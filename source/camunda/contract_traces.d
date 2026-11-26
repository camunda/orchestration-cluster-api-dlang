/// Golden-trace replay of `camunda.contract` against the traces generated
/// from the SPARK-proved `Camunda_Contract` package (vendored under
/// `tests/contract-traces/`, see its README). Test-only.
module camunda.contract_traces;

@safe:

version (unittest):

import camunda.contract;
import std.conv : to;
import std.json;

private JSONValue[] casesOf(string text, string machine)
{
    auto doc = parseJSON(text);
    assert(doc["schemaVersion"].integer == 1, "unknown trace schemaVersion");
    assert(doc["machine"].str == machine);
    auto cases = doc["cases"].arrayNoRef;
    assert(cases.length > 0, machine ~ ": no cases");
    return cases;
}

private long num(const JSONValue v, string key) { return v[key].integer; }
private bool flag(const JSONValue v, string key) { return v[key].boolean; }

private void expectEmpty(const JSONValue output, string where)
{
    assert(output.type == JSONType.object && output.objectNoRef.length == 0, where ~ ": expected empty output");
}

unittest // slots.json: (state, event) -> state' parity for WorkerSlotState
{
    size_t steps;
    foreach (c; casesOf(import("slots.json"), "slots"))
    {
        const name = c["name"].str;
        auto s = WorkerSlotState.make(num(c["initial"], "capacity"));
        foreach (i, step; c["steps"].arrayNoRef)
        {
            const where = name ~ "#" ~ i.to!string;
            auto ev = step["event"];
            auto output = step["output"];
            switch (ev["type"].str)
            {
            case "observe":
                assert(s.freeSlots == num(output, "freeSlots"), where);
                assert(s.isDrained == flag(output, "isDrained"), where);
                break;
            case "requestedBatchSize":
                assert(s.requestedBatchSize(num(ev, "permitted")) == num(output, "requestedBatchSize"), where);
                break;
            case "reserve":
                assert(s.reserveSlots(num(ev, "count")) == num(output, "taken"), where);
                break;
            case "release":
                s.releaseSlots(num(ev, "count"));
                expectEmpty(output, where);
                break;
            case "markStopped":
                s.markStopped();
                expectEmpty(output, where);
                break;
            default:
                assert(false, where ~ ": unknown event " ~ ev["type"].str);
            }
            auto st = step["state"];
            assert(s.capacity == num(st, "capacity"), where);
            assert(s.inFlight == num(st, "inFlight"), where);
            assert(s.stopped == flag(st, "stopped"), where);
            steps++;
        }
    }
    assert(steps > 0);
}

unittest // backpressure.json: AIMD parity for BackpressureState
{
    size_t steps;
    foreach (c; casesOf(import("backpressure.json"), "backpressure"))
    {
        const name = c["name"].str;
        auto init = c["initial"];
        auto b = BackpressureState.make(num(init, "minLimit"), num(init, "maxLimit"), num(init, "recoveryWindow"));
        foreach (i, step; c["steps"].arrayNoRef)
        {
            const where = name ~ "#" ~ i.to!string;
            auto ev = step["event"];
            switch (ev["type"].str)
            {
            case "observe": break;
            case "backpressure":
                assert(isBackpressureStatus(num(ev, "status")), where);
                b.onBackpressure();
                break;
            case "healthy": b.onHealthy(); break;
            default:
                assert(false, where ~ ": unknown event " ~ ev["type"].str);
            }
            expectEmpty(step["output"], where);
            auto st = step["state"];
            assert(b.minLimit == num(st, "minLimit"), where);
            assert(b.maxLimit == num(st, "maxLimit"), where);
            assert(b.currentLimit == num(st, "currentLimit"), where);
            assert(b.healthyStreak == num(st, "healthyStreak"), where);
            assert(b.recoveryWindow == num(st, "recoveryWindow"), where);
            steps++;
        }
    }
    assert(steps > 0);
}

unittest // retry.json: status classification and backoff parity
{
    size_t steps;
    foreach (c; casesOf(import("retry.json"), "retry"))
    {
        const name = c["name"].str;
        auto init = c["initial"];
        foreach (i, step; c["steps"].arrayNoRef)
        {
            const where = name ~ "#" ~ i.to!string;
            auto ev = step["event"];
            auto output = step["output"];
            switch (ev["type"].str)
            {
            case "classifyStatus":
                const status = num(ev, "status");
                assert(isRetryableStatus(status) == flag(output, "isRetryable"), where);
                assert(isBackpressureStatus(status) == flag(output, "isBackpressure"), where);
                break;
            case "retryDelay":
                assert(retryDelayMs(num(ev, "attempt"), num(init, "baseMs"), num(init, "maxDelayMs"))
                    == num(output, "delayMs"), where);
                break;
            default:
                assert(false, where ~ ": unknown event " ~ ev["type"].str);
            }
            expectEmpty(step["state"], where);
            steps++;
        }
    }
    assert(steps > 0);
}
