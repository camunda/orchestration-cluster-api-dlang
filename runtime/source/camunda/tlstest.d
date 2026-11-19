/// End-to-end TLS tests: custom CA, inline PEM, mTLS and revocation against
/// a real TLS server (`openssl s_server`), with throwaway certificates made
/// by the `openssl` CLI. Test-only; needs `openssl` on PATH (CI runners and
/// Git for Windows have it). The same tests run against curl (POSIX) and
/// WinHTTP (Windows).
module camunda.tlstest;

version (unittest):

@safe:

import camunda.errors;
import camunda.http;
import camunda.safeio : Chan, spawn;

/// Throwaway PKI in a temp dir: a CA; leaves signed by it (`server` for
/// 127.0.0.1, `client`, and `offline`, a server cert whose CRL URL nothing
/// answers); and an unrelated CA.
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
        p.serverWithCrl("offline", "http://127.0.0.1:9/offline.crl");
        // The client key again, as encrypted PKCS#8 (passphrase "s3cret").
        p.openssl(["pkcs8", "-topk8", "-in", p.path("client.key"), "-out", p.path("client-enc.key"),
            "-v2", "aes-256-cbc", "-passout", "pass:s3cret"]);
        // The client key as PKCS#1 (OpenSSL 3 needs -traditional; LibreSSL
        // writes PKCS#1 by default and has no such flag).
        if (!p.tryOpenssl(["rsa", "-in", p.path("client.key"), "-out", p.path("client-pkcs1.key"), "-traditional"]))
            p.openssl(["rsa", "-in", p.path("client.key"), "-out", p.path("client-pkcs1.key")]);
        // An EC (P-256) client with a SEC1 key.
        p.openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", p.path("client-ec.key")]);
        p.openssl(["req", "-new", "-key", p.path("client-ec.key"), "-out", p.path("client-ec.csr"),
            "-subj", "/CN=camunda test ec client"]);
        p.openssl(["x509", "-req", "-in", p.path("client-ec.csr"), "-CA", p.path("ca.pem"), "-CAkey", p.path("ca.key"),
            "-CAcreateserial", "-out", p.path("client-ec.pem"), "-days", "2", "-extfile", p.path("client.ext")]);
        // And both as a PKCS#12 keystore (password "s3cret").
        p.openssl(["pkcs12", "-export", "-in", p.path("client.pem"), "-inkey", p.path("client.key"),
            "-out", p.path("client.p12"), "-passout", "pass:s3cret", "-name", "camunda test client"]);
        return p;
    }

    /// A server cert for 127.0.0.1 whose CRL distribution point is `crlUrl`.
    void serverWithCrl(string name, string crlUrl) const
    {
        leaf(name, "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\ncrlDistributionPoints=URI:" ~ crlUrl ~ "\n");
    }

    /// Revoke leaf `name` and write the CA's CRL (DER) to `ca.crl`.
    void revoke(string name) const
    {
        import std.file : write;
        import std.array : replace;

        // openssl config values treat `\` as an escape: use `/`.
        const d = dir.replace("\\", "/");
        write(path("index.txt"), "");
        write(path("crlnumber"), "01\n");
        write(path("ca.cnf"), "[ca]\ndefault_ca = test_ca\n[test_ca]\ndatabase = " ~ d ~ "/index.txt\n"
            ~ "crlnumber = " ~ d ~ "/crlnumber\ndefault_md = sha256\ndefault_crl_days = 2\n");
        const ca = ["-config", path("ca.cnf"), "-keyfile", path("ca.key"), "-cert", path("ca.pem")];
        openssl(["ca"] ~ ca ~ ["-revoke", path(name ~ ".pem")]);
        openssl(["ca"] ~ ca ~ ["-gencrl", "-out", path("ca.crl.pem")]);
        openssl(["crl", "-in", path("ca.crl.pem"), "-outform", "DER", "-out", path("ca.crl")]);
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
        version (Windows) enum devnull = "NUL"; else enum devnull = "/dev/null";
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

/// Plain-HTTP CRL server for the revocation test: sends its port on `port`,
/// takes the CRL file path from `crlFile`, then answers every request with
/// that file until one asks for `/stop`.
private void crlServer(Chan!int port, Chan!string crlFile)
{
    import std.socket : TcpSocket, InternetAddress;
    import std.file : read;
    import std.conv : to;
    import std.algorithm.searching : canFind;

    auto listener = new TcpSocket();
    scope (exit) listener.close();
    listener.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
    listener.listen(8);
    port.put((cast(InternetAddress) listener.localAddress).port);
    string file;
    crlFile.take(file);
    for (;;)
    {
        auto conn = listener.accept();
        scope (exit) conn.close();
        char[4096] buf;
        string head;
        while (!head.canFind("\r\n\r\n"))
        {
            const n = conn.receive(buf[]);
            if (n <= 0) break;
            head ~= buf[0 .. n].idup;
        }
        if (head.canFind("GET /stop ")) return;
        const crl = cast(const(ubyte)[]) read(file);
        conn.send("HTTP/1.1 200 OK\r\nContent-Type: application/pkix-crl\r\nContent-Length: "
            ~ crl.length.to!string ~ "\r\nConnection: close\r\n\r\n");
        conn.send(crl);
    }
}

// camunda/orchestration-cluster-api-dlang#30 and #28: the CA, as a file or
// inline, decides trust (it replaces the system store); an unrelated CA, the
// system store and a certificate for another host all fail.
unittest
{
    import std.algorithm.searching : canFind;

    auto pki = Pki.make();
    scope (exit) pki.remove();
    auto srv = TlsServer.start(pki, Mode.www);
    scope (exit) srv.stop();

    auto byPath = get(srv);
    byPath.caPath = pki.path("ca.pem");
    assert(perform(byPath).status == 200);

    auto inline = get(srv);
    inline.caPem = pki.read("ca.pem");
    assert(perform(inline).status == 200);

    auto wrong = get(srv);
    wrong.caPem = pki.read("other-ca.pem");
    const w = failure(wrong);
    assert(w !is null, "an unrelated inline CA must not be trusted");
    version (Windows) assert(w.canFind("not signed by the CA in CAMUNDA_MTLS_CA"), w);

    auto system = get(srv);
    assert(failure(system) !is null, "the system store must not trust the test CA");

    // The certificate is for 127.0.0.1 only.
    auto otherHost = get(srv);
    otherHost.url = srv.url("localhost");
    otherHost.caPath = pki.path("ca.pem");
    const h = failure(otherHost);
    assert(h !is null, "a certificate for another host must be refused");
    version (Windows) assert(h.canFind("not issued for localhost"), h);
}

// #28 security: a server the client does not trust receives no request
// (WinHTTP checks in the send callback, before writing; curl checks in the
// handshake). The server logs each file requested; a trusted control
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
    untrusted.caPem = pki.read("other-ca.pem");
    untrusted.headers["Authorization"] = "Bearer must-not-leak";
    assert(failure(untrusted) !is null);

    auto control = get(srv, "/control-arrives");
    control.caPem = pki.read("ca.pem");
    assert(perform(control).status == 200);

    Thread.sleep(300.msecs);
    const log = pki.read("access.log");
    assert(log.canFind("FILE:control-arrives"), "the server logged no request; log: " ~ log);
    assert(!log.canFind("must-not-arrive"), "an untrusted server received the request: " ~ log);
}

