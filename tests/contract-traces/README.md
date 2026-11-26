# Camunda_Contract golden traces (vendored)

Copied unchanged from
https://github.com/camunda/orchestration-cluster-api-ada/tree/52cd13f40a92a0b70fcd15ecfc6b7347d86e3139/spec
(`spec/traces/*.json` and `spec/schema.json`). Do not edit them by hand: they
are generated from the SPARK-proved `Camunda_Contract` package. To update,
copy the files from a newer commit of that repository and update the link.

`source/camunda/contract_traces.d` replays every case against
`camunda.contract` in `dub test` (string imports: no file I/O, no GNAT).
