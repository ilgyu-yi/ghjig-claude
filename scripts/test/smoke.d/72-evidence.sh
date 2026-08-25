# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after 71-judged-list.sh (#716). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §184: ghjig_evidence.sh — the evidence/quote emitter, locked as behavior (#716) ----------
# scripts/ghjig_evidence.sh's header is the contract's single code home
# (Directive #637 L2's instrument); this block is its negative face: NORMAL-
# BEHAVIOR arms that execute the script as an executable file inside scratch
# fixture git repos (deterministic HEAD sha for the pin assertions,
# controllable clean/dirty trees). The behavior these arms lock:
#   * `evidence '<command>'` — the command string runs VERBATIM via `bash -c`
#     in its own process group; rc=0 emits ONE fenced block: a `$ <command>`
#     line, the command's stdout bytes verbatim, the pin line. Non-zero rc or
#     timeout: exit 2, NOTHING on stdout, the child rc named on stderr. A
#     newline-bearing command is refused (exit 1, the refusal named).
#   * `quote <path> <span-file>` — fixed-string byte match; a clean tracked
#     path resolves via the HEAD BLOB (blob-read isolation: the worktree copy
#     is not the source, and a symlink entry never reads through to its
#     target); a miss exits 3 naming the path, emitting nothing; a NUL byte in
#     the span is refused (exit 1 — the shellvar channel would false-hit); the
#     worktree branch refuses a symlink leaf (exit 1). Attribution line:
#     `quoted from <path>:<line>`, line = newlines-before-match + 1.
#   * block shape — fence escalation past any payload backtick run opening a
#     line at <=3 spaces of indentation; `\ no-eol` marker line before the pin
#     when the output lacks a trailing newline. Recovery rule (byte-identical
#     re-execution, #637's discrimination signal): the output bytes are the
#     block bytes between the command line and the pin/marker line, minus the
#     injected final newline when the marker is present.
#   * pin — `pin: <head-sha> <YYYY-MM-DD>Z`; `(dirty)` after the sha on an
#     unclean tree, absent on a clean one.
#   * timeout — GHJIG_EVIDENCE_TIMEOUT (digits only) expires the child's whole
#     PROCESS GROUP: pipeline members do not survive the leader.
#   * environment — pure-local: a green evidence run needs only the
#     bash/git/awk/coreutils dirs on PATH (no gh, no jq, no curl).
# Exit codes pinned: 0 ok · 1 usage/environment/refusal · 2 evidence command
# failed or timed out · 3 quotation does not resolve.
#
# Fail-closed harness discipline: an absent/non-executable script or a failed
# fixture build reds EVERY arm below as ng — never a skip, never a harness
# error. No .md phrase-pinning anywhere in this block (Directive #637 L3).

S184E_SCRIPT="$SHELL_ROOT/scripts/ghjig_evidence.sh"
S184E_DIR="$TMP/s184e"
S184E_FX="$S184E_DIR/fx"
S184E_R1="$S184E_DIR/r1"   # clean repo: quote sources + green evidence pins
S184E_R2="$S184E_DIR/r2"   # dirty repo: uncommitted change -> (dirty) pin
S184E_R3="$S184E_DIR/r3"   # symlink pair + blob-read isolation repo
mkdir -p "$S184E_FX" "$S184E_R1" "$S184E_R2" "$S184E_R3"

