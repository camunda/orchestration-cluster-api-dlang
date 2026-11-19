/// HTTP: libcurl on POSIX, WinHTTP on Windows (`camunda.winhttp`). Auth
/// headers, mTLS, retries and backpressure sit above this.
module camunda.http;

@safe:

import camunda.errors;
import camunda.jsonx;
import camunda.safeio : Chan, ownText, readBytes, spawn;
import camunda.transport : hasHeaderNamed, mergeHeadersCaseInsensitive;
import std.json;
version (Windows) {} else import std.net.curl : HTTP, CurlException;
import std.string : toLower;

struct HttpRequest
{
    string method = "GET";
    string url;
    string[string] headers;
    string body_;
    const(ubyte)[] rawBody;
    /// Content-Type of the body. Only sent when there is a body; defaults to
    /// `application/json` then. Bodiless requests carry no Content-Type.
    /// Ignored when `headers` already carries a Content-Type entry (that one
    /// is sent instead).
    string contentType;
    /// Send an empty `Expect` header to suppress curl's `100-continue` round
    /// trip on requests with a body (gateways answer it inconsistently).
    /// Cleared by baseRequest when the caller set an explicit Expect header.
    bool suppressExpect = true;
    long timeoutMs = 30_000;
    // mTLS
    string certPath;
    string keyPath;
    string caPath;
    string keyPassphrase;
    /// Inline PEM (CAMUNDA_MTLS_CERT / _KEY / _CA). Never written to disk:
    /// curl gets them as blobs. At most one of `x` and `xPath` is set.
    string certPem;
    string keyPem;
    string caPem;
}

struct HttpResponse
{
    int status;
    string body_;
    immutable(ubyte)[] bytes;
    string contentType;
}

/// Send `req` and return the response. Connection failures throw
/// `NetworkException`; HTTP error statuses are returned, not thrown.
HttpResponse perform(const ref HttpRequest req)
{
    version (Windows)
    {
        import camunda.winhttp : winHttpPerform;
        return winHttpPerform(req);
    }
    else
        return curlPerform(req);
}

// libcurl >= 7.77 blob options (CURLOPTTYPE_BLOB + n); std.net.curl's
// CurlOption enum predates them.
private enum : int { curlOptSslCertBlob = 40_291, curlOptSslKeyBlob = 40_292, curlOptCaInfoBlob = 40_309 }

/// `struct curl_blob`; CURL_BLOB_COPY makes libcurl keep its own copy.
private struct CurlBlob
{
    const(void)* data;
    size_t len;
    uint flags;
}

/// The CAMUNDA_MTLS_* settings whose inline PEM a given libcurl cannot
/// consume, decided purely from the reported TLS backend and libcurl version.
/// Setting a blob option successfully is not proof of support: several
/// backends accept the option and then silently ignore the blob
/// (<https://curl.se/libcurl/c/tls-options.html>). Inline credentials that
/// never reach the TLS handshake would let a server with optional client
/// authentication accept the request without mTLS, so unsupported
/// combinations must fail closed before any request is sent.
///
/// `sslVersion` is libcurl's `ssl_version` string and `versionNum` its
/// `version_num`. Per-backend minimums from the upstream history
/// (<https://curl.se/libcurl/c/CURLOPT_CAINFO_BLOB.html>): the client
/// certificate/key blobs are OpenSSL-family only (GnuTLS, mbedTLS, wolfSSL
/// and Schannel ignore them); the CA blob is supported by the OpenSSL family
/// from 7.77, by rustls from 7.82, mbedTLS from 7.81, wolfSSL from 8.2 and
/// GnuTLS from 8.18, and never by Schannel.
private string[] missingInlinePemSupport(string sslVersion, uint versionNum,
    bool caPem, bool certPem, bool keyPem)
{
    import std.algorithm.searching : canFind;
    import std.string : indexOf, strip;

    // MultiSSL builds append the inactive backends in parentheses, e.g.
    // `OpenSSL/3.0.8 (GnuTLS/3.7.9)`. Only the active backend (before the
    // first `(`) decides blob support, so drop the parenthesized list.
    string ssl = sslVersion;
    const paren = ssl.indexOf('(');
    if (paren >= 0)
        ssl = ssl[0 .. paren];
    ssl = ssl.strip;

    const v = versionNum;
    const opensslFamily = ssl.canFind("OpenSSL") || ssl.canFind("LibreSSL")
        || ssl.canFind("BoringSSL") || ssl.canFind("AWS-LC") || ssl.canFind("quictls");
    const gnutls = ssl.canFind("GnuTLS");
    const mbedtls = ssl.canFind("mbedTLS");
    const wolfssl = ssl.canFind("wolfSSL");
    const rustls = ssl.canFind("rustls");
    const schannel = ssl.canFind("Schannel");

    string[] missing;
    if (certPem || keyPem)
    {
        // Client cert/key blobs: OpenSSL family only, from 7.77.
        const certKeyOk = opensslFamily && v >= 0x07_4D_00; // 7.77.0
        if (!certKeyOk)
        {
            if (certPem) missing ~= "CAMUNDA_MTLS_CERT";
            if (keyPem) missing ~= "CAMUNDA_MTLS_KEY";
        }
    }
    if (caPem)
    {
        const caOk = (opensslFamily && v >= 0x07_4D_00) // 7.77.0
            || (rustls && v >= 0x07_52_00)   // 7.82.0
            || (mbedtls && v >= 0x07_51_00)  // 7.81.0
            || (wolfssl && v >= 0x08_02_00)  // 8.2.0
            || (gnutls && v >= 0x08_12_00);  // 8.18.0
        if (!caOk) missing ~= "CAMUNDA_MTLS_CA";
    }
    return missing;
}

