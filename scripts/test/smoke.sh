#!/usr/bin/env bash
# scripts/test/smoke.sh — shell infrastructure sanity check.
# Verifies hook/helper/inject behavior without running Claude Code.
set -uo pipefail

SHELL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"

PASS=0
FAIL=0
ok() { printf '✓ %s\n' "$1"; PASS=$((PASS+1)); }
ng() { printf '✗ %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

# ---------- 1. structure ----------
for f in \
  .gitignore \
  .claude/settings.json \
  .claude/CLAUDE.md \
  .claude/agents/planner.md \
  .claude/agents/explorer.md \
  .claude/agents/doc-writer.md \
  .claude/agents/test-writer.md \
  .claude/agents/code-reviewer.md \
  .claude/agents/security-reviewer.md \
  .claude/commands/onboard.md \
  .claude/commands/work-on.md \
  .claude/commands/ship.md \
  .claude/hooks/pre_tool_use.sh \
  .claude/hooks/post_tool_use.sh \
  .claude/hooks/stop.sh \
  .claude/hooks/user_prompt_submit.sh \
  .claude/hooks/session_start.sh \
  .claude/templates/pr_body.md \
  bin/claude-eng \
  scripts/bootstrap.sh \
  scripts/clone-into.sh \
  scripts/register.sh \
  scripts/lib/inject.sh \
; do
  [ -f "$SHELL_ROOT/$f" ] && ok "exists: $f" || ng "missing: $f"
done

# ---------- 2. helper / hook syntax ----------
for h in log escape cwd_guard detect_stack branch_guard conventional_commit secret_scan tests gh_state; do
  if bash -n "$SHELL_ROOT/.claude/hooks/helpers/$h.sh" 2>/dev/null; then
    ok "helper syntax: $h.sh"
  else
    ng "helper syntax: $h.sh"
  fi
done
for h in pre_tool_use post_tool_use stop user_prompt_submit session_start; do
  if bash -n "$SHELL_ROOT/.claude/hooks/$h.sh" 2>/dev/null; then
    ok "hook syntax: $h.sh"
  else
    ng "hook syntax: $h.sh"
  fi
done

# ---------- 3. conventional_commit helper ----------
. "$SHELL_ROOT/.claude/hooks/helpers/conventional_commit.sh"
check_commit_subject "feat(#42): add login" 2>/dev/null && ok "cc: feat(#42) accepted" || ng "cc: feat(#42) should accept"
check_commit_subject "feat: no issue" 2>/dev/null && ng "cc: feat without issue should reject" || ok "cc: feat without issue rejected"
check_commit_subject "chore: typo" 2>/dev/null && ok "cc: chore without issue accepted" || ng "cc: chore without issue should accept"
check_commit_subject "chore(#7): bump deps" 2>/dev/null && ok "cc: chore(#7) accepted" || ng "cc: chore(#7) should accept"
# 72-char subject ok
LONG=$(printf 'a%.0s' {1..72})
check_commit_subject "feat(#1): $LONG" 2>/dev/null && ok "cc: 72-char subject accepted" || ng "cc: 72-char should accept"
# 73-char reject
LONG=$(printf 'a%.0s' {1..73})
check_commit_subject "feat(#1): $LONG" 2>/dev/null && ng "cc: 73-char should reject" || ok "cc: 73-char rejected"
# 72-codepoint multibyte (Korean) subject — verifies codepoint (not byte) length check
KOR=$(printf '가%.0s' {1..72})
check_commit_subject "feat(#1): $KOR" 2>/dev/null && ok "cc: 72-codepoint multibyte accepted" || ng "cc: 72-codepoint multibyte should accept"

# ---------- 4. inject + registry ----------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# fake target git repo (init may default to main; immediately move to a feature branch)
(cd "$TMP" && git init -q fake && cd fake && git checkout -b smoke/feat/1-test -q 2>/dev/null && git commit --allow-empty -q -m init 2>/dev/null) || true
. "$SHELL_ROOT/scripts/lib/inject.sh"

# Isolate registry for the test
ORIG_REG="$SHELL_ROOT/.claude/state/registry.txt"
ORIG_REG_BAK=""
if [ -f "$ORIG_REG" ]; then
  ORIG_REG_BAK="$ORIG_REG.smoke-bak"
  mv "$ORIG_REG" "$ORIG_REG_BAK"
fi

inject_into "$TMP/fake" >/dev/null 2>&1 && ok "inject_into ok" || ng "inject_into failed"
[ -L "$TMP/fake/.claude/settings.local.json" ] && ok "settings.local.json symlinked" || ng "settings.local.json missing"
[ -L "$TMP/fake/.claude/agents/planner.md" ] && ok "agents/planner.md symlinked" || ng "agents/planner.md missing"
grep -q "$TMP/fake" "$SHELL_ROOT/.claude/state/registry.txt" 2>/dev/null && ok "registry entry added" || ng "registry not updated"
grep -q "^.claude/settings.local.json" "$TMP/fake/.git/info/exclude" 2>/dev/null && ok ".git/info/exclude updated" || ng "exclude not updated"

# ---------- 5. cwd_guard ----------
. "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"

(cd "$TMP/fake" && in_scope) && ok "in_scope: registered path" || ng "in_scope should be true"
(cd "$TMP" && in_scope) && ng "in_scope: unregistered should be false" || ok "in_scope: unregistered false"

path_in_scope "$TMP/fake/some/file" && ok "path_in_scope: inside registered" || ng "path_in_scope should be true"
path_in_scope "/etc/passwd" && ng "path_in_scope: /etc/passwd should be false" || ok "path_in_scope: /etc/passwd false"
path_in_scope "$HOME/.zshrc" && ng "path_in_scope: ~/.zshrc should be false" || ok "path_in_scope: ~/.zshrc false"
path_in_scope "$SHELL_ROOT/.claude/CLAUDE.md" && ok "path_in_scope: shell self allowed" || ng "shell self should be allowed"

# ---------- 6. secret_scan ----------
. "$SHELL_ROOT/.claude/hooks/helpers/secret_scan.sh"
SCAN_DIR=$(mktemp -d)
(
  cd "$SCAN_DIR"
  git init -q
  printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > leak.txt
  git add leak.txt
  scan_staged_secrets >/dev/null 2>&1 && echo PASSED_LEAK_TEST_WRONG || echo DETECTED_OK
) | grep -q DETECTED_OK && ok "secret_scan: AWS key detected" || ng "secret_scan should detect AWS key"
rm -rf "$SCAN_DIR"

# ---------- 7. pre_tool_use integration: block behavior ----------
fake_input() {
  local tool="$1" json_input="$2"
  printf '{"tool_name":"%s","tool_input":%s}' "$tool" "$json_input"
}
# Edit on out-of-scope path
out=$(cd "$TMP/fake" && fake_input "Edit" "{\"file_path\":\"/etc/passwd\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 2 ] && ok "pre_tool_use blocks /etc/passwd edit" || ng "should block /etc/passwd edit (rc=$rc)"

# Edit on in-scope path
out=$(cd "$TMP/fake" && fake_input "Edit" "{\"file_path\":\"$TMP/fake/README.md\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 0 ] && ok "pre_tool_use allows in-scope edit" || ng "should allow in-scope edit (rc=$rc)"

# Bash rm -rf $HOME
out=$(cd "$TMP/fake" && fake_input "Bash" "{\"command\":\"rm -rf \$HOME/somewhere\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 2 ] && ok "pre_tool_use blocks 'rm -rf \$HOME/...'" || ng "should block rm -rf \$HOME (rc=$rc)"

# Bash force push
out=$(cd "$TMP/fake" && fake_input "Bash" "{\"command\":\"git push --force origin feature\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 2 ] && ok "pre_tool_use blocks force push" || ng "should block force push (rc=$rc)"

# Bash with escape — pass SKIP_HOOKS into pre_tool_use's environment via export
out=$(cd "$TMP/fake" && {
  export SKIP_HOOKS=force-push SKIP_REASON="emergency"
  fake_input "Bash" "{\"command\":\"git push --force origin feature\"}" \
    | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh"
} 2>&1)
rc=$?
[ "$rc" = 0 ] && ok "escape SKIP_HOOKS=force-push passes" || ng "escape should pass (rc=$rc)"

# Hook transparent outside registry
out=$(cd "$TMP" && fake_input "Edit" "{\"file_path\":\"/etc/passwd\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 0 ] && ok "hook transparent outside registry" || ng "hook should be transparent outside registry (rc=$rc)"

# ---------- 8. detect_stack: godot ----------
. "$SHELL_ROOT/.claude/hooks/helpers/detect_stack.sh"

GODOT_DIR=$(mktemp -d)
: > "$GODOT_DIR/project.godot"

out=$(cd "$GODOT_DIR" && detect_stack)
[ "$out" = "godot" ] && ok "detect_stack: godot via project.godot" || ng "detect_stack should return godot (got: $out)"

out=$(cd "$GODOT_DIR" && detect_test_cmd)
case "$out" in *godot*) ok "detect_test_cmd: godot returns godot command" ;; *) ng "detect_test_cmd should mention godot (got: $out)" ;; esac

# detect_lint_cmd: PATH-aware. 'gdlint .' iff gdlint installed, else empty.
out=$(cd "$GODOT_DIR" && detect_lint_cmd)
if command -v gdlint >/dev/null 2>&1; then
  [ "$out" = "gdlint ." ] && ok "detect_lint_cmd: godot → gdlint ." || ng "detect_lint_cmd should emit 'gdlint .' (got: $out)"
else
  [ -z "$out" ] && ok "detect_lint_cmd: godot silent when gdlint absent" || ng "detect_lint_cmd should be empty when gdlint absent (got: $out)"
fi

# detect_format_cmd: PATH-aware. 'gdformat <file>' for .gd iff gdformat installed.
out=$(cd "$GODOT_DIR" && detect_format_cmd hello.gd)
if command -v gdformat >/dev/null 2>&1; then
  case "$out" in *gdformat*hello.gd*) ok "detect_format_cmd: .gd → gdformat hello.gd" ;; *) ng "detect_format_cmd should emit gdformat (got: $out)" ;; esac
else
  [ -z "$out" ] && ok "detect_format_cmd: .gd silent when gdformat absent" || ng "detect_format_cmd .gd should be empty when gdformat absent (got: $out)"
fi

# Scene / resource files are explicitly NOT auto-formatted (editor-managed).
for ext in tscn tres import; do
  out=$(cd "$GODOT_DIR" && detect_format_cmd "scene.$ext")
  [ -z "$out" ] && ok "detect_format_cmd: .$ext not auto-formatted" || ng "detect_format_cmd .$ext should be empty (got: $out)"
done

# Empty dir (no sentinels) still resolves to unknown — regression guard
EMPTY_DIR=$(mktemp -d)
out=$(cd "$EMPTY_DIR" && detect_stack)
[ "$out" = "unknown" ] && ok "detect_stack: unknown when no sentinel" || ng "detect_stack should return unknown (got: $out)"
rmdir "$EMPTY_DIR"

rm -rf "$GODOT_DIR"

# ---------- 9. shell self-registration ----------
# Source the helper if it exists yet (Phase C wires it). Pre-impl this is a no-op
# and ensure_self_registered will be undefined — the assertions below will fail
# accordingly, which is the intended pre-impl signal.
[ -f "$SHELL_ROOT/scripts/lib/self_register.sh" ] && . "$SHELL_ROOT/scripts/lib/self_register.sh"

# 9a. ensure_self_registered: appends to registry, idempotent
# Canonicalize via pwd -P (ensure_self_registered does the same internally; macOS).
SR_TMP=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$SR_TMP/.claude/state"
if command -v ensure_self_registered >/dev/null 2>&1; then
  ensure_self_registered "$SR_TMP" >/dev/null 2>&1
  grep -qxF "$SR_TMP" "$SR_TMP/.claude/state/registry.txt" 2>/dev/null \
    && ok "self-register: registry entry added" || ng "self-register: should add registry entry"
  ensure_self_registered "$SR_TMP" >/dev/null 2>&1
  count=$(grep -cxF "$SR_TMP" "$SR_TMP/.claude/state/registry.txt" 2>/dev/null || echo 0)
  [ "$count" = "1" ] && ok "self-register: idempotent (1 entry after 2 runs)" \
    || ng "self-register: should be idempotent (got $count entries)"
else
  ng "self-register: ensure_self_registered undefined (Phase C not done)"
  ng "self-register: idempotency unverifiable without ensure_self_registered"
fi
rm -rf "$SR_TMP"

# 9b. register.sh against target==SHELL_ROOT skips workspace symlink-loop + still registers
# Isolate by copying register.sh and its lib deps into a fake shell root.
# Canonicalize via pwd -P so the registry's stored path matches our grep target
# (on macOS, mktemp returns /var/folders/... but pwd -P resolves to /private/var/...).
FAKE_SR=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$FAKE_SR/scripts/lib" "$FAKE_SR/.claude/state" "$FAKE_SR/.claude/agents" "$FAKE_SR/.claude/commands" "$FAKE_SR/workspace"
echo '{}' > "$FAKE_SR/.claude/settings.json"
cp "$SHELL_ROOT/scripts/register.sh" "$FAKE_SR/scripts/register.sh"
cp "$SHELL_ROOT/scripts/lib/inject.sh" "$FAKE_SR/scripts/lib/inject.sh"
[ -f "$SHELL_ROOT/scripts/lib/self_register.sh" ] && cp "$SHELL_ROOT/scripts/lib/self_register.sh" "$FAKE_SR/scripts/lib/self_register.sh"
chmod +x "$FAKE_SR/scripts/register.sh"

"$FAKE_SR/scripts/register.sh" "$FAKE_SR" >/dev/null 2>&1 || true

ws_link="$FAKE_SR/workspace/$(basename "$FAKE_SR")"
[ ! -e "$ws_link" ] && ok "register.sh: no workspace symlink-loop when target=SHELL_ROOT" \
  || ng "register.sh created workspace symlink-loop: $ws_link"

grep -qxF "$FAKE_SR" "$FAKE_SR/.claude/state/registry.txt" 2>/dev/null \
  && ok "register.sh: SHELL_ROOT recorded in registry" \
  || ng "register.sh did not register SHELL_ROOT"

rm -rf "$FAKE_SR"

# ---------- 10. bootstrap PATH-guidance phrasing (#4) ----------
# Bootstrap cannot see zsh/bash aliases in the parent shell, so a literal
# "not on PATH" warn is misleading whenever a user opts for the alias path.
# Issue #4: replace the false-alarm warn with neutral info that surfaces both
# install options and the alias-blindness caveat.
BOOTSTRAP="$SHELL_ROOT/scripts/bootstrap.sh"
grep -q 'not on PATH' "$BOOTSTRAP" \
  && ng "bootstrap.sh still emits misleading 'not on PATH' warn (#4)" \
  || ok "bootstrap.sh: no false-alarm 'not on PATH' warn"
grep -qE 'bin[[:space:]]+to PATH|bin/claude-eng' "$BOOTSTRAP" \
  && ok "bootstrap.sh: surfaces PATH install option" \
  || ng "bootstrap.sh: missing PATH install guidance"
grep -qE 'alias[[:space:]]+claude-eng' "$BOOTSTRAP" \
  && ok "bootstrap.sh: surfaces alias install option" \
  || ng "bootstrap.sh: missing alias install guidance"

# ---------- 11. operating modes (#7) ----------
# SPEC §5.7.1: /ship terminal behavior is mode-gated.
# - attended (default) stops at PR-ready.
# - unattended classifies blockers and either merges (clean) or parks (hard).
# Pre-impl: ship_mode.sh does not exist yet; the source line is guarded so
# the rest of the script keeps running. The function-not-defined asserts
# below are the intended Phase-B failures — Phase C will satisfy them.
SHIP_MODE_HELPER="$SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh"
# shellcheck disable=SC1090
[ -f "$SHIP_MODE_HELPER" ] && . "$SHIP_MODE_HELPER"

MODE_TMP=$(cd "$(mktemp -d)" && pwd -P)
export SHIP_PARK_LOG_PATH="$MODE_TMP/unattended-park.log"

# 11a. attended-default-stops
# With no mode surface set, resolve_mode → attended and the post-ready
# decision is `stop`. Isolate by clearing all surface inputs.
(
  unset CLAUDE_ENG_SHELL_MODE
  cd "$MODE_TMP"
  rm -f .claude/state/mode 2>/dev/null
  if command -v resolve_mode >/dev/null 2>&1 && command -v ship_decide_post_ready >/dev/null 2>&1; then
    mode=$(resolve_mode 2>/dev/null)
    decision=$(printf '{"state":"clean"}' | ship_decide_post_ready "$mode" 2>/dev/null)
    [ "$mode" = "attended" ] && [ "$decision" = "stop" ]
  else
    exit 1
  fi
) && ok "mode: attended default → stop" || ng "mode: attended default should stop (ship_mode.sh missing or wrong)"

# 11b. unattended + clean PR → merge
(
  export CLAUDE_ENG_SHELL_MODE=unattended
  if command -v ship_classify_blocker >/dev/null 2>&1 && command -v ship_decide_post_ready >/dev/null 2>&1; then
    clean_json='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"}],"reviewDecision":"APPROVED"}'
    class=$(printf '%s' "$clean_json" | ship_classify_blocker 2>/dev/null)
    decision=$(ship_decide_post_ready unattended "$class" 2>/dev/null)
    [ "$class" = "clean" ] && [ "$decision" = "merge" ]
  else
    exit 1
  fi
) && ok "mode: unattended + clean → merge" || ng "mode: unattended + clean should decide merge (ship_mode.sh missing or wrong)"

# 11c. unattended + hard blocker → park (+ comment string + log line)
(
  export CLAUDE_ENG_SHELL_MODE=unattended
  if command -v ship_classify_blocker >/dev/null 2>&1 \
     && command -v ship_decide_post_ready >/dev/null 2>&1 \
     && command -v ship_park_pr >/dev/null 2>&1; then
    # required reviews with no reviewer = hard
    hard_json='{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"conclusion":"SUCCESS"}],"reviewDecision":"REVIEW_REQUIRED","reviewRequests":[]}'
    class=$(printf '%s' "$hard_json" | ship_classify_blocker 2>/dev/null)
    decision=$(ship_decide_post_ready unattended "$class" 2>/dev/null)
    comment=$(ship_park_pr "review-required-no-reviewer" 2>/dev/null)
    [ "$class" = "hard" ] || exit 1
    [ "$decision" = "park" ] || exit 1
    # comment string must be non-empty and mention the reason token
    printf '%s' "$comment" | grep -q "review-required-no-reviewer" || exit 1
    # park log line written to the override path
    [ -f "$SHIP_PARK_LOG_PATH" ] || exit 1
    grep -q "review-required-no-reviewer" "$SHIP_PARK_LOG_PATH" || exit 1
  else
    exit 1
  fi
) && ok "mode: unattended + hard → park (comment + log)" || ng "mode: unattended + hard should park with comment+log (ship_mode.sh missing or wrong)"

# 11d. --mode= flag-source resolution (#10)
(
  unset CLAUDE_ENG_SHELL_MODE
  cd "$MODE_TMP"
  rm -f .claude/state/mode 2>/dev/null
  if command -v resolve_mode >/dev/null 2>&1; then
    mode=$(resolve_mode --mode=unattended 2>/dev/null)
    [ "$mode" = "unattended" ]
  else
    exit 1
  fi
) && ok "mode: --mode=unattended flag → unattended" || ng "mode: --mode flag not honored (#10)"

# 11e. .claude/state/mode file-source resolution (#10)
(
  unset CLAUDE_ENG_SHELL_MODE
  mkdir -p "$MODE_TMP/.claude/state"
  printf 'unattended\n' > "$MODE_TMP/.claude/state/mode"
  cd "$MODE_TMP"
  if command -v resolve_mode >/dev/null 2>&1; then
    mode=$(resolve_mode 2>/dev/null)
    [ "$mode" = "unattended" ]
  else
    exit 1
  fi
) && ok "mode: .claude/state/mode file → unattended" || ng "mode: file-source not honored (#10)"
rm -f "$MODE_TMP/.claude/state/mode" 2>/dev/null

# 11f. unattended + soft (CI pending) → fix-and-wait (#10)
(
  if command -v ship_classify_blocker >/dev/null 2>&1 && command -v ship_decide_post_ready >/dev/null 2>&1; then
    soft_json='{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"status":"PENDING"}],"reviewDecision":"APPROVED"}'
    class=$(printf '%s' "$soft_json" | ship_classify_blocker 2>/dev/null)
    decision=$(ship_decide_post_ready unattended "$class" 2>/dev/null)
    [ "$class" = "soft" ] && [ "$decision" = "fix-and-wait" ]
  else
    exit 1
  fi
) && ok "mode: unattended + soft → fix-and-wait" || ng "mode: soft → fix-and-wait dispatch wrong (#10)"

# 11g. classifier emits stderr warning on empty stdin (#10)
(
  if command -v ship_classify_blocker >/dev/null 2>&1; then
    err=$(printf '' | ship_classify_blocker 2>&1 1>/dev/null)
    printf '%s' "$err" | grep -q 'no input on stdin'
  else
    exit 1
  fi
) && ok "classify: empty stdin → stderr warning" || ng "classify: empty stdin should warn 'no input on stdin' (#10)"

# 11h. ship_park_pr idempotent on repeat (#10)
# Stubs `gh` via a tmpdir on PATH so the helper can check label presence
# without a real PR. First call: gh returns []; helper emits comment +
# appends park log. Second call: gh returns the unattended-parked label;
# helper writes `park-suppressed: <reason>` and emits nothing.
GH_SHIM_DIR="$MODE_TMP/gh-shim"
mkdir -p "$GH_SHIM_DIR"
cat > "$GH_SHIM_DIR/gh" <<'SHIM'
#!/bin/sh
# Smoke shim — mimics `gh pr view --json labels --jq '.labels[].name'`:
# outputs one label name per line (the real gh's --jq behavior).
case "$*" in
  *"pr view"*"--jq"*)
    if [ -f "$GH_SHIM_STATE/labeled" ]; then
      printf 'unattended-parked\n'
    fi
    ;;
esac
SHIM
chmod +x "$GH_SHIM_DIR/gh"

(
  export GH_SHIM_STATE="$MODE_TMP"
  export PATH="$GH_SHIM_DIR:$PATH"
  export SHIP_PARK_LOG_PATH="$MODE_TMP/idempotent-park.log"
  rm -f "$GH_SHIM_STATE/labeled" "$SHIP_PARK_LOG_PATH" 2>/dev/null
  if command -v ship_park_pr >/dev/null 2>&1; then
    comment1=$(ship_park_pr "idempotence-test" 2>/dev/null)
    [ -n "$comment1" ] || exit 1
    grep -q "idempotence-test" "$SHIP_PARK_LOG_PATH" || exit 1
    touch "$GH_SHIM_STATE/labeled"
    comment2=$(ship_park_pr "idempotence-test" 2>/dev/null)
    [ -z "$comment2" ] || exit 1
    grep -q "park-suppressed:.*idempotence-test" "$SHIP_PARK_LOG_PATH" || exit 1
  else
    exit 1
  fi
) && ok "park: idempotent on repeat (no comment, park-suppressed log)" || ng "park: not idempotent on repeat (#10)"

# 11i. classifier emits stderr warning when jq is missing (#13)
# Strip jq's directory from PATH (so `command -v jq` returns false) while
# keeping other essentials (cat, grep) reachable via the rest of PATH.
# Skip cleanly if jq isn't installed (nothing to remove) or somehow still
# resolves after removal (multi-locations, exec-shadow, etc.).
(
  jq_path=$(command -v jq 2>/dev/null)
  if [ -z "$jq_path" ]; then
    exit 0  # no jq on PATH already; nothing to test
  fi
  jq_dir=$(dirname "$jq_path")
  NEW_PATH=$(printf '%s' "$PATH" | awk -v d="$jq_dir" 'BEGIN{RS=":"}$0!=d{printf "%s%s",sep,$0;sep=":"}')
  # If stripping jq's directory also strips an essential (grep/cat live there
  # too — common when jq is in /usr/bin alongside everything), skip cleanly.
  # `command -v` is unreliable for grep (often a shell alias/function);
  # actually invoke the tools in a subshell with the stripped PATH.
  if ! ( PATH="$NEW_PATH" cat /dev/null && PATH="$NEW_PATH" grep --version >/dev/null 2>&1 ); then
    exit 0
  fi
  PATH="$NEW_PATH"
  if command -v jq >/dev/null 2>&1; then
    exit 0  # jq still resolvable somehow; assert n/a
  fi
  if command -v ship_classify_blocker >/dev/null 2>&1; then
    err=$(printf '{}' | ship_classify_blocker 2>&1 1>/dev/null)
    printf '%s' "$err" | grep -q 'jq not found'
  else
    exit 1
  fi
) && ok "classify: missing jq → stderr warning" || ng "classify: missing jq should warn 'jq not found' (#13)"

# 11j. park label-presence check tolerates trailing whitespace (#13)
# Real gh --jq output is clean, but a shim or future formatter that emits
# trailing whitespace on label names shouldn't silently miss-match. Use a
# whitespace-padded shim variant to assert robustness.
GH_SHIM_PAD_DIR="$MODE_TMP/gh-shim-pad"
mkdir -p "$GH_SHIM_PAD_DIR"
cat > "$GH_SHIM_PAD_DIR/gh" <<'SHIM'
#!/bin/sh
case "$*" in
  *"pr view"*"--jq"*)
    if [ -f "$GH_SHIM_STATE/labeled" ]; then
      printf 'unattended-parked  \n'
    fi
    ;;
