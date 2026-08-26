# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after 72-evidence.sh (#721). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §185: ghjig_rounds.sh — the rounds instrument, locked as behavior (#721) ----------
# scripts/ghjig_rounds.sh's header is the contract's single code home (Directive
# #637 item 7's reporter); this block is its negative face: NORMAL-BEHAVIOR arms
# that execute the SHIPPED script as an executable file behind a PATH-prepended
# EXECUTABLE `gh` stub (the §183 idiom — a shell-function stub never reaches a
# separate process, and this script reaches gh through a CHILD process anyway).
# The child is the real scripts/ghjig_judged_list.sh: only gh is stubbed, so
# every rounds figure below is derived through the single code home, not
# pre-answered by the harness.
#
# The behavior these arms lock:
#   * `ghjig_rounds.sh <pr> [<pr>…]` — one `pr=<N> rounds=<K>` line per PR in
#     ARGUMENT order, then one `trend: <tok> …` line with one token per
#     reported PR in the same order.
#   * derivation — rounds = the child's `next=` value minus 1, so a history
#     whose canonical rounds are {1,3} (a DELETED round-2 comment) reports 3,
#     not the fact-line count 2; a lookalike-only history reports 0.
#   * anomaly channel — when the child's fact-line count and next−1 disagree,
#     an informational `anomaly:` line goes to STDERR only: the stdout grammar
#     and the exit code are untouched, and a contiguous history is silent.
#   * per-PR failure is REPORTED, never fatal (fail-open reporter) — a child
#     exit 3 (duplicate canonical round) reads `rounds=ambiguous(duplicate)`, a
#     child failure reads `rounds=error(rc=<rc>)`, later PRs in the same
#     invocation still report, the instrument still exits 0, and the trend
#     token for such an entry is `?` (never silently dropped).
#   * `--recent <M>` — the window is MERGE-ORDERED, which the listing API is
#     not: membership and order both come from `mergedAt` (over-fetch, sort
#     desc, cut to M, emit oldest→newest), resolved via
#     `gh pr list --state merged --limit <over-fetch> --json number,mergedAt`.
#   * single code home — the shipped script carries NO header/marker literal of
#     its own: the canonicity test lives only in the child.
#   * usage — no arguments is a usage error: exit 1, the usage text on stderr,
#     nothing on stdout.
# Exit codes pinned: 0 whenever the sweep ran (per-PR failures are reported) ·
# 1 usage error.
#
# Fail-closed harness discipline: an absent/non-executable script or child, a
# missing jq, or a fixture that the CHILD does not read as intended reds EVERY
# arm below as ng — never a skip, never a harness error. The only file-content
# comparison in this block is §185i's code-vs-code literal-absence extraction
# (proved on the child, which does carry the literals); no .md phrase-pinning
# anywhere (Directive #637 L3).

S185R_SCRIPT="$SHELL_ROOT/scripts/ghjig_rounds.sh"
S185R_CHILD="$SHELL_ROOT/scripts/ghjig_judged_list.sh"
S185R_DIR="$TMP/s185r"
S185R_FX="$S185R_DIR/fx"
S185R_LOG="$S185R_DIR/gh.log"
mkdir -p "$S185R_DIR/bin" "$S185R_FX"
: > "$S185R_LOG"

# Executable PATH `gh` stub. Dispatches on the sub-command AND its argument:
# `pr view <N> --json comments …` serves that PR's fixture (or fails with the
# rc a `pr_<N>.rc` control file names — the per-PR-failure arm's lever), and
# `pr list --state merged …` serves the merged-window fixture the caller
# selected. Any -q/--jq filter is applied through real jq, so WHATEVER filter
# the child passes is honored rather than pre-answered.
cat > "$S185R_DIR/bin/gh" <<'S185R_GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${S185R_GH_LOG:?}"
q=""; prev=""
for a in "$@"; do
  case "$prev" in -q|--jq) q="$a";; esac
  prev="$a"
