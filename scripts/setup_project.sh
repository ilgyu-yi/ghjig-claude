#!/usr/bin/env bash
# scripts/setup_project.sh — idempotent bootstrap for the dir-mode Project v2 substrate.
#
# Creates (or finds) a single GitHub Project v2 named "<repo-name> roadmap"
# (override via $CLAUDE_ENG_PROJECT_NAME) and ensures the six script-managed
# custom fields exist with the schema locked by docs/ADRs/0002-…:
#   Type, Status, Priority (SINGLE_SELECT); Parent, Success Signals (TEXT); Confidence (NUMBER).
# The Iteration field is user-managed (gh CLI lacks ITERATION data-type support);
# the script prints a one-time hint when it's missing.
#
# Refuses on:
#   - cwd not in $CLAUDE_ENG_SHELL_ROOT/.claude/state/registry.txt (registry guard)
#   - `gh auth status` failure
#   - missing `project` token scope
#
# All decisions are audit-logged via audit_log (category: project-setup) when
# hookrt.sh is available. Mock-friendly: every gh call goes through $PATH so
# smoke §41 can overlay a fixture.

set -euo pipefail

# ---------- environment ----------
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${CLAUDE_ENG_SHELL_ROOT:=$SCRIPT_ROOT}"
export CLAUDE_ENG_SHELL_ROOT

if [ -f "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/hookrt.sh" ]; then
  # shellcheck source=/dev/null
  . "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/hookrt.sh"
else
  audit_log() { :; }
fi

# ---------- registry guard ----------
TARGET=$(pwd -P)
REGISTRY="$CLAUDE_ENG_SHELL_ROOT/.claude/state/registry.txt"
if [ ! -f "$REGISTRY" ] || ! grep -qxF "$TARGET" "$REGISTRY"; then
  echo "setup_project: refusing — '$TARGET' is not a registered target" >&2
  echo "  Register first: $CLAUDE_ENG_SHELL_ROOT/scripts/register.sh '$TARGET'" >&2
  audit_log block project-setup deny "unregistered-path: $TARGET" 2>/dev/null || true
  exit 1
fi

# ---------- gh auth + scope check ----------
if ! gh auth status >/dev/null 2>&1; then
  echo "setup_project: gh is not authenticated" >&2
  echo "  Run: gh auth login" >&2
  audit_log block project-setup deny "gh-not-authenticated" 2>/dev/null || true
  exit 1
fi

auth_blob=$(gh auth status 2>&1 || true)
if ! printf '%s' "$auth_blob" | grep -iq "token scopes:.*project"; then
  echo "setup_project: gh token is missing the 'project' scope" >&2
  echo "  Refresh with: gh auth refresh -s project" >&2
  audit_log block project-setup deny "missing-project-scope" 2>/dev/null || true
  exit 1
fi

# ---------- owner + repo + project name ----------
if ! command -v jq >/dev/null 2>&1; then
  echo "setup_project: jq is required but not installed" >&2
  exit 1
fi

repo_json=$(gh repo view --json owner,name 2>/dev/null) || {
  echo "setup_project: gh repo view failed — is this a GitHub-linked repo?" >&2
  audit_log block project-setup deny "no-gh-remote" 2>/dev/null || true
  exit 1
}
owner=$(printf '%s' "$repo_json" | jq -r '.owner.login')
repo_name=$(printf '%s' "$repo_json" | jq -r '.name')
project_name="${CLAUDE_ENG_PROJECT_NAME:-$repo_name roadmap}"

if [ -z "$owner" ] || [ "$owner" = null ]; then
  echo "setup_project: could not resolve repo owner from gh repo view" >&2
  exit 1
fi

# ---------- find or create project ----------
existing=$(gh project list --owner "$owner" --format json --limit 100 2>/dev/null \
  | jq -r --arg name "$project_name" '.projects[]? | select(.title==$name) | .number' \
  | head -1)

if [ -n "$existing" ]; then
  project_num="$existing"
  echo "setup_project: project '$project_name' exists (#$project_num)"
  audit_log info project-setup skipped "project-exists: $project_name #$project_num" 2>/dev/null || true
else
  create_json=$(gh project create --owner "$owner" --title "$project_name" --format json)
  project_num=$(printf '%s' "$create_json" | jq -r '.number')
  project_url=$(printf '%s' "$create_json" | jq -r '.url')
  if [ -z "$project_num" ] || [ "$project_num" = null ]; then
    echo "setup_project: gh project create returned unexpected output: $create_json" >&2
    exit 1
  fi
  echo "setup_project: created project '$project_name' (#$project_num)  url=$project_url"
  audit_log info project-setup created "project: $project_name #$project_num" 2>/dev/null || true
fi

# ---------- ensure six fields ----------
ensure_field() {
  local name="$1" data_type="$2" options="${3:-}"
  local present
  present=$(gh project field-list "$project_num" --owner "$owner" --format json --limit 100 2>/dev/null \
    | jq -r --arg name "$name" '.fields[]? | select(.name==$name) | .name' \
    | head -1)
  if [ -n "$present" ]; then
    echo "  field '$name' exists — skipped"
    audit_log info project-setup skipped "field: $name" 2>/dev/null || true
    return 0
  fi
  if [ "$data_type" = SINGLE_SELECT ]; then
    gh project field-create "$project_num" --owner "$owner" --name "$name" \
      --data-type SINGLE_SELECT --single-select-options "$options" >/dev/null
  else
    gh project field-create "$project_num" --owner "$owner" --name "$name" \
      --data-type "$data_type" >/dev/null
  fi
  echo "  field '$name' ($data_type) — created"
  audit_log info project-setup created "field: $name ($data_type)" 2>/dev/null || true
}

ensure_field "Type"            SINGLE_SELECT "Goal,Directive,Execution"
ensure_field "Status"          SINGLE_SELECT "Planned,Active,Completed,Blocked,Revised"
ensure_field "Priority"        SINGLE_SELECT "P0,P1,P2,P3"
ensure_field "Parent"          TEXT
ensure_field "Confidence"      NUMBER
ensure_field "Success Signals" TEXT

# ---------- iteration field (user-managed, ADR-0002) ----------
iteration_present=$(gh project field-list "$project_num" --owner "$owner" --format json --limit 100 2>/dev/null \
  | jq -r '.fields[]? | select(.name=="Iteration") | .name' | head -1)
if [ -z "$iteration_present" ]; then
  echo ""
  echo "Iteration field not present. gh project field-create does not support ITERATION data-type (ADR-0002)."
  echo "  Add manually via the GH UI: open the Project → '+ field' → Iteration → set cadence."
  echo "  Recommended: 2-week cycles, Monday start."
fi

# ---------- final ----------
echo ""
echo "setup_project: done. Project #$project_num for $owner/$repo_name"
audit_log info project-setup complete "project: $project_name #$project_num" 2>/dev/null || true
exit 0
