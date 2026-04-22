#!/usr/bin/env bash
# Package a skills-only Cowork plugin variant from the full plugin source.
# Usage: bash scripts/build-cowork-plugin.sh <plugin-dir> <output-dir>
#
# Produces <output-dir>/origo-bc-cowork.plugin containing ONLY the skills
# that are useful when Cowork provides its own MCP connection (no setup
# wizard or stdio-proxy scripts). The manifest is read from
# .claude-plugin/plugin.cowork.json.
#
# Skills included (hardcoded — update this list when adding new
# knowledge-only skills):
COWORK_SKILLS=(
  "origo-bc-accounting"
  "origo-bc-cloud-events"
)

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

COWORK_MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.cowork.json"
if [[ ! -f "$COWORK_MANIFEST" ]]; then
  echo "ERROR: missing $COWORK_MANIFEST" >&2
  exit 2
fi

NAME=$(jq -r '.name' "$COWORK_MANIFEST")
VERSION=$(jq -r '.version // empty' "$COWORK_MANIFEST")

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR_ABS=$(cd "$OUTPUT_DIR" && pwd)
OUT="$OUTPUT_DIR_ABS/${NAME}-cowork.plugin"
rm -f "$OUT"

echo "==> Packaging ${NAME}-cowork (skills-only) v${VERSION:-?}"
echo "    source: $PLUGIN_DIR"
echo "    output: $OUT"

# Build in a temp directory with just the pieces we need.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# 1. Plugin manifest — rename the cowork variant to the standard filename.
mkdir -p "$TMPDIR/.claude-plugin"
cp "$COWORK_MANIFEST" "$TMPDIR/.claude-plugin/plugin.json"

# 2. Copy only the designated skills.
mkdir -p "$TMPDIR/skills"
for skill in "${COWORK_SKILLS[@]}"; do
  SKILL_SRC="$PLUGIN_DIR/skills/$skill"
  if [[ ! -d "$SKILL_SRC" ]]; then
    echo "ERROR: skill directory not found: $SKILL_SRC" >&2
    exit 1
  fi
  cp -r "$SKILL_SRC" "$TMPDIR/skills/$skill"
  echo "    + skill: $skill"
done

# 3. Zip it up.
( cd "$TMPDIR" && zip -r -q "$OUT" . \
    -x "*.DS_Store" \
    -x "Thumbs.db" )

SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")
echo "==> Wrote $OUT ($SIZE bytes)"

# Sanity check: re-read the manifest from inside the zip.
CHECKDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR" "$CHECKDIR"' EXIT
unzip -qq "$OUT" -d "$CHECKDIR"
if ! jq empty "$CHECKDIR/.claude-plugin/plugin.json" 2>/dev/null; then
  echo "ERROR: packaged plugin.json is not valid JSON" >&2
  exit 1
fi

echo "==> Contents:"
unzip -l "$OUT"
