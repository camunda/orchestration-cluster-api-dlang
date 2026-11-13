/// Environment-driven configuration. Mirrors the JS SDK's `CAMUNDA_*` surface.
module camunda.config;

@safe:

import camunda.errors;
import camunda.safeio : envGet;
import std.conv : to;
import std.format : format;
import std.string : split, strip, toLower, toUpper;

enum AuthStrategy
{
    none = "NONE",
    oauth = "OAUTH",
    basic = "BASIC",
}

enum LogLevel
{
    off = "off",
    error = "error",
    warn = "warn",
    info = "info",
    debug_ = "debug",
    trace = "trace",
}

enum BackpressureProfile
{
    balanced = "BALANCED",
    conservative = "CONSERVATIVE",
    aggressive = "AGGRESSIVE",
    legacy = "LEGACY",
}

struct RetryConfig
{
    uint maxAttempts = 3;
    long baseDelayMs = 100;
    long maxDelayMs = 2000;
}

struct TlsConfig
{
    string cert;
    string key;
    string ca;
    string certPath;
    string keyPath;
    string caPath;
    string keyPassphrase;

    bool isConfigured() const
    {
        return cert.length || key.length || ca.length
            || certPath.length || keyPath.length || caPath.length;
    }
}

struct WorkerDefaults
{
    long timeoutMs = 60_000;
    int maxConcurrentJobs = 32;
    long requestTimeoutMs = 10_000;
    string name = "d-sdk-worker";
    long startupJitterMaxSeconds = 0;
}

/// Fully-resolved SDK configuration. Produced by `CamundaConfig.resolve`.
struct CamundaConfig
{
    string restAddress = "http://localhost:8080/v2";
    AuthStrategy authStrategy = AuthStrategy.none;
    string clientId;
    string clientSecret;
    string oauthUrl = "https://login.cloud.camunda.io/oauth/token";
    string tokenAudience = "zeebe.camunda.io";
    string oauthScope;
    string oauthCacheDir;
    string basicAuthUsername;
    string basicAuthPassword;
    string defaultTenantId;
    string[] tenantIds;
    BackpressureProfile backpressureProfile = BackpressureProfile.balanced;
    LogLevel logLevel = LogLevel.info;
    long eventualPollDefaultMs = 10_000;
    RetryConfig retry;
    TlsConfig tls;
    WorkerDefaults workerDefaults;
    bool restAddressExact;

    /// Resolve from the process environment.
    static CamundaConfig fromEnv()
    {
        return resolve(null, &envGet);
    }

    /// Resolve from the process environment, with `overrides` winning.
    static CamundaConfig fromEnv(string[string] overrides)
    {
        return resolve(overrides, &envGet);
    }

    /// Resolve using only `overrides` (no process environment). Used by tests.
    static CamundaConfig fromMap(string[string] overrides)
    {
        return resolve(overrides, function string(string) { return null; });
    }

