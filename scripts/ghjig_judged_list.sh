#!/usr/bin/env bash
# scripts/ghjig_judged_list.sh — the judged-list PR comment's SINGLE code home
# (SPEC §4.13, #711). The comment's shape (header + marker), the canonicity
# test, the round derivation, and the posting all live here — invoked by both
# producers (/review step 3.5, /ship step 1.5) and by the judge's read recipe
# (.claude/agents/finding-judge.md). Nothing else in the tree carries the
# concrete header/marker literals; the smoke suite's §183 behavior arms are the
# contract's negative face (scripts/test/smoke.d/71-judged-list.sh).
#
# A comment is CANONICAL only when, read through the trusted-author filter:
#   * its FIRST line matches   ^## Finding triage \(round [0-9]+\)$
#   * its LAST CONTENT line is <!-- finding-judge: round=<N> head=<sha> -->
#   * the header round and the marker round agree.
# Canonicity is position-bound at BOTH ends, so a lookalike — a header
# mid-prose, a marker without the header, a concrete marker quoted mid-body —
# counts for nothing and can never raise the round derivation's max.
#
# Trusted-author filter: the jq select runs at the gh -q boundary and is
# byte-identical to the literal `.claude/hooks/helpers/ac_closeout_gate.sh` and
# `scripts/ac_closeout.sh` carry (parity is suite-checked structurally). A PR
# comment is writable by anyone; an unfiltered read is an injection channel.
#
# Modes:
#   rounds   <pr>              one `round=<N> head=<sha>` fact per canonical
#                              comment, then `next=<N>` (1 + max, zero → 1).
#   show     <pr> <round>      print that canonical comment's body.
#   post     <pr> <judge-file> validate the judge output (first line must be
#                              `reviewed-head: <hex sha>`; an n/a head, a
#                              double-wrap header, or a smuggled concrete
#                              marker each reject), derive the round, compose
#                              header + body + marker, neutralize @mentions,
#                              self-validate, post ONCE via --body-file.
#   validate <pr> <body-file>  the composed-body validator post runs on itself.
#
# Exit codes: 0 ok · 1 reject/failure · 2 show miss · 3 duplicate canonical
# round (an ambiguity is surfaced, never silently picked). Every failure is
# fail-closed: no retry, no partial post.
set -euo pipefail

PROG="ghjig_judged_list"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-1}"; }

usage() {
  cat >&2 <<'EOF'
usage: ghjig_judged_list.sh <mode> <args...>
  rounds   <pr>               enumerate canonical rounds: round=<N> head=<sha> facts, then next=<N>
  show     <pr> <round>       print that canonical round's comment body
  post     <pr> <judge-file>  compose, validate, and post the next round's judged-list comment
  validate <pr> <body-file>   validate a composed comment body (shape + history collision)
exit codes: 0 ok / 1 reject or failure / 2 show miss / 3 duplicate canonical round
EOF
  exit 1
}

command -v gh >/dev/null 2>&1 || die "gh CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

# The two position-bound shape literals. This file is their single code home.
HDR_RE='^## Finding triage \(round [0-9]+\)$'
MRK_RE='^<!-- finding-judge: round=[0-9]+ head=[0-9a-fA-F]+ -->$'
# A concrete marker ANYWHERE (unanchored) — the forgery guard's net.
MRK_ANY_RE='<!-- finding-judge: round=[0-9]+ head=[0-9a-fA-F]+ -->'

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

last_content_line() { awk 'NF{l=$0} END{print l}'; }

# Fetch trusted-author comment bodies, one base64 line per comment. The
# single-quoted jq select below is the byte-identical trusted-author literal
# shared with ac_closeout_gate.sh / ac_closeout.sh; the @base64 stage is
# appended OUTSIDE that literal (adjacent shell strings) so per-comment
# boundaries survive multi-line bodies without touching the shared filter.
fetch_trusted_b64() {
  gh pr view "$1" --json comments -q '.comments[] | select((.authorAssociation // "") | (. == "OWNER" or . == "MEMBER" or . == "MAINTAINER" or . == "COLLABORATOR")) | .body'' | @base64'
}