done
case "$1 $2" in
  "pr view")
    pr="$3"
    if [ -f "${S185R_GH_FXDIR:?}/pr_$pr.rc" ]; then
      printf 'gh: simulated API failure for PR #%s\n' "$pr" >&2
      exit "$(cat "${S185R_GH_FXDIR:?}/pr_$pr.rc")"
    fi
    if [ ! -f "${S185R_GH_FXDIR:?}/pr_$pr.json" ]; then
      printf 'gh: no comment fixture for PR #%s\n' "$pr" >&2
      exit 1
    fi
    if [ -n "$q" ]; then jq -r "$q" < "${S185R_GH_FXDIR:?}/pr_$pr.json"
    else cat "${S185R_GH_FXDIR:?}/pr_$pr.json"; fi
    ;;
  "pr list")
    if [ -z "${S185R_GH_LIST:-}" ] || [ ! -f "${S185R_GH_LIST:-}" ]; then
      printf 'gh: no merged-window fixture selected\n' >&2
      exit 1
    fi
    if [ -n "$q" ]; then jq -r "$q" < "$S185R_GH_LIST"; else cat "$S185R_GH_LIST"; fi
    ;;
esac
exit 0
S185R_GH_STUB
chmod +x "$S185R_DIR/bin/gh"

# s185r_canon_fx <pr> <highest-round> — a trusted comment set whose canonical
# rounds are exactly 1..<highest-round> (contiguous), in the shape the child
# recognizes: header first line, marker last content line, rounds agreeing.
s185r_canon_fx() {
  jq -n --argjson k "$2" '{comments: [range(1; $k + 1) |
    {authorAssociation: "OWNER",
     body: ("## Finding triage (round \(.))\n\n- F: upheld\n\n<!-- finding-judge: round=\(.) head=abc000\(.) -->")}]}' \
    > "$S185R_FX/pr_$1.json" 2>/dev/null
}
s185r_canon_fx 42 3   # the sweep's reference PR: canonical rounds 1..3
s185r_canon_fx 51 1
s185r_canon_fx 52 2
s185r_canon_fx 53 3
s185r_canon_fx 54 4

# pr 43 — LOOKALIKES ONLY: a header mid-prose, and a header+marker comment whose
# marker is not the last content line. Neither is canonical, and neither is one
# of the child's two stderr anomaly classes, so this history is silent and its
# derived rounds are 0.
cat > "$S185R_FX/pr_43.json" <<'S185R_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"prose that mentions ## Finding triage (round 5) mid-line\n\nmore prose"},
{"authorAssociation":"MEMBER","body":"## Finding triage (round 7)\n\n- body\n\n<!-- finding-judge: round=7 head=eee5555 -->\n\ntrailing content AFTER the marker"}
]}
S185R_JSON

# pr 44 — THE GAP: canonical rounds 1 and 3, the round-2 comment DELETED. The
# child prints two facts and next=4, so next−1 is 3 while the fact count is 2.
cat > "$S185R_FX/pr_44.json" <<'S185R_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"## Finding triage (round 1)\n\n- F1: upheld\n\n<!-- finding-judge: round=1 head=abc0001 -->"},
{"authorAssociation":"MEMBER","body":"## Finding triage (round 3)\n\n- F3: upheld\n\n<!-- finding-judge: round=3 head=abc0003 -->"}
]}
S185R_JSON

# pr 45 — TWO canonical comments claiming round 2: the child refuses with exit 3.
cat > "$S185R_FX/pr_45.json" <<'S185R_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"## Finding triage (round 2)\n\n- A\n\n<!-- finding-judge: round=2 head=abc0002 -->"},
{"authorAssociation":"MEMBER","body":"## Finding triage (round 2)\n\n- B\n\n<!-- finding-judge: round=2 head=def0002 -->"}
]}
S185R_JSON

# pr 46 — the read itself fails (gh exits 1), so the child's derivation fails
# with rc 1: the per-PR failure lever.
printf '1\n' > "$S185R_FX/pr_46.rc"

