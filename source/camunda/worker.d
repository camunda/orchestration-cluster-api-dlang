/// Job workers: activate jobs of a given type, run a handler on a pool of
/// threads, apply each result.
///
/// The model (as in the other Camunda SDKs): `maxJobsActive` caps the jobs
/// the worker holds at once; whenever enough capacity frees up the worker
/// activates more, sized to the free capacity.
///
/// Engine I/O and user code are separate. The thread that calls `run` is
/// the dispatcher: it sends the activation long poll and every
/// complete/fail/error call through the client's I/O thread (one libcurl
/// multi loop over a small keep-alive connection pool, see
/// `camunda.http.HttpEngine`) and never blocks on one. Handler threads only
/// run the handler: each gets an already parsed job and hands its
/// `JobAction` back to the dispatcher. So the engine connections and file
/// descriptors a worker uses do not grow with `handlerThreads`
/// (camunda/orchestration-cluster-api-dlang#54).
///
/// The handler pool is elastic: it starts with `coreHandlerThreads`
/// threads, adds one whenever a job is dispatched and none is free, and
/// retires the extra ones after `threadIdleTimeoutMs` without the pool
/// being fully busy.
module camunda.worker;

@safe:

import camunda.client : CamundaClient;
import camunda.clock : Clock;
import camunda.config : WorkerDefaults;
import camunda.errors;
import camunda.generated;
import camunda.http : HttpResult, HttpSink;
import camunda.jsonx;
import camunda.safeio : Chan, Isolated, JoinHandle, ThreadSafe, assumeIsolated, isSendable, spawn;
import std.json;

/// Configuration for a `JobWorker`. A zero or null field is unset: the
/// worker takes it from the client's `CAMUNDA_WORKER_*` defaults (see
/// `WorkerDefaults`), so explicit settings always win over the environment.
struct JobWorkerConfig
{
    string jobType;
    /// Most jobs held at once (activated and not yet completed, failed or
    /// left). Each activation asks for the free capacity. Default 32
    /// (`CAMUNDA_WORKER_MAX_CONCURRENT_JOBS`).
    int maxJobsActive;
    /// Most threads running the handler; 0 means four per CPU core, at
    /// most `maxJobsActive`. Handler threads only run user code, so this
    /// sets how many handlers run at once, not how many connections the
    /// worker opens.
    int handlerThreads;
    /// Handler threads kept even when idle; 0 means `min(2, effectiveThreads)`.
    int coreHandlerThreads;
    /// Retire handler threads above the core once the pool has not been
    /// fully busy for this long. 0 means 30 s.
    long threadIdleTimeoutMs;
    /// Job lease duration. Default 60 s (`CAMUNDA_WORKER_TIMEOUT`).
    long jobTimeoutMs;
    /// Long-poll timeout of an activation request. Default 10 s
    /// (`CAMUNDA_WORKER_REQUEST_TIMEOUT`).
    long requestTimeoutMs;
    /// Pause after an activation that returned no jobs (for servers that
    /// answer at once rather than long-polling).
    long pollIntervalMs = 250;
    /// How long `run` waits, once stopping, for the jobs it holds to be
    /// settled. Jobs still held then are counted in `WorkerStats.unaccounted`
    /// and `run` returns without waiting for their handler threads. An
    /// activation request still in flight then is not waited for either and
    /// is counted in `WorkerStats.abandonedActivations`: jobs it activates
    /// stay locked on the engine until `jobTimeoutMs`. 0 means 30 s.
    long shutdownTimeoutMs;
    /// Default "d-sdk-worker" (`CAMUNDA_WORKER_NAME`).
    string workerName;
    string[] fetchVariables;
    string[] tenantIds;
    long startupJitterMaxSeconds;
    bool withLease;

    static JobWorkerConfig create(string jobType)
    {
        JobWorkerConfig c;
        c.jobType = jobType;
        return c;
    }

    static JobWorkerConfig fromDefaults(string jobType, const ref WorkerDefaults defaults)
    {
        auto c = JobWorkerConfig.create(jobType);
        c.applyDefaults(defaults);
        return c;
    }

    /// Fill the unset fields from `defaults`.
    void applyDefaults(const ref WorkerDefaults defaults)
    {
        if (!jobTimeoutMs) jobTimeoutMs = defaults.timeoutMs;
        if (!maxJobsActive) maxJobsActive = defaults.maxConcurrentJobs;
        if (!requestTimeoutMs) requestTimeoutMs = defaults.requestTimeoutMs;
        if (!workerName.length) workerName = defaults.name;
        if (!startupJitterMaxSeconds) startupJitterMaxSeconds = defaults.startupJitterMaxSeconds;
    }

    JobWorkerConfig maxJobs(int n) { maxJobsActive = n; return this; }
    JobWorkerConfig shutdownTimeout(long ms) { shutdownTimeoutMs = ms; return this; }
    JobWorkerConfig threads(int n) { handlerThreads = n; return this; }
    JobWorkerConfig coreThreads(int n) { coreHandlerThreads = n; return this; }
    JobWorkerConfig idleTimeoutMs(long ms) { threadIdleTimeoutMs = ms; return this; }
    JobWorkerConfig timeoutMs(long ms) { jobTimeoutMs = ms; return this; }
    JobWorkerConfig name(string n) { workerName = n; return this; }
    JobWorkerConfig variables(string[] names) { fetchVariables = names; return this; }
    JobWorkerConfig tenants(string[] ids) { tenantIds = ids; return this; }
    JobWorkerConfig lease(bool enabled) { withLease = enabled; return this; }

    /// Most handler threads alive at once.
    int effectiveThreads() const
    {
        import std.algorithm.comparison : clamp, max;
        import std.parallelism : totalCPUs;
        if (handlerThreads > 0) return handlerThreads;
        return clamp(4 * totalCPUs, 1, max(1, maxJobsActive));
    }

    /// Handler threads started up front and kept when idle.
    int effectiveCoreThreads() const
    {
        import std.algorithm.comparison : clamp, max, min;
        const most = max(1, effectiveThreads);
        return coreHandlerThreads > 0 ? clamp(coreHandlerThreads, 1, most) : min(2, most);
    }

    /// Idle time after which extra handler threads retire.
    long effectiveIdleTimeoutMs() const
    {
        return threadIdleTimeoutMs > 0 ? threadIdleTimeoutMs : 30_000;
    }

    /// `shutdownTimeoutMs`, or 30 s when unset.
    long effectiveShutdownTimeoutMs() const
    {
        return shutdownTimeoutMs > 0 ? shutdownTimeoutMs : 30_000;
    }
}

/// Handler pool size so far, for tests and tuning.
struct PoolStats
{
    int live;      /// handler threads running now
    int peak;      /// most handler threads alive at once
    long spawned;  /// handler threads started
    long retired;  /// handler threads retired after idling
}

/// Counters of a worker's activity so far.
struct WorkerStats
{
    long activated;          /// jobs received from activations
    long completed;          /// completeJob calls that succeeded
    long failed;             /// failJob calls that succeeded (incl. handler exceptions)
    long errored;            /// throwJobError calls that succeeded
    long left;               /// jobs the handler chose to leave
    /// Jobs the server returned beyond the free slots. They are dropped
    /// without a command and time out on the engine.
    long overActivated;
    long handlerExceptions;  /// handler threw; the job was failed with retries - 1
    long actionFailures;     /// a complete/fail/error call itself failed
    long activationFailures; /// activation requests that failed (then backed off)
    long handlerAborts;      /// a handler thread died (an `Error`) holding a job; the job is counted as left
    long unaccounted;        /// jobs still held when the shutdown timeout ran out
    /// Activation requests still in flight when the shutdown timeout ran
    /// out. Jobs such a request activates are never seen by the worker and
    /// stay locked on the engine until their job timeout.
    long abandonedActivations;
}

