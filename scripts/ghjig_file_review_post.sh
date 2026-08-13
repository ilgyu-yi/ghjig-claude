#!/usr/bin/env bash
# scripts/ghjig_file_review_post.sh — post a self `COMMENT` review to the CURRENT
# branch's own PR, pinned to its head, carrying the sanitized review body that
# `/file-review` wrote itself to the fixed out-of-band staging file
# `<esd>/file-review/staging` (SPEC §5.7.1 "Second exception — the self-review
# producer", §5.29; #598, #602, #633).
#
# This is the single `permissions.allow`-covered surface that lets an unattended
# `/ship` post its own head-pinned review: the auto-mode classifier defers this
# fixed-form command to the shell instead of blocking the raw
# `gh api .../pulls/<n>/reviews` self-approve POST as self-approval. The allow
# entry is the exact, wildcard-free `Bash(.claude/ghjig-root/scripts/ghjig_file_review_post.sh)`.
#
# THE PRODUCER IS ONE LINK, NOT TWO (#633). The caller writes the staging file;
# there is no separate writer script and the staged file carries no header stamps
# — it holds the sanitized body and nothing else. That matters for the capability
# boundary: the retired writer's only job was translating a *variable* tempfile
# path into the fixed path read below, and the only allow form that could have
# covered a variable argv was a prefix wildcard, which would have auto-approved an
# arbitrary-path read whose content this wrapper publishes verbatim. With the argv
# gone, no shell script in the tree can be pointed at an arbitrary path.
#
# The wrapper IS the capability boundary — even invoked adversarially it can only
# post a self `COMMENT` on the acting identity's OWN current-branch PR:
#   - no positional args (it resolves the current-branch PR itself, mirroring
#     `gh pr merge --auto`, so the allow entry needs no trailing wildcard) and it
#     stays invocable BARE — no stdin pipe, so the classifier keeps deferring it;
#   - the body is read from the fixed staging file, invisible to the permission
#     matcher — NOT stdin (a bare covered command cannot be fed stdin);
#   - `event=COMMENT` is hardcoded — never APPROVE/REQUEST_CHANGES;
#   - an own-PR guard fails closed unless the acting identity == the PR author.
#
# What is NOT retired: this wrapper still posts the staged body VERBATIM apart
# from the marker/head bind, so body sanitization remains the caller's job
# (§5.29) and the review-body egress channel is open, not closed — a tracked
# residual owned by #634.
#
# Whether the produced self-review is then HONORED is a separate per-target
# decision (`resolve_self_review_policy` / `.claude/state/self-review`, §5.7.1)
# read by the merge-review gate (§6.1) — this producer never consults it.
set -euo pipefail

fail() { printf 'ghjig_file_review_post: %s\n' "$1" >&2; exit 1; }

# deny <arm> <message> — a fail-closed reject with NO POST, plus its audit line.
# The audit record is the block's deferred positive face (MISSION.md:18): without
# it every arm below is an invisible block. Two mechanism details are
# load-bearing. (a) `audit_log` resolves its log via `ghjig_state_dir`, NOT
# `ghjig_state_dir_cli` — and a Bash-tool subprocess commonly runs with
# CLAUDE_PROJECT_DIR unset, so without the explicit prefix below the record
# would land on the legacy shared path (or nowhere) instead of the per-project
# log this wrapper just resolved (SPEC §3.2.2). (b) The call is subshelled and
# `|| true`-guarded: under `set -euo pipefail` a non-zero `audit_log` must never
# convert a fail-closed reject into anything other than a clean refusal.
# The reason carries the ARM NAME ONLY — an audit line echoing the body would
# re-publish, into the log, exactly the content the reject withheld.
deny() {
  local arm="$1" msg="$2"
  if command -v audit_log >/dev/null 2>&1; then
    ( export CLAUDE_PROJECT_DIR="${esd%/.claude/ghjig-state}"; audit_log info file-review rejected "reason=$arm" ) >/dev/null 2>&1 || true
  fi
  printf 'ghjig_file_review_post: %s — fail closed, no POST\n' "$msg" >&2
  exit 1
}

