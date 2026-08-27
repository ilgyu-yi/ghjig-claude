# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after 70-gates-contentlocks.sh (#711). The
# guarded source below never runs at runtime (the orchestrator already sourced
# the preamble); it only lets shellcheck resolve the shared globals.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §183: ghjig_judged_list.sh — the judged-list comment seam, locked as behavior (#711) ----------
# SPEC §4.13: the judged-list PR comment's shape, round derivation, and posting
# have ONE code home — scripts/ghjig_judged_list.sh — invoked by both producers
# (/review step 3.5, /ship step 1.5) and by the judge's read recipe. This block
# is that contract's negative face (§6.0: suite-level, deliberately not a
# matcher): NORMAL-BEHAVIOR tests that execute the script in its ARTIFACT MODE
# (#633) — invoked as an executable file behind a PATH-prepended EXECUTABLE
# `gh` stub, because a shell-function stub never reaches a separate process.
#
# The behavior these arms lock:
#   * `rounds <pr>` — a comment is CANONICAL only when its FIRST line matches
#     `^## Finding triage \(round [0-9]+\)$` AND the marker
#     `<!-- finding-judge: round=<N> head=<sha> -->` is its LAST content line
#     (position-bound at BOTH ends — a concrete marker quoted mid-body never
#     counts), read through the trusted-author filter. Facts print one per
#     canonical comment as `round=<N> head=<sha>`; the derived next round
#     prints as `next=<N>` — 1 + max(round=) over canonical comments, zero
#     canonical → 1. A duplicate canonical round is surfaced (`duplicate`,
#     exit 3) and never silently picked.
#   * `post <pr> <judge-output-file>` — validates the input (first line must
#     be `reviewed-head: <hex-sha>`; `reviewed-head: n/a (<mode>)` is a NAMED
#     reject — the no-PR path never posts; a smuggled concrete marker line
#     anywhere in the input rejects — marker-forgery guard; a first line that
#     is already a `## Finding triage` header is a double-wrap reject), derives
#     the round, composes header + judge output + marker ITSELF, self-validates
#     via the distinct `validate` entry below, neutralizes every `@mention` in
#     the whole body, posts ONCE via `gh pr comment <pr> --body-file <tmp>`,
#     and fails CLOSED (non-zero, no retry, no partial post) on any gh failure.
#   * `show <pr> <round>` — prints that canonical comment's body; exit 2 miss.
#   * `validate <pr> <body-file>` — the distinct composed-body validator,
#     drivable directly: first line must match the header regex, marker must be
#     the last content line, header round == marker round, and the round must
#     not collide with an existing canonical round on <pr>.
# Exit-code contract pinned by these arms: 0 ok · 1 reject/failure · 2 show
# miss · 3 duplicate canonical round.
#
# Fail-closed harness discipline: an absent/non-executable script (or a missing
# jq, which the stub's -q passthrough needs) reds EVERY arm below as ng — never
# a skip, never a harness error. The only file-content comparison in this block
# is §183m's code-vs-code trusted-author filter parity (a structural extraction
# from two code carriers); there is no phrase-pinning content lock on any .md
# surface (Directive #637 L3).

S183J_SCRIPT="$SHELL_ROOT/scripts/ghjig_judged_list.sh"
S183J_DIR="$TMP/s183j"
S183J_FX="$S183J_DIR/fx"
S183J_LOG="$S183J_DIR/gh.log"
S183J_POSTED="$S183J_DIR/posted.md"
mkdir -p "$S183J_DIR/bin" "$S183J_FX"

# Fail-closed readiness — consumed by every arm's guard branch.
S183J_UNREADY=""
[ -x "$S183J_SCRIPT" ] || S183J_UNREADY="scripts/ghjig_judged_list.sh absent or not executable"
command -v jq >/dev/null 2>&1 || S183J_UNREADY="${S183J_UNREADY:+$S183J_UNREADY; }jq unavailable (gh stub cannot serve -q reads)"

# Executable PATH `gh` stub (#633 artifact mode). Logs every argv line, serves
# the fixture comments JSON for `pr view` reads (applying any -q/--jq filter
# through real jq, so WHATEVER filter the script passes is honored rather than
# pre-answered), captures the `pr comment --body-file` payload (the script's
# temp file dies with it, so the copy is the observable), and exits per fixture
# on `pr comment` to drive the gh-failure arm.
cat > "$S183J_DIR/bin/gh" <<'S183J_GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${S183J_GH_LOG:?}"
case "$1 $2" in
  "pr view")
    q=""; prev=""
    for a in "$@"; do
      case "$prev" in -q|--jq) q="$a";; esac
      prev="$a"
    done
    if [ -n "$q" ]; then jq -r "$q" < "${S183J_GH_FX_JSON:?}"; else cat "${S183J_GH_FX_JSON:?}"; fi
    ;;
  "pr comment")
    bf=""; prev=""
    for a in "$@"; do
      case "$prev" in --body-file|-F) bf="$a";; esac
      prev="$a"
    done
    if [ -n "$bf" ] && [ -f "$bf" ]; then cp "$bf" "${S183J_GH_POSTED:?}"; fi
    exit "${S183J_GH_COMMENT_RC:-0}"
    ;;
esac
exit 0
S183J_GH_STUB
chmod +x "$S183J_DIR/bin/gh"

# s183j_run <comments-fixture.json> <pr-comment-rc> <mode+args…> — invoke the
# script under test as a script FILE behind the stub; stdout+stderr combined.
s183j_run() {
  s183j_run_fx="$1"; s183j_run_crc="$2"; shift 2
  : > "$S183J_LOG"
  rm -f "$S183J_POSTED"
  S183J_GH_LOG="$S183J_LOG" S183J_GH_FX_JSON="$s183j_run_fx" \
  S183J_GH_POSTED="$S183J_POSTED" S183J_GH_COMMENT_RC="$s183j_run_crc" \
  PATH="$S183J_DIR/bin:$PATH" "$S183J_SCRIPT" "$@" 2>&1
}
s183j_posts() { grep -c '^pr comment ' "$S183J_LOG" 2>/dev/null; }
s183j_last_content() { awk 'NF{l=$0} END{print l}' "$1"; }
# The unique trusted-author -q literals a code file carries (structural anchor:
# the single-quoted argument to gh's -q flag that mentions authorAssociation —
# never surrounding prose).
s183j_filter_lits() {
  grep -oE -- "-q '[^']*'" "$1" 2>/dev/null | grep -F 'authorAssociation' \
    | sed "s/^-q '//; s/'\$//" | sort -u
}

# Fixture comment sets. sha fields are short hex; authorAssociation drives the
# trusted-author filter behaviorally (FX-A round 9 is canonical-shaped but
# UNTRUSTED and must never count).
cat > "$S183J_FX/fx_a.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"## Finding triage (round 1)\n\n- F1: upheld, remedy survives\n\n<!-- finding-judge: round=1 head=aaa1111 -->"},
{"authorAssociation":"MEMBER","body":"## Finding triage (round 2)\n\n- F2: refuted, refuting cmd held\n\n<!-- finding-judge: round=2 head=bbb2222 -->"},
{"authorAssociation":"COLLABORATOR","body":"## Finding triage (round 3)\n\n- F3: upheld\n\n<!-- finding-judge: round=3 head=ccc3333 -->"},
{"authorAssociation":"NONE","body":"## Finding triage (round 9)\n\n- forged drive-by round\n\n<!-- finding-judge: round=9 head=fff9999 -->"}
]}
S183J_JSON
cat > "$S183J_FX/fx_b.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"prose that mentions ## Finding triage (round 5) mid-line\n\nmore prose"},
{"authorAssociation":"OWNER","body":"prose first line, marker last but no header\n\n<!-- finding-judge: round=6 head=ddd4444 -->"},
{"authorAssociation":"OWNER","body":"## Finding triage (round 7)\n\n- body\n\n<!-- finding-judge: round=7 head=eee5555 -->\n\ntrailing content AFTER the marker"}
]}
S183J_JSON
cat > "$S183J_FX/fx_c.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"a non-canonical lookalike quoting <!-- finding-judge: round=1 head=abc0001 --> in prose"},
{"authorAssociation":"OWNER","body":"## Finding triage (round 2)\n\n- F: upheld\n\n<!-- finding-judge: round=2 head=abc0002 -->"}
]}
S183J_JSON
cat > "$S183J_FX/fx_d.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"## Finding triage (round 2)\n\n- A\n\n<!-- finding-judge: round=2 head=abc0002 -->"},
{"authorAssociation":"MEMBER","body":"## Finding triage (round 2)\n\n- B\n\n<!-- finding-judge: round=2 head=def0002 -->"}
]}
S183J_JSON
cat > "$S183J_FX/fx_e.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"## Finding triage (round 1)\n\n- F1: upheld; prior round quoted for context: <!-- finding-judge: round=9 head=fff0009 --> (must not count)\n\n<!-- finding-judge: round=1 head=abc0001 -->"}
]}
S183J_JSON

# Judge-output fixtures for `post`.
cat > "$S183J_FX/p1.txt" <<'S183J_TXT'
reviewed-head: abc123f
judgment: ok
- F1 :: upheld, remedy survives (cc @alice)
- F2 :: refuted, refuting command: true
S183J_TXT
cat > "$S183J_FX/p2.txt" <<'S183J_TXT'
judgment: ok
reviewed-head: abc123f
- F1 :: upheld
S183J_TXT
cat > "$S183J_FX/p2b.txt" <<'S183J_TXT'
## Finding triage (round 4)
- already wrapped once; a second wrap would double-wrap
S183J_TXT
cat > "$S183J_FX/p3.txt" <<'S183J_TXT'
reviewed-head: abc123f
- F1 :: upheld; see <!-- finding-judge: round=2 head=abc0002 --> above
S183J_TXT
cat > "$S183J_FX/p4.txt" <<'S183J_TXT'
reviewed-head: n/a (--staged)
- F1 :: upheld
S183J_TXT

