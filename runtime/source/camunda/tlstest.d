/// End-to-end TLS tests: custom CA, inline PEM and mTLS against a real TLS
/// server (`openssl s_server`), with throwaway certificates made by the
/// `openssl` CLI. Test-only; needs `openssl` on PATH (CI runners and Git for
/// Windows have it).
module camunda.tlstest;

version (unittest):

@safe:

import camunda.errors;
import camunda.http;

/// Throwaway PKI in a temp dir: a CA, a server cert for 127.0.0.1 signed by
/// it, a client cert signed by it, and an unrelated CA.
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
        write(p.path("server.ext"), "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n");
        write(p.path("client.ext"), "extendedKeyUsage=clientAuth\n");
        foreach (ca; ["ca", "other-ca"])
            p.openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", p.path(ca ~ ".key"),
                "-out", p.path(ca ~ ".pem"), "-days", "2", "-subj", "/CN=camunda test " ~ ca]);
        foreach (leaf; ["server", "client"])
        {
            p.openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", p.path(leaf ~ ".key"),
                "-out", p.path(leaf ~ ".csr"), "-subj", "/CN=" ~ (leaf == "server" ? "127.0.0.1" : "camunda test client")]);
            p.openssl(["x509", "-req", "-in", p.path(leaf ~ ".csr"), "-CA", p.path("ca.pem"),
                "-CAkey", p.path("ca.key"), "-CAcreateserial", "-out", p.path(leaf ~ ".pem"), "-days", "2",
                "-extfile", p.path(leaf ~ ".ext")]);
        }
        return p;
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

/// `openssl s_server -www` on a free local port; `mtls` requires a client
/// certificate signed by the test CA.
struct TlsServer
{
    import std.process : Pid;
    Pid pid;
    ushort port;

    static TlsServer start(const ref Pki pki, bool mtls)
    {
        import std.process : spawnProcess, Config;
        import std.socket : TcpSocket, InternetAddress;
        import std.stdio : File;
        import std.conv : to;
        import core.thread : Thread;
        import core.time : msecs;

        TlsServer s;
        {
            auto probe = new TcpSocket();
            scope (exit) probe.close();
            probe.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
            s.port = (cast(InternetAddress) probe.localAddress).port;
        }
        auto args = ["openssl", "s_server", "-accept", s.port.to!string, "-www",
            "-cert", pki.path("server.pem"), "-key", pki.path("server.key")];
        if (mtls) args ~= ["-Verify", "1", "-CAfile", pki.path("ca.pem")];
        version (Windows) enum devnull = "NUL"; else enum devnull = "/dev/null";
        auto nul = File(devnull, "w");
        s.pid = spawnProcess(args, File(devnull, "r"), nul, nul);
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

    string url() const { import std.conv : to; return "https://127.0.0.1:" ~ port.to!string ~ "/"; }

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

private HttpRequest get(const ref TlsServer s)
{
    HttpRequest r;
    r.url = s.url;
    r.timeoutMs = 10_000;
    return r;
}

// Windows: these run against WinHTTP in phase 3 of #28; until then the
// backend refuses custom CAs and client certs (see camunda.winhttp).
version (Windows) {} else
{
    // camunda/orchestration-cluster-api-dlang#30: the CA, as a file or inline,
    // decides trust; an unrelated CA and the system store both fail.
    unittest
    {
        auto pki = Pki.make();
        scope (exit) pki.remove();
        auto srv = TlsServer.start(pki, false);
        scope (exit) srv.stop();

        auto byPath = get(srv);
        byPath.caPath = pki.path("ca.pem");
        assert(perform(byPath).status == 200);

        auto inline = get(srv);
        inline.caPem = pki.read("ca.pem");
        assert(perform(inline).status == 200);

        auto wrong = get(srv);
        wrong.caPem = pki.read("other-ca.pem");
        assert(collectNetwork(wrong), "an unrelated inline CA must not be trusted");

        auto system = get(srv);
        assert(collectNetwork(system), "the system store must not trust the test CA");
    }

    // #30: client certificates, as files or inline.
    unittest
    {
        auto pki = Pki.make();
        scope (exit) pki.remove();
        auto srv = TlsServer.start(pki, true);
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

        auto none = get(srv);
        none.caPem = pki.read("ca.pem");
        assert(collectNetwork(none), "the server requires a client certificate");
    }

    private bool collectNetwork(ref HttpRequest r)
    {
        try { perform(r); return false; }
        catch (NetworkException) return true;
    }

    // #31: a `Transport` built from CAMUNDA_MTLS_CA/CERT/KEY forwards the
    // inline PEMs to the HTTP layer — the direct `HttpRequest` tests above
    // cannot see a break in that wiring. The server requires a client
    // certificate signed by the test CA, so it answers 200 only when the
    // inline CA and the inline client credentials all reached the TLS
    // handshake.
    unittest
    {
        import camunda.transport : CamundaOptions, Transport;
        import std.json : JSONValue;

        auto pki = Pki.make();
        scope (exit) pki.remove();
        auto srv = TlsServer.start(pki, true);
        scope (exit) srv.stop();

        auto t = new Transport(CamundaOptions.create
            .withKey("CAMUNDA_AUTH_STRATEGY", "NONE")
            .withKey("CAMUNDA_REST_ADDRESS", srv.url)
            .withKey("CAMUNDA_MTLS_CA", pki.read("ca.pem"))
            .withKey("CAMUNDA_MTLS_CERT", pki.read("client.pem"))
            .withKey("CAMUNDA_MTLS_KEY", pki.read("client.key")));
        t.requestVoid("GET", "/topology", JSONValue.init, null);
    }
}
