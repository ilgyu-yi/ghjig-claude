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

# ---------- shared resolver helpers (issue #71) ----------
# Pin script identity + audit category before sourcing the lib so its
# stderr prefixes and audit lines stay attributed to setup_project. All
# guard rcs are translated to `exit 1` to preserve pre-#71 behavior
# (smoke §41 asserts non-zero, not specific codes).
# shellcheck disable=SC2034  # used by sourced dir_mode_project_resolve.sh
DR_SCRIPT_NAME=setup_project
# shellcheck disable=SC2034  # used by sourced dir_mode_project_resolve.sh
DR_AUDIT_CATEGORY=project-setup
# shellcheck source=/dev/null
. "$CLAUDE_ENG_SHELL_ROOT/scripts/lib/dir_mode_project_resolve.sh"

dr_check_registry_guard || exit 1
dr_check_gh_auth || exit 1
dr_check_gh_scope || exit 1
dr_check_jq || exit 1
dr_resolve_owner_repo || exit 1

owner="$DR_OWNER"
repo_name="$DR_REPO_NAME"
project_name="$DR_PROJECT_NAME"

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

# ---------- link project to repo ----------
# Best-effort: gh project link is idempotent server-side (re-linking the same
# project to the same repo is a no-op). Suppress stdout; report on failure only.
if ! gh project link "$project_num" --owner "$owner" --repo "$owner/$repo_name" >/dev/null 2>&1; then
  echo "  warn: failed to link project #$project_num to $owner/$repo_name (manual link via UI required)" >&2
  audit_log warn project-setup notice "project-link-failed: $project_num → $owner/$repo_name" 2>/dev/null || true
else
  audit_log info project-setup linked "project: #$project_num → $owner/$repo_name" 2>/dev/null || true
fi

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
