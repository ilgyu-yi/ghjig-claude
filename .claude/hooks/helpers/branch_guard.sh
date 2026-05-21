# helpers/branch_guard.sh — protected-branch checks. Source from hooks.
#
# Depends on $PROTECTED_BRANCH_PATTERN from helpers/git_matcher.sh — every
# caller of branch_guard.sh in the shell already sources git_matcher.sh
# (it provides GIT_PREFIX), but we source it idempotently here so future
# standalone callers don't silently degrade.
# shellcheck disable=SC1090,SC1091
. "$(dirname "${BASH_SOURCE[0]}")/git_matcher.sh"

# Static-name subset of the protected branches — the names that exist
# without a glob (i.e. `main`, `master`). Used by detached-HEAD tip-equality
# enumeration where for-each-ref is overkill. If you add a new static name
# here, also add it to PROTECTED_BRANCH_* in helpers/git_matcher.sh.
_protected_static_refs() {
  printf '%s\n' main master
}

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
  for ref in $(_protected_static_refs); do
    tip=$(_resolve_protected_ref "$ref") || continue
    if [ -n "$tip" ] && [ "$tip" = "$head_sha" ]; then
      printf 'HEAD@%s (detached, == %s)' "$short" "$ref"
      return
    fi
  done
  # `refs/heads/release/*` mirrors the `release/*` segment of
  # PROTECTED_BRANCH_CASE_GLOB in helpers/git_matcher.sh. If you change the
  # glob there, update this refspec too.
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
  if [ -n "$b" ] && printf '%s' "$b" | grep -qE "^(${PROTECTED_BRANCH_PATTERN})$"; then
    return 0
  fi
  # Detached HEAD (no symbolic ref): compare HEAD's SHA against the tip
  # SHA of each protected branch. main/master are constant names; release/*
  # is enumerated via for-each-ref so any branch under that prefix counts.
  if [ -z "$b" ]; then
    local head_sha tip
    head_sha=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
    for ref in $(_protected_static_refs); do
      tip=$(_resolve_protected_ref "$ref") || continue
      [ -n "$tip" ] && [ "$tip" = "$head_sha" ] && return 0
    done
    # Enumerate release/* tips. Glob mirrors PROTECTED_BRANCH_CASE_GLOB.
    while IFS= read -r tip; do
      [ -n "$tip" ] && [ "$tip" = "$head_sha" ] && return 0
    done < <(git for-each-ref --format='%(objectname)' 'refs/heads/release/*' 2>/dev/null)
  fi
  return 1
}
