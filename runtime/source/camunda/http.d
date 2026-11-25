/// HTTP: libcurl's multi interface (`camunda.curlio`) behind an `HttpEngine`
/// that runs requests on its own I/O thread. Auth headers, mTLS, retries and
/// backpressure sit above this.
module camunda.http;

@safe:

import camunda.errors;
import camunda.jsonx;
import camunda.safeio : Chan, Lock, ThreadSafe, ownText, readBytes, spawnDaemon;
import camunda.transport : hasHeaderNamed, mergeHeadersCaseInsensitive;
import std.json;
import std.string : toLower;
version (unittest) import camunda.safeio : spawn;

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
    /// A long poll (job activation): see `WireRequest.longPoll`.
    bool longPoll;
}

struct HttpResponse
{
    int status;
    string body_;
    immutable(ubyte)[] bytes;
    string contentType;
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
/// certificate/key blobs are OpenSSL-family only, from 7.71 (GnuTLS, mbedTLS, wolfSSL
/// and Schannel ignore them); the CA blob is supported by the OpenSSL family
/// from 7.77, by rustls from 7.82, mbedTLS from 7.81, wolfSSL from 8.2 and
/// GnuTLS from 8.18, and never by Schannel.
private string[] missingInlinePemSupport(string sslVersion, uint versionNum,
    bool caPem, bool certPem, bool keyPem)
{
    import std.algorithm.searching : canFind;
    import std.string : indexOf, strip;

    // MultiSSL builds list the inactive backends in parentheses, before or
    // after the active one: `OpenSSL/3.0.8 (GnuTLS/3.7.9)` or
    // `(SecureTransport) LibreSSL/3.3.6`. Remove every parenthesized segment
    // wherever it occurs so only the active backend decides blob support.
    // An unbalanced `(` drops the rest (fail closed: unknown => unsupported).
    string ssl;
    {
        string rest = sslVersion;
        for (;;)
        {
            const open = rest.indexOf('(');
            if (open < 0) { ssl ~= rest; break; }
            ssl ~= rest[0 .. open];
            const close = rest[open .. $].indexOf(')');
            if (close < 0) break;
            rest = rest[open + close + 1 .. $];
        }
    }
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
        // Client cert/key blobs: OpenSSL family only, from 7.71.
        const certKeyOk = opensslFamily && v >= 0x07_47_00; // 7.71.0
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
/// Must run after libcurl is initialized (`curlGlobalInitOnce`, which `toWire`
/// calls first); `curl_version_info` is not documented as
/// safe to call before that.
package(camunda) string[] curlTlsBackendMissingBlobs(const ref HttpRequest req)
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
    // cert/key blobs: OpenSSL family only, from 7.71.
    assert(missingInlinePemSupport("OpenSSL/3.0.8", 0x07_47_00, false, true, true).length == 0);
    assert(missingInlinePemSupport("OpenSSL/3.0.8", 0x07_46_00, false, true, true)
        == ["CAMUNDA_MTLS_CERT", "CAMUNDA_MTLS_KEY"]);
    // The CA blob keeps its 7.77 floor while cert/key are accepted.
    assert(missingInlinePemSupport("OpenSSL/3.0.8", 0x07_4C_00, true, true, true)
        == ["CAMUNDA_MTLS_CA"]);
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
    // Leading inactive backend (macOS: `(SecureTransport) LibreSSL/3.3.6`).
    assert(missingInlinePemSupport("(SecureTransport) LibreSSL/3.3.6", 0x08_07_01, true, true, true)
        .length == 0);
    // A leading inactive supported name must not authorize the active backend.
    assert(missingInlinePemSupport("(OpenSSL/3.0.8) GnuTLS/3.7.9", 0x08_12_00, false, true, false)
        == ["CAMUNDA_MTLS_CERT"]);
    // Unbalanced parenthesis: everything after `(` is ignored (fail closed).
    assert(missingInlinePemSupport("GnuTLS/3.7.9 (OpenSSL/3.0.8", 0x08_12_00, false, true, false)
        == ["CAMUNDA_MTLS_CERT"]);
}

/// A request as handed to an `HttpEngine`'s I/O thread: an immutable copy,
/// so it may cross threads.
package(camunda) struct WireRequest
{
    string method;
    string url;
    /// `name, value` pairs, in no particular order.
    immutable(string[2])[] headers;
    immutable(ubyte)[] body_;
    string contentType;
    bool suppressExpect;
    long timeoutMs;
    string certPath, keyPath, caPath, keyPassphrase;
    string certPem, keyPem, caPem;
    /// A long poll (job activation): it may wait on the server for a long
    /// time, so it does not count against the engine's connection limit.
    bool longPoll;

    /// The request this was made from.
    HttpRequest toRequest() const
    {
        HttpRequest r;
        r.method = method;
        r.url = url;
        foreach (h; headers) r.headers[h[0]] = h[1];
        r.rawBody = body_;
        r.contentType = contentType;
        r.suppressExpect = suppressExpect;
        r.timeoutMs = timeoutMs;
        r.certPath = certPath;
        r.keyPath = keyPath;
        r.caPath = caPath;
        r.keyPassphrase = keyPassphrase;
        r.certPem = certPem;
        r.keyPem = keyPem;
        r.caPem = caPem;
        r.longPoll = longPoll;
        return r;
    }
}

/// Copy `req` for the I/O thread. Throws a `CamundaException` for what can
/// never be sent (an unsupported method, inline PEM this libcurl would
/// drop) before anything reaches the network.
package(camunda) WireRequest toWire(const ref HttpRequest req)
{
    switch (req.method)
    {
    case "GET", "POST", "PUT", "PATCH", "DELETE": break;
    default: throw new CamundaException("unsupported HTTP method: " ~ req.method);
    }
    import camunda.curlio : curlGlobalInitOnce;
    // `curl_version_info` is only documented as safe after global init.
    curlGlobalInitOnce();
    // Fail closed when this libcurl's TLS backend would silently drop
    // the inline PEM (curl.se support table).
    if (const missing = curlTlsBackendMissingBlobs(req))
    {
        import std.array : join;
        throw new CamundaException("inline PEM (" ~ missing.join(", ") ~ ") is not supported by"
            ~ " this libcurl's TLS backend; set the matching *_PATH file settings instead");
    }
    WireRequest w;
    w.method = req.method;
    w.url = req.url;
    foreach (k, v; req.headers) w.headers ~= [k, v];
    if (req.rawBody.length) w.body_ = req.rawBody.idup;
    else if (req.body_.length) w.body_ = cast(immutable(ubyte)[]) req.body_;
    w.contentType = req.contentType;
    w.suppressExpect = req.suppressExpect;
    w.timeoutMs = req.timeoutMs > 0 ? req.timeoutMs : 30_000;
    w.certPath = req.certPath;
    w.keyPath = req.keyPath;
    w.caPath = req.caPath;
    w.keyPassphrase = req.keyPassphrase;
    w.certPem = req.certPem;
    w.keyPem = req.keyPem;
    w.caPem = req.caPem;
    w.longPoll = req.longPoll;
    return w;
}

/// The outcome of a submitted request.
package(camunda) struct HttpResult
{
    /// The caller's tag, passed through.
    long tag;
    /// The response (any HTTP status) when `error` is empty.
    HttpResponse response;
    /// Why no response arrived (connection refused, timeout, ...).
    string error;
    /// `error` is a configuration problem (a TLS setting libcurl refused),
    /// not a network one.
    bool configError;
    /// `error` is an authentication failure (the token request failed):
    /// `get` throws `AuthException`, as the blocking transport does.
    bool authError;

    /// The response; throws `AuthException` for an authentication
    /// failure, `CamundaException` for a configuration problem, or
    /// `NetworkException` when there is none.
    HttpResponse get() const
    {
        import std.algorithm.searching : startsWith;
        enum authPrefix = "authentication error: ";
        if (authError)
            throw new AuthException(error.startsWith(authPrefix) ? error[authPrefix.length .. $] : error);
        if (configError) throw new CamundaException(error);
        if (error.length) throw new NetworkException(error);
        return cast(HttpResponse) response;
    }
}

/// Where an `HttpEngine` delivers results. `deliver` runs on the I/O
/// thread: it must be quick, must not throw, and must be thread-safe.
package(camunda) abstract class HttpSink
{
    abstract void deliver(HttpResult result) @safe;
}

/// An `HttpSink` that puts every result on a channel.
package(camunda) final class ChanSink : HttpSink
{
    private Chan!HttpResult ch;
    this(Chan!HttpResult ch) { this.ch = ch; }
    override void deliver(HttpResult result) { ch.put(result); }

    /// A sink for `ch`, as other threads may hold it.
    static ThreadSafe!HttpSink of(Chan!HttpResult ch)
    {
        // `ch` is the only state, and a channel is thread-safe.
        return ThreadSafe!HttpSink.assumeThreadSafe(new ChanSink(ch));
    }
}

/// A submitted request, queued for the I/O thread.
package(camunda) struct Submission
{
    WireRequest req;
    ThreadSafe!HttpSink sink;
    long tag;
    /// When it was submitted (`monoNowMs`): its timeout runs from here, so
    /// time spent queued for a connection counts against it.
    long submittedMs;

    /// What is left of the request's timeout; 0 or less when it expired
    /// while queued.
    long remainingMs(long nowMs) const
    {
        return req.timeoutMs - (nowMs - submittedMs);
    }
}

/// The result for a submission whose timeout ran out before it was sent.
package(camunda) HttpResult queuedTimeout(ref const Submission s)
{
    HttpResult r;
    r.tag = s.tag;
    import std.conv : to;
    r.error = "Timeout was reached: queued for a connection for longer than the "
        ~ s.req.timeoutMs.to!string ~ " ms timeout";
    return r;
}

/// Runs HTTP requests on its own I/O thread over a small pool of keep-alive
/// connections.
///
/// One thread drives libcurl's multi interface: every request runs there,
/// and at most `maxConnections` ordinary requests are in flight at once
/// (more wait in a queue), so connections are reused between requests
/// instead of opened per request. Long polls (`HttpRequest.longPoll`, job
/// activation) do not count against the limit.
///
/// The I/O thread starts with the first request and exits after a few
/// seconds without work (closing its connections); the next request starts
/// it again.
final class HttpEngine
{
    private Lock lock;
    private Chan!Submission queue;
    private int maxConns;
    private shared long opened, sent;
    private bool running;
    /// The I/O thread's multi handle while it runs (only for wakeups).
    private void* multi;

