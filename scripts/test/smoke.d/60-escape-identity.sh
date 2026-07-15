# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §120: SessionStart SSOT-presence health line (#460) ----------
# Phase B (Test). Drives the FORTHCOMING SSOT-presence health line that
# session_start.sh is to emit in its in-scope section (alongside the branch
# banner), consuming scripts/lib/onboard_checks.sh --dry-run (filesystem-only,
# NO gh call). Contract under test (Execution #460):
#   - both MISSION.md + SPEC.md present → one line `[GHJig-Claude] SSOT: …`
#       carrying the `✓` glyph (grep anchor: a line with `SSOT:` and `✓`);
#   - SPEC.md ABSENT → a prominent SPEC-first nudge line prefixed
#       `[GHJig-Claude] SSOT-nudge:` mentioning SPEC.md (anchor: `SSOT-nudge`);
#   - the path makes NO `gh` call (onboard_checks --dry-run is gh-free);
#   - it fires for a REGISTERED target only — it sits AFTER `in_scope || exit 0`.
#
# Driver mirrors §105's fake-root pattern: a self-contained shell copy carrying
# session_start.sh + hookrt + helpers + the REAL scripts/lib/onboard_checks.sh,
# with a git-fetch shim for the self-sync step. Each sub-case runs from a fixture
# TARGET dir (its own git repo); `in_scope` is made true by writing that target's
# path into the per-project registry that ghjig_registry_file resolves to under
# GHJIG_STATE_DIR_OVERRIDE. CLAUDE_PROJECT_DIR points at the target (hook context),
# GHJIG_ROOT at the fake root (where session_start.sh + its libs live).
#
# RED until Phase C: session_start.sh has NO SSOT code yet, so the present/nudge
# assertions (120a/120b) and the registered-only positive sense fail LOUD with a
# "(Phase C not wired)" message (mirrors §107/§118/§119's not-yet-wired pattern) —
# a clean intended failure, not a harness error. 120c (no-gh-call) and 120d's
# negative sense are falsifiable companions that may pass pre-Code.
S120_PROBE=$(cd "$(mktemp -d)" && pwd -P)
S120_FAKE_ROOT="$S120_PROBE/shell"
mkdir -p "$S120_FAKE_ROOT/.claude/hooks/helpers" \
         "$S120_FAKE_ROOT/.claude/state" \
         "$S120_FAKE_ROOT/scripts/lib"
cp "$SHELL_ROOT/.claude/hooks/session_start.sh" "$S120_FAKE_ROOT/.claude/hooks/" 2>/dev/null
cp "$SHELL_ROOT/.claude/hooks/hookrt.sh"         "$S120_FAKE_ROOT/.claude/hooks/" 2>/dev/null
for s120_h in log escape cwd_guard branch_guard; do
  cp "$SHELL_ROOT/.claude/hooks/helpers/$s120_h.sh" "$S120_FAKE_ROOT/.claude/hooks/helpers/" 2>/dev/null
done
# The candidate readers + audit-path lib so the §6.5(d) friction advisory degrades
# silently (the fixture target has no audit aggregate) without scanning the real repo.
cp "$SHELL_ROOT/scripts/narrowing_candidates.sh"  "$S120_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/promotion_candidates.sh"  "$S120_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/ceremony_candidates.sh"   "$S120_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/lib/audit_log_path.sh"    "$S120_FAKE_ROOT/scripts/lib/" 2>/dev/null
# The SSOT line consumes the REAL onboard_checks.sh --dry-run — copy it in so the
# line can compute from the fake root (Phase C will source/invoke it via SHELL_ROOT).
cp "$SHELL_ROOT/scripts/lib/onboard_checks.sh"    "$S120_FAKE_ROOT/scripts/lib/" 2>/dev/null

# git-fetch shim: no-op the self-sync fetch so the run stays offline/fast.
S120_GIT_SHIM="$S120_PROBE/bin"
S120_REAL_GIT=$(command -v git)
mkdir -p "$S120_GIT_SHIM"
cat > "$S120_GIT_SHIM/git" <<SHIM
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "fetch" ]; then exit 0; fi
done
exec '$S120_REAL_GIT' "\$@"
SHIM
chmod +x "$S120_GIT_SHIM/git"

# gh stub: a BROKEN gh — exits nonzero on every invocation. The SSOT path consumes
# onboard_checks --dry-run (gh-free), so its health line must still render under this
# broken gh (120c). A clean "sentinel never touched" assertion is not possible here:
# session_start.sh's pre-existing branch banner already shells `gh pr view`, which
# would confound an absolute no-call sentinel — so the gh-free property is asserted by
# RESULT (the SSOT line renders even though gh is broken) rather than by call-count.
cat > "$S120_GIT_SHIM/gh" <<'SHIM'
#!/bin/sh
exit 3
SHIM
chmod +x "$S120_GIT_SHIM/gh"

# s120_make_target <name> <register:0|1> [files…] → echoes the target path.
# Builds a git-repo fixture target, drops the named SSOT files, and (when
# register=1) writes its path into the per-project registry that ghjig_registry_file
# resolves to under GHJIG_STATE_DIR_OVERRIDE=<target>/.claude/ghjig-state.
s120_make_target() {
  s120_t=$(cd "$(mktemp -d)" && pwd -P)
  mkdir -p "$s120_t/.claude/ghjig-state"
  (
    cd "$s120_t" || exit 1
    git init -q
    git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
  )
  shift 2 2>/dev/null || true
  for s120_f in "$@"; do
    printf '# %s\n' "$s120_f" > "$s120_t/$s120_f"
  done
  [ "${s120_reg:-}" = 1 ] && printf '%s\n' "$s120_t" > "$s120_t/.claude/ghjig-state/registry.txt"
  printf '%s\n' "$s120_t"
}

# s120_run <target> → drives the fake-root session_start.sh from <target>'s cwd
# with <target> registered + in scope; echoes captured stdout (the SSOT line, if any).
s120_run() {
  (
    cd "$1" || exit 1
    export GHJIG_ROOT_OVERRIDE="$S120_FAKE_ROOT"
    export CLAUDE_PROJECT_DIR="$1"
    export GHJIG_STATE_DIR_OVERRIDE="$1/.claude/ghjig-state"
    export PATH="$S120_GIT_SHIM:$PATH"
    touch "$S120_FAKE_ROOT/.claude/state/last-shell-fetched" 2>/dev/null
    bash "$S120_FAKE_ROOT/.claude/hooks/session_start.sh" 2>/dev/null
  )
}

if [ ! -f "$S120_FAKE_ROOT/.claude/hooks/session_start.sh" ] \
   || [ ! -f "$S120_FAKE_ROOT/scripts/lib/onboard_checks.sh" ]; then
  ng "120a: SSOT present line — fake-root setup failed (Phase C not wired) (#460)"
  ng "120b: SSOT-nudge on absent SPEC.md — fake-root setup failed (#460)"
  ng "120c: SSOT path makes no gh call — fake-root setup failed (#460)"
  ng "120d: SSOT line is registered-only — fake-root setup failed (#460)"
else
  # 120a (present; RED until Code): a REGISTERED target with BOTH MISSION.md and
  # SPEC.md → output carries the SSOT health line (a line with `SSOT:` and `✓`).
  s120_reg=1
  S120_BOTH=$(s120_make_target both 1 MISSION.md SPEC.md)
  s120a_out=$(s120_run "$S120_BOTH")
  if printf '%s\n' "$s120a_out" | grep -F 'SSOT:' | grep -Fq '✓'; then
    ok "120a: SessionStart emits the SSOT-present health line (SSOT: … ✓) on a registered both-present target (#460)"
  else
    ng "120a: no SSOT-present health line emitted — Phase C not wired (#460)"
  fi

  # 120b (nudge; RED until Code): a REGISTERED target with MISSION.md but NO SPEC.md
  # → a prominent SPEC-first nudge line prefixed `SSOT-nudge`.
  S120_NOSPEC=$(s120_make_target nospec 1 MISSION.md)
  s120b_out=$(s120_run "$S120_NOSPEC")
  if printf '%s\n' "$s120b_out" | grep -q 'SSOT-nudge'; then
    ok "120b: SessionStart emits an SSOT-nudge line when SPEC.md is absent (#460)"
  else
    ng "120b: no SSOT-nudge line emitted on absent SPEC.md — Phase C not wired (#460)"
  fi

  # 120c (no-gh-call; RED until Code): drive the both-present target with gh stubbed
  # to FAIL (exit 3) + drop a sentinel on every invocation. The SSOT path consumes
  # onboard_checks --dry-run, which is gh-free, so the SSOT health line MUST still
  # render even though every gh shell-out fails. We cannot attribute the pre-existing
  # branch-banner `gh pr view` to the SSOT path, so the gh-free property is verified
  # by RESULT: the SSOT line renders under a broken gh. Pre-Code no line renders →
  # this fails LOUD for the right reason (Phase C not wired), and post-Code it is the
  # falsifiable proof that the SSOT line does not depend on a working gh.
  s120c_out=$(s120_run "$S120_BOTH")
  if printf '%s\n' "$s120c_out" | grep -Eq 'SSOT:|SSOT-nudge'; then
    ok "120c: SSOT line renders under a broken/failing gh (onboard_checks --dry-run is gh-free) (#460)"
  else
    ng "120c: SSOT line did not render under a broken gh — Phase C not wired (gh-free path unproven) (#460)"
  fi

  # 120d (registered-only): an UNREGISTERED cwd (not in the registry) → session_start
  # exits at `in_scope || exit 0` BEFORE any SSOT line, so neither SSOT: nor SSOT-nudge
  # appears. Negative sense holds pre-Code (vacuously) and is the falsifiable twin of
  # 120a's positive sense once Code lands.
  s120_reg=0
  S120_UNREG=$(s120_make_target unreg 0 MISSION.md SPEC.md)
  s120d_out=$(s120_run "$S120_UNREG")
  if printf '%s\n' "$s120d_out" | grep -Eq 'SSOT:|SSOT-nudge'; then
    ng "120d: an SSOT line leaked on an UNREGISTERED cwd (must sit after in_scope || exit 0) (#460)"
  else
    ok "120d: no SSOT line on an unregistered cwd (registered-only, after in_scope) (#460)"
  fi
  unset s120_reg
fi
rm -rf "$S120_PROBE"

# ---------- §121: spec_drift_candidates.sh code-vs-SPEC drift detector (#462) ----------
# Phase B (Test). Drives the FORTHCOMING measure-first reader scripts/spec_drift_candidates.sh
# (Execution #462, Directive #455) on a synthetic git fixture (offline, local git, mirrors
# §107's ceremony fixture). Contract: it greps SPEC.md for referenced repo paths, then flags
# a "code-ahead drift" candidate = a commit that touched a referenced path WITHOUT co-touching
# SPEC.md. Output: indented `  <path> | drift-commits=N` cluster lines (the §6.5(d) advisory
# grep shape) or a sentinel; always exit 0, fail-open. Detection only (no /reconcile-spec, no
# session_start wiring here).
# RED until Phase C: with the script absent the guard fails LOUD on every assertion.
S121_SCRIPT="$SHELL_ROOT/scripts/spec_drift_candidates.sh"
if [ ! -f "$S121_SCRIPT" ]; then
  ng "121a: divergence commit (touches a SPEC-referenced path, not SPEC.md) → candidate — scripts/spec_drift_candidates.sh missing (Phase C not landed) (#462)"
  ng "121b: co-commit (touches the path AND SPEC.md) → NOT a candidate — script missing (#462)"
  ng "121c: output is the §6.5(d) grep cluster shape — script missing (#462)"
  ng "121d: fail-open on non-repo / absent dir / clean repo → sentinel + exit 0 — script missing (#462)"
else
  S121_DIR=$(mktemp -d)
  S121_REPO="$S121_DIR/repo"
  mkdir -p "$S121_REPO"
  (
    cd "$S121_REPO" || exit 1
    git init -q
    gc() { git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q "$@"; }
    # Commit 1: SPEC.md references scripts/foo.sh + scripts/bar.sh, added with both files
    # (co-touches SPEC → contributes no drift).
    printf 'SPEC referencing scripts/foo.sh and scripts/bar.sh\n' > SPEC.md
    mkdir -p scripts; printf 'foo\n' > scripts/foo.sh; printf 'bar\n' > scripts/bar.sh
    git add SPEC.md scripts/foo.sh scripts/bar.sh; gc -m 'init: spec + scripts'
    # Commit 2: DIVERGENCE — modify scripts/foo.sh only, not SPEC.md → foo.sh drift candidate.
    printf 'foo2\n' >> scripts/foo.sh; git add scripts/foo.sh; gc -m 'change foo only'
    # Commit 3: CO-COMMIT — modify scripts/bar.sh AND SPEC.md together → bar.sh NOT a candidate.
    printf 'bar2\n' >> scripts/bar.sh; printf 'spec note\n' >> SPEC.md
    git add scripts/bar.sh SPEC.md; gc -m 'change bar + update spec'
  )
  s121_out=$(bash "$S121_SCRIPT" "$S121_REPO" 2>/dev/null); s121_rc=$?

  # 121a: divergence path scripts/foo.sh surfaces as a drift candidate.
  if [ "$s121_rc" = 0 ] && printf '%s\n' "$s121_out" | grep -q 'scripts/foo.sh' \
     && printf '%s\n' "$s121_out" | grep -qi 'drift'; then
    ok "121a: surfaces scripts/foo.sh (touched without co-touching SPEC.md) as a drift candidate (#462)"
  else
    ng "121a: did not surface the scripts/foo.sh drift candidate (rc=$s121_rc) (#462)"
  fi
  # 121b: co-commit path scripts/bar.sh is NOT surfaced (it co-touched SPEC.md).
  if ! printf '%s\n' "$s121_out" | grep -q 'scripts/bar.sh'; then
    ok "121b: omits scripts/bar.sh (co-committed with SPEC.md — not drift) (#462)"
  else
    ng "121b: scripts/bar.sh leaked as a candidate despite co-touching SPEC.md (#462)"
  fi
  # 121c: output carries the §6.5(d) advisory cluster shape.
  if printf '%s\n' "$s121_out" | grep -qE '^[[:space:]]+.+\|.+='; then
    ok "121c: emits the §6.5(d) grep cluster shape (  <path> | drift-commits=N) (#462)"
  else
    ng "121c: output not in the §6.5(d) cluster shape (#462)"
  fi
  # 121d: fail-open — non-repo dir, absent dir, and a clean repo (no drift) all exit 0 with a sentinel.
  bash "$S121_SCRIPT" "$S121_DIR" >/dev/null 2>&1; s121_e1=$?       # exists, not a git repo
  bash "$S121_SCRIPT" "$S121_DIR/nope" >/dev/null 2>&1; s121_e2=$?  # absent
  s121_clean=$(mktemp -d)
  ( cd "$s121_clean" && git init -q && printf 'no refs\n' > SPEC.md \
    && git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m 'chore: init' )
  s121_clean_out=$(bash "$S121_SCRIPT" "$s121_clean" 2>/dev/null); s121_e3=$?
  if [ "$s121_e1" = 0 ] && [ "$s121_e2" = 0 ] && [ "$s121_e3" = 0 ] \
     && printf '%s\n' "$s121_clean_out" | grep -qi 'no spec-drift\|none'; then
    ok "121d: fail-open — non-repo/absent dir + clean repo degrade to a sentinel, exit 0 (#462)"
  else
    ng "121d: fail-open broke (non-repo=$s121_e1 absent=$s121_e2 clean=$s121_e3) (#462)"
  fi
  rm -rf "$S121_DIR" "$s121_clean"
fi

# ---------- §122: /reconcile-spec command contract (#464) ----------
# Phase B (Test). Asserts the STRUCTURE/contract of the forthcoming
# .claude/commands/reconcile-spec.md (Execution #464, Directive #455) — the drift
# classification + user-gated SPEC correction command. It deliberately does NOT
# assert classification CORRECTNESS (that is agent judgment, like /onboard's SSOT
# drafting); it greps the command file for the stable contract tokens the SPEC §5.27
# contract also fixes: the three named dispositions, the user-approval gate, the
# never-edit-SPEC-on-code-wrong invariant, the unattended no-auto-apply rule, and the
# spec-reconcile audit category. RED until Phase C (the command file is absent).
S122_CMD="$SHELL_ROOT/.claude/commands/reconcile-spec.md"
if [ ! -f "$S122_CMD" ]; then
  ng "122a: reconcile-spec.md exists + frontmatter — command file missing (Phase C not landed) (#464)"
  ng "122b: encodes the three dispositions (spec-ahead/code-ahead/code-wrong) — file missing (#464)"
  ng "122c: user-approval gate + never-edit-SPEC-on-code-wrong invariant — file missing (#464)"
  ng "122d: unattended no-auto-apply rule + spec-reconcile audit category — file missing (#464)"
else
  # 122a: file present with description + argument-hint frontmatter.
  if grep -qE '^description:' "$S122_CMD" && grep -qE '^argument-hint:' "$S122_CMD"; then
    ok "122a: reconcile-spec.md has description + argument-hint frontmatter (#464)"
  else
    ng "122a: reconcile-spec.md missing frontmatter (#464)"
  fi
  # 122b: the three named dispositions are encoded.
  if grep -qF 'spec-ahead' "$S122_CMD" && grep -qF 'code-ahead' "$S122_CMD" \
     && grep -qF 'code-wrong' "$S122_CMD"; then
    ok "122b: encodes the three dispositions (spec-ahead / code-ahead-correct / code-wrong) (#464)"
  else
    ng "122b: missing one of the three disposition tokens (#464)"
  fi
  # 122c: the user-approval gate + the never-edit-SPEC-on-code-wrong invariant are present.
  if grep -qiE 'approv' "$S122_CMD" && grep -qiE 'never edit|not edit|no SPEC edit|never .*SPEC' "$S122_CMD"; then
    ok "122c: states the user-approval gate + the never-edit-SPEC-on-code-wrong invariant (#464)"
  else
    ng "122c: missing the approval gate or the never-edit-on-code-wrong invariant (#464)"
  fi
  # 122d: the unattended no-auto-apply rule + the spec-reconcile audit category.
  if grep -qiE 'unattended' "$S122_CMD" && grep -qiE 'auto-apply|self-approve|park' "$S122_CMD" \
     && grep -qF 'spec-reconcile' "$S122_CMD"; then
    ok "122d: states the unattended no-auto-apply rule + names the spec-reconcile audit category (#464)"
  else
    ng "122d: missing the unattended no-auto-apply rule or the spec-reconcile audit category (#464)"
  fi
fi

# ---------- §123: SessionStart friction advisory surfaces the spec-drift count (#466) ----------
# Phase B (Test). Phase C will wire scripts/spec_drift_candidates.sh into
# _session_friction_advisory in .claude/hooks/session_start.sh — adding it to the
# reader set (alongside narrowing/promotion/ceremony) under the SAME timeout
# envelope and the existing once-per-session last-friction-surfaced stamp — and when
# spec-drift candidates exist the advisory line reports the count (text containing
# `spec-drift candidate`, e.g. `N spec-drift candidate(s)`). SPEC §6.5(d), Directive #455.
#
# 123a (wiring; mirrors §107f): static grep — Phase C must reference the reader in
# session_start.sh. RED now (not yet referenced).
# 123b (count surfaces on seeded drift): drive session_start.sh headlessly (mirrors the
# §105 friction driver — self-contained fake shell root with its own git repo + registry,
# a git shim that no-ops fetch, GHJIG_STATE_DIR_OVERRIDE/CLAUDE_PROJECT_DIR/
# SESSION_START_FRICTION_TTL forcing the once-per-session advisory to compute via an
# absent stamp) against a fake root whose repo carries a SEEDED code-ahead drift: a
# SPEC.md referencing scripts/foo.sh + a later commit that modified scripts/foo.sh
# WITHOUT co-touching SPEC.md. The REAL spec_drift_candidates.sh (carried into the root,
# pointed at the project repo) thus returns a candidate, so once wired the advisory text
# must contain `spec-drift candidate`. RED now — session_start.sh does not run the reader.
if grep -q 'spec_drift_candidates.sh' "$SHELL_ROOT/.claude/hooks/session_start.sh"; then
  ok "123a: session_start.sh wires spec_drift_candidates.sh into the friction advisory (#466)"
else
  ng "123a: session_start.sh does not invoke spec_drift_candidates.sh — drift reader not wired (#466)"
fi

S123_PROBE=$(mktemp -d)
S123_FAKE_ROOT="$S123_PROBE/shell"
mkdir -p "$S123_FAKE_ROOT/.claude/hooks/helpers" \
         "$S123_FAKE_ROOT/.claude/state" \
         "$S123_FAKE_ROOT/.claude/audit" \
         "$S123_FAKE_ROOT/scripts/lib"
