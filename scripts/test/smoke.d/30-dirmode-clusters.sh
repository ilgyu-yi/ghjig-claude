# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- 43. dir-mode command files structural sanity (#45) ----------
# PR #45 ships the five dir-mode commands + a directive body template.
# Command files are Markdown prompts for Claude (no executable code);
# what we can verify here is that each file exists, has the standard
# frontmatter (description + argument-hint), references the gated
# activation-reviewer where SPEC §5.10–§5.14 require it, and names the
# correct audit category.

DR_TEMPLATE="$SHELL_ROOT/.claude/templates/directive.md"
if [ ! -f "$DR_TEMPLATE" ]; then
  ng "43: .claude/templates/directive.md missing (#45)"
else
  dt_missing=""
  # Parent Goal field is not part of the directive template; MISSION fit is the canonical anchor.
  for section in "## Objective" "## Success signals" "## Non-goals" "## Constraints" "## MISSION fit"; do
    if ! grep -qF "$section" "$DR_TEMPLATE"; then
      dt_missing="$dt_missing $section"
    fi
  done
  if [ -z "$dt_missing" ]; then
    ok "43-template: directive.md template has all five required sections (#45/#96)"
  else
    ng "43-template: directive.md missing sections:$dt_missing (#45/#96)"
  fi
fi

for cmd in file-directive list-directives activate activate-directive complete-directive link-directive revise-directive block-directive; do
  cmd_path="$SHELL_ROOT/.claude/commands/$cmd.md"
  if [ ! -f "$cmd_path" ]; then
    ng "43-$cmd: command file missing (#45/#80)"
    continue
  fi
  has_desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{print 1; exit}' "$cmd_path")
  has_hint=$(awk '/^---$/{c++; next} c==1 && /^argument-hint:/{print 1; exit}' "$cmd_path")
  if [ "$has_desc" = 1 ] && [ "$has_hint" = 1 ]; then
    ok "43-$cmd: frontmatter has description + argument-hint (#45/#80)"
  else
    ng "43-$cmd: frontmatter missing description or argument-hint (#45/#80)"
  fi
done

# 43-reviewer-ref: file-directive, activate-directive, complete-directive,
# revise-directive must each reference activation-reviewer (the gated step per
# SPEC §5.10/§5.12/§5.13/§5.16). block-directive is intentionally NOT
# reviewer-gated (annotation-only — SPEC §5.17) and is asserted separately
# below (43-no-reviewer-block).
for cmd in file-directive activate activate-directive complete-directive revise-directive; do
  if grep -qF "activation-reviewer" "$SHELL_ROOT/.claude/commands/$cmd.md" 2>/dev/null; then
    ok "43-reviewer-$cmd: command references activation-reviewer at the gated step (#45/#80)"
  else
    ng "43-reviewer-$cmd: command does not reference activation-reviewer (#45/#80)"
  fi
done

# 43-annotation-only-block (#80): /block-directive must explicitly declare it
# is annotation-only / not reviewer-gated (SPEC §5.17 contract). Catches a
# future drift that adds a reviewer invocation without updating the spec.
if grep -qE '(not reviewer-gated|annotation[, -]only|does not invoke `?activation-reviewer)' "$SHELL_ROOT/.claude/commands/block-directive.md" 2>/dev/null; then
  ok "43-annotation-only-block: /block-directive declares annotation-only / not-reviewer-gated contract (#80)"
else
  ng "43-annotation-only-block: /block-directive must declare its annotation-only contract per SPEC §5.17 (#80)"
fi

# 43-audit-cat: each non-read-only command names its audit category.
for pair in "file-directive:directive-file" "activate:activation" "complete-directive:directive-complete" "link-directive:directive-link" "revise-directive:directive-revise" "block-directive:directive-block"; do
  cmd="${pair%%:*}"
  cat="${pair##*:}"
  if grep -qF "$cat" "$SHELL_ROOT/.claude/commands/$cmd.md" 2>/dev/null; then
    ok "43-audit-$cmd: command names audit category '$cat' (#45/#80)"
  else
    ng "43-audit-$cmd: command does not name audit category '$cat' (#45/#80)"
  fi
done

# 43-activate-sanitize (#172, security): /activate's untrusted-reject auto-discussion
# path must mandate the safe transport (--body-file, never inline --body with untrusted
# text) and whole-body @mention neutralization. Regression-guard for the body-from-
# untrusted-text shell-injection / mass-ping surface (security-reviewer, PR #176).
ACT_PATH="$SHELL_ROOT/.claude/commands/activate.md"
if grep -qF -- "--body-file" "$ACT_PATH" 2>/dev/null \
   && grep -qiE 'never[^.]*inline .?--body|inline .?--body[^.]*untrusted' "$ACT_PATH" 2>/dev/null \
   && grep -qiE 'every `?@mention|@mention.*anywhere|whole-body .?@mention' "$ACT_PATH" 2>/dev/null; then
  ok "43-activate-sanitize: /activate untrusted-reject mandates --body-file + whole-body @mention neutralization (#172)"
else
  ng "43-activate-sanitize: /activate must mandate --body-file (not inline --body) + whole-body @mention sanitization for the auto-discussion (#172)"
fi

# 43-unblock (#215): /activate must be the Directive unblock path — accept
# status:blocked as a re-activatable precondition (step 2) and remove it on pass
# (step 4). Doc-check: the command markdown IS the behavior (no runtime executes
# it), so AC3 explicitly accepts a content assertion. Fails pre-#215 (activate.md
# only handled status:proposed).
if grep -qiE 'status:proposed[^.]*\bor\b[^.]*status:blocked|status:blocked[^.]*\bor\b[^.]*status:proposed' "$ACT_PATH" 2>/dev/null \
   && grep -qiE 'remove[^.]*status:blocked|status:blocked.*(present|remov)' "$ACT_PATH" 2>/dev/null; then
  ok "43-unblock: /activate is blocked-aware — status:blocked precondition + pass-arm removal (#215)"
else
  ng "43-unblock: /activate must accept status:blocked as re-activatable and remove it on pass (#215)"
fi

# 43-reason-required (#80): /block-directive must mandate --reason <why>.
# The argument-hint frontmatter and the Procedure must both name --reason.
if grep -qE 'argument-hint:.*--reason' "$SHELL_ROOT/.claude/commands/block-directive.md" 2>/dev/null \
   && grep -qE '(--reason|`--reason)' "$SHELL_ROOT/.claude/commands/block-directive.md" 2>/dev/null; then
  ok "43-reason-required: /block-directive declares --reason in argument-hint + procedure (#80)"
else
  ng "43-reason-required: /block-directive must declare --reason in both argument-hint and procedure (#80)"
fi

# ---- §504a-d (#504 / Directive #498): skill --body-file holdouts + work-on
# default-branch. Source-grep locks (parity with the §43 dir-mode contract locks).
S504_BD="$SHELL_ROOT/.claude/commands/block-directive.md"
S504_RD="$SHELL_ROOT/.claude/commands/resolve-discussion.md"
S504_CD="$SHELL_ROOT/.claude/commands/complete-directive.md"
S504_WO="$SHELL_ROOT/.claude/commands/work-on.md"
# 504a: /block-directive posts the block comment via --body-file, not inline --body.
if grep -qF -- '--body-file' "$S504_BD" 2>/dev/null && ! grep -qE 'gh issue comment[^`]*--body "## Blocked' "$S504_BD" 2>/dev/null; then
  ok "504a: /block-directive posts the block comment via --body-file (#504)"
else
  ng "504a: /block-directive still uses inline --body for the free-text block comment (#504)"
fi
# 504b: /resolve-discussion no-action path posts via --body-file.
if grep -qF -- '--body-file' "$S504_RD" 2>/dev/null; then
  ok "504b: /resolve-discussion uses --body-file for the free-text no-action comment (#504)"
else
  ng "504b: /resolve-discussion no-action comment still inline --body (#504)"
fi
# 504c: /complete-directive step 5 posts the closing comment via --body-file.
if grep -qF -- '--body-file' "$S504_CD" 2>/dev/null; then
  ok "504c: /complete-directive posts the closing comment via --body-file (#504)"
else
  ng "504c: /complete-directive closing comment not specified via --body-file (#504)"
fi
# 504d: /work-on resolves the default branch for the Closes/Refs trailer (not a
# hardcoded `main`), so a master/release-default target routes the trailer right.
if grep -qE 'defaultBranchRef' "$S504_WO" 2>/dev/null && ! grep -qE '\[ "\$BASE" != "main" \]' "$S504_WO" 2>/dev/null; then
  ok "504d: /work-on resolves the default branch for Closes/Refs (not literal main) (#504)"
else
  ng "504d: /work-on still hardcodes 'main' for the Closes/Refs trailer (#504)"
fi

# 43-archive-marker (#80): /revise-directive must name the archive comment
# marker exactly as §5.16 specifies.
if grep -qF "## Pre-revision body — archived" "$SHELL_ROOT/.claude/commands/revise-directive.md" 2>/dev/null; then
  ok "43-archive-marker: /revise-directive names the canonical archive comment marker (#80)"
else
  ng "43-archive-marker: /revise-directive must name the '## Pre-revision body — archived <ISO date>' marker (#80)"
fi

# 43-blocked-marker (#80): /block-directive must name the block comment marker
# exactly as §5.17 specifies.
if grep -qF "## Blocked:" "$SHELL_ROOT/.claude/commands/block-directive.md" 2>/dev/null; then
  ok "43-blocked-marker: /block-directive names the canonical '## Blocked: <reason>' marker (#80)"
else
  ng "43-blocked-marker: /block-directive must name the '## Blocked: <reason>' marker (#80)"
fi

# ---------- 44. Type-aware hooks + proposed-protect matcher (#46, #171) ----------
# PR #46 wired Type-awareness into pre_tool_use.sh; #171 generalized the matcher
# directive-protect → proposed-protect. The matcher blocks branch creation when
# the target Issue is `status:proposed` (any type) OR a Directive (any status) —
# subsuming, not replacing, the old Directive-only check (a status-only check
# would let an Active Directive branch, a §10.5 regression). Smoke covers:
#   44a: proposed Directive (directive + status:proposed)        → block.
#   44b: non-proposed non-Directive Issue                        → allow.
#   44c: Active Directive (directive, NO status:proposed)        → block (§10.5 guard).
#   44d: proposed Execution Issue (task + status:proposed)       → block (symmetry, #171).
#   44e: is_proposed_issue does NOT cache (flips when label removed; volatile).
#   44f: fail-open — gh unavailable → allow (no spurious block).
#   44g: SKIP_HOOKS=proposed-protect bypasses the block.
#
# Mock strategy: PATH-overlay mock `gh` returns canned labels per issue.
# GH_MOCK_FAIL=1 makes the mock exit non-zero (simulates gh down / no auth).

DP_DIR=$(mktemp -d)
DP_BIN="$DP_DIR/bin"
DP_TARGET="$DP_DIR/target"
# #357: dp_run's hook fires under the whole-run override (CLAUDE_PROJECT_DIR
# unset), so is_directive_issue caches to $SMOKE_STATE, not the legacy path.
DP_CACHE="$SMOKE_STATE/issue-type-cache"
mkdir -p "$DP_BIN" "$DP_TARGET"
DP_TARGET=$(cd "$DP_TARGET" && pwd -P)
(cd "$DP_TARGET" && git init -q) || true
DP_AUDIT="$DP_DIR/audit.jsonl"

# Register DP_TARGET so cwd_guard accepts it (matches the §41 pattern).
DP_REGISTRY="$SMOKE_REG"
printf '%s\n' "$DP_TARGET" >> "$DP_REGISTRY"

cat > "$DP_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh for §44. Inspects $GH_MOCK_LABELS_<n> (e.g. GH_MOCK_LABELS_42="directive,enhancement")
# to decide what `gh issue view <n> --json labels` returns. `gh repo view`
# returns a fixed smoke-owner/smoke-repo. Honors the `-q <jq-expr>` flag the
# real gh exposes — so callers that pass `-q .owner.login` get just the value.
emit() {
  # $1 = full JSON; the rest of argv contains the original flags. Look for
  # -q <expr> and apply via jq if present; otherwise emit the full JSON.
  local full="$1"; shift
  local expr=""
  local next=0
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
# Simulate gh unavailable (network down / no auth) for the fail-open assertion.
if [ "${GH_MOCK_FAIL:-}" = 1 ]; then exit 1; fi
case "${1:-}" in
  repo)
    if [ "${2:-}" = view ]; then
      emit '{"owner":{"login":"smoke-owner"},"name":"smoke-repo"}' "$@"
    fi
    ;;
  issue)
    if [ "${2:-}" = view ]; then
      issue="$3"
      var="GH_MOCK_LABELS_${issue}"
      labels="${!var:-}"
      arr="["; first=1; old_ifs="$IFS"; IFS=,
      for l in $labels; do
        [ -z "$l" ] && continue
        [ "$first" = 1 ] && first=0 || arr="$arr,"
        arr="$arr{\"name\":\"$l\"}"
      done
      IFS="$old_ifs"; arr="$arr]"
      emit "{\"labels\":$arr}" "$@"
    fi
    ;;
  pr)
    if [ "${2:-}" = view ]; then
      emit "{\"closingIssuesReferences\":[${GH_MOCK_PR_CLOSING:-}]}" "$@"
    fi
    ;;
esac
exit 0
MOCK
chmod +x "$DP_BIN/gh"

dp_run() {
  # $1 = cmd string passed in as Bash tool input; $2 (optional) = SKIP_HOOKS value
  local cmd="$1" skip="${2:-}"
  # pre_tool_use.sh expects JSON on stdin with .tool_input.command for Bash.
  local stdin_json
  stdin_json=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd")
  (
    cd "$DP_TARGET" || exit 0
    PATH="$DP_BIN:$PATH" \
    GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
    AUDIT_LOG_PATH="$DP_AUDIT" \
    GH_MOCK_LABELS_91="directive,enhancement" \
    GH_MOCK_LABELS_92="enhancement" \
    GH_MOCK_LABELS_93="directive" \
    GH_MOCK_LABELS_94="task,status:proposed" \
    GH_MOCK_LABELS_95="directive,status:proposed" \
    GH_MOCK_FAIL="${GH_MOCK_FAIL:-}" \
    SKIP_HOOKS="$skip" \
    SKIP_REASON="${skip:+smoke-test}" \
      bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" <<< "$stdin_json"
  )
  return $?
}

# Clear cache so each assertion starts fresh.
rm -rf "$DP_CACHE"

rm -rf "$DP_CACHE"

# 44a: proposed Directive (#95: directive,status:proposed) → block.
rc=0
dp_run "git checkout -b ilgyu-yi/feat/95-foo" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "44a: proposed-protect blocks branch on proposed Directive #95 (#171)" \
              || ng "44a: expected block(2) on proposed Directive #95; got rc=$rc (#171)"

# 44b: non-proposed non-Directive (#92: enhancement) → allow.
rc=0
dp_run "git checkout -b ilgyu-yi/feat/92-bar" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "44b: proposed-protect allows branch on non-proposed non-Directive #92 (#171)" \
              || ng "44b: expected allow(0) on #92; got rc=$rc (#171)"

# 44c: Active Directive (#91: directive, NO status:proposed) → block. §10.5 REGRESSION GUARD:
#      proves proposed-protect SUBSUMES (not replaces) the Directive check — a status-only
#      matcher would allow this and let an Active Directive branch.
rc=0
dp_run "git checkout -b ilgyu-yi/feat/91-foo" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "44c: proposed-protect still blocks branch on Active Directive #91 (§10.5 guard) (#171)" \
              || ng "44c: expected block(2) on Active Directive #91 — §10.5 REGRESSION; got rc=$rc (#171)"

# 44d: proposed Execution Issue (#94: task,status:proposed) → block. The symmetry case #171 adds.
rc=0
dp_run "git checkout -b ilgyu-yi/feat/94-baz" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "44d: proposed-protect blocks branch on proposed Execution Issue #94 (symmetry) (#171)" \
              || ng "44d: expected block(2) on proposed Execution #94; got rc=$rc (#171)"

# 44e: is_proposed_issue does NOT cache — flips PROPOSED→NOT when the label is removed
#      (mirrors /activate), proving no stale cache keeps an activated Issue blocked.
rm -rf "$DP_CACHE"
dp_pred() {
  ( cd "$DP_TARGET" || exit 0
    PATH="$DP_BIN:$PATH" GHJIG_ROOT="$SHELL_ROOT" GH_MOCK_LABELS_94="$1" \
      bash -c '. "$GHJIG_ROOT/.claude/hooks/helpers/issue_type.sh"; is_proposed_issue 94 && echo PROPOSED || echo NOT' 2>/dev/null )
}
pp_first=$(dp_pred "task,status:proposed")
pp_second=$(dp_pred "task")
if [ "$pp_first" = PROPOSED ] && [ "$pp_second" = NOT ]; then
  ok "44e: is_proposed_issue re-queries each call (no stale cache; PROPOSED->NOT on label removal) (#171)"
else
  ng "44e: is_proposed_issue caching regression; first=$pp_first second=$pp_second (#171)"
fi

# 44f: fail-open — gh unavailable (GH_MOCK_FAIL=1) → allow even a would-be-blocked Directive.
rm -rf "$DP_CACHE"
rc=0
GH_MOCK_FAIL=1 dp_run "git checkout -b ilgyu-yi/feat/91-foo" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "44f: proposed-protect fails open (allow) when gh is unavailable (#171)" \
              || ng "44f: expected fail-open allow(0) on gh failure; got rc=$rc (#171)"