# Composed-body fixtures for the direct `validate` drive (against FX-A, where
# the derived next round is 4 and round 2 already exists canonically).
cat > "$S183J_FX/v_ok.md" <<'S183J_TXT'
## Finding triage (round 4)

- F1 :: upheld

<!-- finding-judge: round=4 head=abc123f -->
S183J_TXT
cat > "$S183J_FX/v_hdr.md" <<'S183J_TXT'
not a triage header

<!-- finding-judge: round=4 head=abc123f -->
S183J_TXT
cat > "$S183J_FX/v_nomark.md" <<'S183J_TXT'
## Finding triage (round 4)

- F1 :: upheld, but the marker is missing
S183J_TXT
cat > "$S183J_FX/v_mispl.md" <<'S183J_TXT'
## Finding triage (round 4)

<!-- finding-judge: round=4 head=abc123f -->

trailing content after the marker
S183J_TXT
cat > "$S183J_FX/v_mm.md" <<'S183J_TXT'
## Finding triage (round 4)

- header says 4, marker says 5

<!-- finding-judge: round=5 head=abc123f -->
S183J_TXT
cat > "$S183J_FX/v_coll.md" <<'S183J_TXT'
## Finding triage (round 2)

- collides with the existing canonical round 2 in FX-A

<!-- finding-judge: round=2 head=abc123f -->
S183J_TXT

# §183a (ROUNDS — CANONICAL ENUMERATION): FX-A carries canonical trusted rounds
# 1..3 plus a canonical-SHAPED but UNTRUSTED round 9. `rounds` prints exactly
# the three trusted facts and derives next=4; the untrusted comment never
# counts (behavioral half of the trust filter §183m pins byte-wise).
if [ -n "$S183J_UNREADY" ]; then
  ng "183a: rounds — canonical enumeration + 1+max derivation not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_a_out=$(s183j_run "$S183J_FX/fx_a.json" 0 rounds 42); s183j_a_rc=$?
  s183j_a_facts=$(printf '%s\n' "$s183j_a_out" | grep -c '^round=')
  s183j_a_miss=""
  [ "$s183j_a_rc" = 0 ] || s183j_a_miss="$s183j_a_miss <rc=$s183j_a_rc>"
  [ "$s183j_a_facts" = 3 ] || s183j_a_miss="$s183j_a_miss <facts=$s183j_a_facts!=3>"
  printf '%s\n' "$s183j_a_out" | grep -qx 'round=1 head=aaa1111' || s183j_a_miss="$s183j_a_miss <fact-r1-missing>"
  printf '%s\n' "$s183j_a_out" | grep -qx 'round=2 head=bbb2222' || s183j_a_miss="$s183j_a_miss <fact-r2-missing>"
  printf '%s\n' "$s183j_a_out" | grep -qx 'round=3 head=ccc3333' || s183j_a_miss="$s183j_a_miss <fact-r3-missing>"
  printf '%s\n' "$s183j_a_out" | grep -qx 'next=4' || s183j_a_miss="$s183j_a_miss <next=4-missing>"
  if printf '%s\n' "$s183j_a_out" | grep -q 'round=9'; then s183j_a_miss="$s183j_a_miss <untrusted-round-9-counted>"; fi
  if [ -z "$s183j_a_miss" ]; then
    ok "183a: rounds — three canonical trusted facts enumerated, next=4 derived, untrusted canonical-shaped round 9 excluded (#711)"
  else
    ng "183a: rounds broke canonical enumeration / derivation on FX-A —$s183j_a_miss (#711)"
  fi
fi

# §183b (ROUNDS — LOOKALIKES COUNT FOR NOTHING): FX-B carries only lookalikes
# (header mid-prose; marker without header; marker not the LAST content line).
# Zero facts, next=1 (zero canonical → 1) — canonicity is position-bound.
if [ -n "$S183J_UNREADY" ]; then
  ng "183b: rounds — lookalike rejection (position-bound canonicity) not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_b_out=$(s183j_run "$S183J_FX/fx_b.json" 0 rounds 42); s183j_b_rc=$?
  s183j_b_facts=$(printf '%s\n' "$s183j_b_out" | grep -c '^round=')
  s183j_b_miss=""
  [ "$s183j_b_rc" = 0 ] || s183j_b_miss="$s183j_b_miss <rc=$s183j_b_rc>"
  [ "$s183j_b_facts" = 0 ] || s183j_b_miss="$s183j_b_miss <facts=$s183j_b_facts!=0>"
  printf '%s\n' "$s183j_b_out" | grep -qx 'next=1' || s183j_b_miss="$s183j_b_miss <next=1-missing>"
  if [ -z "$s183j_b_miss" ]; then
    ok "183b: rounds — all three lookalike shapes rejected (zero facts), next=1 on zero canonical comments (#711)"
  else
    ng "183b: a lookalike counted as canonical, or the zero-canonical derivation is wrong —$s183j_b_miss (#711)"
  fi
fi

# §183c (ROUNDS — CANONICAL BESIDE A LOOKALIKE): FX-C has one canonical round 2
# beside a non-canonical comment quoting a round=1 marker in prose. Exactly one
# fact; next=3.
if [ -n "$S183J_UNREADY" ]; then
  ng "183c: rounds — canonical-beside-lookalike derivation not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_c_out=$(s183j_run "$S183J_FX/fx_c.json" 0 rounds 42); s183j_c_rc=$?
  s183j_c_facts=$(printf '%s\n' "$s183j_c_out" | grep -c '^round=')
  s183j_c_miss=""
  [ "$s183j_c_rc" = 0 ] || s183j_c_miss="$s183j_c_miss <rc=$s183j_c_rc>"
  [ "$s183j_c_facts" = 1 ] || s183j_c_miss="$s183j_c_miss <facts=$s183j_c_facts!=1>"
  printf '%s\n' "$s183j_c_out" | grep -qx 'round=2 head=abc0002' || s183j_c_miss="$s183j_c_miss <fact-r2-missing>"
  printf '%s\n' "$s183j_c_out" | grep -qx 'next=3' || s183j_c_miss="$s183j_c_miss <next=3-missing>"
  if printf '%s\n' "$s183j_c_out" | grep -q '^round=1 '; then s183j_c_miss="$s183j_c_miss <lookalike-r1-counted>"; fi
  if [ -z "$s183j_c_miss" ]; then
    ok "183c: rounds — one canonical round-2 fact beside a quoted-marker lookalike, next=3 (#711)"
  else
    ng "183c: the round=1 prose lookalike leaked into the facts or the derivation —$s183j_c_miss (#711)"
  fi
fi

# §183d (ROUNDS — DUPLICATE SURFACED, NEVER SILENTLY PICKED): FX-D carries TWO
# canonical round-2 comments. `rounds` must name `duplicate`, exit 3 (the
# distinct code this suite pins), and must NOT emit a next= line as if one of
# the two had been silently chosen.
if [ -n "$S183J_UNREADY" ]; then
  ng "183d: rounds — duplicate-canonical-round surfacing not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_d_out=$(s183j_run "$S183J_FX/fx_d.json" 0 rounds 42); s183j_d_rc=$?
  s183j_d_miss=""
  [ "$s183j_d_rc" = 3 ] || s183j_d_miss="$s183j_d_miss <rc=$s183j_d_rc!=3>"
  printf '%s\n' "$s183j_d_out" | grep -q 'duplicate' || s183j_d_miss="$s183j_d_miss <duplicate-not-named>"
  if printf '%s\n' "$s183j_d_out" | grep -q '^next='; then s183j_d_miss="$s183j_d_miss <next=-emitted-despite-duplicate>"; fi
  if [ -z "$s183j_d_miss" ]; then
    ok "183d: rounds — duplicate canonical round surfaced as duplicate with exit 3, no silent pick, no next= (#711)"
  else
    ng "183d: a duplicate canonical round was silently picked or not distinctly surfaced —$s183j_d_miss (#711)"
  fi
fi

# §183e (ROUNDS — QUOTED CONCRETE MARKER MID-BODY): FX-E's single canonical
# round-1 comment QUOTES a concrete round=9 marker mid-body. Position-binding
# means the quote never raises the max: one fact, next=2.
if [ -n "$S183J_UNREADY" ]; then
  ng "183e: rounds — mid-body quoted-marker exclusion not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_e_out=$(s183j_run "$S183J_FX/fx_e.json" 0 rounds 42); s183j_e_rc=$?
  s183j_e_facts=$(printf '%s\n' "$s183j_e_out" | grep -c '^round=')
  s183j_e_miss=""
  [ "$s183j_e_rc" = 0 ] || s183j_e_miss="$s183j_e_miss <rc=$s183j_e_rc>"
  [ "$s183j_e_facts" = 1 ] || s183j_e_miss="$s183j_e_miss <facts=$s183j_e_facts!=1>"
  printf '%s\n' "$s183j_e_out" | grep -qx 'round=1 head=abc0001' || s183j_e_miss="$s183j_e_miss <fact-r1-missing>"
  printf '%s\n' "$s183j_e_out" | grep -qx 'next=2' || s183j_e_miss="$s183j_e_miss <next=2-missing>"
  if printf '%s\n' "$s183j_e_out" | grep -q 'round=9'; then s183j_e_miss="$s183j_e_miss <quoted-marker-raised-max>"; fi
  if [ -z "$s183j_e_miss" ]; then
    ok "183e: rounds — a concrete marker quoted mid-body in a canonical comment leaves the max untouched (next=2) (#711)"
  else
    ng "183e: a quoted mid-body marker raised the round max (position-binding broken) —$s183j_e_miss (#711)"
  fi