esac
SHIM
chmod +x "$GH_SHIM_PAD_DIR/gh"

(
  export GH_SHIM_STATE="$MODE_TMP"
  export PATH="$GH_SHIM_PAD_DIR:$PATH"
  export SHIP_PARK_LOG_PATH="$MODE_TMP/whitespace-park.log"
  rm -f "$SHIP_PARK_LOG_PATH" 2>/dev/null
  touch "$GH_SHIM_STATE/labeled"
  if command -v ship_park_pr >/dev/null 2>&1; then
    comment=$(ship_park_pr "whitespace-test" 2>/dev/null)
    # Label is "present" (just padded); helper must suppress: no comment,
    # park-suppressed line in log.
    [ -z "$comment" ] || exit 1
    grep -q "park-suppressed:.*whitespace-test" "$SHIP_PARK_LOG_PATH" || exit 1
  else
    exit 1
  fi
) && ok "park: tolerates trailing whitespace on label name" || ng "park: whitespace on label slipped past label-presence check (#13)"

rm -f "$MODE_TMP/labeled" 2>/dev/null
unset SHIP_PARK_LOG_PATH
rm -rf "$MODE_TMP"

# ---------- 12. /work-on first-commit policy (#9) ----------
# SPEC §5.3 step 7: the first commit on a /work-on branch is Phase A,
# never an empty seed. work-on.md (the live skill) must match.
WORK_ON="$SHELL_ROOT/.claude/commands/work-on.md"
# Negative: catch the original imperative-instruction tokens. We deliberately
# *don't* match prose like "seed commit" / "placeholder commit" because the
# file's own prohibition uses those phrases ("Don't fall back to an empty seed
# commit..."); broadening the regex collides with the prohibition wording.
# The stronger guard is the positive assert below — it requires the new
# Phase-A wording to be present, which a regression couldn't satisfy.
if grep -qE 'allow-empty|Empty commit \+ push' "$WORK_ON"; then
  ng "work-on.md still instructs empty-seed commit (#9)"