# 44g: SKIP_HOOKS=proposed-protect bypasses the block.
rc=0
dp_run "git checkout -b ilgyu-yi/feat/95-foo" "proposed-protect" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "44g: SKIP_HOOKS=proposed-protect bypasses the block (#171)" \
              || ng "44g: SKIP_HOOKS=proposed-protect should allow; got rc=$rc (#171)"

# 44h: is_directive_issue STILL caches per-session (preserves #46 coverage; contrast with 44e).
rm -rf "$DP_CACHE"
dp_run "git checkout -b ilgyu-yi/feat/91-foo" >/dev/null 2>&1 || true
if [ -f "$DP_CACHE/smoke-owner__smoke-repo__91" ] && [ "$(cat "$DP_CACHE/smoke-owner__smoke-repo__91" 2>/dev/null)" = directive ]; then
  ok "44h: is_directive_issue caches type per-issue (#46/#171)"
else
  ng "44h: is_directive_issue cache missing/wrong for #91 (#46/#171)"
fi

# 44i (#212): is_directive_issue anchors on comma-list boundaries, not a grep
# word-match. A label like `non-directive` (hyphen is a grep word boundary) must
# NOT be classified as a Directive; a bare `directive` anywhere in the list must.
s212_isdir() {  # $1=labels → echoes directive|execution
  (
    export GHJIG_ROOT="$TMP/s212root"
    unset GHJIG_STATE_DIR_OVERRIDE   # #357: cache must ride this subshell's own GHJIG_ROOT, not $SMOKE_STATE
    rm -rf "$GHJIG_ROOT/.claude/state/issue-type-cache" 2>/dev/null
    mkdir -p "$GHJIG_ROOT/.claude/state"
    s212_lbl="$1"
    gh() {
      case "$*" in
        *'repo view'*owner*) printf 'smoke-owner\n' ;;
        *'repo view'*name*) printf 'smoke-repo\n' ;;
        *'issue view'*) printf '%s\n' "$s212_lbl" ;;
        *) return 0 ;;
      esac
    }
    . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"
    is_directive_issue 700 && echo directive || echo execution
  )
}
[ "$(s212_isdir 'non-directive')" = execution ] \
  && ok "44i: is_directive_issue does not mis-classify 'non-directive' as a Directive (#212)" \
  || ng "44i: 'non-directive' mis-classified (word-match over-match) (#212)"
[ "$(s212_isdir 'directive')" = directive ] \
  && ok "44i: bare 'directive' label classified as Directive (#212)" \
  || ng "44i: bare 'directive' not classified as Directive (#212)"
[ "$(s212_isdir 'task,directive')" = directive ] \
  && ok "44i: 'directive' as a comma-list element classified as Directive (#212)" \
  || ng "44i: comma-list 'directive' not classified (#212)"
[ "$(s212_isdir 'bug,task')" = execution ] \
  && ok "44i: comma list without 'directive' is execution (#212)" \
  || ng "44i: non-directive comma list mis-classified (#212)"

# 44j (#249): is_initiative_issue keys on the `initiative` label, symmetric to
# is_directive_issue. Self-contained function-mock (mirrors 44i's s212_isdir).
m1_pred() {  # $1=labels $2=predicate-fn → echoes YES|NO
  (
    export GHJIG_ROOT="$TMP/m1root"
    unset GHJIG_STATE_DIR_OVERRIDE   # #357: cache must ride this subshell's own GHJIG_ROOT, not $SMOKE_STATE
    rm -rf "$GHJIG_ROOT/.claude/state/issue-type-cache" 2>/dev/null
    mkdir -p "$GHJIG_ROOT/.claude/state"
    m1_lbl="$1"
    gh() {
      case "$*" in
        *'repo view'*owner*) printf 'smoke-owner\n' ;;
        *'repo view'*name*) printf 'smoke-repo\n' ;;
        *'issue view'*) printf '%s\n' "$m1_lbl" ;;
        *) return 0 ;;
      esac
    }
    . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"
    "$2" 700 && echo YES || echo NO
  )
}
[ "$(m1_pred 'initiative' is_initiative_issue)" = YES ] \
  && ok "44j: is_initiative_issue true on initiative label (#249)" \
  || ng "44j: is_initiative_issue missed initiative label (#249)"
[ "$(m1_pred 'task' is_initiative_issue)" = NO ] \
  && ok "44j: is_initiative_issue false on non-initiative label (#249)" \
  || ng "44j: is_initiative_issue mis-fired on task (#249)"
[ "$(m1_pred 'initiative-foo' is_initiative_issue)" = NO ] \
  && ok "44j: is_initiative_issue does not over-match 'initiative-foo' (#249)" \
  || ng "44j: is_initiative_issue over-matched 'initiative-foo' (#249)"

# 44k (#249): the two type predicates resolve INDEPENDENTLY (no cache collision /
# no cross-classification) — directive→directive-yes/initiative-no, and vice-versa.
[ "$(m1_pred 'directive' is_directive_issue)" = YES ] && [ "$(m1_pred 'directive' is_initiative_issue)" = NO ] \
  && ok "44k: directive label → is_directive yes, is_initiative no (#249)" \
  || ng "44k: directive label cross-classified (#249)"
[ "$(m1_pred 'initiative' is_initiative_issue)" = YES ] && [ "$(m1_pred 'initiative' is_directive_issue)" = NO ] \
  && ok "44k: initiative label → is_initiative yes, is_directive no (#249)" \
  || ng "44k: initiative label cross-classified (#249)"

# 44l (#249): is_initiative_issue fails open (gh unavailable → not-initiative).
m1_failopen() {
  ( export GHJIG_ROOT="$TMP/m1root2"; mkdir -p "$GHJIG_ROOT/.claude/state"
    gh() { return 1; }
    . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"
    is_initiative_issue 700 && echo YES || echo NO )
}
[ "$(m1_failopen)" = NO ] \
  && ok "44l: is_initiative_issue fails open (gh down → not-initiative) (#249)" \
  || ng "44l: is_initiative_issue fail-open regression (#249)"

# 44m (#249): issue_has_initiative_parent_marker — tri-state on the line-1
# `Parent Initiative: #N` marker. Distinct from the Parent Directive resolver
# (a Parent Directive line is NOT an initiative marker → rc 1).
m1_marker() {  # $1=body → echoes rc
  ( export GHJIG_ROOT="$TMP/m1root3"; mkdir -p "$GHJIG_ROOT/.claude/state"
    m1_body="$1"
    gh() {
      case "$*" in
        *'issue view'*'--json body'*) printf '%s\n' "$m1_body" ;;
        *) return 0 ;;
      esac
    }
    . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"
    issue_has_initiative_parent_marker 700; echo $? )
}
[ "$(m1_marker 'Parent Initiative: #42')" = 0 ] \
  && ok "44m: line-1 'Parent Initiative: #N' recognized (rc 0) (#249)" \
  || ng "44m: initiative parent marker not recognized (#249)"
[ "$(m1_marker 'Parent Directive: #42')" = 1 ] \
  && ok "44m: 'Parent Directive' is NOT an initiative marker (rc 1) (#249)" \
  || ng "44m: Parent Directive mis-read as initiative marker (#249)"
[ "$(m1_marker 'Some other first line')" = 1 ] \
  && ok "44m: absent initiative marker → rc 1 (#249)" \
  || ng "44m: absent-marker rc wrong (#249)"
m1_marker_fail() {
  ( export GHJIG_ROOT="$TMP/m1root4"; mkdir -p "$GHJIG_ROOT/.claude/state"
    gh() { return 1; }
    . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"
    issue_has_initiative_parent_marker 700; echo $? )
}
[ "$(m1_marker_fail)" = 2 ] \
  && ok "44m: marker resolver unresolvable → rc 2 (fail-open) (#249)" \
  || ng "44m: marker fail-open rc wrong (#249)"

# 505d (#505 / Directive #498): the line-1 parent markers must tolerate a trailing
# CRLF \r (Windows editor / paste), else a parented Issue mis-resolves as
# marker-ABSENT — letting label-parent-consistency mislabel it standalone.
m1d_marker() {  # $1=body → echoes issue_has_parent_marker rc
  ( export GHJIG_ROOT="$TMP/m1root5"; mkdir -p "$GHJIG_ROOT/.claude/state"
    m1_body="$1"
    gh() { case "$*" in *'issue view'*'--json body'*) printf '%s\n' "$m1_body" ;; *) return 0 ;; esac; }
    . "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"
    issue_has_parent_marker 700; echo $? )
}
[ "$(m1d_marker "$(printf 'Parent Directive: #42\r')")" = 0 ] \
  && ok "505d: CRLF-terminated 'Parent Directive: #N' still recognized (#505)" \
  || ng "505d: CRLF \\r breaks the Parent Directive marker → mis-resolve (#505)"
[ "$(m1d_marker 'Parent Directive: #42')" = 0 ] \
  && ok "505d2: LF 'Parent Directive: #N' still recognized (regression) (#505)" \
  || ng "505d2: LF Parent Directive marker regressed (#505)"

# Cleanup: remove cache entries created by §44 so they don't leak.
rm -f "$DP_CACHE/smoke-owner__smoke-repo__91" "$DP_CACHE/smoke-owner__smoke-repo__92" "$DP_CACHE/smoke-owner__smoke-repo__93" "$DP_CACHE/smoke-owner__smoke-repo__94" "$DP_CACHE/smoke-owner__smoke-repo__95"
# Remove the test target from the registry so other tests aren't affected.
if [ -f "$DP_REGISTRY" ]; then
  dp_tmp_reg=$(mktemp)
  grep -vxF "$DP_TARGET" "$DP_REGISTRY" > "$dp_tmp_reg" 2>/dev/null || true
  mv "$dp_tmp_reg" "$DP_REGISTRY"
fi
rm -rf "$DP_DIR"

# ---------- 45. /file-issue + /reflect + /ship dir-mode integrations (#47) ----------
# PR #47 wires the three existing engineering commands into the dir-mode
# layer. Since these are Markdown procedural prompts (Claude follows them),
# the testable contract is structural: each command names the integration
# step, the regex it consumes, and the audit category it emits.

# 45a: /file-issue has the --parent flag in argument-hint and step 1.5.
if grep -qF -- '--parent' "$SHELL_ROOT/.claude/commands/file-issue.md" \
   && grep -qF 'Directive parenting' "$SHELL_ROOT/.claude/commands/file-issue.md" \
   && grep -qF 'Parent Directive: #' "$SHELL_ROOT/.claude/commands/file-issue.md"; then
  ok "45a: /file-issue documents --parent flag + Parent Directive marker (#47)"
else
  ng "45a: /file-issue missing --parent or Parent Directive integration (#47)"
fi

# 45b: /ship step 10.5 audits directive-exec-count on clean-branch merges.
if grep -qF 'directive-exec-count' "$SHELL_ROOT/.claude/commands/ship.md" \
   && grep -qF 'does NOT flip' "$SHELL_ROOT/.claude/commands/ship.md"; then
  ok "45b: /ship 10.5 audits directive-exec-count + asserts no auto-completion (#47)"
else
  ng "45b: /ship missing directive-exec-count audit or no-auto-complete assertion (#47)"
fi

# 45c: /reflect exists with frontmatter + parent-Directive idempotency.
if [ -f "$SHELL_ROOT/.claude/commands/reflect.md" ] \
   && grep -qE '^description:' "$SHELL_ROOT/.claude/commands/reflect.md" \
   && grep -qE '^argument-hint:' "$SHELL_ROOT/.claude/commands/reflect.md" \
   && grep -qF 'idempotent' "$SHELL_ROOT/.claude/commands/reflect.md" \
   && grep -qF 'Parent Directive: #' "$SHELL_ROOT/.claude/commands/reflect.md"; then
  ok "45c: /reflect.md has frontmatter + Parent Directive regex + idempotency rule (#47)"
else
  ng "45c: /reflect.md missing frontmatter or expected sections (#47)"
fi

# 45d: /reflect names its audit categories (directive-reflect for posted + skipped).
if grep -qF 'directive-reflect' "$SHELL_ROOT/.claude/commands/reflect.md" 2>/dev/null; then
  ok "45d: /reflect names audit category 'directive-reflect' (#47)"
else
  ng "45d: /reflect does not name audit category 'directive-reflect' (#47)"
fi

# 45f (#329): /reflect classifies by content marker (not the shared PR URL) and
# enriches the workflow stub IN PLACE — locks both markers, the PATCH mechanism,
# and the enrich-in-place branch (the fix for the URL-keyed permanent-stub bug).
RF329="$SHELL_ROOT/.claude/commands/reflect.md"
if grep -qF 'reflect-stub' "$RF329" && grep -qF 'reflect-enriched' "$RF329" \
   && grep -qF 'gh api -X PATCH' "$RF329" \
   && grep -qiF 'enrich in place' "$RF329"; then
  ok "45f: /reflect enriches the workflow stub in place via content markers (#329)"
else
  ng "45f: /reflect missing marker-based enrich-in-place contract (#329)"
fi

# 45e: /file-issue parents via /link-directive to keep linkage idempotent.
if grep -qF '/link-directive' "$SHELL_ROOT/.claude/commands/file-issue.md" 2>/dev/null; then
  ok "45e: /file-issue routes Project parenting through /link-directive (#47)"
else
  ng "45e: /file-issue does not route through /link-directive (#47)"
fi

# ---------- 46. issue-reviewer Type-aware open-issues scan (#55) ----------
# PR #55 fixes a bug where issue-reviewer's existing-coverage check could
# spuriously refine/block a proposed Execution Issue because an open
# Directive (now part of the open-issues set after v0 dir-mode landed)
# matched as duplicate. The fix is documentation: the agent file now
# instructs the reviewer to exclude `-label:directive` at fetch time and
# to treat any `Parent Directive: #<D>` declaration as umbrella-not-dup.
IR_PATH="$SHELL_ROOT/.claude/agents/issue-reviewer.md"
if [ ! -f "$IR_PATH" ]; then
  ng "46: issue-reviewer.md missing (#55)"
else
  # 46a: open-issues fetch instruction includes the `-label:directive` exclusion.
  if grep -qF -- '-label:directive' "$IR_PATH"; then
    ok "46a: issue-reviewer fetches with -label:directive exclusion (#55)"
  else
    ng "46a: issue-reviewer fetch does not exclude Type=Directive (#55)"
  fi

  # 46b: Existing-coverage paragraph documents the Parent-Directive umbrella case.
  if grep -qF 'Parent Directive' "$IR_PATH"; then
    ok "46b: issue-reviewer documents the Parent Directive umbrella case (#55)"
  else
    ng "46b: issue-reviewer does not document Parent Directive umbrella case (#55)"
  fi

  # 46c: No regression — the three VERDICT-line forms remain documented.
  if grep -qE '^- `VERDICT: ship' "$IR_PATH" \
     && grep -qE '^- `VERDICT: refine' "$IR_PATH" \
     && grep -qE '^- `VERDICT: block' "$IR_PATH"; then
    ok "46c: issue-reviewer VERDICT-line format unchanged (ship/refine/block) (#55)"
  else
    ng "46c: issue-reviewer VERDICT-line format broken (#55)"
  fi
fi

# ---------- 47. SPEC §5.15 /reflect stub (#57) ----------
# PR #53 introduced /reflect as a Markdown command but did not add a
# numbered SPEC subsection. /ship step 10.5 and reflect.md both reference
# "SPEC §5.15" — this assertion locks the section's existence so the
# cross-references resolve.
if grep -qE '^### 5\.15 `/reflect' "$SHELL_ROOT/SPEC.md"; then
  ok "47: SPEC §5.15 /reflect stub present (#57)"
else
  ng "47: SPEC §5.15 /reflect stub missing — /ship step 10.5 and reflect.md reference it (#57)"
fi

# ---------- 48. dir-mode-post-merge workflow contract (#63 / Directive #61) ----------
# Directive #61 ships a hook-enforced post-merge path. v0's audit + reflection
# only fired when Claude was the merger; this workflow fires on every
# pull_request.closed && merged == true event. The canonical template lives
# under target-substrate/workflows/ (the home every substrate workflow shares,
# #348 removed the pre-target-substrate root copy) and the dogfooded
# installation lives in .github/workflows/. §48 locks the contract: file
# existence, trigger shape, Parent Directive regex consumer, exec-count token.

DPM_TEMPLATE="$SHELL_ROOT/.claude/templates/target-substrate/workflows/dir-mode-post-merge.yml"
DPM_INSTALL="$SHELL_ROOT/.github/workflows/dir-mode-post-merge.yml"

if [ ! -f "$DPM_TEMPLATE" ]; then
  ng "48: target-substrate/workflows/dir-mode-post-merge.yml missing (#63 / #348)"
elif [ ! -f "$DPM_INSTALL" ]; then
  ng "48: .github/workflows/dir-mode-post-merge.yml missing (dogfood install) (#63)"
