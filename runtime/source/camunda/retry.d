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
    const maxAttempts = cfg.maxAttempts < 1 ? 1 : cfg.maxAttempts;
    uint attempt = 0;
    while (true)
    {
        try return op();
        catch (Exception err)
        {
            attempt += 1;
            if (attempt >= maxAttempts || !isRetryable(err)) throw err;
            clock.sleep(backoffDelayMs(cfg, attempt - 1));
        }
    }
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