# Merged-window fixtures, in the createdAt-DESCENDING order the listing API
# returns. FX-ORD: 52 is listed FIRST but merged EARLIEST, so merge order
# (52, 51, 53) is neither the listing order (52, 53, 51) nor its reverse
# (51, 53, 52) — the three candidate orders yield three different trends.
cat > "$S185R_FX/list_ord.json" <<'S185R_JSON'
[
{"number":52,"mergedAt":"2026-08-01T00:00:00Z"},
{"number":53,"mergedAt":"2026-08-20T00:00:00Z"},
{"number":51,"mergedAt":"2026-08-10T00:00:00Z"}
]
S185R_JSON
# FX-WIN: 54 is the #675 shape — created earliest (so listed LAST, below three
# PRs that merged before it) yet merged latest. A `--recent 2` window decided by
# mergedAt holds {54, 53}; one decided by listing position would hold {51, 52}.
cat > "$S185R_FX/list_win.json" <<'S185R_JSON'
[
{"number":51,"mergedAt":"2026-08-05T00:00:00Z"},
{"number":52,"mergedAt":"2026-08-06T00:00:00Z"},
{"number":53,"mergedAt":"2026-08-07T00:00:00Z"},
{"number":54,"mergedAt":"2026-08-30T00:00:00Z"}
]
S185R_JSON

# s185r_run <list-fixture|-> <stderr-file> <argv…> — invoke the script under
# test as an executable FILE behind the stub; stdout on the wire, stderr split
# off (the anomaly channel is a stderr contract).
s185r_run() {
  s185r_run_list="$1"; s185r_run_err="$2"; shift 2
  [ "$s185r_run_list" = "-" ] && s185r_run_list=""
  : > "$S185R_LOG"
  S185R_GH_LOG="$S185R_LOG" S185R_GH_FXDIR="$S185R_FX" S185R_GH_LIST="$s185r_run_list" \
  PATH="$S185R_DIR/bin:$PATH" "$S185R_SCRIPT" "$@" 2>"$s185r_run_err"
}
# s185r_child <pr> — the same fixture read by the CHILD code home directly
# (readiness only): what the instrument must derive from.
s185r_child() {
  S185R_GH_LOG="$S185R_LOG" S185R_GH_FXDIR="$S185R_FX" S185R_GH_LIST="" \
  PATH="$S185R_DIR/bin:$PATH" "$S185R_CHILD" rounds "$1" 2>/dev/null
}
# s185r_flat <text> — newline-joined-with-| rendering for a red arm's message.
s185r_flat() { printf '%s' "$1" | tr '\n' '|'; }
# s185r_anom <stderr-file> — how many informational anomaly lines were raised.
s185r_anom() { grep -c '^anomaly:' "$1" 2>/dev/null; }
# s185r_lits <file> — the two judged-list shape literals a code file carries.
# Structural: the concrete marker token and the concrete header text, counted
# in the file's bytes (code or comment alike — the single-code-home invariant
# admits neither).
s185r_lits() {
  s185r_lits_a=$(grep -cF 'finding-judge:' "$1" 2>/dev/null)
  s185r_lits_b=$(grep -cF '## Finding triage' "$1" 2>/dev/null)
  printf '%s\n' "$(( ${s185r_lits_a:-0} + ${s185r_lits_b:-0} ))"
}