s184e_git() { git -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@"; }

# r1 — committed once, then never touched: its HEAD sha is the deterministic
# pin target and its tree stays clean for the clean-pin assertions.
(
  cd "$S184E_R1" || exit 9
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  cat > note.txt <<'S184E_NOTE'
alpha line one
beta line two
gamma target line
delta four
epsilon five
zeta six
omega last
S184E_NOTE
  printf 'mismatch span content\n' > other.txt
  printf 'abcdef\n' > nul.txt
  git add note.txt other.txt nul.txt
  s184e_git commit -q -m fx
) >/dev/null 2>&1
S184E_R1_SHA=$(git -C "$S184E_R1" rev-parse HEAD 2>/dev/null)

# r2 — one committed file, then an uncommitted append: a dirty tree by
# construction, for the (dirty) pin arm.
(
  cd "$S184E_R2" || exit 9
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  printf 'base line\n' > f.txt
  git add f.txt
  s184e_git commit -q -m fx
  printf 'uncommitted extra\n' >> f.txt
) >/dev/null 2>&1

# r3 — real.txt committed WITH the span, then the span deleted from the
# WORKTREE copy (HEAD still carries it -> blob-read isolation probe), plus an
# untracked in-repo symlink to an untracked plain file that DOES contain the
# span (the read-through bait the symlink-leaf refusal must not take).
(
  cd "$S184E_R3" || exit 9
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  printf 'filler first\nsigil span payload\ntrailing third\n' > real.txt
  git add real.txt
  s184e_git commit -q -m fx
  printf 'no payload here\n' > real.txt
  printf 'sigil span payload\n' > target_plain.txt
  ln -s target_plain.txt link.txt
) >/dev/null 2>&1

# Span fixtures (quote's second argument is a span FILE).
printf 'gamma target line\n' > "$S184E_FX/span_g.txt"
printf 'delta four\nepsilon five\nzeta six\n' > "$S184E_FX/span_h.txt"
printf 'no such span anywhere in the fixture\n' > "$S184E_FX/span_i.txt"
printf 'mismatch span content\n' > "$S184E_FX/span_j.txt"
printf 'abc\0def' > "$S184E_FX/span_k.bin"
printf 'sigil span payload\n' > "$S184E_FX/span_l.txt"

# Fail-closed readiness — consumed by every arm's guard branch. Fixture-build
# integrity is part of readiness: an arm asserting against a half-built repo
# would red for the wrong reason (or worse, green vacuously).
S184E_UNREADY=""
[ -x "$S184E_SCRIPT" ] || S184E_UNREADY="scripts/ghjig_evidence.sh absent or not executable"
[ -n "$S184E_R1_SHA" ] || S184E_UNREADY="${S184E_UNREADY:+$S184E_UNREADY; }r1 fixture repo has no HEAD"
[ -z "$(git -C "$S184E_R1" status --porcelain 2>/dev/null)" ] || S184E_UNREADY="${S184E_UNREADY:+$S184E_UNREADY; }r1 fixture tree not clean"
git -C "$S184E_R2" rev-parse HEAD >/dev/null 2>&1 || S184E_UNREADY="${S184E_UNREADY:+$S184E_UNREADY; }r2 fixture repo has no HEAD"
[ -n "$(git -C "$S184E_R2" status --porcelain 2>/dev/null)" ] || S184E_UNREADY="${S184E_UNREADY:+$S184E_UNREADY; }r2 fixture tree not dirty"
[ -L "$S184E_R3/link.txt" ] || S184E_UNREADY="${S184E_UNREADY:+$S184E_UNREADY; }r3 symlink missing"
git -C "$S184E_R3" show HEAD:real.txt 2>/dev/null | grep -qF 'sigil span payload' || S184E_UNREADY="${S184E_UNREADY:+$S184E_UNREADY; }r3 HEAD blob lost the span"
if grep -qF 'sigil span payload' "$S184E_R3/real.txt" 2>/dev/null; then S184E_UNREADY="${S184E_UNREADY:+$S184E_UNREADY; }r3 worktree still carries the span"; fi
[ "$(wc -c < "$S184E_FX/span_k.bin" | tr -d ' ')" = 7 ] || S184E_UNREADY="${S184E_UNREADY:+$S184E_UNREADY; }NUL span fixture lost its NUL byte"

# s184e_run <repo> <out> <err> <argv…> — invoke the script under test as an
# executable file from the fixture repo root, stdout/stderr split.
s184e_run() {
  s184e_run_repo="$1"; s184e_run_out="$2"; s184e_run_err="$3"; shift 3
  ( cd "$s184e_run_repo" && "$S184E_SCRIPT" "$@" ) >"$s184e_run_out" 2>"$s184e_run_err"
}

s184e_pin_line() { grep '^pin: ' "$1" | head -n 1; }

# s184e_sha_matches <pin-line> <full-sha> — the pin sha (field 2) identifies
# the fixture HEAD: a >=7-hex prefix of the full sha (short or full accepted).
s184e_sha_matches() {
  local s
  s=$(printf '%s' "$1" | awk '{print $2}')
  [ "${#s}" -ge 7 ] || return 1
  case "$2" in "$s"*) return 0 ;; esac
  return 1
}

# s184e_recover <block-file> <out-file> — the header's recovery rule, applied
# literally: skip the opening fence and the `$ <command>` line; the output
# bytes run to the line before the pin (or before the `\ no-eol` marker, in
# which case the injected final newline is dropped).
s184e_recover() {
  awk '
    NR <= 2 { next }
    { lines[++n] = $0 }
    END {
      end = n - 2; noeol = 0
      if (n >= 3 && lines[n-2] == "\\ no-eol") { end = n - 3; noeol = 1 }
      for (i = 1; i <= end; i++) {
        if (i == end && noeol) printf "%s", lines[i]
        else printf "%s\n", lines[i]
      }
    }
  ' "$1" > "$2"
}

