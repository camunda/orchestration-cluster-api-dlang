/// Authentication strategies and token management.
///
/// OAUTH (client-credentials, in-memory + optional disk cache), BASIC, NONE.
module camunda.auth;

@safe:

import camunda.clock : Clock;
import camunda.config : AuthStrategy, CamundaConfig;
import camunda.errors;
import camunda.http;
import camunda.jsonx;
import camunda.safeio;
import std.format : format;
import std.json;
import std.string : representation;

private struct CachedToken
{
    string token;
    long refreshAfterMono;
    long refreshAfterWall;
}

/// Resolves and applies authentication to outgoing requests.
final class Authentication
{
    private AuthStrategy strategy;
    private string oauthUrl;
    private string clientId;
    private string clientSecret;
    private string audience;
    private string oauthScope;
    private string basicUsername;
    private string basicPassword;
    private string oauthCacheDir;
    private Clock clock;
    private CachedToken cached;
    private bool hasCached;

    this(const ref CamundaConfig config, Clock clock)
    {
        this.strategy = config.authStrategy;
        this.oauthUrl = config.oauthUrl;
        this.clientId = config.clientId;
        this.clientSecret = config.clientSecret;
        this.audience = config.tokenAudience;
        this.oauthScope = config.oauthScope;
        this.basicUsername = config.basicAuthUsername;
        this.basicPassword = config.basicAuthPassword;
        this.oauthCacheDir = config.oauthCacheDir;
        this.clock = clock;
    }

    AuthStrategy authStrategy() const { return strategy; }

    /// Headers to attach to an API request. Refreshes the OAuth token if needed.
    string[string] headers()
    {
        string[string] h;
        final switch (strategy)
        {
        case AuthStrategy.none:
            break;
        case AuthStrategy.basic:
            h["Authorization"] = "Basic " ~ basicToken(basicUsername, basicPassword);
            break;
        case AuthStrategy.oauth:
            h["Authorization"] = "Bearer " ~ accessToken();
            break;
        }
        return h;
    }

    private string accessToken()
    {
        if (hasCached && clock.nowMs() < cached.refreshAfterMono)
            return cached.token;
        auto disk = readDiskToken();
        if (disk.token.length && clock.nowMs() < disk.refreshAfterMono)
        {
            cached = disk;
            hasCached = true;
            return disk.token;
        }
        auto fetched = fetchToken();
        writeDiskToken(fetched);
        cached = fetched;
        hasCached = true;
        return fetched.token;
    }

    private string cacheFilePath() const
    {
        if (!oauthCacheDir.length) return null;
        import std.digest.crc : crc32Of, crcHexString;
        auto key = oauthUrl ~ "\0" ~ clientId ~ "\0" ~ audience;
        auto hex = crcHexString(crc32Of(key));
        return oauthCacheDir ~ "/camunda-oauth-" ~ hex ~ ".json";
    }

    private CachedToken readDiskToken()
    {
        CachedToken none;
        auto path = cacheFilePath();
        if (path is null || !pathExists(path)) return none;
        try
        {
            auto text = readRawText(path);
            auto j = parseJSON(text);
            CachedToken t;
            t.token = jsonGetString(j, "access_token");
            auto refreshWall = jsonGetLong(j, "refresh_after_unix_ms");
            auto nowWall = clock.nowWallMs();
            auto now = clock.nowMs();
            t.refreshAfterWall = refreshWall;
            t.refreshAfterMono = refreshWall > nowWall ? now + (refreshWall - nowWall) : now;
            return t;
        }
        catch (Exception)
        {
            return none;
        }
    }

    private void writeDiskToken(const ref CachedToken token)
    {
        auto path = cacheFilePath();
        if (path is null) return;
        try
        {
            import std.path : dirName;
            makeDirRecurse(dirName(path));
            auto obj = emptyObject();
            jsonSet(obj, "access_token", JSONValue(token.token));
            jsonSet(obj, "refresh_after_unix_ms", JSONValue(token.refreshAfterWall));
            auto tmp = path ~ ".tmp-" ~ thisPidString();
            writeText(tmp, obj.toString);
            renamePath(tmp, path);
        }
        catch (Exception)
        {
            // best-effort cache
        }
    }

    private CachedToken fetchToken()
    {
        if (!oauthUrl.length) throw new ConfigException("CAMUNDA_OAUTH_URL is required for OAUTH");
        if (!clientId.length) throw new ConfigException("CAMUNDA_CLIENT_ID is required for OAUTH");
        if (!clientSecret.length) throw new ConfigException("CAMUNDA_CLIENT_SECRET is required for OAUTH");

        import std.uri : encodeComponent;
        string form = "grant_type=client_credentials"
            ~ "&client_id=" ~ encodeComponent(clientId)
            ~ "&client_secret=" ~ encodeComponent(clientSecret);
        if (audience.length) form ~= "&audience=" ~ encodeComponent(audience);
        if (oauthScope.length) form ~= "&scope=" ~ encodeComponent(oauthScope);

        HttpRequest req;
        req.method = "POST";
        req.url = oauthUrl;
        req.body_ = form;
        req.contentType = "application/x-www-form-urlencoded";
        req.headers["Accept"] = "application/json";
        HttpResponse res;
        try res = perform(req);
        catch (NetworkException e)
            throw new AuthException("Failed to reach the OAuth token endpoint: " ~ e.msg, __FILE__, __LINE__, e);

        if (res.status < 200 || res.status >= 300)
            throw new AuthException(format("token endpoint returned HTTP %s: %s", res.status, res.body_));

        JSONValue payload;
        try payload = parseJSON(res.body_);
        catch (Exception e)
            throw new AuthException("failed to parse token response: " ~ e.msg, __FILE__, __LINE__, e);

        auto token = jsonGetString(payload, "access_token");
        if (!token.length)
            throw new AuthException("OAuth token response did not contain an access_token.");
        auto expiresIn = jsonGetLong(payload, "expires_in");
        if (expiresIn <= 0) expiresIn = 60;
        auto lead = expiresIn > 30 ? expiresIn - 30 : 1;
        CachedToken c;
        c.token = token;
        c.refreshAfterMono = clock.nowMs() + lead * 1000;
        c.refreshAfterWall = clock.nowWallMs() + lead * 1000;
        return c;
    }
}

/// `@trusted`: `std.base64.encode` takes/returns `ubyte[]`/`char[]`; we copy
/// the result into an owned string.
string basicToken(string user, string pass) @trusted
{
    import std.base64 : Base64;
    auto raw = (user ~ ":" ~ pass).representation;
    return Base64.encode(raw).idup;
}

unittest
{
    assert(basicToken("demo", "demo") == "ZGVtbzpkZW1v");
}

unittest
{
    import camunda.clock : TestClock;
    CamundaConfig cfg;
    cfg.authStrategy = AuthStrategy.none;
    auto auth = new Authentication(cfg, new TestClock);
    assert(auth.headers().length == 0);
}

unittest
{
    import camunda.clock : TestClock;
    CamundaConfig cfg;
    cfg.authStrategy = AuthStrategy.basic;
    cfg.basicAuthUsername = "demo";
    cfg.basicAuthPassword = "demo";
    auto auth = new Authentication(cfg, new TestClock);
    assert(auth.headers()["Authorization"] == "Basic ZGVtbzpkZW1v");
}
