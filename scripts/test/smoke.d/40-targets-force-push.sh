# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- 61. target-substrate foundation: SPEC §1.7 Substrate-in-target contract (#114) ----------
# Issue #114 (foundation slice of Directive #107) landed the design foundation
# for target-substrate installation. The boundary-expansion rationale + three-tier
# feature model + graceful-degradation principle + reversibility contract now live
# inline in SPEC §1.7's "Substrate-in-target contract" subsection. §61 is a
# static-file regression: catches "SPEC §1.7 subsection deleted" or "three-tier
# / graceful-degradation / reversibility clauses removed" in a future PR.

# §61a: SPEC §1.7 names the "Substrate-in-target contract" subsection.
if grep -q "Substrate-in-target contract" "$SHELL_ROOT/SPEC.md"; then
  ok "61a: SPEC §1.7 names 'Substrate-in-target contract' subsection (#114; updated #162)"
else
  ng "61a: SPEC §1.7 missing 'Substrate-in-target contract' subsection (#114; updated #162)"
fi

# §61b: SPEC §1.7 carries the three load-bearing target-substrate clauses inline.
if grep -q "Three-tier feature model" "$SHELL_ROOT/SPEC.md" \
   && grep -q "Graceful-degradation principle" "$SHELL_ROOT/SPEC.md" \
   && grep -q "Reversibility contract" "$SHELL_ROOT/SPEC.md"; then
  ok "61b: SPEC §1.7 carries Three-tier / Graceful-degradation / Reversibility clauses inline (#114; updated #162)"
else
  ng "61b: SPEC §1.7 missing one or more target-substrate clauses (#114; updated #162)"
fi

# §61c (#265): the §2.1 Directive lifecycle uses `/activate` (not the deprecated
# `/activate-directive` alias) as the operative Active-state entry transition.
# Guards the EI-A alias purge against regression. Positive assertion: the state
# table's Active row names `/activate` as the entry transition.
if grep -qE '^\| `Active` \|.*\| `/activate` \(removes `status:proposed`' "$SHELL_ROOT/SPEC.md"; then
  ok "61c: SPEC §2.1 Active-state entry transition is /activate, not the deprecated alias (#265)"
else
  ng "61c: SPEC §2.1 Active-state entry transition not /activate — deprecated-alias regression (#265)"
fi

# ---------- 62. discussion-tier lifecycle: skills + enforcement + /triage (#116) ----------
# Issue #116 (final slice of Directive #109) ships the deferred items from
# SPEC §5.19's "Deferred to follow-up" list: /discuss + /resolve-discussion
# skills, close-path enforcement in the trusted-filer-mutate matcher, and
# /triage extension to surface stale discussions.

# §62a: /discuss skill file exists and has the reduced-required shape.
if [ -f "$SHELL_ROOT/.claude/commands/discuss.md" ] \
   && grep -q "No rationale triad, no reviewer gate" "$SHELL_ROOT/.claude/commands/discuss.md" \
   && grep -q '"discussion"' "$SHELL_ROOT/.claude/commands/discuss.md"; then
  ok "62a: /discuss skill declares friction-free filing + discussion label (#116)"
else
  ng "62a: /discuss skill missing or lacks reduced-required shape (#116)"
fi

# §62b: /resolve-discussion skill file exists with both --promoted-to and --no-action modes.
if [ -f "$SHELL_ROOT/.claude/commands/resolve-discussion.md" ] \
   && grep -q -- "--promoted-to" "$SHELL_ROOT/.claude/commands/resolve-discussion.md" \
   && grep -q -- "--no-action" "$SHELL_ROOT/.claude/commands/resolve-discussion.md" \
   && grep -q "reason completed" "$SHELL_ROOT/.claude/commands/resolve-discussion.md" \
   && grep -q 'reason "not planned"' "$SHELL_ROOT/.claude/commands/resolve-discussion.md"; then
  ok "62b: /resolve-discussion skill names both close paths + reasons (gh-valid space form, #216)"
else
  ng "62b: /resolve-discussion skill missing or lacks both close-path modes (#116)"
fi

# §62c-e: trusted-filer-mutate matcher hook test — close-path enforcement on discussion Issues.
# Reuses the §55 (filer-aware) mock-gh shim pattern.
S62_DIR=$(mktemp -d)
mkdir -p "$S62_DIR/bin" "$S62_DIR/target"
S62_TARGET=$(cd "$S62_DIR/target" && pwd -P)
(cd "$S62_TARGET" && git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
 git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
printf '%s\n' "$S62_TARGET" >> "$SMOKE_REG"

# Mock gh: returns labels including "discussion" for issue view + --jq-aware
# output (the hook calls `gh issue view N --json labels --jq '.labels[].name'`
# which would yield raw label names one-per-line).
cat > "$S62_DIR/bin/gh" <<'GHEOF'
#!/bin/sh
# Mock gh for §62 — discussion-tier close-path enforcement.
case "$*" in
  *"repo view"*"--json owner"*)
    # is_trusted_filer resolves the current repo via `gh repo view` for its
    # cache key + authorAssociation query; serve it so the trusted path is
    # reachable (previously absent → is_trusted_filer bailed unresolvable → the
    # over-block was doubly masked, #236).
    printf 'mock\n'
    exit 0
    ;;
  *"repo view"*"--json name"*)
    printf 'repo\n'
    exit 0
    ;;
  *"issue view"*"--json"*"--jq"*)
    # The hook's Stage-1 query calls --json labels --jq '.labels[].name'; emit
    # the label names raw.
    printf 'discussion\n'
    exit 0
    ;;
  *"issue view"*"authorAssociation"*)
    # is_trusted_filer queries --json authorAssociation -q '.authorAssociation'
    # (a `-q` scalar, NOT --jq). Return the scalar so trust actually resolves —
    # issue 999 is OWNER (trusted). Previously this fell to the JSON-blob arm
    # below, so is_trusted_filer read untrusted and masked the #236 over-block.
    printf 'OWNER\n'
    exit 0
    ;;
  *"issue view"*"--json"*)
    printf '{"labels":[{"name":"discussion"}],"authorAssociation":"OWNER","state":"OPEN","number":999}\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GHEOF
chmod +x "$S62_DIR/bin/gh"

s62_close_run() {
  local cmd="$1"
  (
    cd "$S62_TARGET" || exit 1
    # jq-encode so a command carrying inner quotes (e.g. --reason "not planned")
    # stays valid JSON (#216).
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)" \
      | PATH="$S62_DIR/bin:$PATH" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
  )
  return $?
}

# Cache isolation (#238): clear the whole leaf is_trusted_filer cache dir once
# at §62 start so the trusted path is exercised against the §62 mock, not a
# stale fixture from §55 or a prior run. is_trusted_filer writes into the real
# $GHJIG_ROOT cache (no override env; the hook resolves helpers from
# ROOT). `.gitignore` covers `.claude/state/`, so this leaf is never committed.
rm -rf "$SHELL_ROOT/.claude/state/issue-filer-cache"

# §62c: bare `gh issue close <N>` on discussion-labeled Issue → BLOCKED (rc=2).
s62_close_run "gh issue close 999"
case $? in
  2) ok "62c: bare gh issue close on discussion Issue → block (#116)" ;;
  *) ng "62c: expected rc=2 (block) for bare close on discussion, got rc=$? (#116)" ;;
esac

# §62d: `gh issue close <N> --reason completed` on discussion-labeled Issue → ALLOWED (rc=0).
s62_close_run "gh issue close 999 --reason completed"
case $? in
  0) ok "62d: gh issue close --reason completed on discussion Issue → allow (#116)" ;;
  *) ng "62d: expected rc=0 (allow) for --reason completed, got rc=$? (#116)" ;;
esac

# §62e: `gh issue close <N> --reason "not planned"` (gh-valid SPACE form) on a
# discussion Issue → ALLOWED (rc=0). Issue 999 is authored by a trusted filer
# (OWNER) — now that the mock fully serves is_trusted_filer (repo view + scalar
# authorAssociation), this exercises the §236 path: discussion-tier is-not-planned
# is the sanctioned §5.19 no-action close and must be allowed REGARDLESS of filer
# trust (pre-#236 it was short-circuited into the Stage-2 trusted-filer block).
s62_close_run 'gh issue close 999 --reason "not planned"'
case $? in
  0) ok "62e: trusted-filer discussion + --reason \"not planned\" → allow (§5.19, #236)" ;;
  *) ng "62e: expected rc=0 (allow) for trusted-filer discussion not-planned, got rc=$? (#236)" ;;
esac

# §62e2 (#216/#236): the legacy underscore form is still TOLERATED (hook never the
# blocker), AND on this trusted-filer discussion Issue it must be allowed via the
# §236 discussion-first path, not blocked by Stage-2 trust.
s62_close_run "gh issue close 999 --reason not_planned"
case $? in
  0) ok "62e2: legacy --reason not_planned still tolerated by the hook (#216)" ;;
  *) ng "62e2: expected rc=0 (tolerance) for legacy underscore, got rc=$? (#216)" ;;
esac

# §62e3 (#216): `--reason duplicate` is NOT one of the two discussion close paths
# (§5.19) and must NOT be mistaken for not-planned by the tolerant regex → BLOCK.
s62_close_run "gh issue close 999 --reason duplicate"
case $? in
  2) ok "62e3: --reason duplicate on discussion Issue → block (not a §5.19 path; no over-match) (#216)" ;;
  *) ng "62e3: expected rc=2 (block) for --reason duplicate, got rc=$? (#216)" ;;
esac

# §62g/§62h (#499 / Directive #498): a leading gh GLOBAL FLAG before `issue close`
# must not bypass the trusted-filer-mutate entry anchor (pre_tool_use.sh :459).
# The tight `\bgh[[:space:]]+issue[[:space:]]+(close|edit)` anchor missed
# `gh -R o/r issue close` / `gh --repo o/r issue close`; the #499 fix widens it to
# tolerate a leading global-flag run. Placed inside §62 (before the cleanup
# below) so the fresh s62 mock/target is in scope. §62g is RED before the fix
# (leading flag → arm never enters → allow); §62h is the no-over-block guard.
# §62g: leading -R before `issue close` (no --reason) on the discussion/OWNER
# Issue must BLOCK (rc=2), exactly as the bare §62c form does.
s62_close_run "gh -R o/r issue close 999"
case $? in
  2) ok "62g: leading -R before 'issue close' → trusted-filer still blocks (#499)" ;;
  *) ng "62g: leading -R bypassed trusted-filer-mutate, got rc=$? (#499)" ;;
esac
# §62h: leading --repo + a valid `--reason completed` close must still ALLOW (rc=0)
# — the widened anchor must not over-block the compliant completed-close path.
s62_close_run "gh --repo mock/repo issue close 999 --reason completed"
case $? in
  0) ok "62h: leading --repo + --reason completed still allowed (no over-block) (#499)" ;;
  *) ng "62h: leading-flag completed close wrongly blocked, got rc=$? (#499)" ;;
esac

# Cleanup §62.
sp_tmp_reg=$(mktemp); grep -vxF "$S62_TARGET" "$SMOKE_REG" > "$sp_tmp_reg" 2>/dev/null || true
mv "$sp_tmp_reg" "$SMOKE_REG"
rm -rf "$S62_DIR"

# §62f: stale-discussion surface lives in /activate batch mode (relocated from
# /triage by #173, SPEC §5.19 step 2.5 → §5.12).
if grep -q "Stale-discussion surface" "$SHELL_ROOT/.claude/commands/activate.md" \
   && grep -q "label discussion" "$SHELL_ROOT/.claude/commands/activate.md"; then
  ok "62f: /activate batch mode surfaces stale discussion queue (#116/#173)"
else
  ng "62f: /activate missing stale-discussion surface logic (relocated from /triage, #173)"
fi

# ---------- 63. target-substrate implementation: canonical dir + /onboard-dir-mode + preflight (#118) ----------
# Issue #118 (final slice of Directive #107) ships the install machinery:
# canonical-source directory, /onboard-dir-mode skill, scripts/onboard_target.sh,
# and per-command graceful-degradation preflight references.

# §63a: canonical-source directory has the 11 expected files.
S63_SUB="$SHELL_ROOT/.claude/templates/target-substrate"
s63a_count=0
for f in ISSUE_TEMPLATE/config.yml ISSUE_TEMPLATE/directive-proposal.yml \
         ISSUE_TEMPLATE/execution-under-directive.yml ISSUE_TEMPLATE/task.yml \
         ISSUE_TEMPLATE/bug-report.yml ISSUE_TEMPLATE/discussion.yml \
         workflows/auto-status-proposed.yml workflows/auto-clear-awaiting-author.yml \
         workflows/issues-to-project-mirror.yml \
         workflows/dir-mode-post-merge.yml workflows/check-changelog.yml \
         workflows/check-toc.yml \
         workflows/initiative-feedback-label.yml \
         workflows/resolve_parent_directive.sh \
         workflows/detect_bare_refs_directive.sh \
         workflows/build_toc.sh; do
  [ -f "$S63_SUB/$f" ] && s63a_count=$((s63a_count + 1))
done
if [ "$s63a_count" = 16 ]; then
  ok "63a: target-substrate canonical-source has 16 files (6 ISSUE_TEMPLATE + 7 workflows + 3 sourced helpers) (#118 + #133 + #180 + #335 + #337 + #347 + #359)"
else
  ng "63a: target-substrate canonical-source missing files: expected 16, found $s63a_count (#118 + #133 + #180 + #335 + #337 + #347 + #359)"
fi

# §63b: /onboard-dir-mode skill file exists with tiered procedure.
if [ -f "$SHELL_ROOT/.claude/commands/onboard-dir-mode.md" ] \
   && grep -q "Tier 1" "$SHELL_ROOT/.claude/commands/onboard-dir-mode.md" \
   && grep -q "Tier 2" "$SHELL_ROOT/.claude/commands/onboard-dir-mode.md" \
   && grep -q "Tier 3" "$SHELL_ROOT/.claude/commands/onboard-dir-mode.md"; then
  ok "63b: /onboard-dir-mode skill names all 3 tiers (#118)"
else
  ng "63b: /onboard-dir-mode skill missing or lacks tier-aware procedure (#118)"
fi

# §63c: scripts/onboard_target.sh exists + executable + handles --tier flag.
if [ -x "$SHELL_ROOT/scripts/onboard_target.sh" ] \
   && grep -q -- "--tier" "$SHELL_ROOT/scripts/onboard_target.sh" \
   && grep -q "gh label create" "$SHELL_ROOT/scripts/onboard_target.sh"; then
  ok "63c: scripts/onboard_target.sh executable + tier-aware (#118)"
else
  ng "63c: scripts/onboard_target.sh missing or lacks tier handling (#118)"
fi

# §63d: scripts/onboard_target.sh --tier 1 --dry-run is a no-op (idempotent).
s63d_rc=0
"$SHELL_ROOT/scripts/onboard_target.sh" --tier 1 --dry-run >/dev/null 2>&1 || s63d_rc=$?
# The script exits 1 if `gh repo view` cannot resolve (not in a gh repo context).
# Smoke runs from the shell repo where gh is authed, so exit 0 expected. If
# gh auth is missing, accept rc=1 as graceful-failure (per the graceful-degradation principle, SPEC §1.7).
if [ "$s63d_rc" = 0 ] || [ "$s63d_rc" = 1 ]; then
  ok "63d: onboard_target.sh --tier 1 --dry-run is non-destructive (rc=$s63d_rc; expected 0 or 1) (#118)"
else
  ng "63d: onboard_target.sh --tier 1 --dry-run unexpected rc=$s63d_rc (#118)"
fi

# §63d2 (#238): `--tier` with NO value must print the usage diagnostic and exit
# non-zero — not crash with `$2: unbound variable` under `set -u`. Pre-#238 the
# `--tier) TIER="$2"` arm dereferenced an unbound $2. Assert the diagnostic text
# appears (proves the script's own validation ran, not bash's unbound-var abort).
s63d2_out=$("$SHELL_ROOT/scripts/onboard_target.sh" --tier 2>&1 || true)
s63d2_rc=0
"$SHELL_ROOT/scripts/onboard_target.sh" --tier >/dev/null 2>&1 || s63d2_rc=$?
if [ "$s63d2_rc" -ne 0 ] && printf '%s' "$s63d2_out" | grep -q -- "--tier"; then
  ok "63d2: onboard_target --tier with no value diagnoses cleanly (rc=$s63d2_rc, no unbound-var crash) (#238)"
else
  ng "63d2: --tier with no value crashed or gave no diagnostic (rc=$s63d2_rc, out=$s63d2_out) (#238)"
fi

# §63e: each of the 7 dir-mode command procedure files contains a substrate
# preflight step. Pattern broadened (#151) to match both the original
# "Step 0 ... preflight" phrasing and the compressed "Substrate preflight"
# one-liner introduced by Directive #149 / Issue #151 (the 4-line boilerplate
# was de-duplicated to a single shared statement per AC #4).
s63e_count=0
# activate-directive is now a thin alias (#172) delegating its preflight to
# /activate; the loop tracks the real command /activate.
for cmd in file-directive activate complete-directive revise-directive \
           block-directive list-directives link-directive; do
  if grep -qE "Step 0.*preflight|step 0 preflight|Substrate preflight" "$SHELL_ROOT/.claude/commands/${cmd}.md"; then
    s63e_count=$((s63e_count + 1))
  fi
done
if [ "$s63e_count" = 7 ]; then
  ok "63e: all 7 dir-mode commands name substrate preflight (#118; updated #151)"
else
  ng "63e: substrate preflight missing in some dir-mode commands: $s63e_count/7 (#118; updated #151)"
fi

# §63f: reversibility paths referenced from /onboard-dir-mode.
# Pattern updated (#162): reversibility content lives inline in SPEC §1.7 and
# /onboard-dir-mode cross-refs that. The structural assertion is that the skill
# names the reversibility contract or the SPEC subsection that anchors it.
if grep -qE "reversibility|Reversibility|Substrate-in-target" "$SHELL_ROOT/.claude/commands/onboard-dir-mode.md"; then
  ok "63f: /onboard-dir-mode references reversibility / Substrate-in-target framing (#118; updated #162)"
else
  ng "63f: /onboard-dir-mode missing reversibility / Substrate-in-target reference (#118; updated #162)"
fi

