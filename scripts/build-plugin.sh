#!/usr/bin/env bash
# Package a Cowork plugin source tree into a `.plugin` zip bundle.
# Usage: bash scripts/build-plugin.sh <plugin-dir> <output-dir>
#
# Produces <output-dir>/<plugin-name>.plugin where <plugin-name> comes
# from .claude-plugin/plugin.json.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <plugin-dir> <output-dir>" >&2
  exit 2
fi

PLUGIN_DIR="${1%/}"
OUTPUT_DIR="${2%/}"

if [[ ! -d "$PLUGIN_DIR" ]]; then
  echo "ERROR: plugin dir not found: $PLUGIN_DIR" >&2
  exit 2
fi

MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"
if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: missing $MANIFEST" >&2
  exit 2
fi

NAME=$(jq -r '.name' "$MANIFEST")
if [[ -z "$NAME" || "$NAME" == "null" ]]; then
  echo "ERROR: plugin.json has no 'name'" >&2
  exit 2
fi

VERSION=$(jq -r '.version // empty' "$MANIFEST")

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR_ABS=$(cd "$OUTPUT_DIR" && pwd)
OUT="$OUTPUT_DIR_ABS/${NAME}.plugin"
rm -f "$OUT"

echo "==> Packaging $NAME v${VERSION:-?}"
echo "    source: $PLUGIN_DIR"
echo "    output: $OUT"

# Zip from inside the plugin dir so entries are relative.
# Exclude OS noise and the legacy empty commands/ folder.
( cd "$PLUGIN_DIR" && zip -r -q "$OUT" . \
    -x "*.DS_Store" \
    -x "Thumbs.db" \
    -x "commands/*" \
    -x "commands/" )

SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")
echo "==> Wrote $OUT ($SIZE bytes)"

# Sanity check: re-read the manifest from inside the zip.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
unzip -qq "$OUT" -d "$TMPDIR"
if ! jq empty "$TMPDIR/.claude-plugin/plugin.json" 2>/dev/null; then
  echo "ERROR: packaged plugin.json is not valid JSON" >&2
  exit 1
fi

echo "==> Contents:"
unzip -l "$OUT"