fi

# §183f (SHOW — CANONICAL HIT): show 42 2 on FX-A prints the round-2 body —
# header first line, its own content, its marker.
if [ -n "$S183J_UNREADY" ]; then
  ng "183f: show — canonical-round body retrieval not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_f_out=$(s183j_run "$S183J_FX/fx_a.json" 0 show 42 2); s183j_f_rc=$?
  s183j_f_first=$(printf '%s\n' "$s183j_f_out" | head -n 1)
  s183j_f_miss=""
  [ "$s183j_f_rc" = 0 ] || s183j_f_miss="$s183j_f_miss <rc=$s183j_f_rc>"
  [ "$s183j_f_first" = "## Finding triage (round 2)" ] || s183j_f_miss="$s183j_f_miss <first-line-not-header>"
  printf '%s\n' "$s183j_f_out" | grep -qF -- '- F2: refuted, refuting cmd held' || s183j_f_miss="$s183j_f_miss <body-content-missing>"
  printf '%s\n' "$s183j_f_out" | grep -qF 'round=2 head=bbb2222' || s183j_f_miss="$s183j_f_miss <marker-missing>"
  if [ -z "$s183j_f_miss" ]; then
    ok "183f: show — the canonical round-2 body prints whole (header, content, marker) (#711)"
  else
    ng "183f: show did not return the canonical round-2 body —$s183j_f_miss (#711)"
  fi
fi

# §183g (SHOW — MISS IS EXIT 2, TRUST-FILTERED): show 42 9 on FX-A must MISS:
# the only round-9 comment is canonical-shaped but untrusted. Exit 2, and the
# forged body never prints.
if [ -n "$S183J_UNREADY" ]; then
  ng "183g: show — miss/trust behavior not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_g_out=$(s183j_run "$S183J_FX/fx_a.json" 0 show 42 9); s183j_g_rc=$?
  s183j_g_miss=""
  [ "$s183j_g_rc" = 2 ] || s183j_g_miss="$s183j_g_miss <rc=$s183j_g_rc!=2>"
  if printf '%s\n' "$s183j_g_out" | grep -q 'forged drive-by round'; then s183j_g_miss="$s183j_g_miss <untrusted-body-served>"; fi
  if [ -z "$s183j_g_miss" ]; then
    ok "183g: show — an untrusted canonical-shaped round is a miss (exit 2), its body never served (#711)"
  else
    ng "183g: show served an untrusted round or missed with the wrong code —$s183j_g_miss (#711)"
  fi
fi

# §183h (POST — COMPOSITION HAPPY PATH, FX-P1): a valid judge output against
# FX-A (derived round 4) posts EXACTLY ONCE via `pr comment 42 --body-file`.
# The captured body: first line is the round-4 header (and matches the header
# regex), the round-4/input-sha marker is the LAST content line, the judge
# output rides as the body, and every @mention is neutralized (bare `@alice`
# gone, `alice` retained — the ac_closeout.sh zwsp idiom family).
if [ -n "$S183J_UNREADY" ]; then
  ng "183h: post — composition/posting happy path not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_run "$S183J_FX/fx_a.json" 0 post 42 "$S183J_FX/p1.txt" >/dev/null; s183j_h_rc=$?
  s183j_h_posts=$(s183j_posts)
  s183j_h_miss=""
  [ "$s183j_h_rc" = 0 ] || s183j_h_miss="$s183j_h_miss <rc=$s183j_h_rc>"
  [ "$s183j_h_posts" = 1 ] || s183j_h_miss="$s183j_h_miss <posts=$s183j_h_posts!=1>"
  grep -q '^pr comment 42 .*--body-file' "$S183J_LOG" || s183j_h_miss="$s183j_h_miss <not-body-file-post>"
  if [ -f "$S183J_POSTED" ]; then
    s183j_h_first=$(head -n 1 "$S183J_POSTED")
    s183j_h_last=$(s183j_last_content "$S183J_POSTED")
    [ "$s183j_h_first" = "## Finding triage (round 4)" ] || s183j_h_miss="$s183j_h_miss <header-first-line-wrong>"
    printf '%s\n' "$s183j_h_first" | grep -qE '^## Finding triage \(round [0-9]+\)$' || s183j_h_miss="$s183j_h_miss <header-regex-miss>"
    [ "$s183j_h_last" = "<!-- finding-judge: round=4 head=abc123f -->" ] || s183j_h_miss="$s183j_h_miss <marker-not-last-content-line>"
    grep -qF -- 'F1 :: upheld' "$S183J_POSTED" || s183j_h_miss="$s183j_h_miss <judge-output-body-missing>"
    if grep -q '@alice' "$S183J_POSTED"; then s183j_h_miss="$s183j_h_miss <bare-mention-survived>"; fi
    grep -q 'alice' "$S183J_POSTED" || s183j_h_miss="$s183j_h_miss <mention-content-dropped>"
  else
    s183j_h_miss="$s183j_h_miss <no-body-captured>"
  fi
  if [ -z "$s183j_h_miss" ]; then
    ok "183h: post — one --body-file post; header first line, marker (round 4, input sha) last content line, mentions neutralized (#711)"
  else
    ng "183h: post composed or delivered the comment wrong —$s183j_h_miss (#711)"
  fi
fi

# §183i (POST — INPUT REJECTS: NOT-reviewed-head FIRST LINE + DOUBLE-WRAP): an
# input whose first line is not `reviewed-head:` (FX-P2), and an input whose
# first line is ALREADY a `## Finding triage` header (double-wrap), both reject
# non-zero with ZERO posts.
if [ -n "$S183J_UNREADY" ]; then
  ng "183i: post — first-line validation rejects not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_i_miss=""
  s183j_run "$S183J_FX/fx_a.json" 0 post 42 "$S183J_FX/p2.txt" >/dev/null; s183j_i_rc1=$?
  s183j_i_posts1=$(s183j_posts)
  [ "$s183j_i_rc1" != 0 ] || s183j_i_miss="$s183j_i_miss <p2-accepted>"
  [ "$s183j_i_posts1" = 0 ] || s183j_i_miss="$s183j_i_miss <p2-posted=$s183j_i_posts1>"
  s183j_run "$S183J_FX/fx_a.json" 0 post 42 "$S183J_FX/p2b.txt" >/dev/null; s183j_i_rc2=$?
  s183j_i_posts2=$(s183j_posts)
  [ "$s183j_i_rc2" != 0 ] || s183j_i_miss="$s183j_i_miss <double-wrap-accepted>"
  [ "$s183j_i_posts2" = 0 ] || s183j_i_miss="$s183j_i_miss <double-wrap-posted=$s183j_i_posts2>"
  if [ -z "$s183j_i_miss" ]; then
    ok "183i: post — a first line that is not reviewed-head:, and an already-wrapped triage header, both reject with no post (#711)"
  else
    ng "183i: post accepted a malformed first line (missing reviewed-head: or double-wrap) —$s183j_i_miss (#711)"
  fi
fi

# §183j (POST — MARKER-FORGERY GUARD, FX-P3): a judge output smuggling a
# concrete `<!-- finding-judge: … -->` marker line anywhere in the input is
# rejected with no post — otherwise the smuggled round would read back as
# canonical history.
if [ -n "$S183J_UNREADY" ]; then
  ng "183j: post — smuggled-marker (forgery) reject not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_run "$S183J_FX/fx_a.json" 0 post 42 "$S183J_FX/p3.txt" >/dev/null; s183j_j_rc=$?
  s183j_j_posts=$(s183j_posts)
  s183j_j_miss=""
  [ "$s183j_j_rc" != 0 ] || s183j_j_miss="$s183j_j_miss <forged-input-accepted>"
  [ "$s183j_j_posts" = 0 ] || s183j_j_miss="$s183j_j_miss <posted=$s183j_j_posts>"
  if [ -z "$s183j_j_miss" ]; then
    ok "183j: post — an input smuggling a concrete marker is rejected before any post (forgery guard) (#711)"
  else
    ng "183j: a smuggled concrete marker got through post —$s183j_j_miss (#711)"
  fi
fi

# §183k (POST — THE NO-PR PATH IS A NAMED REJECT, FX-P4): `reviewed-head: n/a
# (<mode>)` never posts — the reject is non-zero, zero posts, and NAMES the
# n/a head it refused (not a silent generic failure).
if [ -n "$S183J_UNREADY" ]; then
  ng "183k: post — reviewed-head n/a named reject not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_k_out=$(s183j_run "$S183J_FX/fx_a.json" 0 post 42 "$S183J_FX/p4.txt"); s183j_k_rc=$?
  s183j_k_posts=$(s183j_posts)
  s183j_k_miss=""
  [ "$s183j_k_rc" != 0 ] || s183j_k_miss="$s183j_k_miss <n/a-head-accepted>"
  [ "$s183j_k_posts" = 0 ] || s183j_k_miss="$s183j_k_miss <posted=$s183j_k_posts>"
  printf '%s\n' "$s183j_k_out" | grep -qF 'n/a' || s183j_k_miss="$s183j_k_miss <reject-not-named>"
  if [ -z "$s183j_k_miss" ]; then
    ok "183k: post — reviewed-head: n/a (--staged) is a NAMED reject, the no-PR path never posts (#711)"
  else
    ng "183k: the no-PR (n/a head) input posted or rejected namelessly —$s183j_k_miss (#711)"
  fi
