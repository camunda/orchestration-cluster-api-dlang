/+ dub.sdl:
name "topology"
dependency "camunda-orchestration-sdk" path=".."
+/
/// Connect to a cluster and print its topology.
///
/// Run with: `dub run --single examples/topology.d`
///
/// Configure via environment variables, e.g. for a local cluster:
///   CAMUNDA_REST_ADDRESS=http://localhost:8080
module topology;

import camunda;
import std.stdio : writeln;

void main()
{
    auto client = CamundaClient.fromEnv();
    auto topology = client.topology();
    writeln("Gateway version: ", topology.gatewayVersion);
    writeln("Cluster size:    ", topology.clusterSize);
    writeln("Brokers:         ", topology.brokers.length);
}