    /// Idle time after which the I/O thread exits.
    enum long idleExitMs = 5_000;

    this(int maxConnections = 16)
    {
        lock = new Lock;
        queue = Chan!Submission.make;
        maxConns = maxConnections > 0 ? maxConnections : 16;
    }

    /// This engine as other threads may hold it.
    package(camunda) ThreadSafe!HttpEngine threadSafe()
    {
        // Every mutable member is behind `lock`, atomic, or a channel.
        return ThreadSafe!HttpEngine.assumeThreadSafe(this);
    }

    /// Most ordinary requests in flight at once.
    int maxConnections() const { return maxConns; }

    /// Connections opened so far (libcurl's count of new connections).
    long connectionsOpened() const
    {
        import core.atomic : atomicLoad;
        return atomicLoad(opened);
    }

    /// Requests finished so far.
    long requestsSent() const
    {
        import core.atomic : atomicLoad;
        return atomicLoad(sent);
    }

    /// Send `req` and wait for the response. Connection failures throw
    /// `NetworkException`; HTTP error statuses are returned, not thrown.
    HttpResponse perform(const ref HttpRequest req)
    {
        auto ch = Chan!HttpResult.make;
        submit(req, ChanSink.of(ch), 0);
        HttpResult r;
        ch.take(r);
        return r.get;
    }

