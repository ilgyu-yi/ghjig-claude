#!/usr/bin/env bash
# scripts/dir_mode_project.sh — dir-mode Project resolver (SPEC §1.7 / issue #71).
#
# Deterministic gate invoked from /file-directive step 1 (and any other dir-mode
# command that needs the resolved Project number/owner/name without creating).
# Find-only path; bootstrap remains scripts/setup_project.sh.
#
# Verbs:
#   resolve   Print "<num>\t<owner>\t<name>" on stdout if found; exit 0.
#             Exit non-zero on specific refusal modes (see exit-code table below).
#   --help    Print this header.
#
# Exit codes (also documented in /file-directive.md step 1):
#   0 — Project found; stdout = "<project-num>\t<owner>\t<project-name>"
#   1 — Registry guard: cwd is not a registered target
#   2 — gh not authenticated
#   3 — gh token missing 'project' scope
#   4 — gh repo view failed (no GitHub remote, or owner unresolvable)
#   5 — No Project named "<repo-name> roadmap" (or $GHJIG_PROJECT_NAME) for owner
#   6 — jq missing
#
# All non-zero exits emit a one-line diagnostic to stderr and an audit_log entry
# under category 'project-resolve' (when hookrt.sh is sourceable).

set -uo pipefail

# ---------- environment ----------
# Self-location: resolve GHJIG_ROOT from our own path (test seam: GHJIG_ROOT_OVERRIDE).
# The inherited ambient env is never an input (#539).
GHJIG_ROOT="${GHJIG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"; export GHJIG_ROOT

if [ -f "$GHJIG_ROOT/.claude/hooks/hookrt.sh" ]; then
  # shellcheck source=/dev/null
  . "$GHJIG_ROOT/.claude/hooks/hookrt.sh"
else
  audit_log() { :; }
fi

# ---------- shared resolver helpers ----------
# shellcheck disable=SC2034  # used by sourced dir_mode_project_resolve.sh
DR_SCRIPT_NAME=dir_mode_project
# shellcheck disable=SC2034  # used by sourced dir_mode_project_resolve.sh
DR_AUDIT_CATEGORY=project-resolve
# shellcheck source=/dev/null
. "$GHJIG_ROOT/scripts/lib/dir_mode_project_resolve.sh"

verb="${1:-}"
case "$verb" in
  resolve)
    # Propagate the lib's specific rc so callers can dispatch on the failure mode.
    dr_check_registry_guard || exit $?
    dr_check_gh_auth || exit $?
    dr_check_gh_scope || exit $?
    dr_check_jq || exit $?
    dr_resolve_owner_repo || exit $?
    dr_find_project || exit $?
    printf '%s\t%s\t%s\n' "$DR_PROJECT_NUM" "$DR_OWNER" "$DR_PROJECT_NAME"
    audit_log info project-resolve found "project: $DR_PROJECT_NAME #$DR_PROJECT_NUM" 2>/dev/null || true
    exit 0
    ;;
  ""|--help|-h)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "$DR_SCRIPT_NAME: unknown verb '$verb' — try '$(basename "$0") --help'" >&2
    exit 1
    ;;
esac