# §184a (READINESS — FAIL-CLOSED GUARD, born GREEN): the script is present and
# executable and every fixture built to spec. When this arm reds, every arm
# below reds with the same reason — the guard is a loud red, never a skip.
if [ -n "$S184E_UNREADY" ]; then
  ng "184a: readiness — evidence/quote harness not ready: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  ok "184a: readiness — script executable; fixtures built (clean r1@HEAD, dirty r2, symlink+blob-isolation r3, 7-byte NUL span) (#716)"
fi

# §184b (EVIDENCE — THE GREEN BLOCK, AC1; born RED until #716 Phase C): a
# fixture command in the clean repo exits 0 and emits ONE fenced block: the
# `$ <command>` line verbatim, the exact stdout bytes (recovered per the
# header rule), and a clean pin whose sha is the fixture HEAD — no (dirty).
if [ -n "$S184E_UNREADY" ]; then
  ng "184b: evidence — green fenced block not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_b_cmd="printf 'a\nb\n'"
  s184e_run "$S184E_R1" "$S184E_DIR/b.out" "$S184E_DIR/b.err" evidence "$s184e_b_cmd"; s184e_b_rc=$?
  s184e_b_miss=""
  [ "$s184e_b_rc" = 0 ] || s184e_b_miss="$s184e_b_miss <rc=$s184e_b_rc!=0>"
  head -n 1 "$S184E_DIR/b.out" | grep -qE '^`{3,}$' || s184e_b_miss="$s184e_b_miss <no-opening-fence>"
  grep -qxF "\$ $s184e_b_cmd" "$S184E_DIR/b.out" || s184e_b_miss="$s184e_b_miss <command-line-not-verbatim>"
  bash -c "$s184e_b_cmd" > "$S184E_DIR/b.expect"
  s184e_recover "$S184E_DIR/b.out" "$S184E_DIR/b.got"
  cmp -s "$S184E_DIR/b.expect" "$S184E_DIR/b.got" || s184e_b_miss="$s184e_b_miss <output-bytes-not-verbatim>"
  [ "$(grep -c '^pin: ' "$S184E_DIR/b.out")" = 1 ] || s184e_b_miss="$s184e_b_miss <pin-lines!=1>"
  s184e_b_pin=$(s184e_pin_line "$S184E_DIR/b.out")
  printf '%s\n' "$s184e_b_pin" | grep -qE '^pin: [0-9a-f]{7,40} [0-9]{4}-[0-9]{2}-[0-9]{2}Z$' || s184e_b_miss="$s184e_b_miss <clean-pin-shape-wrong>"
  s184e_sha_matches "$s184e_b_pin" "$S184E_R1_SHA" || s184e_b_miss="$s184e_b_miss <pin-sha-not-fixture-HEAD>"
  case "$s184e_b_pin" in *"(dirty)"*) s184e_b_miss="$s184e_b_miss <dirty-mark-on-clean-tree>";; esac
  if [ -z "$s184e_b_miss" ]; then
    ok "184b: evidence — exit 0; \$-line verbatim, stdout bytes exact, pin sha == fixture HEAD, no (dirty) on a clean tree (#716)"
  else
    ng "184b: evidence broke the green-block contract —$s184e_b_miss (#716)"
  fi
fi

# §184c (EVIDENCE — FAILING COMMAND EMITS NOTHING, AC1; born RED): a command
# exiting 3 after partial output yields exit 2, a byte-empty stdout (no
# partial block, ever), and the child rc NAMED on stderr — the naming is what
# a bare not-implemented stub cannot fake.
if [ -n "$S184E_UNREADY" ]; then
  ng "184c: evidence — failing-command emptiness not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R1" "$S184E_DIR/c.out" "$S184E_DIR/c.err" evidence "printf partial; exit 3"; s184e_c_rc=$?
  s184e_c_miss=""
  [ "$s184e_c_rc" = 2 ] || s184e_c_miss="$s184e_c_miss <rc=$s184e_c_rc!=2>"
  [ ! -s "$S184E_DIR/c.out" ] || s184e_c_miss="$s184e_c_miss <stdout-not-byte-empty>"
  grep -qE '(^|[^0-9])3([^0-9]|$)' "$S184E_DIR/c.err" || s184e_c_miss="$s184e_c_miss <child-rc-3-not-named-on-stderr>"
  if [ -z "$s184e_c_miss" ]; then
    ok "184c: evidence — a failing command exits 2 with byte-empty stdout and the child rc (3) named on stderr (#716)"
  else
    ng "184c: a failing evidence command leaked output or lost its cause —$s184e_c_miss (#716)"
  fi
fi