# §63g: tier-2 dry-run produces label-create lines for BOTH status:proposed
# AND status:blocked. Regression guard for the v0 parser bug (caught at
# PR #119 code-review) where `:`-delimited parsing on `status:proposed:FBCA04...`
# would split as name=status / color=proposed / desc=FBCA04:... silently
# dropping the two `status:*` labels. The smoke §63d --tier 1 path didn't
# exercise label parsing; §63g closes the gap.
s63g_out=$("$SHELL_ROOT/scripts/onboard_target.sh" --tier 2 --dry-run 2>&1 || true)
s63g_ok=1
for required in "status:proposed" "status:blocked" "awaiting-author" "execution" "discussion" "task" "skip-changelog" "P0" "P1" "P2" "P3" "initiative:challenged" "initiative:completion-requested" "directive" "initiative"; do
  if ! printf '%s' "$s63g_out" | grep -qE "gh label create '$required'"; then
    s63g_ok=0
    break
  fi
done
if [ "$s63g_ok" = 1 ]; then
  ok "63g: onboard_target --tier 2 --dry-run emits gh label create for all 15 dir-mode labels incl. the inline directive + initiative type-keys and the #359 initiative-feedback projection labels (#118 + #133 + #249 + #359)"
else
  ng "63g: onboard_target --tier 2 --dry-run missing one or more required labels (regression-guard for label-parser drift) (#118 + #133)"
fi

# §63h: substrate-preflight grep CORRECTNESS (#189). §63e asserts the preflight
# is PRESENT; this asserts its grep can actually match. `gh label list` is
# tab-separated (name<TAB>desc<TAB>color), so `grep -qx directive` (whole-line-
# exact) never matches → the guard silently falls open (a no-op that never
# guards). The correct form pipes through `cut -f1` first, as /activate and
# /file-directive step-3 already do. Two-part guard: (a) no command file retains
# the whole-line form (AC#1 predicate verbatim); (b) the 6 directive-gated
# commands use the `cut -f1` form.
s63h_stale=$(grep -rlF 'gh label list | grep -qx' "$SHELL_ROOT/.claude/commands/" 2>/dev/null || true)
s63h_cut=0
for cmd in file-directive complete-directive revise-directive \
           block-directive list-directives link-directive; do
  if grep -qF 'gh label list | cut -f1 | grep -qx directive' "$SHELL_ROOT/.claude/commands/${cmd}.md"; then
    s63h_cut=$((s63h_cut + 1))
  fi
done
if [ -z "$s63h_stale" ] && [ "$s63h_cut" = 6 ]; then
  ok "63h: substrate-preflight grep uses cut -f1 in all 6 directive-gated commands; no whole-line form remains (#189)"
else
  ng "63h: substrate-preflight grep regression — whole-line form in [$(printf '%s' "${s63h_stale:-none}" | tr '\n' ' ')], cut-form count $s63h_cut/6 (#189)"
fi

# §63i: SPEC §1.7 tier-3 workflow brace-list names all 5 installed workflows,
# incl. check-changelog (#190). §63a asserts the canonical source SHIPS 5
# workflows; §63i asserts the SPEC §1.7 "Substrate-in-target contract" TEXT
# names check-changelog in the tier-3 brace-list — the doc-vs-shipped drift
# #190 corrects. Anchored to the brace-list via auto-status-proposed (the
# first list member) so it matches only the tier-3 line, not check-changelog
# mentions elsewhere in SPEC (e.g. §66 references).
if grep -qE 'auto-status-proposed.*check-changelog' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "63i: SPEC §1.7 tier-3 workflow brace-list includes check-changelog (5 workflows) (#190)"
else
  ng "63i: SPEC §1.7 tier-3 workflow brace-list omits check-changelog (doc-vs-shipped drift) (#190)"
fi

# §63k (#359): the initiative-feedback-label workflow template has the required
# shape — fires on issue_comment(created), has issues:write, and carries both
# Initiative markers + both projection labels so the marker→label mapping is
# present. Shape-only (an Action's runtime is not reproducible locally; the
# mapping itself is an AC-documented check). Template-only — no dogfood copy in
# the shell's own .github/workflows/ (the §48f cmp-lock is dir-mode-post-merge
# scoped; the shell has no Initiatives to label).
IFL_WF="$SHELL_ROOT/.claude/templates/target-substrate/workflows/initiative-feedback-label.yml"
if [ -f "$IFL_WF" ] \
   && grep -q 'issue_comment' "$IFL_WF" \
   && grep -qE 'types:.*created' "$IFL_WF" \
   && grep -qE 'issues:[[:space:]]*write' "$IFL_WF" \
   && grep -qF '## Initiative challenge' "$IFL_WF" \
   && grep -qF '## Initiative completion' "$IFL_WF" \
   && grep -qF 'initiative:challenged' "$IFL_WF" \
   && grep -qF 'initiative:completion-requested' "$IFL_WF"; then
  ok "63k: initiative-feedback-label.yml has issue_comment(created) + issues:write + both markers + both projection labels (#359)"
else
  ng "63k: initiative-feedback-label.yml missing required shape (event/perms/markers/labels) (#359)"
fi

# §63j: tier-3 onboard change-detection must see UNTRACKED .github (#343). On a
# greenfield target the freshly-copied substrate is untracked; `git diff --quiet
# -- .github/` is blind to untracked paths (returns 0 = "no changes"), so the
# tier-3 PR-creation branch was skipped and the substrate never installed. The
# fix swaps the predicate to `git status --porcelain -- .github/` (non-empty =>
# changes), which sees untracked + modified + staged and is read-only on the
# index. Two-part guard: (a) a live throwaway-repo truth table proving porcelain
# sees untracked where diff --quiet does not, and that a clean tracked tree is
# empty (idempotent skip preserved); (b) the script source uses the porcelain
# gate and no longer carries the bare `diff --quiet -- .github/` predicate.
s63j_tmp=$(mktemp -d)
(
  cd "$s63j_tmp" || exit 9
  git init -q || exit 9
  git config user.email smoke@example.com; git config user.name smoke
  # Disable commit signing: a user's global commit.gpgsign=true would otherwise
  # make these throwaway commits fail (no signing key in the smoke context).
  git config commit.gpgsign false
  git commit --allow-empty -q -m init || exit 9
  mkdir -p .github/workflows
  printf 'x\n' > .github/workflows/probe.yml
  # Untracked .github/: porcelain MUST report it; diff --quiet MUST NOT (the bug).
  [ -n "$(git status --porcelain -- .github/)" ] || exit 1
  git diff --quiet -- .github/ || exit 2   # exit 2 only if diff DID see it (it shouldn't)
  # Already-onboarded (committed) .github/: porcelain MUST be empty (idempotent skip).
  git add .github/ && git commit -q -m onboard || exit 9
  [ -z "$(git status --porcelain -- .github/)" ] || exit 3
  exit 0
)
s63j_git_rc=$?
rm -rf "$s63j_tmp"
s63j_src_bad=""
s63j_ot="$SHELL_ROOT/scripts/onboard_target.sh"
grep -q 'status --porcelain -- .github/' "$s63j_ot" 2>/dev/null || s63j_src_bad="$s63j_src_bad porcelain-gate-missing"
grep -q 'diff --quiet -- .github/' "$s63j_ot" 2>/dev/null && s63j_src_bad="$s63j_src_bad bare-diff-quiet-present"
if [ "$s63j_git_rc" = 0 ] && [ -z "$s63j_src_bad" ]; then
  ok "63j: tier-3 onboard detects untracked .github via status --porcelain (#343)"
else
  ng "63j: untracked-.github detection regression: git_rc=$s63j_git_rc src=[${s63j_src_bad:-ok}] (#343)"
fi

# ---------- 64. version surface (#123 / Directive #122) ----------
# 64a — VERSION file is exactly one non-empty line (semver 0.x format
# locked by Directive #122 constraint #1; no comments, no trailing
# blank lines).
s64a_lines=$(wc -l < "$SHELL_ROOT/VERSION" 2>/dev/null | tr -d ' ')
s64a_content=$(tr -d '[:space:]' < "$SHELL_ROOT/VERSION" 2>/dev/null)
if [ "$s64a_lines" = "1" ] && [ -n "$s64a_content" ]; then
  ok "64a: VERSION is exactly one non-empty line (#123)"
else
  ng "64a: VERSION is not single non-empty line (lines=$s64a_lines content_empty=$([ -z "$s64a_content" ] && echo yes || echo no)) (#123)"
fi

# 64b — `bin/ghjig --version` exits 0 from an unregistered cwd and
# emits the shell's own VERSION (not the underlying `claude` CLI's
# version). Confirms the --version short-circuit runs before the
# registry/scope guard AND before `exec claude` (Directive #122
# constraint #3; required because line 39 of bin/ghjig currently
# `exec`s to `claude`, so any pre-fix forward-through gets caught here).
s64b_tmp=$(mktemp -d)
s64b_out=$(cd "$s64b_tmp" && "$SHELL_ROOT/bin/ghjig" --version 2>/dev/null)
s64b_rc=$?
rm -rf "$s64b_tmp"
s64b_expected=$(cat "$SHELL_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')
s64b_got=$(printf '%s' "$s64b_out" | tr -d '[:space:]')
if [ "$s64b_rc" = "0" ] && [ -n "$s64b_out" ] && [ "$s64b_got" = "$s64b_expected" ]; then
  ok "64b: bin/ghjig --version exits 0 with shell's VERSION ('$s64b_expected') from unregistered cwd (#123)"
else
  ng "64b: bin/ghjig --version did not return shell's VERSION (rc=$s64b_rc expected='$s64b_expected' got='$s64b_got') (#123)"
fi

# 64c (#318, Directive #311) — `ghjig list` advisory discovery. Runs before
# the scope guard (like --version), exits 0 from an unregistered cwd, and unions
# workspace/* resolved targets with the legacy shared registry, dedup by resolved
# path, skipping dangling symlinks. Tested against a FAKE shell root (ghjig
# self-locates its root from BASH_SOURCE, so a copy under $FAKE/bin resolves to
# $FAKE), mirroring §9b's fake-root pattern.
S64C_FAKE=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S64C_FAKE/bin" "$S64C_FAKE/workspace" "$S64C_FAKE/.claude/state"
cp "$SHELL_ROOT/bin/ghjig" "$S64C_FAKE/bin/ghjig"; chmod +x "$S64C_FAKE/bin/ghjig"
S64C_T1=$(cd "$(mktemp -d)" && pwd -P)   # workspace-only
S64C_T2=$(cd "$(mktemp -d)" && pwd -P)   # in BOTH workspace + legacy (dedup target)
S64C_T3=$(cd "$(mktemp -d)" && pwd -P)   # legacy-only
ln -sfn "$S64C_T1" "$S64C_FAKE/workspace/t1"
ln -sfn "$S64C_T2" "$S64C_FAKE/workspace/t2"
ln -sfn "$S64C_FAKE/workspace/nonexistent-xyz-$$" "$S64C_FAKE/workspace/dangling"  # dangling
printf '%s\n%s\n' "$S64C_T2" "$S64C_T3" > "$S64C_FAKE/.claude/state/registry.txt"
S64C_CWD=$(cd "$(mktemp -d)" && pwd -P)   # unregistered cwd
s64c_out=$(cd "$S64C_CWD" && "$S64C_FAKE/bin/ghjig" list 2>/dev/null); s64c_rc=$?
s64c_t2count=$(printf '%s\n' "$s64c_out" | grep -cxF "$S64C_T2")
if [ "$s64c_rc" = "0" ] \
   && printf '%s\n' "$s64c_out" | grep -qxF "$S64C_T1" \
   && printf '%s\n' "$s64c_out" | grep -qxF "$S64C_T2" \
   && printf '%s\n' "$s64c_out" | grep -qxF "$S64C_T3" \
   && [ "$s64c_t2count" = "1" ] \
   && ! printf '%s\n' "$s64c_out" | grep -q 'dangling\|nonexistent-xyz'; then
  ok "64c: ghjig list unions workspace+legacy, dedups, skips dangling, exits 0 from unregistered cwd (#318)"
else
  ng "64c: ghjig list wrong (rc=$s64c_rc t2count=$s64c_t2count out='$(printf '%s' "$s64c_out" | tr '\n' '|')') (#318)"
fi
rm -rf "$S64C_FAKE" "$S64C_T1" "$S64C_T2" "$S64C_T3" "$S64C_CWD"

# ---------- 65. /release skill (#131 / Directive #128) ----------
# §65 exercises scripts/release_consolidate.sh against throwaway git repos.
# The helper is invoked directly (no Claude session) so the deterministic
# logic — semver validate, preflight, fragment scan + validate, VERSION
# write-back, CHANGELOG prepend, fragment cleanup — is covered without
# needing to mock `gh`. Skill-body assertions (reviewer-gate language,
# post-merge recipe, no third-party Actions) are grep-locks in §65h.
#
# Helper contract under --dry-run (used by these tests):
#   - skip `git fetch origin` (no network in smoke)
#   - do check local tags via `git tag -l vX.Y.Z` for idempotency
#   - stage VERSION + CHANGELOG.md + `git rm --cached` of fragments
#   - exit 0 on success without commit/push/branch
# Real-mode is exercised by the skill body (grep-locked in §65h).

RELEASE_CONS="$SHELL_ROOT/scripts/release_consolidate.sh"

# Per-case throwaway-repo seeder. The helper expects the same on-disk
# shape an adopter repo would have post `/onboard-dir-mode`.
# usage: setup_release_smoke <dir> <version-content> [<cat> <num> <body>]
setup_release_smoke() {
  local dir="$1" ver="$2" cat="${3:-}" num="${4:-}" body="${5:-}"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && \
    git config user.email "smoke@example.com" && \
    git config user.name "smoke" && \
    git config commit.gpgsign false && \
    git config tag.gpgsign false && \
    printf '%s\n' "$ver" > VERSION && \
    printf '# Changelog\n\n## [0.1.0] — 2026-05-26\n\n### Added\n- prior release. (#1)\n\n[0.1.0]: https://example.test/releases/tag/v0.1.0\n' > CHANGELOG.md && \
    for c in added changed deprecated removed fixed security; do
      mkdir -p "changelog_unreleased/$c"
      touch "changelog_unreleased/$c/.gitkeep"
    done && \
    if [ -n "$cat" ] && [ -n "$num" ]; then
      printf '%s\n' "$body" > "changelog_unreleased/$cat/$num.md"
    fi && \
    git add -A && \
    git commit -q -m init ) >/dev/null 2>&1
}

# §65a — happy path: dry-run consolidates one Added fragment.
s65a_root=$(mktemp -d)
s65a_dir="$s65a_root/repo"
setup_release_smoke "$s65a_dir" "0.2.0-dev" "added" "131" "- /release skill ships. (#131)"
s65a_rc=1
if [ -x "$RELEASE_CONS" ]; then
  ( cd "$s65a_dir" && "$RELEASE_CONS" 0.2.0 --dry-run >/dev/null 2>&1 )
  s65a_rc=$?
fi
s65a_version=$(tr -d '[:space:]' < "$s65a_dir/VERSION" 2>/dev/null)
s65a_section=$(grep -c '^## \[0\.2\.0\]' "$s65a_dir/CHANGELOG.md" 2>/dev/null | tr -d ' ')
s65a_bullet=$(grep -c '/release skill ships' "$s65a_dir/CHANGELOG.md" 2>/dev/null | tr -d ' ')
s65a_fragment="missing"
[ -f "$s65a_dir/changelog_unreleased/added/131.md" ] && s65a_fragment="present"
[ ! -f "$s65a_dir/changelog_unreleased/added/131.md" ] && s65a_fragment="removed"
if [ "$s65a_rc" = "0" ] && [ "$s65a_version" = "0.2.0" ] && [ "$s65a_section" = "1" ] && [ "$s65a_bullet" = "1" ] && [ "$s65a_fragment" = "removed" ]; then
  ok "65a: /release 0.2.0 --dry-run strips -dev, prepends [0.2.0] section + bullet, removes fragment (#131)"
else
  ng "65a: /release happy path failed (rc=$s65a_rc version=$s65a_version section=$s65a_section bullet=$s65a_bullet fragment=$s65a_fragment) (#131)"
fi
rm -rf "$s65a_root"

# §65b — empty-fragments: no fragment files under any category subdir.
s65b_root=$(mktemp -d)
s65b_dir="$s65b_root/repo"
setup_release_smoke "$s65b_dir" "0.2.0-dev"
s65b_rc=0
s65b_err=""
if [ -x "$RELEASE_CONS" ]; then
  s65b_err=$( cd "$s65b_dir" && "$RELEASE_CONS" 0.2.0 --dry-run 2>&1 >/dev/null )
  s65b_rc=$?
fi
if [ "$s65b_rc" != "0" ] && printf '%s' "$s65b_err" | grep -q 'no fragments' && printf '%s' "$s65b_err" | grep -q 'changelog_unreleased'; then
  ok "65b: /release with empty fragments exits non-zero with 'no fragments' + 'changelog_unreleased' in stderr (#131)"
else
  ng "65b: /release empty-fragments check failed (rc=$s65b_rc err-has-no-fragments=$(printf '%s' "$s65b_err" | grep -qc 'no fragments') err-has-path=$(printf '%s' "$s65b_err" | grep -qc 'changelog_unreleased')) (#131)"
fi
rm -rf "$s65b_root"

# §65c — semver invalid (MAJOR=1): /release 1.0.0 rejected with MAJOR=0 invariant message.
s65c_root=$(mktemp -d)
s65c_dir="$s65c_root/repo"
setup_release_smoke "$s65c_dir" "0.2.0-dev" "added" "131" "- something. (#131)"
s65c_rc=0
s65c_err=""
if [ -x "$RELEASE_CONS" ]; then
  s65c_err=$( cd "$s65c_dir" && "$RELEASE_CONS" 1.0.0 --dry-run 2>&1 >/dev/null )
  s65c_rc=$?
fi
if [ "$s65c_rc" != "0" ] && printf '%s' "$s65c_err" | grep -q 'MAJOR=0'; then
  ok "65c: /release 1.0.0 rejected with 'MAJOR=0' invariant message (#131)"
else
  ng "65c: /release MAJOR=0 invariant check failed (rc=$s65c_rc err-has-major0=$(printf '%s' "$s65c_err" | grep -qc 'MAJOR=0')) (#131)"
fi
rm -rf "$s65c_root"

# §65d — semver invalid (format): /release notsemver rejected with semver message.
s65d_root=$(mktemp -d)
s65d_dir="$s65d_root/repo"
setup_release_smoke "$s65d_dir" "0.2.0-dev" "added" "131" "- something. (#131)"
s65d_rc=0
s65d_err=""
if [ -x "$RELEASE_CONS" ]; then
  s65d_err=$( cd "$s65d_dir" && "$RELEASE_CONS" notsemver --dry-run 2>&1 >/dev/null )
  s65d_rc=$?
