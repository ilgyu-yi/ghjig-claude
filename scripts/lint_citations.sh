#!/usr/bin/env bash
# scripts/lint_citations.sh — born-advisory, non-gating citation reader (#676).
# See SPEC §1.10.
#
# Mechanizes the LEXICAL half of §1.10 part (a) — a quoted span in a
# durable-artifact body resolves in the FILE it is attributed to — and nothing
# else. Part (b) (a corpus-quantified claim carries its literal command and
# output) is reviewer judgment and is deliberately not mechanized; so is a
# quotation read out of its paragraph, which a lexical reader is blind to by
# construction.
#
#   1. EXTRACT the body's quoted spans, one line at a time: both `*"…"*` and
#      plain `"…"`, non-greedy. Fenced code blocks are excluded (an awk ```
#      toggle — the only multi-line state this reader keeps). Spans under four
#      words are skipped: below that floor scare-quotes and `${#X}` forms
#      dominate and every extra finding measured on the corpus was false.
#   2. ATTRIBUTE each span to the nearest path-shaped inline-code token on the
#      SAME LINE, preceding-preferred, else nearest following. A bare `:NN`
#      inherits the last path on that line. There is no paragraph lookback: on
#      the measured corpus a <=3-lines-back fallback fired twice and was wrong
#      both times.
#   3. RESOLVE on a four-rung ladder, reporting per span the search it ran:
#        (1) `git grep -F` at the attributed path            -> resolves
#        (2) same path, whitespace/line-wrap normalized       -> normalized
#        (3) repo-wide, excluding the body's own path         -> site-mismatch
#        (4) nowhere                                          -> unresolved
#      §1.10 makes the FILE the binding half of an attribution and a `:NN`
#      informational, so a line that has drifted is noted, never a defect.
#
# A defect class (site-mismatch / unresolved) is reachable ONLY through an
# attribution to a path that exists in the tree. An attribution to a GitHub
# artifact (`#N`, an issues/pull URL, a `gh issue`/`gh pr` reference, an
# adjacent `comment` token) or to a path absent from the tree is
# `unresolvable-locally` — keyed on the ATTRIBUTION, never on the failure, so
# this reader never guesses fabricated-vs-remote. A span with no attribution at
# all is `no-attribution`, grouped into one informational line.
#
# Advisory by construction: findings print to stdout and the exit code is
# ALWAYS 0 — this reader never gates a caller (SPEC §6.0 advisory face, the
# scripts/lint_bash_idioms.sh precedent at §4.5.1). Unreadable input, an absent
# `git`, or a non-repo prints a `fail-open` sentinel and still exits 0, so a
# silent no-op can never be mistaken for a clean body.
#
# STREAMS: stdout carries exactly one report line plus one indented `search:`
# line per span; the per-class totals go to STDERR, so a caller counting classes
# on stdout counts spans and nothing else.
set -uo pipefail

# Field separator for the extractor -> classifier channel. Deliberately a
# NON-whitespace control character: with a tab, `read`'s IFS-whitespace rule
# collapses a leading empty field and an unattributed span silently lands in the
# attribution slot, erasing the no-attribution class.
US=$(printf '\037')

ROOT=""      # repo top level the searches run from
RELBODY=""   # body path relative to ROOT, for the rung-3 self-exclusion

c_resolves=0
c_normalized=0
c_mismatch=0
c_unresolved=0
c_remote=0
c_noattr=0
c_total=0
na_lines=""