/// A worker's run state, shared by its poller, its handler threads and
/// whoever stops it. Every member is atomic.
final class WorkerControl
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;
    private shared bool stopping_;
    // Each `run` is a generation. When the shutdown timeout runs out, that
    // run's generation is recorded here: its handler threads then run no
    // job they take, since nobody is left to settle it. A later `run` has a
    // new generation, so its handlers are not affected. The record is a
    // watermark: every generation up to it stays abandoned, so a second
    // timed-out run does not revive the first one's handlers.
    private shared long runGen_, abandonedGen_;
    private shared long activated, completed, failed, errored, left, overActivated,
        handlerExceptions, actionFailures, activationFailures,
        handlerAborts, unaccounted, abandonedActivations;
    private shared int poolLive, poolPeak;
    private shared long poolSpawned, poolRetired;

    /// Ask the worker to stop: it activates no more jobs, finishes the ones
    /// it holds, and `run` returns (within the shutdown timeout).
    void stop() { atomicStore(stopping_, true); }

    /// Whether the shutdown timeout ran out with jobs held.
    /// Cleared when the worker runs again.
    bool abandoned() const
    {
        const g = atomicLoad(runGen_);
        return g > 0 && atomicLoad(abandonedGen_) == g;
    }

    package void abandon() { atomicStore(abandonedGen_, atomicLoad(runGen_)); }

    /// Whether the run of generation `gen`, or a later one, timed out on
    /// shutdown. A run that ended in time waited for all its handlers, so
    /// none of an earlier generation is left to be wrongly skipped.
    private bool abandonedRun(long gen) const { return gen <= atomicLoad(abandonedGen_); }

    private long generation() const { return atomicLoad(runGen_); }

    /// Whether `stop` was called.
    bool stopping() const { return atomicLoad(stopping_); }

    /// A snapshot of the handler pool.
    PoolStats pool() const
    {
        PoolStats p;
        p.live = atomicLoad(poolLive);
        p.peak = atomicLoad(poolPeak);
        p.spawned = atomicLoad(poolSpawned);
        p.retired = atomicLoad(poolRetired);
        return p;
    }

    private void poolGrew(int live)
    {
        atomicStore(poolLive, live);
        if (live > atomicLoad(poolPeak)) atomicStore(poolPeak, live);
        atomicOp!"+="(poolSpawned, 1);
    }

    private void poolShrank(int live, long n)
    {
        atomicStore(poolLive, live);
        atomicOp!"+="(poolRetired, n);
    }

    /// A snapshot of the counters.
    WorkerStats stats() const
    {
        WorkerStats s;
        s.activated = atomicLoad(activated);
        s.completed = atomicLoad(completed);
        s.failed = atomicLoad(failed);
        s.errored = atomicLoad(errored);
        s.left = atomicLoad(left);
        s.overActivated = atomicLoad(overActivated);
        s.handlerExceptions = atomicLoad(handlerExceptions);
        s.actionFailures = atomicLoad(actionFailures);
        s.activationFailures = atomicLoad(activationFailures);
        s.handlerAborts = atomicLoad(handlerAborts);
        s.unaccounted = atomicLoad(unaccounted);
        s.abandonedActivations = atomicLoad(abandonedActivations);
        return s;
    }

    private void count(string field)(long n = 1)
    {
        atomicOp!"+="(mixin(field), n);
    }

    private void restart()
    {
        atomicOp!"+="(runGen_, 1);
        atomicStore(stopping_, false);
    }
}

unittest // abandonment is a watermark across successive shutdown timeouts
{
    auto c = new WorkerControl;
    c.restart();
    const g1 = c.generation;
    c.abandon();
    assert(c.abandonedRun(g1) && c.abandoned);
    c.restart();
    const g2 = c.generation;
    assert(!c.abandoned && !c.abandonedRun(g2));
    assert(c.abandonedRun(g1), "first run revived by a restart");
    c.abandon();
    assert(c.abandonedRun(g1), "first run revived by a second timeout");
    assert(c.abandonedRun(g2) && c.abandoned);
    c.restart();
    assert(!c.abandoned && !c.abandonedRun(c.generation));
}

/// A job delivered to a worker handler.
struct Job
{
    ActivatedJobResult raw;
    private import camunda.clock : Clock;
    private Clock _clock;
    private ThreadSafe!CamundaClient _client;
    private ThreadSafe!WorkerControl _control;

    string key() const { return raw.jobKey.value; }
    string type() const { return raw.type; }
    string processInstanceKey() const { return raw.processInstanceKey.value; }
    string elementId() const { return raw.elementId.value; }
    int retries() const { return raw.retries; }
    JSONValue variables() const { return raw.variables; }
    JSONValue customHeaders() const { return raw.customHeaders; }
    string leaseToken() const
    {
        return raw.has_jobLeaseToken ? raw.jobLeaseToken.value : null;
    }
    Clock clock() { return _clock; }
    /// The worker's client, for calls the handler makes itself.
    CamundaClient client() { return _client.get; }
    /// Stop the worker that delivered this job (see `WorkerControl.stop`).
    void stopWorker() { _control.get.stop(); }
}

/// The action a handler asks the worker to take after processing a job.
struct JobAction
{
    enum Kind { complete, fail, error, leave }
    Kind kind = Kind.complete;
    JSONValue variables;
    string errorMessage;
    string errorCode;
    int retries = -1;
    long retryBackoffMs;

    static JobAction complete()
    {
        JobAction a;
        a.kind = Kind.complete;
        return a;
    }

    static JobAction completeWith(JSONValue variables)
    {
        auto a = complete();
        a.variables = variables;
        return a;
    }

    static JobAction fail(string errorMessage)
    {
        JobAction a;
        a.kind = Kind.fail;
        a.errorMessage = errorMessage;
        return a;
    }

    static JobAction bpmnError(string errorCode, string errorMessage = null)
    {
        JobAction a;
        a.kind = Kind.error;
        a.errorCode = errorCode;
        a.errorMessage = errorMessage;
        return a;
    }

    static JobAction leave()
    {
        JobAction a;
        a.kind = Kind.leave;
        return a;
    }
}

/// A job handler. It runs on the worker's handler threads, so it is a plain
/// function: give it state through the `run` context argument, which must
/// be sendable (immutable data, `shared`, `Chan`, `ThreadSafe`, ...).
alias JobHandler = JobAction function(Job) @safe;

/// A continuously polling job worker with a pool of handler threads.
final class JobWorker
{
    private CamundaClient client;
    private JobWorkerConfig config;
    private WorkerControl ctl;

    private enum long backoffMinMs = 50;
    private enum long backoffMaxMs = 5_000;
    /// The tag of the activation request; commands get 1, 2, ...
    private enum long activationTag = 0;

    this(CamundaClient client, JobWorkerConfig config)
    {
        this.client = client;
        WorkerDefaults builtIn;
        config.applyDefaults(builtIn);
        import camunda.contract : maxSlots;
        import std.conv : text;
        // The slot contract caps capacity at maxSlots; reject a larger
        // setting instead of silently activating fewer jobs.
        if (config.maxJobsActive < 1 || config.maxJobsActive > maxSlots)
            throw new ConfigException(text("JobWorkerConfig.maxJobsActive must be in 1 .. ", maxSlots,
                ", got ", config.maxJobsActive));
        this.config = config;
        this.ctl = new WorkerControl;
    }

    /// Stop the worker (see `WorkerControl.stop`). From another thread, use
    /// `control`.
    void stop() { ctl.stop(); }

    /// The run state, for other threads: `control.get.stop()`,
    /// `control.get.stats()`.
    ThreadSafe!WorkerControl control()
    {
        // WorkerControl's members are all atomic.
        return ThreadSafe!WorkerControl.assumeThreadSafe(ctl);
    }

    /// Counters so far.
    WorkerStats stats() const { return ctl.stats(); }

    /// Handler pool size so far.
    PoolStats pool() const { return ctl.pool(); }

