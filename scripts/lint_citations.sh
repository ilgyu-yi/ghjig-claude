#!/usr/bin/env bash
# scripts/lint_citations.sh — born-advisory, non-gating citation reader (#676).
# The contract is SPEC §1.10; it is referenced here, not restated (§9). This header
# states, in the present tense, the constraints the code cannot show. How each one
# was demonstrated — the exploits, the measurements, the review rounds — lives in
# PR #677's record and in git history, not here: a narrative or a live figure in a
# comment is itself an unchecked claim, and unchecked claims are this tool's subject.
#
# Mechanizes the LEXICAL half of §1.10 part (a) and nothing else. Part (b), and a
# quotation read out of its paragraph, are reviewer judgment.
#
#   1. EXTRACT the body's quoted spans, one line at a time: both `*"…"*` and plain
#      `"…"`, non-greedy, ASCII double quotes only. Fenced blocks are excluded (draft
#      text, not body prose). The extractor runs under `LC_ALL=C`: a body is
#      author-supplied, and in a UTF-8 locale one invalid byte is fatal to a regex
#      match — extraction must survive any byte the author feeds it. Byte semantics
#      also match `git grep -F`'s, so the caps below count the same units the
#      searches do.
#   2. ATTRIBUTE each span to the nearest path-shaped inline-code token on the SAME
#      LINE, preceding-preferred, else nearest following. A bare `:NN` inherits the
#      last path on that line. No paragraph lookback: measured on real bodies, a
#      lookback fallback misattributes more than it recovers.
#   3. RESOLVE on a four-rung ladder, stating the search that produced each result:
#        (1) `git grep -F` at the attributed path            -> resolves
#        (2) same path, whitespace/line-wrap normalized       -> normalized
#        (3) repo-wide, excluding the body's own path         -> site-mismatch
#        (4) nowhere                                          -> unresolved
#
# CONTAINMENT — a filesystem question that neither a textual nor an index test
# decides. Three tests gate the ladder, and none subsumes another:
#   * `in_repo_path` — TEXTUAL. Refuses absolute paths, `..`, pathspec magic, and
#     `.git/` (which containment would otherwise admit, since it is under the root).
#   * `tracked_path` — an INDEX test. It holds rung 2 — the one rung that reads a
#     file directly rather than through `git grep` — to the same tracked corpus
#     rungs 1 and 3 search, so a verbatim span in a file the index does not name is
#     not reported as `normalized`, a normalisation that did not happen. It is not
#     an entry test: `git ls-files --error-unmatch` also succeeds for a DIRECTORY
#     PREFIX of index entries, so a tracked directory replaced in the worktree by a
#     regular file passes it, and rung 2 then reads a path git does not track. The
#     precondition is worktree write, as for the residuals below.
#   * `phys_path` — a FILESYSTEM test. A tracked symlink to `/etc/passwd` passes
#     both tests above and `-f` FOLLOWS it, which would make rung 2 a confirm-guess
#     oracle over any readable path; a tracked leaf whose parent directory was
#     swapped for an outward symlink passes both too, with rung 1's `git grep`
#     reading THROUGH it — `git grep` enforces a pathspec boundary, never a
#     filesystem one.
#
# Every refusal reports `unresolvable-locally`, a NON-defect, so containment cannot
# manufacture a finding. The filesystem is probed only for a path already textually
# in-repo AND physically contained: a bare `-e` on an arbitrary attribution is an
# existence oracle over the machine.
#
# RESIDUALS, stated because they are open, and deliberately uncounted — a census of
# open items rots as items open and close.
#   * The out-of-reach sentences DISTINGUISH an untracked path that exists from one
#     that does not, for any path already textually in-repo and physically contained.
#     Body text therefore gets a one-bit existence answer over the repository — never
#     content, never outside it, only paths the author already holds. It is the price
#     of naming which test refused rather than guessing, and unlike the two below it
#     needs no worktree write.
#   * A HARDLINK inside the tree to a file outside it defeats `phys_path` by
#     construction — no symlink exists for `cd -P` or `-L` to see, so the attributed
#     path reads outside content. This reaches rung 1 AND rung 2: `-f`, `-r` and a
#     false `-L` all pass, so the direct `awk` read is exposed exactly as the `git
#     grep` is. What the physical test closes is the SYMLINK forms of the
#     author-chosen axis, not the axis.
#   * Rung 3 is a repo-wide `git grep` over the WORKTREE, so a worktree whose
#     directory entries have been replaced by symlinks can bring outside content
#     into that corpus. The file is not author-chosen, but the QUERY is, so it is a
#     content-confirm oracle over whatever such a link exposes.
# The hardlink and the repo-wide rung need write access to the developer's own
# worktree, which `git checkout` will not produce; whoever has it can read those
# files directly.
#
# BOUNDED COST. Each factor of the reader's cost is capped, and each cap STATES what
# it skipped — a skipped rung is not a ruled-out one, and a silent cap in a tool
# whose subject is unstated claims is the defect it exists to catch. Every decline
# the EXTRACTOR makes goes through `drop()`, a single counted channel whose keys are
# printed in first-seen order at END, so a new decline there cannot be silent
# without bypassing an obvious convention. The bounds reached DURING classification
# — a cited artifact's over-long line, the rung-2 byte budget, a failed awk — do not
# go through drop(): each is stated on the report line whose meaning it changes,
# which is where the STREAMS rule below puts it. The caps:
#   SPAN_MAX         a span too long to be prose             (extraction)
#   SPAN_COUNT_MAX   more spans than a body plausibly has    (extraction)
#   BODY_LINE_MAX    a body line long enough to matter — the extractor's own scan
#                    is quadratic in one line's length, and the body is the axis
#                    its AUTHOR controls
#   LINE_MAX         a CITED artifact's absurd line, inside NORM_PROG, whose
#                    per-record normalisation is quadratic in line length
#   R2_BUDGET        total bytes rung 2 may read per run, tested BEFORE the read
#                    against the file's size, so the bound is exact rather than
#                    exceeded by one file
#
# WHAT IS NOT CAPPED, stated because the enumeration above would otherwise read as
# complete: rungs 1 and 3 are `git grep` invocations, one pair per classified span,
# and rung 3's corpus is the repository's whole tracked text. Span COUNT is capped,
# so the number of invocations is bounded — but the bytes each one reads scale with
# the repository.
#
# A closed report pipe stops the CLASSIFICATION loop, not only the writing —
# grinding on for a caller that has stopped reading is unbounded work for nobody.
# Extraction is already complete by then; it is captured up front so its exit
# status is observable, and its own cost is bounded by the caps above.
#
# NEUTRALISED BYTES. The extractor turns every C0 control except tab into a space,
# one byte for one byte so no column offset shifts. US is this channel's field
# separator, so a literal one would move a span into or out of the attribution
# slot. CR and ESC are not whitespace, so they pass the path-shape test — and an
# attribution that reaches the column-0 report line carrying a VT escape sequence
# can redraw a defect line into a clean-looking one on a terminal. Machine counting
# is unaffected either way; the channel a human reads is the one at stake, and that
# is the channel both authoring commands tell the agent to surface.
#
# STREAMS. stdout carries one report line plus one indented `search:` line, one such
# PAIR per classified span — except `no-attribution`, whose spans are GROUPED into a
# single pair. Where a decline is stated follows one RULE, and the rule is §1.10's:
# a decline that changes what a report line means is stated ON that line, and every
# other decline is stated on stderr beside the per-class totals. The rule stands
# here in place of a tally of the two sides on purpose — the tally rots as declines
# are added and the rule does not move.
#
# COUNTING CLASSES: anchor at COLUMN 0 — `^[^[:space:]].*:<line>: <class> — ` — or
# read the stderr totals. Two things on stdout are author-supplied: the attributed
# path (path-shaped, so an attribution named `site-mismatch.md` carries that token)
# and the span itself, echoed verbatim into the INDENTED `search:` line, where it
# can carry a whole forged `…:3: resolves — …` sequence. A count anchored only on
# `:<line>: <class>` therefore inflates; the column-0 anchor excludes the indented
# line, and the stderr totals are unreachable from body text altogether. Nothing
# can SUPPRESS a count.
#
# One caveat on the split, since this reader may not overstate its own output: when
# a caller closes the pipe, bash re-routes the failed write's payload to stderr, so
# one report line can appear there ahead of the TRUNCATED sentinel. That is the
# shell's behaviour, not a channel this reader opens, and the `citation note` /
# `citation totals` prefixes remain unreachable from body text.
#
# Advisory by construction: findings print to stdout, the exit code is ALWAYS 0,
# and this reader never gates a caller (SPEC §6.0 advisory face, the
# `scripts/lint_bash_idioms.sh` precedent at §4.5.1). Unreadable input, an absent
# `git`, or a non-repo prints a `fail-open` sentinel and still exits 0, so a silent
# no-op can never be mistaken for a clean body.
set -uo pipefail

