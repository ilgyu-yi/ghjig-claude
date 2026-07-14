# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- 33. Co-Authored-By trailer toggle (#63) ----------
# helpers/coauthor.sh exposes coauthor_trailer. Default emits the
# Co-Authored-By line; GHJIG_COAUTHOR=off OR
# .claude/state/coauthor=off suppresses it. Env wins over file.
# Unknown values fail-safe to `on`.
COAUTHOR_HELPER="$SHELL_ROOT/.claude/hooks/helpers/coauthor.sh"

if [ -f "$COAUTHOR_HELPER" ]; then
  ok "coauthor: helpers/coauthor.sh exists (#63)"
else
  ng "coauthor: helpers/coauthor.sh missing (#63)"
fi

COAUTHOR_TMP=$(mktemp -d)
mkdir -p "$COAUTHOR_TMP/.claude/state"

# 33a. Default (no env, no file) → emits trailer.
(
  export GHJIG_ROOT="$COAUTHOR_TMP"
  unset GHJIG_COAUTHOR
  rm -f "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  out=$(coauthor_trailer)
  printf '%s' "$out" | grep -q '^Co-Authored-By: Claude'
) && ok "coauthor: default emits trailer (#63)" \
   || ng "coauthor: default did not emit trailer (#63)"

# 33b. File=off → empty.
(
  export GHJIG_ROOT="$COAUTHOR_TMP"
  unset GHJIG_COAUTHOR
  printf 'off\n' > "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  out=$(coauthor_trailer)
  [ -z "$out" ]
) && ok "coauthor: file=off emits empty (#63)" \
   || ng "coauthor: file=off should emit empty (#63)"

# 33c. Env=off overrides file=on.
(
  export GHJIG_ROOT="$COAUTHOR_TMP"
  export GHJIG_COAUTHOR=off
  printf 'on\n' > "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  out=$(coauthor_trailer)
  [ -z "$out" ]
) && ok "coauthor: env=off overrides file=on (#63)" \
   || ng "coauthor: env should override file (#63)"

# 33d. Unknown value → fail-safe to `on` + stderr warning.
(
  export GHJIG_ROOT="$COAUTHOR_TMP"
  export GHJIG_COAUTHOR=maybe
  rm -f "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  stderr=$(coauthor_trailer 2>&1 >/dev/null)
  out=$(coauthor_trailer 2>/dev/null)
  printf '%s' "$out" | grep -q '^Co-Authored-By: Claude' || exit 1
  printf '%s' "$stderr" | grep -qi 'unknown\|warn\|fallback\|invalid' || exit 1
) && ok "coauthor: unknown value fails-safe to on + warns (#63)" \
   || ng "coauthor: unknown value should fail-safe to on + warn (#63)"

# 33e (#294). Version-AGNOSTIC trailer: the emitted line must be exactly
# `Co-Authored-By: Claude <noreply@anthropic.com>` with NO model version
# (`Opus`, `4.x`, `(1M context)`), so it never re-drifts at a model bump.
(
  export GHJIG_ROOT="$COAUTHOR_TMP"
  unset GHJIG_COAUTHOR
  rm -f "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  out=$(coauthor_trailer)
  [ "$out" = 'Co-Authored-By: Claude <noreply@anthropic.com>' ] || exit 1
  printf '%s' "$out" | grep -qiE 'opus|[0-9]\.[0-9]|1M context' && exit 1
  exit 0
) && ok "coauthor: trailer is version-agnostic (no model version) (#294)" \
   || ng "coauthor: trailer must be version-agnostic 'Claude <noreply@anthropic.com>' (#294)"

rm -rf "$COAUTHOR_TMP"

# ---------- 34. README currency (#65, extended for activation-reviewer #58) ----------
# README.md is the project's landing page. Lock that it names all
# nine subagents (eight engineering + one dir-mode), the --base flag,
# the operating modes, and the bootstrap dependencies. Future agent
# additions / flag changes fail-fast here if they forget to update
# the README.
README_MD="$SHELL_ROOT/README.md"

for agent in explorer planner doc-writer test-writer \
             code-reviewer security-reviewer \
             issue-reviewer plan-reviewer \
             activation-reviewer; do
  if grep -q "$agent" "$README_MD" 2>/dev/null; then
    ok "readme: names subagent '$agent' (#65)"
  else
    ng "readme: missing subagent '$agent' (#65)"
  fi
done

if grep -q -- '--base' "$README_MD" 2>/dev/null; then
  ok "readme: mentions --base (#65)"
else
  ng "readme: missing --base (#65)"
fi

if grep -qi 'unattended' "$README_MD" 2>/dev/null \
   && grep -qi 'attended' "$README_MD" 2>/dev/null; then
  ok "readme: names both operating modes (#65)"
else
  ng "readme: missing one or both operating mode names (#65)"
fi

if grep -q 'python3' "$README_MD" 2>/dev/null; then
  ok "readme: install section names python3 dep (#65)"
else
  ng "readme: missing python3 in install deps (#65)"
fi

# §34 (cont., #409): the README must work as an adoption runbook, not just a
# landing page. Presence-grep the five first-contact orientation areas so a
# future edit that drops one fails fast (same fail-fast intent as the agent /
# --base / mode checks above). Contract authored in README.md:"Adopting it on
# your repo".
if grep -q 'Adopting it on your repo' "$README_MD" 2>/dev/null; then
  ok "readme: has the 'Adopting it on your repo' runbook section (#409)"
else
  ng "readme: missing the 'Adopting it on your repo' runbook section (#409)"
fi
if grep -q 'ghjig-root' "$README_MD" 2>/dev/null; then
  ok "readme: Footprint names the ghjig-root binding symlink (#409)"
else
  ng "readme: Footprint must name the ghjig-root binding symlink (#409)"
fi
if grep -qi 'gh auth' "$README_MD" 2>/dev/null && grep -q 'project' "$README_MD" 2>/dev/null; then
  ok "readme: Prerequisites name gh auth + the dir-mode project scope (#409)"
else
  ng "readme: Prerequisites must name gh auth + the dir-mode project scope (#409)"
fi
if grep -qi 'no automatic changes' "$README_MD" 2>/dev/null; then
  ok "readme: previews /onboard ('no automatic changes') (#409)"
else
  ng "readme: must preview /onboard ('no automatic changes') (#409)"
fi
if grep -qi 'PR into your repo' "$README_MD" 2>/dev/null; then
  ok "readme: flags that dir-mode mutates the target via a PR (#409)"
else
  ng "readme: must flag that dir-mode mutates the target via a PR (#409)"
fi
# AC#7 — the Korean README must mirror the section (a stale mirror is a new drift).
if grep -q 'Adopting it on your repo' "$SHELL_ROOT/README.ko.md" 2>/dev/null; then
  ok "readme.ko: mirrors the 'Adopting it on your repo' section (#409)"
else
  ng "readme.ko: must mirror the 'Adopting it on your repo' section (#409)"
fi

# §34 (cont., #413): unattended is the MISSION line-24 headline capability, so
# the README must advertise it in a dedicated subsection — not bury it. Guard
# the subsection heading + that the honest park framing is present, so the
# advertising cannot silently rot. Mirror-presence on README.ko too.
if grep -q 'Attended vs unattended' "$README_MD" 2>/dev/null \
   && grep -qi 'park' "$README_MD" 2>/dev/null; then
  ok "readme: advertises unattended in an 'Attended vs unattended' subsection with park framing (#413)"
else
  ng "readme: missing the 'Attended vs unattended' subsection or its park framing (#413)"
fi
if grep -q 'Attended vs unattended' "$SHELL_ROOT/README.ko.md" 2>/dev/null; then
  ok "readme.ko: mirrors the 'Attended vs unattended' subsection (#413)"
else
  ng "readme.ko: must mirror the 'Attended vs unattended' subsection (#413)"
fi

# ---------- 32. backmerge block (#61) ----------
# `git merge <protected>` on a feature branch is a backmerge; pre_tool_use
# blocks. Allowed: target is non-protected; or current branch IS the
# protected branch (you're locally merging a PR, not back-merging).
# Escape: SKIP_HOOKS=backmerge.

# §32a: git merge main on non-protected branch → block.
if [ "$(hook_run 'git merge main')" = "2" ]; then
  ok "backmerge: git merge main on feature branch blocked (#61)"
else
  ng "backmerge: git merge main on feature branch should block (#61)"
fi

# §32b: git merge feature-x (non-protected target) → allow.
if [ "$(hook_run 'git merge feature-x')" = "0" ]; then
  ok "backmerge: git merge feature-x (non-protected) allowed (#61)"
else
  ng "backmerge: git merge feature-x should allow (#61)"
fi

# §32c: git merge main while currently on main → allow.
BACKMERGE_MAIN_DIR=$(mktemp -d)
(
  cd "$BACKMERGE_MAIN_DIR" || exit 1
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
)
printf '%s\n' "$BACKMERGE_MAIN_DIR" >> "$SMOKE_REG"
(
  cd "$BACKMERGE_MAIN_DIR"
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' 'git merge main' | jq -Rs .)" \
    | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
      bash "$HOOK" >/dev/null 2>&1
  [ "$?" = "0" ]
) && ok "backmerge: on-main merge allowed (#61)" \
   || ng "backmerge: on-main merge should allow (#61)"
grep -vxF "$BACKMERGE_MAIN_DIR" "$SMOKE_REG" > "$SMOKE_REG.tmp"
mv "$SMOKE_REG.tmp" "$SMOKE_REG"
rm -rf "$BACKMERGE_MAIN_DIR"

# §32d: SKIP_HOOKS=backmerge git merge main → allow.
if [ "$(hook_run 'SKIP_HOOKS=backmerge SKIP_REASON=test git merge main')" = "0" ]; then
  ok "backmerge: SKIP_HOOKS=backmerge escape allows (#61)"
else
  ng "backmerge: SKIP_HOOKS=backmerge should allow (#61)"
fi

# §32e-h: option-prefixed forms must also block (the regex must
# tolerate intermediate tokens between `merge` and the ref).
for c in 'git merge --no-edit main' \
         'git merge --no-ff main' \
         'git merge -m "msg" main' \
         'git merge --strategy=ours origin/main'; do
  if [ "$(hook_run "$c")" = "2" ]; then
    ok "backmerge: '$c' blocked (#61)"
  else
    ng "backmerge: '$c' should block (#61)"
  fi
done

# §32i: substring-like name `mainframe` should NOT match.
if [ "$(hook_run 'git merge mainframe')" = "0" ]; then
  ok "backmerge: 'git merge mainframe' (non-protected name) allowed (#61)"
else
  ng "backmerge: 'mainframe' false-positive — should not match (#61)"
fi

# §32j: `feature/main` (a feature branch that happens to contain `main`
# in its name) should NOT match. The matcher's optional remote-style
# prefix could swallow `feature/`, but the inner ref alternation needs
# to anchor cleanly.
if [ "$(hook_run 'git merge feature/main')" = "0" ]; then
  ok "backmerge: 'git merge feature/main' allowed (not a protected ref) (#61)"
else
  ng "backmerge: 'feature/main' false-positive (#61)"
fi

# ---------- 28. SPEC TOC freshness (#51) ----------
# SPEC.md carries a line-indexed TOC between <!-- TOC START / END -->
# markers, regenerated by scripts/build_toc.sh. A heading add/move
# that's not followed by a TOC rebuild should fail this smoke.
BUILD_TOC="$SHELL_ROOT/scripts/build_toc.sh"

if [ -x "$BUILD_TOC" ]; then
  if "$BUILD_TOC" --check >/dev/null 2>&1; then
    ok "spec-toc: scripts/build_toc.sh --check passes (#51)"
  else
    ng "spec-toc: SPEC.md TOC is out of sync — run scripts/build_toc.sh (#51)"
  fi
else
  ng "spec-toc: scripts/build_toc.sh missing or non-executable (#51)"
fi

# ---------- 27. reviewer subagents SSOT (#49) ----------
# SPEC §1.5 + §4.7 + §4.8 + §5.2 + §5.3 introduce two new subagents
# (issue-reviewer, plan-reviewer) that substitute for the human at
# the rationale check and approach check in unattended mode. Lock the
# agent files exist, SPEC subagent table lists them, and the two
# slash-command operational docs reference them.
ISSUE_REVIEWER="$SHELL_ROOT/.claude/agents/issue-reviewer.md"
PLAN_REVIEWER="$SHELL_ROOT/.claude/agents/plan-reviewer.md"
FILE_ISSUE_FOR_49="$SHELL_ROOT/.claude/commands/file-issue.md"
WORK_ON_FOR_49="$SHELL_ROOT/.claude/commands/work-on.md"

[ -f "$ISSUE_REVIEWER" ] && ok "reviewers: issue-reviewer.md exists (#49)" \
  || ng "reviewers: issue-reviewer.md missing (#49)"
[ -f "$PLAN_REVIEWER" ] && ok "reviewers: plan-reviewer.md exists (#49)" \
  || ng "reviewers: plan-reviewer.md missing (#49)"

# YAML frontmatter sanity — file starts with `---` and contains name/description.
for f in "$ISSUE_REVIEWER" "$PLAN_REVIEWER"; do
  base=$(basename "$f")
  if [ -f "$f" ] && head -1 "$f" 2>/dev/null | grep -q '^---$' \
     && head -10 "$f" 2>/dev/null | grep -qE '^(name|description):'; then
    ok "reviewers: $base has YAML frontmatter (#49)"
  else
    ng "reviewers: $base missing or malformed frontmatter (#49)"
  fi
done

# SPEC subagent table lists both agents.
if grep -q '`issue-reviewer`' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -q '`plan-reviewer`' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "reviewers: SPEC §1.5 lists issue-reviewer + plan-reviewer (#49)"
else
  ng "reviewers: SPEC §1.5 missing one or both reviewer names (#49)"
fi

# Operational docs reference the new agents.
if grep -q 'issue-reviewer' "$FILE_ISSUE_FOR_49" 2>/dev/null; then
  ok "reviewers: file-issue.md references issue-reviewer (#49)"
else
  ng "reviewers: file-issue.md missing issue-reviewer reference (#49)"
fi
if grep -q 'plan-reviewer' "$WORK_ON_FOR_49" 2>/dev/null; then
  ok "reviewers: work-on.md references plan-reviewer (#49)"
else
  ng "reviewers: work-on.md missing plan-reviewer reference (#49)"
fi

# ---------- 26. no-stale-unchecked-at-merge SSOT (#47) ----------
# SPEC §1.4 (PR-as-living-doc) + §5.7 (/ship) carry the rule that a
# merged PR body must reflect truth — every `- [ ]` is ticked, marked
# `[~] N/A — <reason>`, or removed. Lock the SSOT + operational doc.
SHIP_CMD_FOR_47="$SHELL_ROOT/.claude/commands/ship.md"

if grep -qi 'checklist audit' "$SHIP_CMD_FOR_47" 2>/dev/null \
   && grep -qi '\[~\] N/A' "$SHIP_CMD_FOR_47" 2>/dev/null; then
  ok "merge-hygiene: ship.md mentions checklist audit + [~] N/A marker (#47)"
else
  ng "merge-hygiene: ship.md missing checklist audit step or N/A marker (#47)"
fi

if grep -qi 'No stale unchecked items' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "merge-hygiene: SPEC.md §1.4 carries no-stale-unchecked rule (#47)"
else
  ng "merge-hygiene: SPEC.md missing no-stale-unchecked rule (#47)"
fi

