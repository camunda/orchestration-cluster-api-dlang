/// Transient-error retry with exponential backoff and full jitter.
///
/// Initiating operations that fail with a retryable signal (HTTP 429/502/503/504,
/// or a network-level error) are retried up to `RetryConfig.maxAttempts` with
/// exponentially increasing, fully-jittered delays.
module camunda.retry;

@safe:

import camunda.clock : Clock;
import camunda.config : RetryConfig;
import camunda.errors;
import camunda.safeio : unitRandom;

/// Whether an error should trigger a retry.
bool isRetryable(Exception err)
{
    if (cast(NetworkException) err) return true;
    if (auto api = cast(ApiException) err)
        return api.status == 429 || api.status == 502 || api.status == 503 || api.status == 504;
    return false;
}

/// Whether a `NetworkException` message says the request was never sent:
/// the connection could not be opened (DNS, refused, TLS handshake) or the
/// request timed out while queued for a connection. A read timeout or a
/// reset after sending is not one of these: the server may have applied it.
bool isNotSentNetworkError(string msg) pure
{
    import std.algorithm.searching : canFind;
    import std.uni : toLower;
    static immutable markers = [
        // libcurl (curl_easy_strerror texts)
        "couldn't resolve host", "couldn't resolve proxy", "couldn't connect",
        "ssl connect error", "ssl peer certificate", "ssl certificate problem",
        "problem with the local ssl certificate", "problem with the ssl ca cert",
        // queued in the engine, never handed to a connection
        "queued for a connection",
        // WinHTTP (winHttpErrorName texts) and the TLS check
        "host name not resolved", "could not connect", "timed out before sending to",
        "network error: tls: ", "tls failure",
    ];
    import std.algorithm.searching : startsWith;
    const m = msg.toLower;
    // WinHTTP failures raised after WinHttpSendRequest returned: the request
    // may have reached the server whatever the error code says.
    static immutable postSend = ["no response from", "no status line from", "cannot read the response from"];
    foreach (prefix; postSend)
        if (m.startsWith(prefix)) return false;
    foreach (marker; markers)
        if (m.canFind(marker)) return true;
    return false;
}

/// Retry rule for job commands (complete / fail / throw error). They are
/// not idempotent: retry only when the server says the command was not
/// applied (429, 503) or the request was never sent. Never on 504, 502,
/// 500, a read timeout or a reset after sending: the outcome is unknown,
/// and a retry of an applied command gets 404.
bool isJobCommandRetryable(Exception err)
{
    if (auto net = cast(NetworkException) err) return isNotSentNetworkError(net.msg);
    if (auto api = cast(ApiException) err) return api.status == 429 || api.status == 503;
    return false;
}

/// Whether a failed job command may have been applied anyway (the cases
/// `isJobCommandRetryable` refuses that are not plain rejections).
bool isUnknownOutcome(Exception err)
{
    if (isJobCommandRetryable(err)) return false;
    if (cast(NetworkException) err) return true;
    if (auto api = cast(ApiException) err) return api.status >= 500 || api.status == 408;
    return false;
}

/// `delay = random(0, min(maxDelay, base * 2^attempt))`.
long backoffDelayMs(const ref RetryConfig cfg, uint attempt)
{
    auto shift = attempt > 32 ? 32 : attempt;
    long exp = cfg.baseDelayMs;
    if (shift > 0)
    {
        if (exp > long.max / (1L << shift)) exp = cfg.maxDelayMs;
        else exp = exp * (1L << shift);
    }
    auto capped = exp < cfg.maxDelayMs ? exp : cfg.maxDelayMs;
    if (capped < 0) capped = 0;
    return cast(long)(capped * unitRandom());
}

/// Run `op`, retrying on transient failures per `cfg`.
T withRetry(T)(const ref RetryConfig cfg, Clock clock, scope T delegate() @safe op)
{
    return withRetry!T(cfg, clock, op, &isRetryable);
}

