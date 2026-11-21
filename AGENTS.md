# AGENTS.md

> This repo follows the central Camunda AGENTS guidelines:
> https://raw.githubusercontent.com/camunda/.github/refs/heads/main/AGENTS.md
> The instructions below extend those and take precedence on conflict.

<!-- sdk-infra-delegation:start -->
> **Note:** This file also delegates to the shared SDK AGENTS.md. Read and apply it too.

**URL:**
https://raw.githubusercontent.com/camunda/sdk-infra/refs/heads/main/policies/AGENTS.md

It holds the conventions shared by all Camunda SDK repos (commits, bug fixes, tests, opening issues). Precedence on conflict: this file, then the shared SDK file, then the central Camunda file.
<!-- sdk-infra-delegation:end -->

## Opening issues

Every issue you open (`gh issue create`, REST or MCP) must carry the SDK defect-metrics fields (https://camunda.github.io/sdk-quality-metrics/). This applies in this repo and to issues you file elsewhere (other SDKs, camunda/sdk-infra, camunda/camunda). Put these lines at the end of the body, or set the matching labels directly:

```
Type: bug | enhancement | documentation | question
Found-by: review | ci | conformance-test | performance-test | integration | manual-test | audit | user
Affects: main | stable | both
Severity: critical | high | medium | low
Introduced-by: <commit sha | owner/repo@sha | #PR | release tag>   (optional)
```

- For a bug, `Found-by`, `Affects` and `Severity` are required. Without them the issue gets `needs-triage`.
- `Found-by` is the quality layer that caught it, not who typed the issue. `Affects: stable` means a released `stable/N` line.
- An issue created with a workflow's `GITHUB_TOKEN` does not trigger `sdk-issue-labels.yml`, so the body lines are not turned into labels. Set the labels directly instead: `--label <type> --label found-by/<x> --label affects/<main|stable> --label severity/<x>`, where `<type>` is the `Type` value (`bug`, `enhancement`, `documentation`, `question`). For `Affects: both`, add both `--label affects/main` and `--label affects/stable`.
- Until this repo adopts `sdk-issue-labels.yml` (https://github.com/camunda/orchestration-cluster-api-dlang/issues/44), body lines are not converted here: always set the labels directly.

Value definitions: [shared policy, "Opening issues"](https://github.com/camunda/sdk-infra/blob/main/policies/AGENTS.md#opening-issues).

## Role & boundary

This repo produces the **D SDK** for the Camunda 8 Orchestration Cluster REST API.
It is a sibling of the JS / Python / C# / Rust / Go / PHP / Java SDKs and follows
the same pattern: a **generated** low-level client wrapped by a **hand-written**
ergonomic runtime. Target API version: **8.11** (`main` of the JS reference).

The D port uses the same configuration and strictness as
[`nano-coder-d`](https://github.com/nanobpm/nano-coder) (`d/`): LDC ≥ 1.43,
module-level `@safe:`, `-preview=dip1000`, `-preview=nosharedaccess`,
`-boundscheck=on` in release, and a ratchet on `@trusted`.

Upstream dependencies — fix at the source when they misbehave, not by working
around them here:

- [`camunda-schema-bundler`](https://github.com/camunda/camunda-schema-bundler) —
  fetches and bundles the upstream OpenAPI spec.
- [`camunda/camunda`](https://github.com/camunda/camunda) — source of the OpenAPI spec.
- The JS SDK (`orchestration-cluster-api-js`) is the behavioural reference.

## Path map

| Path | Ownership and intent |
| --- | --- |
| `runtime/source/camunda/` | `:runtime` sub-package. Spec-agnostic transport: config, auth, HTTP, retry, clock, backpressure, eventual, `transport.d` (`Transport`), `runtime.d` (entry). Must not import `camunda.generated`. **Primary edit surface.** |
| `runtime/source/camunda/safeio.d` | The `@trusted` C-boundary. Review like Rust `unsafe`. |
| `source/camunda/` | Typed SDK on top of `:runtime`: `client.d` (`CamundaClient` wraps `Transport` + generated facade), `worker.d`, `package.d`. |
| `source/camunda/generated/` | **Generated.** Produced by `make generate`. Never hand-edit. |
| `scripts/generate.d` | Numbered generation hooks (01 keys … 07 examples). **Primary edit surface** for generated output. |
| `scripts/*.d` | Repo tooling as dub single-file programs (`dub run -q --single scripts/<name>.d`; the Makefile wraps them). No Python; Node.js is only needed for `npm run bundle:spec` and releases. |
| `scripts/sync-readme-snippets.d` | Injects `examples/*.d` region snippets into `README.md`. `--check` is the CI gate. |
| `docs/` | **Generated.** `api-reference.md` and `semantic-types.md`. Never hand-edit. |
| `scripts/check-safe.sh` | `@safe` / `@trusted` / isolation ratchet. Runs as a dub `preBuildCommands` hook. |
| `external-spec/bundled/` | Bundled OpenAPI spec + `spec-metadata.json`, written by `npm run bundle:spec`. Committed generator inputs. |
| `examples/` | Compilable usage examples. `examples/readme.d` hosts region-tagged snippets for the README. |

## Generation pipeline

```bash
make generate        # npm run bundle:spec (camunda/camunda @ SPEC_REF, default main) + generate
make generate-local  # regenerate from the committed external-spec/bundled/ (CI drift gate)
```

`scripts/generate.d` reads `external-spec/bundled/rest-api.bundle.json` and
`spec-metadata.json` and emits:

1. `keys.d` — Camunda Domain Type System (nominal newtypes with `tryNew` / `assumeExists`).
2. `enums.d` — every OpenAPI string enum.
3. `models.d` — JSON-backed request/response structs, one per schema.
4. `operations.d` — `mixin template GeneratedOperations()`: one method per REST operation.
5. `package.d` — public re-exports + `generatedSpecHash` / `generatedOperationCount`.
6. `docs/api-reference.md` and `docs/semantic-types.md`.
7. `examples/<tag>.d` + `examples/operation-map.json` — one compilable region per REST operation.

The spec is fetched from camunda/camunda and bundled by `camunda-schema-bundler`
(`npm run bundle:spec`), exactly as in the JS SDK. The default ref lives in
`package.json`: `main` on `main`, `stable/8.N` on `stable/N`. `publish.yml`
re-bundles on every release and commits drift as `fix(gen): regenerate artifacts`. Do **not** hand-edit `source/camunda/generated/`, `docs/`,
or the generated example files.

README snippets are injected from `examples/readme.d` by `make sync-readme`.
The configuration table is injected by `make config-reference`.
`make example-coverage` requires every spec operation to have a region.
`make docs-md` writes `docs-md/d-sdk/` for camunda-docs (gitignored).

## Build / test / lint

```bash
make test        # dub test
make lint        # check-safe.sh + D-Scanner
make examples    # type-check every examples/*.d
make sync-readme-check
make config-reference-check
make example-coverage
make docs-md
make typecheck-windows  # compile Windows-only code for Windows (seconds; part of make check)
make check-windows      # dub test on a real Windows runner for the working tree (~1-2 min)
make check       # full local CI gate
```

### Windows code

Code behind `version (Windows)` (`winhttp.d`, `wincrypt.d`, Windows
branches elsewhere) is not compiled by a POSIX build, and its tests only run
on Windows. Before you push a change that touches it:

1. `make check` includes `make typecheck-windows`, which catches compile errors.
2. Run `make check-windows`, which runs the tests on a real Windows runner (it
   needs `gh` auth and push access). Push only when it passes. A green
   POSIX run says nothing about this code.

Where you can, put the logic in plain functions that build and test on every
OS (key naming, cache keys, error mapping), and keep the Windows-only part to
the API calls.

All code is `@safe`. Every module starts with `@safe:`. Calls the compiler
cannot check live in small `@trusted` functions (shared ones in `safeio.d`).
`scripts/check-safe.sh` fails the build on a module without `@safe:`, a
`@system:`/`@trusted:` label, `@system` outside `extern (C)`, a `@trusted`
without a comment above it saying why it is safe, or more `@trusted` than the
budgets allow.

The build uses `-preview=dip1000` and `-preview=nosharedaccess` and requires
LDC 1.43 or later (dub rejects DMD and GDC). Release builds keep
`-boundscheck=on`.

### Always-green policy

Warnings are fatal. Do not suppress a warning to make a build pass. Do not
treat any failure as pre-existing or unrelated without explicit confirmation.

### Separate generator changes from regenerated output

When a change modifies `scripts/generate.d` **and** that change alters
`source/camunda/generated/` or `docs/`, split into two commits:

1. Generator change only. No `source/camunda/generated/` changes.
2. `chore(gen): regenerate for <summary>` — the regenerated output.

## Backporting to stable branches

`.github/workflows/backport.yml` calls camunda/sdk-infra's shared `sdk-backport.yml`
(`korthout/backport-action`, running as `camunda-sdk-automation`; the same flow as the other
SDKs). It is configured by `.github/backport.yml` and `.github/actions/codegen-setup`, both
read from the **target** branch, so keep them on `main` and on every live `stable/N`
(`stable/10` still generates with `scripts/generate.py`, so its copies differ).

- Add the label `backport stable/<N>` to a PR. The backport PR opens when the PR merges, or
  right away if it is already merged.
- Or comment `/backport` on a merged PR to re-run it for its labels. PRs from forks can only
  be backported this way.

Backport hand-written runtime and infra changes when the affected code exists on the stable
branch. Never backport generated output on its own; each branch regenerates from its own spec.
A change to the generator itself doesn't carry over to `stable/10`'s Python generator: port
it by hand there, or skip it.

After the cherry-pick, the workflow adds a `chore(gen): regenerate for backport of #N`
commit. The derived files (`generated-paths`: `external-spec/`, `source/camunda/generated/`,
`docs/`, and the generated `examples/*.d` plus `operation-map.json`) are restored from the
target branch, regenerated, and unit-tested (`dub test && dub test :runtime`). `generated-paths` takes no globs or excludes, so the
generated examples are listed one by one, without the hand-written `readme.d` and
`topology.d`. **When a new API tag adds an example file, add it to `generated-paths` on
every branch that has it** before backporting such a change. The workflow commits only listed
paths: from sdk-infra#112 it fails and names an unlisted file the regeneration wrote; before
that, it silently leaves the file out.

If the cherry-pick conflicts, the action opens a **draft** PR with the conflicts committed. A
draft always means a conflict, even without conflict markers: if the source changes a file
the target lacks, `main`'s whole file is committed. Resolve it on the backport branch, then
comment `/backport` on the source PR to regenerate. If fix B builds on fix A, merge A's
backport first, then rebuild B's branch from the updated target (`git switch -C
backport-<B>-to-stable/N origin/stable/N && git cherry-pick -x <B's merge commit>`, push with
`--force-with-lease`, comment `/backport`).

If regenerating fails, the bot comments on the backport PR. If the change depends on spec the
stable branch doesn't have, it can't be backported as-is: close the backport PR, or reduce it
to what applies to the stable spec.

## Commit messages

Conventional Commits. Use `fix` only for user-facing bug fixes; use `chore`
for review-comment fix-ups and regeneration commits.

## Releases

`main` publishes **11.x-alpha** via semantic-release (Camunda 8.11 / next).
`stable/N` publishes `N.x` on the release channel. The workflow is
`.github/workflows/publish.yml`. It stamps
`runtime/source/camunda/version_.d` (never put a `"version"` in `dub.json`:
code.dlang.org takes versions from git tags and flags a declared one), tags `vX.Y.Z`, opens a GitHub Release, and pings
code.dlang.org when `DUB_REGISTRY_TOKEN` is set.

Release identity fails open: with Vault secrets (`VAULT_ADDR`, …) it pushes as
the `camunda-sdk-automation` app, which can bypass branch rulesets; without
them, or if Vault/the app token fails, it uses `GITHUB_TOKEN` and warns in the
run summary. Adding rulesets to `main`/`stable/*` requires the Vault secrets.

Set repo variable `CAMUNDA_SDK_CURRENT_STABLE_MAJOR` (same as the other SDKs)
so `stable/<that>` is the `latest` channel. First registry listing is a
one-time register of this GitHub repo on https://code.dlang.org.

## D conventions

- Synchronous API (libcurl), like the PHP SDK. No async runtime.
- Configuration via `CamundaClient.fromEnv` / `CamundaOptions.create.withKey`;
  options override environment, which overrides defaults.
- Errors are exceptions rooted at `CamundaException` (`ConfigException`,
  `AuthException`, `ApiException`, …).
- Semantic keys are distinct types. Do not collapse them back to `string`.
- Cadence (retry, poll, backpressure, OAuth refresh) goes through the injected
  `Clock`. Tests use `TestClock`.
- Bug fixes follow red/green: write the failing test first, scope it to the
  defect *class*, then apply the minimal fix.
- Never use `git commit -a` / `git add -A`. Stage explicit paths.
- Never use broad `pkill -f` / `killall`.
