#!/usr/bin/env bash
# scripts/setup_project.sh — idempotent bootstrap for the dir-mode Project v2 substrate.
#
# Project schema: the Project is a DERIVED view; Issues are SSOT. The
# mirror workflow (.github/workflows/issues-to-project-mirror.yml) populates
# Project Items from Issue state. This script ensures the field schema the
# mirror writes into:
#   Type     SINGLE_SELECT — Directive,Execution   (MISSION.md replaces a Goal artifact)
#   Status   SINGLE_SELECT — Proposed,Active,Blocked,Completed   (4-state lifecycle)
#   Priority SINGLE_SELECT — P0,P1,P2,P3
#   Parent   TEXT          — mirrored from Issue body line-1 `Parent Directive: #N` marker
# The Iteration field is user-managed (gh CLI lacks ITERATION data-type support);
# the script prints a one-time hint when it's missing.
#
# v3 removes: Confidence (NUMBER) and Success Signals (TEXT) fields — per
# Confidence + Success Signals live in the Issue body, not Project fields; the Project
# carries only the structural-metadata mirror.
#
# Refuses on:
#   - cwd not in $GHJIG_ROOT/.claude/state/registry.txt (registry guard)
#   - `gh auth status` failure
#   - missing `project` token scope
#
# All decisions are audit-logged via audit_log (category: project-setup) when
# hookrt.sh is available. Mock-friendly: every gh call goes through $PATH so
# smoke §41 can overlay a fixture.

set -euo pipefail

# ---------- environment ----------
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${GHJIG_ROOT:=$SCRIPT_ROOT}"
export GHJIG_ROOT

if [ -f "$GHJIG_ROOT/.claude/hooks/hookrt.sh" ]; then
  # shellcheck source=/dev/null
  . "$GHJIG_ROOT/.claude/hooks/hookrt.sh"
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
. "$GHJIG_ROOT/scripts/lib/dir_mode_project_resolve.sh"

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
    # Field exists; for SINGLE_SELECT, reconcile options additively (issue #76).
    # Non-SINGLE_SELECT (TEXT/NUMBER) has no options to reconcile — keep the
    # pre-#76 "skipped" message and audit line.
    if [ "$data_type" = SINGLE_SELECT ] && [ -n "$options" ]; then
      dr_reconcile_select_options "$project_num" "$owner" "$name" "$options"
    else
      echo "  field '$name' exists — skipped"
      audit_log info project-setup skipped "field: $name" 2>/dev/null || true
    fi
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

# Field is named "Item Type" (not "Type"): GitHub reserves "Type" as a
# built-in Projects-v2 field name, so `field-create --name Type` fails with
# "Name cannot have a reserved value" (#342).
ensure_field "Item Type" SINGLE_SELECT "Directive,Execution"
ensure_field "Status"    SINGLE_SELECT "Proposed,Active,Blocked,Completed"
ensure_field "Priority"  SINGLE_SELECT "P0,P1,P2,P3"
ensure_field "Parent"    TEXT
# Confidence and Success Signals live in the Issue body, not Project fields.
# Confidence + Success Signals content lives in Directive Issue body sections.
# Goal Type option removed; MISSION.md is the canonical direction.

# ---------- link project to repo ----------
# Best-effort: gh project link is idempotent server-side (re-linking the same
# project to the same repo is a no-op). Suppress stdout; report on failure only.
if ! gh project link "$project_num" --owner "$owner" --repo "$owner/$repo_name" >/dev/null 2>&1; then
  echo "  warn: failed to link project #$project_num to $owner/$repo_name (manual link via UI required)" >&2
  audit_log warn project-setup notice "project-link-failed: $project_num → $owner/$repo_name" 2>/dev/null || true
else
  audit_log info project-setup linked "project: #$project_num → $owner/$repo_name" 2>/dev/null || true
fi

# ---------- iteration field (user-managed) ----------
# `gh project field-create --data-type` does not accept ITERATION; it must be
# created via `gh api graphql` (multi-step) or the GitHub UI. The setup script
# leaves Iteration for manual creation since the UI path is one-time and ~30s.
iteration_present=$(gh project field-list "$project_num" --owner "$owner" --format json --limit 100 2>/dev/null \
  | jq -r '.fields[]? | select(.name=="Iteration") | .name' | head -1)
if [ -z "$iteration_present" ]; then
  echo ""
  echo "Iteration field not present. gh CLI does not support creating ITERATION-data-type fields."
  echo "  Add manually via the GH UI: open the Project → '+ field' → Iteration → set cadence."
  echo "  Recommended: 2-week cycles, Monday start."
fi

# ---------- final ----------
echo ""
echo "setup_project: done. Project #$project_num for $owner/$repo_name"
audit_log info project-setup complete "project: $project_name #$project_num" 2>/dev/null || true
exit 0
