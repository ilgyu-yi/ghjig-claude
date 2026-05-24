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
  cd "$SCAN_DIR" || exit 1
  git init -q
  printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > leak.txt
  git add leak.txt
  scan_staged_secrets >/dev/null 2>&1 && echo PASSED_LEAK_TEST_WRONG || echo DETECTED_OK
) | grep -q DETECTED_OK && ok "secret_scan: AWS key detected" || ng "secret_scan should detect AWS key"
rm -rf "$SCAN_DIR"

# 6b: positive — leak on a non-ignored file emits `file:line: <id>` marker (#25).
# Capture-then-grep instead of `subshell | grep -q`: `grep -q` exits on first
# match, sends SIGPIPE upstream, and the subshell exits 141. Under the
# smoke's `set -uo pipefail` the SIGPIPE propagates as the pipeline status
# and falsely fires the failure branch. Capture closes the pipe cleanly.
SCAN_6B=$(mktemp -d)
scan_6b_out=$(
  cd "$SCAN_6B" || exit 1
  git init -q
  mkdir -p src
  printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > src/foo.py
  git add src/foo.py
  # shellcheck disable=SC2069  # intentional: stderr → captured stdout, stdout discarded
  scan_staged_secrets 2>&1 >/dev/null
)
if printf '%s\n' "$scan_6b_out" | grep -qE 'src/foo\.py:[0-9]+:.*(aws|AKIA)'; then
  ok "secret_scan: emits file:line:<id> on non-ignored hit (#25)"
else
  ng "secret_scan: should emit file:line:<id> marker (#25)"
fi
rm -rf "$SCAN_6B"

# 6c: allow-list — leak on a path matched by HEAD's .shellsecretignore is
# skipped. .shellsecretignore must be committed FIRST (read from HEAD per
# security review MEDIUM-1) — staging-only does not take effect, which is
# locked by §6g below.
SCAN_6C=$(mktemp -d)
(
  cd "$SCAN_6C" || exit 1
  git init -q
  mkdir -p docs
  printf 'docs/\n' > .shellsecretignore
  git add .shellsecretignore
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m 'chore: allow-list docs/'
  printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > docs/example.md
  git add docs/example.md
  scan_staged_secrets >/dev/null 2>&1 && echo NO_BLOCK || echo BLOCKED
) | grep -q NO_BLOCK \
  && ok "secret_scan: HEAD .shellsecretignore entry skips matching paths (#25)" \
  || ng "secret_scan: allow-list entry did not skip the path (#25)"
rm -rf "$SCAN_6C"

# 6d: regression — without .shellsecretignore the legacy block path stands (#25).
SCAN_6D=$(mktemp -d)
(
  cd "$SCAN_6D" || exit 1
  git init -q
  mkdir -p docs
  # No .shellsecretignore created.
  printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > docs/example.md
  git add docs/example.md
  scan_staged_secrets >/dev/null 2>&1 && echo PASSED_LEAK_TEST_WRONG || echo DETECTED_OK
) | grep -q DETECTED_OK \
  && ok "secret_scan: missing .shellsecretignore preserves legacy block (#25)" \
  || ng "secret_scan: missing-allow-list regression — leak slipped through (#25)"
rm -rf "$SCAN_6D"

# 6e: parser-bypass attempt — a content line starting with `++ ` must NOT
# be misparsed as a `+++ b/<path>` header. Security review #26 HIGH-1.
SCAN_6E=$(mktemp -d)
(
  cd "$SCAN_6E" || exit 1
  git init -q
  mkdir -p src
  # First line is `++ b/x/tests/sneaky.py` (would become `+++ b/...` in diff
  # if naive parser treated it as a header) — second line is a real leak.
  # If the parser bug existed, file would re-tag to x/tests/sneaky.py and
  # the `tests/` allow-list entry (committed below) would skip the leak.
  printf '%s\n%s\n' '++ b/x/tests/sneaky.py' 'aws_key = "AKIAIOSFODNN7EXAMPLE"' > src/foo.py
  # Stage with a HEAD-committed allow-list that skips tests/ — the exploit
  # depended on this redirect.
  printf 'tests/\n' > .shellsecretignore
  git add .shellsecretignore
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m 'allow-list'
  git add src/foo.py
  scan_staged_secrets >/dev/null 2>&1 && echo PASSED_LEAK_TEST_WRONG || echo DETECTED_OK
) | grep -q DETECTED_OK \
  && ok "secret_scan: '++ ' content line is not misparsed as header (#25)" \
  || ng "secret_scan: parser-bypass — '++ ' content reassigns file (#25)"
rm -rf "$SCAN_6E"

