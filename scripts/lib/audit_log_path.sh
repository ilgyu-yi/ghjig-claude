# shellcheck shell=bash
# scripts/lib/audit_log_path.sh — resolve the audit-log path the §6.0 P3
# consumer scripts read. Mirrors hookrt.sh's audit_log path resolution
# (eng_state_dir → legacy shared) so the consumers read the SAME file the
# writer targets. set -u-safe; no external calls.
#
# Public:
#   resolve_audit_log [path-arg] — print the audit-log path. An explicit
#     non-empty arg wins (the test seam — smoke feeds a synthetic fixture);
#     else ENG_STATE_DIR_OVERRIDE / $CLAUDE_PROJECT_DIR/.claude/eng-state →
#     "<esd>/audit/audit.jsonl"; else the legacy shared
#     "$CLAUDE_ENG_SHELL_ROOT/.claude/audit/audit.jsonl".

resolve_audit_log() {
  if [ -n "${1:-}" ]; then printf '%s' "$1"; return 0; fi
  local esd=""
  if [ -n "${ENG_STATE_DIR_OVERRIDE:-}" ]; then
    esd="$ENG_STATE_DIR_OVERRIDE"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    esd="$CLAUDE_PROJECT_DIR/.claude/eng-state"
  fi
  if [ -n "$esd" ]; then printf '%s' "$esd/audit/audit.jsonl"; return 0; fi
  printf '%s' "${CLAUDE_ENG_SHELL_ROOT:-}/.claude/audit/audit.jsonl"
}
