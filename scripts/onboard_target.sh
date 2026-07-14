#!/usr/bin/env bash
# scripts/onboard_target.sh — install the v3 substrate into the current
# target repo (cwd). Tier-aware (--tier 1|2|3). Idempotent. PR-based file
# installs via a PR to the target (never direct push). Audit-logged.
#
# Invoked from /onboard-dir-mode (.claude/commands/onboard-dir-mode.md).
#
# Tier semantics (SPEC §1.7 Substrate-in-target contract):
#   1 — no-op (eng-mode only; no substrate installed).
#   2 — labels: the 13-label v3 set via `gh label create --force`.
#   3 — tier 2 + ISSUE_TEMPLATE + workflows (via PR) + Project v2.

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

TIER=3
DRY_RUN=
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)
      TIER="${2:-}"
      [ -z "$TIER" ] && { echo "onboard_target: --tier requires a value (1, 2, or 3)" >&2; exit 2; }
      shift 2 ;;
    --tier=*) TIER="${1#--tier=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "onboard_target: unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$TIER" in
  1|2|3) ;;
  *) echo "onboard_target: --tier must be 1, 2, or 3 (got $TIER)" >&2; exit 2 ;;
esac

# Resolve target owner/repo (validates we're in a real gh repo context).
# Dry-run skips the live-gh check so smoke and other no-network contexts
# (CI runners without gh auth, sandbox testing) can exercise the script's
# structural output without auth. Live runs still require gh + remote.
if ! command -v gh >/dev/null 2>&1; then
  if [ -n "$DRY_RUN" ]; then
    TARGET_OWNER_REPO="<owner>/<repo>"
  else
    echo "onboard_target: gh CLI not found" >&2
    exit 1
  fi
else
  TARGET_OWNER_REPO=$(gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null || true)
  if [ -z "$TARGET_OWNER_REPO" ]; then
    if [ -n "$DRY_RUN" ]; then
      TARGET_OWNER_REPO="<owner>/<repo>"
    else
      echo "onboard_target: cannot resolve gh repo (cwd not in a gh-recognized git repo or gh not authed)" >&2
      exit 1
    fi
  fi
fi
echo "onboard_target: target=$TARGET_OWNER_REPO tier=$TIER ${DRY_RUN:+(dry-run)}"

# ---------------------------------------------------------------
# Tier 1 — no-op
# ---------------------------------------------------------------
if [ "$TIER" = 1 ]; then
  echo "onboard_target: tier 1 — no substrate to install (eng-mode works without)"
  audit_log info onboard-dir-mode created "target=$TARGET_OWNER_REPO tier=1 noop"
  exit 0
fi

# ---------------------------------------------------------------
# Tier 2 — labels
# ---------------------------------------------------------------
# Delegate to scripts/ensure_v3_labels.sh — the single source of truth for
# the v3 label set (named, colored, described). Avoids duplicating the
# spec here (canonical-substrate principle: one source of truth per
# artifact type). Plus extra labels not in ensure_v3_labels.sh: directive,
# P0/P1/P2/P3 — installed inline since those labels are not the v3-bootstrap
# scope of ensure_v3_labels.sh.
echo "onboard_target: tier 2 — installing 13-label v3 set..."

ensure_label() {
  local name="$1" color="$2" desc="$3"
  if [ -n "$DRY_RUN" ]; then
    printf "  [dry-run] would: gh label create '%s' --color '%s' --force\n" "$name" "$color"
    return 0
  fi
  gh label create "$name" --color "$color" --description "$desc" --force >/dev/null 2>&1 || \
    printf "  warn: label '%s' install failed (non-fatal; existing labels often differ in description-only)\n" "$name"
}

# v3-bootstrap labels (mirror of scripts/ensure_v3_labels.sh — call it
# directly when not dry-run to inherit any future updates there).
if [ -n "$DRY_RUN" ]; then
  # Mirror the spec inline for dry-run visibility.
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
  ensure_label "initiative:challenged"          "0052CC" "Execution challenged parent Initiative; orchestrator re-evaluation requested (#359)"
  ensure_label "initiative:completion-requested" "0052CC" "Execution signals parent Initiative may be complete; orchestrator assessment requested (#359)"
else
  bash "$GHJIG_ROOT/scripts/ensure_v3_labels.sh" 2>&1 | sed 's/^/  /'
fi

# Additional labels not in ensure_v3_labels.sh (P0-P3 moved into the canonical
# set by #185; the two tier type-keys `directive` and `initiative` remain inline
# here — #249).
ensure_label "directive" "0E8A16" "Directive Issue (dir-mode, SPEC §1.7)"
ensure_label "initiative" "0052CC" "Initiative: planning-tier strategic commitment consumed from upstream (dir-mode, SPEC §1.7)"

echo "onboard_target: tier 2 labels done (15 total: 13 from ensure_v3_labels.sh + 2 inline: directive, initiative)."

if [ "$TIER" = 2 ]; then
  audit_log info onboard-dir-mode created "target=$TARGET_OWNER_REPO tier=2 labels=15"
  exit 0
fi

# ---------------------------------------------------------------
# Tier 3 — labels + ISSUE_TEMPLATE + workflows (via PR) + Project
# ---------------------------------------------------------------
echo "onboard_target: tier 3 — installing ISSUE_TEMPLATE + workflows via PR..."
SUBSTRATE_ROOT="$GHJIG_ROOT/.claude/templates/target-substrate"
if [ ! -d "$SUBSTRATE_ROOT" ]; then
  echo "onboard_target: canonical-source $SUBSTRATE_ROOT missing — re-run scripts/sync_target_substrate.sh" >&2
  exit 1
