#!/usr/bin/env bash
# scripts/ghjig_evidence.sh — the render/pointer helper: Directive #637 L2's
# instrument, the sanctioned authoring path for descriptive facts in durable
# bodies (#716). This header is the contract's single code home (the SPEC §4.13
# pattern); the smoke suite's §184 behavior arms are its negative face
# (scripts/test/smoke.d/72-evidence.sh). The helper GATES NOTHING: it is the
# positive face only — obligation to use it is #637 item 6's carrier rules,
# not this script's. Pure-local: no network access anywhere.
#
# Modes:
#   evidence '<command>'       run the command string VERBATIM via `bash -c`
#                              (no wrapper, no injected options — the printed
#                              command IS the executed command), in its own
#                              process group, stdout captured to a temp file
#                              (never a pipe), under the timeout below. On
#                              rc=0 emit ONE fenced evidence block to stdout:
#                              a `$ <command>` line, the command's stdout
#                              bytes verbatim, then the pin line. On non-zero
#                              rc or timeout: exit 2, NOTHING on stdout, the
#                              cause named on stderr. The child's stderr
#                              passes through to this script's stderr and is
#                              OUTSIDE the block's guarantee. A command
#                              containing a newline is refused (exit 1): the
#                              block's first line must re-execute as the
#                              whole command.
#   quote <path> <span-file|-> verify the span's bytes resolve VERBATIM in
#                              the attributed repo-relative path, then emit
#                              the quotation block (fenced span, a
#                              `quoted from <path>:<line>` attribution, the
#                              pin line). Resolution source keys on
#                              TRACKED-ness, not per-file cleanliness: a
#                              TRACKED path resolves via the HEAD blob
#                              (`git show`) even when its worktree copy
#                              diverged, so the attestation binds to the pin
#                              and a symlink entry yields its link text,
#                              never its target's content; an UNTRACKED path
#                              falls back to the worktree read only after a
#                              symlink-leaf refusal and a physical-directory
#                              containment check. The (dirty) pin mark is
#                              tree-level, not per-file.
#                              A miss exits 3 naming the path and the miss on
#                              stderr and emits NOTHING — there is no
#                              emit-anyway form.
#
# Span semantics (quote): matching is fixed-string over bytes — no
# normalization (the normalizing tier is scripts/lint_citations.sh's advisory
# business, not a fail-closed emitter's). The span's TRAILING NEWLINES are not
# significant. A NUL byte in the span or in the resolution source is refused
# (exit 1): the channels shells offer strip NUL, so a NUL-bearing comparison
# could false-hit. The attributed line number is the count of newlines in the
# source preceding the match, plus one. A matcher execution failure (awk exec
# error, E2BIG) is fail-closed: exit non-zero, reported, never treated as a
# hit or a silent miss.
#
# Block shape: the fence length is max(3, longest backtick run opening a
# payload line at up to three spaces of indentation, plus one) — CommonMark
# closes an N-fence with >=N backticks indented up to three spaces, so payload
# can never terminate the block early; escalation is unbounded by design.
# When the evidence output lacks a trailing newline the emitter adds one and
# inserts a `\ no-eol` marker line before the pin line; the recovery rule is:
# the output bytes are the block bytes between the command line and the
# pin/marker line, minus the injected final newline when the marker is
# present.
#
# Pin: `pin: <head-sha> <YYYY-MM-DD>Z` — the repo HEAD at emission and the
# UTC date; `(dirty)` after the sha marks an unclean tree. Byte-identical
# re-execution (#637's discrimination signal) is claimed only for a clean pin.
# The guarantee is EMISSION-TIME truth only: later hand-editing of an emitted
# block is outside this script's guarantee.
#
# Timeout (evidence): default 60s; GHJIG_EVIDENCE_TIMEOUT overrides, digits
# only, capped at 600. On expiry the watchdog signals the child's PROCESS
# GROUP (kill -TERM -- -pgid), so pipeline members do not survive the leader.
#
# Exit codes: 0 ok · 1 usage/environment/refusal (NUL span, newline command,
# symlink or containment refusal, bad timeout override) · 2 evidence command
# failed or timed out (child rc named on stderr) · 3 quotation does not
# resolve. Every failure path emits nothing on stdout.
set -euo pipefail

PROG="ghjig_evidence"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit "${2:-1}"; }