# Portable mtime read (the repo's established idiom — session_start.sh:114-116,
# helpers/status.sh:35-37). A platform with NEITHER branch returns non-zero so the
# caller fails closed; it must never silently skip the TTL.
fr_mtime() {
  local f="$1" m
  if m=$(stat -c %Y "$f" 2>/dev/null); then printf '%s' "$m"; return 0; fi
  if m=$(stat -f %m "$f" 2>/dev/null); then printf '%s' "$m"; return 0; fi
  return 1
}

esd=""

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

# The sanitized review body arrives via the fixed staging file the CALLER wrote
# (#633), never stdin, an inline argument, or a writer script. It is resolved
# through the SAME shared ghjig_state_dir_cli() the caller resolves.
command -v ghjig_state_dir_cli >/dev/null 2>&1 \
  || fail "ghjig_state_dir_cli unavailable (hookrt.sh not sourced)"
esd=$(ghjig_state_dir_cli 2>/dev/null) || esd=""
[ -n "$esd" ] || fail "could not resolve per-project state dir"
frdir="$esd/file-review"
sf="$frdir/staging"

# Symlink guards — BOTH the leaf AND the `file-review` directory component. The
# mtime reads below default to `lstat` on BSD and GNU alike, so a symlink reports
# the LINK's fresh mtime while the content read follows to an arbitrary target and
# `[ -r ]` / `[ -s ]` / `[ -f ]` all pass. Guarding the leaf alone is provably
# insufficient: with the parent a symlink the leaf is a genuine regular file. The
# retired writer's atomic rename was the only structural regular-file guarantee at
# this read path, so these checks replace it. Two cases stay deliberately
# unguarded and are disclosed in SPEC §5.7.1 rather than fixed: a hardlinked
# staging file (nlink > 1), and a symlinked ancestor above the `file-review`
# component.
[ ! -L "$frdir" ] || deny symlink-dir "staging directory component is a symlink ($frdir)"
[ ! -L "$sf" ]    || deny symlink-leaf "staging file is a symlink ($sf)"

# Fail closed BEFORE any read if the staging file is absent/irregular/unreadable/
# empty. The absent message NAMES THE ABSOLUTE PATH so a caller/wrapper path
# divergence is a diagnosable error rather than a silent park (SPEC §5.7.1).
[ -e "$sf" ] || deny staging-absent "no staged review body at $sf (nothing was written there)"
[ -f "$sf" ] || deny staging-irregular "staged review body is not a regular file ($sf)"
[ -r "$sf" ] || deny staging-unreadable "staged review body is unreadable ($sf)"
[ -s "$sf" ] || deny staging-empty "empty staged review body ($sf)"

# stat -> slurp -> stat (equal) -> one-shot unlink -> validate -> POST.
# The mtime is read BEFORE the slurp and AGAIN after it, and the two must be
# equal: without the second read the freshness check would attest to a file a
# concurrent rewrite could have replaced between the check and the read — i.e. to
# bytes other than the ones posted.
mt1=$(fr_mtime "$sf") || deny mtime-unresolvable "could not read the staging file mtime on this platform ($sf)"
staged=$(cat "$sf")
mt2=$(fr_mtime "$sf") || deny mtime-unresolvable "could not re-read the staging file mtime on this platform ($sf)"
[ "$mt1" = "$mt2" ] \
  || deny mtime-changed "staging file mtime changed during the read ($mt1 != $mt2) — the freshness check would not cover the posted bytes"

# One-shot unlink IMMEDIATELY after the slurp+re-stat and BEFORE validation and
# the POST. Unlinking here is poison cleanup (every validation reject below
# therefore leaves no sanitized body at rest) and it forecloses a TOCTOU in which
# a concurrent rewrite makes this wrapper post twice.
rm -f "$sf"

