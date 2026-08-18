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
#      dominate and every extra finding measured on the corpus was false. Spans
#      over SPAN_MAX characters are skipped too — a prose quotation is not
#      hundreds of thousands of characters long, and an over-long one is the
#      first half of rung 2's cost product (PR #677).
#   2. ATTRIBUTE each span to the nearest path-shaped inline-code token on the
#      SAME LINE, preceding-preferred, else nearest following. A bare `:NN`
#      inherits the last path on that line. There is no paragraph lookback: on
#      the measured corpus a <=3-lines-back fallback fired twice and was wrong
#      both times.
#   3. RESOLVE on a four-rung ladder, stating for each span it classifies the
#      search it ran:
#        (1) `git grep -F` at the attributed path            -> resolves
#        (2) same path, whitespace/line-wrap normalized       -> normalized
#        (3) repo-wide, excluding the body's own path         -> site-mismatch
#        (4) nowhere                                          -> unresolved
#      §1.10 makes the FILE the binding half of an attribution and a `:NN`
#      informational, so a line that has drifted is noted, never a defect.
#
# CONTAINMENT (PR #677, round 3). The ladder is entered only for an attribution
# that passes THREE independent tests, because the first two decide different
# questions than the third:
#
#   * `in_repo_path` — TEXTUAL. Refuses an absolute path, a `..` component, and
#     git pathspec magic.
#   * `tracked_path` — an INDEX test (`git ls-files --error-unmatch` under
#     `:(literal)`). It holds rung 2 — the one rung that reads a file directly
#     instead of through `git grep` — to the same tracked corpus rungs 1 and 3
#     search, so a verbatim span in an UNTRACKED file can never be reported as
#     `normalized`, a normalisation that did not happen.
#   * `phys_path` — a FILESYSTEM test. Neither of the above decides a filesystem
#     question, and two reviewers demonstrated the gap: a tracked `abs.md` whose
#     index mode is 120000 pointing at `/etc/passwd` passes both tests and `-f`
#     FOLLOWS the link, so rung 2 became a confirm-guess oracle over any
#     readable path on the machine; and a tracked `sub/x.md` whose `sub` is
#     replaced by a symlink in the worktree also passes both, and rung 1's
#     `git grep` then read THROUGH it — `git grep` enforces a pathspec boundary,
#     never a filesystem one. So the attributed path is resolved PHYSICALLY and
#     required to land on a non-symlink leaf under the physical repository root.
#
# A refusal on any of the three lands on `unresolvable-locally` — a non-defect —
# so containment never manufactures a finding. Whether the *file* exists is
# probed ONLY for a path that is already textually in-repo AND physically
# contained: a bare `-e` on an arbitrary attribution is an existence oracle over
# the machine, which is the thing being denied.
#
# The residual is stated rather than claimed shut: rung 3 is a repo-wide
# `git grep` over the worktree, so a worktree whose *directory entries* have been
# replaced by symlinks can still have content outside the tree entering that
# corpus. That path is not author-chosen (rung 3 takes no attribution), and it
# requires write access to the developer's own worktree — whoever has that can
# read the files directly. The attributed-path axis, which an author DOES choose,
# is what the physical test closes.
#
# A defect class (site-mismatch / unresolved) is therefore reachable ONLY through
# an attribution to a tracked, contained file. An attribution to a GitHub
# artifact (`#N`, an issues/pull URL, a `gh issue`/`gh pr` reference, an adjacent
# `comment` token) or to anything this reader may not search — untracked, absent,
# a directory, a symlink, or outside the repository — is `unresolvable-locally`,
# keyed on the ATTRIBUTION, never on the failure, so this reader never guesses
# fabricated-vs-remote. A span with no attribution at all is `no-attribution`,
# grouped into one informational line.
#
# BOUNDED COST (PR #677, round 3). Rung 2 is the only unbounded rung, and its
# cost is a PRODUCT — file bytes x span length x span count. The sliding window
# made a single scan linear in file size; three caps bound the other two factors
# and the total: SPAN_MAX drops an absurd span at extraction, LINE_MAX (inside
# NORM_PROG) skips an absurd input LINE, whose per-record normalisation is
# quadratic in line length — 4 MB as one line measured 66.9 s against 0.28 s as
# 60 000 lines — and R2_BUDGET caps the total bytes rung 2 may scan per run. When
# the budget is spent the skip is STATED on the affected report line, because a
# span that reaches rung 3 with rung 2 skipped has not had a whitespace-only
# variant ruled out, and the report must not imply otherwise.
#
# Advisory by construction: findings print to stdout and the exit code is
# ALWAYS 0 — this reader never gates a caller (SPEC §6.0 advisory face, the
# scripts/lint_bash_idioms.sh precedent at §4.5.1). Unreadable input, an absent
# `git`, or a non-repo prints a `fail-open` sentinel and still exits 0, so a
# silent no-op can never be mistaken for a clean body.
#
# STREAMS: stdout carries one report line plus one indented `search:` line and
# nothing else — one such PAIR per span for every class except `no-attribution`,
# whose spans are GROUPED into a single pair naming all of their lines. The
# per-class totals go to STDERR, so a caller counting classes on stdout counts
# report lines and never a summary. A caller that closes stdout mid-report gets a
# TRUNCATED sentinel on stderr (see the trap below), so a cut report is never
# indistinguishable from a complete one.
set -uo pipefail