else
  # 48a: trigger is pull_request.closed.
  if grep -qF 'types: [closed]' "$DPM_TEMPLATE" \
     && grep -qE '^on:[[:space:]]*$' "$DPM_TEMPLATE" \
     && grep -qE '^[[:space:]]+pull_request:' "$DPM_TEMPLATE"; then
    ok "48a: workflow triggers on pull_request.closed (#63)"
  else
    ng "48a: workflow missing pull_request.closed trigger (#63)"
  fi

  # 48b: merged-true guard present.
  if grep -qF 'github.event.pull_request.merged == true' "$DPM_TEMPLATE"; then
    ok "48b: workflow guards on merged == true (#63)"
  else
    ng "48b: workflow missing merged == true guard (#63)"
  fi

  # 48c: parses Parent Directive marker via the canonical regex.
  if grep -qF 'Parent Directive' "$DPM_TEMPLATE"; then
    ok "48c: workflow parses Parent Directive marker (#63)"
  else
    ng "48c: workflow does not parse Parent Directive (#63)"
  fi

  # 48d: emits directive-exec-count audit line in the reflection comment.
  if grep -qF 'directive-exec-count' "$DPM_TEMPLATE"; then
    ok "48d: workflow comment carries directive-exec-count audit line (#63)"
  else
    ng "48d: workflow comment missing directive-exec-count token (#63)"
  fi

  # 48e: idempotency check on existing PR-URL in Directive's comments.
  if grep -qF 'PR_URL' "$DPM_TEMPLATE" && grep -qiF 'already reflected' "$DPM_TEMPLATE"; then
    ok "48e: workflow has existing-URL idempotency check (#63)"
  else
    ng "48e: workflow missing idempotency check (#63)"
  fi

  # 48f: dogfood install matches the canonical target-substrate template (byte-for-byte).
  if cmp -s "$DPM_TEMPLATE" "$DPM_INSTALL"; then
    ok "48f: .github/workflows/ install matches target-substrate canonical source (#63 / #348)"
  else
    ng "48f: workflow install drifts from the target-substrate template (#63 / #348)"
  fi

  # 48h (#329): the reflection stub carries the reflect-stub marker + the corrected
  # in-place-edit wording, and the false "will replace this comment's content"
  # claim is gone (the bug was the stub claiming /reflect would replace it while
  # /reflect's URL-keyed idempotency made it no-op). Checked on the install; 48f
  # cmp-locks the template to match.
  if grep -qF 'reflect-stub pr=#' "$DPM_INSTALL" \
     && grep -qF 'edits this comment in place' "$DPM_INSTALL" \
     && ! grep -qF 'will replace this comment' "$DPM_INSTALL"; then
    ok "48h: reflection stub carries reflect-stub marker + in-place-edit wording, no false replace claim (#329)"
  else
    ng "48h: workflow reflection-stub marker/wording wrong (#329)"
  fi

  # 48i (#329): the target-substrate workflow copy is the canonical install source
  # for onboarded target repos. Post-#348 it is also DPM_TEMPLATE (cmp-locked to the
  # dogfood copy by 48f), so this is a direct belt-and-suspenders check that the
  # canonical copy carries the #329 fix — else targets would install the buggy stub.
  DPM_TARGETSUB="$SHELL_ROOT/.claude/templates/target-substrate/workflows/dir-mode-post-merge.yml"
  if [ -f "$DPM_TARGETSUB" ]; then
    if grep -qF 'reflect-stub pr=#' "$DPM_TARGETSUB" \
       && ! grep -qF 'will replace this comment' "$DPM_TARGETSUB" \
       && ! grep -qF 'dedupes across both paths' "$DPM_TARGETSUB"; then
      ok "48i: target-substrate workflow copy carries the #329 reflect-stub fix (#329)"
    else
      ng "48i: target-substrate workflow copy missing the #329 fix (targets would install the bug) (#329)"
    fi
  else
    ng "48i: target-substrate workflow copy not found (#329)"
  fi

  # 48g: every `gh <subcommand>` in the workflow carries --repo (#66 fix).
  # The runner has no checkout step; gh would otherwise read git context from
  # cwd and fail. Lock the --repo flag on every gh invocation. The pattern
  # matches gh-with-subcommand anywhere on a line (including inside $(...)
  # substitutions) so multi-line gh calls (continuation with backslash) count.
  gh_calls=$(grep -cE '\bgh[[:space:]]+(pr|issue|repo|project|api|auth|run|workflow|release|search|label)\b' "$DPM_TEMPLATE" 2>/dev/null || echo 0)
  gh_with_repo=$(grep -cE '\bgh[[:space:]]+(pr|issue|repo|project|api|auth|run|workflow|release|search|label)\b.*--repo' "$DPM_TEMPLATE" 2>/dev/null || echo 0)
  if [ "$gh_calls" -gt 0 ] && [ "$gh_calls" = "$gh_with_repo" ]; then
    ok "48g: all $gh_calls gh invocations carry --repo flag (no-checkout runner) (#66)"
  else
    ng "48g: $gh_calls gh invocations but only $gh_with_repo carry --repo — runner will fail without git context (#66)"
  fi
fi

# ---------- 48j. label-aware reflection resolver helper (#335) ----------
# The post-merge resolver used to post to the FIRST `Parent Directive: #N`
# marker among a PR's closing issues without checking N is `directive`-labelled,
# so nested-umbrella work mis-targeted the umbrella. #335 extracts the resolution
# into a sourceable, smoke-executed helper that climbs to the first
# `directive`-labelled ancestor (depth-cap 2, cycle guard, fail-soft). Three
# byte-identical copies: canonical scripts/lib + this-repo .github/workflows
# runtime + target-substrate (shipped into onboarded targets).
DPM_RESOLVER_CANON="$SHELL_ROOT/scripts/lib/resolve_parent_directive.sh"
DPM_RESOLVER_INSTALL="$SHELL_ROOT/.github/workflows/resolve_parent_directive.sh"
DPM_RESOLVER_TARGETSUB="$SHELL_ROOT/.claude/templates/target-substrate/workflows/resolve_parent_directive.sh"

if [ ! -f "$DPM_RESOLVER_CANON" ]; then
  ng "48j: scripts/lib/resolve_parent_directive.sh missing (#335)"
else
  RPD_DIR=$(mktemp -d)
  RPD_SHIM="$RPD_DIR/bin"
  RPD_STATE="$RPD_DIR/state"
  mkdir -p "$RPD_SHIM" "$RPD_STATE"

  # Fake gh: returns the post-`--jq` values the resolver expects. Closing list,
  # per-issue body, and per-issue labels are keyed by fixture files in RPD_STATE.
  cat > "$RPD_SHIM/gh" <<'SHIM'