# 6f: PEM private-key detection — patterns beginning with `-` must not be
# silently consumed by BSD-grep option-parsing. Security review #26 HIGH-2.
SCAN_6F=$(mktemp -d)
(
  cd "$SCAN_6F" || exit 1
  git init -q
  cat > leak.key <<'PEM'
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0bogus_does_not_matter_for_detection_test
-----END RSA PRIVATE KEY-----
PEM
  git add leak.key
  scan_staged_secrets >/dev/null 2>&1 && echo PASSED_LEAK_TEST_WRONG || echo DETECTED_OK
) | grep -q DETECTED_OK \
  && ok "secret_scan: PEM private-key pattern fires (BSD-grep -- guard) (#25)" \
  || ng "secret_scan: PEM private-key silently skipped (BSD-grep regression) (#25)"
rm -rf "$SCAN_6F"

# 6g: same-commit self-bypass — staging .shellsecretignore alongside a
# secret must not take effect (allow-list is read from HEAD, not the
# working tree). Security review #26 MEDIUM-1.
SCAN_6G=$(mktemp -d)
(
  cd "$SCAN_6G" || exit 1
  git init -q
  mkdir -p docs
  # No prior commit — so HEAD has no .shellsecretignore. Stage a permissive
  # entry alongside the leak; the scan should NOT honor the new entry.
  printf '*\n' > .shellsecretignore
  printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > docs/example.md
  git add .shellsecretignore docs/example.md
  scan_staged_secrets >/dev/null 2>&1 && echo BYPASS_WRONG || echo BLOCKED_OK
) | grep -q BLOCKED_OK \
  && ok "secret_scan: same-commit .shellsecretignore does not self-bypass (#25)" \
  || ng "secret_scan: same-commit allow-list bypass — security regression (#25)"
rm -rf "$SCAN_6G"

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
    # Cache file should now exist. (find rather than `[ -f glob ]` because
    # the latter only tests the first glob expansion and silently passes
    # when the glob fails to expand — SC2144.)
    [ -n "$(find "$CACHE_TMP" -maxdepth 1 -name '*pr-99.json' -print -quit 2>/dev/null)" ] || exit 1
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
    cd "$TMP/fake" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | jq -Rs .)" \
      | CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
        bash "$HOOK" >/dev/null 2>&1
    printf '%s' "$?"
  )
}

# Sanity: hook tests rely on $TMP/fake being on a non-protected branch.
# Lock this with an explicit assertion so a future tweak to §4's setup
# cannot silently reintroduce the bug. Uses PROTECTED_BRANCH_PATTERN from
# git_matcher.sh (sourced via helpers/branch_guard.sh elsewhere in the
# smoke; sourcing here too is idempotent).
# shellcheck disable=SC1091
. "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
hook_env_branch=$(cd "$TMP/fake" && git symbolic-ref --short HEAD 2>/dev/null)
if printf '%s' "$hook_env_branch" | grep -qE "^(${PROTECTED_BRANCH_PATTERN})$"; then
  ng "hook test env: \$TMP/fake on protected branch '$hook_env_branch' (#41)"
else
  ok "hook test env: non-protected branch '$hook_env_branch' for hook_run (#41)"
fi

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
    cd "$SHELL_ROOT" || exit 1
    # `2>&1 >/dev/null` is the intentional stderr-to-captured-pipe + stdout-to-null
    # swap: post_run is invoked via $(post_run ...), which captures stdout. The
    # post_tool_use hook emits reminders to stderr; this order routes them into
    # the captured pipe while discarding hook stdout. Reordering would silence
    # the assertion at smoke.sh L1019.
    # shellcheck disable=SC2069
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
# hookrt.sh hosts audit_log + safe_source after #34; session_start.sh
# primitively bootstraps it before sourcing any helper. Copy it too or
# the bootstrap fails and session_start exits before the git-fetch logic.
cp "$SHELL_ROOT/.claude/hooks/hookrt.sh" "$SESS_FAKE_ROOT/.claude/hooks/" 2>/dev/null
for h in log escape cwd_guard branch_guard; do
  cp "$SHELL_ROOT/.claude/hooks/helpers/$h.sh" "$SESS_FAKE_ROOT/.claude/hooks/helpers/" 2>/dev/null
done
: > "$SESS_FAKE_ROOT/.claude/state/registry.txt"