# §184d (EVIDENCE — BYTE-IDENTICAL RE-EXECUTION, AC1; born RED): extract the
# output bytes from an emitted block per the header's recovery rule, re-run
# the block's own command line, cmp identical — #637's discrimination signal.
if [ -n "$S184E_UNREADY" ]; then
  ng "184d: evidence — byte-identical re-execution not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_d_cmd="printf '%s\n' one 'two  spaced' three"
  s184e_run "$S184E_R1" "$S184E_DIR/d.out" "$S184E_DIR/d.err" evidence "$s184e_d_cmd"; s184e_d_rc=$?
  s184e_d_miss=""
  [ "$s184e_d_rc" = 0 ] || s184e_d_miss="$s184e_d_miss <rc=$s184e_d_rc!=0>"
  s184e_recover "$S184E_DIR/d.out" "$S184E_DIR/d.got"
  bash -c "$s184e_d_cmd" > "$S184E_DIR/d.rerun"
  cmp -s "$S184E_DIR/d.got" "$S184E_DIR/d.rerun" || s184e_d_miss="$s184e_d_miss <recovered-bytes-diverge-from-re-execution>"
  if [ -z "$s184e_d_miss" ]; then
    ok "184d: evidence — recovered block bytes cmp-identical to a fresh re-execution of the block's command (#716)"
  else
    ng "184d: the emitted block does not re-execute byte-identical —$s184e_d_miss (#716)"
  fi
fi

# §184e (EVIDENCE — NO-EOL MARKER, AC1; born RED): output lacking a trailing
# newline carries the `\ no-eol` marker line immediately before the pin, and
# the recovery rule (drop the injected final newline) restores the exact byte.
if [ -n "$S184E_UNREADY" ]; then
  ng "184e: evidence — no-eol marker not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R1" "$S184E_DIR/e.out" "$S184E_DIR/e.err" evidence "printf 'x'"; s184e_e_rc=$?
  s184e_e_miss=""
  [ "$s184e_e_rc" = 0 ] || s184e_e_miss="$s184e_e_miss <rc=$s184e_e_rc!=0>"
  awk '/^pin: / { if (prev == "\\ no-eol") found = 1 } { prev = $0 } END { exit found ? 0 : 1 }' "$S184E_DIR/e.out" \
    || s184e_e_miss="$s184e_e_miss <no-eol-marker-not-immediately-before-pin>"
  printf 'x' > "$S184E_DIR/e.expect"
  s184e_recover "$S184E_DIR/e.out" "$S184E_DIR/e.got"
  cmp -s "$S184E_DIR/e.expect" "$S184E_DIR/e.got" || s184e_e_miss="$s184e_e_miss <recovered-bytes-not-the-single-x>"
  if [ -z "$s184e_e_miss" ]; then
    ok "184e: evidence — newline-less output carries the no-eol marker before the pin and recovers byte-identical (#716)"
  else
    ng "184e: the no-eol marker/recovery contract is broken —$s184e_e_miss (#716)"
  fi
fi

# §184f (EVIDENCE — NEWLINE-BEARING COMMAND REFUSED, AC1; born RED on the
# message class): a command string containing a newline can never re-execute
# from the block's single `$` line — exit 1, empty stdout, the refusal class
# (newline) named on stderr.
if [ -n "$S184E_UNREADY" ]; then
  ng "184f: evidence — newline-command refusal not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_f_cmd=$'printf a\nprintf b'
  s184e_run "$S184E_R1" "$S184E_DIR/f.out" "$S184E_DIR/f.err" evidence "$s184e_f_cmd"; s184e_f_rc=$?
  s184e_f_miss=""
  [ "$s184e_f_rc" = 1 ] || s184e_f_miss="$s184e_f_miss <rc=$s184e_f_rc!=1>"
  [ ! -s "$S184E_DIR/f.out" ] || s184e_f_miss="$s184e_f_miss <stdout-not-empty>"
  grep -qi 'newline' "$S184E_DIR/f.err" || s184e_f_miss="$s184e_f_miss <refusal-class-newline-not-named>"
  if [ -z "$s184e_f_miss" ]; then
    ok "184f: evidence — a newline-bearing command is refused (exit 1, nothing emitted, newline named on stderr) (#716)"
  else
    ng "184f: a newline-bearing command was not refused by name —$s184e_f_miss (#716)"
  fi
fi

