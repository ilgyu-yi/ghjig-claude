# shellcheck shell=bash
# scripts/lib/audit_log_path.sh — resolve the audit-log path the §6.0 P3
# consumer scripts read. Mirrors the writer's dedicated resolver
# (hookrt.sh ghjig_audit_dir, SPEC §3.2.2) so the consumers read the SAME
# file audit_log targets, with the legacy shared file as a READ-ONLY FLOOR.
# set -u-safe.
#
# Public:
#   resolve_audit_log [path-arg] — print the audit-log path. An explicit
#     non-empty arg wins (the test seam — smoke feeds a synthetic fixture);
#     else resolve the per-project tier through the writer's rung order
#     (GHJIG_STATE_DIR_OVERRIDE → $CLAUDE_PROJECT_DIR/.claude/ghjig-state →
#     main-worktree top level via git --git-common-dir → self-location) and
#     return "<esd>/audit/audit.jsonl" when that file EXISTS; else return
#     the legacy floor "$GHJIG_ROOT/.claude/audit/audit.jsonl" (read-only
#     back-compat — records that predate the unconditional writer, #725).

# Self-location: resolve GHJIG_ROOT from our own path (test seam:
# GHJIG_ROOT_OVERRIDE). The inherited ambient env is never an input (#539).
GHJIG_ROOT="${GHJIG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"; export GHJIG_ROOT

resolve_audit_log() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  local esd="" gcd top=""
  if [ -n "${GHJIG_STATE_DIR_OVERRIDE:-}" ]; then
    esd="$GHJIG_STATE_DIR_OVERRIDE"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    esd="$CLAUDE_PROJECT_DIR/.claude/ghjig-state"
  elif [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    gcd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || gcd=""
    case "$gcd" in */.git) top="${gcd%/.git}" ;; esac
    [ -n "$top" ] || top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""
    [ -n "$top" ] && esd="$top/.claude/ghjig-state"
  fi
  [ -n "$esd" ] || esd="$GHJIG_ROOT/.claude/ghjig-state"
  if [ -f "$esd/audit/audit.jsonl" ]; then
    printf '%s' "$esd/audit/audit.jsonl"; return 0
  fi
  printf '%s' "$GHJIG_ROOT/.claude/audit/audit.jsonl"
}
