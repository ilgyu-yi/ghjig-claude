# shellcheck shell=bash
# helpers/branch_guard.sh — protected-branch checks. Source from hooks.
#
# Depends on $PROTECTED_BRANCH_PATTERN from helpers/git_matcher.sh — every
# caller of branch_guard.sh in the shell already sources git_matcher.sh
# (it provides GIT_PREFIX), but we source it idempotently here so future
# standalone callers don't silently degrade. Helper-to-helper sources
# go through `safe_source` per SPEC §6.1 — the on-miss warn fires from
# this site too, surfacing the second consumer (#36).
# shellcheck disable=SC1090,SC1091
safe_source "$(dirname "${BASH_SOURCE[0]}")/git_matcher.sh" commit-format || true

# Returns the current branch name, or the empty string if HEAD is detached.
# Callers that need a human-readable label (including detached-HEAD context)
# should use branch_label instead.
current_branch() {
  git symbolic-ref --short HEAD 2>/dev/null || echo ""
}

# Resolve the SHA of a protected ref, or empty if it doesn't exist.
_resolve_protected_ref() {
  git rev-parse --verify --quiet "refs/heads/$1" 2>/dev/null
}

# Human-readable branch label suitable for hook error messages.
# - Attached: the branch name.
# - Detached on a protected tip: `HEAD@<short> (detached, == <ref>)`.
# - Detached elsewhere: `HEAD@<short> (detached)`.
# - No HEAD (empty repo): empty string.
branch_label() {
  local b
  b=$(current_branch)
  if [ -n "$b" ]; then
    printf '%s' "$b"
    return
  fi
  local head_sha short tip
  head_sha=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || { printf ''; return; }
  short=$(git rev-parse --short HEAD 2>/dev/null) || short="${head_sha:0:7}"
  local ref
  # Static-name subset: `main`/`master` are constant; release/* is enumerated
  # by the for-each-ref below. If you add a new static protected name, also
  # extend PROTECTED_BRANCH_PATTERN in helpers/git_matcher.sh.
  for ref in main master; do
    tip=$(_resolve_protected_ref "$ref") || continue
    if [ -n "$tip" ] && [ "$tip" = "$head_sha" ]; then
      printf 'HEAD@%s (detached, == %s)' "$short" "$ref"
      return
    fi
  done
  # `refs/heads/release/*` mirrors the release/* segment of
  # PROTECTED_BRANCH_PATTERN in helpers/git_matcher.sh. If you change the
  # ERE there, update this refspec too.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    tip="${line%% *}"
    ref="${line#* }"
    if [ "$tip" = "$head_sha" ]; then
      printf 'HEAD@%s (detached, == %s)' "$short" "$ref"
      return
    fi
  done < <(git for-each-ref --format='%(objectname) %(refname:short)' 'refs/heads/release/*' 2>/dev/null)
  printf 'HEAD@%s (detached)' "$short"
}

# Returns 0 (true) when:
# - the named branch is in the protected set, OR
# - HEAD is detached and its SHA equals the tip of any protected branch.
# The detached-tip check covers `git checkout <main-sha>` mistakes that
# the symbolic-ref-only matcher silently allowed.
is_protected_branch() {
  local b="${1:-$(current_branch)}"
  # Pattern test against the SSOT. grep -qE forks once; is_protected_branch
  # is called at most a few times per hook invocation, so the cost is
  # tolerable. (Bash's built-in `[[ =~ ]]` is POSIX-ERE-only and rejects
  # the `\S` shorthand used in PROTECTED_BRANCH_PATTERN; staying with grep
  # keeps the ERE flavor consistent across all matchers in the codebase.)
  # #555 A7: case-INSENSITIVE (`-i`), for parity with the force-push arm's
  # `grep -qiE` protected-token check. On a case-insensitive filesystem a
  # `Main`/`MASTER` checkout resolves to the same ref as `main`/`master`, so a
  # case-sensitive test here left the edit/commit gates blind to that branch —
  # a fail-open. `-i` closes it (tightens the block-path; never widens allow).
  if [ -n "$b" ] && printf '%s' "$b" | grep -qiE "^(${PROTECTED_BRANCH_PATTERN})$"; then
    return 0
  fi
  # Detached HEAD (no symbolic ref): compare HEAD's SHA against the tip
  # SHA of each protected branch. main/master are constant names; release/*
  # is enumerated via for-each-ref so any branch under that prefix counts.
  if [ -z "$b" ]; then
    local head_sha tip
    head_sha=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
    for ref in main master; do
      tip=$(_resolve_protected_ref "$ref") || continue
      [ -n "$tip" ] && [ "$tip" = "$head_sha" ] && return 0
    done
    # Enumerate release/* tips. Glob mirrors the release/* segment of
    # PROTECTED_BRANCH_PATTERN in helpers/git_matcher.sh.
    while IFS= read -r tip; do
      [ -n "$tip" ] && [ "$tip" = "$head_sha" ] && return 0
    done < <(git for-each-ref --format='%(objectname)' 'refs/heads/release/*' 2>/dev/null)
  fi
  return 1
}