// #28 revocation soft-fail: a CRL that cannot be fetched does not fail the
// request (curl does not check CRLs at all; WinHTTP checks and tolerates
// "offline").
unittest
{
    auto pki = Pki.make();
    scope (exit) pki.remove();
    auto srv = TlsServer.start(pki, Mode.www, "offline");
    scope (exit) srv.stop();

    auto r = get(srv);
    r.caPath = pki.path("ca.pem");
    assert(perform(r).status == 200);
}

// #28 revocation on Windows: a server certificate on its CA's CRL is
// refused. (curl does not fetch CRLs, so this is WinHTTP only.)
version (Windows) unittest
{
    import std.algorithm.searching : canFind;
    import std.conv : to;
    import std.socket : TcpSocket, InternetAddress;

    auto port = Chan!int.make;
    auto crlFile = Chan!string.make;
    auto crl = spawn(&crlServer, port, crlFile);
    int p;
    port.take(p);
    scope (exit)
    {
        auto c = new TcpSocket(new InternetAddress("127.0.0.1", cast(ushort) p));
        c.send("GET /stop HTTP/1.1\r\n\r\n");
        c.close();
        crl.join();
    }

    auto pki = Pki.make();
    scope (exit) pki.remove();
    pki.serverWithCrl("revoked", "http://127.0.0.1:" ~ p.to!string ~ "/ca.crl");
    pki.revoke("revoked");
    crlFile.put(pki.path("ca.crl"));

    auto srv = TlsServer.start(pki, Mode.www, "revoked");
    scope (exit) srv.stop();
    auto r = get(srv);
    r.caPath = pki.path("ca.pem");
    const msg = failure(r);
    assert(msg !is null && msg.canFind("revoked"), msg is null ? "a revoked certificate was accepted" : msg);
}

