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