    /// Queue `req` and return at once; the result goes to `sink` (on the
    /// I/O thread) carrying `tag`. Throws only for a request that can never
    /// be sent (see `toWire`).
    package(camunda) void submit(const ref HttpRequest req, ThreadSafe!HttpSink sink, long tag)
    {
        import camunda.safeio : monoNowMs;
        auto s = Submission(toWire(req), sink, tag, monoNowMs);
        lock.run({
            // Start the thread before marking the engine running or queuing:
            // a failed spawn throws to this caller and leaves nothing queued
            // and no engine wrongly marked running. The new thread blocks on
            // `attach` (this lock) until the request below is queued.
            if (!running)
            {
                import camunda.curlio : ioLoop;
                spawnDaemon(&ioLoop, threadSafe);
                running = true;
                queue.put(s);
            }
            else
            {
                queue.put(s);
                if (multi !is null)
                {
                    import camunda.curlio : multiWakeup;
                    multiWakeup(multi);
                }
            }
        });
    }

    package void counted(long newConnections)
    {
        import core.atomic : atomicOp;
        atomicOp!"+="(opened, newConnections);
        atomicOp!"+="(sent, 1);
    }

    package bool next(out Submission s) { return queue.tryTake(s); }

    /// The I/O thread started with multi handle `m`.
    package void attach(void* m) { lock.run({ multi = m; }); }

