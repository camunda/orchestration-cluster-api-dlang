/// Job workers: activate jobs of a given type, run a handler on a pool of
/// threads, apply each result.
///
/// The model (as in the other Camunda SDKs): `maxJobsActive` caps the jobs
/// the worker holds at once. The calling thread polls; `handlerThreads`
/// threads run the handler, so up to that many jobs are handled in parallel;
/// whenever enough capacity frees up the worker activates more, sized to the
/// free capacity.
module camunda.worker;

@safe:

import camunda.client : CamundaClient;
import camunda.config : WorkerDefaults;
import camunda.errors;
import camunda.generated;
import camunda.jsonx;
import camunda.safeio : Chan, JoinHandle, ThreadSafe, isSendable, spawn;
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
    /// Threads running the handler; 0 means one per `maxJobsActive`.
    int handlerThreads;
    /// Job lease duration. Default 60 s (`CAMUNDA_WORKER_TIMEOUT`).
    long jobTimeoutMs;
    /// Long-poll timeout of an activation request. Default 10 s
    /// (`CAMUNDA_WORKER_REQUEST_TIMEOUT`).
    long requestTimeoutMs;
    /// Pause after an activation that returned no jobs (for servers that
    /// answer at once rather than long-polling).
    long pollIntervalMs = 250;
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
    JobWorkerConfig threads(int n) { handlerThreads = n; return this; }
    JobWorkerConfig timeoutMs(long ms) { jobTimeoutMs = ms; return this; }
    JobWorkerConfig name(string n) { workerName = n; return this; }
    JobWorkerConfig variables(string[] names) { fetchVariables = names; return this; }
    JobWorkerConfig tenants(string[] ids) { tenantIds = ids; return this; }
    JobWorkerConfig lease(bool enabled) { withLease = enabled; return this; }

    /// Handler threads actually started.
    int effectiveThreads() const
    {
        return handlerThreads > 0 ? handlerThreads : maxJobsActive;
    }
}

/// Counters of a worker's activity so far.
struct WorkerStats
{
    long activated;          /// jobs received from activations
    long completed;          /// completeJob calls that succeeded
    long failed;             /// failJob calls that succeeded (incl. handler exceptions)
    long errored;            /// throwJobError calls that succeeded
    long left;               /// jobs the handler chose to leave
    long handlerExceptions;  /// handler threw; the job was failed with retries - 1
    long actionFailures;     /// a complete/fail/error call itself failed
    long activationFailures; /// activation requests that failed (then backed off)
}

/// A worker's run state, shared by its poller, its handler threads and
/// whoever stops it. Every member is atomic.
final class WorkerControl
{
    import core.atomic : atomicLoad, atomicOp, atomicStore;
    private shared bool stopping_;
    private shared long activated, completed, failed, errored, left,
        handlerExceptions, actionFailures, activationFailures;

    /// Ask the worker to stop: it activates no more jobs, finishes the ones
    /// it holds, and `run` returns (after at most one activation long poll).
    void stop() { atomicStore(stopping_, true); }

    /// Whether `stop` was called.
    bool stopping() const { return atomicLoad(stopping_); }

    /// A snapshot of the counters.
    WorkerStats stats() const
    {
        WorkerStats s;
        s.activated = atomicLoad(activated);
        s.completed = atomicLoad(completed);
        s.failed = atomicLoad(failed);
        s.errored = atomicLoad(errored);
        s.left = atomicLoad(left);
        s.handlerExceptions = atomicLoad(handlerExceptions);
        s.actionFailures = atomicLoad(actionFailures);
        s.activationFailures = atomicLoad(activationFailures);
        return s;
    }

    private void count(string field)(long n = 1)
    {
        atomicOp!"+="(mixin(field), n);
    }

    private void restart() { atomicStore(stopping_, false); }
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

