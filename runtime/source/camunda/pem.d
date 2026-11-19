/// Minimal PEM reader: the labelled base64 blocks of a PEM file, decoded.
/// Used by the WinHTTP backend (Windows has no "load this PEM file" API for
/// TLS); plain D, so it is tested on every platform.
module camunda.pem;

@safe:

/// One `-----BEGIN <label>-----` ... `-----END <label>-----` block.
struct PemBlock
{
    string label;
    immutable(ubyte)[] der;
    /// RFC 1421 `Proc-Type: 4,ENCRYPTED` (OpenSSL's legacy encrypted keys):
    /// `der` is ciphertext.
    bool legacyEncrypted;
}

/// All PEM blocks in `text`, in order. Text outside blocks (comments,
/// `Bag Attributes` lines from openssl) is ignored. Throws on a block with
/// no END line, a mismatched END label, or invalid base64.
PemBlock[] parsePem(string text)
{
    import std.base64 : Base64;
    import std.string : indexOf, lineSplitter, strip, startsWith, endsWith;
    import std.exception : enforce;

    PemBlock[] blocks;
    string label;
    string b64;
    bool inBlock;
    bool encrypted;
    foreach (raw; text.lineSplitter)
    {
        const line = raw.strip;
        if (!inBlock)
        {
            if (line.startsWith("-----BEGIN ") && line.endsWith("-----"))
            {
                label = line["-----BEGIN ".length .. $ - "-----".length];
                b64 = null;
                inBlock = true;
                encrypted = false;
            }
            continue;
        }
        if (line.startsWith("-----END "))
        {
            enforce(line == "-----END " ~ label ~ "-----", "PEM block " ~ label ~ " ends with " ~ line);
            immutable(ubyte)[] der;
            try der = Base64.decode(b64).idup;
            catch (Exception e) throw new Exception("PEM block " ~ label ~ " is not valid base64: " ~ e.msg);
            blocks ~= PemBlock(label, der, encrypted);
            inBlock = false;
            continue;
        }
        // RFC 1421 headers inside a block (legacy encrypted keys) are kept
        // out of the base64.
        if (line.indexOf(':') >= 0)
        {
            if (line.startsWith("Proc-Type:") && line.indexOf("ENCRYPTED") >= 0) encrypted = true;
            continue;
        }
        b64 ~= line;
    }
    enforce(!inBlock, "PEM block " ~ label ~ " has no END line");
    return blocks;
}

/// The DER of every block labelled `label`.
immutable(ubyte)[][] pemBlocks(string text, string label)
{
    immutable(ubyte)[][] r;
    foreach (b; parsePem(text))
        if (b.label == label) r ~= b.der;
    return r;
}

unittest
{
    import std.exception : collectException;

    const two = "Bag Attributes\n  friendlyName: x\n-----BEGIN CERTIFICATE-----\r\nAQID\r\nBA==\r\n-----END CERTIFICATE-----\r\n"
        ~ "junk\n-----BEGIN PRIVATE KEY-----\nBQY=\n-----END PRIVATE KEY-----\n"
        ~ "-----BEGIN CERTIFICATE-----\n  Bwg=  \n-----END CERTIFICATE-----";
    auto b = parsePem(two);
    assert(b.length == 3);
    assert(b[0].label == "CERTIFICATE" && b[0].der == [1, 2, 3, 4]);
    assert(b[1].label == "PRIVATE KEY" && b[1].der == [5, 6]);
    assert(pemBlocks(two, "CERTIFICATE") == [[1, 2, 3, 4], [7, 8]]);
    assert(pemBlocks("no pem here", "CERTIFICATE").length == 0);

    // Legacy encrypted-key headers are skipped.
    auto legacy = parsePem("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAQ==\n-----END RSA PRIVATE KEY-----\n");
    assert(legacy.length == 1 && legacy[0].der == [1] && legacy[0].legacyEncrypted);
    assert(!b[1].legacyEncrypted);

    assert(collectException(parsePem("-----BEGIN CERTIFICATE-----\nAQID\n")) !is null);
    assert(collectException(parsePem("-----BEGIN CERTIFICATE-----\nAQID\n-----END PRIVATE KEY-----\n")) !is null);
    assert(collectException(parsePem("-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n")) !is null);
}

