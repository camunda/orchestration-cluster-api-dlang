// The shared camunda/sdk-infra commitlint workflow (@v1) runs commitlint without a
// config of its own, so the calling repo must provide one or every commit fails
// with `empty-rules`.
module.exports = { extends: ['@commitlint/config-conventional'] };
