#!/usr/bin/env bash
# scripts/narrowing_candidates.sh [<audit-log>] [<min-days>]
#
# Surface escape-clustering over LIVE audit records as gates that may warrant
# narrowing (SPEC §6.0 P3, Directive #356 signal 2). READ-ONLY / surfacing-only:
# it lists candidates; the narrow decision stays human/reviewer judgment.
#
# Clusters LIVE escape records — event=escape, decision=skip, and source != "test"
# (an absent source is treated as live, fail-open) — by category × a normalized
# reason (lowercased; a leading "reason=" stripped; whitespace collapsed/trimmed,
# so free-text SKIP_REASON variants of one intent group together). For each group
# it counts total escapes and DISTINCT UTC calendar days. The audit record carries
# no session id, so a distinct day (ts[0:10]) is the session proxy. Groups whose
# distinct-day count >= the threshold (default 2; positional $2 or $NARROWING_MIN_DAYS)
# are surfaced, sorted by days desc then escapes desc.
#
# Log path: $1 if given, else the same path audit_log writes (resolve_audit_log).
# Always exits 0 (a read-only report); empty/absent log → a "no records" line, 0.
# No gh, no network, no mutation.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=/dev/null
. "$HERE/lib/audit_log_path.sh"

log=$(resolve_audit_log "${1:-}")
min_days="${2:-${NARROWING_MIN_DAYS:-2}}"
case "$min_days" in ""|*[!0-9]*) min_days=2 ;; esac

if [ ! -s "$log" ]; then
  echo "narrowing-candidates: no records (log: ${log:-<unset>})"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "narrowing-candidates: jq not found — cannot report" >&2
  exit 0
fi

echo "narrowing candidates (escape-clustering; session ≈ distinct UTC day; min_days=$min_days):"
out=$(grep -v '^[[:space:]]*$' "$log" | jq -rs --argjson md "$min_days" '
  map(select(.event == "escape" and .decision == "skip" and ((.source // "live") != "test")))
  | map({
      category: .category,
      reason: (.reason // "" | ascii_downcase | gsub("^reason=";"") | gsub("\\s+";" ") | gsub("^ +| +$";"")),
      day: (.ts // "" | .[0:10])
    })
  | group_by([.category, .reason])
  | map({category: .[0].category, reason: .[0].reason, escapes: length, days: ([.[].day] | unique | length)})
  | map(select(.days >= $md))
  | sort_by(-.days, -.escapes)
  | .[] | "  \(.category) | \(.reason) | escapes=\(.escapes) | days=\(.days)"
' 2>/dev/null)

if [ -z "$out" ]; then
  echo "  (none above threshold)"
else
  printf '%s\n' "$out"
fi
exit 0
