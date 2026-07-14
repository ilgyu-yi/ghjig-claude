#!/usr/bin/env bash
# scripts/ghjig_file_review_post.sh — post a self `COMMENT` review to the CURRENT
# branch's own PR, pinned to its head, carrying the sanitized review body from
# stdin (SPEC §5.7.1 "Second exception — the self-review producer", #598).
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
#     `gh pr merge --auto`, so the allow entry needs no trailing wildcard);
#   - the body is read from stdin (invisible to the permission matcher);
#   - `event=COMMENT` is hardcoded — never APPROVE/REQUEST_CHANGES;
#   - an own-PR guard fails closed unless the acting identity == the PR author.
# Whether the produced self-review is then HONORED is a separate per-target
# decision (`resolve_self_review_policy` / `.claude/state/self-review`, §5.7.1)
# read by the merge-review gate (§6.1) — this producer never consults it.
set -euo pipefail

fail() { printf 'ghjig_file_review_post: %s\n' "$1" >&2; exit 1; }

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

# Own-PR guard (fail closed): the acting identity must be the PR author. A
# self `COMMENT` on someone else's PR is out of this wrapper's mandate.
me=$(gh api user --jq .login 2>/dev/null) || fail "could not resolve acting identity"
[ -n "$me" ] || fail "empty acting identity"
[ "$me" = "$pr_author" ] \
  || fail "refusing: acting identity ($me) is not the PR author ($pr_author) — this wrapper is own-PR only"

owner_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || fail "could not resolve origin repo"
[ -n "$owner_repo" ] || fail "empty origin repo"

# The sanitized review body arrives on stdin (never an inline argument).
body=$(cat)
[ -n "$body" ] || fail "empty review body on stdin"

# Post the self COMMENT review, pinned to the current head. `event=COMMENT` is
# hardcoded; the body travels via `-F body=@-` (read from stdin as a string).
printf '%s' "$body" | gh api "repos/$owner_repo/pulls/$pr_num/reviews" \
  -f commit_id="$head_sha" \
  -f event=COMMENT \
  -F body=@- \
  --jq '{id, commit_id, state, user: .user.login}' \
  || fail "review POST failed"
