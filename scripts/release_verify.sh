#!/usr/bin/env bash
# scripts/release_verify.sh <X.Y.Z> — post-merge release verification (#471, Directive
# #468; SPEC §18.2 / §6.0). READ-ONLY and FAIL-OPEN: it confirms the `vX.Y.Z` tag exists
# and a GitHub Release with NON-EMPTY notes is present (one `gh release view --json
# tagName,body` query), printing a named advisory line on a missing tag / missing-or-
# empty-notes Release. It NEVER creates anything and EXITS 0 on every path (gh error /
# offline → one advisory line), so it observes the release result without blocking the
# flow — the verification-only / never-false-block posture. Run after the post-merge
# `gh release create` (by the maintainer or the /ship unattended continuation).

set -uo pipefail

X_Y_Z="${1:-}"
if [ -z "$X_Y_Z" ]; then
  echo "release_verify: usage: release_verify.sh <X.Y.Z>" >&2
  exit 2
fi
if ! printf '%s' "$X_Y_Z" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "release_verify: '$X_Y_Z' is not valid semver (X.Y.Z expected)" >&2
  exit 2
fi
TAG="v$X_Y_Z"

# Fail-open: no gh → skip the verify (advisory, never a block).
if ! command -v gh >/dev/null 2>&1; then
  echo "release_verify: gh not on PATH — skipping post-merge verify for $TAG" >&2
  exit 0
fi

_rv_out=$(mktemp); _rv_err=$(mktemp)
gh release view "$TAG" --json tagName,body >"$_rv_out" 2>"$_rv_err"
rv_rc=$?
rv_out=$(cat "$_rv_out" 2>/dev/null || true)
rv_err=$(cat "$_rv_err" 2>/dev/null || true)
rm -f "$_rv_out" "$_rv_err"

if [ "$rv_rc" -ne 0 ]; then
  # Distinguish "release/tag absent" from a generic gh failure (offline/auth). Grep BOTH
  # streams so it is robust to which one gh writes the message to.
  if printf '%s\n%s' "$rv_out" "$rv_err" | grep -qi 'not found\|no release'; then
    echo "release_verify: no Release found for $TAG — the post-merge \`gh release create\` may not have run" >&2
  else
    echo "release_verify: could not query gh for the $TAG Release (offline or unauthenticated?) — skipping verify" >&2
  fi
  exit 0
fi

# gh succeeded — confirm the notes are non-empty (the tag is implied by a present Release).
# jq is the only way to read the `body` field; if it is absent OR fails to run, we cannot
# read the notes, so fail-open with an advisory (mirroring the gh-absent guard at :25) rather
# than letting `body` stay empty and firing a false "empty notes" advisory (#473).
if ! command -v jq >/dev/null 2>&1; then
  echo "release_verify: jq not on PATH — cannot read the $TAG Release notes; skipping the notes check" >&2
  exit 0
fi
body=$(printf '%s' "$rv_out" | jq -r '.body // empty' 2>/dev/null)
if [ "$?" -ne 0 ]; then
  echo "release_verify: jq could not parse the $TAG Release payload — skipping the notes check" >&2
  exit 0
fi
if [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
  echo "release_verify: $TAG ok (tag + Release with notes present)"
else
  echo "release_verify: $TAG Release has empty notes — the CHANGELOG section did not reach the Release page" >&2
fi
exit 0