else
  ok "work-on.md: no empty-seed instruction"
fi
# Stronger positive: 'Phase A' and 'first commit' must appear on the same line
# (the step-7 prose). Mere presence of either word elsewhere doesn't satisfy.
if grep -qE 'Phase A.*first commit|first commit.*Phase A' "$WORK_ON"; then
  ok "work-on.md: step 7 binds Phase A to the first commit"
else
  ng "work-on.md: step 7 should bind 'Phase A' to 'first commit' on one line (#9)"
fi

# ---------- 13. status helper (#15) ----------
# SPEC §5.5: /status + UserPromptSubmit both delegate to .claude/hooks/helpers/status.sh.
# Helper must expose status_compact (plaintext block) and status_json (valid JSON).
STATUS_HELPER="$SHELL_ROOT/.claude/hooks/helpers/status.sh"
# shellcheck disable=SC1090
[ -f "$STATUS_HELPER" ] && . "$STATUS_HELPER"

if command -v status_compact >/dev/null 2>&1; then
  ok "status: helper sourceable, status_compact defined"
else
  ng "status: status.sh missing or status_compact undefined (#15)"
fi

# 13a. status_compact emits a `branch:` line on a sane invocation.
(
  cd "$SHELL_ROOT" || exit 1
  if command -v status_compact >/dev/null 2>&1; then
    out=$(status_compact 2>/dev/null)
    printf '%s' "$out" | grep -q '^branch:'
  else
    exit 1
  fi
) && ok "status: status_compact emits 'branch:' line" || ng "status: status_compact missing branch line (#15)"