#!/bin/sh
args="$*"
case "$args" in
  *"pr view"*closingIssuesReferences*)
    [ -f "$RPD_STATE/closing" ] && cat "$RPD_STATE/closing"
    exit 0 ;;
  *"issue view"*labels*)
    n=$(printf '%s\n' "$args" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
    [ -n "$n" ] && [ -f "$RPD_STATE/labels_$n" ] && cat "$RPD_STATE/labels_$n"
    exit 0 ;;
  *"issue view"*body*)
    n=$(printf '%s\n' "$args" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
    [ -n "$n" ] && [ -f "$RPD_STATE/body_$n" ] && cat "$RPD_STATE/body_$n"
    exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$RPD_SHIM/gh"

  rpd_reset() { rm -f "$RPD_STATE"/closing "$RPD_STATE"/body_* "$RPD_STATE"/labels_* 2>/dev/null || true; }
  rpd_call() {
    PATH="$RPD_SHIM:$PATH" RPD_STATE="$RPD_STATE" \
      bash -c '. "$1"; resolve_parent_directive "$2" "$3"' _ "$DPM_RESOLVER_CANON" "$1" "mock/repo" 2>/dev/null
  }

  # Case 1 — direct execution → Directive (the common case; resolves at hop 1).
  rpd_reset
  printf '11\n' > "$RPD_STATE/closing"
  printf 'Parent Directive: #20\n' > "$RPD_STATE/body_11"
  printf 'directive\n' > "$RPD_STATE/labels_20"
  out=$(rpd_call 901)
  if printf '%s' "$out" | grep -qx 'directive=20' && printf '%s' "$out" | grep -qx 'exec_issue=11'; then
    ok "48j-1: direct execution resolves to its Directive (#335)"
  else
    ng "48j-1: direct execution mis-resolved: '$out' (#335)"
  fi

  # Case 2 — REPRODUCTION: nested umbrella. The closing issue points at an
  # umbrella (#30, not directive-labelled) that itself points at the Directive
  # (#40). Must climb PAST the umbrella to #40, not stop at #30.
  rpd_reset
  printf '12\n' > "$RPD_STATE/closing"
  printf 'Parent Directive: #30\n' > "$RPD_STATE/body_12"
  printf 'execution\n' > "$RPD_STATE/labels_30"
  printf 'Parent Directive: #40\n' > "$RPD_STATE/body_30"
  printf 'directive\n' > "$RPD_STATE/labels_40"
  out=$(rpd_call 902)
  if printf '%s' "$out" | grep -qx 'directive=40'; then
    ok "48j-2: nested umbrella climbs to the grandparent Directive (#335)"
  else
    ng "48j-2: nested umbrella mis-targeted (expected directive=40): '$out' (#335)"
  fi

  # Case 3 — cycle (no directive in the chain) → empty, no hang (depth-cap +
  # visited guard).
  rpd_reset
  printf '13\n' > "$RPD_STATE/closing"
  printf 'Parent Directive: #50\n' > "$RPD_STATE/body_13"
  printf 'execution\n' > "$RPD_STATE/labels_50"
  printf 'Parent Directive: #60\n' > "$RPD_STATE/body_50"
  printf 'execution\n' > "$RPD_STATE/labels_60"
  printf 'Parent Directive: #50\n' > "$RPD_STATE/body_60"
  out=$(rpd_call 903)
  if ! printf '%s' "$out" | grep -q 'directive='; then
    ok "48j-3: cyclic non-directive chain resolves to nothing (#335)"
  else
    ng "48j-3: cyclic chain wrongly resolved: '$out' (#335)"
  fi

  # Case 4 — non-directive dead-end (chain ends at a non-directive issue with no
  # further marker) → empty.
  rpd_reset
  printf '14\n' > "$RPD_STATE/closing"
  printf 'Parent Directive: #70\n' > "$RPD_STATE/body_14"
  printf 'execution\n' > "$RPD_STATE/labels_70"
  printf 'no marker here\n' > "$RPD_STATE/body_70"
  out=$(rpd_call 904)
  if ! printf '%s' "$out" | grep -q 'directive='; then
    ok "48j-4: non-directive dead-end resolves to nothing (#335)"
  else
    ng "48j-4: dead-end wrongly resolved: '$out' (#335)"
  fi

  # 48j-sync: the three resolver copies are byte-identical (cmp-lock, the §48f
  # discipline applied to the helper).
  if [ -f "$DPM_RESOLVER_INSTALL" ] && [ -f "$DPM_RESOLVER_TARGETSUB" ] \
     && cmp -s "$DPM_RESOLVER_CANON" "$DPM_RESOLVER_INSTALL" \
     && cmp -s "$DPM_RESOLVER_CANON" "$DPM_RESOLVER_TARGETSUB"; then
    ok "48j-sync: 3 resolver copies (scripts/lib + .github/workflows + target-substrate) byte-identical (#335)"
  else
    ng "48j-sync: resolver copies missing or drifted (#335)"
  fi

  # 48j-repo: every gh call in the helper carries --repo (the §48g invariant now
  # that the gh calls live in the helper, not the run-block).
  hgh=$(grep -cE '\bgh[[:space:]]+(pr|issue)\b' "$DPM_RESOLVER_CANON" 2>/dev/null || echo 0)
  hghrepo=$(grep -cE '\bgh[[:space:]]+(pr|issue)\b.*--repo' "$DPM_RESOLVER_CANON" 2>/dev/null || echo 0)
  if [ "$hgh" -gt 0 ] && [ "$hgh" = "$hghrepo" ]; then
    ok "48j-repo: all $hgh helper gh calls carry --repo (#335)"
  else
    ng "48j-repo: $hgh helper gh calls, only $hghrepo carry --repo (#335)"
  fi

  # 48j-noop: the helper emits a visible no-op note when nothing resolves
  # (today's inline resolver was silent).
  if grep -qiE 'no .*directive|no-op|nothing to' "$DPM_RESOLVER_CANON"; then
    ok "48j-noop: helper logs a visible no-op on empty resolution (#335)"
  else
    ng "48j-noop: helper has no visible no-op log (#335)"
  fi

  rm -rf "$RPD_DIR" 2>/dev/null || true
fi

# 48k: all three dir-mode-post-merge.yml copies source the helper after an
# actions/checkout, guard the source with `[ -f ]` (missing helper degrades to
# no-reflection, not a failed Action), and no longer claim "No actions/checkout".
dpm_wf_ok=1
for wf in "$DPM_INSTALL" "$DPM_TEMPLATE" "$SHELL_ROOT/.claude/templates/target-substrate/workflows/dir-mode-post-merge.yml"; do
  [ -f "$wf" ] || { dpm_wf_ok=0; continue; }
  grep -qF 'actions/checkout' "$wf" || dpm_wf_ok=0
  grep -qF 'resolve_parent_directive.sh' "$wf" || dpm_wf_ok=0
  grep -qE '\[ -f ' "$wf" || dpm_wf_ok=0   # the source is guarded by a file-existence check
done
if [ "$dpm_wf_ok" = 1 ]; then
  ok "48k: all 3 workflow copies checkout + guard-source resolve_parent_directive.sh (#335)"
else
  ng "48k: a workflow copy missing checkout / guarded source of the resolver helper (#335)"
fi

# ---------- 48m. bare-Refs-to-default §10.5 detector (#337) ----------
# Recurrence-prevention for the #92 leak: directive-scoped work merged to the
# live default branch with an EMPTY closing set (bare `Refs #N`, no `Closes`)
# silently deprives the parent Directive of a reflection. The post-merge
# workflow runs detect_bare_refs_directive (sibling of resolve_parent_directive,
# reusing its extracted depth-2 climb) and posts an idempotent warn comment.
DBR_CANON="$SHELL_ROOT/scripts/lib/detect_bare_refs_directive.sh"
DBR_INSTALL="$SHELL_ROOT/.github/workflows/detect_bare_refs_directive.sh"
DBR_TARGETSUB="$SHELL_ROOT/.claude/templates/target-substrate/workflows/detect_bare_refs_directive.sh"

if [ ! -f "$DBR_CANON" ]; then
  ng "48m: scripts/lib/detect_bare_refs_directive.sh missing (#337)"
else
  DBR_DIR=$(mktemp -d)
  DBR_SHIM="$DBR_DIR/bin"
  DBR_STATE="$DBR_DIR/state"
  mkdir -p "$DBR_SHIM" "$DBR_STATE"

  # Fake gh: post-`--jq` values keyed by fixture files. Covers the detector's
  # repo/pr/issue reads plus the resolver climb it reuses.
  cat > "$DBR_SHIM/gh" <<'SHIM'
#!/bin/sh
args="$*"
case "$args" in
  *"repo view"*defaultBranchRef*)
    [ -f "$DBR_STATE/default" ] && cat "$DBR_STATE/default"
    exit 0 ;;
  *"pr view"*baseRefName*)
    p=$(printf '%s\n' "$args" | sed -nE 's/.*pr view ([0-9]+).*/\1/p')
    [ -n "$p" ] && [ -f "$DBR_STATE/base_$p" ] && cat "$DBR_STATE/base_$p"
    exit 0 ;;
  *"pr view"*closingIssuesReferences*)
    p=$(printf '%s\n' "$args" | sed -nE 's/.*pr view ([0-9]+).*/\1/p')
    [ -n "$p" ] && [ -f "$DBR_STATE/closing_$p" ] && cat "$DBR_STATE/closing_$p"
    exit 0 ;;
  *"pr view"*body*)
    p=$(printf '%s\n' "$args" | sed -nE 's/.*pr view ([0-9]+).*/\1/p')
    [ -n "$p" ] && [ -f "$DBR_STATE/prbody_$p" ] && cat "$DBR_STATE/prbody_$p"
    exit 0 ;;
  *"issue view"*labels*)
    n=$(printf '%s\n' "$args" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
    [ -n "$n" ] && [ -f "$DBR_STATE/labels_$n" ] && cat "$DBR_STATE/labels_$n"
    exit 0 ;;
  *"issue view"*body*)
    n=$(printf '%s\n' "$args" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
    [ -n "$n" ] && [ -f "$DBR_STATE/body_$n" ] && cat "$DBR_STATE/body_$n"
    exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$DBR_SHIM/gh"

  dbr_reset() {
    rm -f "$DBR_STATE"/default "$DBR_STATE"/base_* "$DBR_STATE"/closing_* \
          "$DBR_STATE"/prbody_* "$DBR_STATE"/labels_* "$DBR_STATE"/body_* 2>/dev/null || true
  }
  dbr_call() {
    PATH="$DBR_SHIM:$PATH" DBR_STATE="$DBR_STATE" \
      bash -c '. "$1"; detect_bare_refs_directive "$2" "$3"' _ "$DBR_CANON" "$1" "mock/repo" 2>/dev/null
  }

  # Case 1 — FLAG: directive-scoped Refs, empty closing set, base==default.
  dbr_reset
  printf 'main\n' > "$DBR_STATE/default"
  printf 'main\n' > "$DBR_STATE/base_801"
  : > "$DBR_STATE/closing_801"            # empty closing set
  printf 'Some work. Refs #20\n' > "$DBR_STATE/prbody_801"
  printf 'directive\n' > "$DBR_STATE/labels_20"
  out=$(dbr_call 801)
  if printf '%s' "$out" | grep -q 'flag='; then
    ok "48m-1: bare directive Refs to default with empty closing set is flagged (#337)"
  else
    ng "48m-1: flagged shape not detected: '$out' (#337)"
  fi

  # Case 2 — FLAG via climb: Refs target is an Execution Issue parented under a
  # Directive (reuses resolve_parent_directive's depth-2 climb).
  dbr_reset
  printf 'main\n' > "$DBR_STATE/default"
  printf 'main\n' > "$DBR_STATE/base_805"
  : > "$DBR_STATE/closing_805"
  printf 'Refs #40\n' > "$DBR_STATE/prbody_805"
  printf 'execution\n' > "$DBR_STATE/labels_40"
  printf 'Parent Directive: #50\n' > "$DBR_STATE/body_40"
  printf 'directive\n' > "$DBR_STATE/labels_50"
  out=$(dbr_call 805)
  if printf '%s' "$out" | grep -q 'flag='; then
    ok "48m-2: execution-parented Refs (climb to Directive) is flagged (#337)"
  else
    ng "48m-2: execution-parented Refs not detected via climb: '$out' (#337)"
  fi

  # Case 3 — no flag: Refs target is non-directive (a standalone task, no climb).
  dbr_reset
  printf 'main\n' > "$DBR_STATE/default"
  printf 'main\n' > "$DBR_STATE/base_802"
  : > "$DBR_STATE/closing_802"
  printf 'Refs #21\n' > "$DBR_STATE/prbody_802"
  printf 'task\n' > "$DBR_STATE/labels_21"
  printf 'no marker\n' > "$DBR_STATE/body_21"
  out=$(dbr_call 802)
  if ! printf '%s' "$out" | grep -q 'flag='; then
    ok "48m-3: non-directive Refs is not flagged (#337)"
  else
    ng "48m-3: non-directive Refs wrongly flagged: '$out' (#337)"
  fi

  # Case 4 — no flag: non-empty closing set (a proper Closes of an Execution Issue).
  dbr_reset
  printf 'main\n' > "$DBR_STATE/default"
  printf 'main\n' > "$DBR_STATE/base_803"
  printf '30\n' > "$DBR_STATE/closing_803"   # non-empty
  printf 'Refs #20\n' > "$DBR_STATE/prbody_803"
  printf 'directive\n' > "$DBR_STATE/labels_20"
  out=$(dbr_call 803)
  if ! printf '%s' "$out" | grep -q 'flag='; then
    ok "48m-4: non-empty closing set is not flagged (#337)"
  else
    ng "48m-4: non-empty closing set wrongly flagged: '$out' (#337)"
  fi

  # Case 5 — no flag: base != default branch (legit §10.5 topic-branch sub-task PR).
  dbr_reset
  printf 'main\n' > "$DBR_STATE/default"
  printf 'experiment/foo\n' > "$DBR_STATE/base_804"
  : > "$DBR_STATE/closing_804"
  printf 'Refs #20\n' > "$DBR_STATE/prbody_804"
  printf 'directive\n' > "$DBR_STATE/labels_20"
  out=$(dbr_call 804)
  if ! printf '%s' "$out" | grep -q 'flag='; then
    ok "48m-5: non-default base (topic-branch sub-task) is not flagged (#337)"
  else
    ng "48m-5: non-default base wrongly flagged: '$out' (#337)"
  fi

  # Case 6 — fail-soft: default branch unresolvable (gh error) → no flag, no abort.
  dbr_reset
  printf 'main\n' > "$DBR_STATE/base_806"     # no `default` fixture → empty
  : > "$DBR_STATE/closing_806"
  printf 'Refs #20\n' > "$DBR_STATE/prbody_806"
  printf 'directive\n' > "$DBR_STATE/labels_20"
  out=$(dbr_call 806)
  if ! printf '%s' "$out" | grep -q 'flag='; then
    ok "48m-6: unresolvable default branch fails soft (no flag) (#337)"
  else
    ng "48m-6: fail-soft path wrongly flagged: '$out' (#337)"
  fi

  # Case 7 — FLAG at sorted position 6+ (#553 E5): five non-directive Refs
  # precede a directive-scoped one. The old `count>=5` position cap broke the
  # gh fan-out before reaching #66, silently DROPPING the §10.5 violation
  # (false-negative). RED pre-fix, GREEN after the short-circuit + raised cap.
  dbr_reset
  printf 'main\n' > "$DBR_STATE/default"
  printf 'main\n' > "$DBR_STATE/base_807"
  : > "$DBR_STATE/closing_807"
  printf 'Refs #61 Refs #62 Refs #63 Refs #64 Refs #65 Refs #66\n' > "$DBR_STATE/prbody_807"
  for t in 61 62 63 64 65; do printf 'task\n' > "$DBR_STATE/labels_$t"; done   # non-directive, no marker
  printf 'directive\n' > "$DBR_STATE/labels_66"                                 # directive at position 6
  out=$(dbr_call 807)
  if printf '%s' "$out" | grep -q 'flag=.*66'; then
    ok "48m-7: a directive Ref at sorted position 6 is still flagged (no 5-cap false-negative) (#553)"
  else
    ng "48m-7: position-6 directive Ref dropped by the scan cap: '$out' (#553)"
  fi

  # 48m-sync: the three detector copies are byte-identical (cmp-lock).
  if [ -f "$DBR_INSTALL" ] && [ -f "$DBR_TARGETSUB" ] \
     && cmp -s "$DBR_CANON" "$DBR_INSTALL" \
     && cmp -s "$DBR_CANON" "$DBR_TARGETSUB"; then
    ok "48m-sync: 3 detector copies byte-identical (#337)"
  else
    ng "48m-sync: detector copies missing or drifted (#337)"
  fi

  # 48m-repo: every gh INVOCATION in the detector carries --repo (comment lines,
  # e.g. a prose reference to a `gh pr merge` hook, are excluded — not calls).
  dgh=$(grep -E '\bgh[[:space:]]+(pr|issue|repo)\b' "$DBR_CANON" 2>/dev/null | grep -vc '^[[:space:]]*#' || echo 0)
  dghrepo=$(grep -E '\bgh[[:space:]]+(pr|issue|repo)\b.*--repo' "$DBR_CANON" 2>/dev/null | grep -vc '^[[:space:]]*#' || echo 0)
  if [ "$dgh" -gt 0 ] && [ "$dgh" = "$dghrepo" ]; then
    ok "48m-repo: all $dgh detector gh calls carry --repo (#337)"
  else
    ng "48m-repo: $dgh detector gh calls, only $dghrepo carry --repo (#337)"
  fi

  rm -rf "$DBR_DIR" 2>/dev/null || true
fi

# 48n: all 3 dir-mode-post-merge.yml copies wire the bare-Refs detector + an
# idempotent warn comment (marker-guarded) (#337).
dbr_wf_ok=1
for wf in "$DPM_INSTALL" "$DPM_TEMPLATE" "$SHELL_ROOT/.claude/templates/target-substrate/workflows/dir-mode-post-merge.yml"; do
  [ -f "$wf" ] || { dbr_wf_ok=0; continue; }
  grep -qF 'detect_bare_refs_directive.sh' "$wf" || dbr_wf_ok=0
  grep -qF 'bare-refs-warning pr=#' "$wf" || dbr_wf_ok=0
done
if [ "$dbr_wf_ok" = 1 ]; then
  ok "48n: all 3 workflow copies wire the bare-Refs detector + idempotent warn marker (#337)"
else
  ng "48n: a workflow copy missing the bare-Refs detector wiring / warn marker (#337)"
fi

# ---------- 49. Agent files have valid loadable frontmatter (#64 / Directive #62) ----------
# Claude Code enumerates subagent_type values from .claude/agents/*.md at
# session start (SPEC §4.9.3). A broken agent file means the harness silently
# skips that subagent. §49 catches the "agent file unloadable" case
# independently of routing — even before session restart, a malformed
# frontmatter would fail to register the agent at all.
#
# Check: every .claude/agents/*.md has frontmatter with `name`, `description`,
# and `tools` keys. tools is a bracketed list containing at minimum Read.

agent_dir="$SHELL_ROOT/.claude/agents"
all_agents_loadable=1
agent_count=0
if [ -d "$agent_dir" ]; then
  for agent_file in "$agent_dir"/*.md; do
    [ -e "$agent_file" ] || continue
    agent_count=$((agent_count + 1))
    name=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$agent_file")
    desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{print; exit}' "$agent_file")
    tools=$(awk '/^---$/{c++; next} c==1 && /^tools:/{print; exit}' "$agent_file")
    if [ -z "$name" ] || [ -z "$desc" ] || [ -z "$tools" ]; then
      ng "49: agent $(basename "$agent_file") has incomplete frontmatter (name='$name' desc='$desc' tools='$tools') (#64)"
      all_agents_loadable=0
    elif ! printf '%s' "$tools" | grep -qE '\[.*Read.*\]'; then
      ng "49: agent $(basename "$agent_file") tools missing Read (#64)"
      all_agents_loadable=0
    fi
  done
fi
if [ "$all_agents_loadable" = 1 ] && [ "$agent_count" -ge 9 ]; then
  ok "49: all $agent_count agent files have loadable frontmatter — first-class routing eligible after session restart (SPEC §4.9.3) (#64)"
elif [ "$all_agents_loadable" = 1 ]; then
  ng "49: only $agent_count agents found; expected ≥9 (the eight engineering + activation-reviewer) (#64)"
fi

# ---------- 50. /file-directive Project-substrate guard (#71) ----------
# SPEC §1.7 designates the GitHub Project v2 as the dir-mode substrate. Three
# Directives (#54/#61/#62) shipped without Project Items because the prose-only
# step-1 guard ("instruct the user and stop") in /file-directive.md was
# advisory rather than enforced. PR #72 ships:
#   - A new deterministic resolver: scripts/dir_mode_project.sh resolve
#     (exit 0 = found + tab-separated stdout, exit 5 = no Project for target).
#   - /file-directive.md step 1 rewritten to invoke the resolver via Bash
#     and dispatch on its exit code.
#   - /file-directive.md step 7 audit-format tightening: item=<item-id> is
#     mandatory; substituting milestone=#N is a contract violation.
#
# §50 enforces both halves:
#   50a — Audit-format guard. Scans .claude/audit/audit.jsonl for every
#         directive-file/created line with ts >= cutoff (cutoff = the day this
#         PR lands; historical lines #54/#61/#62 stay grandfathered per AC #6).
#         Each line's reason must match the documented format.
#   50b — Resolver gate behavior. Mocks `gh` per the §41 pattern. Case
#         "no project" → expect exit 5 + stderr names setup_project.sh.
#         Case "project exists" → expect exit 0 + stdout `<num>\t<owner>\t<name>`.

# Cutoff = just after the last grandfathered directive-file entry. Originally
# 2026-05-24T11:00:00Z to grandfather #54/#61/#62 (all filed 2026-05-24T10:34:54Z).
# Bumped to 2026-05-25T02:05:00Z (Directive #84 Goal-bootstrap session) to also
# grandfather the broken `created` line at 2026-05-25T02:02:40Z whose `item=`
# field was empty due to a `gh project item-create --format json` jq parse
# failure on a body containing em-dashes / multi-paragraph Markdown. The Item
# ID was recovered via GraphQL listing 39 seconds later and a `directive-file`
# `note` correction with the proper ID is at 2026-05-25T02:03:19Z (visible in
# the audit log). Hardening `audit_log` to validate the format before writing
# is tracked separately. Catches any post-bump filings.
#
# Bumped again to 2026-05-26T03:30:00Z (Directive #92 / v3 cluster-I cutover)
# to grandfather the LAST v0-shape `item=<PVTI-id>` line, which is #92 itself
# at 2026-05-26T03:21:23Z — #92 was filed BEFORE its own cluster I cutover
# flipped the audit token from `item=` to `issue=#<N>`. Post-cutoff lines
# (#107, #109, and forward) must use the v3 `issue=#<N>` shape per the
# updated regex below.
DIRECTIVE_FILE_AUDIT_CUTOFF="2026-05-28T02:00:00Z"
# Cutoff bumped 2026-05-28 by #135: grandfathers the historical malformed
# directive-file/created entry for #128 at 2026-05-28T01:44:53Z (missing
# priority=P<N> token — see SPEC §5.10 step 4). The defect is fixed
# forward by #135's /file-directive Priority capture + step-4 emission;
# the historical entry is immutable per the audit-log append-only
# contract. New entries past the cutoff remain gated.
AUDIT_FILE="$SMOKE_AUDIT"

# 50a — audit-format guard
if [ ! -f "$AUDIT_FILE" ]; then
  # No audit log yet → no entries to verify → vacuously pass.
  ok "50a: no audit log at $AUDIT_FILE — vacuously pass (#71)"
elif ! command -v jq >/dev/null 2>&1; then
  ng "50a: jq not installed — cannot scan audit log (#71)"
else
  # Any directive-file/created line with ts >= cutoff whose reason does NOT
  # match `directive: ... issue=#<N> priority=P<N> confidence=<N>` (v3 shape
  # (Issues are SSOT; the audit-log token references the Issue number).
  bad_lines=$(jq -r --arg cutoff "$DIRECTIVE_FILE_AUDIT_CUTOFF" '
    select(.category=="directive-file" and .decision=="created" and .ts >= $cutoff)
    | select(.reason | test("^directive: .* issue=#[0-9]+ priority=P[0-3] confidence=[0-9]+$") | not)
    | .reason
  ' "$AUDIT_FILE" 2>/dev/null)
  if [ -z "$bad_lines" ]; then
    ok "50a: directive-file audit entries (ts >= $DIRECTIVE_FILE_AUDIT_CUTOFF) match documented format (#71)"
  else
    # Take only the first bad line to keep the diagnostic compact.
    first_bad=$(printf '%s\n' "$bad_lines" | head -1)
    ng "50a: directive-file audit entry deviates from documented format: '$first_bad' (#71)"
  fi
fi

# 50b — resolver gate behavior (two sub-cases under one assertion to match
# the planner's "+2 assertions" contract: 50a + 50b = 2).
DR_SCRIPT="$SHELL_ROOT/scripts/dir_mode_project.sh"
if [ ! -f "$DR_SCRIPT" ]; then
  ng "50b: scripts/dir_mode_project.sh missing — Phase C not yet landed (#71)"
elif ! command -v jq >/dev/null 2>&1; then
  ng "50b: jq not installed — cannot run gh-mock smoke (#71)"
else
  DR50_DIR=$(mktemp -d)
  DR50_TARGET="$DR50_DIR/target"
  DR50_BIN="$DR50_DIR/bin"
  mkdir -p "$DR50_TARGET" "$DR50_BIN"
  # Resolve to realpath so the registry entry matches `pwd -P` from inside
  # the target dir (macOS /var is a symlink).
  DR50_TARGET=$(cd "$DR50_TARGET" && pwd -P)
  (cd "$DR50_TARGET" && git init -q && git remote add origin https://github.com/smoke-owner/smoke-repo.git 2>/dev/null) || true

  # #357 (Class B): register on the target's own per-project ghjig-state registry
  # (dr_check_registry_guard's override-immune first read-arm), not the live
  # shared registry — guard stays green, live sinks stay untouched.
  DR50_REGISTRY="$DR50_TARGET/.claude/ghjig-state/registry.txt"
  mkdir -p "$(dirname "$DR50_REGISTRY")"
  printf '%s\n' "$DR50_TARGET" >> "$DR50_REGISTRY"

  # Minimal gh mock — just `gh auth status` + `gh repo view` + `gh project list`.
  # Toggled by presence/absence of $GH_MOCK_PROJECT_CREATED.
  cat > "$DR50_BIN/gh" <<'DR50_MOCK'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$GH_MOCK_LOG"; printf '\n' >> "$GH_MOCK_LOG"
case "${1:-}" in
  --version) printf 'gh version 2.50.0 (mock)\n' ;;
  auth)
    case "${2:-}" in
      status)
        echo "github.com" >&2
        echo "  - Token scopes: ${GH_MOCK_SCOPES:-gist, repo, project}" >&2
        ;;
    esac
    ;;
  repo)
    if [ "${2:-}" = view ]; then
      printf '{"owner":{"login":"smoke-owner"},"name":"smoke-repo"}'
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
    esac
    ;;
esac
exit 0
DR50_MOCK
  chmod +x "$DR50_BIN/gh"

  # Case 1 — no project. Expect exit 5 + 'setup_project.sh' in stderr.
  rm -f "$DR50_DIR/project-created" "$DR50_DIR/gh.log"
  dr50_no_rc=0
  dr50_no_err=$(
    cd "$DR50_TARGET" || exit 0
    PATH="$DR50_BIN:$PATH" \
    GHJIG_ROOT="$SHELL_ROOT" \
    GH_MOCK_LOG="$DR50_DIR/gh.log" \
    GH_MOCK_PROJECT_CREATED="$DR50_DIR/project-created" \
      bash "$DR_SCRIPT" resolve 2>&1 >/dev/null
  ) || dr50_no_rc=$?

  # Case 2 — project exists. Expect exit 0 + tab-separated stdout.
  touch "$DR50_DIR/project-created"
  rm -f "$DR50_DIR/gh.log"
  dr50_yes_rc=0
  dr50_yes_out=$(
    cd "$DR50_TARGET" || exit 0
    PATH="$DR50_BIN:$PATH" \
    GHJIG_ROOT="$SHELL_ROOT" \
    GH_MOCK_LOG="$DR50_DIR/gh.log" \
    GH_MOCK_PROJECT_CREATED="$DR50_DIR/project-created" \
      bash "$DR_SCRIPT" resolve 2>/dev/null
  ) || dr50_yes_rc=$?

  # Combined assertion: both sub-cases must behave correctly.
  if [ "$dr50_no_rc" = 5 ] && printf '%s' "$dr50_no_err" | grep -q 'setup_project.sh' \
     && [ "$dr50_yes_rc" = 0 ] && printf '%s' "$dr50_yes_out" | grep -qE $'^[0-9]+\t[^\t]+\t[^\t]+$'; then
    ok "50b: dir_mode_project.sh resolve — exit 5 on missing (names setup_project.sh) + exit 0 on present (tab-separated stdout) (#71)"
  else
    ng "50b: resolver gate failed; no-project rc=$dr50_no_rc err='$dr50_no_err'; project-exists rc=$dr50_yes_rc out='$dr50_yes_out' (#71)"
  fi

  # Cleanup
  if [ -f "$DR50_REGISTRY" ]; then
    dr50_tmp_reg=$(mktemp)
    grep -vxF "$DR50_TARGET" "$DR50_REGISTRY" > "$dr50_tmp_reg" 2>/dev/null || true
    mv "$dr50_tmp_reg" "$DR50_REGISTRY"
  fi
  rm -rf "$DR50_DIR"
fi

# ---------- 52. pr_cache.sh helpers work under zsh (#82) ----------
# zsh has a built-in tied array $path that mirrors $PATH. A `local path`
# declaration followed by a scalar assignment clobbers the search path,
# breaking subsequent command resolution. Pre-#82, pr_cache_read /
# pr_cache_write / secret_scan_path_allowed all used `local path` and
# failed with `sed/date: command not found` when sourced under zsh — even
# though PATH was correct and the binaries resolved via `which`.
#
# §52a: invoke pr_cache_write via `zsh -c` against an isolated PR_CACHE_DIR
# and assert exit 0 + the cache file was written. Skipped when zsh isn't
# installed (Linux CI runners may lack it; not blocking).
# §52b: structural — no helper uses a zsh-tied-array name as a local.

if command -v zsh >/dev/null 2>&1; then
  S52_DIR=$(mktemp -d)
  s52_rc=0
  PR_CACHE_REPO=test/repo PR_CACHE_DIR="$S52_DIR" GHJIG_ROOT="$SHELL_ROOT" \
    zsh -c '
      set -e
      . "$GHJIG_ROOT/.claude/hooks/helpers/pr_cache.sh"
      pr_cache_write 12345 deadbeef abc123 >/dev/null 2>&1
    ' || s52_rc=$?
  s52_file="$S52_DIR/test%2Frepo__pr-12345.json"
  # Assert: rc=0 AND file exists AND file contains the sha we wrote.
  # The sha check catches a future regression where pr_cache_write
  # silently truncates / produces empty content while still returning 0.
  if [ "$s52_rc" = 0 ] && [ -f "$s52_file" ] && grep -q 'deadbeef' "$s52_file"; then
    ok "52a: pr_cache_write succeeds under zsh + sha written to cache file (#82)"
  else
    s52_listing=$(ls "$S52_DIR" 2>/dev/null | tr '\n' ' ')
    s52_contents=$(cat "$s52_file" 2>/dev/null | head -c 200)
    ng "52a: pr_cache_write rc=$s52_rc; dir=[$s52_listing] contents=[$s52_contents] (#82)"
  fi

  # §52c: round-trip — pr_cache_read under zsh against the file just written
  # by §52a must return the sha (catches a regression in the read path's
  # zsh-tied-array rename that §52b's static check would also flag).
  s52c_rc=0
  s52c_out=$(PR_CACHE_REPO=test/repo PR_CACHE_DIR="$S52_DIR" GHJIG_ROOT="$SHELL_ROOT" \
    zsh -c '
      . "$GHJIG_ROOT/.claude/hooks/helpers/pr_cache.sh"
      pr_cache_read 12345
    ' 2>/dev/null) || s52c_rc=$?
  if [ "$s52c_rc" = 0 ] && [ "$s52c_out" = "deadbeef" ]; then
    ok "52c: pr_cache_read under zsh returns the sha written by §52a (#82)"
  else
    ng "52c: pr_cache_read rc=$s52c_rc out=[$s52c_out] (expected 'deadbeef') (#82)"
  fi
  rm -rf "$S52_DIR"
else
  ok "52a: zsh not installed — pr_cache.sh zsh-compatibility check skipped (#82)"
  ok "52c: zsh not installed — pr_cache_read zsh round-trip skipped (#82)"
fi

# §52b: static check across .claude/hooks/helpers/*.sh — no helper may
# use a zsh-tied-array name (path, fpath, cdpath, manpath, module_path)
# as a local variable. Excludes comment lines.
s52b_hits=$(grep -nE '^[[:space:]]*local[[:space:]]+([^=#]*[[:space:]])?(path|fpath|cdpath|manpath|module_path)([[:space:]]|=|$)' \
  "$SHELL_ROOT/.claude/hooks/helpers/"*.sh 2>/dev/null | grep -v ':[[:space:]]*#' || true)
if [ -z "$s52b_hits" ]; then
  ok "52b: no zsh-tied-array names used as locals in .claude/hooks/helpers/*.sh (#82)"
else
  ng "52b: helper uses zsh-tied-array name as local: $s52b_hits (#82)"
fi

# ---------- 53. audit_log pre-write format validation (#87) ----------
# audit_log's pre-write validator catches malformed `directive-* / created`
# lines at write time, preventing them from landing in audit.jsonl in the
# first place (long-term replacement for smoke §50a's grandfathering
# cutoff bumps). On format violation, audit_log writes a
# `decision=format-error` warn line instead of the requested record and
# returns 1.

S53_DIR=$(mktemp -d)
S53_LOG="$S53_DIR/.claude/audit/audit.jsonl"
mkdir -p "$(dirname "$S53_LOG")"

# §53a: well-formed directive-file/created → written verbatim, rc=0.
(
  GHJIG_ROOT="$S53_DIR"; unset GHJIG_STATE_DIR_OVERRIDE  # #357: audit must land in $S53_DIR, not $SMOKE_STATE
  # shellcheck source=/dev/null
  . "$SHELL_ROOT/.claude/hooks/hookrt.sh"
  audit_log info directive-file created "directive: smoke test issue=#123 priority=P2 confidence=50"
)
s53a_rc=$?
s53a_last=$(tail -1 "$S53_LOG" 2>/dev/null)
if [ "$s53a_rc" = 0 ] \
   && printf '%s' "$s53a_last" | grep -q '"decision":"created"' \
   && printf '%s' "$s53a_last" | grep -q 'issue=#123'; then
  ok "53a: audit_log valid directive-file/created writes verbatim, rc=0 (#87)"
else
  ng "53a: rc=$s53a_rc last=$s53a_last (#87)"
fi

# §53b: malformed directive-file/created (empty issue=) → format-error
# line written, original record NOT written, rc=1.
s53b_before=$(wc -l < "$S53_LOG" 2>/dev/null | tr -d ' ')
(
  GHJIG_ROOT="$S53_DIR"; unset GHJIG_STATE_DIR_OVERRIDE  # #357: audit must land in $S53_DIR, not $SMOKE_STATE
  # shellcheck source=/dev/null
  . "$SHELL_ROOT/.claude/hooks/hookrt.sh"
  audit_log info directive-file created "directive: bad issue= priority=P2 confidence=50"
)
s53b_rc=$?
s53b_after=$(wc -l < "$S53_LOG" 2>/dev/null | tr -d ' ')
s53b_added=$(( s53b_after - s53b_before ))
s53b_last=$(tail -1 "$S53_LOG" 2>/dev/null)
if [ "$s53b_rc" = 1 ] \
   && [ "$s53b_added" = 1 ] \
   && printf '%s' "$s53b_last" | grep -q '"decision":"format-error"' \
   && printf '%s' "$s53b_last" | grep -q 'audit-format-error'; then
  ok "53b: audit_log malformed directive-file/created rejected with format-error, rc=1 (#87)"
else
  ng "53b: rc=$s53b_rc added=$s53b_added last=$s53b_last (#87)"
fi

# §53c: non-strict combination (directive-link/created) → written verbatim,
# rc=0, no format-error even though the regex would reject "directive=#1
# issue=#2" if mis-applied to it.
s53c_before=$(wc -l < "$S53_LOG" 2>/dev/null | tr -d ' ')
(
  GHJIG_ROOT="$S53_DIR"; unset GHJIG_STATE_DIR_OVERRIDE  # #357: audit must land in $S53_DIR, not $SMOKE_STATE
  # shellcheck source=/dev/null
  . "$SHELL_ROOT/.claude/hooks/hookrt.sh"
  audit_log info directive-link created "directive=#75 issue=#80"
)
s53c_rc=$?
s53c_after=$(wc -l < "$S53_LOG" 2>/dev/null | tr -d ' ')
s53c_added=$(( s53c_after - s53c_before ))
s53c_last=$(tail -1 "$S53_LOG" 2>/dev/null)
if [ "$s53c_rc" = 0 ] \
   && [ "$s53c_added" = 1 ] \
   && printf '%s' "$s53c_last" | grep -q '"decision":"created"'; then
  ok "53c: audit_log directive-link/created (non-strict) writes verbatim, rc=0 (#87)"
else
  ng "53c: rc=$s53c_rc added=$s53c_added last=$s53c_last (#87)"
fi

rm -rf "$S53_DIR"

# ---------- 54. Issue templates + auto-status-proposed workflow (#93 / Directive #92) ----------
# Cluster A of the v3 reframe (dir-mode-v3 brief §9.1): the .github/ISSUE_TEMPLATE/*.yml
# files plus the auto-status-proposed workflow. Structural sanity — files exist + parse
# as YAML + the templates carry the expected `name`/`description`/`body` top-level keys
# + the four expected labels are named in the right templates.

# 54a: all five template / config files exist.
s54a_missing=""
for f in config.yml directive-proposal.yml execution-under-directive.yml task.yml bug-report.yml; do
  [ -f "$SHELL_ROOT/.github/ISSUE_TEMPLATE/$f" ] || s54a_missing="$s54a_missing $f"
done
if [ -z "$s54a_missing" ]; then
  ok "54a: all 5 Issue template / config files present (#93)"
else
  ng "54a: Issue template files missing:$s54a_missing (#93)"
fi

# 54b: auto-status-proposed workflow exists (repurposed from auto-needs-triage, #179).
ASP_WF="$SHELL_ROOT/.github/workflows/auto-status-proposed.yml"
if [ -f "$ASP_WF" ]; then
  ok "54b: auto-status-proposed workflow present (#93/#179)"
else
  ng "54b: .github/workflows/auto-status-proposed.yml missing (#93/#179)"
fi

# 54c: workflow fires on `issues.opened`.
if grep -qE "^[[:space:]]+types:[[:space:]]*\[opened\]" "$ASP_WF" 2>/dev/null; then
  ok "54c: auto-status-proposed workflow fires on issues.opened (#93/#179)"
else
  ng "54c: auto-status-proposed workflow trigger missing `types: [opened]` (#93/#179)"
fi

# 54c2: workflow applies status:proposed + task (NOT needs-triage) on label-free filings (#179).
if grep -q -- '--add-label "status:proposed"' "$ASP_WF" 2>/dev/null \
   && grep -q -- '--add-label "task"' "$ASP_WF" 2>/dev/null \
   && ! grep -q 'needs-triage' "$ASP_WF" 2>/dev/null; then
  ok "54c2: auto-status-proposed applies status:proposed+task, no needs-triage (#179)"
else
  ng "54c2: auto-status-proposed must apply status:proposed+task and drop needs-triage (#179)"
fi

# 54c3: both workflow copies (.github + target-substrate) byte-identical (#179).
if diff -q "$ASP_WF" "$SHELL_ROOT/.claude/templates/target-substrate/workflows/auto-status-proposed.yml" >/dev/null 2>&1; then
  ok "54c3: auto-status-proposed workflow copies byte-identical (#179)"
else
  ng "54c3: auto-status-proposed .github vs target-substrate copies differ (#179)"
fi

# 54d: every work-type template applies its type label + status:proposed at filing (#93/#186).
# Full symmetry: directive/execution/task/bug all gate via status:proposed; execution is
# task-free (distinguished by the Parent Directive marker), task/bug keep their type label.
s54d_it="$SHELL_ROOT/.github/ISSUE_TEMPLATE"
s54d_ok=1
grep -qE "^labels:[[:space:]]*\[directive,[[:space:]]*status:proposed\]" "$s54d_it/directive-proposal.yml" 2>/dev/null || s54d_ok=0
grep -qE "^labels:[[:space:]]*\[execution,[[:space:]]*status:proposed\]" "$s54d_it/execution-under-directive.yml" 2>/dev/null || s54d_ok=0
grep -qE "^labels:[[:space:]]*\[task,[[:space:]]*status:proposed\]" "$s54d_it/task.yml" 2>/dev/null || s54d_ok=0
grep -qE "^labels:[[:space:]]*\[bug,[[:space:]]*status:proposed\]" "$s54d_it/bug-report.yml" 2>/dev/null || s54d_ok=0
if [ "$s54d_ok" = 1 ]; then
  ok "54d: all work-type templates apply type+status:proposed (directive/execution/task/bug) (#93/#186)"
else
  ng "54d: a work-type template's labels frontmatter is missing type or status:proposed (#93/#186)"
fi

# 54i: blank issues disabled — both config.yml copies set blank_issues_enabled: false (#186).
if grep -qE "^blank_issues_enabled:[[:space:]]*false" "$s54d_it/config.yml" 2>/dev/null \
   && grep -qE "^blank_issues_enabled:[[:space:]]*false" "$SHELL_ROOT/.claude/templates/target-substrate/ISSUE_TEMPLATE/config.yml" 2>/dev/null; then
  ok "54i: blank_issues_enabled is false in both config.yml copies (#186)"
else
  ng "54i: blank issues must be disabled (blank_issues_enabled: false) in both config.yml copies (#186)"
fi

# 54j: changed ISSUE_TEMPLATE + config copies byte-identical across .github/ and target-substrate/ (#186).
s54j_ok=1
for f in execution-under-directive.yml task.yml bug-report.yml config.yml; do
  diff -q "$s54d_it/$f" "$SHELL_ROOT/.claude/templates/target-substrate/ISSUE_TEMPLATE/$f" >/dev/null 2>&1 || s54j_ok=0
done
if [ "$s54j_ok" = 1 ]; then
  ok "54j: execution/task/bug templates + config.yml byte-identical across both copies (#186)"
else
  ng "54j: an ISSUE_TEMPLATE/config copy diverged between .github/ and target-substrate/ (#186)"
fi

# 54e: execution-under-directive requires a Parent Directive number input field.
if grep -qE "id:[[:space:]]*parent-directive" "$SHELL_ROOT/.github/ISSUE_TEMPLATE/execution-under-directive.yml" 2>/dev/null; then
  ok "54e: execution-under-directive declares required parent-directive field (#93)"
else
  ng "54e: execution-under-directive.yml missing parent-directive input (#93)"
fi

# 54f: ensure_v3_labels.sh creates the dir-mode labels (incl. awaiting-author #172, P0-P3 #185).
s54f_p=1
for p in P0 P1 P2 P3; do grep -q "ensure_label \"$p\"" "$SHELL_ROOT/scripts/ensure_v3_labels.sh" || s54f_p=0; done
if [ -x "$SHELL_ROOT/scripts/ensure_v3_labels.sh" ] \
   && grep -q "status:proposed" "$SHELL_ROOT/scripts/ensure_v3_labels.sh" \
   && grep -q "status:blocked" "$SHELL_ROOT/scripts/ensure_v3_labels.sh" \
   && ! grep -q "needs-triage" "$SHELL_ROOT/scripts/ensure_v3_labels.sh" \
   && grep -q "awaiting-author" "$SHELL_ROOT/scripts/ensure_v3_labels.sh" \
   && grep -q "ensure_label.*\"task\"" "$SHELL_ROOT/scripts/ensure_v3_labels.sh" \
   && grep -q "ensure_label \"execution\"" "$SHELL_ROOT/scripts/ensure_v3_labels.sh" \
   && [ "$s54f_p" = 1 ]; then
  ok "54f: ensure_v3_labels.sh creates status:proposed + status:blocked + task + execution + awaiting-author + P0-P3; no needs-triage (#93/#172/#179/#185/#186)"
else
  ng "54f: ensure_v3_labels.sh label set wrong (need execution + awaiting-author + P0-P3, no needs-triage) (#93/#172/#179/#185/#186)"
fi

# 54k (#359): ensure_v3_labels.sh creates the two initiative-feedback projection
# labels the initiative-feedback-label workflow applies.
if grep -q "ensure_label \"initiative:challenged\"" "$SHELL_ROOT/scripts/ensure_v3_labels.sh" \
   && grep -q "ensure_label \"initiative:completion-requested\"" "$SHELL_ROOT/scripts/ensure_v3_labels.sh"; then
  ok "54k: ensure_v3_labels.sh creates initiative:challenged + initiative:completion-requested (#359)"
else
  ng "54k: ensure_v3_labels.sh missing the initiative-feedback projection labels (#359)"
fi

# 54h: auto-clear-awaiting-author workflow (#180) — fires on issues.edited, removes
# awaiting-author, gh-CLI-only (no third-party Actions), both copies byte-identical.
ACA_WF="$SHELL_ROOT/.github/workflows/auto-clear-awaiting-author.yml"
ACA_SUB="$SHELL_ROOT/.claude/templates/target-substrate/workflows/auto-clear-awaiting-author.yml"
if [ -f "$ACA_WF" ] \
   && grep -qE "^[[:space:]]+types:[[:space:]]*\[edited\]" "$ACA_WF" 2>/dev/null \
   && grep -q -- '--remove-label "awaiting-author"' "$ACA_WF" 2>/dev/null \
   && ! grep -qE '^[[:space:]]*uses:' "$ACA_WF" 2>/dev/null \
   && diff -q "$ACA_WF" "$ACA_SUB" >/dev/null 2>&1; then
  ok "54h: auto-clear-awaiting-author fires on issues.edited, removes awaiting-author, no 3rd-party Actions, copies identical (#180)"
else
  ng "54h: auto-clear-awaiting-author workflow missing/wrong (issues.edited + --remove-label awaiting-author + gh-only + byte-identical copies) (#180)"
fi

# 54g: YAML structural sanity via python+pyyaml when available.
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  s54g_fails=0
  s54g_checked=0
  s54g_list=""
  for f in "$SHELL_ROOT"/.github/ISSUE_TEMPLATE/*.yml "$SHELL_ROOT"/.github/workflows/auto-status-proposed.yml; do
    [ -f "$f" ] || continue
    s54g_checked=$((s54g_checked+1))
    if ! python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
      s54g_fails=$((s54g_fails+1))
      s54g_list="$s54g_list $(basename "$f")"
    fi
  done
  # Count-guard (#279 Theme E anti-vacuity): the `[ -f ] || continue` skip means
  # an empty glob (templates deleted/renamed) would leave s54g_fails=0 and pass
  # "all 6 … parse cleanly" having checked NOTHING. Assert the expected count so
  # the assertion fails loud instead of greening vacuously.
  # Expected 7 = 6 ISSUE_TEMPLATE/*.yml (bug-report, config, directive-proposal,
  # discussion, execution-under-directive, task) + auto-status-proposed.yml. The
  # count-guard caught a stale "6" here (discussion.yml had been added without
  # updating this assertion) — exactly the drift it exists to surface (#279).
  if [ "$s54g_checked" -ne 7 ]; then
    ng "54g: expected 7 template+workflow YAML files, found $s54g_checked (vacuous-skip guard, #279)"
  elif [ "$s54g_fails" = 0 ]; then
    ok "54g: all 7 template + workflow YAML files parse cleanly (#93/#279)"
  else
    ng "54g: $s54g_fails YAML parse failures:$s54g_list (#93)"
  fi
else
  ok "54g: python3+pyyaml not available — YAML parse check skipped (#93)"
fi

# ---------- 55. trusted-filer-mutate matcher + is_trusted_filer helper (#95 / Directive #92) ----------
# Cluster C of the v3 reframe (brief §6 filer-aware invariants).
# Matrix coverage:
#   §55a — trusted filer + close without --reason completed → block
#   §55b — trusted filer + close --reason completed         → allow (mark_allow silent)
#   §55c — untrusted filer + close without --reason         → allow (regular rules)
#   §55d — any filer + edit --remove-label directive        → block
#   §55e — any filer + edit --add-label other-label         → allow
#   §55f — helper missing / gh failure                      → fail-open allow
# Uses a gh-shim PATH overlay similar to §39's pattern.

PT55_DIR=$(mktemp -d)
PT55_SHIM="$PT55_DIR/bin"
PT55_STATE="$PT55_DIR/state"
mkdir -p "$PT55_SHIM" "$PT55_STATE"

cat > "$PT55_SHIM/gh" <<'SHIM'
#!/bin/sh
# Mock gh — minimal subcommand dispatch needed by issue_filer.sh + the matcher.
# Note: shebang is /bin/sh; on ubuntu CI this is dash, which has stricter
# pattern parsing than bash. Patterns kept simple — `--json owner` and
# `--json name` are sufficient discriminators (gh's separate-call form
# from issue_filer.sh).
args="$*"
case "$args" in
  *"--json owner"*) printf 'mock\n'; exit 0 ;;
  *"--json name"*)  printf 'repo\n'; exit 0 ;;
  *"--json authorAssociation"*)
    n=$(printf '%s\n' "$args" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
    # Repo-scoped fixture (#231): when the query carries --repo owner/name,
    # key the fixture on it (filer_<owner>_<name>_<n>); else the number-only
    # current-repo fixture (filer_<n>).
    r=$(printf '%s\n' "$args" | sed -nE 's/.*--repo ([^ ]+).*/\1/p')
    if [ -n "$r" ]; then
      key="$GH_SHIM_STATE/filer_$(printf '%s' "$r" | tr '/' '_')_$n"
    else
      key="$GH_SHIM_STATE/filer_$n"
    fi
    if [ -n "$n" ] && [ -f "$key" ]; then
      cat "$key"
    fi
    exit 0 ;;
  *"api repos/"*"/issues/"*)
    # #404: is_trusted_filer now resolves author_association via the issues REST
    # endpoint (gh api repos/<owner>/<name>/issues/<n>) instead of the unsupported
    # `gh issue view --json authorAssociation`. Parse owner/name/n and key on the
    # repo-scoped fixture (filer_<owner>_<name>_<n>), falling back to the bare-number
    # fixture (filer_<n>) for the current repo (mock/repo, whose §55 fixtures are
    # number-only). Mirrors the authorAssociation case's keying.
    on=$(printf '%s\n' "$args" | sed -nE 's#.*api repos/([^/]+)/([^/]+)/issues/([0-9]+).*#\1_\2_\3#p')
    n=$(printf '%s\n' "$args" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    key="$GH_SHIM_STATE/filer_$on"
    [ -f "$key" ] || key="$GH_SHIM_STATE/filer_$n"
    if [ -n "$on" ] && [ -f "$key" ]; then
      cat "$key"
    fi
    exit 0 ;;
esac
exit 0
SHIM
chmod +x "$PT55_SHIM/gh"

# Per-issue fixtures: write the authorAssociation literal to $GH_SHIM_STATE/filer_<n>.
printf 'OWNER\n'  > "$PT55_STATE/filer_100"   # trusted (bare-number current repo)
printf 'NONE\n'   > "$PT55_STATE/filer_200"   # untrusted (bare-number current repo)
# Repo-scoped fixtures (#231): same-repo URL (mock/repo) #100 trusted; foreign
# repo (other/repo) #300 trusted while the current repo has no #300 (untrusted).
printf 'OWNER\n'  > "$PT55_STATE/filer_mock_repo_100"
printf 'OWNER\n'  > "$PT55_STATE/filer_other_repo_300"
# Flag-form fixture (#237): foreign repo via `--repo flagco/repo` #500 trusted
# (OWNER) while the current repo has no #500. Proves the `--repo` flag — not just
# the URL selector — feeds the repo-aware trust lookup.
printf 'OWNER\n'  > "$PT55_STATE/filer_flagco_repo_500"
# -R short-alias fixture (#242): foreign repo via `-R rco/repo` #700 trusted
# (OWNER) while the current repo has no #700. is_trusted_filer always queries via
# `--repo` internally, so the §55 mock's `--repo` parsing serves the -R path too.
printf 'OWNER\n'  > "$PT55_STATE/filer_rco_repo_700"

# Cache isolation (#238): is_trusted_filer writes its cache into the REAL
# $GHJIG_ROOT/.claude/state/issue-filer-cache — there is no override
# env, and a temp root can't be substituted because the hook resolves all its
# helpers from $GHJIG_ROOT. Clear the whole leaf cache dir once at
# section start so every §55 assertion re-exercises the gh-query path rather
# than passing on a stale fixture from a prior run. This subsumes the former
# per-key `rm -f` clears. `.gitignore` covers `.claude/state/`, so this leaf is
# never committed — the only defect was test-integrity, which a clean slate fixes.
FILER_CACHE="$SHELL_ROOT/.claude/state/issue-filer-cache"
rm -rf "$FILER_CACHE"

# Helper to invoke pre_tool_use.sh with a synthesized Bash command. Returns
# the hook's exit code (0=allow, 2=block).
pt55_run() {
  local cmd="$1"
  (
    cd "$TMP/fake" || exit 1
    # shellcheck disable=SC2069  # intentional: swap stderr → captured pipe, discard stdout
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | jq -Rs .)" \
      | PATH="$PT55_SHIM:$PATH" \
        GH_SHIM_STATE="$PT55_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1 >/dev/null
  )
  return $?
}

