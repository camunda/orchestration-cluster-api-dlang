/// HTTP over WinHTTP, the HTTP stack built into Windows: `camunda.http.perform`
/// on Windows. TLS is Schannel, server trust is the Windows certificate
/// store, and the proxy is the system's (or `HTTPS_PROXY`/`HTTP_PROXY`/
/// `NO_PROXY` when set, as on POSIX; `NO_PROXY` applies to the system
/// proxy too). Redirects are not followed and cookies are not kept, as with
/// the curl backend. Nothing to link or ship: winhttp.dll is
/// part of Windows. (camunda/orchestration-cluster-api-dlang#28)
///
/// Not yet: a custom CA file (`caPath`) and PEM client certificates (mTLS).
/// Requests that set them fail with a clear error instead of silently
/// trusting something else.
///
/// The URL and proxy helpers are plain D and tested on every platform; only
/// `perform` is Windows-only.
module camunda.winhttp;

@safe:

import std.string : indexOf, lastIndexOf, toLower;

/// The parts of an absolute http(s) URL that WinHTTP takes separately.
struct UrlParts
{
    bool secure;
    string host; /// without brackets for IPv6
    ushort port;
    string target; /// path and query, at least "/"
}

/// Split `url` for WinHttpConnect/WinHttpOpenRequest. Throws on anything but
/// an absolute http/https URL with a host.
UrlParts splitUrl(string url) pure
{
    import std.conv : to, ConvException;

    UrlParts u;
    const sep = url.indexOf("://");
    if (sep <= 0) throw new Exception("not an absolute URL: " ~ url);
    const scheme = url[0 .. sep].toLower;
    if (scheme == "https") u.secure = true;
    else if (scheme != "http") throw new Exception("unsupported URL scheme '" ~ scheme ~ "': " ~ url);
    auto rest = url[sep + 3 .. $];
    auto slash = rest.indexOf('/');
    auto qmark = rest.indexOf('?');
    if (qmark >= 0 && (slash < 0 || qmark < slash)) slash = qmark;
    auto authority = slash < 0 ? rest : rest[0 .. slash];
    u.target = slash < 0 ? "/" : rest[slash .. $];
    if (u.target[0] == '?') u.target = "/" ~ u.target;
    const fragment = u.target.indexOf('#');
    if (fragment >= 0) u.target = u.target[0 .. fragment];
    const at = authority.indexOf('@');
    if (at >= 0) throw new Exception("credentials in the URL are not supported: " ~ url);
    string portText;
    if (authority.length && authority[0] == '[')
    {
        const close = authority.indexOf(']');
        if (close < 0) throw new Exception("unterminated IPv6 address: " ~ url);
        u.host = authority[1 .. close];
        const after = authority[close + 1 .. $];
        if (after.length)
        {
            if (after[0] != ':') throw new Exception("bad authority: " ~ url);
            portText = after[1 .. $];
        }
    }
    else
    {
        const colon = authority.indexOf(':');
        u.host = colon < 0 ? authority : authority[0 .. colon];
        if (colon >= 0) portText = authority[colon + 1 .. $];
    }
    if (!u.host.length) throw new Exception("URL has no host: " ~ url);
    if (portText.length)
    {
        try u.port = portText.to!ushort;
        catch (ConvException) throw new Exception("bad port '" ~ portText ~ "': " ~ url);
    }
    else u.port = u.secure ? 443 : 80;
    return u;
}

unittest
{
    auto a = splitUrl("http://127.0.0.1:8080/v2/things?x=a%20b");
    assert(!a.secure && a.host == "127.0.0.1" && a.port == 8080 && a.target == "/v2/things?x=a%20b");
    auto b = splitUrl("HTTPS://cluster.camunda.io");
    assert(b.secure && b.host == "cluster.camunda.io" && b.port == 443 && b.target == "/");
    auto c = splitUrl("http://[::1]:26500/v2?q=1#frag");
    assert(c.host == "::1" && c.port == 26500 && c.target == "/v2?q=1");
    auto d = splitUrl("http://h?only=query");
    assert(d.host == "h" && d.port == 80 && d.target == "/?only=query");
    import std.exception : assertThrown;
    assertThrown(splitUrl("ftp://h/"));
    assertThrown(splitUrl("/relative"));
    assertThrown(splitUrl("http://:80/"));
    assertThrown(splitUrl("http://h:99999/"));
    assertThrown(splitUrl("http://user:pw@h/"));
}

