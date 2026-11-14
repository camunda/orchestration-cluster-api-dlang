# Camunda Orchestration Cluster API — D SDK (Technical Preview)

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Ergonomic D SDK for the [Camunda 8 Orchestration Cluster REST API](https://docs.camunda.io/docs/apis-tools/orchestration-cluster-api-rest/orchestration-cluster-api-rest-overview/).

This SDK follows the same architecture as the official
[JavaScript](https://github.com/camunda/orchestration-cluster-api-js),
[Python](https://github.com/camunda/orchestration-cluster-api-python),
[C#](https://github.com/camunda/orchestration-cluster-api-csharp),
[Rust](https://github.com/camunda/orchestration-cluster-api-rust),
[Go](https://github.com/camunda/orchestration-cluster-api-go), and
[PHP](https://github.com/camunda/orchestration-cluster-api-php) SDKs:

- A **generated client** produced from the upstream OpenAPI spec.
- A **hand-written runtime** on top: environment-driven configuration,
  authentication, typed errors, retry, backpressure, and **job workers**.
- The **Camunda Domain Type System**: semantic keys such as `JobKey` and
  `ProcessInstanceKey` are distinct types with validation, not bare strings.

The public API is **synchronous** (libcurl), like the PHP SDK.

Target API version: **8.11**.

## Support status

This is a **Technical Preview** of the D client for the Camunda 8 Orchestration Cluster
API, provided for evaluation and feedback. It gives you a stable foundation to build on
now, with a clear path to full support: we do not intend to make breaking changes to the
application integration surface, but we do not guarantee that we will not. The SDK will
become fully supported with an SLA in a future release.

We don't anticipate major changes — and
[your feedback](https://github.com/camunda/orchestration-cluster-api-dlang/issues) is what
helps close that gap.

> As a Technical Preview, the API surface may still evolve before it is declared fully
> supported. Pin a specific version if you need stability.

## Requirements

- [LDC](https://github.com/ldc-developers/ldc) 1.43 or later, and dub
- libcurl (ships with macOS; on Linux install `libcurl4` / `libcurl-devel`)

On macOS: `brew install ldc dub`. Elsewhere, see the
[LDC releases](https://github.com/ldc-developers/ldc/releases).

DMD and GDC are rejected: the build requires LDC's DIP1000 / nosharedaccess
support.

## Install

The SDK is published on the D package registry as
[`camunda-orchestration-sdk`](https://code.dlang.org/packages/camunda-orchestration-sdk).
Add it to your project with dub:

```sh
dub add camunda-orchestration-sdk
```

This adds the latest stable release (for example `"camunda-orchestration-sdk": "~>10.1.1"`)
to your `dub.json`. dub picks stable releases over prereleases, so the 11.x
alphas are not selected unless you ask for them.

Pick the release line that matches your Camunda version (SDK major = Camunda minor):

| Camunda | SDK line | Branch | Spec source (camunda/camunda) | `dub.json` constraint |
| --- | --- | --- | --- | --- |
| 8.10 | `10.x` (stable) | `stable/10` | `stable/8.10` | `"~>10.1"` |
| 8.11 (in development) | `11.0.0-alpha.N` (prerelease) | `main` | `main` | `"~>11.0.0-alpha.2"` |

```json
{
  "dependencies": {
    "camunda-orchestration-sdk": "~>10.1"
  }
}
```

To try the 8.11 prerelease line: `dub add 'camunda-orchestration-sdk@~>11.0.0-alpha.2'`.
Alphas can change between releases; pin an exact version (`"==11.0.0-alpha.2"`)
if you need repeatable builds, and commit `dub.selections.json`.

Every release is a git tag (`vX.Y.Z`) with a
[GitHub Release](https://github.com/camunda/orchestration-cluster-api-dlang/releases);
the registry picks new tags up automatically.

To build against an unreleased commit, check the repo out and register it
locally (it then overrides the registry version for matching constraints):

```sh
git clone https://github.com/camunda/orchestration-cluster-api-dlang.git
dub add-local orchestration-cluster-api-dlang   # undo: dub remove-local …
```

### Transport only: `camunda-orchestration-sdk:runtime`

If you call the REST API generically (a CLI, a proxy, a catalog-driven tool)
and do not need the typed operations, depend on the runtime sub-package. It
has the same `CAMUNDA_*` configuration, auth (NONE / BASIC / OAuth), retry,
backpressure and TLS as the full SDK, without compiling the generated models.

```json
{
  "dependencies": {
    "camunda-orchestration-sdk:runtime": "~>10.1"
  }
}
```

<!-- snippet-source: examples/readme.d | regions: RuntimeOnly -->
```d
import camunda.runtime;
import std.json;

auto t = Transport.fromEnv();
JSONValue topo = t.requestJson("GET", "/topology", JSONValue.init, null);
```

The full SDK depends on `:runtime`; `CamundaClient.transport` exposes the same
object.

## Quick start

<!-- snippet-source: examples/readme.d | regions: QuickStart -->

```d
import camunda;

// Reads CAMUNDA_REST_ADDRESS, CAMUNDA_AUTH_STRATEGY, CAMUNDA_CLIENT_ID, ... from the env.
auto client = CamundaClient.fromEnv();

auto topology = client.topology();
import std.stdio : writeln;
writeln("Gateway version: ", topology.gatewayVersion);
```

Programmatic configuration overrides take precedence over the environment:

<!-- snippet-source: examples/readme.d | regions: Overrides -->

```d
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
```

## Authentication

The strategy is chosen by `CAMUNDA_AUTH_STRATEGY` (or inferred from the
credentials that are present):

| Strategy | Required configuration |
| --- | --- |
| `OAUTH` | `CAMUNDA_CLIENT_ID`, `CAMUNDA_CLIENT_SECRET`, `CAMUNDA_OAUTH_URL`, optional `CAMUNDA_TOKEN_AUDIENCE`, `CAMUNDA_OAUTH_SCOPE` |
| `BASIC` | `CAMUNDA_BASIC_AUTH_USERNAME`, `CAMUNDA_BASIC_AUTH_PASSWORD` |
| `NONE`  | — (local development) |

OAuth uses the client-credentials grant. Tokens are cached in memory and
refreshed 30 seconds before expiry. Set `CAMUNDA_OAUTH_CACHE_DIR` to persist
them across process restarts.

## Semantic keys

Identifiers are distinct types. `tryNew` validates the spec constraints;
`assumeExists` side-loads a value received out of band.

<!-- snippet-source: examples/readme.d | regions: SemanticKeys -->

```d
import camunda;

auto key = JobKey.tryNew("2251799813653498"); // validates pattern & length
assert(key.value == "2251799813653498");
// Side-load without validation:
auto loose = JobKey.assumeExists("123");
```

## Job workers

<!-- snippet-source: examples/readme.d | regions: JobWorker -->

```d
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
```

## Eventual consistency

Reads against secondary storage may lag a write. `eventual` polls until the
read succeeds (retrying 404s) or the timeout elapses.

<!-- snippet-source: examples/readme.d | regions: EventualConsistency -->

```d
import camunda;

auto key = ProcessInstanceKey.assumeExists("2251799813685249");
auto instance = client.eventual(ConsistencyOptions.init, {
    return client.getProcessInstance(key);
});
```

## Configuration reference

<!-- BEGIN_CONFIG_REFERENCE -->

| Variable | Default | Description |
| --- | --- | --- |
| `CAMUNDA_REST_ADDRESS` | `http://localhost:8080` | Cluster REST endpoint. `/v2` is appended automatically when absent. |
| `ZEEBE_REST_ADDRESS` | — | Legacy alias for `CAMUNDA_REST_ADDRESS` (used only when the latter is unset). |
| `CAMUNDA_REST_ADDRESS_EXACT` | `false` | Disable the automatic `/v2` suffix so `CAMUNDA_REST_ADDRESS` is used as the base path. |
| `CAMUNDA_AUTH_STRATEGY` | — | `NONE`, `BASIC`, or `OAUTH`. Auto-detected from the supplied credentials when unset. |
| `CAMUNDA_CLIENT_ID` | — | OAuth client id. |
| `CAMUNDA_CLIENT_SECRET` | — | OAuth client secret. |
| `CAMUNDA_CLIENT_AUTH_CLIENTID` | — | Legacy alias for `CAMUNDA_CLIENT_ID`. |
| `CAMUNDA_CLIENT_AUTH_CLIENTSECRET` | — | Legacy alias for `CAMUNDA_CLIENT_SECRET`. |
| `CAMUNDA_OAUTH_URL` | `https://login.cloud.camunda.io/oauth/token` | OAuth token endpoint. |
| `CAMUNDA_TOKEN_AUDIENCE` | `zeebe.camunda.io` | OAuth token audience. |
| `CAMUNDA_OAUTH_SCOPE` | — | Optional OAuth scope. |
| `CAMUNDA_OAUTH_CACHE_DIR` | — | Directory for the on-disk OAuth token cache. Unset disables disk caching. |
| `CAMUNDA_BASIC_AUTH_USERNAME` | — | Basic-auth username. |
| `CAMUNDA_BASIC_AUTH_PASSWORD` | — | Basic-auth password. |
| `CAMUNDA_DEFAULT_TENANT_ID` | — | Default tenant id applied to tenant-aware operations (alias `CAMUNDA_TENANT_ID`). |
| `CAMUNDA_TENANT_ID` | — | Alias for `CAMUNDA_DEFAULT_TENANT_ID`. |
| `CAMUNDA_TENANT_IDS` | — | Comma-separated default tenant ids (e.g. for job activation). |
| `CAMUNDA_SDK_BACKPRESSURE_PROFILE` | `BALANCED` | `BALANCED`, `CONSERVATIVE`, `AGGRESSIVE`, or `LEGACY` (observe-only). |
| `CAMUNDA_SDK_HTTP_RETRY_MAX_ATTEMPTS` | `3` | Total HTTP attempts for transient failures (429, 502, 503, 504, network). |
| `CAMUNDA_SDK_HTTP_RETRY_BASE_DELAY_MS` | `100` | Base backoff delay, in milliseconds. |
| `CAMUNDA_SDK_HTTP_RETRY_MAX_DELAY_MS` | `2000` | Backoff cap, in milliseconds. |
| `CAMUNDA_SDK_EVENTUAL_POLL_DEFAULT_MS` | `10000` | Default overall timeout for `eventual` polling, in milliseconds. |
| `CAMUNDA_SDK_LOG_LEVEL` | `info` | `off`, `error`, `warn`, `info`, `debug`, or `trace`. |
| `CAMUNDA_WORKER_TIMEOUT` | `60000` | Default job activation timeout, in milliseconds. |
| `CAMUNDA_WORKER_MAX_CONCURRENT_JOBS` | `32` | Default maximum number of jobs a worker activates at once. |
| `CAMUNDA_WORKER_REQUEST_TIMEOUT` | `10000` | Default long-poll request timeout, in milliseconds. |
| `CAMUNDA_WORKER_NAME` | `d-sdk-worker` | Default worker name reported when activating jobs. |
| `CAMUNDA_WORKER_STARTUP_JITTER_MAX_SECONDS` | `0` | Maximum random startup delay before the first poll, in seconds. |
| `CAMUNDA_MTLS_CERT` | — | Inline PEM client certificate. |
| `CAMUNDA_MTLS_KEY` | — | Inline PEM client private key. |
| `CAMUNDA_MTLS_CA` | — | Inline PEM CA bundle. |
| `CAMUNDA_MTLS_CERT_PATH` | — | Path to the client certificate for mutual TLS. |
| `CAMUNDA_MTLS_KEY_PATH` | — | Path to the client private key for mutual TLS. |
| `CAMUNDA_MTLS_CA_PATH` | — | Path to the CA bundle used to verify the server certificate. |
| `CAMUNDA_MTLS_KEY_PASSPHRASE` | — | Passphrase protecting the mTLS client key, if any. |

<!-- END_CONFIG_REFERENCE -->

## Safety

Every module is `@safe`. Escapes live in `runtime/source/camunda/safeio.d` (and three
libcurl / JSON / Base64 wrappers) and are budgeted by `scripts/check-safe.sh`.
The build uses `-preview=dip1000` and `-preview=nosharedaccess` and keeps
bounds checks on in release.

See `AGENTS.md` for the contributor contract.

## API reference

Generated from the bundled spec (do not edit by hand):

- [API reference](docs/api-reference.md) — every REST operation on `CamundaClient`
- [Semantic types](docs/semantic-types.md) — every domain key and its constraints

## Regenerating the client

The spec comes from [camunda/camunda](https://github.com/camunda/camunda)
(`zeebe/gateway-protocol/src/main/proto/v2`), fetched and bundled by
[camunda-schema-bundler](https://www.npmjs.com/package/camunda-schema-bundler),
the same tool and pipeline as the JS SDK. The bundled spec is committed, so
only fetching a new spec needs Node.js. The generator and every repository
check are D programs in `scripts/`, run by dub with the toolchain above:

```sh
npm install                           # Node.js: only for make generate / bundle-spec
make generate                         # bundle from camunda/camunda main, then generate
SPEC_REF=<branch|tag|sha> make generate
make generate-local                   # regenerate from the committed bundle only
make test
```

`main` tracks camunda/camunda `main`; `stable/N` tracks `stable/8.N`. Each
release re-bundles and commits any drift as `fix(gen): regenerate artifacts`.
`source/camunda/generated/` is never hand-edited.

## License

Apache-2.0.
