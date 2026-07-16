#!/usr/bin/env bash
# .githooks/_lib.sh — shared prelude for the local git-hook enforcement tier
# (SPEC §6.7). Every adapter (pre-commit / pre-push / commit-msg) sources this
# FIRST. It self-locates the shell tree via the §3.2.1 binding-symlink idiom,
# sources hookrt.sh (audit_log + safe_source), and exposes:
#   githook_source <helper.sh> [category] — safe_source a helper by basename.
#   githook_block  <category> <message>   — stderr message + best-effort
#                                            audit_log, returns non-zero.
# A missing or dangling binding → exit 0: this is an ADVICE tier (folds to
# --no-verify by design, SPEC §6.7), so a broken shell link must NEVER wedge
# the user's git.
set -uo pipefail

# Self-locate the shell tree through the committed binding symlink (§3.2.1):
# <repo-top>/.claude/ghjig-root points at the shell root.
_gh_top="$(git rev-parse --show-toplevel 2>/dev/null)" || _gh_top=""
GR="$_gh_top/.claude/ghjig-root"
# Missing or dangling binding → exit 0 (advice tier; never wedge git).
[ -n "$_gh_top" ] && [ -d "$GR/.claude" ] || exit 0

# Resolve the physical shell root (follow the binding symlink).
SHELL_ROOT="$(cd "$GR" && pwd -P)" || exit 0
export GHJIG_ROOT="$SHELL_ROOT"

# Route audit evidence to the target's PER-PROJECT log (§3.2.2, #602). Under
# terminal context CLAUDE_PROJECT_DIR is unset, so audit_log's ghjig_state_dir
# would fall back to the legacy shared path; deriving it from the git top-level
# (the ghjig_state_dir_cli rule) lands terminal-originated evidence in the
# target's per-project audit log. Only set it when unset.
: "${CLAUDE_PROJECT_DIR:=$_gh_top}"
export CLAUDE_PROJECT_DIR

# Source hookrt.sh (the audit_log + safe_source primitives). Missing → exit 0.
_gh_hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
[ -f "$_gh_hookrt" ] || exit 0
# shellcheck source=/dev/null
. "$_gh_hookrt"

# githook_source <helper-basename> [audit-category] — safe_source a helper from
# .claude/hooks/helpers/. Returns non-zero (fail-open per safe_source) on miss;
# the adapter then short-circuits to exit 0 (advice tier).
githook_source() {
  safe_source "$SHELL_ROOT/.claude/hooks/helpers/$1" "${2:-git-hook-tier}"
}

# githook_block <category> <message> — emit a clear stderr line, best-effort
# audit_log (a subshell so any audit misbehavior cannot abort the hook), and
# return non-zero so git aborts the op on the non-zero hook exit.
githook_block() {
  local category="$1" msg="$2"
  printf '[GHJig-Claude] %s\n' "$msg" >&2
  ( audit_log block "$category" blocked "$msg" ) >/dev/null 2>&1 || true
  return 1
}