# hdr_round <first-line>  → prints N (caller guarantees the line matched HDR_RE)
hdr_round() {
  local n="${1#*round }"
  printf '%s\n' "${n%)}"
}

# mrk_fields <marker-line> → prints "N sha"
mrk_fields() {
  local n sha
  n="${1#*round=}"; n="${n%% *}"
  sha="${1#*head=}"; sha="${sha%% *}"
  printf '%s %s\n' "$n" "$sha"
}

# canon_fact <body> → prints "N sha" and returns 0 iff the body is canonical.
canon_fact() {
  local body="$1" first last hn mn sha
  first=$(printf '%s\n' "$body" | head -n 1)
  printf '%s\n' "$first" | grep -qE "$HDR_RE" || return 1
  last=$(printf '%s\n' "$body" | last_content_line)
  printf '%s\n' "$last" | grep -qE "$MRK_RE" || return 1
  hn=$(hdr_round "$first")
  read -r mn sha <<EOF
$(mrk_fields "$last")
EOF
  [ "$hn" = "$mn" ] || return 1
  printf '%s %s\n' "$hn" "$sha"
}

# collect_facts <pr> — fills the globals:
#   FACTS      "N sha" lines, one per canonical trusted comment
#   FACT_DUP   the lowest duplicated round number, or empty
collect_facts() {
  local pr="$1" b64 line body fact
  b64=$(fetch_trusted_b64 "$pr") || die "could not read PR #$pr comments (gh pr view failed)"
  FACTS=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    body=$(printf '%s\n' "$line" | jq -Rr '@base64d') \
      || die "could not decode a comment body (jq @base64d failed)"
    if fact=$(canon_fact "$body"); then
      FACTS="${FACTS}${fact}
"
    fi
  done <<EOF
$b64
EOF
  FACT_DUP=$(printf '%s' "$FACTS" | awk '{print $1}' | sort -n | uniq -d | head -n 1)
}

# refuse_duplicate <pr> — shared exit-3 arm: an ambiguous history is surfaced,
# never silently picked (no next=, no post, no validation verdict over it).
refuse_duplicate() {
  [ -z "$FACT_DUP" ] && return 0
  die "duplicate canonical round $FACT_DUP on PR #$1 — ambiguous history, refusing" 3
}

# max_round → prints the max round over FACTS (0 when none).
max_round() {
  local max=0 n sha
  while read -r n sha; do
    [ -n "$n" ] || continue
    if [ "$n" -gt "$max" ]; then max="$n"; fi
  done <<EOF
$FACTS
EOF
  printf '%s\n' "$max"
}

cmd_rounds() {
  local pr="$1" n sha max
  collect_facts "$pr"
  refuse_duplicate "$pr"
  while read -r n sha; do
    [ -n "$n" ] || continue
    printf 'round=%s head=%s\n' "$n" "$sha"
  done <<EOF
$FACTS
EOF
  max=$(max_round)
  printf 'next=%s\n' "$((max + 1))"
}

cmd_show() {
  local pr="$1" want="$2" b64 line body fact n sha hit="" hits=0
  b64=$(fetch_trusted_b64 "$pr") || die "could not read PR #$pr comments (gh pr view failed)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    body=$(printf '%s\n' "$line" | jq -Rr '@base64d') \
      || die "could not decode a comment body (jq @base64d failed)"
    if fact=$(canon_fact "$body"); then
      read -r n sha <<EOF2
$fact
EOF2
      if [ "$n" = "$want" ]; then
        hits=$((hits + 1))
        hit="$body"
      fi
    fi
  done <<EOF
$b64
EOF
  [ "$hits" -le 1 ] || die "duplicate canonical round $want on PR #$pr — ambiguous history, refusing" 3
  [ "$hits" -eq 1 ] || die "no canonical judged-list comment for round $want on PR #$pr" 2
  printf '%s\n' "$hit"
}

