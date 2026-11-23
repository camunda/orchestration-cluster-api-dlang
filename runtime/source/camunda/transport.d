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
    /// Custom headers applied to every API request, on top of (and winning
    /// over) `CAMUNDA_DEFAULT_HEADERS`. A custom `Content-Type` overrides
    /// even the body's default — for a multipart body you must then preserve
    /// the boundary parameter yourself. Values may be secrets: never log
    /// them.
    string[string] headers;

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

    /// Add a custom header sent with every API request (never to the OAuth
    /// token endpoint). Applied last, merged case-insensitively, so it may
    /// replace the SDK's own `Authorization` / `Accept` headers — and even
    /// `Content-Type`: for a multipart body you must then preserve the
    /// boundary parameter yourself. The name must be
    /// an HTTP token and the value free of control characters (horizontal
    /// tab allowed); anything else is a `ConfigException` whose message
    /// names the header but never the value (it may be a secret).
    CamundaOptions withHeader(string name, string value)
    {
        validateHeader(name, value);
        // Replace any existing entry with the same case-insensitive name so
        // the latest call always wins, regardless of capitalization.
        import std.uni : sicmp;
        string[] stale;
        foreach (k; headers.byKey)
            if (sicmp(k, name) == 0) stale ~= k;
        foreach (k; stale)
            headers.remove(k);
        headers[name] = value;
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
    // withHeader: a later call wins regardless of capitalization, both orders.
    auto a = CamundaOptions.create.withHeader("x-api-key", "old").withHeader("X-Api-Key", "new");
    assert(a.headers == ["X-Api-Key": "new"]);
    auto b = CamundaOptions.create.withHeader("X-Api-Key", "old").withHeader("x-api-key", "new");
    assert(b.headers == ["x-api-key": "new"]);
    auto c = CamundaOptions.create.withHeader("X-A", "1").withHeader("X-B", "2");
    assert(c.headers == ["X-A": "1", "X-B": "2"]);
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
    private string[string] _headers;

    this(CamundaOptions options)
    {
        _config = options.config is null
            ? CamundaConfig.fromEnv()
            : CamundaConfig.fromEnv(options.config);
        _clock = options.clock is null ? liveClock() : options.clock;
        _auth = new Authentication(_config, _clock);
        _bp = new BackpressureManager(_config.backpressureProfile, _clock);
        // Programmatic headers win over CAMUNDA_DEFAULT_HEADERS on the same
        // (case-insensitive) name. Validate here too: `options.headers` is a
        // public field, so direct assignment bypasses `withHeader`; every
        // programmatic header must fail closed before reaching curl.
        foreach (k, v; options.headers)
            validateHeader(k, v);
        _headers = mergeHeadersCaseInsensitive(_config.defaultHeaders, options.headers);
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

    /// The custom headers sent with every request (config + programmatic,
    /// already merged). Values may be secrets: never log them.
    const(string[string]) headers() const { return _headers; }

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
        const gated = admit(method, path);
        scope (exit) if (gated) _bp.release();
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

    /// Take a backpressure permit for `method path` unless it is exempt
    /// (see `isBackpressureExempt`). Returns whether a permit was taken, so
    /// the caller releases only what it acquired.
    private bool admit(string method, string path)
    {
        if (isBackpressureExempt(method, path)) return false;
        _bp.acquire();
        return true;
    }

    private HttpResponse guardedRequest(string method, string path, JSONValue body_, string[string] query,
        ServerBase server)
    {
        const gated = admit(method, path);
        scope (exit) if (gated) _bp.release();
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
        // Custom headers go last and merge case-insensitively, so they may
        // replace the SDK's own Authorization/Accept (matching c8ctl). They
        // never reach the OAuth token endpoint: that request is built in
        // auth.d, not here. Values may be secrets: never log them.
        req.headers = mergeHeadersCaseInsensitive(req.headers, _headers);
        // Body-related defaults are decided here, not in perform(): a custom
        // Content-Type or Expect must not be overwritten by a body default
        // added later. perform() only fills in what is still absent.
        if (hasHeaderNamed(req.headers, "content-type"))
            req.contentType = "";
        if (hasHeaderNamed(req.headers, "expect"))
            req.suppressExpect = false;
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

/// Merge `over` onto `base`, matching header names case-insensitively: when
/// both carry the same name under different cases, the `over` entry replaces
/// the `base` entry (keeping the `over` spelling) instead of adding a
/// duplicate line. Both sides are first normalized to one entry per
/// case-insensitive name (deterministic: the lexicographically last
/// spelling wins a same-source collision), so case variants in `base` can
/// never survive to outrank an `over` entry later.
/// (camunda/orchestration-cluster-api-dlang#11)
string[string] mergeHeadersCaseInsensitive(const string[string] base, const string[string] over)
{
    import std.string : toLower;
    string[string] merged = dedupeHeadersCaseInsensitive(base);
    foreach (name, value; dedupeHeadersCaseInsensitive(over))
    {
        string[] stale;
        foreach (k; merged.keys)
        {
            if (k.toLower == name.toLower) stale ~= k;
        }
        foreach (k; stale) merged.remove(k);
        merged[name] = value;
    }
    return merged;
}

/// One entry per case-insensitive header name. An associative array can hold
/// `"Authorization"` and `"AUTHORIZATION"` at once; on a collision the
/// lexicographically last spelling wins, deterministically (keys are sorted
/// first, so the result never depends on iteration order).
private string[string] dedupeHeadersCaseInsensitive(const string[string] headers)
{
    import std.algorithm.sorting : sort;
    import std.string : toLower;
    string[string] result;
    string[] spellings = headers.keys;
    spellings.sort;
    string[string] byLower;
    foreach (name; spellings)
    {
        auto lower = name.toLower;
        if (auto existing = lower in byLower)
        {
            result.remove(*existing);
            result[name] = headers[name];
            *existing = name;
        }
        else
        {
            result[name] = headers[name];
            byLower[lower] = name;
        }
    }
    return result;
}

/// True when `headers` already carries `loweredName` under some case.
/// `loweredName` must already be lowercase.
bool hasHeaderNamed(const string[string] headers, string loweredName)
{
    import std.string : toLower;
    foreach (k; headers.keys)
    {
        if (k.toLower == loweredName) return true;
    }
    return false;
}

/// RFC 9110 field syntax: a nonempty token name, and a value without control
/// characters other than horizontal tab. Both custom-header sources
/// (`CAMUNDA_DEFAULT_HEADERS` and `CamundaOptions.withHeader`) go through
/// here before anything reaches the wire, so a `\r\n` in a value can never
/// inject an extra header line. The error names the header but never the
/// value — it may be a secret.
void validateHeader(string name, string value, string source = "custom header")
{
    import camunda.errors : ConfigException;
    if (!name.length)
        throw new ConfigException(source ~ " has an empty name");
    foreach (c; name)
    {
        const isTchar = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9')
            || c == '!' || c == '#' || c == '$' || c == '%' || c == '&'
            || c == '\'' || c == '*' || c == '+' || c == '-' || c == '.'
            || c == '^' || c == '_' || c == '`' || c == '|' || c == '~';
        if (!isTchar)
            throw new ConfigException(
                source ~ " name '" ~ name ~ "' is not a valid HTTP field name");
    }
    foreach (c; value)
    {
        const ok = c == '\t' || c == ' ' || (c >= '!' && c <= '~') || c >= 0x80;
        if (!ok)
            throw new ConfigException(
                source ~ " '" ~ name ~ "' has a control character in its value");
    }
}

unittest
{
    import camunda.errors : ConfigException;
    import std.algorithm.searching : canFind;
    import std.conv : to;
    import std.string : representation;

    // Valid names and values pass.
    validateHeader("X-Api-Key", "secret");
    validateHeader("Authorization", "Bearer tok");
    validateHeader("X", "");
    validateHeader("X-Weird_`~", "v");
    validateHeader("X-Tab", "a\tb");
    validateHeader("X-Obs", "caf\u00e9");

    // Injection and malformed names are rejected, naming the header but
    // never the value.
    foreach (name; ["", "Bad Name", "Bad:Name", "Bad\rName", "Bad\nName",
        "Bad\"Name", "(Bad)", "Bad@Name", "Bad/Name"])
    {
        try
        {
            validateHeader(name, "v");
            assert(false, "expected ConfigException for name '" ~ name ~ "'");
        }
        catch (ConfigException) {}
    }
    foreach (value; ["a\rb", "a\nb", "a\r\nInjected: yes", "a\0b", "a\x7fb"])
    {
        try
        {
            validateHeader("X-Api-Key", value);
            assert(false, "expected ConfigException for value " ~ value.representation.to!string);
        }
        catch (ConfigException e)
        {
            assert(e.msg.canFind("X-Api-Key"), e.msg);
            // The value may be a secret: it must never appear in the error.
            assert(!e.msg.canFind("Injected"), e.msg);
        }
    }

    // withHeader validates too (the programmatic path).
    try
    {
        CamundaOptions.create.withHeader("X-Api-Key", "a\r\nInjected: yes");
        assert(false, "expected ConfigException from withHeader");
    }
    catch (ConfigException e)
    {
        assert(e.msg.canFind("X-Api-Key"), e.msg);
        assert(!e.msg.canFind("Injected"), e.msg);
    }
    try
    {
        CamundaOptions.create.withHeader("Bad Name", "v");
        assert(false, "expected ConfigException from withHeader");
    }
    catch (ConfigException) {}
}

unittest
{
    // Case variants on either side collapse before the merge: an environment
    // value can never survive next to a programmatic override under another
    // case (which would otherwise win the later request merge).
    auto merged = mergeHeadersCaseInsensitive(
        ["Authorization": "Bearer env1", "AUTHORIZATION": "Bearer env2"],
        ["authorization": "Bearer code"]);
    assert(merged.length == 1);
    assert(merged["authorization"] == "Bearer code");
    // Same-source collisions resolve deterministically (lexicographically
    // last spelling wins), regardless of iteration order.
    auto a = dedupeHeadersCaseInsensitive(["X-Key": "1", "x-key": "2"]);
    auto b = dedupeHeadersCaseInsensitive(["x-key": "2", "X-Key": "1"]);
    assert(a == b && a.length == 1);
    assert(a == ["x-key": "2"]);
}

unittest
{
    auto merged = mergeHeadersCaseInsensitive(
        ["Authorization": "Bearer sdk", "Accept": "application/json, */*"],
        ["authorization": "Bearer custom", "X-Api-Key": "k"]);
    assert(merged.length == 3);
    assert(merged["authorization"] == "Bearer custom");
    assert(merged["Accept"] == "application/json, */*");
    assert(merged["X-Api-Key"] == "k");
    // No case-variant duplicates.
    import std.string : toLower;
    int authCount;
    foreach (k; merged.keys) if (k.toLower == "authorization") authCount++;
    assert(authCount == 1);
}

/// Whether `method path` bypasses the backpressure gate.
///
/// Only initiating operations are gated. Job activation is bounded by the
/// worker's `maxJobs`, and completing, failing, throwing an error on or
/// updating a job relieves the broker: queuing those behind the gate makes
/// them miss the job timeout, so the job runs twice and the late completion
/// fails with 404 (camunda/orchestration-cluster-api-dlang#49).
bool isBackpressureExempt(string method, string path) pure nothrow @nogc
{
    import std.algorithm.searching : endsWith, startsWith;
    enum prefix = "jobs/";
    // Request methods accept slashless paths (joinUrl adds the slash).
    if (path.startsWith("/")) path = path[1 .. $];
    if (!path.startsWith(prefix)) return false;
    const rest = path[prefix.length .. $];
    if (method == "POST" && rest == "activation") return true;
    // Single-job commands: `/jobs/{jobKey}` and `/jobs/{jobKey}/<command>`.
    size_t slash = rest.length;
    foreach (i, c; rest)
        if (c == '/') { slash = i; break; }
    const key = rest[0 .. slash];
    const digits = (key.length > 0 && key[0] == '-') ? key[1 .. $] : key;
    if (digits.length == 0) return false;
    foreach (c; digits)
        if (c < '0' || c > '9') return false; // `/jobs/search`, `/jobs/batch-update`, …
    const tail = rest[slash .. $];
    if (method == "PATCH" && tail.length == 0) return true;
    if (method != "POST") return false;
    return tail == "/completion" || tail == "/failure" || tail == "/error";
}

unittest
{
    assert(isBackpressureExempt("POST", "/jobs/activation"));
    assert(isBackpressureExempt("POST", "/jobs/2251799813685249/completion"));
    assert(isBackpressureExempt("POST", "/jobs/1/failure"));
    assert(isBackpressureExempt("POST", "/jobs/1/error"));
    assert(isBackpressureExempt("PATCH", "/jobs/1"));
    // Initiating and read operations stay gated.
    assert(!isBackpressureExempt("POST", "/process-instances"));
    assert(!isBackpressureExempt("POST", "/messages/publication"));
    assert(!isBackpressureExempt("POST", "/jobs/search"));
    assert(!isBackpressureExempt("POST", "/jobs/batch-update"));
    assert(!isBackpressureExempt("GET", "/jobs/statistics/global"));
    assert(!isBackpressureExempt("POST", "/jobs//completion"));
    assert(!isBackpressureExempt("GET", "/jobs/1/completion"));
    // Slashless paths and signed keys (JobKey accepts `^-?[0-9]+$`).
    assert(isBackpressureExempt("POST", "jobs/activation"));
    assert(isBackpressureExempt("POST", "jobs/1/completion"));
    assert(isBackpressureExempt("PATCH", "jobs/1"));
    assert(isBackpressureExempt("POST", "/jobs/-1/completion"));
    assert(isBackpressureExempt("POST", "/jobs/-42/failure"));
    assert(isBackpressureExempt("POST", "jobs/-1/error"));
    assert(isBackpressureExempt("PATCH", "/jobs/-1"));
    assert(!isBackpressureExempt("POST", "/jobs/-/completion"));
    assert(!isBackpressureExempt("POST", "/jobs/--1/completion"));
    assert(!isBackpressureExempt("POST", "jobs/search"));
    assert(!isBackpressureExempt("POST", "//jobs/1/completion"));
}

unittest
{
    // #49: with the limiter at its floor and every permit held, job
    // completion is admitted without waiting; initiating operations are not.
    // Pin BALANCED: under the supported LEGACY profile `recordBackpressure`
    // is observe-only and the limiter never gates, so the fixture must not
    // inherit the developer's CAMUNDA_SDK_BACKPRESSURE_PROFILE.
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    auto t = new Transport(CamundaOptions.create
        .withKey("CAMUNDA_AUTH_STRATEGY", "NONE")
        .withKey("CAMUNDA_SDK_BACKPRESSURE_PROFILE", "BALANCED")
        .withClock(clock));
    foreach (_; 0 .. 10) t._bp.recordBackpressure();
    const cap = t.backpressureState.permitsMax;
    assert(!t.backpressureState.unlimited);
    foreach (_; 0 .. cap) t._bp.acquire();
    const before = clock.nowMs;
    foreach (path; ["/jobs/1/completion", "/jobs/1/failure", "/jobs/1/error", "/jobs/activation"])
        assert(!t.admit("POST", path));
    assert(!t.admit("PATCH", "/jobs/1"));
    assert(clock.nowMs == before, "exempt job command waited on the gate");
    assert(t.backpressureState.permitsCurrent == cap);
    assert(t.backpressureState.waiters == 0);
}

unittest
{
    // Empty on either side is a copy of the other.
    assert(mergeHeadersCaseInsensitive(null, ["A": "1"]) == ["A": "1"]);
    assert(mergeHeadersCaseInsensitive(["A": "1"], null) == ["A": "1"]);
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

unittest
{
    // camunda/orchestration-cluster-api-dlang#11: config + programmatic
    // headers merge case-insensitively; the programmatic one wins.
    auto t = new Transport(CamundaOptions.create
        .withKey("CAMUNDA_AUTH_STRATEGY", "NONE")
        .withKey("CAMUNDA_DEFAULT_HEADERS", `{"X-Api-Key":"from-env","X-Other":"env"}`)
        .withHeader("x-api-key", "from-code"));
    assert(t.headers.length == 2);
    assert(t.headers["x-api-key"] == "from-code");
    assert(t.headers["X-Other"] == "env");
}

unittest
{
    // Direct assignment to the public `headers` map must not bypass
    // validation (header injection via CR/LF).
    import std.algorithm.searching : canFind;
    foreach (bad; [["X-Api-Key", "a\r\nInjected: yes"], ["Bad Name", "v"], ["X", "a\0b"]])
    {
        auto o = CamundaOptions.create.withKey("CAMUNDA_AUTH_STRATEGY", "NONE");
        o.headers[bad[0]] = bad[1];
        try
        {
            new Transport(o);
            assert(false, "expected ConfigException for direct headers assignment");
        }
        catch (ConfigException e)
            assert(!e.msg.canFind("Injected"), e.msg);
    }
}
