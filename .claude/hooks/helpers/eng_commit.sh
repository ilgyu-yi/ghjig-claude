# shellcheck shell=bash
# helpers/eng_commit.sh — slot-assembly for the conventional commit subject
# (ADR-0002 GO target; SPEC §10.2). The agent fills slots instead of hand-rolling
# `git commit -m "<type>(#N): …"`. eng_commit assembles the subject, validates it
# via check_commit_subject BEFORE committing, and commits via a bash argv ARRAY
# (multi -m: subject + body paragraphs + optional coauthor trailer) so:
#   - the FIRST -m carries only the subject → the commit-format matcher SEES and
#     accepts it on the happy path (NOT the -F fail-open bypass; git's -m/-F are
#     mutually exclusive anyway);
#   - the array argv (no eval, no string re-quoting) makes multibyte and
#     multi-paragraph bodies round-trip losslessly.
# Positive face; the commit-format hook stays the mandatory net (§6.0 P4).
#
# Public:
#   eng_commit <type> <issue> <subject> [body-paragraph...]
#     rc 0 on commit; nonzero + "eng_commit: <reason>" (no commit) on rejection.
#     The caller passes the Closes #N / Refs #N trailer as a body paragraph
#     (base-dependent — the caller's decision, §10.3/§10.5).

# Resolve the helper dir ONCE at source time (not at call time) so dep-resolution
# stays correct when eng_commit runs from a different cwd (e.g. the target repo it
# commits in) — a call-time `dirname "$BASH_SOURCE"` would resolve a relative
# source path against the wrong cwd.
_ENG_COMMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

eng_commit() {
  if [ "$#" -lt 3 ]; then
    printf 'eng_commit: usage: eng_commit <type> <issue> <subject> [body-paragraph...]\n' >&2
    return 2
  fi
  local type="$1" issue="$2" subject="$3"
  shift 3
  local full="${type}(#${issue}): ${subject}"

  # Resolve deps (sibling helpers) if the caller hasn't already sourced them.
  command -v check_commit_subject >/dev/null 2>&1 || . "$_ENG_COMMIT_DIR/conventional_commit.sh" 2>/dev/null
  command -v coauthor_trailer >/dev/null 2>&1 || . "$_ENG_COMMIT_DIR/coauthor.sh" 2>/dev/null

  # Validate BEFORE committing — surface the failure here with full context,
  # not as an opaque post-hoc hook block.
  local err
  if ! err=$(check_commit_subject "$full" 2>&1); then
    printf 'eng_commit: rejected subject [%s]\n%s\n' "$full" "$err" >&2
    return 1
  fi

  # Build argv as an array: first -m = subject (hook-visible), then one -m per
  # body paragraph, then the coauthor trailer (when enabled) as a final -m.
  local args=(commit -m "$full")
  local para
  for para in "$@"; do
    args+=(-m "$para")
  done
  local co
  co=$(coauthor_trailer 2>/dev/null || true)
  [ -n "$co" ] && args+=(-m "$co")

  git "${args[@]}"
}