cp "$SHELL_ROOT/.claude/hooks/session_start.sh" "$S123_FAKE_ROOT/.claude/hooks/"
cp "$SHELL_ROOT/.claude/hooks/hookrt.sh" "$S123_FAKE_ROOT/.claude/hooks/" 2>/dev/null
for h in log escape cwd_guard branch_guard; do
  cp "$SHELL_ROOT/.claude/hooks/helpers/$h.sh" "$S123_FAKE_ROOT/.claude/hooks/helpers/" 2>/dev/null
done
# Carry the candidate readers (incl. the drift reader under test) + their path lib.
cp "$SHELL_ROOT/scripts/narrowing_candidates.sh" "$S123_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/promotion_candidates.sh" "$S123_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/ceremony_candidates.sh" "$S123_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/spec_drift_candidates.sh" "$S123_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/lib/audit_log_path.sh" "$S123_FAKE_ROOT/scripts/lib/" 2>/dev/null
: > "$S123_FAKE_ROOT/.claude/state/registry.txt"
# Seed a code-ahead drift INTO the fake-root repo (it is also $CLAUDE_PROJECT_DIR, so the
# drift reader run with no arg mines this history): SPEC.md references scripts/foo.sh,
# then a later commit modifies scripts/foo.sh WITHOUT co-touching SPEC.md.
(
  cd "$S123_FAKE_ROOT" || exit 1
  git init -q
  gc() { git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q "$@"; }
  printf 'SPEC referencing scripts/foo.sh\n' > SPEC.md
  printf 'foo\n' > scripts/foo.sh
  git add SPEC.md scripts/foo.sh; gc -m 'init: spec + foo'
  printf 'foo2\n' >> scripts/foo.sh; git add scripts/foo.sh; gc -m 'change foo only (code-ahead drift)'
)
S123_GIT_SHIM="$S123_PROBE/bin"
REAL_GIT_123=$(command -v git)
mkdir -p "$S123_GIT_SHIM"
cat > "$S123_GIT_SHIM/git" <<SHIM
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "fetch" ]; then exit 0; fi
done
exec '$REAL_GIT_123' "\$@"
SHIM
chmod +x "$S123_GIT_SHIM/git"

if [ ! -f "$S123_FAKE_ROOT/.claude/hooks/session_start.sh" ] \
   || [ ! -f "$S123_FAKE_ROOT/scripts/spec_drift_candidates.sh" ] \
   || ! command -v jq >/dev/null 2>&1; then
  ng "123b: jq missing or fake-root/drift-reader setup failed — cannot drive the §6.5(d) advisory (#466)"
else
  S123_STATE="$S123_PROBE/state"
  mkdir -p "$S123_STATE/audit"
  rm -f "$S123_STATE/last-friction-surfaced"   # absent stamp → force the once-per-session compute
  s123_out=$(
    export GHJIG_ROOT_OVERRIDE="$S123_FAKE_ROOT"
    export PATH="$S123_GIT_SHIM:$PATH"
    export CLAUDE_PROJECT_DIR="$S123_FAKE_ROOT"
    export GHJIG_STATE_DIR_OVERRIDE="$S123_STATE"
    export SESSION_START_FRICTION_TTL=21600
    touch "$S123_FAKE_ROOT/.claude/state/last-shell-fetched" 2>/dev/null
    bash "$S123_FAKE_ROOT/.claude/hooks/session_start.sh" 2>/dev/null
  )
  if printf '%s\n' "$s123_out" | grep -qi 'spec-drift candidate'; then
    ok "123b: §6.5(d) advisory reports the spec-drift candidate count on seeded code-ahead drift (#466)"
  else
    ng "123b: §6.5(d) advisory did not surface the spec-drift count — reader not wired into session_start.sh (#466)"
  fi
fi
rm -rf "$S123_PROBE"

# ---------- §65k: post-merge Release verify (#471) ----------
# §65k covers the #471 read-only, fail-open post-merge Release verify:
#  (1) The documented `gh release create` one-liner (release.md §82 + SPEC §18
#      §1422) must carry NO `--verify-tag` flag (#448): the tag and Release are
#      made together from --target, so --verify-tag would always abort a fresh
#      release. The docs ALSO carry explanatory prose ("No `--verify-tag` (#448):
#      that flag aborts `gh release create` …") that embeds BOTH tokens in one
#      line — so a naive `gh release create.*--verify-tag` grep false-positives on
#      the prose. The grep-lock therefore anchors on the COMMAND form
#      (`^[[:space:]]*gh release create`), which the prose lines (starting `**No`
#      / `Re-running`) do not match. Mirrors the §65i premise-lock shape: a
#      premise-lock proves the bad command form WOULD be caught if reintroduced.
#  (2) scripts/release_verify.sh <X.Y.Z> (Phase C) is a read-only, fail-open
#      post-merge verify: one `gh release view "vX.Y.Z" --json tagName,body`
#      query, advisory-only, exits 0 on EVERY path. Four arms: tag+non-empty body
#      → `ok` line; empty/whitespace body → "empty notes" advisory; gh "release
#      not found" → "no Release found" advisory; any other gh failure → fail-open
#      advisory. A PATH-overlay `gh` stub (mirrors §29/§118) keyed on argv drives
#      each arm.
# RED expectation pre-Phase-C: 65k-1 (grep-lock) PASSES now — the Doc commit
# already removed the flag, so it is the standing regression guard. 65k-2..5 fail
# LOUD via a script-absent guard (mirrors §107/§118) because release_verify.sh is
# absent until Phase C.

# §65k-1 — grep-lock: no `gh release create … --verify-tag` COMMAND in release.md
# or SPEC.md, NOT tripped by the explanatory prose. Anchor on the command form.
s65k_release="$SHELL_ROOT/.claude/commands/release.md"
s65k_spec="$SHELL_ROOT/SPEC.md"
# Command-form lines: optional leading whitespace then `gh release create`.
s65k_bad=$(grep -hE '^[[:space:]]*gh release create' "$s65k_release" "$s65k_spec" 2>/dev/null \
  | grep -c -- '--verify-tag')
# Premise lock: a literal bad command line WOULD be caught by the same matcher.
s65k_premise=$(printf 'gh release create v1.2.3 --verify-tag --target X\n' \
  | grep -E '^[[:space:]]*gh release create' | grep -c -- '--verify-tag')
if [ "$s65k_bad" = "0" ] && [ "$s65k_premise" -ge 1 ]; then
  ok "65k-1: documented gh release create command carries no --verify-tag flag; premise-lock detects the bad form (#471)"
else
  ng "65k-1: grep-lock failed (bad-command-hits=$s65k_bad premise=$s65k_premise; want 0/≥1) (#471)"
fi

# §65k-2..5 — drive scripts/release_verify.sh under a PATH-overlay `gh` stub.
S65K_SCRIPT="$SHELL_ROOT/scripts/release_verify.sh"
if [ ! -f "$S65K_SCRIPT" ]; then
  ng "65k-2: tag present + non-empty body → ok line, exit 0 — scripts/release_verify.sh missing (Phase C not landed) (#471)"
  ng "65k-3: gh 'release not found' → no-Release advisory, exit 0 — script missing (#471)"
  ng "65k-4: empty/whitespace body → empty-notes advisory, exit 0 — script missing (#471)"
  ng "65k-5: generic gh failure → fail-open advisory, exit 0 — script missing (#471)"
else
  S65K_DIR=$(cd "$(mktemp -d)" && pwd -P)
  S65K_SHIM="$S65K_DIR/bin"
  S65K_STATE="$S65K_DIR/state"
  mkdir -p "$S65K_SHIM" "$S65K_STATE"
  # Smoke shim for release_verify.sh. State files under $S65K_STATE drive `gh
  # release view`: mode=ok|empty|notfound|error selects the response.
  cat > "$S65K_SHIM/gh" <<'SHIM'
#!/bin/sh
case "$*" in
  *"release view"*)
    mode=$(cat "$S65K_STATE/mode" 2>/dev/null)
    case "$mode" in
      ok)       printf '{"tagName":"v0.2.0","body":"notes here"}\n' ;;
      empty)    printf '{"tagName":"v0.2.0","body":""}\n' ;;
      notfound) echo 'release not found' >&2; exit 1 ;;
      *)        echo 'HTTP 500: something broke' >&2; exit 1 ;;
    esac
    ;;
esac
exit 0
SHIM
  chmod +x "$S65K_SHIM/gh"

  # s65k_run <mode> → echoes the script's stdout+stderr (advisories may go either);
  # sets s65k_rc to its exit code. gh resolves via PATH (shim first).
  s65k_run() {
    printf '%s\n' "$1" > "$S65K_STATE/mode"
    s65k_out=$(
      PATH="$S65K_SHIM:$PATH" S65K_STATE="$S65K_STATE" \
        bash "$S65K_SCRIPT" 0.2.0 2>&1
    ); s65k_rc=$?
  }

  # 65k-2: tag present + non-empty body → exit 0 AND an `ok` marker in output.
  s65k_run ok
  if [ "$s65k_rc" = "0" ] && printf '%s\n' "$s65k_out" | grep -qi 'ok'; then
    ok "65k-2: present tag + non-empty body → ok marker, exit 0 (#471)"
  else
    ng "65k-2: verify-ok arm failed (rc=$s65k_rc out='$s65k_out'; want exit 0 + ok marker) (#471)"
  fi

  # 65k-3: gh 'release not found' → exit 0 AND an advisory naming the missing Release.
  s65k_run notfound
  if [ "$s65k_rc" = "0" ] && printf '%s\n' "$s65k_out" | grep -qi 'no Release found'; then
    ok "65k-3: gh 'release not found' → no-Release advisory, exit 0 (#471)"
  else
    ng "65k-3: no-Release arm failed (rc=$s65k_rc out='$s65k_out'; want exit 0 + Release advisory) (#471)"
  fi

  # 65k-4: empty body → exit 0 AND an advisory naming empty notes.
  s65k_run empty
  if [ "$s65k_rc" = "0" ] && printf '%s\n' "$s65k_out" | grep -qi 'empty'; then
    ok "65k-4: empty/whitespace body → empty-notes advisory, exit 0 (#471)"
  else
    ng "65k-4: empty-notes arm failed (rc=$s65k_rc out='$s65k_out'; want exit 0 + empty-notes advisory) (#471)"
  fi

  # 65k-5: generic gh failure → exit 0 + a fail-open advisory (never blocks).
  s65k_run error
  if [ "$s65k_rc" = "0" ] && printf '%s\n' "$s65k_out" | grep -qiE 'advisor|unable|could not|fail|warn|skip'; then
    ok "65k-5: generic gh failure → fail-open advisory, exit 0 (#471)"
  else
    ng "65k-5: fail-open arm failed (rc=$s65k_rc out='$s65k_out'; want exit 0 + fail-open advisory) (#471)"
  fi

  # 65k-6: jq-absent guard. Drive the notes-present mode (gh returns a non-empty
  # body) but with `jq` SHADOWED by a nonzero-exit stub first on PATH — so the
  # script cannot parse `.body` and must NOT misfire the empty-notes advisory.
  # RED pre-Code: release_verify.sh has no jq-absent guard, so a missing/broken jq
  # leaves body="" and the "empty notes" advisory falsely fires. The Code phase
  # adds the guard (skip the notes check when jq is unavailable) → GREEN.
  cat > "$S65K_SHIM/jq" <<'JQSHIM'
#!/bin/sh
echo 'jq: shadowed (smoke jq-absent arm)' >&2
exit 127
JQSHIM
  chmod +x "$S65K_SHIM/jq"
  s65k_run ok
  rm -f "$S65K_SHIM/jq"
  if [ "$s65k_rc" = "0" ] && ! printf '%s\n' "$s65k_out" | grep -qi 'empty notes'; then
    ok "65k-6: jq-absent → no false empty-notes advisory, exit 0 (#471)"
  else
    ng "65k-6: jq-absent guard missing — false empty-notes advisory fired (rc=$s65k_rc out='$s65k_out'; want exit 0 + no 'empty notes') (#471)"
  fi
  rm -rf "$S65K_DIR"
fi

# ---------- §125: file-based in-agent skip token — the hook-side READER (#479) ----------
# Phase B (Test), RED-first against the current (no-reader) escape.sh. The Code
# phase will extend should_skip <cat> to consult, AFTER the $SKIP_HOOKS check, a
# per-category token at $(ghjig_state_dir)/escape/<cat>.token: four KEY=VALUE keys
# (category, reason, cmd_fingerprint, created), honored iff ALL hold — file
# present+readable; exactly the four keys; category==requested==filename;
# cmd_fingerprint non-empty AND a substring of the hook-exported $ESCAPE_BIND_CMD
# (the raw command); created numeric AND now-created <= 60; bind-cmd non-empty. On
# honor: audit_log escape <cat> skip "<reason>" → delete the token → skip. Token
# is consumed-on-read (deleted on honor AND on stale/malformed reject). Pure-bash
# reader; fail-safe-to-block on any doubt. Bash-tool path ONLY.
#
# WHY a dedicated driver (esc_hook_run) and fixture repo: §15's hook_run cds into
# $TMP/fake on a NON-protected branch, so the `branch` matcher never fires there.
# The honor path is exercised against a genuinely-blocked op — a commit on a
# protected branch (release/9.9.9) — mirroring §15's "escape against a real block"
# discipline. The driver keeps GHJIG_STATE_DIR_OVERRIDE=$SMOKE_STATE inherited (NOT
# setting CLAUDE_PROJECT_DIR), so the hook's ghjig_state_dir() resolves to the SAME
# isolated dir we write the token under — testing the READER independently of
# scripts/ghjig_skip.sh (Code phase, absent). Tokens are written DIRECTLY with printf.
#
# EXPECTED pre-Code RED set: 125-1 (honor), 125-2-first (consume — first call must
# be allowed, which needs honor), 125-5a (python-free honor), 125-8 (audit). The
# fail-safe arms (125-3/4/5b/6/7) are GREEN both pre and post Code (the current
# escape.sh has no reader → every token is ignored → block stands).

