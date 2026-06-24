#!/usr/bin/env bash
# scripts/spec_drift_candidates.sh [<repo-dir>] [<min-count>]
#
# Surface CODE-vs-SPEC drift over commit history as measure-first candidates
# (SPEC §6.0 P3, §6.5(d); Directive #455). READ-ONLY / surfacing-only: it lists
# candidates; no gate, no classification, no correction. The narrow/harden — and
# here the reconcile — decision stays human / reviewer judgment (#41 principle #3).
#
# Like ceremony_candidates.sh (not the audit-log siblings) it mines `git log`. The
# signal is CODE-AHEAD drift: a commit that touched a repo path SPEC.md references,
# WITHOUT co-touching SPEC.md in the same commit — "code moved, SPEC didn't". The
# referenced-path set is derived from SPEC.md at run time (grep), never hardcoded.
#
# Output: a header + indented `  <path> | drift-commits=N` cluster lines (the shape
# the §6.5(d) advisory greps), or `  (no spec-drift candidates)`. Lookback:
# $SPEC_DRIFT_LOOKBACK commits (default 300). Threshold: surface only when a path's
# drift-commit count >= min-count ($2 or $SPEC_DRIFT_MIN_COUNT, default 1). Always
# exits 0; a non-repo / absent dir / absent-or-unreferencing SPEC.md degrades to a
# sentinel. No gh, no network, no mutation, no jq.
#
# Detection only. The three-way classification (spec-ahead / code-ahead-correct /
# code-wrong) and the user-gated SPEC correction are the sibling /reconcile-spec flow;
# wiring this reader into the §6.5(d) advisory is a later sibling. Honest limits
# (surfaced, not corrected): a batched commit touching code AND SPEC.md for unrelated
# reasons masks a real drift; the path-token grep is coarse. It over-surfaces by design.

set -uo pipefail

dir="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
min_count="${2:-${SPEC_DRIFT_MIN_COUNT:-1}}"
case "$min_count" in ""|*[!0-9]*) min_count=1 ;; esac
lookback="${SPEC_DRIFT_LOOKBACK:-300}"
case "$lookback" in ""|*[!0-9]*) lookback=300 ;; esac

# Fail-open: not a directory, or not a git work tree → sentinel, exit 0.
if [ ! -d "$dir" ] || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "spec-drift candidates: no git history (dir: ${dir:-<unset>})"
  echo "  (no spec-drift candidates)"
  exit 0
fi

echo "spec-drift candidates (code-ahead; min_count=$min_count):"

# Referenced-path set from SPEC.md at run time. Anchor on the real top-level repo
# prefixes + a required file extension so prose fragments / trailing punctuation do
# not enter the set. Strip a defensive trailing dot. Empty set (no SPEC.md, or it
# references nothing) → sentinel.
refs=""
if [ -f "$dir/SPEC.md" ]; then
  refs=$(grep -oE '(scripts|bin|\.claude)/[A-Za-z0-9_./-]+\.(sh|md|yml|yaml)' "$dir/SPEC.md" 2>/dev/null \
         | sed 's/\.$//' | sort -u)
fi
if [ -z "$refs" ]; then
  echo "  (no spec-drift candidates)"
  exit 0
fi
# Flatten to a space-separated list for `awk -v` (a value with embedded newlines is
# rejected by awk with "newline in string"); repo paths never contain spaces.
refs_flat=$(printf '%s' "$refs" | tr '\n' ' ')

# One git call: per commit a header line (\x01<hash>) followed by its changed file
# paths (--name-only). awk flags, per commit, whether SPEC.md was touched; for each
# changed path in the referenced set touched WITHOUT SPEC.md, increments a per-path
# drift counter (one increment per drifting commit).
out=$(
  git -C "$dir" log --no-merges -n "$lookback" --name-only \
      --format=$'\x01%H' 2>/dev/null \
  | awk -v refs="$refs_flat" -v minc="$min_count" '
    BEGIN {
      sep = sprintf("%c", 1)
      n = split(refs, a, " ")
      for (i = 1; i <= n; i++) if (a[i] != "") ref[a[i]] = 1
      incommit = 0; touched_spec = 0
    }
    function flush(   p) {
      if (incommit && !touched_spec) {
        for (p in cf) if (p in ref) drift[p]++
      }
      incommit = 0; touched_spec = 0; split("", cf)
    }
    {
      if (substr($0, 1, 1) == sep) { flush(); incommit = 1; next }
      if ($0 == "") next
      if (incommit) {
        cf[$0] = 1
        if ($0 == "SPEC.md") touched_spec = 1
      }
    }
    END {
      flush()
      for (p in drift) if (drift[p] >= minc) printf "  %s | drift-commits=%d\n", p, drift[p]
    }
  ' 2>/dev/null
)

if [ -z "$out" ]; then
  echo "  (no spec-drift candidates)"
else
  printf '%s\n' "$out" | sort
fi
exit 0