    /// Run until `stop`. This thread dispatches: it sends the activation
    /// long poll and the complete/fail/error calls through the client's I/O
    /// thread without waiting on them, and hands parsed jobs to up to
    /// `config.effectiveThreads` handler threads (an elastic pool: it
    /// starts with `config.effectiveCoreThreads`, grows when a job finds no
    /// free thread, and shrinks back after `config.effectiveIdleTimeoutMs`
    /// without being fully busy). A handler that throws fails its job with
    /// one retry fewer. A complete/fail/error call that fails transiently
    /// is retried per `CAMUNDA_SDK_HTTP_RETRY_*`. Failed activations back
    /// off (50 ms up to 5 s). Rethrows `LeaseNotHonored`, after the jobs
    /// already held finish.
    void run(JobHandler handler)
    {
        run(&callPlain, handler);
    }

    /// ditto, passing `context` to every handler call.
    void run(Ctx)(JobAction function(Job, Ctx) @safe handler, Ctx context)
        if (isSendable!Ctx)
    {
        import camunda.contract : BackpressureState, RpcKind, WorkerSlotState,
            isBackpressureStatus, retryDelayMs, usesBackpressureGate;
        import camunda.retry : backoffDelayMs, isRetryable;
        import std.algorithm.comparison : max, min;
        ctl.restart();
        long gen = ctl.generation;
        auto clock = client.clock;
        if (config.startupJitterMaxSeconds > 0)
        {
            import camunda.safeio : unitRandom;
            auto jitter = cast(long)(config.startupJitterMaxSeconds * 1000 * unitRandom());
            // Interruptible: a stop (or a newer run) during the jitter
            // returns without activating, within the shutdown timeout.
            if (!startupWait(clock, jitter, () => ctl.stopping || ctl.generation != gen))
                return;
        }
        auto transport = client.transport;
        const retry = transport.config.retry;
        const maxAttempts = max(1, retry.maxAttempts);
        // Slot accounting and the activation AIMD limit follow the
        // SPARK-proved contract (camunda.contract): held jobs never exceed
        // the capacity, a release never underflows, and the batch asked for
        // is min(free slots, AIMD limit).
        auto slots = WorkerSlotState.make(max(1, config.maxJobsActive));
        const cap = slots.capacity;
        auto aimd = BackpressureState.make(1, cap, 16);
        // Only activation is gated; job commands drain the broker.
        static assert(usesBackpressureGate(RpcKind.activate));
        static assert(!usesBackpressureGate(RpcKind.complete) && !usesBackpressureGate(RpcKind.fail)
            && !usesBackpressureGate(RpcKind.throwError));
        // Activate again once 30% of the capacity is free, as the Java
        // client does: no tiny one-job activations under load.
        const threshold = max(1, (cap * 3 + 9) / 10);
        auto tickets = Chan!Ticket.make;
        auto events = Chan!Event.make;
        // EventSink only puts on a channel, which is thread-safe.
        auto sink = ThreadSafe!HttpSink.assumeThreadSafe(new EventSink(events));
        JoinHandle[] handlers;
        int live;     // threads serving jobs
        int retiring; // threads sent a retire signal and not yet exited
        bool abandoned; // the shutdown timeout ran out with jobs held
        scope (exit)
        {
            // After a shutdown timeout, jobs still queued for a handler are
            // discarded (they are counted in `unaccounted`): no dispatcher
            // is left to settle what a late handler would do with them.
            if (abandoned)
            {
                Ticket dropped;
                while (tickets.tryTake(dropped)) {}
            }
            tickets.close();
            // A thread that died was reported (`aborted`) and accounted
            // for, so what killed it is not rethrown. After a shutdown
            // timeout, threads still running are not waited for.
            foreach (ref h; handlers)
                if (!abandoned || !h.running) h.join(false);
                else h.detach(); // do not keep the process alive at exit
            ctl.poolShrank(0, 0);
        }
        const maxThreads = max(1, config.effectiveThreads);
        const coreThreads = config.effectiveCoreThreads;
        const idleTimeout = config.effectiveIdleTimeoutMs;
        const shutdownTimeout = config.effectiveShutdownTimeoutMs;
        long stopDeadlineMs = long.max; // set when stopping starts
        int busy;  // handed to a handler that has not returned yet
        bool activating;
        long nextActivationMs; // no activation before this (backoff, poll interval)
        int failedActivations; // in a row, for the backoff
        Exception fatal;
        Pending[long] inFlight; // sent commands, by tag
        Pending[long] retrying; // commands waiting to be sent again
        long nextTag = activationTag + 1;

        void grow()
        {
            handlers ~= spawn(&handlerLoop!Ctx, tickets, events, client.threadSafe, control, gen, handler, context);
            live++;
            ctl.poolGrew(live + retiring);
        }
        void settled(JobAction.Kind kind)
        {
            slots.releaseSlots(1);
            final switch (kind)
            {
            case JobAction.Kind.complete: ctl.count!"completed"; break;
            case JobAction.Kind.fail: ctl.count!"failed"; break;
            case JobAction.Kind.error: ctl.count!"errored"; break;
            case JobAction.Kind.leave: ctl.count!"left"; break;
            }
        }
        void send(long tag, Pending p)
        {
            p.attempts++;
            inFlight[tag] = p;
            try transport.submitJson("POST", p.command.path, p.command.body_, sink, tag);
            catch (Exception e)
            {
                inFlight.remove(tag);
                ctl.count!"actionFailures";
                slots.releaseSlots(1);
            }
        }
        void activationFailed(Exception e = null)
        {
            ctl.count!"activationFailures";
            if (auto api = cast(ApiException) e)
                if (isBackpressureStatus(api.status)) aimd.onBackpressure();
            if (failedActivations < 100) failedActivations++;
            nextActivationMs = clock.nowMs + retryDelayMs(failedActivations, backoffMinMs, backoffMaxMs);
        }
        void activate()
        {
            try
            {
                const timeout = max(30_000, config.requestTimeoutMs + 10_000);
                transport.submitJson("POST", "/jobs/activation", activationBody(slots.requestedBatchSize(aimd.currentLimit)), sink,
                    activationTag, true, timeout);
                activating = true;
            }
            catch (Exception e) activationFailed();
        }
        void activated(HttpResult r)
        {
            activating = false;
            JSONValue[] jobs;
            try
            {
                auto payload = parseJSON(transport.checked(r).body_);
                if (payload.type == JSONType.object)
                    if (auto p = "jobs" in payload)
                        if (p.type == JSONType.array) jobs = p.arrayNoRef;
            }
            catch (Exception e)
            {
                transport.recordOutcome(e); // activations are not retried
                activationFailed(e);
                return;
            }
            transport.recordOutcome(null);
            failedActivations = 0;
            aimd.onHealthy();
            ctl.count!"activated"(jobs.length);
            if (config.withLease)
                foreach (j; jobs)
                {
                    auto a = ActivatedJobResult.fromJson(j);
                    if (!a.has_jobLeaseToken || !a.jobLeaseToken.value.length)
                    {
                        // The server ignored the lease request: hand out
                        // nothing and stop, as these jobs cannot be settled
                        // under the protocol the handler expects.
                        fatal = new LeaseNotHonored(a.has_jobKey ? a.jobKey.value : "", "withLease");
                        return;
                    }
                }
            // Over-activation (more jobs than free slots) saturates: the
            // excess is left, and the engine hands it out again after its
            // timeout.
            const taken = slots.reserveSlots(jobs.length);
            if (taken < jobs.length)
            {
                ctl.count!"overActivated"(jobs.length - taken);
                jobs = jobs[0 .. taken];
            }
            foreach (j; jobs)
            {
                busy++;
                // The parsed response is dropped below; each job subtree
                // goes to exactly one handler thread.
                tickets.put(Ticket(false, assumeIsolated(j)));
            }
            if (!jobs.length && config.pollIntervalMs > 0)
                nextActivationMs = clock.nowMs + config.pollIntervalMs;
        }
        void handle(ref Event ev)
        {
            final switch (ev.kind)
            {
            case Event.Kind.retired:
                retiring--;
                ctl.poolShrank(live + retiring, 0);
                return;
            case Event.Kind.aborted:
                // The thread died holding a job: free its slot and count
                // the job as left (the engine hands it out again after its
                // timeout). The pool replaces the thread when needed.
                busy--;
                live--;
                ctl.count!"handlerAborts";
                settled(JobAction.Kind.leave);
                ctl.poolShrank(live + retiring, 0);
                return;
            case Event.Kind.handled:
                busy--;
                if (ev.command.kind == JobAction.Kind.leave || !ev.command.path.length)
                {
                    if (ev.command.kind == JobAction.Kind.leave) settled(JobAction.Kind.leave);
                    else slots.releaseSlots(1); // the command could not even be built (counted by the handler)
                    return;
                }
                send(nextTag++, Pending(ev.command));
                return;
            case Event.Kind.http:
                if (ev.http.tag == activationTag)
                {
                    activated(ev.http);
                    return;
                }
                auto p = ev.http.tag in inFlight;
                if (p is null) return;
                auto pending = *p;
                inFlight.remove(ev.http.tag);
                try
                {
                    transport.checked(ev.http);
                    transport.recordOutcome(null);
                    settled(pending.command.kind);
                }
                catch (Exception e)
                {
                    if (isRetryable(e) && pending.attempts < maxAttempts)
                    {
                        // Like the blocking path, only a command given up
                        // on counts as backpressure.
                        pending.dueMs = clock.nowMs + backoffDelayMs(retry, pending.attempts - 1);
                        retrying[ev.http.tag] = pending;
                    }
                    else
                    {
                        transport.recordOutcome(e);
                        ctl.count!"actionFailures";
                        slots.releaseSlots(1);
                    }
                }
                return;
            }
        }

        foreach (_; 0 .. coreThreads) grow();
        // Last time every live thread had a job (or the pool last changed).
        long lastFullMs = clock.nowMs;
        for (;;)
        {
            Event ev;
            while (events.tryTake(ev)) handle(ev);
            const now = clock.nowMs;
            foreach (tag; retrying.keys)
                if (retrying[tag].dueMs <= now)
                {
                    auto p = retrying[tag];
                    retrying.remove(tag);
                    send(tag, p);
                }
            // Join retirees that have exited (they left their slot already).
            if (handlers.length > live + retiring) pruneFinished(handlers);
            // Threads still retiring keep their slot until they exit.
            while (busy > live && live + retiring < maxThreads) grow();
            if (busy >= live) lastFullMs = now;
            else if (live > coreThreads && now - lastFullMs >= idleTimeout)
            {
                // Retire the threads that were not needed for a whole idle
                // period. A retire ticket is the signal; idle threads take
                // it, busy ones only after their job.
                const target = max(coreThreads, busy);
                const n = live - target;
                foreach (_; 0 .. n) tickets.put(Ticket(true));
                live = target;
                retiring += n;
                ctl.poolShrank(live + retiring, n);
                lastFullMs = now;
            }
            const stopping = ctl.stopping || fatal !is null;
            if (stopping && !activating && slots.inFlight == 0) break;
            if (stopping && stopDeadlineMs == long.max) stopDeadlineMs = now + shutdownTimeout;
            if (stopping && now >= stopDeadlineMs)
            {
                // Bounded drain: report what is still held, do not hang.
                if (slots.inFlight > 0) ctl.count!"unaccounted"(slots.inFlight);
                // An activation long poll may outlast the timeout; the jobs
                // it returns are not seen here, so record the request.
                if (activating) ctl.count!"abandonedActivations";
                // Before the queue is drained: a handler that takes a
                // ticket from now on sees the flag and skips it.
                ctl.abandon();
                abandoned = true;
                break;
            }
            // Activate when enough capacity is free, unless queued jobs wait
            // for slots that retiring threads still hold.
            const wanted = !stopping && !activating && slots.freeSlots >= threshold
                && !(busy > live && retiring > 0);
            if (wanted && now >= nextActivationMs) activate();

            // Wait for the next event, bounded by the next deadline on the
            // injected clock: idle retirement, a command retry, or the
            // next activation.
            long deadline = long.max;
            if (live > coreThreads && busy < live) deadline = min(deadline, lastFullMs + idleTimeout);
            foreach (p; retrying) deadline = min(deadline, p.dueMs);
            deadline = min(deadline, stopDeadlineMs);
            // `stop` sends no event: look for it now and then (also while
            // idle or backing off), so the worker stops on time.
            if (!stopping) deadline = min(deadline, now + stopPollMs);
            if (wanted && !activating) deadline = min(deadline, max(now + 1, nextActivationMs));
            const got = deadline == long.max ? events.take(ev) : takeUntil(events, ev, clock, deadline);
            if (got) handle(ev);
        }
        if (fatal !is null) throw fatal;
    }