# ESC_HOOK now defined in _preamble.sh (#600).
ESC_REPO=$(cd "$(mktemp -d)" && pwd -P)
ESC_TOKEN_DIR="$SMOKE_STATE/escape"
esc_git() { git -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
(
  cd "$ESC_REPO" || exit 1
  git init -q
  git checkout -q -b release/9.9.9 2>/dev/null || git checkout -q release/9.9.9
  esc_git commit --allow-empty -q -m "init"
) || ng "125: protected fixture repo setup failed (#479)"
# Register the fixture under the isolated registry so out-of-scope concerns don't
# interfere; the branch matcher is what we exercise here.
grep -qxF "$ESC_REPO" "$SMOKE_REG" 2>/dev/null || printf '%s\n' "$ESC_REPO" >> "$SMOKE_REG"

# Non-vacuity guard: the isolated escape dir MUST resolve under $SMOKE_STATE, or
# every token write below would land somewhere the hook never reads and the arms
# would green on nothing. Assert the seam loudly before any token is written.
if [ -n "$SMOKE_STATE" ] && [ -d "$SMOKE_STATE" ]; then
  mkdir -p "$ESC_TOKEN_DIR"
  ok "125: isolated escape token dir resolves under \$SMOKE_STATE (seam, #479)"
else
  ng "125: cannot resolve isolated escape state dir — token arms would be vacuous (#479)"
fi

# Sanity: the fixture must really be on a protected branch (else the branch
# matcher never fires and the honor arms would test nothing).
esc_repo_branch=$(cd "$ESC_REPO" && git symbolic-ref --short HEAD 2>/dev/null)
if printf '%s' "$esc_repo_branch" | grep -qE "^(${PROTECTED_BRANCH_PATTERN})$"; then
  ok "125: fixture on protected branch '$esc_repo_branch' (honor arms exercise a real block, #479)"
else
  ng "125: fixture NOT on a protected branch ('$esc_repo_branch') — honor arms vacuous (#479)"
fi

# Driver: run the PreToolUse hook against a Bash command FROM the protected repo,
# with the isolated state override inherited. Echoes the hook exit code.
esc_hook_run() {
  local _cmd="$1"
  (
    cd "$ESC_REPO" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$_cmd" | jq -Rs .)" \
      | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$ESC_HOOK" >/dev/null 2>&1
    printf '%s' "$?"
  )
}

# Write a token file with EXACTLY the supplied KEY=VALUE lines.
# Usage: esc_write_token <category> <line...> ; writes $ESC_TOKEN_DIR/<category>.token
esc_write_token() {
  local _cat="$1"; shift
  mkdir -p "$ESC_TOKEN_DIR"
  : > "$ESC_TOKEN_DIR/$_cat.token"
  local _ln
  for _ln in "$@"; do
    printf '%s\n' "$_ln" >> "$ESC_TOKEN_DIR/$_cat.token"
  done
}

# A protected-branch commit whose SUBJECT is a distinguishing fingerprint
# substring (NOT a bare verb). The fingerprint must be a substring of THIS cmd.
ESC_CMD='git commit --allow-empty -m "chore: release 9.9.9 cut"'
ESC_FP='chore: release 9.9.9 cut'

# 125-1. HONORED happy-path (RED until Code): a valid `branch` token disarms the
# protected-branch commit block → allowed (rc 0). Pre-Code: no reader → blocked.
esc_write_token branch \
  "category=branch" \
  "reason=in-agent escape token" \
  "cmd_fingerprint=$ESC_FP" \
  "created=$(date +%s)"
esc_before=$(audit_lines); [ -z "$esc_before" ] && esc_before=0
esc_rc1=$(esc_hook_run "$ESC_CMD")
if [ "$esc_rc1" = "0" ]; then
  ok "125-1: valid branch token honored — protected commit allowed (#479)"
else
  ng "125-1: valid branch token NOT honored (rc=$esc_rc1) — RED until Code (#479)"
fi

# 125-8. AUDIT emission (RED until Code): the honored skip from 125-1 wrote
# exactly one escape/skip/branch record carrying the token's reason.
esc_after=$(audit_lines); [ -z "$esc_after" ] && esc_after=0
esc_delta=$((esc_after - esc_before))
if [ "$esc_delta" -ge 1 ] \
   && [ "$(tail -n "$esc_delta" "$REAL_AUDIT" 2>/dev/null | grep -c '"event":"escape"')" -ge 1 ] \
   && tail -n "$esc_delta" "$REAL_AUDIT" 2>/dev/null | grep '"event":"escape"' | grep -q '"category":"branch"' \
   && tail -n "$esc_delta" "$REAL_AUDIT" 2>/dev/null | grep '"event":"escape"' | grep -q 'in-agent escape token'; then
  ok "125-8: honored skip emits an escape/branch audit record with the token reason (#479)"
else
  ng "125-8: no escape/branch audit record for the honored token (delta=$esc_delta) — RED until Code (#479)"
fi

# 125-2. NO standing bypass / consume-on-read (RED-first part + GREEN part):
#   (a) after 125-1's honor, the token file no longer exists (consumed);
#   (b) re-driving the SAME command now BLOCKS (rc 2) — no persistent bypass.
# Pre-Code: the reader never consumes (the token still sits there) AND the first
# call already blocked, so (b) is trivially true but (a) is RED.
if [ ! -e "$ESC_TOKEN_DIR/branch.token" ]; then
  ok "125-2a: honored token consumed (file deleted) — RED until Code (#479)"
else
  ng "125-2a: token NOT consumed after honor — standing bypass risk (#479)"
fi
esc_rc2=$(esc_hook_run "$ESC_CMD")
if [ "$esc_rc2" = "2" ]; then
  ok "125-2b: re-driving the same command after consume → blocked (no standing bypass) (#479)"
else
  ng "125-2b: token granted a standing bypass (rc=$esc_rc2) (#479)"
fi

# 125-3. FAIL-SAFE: absent token → blocked (GREEN pre+post — regression guard).
rm -f "$ESC_TOKEN_DIR/branch.token"
esc_rc3=$(esc_hook_run "$ESC_CMD")
if [ "$esc_rc3" = "2" ]; then
  ok "125-3: no token → protected commit blocked (fail-safe, #479)"
else
  ng "125-3: protected commit allowed with NO token (rc=$esc_rc3) (#479)"
fi

# 125-4. FAIL-SAFE: malformed token → blocked AND consumed.
#   (a) missing a required key, (b) an unknown extra key, (c) non-numeric created.
# Each must block (GREEN pre+post); post-Code each must also be consumed (the
# reader deletes a rejected token). The consume assertion is RED pre-Code (no
# reader to delete) — but it sits with the malformed fail-safe family by intent.
esc_malformed_block_ok=1
esc_malformed_consume_ok=1
# (a) missing cmd_fingerprint
esc_write_token branch "category=branch" "reason=x" "created=$(date +%s)"
[ "$(esc_hook_run "$ESC_CMD")" = "2" ] || esc_malformed_block_ok=0
[ -e "$ESC_TOKEN_DIR/branch.token" ] && esc_malformed_consume_ok=0
# (b) unknown extra key
esc_write_token branch "category=branch" "reason=x" "cmd_fingerprint=$ESC_FP" "created=$(date +%s)" "bogus=1"
[ "$(esc_hook_run "$ESC_CMD")" = "2" ] || esc_malformed_block_ok=0
[ -e "$ESC_TOKEN_DIR/branch.token" ] && esc_malformed_consume_ok=0
# (c) non-numeric created
esc_write_token branch "category=branch" "reason=x" "cmd_fingerprint=$ESC_FP" "created=not-a-number"
[ "$(esc_hook_run "$ESC_CMD")" = "2" ] || esc_malformed_block_ok=0
[ -e "$ESC_TOKEN_DIR/branch.token" ] && esc_malformed_consume_ok=0
rm -f "$ESC_TOKEN_DIR/branch.token"
if [ "$esc_malformed_block_ok" = 1 ]; then
  ok "125-4-block: malformed token (missing/unknown key, non-numeric created) → blocked (fail-safe, #479)"
else
  ng "125-4-block: a malformed token did NOT fail safe to block (#479)"
fi
if [ "$esc_malformed_consume_ok" = 1 ]; then
  ok "125-4-consume: malformed token deleted on read — RED until Code (#479)"
else
  ng "125-4-consume: malformed token NOT consumed (#479)"
fi

# 125-5. FAIL-SAFE under python3-absent (honor part RED until Code). The reader is
# pure-bash, so shadowing python3 off PATH must NOT change either verdict:
#   (a) a VALID token still HONORS (allowed rc 0) — RED until Code;
#   (b) a malformed token still fail-safe-BLOCKS — GREEN pre+post.
ESC_NOPY=$(mktemp -d)
# A PATH with only a python3 shim that fails — proves the reader doesn't shell out
# to python3. Keep the real toolchain reachable via the shim dir prepended only.
cat > "$ESC_NOPY/python3" <<'NOPY'
#!/usr/bin/env bash
echo "python3 disabled for this test" >&2
exit 127
NOPY
chmod +x "$ESC_NOPY/python3"
esc_pyfree_hook_run() {
  local _cmd="$1"
  (
    cd "$ESC_REPO" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$_cmd" | jq -Rs .)" \
      | PATH="$ESC_NOPY:$PATH" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$ESC_HOOK" >/dev/null 2>&1
    printf '%s' "$?"
  )
}
# (a) valid token, python3 shadowed → still honors.
esc_write_token branch \
  "category=branch" \
  "reason=python-free honor" \
  "cmd_fingerprint=$ESC_FP" \
  "created=$(date +%s)"
esc_rc5a=$(esc_pyfree_hook_run "$ESC_CMD")
if [ "$esc_rc5a" = "0" ]; then
  ok "125-5a: valid token honored with python3 off PATH (pure-bash reader) — RED until Code (#479)"
else
  ng "125-5a: token not honored when python3 absent (rc=$esc_rc5a) — RED until Code (#479)"
fi
rm -f "$ESC_TOKEN_DIR/branch.token"
# (b) malformed token, python3 shadowed → still blocks.
esc_write_token branch "category=branch" "reason=x" "created=$(date +%s)"
esc_rc5b=$(esc_pyfree_hook_run "$ESC_CMD")
if [ "$esc_rc5b" = "2" ]; then
  ok "125-5b: malformed token still fail-safe-blocks with python3 absent (#479)"
else
  ng "125-5b: malformed token honored when python3 absent (rc=$esc_rc5b) (#479)"
fi
rm -f "$ESC_TOKEN_DIR/branch.token"
rm -rf "$ESC_NOPY"

# 125-6. Does NOT disarm — stale TTL / fingerprint-mismatch (GREEN pre; post the
# reader must reject these specific tokens even though present).
#   (a) created older than the 60s TTL → blocked.
esc_write_token branch \
  "category=branch" \
  "reason=stale" \
  "cmd_fingerprint=$ESC_FP" \
  "created=$(( $(date +%s) - 120 ))"
esc_rc6a=$(esc_hook_run "$ESC_CMD")
if [ "$esc_rc6a" = "2" ]; then
  ok "125-6a: token older than 60s TTL does not disarm — blocked (#479)"
else
  ng "125-6a: stale (>60s) token wrongly honored (rc=$esc_rc6a) (#479)"
fi
rm -f "$ESC_TOKEN_DIR/branch.token"
#   (b) cmd_fingerprint NOT a substring of the driven command → blocked.
esc_write_token branch \
  "category=branch" \
  "reason=mismatch" \
  "cmd_fingerprint=this fingerprint is not in the command" \
  "created=$(date +%s)"
esc_rc6b=$(esc_hook_run "$ESC_CMD")
if [ "$esc_rc6b" = "2" ]; then
  ok "125-6b: fingerprint not a substring of the command does not disarm — blocked (#479)"
else
  ng "125-6b: fingerprint-mismatch token wrongly honored (rc=$esc_rc6b) (#479)"
fi
rm -f "$ESC_TOKEN_DIR/branch.token"

# 125-7. Category-scoping (GREEN pre+post): a valid `branch` token does NOT disarm
# a DIFFERENT category's block on the same command. Drive a commit with a bad
# (non-CC) subject so the commit-format matcher blocks; the branch token must not
# rescue it. The fingerprint is a substring of THIS command.
ESC_BAD_CMD='git commit --allow-empty -m "not a conventional subject 9.9.9"'
esc_write_token branch \
  "category=branch" \
  "reason=wrong-category" \
  "cmd_fingerprint=not a conventional subject 9.9.9" \
  "created=$(date +%s)"
esc_rc7=$(esc_hook_run "$ESC_BAD_CMD")
if [ "$esc_rc7" = "2" ]; then
  ok "125-7: a branch token does not disarm a commit-format block (category-scoped) (#479)"
else
  ng "125-7: branch token leaked across categories (rc=$esc_rc7) (#479)"
fi
rm -f "$ESC_TOKEN_DIR/branch.token"

# 125-9. WRITER round-trip — the documented writer `scripts/ghjig_skip.sh` produces
# a token the reader honors for the matching command and that is consumed on read
# (closes the writer side; §125-1..8 exercise the reader via printf tokens).
rm -f "$ESC_TOKEN_DIR/branch.token"
"$SHELL_ROOT/scripts/ghjig_skip.sh" branch "$ESC_FP" "round-trip via ghjig_skip" >/dev/null 2>&1
esc_rc9=$(esc_hook_run "$ESC_CMD")
if [ "$esc_rc9" = "0" ] && [ ! -e "$ESC_TOKEN_DIR/branch.token" ]; then
  ok "125-9: ghjig_skip.sh writer round-trip — token honored + consumed (#479)"
else
  ng "125-9: ghjig_skip.sh writer token not honored/consumed (rc=$esc_rc9) (#479)"
fi
# 125-9b. WRITER footgun-reducer — ghjig_skip.sh refuses a <8-char fingerprint
# (exit != 0) and writes NO token.
rm -f "$ESC_TOKEN_DIR/branch.token"
if ! "$SHELL_ROOT/scripts/ghjig_skip.sh" branch "short" "x" >/dev/null 2>&1 \
   && [ ! -e "$ESC_TOKEN_DIR/branch.token" ]; then
  ok "125-9b: ghjig_skip.sh refuses a <8-char fingerprint and writes no token (#479)"
else
  ng "125-9b: ghjig_skip.sh wrote a token for a too-short fingerprint (footgun) (#479)"
fi
# 125-9c. WRITER category validation — ghjig_skip.sh rejects a category outside
# ^[A-Za-z0-9,_-]+$ (the category is interpolated into the token path, so a
# ../-traversal value must be refused: exit != 0, no traversed file written) (#551).
rm -f "$ESC_TOKEN_DIR/branch.token"
esc_traverse_probe="$ESC_TOKEN_DIR/../pwned_551"
rm -f "$esc_traverse_probe.token"
if ! "$SHELL_ROOT/scripts/ghjig_skip.sh" "../pwned_551" "$ESC_FP" "traversal probe" >/dev/null 2>&1 \
   && [ ! -e "$esc_traverse_probe.token" ]; then
  ok "125-9c: ghjig_skip.sh rejects a ../-traversal category and writes no token (#551)"
else
  ng "125-9c: ghjig_skip.sh honored an invalid/traversal category (footgun) (#551)"
fi
# 125-9d. WRITER category validation — a legitimate hyphenated category
# (out-of-scope) is still accepted and writes its token (regression guard) (#551).
rm -f "$ESC_TOKEN_DIR/out-of-scope.token"
if "$SHELL_ROOT/scripts/ghjig_skip.sh" "out-of-scope" "$ESC_FP" "valid category" >/dev/null 2>&1 \
   && [ -e "$ESC_TOKEN_DIR/out-of-scope.token" ]; then
  ok "125-9d: ghjig_skip.sh accepts a valid hyphenated category (#551)"
else
  ng "125-9d: ghjig_skip.sh rejected a legitimate category (over-tightened) (#551)"
fi
rm -f "$ESC_TOKEN_DIR/out-of-scope.token"

# 125-10. created OUT-OF-RANGE does NOT disarm (security regression, #479 N=3
# review): a leading-zero value (`$(( ))` parses it as octal) and a >=2^63 value
# (overflows bash 3.2 arithmetic, wraps negative) both pass a naive all-digit
# check but break the TTL/future-date arithmetic — they MUST fail-safe-block.
rm -f "$ESC_TOKEN_DIR/branch.token"
esc_write_token branch "category=branch" "reason=octal probe" "cmd_fingerprint=$ESC_FP" "created=0$(date +%s)"
esc_rc10a=$(esc_hook_run "$ESC_CMD")
rm -f "$ESC_TOKEN_DIR/branch.token"
esc_write_token branch "category=branch" "reason=overflow probe" "cmd_fingerprint=$ESC_FP" "created=99999999999999999999"
esc_rc10b=$(esc_hook_run "$ESC_CMD")
rm -f "$ESC_TOKEN_DIR/branch.token"
if [ "$esc_rc10a" = "2" ] && [ "$esc_rc10b" = "2" ]; then
  ok "125-10: out-of-range created (leading-zero octal / >=2^63 overflow) fail-safe-blocks (#479)"
else
  ng "125-10: out-of-range created wrongly honored (octal rc=$esc_rc10a overflow rc=$esc_rc10b) (#479)"
fi

# ---------- §125-NOOVERRIDE: writer/reader state-dir alignment in LIVE (no GHJIG_STATE_DIR_OVERRIDE) (#483) ----------
# Phase B (Test), RED-first against current Code. The §125-1..10 arms above pin
# GHJIG_STATE_DIR_OVERRIDE=$SMOKE_STATE on BOTH the printf writer and the reader,
# so they never exercise the path resolution that LIVE actually takes — and that
# masked #483: in LIVE the writer (scripts/ghjig_skip.sh, a Bash-tool subprocess)
# has CLAUDE_PROJECT_DIR UNSET → ghjig_state_dir empty → it falls back to
# $SHELL_ROOT/.claude/state/escape/<cat>.token, while the reader (the PreToolUse
# hook) has CLAUDE_PROJECT_DIR SET → ghjig_state_dir=<repo>/.claude/ghjig-state →
# reads <repo>/.claude/ghjig-state/escape/<cat>.token. The two diverge → the #479
# channel is non-functional in LIVE.
#
# This arm reproduces the LIVE divergence WITHOUT re-masking it: NO override on
# either side, and CLAUDE_PROJECT_DIR explicitly UNSET for the writer (forcing it
# to DERIVE the project dir) while SET for the reader (the live hook condition).
# Both run with cwd INSIDE a throwaway, self-contained git repo on a protected
# branch, so `git rev-parse --show-toplevel` from inside resolves to that repo.
#
# Pre-Code RED: the writer with no CPD falls to $SHELL_ROOT/.claude/state/escape/
# (the REAL shell root) while the reader looks under <fixture>/.claude/ghjig-state/
# → token not found → BLOCKED (rc 2). Post-Code: ghjig_skip.sh derives
# CLAUDE_PROJECT_DIR via git-toplevel when unset, and both empty-ghjig_state_dir
# fallbacks align to .claude/ghjig-state → writer + reader agree → honored (rc 0).
ESC_NOOV_REPO=$(cd "$(mktemp -d)" && pwd -P)
(
  cd "$ESC_NOOV_REPO" || exit 1
  git init -q
  git checkout -q -b release/9.9.9 2>/dev/null || git checkout -q release/9.9.9
  esc_git commit --allow-empty -q -m "init"
) || ng "125-NOOVERRIDE: protected fixture repo setup failed (#483)"
# The reader runs WITHOUT the $SMOKE_STATE override, so it resolves its registry
# per-project: ghjig_registry_file → CLAUDE_PROJECT_DIR/.claude/ghjig-state/registry.txt.
# Register the fixture THERE (not just $SMOKE_REG, which the no-override reader
# never reads) so the protected-branch matcher is in scope and actually FIRES —
# otherwise the hook fails open (out-of-scope) and the honor assertion is vacuous.
mkdir -p "$ESC_NOOV_REPO/.claude/ghjig-state"
printf '%s\n' "$ESC_NOOV_REPO" > "$ESC_NOOV_REPO/.claude/ghjig-state/registry.txt"

ESC_NOOV_FP='chore: release 9.9.9 no-override cut'
ESC_NOOV_CMD='git commit --allow-empty -m "chore: release 9.9.9 no-override cut"'
# The two divergent destinations: where the live writer (no CPD) falls back, and
# where the live reader (CPD set) looks.
ESC_NOOV_LIVE_WRITER_TOKEN="$SHELL_ROOT/.claude/state/escape/branch.token"
ESC_NOOV_READER_DIR="$ESC_NOOV_REPO/.claude/ghjig-state/escape"

# Non-vacuity guard: with NO token armed, the reader MUST block the protected
# commit (rc 2). If it allows here, the matcher isn't firing (scope/branch wrong)
# and the honor arm below would green on nothing.
esc_noov_rc_pre=$(
  cd "$ESC_NOOV_REPO" || exit 1
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' "$ESC_NOOV_CMD" | jq -Rs .)" \
    | env -u GHJIG_STATE_DIR_OVERRIDE \
        CLAUDE_PROJECT_DIR="$ESC_NOOV_REPO" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$ESC_HOOK" >/dev/null 2>&1
  printf '%s' "$?"
)
if [ "$esc_noov_rc_pre" = "2" ]; then
  ok "125-NOOVERRIDE: no-override reader blocks the protected commit absent a token (matcher fires, non-vacuous) (#483)"
else
  ng "125-NOOVERRIDE: no-override reader did NOT block absent a token (rc=$esc_noov_rc_pre) — honor arm would be vacuous (#483)"
fi

# Writer: NO override, CLAUDE_PROJECT_DIR explicitly UNSET, cwd inside the fixture.
# Post-Code ghjig_skip.sh must derive the project dir from git-toplevel → fixture.
( cd "$ESC_NOOV_REPO" && env -u GHJIG_STATE_DIR_OVERRIDE -u CLAUDE_PROJECT_DIR \
    GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
    "$SHELL_ROOT/scripts/ghjig_skip.sh" branch "$ESC_NOOV_FP" 'no-override probe' >/dev/null 2>&1 )

# Reader: drive the protected-branch commit through the real PreToolUse hook with
# GHJIG_STATE_DIR_OVERRIDE UNSET and CLAUDE_PROJECT_DIR=<fixture> (the live hook
# condition), cwd in the fixture. The fingerprint is a substring of the command.
esc_noov_rc=$(
  cd "$ESC_NOOV_REPO" || exit 1
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' "$ESC_NOOV_CMD" | jq -Rs .)" \
    | env -u GHJIG_STATE_DIR_OVERRIDE \
        CLAUDE_PROJECT_DIR="$ESC_NOOV_REPO" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$ESC_HOOK" >/dev/null 2>&1
  printf '%s' "$?"
)

if [ "$esc_noov_rc" = "0" ] && [ ! -e "$ESC_NOOV_READER_DIR/branch.token" ]; then
  ok "125-NOOVERRIDE: writer (no CPD) and reader (CPD set) resolve the same state dir — token honored + consumed (#483)"
else
  ng "125-NOOVERRIDE: writer/reader state-dir divergence — token NOT honored (rc=$esc_noov_rc) — RED until Code (#483)"
fi
# CLEANUP: the pre-Code writer (no CPD) writes into the REAL
# $SHELL_ROOT/.claude/state/escape/ (outside $SMOKE_STATE) — remove any stray
# token so no escape token is left in the real tree. Also drop the fixture token.
rm -f "$ESC_NOOV_LIVE_WRITER_TOKEN"
rm -f "$ESC_NOOV_READER_DIR/branch.token"
rm -rf "$ESC_NOOV_REPO"

# ---------- §124: escape docs state the in-harness reality, not a false "survives in-harness" claim (#478) ----------
# Placed before §110 (the README floor guard, which runs last by design). Both
# SKIP_HOOKS escape forms (leading env-prefix + trailing `# ghjig:skip=…`
# sentinel) are stripped before reaching the PreToolUse hook's tool_input.command
# in the Claude Code Bash tool — the parsers are correct in isolation, but the
# harness never delivers the prefix/sentinel. So the docs must NOT claim the
# trailing sentinel "survives the live Claude Code Bash tool" / is the "reliable
# in-harness escape" / works "in-harness"; they must state the stripped reality.
# Both-granularity + non-vacuous: NG if any surface still asserts the false claim,
# OR if the corrected "stripped before the hook" statement is absent, OR if a
# scanned surface is missing.
s124_surfaces="$SHELL_ROOT/.claude/CLAUDE.md $SHELL_ROOT/SPEC.md $SHELL_ROOT/.claude/hooks/helpers/escape.sh"
s124_missing=0
for _s124_f in $s124_surfaces; do [ -f "$_s124_f" ] || s124_missing=$((s124_missing + 1)); done
# NEGATIVE arm — no surface may positively claim the trailing sentinel works in-harness.
s124_false=$(grep -rElE 'survives the .{0,15}live Claude Code Bash tool|reliable in-harness escape|sentinel[^.]{0,40}in-harness' $s124_surfaces 2>/dev/null | wc -l | tr -d ' ')
# POSITIVE arm — the corrected reality (both in-command forms stripped before the hook) must be present.
s124_fixed=$(grep -rElE 'stripped before .{0,40}(hook|tool_input)|both .{0,40}forms .{0,25}stripped' $s124_surfaces 2>/dev/null | wc -l | tr -d ' ')
if [ "$s124_missing" = 0 ] && [ "$s124_false" = 0 ] && [ "$s124_fixed" -ge 1 ]; then
  ok "124: escape docs state the in-harness reality (both forms stripped); no false 'survives in-harness' claim (#478)"
else
  ng "124: escape docs still claim the trailing sentinel works in-harness, or lack the stripped-reality statement (missing=$s124_missing false=$s124_false fixed=$s124_fixed) (#478)"
fi

# ---------- §126: implementer subagent (Phase C) default-route channel contract (#486 / Directive #477 / #492) ----------
# Placed before §110 (the README floor guard, which runs last by design). Phase B
# (Test) for EI-1 under Directive #477. The Doc phase already landed the contract
# into .claude/agents/implementer.md, .claude/commands/implement.md, SPEC, and
# CLAUDE.md, so these are REGRESSION LOCKS (style of §117 / the agent-doc checks),
# not RED-first: this declarative feat's Code is n/a, and this Test phase guards
# the declarative contract. NON-VACUOUS throughout: each arm fails LOUD when a
# scanned file is missing rather than greening on nothing scanned.

# §126a — implementer.md must declare the channel-defining contract: artifact-only
# / manifest-driven input, churn-discard, and a structured return. Anchors are
# stable tokens read from the file (manifest, artifact-only premise, churn-discard,
# structured return, plan-deviations, discoveries).
S126_AGENT="$SHELL_ROOT/.claude/agents/implementer.md"
if [ ! -f "$S126_AGENT" ]; then
  ng "126a: .claude/agents/implementer.md missing — implementer contract absent (#486)"
else
  s126a_manifest=$(grep -ciE 'manifest' "$S126_AGENT" 2>/dev/null | tr -d ' ')
  s126a_artifact=$(grep -ciE 'artifact-only|no knowledge of the main assistant|not from the main assistant' "$S126_AGENT" 2>/dev/null | tr -d ' ')
  s126a_churn=$(grep -ciE 'churn[ -]?discard|working churn|never re-enters' "$S126_AGENT" 2>/dev/null | tr -d ' ')
  s126a_struct=$(grep -ciE 'structured return' "$S126_AGENT" 2>/dev/null | tr -d ' ')
  s126a_dev=$(grep -ciE 'deviation' "$S126_AGENT" 2>/dev/null | tr -d ' ')
  s126a_disc=$(grep -ciE 'discover' "$S126_AGENT" 2>/dev/null | tr -d ' ')
  if [ "$s126a_manifest" -ge 1 ] && [ "$s126a_artifact" -ge 1 ] && [ "$s126a_churn" -ge 1 ] \
     && [ "$s126a_struct" -ge 1 ] && [ "$s126a_dev" -ge 1 ] && [ "$s126a_disc" -ge 1 ]; then
    ok "126a: implementer.md declares manifest-driven artifact-only input + churn-discard + structured return (deviations/discoveries) (#486)"
  else
    ng "126a: implementer.md missing a contract token (manifest=$s126a_manifest artifact=$s126a_artifact churn=$s126a_churn struct=$s126a_struct dev=$s126a_dev disc=$s126a_disc) (#486)"
  fi
fi

# §126b — /implement command must document manifest assembly (plan + failing test +
# named files), spawning the implementer subagent, absorbing ONLY the structured
# return, and the DEFAULT-with-opt-out invariant (#492 default-flip; see the inline
# note below for the flip from the superseded opt-in lock).
S126_CMD="$SHELL_ROOT/.claude/commands/implement.md"
if [ ! -f "$S126_CMD" ]; then
  ng "126b: .claude/commands/implement.md missing — /implement contract absent (#486)"
else
  s126b_manifest=$(grep -ciE 'manifest' "$S126_CMD" 2>/dev/null | tr -d ' ')
  s126b_plan=$(grep -ciE 'plan' "$S126_CMD" 2>/dev/null | tr -d ' ')
  s126b_test=$(grep -ciE 'failing .{0,12}test|phase-?b test' "$S126_CMD" 2>/dev/null | tr -d ' ')
  s126b_spawn=$(grep -ciE 'subagent_type: *implementer|implementer subagent' "$S126_CMD" 2>/dev/null | tr -d ' ')
  s126b_absorb=$(grep -ciE 'structured return|absorb' "$S126_CMD" 2>/dev/null | tr -d ' ')
  # #492: implement.md flipped from the opt-in invariant to default-with-opt-out
  # (Directive #477 signal-4 default-flip). The token now asserts the DEFAULT
  # posture + the documented opt-out, not the old opt-in language.
  s126b_default=$(grep -ciE 'default-with-opt-out|by default|opt-out' "$S126_CMD" 2>/dev/null | tr -d ' ')
  if [ "$s126b_manifest" -ge 1 ] && [ "$s126b_plan" -ge 1 ] && [ "$s126b_test" -ge 1 ] \
     && [ "$s126b_spawn" -ge 1 ] && [ "$s126b_absorb" -ge 1 ] && [ "$s126b_default" -ge 1 ]; then
    ok "126b: /implement documents manifest assembly + implementer spawn + structured-return absorb + DEFAULT-with-opt-out invariant (#486/#492)"
  else
    ng "126b: /implement missing a contract token (manifest=$s126b_manifest plan=$s126b_plan test=$s126b_test spawn=$s126b_spawn absorb=$s126b_absorb default=$s126b_default) (#486/#492)"
  fi
fi

# §126c — default-route guard (Directive #477 signal-4 default-flip, #492). The
# load-bearing arm is INVERTED from the old opt-in lock: the DEFAULT Code-phase
# flow now DOES route to the implementer. /work-on.md MUST dispatch the implementer
# (a Phase-C step naming the implementer subagent / routing to it) AND document the
# opt-out (trivial / glue edits stay in the main loop). The Stop/PostToolUse hook
# NEGATIVE is PRESERVED: auto-routing lives in the /work-on doc procedure ONLY,
# never in a hook (the native no-auto-invoke posture). The route grep keys on the
# dispatch phrasing (NOT a bare "/implement" — that already appears in work-on step
# 4.5's manifest read-back), so it stays 0 until the Phase-C routing step lands; the
# opt-out grep is likewise 0 until then — either unmet arm keeps §126c RED before the
# #492 Code phase. NON-VACUOUS: fails loud if /work-on.md is missing.
S126_WORKON="$SHELL_ROOT/.claude/commands/work-on.md"
if [ ! -f "$S126_WORKON" ]; then
  ng "126c: .claude/commands/work-on.md missing — cannot assert default-route (#486/#492)"
else
  # POSITIVE (#492): /work-on MUST dispatch the implementer for the Code phase by default.
  s126c_workon_route=$(grep -ciE 'subagent_type: *implementer|implementer subagent|invoke .{0,20}implementer' "$S126_WORKON" 2>/dev/null | tr -d ' ')
  # POSITIVE (#492): /work-on MUST document the opt-out for trivial / glue edits.
  s126c_optout=$(grep -ciE 'opt-out|stay in the main loop|trivial .{0,30}(glue|edit)' "$S126_WORKON" 2>/dev/null | tr -d ' ')
  # NEGATIVE (PRESERVED): no Stop / PostToolUse hook may auto-invoke the implementer.
  s126c_hook_route=$(grep -rilE 'subagent_type: *implementer|invoke .{0,20}implementer|implementer subagent' "$SHELL_ROOT"/.claude/hooks/stop.sh "$SHELL_ROOT"/.claude/hooks/post_tool_use.sh 2>/dev/null | wc -l | tr -d ' ')
  if [ "$s126c_workon_route" -ge 1 ] && [ "$s126c_optout" -ge 1 ] && [ "$s126c_hook_route" = 0 ]; then
    ok "126c: default Code-phase flow routes to implementer in /work-on (by default + documented opt-out) and NO Stop/PostToolUse hook auto-invokes it — #477 signal-4 default-flip (#492)"
  else
    ng "126c: default-route contract unmet (work-on-route=$s126c_workon_route opt-out=$s126c_optout hooks=$s126c_hook_route; want route>=1, opt-out>=1, hooks=0) (#492)"
  fi
fi

# ---------- §126d: implementer tree-safety hardening (#516, promoted from discussion #497) ----------
# RED-first (Phase B for #516): three Code-phase tokens absent until the #516 Code commit —
#   (1) implementer.md — affirmative path-scoped-add rule (never `git add -A`/`-u`; stage only manifest-named paths)
#   (2) implement.md   — pre-dispatch clean-tree surface/warn, explicitly NOT a hard block
#   (3) work-on.md     — the stale "pre-commit review checkpoint" wording replaced by "pre-ready"
# NON-VACUOUS: any missing file fails LOUD rather than greening on nothing scanned.
S126D_AGENT="$SHELL_ROOT/.claude/agents/implementer.md"
S126D_CMD="$SHELL_ROOT/.claude/commands/implement.md"
S126D_WORKON="$SHELL_ROOT/.claude/commands/work-on.md"
if [ ! -f "$S126D_AGENT" ] || [ ! -f "$S126D_CMD" ] || [ ! -f "$S126D_WORKON" ]; then
  ng "126d: implementer tree-safety file missing — cannot assert hardening (#516)"
else
  # (1) path-scoped-add: forbids -A/-u AND names manifest-scoped staging.
  s126d_noaddall=$(grep -ciE 'never.{0,40}git add -[Au]' "$S126D_AGENT" 2>/dev/null | tr -d ' ')
  s126d_scoped=$(grep -ciE 'manifest-named path|only the manifest' "$S126D_AGENT" 2>/dev/null | tr -d ' ')
  # (2) pre-dispatch surface/warn, explicitly not a hard block.
  s126d_surface=$(grep -ciE 'dirty .{0,12}tree|clean[ -]tree' "$S126D_CMD" 2>/dev/null | tr -d ' ')
  s126d_notblock=$(grep -ciE 'not a hard block|surface/warn' "$S126D_CMD" 2>/dev/null | tr -d ' ')
  # (3) wording: "pre-commit review checkpoint" gone (want 0), "pre-ready" present.
  s126d_precommit=$(grep -ciE 'pre-commit review checkpoint' "$S126D_WORKON" 2>/dev/null | tr -d ' ')
  s126d_preready=$(grep -ciE 'pre-ready' "$S126D_WORKON" 2>/dev/null | tr -d ' ')
  if [ "$s126d_noaddall" -ge 1 ] && [ "$s126d_scoped" -ge 1 ] \
     && [ "$s126d_surface" -ge 1 ] && [ "$s126d_notblock" -ge 1 ] \
     && [ "$s126d_precommit" = 0 ] && [ "$s126d_preready" -ge 1 ]; then
    ok "126d: implementer tree-safety hardened — path-scoped-add rule + pre-dispatch surface/warn + pre-ready wording (#516)"
  else
    ng "126d: tree-safety hardening incomplete (noaddall=$s126d_noaddall scoped=$s126d_scoped surface=$s126d_surface notblock=$s126d_notblock precommit=${s126d_precommit}[want 0] preready=$s126d_preready) (#516)"
  fi
fi

# ---------- §126e: implementer fail-open reversibility degradation lock (#517, promoted from discussion #496 Gap 2) ----------
# Regression lock (NOT RED-first — the contract already lives in the docs; this pins it
# against silent removal, §126a-style). The fail-open reversibility safety valve —
# "a missing implementer path degrades to main-loop authoring" — was leaned on IN LIEU
# OF the descoped A/B measurement (Directive #477), yet §126a-c never asserted it.
# Locked across all three documenting surfaces. NON-VACUOUS: any missing file fails LOUD.
S126E_CMD="$SHELL_ROOT/.claude/commands/implement.md"
S126E_WORKON="$SHELL_ROOT/.claude/commands/work-on.md"
S126E_AGENT="$SHELL_ROOT/.claude/agents/implementer.md"
if [ ! -f "$S126E_CMD" ] || [ ! -f "$S126E_WORKON" ] || [ ! -f "$S126E_AGENT" ]; then
  ng "126e: implementer fail-open file missing — cannot assert degradation contract (#517)"
else
  s126e_cmd=$(grep -ciE 'fail-open reversibility|degrades? to main-loop authoring' "$S126E_CMD" 2>/dev/null | tr -d ' ')
  s126e_workon=$(grep -ciE 'fail-open reversibility|degrades? to main-loop authoring' "$S126E_WORKON" 2>/dev/null | tr -d ' ')
  s126e_agent=$(grep -ciE 'fail-open reversibility|degrades? to main-loop authoring' "$S126E_AGENT" 2>/dev/null | tr -d ' ')
  if [ "$s126e_cmd" -ge 1 ] && [ "$s126e_workon" -ge 1 ] && [ "$s126e_agent" -ge 1 ]; then
    ok "126e: fail-open reversibility degradation contract documented across implement.md / work-on.md / implementer.md (#517)"
  else
    ng "126e: fail-open degradation contract missing a surface (implement=$s126e_cmd work-on=$s126e_workon implementer=$s126e_agent) (#517)"
  fi
fi

# ---------- §127: directive-level coding-memory loop contract (#488 / Directive #477) ----------
# Placed before §110 (the README floor guard, which runs last by design). Phase B
# (Test) for EI-2 under Directive #477. The Doc phase already landed the contract
# into .claude/commands/{reflect,work-on,implement}.md + SPEC §5.15/§5.3/§4.12, so
# these are REGRESSION LOCKS (style of §126a/b), not RED-first. NON-VACUOUS: each
# arm fails LOUD when its scanned file is missing rather than greening on nothing
# scanned. §127b keys on NON-colliding tokens (directive-level learnings / Parent
# Directive / manifest) so it never reintroduces the §126c landmine substrings.

# §127a — /reflect learnings-distill section. reflect.md must document the
# `### Learnings for the next Execution` section, the distillation heuristic
# (durable learning kept, churn NOT distilled), and that the implementer's
# structured-return discoveries are a source.
S127_REFLECT="$SHELL_ROOT/.claude/commands/reflect.md"
if [ ! -f "$S127_REFLECT" ]; then
  ng "127a: .claude/commands/reflect.md missing — learnings-distill contract absent (#488)"
else
  s127a_section=$(grep -ciE 'Learnings for the next Execution' "$S127_REFLECT" 2>/dev/null | tr -d ' ')
  s127a_durable=$(grep -ciE 'durable learning|outlives this PR' "$S127_REFLECT" 2>/dev/null | tr -d ' ')
  s127a_churn=$(grep -ciE 'Churn is NOT a learning|within-Execution churn|not be transcribed' "$S127_REFLECT" 2>/dev/null | tr -d ' ')
  s127a_disc=$(grep -ciE 'structured-return .{0,12}discoveries|discoveries' "$S127_REFLECT" 2>/dev/null | tr -d ' ')
  if [ "$s127a_section" -ge 1 ] && [ "$s127a_durable" -ge 1 ] && [ "$s127a_churn" -ge 1 ] && [ "$s127a_disc" -ge 1 ]; then
    ok "127a: /reflect documents Learnings-for-next-Execution section + durable/churn distillation heuristic + discoveries source (#488)"
  else
    ng "127a: /reflect missing a learnings-distill token (section=$s127a_section durable=$s127a_durable churn=$s127a_churn disc=$s127a_disc) (#488)"
  fi
fi

# §127b — /work-on read-back. work-on.md must document reading accumulated learnings
# from the Parent Directive and injecting them into the planner + the /implement
# manifest's `directive-level learnings` field. Keys on NON-colliding tokens
# (directive-level learnings / Parent Directive / manifest) that are independent of
# the §126c dispatch phrasing. NOTE (#492): as of the signal-4 default-flip, §126c
# now REQUIRES the implementer-dispatch phrasing in work-on.md (the default Phase-C
# route), so this file legitimately contains those substrings — §127b deliberately
# keys on its own disjoint tokens so the two sections stay consistent; it neither
# greps for nor depends on the dispatch phrasing.
S127_WORKON="$SHELL_ROOT/.claude/commands/work-on.md"
if [ ! -f "$S127_WORKON" ]; then
  ng "127b: .claude/commands/work-on.md missing — read-back contract absent (#488)"
else
  s127b_learnings=$(grep -ciE 'directive-level learnings' "$S127_WORKON" 2>/dev/null | tr -d ' ')
  s127b_readback=$(grep -ciE 'Parent Directive' "$S127_WORKON" 2>/dev/null | tr -d ' ')
  s127b_planner=$(grep -ciE 'planner' "$S127_WORKON" 2>/dev/null | tr -d ' ')
  s127b_manifest=$(grep -ciE 'manifest' "$S127_WORKON" 2>/dev/null | tr -d ' ')
  if [ "$s127b_learnings" -ge 1 ] && [ "$s127b_readback" -ge 1 ] && [ "$s127b_planner" -ge 1 ] && [ "$s127b_manifest" -ge 1 ]; then
    ok "127b: /work-on documents reading directive-level learnings from the Parent Directive + injecting into planner + the manifest field (#488)"
  else
    ng "127b: /work-on missing a read-back token (learnings=$s127b_learnings readback=$s127b_readback planner=$s127b_planner manifest=$s127b_manifest) (#488)"
  fi
fi

# §127c — /implement manifest field. implement.md must document the
# `directive-level learnings` field in the manifest contract.
S127_IMPL="$SHELL_ROOT/.claude/commands/implement.md"
if [ ! -f "$S127_IMPL" ]; then
  ng "127c: .claude/commands/implement.md missing — manifest-field contract absent (#488)"
else
  s127c_field=$(grep -ciE 'directive-level learnings' "$S127_IMPL" 2>/dev/null | tr -d ' ')
  s127c_manifest=$(grep -ciE 'manifest' "$S127_IMPL" 2>/dev/null | tr -d ' ')
  if [ "$s127c_field" -ge 1 ] && [ "$s127c_manifest" -ge 1 ]; then
    ok "127c: /implement documents the directive-level learnings field in the manifest contract (#488)"
  else
    ng "127c: /implement missing manifest-field token (field=$s127c_field manifest=$s127c_manifest) (#488)"
  fi
fi

# §127d — no-regression. The existing /reflect reflection sections must still be
# present in reflect.md (the Learnings section is additive, a fourth body section).
if [ ! -f "$S127_REFLECT" ]; then
  ng "127d: .claude/commands/reflect.md missing — cannot assert reflection-section no-regression (#488)"
else
  s127d_contrib=$(grep -ciE '### Contribution' "$S127_REFLECT" 2>/dev/null | tr -d ' ')
  s127d_signals=$(grep -ciE 'Success signals advanced' "$S127_REFLECT" 2>/dev/null | tr -d ' ')
  s127d_next=$(grep -ciE '### Next' "$S127_REFLECT" 2>/dev/null | tr -d ' ')
  if [ "$s127d_contrib" -ge 1 ] && [ "$s127d_signals" -ge 1 ] && [ "$s127d_next" -ge 1 ]; then
    ok "127d: /reflect existing reflection sections (Contribution / Success signals advanced / Next) intact after additive Learnings section (#488)"
  else
    ng "127d: /reflect lost an existing reflection section (contrib=$s127d_contrib signals=$s127d_signals next=$s127d_next) (#488)"
  fi
fi

# ---------- §128: directive-close matcher (#490) ----------
# A GitHub close keyword + Directive #N in a PR --body (inline) OR a commit
# message auto-closes the Directive at merge, bypassing /complete-directive's
# signal-evidence gate (§5.13). The directive-close matcher blocks that; an
# Execution Issue auto-closing on merge stays correct. Two vectors (PR body +
# commit message) × a 4-way matrix (Directive→block, Execution→allow,
# non-close mention→allow, fail-open). Mirrors the §44 PATH-overlay gh-mock
# fixture; GH_MOCK_FAIL=1 simulates gh down for the per-#N fail-open arm.
# Mock issues: #93 = directive (the protected Directive); #92 = enhancement
# (a non-Directive Execution-class Issue). KEY caution carried from plan
# review: the commit vector must exercise a close keyword in a commit BODY
# line (not just the subject) — extract_commit_subject is subject-only, so a
# subject-only test would never reach the body where GitHub actually parses
# the keyword. §128h/§128j cover the body-line and heredoc-body forms.
DC_DIR=$(mktemp -d)
DC_BIN="$DC_DIR/bin"
DC_TARGET="$DC_DIR/target"
DC_CACHE="$SMOKE_STATE/issue-type-cache"
DC_AUDIT="$DC_DIR/audit.jsonl"
mkdir -p "$DC_BIN" "$DC_TARGET"
DC_TARGET=$(cd "$DC_TARGET" && pwd -P)
( cd "$DC_TARGET" && git init -q && git checkout -q -b smoke-490-feature 2>/dev/null ) || true
printf '%s\n' "$DC_TARGET" >> "$SMOKE_REG"

cat > "$DC_BIN/gh" <<'DCMOCK'
#!/usr/bin/env bash
# Mock gh for §128 — same shape as §44: `gh issue view <n> --json labels`
# returns GH_MOCK_LABELS_<n>; `gh repo view` returns smoke-owner/smoke-repo.
emit() {
  local full="$1"; shift
  local expr="" next=0
  for a in "$@"; do
    if [ "$next" = 1 ]; then expr="$a"; next=0; continue; fi
    [ "$a" = "-q" ] && next=1
  done
  if [ -n "$expr" ] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$full" | jq -r "$expr" 2>/dev/null
  else
    printf '%s' "$full"
  fi
}
if [ "${GH_MOCK_FAIL:-}" = 1 ]; then exit 1; fi
case "${1:-}" in
  repo) [ "${2:-}" = view ] && emit '{"owner":{"login":"smoke-owner"},"name":"smoke-repo"}' "$@" ;;
  issue)
    if [ "${2:-}" = view ]; then
      issue="$3"; var="GH_MOCK_LABELS_${issue}"; labels="${!var:-}"
      arr="["; first=1; old_ifs="$IFS"; IFS=,
      for l in $labels; do
        [ -z "$l" ] && continue
        [ "$first" = 1 ] && first=0 || arr="$arr,"
        arr="$arr{\"name\":\"$l\"}"
      done
      IFS="$old_ifs"; arr="$arr]"
      emit "{\"labels\":$arr}" "$@"
    fi ;;