# ---------- 25. rationale/alternatives review SSOT (#45) ----------
# SPEC §4.1 + §5.2 + §5.3 now require explicit rationale review on
# issue creation and an alternatives-mandatory section in the planner
# output. The operational docs (file-issue.md, work-on.md, planner.md)
# must reflect those contracts; lock them so future edits cannot
# silently drop the review step.
FILE_ISSUE_CMD="$SHELL_ROOT/.claude/commands/file-issue.md"
WORK_ON_CMD="$SHELL_ROOT/.claude/commands/work-on.md"
PLANNER_AGENT="$SHELL_ROOT/.claude/agents/planner.md"

PR_BODY_TPL="$SHELL_ROOT/.claude/templates/pr_body.md"

# Each operational doc check pairs a header/keyword grep with a content
# anchor that survives mild paraphrase, so a future rewording can't
# accidentally drop the contract while keeping the trigger word.
if grep -qi 'rationale' "$FILE_ISSUE_CMD" 2>/dev/null \
   && grep -q 'MISSION fit' "$FILE_ISSUE_CMD" 2>/dev/null; then
  ok "review: file-issue.md mentions rationale check + MISSION fit (#45)"
else
  ng "review: file-issue.md missing rationale check or MISSION fit anchor (#45)"
fi

# INVERTED for #530: the old "beats the alternatives" self-authored-list
# wording is gone. work-on.md now describes the adversarial contest — the
# approach check confirms the winning candidate from the contest record
# {A / B1 / B2 / verdict}, judged by plan-reviewer. Re-anchor to the contest.
if grep -qi 'approach check' "$WORK_ON_CMD" 2>/dev/null \
   && grep -qF 'contest record' "$WORK_ON_CMD" 2>/dev/null \
   && grep -qF '{A, B1, B2}' "$WORK_ON_CMD" 2>/dev/null; then
  ok "review: work-on.md approach check confirms the winning contest candidate {A, B1, B2} (#45/#530)"
else
  ng "review: work-on.md missing approach check or contest-record/{A, B1, B2} anchor (#45/#530)"
fi

# INVERTED for #530: the planner NO LONGER authors `## Alternatives
# considered`, and the old "mandatory" alternatives rule is gone. Assert the
# absence of the old contract AND that the contest record now lives elsewhere
# (the `/work-on` flow assembles it — the interested party no longer controls
# the choice set).
if ! grep -qi 'mandatory' "$PLANNER_AGENT" 2>/dev/null \
   && grep -qF 'not** author' "$PLANNER_AGENT" 2>/dev/null \
   && grep -qiF 'contest record' "$PLANNER_AGENT" 2>/dev/null \
   && grep -qF 'one base Plan A' "$PLANNER_AGENT" 2>/dev/null; then
  ok "review: planner.md no longer authors Alternatives; contest record lives elsewhere (#45/#530)"
else
  ng "review: planner.md still mandates alternatives, or missing 'no longer author'/'contest record'/'one base Plan A' anchor (#45/#530)"
fi

# Template carries the section the planner is required to emit — otherwise
# the planner's output has no slot in the PR body and the contract is
# inconsistent.
if grep -q 'Alternatives considered' "$PR_BODY_TPL" 2>/dev/null; then
  ok "review: pr_body.md template includes Alternatives considered slot (#45)"
else
  ng "review: pr_body.md template missing Alternatives considered slot (#45)"
fi

# ---------- 24. merge-strategy SSOT (#43) ----------
# SPEC §5.7.1 + §12 declare `--merge --delete-branch` as the /ship
# merge mechanism. Lock SPEC.md AND the operational docs against silent
# regressions back to --squash. The checks scope to the actual invocation
# (`gh pr merge ... --merge`) so the rationale paragraph that mentions
# "--squash" in prose doesn't false-positive.
SPEC_MD="$SHELL_ROOT/SPEC.md"
SHIP_CMD="$SHELL_ROOT/.claude/commands/ship.md"
ENG_FLOW="$SHELL_ROOT/docs/ENGINEERING_FLOW.md"

# SPEC.md must carry the positive invocation form and must NOT name
# `gh pr merge ... --squash` as the merge command anywhere.
if grep -qE 'gh pr merge[^`]*--merge\b' "$SPEC_MD" 2>/dev/null; then
  ok "merge-strategy: SPEC.md names gh pr merge --merge (#43)"
else
  ng "merge-strategy: SPEC.md missing gh pr merge --merge (#43)"
fi
if grep -qE 'gh pr merge[^`]*--squash\b' "$SPEC_MD" 2>/dev/null; then
  ng "merge-strategy: SPEC.md still names gh pr merge --squash (#43)"
else
  ok "merge-strategy: SPEC.md no longer names gh pr merge --squash (#43)"
fi

# Operational docs: positive form present, --squash invocation absent.
if grep -qE 'gh pr merge[^`]*--merge\b' "$SHIP_CMD" 2>/dev/null; then
  ok "merge-strategy: ship.md references gh pr merge --merge (#43)"
else
  ng "merge-strategy: ship.md missing gh pr merge --merge (#43)"
fi
if grep -qE 'gh pr merge[^`]*--squash\b' "$SHIP_CMD" 2>/dev/null; then
  ng "merge-strategy: ship.md still references gh pr merge --squash (#43)"
else
  ok "merge-strategy: ship.md no longer references gh pr merge --squash (#43)"
fi
if grep -qE 'gh pr merge[^`]*--squash\b' "$ENG_FLOW" 2>/dev/null; then
  ng "merge-strategy: ENGINEERING_FLOW.md still references gh pr merge --squash (#43)"
else
  ok "merge-strategy: ENGINEERING_FLOW.md no longer references gh pr merge --squash (#43)"
fi

# ---------- 19. formatter shell-injection safety (#25) ----------
# detect_format_cmd must shell-quote the file path it returns, so that
# `eval "$fmt"` in post_tool_use cannot run injected metacharacters from
# a filename. Drive the helper with a malicious-shaped path; eval its
# output against a fake `ruff` shim; assert the side-effect didn't fire.
. "$SHELL_ROOT/.claude/hooks/helpers/detect_stack.sh"

FMT_SAFETY_DIR=$(mktemp -d)
RUFF_SHIM_DIR="$FMT_SAFETY_DIR/bin"
SENTINEL="$FMT_SAFETY_DIR/pwned"
mkdir -p "$RUFF_SHIM_DIR"
cat > "$RUFF_SHIM_DIR/ruff" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$RUFF_SHIM_DIR/ruff"

# 19a. metacharacter-laden filename ending in .py (so the case pattern
# matches and detect_format_cmd returns a command). Without quoting the
# `;` would chain a touch under eval. The fix shell-quotes the path.
(
  export PATH="$RUFF_SHIM_DIR:$PATH"
  malicious="legit; touch $SENTINEL .py"
  fmt=$(detect_format_cmd "$malicious")
  [ -n "$fmt" ] || exit 1
  eval "$fmt" >/dev/null 2>&1 || true
  [ ! -e "$SENTINEL" ]
) && ok "format: metacharacter filename does not exec injected side effect (#25)" \
   || ng "format: filename injection slipped through (#25)"

# 19b. benign filename still resolves correctly through the helper.
(
  export PATH="$RUFF_SHIM_DIR:$PATH"
  fmt=$(detect_format_cmd "clean.py")
  case "$fmt" in *ruff*clean.py*) exit 0 ;; *) exit 1 ;; esac
) && ok "format: benign filename still produces expected command (#25)" \
   || ng "format: benign filename regression (#25)"

rm -rf "$FMT_SAFETY_DIR"

# ---------- 18. destructive-arg parsing (#27) ----------
# check_destructive_args must:
# - Honor quotes in the cmd string (no IFS word-split through quoted paths).
# - Not pathname-expand globs (literal `*` stays literal).
# - Route bare relative names through path_in_scope.
#
# hook_run cd's into $TMP/fake (#41); both $TMP/fake and SHELL_ROOT are
# registered, so any path under either is in-scope and any absolute path
# outside both is out-of-scope (modulo other registered targets, which
# the smoke test isolates by stashing the registry at start).

# 18a. quoted absolute path with spaces, out of scope → block.
quoted_space='rm -rf "/var/tmp/My Photos"'
exit_code=$(hook_run "$quoted_space")
if [ "$exit_code" = "2" ]; then
  ok "destructive: quoted out-of-scope path with spaces blocked (#27)"
else
  ng "destructive: quoted out-of-scope path should block, exit=$exit_code (#27)"
fi

# 18b. bare relative name → resolved against PWD ($TMP/fake, in registry) → in scope → allow.
relative_in='rm -rf workspace'
exit_code=$(hook_run "$relative_in")
if [ "$exit_code" = "0" ]; then
  ok "destructive: bare relative in-scope (PWD=\$TMP/fake) allowed (#27)"
else
  ng "destructive: bare relative in-scope should pass, exit=$exit_code (#27)"
fi

# §27m (#505 / Directive #498): a FLAGLESS `mv`/`cp` whose DEST is out-of-registry
# clobbers outside scope, yet the destructive prefilter required a force/recursive
# flag to enter — so flagless `mv in /out` slipped past. Gate flagless mv/cp too.
[ "$(hook_run 'mv ./workspace /var/tmp/ce-out')" = "2" ] \
  && ok "27m: flagless mv to out-of-scope dest blocked (#505)" \
  || ng "27m: flagless mv to out-of-scope dest not gated (clobber bypass) (#505)"
[ "$(hook_run 'cp ./workspace /var/tmp/ce-out')" = "2" ] \
  && ok "27m2: flagless cp to out-of-scope dest blocked (#505)" \
  || ng "27m2: flagless cp to out-of-scope dest not gated (#505)"
[ "$(hook_run 'mv ./a ./b')" = "0" ] \
  && ok "27m3: flagless mv within registry allowed (no over-block) (#505)" \
  || ng "27m3: flagless in-scope mv wrongly blocked (#505)"
# unforced single-operand rm must STILL be allowed (the #212 design — only mv/cp
# gain the flagless dest-check, not rm).
[ "$(hook_run 'rm ./workspace')" = "0" ] \
  && ok "27m4: unforced single rm still not gated (no #212 regression) (#505)" \
  || ng "27m4: unforced rm wrongly gated — #212 regression (#505)"

# §505s (#505): documented-residual locks. (a) .shellsecretignore must state the
# scanner has NO coverage on its whitelisted paths (operators must not assume it);
# (b) SPEC §6.1 must document the destructive find/truncate/redirect residuals.
if grep -qiE 'not (scanned|covered)|no(t| ) coverage|scanner (is )?off' "$SHELL_ROOT/.shellsecretignore" 2>/dev/null; then
  ok "505s: .shellsecretignore documents the no-coverage caveat (#505)"
else
  ng "505s: .shellsecretignore lacks the explicit no-coverage caveat (#505)"
fi
if grep -qiE '(-delete|truncate|redirect)[^#]*#505|#505[^#]*(-delete|truncate|redirect)' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "505s2: SPEC §6.1 documents the destructive find/truncate/redirect residuals (#505)"
else
  ng "505s2: SPEC does not document the destructive residuals (#505)"
fi

# 18c. `../` relative escape from $TMP/fake → out of scope → block.
relative_escape='rm -rf ../etc/passwd'
exit_code=$(hook_run "$relative_escape")
if [ "$exit_code" = "2" ]; then
  ok "destructive: ../ relative escape blocks (#27)"
else
  ng "destructive: ../ escape should block, exit=$exit_code (#27)"
fi

# 18d. unclosed quote → shlex ValueError → fail closed (block). Without this,
# the matcher would emit zero tokens and silently allow the command.
unclosed='rm -rf "/var/tmp/leak'
exit_code=$(hook_run "$unclosed")
if [ "$exit_code" = "2" ]; then
  ok "destructive: unclosed quote fails closed (block) (#27)"
else
  ng "destructive: unclosed quote should fail closed, exit=$exit_code (#27)"
fi

# 18e. `env VAR=value rm -rf <oos>` — env is in the skip list; VAR=value
# isn't a flag and is treated as a (corrupted-looking) bare relative path
# routed through path_in_scope. Either way the trailing OOS path must still
# block the whole command.
env_form='env CLAUDE_TEST=1 rm -rf /var/tmp/from-env'
exit_code=$(hook_run "$env_form")
if [ "$exit_code" = "2" ]; then
  ok "destructive: env-prefixed form still blocks OOS path (#27)"
else
  ng "destructive: env-prefixed form should block OOS, exit=$exit_code (#27)"
fi

# ---------- 17. lint timeout (#29) ----------
# SPEC §6.1: commit-time lint is bounded by GHJIG_LINT_TIMEOUT (default 30s).
# The helper run_bounded_lint runs the lint cmd via `timeout(1)` so a slow lint
# cannot hang the commit. If neither `timeout` nor `gtimeout` is on PATH, the
# helper falls back to unbounded run + audit_log warn (documented in SPEC).

if command -v run_bounded_lint >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    # 17a. slow lint terminated by timeout within window.
    start=$SECONDS
    GHJIG_LINT_TIMEOUT=1 run_bounded_lint "sleep 5" >/dev/null 2>&1
    rc=$?
    elapsed=$((SECONDS - start))
    if [ "$rc" != "0" ] && [ "$elapsed" -le 3 ]; then
      ok "lint: bounded run terminates slow lint within window (rc=$rc, ${elapsed}s) (#29)"
    else
      ng "lint: slow lint not bounded (rc=$rc, ${elapsed}s) (#29)"
    fi

    # 17b. fast lint within timeout still passes.
    if GHJIG_LINT_TIMEOUT=5 run_bounded_lint "true" >/dev/null 2>&1; then
      ok "lint: fast command within timeout passes (#29)"
    else
      ng "lint: fast command incorrectly failed (#29)"
    fi

    # 17c. failing lint within timeout returns non-zero.
    if GHJIG_LINT_TIMEOUT=5 run_bounded_lint "false" >/dev/null 2>&1; then
      ng "lint: failing command should return non-zero (#29)"
    else
      ok "lint: failing command returns non-zero (#29)"
    fi
  else
    ok "lint: timeout test skipped — neither timeout nor gtimeout on PATH"
  fi
else
  ng "lint: run_bounded_lint helper missing (#29)"
fi

# ---------- 36. protected-branch SSOT (#16) ----------
# Single source of truth for SPEC §6.1 protected-branch policy lives in
# helpers/git_matcher.sh. Drift would silently weaken enforcement. Two
# checks:
#   36a (positive): the two constants are defined and the ERE matches the
#       expected set (main / master / release/foo) while rejecting near-
#       misses (mainframe, feature/main).
#   36b (drift-lock): the literal three-token alternation `main|master|release`
#       must not appear in any *.sh file under .claude/hooks/ except for
#       git_matcher.sh itself. Deny-list scan — any new enforcement file
#       under hooks/ that copy-pastes the literal is caught automatically,
#       no allow-list update required.
#       Implementation note: the grep pattern uses BRE-escaped pipes
#       (`main\|master\|release`) so smoke.sh's own source — which contains
#       these literal grep strings — does NOT self-match the unescaped
#       `main|master|release` form that lives only in git_matcher.sh.
#       DO NOT change `\|` to `|` here or the test will self-match and
#       silently always pass.
( . "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
  fail36a=0
  [ -n "${PROTECTED_BRANCH_PATTERN:-}" ] || fail36a=1
  # ERE form must match the expected positives.
  for b in main master release/foo release/2026-q2; do
    printf '%s' "$b" | grep -qE "^(${PROTECTED_BRANCH_PATTERN})$" || fail36a=1
  done
  # ERE form must reject substring near-misses.
  for b in mainframe master-key feature/main release; do
    printf '%s' "$b" | grep -qE "^(${PROTECTED_BRANCH_PATTERN})$" && fail36a=1
  done
  if [ "$fail36a" = 0 ]; then
    ok "protected-ssot: PROTECTED_BRANCH_PATTERN matches expected set (#16)"
  else
    ng "protected-ssot: PROTECTED_BRANCH_PATTERN definition/behavior broken (#16)"
  fi
)