    this(CamundaClient client, JobWorkerConfig config)
    {
        this.client = client;
        WorkerDefaults builtIn;
        config.applyDefaults(builtIn);
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

    /// Run until `stop`: poll on this thread, handle jobs on
    /// `config.effectiveThreads` threads. A handler that throws fails its
    /// job with one retry fewer. Failed activations back off (50 ms up to
    /// 5 s). Rethrows `LeaseNotHonored`, after the jobs already held finish.
    void run(JobHandler handler)
    {
        run(&callPlain, handler);
    }

    /// ditto, passing `context` to every handler call.
    void run(Ctx)(JobAction function(Job, Ctx) @safe handler, Ctx context)
        if (isSendable!Ctx)
    {
        import std.algorithm.comparison : max, min;
        ctl.restart();
        if (config.startupJitterMaxSeconds > 0)
        {
            import camunda.safeio : unitRandom;
            auto jitter = cast(long)(config.startupJitterMaxSeconds * 1000 * unitRandom());
            client.clock.sleep(jitter);
        }
        const cap = max(1, config.maxJobsActive);
        // Activate again once 30% of the capacity is free, as the Java
        // client does: no tiny one-job activations under load.
        const threshold = max(1, (cap * 3 + 9) / 10);
        auto jobs = Chan!string.make;
        auto freed = Chan!int.make;
        JoinHandle[] handlers;
        scope (exit)
        {
            jobs.close();
            foreach (ref h; handlers) h.join();
        }
        foreach (_; 0 .. max(1, config.effectiveThreads))
            handlers ~= spawn(&handlerLoop!Ctx, jobs, freed, client.threadSafe, control, handler, context);

        int held;
        long backoff;
        int one;
        while (!ctl.stopping)
        {
            while (freed.tryTake(one)) held--;
            if (cap - held < threshold)
            {
                freed.take(one); // wait for a handler to finish one
                held--;
                continue;
            }
            ActivatedJobResult[] batch;
            try batch = activate(cap - held);
            catch (LeaseNotHonored e) throw e;
            catch (Exception e)
            {
                ctl.count!"activationFailures";
                backoff = backoff ? min(backoffMaxMs, backoff * 8 / 5) : backoffMinMs;
                client.clock.sleep(backoff);
                continue;
            }
            backoff = 0;
            ctl.count!"activated"(batch.length);
            foreach (raw; batch)
            {
                held++;
                jobs.put(raw.raw.toString());
            }
            if (!batch.length && config.pollIntervalMs > 0 && !ctl.stopping)
                client.clock.sleep(config.pollIntervalMs);
        }
    }

    private static JobAction callPlain(Job job, JobHandler handler)
    {
        return handler(job);
    }

    private ActivatedJobResult[] activate(int count)
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

        auto jobs = client.activateJobs(req).jobs;
        if (config.withLease)
            foreach (raw; jobs)
                if (!raw.has_jobLeaseToken || !raw.jobLeaseToken.value.length)
                    throw new LeaseNotHonored(raw.has_jobKey ? raw.jobKey.value : "", "withLease");
        return jobs;
    }
}

/// One handler thread: take jobs until the channel closes, run the handler,
/// apply its action, and report each finished job on `freed`.
private void handlerLoop(Ctx)(Chan!string jobs, Chan!int freed,
    ThreadSafe!CamundaClient client, ThreadSafe!WorkerControl control,
    JobAction function(Job, Ctx) @safe handler, Ctx context)
{
    auto c = client.get;
    auto ctl = control.get;
    string text;
    while (jobs.take(text))
    {
        scope (exit) freed.put(1);
        Job job;
        job.raw = ActivatedJobResult.fromJson(parseJSON(text));
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
        try apply(c, job, action, ctl);
        catch (Exception e) ctl.count!"actionFailures";
    }
}

private void apply(CamundaClient client, Job job, JobAction action, WorkerControl ctl)
{
    final switch (action.kind)
    {
    case JobAction.Kind.leave:
        ctl.count!"left";
        return;
    case JobAction.Kind.complete:
        auto req = JobCompletionRequest.initEmpty();
        if (action.variables.type != JSONType.null_)
            req.variables(action.variables);
        if (job.leaseToken.length)
            req.jobLeaseToken(JobLeaseToken.assumeExists(job.leaseToken));
        client.completeJob(job.raw.jobKey, req);
        ctl.count!"completed";
        return;
    case JobAction.Kind.fail:
        auto req = JobFailRequest.initEmpty();
        if (action.errorMessage.length) req.errorMessage(action.errorMessage);
        if (action.retries >= 0) req.retries(action.retries);
        if (action.retryBackoffMs > 0) req.retryBackOff(action.retryBackoffMs);
        if (action.variables.type != JSONType.null_)
            req.variables(action.variables);
        if (job.leaseToken.length)
            req.jobLeaseToken(JobLeaseToken.assumeExists(job.leaseToken));
        client.failJob(job.raw.jobKey, req);
        ctl.count!"failed";
        return;
    case JobAction.Kind.error:
        auto req = JobErrorRequest.initEmpty();
        req.errorCode(action.errorCode);
        if (action.errorMessage.length) req.errorMessage(action.errorMessage);
        if (action.variables.type != JSONType.null_)
            req.variables(action.variables);
        if (job.leaseToken.length)
            req.jobLeaseToken(JobLeaseToken.assumeExists(job.leaseToken));
        client.throwJobError(job.raw.jobKey, req);
        ctl.count!"errored";
        return;
    }
}

unittest
{
    auto cfg = JobWorkerConfig.create("payment-service").maxJobs(20).name("payment-worker");
    assert(cfg.jobType == "payment-service");
    assert(cfg.maxJobsActive == 20);
    assert(cfg.effectiveThreads == 20);
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
            if (Socket.select(set, null, null, 50.msecs) <= 0) continue;
            if (set.isSet(listener))
            {
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
                    c.send(format("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
                        reply.length, reply));
                    if (!reported && completed + failed == total)
                    {
                        reported = true;
                        done.put(format("%d %d %d %d", completed, failed, maxOutstanding, badFailures));
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
    assert(bare.config.maxJobsActive == 32 && bare.config.effectiveThreads == 32);
}
