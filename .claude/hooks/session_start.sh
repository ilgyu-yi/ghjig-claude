#!/usr/bin/env bash
set -uo pipefail

# The inject-consistency banner was removed in #318 (Directive #311). Post-#312 a
# plain `claude` in an injected target (env unset + settings.local.json symlink)
# is the NORMAL working state — hooks self-locate via the binding symlink and the
# env is back-filled below — so the old banner only false-fired. The residual
# genuine no-op (binding symlink missing/broken) is structurally undetectable
# here: this hook is itself invoked through that binding
# (${CLAUDE_PROJECT_DIR}/.claude/eng-shell-root/...), so a broken binding means
# this script never runs. See SPEC §6.5(c). The hookrt-missing banner below stays.

SHELL_ROOT="${CLAUDE_ENG_SHELL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
[ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0
# Back-fill the env var from self-location (#312) so helpers that reference
# $CLAUDE_ENG_SHELL_ROOT resolve even when launched with no global env.
export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"

# Primitive bootstrap of hookrt.sh (audit_log + safe_source). SPEC §6.1.
hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
if [ ! -f "$hookrt" ]; then
  # Per-invocation diagnostic floor (stable contract for log scrapers).
  printf '[claude-eng-shell] WARN hookrt-missing: %s not loaded — hook exiting\n' "$hookrt" >&2
  # Once-per-session actionable banner (SPEC §6.5(c)). Same primitive-inline-
  # printf + mkdir-stamp debounce pattern as the inject-consistency banner.
  # Distinct stamp suffix `-hookrt` avoids collision. If mkdir fails (hostile
  # $TMPDIR / low-disk), the banner is suppressed; the per-fire WARN above is
  # the diagnostic floor that survives that failure mode.
  _hookrt_stamp="${TMPDIR:-/tmp}/claude-eng-banner-hookrt.${CLAUDE_SESSION_ID:-$PPID}"
  if [ ! -d "$_hookrt_stamp" ] && mkdir "$_hookrt_stamp" 2>/dev/null; then
    printf '[claude-eng-shell] WARN hookrt-missing: hook enforcement OFF until restored. Fix: `git -C %s status` to inspect tree state, then `git -C %s checkout -- .claude/hooks/hookrt.sh` to restore.\n' \
      "$SHELL_ROOT" "$SHELL_ROOT" >&2
  fi
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