fi

# §183l (VALIDATE — THE DISTINCT VALIDATOR, DRIVEN DIRECTLY): against FX-A
# (canonical rounds 1..3), a well-formed round-4 body passes (positive control,
# so a reject-everything stub cannot green this arm), and each malformed body
# rejects: first line not the header, marker missing, marker not the last
# content line, header/marker round mismatch, round collision with an existing
# canonical round.
if [ -n "$S183J_UNREADY" ]; then
  ng "183l: validate — composed-body validator not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_l_miss=""
  s183j_run "$S183J_FX/fx_a.json" 0 validate 42 "$S183J_FX/v_ok.md" >/dev/null; s183j_l_rc=$?
  [ "$s183j_l_rc" = 0 ] || s183j_l_miss="$s183j_l_miss <control-valid-body-rejected:rc=$s183j_l_rc>"
  s183j_run "$S183J_FX/fx_a.json" 0 validate 42 "$S183J_FX/v_hdr.md" >/dev/null; s183j_l_rc=$?
  [ "$s183j_l_rc" != 0 ] || s183j_l_miss="$s183j_l_miss <first-line-not-header-accepted>"
  s183j_run "$S183J_FX/fx_a.json" 0 validate 42 "$S183J_FX/v_nomark.md" >/dev/null; s183j_l_rc=$?
  [ "$s183j_l_rc" != 0 ] || s183j_l_miss="$s183j_l_miss <marker-missing-accepted>"
  s183j_run "$S183J_FX/fx_a.json" 0 validate 42 "$S183J_FX/v_mispl.md" >/dev/null; s183j_l_rc=$?
  [ "$s183j_l_rc" != 0 ] || s183j_l_miss="$s183j_l_miss <marker-misplaced-accepted>"
  s183j_run "$S183J_FX/fx_a.json" 0 validate 42 "$S183J_FX/v_mm.md" >/dev/null; s183j_l_rc=$?
  [ "$s183j_l_rc" != 0 ] || s183j_l_miss="$s183j_l_miss <header-marker-round-mismatch-accepted>"
  s183j_run "$S183J_FX/fx_a.json" 0 validate 42 "$S183J_FX/v_coll.md" >/dev/null; s183j_l_rc=$?
  [ "$s183j_l_rc" != 0 ] || s183j_l_miss="$s183j_l_miss <round-collision-accepted>"
  if [ -z "$s183j_l_miss" ]; then
    ok "183l: validate — well-formed round-4 body passes; misplaced header/marker, round mismatch, and round collision each reject (#711)"
  else
    ng "183l: the composed-body validator let a malformed body through (or rejected the control) —$s183j_l_miss (#711)"
  fi
fi

# §183m (TRUSTED-AUTHOR FILTER PARITY — CODE vs CODE): the script's -q filter
# literal must be byte-identical to ac_closeout_gate.sh's. Extraction is
# structural (the single-quoted -q argument mentioning authorAssociation, one
# unique literal per file) — never a prose pin. Control: the two PRE-EXISTING
# carriers (gate helper + ac_closeout.sh remedy) must extract identical, which
# proves the extractor itself before the script is compared.
if [ -n "$S183J_UNREADY" ]; then
  ng "183m: trusted-author filter parity not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_m_gate=$(s183j_filter_lits "$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh")
  s183j_m_rmd=$(s183j_filter_lits "$SHELL_ROOT/scripts/ac_closeout.sh")
  s183j_m_new=$(s183j_filter_lits "$S183J_SCRIPT")
  s183j_m_new_n=$(printf '%s\n' "$s183j_m_new" | awk 'NF' | awk 'END{print NR}')
  s183j_m_miss=""
  [ -n "$s183j_m_gate" ] || s183j_m_miss="$s183j_m_miss <gate-literal-unextractable>"
  [ "$s183j_m_rmd" = "$s183j_m_gate" ] || s183j_m_miss="$s183j_m_miss <extractor-control-failed:gate-vs-remedy-differ>"
  [ "$s183j_m_new_n" = 1 ] || s183j_m_miss="$s183j_m_miss <script-literals=$s183j_m_new_n!=1>"
  { [ -n "$s183j_m_new" ] && [ "$s183j_m_new" = "$s183j_m_gate" ]; } || s183j_m_miss="$s183j_m_miss <script-filter-diverges-from-gate>"
  if [ -z "$s183j_m_miss" ]; then
    ok "183m: the script's trusted-author -q filter is byte-identical to ac_closeout_gate.sh's (extractor proven on gate-vs-remedy) (#711)"
  else
    ng "183m: trusted-author filter parity broken —$s183j_m_miss (#711)"
  fi
fi

# §183n (GH FAILURE — FAIL CLOSED, NO RETRY): with the stub failing
# `pr comment`, a valid post attempt exits non-zero and attempts the post
# EXACTLY ONCE — loud, no retry loop, no pretend-success.
if [ -n "$S183J_UNREADY" ]; then
  ng "183n: post — gh-failure fail-closed behavior not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_run "$S183J_FX/fx_a.json" 1 post 42 "$S183J_FX/p1.txt" >/dev/null; s183j_n_rc=$?
  s183j_n_posts=$(s183j_posts)
  s183j_n_miss=""
  [ "$s183j_n_rc" != 0 ] || s183j_n_miss="$s183j_n_miss <gh-failure-swallowed:rc=0>"
  [ "$s183j_n_posts" = 1 ] || s183j_n_miss="$s183j_n_miss <attempts=$s183j_n_posts!=1>"
  if [ -z "$s183j_n_miss" ]; then
    ok "183n: post — a failing gh pr comment fails the script closed after exactly one attempt (no retry, no silent pass) (#711)"
  else
    ng "183n: a gh posting failure was swallowed or retried —$s183j_n_miss (#711)"
  fi
fi

# §183o (THE ROUND TRIP — AC 3's core lock): the body `post` composes, served
# back as a trusted PR comment, is accepted as CANONICAL by `rounds` — fact
# round=4 with the input sha, next=5. Producer and reader agree on one shape
# because they are the same code home.
if [ -n "$S183J_UNREADY" ]; then
  ng "183o: round trip — post-composed body re-read by rounds not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#711)"
else
  s183j_run "$S183J_FX/fx_a.json" 0 post 42 "$S183J_FX/p1.txt" >/dev/null; s183j_o_rc=$?
  if [ "$s183j_o_rc" != 0 ] || [ ! -f "$S183J_POSTED" ]; then
    ng "183o: round trip — the post half failed (rc=$s183j_o_rc, body-captured=$([ -f "$S183J_POSTED" ] && echo yes || echo no)), nothing to read back (#711)"
  else
    jq -n --arg b "$(cat "$S183J_POSTED")" '{"comments":[{"authorAssociation":"OWNER","body":$b}]}' > "$S183J_FX/fx_rt.json"
    s183j_o_out=$(s183j_run "$S183J_FX/fx_rt.json" 0 rounds 42); s183j_o_rc2=$?
    s183j_o_miss=""
    [ "$s183j_o_rc2" = 0 ] || s183j_o_miss="$s183j_o_miss <rc=$s183j_o_rc2>"
    printf '%s\n' "$s183j_o_out" | grep -qx 'round=4 head=abc123f' || s183j_o_miss="$s183j_o_miss <composed-body-not-canonical>"
    printf '%s\n' "$s183j_o_out" | grep -qx 'next=5' || s183j_o_miss="$s183j_o_miss <next=5-missing>"
    if [ -z "$s183j_o_miss" ]; then
      ok "183o: round trip — the body post composes reads back canonical (round=4 head=abc123f, next=5) (#711)"
    else
      ng "183o: rounds does not accept the body post itself composed — producer/reader shape split —$s183j_o_miss (#711)"
    fi
  fi
fi

# ---------- §183p–§183t: the reader residuals (#713) ----------
# Phase B arms for the five contracts #713's Doc phase pinned in the script
# header: base-10 round normalization (AC1), full-stream fetch + duplicate
# refusal over a deep stream (AC2 — behavior lock, born green), the two named
# anomaly classes on stderr with every other lookalike silent (AC3), a cleanup
# trap that covers INT/TERM (AC4), and the MAINTAINER token gone from the
# shared trusted-author literal (AC5). §183p/q/s/t are born RED and green with
# #713's Code phase; §183r locks behavior the current script already exhibits.

# s183j_run_split <fixture> <crc> <stderr-file> <mode+args…> — like s183j_run
# but stdout only on the wire, stderr captured separately (the anomaly channel
# is a stderr contract: fact/next= grammar on stdout must stay anomaly-free).
s183j_run_split() {
  s183j_rs_fx="$1"; s183j_rs_crc="$2"; s183j_rs_err="$3"; shift 3
  : > "$S183J_LOG"
  rm -f "$S183J_POSTED"
  S183J_GH_LOG="$S183J_LOG" S183J_GH_FX_JSON="$s183j_rs_fx" \
  S183J_GH_POSTED="$S183J_POSTED" S183J_GH_COMMENT_RC="$s183j_rs_crc" \
  PATH="$S183J_DIR/bin:$PATH" "$S183J_SCRIPT" "$@" 2>"$s183j_rs_err"
}

