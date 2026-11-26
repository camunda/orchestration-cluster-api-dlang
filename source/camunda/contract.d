/// The JobWorker arithmetic contract, ported from the SPARK-proved
/// `Camunda_Contract` package of
/// https://github.com/camunda/orchestration-cluster-api-ada
/// (`src/camunda_contract.ads`, conformance traces in `spec/traces/`).
///
/// Every function is `pure nothrow @nogc @safe` and total: out-of-range
/// arguments are clamped to the proved ranges instead of failing, so the
/// invariants of each state hold whatever the caller passes.
///
/// - `WorkerSlotState`: in-flight slot accounting. `inFlight` stays in
///   `0 .. capacity`, over-activation saturates, release never underflows.
/// - `BackpressureState`: AIMD limit, halved on 429/503, raised by one
///   every `recoveryWindow` healthy outcomes, kept in `[minLimit, maxLimit]`.
/// - `isRetryableStatus`, `isBackpressureStatus`, `retryDelayMs`:
///   overflow-free exponential backoff in `[baseMs, maxDelayMs]`.
/// - `LeaseState`: a job may be settled only while its lease is held.
/// - `usesBackpressureGate`: only activation is gated; complete, fail and
///   throw drain the broker and never wait on the gate (see
///   https://github.com/camunda/orchestration-cluster-api-dlang/issues/50).
module camunda.contract;

@safe:
pure:
nothrow:
@nogc:

enum int maxSlots = 10_000;
enum int maxDelayMsLimit = 600_000;
enum int maxAttempts = 100;
enum int maxRecoveryWindow = 10_000;

private int clampInt(long v, int lo, int hi)
{
    return v < lo ? lo : v > hi ? hi : cast(int) v;
}

// ─── 1. Worker in-flight slots ──────────────────────────────────────────────

struct WorkerSlotState
{
pure nothrow @nogc:

    int capacity = 32;
    int inFlight;
    bool stopped;

    /// A fresh state: nothing in flight, running. `capacity` is clamped
    /// to `1 .. maxSlots`.
    static WorkerSlotState make(long capacity)
    {
        WorkerSlotState s;
        s.capacity = clampInt(capacity, 1, maxSlots);
        return s;
    }

    /// `capacity - inFlight`.
    int freeSlots() const { return capacity - inFlight; }

    /// How many jobs to ask for: 0 when stopped, else
    /// `min(freeSlots, permitted)`.
    int requestedBatchSize(long permitted) const
    {
        if (stopped) return 0;
        const p = clampInt(permitted, 1, maxSlots);
        return freeSlots <= p ? freeSlots : p;
    }

    /// Take up to `count` slots; returns how many were taken. Saturates at
    /// `capacity`; takes nothing when stopped.
    int reserveSlots(long count)
    {
        const c = clampInt(count, 0, maxSlots);
        if (stopped) return 0;
        const taken = c <= freeSlots ? c : freeSlots;
        inFlight += taken;
        return taken;
    }

    /// Free `count` slots, clamping at zero. Returns `wakePoller`: true when
    /// the release brought the free slots from below `threshold` up to at
    /// least `threshold` while running, i.e. a parked poller should
    /// activate again now.
    bool releaseSlots(long count, long threshold = 1)
    {
        const c = clampInt(count, 0, maxSlots);
        const t = clampInt(threshold, 1, capacity);
        const before = freeSlots;
        inFlight = c >= inFlight ? 0 : inFlight - c;
        return !stopped && before < t && freeSlots >= t;
    }

    void markStopped() { stopped = true; }

    /// Stopped with nothing in flight.
    bool isDrained() const { return stopped && inFlight == 0; }
}

// ─── 2. AIMD backpressure ───────────────────────────────────────────────────

struct BackpressureState
{
pure nothrow @nogc:

    int minLimit = 1;
    int maxLimit = 32;
    int currentLimit = 32;
    int healthyStreak;
    int recoveryWindow = 16;

    /// Starts at `maxLimit`. Arguments are clamped to their ranges and
    /// `minLimit` to at most `maxLimit`.
    static BackpressureState make(long minLimit = 1, long maxLimit = 32, long recoveryWindow = 16)
    {
        BackpressureState b;
        b.maxLimit = clampInt(maxLimit, 1, maxSlots);
        b.minLimit = clampInt(minLimit, 1, b.maxLimit);
        b.currentLimit = b.maxLimit;
        b.recoveryWindow = clampInt(recoveryWindow, 1, maxRecoveryWindow);
        return b;
    }