(
  cd "$SESS_FAKE_ROOT" || exit 1
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

# ---------- 34. README currency (#65, extended for directive-reviewer #58) ----------
# README.md is the project's landing page. Lock that it names all
# nine subagents (eight engineering + one dir-mode), the --base flag,
# the operating modes, and the bootstrap dependencies. Future agent
# additions / flag changes fail-fast here if they forget to update
# the README.
README_MD="$SHELL_ROOT/README.md"

for agent in explorer planner doc-writer test-writer \
             code-reviewer security-reviewer \
             issue-reviewer plan-reviewer \
             directive-reviewer; do
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
  cd "$BACKMERGE_MAIN_DIR" || exit 1
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

# ---------- 35. README env-var catalog SSOT (#15) ----------
# The README "Configuration toggles" table is the user-facing SSOT for env
# vars per SPEC §1.3. Every env var documented elsewhere in the shell must
# also appear in the table. A missing row is the same drift class as a
# missing SPEC TOC entry (§28). Mirrors the §27 multi-target loop idiom.
README_MD="$SHELL_ROOT/README.md"
if [ -f "$README_MD" ]; then
  missing=""
  for v in SESSION_START_FETCH_TIMEOUT CLAUDE_ENG_STOP_THROTTLE SHIP_PARK_LOG_PATH PR_CACHE_REPO; do
    if ! grep -q "$v" "$README_MD"; then
      missing="$missing $v"
    fi
  done
  if [ -z "$missing" ]; then
    ok "readme-toggles: all four env vars documented in README (#15)"
  else
    ng "readme-toggles: env vars missing from README Configuration toggles:$missing (#15)"
  fi
else
  ng "readme-toggles: README.md not found at $README_MD (#15)"
fi

# ---------- 37. SessionStart inject-consistency banner (#23) ----------
# When the shell was injected into a target (settings.local.json is a
# symlink) but CLAUDE_ENG_SHELL_ROOT is unset (user ran `claude`, not
# `claude-eng`), SessionStart must emit one stderr warning so the silent
# no-op state is visible. The check runs *before* session_start.sh's
# env-guard at lines 4-5; without it every hook silently exits 0.
# Marker substring locked here: `inject-consistency`. Banner text may
# evolve so long as that token remains.
SESS_37_DIR=$(mktemp -d)
SESS_37_SHELL="$SESS_37_DIR/shell"
SESS_37_TARGET="$SESS_37_DIR/target"
mkdir -p "$SESS_37_SHELL/.claude" "$SESS_37_TARGET/.claude"
touch "$SESS_37_SHELL/.claude/settings.json"
# Mirror inject_into's symlink: target/.claude/settings.local.json → shell/.claude/settings.json
ln -sfn "$SESS_37_SHELL/.claude/settings.json" "$SESS_37_TARGET/.claude/settings.local.json"

# Stable TMPDIR + session id so the stamp file is deterministic across
# 37a / 37d.
SESS_37_TMP="$SESS_37_DIR/tmp"; mkdir -p "$SESS_37_TMP"
SESS_37_SID="smoke37"

run_37_session_start() {
  local env_set="$1"   # 'set' | 'unset'
  local cwd="$2"
  (
    unset CLAUDE_ENG_SHELL_ROOT
    [ "$env_set" = set ] && export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"
    export TMPDIR="$SESS_37_TMP"
    export CLAUDE_SESSION_ID="$SESS_37_SID"
    cd "$cwd" || exit 1
    # Same intentional swap as post_run at smoke.sh:1023 — caller captures
    # stdout via $(...); the hook writes to stderr; this order routes
    # stderr into the captured pipe while discarding hook stdout.
    # shellcheck disable=SC2069
    bash "$SHELL_ROOT/.claude/hooks/session_start.sh" 2>&1 >/dev/null
  )
}

# 37a (positive): symlink + env unset → banner.
rm -rf "$SESS_37_TMP/claude-eng-banner."*
out37a=$(run_37_session_start unset "$SESS_37_TARGET")
if printf '%s' "$out37a" | grep -q 'inject-consistency'; then
  ok "session-banner: symlink + env unset emits banner (#23)"
else
  ng "session-banner: symlink + env unset should emit banner (#23)"
fi

# 37b (env-set negative): symlink + env set → no banner (env tells the
# shell it knows where it is).
rm -rf "$SESS_37_TMP/claude-eng-banner."*
out37b=$(run_37_session_start set "$SESS_37_TARGET")
if printf '%s' "$out37b" | grep -q 'inject-consistency'; then
  ng "session-banner: env-set should suppress banner (#23)"
else
  ok "session-banner: env-set + symlink → no banner (#23)"
fi

# 37c (no-symlink negative): no symlink + env unset → no banner. A
# workspace that was never injected must stay quiet (no false positives).
SESS_37_CLEAN="$SESS_37_DIR/clean"; mkdir -p "$SESS_37_CLEAN/.claude"
rm -rf "$SESS_37_TMP/claude-eng-banner."*
out37c=$(run_37_session_start unset "$SESS_37_CLEAN")
if printf '%s' "$out37c" | grep -q 'inject-consistency'; then
  ng "session-banner: non-injected dir should not emit banner (#23)"
else
  ok "session-banner: no symlink → no banner (#23)"
fi

# 37d (idempotency): same SID/TMPDIR — second run within the session
# must suppress the banner (one-per-session debounce).
rm -rf "$SESS_37_TMP/claude-eng-banner."*
out37d_first=$(run_37_session_start unset "$SESS_37_TARGET")
out37d_second=$(run_37_session_start unset "$SESS_37_TARGET")
first_hit=$(printf '%s' "$out37d_first" | grep -c 'inject-consistency')
second_hit=$(printf '%s' "$out37d_second" | grep -c 'inject-consistency')
if [ "$first_hit" = "1" ] && [ "$second_hit" = "0" ]; then
  ok "session-banner: debounced to once per session (#23)"
else
  ng "session-banner: idempotency broken (first=$first_hit second=$second_hit) (#23)"
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
  *"pr view"*"closingIssuesReferences"*)
    cat "$GH_SHIM_STATE/pr_issues" 2>/dev/null
    ;;
  *"pr view"*"--json number"*)
    cat "$GH_SHIM_STATE/pr_number" 2>/dev/null
    ;;
  *"issue view"*"--json body"*)
    cat "$GH_SHIM_STATE/issue_body" 2>/dev/null
    ;;
  *"issue view"*"--json comments"*)
    cat "$GH_SHIM_STATE/issue_comments" 2>/dev/null
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
        CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1 >/dev/null
  )
}

