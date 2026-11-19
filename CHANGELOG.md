# [11.0.0-alpha.7](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.6...v11.0.0-alpha.7) (2026-11-19)


### Bug Fixes

* **gen:** regenerate artifacts ([4f156e5](https://github.com/camunda/orchestration-cluster-api-dlang/commit/4f156e5b12379614706c276c455bfcf5f9e618a5))
* **runtime:** link libcurl on POSIX only; test on Windows ([#27](https://github.com/camunda/orchestration-cluster-api-dlang/issues/27)) ([cc9e087](https://github.com/camunda/orchestration-cluster-api-dlang/commit/cc9e0873fb564f1af6ef66be0c7e4e8cebd98413))

# [11.0.0-alpha.6](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.5...v11.0.0-alpha.6) (2026-11-16)


* feat!: concurrent job worker, thread-safe client, keep-alive HTTP ([#22](https://github.com/camunda/orchestration-cluster-api-dlang/issues/22)) ([8810347](https://github.com/camunda/orchestration-cluster-api-dlang/commit/88103473093a033d0793d71ca378e5c515b1fbc1))


### BREAKING CHANGES

* JobWorkerConfig.maxJobsToActivate is renamed
maxJobsActive and now caps jobs in flight; JobWorker.pollOnce is removed;
run takes a `JobAction function(Job)` (or function plus sendable context)
instead of a delegate, and runs it on several threads at once;
JobWorkerConfig numeric/name fields default to 0/null (unset) and are
resolved when the worker is created.

* docs: per-thread file descriptors and the macOS select() limit

# [11.0.0-alpha.5](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.4...v11.0.0-alpha.5) (2026-11-15)


### Bug Fixes

* send the default tenant (<default> unless configured) on tenant-scoped commands ([#16](https://github.com/camunda/orchestration-cluster-api-dlang/issues/16)) ([9f9e44f](https://github.com/camunda/orchestration-cluster-api-dlang/commit/9f9e44fa4190c044e3b6afdfdfb5e99212258ad4)), closes [#14](https://github.com/camunda/orchestration-cluster-api-dlang/issues/14) [#10](https://github.com/camunda/orchestration-cluster-api-dlang/issues/10)

# [11.0.0-alpha.4](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.3...v11.0.0-alpha.4) (2026-11-14)


### Features

* **openapi:** add :openapi subpackage, a hardened OpenAPI reader ([#19](https://github.com/camunda/orchestration-cluster-api-dlang/issues/19)) ([b2946ef](https://github.com/camunda/orchestration-cluster-api-dlang/commit/b2946ef4aeecd36b422a4c82d73827d23447e0bb)), closes [#15](https://github.com/camunda/orchestration-cluster-api-dlang/issues/15)

# [11.0.0-alpha.3](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.2...v11.0.0-alpha.3) (2026-11-14)


### Features

* **runtime:** custom HTTP headers on every request ([#12](https://github.com/camunda/orchestration-cluster-api-dlang/issues/12)) ([8d57e09](https://github.com/camunda/orchestration-cluster-api-dlang/commit/8d57e09b1c0be18811068aa5aeb63c35b538ef95)), closes [#11](https://github.com/camunda/orchestration-cluster-api-dlang/issues/11)

# [11.0.0-alpha.2](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.1...v11.0.0-alpha.2) (2026-11-14)


### Bug Fixes

* **release:** drop the version field from dub.json ([a6cef14](https://github.com/camunda/orchestration-cluster-api-dlang/commit/a6cef14d524f4909a9a3258b697bf23d5a0a4544))

# [11.0.0-alpha.1](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.0...v11.0.0-alpha.1) (2026-11-13)


### Bug Fixes

* apply the default tenant to every request with an optional tenantId ([0c3a6e9](https://github.com/camunda/orchestration-cluster-api-dlang/commit/0c3a6e908a60ad0d3a6bffc5ce68bb94188ac5eb)), closes [#8](https://github.com/camunda/orchestration-cluster-api-dlang/issues/8)
* **http:** send bodies with their Content-Type; PUT/PATCH bodies; no Content-Type without a body ([cd54283](https://github.com/camunda/orchestration-cluster-api-dlang/commit/cd54283ddfb1f502590d8842f4fb520dd45a1e5a)), closes [#5](https://github.com/camunda/orchestration-cluster-api-dlang/issues/5)
* resolve cluster-admin operations against the bare root server ([63ff834](https://github.com/camunda/orchestration-cluster-api-dlang/commit/63ff834fdbf9e8cd9a33c4d73d4162d4b92345ff)), closes [#6](https://github.com/camunda/orchestration-cluster-api-dlang/issues/6)


### Features

* multipart createDocument/createDocuments with a shared multipart builder ([b5ddb1d](https://github.com/camunda/orchestration-cluster-api-dlang/commit/b5ddb1d0309fc97f603ade70936128ce268eff76)), closes [#7](https://github.com/camunda/orchestration-cluster-api-dlang/issues/7)