/// Thin probe: read the running libcurl's backend + version and decide.
/// Must run after libcurl is initialized (`HTTP()` construction performs the
/// synchronized `curl_global_init`); `curl_version_info` is not documented as
/// safe to call before that.
private string[] curlTlsBackendMissingBlobs(const ref HttpRequest req)
{
    import etc.c.curl : CURLVERSION_NOW, curl_version_info;
    import std.string : fromStringz;

    // `@trusted`: `curl_version_info` returns a pointer to libcurl's own
    // static, never-freed info struct; `ssl_version` is a static
    // NUL-terminated string and `version_num` a plain integer. All read-only.
    const probe = () @trusted {
        auto i = curl_version_info(CURLVERSION_NOW);
        static struct Probe { string ssl; uint num; }
        return i is null ? Probe("", 0)
            : Probe(i.ssl_version is null ? "" : fromStringz(i.ssl_version).idup, i.version_num);
    }();
    return missingInlinePemSupport(probe.ssl, probe.num,
        req.caPem.length != 0, req.certPem.length != 0, req.keyPem.length != 0);
}

unittest
{
    // cert/key blobs: OpenSSL family only, from 7.77.
    assert(missingInlinePemSupport("OpenSSL/3.0.8", 0x07_4D_00, false, true, true).length == 0);
    assert(missingInlinePemSupport("OpenSSL/3.0.8", 0x07_4C_00, false, true, true)
        == ["CAMUNDA_MTLS_CERT", "CAMUNDA_MTLS_KEY"]);
    // GnuTLS / mbedTLS / Schannel ignore client cert/key blobs.
    assert(missingInlinePemSupport("GnuTLS/3.7.9", 0x08_12_00, false, true, true).length == 2);
    assert(missingInlinePemSupport("mbedTLS/3.6.0", 0x07_51_00, false, true, false)
        == ["CAMUNDA_MTLS_CERT"]);
    assert(missingInlinePemSupport("Schannel", 0x08_00_00, false, false, true)
        == ["CAMUNDA_MTLS_KEY"]);
    // rustls ignores the client cert/key blobs too.
    assert(missingInlinePemSupport("rustls/1.0", 0x07_52_00, false, true, true).length == 2);

    // CA blob per-backend minimum versions.
    assert(missingInlinePemSupport("OpenSSL/3.0.8", 0x07_4D_00, true, false, false).length == 0);
    assert(missingInlinePemSupport("rustls/1.0", 0x07_52_00, true, false, false).length == 0);
    assert(missingInlinePemSupport("rustls/1.0", 0x07_51_00, true, false, false)
        == ["CAMUNDA_MTLS_CA"]);
    assert(missingInlinePemSupport("mbedTLS/3.6.0", 0x07_51_00, true, false, false).length == 0);
    assert(missingInlinePemSupport("mbedTLS/3.6.0", 0x07_50_00, true, false, false)
        == ["CAMUNDA_MTLS_CA"]);
    assert(missingInlinePemSupport("wolfSSL/5.6", 0x08_02_00, true, false, false).length == 0);
    assert(missingInlinePemSupport("wolfSSL/5.6", 0x08_01_00, true, false, false)
        == ["CAMUNDA_MTLS_CA"]);
    assert(missingInlinePemSupport("GnuTLS/3.7.9", 0x08_12_00, true, false, false).length == 0);
    assert(missingInlinePemSupport("GnuTLS/3.7.9", 0x08_11_00, true, false, false)
        == ["CAMUNDA_MTLS_CA"]);
    // Schannel never takes the CA blob.
    assert(missingInlinePemSupport("Schannel", 0x08_12_00, true, false, false)
        == ["CAMUNDA_MTLS_CA"]);

    // MultiSSL: only the active backend (before the parenthesized list) decides.
    // Active OpenSSL must not be rejected because an inactive GnuTLS is listed.
    assert(missingInlinePemSupport("OpenSSL/3.0.8 (GnuTLS/3.7.9)", 0x08_12_00, true, true, true)
        .length == 0);
    // Active GnuTLS must not be authorized by an inactive supported name.
    assert(missingInlinePemSupport("GnuTLS/3.7.9 (OpenSSL/3.0.8)", 0x08_12_00, false, true, true)
        .length == 2);
    // Inactive rustls must not authorize the CA blob for active GnuTLS < 8.18.
    assert(missingInlinePemSupport("GnuTLS/3.7.9 (rustls/1.0)", 0x08_11_00, true, false, false)
        == ["CAMUNDA_MTLS_CA"]);
}