# Freshness — the TTL rides the staging file's mtime, since the caller IS the
# writer and mtime therefore IS write time (#633). A future-dated mtime is its
# OWN reject arm: `now - mt <= 60` alone passes for one.
# The `0*` arm is load-bearing, not defensive: a leading-zero epoch makes the
# TTL's $(( )) raise "value too great for base", and an arithmetic expansion
# failure SKIPS the whole `[ … ] || deny` list instead of failing it — so the
# freshness check is never evaluated and execution falls through to the POST.
# Reasoning that `stat` never emits a leading zero is not a substitute for the
# guard: the guard is what makes that assumption non-load-bearing.
#
# The fall-through is SCRIPT-FILE-specific, which is why it is easy to test wrong.
# Reproduced at head: run as a script file the arithmetic error prints and control
# continues past the TTL to the POST (exit 0); the same statements under `bash -c`
# abort instead (exit 1). So a `bash -c` probe shows the SAFE behaviour and would
# invite deleting this arm a second time. Reproduce in a script file, or not at all.
case "$mt1" in ''|0*|*[!0-9]*) deny mtime-malformed "implausible staging file mtime ($mt1) — re-stage the body so its mtime is a plain epoch" ;; esac
[ "${#mt1}" -le 11 ] || deny mtime-malformed "implausible staging file mtime ($mt1)"
now=$(date +%s)
[ "$mt1" -le "$now" ] || deny mtime-future "future-dated staging file (mtime $mt1 > now $now)"
[ "$(( now - mt1 ))" -le 60 ] || deny stale "stale staged review body (mtime older than the 60s TTL) — re-write the staging file and re-invoke this wrapper within 60s"

# Marker accept set (SPEC §5.29): count canonical markers with the BYTE-IDENTICAL
# regex the merge-side consumer uses (`helpers/ac_closeout_gate.sh`) and require
# EXACTLY ONE. Sharing the literal is the anti-drift mechanism — a looser producer
# parse would POST a body the merge gate then rejects, moving the park from the
# free pre-POST side to the unretractable published-review side.
markers=$(printf '%s' "$staged" \
  | grep -oE '<!-- file-review verdict=[A-Za-z]+ head=[^[:space:]]+ reviewer=code-reviewer -->' 2>/dev/null) || markers=""
marker_count=0
[ -n "$markers" ] && marker_count=$(printf '%s\n' "$markers" | grep -c .)
[ "$marker_count" = 1 ] \
  || deny marker-count "staged body carries $marker_count canonical file-review markers, expected exactly 1 — re-write the staging file with exactly one canonical marker and re-invoke"

# Head-staleness guard — RETAINED, not subsumed by the single step (SPEC §5.7.1).
# The window it covers is the WHOLE review, not the retired stage-to-post split: a
# foreign push (a concurrent agent, a human push, GitHub's "Update branch") that
# advances the PR head after `/file-review` computed its head would otherwise let
# this wrapper pin `commit_id` to a head no reviewer ever saw, and `merge-review`
# reads `commit_id` off the review object and only `verdict` from the marker.
# Arm 1 — the marker's head= IS the remote head the review was performed against.
marker_head=$(printf '%s' "$markers" | sed -nE 's/.*head=([^[:space:]]+) reviewer=.*/\1/p')
[ -n "$marker_head" ] || deny marker-head-absent "could not read head= from the staged body's marker — re-write the marker in the canonical form and re-invoke"
[ "$marker_head" = "$head_sha" ] \
  || deny marker-head-mismatch "marker head ($marker_head) != resolved PR head ($head_sha) — the PR head advanced since the review; re-run /file-review at the new head"
# Arm 2 — the shell-authored belt: the local checkout must sit on that same head.
# This is exactly what the retired stamp compared. Both arms are STALENESS guards,
# not anti-forge: the marker is agent-authored, so anti-forge integrity stays at
# the `merge-review` gate.
local_head=$(git rev-parse HEAD 2>/dev/null) || local_head=""
[ -n "$local_head" ] || deny local-head-unresolvable "could not resolve the local git HEAD — run from inside the PR's checkout and re-invoke"
[ "$local_head" = "$head_sha" ] \
  || deny local-head-mismatch "local HEAD ($local_head) != resolved PR head ($head_sha) — check out the PR head (git pull --ff-only) and re-invoke"

# Post the self COMMENT review, pinned to the current head. `event=COMMENT` is
# hardcoded; the in-memory body travels via `-F body=@-` (read as a string).
printf '%s' "$staged" | gh api "repos/$owner_repo/pulls/$pr_num/reviews" \
  --hostname "$h" \
  -f commit_id="$head_sha" \
  -f event=COMMENT \
  -F body=@- \
  --jq '{id, commit_id, state, user: .user.login}' \
  || fail "review POST failed"
