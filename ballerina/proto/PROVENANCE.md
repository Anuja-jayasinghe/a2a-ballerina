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

## Post-processing applied to the generated stub

The vendored proto above is fed to `bal grpc` unchanged, but the file it
emits (`ballerina/modules/grpcstub/a2a_pb.bal`) gets two scripted, asserted
rewrites before it is checked in. Both are applied by
`scripts/regen-grpc-stub.sh`, which fails loudly if either stops
matching the expected number of occurrences.

1. **`google_protobuf_Value` → `anydata`** (2 occurrences: the `Part.data`
   field declaration and the `setPart_Data` helper). `bal grpc` has no
   mapping for a field typed directly `google.protobuf.Value` and emits a
   reference to a type it never defines. `anydata` is not an arbitrary
   stand-in: it is exactly how `ballerina/grpc`'s runtime already
   represents a `google.protobuf.Value`, since the values inside a
   `google.protobuf.Struct`'s field map are `Value`s and those surface as
   the `anydata` values of the `map<anydata>` the tool generates for
   `Struct`.
2. **`initStub(self, A2A_DESC)` → `initStub(self, A2A_DESC,
   A2A_DESCRIPTOR_MAP)`** (1 occurrence). `bal grpc` emits no dependency
   descriptor map, so a2a.proto's `google/protobuf/struct.proto`
   dependency was never resolved and every `google.protobuf.*` type
   degraded to a protobuf *placeholder* descriptor. That is survivable for
   `Struct`/`Empty`/`Timestamp` (ballerina/grpc's `StandardDescriptorBuilder`
   re-resolves those by message name) but fatal for `google.protobuf.Value`,
   which has no entry in that table — `Part.data` failed at runtime with
   `"Failed to frame message: ... because fileDescriptor is null"`.

`A2A_DESCRIPTOR_MAP` and the `google/protobuf/struct.proto` descriptor it
carries live in `ballerina/modules/grpcstub/wellknown_desc.bal`, a **hand-maintained**
companion file that the regeneration script neither generates nor overwrites.
That file documents the failure mode and the descriptor's own provenance in
full. It tracks the protobuf well-known types, not the A2A spec, so it does
not need revisiting when `a2a.proto` moves.

## Regenerating

Run `scripts/regen-grpc-stub.sh` from the repo root. It re-derives the
stub from this vendored proto and fails (with a diff) if the checked-in
`ballerina/modules/grpcstub/a2a_pb.bal` would change — review the diff, decide
whether it's expected (spec moved) or a regression, and re-run with
`--apply` to accept it.

If the upstream proto changes, re-run Step 1 above to refresh both this
file and `a2a.upstream.proto`, then manually re-apply the four strip rules
to produce a new vendored `a2a.proto`, then run the regen script.