version (Windows) {} else
{
/// `@trusted`: std.net.curl is `@system` throughout. This only hands it values
/// it reads or copies, and copies every buffer it hands back before keeping it.
///
/// Bodies: std.net.curl's `postData` forces `application/octet-stream`, and
/// `Method.put` switches curl to upload mode (fed by `onSend`, so the body is
/// dropped and sent chunked). Instead every request with a body is a curl
/// POST with `postfields` + the real Content-Type, and PUT/PATCH/DELETE are
/// sent with CURLOPT_CUSTOMREQUEST. (camunda/orchestration-cluster-api-dlang#5)
///
/// Connections: each thread keeps one curl handle per TLS setup
/// (`tlsHandles`) and reuses it, so libcurl keeps the connection alive
/// between requests instead of opening a TCP (and TLS) connection per call.
/// Every request starts from a reset method state and clears what it set
/// (headers, custom verb, body pointer) on the way out, so nothing leaks into
/// the next request on the same handle. A handle whose transfer failed is
/// dropped and rebuilt on next use.
private HttpResponse curlPerform(const ref HttpRequest req) @trusted
{
    import etc.c.curl : CurlOption;
    // Hand inline PEM to curl as a blob. Throws a CamundaException naming the
    // setting when this libcurl or its TLS backend cannot take blobs.
    void setBlob(ref HTTP http, int option, string pem, string setting)
    {
        if (!pem.length) return;
        auto blob = CurlBlob(pem.ptr, pem.length, 1 /* CURL_BLOB_COPY */);
        try
            http.handle.set(cast(CurlOption) option, cast(void*) &blob);
        catch (CurlException e)
            throw new CamundaException(setting ~ " (inline PEM) needs libcurl 7.77 or later with an"
                ~ " OpenSSL-compatible TLS backend; set " ~ setting ~ "_PATH to a file instead (" ~ e.msg ~ ")");
    }

    const tlsKey = req.caPath ~ "\0" ~ req.certPath ~ "\0" ~ req.keyPath ~ "\0" ~ req.keyPassphrase
        ~ "\0" ~ req.caPem ~ "\0" ~ req.certPem ~ "\0" ~ req.keyPem;
    HTTP http;
    if (auto h = tlsKey in tlsHandles) http = *h;
    else
    {
        // Constructing the first `HTTP` runs Phobos' synchronized
        // `curl_global_init`. Probe the TLS backend only after that:
        // `curl_version_info` is not documented as safe before global init,
        // and concurrent first requests would otherwise race on it. The
        // backend check still throws before any network request is sent.
        http = HTTP();
        // Fail closed when this libcurl's TLS backend would silently drop the
        // inline PEM (curl.se support table).
        if (const missing = curlTlsBackendMissingBlobs(req))
        {
            import std.array : join;
            throw new CamundaException("inline PEM (" ~ missing.join(", ") ~ ") is not supported by"
                ~ " this libcurl's TLS backend; set the matching *_PATH file settings instead");
        }
        if (req.caPath.length) http.caInfo = req.caPath;
        if (req.certPath.length)
        {
            http.handle.set(CurlOption.sslcert, req.certPath);
            if (req.keyPath.length) http.handle.set(CurlOption.sslkey, req.keyPath);
        }
        if (req.keyPassphrase.length) http.handle.set(CurlOption.keypasswd, req.keyPassphrase);
        setBlob(http, curlOptCaInfoBlob, req.caPem, "CAMUNDA_MTLS_CA");
        setBlob(http, curlOptSslCertBlob, req.certPem, "CAMUNDA_MTLS_CERT");
        setBlob(http, curlOptSslKeyBlob, req.keyPem, "CAMUNDA_MTLS_KEY");
        tlsHandles[tlsKey] = http;
    }
    http.url = req.url;
    // Reset the method (GET clears POST/upload/nobody) and the verb override.
    http.handle.set(CurlOption.httpget, 1L);
    http.handle.clear(CurlOption.customrequest);
    http.method = HTTP.Method.undefined;
    http.clearRequestHeaders();
    scope (exit)
    {
        // `setPostData` keeps a pointer to `payload` without copying it:
        // never leave it on the handle past this call.
        http.clearRequestHeaders();
        http.handle.clear(CurlOption.customrequest);
        http.handle.clear(CurlOption.postfields);
        http.handle.set(CurlOption.httpget, 1L);
        http.onReceive = null;
        http.onReceiveHeader = null;
    }
    foreach (k, v; req.headers) http.addRequestHeader(k, v);
    import core.time : msecs;
    http.connectTimeout = (req.timeoutMs > 0 ? req.timeoutMs : 30_000).msecs;
    http.operationTimeout = (req.timeoutMs > 0 ? req.timeoutMs : 30_000).msecs;

    const(void)[] payload;
    if (req.rawBody.length) payload = req.rawBody;
    else if (req.body_.length) payload = req.body_;
    const hasBody = payload.length > 0 && req.method != "GET" && req.method != "HEAD";
    // Content-Type/Expect defaults are filled in only when the caller's
    // headers do not already carry the name: an explicit custom header always
    // wins, for every request shape. (camunda/orchestration-cluster-api-dlang#12)
    const customContentType = hasHeaderNamed(req.headers, "content-type");
    const customExpect = hasHeaderNamed(req.headers, "expect");
    if (hasBody)
    {
        http.method = HTTP.Method.post;
        http.setPostData(payload,
            customContentType ? "" : req.contentType.length ? req.contentType : "application/json");
        if (req.suppressExpect && !customExpect) http.addRequestHeader("Expect", "");
        if (req.method != "POST") http.handle.set(CurlOption.customrequest, req.method);
    }
    else switch (req.method)
    {
    case "GET": http.method = HTTP.Method.get; break;
    case "DELETE": http.method = HTTP.Method.del; break;
    case "POST", "PUT", "PATCH":
        // Bodiless write: an empty POST (Content-Length: 0), with libcurl's
        // default form Content-Type removed, and the verb overridden.
        http.method = HTTP.Method.post;
        http.handle.set(CurlOption.postfields, "");
        http.handle.set(CurlOption.postfieldsize, 0L);
        if (!customContentType) http.addRequestHeader("Content-Type", "");
        if (req.method != "POST") http.handle.set(CurlOption.customrequest, req.method);
        break;
    default:
        throw new CamundaException("unsupported HTTP method: " ~ req.method);
    }

    ubyte[] buf;
    string contentType;
    http.onReceiveHeader = (in char[] key, in char[] value) {
        if (key.idup.toLower == "content-type") contentType = value.idup;
    };
    http.onReceive = (ubyte[] data) {
        buf ~= data;
        return data.length;
    };
    try http.perform();
    catch (CurlException e)
    {
        tlsHandles.remove(tlsKey);
        throw new NetworkException(e.msg, __FILE__, __LINE__, e);
    }

    HttpResponse res;
    res.status = http.statusLine.code;
    res.contentType = contentType;
    res.bytes = buf.idup;
    res.body_ = ownText(buf);
    return res;
}

/// This thread's curl handles, one per TLS setup (module variables are
/// thread-local in D, so no other thread ever sees them). TLS options are
/// fixed per handle, so a request with a different CA or client certificate
/// never inherits another's.
private HTTP[string] tlsHandles;
}

