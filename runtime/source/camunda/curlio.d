/// The I/O thread of an `HttpEngine`: one thread drives libcurl's multi
/// interface for every request of the engine, over a small pool of
/// keep-alive connections (camunda/orchestration-cluster-api-dlang#54,
/// backported to stable/10 in #56).
///
/// Every libcurl call is here. Each easy handle belongs to the I/O thread
/// alone; other threads only queue `Submission`s and call
/// `curl_multi_wakeup`, which libcurl documents as callable from any thread.
module camunda.curlio;

@safe:

import camunda.http;
import camunda.safeio : ThreadSafe, monoNowMs, ownText;
import core.stdc.config : c_long;

package(camunda):

private alias CURL = void;
private alias CURLM = void;

// The multi calls Phobos' `etc.c.curl` binding predates. They make
// libcurl 7.68 (January 2020) the minimum the SDK links against (README,
// "Requirements").
private extern (C) @system nothrow @nogc
{
    int curl_multi_poll(CURLM* multi, void* extraFds, uint extraNfds, int timeoutMs, int* numfds);
    int curl_multi_wakeup(CURLM* multi);
    void curl_easy_reset(CURL* handle);
}

// libcurl >= 7.77 blob options (CURLOPTTYPE_BLOB + n); Phobos' CurlOption
// enum predates them.
private enum : int { curlOptSslCertBlob = 40_291, curlOptSslKeyBlob = 40_292, curlOptCaInfoBlob = 40_309 }
// CURLOPT_POSTFIELDSIZE_LARGE, CURLOPT_COPYPOSTFIELDS.
private enum : int { curlOptPostFieldSizeLarge = 30_120, curlOptCopyPostFields = 10_165 }

/// `struct curl_blob`; CURL_BLOB_COPY makes libcurl keep its own copy.
private struct CurlBlob
{
    const(void)* data;
    size_t len;
    uint flags;
}

private shared bool globalInitDone;

/// Run `curl_global_init` once per process, before any other libcurl call.
/// `@trusted`: the flag is only touched inside the process-wide
/// `synchronized` section; `curl_global_init` takes a plain flag word.
void curlGlobalInitOnce() @trusted
{
    import core.atomic : atomicLoad, atomicStore;
    import etc.c.curl : curl_global_init;
    if (atomicLoad(globalInitDone)) return;
    synchronized
    {
        if (atomicLoad(globalInitDone)) return;
        curl_global_init(3 /* CURL_GLOBAL_ALL */);
        atomicStore(globalInitDone, true);
    }
}

/// Wake the I/O thread blocked in `curl_multi_poll`.
/// `@trusted`: `curl_multi_wakeup` is documented thread-safe; the engine
/// calls it under its lock, while `multi` is still attached (not freed).
void multiWakeup(void* multi) @trusted
{
    curl_multi_wakeup(multi);
}

/// One request in flight on the I/O thread.
private final class Transfer
{
    Submission sub;
    CURL* easy;
    void* headers; // curl_slist*
    ubyte[] body_;
    string contentType;
    char[256] errorBuffer; // CURL_ERROR_SIZE
}

/// libcurl's write callback: append the body chunk.
/// `@trusted`: `data` is the `Transfer` the I/O thread registered and keeps
/// alive (`active`) for the whole transfer; `ptr[0 .. size * n]` is the
/// chunk libcurl owns for the duration of the call, copied here.
private extern (C) size_t onBodyChunk(const(char)* ptr, size_t size, size_t n, void* data) @trusted nothrow
{
    auto t = cast(Transfer) data;
    t.body_ ~= cast(const(ubyte)[]) ptr[0 .. size * n];
    return size * n;
}