    /// The idle I/O thread asks to exit: true (and the engine is
    /// stopped) unless a request arrived meanwhile.
    package bool detach()
    {
        return lock.run({
            if (queue.tryTake(pendingAfterDetach)) return false;
            running = false;
            multi = null;
            return true;
        });
    }

    /// A request `detach` found, for the I/O thread to pick up.
    package Submission pendingAfterDetach;

    /// The I/O thread is dying: the next request starts a new one.
    /// Returns the requests still queued, for the dying thread to fail:
    /// no I/O thread would ever pick them up otherwise.
    package Submission[] crashed()
    {
        return lock.run({
            running = false;
            multi = null;
            Submission[] orphans;
            Submission s;
            while (queue.tryTake(s)) orphans ~= s;
            return orphans;
        });
    }
}

/// Send `req` and return the response, on the process-wide default engine
/// (`defaultEngine`). Connection failures throw `NetworkException`; HTTP
/// error statuses are returned, not thrown.
HttpResponse perform(const ref HttpRequest req)
{
    return defaultEngine().perform(req);
}

/// The engine `perform` uses: requests sent outside a `Transport` (the
/// OAuth token fetch, tests). Each `Transport` has its own.
HttpEngine defaultEngine()
{
    import camunda.safeio : liveSingleton;
    return liveSingleton!HttpEngine;
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

// A request queued behind a busy connection limit times out from when it
// was submitted, not from when a connection frees up: its time in the
// queue counts against its timeout.
unittest
{
    import std.conv : to;
    import std.algorithm.searching : canFind;
    import camunda.safeio : monoNowMs;

    auto port = Chan!int.make;
    auto server = spawn(&slowServer, port, 600);
    int p;
    port.take(p);
    auto engine = new HttpEngine(1);
    auto results = Chan!HttpResult.make;
    HttpRequest slow;
    slow.method = "GET";
    slow.url = "http://127.0.0.1:" ~ p.to!string ~ "/v2/slow";
    slow.timeoutMs = 5_000;
    engine.submit(slow, ChanSink.of(results), 1);
    HttpRequest queued = slow;
    queued.timeoutMs = 200;
    const start = monoNowMs;
    engine.submit(queued, ChanSink.of(results), 2);
    HttpResult first;
    results.take(first);
    const waited = monoNowMs - start;
    HttpResult second;
    results.take(second);
    server.join();
    assert(first.tag == 2, "the queued request outlived its timeout: it waited for the busy slot");
    assert(first.error.canFind("queued"), first.error);
    assert(waited < 1_000, "queued timeout fired only after " ~ waited.to!string ~ " ms");
    assert(second.tag == 1 && second.error == "", second.error);
}
// An explicitly empty caller header is sent as "Name:" on the wire, not
// dropped by curl's empty-value removal; SDK suppression headers still remove.
unittest
{
    import std.algorithm.searching : canFind;
    import std.uni : toLower;
    foreach (m; ["GET", "POST", "PUT"])
    {
        foreach (withBody; [false, true])
        {
            HttpRequest req;
            req.method = m;
            if (withBody) req.body_ = "{}";
            req.suppressExpect = true;
            req.headers = ["X-Flag": "", "X-Api-Key": "k"];
            auto raw = captureRequest(req);
            assert(raw.toLower.canFind("\r\nx-flag:"), raw);
            assert(hasHeader(raw, "x-api-key: k"), raw);
            assert(!raw.toLower.canFind("expect:"), raw);
        }
    }
}

// camunda/orchestration-cluster-api-dlang#56 (backport of #54/#55): many
// requests submitted at once never open more connections than the engine's
// limit (libcurl's num_connects), and those connections are kept alive.
unittest
{
    import std.conv : to;
    enum requests = 40, limit = 3;
    auto ch = Chan!int.make;
    auto seen = Chan!string.make;
    auto server = spawn(&countingServer, requests, ch, seen);
    int port;
    ch.take(port);
    auto engine = new HttpEngine(limit);
    assert(engine.maxConnections == limit);
    auto results = Chan!HttpResult.make;
    HttpRequest req;
    req.method = "POST";
    req.body_ = `{}`;
    req.url = "http://127.0.0.1:" ~ port.to!string ~ "/v2/things";
    foreach (i; 0 .. requests) engine.submit(req, ChanSink.of(results), i);
    foreach (_; 0 .. requests)
    {
        HttpResult r;
        results.take(r);
        assert(r.get.status == 200, r.error);
    }
    string raw;
    while (seen.take(raw)) {}
    int accepted;
    ch.take(accepted);
    server.join();
    assert(engine.requestsSent == requests);
    assert(engine.connectionsOpened <= limit,
        "opened " ~ engine.connectionsOpened.to!string ~ " connections, limit " ~ limit.to!string);
    assert(accepted <= limit, "server accepted " ~ accepted.to!string ~ " connections");
}

version (unittest)
{
    /// Two-connection server: answers the first request with a 307 to
    /// `/v2/final`, the second with `200 {"ok":1}` and reports its request line.
    private void redirectServer(Chan!int port, Chan!string seen)
    {
        import std.socket : TcpSocket, InternetAddress;
        import std.string : indexOf;
        auto listener = new TcpSocket();
        scope (exit) listener.close();
        listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        listener.listen(4);
        port.put((cast(InternetAddress) listener.localAddress).port);
        foreach (i; 0 .. 2)
        {
            auto conn = listener.accept();
            scope (exit) conn.close();
            string got;
            ubyte[4096] chunk;
            while (got.indexOf("\r\n\r\n") < 0)
            {
                const n = conn.receive(chunk[]);
                if (n <= 0) break;
                got ~= cast(const(char)[]) chunk[0 .. n];
            }
            if (i == 0)
                conn.send("HTTP/1.1 307 Temporary Redirect\r\nLocation: /v2/final\r\n"
                    ~ "Content-Length: 0\r\nConnection: close\r\n\r\n");
            else
            {
                const eol = got.indexOf("\r\n");
                seen.put(eol < 0 ? got : got[0 .. eol]);
                conn.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    ~ "Content-Length: 8\r\nConnection: close\r\n\r\n{\"ok\":1}");
            }
        }
    }
}

// A 307 from a gateway or token endpoint is followed, as std.net.curl did.
unittest
{
    import std.conv : to;
    auto port = Chan!int.make;
    auto seen = Chan!string.make;
    auto server = spawn(&redirectServer, port, seen);
    int p;
    port.take(p);
    HttpRequest req;
    req.method = "GET";
    req.url = "http://127.0.0.1:" ~ p.to!string ~ "/v2/start";
    req.timeoutMs = 10_000;
    auto res = perform(req);
    assert(res.status == 200, "redirect not followed: " ~ res.status.to!string);
    assert(res.body_ == `{"ok":1}`, res.body_);
    string line;
    seen.take(line);
    server.join();
    assert(line == "GET /v2/final HTTP/1.1", line);
}