string encodeQuery(string[string] query)
{
    if (query is null) return "";
    import std.uri : encodeComponent;
    string out_;
    foreach (k, v; query)
    {
        if (v is null) continue;
        if (out_.length) out_ ~= "&";
        out_ ~= encodeComponent(k) ~ "=" ~ encodeComponent(v);
    }
    return out_;
}

string joinUrl(string base, string path, string[string] query = null)
{
    auto b = base;
    while (b.length && b[$ - 1] == '/') b = b[0 .. $ - 1];
    auto p = path;
    if (!p.length || p[0] != '/') p = "/" ~ p;
    auto url = b ~ p;
    auto q = encodeQuery(query);
    if (q.length) url ~= "?" ~ q;
    return url;
}

unittest
{
    assert(joinUrl("http://localhost:8080/v2", "/topology") == "http://localhost:8080/v2/topology");
    assert(joinUrl("http://localhost:8080/v2/", "topology") == "http://localhost:8080/v2/topology");
    auto q = ["a": "b c"];
    assert(joinUrl("http://x", "/p", q) == "http://x/p?a=b%20c");
}

version (unittest)
{
    /// One-shot server for `captureRequest`: sends its port on `port`, reads
    /// one whole request (head, then a Content-Length body), sends it on
    /// `seen`, and answers `200 {}`.
    private void captureServer(Chan!int port, Chan!string seen)
    {
        import std.socket : TcpSocket, InternetAddress;
        import std.conv : to;
        import std.string : indexOf, strip, toLower;
        auto listener = new TcpSocket();
        scope (exit) listener.close();
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(4);
        port.put((cast(InternetAddress) listener.localAddress).port);
        auto conn = listener.accept();
        scope (exit) conn.close();
        string got;
        ubyte[4096] chunk;
        for (;;)
        {
            const end = got.indexOf("\r\n\r\n");
            if (end >= 0)
            {
                size_t bodyLen;
                const head = got[0 .. end + 4];
                const cl = head.toLower.indexOf("\r\ncontent-length:");
                if (cl >= 0)
                {
                    auto rest = head[cl + 17 .. $];
                    bodyLen = rest[0 .. rest.indexOf("\r\n")].strip.to!size_t;
                }
                // `Expect: 100-continue`: say continue, or the body waits.
                if (got.length == head.length && bodyLen && head.toLower.indexOf("\r\nexpect: 100-continue") >= 0)
                    conn.send("HTTP/1.1 100 Continue\r\n\r\n");
                if (got.length >= head.length + bodyLen) break;
            }
            const n = conn.receive(chunk[]);
            if (n <= 0) break;
            got ~= cast(const(char)[]) chunk[0 .. n];
        }
        seen.put(got);
        conn.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
    }

    /// Send `req` to a one-shot local server and return the raw request it
    /// received. Works the same for every backend (curl, WinHTTP), because
    /// the server reads on its own thread while the client sends.
    private string captureRequest(HttpRequest req)
    {
        import std.conv : to;
        auto port = Chan!int.make;
        auto seen = Chan!string.make;
        auto server = spawn(&captureServer, port, seen);
        int p;
        port.take(p);
        req.url = "http://127.0.0.1:" ~ p.to!string ~ "/v2/things";
        req.timeoutMs = 10_000;
        auto res = perform(req);
        assert(res.status == 200, "capture server answered " ~ res.status.to!string);
        string got;
        seen.take(got);
        server.join();
        return got;
    }

    private bool hasHeader(string raw, string line)
    {
        import std.algorithm.searching : canFind;
        import std.uni : toLower;
        return raw.toLower.canFind("\r\n" ~ line.toLower ~ "\r\n");
    }

    private string bodyOf(string raw)
    {
        import std.string : indexOf;
        const i = raw.indexOf("\r\n\r\n");
        return i < 0 ? null : raw[i + 4 .. $];
    }
}

