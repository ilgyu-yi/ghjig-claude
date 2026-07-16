#!/usr/bin/env bash
# scripts/release_consolidate.sh — deterministic release work for /release (SPEC §5.20 / §18).
#
# Usage:
#   scripts/release_consolidate.sh <X.Y.Z> [--base <branch>] [--dry-run]
#
# Performs (in order):
#   1. Validate semver 0.x; reject MAJOR>0 with explicit invariant message.
#   2. Preflight: clean working tree; (real mode) checkout base + pull;
#      check for existing vX.Y.Z tag → exit 0 idempotent.
#   3. Fragment scan + validate: positive-integer stem; bullet contains
#      (#<N>) matching stem; no fragments → exit non-zero.
#   4. VERSION write-back: strip any -dev suffix, write X.Y.Z.
#   5. CHANGELOG.md: prepend `## [X.Y.Z] — YYYY-MM-DD (UTC)` section
#      with `### <Category>` subheadings per Keep-a-Changelog.
#   6. `git rm` consumed fragments.
#   7. `git add VERSION CHANGELOG.md`.
#   8. Exit 0.
#
# The skill (`.claude/commands/release.md`) then creates the
# `release/X.Y.Z` branch, commits the staged diff (under the documented
# SKIP_HOOKS=branch escape), and opens the draft PR. This helper does
# NOT branch, commit, push, or call `gh`.
#
# --dry-run: skip remote-dependent preflight (git fetch); local tag
# check still runs. Useful for smoke. Produces the same staged tree
# real mode does.

set -uo pipefail

VERSION_ARG=""
BASE="main"
DRY_RUN=0

# Resolve + source the stack/version detector for the §18.2 manifest-match preflight
# (#469). The path is fixed from BASH_SOURCE before any cd; detect_stack.sh is pure
# (function defs only, no side effects), and absence degrades the preflight to a skip.
_RC_DETECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)/.claude/hooks/helpers/detect_stack.sh"
# shellcheck source=/dev/null
[ -f "$_RC_DETECT" ] && . "$_RC_DETECT"