esac
exit 0
DCMOCK
chmod +x "$DC_BIN/gh"

# dc_run <cmd> [SKIP_HOOKS] — feed <cmd> to pre_tool_use.sh as a Bash tool call.
# Builds stdin JSON via python3 json.dumps so a command containing double
# quotes / newlines (every directive-close case does) round-trips safely.
dc_run() {
  local cmd="$1" skip="${2:-}" stdin_json
  stdin_json=$(CMD="$cmd" python3 -c 'import json,os; print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))')
  (
    cd "$DC_TARGET" || exit 0
    PATH="$DC_BIN:$PATH" \
    GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
    AUDIT_LOG_PATH="$DC_AUDIT" \
    GH_MOCK_LABELS_92="enhancement" \
    GH_MOCK_LABELS_93="directive" \
    GH_MOCK_FAIL="${GH_MOCK_FAIL:-}" \
    SKIP_HOOKS="$skip" \
    SKIP_REASON="${skip:+smoke-test}" \
      bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" <<< "$stdin_json"
  )
  return $?
}

if ! command -v python3 >/dev/null 2>&1; then
  ok "128: directive-close matrix skipped — python3 absent (dc_run JSON encoder unavailable) (#490)"
else
  # ---- PR-body vector (gh pr create / gh pr edit --body) ----
  rm -rf "$DC_CACHE"
  # 128a: Directive close-keyword in --body → block.
  rc=0; dc_run 'gh pr create --title "x" --body "Closes #93"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && ok "128a: directive-close blocks 'Closes #93' (Directive) in gh pr create --body (#490)" \
                || ng "128a: expected block(2) on Directive close-kw in PR body; got rc=$rc (#490)"

  # 128b: Execution close-keyword in --body → allow (the central over-block guard).
  rc=0; dc_run 'gh pr create --title "x" --body "Closes #92"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok "128b: directive-close allows 'Closes #92' (Execution) in PR body — over-block guard (#490)" \
                || ng "128b: expected allow(0) on Execution close-kw in PR body; got rc=$rc (#490)"

  # 128c: non-close mention of a Directive (Refs/advances) → allow.
  rc=0; dc_run 'gh pr create --title "x" --body "Refs #93 — advances #93 signal 3"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok "128c: directive-close allows 'Refs #93 / advances #93' (no close keyword) (#490)" \
                || ng "128c: expected allow(0) on non-close Directive mention; got rc=$rc (#490)"

  # 128d: fail-open — gh unavailable → allow even a would-be-blocked Directive.
  rm -rf "$DC_CACHE"; rc=0
  GH_MOCK_FAIL=1 dc_run 'gh pr create --title "x" --body "Closes #93"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok "128d: directive-close per-#N fail-open (allow) when gh is unavailable (#490)" \
                || ng "128d: expected fail-open allow(0) on gh failure; got rc=$rc (#490)"
  rm -rf "$DC_CACHE"

  # 128e: multiple #N — block if ANY referenced Issue is a Directive.
  rc=0; dc_run 'gh pr create --title "x" --body "Refs #92, closes #93"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && ok "128e: directive-close blocks when ANY close-kw #N is a Directive (Refs #92, closes #93) (#490)" \
                || ng "128e: expected block(2) when one of several #N is a Directive; got rc=$rc (#490)"

  # 128f: case-insensitive keyword.
  rc=0; dc_run 'gh pr create --title "x" --body "CLOSES #93"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && ok "128f: directive-close keyword match is case-insensitive (CLOSES #93) (#490)" \
                || ng "128f: expected block(2) on uppercase CLOSES #93; got rc=$rc (#490)"

  # 128g: SKIP_HOOKS=directive-close bypasses the block.
  rc=0; dc_run 'gh pr create --title "x" --body "Closes #93"' "directive-close" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok "128g: SKIP_HOOKS=directive-close bypasses the PR-body block (#490)" \
                || ng "128g: SKIP_HOOKS=directive-close should allow; got rc=$rc (#490)"

  # 128n: --body-file is a documented residual — NOT read, so not blocked.
  rc=0; dc_run 'gh pr create --title "x" --body-file notes-93.md' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok "128n: directive-close does not read --body-file (documented residual) (#490)" \
                || ng "128n: --body-file residual should not block; got rc=$rc (#490)"

  # ---- Commit-message vector (commit-format umbrella sub-check) ----
  # Runs on smoke-490-feature (non-protected) with a valid CC subject, so the
  # only thing that can block is the directive-close body scan.
  rm -rf "$DC_CACHE"
  # 128h: close keyword in a commit BODY line (2nd -m), NOT the subject → block.
  #       extract_commit_subject returns only "fix(#92): x"; the body must still be scanned.
  rc=0; dc_run 'git commit -m "fix(#92): x" -m "Closes #93"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && ok "128h: directive-close blocks a close-kw in a commit BODY line, not just the subject (#490)" \
                || ng "128h: expected block(2) on Directive close-kw in commit body; got rc=$rc (#490)"

  # 128i: Execution close-keyword in commit body → allow.
  rc=0; dc_run 'git commit -m "fix(#92): x" -m "Closes #92"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok "128i: directive-close allows 'Closes #92' (Execution) in commit body (#490)" \
                || ng "128i: expected allow(0) on Execution close-kw in commit body; got rc=$rc (#490)"

  # 128j: heredoc commit-message body carrying the close keyword → block.
  rc=0; dc_run 'git commit -m "$(cat <<'\''EOF'\''
