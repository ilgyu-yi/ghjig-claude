#!/usr/bin/env bash
set -uo pipefail

SHELL_ROOT="${CLAUDE_ENG_SHELL_ROOT:-}"
[ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0

. "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"
. "$SHELL_ROOT/.claude/hooks/helpers/branch_guard.sh"

# 1) Shell self-sync check — always runs regardless of target cwd.
# Gated by .claude/state/last-shell-fetched stamp (SESSION_START_FETCH_TTL
# seconds, default 21600 = 6 h). Fetch is bounded by
# SESSION_START_FETCH_TIMEOUT (default 5 s) via timeout(1)/gtimeout(1).
# See SPEC §6.5(a).
_session_should_fetch() {
  local stamp="$SHELL_ROOT/.claude/state/last-shell-fetched"
  [ -f "$stamp" ] || return 0
  local ttl="${SESSION_START_FETCH_TTL:-21600}"
  local mtime now
  if mtime=$(stat -c %Y "$stamp" 2>/dev/null); then
    :
  elif mtime=$(stat -f %m "$stamp" 2>/dev/null); then
    :
  else
    return 0
  fi
  now=$(date +%s)
  [ "$((now - mtime))" -ge "$ttl" ]
}

_session_run_fetch() {
  local stamp="$SHELL_ROOT/.claude/state/last-shell-fetched"
  local secs="${SESSION_START_FETCH_TIMEOUT:-5}"
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  fi
  mkdir -p "$(dirname "$stamp")" 2>/dev/null
  if [ -n "$timeout_bin" ]; then
    (cd "$SHELL_ROOT" && "$timeout_bin" "$secs" git fetch --quiet 2>/dev/null) \
      && touch "$stamp"
  else
    (cd "$SHELL_ROOT" && git fetch --quiet 2>/dev/null) \
      && touch "$stamp"
  fi
}

if command -v git >/dev/null 2>&1; then
  if (cd "$SHELL_ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    _session_should_fetch && _session_run_fetch
    # `behind` reads local refs (possibly up to TTL stale by design).
    behind=$(cd "$SHELL_ROOT" && git rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)
    if [ "${behind:-0}" -gt 0 ]; then
      printf '[claude-eng-shell] shell repo is %s commit(s) behind origin. consider pulling.\n' "$behind"
    fi
  fi
fi

# 2) Session restore — only when target cwd is in the registry.
in_scope || exit 0
command -v git >/dev/null 2>&1 || exit 0

branch=$(current_branch)
[ -z "$branch" ] && exit 0
printf '[claude-eng-shell] branch: %s\n' "$branch"

if [ -f MISSION.md ]; then
  printf '[MISSION summary]\n'
  head -n 20 MISSION.md
fi

if command -v gh >/dev/null 2>&1; then
  body=$(gh pr view --json body --jq .body 2>/dev/null || true)
  if [ -n "$body" ]; then
    printf '[current PR body]\n%s\n' "$body" | head -c 8192
  fi
fi

exit 0