// camunda/orchestration-cluster-api-dlang#5: method, Content-Type and body on the wire.
unittest
{
    import std.algorithm.searching : startsWith, canFind;
    import std.uni : toLower;
    foreach (m; ["POST", "PUT", "PATCH", "DELETE"])
    {
        HttpRequest req;
        req.method = m;
        req.body_ = `{"name":"n"}`;
        req.contentType = "application/json";
        auto raw = captureRequest(req);
        assert(raw.startsWith(m ~ " /v2/things HTTP/1.1\r\n"), raw);
        assert(hasHeader(raw, "content-type: application/json"), raw);
        import std.algorithm.searching : count;
        assert(raw.toLower.count("content-type:") == 1, raw); // no octet-stream duplicate
        assert(hasHeader(raw, "content-length: 12"), raw);
        assert(!raw.toLower.canFind("transfer-encoding"), raw);
        assert(!raw.toLower.canFind("expect:"), raw);
        assert(bodyOf(raw) == `{"name":"n"}`, raw);
    }
}

unittest
{
    // Multipart keeps its boundary; JSON is the default for an untyped body.
    import std.algorithm.searching : startsWith;
    HttpRequest mp;
    mp.method = "POST";
    mp.contentType = "multipart/form-data; boundary=XyZ";
    mp.rawBody = cast(const(ubyte)[]) "--XyZ\r\n\r\nhi\r\n--XyZ--\r\n";
    auto raw = captureRequest(mp);
    assert(hasHeader(raw, "content-type: multipart/form-data; boundary=XyZ"), raw);
    assert(bodyOf(raw) == "--XyZ\r\n\r\nhi\r\n--XyZ--\r\n", raw);

    HttpRequest untyped;
    untyped.method = "POST";
    untyped.body_ = "{}";
    assert(hasHeader(captureRequest(untyped), "content-type: application/json"));
}

