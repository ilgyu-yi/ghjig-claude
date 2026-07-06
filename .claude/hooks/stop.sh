#!/usr/bin/env bash
set -uo pipefail

SHELL_ROOT="${GHJIG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
[ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0
# Export the resolved root (#312, #537) so helpers that reference $GHJIG_ROOT
# resolve with no global env. Internal/exported-only: the ambient env is never
# consulted here; GHJIG_ROOT_OVERRIDE is a test-only seam (SPEC §3.2.1).
export GHJIG_ROOT="$SHELL_ROOT"

# Primitive bootstrap of hookrt.sh (audit_log + safe_source). SPEC §6.1.
hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
if [ ! -f "$hookrt" ]; then
  printf '[GHJig-Claude] WARN hookrt-missing: %s not loaded — hook exiting\n' "$hookrt" >&2
  exit 0
fi
# shellcheck source=/dev/null
. "$hookrt"

safe_source "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh" out-of-scope || true

in_scope 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0

# Simple modulo throttle: suggest only when response_count is a multiple of N.
count_file="$SHELL_ROOT/.claude/state/stop_count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

throttle_n=${GHJIG_STOP_THROTTLE:-5}
# Sanitize before arithmetic (set -u context): a non-numeric value would abort
# the hook under $(( )), and 0 would divide-by-zero — either silently killing the
# /review + /sync-pr advisories below. Empty/zero/non-numeric → default 5
# (mirrors the session_start/post_tool_use throttle-var guards).
case "$throttle_n" in ""|0|*[!0-9]*) throttle_n=5 ;; esac
[ $((count % throttle_n)) -ne 0 ] && exit 0

# Suggest /review when uncommitted changes are present.
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  printf '[GHJig-Claude] uncommitted changes present. consider /review.\n' >&2
fi

# Suggest /sync-pr when HEAD has advanced past the last /sync-pr — i.e. commit(s)
# happened since the PR body was last curated, so its checklist is stale relative
# to HEAD (SPEC §6.3 second arm). Detection is local (cached last_synced_head vs
# `git rev-parse HEAD`) behind one `current_pr_number` lookup; this whole block
# is already gated by the modulo throttle above, so the gh touch runs at most
# once per N responses. No PR / no cache (never synced) / no gh → silent no-op.
safe_source "$SHELL_ROOT/.claude/hooks/helpers/gh_state.sh" stop-syncpr || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/pr_cache.sh" stop-syncpr || true
pr_n=$(current_pr_number 2>/dev/null || true)
if [ -n "$pr_n" ]; then
  cached_head=$(pr_cache_head "$pr_n" 2>/dev/null || true)
  cur_head=$(git rev-parse HEAD 2>/dev/null || true)
  if [ -n "$cached_head" ] && [ -n "$cur_head" ] && [ "$cached_head" != "$cur_head" ]; then
    printf '[GHJig-Claude] commit(s) since last /sync-pr. consider /sync-pr.\n' >&2
  fi
fi

exit 0
