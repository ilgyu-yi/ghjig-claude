#!/usr/bin/env bash
# scripts/ghjig_skip.sh <category> <cmd_fingerprint> [reason] (#479; SPEC §7)
#
# Arms a ONE-SHOT, command-bound escape token that the PreToolUse hook reads at
# fire time — the in-agent escape channel that survives the Claude Code Bash
# tool (which strips the in-command SKIP_HOOKS forms before the hook sees the
# command). Run this IMMEDIATELY BEFORE the sanctioned guarded command.
#
# The token is honored only for a command whose text CONTAINS <cmd_fingerprint>,
# within a 60s TTL, exactly once (consumed on read). Use a DISTINGUISHING
# fingerprint — the commit subject / version / branch name, not a bare verb like
# "git commit" — so a stale token cannot disarm a later unrelated command.
#
# Threat model (SPEC §6.1): hooks are mistake-prevention, not a security
# boundary — anyone who can write the state dir can bash -c around the hook, so
# the token carries no signature. consume-once + the TTL are the real narrowing
# guards; the fingerprint + the >=8-char floor are anti-footgun, not anti-adversary.
set -u

_es_self=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Self-locate like the hook entries (#537): the ambient env is never consulted;
# GHJIG_ROOT_OVERRIDE is the test-only seam (SPEC §3.2.1).
SHELL_ROOT="${GHJIG_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$_es_self/.." && pwd)}"
# shellcheck source=/dev/null
. "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null || true

category="${1:-}"
fingerprint="${2:-}"
reason="${3:-unspecified}"

if [ -z "$category" ] || [ -z "$fingerprint" ]; then
  echo "ghjig_skip: usage: ghjig_skip.sh <category> <cmd_fingerprint> [reason]" >&2
  echo "ghjig_skip: <cmd_fingerprint> is a distinguishing substring of the intended command (commit subject / version / branch)." >&2
  exit 2
fi
# Footgun-reducer: refuse a too-short fingerprint (consume-once + 60s TTL are the
# real narrowing guards; a 1-3 char fingerprint would bind almost any command).
if [ "${#fingerprint}" -lt 8 ]; then
  echo "ghjig_skip: fingerprint '$fingerprint' is too short (<8 chars). Use a distinguishing substring (commit subject / version), not a bare verb." >&2
  exit 2
fi

# Resolve the SAME token dir the hook reads (#483). The PreToolUse hook runs with
# CLAUDE_PROJECT_DIR set, so its ghjig_state_dir → <repo>/.claude/ghjig-state; but a
# Claude Code Bash-tool subprocess (this writer) often has CLAUDE_PROJECT_DIR
# UNSET. Derive it from the git top-level when unset (== the project dir the hook
# sees) so writer and reader agree. An already-set CLAUDE_PROJECT_DIR always wins.
if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  _es_top=$(git rev-parse --show-toplevel 2>/dev/null) || _es_top=""
  [ -n "$_es_top" ] && export CLAUDE_PROJECT_DIR="$_es_top"
fi
if command -v ghjig_state_dir >/dev/null 2>&1; then
  esd=$(ghjig_state_dir 2>/dev/null) || esd=""
else
  esd=""
fi
# Aligned fallback (not .claude/state) — consistent with ghjig_state_dir's non-empty
# form so the no-CLAUDE_PROJECT_DIR / non-repo case still agrees with the reader.
[ -n "$esd" ] || esd="$SHELL_ROOT/.claude/ghjig-state"

dir="$esd/escape"
mkdir -p "$dir" || { echo "ghjig_skip: cannot create token dir $dir" >&2; exit 1; }
tok="$dir/${category}.token"
tmp="$tok.tmp.$$"

{
  printf 'category=%s\n' "$category"
  printf 'reason=%s\n' "$reason"
  printf 'cmd_fingerprint=%s\n' "$fingerprint"
  printf 'created=%s\n' "$(date +%s)"
} > "$tmp" || { echo "ghjig_skip: cannot write token" >&2; rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$tok"   # atomic rename within the dir (no half-written token is ever read)

echo "ghjig_skip: armed one-shot '$category' escape (fingerprint='$fingerprint', 60s TTL) — run the matching command next." >&2
