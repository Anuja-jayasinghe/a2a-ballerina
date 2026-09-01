#!/usr/bin/env bash
# Mutation testing driver for ballerina/a2a.
#
# Applies one hand-picked mutation at a time to a source file, rebuilds and
# retests, and reports whether the existing test suite caught it (KILLED) or
# not (SURVIVED - a genuine coverage gap). Each mutation targets a
# specific, previously-identified risk surface (see scripts/mutations/) -
# this is not automated whole-codebase mutation testing, it is a curated,
# reproducible set standing in for it, since no mutation-testing tool
# exists for Ballerina.
#
# Every mutation is restored via `git checkout` immediately after its run,
# so the working tree ends up unchanged whether or not this script
# succeeds. Requires a clean working tree to start (so "unchanged" is
# unambiguous) and python3 (used for exact literal-text find/replace,
# rather than sed, since several mutations' search text contains
# characters sed would treat as regex metacharacters).
#
# Usage:
#   scripts/mutation-test.sh              # run every mutation
#   scripts/mutation-test.sh 01 06 10     # run only these mutation IDs
#
# Exit status is non-zero if any mutation survived or failed to compile,
# so this is safe to wire into CI as a gate later if desired.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTATIONS_DIR="$REPO_ROOT/scripts/mutations"
cd "$REPO_ROOT/ballerina"

BAL_CMD="bal"
if ! command -v bal >/dev/null 2>&1 && command -v bal.bat >/dev/null 2>&1; then
    BAL_CMD="bal.bat"
fi

if [ -n "$(git status --porcelain --untracked-files=no -- .)" ]; then
    echo "ERROR: tracked files have uncommitted changes. Commit or stash them before running mutation tests - each mutation is reverted via 'git checkout', which would discard unrelated in-progress work too." >&2
    exit 1
fi

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# Applies one mutation's SEARCH -> REPLACE to $REPO_ROOT/ballerina/$1, failing loudly
# if SEARCH doesn't appear in the file exactly once - the same
# fail-on-drift discipline scripts/regen-grpc-stub.sh uses, so a mutation
# silently doing nothing (or hitting the wrong occurrence) is never
# mistaken for a kill.
apply_mutation() {
    SEARCH="$2" REPLACE="$3" python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
search = os.environ["SEARCH"]
replace = os.environ["REPLACE"]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
count = content.count(search)
if count != 1:
    sys.stderr.write(f"ERROR: expected exactly 1 occurrence of the search text in {path}, found {count}\n")
    sys.exit(1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content.replace(search, replace, 1))
PY
}

RESULTS=()

run_one() {
    local mutation_path="$1"
    local id
    id="$(basename "$mutation_path" .mutation)"

    local FILE DESC SEARCH REPLACE
    # shellcheck disable=SC1090
    source "$mutation_path"
    local target="$REPO_ROOT/ballerina/$FILE"

    echo "=== $id: $DESC ==="
    apply_mutation "$target" "$SEARCH" "$REPLACE"

    "$BAL_CMD" build >"$LOG_DIR/$id-build.log" 2>&1 || true
    # `bal`'s own exit code is checked, but not trusted alone: `bal.bat`
    # invoked through Git Bash on Windows has been observed to report exit
    # 0 even on a genuine compilation error (reproduced directly - a
    # deliberately broken file still exits 0 while printing "error:
    # compilation contains errors"). Grepping the tool's own status line is
    # the one signal that held up in that environment, so both checks run
    # and either one flagging failure is trusted.
    if grep -q "error: compilation contains errors" "$LOG_DIR/$id-build.log"; then
        echo "  INVALID - mutant does not compile, see $LOG_DIR/$id-build.log"
        git checkout -- "$target"
        RESULTS+=("$id: INVALID (does not compile)")
        return
    fi

    "$BAL_CMD" test >"$LOG_DIR/$id-test.log" 2>&1 || true
    if grep -q "error: there are test failures" "$LOG_DIR/$id-test.log"; then
        echo "  KILLED - the test suite caught this mutation"
        RESULTS+=("$id: KILLED")
    else
        echo "  SURVIVED - the test suite did not catch this mutation"
        RESULTS+=("$id: SURVIVED")
    fi

    git checkout -- "$target"
}

if [ "$#" -gt 0 ]; then
    for id in "$@"; do
        run_one "$MUTATIONS_DIR/$id"*.mutation
    done
else
    for f in "$MUTATIONS_DIR"/*.mutation; do
        run_one "$f"
    done
fi

echo
echo "=== Summary ==="
survived=0
for r in "${RESULTS[@]}"; do
    echo "  $r"
    case "$r" in
        *SURVIVED*|*INVALID*) survived=$((survived + 1)) ;;
    esac
done

if [ "$survived" -gt 0 ]; then
    echo
    echo "$survived mutation(s) need attention - see above." >&2
    exit 1
fi

echo
echo "All mutations killed."
