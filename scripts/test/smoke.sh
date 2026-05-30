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

# Bash force push to an EXPLICIT non-protected branch → allowed (#204).
# (Force-push to a named feature branch is the rebase-pull tail, SPEC §13.)
out=$(cd "$TMP/fake" && fake_input "Bash" "{\"command\":\"git push --force-with-lease origin feature\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 0 ] && ok "pre_tool_use allows force-push to explicit feature branch (#204)" || ng "should allow force-push to explicit feature branch (rc=$rc) (#204)"

# Bash with escape — SKIP_HOOKS=force-push bypasses a genuinely-blocked
# force-push. Bare (no explicit target) is blocked under #204, so this
# exercises the escape against a real block (not an allowed command).
out=$(cd "$TMP/fake" && {
  export SKIP_HOOKS=force-push SKIP_REASON="emergency"
  fake_input "Bash" "{\"command\":\"git push --force\"}" \
    | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh"
} 2>&1)
rc=$?
[ "$rc" = 0 ] && ok "escape SKIP_HOOKS=force-push passes (bare force-push)" || ng "escape should pass (rc=$rc)"

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

# 37x (#209): `git commit --allow-empty` must NOT skip the commit umbrella.
# Pre-#209 the matcher ENTRY excluded --allow-empty, so an empty commit bypassed
# branch + commit-format + secret + lint in one flag. A malformed subject proves
# the umbrella now ENTERS (the four sub-checks share a single `if` block, so the
# matcher-entry guard is the whole fix — once it enters, branch/secret/lint run
# by construction). The second case keeps a valid empty commit from over-blocking.
if [ "$(hook_run 'git commit --allow-empty -m "not a CC subject"')" = "2" ]; then
  ok "matcher: git commit --allow-empty enters the commit gate (commit-format fires) (#209)"
else
  ng "matcher: git commit --allow-empty bypasses the commit umbrella (#209)"
fi
if [ "$(hook_run 'git commit --allow-empty -m "feat(#1): valid empty"')" = "0" ]; then
  ok "matcher: git commit --allow-empty with a valid CC subject still passes (#209)"
else
  ng "matcher: valid --allow-empty commit over-blocked (#209)"
fi

# 37y (#212): the destructive out-of-scope guard recognizes a force/recursive
# flag in ANY surface form (clustered/separated/long/non-first), anchored to the
# verb. /etc/ce-probe is out of scope → block. Pre-#212 only a clustered -rf
# immediately after the verb matched, so the separated/long/non-first forms
# slipped past (rc=0 allow).
for d212 in \
  'rm -r -f /etc/ce-probe' \
  'rm --force /etc/ce-probe' \
  'rm -i -rf /etc/ce-probe' \
  'rm --recursive --force /etc/ce-probe' \
  'rm -rf /etc/ce-probe' ; do
  if [ "$(hook_run "$d212")" = "2" ]; then
    ok "matcher: destructive out-of-scope blocked [$d212] (#212)"
  else
    ng "matcher: destructive form slipped past [$d212] (#212)"
  fi
done
# No over-block: an UNFORCED rm (no force/recursive flag) must not enter the arm
# (only forced/recursive forms are gated — broadening to bare rm is out of scope).
if [ "$(hook_run 'rm /etc/ce-probe')" = "0" ]; then
  ok "matcher: unforced rm does not enter the destructive arm (#212)"
else
  ng "matcher: unforced rm wrongly blocked (#212)"
fi
# No over-entry: a free-floating force flag with NO rm/mv/cp verb must not trigger.
if [ "$(hook_run 'grep -f pattern /etc/ce-probe')" = "0" ]; then
  ok "matcher: free-floating -f without rm/mv/cp does not trigger destructive arm (#212)"
else
  ng "matcher: grep -f wrongly entered the destructive arm (#212)"
fi

# ---------- 23. SKIP_HOOKS escape parsing (#38, #206) ----------
# SPEC §7 escape has TWO forms. §23a-f cover the LEADING env-prefix form,
# which only works where the prefix arrives INSIDE the command string —
# hook_run embeds it in tool_input.command via `jq -Rs`, modeling a real
# shell / verbatim delivery. CAVEAT (#206): the LIVE Claude Code Bash tool
# consumes a leading `VAR=val` as the subprocess env, so it never reaches
# tool_input.command — the leading form is dead in-harness. §23g-k (below)
# cover the TRAILING sentinel `# claude-eng:skip=<cat> reason=<why>`, which
# stays in the command and IS the reliable in-harness escape (incl. §23k: a
# line-1 sentinel must not strip/bypass a later-line command). §23l is the
# pre-existing parse_env_prefix outvar-collision guard.

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

# 23g (#206): TRAILING SENTINEL — the in-harness escape. A `git reset --hard`
# (destructive) blocks today; with a trailing `# claude-eng:skip=destructive
# reason=...` sentinel IN the command (which is how it arrives in-harness AND
# in hook_run) it is allowed + an escape audit record is written.
before=$(audit_lines); [ -z "$before" ] && before=0
rc=$(hook_run 'git reset --hard  # claude-eng:skip=destructive reason=in-harness-escape')
after=$(audit_lines); [ -z "$after" ] && after=0
delta=$((after - before))
if [ "$rc" = "0" ] && [ "$delta" -ge 1 ] \
   && tail -n "$delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"category":"destructive"' \
   && tail -n "$delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"event":"escape"'; then
  ok "skip: trailing sentinel honored + audited in-harness (#206)"
else
  ng "skip: trailing sentinel not honored (rc=$rc, delta=$delta) (#206)"
fi

# 23h (#206): REGRESSION proving the gap — a bare command with NO sentinel
# (modeling what the harness delivers after eating a leading env-prefix) still
# BLOCKS. This is exactly the in-harness failure #206 fixes: a user who typed
# `SKIP_HOOKS=destructive ... git reset --hard` gets the prefix stripped, so the
# hook sees only the bare command. The sentinel (§23g) is the working path.
rc=$(hook_run 'git reset --hard')
if [ "$rc" = "2" ]; then
  ok "skip: bare command (harness-stripped leading prefix) still blocks (#206)"
else
  ng "skip: bare command should block (rc=$rc) (#206)"
fi

# 23i (#206): the sentinel + its reason text are STRIPPED before the matcher
# pass, so a reason containing a blockable substring cannot bleed into another
# matcher. Skip=destructive with a reason that mentions a force-push: only the
# destructive matcher should be considered (and skipped) — the force-push
# matcher must not fire on the stripped reason text.
rc=$(hook_run 'git reset --hard  # claude-eng:skip=destructive reason=mentions git push --force origin main')
if [ "$rc" = "0" ]; then
  ok "skip: sentinel reason text does not bleed into other matchers (#206)"
else
  ng "skip: sentinel reason bled into a matcher (rc=$rc) (#206)"
fi

# 23j (#206): a plain (non-namespaced) trailing comment is NOT an escape — the
# sentinel must carry the `claude-eng:skip=` namespace, else a normal comment
# could silently disable a guardrail.
rc=$(hook_run 'git reset --hard  # just a normal comment, not an escape')
if [ "$rc" = "2" ]; then
  ok "skip: plain trailing comment is not treated as an escape (#206)"
else
  ng "skip: plain comment wrongly skipped a matcher (rc=$rc) (#206)"
fi

# 23k (#206): SECURITY — a line-1 sentinel must NOT skip a dangerous command on
# a LATER line. bash `[[ =~ ]]` matches newlines, so a naive newline-spanning
# regex would let `echo ok # claude-eng:skip=destructive reason=x\n<danger>`
# greedily capture+strip the danger line before matchers, executing it under a
# falsified audit category. The single-trailing-line sentinel must reject this
# (no escape) → the command falls through to the matcher and BLOCKS.
rc=$(hook_run "$(printf 'echo ok  # claude-eng:skip=destructive reason=probe\ngit reset --hard')")
if [ "$rc" = "2" ]; then
  ok "skip: line-1 sentinel does not strip/bypass a later-line command (#206)"
else
  ng "skip: multi-line sentinel bypassed a later-line matcher (rc=$rc) (#206)"
fi

# 23m (#206): category-scoping bounds the command-scope of a tail sentinel — a
# last-line sentinel naming category X (out-of-scope) does NOT disarm an
# earlier-line danger of category Y (destructive). The destructive matcher still
# fires → BLOCK. (Documents/locks the SPEC §7 "category-scoped" guarantee that
# bounds the last-line-disarms-command behavior to the NAMED category only.)
rc=$(hook_run "$(printf 'git reset --hard\necho ok  # claude-eng:skip=out-of-scope reason=wrong-category')")
if [ "$rc" = "2" ]; then
  ok "skip: tail sentinel for category X does not disarm a category-Y danger (#206)"
else
  ng "skip: wrong-category tail sentinel disarmed a different matcher (rc=$rc) (#206)"
fi

# 23n (#208): SECURITY — the sentinel `#` must be a genuine UNQUOTED comment
# token, not a `#` inside a quoted argument. A destructive command carrying the
# sentinel text inside a quoted arg must STILL BLOCK: the executed shell runs the
# whole command (the `#` is argument text, not a comment), so the hook must not
# read it as an escape. Buggy pre-#208 code anchored the regex at end-of-string
# without a comment-token check, honored it (rc=0), and disarmed the matcher with
# a falsified audit reason.
rc=$(hook_run 'git reset --hard "note # claude-eng:skip=destructive reason=x"')
if [ "$rc" = "2" ]; then
  ok "skip: sentinel inside a quoted argument is not an escape (#208)"
else
  ng "skip: quoted-arg sentinel wrongly disarmed a matcher (rc=$rc) (#208)"
fi

# 23o (#208): REGRESSION GUARD — a GENUINE trailing-comment sentinel that follows
# an earlier quoted argument must still be honored. Guards against an over-strict
# fix that rejects the sentinel whenever any quote precedes the `#`.
before=$(audit_lines); [ -z "$before" ] && before=0
rc=$(hook_run 'git reset --hard "safe label"  # claude-eng:skip=destructive reason=genuine')
after=$(audit_lines); [ -z "$after" ] && after=0
delta=$((after - before))
if [ "$rc" = "0" ] && [ "$delta" -ge 1 ] \
   && tail -n "$delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"category":"destructive"'; then
  ok "skip: genuine trailing-comment sentinel after a quoted arg still honored (#208)"
else
  ng "skip: genuine sentinel after quoted arg not honored (rc=$rc, delta=$delta) (#208)"
fi

# 23p (#208 security review): ANSI-C $(...) quoting must not reopen the bypass.
# In `<cmd> $'x\' # claude-eng:skip=all reason=y'` the `\'` is an ESCAPED quote,
# so bash keeps the string open and the `#` is argument text, not a comment — the
# command runs intact and must STILL BLOCK. A naive single-quote scan would
# mis-close at `\'` and wrongly honor the sentinel.
rc=$(hook_run "git reset --hard \$'x\\' # claude-eng:skip=all reason=y'")
if [ "$rc" = "2" ]; then
  ok "skip: ANSI-C \$'...' escaped quote does not expose a sentinel (#208)"
else
  ng "skip: ANSI-C \$'...' sentinel wrongly honored (rc=$rc) (#208)"
fi

# 23q (#208 security review): a genuine sentinel whose `#` begins a line (after a
# newline word-boundary) on the command's final line is honored — fixes the
# newline false-deny. The command-scoped destructive skip then allows the line-1
# danger (SPEC §7 command-scope), and an escape record is written.
before=$(audit_lines); [ -z "$before" ] && before=0
rc=$(hook_run "$(printf 'git reset --hard\n# claude-eng:skip=destructive reason=newline-boundary')")
after=$(audit_lines); [ -z "$after" ] && after=0
delta=$((after - before))
if [ "$rc" = "0" ] && [ "$delta" -ge 1 ] \
   && tail -n "$delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"category":"destructive"'; then
  ok "skip: newline-boundary sentinel on the final line is honored (#208)"
else
  ng "skip: newline-boundary sentinel not honored (rc=$rc, delta=$delta) (#208)"
fi

# 23l. Outvar-collision regression: passing `cmd` as outvar (the same
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

# Register $SP_TARGET so the registry guard accepts it. Save and restore the
# real registry (already swapped to a temp $REG by the §4 setup at the top of
# this file).
SP_REGISTRY="$SHELL_ROOT/.claude/state/registry.txt"
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
    # Schema: 4 CLI-managed fields (Type / Status / Priority / Parent).
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
    # 4 v3 declared options = 7 total names. (Type field carries the legacy
    # Goal,Directive,Execution from a v0 substrate — v3 declares only
    # Directive,Execution, which is a subset; no Type reconcile fires.)
    SP_DIR2=$(mktemp -d)
    SP_TARGET2="$SP_DIR2/target"
    mkdir -p "$SP_TARGET2"
    SP_TARGET2=$(cd "$SP_TARGET2" && pwd -P)
    (cd "$SP_TARGET2" && git init -q && git remote add origin https://github.com/smoke-owner/smoke-repo.git 2>/dev/null) || true
    printf '%s\n' "$SP_TARGET2" >> "$SP_REGISTRY"
    mkdir -p "$SP_DIR2/fields" "$SP_DIR2/options"
    touch "$SP_DIR2/project-created"
    # v3 script declares 4 fields; pre-seed extra legacy fields (Confidence,
    # Success_Signals) so we cover the v0→v3 migration case where they exist
    # but are no longer declared. setup_project.sh skips fields it doesn't
    # declare (no destructive delete; cluster I's migration handles deletion).
    for f in Type Status Priority Parent Confidence Success_Signals; do touch "$SP_DIR2/fields/$f"; done
    # Pre-seed v0 Type option set; v3 declared is subset — no Type reconcile.
    printf 'Goal,Directive,Execution\n' > "$SP_DIR2/options/Type"
    printf 'Todo,In Progress,Done\n'    > "$SP_DIR2/options/Status"
    printf 'P0,P1,P2,P3\n'              > "$SP_DIR2/options/Priority"
    (
      cd "$SP_TARGET2" || exit 0
      PATH="$SP_BIN:$PATH" \
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
    printf '%s\n' "$SP_TARGET3" >> "$SP_REGISTRY"
    mkdir -p "$SP_DIR3/fields" "$SP_DIR3/options"
    touch "$SP_DIR3/project-created"
    for f in Type Status Priority Parent; do touch "$SP_DIR3/fields/$f"; done
    printf 'Directive,Execution\n'                        > "$SP_DIR3/options/Type"
    printf 'Proposed,Active,Blocked,Completed\n'          > "$SP_DIR3/options/Status"
    printf 'P0,P1,P2,P3\n'                                > "$SP_DIR3/options/Priority"
    (
      cd "$SP_TARGET3" || exit 0
      PATH="$SP_BIN:$PATH" \
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
# CLAUDE_ENG_BEHAVIORAL_SMOKE=1 — it shells out to the live agent and asserts
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

# ---------- 42e. activation-reviewer behavioral assertions (#69 / Directive #62) ----------
# Gated behind CLAUDE_ENG_BEHAVIORAL_SMOKE=1. When set, shells out to the live
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
- `CLAUDE_ENG_BEHAVIORAL_SMOKE=1 bash scripts/test/smoke.sh` adds the passing §42e assertions (`42e-ship`, `42e-refine-or-block`, `42e-exec`) on top of the default total; verified by counting `ok "42e-` lines in the output.

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
- [ ] `CLAUDE_ENG_BEHAVIORAL_SMOKE=1 bash scripts/test/smoke.sh` adds a passing `42e-exec` assertion.
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

# 43-reason-required (#80): /block-directive must mandate --reason <why>.
# The argument-hint frontmatter and the Procedure must both name --reason.
if grep -qE 'argument-hint:.*--reason' "$SHELL_ROOT/.claude/commands/block-directive.md" 2>/dev/null \
   && grep -qE '(--reason|`--reason)' "$SHELL_ROOT/.claude/commands/block-directive.md" 2>/dev/null; then
  ok "43-reason-required: /block-directive declares --reason in argument-hint + procedure (#80)"
else
  ng "43-reason-required: /block-directive must declare --reason in both argument-hint and procedure (#80)"
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
    CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
    PATH="$DP_BIN:$PATH" CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" GH_MOCK_LABELS_94="$1" \
      bash -c '. "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"; is_proposed_issue 94 && echo PROPOSED || echo NOT' 2>/dev/null )
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
    export CLAUDE_ENG_SHELL_ROOT="$TMP/s212root"
    rm -rf "$CLAUDE_ENG_SHELL_ROOT/.claude/state/issue-type-cache" 2>/dev/null
    mkdir -p "$CLAUDE_ENG_SHELL_ROOT/.claude/state"
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
AUDIT_FILE="$SHELL_ROOT/.claude/audit/audit.jsonl"

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

  DR50_REGISTRY="$SHELL_ROOT/.claude/state/registry.txt"
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
    CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
    CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
  PR_CACHE_REPO=test/repo PR_CACHE_DIR="$S52_DIR" CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
    zsh -c '
      set -e
      . "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/pr_cache.sh"
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
  s52c_out=$(PR_CACHE_REPO=test/repo PR_CACHE_DIR="$S52_DIR" CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
    zsh -c '
      . "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/pr_cache.sh"
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
  CLAUDE_ENG_SHELL_ROOT="$S53_DIR"
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
  CLAUDE_ENG_SHELL_ROOT="$S53_DIR"
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
  CLAUDE_ENG_SHELL_ROOT="$S53_DIR"
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
  s54g_list=""
  for f in "$SHELL_ROOT"/.github/ISSUE_TEMPLATE/*.yml "$SHELL_ROOT"/.github/workflows/auto-status-proposed.yml; do
    [ -f "$f" ] || continue
    if ! python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
      s54g_fails=$((s54g_fails+1))
      s54g_list="$s54g_list $(basename "$f")"
    fi
  done
  if [ "$s54g_fails" = 0 ]; then
    ok "54g: all 6 template + workflow YAML files parse cleanly (#93)"
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
    if [ -n "$n" ] && [ -f "$GH_SHIM_STATE/filer_$n" ]; then
      cat "$GH_SHIM_STATE/filer_$n"
    fi
    exit 0 ;;
esac
exit 0
SHIM
chmod +x "$PT55_SHIM/gh"

# Per-issue fixtures: write the authorAssociation literal to $GH_SHIM_STATE/filer_<n>.
printf 'OWNER\n'  > "$PT55_STATE/filer_100"   # trusted
printf 'NONE\n'   > "$PT55_STATE/filer_200"   # untrusted

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
        CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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
      CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
      bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
)
case $? in
  0) ok "55f: SKIP_HOOKS=trusted-filer-mutate escape allows otherwise-blocked close (#95)" ;;
  *) ng "55f: SKIP_HOOKS escape rc=$? (expected 0) (#95)" ;;
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
# shipped-release history, like the directive-reviewer rename); and this smoke
# file itself (its deprecation assertions necessarily name the retired agent).
s56f_hits=$(cd "$SHELL_ROOT" && git grep -l 'triage-reviewer' -- . \
  ':(exclude).claude/state' ':(exclude).claude/audit' \
  ':(exclude)CHANGELOG.md' ':(exclude)scripts/test/smoke.sh' 2>/dev/null)
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

# 57e: workflow parses `Parent Directive: #N` body marker.
if grep -qE 'Parent Directive: #' "$MIRROR_WF" 2>/dev/null; then
  ok "57e: workflow parses Parent Directive body marker (#96/cluster D)"
else
  ng "57e: workflow missing Parent Directive marker parse (#96/cluster D)"
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
printf '%s\n' "$S60_TARGET" >> "$SHELL_ROOT/.claude/state/registry.txt"

# Helper: invoke pre_tool_use.sh with a synthesized Edit input from $S60_TARGET.
s60_edit_run() {
  local target_path="$1"
  (
    cd "$S60_TARGET" || exit 1
    printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$target_path" \
      | CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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

# §60e (#210): Edit on a sensitive file under $CLAUDE_ENG_SHELL_ROOT/ → still
#       blocked. The shell-self-mod carve-out skips branch + out-of-scope, but
#       the sensitive-file check fires under BOTH carve-outs. Pre-#210 the
#       SHELL_ROOT arm did an early `exit 0` before the sensitive case, so this
#       was wrongly allowed.
s60e_target="$SHELL_ROOT/.claude/state/smoke-probe.pem"
s60_edit_run "$s60e_target"
case $? in
  2) ok "60e: Sensitive-file edit blocked under \$CLAUDE_ENG_SHELL_ROOT/ (sensitive check survives carve-out) (#210)" ;;
  *) ng "60e: expected rc=2 (sensitive block), got rc=$? under SHELL_ROOT (#210)" ;;
esac

# §60f (#210): regression — a NON-sensitive edit under $CLAUDE_ENG_SHELL_ROOT/
#       is still allowed (the self-mod carve-out still skips branch + scope for
#       ordinary shell files; the fix must not over-block shell self-modification).
s60f_target="$SHELL_ROOT/.claude/CLAUDE.md"
s60_edit_run "$s60f_target"
case $? in
  0) ok "60f: Non-sensitive shell self-modification still allowed under SHELL_ROOT (#210)" ;;
  *) ng "60f: expected rc=0 (allow), got rc=$? on shell self-mod file (#210)" ;;
esac

# Cleanup §60.
sp_tmp_reg=$(mktemp); grep -vxF "$S60_TARGET" "$SHELL_ROOT/.claude/state/registry.txt" > "$sp_tmp_reg" 2>/dev/null || true
mv "$sp_tmp_reg" "$SHELL_ROOT/.claude/state/registry.txt"
rm -rf "$S60_DIR"

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
   && grep -q "reason not_planned" "$SHELL_ROOT/.claude/commands/resolve-discussion.md"; then
  ok "62b: /resolve-discussion skill names both close paths + reasons (#116)"
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
printf '%s\n' "$S62_TARGET" >> "$SHELL_ROOT/.claude/state/registry.txt"

# Mock gh: returns labels including "discussion" for issue view + --jq-aware
# output (the hook calls `gh issue view N --json labels --jq '.labels[].name'`
# which would yield raw label names one-per-line).
cat > "$S62_DIR/bin/gh" <<'GHEOF'
#!/bin/sh
# Mock gh for §62 — discussion-tier close-path enforcement.
case "$*" in
  *"issue view"*"--json"*"--jq"*)
    # The hook calls --jq '.labels[].name'; emit the label names raw.
    printf 'discussion\n'
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
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd" \
      | PATH="$S62_DIR/bin:$PATH" CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
  )
  return $?
}

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

# §62e: `gh issue close <N> --reason not_planned` on discussion-labeled Issue → ALLOWED (rc=0).
s62_close_run "gh issue close 999 --reason not_planned"
case $? in
  0) ok "62e: gh issue close --reason not_planned on discussion Issue → allow (#116)" ;;
  *) ng "62e: expected rc=0 (allow) for --reason not_planned, got rc=$? (#116)" ;;
esac

# Cleanup §62.
sp_tmp_reg=$(mktemp); grep -vxF "$S62_TARGET" "$SHELL_ROOT/.claude/state/registry.txt" > "$sp_tmp_reg" 2>/dev/null || true
mv "$sp_tmp_reg" "$SHELL_ROOT/.claude/state/registry.txt"
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
         workflows/dir-mode-post-merge.yml workflows/check-changelog.yml; do
  [ -f "$S63_SUB/$f" ] && s63a_count=$((s63a_count + 1))
done
if [ "$s63a_count" = 11 ]; then
  ok "63a: target-substrate canonical-source has 11 files (6 ISSUE_TEMPLATE + 5 workflows) (#118 + #133 + #180)"
else
  ng "63a: target-substrate canonical-source missing files: expected 11, found $s63a_count (#118 + #133 + #180)"
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
for required in "status:proposed" "status:blocked" "awaiting-author" "execution" "discussion" "task" "skip-changelog" "P0" "P1" "P2" "P3"; do
  if ! printf '%s' "$s63g_out" | grep -qE "gh label create '$required'"; then
    s63g_ok=0
    break
  fi
done
if [ "$s63g_ok" = 1 ]; then
  ok "63g: onboard_target --tier 2 --dry-run emits gh label create for all v3-bootstrap labels including status:proposed + status:blocked + skip-changelog (#118 + #133)"
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

# 64b — `bin/claude-eng --version` exits 0 from an unregistered cwd and
# emits the shell's own VERSION (not the underlying `claude` CLI's
# version). Confirms the --version short-circuit runs before the
# registry/scope guard AND before `exec claude` (Directive #122
# constraint #3; required because line 39 of bin/claude-eng currently
# `exec`s to `claude`, so any pre-fix forward-through gets caught here).
s64b_tmp=$(mktemp -d)
s64b_out=$(cd "$s64b_tmp" && "$SHELL_ROOT/bin/claude-eng" --version 2>/dev/null)
s64b_rc=$?
rm -rf "$s64b_tmp"
s64b_expected=$(cat "$SHELL_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')
s64b_got=$(printf '%s' "$s64b_out" | tr -d '[:space:]')
if [ "$s64b_rc" = "0" ] && [ -n "$s64b_out" ] && [ "$s64b_got" = "$s64b_expected" ]; then
  ok "64b: bin/claude-eng --version exits 0 with shell's VERSION ('$s64b_expected') from unregistered cwd (#123)"
else
  ng "64b: bin/claude-eng --version did not return shell's VERSION (rc=$s64b_rc expected='$s64b_expected' got='$s64b_got') (#123)"
fi

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
printf '%s\n' "$S69_TARGET" >> "$SHELL_ROOT/.claude/state/registry.txt"

# Mock gh: issue 777 is parented (line-1 marker), 888 is standalone (no marker),
# 555 simulates gh failure (fail-open path). The matcher calls
# `gh issue view <N> --json body -q .body`; the mock emits the post-jq body raw.
cat > "$S69_DIR/bin/gh" <<'GHEOF'
#!/bin/sh
case "$*" in
  *"issue view 777"*) printf 'Parent Directive: #92\n\n## What\nparented execution work\n'; exit 0 ;;
  *"issue view 888"*) printf '## What\nstandalone task body, no marker\n'; exit 0 ;;
  *"issue view 555"*) exit 1 ;;   # gh down / no auth → predicate rc 2 → fail open
  *) exit 0 ;;
esac
GHEOF
chmod +x "$S69_DIR/bin/gh"

s69_edit_run() {
  # $1 = full command (may carry a SKIP_HOOKS env-prefix for the escape case).
  (
    cd "$S69_TARGET" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
      | PATH="$S69_DIR/bin:$PATH" CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT" \
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

# §69g (#212): correctness of the BASH_REMATCH renumber — the captured label
# must be the gated token after the comma, not the prefix. 777 HAS a marker, so
# `task` (standalone) contradicts it → block. If the prefix `bar` were captured
# instead of `task`, it would be non-gated and fail-open allow.
s69_edit_run "gh issue edit 777 --add-label bar,task"
case $? in
  2) ok "69g: comma-list label correctly captured (bar,task → task contradiction blocks) (#212)" ;;
  *) ng "69g: comma-list label mis-captured (renumber regression?), got rc=$? (#212)" ;;
esac

# §69h (#212): no over-match — a longer label like `executionish` is not the
# gated `execution` token and must allow (777 has marker, but executionish is
# ungated so the arm fails open regardless).
s69_edit_run "gh issue edit 777 --add-label executionish"
case $? in
  0) ok "69h: --add-label executionish does not over-match the gated token → allow (#212)" ;;
  *) ng "69h: executionish over-matched the gated label, got rc=$? (#212)" ;;
esac

# Cleanup §69.
s69_tmp_reg=$(mktemp); grep -vxF "$S69_TARGET" "$SHELL_ROOT/.claude/state/registry.txt" > "$s69_tmp_reg" 2>/dev/null || true
mv "$s69_tmp_reg" "$SHELL_ROOT/.claude/state/registry.txt"
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