# Helper to reset the shim state between sub-cases.
gh38_reset() {
  rm -f "$GH38_STATE"/pr_issues "$GH38_STATE"/pr_number \
        "$GH38_STATE"/issue_body "$GH38_STATE"/issue_comments \
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

# 38b: allow when `^## AC closeout` marker comment already exists.
gh38_reset
printf '100\n' > "$GH38_STATE/pr_issues"
printf -- '- [ ] do the thing\n' > "$GH38_STATE/issue_body"
printf '## AC closeout (resolved by PR #200)\nbody...\n' > "$GH38_STATE/issue_comments"
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
REAL_AUDIT="$SHELL_ROOT/.claude/audit/audit.jsonl"
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
# Now simulate the marker being present (helper would have posted it).
printf '## AC closeout (resolved by PR #200)\nbody...\n' > "$GH38_STATE/issue_comments"
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
# Each iteration: move the helper aside (trap-protected), invoke the
# right hook with a benign input, assert (a) rc=0, (b) audit.jsonl
# grew, (c) the new tail contains both the expected category and the
# `helper-missing` token. Restore immediately so a later assertion
# failure doesn't leave the live helper missing.
#
# hookrt.sh and helpers/log.sh are excluded:
#   - hookrt.sh is the primitive bootstrap; its absence is stderr-only
#     by design (cannot audit-log itself).
#   - helpers/log.sh is a compatibility shim after #34; no hook
#     safe-sources it (audit_log comes from hookrt.sh directly).

REAL_AUDIT_38H="$SHELL_ROOT/.claude/audit/audit.jsonl"

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
            CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
          | CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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

  # Core contract: rc=0 (fail-open) + audit grew + category + decision tokens.
  ss_ok=0
  if [ "$ss_rc" = 0 ] \
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
    ng "safe_source: $ss_helper missing — expected category=$ss_cat decision=helper-missing (security-suffix per §6.1); got rc=$ss_rc new=$ss_new tail=$ss_tail (#34)"
  fi
done

trap - EXIT INT TERM

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

REAL_AUDIT_38J="$SHELL_ROOT/.claude/audit/audit.jsonl"
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
        CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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

REAL_AUDIT_39="$SHELL_ROOT/.claude/audit/audit.jsonl"

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
        CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
  "gh pr merge 200 --merge|ac-closeout|pass-through"
)

# Subset notes for the v1 cut: only ac-closeout is included here.
# Adding the other 10 matchers needs custom setup per matcher (cwd on
# the right branch for backmerge; pushed-vs-unpushed for --amend; etc.)
# — those are added incrementally in the Code phase as the matchers are
# retrofitted. §39b's structural check is the safety net that catches
# any matcher whose retrofit is forgotten.

p39_fails=0
for row in "${PT39_TABLE[@]}"; do
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

rm -rf "$PT39_DIR"

# ---------- 40. SessionStart hookrt-missing banner (#37) ----------
# SPEC §6.5(c): when $CLAUDE_ENG_SHELL_ROOT is set AND
# $CLAUDE_ENG_SHELL_ROOT/.claude/hooks/hookrt.sh is absent, session_start.sh
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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