# 13b. status_json is valid JSON.
(
  cd "$SHELL_ROOT" || exit 1
  if command -v status_json >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    out=$(status_json 2>/dev/null)
    printf '%s' "$out" | jq -e . >/dev/null 2>&1
  else
    exit 1
  fi
) && ok "status: status_json is valid JSON" || ng "status: status_json invalid or undefined (#15)"

# 13c. user_prompt_submit.sh sources the helper (no hand-rolled branch summary).
if grep -q 'status_compact' "$SHELL_ROOT/.claude/hooks/user_prompt_submit.sh"; then
  ok "user_prompt_submit: delegates to status_compact"
else
  ng "user_prompt_submit still hand-rolls branch summary (#15)"
fi

# ---------- 14. /sync-pr body cache (#16) ----------
# SPEC §5.4: persistent SHA-256 cache at
# .claude/state/pr-cache/<owner>__<repo>__pr-<n>.json. pr_cache_check exits
# 0 when cache absent or matches, non-zero on mismatch (external edit).
PR_CACHE_HELPER="$SHELL_ROOT/.claude/hooks/helpers/pr_cache.sh"
# shellcheck disable=SC1090
[ -f "$PR_CACHE_HELPER" ] && . "$PR_CACHE_HELPER"

if command -v pr_cache_read >/dev/null 2>&1 \
   && command -v pr_cache_write >/dev/null 2>&1 \
   && command -v pr_cache_check >/dev/null 2>&1; then
  ok "pr_cache: helper sourceable, functions defined"
else
  ng "pr_cache: helper missing or functions undefined (#16)"
fi

CACHE_TMP=$(cd "$(mktemp -d)" && pwd -P)