fi
if [ "$s65d_rc" != "0" ] && printf '%s' "$s65d_err" | grep -qi 'semver'; then
  ok "65d: /release notsemver rejected with 'semver' format message (#131)"
else
  ng "65d: /release semver format check failed (rc=$s65d_rc err-has-semver=$(printf '%s' "$s65d_err" | grep -qci 'semver')) (#131)"
fi
rm -rf "$s65d_root"

# §65e — idempotent on existing tag: v0.1.0 tag exists, /release 0.1.0 no-ops.
s65e_root=$(mktemp -d)
s65e_dir="$s65e_root/repo"
setup_release_smoke "$s65e_dir" "0.1.0" "added" "131" "- something. (#131)"
( cd "$s65e_dir" && git tag -a v0.1.0 -m "v0.1.0" ) >/dev/null 2>&1
s65e_rc=99
s65e_out=""
if [ -x "$RELEASE_CONS" ]; then
  s65e_out=$( cd "$s65e_dir" && "$RELEASE_CONS" 0.1.0 --dry-run 2>&1 )
  s65e_rc=$?
fi
# Working tree unchanged after no-op invocation.
s65e_dirty=$( cd "$s65e_dir" && git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
if [ "$s65e_rc" = "0" ] && printf '%s' "$s65e_out" | grep -qi 'already released' && [ "$s65e_dirty" = "0" ]; then
  ok "65e: /release 0.1.0 with existing v0.1.0 tag is idempotent (rc=0, 'already released' message, no staged changes) (#131)"
else
  ng "65e: /release idempotency check failed (rc=$s65e_rc out-has-already=$(printf '%s' "$s65e_out" | grep -qci 'already released') dirty=$s65e_dirty) (#131)"
fi
rm -rf "$s65e_root"

# §65f — filename-stem mismatch: fragment added/42.md has bullet "(#99)" → rejected.
s65f_root=$(mktemp -d)
s65f_dir="$s65f_root/repo"
setup_release_smoke "$s65f_dir" "0.2.0-dev" "added" "42" "- mismatched ref. (#99)"
s65f_rc=0
s65f_err=""
if [ -x "$RELEASE_CONS" ]; then
  s65f_err=$( cd "$s65f_dir" && "$RELEASE_CONS" 0.2.0 --dry-run 2>&1 >/dev/null )
  s65f_rc=$?
fi
if [ "$s65f_rc" != "0" ] && printf '%s' "$s65f_err" | grep -q '42\.md' && printf '%s' "$s65f_err" | grep -qi 'mismatch'; then
  ok "65f: /release rejects filename-stem mismatch with file path + 'mismatch' in stderr (#131)"
else
  ng "65f: /release stem-mismatch check failed (rc=$s65f_rc err-has-file=$(printf '%s' "$s65f_err" | grep -qc '42\.md') err-has-mismatch=$(printf '%s' "$s65f_err" | grep -qci 'mismatch')) (#131)"
fi
rm -rf "$s65f_root"

# §65g — --base plumbing (static lock): skill body parses --base argument.
# Functional --base needs a maintenance branch + PR which smoke can't fake;
# AC#7 verified here as a skill-body assertion per the plan-reviewer note.
s65g_skill="$SHELL_ROOT/.claude/commands/release.md"
if [ -f "$s65g_skill" ] && grep -q -E '\-\-base <branch>' "$s65g_skill"; then
  ok "65g: /release skill body documents --base <branch> plumbing (#131)"
else
  ng "65g: /release skill body missing --base <branch> reference (#131)"
fi

# §65h — skill-body grep-locks for AC#7 (reviewer gate), AC#8 (post-merge
# recipe), AC#9 (no third-party Actions). Lock the contract surface.
s65h_skill="$SHELL_ROOT/.claude/commands/release.md"
s65h_ok=1
s65h_reasons=""
if ! grep -q -E 'code-reviewer' "$s65h_skill"; then
  s65h_ok=0
  s65h_reasons="$s65h_reasons missing-code-reviewer-ref;"
fi
if ! grep -q 'unattended' "$s65h_skill"; then
  s65h_ok=0
  s65h_reasons="$s65h_reasons missing-unattended-ref;"
fi
if ! grep -q -E 'gh release create' "$s65h_skill"; then
  s65h_ok=0
  s65h_reasons="$s65h_reasons missing-gh-release-create;"
fi
# No `uses:` lines in the skill body or helper script — third-party Actions
# would be referenced via that YAML key in a workflow file. Grep-lock on the
# skill + helper enforces AC#9 on the new surface this PR adds.
if grep -h -E '^\s*uses:\s+[^a]' "$s65h_skill" "$RELEASE_CONS" 2>/dev/null | grep -v -E 'uses:\s+actions/' | grep -q .; then
  s65h_ok=0
  s65h_reasons="$s65h_reasons third-party-action-detected;"
fi
if [ "$s65h_ok" = 1 ]; then
  ok "65h: /release skill body locks reviewer-gate + unattended + post-merge gh release recipe + no third-party Actions (#131)"
else
  ng "65h: /release skill-body grep-locks failed:$s65h_reasons (#131)"
fi

# §65i — the documented /release commit subject must pass the conventional-commit
# hook unmodified (#416). The template lived as `chore(release): X.Y.Z`, which the
# `commit-format` matcher rejects (re_optional permits only a (#N) scope or none),
# and the documented SKIP_HOOKS=branch escape does NOT cover commit-format — so
# every release commit made with the documented subject was blocked. This guard
# extracts the real documented subject and runs it through the real check (not a
# grep-lock), so a future re-introduction of a rejected scope — or a regex change
# that breaks the unchanged subject — fails smoke.
. "$SHELL_ROOT/.claude/hooks/helpers/conventional_commit.sh"
s65i_skill="$SHELL_ROOT/.claude/commands/release.md"
s65i_subject=$(grep -oE 'git commit -m "[^"]+"' "$s65i_skill" | head -1 | sed -E 's/^git commit -m "//; s/"$//')
# Resolve the <X.Y.Z> placeholder to a fixed valid semver (pinned, not VERSION-coupled).
s65i_resolved=${s65i_subject//<X.Y.Z>/0.3.0}
if [ -z "$s65i_subject" ]; then
  ng "65i: could not extract /release commit subject from release.md (#416)"
elif check_commit_subject "$s65i_resolved" 2>/dev/null; then
  ok "65i: documented /release commit subject passes conventional_commit hook unmodified (#416)"
else
  ng "65i: documented /release commit subject '$s65i_resolved' rejected by conventional_commit hook (#416)"
fi
# Premise lock: the pre-fix scoped form must remain rejected, else the guard is moot.
check_commit_subject "chore(release): 0.3.0" 2>/dev/null \
  && ng "65i: scoped chore(release) form unexpectedly accepted — guard premise broken (#416)" \
  || ok "65i: scoped chore(release) form correctly rejected by conventional_commit hook (#416)"

# ---------- §65j: manifest-match preflight (#469) ----------
# §65j exercises the verification-only manifest-match preflight Phase C adds to
# release_consolidate.sh (between X.Y.Z semver resolution and the VERSION
# write-back). The preflight resolves the detected stack's manifest version via
# a new detect_version() in detect_stack.sh and:
#   - confident MISMATCH (manifest ver != X.Y.Z) → non-zero exit, stderr names
#     BOTH the manifest version and the release version.
#   - MATCH (manifest ver == X.Y.Z) → preflight passes; release proceeds to the
#     normal staged dry-run success (exit 0, today's happy-path outcome).
#   - UNCERTAIN (unknown stack / absent manifest / unparseable field) → graceful
#     skip with a note, NON-blocking (run proceeds exactly as today).
#   - The preflight READS the manifest, never writes it.
# The §65 fixtures drop no package.json, so detect_stack resolves `unknown` →
# today's runs hit the uncertain/skip path. To force the node match/mismatch
# arms, §65j seeds a package.json with a `.version` into the fixture via a
# sibling seeder so detect_stack resolves `node`.
# RED expectation pre-Phase-C: 65j-1 (mismatch refuse) and 65j-2 (match pass)
# fail loud because no preflight exists yet; 65j-3 (non-block) and 65j-4
# (never-writes grep-lock) hold even pre-Code (standing guards).

# Sibling seeder: same shape as setup_release_smoke, plus a package.json with a
# `.version` so detect_stack resolves `node` and the preflight has a manifest to
# read. The package.json is committed into the init commit, so the working tree
# stays clean (the helper's Step-2 clean-tree preflight passes).
# usage: setup_release_smoke_node <dir> <version-content> <pkg-version> <cat> <num> <body>
setup_release_smoke_node() {
  local dir="$1" ver="$2" pkgver="$3" cat="${4:-}" num="${5:-}" body="${6:-}"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && \
    git config user.email "smoke@example.com" && \
    git config user.name "smoke" && \
    git config commit.gpgsign false && \
    git config tag.gpgsign false && \
    printf '%s\n' "$ver" > VERSION && \
    printf '{\n  "name": "smoke-fixture",\n  "version": "%s"\n}\n' "$pkgver" > package.json && \
    printf '# Changelog\n\n## [0.1.0] — 2026-05-26\n\n### Added\n- prior release. (#1)\n\n[0.1.0]: https://example.test/releases/tag/v0.1.0\n' > CHANGELOG.md && \
    for c in added changed deprecated removed fixed security; do
      mkdir -p "changelog_unreleased/$c"
      touch "changelog_unreleased/$c/.gitkeep"
    done && \
    if [ -n "$cat" ] && [ -n "$num" ]; then
      printf '%s\n' "$body" > "changelog_unreleased/$cat/$num.md"
    fi && \
    git add -A && \
    git commit -q -m init ) >/dev/null 2>&1
}

# §65j-1 — confident MISMATCH: node fixture with package.json version 0.1.0,
# cutting 0.2.0 → preflight must refuse (non-zero) AND stderr names BOTH versions.
s65j1_root=$(mktemp -d)
s65j1_dir="$s65j1_root/repo"
setup_release_smoke_node "$s65j1_dir" "0.2.0-dev" "0.1.0" "added" "469" "- preflight. (#469)"
s65j1_rc=0
s65j1_err=""
if [ -x "$RELEASE_CONS" ]; then
  s65j1_err=$( cd "$s65j1_dir" && "$RELEASE_CONS" 0.2.0 --dry-run 2>&1 >/dev/null )
  s65j1_rc=$?
fi
s65j1_has_manifest=$(printf '%s' "$s65j1_err" | grep -c '0\.1\.0')
s65j1_has_release=$(printf '%s' "$s65j1_err" | grep -c '0\.2\.0')
if [ "$s65j1_rc" != "0" ] && [ "$s65j1_has_manifest" -ge 1 ] && [ "$s65j1_has_release" -ge 1 ]; then
  ok "65j-1: manifest-match preflight refuses a confident mismatch (rc!=0) naming both manifest 0.1.0 + release 0.2.0 (#469)"
else
  ng "65j-1: manifest-mismatch refusal failed (rc=$s65j1_rc err-has-manifest=$s65j1_has_manifest err-has-release=$s65j1_has_release) (#469)"
fi
rm -rf "$s65j1_root"

# §65j-2 — MATCH: node fixture with package.json version 0.2.0, cutting 0.2.0 →
# preflight passes, release reaches today's normal staged dry-run success.
s65j2_root=$(mktemp -d)
s65j2_dir="$s65j2_root/repo"
setup_release_smoke_node "$s65j2_dir" "0.2.0-dev" "0.2.0" "added" "469" "- preflight match. (#469)"
s65j2_rc=1
if [ -x "$RELEASE_CONS" ]; then
  ( cd "$s65j2_dir" && "$RELEASE_CONS" 0.2.0 --dry-run >/dev/null 2>&1 )
  s65j2_rc=$?
fi
s65j2_version=$(tr -d '[:space:]' < "$s65j2_dir/VERSION" 2>/dev/null)
s65j2_section=$(grep -c '^## \[0\.2\.0\]' "$s65j2_dir/CHANGELOG.md" 2>/dev/null | tr -d ' ')
if [ "$s65j2_rc" = "0" ] && [ "$s65j2_version" = "0.2.0" ] && [ "$s65j2_section" = "1" ]; then
  ok "65j-2: manifest-match preflight passes a matching manifest; release reaches staged dry-run success (#469)"
else
  ng "65j-2: manifest-match pass-through failed (rc=$s65j2_rc version=$s65j2_version section=$s65j2_section) (#469)"
fi
rm -rf "$s65j2_root"

# Sibling seeder for the python/TOML stack: same shape as setup_release_smoke_node,
# but writes pyproject.toml ([project] version) instead of package.json so
# detect_stack resolves `python` and detect_version reads the pure-awk _toml_version
# (NO jq). usage: setup_release_smoke_toml <dir> <version-content> <toml-version> <cat> <num> <body>
setup_release_smoke_toml() {
  local dir="$1" ver="$2" tomlver="$3" cat="${4:-}" num="${5:-}" body="${6:-}"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && \
    git config user.email "smoke@example.com" && \
    git config user.name "smoke" && \
    git config commit.gpgsign false && \
    git config tag.gpgsign false && \
    printf '%s\n' "$ver" > VERSION && \
    printf '[project]\nname = "smoke-fixture"\nversion = "%s"\n' "$tomlver" > pyproject.toml && \
    printf '# Changelog\n\n## [0.1.0] — 2026-05-26\n\n### Added\n- prior release. (#1)\n\n[0.1.0]: https://example.test/releases/tag/v0.1.0\n' > CHANGELOG.md && \
    for c in added changed deprecated removed fixed security; do
      mkdir -p "changelog_unreleased/$c"
      touch "changelog_unreleased/$c/.gitkeep"
    done && \
    if [ -n "$cat" ] && [ -n "$num" ]; then
      printf '%s\n' "$body" > "changelog_unreleased/$cat/$num.md"
    fi && \
    git add -A && \
    git commit -q -m init ) >/dev/null 2>&1
}

# §65j-5 — TOML MISMATCH: python fixture with pyproject.toml [project] version 0.1.0,
# cutting 0.2.0 → preflight must refuse (non-zero) AND stderr names BOTH versions.
# Exercises detect_version's pure-awk _toml_version (no jq). Passes against current
# code (the awk parser already works; the preflight already refuses confident node
# mismatches and python flows through the same path).
s65j5_root=$(mktemp -d)
s65j5_dir="$s65j5_root/repo"
setup_release_smoke_toml "$s65j5_dir" "0.2.0-dev" "0.1.0" "added" "473" "- toml preflight. (#473)"
s65j5_rc=0
s65j5_err=""
if [ -x "$RELEASE_CONS" ]; then
  s65j5_err=$( cd "$s65j5_dir" && "$RELEASE_CONS" 0.2.0 --dry-run 2>&1 >/dev/null )
  s65j5_rc=$?
fi
s65j5_has_manifest=$(printf '%s' "$s65j5_err" | grep -c '0\.1\.0')
s65j5_has_release=$(printf '%s' "$s65j5_err" | grep -c '0\.2\.0')
if [ "$s65j5_rc" != "0" ] && [ "$s65j5_has_manifest" -ge 1 ] && [ "$s65j5_has_release" -ge 1 ]; then
  ok "65j-5: pyproject.toml manifest-match preflight refuses a confident mismatch (rc!=0) naming both manifest 0.1.0 + release 0.2.0, via pure-awk _toml_version (#469)"
else
  ng "65j-5: toml manifest-mismatch refusal failed (rc=$s65j5_rc err-has-manifest=$s65j5_has_manifest err-has-release=$s65j5_has_release) (#469)"
fi
rm -rf "$s65j5_root"

# §65j-6 — TOML MATCH: python fixture with pyproject.toml [project] version 0.2.0,
# cutting 0.2.0 → preflight passes, release reaches today's normal staged dry-run
# success. Confirms the awk _toml_version returns the version that satisfies the match.
s65j6_root=$(mktemp -d)
s65j6_dir="$s65j6_root/repo"
setup_release_smoke_toml "$s65j6_dir" "0.2.0-dev" "0.2.0" "added" "473" "- toml match. (#473)"
s65j6_rc=1
if [ -x "$RELEASE_CONS" ]; then
  ( cd "$s65j6_dir" && "$RELEASE_CONS" 0.2.0 --dry-run >/dev/null 2>&1 )
  s65j6_rc=$?
fi
s65j6_version=$(tr -d '[:space:]' < "$s65j6_dir/VERSION" 2>/dev/null)
s65j6_section=$(grep -c '^## \[0\.2\.0\]' "$s65j6_dir/CHANGELOG.md" 2>/dev/null | tr -d ' ')
if [ "$s65j6_rc" = "0" ] && [ "$s65j6_version" = "0.2.0" ] && [ "$s65j6_section" = "1" ]; then
  ok "65j-6: pyproject.toml manifest-match preflight passes a matching manifest; release reaches staged dry-run success (#469)"
else
  ng "65j-6: toml manifest-match pass-through failed (rc=$s65j6_rc version=$s65j6_version section=$s65j6_section) (#469)"
fi
rm -rf "$s65j6_root"

# §65j-3 — UNCERTAIN: no package.json (detect_stack → unknown) → preflight must
# gracefully skip and NOT block; run reaches today's happy-path success. This
# likely holds pre-Code (no preflight yet) — it is the falsifiable non-block
# guard that pins the uncertain arm so Phase C cannot make it blocking.
s65j3_root=$(mktemp -d)
s65j3_dir="$s65j3_root/repo"
setup_release_smoke "$s65j3_dir" "0.2.0-dev" "added" "469" "- uncertain. (#469)"
s65j3_rc=1
if [ -x "$RELEASE_CONS" ]; then
  ( cd "$s65j3_dir" && "$RELEASE_CONS" 0.2.0 --dry-run >/dev/null 2>&1 )
  s65j3_rc=$?
fi
s65j3_version=$(tr -d '[:space:]' < "$s65j3_dir/VERSION" 2>/dev/null)
if [ "$s65j3_rc" = "0" ] && [ "$s65j3_version" = "0.2.0" ]; then
  ok "65j-3: uncertain stack (no manifest) → preflight skips, non-blocking; run reaches happy-path success (#469)"
else
  ng "65j-3: uncertain-arm non-block guard failed (rc=$s65j3_rc version=$s65j3_version) (#469)"
fi
rm -rf "$s65j3_root"

# §65j-4 — never-writes grep-lock: the preflight READS the manifest, never writes
# it. Assert release_consolidate.sh contains no redirect-into or jq-write of a
# manifest file (package.json / Cargo.toml / pyproject.toml). Pre-Code this holds
# trivially (no preflight); it is the standing guard against a Phase-C regression
# that would mutate a manifest.
s65j4_writes=$(grep -nE '(>>?[[:space:]]*("?)(package\.json|Cargo\.toml|pyproject\.toml))|jq[^|]*>[[:space:]]*("?)(package\.json|Cargo\.toml|pyproject\.toml)' "$RELEASE_CONS" 2>/dev/null)
if [ -z "$s65j4_writes" ]; then
  ok "65j-4: release_consolidate.sh never writes package.json/Cargo.toml/pyproject.toml (preflight is read-only) (#469)"