    private string activationBody(int count)
    {
        auto req = JobActivationRequest.initEmpty();
        req.type(config.jobType);
        req.maxJobsToActivate(count);
        req.timeout(config.jobTimeoutMs);
        req.requestTimeout(config.requestTimeoutMs);
        req.worker(config.workerName);
        if (config.fetchVariables.length) req.fetchVariable(config.fetchVariables);
        if (config.tenantIds.length)
        {
            TenantId[] ids;
            foreach (t; config.tenantIds) ids ~= TenantId.assumeExists(t);
            req.tenantIds(ids);
        }
        if (config.withLease) req.withLease(true);
        return client.withDefaultJobTenants(req.toJson()).toString();
    }

    private static JobAction callPlain(Job job, JobHandler handler)
    {
        return handler(job);
    }

    /// Take from `ch` until `clock` reaches `deadlineMs`. On the live
    /// clock this is a plain timed wait; an injected clock is waited on in
    /// short `clock.sleep` slices, so it decides when the deadline has
    /// passed.
    private static bool takeUntil(T)(Chan!T ch, out T v, Clock clock, long deadlineMs)
    {
        import camunda.clock : LiveClock;
        enum sliceMs = 5;
        const live = cast(LiveClock) clock !is null;
        for (;;)
        {
            if (ch.tryTake(v)) return true;
            const left = deadlineMs - clock.nowMs;
            if (left <= 0) return false;
            if (live)
            {
                if (ch.takeFor(v, left)) return true;
            }
            else clock.sleep(left < sliceMs ? left : sliceMs);
        }
    }

    /// Join and drop the handles of threads that have retired.
    /// Returns how many were reaped.
    private static int pruneFinished(ref JoinHandle[] handlers)
    {
        JoinHandle[] keep;
        int reaped;
        foreach (ref h; handlers)
        {
            if (h.running) keep ~= h;
            else
            {
                h.join(false); // a thread that died was already reported
                reaped++;
            }
        }
        handlers = keep;
        return reaped;
    }
}

/// How often (ms) the dispatcher checks for `stop` while it holds jobs.
private enum long stopPollMs = 100;

/// Sleep `jitterMs` through `clock` in `stopPollMs` slices, checking
/// `cancelled` before each slice. Returns false (at once) when cancelled.
private bool startupWait(C)(C clock, long jitterMs, scope bool delegate() @safe cancelled)
{
    const deadline = clock.nowMs + jitterMs;
    for (;;)
    {
        if (cancelled()) return false;
        const left = deadline - clock.nowMs;
        if (left <= 0) return true;
        clock.sleep(left < stopPollMs ? left : stopPollMs);
    }
}

unittest // stop during the startup jitter returns promptly, without activating
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    int checks;
    assert(!startupWait(clock, 30_000, () => ++checks > 3));
    assert(clock.nowMs <= 3 * stopPollMs, "stop was not seen during the jitter");
}

unittest // without a stop, the full jitter elapses before the first activation
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    assert(startupWait(clock, 1_234, () => false));
    assert(clock.nowMs == 1_234);
    assert(startupWait(clock, 0, () => false) && clock.nowMs == 1_234);
}

/// A job for a handler thread, or the signal to retire.
private struct Ticket
{
    bool retire;
    Isolated!JSONValue job;
}