/// The proxy WinHTTP should use, from the POSIX-style `HTTPS_PROXY` /
/// `HTTP_PROXY` values passed in (empty when unset). `list` is WinHTTP's
/// per-scheme form (`http=host:port;https=host:port`); empty means no
/// variable is set, so use the system proxy. `NO_PROXY` is not folded in
/// here: WinHTTP's bypass list has different matching rules, so it is applied
/// per request with `noProxyMatches` instead.
///
/// WinHTTP talks to a proxy only in plain HTTP (CONNECT for https targets),
/// so a proxy URL with any other scheme (`https://`, `socks5://`, ...) is
/// rejected rather than silently downgraded.
struct ProxyChoice
{
    string list;
}

ProxyChoice proxyFromEnv(string httpsProxy, string httpProxy) pure
{
    import std.array : join;
    import std.string : strip;

    static string hostPort(string v)
    {
        auto s = v.strip;
        const sep = s.indexOf("://");
        if (sep >= 0)
        {
            const scheme = s[0 .. sep].toLower;
            if (scheme != "http")
                throw new Exception("unsupported proxy scheme '" ~ scheme ~ "' in " ~ v
                    ~ ": WinHTTP supports only http:// proxies");
            s = s[sep + 3 .. $];
        }
        while (s.length && s[$ - 1] == '/') s = s[0 .. $ - 1];
        if (!s.length || s.indexOf('/') >= 0 || s.indexOf('@') >= 0)
            throw new Exception("unsupported proxy '" ~ v ~ "': expected [http://]host[:port]");
        return s;
    }

    ProxyChoice p;
    string[] parts;
    if (httpProxy.strip.length) parts ~= "http=" ~ hostPort(httpProxy);
    if (httpsProxy.strip.length) parts ~= "https=" ~ hostPort(httpsProxy);
    p.list = parts.join(";");
    return p;
}

unittest
{
    import std.exception : assertThrown;

    assert(proxyFromEnv("", "") == ProxyChoice.init);
    auto p = proxyFromEnv("http://proxy.corp:3128/", "proxy.corp:3128");
    assert(p.list == "http=proxy.corp:3128;https=proxy.corp:3128", p.list);
    assert(proxyFromEnv("HTTP://p:1", "").list == "https=p:1");
    // Never silently downgrade a TLS or SOCKS proxy to plain HTTP.
    assertThrown(proxyFromEnv("https://proxy.corp:443", ""));
    assertThrown(proxyFromEnv("", "socks5://proxy.corp:1080"));
    assertThrown(proxyFromEnv("http://user:pw@proxy:1", ""));
    assertThrown(proxyFromEnv("http://proxy:1/path", ""));
}

/// Whether `host` is excluded from proxying by `noProxy` (the `NO_PROXY`
/// value), with curl's semantics: comma-separated, case-insensitive; `*`
/// alone matches everything; an entry matches the host itself and every
/// subdomain, with or without a leading dot (`.internal` and `internal` both
/// match `cluster.internal` and `internal`). An entry's `:port` is ignored.
bool noProxyMatches(string noProxy, string host) pure
{
    import std.algorithm : endsWith;
    import std.array : split;
    import std.string : strip;

    auto h = host.toLower;
    while (h.length && h[$ - 1] == '.') h = h[0 .. $ - 1];
    if (h.length > 1 && h[0] == '[' && h[$ - 1] == ']') h = h[1 .. $ - 1];
    foreach (raw; noProxy.split(","))
    {
        auto e = raw.strip.toLower;
        if (e == "*") return true;
        if (e.length && e[0] == '[')
        {
            const close = e.indexOf(']');
            e = close > 0 ? e[1 .. close] : e;
        }
        else if (e.indexOf(':') >= 0 && e.indexOf(':') == e.lastIndexOf(':'))
            e = e[0 .. e.indexOf(':')]; // host:port; bare IPv6 has several ':'
        while (e.length && e[0] == '.') e = e[1 .. $];
        while (e.length && e[$ - 1] == '.') e = e[0 .. $ - 1];
        if (!e.length) continue;
        if (h == e || h.endsWith("." ~ e)) return true;
    }
    return false;
}

unittest
{
    assert(!noProxyMatches("", "h"));
    assert(noProxyMatches("*", "anything.example"));
    assert(noProxyMatches(" localhost , .internal ,", "cluster.internal"));
    assert(noProxyMatches(".internal", "internal"));
    assert(noProxyMatches("internal", "a.b.INTERNAL"));
    assert(!noProxyMatches("internal", "notinternal"));
    assert(noProxyMatches("Camunda.io:443", "x.camunda.io"));
    assert(noProxyMatches("::1", "::1"));
    assert(noProxyMatches("[::1]:8080", "::1"));
    assert(!noProxyMatches("localhost", "example.com"));
}