# FX-Z8: one trusted canonical comment whose header AND marker both carry the
# zero-padded token 08 (they agree, so the comment is canonical; only the token
# spelling is unusual). FX-Z8D adds a second canonical comment claiming round 8
# unpadded — one round, two spellings, one duplicate.
cat > "$S183J_FX/fx_z8.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"## Finding triage (round 08)\n\n- Z: zero-padded round token\n\n<!-- finding-judge: round=08 head=abc0008 -->"}
]}
S183J_JSON
cat > "$S183J_FX/fx_z8d.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"## Finding triage (round 08)\n\n- Z: zero-padded spelling\n\n<!-- finding-judge: round=08 head=abc0008 -->"},
{"authorAssociation":"MEMBER","body":"## Finding triage (round 8)\n\n- Z: unpadded spelling of the SAME round\n\n<!-- finding-judge: round=8 head=def0008 -->"}
]}
S183J_JSON

# Anomaly-class fixtures (AC3). FX-AN-A: trusted, valid marker as the LAST
# content line, but no canonical first-line header. FX-AN-B: trusted, canonical
# header (round 4) and position-bound marker whose round (5) disagrees.
cat > "$S183J_FX/fx_an_a.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"prose first line, no triage header anywhere\n\n<!-- finding-judge: round=6 head=ddd4444 -->"}
]}
S183J_JSON
cat > "$S183J_FX/fx_an_b.json" <<'S183J_JSON'
{"comments":[
{"authorAssociation":"OWNER","body":"## Finding triage (round 4)\n\n- header says 4, marker says 5\n\n<!-- finding-judge: round=5 head=eee5555 -->"}
]}
S183J_JSON

# §183p (ROUNDS — ZERO-PADDED ROUND TOKEN, AC1; born RED until #713 Code): a
# trusted canonical comment spelling its round 08 must derive, not abort: the
# token normalizes to base-10 BEFORE any arithmetic — fact `round=8`, next=9,
# exit 0, and the raw 08 spelling never reaches stdout. The duplicate half:
# canonical 08 beside canonical 8 is ONE round claimed twice — duplicate, exit
# 3, no next=. (Today both halves die at the $((max + 1)) octal abort: "08:
# value too great for base", exit 1.)
if [ -n "$S183J_UNREADY" ]; then
  ng "183p: rounds — zero-padded round normalization not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#713)"
else
  s183j_p_out=$(s183j_run "$S183J_FX/fx_z8.json" 0 rounds 42); s183j_p_rc=$?
  s183j_p_miss=""
  [ "$s183j_p_rc" = 0 ] || s183j_p_miss="$s183j_p_miss <rc=$s183j_p_rc>"
  printf '%s\n' "$s183j_p_out" | grep -qx 'round=8 head=abc0008' || s183j_p_miss="$s183j_p_miss <normalized-fact-round=8-missing>"
  printf '%s\n' "$s183j_p_out" | grep -qx 'next=9' || s183j_p_miss="$s183j_p_miss <next=9-missing>"
  if printf '%s\n' "$s183j_p_out" | grep -q 'round=08'; then s183j_p_miss="$s183j_p_miss <raw-08-token-leaked>"; fi
  s183j_p_out2=$(s183j_run "$S183J_FX/fx_z8d.json" 0 rounds 42); s183j_p_rc2=$?
  [ "$s183j_p_rc2" = 3 ] || s183j_p_miss="$s183j_p_miss <08-vs-8-rc=$s183j_p_rc2!=3>"
  printf '%s\n' "$s183j_p_out2" | grep -q 'duplicate' || s183j_p_miss="$s183j_p_miss <08-vs-8-duplicate-not-named>"
  if printf '%s\n' "$s183j_p_out2" | grep -q '^next='; then s183j_p_miss="$s183j_p_miss <08-vs-8-next=-emitted>"; fi
  if [ -z "$s183j_p_miss" ]; then
    ok "183p: rounds — round token 08 normalizes to round=8/next=9, and 08 beside 8 is one duplicate round (exit 3) (#713)"
  else
    ng "183p: a zero-padded round token broke the derivation (octal abort or missed 08/8 duplicate) —$s183j_p_miss (#713)"
  fi
fi

# §183q (ROUNDS — THE TWO NAMED ANOMALY CLASSES, AC3; born RED until #713
# Code): on TRUSTED comments, (a) a valid marker as the last content line with
# no canonical header and (b) a position-bound header/marker pair whose rounds
# disagree each surface EXACTLY ONE informational `anomaly: …` line on STDERR —
# the two classes named distinctly (their lines differ) — while the stdout
# grammar and exit code stay exactly what they are today (zero facts, next=1,
# exit 0). Negative face (green today, must STAY green): the prose-lookalike
# (FX-C) and quoted-mid-body-marker (FX-E) shapes are silent BY DESIGN — the
# anomaly channel must not become an oracle for probing position-binding.
if [ -n "$S183J_UNREADY" ]; then
  ng "183q: rounds — anomaly-class stderr surfacing not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#713)"
else
  s183j_q_miss=""
  s183j_q_out_a=$(s183j_run_split "$S183J_FX/fx_an_a.json" 0 "$S183J_DIR/err_a" rounds 42); s183j_q_rc_a=$?
  s183j_q_out_b=$(s183j_run_split "$S183J_FX/fx_an_b.json" 0 "$S183J_DIR/err_b" rounds 42); s183j_q_rc_b=$?
  s183j_q_an_a=$(grep -c '^anomaly:' "$S183J_DIR/err_a"); s183j_q_an_b=$(grep -c '^anomaly:' "$S183J_DIR/err_b")
  [ "$s183j_q_rc_a" = 0 ] || s183j_q_miss="$s183j_q_miss <headerless-rc=$s183j_q_rc_a>"
  [ "$s183j_q_rc_b" = 0 ] || s183j_q_miss="$s183j_q_miss <mismatch-rc=$s183j_q_rc_b>"
  [ "$s183j_q_an_a" = 1 ] || s183j_q_miss="$s183j_q_miss <headerless-anomaly-lines=$s183j_q_an_a!=1>"
  [ "$s183j_q_an_b" = 1 ] || s183j_q_miss="$s183j_q_miss <mismatch-anomaly-lines=$s183j_q_an_b!=1>"
  [ "$(grep '^anomaly:' "$S183J_DIR/err_a")" != "$(grep '^anomaly:' "$S183J_DIR/err_b")" ] \
    || s183j_q_miss="$s183j_q_miss <two-classes-one-name>"
  # stdout grammar unchanged by the anomaly channel: zero facts, next=1, and
  # never an anomaly line on stdout.
  for s183j_q_out in "$s183j_q_out_a" "$s183j_q_out_b"; do
    [ "$(printf '%s\n' "$s183j_q_out" | grep -c '^round=')" = 0 ] || s183j_q_miss="$s183j_q_miss <anomaly-comment-counted-as-fact>"
    printf '%s\n' "$s183j_q_out" | grep -qx 'next=1' || s183j_q_miss="$s183j_q_miss <next=1-missing>"
    if printf '%s\n' "$s183j_q_out" | grep -q '^anomaly:'; then s183j_q_miss="$s183j_q_miss <anomaly-leaked-to-stdout>"; fi
  done
  # Negative face: every OTHER lookalike shape stays silent.
  s183j_run_split "$S183J_FX/fx_c.json" 0 "$S183J_DIR/err_c" rounds 42 >/dev/null
  s183j_run_split "$S183J_FX/fx_e.json" 0 "$S183J_DIR/err_e" rounds 42 >/dev/null
  if grep -q '^anomaly:' "$S183J_DIR/err_c"; then s183j_q_miss="$s183j_q_miss <prose-lookalike-raised-anomaly>"; fi
  if grep -q '^anomaly:' "$S183J_DIR/err_e"; then s183j_q_miss="$s183j_q_miss <quoted-mid-body-marker-raised-anomaly>"; fi
  if [ -z "$s183j_q_miss" ]; then
    ok "183q: rounds — headerless-marker and header/marker-mismatch each one distinct anomaly: stderr line; stdout grammar, exit codes, and lookalike silence unchanged (#713)"
  else
    ng "183q: the two near-canonical classes are not surfaced as named stderr anomalies (or the channel leaked/over-fired) —$s183j_q_miss (#713)"
  fi
fi

# §183r (ROUNDS/POST — FULL-STREAM READ + DUPLICATE REFUSAL DEEP IN THE
# STREAM, AC2; born GREEN — a behavior lock on the documented full-stream
# read): a canonical comment sitting beyond position 100 of the served stream
# is still counted by `rounds`, and a `post` whose duplicate twin hides that
# deep exits 3 with ZERO posts — a windowed (first-100) read would miss both.
if [ -n "$S183J_UNREADY" ]; then
  ng "183r: full-stream deep-comment read not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#713)"
