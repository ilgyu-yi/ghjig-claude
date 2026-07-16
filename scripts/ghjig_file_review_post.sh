#!/usr/bin/env bash
# scripts/ghjig_file_review_post.sh — post a self `COMMENT` review to the CURRENT
# branch's own PR, pinned to its head, carrying the sanitized review body from a
# fixed out-of-band STATE FILE staged by ghjig_file_review_stage.sh
# (SPEC §5.7.1 "Second exception — the self-review producer", #598, #602).
#
# This is the single `permissions.allow`-covered surface that lets an unattended
# `/ship` post its own head-pinned review: the auto-mode classifier defers this
# fixed-form command to the shell instead of blocking the raw
# `gh api .../pulls/<n>/reviews` self-approve POST as self-approval. The allow
# entry is the exact, wildcard-free `Bash(.claude/ghjig-root/scripts/ghjig_file_review_post.sh)`.
#
# The wrapper IS the capability boundary — even invoked adversarially it can only
# post a self `COMMENT` on the acting identity's OWN current-branch PR:
#   - no positional args (it resolves the current-branch PR itself, mirroring
#     `gh pr merge --auto`, so the allow entry needs no trailing wildcard) and it
#     stays invocable BARE — no stdin pipe, so the classifier keeps deferring it;
#   - the body is read from a staged state file (#602), invisible to the
#     permission matcher — NOT stdin (a bare covered command cannot be fed stdin);
#   - `event=COMMENT` is hardcoded — never APPROVE/REQUEST_CHANGES;
#   - an own-PR guard fails closed unless the acting identity == the PR author.
# Whether the produced self-review is then HONORED is a separate per-target
# decision (`resolve_self_review_policy` / `.claude/state/self-review`, §5.7.1)
# read by the merge-review gate (§6.1) — this producer never consults it.
set -euo pipefail

fail() { printf 'ghjig_file_review_post: %s\n' "$1" >&2; exit 1; }

_fr_self=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# Self-locate like ghjig_skip.sh (#537): the ambient env is never consulted;
# GHJIG_ROOT_OVERRIDE is the test-only seam (SPEC §3.2.1).
SHELL_ROOT="${GHJIG_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$_fr_self/.." && pwd)}"
# shellcheck source=/dev/null
. "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null || true

command -v gh >/dev/null 2>&1 || fail "gh CLI not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

# Resolve the current-branch PR (no positional arg — mirrors `gh pr merge --auto`).
pr_json=$(gh pr view --json number,headRefOid,author 2>/dev/null) \
  || fail "no PR for the current branch (or gh not authed)"
pr_num=$(printf '%s' "$pr_json" | jq -r '.number // empty')
head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty')
pr_author=$(printf '%s' "$pr_json" | jq -r '.author.login // empty')
[ -n "$pr_num" ] && [ -n "$head_sha" ] && [ -n "$pr_author" ] \
  || fail "could not resolve PR number / head / author for the current branch"

# Resolve the origin repo (owner/name) AND its host BEFORE the identity guard.
# `gh api` resolves gh's DEFAULT host (github.com), not the repo's, so on a GHES
# target a host-less `gh api user` reads the wrong account and the own-PR guard
# below mis-fires. Derive the host from the repo's normalized url and pin it on
# every host-less `gh api` call. Fail CLOSED on an unusable host — a silent
# default-host fallback would let the guard pass against the wrong account (#610).
owner_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || fail "could not resolve origin repo"
[ -n "$owner_repo" ] || fail "empty origin repo"

repo_url=$(gh repo view --json nameWithOwner,url --jq .url 2>/dev/null) \
  || fail "could not resolve origin repo url"
h=${repo_url#*://}; h=${h#*@}; h=${h%%/*}
case "$h" in
  ''|*[!A-Za-z0-9.:-]*)
    fail "could not resolve repo host from url ($repo_url) — authenticate gh to that host" ;;
esac

