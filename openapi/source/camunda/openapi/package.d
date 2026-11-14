/// Hardened, Phobos-only OpenAPI reader shared by `scripts/generate.d` and
/// d8ctl: an order-preserving JSON parser, a spec model, and `$ref` / `allOf`
/// resolution with schema flattening.
module camunda.openapi;

@safe:

public import camunda.openapi.errors;
public import camunda.openapi.json;
public import camunda.openapi.spec;