# 36b: deny-list scan. Any *.sh file under .claude/hooks/ (recursive) that
# is not git_matcher.sh itself and still carries the literal three-token
# alternation `main|master|release` is drift. Switching from an explicit
# allow-list to a deny-list closes the false-negative gap where a new
# enforcement gate added to e.g. post_tool_use.sh could silently copy-paste
# the literal and escape detection.
drift=$(find "$SHELL_ROOT/.claude/hooks" -type f -name '*.sh' \
        ! -path '*/git_matcher.sh' \
        -exec grep -lE 'main\|master\|release' {} + 2>/dev/null \
       | sed "s|^$SHELL_ROOT/||" | tr '\n' ' ')
if ! grep -qE 'main\|master\|release' \
     "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"; then
  ng "protected-ssot: pattern absent from git_matcher.sh (constant gone?) (#16)"
elif [ -n "${drift% }" ]; then
  ng "protected-ssot: literal pattern found outside git_matcher.sh: ${drift% } (#16)"
else
  ok "protected-ssot: literal pattern centralized in git_matcher.sh (#16)"
fi

# ---------- 35. config-toggle env-var catalog SSOT (#15, relocated #296) ----------
# The "Configuration toggles" table in docs/CONFIG.md is the user-facing
# catalog for env vars per SPEC §1.3 (relocated from README.md in #296 to
# keep the README front-door lean). Every env var documented elsewhere in
# the shell must also appear in the table. A missing row is the same drift
# class as a missing SPEC TOC entry (§28). Mirrors the §27 multi-target loop.
CONFIG_MD="$SHELL_ROOT/docs/CONFIG.md"
if [ -f "$CONFIG_MD" ]; then
  missing=""
  for v in SESSION_START_FETCH_TIMEOUT SESSION_START_FRICTION_TTL SESSION_START_FRICTION_TIMEOUT GHJIG_STOP_THROTTLE SHIP_PARK_LOG_PATH PR_CACHE_REPO; do
    if ! grep -q "$v" "$CONFIG_MD"; then
      missing="$missing $v"
    fi
  done
  if [ -z "$missing" ]; then
    ok "config-toggles: all env vars documented in docs/CONFIG.md (#15, #398)"
  else
    ng "config-toggles: env vars missing from docs/CONFIG.md catalog:$missing (#15)"
  fi
else
  ng "config-toggles: docs/CONFIG.md not found at $CONFIG_MD (#15)"
fi

# ---------- 37. SessionStart inject-consistency banner REMOVED (#318) ----------
# The inject-consistency banner was REMOVED in #318 (Directive #311). Post-#312 a
# plain `claude` in an injected target (settings.local.json symlink + env unset)
# is the NORMAL working state — hooks self-locate via the binding symlink and
# session_start.sh back-fills the env — so the banner only false-fired. And the
# residual genuine no-op (broken binding) is structurally undetectable from
# SessionStart: the hook command itself traverses the binding, so a broken
# binding means session_start.sh never runs and the banner inside it can't fire.
# So: the banner must NOT appear in any state, and the emitting code must be gone.
SESS_37_DIR=$(mktemp -d)
SESS_37_SHELL="$SESS_37_DIR/shell"
SESS_37_TARGET="$SESS_37_DIR/target"
mkdir -p "$SESS_37_SHELL/.claude" "$SESS_37_TARGET/.claude"
touch "$SESS_37_SHELL/.claude/settings.json"
# Mirror inject_into's symlink: target/.claude/settings.local.json → shell/.claude/settings.json
ln -sfn "$SESS_37_SHELL/.claude/settings.json" "$SESS_37_TARGET/.claude/settings.local.json"

SESS_37_TMP="$SESS_37_DIR/tmp"; mkdir -p "$SESS_37_TMP"

run_37_session_start() {
  local cwd="$1"
  (
    unset GHJIG_ROOT_OVERRIDE GHJIG_ROOT
    export TMPDIR="$SESS_37_TMP"
    export CLAUDE_SESSION_ID="smoke37"
    cd "$cwd" || exit 1
    # shellcheck disable=SC2069
    bash "$SHELL_ROOT/.claude/hooks/session_start.sh" 2>&1 >/dev/null
  )
}

# 37a (runtime): the former false-positive state (symlink + env unset) must now
# emit NO inject-consistency banner. Anti-vacuity: 37b proves session_start.sh
# still runs (the banner block is gone from source, not silenced by a crash).
out37a=$(run_37_session_start "$SESS_37_TARGET")
if printf '%s' "$out37a" | grep -q 'inject-consistency'; then
  ng "37: inject-consistency banner should be removed but still fires (#318)"
else
  ok "37: no inject-consistency banner in normal env-unset+injected state (removed, #318)"
fi

# 37b (source): the emitting code is gone from session_start.sh (not merely
# token-silenced). Greps the printf payload `WARN inject-consistency`, so a
# removal comment mentioning the bare token doesn't vacuously pass.
if grep -q 'WARN inject-consistency' "$SHELL_ROOT/.claude/hooks/session_start.sh"; then
  ng "37: session_start.sh still emits the inject-consistency banner (#318)"
else
  ok "37: inject-consistency banner code removed from session_start.sh (#318)"
fi

rm -rf "$SESS_37_DIR"

# ---------- 38. gh pr merge AC closeout gate (#29) ----------
# PreToolUse blocks `gh pr merge` when any issue in the PR's
# closingIssuesReferences has unchecked AC items AND no comment with a
# `^## AC closeout` header is present. Tests use a gh shim on PATH so
# the matcher's gh queries return canned JSON without network. Mirrors
# the §11h shim pattern.
GH38_DIR=$(mktemp -d)
GH38_SHIM="$GH38_DIR/bin"
GH38_STATE="$GH38_DIR/state"
mkdir -p "$GH38_SHIM" "$GH38_STATE"

cat > "$GH38_SHIM/gh" <<'SHIM'
#!/bin/sh
case "$*" in
  *"pr view"*headRefOid*) echo smoke-attest-head ;;  # #586 merge-review head-pin match
  *"api"*"/reviews"*)            printf '[{"state":"APPROVED","commit_id":"smoke-attest-head","submitted_at":"2020-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"lgtm"}]\n' ;;  # #586 native APPROVED@head → merge-review allows
  *"repo view"*"nameWithOwner"*) echo o/r ;;  # #586 merge-review owner/repo
  *"pr view"*"closingIssuesReferences"*)
    # #500: branch on the PR number in the query so a URL-resolved PR (777) and
    # the current-branch fallback PR (5) return DIFFERENT linked issues — needed
    # to observe the extract_pr_from_merge_cmd URL-divergence fix. Uses 777 (NOT
    # the 200 the existing §38a-e/§31/§499 cases use) so those fall through to the
    # flat pr_issues file unchanged.
    case "$*" in
      *" 777 "*|*"pull/777"*) cat "$GH_SHIM_STATE/pr_issues_777" 2>/dev/null ;;
      *) cat "$GH_SHIM_STATE/pr_issues" 2>/dev/null ;;
    esac
    ;;
  *"pr view"*"--json number"*)
    cat "$GH_SHIM_STATE/pr_number" 2>/dev/null
    ;;
  *"issue view"*"--json body"*)
    cat "$GH_SHIM_STATE/issue_body" 2>/dev/null
    ;;
  *"issue view"*"--json comments"*)
    # #500: when the gate's query filters comments by authorAssociation (the
    # trusted-author marker fix), serve the trusted-only file; otherwise (the
    # pre-fix `.comments[].body` query) serve the flat file. This models the
    # gh-side jq select that the shell mock cannot itself execute.
    case "$*" in
      *authorAssociation*) cat "$GH_SHIM_STATE/issue_comments_trusted" 2>/dev/null ;;
      *) cat "$GH_SHIM_STATE/issue_comments" 2>/dev/null ;;
    esac
    ;;
  *"issue comment"*)
    : "${GH_SHIM_STATE:?}"
    echo "post" >> "$GH_SHIM_STATE/post_log"
    cat >> "$GH_SHIM_STATE/posted_body" 2>/dev/null
    ;;
esac
exit 0
SHIM
chmod +x "$GH38_SHIM/gh"

# Run the PreToolUse hook with $cmd as the Bash tool_input.command.
# cd into $TMP/fake (already in the smoke registry via §4 inject_into)
# so the hook's `in_scope` guard passes. Captures hook stderr via the
# 2>&1 >/dev/null swap; returns the hook's exit code (pipefail).
gh38_run() {
  local cmd="$1"
  (
    cd "$TMP/fake" || exit 1
    # shellcheck disable=SC2069  # intentional: swap stderr → captured pipe, discard stdout
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | jq -Rs .)" \
      | PATH="$GH38_SHIM:$PATH" \
        GH_SHIM_STATE="$GH38_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1 >/dev/null
  )
}

# Helper to reset the shim state between sub-cases.
gh38_reset() {
  rm -f "$GH38_STATE"/pr_issues "$GH38_STATE"/pr_number \
        "$GH38_STATE"/issue_body "$GH38_STATE"/issue_comments \
        "$GH38_STATE"/issue_comments_trusted "$GH38_STATE"/pr_issues_777 \
        "$GH38_STATE"/post_log "$GH38_STATE"/posted_body
}

# 38a: positive block — linked issue with unchecked AC, no closeout marker.
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n- [x] already done\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"
out38a=$(gh38_run "gh pr merge 200 --merge")
rc38a=$?
if [ "$rc38a" = 2 ] && printf '%s' "$out38a" | grep -q 'ac-closeout'; then
  ok "ac-closeout: blocks gh pr merge when AC unchecked + no marker (#29)"
else
  ng "ac-closeout: should have blocked (rc=$rc38a) (#29)"
fi

# 38b: allow when the canonical `## AC closeout (resolved by PR #N)` marker
# comment already exists. #500: the gate now requires the marker from a TRUSTED
# author, so the trusted-filtered comment set must also carry it (the mock serves
# issue_comments_trusted for the authorAssociation-filtered query).
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
printf '## AC closeout (resolved by PR #200)\nbody...\n' > "$GH38_STATE/issue_comments"
printf '## AC closeout (resolved by PR #200)\n' > "$GH38_STATE/issue_comments_trusted"
out38b=$(gh38_run "gh pr merge 200 --merge")
rc38b=$?
if [ "$rc38b" = 0 ]; then
  ok "ac-closeout: allows merge when closeout marker present (#29)"
else
  ng "ac-closeout: should have allowed when marker present (rc=$rc38b: $out38b) (#29)"
fi

# 38c: allow when linked issue has no `- [ ]` AC items (all ticked / N/A).
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [x] done\n- [~] N/A — reason\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"
out38c=$(gh38_run "gh pr merge 200 --merge")
rc38c=$?
if [ "$rc38c" = 0 ]; then
  ok "ac-closeout: allows merge when issue has no unchecked AC (#29)"
else
  ng "ac-closeout: should have allowed on no-AC (rc=$rc38c: $out38c) (#29)"
fi

# 38d: SKIP_HOOKS=ac-closeout escape — must allow and audit-log.
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"
REAL_AUDIT="$SMOKE_AUDIT"
audit_before=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' ' || echo 0)
gh38_run "SKIP_HOOKS=ac-closeout SKIP_REASON='emergency' gh pr merge 200 --merge" >/dev/null
rc38d=$?
audit_after=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' ' || echo 0)
if [ "$rc38d" = 0 ] && [ "$audit_after" -gt "$audit_before" ] \
   && tail -1 "$REAL_AUDIT" 2>/dev/null | grep -q 'ac-closeout'; then
  ok "ac-closeout: SKIP_HOOKS=ac-closeout allows merge + audit-logged (#29)"
else
  ng "ac-closeout: SKIP_HOOKS=ac-closeout failed (rc=$rc38d, audit_before=$audit_before, audit_after=$audit_after) (#29)"
fi

# 38e: PR with no closingIssuesReferences (no linked issue) → allow.
gh38_reset
: > "$GH38_STATE/pr_issues"  # empty list
out38e=$(gh38_run "gh pr merge 200 --merge")
rc38e=$?
if [ "$rc38e" = 0 ]; then
  ok "ac-closeout: allows merge when PR has no linked issues (#29)"
else
  ng "ac-closeout: should have allowed when no closingIssuesReferences (rc=$rc38e: $out38e) (#29)"
fi

# 38f: helper idempotency — scripts/ac_closeout.sh posts once, then skips.
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n- [ ] another\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"
(
  export GH_SHIM_STATE="$GH38_STATE"
  export PATH="$GH38_SHIM:$PATH"
  "$SHELL_ROOT/scripts/ac_closeout.sh" 200 >/dev/null 2>&1
)
posts1=$(wc -l < "$GH38_STATE/post_log" 2>/dev/null | tr -d ' ' || echo 0)
# Now simulate the marker being present (helper would have posted it). #556:
# the remedy's skip guard now reads TRUSTED-author comments (the mock serves
# issue_comments_trusted for the authorAssociation-filtered query), mirroring
# the gate — so the posted marker must land in the trusted file too.
printf '## AC closeout (resolved by PR #200)\nbody...\n' > "$GH38_STATE/issue_comments"
printf '## AC closeout (resolved by PR #200)\n' > "$GH38_STATE/issue_comments_trusted"
(
  export GH_SHIM_STATE="$GH38_STATE"
  export PATH="$GH38_SHIM:$PATH"
  "$SHELL_ROOT/scripts/ac_closeout.sh" 200 >/dev/null 2>&1
)
posts2=$(wc -l < "$GH38_STATE/post_log" 2>/dev/null | tr -d ' ' || echo 0)
if [ "$posts1" -ge 1 ] && [ "$posts2" = "$posts1" ]; then
  ok "ac-closeout: helper idempotent (first run posts, second skips) (#29)"
else
  ng "ac-closeout: helper not idempotent (posts1=$posts1, posts2=$posts2) (#29)"
fi

# 556a (#556 C2): deadlock guard — a lookalike / untrusted `## AC closeout`
# comment must NOT make the remedy skip while the gate keeps blocking. The
# gate reads only TRUSTED-author comments with the strict `(resolved by PR #N)`
# shape; the remedy MUST mirror that. Fixture: an untrusted lookalike sits in
# the flat comment file, but the trusted-author file is EMPTY → the remedy must
# still post (not skip). Pre-fix (loose author-unfiltered `^## AC closeout`
# grep on the flat file) the remedy would SKIP → 0 posts → deadlock.
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
printf '## AC closeout (resolved by PR #200)\ndrive-by lookalike\n' > "$GH38_STATE/issue_comments"
: > "$GH38_STATE/issue_comments_trusted"   # no trusted marker present
(
  export GH_SHIM_STATE="$GH38_STATE"
  export PATH="$GH38_SHIM:$PATH"
  "$SHELL_ROOT/scripts/ac_closeout.sh" 200 >/dev/null 2>&1
)
posts556a=$(wc -l < "$GH38_STATE/post_log" 2>/dev/null | tr -d ' ' || echo 0)
if [ "$posts556a" -ge 1 ]; then
  ok "ac-closeout: remedy posts despite untrusted lookalike (no deadlock) (#556)"
else
  ng "ac-closeout: remedy skipped on untrusted lookalike → gate-deadlock (posts=$posts556a) (#556)"
fi

