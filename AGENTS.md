# AGENTS.md

> This repo follows the central Camunda AGENTS guidelines:
> https://raw.githubusercontent.com/camunda/.github/refs/heads/main/AGENTS.md
> The instructions below extend those and take precedence on conflict.

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
| `source/camunda/` | Hand-written runtime: config, auth, HTTP, retry, clock, backpressure, eventual, worker, client. **Primary edit surface.** |
| `source/camunda/safeio.d` | The `@trusted` C-boundary. Review like Rust `unsafe`. |
| `source/camunda/generated/` | **Generated.** Produced by `make generate`. Never hand-edit. |
| `scripts/generate.py` | Numbered generation hooks (01 keys … 06 markdown docs). **Primary edit surface** for generated output. |
| `scripts/sync-readme-snippets.py` | Injects `examples/*.d` region snippets into `README.md`. `--check` is the CI gate. |
| `docs/` | **Generated.** `api-reference.md` and `semantic-types.md`. Never hand-edit. |
| `scripts/check-safe.sh` | `@safe` / `@trusted` / isolation ratchet. Runs as a dub `preBuildCommands` hook. |
| `external-spec/bundled/` | Bundled OpenAPI spec + `spec-metadata.json`. Generator inputs. |
| `examples/` | Compilable usage examples. `examples/readme.d` hosts region-tagged snippets for the README. |

## Generation pipeline

```bash
make generate    # regenerate source/camunda/generated/ and docs/ from the bundled spec
```

`scripts/generate.py` reads `external-spec/bundled/rest-api.bundle.json` and
`spec-metadata.json` and emits:

1. `keys.d` — Camunda Domain Type System (nominal newtypes with `tryNew` / `assumeExists`).
2. `enums.d` — every OpenAPI string enum.
3. `models.d` — JSON-backed request/response structs, one per schema.
4. `operations.d` — `mixin template GeneratedOperations()`: one method per REST operation.
5. `package.d` — public re-exports + `generatedSpecHash` / `generatedOperationCount`.
6. `docs/api-reference.md` and `docs/semantic-types.md`.
7. `examples/<tag>.d` + `examples/operation-map.json` — one compilable region per REST operation.

To pick up a newer spec, copy the JS SDK's `external-spec/bundled/` files in and
re-run `make generate`. Do **not** hand-edit `source/camunda/generated/`, `docs/`,
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
make check       # full local CI gate
```

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

When a change modifies `scripts/generate.py` **and** that change alters
`source/camunda/generated/` or `docs/`, split into two commits:

1. Generator change only. No `source/camunda/generated/` changes.
2. `chore(gen): regenerate for <summary>` — the regenerated output.

## Commit messages

Conventional Commits. Use `fix` only for user-facing bug fixes; use `chore`
for review-comment fix-ups and regeneration commits.

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