    private static CamundaConfig resolve(string[string] overrides, string function(string) @safe lookup)
    {
        string get(string key)
        {
            if (overrides !is null)
            {
                if (auto p = key in overrides)
                {
                    auto v = (*p).strip;
                    if (v.length) return v;
                }
            }
            auto v = lookup(key);
            return v is null ? null : v.strip;
        }

        string first(string[] keys)
        {
            foreach (k; keys)
            {
                auto v = get(k);
                if (v.length) return v;
            }
            return null;
        }

        CamundaConfig c;
        c.restAddressExact = parseBool(get("CAMUNDA_REST_ADDRESS_EXACT"), false);
        auto rawAddress = first(["CAMUNDA_REST_ADDRESS", "ZEEBE_REST_ADDRESS"]);
        if (rawAddress is null) rawAddress = "http://localhost:8080";
        c.restAddress = normalizeRestAddress(rawAddress, c.restAddressExact);

        c.clientId = first(["CAMUNDA_CLIENT_ID", "CAMUNDA_CLIENT_AUTH_CLIENTID"]);
        c.clientSecret = first(["CAMUNDA_CLIENT_SECRET", "CAMUNDA_CLIENT_AUTH_CLIENTSECRET"]);
        auto oauthUrl = get("CAMUNDA_OAUTH_URL");
        if (oauthUrl.length) c.oauthUrl = oauthUrl;
        auto audience = get("CAMUNDA_TOKEN_AUDIENCE");
        if (audience.length) c.tokenAudience = audience;
        c.oauthScope = get("CAMUNDA_OAUTH_SCOPE");
        c.oauthCacheDir = get("CAMUNDA_OAUTH_CACHE_DIR");
        c.basicAuthUsername = get("CAMUNDA_BASIC_AUTH_USERNAME");
        c.basicAuthPassword = get("CAMUNDA_BASIC_AUTH_PASSWORD");

        auto explicit = get("CAMUNDA_AUTH_STRATEGY");
        c.authStrategy = resolveStrategy(explicit, c.clientId, c.clientSecret,
            c.basicAuthUsername, c.basicAuthPassword);

        c.defaultTenantId = first(["CAMUNDA_DEFAULT_TENANT_ID", "CAMUNDA_TENANT_ID"]);
        c.tenantIds = parseTenantIds(get("CAMUNDA_TENANT_IDS"), c.defaultTenantId);

        auto profile = get("CAMUNDA_SDK_BACKPRESSURE_PROFILE");
        if (profile.length) c.backpressureProfile = parseProfile(profile);

        auto level = get("CAMUNDA_SDK_LOG_LEVEL");
        if (level.length) c.logLevel = parseLogLevel(level);

        c.eventualPollDefaultMs = parseLong(get("CAMUNDA_SDK_EVENTUAL_POLL_DEFAULT_MS"), 10_000);
        c.retry.maxAttempts = cast(uint) parseLong(get("CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS"), 3);
        c.retry.baseDelayMs = parseLong(get("CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS"), 100);
        c.retry.maxDelayMs = parseLong(get("CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS"), 2000);

        c.tls.cert = get("CAMUNDA_MTLS_CERT");
        c.tls.key = get("CAMUNDA_MTLS_KEY");
        c.tls.ca = get("CAMUNDA_MTLS_CA");
        c.tls.certPath = get("CAMUNDA_MTLS_CERT_PATH");
        c.tls.keyPath = get("CAMUNDA_MTLS_KEY_PATH");
        c.tls.caPath = get("CAMUNDA_MTLS_CA_PATH");
        c.tls.keyPassphrase = get("CAMUNDA_MTLS_KEY_PASSPHRASE");

        c.workerDefaults.timeoutMs = parseLong(get("CAMUNDA_WORKER_TIMEOUT"), 60_000);
        c.workerDefaults.maxConcurrentJobs = cast(int) parseLong(get("CAMUNDA_WORKER_MAX_CONCURRENT_JOBS"), 32);
        c.workerDefaults.requestTimeoutMs = parseLong(get("CAMUNDA_WORKER_REQUEST_TIMEOUT"), 10_000);
        auto wname = get("CAMUNDA_WORKER_NAME");
        if (wname.length) c.workerDefaults.name = wname;
        c.workerDefaults.startupJitterMaxSeconds =
            parseLong(get("CAMUNDA_WORKER_STARTUP_JITTER_MAX_SECONDS"), 0);

        c.validate();
        return c;
    }

    private void validate() const
    {
        if (authStrategy == AuthStrategy.oauth)
        {
            if (!clientId.length || !clientSecret.length || !oauthUrl.length)
                throw new ConfigException(
                    "OAUTH strategy requires CAMUNDA_CLIENT_ID, CAMUNDA_CLIENT_SECRET and CAMUNDA_OAUTH_URL");
        }
        if (authStrategy == AuthStrategy.basic)
        {
            if (!basicAuthUsername.length || !basicAuthPassword.length)
                throw new ConfigException(
                    "BASIC strategy requires CAMUNDA_BASIC_AUTH_USERNAME and CAMUNDA_BASIC_AUTH_PASSWORD");
        }
        if (tls.cert.length ^ tls.key.length)
            throw new ConfigException(
                "mutual TLS requires both CAMUNDA_MTLS_CERT and CAMUNDA_MTLS_KEY");
        if (tls.certPath.length ^ tls.keyPath.length)
            throw new ConfigException(
                "mutual TLS requires both CAMUNDA_MTLS_CERT_PATH and CAMUNDA_MTLS_KEY_PATH");
    }
}

string normalizeRestAddress(string raw, bool exact = false)
{
    auto trimmed = raw;
    while (trimmed.length && trimmed[$ - 1] == '/') trimmed = trimmed[0 .. $ - 1];
    if (exact) return trimmed;
    if (trimmed.length >= 3 && trimmed[$ - 3 .. $] == "/v2") return trimmed;
    // also accept /vN
    import std.regex : matchFirst, regex;
    if (!matchFirst(trimmed, regex(`/v\d+$`)).empty) return trimmed;
    return trimmed ~ "/v2";
}

private AuthStrategy resolveStrategy(string explicit, string clientId, string clientSecret,
    string basicUser, string basicPass)
{
    if (explicit.length)
    {
        switch (explicit.toUpper)
        {
        case "OAUTH": return AuthStrategy.oauth;
        case "BASIC": return AuthStrategy.basic;
        case "NONE": return AuthStrategy.none;
        default:
            throw new ConfigException(
                format("unknown CAMUNDA_AUTH_STRATEGY %s (expected OAUTH, BASIC or NONE)", explicit));
        }
    }
    const hasOauth = clientId.length && clientSecret.length;
    const hasBasic = basicUser.length && basicPass.length;
    if (hasOauth && hasBasic)
        throw new ConfigException(
            "Both OAuth and Basic credentials are set, but CAMUNDA_AUTH_STRATEGY is not configured");
    if (hasOauth) return AuthStrategy.oauth;
    if (hasBasic) return AuthStrategy.basic;
    return AuthStrategy.none;
}