# 556b (#556 C1): @mentions in re-emitted AC lines are neutralized (no re-ping).
# Fixture: an unchecked AC line carries a bare `@someuser`. No trusted marker →
# remedy posts. The posted body must NOT contain the bare `@someuser` mention
# (a zero-width space is inserted after `@`). Pre-fix the line is refiled
# verbatim → the bare mention survives → GitHub re-pings.
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] ping @someuser about the thing\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"
: > "$GH38_STATE/issue_comments_trusted"
(
  export GH_SHIM_STATE="$GH38_STATE"
  export PATH="$GH38_SHIM:$PATH"
  "$SHELL_ROOT/scripts/ac_closeout.sh" 200 >/dev/null 2>&1
)
posts556b=$(wc -l < "$GH38_STATE/post_log" 2>/dev/null | tr -d ' ' || echo 0)
if [ "$posts556b" -ge 1 ] \
   && ! grep -q '@someuser' "$GH38_STATE/posted_body" 2>/dev/null \
   && grep -q 'someuser' "$GH38_STATE/posted_body" 2>/dev/null; then
  ok "ac-closeout: re-emitted AC @mentions neutralized (no re-ping) (#556)"
else
  ng "ac-closeout: @mention survived refile (posts=$posts556b, bare mention present) (#556)"
fi

# 38g: command-shape regression (#31) — matcher + extractor / fallback
# must handle the live dogfood-failing form and four common variants.
# The failure on PR #30 used the piped form; lock all five against
# future matcher drift.
gh38_g_shapes=(
  "gh pr merge 200 --merge --delete-branch 2>&1 | tail -3"
  "gh pr merge 200 --merge | tail -1"
  "gh pr merge 200 --merge > /tmp/out"
  "cd /tmp && gh pr merge 200 --merge"
  "gh pr merge 200 --merge; echo done"
)
shape_fails=0
shape_miss_log=""
for shape in "${gh38_g_shapes[@]}"; do
  gh38_reset
  printf '100\n' > "$GH38_STATE/pr_issues"
  printf '200\n' > "$GH38_STATE/pr_number"
  printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
  : > "$GH38_STATE/issue_comments"
  shape_out=$(gh38_run "$shape")
  shape_rc=$?
  if [ "$shape_rc" != 2 ] || ! printf '%s' "$shape_out" | grep -q 'ac-closeout'; then
    shape_fails=$((shape_fails + 1))
    shape_miss_log="$shape_miss_log
  miss: rc=$shape_rc cmd='$shape' out=$shape_out"
  fi
done
if [ "$shape_fails" = 0 ]; then
  ok "ac-closeout: blocks all 5 command-shape variants (piped/redirect/prepend/sep) (#31)"
else
  ng "ac-closeout: $shape_fails/5 command shapes failed to block (#31)$shape_miss_log"
fi

# 38h: safe_source helper-missing audit-warn — parameterized over every
# hook-sourced helper (#34). Generalizes the original §38h ac-closeout
# dogfood reproduction (#31) to every helper sourced by the 5 hook files,
# locking in the contract from the SPEC §6.1 fail-policy table:
# safe_source emits `audit_log warn <category> helper-missing` and the
# hook fail-opens (rc=0) when the helper file is absent.
#
# #586 EXCEPTION: `ac_closeout_gate.sh` is shared by the `merge-review` arm,
# which is the deliberate fail-CLOSED exception in the §6.1 fail-policy table
# (SPEC §1732) — a helper miss there BLOCKS (rc=2), not fail-open. Its expected
# rc is therefore 2. The `ac-closeout` arm still emits its own helper-missing
# warn first (it fail-opens), so category=ac-closeout / decision=helper-missing
# stays in the tail; only the terminal rc differs (merge-review blocks after).
#
# Each iteration: move the helper aside (trap-protected), invoke the
# right hook with a benign input, assert (a) rc matches the row's expected
# rc (0, or 2 for the fail-closed merge-review-sharing helper), (b) audit.jsonl
# grew, (c) the new tail contains both the expected category and the
# `helper-missing` token. Restore immediately so a later assertion
# failure doesn't leave the live helper missing.
#
# hookrt.sh and helpers/log.sh are excluded:
#   - hookrt.sh is the primitive bootstrap; its absence is stderr-only
#     by design (cannot audit-log itself).
#   - helpers/log.sh is a compatibility shim after #34; no hook
#     safe-sources it (audit_log comes from hookrt.sh directly).

REAL_AUDIT_38H="$SMOKE_AUDIT"

# (helper-basename, expected category, hook-script, stdin-cmd-or-prompt)
# Tuples are colon-separated. For pre_tool_use the 4th field is the
# tool_input.command; for user_prompt_submit it's the user prompt text.
SS_TABLE=(
  "escape.sh:escape:pre_tool_use.sh:echo benign"
  "cwd_guard.sh:out-of-scope:pre_tool_use.sh:echo benign"
  "detect_stack.sh:format:pre_tool_use.sh:echo benign"
  "branch_guard.sh:branch:pre_tool_use.sh:echo benign"
  "conventional_commit.sh:commit-format:pre_tool_use.sh:echo benign"
  "secret_scan.sh:secret:pre_tool_use.sh:echo benign"
  "git_matcher.sh:commit-format:pre_tool_use.sh:echo benign"
  "ac_closeout_gate.sh:ac-closeout:pre_tool_use.sh:gh pr merge 200 --merge"
  "status.sh:status:user_prompt_submit.sh:hello"
)

# Trap-protected restore covering whichever helper is currently aside.
SS_CUR_PATH=""
SS_CUR_BAK=""
ss38h_restore() {
  if [ -n "$SS_CUR_PATH" ] && [ -n "$SS_CUR_BAK" ] \
     && [ ! -f "$SS_CUR_PATH" ] && [ -f "$SS_CUR_BAK" ]; then
    mv "$SS_CUR_BAK" "$SS_CUR_PATH"
  fi
}
trap 'ss38h_restore' EXIT INT TERM

# Loop:
for entry in "${SS_TABLE[@]}"; do
  IFS=':' read -r ss_helper ss_cat ss_hook ss_payload <<< "$entry"
  ss_path="$SHELL_ROOT/.claude/hooks/helpers/$ss_helper"
  ss_bak="$GH38_DIR/${ss_helper}.bak"
  SS_CUR_PATH="$ss_path"
  SS_CUR_BAK="$ss_bak"

  if [ ! -f "$ss_path" ]; then
    ng "safe_source: helper file not present in repo [$ss_helper] (#34)"
    SS_CUR_PATH=""; SS_CUR_BAK=""
    continue
  fi

  # Fresh §38 fixture state per iteration (relevant for ac-closeout path).
  gh38_reset
  printf '100\n' > "$GH38_STATE/pr_issues"
  printf '200\n' > "$GH38_STATE/pr_number"
  printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
  : > "$GH38_STATE/issue_comments"

  mv "$ss_path" "$ss_bak"
  ss_before=$(wc -l < "$REAL_AUDIT_38H" 2>/dev/null | tr -d ' ' || echo 0)

  case "$ss_hook" in
    pre_tool_use.sh)
      ss_input=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(printf '%s' "$ss_payload" | jq -Rs .)")
      (
        cd "$TMP/fake" || exit 0
        # shellcheck disable=SC2069
        printf '%s' "$ss_input" \
          | PATH="$GH38_SHIM:$PATH" \
            GH_SHIM_STATE="$GH38_STATE" \
            GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
            bash "$SHELL_ROOT/.claude/hooks/$ss_hook" 2>&1 >/dev/null
      )
      ss_rc=$?
      ;;
    user_prompt_submit.sh)
      ss_input=$(printf '{"prompt":%s}' \
        "$(printf '%s' "$ss_payload" | jq -Rs .)")
      (
        cd "$TMP/fake" || exit 0
        # shellcheck disable=SC2069
        printf '%s' "$ss_input" \
          | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
            bash "$SHELL_ROOT/.claude/hooks/$ss_hook" 2>&1 >/dev/null
      )
      ss_rc=$?
      ;;
    *)
      ng "safe_source: unknown hook in test table [$ss_hook] (#34)"
      mv "$ss_bak" "$ss_path"
      SS_CUR_PATH=""; SS_CUR_BAK=""
      continue
      ;;
  esac

  ss_after=$(wc -l < "$REAL_AUDIT_38H" 2>/dev/null | tr -d ' ' || echo 0)
  ss_new=$(( ss_after - ss_before ))
  ss_tail=""
  if [ "$ss_new" -gt 0 ]; then
    ss_tail=$(tail -"$ss_new" "$REAL_AUDIT_38H" 2>/dev/null)
  fi

  # Restore the helper IMMEDIATELY (before the assertion) so an assertion
  # failure doesn't leave the suite running without the live helper.
  mv "$ss_bak" "$ss_path"
  SS_CUR_PATH=""
  SS_CUR_BAK=""

  # Expected terminal rc: fail-open (0) for every helper EXCEPT ac_closeout_gate.sh,
  # which the fail-CLOSED merge-review arm also sources (#586, SPEC §1732) → rc=2.
  ss_exp_rc=0
  [ "$ss_helper" = ac_closeout_gate.sh ] && ss_exp_rc=2

  # Core contract: rc matches expected + audit grew + category + decision tokens.
  ss_ok=0
  if [ "$ss_rc" = "$ss_exp_rc" ] \
     && [ "$ss_new" -ge 1 ] \
     && printf '%s' "$ss_tail" | grep -q "\"category\":\"$ss_cat\"" \
     && printf '%s' "$ss_tail" | grep -q '"decision":"helper-missing"'; then
    ss_ok=1
  fi

  # Security-relevant suffix contract (SPEC §6.1): the warn carries
  # "NOT ENFORCED (security-relevant)" for secret + branch categories,
  # and MUST NOT carry it for any other category. Mismatch is treated as
  # a hard fail of this iteration — the SPEC affordance exists specifically
  # to draw operator attention.
  case "$ss_cat" in
    secret|branch)
      printf '%s' "$ss_tail" | grep -q 'NOT ENFORCED' || ss_ok=0
      ;;
    *)
      printf '%s' "$ss_tail" | grep -q 'NOT ENFORCED' && ss_ok=0
      ;;
  esac

  if [ "$ss_ok" = 1 ]; then
    ok "safe_source: $ss_helper missing → warn ($ss_cat) emitted (#34)"
  else
    ng "safe_source: $ss_helper missing — expected rc=$ss_exp_rc category=$ss_cat decision=helper-missing (security-suffix per §6.1); got rc=$ss_rc new=$ss_new tail=$ss_tail (#34)"
  fi
done

trap - EXIT INT TERM

# 38j (#213): the secret-scan CALL must FAIL-OPEN when secret_scan.sh is missing.
# 38h proves safe_source warns on miss, but it uses an `echo` payload that never
# reaches the scan_staged_secrets call. The real bug is at the call site: a
# `git commit` with scan_staged_secrets undefined hit `command not found` and
# BLOCKED (fail-closed), forcing SKIP_HOOKS=secret on every commit. Move the
# helper aside and run a VALID commit on the non-protected fake branch — it must
# NOT be blocked (fail-open per the §6.1 fail-policy table). Trap-protected.
s213_path="$SHELL_ROOT/.claude/hooks/helpers/secret_scan.sh"
s213_bak=$(mktemp -u)
s213_restore() { [ -f "$s213_bak" ] && [ ! -f "$s213_path" ] && mv "$s213_bak" "$s213_path"; }
trap 's213_restore' EXIT INT TERM
if [ -f "$s213_path" ]; then
  mv "$s213_path" "$s213_bak"
  s213_rc=$(hook_run 'git commit -m "feat(#1): valid subject"')
  s213_restore
  trap - EXIT INT TERM
  if [ "$s213_rc" = 0 ]; then
    ok "38j: secret-scan call fails open when secret_scan.sh is missing (valid commit not blocked) (#213)"
  else
    ng "38j: secret-scan call fails CLOSED on missing helper (rc=$s213_rc, expected 0) (#213)"
  fi
else
  ng "38j: secret_scan.sh not present in repo (#213)"
fi

