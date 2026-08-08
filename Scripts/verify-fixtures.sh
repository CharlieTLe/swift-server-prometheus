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

if diff -ru "$TMP/committed" "$ROOT/Fixtures" > "$TMP/diff.txt" 2>&1; then
  echo "fixtures up to date"
  exit 0
fi

echo "error: committed fixtures differ from freshly generated ones" >&2
echo >&2
head -100 "$TMP/diff.txt" >&2
echo >&2
echo "If upstream moved, update docs/PORTING.md's pin and review the diff deliberately." >&2
exit 1