# §184g (QUOTE — SINGLE-LINE SPAN, AC2; born RED): a span sitting on line 3 of
# a tracked-clean file resolves: exit 0, the span in the block, the
# attribution `quoted from note.txt:3` with the CORRECT line number, a clean
# pin bound to the fixture HEAD.
if [ -n "$S184E_UNREADY" ]; then
  ng "184g: quote — single-line span resolution not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R1" "$S184E_DIR/g.out" "$S184E_DIR/g.err" quote note.txt "$S184E_FX/span_g.txt"; s184e_g_rc=$?
  s184e_g_miss=""
  [ "$s184e_g_rc" = 0 ] || s184e_g_miss="$s184e_g_miss <rc=$s184e_g_rc!=0>"
  grep -qF 'gamma target line' "$S184E_DIR/g.out" || s184e_g_miss="$s184e_g_miss <span-missing-from-block>"
  grep -qE 'quoted from note\.txt:3([^0-9]|$)' "$S184E_DIR/g.out" || s184e_g_miss="$s184e_g_miss <attribution-line-number-not-3>"
  [ "$(grep -c '^pin: ' "$S184E_DIR/g.out")" = 1 ] || s184e_g_miss="$s184e_g_miss <pin-lines!=1>"
  s184e_g_pin=$(s184e_pin_line "$S184E_DIR/g.out")
  s184e_sha_matches "$s184e_g_pin" "$S184E_R1_SHA" || s184e_g_miss="$s184e_g_miss <pin-sha-not-fixture-HEAD>"
  case "$s184e_g_pin" in *"(dirty)"*) s184e_g_miss="$s184e_g_miss <dirty-mark-on-clean-tree>";; esac
  if [ -z "$s184e_g_miss" ]; then
    ok "184g: quote — single-line span resolves with quoted from note.txt:3 and a clean HEAD-bound pin (#716)"
  else
    ng "184g: quote broke single-line resolution/attribution —$s184e_g_miss (#716)"
  fi
fi

# §184h (QUOTE — MULTI-LINE SPAN, AC2; born RED): a three-line span starting
# on line 4 resolves with the STARTING line number in the attribution.
if [ -n "$S184E_UNREADY" ]; then
  ng "184h: quote — multi-line span resolution not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R1" "$S184E_DIR/h.out" "$S184E_DIR/h.err" quote note.txt "$S184E_FX/span_h.txt"; s184e_h_rc=$?
  s184e_h_miss=""
  [ "$s184e_h_rc" = 0 ] || s184e_h_miss="$s184e_h_miss <rc=$s184e_h_rc!=0>"
  grep -qF 'delta four' "$S184E_DIR/h.out" || s184e_h_miss="$s184e_h_miss <span-first-line-missing>"
  grep -qF 'zeta six' "$S184E_DIR/h.out" || s184e_h_miss="$s184e_h_miss <span-last-line-missing>"
  grep -qE 'quoted from note\.txt:4([^0-9]|$)' "$S184E_DIR/h.out" || s184e_h_miss="$s184e_h_miss <attribution-not-starting-line-4>"
  if [ -z "$s184e_h_miss" ]; then
    ok "184h: quote — a 3-line span resolves attributed to its starting line (note.txt:4) (#716)"
  else
    ng "184h: quote broke multi-line resolution/attribution —$s184e_h_miss (#716)"
  fi
fi

# §184i (QUOTE — ABSENT SPAN IS A LOUD MISS, AC2; born RED: the stub exits 1,
# the contract says 3): a span nowhere in the attributed file exits 3, emits
# NOTHING (no emit-anyway form), and names the path on stderr.
if [ -n "$S184E_UNREADY" ]; then
  ng "184i: quote — absent-span miss not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R1" "$S184E_DIR/i.out" "$S184E_DIR/i.err" quote note.txt "$S184E_FX/span_i.txt"; s184e_i_rc=$?
  s184e_i_miss=""
  [ "$s184e_i_rc" = 3 ] || s184e_i_miss="$s184e_i_miss <rc=$s184e_i_rc!=3>"
  [ ! -s "$S184E_DIR/i.out" ] || s184e_i_miss="$s184e_i_miss <stdout-not-empty>"
  grep -qF 'note.txt' "$S184E_DIR/i.err" || s184e_i_miss="$s184e_i_miss <path-not-named-on-stderr>"
  if [ -z "$s184e_i_miss" ]; then
    ok "184i: quote — an absent span exits 3, emits nothing, names note.txt on stderr (#716)"
  else
    ng "184i: an absent span was not a loud empty exit-3 miss —$s184e_i_miss (#716)"
  fi
fi

# §184j (QUOTE — PATH-MISMATCH IS A MISS, AC2; born RED): a span that DOES
# exist in other.txt but is attributed to note.txt exits 3 with nothing
# emitted — attribution binds to the named path, not to "somewhere in the
# repo". Positive control: the same span attributed to other.txt resolves,
# proving the mismatch arm reds on attribution, not on span absence.
if [ -n "$S184E_UNREADY" ]; then
  ng "184j: quote — path-mismatch miss not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R1" "$S184E_DIR/j.out" "$S184E_DIR/j.err" quote note.txt "$S184E_FX/span_j.txt"; s184e_j_rc=$?
  s184e_j_miss=""
  [ "$s184e_j_rc" = 3 ] || s184e_j_miss="$s184e_j_miss <mismatch-rc=$s184e_j_rc!=3>"
  [ ! -s "$S184E_DIR/j.out" ] || s184e_j_miss="$s184e_j_miss <mismatch-emitted-output>"
  s184e_run "$S184E_R1" "$S184E_DIR/j2.out" "$S184E_DIR/j2.err" quote other.txt "$S184E_FX/span_j.txt"; s184e_j_rc2=$?
  [ "$s184e_j_rc2" = 0 ] || s184e_j_miss="$s184e_j_miss <control-correct-path-rc=$s184e_j_rc2!=0>"
  if [ -z "$s184e_j_miss" ]; then
    ok "184j: quote — a span present only in a DIFFERENT file than attributed exits 3; the correctly-attributed control resolves (#716)"
  else
    ng "184j: attribution did not bind to the named path —$s184e_j_miss (#716)"
  fi
