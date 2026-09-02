_Authors_: @Anuja-jayasinghe \
_Created_: 2026/08/01 \
_Updated_: 2026/09/02 \
_Edition_: Swan Lake

# Sanitation for A2A protocol buffer specification

This document records the sanitation done on top of the official A2A protocol
buffer specification, so that `bal grpc` can generate a working client stub
from it. The specification is obtained from
[`a2aproject/A2A`](https://github.com/a2aproject/A2A)'s
`specification/a2a.proto`, at blob SHA `2814f0f9a8a3db0fa1976dd4aece8ce38700a0bf`
(commit `cfc9d34bc41e368827eb6446d31f912e44f795c5`), fetched 2026-08-01.
Unlike a typical OpenAPI sanitation, none of these changes touch the
protocol's actual shape (message fields, RPC signatures) — they only remove
annotations `bal grpc` cannot resolve and does not read for anything else,
so the vendored copy is semantically identical to upstream on the wire.

1. **Remove the three `google/api/*` imports**:
   - **Original**: `import "google/api/annotations.proto";`,
     `import "google/api/client.proto";`,
     `import "google/api/field_behavior.proto";`
   - **Updated**: removed entirely.
   - **Reason**: `bal grpc` cannot resolve these imports without also
     vendoring `googleapis/googleapis`, and doing so does not actually fix
     codegen either — it still emits references to constants the tool never
     generates (see the design doc's own findings on this).

2. **Remove every `option (google.api.http) = { ... };` block on an rpc**:
   - **Original**: each rpc declares an HTTP-transcoding annotation, e.g.
     `option (google.api.http) = { post: "/message:send" body: "*" };`.
   - **Updated**: removed from every rpc.
   - **Reason**: HTTP-transcoding metadata only — contributes nothing to the
     gRPC wire format or to the types `bal grpc` generates.

3. **Remove every `[(google.api.method_signature) = "..."]` annotation**:
   - **Original**: present on several rpc/field declarations.
   - **Updated**: removed.
   - **Reason**: documentation-only annotation, not read by `bal grpc`.

4. **Remove every `[(google.api.field_behavior) = ...]` field annotation**:
   - **Original**: present on fields the spec marks `REQUIRED`/`OPTIONAL`.
   - **Updated**: removed.
   - **Reason**: same as above — not read by `bal grpc` for anything but the
     fields already covered by rules 1-3.

## Additional post-processing applied to the generated stub

The four sanitations above apply to the vendored `.proto` file itself,
before it ever reaches `bal grpc`. Separately, `scripts/regen-grpc-stub.sh`
also applies three scripted, asserted rewrites to the file `bal grpc`
*generates* (`ballerina/modules/grpcstub/a2a_pb.bal`) — these aren't
sanitation of the input specification in the sense the rest of this
document covers, so they're kept in their own section rather than folded
into the numbered list above. Each fails loudly (wrong occurrence count) if
`bal grpc`'s own output shape ever changes underneath it:

1. **`google_protobuf_Value` → `anydata`** (2 occurrences: the `Part.data`
   field declaration and the `setPart_Data` helper). `bal grpc` has no
   mapping for a field typed directly `google.protobuf.Value` and emits a
   reference to a type it never defines. `anydata` is exactly how
   `ballerina/grpc`'s own runtime already represents a
   `google.protobuf.Value` — the values inside a `google.protobuf.Struct`'s
   field map are `Value`s, and those surface as the `anydata` values of the
   `map<anydata>` the tool generates for `Struct`.
2. **`initStub(self, A2A_DESC)` → `initStub(self, A2A_DESC, A2A_DESCRIPTOR_MAP)`**
   (1 occurrence). `bal grpc` emits no dependency descriptor map, so
   `a2a.proto`'s `google/protobuf/struct.proto` dependency is never
   resolved and every `google.protobuf.*` type degrades to a protobuf
   *placeholder* descriptor. Survivable for `Struct`/`Empty`/`Timestamp`
   (`ballerina/grpc`'s `StandardDescriptorBuilder` re-resolves those by
   message name) but fatal for `google.protobuf.Value`, which has no entry
   in that table — `Part.data` failed at runtime with `"Failed to frame
   message: ... because fileDescriptor is null"`. `A2A_DESCRIPTOR_MAP` and
   the `google/protobuf/struct.proto` descriptor it carries live in
   `ballerina/modules/grpcstub/wellknown_desc.bal`, a **hand-maintained**
   companion file the regeneration script neither generates nor overwrites.
3. **Prepend the Apache-2.0 license header**. `bal grpc` emits no header at
   all, unlike every other `.bal` file in this repo. Prepended by the
   script rather than hand-edited into the checked-in file, since a
   hand-added header would be silently wiped by the next `--apply` run.

## `bal grpc` CLI command

The following command is what `scripts/regen-grpc-stub.sh` runs to
regenerate the stub from the vendored proto (paths relative to the repo
root):

```bash
bal grpc --input ballerina/proto/a2a.proto --proto-path ballerina/proto --output <output-dir>
```

In practice, always run `scripts/regen-grpc-stub.sh` itself rather than this
command directly — it also applies the three post-processing rewrites above,
diffs the result against the checked-in stub, and only overwrites it when
run with `--apply`.

## Regenerating

Run `scripts/regen-grpc-stub.sh` from the repo root. It re-derives the stub
from this vendored proto and fails (with a diff) if the checked-in
`ballerina/modules/grpcstub/a2a_pb.bal` would change — review the diff,
decide whether it's expected (spec moved) or a regression, and re-run with
`--apply` to accept it.

If the upstream proto changes, re-fetch it and refresh the blob/commit SHAs
above, then manually re-apply the four sanitations to produce a new vendored
`a2a.proto`, then run the regen script.