else
  ng "65j-4: release_consolidate.sh writes a manifest — preflight must be read-only:$s65j4_writes (#469)"
fi

# ---------- 66. check-changelog.yml workflow (#133 / Directive #128) ----------
# §66 locks the per-PR fragment-gate workflow contract: file exists at the
# shell repo AND at canonical-source path AND they are byte-identical AND
# trigger semantics + label-bypass label install all wired correctly.

S66_SHELL_WF="$SHELL_ROOT/.github/workflows/check-changelog.yml"
S66_CANON_WF="$SHELL_ROOT/.claude/templates/target-substrate/workflows/check-changelog.yml"

# §66a — workflow file exists at both shell repo root AND canonical source.
if [ -f "$S66_SHELL_WF" ] && [ -f "$S66_CANON_WF" ]; then
  ok "66a: check-changelog.yml workflow exists at .github/ AND canonical-source path (#133)"
else
  ng "66a: check-changelog.yml workflow missing (shell=$([ -f "$S66_SHELL_WF" ] && echo yes || echo no) canon=$([ -f "$S66_CANON_WF" ] && echo yes || echo no)) (#133)"
fi

# §66b — byte-identical via diff exit-0; single-source-of-truth invariant.
if [ -f "$S66_SHELL_WF" ] && [ -f "$S66_CANON_WF" ] && diff -q "$S66_SHELL_WF" "$S66_CANON_WF" >/dev/null 2>&1; then
  ok "66b: check-changelog.yml shell-root and canonical-source are byte-identical (#133)"
else
  ng "66b: check-changelog.yml drift between shell-root and canonical-source (#133)"
fi

# §66c — trigger semantics: pull_request event with labeled + unlabeled types
# so the skip-changelog opt-out re-runs the check, and branches filter
# includes main + *-maintenance per SPEC §18.6.
s66c_ok=0
if [ -f "$S66_SHELL_WF" ]; then
  s66c_ok=1
  for required in 'pull_request' 'opened' 'synchronize' 'reopened' 'labeled' 'unlabeled' 'main' '*-maintenance' 'skip-changelog'; do
    if ! grep -qF "$required" "$S66_SHELL_WF"; then
      s66c_ok=0
      break
    fi
  done
fi
if [ "$s66c_ok" = 1 ]; then
  ok "66c: check-changelog.yml triggers cover pull_request opened/synchronize/reopened/labeled/unlabeled on main + *-maintenance + skip-changelog bypass (#133)"
else
  ng "66c: check-changelog.yml trigger semantics drift — missing one of {pull_request, opened, synchronize, reopened, labeled, unlabeled, main, *-maintenance, skip-changelog} (#133)"
fi

# §66f — workflow header documents the GitHub self-trigger policy.
# Discovered during #133 rollout; future contributors must not strip
# this comment. Locks the doc-as-code surface SPEC §18.6 references.
# Two independent greps because the policy phrase wraps across comment
# lines and `grep -E '\n'` is brittle.
if [ -f "$S66_SHELL_WF" ] && grep -q 'self-trigger on its own landing PR' "$S66_SHELL_WF" \
   && grep -q 'security policy excludes workflow files' "$S66_SHELL_WF"; then
  ok "66f: check-changelog.yml header documents GitHub workflow self-trigger policy (#135)"
else
  ng "66f: check-changelog.yml header missing self-trigger policy comment (#135)"
fi

# §66g — fragment-gate must FAIL on ANY malformed fragment, not pass on the
# first valid one (#303). The original validation step (SPEC §18.1) had an
# any-valid masking bug: it set `ok=1` on the first fragment that passed all
# three rules and then `exit 0`'d after the loop if `ok=1`, while a malformed
# sibling fragment merely `echo ::error` + `continue`d. Net: a PR carrying one
# good fragment and one broken one would pass the gate, defeating the contract.
# The fix replaces the any-valid `ok=1` flag with an all-valid `bad=1` failure
# accumulator (set inside the loop on any rule miss) plus a post-loop
# `[ "$bad" = 1 ]` → `exit 1`, and adds a leading "- " bullet check so the
# fragment is a real markdown list item. This is a STRUCTURAL grep against the
# workflow file — smoke cannot run a real Actions runner, and §66b already
# locks the shell + canonical copies byte-identical, so asserting on
# $S66_SHELL_WF alone suffices. Patterns are chosen RED-now / GREEN-after:
# the fix has not landed yet (Phase C), so §66g is expected to report `ng`.
s66g_ok=0
s66g_reasons=""
if [ -f "$S66_SHELL_WF" ]; then
  s66g_ok=1
  # (1) all-valid accumulator present: a `bad=1` failure flag set in the loop.
  if ! grep -qE 'bad=1' "$S66_SHELL_WF"; then
    s66g_ok=0
    s66g_reasons="$s66g_reasons missing-bad-accumulator;"
  fi
  # (2) post-loop fail gate keyed on the accumulator (exit 1 when bad=1),
  #     replacing the old `[ "$ok" = 1 ]` … exit 0 any-valid pass gate.
  if ! grep -qE '\[ "\$bad" = 1 \]' "$S66_SHELL_WF"; then
    s66g_ok=0
    s66g_reasons="$s66g_reasons missing-bad-fail-gate;"
  fi
  # (3) the any-valid masking token is GONE: no `ok=1` flag used as the sole
  #     pass gate (the literal old bug shape).
  if grep -qE 'ok=1' "$S66_SHELL_WF"; then
    s66g_ok=0
    s66g_reasons="$s66g_reasons any-valid-ok-flag-still-present;"
  fi
  # (4) leading "- " bullet validation: the gate must require each fragment
  #     to start with a markdown dash bullet.
  if ! grep -qE 'grep[^|]*"\^- "|grep[^|]*'\''\^- '\''' "$S66_SHELL_WF"; then
    s66g_ok=0
    s66g_reasons="$s66g_reasons missing-dash-bullet-check;"
  fi
fi
if [ "$s66g_ok" = 1 ]; then
  ok "66g: check-changelog.yml fragment-gate fails on ANY malformed fragment (all-valid bad=1 accumulator + post-loop exit, no any-valid ok=1 mask) and checks the leading \"- \" bullet (#303)"
else
  ng "66g: check-changelog.yml fragment-gate still has any-valid masking / missing dash-bullet check:$s66g_reasons (#303)"
fi

# §66h (#553 E4) — the fragment bullet and its `(#N)` ref must co-occur on ONE
# line. The old gate ran a `^- ` bullet grep and a `(#N)` ref grep that were
# line-INDEPENDENT, so a malformed multi-line fragment (a `- ` bullet on line 1,
# an orphan `(#N)` on line 2) satisfied both and passed. Functional check of the
# exact combined regex the fixed gate now uses (`^- .*(#<stem>)`).
s66h_tmp=$(mktemp)
printf -- '- a changelog bullet with no ref on this line\n(#5) orphan ref on its own line\n' > "$s66h_tmp"
if grep -qE '^- .*\(#5\)' "$s66h_tmp"; then
  ng "66h: multi-line fragment (bullet + ref split across lines) wrongly accepted by single-line grep (#553)"
else
  ok "66h: multi-line fragment (bullet/ref on different lines) rejected by combined bullet+ref grep (#553)"
fi
printf -- '- a proper single-line changelog bullet (#5)\n' > "$s66h_tmp"
if grep -qE '^- .*\(#5\)' "$s66h_tmp"; then
  ok "66h2: well-formed single-line fragment (bullet + ref together) still accepted (#553)"
else
  ng "66h2: well-formed single-line fragment wrongly rejected (#553)"
fi
rm -f "$s66h_tmp"

# §66i (#553 E3+E4) — structural lock on the two check-changelog fixes:
#  E3: `gh pr diff` transport status captured SEPARATELY (its own failure branch,
#      not a whole-pipeline `|| true` that conflates transport failure with
#      "no fragment"), so a diff/API error is a hard error, not a silent block.
#  E4: the per-fragment validation uses the single-line combined `^- .*(#<stem>)`
#      bullet+ref grep.
s66i_ok=1
s66i_reasons=""
grep -qF 'if ! diff_out=$(gh pr diff "$PR_NUM" --repo "$REPO" --patch); then' "$S66_SHELL_WF" \
  || { s66i_ok=0; s66i_reasons="$s66i_reasons missing-diff-transport-guard;"; }
grep -qF '^- .*\(#${stem}\)' "$S66_SHELL_WF" \
  || { s66i_ok=0; s66i_reasons="$s66i_reasons missing-single-line-bullet-ref-grep;"; }
if [ "$s66i_ok" = 1 ]; then
  ok "66i: check-changelog captures gh pr diff transport separately (E3) + validates bullet+ref on one line (E4) (#553)"
else
  ng "66i: check-changelog missing diff-transport guard / single-line bullet+ref grep:$s66i_reasons (#553)"
fi

# §66d — ensure_v3_labels.sh enumerates skip-changelog. The label is the
# documented opt-out per SPEC §18.6; its absence from the bootstrap label
# set would break the workflow's bypass path in adopting repos.
S66_LABELS="$SHELL_ROOT/scripts/ensure_v3_labels.sh"
if [ -f "$S66_LABELS" ] && grep -q 'skip-changelog' "$S66_LABELS"; then
  ok "66d: ensure_v3_labels.sh enumerates skip-changelog label (#133)"
else
  ng "66d: ensure_v3_labels.sh missing skip-changelog label entry (#133)"
fi

# §66e — workflow's bash logic uses bash + gh only (no third-party Actions
# beyond actions/checkout which Issue #133 Notes explicitly carves out as
# the canonical equivalent of git clone).
if [ -f "$S66_SHELL_WF" ]; then
  # Find uses: lines whose target is not under actions/ (the GitHub-shipped
  # namespace). Any hit is a third-party dependency.
  s66e_bad=$(grep -E '^\s*-?\s*uses:\s+' "$S66_SHELL_WF" 2>/dev/null | grep -vE 'uses:\s+actions/' || true)
  if [ -z "$s66e_bad" ]; then
    ok "66e: check-changelog.yml has no third-party GitHub Actions (actions/checkout carve-out only) (#133)"
  else
    ng "66e: check-changelog.yml references third-party Action(s): $s66e_bad (#133)"
  fi
else
  ng "66e: check-changelog.yml missing — cannot assert action provenance (#133)"
fi

# ---------- 67. task-vs-execution distinction enforced in both gates (#197) ----------
# SPEC §1.7 line 309: execution = parented under a Directive; task = standalone,
# not parented. Two enforcers must honor that distinction rather than leave the
# type label to agent discretion: activation-reviewer's parent-fit rulebook and
# /file-issue's label derivation. Greps anchor on stable tokens (label names near
# "parent fit", the derivation values), not full sentences — §63e/§63h idiom.
S67_AR="$SHELL_ROOT/.claude/agents/activation-reviewer.md"
S67_FI="$SHELL_ROOT/.claude/commands/file-issue.md"
S67_SPEC="$SHELL_ROOT/SPEC.md"

# §67a — activation-reviewer gates parent-fit by type label: task/bug skip it,
# only execution requires a parent, and the Parent-mismatch matrix is scoped to
# execution-labelled Issues.
if [ -f "$S67_AR" ] \
   && grep -qF 'Parent-fit is gated by the type label' "$S67_AR" \
   && grep -qF 'Only `execution` requires a parent.' "$S67_AR" \
   && grep -qF 'Parent-mismatch matrix (`execution`-labelled Issues only)' "$S67_AR"; then
  ok "67a: activation-reviewer gates parent-fit by type label; matrix scoped to execution (#197)"
else
  ng "67a: activation-reviewer parent-fit not gated by type label / matrix not execution-scoped (#197)"
fi

# §67f (#254, M2) — activation-reviewer handles the Initiative tier: type dispatch
# recognizes `initiative`, the Directive alignment branches on parent kind, and the
# Initiative rulebook documents contract-evaluability + extraction-faithfulness.
if [ -f "$S67_AR" ] \
   && grep -qF 'label present → Initiative rulebook' "$S67_AR" \
   && grep -qF '## Initiative rulebook' "$S67_AR" \
   && grep -qF 'Parent-kind alignment' "$S67_AR" \
   && grep -qF 'Contract-evaluability' "$S67_AR" \
   && grep -qF 'Extraction-faithfulness' "$S67_AR"; then
  ok "67f: activation-reviewer has Initiative dispatch + parent-kind alignment + contract/extraction checks (#254)"
else
  ng "67f: activation-reviewer missing Initiative-tier branching/checks (#254)"
fi

# §67b — the inverse smell: a Parent marker on a task/bug is a relabel-or-drop
# type smell, not a parent problem.
if [ -f "$S67_AR" ] \
   && grep -qF 'Relabel-or-drop smell' "$S67_AR" \
   && grep -qF 'relabel `execution` or drop the parent' "$S67_AR"; then
  ok "67b: activation-reviewer carries the relabel-or-drop smell for a Parent marker on task/bug (#197)"
else
  ng "67b: activation-reviewer missing the relabel-or-drop smell (#197)"
fi

# §67c — /file-issue derives the type label deterministically (parent->execution,
# standalone->task, --quick->bug) with no unresolved --label "..." placeholder.
if [ -f "$S67_FI" ] \
   && grep -qF 'Derive the type label deterministically' "$S67_FI" \
   && grep -qF -- '--label "<derived: bug|execution|task>"' "$S67_FI" \
   && ! grep -qF -- '--label "..."' "$S67_FI"; then
  ok "67c: /file-issue derives label deterministically; no --label \"...\" placeholder remains (#197)"
else
  ng "67c: /file-issue label not derived deterministically / placeholder still present (#197)"
fi

# §67d — /file-issue step 1.5 defaults to standalone in unattended mode rather
# than auto-parenting (the regression that mislabels a task as execution).
if [ -f "$S67_FI" ] && grep -qF 'do **NOT** auto-parent' "$S67_FI"; then
  ok "67d: /file-issue step 1.5 does not auto-parent in unattended mode (#197)"
else
  ng "67d: /file-issue step 1.5 missing the unattended no-auto-parent default (#197)"
fi

# §67e — SPEC §4.9.1 dispatch prose reconciled: parent-fit is gated by label.
if [ -f "$S67_SPEC" ] && grep -qF 'parent-fit is gated by label' "$S67_SPEC"; then
  ok "67e: SPEC §4.9.1 reconciles parent-fit as label-gated (#197)"
else
  ng "67e: SPEC §4.9.1 not reconciled for label-gated parent-fit (#197)"
fi

# ---------- 68. CLAUDE.md ceiling line reconciled with SPEC §5.7.1 (#201) ----------
# The Backbone "autonomy ceiling" sentence must state the ceiling is PR-ready
# BY DEFAULT (attended) AND that `unattended` deliberately extends it through the
# /ship merge-or-park terminal step — not an unqualified "stops at PR-ready" that
# the auto-mode classifier reads as a hard ceiling (the live denial #201 fixes).
# Doc-as-code lock: greps anchor on stable tokens (§63e/§67 idiom), and assert the
# old unqualified phrasing is gone so the line cannot silently re-drift.
S68_CLAUDE="$SHELL_ROOT/.claude/CLAUDE.md"
if [ -f "$S68_CLAUDE" ] \
   && grep -qF '**extends** the ceiling past PR-ready' "$S68_CLAUDE" \
   && grep -qF 'merge-or-park terminal step' "$S68_CLAUDE" \
   && grep -qF 'SPEC §5.7.1' "$S68_CLAUDE" \
   && ! grep -qF 'Default autonomy ceiling stops at PR-ready' "$S68_CLAUDE"; then
  ok "68: CLAUDE.md ceiling qualified — unattended extends past PR-ready, old phrasing gone (#201)"
else
  ng "68: CLAUDE.md ceiling not reconciled with SPEC §5.7.1 / unqualified phrasing remains (#201)"
fi

# ---------- 69. label-parent-consistency matcher (#199, enforces #197 advisory) ----------
# Runtime PreToolUse matcher: `gh issue edit <N> --add-label {execution|task|bug}`
# must be consistent with the Issue body's line-1 `Parent Directive: #N` marker.
# `execution` requires a marker; `task`/`bug` must NOT carry one. Behavioral
# (block/allow rc) asserts, not prose-presence — answering the #197 self-review
# gap (smoke §67 greps the instruction exists, not that it is obeyed). Reuses the
# §62 mock-gh shim pattern; the matcher resolves the body via
# `gh issue view <N> --json body -q .body` (issue_has_parent_marker, tri-state).
# NOTE (#199): renumbered §68→§69 on rebase after PR #202 landed its own §68
# (the ceiling test above) on main — the planned keep-both resolution.
S69_DIR=$(mktemp -d)
mkdir -p "$S69_DIR/bin" "$S69_DIR/target"
S69_TARGET=$(cd "$S69_DIR/target" && pwd -P)
(cd "$S69_TARGET" && git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
 git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
printf '%s\n' "$S69_TARGET" >> "$SMOKE_REG"

# Mock gh: issue 777 is parented (line-1 marker), 888 is standalone (no marker),
# 555 simulates gh failure (fail-open path). The matcher calls
# `gh issue view <N> --json body -q .body`; the mock emits the post-jq body raw.
cat > "$S69_DIR/bin/gh" <<'GHEOF'
#!/bin/sh
case "$*" in
  *"issue view 777"*) printf 'Parent Directive: #92\n\n## What\nparented execution work\n'; exit 0 ;;
  *"issue view 888"*) printf '## What\nstandalone task body, no marker\n'; exit 0 ;;
  *"issue view 555"*) exit 1 ;;   # gh down / no auth → predicate rc 2 → fail open
  # #276 A3 cross-repo: issue 444 differs by repo. In other/repo it is
  # marker-LESS (execution w/o marker → should block); in the current repo
  # it HAS a marker (execution w/ marker → would allow). Proves the matcher
  # resolves against the command's --repo target, not the cwd repo.
  *"issue view 444"*"--repo other/repo"*) printf '## What\nforeign marker-less body\n'; exit 0 ;;
  *"issue view 444"*) printf 'Parent Directive: #92\n\n## What\ncurrent-repo parented\n'; exit 0 ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$S69_DIR/bin/gh"