usage() {
  cat >&2 <<'EOF'
usage: ghjig_evidence.sh <mode> <args...>
  evidence '<command>'        run the command; emit ONE fenced block: $ <command> / stdout bytes / pin
  quote <path> <span-file|->  verify the span resolves verbatim at <path>; emit the quotation block
exit codes: 0 ok / 1 usage-environment-refusal / 2 evidence failed or timed out / 3 quote does not resolve
EOF
  exit 1
}

command -v git >/dev/null 2>&1 || die "git not found"

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ghjig_evidence.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT

# pin_line — `pin: <head-sha>[ (dirty)] <YYYY-MM-DD>Z` for the CALLING repo
# (resolved at cwd). The (dirty) mark is tree-level: any uncommitted change
# marks the pin, whichever file it touches.
pin_line() {
  local sha dirty=""
  sha=$(git rev-parse HEAD 2>/dev/null) || return 1
  [ -z "$(git status --porcelain 2>/dev/null)" ] || dirty=" (dirty)"
  printf 'pin: %s%s %sZ\n' "$sha" "$dirty" "$(date -u +%Y-%m-%d)"
}

# fence_for <payload-file>… — max(3, longest backtick run opening a payload
# line at up to three spaces of indentation, plus one): CommonMark closes an
# N-fence with >=N backticks indented up to three spaces, so the emitted
# fence must outrun every such payload run.
fence_for() {
  local n
  n=$(cat -- "$@" | awk '
    { line = $0
      sub(/^ ? ? ?/, "", line)
      if (match(line, /^`+/) && RLENGTH > max) max = RLENGTH }
    END { print max + 0 }')
  n=$((n + 1))
  [ "$n" -ge 3 ] || n=3
  printf '%*s' "$n" '' | tr ' ' '\140'
}

run_evidence() {
  [ "$#" -eq 1 ] || usage
  local cmd="$1" t=60 child wd rc=0 outf flag pin fence noeol=""
  case "$cmd" in
    *$'\n'*) die "command contains a newline — the block's \$-line must re-execute as the whole command; refused" 1 ;;
  esac
  if [ -n "${GHJIG_EVIDENCE_TIMEOUT+x}" ]; then
    case "$GHJIG_EVIDENCE_TIMEOUT" in
      ''|*[!0-9]*) die "bad GHJIG_EVIDENCE_TIMEOUT '${GHJIG_EVIDENCE_TIMEOUT}' — digits only, capped at 600" 1 ;;
    esac
    t="$GHJIG_EVIDENCE_TIMEOUT"
    [ "$t" -le 600 ] || t=600
  fi
  outf="$TMPD/out"
  flag="$TMPD/timedout"
  # Own PROCESS GROUP via job control at spawn (`set -m`); stdout captured to
  # a temp FILE (never a pipe); stderr passes through. The watchdog runs in
  # its own group too, so killing it never leaves a stray sleep behind.
  set -m
  bash -c "$cmd" > "$outf" &
  child=$!
  (
    sleep "$t"
    : > "$flag"
    kill -TERM -- "-$child" 2>/dev/null || true
    sleep 5
    kill -KILL -- "-$child" 2>/dev/null || true
  ) &
  wd=$!
  set +m
  wait "$child" || rc=$?
  kill -TERM -- "-$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  if [ -e "$flag" ] && [ "$rc" -ne 0 ]; then
    die "evidence command timed out after ${t}s (child rc=$rc); nothing emitted" 2
  fi
  [ "$rc" -eq 0 ] || die "evidence command failed: child rc=$rc; nothing emitted" 2
  # Emission-time pin: HEAD/tree state AFTER the command ran.
  pin=$(pin_line) || die "cannot resolve repo HEAD for the pin" 1
  if [ -s "$outf" ] && [ -n "$(tail -c 1 "$outf")" ]; then
    noeol=1
  fi
  printf '$ %s\n' "$cmd" > "$TMPD/cmdline"
  fence=$(fence_for "$TMPD/cmdline" "$outf")
  printf '%s\n' "$fence"
  printf '$ %s\n' "$cmd"
  cat -- "$outf"
  [ -z "$noeol" ] || printf '\n\\ no-eol\n'
  printf '%s\n' "$pin"
  printf '%s\n' "$fence"
}

mode="${1:-}"
case "$mode" in
  evidence)
    shift
    run_evidence "$@"
    ;;
  quote)
    die "quote mode not implemented yet (#716 Phase C)" 1
    ;;
  *)
    usage
    ;;
esac