# ---------- 41. scripts/setup_project.sh idempotency + scope guards (#43) ----------
# PR #43 introduces scripts/setup_project.sh — an idempotent bootstrap for the
# GitHub Project v2 substrate (SPEC §1.7, ADR-0002). The script:
#   1. Refuses on unregistered target paths (registry guard).
#   2. Refuses without `gh auth` + `project` scope.
#   3. On first run: creates the Project (if absent) and the six CLI-managed
#      fields. The Iteration field is user-managed via GH UI per the gh CLI
#      ITERATION-data-type limitation documented in ADR-0002.
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

# Register $SP_TARGET so the registry guard accepts it. Save and restore the
# real registry (already swapped to a temp $REG by the §4 setup at the top of
# this file).
SP_REGISTRY="$SHELL_ROOT/.claude/state/registry.txt"
printf '%s\n' "$SP_TARGET" >> "$SP_REGISTRY"

# Mock gh — dispatches by subcommand; logs full argv. Tracks per-field creation
# state via $GH_MOCK_FIELDS_DIR so successive ensure_field calls see the union
# of (default "Title" + all fields created so far). This makes the mock match
# real gh behavior: after field-create succeeds, that field shows up in
# field-list on the next call.
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
        # plus whatever names were recorded by previous field-create calls.
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
          json="$json{\"name\":\"$line\"}"
        done <<< "$names"
        printf '%s]}' "$json"
        ;;
      field-create)
        # Extract --name argument; record file under $GH_MOCK_FIELDS_DIR (basename
        # uses underscores in place of spaces so the filename is safe).
        next=
        for a in "$@"; do
          if [ "${next:-}" = name ]; then
            mkdir -p "$GH_MOCK_FIELDS_DIR"
            touch "$GH_MOCK_FIELDS_DIR/${a// /_}"
            break
          fi
          [ "$a" = "--name" ] && next=name
        done
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR/fields" \
      GH_MOCK_AUTH=ok \
        bash "$SP_SCRIPT" </dev/null >/dev/null 2>&1
    )
    sp41a_creates=$( { grep -c 'project field-create' "$SP_DIR/gh.log" 2>/dev/null; } || true)
    sp41a_proj_create=$( { grep -c 'project create' "$SP_DIR/gh.log" 2>/dev/null; } || true)
    : "${sp41a_creates:=0}"
    : "${sp41a_proj_create:=0}"
    # Six CLI-managed fields per ADR-0002 "Iteration constraint" — Iteration is user-managed.
    if [ "$sp41a_proj_create" -ge 1 ] && [ "$sp41a_creates" = 6 ]; then
      ok "41a: first-run creates project + 6 fields (Iteration user-managed) (#43)"
    else
      ng "41a: first-run expected ≥1 project-create + 6 field-create; got proj=$sp41a_proj_create field=$sp41a_creates (#43)"
    fi

    # 41b: second-run (project + fields already exist) → zero new field-creates.
    rm -f "$SP_DIR/gh.log"
    (
      cd "$SP_TARGET" || exit 0
      PATH="$SP_BIN:$PATH" \
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR/fields" \
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR/fields" \
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
      GH_MOCK_LOG="$SP_DIR/gh.log" \
      GH_MOCK_PROJECT_CREATED="$SP_DIR/project-created" \
      GH_MOCK_FIELDS_DIR="$SP_DIR/fields" \
      GH_MOCK_AUTH=ok \
      GH_MOCK_SCOPES='gist, repo' \
        bash "$SP_SCRIPT" </dev/null >/dev/null 2>&1
    ) || sp41d_rc=$?
    if [ "$sp41d_rc" -ne 0 ]; then
      ok "41d: missing project scope → refused with exit $sp41d_rc (#43)"
    else
      ng "41d: missing project scope should refuse but exited 0 (#43)"
    fi
  fi
fi

# Remove the target from the registry to avoid leaking into other tests.
if [ -f "$SP_REGISTRY" ]; then
  sp_tmp_reg=$(mktemp)
  grep -vxF "$SP_TARGET" "$SP_REGISTRY" > "$sp_tmp_reg" 2>/dev/null || true
  mv "$sp_tmp_reg" "$SP_REGISTRY"
fi
rm -rf "$SP_DIR"

# ---------- 42. directive-reviewer subagent structural sanity (#44) ----------
# Structural assertions (42a-42d) verify the agent file's contract:
# frontmatter (name, description, tools), required body sections, and the
# VERDICT-line format documented in the body. These run by default.
#
# Behavioral validation lives in §42e below, gated behind
# CLAUDE_ENG_BEHAVIORAL_SMOKE=1 — it shells out to the live agent and asserts
# its VERDICT output on synthetic inputs (SPEC §4.9.3, issue #69 under
# Directive #62). Default smoke stays deterministic and offline.

DR_PATH="$SHELL_ROOT/.claude/agents/directive-reviewer.md"
if [ ! -f "$DR_PATH" ]; then
  ng "42: directive-reviewer.md missing (#44)"
