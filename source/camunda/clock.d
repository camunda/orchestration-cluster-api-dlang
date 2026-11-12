/// The clock all SDK runtime cadence resolves through.
///
/// Worker poll loops, eventual-consistency polling, retry backoff, backpressure
/// decay and OAuth refresh all read time here. Inject a `TestClock` so tests
/// control cadence without waiting on the wall.
///
/// See the cross-SDK contract in camunda/orchestration-cluster-api-js#450.
module camunda.clock;

@safe:

import camunda.safeio : liveSingleton, monoNowMs, sleepMs, wallNowMs;

/// Time and waiting, as the SDK runtime sees them.
interface Clock
{
    /// Monotonic milliseconds. Must never go backwards.
    long nowMs() const;

    /// Wall-clock milliseconds since the Unix epoch. May jump.
    long nowWallMs() const;

    /// Wait for `durationMs`. A zero duration must still yield.
    void sleep(long durationMs);
}

/// Real time. `nowMs` is monotonic; `sleep` is `Thread.sleep`.
final class LiveClock : Clock
{
    long nowMs() const { return monoNowMs(); }
    long nowWallMs() const { return wallNowMs(); }
    void sleep(long durationMs)
    {
        sleepMs(durationMs < 1 ? 0 : durationMs);
    }
}

/// The shared live clock, used when none is injected.
Clock liveClock()
{
    return liveSingleton!LiveClock();
}

/// A controllable clock for tests. `advance` moves both timelines together.
final class TestClock : Clock
{
    private long _mono;
    private long _wall;
    private long[] _sleeps;

    this(long startMs = 0)
    {
        _mono = startMs;
        _wall = startMs;
    }

    long nowMs() const { return _mono; }
    long nowWallMs() const { return _wall; }

    void sleep(long durationMs)
    {
        auto d = durationMs < 0 ? 0 : durationMs;
        _sleeps ~= d;
        _mono += d;
        _wall += d;
    }

    void advance(long ms)
    {
        _mono += ms;
        _wall += ms;
    }

    const(long)[] sleeps() const { return _sleeps; }
}

unittest
{
    auto c = new TestClock(1000);
    assert(c.nowMs == 1000);
    c.sleep(250);
    assert(c.nowMs == 1250);
    assert(c.sleeps == [250]);
}
