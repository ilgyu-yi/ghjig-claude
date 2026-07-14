# shellcheck shell=bash
# scripts/test/smoke.d/_preamble.sh — shared globals + helpers for the smoke
# suite (#600). Sourced FIRST by scripts/test/smoke.sh, before any NN-*.sh
# section file, so every section sees these symbols. SHELL_ROOT/GHJIG_ROOT are
# resolved+exported by the orchestrator BEFORE this file is sourced (from here
# the ../.. hop would resolve one level too shallow).
#
# SC2034: many scalars below (TMP, HOOK, POST_HOOK, ESC_HOOK, SMOKE_*, S357_*,
# s357_*) are consumed only by sibling section files sourced later into the
# same shell, so a standalone lint of this file sees them as unused.
# shellcheck disable=SC2034

set -uo pipefail

# §357 AC1 backstop (capture half) — snapshot the LIVE shared sinks' size BEFORE
# any fixture fires. Reads the literal $SHELL_ROOT paths (NOT $SMOKE_*): a smoke
# run must add ZERO lines to the shell's live audit log + scope registry (state
# isolation, #357). The matching assertion sits just before the results block;
# it fails LOUD if a future change reintroduces a live-sink write. Captured here,
# before the §4 registry backup, so it reflects the truly untouched live state.
S357_LIVE_AUDIT="$SHELL_ROOT/.claude/audit/audit.jsonl"
S357_LIVE_REG="$SHELL_ROOT/.claude/state/registry.txt"
# Guard with [ -f ] before the `< file` redirect: bash applies `< file` BEFORE
# `2>/dev/null`, so on an absent path the open-failure reaches the real stderr
# unsuppressed (a spurious "No such file" line, #417). An absent sink snapshots
# as 0 — the assertion semantics are unchanged.
s357_audit_before=0; [ -f "$S357_LIVE_AUDIT" ] && s357_audit_before=$(wc -l < "$S357_LIVE_AUDIT" | tr -d ' ')
s357_reg_before=0; [ -f "$S357_LIVE_REG" ] && s357_reg_before=$(wc -l < "$S357_LIVE_REG" | tr -d ' ')

# §357 — pin ALL fixture hook fires to an isolated ephemeral state dir for the
# whole run. ghjig_state_dir() honors GHJIG_STATE_DIR_OVERRIDE as top priority, so
# every audit_log + argless ghjig_registry_file (in_scope) resolves here instead
# of the shell's live shared sinks. Class A registry writes target $SMOKE_REG;
# resolver-contract tests (§83/§84) and §20 locally `unset` this to exercise the
# other branches; Class B guard tests (§41/§50) register on their target's own
# per-project ghjig-state path. Cleaned on EXIT (see the §4 trap).
SMOKE_STATE=$(mktemp -d)
SMOKE_AUDIT="$SMOKE_STATE/audit/audit.jsonl"
SMOKE_REG="$SMOKE_STATE/registry.txt"
mkdir -p "$SMOKE_STATE/audit"
export GHJIG_STATE_DIR_OVERRIDE="$SMOKE_STATE"
# #586 — merge-review REPLACES the retired merge-attestation file arm (#544).
# The gate now reads a GitHub review OBJECT at the current head via `gh` (not a
# $(ghjig_state_dir)/attest/pr-<N> file), so no state-dir seed makes the
# pre-existing ac-closeout/merge-strategy/pass-through merge fixtures pass it.
# Instead each of those fixtures' gh shims (§38/§39/§78) serves a canned
# APPROVED-at-head review whose commit_id == the `smoke-attest-head` its
# headRefOid arm reports, plus a nameWithOwner — so merge-review resolves to a
# SILENT mark_allow (native APPROVED@head) and each fixture keeps asserting its
# own gate's verdict with no bypass-audit noise polluting the audit-count
# assertions. (The §137/§140 suites override GHJIG_STATE_DIR_OVERRIDE and carry
# their own per-case gh state, so nothing here leaks into them.)
# §361 — mark every fixture-fire audit record as test-origin (Directive #356
# signal 1). Only the exact token `test` flips audit_log's `source` field; a
# real Bash-tool action cannot inject this into the hook subprocess (SPEC §7),
# so `source=live` stays the trustworthy default for real sessions. §93's
# default/forged-value sub-tests locally unset / re-set this.
export GHJIG_AUDIT_SOURCE=test

PASS=0
FAIL=0
ok() { printf '✓ %s\n' "$1"; PASS=$((PASS+1)); }
ng() { printf '✗ %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

# TMP + its EXIT trap (moved here from §4 so all sections share one scratch dir,
# #600). The trap also cleans the §357 isolated state dir.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$SMOKE_STATE"' EXIT

# Hook entrypoints reused across section boundaries (moved from §15/§23/§125,
# #600).
HOOK="$SHELL_ROOT/.claude/hooks/pre_tool_use.sh"
POST_HOOK="$SHELL_ROOT/.claude/hooks/post_tool_use.sh"
ESC_HOOK="$SHELL_ROOT/.claude/hooks/pre_tool_use.sh"