/// The engine call that settles a job once its handler returned (none for
/// `leave`, or when the call could not be built: `path` is empty then).
private struct Command
{
    JobAction.Kind kind;
    string path;
    string body_;
}

/// What the dispatcher reacts to.
private struct Event
{
    enum Kind { handled, retired, http, aborted }
    Kind kind;
    Command command; // handled
    HttpResult http; // http
}

/// A command and how often it was sent.
private struct Pending
{
    Command command;
    uint attempts;
    long dueMs; // when retrying: when to send it again
}

/// Hands the engine's results to the dispatcher.
private final class EventSink : HttpSink
{
    private Chan!Event events;
    this(Chan!Event events) { this.events = events; }
    override void deliver(HttpResult r)
    {
        Event e;
        e.kind = Event.Kind.http;
        e.http = r;
        events.put(e);
    }
}

/// One handler thread: take parsed jobs until the channel closes or a
/// retire ticket comes, run the handler, and hand the resulting engine
/// call back to the dispatcher (which sends it). It makes no engine call
/// itself.
private void handlerLoop(Ctx)(Chan!Ticket tickets, Chan!Event events,
    ThreadSafe!CamundaClient client, ThreadSafe!WorkerControl control, long gen,
    JobAction function(Job, Ctx) @safe handler, Ctx context)
{
    auto c = client.get;
    auto ctl = control.get;
    Ticket t;
    while (tickets.take(t))
    {
        // After a shutdown timeout, a ticket taken during or after the
        // drain is already counted in `unaccounted`: do not run it.
        if (ctl.abandonedRun(gen)) return;
        Event done;
        if (t.retire)
        {
            done.kind = Event.Kind.retired;
            events.put(done); // wake the dispatcher to reuse the slot
            return;
        }
        // If anything escapes (an `Error`: the thread dies), tell the
        // dispatcher, so the job's slot is freed and accounted for.
        bool reported;
        scope (exit) if (!reported)
        {
            Event aborted;
            aborted.kind = Event.Kind.aborted;
            events.put(aborted);
        }
        Job job;
        job.raw = ActivatedJobResult.fromJson(t.job.take);
        job._clock = c.clock;
        job._client = client;
        job._control = control;
        JobAction action;
        try action = handler(job, context);
        catch (Exception e)
        {
            ctl.count!"handlerExceptions";
            action = JobAction.fail(e.msg);
            action.retries = job.retries > 0 ? job.retries - 1 : 0;
        }
        done.kind = Event.Kind.handled;
        try done.command = command(job, action);
        catch (Exception e)
        {
            ctl.count!"actionFailures";
            done.command = Command(JobAction.Kind.complete); // no path: the dispatcher drops the job
        }
        reported = true;
        events.put(done);
    }
}

/// The engine call for `action` on `job`.
private Command command(const ref Job job, JobAction action)
{
    import std.uri : encodeComponent;
    Command c;
    c.kind = action.kind;
    const base = "/jobs/" ~ encodeComponent(job.key) ~ "/";
    final switch (action.kind)
    {
    case JobAction.Kind.leave:
        return c;
    case JobAction.Kind.complete:
        auto req = JobCompletionRequest.initEmpty();
        if (action.variables.type != JSONType.null_)
            req.variables(action.variables);
        if (job.leaseToken.length)
            req.jobLeaseToken(JobLeaseToken.assumeExists(job.leaseToken));
        c.path = base ~ "completion";
        c.body_ = req.toJson().toString();
        return c;
    case JobAction.Kind.fail:
        auto req = JobFailRequest.initEmpty();
        if (action.errorMessage.length) req.errorMessage(action.errorMessage);
        if (action.retries >= 0) req.retries(action.retries);
        if (action.retryBackoffMs > 0) req.retryBackOff(action.retryBackoffMs);
        if (action.variables.type != JSONType.null_)
            req.variables(action.variables);
        if (job.leaseToken.length)
            req.jobLeaseToken(JobLeaseToken.assumeExists(job.leaseToken));
        c.path = base ~ "failure";
        c.body_ = req.toJson().toString();
        return c;
    case JobAction.Kind.error:
        auto req = JobErrorRequest.initEmpty();
        req.errorCode(action.errorCode);
        if (action.errorMessage.length) req.errorMessage(action.errorMessage);
        if (action.variables.type != JSONType.null_)
            req.variables(action.variables);
        if (job.leaseToken.length)
            req.jobLeaseToken(JobLeaseToken.assumeExists(job.leaseToken));
        c.path = base ~ "error";
        c.body_ = req.toJson().toString();
        return c;
    }
}

unittest
{
    import std.algorithm.comparison : clamp;
    import std.parallelism : totalCPUs;
    auto cfg = JobWorkerConfig.create("payment-service").maxJobs(20).name("payment-worker");
    assert(cfg.jobType == "payment-service");
    assert(cfg.maxJobsActive == 20);
    assert(cfg.effectiveThreads == clamp(4 * totalCPUs, 1, 20));
    assert(JobWorkerConfig.create("x").maxJobs(1).effectiveThreads == 1);
    assert(JobWorkerConfig.create("x").maxJobs(10_000).effectiveThreads == 4 * totalCPUs);
    assert(cfg.threads(4).effectiveThreads == 4);
    assert(cfg.workerName == "payment-worker");
    auto a = JobAction.completeWith(JSONValue(["paid": JSONValue(true)]));
    assert(a.kind == JobAction.Kind.complete);
}

