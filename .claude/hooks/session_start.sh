#!/usr/bin/env bash
set -uo pipefail

# 0) Inject-consistency banner — runs even when CLAUDE_ENG_SHELL_ROOT is
# unset, so it must precede the env-guard below. Trigger: env empty AND
# this cwd's .claude/settings.local.json is a symlink (the canonical
# "shell was injected" marker; the only place that symlink shape is
# created is scripts/lib/inject.sh). In that state every other hook
# silently exits 0, which evaporates the SPEC §0.1 enforcement guarantee
# with no signal. The banner makes the silence visible. SPEC §6.5(c).
#
# Debounce: one stamp file under $TMPDIR keyed on CLAUDE_SESSION_ID
# (set by Claude Code) with $PPID as the same-session fallback. Stamp
# is touched once; subsequent SessionStart calls within the same
# session skip the banner. A PID-recycle miss costs at most one
# undetected mis-invocation, strictly better than the prior silent-no-op.
if [ -z "${CLAUDE_ENG_SHELL_ROOT:-}" ] && [ -L "$PWD/.claude/settings.local.json" ]; then
  # Stamp is a directory created via mkdir, not a file via `: >`. mkdir is
  # atomic and refuses to follow symlinks, so a hostile $TMPDIR cannot
  # redirect the truncate to a victim-owned file. Predictable-name race
  # is reduced to "attacker may suppress the banner" — security-neutral.
  _banner_stamp="${TMPDIR:-/tmp}/claude-eng-banner.${CLAUDE_SESSION_ID:-$PPID}"
  if [ ! -d "$_banner_stamp" ] && mkdir "$_banner_stamp" 2>/dev/null; then
    printf "[claude-eng-shell] WARN inject-consistency: shell injected here but CLAUDE_ENG_SHELL_ROOT is unset — every hook will silently no-op. Fix: invoke 'claude-eng' instead of 'claude', OR 'export CLAUDE_ENG_SHELL_ROOT=<shell repo path>' before launching.\n" >&2
  fi
fi

SHELL_ROOT="${CLAUDE_ENG_SHELL_ROOT:-}"
[ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0

# Primitive bootstrap of hookrt.sh (audit_log + safe_source). SPEC §6.1.
hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
if [ ! -f "$hookrt" ]; then
  printf '[claude-eng-shell] WARN hookrt-missing: %s not loaded — hook exiting\n' "$hookrt" >&2
  exit 0
fi
# shellcheck source=/dev/null
. "$hookrt"

safe_source "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"     out-of-scope || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/branch_guard.sh"  branch       || true

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
