#!/usr/bin/env bash
# scripts/promotion_candidates.sh [<audit-log>] [<min-rejects>]
#
# Aggregate the reviewer-reject reason-class trail into advisory→hook promotion
# candidates (SPEC §6.0 P3, Directive #356 signal 4). READ-ONLY / surfacing-only:
# it lists candidates; the promote decision stays human/reviewer judgment.
#
# Reads reviewer-reject records — event=warn, decision=reject — emitted by
# reviewer_reject_audit (#361) with a reason of the form "class=<token> issue=#<N>",
# category ∈ issue-review|plan-review|activation. Aggregates by category × class
# and surfaces groups whose reject count >= the threshold (default 3; positional
# $2 or $PROMOTION_MIN_REJECTS), sorted by rejects desc. A class rejected N+ times
# across reviews is a candidate for promoting the advisory to a hook.
#
# LIVE-default: records with source == "test" are excluded (absent source → live)
# so harness-fixture rejects don't pollute a real report. Lines whose reason has
# no "class=" token (legacy / non-reviewer warns) are skipped.
#
# Log path: $1 if given, else the same path audit_log writes (resolve_audit_log).
# Always exits 0 (a read-only report); empty/absent log → a "no records" line, 0.
# No gh, no network, no mutation.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=/dev/null
. "$HERE/lib/audit_log_path.sh"

log=$(resolve_audit_log "${1:-}")
min_rejects="${2:-${PROMOTION_MIN_REJECTS:-3}}"
case "$min_rejects" in ""|*[!0-9]*) min_rejects=3 ;; esac

if [ ! -s "$log" ]; then
  echo "promotion-candidates: no records (log: ${log:-<unset>})"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "promotion-candidates: jq not found — cannot report" >&2
  exit 0
fi

echo "promotion candidates (reviewer-reject reason-class aggregation; LIVE-only; min_rejects=$min_rejects):"
out=$(grep -v '^[[:space:]]*$' "$log" | jq -rs --argjson mr "$min_rejects" '
  map(select(.event == "warn" and .decision == "reject" and ((.source // "live") != "test")))
  | map(select((.reason // "") | test("class=[a-z-]+")))
  | map({category: .category, cls: ((.reason) | capture("class=(?<c>[a-z-]+)").c)})
  | group_by([.category, .cls])
  | map({category: .[0].category, cls: .[0].cls, rejects: length})
  | map(select(.rejects >= $mr))
  | sort_by(-.rejects)
  | .[] | "  \(.category) | \(.cls) | rejects=\(.rejects)"
' 2>/dev/null)

if [ -z "$out" ]; then
  echo "  (none above threshold)"
else
  printf '%s\n' "$out"
fi
exit 0
