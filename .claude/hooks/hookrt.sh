# shellcheck shell=bash
# .claude/hooks/hookrt.sh — hook runtime bootstrap.
#
# Hosts:
#   - _audit_json_string  : JSON-encode arbitrary strings (jq with fallback).
#   - audit_log           : the one-record-per-line audit writer.
#   - safe_source         : presence-checked source with helper-missing
#                           audit-warn emission.
#
# Every hook file opens with a primitive presence-check of THIS file; once
# loaded, every other helper goes through `safe_source <path> <category>`.
# This breaks the chicken-and-egg of `safe_source` calling `audit_log` —
# both live here, loaded by the same primitive.
#
# Bootstrap contract (the primitive every hook uses):
#
#   SHELL_ROOT="${CLAUDE_ENG_SHELL_ROOT:-}"
#   [ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0
#   hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
#   if [ ! -f "$hookrt" ]; then
#     printf '[claude-eng-shell] WARN hookrt-missing: %s not loaded — hook exiting\n' "$hookrt" >&2
#     exit 0
#   fi
#   # shellcheck source=/dev/null
#   . "$hookrt"
#
# After this point the hook can call `safe_source helpers/foo.sh foo` for
# every other helper.
#
# Cross-reference: SPEC §6.1 (session-restart caveat + fail-policy table).

# _audit_json_string <s> — encode <s> as a JSON string literal (with
# surrounding quotes). Prefers jq for fidelity; falls back to inline
# escapes for control characters most likely to appear in `reason`/`cwd`.
_audit_json_string() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -Rs .
    return
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# audit_log <event> <category> <decision> <reason> — append one JSON
# record to audit.jsonl. `reason` is user-controllable / filesystem-
# derived so it's JSON-encoded; other fields are call-site constants.
audit_log() {
  local event="$1" category="$2" decision="$3" reason="$4"
  local ts cwd log
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cwd=$(pwd -P 2>/dev/null || pwd)
  log="$CLAUDE_ENG_SHELL_ROOT/.claude/audit/audit.jsonl"
  mkdir -p "$(dirname "$log")"
  local r_reason r_cwd
  r_reason=$(_audit_json_string "$reason")
  r_cwd=$(_audit_json_string "$cwd")
  printf '{"ts":"%s","event":"%s","category":"%s","decision":"%s","reason":%s,"cwd":%s}\n' \
    "$ts" "$event" "$category" "$decision" "$r_reason" "$r_cwd" >> "$log"
}

# safe_source <helper-path> <audit-category> — presence-check + source.
#   - On success: source the helper and return 0.
#   - On miss   : emit `audit_log warn <category> helper-missing "<path>"`
#                 and return 1. Caller fails-open by short-circuiting any
#                 downstream call that depends on the helper.
#
# The fail-open policy is per-category but uniformly implemented here:
# the warn is emitted, the caller decides whether to continue (the
# default) or to refuse the operation (no current call site does this;
# future PRs may flip individual entries with SPEC §1.4 justification).
#
# SPEC §6.1 enumerates the per-helper (category, on-miss-note) table.
safe_source() {
  local helper_path="$1" category="$2"
  if [ -f "$helper_path" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$helper_path" && return 0
  fi
  # Missing OR sourcing errored — warn and tell the caller to short-circuit.
  # Security-relevant categories carry a NOT ENFORCED suffix so an operator
  # scanning audit.jsonl can distinguish "informational helper unavailable"
  # from "security gate is OFF" at a glance. SPEC §6.1 fail-policy table.
  local sev_suffix=""
  case "$category" in
    secret|branch) sev_suffix=" — NOT ENFORCED (security-relevant)" ;;
  esac
  audit_log warn "$category" helper-missing "$helper_path not loaded; hook fail-open per SPEC §6.1. Restart claude-eng if a hook-spec change recently introduced this helper.${sev_suffix}"
  return 1
}
