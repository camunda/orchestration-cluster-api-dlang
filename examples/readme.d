/+ dub.sdl:
name "readme-snippets"
dependency "camunda-orchestration-sdk" path=".."
+/
/// Compilable usage examples that appear in `README.md`.
///
/// Region tags use `// region <Name>` ... `// endregion <Name>`.
module readme;

import camunda;
import std.json;

void quickStart()
{
    // region QuickStart
    import camunda;

    // Reads CAMUNDA_REST_ADDRESS, CAMUNDA_AUTH_STRATEGY, CAMUNDA_CLIENT_ID, ... from the env.
    auto client = CamundaClient.fromEnv();

    auto topology = client.topology();
    import std.stdio : writeln;
    writeln("Gateway version: ", topology.gatewayVersion);
    // endregion QuickStart
    cast(void) client;
    cast(void) topology;
}

void runtimeOnly()
{
    // region RuntimeOnly
    import camunda.runtime;
    import std.json;

    auto t = Transport.fromEnv();
    JSONValue topo = t.requestJson("GET", "/topology", JSONValue.init, null);
    // endregion RuntimeOnly
    cast(void) topo;
}

void programmaticOverrides()
{
    // region Overrides
    import camunda;

    auto client = CamundaClient.create(
        CamundaOptions.create
            .withKey("CAMUNDA_REST_ADDRESS", "https://my-cluster.camunda.io")
            .withKey("CAMUNDA_AUTH_STRATEGY", "OAUTH")
            .withKey("CAMUNDA_CLIENT_ID", "my-client-id")
            .withKey("CAMUNDA_CLIENT_SECRET", "my-secret")
            .withKey("CAMUNDA_OAUTH_URL", "https://login.cloud.camunda.io/oauth/token")
            .withKey("CAMUNDA_TOKEN_AUDIENCE", "zeebe.camunda.io"),
    );
    // endregion Overrides
    cast(void) client;
}

void jobWorker()
{
    auto client = CamundaClient.fromEnv();
    // region JobWorker
    import camunda;

    auto worker = client.createJobWorker(
        JobWorkerConfig.create("payment-service")
            .maxJobs(20)
            .name("payment-worker"),
    );

    worker.run((Job job) {
        import std.stdio : writeln;
        writeln("handling job ", job.key);
        return JobAction.completeWith(JSONValue(["paid": JSONValue(true)]));
    });
    // endregion JobWorker
}

void eventualConsistency()
{
    auto client = CamundaClient.fromEnv();
    // region EventualConsistency
    import camunda;

    auto key = ProcessInstanceKey.assumeExists("2251799813685249");
    auto instance = client.eventual(ConsistencyOptions.init, {
        return client.getProcessInstance(key);
    });
    // endregion EventualConsistency
    cast(void) instance;
}

void semanticKeys()
{
    // region SemanticKeys
    import camunda;

    auto key = JobKey.tryNew("2251799813653498"); // validates pattern & length
    assert(key.value == "2251799813653498");
    // Side-load without validation:
    auto loose = JobKey.assumeExists("123");
    // endregion SemanticKeys
    cast(void) loose;
}

void main()
{
    // Type-check only. Do not run against a live cluster from this file.
    semanticKeys();
}
