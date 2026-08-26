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
#   ghjig_rounds.sh --recent <M>   report up to M of the most recently MERGED PRs
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
# count, and never touches the exit code. The child's stderr is forwarded
# verbatim, so its own two anomaly classes share this prefix and — unlike the
# line above — carry no `pr=`; on a multi-PR sweep a child anomaly is therefore
# not attributable to a PR from the output alone.
#
# Window resolution (`--recent <M>`) is MERGE-ORDERED, which the listing API is
# not: `gh pr list --state merged` returns createdAt-descending, so both the
# membership of a `--limit M` window and the order within it can disagree with
# merge order — a long-lived PR that merged late sits below PRs that merged
# earlier, which would bias the very trend this instrument reports. So the
# window is over-fetched, sorted by `mergedAt` descending, cut to at most M, and
# emitted oldest→newest. The over-fetch is 4×M with a floor of 20 and a cap of
# 200 (never below M) — wide enough that the window is not a listing prefix.
# The resolution runs ONCE per invocation. The resolution command, verbatim:
#
#   gh pr list --state merged --limit <over-fetch> --json number,mergedAt
#
# On the explicit-list route the caller owns the order: the trend is printed in
# the order the PR arguments were given, merge-ordered only if the caller made
# it so.
#
# A derivation failure is any non-zero child exit — rc 3 (the child's duplicate
# refusal) reads `ambiguous(duplicate)`, every other rc reads `error(rc=<rc>)`,
# as does a child that exits 0 without a parsable `next=` (reported `rc=0`).
#
# Exit codes: 0 whenever the sweep ran — a PR whose derivation failed is
# REPORTED, never fatal (fail-open reporter) · 1 anything that prevented the
# sweep from starting at all — a usage error, an absent dependency, an
# unreachable code home, or a `--recent` window that could not be resolved.
# A per-PR derivation failure is never one of these. Nothing here fails closed: this is
# an advisory reporter, and evidence/gates elsewhere keep their own posture.
set -euo pipefail

PROG="ghjig_rounds"

# The over-fetch of the `--recent` listing: the window is decided by mergedAt,
# so the fetch must reach PAST the M topmost createdAt-descending entries or the
# window could only ever be a listing prefix. Factor 4, with a floor, a cap, and
# never below M itself.
OVERFETCH_FACTOR=4
OVERFETCH_FLOOR=20
OVERFETCH_CAP=200

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-1}"; }

usage() {
  cat >&2 <<'EOF'
usage: ghjig_rounds.sh <pr> [<pr>...]   report those PRs in the order given
       ghjig_rounds.sh --recent <M>     report up to M of the most recently merged PRs
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

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# TREND accumulates one token per reported PR, in report order, and is printed
# once at the end — an ambiguous or errored entry contributes `?`, never a
# dropped token, so the trend's length always equals the number of PRs swept.
TREND=""

# report_pr <pr> — print this PR's report line on stdout and append its trend
# token. Rounds come ONLY from the child code home's `next=` value (minus 1);
# this function never inspects a comment's shape. A per-PR failure is reported
# in place and is never fatal (fail-open reporter).
report_pr() {
  local pr="$1" rc=0 out="" next="" facts=0 rounds tok
  out=$("$JUDGED" rounds "$pr") || rc=$?
  if [ "$rc" -eq 3 ]; then
    printf 'pr=%s rounds=ambiguous(duplicate)\n' "$pr"
    tok='?'
  elif [ "$rc" -ne 0 ]; then
    printf 'pr=%s rounds=error(rc=%s)\n' "$pr" "$rc"
    tok='?'
  else
    next=$(printf '%s\n' "$out" | sed -n 's/^next=\([0-9][0-9]*\)$/\1/p' | tail -n 1)
    if [ -z "$next" ]; then
      # The child succeeded but printed no parsable `next=`: the derivation is
      # unavailable, which is a per-PR failure like any other.
      printf 'pr=%s rounds=error(rc=%s)\n' "$pr" "$rc"
      tok='?'
    else
      rounds=$((next - 1))
      facts=$(printf '%s\n' "$out" | grep -c '^round=') || facts=0
      if [ "$facts" -ne "$rounds" ]; then
        printf 'anomaly: pr=%s — the child reports %s canonical round facts but the last judged round is %s; live numbering is contiguous, so the gap most likely means a judged comment was deleted (informational: the reported count stands)\n' \
          "$pr" "$facts" "$rounds" >&2
      fi
      printf 'pr=%s rounds=%s\n' "$pr" "$rounds"
      tok="$rounds"
    fi
  fi
  TREND="${TREND:+$TREND }$tok"
}

# resolve_recent <M> — print up to M of the most recently MERGED PR numbers,
# oldest first. Merge order is not listing order, so the listing is over-fetched,
# sorted by mergedAt descending, cut to at most M, and re-reversed. One `pr list`
# call. The listing can hold fewer than M merged PRs, and the trend line's one
# token per reported PR is what states the sample actually reported.
resolve_recent() {
  local m over json nums
  # Base-10 lift before any arithmetic: is_num admits a leading zero, which bash
  # would read as octal. The child code home states the same rule at its own
  # lift seam; this consumer is one hop from that guard.
  m=$((10#$1))
  over=$((m * OVERFETCH_FACTOR))
  [ "$over" -ge "$OVERFETCH_FLOOR" ] || over="$OVERFETCH_FLOOR"
  [ "$over" -le "$OVERFETCH_CAP" ] || over="$OVERFETCH_CAP"
  [ "$over" -ge "$m" ] || over="$m"
  json=$(gh pr list --state merged --limit "$over" --json number,mergedAt) \
    || die "could not resolve the --recent window (gh pr list failed)"
  nums=$(printf '%s\n' "$json" | jq -r --argjson m "$m" '
      map(select(.mergedAt != null and .number != null))
      | sort_by(.mergedAt) | reverse | .[0:$m] | reverse | .[].number') \
    || die "could not resolve the --recent window (the listing did not parse)"
  [ -n "$nums" ] || die "the --recent window resolved to no merged PR"
  printf '%s\n' "$nums"
}

case "${1:-}" in
  --recent)
    [ "$#" -eq 2 ] || usage
    is_num "$2" || die "reject: <M> must be a number (got: $2)"
    [ "$2" -ge 1 ] || die "reject: <M> must be at least 1 (got: $2)"
    RECENT=$(resolve_recent "$2") || exit $?
    while IFS= read -r rpr; do
      [ -n "$rpr" ] || continue
      report_pr "$rpr"
    done <<EOF
$RECENT
EOF
    ;;
  -*) usage ;;
  *)
    # Validate every argument BEFORE any is reported: a non-numeric argument is a
    # usage error, and exit 1 means the sweep never started (see the exit codes
    # above), so it must not follow a partially emitted report.
    for apr in "$@"; do
      is_num "$apr" || usage
    done
    for apr in "$@"; do
      report_pr "$apr"
    done
    ;;
esac

printf 'trend: %s\n' "$TREND"
exit 0
