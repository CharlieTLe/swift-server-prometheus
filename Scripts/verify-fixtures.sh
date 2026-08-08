#!/usr/bin/env bash
# Verify committed fixtures still match what the Go oracle produces.
#
# Run in CI (where Go is available) and on every upstream-pin bump. A diff here
# means either the port's contract changed or upstream drifted — both need a
# human decision, never a silent regeneration.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cp -R "$ROOT/Fixtures" "$TMP/committed"
"$ROOT/Scripts/regen-fixtures.sh" >/dev/null

# Compare everything except MANIFEST.json, whose `goVersion` records the
# generating toolchain for provenance and legitimately differs between machines.
# The fixture bytes are the contract; MANIFEST's `files` block (path + sha256 +
# line count) is checked separately below, so content drift is still caught twice.
if ! diff -ru -x MANIFEST.json "$TMP/committed" "$ROOT/Fixtures" > "$TMP/diff.txt" 2>&1; then
  echo "error: committed fixtures differ from freshly generated ones" >&2
  echo >&2
  head -100 "$TMP/diff.txt" >&2
  echo >&2
  echo "If upstream moved, update docs/PORTING.md's pin and review the diff deliberately." >&2
  exit 1
fi

# The manifest's file list must agree; its toolchain fields need not.
manifest_files() {
  sed -n '/"files"/,$p' "$1"
}
if ! diff -u <(manifest_files "$TMP/committed/MANIFEST.json") \
             <(manifest_files "$ROOT/Fixtures/MANIFEST.json") > "$TMP/manifest.txt" 2>&1; then
  echo "error: MANIFEST.json file list differs" >&2
  head -60 "$TMP/manifest.txt" >&2
  exit 1
fi

# Report a toolchain change rather than failing on it: Go's output for these
# suites is stable across versions, and a difference here is information, not an
# error. If it ever coincides with a content diff, the checks above will fail.
committed_go=$(sed -n 's/.*"goVersion": "\(.*\)".*/\1/p' "$TMP/committed/MANIFEST.json")
current_go=$(sed -n 's/.*"goVersion": "\(.*\)".*/\1/p' "$ROOT/Fixtures/MANIFEST.json")
if [[ "$committed_go" != "$current_go" ]]; then
  echo "note: fixtures were committed with $committed_go, verified with $current_go" >&2
  echo "      content is identical, so the difference is benign." >&2
  # Restore the committed manifest so the working tree stays clean.
  cp "$TMP/committed/MANIFEST.json" "$ROOT/Fixtures/MANIFEST.json"
fi

echo "fixtures up to date"
