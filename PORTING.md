# D SDK: porting status

`orchestration-cluster-api-dlang` is a D reimplementation of the Camunda
Orchestration Cluster SDK. The JS SDK is the behavioural reference; the
architecture matches the Rust / PHP siblings: a **generated** client from the
bundled OpenAPI spec, wrapped by a **hand-written** runtime.

```sh
make generate   # bundle the spec from camunda/camunda, regenerate source/camunda/generated/
make test       # dub test
make check      # test + D-Scanner + examples
```

LDC ≥ 1.43 is required. libcurl is used for HTTP.

## What is generated (do not hand-edit)

`scripts/generate.py` is the pipeline, numbered like the sibling SDKs:

| Hook | Output | Contents |
| --- | --- | --- |
| 01 | `source/camunda/generated/keys.d` | Domain Type System: 47 semantic key newtypes (`tryNew` / `assumeExists`) |
| 02 | `source/camunda/generated/enums.d` | 48 OpenAPI string enums |
| 03 | `source/camunda/generated/models.d` | 661 JSON-backed request/response structs |
| 04 | `source/camunda/generated/operations.d` | `GeneratedOperations` mixin: 244 REST operations |
| 05 | `source/camunda/generated/package.d` | Re-exports + `generatedSpecHash` / `generatedOperationCount` |

`make generate` fetches and bundles the spec with `camunda-schema-bundler`
(same as the JS SDK; `SPEC_REF` selects the camunda/camunda ref). Change the generator, not the emitted files.

## What is hand-written

| D module | JS / Rust counterpart | Status |
| --- | --- | --- |
| `camunda/config.d` | `unifiedConfiguration` / `config.rs` | `CAMUNDA_*` resolution, aliases, auth inference, `/v2` suffix, mTLS, worker defaults, retry, backpressure profile |
| `camunda/auth.d` | `auth.ts` / `auth.rs` | NONE / BASIC / OAUTH (client-credentials, 30s lead, optional disk cache) |
| `camunda/http.d` | libcurl | GET/POST/PUT/PATCH/DELETE, mTLS paths, query encoding |
| `camunda/retry.d` | `retry.ts` / `retry.rs` | 429/502/503/504 + network, full jitter, injected clock |
| `camunda/clock.d` | `clock.ts` / `clock.rs` | `Clock` / `LiveClock` / `TestClock` |
| `camunda/backpressure.d` | `backpressure.ts` | AIMD gate, BALANCED vs LEGACY |
| `camunda/eventual.d` | `eventual.ts` | Poll until predicate / 404-retry / timeout |
| `camunda/worker.d` | `jobWorker.ts` | Long-poll activate → handler → complete/fail/error/leave, leases |
| `camunda/client.d` | `CamundaClient` | Facade + curated `topology` / `deployResources` / `eventual` / `createJobWorker` |
| `camunda/errors.d` | `errors.ts` | Typed exception taxonomy |
| `camunda/jsonx.d`, `safeio.d` | — | `@safe` JSON + C-boundary |

## Known gaps versus the JS SDK

- **Engine clock.** `Clock` is injectable; `EngineClock` (pin the broker clock)
  is not ported.
- **Falcon / command stream.** The Rust SDK's nanobpmn upgrade is not ported.
- **Threaded workers, telemetry, support logger, Zod validation.** JS-only
  surfaces, not in the PHP/Rust core either (or only partially).
- **Pagination helpers** as a first-class `.paginate` on search ops.
- **Integration tests** against a live cluster.
- **camunda-docs sync workflow** (the generator is here; the docs-site workflow is not).

## Safety

Same contract as `nano-coder-d`:

- Every module starts with `@safe:`
- `-preview=dip1000 -preview=nosharedaccess`
- Release keeps `-boundscheck=on`
- `scripts/check-safe.sh` ratchets `@trusted` (`scripts/trusted-budget`,
  `scripts/trusted-budget-safeio`) and forbids `__gshared` / `union` /
  raw threads outside `safeio.d`