else
  # 42a: frontmatter has name, description, tools.
  dr_name=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$DR_PATH")
  dr_desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{print; exit}' "$DR_PATH")
  dr_tools=$(awk '/^---$/{c++; next} c==1 && /^tools:/{print; exit}' "$DR_PATH")
  if [ -n "$dr_name" ] && [ -n "$dr_desc" ] && [ -n "$dr_tools" ]; then
    ok "42a: directive-reviewer frontmatter has name + description + tools (#44)"
  else
    ng "42a: frontmatter missing required key; name='$dr_name' desc='$dr_desc' tools='$dr_tools' (#44)"
  fi

  # 42b: required body sections present (matches the reviewer-subagent
  # convention from issue-reviewer.md / plan-reviewer.md).
  dr_missing=""
  for section in "## Input" "## Premise" "## Checks" "## Output" "## Rules"; do
    if ! grep -qF "$section" "$DR_PATH"; then
      dr_missing="$dr_missing $section"
    fi
  done
  if [ -z "$dr_missing" ]; then
    ok "42b: directive-reviewer body has all required sections (#44)"
  else
    ng "42b: directive-reviewer body missing sections:$dr_missing (#44)"
  fi

  # 42c: VERDICT-line format documents the three terminal verdicts (matches
  # SPEC §4.7 / §4.8 reviewer convention).
  if grep -qE '^- `VERDICT: ship' "$DR_PATH" \
     && grep -qE '^- `VERDICT: refine' "$DR_PATH" \
     && grep -qE '^- `VERDICT: block' "$DR_PATH"; then
    ok "42c: VERDICT-line format documents ship / refine / block (#44)"
  else
    ng "42c: VERDICT-line format incomplete (#44)"
  fi

  # 42d: tools restricted to the standard reviewer read-only set
  # (matches issue-reviewer.md and plan-reviewer.md).
  if printf '%s' "$dr_tools" | grep -qE 'Read.*Grep.*Glob.*Bash'; then
    ok "42d: directive-reviewer tools restricted to [Read, Grep, Glob, Bash] (#44)"
  else
    ng "42d: directive-reviewer tools expected [Read, Grep, Glob, Bash]; got '$dr_tools' (#44)"
  fi
fi

# ---------- 42e. directive-reviewer behavioral assertions (#69 / Directive #62) ----------
# Gated behind CLAUDE_ENG_BEHAVIORAL_SMOKE=1. When set, shells out to the live
# agent via `claude -p --agent directive-reviewer` and asserts the documented
# VERDICT-line output on two synthetic Directive bodies:
#   - case A: minimal-but-valid body  → ^VERDICT: ship
#   - case B: body missing the entire ## Success signals heading
#                                     → ^VERDICT: (refine|block)
# Default-unset → no-op so smoke stays offline + deterministic (preserves the
# 278/278 baseline). See SPEC §4.9.3 for the routing-regression contract this
# block protects.
if [ "${CLAUDE_ENG_BEHAVIORAL_SMOKE:-}" = 1 ]; then
  if ! command -v claude >/dev/null 2>&1; then
    ng "42e: CLAUDE_ENG_BEHAVIORAL_SMOKE=1 but 'claude' CLI not on PATH (#69)"
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
- `bash scripts/test/smoke.sh` (with `CLAUDE_ENG_BEHAVIORAL_SMOKE` unset) prints `smoke: pass=278 fail=0` on the next merge to main; verified by the PR's CI summary and one local re-run on the merge commit.
- `CLAUDE_ENG_BEHAVIORAL_SMOKE=1 bash scripts/test/smoke.sh` adds exactly two passing assertions under §42e (`42e-ship` and `42e-refine-or-block`) and the total becomes `pass=280 fail=0`; verified by counting `ok "42e-` lines in the output.

## Non-goals
- Does NOT include behavioral smoke for `issue-reviewer`, `plan-reviewer`, `code-reviewer`, or `security-reviewer` — their structural assertions are out of scope for this Directive.
- Does NOT modify directive-reviewer's five checks or the VERDICT-line format (both locked by PR #50).

## Constraints
- §42e must be self-contained inside `scripts/test/smoke.sh`; no new helper scripts under `scripts/test/` or new entries in the registry.
- The env-var guard must be a single `if` at the top of §42e — no scattered checks inside individual `ok`/`ng` calls.

