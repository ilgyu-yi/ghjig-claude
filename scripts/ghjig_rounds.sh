#!/usr/bin/env bash
# scripts/ghjig_rounds.sh — the rounds instrument: Directive #637 item 7's
# reporter (#721). It prints the review-round count per PR and the sequence as
# a trend, so the Directive's motivating metric is READ AT RUNTIME rather than
# asserted from memory (§1.11 L2). This header is the contract's single code
# home (the §4.13 pattern); the smoke suite's §185 behavior arms are its
# negative face (scripts/test/smoke.d/73-rounds.sh).
#
# It GATES NOTHING: no exit-code consumer, no hook, no CI wiring. Its consumer
# is a human or agent reading the output at a Directive's completion review.
# It is NOT a reject count and neither selects nor preempts Directive #639's
# per-change attribution substrate.
#
# Usage:
#   ghjig_rounds.sh <pr> [<pr>…]   report those PRs, in the order given
#   ghjig_rounds.sh --recent <M>   report the M most recently MERGED PRs
#
# Output (stdout), one line per PR then one trend line:
#   pr=<N> rounds=<K>                  K judged rounds (K=0 when none)
#   pr=<N> rounds=ambiguous(duplicate) the PR's canonical history is ambiguous
#   pr=<N> rounds=error(rc=<rc>)       the derivation failed for this PR
#   trend: <tok> <tok> …               one token per reported PR, in order
#                                      (the digits, or `?` for an ambiguous or
#                                      errored entry — never silently dropped)
#
# Derivation: rounds = (the child's `next=` value) − 1. Rounds are read ONLY
# through a child invocation of the single code home,
# `scripts/ghjig_judged_list.sh rounds <pr>` (located as a sibling of this
# file, never through PATH), which prints `next=` as one more than the highest
# canonical round it found — so `next − 1` IS the ordinal of the last judged
# round, and a lookalike-only history yields 0. This file carries no
# header/marker literal of its own: the canonicity test has one code home and
# this instrument consumes its output contract (§1.11 L4).
#
# Counting the child's `round=` fact lines is deliberately NOT the derivation:
# `post` always mints `next = max + 1`, so live numbering is contiguous and a
# gap can only come from a DELETED marker comment — under which a count
# undercounts (markers {1,3} would report 2). When the fact-line count and
# `next − 1` disagree, that gap is reported as an informational `anomaly:` line
# on stderr; anomaly output is never a fact, never changes a reported round
# count, and never touches the exit code.
#
# Window resolution (`--recent <M>`) is MERGE-ORDERED, which the listing API is
# not: `gh pr list --state merged` returns createdAt-descending, so both the
# membership of a `--limit M` window and the order within it can disagree with
# merge order — a long-lived PR that merged late sits below PRs that merged
# earlier, which would bias the very trend this instrument reports. So the
# window is over-fetched, sorted by `mergedAt` descending, cut to M, and
# emitted oldest→newest. The resolution command, verbatim:
#
#   gh pr list --state merged --limit <over-fetch> --json number,mergedAt
#
# On the explicit-list route the caller owns the order: the trend is printed in
# the order the PR arguments were given, merge-ordered only if the caller made
# it so.
#
# Exit codes: 0 whenever the sweep ran — a PR whose derivation failed is
# REPORTED, never fatal (fail-open reporter) · 1 usage error, or a `--recent`
# window that could not be resolved at all. Nothing here fails closed: this is
# an advisory reporter, and evidence/gates elsewhere keep their own posture.
set -euo pipefail

PROG="ghjig_rounds"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-1}"; }

usage() {
  cat >&2 <<'EOF'
usage: ghjig_rounds.sh <pr> [<pr>...]   report those PRs in the order given
       ghjig_rounds.sh --recent <M>     report the M most recently merged PRs
output: one `pr=<N> rounds=<K|ambiguous(duplicate)|error(rc=<rc>)>` line per PR, then `trend: ...`
exit codes: 0 the sweep ran (per-PR failures are reported) / 1 usage or unresolvable window
EOF
  exit 1
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JUDGED="$HERE/ghjig_judged_list.sh"

command -v gh >/dev/null 2>&1 || die "gh CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
[ -x "$JUDGED" ] || die "the judged-list code home is not executable: $JUDGED"

[ "$#" -ge 1 ] || usage

case "${1:-}" in
  --recent) die "--recent not implemented yet (#721 Phase C)" 1 ;;
  -*) usage ;;
  *) die "report mode not implemented yet (#721 Phase C)" 1 ;;
esac