/// libcurl's header callback: track the Content-Type of the final response.
/// `@trusted`: as for `onBodyChunk`; the line is copied before it is kept.
private extern (C) size_t onHeaderLine(const(char)* ptr, size_t size, size_t n, void* data) @trusted nothrow
{
    import std.ascii : toLower;
    import std.string : strip;
    auto t = cast(Transfer) data;
    const line = ptr[0 .. size * n];
    enum name = "content-type:";
    if (line.length >= 5 && line[0 .. 5] == "HTTP/") t.contentType = null; // a new (final or 1xx) response
    else if (line.length >= name.length)
    {
        bool match = true;
        foreach (i, c; name)
            if (toLower(line[i]) != c) { match = false; break; }
        if (match) t.contentType = line[name.length .. $].strip.idup;
    }
    return size * n;
}

/// The I/O thread of `engineRef` (started by `HttpEngine.submit`).
void ioLoop(ThreadSafe!HttpEngine engineRef)
{
    curlGlobalInitOnce();
    auto engine = engineRef.get;
    auto multi = newMulti(engine.maxConnections);
    engine.attach(multi);
    Transfer[size_t] active; // by easy handle address
    Submission[] waiting;
    CURL*[] spare;
    int ordinary; // active transfers that count against the limit
    scope (exit)
    {
        foreach (t; active) abandon(multi, t);
        freeAll(multi, spare);
    }
    // A dying I/O thread must not leave the engine marked running. Declared
    // after the cleanup guard so it runs first: the multi handle is
    // unpublished (under the engine lock) before it is freed.
    bool unpublished;
    scope (failure) if (!unpublished) engine.crashed();
    try ioRun(engine, multi, active, waiting, spare, ordinary);
    catch (Exception e)
    {
        // Fail every affected caller rather than leave it blocked forever.
        HttpResult r;
        r.error = "HTTP I/O thread failed: " ~ e.msg;
        foreach (t; active) deliver(t.sub, r);
        foreach (w; waiting) deliver(w, r);
        unpublished = true;
        foreach (w; engine.crashed()) deliver(w, r);
    }
}

private void ioRun(HttpEngine engine, CURLM* multi, ref Transfer[size_t] active,
    ref Submission[] waiting, ref CURL*[] spare, ref int ordinary)
{
    long idleSince = monoNowMs;
    for (;;)
    {
        Submission s;
        while (engine.next(s)) waiting ~= s;
        Submission[] later;
        foreach (w; waiting)
        {
            // Checked first: a request expires while it waits for a slot.
            const left = w.remainingMs(monoNowMs);
            if (left <= 0)
            {
                engine.counted(0);
                deliver(w, queuedTimeout(w));
                continue;
            }
            if (!w.req.longPoll && ordinary >= engine.maxConnections)
            {
                later ~= w;
                continue;
            }
            auto t = new Transfer;
            t.sub = w;
            t.sub.req.timeoutMs = left;
            HttpResult failed;
            bool ok;
            try ok = start(multi, t, spare, failed);
            catch (Exception e)
            {
                failed = HttpResult.init;
                failed.error = "request setup failed: " ~ e.msg;
            }
            if (!ok)
            {
                engine.counted(0);
                deliver(t.sub, failed);
                continue;
            }
            active[easyKey(t.easy)] = t;
            if (!w.req.longPoll) ordinary++;
        }
        waiting = later;
        if (!active.length && !waiting.length)
        {
            if (monoNowMs - idleSince >= HttpEngine.idleExitMs)
            {
                if (engine.detach()) return;
                waiting ~= engine.pendingAfterDetach;
                continue;
            }
        }
        else idleSince = monoNowMs;
        foreach (done; step(multi, active.length ? 100 : 1_000))
        {
            auto t = active[done.key];
            active.remove(done.key);
            if (!t.sub.req.longPoll) ordinary--;
            long connects;
            auto r = finish(multi, t, done.code, spare, connects);
            engine.counted(connects);
            deliver(t.sub, r);
        }
    }
}

private void deliver(ref Submission s, HttpResult r)
{
    r.tag = s.tag;
    try s.sink.get.deliver(r);
    catch (Exception) {}
}

/// `@trusted`: the handle address only identifies the transfer; it is
/// never dereferenced through this value.
private size_t easyKey(CURL* easy) @trusted pure nothrow
{
    return cast(size_t) easy;
}