# Own-PR guard (fail closed): the acting identity must be the PR author. A self
# `COMMENT` on someone else's PR is out of this wrapper's mandate. The identity
# is resolved AT THE REPO HOST (`--hostname "$h"`), never gh's default host.
me=$(gh api user --hostname "$h" --jq .login 2>/dev/null) || fail "could not resolve acting identity"
[ -n "$me" ] || fail "empty acting identity"
[ "$me" = "$pr_author" ] \
  || fail "refusing: acting identity ($me) is not the PR author ($pr_author) — this wrapper is own-PR only"

# The sanitized review body arrives via a fixed staged state file (#602), never
# stdin or an inline argument. It is resolved through the SAME shared
# ghjig_state_dir_cli() the writer used, under `<state>/file-review/body`.
command -v ghjig_state_dir_cli >/dev/null 2>&1 \
  || fail "ghjig_state_dir_cli unavailable (hookrt.sh not sourced)"
esd=$(ghjig_state_dir_cli 2>/dev/null) || esd=""
[ -n "$esd" ] || fail "could not resolve per-project state dir"
sf="$esd/file-review/body"

# Fail closed BEFORE any POST if the staged body is absent/unreadable/empty.
[ -r "$sf" ] || fail "no staged review body (absent/unreadable) — fail closed, no POST"
if [ ! -s "$sf" ]; then rm -f "$sf"; fail "empty staged review body — fail closed, no POST"; fi

# Slurp ONCE, then one-shot unlink the state file IMMEDIATELY — before validation
# and before the POST (slurp→unlink→validate→post). Unlinking first is poison
# cleanup (every reject path below also drops the file) and forecloses a TOCTOU:
# a concurrent restage cannot make this wrapper post twice.
staged=$(cat "$sf")
rm -f "$sf"

# Validate the header IN MEMORY. The two-line header is created=<epoch> then
# head=<sha>; the rest is the verbatim body.
created_line=$(printf '%s\n' "$staged" | sed -n '1p')
head_line=$(printf '%s\n'    "$staged" | sed -n '2p')
body=$(printf '%s\n'         "$staged" | tail -n +3)

case "$created_line" in
  created=*) : ;;
  *) fail "malformed staged body (no created= header) — fail closed, no POST" ;;
esac
case "$head_line" in
  head=*) : ;;
  *) fail "malformed staged body (no head= header) — fail closed, no POST" ;;
esac
created=${created_line#created=}
staged_head=${head_line#head=}

# `created` must be a plausible base-10 epoch before arithmetic (mirrors
# escape.sh:64-77): digits only, no leading zero (octal trap), <=11 digits
# (year-5138 ceiling / bash-3.2 overflow guard), else the TTL/future checks
# below silently fall through to HONOR.
case "$created" in ''|0*|*[!0-9]*) fail "malformed created epoch in staged body — fail closed, no POST" ;; esac
[ "${#created}" -le 11 ] || fail "implausible created epoch in staged body — fail closed, no POST"
now=$(date +%s)
[ "$created" -le "$now" ] || fail "future-dated staged body — fail closed, no POST"
[ "$(( now - created ))" -le 60 ] || fail "stale staged body (>60s TTL) — fail closed, no POST"

# Head-bind: the staged head must equal the wrapper's resolved current head.
[ "$staged_head" = "$head_sha" ] \
  || fail "staged head ($staged_head) != current head ($head_sha) — fail closed, no POST"

# The body (header lines stripped) must be non-empty.
[ -n "$body" ] || fail "empty staged review body after header strip — fail closed, no POST"

# Post the self COMMENT review, pinned to the current head. `event=COMMENT` is
# hardcoded; the in-memory body travels via `-F body=@-` (read as a string).
printf '%s' "$body" | gh api "repos/$owner_repo/pulls/$pr_num/reviews" \
  --hostname "$h" \
  -f commit_id="$head_sha" \
  -f event=COMMENT \
  -F body=@- \
  --jq '{id, commit_id, state, user: .user.login}' \
  || fail "review POST failed"