// #30 / #28: client certificates, as files or inline, plain or encrypted
// PKCS#8, or a PKCS#12 keystore.
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

    auto inline = get(srv);
    inline.caPem = pki.read("ca.pem");
    inline.certPem = pki.read("client.pem");
    inline.keyPem = pki.read("client.key");
    assert(perform(inline).status == 200);

    auto encrypted = get(srv);
    encrypted.caPem = pki.read("ca.pem");
    encrypted.certPem = pki.read("client.pem");
    encrypted.keyPem = pki.read("client-enc.key");
    encrypted.keyPassphrase = "s3cret";
    assert(perform(encrypted).status == 200);

    auto wrongPass = encrypted;
    wrongPass.keyPassphrase = "wrong";
    assert(collectException(perform(wrongPass)) !is null, "a wrong passphrase must fail");

    // PKCS#1 (RSA) and SEC1 (EC) keys; Windows wraps them as PKCS#8.
    auto pkcs1 = get(srv);
    pkcs1.caPem = pki.read("ca.pem");
    pkcs1.certPem = pki.read("client.pem");
    pkcs1.keyPem = pki.read("client-pkcs1.key");
    assert(perform(pkcs1).status == 200);

    auto ec = get(srv);
    ec.caPem = pki.read("ca.pem");
    ec.certPath = pki.path("client-ec.pem");
    ec.keyPath = pki.path("client-ec.key");
    assert(perform(ec).status == 200);

    auto keystore = get(srv);
    keystore.caPath = pki.path("ca.pem");
    keystore.keystorePath = pki.path("client.p12");
    keystore.keystorePassword = "s3cret";
    assert(perform(keystore).status == 200);

    auto wrongKeystorePass = keystore;
    wrongKeystorePass.keystorePassword = "wrong";
    assert(collectException(perform(wrongKeystorePass)) !is null, "a wrong keystore password must fail");

    auto none = get(srv);
    none.caPem = pki.read("ca.pem");
    assert(failure(none) !is null, "the server requires a client certificate");
}

// camunda.pem.toPkcs8 wraps a PKCS#1 key exactly as OpenSSL does.
unittest
{
    import camunda.pem : parsePem, toPkcs8;

    auto pki = Pki.make();
    scope (exit) pki.remove();
    assert(parsePem(pki.read("client-pkcs1.key"))[0].label == "RSA PRIVATE KEY");
    pki.openssl(["pkcs8", "-topk8", "-nocrypt", "-in", pki.path("client-pkcs1.key"), "-out", pki.path("client-p8.key")]);
    auto pkcs1 = parsePem(pki.read("client-pkcs1.key"))[0];
    assert(toPkcs8(pkcs1) == parsePem(pki.read("client-p8.key"))[0].der);
}