s69_edit_run() {
  # $1 = full command (may carry a SKIP_HOOKS env-prefix for the escape case).
  (
    cd "$S69_TARGET" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
      | PATH="$S69_DIR/bin:$PATH" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
  )
  return $?
}

# §69a: --add-label execution on a marker-less Issue (888) → BLOCKED (rc=2).
s69_edit_run "gh issue edit 888 --add-label execution"
case $? in
  2) ok "69a: --add-label execution on marker-less Issue → block (#199)" ;;
  *) ng "69a: expected rc=2 (block) for execution w/o marker, got rc=$? (#199)" ;;
esac

# §69b: --add-label execution on a parented Issue (777, has marker) → ALLOWED (rc=0).
s69_edit_run "gh issue edit 777 --add-label execution"
case $? in
  0) ok "69b: --add-label execution with marker present → allow (#199)" ;;
  *) ng "69b: expected rc=0 (allow) for execution w/ marker, got rc=$? (#199)" ;;
esac

# §69c: --add-label task on a parented Issue (777, has marker) → BLOCKED (rc=2).
s69_edit_run "gh issue edit 777 --add-label task"
case $? in
  2) ok "69c: --add-label task with marker present → block (type smell) (#199)" ;;
  *) ng "69c: expected rc=2 (block) for task w/ marker, got rc=$? (#199)" ;;
esac

# §69d: fail-open — gh unresolvable (555) → ALLOWED (rc=0) even for the would-block
# execution-no-marker shape. Parity with proposed-protect / trusted-filer-mutate.
s69_edit_run "gh issue edit 555 --add-label execution"
case $? in
  0) ok "69d: fail-open when Issue body unresolvable → allow (#199)" ;;
  *) ng "69d: expected rc=0 (fail-open) for unresolvable body, got rc=$? (#199)" ;;
esac

# §69e: escape hatch — SKIP_HOOKS=label-parent-consistency bypasses the §69a block
# (rc=0) AND emits an escape audit record (category label-parent-consistency).
s69_before=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$s69_before" ] && s69_before=0
s69_edit_run "SKIP_HOOKS=label-parent-consistency SKIP_REASON=legit-two-step gh issue edit 888 --add-label execution"
s69_rc=$?
s69_after=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$s69_after" ] && s69_after=0
s69_delta=$((s69_after - s69_before))
if [ "$s69_rc" = 0 ] && [ "$s69_delta" -ge 1 ] \
   && tail -n "$s69_delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"category":"label-parent-consistency"' \
   && tail -n "$s69_delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"event":"escape"'; then
  ok "69e: SKIP_HOOKS=label-parent-consistency bypasses + audit-logs escape (#199)"
else
  ng "69e: escape not honored / not audited (rc=$s69_rc, delta=$s69_delta) (#199)"
fi

# §69f (#212): the gated label as a NON-FIRST element of a comma-joined
# --add-label value must still be caught. 888 is marker-less, so execution
# anywhere in the list → block. Pre-#212 the regex anchored the label at the
# head of the value and missed this (fail-open allow).
s69_edit_run "gh issue edit 888 --add-label other,execution"
case $? in
  2) ok "69f: --add-label other,execution (comma list) on marker-less Issue → block (#212)" ;;
  *) ng "69f: comma-list execution not caught, got rc=$? (#212)" ;;
esac

# §69g (#276 A1): URL-form issue selector must not bypass. 888 is marker-less,
# so a URL targeting it + --add-label execution → block. Pre-#276 the entry
# pre-filter matched a bare number only, so the URL silently fell through (allow).
s69_edit_run "gh issue edit https://github.com/o/r/issues/888 --add-label execution"
case $? in
  2) ok "69g: URL-form selector (#276 A1) on marker-less Issue → block (#276)" ;;
  *) ng "69g: URL-form selector bypassed the matcher, got rc=$? (#276 A1)" ;;
esac

# §69h (#276 A2): a flag placed BEFORE the positional issue arg must not bypass.
# gh accepts `gh issue edit --add-label execution 888`; pre-#276 the extraction
# required the number immediately after `edit`, so this fell through (allow).
s69_edit_run "gh issue edit --add-label execution 888"
case $? in
  2) ok "69h: flag-before-positional selector (#276 A2) → block (#276)" ;;
  *) ng "69h: flag-before-positional bypassed the matcher, got rc=$? (#276 A2)" ;;
esac

# §69i (#276 A3): cross-repo resolution. `--repo other/repo` targets issue 444 in
# the FOREIGN repo (marker-less → execution w/o marker → block). The current repo's
# 444 HAS a marker (would allow). Pre-#276 the predicate resolved against the cwd
# repo, wrongly allowing (rc=0). The fix threads the --repo target into the
# predicate (and its cache key), so it resolves the foreign marker-less body → block.
s69_edit_run "gh issue edit 444 --repo other/repo --add-label execution"
case $? in
  2) ok "69i: cross-repo --repo target resolved (#276 A3) → block (#276)" ;;
  *) ng "69i: cross-repo target resolved against wrong repo, got rc=$? (#276 A3)" ;;
esac

# §69j (#276): a non-resolvable / garbage selector must reach a DECIDED state
# (mark_allow → rc=0), never silent fall-through (the §6.1 pass-through invariant).
s69_edit_run "gh issue edit --add-label execution"
case $? in
  0) ok "69j: garbage selector (no issue#) → mark_allow, decided (#276)" ;;
  *) ng "69j: garbage selector did not fail-open cleanly, got rc=$? (#276)" ;;
esac

# §69g (#212): correctness of the BASH_REMATCH renumber — the captured label
# must be the gated token after the comma, not the prefix. 777 HAS a marker, so
# `task` (standalone) contradicts it → block. If the prefix `bar` were captured
# instead of `task`, it would be non-gated and fail-open allow.
s69_edit_run "gh issue edit 777 --add-label bar,task"
case $? in
  2) ok "69k: comma-list label correctly captured (bar,task → task contradiction blocks) (#212)" ;;
  *) ng "69k: comma-list label mis-captured (renumber regression?), got rc=$? (#212)" ;;
esac

# §69h (#212): no over-match — a longer label like `executionish` is not the
# gated `execution` token and must allow (777 has marker, but executionish is
# ungated so the arm fails open regardless).
s69_edit_run "gh issue edit 777 --add-label executionish"
case $? in
  0) ok "69l: --add-label executionish does not over-match the gated token → allow (#212)" ;;
  *) ng "69l: executionish over-matched the gated label, got rc=$? (#212)" ;;
esac

# §69m (#278 Theme C): a HYPHEN-suffixed label (`directive-foo`) must NOT
# over-match the `directive` token. Pre-#278 the `([^a-z]|$)` terminator
# treated `-` as a boundary, so `directive-foo` matched the directive arm and
# (on marker-less 888 → neither parent kind) wrongly BLOCKED. The fix tightens
# the terminator to a true label boundary (comma / whitespace / quote / end).
s69_edit_run "gh issue edit 888 --add-label directive-foo"
case $? in
  0) ok "69m: --add-label directive-foo (hyphen suffix) does not over-match → allow (#278)" ;;
  *) ng "69m: directive-foo over-matched the directive token, got rc=$? (#278 C)" ;;
esac

# §69n (#278): an UNDERSCORE-suffixed label (`task_old`) likewise must not
# over-match the `task` token (777 has a marker; pre-fix task+marker → block).
s69_edit_run "gh issue edit 777 --add-label task_old"
case $? in
  0) ok "69n: --add-label task_old (underscore suffix) does not over-match → allow (#278)" ;;
  *) ng "69n: task_old over-matched the task token, got rc=$? (#278 C)" ;;
esac

# §69o (#278 regression): the bare gated token and comma-joined lists must STILL
# match. `directive` on 888 (no parent kind) → parent-XOR neither → block (the
# fix must not loosen the real gate).
s69_edit_run "gh issue edit 888 --add-label directive"
case $? in
  2) ok "69o: bare --add-label directive still gated (parent-XOR) → block (#278 regression)" ;;
  *) ng "69o: bare directive token no longer gated, got rc=$? (#278 regression)" ;;
esac

# Cleanup §69.
s69_tmp_reg=$(mktemp); grep -vxF "$S69_TARGET" "$SMOKE_REG" > "$s69_tmp_reg" 2>/dev/null || true
mv "$s69_tmp_reg" "$SMOKE_REG"
rm -rf "$S69_DIR"

# ---------- 70. force-push scoping: explicit non-protected target only (#204) ----------
# Allow force-push to an explicitly-named non-protected branch (the rebase-pull
# tail, SPEC §13); block a protected target, and block a bare/remote-only
# force-push (no target named) with guidance to name it. The matcher decides
# from the COMMAND (protected token + explicit-refspec presence), never from the
# current branch — a bare push's true destination is config-dependent, so HEAD
# is not a safe proxy (a feature branch tracking origin/main would clobber main).
# NOTE (#204): §69 (label-parent-consistency, #203) is the section immediately
# above; §70 follows it — the planned keep-both resolution at this anchor.

# §70a: explicit non-protected refspec → ALLOW.
if [ "$(hook_run 'git push --force-with-lease origin my-feature')" = "0" ]; then
  ok "70a: force-push to explicit non-protected branch allowed (#204)"
else
  ng "70a: force-push to explicit feature branch should be allowed (#204)"
fi