unittest
{
    // Bodiless requests carry no Content-Type; bodiless writes send Content-Length: 0.
    import std.algorithm.searching : startsWith, canFind;
    import std.uni : toLower;
    foreach (m; ["GET", "DELETE", "POST", "PUT"])
    {
        HttpRequest req;
        req.method = m;
        auto raw = captureRequest(req);
        assert(raw.startsWith(m ~ " /v2/things HTTP/1.1\r\n"), raw);
        assert(!raw.toLower.canFind("content-type"), raw);
        if (m == "POST" || m == "PUT") assert(hasHeader(raw, "content-length: 0"), raw);
    }
}

// camunda/orchestration-cluster-api-dlang#11: custom headers on the wire.
unittest
{
    import std.algorithm.searching : canFind, count, startsWith;
    import std.uni : toLower;

    // JSON body: custom headers ride along; an Authorization entry under a
    // different case replaces the SDK one (no duplicate line).
    HttpRequest json;
    json.method = "POST";
    json.body_ = `{"name":"n"}`;
    json.contentType = "application/json";
    json.headers["Authorization"] = "Bearer sdk-token";
    json.headers["Accept"] = "application/json, */*";
    json.headers = mergeHeadersCaseInsensitive(json.headers,
        ["X-Api-Key": "secret-key", "authorization": "Bearer gateway-token"]);
    auto rawJson = captureRequest(json);
    assert(hasHeader(rawJson, "x-api-key: secret-key"), rawJson);
    assert(hasHeader(rawJson, "authorization: Bearer gateway-token"), rawJson);
    assert(!rawJson.toLower.canFind("sdk-token"), rawJson);
    assert(rawJson.toLower.count("authorization:") == 1, rawJson);
    assert(hasHeader(rawJson, "content-type: application/json"), rawJson);
    assert(bodyOf(rawJson) == `{"name":"n"}`, rawJson);

    // Multipart: the boundary Content-Type survives and custom headers are sent.
    HttpRequest mp;
    mp.method = "POST";
    mp.contentType = "multipart/form-data; boundary=XyZ";
    mp.rawBody = cast(const(ubyte)[]) "--XyZ\r\n\r\nhi\r\n--XyZ--\r\n";
    mp.headers = mergeHeadersCaseInsensitive(mp.headers, ["X-Api-Key": "secret-key"]);
    auto rawMp = captureRequest(mp);
    assert(hasHeader(rawMp, "x-api-key: secret-key"), rawMp);
    assert(hasHeader(rawMp, "content-type: multipart/form-data; boundary=XyZ"), rawMp);
    assert(bodyOf(rawMp) == "--XyZ\r\n\r\nhi\r\n--XyZ--\r\n", rawMp);

    // Bodiless: custom headers are sent, still no Content-Type.
    HttpRequest get;
    get.method = "GET";
    get.headers = mergeHeadersCaseInsensitive(get.headers, ["X-Api-Key": "secret-key"]);
    auto rawGet = captureRequest(get);
    assert(rawGet.startsWith("GET /v2/things HTTP/1.1\r\n"), rawGet);
    assert(hasHeader(rawGet, "x-api-key: secret-key"), rawGet);
    assert(!rawGet.toLower.canFind("content-type"), rawGet);
}

