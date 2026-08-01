# a2a.proto provenance

- Upstream repo: `a2aproject/A2A`
- Upstream path: `specification/a2a.proto`
- Blob SHA: `2814f0f9a8a3db0fa1976dd4aece8ce38700a0bf`
- Last-touching commit SHA: `cfc9d34bc41e368827eb6446d31f912e44f795c5`
- Fetched: `2026-08-01`

## Strip rules applied to produce the vendored copy

The vendored `a2a.proto` in this directory is **not** byte-identical to the
upstream file. The following are removed, and only these:

1. The three imports `google/api/annotations.proto`,
   `google/api/client.proto`, `google/api/field_behavior.proto`.
2. Every `option (google.api.http) = { ... };` block on an rpc.
3. Every `[(google.api.method_signature) = "..."]` field/rpc annotation.
4. Every `[(google.api.field_behavior) = ...]` field annotation.

These are HTTP-transcoding and documentation annotations only — they
contribute nothing to the gRPC wire format or to the generated Ballerina
types (`bal grpc` does not read them for anything but the fields removed
above). Stripping them is required because `bal grpc` cannot resolve the
`google/api/*` imports without vendoring `googleapis/googleapis` as well,
and doing so does not actually fix codegen (see the design spec's Finding 2,
Defect A) — it still emits references to constants the tool never
generates.

## Regenerating

Run `a2a/scripts/regen-grpc-stub.sh` from the repo root. It re-derives the
stub from this vendored proto and fails (with a diff) if the checked-in
`a2a/modules/grpcstub/a2a_pb.bal` would change — review the diff, decide
whether it's expected (spec moved) or a regression, and re-run with
`--apply` to accept it.

If the upstream proto changes, re-run Step 1 above to refresh both this
file and `a2a.upstream.proto`, then manually re-apply the four strip rules
to produce a new vendored `a2a.proto`, then run the regen script.
