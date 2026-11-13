/// Entry point of `camunda-orchestration-sdk:runtime`: the spec-agnostic
/// transport (config, auth, HTTP, retry, backpressure, eventual consistency).
///
/// Use this when you call the REST API generically (e.g. a CLI driven by a
/// catalog). For typed operations import `camunda` instead.
module camunda.runtime;

@safe:

public import camunda.auth : Authentication;
public import camunda.backpressure : BackpressureManager, BackpressureSeverity, BackpressureState;
public import camunda.clock : Clock, LiveClock, TestClock, liveClock;
public import camunda.config : AuthStrategy, BackpressureProfile, CamundaConfig, LogLevel, RetryConfig, TlsConfig, WorkerDefaults;
public import camunda.errors;
public import camunda.eventual : ConsistencyOptions;
public import camunda.transport : CamundaOptions, Transport, shouldSendJsonBody;
public import camunda.version_ : sdkUserAgent, sdkVersion;