// camunda/orchestration-cluster-api-dlang#12: a custom Content-Type or Expect
// wins over the body-related defaults perform() would otherwise add later.
unittest
{
    import std.algorithm.searching : canFind, count, startsWith;
    import std.uni : toLower;

    // JSON body: the custom Content-Type is the only one on the wire.
    HttpRequest json;
    json.method = "POST";
    json.body_ = `{"name":"n"}`;
    json.contentType = "application/json";
    json.headers["content-type"] = "application/vnd.custom+json";
    auto rawJson = captureRequest(json);
    assert(hasHeader(rawJson, "content-type: application/vnd.custom+json"), rawJson);
    assert(rawJson.toLower.count("content-type:") == 1, rawJson);
    assert(!rawJson.canFind("application/json"), rawJson);
    assert(bodyOf(rawJson) == `{"name":"n"}`, rawJson);

    // Multipart: same, with a raw body.
    HttpRequest mp;
    mp.method = "POST";
    mp.contentType = "multipart/form-data; boundary=XyZ";
    mp.rawBody = cast(const(ubyte)[]) "--XyZ\r\n\r\nhi\r\n--XyZ--\r\n";
    mp.headers["Content-Type"] = "multipart/related; boundary=XyZ";
    auto rawMp = captureRequest(mp);
    assert(hasHeader(rawMp, "content-type: multipart/related; boundary=XyZ"), rawMp);
    assert(rawMp.toLower.count("content-type:") == 1, rawMp);
    assert(bodyOf(rawMp) == "--XyZ\r\n\r\nhi\r\n--XyZ--\r\n", rawMp);

    // Bodiless write: the custom Content-Type replaces the empty suppression
    // header, it is not overwritten by it.
    HttpRequest put;
    put.method = "PUT";
    put.headers["Content-Type"] = "application/vnd.empty";
    auto rawPut = captureRequest(put);
    assert(rawPut.startsWith("PUT /v2/things HTTP/1.1\r\n"), rawPut);
    assert(hasHeader(rawPut, "content-type: application/vnd.empty"), rawPut);
    assert(rawPut.toLower.count("content-type:") == 1, rawPut);

    // A custom Expect replaces the 100-continue suppression default.
    HttpRequest exp;
    exp.method = "POST";
    exp.body_ = "{}";
    exp.headers["Expect"] = "100-continue";
    auto rawExp = captureRequest(exp);
    assert(hasHeader(rawExp, "expect: 100-continue"), rawExp);
    assert(rawExp.toLower.count("expect:") == 1, rawExp);
}

version (unittest)
{
    /// A keep-alive HTTP/1.1 server on its own thread: answers `requests`
    /// requests with `{}`, sending each raw request (head and body, framed
    /// by Content-Length) on `seen`. The port goes out first on `out_`, the
    /// number of TCP connections it accepted last.
    private void countingServer(int requests, Chan!int out_, Chan!string seen)
    {
        import std.socket : TcpSocket, InternetAddress, Socket, SocketSet, SocketOption, SocketOptionLevel;
        import std.conv : to;
        import std.string : indexOf, toLower;
        auto listener = new TcpSocket();
        scope (exit) listener.close();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(16);
        out_.put((cast(InternetAddress) listener.localAddress).port);
        Socket[] conns;
        string[] pending;
        int accepted, answered;
        auto set = new SocketSet();
        while (answered < requests)
        {
            set.reset();
            set.add(listener);
            foreach (c; conns) set.add(c);
            if (Socket.select(set, null, null) <= 0) continue;
            if (set.isSet(listener))
            {
                conns ~= listener.accept();
                pending ~= "";
                accepted++;
            }
            foreach (i, c; conns)
            {
                if (!set.isSet(c)) continue;
                ubyte[4096] chunk;
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
                        import std.string : strip;
                        bodyLen = rest[0 .. rest.indexOf("\r\n")].strip.to!size_t;
                    }
                    if (pending[i].length < head.length + bodyLen) break;
                    seen.put(pending[i][0 .. head.length + bodyLen]);
                    pending[i] = pending[i][head.length + bodyLen .. $];
                    c.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
                    answered++;
                }
            }
        }
        foreach (c; conns) c.close();
        out_.put(accepted);
        seen.close();
    }
}

