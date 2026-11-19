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
            }
            continue;
        }
        if (line.startsWith("-----END "))
        {
            enforce(line == "-----END " ~ label ~ "-----", "PEM block " ~ label ~ " ends with " ~ line);
            immutable(ubyte)[] der;
            try der = Base64.decode(b64).idup;
            catch (Exception e) throw new Exception("PEM block " ~ label ~ " is not valid base64: " ~ e.msg);
            blocks ~= PemBlock(label, der);
            inBlock = false;
            continue;
        }
        // RFC 1421 headers inside a block (legacy encrypted keys) are kept
        // out of the base64.
        if (line.indexOf(':') >= 0) continue;
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
    assert(legacy.length == 1 && legacy[0].der == [1]);

    assert(collectException(parsePem("-----BEGIN CERTIFICATE-----\nAQID\n")) !is null);
    assert(collectException(parsePem("-----BEGIN CERTIFICATE-----\nAQID\n-----END PRIVATE KEY-----\n")) !is null);
    assert(collectException(parsePem("-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n")) !is null);
}