# SIGPIPE would kill this reader with status 141 the moment a caller closed the
# pipe (`… | head -2`), contradicting the exit-0 contract. With the signal ignored
# the write fails and the status stays 0 — but the disposition is inherited across
# `exec` and a failed write is silent, so on its own it makes a truncated report
# indistinguishable from a complete one. Three things restore the distinction:
# every stdout write goes through `emit`, which states the cut on stderr; the
# CLASSIFICATION loop stops at that point (extraction is already complete, and
# bounded); and each capture that pipes a child into `head` resets PIPE to default so
# the child still dies at the closed pipe.
trap '' PIPE

# Field separator for the extractor -> classifier channel. Deliberately a
# NON-whitespace control character: with a tab, `read`'s IFS-whitespace rule
# collapses a leading empty field and an unattributed span silently lands in the
# attribution slot, erasing the no-attribution class. A literal US byte in the body
# is neutralised by the extractor so it cannot shift a field either.
US=$(printf '\037')

# Cost caps. Overridable for measurement; the defaults are the contract. Each is
# sanitised because it reaches `$(( ))` — an unsanitised value there is an
# arithmetic-evaluation injection sink.
SPAN_MAX=${GHJIG_CITATION_SPAN_MAX:-1000}            # characters, per span
SPAN_COUNT_MAX=${GHJIG_CITATION_SPAN_COUNT_MAX:-200} # classified spans per body
BODY_LINE_MAX=${GHJIG_CITATION_BODY_LINE_MAX:-20000} # characters, per body line
R2_BUDGET=${GHJIG_CITATION_R2_BUDGET:-33554432}      # bytes rung 2 may read per run
case "$SPAN_MAX" in ''|*[!0-9]*) SPAN_MAX=1000 ;; esac
case "$SPAN_COUNT_MAX" in ''|*[!0-9]*) SPAN_COUNT_MAX=200 ;; esac
case "$BODY_LINE_MAX" in ''|*[!0-9]*) BODY_LINE_MAX=20000 ;; esac
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

