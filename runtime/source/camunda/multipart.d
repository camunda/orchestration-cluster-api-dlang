/// `multipart/form-data` bodies for the upload operations (deployments,
/// documents). Pair with `Transport.requestRaw(method, path, m.contentType, m.body_)`.
module camunda.multipart;

@safe:

/// Builds a `multipart/form-data` body (RFC 7578).
struct Multipart
{
    private string _boundary;
    private ubyte[] _buf;

    /// A builder with a random boundary (fixed `boundary` for tests).
    static Multipart create(string boundary = null)
    {
        Multipart m;
        m._boundary = boundary.length ? boundary : randomBoundary();
        return m;
    }

    /// A file part: `name` is the form field, `fileName` the reported file name.
    ref Multipart addFile(string name, string fileName, string contentType, const(ubyte)[] bytes,
        string[string] extraHeaders = null) return
    {
        open();
        put("Content-Disposition: form-data; name=\"" ~ quoted(name) ~ "\"; filename=\"" ~ quoted(fileName) ~ "\"\r\n");
        put("Content-Type: " ~ (contentType.length ? contentType : "application/octet-stream") ~ "\r\n");
        foreach (k, v; extraHeaders) put(k ~ ": " ~ v ~ "\r\n");
        put("\r\n");
        _buf ~= bytes;
        put("\r\n");
        return this;
    }

    /// A text field, optionally typed (e.g. `application/json` for metadata).
    ref Multipart addField(string name, string value, string contentType = null) return
    {
        open();
        put("Content-Disposition: form-data; name=\"" ~ quoted(name) ~ "\"\r\n");
        if (contentType.length) put("Content-Type: " ~ contentType ~ "\r\n");
        put("\r\n");
        put(value);
        put("\r\n");
        return this;
    }

    /// The `Content-Type` header value, including the boundary.
    string contentType() const { return "multipart/form-data; boundary=" ~ _boundary; }

    /// The finished body (closing delimiter appended).
    immutable(ubyte)[] body_() const
    {
        return (_buf ~ cast(const(ubyte)[]) ("--" ~ _boundary ~ "--\r\n")).idup;
    }

    private void open() { put("--" ~ _boundary ~ "\r\n"); }
    private void put(string s) { _buf ~= cast(const(ubyte)[]) s; }
}

private string quoted(string s)
{
    import std.array : replace;
    return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\r", "").replace("\n", "");
}

private string randomBoundary()
{
    import std.random : uniform;
    enum hex = "0123456789abcdef";
    char[24] tail;
    foreach (ref c; tail) c = hex[uniform(0, 16)];
    return "----camunda-sdk-d-" ~ tail.idup;
}

/// Best-effort MIME type from a file name's extension (`application/octet-stream` otherwise).
string mimeTypeFor(string fileName) pure
{
    import std.path : extension;
    import std.uni : toLower;
    switch (fileName.extension.toLower)
    {
    case ".pdf": return "application/pdf";
    case ".json": return "application/json";
    case ".txt": return "text/plain";
    case ".csv": return "text/csv";
    case ".html", ".htm": return "text/html";
    case ".xml", ".bpmn", ".dmn": return "application/xml";
    case ".png": return "image/png";
    case ".jpg", ".jpeg": return "image/jpeg";
    case ".gif": return "image/gif";
    case ".svg": return "image/svg+xml";
    case ".zip": return "application/zip";
    default: return "application/octet-stream";
    }
}

unittest
{
    auto m = Multipart.create("B");
    m.addFile("file", "a \"q\".txt", "text/plain", cast(const(ubyte)[]) "hi")
     .addField("metadata", `{"k":1}`, "application/json");
    assert(m.contentType == "multipart/form-data; boundary=B");
    assert(cast(string) m.body_ ==
        "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a \\\"q\\\".txt\"\r\n" ~
        "Content-Type: text/plain\r\n\r\nhi\r\n" ~
        "--B\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{\"k\":1}\r\n" ~
        "--B--\r\n");
    assert(Multipart.create().contentType != Multipart.create().contentType);
    assert(mimeTypeFor("x/Report.PDF") == "application/pdf");
    assert(mimeTypeFor("noext") == "application/octet-stream");
}
