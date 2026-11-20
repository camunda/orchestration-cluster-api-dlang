/// Pure helpers for persisting client keys on Windows (winhttp.d). They
/// hold no Windows calls, so they build and are tested on every OS; the
/// Windows-only code keeps to the API calls around them.
module camunda.tlskeys;

@safe:

/// The CNG key name for a client key: SDK-owned (the `camunda-sdk-` prefix
/// never names a key the user has), scoped to process `pid` (another
/// process using the same key deletes its own copy at exit), and derived
/// from the key material plus its secret. The secret is part of the name so
/// that a wrong passphrase can't reuse a key the right one already imported:
/// it gets its own name, and its import fails. `kind` separates PEM keys
/// from keystore keys ("" or "p12").
string cngKeyName(int pid, const(ubyte)[] material, const(char)[] secret, string kind = "")
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : SHA256;
    import std.format : format;

    SHA256 h;
    h.start();
    h.put(material);
    h.put(cast(const(ubyte)[]) "\0");
    h.put(cast(const(ubyte)[]) secret);
    const digest = h.finish();
    const hex = toHexString!(LetterCase.lower)(digest)[0 .. 16].idup;
    return kind.length ? format("camunda-sdk-%s-%s-%s", pid, kind, hex) : format("camunda-sdk-%s-%s", pid, hex);
}

/// NCRYPTBUFFER_PKCS_ALG_PARAM for PBE-SHA1-3DES (1.2.840.113549.1.12.1.3):
/// the native CRYPT_PKCS12_PBE_PARAMS (int iIterations, ULONG cbSalt,
/// little-endian) followed by the salt. It is not DER: passing a DER
/// PBEParameter here makes NCryptExportKey fail with 0x80090027.
ubyte[] pkcs12PbeParams(uint iterations, const(ubyte)[] salt)
{
    import std.bitmanip : nativeToLittleEndian;

    return nativeToLittleEndian(iterations)[].dup ~ nativeToLittleEndian(cast(uint) salt.length)[] ~ salt;
}

unittest
{
    const key = cast(const(ubyte)[]) "key bytes";
    const a = cngKeyName(42, key, "secret");
    assert(a.length == "camunda-sdk-42-".length + 16 && a[0 .. 15] == "camunda-sdk-42-");
    assert(a == cngKeyName(42, key, "secret"), "same key, same name");
    assert(a != cngKeyName(42, key, "wrong"), "a wrong passphrase gets its own name");
    assert(a != cngKeyName(42, key, ""), "unencrypted differs from encrypted");
    assert(a != cngKeyName(43, key, "secret"), "scoped to the process");
    assert(a != cngKeyName(42, cast(const(ubyte)[]) "other key", "secret"));
    // The separator keeps (material, secret) pairs apart.
    assert(cngKeyName(1, cast(const(ubyte)[]) "ab", "c") != cngKeyName(1, cast(const(ubyte)[]) "a", "bc"));
    const p = cngKeyName(42, key, "secret", "p12");
    assert(p[0 .. 19] == "camunda-sdk-42-p12-" && p[19 .. $] == a[15 .. $]);
}

unittest
{
    const salt = cast(const(ubyte)[]) [1, 2, 3, 4, 5, 6, 7, 8];
    assert(pkcs12PbeParams(2000, salt) == [0xD0, 0x07, 0, 0, 8, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]);
    assert(pkcs12PbeParams(1, null) == [1, 0, 0, 0, 0, 0, 0, 0]);
}