# Fail-closed readiness — consumed by every arm's guard branch. Fixture
# integrity is part of readiness twice over: the comment SETS are counted, and
# the four load-bearing histories are read by the CHILD, so an arm that reds
# below is reporting on the instrument and not on a mis-built fixture.
S185R_UNREADY=""
[ -x "$S185R_SCRIPT" ] || S185R_UNREADY="scripts/ghjig_rounds.sh absent or not executable"
[ -x "$S185R_CHILD" ] || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }scripts/ghjig_judged_list.sh (the child code home) absent or not executable"
command -v jq >/dev/null 2>&1 || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }jq unavailable (fixture build + the stub's -q passthrough need it)"

s185r_rd_n=0
for s185r_rd_spec in 42:3 51:1 52:2 53:3 54:4 43:2 44:2 45:2; do
  s185r_rd_pr="${s185r_rd_spec%%:*}"; s185r_rd_k="${s185r_rd_spec##*:}"
  s185r_rd_cnt=$(jq '.comments | length' "$S185R_FX/pr_$s185r_rd_pr.json" 2>/dev/null)
  [ "$s185r_rd_cnt" = "$s185r_rd_k" ] \
    || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }pr_$s185r_rd_pr fixture holds ${s185r_rd_cnt:-none} comments (want $s185r_rd_k)"
  s185r_rd_n=$((s185r_rd_n + 1))
done
[ "$s185r_rd_n" = 8 ] || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }only $s185r_rd_n/8 comment fixtures were checked"
[ "$(jq 'length' "$S185R_FX/list_ord.json" 2>/dev/null)" = 3 ] \
  || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the merge-order window fixture does not hold 3 entries"
[ "$(jq 'length' "$S185R_FX/list_win.json" 2>/dev/null)" = 4 ] \
  || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the window-membership fixture does not hold 4 entries"
[ -f "$S185R_FX/pr_46.rc" ] \
  || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the pr-46 failure lever is missing"

if [ -z "$S185R_UNREADY" ]; then
  s185r_rd_42=$(s185r_child 42)
  s185r_rd_43=$(s185r_child 43)
  s185r_rd_44=$(s185r_child 44)
  s185r_child 45 >/dev/null; s185r_rd_rc45=$?
  s185r_child 46 >/dev/null; s185r_rd_rc46=$?
  printf '%s\n' "$s185r_rd_42" | grep -qx 'next=4' \
    || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the child does not derive next=4 on pr 42 (rounds 1..3)"
  printf '%s\n' "$s185r_rd_43" | grep -qx 'next=1' \
    || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the child does not derive next=1 on the lookalike-only pr 43"
  printf '%s\n' "$s185r_rd_44" | grep -qx 'next=4' \
    || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the child does not derive next=4 on the gapped pr 44"
  [ "$(printf '%s\n' "$s185r_rd_44" | grep -c '^round=')" = 2 ] \
    || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the gapped pr 44 does not yield exactly 2 fact lines"
  [ "$s185r_rd_rc45" = 3 ] \
    || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the duplicate history on pr 45 does not exit 3 in the child (rc=$s185r_rd_rc45)"
  [ "$s185r_rd_rc46" = 1 ] \
    || S185R_UNREADY="${S185R_UNREADY:+$S185R_UNREADY; }the pr-46 read failure does not exit 1 in the child (rc=$s185r_rd_rc46)"
fi

