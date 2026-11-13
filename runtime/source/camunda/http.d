/// HTTP over libcurl. Auth headers, mTLS, retries and backpressure sit above this.
module camunda.http;

@safe:

import camunda.errors;
import camunda.jsonx;
import camunda.safeio : ownText, readBytes;
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
    string contentType = "application/json";
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
HttpResponse perform(const ref HttpRequest req) @trusted
{
    auto http = HTTP(req.url);
    switch (req.method)
    {
    case "GET": http.method = HTTP.Method.get; break;
    case "POST": http.method = HTTP.Method.post; break;
    case "PUT": http.method = HTTP.Method.put; break;
    case "PATCH": http.method = HTTP.Method.patch; break;
    case "DELETE": http.method = HTTP.Method.del; break;
    default: http.method = HTTP.Method.get; break;
    }
    foreach (k, v; req.headers) http.addRequestHeader(k, v);
    if (req.contentType.length) http.addRequestHeader("Content-Type", req.contentType);
    import core.time : msecs;
    http.connectTimeout = (req.timeoutMs > 0 ? req.timeoutMs : 30_000).msecs;
    http.operationTimeout = (req.timeoutMs > 0 ? req.timeoutMs : 30_000).msecs;

    if (req.caPath.length) http.caInfo = req.caPath;
    if (req.certPath.length)
    {
        import etc.c.curl : CurlOption;
        http.handle.set(CurlOption.sslcert, req.certPath);
        if (req.keyPath.length) http.handle.set(CurlOption.sslkey, req.keyPath);
        if (req.keyPassphrase.length) http.handle.set(CurlOption.keypasswd, req.keyPassphrase);
    }

    const(void)[] payload;
    if (req.rawBody.length) payload = req.rawBody;
    else if (req.body_.length) payload = req.body_;
    if (payload.length && req.method != "GET") http.postData = payload;

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
