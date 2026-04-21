#!/usr/bin/env bash
# Validate a Cowork plugin source tree before packaging.
# Usage: bash scripts/validate-plugin.sh <plugin-dir>
#
# Exits non-zero with a machine-readable error list if anything is wrong.
# Designed to run the same way locally and in Azure Pipelines.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <plugin-dir>" >&2
  exit 2
fi

PLUGIN_DIR="${1%/}"

if [[ ! -d "$PLUGIN_DIR" ]]; then
  echo "ERROR: plugin dir not found: $PLUGIN_DIR" >&2
  exit 2
fi

ERRORS=()
warn() { echo "WARN : $*"; }
err()  { ERRORS+=("$*"); echo "ERROR: $*"; }

echo "==> Validating $PLUGIN_DIR"

# 1. .claude-plugin/plugin.json exists, is valid JSON, has a kebab-case name
MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"
if [[ ! -f "$MANIFEST" ]]; then
  err "missing $MANIFEST"
else
  if ! jq empty "$MANIFEST" 2>/dev/null; then
    err "$MANIFEST is not valid JSON"
  else
    NAME=$(jq -r '.name // empty' "$MANIFEST")
    VERSION=$(jq -r '.version // empty' "$MANIFEST")
    if [[ -z "$NAME" ]]; then
      err "plugin.json missing 'name'"
    elif [[ ! "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      err "plugin.json 'name' not kebab-case: $NAME"
    else
      echo "  plugin name    : $NAME"
    fi
    if [[ -z "$VERSION" ]]; then
      warn "plugin.json missing 'version' (will default)"
    else
      echo "  plugin version : $VERSION"
      if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
        err "plugin.json 'version' is not semver: $VERSION"
      fi
    fi
  fi
fi

# 2. Each skills/*/ subdirectory must contain a SKILL.md with YAML frontmatter
SKILLS_DIR="$PLUGIN_DIR/skills"
if [[ -d "$SKILLS_DIR" ]]; then
  shopt -s nullglob
  for d in "$SKILLS_DIR"/*/; do
    SKILL_NAME=$(basename "$d")
    SKILL_FILE="$d/SKILL.md"
    if [[ ! -f "$SKILL_FILE" ]]; then
      err "skill $SKILL_NAME: missing SKILL.md"
      continue
    fi
    # Must begin with '---' frontmatter delimiter
    if [[ "$(head -n1 "$SKILL_FILE")" != "---" ]]; then
      err "skill $SKILL_NAME: SKILL.md missing YAML frontmatter (no leading '---')"
      continue
    fi
    # Extract frontmatter block (between first two '---' lines)
    FM=$(awk '/^---$/{n++; next} n==1{print} n==2{exit}' "$SKILL_FILE")
    if ! echo "$FM" | grep -q '^name:'; then
      err "skill $SKILL_NAME: frontmatter missing 'name'"
    fi
    if ! echo "$FM" | grep -q '^description:'; then
      err "skill $SKILL_NAME: frontmatter missing 'description'"
    fi
    echo "  skill OK       : $SKILL_NAME"
  done
fi

# 3. Bundled scripts must be present and parseable
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
if [[ -d "$SCRIPTS_DIR" ]]; then
  for f in "$SCRIPTS_DIR"/*.js; do
    [[ -e "$f" ]] || continue
    if ! node --check "$f" 2>/dev/null; then
      err "script has a syntax error: $f"
    else
      echo "  js syntax OK   : $(basename "$f")"
    fi
  done
  # We can't parse PowerShell without PowerShell, but at least check non-empty
  for f in "$SCRIPTS_DIR"/*.ps1; do
    [[ -e "$f" ]] || continue
    if [[ ! -s "$f" ]]; then
      err "script is empty: $f"
    else
      echo "  ps1 present    : $(basename "$f")"
    fi
  done
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo
  echo "==> VALIDATION FAILED (${#ERRORS[@]} errors)"
  exit 1
fi

echo
echo "==> VALIDATION OK"