# §55a: trusted filer + close without --reason completed → block (rc=2).
pt55_run "gh issue close 100" >/dev/null 2>&1
case $? in
  2) ok "55a: trusted filer + close without --reason → block (rc=2) (#95)" ;;
  *) ng "55a: expected rc=2 (block) got rc=$? (#95)" ;;
esac

# §55m (#505 / Directive #498): the EQUALS form `--reason=completed` (gh accepts
# it) on a trusted filer must ALLOW — the matcher's tf_completed check only
# recognized the space form, falsely blocking a legitimate completed-close and
# pushing the user toward SKIP_HOOKS.
pt55_run "gh issue close 100 --reason=completed" >/dev/null 2>&1
case $? in
  0) ok "55m: trusted filer + --reason=completed (equals form) → allow (#505)" ;;
  *) ng "55m: --reason=completed equals form falsely blocked (rc=$?) (#505)" ;;
esac

# §55b: trusted filer + close --reason completed → allow (rc=0).
pt55_run "gh issue close 100 --reason completed" >/dev/null 2>&1
case $? in
  0) ok "55b: trusted filer + close --reason completed → allow (rc=0) (#95)" ;;
  *) ng "55b: expected rc=0 (allow) got rc=$? (#95)" ;;
esac

# §55c: untrusted filer + close without --reason → allow.
pt55_run "gh issue close 200" >/dev/null 2>&1
case $? in
  0) ok "55c: untrusted filer + close without --reason → allow (rc=0) (#95)" ;;
  *) ng "55c: expected rc=0 (allow) got rc=$? (#95)" ;;