else
  jq -n '{comments: ([range(110) | {authorAssociation: "OWNER", body: ("filler prose comment \(.) — no triage shape")}]
                     + [{authorAssociation: "OWNER", body: "## Finding triage (round 7)\n\n- deep canonical\n\n<!-- finding-judge: round=7 head=abc0007 -->"}])}' \
    > "$S183J_FX/fx_deep.json"
  jq -n '{comments: ([{authorAssociation: "OWNER", body: "## Finding triage (round 7)\n\n- shallow twin\n\n<!-- finding-judge: round=7 head=aaa0007 -->"}]
                     + [range(110) | {authorAssociation: "OWNER", body: ("filler prose comment \(.) — no triage shape")}]
                     + [{authorAssociation: "OWNER", body: "## Finding triage (round 7)\n\n- deep twin\n\n<!-- finding-judge: round=7 head=bbb0007 -->"}])}' \
    > "$S183J_FX/fx_deepdup.json"
  s183j_r_miss=""
  s183j_r_out=$(s183j_run "$S183J_FX/fx_deep.json" 0 rounds 42); s183j_r_rc=$?
  [ "$s183j_r_rc" = 0 ] || s183j_r_miss="$s183j_r_miss <deep-rounds-rc=$s183j_r_rc>"
  printf '%s\n' "$s183j_r_out" | grep -qx 'round=7 head=abc0007' || s183j_r_miss="$s183j_r_miss <deep-canonical-not-counted>"
  printf '%s\n' "$s183j_r_out" | grep -qx 'next=8' || s183j_r_miss="$s183j_r_miss <next=8-missing>"
  s183j_run "$S183J_FX/fx_deepdup.json" 0 post 42 "$S183J_FX/p1.txt" >/dev/null; s183j_r_rc2=$?
  s183j_r_posts=$(s183j_posts)
  [ "$s183j_r_rc2" = 3 ] || s183j_r_miss="$s183j_r_miss <deep-duplicate-post-rc=$s183j_r_rc2!=3>"
  [ "$s183j_r_posts" = 0 ] || s183j_r_miss="$s183j_r_miss <colliding-round-posted=$s183j_r_posts>"
  if [ -z "$s183j_r_miss" ]; then
    ok "183r: a canonical round beyond position 100 still counts, and a post over its deep duplicate twin refuses with exit 3, zero posts (#713)"
  else
    ng "183r: the derivation read a WINDOW, not the stream — a deep canonical round was missed or a colliding round was minted —$s183j_r_miss (#713)"
  fi
fi

# §183s (POST — CLEANUP TRAP COVERS INT/TERM, AC4; born RED until #713 Code):
# drive `post` into its stalled window (a gh stub that blocks on a FIFO after
# touching a readiness file), TERM the script there, and require the 0600 temp
# file gone afterwards. Deterministic: readiness file + bounded poll, no fixed
# sleeps. NOTE the platform residual: bash's termsig handler happens to run the
# EXIT trap on an untrapped TERM, so the kill half is green even today — the
# half that is RED today is the registration check: the cleanup trap must be
# REGISTERED for INT and TERM (the AC's literal contract; on shells without
# that termsig courtesy, EXIT-only means a leak). Structural extraction of the
# trap lines, same discipline as §183m — not a prose pin.
if [ -n "$S183J_UNREADY" ]; then
  ng "183s: post — INT/TERM cleanup-trap coverage not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#713)"
else
  s183j_s_miss=""
  # Structural half: the trap registration(s) cover INT and TERM (grep -w is
  # token-exact, so a bare EXIT-only registration cannot satisfy either).
  s183j_s_traps=$(grep -E '^[[:space:]]*trap[[:space:]]' "$S183J_SCRIPT")
  printf '%s\n' "$s183j_s_traps" | grep -qw 'INT' || s183j_s_miss="$s183j_s_miss <no-trap-registered-for-INT>"
  printf '%s\n' "$s183j_s_traps" | grep -qw 'TERM' || s183j_s_miss="$s183j_s_miss <no-trap-registered-for-TERM>"
  # Behavioral half: TERM in the stalled window leaves no temp file behind.
  s183j_s_tmp="$S183J_DIR/actmp"; s183j_s_fifo="$S183J_DIR/blockfifo"; s183j_s_ready="$S183J_DIR/blockready"
  mkdir -p "$s183j_s_tmp" "$S183J_DIR/binblock"
  rm -f "$s183j_s_fifo" "$s183j_s_ready" "$s183j_s_tmp"/ghjig-judged-list.* 2>/dev/null
  mkfifo "$s183j_s_fifo"
  cat > "$S183J_DIR/binblock/gh" <<'S183J_GH_BLOCK'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    q=""; prev=""
    for a in "$@"; do case "$prev" in -q|--jq) q="$a";; esac; prev="$a"; done
    if [ -n "$q" ]; then jq -r "$q" < "${S183J_GH_FX_JSON:?}"; else cat "${S183J_GH_FX_JSON:?}"; fi
    ;;
  "pr comment")
    echo "$$" > "${S183J_BLOCK_READY:?}"
    read -r _ < "${S183J_BLOCK_FIFO:?}"
    exit 0 ;;
esac
exit 0
S183J_GH_BLOCK
  chmod +x "$S183J_DIR/binblock/gh"
  S183J_GH_FX_JSON="$S183J_FX/fx_a.json" S183J_BLOCK_READY="$s183j_s_ready" \
  S183J_BLOCK_FIFO="$s183j_s_fifo" TMPDIR="$s183j_s_tmp" \
  PATH="$S183J_DIR/binblock:$PATH" "$S183J_SCRIPT" post 42 "$S183J_FX/p1.txt" >/dev/null 2>&1 &
  s183j_s_pid=$!
  # Off the job table: no "Terminated: 15" notice pollutes the suite output.
  # Liveness below is kill -0 polling, so losing `wait` on the pid costs nothing.
  disown "$s183j_s_pid" 2>/dev/null
  s183j_s_i=0
  while [ ! -s "$s183j_s_ready" ] && [ "$s183j_s_i" -lt 150 ]; do sleep 0.1; s183j_s_i=$((s183j_s_i + 1)); done
  if [ ! -s "$s183j_s_ready" ]; then
    s183j_s_miss="$s183j_s_miss <stalled-window-never-reached>"
    kill -KILL "$s183j_s_pid" 2>/dev/null
  else
    # Inside the window: exactly one 0600 temp file exists (proves the window
    # was real before we assert its cleanup).
    s183j_s_n=$(find "$s183j_s_tmp" -name 'ghjig-judged-list.*' | wc -l | tr -d ' ')
    [ "$s183j_s_n" = 1 ] || s183j_s_miss="$s183j_s_miss <window-tempfiles=$s183j_s_n!=1>"
    s183j_s_mode=$(ls -l "$s183j_s_tmp"/ghjig-judged-list.* 2>/dev/null | awk 'NR==1{print substr($1,1,10)}')
    [ "$s183j_s_mode" = "-rw-------" ] || s183j_s_miss="$s183j_s_miss <temp-mode=$s183j_s_mode!=0600>"
    kill -TERM "$s183j_s_pid" 2>/dev/null
    s183j_s_i=0
    while kill -0 "$s183j_s_pid" 2>/dev/null && [ "$s183j_s_i" -lt 150 ]; do sleep 0.1; s183j_s_i=$((s183j_s_i + 1)); done
    if kill -0 "$s183j_s_pid" 2>/dev/null; then
      s183j_s_miss="$s183j_s_miss <script-survived-TERM>"
      kill -KILL "$s183j_s_pid" 2>/dev/null
    fi
    s183j_s_left=$(find "$s183j_s_tmp" -name 'ghjig-judged-list.*' | wc -l | tr -d ' ')
    [ "$s183j_s_left" = 0 ] || s183j_s_miss="$s183j_s_miss <temp-leaked-on-TERM=$s183j_s_left>"
  fi
  # Unblock/reap the stub (it outlives the TERMed script, parked on the FIFO).
  if [ -s "$s183j_s_ready" ]; then kill -KILL "$(cat "$s183j_s_ready")" 2>/dev/null; fi
  rm -f "$s183j_s_fifo"
  if [ -z "$s183j_s_miss" ]; then
    ok "183s: post — the cleanup trap is registered for INT and TERM, and a TERM in the stalled gh window leaves no temp file (#713)"
  else
    ng "183s: the temp-file cleanup does not cover INT/TERM —$s183j_s_miss (#713)"
  fi
fi

# §183t (TRUSTED-AUTHOR LITERAL — MAINTAINER GONE FROM ALL THREE CARRIERS, AC5;
# born RED until #713 Code): MAINTAINER is not a CommentAuthorAssociation enum
# value — in an allowlist it can only fail to match, never widen trust. The
# shared -q literal (extracted structurally, the same s183j_filter_lits §183m
# proves on gate-vs-remedy) must not carry the token in ANY of its three
# carriers; §183m's byte-parity stays green across the move.
if [ -n "$S183J_UNREADY" ]; then
  ng "183t: trusted-author literal MAINTAINER absence not exercised: $S183J_UNREADY (fail-closed red, not a skip) (#713)"
else
  s183j_t_miss=""
  for s183j_t_f in "$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh" "$SHELL_ROOT/scripts/ac_closeout.sh" "$S183J_SCRIPT"; do
    s183j_t_lit=$(s183j_filter_lits "$s183j_t_f")
    [ -n "$s183j_t_lit" ] || s183j_t_miss="$s183j_t_miss <literal-unextractable:$(basename "$s183j_t_f")>"
    if printf '%s\n' "$s183j_t_lit" | grep -qF 'MAINTAINER'; then
      s183j_t_miss="$s183j_t_miss <MAINTAINER-still-in:$(basename "$s183j_t_f")>"
    fi
  done
  if [ -z "$s183j_t_miss" ]; then
    ok "183t: the shared trusted-author -q literal carries no MAINTAINER token in any of its three carriers (#713)"
  else
    ng "183t: the inert MAINTAINER token survives in the shared trusted-author literal —$s183j_t_miss (#713)"
  fi
fi

