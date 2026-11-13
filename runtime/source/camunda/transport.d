/// The shared HTTP transport: config, auth, retry, backpressure, TLS.
///
/// Spec-agnostic. `CamundaClient` (the typed SDK) and generic consumers such
/// as d8ctl both send every request through here, so `CAMUNDA_*` semantics,
/// OAuth, retry and backpressure behave identically.
module camunda.transport;

@safe:

import camunda.auth;
import camunda.backpressure;
import camunda.clock;
import camunda.config;
import camunda.errors;
import camunda.http;
import camunda.jsonx;
import camunda.retry;
import camunda.version_ : sdkUserAgent;
import std.json;

/// Options for constructing a `Transport` (or a `CamundaClient`).
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

/// Generic, spec-agnostic Camunda REST transport.

/// Which spec server an operation is resolved against. Most operations use the
/// top-level `{schema}://{host}:{port}/v2`; cluster-admin operations
/// (`/cluster/v2/...`) declare the bare root `{schema}://{host}:{port}`.
/// (camunda/orchestration-cluster-api-dlang#6)
enum ServerBase
{
    api,
    root,
}

/// `restAddress` without its trailing `/v2` (and slashes): the bare-root server.
string rootAddress(string restAddress) pure
{
    auto a = restAddress;
    while (a.length && a[$ - 1] == '/') a = a[0 .. $ - 1];
    if (a.length >= 3 && a[$ - 3 .. $] == "/v2") a = a[0 .. $ - 3];
    return a;
}

unittest
{
    assert(rootAddress("http://localhost:8080/v2") == "http://localhost:8080");
    assert(rootAddress("https://z.example/v2/") == "https://z.example");
    assert(rootAddress("https://gw.example/base") == "https://gw.example/base");
}

final class Transport
{
    private CamundaConfig _config;
    private Authentication _auth;
    private Clock _clock;
    private BackpressureManager _bp;
    private string _userAgent = sdkUserAgent;

    this(CamundaOptions options)
    {
        _config = options.config is null
            ? CamundaConfig.fromEnv()
            : CamundaConfig.fromEnv(options.config);
        _clock = options.clock is null ? liveClock() : options.clock;
        _auth = new Authentication(_config, _clock);
        _bp = new BackpressureManager(_config.backpressureProfile, _clock);
    }

    static Transport fromEnv()
    {
        return new Transport(CamundaOptions.create);
    }

    static Transport fromEnv(string[string] overrides)
    {
        CamundaOptions o;
        o.config = overrides;
        return new Transport(o);
    }

    const(CamundaConfig) config() const { return _config; }
    Clock clock() { return _clock; }
    Authentication auth() { return _auth; }
    BackpressureState backpressureState() const { return _bp.state(); }

    /// Override the `User-Agent` (e.g. a CLI identifying itself).
    void userAgent(string ua) { _userAgent = ua; }
    string userAgent() const { return _userAgent; }

    JSONValue requestJson(string method, string path, JSONValue body_, string[string] query,
        ServerBase server = ServerBase.api)
    {
        auto res = guardedRequest(method, path, body_, query, server);
        if (!res.body_.length) return emptyObject();
        try return parseJSON(res.body_);
        catch (Exception e)
            throw new SerializationException("failed to parse JSON response: " ~ e.msg, __FILE__, __LINE__, e);
    }

    void requestVoid(string method, string path, JSONValue body_, string[string] query,
        ServerBase server = ServerBase.api)
    {
        guardedRequest(method, path, body_, query, server);
    }

    string requestText(string method, string path, JSONValue body_, string[string] query,
        ServerBase server = ServerBase.api)
    {
        return guardedRequest(method, path, body_, query, server).body_;
    }

    immutable(ubyte)[] requestBytes(string method, string path, JSONValue body_, string[string] query,
        ServerBase server = ServerBase.api)
    {
        return guardedRequest(method, path, body_, query, server).bytes;
    }