# SIGPIPE would kill this reader with status 141 the moment a caller closes the
# pipe (`… | head -2`), contradicting the exit-0-unconditionally contract above.
# With the signal ignored the write fails and the status stays 0 — but the
# disposition is inherited across `exec`, so on its own it makes a TRUNCATED
# report indistinguishable from a complete one: partial stdout, exit 0, nothing
# marking the cut. Two things restore the distinction (PR #677): every stdout
# write goes through `emit`, which turns a failed write into a stated sentinel on
# stderr; and each capture subshell that pipes a child into `head` resets PIPE to
# its default, so those children still die at the closed pipe rather than running
# on with a write error.
trap '' PIPE

# Field separator for the extractor -> classifier channel. Deliberately a
# NON-whitespace control character: with a tab, `read`'s IFS-whitespace rule
# collapses a leading empty field and an unattributed span silently lands in the
# attribution slot, erasing the no-attribution class. A literal US byte in the
# body itself would misalign the same record, so the extractor neutralises it.
US=$(printf '\037')

# Cost caps (PR #677). Overridable for measurement; the defaults are the contract.
SPAN_MAX=${GHJIG_CITATION_SPAN_MAX:-1000}          # characters, per span
R2_BUDGET=${GHJIG_CITATION_R2_BUDGET:-33554432}    # bytes rung 2 may scan per run
case "$SPAN_MAX" in ''|*[!0-9]*) SPAN_MAX=1000 ;; esac
case "$R2_BUDGET" in ''|*[!0-9]*) R2_BUDGET=33554432 ;; esac
R2_LEFT=$R2_BUDGET

ROOT=""      # repo top level the searches run from
ROOT_P=""    # …physically resolved, for the containment test
RELBODY=""   # body path relative to ROOT, for the rung-3 self-exclusion
TRUNCATED=0  # a caller closed stdout mid-report

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

# One stdout line. A failed write means the caller closed the pipe: say so once,
# on stderr, and stop writing. Without this the ignored SIGPIPE above would make
# a truncated report read as a clean one (PR #677).
emit() {
  [ "$TRUNCATED" -eq 0 ] || return 0
  if ! printf '%s\n' "$1" 2>/dev/null; then
    TRUNCATED=1
    printf 'citation report TRUNCATED: the caller closed the report pipe after %d classified span(s) — the lines below the cut were never written (SPEC §1.10; still advisory, still exit 0)\n' \
      "$c_total" >&2
  fi
}

# One report line, then the indented `search:` line carrying the literal
# invocation that produced it, run from ROOT. The tool states the search it ran,
# not a summary of it (SPEC §1.10 part (b), applied to the tool's own output).
report() {
  emit "$(printf '%s:%s: %s — %s' "$BODY" "$2" "$1" "$3")"
  emit "$(printf '    search: %s' "$4")"
}