# ---------- §183u–§183x: the Issue substrate seam (#707) ----------
# Phase B arms for SPEC §4.13 "One role, two substrates" (#707): the script
# carries the durable substrate as ONE seam — fetch command, post target, and
# pin-form arm — while the four modes stay substrate-independent. On the Issue
# substrate the pin is the SAME `reviewed-head:` field carrying a bare-hex
# sha256 PREFIX (7–40 hex chars) of the fetched Issue body, and issue-mode
# `post` recomputes the live-body hash and REFUSES a stale pin — loud,
# fail-closed, the same refusal class as the existing n/a / duplicate /
# forgery arms. These are SEAM tests, deliberately NOT a mirror of the
# §183a–§183o PR arm set: the PR arms already own the shape / derivation /
# forgery contract, and the seam arms lock only what the substrate move can
# break — routing, pin form, and the body-advance gap a head-pin cannot see.
#
# BINDINGS the Code phase takes from this block (stated once, asserted below):
#   * substrate discriminator: the flag `--issue`, between the mode word and
#     the number — `post --issue <n> <file>`, `rounds --issue <n>`. The SPEC
#     paragraph does not pin a spelling; this block does, so producer recipes
#     and these arms converge on one argv shape.
#   * pin recipe: sha256 over the Issue body as COMMAND SUBSTITUTION of the
#     `gh issue view <n> --json … -q .body` read returns it (i.e. trailing
#     newlines stripped); the pin is a 7–40-hex PREFIX of that digest.
#   * routes: fetch via `gh issue view <n> …`, post via `gh issue comment <n>
#     --body-file <tmp>` — the stub below dispatches on those word pairs.
# §183u/§183v(a)/§183w are born RED at c4ee475 (no issue mode exists — every
# `--issue` argv dies at the `<pr> must be a number` guard); §183x is born
# GREEN and must stay green through the Code phase (PR modes byte-unchanged).

S183U_BIN="$S183J_DIR/bin2"
S183U_FX="$S183J_DIR/fxu"
S183U_IPOSTED="$S183J_DIR/issue_posted.md"
mkdir -p "$S183U_BIN" "$S183U_FX"

# Extended executable gh stub (#633 artifact mode): the §183 stub's pr routes
# byte-for-byte, plus the two issue routes the seam adds. A separate binary —
# the §183a–t arms keep running against the original stub untouched.
cat > "$S183U_BIN/gh" <<'S183U_GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${S183J_GH_LOG:?}"
case "$1 $2" in
  "pr view")
    q=""; prev=""
    for a in "$@"; do
      case "$prev" in -q|--jq) q="$a";; esac
      prev="$a"
    done
    if [ -n "$q" ]; then jq -r "$q" < "${S183J_GH_FX_JSON:?}"; else cat "${S183J_GH_FX_JSON:?}"; fi
    ;;
  "pr comment")
    bf=""; prev=""
    for a in "$@"; do
      case "$prev" in --body-file|-F) bf="$a";; esac
      prev="$a"
    done
    if [ -n "$bf" ] && [ -f "$bf" ]; then cp "$bf" "${S183J_GH_POSTED:?}"; fi
    exit 0
    ;;
  "issue view")
    q=""; prev=""
    for a in "$@"; do
      case "$prev" in -q|--jq) q="$a";; esac
      prev="$a"
    done
    if [ -n "$q" ]; then jq -r "$q" < "${S183U_GH_ISSUE_JSON:?}"; else cat "${S183U_GH_ISSUE_JSON:?}"; fi
    ;;
  "issue comment")
    bf=""; prev=""
    for a in "$@"; do
      case "$prev" in --body-file|-F) bf="$a";; esac
      prev="$a"
    done
    if [ -n "$bf" ] && [ -f "$bf" ]; then cp "$bf" "${S183U_GH_ISSUE_POSTED:?}"; fi
    exit 0
    ;;
esac
exit 0
S183U_GH_STUB
chmod +x "$S183U_BIN/gh"

# Issue fixtures: body A is the body under judgment; body B is the SAME Issue
# after an edit — the substrate advance §183w drives. One JSON per issue state,
# carrying BOTH .body and .comments, so whatever -q the script passes (.body
# for the pin, the trusted-author comments filter for rounds) is honored by
# real jq rather than pre-answered.
S183U_BODY_A='## What

Activation fixture — Directive body A under judgment.

- AC1: the judged list lands as an Issue comment'
S183U_BODY_B='## What

Activation fixture — body B: the same Issue AFTER a body edit (the gap a head-pin cannot see).'
jq -n --arg b "$S183U_BODY_A" '{body: $b, comments: []}' > "$S183U_FX/fx_iss_a.json"
jq -n --arg b "$S183U_BODY_B" '{body: $b, comments: []}' > "$S183U_FX/fx_iss_b.json"

# Portable sha256 (the scripts/lint.sh idiom); the pin fixtures derive from the
# SAME body string the fixture JSON carries, so pin and fixture cannot drift.
s183u_sha256() {
  { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    else shasum -a 256 | awk '{print $1}'; fi; } 2>/dev/null
}
S183U_PIN=$(printf '%s' "$S183U_BODY_A" | s183u_sha256 | cut -c1-12)
S183U_PIN64=$(printf '%s' "$S183U_BODY_A" | s183u_sha256)

# Judge-reply fixtures for the issue path.
printf '%s\n' "reviewed-head: $S183U_PIN" "judgment: ok" \
  "- F1 :: upheld, remedy survives (cc @bob)" > "$S183U_FX/pi_ok.txt"
printf '%s\n' "reviewed-head: issue-body:$S183U_PIN" "- F1 :: upheld" > "$S183U_FX/pi_tagged.txt"
printf '%s\n' "reviewed-head: $S183U_PIN64" "- F1 :: upheld" > "$S183U_FX/pi_full64.txt"

# s183u_run <issue-fixture.json> <mode+args…> — both substrates wired at once:
# the PR fixture stays pinned to FX-A (canonical rounds 1..3, next=4) on EVERY
# run, so a substrate leak — an issue invocation reading PR comments, or a PR
# invocation touching an issue route — is observable, never a silent pass.
s183u_run() {
  s183u_run_ifx="$1"; shift
  : > "$S183J_LOG"
  rm -f "$S183J_POSTED" "$S183U_IPOSTED"
  S183J_GH_LOG="$S183J_LOG" S183J_GH_FX_JSON="$S183J_FX/fx_a.json" \
  S183J_GH_POSTED="$S183J_POSTED" \
  S183U_GH_ISSUE_JSON="$s183u_run_ifx" S183U_GH_ISSUE_POSTED="$S183U_IPOSTED" \
  PATH="$S183U_BIN:$PATH" "$S183J_SCRIPT" "$@" 2>&1
}
s183u_iposts() { grep -c '^issue comment ' "$S183J_LOG" 2>/dev/null; }
s183u_pposts() { grep -c '^pr comment ' "$S183J_LOG" 2>/dev/null; }

# Fail-closed readiness: the §183 preconditions plus a sha256 tool and the
# derived pin fixtures actually being hex of the expected widths.
S183U_UNREADY="$S183J_UNREADY"
{ command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; } \
  || S183U_UNREADY="${S183U_UNREADY:+$S183U_UNREADY; }no sha256 tool (the issue pin is a body-hash prefix)"
printf '%s\n' "$S183U_PIN" | grep -qE '^[0-9a-f]{12}$' \
  || S183U_UNREADY="${S183U_UNREADY:+$S183U_UNREADY; }pin fixture is not 12 hex chars (got: $S183U_PIN)"
printf '%s\n' "$S183U_PIN64" | grep -qE '^[0-9a-f]{64}$' \
  || S183U_UNREADY="${S183U_UNREADY:+$S183U_UNREADY; }full-digest fixture is not 64 hex chars"

# §183u (ISSUE ROUND-TRIP — born RED until #707 Code): a judge reply pinned
# `reviewed-head: <12-hex prefix of sha256(body A)>` posts to the ISSUE
# substrate: the fetch goes through `issue view 43`, the post lands EXACTLY
# ONCE via `issue comment 43 --body-file`, and NO pr route fires. Zero
# canonical issue comments → the composed header is round 1, and the marker's
# head field carries the PIN (the same field, the substrate's own pin form).
# Round-trip: the captured body served back as a trusted ISSUE comment is
# accepted by `rounds --issue 43` as canonical — round=1 head=<pin>, next=2.
# The PR fixture (rounds 1..3, next=4) stays wired throughout, so issue-mode
# reading PR comments would surface as a round-4 header, not a silent pass.
if [ -n "$S183U_UNREADY" ]; then
  ng "183u: issue substrate — post/rounds round trip not exercised: $S183U_UNREADY (fail-closed red, not a skip) (#707)"
