/// End-to-end TLS tests for the curl-multi engine: custom CA (file or
/// inline), mTLS client certificates (files, inline PEM, encrypted keys)
/// against a real TLS server (`openssl s_server`), with throwaway
/// certificates made by the `openssl` CLI. Test-only; needs `openssl` on
/// PATH (CI runners have it). Backported from main (#28, #30, #55) to
/// stable/10 in #56, without the PKCS#12 keystore, revocation and WinHTTP
/// cases stable/10 does not have.
module camunda.tlstest;

version (unittest):

@safe:

import camunda.errors;
import camunda.http;

/// Throwaway PKI in a temp dir: a CA; leaves signed by it (`server` for
/// 127.0.0.1 and `client`); and an unrelated CA.
struct Pki
{
    string dir;

    string path(string name) const { import std.path : buildPath; return buildPath(dir, name); }
    string read(string name) const { import std.file : readText; return readText(path(name)); }

    static Pki make()
    {
        import std.file : tempDir, mkdirRecurse, write;
        import std.path : buildPath;
        import std.conv : to;
        import std.process : thisProcessID;
        import std.uuid : randomUUID;

        Pki p;
        p.dir = buildPath(tempDir, "camunda-tlstest-" ~ thisProcessID.to!string ~ "-" ~ randomUUID.toString[0 .. 8]);
        mkdirRecurse(p.dir);
        foreach (ca; ["ca", "other-ca"])
            p.openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", p.path(ca ~ ".key"),
                "-out", p.path(ca ~ ".pem"), "-days", "2", "-subj", "/CN=camunda test " ~ ca]);
        p.leaf("server", "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n");
        p.leaf("client", "extendedKeyUsage=clientAuth\n");
        // The client key again, as encrypted PKCS#8 (passphrase "s3cret").
        p.openssl(["pkcs8", "-topk8", "-in", p.path("client.key"), "-out", p.path("client-enc.key"),
            "-v2", "aes-256-cbc", "-passout", "pass:s3cret"]);
        return p;
    }

    private void leaf(string name, string ext) const
    {
        import std.file : write;
        write(path(name ~ ".ext"), ext);
        openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", path(name ~ ".key"),
            "-out", path(name ~ ".csr"), "-subj", "/CN=camunda test " ~ name]);
        openssl(["x509", "-req", "-in", path(name ~ ".csr"), "-CA", path("ca.pem"),
            "-CAkey", path("ca.key"), "-CAcreateserial", "-out", path(name ~ ".pem"), "-days", "2",
            "-extfile", path(name ~ ".ext")]);
    }

    bool tryOpenssl(string[] args) const
    {
        import std.process : execute;
        return execute(["openssl"] ~ args).status == 0;
    }

    void openssl(string[] args) const
    {
        import std.process : execute;
        const r = execute(["openssl"] ~ args);
        assert(r.status == 0, "openssl " ~ args[0] ~ " failed: " ~ r.output);
    }

    void remove() const
    {
        import std.file : rmdirRecurse, exists;
        if (exists(dir)) rmdirRecurse(dir);
    }
}

/// How the test server behaves.
enum Mode
{
    www,  /// answers every request with 200 (`-www`)
    mtls, /// ditto, and requires a client cert signed by the test CA
    files, /// serves files from the PKI dir (`-WWW`), logging `FILE:<name>` to `access.log`
}

/// `openssl s_server` on a free local port, presenting leaf `cert`.
struct TlsServer
{
    import std.process : Pid;
    Pid pid;
    ushort port;

