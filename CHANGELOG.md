# [11.0.0-alpha.15](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.14...v11.0.0-alpha.15) (2026-11-23)


### Bug Fixes

* do not gate job activation and job commands on backpressure ([#50](https://github.com/camunda/orchestration-cluster-api-dlang/issues/50)) ([2cd8c69](https://github.com/camunda/orchestration-cluster-api-dlang/commit/2cd8c693a7a84e51cea17d8545e2109e6fdafb9c)), closes [#49](https://github.com/camunda/orchestration-cluster-api-dlang/issues/49) [#49](https://github.com/camunda/orchestration-cluster-api-dlang/issues/49)

# [11.0.0-alpha.14](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.13...v11.0.0-alpha.14) (2026-11-22)


### Features

* **gen:** honour optionalTenantIdInBody from bundler 2.5.1 metadata ([#48](https://github.com/camunda/orchestration-cluster-api-dlang/issues/48)) ([10628b0](https://github.com/camunda/orchestration-cluster-api-dlang/commit/10628b08b33e07a0b734baf9c8dacf25660b748f)), closes [#40](https://github.com/camunda/orchestration-cluster-api-dlang/issues/40)

# [11.0.0-alpha.13](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.12...v11.0.0-alpha.13) (2026-11-21)


### Bug Fixes

* **gen:** derive default-tenant injection from the body shape ([#37](https://github.com/camunda/orchestration-cluster-api-dlang/issues/37)) ([e1228e7](https://github.com/camunda/orchestration-cluster-api-dlang/commit/e1228e797e18791df185d101ba351ce5d3b5bbab)), closes [#36](https://github.com/camunda/orchestration-cluster-api-dlang/issues/36)
* **gen:** regenerate artifacts ([a336a37](https://github.com/camunda/orchestration-cluster-api-dlang/commit/a336a373a40f5fb2fbf73a7b4d959dcb419d2c87))

# [11.0.0-alpha.12](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.11...v11.0.0-alpha.12) (2026-11-20)


### Bug Fixes

* **runtime:** keep PKCS[#12](https://github.com/camunda/orchestration-cluster-api-dlang/issues/12) keys in SDK-owned containers on Windows ([#35](https://github.com/camunda/orchestration-cluster-api-dlang/issues/35)) ([6b5544d](https://github.com/camunda/orchestration-cluster-api-dlang/commit/6b5544dce6de132ec9b1532dac0d632be7799eee)), closes [#32](https://github.com/camunda/orchestration-cluster-api-dlang/issues/32) [PKCS#8](https://github.com/PKCS/issues/8) [#34](https://github.com/camunda/orchestration-cluster-api-dlang/issues/34)

# [11.0.0-alpha.11](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.10...v11.0.0-alpha.11) (2026-11-20)


### Bug Fixes

* **gen:** regenerate artifacts ([1da6bb8](https://github.com/camunda/orchestration-cluster-api-dlang/commit/1da6bb82b0b03f21b08a67f67db6aec224b09f77))

# [11.0.0-alpha.10](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.9...v11.0.0-alpha.10) (2026-11-19)


### Features

* **runtime:** custom CA, revocation and mTLS on WinHTTP ([#28](https://github.com/camunda/orchestration-cluster-api-dlang/issues/28) phase 3) ([#32](https://github.com/camunda/orchestration-cluster-api-dlang/issues/32)) ([e77d470](https://github.com/camunda/orchestration-cluster-api-dlang/commit/e77d470da3b6a17b317d3fe4c3d7806a13134d1f)), closes [PKCS#8](https://github.com/PKCS/issues/8) [PKCS#12](https://github.com/PKCS/issues/12) [PKCS#12](https://github.com/PKCS/issues/12) [PKCS#1](https://github.com/PKCS/issues/1) [PKCS#8](https://github.com/PKCS/issues/8) [PKCS#1](https://github.com/PKCS/issues/1) [PKCS#1](https://github.com/PKCS/issues/1) [PKCS#12](https://github.com/PKCS/issues/12) [PKCS#12](https://github.com/PKCS/issues/12) [PKCS#12](https://github.com/PKCS/issues/12) [PKCS#8](https://github.com/PKCS/issues/8) [PKCS#12](https://github.com/PKCS/issues/12) [PKCS#12](https://github.com/PKCS/issues/12)

# [11.0.0-alpha.9](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.8...v11.0.0-alpha.9) (2026-11-19)


### Bug Fixes

* **runtime:** honour inline mTLS PEM (CAMUNDA_MTLS_CA/CERT/KEY) ([#31](https://github.com/camunda/orchestration-cluster-api-dlang/issues/31)) ([ce8ba2b](https://github.com/camunda/orchestration-cluster-api-dlang/commit/ce8ba2bb9b0be16fc01d404a53f90ae6b55b905d)), closes [#28](https://github.com/camunda/orchestration-cluster-api-dlang/issues/28)

# [11.0.0-alpha.8](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v11.0.0-alpha.7...v11.0.0-alpha.8) (2026-11-19)


### Features

* **runtime:** native WinHTTP backend on Windows ([#29](https://github.com/camunda/orchestration-cluster-api-dlang/issues/29)) ([5567097](https://github.com/camunda/orchestration-cluster-api-dlang/commit/55670970acd197b3e8494203fcc8f47a9f82ff4a))

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