else
  s183u_u_miss=""
  s183u_run "$S183U_FX/fx_iss_a.json" post --issue 43 "$S183U_FX/pi_ok.txt" >/dev/null; s183u_u_rc=$?
  [ "$s183u_u_rc" = 0 ] || s183u_u_miss="$s183u_u_miss <post-rc=$s183u_u_rc>"
  [ "$(s183u_iposts)" = 1 ] || s183u_u_miss="$s183u_u_miss <issue-posts=$(s183u_iposts)!=1>"
  [ "$(s183u_pposts)" = 0 ] || s183u_u_miss="$s183u_u_miss <pr-route-touched>"
  grep -q '^issue view 43' "$S183J_LOG" || s183u_u_miss="$s183u_u_miss <fetch-not-issue-view>"
  grep -q '^issue comment 43 .*--body-file' "$S183J_LOG" || s183u_u_miss="$s183u_u_miss <not-issue-body-file-post>"
  if [ -f "$S183U_IPOSTED" ]; then
    s183u_u_first=$(head -n 1 "$S183U_IPOSTED")
    s183u_u_last=$(s183j_last_content "$S183U_IPOSTED")
    [ "$s183u_u_first" = "## Finding triage (round 1)" ] || s183u_u_miss="$s183u_u_miss <header-not-round-1>"
    [ "$s183u_u_last" = "<!-- finding-judge: round=1 head=$S183U_PIN -->" ] || s183u_u_miss="$s183u_u_miss <marker-head-not-the-pin>"
    grep -qF -- 'F1 :: upheld' "$S183U_IPOSTED" || s183u_u_miss="$s183u_u_miss <judge-output-body-missing>"
    if grep -q '@bob' "$S183U_IPOSTED"; then s183u_u_miss="$s183u_u_miss <bare-mention-survived>"; fi
    jq --arg b "$(cat "$S183U_IPOSTED")" '.comments = [{authorAssociation: "OWNER", body: $b}]' \
      "$S183U_FX/fx_iss_a.json" > "$S183U_FX/fx_iss_rt.json"
    s183u_u_out=$(s183u_run "$S183U_FX/fx_iss_rt.json" rounds --issue 43); s183u_u_rc2=$?
    [ "$s183u_u_rc2" = 0 ] || s183u_u_miss="$s183u_u_miss <rounds-rc=$s183u_u_rc2>"
    printf '%s\n' "$s183u_u_out" | grep -qx "round=1 head=$S183U_PIN" || s183u_u_miss="$s183u_u_miss <posted-body-not-canonical>"
    printf '%s\n' "$s183u_u_out" | grep -qx 'next=2' || s183u_u_miss="$s183u_u_miss <next=2-missing>"
  else
    s183u_u_miss="$s183u_u_miss <no-issue-body-captured>"
  fi
  if [ -z "$s183u_u_miss" ]; then
    ok "183u: issue substrate — post --issue lands once via issue comment --body-file (round-1 header, pin-head marker), and rounds --issue reads it back canonical (next=2) (#707)"
  else
    ng "183u: the issue-substrate post/rounds round trip does not hold —$s183u_u_miss (#707)"
  fi
fi

# §183v (PIN-FORM ASYMMETRY — the acceptance half is the RED half): the pin
# field keeps ONE spelling across substrates — bare hex, 7–40 chars. (a) the
# bare 12-hex prefix is ACCEPTED on the issue path (one post) — born RED, since
# no issue invocation exists at head; (b) the tagged spelling
# `reviewed-head: issue-body:<hex>` REJECTS with no post (a second pin grammar
# is exactly what the "same field, existing validators unchanged" contract
# forbids); (c) a FULL 64-hex sha256 REJECTS with no post — the existing
# `{7,40}` first-line bound. Halves (b)/(c) are vacuously green at head (every
# --issue argv already rejects); half (a) is what makes this arm non-vacuous
# and red, and post-Code it converts (b)/(c) from vacuous to load-bearing.
if [ -n "$S183U_UNREADY" ]; then
  ng "183v: issue substrate — pin-form acceptance asymmetry not exercised: $S183U_UNREADY (fail-closed red, not a skip) (#707)"
else
  s183u_v_miss=""
  s183u_run "$S183U_FX/fx_iss_a.json" post --issue 43 "$S183U_FX/pi_ok.txt" >/dev/null; s183u_v_rc=$?
  [ "$s183u_v_rc" = 0 ] || s183u_v_miss="$s183u_v_miss <bare-hex-prefix-rejected:rc=$s183u_v_rc>"
  [ "$(s183u_iposts)" = 1 ] || s183u_v_miss="$s183u_v_miss <bare-hex-posts=$(s183u_iposts)!=1>"
  s183u_run "$S183U_FX/fx_iss_a.json" post --issue 43 "$S183U_FX/pi_tagged.txt" >/dev/null; s183u_v_rc2=$?
  [ "$s183u_v_rc2" != 0 ] || s183u_v_miss="$s183u_v_miss <tagged-issue-body-form-accepted>"
  [ "$(s183u_iposts)" = 0 ] || s183u_v_miss="$s183u_v_miss <tagged-form-posted>"
  s183u_run "$S183U_FX/fx_iss_a.json" post --issue 43 "$S183U_FX/pi_full64.txt" >/dev/null; s183u_v_rc3=$?
  [ "$s183u_v_rc3" != 0 ] || s183u_v_miss="$s183u_v_miss <full-64-hex-sha-accepted>"
  [ "$(s183u_iposts)" = 0 ] || s183u_v_miss="$s183u_v_miss <full-64-posted>"
  if [ -z "$s183u_v_miss" ]; then
    ok "183v: issue pin form — bare 12-hex prefix accepted; tagged issue-body:<hex> and full 64-hex sha both reject with no post (the 7-40 bare-hex bound holds) (#707)"
  else
    ng "183v: the issue pin form diverged from bare-hex 7-40 —$s183u_v_miss (#707)"
  fi
fi

# §183w (BODY-ADVANCE REFUSAL — born RED): the SAME judge reply that posts
# cleanly against body A is staged while the served Issue now carries body B —
# the substrate advanced under the pin, the gap a head-pin cannot see (#723).
# Issue-mode `post` recomputes the live-body hash and REFUSES: non-zero exit,
# ZERO comments land on either route, and the refusal NAMES the staleness —
# the message carries one of advance/mismatch/stale, the same loud fail-closed
# refusal class as the n/a / duplicate / forgery arms, never a silent generic
# failure. (At head the --issue argv dies at the argc/usage guard, whose text
# names no advance/mismatch/stale — red on the naming check. A bare 'body'
# probe was measured VACUOUS here: the usage text itself says "comment body".)
if [ -n "$S183U_UNREADY" ]; then
  ng "183w: issue substrate — stale-pin (body advanced) refusal not exercised: $S183U_UNREADY (fail-closed red, not a skip) (#707)"
else
  s183u_w_out=$(s183u_run "$S183U_FX/fx_iss_b.json" post --issue 43 "$S183U_FX/pi_ok.txt"); s183u_w_rc=$?
  s183u_w_miss=""
  [ "$s183u_w_rc" != 0 ] || s183u_w_miss="$s183u_w_miss <stale-pin-accepted:rc=0>"
  [ "$(s183u_iposts)" = 0 ] || s183u_w_miss="$s183u_w_miss <stale-pin-posted=$(s183u_iposts)>"
  [ "$(s183u_pposts)" = 0 ] || s183u_w_miss="$s183u_w_miss <pr-route-touched>"
  printf '%s\n' "$s183u_w_out" | grep -qiE 'advanc|mismatch|stale' || s183u_w_miss="$s183u_w_miss <refusal-does-not-name-the-advance>"
  if [ -z "$s183u_w_miss" ]; then
    ok "183w: issue substrate — a pin staled by a body edit refuses loudly (names the advance/mismatch), fail-closed, zero comments on any route (#707)"
  else
    ng "183w: a body advance under the pin was not refused loudly —$s183u_w_miss (#707)"
  fi
fi

# §183x (PR MODES BYTE-UNCHANGED ACROSS THE SEAM — born GREEN, must STAY green
# through the Code phase): through the EXTENDED stub, with the issue routes
# wired and serving, a plain PR-mode `post 42` behaves exactly as §183h locked
# it — exit 0, EXACTLY one `pr comment 42 --body-file`, the round-4 marker
# carrying the input sha verbatim — and touches NO issue route (`issue view` /
# `issue comment` never fire on the PR path). The n/a refusal and the pin
# handling on the PR path are already owned by §183k and §183h/§183o — cited,
# not duplicated (the no-mirror constraint). Behavior note the Code phase must
# not "fix": the PR path takes the reviewed-head sha VERBATIM into the marker
# (§183h) — it performs no headRefOid fetch today, and none is added by #707.
if [ -n "$S183U_UNREADY" ]; then
  ng "183x: PR-mode invariance across the substrate seam not exercised: $S183U_UNREADY (fail-closed red, not a skip) (#707)"
else
  s183u_run "$S183U_FX/fx_iss_a.json" post 42 "$S183J_FX/p1.txt" >/dev/null; s183u_x_rc=$?
  s183u_x_miss=""
  [ "$s183u_x_rc" = 0 ] || s183u_x_miss="$s183u_x_miss <pr-post-rc=$s183u_x_rc>"
  [ "$(s183u_pposts)" = 1 ] || s183u_x_miss="$s183u_x_miss <pr-posts=$(s183u_pposts)!=1>"
  grep -q '^pr comment 42 .*--body-file' "$S183J_LOG" || s183u_x_miss="$s183u_x_miss <not-pr-body-file-post>"
  if grep -q '^issue ' "$S183J_LOG"; then s183u_x_miss="$s183u_x_miss <issue-route-touched-on-pr-path>"; fi
  if [ -f "$S183J_POSTED" ]; then
    [ "$(s183j_last_content "$S183J_POSTED")" = "<!-- finding-judge: round=4 head=abc123f -->" ] \
      || s183u_x_miss="$s183u_x_miss <pr-marker-changed>"
  else
    s183u_x_miss="$s183u_x_miss <no-pr-body-captured>"
  fi
  if [ -z "$s183u_x_miss" ]; then
    ok "183x: PR mode is byte-unchanged across the seam — one pr-comment post, round-4 marker with the verbatim sha, zero issue-route hits (#707)"
  else
    ng "183x: the substrate seam disturbed the PR path —$s183u_x_miss (#707)"
  fi
fi