# 38i: top-level placement assertion (#34) — safe_source calls must not
# live inside a function body in pre_tool_use.sh. The in-function source
# of git_matcher.sh at the pre-#34 pre_tool_use.sh:79 was a historical
# accident; #34 moves it to top-level. This grep-based check catches a
# future regression of the same shape (any safe_source call indented
# inside a `name() { ... }` block).
ss_inside=$(awk '
  /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{?[[:space:]]*$/ { in_func=1; depth=1; next }
  in_func {
    n_open  = gsub(/\{/, "{")
    n_close = gsub(/\}/, "}")
    depth += n_open - n_close
    if (depth <= 0) { in_func=0; next }
    if ($0 ~ /[[:space:]]safe_source[[:space:]]/) print FILENAME ":" NR ": " $0
  }
' "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh")
if [ -z "$ss_inside" ]; then
  ok "safe_source: no in-function placement in pre_tool_use.sh (#34)"
else
  ng "safe_source: in-function placement found (regression of #34): $ss_inside"
fi

# 38j: helper-to-helper safe_source dual-warn (#36) — when git_matcher.sh
# is missing, BOTH source-sites in a single pre_tool_use invocation must
# emit a helper-missing warn: the hook-level safe_source at
# pre_tool_use.sh:26 AND branch_guard.sh's internal safe_source of
# git_matcher.sh (added by #36). Exactly two warns mentioning the
# git_matcher.sh basename in the freshly grown audit window.
#
# This is the structural enforcer of the SPEC §6.1 invariant after #36:
# helper-to-helper sources go through safe_source, so missing helpers
# warn from every site that needed them, not just the hook-level site.
# Pre-#36, the §38h floor (ss_new >= 1) saw 1 (only the hook-level
# warn); branch_guard.sh's plain `.` failed silently. Post-#36, both
# fire and the count is 2.

REAL_AUDIT_38J="$SMOKE_AUDIT"
SS38J_PATH="$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
SS38J_BAK="$GH38_DIR/git_matcher.sh.bak.38j"

ss38j_restore() {
  if [ -n "${SS38J_BAK:-}" ] && [ -f "$SS38J_BAK" ] && [ ! -f "$SS38J_PATH" ]; then
    mv "$SS38J_BAK" "$SS38J_PATH"
  fi
}
trap 'ss38j_restore' EXIT INT TERM

if [ ! -f "$SS38J_PATH" ]; then
  ng "38j: helper file not present in repo [git_matcher.sh] (#36)"
else
  gh38_reset
  mv "$SS38J_PATH" "$SS38J_BAK"
  ss38j_before=$(wc -l < "$REAL_AUDIT_38J" 2>/dev/null | tr -d ' ' || echo 0)

  ss38j_input='{"tool_name":"Bash","tool_input":{"command":"echo benign"}}'
  (
    cd "$TMP/fake" || exit 0
    # shellcheck disable=SC2069
    printf '%s' "$ss38j_input" \
      | PATH="$GH38_SHIM:$PATH" \
        GH_SHIM_STATE="$GH38_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1 >/dev/null
  )
  ss38j_rc=$?

  ss38j_after=$(wc -l < "$REAL_AUDIT_38J" 2>/dev/null | tr -d ' ' || echo 0)
  ss38j_new=$(( ss38j_after - ss38j_before ))
  ss38j_tail=""
  if [ "$ss38j_new" -gt 0 ]; then
    ss38j_tail=$(tail -"$ss38j_new" "$REAL_AUDIT_38J" 2>/dev/null)
  fi

  # Restore IMMEDIATELY (before the assertion) so an assertion failure
  # doesn't leave the suite running without the live helper.
  mv "$SS38J_BAK" "$SS38J_PATH"
  SS38J_BAK=""

  # Count helper-missing warns mentioning git_matcher.sh in the new
  # audit window. Both warns share category=commit-format and
  # decision=helper-missing; differ only by no-op fields. The reason
  # field carries the absolute path of the missing helper, so a
  # basename match isolates git_matcher.sh from any concurrent
  # unrelated warns.
  ss38j_count=$(printf '%s\n' "$ss38j_tail" \
    | grep -c '"category":"commit-format"' \
    || true)
  ss38j_gm_count=$(printf '%s\n' "$ss38j_tail" \
    | grep '"decision":"helper-missing"' \
    | grep -c 'git_matcher\.sh' \
    || true)

  if [ "$ss38j_rc" = 0 ] && [ "$ss38j_gm_count" = 2 ]; then
    ok "safe_source: git_matcher.sh missing → 2 helper-missing warns (hook + branch_guard) (#36)"
  else
    ng "safe_source: expected 2 helper-missing warns for git_matcher.sh; got rc=$ss38j_rc commit-format=$ss38j_count gm-helper-missing=$ss38j_gm_count tail=$ss38j_tail (#36)"
  fi
fi

trap - EXIT INT TERM

# 38g (#499 / Directive #498): a leading gh GLOBAL FLAG before `pr merge` must not
# bypass the ac-closeout entry anchor (pre_tool_use.sh :336). The tight
# `\bgh[[:space:]]+pr[[:space:]]+merge` anchor missed `gh --repo o/r pr merge`;
# the #499 fix widens it (same leading-global-flag-run form as merge-strategy).
# Placed in §38 (before the GH38 teardown below) so the gh38 shim is live. RED
# before the fix (leading-flag form → ac-closeout never enters → allow).
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"
out38g=$(gh38_run "gh --repo o/r pr merge 200 --merge"); rc38g=$?
if [ "$rc38g" = 2 ] && printf '%s' "$out38g" | grep -q 'ac-closeout'; then
  ok "38g: leading --repo before 'pr merge' → ac-closeout still blocks unchecked AC (#499)"
else
  ng "38g: leading --repo bypassed ac-closeout (rc=$rc38g) (#499)"
fi

# ---- §500a-500e (#500 / Directive #498): ac-closeout integrity ----
# Three independent bypasses of the closeout gate, all in ac_closeout_gate.sh.
# Placed in the §38 block (before the GH38 teardown) so the gh38 shim is live.
# Labelled 500a-e (not 38h-l) to avoid colliding with the pre-existing §38j/ss38*
# labels.

# 500a (checkbox-form gap): an unchecked AC written as `* [ ]` (not `- [ ]`) must
# still be DETECTED → block. RED before the fix (only `^- \[ \]` was recognized,
# so the issue looked AC-clean and the merge was allowed).
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '* [ ] do the thing\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"; : > "$GH38_STATE/issue_comments_trusted"
out500a=$(gh38_run "gh pr merge 200 --merge"); rc500a=$?
if [ "$rc500a" = 2 ] && printf '%s' "$out500a" | grep -q 'ac-closeout'; then
  ok "500a: '* [ ]' unchecked AC detected → block (checkbox-form gap, #500)"
else
  ng "500a: '* [ ]' unchecked AC not detected → bypass (rc=$rc500a) (#500)"
fi

# 500b (forged non-canonical marker): a comment that merely STARTS with
# `## AC closeout` but is not the canonical machine shape must NOT satisfy the
# gate → block. RED before the fix (`^## AC closeout` matched any heading).
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
printf '## AC closeout-totally-fake lol\n' > "$GH38_STATE/issue_comments"
printf '## AC closeout-totally-fake lol\n' > "$GH38_STATE/issue_comments_trusted"
out500b=$(gh38_run "gh pr merge 200 --merge"); rc500b=$?
if [ "$rc500b" = 2 ] && printf '%s' "$out500b" | grep -q 'ac-closeout'; then
  ok "500b: forged non-canonical '## AC closeout-…' does not satisfy the gate → block (#500)"
else
  ng "500b: forged non-canonical marker bypassed the gate (rc=$rc500b) (#500)"
fi

# 500c (untrusted-author marker): a canonical marker posted by an UNTRUSTED author
# must NOT satisfy the gate. The mock returns the canonical marker for the flat
# (pre-fix) query but an EMPTY trusted-filtered set, modelling the author filter
# → block. RED before the fix (no author filter; flat query saw the marker).
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
printf '## AC closeout (resolved by PR #200)\n' > "$GH38_STATE/issue_comments"
: > "$GH38_STATE/issue_comments_trusted"   # untrusted author → filtered out
out500c=$(gh38_run "gh pr merge 200 --merge"); rc500c=$?
if [ "$rc500c" = 2 ] && printf '%s' "$out500c" | grep -q 'ac-closeout'; then
  ok "500c: canonical marker from an untrusted author does not satisfy the gate → block (#500)"
else
  ng "500c: untrusted-author marker bypassed the gate (rc=$rc500c) (#500)"
fi

# 500d (no over-block GUARD — must stay green): a canonical marker from a TRUSTED
# author still satisfies the gate → ALLOW. Guards against over-blocking the
# legitimate closeout path.
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
printf '## AC closeout (resolved by PR #200)\n' > "$GH38_STATE/issue_comments"
printf '## AC closeout (resolved by PR #200)\n' > "$GH38_STATE/issue_comments_trusted"
out500d=$(gh38_run "gh pr merge 200 --merge"); rc500d=$?
if [ "$rc500d" = 0 ]; then
  ok "500d: canonical marker from a trusted author still allows merge (no over-block, #500)"
else
  ng "500d: canonical trusted marker wrongly blocked (rc=$rc500d: $out500d) (#500)"
fi

# 500e (PR-URL target divergence): `gh pr merge <URL>/pull/777` must evaluate PR
# 777 (extract_pr_from_merge_cmd parses the URL), NOT fall back to the current
# branch's PR. PR 777 → issue 300 (unchecked, no marker) → block; the fallback
# PR (5) is clean. RED before the fix (URL token skipped → fallback → allow).
# Uses 777 (not 200) so the mock's per-PR branch doesn't collide with the
# PR-200 cases above.
gh38_reset
printf '300\n' > "$GH38_STATE/pr_issues_777"   # PR 777's linked issue (unchecked)
: > "$GH38_STATE/pr_issues"                      # fallback PR 5 → no linked issues
printf '5\n' > "$GH38_STATE/pr_number"           # current-branch fallback PR
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"; : > "$GH38_STATE/issue_comments_trusted"
out500e=$(gh38_run "gh pr merge https://github.com/o/r/pull/777 --merge"); rc500e=$?
if [ "$rc500e" = 2 ] && printf '%s' "$out500e" | grep -q 'ac-closeout'; then
  ok "500e: URL-form PR resolves to #777 (not the fallback) → block on its unchecked AC (#500)"
else
  ng "500e: URL-form PR mis-resolved to the fallback → bypass (rc=$rc500e) (#500)"
fi

# 500f (URL inside a value-flag — security-review finding): a `/pull/N` that
# appears as the VALUE of `--body`/`--subject`/etc. must NOT be read as the PR
# selector. `gh pr merge --body <…/pull/777> 5 --merge` must evaluate PR 5 (the
# real positional), not 777. PR 5 → issue 100 (unchecked, no marker) → block;
# 777 → pr_issues_777 (empty) → would wrongly allow. RED before the skip_next
# fix (the `*/pull/*` arm matched the --body value → extracted 777 → allow).
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"          # PR 5 (default arm) → dirty issue
: > "$GH38_STATE/pr_issues_777"                     # 777 → no linked issues
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
: > "$GH38_STATE/issue_comments"; : > "$GH38_STATE/issue_comments_trusted"
out500f=$(gh38_run "gh pr merge --body https://github.com/o/r/pull/777 5 --merge"); rc500f=$?
if [ "$rc500f" = 2 ] && printf '%s' "$out500f" | grep -q 'ac-closeout'; then
  ok "500f: /pull/N inside a --body value is not read as the PR; PR 5 evaluated → block (#500)"
else
  ng "500f: /pull/N in a --body value mis-resolved the PR → bypass (rc=$rc500f) (#500)"
fi

rm -rf "$GH38_DIR"

# ---------- 39. matcher pass-through audit invariant (#33) ----------
# SPEC §6.1 contract: every matcher that enters MUST emit exactly one
# audit record tagged with its category in this hook invocation. The
# terminal arm fires it (block / warn); if no arm fires by the tail,
# `pass_through_trace <cat> "<cmd>"` emits a `warn <cat> pass-through`.
#
# §39a tests pass-through firing for matchers where a benign-but-entering
# cmd today produces no audit record. §39b is the structural awk-grep
# that every matcher block contains a `pass_through_trace` symbol. §39c
# asserts the negative: a cmd that enters no matcher produces zero
# new audit records.

REAL_AUDIT_39="$SMOKE_AUDIT"

# §39 test harness — invoke pre_tool_use.sh with a synthesized Bash
# tool_input.command, captured the way §38 does. The gh shim is needed
# only for the ac-closeout matcher; reuse the §38 fixture path.
PT39_DIR=$(mktemp -d)
PT39_SHIM="$PT39_DIR/bin"
PT39_STATE="$PT39_DIR/state"
mkdir -p "$PT39_SHIM" "$PT39_STATE"
cat > "$PT39_SHIM/gh" <<'SHIM'
#!/bin/sh
case "$*" in
  *"pr view"*headRefOid*) echo smoke-attest-head ;;  # #586 merge-review head-pin match
  *"api"*"/reviews"*)                    printf '[{"state":"APPROVED","commit_id":"smoke-attest-head","submitted_at":"2020-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"lgtm"}]\n' ;;  # #586 native APPROVED@head → merge-review allows
  *"repo view"*"nameWithOwner"*)         echo o/r ;;  # #586 merge-review owner/repo
  *"pr view"*"closingIssuesReferences"*) cat "$GH_SHIM_STATE/pr_issues" 2>/dev/null ;;
  *"pr view"*"--json number"*)           cat "$GH_SHIM_STATE/pr_number" 2>/dev/null ;;
  *"issue view"*"--json body"*)          cat "$GH_SHIM_STATE/issue_body" 2>/dev/null ;;
  *"issue view"*"--json comments"*)      cat "$GH_SHIM_STATE/issue_comments" 2>/dev/null ;;
esac
exit 0
SHIM
chmod +x "$PT39_SHIM/gh"

# Set up an ac-closeout fixture that makes pr_needs_closeout return 1
# (allow path — linked issue has NO unchecked AC items). This is the
# pass-through scenario for ac-closeout.
printf '100\n' > "$PT39_STATE/pr_issues"
printf '200\n' > "$PT39_STATE/pr_number"
printf -- '- [x] all done\n' > "$PT39_STATE/issue_body"
: > "$PT39_STATE/issue_comments"

pt39_run() {
  local cmd="$1"
  (
    cd "$TMP/fake" || exit 1
    # shellcheck disable=SC2069
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | jq -Rs .)" \
      | PATH="$PT39_SHIM:$PATH" \
        GH_SHIM_STATE="$PT39_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1 >/dev/null
  )
}

# §39a: benign-but-entering commands per matcher. Each row asserts the
# audit grew by ≥1 and the LAST appended record carries the expected
# category + decision token. Categories per the SPEC §6.1 row table;
# decision tokens per the new decision-token vocabulary table.
#
# Rows that expect `pass-through` are the new behavior the refactor
# introduces. Rows expecting `notice` are explicit-allow arms (e.g.
# --amend on non-pushed commit). Rows expecting `bypass-suspect` cover
# the always-warns matcher (unchanged by this PR but locks the invariant
# that it always decides).
#
# Format: "cmd-or-cmd-tag|category|expected-decision"
# When the cmd starts with `gh pr merge`, pt39_run uses the gh shim
# whose state is already configured for the pass-through ac-closeout
# scenario above.
PT39_TABLE=(
  # Intentionally empty after #83. The original row
  # ("gh pr merge 200 --merge|ac-closeout|pass-through") encoded the
  # pre-fix bug behavior — the ac-closeout matcher's case-statement was
  # missing the rc=1 happy-path arm, so allow-cases fell through to
  # pass_through_trace. Issue #83's fix added `1) mark_allow ac-closeout`,
  # making the happy path silent (per SPEC §6.1's mark_allow contract).
  # §39d below asserts the corrected silence, including the pipe-form
  # `gh pr merge ... 2>&1 | tail -N` shape that originally triggered #83.
)

# Subset notes for the v1 cut: only ac-closeout was included originally.
# Adding the other 10 matchers needs custom setup per matcher (cwd on
# the right branch for backmerge; pushed-vs-unpushed for --amend; etc.)
# — those are added incrementally as the matchers are retrofitted. §39b's
# structural check is the safety net that catches any matcher whose
# retrofit is forgotten.

p39_fails=0
# Guard empty-array iteration under `set -u`. PT39_TABLE is intentionally
# empty after #83's mark_allow fix; §39d below tests the corrected silence.
for row in ${PT39_TABLE[@]+"${PT39_TABLE[@]}"}; do
  IFS='|' read -r p39_cmd p39_cat p39_dec <<< "$row"
  p39_before=$(wc -l < "$REAL_AUDIT_39" 2>/dev/null | tr -d ' ' || echo 0)
  pt39_run "$p39_cmd" >/dev/null 2>&1
  p39_rc=$?
  p39_after=$(wc -l < "$REAL_AUDIT_39" 2>/dev/null | tr -d ' ' || echo 0)
  p39_new=$(( p39_after - p39_before ))
  p39_tail=""
  if [ "$p39_new" -gt 0 ]; then
    p39_tail=$(tail -"$p39_new" "$REAL_AUDIT_39" 2>/dev/null)
  fi

  if [ "$p39_new" -ge 1 ] \
     && printf '%s' "$p39_tail" | grep -q "\"category\":\"$p39_cat\"" \
     && printf '%s' "$p39_tail" | grep -q "\"decision\":\"$p39_dec\""; then
    ok "pass-through: $p39_cat → $p39_dec emitted on benign-entering cmd (#33)"
  else
    p39_fails=$((p39_fails+1))
    ng "pass-through: expected category=$p39_cat decision=$p39_dec; got rc=$p39_rc new=$p39_new tail=$p39_tail (#33)"
  fi
done

