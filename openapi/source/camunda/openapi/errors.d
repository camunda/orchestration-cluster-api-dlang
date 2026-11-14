/// Typed errors for the OpenAPI reader. Every failure raised while reading an
/// untrusted document is an `OpenApiException` that carries the JSON-pointer
/// path of the offending node, so callers can point a human at the problem.
module camunda.openapi.errors;

@safe:

/// An error reading or interpreting an OpenAPI (or JSON) document.
class OpenApiException : Exception
{
    /// JSON-pointer path (RFC 6901) of the node that caused the error, e.g.
    /// `#/components/schemas/Foo/allOf/0`. Empty when there is no meaningful
    /// location (for example a document-size limit).
    string path;

    this(string msg, string path = null, string file = __FILE__, size_t line = __LINE__)
    {
        this.path = path;
        super(path is null ? msg : msg ~ " (at " ~ path ~ ")", file, line);
    }
}

/// The document exceeded a reader limit (nesting depth, size, `$ref` chain).
class OpenApiLimitException : OpenApiException
{
    this(string msg, string path = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, path, file, line);
    }
}

/// A cyclic `$ref` was detected while resolving.
class OpenApiCycleException : OpenApiException
{
    this(string msg, string path = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, path, file, line);
    }
}