# Single-quote a value into a literal, copy-pasteable argv element. The spans
# carry backticks, `$` and `--`, so every search is built as quoted argv and
# printed in the same form — never eval'd, never word-split.
sq() {
  local s="$1" out
  out=${s//\'/\'\\\'\'}
  printf "'%s'" "$out"
}

# One report line, then the indented `search:` line carrying the literal
# invocation that produced it. The tool states the search it ran, not a summary
# of it (SPEC §1.10 part (b), applied to the tool's own output).
report() {
  printf '%s:%s: %s — %s\n' "$BODY" "$2" "$1" "$3"
  printf '    search: %s\n' "$4"
}

# Rung 2: does the attributed file carry the span once whitespace AND line wraps
# are normalized? Continuation lines of a wrapped comment keep a `# ` prefix, so
# that prefix is stripped before joining — without it a wrapped source misses
# and `unresolved` over-reports. Prints the 1-based line the match starts on.
norm_hit() {
  local f="$1" s="$2"
  SPAN="$s" awk '
    BEGIN { s = ENVIRON["SPAN"]; gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s) }
    {
      l = $0
      sub(/^[ \t]*#[ \t]?/, "", l)
      gsub(/[ \t]+/, " ", l); sub(/^ /, "", l); sub(/ $/, "", l)
      if (l == "") next
      n++; lno[n] = NR
      if (buf == "") { st[n] = 1; buf = l } else { st[n] = length(buf) + 2; buf = buf " " l }
    }
    END {
      if (n == 0 || s == "") exit
      p = index(buf, s)
      if (p == 0) exit
      ln = lno[1]
      for (i = 1; i <= n; i++) if (st[i] <= p) ln = lno[i]
      print ln
    }
  ' "$f" 2>/dev/null
}

# The extractor. Emits one US-separated record per kept span:
#   <body line>US<attributed path>US<cited :NN>US<github-artifact flag>US<span>
extract() {
  awk -v US="$US" '
    # A fenced block quotes draft text, not body prose — never extracted.
    /^[ \t]*(```|~~~)/ { fence = 1 - fence; next }
    fence { next }
    {
      line = $0
      ntok = 0; lastpath = ""
      rest = line; base = 0
      # Inline-code tokens, left to right, with their column in `line`.
      while (1) {
        i = index(rest, "`")
        if (i == 0) break
        after = substr(rest, i + 1)
        j = index(after, "`")
        if (j == 0) break
        tok = substr(after, 1, j - 1)
        start = base + i
        base = base + i + j
        rest = substr(after, j + 1)
        if (tok ~ /^:[0-9]+$/) {
          # A bare `:NN` inherits the last path named on this line.
          if (lastpath != "") {
            ntok++; ts[ntok] = start; tp[ntok] = lastpath; tl[ntok] = substr(tok, 2)
          }
          continue
        }
        p = tok; cited = ""
        if (match(p, /:[0-9]+$/)) { cited = substr(p, RSTART + 1); p = substr(p, 1, RSTART - 1) }
        # Path-shaped: no whitespace, and either a directory separator or a
        # trailing extension. `#676`, `${#X}` and prose in backticks miss.
        if (p != "" && p !~ /[ \t]/ && (index(p, "/") > 0 || p ~ /\.[A-Za-z0-9]+$/)) {
          lastpath = p
          ntok++; ts[ntok] = start; tp[ntok] = p; tl[ntok] = cited
        }
      }
      # GitHub-artifact markers on the line — consulted only when no path
      # attribution was found, so a real path always wins.
      gh = 0
      if (line ~ /(^|[^A-Za-z0-9_])#[0-9]+/) gh = 1
      if (line ~ /github\.com\/[^ )]*\/(issues|pull)\//) gh = 1
      if (line ~ /gh[ ]+(issue|pr)([ ]|$)/) gh = 1
      if (line ~ /[Cc]omments?([^A-Za-z]|$)/) gh = 1

      rest = line; base = 0
      while (1) {
        i = index(rest, "\"")
        if (i == 0) break
        after = substr(rest, i + 1)
        j = index(after, "\"")
        if (j == 0) break
        span = substr(after, 1, j - 1)
        sstart = base + i
        base = base + i + j
        rest = substr(after, j + 1)
        t = span
        sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t == "") continue
        if (split(t, W, /[ \t]+/) < 4) continue   # the four-word floor
        ai = 0
        for (k = 1; k <= ntok; k++) if (ts[k] < sstart) ai = k       # nearest preceding
        if (ai == 0) for (k = 1; k <= ntok; k++) if (ts[k] > sstart) { ai = k; break }
        printf "%d%s%s%s%s%s%d%s%s\n", NR, US, (ai ? tp[ai] : ""), US, (ai ? tl[ai] : ""), US, gh, US, t
      }
    }
  ' "$1"
}