// Sequential requests on one thread reuse one connection (keep-alive)
// instead of opening a TCP connection per request, and nothing one request
// set on the reused handle (verb override, body, Content-Type) leaks into
// the next.
unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.conv : to;
    import std.uni : toLower;
    auto ch = Chan!int.make;
    auto seen = Chan!string.make;
    auto server = spawn(&countingServer, 6, ch, seen);
    int port;
    ch.take(port);
    const base = "http://127.0.0.1:" ~ port.to!string;
    void send(string method, string body_ = null)
    {
        HttpRequest req;
        req.method = method;
        req.body_ = body_;
        req.url = base ~ "/v2/things";
        auto res = perform(req);
        assert(res.status == 200 && res.body_ == "{}", res.body_);
    }
    send("POST", `{"a":1}`);
    send("PATCH", `{"b":2}`);
    send("DELETE");
    send("GET");
    send("PUT");
    send("GET");
    string[] raw;
    string r;
    while (seen.take(r)) raw ~= r;
    int accepted;
    ch.take(accepted);
    server.join();
    assert(accepted == 1, "expected 1 connection for 6 requests, got " ~ accepted.to!string);
    assert(raw.length == 6);
    assert(raw[0].startsWith("POST /v2/things ") && bodyOf(raw[0]) == `{"a":1}`, raw[0]);
    assert(raw[1].startsWith("PATCH /v2/things ") && bodyOf(raw[1]) == `{"b":2}`, raw[1]);
    foreach (i, want; ["DELETE", "GET"])
    {
        auto req = raw[2 + i];
        assert(req.startsWith(want ~ " /v2/things "), req);
        assert(!req.toLower.canFind("content-type:"), req);
        assert(!req.toLower.canFind("content-length:") || hasHeader(req, "content-length: 0"), req);
        assert(bodyOf(req) == "", req);
    }
    assert(raw[4].startsWith("PUT /v2/things ") && hasHeader(raw[4], "content-length: 0"), raw[4]);
    assert(raw[5].startsWith("GET /v2/things ") && bodyOf(raw[5]) == "", raw[5]);
}

version (unittest)
{
    /// Answers its first request slowly: the head after `delayMs`, then the
    /// body after another `delayMs`.
    private void slowServer(Chan!int port, int delayMs)
    {
        import core.thread : Thread;
        import core.time : msecs;
        import std.socket : TcpSocket, InternetAddress;
        auto listener = new TcpSocket();
        scope (exit) listener.close();
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(4);
        port.put((cast(InternetAddress) listener.localAddress).port);
        auto conn = listener.accept();
        scope (exit) conn.close();
        ubyte[4096] chunk;
        conn.receive(chunk[]);
        Thread.sleep(delayMs.msecs);
        conn.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n");
        Thread.sleep(delayMs.msecs);
        conn.send("{}");
    }
}

// The request timeout bounds the whole exchange, not each step: a head that
// arrives just in time followed by a slow body still times out.
unittest
{
    import std.conv : to;
    import std.exception : collectException;
    import camunda.errors : NetworkException;

    auto port = Chan!int.make;
    auto server = spawn(&slowServer, port, 700);
    int p;
    port.take(p);
    HttpRequest req;
    req.method = "GET";
    req.url = "http://127.0.0.1:" ~ p.to!string ~ "/v2/slow";
    req.timeoutMs = 1_000;
    auto e = collectException!NetworkException(perform(req));
    server.join();
    assert(e !is null, "a 1400 ms exchange finished inside a 1000 ms timeout");
}