version (unittest)
{
    /// A fake job API on its own thread. Hands out `total` jobs (retries 3;
    /// every 10th has variable `boom`), long-poll-free; answers completion
    /// and failure. Once every job is completed or failed it sends a summary
    /// on `done`: "completed failed maxOutstanding badFailures", where a bad
    /// failure is one without retries 2 and a message. It serves until
    /// `quit` gets a value. The port goes out first on `port`.
    private void fakeJobServer(int total, Chan!int port, Chan!string done, Chan!int quit)
    {
        fakeJobServerWith(total, 0, port, done, quit);
    }

    /// `fakeJobServer` answering every request `latencyMs` late (without
    /// holding up the others), like an engine behind a slow link. The
    /// summary gets a fifth field: the connections it accepted.
    private void fakeJobServerWith(int total, long latencyMs, Chan!int port, Chan!string done, Chan!int quit)
    {
        import camunda.safeio : monoNowMs;
        static struct Reply { size_t conn; long due; string text; }
        Reply[] replies;
        int accepted;
        import std.algorithm.comparison : max, min;
        import std.algorithm.searching : canFind, startsWith;
        import std.conv : to;
        import std.format : format;
        import std.socket : TcpSocket, InternetAddress, Socket, SocketSet, SocketOption, SocketOptionLevel;
        import std.string : indexOf, strip, toLower;
        import core.time : msecs;
        auto listener = new TcpSocket();
        scope (exit) listener.close();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(64);
        port.put((cast(InternetAddress) listener.localAddress).port);
        Socket[] conns;
        string[] pending;
        int handedOut, completed, failed, maxOutstanding, badFailures;
        bool reported;
        auto set = new SocketSet();
        int q;
        while (!quit.tryTake(q))
        {
            set.reset();
            set.add(listener);
            foreach (c; conns) set.add(c);
            // Send the replies that are due.
            Reply[] later;
            foreach (r; replies)
                if (r.due <= monoNowMs) conns[r.conn].send(r.text);
                else later ~= r;
            replies = later;
            if (Socket.select(set, null, null, (replies.length ? 1 : 50).msecs) <= 0) continue;
            if (set.isSet(listener))
            {
                accepted++;
                conns ~= listener.accept();
                pending ~= "";
            }
            foreach (i, c; conns)
            {
                if (!set.isSet(c)) continue;
                ubyte[8192] chunk;
                const n = c.receive(chunk[]);
                if (n <= 0) continue;
                pending[i] ~= cast(const(char)[]) chunk[0 .. n];
                for (;;)
                {
                    const end = pending[i].indexOf("\r\n\r\n");
                    if (end < 0) break;
                    const head = pending[i][0 .. end + 4];
                    size_t bodyLen;
                    const cl = head.toLower.indexOf("\r\ncontent-length:");
                    if (cl >= 0)
                    {
                        auto rest = head[cl + 17 .. $];
                        bodyLen = rest[0 .. rest.indexOf("\r\n")].strip.to!size_t;
                    }
                    if (pending[i].length < head.length + bodyLen) break;
                    const body_ = pending[i][head.length .. head.length + bodyLen];
                    pending[i] = pending[i][head.length + bodyLen .. $];
                    string reply = "{}";
                    if (head.startsWith("POST /v2/jobs/activation "))
                    {
                        const want = parseJSON(body_)["maxJobsToActivate"].integer.to!int;
                        string[] jobs;
                        foreach (_; 0 .. min(want, total - handedOut))
                        {
                            handedOut++;
                            jobs ~= format(`{"jobKey":"%d","type":"t","retries":3,"variables":{"boom":%s}}`,
                                handedOut, handedOut % 10 == 0 ? "true" : "false");
                        }
                        import std.array : join;
                        reply = `{"jobs":[` ~ jobs.join(",") ~ `]}`;
                    }
                    else if (head.canFind("/completion "))
                        completed++;
                    else if (head.canFind("/failure "))
                    {
                        failed++;
                        auto f = parseJSON(body_);
                        if (!("retries" in f) || f["retries"].integer != 2 || !("errorMessage" in f))
                            badFailures++;
                    }
                    maxOutstanding = max(maxOutstanding, handedOut - completed - failed);
                    replies ~= Reply(i, monoNowMs + latencyMs,
                        format("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
                        reply.length, reply));
                    if (!reported && completed + failed == total)
                    {
                        reported = true;
                        done.put(format("%d %d %d %d %d", completed, failed, maxOutstanding, badFailures, accepted));
                    }
                }
            }
        }
        foreach (c; conns) c.close();
    }

    /// Handlers running right now, and the most seen at once.
    private final class Gauge
    {
        import camunda.safeio : Lock;
        private Lock lock;
        private int now, peak_;
        this() { lock = new Lock; }
        void enter()
        {
            lock.run({
                now++;
                if (now > peak_) peak_ = now;
            });
        }
        void exit() { lock.run({ now--; }); }
        int peak() const { return lock.run(() => peak_); }
    }

    private JobAction gaugedHandler(Job job, ThreadSafe!Gauge gauge)
    {
        gauge.get.enter();
        scope (exit) gauge.get.exit();
        job.clock.sleep(5);
        if (job.variables["boom"].boolean) throw new Exception("boom");
        return JobAction.complete();
    }

    private void stopWhenDone(Chan!string done, Chan!string relay, ThreadSafe!WorkerControl ctl)
    {
        string summary;
        done.take(summary);
        ctl.get.stop();
        relay.put(summary);
    }
}

// The worker holds at most maxJobsActive jobs, handles them on its handler
// threads in parallel, completes them all, and fails a job whose handler
// throws with one retry fewer.
unittest
{
    import std.conv : to;
    import std.format : format;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto relay = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServer, 200, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(8).threads(4));
    worker.config.pollIntervalMs = 10;
    auto stopper = spawn(&stopWhenDone, done, relay, worker.control);
    // Gauge takes its lock in every method.
    auto gauge = ThreadSafe!Gauge.assumeThreadSafe(new Gauge);
    worker.run(&gaugedHandler, gauge);
    stopper.join();
    string summary;
    relay.take(summary);
    int completed, failed, maxOutstanding, badFailures;
    import std.format : formattedRead;
    auto fields = summary;
    fields.formattedRead("%d %d %d %d", completed, failed, maxOutstanding, badFailures);
    assert(completed == 180 && failed == 20, summary);
    assert(badFailures == 0, summary);
    assert(maxOutstanding <= 8, "held more than maxJobsActive: " ~ summary);
    const int peak = gauge.get.peak;
    assert(peak >= 2 && peak <= 4, format("handler concurrency %d, want 2..4", peak));
    const s = worker.stats;
    assert(s.completed == 180 && s.failed == 20 && s.handlerExceptions == 20, format("%s", s));
    assert(s.activated == 200 && s.actionFailures == 0, format("%s", s));
}

version (unittest)
{
    private JobAction sleepyHandler(Job job, long sleepMs)
    {
        job.clock.sleep(sleepMs);
        return JobAction.complete();
    }

    /// Run `total` jobs of `sleepMs` work each through a worker against a
    /// fake engine answering `latencyMs` late. Returns the elapsed time,
    /// the connections the engine accepted, the connections the client's
    /// engine opened, and the handler pool's peak.
    private long[4] timedRun(int total, long latencyMs, int maxJobs, int threads, long sleepMs,
        int maxConnections = 16)
    {
        import camunda.safeio : monoNowMs;
        import std.conv : to;
        import std.format : formattedRead;
        auto port = Chan!int.make;
        auto done = Chan!string.make;
        auto relay = Chan!string.make;
        auto quit = Chan!int.make;
        auto server = spawn(&fakeJobServerWith, total, latencyMs, port, done, quit);
        scope (exit) { quit.put(1); server.join(); }
        int p;
        port.take(p);
        auto client = CamundaClient.fromEnv([
            "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
            "CAMUNDA_AUTH_STRATEGY": "NONE",
            "CAMUNDA_SDK_HTTP_MAX_CONNECTIONS": maxConnections.to!string,
        ]);
        auto worker = client.createJobWorker(
            JobWorkerConfig.create("t").maxJobs(maxJobs).threads(threads).coreThreads(threads));
        worker.config.pollIntervalMs = 10;
        auto stopper = spawn(&stopWhenDone, done, relay, worker.control);
        const start = monoNowMs;
        worker.run(&sleepyHandler, sleepMs);
        const elapsed = monoNowMs - start;
        stopper.join();
        string summary;
        relay.take(summary);
        int completed, failed, maxOutstanding, badFailures, accepted;
        summary.formattedRead("%d %d %d %d %d", completed, failed, maxOutstanding, badFailures, accepted);
        assert(completed == total && failed == 0, summary);
        assert(worker.stats.completed == total && worker.stats.actionFailures == 0);
        return [elapsed, accepted, client.transport.engine.connectionsOpened, worker.pool.peak];
    }
}

// A worker with 200+ handler threads keeps its engine connections (and so
// its file descriptors) bounded by the client's connection limit, not by
// the thread count (camunda/orchestration-cluster-api-dlang#54).
unittest
{
    import std.format : format;
    const r = timedRun(2_000, 0, 512, 256, 5);
    // The connection limit (16, CAMUNDA_SDK_HTTP_MAX_CONNECTIONS) plus the
    // activation long poll.
    enum bound = 16 + 1;
    assert(r[3] >= 200, format("pool peaked at %s threads, want 200+", r[3]));
    assert(r[1] <= bound, format("engine accepted %s connections from %s handler threads", r[1], r[3]));
    assert(r[2] <= bound, format("client opened %s connections", r[2]));
}

// 2 ms of engine latency does not lower the worker's throughput: engine
// calls overlap on the I/O thread instead of each blocking a handler
// thread (camunda/orchestration-cluster-api-dlang#54).
unittest
{
    import std.format : format;
    // Handler work (1 ms) is smaller than the engine latency, so a design
    // where each completion blocks a handler thread would pay the latency
    // on every job: 2_000 x 2 ms / 16 threads = 250 ms extra. The
    // tolerance below sits well under that penalty, so the test goes red
    // if completions block handler threads. HTTP/1.1 answers one request
    // per connection at a time, so the pool (32 connections) must cover
    // the request rate times the latency; maxJobs covers the jobs held
    // while their completion is in flight.
    timedRun(200, 0, 512, 16, 1, 32);
    const fast = timedRun(2_000, 0, 512, 16, 1, 32)[0];
    const slow = timedRun(2_000, 2, 512, 16, 1, 32)[0];
    assert(slow <= fast + fast / 4 + 60, format("2 ms latency: %s ms, none: %s ms", slow, fast));
}