# §70b: explicit protected refspec → BLOCK, message names "protected".
s70b=$(cd "$TMP/fake" && fake_input "Bash" "{\"command\":\"git push --force origin main\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
s70b_rc=$?
if [ "$s70b_rc" = 2 ] && printf '%s' "$s70b" | grep -qi protected; then
  ok "70b: force-push to protected branch blocked; message names protected (#204)"
else
  ng "70b: protected force-push should block with 'protected' msg (rc=$s70b_rc) (#204)"
fi

# §70c: bare force-push (no target) → BLOCK, message guides to name the target.
s70c=$(cd "$TMP/fake" && fake_input "Bash" "{\"command\":\"git push --force\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
s70c_rc=$?
if [ "$s70c_rc" = 2 ] && printf '%s' "$s70c" | grep -qi 'explicit target branch'; then
  ok "70c: bare force-push blocked; message tells user to name the target (#204)"
else
  ng "70c: bare force-push should block with name-the-target guidance (rc=$s70c_rc) (#204)"
fi

# §70d: remote-only force-push (no branch named) → BLOCK (target still implicit).
if [ "$(hook_run 'git push --force origin')" = "2" ]; then
  ok "70d: remote-only force-push (no branch) blocked (#204)"
else
  ng "70d: remote-only force-push should block (no explicit target) (#204)"
fi

# §70e: --mirror force-push → BLOCK even with a trailing positional. --mirror
# pushes/deletes EVERY ref (incl. protected); the trailing token must not flip
# the positional count to allow. (Security: closes the ref-set-flag bypass.)
if [ "$(hook_run 'git push --force --mirror origin extra')" = "2" ]; then
  ok "70e: --mirror force-push blocked despite trailing positional (#204)"
else
  ng "70e: --mirror force-push must block (targets all refs) (#204)"
fi

# §70f: --all force-push → BLOCK even with a trailing positional.
if [ "$(hook_run 'git push --all --force origin extra')" = "2" ]; then
  ok "70f: --all force-push blocked despite trailing positional (#204)"
else
  ng "70f: --all force-push must block (targets all branches) (#204)"
fi

# §70g: protected-token match is case-insensitive — `MAIN` collides with `main`
# on case-insensitive filesystems (macOS/Windows), so it must block too.
if [ "$(hook_run 'git push --force origin MAIN')" = "2" ]; then
  ok "70g: case-folded protected target (MAIN) blocked (#204)"
else
  ng "70g: case-folded protected target should block (#204)"
fi

# §70h: --mirror force-push with NO positional still blocks (the ref-set guard
# fires regardless of token count — not dependent on the positional heuristic).
if [ "$(hook_run 'git push --force --mirror')" = "2" ]; then
  ok "70h: --mirror force-push (no positional) blocked (#204)"
else
  ng "70h: --mirror force-push must block regardless of positional count (#204)"
fi

# §70i: over-block guard — a branch literally named `all` (no `--` prefix) is a
# normal explicit non-protected target and must be ALLOWED; the ref-set regex
# requires the `--` flag form, so a positional `all` does not trip it.
if [ "$(hook_run 'git push --force-with-lease origin all')" = "0" ]; then
  ok "70i: explicit non-protected branch named 'all' allowed (no refset over-block) (#204)"
else
  ng "70i: branch named 'all' should be allowed (refset regex needs -- prefix) (#204)"
fi

# §70j–§70o: composite-command segment isolation (#437). The force-push arm now
# isolates the actual git-push segment(s) via push_segments (mirroring the #366
# branch arm), so a force flag / protected token / target in a SIBLING non-push
# segment no longer false-trips — while every genuine-block path is preserved
# (the falsifiability arm).

# §70j: the motivating false-positive — a non-protected force-push composed with
# a PR-create that names the default branch in a SIBLING segment → ALLOW.
if [ "$(hook_run 'git push --force-with-lease origin my-feature && gh pr create --base main')" = "0" ]; then
  ok "70j: non-protected force-push + sibling 'gh pr create --base main' allowed (#437)"
else
  ng "70j: composite force-push with a sibling protected token should NOT block (#437)"
fi

# §70k: genuine protected force-push in a composite STILL blocks (falsifiability).
s70k=$(cd "$TMP/fake" && fake_input "Bash" "{\"command\":\"git push --force origin main && gh pr create --base main\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
s70k_rc=$?
if [ "$s70k_rc" = 2 ] && printf '%s' "$s70k" | grep -qi protected; then
  ok "70k: protected force-push still blocks in a composite; names protected (#437)"
else
  ng "70k: protected force-push in a composite must still block (rc=$s70k_rc) (#437)"
fi

# §70l: bare force-push composed with a sibling STILL blocks (target unverifiable).
if [ "$(hook_run 'git push --force && gh pr create --base feature')" = "2" ]; then
  ok "70l: bare force-push in a composite still blocks (#437)"
else
  ng "70l: bare force-push in a composite must still block (#437)"
fi

# §70m: --mirror force-push composed with a sibling STILL blocks (targets all refs).
if [ "$(hook_run 'git push --force --mirror origin x && gh pr create --base feature')" = "2" ]; then
  ok "70m: --mirror force-push in a composite still blocks (#437)"
else
  ng "70m: --mirror force-push in a composite must still block (#437)"
fi

# §70n: multi-push-segment — block if ANY force-bearing push segment is protected,
# even when an earlier segment is a legitimate non-protected force-push.
if [ "$(hook_run 'git push --force-with-lease origin feat && git push --force origin main')" = "2" ]; then
  ok "70n: multi-push-segment blocks when a later segment force-pushes protected (#437)"
else
  ng "70n: any protected force-push segment must block (#437)"
fi

# §70o: a force flag living ONLY in a non-push sibling (not in the git-push
# segment) → the push itself is non-force/non-protected → ALLOW (entry .*-span fix).
if [ "$(hook_run 'git push origin my-feature && echo --force-with-lease')" = "0" ]; then
  ok "70o: force flag in a sibling non-push segment does not make it a force-push (#437)"
else
  ng "70o: sibling-only force flag should not trigger the force-push gate (#437)"
fi

# §70p–§70s: message-value strip (#440). A force/protected literal documented
# inside a commit MESSAGE body (-m/--message/-F value) is data, not a command,
# so it must not false-trip the force-push/protected arms — while a REAL push in
# a sibling segment still blocks (the elision is anchored to the message flag).

# §70p: a force-push literal inside an -m message body → ALLOW (not a command).
if [ "$(hook_run 'git commit -m "feat(#5): real subject" -m "example: git push --force-with-lease origin main"')" = "0" ]; then
  ok "70p: force-push literal in a commit message body not blocked (#440)"
else
  ng "70p: a force-push literal in -m message data should not trip the gate (#440)"
fi

# §70q: a protected-push literal inside an -m message body → ALLOW (branch arm).
if [ "$(hook_run 'git commit -m "feat(#5): real subject" -m "see git push origin main for the tail"')" = "0" ]; then
  ok "70q: protected-push literal in a commit message body not blocked (#440)"
else
  ng "70q: a protected-push literal in -m message data should not trip the branch arm (#440)"
fi

# §70r: --message=-glued force/protected literal → ALLOW (the = form is elided
# too). The subject itself is a VALID conventional commit (so commit-format does
# not block on the subject); the force/protected literal lives in the value.
if [ "$(hook_run 'git commit --message="feat(#5): note re git push --force origin main"')" = "0" ]; then
  ok "70r: --message=-glued force/protected literal not blocked (#440)"
else
  ng "70r: a force/protected literal in a --message= value should not trip the gate (#440)"
fi

# §70s: falsifiability — a REAL force-push to protected in a SIBLING of a commit
# still BLOCKS (the -m is elided, but the genuine push segment is not).
if [ "$(hook_run 'git commit -m "feat(#5): real subject" && git push --force origin main')" = "2" ]; then
  ok "70s: real force-push to protected in a commit sibling still blocks (#440)"
else
  ng "70s: a genuine sibling force-push to protected must still block (#440)"
fi

# §70t–§70v: glued-separator folds the force-push verb (#446). When a shell
# operator (&&, ;, |) is GLUED to the prior token with no surrounding space
# (e.g. `git commit -m "x"&&git push…`), parse_env_prefix's shlex round-trip
# folds the operator into one token, destroying the `git push` verb the push
# arms' entry-grep keys on → the protected force-push slips through ALLOWED.
# The spaced sibling form is correctly BLOCKED today. The Code phase adds a
# normalization that re-separates the glued operator, flipping the glued forms
# to BLOCKED while leaving every legit allow-case untouched.
#
# RED-PENDING-CODE (currently ALLOWED, must flip to BLOCKED):
#   §70t glued &&, and §70u glued &&, ;, | protected force-push vectors.
# GREEN now AND after: every spaced control, the newline-glued case (the \n is
#   collapsed to a space before parse_env_prefix), all §70v allow-cases.

# NOTE on the prior segment's subject: every glued command pairs the protected
# force-push onto a VALID conventional-commit subject (`feat(#5): real subject`),
# exactly as §70p–§70s do. A throwaway subject like `-m "x"` would be blocked by
# the independent commit-format arm, confounding the force-push decision under
# test; a valid subject isolates the force-push/protected arm as the sole gate.

# §70t (AC1): a glued-&& force-push to a protected branch must BLOCK. The
# `subject"&&` fold currently swallows the `git push` verb → ALLOWED → RED until
# the Code fix.
if [ "$(hook_run 'git commit -m "feat(#5): real subject"&&git push --force origin main')" = "2" ]; then
  ok "70t: glued-&& force-push to protected branch blocked (#446)"
else
  ng "70t: glued-&& force-push to protected branch must block (#446)"
fi
# §70t control: the spaced sibling is BLOCKED today AND after the fix — proves
# the assertion harness itself catches the protected force-push when not folded.
if [ "$(hook_run 'git commit -m "feat(#5): real subject" && git push --force origin main')" = "2" ]; then
  ok "70t: spaced-&& control force-push to protected branch blocked (#446)"
else
  ng "70t: spaced-&& control must block (harness sanity) (#446)"
fi

# §70u (AC2): glued ≡ spaced equivalence across three separators, each gluing a
# protected force-push onto a prior valid `git commit`. Each glued form must
# BLOCK identically to its spaced sibling.
# §70u-and glued && — RED until the Code fix.
if [ "$(hook_run 'git commit -m "feat(#5): real subject"&&git push --force origin main')" = "2" ]; then
  ok "70u: glued-&& protected force-push blocked (#446)"
else
  ng "70u: glued-&& protected force-push must block (#446)"
fi
# §70u-and spaced && control — BLOCKED now and after.
if [ "$(hook_run 'git commit -m "feat(#5): real subject" && git push --force origin main')" = "2" ]; then
  ok "70u: spaced-&& protected force-push control blocked (#446)"
else
  ng "70u: spaced-&& protected force-push control must block (#446)"
fi
# §70u-semi glued ; — RED until the Code fix.
if [ "$(hook_run 'git commit -m "feat(#5): real subject";git push --force origin main')" = "2" ]; then
  ok "70u: glued-; protected force-push blocked (#446)"
else
  ng "70u: glued-; protected force-push must block (#446)"
fi
# §70u-semi spaced ; control — BLOCKED now and after.
if [ "$(hook_run 'git commit -m "feat(#5): real subject" ; git push --force origin main')" = "2" ]; then
  ok "70u: spaced-; protected force-push control blocked (#446)"
else
  ng "70u: spaced-; protected force-push control must block (#446)"
fi
# §70u-pipe glued | — RED until the Code fix. (Confirmed a genuine vector: folds
# the operator into the prior token, destroying the push verb — plan-review OK.)
if [ "$(hook_run 'git commit -m "feat(#5): real subject"|git push --force origin main')" = "2" ]; then
  ok "70u: glued-| protected force-push blocked (#446)"
else
  ng "70u: glued-| protected force-push must block (#446)"
fi
# §70u-pipe spaced | control — BLOCKED now and after.
if [ "$(hook_run 'git commit -m "feat(#5): real subject" | git push --force origin main')" = "2" ]; then
  ok "70u: spaced-| protected force-push control blocked (#446)"
else
  ng "70u: spaced-| protected force-push control must block (#446)"
fi
# §70u-newline exploratory: a newline separator. pre_tool_use.sh:125 collapses
# \n→space BEFORE parse_env_prefix, so the newline normalizes to a spaced
# boundary and is expected ALREADY BLOCKED (now AND after). If this comes up RED
# the \n-collapse assumption is wrong — flag it.
nl_glued_cmd=$(printf 'git commit -m "feat(#5): real subject"\ngit push --force origin main')
if [ "$(hook_run "$nl_glued_cmd")" = "2" ]; then
  ok "70u: newline-glued protected force-push blocked (\\n collapses to space) (#446)"
else
  ng "70u: newline-glued protected force-push must block (\\n-collapse vector) (#446)"
fi

# §70v (AC3): no over-block — every allow-case must stay ALLOWED now AND after
# the normalization. These guard that re-separating the glued operator does not
# leak into legitimate compounds or commit-message data.
# §70v-i: glued legit force-push to a NON-protected branch → ALLOWED.
if [ "$(hook_run 'git commit -m "feat(#5): real subject"&&git push --force origin feature-branch')" = "0" ]; then
  ok "70v: glued-&& force-push to NON-protected branch allowed (#446)"
else
  ng "70v: legit glued force-push to a non-protected branch must not block (#446)"
fi
# §70v-ii: ordinary glued non-push compound → ALLOWED.
if [ "$(hook_run 'git status&&echo done')" = "0" ]; then
  ok "70v: ordinary glued non-push compound allowed (#446)"
else
  ng "70v: a glued non-push compound must not block (#446)"
fi
# §70v-iii: a --force/main literal INSIDE a quoted -m value → ALLOWED (message
# data, composes with the #440 elision; the over-block guard the fix must keep).
if [ "$(hook_run 'git commit -m "feat(#5): note re git push --force origin main here"')" = "0" ]; then
  ok "70v: force/protected literal inside an -m message value allowed (#446)"
else
  ng "70v: a force/protected literal in -m message data must not trip the gate (#446)"
fi

# §70w: single-& (bash background operator) glued-separator fold (#476) — the
# sibling of #446. A lone unquoted `&` glued to the prior token (no surrounding
# space, e.g. `git status&git push…`) folds into one token under the shlex
# round-trip the same way &&/;/| do, destroying the `git push` verb the push
# arms key on → the protected force-push slips through ALLOWED. The Code phase
# (1) pads a lone unquoted `&` to ` & ` in space_glued_separators UNLESS it is
# part of a redirect (immediately adjacent to `>`/`<`: `>&`, `&>`, `N>&M`, `<&`,
# `&>>`), and (2) adds `&` to push_segments' awk split set so a glued `&`
# isolates sibling clauses. `&&` is matched first, so the lone-`&` arm must not
# mis-split it into `& &`.
#
# Every glued command pairs onto a VALID conventional-commit subject
# (`feat(#5): real subject`) per §70p–§70v, so the commit-format matcher does
# not confound the force-push decision under test.
#
# RED-PENDING-CODE (must flip with the Code fix):
#   §70w-block          ALLOWED→BLOCKED (the `&` fold destroys the push verb).
#   §70w-overblock-guard BLOCKED→ALLOWED (the sibling `echo main`'s `main`
#                        currently false-trips the protected grep; the `&` split
#                        must isolate the push segment).
# GREEN now AND after: the spaced control, every redirect-allow arm, the
#   redirect-protected arm, the in-message arm, and the &&-first regression arm.

# §70w-block (AC1): a glued-& force-push to a protected branch must BLOCK. The
# `status&git` fold currently swallows the `git push` verb → ALLOWED → RED.
if [ "$(hook_run 'git status&git push --force origin main')" = "2" ]; then
  ok "70w: glued-& force-push to protected branch blocked (#476)"
else
  ng "70w: glued-& force-push to protected branch must block (#476)"
fi

# §70w-overblock-guard (plan-review #1): a legit force-push to a NON-protected
# branch backgrounded with `&`, followed by `echo main`. The `&` must isolate
# the push segment so the sibling's `main` token does not trip the protected
# grep → ALLOWED. Pre-Code push_segments has no `&` split, so the whole line is
# one segment and `main` false-BLOCKs → RED.
if [ "$(hook_run 'git push --force origin feature & echo main')" = "0" ]; then
  ok "70w: backgrounded non-protected force-push + sibling 'main' allowed (#476)"
else
  ng "70w: a sibling 'echo main' after a backgrounded non-protected push must not block (#476)"
fi

# §70w-control: the spaced sibling is BLOCKED today AND after — glued≡spaced
# equivalence, and proves the harness catches the protected force-push unfolded.
if [ "$(hook_run 'git status & git push --force origin main')" = "2" ]; then
  ok "70w: spaced-& control force-push to protected branch blocked (#476)"
else
  ng "70w: spaced-& control must block (harness sanity) (#476)"
fi

# §70w-redirect-allow: a force-push to a NON-protected branch carrying a
# `&`-redirect must stay ALLOWED — the redirect carve-out must not pad `2>&1`
# etc. into a clause boundary nor over-block. One assertion per redirect form.
if [ "$(hook_run 'git push --force origin feature 2>&1')" = "0" ]; then
  ok "70w-redirect-allow: 2>&1 stderr-to-stdout dup allowed (#476)"
else
  ng "70w-redirect-allow: a 2>&1 redirect on a non-protected force-push must not block (#476)"
fi
if [ "$(hook_run 'git push --force origin feature >&2')" = "0" ]; then
  ok "70w-redirect-allow: >&2 stdout-to-stderr dup allowed (#476)"
else
  ng "70w-redirect-allow: a >&2 redirect on a non-protected force-push must not block (#476)"
fi
if [ "$(hook_run 'git push --force origin feature &>log')" = "0" ]; then
  ok "70w-redirect-allow: &>log all-to-file redirect allowed (#476)"
else
  ng "70w-redirect-allow: a &>log redirect on a non-protected force-push must not block (#476)"
fi
if [ "$(hook_run 'git push --force origin feature 1>&2')" = "0" ]; then
  ok "70w-redirect-allow: 1>&2 fd-numbered dup allowed (#476)"
else
  ng "70w-redirect-allow: a 1>&2 redirect on a non-protected force-push must not block (#476)"
fi
if [ "$(hook_run 'git push --force origin feature &>>log')" = "0" ]; then
  ok "70w-redirect-allow: &>>log all-append redirect allowed (#476)"
else
  ng "70w-redirect-allow: a &>>log redirect on a non-protected force-push must not block (#476)"
fi
if [ "$(hook_run 'git push --force origin feature 0<&3')" = "0" ]; then
  ok "70w-redirect-allow: 0<&3 input fd-dup (<&) allowed (#476)"
else
  ng "70w-redirect-allow: a 0<&3 input fd-dup on a non-protected force-push must not block (#476)"
fi

# §70w-redirect-protected: the redirect carve-out must NOT blind the gate to a
# redirect-bearing protected force-push → BLOCKED (now AND after).
if [ "$(hook_run 'git push --force origin main 2>&1')" = "2" ]; then
  ok "70w-redirect-protected: redirect-bearing protected force-push blocked (#476)"
else
  ng "70w-redirect-protected: a 2>&1 redirect must not blind the gate to a protected force-push (#476)"
fi

# §70w-in-message: the `&` and the push text live inside a quoted -m value =
# data, not a boundary → ALLOWED (now AND after; composes with the #440 elision).
if [ "$(hook_run 'git commit -m "feat(#5): mention & and git push --force origin main here"')" = "0" ]; then
  ok "70w-in-message: a lone & + push literal inside an -m value allowed (#476)"
else
  ng "70w-in-message: a & and push literal in -m message data must not trip the gate (#476)"
fi

# §70w-amp-amp-first: regression guard — the new lone-& arm must match two-char
# `&&` FIRST and not mis-split it into `& &`. A glued-&& protected force-push
# must still BLOCK (now AND after).
if [ "$(hook_run 'git commit -m "feat(#5): real subject"&&git push --force origin main')" = "2" ]; then
  ok "70w-amp-amp-first: glued-&& protected force-push still blocked (no & & mis-split) (#476)"
else
  ng "70w-amp-amp-first: && must match before lone-& (no & & mis-split) (#476)"
fi

# ---------- 71. escape-hatch reference docs route in-harness blocks correctly (#217) ----------
# SPEC §7 has TWO escape forms; the leading env-prefix is non-functional in the
# live Claude Code Bash tool (consumed as subprocess env, #206), so the canonical
# in-harness form is the trailing sentinel. These doc-checks assert the reference
# docs present the trailing sentinel + carry the label-parent-consistency category
# + cite the actual .shellsecretignore globs. Fail pre-#217.
EH="$SHELL_ROOT/docs/ESCAPE_HATCH.md"
TS="$SHELL_ROOT/docs/TROUBLESHOOTING.md"
# 71a: ESCAPE_HATCH.md presents the trailing-sentinel in-harness form.
grep -qF 'ghjig:skip=' "$EH" 2>/dev/null \
  && ok "71a: ESCAPE_HATCH.md documents the trailing-sentinel in-harness escape (#217)" \
  || ng "71a: ESCAPE_HATCH.md missing the trailing-sentinel form (#217)"
# 71b: ESCAPE_HATCH.md ## Categories includes label-parent-consistency.
grep -qF 'label-parent-consistency' "$EH" 2>/dev/null \
  && ok "71b: ESCAPE_HATCH.md categories include label-parent-consistency (#217)" \
  || ng "71b: ESCAPE_HATCH.md missing the label-parent-consistency category (#217)"
# 71c: TROUBLESHOOTING.md names the trailing-sentinel in-harness form.
grep -qF 'ghjig:skip=' "$TS" 2>/dev/null \
  && ok "71c: TROUBLESHOOTING.md names the trailing-sentinel in-harness escape (#217)" \
  || ng "71c: TROUBLESHOOTING.md missing the trailing-sentinel form (#217)"
# 71d: TROUBLESHOOTING.md carries a label-parent-consistency row.
grep -qF 'label-parent-consistency' "$TS" 2>/dev/null \
  && ok "71d: TROUBLESHOOTING.md has a label-parent-consistency row (#217)" \
  || ng "71d: TROUBLESHOOTING.md missing the label-parent-consistency row (#217)"
# 71e: README.md (+ .ko) present the trailing-sentinel as the in-harness escape.
grep -qF 'ghjig:skip=' "$SHELL_ROOT/README.md" 2>/dev/null \
  && grep -qF 'ghjig:skip=' "$SHELL_ROOT/README.ko.md" 2>/dev/null \
  && ok "71e: README.md + README.ko.md present the trailing-sentinel escape (#217)" \
  || ng "71e: README escape line missing the trailing-sentinel form (#217)"
# 71f: CLAUDE.md no longer cites the stale *test*/*example* glob defaults (it now
# names the actual component-aware globs or references the file as SSOT).
if grep -qF '*test*' "$SHELL_ROOT/.claude/CLAUDE.md" 2>/dev/null; then
  ng "71f: CLAUDE.md still cites the stale *test* .shellsecretignore default (#217)"
else
  ok "71f: CLAUDE.md no longer cites the stale *test*/*example* globs (#217)"
fi
# 71g (#513 / Directive #498 residual): CLAUDE.md's SessionStart-banner line must
# name BOTH detectable silent-no-op states — `hookrt.sh` missing AND the
# registry-zeroed disarm (#502, SPEC §6.5(c)) — and must NOT assert "the one"
# (a count claim the SSOT contradicts since #502 added the second detector).
s71g_md="$SHELL_ROOT/.claude/CLAUDE.md"
s71g_line=$(grep -iE 'SessionStart banner' "$s71g_md" 2>/dev/null)
if printf '%s' "$s71g_line" | grep -qiE 'hookrt' \
   && printf '%s' "$s71g_line" | grep -qiE 'registr' \
   && ! printf '%s' "$s71g_line" | grep -qiE 'the one detectable silent-no-op'; then
  ok "71g: CLAUDE.md SessionStart line names both silent-no-op detectors (hookrt + registry), no stale 'the one' count (#513)"
else
  ng "71g: CLAUDE.md SessionStart line stale — must name both hookrt + registry-zeroed detectors, drop 'the one' (#513)"
fi

# ---------- 72. robustness cluster: release_consolidate + ac_closeout symmetry (#218) ----------
# Script-content assertions (the affected scripts talk to git/gh and aren't
# cheaply unit-testable in isolation); they verify the fix is present.
# 72a (SITE 1): release_consolidate.sh's fragment-consume `git rm` is guarded so
# a failure exits non-zero (was swallowed under set -uo pipefail).
RC_SH="$SHELL_ROOT/scripts/release_consolidate.sh"
if grep -qF 'git rm -q "$f" ||' "$RC_SH" 2>/dev/null \
   && grep -qF 'git add VERSION CHANGELOG.md ||' "$RC_SH" 2>/dev/null; then
  ok "72a: release_consolidate.sh git rm + git add guarded (non-zero exit on failure) (#218)"
else
  ng "72a: release_consolidate.sh git rm/git add failure is unguarded — swallowed under set -uo pipefail (#218)"
fi
# 72b (SITE 2): ac_closeout.sh's detect + convert no longer require a trailing
# space, so they cover the same degenerate `- [ ]` lines the gate blocks on.
# grep -F (fixed string) for the OLD trailing-space signatures — absent = fixed.
AC_SH="$SHELL_ROOT/scripts/ac_closeout.sh"
if ! grep -F '[ x~]\] ' "$AC_SH" >/dev/null 2>&1 \
   && ! grep -F '\[ \] /' "$AC_SH" >/dev/null 2>&1; then
  ok "72b: ac_closeout.sh detect+convert dropped the trailing-space requirement (gate symmetry) (#218)"
else
  ng "72b: ac_closeout.sh still requires a trailing space — gate-vs-remedy deadlock on degenerate '- [ ]' (#218)"
fi
# 72c (SITE 4): migrate_v3.sh header no longer claims snapshot idempotency it
# never had (second-resolution timestamp).
if ! grep -qF 're-running with the same date does nothing' "$SHELL_ROOT/scripts/migrate_v3.sh" 2>/dev/null; then
  ok "72c: migrate_v3.sh header no longer claims false snapshot idempotency (#218)"
else
  ng "72c: migrate_v3.sh header still claims snapshot idempotency it never had (#218)"
fi
# 72d (#500): ac_closeout.sh's detect + tick must track the gate's broadened
# bullet family (`-`/`*`/`+` and ordered `N.`), or a non-`-` checkbox issue
# deadlocks (gate blocks on it, remedy finds no AC lines → posts no marker).
# Script-content assertion (parity with §72a-c): the `([-*+]|[0-9]+\.)` family
# fragment must appear in BOTH the detection grep and the tick sed (>=2).
AC_SH2="$SHELL_ROOT/scripts/ac_closeout.sh"
s72d=$(grep -cF '([-*+]|[0-9]+\.)' "$AC_SH2" 2>/dev/null | tr -d ' '); [ -z "$s72d" ] && s72d=0
if [ "$s72d" -ge 2 ]; then
  ok "72d: ac_closeout.sh detect+tick track the gate's broadened bullet family (no deadlock) (#500)"
else
  ng "72d: ac_closeout.sh still dash-only — deadlocks on non-dash checkbox issues the gate blocks (found=$s72d) (#500)"
fi

# ---------- 73. Initiative-tier enforcement matchers (#251, M1.2) ----------
# (a) initiative/directive label mutual-exclusivity + (b) Directive parent-XOR
# (both folded into label-parent-consistency on --add-label), and (c) the new
# initiative-readonly matcher. Mock gh branches on `--json labels` vs `--json
# body` so the type predicates AND the field/marker resolvers run through the
# real hook. Fixtures: 801 directive+MISSION-fit-only, 802 initiative, 803
# Parent-Initiative-marker-only, 804 task, 805 BOTH parent kinds, 806 NEITHER,
# 807 gh-down, 808 MISSION-fit-only.
S73_DIR=$(mktemp -d)
mkdir -p "$S73_DIR/bin" "$S73_DIR/target"
S73_TARGET=$(cd "$S73_DIR/target" && pwd -P)
(cd "$S73_TARGET" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; })
 git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
printf '%s\n' "$S73_TARGET" >> "$SMOKE_REG"
cat > "$S73_DIR/bin/gh" <<'GHEOF'
#!/bin/sh
n=$(printf '%s\n' "$*" | sed -nE 's/.*issue (view|edit|close|reopen|comment) #?([0-9]+).*/\2/p' | head -1)
case "$*" in
  *"repo view"*owner*) printf 'smoke-owner\n'; exit 0 ;;
  *"repo view"*name*)  printf 'smoke-repo\n'; exit 0 ;;
esac
[ "$n" = 807 ] && exit 1   # gh down → fail-open
case "$*" in
  *"--json labels"*)
    case "$n" in
      801) printf 'directive\n' ;; 802) printf 'initiative\n' ;;
      804) printf 'task\n' ;; 803|805|806|808) printf 'P2\n' ;;
      *) printf '\n' ;;
    esac; exit 0 ;;
  *"--json body"*)
    case "$n" in
      801|808) printf '## Objective\nx\n\n## MISSION fit\nConsuming Initiatives\n' ;;
      802) printf '## Termination condition\nx\n' ;;
      803) printf 'Parent Initiative: #802\n\n## Objective\nx\n' ;;
      805) printf 'Parent Initiative: #802\n\n## MISSION fit\nX\n' ;;
      806) printf '## What\nno parent\n' ;;
      *) printf '\n' ;;
    esac; exit 0 ;;
  *"--json authorAssociation"*) printf 'NONE\n'; exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$S73_DIR/bin/gh"
s73_run() {  # $1 = command (may carry a SKIP_HOOKS env-prefix)
  ( cd "$S73_TARGET" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
      | PATH="$S73_DIR/bin:$PATH" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 )
  return $?
}
s73_cc() { rm -f "$SHELL_ROOT/.claude/state/issue-type-cache/smoke-owner__smoke-repo__"* 2>/dev/null || true; }

# (a) label mutual-exclusivity
s73_cc; s73_run "gh issue edit 801 --add-label initiative"
[ "$?" = 2 ] && ok "73a: --add-label initiative on a directive Issue → block (#251)" || ng "73a: initiative-on-directive not blocked (#251)"
s73_cc; s73_run "gh issue edit 804 --add-label P1"
[ "$?" = 0 ] && ok "73a: --add-label P1 on a task Issue → allow (no type-key conflict) (#251)" || ng "73a: non-conflicting add over-blocked (#251)"

# (b) Directive parent-XOR on --add-label directive
s73_cc; s73_run "gh issue edit 805 --add-label directive"
[ "$?" = 2 ] && ok "73b: --add-label directive with BOTH parent kinds → block (#251)" || ng "73b: parent-XOR both-present not blocked (#251)"
s73_cc; s73_run "gh issue edit 806 --add-label directive"
[ "$?" = 2 ] && ok "73b: --add-label directive with NEITHER parent kind → block (#251)" || ng "73b: parent-XOR neither-present not blocked (#251)"
s73_cc; s73_run "gh issue edit 808 --add-label directive"
[ "$?" = 0 ] && ok "73b: --add-label directive with exactly a MISSION-fit field → allow (#251)" || ng "73b: valid MISSION-parented over-blocked (#251)"
s73_cc; s73_run "gh issue edit 803 --add-label directive"
[ "$?" = 0 ] && ok "73b: --add-label directive with exactly a Parent Initiative marker → allow (#251)" || ng "73b: valid Initiative-parented over-blocked (#251)"
s73_cc; s73_run "gh issue edit 807 --add-label directive"
[ "$?" = 0 ] && ok "73b: parent-XOR fail-open on unresolvable body → allow (#251)" || ng "73b: parent-XOR fail-open regression (#251)"

# (c) initiative-readonly
s73_cc; s73_run "gh issue edit 802 --add-label P1"
[ "$?" = 2 ] && ok "73c: gh issue edit on an initiative Issue → block (read-only) (#251)" || ng "73c: initiative edit not blocked (#251)"
s73_cc; s73_run "gh issue close 802"
[ "$?" = 2 ] && ok "73c: gh issue close on an initiative Issue → block (#251)" || ng "73c: initiative close not blocked (#251)"
s73_cc; s73_run "gh issue reopen 802"
[ "$?" = 2 ] && ok "73c: gh issue reopen on an initiative Issue → block (#251)" || ng "73c: initiative reopen not blocked (#251)"
s73_cc; s73_run 'gh issue comment 802 --body hi'
[ "$?" = 0 ] && ok "73c: gh issue comment on an initiative Issue → allow (#251)" || ng "73c: comment on initiative wrongly blocked (#251)"
s73_cc; s73_run "gh issue edit 801 --body x"
[ "$?" = 0 ] && ok "73c: gh issue edit on a non-initiative Issue → allow (no over-block) (#251)" || ng "73c: non-initiative edit over-blocked (#251)"
s73_cc; s73_run "gh issue close 807"
[ "$?" = 0 ] && ok "73c: initiative-readonly fail-open on unresolvable → allow (#251)" || ng "73c: initiative-readonly fail-open regression (#251)"
s73_cc
s73_b=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$s73_b" ] && s73_b=0
s73_run "SKIP_HOOKS=initiative-readonly SKIP_REASON=maintainer-edit gh issue close 802"; s73_rc=$?
s73_a=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$s73_a" ] && s73_a=0
if [ "$s73_rc" = 0 ] && [ "$((s73_a - s73_b))" -ge 1 ] \
   && tail -n "$((s73_a - s73_b))" "$REAL_AUDIT" 2>/dev/null | grep -q '"category":"initiative-readonly"'; then
  ok "73c: SKIP_HOOKS=initiative-readonly escape honored + audited (#251)"
else
  ng "73c: initiative-readonly escape not honored/audited (rc=$s73_rc) (#251)"
fi

# (d) issue_has_mission_fit_field tri-state unit (function-mock, §44m style)
s73_field() {
  ( export GHJIG_ROOT="$TMP/s73fld"; mkdir -p "$GHJIG_ROOT/.claude/state"
    s73_body="$1"
    gh() { case "$*" in *'issue view'*'--json body'*) printf '%s\n' "$s73_body" ;; *) return 0 ;; esac; }
    . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"
    issue_has_mission_fit_field 700; echo $? )
}
[ "$(s73_field '## Objective
x

## MISSION fit
Consuming Initiatives')" = 0 ] && ok "73d: issue_has_mission_fit_field present (heading anywhere) → rc 0 (#251)" || ng "73d: mission-fit present not detected (#251)"
[ "$(s73_field '## What
no fit field here')" = 1 ] && ok "73d: issue_has_mission_fit_field absent → rc 1 (#251)" || ng "73d: mission-fit absent rc wrong (#251)"
s73_field_fail() { ( export GHJIG_ROOT="$TMP/s73fld2"; mkdir -p "$GHJIG_ROOT/.claude/state"; gh() { return 1; }; . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"; issue_has_mission_fit_field 700; echo $? ) }
[ "$(s73_field_fail)" = 2 ] && ok "73d: issue_has_mission_fit_field unresolvable → rc 2 (#251)" || ng "73d: mission-fit fail-open rc wrong (#251)"

# §73e (#257, M3) — the /consume-initiative command exists with the five-step /
# two-gate / read-only shape. Structural anchors (the flow is prompt-driven; the
# mechanized surfaces it relies on — initiative-readonly comment-allow, the
# label-parent-consistency create-path exemption, the I1/I2 reviewer checks — are
# already covered by §73a-d / §44 / §67f).
S73E_CMD="$SHELL_ROOT/.claude/commands/consume-initiative.md"
if [ -f "$S73E_CMD" ] \
   && grep -qF 'argument-hint' "$S73E_CMD" \
   && grep -qiF 'substrate' "$S73E_CMD" \
   && grep -qF 'initiative' "$S73E_CMD" \
   && grep -qF 'activation-reviewer' "$S73E_CMD" \
   && grep -qiF 'contract-evaluability' "$S73E_CMD" \
   && grep -qiF 'extraction-faithfulness' "$S73E_CMD" \
   && grep -qF 'Parent Initiative: #' "$S73E_CMD" \
   && grep -qF 'gh issue comment' "$S73E_CMD" \
   && grep -qF 'status:proposed' "$S73E_CMD" \
   && grep -qF -- '--body-file' "$S73E_CMD"; then
  ok "73e: /consume-initiative command has the five-step / two-gate / read-only shape (#257)"
else
  ng "73e: /consume-initiative command missing or incomplete (#257)"
fi
# §73e2: read-only discipline — the only Initiative write the flow performs is a
# comment; the procedure must not edit/close the Initiative. Assert a 'Forbidden'
# (or never-edit) clause naming that it never edits/closes the Initiative.
if [ -f "$S73E_CMD" ] && grep -qiE 'never (edit|close|relabel|activate|mutat)' "$S73E_CMD"; then
  ok "73e2: /consume-initiative documents the never-mutate-the-Initiative discipline (#257)"
else
  ng "73e2: /consume-initiative missing the read-only discipline clause (#257)"
fi

# §73f (#260, M4) — the /initiative-feedback command exists with both modes, both
# scannable markers, and the comment-only / escalate-not-decide discipline.
S73F_CMD="$SHELL_ROOT/.claude/commands/initiative-feedback.md"
if [ -f "$S73F_CMD" ] \
   && grep -qF -- '--challenge' "$S73F_CMD" \
   && grep -qF -- '--completion' "$S73F_CMD" \
   && grep -qF '## Initiative challenge' "$S73F_CMD" \
   && grep -qF '## Initiative completion' "$S73F_CMD" \
   && grep -qF 'gh issue comment' "$S73F_CMD" \
   && grep -qF -- '--body-file' "$S73F_CMD" \
   && grep -qF 'initiative' "$S73F_CMD"; then
  ok "73f: /initiative-feedback has both modes + both markers + comment/--body-file shape (#260)"
else
  ng "73f: /initiative-feedback command missing or incomplete (#260)"
fi
# §73f2: escalate-not-decide / comment-only discipline — never reject/close/assert-done.
if [ -f "$S73F_CMD" ] \
   && grep -qiE 'never (reject|close|retire|edit|assert|mutat)' "$S73F_CMD" \
   && grep -qiE 'escalat|re-evaluation|termination assessment' "$S73F_CMD"; then
  ok "73f2: /initiative-feedback documents escalate-not-decide (comment-only) discipline (#260)"
else
  ng "73f2: /initiative-feedback missing the escalate-not-decide discipline (#260)"
fi

rm -rf "$S73_DIR"

# ---------- 74. doc-consistency: SPEC enumerables grep-checked against source (#267) ----------
# The recurrence-stopping discipline for the "enumerable-facts-as-prose" drift
# class (spec-internal sweep S3/S6; cf. #238). Greps SPEC's hand-maintained
# counts/lists against their actual sources so a future drift fails smoke
# instead of silently rotting — hooks-as-environment applied to the SPEC itself.

# §74a: agent count — the SPEC directory-tree "(N)" matches .claude/agents/.
s74_agents=$(ls "$SHELL_ROOT/.claude/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
if grep -qF "subagent definitions ($s74_agents)" "$SHELL_ROOT/SPEC.md"; then
  ok "74a: SPEC directory-tree agent count matches .claude/agents/ ($s74_agents) (#267)"
else
  ng "74a: SPEC directory-tree agent count drifted from .claude/agents/ ($s74_agents files) (#267)"
fi
# §74a2: no STALE lower-count agent prose remains anywhere in SPEC (the count
# grew 6→9, so any "six/seven/eight {subagents|-agent|… of them}" agent-count
# phrasing is stale). Closes §74a's single-phrase blind spot.
if grep -qiE '\b(six|seven|eight)([ -])(subagent|agent)|agents/\*` \((six|seven|eight) of them\)|\b(six|seven|eight) subagents' "$SHELL_ROOT/SPEC.md"; then
  ng "74a2: stale lower-count agent prose remains in SPEC (count is $s74_agents) (#267)"
else
  ok "74a2: no stale lower-count agent prose in SPEC (#267)"
fi

# §74b: SKIP_HOOKS coverage — every `should_skip <cat>` in pre_tool_use.sh is
# documented (in backticks) somewhere in SPEC. A new matcher category that is
# never documented fails here (the §7 enumeration is the intended home).
s74_missing=""
for cat in $(grep -oE 'should_skip [a-z-]+' "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" | awk '{print $2}' | sort -u); do
  grep -qF "\`$cat\`" "$SHELL_ROOT/SPEC.md" || s74_missing="$s74_missing $cat"
done
if [ -z "$s74_missing" ]; then
  ok "74b: every should_skip <cat> in pre_tool_use.sh is documented in SPEC (#267)"
else
  ng "74b: SKIP_HOOKS categories undocumented in SPEC:$s74_missing (#267)"
fi

# §74c: dir-mode label count — SPEC §1.7 "N total" matches ensure_v3_labels.sh
# calls + the inline directive/initiative type-keys in onboard_target.sh.
s74_ensure=$(grep -cE '^ensure_label ' "$SHELL_ROOT/scripts/ensure_v3_labels.sh")
s74_inline=$(grep -cE '^ensure_label "(directive|initiative)"' "$SHELL_ROOT/scripts/onboard_target.sh")
s74_total=$((s74_ensure + s74_inline))
if grep -qF "$s74_total total" "$SHELL_ROOT/SPEC.md"; then
  ok "74c: SPEC §1.7 tier-2 label count matches ensure_v3_labels + inline ($s74_total) (#267)"
else
  ng "74c: SPEC §1.7 label count drifted ($s74_ensure ensure + $s74_inline inline = $s74_total) (#267)"
fi

# §74d: reviewer-gate escape audit parity (#558). `directive-review` is a
# command-prose-enforced escape — no PreToolUse hook reads it, so `should_skip`
# never auto-emits its escape record. Every command whose Escape section
# documents the `SKIP_HOOKS=directive-review` bypass must therefore carry the
# explicit `audit_log escape directive-review skip` emission instruction, or the
# "audit-logged" guarantee (SPEC §7) is broken. A doc that keeps the bypass
# prose but drops the emission fails here.
s74d_missing=""
for f in file-directive activate revise-directive complete-directive consume-initiative; do
  fp="$SHELL_ROOT/.claude/commands/$f.md"
  # Only require the emission where the bypass is actually documented.
  if grep -qF 'SKIP_HOOKS=directive-review' "$fp" 2>/dev/null; then
    grep -qF 'audit_log escape directive-review skip' "$fp" 2>/dev/null || s74d_missing="$s74d_missing $f"
  fi
done
if [ -z "$s74d_missing" ]; then
  ok "74d: every /file-directive-family reviewer-gate escape emits an audit record (#558)"
else
  ng "74d: reviewer-gate escape claims audit-logged but drops emission:$s74d_missing (#558)"
fi

# §74e: SPEC §7 documents the reviewer-gate escape audit-parity requirement
# (#558) — the counterpart of §74d on the SPEC side, so the contract can't be
# removed from the SSOT while the command docs keep emitting.
if grep -qF 'audit_log escape directive-review skip' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "74e: SPEC §7 pins the reviewer-gate escape audit-parity emission (#558)"
else
  ng "74e: SPEC §7 missing reviewer-gate escape audit-parity emission (#558)"
fi

# ---------- 75. Initiative-tier spec precision (C2–C5, #263) ----------
# Four integration-boundary invariants the v2 tier shipped without pinning.
# Each AC becomes a durable grep so the precision can't silently regress
# (the §74 enumeration-discipline applied to the Initiative tier).

# 75a (C2): SPEC §1.7 states the create-path split — /file-directive is
# MISSION-parented; Initiative-parented Directives are born only via
# /consume-initiative (no hand-authored Parent Initiative marker).
if grep -qiE 'create-path split' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qE 'sole.*producer of .Parent Initiative|only.*via .?/consume-initiative' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "75a: SPEC §1.7 states the Directive create-path split (C2, #263)"
else
  ng "75a: SPEC §1.7 must state /file-directive=MISSION-parented vs /consume-initiative=Initiative-parented (C2, #263)"
fi

# 75b (C3): SPEC §1.7 states an Initiative is outside the 4-state lifecycle
# and the status:* taxonomy (the §2.1 half landed with EI-A; this is the
# §1.7 residual cross-reference).
if grep -qiE 'outside the 4-state.*lifecycle' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qiE 'never applies .status:|never.*status:\*|outside.*status:\* taxonomy' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "75b: SPEC §1.7 places Initiative outside the 4-state lifecycle + status:* taxonomy (C3, #263)"
else
  ng "75b: SPEC §1.7 must state an Initiative is outside the 4-state lifecycle + status:* taxonomy (C3, #263)"
fi

# 75c (C4): /activate guards the initiative label (refuses, routes to
# /consume-initiative) and SPEC §5.12 names the tri-state resolution —
# closing the binary-vs-tri-state mis-typing gap.
ACTIVATE_CMD="$SHELL_ROOT/.claude/commands/activate.md"
if grep -qiE 'initiative.*(refuse|consumed via .?/consume-initiative)' "$ACTIVATE_CMD" 2>/dev/null \
   && grep -qiE 'tri-state' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qE '§5\.12.*[Aa]ctivate|/activate.*tri-state|tri-state.*activate' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "75c: /activate + SPEC §5.12 guard the initiative label (tri-state) (C4, #263)"
else
  ng "75c: /activate must refuse the initiative label and SPEC §5.12 must name the tri-state resolution (C4, #263)"
fi

# 75d (C5): SPEC §6.1 documents that initiative-readonly's block beats
# trusted-filer-mutate's --reason completed allowance on an Initiative close,
# and names the real mechanism (block-is-terminal, not matcher ordering).
if grep -qiE 'block-is-terminal|block.*terminat' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qiE 'never.*closed by the shell|Precedence over .trusted-filer-mutate' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "75d: SPEC §6.1 documents initiative-readonly close precedence (block-is-terminal) (C5, #263)"
else
  ng "75d: SPEC §6.1 must document initiative-readonly's close precedence over trusted-filer-mutate (C5, #263)"
fi

# ---------- 76. resolve_gh_issue_target parser hardening (#283) ----------
# Direct unit tests of the selector helper (pure string parsing — no gh needed).
# The helper is sourced + called in a subshell that echoes "issue<TAB>repo"; the
# parent captures and asserts so ok/ng counters live in the parent.
s76_call() {
  # $1 = command, $2 = verb-regex → echoes "<issue>\t<repo>"
  ( export GHJIG_ROOT="$SHELL_ROOT"
    # shellcheck disable=SC1091
    . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"
    resolve_gh_issue_target "$1" "$2" )
}

# 76a (#283): quote-aware — a quoted flag value with an INTERIOR digit
# (`--body "fixes 99 things"`) must not be mistaken for the positional issue
# selector. Pre-#283 `read -ra` word-split the value, so `99` won was picked
# over the real `7`. shlex tokenization keeps the quoted value one token.
s76a=$(s76_call 'gh issue edit --body "fixes 99 things" 7 --add-label execution' 'edit')
s76a_issue=${s76a%%	*}
if [ "$s76a_issue" = 7 ]; then
  ok "76a: quoted flag value's interior digit not mistaken for the issue (#283)"
else
  ng "76a: interior digit of a quoted flag value picked as issue — got [$s76a_issue] want 7 (#283)"
fi

# 76b (#283): host-prefix — `--repo github.com/o/r` must normalize to `o/r`,
# not `github.com/r` (`${repo%%/*}`/`${repo##*/}` lost the owner pre-#283 →
# gh query failed → fail-open). gh accepts the `[HOST/]OWNER/REPO` spec.
s76b=$(s76_call 'gh issue edit 5 --repo github.com/o/r --add-label execution' 'edit')
s76b_repo=${s76b#*	}
if [ "$s76b_repo" = "o/r" ]; then
  ok "76b: host-prefixed --repo normalized to owner/name (#283)"
else
  ng "76b: host-prefixed --repo not normalized — got [$s76b_repo] want o/r (#283)"
fi

# 76c (#283 regression): the bare, flag-ordered, and =-form selectors still
# resolve correctly (no regression from the tokenizer swap).
s76c1=$(s76_call 'gh issue edit 888 --add-label execution' 'edit');         s76c1=${s76c1%%	*}
s76c2=$(s76_call 'gh issue edit --add-label execution 888' 'edit');         s76c2=${s76c2%%	*}
s76c3=$(s76_call 'gh issue close 42 --repo=o/r' 'edit|close|reopen'); s76c3_repo=${s76c3#*	}; s76c3=${s76c3%%	*}
if [ "$s76c1" = 888 ] && [ "$s76c2" = 888 ] && [ "$s76c3" = 42 ] && [ "$s76c3_repo" = "o/r" ]; then
  ok "76c: bare / flag-ordered / =-form selectors still resolve (#283 regression)"
else
  ng "76c: selector regression — bare=[$s76c1] flagfirst=[$s76c2] close=[$s76c3] repo=[$s76c3_repo] (#283)"
fi

# 76d (#283 regression): URL form still extracts issue + owner/name (incl. an
# enterprise host) — the URL branch already handled host correctly.
s76d=$(s76_call 'gh issue edit https://gh.corp.example/o/r/issues/77 --add-label execution' 'edit')
s76d_issue=${s76d%%	*}; s76d_repo=${s76d#*	}
if [ "$s76d_issue" = 77 ] && [ "$s76d_repo" = "o/r" ]; then
  ok "76d: URL-form (enterprise host) still extracts issue + owner/name (#283 regression)"
else
  ng "76d: URL parse regression — issue=[$s76d_issue] repo=[$s76d_repo] (#283)"
fi

# ---------- 77. reviewer working-tree discipline (#285) ----------
# Each read-only-by-intent Bash subagent must carry the working-tree-discipline
# constraint (read-only git only) so a reviewer can't silently revert/stage the
# parent's uncommitted work when sharing the tree. Belt-and-suspenders to the
# canonical worktree-isolation invocation (SPEC §1.5).
s77_missing=""
for a in code-reviewer security-reviewer activation-reviewer issue-reviewer plan-reviewer plan-challenger planner explorer; do
  f="$SHELL_ROOT/.claude/agents/$a.md"
  if ! { [ -f "$f" ] \
         && grep -qiF 'Working-tree discipline' "$f" \
         && grep -qiF 'read-only git' "$f"; }; then
    s77_missing="$s77_missing $a"
  fi
done
if [ -z "$s77_missing" ]; then
  ok "77: all 8 read-only Bash subagents carry the read-only-git working-tree constraint (#285, +plan-challenger #530, +planner #552)"
else
  ng "77: working-tree-discipline constraint missing from:$s77_missing (#285/#552)"
fi

# ---------- 77b. planner listed in CLAUDE.md working-tree-isolation set (#552) ----------
# planner carries Bash and is read-only-by-intent; it must appear in the
# CLAUDE.md isolation roster alongside the other read-only reviewers, not be
# silently exempt (cluster F, Directive #550).
S77B_CLAUDE="$SHELL_ROOT/.claude/CLAUDE.md"
if grep -qiF 'Working-tree isolation' "$S77B_CLAUDE" \
   && grep -nE 'Working-tree isolation.*`planner`' "$S77B_CLAUDE" >/dev/null 2>&1; then
  ok "77b: planner listed in CLAUDE.md working-tree-isolation roster (#552)"
else
  # accept planner appearing anywhere inside the isolation-roster sentence
  if awk '/\*\*Working-tree isolation\*\*/{f=1} f&&/planner/{print; exit}' "$S77B_CLAUDE" | grep -q planner; then
    ok "77b: planner listed in CLAUDE.md working-tree-isolation roster (#552)"
  else
    ng "77b: planner missing from CLAUDE.md working-tree-isolation roster (#552)"
  fi
fi

# ---------- 78. merge-strategy matcher (#288) ----------
# Enforces SPEC §5.7.1: `gh pr merge` to the DEFAULT branch must be `--merge`.
# squash/rebase/bare → block; --merge → allow; squash on a NON-default base →
# allow. Keyed on the live default branch. Fail-open if gh can't resolve.
PT78_DIR=$(mktemp -d)
PT78_SHIM="$PT78_DIR/bin"
PT78_STATE="$PT78_DIR/state"
mkdir -p "$PT78_SHIM" "$PT78_STATE"
# Shim answers the two resolutions the matcher needs (and nothing for the
# ac-closeout arm, which then fail-opens to allow — so rc is decided by
# merge-strategy). Empty state file → empty output → fail-open path.
cat > "$PT78_SHIM/gh" <<'SHIM'
#!/bin/sh
case "$*" in
  *"pr view"*headRefOid*) echo smoke-attest-head ;;  # #586 merge-review head-pin match
  *"api"*"/reviews"*)               printf '[{"state":"APPROVED","commit_id":"smoke-attest-head","submitted_at":"2020-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"lgtm"}]\n' ;;  # #586 native APPROVED@head → merge-review allows
  *"repo view"*"nameWithOwner"*)    echo o/r ;;  # #586 merge-review owner/repo
  *"repo view"*"defaultBranchRef"*) cat "$GH_SHIM_STATE/default_branch" 2>/dev/null ;;
  # Per-PR bases for the #290 finding-B test: PR 5 is on the default branch,
  # PR 7 is on a non-default base. (Specific cases before the generic one.)
  *"pr view 7 "*"baseRefName"*)     echo feature-x ;;
  *"pr view 5 "*"baseRefName"*)     echo main ;;
  *"pr view"*"baseRefName"*)        cat "$GH_SHIM_STATE/base_branch" 2>/dev/null ;;
esac
exit 0
SHIM
chmod +x "$PT78_SHIM/gh"
printf 'main\n' > "$PT78_STATE/default_branch"
printf 'main\n' > "$PT78_STATE/base_branch"

pt78_run() {  # $1 = command (may carry a SKIP_HOOKS env-prefix) → echoes hook exit code
  (
    cd "$TMP/fake" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$1" | jq -Rs .)" \
      | PATH="$PT78_SHIM:$PATH" GH_SHIM_STATE="$PT78_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
    printf '%s' "$?"
  )
}

# 78a (#288): squash → default branch (base=main, default=main) → BLOCK.
# RED before the matcher (today only ac-closeout runs → allow).
[ "$(pt78_run 'gh pr merge 200 --squash --delete-branch')" = 2 ] \
  && ok "78a: squash → default branch blocked (#288)" \
  || ng "78a: squash → default branch NOT blocked (#288)"

# 78b: rebase → default branch → BLOCK.
[ "$(pt78_run 'gh pr merge 200 --rebase')" = 2 ] \
  && ok "78b: rebase → default branch blocked (#288)" \
  || ng "78b: rebase → default branch NOT blocked (#288)"

# 78c: bare merge (no strategy flag) → default branch → BLOCK.
[ "$(pt78_run 'gh pr merge 200 --delete-branch')" = 2 ] \
  && ok "78c: bare merge → default branch blocked (#288)" \
  || ng "78c: bare merge → default branch NOT blocked (#288)"

# 78d: --merge → default branch → ALLOW (the policy-compliant path).
[ "$(pt78_run 'gh pr merge 200 --merge --delete-branch')" = 0 ] \
  && ok "78d: --merge → default branch allowed (#288)" \
  || ng "78d: --merge → default branch wrongly blocked (#288)"

# 78e: --auto --merge (the /ship form) → ALLOW.
[ "$(pt78_run 'gh pr merge 200 --auto --merge --delete-branch')" = 0 ] \
  && ok "78e: --auto --merge (/ship form) → default branch allowed (#288)" \
  || ng "78e: --auto --merge wrongly blocked (#288)"

# 78f: squash → NON-default base (base=feature-x, default=main) → ALLOW
# (topic-branch consolidation, §10.5).
printf 'feature-x\n' > "$PT78_STATE/base_branch"
[ "$(pt78_run 'gh pr merge 200 --squash --delete-branch')" = 0 ] \
  && ok "78f: squash → non-default base allowed (#288)" \
  || ng "78f: squash → non-default base wrongly blocked (#288)"
printf 'main\n' > "$PT78_STATE/base_branch"   # restore

# 78g: fail-open — default branch unresolvable (empty) + squash → ALLOW.
printf '' > "$PT78_STATE/default_branch"
[ "$(pt78_run 'gh pr merge 200 --squash')" = 0 ] \
  && ok "78g: fail-open when default branch unresolvable → allow (#288)" \
  || ng "78g: did not fail-open on unresolvable default branch (#288)"
printf 'main\n' > "$PT78_STATE/default_branch"  # restore

# 78h: escape — SKIP_HOOKS=merge-strategy bypasses the squash→default block
# (rc=0) AND emits an escape audit record.
REAL_AUDIT_78="$SMOKE_AUDIT"
s78_before=$(wc -l < "$REAL_AUDIT_78" 2>/dev/null | tr -d ' '); [ -z "$s78_before" ] && s78_before=0
s78_rc=$(pt78_run "SKIP_HOOKS=merge-strategy SKIP_REASON=consolidator gh pr merge 200 --squash")
s78_after=$(wc -l < "$REAL_AUDIT_78" 2>/dev/null | tr -d ' '); [ -z "$s78_after" ] && s78_after=0
s78_delta=$((s78_after - s78_before))
if [ "$s78_rc" = 0 ] && [ "$s78_delta" -ge 1 ] \
   && tail -n "$s78_delta" "$REAL_AUDIT_78" 2>/dev/null | grep -q '"category":"merge-strategy"' \
   && tail -n "$s78_delta" "$REAL_AUDIT_78" 2>/dev/null | grep -q '"event":"escape"'; then
  ok "78h: SKIP_HOOKS=merge-strategy bypasses + audit-logs escape (#288)"
else
  ng "78h: merge-strategy escape not honored / not audited (rc=$s78_rc delta=$s78_delta) (#288)"
fi

# 78i (#290 C): the short merge flag `-m` (gh's `--merge` shorthand) → ALLOW.
# RED pre-#290 (substring grep saw no `--merge` → treated as non-merge → block).
[ "$(pt78_run 'gh pr merge 200 -m')" = 0 ] \
  && ok "78i: short -m (merge) → default branch allowed (#290 C)" \
  || ng "78i: short -m wrongly blocked (#290 C)"

# 78j (#290 A): `--merge` inside a --body VALUE must NOT be read as the strategy;
# the real strategy is --squash → BLOCK. RED pre-#290 (substring grep matched the
# body's `--merge` → silent allow while gh squashes).
[ "$(pt78_run 'gh pr merge 200 --squash --body "see --merge discussion"')" = 2 ] \
  && ok "78j: --merge inside --body value not read as strategy → block (#290 A)" \
  || ng "78j: --merge in a --body value bypassed the squash block (#290 A)"

# 78k (#290 B): the PR is the first POSITIONAL token, not a flag value.
# `--body 7 --squash 5` → PR 5 (on default `main` → block), NOT PR 7 (on
# non-default `feature-x` → would allow). RED pre-#290 (extract_pr returned 7).
[ "$(pt78_run 'gh pr merge --body 7 --squash 5')" = 2 ] \
  && ok "78k: PR resolved as positional (5), not the --body value (7) → block (#290 B)" \
  || ng "78k: PR mis-resolved from a flag value → wrong base (#290 B)"

# 78l (#290 C regression): short `-s` (squash) → default branch → BLOCK (the
# short squash/rebase forms must still be caught).
[ "$(pt78_run 'gh pr merge 200 -s')" = 2 ] \
  && ok "78l: short -s (squash) → default branch blocked (#290 C)" \
  || ng "78l: short -s squash not blocked (#290 C)"

# 78m (#340): command-word merge detection. `gh pr merge` appearing only as
# DATA — a quoted argument, a heredoc body, a here-string, a commit message —
# must NOT trigger the gate (reuses the PT78 shim: default=main, base=main, so
# pre-#340 the coarse substring would block these). Reproduce-first: each rc=0
# assertion FAILS today (substring → block rc=2) and passes after is_pr_merge_command.

# 78m-1: `gh pr merge` inside a quoted echo argument → not a command → allow.
[ "$(pt78_run 'echo "run gh pr merge 200 --squash later"')" = 0 ] \
  && ok "78m-1: gh pr merge in a quoted arg not treated as a merge (#340)" \
  || ng "78m-1: quoted-arg gh-pr-merge text wrongly gated (#340)"

# 78m-2: `gh pr merge` inside a quoted --body value of a different gh command.
[ "$(pt78_run 'gh issue comment 200 --body "later we gh pr merge 200 --squash"')" = 0 ] \
  && ok "78m-2: gh pr merge in a quoted --body not treated as a merge (#340)" \
  || ng "78m-2: quoted --body gh-pr-merge text wrongly gated (#340)"

# 78m-3: `gh pr merge` inside an unquoted heredoc body (<<EOF) → data → allow.
s78m3=$(printf 'cat <<EOF\ndiscuss gh pr merge 200 --squash here\nEOF\n')
[ "$(pt78_run "$s78m3")" = 0 ] \
  && ok "78m-3: gh pr merge in a <<EOF heredoc body not gated (#340)" \
  || ng "78m-3: heredoc-body gh-pr-merge text wrongly gated (#340)"

# 78m-4: quoted-delimiter heredoc (<<'EOF') body → data → allow.
s78m4=$(printf "cat <<'EOF'\ngh pr merge 200 --squash\nEOF\n")
[ "$(pt78_run "$s78m4")" = 0 ] \
  && ok "78m-4: gh pr merge in a <<'EOF' heredoc body not gated (#340)" \
  || ng "78m-4: quoted-delimiter heredoc body wrongly gated (#340)"

# 78m-5: here-string (<<<) carrying the text → data, NOT a heredoc → allow.
[ "$(pt78_run 'cat <<<"gh pr merge 200 --squash"')" = 0 ] \
  && ok "78m-5: gh pr merge in a <<< here-string not gated (#340)" \
  || ng "78m-5: here-string gh-pr-merge text wrongly gated (#340)"

# --- zero-false-negative guard: real merges MUST still be gated post-#340 ---

# 78m-6: a genuine squash → default branch still BLOCKS (the load-bearing invariant).
[ "$(pt78_run 'gh pr merge 200 --squash --delete-branch')" = 2 ] \
  && ok "78m-6: real squash merge still blocked after #340 (#340)" \
  || ng "78m-6: real merge slipped the gate — false-negative regression (#340)"

# 78m-7: env-prefixed real merge (GH_TOKEN=x gh pr merge … --squash) still BLOCKS.
[ "$(pt78_run 'GH_TOKEN=x gh pr merge 200 --squash')" = 2 ] \
  && ok "78m-7: env-prefixed real merge still blocked (#340)" \
  || ng "78m-7: env-prefixed real merge slipped the gate (#340)"

# 78m-8: `&&`-chained real merge still BLOCKS.
[ "$(pt78_run 'true && gh pr merge 200 --squash')" = 2 ] \
  && ok "78m-8: &&-chained real merge still blocked (#340)" \
  || ng "78m-8: &&-chained real merge slipped the gate (#340)"

# --- 78n-78r (#499 / Directive #498): a leading gh GLOBAL FLAG before `pr merge`
# must not bypass the merge-strategy entry anchor (pre_tool_use.sh :259). The
# tight `\bgh[[:space:]]+pr[[:space:]]+merge` anchor missed `gh --repo o/r pr
# merge`; the #499 fix widens it to tolerate a leading global-flag run while
# keeping `pr merge` ADJACENT (so it must NOT over-match a `merge` word in a
# `pr create` body). Placed in §78 (before the PT78 teardown below) so the pt78
# shim is live — reusing pt78_run at end-of-file is unreliable. RED before the
# fix (leading-flag forms returned allow); 78r is the over-block guard.
[ "$(pt78_run 'gh --repo o/r pr merge 200 --squash')" = 2 ] \
  && ok "78n: leading --repo <val> before 'pr merge' → squash still blocked (#499)" \
  || ng "78n: leading --repo bypassed merge-strategy (#499)"
[ "$(pt78_run 'gh -R o/r pr merge 200 --squash')" = 2 ] \
  && ok "78o: leading -R <val> before 'pr merge' → squash still blocked (#499)" \
  || ng "78o: leading -R bypassed merge-strategy (#499)"
[ "$(pt78_run 'gh --repo=o/r pr merge 200 --squash')" = 2 ] \
  && ok "78p: leading --repo=val (equals form) before 'pr merge' → squash still blocked (#499)" \
  || ng "78p: leading --repo=val bypassed merge-strategy (#499)"
[ "$(pt78_run 'gh --repo o/r pr merge 200 --merge')" = 0 ] \
  && ok "78q: leading --repo + --merge still allowed (no over-block) (#499)" \
  || ng "78q: leading-flag --merge wrongly blocked (#499)"
[ "$(pt78_run 'gh pr create --title fix --body "see the pr merge discussion thread"')" = 0 ] \
  && ok "78r: 'merge' inside a pr-create body does NOT trip merge-strategy (over-block guard) (#499)" \
  || ng "78r: widened anchor over-blocks a pr-create whose body contains 'merge' (#499)"

rm -rf "$PT78_DIR"

