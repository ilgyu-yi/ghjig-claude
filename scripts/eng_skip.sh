#!/usr/bin/env bash
# scripts/eng_skip.sh <category> <cmd_fingerprint> [reason] (#479; SPEC §7)
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
SHELL_ROOT="${CLAUDE_ENG_SHELL_ROOT:-$(CDPATH='' cd -- "$_es_self/.." && pwd)}"
# shellcheck source=/dev/null
. "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null || true

category="${1:-}"
fingerprint="${2:-}"
reason="${3:-unspecified}"

if [ -z "$category" ] || [ -z "$fingerprint" ]; then
  echo "eng_skip: usage: eng_skip.sh <category> <cmd_fingerprint> [reason]" >&2
  echo "eng_skip: <cmd_fingerprint> is a distinguishing substring of the intended command (commit subject / version / branch)." >&2
  exit 2
fi
# Footgun-reducer: refuse a too-short fingerprint (consume-once + 60s TTL are the
# real narrowing guards; a 1-3 char fingerprint would bind almost any command).
if [ "${#fingerprint}" -lt 8 ]; then
  echo "eng_skip: fingerprint '$fingerprint' is too short (<8 chars). Use a distinguishing substring (commit subject / version), not a bare verb." >&2
  exit 2
fi

if command -v eng_state_dir >/dev/null 2>&1; then
  esd=$(eng_state_dir 2>/dev/null) || esd=""
else
  esd=""
fi
[ -n "$esd" ] || esd="$SHELL_ROOT/.claude/state"

dir="$esd/escape"
mkdir -p "$dir" || { echo "eng_skip: cannot create token dir $dir" >&2; exit 1; }
tok="$dir/${category}.token"
tmp="$tok.tmp.$$"

{
  printf 'category=%s\n' "$category"
  printf 'reason=%s\n' "$reason"
  printf 'cmd_fingerprint=%s\n' "$fingerprint"
  printf 'created=%s\n' "$(date +%s)"
} > "$tmp" || { echo "eng_skip: cannot write token" >&2; rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$tok"   # atomic rename within the dir (no half-written token is ever read)

echo "eng_skip: armed one-shot '$category' escape (fingerprint='$fingerprint', 60s TTL) — run the matching command next." >&2