/// A readable name for the WinHTTP errors a caller can act on.
string winHttpErrorName(uint code) pure nothrow
{
    switch (code)
    {
    case 12_002: return "timed out";
    case 12_007: return "host name not resolved";
    case 12_029: return "could not connect";
    case 12_030: return "connection aborted";
    case 12_152: return "invalid server response";
    case 12_175: return "TLS failure (is the server certificate trusted in the Windows certificate store?)";
    default: return "error";
    }
}

version (Windows)
{
    import camunda.errors : CamundaException, ConfigException, NetworkException;
    import camunda.http : HttpRequest, HttpResponse;
    import camunda.safeio : ownText;
    import camunda.transport : hasHeaderNamed;
    import core.sys.windows.winhttp;
    import core.sys.windows.windef : DWORD;

    /// This thread's WinHTTP session. WinHTTP pools connections per session,
    /// so sequential requests on one thread reuse one keep-alive connection.
    /// Module variables are thread-local in D, so no other thread sees it.
    private HINTERNET session;

    // `@trusted`: closes the handle this thread opened (thread-local, so
    // nothing else can be using it once the thread ends).
    static ~this() @trusted
    {
        if (session !is null) WinHttpCloseHandle(session);
    }

    /// `@trusted`: WinHTTP is a C API. This hands it NUL-terminated UTF-16
    /// copies of the request strings and the request's own body (which
    /// outlives the synchronous send), reads into a bounds-checked GC
    /// buffer, and closes every handle it opens on the way out.
    HttpResponse winHttpPerform(const ref HttpRequest req) @trusted
    {
        import std.utf : toUTF16z, toUTF8;
        import core.time : MonoTime, msecs;

        // Nested, so they share this function's @trusted boundary (their
        // attributes are inferred; both call into the C API).
        NetworkException lastError(string what, string url)
        {
            import core.sys.windows.winbase : GetLastError;
            import std.format : format;

            const code = GetLastError();
            return new NetworkException(format("%s %s: WinHTTP %s %s", what, url, code, winHttpErrorName(code)));
        }

        HINTERNET openSession()
        {
            import std.process : environment;
            import std.utf : toUTF16z;

            ProxyChoice p;
            try p = proxyFromEnv(environment.get("HTTPS_PROXY", environment.get("https_proxy", "")),
                environment.get("HTTP_PROXY", environment.get("http_proxy", "")));
            catch (Exception e) throw new ConfigException(e.msg);
            HINTERNET s;
            if (p.list.length)
                s = WinHttpOpen("camunda-orchestration-sdk-d"w.ptr, WINHTTP_ACCESS_TYPE_NAMED_PROXY,
                    p.list.toUTF16z, WINHTTP_NO_PROXY_BYPASS, 0);
            else
            {
                // The system proxy (including PAC); Windows 8.1+.
                s = WinHttpOpen("camunda-orchestration-sdk-d"w.ptr, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
                if (s is null) // older Windows: the WinHTTP-configured proxy
                    s = WinHttpOpen("camunda-orchestration-sdk-d"w.ptr, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
            }
            if (s is null) throw lastError("cannot open a WinHTTP session for", "");
            return s;
        }

        if (req.caPath.length || req.certPath.length || req.keyPath.length)
            throw new CamundaException("a custom CA file and client certificates (mTLS) are not supported"
                ~ " on Windows yet (camunda/orchestration-cluster-api-dlang#28); trust the CA through the"
                ~ " Windows certificate store and unset the CA path");

        UrlParts u;
        try u = splitUrl(req.url);
        catch (Exception e) throw new CamundaException(e.msg);

        if (session is null) session = openSession();

        auto conn = WinHttpConnect(session, u.host.toUTF16z, u.port, 0);
        if (conn is null) throw lastError("cannot connect to", req.url);
        scope (exit) WinHttpCloseHandle(conn);

        switch (req.method)
        {
        case "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE": break;
        default: throw new CamundaException("unsupported HTTP method: " ~ req.method);
        }
        // ESCAPE_DISABLE: send the target exactly as built (joinUrl already
        // percent-encodes), as curl does.
        auto h = WinHttpOpenRequest(conn, req.method.toUTF16z, u.target.toUTF16z, null,
            WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
            (u.secure ? WINHTTP_FLAG_SECURE : 0) | WINHTTP_FLAG_ESCAPE_DISABLE);
        if (h is null) throw lastError("cannot open a request to", req.url);
        scope (exit) WinHttpCloseHandle(h);

        // The session is shared by every client on this thread: no cookie
        // jar (one client's cookies must not reach another), and no
        // automatic redirects (WinHTTP would replay caller headers such as
        // credentials to the new host). Same behaviour as the curl backend.
        DWORD features = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS;
        if (!WinHttpSetOption(h, WINHTTP_OPTION_DISABLE_FEATURE, &features, DWORD.sizeof))
            throw lastError("cannot configure the request to", req.url);

        // NO_PROXY, with curl's matching, for an explicit and a system proxy.
        import std.process : environment;
        if (noProxyMatches(environment.get("NO_PROXY", environment.get("no_proxy", "")), u.host))
        {
            WINHTTP_PROXY_INFO direct;
            direct.dwAccessType = WINHTTP_ACCESS_TYPE_NO_PROXY;
            if (!WinHttpSetOption(h, WINHTTP_OPTION_PROXY, &direct, WINHTTP_PROXY_INFO.sizeof))
                throw lastError("cannot bypass the proxy for", req.url);
        }

        // One deadline for the whole request: every blocking step gets only
        // the time that is left.
        const timeout = cast(long)(req.timeoutMs > 0 ? req.timeoutMs : 30_000);
        const deadline = MonoTime.currTime + timeout.msecs;
        void armTimeouts(string stage)
        {
            const left = (deadline - MonoTime.currTime).total!"msecs";
            if (left <= 0)
                throw new NetworkException("timed out " ~ stage ~ " " ~ req.url);
            const ms = cast(int)(left > int.max ? int.max : left);
            WinHttpSetTimeouts(h, ms, ms, ms, ms);
        }
        armTimeouts("before sending to");

        const(ubyte)[] payload;
        if (req.rawBody.length) payload = req.rawBody;
        else if (req.body_.length) payload = cast(const(ubyte)[]) req.body_;
        const hasBody = payload.length > 0 && req.method != "GET" && req.method != "HEAD";
        if (!hasBody) payload = null;

        // Headers: the caller's always win. An empty value means "don't
        // send this header" (curl's convention, used for Expect). WinHTTP
        // never sends Expect on its own, so suppressExpect needs nothing.
        string headers;
        foreach (k, v; req.headers)
            if (v.length) headers ~= k ~ ": " ~ v ~ "\r\n";
        if (hasBody && !hasHeaderNamed(req.headers, "content-type"))
            headers ~= "Content-Type: " ~ (req.contentType.length ? req.contentType : "application/json") ~ "\r\n";
        else if (!hasBody && (req.method == "POST" || req.method == "PUT" || req.method == "PATCH"))
            headers ~= "Content-Length: 0\r\n";
        auto wideHeaders = headers.length ? headers.toUTF16z : WINHTTP_NO_ADDITIONAL_HEADERS;

        const len = cast(DWORD) payload.length;
        if (!WinHttpSendRequest(h, wideHeaders, headers.length ? cast(DWORD) -1 : 0,
                cast(void*) payload.ptr, len, len, 0))
            throw lastError("cannot send to", req.url);
        armTimeouts("waiting for a response from");
        if (!WinHttpReceiveResponse(h, null))
            throw lastError("no response from", req.url);

        HttpResponse res;
        DWORD status, size = DWORD.sizeof;
        if (!WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX))
            throw lastError("no status line from", req.url);
        res.status = cast(int) status;

        wchar[512] ct;
        DWORD ctSize = ct.sizeof;
        if (WinHttpQueryHeaders(h, WINHTTP_QUERY_CONTENT_TYPE, WINHTTP_HEADER_NAME_BY_INDEX,
                ct.ptr, &ctSize, WINHTTP_NO_HEADER_INDEX))
            res.contentType = toUTF8(ct[0 .. ctSize / wchar.sizeof]);

        ubyte[] buf;
        ubyte[16 * 1024] chunk;
        for (;;)
        {
            armTimeouts("reading the response from");
            DWORD got;
            if (!WinHttpReadData(h, chunk.ptr, cast(DWORD) chunk.length, &got))
                throw lastError("cannot read the response from", req.url);
            if (MonoTime.currTime > deadline)
                throw new NetworkException("timed out reading the response from " ~ req.url);
            if (got == 0) break;
            buf ~= chunk[0 .. got];
        }
        res.bytes = buf.idup;
        res.body_ = ownText(buf);
        return res;
    }
}

version (Windows) unittest
{
    import std.algorithm.searching : canFind;
    import std.exception : collectException;

    // A CA file or client certificate is refused, not silently ignored.
    HttpRequest tls;
    tls.url = "https://127.0.0.1:9/v2/topology";
    tls.caPath = "ca.pem";
    auto e = collectException!CamundaException(winHttpPerform(tls));
    assert(e !is null && e.msg.canFind("not supported on Windows"), e is null ? "no exception" : e.msg);

    // A refused connection is a NetworkException that says so.
    HttpRequest closed;
    closed.url = "http://127.0.0.1:9/v2/topology";
    closed.timeoutMs = 5_000;
    auto n = collectException!NetworkException(winHttpPerform(closed));
    assert(n !is null && n.msg.canFind("could not connect"), n is null ? "no exception" : n.msg);
}
