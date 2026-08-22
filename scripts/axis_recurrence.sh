#!/usr/bin/env bash
# scripts/axis_recurrence.sh [<audit-log>]
#
# Axis-recurrence signal over the reviewer-reject trail (SPEC §6.1, #697 /
# Directive #688 item 3). The second consumer of the reviewer-reject audit
# records: where promotion_candidates.sh aggregates by category × reason-class
# and drops the issue target, this one keeps it — grouping LIVE reject records
# (event=warn, decision=reject, source != "test"; absent source is live,
# fail-open) by (issue, reason-class) across reviewer categories. When the same
# target has drawn the same reason-class a second time, ONE line surfaces
# carrying `change the form, not the instance`; a first occurrence emits
# nothing. The line carries the jq-unique-sorted category set and the
# occurrence ts range (ts=<first>..<last>), so a same-minute duplicate emission
# is legible rather than silently counted.
#
# Observe-only (§6.0 P3): no gate, no verdict change, no park consumes it; the
# header's calibration note states the limit (reason-class is not a calibrated
# axis key). Threshold fixed at 2 — no knob. Records whose reason lacks either
# a class=[a-z-]+ or an issue=#[0-9]+ token are skipped; malformed/torn JSON
# lines are skipped per-line (fromjson? posture — a bad record never blinds
# the whole report). Fail-open: absent/empty log or missing jq → a note,
# exit 0. Always exits 0. No gh, no network, no mutation.
#
# Log path: $1 if given, else the same path audit_log writes (resolve_audit_log).

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=/dev/null
. "$HERE/lib/audit_log_path.sh"

log=$(resolve_audit_log "${1:-}")

# Both headers print unconditionally — including on an empty/absent log —
# BEFORE any early exit (smoke §181d pins them whole-line on all three cases).
echo "axis-recurrence (reviewer-reject trail, second same-target same-class occurrence; observe-only):"
echo "  note: reason-class is not a calibrated axis key — two defects can share a class, one axis can span classes; signal, not verdict"

if [ ! -s "$log" ]; then
  echo "  axis-recurrence: no records (log: ${log:-<unset>})"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "axis-recurrence: jq not found — cannot report" >&2
  exit 0
fi

# Per-line parse (-R + fromjson? // empty): a torn line is dropped, the rest
# of the report survives. The pair line is built in exactly ONE place — the
# smoke asserts it whole-line, so no second assembly path may drift.
out=$(jq -rRn '
  [inputs | fromjson? // empty]
  | map(select(.event == "warn" and .decision == "reject" and ((.source // "live") != "test")))
  | map(select((.reason // "") | test("class=[a-z-]+") and test("issue=#[0-9]+")))
  | map({
      issue: ((.reason // "") | capture("issue=#(?<n>[0-9]+)").n),
      class: ((.reason // "") | capture("class=(?<c>[a-z-]+)").c),
      category: (.category // ""),
      ts: (.ts // "")
    })
  | group_by([.issue, .class])
  | map({
      issue: .[0].issue,
      class: .[0].class,
      rejects: length,
      categories: ([.[].category] | unique | join(",")),
      first: ([.[].ts] | min),
      last: ([.[].ts] | max)
    })
  | map(select(.rejects >= 2))
  | sort_by([(.issue | tonumber), .class])
  | .[]
  | "  issue=#\(.issue) | class=\(.class) | rejects=\(.rejects) | categories=\(.categories) | ts=\(.first)..\(.last) — change the form, not the instance"
' "$log" 2>/dev/null)

if [ -z "$out" ]; then
  echo "  (no recurring pairs)"
else
  printf '%s\n' "$out"
fi
exit 0