## Parent Goal
First Directive in this synthetic test environment — bootstraps the Goal slot per directive-reviewer rule "The first Directive in a repo bootstraps the Goal slot".
PROMPT_EOF
    dr_ship_out=$(claude -p --agent directive-reviewer "$dr_ship_prompt" 2>&1 || true)
    dr_ship_verdict=$(printf '%s\n' "$dr_ship_out" | tail -n 20 | grep -E '^VERDICT:' | tail -1)
    case "$dr_ship_verdict" in
      "VERDICT: ship"*)
        ok "42e-ship: directive-reviewer returns 'ship' on minimal-but-valid synthetic body (#69)" ;;
      *)
        ng "42e-ship: expected '^VERDICT: ship', got '$dr_ship_verdict' (#69)" ;;
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
- Does NOT modify directive-reviewer's five checks or the VERDICT-line format.

## Constraints
- §42e must be self-contained inside `scripts/test/smoke.sh`.
- The env-var guard must be a single `if` at the top of §42e.

## Parent Goal
First Directive in this synthetic test environment.
PROMPT_EOF
    dr_refine_out=$(claude -p --agent directive-reviewer "$dr_refine_prompt" 2>&1 || true)
    dr_refine_verdict=$(printf '%s\n' "$dr_refine_out" | tail -n 20 | grep -E '^VERDICT:' | tail -1)
    case "$dr_refine_verdict" in
      "VERDICT: refine"*|"VERDICT: block"*)
        ok "42e-refine-or-block: directive-reviewer rejects body missing '## Success signals' (got '$dr_refine_verdict') (#69)" ;;
      *)
        ng "42e-refine-or-block: expected '^VERDICT: refine' or '^VERDICT: block', got '$dr_refine_verdict' (#69)" ;;
    esac
  fi
fi

# ---------- 43. dir-mode command files structural sanity (#45) ----------
# PR #45 ships the five dir-mode commands + a directive body template.
# Command files are Markdown prompts for Claude (no executable code);
# what we can verify here is that each file exists, has the standard
# frontmatter (description + argument-hint), references the gated
# directive-reviewer where SPEC §5.10–§5.14 require it, and names the
# correct audit category.

DR_TEMPLATE="$SHELL_ROOT/.claude/templates/directive.md"
if [ ! -f "$DR_TEMPLATE" ]; then
  ng "43: .claude/templates/directive.md missing (#45)"
else
  dt_missing=""
  for section in "## Objective" "## Success signals" "## Non-goals" "## Constraints" "## Parent Goal"; do
    if ! grep -qF "$section" "$DR_TEMPLATE"; then
      dt_missing="$dt_missing $section"
    fi
  done
  if [ -z "$dt_missing" ]; then
    ok "43-template: directive.md template has all five required sections (#45)"
  else
    ng "43-template: directive.md missing sections:$dt_missing (#45)"
  fi
fi

for cmd in file-directive list-directives activate-directive complete-directive link-directive; do
  cmd_path="$SHELL_ROOT/.claude/commands/$cmd.md"
  if [ ! -f "$cmd_path" ]; then
    ng "43-$cmd: command file missing (#45)"
    continue
  fi
  has_desc=$(awk '/^---$/{c++; next} c==1 && /^description:/{print 1; exit}' "$cmd_path")
  has_hint=$(awk '/^---$/{c++; next} c==1 && /^argument-hint:/{print 1; exit}' "$cmd_path")
  if [ "$has_desc" = 1 ] && [ "$has_hint" = 1 ]; then
    ok "43-$cmd: frontmatter has description + argument-hint (#45)"
  else
    ng "43-$cmd: frontmatter missing description or argument-hint (#45)"
  fi
done

# 43-reviewer-ref: file-directive, activate-directive, complete-directive
# must each reference directive-reviewer (the gated step per SPEC §5.10/§5.12/§5.13).
for cmd in file-directive activate-directive complete-directive; do
  if grep -qF "directive-reviewer" "$SHELL_ROOT/.claude/commands/$cmd.md" 2>/dev/null; then
    ok "43-reviewer-$cmd: command references directive-reviewer at the gated step (#45)"
  else
    ng "43-reviewer-$cmd: command does not reference directive-reviewer (#45)"
  fi
done

# 43-audit-cat: each non-read-only command names its audit category.
for pair in "file-directive:directive-file" "activate-directive:directive-activate" "complete-directive:directive-complete" "link-directive:directive-link"; do
  cmd="${pair%%:*}"
  cat="${pair##*:}"
  if grep -qF "$cat" "$SHELL_ROOT/.claude/commands/$cmd.md" 2>/dev/null; then
    ok "43-audit-$cmd: command names audit category '$cat' (#45)"
  else
    ng "43-audit-$cmd: command does not name audit category '$cat' (#45)"
  fi
done

# ---------- 44. Type-aware hooks + directive-protect matcher (#46) ----------
# PR #46 wires Type-awareness into pre_tool_use.sh via helpers/issue_type.sh.
# Smoke covers:
#   44a: directive-protect blocks `git checkout -b <user>/<type>/<N>-<slug>`
#        when issue <N> carries the `directive` label.
#   44b: same command for a non-Directive issue is allowed (mark_allow).
#   44c: is_directive_issue caches the result under .claude/state/issue-type-cache/.
#   44d: SKIP_HOOKS=directive-protect bypasses the block.
#
# Mock strategy: PATH-overlay mock `gh` returns canned labels per issue.

