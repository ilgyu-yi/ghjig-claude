#!/usr/bin/env bash
# scripts/ceremony_candidates.sh [<repo-dir>] [<min-count>]
#
# Surface CEREMONY mis-sizing over commit history as measure-first candidates
# (SPEC §6.0 P3, §6.5(d); Directive #401). READ-ONLY / surfacing-only: it lists
# candidates; no gate, no weight model, no author-facing field. The narrow/harden
# decision stays human / reviewer judgment (#41 principle #3).
#
# Unlike the two audit-log siblings (narrowing_/promotion_candidates.sh), the
# ceremony signal is NOT in audit.jsonl — it lives in `git log`: the commit-subject
# `type(#n):` prefix, the Doc→Test→Code phase arc, and the changed-file count. So
# this reader mines git history of <repo-dir> (default $CLAUDE_PROJECT_DIR or PWD),
# groups commits by `#<issue>`, and flags BOTH directions:
#   - under-ceremony: a group with a `feat` commit spanning >1 file but NO `test`
#                     and NO `docs` phase commit (landed a feature with no phase arc).
#   - over-ceremony:  a group of >=3 commits forming a phase arc (a `test`/`docs`
#                     commit present) over a single changed file (full phasing on a
#                     one-file change).
# Honest limits (surfaced, not corrected): a batched single-commit PR collapses the
# arc → possible under-ceremony false positive; over-classification is weak.
#
# Output: a header + indented `  #<issue> | <kind> | files=N commits=C` cluster
# lines (the shape the §6.5(d) advisory greps), or `  (none above threshold)`.
# Lookback: $CEREMONY_LOOKBACK commits (default 300). Threshold: surface only when
# the flagged-group count >= min-count ($2 or $CEREMONY_MIN_COUNT, default 1).
# Always exits 0; a non-repo / absent dir / missing base degrades to silence. No
# gh, no network, no mutation, no jq.

set -uo pipefail

dir="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
min_count="${2:-${CEREMONY_MIN_COUNT:-1}}"
case "$min_count" in ""|*[!0-9]*) min_count=1 ;; esac
lookback="${CEREMONY_LOOKBACK:-300}"
case "$lookback" in ""|*[!0-9]*) lookback=300 ;; esac

# Fail-open: not a directory, or not a git work tree → silence, exit 0.
if [ ! -d "$dir" ] || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ceremony-candidates: no git history (dir: ${dir:-<unset>})"
  exit 0
fi

echo "ceremony candidates (commit-history mis-sizing; min_count=$min_count):"

# One git call: per commit a header line (\x01<hash>\x1f<subject>) followed by its
# changed file paths (--name-only). awk groups by #<issue> and flags both directions.
out=$(
  git -C "$dir" log --no-merges -n "$lookback" --name-only \
      --format=$'\x01%H\x1f%s' 2>/dev/null \
  | awk -v sep1=$'\x01' -v sep2=$'\x1f' -v minc="$min_count" '
    function flush() {}
    {
      if (substr($0,1,1) == sep1) {
        # commit header
        line = substr($0,2)
        p = index(line, sep2)
        subj = (p>0) ? substr(line, p+1) : line
        cur = ""
        if (match(subj, /^(feat|fix|docs|refactor|perf|test|style|build|ci|chore|revert)\(#[0-9]+\)/)) {
          tok = substr(subj, RSTART, RLENGTH)        # e.g. feat(#901)
          ti = index(tok, "(")
          type = substr(tok, 1, ti-1)
          iss = tok; sub(/^[a-z]+\(#/, "", iss); sub(/\).*/, "", iss)
          cur = iss
          commits[iss]++
          if (type == "feat") hasfeat[iss] = 1
          if (type == "test") hastest[iss] = 1
          if (type == "docs") hasdocs[iss] = 1
          seen[iss] = 1
        }
        next
      }
      if ($0 == "") next
      # a file path belonging to the current (recognized) commit
      if (cur != "") {
        key = cur SUBSEP $0
        if (!(key in pathseen)) { pathseen[key] = 1; files[cur]++ }
      }
    }
    END {
      n = 0
      for (i in seen) {
        fc = (i in files) ? files[i] : 0
        cc = commits[i]
        kind = ""
        if (hasfeat[i] && fc > 1 && !hastest[i] && !hasdocs[i]) kind = "under-ceremony"
        else if (cc >= 3 && (hastest[i] || hasdocs[i]) && fc == 1) kind = "over-ceremony"
        if (kind != "") { flag[n] = sprintf("  #%s | %s | files=%d commits=%d", i, kind, fc, cc); n++ }
      }
      if (n >= minc && n > 0) {
        for (j = 0; j < n; j++) print flag[j]
      }
    }
  ' 2>/dev/null
)

if [ -z "$out" ]; then
  echo "  (none above threshold)"
else
  printf '%s\n' "$out" | sort
fi
exit 0