fi

# §184k (QUOTE — NUL SPAN REFUSED, AC2; born RED on the message class): file
# `abcdef`, span `abc<NUL>def` — the shellvar channel strips NUL, so comparing
# through it would FALSE-HIT. The contract: refusal, exit 1, NUL named on
# stderr — neither a hit nor a silent miss.
if [ -n "$S184E_UNREADY" ]; then
  ng "184k: quote — NUL-span refusal not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R1" "$S184E_DIR/k.out" "$S184E_DIR/k.err" quote nul.txt "$S184E_FX/span_k.bin"; s184e_k_rc=$?
  s184e_k_miss=""
  [ "$s184e_k_rc" = 1 ] || s184e_k_miss="$s184e_k_miss <rc=$s184e_k_rc!=1:neither-hit-0-nor-miss-3-allowed>"
  [ ! -s "$S184E_DIR/k.out" ] || s184e_k_miss="$s184e_k_miss <stdout-not-empty>"
  grep -qi 'nul' "$S184E_DIR/k.err" || s184e_k_miss="$s184e_k_miss <refusal-class-NUL-not-named>"
  if [ -z "$s184e_k_miss" ]; then
    ok "184k: quote — a NUL-bearing span is refused by name (exit 1), never false-hit through the shellvar channel (#716)"
  else
    ng "184k: the NUL span was not refused by name —$s184e_k_miss (#716)"
  fi
fi

# §184l (QUOTE — SYMLINK-LEAF REFUSAL + BLOB-READ ISOLATION, AC2; born RED):
# in the dirty r3, the attributed path link.txt is an in-repo symlink to a
# file that CONTAINS the span — reading through it would hit, so exit 0 here
# means the refusal was skipped; the contract is exit 1, nothing emitted.
# Positive twin: real.txt is tracked and its HEAD blob carries the span while
# the WORKTREE copy no longer does — resolution via the HEAD blob still exits
# 0 with the correct HEAD-side line number (blob-read isolation).
if [ -n "$S184E_UNREADY" ]; then
  ng "184l: quote — symlink refusal + blob-read isolation not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R3" "$S184E_DIR/l.out" "$S184E_DIR/l.err" quote link.txt "$S184E_FX/span_l.txt"; s184e_l_rc=$?
  s184e_l_miss=""
  [ "$s184e_l_rc" = 1 ] || s184e_l_miss="$s184e_l_miss <symlink-rc=$s184e_l_rc!=1>"
  [ ! -s "$S184E_DIR/l.out" ] || s184e_l_miss="$s184e_l_miss <symlink-path-emitted-a-block>"
  s184e_run "$S184E_R3" "$S184E_DIR/l2.out" "$S184E_DIR/l2.err" quote real.txt "$S184E_FX/span_l.txt"; s184e_l_rc2=$?
  [ "$s184e_l_rc2" = 0 ] || s184e_l_miss="$s184e_l_miss <blob-isolation-rc=$s184e_l_rc2!=0>"
  grep -qF 'sigil span payload' "$S184E_DIR/l2.out" || s184e_l_miss="$s184e_l_miss <blob-span-missing-from-block>"
  grep -qE 'quoted from real\.txt:2([^0-9]|$)' "$S184E_DIR/l2.out" || s184e_l_miss="$s184e_l_miss <HEAD-side-line-2-attribution-missing>"
  if [ -z "$s184e_l_miss" ]; then
    ok "184l: quote — the span-bearing symlink is refused unread (exit 1); the tracked twin resolves from the HEAD blob after its worktree copy lost the span (#716)"
  else
    ng "184l: symlink-leaf refusal or blob-read isolation is broken —$s184e_l_miss (#716)"
  fi
fi

