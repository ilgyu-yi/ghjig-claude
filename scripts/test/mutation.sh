#!/usr/bin/env bash
# scripts/test/mutation.sh — enforcement-matcher mutation harness (#423).
#
# Measures the smoke suite's KILL-RATE on the critical matchers. The smoke suite
# asserts the matchers behave correctly; this proves those assertions actually
# kill a regression. For each matcher it appends a weakened redefinition to a
# throwaway git-worktree copy (append-override: bash takes the last definition),
# runs the full smoke suite there with CLAUDE_ENG_SHELL_ROOT pointed at the
# worktree, and asserts smoke FAILS (exit != 0 — the mutant is killed). A
# SURVIVING mutant (smoke still green under a weakened guard) is a harness
# failure: the matcher is no longer pinned by any assertion. The worktree
# isolates the mutation from the live tree. SPEC §11.1.
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "mutation: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
command -v git >/dev/null 2>&1 || { echo "mutation: git unavailable" >&2; exit 2; }

# Each entry: "<label>|<helper-relpath>|<append-override>". The override is a
# weakened redefinition that neuters the matcher; smoke must catch it.
MUTATIONS=(
  "commit-format|.claude/hooks/helpers/conventional_commit.sh|check_commit_subject() { return 0; }"
  "secret|.claude/hooks/helpers/secret_scan.sh|scan_staged_secrets() { return 0; }"
  "protected-branch|.claude/hooks/helpers/git_matcher.sh|PROTECTED_BRANCH_PATTERN='__mutation_never_match__'"
)

killed=0; survived_list=""
# Track the in-flight worktree/tempdir so an interrupt (SIGINT/SIGTERM) mid-smoke
# doesn't leak them — the per-iteration cleanup below handles the normal path.
_mut_base=""; _mut_wt=""
_mut_cleanup() {
  [ -n "$_mut_wt" ] && git worktree remove --force "$_mut_wt" 2>/dev/null
  [ -n "$_mut_base" ] && rm -rf "$_mut_base" 2>/dev/null
  git worktree prune 2>/dev/null || true
}
trap _mut_cleanup EXIT INT TERM

for m in "${MUTATIONS[@]}"; do
  label=${m%%|*}; rest=${m#*|}; relpath=${rest%%|*}; override=${rest#*|}
  base=$(mktemp -d) || { echo "mutation: mktemp failed" >&2; exit 2; }
  wt="$base/mut-$label"
  _mut_base="$base"; _mut_wt="$wt"   # arm the interrupt-cleanup trap for this iteration

  if ! git worktree add --quiet --detach "$wt" HEAD 2>/dev/null; then
    echo "mutation: ERROR — git worktree add failed for $label" >&2
    survived_list="$survived_list $label(setup-error)"
    rm -rf "$base" 2>/dev/null
    continue
  fi

  # Apply the mutation to the worktree copy only (never the live tree).
  printf '\n# --- mutation harness override (#423): weaken %s ---\n%s\n' "$label" "$override" >> "$wt/$relpath"

  # Run the full smoke suite against the mutated worktree. CLAUDE_ENG_SHELL_ROOT
  # forces all hook/helper resolution to the worktree so the mutated helper is
  # the one exercised. Smoke is offline-deterministic by default.
  if CLAUDE_ENG_SHELL_ROOT="$wt" bash "$wt/scripts/test/smoke.sh" >/dev/null 2>&1; then
    echo "SURVIVED  $label — smoke stayed green under a weakened matcher (guard unpinned)"
    survived_list="$survived_list $label"
  else
    echo "killed    $label — smoke caught the weakened matcher"
    killed=$((killed + 1))
  fi

  git worktree remove --force "$wt" 2>/dev/null
  rm -rf "$base" 2>/dev/null
  _mut_wt=""; _mut_base=""   # disarm — this iteration cleaned up normally
done

echo
total=${#MUTATIONS[@]}
echo "mutation: killed=$killed/$total"
if [ -n "$survived_list" ]; then
  echo "mutation: FAIL — surviving mutants:$survived_list" >&2
  echo "mutation: a surviving mutant means the smoke suite no longer pins that matcher's guard." >&2
  exit 1
fi
echo "mutation: all mutants killed — the critical enforcement matchers are pinned by smoke"
