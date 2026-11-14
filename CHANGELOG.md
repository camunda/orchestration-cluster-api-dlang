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
