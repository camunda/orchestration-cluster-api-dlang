/// Adaptive global backpressure controller.
///
/// Escalates on broker backpressure signals (HTTP 429 / 503 / RESOURCE_EXHAUSTED)
/// and throttles initiating operations via an adaptive concurrency limiter.
/// Drain operations (job complete / fail) bypass the gate.
module camunda.backpressure;

@safe:

import camunda.clock : Clock;
import camunda.config : BackpressureProfile;
import camunda.errors;
import std.algorithm : max, min;

enum BackpressureSeverity
{
    healthy,
    soft,
    severe,
}

struct BackpressureState
{
    BackpressureSeverity severity;
    uint consecutive;
    bool unlimited = true;
    uint permitsMax;
    uint permitsCurrent;
    uint waiters;
    long backoffMs;
}

bool isBackpressureResponse(int status, string body_)
{
    import std.algorithm : canFind;
    const exhausted = body_.length && body_.canFind("RESOURCE_EXHAUSTED");
    if (status == 429 || status == 503) return true;
    if (status == 500) return exhausted;
    return exhausted;
}

bool isBackpressureError(Exception err)
{
    if (auto api = cast(ApiException) err)
        return isBackpressureResponse(api.status, api.body_);
    return false;
}

private enum uint INITIAL_MAX = 16;
private enum uint FLOOR = 1;
private enum double SOFT_FACTOR = 0.70;
private enum double SEVERE_FACTOR = 0.50;
private enum long RECOVERY_INTERVAL_MS = 1000;
private enum uint RECOVERY_STEP = 1;
private enum uint SEVERE_THRESHOLD = 3;
private enum long DECAY_QUIET_MS = 2000;
private enum uint MAX_WAITERS = 1000;
private enum double HEALTHY_RECOVERY_MULTIPLIER = 1.5;
private enum long UNLIMITED_AFTER_HEALTHY_MS = 30_000;
private enum long BACKOFF_INITIAL_MS = 25;
private enum long BACKOFF_MAX_MS = 2000;
private enum uint BACKOFF_ESCALATE = 2;

/// Adaptive backpressure manager shared by a client and its workers.
final class BackpressureManager
{
    private bool observeOnly;
    private Clock clock;
    private BackpressureSeverity severity = BackpressureSeverity.healthy;
    private uint consecutive;
    private long lastEventAt = -1;
    private uint permitsCurrent;
    private bool unlimited = true;
    private uint permitsMax;
    private long lastRecoverCheck = -1;
    private long healthySince = -1;
    private uint waiters;
    private long backoffMs;

    this(BackpressureProfile profile, Clock clock)
    {
        this.observeOnly = profile == BackpressureProfile.legacy;
        this.clock = clock;
    }

    BackpressureState state() const
    {
        BackpressureState s;
        s.severity = severity;
        s.consecutive = consecutive;
        s.unlimited = unlimited;
        s.permitsMax = permitsMax;
        s.permitsCurrent = permitsCurrent;
        s.waiters = waiters;
        s.backoffMs = backoffMs;
        return s;
    }

    /// Acquire a permit. Blocks (via the injected clock) while the cap is held.
    /// Fail-fast if the waiter queue is at capacity.
    void acquire()
    {
        if (observeOnly) return;
        maybeRecover();
        if (unlimited)
        {
            permitsCurrent += 1;
            return;
        }
        if (permitsCurrent < permitsMax)
        {
            permitsCurrent += 1;
            return;
        }
        if (waiters >= MAX_WAITERS)
            throw new BackpressureException("waiter queue at capacity");
        waiters += 1;
        scope (exit) waiters -= 1;
        while (!unlimited && permitsCurrent >= permitsMax)
        {
            auto delay = backoffMs > 0 ? backoffMs : 1;
            clock.sleep(delay);
            maybeRecover();
        }
        permitsCurrent += 1;
    }

    void release()
    {
        if (observeOnly) return;
        if (permitsCurrent > 0) permitsCurrent -= 1;
    }

    void recordHealthyHint()
    {
        if (observeOnly) return;
        auto now = clock.nowMs();
        if (lastEventAt >= 0 && now - lastEventAt >= DECAY_QUIET_MS)
        {
            if (severity == BackpressureSeverity.severe)
                severity = BackpressureSeverity.soft;
            else if (severity == BackpressureSeverity.soft)
            {
                severity = BackpressureSeverity.healthy;
                consecutive = 0;
                if (healthySince < 0) healthySince = now;
            }
        }
        maybeRecover();
    }

    void recordBackpressure()
    {
        if (observeOnly) return;
        auto now = clock.nowMs();
        lastEventAt = now;
        healthySince = -1;
        consecutive += 1;
        if (consecutive >= SEVERE_THRESHOLD) severity = BackpressureSeverity.severe;
        else severity = BackpressureSeverity.soft;

        if (unlimited)
        {
            unlimited = false;
            permitsMax = INITIAL_MAX;
        }
        else
        {
            auto factor = severity == BackpressureSeverity.severe ? SEVERE_FACTOR : SOFT_FACTOR;
            auto next = cast(uint)(permitsMax * factor);
            if (next < FLOOR) next = FLOOR;
            permitsMax = next;
        }
        if (permitsMax <= FLOOR && severity == BackpressureSeverity.severe)
        {
            if (backoffMs == 0) backoffMs = BACKOFF_INITIAL_MS;
            else
            {
                backoffMs *= BACKOFF_ESCALATE;
                if (backoffMs > BACKOFF_MAX_MS) backoffMs = BACKOFF_MAX_MS;
            }
        }
    }

    private void maybeRecover()
    {
        if (unlimited) return;
        auto now = clock.nowMs();
        if (lastRecoverCheck >= 0 && now - lastRecoverCheck < RECOVERY_INTERVAL_MS) return;
        lastRecoverCheck = now;
        if (severity != BackpressureSeverity.healthy) return;
        if (healthySince < 0) healthySince = now;
        if (now - healthySince >= UNLIMITED_AFTER_HEALTHY_MS)
        {
            unlimited = true;
            backoffMs = 0;
            return;
        }
        auto grown = cast(uint)(permitsMax * HEALTHY_RECOVERY_MULTIPLIER);
        if (grown < permitsMax + RECOVERY_STEP) grown = permitsMax + RECOVERY_STEP;
        permitsMax = grown;
    }
}

unittest
{
    assert(isBackpressureResponse(429, ""));
    assert(isBackpressureResponse(503, ""));
    assert(isBackpressureResponse(500, "RESOURCE_EXHAUSTED"));
    assert(!isBackpressureResponse(500, "boom"));
    assert(!isBackpressureResponse(404, ""));
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    auto bp = new BackpressureManager(BackpressureProfile.balanced, clock);
    assert(bp.state.unlimited);
    bp.acquire();
    bp.release();
    bp.recordBackpressure();
    assert(!bp.state.unlimited);
    assert(bp.state.permitsMax == INITIAL_MAX);
    assert(bp.state.severity == BackpressureSeverity.soft);
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    auto bp = new BackpressureManager(BackpressureProfile.legacy, clock);
    bp.recordBackpressure();
    bp.recordBackpressure();
    bp.recordBackpressure();
    assert(bp.state.unlimited); // observe-only never gates
}
