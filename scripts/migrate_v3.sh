#!/usr/bin/env bash
# scripts/migrate_v3.sh — one-time migration from v0/v1 (Projects-as-SSOT)
# to the Issues-as-SSOT substrate (Directive #92 cluster I).
#
# Procedure (brief §8 step 1-5):
#   Step 1. Snapshot every Item in the dir-mode Project to a timestamped
#           directory under .claude/state/v2-snapshot/<ISO>/. One JSON file
#           per Item, plus a manifest. Read-only history.
#   Step 2. Verify MISSION.md exists and contains the canonical content
#           (already populated by the Cluster I PR — this script does NOT
#           write MISSION.md; that's an explicit human-curated step).
#   Step 3. Delete each Item from the Project via `gh project item-delete`.
#           Idempotent: items already deleted are skipped.
#   Step 4. Reconcile field schema by re-running setup_project.sh which
#           drops the Goal Type option, drops Confidence + Success Signals
#           fields, and updates Status options to the v3 4-state set.
#   Step 5. The mirror workflow re-creates Items on the next Issue event;
#           no manual backfill.
#
# Refuses on:
#   - cwd not in $GHJIG_ROOT/.claude/state/registry.txt
#   - missing MISSION.md (must be populated before running)
#   - --confirm flag absent (destructive operation — explicit opt-in)
#
# Snapshot is NOT idempotent: the timestamp resolves to the second
# (date -u +%Y%m%dT%H%M%SZ), so each run writes a fresh snapshot dir.
# Idempotency holds only on the Item deletion (a re-run finds the Items
# already deleted). migrate_v3 is a spent one-shot — the v3 cutover
# completed inline — so a redundant snapshot dir on a re-run is harmless. (#218)

set -euo pipefail

# Self-location: resolve GHJIG_ROOT from our own path (test seam: GHJIG_ROOT_OVERRIDE).
# The inherited ambient env is never an input (#539).
GHJIG_ROOT="${GHJIG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"; export GHJIG_ROOT

if [ -f "$GHJIG_ROOT/.claude/hooks/hookrt.sh" ]; then
  # shellcheck source=/dev/null
  . "$GHJIG_ROOT/.claude/hooks/hookrt.sh"
else
  audit_log() { :; }
fi

# --confirm gate FIRST — destructive operation; explicit opt-in must
# precede infrastructure checks so the gate is visible even when run on
# a fresh runner (no registry entry, no gh auth). Subsequent guards
# protect actual execution.
if [ "${1:-}" != "--confirm" ]; then
  echo "migrate_v3: DESTRUCTIVE one-shot — re-run with --confirm to proceed."
  echo ""
  echo "  Action: snapshot all Items in the dir-mode Project + delete each"
  echo "  Target: \$GHJIG_ROOT/.claude/state/v2-snapshot/<ISO>/"
  echo ""
  echo "After this script: setup_project.sh reconciles the field schema to v3"
  echo "  (drops Goal/Confidence/Success Signals; Status → 4-state set)."
  echo "  Mirror workflow re-creates Items from Issues on the next Issue event."
  exit 2
fi

# shellcheck disable=SC2034  # consumed by sourced dir_mode_project_resolve.sh
DR_SCRIPT_NAME=migrate_v3
# shellcheck disable=SC2034  # consumed by sourced dir_mode_project_resolve.sh
DR_AUDIT_CATEGORY=project-setup
# shellcheck source=/dev/null
. "$GHJIG_ROOT/scripts/lib/dir_mode_project_resolve.sh"

dr_check_registry_guard || exit 1
dr_check_gh_auth || exit 1
dr_check_gh_scope || exit 1
dr_check_jq || exit 1
dr_resolve_owner_repo || exit 1
dr_find_project || exit 1

owner="$DR_OWNER"
project_num="$DR_PROJECT_NUM"

# MISSION.md presence check (brief §8 step 2).
if [ ! -f "$GHJIG_ROOT/MISSION.md" ]; then
  echo "migrate_v3: MISSION.md missing — populate before running migration." >&2
  echo "  PVTI #84's body should be transcribed into MISSION.md (MISSION.md replaces the Goal artifact)." >&2
  audit_log block "$DR_AUDIT_CATEGORY" deny "migrate_v3: MISSION.md missing — refused"
  exit 1
fi

# Step 1: snapshot
ts=$(date -u +%Y%m%dT%H%M%SZ)
snap_dir="$GHJIG_ROOT/.claude/state/v2-snapshot/$ts"
mkdir -p "$snap_dir"
echo "migrate_v3: snapshot directory $snap_dir"

# Fetch all Items as JSON. Use --limit 200 to capture all (we have <20 today).
items_json=$(gh project item-list "$project_num" --owner "$owner" --format json --limit 200 2>/dev/null)
total=$(printf '%s' "$items_json" | jq -r '.items | length')
echo "migrate_v3: $total items found in Project #${project_num}"

# Write manifest + per-item JSON files.
printf '%s\n' "$items_json" | jq '.' > "$snap_dir/manifest.json"

item_ids=$(printf '%s' "$items_json" | jq -r '.items[].id')
saved=0
for item_id in $item_ids; do
  printf '%s\n' "$items_json" \
    | jq --arg id "$item_id" '.items[] | select(.id==$id)' \
    > "$snap_dir/item__${item_id}.json"
  saved=$((saved+1))
done
echo "migrate_v3: snapshotted $saved items to $snap_dir"

# Step 3: delete each item. `gh project item-delete` requires both the
# Project number AND `--owner` in non-interactive contexts. Without
# `--owner`, every call fails with "owner is required when not running
# interactively" and the migration silently no-ops (caught when the v3
# cutover ran 2026-05-26; PR #105 fixes the script after the cutover
# completed inline).
deleted=0
skipped=0
for item_id in $item_ids; do
  if gh project item-delete "$project_num" --owner "$owner" --id "$item_id" >/dev/null 2>&1; then
    deleted=$((deleted+1))
  else
    # Idempotent: item already deleted, or transient error.
    skipped=$((skipped+1))
  fi
done
echo "migrate_v3: deleted=$deleted skipped=$skipped"

audit_log info "$DR_AUDIT_CATEGORY" migrated "v3-migration: project=#${project_num} snapshot=$snap_dir items_total=$total deleted=$deleted skipped=$skipped"

# Step 4: reconcile field schema to v3 by re-running setup_project.sh.
echo "migrate_v3: re-running setup_project.sh to reconcile field schema..."
bash "$GHJIG_ROOT/scripts/setup_project.sh" || {
  echo "migrate_v3: setup_project.sh failed — fields may need manual reconciliation" >&2
  audit_log warn "$DR_AUDIT_CATEGORY" notice "v3-migration: setup_project.sh failed post-snapshot+delete"
  exit 1
}

echo ""
echo "migrate_v3: done. Project #${project_num} is now v3-schema-aligned."
echo ""
echo "Next steps:"
echo "  1. Re-fire mirror workflow by editing one Directive Issue (or wait for next event)."
echo "  2. Verify: \`gh project item-list ${project_num} --owner ${owner}\` returns mirror-created Items."
echo "  3. Project #84 (the Goal Item) is gone — MISSION.md is the canonical direction now."