# §185a (READINESS — FAIL-CLOSED GUARD, born GREEN): the instrument and its
# child code home are executable, jq is present, every fixture holds the
# comment set it claims, and the child reads the four load-bearing histories as
# next=4 / next=1 / next=4-over-2-facts / exit 3 / exit 1. When this arm reds,
# every arm below reds with the same reason — a loud red, never a skip.
if [ -n "$S185R_UNREADY" ]; then
  ng "185a: readiness — rounds-instrument harness not ready: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  ok "185a: readiness — instrument + child executable; fixtures built and confirmed through the child (contiguous, lookalike-only, gapped, duplicate, unreadable) (#721)"
fi

# §185b (REPORT — CANONICAL 1..N YIELDS rounds=N, AC1): a PR whose trusted
# comments carry canonical judged-list comments for rounds 1..3 reports
# `pr=42 rounds=3` and a one-token trend `trend: 3` — nothing else on stdout —
# and the sweep exits 0.
if [ -n "$S185R_UNREADY" ]; then
  ng "185b: report — canonical 1..N round count not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_b_out=$(s185r_run - "$S185R_DIR/err_b" 42); s185r_b_rc=$?
  s185r_b_want=$(printf '%s\n' 'pr=42 rounds=3' 'trend: 3')
  s185r_b_miss=""
  [ "$s185r_b_rc" = 0 ] || s185r_b_miss="$s185r_b_miss <rc=$s185r_b_rc!=0>"
  [ "$s185r_b_out" = "$s185r_b_want" ] || s185r_b_miss="$s185r_b_miss <stdout=[$(s185r_flat "$s185r_b_out")]!=[$(s185r_flat "$s185r_b_want")]>"
  if [ -z "$s185r_b_miss" ]; then
    ok "185b: report — canonical rounds 1..3 on one PR print pr=42 rounds=3 then trend: 3, exit 0 (#721)"
  else
    ng "185b: the canonical 1..N history is not reported as rounds=N —$s185r_b_miss (#721)"
  fi
fi

# §185c (REPORT — A LOOKALIKE-ONLY HISTORY IS rounds=0, AC1's other side): a PR
# whose trusted comments are all non-canonical (a header mid-prose; a marker
# that is not the last content line) reports `pr=43 rounds=0` and `trend: 0` —
# zero is REPORTED, never a dropped line — and the sweep exits 0.
if [ -n "$S185R_UNREADY" ]; then
  ng "185c: report — lookalike-only rounds=0 not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_c_out=$(s185r_run - "$S185R_DIR/err_c" 43); s185r_c_rc=$?
  s185r_c_want=$(printf '%s\n' 'pr=43 rounds=0' 'trend: 0')
  s185r_c_miss=""
  [ "$s185r_c_rc" = 0 ] || s185r_c_miss="$s185r_c_miss <rc=$s185r_c_rc!=0>"
  [ "$s185r_c_out" = "$s185r_c_want" ] || s185r_c_miss="$s185r_c_miss <stdout=[$(s185r_flat "$s185r_c_out")]!=[$(s185r_flat "$s185r_c_want")]>"
  if [ -z "$s185r_c_miss" ]; then
    ok "185c: report — a lookalike-only history reports pr=43 rounds=0 and trend: 0, exit 0 (#721)"
  else
    ng "185c: the lookalike-only history is not reported as rounds=0 —$s185r_c_miss (#721)"
  fi
fi

# §185d (DERIVATION — next−1, NOT THE FACT COUNT, plus the anomaly note): a
# history whose canonical rounds are {1,3} (the round-2 comment deleted) reports
# rounds=3 — the ordinal of the last judged round — where counting the child's
# two fact lines would report 2. The count/next−1 disagreement raises exactly
# one informational `anomaly:` line on STDERR naming the PR; stdout carries the
# report grammar only and the exit code stays 0. Negative control in the same
# arm: the contiguous history (pr 42) raises NO anomaly line, so the channel
# reports a real disagreement rather than firing on every sweep.
if [ -n "$S185R_UNREADY" ]; then
  ng "185d: derivation — the gapped-history next−1 derivation not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_d_out=$(s185r_run - "$S185R_DIR/err_d" 44); s185r_d_rc=$?
  s185r_d_want=$(printf '%s\n' 'pr=44 rounds=3' 'trend: 3')
  s185r_d_an=$(s185r_anom "$S185R_DIR/err_d")
  s185r_run - "$S185R_DIR/err_d42" 42 >/dev/null
  s185r_d_an42=$(s185r_anom "$S185R_DIR/err_d42")
  s185r_d_miss=""
  [ "$s185r_d_rc" = 0 ] || s185r_d_miss="$s185r_d_miss <rc=$s185r_d_rc!=0>"
  [ "$s185r_d_out" = "$s185r_d_want" ] || s185r_d_miss="$s185r_d_miss <stdout=[$(s185r_flat "$s185r_d_out")]!=[$(s185r_flat "$s185r_d_want")]>"
  [ "$s185r_d_an" = 1 ] || s185r_d_miss="$s185r_d_miss <gap-anomaly-lines=$s185r_d_an!=1>"
  grep '^anomaly:' "$S185R_DIR/err_d" 2>/dev/null | grep -qF '44' \
    || s185r_d_miss="$s185r_d_miss <anomaly-does-not-name-pr-44>"
  [ "$s185r_d_an42" = 0 ] || s185r_d_miss="$s185r_d_miss <contiguous-history-raised-anomaly=$s185r_d_an42>"
  if [ -z "$s185r_d_miss" ]; then
    ok "185d: derivation — canonical rounds {1,3} report rounds=3 (next−1, not the 2 fact lines) with one stderr anomaly naming the PR; a contiguous history is silent (#721)"
  else
    ng "185d: the round count is not next−1, or the anomaly channel mis-fired —$s185r_d_miss (#721)"
  fi
fi

# §185e (FAIL-OPEN — AN AMBIGUOUS HISTORY IS REPORTED, THE SWEEP CONTINUES,
# AC2): a PR with two canonical comments claiming the same round reads
# `pr=45 rounds=ambiguous(duplicate)`; the next PR of the SAME invocation still
# reports its own count; the trend carries `?` for the ambiguous entry (never a
# dropped token); the instrument exits 0.
if [ -n "$S185R_UNREADY" ]; then
  ng "185e: fail-open — ambiguous-history reporting not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_e_out=$(s185r_run - "$S185R_DIR/err_e" 45 42); s185r_e_rc=$?
  s185r_e_want=$(printf '%s\n' 'pr=45 rounds=ambiguous(duplicate)' 'pr=42 rounds=3' 'trend: ? 3')
  s185r_e_miss=""
  [ "$s185r_e_rc" = 0 ] || s185r_e_miss="$s185r_e_miss <rc=$s185r_e_rc!=0>"
  [ "$s185r_e_out" = "$s185r_e_want" ] || s185r_e_miss="$s185r_e_miss <stdout=[$(s185r_flat "$s185r_e_out")]!=[$(s185r_flat "$s185r_e_want")]>"
  if [ -z "$s185r_e_miss" ]; then
    ok "185e: fail-open — a duplicate canonical round reads rounds=ambiguous(duplicate) with trend token ?, the next PR still reports, exit 0 (#721)"
  else
    ng "185e: an ambiguous history aborted the sweep or was not reported in place —$s185r_e_miss (#721)"
  fi
fi

# §185f (FAIL-OPEN — A FAILED DERIVATION IS REPORTED WITH ITS rc, AC2): when the
# read for one PR fails (gh exits 1, so the child exits 1), that PR reads
# `pr=46 rounds=error(rc=1)`, the later PR of the same invocation reports
# normally, the trend carries `?` for the errored entry, and the instrument
# exits 0 — a reporter never turns one PR's failure into the sweep's.
if [ -n "$S185R_UNREADY" ]; then
  ng "185f: fail-open — per-PR failure reporting not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_f_out=$(s185r_run - "$S185R_DIR/err_f" 46 42); s185r_f_rc=$?
  s185r_f_want=$(printf '%s\n' 'pr=46 rounds=error(rc=1)' 'pr=42 rounds=3' 'trend: ? 3')
  s185r_f_miss=""
  [ "$s185r_f_rc" = 0 ] || s185r_f_miss="$s185r_f_miss <rc=$s185r_f_rc!=0>"
  [ "$s185r_f_out" = "$s185r_f_want" ] || s185r_f_miss="$s185r_f_miss <stdout=[$(s185r_flat "$s185r_f_out")]!=[$(s185r_flat "$s185r_f_want")]>"
  if [ -z "$s185r_f_miss" ]; then
    ok "185f: fail-open — an unreadable PR reads rounds=error(rc=1) with trend token ?, the later PR reports normally, exit 0 (#721)"
  else
    ng "185f: a per-PR derivation failure was not reported in place (or it aborted the sweep) —$s185r_f_miss (#721)"
  fi
fi

# §185g (--recent — THE ORDER IS MERGE ORDER, AC3): given a listing whose
# createdAt-descending order carries a mergedAt inversion (52 listed first but
# merged earliest), the report and the trend follow mergedAt oldest→newest
# (52, 51, 53 → trend 2 1 3) — neither the listing order (2 3 1) nor its
# reverse (1 3 2). The window is resolved by exactly one
# `gh pr list --state merged … --json number,mergedAt` call.
if [ -n "$S185R_UNREADY" ]; then
  ng "185g: --recent — merge-ordered emission not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_g_out=$(s185r_run "$S185R_FX/list_ord.json" "$S185R_DIR/err_g" --recent 3); s185r_g_rc=$?
  s185r_g_want=$(printf '%s\n' 'pr=52 rounds=2' 'pr=51 rounds=1' 'pr=53 rounds=3' 'trend: 2 1 3')
  s185r_g_lists=$(grep -c '^pr list ' "$S185R_LOG" 2>/dev/null)
  s185r_g_miss=""
  [ "$s185r_g_rc" = 0 ] || s185r_g_miss="$s185r_g_miss <rc=$s185r_g_rc!=0>"
  [ "$s185r_g_out" = "$s185r_g_want" ] || s185r_g_miss="$s185r_g_miss <stdout=[$(s185r_flat "$s185r_g_out")]!=[$(s185r_flat "$s185r_g_want")]>"
  [ "$s185r_g_lists" = 1 ] || s185r_g_miss="$s185r_g_miss <pr-list-calls=$s185r_g_lists!=1>"
  grep '^pr list ' "$S185R_LOG" 2>/dev/null | grep -qF -- '--state merged' \
    || s185r_g_miss="$s185r_g_miss <resolution-not-state-merged>"
  grep '^pr list ' "$S185R_LOG" 2>/dev/null | grep -qF -- '--json number,mergedAt' \
    || s185r_g_miss="$s185r_g_miss <resolution-does-not-fetch-mergedAt>"
  if [ -z "$s185r_g_miss" ]; then
    ok "185g: --recent — the window emits oldest→newest by mergedAt (52 51 53, trend 2 1 3) through one --state merged --json number,mergedAt resolution (#721)"
  else
    ng "185g: the --recent window followed listing order instead of merge order (or resolved it another way) —$s185r_g_miss (#721)"
  fi
fi

# §185h (--recent — MEMBERSHIP IS mergedAt, NOT LISTING POSITION, AC3): a PR
# created earliest and merged latest sits LAST in the createdAt-descending
# listing, below three PRs that merged before it; with `--recent 2` it is IN the
# window (53, 54 → trend 3 4), where a listing-position window would report the
# two topmost entries (51, 52). The listing is over-fetched: the resolution's
# --limit exceeds M, so the window cannot be a prefix of the listing.
if [ -n "$S185R_UNREADY" ]; then
  ng "185h: --recent — mergedAt window membership not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_h_out=$(s185r_run "$S185R_FX/list_win.json" "$S185R_DIR/err_h" --recent 2); s185r_h_rc=$?
  s185r_h_want=$(printf '%s\n' 'pr=53 rounds=3' 'pr=54 rounds=4' 'trend: 3 4')
  s185r_h_lim=$(grep '^pr list ' "$S185R_LOG" 2>/dev/null | head -n 1 \
    | awk '{for (i = 1; i < NF; i++) if ($i == "--limit") print $(i + 1)}' | head -n 1)
  s185r_h_miss=""
  [ "$s185r_h_rc" = 0 ] || s185r_h_miss="$s185r_h_miss <rc=$s185r_h_rc!=0>"
  [ "$s185r_h_out" = "$s185r_h_want" ] || s185r_h_miss="$s185r_h_miss <stdout=[$(s185r_flat "$s185r_h_out")]!=[$(s185r_flat "$s185r_h_want")]>"
  case "${s185r_h_lim:-x}" in
    ''|*[!0-9]*) s185r_h_miss="$s185r_h_miss <resolution-limit-unparsed:${s185r_h_lim:-none}>" ;;
    *) [ "$s185r_h_lim" -gt 2 ] || s185r_h_miss="$s185r_h_miss <no-over-fetch:limit=$s185r_h_lim<=M=2>" ;;
  esac
  if [ -z "$s185r_h_miss" ]; then
    ok "185h: --recent — the late-merged/early-created PR is in the --recent 2 window (53, 54; trend 3 4) and the listing is over-fetched past M (limit=$s185r_h_lim) (#721)"
  else
    ng "185h: --recent membership came from listing position rather than mergedAt —$s185r_h_miss (#721)"
  fi