classify() {
  local ln="$1" ap="$2" al="$3" gh="$4" span="$5"
  local qspan searchcmd out hitline nline note first nsites extra

  c_total=$((c_total + 1))
  qspan=$(sq "$span")

  if [ -n "$ap" ] && [ -f "$ROOT/$ap" ]; then
    # Rung 1 — literal, at the attributed path.
    searchcmd="git grep -F -h -n -e $qspan -- $(sq "$ap")"
    out=$(git -C "$ROOT" grep -F -h -n -e "$span" -- "$ap" 2>/dev/null | head -1)
    if [ -n "$out" ]; then
      hitline=${out%%:*}
      note=""
      if [ -n "$al" ] && [ "$al" != "$hitline" ]; then
        note=" (cited :$al, carried at :$hitline — line drift; the file is the binding half, §1.10)"
      fi
      c_resolves=$((c_resolves + 1))
      report resolves "$ln" "$ap:$hitline$note" "$searchcmd"
      return
    fi
    # Rung 2 — same path, whitespace and line-wrap normalized. Informational.
    nline=$(norm_hit "$ROOT/$ap" "$span")
    if [ -n "$nline" ]; then
      note=""
      if [ -n "$al" ] && [ "$al" != "$nline" ]; then
        note=" (cited :$al)"
      fi
      c_normalized=$((c_normalized + 1))
      report normalized "$ln" \
        "$ap:$nline$note — matched only after whitespace/line-wrap normalisation; informational, not a defect" \
        "$searchcmd"
      return
    fi
    # Rung 3 — repo-wide, minus the body itself. A committed body is tracked, so
    # without the self-exclusion a fabricated span hits itself and reports as a
    # site-mismatch it is not.
    if [ -n "$RELBODY" ]; then
      searchcmd="git grep -F -n -e $qspan -- $(sq ":(exclude,top)$RELBODY")"
      out=$(git -C "$ROOT" grep -F -n -e "$span" -- ":(exclude,top)$RELBODY" 2>/dev/null)
    else
      searchcmd="git grep -F -n -e $qspan"
      out=$(git -C "$ROOT" grep -F -n -e "$span" 2>/dev/null)
    fi
    if [ -n "$out" ]; then
      first=$(printf '%s\n' "$out" | head -1 | cut -d: -f1,2)
      nsites=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
      extra=""
      if [ "$nsites" -gt 1 ]; then
        extra=" (+$((nsites - 1)) other site(s))"
      fi
      c_mismatch=$((c_mismatch + 1))
      report site-mismatch "$ln" \
        "the wording is real but $ap does not carry it; it is carried at $first$extra" \
        "$searchcmd"
    else
      # Rung 4.
      c_unresolved=$((c_unresolved + 1))
      report unresolved "$ln" \
        "attributed to $ap, and no file in the tree carries the span" \
        "$searchcmd"
    fi
    return
  fi

  if [ -n "$ap" ]; then
    c_remote=$((c_remote + 1))
    report unresolvable-locally "$ln" \
      "attributed to $ap, which is not in the working tree — out of this reader's reach, not a defect" \
      "(none — nothing local to search)"
    return
  fi
  if [ "$gh" = "1" ]; then
    c_remote=$((c_remote + 1))
    report unresolvable-locally "$ln" \
      "attributed to a GitHub artifact (Issue / PR / comment), not a working-tree path — not a defect" \
      "(none — GitHub artifacts are out of this reader's reach)"
    return
  fi
  # Grouped into one informational line at the end.
  c_noattr=$((c_noattr + 1))
  na_lines="$na_lines $ln"
}

fail_open() {
  printf 'fail-open: %s — citation check skipped, nothing is gated by it (SPEC §1.10)\n' "$1" >&2
}

main() {
  local bodydir line ap al gh span

  if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    echo "usage: lint_citations.sh <proposed-body.md>" >&2
    fail_open "no body path given"
    return 0
  fi
  BODY="$1"
  if [ ! -f "$BODY" ] || [ ! -r "$BODY" ]; then
    fail_open "cannot read $BODY"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    fail_open "git is not available"
    return 0
  fi
  bodydir=$(cd "$(dirname "$BODY")" 2>/dev/null && pwd)
  if [ -n "$bodydir" ]; then
    ROOT=$(git -C "$bodydir" rev-parse --show-toplevel 2>/dev/null)
  fi
  if [ -z "$ROOT" ]; then
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  fi
  if [ -z "$ROOT" ]; then
    fail_open "$BODY is not inside a git repository"
    return 0
  fi
  if [ -n "$bodydir" ]; then
    case "$bodydir/" in
      "$ROOT"/*) RELBODY="${bodydir#"$ROOT"/}/$(basename "$BODY")" ;;
      *) RELBODY="" ;;
    esac
    if [ "$bodydir" = "$ROOT" ]; then
      RELBODY=$(basename "$BODY")
    fi
  fi

  printf '# citation report: %s (SPEC §1.10 part (a) — advisory, exit 0 always)\n' "$BODY"
  while IFS="$US" read -r line ap al gh span; do
    [ -n "$span" ] || continue
    classify "$line" "$ap" "$al" "$gh" "$span"
  done < <(extract "$BODY")

  if [ "$c_noattr" -gt 0 ]; then
    printf '%s: no-attribution — %d span(s) name no file on their line (line(s):%s); informational, never a defect\n' \
      "$BODY" "$c_noattr" "$na_lines"
    printf '    search: (none — a span with no attributed file has nothing to search against)\n'
  fi

  # Totals on stderr: stdout stays exactly one report line + one search line per
  # span, so a caller can count classes there without subtracting a summary.
  printf 'citation totals (advisory): %d span(s) — resolves=%d normalized=%d site-mismatch=%d unresolved=%d unresolvable-locally=%d no-attribution=%d\n' \
    "$c_total" "$c_resolves" "$c_normalized" "$c_mismatch" "$c_unresolved" "$c_remote" "$c_noattr" >&2

  return 0
}

main "$@"