DP_DIR=$(mktemp -d)
DP_BIN="$DP_DIR/bin"
DP_TARGET="$DP_DIR/target"
DP_CACHE="$SHELL_ROOT/.claude/state/issue-type-cache"
mkdir -p "$DP_BIN" "$DP_TARGET"
DP_TARGET=$(cd "$DP_TARGET" && pwd -P)
(cd "$DP_TARGET" && git init -q) || true
DP_AUDIT="$DP_DIR/audit.jsonl"

# Register DP_TARGET so cwd_guard accepts it (matches the §41 pattern).
DP_REGISTRY="$SHELL_ROOT/.claude/state/registry.txt"
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
    CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
    AUDIT_LOG_PATH="$DP_AUDIT" \
    GH_MOCK_LABELS_91="directive,enhancement" \
    GH_MOCK_LABELS_92="enhancement" \
    GH_MOCK_LABELS_93="directive" \
    SKIP_HOOKS="$skip" \
    SKIP_REASON="${skip:+smoke-test}" \
      bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" <<< "$stdin_json"
  )
  return $?
}

# Clear cache so each assertion starts fresh.
rm -rf "$DP_CACHE"

# 44a: Directive issue → block.
rc=0
dp_run "git checkout -b ilgyu-yi/feat/91-foo" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then
  ok "44a: directive-protect blocks git checkout -b on Directive Issue #91 (#46)"
else
  ng "44a: expected exit 2 (block) on Directive Issue; got rc=$rc (#46)"
fi

# 44b: Execution issue (non-Directive label) → allowed (rc 0).
rc=0
dp_run "git checkout -b ilgyu-yi/feat/92-bar" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
  ok "44b: directive-protect allows git checkout -b on non-Directive Issue #92 (#46)"
else
  ng "44b: expected rc=0 on non-Directive Issue; got rc=$rc (#46)"
fi

# 44c: cache entry created after lookups.
if [ -f "$DP_CACHE/smoke-owner__smoke-repo__91" ] && [ -f "$DP_CACHE/smoke-owner__smoke-repo__92" ]; then
  cache_91=$(cat "$DP_CACHE/smoke-owner__smoke-repo__91" 2>/dev/null)
  cache_92=$(cat "$DP_CACHE/smoke-owner__smoke-repo__92" 2>/dev/null)
  if [ "$cache_91" = directive ] && [ "$cache_92" = execution ]; then
    ok "44c: is_directive_issue cache stores type per-issue (#46)"
  else
    ng "44c: cache contents wrong; #91=$cache_91 #92=$cache_92 (expected directive/execution) (#46)"
  fi
else
  ng "44c: cache files not created under $DP_CACHE (#46)"
fi

# 44d: SKIP_HOOKS=directive-protect bypasses the block.
rc=0
dp_run "git checkout -b ilgyu-yi/feat/93-baz" "directive-protect" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
  ok "44d: SKIP_HOOKS=directive-protect bypasses the block (#46)"
else
  ng "44d: SKIP_HOOKS=directive-protect should allow but got rc=$rc (#46)"
fi

# Cleanup: remove cache entries created by §44 so they don't leak.
rm -f "$DP_CACHE/smoke-owner__smoke-repo__91" "$DP_CACHE/smoke-owner__smoke-repo__92" "$DP_CACHE/smoke-owner__smoke-repo__93"
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
# pull_request.closed && merged == true event. The template lives shell-side
# (.claude/templates/) and the dogfooded installation lives in
# .github/workflows/. §48 locks the contract: file existence, trigger shape,
# Parent Directive regex consumer, directive-exec-count audit-line token.

DPM_TEMPLATE="$SHELL_ROOT/.claude/templates/dir-mode-post-merge.yml"
DPM_INSTALL="$SHELL_ROOT/.github/workflows/dir-mode-post-merge.yml"

if [ ! -f "$DPM_TEMPLATE" ]; then
  ng "48: .claude/templates/dir-mode-post-merge.yml missing (#63)"
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

  # 48f: dogfood install matches template (byte-for-byte or detectable equivalence).
  if cmp -s "$DPM_TEMPLATE" "$DPM_INSTALL"; then
    ok "48f: .github/workflows/ install matches .claude/templates/ source (#63)"
  else
    ng "48f: workflow install drifts from template (#63)"
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
  ng "49: only $agent_count agents found; expected ≥9 (the eight engineering + directive-reviewer) (#64)"
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
