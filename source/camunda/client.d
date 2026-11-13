/// The primary entry point of the SDK.
module camunda.client;

@safe:

import camunda.auth;
import camunda.backpressure;
import camunda.clock;
import camunda.config;
import camunda.errors;
import camunda.eventual;
import camunda.generated;
import camunda.jsonx;
import camunda.safeio : readBytes;
import camunda.transport;
import camunda.version_ : sdkUserAgent, sdkVersion;
import camunda.worker;
import std.json;
import std.path : baseName;

public import camunda.transport : CamundaOptions;

/// The Camunda 8 Orchestration Cluster SDK — synchronous client.
///
/// Mixes in the generated flat facade (`GeneratedOperations`) so every REST
/// operation is a method on this type. Curated helpers (`topology`,
/// `deployResources`, `createJobWorker`, `eventual`) sit on top.
final class CamundaClient
{
    mixin GeneratedOperations;

    private Transport _t;

    this(CamundaOptions options)
    {
        _t = new Transport(options);
    }

    static CamundaClient fromEnv()
    {
        return new CamundaClient(CamundaOptions.create);
    }

    static CamundaClient fromEnv(string[string] overrides)
    {
        CamundaOptions o;
        o.config = overrides;
        return new CamundaClient(o);
    }

    static CamundaClient create(CamundaOptions options)
    {
        return new CamundaClient(options);
    }

    /// The shared transport (also usable on its own via `camunda.runtime`).
    Transport transport() { return _t; }
    const(CamundaConfig) config() const { return _t.config; }
    Clock clock() { return _t.clock; }
    Authentication auth() { return _t.auth; }
    BackpressureState backpressureState() const { return _t.backpressureState; }

    /// Fetch the cluster topology.
    TopologyResponse topology()
    {
        return getTopologyOp();
    }

    /// Deploy one or more resources (BPMN, DMN, forms) from local file paths.
    DeploymentResult deployResources(string[] paths, string tenantId = null)
    {
        if (!paths.length)
            throw new ConfigException("deployResources() requires at least one file path.");
        auto tenant = tenantId.length ? tenantId
            : (config.defaultTenantId.length ? config.defaultTenantId : null);
        return createDeploymentMultipart(paths, tenant);
    }

    /// Poll `op` until it succeeds (retrying 404s) or the timeout elapses.
    T eventual(T)(ConsistencyOptions opts, scope T delegate() @safe op)
    {
        return poll!T(opts, config.eventualPollDefaultMs, _t.clock, op, (const T) => true);
    }

    /// Poll `op` until `predicate` is true.
    T eventual(T)(ConsistencyOptions opts, scope T delegate() @safe op,
        scope bool delegate(const T) @safe predicate)
    {
        return poll!T(opts, config.eventualPollDefaultMs, _t.clock, op, predicate);
    }

    JobWorker createJobWorker(JobWorkerConfig cfg)
    {
        cfg.applyDefaults(config.workerDefaults);
        if (!cfg.tenantIds.length && config.tenantIds.length)
            cfg.tenantIds = config.tenantIds.dup;
        return new JobWorker(this, cfg);
    }

    JobWorkerConfig workerConfig(string jobType)
    {
        return JobWorkerConfig.fromDefaults(jobType, config.workerDefaults);
    }

    // --- transport used by the generated facade --------------------------------

    JSONValue requestJson(string method, string path, JSONValue body_, string[string] query)
    {
        return _t.requestJson(method, path, body_, query);
    }

    void requestVoid(string method, string path, JSONValue body_, string[string] query)
    {
        _t.requestVoid(method, path, body_, query);
    }

    string requestText(string method, string path, JSONValue body_, string[string] query)
    {
        return _t.requestText(method, path, body_, query);
    }

    immutable(ubyte)[] requestBytes(string method, string path, JSONValue body_, string[string] query)
    {
        return _t.requestBytes(method, path, body_, query);
    }

    private DeploymentResult createDeploymentMultipart(string[] paths, string tenantId)
    {
        // Build a multipart/form-data body. Each file is a `resources` part.
        enum boundary = "----camunda-sdk-d-boundary";
        ubyte[] bodyBuf;
        void append(string s) { bodyBuf ~= cast(const(ubyte)[]) s; }
        foreach (p; paths)
        {
            auto name = baseName(p);
            auto bytes = readBytes(p);
            append("--" ~ boundary ~ "\r\n");
            append("Content-Disposition: form-data; name=\"resources\"; filename=\"" ~ name ~ "\"\r\n");
            append("Content-Type: application/octet-stream\r\n\r\n");
            bodyBuf ~= bytes;
            append("\r\n");
        }
        if (tenantId.length)
        {
            append("--" ~ boundary ~ "\r\n");
            append("Content-Disposition: form-data; name=\"tenantId\"\r\n\r\n");
            append(tenantId);
            append("\r\n");
        }
        append("--" ~ boundary ~ "--\r\n");

        auto res = _t.requestRaw("POST", "/deployments", "multipart/form-data; boundary=" ~ boundary, bodyBuf);
        try return DeploymentResult.fromJson(parseJSON(res.body_));
        catch (Exception e)
            throw new SerializationException("failed to parse deployment response: " ~ e.msg, __FILE__, __LINE__, e);
    }
}

unittest
{
    auto c = CamundaClient.create(CamundaOptions.create
        .withKey("CAMUNDA_REST_ADDRESS", "http://localhost:8080")
        .withKey("CAMUNDA_AUTH_STRATEGY", "NONE"));
    assert(c.config.restAddress == "http://localhost:8080/v2");
    assert(c.config.authStrategy == AuthStrategy.none);
    assert(sdkVersion.length > 0);
    assert(sdkUserAgent.length > "camunda-orchestration-sdk-d/".length);
}

unittest
{
    // The generated facade covers the bundled spec (per-operation coverage is
    // gated by scripts/check-example-coverage.py; the count moves with upstream).
    assert(generatedOperationCount > 200);
    assert(generatedSpecHash.length > 0);
}

unittest
{
    auto key = JobKey.tryNew("2251799813653498");
    assert(key.value == "2251799813653498");
    assert(JobKey.isValid("2251799813653498"));
    assert(!JobKey.isValid("not-a-key"));
    bool threw;
    try JobKey.tryNew("nope");
    catch (CamundaKeyError) threw = true;
    assert(threw);
    auto loose = JobKey.assumeExists("anything");
    assert(loose.value == "anything");
}