/// ditto, with `retryable` deciding which failures are retried.
T withRetry(T)(const ref RetryConfig cfg, Clock clock, scope T delegate() @safe op,
    bool function(Exception) @safe retryable)
{
    const maxAttempts = cfg.maxAttempts < 1 ? 1 : cfg.maxAttempts;
    uint attempt = 0;
    while (true)
    {
        try return op();
        catch (Exception err)
        {
            attempt += 1;
            if (attempt >= maxAttempts || !retryable(err)) throw err;
            clock.sleep(backoffDelayMs(cfg, attempt - 1));
        }
    }
}

unittest
{
    // Post-send WinHTTP messages are never "not sent", whatever the code name.
    assert(!isNotSentNetworkError("no response from http://h/v2/jobs/1/completion: WinHTTP 12175 TLS failure"));
    assert(!isNotSentNetworkError("no response from http://h/x: WinHTTP 12029 could not connect"));
    assert(!isNotSentNetworkError("no status line from http://h/x: WinHTTP 12175 TLS failure"));
    assert(!isNotSentNetworkError("cannot read the response from http://h/x: WinHTTP 12002 timed out"));
    assert(isNotSentNetworkError("cannot send to http://h/x: WinHTTP 12029 could not connect"));
}

unittest
{
    assert(isRetryable(new ApiException(503, "")));
    assert(isRetryable(new ApiException(429, "")));
    assert(!isRetryable(new ApiException(404, "")));
    assert(!isRetryable(new ValidationException("x")));
    assert(isRetryable(new NetworkException("reset")));
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    RetryConfig cfg;
    cfg.maxAttempts = 4;
    cfg.baseDelayMs = 1;
    cfg.maxDelayMs = 2;
    int calls;
    auto result = withRetry!int(cfg, clock, {
        calls += 1;
        if (calls < 3) throw new ApiException(503, "");
        return calls;
    });
    assert(result == 3);
    assert(calls == 3);
    assert(clock.sleeps.length == 2);
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    RetryConfig cfg;
    cfg.maxAttempts = 4;
    cfg.baseDelayMs = 1;
    cfg.maxDelayMs = 2;
    int calls;
    bool threw;
    try
    {
        cast(void) withRetry!int(cfg, clock, {
            calls += 1;
            throw new ApiException(503, "");
            return 0;
        });
    }
    catch (ApiException) threw = true;
    assert(threw);
    assert(calls == 4);
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    RetryConfig cfg;
    cfg.maxAttempts = 4;
    int calls;
    bool threw;
    try
    {
        cast(void) withRetry!int(cfg, clock, {
            calls += 1;
            throw new ValidationException("nope");
            return 0;
        });
    }
    catch (ValidationException) threw = true;
    assert(threw);
    assert(calls == 1);
    assert(clock.sleeps.length == 0);
}

unittest
{
    // Job commands: retried only when not applied.
    assert(isJobCommandRetryable(new ApiException(429, "")));
    assert(isJobCommandRetryable(new ApiException(503, "")));
    foreach (st; [500, 502, 504, 404, 400])
        assert(!isJobCommandRetryable(new ApiException(st, "")));
    assert(isJobCommandRetryable(new NetworkException("Couldn't connect to server: refused")));
    assert(isJobCommandRetryable(new NetworkException("Couldn't resolve host name")));
    assert(isJobCommandRetryable(new NetworkException("SSL connect error")));
    assert(!isJobCommandRetryable(new NetworkException("Timeout was reached: read")));
    assert(!isJobCommandRetryable(new NetworkException("Failure when receiving data from the peer")));
    assert(isUnknownOutcome(new ApiException(504, "")));
    assert(isUnknownOutcome(new NetworkException("Timeout was reached")));
    assert(!isUnknownOutcome(new ApiException(404, "")));
    assert(!isUnknownOutcome(new ApiException(503, "")));
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    RetryConfig cfg;
    cfg.maxAttempts = 4;
    int calls;
    bool threw;
    try
    {
        cast(void) withRetry!int(cfg, clock, {
            calls += 1;
            throw new ApiException(504, "");
            return 0;
        }, &isJobCommandRetryable);
    }
    catch (ApiException) threw = true;
    assert(threw && calls == 1);
}