# §39b: structural awk-grep — every `if printf '%s' "$cmd" | grep -qE`
# matcher block in pre_tool_use.sh must contain a `pass_through_trace`
# call. The decided= + tail pattern from SPEC §6.1 implementation
# pattern ensures the symbol appears. Awk tracks `if ... then ... fi`
# nesting via line count of `then` opens vs `fi` closes within each
# matcher block.
pt39b_missing=$(awk '
  /if printf .* grep -qE/ {
    # Closing the previous matcher block: if we never saw pass_through_trace
    # or mark_allow since the prior matcher entry, that matcher is missing
    # its structural tail-marker. Either symbol satisfies the SPEC §6.1
    # contract (pass_through_trace = anomaly safety net; mark_allow =
    # high-frequency happy path, no audit emission).
    if (in_matcher && !saw_pt) print FILENAME ":" start ": " matcher_text
    in_matcher=1; saw_pt=0; start=NR; matcher_text=$0; next
  }
  in_matcher && (/pass_through_trace/ || /mark_allow/) { saw_pt=1 }
  END {
    if (in_matcher && !saw_pt) print FILENAME ":" start ": " matcher_text
  }
' "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh")
if [ -z "$pt39b_missing" ]; then
  ok "pass-through: every matcher block contains pass_through_trace symbol (#33)"
else
  ng "pass-through: matcher block(s) missing pass_through_trace: $pt39b_missing (#33)"
fi

# §39c: negative — a Bash cmd that matches no matcher (`ls -la`) must
# produce zero new audit records. Locks the "matcher didn't enter ⇒
# no record" half of the invariant.
p39c_before=$(wc -l < "$REAL_AUDIT_39" 2>/dev/null | tr -d ' ' || echo 0)
pt39_run "ls -la" >/dev/null 2>&1
p39c_after=$(wc -l < "$REAL_AUDIT_39" 2>/dev/null | tr -d ' ' || echo 0)
p39c_new=$(( p39c_after - p39c_before ))
if [ "$p39c_new" = 0 ]; then
  ok "pass-through: benign no-matcher cmd produces zero audit records (#33)"
else
  ng "pass-through: benign cmd produced $p39c_new unexpected audit records (#33)"
fi

# §39d: ac-closeout happy-path silence (#83). When pr_needs_closeout
# returns 1 (allow: no unchecked AC items), the matcher's `1)` arm calls
# mark_allow (silent per SPEC §6.1 mark_allow contract) and decides.
# Pre-fix bug: the case statement had no `1)` arm, so the happy path
# fell through to pass_through_trace, producing a spurious warn audit
# line on every successful AC-closed-out merge. Tests both the bare form
# and the pipe-with-redirect form (`gh pr merge ... 2>&1 | tail -5`) that
# triggered #83's discovery on PR #77's auto-merge.
for p39d_cmd in "gh pr merge 200 --merge" "gh pr merge 200 --auto --merge --delete-branch 2>&1 | tail -5"; do
  p39d_before=$(wc -l < "$REAL_AUDIT_39" 2>/dev/null | tr -d ' ' || echo 0)
  pt39_run "$p39d_cmd" >/dev/null 2>&1
  p39d_after=$(wc -l < "$REAL_AUDIT_39" 2>/dev/null | tr -d ' ' || echo 0)
  p39d_new=$(( p39d_after - p39d_before ))
  if [ "$p39d_new" = 0 ]; then
    ok "pass-through: ac-closeout happy path silent on \`${p39d_cmd:0:40}...\` (#83)"
  else
    p39d_tail=$(tail -"$p39d_new" "$REAL_AUDIT_39" 2>/dev/null | tr '\n' '|')
    ng "pass-through: ac-closeout happy path emitted $p39d_new audit record(s) on \`$p39d_cmd\` — expected silent (mark_allow). tail=$p39d_tail (#83)"
  fi
done

rm -rf "$PT39_DIR"

# ---------- 40. SessionStart hookrt-missing banner (#37) ----------
# SPEC §6.5(c): when the resolved shell root's
# .claude/hooks/hookrt.sh is absent, session_start.sh
# emits a once-per-session actionable banner to stderr (debounced via
# TMPDIR stamp keyed on CLAUDE_SESSION_ID:-$PPID with `-hookrt` suffix),
# layered on top of the existing per-invocation WARN diagnostic floor at
# session_start.sh:34.
#
# Banner content carries a `Fix:` clause (the call to action); the
# per-invocation WARN line does not. Smoke filters on `Fix:` to isolate
# the banner from the diagnostic floor when both fire on the same call.
#
# 40a: fires when hookrt.sh missing on first SessionStart invocation.
# 40b: stamp-debounce — fires exactly once across two same-session invocations.
# 40c: silent when hookrt.sh present.

SS_HOOKRT_PATH="$SHELL_ROOT/.claude/hooks/hookrt.sh"
SS40_DIR=$(mktemp -d)
SS40_BAK="$SS40_DIR/hookrt.sh.bak"
SS40_TMPDIR="$SS40_DIR/tmp"
mkdir -p "$SS40_TMPDIR"

ss40_restore() {
  if [ -n "${SS40_BAK:-}" ] && [ -f "$SS40_BAK" ] && [ ! -f "$SS_HOOKRT_PATH" ]; then
    mv "$SS40_BAK" "$SS_HOOKRT_PATH"
  fi
}
trap 'ss40_restore' EXIT INT TERM

if [ ! -f "$SS_HOOKRT_PATH" ]; then
  ng "40: hookrt.sh not present in repo (#37)"
else
  mv "$SS_HOOKRT_PATH" "$SS40_BAK"

  # 40a: first invocation, fresh session, hookrt.sh missing → banner fires.
  ss40a_session_id="smoke-40a-$$-$(date +%s%N 2>/dev/null || echo 0)"
  ss40a_stderr=$(
    (
      cd "$TMP/fake" || exit 0
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
      CLAUDE_SESSION_ID="$ss40a_session_id" \
      TMPDIR="$SS40_TMPDIR" \
        bash "$SHELL_ROOT/.claude/hooks/session_start.sh" </dev/null 2>&1 >/dev/null
    )
  )
  ss40a_banner=$(printf '%s\n' "$ss40a_stderr" | grep -c 'hookrt-missing.*Fix:' || true)
  if [ "$ss40a_banner" = 1 ]; then
    ok "40a: hookrt.sh missing → banner fires once (#37)"
  else
    ng "40a: hookrt.sh missing — expected banner count=1; got=$ss40a_banner stderr=$ss40a_stderr (#37)"
  fi

  # 40b: second invocation, SAME session_id → stamp dedupes → banner does NOT refire.
  ss40b_stderr=$(
    (
      cd "$TMP/fake" || exit 0
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
      CLAUDE_SESSION_ID="$ss40a_session_id" \
      TMPDIR="$SS40_TMPDIR" \
        bash "$SHELL_ROOT/.claude/hooks/session_start.sh" </dev/null 2>&1 >/dev/null
    )
  )
  ss40b_banner=$(printf '%s\n' "$ss40b_stderr" | grep -c 'hookrt-missing.*Fix:' || true)
  if [ "$ss40b_banner" = 0 ]; then
    ok "40b: second invocation same session → banner debounced to zero (#37)"
  else
    ng "40b: same-session second invocation — expected banner count=0 (debounced); got=$ss40b_banner stderr=$ss40b_stderr (#37)"
  fi

  # Restore hookrt.sh BEFORE 40c so the present-case has the real runtime.
  mv "$SS40_BAK" "$SS_HOOKRT_PATH"
  SS40_BAK=""

  # 40c: fresh session, hookrt.sh present → banner does NOT fire.
  ss40c_session_id="smoke-40c-$$-$(date +%s%N 2>/dev/null || echo 0)"
  ss40c_stderr=$(
    (
      cd "$TMP/fake" || exit 0
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
      CLAUDE_SESSION_ID="$ss40c_session_id" \
      TMPDIR="$SS40_TMPDIR" \
        bash "$SHELL_ROOT/.claude/hooks/session_start.sh" </dev/null 2>&1 >/dev/null
    )
  )
  ss40c_banner=$(printf '%s\n' "$ss40c_stderr" | grep -c 'hookrt-missing.*Fix:' || true)
  if [ "$ss40c_banner" = 0 ]; then
    ok "40c: hookrt.sh present → banner silent (#37)"
  else
    ng "40c: hookrt.sh present — expected banner count=0; got=$ss40c_banner stderr=$ss40c_stderr (#37)"
  fi
fi

trap - EXIT INT TERM
rm -rf "$SS40_DIR"

# ---------- §502: SessionStart registry-zeroed detector (#502 / Directive #498) ----------
# A present-but-EMPTY per-project registry silently disables all enforcement
# (in_scope fails open); session_start.sh now surfaces it (banner + audit warn)
# so the disarmed state is no longer traceless. GHJIG_STATE_DIR_OVERRIDE points
# ghjig_registry_file at a controlled dir. Mirrors the §40 banner harness.
SS502_TMPDIR=$(mktemp -d); SS502_STATE=$(mktemp -d)
ss502_run() {  # $1 = session_id → echoes registry-zeroed banner count
  ( cd "$TMP/fake" || exit 0
    GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" CLAUDE_SESSION_ID="$1" \
    CLAUDE_PROJECT_DIR="$SS502_STATE" GHJIG_STATE_DIR_OVERRIDE="$SS502_STATE" \
    TMPDIR="$SS502_TMPDIR" \
      bash "$SHELL_ROOT/.claude/hooks/session_start.sh" </dev/null 2>&1 >/dev/null
  ) | grep -c 'registry-zeroed.*Fix:' || true
}
# 502a: present-but-EMPTY registry → banner fires (was traceless).
: > "$SS502_STATE/registry.txt"
[ "$(ss502_run "smoke-502a-$$")" = 1 ] \
  && ok "502a: empty registry → registry-zeroed banner fires (#502)" \
  || ng "502a: empty registry did not surface the silent-disable (#502)"
# 502b: registry WITH content → silent (no false fire).
printf '%s\n' "$TMP/fake" > "$SS502_STATE/registry.txt"
[ "$(ss502_run "smoke-502b-$$")" = 0 ] \
  && ok "502b: non-empty registry → detector silent (#502)" \
  || ng "502b: non-empty registry wrongly fired the detector (#502)"
# 502c: ABSENT registry → silent (normal unregistered / pre-registration case).
rm -f "$SS502_STATE/registry.txt"
[ "$(ss502_run "smoke-502c-$$")" = 0 ] \
  && ok "502c: absent registry → detector silent (transparent unregistered case) (#502)" \
  || ng "502c: absent registry wrongly fired the detector (#502)"
# 502e: the PERSISTENT half — an empty registry must write a queryable
# `registry-zeroed` audit record (not just the ephemeral stderr banner), else
# the disarmed state stays traceless in the LOG (the audit_log arity bug). Fresh
# empty-registry run, then grep the audit aggregate under the override dir.
: > "$SS502_STATE/registry.txt"
ss502_run "smoke-502e-$$" >/dev/null 2>&1
if grep -rqs 'registry-zeroed' "$SS502_STATE" 2>/dev/null; then
  ok "502e: empty registry writes a persistent 'registry-zeroed' audit record (#502)"
else
  ng "502e: no persistent registry-zeroed audit record — disarmed state traceless in the log (#502)"
fi
rm -rf "$SS502_TMPDIR" "$SS502_STATE"
# 502f (#554/D4): the banner must also stat the LEGACY shared registry. When the
# per-project registry is ABSENT, in_scope/path_in_scope fall back to the legacy
# shared "${GHJIG_ROOT}/.claude/state/registry.txt" (cwd_guard.sh:12,62) — so an
# empty legacy file ALSO silently disables enforcement, but pre-fix the banner
# (which only stat'd the per-project file) stayed mute: a silent-disabled blind
# spot. The banner now mirrors the reader's resolution order. Guarded on the
# legacy file NOT pre-existing (never clobber a real registration); the file is
# gitignored + removed after.
SS502F_LEGACY="$SHELL_ROOT/.claude/state/registry.txt"
if [ ! -e "$SS502F_LEGACY" ]; then
  mkdir -p "$(dirname "$SS502F_LEGACY")"
  : > "$SS502F_LEGACY"                         # empty legacy shared registry
  SS502F_STATE=$(mktemp -d)                    # per-project override w/ NO registry.txt → absent
  SS502F_TMPDIR=$(mktemp -d)
  ss502f_cnt=$( ( cd "$TMP/fake" || exit 0
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" CLAUDE_SESSION_ID="smoke-502f-$$" \
      CLAUDE_PROJECT_DIR="$SS502F_STATE" GHJIG_STATE_DIR_OVERRIDE="$SS502F_STATE" \
      TMPDIR="$SS502F_TMPDIR" \
        bash "$SHELL_ROOT/.claude/hooks/session_start.sh" </dev/null 2>&1 >/dev/null
    ) | grep -c 'registry-zeroed.*Fix:' || true )
  [ "$ss502f_cnt" = 1 ] \
    && ok "502f: empty LEGACY shared registry (per-project absent) → banner fires (#554)" \
    || ng "502f: empty legacy shared registry silently disabled enforcement — banner mute (#554)"
  rm -f "$SS502F_LEGACY"; rm -rf "$SS502F_STATE" "$SS502F_TMPDIR"
else
  ok "502f: legacy shared registry pre-exists — D4 legacy-empty test skipped to avoid clobber (#554)"
fi
# 502d: SPEC §6.5(c) documents the registry-zeroed detector AND the
# binding-repoint residual + the §1.4 "no fail-open flip" decision.
if grep -qiE 'registry-zeroed detector' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qiE 'binding-symlink repoint|repoint.*binding' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qiE 'NOT a fail-open|not a fail-open' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "502d: SPEC §6.5(c) documents the registry detector + binding-repoint residual + §1.4 decision (#502)"
else
  ng "502d: SPEC missing the #502 detector/residual/§1.4 documentation (#502)"
fi

# ---------- 41. scripts/setup_project.sh idempotency + scope guards (#43) ----------
# PR #43 introduces scripts/setup_project.sh — an idempotent bootstrap for the
# GitHub Project substrate (SPEC §1.7). The script:
#   1. Refuses on unregistered target paths (registry guard).
#   2. Refuses without `gh auth` + `project` scope.
#   3. On first run: creates the Project (if absent) and the six CLI-managed
#      fields. The Iteration field is user-managed via GH UI because the
#      `gh project field-create` CLI does not accept ITERATION as a data type.
#   4. On rerun: queries existing fields and skips creates that already exist.
#
# §41 mocks `gh` via PATH overlay so the test runs without the `project` token
# scope, without making real API calls, and without creating GitHub state.
# The mock records each `gh …` invocation to a log file the assertions inspect.

SP_DIR=$(mktemp -d)
SP_TARGET="$SP_DIR/target"
SP_BIN="$SP_DIR/bin"
mkdir -p "$SP_TARGET" "$SP_BIN"
# Resolve to the realpath so the registry entry matches `pwd -P` from inside the
# target directory (macOS /var is a symlink to /private/var; the script uses -P).
SP_TARGET=$(cd "$SP_TARGET" && pwd -P)
(cd "$SP_TARGET" && git init -q && git remote add origin https://github.com/smoke-owner/smoke-repo.git 2>/dev/null) || true

# Register $SP_TARGET so the registry guard accepts it. #357 (Class B): the
# code under test (setup_project.sh → dr_check_registry_guard) reads the
# target's OWN per-project ghjig-state registry as its first, override-immune
# read-arm — so register there, NOT the shell's live shared registry. Keeps the
# guard green while writing nothing to $SHELL_ROOT/.claude/state/registry.txt.
SP_REGISTRY="$SP_TARGET/.claude/ghjig-state/registry.txt"
mkdir -p "$(dirname "$SP_REGISTRY")"
printf '%s\n' "$SP_TARGET" >> "$SP_REGISTRY"

# Mock gh — dispatches by subcommand; logs full argv. Tracks per-field creation
# state via $GH_MOCK_FIELDS_DIR so successive ensure_field calls see the union
# of (default "Title" + all fields created so far). This makes the mock match
# real gh behavior: after field-create succeeds, that field shows up in
# field-list on the next call. SINGLE_SELECT field options are recorded under
# $GH_MOCK_OPTIONS_DIR/<field-name-with-underscores> (CSV of option names);
# field-list surfaces them via the `options` key so the reconcile helper (issue
# #76) can diff declared vs current. `gh api graphql` invocations land in the
# log via the top-of-mock argv capture — assertions grep for `^api graphql`.
cat > "$SP_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$GH_MOCK_LOG"; printf '\n' >> "$GH_MOCK_LOG"
case "${1:-}" in
  --version) printf 'gh version 2.50.0 (mock)\n' ;;
  auth)
    case "${2:-}" in
      status)
        if [ "${GH_MOCK_AUTH:-ok}" != ok ]; then
          echo "You are not logged in" >&2
          exit 1
        fi
        echo "github.com" >&2
        echo "  - Logged in to github.com as smoke" >&2
        echo "  - Token scopes: ${GH_MOCK_SCOPES:-gist, repo, project}" >&2
        ;;
    esac
    ;;
  repo)
    if [ "${2:-}" = view ]; then
      printf '{"owner":{"login":"smoke-owner"},"name":"smoke-repo"}'
    fi
    ;;
  api)
    # `gh api graphql` arm — used by the option-reconcile helper (issue #76)
    # to upsert SINGLE_SELECT options via updateProjectV2Field. The full argv
    # is already in $GH_MOCK_LOG; return a minimal success payload.
    if [ "${2:-}" = graphql ]; then
      printf '{"data":{"updateProjectV2Field":{"projectV2Field":{"id":"PVTSSF_mock"}}}}'
    fi
    ;;
  project)
    case "${2:-}" in
      list)
        if [ -f "$GH_MOCK_PROJECT_CREATED" ]; then
          printf '{"projects":[{"number":1,"title":"smoke-repo roadmap","url":"https://gh.test/p/1","owner":{"login":"smoke-owner"}}]}'
        else
          printf '{"projects":[]}'
        fi
        ;;
      create)
        touch "$GH_MOCK_PROJECT_CREATED"
        printf '{"number":1,"url":"https://gh.test/p/1"}'
        ;;
      field-list)
        # Build a JSON list of currently-existing fields: always-present "Title"
        # plus whatever names were recorded by previous field-create calls. For
        # each field, include an `options` array if $GH_MOCK_OPTIONS_DIR/<name>
        # exists (CSV-of-option-names). Reconcile helper (issue #76) reads this.
        names="Title"
        if [ -d "$GH_MOCK_FIELDS_DIR" ]; then
          for n in "$GH_MOCK_FIELDS_DIR"/*; do
            [ -e "$n" ] || continue
            names="$names"$'\n'"$(basename "$n" | tr '_' ' ')"
          done
        fi
        json='{"fields":['
        first=1
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          [ "$first" = 1 ] && first=0 || json="$json,"
          json="$json{\"id\":\"PVTSSF_mock_${line// /_}\",\"name\":\"$line\""
          opts_file="${GH_MOCK_OPTIONS_DIR:-}/${line// /_}"
          if [ -n "${GH_MOCK_OPTIONS_DIR:-}" ] && [ -f "$opts_file" ]; then
            opts_csv=$(cat "$opts_file")
            json="$json,\"options\":["
            first_opt=1
            IFS=',' read -ra opts_arr <<< "$opts_csv"
            for o in "${opts_arr[@]}"; do
              [ "$first_opt" = 1 ] && first_opt=0 || json="$json,"
              json="$json{\"id\":\"opt_mock\",\"name\":\"$o\"}"
            done
            json="$json]"
          fi
          json="$json}"
        done <<< "$names"
        printf '%s]}' "$json"
        ;;
      field-create)
        # Extract --name + --single-select-options; record field under
        # $GH_MOCK_FIELDS_DIR and (if SINGLE_SELECT) options under
        # $GH_MOCK_OPTIONS_DIR. Basenames use underscores for spaces.
        next=
        fname=
        fopts=
        for a in "$@"; do
          if [ "${next:-}" = name ]; then
            fname="$a"; next=
            continue
          fi
          if [ "${next:-}" = opts ]; then
            fopts="$a"; next=
            continue
          fi
          [ "$a" = "--name" ] && next=name
          [ "$a" = "--single-select-options" ] && next=opts
        done
        if [ -n "$fname" ]; then
          mkdir -p "$GH_MOCK_FIELDS_DIR"
          touch "$GH_MOCK_FIELDS_DIR/${fname// /_}"
          if [ -n "$fopts" ] && [ -n "${GH_MOCK_OPTIONS_DIR:-}" ]; then
            mkdir -p "$GH_MOCK_OPTIONS_DIR"
            printf '%s\n' "$fopts" > "$GH_MOCK_OPTIONS_DIR/${fname// /_}"
          fi
        fi
        printf '{"id":"PVTSSF_mock"}'
        ;;
      link)
        printf '{"url":"https://gh.test/p/1"}'
        ;;
      view)
        printf '{"number":1,"url":"https://gh.test/p/1"}'
        ;;
    esac
    ;;
esac
exit 0
MOCK
chmod +x "$SP_BIN/gh"

# Mocked jq passthrough — real jq is fine if present; we don't need to mock it.
# (If jq isn't installed, smoke §41 can't run; treat that as a skip.)
if ! command -v jq >/dev/null 2>&1; then
  ng "41: jq not installed — cannot run mocked smoke (#43)"
else
  SP_SCRIPT="$SHELL_ROOT/scripts/setup_project.sh"
  if [ ! -f "$SP_SCRIPT" ]; then
    ng "41: scripts/setup_project.sh missing — cannot run mocked smoke (#43)"
  else
    # 41a: first-run from registered target → creates project + 7 fields.
    rm -f "$SP_DIR/gh.log" "$SP_DIR/project-created" "$SP_DIR/fields-created"
    (
      cd "$SP_TARGET" || exit 0
      PATH="$SP_BIN:$PATH" \
      GHJIG_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR/fields" \
      GH_MOCK_OPTIONS_DIR="$SP_DIR/options" \
      GH_MOCK_AUTH=ok \
        bash "$SP_SCRIPT" </dev/null >/dev/null 2>&1
    )
    sp41a_creates=$( { grep -c 'project field-create' "$SP_DIR/gh.log" 2>/dev/null; } || true)
    sp41a_proj_create=$( { grep -c 'project create' "$SP_DIR/gh.log" 2>/dev/null; } || true)
    : "${sp41a_creates:=0}"
    : "${sp41a_proj_create:=0}"
    # Schema: 4 CLI-managed fields (Item Type / Status / Priority / Parent).
    # Goal Type option removed; Confidence + Success Signals fields removed.
    # Iteration stays user-managed.
    if [ "$sp41a_proj_create" -ge 1 ] && [ "$sp41a_creates" = 4 ]; then
      ok "41a: first-run creates project + 4 fields (#43/#96)"
    else
      ng "41a: first-run expected ≥1 project-create + 4 field-create (v3); got proj=$sp41a_proj_create field=$sp41a_creates (#43/#96)"
    fi

    # 41b: second-run (project + fields already exist) → zero new field-creates.
    rm -f "$SP_DIR/gh.log"
    (
      cd "$SP_TARGET" || exit 0
      PATH="$SP_BIN:$PATH" \
      GHJIG_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR/fields" \
      GH_MOCK_OPTIONS_DIR="$SP_DIR/options" \
      GH_MOCK_AUTH=ok \
        bash "$SP_SCRIPT" </dev/null >/dev/null 2>&1
    )
    sp41b_creates=$( { grep -c 'project field-create' "$SP_DIR/gh.log" 2>/dev/null; } || true)
    sp41b_proj_create=$( { grep -c 'project create' "$SP_DIR/gh.log" 2>/dev/null; } || true)
    : "${sp41b_creates:=0}"
    : "${sp41b_proj_create:=0}"
    if [ "$sp41b_creates" = 0 ] && [ "$sp41b_proj_create" = 0 ]; then
      ok "41b: second-run idempotent — zero new creates (#43)"
    else
      ng "41b: second-run expected 0 creates; got proj=$sp41b_proj_create field=$sp41b_creates (#43)"
    fi

    # 41c: unregistered path → script refuses with exit 1.
    SP_OTHER=$(mktemp -d)
    (cd "$SP_OTHER" && git init -q) || true
    sp41c_rc=0
    (
      cd "$SP_OTHER" || exit 0
      PATH="$SP_BIN:$PATH" \
      GHJIG_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR/fields" \
      GH_MOCK_OPTIONS_DIR="$SP_DIR/options" \
      GH_MOCK_AUTH=ok \
        bash "$SP_SCRIPT" </dev/null >/dev/null 2>&1
    ) || sp41c_rc=$?
    if [ "$sp41c_rc" -ne 0 ]; then
      ok "41c: unregistered path → refused with exit $sp41c_rc (#43)"
    else
      ng "41c: unregistered path should refuse but exited 0 (#43)"
    fi
    rm -rf "$SP_OTHER"

    # 41d: missing `project` scope → script refuses with exit 1.
    sp41d_rc=0
    (
      cd "$SP_TARGET" || exit 0
      PATH="$SP_BIN:$PATH" \
      GHJIG_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR/fields" \
      GH_MOCK_OPTIONS_DIR="$SP_DIR/options" \
      GH_MOCK_AUTH=ok \
      GH_MOCK_SCOPES='gist, repo' \
        bash "$SP_SCRIPT" </dev/null >/dev/null 2>&1
    ) || sp41d_rc=$?
    if [ "$sp41d_rc" -ne 0 ]; then
      ok "41d: missing project scope → refused with exit $sp41d_rc (#43)"
    else
      ng "41d: missing project scope should refuse but exited 0 (#43)"
    fi

    # 41e: option reconciliation — drift case.
    # Status pre-seeded with GitHub-default options (Todo, In Progress, Done);
    # declared v3 set is (Proposed, Active, Blocked, Completed). Expect: one
    # `gh api graphql` mutation whose payload UNIONS the 3 defaults with the
    # 4 v3 declared options = 7 total names. (Item Type field carries the
    # legacy Goal,Directive,Execution from a v0 substrate — v3 declares only
    # Directive,Execution, which is a subset; no Item Type reconcile fires.)
    SP_DIR2=$(mktemp -d)
    SP_TARGET2="$SP_DIR2/target"
    mkdir -p "$SP_TARGET2"
    SP_TARGET2=$(cd "$SP_TARGET2" && pwd -P)
    (cd "$SP_TARGET2" && git init -q && git remote add origin https://github.com/smoke-owner/smoke-repo.git 2>/dev/null) || true
    # #357 Class B: register on THIS target's own per-project registry (the guard
    # reads it with cwd=$SP_TARGET2), not the live shared one.
    mkdir -p "$SP_TARGET2/.claude/ghjig-state"
    printf '%s\n' "$SP_TARGET2" >> "$SP_TARGET2/.claude/ghjig-state/registry.txt"
    mkdir -p "$SP_DIR2/fields" "$SP_DIR2/options"
    touch "$SP_DIR2/project-created"
    # v3 script declares 4 fields; pre-seed extra legacy fields (Confidence,
    # Success_Signals) so we cover the v0→v3 migration case where they exist
    # but are no longer declared. setup_project.sh skips fields it doesn't
    # declare (no destructive delete; cluster I's migration handles deletion).
    for f in Item_Type Status Priority Parent Confidence Success_Signals; do touch "$SP_DIR2/fields/$f"; done
    # Pre-seed v0 Item Type option set; v3 declared is subset — no reconcile.
    # (Mock encodes the spaced name "Item Type" as the basename "Item_Type".)
    printf 'Goal,Directive,Execution\n' > "$SP_DIR2/options/Item_Type"
    printf 'Todo,In Progress,Done\n'    > "$SP_DIR2/options/Status"
    printf 'P0,P1,P2,P3\n'              > "$SP_DIR2/options/Priority"
    (
      cd "$SP_TARGET2" || exit 0
      PATH="$SP_BIN:$PATH" \
      GHJIG_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR2/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR2/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR2/fields" \
      GH_MOCK_OPTIONS_DIR="$SP_DIR2/options" \
      GH_MOCK_AUTH=ok \
        bash "$SP_SCRIPT" </dev/null >"$SP_DIR2/stdout" 2>&1
    )
    sp41e_graphql=$( { grep -c '^api graphql' "$SP_DIR2/gh.log" 2>/dev/null; } || true)
    : "${sp41e_graphql:=0}"
    # All 4 v3 Status names + all 3 GitHub-default names must appear in the
    # mutation payload (additive contract: union, not replace).
    sp41e_proposed=$(  { grep -c 'Proposed'    "$SP_DIR2/gh.log" 2>/dev/null; } || true)
    sp41e_active=$(    { grep -c 'Active'      "$SP_DIR2/gh.log" 2>/dev/null; } || true)
    sp41e_completed=$( { grep -c 'Completed'   "$SP_DIR2/gh.log" 2>/dev/null; } || true)
    sp41e_blocked=$(   { grep -c 'Blocked'     "$SP_DIR2/gh.log" 2>/dev/null; } || true)
    sp41e_todo=$(      { grep -c 'Todo'        "$SP_DIR2/gh.log" 2>/dev/null; } || true)
    sp41e_inprog=$(    { grep -c 'In Progress' "$SP_DIR2/gh.log" 2>/dev/null; } || true)
    sp41e_done=$(      { grep -c 'Done'        "$SP_DIR2/gh.log" 2>/dev/null; } || true)
    : "${sp41e_proposed:=0}"; : "${sp41e_active:=0}"; : "${sp41e_completed:=0}"
    : "${sp41e_blocked:=0}"
    : "${sp41e_todo:=0}";     : "${sp41e_inprog:=0}"; : "${sp41e_done:=0}"
    if [ "$sp41e_graphql" = 1 ] \
       && [ "$sp41e_proposed" -ge 1 ] && [ "$sp41e_active" -ge 1 ] \
       && [ "$sp41e_completed" -ge 1 ] && [ "$sp41e_blocked" -ge 1 ] \
       && [ "$sp41e_todo" -ge 1 ] && [ "$sp41e_inprog" -ge 1 ] && [ "$sp41e_done" -ge 1 ]; then
      ok "41e: v3 Status drift → 1 graphql mutation; union payload carries 4 v3 + 3 default options (#76/#96)"
    else
      ng "41e: v3 Status drift expected 1 graphql + 7 union names; got graphql=$sp41e_graphql prop=$sp41e_proposed act=$sp41e_active comp=$sp41e_completed blk=$sp41e_blocked todo=$sp41e_todo inprog=$sp41e_inprog done=$sp41e_done (#76/#96)"
    fi
    # Clean up §41e target before §41f reuses the registry.
    sp_tmp_reg=$(mktemp); grep -vxF "$SP_TARGET2" "$SP_REGISTRY" > "$sp_tmp_reg" 2>/dev/null || true
    mv "$sp_tmp_reg" "$SP_REGISTRY"
    rm -rf "$SP_DIR2"

    # 41f: option reconciliation — idempotent (v3-aligned) case.
    # Status pre-seeded with the v3 4-state set (Proposed,Active,Blocked,
    # Completed) — exactly matches the declared set. Expect: zero `gh api
    # graphql` calls AND stdout marker `options already aligned`.
    SP_DIR3=$(mktemp -d)
    SP_TARGET3="$SP_DIR3/target"
    mkdir -p "$SP_TARGET3"
    SP_TARGET3=$(cd "$SP_TARGET3" && pwd -P)
    (cd "$SP_TARGET3" && git init -q && git remote add origin https://github.com/smoke-owner/smoke-repo.git 2>/dev/null) || true
    # #357 Class B: register on THIS target's own per-project registry.
    mkdir -p "$SP_TARGET3/.claude/ghjig-state"
    printf '%s\n' "$SP_TARGET3" >> "$SP_TARGET3/.claude/ghjig-state/registry.txt"
    mkdir -p "$SP_DIR3/fields" "$SP_DIR3/options"
    touch "$SP_DIR3/project-created"
    for f in Item_Type Status Priority Parent; do touch "$SP_DIR3/fields/$f"; done
    printf 'Directive,Execution\n'                        > "$SP_DIR3/options/Item_Type"
    printf 'Proposed,Active,Blocked,Completed\n'          > "$SP_DIR3/options/Status"
    printf 'P0,P1,P2,P3\n'                                > "$SP_DIR3/options/Priority"
    (
      cd "$SP_TARGET3" || exit 0
      PATH="$SP_BIN:$PATH" \
      GHJIG_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR3/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR3/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR3/fields" \
      GH_MOCK_OPTIONS_DIR="$SP_DIR3/options" \
      GH_MOCK_AUTH=ok \
        bash "$SP_SCRIPT" </dev/null >"$SP_DIR3/stdout" 2>&1
    )
    sp41f_graphql=$( { grep -c '^api graphql' "$SP_DIR3/gh.log" 2>/dev/null; } || true)
    sp41f_aligned=$( { grep -c 'options already aligned' "$SP_DIR3/stdout" 2>/dev/null; } || true)
    : "${sp41f_graphql:=0}"; : "${sp41f_aligned:=0}"
    if [ "$sp41f_graphql" = 0 ] && [ "$sp41f_aligned" -ge 1 ]; then
      ok "41f: Status aligned → 0 graphql mutations + 'options already aligned' stdout (#76)"
    else
      ng "41f: Status aligned expected 0 graphql + ≥1 aligned-stdout; got graphql=$sp41f_graphql aligned=$sp41f_aligned (#76)"
    fi
    sp_tmp_reg=$(mktemp); grep -vxF "$SP_TARGET3" "$SP_REGISTRY" > "$sp_tmp_reg" 2>/dev/null || true
    mv "$sp_tmp_reg" "$SP_REGISTRY"
    rm -rf "$SP_DIR3"
  fi
fi

# Remove the target from the registry to avoid leaking into other tests.
if [ -f "$SP_REGISTRY" ]; then
  sp_tmp_reg=$(mktemp)
  grep -vxF "$SP_TARGET" "$SP_REGISTRY" > "$sp_tmp_reg" 2>/dev/null || true
  mv "$sp_tmp_reg" "$SP_REGISTRY"
fi
rm -rf "$SP_DIR"

# ---------- 42. activation-reviewer subagent structural sanity (#44) ----------
# Structural assertions (42a-42d) verify the agent file's contract:
# frontmatter (name, description, tools), required body sections, and the
# VERDICT-line format documented in the body. These run by default.
#
# Behavioral validation lives in §42e below, gated behind
# GHJIG_BEHAVIORAL_SMOKE=1 — it shells out to the live agent and asserts
# its VERDICT output on synthetic inputs (SPEC §4.9.3, issue #69 under
# Directive #62). Default smoke stays deterministic and offline.

DR_PATH="$SHELL_ROOT/.claude/agents/activation-reviewer.md"
if [ ! -f "$DR_PATH" ]; then
  ng "42: activation-reviewer.md missing (#44)"
else
  # 42a: frontmatter has name, description, tools.
  dr_name=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$DR_PATH")
  dr_desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{print; exit}' "$DR_PATH")
  dr_tools=$(awk '/^---$/{c++; next} c==1 && /^tools:/{print; exit}' "$DR_PATH")
  if [ -n "$dr_name" ] && [ -n "$dr_desc" ] && [ -n "$dr_tools" ]; then
    ok "42a: activation-reviewer frontmatter has name + description + tools (#44)"
  else
    ng "42a: frontmatter missing required key; name='$dr_name' desc='$dr_desc' tools='$dr_tools' (#44)"
  fi

  # 42b: required body sections present. Type-neutral structure (#170):
  # the reviewer dispatches by type label, so Input/Checks live under
  # per-type rulebooks (Directive rulebook / Execution rulebook) rather
  # than top-level headings.
  dr_missing=""
  for section in "## Type-label dispatch" "## Premise" "## Directive rulebook" "## Execution rulebook" "## Output" "## Rules"; do
    if ! grep -qF "$section" "$DR_PATH"; then
      dr_missing="$dr_missing $section"
    fi
  done
  if [ -z "$dr_missing" ]; then
    ok "42b: activation-reviewer body has all required sections (#44)"
  else
    ng "42b: activation-reviewer body missing sections:$dr_missing (#44)"
  fi

  # 42c: VERDICT-line format documents the three terminal verdicts. #172
  # replaced ship/refine/block with pass/revise/reject for activation-reviewer.
  if grep -qE '^- `VERDICT: pass' "$DR_PATH" \
     && grep -qE '^- `VERDICT: revise' "$DR_PATH" \
     && grep -qE '^- `VERDICT: reject' "$DR_PATH"; then
    ok "42c: VERDICT-line format documents pass / revise / reject (#44/#172)"
  else
    ng "42c: VERDICT-line format incomplete (#44/#172)"
  fi

  # 42d: tools restricted to the standard reviewer read-only set
  # (matches issue-reviewer.md and plan-reviewer.md).
  if printf '%s' "$dr_tools" | grep -qE 'Read.*Grep.*Glob.*Bash'; then
    ok "42d: activation-reviewer tools restricted to [Read, Grep, Glob, Bash] (#44)"
  else
    ng "42d: activation-reviewer tools expected [Read, Grep, Glob, Bash]; got '$dr_tools' (#44)"
  fi
fi

# ---------- 42f. N=3 escalation ownership + input provisioning (#552) ----------
# Cluster F, Directive #550: the revise→reject escalation lives under the
# "handled by caller" Verdict dispatch heading. Its ownership must name the
# caller (not "the reviewer escalates"), AND the comment-history it counts must
# be provisioned as an Input the reviewer/caller can actually read. Guards
# against re-introducing the unowned escalation with no provisioned data.
if [ -f "$DR_PATH" ]; then
  # (a) escalation is caller-owned (not "the reviewer escalates").
  if grep -qiF 'Escalation (caller-owned)' "$DR_PATH" \
     && ! grep -qiE 'the reviewer escalates to `?reject' "$DR_PATH"; then
    ok "42f-a: N=3 escalation is caller-owned, not 'the reviewer escalates' (#552)"
  else
    ng "42f-a: N=3 escalation ownership still ambiguous / unassigned (#552)"
  fi
  # (b) the counted data is provisioned as an Input (Revise-round count, in BOTH
  #     rulebooks) so the escalation isn't counting unprovisioned comment history.
  rrc_count=$(grep -cF 'Revise-round count' "$DR_PATH")
  if [ "$rrc_count" -ge 2 ]; then
    ok "42f-b: Revise-round count provisioned as Input in both rulebooks ($rrc_count) (#552)"
  else
    ng "42f-b: Revise-round count Input under-provisioned (found $rrc_count, want >=2) (#552)"
  fi
  # (c) escalation still TIGHTENS to reject after N=3 — block-path preserved.
  if grep -qiE 'N=3.*reject|reject handling' "$DR_PATH"; then
    ok "42f-c: escalation still resolves to reject after N=3 (block-path preserved) (#552)"
  else
    ng "42f-c: N=3 escalation no longer resolves to reject (regression) (#552)"
  fi
fi

# ---------- 42e. activation-reviewer behavioral assertions (#69 / Directive #62) ----------
# Gated behind GHJIG_BEHAVIORAL_SMOKE=1. When set, shells out to the live
# agent via `claude -p --agent activation-reviewer` and asserts the documented
# VERDICT-line output on three synthetic bodies (both Issue types, per #170):
#   - case A: minimal-but-valid Directive body  → ^VERDICT: pass
#   - case B: Directive body missing the entire ## Success signals heading
#                                               → ^VERDICT: (revise|reject)
#   - case C: minimal-but-valid Execution body  → ^VERDICT: pass
#             (exercises the type-neutral Execution rulebook dispatch)
# Verdict vocab is pass/revise/reject (#172, replaced ship/refine/block).
# Default-unset → no-op so smoke stays offline + deterministic (preserves the
# 278/278 baseline). See SPEC §4.9.3 for the routing-regression contract this
# block protects.
#
# Surface note: `claude -p --agent <name>` is the CLI session-agent override,
# which resolves the agent from `.claude/agents/*.md` at subprocess startup.
# This is a different invocation surface than the in-session `Agent({subagent_type:
# "<name>"})` tool dispatch that SPEC §4.9.3's session-restart caveat is written
# against; the two share the `.claude/agents/*.md` enumeration source but are
# separate code paths. §42e protects the CLI surface; the in-session dispatch
# is covered by Signal 1's session-trace evidence captured in the PR body.
if [ "${GHJIG_BEHAVIORAL_SMOKE:-}" = 1 ]; then
  if ! command -v claude >/dev/null 2>&1; then
    ng "42e: GHJIG_BEHAVIORAL_SMOKE=1 but 'claude' CLI not on PATH (#69)"
  else
    # Case A — synthetic minimal-but-valid Directive body. All five sections
    # present with substantive content; each success signal cites a concrete
    # mechanically-verifiable artifact (smoke run, ok-line count).
    # NOTE: `IFS= read -r -d ''` instead of `var=$(cat <<EOF)` — macOS default
    # bash 3.2 has a parser bug where heredoc-inside-command-substitution
    # mis-tokenizes special chars in the body. `read -d ''` avoids the nested
    # construct entirely; the `|| true` absorbs read's EOF-exit (rc=1).
    IFS= read -r -d '' dr_ship_prompt <<'PROMPT_EOF' || true
Review the following proposed Directive body for /file-directive (proposal review per SPEC §1.7 / §2.1). No active Directives in this synthetic test environment — proceed with checks 1-5. Do not fetch the active-Directive list; treat it as empty.

Proposed body:

# Directive: Lock smoke §42e default-offline contract

## Objective
Keep `scripts/test/smoke.sh`'s default-unset path at exactly 278 passing assertions so CI and dev loops remain deterministic and offline regardless of whether the behavioral-smoke env var is set in the operator's shell.

## Success signals
- `bash scripts/test/smoke.sh` (with `GHJIG_BEHAVIORAL_SMOKE` unset) prints `smoke: pass=278 fail=0` on the next merge to main; verified by the PR's CI summary and one local re-run on the merge commit.
- `GHJIG_BEHAVIORAL_SMOKE=1 bash scripts/test/smoke.sh` adds the passing §42e assertions (`42e-ship`, `42e-refine-or-block`, `42e-exec`) on top of the default total; verified by counting `ok "42e-` lines in the output.

## Non-goals
- Does NOT include behavioral smoke for `issue-reviewer`, `plan-reviewer`, `code-reviewer`, or `security-reviewer` — their structural assertions are out of scope for this Directive.
- Does NOT modify activation-reviewer's five checks or the VERDICT-line format (both locked by PR #50).

## Constraints
- §42e must be self-contained inside `scripts/test/smoke.sh`; no new helper scripts under `scripts/test/` or new entries in the registry.
- The env-var guard must be a single `if` at the top of §42e — no scattered checks inside individual `ok`/`ng` calls.

## MISSION fit
Serves MISSION's `Success looks like > The flow holds in unattended runs` criterion — synthetic test environment for the dir-mode workflow.
PROMPT_EOF
    dr_ship_out=$(claude -p --agent activation-reviewer "$dr_ship_prompt" 2>&1 || true)
    # Capture the LAST `^VERDICT:` line anchored on the documented delimiters
    # (`ship —`, `refine:`, `block:` per .claude/agents/activation-reviewer.md:78-82).
    # Anchoring avoids matching prose quotes of the agent's own `## Verdict
    # dispatch` section if the agent cites itself; `tail -1` picks the terminal
    # verdict if multiple anchored lines somehow appear.
    dr_ship_verdict=$(printf '%s\n' "$dr_ship_out" | grep -E '^VERDICT: (pass —|pass -|revise:|reject:)' | tail -1)
    case "$dr_ship_verdict" in
      "VERDICT: pass"*)
        ok "42e-pass: activation-reviewer returns 'pass' on minimal-but-valid synthetic body (#69/#172)" ;;
      *)
        # On miss, surface the first 200 chars of the agent's output so the
        # next operator can tell live-agent failures (auth, rate-limit, model
        # overloaded) apart from genuine verdict regressions.
        dr_ship_head=$(printf '%s' "$dr_ship_out" | head -c 200 | tr '\n' ' ')
        ng "42e-pass: expected '^VERDICT: pass', got '$dr_ship_verdict' [out: $dr_ship_head] (#69/#172)" ;;
    esac

    # Case B — synthetic body missing the entire ## Success signals heading.
    # Per check 1 (schema completeness), one missing section → refine; three
    # or more → block. Either verdict signals the missing-section regression
    # was caught; we accept both as pass to keep the assertion robust.
    IFS= read -r -d '' dr_refine_prompt <<'PROMPT_EOF' || true
Review the following proposed Directive body for /file-directive (proposal review per SPEC §1.7 / §2.1). No active Directives in this synthetic test environment — proceed with checks 1-5. Do not fetch the active-Directive list; treat it as empty.

Proposed body:

# Directive: Lock smoke §42e default-offline contract

## Objective
Keep `scripts/test/smoke.sh`'s default-unset path at exactly 278 passing assertions so CI and dev loops remain deterministic and offline regardless of whether the behavioral-smoke env var is set in the operator's shell.

## Non-goals
- Does NOT include behavioral smoke for `issue-reviewer`, `plan-reviewer`, `code-reviewer`, or `security-reviewer`.
- Does NOT modify activation-reviewer's five checks or the VERDICT-line format.

## Constraints
- §42e must be self-contained inside `scripts/test/smoke.sh`.
- The env-var guard must be a single `if` at the top of §42e.

## MISSION fit
Synthetic test environment for the dir-mode workflow.
PROMPT_EOF
    dr_refine_out=$(claude -p --agent activation-reviewer "$dr_refine_prompt" 2>&1 || true)
    dr_refine_verdict=$(printf '%s\n' "$dr_refine_out" | grep -E '^VERDICT: (pass —|pass -|revise:|reject:)' | tail -1)
    case "$dr_refine_verdict" in
      "VERDICT: revise"*|"VERDICT: reject"*)
        ok "42e-revise-or-reject: activation-reviewer rejects body missing '## Success signals' (got '$dr_refine_verdict') (#69/#172)" ;;
      *)
        dr_refine_head=$(printf '%s' "$dr_refine_out" | head -c 200 | tr '\n' ' ')
        ng "42e-revise-or-reject: expected '^VERDICT: revise' or '^VERDICT: reject', got '$dr_refine_verdict' [out: $dr_refine_head] (#69/#172)" ;;
    esac

    # Case C — synthetic minimal-but-valid EXECUTION Issue body (#170). The
    # type-neutral reviewer must dispatch to the Execution rulebook (no
    # `directive` label) and pass a well-formed Execution body. This is the
    # both-body-shapes coverage AC item 5 of #170 requires; the verdict vocab
    # is still ship/refine/block (the pass/revise/reject contract is #172).
    IFS= read -r -d '' dr_exec_prompt <<'PROMPT_EOF' || true
Review the following proposed Execution Issue body (an Execution Issue — `task` label, NO `directive` label). Apply the Execution rulebook per SPEC §4.9.1 type-label dispatch. Treat the other-open-Issues list as empty (do not fetch it).

Proposed body:

Parent Directive: #167

## What
Add a single smoke assertion under §42e that exercises the activation-reviewer on an Execution-shaped body, proving the type-neutral dispatch handles both Issue types.

## Why
Serves Directive #167's context-narrowing mechanism via its `## MISSION fit`: the activation gate must validate Execution Issues, so the reviewer's Execution rulebook needs behavioral coverage.

## Acceptance criteria
- [ ] `GHJIG_BEHAVIORAL_SMOKE=1 bash scripts/test/smoke.sh` adds a passing `42e-exec` assertion.
- [ ] The assertion calls `claude -p --agent activation-reviewer` with an Execution-shaped body and asserts `^VERDICT: pass`.

## Out of scope
- The 3-state pass/revise/reject verdict contract (Issue #172).

## Notes
- Refs #170.
PROMPT_EOF
    dr_exec_out=$(claude -p --agent activation-reviewer "$dr_exec_prompt" 2>&1 || true)
    dr_exec_verdict=$(printf '%s\n' "$dr_exec_out" | grep -E '^VERDICT: (pass —|pass -|revise:|reject:)' | tail -1)
    case "$dr_exec_verdict" in
      "VERDICT: pass"*)
        ok "42e-exec: activation-reviewer returns 'pass' on minimal-but-valid Execution body (#170/#172)" ;;
      *)
        dr_exec_head=$(printf '%s' "$dr_exec_out" | head -c 200 | tr '\n' ' ')
        ng "42e-exec: expected '^VERDICT: pass' on Execution body, got '$dr_exec_verdict' [out: $dr_exec_head] (#170/#172)" ;;
    esac
  fi
fi

