# shellcheck shell=bash
# helpers/log.sh — audit log writer. Source from hooks.

# Encode an arbitrary string as a JSON string literal (with surrounding
# quotes). Prefers jq for fidelity; falls back to inline escapes for the
# control characters most likely to appear in `reason` / `cwd`.
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

audit_log() {
  local event="$1" category="$2" decision="$3" reason="$4"
  local ts cwd log
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cwd=$(pwd -P 2>/dev/null || pwd)
  log="$CLAUDE_ENG_SHELL_ROOT/.claude/audit/audit.jsonl"
  mkdir -p "$(dirname "$log")"
  # `reason` is user-controllable (SKIP_REASON, normalized cmd strings,
  # park reasons) and `cwd` is filesystem-derived (POSIX paths legally
  # contain `"` and `\`). Both must be JSON-encoded to preserve the
  # "one record per line" invariant of audit.jsonl. Other fields are
  # hardcoded constants at every call site.
  local r_reason r_cwd
  r_reason=$(_audit_json_string "$reason")
  r_cwd=$(_audit_json_string "$cwd")
  printf '{"ts":"%s","event":"%s","category":"%s","decision":"%s","reason":%s,"cwd":%s}\n' \
    "$ts" "$event" "$category" "$decision" "$r_reason" "$r_cwd" >> "$log"
}