// Explicit settings win over CAMUNDA_WORKER_* defaults; unset ones take them.
unittest
{
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:1",
        "CAMUNDA_WORKER_MAX_CONCURRENT_JOBS": "5",
        "CAMUNDA_WORKER_TIMEOUT": "7000",
    ]);
    auto explicit = client.createJobWorker(JobWorkerConfig.create("t").maxJobs(8).timeoutMs(9000));
    assert(explicit.config.maxJobsActive == 8 && explicit.config.jobTimeoutMs == 9000);
    auto fromEnv = client.createJobWorker(JobWorkerConfig.create("t"));
    assert(fromEnv.config.maxJobsActive == 5 && fromEnv.config.jobTimeoutMs == 7000);
    assert(fromEnv.config.requestTimeoutMs == 10_000 && fromEnv.config.workerName == "d-sdk-worker");
    auto bare = new JobWorker(client, JobWorkerConfig.create("t"));
    import std.algorithm.comparison : min;
    import std.parallelism : totalCPUs;
    assert(bare.config.maxJobsActive == 32 && bare.config.effectiveThreads == min(32, 4 * totalCPUs));
}

// maxJobsActive outside the slot contract's 1 .. maxSlots is rejected, not clamped.
unittest
{
    import std.exception : assertThrown;
    import camunda.contract : maxSlots;
    auto client = CamundaClient.fromEnv(["CAMUNDA_REST_ADDRESS": "http://127.0.0.1:1"]);
    assert(client.createJobWorker(JobWorkerConfig.create("t").maxJobs(maxSlots)).config.maxJobsActive == maxSlots);
    assertThrown!ConfigException(client.createJobWorker(JobWorkerConfig.create("t").maxJobs(maxSlots + 1)));
    assertThrown!ConfigException(client.createJobWorker(JobWorkerConfig.create("t").maxJobs(-1)));
}

version (unittest)
{
    /// After `done`, wait (up to 5 s) for the pool to shrink back to its
    /// core, then stop the worker and relay the summary and the pool size.
    private void stopWhenIdle(Chan!string done, Chan!string relay, ThreadSafe!WorkerControl ctl, int core)
    {
        import camunda.clock : LiveClock;
        import std.format : format;
        string summary;
        done.take(summary);
        auto clock = new LiveClock;
        const deadline = clock.nowMs + 5_000;
        while (ctl.get.pool.live > core && clock.nowMs < deadline) clock.sleep(10);
        const p = ctl.get.pool;
        ctl.get.stop();
        relay.put(format("%s|%d", summary, p.live));
    }
}

// The handler pool starts at its core, grows to the maximum under load,
// never exceeds it, and retires the extra threads after idling.
unittest
{
    import std.conv : to;
    import std.format : format;
    import std.string : split;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto relay = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServer, 200, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(8).threads(4).coreThreads(1).idleTimeoutMs(100));
    worker.config.pollIntervalMs = 10;
    assert(worker.config.effectiveCoreThreads == 1);
    auto stopper = spawn(&stopWhenIdle, done, relay, worker.control, 1);
    // Gauge takes its lock in every method.
    auto gauge = ThreadSafe!Gauge.assumeThreadSafe(new Gauge);
    worker.run(&gaugedHandler, gauge);
    stopper.join();
    string summary;
    relay.take(summary);
    const parts = summary.split("|");
    const pool = worker.pool;
    assert(pool.peak == 4, format("pool peaked at %s, want 4: %s", pool, summary));
    assert(parts[1] == "1", format("pool did not shrink to its core: %s", summary));
    assert(pool.retired >= 3 && pool.spawned == 1 + pool.retired, format("%s", pool));
    assert(gauge.get.peak <= 4, format("handler concurrency %d > 4", gauge.get.peak));
    assert(pool.live == 0, "threads still counted after run returned");
}

unittest
{
    auto cfg = JobWorkerConfig.create("t").maxJobs(32);
    assert(cfg.effectiveCoreThreads == 2 && cfg.effectiveIdleTimeoutMs == 30_000);
    assert(cfg.threads(1).effectiveCoreThreads == 1);
    assert(cfg.threads(8).coreThreads(20).effectiveCoreThreads == 8);
    assert(cfg.idleTimeoutMs(500).effectiveIdleTimeoutMs == 500);
}

version (unittest)
{
    /// Job "4" finishes at once; the others block until `gate` opens.
    private JobAction gatedHandler(Job job, Chan!int gate)
    {
        if (job.key != "4")
        {
            int g;
            gate.take(g);
            gate.put(g); // let the next blocked handler through
        }
        return JobAction.complete();
    }

    /// Wait (up to 5 s) for the pool to shrink to `want` while three jobs
    /// stay blocked, record the size, then open `gate` and stop when done.
    private void releaseWhenShrunk(Chan!string done, Chan!int gate, Chan!int relay,
        ThreadSafe!WorkerControl ctl, int want)
    {
        import camunda.clock : LiveClock;
        auto clock = new LiveClock;
        const deadline = clock.nowMs + 5_000;
        while (ctl.get.pool.peak < 4 && clock.nowMs < deadline) clock.sleep(5);
        while (ctl.get.pool.live > want && clock.nowMs < deadline) clock.sleep(10);
        relay.put(ctl.get.pool.live);
        gate.put(1);
        string summary;
        done.take(summary);
        ctl.get.stop();
    }
}

// An idle thread retires after the idle timeout even while the other
// threads stay busy and too little capacity is free to activate again.
unittest
{
    import std.conv : to;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto gate = Chan!int.make;
    auto relay = Chan!int.make;
    auto server = spawn(&fakeJobServer, 4, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(4).threads(4).coreThreads(1).idleTimeoutMs(100));
    worker.config.pollIntervalMs = 10;
    auto stopper = spawn(&releaseWhenShrunk, done, gate, relay, worker.control, 3);
    worker.run(&gatedHandler, gate);
    stopper.join();
    int live;
    relay.take(live);
    assert(live == 3, "idle thread did not retire under partial occupancy: " ~ live.to!string);
}

version (unittest)
{
    /// A clock that moves only when someone sleeps on it (each sleep also
    /// yields 1 ms of real time). Safe to share between threads.
    private final class SleepDrivenClock : Clock
    {
        import camunda.safeio : Lock, sleepMs;
        private Lock lock;
        private long mono;
        this() { lock = new Lock; }
        long nowMs() const { return lock.run(() => mono); }
        long nowWallMs() const { return nowMs; }
        void sleep(long durationMs)
        {
            const d = durationMs < 0 ? 0 : durationMs;
            lock.run({ mono += d; });
            sleepMs(1);
        }
    }
}

// The idle-retirement wait under partial occupancy follows the injected
// clock: with a clock that only advances on sleep, the idle thread still
// retires while three jobs stay blocked.
unittest
{
    import camunda.transport : CamundaOptions;
    import std.conv : to;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto gate = Chan!int.make;
    auto relay = Chan!int.make;
    auto server = spawn(&fakeJobServer, 4, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    CamundaOptions o;
    o.config = [
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ];
    auto client = CamundaClient.create(o.withClock(new SleepDrivenClock));
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(4).threads(4).coreThreads(1).idleTimeoutMs(100));
    worker.config.pollIntervalMs = 10;
    auto stopper = spawn(&releaseWhenShrunk, done, gate, relay, worker.control, 3);
    worker.run(&gatedHandler, gate);
    stopper.join();
    int live;
    relay.take(live);
    assert(live == 3, "idle thread did not retire on the injected clock: " ~ live.to!string);
}