fi

# Copy canonical files into target's .github/.
TARGET_GITHUB="$(pwd)/.github"
# The release-backbone authoring substrate installs into the target REPO ROOT
# (not .github/): changelog_unreleased/TEMPLATE.md + the six Keep-a-Changelog
# category subdirs each with a .gitkeep (SPEC §18.1/§18.6). It is the authoring
# affordance the check-changelog.yml gate enforces against — shipping the gate
# without it leaves the adopter self-contradictory (#374).
SUBSTRATE_CL="$SUBSTRATE_ROOT/changelog_unreleased"
TARGET_CL="$(pwd)/changelog_unreleased"
CL_CATEGORIES="added changed deprecated removed fixed security"
mkdir -p "$TARGET_GITHUB/ISSUE_TEMPLATE" "$TARGET_GITHUB/workflows"
if [ -n "$DRY_RUN" ]; then
  echo "  [dry-run] would copy:"
  ls "$SUBSTRATE_ROOT/ISSUE_TEMPLATE/" "$SUBSTRATE_ROOT/workflows/" 2>/dev/null
  echo "  [dry-run] would install changelog_unreleased/ substrate (TEMPLATE.md + 6 .gitkeep category dirs):"
  ls "$SUBSTRATE_CL/" 2>/dev/null
else
  cp "$SUBSTRATE_ROOT/ISSUE_TEMPLATE/"*.yml "$TARGET_GITHUB/ISSUE_TEMPLATE/"
  cp "$SUBSTRATE_ROOT/workflows/"*.yml "$TARGET_GITHUB/workflows/"
  # Resolver helper(s) shipped alongside the workflows so the post-merge workflow
  # can source them after actions/checkout (#335). Guarded so an absent *.sh does
  # not copy a literal glob.
  for sh in "$SUBSTRATE_ROOT/workflows/"*.sh; do
    [ -e "$sh" ] || break
    cp "$sh" "$TARGET_GITHUB/workflows/"
  done
  # Release-backbone authoring substrate into the repo root (#374, SPEC §18.6).
  cp "$SUBSTRATE_CL/TEMPLATE.md" "$TARGET_CL/TEMPLATE.md" 2>/dev/null || {
    mkdir -p "$TARGET_CL" && cp "$SUBSTRATE_CL/TEMPLATE.md" "$TARGET_CL/TEMPLATE.md"
  }
  for cat in $CL_CATEGORIES; do
    mkdir -p "$TARGET_CL/$cat"
    cp "$SUBSTRATE_CL/$cat/.gitkeep" "$TARGET_CL/$cat/.gitkeep"
  done
  echo "  copied ISSUE_TEMPLATE + workflow files (incl. resolver helper) into $TARGET_GITHUB/"
  echo "  installed changelog_unreleased/ substrate (TEMPLATE.md + 6 category dirs) into $TARGET_CL/"
fi

# Open a PR if there are changes. Idempotent: skip if nothing to install.
# Use `git status --porcelain` (not `git diff --quiet`): on a greenfield target
# the freshly-copied .github/ is UNTRACKED, and `git diff` is blind to untracked
# paths — it would report "no changes" and skip the PR, never installing the
# substrate (#343). `status --porcelain` sees untracked + modified + staged and
# is read-only on the index. Empty output => genuinely nothing to install.
if [ -z "$DRY_RUN" ]; then
  # Pathspec covers BOTH install targets — .github/ AND the repo-root
  # changelog_unreleased/ substrate (#374). Omitting the latter would let a target
  # that only needs the substrate (gate already present) report "nothing to install"
  # and skip the PR, re-creating the gate-without-substrate gap this fix closes.
  if [ -z "$(git -C "$(pwd)" status --porcelain -- .github/ changelog_unreleased/)" ]; then
    echo "onboard_target: tier 3 files already match canonical-source (no PR needed; idempotent)"
  else
    BRANCH="onboard-dir-mode-substrate"
    git -C "$(pwd)" checkout -b "$BRANCH" 2>/dev/null || git -C "$(pwd)" checkout "$BRANCH"
    git -C "$(pwd)" add .github/ changelog_unreleased/
    git -C "$(pwd)" commit -m "chore: onboard GHJig-Claude dir-mode v3 substrate

Installs ISSUE_TEMPLATE files + dir-mode workflows + the changelog_unreleased/
authoring substrate (SPEC §1.7 Substrate-in-target contract; §18.6 release backbone).
Reversibility: git rm .github/ISSUE_TEMPLATE/<file>, .github/workflows/<file>,
or changelog_unreleased/<...> removes any installed file via a normal PR."
    git -C "$(pwd)" push -u origin "$BRANCH"
    gh pr create --title "chore: onboard GHJig-Claude dir-mode v3 substrate" \
      --body "Installs ISSUE_TEMPLATE files + dir-mode workflows + the changelog_unreleased/ authoring substrate (SPEC §1.7 Substrate-in-target contract; §18.6 release backbone). Reversibility: git rm any installed file via a normal PR; gh label delete any installed label; gh project delete the Project out-of-band."
  fi
fi

# Project v2 setup.
if [ -n "$DRY_RUN" ]; then
  echo "  [dry-run] would: bash scripts/setup_project.sh"
else
  echo "onboard_target: invoking setup_project.sh..."
  bash "$GHJIG_ROOT/scripts/setup_project.sh" || echo "  warn: setup_project.sh failed — Project may need manual creation"
fi

audit_log info onboard-dir-mode created "target=$TARGET_OWNER_REPO tier=3"
echo "onboard_target: tier 3 done."