    static TlsServer start(const ref Pki pki, Mode mode, string cert = "server")
    {
        import std.process : spawnProcess, Config;
        import std.socket : TcpSocket, InternetAddress;
        import std.stdio : File;
        import std.conv : to;
        import core.thread : Thread;
        import core.time : msecs;

        TlsServer s;
        s.port = freePort();
        auto args = ["openssl", "s_server", "-accept", s.port.to!string,
            "-cert", pki.path(cert ~ ".pem"), "-key", pki.path(cert ~ ".key")];
        final switch (mode)
        {
        case Mode.www: args ~= "-www"; break;
        case Mode.mtls: args ~= ["-www", "-Verify", "1", "-CAfile", pki.path("ca.pem")]; break;
        // OpenSSL and LibreSSL both print FILE:<name> to stderr for each
        // file they serve.
        case Mode.files: args ~= "-WWW"; break;
        }
        // macOS system libcurl uses LibreSSL 3.3.6, which fails to decode a
        // TLS 1.3 CertificateRequest from current OpenSSL (`tlsv1 alert
        // decode error`). Test-server interop quirk only: pin TLS 1.2 there.
        version (OSX) if (mode == Mode.mtls) args ~= "-no_tls1_3";
        enum devnull = "/dev/null";
        auto nul = File(devnull, "w");
        auto stderr = mode == Mode.files ? File(pki.path("access.log"), "w") : nul;
        s.pid = spawnProcess(args, File(devnull, "r"), nul, stderr, null, Config.none, pki.dir);
        foreach (_; 0 .. 100) // up to 10 s for the server to listen
        {
            auto c = new TcpSocket();
            scope (exit) c.close();
            try { c.connect(new InternetAddress("127.0.0.1", s.port)); return s; }
            catch (Exception) Thread.sleep(100.msecs);
        }
        s.stop();
        assert(false, "openssl s_server did not start");
    }

    string url(string host = "127.0.0.1", string path = "/") const
    {
        import std.conv : to;
        return "https://" ~ host ~ ":" ~ port.to!string ~ path;
    }

    void stop()
    {
        import std.process : kill, wait;
        // `@trusted`: kills the child this struct spawned (std.process.kill is
        // @system only because a reused pid could name another process; we
        // wait on ours below, so it cannot have been reaped and reused yet).
        () @trusted { kill(pid); }();
        wait(pid);
    }
}

