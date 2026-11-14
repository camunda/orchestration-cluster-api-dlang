/// HTTP over libcurl. Auth headers, mTLS, retries and backpressure sit above this.
module camunda.http;

@safe:

import camunda.errors;
import camunda.jsonx;
import camunda.safeio : ownText, readBytes;
import camunda.transport : mergeHeadersCaseInsensitive;
import std.json;
import std.net.curl : HTTP, CurlException;
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
    string contentType;
    long timeoutMs = 30_000;
    // mTLS
    string certPath;
    string keyPath;
    string caPath;
    string keyPassphrase;
}

struct HttpResponse
{
    int status;
    string body_;
    immutable(ubyte)[] bytes;
    string contentType;
}

/// `@trusted`: std.net.curl is `@system` throughout. This only hands it values
/// it reads or copies, and copies every buffer it hands back before keeping it.
///
/// Bodies: std.net.curl's `postData` forces `application/octet-stream`, and
/// `Method.put` switches curl to upload mode (fed by `onSend`, so the body is
/// dropped and sent chunked). Instead every request with a body is a curl
/// POST with `postfields` + the real Content-Type, and PUT/PATCH/DELETE are
/// sent with CURLOPT_CUSTOMREQUEST. (camunda/orchestration-cluster-api-dlang#5)
HttpResponse perform(const ref HttpRequest req) @trusted
{
    import etc.c.curl : CurlOption;
    auto http = HTTP(req.url);
    foreach (k, v; req.headers) http.addRequestHeader(k, v);
    import core.time : msecs;
    http.connectTimeout = (req.timeoutMs > 0 ? req.timeoutMs : 30_000).msecs;
    http.operationTimeout = (req.timeoutMs > 0 ? req.timeoutMs : 30_000).msecs;

    if (req.caPath.length) http.caInfo = req.caPath;
    if (req.certPath.length)
    {
        http.handle.set(CurlOption.sslcert, req.certPath);
        if (req.keyPath.length) http.handle.set(CurlOption.sslkey, req.keyPath);
        if (req.keyPassphrase.length) http.handle.set(CurlOption.keypasswd, req.keyPassphrase);
    }

    const(void)[] payload;
    if (req.rawBody.length) payload = req.rawBody;
    else if (req.body_.length) payload = req.body_;
    const hasBody = payload.length > 0 && req.method != "GET" && req.method != "HEAD";
    if (hasBody)
    {
        http.method = HTTP.Method.post;
        http.setPostData(payload, req.contentType.length ? req.contentType : "application/json");
        // No `Expect: 100-continue` round trip (gateways answer it inconsistently).
        http.addRequestHeader("Expect", "");
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
        http.addRequestHeader("Content-Type", "");
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
        throw new NetworkException(e.msg, __FILE__, __LINE__, e);

    HttpResponse res;
    res.status = http.statusLine.code;
    res.contentType = contentType;
    res.bytes = buf.idup;
    res.body_ = ownText(buf);
    return res;
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
    /// Send `req` at a listener that never answers, then read what curl wrote.
    /// Single-threaded: the kernel completes the TCP handshake from the listen
    /// backlog, curl writes the whole request and times out waiting for a
    /// response, and only then is the queued connection accepted and drained.
    private string captureRequest(HttpRequest req)
    {
        import std.socket : TcpSocket, InternetAddress, SocketShutdown;
        import std.conv : to;
        auto listener = new TcpSocket();
        scope (exit) listener.close();
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(4);
        const port = (cast(InternetAddress) listener.localAddress).port;
        req.url = "http://127.0.0.1:" ~ port.to!string ~ "/v2/things";
        req.timeoutMs = 400;
        try { perform(req); assert(false, "expected a timeout"); }
        catch (NetworkException) {}
        auto conn = listener.accept();
        scope (exit) conn.close();
        conn.blocking = false;
        string got;
        ubyte[4096] chunk;
        for (;;)
        {
            const n = conn.receive(chunk[]);
            if (n <= 0) break;
            got ~= cast(const(char)[]) chunk[0 .. n];
        }
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