# Single-quote a value into a literal, copy-pasteable argv element. The spans carry
# backticks, `$` and `--`, so every search is built as quoted argv and printed in
# the same form — never eval'd, never word-split.
sq() {
  local s="$1" out
  out=${s//\'/\'\\\'\'}
  printf "'%s'" "$out"
}

# One stdout line. A failed write means the caller closed the pipe: say so once, on
# stderr, and stop. `main` then stops classifying — continuing to work for a caller
# that has stopped reading is the same waste in a different place.
emit() {
  [ "$TRUNCATED" -eq 0 ] || return 0
  if ! printf '%s\n' "$1" 2>/dev/null; then
    TRUNCATED=1
    printf 'citation report TRUNCATED: the caller closed the report pipe after %d classified span(s); the rest of the body was not classified (SPEC §1.10; still advisory, still exit 0)\n' \
      "$c_total" >&2
  fi
}

# One report line, then the indented `search:` line carrying the literal invocation
# that produced it, run from ROOT. The tool states the search it ran, not a summary
# of it (SPEC §1.10 part (b), applied to the tool's own output).
report() {
  emit "$(printf '%s:%s: %s — %s' "$BODY" "$2" "$1" "$3")"
  emit "$(printf '    search: %s' "$4")"
}

# Rung 2's search, verbatim — the awk program `norm_hit` runs, kept in a variable so
# the `search:` line can print the SAME program that produced the result. Printing
# rung 1's `git grep` here instead would be a command that cannot reproduce its own
# line: control reaches rung 2 only because that grep returned nothing.
#
# Every statement is `;`-terminated, so flattening the program to one line for
# printing leaves it runnable. The scan is a SLIDING WINDOW, not a whole-file join:
# the window keeps only as many characters as a match ending at the current line can
# need, making the scan linear in file size instead of quadratic.
#
# A line longer than LINE_MAX is skipped and COUNTED, and the count is reported at
# END when no match was found — without that count the caller cannot tell a genuine
# miss from a rung never attempted on the line that mattered, which silently turns
# a `normalized` (non-defect) into an `unresolved` (defect).
#
# Continuation lines of a wrapped comment keep a `# ` prefix, so that prefix is
# stripped before joining. Prints the 1-based line the match starts on.
#
# shellcheck disable=SC2016  # awk program text: `$0` and ENVIRON["SPAN"] are awk's,
# and MUST NOT expand in the shell. The non-expanding channel is the whole design.
NORM_PROG='
BEGIN { s = ENVIRON["SPAN"]; gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); slen = length(s); if (slen == 0) exit; head = 1; tail = 0; abs = 0; buf = ""; found = 0; skipped = 0; LINE_MAX = 65536; }
{
if (length($0) > LINE_MAX) { skipped++; next; };
l = $0; sub(/^[ \t]*#[ \t]?/, "", l); gsub(/[ \t]+/, " ", l); sub(/^ /, "", l); sub(/ $/, "", l);
if (l == "") next;
tail++; ln[tail] = NR;
if (buf == "") { head = tail; st[tail] = abs; buf = l; } else { st[tail] = abs + length(buf) + 1; buf = buf " " l; };
p = index(buf, s);
if (p > 0) { a = abs + p - 1; r = ln[head]; for (i = head; i <= tail; i++) if (st[i] <= a) r = ln[i]; print r; found = 1; exit; };
while (head < tail && length(buf) - (st[head + 1] - abs) >= slen) { o = st[head + 1] - abs; buf = substr(buf, o + 1); delete st[head]; delete ln[head]; head++; abs = st[head]; };
}
END { if (found == 0 && skipped > 0) print "skipped-long-lines=" skipped; }
'

# Rung 2, run. The file operand goes in by redirect, never as an argv element: a
# path opening with `-` would otherwise be read as an awk option. awk's own failure
# is REPORTED rather than swallowed — a discarded error degrades rung 2 to a silent
# miss, which is the same unstated skip in a portability costume.
norm_hit() {
  local f="$1" s="$2" out rc
  # `LC_ALL=C` for the reason the extractor has it: in a UTF-8 locale one invalid
  # byte in the CITED artifact is fatal to a regex match, and a rung that dies on it
  # turns a span that normalises — a non-defect — into `unresolved`. Stated on the
  # report line if it still happens; prevented at the source here.
  out=$(LC_ALL=C SPAN="$s" awk "$NORM_PROG" < "$f" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'awk-failed=%d\n' "$rc"
    return 0
  fi
  printf '%s\n' "$out"
}

# Rung 2, printed — the same program, flattened to the one line the `search:`
# contract allows, against the ROOT-relative path the git rungs also print.
norm_search() {
  local ap="$1" s="$2" prog
  prog=$(printf '%s' "$NORM_PROG" | tr '\n' ' ' | tr -s ' ')
  printf 'LC_ALL=C SPAN=%s awk %s < %s' "$(sq "$s")" "$(sq "$prog")" "$(sq "$ap")"
}

# Is the attribution a plain, repository-relative path? Purely textual — see
# phys_path for the filesystem half. `.git/` is refused here because it IS under the
# repository root, so containment admits it, and the working-tree probe below would
# then answer existence questions about the object store.
in_repo_path() {
  local lower
  case "$1" in
    "" | /* | :*) return 1 ;;
    ".." | "../"* | *"/.." | *"/../"*) return 1 ;;
  esac
  # `.git` is refused case-INSENSITIVELY: on a case-insensitive filesystem
  # `.GIT/config` names the object store just as surely, and a case-sensitive
  # refusal would let it reach the working-tree probe. Folded only for names that
  # map onto `.git` itself: refusing anything merely containing "git" would drop a
  # legitimate `.githooks/` attribution and turn a resolvable citation into a
  # non-answer.
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    ".git" | ".git/"* | *"/.git" | *"/.git/"*) return 1 ;;
  esac
  return 0
}

# Does git track the attribution? `:(literal)` disarms pathspec magic that would
# otherwise widen or invert the search — a committed `:(exclude)decoy.md` attribution
# made rung 1 search everything BUT the decoy and report `resolves` for a span living
# elsewhere. An INDEX test only.
tracked_path() {
  git -C "$ROOT" ls-files --error-unmatch -- ":(literal)$1" >/dev/null 2>&1
}

# The FILESYSTEM half of containment: resolve the attribution's directory chain
# physically and accept the path only if it stays under the physical root and its
# leaf is not itself a symlink.
#
# Prints its whole answer — `ok:<absolute path>` or `no:<which test refused>` — on
# ONE channel, because the caller reads it through a command substitution and a
# subshell cannot set a variable in its parent: a reason passed through a global
# would always arrive empty, and every refusal would fall through to the generic
# wording.
#
# The reason is what makes the out-of-reach wording honest — each arm below names a
# test that actually ran, never a guessed cause, since a guess ("a symlink, or a
# path leaving the tree") is false for causes it does not cover.
phys_path() {
  local ap="$1" d b pd pdrel
  if [ -z "$ROOT_P" ]; then printf 'no:no-root\n'; return 0; fi
  d=$(dirname -- "$ap")
  b=$(basename -- "$ap")
  pd=$(cd -P -- "$ROOT_P/$d" 2>/dev/null && pwd -P)
  if [ -z "$pd" ]; then printf 'no:absent-parent\n'; return 0; fi
  case "$pd/" in
    "$ROOT_P"/*) ;;
    *) printf 'no:escapes\n'; return 0 ;;
  esac
  # …and the object store is refused on the RESOLVED path, not just the spelling.
  # `in_repo_path` folds case, but a tracked symlink whose target is `.git` is a
  # mode-120000 blob, so a CLONE materialises it and an alias like `gitalias/config`
  # walks around the textual refusal entirely — the one such gap that needs no
  # worktree write. Checking `pd` closes the aliasing axis rather than one more
  # spelling of it, and it is checked CASE-FOLDED: `pwd -P` resolves a symlink
  # TEXTUALLY, appending the link target without canonicalising case, so an alias
  # pointing at `.GIT` yields a `pd` a case-sensitive pattern admits on a
  # case-insensitive filesystem.
  pdrel=$(printf '%s' "${pd#"$ROOT_P"}" | tr '[:upper:]' '[:lower:]')
  case "$pdrel/" in
    "/.git/"*) printf 'no:object-store\n'; return 0 ;;
  esac
  if [ -L "$pd/$b" ]; then printf 'no:symlink\n'; return 0; fi
  printf 'ok:%s\n' "$pd/$b"
}

# The honest sentence for an attribution the ladder is not entered for. Every arm
# states a test that RAN — the index answer, a directory test, or the specific
# containment refusal `phys_path` reported — and none states a conclusion beyond it.
# This is the tool that ships "state what is true about the file you name", so the
# wording is load-bearing, not cosmetic.
out_of_reach() {
  local ln="$1" ap="$2" tracked="$3" pp="$4" why="$5" msg
  c_remote=$((c_remote + 1))
  if [ "$why" = "object-store" ]; then
    # Above the tracked test on purpose: the measured alias (`gitalias/config`) is not
    # itself tracked, so keying this on `tracked` would leave the two spellings with
    # different sentences and the oracle open.
    msg="attributed to $ap, which resolves into this repository's own \`.git\` directory — the object store is not part of the corpus this reader searches, so it is refused before any probe; not a defect"
  elif [ "$why" = "refused-textually" ]; then
    # Reported FIRST, and keyed on `why` alone — never under `tracked`: the textual
    # refusal happens BEFORE `tracked_path` is ever called, so a `tracked`-guarded
    # arm here is unreachable and control would fall to the final arm, which asserts
    # an index result from a lookup that never ran.
    msg="attributed to $ap, which is not a plain repository-relative path — absolute, \`..\`-bearing, git pathspec magic, or under \`.git/\` — so it was refused before any index or filesystem lookup ran; not a defect"
  elif [ -n "$pp" ] && [ -d "$pp" ]; then
    msg="attributed to $ap, which resolves to a directory, not a file — §1.10 binds a quotation to the file it names, so there is no single file here to resolve it in; not a defect"
  elif [ "$tracked" = "1" ]; then
    case "$why" in
      symlink)
        msg="attributed to $ap, which git tracks, but the working-tree entry there is a symlink and this reader does not follow one — refused before any read, not a defect" ;;
      escapes)
        msg="attributed to $ap, which git tracks, but its directory chain resolves physically to a path outside this repository — refused before any read, not a defect" ;;
      absent-parent)
        msg="attributed to $ap, which git tracks, but its parent directory is not present in the working tree, so there is nothing at that path to read — not a defect" ;;
      *)
        msg="attributed to $ap, which git tracks, but the working tree does not carry it as a readable regular file — out of this reader's reach, not a defect" ;;
    esac
  elif [ -n "$pp" ] && [ -e "$pp" ]; then
    # Both halves are tests that ran, and they can disagree: on a case-insensitive
    # filesystem `TRACKED.md` exists while the index refuses that spelling. The
    # sentence states the two results and names the disagreement rather than
    # concluding that the file is untracked.
    msg="attributed to $ap, where the working tree has an entry but \`git ls-files --error-unmatch\` refuses that path, so it is outside the tracked corpus this reader searches — on a case-insensitive filesystem the two can disagree about the same file; either way, not a defect"
  else
    msg="attributed to $ap, which is not a tracked path in this repository — out of this reader's reach, not a defect"
  fi
  report unresolvable-locally "$ln" "$msg" "(none — the attributed path is outside the corpus this reader searches)"
}

# The extractor. Emits one US-separated record per kept span:
#   <body line>US<attributed path>US<cited :NN>US<github-artifact flag>US<span>
# Every skip it performs is counted and stated at END.
extract() {
  LC_ALL=C awk -v US="$US" -v spanmax="$SPAN_MAX" -v spancountmax="$SPAN_COUNT_MAX" \
      -v bodylinemax="$BODY_LINE_MAX" -v APOS="'s" '
    # The single counted channel every decline reports through, and the ordered key
    # list that keeps the END output stable. APOS carries an apostrophe in from argv:
    # the program is single-quoted, so a literal apostrophe in a note cannot survive
    # any other way ("the normalising rung s cost").
    function drop_n(reason, n) {
      if (!(reason in dropn)) { order[++nord] = reason }
      dropn[reason] += n
    }
    function drop(reason) { drop_n(reason, 1) }

    # A fenced block quotes draft text, not body prose — never extracted. The
    # delimiter run is matched by CHARACTER and LENGTH, not parity: CommonMark closes
    # an N-backtick fence only with >= N backticks, so a 4-backtick block wrapping a
    # literal ``` line — the ordinary way to document fenced markdown, which this
    # corpus does constantly — is three hits on a parity toggle and silently voided
    # the check for the whole rest of the body.
    match($0, /^[ \t]*(```+|~~~+)/) {
      tok = substr($0, RSTART, RLENGTH); sub(/^[ \t]+/, "", tok)
      fenced++
      if (!fence) { fence = 1; fch = substr(tok, 1, 1); flen = length(tok); fline = NR }
      else if (substr(tok, 1, 1) == fch && length(tok) >= flen) { fence = 0 }
      next
    }
    fence { fenced++; next }
    # A body line long enough to make the scan below quadratic in its own length.
    length($0) > bodylinemax { drop(sprintf("body line(s) over %d characters were not scanned for spans — the scan is quadratic in one line%s length", bodylinemax, APOS)); next }
    {
      line = $0
      # Every C0 control except tab becomes a space — see NEUTRALISED BYTES above.
      gsub(/[\001-\010\013-\037\177]/, " ", line)
      # Only an ASCII double-quote pair is extracted. Typographic pairs are counted
      # and stated rather than declined in silence — or widened into: widening the
      # alphabet changes the span set for a case with no measured demand, while the
      # runtime count keeps the decline visible at exactly the rate it fires. The
      # count the reader prints is the census that cannot go stale; a figure written
      # here would be one that can.
      nq = gsub(/\342\200\234/, "&", line) + gsub(/\342\200\230/, "&", line)
      if (nq > 0)
        drop_n("quotation candidate(s) delimited by typographic quotes were not classified — only an ASCII double-quote pair is extracted", nq)
      ntok = 0; lastpath = ""
      rest = line; base = 0
      # Inline-code tokens, left to right, with their column in `line`.
      while (1) {
        i = index(rest, "`")
        if (i == 0) break
        after = substr(rest, i + 1)
        j = index(after, "`")
        # An unpaired backtick ends the token scan for this line, so any path named
        # after it is never seen — a span on that line can come out attributed to an
        # earlier path or to none. Counted PREEMPTIVELY rather than on demonstrated
        # demand: the point of one channel is that a decline cannot be silent, not
        # that each one has been observed firing.
        if (j == 0) {
          drop("line(s) ended with an unpaired backtick, so any path named after it on that line was not seen — an attribution may be missing or earlier than the author wrote")
          break
        }
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
        # Path-shaped: no whitespace, and either a directory separator or a trailing
        # extension. `#676`, `${#X}` and prose in backticks miss.
        if (p != "" && p !~ /[ \t]/ && (index(p, "/") > 0 || p ~ /\.[A-Za-z0-9]+$/)) {
          lastpath = p
          ntok++; ts[ntok] = start; tp[ntok] = p; tl[ntok] = cited
        }
      }
      # GitHub-artifact markers on the line — consulted only when no path attribution
      # was found, so a real path always wins and this can never convert a defect
      # into a non-defect.
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
        # An unpaired quote opens a quotation this scan cannot close, because pairing
        # is within ONE line. Both halves of a LINE-WRAPPED quotation land here too, so
        # counting this one break states the wrapped case without changing what is
        # extracted. Unlike the typographic case this one is ACTIVE rather than latent,
        # which is why it is counted instead of declared a stated limitation: lines of
        # this shape occur in ordinary prose — an escaped quote inside a sentence
        # about escaping, an unpaired quote inside inline code. No figure here on
        # purpose: a count written in a comment is drawn over a corpus that includes
        # the artifacts being edited, so it rots on the next commit. The count that
        # cannot go stale is the one the reader prints at runtime; §174j pins that
        # it prints.
        if (j == 0) {
          drop("line(s) ended with an unpaired ASCII double quote, so the quotation it opens was not classified — pairing is within one line, which also declines a quotation wrapped across two")
          break
        }
        span = substr(after, 1, j - 1)
        sstart = base + i
        base = base + i + j
        rest = substr(after, j + 1)
        t = span
        sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        # No early return for an empty or whitespace-only quotation: `split` gives it
        # 0 words, so the four-word floor below counts it — a one-word span counted
        # while a zero-word one vanishes is the inconsistency the channel exists to
        # remove. Every decline goes through drop(), so a new one cannot be silent
        # without bypassing an obvious convention.
        if (split(t, W, /[ \t]+/) < 4) { drop("span(s) under the four-word floor were not classified — a shorter quotation is too generic to bind to a site"); continue }
        if (length(t) > spanmax) { drop(sprintf("span(s) over %d characters were not classified — an over-long span is not prose, and it is one factor of the normalising rung%s cost", spanmax, APOS)); continue }
        kept++
        if (kept > spancountmax) { drop(sprintf("span(s) beyond the first %d were not classified — the per-span cost is a git process, so span count is capped", spancountmax)); continue }
        ai = 0
        for (k = 1; k <= ntok; k++) if (ts[k] < sstart) ai = k       # nearest preceding
        if (ai == 0) for (k = 1; k <= ntok; k++) if (ts[k] > sstart) { ai = k; break }
        printf "%d%s%s%s%s%s%d%s%s\n", NR, US, (ai ? tp[ai] : ""), US, (ai ? tl[ai] : ""), US, gh, US, t
      }
    }
    END {
      if (fenced > 0)
        drop_n("line(s) inside fenced blocks were not scanned for spans — fenced text is draft, not body prose", fenced)
      # Every counted decline, in first-seen order. Iteration order over an awk
      # associative array is unspecified, and a report whose lines reshuffle between
      # runs is not a record — hence the explicit order list.
      for (i = 1; i <= nord; i++)
        printf "citation note (advisory): %d %s (SPEC §1.10)\n", dropn[order[i]], order[i] > "/dev/stderr"
      if (fence != 0)
        printf "citation note (advisory): the fenced block opened at line %d is never closed, so the %d line(s) after it were treated as fenced and not scanned for spans (SPEC §1.10)\n", fline, NR - fline > "/dev/stderr"
    }
  ' < "$1"
}

# Rungs 1 through 4, for an attribution already known to be tracked, contained and
# readable. `pp` is the physically-resolved leaf; `ap` is the ROOT-relative path the
# printed searches use.
run_ladder() {
  local ln="$1" ap="$2" al="$3" span="$4" pp="$5"
  local qspan qpath searchcmd out hitline nline drift first nsites extra fsize nout r2note=""

  qspan=$(sq "$span")
  qpath=$(sq ":(literal)$ap")
  # Rung 1 — literal, at the attributed path, and NOT `-I`. For a file git deems
  # binary, `git grep` answers "Binary file X matches" with no line number — a
  # sentence, not a hit, so it must be PARSED rather than read as one. `-I` would
  # avoid the parse by hiding the file instead, which converts a span the attributed
  # file genuinely carries into an `unresolved` — the suppression-manufactures-a-
  # defect shape this reader exists to avoid: the attributed file is author-chosen,
  # and "does the file you named carry this" must be answered, with or without a
  # line number. PIPE is reset inside the capture so `git grep` still dies at
  # `head`'s closed pipe.
  searchcmd="git grep -F -h -n -e $qspan -- $qpath"
  # `LC_ALL=C` because the branch below parses git's own "Binary file …" notice, and a
  # translated catalogue would put a sentence where a line number belongs. Measured
  # untranslated on git 2.55, so this pins a latent axis rather than a live one.
  out=$( trap - PIPE; LC_ALL=C git -C "$ROOT" grep -F -h -n -e "$span" -- ":(literal)$ap" 2>/dev/null | head -1 )
  if [ -n "$out" ]; then
    c_resolves=$((c_resolves + 1))
    case "$out" in
      "Binary file "*)
        report resolves "$ln" \
          "$ap — carried, but git treats that file as binary, so no line number is available" \
          "$searchcmd"
        ;;
      *)
        hitline=${out%%:*}
        drift=""
        if [ -n "$al" ] && [ "$al" != "$hitline" ]; then
          drift=" (cited :$al, carried at :$hitline — line drift; the file is the binding half, §1.10)"
        fi
        report resolves "$ln" "$ap:$hitline$drift" "$searchcmd"
        ;;
    esac
    return
  fi

  # Rung 2 — same path, whitespace and line-wrap normalized. Informational, and
  # reported with its OWN search, since rung 1's returned nothing. The budget is
  # tested against this file's size BEFORE the read, so the stated bound is the bound
  # in force; the consequence — a single file larger than the whole remaining budget
  # is never normalised — is stated on the line it affects rather than hidden.
  nline=""
  fsize=$(wc -c < "$pp" 2>/dev/null | tr -d ' ')
  case "$fsize" in ''|*[!0-9]*) fsize=0 ;; esac
  if [ "$fsize" -le "$R2_LEFT" ]; then
    R2_LEFT=$((R2_LEFT - fsize))
    nout=$(norm_hit "$pp" "$span")
    case "$nout" in
      '') ;;
      skipped-long-lines=*)
        r2note=" (the normalising rung skipped ${nout#*=} line(s) over 65536 characters in $ap, so a whitespace-only variant on such a line is NOT ruled out)" ;;
      awk-failed=*)
        r2note=" (the normalising rung could not run — awk exited ${nout#*=} — so a whitespace-only variant is NOT ruled out)" ;;
      *) nline="$nout" ;;
    esac
  else
    r2note=" (the normalising rung was not run — $ap is larger than this run's remaining rung-2 byte budget — so a whitespace-only variant is NOT ruled out)"
  fi
  if [ -n "$nline" ]; then
    drift=""
    if [ -n "$al" ] && [ "$al" != "$nline" ]; then
      drift=" (cited :$al)"
    fi
    c_normalized=$((c_normalized + 1))
    report normalized "$ln" \
      "$ap:$nline$drift — matched only after whitespace/line-wrap normalisation; informational, not a defect" \
      "$(norm_search "$ap" "$span")"
    return
  fi

  # Rung 3 — repo-wide, minus the body itself. A committed body is tracked, so
  # without the self-exclusion a fabricated span hits itself and reports as a
  # site-mismatch it is not. The capture is bounded (`head -n 51`): a span can match
  # hundreds of thousands of lines, and only the first site plus a count is used.
  #
  # This rung DOES pass `-I`, and the asymmetry with rung 1 is deliberate. Rung 1
  # answers "does the file you named carry this", which must be answered for whatever
  # the author named. Rung 3 answers "where does this wording live as text", and a
  # byte-coincidence inside a binary is not a citation site. The cost of the choice is
  # stated: a wording carried ONLY in a binary file reports `unresolved` rather than
  # `site-mismatch`, so the class is the conservative one, not a false site.
  if [ -n "$RELBODY" ]; then
    searchcmd="git grep -I -F -n -e $qspan -- $(sq ":(exclude,top,literal)$RELBODY")"
    out=$( trap - PIPE; LC_ALL=C git -C "$ROOT" grep -I -F -n -e "$span" -- ":(exclude,top,literal)$RELBODY" 2>/dev/null | head -n 51 )
  else
    searchcmd="git grep -I -F -n -e $qspan"
    out=$( trap - PIPE; LC_ALL=C git -C "$ROOT" grep -I -F -n -e "$span" 2>/dev/null | head -n 51 )
  fi
  if [ -n "$out" ]; then
    first=$(printf '%s\n' "$out" | head -1 | cut -d: -f1,2)
    nsites=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    extra=""
    if [ "$nsites" -gt 50 ]; then
      extra=" (+50 or more other site(s))"
    elif [ "$nsites" -gt 1 ]; then
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
}

# Containment triage: decide which corpus this span's attribution belongs to, then
# either run the ladder on it or say why it is out of reach.
classify() {
  local ln="$1" ap="$2" al="$3" gh="$4" span="$5"
  local tracked=0 pp="" why="" ppr

  c_total=$((c_total + 1))

  if [ -n "$ap" ]; then
    if in_repo_path "$ap"; then
      tracked_path "$ap" && tracked=1
      ppr=$(phys_path "$ap")
      case "$ppr" in
        ok:*) pp=${ppr#ok:} ;;
        *) why=${ppr#no:} ;;
      esac
    else
      # Which refusal it was, because a `.git/` spelling and a symlink alias that
      # resolves there must yield the SAME sentence: a difference between them is the
      # oracle this refusal exists to close.
      case "$(printf '%s' "$ap" | tr '[:upper:]' '[:lower:]')" in
        ".git" | ".git/"* | *"/.git" | *"/.git/"*) why="object-store" ;;
        *) why="refused-textually" ;;
      esac
    fi
    if [ "$tracked" = "1" ] && [ -n "$pp" ] && [ -f "$pp" ] && [ -r "$pp" ]; then
      run_ladder "$ln" "$ap" "$al" "$span" "$pp"
    else
      out_of_reach "$ln" "$ap" "$tracked" "$pp" "$why"
    fi
    return
  fi

  if [ "$gh" = "1" ]; then
    c_remote=$((c_remote + 1))
    report unresolvable-locally "$ln" \
      "no working-tree path on its line, which instead names a GitHub artifact (an Issue / PR number, an issues or pull URL, a \`gh\` reference, or the word comment) — so there is nothing local to resolve it against; not a defect" \
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
  local bodydir bodyroot line ap al gh span records xrc

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
  # `--` on both: a body path opening with `-` would otherwise be read as an option,
  # ROOT would silently fall back to the cwd's repo, and the documented rung-3
  # self-exclusion would vanish. `-P`/`pwd -P` for the same reason one step further
  # in: under a LOGICAL cwd (e.g. macOS `/var`, itself a symlink) the body's
  # directory is a non-prefix of git's physical top level, RELBODY comes out empty,
  # and a wholly fabricated span then matches the body itself and reports
  # `site-mismatch` — §1.10's discriminator, backwards.
  bodydir=$(cd -P -- "$(dirname -- "$BODY")" 2>/dev/null && pwd -P)
  if [ -n "$bodydir" ]; then
    bodyroot=$(git -C "$bodydir" rev-parse --show-toplevel 2>/dev/null)
    ROOT="$bodyroot"
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
  # The self-exclusion pathspec is set ONLY when the body's own repository is the
  # one being searched: excluding a bare basename from a repo the body is not in
  # would exclude an unrelated tracked file that shares the name, turning a real
  # site-mismatch into `unresolved`. Empty is the safe value — rung 3 searches
  # ROOT's tracked files, and a body outside ROOT is by construction not among
  # them, so no self-hit is possible without the exclusion.
  if [ -n "$bodydir" ] && [ -n "${bodyroot:-}" ] && [ "$bodyroot" = "$ROOT" ]; then
    RELBODY="$(git -C "$bodydir" rev-parse --show-prefix 2>/dev/null)$(basename -- "$BODY")"
  fi

  emit "$(printf '# citation report: %s (SPEC §1.10 part (a) — advisory, exit 0 always)' "$BODY")"
  # The extractor is CAPTURED rather than piped in, so its exit status is observable
  # — through a pipe or process substitution it is not, and a producer that dies
  # mid-body silently drops every remaining span while stdout still reads like a
  # clean report. `LC_ALL=C` inside `extract` removes the one author-reachable way
  # to kill it; this check is the backstop that states any other producer failure,
  # the producer-side twin of the TRUNCATED sentinel. The record set is bounded by
  # SPAN_COUNT_MAX, so holding it is bounded too.
  records=$(extract "$BODY")
  xrc=$?
  if [ "$xrc" -ne 0 ]; then
    printf 'citation note (advisory): the extractor exited %d — the body was NOT fully scanned for spans, and the report below is partial (SPEC §1.10)\n' \
      "$xrc" >&2
  fi
  while IFS="$US" read -r line ap al gh span; do
    [ "$TRUNCATED" -eq 0 ] || break
    [ -n "$span" ] || continue
    classify "$line" "$ap" "$al" "$gh" "$span"
  done <<< "$records"

  if [ "$c_noattr" -gt 0 ]; then
    emit "$(printf '%s: no-attribution — %d span(s) name no file on their line (line(s):%s); informational, never a defect' \
      "$BODY" "$c_noattr" "$na_lines")"
    emit '    search: (none — a span with no attributed file has nothing to search against)'
  fi

  # Totals on stderr: no author-supplied text reaches this line, so it is the
  # authoritative count when a report line's own class token could be shadowed by an
  # attributed path named after a class.
  printf 'citation totals (advisory): %d span(s) — resolves=%d normalized=%d site-mismatch=%d unresolved=%d unresolvable-locally=%d no-attribution=%d\n' \
    "$c_total" "$c_resolves" "$c_normalized" "$c_mismatch" "$c_unresolved" "$c_remote" "$c_noattr" >&2

  return 0
}

main "$@"
# SIGPIPE is ignored above, so a closed stdout leaves a failed write, never a 141
# exit. Status is stated once, here.
exit 0
