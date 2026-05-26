#!/usr/bin/env bash
# scripts/ensure_v3_labels.sh — idempotent creation of the labels the v3
# reframe's Issue templates + workflows depend on. Run once after PR #93
# merges (or any time a target repo is bootstrapped against the v3 substrate).
#
# Labels created:
#   - status:proposed  — Directive in proposed state (pre-activation)
#   - status:blocked   — Directive in Blocked state (per SPEC §2.1 v3)
#   - task             — standalone task / improvement (task.yml)
#   - needs-triage     — applied by auto-needs-triage.yml on raw filings
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
ensure_label "task"            "C5DEF5" "Standalone task or small improvement (not parented under a Directive)"
ensure_label "needs-triage"    "D4C5F9" "Issue filed without a template — awaiting maintainer triage classification"

echo "ensure_v3_labels: done."