fi

# §185i (SINGLE CODE HOME — NO SHAPE LITERAL IN THE INSTRUMENT, born GREEN): the
# instrument carries neither the concrete marker token `finding-judge:` nor the
# concrete header text `## Finding triage` anywhere in its bytes — the canonicity
# test has ONE code home and this script consumes its output contract instead of
# re-testing the shape. Control: the same extraction over the child code home
# counts >0, so a broken extractor cannot green this arm.
if [ -n "$S185R_UNREADY" ]; then
  ng "185i: single code home — shape-literal absence not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_i_self=$(s185r_lits "$S185R_SCRIPT")
  s185r_i_child=$(s185r_lits "$S185R_CHILD")
  s185r_i_miss=""
  [ "$s185r_i_child" -gt 0 ] 2>/dev/null || s185r_i_miss="$s185r_i_miss <extractor-control-failed:child-literals=$s185r_i_child>"
  [ "$s185r_i_self" = 0 ] || s185r_i_miss="$s185r_i_miss <instrument-carries-$s185r_i_self-shape-literals>"
  if [ -z "$s185r_i_miss" ]; then
    ok "185i: single code home — the instrument carries no marker/header shape literal (control: the child carries $s185r_i_child) (#721)"
  else
    ng "185i: a second home for the judged-list shape literals appeared —$s185r_i_miss (#721)"
  fi
