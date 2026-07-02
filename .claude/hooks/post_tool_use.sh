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

safe_source "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"     out-of-scope    || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/detect_stack.sh"  format          || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"   commit-format   || true

in_scope 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')

case "$tool" in
  Edit|Write|MultiEdit)
    target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
    [ -z "$target" ] && exit 0
    fmt=$(detect_format_cmd "$target")
    [ -n "$fmt" ] && eval "$fmt" >/dev/null 2>&1 || true
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    # Match `git commit` / `git push` tolerantly so that option-prefix
    # forms (git -c <opt> commit, git -C <path> push, …) still fire the
    # reminders. Single source of truth lives in helpers/git_matcher.sh.
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}commit\b"; then
      printf '[GHJig-Claude] reminder: update the matching PR body checklist item.\n' >&2
    fi
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}push\b"; then
      if command -v gh >/dev/null 2>&1; then
        n=$(gh pr view --json number --jq .number 2>/dev/null)
        if [ -n "$n" ]; then
          state=$(gh pr checks "$n" --json state 2>/dev/null | jq -r '[.[].state] | unique | join(",")' 2>/dev/null)
          [ -n "$state" ] && printf '[GHJig-Claude] PR #%s checks: %s\n' "$n" "$state" >&2
        fi
      fi
    fi
    ;;
  Read)
    # Positive narrowing affordance (SPEC §1.8 / §6.2): when a Read loads a
    # WHOLE file (neither offset nor limit set) above the line threshold, nudge
    # toward a targeted read or explorer delegation. Warn-only — always exit 0;
    # a missed narrowing nudge is ignorable at no cost (§6.0 P1 cost-asymmetry).
    target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
    [ -z "$target" ] && exit 0
    off=$(printf '%s' "$input" | jq -r '.tool_input.offset // empty')
    lim=$(printf '%s' "$input" | jq -r '.tool_input.limit // empty')
    if [ -z "$off" ] && [ -z "$lim" ]; then
      thr="${GHJIG_READ_NUDGE_THRESHOLD:-200}"
      lines=$(wc -l < "$target" 2>/dev/null | tr -d ' ')
      # Fire when the file is large, OR when its size can't be determined (a
      # whole-file load is the worst case, so fail toward nudging).
      if [ -z "$lines" ] || { [ "$lines" -gt "$thr" ]; } 2>/dev/null; then
        printf '[GHJig-Claude] narrowing: whole-file Read of %s — prefer a targeted `Read --offset/--limit`, or delegate the search to `explorer` (SPEC §1.8).\n' "$target" >&2
      fi
    fi
    ;;
esac

exit 0