# 14a. first sync — no cache → pr_cache_check exits 0; write populates cache.
(
  export PR_CACHE_DIR="$CACHE_TMP"
  if command -v pr_cache_check >/dev/null 2>&1 && command -v pr_cache_write >/dev/null 2>&1; then
    # Fresh state — check should exit 0 (no cache = no conflict).
    pr_cache_check 99 "deadbeef" 2>/dev/null || exit 1
    pr_cache_write 99 "deadbeef" "abc123" 2>/dev/null || exit 1
    # Cache file should now exist.
    [ -f "$CACHE_TMP"/*pr-99.json ] || exit 1
  else
    exit 1
  fi
) && ok "pr_cache: first sync writes cache, check passes when empty" || ng "pr_cache: first-sync path broken (#16)"

# 14b. repeat sync — same SHA → check exits 0.
(
  export PR_CACHE_DIR="$CACHE_TMP"
  if command -v pr_cache_check >/dev/null 2>&1; then
    pr_cache_check 99 "deadbeef" 2>/dev/null
  else
    exit 1
  fi
) && ok "pr_cache: repeat sync with matching SHA → proceed" || ng "pr_cache: repeat sync rejected matching SHA (#16)"

# 14c. external edit — different SHA → check exits non-zero with stderr "external edit".
(
  export PR_CACHE_DIR="$CACHE_TMP"
  if command -v pr_cache_check >/dev/null 2>&1; then
    err=$(pr_cache_check 99 "differenthash" 2>&1 >/dev/null)
    # Should exit non-zero
    pr_cache_check 99 "differenthash" 2>/dev/null && exit 1
    # And stderr should name the conflict
    printf '%s' "$err" | grep -qi 'external edit'
  else
    exit 1
  fi
) && ok "pr_cache: mismatched SHA → abort with 'external edit' stderr" || ng "pr_cache: external-edit detection broken (#16)"

# 14d. collision-safe key — `acme/my_repo` and `acme_my/repo` produce
# distinct cache files. Current `tr '/' '_'` scheme collapses both to
# `acme_my_repo`; expected behavior (per #21) is URL-encoded `/` as `%2F`.
(
  export PR_CACHE_DIR="$CACHE_TMP/collision"
  mkdir -p "$PR_CACHE_DIR"
  if command -v pr_cache_write >/dev/null 2>&1; then
    PR_CACHE_REPO="acme/my_repo" pr_cache_write 1 "hash-A" "head-A" 2>/dev/null
    PR_CACHE_REPO="acme_my/repo" pr_cache_write 1 "hash-B" "head-B" 2>/dev/null
    # Two distinct files must exist; total count = 2, not 1.
    count=$(ls "$PR_CACHE_DIR"/*pr-1.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" = "2" ]
  else
    exit 1
  fi
) && ok "pr_cache: collision-safe key — owner/repo and owner_/repo distinct" || ng "pr_cache: key collision between 'acme/my_repo' and 'acme_my/repo' (#21)"

# 14e. corrupt cache — file exists but unparseable → pr_cache_check aborts
# with stderr 'corrupt'. Distinct from "absent" (which proceeds as first sync).
(
  export PR_CACHE_DIR="$CACHE_TMP/corrupt"
  mkdir -p "$PR_CACHE_DIR"
  if command -v pr_cache_check >/dev/null 2>&1 && command -v pr_cache_write >/dev/null 2>&1; then
    # Determine the key the helper would use (uses PR_CACHE_REPO override).
    PR_CACHE_REPO="testowner/testrepo" pr_cache_write 5 "validhash" "headsha" 2>/dev/null
    # Find the file just written and corrupt it.
    target=$(ls "$PR_CACHE_DIR"/*pr-5.json 2>/dev/null | head -1)
    [ -n "$target" ] || exit 1
    printf 'this is not json {[' > "$target"
    # pr_cache_check should now exit non-zero, naming the corruption on stderr.
    err=$(PR_CACHE_REPO="testowner/testrepo" pr_cache_check 5 "validhash" 2>&1 >/dev/null)
    PR_CACHE_REPO="testowner/testrepo" pr_cache_check 5 "validhash" 2>/dev/null && exit 1
    printf '%s' "$err" | grep -qi 'corrupt'
  else
    exit 1
  fi
) && ok "pr_cache: corrupt cache → abort with 'corrupt' stderr" || ng "pr_cache: corrupt cache silently treated as first sync (#21)"

rm -rf "$CACHE_TMP"

# ---------- 15. pre_tool_use hardening (#17) ----------
# Drives pre_tool_use.sh with synthesized PreToolUse JSON. The hook must:
#   - Block multiline backslash-continued force-push.
#   - Block rm -rf ${HOME}/... (curly-brace HOME form).
#   - NOT block eval/bash -c, but emit audit_log warn under
#     category 'bypass-suspect'.
#   - Continue to block single-line force-push (regression guard).
HOOK="$SHELL_ROOT/.claude/hooks/pre_tool_use.sh"
HOOK_TMP=$(cd "$(mktemp -d)" && pwd -P)
HOOK_AUDIT="$HOOK_TMP/audit.jsonl"

# Ensure SHELL_ROOT is in the (isolated) registry. hook_run cd's into
# $TMP/fake (already in registry from §4 via inject_into), not SHELL_ROOT,
# but several §18 cases reason about "paths under SHELL_ROOT" being in
# scope — so SHELL_ROOT must also be registered for those checks to
# resolve correctly. The registry was backed up at smoke start and is
# restored at the end; appending here is local to this run.
grep -qxF "$SHELL_ROOT" "$SHELL_ROOT/.claude/state/registry.txt" 2>/dev/null \
  || printf '%s\n' "$SHELL_ROOT" >> "$SHELL_ROOT/.claude/state/registry.txt"

# Drive the hook with a synthesized Bash PreToolUse payload.
#
# Runs from `$TMP/fake` (created and registered in §4 on branch
# `smoke/feat/1-test`) — NOT from `$SHELL_ROOT`. The shell repo's
# current branch is whatever the developer / CI happens to check out
# (it's `main` for `push: main` CI runs), and the commit gate's
# protected-branch matcher would otherwise false-fire on the
# commit-format / GIT_PREFIX / heredoc tests that expect rc=0.
# Routing through the fake repo's non-protected branch makes the smoke
# branch-independent. See issue #41.
#
# Args: <command string>. Echoes exit code; hook writes audit to real log.
hook_run() {
  local cmd="$1"
  (
    cd "$TMP/fake"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | jq -Rs .)" \
      | CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
        bash "$HOOK" >/dev/null 2>&1
    printf '%s' "$?"
  )
}

# Sanity: hook tests rely on $TMP/fake being on a non-protected branch.
# Lock this with an explicit assertion so a future tweak to §4's setup
# cannot silently reintroduce the bug.
hook_env_branch=$(cd "$TMP/fake" && git symbolic-ref --short HEAD 2>/dev/null)
case "$hook_env_branch" in
  main|master|release/*)
    ng "hook test env: \$TMP/fake on protected branch '$hook_env_branch' (#41)" ;;
  *)
    ok "hook test env: non-protected branch '$hook_env_branch' for hook_run (#41)" ;;
esac

# 15a. multiline force-push (backslash continuation) — blocked.
multiline_cmd=$(printf 'git \\\n  push \\\n  --force-with-lease')
if [ "$(hook_run "$multiline_cmd")" = "2" ]; then
  ok "hook: multiline force-push blocked"
else
  ng "hook: multiline force-push not blocked (#17)"
fi

# 15b. rm -rf ${HOME}/foo — out-of-scope blocked.
if [ "$(hook_run 'rm -rf ${HOME}/foo')" = "2" ]; then
  ok "hook: rm -rf \${HOME}/foo blocked"
else
  ng "hook: rm -rf \${HOME}/foo not blocked (#17)"
fi

# 15c. Benign eval — NOT blocked (exit 0) and audit-warn entry written.
# Uses `eval "ls"` so no downstream matcher fires; bypass-suspect should
# NOT short-circuit downstream matchers, so we test with a clean inner
# command. (`eval "git push --force"` should still BLOCK — covered by
# the regression in 15d's spirit: downstream matchers stay active.)
REAL_AUDIT="$SHELL_ROOT/.claude/audit/audit.jsonl"
mkdir -p "$(dirname "$REAL_AUDIT")" 2>/dev/null
before_count=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' ')
[ -z "$before_count" ] && before_count=0
eval_exit=$(hook_run 'eval "ls -la"')
after_count=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' ')
[ -z "$after_count" ] && after_count=0
delta=$((after_count - before_count))
if [ "$eval_exit" = "0" ] && [ "$delta" -ge 1 ] \
   && tail -n "$delta" "$REAL_AUDIT" 2>/dev/null | grep -q 'bypass-suspect'; then
  ok "hook: benign eval emits warn audit, no block"
else
  ng "hook: benign eval should warn-not-block (exit=$eval_exit delta=$delta) (#17)"
fi

# 15e. `eval "git push --force"` — bypass-suspect warns AND downstream
# force-push matcher still blocks (no security regression from the warn).
before_count=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' ')
[ -z "$before_count" ] && before_count=0
eval_bad_exit=$(hook_run 'eval "git push --force"')
after_count=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' ')
[ -z "$after_count" ] && after_count=0
delta=$((after_count - before_count))
if [ "$eval_bad_exit" = "2" ] && [ "$delta" -ge 1 ]; then
  ok "hook: eval+force-push still blocked (no regression)"
else
  ng "hook: eval+force-push should still block (exit=$eval_bad_exit) (#17)"
fi

# 15d. single-line force-push (regression).
if [ "$(hook_run 'git push --force')" = "2" ]; then
  ok "hook: single-line force-push still blocked"
else
  ng "hook: single-line force-push regression (#17)"
fi

rm -rf "$HOOK_TMP"

# ---------- 16. heredoc -m subject extraction (#28) ----------
# pre_tool_use must accept the heredoc `-m "$(cat <<'TAG' ... TAG )"` form
# used for multi-line commit bodies (Co-Authored-By trailer). Today the
# subject extractor only handles plain quoted -m; heredoc form yields a
# captured "subject" of the entire `$(cat <<...EOF )` substring which
# fails the CC regex and incorrectly blocks the commit.

# 16a. heredoc with a valid CC subject — must NOT be blocked on commit-format.
valid_heredoc=$(printf '%s\n' \
  "git commit -m \"\$(cat <<'EOF'" \
  "feat(#1): heredoc subject" \
  "" \
  "body line" \
  "EOF" \
  ")\"")
exit_code=$(hook_run "$valid_heredoc")
if [ "$exit_code" = "0" ]; then
  ok "heredoc -m: valid CC subject not blocked (#28)"
else
  ng "heredoc -m: valid CC subject incorrectly blocked, exit=$exit_code (#28)"
fi

# 16b. heredoc with a malformed subject — must be blocked on commit-format.
bad_heredoc=$(printf '%s\n' \
  "git commit -m \"\$(cat <<'EOF'" \
  "broken subject without conventional commits format" \
  "" \
  "body" \
  "EOF" \
  ")\"")
exit_code=$(hook_run "$bad_heredoc")
if [ "$exit_code" = "2" ]; then
  ok "heredoc -m: malformed subject still blocked (#28)"
else
  ng "heredoc -m: malformed subject should block, exit=$exit_code (#28)"
fi

# 16c. plain quoted -m regression — still works.
plain_ok='git commit -m "feat(#1): plain subject"'
exit_code=$(hook_run "$plain_ok")
if [ "$exit_code" = "0" ]; then
  ok "plain -m: regression — still passes (#28)"
else
  ng "plain -m: regression — incorrectly blocked, exit=$exit_code (#28)"
fi

# 16d. plain quoted -m with malformed subject — still blocks.
plain_bad='git commit -m "not a conventional commit"'
exit_code=$(hook_run "$plain_bad")
if [ "$exit_code" = "2" ]; then
  ok "plain -m: malformed still blocks (#28)"
else
  ng "plain -m: malformed should still block, exit=$exit_code (#28)"
fi

# ---------- 22. git option-prefix matcher tolerance (#37) ----------
# Every `git <subcommand>` matcher must accept the `git -c <opt>=<val>`,
# `git -C <path>`, and `git --no-pager` prefixes between `git` and the
# subcommand. Pre-fix, the strict `\bgit\s+<subcmd>\b` matchers silently
# allowed any prefixed form, disabling every downstream check.

if [ "$(hook_run 'git -c rerere.enabled=true push --force')" = "2" ]; then
  ok "matcher: git -c <opt> push --force still blocked (#37)"
else
  ng "matcher: git -c <opt> push --force slipped past (#37)"
fi

if [ "$(hook_run 'git -C /tmp/repo push origin main')" = "2" ]; then
  ok "matcher: git -C <path> push origin main blocked (#37)"
else
  ng "matcher: git -C <path> push to main slipped past (#37)"
fi

if [ "$(hook_run 'git -c gc.auto=0 reset --hard')" = "2" ]; then
  ok "matcher: git -c <opt> reset --hard blocked (#37)"
else
  ng "matcher: git -c <opt> reset --hard slipped past (#37)"
fi

if [ "$(hook_run 'git -c receive.unpackLimit=0 clean -fd')" = "2" ]; then
  ok "matcher: git -c <opt> clean -fd blocked (#37)"
else
  ng "matcher: git -c <opt> clean -fd slipped past (#37)"
fi

# commit-format check must fire under -c prefix; a non-CC subject blocks.
if [ "$(hook_run 'git -c commit.gpgsign=false commit -m "not a CC subject"')" = "2" ]; then
  ok "matcher: git -c <opt> commit triggers commit-format check (#37)"
else
  ng "matcher: git -c <opt> commit bypasses commit-format (#37)"
fi

# --no-pager prefix on commit also reaches the gate.
if [ "$(hook_run 'git --no-pager commit -m "still not CC"')" = "2" ]; then
  ok "matcher: git --no-pager commit triggers commit-format (#37)"
else
  ng "matcher: git --no-pager commit bypasses commit-format (#37)"
fi

# Regression: bare valid form still passes.
if [ "$(hook_run 'git commit -m "feat(#1): subject"')" = "0" ]; then
  ok "matcher: bare git commit with valid CC subject still passes (#37)"
else
  ng "matcher: bare git commit regression (#37)"
fi

# Regression: bare destructive form still blocked.
if [ "$(hook_run 'git push --force')" = "2" ]; then
  ok "matcher: bare git push --force regression — still blocked (#37)"
else
  ng "matcher: bare git push --force regression (#37)"
fi

# Broadened option set: --no-optional-locks and -p (short for --paginate)
# must also be tolerated.
if [ "$(hook_run 'git --no-optional-locks push --force')" = "2" ]; then
  ok "matcher: git --no-optional-locks push --force blocked (#37)"
else
  ng "matcher: --no-optional-locks form slipped past (#37)"
fi
if [ "$(hook_run 'git -p commit -m "still not CC"')" = "2" ]; then
  ok "matcher: git -p commit triggers commit-format (#37)"
else
  ng "matcher: git -p commit bypasses commit-format (#37)"
fi

# ---------- 23. SKIP_HOOKS env-prefix parsing (#38) ----------
# SPEC §7 documents the escape hatch as a leading env-prefix on the
# command. Claude Code's hook subprocess does not inherit env-prefixes
# from the command string; the hook must parse them itself.

# Helper: count audit lines + the last N entries.
audit_lines() { wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' '; }

# 23a. SKIP_HOOKS=force-push (matching category) → allow + escape audit.
before=$(audit_lines); [ -z "$before" ] && before=0
rc=$(hook_run "SKIP_HOOKS=force-push SKIP_REASON=emergency git push --force")
after=$(audit_lines); [ -z "$after" ] && after=0
delta=$((after - before))
if [ "$rc" = "0" ] && [ "$delta" -ge 1 ] \
   && tail -n "$delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"category":"force-push"' \
   && tail -n "$delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"event":"escape"'; then
  ok "skip: env-prefix SKIP_HOOKS=force-push reaches the hook (#38)"
else
  ng "skip: env-prefix SKIP_HOOKS=force-push not honored (rc=$rc, delta=$delta) (#38)"
fi

# 23b. SKIP_HOOKS=all matches every category → allow.
rc=$(hook_run "SKIP_HOOKS=all SKIP_REASON=ack git push --force")
if [ "$rc" = "0" ]; then
  ok "skip: env-prefix SKIP_HOOKS=all skips force-push (#38)"
else
  ng "skip: SKIP_HOOKS=all should allow (rc=$rc) (#38)"
fi

# 23c. SKIP_HOOKS=branch (mismatched category) → still blocks force-push.
rc=$(hook_run "SKIP_HOOKS=branch SKIP_REASON=wrong git push --force")
if [ "$rc" = "2" ]; then
  ok "skip: env-prefix with mismatched category still blocks (#38)"
else
  ng "skip: mismatched SKIP_HOOKS should still block (rc=$rc) (#38)"
fi

# 23d. bare command (no prefix) → unchanged.
rc=$(hook_run 'git push --force')
if [ "$rc" = "2" ]; then
  ok "skip: bare force-push regression — still blocked (#38)"
else
  ng "skip: bare force-push regression (#38)"
fi

# 23e. SKIP_REASON containing 'rm -rf'-shaped text doesn't trigger the
# destructive matcher under env-prefix stripping. SKIP_REASON value is
# stripped from cmd before the destructive matcher sees it.
rc=$(hook_run "SKIP_HOOKS=force-push SKIP_REASON='reason contains rm -rf /etc' git push --force")
if [ "$rc" = "0" ]; then
  ok "skip: SKIP_REASON content doesn't bleed into other matchers (#38)"
else
  ng "skip: SKIP_REASON content false-triggered another matcher (rc=$rc) (#38)"
fi

# 23f. SECURITY: only SKIP_HOOKS / SKIP_REASON are allow-listed. The
# reviewer's attack vector — `PATH=/evil <cmd>` — would let an attacker
# redirect downstream `command -v` lookups in detect_lint_cmd /
# detect_format_cmd, landing their binary inside the guardrail's eval.
# Drive parse_env_prefix with a bare PATH= prefix and assert PATH stays
# untouched. The first non-allowed token also halts the parser, so
# PATH= itself is left in the stripped cmd (matchers will ignore it).
PATH_PROBE_DIR=$(mktemp -d)
cat > "$PATH_PROBE_DIR/probe.sh" <<'PROBE'
#!/usr/bin/env bash
SHELL_ROOT="$1"
. "$SHELL_ROOT/.claude/hooks/helpers/log.sh"
. "$SHELL_ROOT/.claude/hooks/helpers/escape.sh"
test_cmd='PATH=/evil:/should/not/win ls -la'
EXPECTED_PATH="$PATH"
parse_env_prefix "$test_cmd" stripped
if [ "$PATH" = "$EXPECTED_PATH" ]; then
  echo PATH:preserved
else
  echo PATH:CLOBBERED
fi
PROBE
chmod +x "$PATH_PROBE_DIR/probe.sh"
probe_out=$(bash "$PATH_PROBE_DIR/probe.sh" "$SHELL_ROOT")
if [ "$probe_out" = "PATH:preserved" ]; then
  ok "skip: PATH= prefix NOT exported into hook (allow-list works) (#38)"
else
  ng "skip: PATH= prefix exported — allow-list bypassed [$probe_out] (#38)"
fi
rm -rf "$PATH_PROBE_DIR"

# 23g. Outvar-collision regression: passing `cmd` as outvar (the same
# name the function uses internally for its parameter) must NOT drop
# the stripped value. This exercises the bash dynamic-scope hazard
# the helper's internals avoid via the _pep_ prefix.
COLLIDE_PROBE=$(mktemp -d)
cat > "$COLLIDE_PROBE/probe.sh" <<'PROBE'
#!/usr/bin/env bash
SHELL_ROOT="$1"
. "$SHELL_ROOT/.claude/hooks/helpers/log.sh"
. "$SHELL_ROOT/.claude/hooks/helpers/escape.sh"
cmd='SKIP_HOOKS=force-push SKIP_REASON=ok the-rest'
parse_env_prefix "$cmd" cmd
echo "cmd=$cmd"
PROBE
chmod +x "$COLLIDE_PROBE/probe.sh"
collide_out=$(bash "$COLLIDE_PROBE/probe.sh" "$SHELL_ROOT")
if [ "$collide_out" = "cmd=the-rest" ]; then
  ok "skip: parse_env_prefix outvar='cmd' is not shadowed by internals (#38)"
else
  ng "skip: outvar='cmd' collision drops stripped value [$collide_out] (#38)"
fi
rm -rf "$COLLIDE_PROBE"

# post_tool_use reminder fires under option-prefix forms too. The hook
# emits the reminder on stderr; assert it shows up under a -c prefix.
POST_HOOK="$SHELL_ROOT/.claude/hooks/post_tool_use.sh"
post_run() {
  local cmd="$1"
  (
    cd "$SHELL_ROOT"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | jq -Rs .)" \
      | CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
        bash "$POST_HOOK" 2>&1 >/dev/null
  )
}
post_out=$(post_run 'git -c commit.gpgsign=false commit -m "feat(#1): x"')
if printf '%s' "$post_out" | grep -q "update the matching PR body checklist"; then
  ok "post_tool_use: git -c <opt> commit triggers PR reminder (#37)"
else
  ng "post_tool_use: option-prefix commit silently skips reminder (#37)"
fi

# ---------- 21. detached HEAD on protected tip (#30) ----------
# is_protected_branch must treat detached HEAD on the tip commit of any
# protected branch (main/master/release/*) as on-protected, so the commit
# and edit gates fire as designed. Detached HEAD on an unprotected commit
# stays allowed (no false positives).

. "$SHELL_ROOT/.claude/hooks/helpers/branch_guard.sh"

DETACHED_DIR=$(mktemp -d)
# Local config: disable GPG signing (user-global signing config can otherwise
# silently break --allow-empty commits in this fake repo) and set a deterministic
# author so commits succeed in CI.
detached_git() { git -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
# Also sanity-check branch_label gives the promised detached-on-tip string.
(
  cd "$DETACHED_DIR" || exit 1
  git init -q
  git checkout -q -b main 2>/dev/null || git checkout -q main
  detached_git commit --allow-empty -q -m "init"
  MAIN_SHA=$(git rev-parse HEAD)
  detached_git -c advice.detachedHead=false checkout -q "$MAIN_SHA"
  label=$(branch_label)
  case "$label" in HEAD@*"(detached, == main)") exit 0 ;; *) exit 1 ;; esac
) && ok "branch_guard: branch_label emits 'HEAD@<short> (detached, == main)' on tip (#30)" \
   || ng "branch_guard: branch_label missing or wrong format on detached tip (#30)"
rm -rf "$DETACHED_DIR"
DETACHED_DIR=$(mktemp -d)
(
  cd "$DETACHED_DIR" || exit 1
  git init -q
  git checkout -q -b main 2>/dev/null || git checkout -q main
  detached_git commit --allow-empty -q -m "init"
  MAIN_SHA=$(git rev-parse HEAD)
  detached_git -c advice.detachedHead=false checkout -q "$MAIN_SHA"
  is_protected_branch
) && ok "branch_guard: detached HEAD on main's tip → protected (#30)" \
   || ng "branch_guard: detached HEAD on protected tip not detected (#30)"

(
  cd "$DETACHED_DIR" || exit 1
  detached_git checkout -q main
  detached_git commit --allow-empty -q -m "second"
  FIRST_SHA=$(git rev-parse HEAD~1)
  detached_git -c advice.detachedHead=false checkout -q "$FIRST_SHA"
  ! is_protected_branch
) && ok "branch_guard: detached HEAD on non-tip SHA → unprotected (#30)" \
   || ng "branch_guard: detached HEAD on non-tip SHA falsely protected (#30)"

rm -rf "$DETACHED_DIR"

# ---------- 20. audit_log JSONL safety (#26) ----------
# audit_log must produce one valid JSON object per line regardless of the
# `reason` contents — including newlines, tabs, carriage returns.

AUDIT_TMP=$(mktemp -d)
mkdir -p "$AUDIT_TMP/.claude/audit"
(
  export CLAUDE_ENG_SHELL_ROOT="$AUDIT_TMP"
  # Source the helper fresh in the subshell so it picks up the override.
  . "$SHELL_ROOT/.claude/hooks/helpers/log.sh"
  # 20a. multi-line reason → exactly one new line in audit.jsonl.
  audit_log block test deny $'line1\nline2\nline3'
  audit_log warn other notice $'tab\there'
  lines=$(wc -l < "$AUDIT_TMP/.claude/audit/audit.jsonl" | tr -d ' ')
  [ "$lines" = "2" ] || exit 1
  # 20b. jq -c parses the whole file cleanly.
  if command -v jq >/dev/null 2>&1; then
    jq -c '.' "$AUDIT_TMP/.claude/audit/audit.jsonl" >/dev/null || exit 1
    # reason field must round-trip the embedded newline.
    first_reason=$(jq -r 'select(.event=="block") | .reason' "$AUDIT_TMP/.claude/audit/audit.jsonl")
    case "$first_reason" in *$'\n'*) ;; *) exit 1 ;; esac
  fi
) && ok "audit_log: multi-line reason → one record, parseable, round-trips (#26)" \
   || ng "audit_log: multi-line reason corrupts JSONL (#26)"

# 20c. cwd with shell metacharacters (legal POSIX path) must also be
# JSON-encoded — the reviewer flagged this as the adjacent integrity gap.
AUDIT_QUOTED_DIR="$AUDIT_TMP/dir\"with-quote"
mkdir -p "$AUDIT_QUOTED_DIR"
(
  export CLAUDE_ENG_SHELL_ROOT="$AUDIT_TMP"
  cd "$AUDIT_QUOTED_DIR" || exit 1
  . "$SHELL_ROOT/.claude/hooks/helpers/log.sh"
  audit_log block test deny "simple reason"
  if command -v jq >/dev/null 2>&1; then
    jq -c '.' "$AUDIT_TMP/.claude/audit/audit.jsonl" >/dev/null
  else
    # Without jq we can only assert one-line-per-record.
    true
  fi
) && ok "audit_log: cwd with embedded quote stays JSONL-parseable (#26)" \
   || ng "audit_log: cwd metachar corrupts JSONL (#26)"
rm -rf "$AUDIT_TMP"

# ---------- 29. status_compact gh-cache (#53) ----------
# helpers/status.sh now caches gh outputs per-branch at
# .claude/state/status-cache/<branch>.json with STATUS_CACHE_TTL (default
# 5s). When the cache is fresh, _status_collect must NOT shell out to gh.
# We assert this by stubbing `gh` to a script that errors on any call;
# fresh-cache invocation should succeed regardless. Stale/missing cache
# must invoke gh and persist a fresh cache file.
STATUS_PROBE_DIR=$(mktemp -d)
STATUS_GH_SHIM_ERR="$STATUS_PROBE_DIR/bin-err"
STATUS_GH_SHIM_OK="$STATUS_PROBE_DIR/bin-ok"
STATUS_CACHE_DIR="$STATUS_PROBE_DIR/state/status-cache"
STATUS_GH_MARKER="$STATUS_PROBE_DIR/gh-was-called"
mkdir -p "$STATUS_GH_SHIM_ERR" "$STATUS_GH_SHIM_OK" "$STATUS_CACHE_DIR"
STATUS_GH_ERR_MARKER="$STATUS_PROBE_DIR/gh-err-was-called"
cat > "$STATUS_GH_SHIM_ERR/gh" <<SHIM
#!/bin/sh
touch '$STATUS_GH_ERR_MARKER'
echo "STUB: gh should not have been called (fresh cache expected)" >&2
exit 99
SHIM
cat > "$STATUS_GH_SHIM_OK/gh" <<SHIM
#!/bin/sh
touch '$STATUS_GH_MARKER'
case "\$*" in
  *"pr view"*) echo '{"number":1,"isDraft":false,"title":"t","body":""}' ;;
  *"pr checks"*) echo '' ;;
  *) echo '' ;;
esac
SHIM
chmod +x "$STATUS_GH_SHIM_ERR/gh" "$STATUS_GH_SHIM_OK/gh"

# 29a. Fresh cache → no gh call. Assert by checking the err-stub marker
# was NOT created (the stub exits 99; a real cache-miss would call it).
(
  cd "$SHELL_ROOT"
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "$branch" ] || exit 1
  safe_branch=$(printf '%s' "$branch" | tr '/' '_')
  cache_file="$STATUS_CACHE_DIR/$safe_branch.json"
  printf '{"branch":"%s","dirty":"","pr_num":"99","pr_state":"draft","pr_title":"stub","issue_num":"","issue_title":"","tasks_done":"3","tasks_total":"5","next":"do thing","phase":"Code","ci":"","mode":"unattended"}\n' "$branch" > "$cache_file"
  rm -f "$STATUS_GH_ERR_MARKER"
  export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"
  export STATUS_CACHE_DIR_OVERRIDE="$STATUS_CACHE_DIR"
  export STATUS_CACHE_TTL=60
  export PATH="$STATUS_GH_SHIM_ERR:$PATH"
  . "$SHELL_ROOT/.claude/hooks/helpers/status.sh"
  _status_collect >/dev/null 2>&1
  [ ! -f "$STATUS_GH_ERR_MARKER" ] || exit 1
) && ok "status-cache: fresh cache hit skips gh (#53)" \
   || ng "status-cache: fresh cache did not skip gh — err-stub fired (#53)"

# 29b. Cache absent → gh IS invoked AND cache is written.
(
  cd "$SHELL_ROOT"
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  safe_branch=$(printf '%s' "$branch" | tr '/' '_')
  cache_file="$STATUS_CACHE_DIR/$safe_branch.json"
  rm -f "$cache_file" "$STATUS_GH_MARKER"
  export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"
  export STATUS_CACHE_DIR_OVERRIDE="$STATUS_CACHE_DIR"
  export STATUS_CACHE_TTL=1
  export PATH="$STATUS_GH_SHIM_OK:$PATH"
  . "$SHELL_ROOT/.claude/hooks/helpers/status.sh"
  _status_collect >/dev/null 2>&1
  [ -f "$STATUS_GH_MARKER" ] || exit 1
  [ -s "$cache_file" ] || exit 1
) && ok "status-cache: cache miss invokes gh and writes cache (#53)" \
   || ng "status-cache: miss path did not invoke gh or did not persist cache (#53)"

# 29c. Stale cache (mtime older than TTL) → must miss and invoke gh.
(
  cd "$SHELL_ROOT"
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  safe_branch=$(printf '%s' "$branch" | tr '/' '_')
  cache_file="$STATUS_CACHE_DIR/$safe_branch.json"
  # Pre-write a cache and backdate it well past the TTL.
  printf '{"branch":"%s","dirty":"","pr_num":"7","pr_state":"draft","pr_title":"old","issue_num":"","issue_title":"","tasks_done":"0","tasks_total":"0","next":"","phase":"","ci":"","mode":""}\n' "$branch" > "$cache_file"
  # touch 10 minutes ago. Portable: -t YYYYMMDDHHMM (BSD + GNU touch).
  ts=$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M)
  touch -t "$ts" "$cache_file"
  rm -f "$STATUS_GH_MARKER"
  export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"
  export STATUS_CACHE_DIR_OVERRIDE="$STATUS_CACHE_DIR"
  export STATUS_CACHE_TTL=5
  export PATH="$STATUS_GH_SHIM_OK:$PATH"
  . "$SHELL_ROOT/.claude/hooks/helpers/status.sh"
  _status_collect >/dev/null 2>&1
  [ -f "$STATUS_GH_MARKER" ] || exit 1
) && ok "status-cache: stale cache (past TTL) invokes gh (#53)" \
   || ng "status-cache: stale cache did not trigger gh refetch (#53)"

# 29d. Per-branch keying: _status_cache_path emits distinct files for
# different branches, so `git checkout other-branch` transparently
# loads a different cache.
(
  export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"
  export STATUS_CACHE_DIR_OVERRIDE="$STATUS_CACHE_DIR"
  . "$SHELL_ROOT/.claude/hooks/helpers/status.sh"
  a=$(_status_cache_path "feature/foo")
  b=$(_status_cache_path "main")
  [ "$a" != "$b" ] || exit 1
  case "$a" in *feature_foo.json) ;; *) exit 1 ;; esac
  case "$b" in *main.json) ;; *) exit 1 ;; esac
) && ok "status-cache: per-branch keying yields distinct paths (#53)" \
   || ng "status-cache: per-branch keying broken (#53)"

rm -rf "$STATUS_PROBE_DIR"

# ---------- 30. session_start fetch TTL stamp (#54) ----------
# session_start.sh now gates its `git fetch` of $SHELL_ROOT behind a
# stamp at .claude/state/last-shell-fetched (TTL via
# SESSION_START_FETCH_TTL, default 21600). Fresh stamp → no fetch;
# stale/absent → fetch runs and stamp is touched.
SESS_PROBE_DIR=$(mktemp -d)
SESS_FAKE_ROOT="$SESS_PROBE_DIR/shell"
mkdir -p "$SESS_FAKE_ROOT/.claude/hooks/helpers" \
         "$SESS_FAKE_ROOT/.claude/state" \
         "$SESS_FAKE_ROOT/.claude/audit"

cp "$SHELL_ROOT/.claude/hooks/session_start.sh" "$SESS_FAKE_ROOT/.claude/hooks/"
for h in log escape cwd_guard branch_guard; do
  cp "$SHELL_ROOT/.claude/hooks/helpers/$h.sh" "$SESS_FAKE_ROOT/.claude/hooks/helpers/" 2>/dev/null
done
: > "$SESS_FAKE_ROOT/.claude/state/registry.txt"

(
  cd "$SESS_FAKE_ROOT"
  git init -q
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
)

SESS_GIT_SHIM="$SESS_PROBE_DIR/bin"
SESS_FETCH_MARKER="$SESS_PROBE_DIR/git-fetch-called"
REAL_GIT=$(command -v git)
mkdir -p "$SESS_GIT_SHIM"
cat > "$SESS_GIT_SHIM/git" <<SHIM
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "fetch" ]; then
    touch '$SESS_FETCH_MARKER'
    exit 0
  fi
done
exec '$REAL_GIT' "\$@"
SHIM
chmod +x "$SESS_GIT_SHIM/git"

run_session_start() {
  (
    export CLAUDE_ENG_SHELL_ROOT="$SESS_FAKE_ROOT"
    export PATH="$SESS_GIT_SHIM:$PATH"
    export SESSION_START_FETCH_TTL="${1:-21600}"
    bash "$SESS_FAKE_ROOT/.claude/hooks/session_start.sh" >/dev/null 2>&1
  )
}

stamp_file="$SESS_FAKE_ROOT/.claude/state/last-shell-fetched"

# 30a. Fresh stamp → no fetch.
touch "$stamp_file"; rm -f "$SESS_FETCH_MARKER"
run_session_start 21600
if [ ! -f "$SESS_FETCH_MARKER" ]; then
  ok "session-fetch: fresh stamp skips git fetch (#54)"
else
  ng "session-fetch: fresh stamp did not skip git fetch (#54)"
fi

# 30b. Stamp absent → fetch + stamp touched.
rm -f "$stamp_file" "$SESS_FETCH_MARKER"
run_session_start 21600
if [ -f "$SESS_FETCH_MARKER" ] && [ -f "$stamp_file" ]; then
  ok "session-fetch: absent stamp triggers fetch + touches stamp (#54)"
else
  ng "session-fetch: absent stamp did not run fetch or did not touch stamp (#54)"
fi

# 30c. Stale stamp → fetch.
ts=$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M)
touch -t "$ts" "$stamp_file"; rm -f "$SESS_FETCH_MARKER"
run_session_start 5
if [ -f "$SESS_FETCH_MARKER" ]; then
  ok "session-fetch: stale stamp (past TTL) triggers fetch (#54)"
else
  ng "session-fetch: stale stamp did not trigger fetch (#54)"
fi

rm -rf "$SESS_PROBE_DIR"

# ---------- 31. /work-on --base + base awareness (#57) ----------
# Five string-level + behavioral locks across SPEC, slash command,
# agent templates, and the status helper's PR row display.

WO_FOR_57="$SHELL_ROOT/.claude/commands/work-on.md"
PLANNER_FOR_57="$SHELL_ROOT/.claude/agents/planner.md"

# 31a. /work-on signature carries --base.
if grep -q -- '--base' "$WO_FOR_57" 2>/dev/null; then
  ok "base-flag: work-on.md mentions --base (#57)"
else
  ng "base-flag: work-on.md missing --base (#57)"
fi

# 31b. SPEC §10.5 heading exists.
if grep -q '^### 10\.5 Topic-branch workflow' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "base-flag: SPEC §10.5 Topic-branch workflow exists (#57)"
else
  ng "base-flag: SPEC §10.5 Topic-branch workflow missing (#57)"
fi

# 31c. planner.md output template includes Target base.
if grep -q 'Target base' "$PLANNER_FOR_57" 2>/dev/null; then
  ok "base-flag: planner.md template includes Target base (#57)"
else
  ng "base-flag: planner.md missing Target base field (#57)"
fi

# 31d/31e. status_compact shows `→ <base>` for non-main PRs and
# omits the marker when base IS main. Stub `gh pr view` to return a
# JSON object whose baseRefName we control.
BASE_PROBE_DIR=$(mktemp -d)
BASE_GH_SHIM="$BASE_PROBE_DIR/bin"
BASE_CACHE_DIR="$BASE_PROBE_DIR/state/status-cache"
mkdir -p "$BASE_GH_SHIM" "$BASE_CACHE_DIR"

cat > "$BASE_GH_SHIM/gh" <<'SHIM'
#!/bin/sh
base=$(cat "$BASE_PROBE_BASE_FILE" 2>/dev/null)
[ -z "$base" ] && base=main
case "$*" in
  *"pr view"*"--json"*)
    printf '{"number":99,"isDraft":true,"title":"t","body":"","baseRefName":"%s"}' "$base"
    ;;
  *"pr checks"*)
    echo ''
    ;;
  *)
    echo ''
    ;;
esac
SHIM
chmod +x "$BASE_GH_SHIM/gh"

# 31d. Non-main base → arrow + base in PR row.
(
  cd "$SHELL_ROOT"
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  safe=$(printf '%s' "$branch" | tr '/' '_')
  rm -f "$BASE_CACHE_DIR/$safe.json"
  export BASE_PROBE_BASE_FILE="$BASE_PROBE_DIR/base"
  echo 'experiment/foo' > "$BASE_PROBE_BASE_FILE"
  export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"
  export STATUS_CACHE_DIR_OVERRIDE="$BASE_CACHE_DIR"
  export STATUS_CACHE_TTL=1
  export PATH="$BASE_GH_SHIM:$PATH"
  . "$SHELL_ROOT/.claude/hooks/helpers/status.sh"
  out=$(status_compact 2>/dev/null)
  printf '%s' "$out" | grep -E '^pr: .*→ experiment/foo' >/dev/null
) && ok "base-flag: status_compact shows → <base> for non-main PR (#57)" \
   || ng "base-flag: status_compact missing → <base> for non-main PR (#57)"

# 31e. Main base → no arrow (regression guard).
(
  cd "$SHELL_ROOT"
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  safe=$(printf '%s' "$branch" | tr '/' '_')
  rm -f "$BASE_CACHE_DIR/$safe.json"
  export BASE_PROBE_BASE_FILE="$BASE_PROBE_DIR/base"
  echo 'main' > "$BASE_PROBE_BASE_FILE"
  export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"
  export STATUS_CACHE_DIR_OVERRIDE="$BASE_CACHE_DIR"
  export STATUS_CACHE_TTL=1
  export PATH="$BASE_GH_SHIM:$PATH"
  . "$SHELL_ROOT/.claude/hooks/helpers/status.sh"
  out=$(status_compact 2>/dev/null)
  printf '%s' "$out" | grep -E '^pr: .*→' >/dev/null && exit 1
  exit 0
) && ok "base-flag: status_compact omits → for main-base PR (#57)" \
   || ng "base-flag: status_compact wrongly emitted → for main-base PR (#57)"

rm -rf "$BASE_PROBE_DIR"

# ---------- 33. Co-Authored-By trailer toggle (#63) ----------
# helpers/coauthor.sh exposes coauthor_trailer. Default emits the
# Co-Authored-By line; CLAUDE_ENG_COAUTHOR=off OR
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
  export CLAUDE_ENG_SHELL_ROOT="$COAUTHOR_TMP"
  unset CLAUDE_ENG_COAUTHOR
  rm -f "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  out=$(coauthor_trailer)
  printf '%s' "$out" | grep -q '^Co-Authored-By: Claude'
) && ok "coauthor: default emits trailer (#63)" \
   || ng "coauthor: default did not emit trailer (#63)"

# 33b. File=off → empty.
(
  export CLAUDE_ENG_SHELL_ROOT="$COAUTHOR_TMP"
  unset CLAUDE_ENG_COAUTHOR
  printf 'off\n' > "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  out=$(coauthor_trailer)
  [ -z "$out" ]
) && ok "coauthor: file=off emits empty (#63)" \
   || ng "coauthor: file=off should emit empty (#63)"

# 33c. Env=off overrides file=on.
(
  export CLAUDE_ENG_SHELL_ROOT="$COAUTHOR_TMP"
  export CLAUDE_ENG_COAUTHOR=off
  printf 'on\n' > "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  out=$(coauthor_trailer)
  [ -z "$out" ]
) && ok "coauthor: env=off overrides file=on (#63)" \
   || ng "coauthor: env should override file (#63)"

# 33d. Unknown value → fail-safe to `on` + stderr warning.
(
  export CLAUDE_ENG_SHELL_ROOT="$COAUTHOR_TMP"
  export CLAUDE_ENG_COAUTHOR=maybe
  rm -f "$COAUTHOR_TMP/.claude/state/coauthor"
  [ -f "$COAUTHOR_HELPER" ] || exit 1
  . "$COAUTHOR_HELPER"
  stderr=$(coauthor_trailer 2>&1 >/dev/null)
  out=$(coauthor_trailer 2>/dev/null)
  printf '%s' "$out" | grep -q '^Co-Authored-By: Claude' || exit 1
  printf '%s' "$stderr" | grep -qi 'unknown\|warn\|fallback\|invalid' || exit 1
) && ok "coauthor: unknown value fails-safe to on + warns (#63)" \
   || ng "coauthor: unknown value should fail-safe to on + warn (#63)"

rm -rf "$COAUTHOR_TMP"

# ---------- 34. README currency (#65) ----------
# README.md is the project's landing page. Lock that it names all
# eight subagents, the --base flag, the operating modes, and the
# bootstrap dependencies. Future agent additions / flag changes
# fail-fast here if they forget to update the README.
README_MD="$SHELL_ROOT/README.md"

for agent in explorer planner doc-writer test-writer \
             code-reviewer security-reviewer \
             issue-reviewer plan-reviewer; do
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
  cd "$BACKMERGE_MAIN_DIR"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
)
printf '%s\n' "$BACKMERGE_MAIN_DIR" >> "$SHELL_ROOT/.claude/state/registry.txt"
(
  cd "$BACKMERGE_MAIN_DIR"
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' 'git merge main' | jq -Rs .)" \
    | CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
      bash "$HOOK" >/dev/null 2>&1
  [ "$?" = "0" ]
) && ok "backmerge: on-main merge allowed (#61)" \
   || ng "backmerge: on-main merge should allow (#61)"
grep -vxF "$BACKMERGE_MAIN_DIR" "$SHELL_ROOT/.claude/state/registry.txt" > "$SHELL_ROOT/.claude/state/registry.txt.tmp"
mv "$SHELL_ROOT/.claude/state/registry.txt.tmp" "$SHELL_ROOT/.claude/state/registry.txt"
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

if grep -qi 'approach check' "$WORK_ON_CMD" 2>/dev/null \
   && grep -q 'beats the alternatives' "$WORK_ON_CMD" 2>/dev/null; then
  ok "review: work-on.md mentions approach check + beats-alternatives (#45)"
else
  ng "review: work-on.md missing approach check or beats-alternatives anchor (#45)"
fi

if grep -q 'Alternatives considered' "$PLANNER_AGENT" 2>/dev/null \
   && grep -qi 'mandatory' "$PLANNER_AGENT" 2>/dev/null; then
  ok "review: planner.md mandates Alternatives considered (#45)"
else
  ng "review: planner.md missing Alternatives considered or mandatory wording (#45)"
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
# SPEC §6.1: commit-time lint is bounded by CLAUDE_ENG_LINT_TIMEOUT (default 30s).
# The helper run_bounded_lint runs the lint cmd via `timeout(1)` so a slow lint
# cannot hang the commit. If neither `timeout` nor `gtimeout` is on PATH, the
# helper falls back to unbounded run + audit_log warn (documented in SPEC).

if command -v run_bounded_lint >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    # 17a. slow lint terminated by timeout within window.
    start=$SECONDS
    CLAUDE_ENG_LINT_TIMEOUT=1 run_bounded_lint "sleep 5" >/dev/null 2>&1
    rc=$?
    elapsed=$((SECONDS - start))
    if [ "$rc" != "0" ] && [ "$elapsed" -le 3 ]; then
      ok "lint: bounded run terminates slow lint within window (rc=$rc, ${elapsed}s) (#29)"
    else
      ng "lint: slow lint not bounded (rc=$rc, ${elapsed}s) (#29)"
    fi

    # 17b. fast lint within timeout still passes.
    if CLAUDE_ENG_LINT_TIMEOUT=5 run_bounded_lint "true" >/dev/null 2>&1; then
      ok "lint: fast command within timeout passes (#29)"
    else
      ng "lint: fast command incorrectly failed (#29)"
    fi

    # 17c. failing lint within timeout returns non-zero.
    if CLAUDE_ENG_LINT_TIMEOUT=5 run_bounded_lint "false" >/dev/null 2>&1; then
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

# ---------- restore registry ----------
if [ -n "$ORIG_REG_BAK" ]; then
  mv "$ORIG_REG_BAK" "$ORIG_REG"
else
  rm -f "$SHELL_ROOT/.claude/state/registry.txt"
fi

# ---------- results ----------
echo
echo "smoke: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1