# Rung 2's search, verbatim — the awk program norm_hit runs, kept in a variable
# so the `search:` line can print the SAME program that produced the result. A
# rung-2 report used to print rung 1's `git grep`, which by construction returns
# nothing (control reaches rung 2 only because it did), so the printed command
# could never reproduce the line it was attached to (PR #677).
#
# Every statement is `;`-terminated, so flattening the program to one line for
# printing leaves it runnable. The scan is a SLIDING WINDOW, not a whole-file
# join: the window keeps only as many characters as a match ending at the current
# line can need, which makes the scan linear in file size instead of quadratic —
# a 9.6 MB attributed file used to stall the caller for minutes (PR #677).
#
# The per-record normalisation is itself quadratic in the length of ONE line, so
# a line longer than LINE_MAX is skipped: 4 MB arriving as a single line (a
# minified bundle, a one-line JSON dump, an inlined SVG) measured 66.9 s where
# the same bytes as 60 000 lines took 0.28 s. The cost of the cap is that a
# whitespace-variant match inside such a line is missed; rung 1's `git grep`
# still finds an exact one there at any size.
#
# Continuation lines of a wrapped comment keep a `# ` prefix, so that prefix is
# stripped before joining — without it a wrapped source misses and `unresolved`
# over-reports. Prints the 1-based line the match starts on.
NORM_PROG='
BEGIN { s = ENVIRON["SPAN"]; gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); slen = length(s); if (slen == 0) exit; head = 1; tail = 0; abs = 0; buf = ""; LINE_MAX = 65536; }
{
if (length($0) > LINE_MAX) next;
l = $0; sub(/^[ \t]*#[ \t]?/, "", l); gsub(/[ \t]+/, " ", l); sub(/^ /, "", l); sub(/ $/, "", l);
if (l == "") next;
tail++; ln[tail] = NR;
if (buf == "") { head = tail; st[tail] = abs; buf = l; } else { st[tail] = abs + length(buf) + 1; buf = buf " " l; };
p = index(buf, s);
if (p > 0) { a = abs + p - 1; r = ln[head]; for (i = head; i <= tail; i++) if (st[i] <= a) r = ln[i]; print r; exit; };
while (head < tail && length(buf) - (st[head + 1] - abs) >= slen) { o = st[head + 1] - abs; buf = substr(buf, o + 1); delete st[head]; delete ln[head]; head++; abs = st[head]; };
}
'

# Rung 2, run. The file operand goes in by redirect, never as an argv element: a
# path opening with `-` would otherwise be read as an awk option (PR #677).
norm_hit() {
  local f="$1" s="$2"
  SPAN="$s" awk "$NORM_PROG" < "$f" 2>/dev/null
}

# Rung 2, printed — the same program, flattened to the one line the `search:`
# contract allows, against the ROOT-relative path the git rungs also print.
norm_search() {
  local ap="$1" s="$2" prog
  prog=$(printf '%s' "$NORM_PROG" | tr '\n' ' ' | tr -s ' ')
  printf 'SPAN=%s awk %s < %s' "$(sq "$s")" "$(sq "$prog")" "$(sq "$ap")"
}

# Is the attribution a plain, repository-relative path? An absolute path, a `..`
# component, or a leading `:` (git pathspec magic) is refused: downstream either
# hands a resolved path to a reader or "$ap" to git, and neither may leave the
# repository (PR #677). Purely textual — see phys_path for the filesystem half.
in_repo_path() {
  case "$1" in
    "" | /* | :*) return 1 ;;
    ".." | "../"* | *"/.." | *"/../"*) return 1 ;;
  esac
  return 0
}

# Does git track the attribution? `:(literal)` disarms pathspec magic that would
# otherwise widen or invert the search — a committed `:(exclude)decoy.md`
# attribution made rung 1 search everything BUT the decoy and report `resolves`
# for a span living elsewhere (PR #677). An INDEX test only.
tracked_path() {
  git -C "$ROOT" ls-files --error-unmatch -- ":(literal)$1" >/dev/null 2>&1
}

# The FILESYSTEM half of containment: resolve the attribution's directory chain
# physically and print the absolute path only if it stays under the physical root
# and its leaf is not itself a symlink. Prints nothing (and reads nothing) for
# anything else — a tracked symlink to `/etc/passwd`, or a tracked path whose
# parent directory has been swapped for a symlink out of the tree, both pass the
# textual and index tests and are refused here (PR #677).
phys_path() {
  local ap="$1" d b pd
  [ -n "$ROOT_P" ] || return 1
  d=$(dirname -- "$ap")
  b=$(basename -- "$ap")
  pd=$(cd -P -- "$ROOT_P/$d" 2>/dev/null && pwd -P) || return 1
  [ -n "$pd" ] || return 1
  case "$pd/" in
    "$ROOT_P"/*) ;;
    *) return 1 ;;
  esac
  [ ! -L "$pd/$b" ] || return 1
  printf '%s\n' "$pd/$b"
}

# The honest sentence for an attribution the ladder is not entered for. The arms
# are keyed on what is TRUE about the path — the index answer plus a directory
# test — and never on a bare `-e`, which for an uncontained attribution is an
# existence oracle over the machine. Wording matters here beyond tidiness: this
# is the tool that ships "state what is true about the file you name", and it
# used to tell an author "git does not track" a path git demonstrably tracked
# (PR #677).
out_of_reach() {
  local ln="$1" ap="$2" tracked="$3" pp="$4"
  c_remote=$((c_remote + 1))
  if [ -n "$pp" ] && [ -d "$pp" ]; then
    report unresolvable-locally "$ln" \
      "attributed to $ap, a directory rather than a file — §1.10 binds a quotation to the file it names, so there is no single file here to resolve it in; not a defect" \
      "(none — a directory attribution names no file to search)"
  elif [ "$tracked" = "1" ] && [ -z "$pp" ]; then
    report unresolvable-locally "$ln" \
      "attributed to $ap, which git tracks but which does not resolve to a plain file inside this repository — a symlink, or a path leaving the tree; refused before any read, not a defect" \
      "(none — the attributed path does not resolve to a contained regular file)"
  elif [ "$tracked" = "1" ]; then
    report unresolvable-locally "$ln" \
      "attributed to $ap, which git tracks but the working tree does not carry as a readable regular file — out of this reader's reach, not a defect" \
      "(none — the tracked path is not a readable regular file in the working tree)"
  elif [ -n "$pp" ] && [ -e "$pp" ]; then
    report unresolvable-locally "$ln" \
      "attributed to $ap, which the working tree carries but git does not track — this reader searches tracked files only, so it is out of reach, not a defect" \
      "(none — an untracked path is outside the tracked corpus this reader searches)"
  else
    report unresolvable-locally "$ln" \
      "attributed to $ap, which is not a tracked path in this repository — out of this reader's reach, not a defect" \
      "(none — nothing local to search)"
  fi
}

# The extractor. Emits one US-separated record per kept span:
#   <body line>US<attributed path>US<cited :NN>US<github-artifact flag>US<span>
extract() {
  awk -v US="$US" -v spanmax="$SPAN_MAX" '
    # A fenced block quotes draft text, not body prose — never extracted.
    /^[ \t]*(```|~~~)/ { fence = 1 - fence; next }
    fence { next }
    {
      line = $0
      # A literal US byte in the body would shift a span into or out of the
      # attribution slot of the record below. Neutralised to a space, which
      # preserves every column offset computed from `line` (PR #677).
      gsub(/\037/, " ", line)
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
        # …and the ceiling: an over-long span is the first factor of rung 2s
        # cost product, and no prose quotation reaches it (PR #677).
        if (length(t) > spanmax) { toolong++; continue }
        ai = 0
        for (k = 1; k <= ntok; k++) if (ts[k] < sstart) ai = k       # nearest preceding
        if (ai == 0) for (k = 1; k <= ntok; k++) if (ts[k] > sstart) { ai = k; break }
        printf "%d%s%s%s%s%s%d%s%s\n", NR, US, (ai ? tp[ai] : ""), US, (ai ? tl[ai] : ""), US, gh, US, t
      }
    }
    END {
      if (toolong > 0) {
        printf "citation note (advisory): %d span(s) over %d characters were not classified — over-long spans are skipped to bound the normalising rung (SPEC §1.10)\n", toolong, spanmax > "/dev/stderr"
      }
    }
  ' < "$1"
}

classify() {
  local ln="$1" ap="$2" al="$3" gh="$4" span="$5"
  local qspan qpath searchcmd out hitline nline note first nsites extra
  local tracked=0 pp="" fsize r2note=""

  c_total=$((c_total + 1))
  qspan=$(sq "$span")

  if [ -n "$ap" ]; then
    if in_repo_path "$ap"; then
      tracked_path "$ap" && tracked=1
      pp=$(phys_path "$ap") || pp=""
    fi
    if [ "$tracked" = "1" ] && [ -n "$pp" ] && [ -f "$pp" ] && [ -r "$pp" ]; then
      qpath=$(sq ":(literal)$ap")
      # Rung 1 — literal, at the attributed path. PIPE is reset inside the
      # capture so `git grep` still dies at `head`'s closed pipe (PR #677).
      searchcmd="git grep -F -h -n -e $qspan -- $qpath"
      out=$( trap - PIPE; git -C "$ROOT" grep -F -h -n -e "$span" -- ":(literal)$ap" 2>/dev/null | head -1 )
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
      # Rung 2 — same path, whitespace and line-wrap normalized. Informational,
      # and reported with its OWN search, since rung 1's returned nothing. Held
      # to the run's byte budget; a skip is stated on whatever line results.
      nline=""
      if [ "$R2_LEFT" -gt 0 ]; then
        fsize=$(wc -c < "$pp" 2>/dev/null | tr -d ' ')
        case "$fsize" in ''|*[!0-9]*) fsize=0 ;; esac
        R2_LEFT=$((R2_LEFT - fsize))
        nline=$(norm_hit "$pp" "$span")
      else
        r2note=" (the normalising rung was skipped — this run's rung-2 byte budget is spent, so a whitespace-only variant of this span is NOT ruled out)"
      fi
      if [ -n "$nline" ]; then
        note=""
        if [ -n "$al" ] && [ "$al" != "$nline" ]; then
          note=" (cited :$al)"
        fi
        c_normalized=$((c_normalized + 1))
        report normalized "$ln" \
          "$ap:$nline$note — matched only after whitespace/line-wrap normalisation; informational, not a defect" \
          "$(norm_search "$ap" "$span")"
        return
      fi
      # Rung 3 — repo-wide, minus the body itself. A committed body is tracked, so
      # without the self-exclusion a fabricated span hits itself and reports as a
      # site-mismatch it is not.
      if [ -n "$RELBODY" ]; then
        searchcmd="git grep -F -n -e $qspan -- $(sq ":(exclude,top,literal)$RELBODY")"
        out=$(git -C "$ROOT" grep -F -n -e "$span" -- ":(exclude,top,literal)$RELBODY" 2>/dev/null)
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
          "the wording is real but $ap does not carry it; it is carried at $first$extra$r2note" \
          "$searchcmd"
      else
        # Rung 4.
        c_unresolved=$((c_unresolved + 1))
        report unresolved "$ln" \
          "attributed to $ap, and no file in the tree carries the span$r2note" \
          "$searchcmd"
      fi
      return
    fi
    out_of_reach "$ln" "$ap" "$tracked" "$pp"
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
  # `--` on both: a body path opening with `-` would otherwise be read as an
  # option, ROOT would silently fall back to the cwd's repo, and the documented
  # rung-3 self-exclusion would vanish (PR #677). `-P`/`pwd -P` for the same
  # reason one step further in: a LOGICAL cwd made the body's directory a
  # non-prefix of git's physical top level, RELBODY came out empty, and a wholly
  # fabricated span then matched the body itself and reported `site-mismatch`
  # citing that body — §1.10's discriminator, backwards. Reproduced on macOS with
  # no symlink of one's own, since `/var` is one.
  bodydir=$(cd -P -- "$(dirname -- "$BODY")" 2>/dev/null && pwd -P)
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
  ROOT_P=$(cd -P -- "$ROOT" 2>/dev/null && pwd -P)
  [ -n "$ROOT_P" ] || ROOT_P="$ROOT"
  # git's own answer for "where is this file, relative to the top level", which
  # is immune to the logical/physical mismatch above.
  if [ -n "$bodydir" ]; then
    RELBODY="$(git -C "$bodydir" rev-parse --show-prefix 2>/dev/null)$(basename -- "$BODY")"
  fi

  emit "$(printf '# citation report: %s (SPEC §1.10 part (a) — advisory, exit 0 always)' "$BODY")"
  while IFS="$US" read -r line ap al gh span; do
    [ -n "$span" ] || continue
    classify "$line" "$ap" "$al" "$gh" "$span"
  done < <(extract "$BODY")

  if [ "$c_noattr" -gt 0 ]; then
    emit "$(printf '%s: no-attribution — %d span(s) name no file on their line (line(s):%s); informational, never a defect' \
      "$BODY" "$c_noattr" "$na_lines")"
    emit '    search: (none — a span with no attributed file has nothing to search against)'
  fi

  # Totals on stderr: stdout stays report lines + search lines only, so a caller
  # can count classes there without subtracting a summary.
  printf 'citation totals (advisory): %d span(s) — resolves=%d normalized=%d site-mismatch=%d unresolved=%d unresolvable-locally=%d no-attribution=%d\n' \
    "$c_total" "$c_resolves" "$c_normalized" "$c_mismatch" "$c_unresolved" "$c_remote" "$c_noattr" >&2

  return 0
}

main "$@"
# SIGPIPE is ignored above, so a closed stdout leaves a failed write, never a
# 141 exit. Status is stated once, here.
exit 0