fix(#92): x

resolves #93
EOF
)"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] && ok "128j: directive-close blocks a close-kw in a heredoc commit-message body (#490)" \
                || ng "128j: expected block(2) on Directive close-kw in heredoc body; got rc=$rc (#490)"

  # 128k: SKIP_HOOKS=directive-close bypasses the commit-vector block.
  rc=0; dc_run 'git commit -m "fix(#92): x" -m "Closes #93"' "directive-close" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok "128k: SKIP_HOOKS=directive-close bypasses the commit-message block (#490)" \
                || ng "128k: SKIP_HOOKS=directive-close should allow commit; got rc=$rc (#490)"

  # 128l: commit-vector fail-open — gh unavailable → allow.
  rm -rf "$DC_CACHE"; rc=0
  GH_MOCK_FAIL=1 dc_run 'git commit -m "fix(#92): x" -m "Closes #93"' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok "128l: directive-close commit vector fails open when gh is unavailable (#490)" \
                || ng "128l: expected fail-open allow(0) on gh failure (commit); got rc=$rc (#490)"
fi

# ---------- §129: recall routing disposition (#520) ----------
# Two arms. Arm (a) is RED-first — it scopes to the recall.md `description:` FRONTMATTER
# (the #520 Code lever), which is rewritten in the Code commit, so it stays NG until then
# even though the body prose already mentions "have we" / "before planning". Arm (b) is a
# regression-lock on the CLAUDE.md norm authored in the SAME Doc commit (green-at-Doc,
# §126a/§127a-style, NOT RED-first) and pins the thin SPEC §5.25 POINTER, not restated
# prose (§9 thin-pointer). NON-VACUOUS: a missing file fails LOUD.
S129_RECALL="$SHELL_ROOT/.claude/commands/recall.md"
S129_CLAUDE="$SHELL_ROOT/.claude/CLAUDE.md"
if [ ! -f "$S129_RECALL" ] || [ ! -f "$S129_CLAUDE" ]; then
  ng "129: recall-routing file missing — cannot assert routing disposition (#520)"
else
  # arm (a): the description: frontmatter line is trigger-oriented — "Use when" + a
  # user-ask shape + a self-identified/pre-plan shape, all WITHIN the description value.
  s129_desc=$(grep -E '^description:' "$S129_RECALL" 2>/dev/null | head -1)
  s129_usewhen=$(printf '%s' "$s129_desc" | grep -ciE 'use when' | tr -d ' ')
  s129_userask=$(printf '%s' "$s129_desc" | grep -ciE 'have we|what did we decide' | tr -d ' ')
  s129_selfid=$(printf '%s' "$s129_desc" | grep -ciE 'before planning|decided this before|before a decision|internally' | tr -d ' ')
  # arm (a2): AC2 (#524) — trigger asymmetry. The deep comment sweep must be
  # routable from EXPLICIT user intent yet EXCLUDED from the pre-planning reflex.
  # Pin the description carries a deep-trigger token (deep / comment / --deep) AND
  # ties it to explicit user intent (explicit / only / never … reflex). RED now:
  # the current single-tier description names neither. Scoped to the description
  # value so body prose cannot green it vacuously.
  s129_deeptok=$(printf '%s' "$s129_desc" | grep -ciE 'deep|comment|--deep' | tr -d ' ')
  s129_explicit=$(printf '%s' "$s129_desc" | grep -ciE 'explicit|only on|never .*reflex|not .*reflex' | tr -d ' ')
  # arm (b): CLAUDE.md recall-routing norm token + the thin SPEC §5.25 pointer.
  s129_norm=$(grep -ciE 'recall routing|recall-shaped' "$S129_CLAUDE" 2>/dev/null | tr -d ' ')
  s129_ptr=$(grep -ciE 'SPEC §5\.25' "$S129_CLAUDE" 2>/dev/null | tr -d ' ')
  # arm (c): #528 — the description carries the empty-light→deep ESCALATION rule.
  # The rule must be tied to an EMPTY light result (the trigger condition), not a
  # bare mention, and must NOT weaken arm (a2)'s explicit-only/never-reflex tokens
  # (which the escalation is scoped under — user-asked branch only). Scoped to the
  # description value so body prose cannot green it vacuously. Non-vacuous: the
  # pre-#528 description named neither token, so this was RED before the Doc edit.
  s129_escal=$(printf '%s' "$s129_desc" | grep -ciE 'escalat' | tr -d ' ')
  s129_emptytrig=$(printf '%s' "$s129_desc" | grep -ciE 'empty|no match' | tr -d ' ')
  if [ "$s129_usewhen" -ge 1 ] && [ "$s129_userask" -ge 1 ] && [ "$s129_selfid" -ge 1 ] \
     && [ "$s129_deeptok" -ge 1 ] && [ "$s129_explicit" -ge 1 ] \
     && [ "$s129_escal" -ge 1 ] && [ "$s129_emptytrig" -ge 1 ] \
     && [ "$s129_norm" -ge 1 ] && [ "$s129_ptr" -ge 1 ]; then
    ok "129: recall-routing disposition — trigger-oriented recall.md description (user-asked + self-identified + deep-on-explicit-intent-only + empty-light→deep escalation) + thin CLAUDE.md norm → SPEC §5.25 (#520, #524, #528)"
  else
    ng "129: recall-routing disposition incomplete (usewhen=$s129_usewhen userask=$s129_userask selfid=$s129_selfid deeptok=$s129_deeptok explicit=$s129_explicit escal=$s129_escal emptytrig=$s129_emptytrig norm=$s129_norm ptr=$s129_ptr) (#520, #524, #528)"
  fi
fi

# ---------- §130: SPEC §9.1-9.4 describe-and-point (no inlined template body) (#522) ----------
# RED-first: §9.1-9.4 historically INLINED the mission/issue/pr_body/adr template bodies —
# a second copy that drifted from the authoritative .claude/templates/* files. De-inline to
# the §9.6-9.8 describe+name-the-file pattern. This locks each §9.1-9.4 subsection to NAME
# its local template file. Block-scoped to §9.1..§9.5 so a path reference elsewhere in SPEC
# cannot green it vacuously. Distinct from §106 (which guards the §9.6-9.8 target-copy specs).
# NON-VACUOUS: SPEC.md missing → loud NG.
S130_SPEC="$SHELL_ROOT/SPEC.md"
if [ ! -f "$S130_SPEC" ]; then
  ng "130: SPEC.md missing — cannot assert §9.1-9.4 describe-and-point (#522)"
else
  s130_block=$(awk '/^### 9\.1 /{f=1} /^### 9\.5 /{f=0} f' "$S130_SPEC")
  s130_mission=$(printf '%s' "$s130_block" | grep -cE '\.claude/templates/mission\.md' | tr -d ' ')
  s130_issue=$(printf '%s' "$s130_block" | grep -cE '\.claude/templates/issue\.md' | tr -d ' ')
  s130_pr=$(printf '%s' "$s130_block" | grep -cE '\.claude/templates/pr_body\.md' | tr -d ' ')
  s130_adr=$(printf '%s' "$s130_block" | grep -cE '\.claude/templates/adr\.md' | tr -d ' ')
  if [ "$s130_mission" -ge 1 ] && [ "$s130_issue" -ge 1 ] && [ "$s130_pr" -ge 1 ] && [ "$s130_adr" -ge 1 ]; then
    ok "130: SPEC §9.1-9.4 name their .claude/templates/{mission,issue,pr_body,adr}.md (describe-and-point, no inlined body) (#522)"
  else
    ng "130: SPEC §9.1-9.4 not all pointing to their template file (mission=$s130_mission issue=$s130_issue pr_body=$s130_pr adr=$s130_adr) (#522)"
  fi
fi

# ---------- §131: /recall deep-tier comment sweep mechanism (#524, #526) ----------
# RED-first (#524); arm (d) is the #526 RED extension. All arms offline.
#   Arm (a) STATIC — the four mechanism invariants pinned by inspecting the helper
#     source (matching §111's static-grep discipline; a live gh comment fetch would
#     be flaky): (AC1/mechanism) a `--deep`-gated branch exists, it fetches
#     candidate comments via `gh issue view ... --json comments`, greps LOCALLY
#     with a FIXED-STRING match (`grep -F`, so dotted tokens like 3.12 are safe),
#     and stays bounded by RECALL_LIMIT.
#   Arm (b) BEHAVIORAL — OFF BY DEFAULT: with the flag ABSENT the output is
#     byte-identical to the light tier (no comment fetch fires). `gh` is stubbed to
#     a deterministic light-only responder that RECORDS any `issue view` call (the
#     deep-only fetch); a fired marker on the no-flag run is a leak. Mirrors the
#     §44i/§44j function-mock precedent (no network).
S131_HELPER="$SHELL_ROOT/.claude/hooks/helpers/recall.sh"
s131=1; s131_why=""
if [ ! -f "$S131_HELPER" ]; then
  s131=0; s131_why="${s131_why}helper-missing;"
else
  # arm (a): static mechanism invariants (AC1 + mechanism)
  grep -qE -- '--deep' "$S131_HELPER" || { s131=0; s131_why="${s131_why}no-deep-flag-branch;"; }
  grep -qE -- 'gh issue view.*--json[[:space:]]+[A-Za-z,]*comments' "$S131_HELPER" \
    || grep -qE -- '--json[[:space:]]+[A-Za-z,]*comments' "$S131_HELPER" \
    || { s131=0; s131_why="${s131_why}no-comment-fetch;"; }
  grep -qE 'grep[[:space:]]+-[A-Za-z]*F' "$S131_HELPER" || { s131=0; s131_why="${s131_why}no-fixed-string-grep;"; }
  grep -q 'RECALL_LIMIT' "$S131_HELPER" || { s131=0; s131_why="${s131_why}deep-not-bounded;"; }

  # arm (b): OFF-by-default — flag-absent output must not fetch comments.
  # `gh` is stubbed as a NAMED function then called in $(...) (the §44i precedent:
  # a `case` block cannot be defined inline inside command substitution on bash 3.2).
  s131_marker="$TMP/s131-deep-fetch-fired"
  # #524-shaped candidate: a closed issue whose TITLE surfaces via search, so the
  # light tier answers it; the issue-view arm (deep-only fetch) drops the marker.
  gh() {
    case "$*" in
      *'repo view'*) printf 'smoke-owner/smoke-repo\n' ;;
      *'search issues'*) printf '#517 pin toolchain to a fixed version\n' ;;
      *'search prs'*) : ;;
      *'issue view'*) : > "$s131_marker" ;;
      *) return 0 ;;
    esac
  }
  s131_run() {  # no flag → light tier only; must not touch the issue-view arm
    RECALL_LIMIT=5
    export RECALL_LIMIT s131_marker
    . "$S131_HELPER"
    recall_pointers "toolchain" 2>/dev/null
  }
  rm -f "$s131_marker" 2>/dev/null
  s131_out=$(s131_run)
  # OFF by default: no comment fetch on the flag-absent invocation.
  [ -f "$s131_marker" ] && { s131=0; s131_why="${s131_why}deep-fetch-fired-without-flag;"; }
  # light-tier output still carries the #517-shaped pointer (search-surfaced case, AC1).
  printf '%s' "$s131_out" | grep -q '#517' || { s131=0; s131_why="${s131_why}light-pointer-missing;"; }
  rm -f "$s131_marker" 2>/dev/null
  unset -f gh s131_run 2>/dev/null

  # arm (c): WITH --deep — the deep tier must (1) surface a NEW open-issue comment
  # pointer the closed-only light tier cannot reach, and (2) NEVER double-print a
  # closed issue the light tier already surfaced (dedup). #524 code-review fix.
  # Stub distinguishes the light call (--state closed) from the deep call (no
  # state → open+closed) so the deep candidate set is strictly broader.
  gh() {
    case "$*" in
      *'repo view'*) printf 'smoke-owner/smoke-repo\n' ;;
      *'search issues'*'--state closed'*) printf '#517 pin toolchain to a fixed version\n' ;;
      *'search issues'*) printf '#517 pin toolchain to a fixed version\n#8 python interpreter version\n' ;;
      *'search prs'*) : ;;
      *'issue view 8 '*|*'issue view 8') printf 'settled on python 3.14 over 3.12\n' ;;
      *'issue view 517 '*|*'issue view 517') printf 'python discussed in this thread too\n' ;;
      *'issue view'*) : ;;
      *) return 0 ;;
    esac
  }
  s131c_run() {
    RECALL_LIMIT=5; export RECALL_LIMIT
    . "$S131_HELPER"
    recall_pointers "python" --deep 2>/dev/null
  }
  s131c_out=$(s131c_run)
  # (1) NEW value: open issue #8 (unreachable by the closed-only light tier) surfaced.
  printf '%s\n' "$s131c_out" | grep -q '#8 ' || { s131=0; s131_why="${s131_why}deep-open-not-surfaced;"; }
  # (2) DEDUP / no double-print: the closed issue #517 appears exactly once.
  s131c_dupes=$(printf '%s\n' "$s131c_out" | grep -c '#517')
  [ "$s131c_dupes" = 1 ] || { s131=0; s131_why="${s131_why}deep-double-print(#517x$s131c_dupes);"; }
  unset -f gh s131c_run 2>/dev/null

  # arm (d) (#526): WITH --deep — a MULTI-TOKEN natural-language topic whose tokens
  # do NOT co-occur in any single issue must still reach a candidate. The stub
  # returns 0 for the whole-phrase candidate search (GitHub free-text AND semantics),
  # so the CURRENT code (no per-token fallback) never reaches #8 and this is RED.
  # The fix's stage-1 token-aware fallback re-queries per high-signal token, so the
  # token "interpreter" surfaces #8 and its comment matches. Assert surfaced + deduped.
  gh() {
    case "$*" in
      *'repo view'*) printf 'smoke-owner/smoke-repo\n' ;;
      # whole-phrase candidate search (light --state closed AND deep no-state) → 0 (AND).
      *'search issues'*'operational interpreter version choice'*) : ;;
      # per-token fallback: only the high-signal token "interpreter" hits a candidate.
      *'search issues'*'interpreter'*) printf '#8 python interpreter version\n' ;;
      *'search issues'*) : ;;   # other tokens (operational/version/choice) → 0
      *'search prs'*) : ;;
      *'issue view 8 '*|*'issue view 8') printf 'we settled the interpreter question in this thread\n' ;;
      *'issue view'*) : ;;
      *) return 0 ;;
    esac
  }
  s131d_run() {
    RECALL_LIMIT=5; export RECALL_LIMIT
    . "$S131_HELPER"
    recall_pointers "operational interpreter version choice" --deep 2>/dev/null
  }
  s131d_out=$(s131d_run)
  # (1) multi-token phrase whose whole-phrase search returns 0 still surfaces #8 via
  # the per-token candidate fallback (the stage-1/stage-2 symmetry restoration).
  printf '%s\n' "$s131d_out" | grep -q '#8 ' || { s131=0; s131_why="${s131_why}deep-multitoken-not-surfaced;"; }
  # (2) still pointers-only + deduped: #8 appears exactly once, comment text absent.
  s131d_dupes=$(printf '%s\n' "$s131d_out" | grep -c '#8 ')
  [ "$s131d_dupes" = 1 ] || { s131=0; s131_why="${s131_why}deep-multitoken-double-print(#8x$s131d_dupes);"; }
  printf '%s' "$s131d_out" | grep -q 'settled the interpreter question' && { s131=0; s131_why="${s131_why}deep-multitoken-comment-leaked;"; }
  unset -f gh s131d_run 2>/dev/null
fi
if [ "$s131" = 1 ]; then
  ok "131: /recall deep tier is --deep-gated (off by default), fetches candidate comments (--json comments), fixed-string greps (grep -F), RECALL_LIMIT-bounded (#524); candidate gate is token-aware — a multi-token phrase whose whole-phrase search returns 0 still reaches candidates via per-token fallback, deduped + pointers-only (#526)"
else
  ng "131: /recall deep-tier mechanism absent/violated:$s131_why (#524)"
fi

# ---------- 132. adversarial-pairing plan review contest (#530) ----------
# Pins the #530 contract: planner produces one base Plan A + NO alternatives;
# /work-on runs an axis selector and dispatches TWO mutually-blind
# plan-challenger agents on distinct axes; plan-reviewer judges {A, B1, B2}.
# All greps are non-vacuous (each anchor is a distinctive token that is TRUE
# only under the #530 contract) and loud-fail if the target file is missing.
s132=1; s132_why=""
S132_CHALLENGER="$SHELL_ROOT/.claude/agents/plan-challenger.md"
S132_REVIEWER="$SHELL_ROOT/.claude/agents/plan-reviewer.md"
S132_SPEC="$SHELL_ROOT/SPEC.md"
S132_WORKON="$SHELL_ROOT/.claude/commands/work-on.md"
S132_PRBODY="$SHELL_ROOT/.claude/templates/pr_body.md"
S132_ACTIVATION="$SHELL_ROOT/.claude/agents/activation-reviewer.md"