fi

# §185j (USAGE — NO INPUT SET IS A USAGE ERROR, born GREEN): invoked with no
# arguments the instrument exits 1 and prints its usage text on STDERR, with
# nothing on stdout — an empty input set is never reported as an empty sweep.
if [ -n "$S185R_UNREADY" ]; then
  ng "185j: usage — the no-argument usage error not exercised: $S185R_UNREADY (fail-closed red, not a skip) (#721)"
else
  s185r_j_out=$(S185R_GH_LOG="$S185R_LOG" S185R_GH_FXDIR="$S185R_FX" S185R_GH_LIST="" \
    PATH="$S185R_DIR/bin:$PATH" "$S185R_SCRIPT" 2>"$S185R_DIR/err_j"); s185r_j_rc=$?
  s185r_j_miss=""
  [ "$s185r_j_rc" = 1 ] || s185r_j_miss="$s185r_j_miss <rc=$s185r_j_rc!=1>"
  [ -z "$s185r_j_out" ] || s185r_j_miss="$s185r_j_miss <stdout-not-empty:[$(s185r_flat "$s185r_j_out")]>"
  grep -q '^usage: ghjig_rounds.sh <pr>' "$S185R_DIR/err_j" \
    || s185r_j_miss="$s185r_j_miss <usage-line-missing-on-stderr>"
  grep -qF -- '--recent' "$S185R_DIR/err_j" \
    || s185r_j_miss="$s185r_j_miss <usage-omits-the---recent-route>"
  if [ -z "$s185r_j_miss" ]; then
    ok "185j: usage — no arguments exits 1 with both input routes named on stderr and nothing on stdout (#721)"
  else
    ng "185j: the no-argument invocation is not a stderr usage error —$s185r_j_miss (#721)"
  fi
fi