esac

# §55d: any filer + edit --remove-label directive → block.
pt55_run "gh issue edit 100 --remove-label directive" >/dev/null 2>&1
case $? in
  2) ok "55d: edit --remove-label directive on trusted filer → block (rc=2) (#95)" ;;
  *) ng "55d: expected rc=2 (block) got rc=$? (#95)" ;;
esac
pt55_run "gh issue edit 200 --remove-label directive" >/dev/null 2>&1
case $? in
  2) ok "55d2: edit --remove-label directive on untrusted filer → block (rc=2) (#95)" ;;
  *) ng "55d2: expected rc=2 (block) got rc=$? (#95)" ;;
esac

# §55d3 (#211): the =-separated form must also block. Pre-#211 the matcher only
# matched the space form, so `--remove-label=directive` (valid gh) silently
# declassified. Fails against current code (rc=0/allow).
pt55_run "gh issue edit 100 --remove-label=directive" >/dev/null 2>&1
case $? in
  2) ok "55d3: edit --remove-label=directive (equals form) → block (rc=2) (#211)" ;;
  *) ng "55d3: equals-form declassify not blocked, got rc=$? (#211)" ;;
esac

# §55d4 (#211): a longer label like `directive-foo` must NOT over-match the
# declassify guard (word-boundary tail). Pre-#211 the unanchored regex matched
# the `directive` prefix and wrongly blocked (rc=2); removing a non-`directive`
# label is legitimate and must be allowed.
pt55_run "gh issue edit 100 --remove-label directive-foo" >/dev/null 2>&1
case $? in
  0) ok "55d4: edit --remove-label directive-foo does not over-match → allow (rc=0) (#211)" ;;
  *) ng "55d4: directive-foo over-matched the declassify guard, got rc=$? (#211)" ;;
esac

# §55d5 (#211): `directive` as a non-first element of a comma-joined value list
# still declassifies in real gh, so it must block. Pre-fix the regex anchored
# directive at the head of the value and missed this.
pt55_run "gh issue edit 100 --remove-label other,directive" >/dev/null 2>&1
case $? in
  2) ok "55d5: edit --remove-label other,directive (comma list) → block (rc=2) (#211)" ;;
  *) ng "55d5: comma-list declassify not blocked, got rc=$? (#211)" ;;
esac

# §55d6 (#211): a comma list with NO `directive` element must still allow.
pt55_run "gh issue edit 100 --remove-label bug,task" >/dev/null 2>&1
case $? in
  0) ok "55d6: edit --remove-label bug,task (no directive) → allow (rc=0) (#211)" ;;
  *) ng "55d6: non-directive comma list wrongly blocked, got rc=$? (#211)" ;;
esac

# §55e: any filer + edit --add-label other-label → allow (not the remove-directive case).
pt55_run "gh issue edit 100 --add-label task" >/dev/null 2>&1
case $? in
  0) ok "55e: edit --add-label (non-directive remove) → allow (rc=0) (#95)" ;;
  *) ng "55e: expected rc=0 (allow) got rc=$? (#95)" ;;
esac

# §55f: SKIP_HOOKS=trusted-filer-mutate escape allows the otherwise-blocked
# trusted-filer close.
(
  cd "$TMP/fake" || exit 1
  # shellcheck disable=SC2069  # intentional: swap stderr → captured pipe, discard stdout
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' 'SKIP_HOOKS=trusted-filer-mutate SKIP_REASON=test gh issue close 100' | jq -Rs .)" \
    | PATH="$PT55_SHIM:$PATH" \
      GH_SHIM_STATE="$PT55_STATE" \
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
      bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
)
case $? in
  0) ok "55f: SKIP_HOOKS=trusted-filer-mutate escape allows otherwise-blocked close (#95)" ;;
  *) ng "55f: SKIP_HOOKS escape rc=$? (expected 0) (#95)" ;;
esac

# §55h (#223): the matcher must recognize URL and quoted-number issue selectors,
# not just a bare [0-9]+. Pre-#223 the bare-[0-9]+ anchor let both forms fall to
# the out-of-scope allow arm. The selector regex now absorbs a leading quote
# (`["']?` — $cmd is tr/sed-normalized, NOT shlex, so quotes survive) and matches
# a gh URL with a case-insensitive scheme. h4 guards against over-block on an
# untrusted filer (normalization must resolve to 200, not empty).
# h1: URL-form declassify → block (any filer).
pt55_run "gh issue edit https://github.com/mock/repo/issues/100 --remove-label directive" >/dev/null 2>&1
case $? in
  2) ok "55h1: URL-form --remove-label directive → block (#223)" ;;
  *) ng "55h1: URL-form declassify not blocked, got rc=$? (#223)" ;;
esac
# h2: quoted-number declassify → block.
pt55_run 'gh issue edit "100" --remove-label directive' >/dev/null 2>&1
case $? in
  2) ok "55h2: quoted-number --remove-label directive → block (#223)" ;;
  *) ng "55h2: quoted-number declassify not blocked, got rc=$? (#223)" ;;
esac
# h3: URL-form close on a TRUSTED filer (100=OWNER) → block (selector normalized
# to the bare number so is_trusted_filer resolves).
pt55_run "gh issue close https://github.com/mock/repo/issues/100" >/dev/null 2>&1
case $? in
  2) ok "55h3: URL-form close on trusted filer → block (selector normalized) (#223)" ;;
  *) ng "55h3: URL-form trusted-filer close not blocked, got rc=$? (#223)" ;;
esac
# h4: URL-form close on an UNTRUSTED filer (200=NONE) → allow (no over-block;
# normalization must resolve to 200, not empty).
pt55_run "gh issue close https://github.com/mock/repo/issues/200" >/dev/null 2>&1
case $? in
  0) ok "55h4: URL-form close on untrusted filer → allow (normalized, no over-block) (#223)" ;;
  *) ng "55h4: URL-form untrusted close wrongly blocked, got rc=$? (#223)" ;;
esac
# h5: uppercase scheme (gh accepts HTTPS://) must also be caught — case-insensitive.
pt55_run "gh issue edit HTTPS://github.com/mock/repo/issues/100 --remove-label directive" >/dev/null 2>&1
case $? in
  2) ok "55h5: uppercase-scheme URL declassify → block (case-insensitive) (#223)" ;;
  *) ng "55h5: uppercase-scheme URL evaded the matcher, got rc=$? (#223)" ;;
esac

# §55i (#231): a foreign-repo URL close must resolve filer-trust against the
# URL's repo, not the current repo. other/repo#300 is trusted (OWNER) while the
# current repo has no #300. Pre-#231 the lookup used the current repo (#300
# absent → untrusted → allow). (Cache cleared once at section start, #238.)
# i1: foreign repo #300 trusted → block (proves the lookup used the URL's repo).
pt55_run "gh issue close https://github.com/other/repo/issues/300" >/dev/null 2>&1
case $? in
  2) ok "55i1: foreign-repo URL close resolves trust against the URL's repo → block (#231)" ;;
  *) ng "55i1: foreign-repo URL close checked the wrong repo, got rc=$? (#231)" ;;
esac
# i2: foreign repo #400 untrusted (no fixture) → allow (no over-block).
pt55_run "gh issue close https://github.com/other/repo/issues/400" >/dev/null 2>&1
case $? in
  0) ok "55i2: foreign-repo URL close, untrusted foreign filer → allow (no over-block) (#231)" ;;
  *) ng "55i2: foreign-repo URL close over-blocked an untrusted filer, got rc=$? (#231)" ;;
esac
# i3: malformed URL repo (no owner/name before /issues/) → fail soft to current
# repo (no crash, no over-block). current #100 is trusted (filer_100) → block.
pt55_run "gh issue close https://github.com/issues/100" >/dev/null 2>&1
case $? in
  2) ok "55i3: malformed-repo URL falls back to current repo (current #100 trusted → block) (#231)" ;;
  *) ng "55i3: malformed-repo URL fail-soft path wrong, got rc=$? (#231)" ;;
esac

# §55j (#236 regression guard): a trusted-filer close-as-not-planned on a
# NON-discussion (work) Issue must STILL block. The §236 fix classifies
# discussion-tier first, but a non-discussion Issue (the §55 mock returns no
# `discussion` label) must fall through to the trusted-filer block as before —
# the §5.19 not-planned allowance is discussion-only, not a blanket pass.
pt55_run 'gh issue close 100 --reason "not planned"' >/dev/null 2>&1
case $? in
  2) ok "55j: trusted-filer not-planned close on a non-discussion Issue still blocks (§55 preserved) (#236)" ;;
  *) ng "55j: non-discussion trusted not-planned close wrongly allowed, got rc=$? (#236)" ;;