# §184m (PIN — DIRTY MARK ON AN UNCLEAN TREE; born RED): evidence in the dirty
# r2 pins with `(dirty)` after the sha; the clean-r1 twin's pin carries no
# such mark — the discrimination-signal boundary (#637 claims byte-identical
# re-execution only for a clean pin).
if [ -n "$S184E_UNREADY" ]; then
  ng "184m: pin — dirty/clean tree marking not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_run "$S184E_R2" "$S184E_DIR/m.out" "$S184E_DIR/m.err" evidence "printf ok"; s184e_m_rc=$?
  s184e_m_miss=""
  [ "$s184e_m_rc" = 0 ] || s184e_m_miss="$s184e_m_miss <dirty-run-rc=$s184e_m_rc!=0>"
  s184e_m_pin=$(s184e_pin_line "$S184E_DIR/m.out")
  case "$s184e_m_pin" in
    *"(dirty)"*) : ;;
    *) s184e_m_miss="$s184e_m_miss <dirty-tree-pin-lacks-dirty-mark>" ;;
  esac
  s184e_run "$S184E_R1" "$S184E_DIR/m2.out" "$S184E_DIR/m2.err" evidence "printf ok"; s184e_m_rc2=$?
  [ "$s184e_m_rc2" = 0 ] || s184e_m_miss="$s184e_m_miss <clean-run-rc=$s184e_m_rc2!=0>"
  s184e_m_pin2=$(s184e_pin_line "$S184E_DIR/m2.out")
  [ -n "$s184e_m_pin2" ] || s184e_m_miss="$s184e_m_miss <clean-run-pin-missing>"
  case "$s184e_m_pin2" in *"(dirty)"*) s184e_m_miss="$s184e_m_miss <clean-tree-pin-carries-dirty-mark>";; esac
  if [ -z "$s184e_m_miss" ]; then
    ok "184m: pin — an uncommitted change puts (dirty) on the pin; the clean twin stays unmarked (#716)"
  else
    ng "184m: the (dirty) pin mark does not track tree state —$s184e_m_miss (#716)"
  fi
fi

# §184n (TIMEOUT — PROCESS-GROUP KILL, AC3; born RED): under a 1s override, a
# pipeline of two pgrep-able sentinels (argv-tagged bash wrappers around
# sleep) returns non-zero (exit 2) within a bounded wait, emits nothing, and
# leaves NO sentinel survivor — a leader-only TERM would orphan the second
# pipeline member.
if [ -n "$S184E_UNREADY" ]; then
  ng "184n: timeout — process-group kill not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_n_tag="s184sent$$"
  s184e_n_rcf="$S184E_DIR/n.rc"
  rm -f "$s184e_n_rcf"
  (
    cd "$S184E_R1" \
      && GHJIG_EVIDENCE_TIMEOUT=1 "$S184E_SCRIPT" evidence \
           "bash -c 'sleep 300' ${s184e_n_tag}A | bash -c 'sleep 300' ${s184e_n_tag}B" \
           >"$S184E_DIR/n.out" 2>"$S184E_DIR/n.err"
    printf '%s\n' "$?" > "$s184e_n_rcf"
  ) &
  s184e_n_bg=$!
  disown "$s184e_n_bg" 2>/dev/null
  s184e_n_miss=""
  s184e_n_i=0
  while [ ! -s "$s184e_n_rcf" ] && [ "$s184e_n_i" -lt 200 ]; do sleep 0.1; s184e_n_i=$((s184e_n_i + 1)); done
  if [ ! -s "$s184e_n_rcf" ]; then
    s184e_n_miss="$s184e_n_miss <no-return-within-20s-bound>"
    kill -KILL "$s184e_n_bg" 2>/dev/null
  else
    s184e_n_rc=$(cat "$s184e_n_rcf")
    [ "$s184e_n_rc" = 2 ] || s184e_n_miss="$s184e_n_miss <rc=$s184e_n_rc!=2>"
    [ ! -s "$S184E_DIR/n.out" ] || s184e_n_miss="$s184e_n_miss <stdout-not-empty>"
    # Grace poll: the group kill must clear BOTH argv-tagged sentinels.
    s184e_n_i=0
    while pgrep -f "$s184e_n_tag" >/dev/null 2>&1 && [ "$s184e_n_i" -lt 50 ]; do sleep 0.1; s184e_n_i=$((s184e_n_i + 1)); done
    if pgrep -f "$s184e_n_tag" >/dev/null 2>&1; then
      s184e_n_miss="$s184e_n_miss <sentinel-survived-the-group-kill>"
    fi
  fi
  pkill -f "$s184e_n_tag" 2>/dev/null
  if [ -z "$s184e_n_miss" ]; then
    ok "184n: timeout — 1s override exits 2 within the bound, empty stdout, no pipeline member survives the process-group kill (#716)"
  else
    ng "184n: the timeout did not kill the child's process group cleanly —$s184e_n_miss (#716)"
  fi
fi

