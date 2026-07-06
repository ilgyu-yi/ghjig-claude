#!/usr/bin/env bash
# detect_bare_refs_directive.sh — SPEC §10.5 bare-`Refs`-to-default detector (#337).
#
# Sourced by .github/workflows/dir-mode-post-merge.yml (after actions/checkout)
# to flag the #92 leak: directive-scoped work merged to the live default branch
# with an EMPTY closing set (only bare `Refs #N`, no `Closes`), which closes no
# Execution Issue and silently deprives the parent Directive of a reflection.
#
# Lives in the post-merge WORKFLOW (not a `gh pr merge` hook) on purpose: the
# #92 violations were predominantly human GitHub-UI merges, which a PreToolUse
# hook never observes; the merge-triggered workflow fires regardless of merger.
#
# THREE byte-identical copies exist, cmp-locked by smoke §48m-sync (the same
# discipline as resolve_parent_directive.sh, #335):
#   - scripts/lib/detect_bare_refs_directive.sh                              (canonical, CI-linted)
#   - .github/workflows/detect_bare_refs_directive.sh                       (this repo's runtime)
#   - .claude/templates/target-substrate/workflows/detect_bare_refs_directive.sh  (shipped into targets)
#
# Reuses resolve_parent_directive.sh's depth-2 label-aware climb (climb_to_directive)
# — sourced relative to this file so the two stay consistent (#335 depth, not a
# depth-1 reimplementation).

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve_parent_directive.sh"

# detect_bare_refs_directive <pr_num> <repo>
#   Flags iff ALL THREE hold: (1) the PR's base is the live default branch,
#   (2) its closingIssuesReferences is empty, (3) its body carries ≥1 `Refs #N`
#   resolving to a directive-scoped issue (a Directive, or — via the climb — an
#   Execution Issue parented under one). On a flag prints `flag=<csv of offending
#   Refs>` to stdout (suitable for $GITHUB_OUTPUT); otherwise prints nothing.
#   ALWAYS returns 0 — any gh failure resolves to "no flag" (fail-soft), never
#   aborts the workflow. Every gh call carries --repo (runner has no git context).
detect_bare_refs_directive() {
  local pr_num="$1" repo="$2"
  local default base closing body refs n labels d flagged="" count=0

  default=$(gh repo view --repo "$repo" --json defaultBranchRef \
    --jq '.defaultBranchRef.name' 2>/dev/null) || return 0
  [ -n "$default" ] || return 0

  base=$(gh pr view "$pr_num" --repo "$repo" --json baseRefName --jq .baseRefName 2>/dev/null) || return 0
  [ "$base" = "$default" ] || return 0                  # gate 1: base == live default branch

  closing=$(gh pr view "$pr_num" --repo "$repo" --json closingIssuesReferences \
    --jq '.closingIssuesReferences[].number' 2>/dev/null) || return 0
  [ -z "$closing" ] || return 0                         # gate 2: empty closing set

  body=$(gh pr view "$pr_num" --repo "$repo" --json body --jq .body 2>/dev/null) || return 0
  # No `Refs` in the body → empty (the grep pipeline exits non-zero; stay fail-soft
  # rather than relying on the caller's `|| true` under set -euo pipefail).
  refs=$(printf '%s\n' "$body" | grep -oiE 'Refs #[0-9]+' | grep -oE '[0-9]+' | sort -u) || refs=""
  [ -n "$refs" ] || return 0

  # gate 3: at least one Refs target is directive-scoped (own label or climb).
  # A single directive-scoped bare Ref is sufficient to flag, so short-circuit
  # the gh fan-out on the first hit rather than scanning to a fixed position
  # (#553 E5 — the old `count>=5` position cap silently dropped a directive Ref
  # at sorted position 6+, a §10.5 false-negative). The short-circuit keeps the
  # common flagged case cheap regardless of the offending Ref's position; a
  # raised, documented cap still bounds a pathological (50+ unique-Ref) body.
  # shellcheck disable=SC2086  # $refs is a newline-separated list — split intended
  for n in $refs; do
    [ "$count" -ge 50 ] && break                        # bound gh fan-out on a pathological body (raised 5→50, #553 E5)
    count=$((count + 1))
    labels=$(gh issue view "$n" --repo "$repo" --json labels --jq '.labels[].name' 2>/dev/null) || continue
    if printf '%s\n' "$labels" | grep -qx 'directive'; then
      flagged="$flagged $n"
      break
    fi
    d=$(climb_to_directive "$n" "$repo")
    if [ -n "$d" ]; then
      flagged="$flagged $n"
      break
    fi
  done

  if [ -n "$flagged" ]; then
    flagged=$(printf '%s' "$flagged" | sed 's/^ //; s/ /,/g')
    printf 'flag=%s\n' "$flagged"
  fi
  return 0
}