usage() {
  echo "usage: $0 <X.Y.Z> [--base <branch>] [--dry-run]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      shift
      BASE="${1:-}"
      [ -z "$BASE" ] && { usage; exit 2; }
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "release_consolidate: unknown flag: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [ -z "$VERSION_ARG" ]; then
        VERSION_ARG="$1"
      else
        echo "release_consolidate: unexpected positional: $1" >&2
        usage
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$VERSION_ARG" ]; then
  usage
  exit 2
fi

# Step 1 — semver validation.
# MAJOR=0 invariant per SPEC §3.5 / §18.2.
if ! printf '%s' "$VERSION_ARG" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "release_consolidate: '$VERSION_ARG' is not valid semver (X.Y.Z form expected)" >&2
  exit 2
fi
MAJOR="${VERSION_ARG%%.*}"
if [ "$MAJOR" != "0" ]; then
  echo "release_consolidate: '$VERSION_ARG' violates MAJOR=0 invariant (SPEC §3.5 / §18.2)" >&2
  echo "release_consolidate: bumps out of 0.x are deferred until the first non-self adopter (Directive #122)" >&2
  exit 2
fi
X_Y_Z="$VERSION_ARG"
TAG="v$X_Y_Z"

# Step 2 — preflight.
# Must be in a git repo.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "release_consolidate: not in a git repository" >&2
  exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT" || { echo "release_consolidate: cannot cd to repo root '$REPO_ROOT'" >&2; exit 2; }

# Working tree must be clean (no unstaged + no staged changes).
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "release_consolidate: working tree has uncommitted changes; run 'git reset --hard HEAD' to retry" >&2
  exit 2
fi

# (real mode) fetch + checkout base + pull. --dry-run skips network.
if [ "$DRY_RUN" = 0 ]; then
  if ! git fetch origin >/dev/null 2>&1; then
    echo "release_consolidate: git fetch origin failed" >&2
    exit 2
  fi
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$CURRENT_BRANCH" != "$BASE" ]; then
    if ! git checkout "$BASE" >/dev/null 2>&1; then
      echo "release_consolidate: cannot checkout base branch '$BASE'" >&2
      exit 2
    fi
  fi
  if ! git pull --ff-only origin "$BASE" >/dev/null 2>&1; then
    echo "release_consolidate: git pull --ff-only origin $BASE failed" >&2
    exit 2
  fi
  # Refuse if release/X.Y.Z branch already exists on origin.
  if git ls-remote --heads origin "release/$X_Y_Z" 2>/dev/null | grep -q .; then
    echo "release_consolidate: release/$X_Y_Z branch already exists on origin" >&2
    exit 2
  fi
fi

# Idempotency: local tag check (works in dry-run too).
if git tag -l "$TAG" | grep -qx "$TAG"; then
  echo "release_consolidate: $TAG already released (no-op)"
  exit 0
fi

# Step 3 — fragment scan + validate.
# Two passes — first validates all fragments + counts; second emits per category.
# Avoids bash-4 associative arrays for macOS bash 3.2 compatibility.
CATEGORIES="added changed deprecated removed fixed security"
FRAGMENT_DIR="changelog_unreleased"
if [ ! -d "$FRAGMENT_DIR" ]; then
  echo "release_consolidate: no $FRAGMENT_DIR/ directory in repo root" >&2
  exit 2
fi

list_category_fragments() {
  # Print sorted *.md fragment paths for a category, one per line.
  local cat_dir="$1"
  [ -d "$cat_dir" ] || return 0
  find "$cat_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort -V
}

FRAGMENTS_FOUND=0
ALL_FRAGMENTS_LIST=""  # newline-separated; safe paths (filenames are integers).

# First pass — validate every fragment + collect master list.
for cat in $CATEGORIES; do
  cat_dir="$FRAGMENT_DIR/$cat"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    base=$(basename "$f" .md)
    if ! printf '%s' "$base" | grep -qE '^[1-9][0-9]*$'; then
      echo "release_consolidate: $f — filename stem '$base' is not a positive integer" >&2
      exit 2
    fi
    if ! grep -qF "(#$base)" "$f"; then
      echo "release_consolidate: $f — bullet missing or mismatched (#$base) reference (stem '$base')" >&2
      exit 2
    fi
    # Leading "- " bullet form (contract parity with check-changelog.yml; #303).
    if ! grep -qE '^- ' "$f"; then
      echo "release_consolidate: $f — fragment must be a single-line bullet beginning with '- ' (stem '$base')" >&2
      exit 2
    fi
    FRAGMENTS_FOUND=$((FRAGMENTS_FOUND + 1))
    ALL_FRAGMENTS_LIST="$ALL_FRAGMENTS_LIST$f
"
  done <<EOF
$(list_category_fragments "$cat_dir")
EOF
done

if [ "$FRAGMENTS_FOUND" -eq 0 ]; then
  echo "release_consolidate: no fragments found under $FRAGMENT_DIR/<category>/*.md" >&2
  echo "release_consolidate: nothing to release; add a fragment first or this is not the right operation" >&2
  exit 2
fi

# Step 3.5 — manifest-match preflight (verify, not write-back; SPEC §18.2 / §6.6, #469).
# Read-only: resolve the detected stack's native manifest version and refuse on a
# CONFIDENT mismatch (naming both versions + the fix); degrade to a graceful skip on the
# UNCERTAIN path (unknown stack / absent / unparseable). It never writes the manifest —
# write-back stays VERSION-only (§18.2). Runs in REPO_ROOT (cwd), where manifests live.
if command -v detect_version >/dev/null 2>&1; then
  MANIFEST_VER=$(detect_version 2>/dev/null || true)
  if [ -n "$MANIFEST_VER" ]; then
    if [ "$MANIFEST_VER" = "$X_Y_Z" ]; then
      echo "release_consolidate: manifest version matches $X_Y_Z (manifest-match preflight ok)"
    else
      echo "release_consolidate: manifest version is $MANIFEST_VER but releasing $X_Y_Z — bump the manifest to match before releasing (SPEC §18.2)" >&2
      exit 2
    fi
  else
    echo "release_consolidate: no detectable manifest version for this stack — skipping manifest-match preflight (SPEC §18.2)" >&2
  fi
fi

# Step 4 — VERSION write-back.
if [ ! -f VERSION ]; then
  echo "release_consolidate: VERSION file not found at repo root" >&2
  exit 2
fi
printf '%s\n' "$X_Y_Z" > VERSION

# Step 5 — CHANGELOG.md prepend.
if [ ! -f CHANGELOG.md ]; then
  echo "release_consolidate: CHANGELOG.md not found at repo root" >&2
  exit 2
fi

DATE_UTC=$(date -u +%Y-%m-%d)
NEW_SECTION_FILE=$(mktemp)
{
  printf '## [%s] — %s\n\n' "$X_Y_Z" "$DATE_UTC"
  for cat in $CATEGORIES; do
    cat_dir="$FRAGMENT_DIR/$cat"
    # Re-enumerate per category to preserve sort order without holding maps.
    cat_files=$(list_category_fragments "$cat_dir")
    [ -z "$cat_files" ] && continue
    cat_cap=$(printf '%s' "$cat" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
    printf '### %s\n\n' "$cat_cap"
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      cat "$f"
      # Ensure trailing newline after the bullet.
      last_char=$(tail -c1 "$f")
      [ "$last_char" = "" ] || [ "$last_char" = $'\n' ] || printf '\n'
    done <<EOF
$cat_files
EOF
    printf '\n'
  done
} > "$NEW_SECTION_FILE"

# Prepend NEW_SECTION_FILE content before the first `## [` heading in CHANGELOG.md.
# Fallback: if no `## [` heading exists yet (pristine CHANGELOG with just the file
# header), append at end-of-file. The inaugural section landed by #129 / PR #130
# means `## [0.1.0]` always exists in practice; the EOF fallback is for the very
# first release ever cut in an adopting repo whose CHANGELOG only has the header.
CHANGELOG_NEW=$(mktemp)
awk -v new_section_file="$NEW_SECTION_FILE" '
  BEGIN { inserted = 0 }
  /^## \[/ && !inserted {
    while ((getline line < new_section_file) > 0) print line
    close(new_section_file)
    inserted = 1
  }
  { print }
  END {
    if (!inserted) {
      while ((getline line < new_section_file) > 0) print line
      close(new_section_file)
    }
  }
' CHANGELOG.md > "$CHANGELOG_NEW"
mv "$CHANGELOG_NEW" CHANGELOG.md
rm -f "$NEW_SECTION_FILE"

# Append reference link at footer (best-effort). Resolve the host + owner/repo
# HOST-GENERICALLY (#614) so a GHES origin yields a repo-host link, not a hardcoded
# github.com one. Prefer gh's normalized url (the #610 idiom); fall back to a
# host-generic origin parse when gh is unavailable. Fail CLOSED on an unusable host
# — omit the link rather than emit a wrong-host URL.
REL_HOST=""
REL_OWNER_REPO=""
if command -v gh >/dev/null 2>&1; then
  REPO_URL=$(gh repo view --json url --jq .url 2>/dev/null || echo "")
  if [ -n "$REPO_URL" ]; then
    REL_HOST=${REPO_URL#*://}; REL_HOST=${REL_HOST#*@}; REL_HOST=${REL_HOST%%/*}
    REL_OWNER_REPO=${REPO_URL#*://}; REL_OWNER_REPO=${REL_OWNER_REPO#*@}
    REL_OWNER_REPO=${REL_OWNER_REPO#*/}; REL_OWNER_REPO=${REL_OWNER_REPO%.git}
  fi
fi
if [ -z "$REL_HOST" ] || [ -z "$REL_OWNER_REPO" ]; then
  # Host-generic origin parse (NOT github.com-specific): strip scheme, userinfo,
  # then the leading host[:/] — handles git@host:owner/repo.git and https://host/owner/repo.git.
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if [ -n "$ORIGIN_URL" ]; then
    REL_HOST=$(printf '%s' "$ORIGIN_URL" | sed -E 's#^[^/]*//##; s#^[^@]*@##; s#[:/].*$##')
    REL_OWNER_REPO=$(printf '%s' "$ORIGIN_URL" | sed -E 's#^[^/]*//##; s#^[^@]*@##; s#[^/:]+[:/]##; s#\.git$##')
  fi
fi
# Charset/non-empty guard on the derived host (fail closed).
case "$REL_HOST" in
  ''|*[!A-Za-z0-9.:-]*) REL_HOST="" ;;
esac
if [ -n "$REL_HOST" ] && [ -n "$REL_OWNER_REPO" ]; then
  printf '\n[%s]: https://%s/%s/releases/tag/%s\n' "$X_Y_Z" "$REL_HOST" "$REL_OWNER_REPO" "$TAG" >> CHANGELOG.md
fi

# Step 6 — git rm consumed fragments. Guard each rm (#218): the script is
# `set -uo pipefail` (no -e), so a swallowed `git rm` failure would let the
# script report success while a consumed fragment lingers on disk (the next
# release would double-consume it).
while IFS= read -r f; do
  [ -z "$f" ] && continue
  git rm -q "$f" || { echo "release_consolidate: git rm failed for $f" >&2; exit 2; }
done <<EOF
$ALL_FRAGMENTS_LIST
EOF

# Step 7 — stage VERSION + CHANGELOG.md.
git add VERSION CHANGELOG.md || { echo "release_consolidate: git add failed for VERSION/CHANGELOG.md" >&2; exit 2; }

# Step 8 — output summary.
echo "release_consolidate: $X_Y_Z staged ($FRAGMENTS_FOUND fragments consolidated)"
echo "release_consolidate: VERSION: $X_Y_Z"
echo "release_consolidate: CHANGELOG.md: new ## [$X_Y_Z] — $DATE_UTC section prepended"
echo "release_consolidate: fragments removed: $FRAGMENTS_FOUND"
if [ "$DRY_RUN" = 1 ]; then
  echo "release_consolidate: --dry-run; no commit, no branch, no push"
fi
exit 0