    /// Send a pre-built raw body (e.g. multipart/form-data) with auth,
    /// retry and backpressure. Returns the 2xx response.
    HttpResponse requestRaw(string method, string path, string contentType, const(ubyte)[] rawBody,
        ServerBase server = ServerBase.api, string[string] query = null)
    {
        _bp.acquire();
        scope (exit) _bp.release();
        HttpResponse res;
        try
        {
            res = withRetry!HttpResponse(_config.retry, _clock, {
                HttpRequest req = baseRequest(method, path, query, server);
                req.contentType = contentType;
                req.rawBody = rawBody.dup;
                return send(req);
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

    private HttpResponse guardedRequest(string method, string path, JSONValue body_, string[string] query,
        ServerBase server)
    {
        _bp.acquire();
        scope (exit) _bp.release();
        HttpResponse res;
        try
        {
            res = withRetry!HttpResponse(_config.retry, _clock, {
                HttpRequest req = baseRequest(method, path, query, server);
                if (shouldSendJsonBody(method, body_))
                {
                    req.body_ = body_.toString;
                    req.contentType = "application/json";
                }
                return send(req);
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

    /// Base URL for `server`: the configured REST address (`…/v2`), or its
    /// root for operations whose spec declares the bare-root server.
    string baseAddress(ServerBase server = ServerBase.api) const
    {
        return server == ServerBase.root ? rootAddress(_config.restAddress) : _config.restAddress;
    }

    private HttpRequest baseRequest(string method, string path, string[string] query, ServerBase server)
    {
        HttpRequest req;
        req.method = method;
        req.url = joinUrl(baseAddress(server), path, query);
        req.headers = _auth.headers();
        req.headers["Accept"] = "application/json, */*";
        req.headers["User-Agent"] = _userAgent;
        req.certPath = _config.tls.certPath;
        req.keyPath = _config.tls.keyPath;
        req.caPath = _config.tls.caPath;
        req.keyPassphrase = _config.tls.keyPassphrase;
        return req;
    }

    private static HttpResponse send(ref HttpRequest req)
    {
        auto res = perform(req);
        if (res.status >= 200 && res.status < 300) return res;
        throw new ApiException(res.status, res.body_);
    }
}

/// An empty JSON object is a present body (`{}`), not an absent one.
/// `JSONValue.init` / `null` still means "no body". See #1.
bool shouldSendJsonBody(string method, const JSONValue body_)
{
    if (method == "GET") return false;
    return body_.type != JSONType.null_;
}

unittest
{
    assert(!shouldSendJsonBody("GET", parseJSON("{}")));
    assert(!shouldSendJsonBody("POST", JSONValue.init));
    assert(!shouldSendJsonBody("POST", JSONValue(null)));
    assert(shouldSendJsonBody("POST", parseJSON("{}")));
    assert(shouldSendJsonBody("PUT", parseJSON(`{"a":1}`)));
    assert(shouldSendJsonBody("PATCH", parseJSON("[]")));
    assert(parseJSON("{}").toString == "{}");
}

unittest
{
    auto t = new Transport(CamundaOptions.create
        .withKey("CAMUNDA_REST_ADDRESS", "http://localhost:8080")
        .withKey("CAMUNDA_AUTH_STRATEGY", "NONE"));
    assert(t.config.restAddress == "http://localhost:8080/v2");
    assert(t.config.authStrategy == AuthStrategy.none);
    assert(t.userAgent.length > "camunda-orchestration-sdk-d/".length);
    t.userAgent = "d8ctl/1";
    assert(t.userAgent == "d8ctl/1");
}

unittest
{
    // Cluster-admin operations resolve against the bare root (#6).
    auto t = new Transport(CamundaOptions.create
        .withKey("CAMUNDA_REST_ADDRESS", "http://localhost:8080")
        .withKey("CAMUNDA_AUTH_STRATEGY", "NONE"));
    assert(joinUrl(t.baseAddress(ServerBase.root), "/cluster/v2/status") == "http://localhost:8080/cluster/v2/status");
    assert(joinUrl(t.baseAddress(), "/topology") == "http://localhost:8080/v2/topology");
}
