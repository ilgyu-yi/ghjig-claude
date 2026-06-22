# shellcheck shell=bash
# helpers/recall.sh — episodic retrieval over the project's own decision record
# (closed issues / merged PRs / ADRs) for the /recall skill. SPEC §5.25.
#
# Public:
#   recall_pointers <topic> — print POINTERS ONLY, one per line: a tag
#     (#<n> | PR#<n> | ADR-NNNN) + the one-line title. NEVER a body.
#
# Pointers-only is STRUCTURAL, not advisory: the gh arms project
# `--json number,title`, so a body is never fetched into reach (a later edit
# adding `body` to the projection is the one regression path — smoke §111 pins
# against it). Bounded by RECALL_LIMIT (default 5) per substrate. Fail-open: a
# gh/grep error degrades to whatever substrate still answers and prints a single
# "decision record unavailable" notice — never an error exit, never a body dump.

# ADR directory — the local half of the decision record. Scoped to the PROJECT
# repo (the cwd's git toplevel), NOT the shell root: the gh arms resolve to the
# current repo via `gh repo view`, so the ADR arm must read the same project's
# docs/ADRs/ — else a bound target would merge the project's issues/PRs with the
# shell's ADRs (two different repos' records). Fall back to cwd when not in git.
_recall_adr_dir() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="."
  printf '%s' "$root/docs/ADRs"
}

recall_pointers() {
  local topic="$1"
  local limit="${RECALL_LIMIT:-5}"
  if [ -z "$topic" ]; then
    printf 'recall: usage: /recall <topic>\n'
    return 0
  fi

  local any=0 repo
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || repo=""

  if [ -n "$repo" ]; then
    # Closed issues — pointers only via field projection (never a body).
    local issues
    issues=$(gh search issues "$topic" --repo "$repo" --state closed \
      --limit "$limit" --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null)
    if [ -n "$issues" ]; then printf '%s\n' "$issues"; any=1; fi
    # Merged/closed PRs — separate call so PR pointers tag distinctly.
    local prs
    prs=$(gh search prs "$topic" --repo "$repo" --state closed \
      --limit "$limit" --json number,title --jq '.[] | "PR#\(.number) \(.title)"' 2>/dev/null)
    if [ -n "$prs" ]; then printf '%s\n' "$prs"; any=1; fi
  else
    # gh unavailable (offline / unauthenticated / rate-limited): fail-open —
    # degrade to the local ADR substrate rather than blocking or erroring.
    printf 'recall: decision record unavailable (gh issues/PRs) — showing local ADRs only\n'
  fi

  # ADRs — title/H1 match over docs/ADRs/*.md (no body grep), capped at RECALL_LIMIT.
  local adr_dir; adr_dir=$(_recall_adr_dir)
  if [ -d "$adr_dir" ]; then
    local f h num title count=0
    for f in "$adr_dir"/*.md; do
      [ -f "$f" ] || continue
      [ "$count" -ge "$limit" ] && break
      h=$(head -1 "$f" 2>/dev/null)
      if printf '%s' "$h" | grep -qi -- "$topic"; then
        num=$(basename "$f" | grep -oE '^[0-9]+')
        title=${h#\# }        # strip leading "# "
        title=${title#*: }    # then the "ADR NNNN: " prefix when present (no-op if no colon)
        printf 'ADR-%s %s\n' "$num" "$title"
        count=$((count + 1)); any=1
      fi
    done
  fi

  [ "$any" = 1 ] || printf 'recall: no matches in the decision record for "%s"\n' "$topic"
  return 0
}