esac

# §55k (#237, completes #231): a foreign-repo close via the `--repo owner/name`
# FLAG (not a URL selector) must resolve filer-trust against the flag's repo,
# not the current repo. flagco/repo#500 is trusted (OWNER) while the current repo
# has no #500. Pre-#237 the close arm parsed a repo only from a URL selector, so
# the bare-number + `--repo` form left tf_repo empty → trust resolved against the
# current repo (#500 absent → untrusted → allow): the #231-class fail-open via
# the flag form. (Cache cleared once at section start, #238.)
# k1: foreign repo #500 trusted via --repo flag, close-as-not-planned → block
# (proves the flag's repo fed the trust lookup).
pt55_run 'gh issue close 500 --repo flagco/repo --reason "not planned"' >/dev/null 2>&1
case $? in
  2) ok "55k1: --repo-flag foreign close resolves trust against the flag's repo → block (#237)" ;;
  *) ng "55k1: --repo-flag foreign close checked the wrong repo, got rc=$? (#237)" ;;
esac
# k2: foreign repo #600 untrusted (no fixture) via --repo flag → allow (no over-block).
pt55_run 'gh issue close 600 --repo flagco/repo --reason "not planned"' >/dev/null 2>&1
case $? in
  0) ok "55k2: --repo-flag foreign close, untrusted foreign filer → allow (no over-block) (#237)" ;;
  *) ng "55k2: --repo-flag foreign close over-blocked an untrusted filer, got rc=$? (#237)" ;;
esac
# k3: malformed --repo value (bare token, no owner/name) → fail soft to current
# repo (no crash, no over-block). current #100 is trusted (filer_100) → block.
pt55_run 'gh issue close 100 --repo badvalue --reason "not planned"' >/dev/null 2>&1
case $? in
  2) ok "55k3: malformed --repo value falls back to current repo (current #100 trusted → block) (#237)" ;;
  *) ng "55k3: malformed --repo fail-soft path wrong, got rc=$? (#237)" ;;
esac

# §55l (#242, completes #237/#231): a foreign-repo close via gh's `-R` SHORT
# ALIAS for --repo must resolve filer-trust against the flag's repo. rco/repo#700
# is trusted (OWNER) while the current repo has no #700. Pre-#242 the close arm
# parsed only the literal `--repo`, so `-R` left tf_repo empty → trust resolved
# against the current repo (#700 absent → untrusted → allow): the #231-class
# fail-open via the short alias. (Cache cleared once at section start, #238.)
# l1: foreign #700 trusted via `-R rco/repo`, close-as-not-planned → block.
pt55_run 'gh issue close 700 -R rco/repo --reason "not planned"' >/dev/null 2>&1
case $? in
  2) ok "55l1: -R short-alias foreign close resolves trust against the flag's repo → block (#242)" ;;
  *) ng "55l1: -R short-alias foreign close checked the wrong repo, got rc=$? (#242)" ;;
esac
# l2: foreign #800 untrusted (no fixture) via `-R rco/repo` → allow (no over-block).
pt55_run 'gh issue close 800 -R rco/repo --reason "not planned"' >/dev/null 2>&1
case $? in
  0) ok "55l2: -R short-alias foreign close, untrusted foreign filer → allow (no over-block) (#242)" ;;
  *) ng "55l2: -R short-alias foreign close over-blocked an untrusted filer, got rc=$? (#242)" ;;
esac
# l3: the `-R=rco/repo` equals form must also resolve (trusted #700 → block).
pt55_run 'gh issue close 700 -R=rco/repo --reason "not planned"' >/dev/null 2>&1
case $? in
  2) ok "55l3: -R=value equals form resolves trust against the flag's repo → block (#242)" ;;
  *) ng "55l3: -R=value equals form not parsed, got rc=$? (#242)" ;;
esac

rm -rf "$PT55_DIR"

# ---------- 56. /triage deprecation alias (#94 → deprecated by #173) ----------
# #173 retired the triage classifier: triage-reviewer.md is deleted, /triage is
# a one-cycle alias for /activate, SPEC §4.10/§5.18 are retirement tombstones,
# and the `triage` audit category is retained as append-only history.

# 56a: triage command file still exists with standard frontmatter (it's an alias).
TRIAGE_CMD="$SHELL_ROOT/.claude/commands/triage.md"
if [ -f "$TRIAGE_CMD" ]; then
  s56a_desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{print 1; exit}' "$TRIAGE_CMD")
  s56a_hint=$(awk '/^---$/{c++; next} c==1 && /^argument-hint:/{print 1; exit}' "$TRIAGE_CMD")
  if [ "$s56a_desc" = 1 ] && [ "$s56a_hint" = 1 ]; then
    ok "56a: /triage command file has description + argument-hint frontmatter (#94/#173)"
  else
    ng "56a: /triage command file frontmatter incomplete (#94/#173)"
  fi
else
  ng "56a: /triage command file missing (#94/#173)"
fi

# 56b: /triage is a deprecation alias — delegates to /activate. The former
# Phase-2 raw-filing gap was CLOSED by #179 (raw filings now auto-stamped
# status:proposed+task), so the alias names that behavior, not a pending gap.
if grep -qE '/activate' "$TRIAGE_CMD" 2>/dev/null \
   && grep -qiE 'alias|deprecat' "$TRIAGE_CMD" 2>/dev/null \
   && grep -qiE 'auto-status-proposed|status:proposed.+task|raw[- ]filing' "$TRIAGE_CMD" 2>/dev/null; then
  ok "56b: /triage is a deprecation alias for /activate; names the #179 raw-filing behavior (#173/#179)"
else
  ng "56b: /triage must be an alias delegating to /activate + naming the #179 raw-filing status:proposed+task behavior (#173/#179)"
fi

# 56c: triage-reviewer subagent file is DELETED (#173 hard-delete).
if [ ! -f "$SHELL_ROOT/.claude/agents/triage-reviewer.md" ]; then
  ok "56c: triage-reviewer agent file removed (#173)"
else
  ng "56c: triage-reviewer agent file should be deleted (#173)"
fi

# 56d: SPEC §4.10 + §5.18 are retirement tombstones (no `### ` headings → dropped from TOC).
if ! grep -qE '^### 4\.10 ' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && ! grep -qE '^### 5\.18 ' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qE '§4\.10 .*retired' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qE '§5\.18 .*deprecated alias' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "56d: SPEC §4.10/§5.18 retired to tombstones (no ### heading) (#173)"
else
  ng "56d: SPEC §4.10/§5.18 should be retirement tombstones without ### headings (#173)"
fi

# 56e: the `triage` audit category is retained in SPEC §2.1 as append-only history.
if grep -qE '\*\*Audit categories\*\*.*\btriage\b' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "56e: SPEC §2.1 retains 'triage' audit category as history (#94/#173)"
else
  ng "56e: SPEC §2.1 audit-categories list missing 'triage' (#94/#173)"
fi

# 56f: no live triage-reviewer references remain in source/docs. Excluded:
# append-only .claude/state + .claude/audit (history); CHANGELOG.md (immutable
# shipped-release history, like the directive-reviewer rename); and the smoke
# suite itself — smoke.sh AND its smoke.d/ section files (#600) — whose
# deprecation assertions necessarily name the retired agent.
s56f_hits=$(cd "$SHELL_ROOT" && git grep -l 'triage-reviewer' -- . \
  ':(exclude).claude/state' ':(exclude).claude/audit' \
  ':(exclude)CHANGELOG.md' ':(exclude)scripts/test/smoke.sh' \
  ':(exclude)scripts/test/smoke.d' 2>/dev/null)
if [ -z "$s56f_hits" ]; then
  ok "56f: no live triage-reviewer references remain in source/docs (#173)"
else
  ng "56f: stray triage-reviewer references remain: $(printf '%s' "$s56f_hits" | tr '\n' ' ') (#173)"
fi

# ---------- 57. issues-to-project-mirror workflow (cluster D, #96 / Directive #92) ----------
# Cluster D of v3 reframe (brief §7). Structural sanity for the one-direction
# Issue → Project mirror workflow.

MIRROR_WF="$SHELL_ROOT/.github/workflows/issues-to-project-mirror.yml"

# 57a: workflow file exists.
if [ -f "$MIRROR_WF" ]; then
  ok "57a: issues-to-project-mirror workflow file present (#96/cluster D)"
else
  ng "57a: .github/workflows/issues-to-project-mirror.yml missing (#96/cluster D)"
fi

# 57b: workflow triggers cover all 8 issue event types (brief §7).
s57b_missing=""
for evt in opened edited labeled unlabeled closed reopened milestoned demilestoned; do
  grep -q "$evt" "$MIRROR_WF" 2>/dev/null || s57b_missing="$s57b_missing $evt"
done
if [ -z "$s57b_missing" ]; then
  ok "57b: workflow trigger covers all 8 issue event types (#96/cluster D)"
else
  ng "57b: workflow trigger missing:$s57b_missing (#96/cluster D)"
fi

# 57c: workflow derives Type from labels (Directive vs Execution).
if grep -q 'type_val="Directive"' "$MIRROR_WF" 2>/dev/null \
   && grep -q 'type_val="Execution"' "$MIRROR_WF" 2>/dev/null; then
  ok "57c: workflow derives Type from labels (Directive/Execution) (#96/cluster D)"
else
  ng "57c: workflow missing Type derivation (#96/cluster D)"
fi

# 57d: workflow names all 4 v3 Status values AND the closed→Completed
# precedence appears before status:proposed / status:blocked branches.
# Brief §7 locks: closed → Completed beats label-driven branches.
s57d_missing=""
for state in Proposed Active Blocked Completed; do
  grep -q "$state" "$MIRROR_WF" 2>/dev/null || s57d_missing="$s57d_missing $state"
done
s57d_closed_line=$(grep -n 'CLOSED' "$MIRROR_WF" 2>/dev/null | head -1 | cut -d: -f1)
s57d_proposed_line=$(grep -n 'status:proposed' "$MIRROR_WF" 2>/dev/null | head -1 | cut -d: -f1)
if [ -z "$s57d_missing" ] \
   && [ -n "$s57d_closed_line" ] && [ -n "$s57d_proposed_line" ] \
   && [ "$s57d_closed_line" -lt "$s57d_proposed_line" ]; then
  ok "57d: workflow names all 4 v3 Status values + CLOSED→Completed precedes status:proposed (#96/cluster D)"
else
  ng "57d: 57d status check failed: missing=$s57d_missing closed_line=$s57d_closed_line proposed_line=$s57d_proposed_line (#96/cluster D)"
fi

# 57e: workflow derives the Project Parent field from BOTH line-1 markers —
# `Parent Directive: #N` AND `Parent Initiative: #N` (#262). The mirror reads
# a Directive's OWN line-1 marker, which is `Parent Initiative` for an
# Initiative-parented Directive; recognizing both keeps Parent Directive a
# strict superset (no regression). This is the one Parent-marker consumer
# that legitimately reads `Parent Initiative` (§1.7 Derived-view integration).
# Anchor to the CODE form (`^Parent <kind>: #`, the literal caret in the
# grep/sed regexes) — the header + inline comments mention the markers
# without the caret, so this won't pass vacuously if the elif code is
# deleted but the comments remain (#262 code-reviewer hardening).
if grep -qE '\^Parent Directive: #' "$MIRROR_WF" 2>/dev/null \
   && grep -qE '\^Parent Initiative: #' "$MIRROR_WF" 2>/dev/null; then
  ok "57e: workflow parses BOTH Parent Directive + Parent Initiative markers (#262)"
else
  ng "57e: workflow must parse both Parent Directive AND Parent Initiative markers (strict superset) (#262)"
fi

# 57f: workflow does NOT mirror Iteration (per Decision 5).
# Heuristic: no `Iteration` field write nor `iteration_val` variable.
if ! grep -qE 'iteration_val|--field-id[^\n]+Iteration|Iteration.*item-edit' "$MIRROR_WF" 2>/dev/null; then
  ok "57f: workflow does NOT mirror Iteration (per Decision 5) (#96/cluster D)"
else
  ng "57f: workflow appears to mirror Iteration (Decision 5 violation) (#96/cluster D)"
fi

# 57g: workflow YAML parses cleanly (when pyyaml available).
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  if python3 -c "import yaml; yaml.safe_load(open('$MIRROR_WF'))" 2>/dev/null; then
    ok "57g: issues-to-project-mirror workflow YAML parses cleanly (#96/cluster D)"
  else
    ng "57g: issues-to-project-mirror YAML parse failed (#96/cluster D)"
  fi
else
  ok "57g: python3+pyyaml not available — YAML parse check skipped (#96/cluster D)"
fi

# 57h: deployed mirror == target-substrate template copy (#262 two-copy
# drift guard). The mirror ships in two byte-identical copies; the #262
# Parent Initiative change must land in BOTH or /onboard installs a stale
# template. Lock parity so a one-copy edit fails fast.
MIRROR_TMPL="$SHELL_ROOT/.claude/templates/target-substrate/workflows/issues-to-project-mirror.yml"
if [ -f "$MIRROR_TMPL" ]; then
  if diff -q "$MIRROR_WF" "$MIRROR_TMPL" >/dev/null 2>&1; then
    ok "57h: deployed mirror == target-substrate template copy (#262)"
  else
    ng "57h: mirror deployed/template copies drifted — edit both in lockstep (#262)"
  fi
else
  ng "57h: target-substrate mirror template copy missing (#262)"
fi

# 57i: scope-down lock (#262) — /reflect + dir-mode-post-merge consume the
# closing Execution Issue's `Parent Directive` marker only; an Execution
# Issue is structurally never Initiative-parented (parent-XOR), so these
# must NOT reference `Parent Initiative`. Guards against a future "make it
# symmetric everywhere" edit re-introducing dead code the §1.7 Derived-view
# note explicitly rejects.
s57i_hits=""
for f in "$SHELL_ROOT/.claude/commands/reflect.md" \
         "$SHELL_ROOT/.github/workflows/dir-mode-post-merge.yml" \
         "$SHELL_ROOT/.claude/templates/target-substrate/workflows/dir-mode-post-merge.yml"; do
  if [ ! -f "$f" ]; then
    # A renamed/deleted target must fail loud, not skip green (vacuity guard).
    s57i_hits="$s57i_hits MISSING:${f##*/}"
  elif grep -qE 'Parent Initiative' "$f" 2>/dev/null; then
    s57i_hits="$s57i_hits ${f##*/}"
  fi
done
if [ -z "$s57i_hits" ]; then
  ok "57i: /reflect + dir-mode-post-merge stay Parent Directive-only (no dead Initiative path) (#262)"
else
  ng "57i: unexpected Parent Initiative reference in reflect/post-merge:$s57i_hits (#262)"
fi

# 57j: dir-mode Project field is named off the Projects-v2 RESERVED name (#342).
# GitHub promoted `Type` to a built-in reserved Projects-v2 field name, so
# `gh project field-create --name Type` now fails ("Name cannot have a reserved
# value"), breaking tier-3 onboarding. The field must use a non-reserved name
# (`Item Type`). Assert across the field-creator (setup_project.sh) AND both
# byte-identical mirror copies: the new name is present and the bare reserved
# token is absent. (Disambiguated from the issue-`type` label and the
# `type_val`/`TYPE_VAL` derivation variables, which are a separate concept.)
s57j_bad=""
SP_SCRIPT_57j="$SHELL_ROOT/scripts/setup_project.sh"
if grep -q 'ensure_field "Item Type"' "$SP_SCRIPT_57j" 2>/dev/null; then :; else
  s57j_bad="$s57j_bad setup_project:item-type-missing"; fi
if grep -q 'ensure_field "Type"' "$SP_SCRIPT_57j" 2>/dev/null; then
  s57j_bad="$s57j_bad setup_project:reserved-Type-present"; fi
for wf in "$MIRROR_WF" "$MIRROR_TMPL"; do
  [ -f "$wf" ] || { s57j_bad="$s57j_bad MISSING:${wf##*/}"; continue; }
  if grep -q 'field_id "Item Type"' "$wf" 2>/dev/null; then :; else
    s57j_bad="$s57j_bad ${wf##*/}:item-type-missing"; fi
  if grep -q 'field_id "Type"' "$wf" 2>/dev/null; then
    s57j_bad="$s57j_bad ${wf##*/}:reserved-Type-present"; fi
done
if [ -z "$s57j_bad" ]; then
  ok "57j: dir-mode Project field uses non-reserved name 'Item Type' (#342)"
else
  ng "57j: reserved/renamed Project field-name issues:$s57j_bad (#342)"
fi

# 57k (#553 E1): the mirror Parent parse tolerates a web-UI CRLF (\r) and any
# trailing text after `#N`, matching the tolerant resolve_parent_directive.sh
# regex (`^Parent Directive: #([0-9]+)`, no `$`-anchor). The old `$`-anchored
# grep+sed silently BLANKED the Project Parent on a CRLF first line or a
# trailing-text marker. Replicates the workflow's first-line parse against
# fixtures (functional); §57k2 structurally locks the file to the same parse
# so this replica can't drift silently.
s57k_parse() {
  local body="$1" first_line parent_val=""
  first_line=$(printf '%s\n' "$body" | head -1 | tr -d '\r' || true)
  if printf '%s' "$first_line" | grep -qE '^Parent Directive: #[0-9]+'; then
    parent_val=$(printf '%s' "$first_line" | sed -E 's/^Parent Directive: #([0-9]+).*/#\1/')
  elif printf '%s' "$first_line" | grep -qE '^Parent Initiative: #[0-9]+'; then
    parent_val=$(printf '%s' "$first_line" | sed -E 's/^Parent Initiative: #([0-9]+).*/#\1/')
  fi
  printf '%s' "$parent_val"
}
s57k_ok=1
s57k_reasons=""
[ "$(s57k_parse "$(printf 'Parent Directive: #42\r\nrest')")" = '#42' ] \
  || { s57k_ok=0; s57k_reasons="$s57k_reasons crlf-blanked;"; }
