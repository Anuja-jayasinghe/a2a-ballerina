#!/usr/bin/env bash
# Regenerates a2a/modules/grpcstub/a2a_pb.bal from a2a/proto/a2a.proto and
# checks whether the result matches what's checked in. Run with --apply to
# overwrite the checked-in file instead of just diffing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$REPO_ROOT/proto"
STUB_DIR="$REPO_ROOT/modules/grpcstub"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

echo "Regenerating gRPC stub from $PROTO_DIR/a2a.proto ..."
bal grpc --input "$PROTO_DIR/a2a.proto" --proto-path "$PROTO_DIR" --output "$SCRATCH_DIR"

GENERATED_FILE="$SCRATCH_DIR/a2a_pb.bal"
if [ ! -f "$GENERATED_FILE" ]; then
    echo "ERROR: bal grpc did not produce a2a_pb.bal at the expected path" >&2
    exit 1
fi

echo "Post-processing: rewriting google_protobuf_Value -> anydata ..."
OCCURRENCES=$(grep -o "google_protobuf_Value" "$GENERATED_FILE" | wc -l | tr -d ' ')
if [ "$OCCURRENCES" -ne 2 ]; then
    echo "ERROR: expected exactly 2 occurrences of google_protobuf_Value, found $OCCURRENCES." >&2
    echo "The bal grpc tool's output shape has changed — do not proceed with this rewrite." >&2
    exit 1
fi
sed -i 's/google_protobuf_Value/anydata/g' "$GENERATED_FILE"

if [ "${1:-}" = "--apply" ]; then
    cp "$GENERATED_FILE" "$STUB_DIR/a2a_pb.bal"
    echo "Applied. $STUB_DIR/a2a_pb.bal updated."
    exit 0
fi

if ! diff -q "$GENERATED_FILE" "$STUB_DIR/a2a_pb.bal" >/dev/null 2>&1; then
    echo "DRIFT DETECTED: regenerated stub differs from checked-in a2a_pb.bal." >&2
    diff "$STUB_DIR/a2a_pb.bal" "$GENERATED_FILE" || true
    exit 1
fi

echo "OK: checked-in stub matches regeneration from a2a.proto."
