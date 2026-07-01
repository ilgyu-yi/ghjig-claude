# shellcheck shell=bash
# helpers/recall.sh — episodic retrieval over the project's own decision record
# (closed issues / merged PRs / ADRs) for the /recall skill. SPEC §5.25.
#
# Public:
#   recall_pointers <topic> [--deep] — print POINTERS ONLY, one per line: a tag
#     (#<n> | PR#<n> | ADR-NNNN) + the one-line title. NEVER a body.
#
# Pointers-only is STRUCTURAL, not advisory: the light gh arms project
# `--json number,title`, so a body is never fetched into reach (a later edit
# adding `body` to the projection is the one regression path — smoke §111 pins
# against it). Bounded by RECALL_LIMIT (default 5) per substrate. Fail-open: a
# gh/grep error degrades to whatever substrate still answers and prints a single
# "decision record unavailable" notice — never an error exit, never a body dump.
#
# Two-tier (#524). The LIGHT tier (default) is the title/H1 sweep above and is
# byte-for-byte unchanged when `--deep` is absent. The DEEP tier — gated ONLY by
# the `--deep` sentinel, itself routed ONLY on explicit user intent (see
# commands/recall.md) — additionally scans the COMMENT bodies of the light-tier
# candidate issues. It fetches `gh issue view <n> --json comments` for those
# bounded candidates, then greps the fetched bodies LOCALLY with a FIXED-STRING
# match (`grep -qF`, not regex / not `gh search`, so dotted-version tokens like
# `3.12` survive). The grep is a PREDICATE (match / no-match): the deep arm emits
# ONLY the `#<n> title` pointer of a matched issue — NEVER the matched comment
# text. Bounded by RECALL_LIMIT. Fail-open per candidate: any gh/grep error on a
# candidate degrades to the light-tier result — never errors, never partial-dumps
# a body. Smoke §111 (AC4) / §131 (AC1+mechanism) pin the structure.

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
  local topic="" deep=0 arg
  # Parse args: the topic plus an optional `--deep` sentinel (order-independent).
  # `--deep` routes ONLY on explicit user intent (commands/recall.md), never the
  # pre-planning reflex — absent it, the LIGHT tier below is byte-for-byte unchanged.
  for arg in "$@"; do
    case "$arg" in
      --deep) deep=1 ;;
      *) [ -z "$topic" ] && topic="$arg" ;;
    esac
  done
  local limit="${RECALL_LIMIT:-5}"
  if [ -z "$topic" ]; then
    printf 'recall: usage: /recall <topic>\n'
    return 0
  fi

  local any=0 repo
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || repo=""

  local issues=""
  if [ -n "$repo" ]; then
    # Closed issues — pointers only via field projection (never a body).
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

  # DEEP tier (#524) — gated ONLY by --deep (explicit user intent). Off by
  # default: absent the flag this whole block is skipped, so the light tier above
  # is byte-for-byte unchanged and NO `gh issue view` fetch fires. When on, run a
  # SEPARATE candidate search that — unlike the closed-only light tier — INCLUDES
  # OPEN issues (a decision under active discussion is the high-conviction case,
  # and open-issue comment threads are unreachable by the light tier). For each
  # bounded candidate, fetch its comments and match them LOCALLY with a
  # token-aware FIXED-STRING predicate (`grep -qF` on the whole topic, else any
  # topic token >= 3 chars, so dotted tokens like 3.12 survive), then emit ONLY
  # the pointers the light tier did NOT already print (dedup — no double-print) —
  # never the matched comment text. Bounded by RECALL_LIMIT; fail-open per candidate.
  if [ "$deep" = 1 ] && [ -n "$repo" ]; then
    local dcands
    dcands=$(gh search issues "$topic" --repo "$repo" \
      --limit "$limit" --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null) || dcands=""
    if [ -n "$dcands" ]; then
      local line num bodies tok matched oldopt dcount=0
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        [ "$dcount" -ge "$limit" ] && break
        num=$(printf '%s' "$line" | grep -oE '^#[0-9]+' | grep -oE '[0-9]+')
        [ -n "$num" ] || continue
        # Dedup: never re-emit a pointer the light tier already printed.
        printf '%s\n' "$issues" | grep -qxF -- "$line" && continue
        # Comment bodies for this candidate — fetched, never printed. Fail-open:
        # a gh error yields an empty set and the candidate is silently skipped.
        bodies=$(gh issue view "$num" --repo "$repo" --json comments \
          --jq '.comments[].body' 2>/dev/null) || bodies=""
        [ -n "$bodies" ] || continue
        # Token-aware PREDICATE (match/no-match), FIXED-STRING only. Whole topic
        # first; else split into tokens with globbing disabled (topics are data,
        # never patterns) and match any token >= 3 chars.
        matched=0
        if printf '%s' "$bodies" | grep -qF -- "$topic"; then
          matched=1
        else
          oldopt=$-; set -f
          for tok in $topic; do
            [ "${#tok}" -ge 3 ] || continue
            if printf '%s' "$bodies" | grep -qF -- "$tok"; then matched=1; break; fi
          done
          case "$oldopt" in *f*) ;; *) set +f ;; esac
        fi
        if [ "$matched" = 1 ]; then
          printf '%s\n' "$line"   # pointer only — never the matched comment body
          dcount=$((dcount + 1)); any=1
        fi
      done <<EOF
$dcands
EOF
    fi
  fi

  [ "$any" = 1 ] || printf 'recall: no matches in the decision record for "%s"\n' "$topic"
  return 0
}
