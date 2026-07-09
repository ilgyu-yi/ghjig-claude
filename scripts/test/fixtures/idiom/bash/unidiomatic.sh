#!/usr/bin/env bash
# Fixture (#546): behaviorally CORRECT bash that trips the project bash-idiom
# axis (.claude/rubrics/bash.md) yet stays CLEAN under shellcheck --severity=warning.
# This is the whole point of the readability / language-idiom axis: it lives BELOW
# the correctness severity shellcheck gates. This file is a read-only lint/grep
# target for scripts/lint_bash_idioms.sh — it is never executed.
set -euo pipefail

# safe_source discipline violation: a raw `source` of a helper path instead of
# `safe_source helpers/foo.sh`. The path is a CONSTANT, so shellcheck emits only
# SC1091 (info) — invisible at --severity=warning.
source helpers/foo.sh

# SMELL: detection-by-attribute-combination. Re-infers "is this a gh pr merge?"
# by combining weak substring greps rather than branching on a normalized
# discriminator — correct for the cases enumerated, but the accretion is the smell.
classify() {
  local cmd="$1"
  local is_merge=0
  # attribute pile: substring + substring + value-skip, re-derived per call site
  if printf '%s' "$cmd" | grep -q 'pr' \
     && printf '%s' "$cmd" | grep -q 'merge' \
     && ! printf '%s' "$cmd" | grep -q -- '--repo'; then
    is_merge=1
  fi
  printf '%s\n' "$is_merge"
}

# git add -A prohibition violation: a bare tree-mutating add that should be
# path-scoped. All expansions are quoted, so no SC2086 surfaces.
stage_all() {
  git add -A
}

# Reference the definitions so this parses as a coherent unit; guarded off so the
# fixture stays no-op-safe even if it were ever sourced/run.
if [ "${GHJIG_FIXTURE_RUN:-0}" = "1" ]; then
  classify "gh pr merge 5"
  stage_all
fi