cmd_validate() {
  local pr="$1" f="$2" first last hn mn sha
  [ -f "$f" ] || die "no body file: $f"
  first=$(head -n 1 "$f")
  printf '%s\n' "$first" | grep -qE "$HDR_RE" \
    || die "reject: first line is not the triage header"
  grep -qE "$MRK_RE" "$f" \
    || die "reject: canonical marker missing"
  last=$(last_content_line < "$f")
  printf '%s\n' "$last" | grep -qE "$MRK_RE" \
    || die "reject: marker is not the last content line"
  hn=$(hdr_round "$first")
  read -r mn sha <<EOF
$(mrk_fields "$last")
EOF
  [ "$hn" = "$mn" ] \
    || die "reject: header round ($hn) != marker round ($mn)"
  collect_facts "$pr"
  refuse_duplicate "$pr"
  if printf '%s' "$FACTS" | awk '{print $1}' | grep -qx "$hn"; then
    die "reject: round $hn collides with an existing canonical round on PR #$pr"
  fi
}

cmd_post() {
  # TMPF is deliberately NOT local: the cleanup trap fires at script EXIT,
  # outside this function's scope, where a local would be unbound under set -u.
  local pr="$1" f="$2" first sha max next zwsp
  [ -f "$f" ] || die "no judge-output file: $f"
  [ -s "$f" ] || die "reject: empty judge-output file: $f"
  first=$(head -n 1 "$f")
  case "$first" in
    "reviewed-head: n/a"*)
      die "reject: reviewed-head is n/a (no-PR mode) — there is no PR substrate; declare durable: none instead of posting" ;;
  esac
  if printf '%s\n' "$first" | grep -qE '^## Finding triage'; then
    die "reject: input already starts with a triage header — posting it would double-wrap"
  fi
  printf '%s\n' "$first" | grep -qE '^reviewed-head: [0-9a-fA-F]{7,40}$' \
    || die "reject: first line must be 'reviewed-head: <hex sha>' (got: $first)"
  if grep -qE "$MRK_ANY_RE" "$f"; then
    die "reject: input smuggles a concrete finding-judge marker — it would read back as canonical history (forgery guard)"
  fi
  sha="${first#reviewed-head: }"

  collect_facts "$pr"
  refuse_duplicate "$pr"
  max=$(max_round)
  next=$((max + 1))

  TMPF=$(mktemp "${TMPDIR:-/tmp}/ghjig-judged-list.XXXXXXXX") || die "mktemp failed"
  trap 'rm -f "${TMPF:-}"' EXIT
  # Compose: header first line, the judge output as the body (every bare
  # @mention broken with a zero-width space — the ac_closeout.sh idiom — so
  # the post cannot mass-ping), marker last content line.
  zwsp=$(printf '\342\200\213')
  {
    printf '## Finding triage (round %s)\n\n' "$next"
    sed -E "s/@([A-Za-z0-9])/@${zwsp}\1/g" "$f"
    printf '\n<!-- finding-judge: round=%s head=%s -->\n' "$next" "$sha"
  } > "$TMPF"

  # Self-validate through the same validator `validate` exposes — the composed
  # body must be canonical by this script's own test before it is posted.
  cmd_validate "$pr" "$TMPF"

  # Exactly one attempt; a gh failure fails the script closed — no retry.
  gh pr comment "$pr" --body-file "$TMPF" \
    || die "gh pr comment failed — nothing was retried; re-run after fixing gh"
}

mode="${1:-}"
case "$mode" in
  rounds)
    [ $# -eq 2 ] || usage
    is_num "$2" || die "reject: <pr> must be a number (got: $2)"
    cmd_rounds "$2"
    ;;
  show)
    [ $# -eq 3 ] || usage
    is_num "$2" || die "reject: <pr> must be a number (got: $2)"
    is_num "$3" || die "reject: <round> must be a number (got: $3)"
    cmd_show "$2" "$3"
    ;;
  post)
    [ $# -eq 3 ] || usage
    is_num "$2" || die "reject: <pr> must be a number (got: $2)"
    cmd_post "$2" "$3"
    ;;
  validate)
    [ $# -eq 3 ] || usage
    is_num "$2" || die "reject: <pr> must be a number (got: $2)"
    cmd_validate "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