version (unittest)
{
    /// Every 10th job's handler dies with an `Error`, the rest complete.
    private JobAction dyingHandler(Job job, int unused)
    {
        if (job.variables["boom"].boolean) throw new Error("handler thread dies");
        return JobAction.complete();
    }

    /// Stop the worker once `want` jobs are completed or aborted (or 10 s pass).
    private void stopWhenSettled(ThreadSafe!WorkerControl ctl, long want)
    {
        import camunda.safeio : sleepMs;
        foreach (_; 0 .. 2000)
        {
            const s = ctl.get.stats;
            if (s.completed + s.handlerAborts >= want) break;
            sleepMs(5);
        }
        ctl.get.stop();
    }

    /// A gate the handler waits on, and a channel it reports each run on.
    struct Gated { Chan!int gate; Chan!int ran; }

    /// Report the run on `g.ran`, block until `g.gate` opens, then leave the job.
    private JobAction countingStuckHandler(Job job, Gated g)
    {
        g.ran.put(1);
        int v;
        g.gate.take(v);
        return JobAction.leave();
    }

    /// Block until `gate` opens, then leave the job.
    private JobAction stuckHandler(Job job, Chan!int gate)
    {
        int v;
        gate.take(v);
        return JobAction.leave();
    }

    /// Stop the worker once it activated a job.
    private void stopAfter(ThreadSafe!WorkerControl ctl, long ms)
    {
        import camunda.safeio : sleepMs;
        sleepMs(ms);
        ctl.get.stop();
    }

    private JobAction slowActivationHandler(Job job) { return JobAction.complete(); }

    private void stopWhenActivated(ThreadSafe!WorkerControl ctl)
    {
        import camunda.safeio : sleepMs;
        foreach (_; 0 .. 2000)
        {
            if (ctl.get.stats.activated > 0) break;
            sleepMs(5);
        }
        ctl.get.stop();
    }
}

// A handler thread that dies with an Error holding a job does not hang
// `stop`: its slot is freed, the pool replaces the thread, and the job is
// counted as left and as a handler abort.
unittest
{
    import std.conv : to;
    import std.format : format;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServer, 20, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(4).threads(2).coreThreads(2));
    worker.config.pollIntervalMs = 10;
    auto stopper = spawn(&stopWhenSettled, worker.control, 20L);
    worker.run(&dyingHandler, 0);
    stopper.join();
    const s = worker.stats;
    assert(s.completed == 18 && s.handlerAborts == 2 && s.left == 2, format("%s", s));
    assert(s.unaccounted == 0, format("%s", s));
    assert(worker.pool.live == 0, format("%s", worker.pool));
}

// Shutdown is bounded: a handler that never returns does not hang `run`
// past the shutdown timeout, and the job it holds is reported.
unittest
{
    import std.conv : to;
    import std.format : format;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServer, 1, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(1).threads(1).shutdownTimeout(200));
    worker.config.pollIntervalMs = 10;
    auto gate = Chan!int.make;
    auto stopper = spawn(&stopWhenActivated, worker.control);
    worker.run(&stuckHandler, gate);
    stopper.join();
    // Let the detached handler thread end before the process does.
    gate.put(1);
    import camunda.safeio : sleepMs;
    sleepMs(200);
    const s = worker.stats;
    assert(s.activated == 1 && s.unaccounted == 1, format("%s", s));
}

// Jobs still queued behind a stuck handler when the shutdown timeout runs
// out are discarded: a late handler does not run them after `run` returned.
unittest
{
    import std.conv : to;
    import std.format : format;
    import camunda.safeio : sleepMs;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServer, 2, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(2).threads(1).coreThreads(1).shutdownTimeout(200));
    worker.config.pollIntervalMs = 10;
    Gated g = Gated(Chan!int.make, Chan!int.make);
    auto stopper = spawn(&stopWhenActivated, worker.control);
    worker.run(&countingStuckHandler, g);
    stopper.join();
    g.gate.put(1);
    g.gate.put(1);
    sleepMs(200);
    int ran, v;
    while (g.ran.tryTake(v)) ran++;
    const s = worker.stats;
    assert(s.activated == 2 && s.unaccounted == 2, format("%s", s));
    assert(ran == 1, format("a queued job ran after shutdown (%s runs)", ran));
}

// With several handler threads, no queued job runs after a shutdown timeout,
// even when a released handler takes the next ticket.
unittest
{
    import std.conv : to;
    import std.format : format;
    import camunda.safeio : sleepMs;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServer, 3, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(3).threads(2).coreThreads(2).shutdownTimeout(200));
    worker.config.pollIntervalMs = 10;
    Gated g = Gated(Chan!int.make, Chan!int.make);
    auto stopper = spawn(&stopWhenActivated, worker.control);
    worker.run(&countingStuckHandler, g);
    stopper.join();
    foreach (_; 0 .. 3) g.gate.put(1);
    sleepMs(200);
    int ran, v;
    while (g.ran.tryTake(v)) ran++;
    const s = worker.stats;
    assert(s.activated == 3 && s.unaccounted == 3, format("%s", s));
    assert(ran <= 2, format("a queued job ran after shutdown (%s runs)", ran));
}

// A shutdown timeout that runs out during an activation long poll does not
// wait for it, and the request is counted, not silently dropped.
unittest
{
    import std.conv : to;
    import std.format : format;
    import camunda.safeio : monoNowMs;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServerWith, 0, 3_000L, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(1).threads(1).shutdownTimeout(100));
    auto stopper = spawn(&stopAfter, worker.control, 200L);
    const started = monoNowMs;
    worker.run(&slowActivationHandler);
    stopper.join();
    const s = worker.stats;
    assert(monoNowMs - started < 2_500, format("run waited for the activation: %s", s));
    assert(s.activated == 0 && s.abandonedActivations == 1 && s.unaccounted == 0, format("%s", s));
}

// `stop` is seen while the worker idles between activations: a long poll
// interval does not hold up shutdown.
unittest
{
    import std.conv : to;
    import std.format : format;
    import camunda.safeio : monoNowMs;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServer, 0, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(1).threads(1).shutdownTimeout(200));
    worker.config.pollIntervalMs = 60_000;
    auto stopper = spawn(&stopAfter, worker.control, 300L);
    const started = monoNowMs;
    worker.run(&slowActivationHandler);
    stopper.join();
    assert(monoNowMs - started < 2_000, format("idle worker ignored stop: %s", worker.stats));
}

// After a shutdown timeout, running the worker again processes jobs: the
// abandonment belongs to the run that timed out, not to the next one.
unittest
{
    import std.conv : to;
    import std.format : format;
    import camunda.safeio : sleepMs;
    auto port = Chan!int.make;
    auto done = Chan!string.make;
    auto quit = Chan!int.make;
    auto server = spawn(&fakeJobServer, 2, port, done, quit);
    scope (exit) { quit.put(1); server.join(); }
    int p;
    port.take(p);
    auto client = CamundaClient.fromEnv([
        "CAMUNDA_REST_ADDRESS": "http://127.0.0.1:" ~ p.to!string,
        "CAMUNDA_AUTH_STRATEGY": "NONE",
    ]);
    auto worker = client.createJobWorker(
        JobWorkerConfig.create("t").maxJobs(1).threads(1).shutdownTimeout(200));
    worker.config.pollIntervalMs = 10;
    auto gate = Chan!int.make;
    auto stopper = spawn(&stopWhenActivated, worker.control);
    worker.run(&stuckHandler, gate);
    stopper.join();
    assert(worker.control.get.abandoned);
    auto again = spawn(&stopWhenCompleted, worker.control);
    worker.run(&slowActivationHandler);
    again.join();
    gate.put(1);
    sleepMs(100);
    const s = worker.stats;
    assert(!worker.control.get.abandoned, format("%s", s));
    assert(s.completed == 1, format("the restarted worker ran no job: %s", s));
}

private
{
    void stopWhenCompleted(ThreadSafe!WorkerControl ctl)
    {
        import camunda.safeio : sleepMs;
        foreach (_; 0 .. 1000)
        {
            if (ctl.get.stats.completed > 0) break;
            sleepMs(5);
        }
        ctl.get.stop();
    }
}