# (a) plan-challenger.md exists AND carries the adversarial mandate.
if [ -f "$S132_CHALLENGER" ]; then
  grep -qiF 'beat Plan A' "$S132_CHALLENGER" || { s132=0; s132_why="${s132_why}challenger-no-beat-mandate;"; }
  grep -qiF 'concession' "$S132_CHALLENGER" \
    && grep -qiF 'names the axis' "$S132_CHALLENGER" \
    || { s132=0; s132_why="${s132_why}challenger-no-concession-names-axis;"; }
  grep -qiF 'fake-diff' "$S132_CHALLENGER" || { s132=0; s132_why="${s132_why}challenger-no-fake-diff;"; }
  grep -qF 'performance' "$S132_CHALLENGER" \
    && grep -qF 'security' "$S132_CHALLENGER" \
    || { s132=0; s132_why="${s132_why}challenger-axis-menu-missing-perf-or-sec;"; }
  grep -qF '§4.9.3' "$S132_CHALLENGER" || { s132=0; s132_why="${s132_why}challenger-no-4.9.3-selfprompt;"; }
  grep -qiF 'Working-tree discipline' "$S132_CHALLENGER" \
    && grep -qiF 'read-only git' "$S132_CHALLENGER" \
    || { s132=0; s132_why="${s132_why}challenger-no-worktree-discipline;"; }
else
  s132=0; s132_why="${s132_why}challenger-file-missing;"
fi

# (b) plan-reviewer.md judges the contest with the guards + unchanged grammar.
if [ -f "$S132_REVIEWER" ]; then
  grep -qF '{A, B1, B2}' "$S132_REVIEWER" \
    || grep -qiF 'judge' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-judge-candidates;"; }
  grep -qiF 'lazy' "$S132_REVIEWER" || { s132=0; s132_why="${s132_why}reviewer-no-lazy-concession;"; }
  grep -qiF 'fake-diff' "$S132_REVIEWER" || { s132=0; s132_why="${s132_why}reviewer-no-fake-diff;"; }
  grep -qiF 'shared-blindspot' "$S132_REVIEWER" || { s132=0; s132_why="${s132_why}reviewer-no-shared-blindspot;"; }
  grep -qF 'VERDICT: ship' "$S132_REVIEWER" \
    && grep -qF 'VERDICT: refine' "$S132_REVIEWER" \
    && grep -qF 'VERDICT: block' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-verdict-grammar-changed;"; }
else
  s132=0; s132_why="${s132_why}reviewer-file-missing;"
fi

# (c) SPEC §4.8 carries the §4.11-distinction argument — BOTH legs. Losing
# either leg silently would gut the load-bearing "why default, not gated"
# rationale, so pin both distinctive phrases.
if [ -f "$S132_SPEC" ]; then
  grep -qiF 'generation diversity' "$S132_SPEC" || { s132=0; s132_why="${s132_why}spec-no-generation-diversity;"; }
  grep -qiF 'vote redundancy' "$S132_SPEC" || { s132=0; s132_why="${s132_why}spec-no-vote-redundancy;"; }
  grep -qiF 'acting context' "$S132_SPEC" || { s132=0; s132_why="${s132_why}spec-no-acting-context;"; }
else
  s132=0; s132_why="${s132_why}spec-file-missing;"
fi

# (d) work-on.md wires the axis selector + parallel challenger dispatch + judge.
if [ -f "$S132_WORKON" ]; then
  grep -qiF 'Axis selection' "$S132_WORKON" || { s132=0; s132_why="${s132_why}workon-no-axis-selection;"; }
  grep -qiF 'plan-challenger' "$S132_WORKON" \
    && grep -qiF 'parallel' "$S132_WORKON" \
    || { s132=0; s132_why="${s132_why}workon-no-parallel-challenger-dispatch;"; }
  grep -qF '{A, B1, B2}' "$S132_WORKON" || { s132=0; s132_why="${s132_why}workon-no-judge-{A,B1,B2};"; }
else
  s132=0; s132_why="${s132_why}workon-file-missing;"
fi

# (e) pr_body.md `## Alternatives considered` is now the contest record.
if [ -f "$S132_PRBODY" ]; then
  grep -qF '## Alternatives considered' "$S132_PRBODY" || { s132=0; s132_why="${s132_why}prbody-no-alternatives-section;"; }
  grep -qiF 'Contest record' "$S132_PRBODY" || { s132=0; s132_why="${s132_why}prbody-no-contest-record;"; }
  grep -qF 'B1' "$S132_PRBODY" \
    && grep -qF 'B2' "$S132_PRBODY" \
    && grep -qiF 'Verdict' "$S132_PRBODY" \
    || { s132=0; s132_why="${s132_why}prbody-no-A/B1/B2/verdict;"; }
else
  s132=0; s132_why="${s132_why}prbody-file-missing;"
fi

# (f) #568 — mandatory-invariant preservation gate. The dispatch manifest carries
# a `Mandatory invariants` field, BOTH reviewer prompts run an invariant-preservation
# gate BEFORE they judge the contest / weigh evidence (a dropped invariant is a
# disqualification, not a taste call), and the plan-reviewer's minimalism guard
# carves out the invariant so "minimalism-by-deferral" can never justify dropping one.

# (f.1) work-on.md dispatch contract passes the invariant manifest to the reviewers.
if [ -f "$S132_WORKON" ]; then
  grep -qF 'Mandatory invariants' "$S132_WORKON" \
    || { s132=0; s132_why="${s132_why}workon-no-mandatory-invariants-field;"; }
else
  s132=0; s132_why="${s132_why}workon-file-missing-568;"
fi