# §184o (ENVIRONMENT — GREEN UNDER A STRIPPED PATH, AC3; born RED): a green
# evidence run under a PATH of only the bash/git/awk/coreutils dirs — the
# script needs no gh, no jq, no curl (pure-local). Count-guard: each required
# tool must resolve BEFORE the strip, or the arm reds loud instead of running
# under a half-built PATH.
if [ -n "$S184E_UNREADY" ]; then
  ng "184o: environment — stripped-PATH green run not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_o_miss=""
  s184e_o_path=""
  for s184e_o_t in bash git awk ls cat rm mv mkdir mktemp date wc tr head sort cut dirname basename sleep env printf; do
    s184e_o_bin=$(command -v "$s184e_o_t" 2>/dev/null)
    if [ -z "$s184e_o_bin" ] || [ ! -e "$s184e_o_bin" ]; then
      case "$s184e_o_t" in
        bash|git|awk|ls) s184e_o_miss="$s184e_o_miss <required-tool-unresolvable:$s184e_o_t>" ;;
      esac
      continue
    fi
    s184e_o_d=$(dirname "$s184e_o_bin")
    case ":$s184e_o_path:" in
      *":$s184e_o_d:"*) : ;;
      *) s184e_o_path="${s184e_o_path:+$s184e_o_path:}$s184e_o_d" ;;
    esac
  done
  [ -n "$s184e_o_path" ] || s184e_o_miss="$s184e_o_miss <stripped-PATH-empty>"
  ( cd "$S184E_R1" && PATH="$s184e_o_path" "$S184E_SCRIPT" evidence "printf 'a\nb\n'" ) \
    >"$S184E_DIR/o.out" 2>"$S184E_DIR/o.err"; s184e_o_rc=$?
  [ "$s184e_o_rc" = 0 ] || s184e_o_miss="$s184e_o_miss <rc=$s184e_o_rc!=0>"
  grep -qxF "\$ printf 'a\nb\n'" "$S184E_DIR/o.out" || s184e_o_miss="$s184e_o_miss <command-line-missing>"
  bash -c "printf 'a\nb\n'" > "$S184E_DIR/o.expect"
  s184e_recover "$S184E_DIR/o.out" "$S184E_DIR/o.got"
  cmp -s "$S184E_DIR/o.expect" "$S184E_DIR/o.got" || s184e_o_miss="$s184e_o_miss <output-bytes-not-verbatim>"
  if [ -z "$s184e_o_miss" ]; then
    ok "184o: environment — a green evidence run completes under a bash/git/awk/coreutils-dirs-only PATH (#716)"
  else
    ng "184o: the script needs more than bash/git/awk/coreutils on PATH (or the strip harness broke) —$s184e_o_miss (#716)"
  fi
fi

# §184p (BLOCK SHAPE — FENCE ESCALATION PAST AN INDENTED PAYLOAD FENCE; born
# RED): payload carrying a 3-backtick run indented 2 spaces (CommonMark closes
# a 3-fence at up to 3 spaces of indentation) forces an opening fence LONGER
# than that run, and the recovery rule still restores the bytes exactly.
if [ -n "$S184E_UNREADY" ]; then
  ng "184p: block shape — fence escalation not exercised: $S184E_UNREADY (fail-closed red, not a skip) (#716)"
else
  s184e_p_ticks='```'
  s184e_p_cmd="printf '%s\n' plainA '  $s184e_p_ticks' plainB"
  s184e_run "$S184E_R1" "$S184E_DIR/p.out" "$S184E_DIR/p.err" evidence "$s184e_p_cmd"; s184e_p_rc=$?
  s184e_p_miss=""
  [ "$s184e_p_rc" = 0 ] || s184e_p_miss="$s184e_p_miss <rc=$s184e_p_rc!=0>"
  s184e_p_fence=$(head -n 1 "$S184E_DIR/p.out")
  printf '%s\n' "$s184e_p_fence" | grep -qE '^`+$' || s184e_p_miss="$s184e_p_miss <opening-line-not-a-fence>"
  [ "${#s184e_p_fence}" -gt 3 ] || s184e_p_miss="$s184e_p_miss <fence-len=${#s184e_p_fence}-not-past-payload-run-3>"
  bash -c "$s184e_p_cmd" > "$S184E_DIR/p.expect"
  s184e_recover "$S184E_DIR/p.out" "$S184E_DIR/p.got"
  cmp -s "$S184E_DIR/p.expect" "$S184E_DIR/p.got" || s184e_p_miss="$s184e_p_miss <recovered-bytes-not-verbatim>"
  if [ -z "$s184e_p_miss" ]; then
    ok "184p: block shape — an indented 3-backtick payload run forces a longer opening fence, bytes recover exactly (#716)"
  else
    ng "184p: fence escalation does not outrun an indented payload fence —$s184e_p_miss (#716)"
  fi
fi
