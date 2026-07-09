#!/usr/bin/env bash
# Fixture (#546): the idiomatic counterpart to unidiomatic.sh. Behaviorally
# equivalent, but written the way bash wants to be written — safe_source, a
# path-scoped add, and a normalized discriminator. Fully shellcheck-clean AND
# idiom-clean: scripts/lint_bash_idioms.sh must emit NO findings over this file.
# Read-only lint/grep target; never executed.
set -euo pipefail

# safe_source discipline: fail-open helper source through the sanctioned wrapper.
safe_source helpers/foo.sh

# Normalize once to the parsed verb (the explicit discriminator), then branch on
# it — never re-derive the substring combination per call site.
classify() {
  local cmd="$1"
  local is_merge=0
  local verb
  verb="$(parse_gh_argv "$cmd")"
  if [ "$verb" = "pr-merge" ]; then
    is_merge=1
  fi
  printf '%s\n' "$is_merge"
}

# Path-scoped add — never a bare `git add -A`/`-u`.
stage_one() {
  git add scripts/foo.sh
}

# Guarded reference so the fixture parses as a coherent unit and stays no-op-safe.
if [ "${GHJIG_FIXTURE_RUN:-0}" = "1" ]; then
  classify "gh pr merge 5"
  stage_one
fi