private struct Done
{
    size_t key;
    int code;
}

/// A new multi handle.
/// `@trusted`: `curl_multi_init` takes no arguments.
/// Its connection cache keeps `maxConnections` plus a few long-poll
/// connections alive: libcurl's default (four per handle currently added)
/// shrinks as transfers finish, closing pooled connections only for the
/// next burst to reopen them.
/// `@trusted`: `curl_multi_init` takes no arguments; CURLMOPT_MAXCONNECTS
/// takes a long.
private CURLM* newMulti(int maxConnections) @trusted
{
    import etc.c.curl : curl_multi_init, curl_multi_setopt, CurlMOption;
    auto m = curl_multi_init();
    if (m is null) assert(0, "curl_multi_init failed");
    curl_multi_setopt(m, CurlMOption.maxconnects, cast(c_long) (maxConnections + 8));
    return m;
}

/// Run what is ready, wait (up to `timeoutMs`, or until a wakeup) for more,
/// and return the transfers that finished.
/// `@trusted`: `multi` is this thread's live multi handle; the messages
/// libcurl returns are read before the next call into it.
private Done[] step(CURLM* multi, int timeoutMs) @trusted
{
    import etc.c.curl : CURLMsg, CurlMsg, curl_multi_info_read, curl_multi_perform;
    int running;
    curl_multi_perform(multi, &running);
    Done[] done;
    int left;
    for (CURLMsg* m = curl_multi_info_read(multi, &left); m !is null; m = curl_multi_info_read(multi, &left))
        if (m.msg == CurlMsg.done) done ~= Done(cast(size_t) m.easy_handle, m.data.result);
    if (done.length) return done;
    int fds;
    curl_multi_poll(multi, null, 0, timeoutMs, &fds);
    return null;
}