/// `key` (a "PRIVATE KEY", "RSA PRIVATE KEY" (PKCS#1) or "EC PRIVATE KEY"
/// (SEC1, with its named curve) block) as unencrypted PKCS#8 DER, the one
/// form Windows CNG imports. Throws on anything else.
immutable(ubyte)[] toPkcs8(const ref PemBlock key)
{
    import std.exception : enforce;

    enforce(!key.legacyEncrypted, "legacy encrypted PEM keys (Proc-Type: 4,ENCRYPTED) are not supported;"
        ~ " convert: openssl pkcs8 -topk8 -v2 aes-256-cbc -in key.pem -out key-pkcs8.pem");
    static immutable ubyte[] version0 = [0x02, 0x01, 0x00];
    switch (key.label)
    {
    case "PRIVATE KEY":
        return key.der;
    case "RSA PRIVATE KEY":
        // AlgorithmIdentifier { rsaEncryption, NULL }
        static immutable ubyte[] rsa = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00];
        return der(0x30, version0 ~ der(0x30, rsa) ~ der(0x04, key.der));
    case "EC PRIVATE KEY":
        // ECPrivateKey ::= SEQUENCE { version, privateKey, [0] curve OID, [1] publicKey }
        static immutable ubyte[] ecPublicKey = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01];
        auto outer = readTlv(key.der);
        enforce(outer.tag == 0x30, "EC PRIVATE KEY is not a DER SEQUENCE");
        const(ubyte)[] rest = outer.value;
        const(ubyte)[] curve;
        while (rest.length)
        {
            auto t = readTlv(rest);
            if (t.tag == 0xA0) curve = t.value;
            rest = rest[t.size .. $];
        }
        enforce(curve.length && curve[0] == 0x06, "EC PRIVATE KEY has no named curve; regenerate it with -param_enc named_curve");
        return der(0x30, version0 ~ der(0x30, ecPublicKey ~ curve) ~ der(0x04, key.der));
    default:
        throw new Exception("unsupported private key type " ~ key.label);
    }
}

private struct Tlv
{
    ubyte tag;
    const(ubyte)[] value;
    size_t size; // header + value
}

/// One DER tag-length-value from the front of `data` (definite lengths only).
private Tlv readTlv(const(ubyte)[] data)
{
    import std.exception : enforce;

    enforce(data.length >= 2, "truncated DER");
    size_t len = data[1];
    size_t head = 2;
    if (len & 0x80)
    {
        const n = len & 0x7F;
        enforce(n >= 1 && n <= 4 && data.length >= 2 + n, "bad DER length");
        len = 0;
        foreach (b; data[2 .. 2 + n]) len = (len << 8) | b;
        head += n;
    }
    enforce(data.length - head >= len, "truncated DER");
    return Tlv(data[0], data[head .. head + len], head + len);
}

private immutable(ubyte)[] der(ubyte tag, const(ubyte)[] value)
{
    immutable(ubyte)[] len;
    if (value.length < 0x80) len = [cast(ubyte) value.length];
    else
    {
        ubyte[] be;
        for (size_t n = value.length; n; n >>= 8) be = cast(ubyte)(n & 0xFF) ~ be;
        len = (cast(ubyte)(0x80 | be.length) ~ be).idup;
    }
    return (tag ~ len ~ value).idup;
}

unittest
{
    import std.exception : collectException;

    // PKCS#1 → PKCS#8: version 0, rsaEncryption + NULL, key in an OCTET STRING.
    auto rsa = PemBlock("RSA PRIVATE KEY", [0x30, 0x00]);
    assert(toPkcs8(rsa) == [0x30, 0x16, 0x02, 0x01, 0x00,
        0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
        0x04, 0x02, 0x30, 0x00]);

    // SEC1 → PKCS#8: the curve OID moves into the AlgorithmIdentifier.
    immutable ubyte[] sec1 = [0x30, 0x0B, 0x02, 0x01, 0x01, 0x04, 0x01, 0xAA, 0xA0, 0x03, 0x06, 0x01, 0x2B];
    auto ec = PemBlock("EC PRIVATE KEY", sec1);
    immutable ubyte[] ecHead = [0x30, 0x20, 0x02, 0x01, 0x00,
        0x30, 0x0C, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x01, 0x2B,
        0x04, 0x0D];
    assert(toPkcs8(ec) == ecHead ~ sec1);

    // Long lengths use the multi-byte form.
    auto big = new immutable(ubyte)[300];
    assert(der(0x04, big)[0 .. 4] == [0x04, 0x82, 0x01, 0x2C]);

    auto pkcs8 = PemBlock("PRIVATE KEY", [1, 2]);
    assert(toPkcs8(pkcs8) == [1, 2]);
    auto noCurve = PemBlock("EC PRIVATE KEY", [0x30, 0x06, 0x02, 0x01, 0x01, 0x04, 0x01, 0xAA]);
    assert(collectException(toPkcs8(noCurve)) !is null);
    auto legacy = PemBlock("RSA PRIVATE KEY", [0x30, 0x00], true);
    assert(collectException(toPkcs8(legacy)) !is null);
    assert(collectException(readTlv([0x30, 0x05, 0x00])) !is null);
}
