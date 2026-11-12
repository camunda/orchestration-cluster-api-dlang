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
import camunda.http;
import camunda.jsonx;
import camunda.retry;
import camunda.safeio : readBytes;
import camunda.worker;
import std.format : format;
import std.json;
import std.path : baseName;

/// Options for constructing a `CamundaClient`.
struct CamundaOptions
{
    string[string] config;
    Clock clock;

    static CamundaOptions create()
    {
        CamundaOptions o;
        return o;
    }

    CamundaOptions withKey(string key, string value)
    {
        config[key] = value;
        return this;
    }

    CamundaOptions withClock(Clock clock)
    {
        this.clock = clock;
        return this;
    }
}

/// The Camunda 8 Orchestration Cluster SDK — synchronous client.
///
/// Mixes in the generated flat facade (`GeneratedOperations`) so every REST
/// operation is a method on this type. Curated helpers (`topology`,
/// `deployResources`, `createJobWorker`, `eventual`) sit on top.
final class CamundaClient
{
    mixin GeneratedOperations;

    private CamundaConfig _config;
    private Authentication _auth;
    private Clock _clock;
    private BackpressureManager _bp;
    private string userAgent = "camunda-orchestration-sdk-d/0.1.0";

    this(CamundaOptions options)
    {
        _config = options.config is null
            ? CamundaConfig.fromEnv()
            : CamundaConfig.fromEnv(options.config);
        _clock = options.clock is null ? liveClock() : options.clock;
        _auth = new Authentication(_config, _clock);
        _bp = new BackpressureManager(_config.backpressureProfile, _clock);
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

    const(CamundaConfig) config() const { return _config; }
    Clock clock() { return _clock; }
    Authentication auth() { return _auth; }
    BackpressureState backpressureState() const { return _bp.state(); }

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
            : (_config.defaultTenantId.length ? _config.defaultTenantId : null);
        return createDeploymentMultipart(paths, tenant);
    }

    /// Poll `op` until it succeeds (retrying 404s) or the timeout elapses.
    T eventual(T)(ConsistencyOptions opts, scope T delegate() @safe op)
    {
        return poll!T(opts, _config.eventualPollDefaultMs, _clock, op, (const T) => true);
    }

    /// Poll `op` until `predicate` is true.
    T eventual(T)(ConsistencyOptions opts, scope T delegate() @safe op,
        scope bool delegate(const T) @safe predicate)
    {
        return poll!T(opts, _config.eventualPollDefaultMs, _clock, op, predicate);
    }

    JobWorker createJobWorker(JobWorkerConfig cfg)
    {
        cfg.applyDefaults(_config.workerDefaults);
        if (!cfg.tenantIds.length && _config.tenantIds.length)
            cfg.tenantIds = _config.tenantIds.dup;
        return new JobWorker(this, cfg);
    }

    JobWorkerConfig workerConfig(string jobType)
    {
        return JobWorkerConfig.fromDefaults(jobType, _config.workerDefaults);
    }

    // --- transport used by the generated facade --------------------------------

    JSONValue requestJson(string method, string path, JSONValue body_, string[string] query)
    {
        auto res = guardedRequest(method, path, body_, query);
        if (!res.body_.length) return emptyObject();
        try return parseJSON(res.body_);
        catch (Exception e)
            throw new SerializationException("failed to parse JSON response: " ~ e.msg, __FILE__, __LINE__, e);
    }

    void requestVoid(string method, string path, JSONValue body_, string[string] query)
    {
        guardedRequest(method, path, body_, query);
    }

    string requestText(string method, string path, JSONValue body_, string[string] query)
    {
        return guardedRequest(method, path, body_, query).body_;
    }

    immutable(ubyte)[] requestBytes(string method, string path, JSONValue body_, string[string] query)
    {
        return guardedRequest(method, path, body_, query).bytes;
    }

    private HttpResponse guardedRequest(string method, string path, JSONValue body_, string[string] query)
    {
        _bp.acquire();
        scope (exit) _bp.release();
        HttpResponse res;
        try
        {
            res = withRetry!HttpResponse(_config.retry, _clock, {
                return sendOnce(method, path, body_, query);
            });
        }
        catch (Exception e)
        {
            if (isBackpressureError(e)) _bp.recordBackpressure();
            throw e;
        }
        _bp.recordHealthyHint();
        return res;
    }

    private HttpResponse sendOnce(string method, string path, JSONValue body_, string[string] query)
    {
        HttpRequest req;
        req.method = method;
        req.url = joinUrl(_config.restAddress, path, query);
        req.headers = _auth.headers();
        req.headers["Accept"] = "application/json, */*";
        req.headers["User-Agent"] = userAgent;
        if (body_.type != JSONType.null_
            && !(body_.type == JSONType.object && body_.objectNoRef.length == 0)
            && method != "GET")
        {
            req.body_ = body_.toString;
            req.contentType = "application/json";
        }
        applyTls(req);
        HttpResponse res;
        try res = perform(req);
        catch (NetworkException e) throw e;
        if (res.status >= 200 && res.status < 300) return res;
        throw new ApiException(res.status, res.body_);
    }

    private void applyTls(ref HttpRequest req)
    {
        req.certPath = _config.tls.certPath;
        req.keyPath = _config.tls.keyPath;
        req.caPath = _config.tls.caPath;
        req.keyPassphrase = _config.tls.keyPassphrase;
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

        _bp.acquire();
        scope (exit) _bp.release();
        auto res = withRetry!HttpResponse(_config.retry, _clock, {
            HttpRequest req;
            req.method = "POST";
            req.url = joinUrl(_config.restAddress, "/deployments");
            req.headers = _auth.headers();
            req.headers["Accept"] = "application/json";
            req.headers["User-Agent"] = userAgent;
            req.contentType = "multipart/form-data; boundary=" ~ boundary;
            req.rawBody = bodyBuf;
            applyTls(req);
            auto r = perform(req);
            if (r.status >= 200 && r.status < 300) return r;
            throw new ApiException(r.status, r.body_);
        });
        _bp.recordHealthyHint();
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
}

unittest
{
    // The generated facade covers every operation in the bundled spec.
    assert(generatedOperationCount == 244);
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