/// Set up `t` on a (reused) easy handle and add it to `multi`. On a
/// setting libcurl refuses, returns false with the result to deliver.
/// `@trusted`: every pointer handed to libcurl outlives the transfer: the
/// strings are copied by libcurl (CURLOPT string options and
/// CURLOPT_COPYPOSTFIELDS copy), blobs use CURL_BLOB_COPY, and `t` (the
/// callback data, the error buffer and the header list) stays in `active`
/// until `finish` removes the handle.
private bool start(CURLM* multi, Transfer t, ref CURL*[] spare, out HttpResult failed) @trusted
{
    import etc.c.curl : CurlOption, curl_easy_init, curl_easy_setopt, curl_multi_add_handle,
        curl_slist, curl_slist_append;
    import std.string : toStringz;
    import std.uni : toLower;
    const req = &t.sub.req;
    if (spare.length)
    {
        t.easy = spare[$ - 1];
        spare = spare[0 .. $ - 1];
        curl_easy_reset(t.easy);
    }
    else t.easy = curl_easy_init();
    if (t.easy is null)
    {
        failed.error = "curl_easy_init failed";
        return false;
    }
    auto e = t.easy;
    void str(CurlOption o, string v) { curl_easy_setopt(e, o, v.toStringz); }
    bool fail(string msg)
    {
        failed.error = msg;
        failed.configError = true;
        spare ~= e;
        t.easy = null;
        return false;
    }
    bool blob(int option, string pem, string setting)
    {
        if (!pem.length) return true;
        auto b = CurlBlob(pem.ptr, pem.length, 1 /* CURL_BLOB_COPY */);
        const rc = curl_easy_setopt(e, cast(CurlOption) option, &b);
        if (rc == 0) return true;
        import std.string : fromStringz;
        import etc.c.curl : curl_easy_strerror;
        return fail(setting ~ " (inline PEM) needs libcurl 7.71 (7.77 for the CA) or later with an"
            ~ " OpenSSL-compatible TLS backend; set " ~ setting ~ "_PATH to a file instead ("
            ~ fromStringz(curl_easy_strerror(rc)).idup ~ ")");
    }

    curl_easy_setopt(e, CurlOption.nosignal, cast(c_long) 1);
    str(CurlOption.url, req.url);
    curl_easy_setopt(e, CurlOption.errorbuffer, t.errorBuffer.ptr);
    curl_easy_setopt(e, CurlOption.writefunction, &onBodyChunk);
    curl_easy_setopt(e, CurlOption.file, cast(void*) t);
    curl_easy_setopt(e, CurlOption.headerfunction, &onHeaderLine);
    curl_easy_setopt(e, CurlOption.writeheader, cast(void*) t);
    curl_easy_setopt(e, CurlOption.timeout_ms, cast(c_long) req.timeoutMs);
    curl_easy_setopt(e, CurlOption.connecttimeout_ms, cast(c_long) req.timeoutMs);

    // TLS.
    if (req.caPath.length) str(CurlOption.cainfo, req.caPath);
    // A custom CA replaces system trust: also clear libcurl's default CA
    // directory, or a server signed by an unrelated system-trusted CA would
    // still be accepted via CURLOPT_CAPATH. Backends without a CA directory
    // (e.g. rustls) answer CURLE_NOT_BUILT_IN or CURLE_UNKNOWN_OPTION:
    // nothing to clear then.
    if (req.caPath.length || req.caPem.length)
    {
        const rc = curl_easy_setopt(e, CurlOption.capath, null);
        if (rc != 0 && rc != 4 && rc != 48)
            return fail("clearing CURLOPT_CAPATH failed: error " ~ rcText(rc));
    }
    // Certificate and key are set independently: an inline certificate
    // (CAMUNDA_MTLS_CERT) may pair with a key file.
    if (req.certPath.length) str(CurlOption.sslcert, req.certPath);
    if (req.keyPath.length) str(CurlOption.sslkey, req.keyPath);
    if (req.keyPassphrase.length) str(CurlOption.keypasswd, req.keyPassphrase);
    if (!blob(curlOptCaInfoBlob, req.caPem, "CAMUNDA_MTLS_CA")) return false;
    if (!blob(curlOptSslCertBlob, req.certPem, "CAMUNDA_MTLS_CERT")) return false;
    if (!blob(curlOptSslKeyBlob, req.keyPem, "CAMUNDA_MTLS_KEY")) return false;

    // Method, body and headers. A request with a body is a POST with the
    // real Content-Type, its verb overridden for PUT/PATCH/DELETE; a
    // bodiless write is an empty POST (Content-Length: 0) without libcurl's
    // default form Content-Type. Content-Type and Expect defaults are only
    // added when the caller's headers do not carry the name: an explicit
    // custom header always wins (camunda/orchestration-cluster-api-dlang#5,
    // #12).
    bool customContentType, customExpect;
    foreach (h; req.headers)
    {
        const n = h[0].toLower;
        if (n == "content-type") customContentType = true;
        if (n == "expect") customExpect = true;
    }
    string[] lines;
    // An empty caller value is sent with curl's "Name;" form: "Name:" would
    // make curl remove the header. "Name:" is used only for the SDK's own
    // suppression of curl defaults (Expect, Content-Type).
    foreach (h; req.headers) lines ~= h[1].length ? h[0] ~ ": " ~ h[1] : h[0] ~ ";";
    const hasBody = req.body_.length > 0 && req.method != "GET";
    if (hasBody)
    {
        curl_easy_setopt(e, CurlOption.post, cast(c_long) 1);
        curl_easy_setopt(e, cast(CurlOption) curlOptPostFieldSizeLarge, cast(long) req.body_.length);
        curl_easy_setopt(e, cast(CurlOption) curlOptCopyPostFields, req.body_.ptr);
        if (!customContentType)
            lines ~= "Content-Type: " ~ (req.contentType.length ? req.contentType : "application/json");
        if (req.suppressExpect && !customExpect) lines ~= "Expect:";
        if (req.method != "POST") str(CurlOption.customrequest, req.method);
    }
    else switch (req.method)
    {
    case "GET":
        curl_easy_setopt(e, CurlOption.httpget, cast(c_long) 1);
        break;
    case "DELETE":
        str(CurlOption.customrequest, "DELETE");
        break;
    default: // POST, PUT, PATCH without a body
        curl_easy_setopt(e, CurlOption.post, cast(c_long) 1);
        curl_easy_setopt(e, cast(CurlOption) curlOptPostFieldSizeLarge, cast(long) 0);
        curl_easy_setopt(e, cast(CurlOption) curlOptCopyPostFields, "".ptr);
        if (!customContentType) lines ~= "Content-Type:";
        if (req.method != "POST") str(CurlOption.customrequest, req.method);
        break;
    }
    curl_slist* list;
    foreach (l; lines) list = curl_slist_append(list, l.toStringz);
    t.headers = list;
    curl_easy_setopt(e, CurlOption.httpheader, list);
    curl_multi_add_handle(multi, e);
    return true;
}

