#!/usr/bin/env bash
# scripts/test/smoke.sh — shell infrastructure sanity check.
# Verifies hook/helper/inject behavior without running Claude Code.
#
# ── Structure (#600) ──────────────────────────────────────────────────────────
# This file is a THIN ORCHESTRATOR. The suite grew until its own shellcheck peak
# (~20 GiB RSS at ~16k lines) OOM-killed the ~16 GB ubuntu CI runner, so it is
# split into a shared preamble + numbered section files under smoke.d/, sourced
# in order into ONE shell (byte-identical pass/fail semantics to the old monolith)
# so each shellcheck unit is small enough to fit the runner. Add a section by
# dropping a new smoke.d/NN-<name>.sh and listing it below in source order. Any
# symbol reused across section boundaries lives in smoke.d/_preamble.sh.
#
# ── Test-integrity / anti-vacuity discipline (#279, Theme E) ──────────────────
# An assertion that greens WITHOUT exercising the property it names is worse than
# no assertion — it reads as coverage while guarding nothing. Two recurring
# vacuous-pass anti-patterns, and the fix for each:
#
#   1. Comment-satisfiable grep. `grep -q 'token' "$FILE"` passes when `token`
#      appears only in a COMMENT/prose, not the CODE form the assertion claims to
#      verify. → Anchor the grep to the code form (e.g. `^Parent Initiative` with
#      the leading caret a regex carries but a comment usually doesn't; or a
#      `should_skip <cat>`-shaped pattern), not a bare token. (Fixed live: §57e.)
#
#   2. Silent skip on an absent target. `[ -f "$f" ] && grep …` (or `… || continue`
#      over a glob, or an `if [ -f ]; then … ` with no `else`) reports green when
#      `$f` is absent — the property went unchecked. → Fail LOUD on a missing
#      target the assertion claims to read (`ng` / `MISSING:`), and when a check
#      iterates an expected SET, assert the COUNT actually checked (a count-guard)
#      so an empty glob can't pass "all N …". (Fixed live: §57i, §54g.)
#
# Optional-tooling skips (`gdlint`/`timeout`/`pyyaml` absent → ok "… skipped") are
# NOT vacuous: the property is genuinely untestable without the tool, and the skip
# is reported. The anti-pattern is a skip that masquerades as a PASS of the thing.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# SHELL_ROOT/GHJIG_ROOT MUST resolve here in the orchestrator: the ../.. hop is
# relative to THIS file's location (scripts/test/), so from a smoke.d/ section
# file it would land one level too shallow. Exported before the preamble is
# sourced so every section (and the preamble's §357 snapshot) sees them.
SHELL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export GHJIG_ROOT="$SHELL_ROOT"

# Self-relative source root so mutation.sh's worktree copy (and any relocated
# checkout) resolves its own smoke.d/, not the live tree's.
SMOKE_D="$(dirname "${BASH_SOURCE[0]}")/smoke.d"

# shellcheck source=smoke.d/_preamble.sh
. "$SMOKE_D/_preamble.sh"

# Section files, in source order (numeric prefix = order). Sequential sourcing
# into one shell keeps every cross-section symbol live.
. "$SMOKE_D/10-structure-hooks.sh"
. "$SMOKE_D/20-modes-matchers.sh"
. "$SMOKE_D/30-dirmode-clusters.sh"
. "$SMOKE_D/40-targets-force-push.sh"
. "$SMOKE_D/50-perproject-recall.sh"
. "$SMOKE_D/60-escape-identity.sh"
. "$SMOKE_D/70-gates-contentlocks.sh"

# ---------- results ----------
echo
echo "smoke: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1
