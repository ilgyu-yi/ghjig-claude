#!/usr/bin/env bash
# scripts/ensure_v3_labels.sh — idempotent creation of the labels the v3
# reframe's Issue templates + workflows depend on. Run once after PR #93
# merges (or any time a target repo is bootstrapped against the v3 substrate).
#
# Labels created:
#   - status:proposed  — Issue in proposed state (pre-activation; all types, #172)
#   - status:blocked   — Directive in Blocked state (per SPEC §2.1 v3)
#   - awaiting-author  — handoff state: reviewer returned revise/trusted-reject (#172)
#   - task             — standalone task / improvement (task.yml)
#   - execution        — Execution Issue parented under a Directive (#186; first-class type)
#   - discussion       — observation / half-formed idea (SPEC §5.19; Issue #112)
#   - skip-changelog   — PR-time opt-out for the release-backbone fragment-gate (SPEC §18.6)
#   - P0 / P1 / P2 / P3 — Directive priority (#185; SPEC §0.4 tier-2 set; the P<N> label
#                        /file-directive applies is the mirror-readable priority projection)
#
# Already-existing labels that v3 relies on (no creation needed):
#   - directive, bug, enhancement, documentation, duplicate, wontfix,
#     unattended-parked, question, help wanted, good first issue, invalid
#
# Idempotent: `gh label create --force` overwrites color/description but is
# stable on existing label names.

set -euo pipefail

ensure_label() {
  local name="$1" color="$2" desc="$3"
  gh label create "$name" --color "$color" --description "$desc" --force >/dev/null
  echo "  label '$name' ensured"
}

echo "ensure_v3_labels: creating v3 reframe labels (idempotent)..."

ensure_label "status:proposed" "FBCA04" "Directive proposed; awaiting maintainer triage (SPEC §2.1 v3)"
ensure_label "status:blocked"  "B60205" "Directive cannot proceed without external input (SPEC §5.17)"
ensure_label "awaiting-author"  "F9D0C4" "Reviewer returned a verdict (revise/trusted-reject); author action pending (#172)"
ensure_label "task"            "C5DEF5" "Standalone task or small improvement (not parented under a Directive)"
ensure_label "execution"       "5319E7" "Execution Issue: a unit of work parented under a Directive (#186)"
ensure_label "discussion"      "FEF2C0" "Observation or half-formed idea; close as promoted (#M) or no-action (SPEC §5.19)"
ensure_label "skip-changelog"  "CCCCCC" "PR exempt from fragment-gate; no end-user observable change (SPEC §18.6)"
ensure_label "P0"              "B60205" "Priority 0 — drop everything"
ensure_label "P1"              "D93F0B" "Priority 1 — next"
ensure_label "P2"              "FBCA04" "Priority 2 — soon"
ensure_label "P3"              "0E8A16" "Priority 3 — eventually"

echo "ensure_v3_labels: done."