/// libcurl's text for `rc`.
/// `@trusted`: `curl_easy_strerror` returns a static NUL-terminated string.
private string rcText(int rc) @trusted
{
    import etc.c.curl : curl_easy_strerror;
    import std.string : fromStringz;
    return fromStringz(curl_easy_strerror(rc)).idup;
}

/// Take finished `t` off `multi` and read its result; its handle goes back
/// to `spare`. `connects` is how many new connections it opened.
/// `@trusted`: `t.easy` is a live handle of this thread that `start` added
/// to `multi`; the header list is freed only after the handle is removed.
private HttpResult finish(CURLM* multi, Transfer t, int code, ref CURL*[] spare,
    out long connects) @trusted
{
    import etc.c.curl : CurlInfo, curl_easy_getinfo, curl_multi_remove_handle, curl_slist,
        curl_slist_free_all;
    import std.string : fromStringz;
    HttpResult r;
    c_long status, opened;
    curl_easy_getinfo(t.easy, CurlInfo.response_code, &status);
    curl_easy_getinfo(t.easy, CurlInfo.num_connects, &opened);
    connects = opened;
    curl_multi_remove_handle(multi, t.easy);
    curl_slist_free_all(cast(curl_slist*) t.headers);
    t.headers = null;
    recycle(spare, t.easy);
    t.easy = null;
    if (code != 0)
    {
        const detail = fromStringz(t.errorBuffer.ptr);
        r.error = rcText(code) ~ (detail.length ? ": " ~ detail.idup : "");
        return r;
    }
    r.response.status = cast(int) status;
    r.response.contentType = t.contentType;
    r.response.bytes = t.body_.idup;
    r.response.body_ = ownText(t.body_);
    t.body_ = null;
    return r;
}

/// Keep a few handles for reuse; free the rest.
private void recycle(ref CURL*[] spare, CURL* easy) @trusted
{
    // `easy` was just removed from its multi handle; it is freed at most
    // once (here or in `freeAll`).
    import etc.c.curl : curl_easy_cleanup;
    if (spare.length < 16) spare ~= easy;
    else curl_easy_cleanup(easy);
}

/// Drop a transfer still in flight when the loop ends.
/// `@trusted`: as for `finish`.
private void abandon(CURLM* multi, Transfer t) @trusted
{
    import etc.c.curl : curl_easy_cleanup, curl_multi_remove_handle, curl_slist, curl_slist_free_all;
    if (t.easy is null) return;
    curl_multi_remove_handle(multi, t.easy);
    curl_easy_cleanup(t.easy);
    curl_slist_free_all(cast(curl_slist*) t.headers);
}

/// Free the spare handles and the multi handle (closing its connections).
/// `@trusted`: every handle in `spare` is off `multi` and freed once; the
/// engine detached `multi` before this runs, so no thread wakes it.
private void freeAll(CURLM* multi, CURL*[] spare) @trusted
{
    import etc.c.curl : curl_easy_cleanup, curl_multi_cleanup;
    foreach (e; spare) curl_easy_cleanup(e);
    curl_multi_cleanup(multi);
}