[ "$(s57k_parse 'Parent Directive: #42 (umbrella note)')" = '#42' ] \
  || { s57k_ok=0; s57k_reasons="$s57k_reasons trailing-text-blanked;"; }
[ "$(s57k_parse 'Parent Directive: #42')" = '#42' ] \
  || { s57k_ok=0; s57k_reasons="$s57k_reasons plain-lf-regressed;"; }
[ "$(s57k_parse "$(printf 'Parent Initiative: #7\r')")" = '#7' ] \
  || { s57k_ok=0; s57k_reasons="$s57k_reasons crlf-initiative-blanked;"; }
if [ "$s57k_ok" = 1 ]; then
  ok "57k: mirror Parent parse tolerates CRLF + trailing text (no \$-anchor false-blank); LF + Initiative markers still resolve (#553)"
else
  ng "57k: mirror Parent parse still \$-anchored / CR-sensitive:$s57k_reasons (#553)"
fi

# 57k2 (#553 E1): structural lock — both mirror copies strip CR (`tr -d '\r'`)
# and use the non-\$-anchored sed (`([0-9]+).*` capture) so the §57k replica
# stays faithful to the shipped workflow.
s57k2_bad=""
for wf in "$MIRROR_WF" "$MIRROR_TMPL"; do
  [ -f "$wf" ] || { s57k2_bad="$s57k2_bad MISSING:${wf##*/}"; continue; }
  grep -qF "tr -d '\\r'" "$wf" || s57k2_bad="$s57k2_bad ${wf##*/}:no-cr-strip"
  grep -qF 's/^Parent Directive: #([0-9]+).*/#\1/' "$wf" || s57k2_bad="$s57k2_bad ${wf##*/}:anchored-sed"
done
if [ -z "$s57k2_bad" ]; then
  ok "57k2: both mirror copies CR-strip + drop the \$-anchor in the Parent sed (#553)"
else
  ng "57k2: mirror Parent parse not CR-tolerant / still \$-anchored:$s57k2_bad (#553)"
fi

# 57l (#553 E2): the three per-issue derive-fetches (labels / state / body) are
# fail-soft — a transient API error degrades to the stale-view default rather
# than aborting the step red. Structural: each `gh issue view … --json {labels,
# state,body}` in the derive step carries a `2>/dev/null || …` fallback.
s57l_bad=""
for wf in "$MIRROR_WF" "$MIRROR_TMPL"; do
  [ -f "$wf" ] || { s57l_bad="$s57l_bad MISSING:${wf##*/}"; continue; }
  grep -qF "gh issue view \"\$ISSUE_NUM\" --repo \"\$REPO\" --json labels --jq '[.labels[].name]' 2>/dev/null || echo '[]'" "$wf" \
    || s57l_bad="$s57l_bad ${wf##*/}:labels-hard"
  grep -qF "gh issue view \"\$ISSUE_NUM\" --repo \"\$REPO\" --json state --jq '.state' 2>/dev/null || echo ''" "$wf" \
    || s57l_bad="$s57l_bad ${wf##*/}:state-hard"
  grep -qF "gh issue view \"\$ISSUE_NUM\" --repo \"\$REPO\" --json body --jq '.body' 2>/dev/null || echo ''" "$wf" \
    || s57l_bad="$s57l_bad ${wf##*/}:body-hard"
done
if [ -z "$s57l_bad" ]; then
  ok "57l: mirror per-issue derive-fetches (labels/state/body) are fail-soft (stale-view, not red) (#553)"
else
  ng "57l: a mirror derive-fetch is not fail-soft (transient API error → red step):$s57l_bad (#553)"
fi

# ---------- 58. substrate-flip (cluster E+F+G+H) command + reviewer + SPEC rewrite (#96 / Directive #92) ----------
# Cluster E (commands) + F (activation-reviewer) + G (setup_project.sh) + H
# (SPEC §1.7/§2.1/§5.10-§5.18). Structural sanity for the
# substrate flip from Project-Items-as-SSOT (v0) to Issues-as-SSOT (v3).

# 58a: every dir-mode command file operates on the Issue substrate
# (gh issue invocation OR explicit `directive` / `status:` label reference).
# Replaces the prior token assertion
# (cluster E #96) which was tied to migration-era qualifiers stripped by
# Directive #149 / Issue #151. The intent is unchanged: prevent regression
# to Project-Items-as-SSOT by requiring each dir-mode command file to assert
# its Issue-substrate contract in the body.
s58a_missing=""
for cmd in file-directive activate-directive complete-directive block-directive revise-directive list-directives link-directive; do
  cmd_path="$SHELL_ROOT/.claude/commands/$cmd.md"
  [ -f "$cmd_path" ] || { s58a_missing="$s58a_missing $cmd(missing)"; continue; }
  if ! grep -qE '(gh issue|`directive` label|`status:)' "$cmd_path" 2>/dev/null; then
    s58a_missing="$s58a_missing $cmd"
  fi
done
if [ -z "$s58a_missing" ]; then
  ok "58a: all 7 dir-mode commands assert Issue-substrate contract (#96/cluster E; updated #151)"
else
  ng "58a: dir-mode commands missing Issue-substrate refs:$s58a_missing (#96/cluster E; updated #151)"
fi

# 58b: /file-directive emits issue=#<N> audit token (not item=PVTI_...).
if grep -qE 'issue=#' "$SHELL_ROOT/.claude/commands/file-directive.md" 2>/dev/null \
   && ! grep -qE 'item=<item-id>|item=PVTI_' "$SHELL_ROOT/.claude/commands/file-directive.md" 2>/dev/null; then
  ok "58b: /file-directive uses issue=#<N> audit token (Issues-as-SSOT) (#96/cluster E)"
else
  ng "58b: /file-directive missing issue=#<N> or still uses item=<id> (#96/cluster E)"
fi

# 58c: activation-reviewer drops Goal-bootstrap allowance, adds MISSION.md alignment check.
# Pattern updated (#162): activation-reviewer asserts MISSION.md alignment — the
# load-bearing structural claim this gate protects.
DR_AGENT="$SHELL_ROOT/.claude/agents/activation-reviewer.md"
if grep -qE 'MISSION\.md alignment|MISSION fit' "$DR_AGENT" 2>/dev/null; then
  ok "58c: activation-reviewer names MISSION.md alignment (#96/cluster F; updated #162)"
else
  ng "58c: activation-reviewer missing MISSION.md alignment check (#96/cluster F; updated #162)"
fi

# 58d: setup_project.sh declares the v3 4-state Status options + 2-option Type.
SP_SH="$SHELL_ROOT/scripts/setup_project.sh"
if grep -qE 'Proposed,Active,Blocked,Completed' "$SP_SH" 2>/dev/null \
   && grep -qE 'Directive,Execution' "$SP_SH" 2>/dev/null \
   && ! grep -qE 'ensure_field "Confidence"|ensure_field "Success Signals"' "$SP_SH" 2>/dev/null; then
  ok "58d: setup_project.sh declares v3 4-state Status + Directive/Execution Type; Confidence + Success Signals dropped (#96/cluster G)"
else
  ng "58d: setup_project.sh v3 schema check failed (#96/cluster G)"
fi

# 58e: SPEC §2.1 lifecycle table has exactly 4 state rows.
# Count rows matching the `| Proposed |` / `| Active |` / `| Blocked |` / `| Completed |` shape.
s58e_count=0
for state in Proposed Active Blocked Completed; do
  if grep -qE "^\| \`$state\`" "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
    s58e_count=$((s58e_count+1))
  fi
done
# Verify Planned and Revised are NOT in the state-table rows.
s58e_planned=$(grep -cE "^\| \`Planned\`" "$SHELL_ROOT/SPEC.md" 2>/dev/null || true)
s58e_revised=$(grep -cE "^\| \`Revised\`" "$SHELL_ROOT/SPEC.md" 2>/dev/null || true)
: "${s58e_planned:=0}"; : "${s58e_revised:=0}"
if [ "$s58e_count" = 4 ] && [ "$s58e_planned" = 0 ] && [ "$s58e_revised" = 0 ]; then
  ok "58e: SPEC §2.1 state-table has exactly 4 v3 states (Proposed/Active/Blocked/Completed); Planned and Revised removed (#96/cluster H)"
else
  ng "58e: SPEC §2.1 state-table v3: 4-count=$s58e_count planned=$s58e_planned revised=$s58e_revised (expected 4/0/0) (#96/cluster H)"
fi

# 58f: SPEC §1.7 substrate paragraph asserts "Issues" as substrate + "derived view" Project.
# Pattern updated (#162): the structural assertion is phrased against the inlined SPEC prose.
if grep -qiE 'all dir-mode state lives on GitHub Issues' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qE 'derived view' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "58f: SPEC §1.7 asserts Issues-as-substrate + Project-as-derived-view (#96/cluster H; updated #162)"
else
  ng "58f: SPEC §1.7 missing substrate / derived-view naming (#96/cluster H; updated #162)"
fi

# ---------- 59. v3 migration script + MISSION.md (#96 / cluster I) ----------
# Cluster I (brief §8) — one-shot snapshot + delete migration. Structural
# sanity: script exists with --confirm gate, MISSION.md populated.

# 59a: migrate_v3.sh exists, is executable, refuses without --confirm.
MIG_SH="$SHELL_ROOT/scripts/migrate_v3.sh"
if [ -x "$MIG_SH" ]; then
  s59a_out=$(bash "$MIG_SH" 2>&1 || true)
  if printf '%s' "$s59a_out" | grep -qE 'DESTRUCTIVE'; then
    ok "59a: migrate_v3.sh requires --confirm + warns DESTRUCTIVE (#96/cluster I)"
  else
    ng "59a: migrate_v3.sh missing DESTRUCTIVE warning on no-confirm invocation (#96/cluster I)"
  fi
else
  ng "59a: scripts/migrate_v3.sh missing or not executable (#96/cluster I)"
fi

# 59b: MISSION.md exists with the 5 canonical sections.
MISSION="$SHELL_ROOT/MISSION.md"
if [ -f "$MISSION" ]; then
  s59b_missing=""
  for section in "## What this exists for" "## Success looks like" "## Who this is for" "## Explicitly NOT goals" "## Stakeholders"; do
    grep -qF "$section" "$MISSION" 2>/dev/null || s59b_missing="$s59b_missing $section"
  done
  if [ -z "$s59b_missing" ]; then
    ok "59b: MISSION.md has all 5 canonical sections (#96/cluster I)"
  else
    ng "59b: MISSION.md missing sections:$s59b_missing (#96/cluster I)"
  fi
else
  ng "59b: MISSION.md missing (#96/cluster I)"
fi

# 59c: MISSION.md declares the operational MISSION-fit contract for Directives.
# Pattern updated (#162): the prior cross-reference and supersession framing were removed
# as migration-era scaffolding; the load-bearing operational claim ("Every Directive's
# MISSION fit field references a section of this file") remains and is what this gate asserts.
if grep -qE "Every Directive's \`## MISSION fit\` field references a section of this file" "$MISSION" 2>/dev/null; then
  ok "59c: MISSION.md declares the Directive MISSION-fit contract (#96/cluster I; updated #162)"
else
  ng "59c: MISSION.md missing the Directive MISSION-fit contract sentence (#96/cluster I; updated #162)"
fi

# ---------- 60. user-global ~/.claude/ carve-out on protected-branch matcher (#91) ----------
# Issue #91: the protected-branch matcher in pre_tool_use.sh used to fire
# on ANY target path when the current branch was protected, even for
# user-global memory writes under $HOME/.claude/ that have nothing to do
# with the repo's branch state. Fix: a $HOME/.claude/ carve-out skips
# the branch + out-of-scope checks while keeping the sensitive-file check
# active.

# Set up a registered cwd on a protected branch ('main') so the matcher
# enters the protected-branch branch. Separate from $TMP/fake which is
# intentionally on a non-protected branch.
S60_DIR=$(mktemp -d)
S60_TARGET="$S60_DIR/target"
mkdir -p "$S60_TARGET"
S60_TARGET=$(cd "$S60_TARGET" && pwd -P)
(cd "$S60_TARGET" && git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
 git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
printf '%s\n' "$S60_TARGET" >> "$SMOKE_REG"

# Helper: invoke pre_tool_use.sh with a synthesized Edit input from $S60_TARGET.
s60_edit_run() {
  local target_path="$1"
  (
    cd "$S60_TARGET" || exit 1
    printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$target_path" \
      | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
  )
  return $?
}

# §60a: Edit on $HOME/.claude/projects/<dummy>/memory/foo.md while on main
#       → allow (carve-out fires; branch check skipped).
s60a_target="$HOME/.claude/projects/smoke-fake/memory/foo.md"
s60_edit_run "$s60a_target"
case $? in
  0) ok "60a: Edit on \$HOME/.claude/... allowed on protected branch (carve-out) (#91)" ;;
  *) ng "60a: expected rc=0 (allow), got rc=$? on \$HOME/.claude/... (#91)" ;;
esac

# §60b: Edit on an in-repo file ($S60_TARGET/SPEC.md) while on main
#       → still blocked (protected-branch check applies; carve-out does
#       NOT fire because target is not under $HOME/.claude/).
s60b_target="$S60_TARGET/some-file.md"
s60_edit_run "$s60b_target"
case $? in
  2) ok "60b: Edit on in-repo file still blocked on protected branch (#91)" ;;
  *) ng "60b: expected rc=2 (block), got rc=$? on in-repo file (#91)" ;;
esac

# §60c: Edit on $HOME/.claude/.../credentials → still blocked
#       (sensitive-file check fires regardless of carve-out).
s60c_target="$HOME/.claude/projects/smoke-fake/credentials"
s60_edit_run "$s60c_target"
case $? in
  2) ok "60c: Sensitive-file edit blocked under \$HOME/.claude/ (sensitive check survives carve-out) (#91)" ;;
  *) ng "60c: expected rc=2 (sensitive block), got rc=$? on credentials file (#91)" ;;
esac

# §60d: Edit on /tmp/random.md while on main → still blocked
#       (out-of-scope check fires; /tmp is not $HOME/.claude/ so carve-out
#       doesn't apply).
s60d_target=$(mktemp -u)/random.md
s60_edit_run "$s60d_target"
case $? in
  2) ok "60d: Out-of-scope edit (/tmp/...) still blocked on protected branch (#91)" ;;
  *) ng "60d: expected rc=2 (block), got rc=$? on /tmp/... (#91)" ;;
esac

# §60e (#210): Edit on a sensitive file under $GHJIG_ROOT/ → still
#       blocked. The shell-self-mod carve-out skips branch + out-of-scope, but
#       the sensitive-file check fires under BOTH carve-outs. Pre-#210 the
#       SHELL_ROOT arm did an early `exit 0` before the sensitive case, so this
#       was wrongly allowed.
s60e_target="$SHELL_ROOT/.claude/state/smoke-probe.pem"
s60_edit_run "$s60e_target"
case $? in
  2) ok "60e: Sensitive-file edit blocked under \$GHJIG_ROOT/ (sensitive check survives carve-out) (#210)" ;;
  *) ng "60e: expected rc=2 (sensitive block), got rc=$? under SHELL_ROOT (#210)" ;;
esac

# §60f (#210): regression — a NON-sensitive edit under $GHJIG_ROOT/
#       is still allowed (the self-mod carve-out still skips branch + scope for
#       ordinary shell files; the fix must not over-block shell self-modification).
s60f_target="$SHELL_ROOT/.claude/CLAUDE.md"
s60_edit_run "$s60f_target"
case $? in
  0) ok "60f: Non-sensitive shell self-modification still allowed under SHELL_ROOT (#210)" ;;
  *) ng "60f: expected rc=0 (allow), got rc=$? on shell self-mod file (#210)" ;;
esac

# §60g (#243): the Edit/Write carve-outs do NOT extend to the destructive-command
# matcher. A forced `rm` targeting a path under $HOME/.claude/ (outside the
# registry) is still blocked — `check_destructive_args` has no carve-out (SPEC
# §6.1 scopes the carve-outs to the Edit/Write rows only). Guards the CLAUDE.md
# correction so the doc and runtime stay aligned (the carve-out is Edit/Write-only,
# not a blanket $HOME/.claude pass). ${HOME} literal form exercises the matcher's
# own $HOME expansion (cf. §15b). Escapable via SKIP_HOOKS=out-of-scope.
if [ "$(hook_run 'rm -rf ${HOME}/.claude/projects/smoke-fake/stale-memory.md')" = "2" ]; then
  ok "60g: forced rm under \$HOME/.claude/ still blocked (destructive matcher has no carve-out) (#243)"
else
  ng "60g: forced rm under \$HOME/.claude/ wrongly allowed (carve-out must be Edit/Write-only) (#243)"
fi

# Cleanup §60.
sp_tmp_reg=$(mktemp); grep -vxF "$S60_TARGET" "$SMOKE_REG" > "$sp_tmp_reg" 2>/dev/null || true
mv "$sp_tmp_reg" "$SMOKE_REG"
rm -rf "$S60_DIR"

