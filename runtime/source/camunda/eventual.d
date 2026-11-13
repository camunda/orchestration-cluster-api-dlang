/// Eventual-consistency polling helper.
///
/// Camunda's secondary storage is eventually consistent. This helper repeatedly
/// runs a read until a predicate is met (or a timeout elapses), retrying 404s
/// on a freshly-created entity.
module camunda.eventual;

@safe:

import camunda.clock : Clock;
import camunda.errors;

struct ConsistencyOptions
{
    /// Overall timeout in milliseconds. 0 means "use the SDK default".
    long timeoutMs;
    /// Delay between attempts, in milliseconds.
    long intervalMs = 250;
    /// Treat HTTP 404 as "not yet consistent" and keep polling.
    bool retryNotFound = true;

    ConsistencyOptions timeout(long ms)
    {
        timeoutMs = ms;
        return this;
    }

    ConsistencyOptions interval(long ms)
    {
        intervalMs = ms;
        return this;
    }

    ConsistencyOptions retry404(bool retry)
    {
        retryNotFound = retry;
        return this;
    }
}

/// Poll `op` until `predicate` is true, or the timeout elapses.
T poll(T)(const ref ConsistencyOptions opts, long defaultTimeoutMs, Clock clock,
    scope T delegate() @safe op, scope bool delegate(const T) @safe predicate)
{
    auto timeout = opts.timeoutMs > 0 ? opts.timeoutMs : defaultTimeoutMs;
    auto started = clock.nowMs();
    while (true)
    {
        try
        {
            auto value = op();
            if (predicate(value)) return value;
        }
        catch (ApiException e)
        {
            if (!(e.status == 404 && opts.retryNotFound)) throw e;
        }
        auto elapsed = clock.nowMs() - started;
        if (elapsed >= timeout)
            throw new EventualConsistencyTimeout(elapsed);
        clock.sleep(opts.intervalMs);
    }
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    ConsistencyOptions opts;
    opts.intervalMs = 1;
    opts.timeoutMs = 1000;
    int calls;
    auto result = poll!int(opts, 1000, clock, {
        calls += 1;
        return calls;
    }, (const int v) => v >= 3);
    assert(result == 3);
    assert(calls == 3);
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    ConsistencyOptions opts;
    opts.intervalMs = 10;
    opts.timeoutMs = 25;
    bool threw;
    try
    {
        poll!int(opts, 25, clock, { return 0; }, (const int) => false);
    }
    catch (EventualConsistencyTimeout) threw = true;
    assert(threw);
}

unittest
{
    import camunda.clock : TestClock;
    auto clock = new TestClock;
    ConsistencyOptions opts;
    opts.intervalMs = 1;
    opts.timeoutMs = 1000;
    int calls;
    auto result = poll!int(opts, 1000, clock, {
        calls += 1;
        if (calls < 3) throw new ApiException(404, "missing");
        return 7;
    }, (const int) => true);
    assert(result == 7);
}
