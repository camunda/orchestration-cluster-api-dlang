/// Typed error surface, mirroring the JS / Rust / PHP SDKs.
module camunda.errors;

@safe:

import std.format : format;

/// Base of every SDK exception. Catch this to handle any Camunda failure.
class CamundaException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

class ConfigException : CamundaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super("configuration error: " ~ msg, file, line);
    }
}

class AuthException : CamundaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super("authentication error: " ~ msg, file, line, next);
    }
}

class NetworkException : CamundaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super("network error: " ~ msg, file, line, next);
    }
}

class SerializationException : CamundaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super("serialization error: " ~ msg, file, line, next);
    }
}

class ValidationException : CamundaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super("validation error: " ~ msg, file, line);
    }
}

class BackpressureException : CamundaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super("backpressure error: " ~ msg, file, line);
    }
}

/// The server returned a non-success HTTP status (often an RFC 7807 problem).
class ApiException : CamundaException
{
    int status;
    string body_;

    this(int status, string body_, string file = __FILE__, size_t line = __LINE__)
    {
        this.status = status;
        this.body_ = body_;
        auto shown = body_.length > 400 ? body_[0 .. 400] ~ "…" : body_;
        super(format("API error: HTTP %s%s", status, shown.length ? " — " ~ shown : ""), file, line);
    }
}

class EventualConsistencyTimeout : CamundaException
{
    long elapsedMs;
    this(long elapsedMs, string file = __FILE__, size_t line = __LINE__)
    {
        this.elapsedMs = elapsedMs;
        super(format("eventual consistency timeout: condition not met after %sms", elapsedMs), file, line);
    }
}

/// A worker asked for a lease and the server returned a job without a token.
class LeaseNotHonored : CamundaException
{
    string jobKey;
    string requestFlag;
    this(string jobKey, string requestFlag, string file = __FILE__, size_t line = __LINE__)
    {
        this.jobKey = jobKey;
        this.requestFlag = requestFlag;
        super(format(
            "lease not honored: activation for job %s set `%s` but the server returned no lease token",
            jobKey, requestFlag), file, line);
    }
}

unittest
{
    auto e = new ApiException(404, `{"title":"not found"}`);
    assert(e.status == 404);
    assert(cast(CamundaException) e !is null);
}