private ushort freePort()
{
    import std.socket : TcpSocket, InternetAddress;
    auto probe = new TcpSocket();
    scope (exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    return (cast(InternetAddress) probe.localAddress).port;
}

private HttpRequest get(const ref TlsServer s, string path = "/")
{
    HttpRequest r;
    r.url = s.url("127.0.0.1", path);
    r.timeoutMs = 10_000;
    return r;
}

/// The message of the NetworkException `r` fails with, or null if it succeeds.
private string failure(HttpRequest r)
{
    try { perform(r); return null; }
    catch (NetworkException e) return e.msg.length ? e.msg : "(no message)";
}

/// Whether this libcurl's TLS backend takes the inline PEM `r` carries;
/// when not, `perform` must refuse it before sending (fail closed).
private bool inlineSupported(const ref HttpRequest r)
{
    import camunda.curlio : curlGlobalInitOnce;
    curlGlobalInitOnce();
    return curlTlsBackendMissingBlobs(r).length == 0;
}

/// `perform(r)`'s status, or -1 when this backend cannot take the inline
/// PEM in `r` and the request was refused with a `CamundaException` before
/// any network I/O (never silently sent without it).
private int performInline(HttpRequest r)
{
    if (inlineSupported(r)) return perform(r).status;
    import std.exception : collectException;
    auto e = collectException!CamundaException(perform(r));
    assert(e !is null && (cast(NetworkException) e) is null, "unsupported inline PEM was not refused");
    return -1;
}

// The CA, as a file or inline, decides trust: a custom CA replaces the
// system store (CURLOPT_CAINFO with CURLOPT_CAPATH cleared), so an unrelated
// CA, the system store and a certificate for another host all fail.
unittest
{
    auto pki = Pki.make();
    scope (exit) pki.remove();
    auto srv = TlsServer.start(pki, Mode.www);
    scope (exit) srv.stop();

    auto byPath = get(srv);
    byPath.caPath = pki.path("ca.pem");
    assert(perform(byPath).status == 200);

    auto wrongPath = get(srv);
    wrongPath.caPath = pki.path("other-ca.pem");
    assert(failure(wrongPath) !is null, "an unrelated CA file must not be trusted");

    auto inline = get(srv);
    inline.caPem = pki.read("ca.pem");
    assert(performInline(inline) != 0);

    auto wrong = get(srv);
    wrong.caPem = pki.read("other-ca.pem");
    if (inlineSupported(wrong))
        assert(failure(wrong) !is null, "an unrelated inline CA must not be trusted");

    auto system = get(srv);
    assert(failure(system) !is null, "the system store must not trust the test CA");

    // The certificate is for 127.0.0.1 only.
    auto otherHost = get(srv);
    otherHost.url = srv.url("localhost");
    otherHost.caPath = pki.path("ca.pem");
    assert(failure(otherHost) !is null, "a certificate for another host must be refused");
}

// A server the client does not trust receives no request: curl checks in
// the handshake. The server logs each file requested; a trusted control
// request proves the log works.
unittest
{
    import std.algorithm.searching : canFind;
    import core.thread : Thread;
    import core.time : msecs;

    auto pki = Pki.make();
    scope (exit) pki.remove();
    import std.file : write;
    write(pki.path("control-arrives"), "ok");
    write(pki.path("must-not-arrive"), "secret");
    auto srv = TlsServer.start(pki, Mode.files);
    scope (exit) srv.stop();

    auto untrusted = get(srv, "/must-not-arrive");
    untrusted.caPath = pki.path("other-ca.pem");
    untrusted.headers["Authorization"] = "Bearer must-not-leak";
    assert(failure(untrusted) !is null);

    auto control = get(srv, "/control-arrives");
    control.caPath = pki.path("ca.pem");
    assert(perform(control).status == 200);

    Thread.sleep(300.msecs);
    const log = pki.read("access.log");
    assert(log.canFind("FILE:control-arrives"), "the server logged no request; log: " ~ log);
    assert(!log.canFind("must-not-arrive"), "an untrusted server received the request: " ~ log);
}

// Client certificates (CURLOPT_SSLCERT/SSLKEY, KEYPASSWD), as files or
// inline PEM, plain or encrypted PKCS#8; reused easy handles must not leak
// one request's credentials into the next.
unittest
{
    import std.exception : collectException;

    auto pki = Pki.make();
    scope (exit) pki.remove();
    auto srv = TlsServer.start(pki, Mode.mtls);
    scope (exit) srv.stop();

    auto byPath = get(srv);
    byPath.caPath = pki.path("ca.pem");
    byPath.certPath = pki.path("client.pem");
    byPath.keyPath = pki.path("client.key");
    assert(perform(byPath).status == 200);

    auto encPath = byPath;
    encPath.keyPath = pki.path("client-enc.key");
    encPath.keyPassphrase = "s3cret";
    assert(perform(encPath).status == 200);

    auto wrongPassPath = encPath;
    wrongPassPath.keyPassphrase = "wrong";
    assert(collectException(perform(wrongPassPath)) !is null, "a wrong passphrase must fail");

    auto inline = get(srv);
    inline.caPath = pki.path("ca.pem");
    inline.certPem = pki.read("client.pem");
    inline.keyPem = pki.read("client.key");
    const inlineStatus = performInline(inline);
    assert(inlineStatus == 200 || inlineStatus == -1);

    if (inlineStatus == 200)
    {
        auto encrypted = inline;
        encrypted.keyPem = pki.read("client-enc.key");
        encrypted.keyPassphrase = "s3cret";
        assert(perform(encrypted).status == 200);

        auto wrongPass = encrypted;
        wrongPass.keyPassphrase = "wrong";
        assert(collectException(perform(wrongPass)) !is null, "a wrong passphrase must fail");
    }

    // No client certificate: the server refuses. Runs after the requests
    // above on the same engine, so a recycled handle keeping their
    // certificate would make it pass.
    auto none = get(srv);
    none.caPath = pki.path("ca.pem");
    assert(failure(none) !is null, "the server requires a client certificate");
}
