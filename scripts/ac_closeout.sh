#!/usr/bin/env bash
# scripts/ac_closeout.sh <pr-num>
#
# For each issue in the PR's closingIssuesReferences, if the issue has
# unchecked AC items AND no `^## AC closeout` header comment, post a
# canonical closeout comment ticking each AC. Idempotent — issues whose
# comments already include the marker are skipped.
#
# Used by /ship step 7.6 to satisfy the PreToolUse `ac-closeout` gate
# (SPEC §6.1) by construction. Safe to run by hand at any time.
#
# Exits 0 on success or all-skipped; non-zero only on transport failure
# (gh unavailable, gh call exits non-zero on a non-skip path).

set -uo pipefail

if [ "${1:-}" = "" ]; then
  echo "usage: ac_closeout.sh <pr-num>" >&2
  exit 2
fi
pr="$1"

command -v gh >/dev/null 2>&1 || { echo "ac_closeout: gh not installed" >&2; exit 1; }

issues=$(gh pr view "$pr" --json closingIssuesReferences -q '.closingIssuesReferences[].number' 2>/dev/null) || {
  echo "ac_closeout: failed to fetch closingIssuesReferences for PR #$pr" >&2
  exit 1
}

if [ -z "$issues" ]; then
  echo "ac_closeout: PR #$pr has no closingIssuesReferences; nothing to do." >&2
  exit 0
fi

while IFS= read -r n; do
  [ -z "$n" ] && continue

  comments=$(gh issue view "$n" --json comments -q '.comments[].body' 2>/dev/null) || {
    echo "ac_closeout: failed to read comments on issue #$n" >&2
    continue
  }
  if printf '%s' "$comments" | grep -q '^## AC closeout'; then
    echo "ac_closeout: issue #$n already has closeout comment; skipping." >&2
    continue
  fi

  body=$(gh issue view "$n" --json body -q .body 2>/dev/null) || {
    echo "ac_closeout: failed to read body on issue #$n" >&2
    continue
  }

  ac_lines=$(printf '%s\n' "$body" | grep -E '^- \[[ x~]\] ' || true)
  if [ -z "$ac_lines" ]; then
    echo "ac_closeout: issue #$n has no AC list; skipping." >&2
    continue
  fi

  # Build the comment: header + each AC line, with `- [ ]` converted to
  # `- [x]`. Preserves `- [~]` (N/A) and already-ticked items verbatim.
  comment="## AC closeout (resolved by PR #${pr})"$'\n\n'
  while IFS= read -r ac; do
    [ -z "$ac" ] && continue
    ticked=$(printf '%s' "$ac" | sed -E 's/^- \[ \] /- [x] /')
    comment="${comment}${ticked}"$'\n'
  done <<< "$ac_lines"
  comment="${comment}"$'\n'"Posted by scripts/ac_closeout.sh per SPEC §5.7.1 step 7.6."

  printf '%s' "$comment" | gh issue comment "$n" --body-file - >/dev/null || {
    echo "ac_closeout: failed to post comment on issue #$n" >&2
    exit 1
  }
  echo "ac_closeout: posted closeout comment on issue #$n" >&2
done <<< "$issues"

exit 0
