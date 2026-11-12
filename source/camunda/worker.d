/// Job workers: poll for jobs of a given type, run a handler, apply the result.
module camunda.worker;

@safe:

import camunda.config : WorkerDefaults;
import camunda.errors;
import camunda.generated;
import camunda.jsonx;
import std.json;

/// Configuration for a `JobWorker`.
struct JobWorkerConfig
{
    string jobType;
    int maxJobsToActivate = 32;
    long jobTimeoutMs = 60_000;
    long requestTimeoutMs = 10_000;
    long pollIntervalMs = 250;
    string workerName = "d-sdk-worker";
    string[] fetchVariables;
    string[] tenantIds;
    long startupJitterMaxSeconds;
    bool withLease;
    bool autoComplete = true;

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

    void applyDefaults(const ref WorkerDefaults defaults)
    {
        if (defaults.timeoutMs) jobTimeoutMs = defaults.timeoutMs;
        if (defaults.maxConcurrentJobs) maxJobsToActivate = defaults.maxConcurrentJobs;
        if (defaults.requestTimeoutMs) requestTimeoutMs = defaults.requestTimeoutMs;
        if (defaults.name.length) workerName = defaults.name;
        startupJitterMaxSeconds = defaults.startupJitterMaxSeconds;
    }

    JobWorkerConfig maxJobs(int n) { maxJobsToActivate = n; return this; }
    JobWorkerConfig timeoutMs(long ms) { jobTimeoutMs = ms; return this; }
    JobWorkerConfig name(string n) { workerName = n; return this; }
    JobWorkerConfig variables(string[] names) { fetchVariables = names; return this; }
    JobWorkerConfig tenants(string[] ids) { tenantIds = ids; return this; }
    JobWorkerConfig lease(bool enabled) { withLease = enabled; return this; }
}

/// A job delivered to a worker handler.
struct Job
{
    ActivatedJobResult raw;
    private import camunda.clock : Clock;
    private Clock _clock;

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

/// A continuously-polling job worker.
final class JobWorker
{
    private import camunda.client : CamundaClient;
    private CamundaClient client;
    private JobWorkerConfig config;
    private bool running;

    this(CamundaClient client, JobWorkerConfig config)
    {
        this.client = client;
        this.config = config;
    }

    /// Signal the worker loop to stop after the current iteration.
    void stop() { running = false; }

    /// Run the worker loop until `stop` is called or an unrecoverable error occurs.
    void run(scope JobAction delegate(Job) @safe handler)
    {
        running = true;
        if (config.startupJitterMaxSeconds > 0)
        {
            import camunda.safeio : unitRandom;
            auto jitter = cast(long)(config.startupJitterMaxSeconds * 1000 * unitRandom());
            client.clock.sleep(jitter);
        }
        while (running)
        {
            auto n = pollOnce(handler);
            if (n == 0 && running && config.pollIntervalMs > 0)
                client.clock.sleep(config.pollIntervalMs);
        }
    }

    /// Activate a single batch of jobs and dispatch them to the handler.
    int pollOnce(scope JobAction delegate(Job) @safe handler)
    {
        auto jobs = activate();
        foreach (job; jobs)
        {
            auto action = handler(job);
            apply(job, action);
        }
        return cast(int) jobs.length;
    }

    private Job[] activate()
    {
        auto req = JobActivationRequest.initEmpty();
        req.type(config.jobType);
        req.maxJobsToActivate(config.maxJobsToActivate);
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

        auto result = client.activateJobs(req);
        Job[] out_;
        foreach (raw; result.jobs)
        {
            if (config.withLease && (!raw.has_jobLeaseToken || !raw.jobLeaseToken.value.length))
                throw new LeaseNotHonored(raw.has_jobKey ? raw.jobKey.value : "", "withLease");
            Job j;
            j.raw = raw;
            j._clock = client.clock;
            out_ ~= j;
        }
        return out_;
    }

    private void apply(Job job, JobAction action)
    {
        final switch (action.kind)
        {
        case JobAction.Kind.leave:
            return;
        case JobAction.Kind.complete:
            auto req = JobCompletionRequest.initEmpty();
            if (action.variables.type != JSONType.null_)
                req.variables(action.variables);
            if (job.leaseToken.length)
                req.jobLeaseToken(JobLeaseToken.assumeExists(job.leaseToken));
            client.completeJob(job.raw.jobKey, req);
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
            return;
        }
    }
}

unittest
{
    auto cfg = JobWorkerConfig.create("payment-service").maxJobs(20).name("payment-worker");
    assert(cfg.jobType == "payment-service");
    assert(cfg.maxJobsToActivate == 20);
    assert(cfg.workerName == "payment-worker");
    auto a = JobAction.completeWith(JSONValue(["paid": JSONValue(true)]));
    assert(a.kind == JobAction.Kind.complete);
}