# (f.2) plan-reviewer.md: invariant-preservation gate marker + disqualification token
# + a "before the contest / regardless of axis" phrase, AND the gate section's heading
# precedes the `Judge the contest` anchor. Ordering is compared by MATCHED-MARKER line
# position resolved at runtime (grep -n), never a hardcoded line number, so it stays
# robust to reformatting.
if [ -f "$S132_REVIEWER" ]; then
  grep -qiE 'invariant-preservation gate' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-invariant-gate-marker;"; }
  grep -qiE 'disqualif' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-disqualif-token;"; }
  grep -qiE 'before the (axis )?contest|regardless of axis' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-before-contest-phrase;"; }
  pr_gate_ln=$(grep -niE 'invariant-preservation gate' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  pr_contest_ln=$(grep -nF 'Judge the contest' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$pr_gate_ln" ] && [ -n "$pr_contest_ln" ] && [ "$pr_gate_ln" -lt "$pr_contest_ln" ]; then
    :
  else
    s132=0; s132_why="${s132_why}reviewer-gate-not-before-contest;"
  fi
else
  s132=0; s132_why="${s132_why}reviewer-file-missing-568;"
fi

# (f.3) activation-reviewer.md: same gate marker + disqualification token + a
# "before the evidence judgment" phrase, AND the gate heading precedes the
# `Evidence sufficiency (completion only)` body-check anchor (line 82-shaped; the
# case-sensitive body form, NOT the lowercase frontmatter mention). Same runtime
# matched-marker ordering, no hardcoded line arithmetic.
if [ -f "$S132_ACTIVATION" ]; then
  grep -qiE 'invariant-preservation gate' "$S132_ACTIVATION" \
    || { s132=0; s132_why="${s132_why}activation-no-invariant-gate-marker;"; }
  grep -qiE 'disqualif' "$S132_ACTIVATION" \
    || { s132=0; s132_why="${s132_why}activation-no-disqualif-token;"; }
  grep -qiE 'before (the )?evidence' "$S132_ACTIVATION" \
    || { s132=0; s132_why="${s132_why}activation-no-before-evidence-phrase;"; }
  ar_gate_ln=$(grep -niE 'invariant-preservation gate' "$S132_ACTIVATION" 2>/dev/null | head -1 | cut -d: -f1)
  ar_ev_ln=$(grep -nF 'Evidence sufficiency (completion only)' "$S132_ACTIVATION" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$ar_gate_ln" ] && [ -n "$ar_ev_ln" ] && [ "$ar_gate_ln" -lt "$ar_ev_ln" ]; then
    :
  else
    s132=0; s132_why="${s132_why}activation-gate-not-before-evidence;"
  fi
else
  s132=0; s132_why="${s132_why}activation-file-missing-568;"
fi

# (f.4) plan-reviewer.md minimalism carve-out: the `minimalism-by-deferral` guard
# names the `technical taste alone` carve-out and the `no worse elsewhere` clause
# (which now folds in a dropped invariant), so minimalism can't be weaponized to
# drop an invariant.
if [ -f "$S132_REVIEWER" ]; then
  grep -qF 'minimalism-by-deferral' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-minimalism-by-deferral;"; }
  grep -qiF 'technical taste alone' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-technical-taste-carveout;"; }
  grep -qiF 'no worse elsewhere' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-no-worse-elsewhere;"; }
fi

# (f.5) empty-manifest attestation — both reviewer prompts document what to do when
# NO invariant is declared (an explicit "none declared" / attestation, so an empty
# manifest is a deliberate statement, not a silent skip of the gate).
grep -qiE 'none declared|attest' "$S132_REVIEWER" \
  || { s132=0; s132_why="${s132_why}reviewer-no-empty-manifest-attest;"; }
grep -qiE 'none declared|attest' "$S132_ACTIVATION" \
  || { s132=0; s132_why="${s132_why}activation-no-empty-manifest-attest;"; }

# (f.6) guard non-regression — the invariant gate is ADDITIVE; the pre-existing
# contest guards (lazy-concession / fake-diff / shared-blindspot) must survive the
# #568 edit. These should PASS today (they already document invariants); pinning
# them stops a future edit from silently dropping them alongside the gate work.
grep -qiE 'lazy.concession|lazy-concession' "$S132_REVIEWER" \
  || { s132=0; s132_why="${s132_why}reviewer-regression-lazy-concession;"; }
grep -qiE 'fake-diff' "$S132_REVIEWER" \
  || { s132=0; s132_why="${s132_why}reviewer-regression-fake-diff;"; }
grep -qiE 'shared-blindspot|shared blindspot' "$S132_REVIEWER" \
  || { s132=0; s132_why="${s132_why}reviewer-regression-shared-blindspot;"; }

# (f.7) #571 — judge-side dismissal evidence-burden guard. The (f.6) guards police the
# CHALLENGERS; this guard polices the JUDGE's own A-stands dismissal of a domination
# claim (refute, don't outweigh; scaled to the challenger's CLAIMED magnitude) and closes
# the reclassification-to-dodge (B1) + unevidenced-down-rate (B2) escape hatches while
# preserving benign-incumbent (fires only on a domination claim; A never re-justified de
# novo). It is ADDITIVE inside Check 1, so it must sit AFTER the Check-0 invariant gate
# (matched-marker runtime position, no hardcoded line); SPEC §4.8/§6.0 carry a thin pointer.
if [ -f "$S132_REVIEWER" ]; then
  grep -qiF 'dismissal evidence-burden' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-dismissal-burden-marker;"; }
  grep -qiE 'refut' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-refute-token;"; }
  grep -qiE 'outweigh' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-outweigh-token;"; }
  grep -qiF 'claimed' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-claimed-magnitude-anchor;"; }
  grep -qiE 'reclassification|trade-off i weighed' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-anti-relabel-clause;"; }
  grep -qiE 'down-rate' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-downrate-clause;"; }
  grep -qiF 'de novo' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-benign-incumbent-carveout;"; }
  pr_burden_ln=$(grep -niF 'dismissal evidence-burden' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  pr_gate2_ln=$(grep -niE 'invariant-preservation gate' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$pr_burden_ln" ] && [ -n "$pr_gate2_ln" ] && [ "$pr_burden_ln" -gt "$pr_gate2_ln" ]; then
    :
  else
    s132=0; s132_why="${s132_why}reviewer-burden-not-after-gate;"
  fi
else
  s132=0; s132_why="${s132_why}reviewer-file-missing-571;"
fi
# (f.7-SPEC) SPEC §4.8/§6.0 thin pointer to the dismissal evidence-burden guard.
if [ -f "$S132_SPEC" ]; then
  grep -qiF 'dismissal evidence-burden' "$S132_SPEC" \
    || { s132=0; s132_why="${s132_why}spec-no-dismissal-burden-pointer;"; }
else
  s132=0; s132_why="${s132_why}spec-file-missing-571;"
fi

# (f.8) #573 — symmetric steelman (two limbs). The former A-only steelman-the-incumbent
# authored advocacy for A alone, autoregressively priming the verdict toward the incumbent.
# It is now SYMMETRIC across {A, B1, B2} and split by concern: an INVARIANT limb inside
# Check 0 (before disqualification) and an AXIS limb at the head of Check 1 (before "Pick
# the winner"). Decoupled assertions (no single-line coupling); ordering pinned by runtime
# matched-marker position (reuses the `invariant-preservation gate` / `Judge the contest`
# markers), so it stays robust to reformatting. Fails on the pre-#573 A-only prose.
if [ -f "$S132_REVIEWER" ]; then
  grep -qiF 'symmetric steelman' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-symmetric-steelman;"; }
  grep -qF 'steelman — invariant limb' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-steelman-invariant-limb;"; }
  grep -qF 'steelman — axis limb' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-steelman-axis-limb;"; }
  grep -qiE 'every candidate|\{A, ?B1, ?B2\}' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-steelman-not-symmetric-coverage;"; }
  grep -qiF 'invariants A preserves' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-steelman-drops-A-invariant;"; }
  # invariant limb sits inside Check 0: gate_ln < inv_ln < contest_ln
  s_gate_ln=$(grep -niE 'invariant-preservation gate' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  s_contest_ln=$(grep -nF 'Judge the contest' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  s_inv_ln=$(grep -nF 'steelman — invariant limb' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  s_axis_ln=$(grep -nF 'steelman — axis limb' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  s_win_ln=$(grep -nF 'Pick the **winner**' "$S132_REVIEWER" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$s_gate_ln" ] && [ -n "$s_contest_ln" ] && [ -n "$s_inv_ln" ] \
     && [ "$s_gate_ln" -lt "$s_inv_ln" ] && [ "$s_inv_ln" -lt "$s_contest_ln" ]; then :; \
  else s132=0; s132_why="${s132_why}reviewer-inv-limb-not-in-check0;"; fi
  # axis limb sits at the head of Check 1: contest_ln < axis_ln < winner_ln
  if [ -n "$s_contest_ln" ] && [ -n "$s_axis_ln" ] && [ -n "$s_win_ln" ] \
     && [ "$s_contest_ln" -lt "$s_axis_ln" ] && [ "$s_axis_ln" -lt "$s_win_ln" ]; then :; \
  else s132=0; s132_why="${s132_why}reviewer-axis-limb-not-check1-head;"; fi
else
  s132=0; s132_why="${s132_why}reviewer-file-missing-573;"
fi
# (f.8-SPEC) SPEC §4.8 steelman sentence reflects symmetric treatment.
if [ -f "$S132_SPEC" ]; then
  grep -qiF 'symmetric steelman' "$S132_SPEC" \
    || { s132=0; s132_why="${s132_why}spec-no-symmetric-steelman-pointer;"; }
fi

# (f.9) #575 — axis-selection contract: weight-not-filter + judge axis-selection sanity
# check + drop-axis attestation. The selector's "focus 2 axes" is a WEIGHT (all axes stay in
# view via the domination bar), not a FILTER; `plan-reviewer` gains an after-the-fact
# axis-selection sanity check (backstop on the non-adversarial selector); `/work-on` emits a
# drop-axis attestation via the HOUSE IDIOM — source hookrt.sh THEN a bare `audit_log info
# plan-axis` (a bare `command -v audit_log` guard WITHOUT sourcing silently no-ops every run).
if [ -f "$S132_WORKON" ] && [ -f "$S132_CHALLENGER" ] && [ -f "$S132_REVIEWER" ]; then
  grep -qiF 'weight, not a filter' "$S132_WORKON" \
    || { s132=0; s132_why="${s132_why}workon-no-weight-not-filter;"; }
  grep -qiF 'all axes in view' "$S132_CHALLENGER" \
    || { s132=0; s132_why="${s132_why}challenger-no-all-axes-in-view;"; }
  grep -qiE 'lead(ing)? with' "$S132_CHALLENGER" \
    || { s132=0; s132_why="${s132_why}challenger-no-lead-with;"; }
  # framing-only guardrail: the domination verb must survive the reframe
  grep -qiF 'beat Plan A' "$S132_CHALLENGER" \
    || { s132=0; s132_why="${s132_why}challenger-framing-dropped-beat;"; }
  grep -qiF 'axis-selection sanity check' "$S132_REVIEWER" \
    || { s132=0; s132_why="${s132_why}reviewer-no-axis-sanity-check;"; }
  grep -qF 'audit_log info plan-axis' "$S132_WORKON" \
    || { s132=0; s132_why="${s132_why}workon-no-plan-axis-attestation;"; }
  grep -qiF 'focused={' "$S132_WORKON" \
    || { s132=0; s132_why="${s132_why}workon-no-focused-split;"; }
  grep -qiF 'deferred={' "$S132_WORKON" \
    || { s132=0; s132_why="${s132_why}workon-no-deferred-split;"; }
  # source-precedes-emit: a hookrt.sh source must sit just above the plan-axis emission
  # (the A defect #575 fixes — a bare guard with no source is a silent no-op / phantom trail).
  pa_ln=$(grep -nF 'audit_log info plan-axis' "$S132_WORKON" 2>/dev/null | head -1 | cut -d: -f1)
  src_near=$(grep -nF 'hooks/hookrt.sh' "$S132_WORKON" 2>/dev/null | cut -d: -f1 | awk -v p="$pa_ln" '$1<=p{m=$1} END{print m}')
  if [ -n "$pa_ln" ] && [ -n "$src_near" ] && [ "$src_near" -lt "$pa_ln" ] && [ "$((pa_ln - src_near))" -le 3 ]; then :; \
  else s132=0; s132_why="${s132_why}workon-plan-axis-not-sourced;"; fi
else
  s132=0; s132_why="${s132_why}axis-contract-file-missing-575;"
fi
# (f.9-SPEC) SPEC reflects weight-not-filter + the plan-axis attestation pointer.
if [ -f "$S132_SPEC" ]; then
  grep -qiF 'weight, not a filter' "$S132_SPEC" \
    || { s132=0; s132_why="${s132_why}spec-no-weight-not-filter;"; }
  grep -qiF 'plan-axis' "$S132_SPEC" \
    || { s132=0; s132_why="${s132_why}spec-no-plan-axis-pointer;"; }
fi

if [ "$s132" = 1 ]; then
  ok "132: adversarial-pairing plan review pinned — plan-challenger (beat/concession/fake-diff/perf+sec axis/§4.9.3/worktree), plan-reviewer (judge {A,B1,B2}/lazy/fake-diff/shared-blindspot/VERDICT grammar), SPEC §4.11-distinction (generation diversity vs vote redundancy + acting context), work-on axis-selector+parallel dispatch+judge, pr_body contest record (#530); + #568 mandatory-invariant gate (work-on manifest field, both reviewers gate-before-contest/evidence + disqualif + empty-manifest attest, minimalism carve-out, guard non-regression); + #571 judge-side dismissal evidence-burden guard (refute-not-outweigh, claimed-magnitude anchor, anti-relabel/evidenced-downrate hatches, benign-incumbent de-novo carve-out, additive-after-gate ordering, SPEC §4.8/§6.0 pointer); + #573 symmetric steelman (invariant limb in Check 0 + axis limb at Check-1 head, {A,B1,B2} coverage, A-invariant retained, matched-marker region ordering, SPEC §4.8 symmetric pointer); + #575 axis-selection contract (weight-not-filter framing in work-on+challenger, judge axis-selection sanity check, drop-axis plan-axis attestation via source-then-bare-audit_log house idiom with source-precedes-emit pin, beat-Plan-A framing-only guardrail, SPEC pointers)"
else
  ng "132: adversarial-pairing plan review contract violated:$s132_why (#530/#568/#571/#573/#575)"
fi

# ---------- §110: README assertion-count floor (#409) ----------
# README's "Verify" block advertises an assertion count as "<N>+". A count that
# OVERSTATES coverage (claims more than the suite runs) is the misleading
# direction; understatement after new assertions land is the benign,
# self-correcting one. So this is a FLOOR guard, not an exact pin — an exact pin
# would be a SPEC §6.0 cost-asymmetry mismatch, tripping CI on every benign
# assertion addition. <N> is parsed from the README, never hardcoded here (a
# hardcoded copy would be a third number to hand-sync). Runs last, so $PASS is
# the full suite total (minus this guard's own pending increment) — the floor
# tolerates that off-by-one by construction.
readme_floor=$(grep -oE '#[[:space:]]*[0-9]+\+?[[:space:]]+assertions' "$README_MD" 2>/dev/null | grep -oE '[0-9]+' | head -1)
if [ -n "$readme_floor" ] && [ "$readme_floor" -le "$PASS" ] 2>/dev/null; then
  ok "110: README assertion floor ($readme_floor) does not overstate live PASS ($PASS) (#409)"
else
  ng "110: README assertion floor (${readme_floor:-unparsed}) overstates live PASS ($PASS) or is unparseable (#409)"
fi

# ---------- §133: GHJig-Claude identity guard (#533) ----------
# Assert ZERO legacy identity identifiers survive in tracked code+prose after the
# rename to GHJig-Claude. Every forbidden token below is built
# from string fragments ("A""B") so this guard's OWN source carries no literal
# legacy token to self-match — the same anti-vacuity discipline as the head
# comment, and it also keeps the Code-phase sed from rewriting the guard's
# patterns (the fragment breaks the contiguous match). Excludes the changelog
# surfaces (CHANGELOG.md dated history + changelog_unreleased/ fragments) — both
# legitimately name the OLD identifiers to describe the migration, and both are
# prose/history, not live code (owner decision #533). Everything else, including
# this file's own real identifiers, is scanned and must be renamed.
s533_forbidden=(
  "CLAUDE_""ENG_"
  "ENG_""STATE_DIR_OVERRIDE"
  "eng""-shell-root"
  "eng""-state"
  "eng""_commit"
  "eng""_skip"
  "eng""_state_dir"
  "eng""_registry_file"
  "ghjig""-shell-root"
  # #537: the ambient shell-root env var is retired as a hook input (SPEC
  # §3.2.1). The name legitimately survives ONLY as historical narration in
  # three docs + the pinned §6.5(c) banner arm in session_start.sh — those
  # four files are carved out per-token in the loop below, and the doc
  # survivors are count-pinned exactly by §133d so the carve-out cannot
  # silently widen. Every other tracked file must be clean post-#537.
  "GHJIG_SHELL_""ROOT"
)
# Bare command / display token, matched case-insensitively — a strict superset
# that also catches the display name, the bin/ path form, the skip sentinel, and
# the banner/anchor forms in one pattern (#533 correctness challenger).
s533_ci_token="claude""-eng"

s533_files=0
s533_hits=""
while IFS= read -r s533_f; do
  [ "$s533_f" = "CHANGELOG.md" ] && continue
  case "$s533_f" in changelog_unreleased/*) continue ;; esac
  [ -f "$SHELL_ROOT/$s533_f" ] || continue
  s533_files=$((s533_files+1))
  for s533_tok in "${s533_forbidden[@]}"; do
    # #537 per-token carve-out (same continue mechanism as the changelog
    # exclusions above): the retired shell-root var name survives only in
    # SPEC/CLAUDE/TROUBLESHOOTING historical narration (count-pinned by
    # §133d) and in session_start.sh, the §6.5(c) banner arm's home — the
    # ambient check + the user-facing "retired" literal must name the var.
    if [ "$s533_tok" = "GHJIG_SHELL_""ROOT" ]; then
      case "$s533_f" in
        SPEC.md|.claude/CLAUDE.md|docs/TROUBLESHOOTING.md|.claude/hooks/session_start.sh) continue ;;
      esac
    fi
    if LC_ALL=C grep -qF -- "$s533_tok" "$SHELL_ROOT/$s533_f"; then
      s533_hits="${s533_hits}${s533_f}[${s533_tok}] "
    fi
  done
  if LC_ALL=C grep -qiF -- "$s533_ci_token" "$SHELL_ROOT/$s533_f"; then
    s533_hits="${s533_hits}${s533_f}[cmd] "
  fi
done < <(git -C "$SHELL_ROOT" ls-files)

# Non-vacuity: the scan must have covered the real tree (188 tracked files at
# authoring; floor well below that so benign growth/shrink can't trip it), else
# an empty git ls-files would green vacuously.
if [ "$s533_files" -lt 150 ]; then
  ng "133a: identity guard scanned only $s533_files files (<150) — scan is vacuous, cannot trust a clean result (#533)"
elif [ -z "$s533_hits" ]; then
  ok "133a: no legacy identity token survives across $s533_files tracked files (#533)"
else
  ng "133a: legacy identity token(s) survive: $s533_hits (#533)"
fi

# §133b (robustness challenger R1): the dogfood settings.json must resolve every
# hook command via \${CLAUDE_PROJECT_DIR} and carry NO *_SHELL_ROOT on the hook
# hot path — that decoupling is what keeps enforcement armed through an in-place
# rename of the env var (SPEC §3.2.1, #533).
s533_settings="$SHELL_ROOT/.claude/settings.json"
if [ -f "$s533_settings" ]; then
  s533_cmds=$(grep -c '"command":' "$s533_settings")
  s533_cpd=$(grep -cF '{CLAUDE_PROJECT_DIR}/.claude/hooks/' "$s533_settings")
  s533_root=$(grep -cF '_SHELL_ROOT' "$s533_settings")
  if [ "$s533_cmds" -ge 5 ] && [ "$s533_cpd" = "$s533_cmds" ] && [ "$s533_root" = 0 ]; then
    ok "133b: settings.json hook commands all resolve via \${CLAUDE_PROJECT_DIR}, none via *_SHELL_ROOT (cmds=$s533_cmds) (#533)"
  else
    ng "133b: settings.json hook-command resolution wrong: commands=$s533_cmds project-dir=$s533_cpd shell-root=$s533_root (want cpd==cmds, root==0) (#533)"
  fi
else
  ng "133b: .claude/settings.json missing (#533)"
fi

# §133c (correctness challenger): positively pin the NEW display-name casing in
# the canonical title spots (a negative-only guard cannot catch an inconsistent
# NEW casing). Deliberately narrow to the title/prose of canonical docs — a
# global negative scan for mis-cased 'ghjig-claude' would false-positive on the
# legitimate lowercase repo slug in every github.com/ilgyu-yi/ghjig-claude URL
# (#533 plan-deviation, recorded in the PR).
s533_cas_why=""
for s533_doc in "README.md" "README.ko.md" "MISSION.md" "SPEC.md" ".claude/CLAUDE.md"; do
  if ! grep -qF -- "GHJig-Claude" "$SHELL_ROOT/$s533_doc" 2>/dev/null; then
    s533_cas_why="${s533_cas_why}${s533_doc}; "
  fi
done
if [ -z "$s533_cas_why" ]; then
  ok "133c: canonical display name 'GHJig-Claude' present in README/README.ko/MISSION/SPEC/CLAUDE.md (#533)"
else
  ng "133c: canonical display name 'GHJig-Claude' missing or mis-cased in: $s533_cas_why (#533)"
fi

# §133d (#537): the doc-file carve-out in §133a is COUNT-PINNED so it cannot
# become a drift hole. The #537 Doc phase left exactly these token-carrying
# lines naming the retired shell-root var as historical narration / the pinned
# banner literal: SPEC.md=5, .claude/CLAUDE.md=1, docs/TROUBLESHOOTING.md=2.
# session_start.sh=2 pins the live §6.5(c) banner-arm code (the ambient
# trigger + the banner literal): §134b guards only the resolution/export
# lines and §134c is banner-behavioral, so without this pin a future
# functional ambient consult elsewhere in the file would evade all guards.
# Any NEW mention (or a removal) trips this pin and forces a conscious update.
s537_pin="SPEC.md:5 .claude/CLAUDE.md:1 docs/TROUBLESHOOTING.md:2 .claude/hooks/session_start.sh:2"
s537_pin_why=""
for s537_spec in $s537_pin; do
  s537_pf="${s537_spec%:*}"; s537_want="${s537_spec##*:}"
  if [ ! -f "$SHELL_ROOT/$s537_pf" ]; then
    s537_pin_why="${s537_pin_why}${s537_pf}(MISSING) "
    continue
  fi
  s537_got=$(LC_ALL=C grep -cF -- "GHJIG_SHELL_""ROOT" "$SHELL_ROOT/$s537_pf" 2>/dev/null)
  [ "${s537_got:-0}" = "$s537_want" ] \
    || s537_pin_why="${s537_pin_why}${s537_pf}(want=$s537_want got=${s537_got:-0}) "
done
if [ -z "$s537_pin_why" ]; then
  ok "133d: retired shell-root var survives at exactly the pinned counts (5/1/2/2) (#537)"
else
  ng "133d: doc-survivor count drifted from the #537 pin: $s537_pin_why(#537)"
fi

# ---------- §134: ambient shell-root demotion (#537) ----------
# SPEC §3.2.1 (post-#537): every hook entry resolves
#   SHELL_ROOT="${GHJIG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# then `export GHJIG_ROOT="$SHELL_ROOT"`. GHJIG_ROOT_OVERRIDE is a TEST-ONLY
# seam (precedent: GHJIG_STATE_DIR_OVERRIDE); on the production hook path the
# AMBIENT environment is NEVER consulted — an inherited GHJIG_ROOT (or the
# retired legacy var) cannot redirect which shell tree the hooks load. This
# kills the cross-clone contamination vector where a stale global export made
# clone B's hooks source clone A's helpers. SPEC §6.5(c) adds two banner arms
# (retired-knob / active-seam) so the clean cut is observable, not silent.

# §134a: wrong-ambient regression. A hostile ambient shell-root pointing at a
# FAKE tree must not redirect the real hook: piping a protected-branch commit
# into the real pre_tool_use.sh must (i) still block and (ii) never load the
# fake tree's runtime/helpers (tripwire stays unwritten). Under the pre-#537
# env-first resolution the fake hookrt.sh is sourced (tripwire fires) and the
# undefined in_scope short-circuits the hook to rc=0 (no block) — RED both
# ways now, GREEN after the resolution flip.
S134A_DIR=$(mktemp -d); S134A_DIR=$(cd "$S134A_DIR" && pwd -P)
S134A_FAKE="$S134A_DIR/fakeroot"
S134A_TRIP="$S134A_DIR/tripwire"
mkdir -p "$S134A_FAKE/.claude/hooks/helpers"
# Fake runtime: sourcing it (or calling its no-op audit_log/safe_source) writes
# the tripwire. If the entry consults the ambient env, it loads THIS file
# instead of the real hookrt.sh.
cat > "$S134A_FAKE/.claude/hooks/hookrt.sh" <<EOF
printf 'hookrt-sourced\n' >> "$S134A_TRIP"
audit_log()   { printf 'audit_log-called\n'   >> "$S134A_TRIP"; return 0; }
safe_source() { printf 'safe_source-called\n' >> "$S134A_TRIP"; return 0; }
EOF
# Populate helpers/ enough for the entry's [ -d .../hooks/helpers ] guard;
# each fake helper also trips if ever sourced.
for s134a_h in escape cwd_guard detect_stack branch_guard conventional_commit; do
  printf 'printf "helper-%s\\n" >> "%s"\n' "$s134a_h" "$S134A_TRIP" \
    > "$S134A_FAKE/.claude/hooks/helpers/$s134a_h.sh"
done
# Registered target repo on a protected branch (main) — §60 fixture pattern —
# so the real hook path has a live protected-branch block to fire.
S134A_TGT="$S134A_DIR/target"
mkdir -p "$S134A_TGT"
(cd "$S134A_TGT" && { git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }; }
 git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
printf '%s\n' "$S134A_TGT" >> "$SMOKE_REG"

s134a_run() {  # "$@" = extra VAR=VAL env pairs → echoes the hook rc
  (
    cd "$S134A_TGT" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m smoke134"}}' \
      | env -u GHJIG_ROOT_OVERRIDE -u GHJIG_ROOT -u "GHJIG_SHELL_""ROOT" "$@" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
    printf '%s' "$?"
  )
}
# 134a-0 (harness control, expected green pre- AND post-flip): with a CLEAN env
# the protected-branch commit blocks — proves the fixture detects a real block,
# so a RED on 134a-1 is the resolution's fault, not the harness's.
s134a0_rc=$(s134a_run)
[ "$s134a0_rc" = 2 ] \
  && ok "134a-0: control — clean env, protected-branch commit blocked (rc=2) (#537)" \
  || ng "134a-0: control broken — clean-env protected commit not blocked (rc=$s134a0_rc); 134a-1/2 unreliable (#537)"
# 134a-1: hostile ambient (legacy + new name → fake tree) — block STILL fires.
s134a1_rc=$(s134a_run "GHJIG_SHELL_""ROOT=$S134A_FAKE" "GHJIG_ROOT=$S134A_FAKE")
[ "$s134a1_rc" = 2 ] \
  && ok "134a-1: hostile ambient shell-root ignored — protected commit still blocked (rc=2) (#537)" \
  || ng "134a-1: ambient env redirected hook resolution — protected commit NOT blocked (rc=$s134a1_rc) (#537)"
# 134a-2: the fake tree was never loaded (no runtime source, no helper source,
# no audit_log/safe_source call landed in the fake).
if [ ! -e "$S134A_TRIP" ]; then
  ok "134a-2: fake tree untouched — hostile ambient never sourced (#537)"
else
  ng "134a-2: hook loaded the AMBIENT fake tree — cross-clone contamination: $(tr '\n' ' ' < "$S134A_TRIP")(#537)"
fi
rm -rf "$S134A_DIR"

# §134b: bootstrap-shape contract on all 5 hook entries. The SHELL_ROOT=
# resolution line must consult GHJIG_ROOT_OVERRIDE + BASH_SOURCE self-location,
# and must NOT consult the ambient env (neither the retired legacy var nor a
# bare/braced GHJIG_ROOT) as primary or fallback; the entry must then export
# GHJIG_ROOT (not the legacy name). Count-guarded: exactly 5 entries checked,
# and a missing file / missing resolution line fails LOUD (anti-vacuity).
s134b_checked=0
s134b_bad=""
for s134b_e in pre_tool_use post_tool_use session_start stop user_prompt_submit; do
  s134b_f="$SHELL_ROOT/.claude/hooks/$s134b_e.sh"
  if [ ! -f "$s134b_f" ]; then
    s134b_bad="${s134b_bad}${s134b_e}[missing-file] "
    continue
  fi
  s134b_checked=$((s134b_checked+1))
  # Whitespace-tolerant extraction of the resolution line (first assignment).
  s134b_line=$(grep -E '^[[:space:]]*SHELL_ROOT=' "$s134b_f" | head -1)
  if [ -z "$s134b_line" ]; then
    s134b_bad="${s134b_bad}${s134b_e}[no-resolution-line] "
    continue
  fi
  printf '%s' "$s134b_line" | grep -q 'GHJIG_ROOT_OVERRIDE' \
    || s134b_bad="${s134b_bad}${s134b_e}[no-override-seam] "
  printf '%s' "$s134b_line" | grep -q 'BASH_SOURCE' \
    || s134b_bad="${s134b_bad}${s134b_e}[no-self-location] "
  printf '%s' "$s134b_line" | grep -qF -- "GHJIG_SHELL_""ROOT" \
    && s134b_bad="${s134b_bad}${s134b_e}[consults-legacy-ambient] "
  # Braced ambient expansion ${GHJIG_ROOT}/${GHJIG_ROOT:-…}/${GHJIG_ROOT-…}
  # (the char after ROOT excludes the _OVERRIDE seam's underscore) …
  printf '%s' "$s134b_line" | grep -qE '\$\{GHJIG_ROOT[}:-]' \
    && s134b_bad="${s134b_bad}${s134b_e}[consults-ambient-braced] "
  # … and the bare $GHJIG_ROOT form.
  printf '%s' "$s134b_line" | grep -qE '\$GHJIG_ROOT([^_A-Za-z0-9]|$)' \
    && s134b_bad="${s134b_bad}${s134b_e}[consults-ambient-bare] "
  grep -qE '^[[:space:]]*export[[:space:]]+GHJIG_ROOT=' "$s134b_f" \
    || s134b_bad="${s134b_bad}${s134b_e}[no-ghjig-root-export] "
  grep -qE "export[[:space:]]+GHJIG_SHELL_""ROOT=" "$s134b_f" \
    && s134b_bad="${s134b_bad}${s134b_e}[legacy-export-survives] "
done
if [ "$s134b_checked" = 5 ] && [ -z "$s134b_bad" ]; then
  ok "134b: all 5 hook entries resolve via GHJIG_ROOT_OVERRIDE→BASH_SOURCE, never the ambient env, and export GHJIG_ROOT (#537)"
else
  ng "134b: hook-entry resolution contract violated (checked=$s134b_checked/5): ${s134b_bad:-none}(#537)"
fi

# §134b (ext, #539): the SAME self-location idiom, extended (non-optionally) past
# the 5 hook entries to the 4 deliberately-invoked CLI scripts + the 4 lib consult
# sites. As of #539 the ambient env is retired as an input EVERYWHERE, not just on
# the hook path (§3.2.1 "Self-location — one idiom"). Each of the 8 files must
# carry the single self-locate idiom `${GHJIG_ROOT_OVERRIDE:-…BASH_SOURCE…pwd -P}`
# and consult the ambient env NOWHERE — no `${GHJIG_ROOT:-…}` / `${GHJIG_ROOT:=…}` /
# `${GHJIG_ROOT}` / `${GHJIG_ROOT:?}`. The degraded `${GHJIG_ROOT:-$SCRIPT_ROOT}`
# (which re-admits the inherited ambient value) is explicitly caught by the same
# ban pattern §134b uses (the `[}:-]` char class matches :-, :=, :?, }, -, and
# excludes the `_OVERRIDE` seam's underscore). Count-guarded to 8; a missing file
# or missing idiom fails LOUD (anti-vacuity). RED until the Code phase flips the
# CLI `:=` fallbacks + the lib `:-`/`:?` reads to the idiom.
s134bx_checked=0
s134bx_bad=""
for s134bx_f in \
  scripts/dir_mode_project.sh scripts/migrate_v3.sh scripts/onboard_target.sh scripts/setup_project.sh \
  scripts/lib/audit_log_path.sh scripts/lib/dir_mode_project_resolve.sh scripts/lib/inject.sh scripts/lib/self_register.sh \
; do
  s134bx_p="$SHELL_ROOT/$s134bx_f"
  if [ ! -f "$s134bx_p" ]; then
    s134bx_bad="${s134bx_bad}${s134bx_f}[missing-file] "
    continue
  fi
  s134bx_checked=$((s134bx_checked+1))
  # (a) idiom present: one line carrying the OVERRIDE seam → BASH_SOURCE → pwd -P.
  grep -Eq 'GHJIG_ROOT_OVERRIDE:-.*BASH_SOURCE.*pwd -P' "$s134bx_p" \
    || s134bx_bad="${s134bx_bad}${s134bx_f}[no-self-locate-idiom] "
  # (b) no ambient braced consult ANYWHERE in the file (the degraded
  # ${GHJIG_ROOT:-$SCRIPT_ROOT} is a member of this set). Bare post-self-locate
  # `$GHJIG_ROOT` uses stay legal — only the ambient-CONSULT braced forms are banned.
  grep -Eq '\$\{GHJIG_ROOT[}:-]' "$s134bx_p" \
    && s134bx_bad="${s134bx_bad}${s134bx_f}[consults-ambient-braced] "
done
if [ "$s134bx_checked" = 8 ] && [ -z "$s134bx_bad" ]; then
  ok "134b (ext): 4 CLI + 4 lib sites self-locate via the OVERRIDE-seam→BASH_SOURCE idiom, never consult the ambient env (#539)"
else
  ng "134b (ext): CLI/lib self-location contract violated (checked=$s134bx_checked/8): ${s134bx_bad:-none}(#539)"
fi

# §134c: SessionStart shell-root env banners (SPEC §6.5(c), #537) — two arms in
# the same once-per-session mkdir-stamp-debounced family as the §40 hookrt /
# §502 registry-zeroed banners; harness mirrors ss502_run. Arm (a): a lingering
# legacy export (or a mismatched ambient GHJIG_ROOT) is functionally ignored on
# the hook path — this banner keeps that ignore from being silent. Arm (b): an
# active GHJIG_ROOT_OVERRIDE names the test-only seam + the loaded tree.
S134C_TMPDIR=$(mktemp -d); S134C_STATE=$(mktemp -d); S134C_CWD=$(mktemp -d)
# Keep all runs off the network/compute: pre-touch the §6.5(d) friction stamp
# (resolved via the state-dir override) and pin a huge fetch TTL so the
# §6.5(a) fetch is stamp-skipped.
touch "$S134C_STATE/last-friction-surfaced"
s134c_run() {  # $1 = session id; remaining args = VAR=VAL pairs → echoes stderr
  local s134c_sid="$1"; shift
  ( cd "$S134C_CWD" || exit 0
    env -u GHJIG_ROOT_OVERRIDE -u GHJIG_ROOT -u "GHJIG_SHELL_""ROOT" \
      CLAUDE_SESSION_ID="$s134c_sid" CLAUDE_PROJECT_DIR="$S134C_STATE" \
      GHJIG_STATE_DIR_OVERRIDE="$S134C_STATE" TMPDIR="$S134C_TMPDIR" \
      SESSION_START_FETCH_TTL=999999999 SESSION_START_FETCH_TIMEOUT=1 \
      "$@" bash "$SHELL_ROOT/.claude/hooks/session_start.sh" </dev/null 2>&1 >/dev/null
  )
}
s134c_retired() {  # $1 = captured stderr → echoes retired-banner line count
  printf '%s\n' "$1" | grep -c "GHJIG_SHELL_""ROOT retired" || true
}
s134c_seam() {  # $1 = captured stderr → echoes seam-banner line count
  printf '%s\n' "$1" | grep -c 'test-only seam active' || true
}
# 134c-a1/a2: legacy ambient set → retired-knob banner fires ONCE, then is
# debounced within the same session (same CLAUDE_SESSION_ID + TMPDIR stamp).
s134c_a_sid="smoke-134c-a-$$"
s134c_a_r1=$(s134c_run "$s134c_a_sid" "GHJIG_SHELL_""ROOT=$S134C_CWD/stale-root")
s134c_a_r2=$(s134c_run "$s134c_a_sid" "GHJIG_SHELL_""ROOT=$S134C_CWD/stale-root")
s134c_a_n1=$(s134c_retired "$s134c_a_r1")
s134c_a_n2=$(s134c_retired "$s134c_a_r2")
[ "$s134c_a_n1" = 1 ] \
  && ok "134c-a1: lingering legacy export → retired-knob banner fires (#537)" \
  || ng "134c-a1: legacy export ignored SILENTLY — retired-knob banner count=$s134c_a_n1 (want 1); stderr=$(printf '%s' "$s134c_a_r1" | tr '\n' ' ') (#537)"
[ "$s134c_a_n1" = 1 ] && [ "$s134c_a_n2" = 0 ] \
  && ok "134c-a2: retired-knob banner debounced to once per session (#537)" \
  || ng "134c-a2: debounce broken — first=$s134c_a_n1 (want 1) second=$s134c_a_n2 (want 0) (#537)"
# 134c-a3: no ambient, no seam → both arms silent (no false fire).
s134c_a3=$(s134c_run "smoke-134c-a3-$$")
[ "$(s134c_retired "$s134c_a3")" = 0 ] && [ "$(s134c_seam "$s134c_a3")" = 0 ] \
  && ok "134c-a3: clean env → both #537 banner arms silent (#537)" \
  || ng "134c-a3: banner false-fired on a clean env: $(printf '%s' "$s134c_a3" | tr '\n' ' ') (#537)"
# 134c-a4: ambient GHJIG_ROOT differing from the self-located root → the same
# retired-knob banner (the arm's second trigger per SPEC §6.5(c)).
s134c_a4=$(s134c_run "smoke-134c-a4-$$" "GHJIG_ROOT=$S134C_CWD/other-root")
[ "$(s134c_retired "$s134c_a4")" = 1 ] \
  && ok "134c-a4: mismatched ambient GHJIG_ROOT → retired-knob banner fires (#537)" \
  || ng "134c-a4: mismatched ambient GHJIG_ROOT ignored silently (banner count=$(s134c_retired "$s134c_a4"), want 1) (#537)"
# 134c-a5 (boundary, no-false-fire pin): ambient GHJIG_ROOT EQUAL to the
# self-located root (the normal wrapper/parent-export channel) → silent.
s134c_a5=$(s134c_run "smoke-134c-a5-$$" "GHJIG_ROOT=$SHELL_ROOT")
[ "$(s134c_retired "$s134c_a5")" = 0 ] \
  && ok "134c-a5: matching ambient GHJIG_ROOT (parent-export channel) → no banner (#537)" \
  || ng "134c-a5: banner false-fires on a MATCHING ambient GHJIG_ROOT (#537)"
# 134c-b1: active override seam → seam banner, exactly once, naming the loaded
# tree. The override points at the REAL shell root so the hook still runs its
# normal course (a functional tree) while the seam arm reports it.
s134c_b1=$(s134c_run "smoke-134c-b1-$$" "GHJIG_ROOT_OVERRIDE=$SHELL_ROOT")
if [ "$(s134c_seam "$s134c_b1")" = 1 ] \
   && printf '%s\n' "$s134c_b1" | grep -qF -- "hooks loading from $SHELL_ROOT"; then
  ok "134c-b1: GHJIG_ROOT_OVERRIDE set → seam banner names the seam + loaded path (#537)"
else
  ng "134c-b1: active test-only seam not surfaced (count=$(s134c_seam "$s134c_b1"), want 1 naming $SHELL_ROOT): $(printf '%s' "$s134c_b1" | tr '\n' ' ') (#537)"
fi
rm -rf "$S134C_TMPDIR" "$S134C_STATE" "$S134C_CWD"

# ---------- §135: ambient retired as an input EVERYWHERE (#539) ----------
# SPEC §3.2.1/§3.6 (post-#539): the 4 CLI scripts drop `: "${GHJIG_ROOT:=…}"` and
# self-locate unconditionally; the 4 lib consult sites self-locate inline before
# any bare $GHJIG_ROOT use; every registered project (incl. the dogfood repo) carries
# a `.claude/ghjig-root` binding symlink; and `.claude/commands/*.md` recast every
# `$GHJIG_ROOT/` to a structural (binding-symlink-relative) form. These assertions
# pin that END state, so they are RED now and GREEN after the Code phase.

# §135a (AC-1): zero ambient-INPUT consult across product scripts. No `${GHJIG_ROOT
# :-…}` / `${GHJIG_ROOT-…}` / `${GHJIG_ROOT:=…}` may survive under scripts/ or bin/.
# Excludes scripts/test/ (harness fixtures + the §134b guard-pattern comment) and
# the GHJIG_ROOT_OVERRIDE seam (the regex already excludes `_OVERRIDE`; filtered
# again defensively). RED now: the 4 CLI `:=` + the 5 lib `:-` sites still match.
s135a_hits=$(git -C "$SHELL_ROOT" grep -nE '\$\{GHJIG_ROOT(:?-|:=)' -- scripts/ bin/ 2>/dev/null \
  | grep -v '^scripts/test/' | grep -v 'GHJIG_ROOT_OVERRIDE' || true)
s135a_n=$(printf '%s' "$s135a_hits" | grep -c . || true)
if [ "$s135a_n" = 0 ]; then
  ok "135a: zero ambient \${GHJIG_ROOT:-}/\${GHJIG_ROOT:=} consult under scripts/ + bin/ (#539)"
else
  ng "135a: $s135a_n ambient GHJIG_ROOT consult site(s) survive under scripts/+bin/ (want 0): $(printf '%s' "$s135a_hits" | tr '\n' ' ')(#539)"
fi

# §135b (AC-2): uniform binding symlink across BOTH project kinds. Every real
# registered project — an injected target AND the dogfood $SHELL_ROOT (the #539-new
# committed self-symlink `.claude/ghjig-root -> ..`) — carries `.claude/ghjig-root`
# resolving to a directory containing `.claude/hooks` (mirrors §82's symlink
# resolution). The invariant is scoped to projects created via inject_into /
# ensure_self_registered, not the harness's bare `printf >> registry` fixtures
# (those are never injected and carry no binding by design). Count-guarded to 2;
# a missing/dangling link fails LOUD. RED now: the dogfood self-symlink is absent.
s135b_checked=0
s135b_bad=""
s135b_check_one() {  # $1 = project root, $2 = label
  local root="$1" label="$2" link real
  link="$root/.claude/ghjig-root"
  s135b_checked=$((s135b_checked+1))
  if [ ! -e "$link" ]; then s135b_bad="${s135b_bad}${label}[no-ghjig-root] "; return; fi
  real=$(cd "$link" 2>/dev/null && pwd -P) || real=""
  if [ -z "$real" ]; then s135b_bad="${s135b_bad}${label}[dangling] "; return; fi
  [ -d "$real/.claude/hooks" ] || s135b_bad="${s135b_bad}${label}[no-hooks-at-target] "
}
s135b_check_one "$SHELL_ROOT" dogfood   # the load-bearing #539-new case (RED now)
S135B_TGT=$(cd "$(mktemp -d)" && pwd -P)   # a freshly-injected target (green control)
( cd "$S135B_TGT" && git init -q ) >/dev/null 2>&1
inject_into "$S135B_TGT" >/dev/null 2>&1
s135b_check_one "$S135B_TGT" injected-target
rm -rf "$S135B_TGT"
if [ "$s135b_checked" = 2 ] && [ -z "$s135b_bad" ]; then
  ok "135b: dogfood + injected-target both carry .claude/ghjig-root → dir with .claude/hooks (uniform binding) (#539)"
else
  ng "135b: binding symlink missing/dangling (checked=$s135b_checked/2): ${s135b_bad:-none}(#539)"
fi

# §135c (AC-4): wrong-ambient regression for the 4 CLI scripts — mirrors §134a.
# A hostile ambient GHJIG_ROOT pointing at a FAKE tree (with tripwire-armed
# hookrt.sh + dir_mode_project_resolve.sh) must not redirect a deliberately-invoked
# CLI script: each self-locates its OWN clone, so the fake tree is never sourced
# (tripwire stays unwritten). Every run is bounded to a guard/--help/dry path on a
# fresh UNREGISTERED cwd with a `gh` stub, so no gh/network is reached either pre-
# or post-flip. RED now: the `:=` fallback honors the inherited GHJIG_ROOT and
# sources the fake tree.
S135C_DIR=$(mktemp -d); S135C_DIR=$(cd "$S135C_DIR" && pwd -P)
S135C_FAKE="$S135C_DIR/fakeroot"
S135C_TRIP="$S135C_DIR/tripwire"
S135C_CWD="$S135C_DIR/cwd"; mkdir -p "$S135C_CWD"
S135C_STUB="$S135C_DIR/stubbin"; mkdir -p "$S135C_STUB"
printf '#!/usr/bin/env bash\nexit 1\n' > "$S135C_STUB/gh"; chmod +x "$S135C_STUB/gh"
mkdir -p "$S135C_FAKE/.claude/hooks" "$S135C_FAKE/scripts/lib"
# Fake runtime + resolver: sourcing either (or calling the no-op audit_log) trips.
cat > "$S135C_FAKE/.claude/hooks/hookrt.sh" <<EOF
printf 'hookrt-sourced\n' >> "$S135C_TRIP"
audit_log()   { printf 'audit_log-called\n'   >> "$S135C_TRIP"; return 0; }
safe_source() { printf 'safe_source-called\n' >> "$S135C_TRIP"; return 0; }
EOF
cat > "$S135C_FAKE/scripts/lib/dir_mode_project_resolve.sh" <<EOF
printf 'resolve-sourced\n' >> "$S135C_TRIP"
EOF
s135c_fire() {  # $1 = script relpath under scripts/, rest = args ; echoes 1 if fake tree touched
  local script="$1"; shift
  rm -f "$S135C_TRIP"
  ( cd "$S135C_CWD" || exit 1
    env -u GHJIG_ROOT_OVERRIDE -u "GHJIG_SHELL_""ROOT" \
      GHJIG_ROOT="$S135C_FAKE" PATH="$S135C_STUB:$PATH" \
      bash "$SHELL_ROOT/scripts/$script" "$@" </dev/null >/dev/null 2>&1 ) || true
  [ -e "$S135C_TRIP" ] && printf 1 || printf 0
}
s135c_checked=0
s135c_bad=""
for s135c_spec in \
  "dir_mode_project.sh --help" \
  "migrate_v3.sh" \
  "onboard_target.sh --tier 1 --dry-run" \
  "setup_project.sh" \
; do
  # shellcheck disable=SC2086  # deliberate word-split of the fixed spec into argv
  set -- $s135c_spec
  s135c_script="$1"
  s135c_checked=$((s135c_checked+1))
  [ "$(s135c_fire "$@")" = 1 ] && s135c_bad="${s135c_bad}${s135c_script} "
done
if [ "$s135c_checked" = 4 ] && [ -z "$s135c_bad" ]; then
  ok "135c: all 4 CLI scripts ignore a hostile ambient GHJIG_ROOT and self-locate (fake tree untouched) (#539)"
else
  ng "135c: CLI script(s) loaded the AMBIENT fake tree (checked=$s135c_checked/4): ${s135c_bad:-none}(#539)"
fi
rm -rf "$S135C_DIR"

# §135d: unset-reachable audit-path bug (#539). narrowing_candidates.sh /
# promotion_candidates.sh source audit_log_path.sh WITHOUT exporting GHJIG_ROOT.
# With the ephemeral-state env also scrubbed, resolve_audit_log must anchor under
# the SELF-LOCATED shell root — never the filesystem-root-anchored `/.claude/audit
# /audit.jsonl` that the `${GHJIG_ROOT:-}` fallback yields today. Sourced exactly
# the way the consumer scripts do (`. "$HERE/lib/audit_log_path.sh"`). RED now.
s135d=$(
  env -u GHJIG_ROOT -u CLAUDE_PROJECT_DIR -u GHJIG_STATE_DIR_OVERRIDE \
    bash -c '. "$1/lib/audit_log_path.sh"; resolve_audit_log' _ "$SHELL_ROOT/scripts" 2>/dev/null
)
if [ "$s135d" = "$SHELL_ROOT/.claude/audit/audit.jsonl" ]; then
  ok "135d: env-scrubbed resolve_audit_log self-locates the shell root (not /.claude/audit) (#539)"
else
  ng "135d: unset GHJIG_ROOT → resolve_audit_log returned '$s135d' (want '$SHELL_ROOT/.claude/audit/audit.jsonl'; the filesystem-root /.claude/audit bug) (#539)"
fi

# §135e (AC-3): commands carry zero `$GHJIG_ROOT/`, and the runtime-executed
# command-prelude form resolves through the binding symlink in BOTH the dogfood
# repo and a freshly-injected target.
# e-1: grep guard — zero `$GHJIG_ROOT/` under .claude/commands/. RED now (recast pending).
s135e_n=$(grep -rn '\$GHJIG_ROOT/' "$SHELL_ROOT/.claude/commands/" 2>/dev/null | grep -c . || true)
if [ "$s135e_n" = 0 ]; then
  ok "135e-1: .claude/commands/ carry zero \$GHJIG_ROOT/ references (#539)"
else
  ng "135e-1: .claude/commands/ still contain $s135e_n \$GHJIG_ROOT/ reference(s) (want 0) (#539)"
fi
# The command-prelude form under test (SPEC §3.2.1 "Runtime-executed"):
#   GR="$(git rev-parse --show-toplevel)/.claude/ghjig-root"; [ -e "$GR/.claude" ]
s135e_prelude='
  GR="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/ghjig-root"
  [ -e "$GR/.claude" ] || { echo NORESOLVE; exit 0; }
  ( cd "$GR" 2>/dev/null && pwd -P )'
# e-2: dogfood repo — RED now (the committed .claude/ghjig-root self-symlink is absent).
s135e2=$( cd "$SHELL_ROOT" && env -u GHJIG_ROOT -u GHJIG_ROOT_OVERRIDE -u CLAUDE_PROJECT_DIR \
  bash -c "$s135e_prelude" 2>/dev/null )
if [ -n "$s135e2" ] && [ "$s135e2" != NORESOLVE ] && [ -d "$s135e2/.claude/hooks" ]; then
  ok "135e-2: dogfood command-prelude GR resolves to a shell root with .claude/hooks (#539)"
else
  ng "135e-2: dogfood command-prelude GR did not resolve (got '$s135e2'; committed self-symlink absent) (#539)"
fi
# e-3: freshly-injected target — CONTROL (green pre- AND post-flip): inject already
# creates the binding symlink, so a RED here would implicate the inject path, not #539.
S135E=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S135E" && git init -q ) >/dev/null 2>&1
inject_into "$S135E" >/dev/null 2>&1
s135e3=$( cd "$S135E" && env -u GHJIG_ROOT -u GHJIG_ROOT_OVERRIDE -u CLAUDE_PROJECT_DIR \
  bash -c "$s135e_prelude" 2>/dev/null )
if [ "$s135e3" = "$SHELL_ROOT" ] && [ -d "$s135e3/.claude/hooks" ]; then
  ok "135e-3: injected-target command-prelude GR resolves to the canonical shell root (control) (#539)"
else
  ng "135e-3: injected-target GR resolution wrong (got '$s135e3', want '$SHELL_ROOT') (#539)"
fi
rm -rf "$S135E"

# ---------- §136: reviewer artifact head-pin (#544) ----------
# SPEC §4.5/§4.6/§1.5/§5.7/§5.6/§4.11 (Doc phase, this branch): a worktree-isolated
# reviewer is checked out at the harness-chosen BASE, not the pushed PR head, so a
# post-push reviewer that reads the ambient tree reviews a STALE artifact and can
# still APPROVE (PR #543). The fix pins the review artifact to the PR head by
# construction on the reviewer side (resolve via `gh pr view --json headRefOid` /
# `gh pr diff` / `git show <HEAD_SHA>:<path>`, no checkout; emit a first-line
# `reviewed-head:` verdict), and closes the loop on the CALLER side (`/ship`,
# `/review`): compute the expected head privately, blind-compare each reviewer's
# independently-reported `reviewed-head`, and treat a mismatch / absent / unconfirmed
# head as a fail-closed INVALID vote (never an approve). Each grep pairs a token with
# a content anchor that survives mild paraphrase (mirrors §25). RED now (items a-d are
# the Code-phase product files; e is a Doc-phase-confirming guard, expected green).
S136_CODE_REV="$SHELL_ROOT/.claude/agents/code-reviewer.md"
S136_SEC_REV="$SHELL_ROOT/.claude/agents/security-reviewer.md"
S136_SHIP="$SHELL_ROOT/.claude/commands/ship.md"
S136_REVIEW="$SHELL_ROOT/.claude/commands/review.md"

# §136a (item 1): code-reviewer.md resolves its artifact from the pushed PR head
# (`headRefOid` + `gh pr diff`), reads changed-file context via `git show <head>:`
# (no checkout), and emits a `reviewed-head:` verdict line. RED now: the prompt has a
# generic `gh pr diff` bullet but NO head-pin (`headRefOid`) and NO `reviewed-head`.
if grep -qF 'headRefOid' "$S136_CODE_REV" 2>/dev/null \
   && grep -qF 'reviewed-head' "$S136_CODE_REV" 2>/dev/null \
   && grep -qF 'gh pr diff' "$S136_CODE_REV" 2>/dev/null; then
  ok "136a: code-reviewer.md pins artifact to PR head (headRefOid + gh pr diff) and emits reviewed-head (#544)"
else
  ng "136a: code-reviewer.md missing head-pin (headRefOid) or reviewed-head verdict line (#544)"
fi

# §136b (item 2): security-reviewer.md carries the SAME artifact-resolution contract
# as §4.5 — an Input/artifact section referencing the head-pin (`headRefOid`) plus the
# `reviewed-head` emission. RED now: security-reviewer.md has NO Input section at all.
if grep -qF 'headRefOid' "$S136_SEC_REV" 2>/dev/null \
   && grep -qF 'reviewed-head' "$S136_SEC_REV" 2>/dev/null; then
  ok "136b: security-reviewer.md carries the §4.5 artifact head-pin + reviewed-head contract (#544)"
else
  ng "136b: security-reviewer.md missing artifact head-pin (headRefOid) or reviewed-head emission (#544)"
fi

# §136c (item 3): ship.md caller-side blind compare — computes the expected head
# (`headRefOid`), treats a `reviewed-head` mismatch/absent as a fail-closed invalid
# vote, AND holds the expected head PRIVATELY (blindness: never passed/revealed to the
# reviewer, else the reviewer could echo it back for a tautological pass). RED now.
if grep -qF 'headRefOid' "$S136_SHIP" 2>/dev/null \
   && grep -qF 'reviewed-head' "$S136_SHIP" 2>/dev/null \
   && grep -qiE 'privat|never (passed|revealed)|not (passed|revealed)|held privately' "$S136_SHIP" 2>/dev/null; then
  ok "136c: ship.md computes expected head, blind-compares reviewed-head, holds head privately (#544)"
else
  ng "136c: ship.md missing caller-side head-pin (headRefOid/reviewed-head) or blindness anchor (#544)"
fi

# §136d (item 4): review.md carries the same caller-side head-pin (compute expected
# head privately + blind-compare reviewed-head). RED now: no head-pin text present.
if grep -qF 'headRefOid' "$S136_REVIEW" 2>/dev/null \
   && grep -qF 'reviewed-head' "$S136_REVIEW" 2>/dev/null; then
  ok "136d: review.md applies the caller-side head-pin (headRefOid + reviewed-head compare) (#544)"
else
  ng "136d: review.md missing caller-side head-pin (headRefOid/reviewed-head compare) (#544)"
fi

# §136e (item 5, Doc-phase-confirming — expected GREEN): SPEC §4.11 tally is now the
# fixed-denominator form. The old fail-open "excluded from the majority" wording must
# be GONE (count 0) and the "2 valid approve"/"invalid vote" fixed-3-denominator
# wording PRESENT. Anti-vacuity: require the positive anchors, not just the absence.
s136e_stale=$(grep -cF 'excluded from the majority' "$SHELL_ROOT/SPEC.md" 2>/dev/null)
if [ "${s136e_stale:-0}" -eq 0 ] \
   && grep -qF '2 valid approve' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qF 'invalid vote' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "136e: SPEC §4.11 tally is fixed-denominator (2 valid approve / invalid vote; no fail-open exclusion) (#544)"
else
  ng "136e: SPEC §4.11 still carries fail-open 'excluded from the majority' or lacks fixed-denominator wording (#544)"
fi

