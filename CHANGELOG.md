# [10.3.0](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v10.2.2...v10.3.0) (2026-11-25)


### Features

* **runtime:** per-client curl-multi I/O engine (runtime-only backport of [#55](https://github.com/camunda/orchestration-cluster-api-dlang/issues/55) to stable/10) ([#57](https://github.com/camunda/orchestration-cluster-api-dlang/issues/57)) ([126a7a9](https://github.com/camunda/orchestration-cluster-api-dlang/commit/126a7a9975409fc19fbc9eb9ba747539f2fef529)), closes [#22](https://github.com/camunda/orchestration-cluster-api-dlang/issues/22) [#53](https://github.com/camunda/orchestration-cluster-api-dlang/issues/53) [#56](https://github.com/camunda/orchestration-cluster-api-dlang/issues/56) [22/#53](https://github.com/camunda/orchestration-cluster-api-dlang/issues/53) [#56](https://github.com/camunda/orchestration-cluster-api-dlang/issues/56)

## [10.2.2](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v10.2.1...v10.2.2) (2026-11-23)


### Bug Fixes

* do not gate job activation and job commands on backpressure ([#50](https://github.com/camunda/orchestration-cluster-api-dlang/issues/50)) ([#51](https://github.com/camunda/orchestration-cluster-api-dlang/issues/51)) ([1409736](https://github.com/camunda/orchestration-cluster-api-dlang/commit/140973686647b2716ea0fdb61e760b06d8a4b65d)), closes [#49](https://github.com/camunda/orchestration-cluster-api-dlang/issues/49) [#49](https://github.com/camunda/orchestration-cluster-api-dlang/issues/49)

## [10.2.1](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v10.2.0...v10.2.1) (2026-11-21)


### Bug Fixes

* **gen:** regenerate artifacts ([66f72d7](https://github.com/camunda/orchestration-cluster-api-dlang/commit/66f72d75baeea8ad89e02e35512fb1fdac4d7be8))
* send the default tenant (<default> unless configured) on tenant-scoped commands ([#39](https://github.com/camunda/orchestration-cluster-api-dlang/issues/39)) ([37c72ff](https://github.com/camunda/orchestration-cluster-api-dlang/commit/37c72ffc5732c1f02b59a1d2ffa64eae86dbb44e)), closes [#38](https://github.com/camunda/orchestration-cluster-api-dlang/issues/38)

# [10.2.0](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v10.1.1...v10.2.0) (2026-11-14)


### Features

* **runtime:** custom HTTP headers on every request (backport to stable/10) ([#17](https://github.com/camunda/orchestration-cluster-api-dlang/issues/17)) ([29b576d](https://github.com/camunda/orchestration-cluster-api-dlang/commit/29b576d5d28b22ddd2a434da84b7c6008d2ef393)), closes [#12](https://github.com/camunda/orchestration-cluster-api-dlang/issues/12) [#11](https://github.com/camunda/orchestration-cluster-api-dlang/issues/11)

## [10.1.1](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v10.1.0...v10.1.1) (2026-11-14)


### Bug Fixes

* **release:** drop the version field from dub.json ([aad111d](https://github.com/camunda/orchestration-cluster-api-dlang/commit/aad111dd272dcf1c3d92fe1ed750cead53024c50))

# [10.1.0](https://github.com/camunda/orchestration-cluster-api-dlang/compare/v10.0.0...v10.1.0) (2026-11-13)


### Bug Fixes

* apply the default tenant to every request with an optional tenantId ([1bc5bfc](https://github.com/camunda/orchestration-cluster-api-dlang/commit/1bc5bfcc4eeaad0b116baa0eca444d98af219b05)), closes [#8](https://github.com/camunda/orchestration-cluster-api-dlang/issues/8)
* **http:** send bodies with their Content-Type; PUT/PATCH bodies; no Content-Type without a body ([1d4b3c4](https://github.com/camunda/orchestration-cluster-api-dlang/commit/1d4b3c4653c3ba70e792c6f893c3f7a8beca71d2)), closes [#5](https://github.com/camunda/orchestration-cluster-api-dlang/issues/5)
* resolve cluster-admin operations against the bare root server ([236fc77](https://github.com/camunda/orchestration-cluster-api-dlang/commit/236fc771505b4ceaf38d1bcf8e4fad25744f1da9)), closes [#6](https://github.com/camunda/orchestration-cluster-api-dlang/issues/6)


### Features

* multipart createDocument/createDocuments with a shared multipart builder ([afaece0](https://github.com/camunda/orchestration-cluster-api-dlang/commit/afaece0b85b2c1b362e19444c984e9502a6c8cb0)), closes [#7](https://github.com/camunda/orchestration-cluster-api-dlang/issues/7)