private BackpressureProfile parseProfile(string s)
{
    switch (s.toUpper)
    {
    case "BALANCED": return BackpressureProfile.balanced;
    case "CONSERVATIVE": return BackpressureProfile.conservative;
    case "AGGRESSIVE": return BackpressureProfile.aggressive;
    case "LEGACY": return BackpressureProfile.legacy;
    default:
        throw new ConfigException(
            format("invalid CAMUNDA_SDK_BACKPRESSURE_PROFILE '%s' (expected BALANCED, CONSERVATIVE, AGGRESSIVE or LEGACY)", s));
    }
}

private LogLevel parseLogLevel(string s)
{
    switch (s.toLower)
    {
    case "off", "none", "silent": return LogLevel.off;
    case "error": return LogLevel.error;
    case "warn", "warning": return LogLevel.warn;
    case "info", "": return LogLevel.info;
    case "debug": return LogLevel.debug_;
    case "trace", "silly", "verbose": return LogLevel.trace;
    default:
        throw new ConfigException(
            format("unknown CAMUNDA_SDK_LOG_LEVEL %s (expected off/error/warn/info/debug/trace)", s));
    }
}

private long parseLong(string s, long fallback)
{
    if (s is null || !s.length) return fallback;
    try return s.to!long;
    catch (Exception)
        throw new ConfigException(format("must be an integer, got %s", s));
}

private bool parseBool(string s, bool fallback)
{
    if (s is null || !s.length) return fallback;
    switch (s.toLower)
    {
    case "1", "true", "yes", "on": return true;
    case "0", "false", "no", "off": return false;
    default: return fallback;
    }
}

private string[] parseTenantIds(string list, string single)
{
    string[] ids;
    if (list.length)
    {
        foreach (part; list.split(','))
        {
            auto t = part.strip;
            if (t.length) ids ~= t;
        }
        return ids;
    }
    if (single.length) return [single];
    return null;
}

unittest
{
    auto c = CamundaConfig.fromMap(null);
    assert(c.restAddress == "http://localhost:8080/v2");
    assert(c.authStrategy == AuthStrategy.none);
}

unittest
{
    assert(normalizeRestAddress("https://x.io") == "https://x.io/v2");
    assert(normalizeRestAddress("https://x.io/") == "https://x.io/v2");
    assert(normalizeRestAddress("https://x.io/v2") == "https://x.io/v2");
    assert(normalizeRestAddress("https://x.io/v2/") == "https://x.io/v2");
    assert(normalizeRestAddress("https://gw/api", true) == "https://gw/api");
}

unittest
{
    auto c = CamundaConfig.fromMap(["ZEEBE_REST_ADDRESS": "https://z.example"]);
    assert(c.restAddress == "https://z.example/v2");
}

unittest
{
    auto c = CamundaConfig.fromMap([
        "CAMUNDA_OAUTH_URL": "https://login/oauth/token",
        "CAMUNDA_CLIENT_ID": "id",
        "CAMUNDA_CLIENT_SECRET": "secret",
    ]);
    assert(c.authStrategy == AuthStrategy.oauth);
}

unittest
{
    bool threw;
    try CamundaConfig.fromMap(["CAMUNDA_AUTH_STRATEGY": "OAUTH"]);
    catch (ConfigException) threw = true;
    assert(threw);
}

unittest
{
    bool threw;
    try CamundaConfig.fromMap(["CAMUNDA_AUTH_STRATEGY": "BASIC"]);
    catch (ConfigException) threw = true;
    assert(threw);
    auto ok = CamundaConfig.fromMap([
        "CAMUNDA_AUTH_STRATEGY": "BASIC",
        "CAMUNDA_BASIC_AUTH_USERNAME": "demo",
        "CAMUNDA_BASIC_AUTH_PASSWORD": "demo",
    ]);
    assert(ok.authStrategy == AuthStrategy.basic);
}

unittest
{
    auto c = CamundaConfig.fromMap([
        "CAMUNDA_BASIC_AUTH_USERNAME": "demo",
        "CAMUNDA_BASIC_AUTH_PASSWORD": "demo",
    ]);
    assert(c.authStrategy == AuthStrategy.basic);
}

unittest
{
    auto c = CamundaConfig.fromMap([
        "CAMUNDA_AUTH_STRATEGY": "NONE",
        "CAMUNDA_CLIENT_ID": "id",
        "CAMUNDA_CLIENT_SECRET": "secret",
    ]);
    assert(c.authStrategy == AuthStrategy.none);
}

unittest
{
    auto c = CamundaConfig.fromMap(["CAMUNDA_TENANT_IDS": "acme, globex ,initech"]);
    assert(c.tenantIds == ["acme", "globex", "initech"]);
}

unittest
{
    bool threw;
    try CamundaConfig.fromMap(["CAMUNDA_AUTH_STRATEGY": "KERBEROS"]);
    catch (ConfigException) threw = true;
    assert(threw);
}
