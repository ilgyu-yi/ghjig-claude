#!/usr/bin/env bash
# scripts/ghjig_file_review_stage.sh <bodyfile> — stage the sanitized self-review
# body into a fixed out-of-band state file so the classifier-deferred BARE wrapper
# (scripts/ghjig_file_review_post.sh) can slurp it without a stdin pipe (#602).
#
# The Claude Code auto-mode classifier defers a covered command only on a
# byte-exact, wildcard-free match, and a bare covered command in the harness
# cannot be fed stdin. So /file-review first SANITIZES its review body to a
# tempfile, calls THIS writer with the tempfile PATH (never the body as an argv
# token — invariant 7), then invokes the wrapper bare. The staged file lives
# under the fixed `<state>/file-review/body` path resolved by the single shared
# ghjig_state_dir_cli() (hookrt.sh); the wrapper reads it, one-shot unlinks it,
# and TTL/head-bind validates it in memory before the reviews POST (SPEC §5.7.1).
set -euo pipefail

fail() { printf 'ghjig_file_review_stage: %s\n' "$1" >&2; exit 1; }

_fr_self=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Self-locate like ghjig_skip.sh (#537): the ambient env is never consulted;
# GHJIG_ROOT_OVERRIDE is the test-only seam (SPEC §3.2.1).
SHELL_ROOT="${GHJIG_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$_fr_self/.." && pwd)}"
# shellcheck source=/dev/null
. "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null || true

bodyfile="${1:-}"
[ -n "$bodyfile" ] || fail "usage: ghjig_file_review_stage.sh <bodyfile>"
[ -r "$bodyfile" ] || fail "body file not readable: $bodyfile"
[ -s "$bodyfile" ] || fail "empty body file: $bodyfile"

command -v ghjig_state_dir_cli >/dev/null 2>&1 \
  || fail "ghjig_state_dir_cli unavailable (hookrt.sh not sourced)"
esd=$(ghjig_state_dir_cli 2>/dev/null) || esd=""
[ -n "$esd" ] || fail "could not resolve per-project state dir"

# Bind the body to the CURRENT head so a restage on a moved head cannot post a
# stale review. The harness gh shim reports headRefOid == real HEAD, so the
# git-derived head here matches the head the wrapper resolves via `gh pr view`.
head_sha=$(git rev-parse HEAD 2>/dev/null) || head_sha=""
[ -n "$head_sha" ] || fail "could not resolve HEAD"

dir="$esd/file-review"
mkdir -p "$dir" || fail "cannot create state dir $dir"
sf="$dir/body"
tmp="$sf.tmp.$$"

# FIRST line created=<epoch>, SECOND line head=<sha>, then the verbatim body.
{
  printf 'created=%s\n' "$(date +%s)"
  printf 'head=%s\n' "$head_sha"
  cat "$bodyfile"
} > "$tmp" || { rm -f "$tmp"; fail "cannot write staged body"; }
mv -f "$tmp" "$sf"   # atomic rename within the dir (no half-written file is read)