    /// A 429/503: halve the limit (not below `minLimit`), reset the streak.
    void onBackpressure()
    {
        healthyStreak = 0;
        const halved = currentLimit / 2;
        currentLimit = halved < minLimit ? minLimit : halved;
    }

    /// A healthy outcome: every `recoveryWindow`-th in a row raises the
    /// limit by one (up to `maxLimit`).
    void onHealthy()
    {
        if (healthyStreak + 1 >= recoveryWindow)
        {
            healthyStreak = 0;
            if (currentLimit < maxLimit) currentLimit++;
        }
        else healthyStreak++;
    }
}

// ─── 3. Retry and backoff ───────────────────────────────────────────────────

/// 0 (network failure), 429, 502, 503, 504.
bool isRetryableStatus(long status)
{
    return status == 0 || status == 429 || status == 502 || status == 503 || status == 504;
}

/// 429, 503.
bool isBackpressureStatus(long status)
{
    return status == 429 || status == 503;
}

/// `min(maxDelayMs, baseMs * 2^(attempt-1))`, without overflow. Arguments
/// are clamped: `attempt` to `1 .. maxAttempts`, the delays to
/// `1 .. maxDelayMsLimit`, and `baseMs` to at most `maxDelayMs`.
int retryDelayMs(long attempt, long baseMs, long maxDelayMs)
{
    const a = clampInt(attempt, 1, maxAttempts);
    const hi = clampInt(maxDelayMs, 1, maxDelayMsLimit);
    int d = clampInt(baseMs, 1, hi);
    foreach (_; 2 .. a + 1)
    {
        if (d > hi / 2) return hi;
        d *= 2;
    }
    return d;
}

// ─── 4. Job lease ───────────────────────────────────────────────────────────

enum LeaseState
{
    /// The job was activated without a lease.
    none,
    /// The worker holds the lease: the job may be settled.
    held,
    /// The lease ran out or was revoked.
    lost,
    /// The job was completed, failed or errored.
    settled,
}

/// A job may be settled only while its lease is held.
bool maySettle(LeaseState s) { return s == LeaseState.held; }

/// Settle: `held -> settled`; any other state is left as it is. Returns
/// whether the settle was allowed.
bool settle(ref LeaseState s)
{
    if (s != LeaseState.held) return false;
    s = LeaseState.settled;
    return true;
}

// ─── 5. RPC-scoped backpressure gating ──────────────────────────────────────

enum RpcKind
{
    activate,
    complete,
    fail,
    throwError,
}

/// Only activation waits on the backpressure gate.
bool usesBackpressureGate(RpcKind k) { return k == RpcKind.activate; }

// ─── Unit tests ─────────────────────────────────────────────────────────────

unittest // wakePoller fires only when crossing the threshold while running
{
    auto s = WorkerSlotState.make(10);
    assert(s.reserveSlots(10) == 10);
    assert(!s.releaseSlots(1, 3)); // 1 free
    assert(s.releaseSlots(2, 3)); // 3 free: crossed
    assert(!s.releaseSlots(1, 3)); // already above
    s.reserveSlots(10);
    s.markStopped();
    assert(!s.releaseSlots(10, 3), "stopped worker must not wake the poller");
    assert(s.isDrained);
}

unittest // clamping keeps invariants
{
    auto s = WorkerSlotState.make(0);
    assert(s.capacity == 1);
    assert(s.reserveSlots(-5) == 0 && s.inFlight == 0);
    assert(retryDelayMs(1000, 50, 5000) == 5000);
    assert(retryDelayMs(1, 50, 5000) == 50);
    assert(retryDelayMs(3, 50, 5000) == 200);
    auto b = BackpressureState.make(10, 5, 0);
    assert(b.minLimit == 5 && b.maxLimit == 5 && b.recoveryWindow == 1);
}

unittest // leases and gating
{
    auto l = LeaseState.held;
    assert(maySettle(l) && settle(l) && l == LeaseState.settled);
    assert(!settle(l));
    auto n = LeaseState.lost;
    assert(!settle(n) && n == LeaseState.lost);
    assert(!maySettle(LeaseState.none));
    assert(usesBackpressureGate(RpcKind.activate));
    assert(!usesBackpressureGate(RpcKind.complete));
    assert(!usesBackpressureGate(RpcKind.fail));
    assert(!usesBackpressureGate(RpcKind.throwError));
}
