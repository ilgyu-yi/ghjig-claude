#!/usr/bin/env bash
# scripts/test/smoke.sh — shell infrastructure sanity check.
# Verifies hook/helper/inject behavior without running Claude Code.
#
# ── Test-integrity / anti-vacuity discipline (#279, Theme E) ──────────────────
# An assertion that greens WITHOUT exercising the property it names is worse than
# no assertion — it reads as coverage while guarding nothing. Two recurring
# vacuous-pass anti-patterns, and the fix for each:
#
#   1. Comment-satisfiable grep. `grep -q 'token' "$FILE"` passes when `token`
#      appears only in a COMMENT/prose, not the CODE form the assertion claims to
#      verify. → Anchor the grep to the code form (e.g. `^Parent Initiative` with
#      the leading caret a regex carries but a comment usually doesn't; or a
#      `should_skip <cat>`-shaped pattern), not a bare token. (Fixed live: §57e.)
#
#   2. Silent skip on an absent target. `[ -f "$f" ] && grep …` (or `… || continue`
#      over a glob, or an `if [ -f ]; then … ` with no `else`) reports green when
#      `$f` is absent — the property went unchecked. → Fail LOUD on a missing
#      target the assertion claims to read (`ng` / `MISSING:`), and when a check
#      iterates an expected SET, assert the COUNT actually checked (a count-guard)
#      so an empty glob can't pass "all N …". (Fixed live: §57i, §54g.)
#
# Optional-tooling skips (`gdlint`/`timeout`/`pyyaml` absent → ok "… skipped") are
# NOT vacuous: the property is genuinely untestable without the tool, and the skip
# is reported. The anti-pattern is a skip that masquerades as a PASS of the thing.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SHELL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export GHJIG_ROOT="$SHELL_ROOT"

# §357 AC1 backstop (capture half) — snapshot the LIVE shared sinks' size BEFORE
# any fixture fires. Reads the literal $SHELL_ROOT paths (NOT $SMOKE_*): a smoke
# run must add ZERO lines to the shell's live audit log + scope registry (state
# isolation, #357). The matching assertion sits just before the results block;
# it fails LOUD if a future change reintroduces a live-sink write. Captured here,
# before the §4 registry backup, so it reflects the truly untouched live state.
S357_LIVE_AUDIT="$SHELL_ROOT/.claude/audit/audit.jsonl"
S357_LIVE_REG="$SHELL_ROOT/.claude/state/registry.txt"
# Guard with [ -f ] before the `< file` redirect: bash applies `< file` BEFORE
# `2>/dev/null`, so on an absent path the open-failure reaches the real stderr
# unsuppressed (a spurious "No such file" line, #417). An absent sink snapshots
# as 0 — the assertion semantics are unchanged.
s357_audit_before=0; [ -f "$S357_LIVE_AUDIT" ] && s357_audit_before=$(wc -l < "$S357_LIVE_AUDIT" | tr -d ' ')
s357_reg_before=0; [ -f "$S357_LIVE_REG" ] && s357_reg_before=$(wc -l < "$S357_LIVE_REG" | tr -d ' ')

# §357 — pin ALL fixture hook fires to an isolated ephemeral state dir for the
# whole run. ghjig_state_dir() honors GHJIG_STATE_DIR_OVERRIDE as top priority, so
# every audit_log + argless ghjig_registry_file (in_scope) resolves here instead
# of the shell's live shared sinks. Class A registry writes target $SMOKE_REG;
# resolver-contract tests (§83/§84) and §20 locally `unset` this to exercise the
# other branches; Class B guard tests (§41/§50) register on their target's own
# per-project ghjig-state path. Cleaned on EXIT (see the §4 trap).
SMOKE_STATE=$(mktemp -d)
SMOKE_AUDIT="$SMOKE_STATE/audit/audit.jsonl"
SMOKE_REG="$SMOKE_STATE/registry.txt"
mkdir -p "$SMOKE_STATE/audit"
export GHJIG_STATE_DIR_OVERRIDE="$SMOKE_STATE"
# #586 — merge-review REPLACES the retired merge-attestation file arm (#544).
# The gate now reads a GitHub review OBJECT at the current head via `gh` (not a
# $(ghjig_state_dir)/attest/pr-<N> file), so no state-dir seed makes the
# pre-existing ac-closeout/merge-strategy/pass-through merge fixtures pass it.
# Instead each of those fixtures' gh shims (§38/§39/§78) serves a canned
# APPROVED-at-head review whose commit_id == the `smoke-attest-head` its
# headRefOid arm reports, plus a nameWithOwner — so merge-review resolves to a
# SILENT mark_allow (native APPROVED@head) and each fixture keeps asserting its
# own gate's verdict with no bypass-audit noise polluting the audit-count
# assertions. (The §137/§140 suites override GHJIG_STATE_DIR_OVERRIDE and carry
# their own per-case gh state, so nothing here leaks into them.)
# §361 — mark every fixture-fire audit record as test-origin (Directive #356
# signal 1). Only the exact token `test` flips audit_log's `source` field; a
# real Bash-tool action cannot inject this into the hook subprocess (SPEC §7),
# so `source=live` stays the trustworthy default for real sessions. §93's
# default/forged-value sub-tests locally unset / re-set this.
export GHJIG_AUDIT_SOURCE=test

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
  .claude/commands/flush.md \
  .claude/hooks/pre_tool_use.sh \
  .claude/hooks/post_tool_use.sh \
  .claude/hooks/stop.sh \
  .claude/hooks/user_prompt_submit.sh \
  .claude/hooks/session_start.sh \
  .claude/templates/pr_body.md \
  bin/ghjig \
  scripts/bootstrap.sh \
  scripts/clone-into.sh \
  scripts/register.sh \
  scripts/setup.sh \
  scripts/lib/onboard_checks.sh \
  scripts/lib/inject.sh \
; do
  [ -f "$SHELL_ROOT/$f" ] && ok "exists: $f" || ng "missing: $f"
done

# ---------- 2. helper / hook syntax ----------
for h in log escape cwd_guard detect_stack branch_guard conventional_commit secret_scan tests gh_state ghjig_commit; do
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
trap 'rm -rf "$TMP" "$SMOKE_STATE"' EXIT
# fake target git repo (init may default to main; immediately move to a feature branch)
(cd "$TMP" && git init -q fake && cd fake && git checkout -b smoke/feat/1-test -q 2>/dev/null && git commit --allow-empty -q -m init 2>/dev/null) || true
. "$SHELL_ROOT/scripts/lib/inject.sh"

# #357: no registry backup/restore needed — the whole-run GHJIG_STATE_DIR_OVERRIDE
# pins all fixture in_scope reads/writes to $SMOKE_REG, and the Class B guard
# tests (§41/§50) register on their target's own ghjig-state path, so the shell's
# live shared $SHELL_ROOT/.claude/state/registry.txt is never written at all.

inject_into "$TMP/fake" >/dev/null 2>&1 && ok "inject_into ok" || ng "inject_into failed"
[ -L "$TMP/fake/.claude/settings.local.json" ] && ok "settings.local.json symlinked" || ng "settings.local.json missing"
[ -L "$TMP/fake/.claude/agents/planner.md" ] && ok "agents/planner.md symlinked" || ng "agents/planner.md missing"
grep -q "$TMP/fake" "$TMP/fake/.claude/ghjig-state/registry.txt" 2>/dev/null && ok "registry entry added (per-project, #316)" || ng "registry not updated"
grep -q "^.claude/settings.local.json" "$TMP/fake/.git/info/exclude" 2>/dev/null && ok ".git/info/exclude updated" || ng "exclude not updated"

# #316/#357: inject records the entry in the TARGET's per-project registry. The
# hook-integration tests (§7+) and hook_run drive the hook with CLAUDE_PROJECT_DIR
# unset, so audit and in_scope resolve through ghjig_state_dir() — which this harness
# pins to an isolated $SMOKE_STATE for the WHOLE run (GHJIG_STATE_DIR_OVERRIDE,
# exported near the top, #357). That keeps every fixture hook fire off the shell's
# LIVE shared sinks ($SHELL_ROOT/.claude/audit/audit.jsonl + .../state/registry.txt),
# restoring the MISSION "shared code, per-project state" isolation invariant for the
# test path. So we mirror the target into $SMOKE_REG (the override's registry), NOT
# the live shared registry, so those matcher tests still reach the matchers (the
# per-project path is covered by §84). Use the CANONICAL path (inject_into
# canonicalizes via `cd && pwd -P`; the hook's in_scope compares against pwd -P),
# else macOS /var vs /private/var never matches. The resolver-contract tests
# (§83/§84) and §20 locally `unset GHJIG_STATE_DIR_OVERRIDE` to exercise the other
# branches; the Class B guard tests (§41/§50) register on the target's own
# ghjig-state path so the live shared registry is never written at all.
FAKE_CANON=$(cd "$TMP/fake" && pwd -P)
mkdir -p "$SHELL_ROOT/.claude/state"
grep -qxF "$FAKE_CANON" "$SMOKE_REG" 2>/dev/null \
  || printf '%s\n' "$FAKE_CANON" >> "$SMOKE_REG"

# ---------- 5. cwd_guard ----------
# hookrt.sh hosts ghjig_registry_file (#316); cwd_guard rides it. In a real hook
# the hook sources hookrt first — mirror that here. The registry now resolves
# per-project, so the registered-path checks run with CLAUDE_PROJECT_DIR set
# (hook context); the unregistered + carve-out checks need no project context.
. "$SHELL_ROOT/.claude/hooks/hookrt.sh"
. "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"

(cd "$TMP/fake" && CLAUDE_PROJECT_DIR="$TMP/fake" in_scope) && ok "in_scope: registered path" || ng "in_scope should be true"
(cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" in_scope) && ng "in_scope: unregistered should be false" || ok "in_scope: unregistered false"

CLAUDE_PROJECT_DIR="$TMP/fake" path_in_scope "$TMP/fake/some/file" && ok "path_in_scope: inside registered" || ng "path_in_scope should be true"
CLAUDE_PROJECT_DIR="$TMP/fake" path_in_scope "/etc/passwd" && ng "path_in_scope: /etc/passwd should be false" || ok "path_in_scope: /etc/passwd false"
CLAUDE_PROJECT_DIR="$TMP/fake" path_in_scope "$HOME/.zshrc" && ng "path_in_scope: ~/.zshrc should be false" || ok "path_in_scope: ~/.zshrc false"
path_in_scope "$SHELL_ROOT/.claude/CLAUDE.md" && ok "path_in_scope: shell self allowed" || ng "shell self should be allowed"

# 5b (#218): a registry entry WITH a trailing slash must still scope paths under
# it. Pre-#218 the `"$entry"/*` glob became `entry//*` (double slash) and never
# matched, and the `[ "$p" = "$entry" ]` equality failed too — the path silently
# dropped from scope (fail-open on the scope guard). Both loops normalize via
# `${entry%/}` now.
S5B_DIR=$(cd "$(mktemp -d)" && pwd -P)   # physical-resolved (path_in_scope resolves symlinks)
printf '%s/\n' "$S5B_DIR" >> "$SMOKE_REG"   # trailing slash entry
path_in_scope "$S5B_DIR/sub/file.txt" \
  && ok "5b: trailing-slash registry entry still scopes paths under it (#218)" \
  || ng "5b: trailing-slash registry entry dropped its path from scope (#218)"
(cd "$S5B_DIR" && in_scope) \
  && ok "5b: in_scope true inside a trailing-slash registry entry (#218)" \
  || ng "5b: in_scope false inside a trailing-slash registry entry (#218)"
s5b_tmp=$(mktemp); grep -vxF "$S5B_DIR/" "$SMOKE_REG" > "$s5b_tmp" 2>/dev/null || true
mv "$s5b_tmp" "$SMOKE_REG"
rmdir "$S5B_DIR" 2>/dev/null || true

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

# 6c (#214): modern OpenAI key formats (sk-proj-/svcacct-/admin-) contain `-`/`_`,
# so the legacy `sk-[A-Za-z0-9]{40,}` (which stops at the first `-`) missed them.
# Helper: stage $1 in a file, echo DETECTED or PASSED (PASSED = scan returned 0).
# NOTE: the test keys are ASSEMBLED at runtime from `$s214_pfx` ("sk-") so no
# committed source line here contains a contiguous scanner-matching literal —
# this file (scripts/test/smoke.sh) is itself scanned (NOT allow-listed), so a
# literal key would self-block future edits. The runtime-assembled full key is
# what gets written to leak.txt and scanned. (#214 security review.)
s214_pfx='sk-'
s214_scan() {
  ( SCAN_214=$(mktemp -d); cd "$SCAN_214" || exit 1; git init -q
    printf 'key = "%s"\n' "$1" > leak.txt; git add leak.txt
    scan_staged_secrets >/dev/null 2>&1 && echo PASSED || echo DETECTED
    cd / ; rm -rf "$SCAN_214" )
}
# Positive: a current-gen sk-proj- key must be DETECTED (fails pre-#214).
[ "$(s214_scan "${s214_pfx}proj-Ab12Cd34_ef56-Gh78Ij90Kl12Mn34Op56Qr78St90Uv")" = DETECTED ] \
  && ok "6c: secret_scan detects modern sk-proj- OpenAI key (#214)" \
  || ng "6c: modern sk-proj- key NOT detected (false negative) (#214)"
# Regression: a legacy sk- + 46 alnum key is still detected.
[ "$(s214_scan "${s214_pfx}ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij")" = DETECTED ] \
  && ok "6c: secret_scan still detects legacy sk- OpenAI key (#214)" \
  || ng "6c: legacy sk- key regression (#214)"
# Negative (no over-broad FP): a short sk- identifier must NOT be flagged.
[ "$(s214_scan "${s214_pfx}short")" = PASSED ] \
  && ok "6c: short sk- identifier not flagged (floor preserved) (#214)" \
  || ng "6c: short sk- identifier wrongly flagged (#214)"

# 6c2 (#551): GitHub App server-to-server (ghs_, incl. Actions GITHUB_TOKEN),
# user-to-server (ghu_) and refresh (ghr_) token families must be DETECTED —
# previously only ghp_/gho_/github_pat_ were covered, so these committed CLEAN.
# Prefix assembled at runtime so no scanner-matching literal lands in this file.
s551_pfx='gh'
s551_scan() {
  ( SCAN_551=$(mktemp -d); cd "$SCAN_551" || exit 1; git init -q
    printf 'token = "%s"\n' "$1" > leak.txt; git add leak.txt
    scan_staged_secrets >/dev/null 2>&1 && echo PASSED || echo DETECTED
    cd / ; rm -rf "$SCAN_551" )
}
for fam in s u r; do
  [ "$(s551_scan "${s551_pfx}${fam}_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab")" = DETECTED ] \
    && ok "6c2: secret_scan detects gh${fam}_ token family (#551)" \
    || ng "6c2: gh${fam}_ token family NOT detected (false negative) (#551)"
done
# Negative (floor preserved): a short gh_-prefixed identifier must NOT be flagged.
[ "$(s551_scan "${s551_pfx}s_short")" = PASSED ] \
  && ok "6c2: short ghs_ identifier not flagged (floor preserved) (#551)" \
  || ng "6c2: short ghs_ identifier wrongly flagged (#551)"

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

# #234: Edit via a symlink named innocuously but pointing at a sensitive target
# must block on the RESOLVED basename, not just the lexical one. Pre-fix the
# lexical basename ("cfg_link") is not sensitive → wrongly allowed.
ln -s "$TMP/fake/cfgdir/.env" "$TMP/fake/cfg_link" 2>/dev/null
out=$(cd "$TMP/fake" && fake_input "Edit" "{\"file_path\":\"$TMP/fake/cfg_link\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 2 ] && ok "234: symlink-named-innocent → sensitive target edit blocked (#234)" \
              || ng "234: symlink → sensitive target not blocked (rc=$rc) (#234)"
rm -f "$TMP/fake/cfg_link"

# #234 regression: a plain (non-symlink) sensitive file still blocks (lexical).
out=$(cd "$TMP/fake" && fake_input "Edit" "{\"file_path\":\"$TMP/fake/sub/.env\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 2 ] && ok "234: plain .env edit still blocked (lexical regression) (#234)" \
              || ng "234: plain .env edit not blocked (rc=$rc) (#234)"

# #234 no over-block: a symlink to a NON-sensitive target is allowed.
ln -s "$TMP/fake/data/notes.txt" "$TMP/fake/notes_link" 2>/dev/null
out=$(cd "$TMP/fake" && fake_input "Edit" "{\"file_path\":\"$TMP/fake/notes_link\"}" \
  | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" 2>&1)
rc=$?
[ "$rc" = 0 ] && ok "234: symlink to a non-sensitive target allowed (no over-block) (#234)" \
              || ng "234: symlink to non-sensitive target wrongly blocked (rc=$rc) (#234)"
rm -f "$TMP/fake/notes_link"

# ---- §501a-g (#501 / Directive #498): sensitive-file matcher case-fold +
# documented-contract globs. In-scope paths under $TMP/fake/sub so the
# out-of-scope arm doesn't pre-empt; basenames need not exist (lexical match).
s501_run() {  # $1 = basename → echoes the hook rc for an Edit under $TMP/fake/sub
  ( cd "$TMP/fake" && fake_input "Edit" "{\"file_path\":\"$TMP/fake/sub/$1\"}" \
    | "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 ); echo $?
}
# 501a/b (case-fold): uppercase variants of sensitive basenames must block.
[ "$(s501_run '.ENV')" = 2 ]    && ok "501a: '.ENV' (case variant) edit blocked (#501)"        || ng "501a: '.ENV' not blocked — case-sensitive matcher (#501)"
[ "$(s501_run 'key.PEM')" = 2 ] && ok "501b: 'key.PEM' (case variant) edit blocked (#501)"     || ng "501b: 'key.PEM' not blocked — case-sensitive matcher (#501)"
# 501c/d (documented-contract prefix globs): `credentials*` / `id_rsa*` per the
# SPEC §6.1 / CLAUDE.md contract (code used the narrower `credentials.*`).
[ "$(s501_run 'credentialsX')" = 2 ]  && ok "501c: 'credentialsX' edit blocked (credentials* contract) (#501)"  || ng "501c: 'credentialsX' not blocked — code narrower than documented contract (#501)"
[ "$(s501_run 'id_rsa_backup')" = 2 ] && ok "501d: 'id_rsa_backup' edit blocked (id_rsa* contract) (#501)"      || ng "501d: 'id_rsa_backup' not blocked — code narrower than contract (#501)"
# 501e (double-extension): a renamed/backup key like `key.pem.txt` must block.
[ "$(s501_run 'key.pem.txt')" = 2 ] && ok "501e: 'key.pem.txt' (double-extension) edit blocked (#501)" || ng "501e: 'key.pem.txt' not blocked — double-extension evasion (#501)"
# 501f (no over-block GUARD — must stay green): an in-scope non-sensitive file is allowed.
[ "$(s501_run 'notes.md')" = 0 ]  && ok "501f: in-scope 'notes.md' still allowed (no over-block) (#501)" || ng "501f: non-sensitive 'notes.md' wrongly blocked (#501)"
# 501g (regression): the canonical lowercase '.env' still blocks.
[ "$(s501_run '.env')" = 2 ]      && ok "501g: '.env' still blocked (lowercase regression) (#501)"        || ng "501g: '.env' regression — no longer blocked (#501)"

# ---- §555 A1 (#555 / Directive #550): the Edit/Write carve-outs must LEXICALLY
# normalize $target (collapse `.`/`..` segments as pure string ops, NO pwd -P /
# realpath / filesystem access) before the prefix match, so a ..-laden absolute
# path can't borrow a carve-out to skip the out-of-scope gate. Pre-fix a raw
# prefix match on `$SHELL_ROOT/../../.../etc/passwd` set shell_self_mod /
# user_global_memory and allowed the edit. `passwd` is a non-sensitive basename,
# so the out-of-scope arm is the sole decider (isolates the carve-out bypass).
# Runs from $TMP/fake. NOTE (parked-PR #561 root cause): the first fix physically
# resolved $target, which only collapses `..` when the ancestor dir EXISTS; on a
# CI runner lacking `$HOME/.claude` it fell back to the raw path and the home
# carve-out bypass re-opened — the 555a1-home-absent case below pins that exact
# condition (HOME → a temp dir with NO .claude subdir; lexical normalization must
# still block).
s555a1_run() {  # $1 = file_path → echoes hook rc for an Edit on it
  ( cd "$TMP/fake" && fake_input "Edit" "{\"file_path\":\"$1\"}" \
    | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 ); echo $?
}
# 555a1-shell: a ..-traversal out of the $SHELL_ROOT carve-out → out-of-scope block.
[ "$(s555a1_run "$SHELL_ROOT/../../../../../../../../etc/passwd")" = 2 ] \
  && ok "555a1: ..-path escaping the \$SHELL_ROOT carve-out → out-of-scope blocked (#555)" \
  || ng "555a1: ..-path carve-out bypass not blocked — raw prefix match (#555)"
# 555a1-home: same escape out of the $HOME/.claude carve-out → out-of-scope block.
[ "$(s555a1_run "$HOME/.claude/../../../../../../../../etc/passwd")" = 2 ] \
  && ok "555a1: ..-path escaping the \$HOME/.claude carve-out → out-of-scope blocked (#555)" \
  || ng "555a1: ..-path \$HOME/.claude carve-out bypass not blocked (#555)"
# 555a1-home-absent (parked-PR regression pin): run with HOME → a temp dir that
# has NO .claude subdir — the CI condition that broke the physical-resolve fix.
# The `$HOME/.claude` carve-out ancestor does not exist, so a physical resolve
# would fall back to the raw `..`-path and match the carve-out (bypass); the
# lexical collapse folds it to /etc/passwd and must still block.
S555A1_HOME=$(mktemp -d)   # empty dir — no .claude under it
[ "$( ( cd "$TMP/fake" && fake_input "Edit" "{\"file_path\":\"$S555A1_HOME/.claude/../../../../../../../../etc/passwd\"}" \
    | HOME="$S555A1_HOME" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 ); echo $? )" = 2 ] \
  && ok "555a1: ..-path escaping \$HOME/.claude blocked even when \$HOME/.claude is ABSENT (#555)" \
  || ng "555a1: carve-out bypass re-opens when \$HOME/.claude absent (physical-resolve regression) (#555)"
rm -rf "$S555A1_HOME"
# 555a1-regression (no over-block): a GENUINE shell-self edit still allowed.
[ "$(s555a1_run "$SHELL_ROOT/.claude/CLAUDE.md")" = 0 ] \
  && ok "555a1: genuine \$SHELL_ROOT self-edit still allowed (no over-block) (#555)" \
  || ng "555a1: genuine shell-self edit wrongly blocked (#555)"

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
mkdir -p "$SR_TMP/.claude/ghjig-state"
if command -v ensure_self_registered >/dev/null 2>&1; then
  ensure_self_registered "$SR_TMP" >/dev/null 2>&1
  grep -qxF "$SR_TMP" "$SR_TMP/.claude/ghjig-state/registry.txt" 2>/dev/null \
    && ok "self-register: registry entry added (per-project, #316)" || ng "self-register: should add registry entry"
  ensure_self_registered "$SR_TMP" >/dev/null 2>&1
  count=$(grep -cxF "$SR_TMP" "$SR_TMP/.claude/ghjig-state/registry.txt" 2>/dev/null || echo 0)
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
mkdir -p "$FAKE_SR/scripts/lib" "$FAKE_SR/.claude/state" "$FAKE_SR/.claude/hooks" "$FAKE_SR/.claude/agents" "$FAKE_SR/.claude/commands" "$FAKE_SR/workspace"
echo '{}' > "$FAKE_SR/.claude/settings.json"
cp "$SHELL_ROOT/scripts/register.sh" "$FAKE_SR/scripts/register.sh"
cp "$SHELL_ROOT/scripts/lib/inject.sh" "$FAKE_SR/scripts/lib/inject.sh"
[ -f "$SHELL_ROOT/scripts/lib/self_register.sh" ] && cp "$SHELL_ROOT/scripts/lib/self_register.sh" "$FAKE_SR/scripts/lib/self_register.sh"
# self_register/inject resolve the registry via ghjig_registry_file (hookrt.sh, #316),
# defensively sourced from GHJIG_ROOT (= FAKE_SR here) — so the fake root
# needs a real hookrt.sh, exactly as a real shell root carries one.
cp "$SHELL_ROOT/.claude/hooks/hookrt.sh" "$FAKE_SR/.claude/hooks/hookrt.sh"
chmod +x "$FAKE_SR/scripts/register.sh"

"$FAKE_SR/scripts/register.sh" "$FAKE_SR" >/dev/null 2>&1 || true

ws_link="$FAKE_SR/workspace/$(basename "$FAKE_SR")"
[ ! -e "$ws_link" ] && ok "register.sh: no workspace symlink-loop when target=SHELL_ROOT" \
  || ng "register.sh created workspace symlink-loop: $ws_link"

grep -qxF "$FAKE_SR" "$FAKE_SR/.claude/ghjig-state/registry.txt" 2>/dev/null \
  && ok "register.sh: SHELL_ROOT recorded in registry (per-project, #316)" \
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
grep -qE 'bin[[:space:]]+to PATH|bin/ghjig' "$BOOTSTRAP" \
  && ok "bootstrap.sh: surfaces PATH install option" \
  || ng "bootstrap.sh: missing PATH install guidance"
grep -qE 'alias[[:space:]]+ghjig' "$BOOTSTRAP" \
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
  unset GHJIG_SHELL_MODE
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
  export GHJIG_SHELL_MODE=unattended
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
  export GHJIG_SHELL_MODE=unattended
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
  unset GHJIG_SHELL_MODE
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
  unset GHJIG_SHELL_MODE
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

# 13d (#318). status_compact surfaces the bound canonical root (`shell-root:`)
# and the ephemeral-state locality (`state:` = project-local | legacy-shared),
# the SPEC §5.5 fields that make the §1.7 shared-code/per-project-state model
# legible in every turn. Drive with CLAUDE_PROJECT_DIR set (hook context) so
# locality resolves to project-local.
(
  cd "$SHELL_ROOT" || exit 1
  command -v status_compact >/dev/null 2>&1 || exit 1
  out=$(CLAUDE_PROJECT_DIR="$SHELL_ROOT" status_compact 2>/dev/null)
  printf '%s' "$out" | grep -q '^shell-root:' \
    && printf '%s' "$out" | grep -Eq '^state: (project-local|legacy-shared)'
) && ok "13d: status_compact surfaces shell-root + state locality (#318)" \
  || ng "13d: status_compact missing shell-root/state fields (#318)"

# 13e (#318). status_json carries the same two fields (parity with compact):
# .shell_root (string) and .state_locality (project-local|legacy-shared).
(
  cd "$SHELL_ROOT" || exit 1
  command -v status_json >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 1
  out=$(CLAUDE_PROJECT_DIR="$SHELL_ROOT" status_json 2>/dev/null)
  printf '%s' "$out" | jq -e '.shell_root and (.state_locality | test("^(project-local|legacy-shared)$"))' >/dev/null 2>&1
) && ok "13e: status_json carries shell_root + state_locality (parity, #318)" \
  || ng "13e: status_json missing shell_root/state_locality (#318)"

# 13f/13g (#325). status_compact/status_json surface the active work language,
# resolved via resolve_work_lang. Drive with GHJIG_WORK_LANG for determinism,
# and an isolated STATUS_CACHE_DIR_OVERRIDE so a pre-existing per-branch status
# cache (written before this field landed) can't serve a stale short-circuit.
WL13_CACHE=$(cd "$(mktemp -d)" && pwd -P)

# 13f: compact emits `work-lang: <code>`.
(
  cd "$SHELL_ROOT" || exit 1
  command -v status_compact >/dev/null 2>&1 || exit 1
  out=$(GHJIG_WORK_LANG=ja STATUS_CACHE_DIR_OVERRIDE="$WL13_CACHE" status_compact 2>/dev/null)
  printf '%s' "$out" | grep -q '^work-lang: ja$'
) && ok "13f: status_compact surfaces work-lang (#325)" \
  || ng "13f: status_compact missing work-lang field (#325)"

# 13g: json carries .work_lang with the same value (parity).
(
  cd "$SHELL_ROOT" || exit 1
  command -v status_json >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 1
  out=$(GHJIG_WORK_LANG=ja STATUS_CACHE_DIR_OVERRIDE="$WL13_CACHE" status_json 2>/dev/null)
  printf '%s' "$out" | jq -e '.work_lang == "ja"' >/dev/null 2>&1
) && ok "13g: status_json carries work_lang (parity, #325)" \
  || ng "13g: status_json missing work_lang (#325)"
rm -rf "$WL13_CACHE"

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
grep -qxF "$SHELL_ROOT" "$SMOKE_REG" 2>/dev/null \
  || printf '%s\n' "$SHELL_ROOT" >> "$SMOKE_REG"

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
      | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
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

# 15f (#277 Theme B): operand-permutation — a force/recursive flag placed AFTER
# the operand (valid GNU syntax) must not bypass the out-of-scope block. Pre-#277
# the entry pre-filter required the flag to follow the verb with only other flags
# between, so `rm <path> -rf` never entered → silent allow.
if [ "$(hook_run 'rm ${HOME}/foo -rf')" = "2" ]; then
  ok "hook: rm \${HOME}/foo -rf (flag after operand) blocked (#277)"
else
  ng "hook: operand-before-flag rm bypassed the out-of-scope block (#277)"
fi

# 15g (#277): the same permutation for mv (out-of-scope source) → blocked.
if [ "$(hook_run 'mv ${HOME}/a ${HOME}/b --force')" = "2" ]; then
  ok "hook: mv \${HOME}/a \${HOME}/b --force (flag last) blocked (#277)"
else
  ng "hook: operand-before-flag mv bypassed the out-of-scope block (#277)"
fi

# 15h (#277 regression): an IN-SCOPE operand-permutation must still be ALLOWED —
# the fix widens entry, not the scope decision. `./foo` resolves under $TMP/fake
# (registered), so a flag-after-operand rm there is the happy path (rc 0).
if [ "$(hook_run 'rm ./foo -rf')" = "0" ]; then
  ok "hook: rm ./foo -rf (in-scope, flag after operand) allowed (#277 regression)"
else
  ng "hook: in-scope operand-permutation rm wrongly blocked (#277 regression)"
fi

# 15i (#277): a flag belonging to ANOTHER pipeline command must NOT trigger the
# rm arm (the #212 cross-command anchoring invariant). `rm ./ok && ls -rf` — the
# -rf is ls's; rm has no force flag and an in-scope operand → allow (rc 0).
if [ "$(hook_run 'rm ./ok && ls -rf .')" = "0" ]; then
  ok "hook: rm ./ok && ls -rf . — ls's flag does not trigger rm arm (#277/#212)"
else
  ng "hook: cross-command flag wrongly attributed to rm (#277/#212)"
fi

# 15c. Benign eval — NOT blocked (exit 0) and audit-warn entry written.
# Uses `eval "ls"` so no downstream matcher fires; bypass-suspect should
# NOT short-circuit downstream matchers, so we test with a clean inner
# command. (`eval "git push --force"` should still BLOCK — covered by
# the regression in 15d's spirit: downstream matchers stay active.)
REAL_AUDIT="$SMOKE_AUDIT"
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

# 15f-15j (#375): bypass-suspect heredoc warn is scoped to *shell-spawning*
# heredocs (SPEC §6.1, "heredoc-spawned shells (bash <<EOF)"). Pre-#375 the
# matcher warned on ANY heredoc opener; benign data heredocs (cat/wc, incl. a
# `.sh` filename used as an OPERAND) must NOT trip it, while `bash <<EOF` and
# `env bash <<EOF` still must. Helper: does running <cmd> add a bypass-suspect
# audit line?
bypass_warns() {
  local cmd="$1" b a d
  b=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$b" ] && b=0
  hook_run "$cmd" >/dev/null
  a=$(wc -l < "$REAL_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$a" ] && a=0
  d=$((a - b))
  [ "$d" -ge 1 ] && tail -n "$d" "$REAL_AUDIT" 2>/dev/null | grep -q 'bypass-suspect'
}
# Benign data heredocs — must NOT warn (RED on the pre-#375 broad regex).
if ! bypass_warns 'cat <<EOF
hello
EOF'; then
  ok "15f: benign 'cat <<EOF' does not trip bypass-suspect (#375)"
else
  ng "15f: 'cat <<EOF' over-warns bypass-suspect (heredoc scope too broad) (#375)"
fi
if ! bypass_warns 'cat foo.sh <<EOF
x
EOF'; then
  ok "15g: 'cat foo.sh <<EOF' (.sh operand) does not trip bypass-suspect (#375)"
else
  ng "15g: '.sh' filename operand false-trips bypass-suspect (#375)"
fi
if ! bypass_warns 'wc -l <<EOF
x
EOF'; then
  ok "15h: benign 'wc -l <<EOF' does not trip bypass-suspect (#375)"
else
  ng "15h: 'wc -l <<EOF' over-warns bypass-suspect (#375)"
fi
# Shell-spawning heredocs — must STILL warn.
if bypass_warns 'bash <<EOF
echo hi
EOF'; then
  ok "15i: 'bash <<EOF' still warns bypass-suspect (shell-spawning) (#375)"
else
  ng "15i: 'bash <<EOF' no longer warns — under-warns shell-spawning heredoc (#375)"
fi
if bypass_warns 'env bash <<EOF
echo hi
EOF'; then
  ok "15j: 'env bash <<EOF' still warns bypass-suspect (env-wrapped shell) (#375)"
else
  ng "15j: 'env bash <<EOF' no longer warns (#375)"
fi

rm -rf "$HOOK_TMP"

# ---------- 15s (#375): /sync-pr Stop-arm detection (SPEC §6.3 second arm) ----------
# The Stop hook's second arm nudges /sync-pr when HEAD advanced past the last
# /sync-pr (cached last_synced_head != git rev-parse HEAD). The detection unit
# is the new pr_cache_head reader + a head comparison; stop.sh wires it behind
# current_pr_number + the modulo throttle (the gh/in_scope/throttle gating is
# exercised structurally below, not end-to-end — it cannot fire in the unregistered
# fake repo without gh). pr_cache_head does not exist pre-#375 → these go RED.
S15S_DIR="$TMP/syncpr"
mkdir -p "$S15S_DIR"
# commit.gpgsign=false guards against a developer's global gpgsign=true, which
# would fail the test identity's signing and leave HEAD unborn (#375).
S15S_GIT=(git -c commit.gpgsign=false -c user.email=t@t -c user.name=t)
(
  cd "$S15S_DIR" || exit 1
  git init -q .
  "${S15S_GIT[@]}" commit -q --allow-empty -m seed
) >/dev/null 2>&1
# shellcheck disable=SC1091
. "$SHELL_ROOT/.claude/hooks/helpers/pr_cache.sh"
export PR_CACHE_DIR="$S15S_DIR/cache" PR_CACHE_REPO="test/repo"
old_head=$(cd "$S15S_DIR" && git rev-parse HEAD)
pr_cache_write 7 deadbeefsha "$old_head"
# §15s-a: pr_cache_head reads back the written head.
if [ "$(pr_cache_head 7)" = "$old_head" ]; then
  ok "15s-a: pr_cache_head returns the cached last_synced_head (#375)"
else
  ng "15s-a: pr_cache_head missing or wrong (got '$(pr_cache_head 7)') (#375)"
fi
# §15s-b: in-sync — cached head == current HEAD → NOT out of sync.
cur_head=$(cd "$S15S_DIR" && git rev-parse HEAD)
if [ "$(pr_cache_head 7)" = "$cur_head" ]; then
  ok "15s-b: HEAD unchanged since sync → no /sync-pr nudge condition (#375)"
else
  ng "15s-b: in-sync HEAD wrongly differs from cached (#375)"
fi
# §15s-c: out-of-sync — advance HEAD, cached head now differs → nudge condition.
(cd "$S15S_DIR" && "${S15S_GIT[@]}" commit -q --allow-empty -m next) >/dev/null 2>&1
new_head=$(cd "$S15S_DIR" && git rev-parse HEAD)
if [ "$(pr_cache_head 7)" != "$new_head" ]; then
  ok "15s-c: commit since last /sync-pr → out-of-sync condition holds (#375)"
else
  ng "15s-c: out-of-sync not detected after a new commit (#375)"
fi
unset PR_CACHE_DIR PR_CACHE_REPO
# §15s-d: stop.sh wires the arm (current_pr_number + pr_cache_head + /sync-pr nudge).
if grep -q 'pr_cache_head' "$SHELL_ROOT/.claude/hooks/stop.sh" \
   && grep -q 'current_pr_number' "$SHELL_ROOT/.claude/hooks/stop.sh" \
   && grep -q '/sync-pr' "$SHELL_ROOT/.claude/hooks/stop.sh"; then
  ok "15s-d: stop.sh wires the /sync-pr arm (current_pr_number + pr_cache_head) (#375)"
else
  ng "15s-d: stop.sh missing the /sync-pr arm wiring (#375)"
fi
# §15s-e (#554/D1): a non-numeric GHJIG_STOP_THROTTLE must NOT abort the hook.
# stop.sh runs under `set -u`; an unsanitized value in the modulo arithmetic
# (throttle line) is an unbound-variable error that kills the hook — silently
# dropping the /review + /sync-pr advisories (0 would divide-by-zero the same
# way). The var is now sanitized (empty/0/non-numeric → default 5). Runs stop.sh
# IN-SCOPE (physical-resolved cwd in the registry, so the throttle line is
# actually reached) with a garbage throttle; a clean exit is the signal — a
# pre-fix set -u abort exits non-zero.
S15E_STATE=$(mktemp -d); S15E_CWD=$(cd "$(mktemp -d)" && pwd -P)
printf '%s\n' "$S15E_CWD" > "$S15E_STATE/registry.txt"
if ( cd "$S15E_CWD" || exit 1
     GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" GHJIG_STATE_DIR_OVERRIDE="$S15E_STATE" \
     GHJIG_STOP_THROTTLE='not-a-number' \
       bash "$SHELL_ROOT/.claude/hooks/stop.sh" </dev/null >/dev/null 2>&1 ); then
  ok "15s-e: non-numeric GHJIG_STOP_THROTTLE does not abort stop.sh (#554)"
else
  ng "15s-e: non-numeric GHJIG_STOP_THROTTLE aborted stop.sh (set -u / div-by-zero) (#554)"
fi
rm -rf "$S15E_STATE" "$S15E_CWD"

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

# 16e (#367): single -m with embedded newlines — extract the FIRST LINE only,
# from the raw command (normalization flattens newlines, so the old whole-blob
# parse over-length-blocked). Valid first line + long body → ALLOW. (RED pre-fix.)
ml_valid=$(printf '%s\n' \
  'git commit -m "feat(#1): valid first line' \
  '' \
  'this is a very long body paragraph that exceeds seventy-two codepoints so the old whole-blob extraction would have wrongly length-blocked this commit"')
exit_code=$(hook_run "$ml_valid")
if [ "$exit_code" = "0" ]; then
  ok "16e: single -m embedded-newline — first line extracted, not blocked (#367)"
else
  ng "16e: single -m embedded-newline wrongly blocked (whole-blob), exit=$exit_code (#367)"
fi

# 16f (#367): single -m embedded newlines, MALFORMED first line → still BLOCK.
# Safety guard: the fix must extract+reject a bad first line, never false-empty.
ml_bad=$(printf '%s\n' \
  'git commit -m "broken first line not a conventional commit' \
  '' \
  'body"')
exit_code=$(hook_run "$ml_bad")
if [ "$exit_code" = "2" ]; then
  ok "16f: single -m embedded-newline malformed first line still blocks (#367)"
else
  ng "16f: malformed first line slipped (false-empty?), exit=$exit_code (#367)"
fi

# 16g (#367): multiple -m — take the FIRST value, not the greedy last. First
# valid + long non-CC second body → ALLOW. (RED pre-fix: greedy-last grabbed the
# long body → length/format block.)
mm_valid='git commit -m "feat(#1): first wins" -m "this is a long second paragraph body that is not a conventional commit subject and would exceed the limit"'
exit_code=$(hook_run "$mm_valid")
if [ "$exit_code" = "0" ]; then
  ok "16g: multiple -m — first value extracted, not blocked (#367)"
else
  ng "16g: multiple -m wrongly blocked (greedy-last), exit=$exit_code (#367)"
fi

# 16h (#367): multiple -m, MALFORMED first → BLOCK. (RED pre-fix: greedy-last
# grabbed the valid-looking SECOND -m → wrongly ALLOWED a malformed-first commit
# — a false-negative the first-value fix closes.)
mm_bad='git commit -m "not a conventional first subject" -m "feat(#1): valid-looking second"'
exit_code=$(hook_run "$mm_bad")
if [ "$exit_code" = "2" ]; then
  ok "16h: multiple -m — malformed first value blocks, not the valid second (#367)"
else
  ng "16h: multiple -m malformed first slipped via greedy-last, exit=$exit_code (#367)"
fi

# 16i (#367): sibling heredoc in a compound command — a `cat > file <<EOF` redirect
# preceding the commit must NOT be read as the subject. The commit uses -F → empty
# → fail-open → ALLOW. (RED pre-fix: the heredoc walk grabbed the changelog bullet.)
sib=$(printf '%s\n' \
  "cat > changelog.md <<'EOF'" \
  "- a changelog bullet that is not a conventional commit subject" \
  "EOF" \
  "git commit -F /tmp/msg.txt")
exit_code=$(hook_run "$sib")
if [ "$exit_code" = "0" ]; then
  ok "16i: sibling heredoc not mistaken for the commit subject (#367)"
else
  ng "16i: sibling heredoc grabbed as subject, exit=$exit_code (#367)"
fi

# 16j (#367): `git commit -F <file>` standalone — no inline message → empty
# extraction → format check skipped (fail-open) → ALLOW.
fonly='git commit -F /tmp/msg.txt'
exit_code=$(hook_run "$fonly")
if [ "$exit_code" = "0" ]; then
  ok "16j: -F-only commit extracts empty, format check skipped (fail-open) (#367)"
else
  ng "16j: -F-only commit wrongly blocked, exit=$exit_code (#367)"
fi

# 16k (#383): single -m, valid line-1 subject, body merely MENTIONS a `<<EOF`
# token as prose → must ALLOW (line-1 precedence). RED pre-fix: the heredoc
# detector fires on the body `<<EOF` and returns a prose body line as the
# "subject", which fails the CC regex and wrongly blocks.
fb_prose=$(printf '%s\n' \
  'git commit -m "fix(#1): scope bypass-suspect to shell-spawning heredocs' \
  '' \
  'the matcher now requires bash <<EOF style openers; cat foo.sh <<EOF stays benign"')
exit_code=$(hook_run "$fb_prose")
if [ "$exit_code" = "0" ]; then
  ok "16k: valid line-1 + body <<EOF prose not mistaken for a heredoc message (#383)"
else
  ng "16k: body <<EOF prose wrongly triggers heredoc extraction → blocked, exit=$exit_code (#383)"
fi

# 16l (#383): the GENUINE `-m "$(cat <<'EOF' ... EOF)"` substitution form with a
# valid subject must STILL extract the heredoc-body subject and ALLOW — line-1
# precedence must not short-circuit it (line-1 there is the `$(cat <<'EOF'`
# opener, which is not a valid CC subject, so it correctly falls through).
gen_heredoc=$(printf '%s\n' \
  "git commit -m \"\$(cat <<'EOF'" \
  "fix(#1): genuine heredoc subject" \
  "" \
  "body line" \
  "EOF" \
  ")\"")
exit_code=$(hook_run "$gen_heredoc")
if [ "$exit_code" = "0" ]; then
  ok "16l: genuine heredoc substitution form still extracts subject (no regression) (#383)"
else
  ng "16l: genuine heredoc form wrongly blocked by line-1 precedence, exit=$exit_code (#383)"
fi

# 16m (#383): MALFORMED line-1 + body `<<EOF` prose → must STILL BLOCK (fail-safe).
# line-1 is not a valid CC subject, so line-1 precedence does NOT short-circuit;
# the extractor falls through and the gate still blocks the malformed subject.
fb_bad=$(printf '%s\n' \
  'git commit -m "broken subject not conventional' \
  '' \
  'body with a bash <<EOF prose token"')
exit_code=$(hook_run "$fb_bad")
if [ "$exit_code" = "2" ]; then
  ok "16m: malformed line-1 with <<EOF prose still blocks (fail-safe) (#383)"
else
  ng "16m: malformed line-1 with <<EOF prose should still block, exit=$exit_code (#383)"
fi

# 16n (#383): the legacy awk fallback (python3 absent) honors line-1 precedence
# too — parity with the python primary. Build a curated PATH carrying the
# coreutils the fallback needs but WITHOUT python3 (so `command -v python3` is
# false and _codepoint_len uses `wc -m`), then call extract_commit_subject
# directly on the body-<<EOF-prose case and assert it returns line-1. An ASCII
# subject keeps the wc -m length check locale-robust on CI.
S16N_BIN="$TMP/nopy3-bin"; mkdir -p "$S16N_BIN"
for t in sed awk grep head tr wc cat; do
  s16n_src=$(command -v "$t" 2>/dev/null) && ln -sf "$s16n_src" "$S16N_BIN/$t"
done
if (
    . "$SHELL_ROOT/.claude/hooks/helpers/conventional_commit.sh"
    raw16n=$(printf '%s\n' 'git commit -m "fix(#1): valid line-1 subject' '' 'body mentioning bash <<EOF prose"')
    norm16n=$(printf '%s' "$raw16n" | tr '\n' ' ')
    export PATH="$S16N_BIN"
    command -v python3 >/dev/null 2>&1 && exit 3   # guard: python3 must be absent for this to test the awk path
    out16n=$(extract_commit_subject "$raw16n" "$norm16n")
    [ "$out16n" = "fix(#1): valid line-1 subject" ]
  ); then
  ok "16n: awk fallback (no python3) honors line-1 precedence — parity (#383)"
else
  ng "16n: awk fallback mis-extracts body <<EOF prose without python3 (rc=$?) (#383)"
fi

# 16o (#554/D2): the wc -m codepoint fallback (python3 absent) is locale-robust.
# A hardcoded LC_ALL=en_US.UTF-8 is absent on many minimal Linux hosts; libc
# then silently falls to the C locale and `wc -m` counts BYTES — over-counting a
# multibyte subject and false-rejecting the 1..72 codepoint bound. The fallback
# now selects a UTF-8 locale the host actually provides, so an ambient LC_ALL=C
# does not collapse it to a byte count. Hide python3 (force the wc path) + add
# `locale` to the curated PATH so the detection branch runs. Guarded on a UTF-8
# locale actually existing (the fix cannot conjure one on a locale-less host).
s16o_loc=$(command -v locale 2>/dev/null) && ln -sf "$s16o_loc" "$S16N_BIN/locale"
# here-string, not `| grep -q`: under `set -o pipefail` grep -q's early pipe
# close SIGPIPEs `locale -a` → nonzero pipeline even on a match (the documented
# smoke SIGPIPE trap), which would wrongly skip this test on every host.
s16o_avail=$(locale -a 2>/dev/null || true)
if command -v locale >/dev/null 2>&1 && grep -qiE '^(C|en_US)\.(UTF-8|utf8)$' <<<"$s16o_avail"; then
  if (
      . "$SHELL_ROOT/.claude/hooks/helpers/conventional_commit.sh"
      export PATH="$S16N_BIN" LC_ALL=C LANG=C
      command -v python3 >/dev/null 2>&1 && exit 3   # guard: python3 must be absent
      len=$(_codepoint_len "가나다")                 # 3 codepoints, 9 UTF-8 bytes
      [ "$len" = 3 ]
    ); then
    ok "16o: wc -m codepoint fallback stays codepoint-correct under ambient LC_ALL=C (#554)"
  else
    ng "16o: wc -m fallback byte-counted a multibyte subject under LC_ALL=C (rc=$?) (#554)"
  fi
else
  ok "16o: no UTF-8 locale on host — codepoint-fallback locale test skipped (#554)"
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

# ---- §503a-e (#503 / Directive #498): GIT_PREFIX must tolerate an UNLISTED
# leading git global flag, else the verb match fails and the push isn't gated.
# `--no-lazy-fetch` (git 2.38+) is a real global flag absent from the allowlist.
# Uses the §37 hook_run harness (live $TMP/fake, non-protected branch).
[ "$(hook_run 'git --no-lazy-fetch push origin main')" = "2" ] \
  && ok "503a: unlisted global flag (--no-lazy-fetch) before push → protected-push still blocked (#503)" \
  || ng "503a: --no-lazy-fetch bypassed protected-push (GIT_PREFIX allowlist gap) (#503)"
[ "$(hook_run 'git --no-lazy-fetch push --force origin main')" = "2" ] \
  && ok "503b: unlisted global flag before a force-push to protected → still blocked (#503)" \
  || ng "503b: --no-lazy-fetch bypassed force-push to protected (#503)"
# 503c (no-regression): a LISTED value-flag (`-c <kv>`) still consumes its value
# and the protected-push still fires (the broadening must not break value-flags).
[ "$(hook_run 'git -c http.proxy=x push origin main')" = "2" ] \
  && ok "503c: listed value-flag (-c <kv>) before push still blocked (no regression) (#503)" \
  || ng "503c: -c value-flag form regressed (#503)"
# 503d (no over-block): an unlisted global flag before a push to a NON-protected
# branch is still allowed.
[ "$(hook_run 'git --no-lazy-fetch push origin feature')" = "0" ] \
  && ok "503d: --no-lazy-fetch push to non-protected branch still allowed (no over-block) (#503)" \
  || ng "503d: --no-lazy-fetch push to non-protected wrongly blocked (#503)"
# 503e (documented residual): the `-c alias.<x>=<verb>` rename bypass (invoking a
# gated verb under an alias name) is contrived and not closed; SPEC §6.1 must
# name it as an explicit residual so it isn't a silent gap. Source-grep.
if grep -qiE 'alias[^`]{0,40}(bypass|residual|rename)|-c alias' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "503e: SPEC §6.1 documents the '-c alias.<x>=<verb>' bypass as a residual (#503)"
else
  ng "503e: SPEC does not document the -c alias rename bypass residual (#503)"
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

# ---------- §555 cluster A (#555 / Directive #550): matcher bypass/false-block ----------
# A3: `mv -- <src> <out-of-registry>` — the POSIX `--` end-of-options guard must
# NOT let a destructive mv/cp evade BOTH entry arms. Pre-fix the flagless arm saw
# the `--` right after `mv ` and bailed; the flag-keyed arm needs a force flag.
if [ "$(hook_run 'mv -- /etc/ce-probe /etc/ce-out')" = "2" ]; then
  ok "555a3: 'mv -- <src> <out-of-registry>' still enters destructive gate → blocked (#555)"
else
  ng "555a3: 'mv --' evaded both destructive arms (bypass) (#555)"
fi
# A3 no over-block: `mv -- <in-scope> <in-scope>` still passes (`./ok` under $TMP/fake).
if [ "$(hook_run 'mv -- ./ok ./ok2')" = "0" ]; then
  ok "555a3: 'mv -- <in-scope> <in-scope>' still allowed (no over-block) (#555)"
else
  ng "555a3: in-scope 'mv --' wrongly blocked (#555)"
fi
# A4: a BUNDLED short force `git push -uf` (bare, no target) must hit the
# irreversible force-push fail-safe. Pre-fix `-uf` carried no isolated `-f\b`
# token → the force arm never entered and the bare force slipped past.
if [ "$(hook_run 'git push -uf')" = "2" ]; then
  ok "555a4: bare bundled-short force 'git push -uf' → blocked (#555)"
else
  ng "555a4: 'git push -uf' bare force slipped past the fail-safe (#555)"
fi
# A4 (reordered cluster) — `-fu` bare force also blocked.
if [ "$(hook_run 'git push -fu')" = "2" ]; then
  ok "555a4: bare bundled-short force 'git push -fu' → blocked (#555)"
else
  ng "555a4: 'git push -fu' bare force slipped past (#555)"
fi
# A4 no over-block: a branch NAME containing '-f' (`my-feature`) is NOT a force
# flag → a non-protected push of it stays allowed (the token-start anchor guard).
if [ "$(hook_run 'git push -u my-feature')" = "0" ]; then
  ok "555a4: branch name containing '-f' not misread as force (no over-block) (#555)"
else
  ng "555a4: branch name with '-f' wrongly treated as force-push (#555)"
fi
# A2: a `git reset --hard` / `git clean -f` mentioned only inside a -m/-F commit
# MESSAGE value is DATA, not a command → the destructive arm must NOT false-block
# it. Pre-fix the reset arm grepped the un-elided cmd; the clean arm heredoc-only.
if [ "$(hook_run 'git commit -m "docs(#1): note git reset --hard usage"')" = "0" ]; then
  ok "555a2: 'git reset --hard' inside a commit message no longer false-blocks (#555)"
else
  ng "555a2: commit message mentioning 'git reset --hard' still false-blocked (#555)"
fi
if [ "$(hook_run 'git commit -m "docs(#1): run git clean -fd to reset"')" = "0" ]; then
  ok "555a2: 'git clean -fd' inside a commit message no longer false-blocks (#555)"
else
  ng "555a2: commit message mentioning 'git clean -fd' still false-blocked (#555)"
fi
# A2 regression: a REAL reset/clean invocation still blocks (message-strip never
# removes a genuine command verb).
if [ "$(hook_run 'git reset --hard')" = "2" ]; then
  ok "555a2: real 'git reset --hard' still blocked (regression) (#555)"
else
  ng "555a2: real 'git reset --hard' no longer blocked (#555)"
fi
if [ "$(hook_run 'git clean -fd')" = "2" ]; then
  ok "555a2: real 'git clean -fd' still blocked (regression) (#555)"
else
  ng "555a2: real 'git clean -fd' no longer blocked (#555)"
fi
# A5: an OPERAND literally named `env` (or rm|mv|cp|sudo|doas|time) must still be
# scope-checked — pre-fix check_destructive_args skipped ANY token equal to those
# words regardless of position, so a non-command-position `env` skipped
# path_in_scope entirely. cwd stays $TMP/fake (registered, so the hook's in_scope
# gate is satisfied); an `env` SYMLINK pointing at the UNREGISTERED $TMP makes the
# `env` operand resolve out of scope. Pre-fix `env` is skipped → allow; post-fix
# it is scope-checked → block. The symlink isolates the skipped-operand as the
# sole out-of-scope arg (the source stays in scope).
ln -s "$TMP" "$TMP/fake/env" 2>/dev/null
if [ "$(hook_run "mv $TMP/fake/README.md env")" = "2" ]; then
  ok "555a5: non-command-position operand 'env' is scope-checked → blocked (#555)"
else
  ng "555a5: operand named 'env' skipped path_in_scope (bypass) (#555)"
fi
rm -f "$TMP/fake/env"
# A5 no over-block: a COMMAND-position wrapper (`sudo rm -rf <in-scope>`) still
# skips the wrapper/verb words and passes for an in-scope operand.
if [ "$(hook_run 'sudo rm -rf ./ok')" = "0" ]; then
  ok "555a5: 'sudo rm -rf <in-scope>' still allowed (wrapper/verb skip preserved) (#555)"
else
  ng "555a5: command-position wrapper/verb skip regressed (#555)"
fi

# ---------- 23. SKIP_HOOKS escape parsing (#38, #206) ----------
# SPEC §7 escape has TWO forms. §23a-f cover the LEADING env-prefix form,
# which only works where the prefix arrives INSIDE the command string —
# hook_run embeds it in tool_input.command via `jq -Rs`, modeling a real
# shell / verbatim delivery. CAVEAT (#206): the LIVE Claude Code Bash tool
# consumes a leading `VAR=val` as the subprocess env, so it never reaches
# tool_input.command — the leading form is dead in-harness. §23g-k (below)
# cover the TRAILING sentinel `# ghjig:skip=<cat> reason=<why>`, which
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
# (destructive) blocks today; with a trailing `# ghjig:skip=destructive
# reason=...` sentinel IN the command (which is how it arrives in-harness AND
# in hook_run) it is allowed + an escape audit record is written.
before=$(audit_lines); [ -z "$before" ] && before=0
rc=$(hook_run 'git reset --hard  # ghjig:skip=destructive reason=in-harness-escape')
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
rc=$(hook_run 'git reset --hard  # ghjig:skip=destructive reason=mentions git push --force origin main')
if [ "$rc" = "0" ]; then
  ok "skip: sentinel reason text does not bleed into other matchers (#206)"
else
  ng "skip: sentinel reason bled into a matcher (rc=$rc) (#206)"
fi

# 23j (#206): a plain (non-namespaced) trailing comment is NOT an escape — the
# sentinel must carry the `ghjig:skip=` namespace, else a normal comment
# could silently disable a guardrail.
rc=$(hook_run 'git reset --hard  # just a normal comment, not an escape')
if [ "$rc" = "2" ]; then
  ok "skip: plain trailing comment is not treated as an escape (#206)"
else
  ng "skip: plain comment wrongly skipped a matcher (rc=$rc) (#206)"
fi

# 23k (#206): SECURITY — a line-1 sentinel must NOT skip a dangerous command on
# a LATER line. bash `[[ =~ ]]` matches newlines, so a naive newline-spanning
# regex would let `echo ok # ghjig:skip=destructive reason=x\n<danger>`
# greedily capture+strip the danger line before matchers, executing it under a
# falsified audit category. The single-trailing-line sentinel must reject this
# (no escape) → the command falls through to the matcher and BLOCKS.
rc=$(hook_run "$(printf 'echo ok  # ghjig:skip=destructive reason=probe\ngit reset --hard')")
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
rc=$(hook_run "$(printf 'git reset --hard\necho ok  # ghjig:skip=out-of-scope reason=wrong-category')")
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
rc=$(hook_run 'git reset --hard "note # ghjig:skip=destructive reason=x"')
if [ "$rc" = "2" ]; then
  ok "skip: sentinel inside a quoted argument is not an escape (#208)"
else
  ng "skip: quoted-arg sentinel wrongly disarmed a matcher (rc=$rc) (#208)"
fi

# 23o (#208): REGRESSION GUARD — a GENUINE trailing-comment sentinel that follows
# an earlier quoted argument must still be honored. Guards against an over-strict
# fix that rejects the sentinel whenever any quote precedes the `#`.
before=$(audit_lines); [ -z "$before" ] && before=0
rc=$(hook_run 'git reset --hard "safe label"  # ghjig:skip=destructive reason=genuine')
after=$(audit_lines); [ -z "$after" ] && after=0
delta=$((after - before))
if [ "$rc" = "0" ] && [ "$delta" -ge 1 ] \
   && tail -n "$delta" "$REAL_AUDIT" 2>/dev/null | grep -q '"category":"destructive"'; then
  ok "skip: genuine trailing-comment sentinel after a quoted arg still honored (#208)"
else
  ng "skip: genuine sentinel after quoted arg not honored (rc=$rc, delta=$delta) (#208)"
fi

# 23p (#208 security review): ANSI-C $(...) quoting must not reopen the bypass.
# In `<cmd> $'x\' # ghjig:skip=all reason=y'` the `\'` is an ESCAPED quote,
# so bash keeps the string open and the `#` is argument text, not a comment — the
# command runs intact and must STILL BLOCK. A naive single-quote scan would
# mis-close at `\'` and wrongly honor the sentinel.
rc=$(hook_run "git reset --hard \$'x\\' # ghjig:skip=all reason=y'")
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
rc=$(hook_run "$(printf 'git reset --hard\n# ghjig:skip=destructive reason=newline-boundary')")
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
      | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
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

# §555 A7 (#555 / Directive #550): is_protected_branch must recognize a
# protected branch NAME case-insensitively, for parity with the force-push arm's
# `grep -qiE`. On a case-insensitive filesystem `Main`/`MASTER` resolve to the
# same ref as `main`/`master`; a case-sensitive test left the edit/commit gates
# blind to those checkouts. Pre-fix these return non-zero (unprotected).
is_protected_branch Main    && ok "555a7: is_protected_branch recognizes 'Main' (case-insensitive) (#555)"   || ng "555a7: 'Main' not recognized as protected — case-sensitive (#555)"
is_protected_branch MASTER  && ok "555a7: is_protected_branch recognizes 'MASTER' (case-insensitive) (#555)" || ng "555a7: 'MASTER' not recognized as protected — case-sensitive (#555)"
# A7 no over-block: a genuinely-unprotected branch name is still unprotected.
if is_protected_branch feature-x; then
  ng "555a7: unprotected branch 'feature-x' wrongly treated as protected (#555)"
else
  ok "555a7: unprotected branch 'feature-x' still unprotected (no over-block) (#555)"
fi

# ---------- 20. audit_log JSONL safety (#26) ----------
# audit_log must produce one valid JSON object per line regardless of the
# `reason` contents — including newlines, tabs, carriage returns.

AUDIT_TMP=$(mktemp -d)
mkdir -p "$AUDIT_TMP/.claude/audit"
(
  export GHJIG_ROOT="$AUDIT_TMP"; unset GHJIG_STATE_DIR_OVERRIDE  # #357: §20 tests the GHJIG_ROOT legacy path
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
  export GHJIG_ROOT="$AUDIT_TMP"; unset GHJIG_STATE_DIR_OVERRIDE  # #357: §20 tests the GHJIG_ROOT legacy path
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

# 20d (#554/D3): the legacy-path fallback (hookrt.sh) references GHJIG_ROOT. With
# no per-project state dir AND GHJIG_ROOT unset, a bare `$GHJIG_ROOT` is a `set -u`
# unbound-variable hard abort for a future non-hook/non-CLI caller. It now uses
# `${GHJIG_ROOT:-}`. Under set -u with all state vars unset, audit_log must not
# emit an 'unbound variable' abort (the write itself may fail — that is fine;
# the signal is the absence of the set -u crash).
d3err=$(
  . "$SHELL_ROOT/.claude/hooks/helpers/log.sh" 2>/dev/null
  unset GHJIG_ROOT GHJIG_STATE_DIR_OVERRIDE CLAUDE_PROJECT_DIR
  set -u
  audit_log warn registry-zeroed notice "d3 set-u probe" 2>&1 >/dev/null
)
if printf '%s' "$d3err" | grep -qi 'unbound variable'; then
  ng "20d: audit_log legacy path set -u aborts on unset GHJIG_ROOT (#554)"
else
  ok "20d: audit_log legacy path is set -u-safe on unset GHJIG_ROOT (#554)"
fi
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
  export GHJIG_ROOT="$SHELL_ROOT"
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
  export GHJIG_ROOT="$SHELL_ROOT"
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
  export GHJIG_ROOT="$SHELL_ROOT"
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
  export GHJIG_ROOT="$SHELL_ROOT"
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
    export GHJIG_ROOT_OVERRIDE="$SESS_FAKE_ROOT"
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
  export GHJIG_ROOT="$SHELL_ROOT"
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
  export GHJIG_ROOT="$SHELL_ROOT"
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

# ---------- 79. /file-issue priority capture (#291) ----------
# /file-issue must capture a P0-P3 priority (parity with /file-directive) so
# eng-mode issues don't land priority-less: ask in attended, default P2 in
# unattended, apply the P<N> label graceful-degradation-guarded, and state the
# contract in SPEC §5.2.
FILE_ISSUE_79="$SHELL_ROOT/.claude/commands/file-issue.md"
if [ -f "$FILE_ISSUE_79" ] \
   && grep -qiE 'priority' "$FILE_ISSUE_79" \
   && grep -qE 'P0\|P1\|P2\|P3|P0` / `P1` / `P2` / `P3|P0`/`P1`/`P2`/`P3' "$FILE_ISSUE_79" \
   && grep -qiE 'default.*\bP2\b' "$FILE_ISSUE_79" \
   && grep -qiE 'graceful-degradation|absent on target' "$FILE_ISSUE_79"; then
  ok "79a: /file-issue captures priority (P0-P3, unattended default P2, degradation-guarded) (#291)"
else
  ng "79a: /file-issue.md missing the priority-capture contract (#291)"
fi
# 79b: SPEC §5.2 documents the /file-issue priority contract.
if grep -qE '\*\*Priority\*\* \(#291' "$SHELL_ROOT/SPEC.md" \
   && grep -qiE 'never lands priority-less|priority-less backlog' "$SHELL_ROOT/SPEC.md"; then
  ok "79b: SPEC §5.2 states the /file-issue priority-capture contract (#291)"
else
  ng "79b: SPEC §5.2 missing the /file-issue priority contract (#291)"
fi

# ---------- 80. stage-0 /bootstrap-repo (#307, Directive #306) ----------
# Stage-0 bootstrap owns the no-default-branch starting state (empty repo /
# unborn HEAD). The protected-branch gate is NAME-based, so on an unborn HEAD
# (`git symbolic-ref --short HEAD` → main while `rev-parse --verify HEAD`
# fails) the seed commit is blocked — correct general behavior. /bootstrap-repo
# owns a single, scoped, audit-logged bypass for that seed commit via the
# `branch` escape. These assertions pin BOTH halves: the gate stays intact for a
# plain unborn-HEAD commit, AND the bootstrap sentinel is honored — plus the
# command file carrying the exact sentinel string (the implementation contract).

# Run the hook in an arbitrary cwd; echo its exit code (2=block, 0=allow).
s80_hook() {
  # $1 = dir, $2 = command string
  ( cd "$1" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$2" | jq -Rs .)" \
      | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
    printf '%s' "$?" )
}

# Fresh repo with an UNBORN HEAD on `main` — no commit, so HEAD is unborn and
# `git symbolic-ref --short HEAD` reports `main` (the stage-0 starting state).
# The repo is REGISTERED (physical-resolved, like §5b): the hook short-circuits
# (`in_scope || exit 0`) outside the registry, and a real target IS registered
# (clone-into / register) before stage-0 runs — so the gate must be exercised
# inside the registry, exactly as /bootstrap-repo encounters it.
S80_REPO=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S80_REPO" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }) ) || true
printf '%s\n' "$S80_REPO" >> "$SMOKE_REG"
s80_branch=$(cd "$S80_REPO" && git symbolic-ref --short HEAD 2>/dev/null)
s80_unborn=$(cd "$S80_REPO" && git rev-parse --verify HEAD 2>/dev/null || printf 'unborn')

# 80a: fixture sanity — unborn HEAD reporting a protected name (`main`).
if [ "$s80_branch" = main ] && [ "$s80_unborn" = unborn ]; then
  ok "80a: stage-0 fixture is an unborn HEAD on protected name 'main' (#307)"
else
  ng "80a: stage-0 fixture not unborn-on-main (branch='$s80_branch' head='$s80_unborn') (#307)"
fi

# 80b: gate intact — a plain seed commit on the unborn-HEAD `main` is BLOCKED.
if [ "$(s80_hook "$S80_REPO" 'git commit -m "chore: seed first commit (MISSION + README)"')" = "2" ]; then
  ok "80b: plain unborn-HEAD commit blocked — name-based gate intact (#307)"
else
  ng "80b: plain unborn-HEAD commit should be blocked by the protected-branch gate (#307)"
fi

# 80c: bootstrap exception — the SAME commit carrying the stage-0 trailing
# sentinel is ALLOWED (and routes through should_skip, i.e. audit-logged).
s80_seed='git commit -m "chore: seed first commit (MISSION + README)"  # ghjig:skip=branch reason=stage-0-bootstrap-seed-on-unborn-HEAD'
if [ "$(s80_hook "$S80_REPO" "$s80_seed")" = "0" ]; then
  ok "80c: unborn-HEAD seed commit with bootstrap sentinel allowed (#307)"
else
  ng "80c: bootstrap-sentinel seed commit should be allowed via the branch escape (#307)"
fi

# Unregister the fixture and remove it.
s80_tmp=$(mktemp); grep -vxF "$S80_REPO" "$SMOKE_REG" > "$s80_tmp" 2>/dev/null || true
mv "$s80_tmp" "$SMOKE_REG"
rm -rf "$S80_REPO"

# 80d: the command file exists with the skill contract AND documents the EXACT
# in-agent seed-escape recipe the §5.0 contract pins. Post-#479 the working
# in-agent escape is the file token (ghjig_skip.sh), NOT the trailing sentinel
# (which the live Bash tool strips, #478) — so the pin follows the contract to
# the ghjig_skip.sh seed recipe. (§80c still proves the sentinel works where a
# command arrives verbatim — the smoke harness / a real shell.)
BOOTSTRAP_CMD="$SHELL_ROOT/.claude/commands/bootstrap-repo.md"
if [ -f "$BOOTSTRAP_CMD" ] \
   && grep -qE '^## Procedure' "$BOOTSTRAP_CMD" \
   && grep -qE '^## Forbidden' "$BOOTSTRAP_CMD" \
   && grep -qF "scripts/ghjig_skip.sh branch 'chore: seed first commit (MISSION + README)'" "$BOOTSTRAP_CMD"; then
  ok "80d: /bootstrap-repo command file carries Procedure/Forbidden + exact ghjig_skip seed recipe (#307, #479)"
else
  ng "80d: .claude/commands/bootstrap-repo.md missing skill contract or exact ghjig_skip seed recipe (#307, #479)"
fi

# 80e: SPEC §5.0 defines stage-0 as preceding /onboard and names the exception,
# AND is cross-referenced from BOTH §1.7 (bootstrap path) and §5.1 (/onboard) —
# AC #2 of #307 requires both back-references, not just §5.0's existence.
if grep -qE '^### 5\.0 `/bootstrap-repo`' "$SHELL_ROOT/SPEC.md" \
   && grep -qiE 'stage-0' "$SHELL_ROOT/SPEC.md" \
   && grep -qiE 'bootstrap exception \(target repos\)|first-commit exception.*target|target.*first-commit exception' "$SHELL_ROOT/SPEC.md" \
   && grep -qE 'Stage-0 precedes all of this|stage-0.*§5\.0|/bootstrap-repo \(§5\.0\)' "$SHELL_ROOT/SPEC.md" \
   && grep -qE 'Precedes.*`/bootstrap-repo` \(§5\.0\)|Precedes.*stage-0' "$SHELL_ROOT/SPEC.md"; then
  ok "80e: SPEC §5.0 defines stage-0 + target exception + §1.7/§5.1 cross-refs (#307)"
else
  ng "80e: SPEC §5.0 must define stage-0, the target exception, and be cross-ref'd from §1.7 + §5.1 (#307)"
fi

# 80f: .claude/CLAUDE.md documents the stage-0 exception, and the seed README
# template SSOT exists.
if grep -qiE 'stage-0 exception' "$SHELL_ROOT/.claude/CLAUDE.md" \
   && [ -f "$SHELL_ROOT/.claude/templates/readme_for_target.md" ]; then
  ok "80f: CLAUDE.md documents stage-0 exception + readme_for_target.md template present (#307)"
else
  ng "80f: CLAUDE.md stage-0 exception note or readme_for_target.md template missing (#307)"
fi

# 80g: /onboard stays read-only — no mutating git/gh-write command introduced.
ONBOARD_CMD="$SHELL_ROOT/.claude/commands/onboard.md"
if [ -f "$ONBOARD_CMD" ] \
   && ! grep -qE 'gh (issue|pr) create|git (commit|push|checkout -b)|gh label create' "$ONBOARD_CMD"; then
  ok "80g: /onboard remains read-only (no mutating command) (#307)"
else
  ng "80g: /onboard.md must stay read-only — no mutating command (#307)"
fi

# ---------- 81. workflow YAML loadability (#309) ----------
# A workflow file that fails to PARSE startup-fails on GitHub — every job is
# skipped, the run name shows the file path instead of the declared `name:`,
# and it fires on the raw push event regardless of `on:`. Such a failure is
# invisible unless the workflow is a required check. #309's root cause was a
# bash heredoc whose `EOF` terminator sat at column 0, dedenting out of the
# `run: |` block scalar and breaking YAML for the whole file. This regression
# parses EVERY workflow so a future block-scalar break is caught pre-merge.

# Parse one YAML file. rc 0 = parses, 1 = parse error, 2 = no parser available.
s81_yaml_ok() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
    return $?
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$1" >/dev/null 2>&1
    return $?
  fi
  return 2
}

s81_parser=skip
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  s81_parser=python3
elif command -v ruby >/dev/null 2>&1; then
  s81_parser=ruby
fi

if [ "$s81_parser" = skip ]; then
  # No YAML parser in this environment — the GitHub CI run is the backstop.
  ok "81a: workflow-YAML parse regression skipped — no python3-yaml/ruby parser here (#309)"
else
  s81_bad=""
  for wf in "$SHELL_ROOT"/.github/workflows/*.yml "$SHELL_ROOT"/.github/workflows/*.yaml; do
    [ -e "$wf" ] || continue
    if ! s81_yaml_ok "$wf"; then
      s81_bad="$s81_bad $(basename "$wf")"
    fi
  done
  if [ -z "$s81_bad" ]; then
    ok "81a: every .github/workflows/*.yml parses as YAML (parser=$s81_parser) (#309)"
  else
    ng "81a: workflow YAML failed to parse —$s81_bad (parser=$s81_parser) (#309)"
  fi
fi

# ---------- 82. per-project binding + hook self-location (#312, Directive #311) ----------
# The shell must be resolvable per project WITHOUT any global shell-root
# env: a project-local untracked `.claude/ghjig-root` symlink → canonical root,
# hooks invoked via that symlink self-locate their root from BASH_SOURCE (pwd -P),
# and the injected `settings.local.json` symlinks to `settings.injected.json` whose
# hook commands use ${CLAUDE_PROJECT_DIR}/.claude/ghjig-root/... . The shell's
# OWN settings.json resolves via ${CLAUDE_PROJECT_DIR} (dogfood, §133b).

# 82a: with no shell-root env at all, a hook invoked through the project-local
# ghjig-root symlink self-locates the canonical root and still enforces —
# a protected-branch commit is blocked (rc=2). (Red until the self-location code.)
S82_PROJ=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S82_PROJ" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }) \
    && git commit -q --allow-empty -m init 2>/dev/null ) || true
mkdir -p "$S82_PROJ/.claude"
ln -sfn "$SHELL_ROOT" "$S82_PROJ/.claude/ghjig-root"
printf '%s\n' "$S82_PROJ" >> "$SMOKE_REG"   # in_scope needs it registered

s82_hook_noenv() {
  # $1 = project cwd, $2 = hook path (via the symlink), $3 = command ; echoes rc
  ( cd "$1" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$3" | jq -Rs .)" \
      | env -u GHJIG_ROOT_OVERRIDE -u GHJIG_ROOT bash "$2" >/dev/null 2>&1
    printf '%s' "$?" )
}
s82_rc=$(s82_hook_noenv "$S82_PROJ" "$S82_PROJ/.claude/ghjig-root/.claude/hooks/pre_tool_use.sh" \
  'git commit -m "chore: x"')
if [ "$s82_rc" = "2" ]; then
  ok "82a: env-unset hook via ghjig-root symlink self-locates + enforces (protected commit blocked) (#312)"
else
  ng "82a: env-unset hook should self-locate via ghjig-root + block protected commit (rc=$s82_rc) (#312)"
fi

# unregister + remove the fixture
s82_tmp=$(mktemp); grep -vxF "$S82_PROJ" "$SMOKE_REG" > "$s82_tmp" 2>/dev/null || true
mv "$s82_tmp" "$SMOKE_REG"
rm -rf "$S82_PROJ"

# 82b: inject_into creates `.claude/ghjig-root` resolving to the canonical
# root, adds it to .git/info/exclude, and is idempotent (no duplicate exclude line).
S82B=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S82B" && git init -q ) || true
inject_into "$S82B" >/dev/null 2>&1
inject_into "$S82B" >/dev/null 2>&1   # second run — idempotency
s82b_link=$(cd "$S82B/.claude/ghjig-root" 2>/dev/null && pwd -P)
s82b_excl=$(grep -c '^\.claude/ghjig-root$' "$S82B/.git/info/exclude" 2>/dev/null || true)
if [ -L "$S82B/.claude/ghjig-root" ] && [ "$s82b_link" = "$SHELL_ROOT" ] && [ "$s82b_excl" = "1" ]; then
  ok "82b: inject creates ghjig-root → canonical root + idempotent .git/info/exclude (#312)"
else
  ng "82b: inject must create ghjig-root→root (got '$s82b_link') + single exclude line (got $s82b_excl) (#312)"
fi

# 82c: inject points settings.local.json at settings.injected.json (not settings.json).
s82c_tgt=$(readlink "$S82B/.claude/settings.local.json" 2>/dev/null || echo "")
if printf '%s' "$s82c_tgt" | grep -q '/\.claude/settings\.injected\.json$'; then
  ok "82c: injected settings.local.json → settings.injected.json (#312)"
else
  ng "82c: settings.local.json should symlink to settings.injected.json (got '$s82c_tgt') (#312)"
fi
rm -rf "$S82B"

# 82d: settings.injected.json exists and ALL 5 hook commands use the
# ${CLAUDE_PROJECT_DIR}/.claude/ghjig-root/.claude/hooks/ form (count-guarded to 5).
S82_INJ="$SHELL_ROOT/.claude/settings.injected.json"
s82d_n=$(grep -cE '\$\{?CLAUDE_PROJECT_DIR\}?/\.claude/ghjig-root/\.claude/hooks/' "$S82_INJ" 2>/dev/null || true)
if [ -f "$S82_INJ" ] && [ "$s82d_n" = "5" ]; then
  ok "82d: settings.injected.json routes all 5 hook commands via \$CLAUDE_PROJECT_DIR/ghjig-root (#312)"
else
  ng "82d: settings.injected.json must route 5 hook commands via \$CLAUDE_PROJECT_DIR/ghjig-root (got $s82d_n) (#312)"
fi

# 82e: dogfood guard (R1, #533 — supersedes the prior env-var-based rule from
# #312) — the shell's OWN settings.json routes all 5 hook commands via
# ${CLAUDE_PROJECT_DIR}/.claude/hooks/ DIRECTLY (project dir == shell root), with
# NO *_SHELL_ROOT env var on the hook hot path and NO ghjig-root symlink
# hop (that hop is the injected-target form, §82d). Decoupling the hot path from
# the env var is what keeps enforcement armed through an in-place rename of it.
S82_OWN="$SHELL_ROOT/.claude/settings.json"
s82e_n=$(grep -cE '\$\{?CLAUDE_PROJECT_DIR\}?/\.claude/hooks/' "$S82_OWN" 2>/dev/null || true)
if [ "$s82e_n" = "5" ] \
   && ! grep -q 'ghjig-root' "$S82_OWN" \
   && ! grep -q '_SHELL_ROOT' "$S82_OWN"; then
  ok "82e: shell's own settings.json routes all 5 hook commands via \${CLAUDE_PROJECT_DIR} directly — no env var, no symlink hop (R1, #533)"
else
  ng "82e: shell's own settings.json must route 5 hook commands via \${CLAUDE_PROJECT_DIR} directly (got $s82e_n), no ghjig-root, no *_SHELL_ROOT (R1, #533)"
fi

# ---------- 83. per-project audit + cache isolation (EI-2a, #314, Directive #311) ----------
# ghjig_state_dir() routes ephemeral assets (audit, caches) to a per-project
# $CLAUDE_PROJECT_DIR/.claude/ghjig-state when CLAUDE_PROJECT_DIR is set (hook
# context), else empty → callers use the legacy shared path. The scope-guard
# registry is NOT moved here (deferred to EI-2b).

# 83a: resolver — set → per-project; unset → empty; override wins. (#314)
# #357: locally unset the whole-run override so each case exercises the branch
# it asserts (per-project / empty); s83_ovr keeps its own inline override.
s83_set=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; unset GHJIG_STATE_DIR_OVERRIDE; CLAUDE_PROJECT_DIR=/tmp/projX ghjig_state_dir )
s83_unset=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; unset GHJIG_STATE_DIR_OVERRIDE CLAUDE_PROJECT_DIR 2>/dev/null; ghjig_state_dir )
s83_ovr=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; GHJIG_STATE_DIR_OVERRIDE=/tmp/ovr CLAUDE_PROJECT_DIR=/tmp/projX ghjig_state_dir )
if [ "$s83_set" = "/tmp/projX/.claude/ghjig-state" ] && [ -z "$s83_unset" ] && [ "$s83_ovr" = "/tmp/ovr" ]; then
  ok "83a: ghjig_state_dir resolves per-project / empty / override (#314)"
else
  ng "83a: ghjig_state_dir resolution wrong (set='$s83_set' unset='$s83_unset' ovr='$s83_ovr') (#314)"
fi

# 83b: audit logs are mutually invisible across two CLAUDE_PROJECT_DIR projects.
S83_A=$(cd "$(mktemp -d)" && pwd -P)
S83_B=$(cd "$(mktemp -d)" && pwd -P)
# #357: unset the override so audit resolves per-project (CLAUDE_PROJECT_DIR), not $SMOKE_STATE.
( export CLAUDE_PROJECT_DIR="$S83_A"; unset GHJIG_STATE_DIR_OVERRIDE; . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; audit_log info test seeded "ei2a-mark-A" ) >/dev/null 2>&1
( export CLAUDE_PROJECT_DIR="$S83_B"; unset GHJIG_STATE_DIR_OVERRIDE; . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; audit_log info test seeded "ei2a-mark-B" ) >/dev/null 2>&1
s83a_log="$S83_A/.claude/ghjig-state/audit/audit.jsonl"
s83b_log="$S83_B/.claude/ghjig-state/audit/audit.jsonl"
if grep -q 'ei2a-mark-A' "$s83a_log" 2>/dev/null && ! grep -q 'ei2a-mark-B' "$s83a_log" 2>/dev/null \
   && grep -q 'ei2a-mark-B' "$s83b_log" 2>/dev/null && ! grep -q 'ei2a-mark-A' "$s83b_log" 2>/dev/null; then
  ok "83b: per-project audit logs mutually invisible (#314)"
else
  ng "83b: audit logs should isolate per CLAUDE_PROJECT_DIR (#314)"
fi
rm -rf "$S83_A" "$S83_B"

# 83c: legacy fallback — CLAUDE_PROJECT_DIR unset → audit lands at the legacy
# $GHJIG_ROOT/.claude/audit path (existing behavior preserved).
S83_LEG=$(cd "$(mktemp -d)" && pwd -P)
( export GHJIG_ROOT="$S83_LEG"; unset CLAUDE_PROJECT_DIR GHJIG_STATE_DIR_OVERRIDE 2>/dev/null
  . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; audit_log info test seeded "ei2a-legacy" ) >/dev/null 2>&1
if grep -q 'ei2a-legacy' "$S83_LEG/.claude/audit/audit.jsonl" 2>/dev/null \
   && [ ! -d "$S83_LEG/.claude/ghjig-state" ]; then
  ok "83c: env-unset audit falls back to legacy shared path (#314)"
else
  ng "83c: env-unset audit should use legacy \$GHJIG_ROOT/.claude/audit (#314)"
fi
rm -rf "$S83_LEG"

# 83d: inject adds .claude/ghjig-state to the target's .git/info/exclude.
S83_INJ=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S83_INJ" && git init -q ) || true
inject_into "$S83_INJ" >/dev/null 2>&1
if grep -qxF '.claude/ghjig-state' "$S83_INJ/.git/info/exclude" 2>/dev/null; then
  ok "83d: inject excludes .claude/ghjig-state in the target (#314)"
else
  ng "83d: inject must add .claude/ghjig-state to .git/info/exclude (#314)"
fi
rm -rf "$S83_INJ"

# ---------- 84. per-project scope-guard registry isolation (EI-2b, #316, Directive #311) ----------
# ghjig_registry_file [project_dir] resolves the scope-guard registry. Argless =
# hook context (rides ghjig_state_dir → CLAUDE_PROJECT_DIR, else legacy shared);
# explicit arg = launcher/CLI context ($arg/.claude/ghjig-state/registry.txt),
# where CLAUDE_PROJECT_DIR is unset because the call precedes the Claude session.
# The registry gates the out-of-scope matcher; missing → in_scope=false → fail-open.

# 84a: resolver resolution — explicit arg / hook (CLAUDE_PROJECT_DIR) / override / legacy.
s84_arg=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; ghjig_registry_file /tmp/projA )
# #357: unset the whole-run override on the override-sensitive (argless) cases —
# s84_hook (rides ghjig_state_dir via CLAUDE_PROJECT_DIR) and s84_leg (legacy
# fallback); s84_arg is explicit-arg (override-immune) and s84_ovr sets its own.
s84_hook=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; unset GHJIG_STATE_DIR_OVERRIDE; CLAUDE_PROJECT_DIR=/tmp/projX ghjig_registry_file )
s84_ovr=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; GHJIG_STATE_DIR_OVERRIDE=/tmp/ovr ghjig_registry_file )
s84_leg=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; export GHJIG_ROOT=/tmp/legroot; unset CLAUDE_PROJECT_DIR GHJIG_STATE_DIR_OVERRIDE 2>/dev/null; ghjig_registry_file )
if [ "$s84_arg" = "/tmp/projA/.claude/ghjig-state/registry.txt" ] \
   && [ "$s84_hook" = "/tmp/projX/.claude/ghjig-state/registry.txt" ] \
   && [ "$s84_ovr" = "/tmp/ovr/registry.txt" ] \
   && [ "$s84_leg" = "/tmp/legroot/.claude/state/registry.txt" ]; then
  ok "84a: ghjig_registry_file resolves arg / hook / override / legacy (#316)"
else
  ng "84a: ghjig_registry_file resolution wrong (arg='$s84_arg' hook='$s84_hook' ovr='$s84_ovr' leg='$s84_leg') (#316)"
fi

# 84b: registrations are mutually invisible across two projects (inject writes per-project).
S84_A=$(cd "$(mktemp -d)" && pwd -P)
S84_B=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S84_A" && git init -q ) || true
( cd "$S84_B" && git init -q ) || true
inject_into "$S84_A" >/dev/null 2>&1
inject_into "$S84_B" >/dev/null 2>&1
s84a_reg="$S84_A/.claude/ghjig-state/registry.txt"
s84b_reg="$S84_B/.claude/ghjig-state/registry.txt"
if grep -qxF "$S84_A" "$s84a_reg" 2>/dev/null && ! grep -qxF "$S84_B" "$s84a_reg" 2>/dev/null \
   && grep -qxF "$S84_B" "$s84b_reg" 2>/dev/null && ! grep -qxF "$S84_A" "$s84b_reg" 2>/dev/null; then
  ok "84b: per-project registries mutually invisible (#316)"
else
  ng "84b: registries should isolate per project (#316)"
fi
rm -rf "$S84_A" "$S84_B"

# 84c: legacy fallback — argless in_scope with no CLAUDE_PROJECT_DIR reads the
# legacy shared $GHJIG_ROOT/.claude/state/registry.txt (back-compat).
S84_LEG=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S84_LEG/.claude/state"
printf '%s\n' "$S84_LEG" > "$S84_LEG/.claude/state/registry.txt"
if ( cd "$S84_LEG"; export GHJIG_ROOT="$S84_LEG"; unset CLAUDE_PROJECT_DIR GHJIG_STATE_DIR_OVERRIDE 2>/dev/null
     . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; . "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"; in_scope ); then
  ok "84c: argless in_scope falls back to legacy shared registry, no project context (#316)"
else
  ng "84c: legacy-shared registry fallback broken (#316)"
fi
rm -rf "$S84_LEG"

# 84d: set -u safety — cwd_guard must not abort with GHJIG_ROOT unset
# (the #312 self-located case); fail-open (return), never crash the guard.
s84d=$( set -u; unset GHJIG_ROOT GHJIG_STATE_DIR_OVERRIDE 2>/dev/null; unset CLAUDE_PROJECT_DIR 2>/dev/null
        . "$SHELL_ROOT/.claude/hooks/hookrt.sh"
        . "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"
        in_scope; printf 'ic=%s ' "$?"; path_in_scope /tmp/x; printf 'pis=%s' "$?" )
if printf '%s' "$s84d" | grep -q 'pis='; then
  ok "84d: cwd_guard set -u-safe with GHJIG_ROOT unset (#316)"
else
  ng "84d: cwd_guard aborts under set -u when GHJIG_ROOT unset (got '$s84d') (#316)"
fi

# 84e: dogfood coherence — self-register write-target == cwd_guard read-target;
# carve-out stays registry-location-independent.
S84_DOG=$(cd "$(mktemp -d)" && pwd -P)
( export GHJIG_ROOT="$SHELL_ROOT"; . "$SHELL_ROOT/scripts/lib/self_register.sh"; ensure_self_registered "$S84_DOG" >/dev/null 2>&1 )
s84e_written="$S84_DOG/.claude/ghjig-state/registry.txt"
# #357: s84e_read is ARGLESS (rides ghjig_state_dir → CLAUDE_PROJECT_DIR); unset the
# whole-run override so it resolves the per-project path it compares against.
s84e_read=$( export CLAUDE_PROJECT_DIR="$S84_DOG"; unset GHJIG_STATE_DIR_OVERRIDE; . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; ghjig_registry_file )
if [ "$s84e_read" = "$s84e_written" ] && grep -qxF "$S84_DOG" "$s84e_written" 2>/dev/null; then
  ok "84e: self-register write-target == cwd_guard read-target (dogfood coherence) (#316)"
else
  ng "84e: dogfood write/read mismatch (read='$s84e_read' written='$s84e_written') (#316)"
fi
if ( export CLAUDE_PROJECT_DIR="$S84_DOG"; unset GHJIG_STATE_DIR_OVERRIDE; . "$SHELL_ROOT/.claude/hooks/hookrt.sh"
     . "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"; path_in_scope "$SHELL_ROOT/.claude/CLAUDE.md" ); then
  ok "84e: shell-root carve-out independent of registry location (#316)"
else
  ng "84e: shell-root carve-out broken under per-project registry (#316)"
fi
rm -rf "$S84_DOG"

# 84f: CLI-context discovery (dr_check_registry_guard) reads the self-describing
# per-project registry from cwd, with CLAUDE_PROJECT_DIR unset (launcher context).
S84_CLI=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S84_CLI/.claude/ghjig-state"
printf '%s\n' "$S84_CLI" > "$S84_CLI/.claude/ghjig-state/registry.txt"
# #357: keep the whole-run override ACTIVE here — dr_check_registry_guard reads
# the registry via explicit-arg (override-immune), so the read is correct either
# way, and the override keeps its project-resolve audit write off the live log.
if ( cd "$S84_CLI"; export GHJIG_ROOT="$SHELL_ROOT"; unset CLAUDE_PROJECT_DIR 2>/dev/null
     . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; . "$SHELL_ROOT/scripts/lib/dir_mode_project_resolve.sh"
     dr_check_registry_guard >/dev/null 2>&1 ); then
  ok "84f: CLI-context discovery reads per-project registry, CLAUDE_PROJECT_DIR unset (#316)"
else
  ng "84f: dr_check_registry_guard should find self-describing per-project registry (#316)"
fi
S84_CLI2=$(cd "$(mktemp -d)" && pwd -P)
if ( cd "$S84_CLI2"; export GHJIG_ROOT="$SHELL_ROOT"; unset CLAUDE_PROJECT_DIR 2>/dev/null
     . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; . "$SHELL_ROOT/scripts/lib/dir_mode_project_resolve.sh"
     dr_check_registry_guard >/dev/null 2>&1 ); then
  ng "84f: unregistered project should fail dr_check_registry_guard (#316)"
else
  ok "84f: unregistered project (no ghjig-state/registry.txt) reads unregistered (#316)"
fi
rm -rf "$S84_CLI" "$S84_CLI2"

# 84g: hook-context back-compat read-floor — a target registered before #316
# (legacy shared registry only, NO per-project ghjig-state/registry.txt) still
# enforces: in_scope falls back to the legacy shared registry even with
# CLAUDE_PROJECT_DIR set (where argless ghjig_registry_file points per-project).
S84_BC=$(cd "$(mktemp -d)" && pwd -P)
S84_BC_ROOT=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S84_BC_ROOT/.claude/state"
printf '%s\n' "$S84_BC" > "$S84_BC_ROOT/.claude/state/registry.txt"   # legacy shared only
# #357: keep CLAUDE_PROJECT_DIR set (hook context) but unset the whole-run
# override so in_scope hits the per-project-absent → legacy back-compat floor.
if ( cd "$S84_BC"; export GHJIG_ROOT="$S84_BC_ROOT"; export CLAUDE_PROJECT_DIR="$S84_BC"; unset GHJIG_STATE_DIR_OVERRIDE
     . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; . "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"
     [ ! -f "$S84_BC/.claude/ghjig-state/registry.txt" ] && in_scope ); then
  ok "84g: hook-context back-compat — pre-#316 target enforces via legacy floor (#316)"
else
  ng "84g: pre-#316 target (legacy-only registry) lost hook enforcement (#316)"
fi
rm -rf "$S84_BC" "$S84_BC_ROOT"

# ---------- 85. shell repo dogfoods its own PR template (#320) ----------
# The shell ships .claude/templates/pr_template_for_target.md to targets but must
# also carry its OWN .github/PULL_REQUEST_TEMPLATE.md (dogfooding, SPEC §9.5/§17).
# Anti-drift contract: the PR template equals the target template with its leading
# install-hint HTML comment line(s) stripped — so editing one without the other
# fails here. The skill path (pr_body.md) is unaffected and not tested here.
S85_PRT="$SHELL_ROOT/.github/PULL_REQUEST_TEMPLATE.md"
S85_SRC="$SHELL_ROOT/.claude/templates/pr_template_for_target.md"
if [ -f "$S85_PRT" ]; then
  ok "85a: .github/PULL_REQUEST_TEMPLATE.md present (dogfood scaffold, #320)"
else
  ng "85a: .github/PULL_REQUEST_TEMPLATE.md missing (#320)"
fi
# 85b: no leftover "install as ..." HTML comment (it IS the installed file).
if [ -f "$S85_PRT" ] && grep -q '^<!--' "$S85_PRT"; then
  ng "85b: PR template still carries an install-hint HTML comment (#320)"
else
  ok "85b: PR template has no install-hint comment (#320)"
fi
# 85c: anti-drift — PR template == target template minus its leading comment line(s).
if [ -f "$S85_PRT" ] && [ -f "$S85_SRC" ]; then
  s85_stripped=$(grep -v '^<!--' "$S85_SRC" | sed '/./,$!d')   # drop comment lines + leading blanks
  s85_actual=$(sed '/./,$!d' "$S85_PRT")                        # normalize leading blanks
  if [ "$s85_stripped" = "$s85_actual" ]; then
    ok "85c: PR template stays in sync with pr_template_for_target.md (#320)"
  else
    ng "85c: PR template drifted from pr_template_for_target.md (#320)"
  fi
else
  ng "85c: PR template or target-template source missing (#320)"
fi

# ---------- 86. work language resolver (EI-1, #323, Directive #322) ----------
# resolve_work_lang (work_lang.sh) resolves the WORK language of durable artifacts.
# SPEC §5.7.2: precedence GHJIG_WORK_LANG env → .claude/state/work-lang
# cwd-relative file → default `en`. Any code accepted verbatim (no enum, not
# ko/en-hardcoded); empty/whitespace → en. Mirrors §11's mode-resolver pattern.
WL_HELPER="$SHELL_ROOT/.claude/hooks/helpers/work_lang.sh"
# shellcheck disable=SC1090
[ -f "$WL_HELPER" ] && . "$WL_HELPER"
WL_TMP=$(cd "$(mktemp -d)" && pwd -P)

# 86a: unset env + no file → default en.
s86a=$( cd "$WL_TMP" || exit; unset GHJIG_WORK_LANG 2>/dev/null
        command -v resolve_work_lang >/dev/null 2>&1 && resolve_work_lang 2>/dev/null )
if [ "$s86a" = "en" ]; then
  ok "86a: resolve_work_lang default → en (unset env + no file) (#323)"
else
  ng "86a: resolve_work_lang default should be en (got '$s86a') (#323)"
fi

# 86b: env layer.
s86b=$( cd "$WL_TMP" || exit; GHJIG_WORK_LANG=ko resolve_work_lang 2>/dev/null )
[ "$s86b" = "ko" ] && ok "86b: GHJIG_WORK_LANG env layer → ko (#323)" \
  || ng "86b: env layer wrong (got '$s86b') (#323)"

# 86c: file layer (cwd-relative .claude/state/work-lang).
mkdir -p "$WL_TMP/.claude/state"; printf 'ja\n' > "$WL_TMP/.claude/state/work-lang"
s86c=$( cd "$WL_TMP" || exit; unset GHJIG_WORK_LANG 2>/dev/null; resolve_work_lang 2>/dev/null )
[ "$s86c" = "ja" ] && ok "86c: .claude/state/work-lang file layer → ja (#323)" \
  || ng "86c: file layer wrong (got '$s86c') (#323)"

# 86d: env overrides file.
s86d=$( cd "$WL_TMP" || exit; GHJIG_WORK_LANG=de resolve_work_lang 2>/dev/null )
[ "$s86d" = "de" ] && ok "86d: env overrides file (#323)" \
  || ng "86d: env should override file (got '$s86d') (#323)"

# 86e: arbitrary code (non-en, non-ko) returned verbatim — generalization, no hardcoding.
s86e=$( cd "$WL_TMP" || exit; GHJIG_WORK_LANG=pt-BR resolve_work_lang 2>/dev/null )
[ "$s86e" = "pt-BR" ] && ok "86e: arbitrary code pt-BR returned verbatim (generalization, #323)" \
  || ng "86e: arbitrary code should pass through (got '$s86e') (#323)"

# 86f: empty/whitespace-only file → en.
printf '   \n' > "$WL_TMP/.claude/state/work-lang"
s86f=$( cd "$WL_TMP" || exit; unset GHJIG_WORK_LANG 2>/dev/null; resolve_work_lang 2>/dev/null )
[ "$s86f" = "en" ] && ok "86f: empty/whitespace work-lang file → en (#323)" \
  || ng "86f: empty file should fall back to en (got '$s86f') (#323)"

# 86g: set -u-safe with everything unset (must not abort).
s86g=$( set -u; cd "$WL_TMP" || exit; rm -f .claude/state/work-lang; unset GHJIG_WORK_LANG 2>/dev/null
        resolve_work_lang; printf ' rc=%s' "$?" )
if printf '%s' "$s86g" | grep -q 'rc=0'; then
  ok "86g: resolve_work_lang set -u-safe, exits 0 (#323)"
else
  ng "86g: resolve_work_lang not set -u-safe (got '$s86g') (#323)"
fi
rm -rf "$WL_TMP"

# ---------- 87. artifact-authoring skills carry the work-language note (EI-3, #327) ----------
# SPEC §5.7.2: each artifact-authoring skill carries a `## Work language` note so
# the instruction reaches the agent at the authoring moment (skills-as-environment).
# Grep-lock with a count-guard (must be exactly 5) — an empty/short match set fails
# (anti-vacuity, smoke.sh:20 discipline). Prose-language compliance is review-judged.
WL87_SKILLS="file-issue file-directive work-on ship complete-directive"
wl87_n=0
for s in $WL87_SKILLS; do
  f="$SHELL_ROOT/.claude/commands/$s.md"
  if [ -f "$f" ] && grep -q '## Work language' "$f" && grep -q 'resolve_work_lang' "$f"; then
    wl87_n=$((wl87_n + 1))
  else
    ng "87: $s.md missing the work-language note (#327)"
  fi
done
if [ "$wl87_n" = 5 ]; then
  ok "87: all 5 artifact-authoring skills carry the work-language note (count-guard, #327)"
else
  ng "87: expected 5 skills with work-language note, got $wl87_n (#327)"
fi

# ---------- 88. bin/ghjig binding-health check (#334) ----------
# An injected target (settings.local.json is a symlink) whose .claude/ghjig-root
# binding is missing/dangling silently no-ops all hooks; bin/ghjig warns at
# launch (the detector the #318-removed SessionStart banner structurally couldn't
# be). Tested against a fake shell root + a stub `claude` on PATH so the tail
# `exec claude` returns 0 instead of launching the real CLI; targets are registered
# in the fake legacy registry so the unregistered-prompt is skipped (no hang).
S88_FAKE=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S88_FAKE/bin" "$S88_FAKE/.claude/hooks" "$S88_FAKE/.claude/state" "$S88_FAKE/workspace"
cp "$SHELL_ROOT/bin/ghjig" "$S88_FAKE/bin/ghjig"; chmod +x "$S88_FAKE/bin/ghjig"
cp "$SHELL_ROOT/.claude/hooks/hookrt.sh" "$S88_FAKE/.claude/hooks/hookrt.sh"
S88_STUB=$(cd "$(mktemp -d)" && pwd -P); printf '#!/usr/bin/env bash\nexit 0\n' > "$S88_STUB/claude"; chmod +x "$S88_STUB/claude"
S88_VALIDROOT=$(cd "$(mktemp -d)" && pwd -P)   # a real dir for a healthy binding to point at
# shellcheck disable=SC2069  # intentional swap: capture stderr (the warning), discard stdout (same pattern as hook_run)
s88_run() { ( cd "$S88_FAKE" || exit; PATH="$S88_STUB:$PATH" "$S88_FAKE/bin/ghjig" "$1" 2>&1 >/dev/null ); }
s88_reg() { printf '%s\n' "$1" >> "$S88_FAKE/.claude/state/registry.txt"; }   # pre-register → skip prompt

# 88a: injected (settings.local.json symlink) + MISSING ghjig-root → warn.
S88_A=$(cd "$(mktemp -d)" && pwd -P); mkdir -p "$S88_A/.claude"
ln -sfn /dev/null "$S88_A/.claude/settings.local.json"
s88_reg "$S88_A"
printf '%s' "$(s88_run "$S88_A")" | grep -q 'WARN binding-health' \
  && ok "88a: injected + missing binding → warn (#334)" \
  || ng "88a: should warn on missing binding (#334)"

# 88b: injected + HEALTHY ghjig-root (resolves) → silent.
S88_B=$(cd "$(mktemp -d)" && pwd -P); mkdir -p "$S88_B/.claude"
ln -sfn /dev/null "$S88_B/.claude/settings.local.json"
ln -sfn "$S88_VALIDROOT" "$S88_B/.claude/ghjig-root"
s88_reg "$S88_B"
printf '%s' "$(s88_run "$S88_B")" | grep -q 'WARN binding-health' \
  && ng "88b: healthy binding should be silent (#334)" \
  || ok "88b: injected + healthy binding → silent (#334)"

# 88c: NOT injected (no settings.local.json symlink) → silent.
S88_C=$(cd "$(mktemp -d)" && pwd -P); mkdir -p "$S88_C/.claude"
s88_reg "$S88_C"
printf '%s' "$(s88_run "$S88_C")" | grep -q 'WARN binding-health' \
  && ng "88c: non-injected should be silent (#334)" \
  || ok "88c: non-injected dir → silent (#334)"

# 88d: injected + DANGLING ghjig-root (symlink to a missing target) → warn
# (the subtle half of `! -e`, which follows the link).
S88_D=$(cd "$(mktemp -d)" && pwd -P); mkdir -p "$S88_D/.claude"
ln -sfn /dev/null "$S88_D/.claude/settings.local.json"
ln -sfn "$S88_D/.claude/nonexistent-binding-target-$$" "$S88_D/.claude/ghjig-root"
s88_reg "$S88_D"
printf '%s' "$(s88_run "$S88_D")" | grep -q 'WARN binding-health' \
  && ok "88d: injected + dangling binding → warn (#334)" \
  || ng "88d: should warn on dangling binding (#334)"

rm -rf "$S88_FAKE" "$S88_STUB" "$S88_VALIDROOT" "$S88_A" "$S88_B" "$S88_C" "$S88_D"

# ---------- registry (#357) ----------
# No restore needed: the live shared registry was never written this run (the
# whole-run GHJIG_STATE_DIR_OVERRIDE + §41/§50 per-project registration keep every
# write off $SHELL_ROOT/.claude/state/registry.txt). The §357 AC1 assertion at
# the end verifies the live audit log + scope registry are byte-for-byte untouched.

# ---------- §89 (#346): /changelog skill + /ship changelog gate + §18.5 distinction ----------
S89_SKILL="$SHELL_ROOT/.claude/commands/changelog.md"
S89_SHIP="$SHELL_ROOT/.claude/commands/ship.md"
S89_SPEC="$SHELL_ROOT/SPEC.md"

# 89a: the /changelog skill file exists with a `description:` front-matter line.
if [ -f "$S89_SKILL" ] && grep -qE '^description:' "$S89_SKILL"; then
  ok "89a: .claude/commands/changelog.md exists with description front matter (#346)"
else
  ng "89a: .claude/commands/changelog.md missing or lacks description front matter (#346)"
fi

# 89b: the skill carries a Work-language note (it authors a durable artifact — the fragment).
grep -qi 'work language' "$S89_SKILL" 2>/dev/null \
  && ok "89b: changelog.md carries the Work-language note (#346)" \
  || ng "89b: changelog.md lacks the Work-language note (#346)"

# 89c: the skill states validation-delegation — authoring, not a re-validating lint surface (§18.5).
grep -qiE 'delegat.*validation|does not re-?implement|not a .*lint|not a .*check surface' "$S89_SKILL" 2>/dev/null \
  && ok "89c: changelog.md states it delegates validation (authoring, not lint) (#346)" \
  || ng "89c: changelog.md must state it delegates validation to CI, not re-validate (#346)"

# 89d: the skill names BOTH outcomes — write a fragment XOR apply skip-changelog.
if grep -q 'changelog_unreleased' "$S89_SKILL" 2>/dev/null && grep -q 'skip-changelog' "$S89_SKILL" 2>/dev/null; then
  ok "89d: changelog.md offers both fragment-write and skip-changelog outcomes (#346)"
else
  ng "89d: changelog.md must offer fragment-write XOR skip-changelog (#346)"
fi

# 89e: /ship carries the pre-ready changelog gate, ordered BEFORE `gh pr ready`.
if grep -q 'skip-changelog' "$S89_SHIP" 2>/dev/null && grep -q 'gh pr ready' "$S89_SHIP" 2>/dev/null; then
  s89_gate=$(grep -nE 'skip-changelog' "$S89_SHIP" | head -1 | cut -d: -f1)
  s89_ready=$(grep -nE 'gh pr ready' "$S89_SHIP" | tail -1 | cut -d: -f1)
  if [ -n "$s89_gate" ] && [ -n "$s89_ready" ] && [ "$s89_gate" -lt "$s89_ready" ]; then
    ok "89e: ship.md changelog gate precedes gh pr ready (#346)"
  else
    ng "89e: ship.md changelog gate must precede gh pr ready (#346)"
  fi
else
  ng "89e: ship.md lacks the pre-ready changelog gate (skip-changelog) (#346)"
fi

# 89f: SPEC §18.5 distinguishes the forbidden lint skill from the sanctioned authoring affordance.
if grep -qE 'changelog-check.*lint' "$S89_SPEC" && grep -q 'authoring affordance' "$S89_SPEC"; then
  ok "89f: SPEC §18.5 distinguishes lint vs authoring (#346)"
else
  ng "89f: SPEC §18.5 must distinguish the forbidden lint skill from the authoring affordance (#346)"
fi

# 89g: SPEC §18.7 skip-criterion clause exists as the SSOT.
grep -q '18.7 Skip criterion' "$S89_SPEC" \
  && ok "89g: SPEC §18.7 skip-criterion clause present (#346)" \
  || ng "89g: SPEC §18.7 skip-criterion clause missing (#346)"

# ---------- §90 (#347): SPEC as a first-class target SSOT (template + ToC tooling) ----------
S90_TMPL="$SHELL_ROOT/.claude/templates/spec.md"
S90_TOC="$SHELL_ROOT/scripts/build_toc.sh"
S90_SUBWF="$SHELL_ROOT/.claude/templates/target-substrate/workflows"
S90_SPEC="$SHELL_ROOT/SPEC.md"

# 90a: the spec.md template exists with both TOC markers + at least one numbered heading.
if [ -f "$S90_TMPL" ] \
   && grep -qF '<!-- TOC START' "$S90_TMPL" && grep -qF '<!-- TOC END -->' "$S90_TMPL" \
   && grep -qE '^## [0-9]+\. ' "$S90_TMPL"; then
  ok "90a: .claude/templates/spec.md present with TOC markers + numbered headings (#347)"
else
  ng "90a: .claude/templates/spec.md missing markers or numbered headings (#347)"
fi

# 90b: build_toc.sh honors --spec <path> — populate + --check an ARBITRARY SPEC path.
# Runs a COPY in an isolated temp dir (its self-located default SPEC is the temp dir),
# so the real repo SPEC is never touched regardless of parameterization state.
S90_DIR=$(mktemp -d); mkdir -p "$S90_DIR/scripts"
cp "$S90_TOC" "$S90_DIR/scripts/build_toc.sh"
cat > "$S90_DIR/target_spec.md" <<'S90SPEC'
# Target
## Table of contents
<!-- TOC START — generated by scripts/build_toc.sh; do not edit by hand -->
<!-- TOC END -->
## 1. Alpha
body
## 2. Beta
body
S90SPEC
bash "$S90_DIR/scripts/build_toc.sh" --spec "$S90_DIR/target_spec.md" >/dev/null 2>&1
if grep -q '§1' "$S90_DIR/target_spec.md" \
   && bash "$S90_DIR/scripts/build_toc.sh" --spec "$S90_DIR/target_spec.md" --check >/dev/null 2>&1; then
  ok "90b: build_toc.sh --spec populates + checks an arbitrary SPEC path (#347)"
else
  ng "90b: build_toc.sh must accept --spec <path> for a target SPEC (#347)"
fi
rm -rf "$S90_DIR"

# 90c: regression guard — default-path (no --spec) --check still passes on the shell's own SPEC (§28 parity).
bash "$S90_TOC" --check >/dev/null 2>&1 \
  && ok "90c: build_toc.sh default-path --check unchanged on the shell's own SPEC (#347)" \
  || ng "90c: build_toc.sh default behavior regressed on the shell's own SPEC (#347)"

# 90d: the target ToC-freshness workflow ships in the canonical substrate.
[ -f "$S90_SUBWF/check-toc.yml" ] \
  && ok "90d: target-substrate workflows/check-toc.yml present (#347)" \
  || ng "90d: target-substrate workflows/check-toc.yml missing (#347)"

# 90e: the shipped build_toc.sh is byte-identical to the canonical scripts/build_toc.sh (no drift).
if [ -f "$S90_SUBWF/build_toc.sh" ] && cmp -s "$S90_TOC" "$S90_SUBWF/build_toc.sh"; then
  ok "90e: substrate build_toc.sh byte-identical to canonical scripts/build_toc.sh (#347)"
else
  ng "90e: substrate build_toc.sh missing or drifted from scripts/build_toc.sh (#347)"
fi

# 90f: SPEC §1.3 documents SPEC-as-SSOT (paired with MISSION) + the navigation norm.
if grep -q 'frequently-consulted pair' "$S90_SPEC" && grep -q 'heading text is the truth' "$S90_SPEC"; then
  ok "90f: SPEC §1.3 documents SPEC-as-SSOT + navigation norm (#347)"
else
  ng "90f: SPEC §1.3 must document SPEC-as-SSOT pairing + the offset-hint/heading-truth norm (#347)"
fi

# 90g: the spec.md template ships self-consistent — a verbatim copy passes build_toc --check
# (so a target's first SPEC PR is not blocked by a stale ToC). Uses an isolated copy.
# (copy target name avoids a case-insensitive collision with the default SPEC.md path)
S90G_DIR=$(mktemp -d); mkdir -p "$S90G_DIR/scripts"
cp "$S90_TOC" "$S90G_DIR/scripts/build_toc.sh"; cp "$S90_TMPL" "$S90G_DIR/project_spec.md"
bash "$S90G_DIR/scripts/build_toc.sh" --spec "$S90G_DIR/project_spec.md" --check >/dev/null 2>&1 \
  && ok "90g: spec.md template ships with a fresh (self-consistent) ToC (#347)" \
  || ng "90g: spec.md template ToC is stale — a verbatim copy would fail check-toc (#347)"
rm -rf "$S90G_DIR"

# ---------- §91 (#348): docs/*.md are thin pointers — lead with a SPEC reference ----------
# The docs-thin-pointer norm (SPEC §9): every human-facing docs/*.md digest must
# lead with a "Full details in SPEC §X" reference (within its first two non-empty
# lines — the title + the lead-in), so it cannot become a second copy of canonical
# content that silently drifts from SPEC. Enforcement, not prose (hooks-as-environment).
S91_FAIL=""
for d in "$SHELL_ROOT"/docs/*.md; do
  [ -f "$d" ] || continue
  # First two non-empty lines (title + lead-in). awk reads the file directly and
  # exits after 2 — no `... | head` pipe (which would SIGPIPE the upstream under
  # `set -o pipefail` and fail nondeterministically by file size, GNU vs BSD).
  s91_lead=$(awk 'NF{n++; print; if(n==2) exit}' "$d")
  if [[ "$s91_lead" == *SPEC* ]]; then
    : # leads with a SPEC reference — compliant
  else
    S91_FAIL="$S91_FAIL ${d##*/}"
  fi
done
if [ -z "$S91_FAIL" ]; then
  ok "91: every docs/*.md leads with a SPEC reference (thin-pointer norm, SPEC §9) (#348)"
else
  ng "91: docs/*.md not leading with a SPEC reference:$S91_FAIL (SPEC §9 thin-pointer norm) (#348)"
fi

# ---------- §92 (#354): SPEC §6.0 wired into the review layer (enforcement-style lens) ----------
# §6.0's own P4 forbids "guidance with no gate behind it"; the enforcement-style
# principle must therefore be referenced by the artifact-judging reviewers that
# apply it, not merely documented. Structural fixed-string grep for the stable
# token "SPEC §6.0" (not a sentence — robust to future rewordings of the lens);
# collect every missing reviewer before reporting (no first-failure short-circuit).
S92_FAIL=""
for r in issue-reviewer plan-reviewer code-reviewer; do
  rf="$SHELL_ROOT/.claude/agents/$r.md"
  if [ -f "$rf" ] && grep -qF 'SPEC §6.0' "$rf"; then
    : # references the enforcement-style principle — wired
  else
    S92_FAIL="$S92_FAIL $r"
  fi
done
if [ -z "$S92_FAIL" ]; then
  ok "92: issue/plan/code-reviewer prompts reference SPEC §6.0 (enforcement-style lens) (#354)"
else
  ng "92: reviewer prompts missing SPEC §6.0 reference:$S92_FAIL (#354)"
fi

# ---------- 93. audit source discriminator + reviewer-reject instrumentation (#361, Directive #356 signals 1+3) ----------
# All fires here resolve to $SMOKE_AUDIT (the whole-run GHJIG_STATE_DIR_OVERRIDE),
# so they do NOT touch the live sinks the §357 backstop (just below) measures.
# hook_run inherits the process env (only GHJIG_ROOT_OVERRIDE is prefix-set),
# so the global GHJIG_AUDIT_SOURCE=test flows through; a subshell that
# unsets / re-sets it exercises the default + forged-value branches.

# Helper: emit one audit-producing fixture fire and echo the LAST record's
# .source (eval "ls" → a bypass-suspect warn, a clean audit-emitting fire).
s93_last_source() {  # echoes the .source of the newest $SMOKE_AUDIT record
  hook_run 'eval "ls -la"' >/dev/null
  tail -n 1 "$SMOKE_AUDIT" 2>/dev/null | jq -r '.source // "ABSENT"' 2>/dev/null
}

if ! command -v jq >/dev/null 2>&1; then
  ng "89: jq not installed — cannot scan audit source field (#361)"
else
  # 89a — the source field is present and resolves `test` under the harness
  # marker (exported globally at smoke start). RED pre-#361 (no field → ABSENT).
  s93a=$(s93_last_source)
  [ "$s93a" = "test" ] \
    && ok "93a: audit record carries source=test under harness marker (#361)" \
    || ng "93a: audit source not 'test' under harness marker (got '$s93a') (#361)"

  # 89b (AC#2 default-live) — marker UNSET → source=live. A real session has no
  # marker, so its records must be live. RED pre-#361.
  s93b=$( unset GHJIG_AUDIT_SOURCE; s93_last_source )
  [ "$s93b" = "live" ] \
    && ok "93b: marker unset → source=live (real-session default) (#361)" \
    || ng "93b: marker unset did not resolve source=live (got '$s93b') (#361)"

  # 89c (AC#2 anti-reclassification) — a FORGED non-`test` value (smoke) must
  # still resolve `live`: only the exact token `test` flips the field, so a real
  # action cannot reclassify itself to dodge a friction signal. RED pre-#361.
  s93c=$( export GHJIG_AUDIT_SOURCE=smoke; s93_last_source )
  [ "$s93c" = "live" ] \
    && ok "93c: forged GHJIG_AUDIT_SOURCE=smoke still resolves source=live (#361)" \
    || ng "93c: forged non-test marker leaked into source (got '$s93c') (#361)"

  # 89d — jq still parses every line after the new field lands (shape integrity).
  if jq -c '.' "$SMOKE_AUDIT" >/dev/null 2>&1; then
    ok "93d: audit.jsonl still one-JSON-object-per-line with the source field (#361)"
  else
    ng "93d: audit.jsonl no longer fully jq-parseable after source field (#361)"
  fi

  # 89e — reviewer_reject_audit helper emits a categorized reject record. RED
  # pre-#361 (helper absent → source fails → nothing emitted).
  s93e_before=$(wc -l < "$SMOKE_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$s93e_before" ] && s93e_before=0
  (
    # shellcheck disable=SC1091
    . "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null
    . "$SHELL_ROOT/.claude/hooks/helpers/reviewer_audit.sh" 2>/dev/null
    reviewer_reject_audit issue-review scope-bleed 999 2>/dev/null
  )
  s93e_after=$(wc -l < "$SMOKE_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$s93e_after" ] && s93e_after=0
  if [ "$s93e_after" -gt "$s93e_before" ] \
     && tail -n "$((s93e_after - s93e_before))" "$SMOKE_AUDIT" 2>/dev/null \
        | jq -e 'select(.event=="warn" and .category=="issue-review" and .decision=="reject" and (.reason | test("class=scope-bleed issue=#999")))' >/dev/null 2>&1; then
    ok "93e: reviewer_reject_audit emits warn/issue-review/reject with class+issue (#361)"
  else
    ng "93e: reviewer_reject_audit did not emit the expected reject record (#361)"
  fi

  # 89f — structural: each of the 4 reviewer-invoking skills references the
  # reject-audit emission (reviewer_reject_audit or the reason-class token).
  s93f_fail=
  for f in file-issue work-on activate complete-directive; do
    grep -q 'reviewer_reject_audit\|reason-class\|reason_class' "$SHELL_ROOT/.claude/commands/$f.md" 2>/dev/null \
      || s93f_fail="$s93f_fail $f"
  done
  [ -z "$s93f_fail" ] \
    && ok "93f: all 4 reviewer-invoking skills wire the reject-audit emission (#361)" \
    || ng "93f: skills missing reject-audit wiring:$s93f_fail (#361)"
fi

# ---------- §94 (#363): audit-log consumers — narrowing detector + promotion report (Directive #356 signals 2/4/5) ----------
# Read-only reporters run against a SYNTHETIC fixture audit.jsonl (mktemp, passed
# as the path arg) — never the live/$SMOKE log — so the assertions don't couple
# to real escape history and cannot pollute the live sinks (§357 AC1 stays green).

# 94a: SPEC §6.0 P3 references the audit log as a P3 consumer surface, names both
# scripts, and states the dual-positive-channel concept (signal 5). (Doc-phase; green early.)
if grep -q 'narrowing_candidates.sh' "$SHELL_ROOT/SPEC.md" \
   && grep -q 'promotion_candidates.sh' "$SHELL_ROOT/SPEC.md" \
   && grep -q 'dual-positive' "$SHELL_ROOT/SPEC.md"; then
  ok "94a: SPEC §6.0 P3 names both consumers + the dual-positive-channel concept (#363)"
else
  ng "94a: SPEC §6.0 P3 must name the two consumer scripts + the dual-positive channel (#363)"
fi

S94_NARROW="$SHELL_ROOT/scripts/narrowing_candidates.sh"
S94_PROMO="$SHELL_ROOT/scripts/promotion_candidates.sh"
if [ ! -f "$S94_NARROW" ] || [ ! -f "$S94_PROMO" ]; then
  ng "94b: scripts/narrowing_candidates.sh / promotion_candidates.sh missing — Code not yet landed (#363)"
  ng "94c: narrowing below-threshold/test-exclusion — scripts missing (#363)"
  ng "94d: promotion surfaced above threshold — scripts missing (#363)"
  ng "94e: promotion below-threshold + legacy-skip — scripts missing (#363)"
  ng "94f: empty/absent-log graceful exit 0 — scripts missing (#363)"
elif ! command -v jq >/dev/null 2>&1; then
  ng "94b: jq not installed — cannot run consumer-script smoke (#363)"
else
  S94_DIR=$(mktemp -d)
  # Narrowing fixture: force-push has 2 distinct LIVE days (→ surfaced, threshold 2);
  # merge-strategy 1 day (below); secret has 2 TEST-source days (excluded → not
  # surfaced); out-of-scope is a legacy line with no source field (→ treated live,
  # must not crash).
  cat > "$S94_DIR/narrow.jsonl" <<'S94FIX'
{"ts":"2026-06-01T10:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
{"ts":"2026-06-02T11:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
{"ts":"2026-06-03T12:00:00Z","event":"escape","category":"merge-strategy","decision":"skip","reason":"one off","cwd":"/x","source":"live"}
{"ts":"2026-06-01T08:00:00Z","event":"escape","category":"secret","decision":"skip","reason":"test fixture","cwd":"/x","source":"test"}
{"ts":"2026-06-02T08:00:00Z","event":"escape","category":"secret","decision":"skip","reason":"test fixture","cwd":"/x","source":"test"}
{"ts":"2026-06-04T09:00:00Z","event":"escape","category":"out-of-scope","decision":"skip","reason":"legacy no source"}
S94FIX
  s94_n_out=$(bash "$S94_NARROW" "$S94_DIR/narrow.jsonl" 2>/dev/null); s94_n_rc=$?
  if [ "$s94_n_rc" = 0 ] && printf '%s\n' "$s94_n_out" | grep -q 'force-push'; then
    ok "94b: narrowing surfaces the 2-distinct-day force-push escape cluster (#363)"
  else
    ng "94b: narrowing did not surface the 2-day force-push cluster (rc=$s94_n_rc) (#363)"
  fi
  if printf '%s\n' "$s94_n_out" | grep -q 'merge-strategy' || printf '%s\n' "$s94_n_out" | grep -q 'secret'; then
    ng "94c: narrowing wrongly surfaced a below-threshold (merge-strategy) or test-source (secret) cluster (#363)"
  else
    ok "94c: narrowing omits single-day + test-source clusters (LIVE-only, threshold) (#363)"
  fi

  # Promotion fixture: issue-review×scope-bleed has 3 rejects (→ surfaced, threshold 3);
  # plan-review×conflict 2 (below); a legacy warn/reject reason with no class= (→ skipped).
  cat > "$S94_DIR/promo.jsonl" <<'S94FIX'
{"ts":"2026-06-01T10:00:00Z","event":"warn","category":"issue-review","decision":"reject","reason":"class=scope-bleed issue=#10","cwd":"/x","source":"live"}
{"ts":"2026-06-01T11:00:00Z","event":"warn","category":"issue-review","decision":"reject","reason":"class=scope-bleed issue=#11","cwd":"/x","source":"live"}
{"ts":"2026-06-02T10:00:00Z","event":"warn","category":"issue-review","decision":"reject","reason":"class=scope-bleed issue=#12","cwd":"/x","source":"live"}
{"ts":"2026-06-02T11:00:00Z","event":"warn","category":"plan-review","decision":"reject","reason":"class=conflict issue=#13","cwd":"/x","source":"live"}
{"ts":"2026-06-03T10:00:00Z","event":"warn","category":"plan-review","decision":"reject","reason":"class=conflict issue=#14","cwd":"/x","source":"live"}
{"ts":"2026-06-03T11:00:00Z","event":"warn","category":"legacy-cat","decision":"reject","reason":"no class token here","cwd":"/x"}
S94FIX
  s94_p_out=$(bash "$S94_PROMO" "$S94_DIR/promo.jsonl" 2>/dev/null); s94_p_rc=$?
  if [ "$s94_p_rc" = 0 ] && printf '%s\n' "$s94_p_out" | grep -q 'issue-review' && printf '%s\n' "$s94_p_out" | grep -q 'scope-bleed'; then
    ok "94d: promotion surfaces issue-review×scope-bleed above the reject threshold (#363)"
  else
    ng "94d: promotion did not surface the 3-reject issue-review/scope-bleed group (rc=$s94_p_rc) (#363)"
  fi
  if printf '%s\n' "$s94_p_out" | grep -q 'conflict'; then
    ng "94e: promotion wrongly surfaced the below-threshold plan-review/conflict group (#363)"
  else
    ok "94e: promotion omits below-threshold group + skips the legacy no-class line (#363)"
  fi

  # 94f: empty + absent log → graceful, exit 0 (no crash, fail-open).
  : > "$S94_DIR/empty.jsonl"
  bash "$S94_NARROW" "$S94_DIR/empty.jsonl" >/dev/null 2>&1; s94_e1=$?
  bash "$S94_PROMO" "$S94_DIR/empty.jsonl" >/dev/null 2>&1; s94_e2=$?
  bash "$S94_NARROW" "$S94_DIR/does-not-exist.jsonl" >/dev/null 2>&1; s94_e3=$?
  if [ "$s94_e1" = 0 ] && [ "$s94_e2" = 0 ] && [ "$s94_e3" = 0 ]; then
    ok "94f: both consumers degrade gracefully (exit 0) on empty + absent log (#363)"
  else
    ng "94f: a consumer crashed on empty/absent log (narrow-empty=$s94_e1 promo-empty=$s94_e2 narrow-absent=$s94_e3) (#363)"
  fi
  rm -rf "$S94_DIR"
fi

# ---------- §95 (#365): audit record-shape SPEC examples carry source; info event documented (G1+G4) ----------
# The §6.1 helper-missing example and the §7 escape example are the canonical
# record-shape contract a consumer copies from; they must include every field
# audit_log's printf emits (hookrt.sh now appends "source" last on EVERY record,
# #361). And the info event kind, emitted by audit_log info (pre_tool_use.sh +
# dir-mode flows), must be documented as a valid event. Reproduce-first: these
# fail on the pre-#365 SPEC (examples omit source; info undocumented).
S95_SPEC="$SHELL_ROOT/SPEC.md"
# 95a: §6.1 helper-missing example carries the source field (G1).
if grep -E '"decision":"helper-missing"' "$S95_SPEC" | grep -q '"source"'; then
  ok "95a: SPEC helper-missing example includes the source field (#365)"
else
  ng "95a: SPEC helper-missing example omits source — drifted from hookrt.sh printf (#365)"
fi
# 95b: §7 escape-skip example carries the source field (G1).
if grep -E '"event":"escape"' "$S95_SPEC" | grep -q '"source"'; then
  ok "95b: SPEC §7 escape example includes the source field (#365)"
else
  ng "95b: SPEC §7 escape example omits source — drifted from hookrt.sh printf (#365)"
fi
# 95c: the info event kind is documented as a valid event (G4) — reconciles the
# "not new event-type kinds" line with the info record audit_log actually emits.
if grep -q 'Event-kind set' "$S95_SPEC" && grep -qE 'event.*\binfo\b|\binfo\b.*informational' "$S95_SPEC"; then
  ok "95c: SPEC documents the info event kind in the event-kind set (#365)"
else
  ng "95c: SPEC does not document the info event kind audit_log emits (#365)"
fi

# ---------- §96 (#366): protected-push / git-clean — token-as-data + sibling-segment FPs ----------
# The protected-push arm scans only the git-push command SEGMENT after heredoc-
# stripping (not a whole-command substring), and the git-clean arm heredoc-strips
# too. So a protected token in a sibling non-push segment or inside a heredoc body
# no longer false-blocks; genuine protected pushes still block (zero false-neg).
# hook_run rc: 2=block, 0=allow. 96a-d are RED pre-fix (old substring blocks them);
# 96e-k are zero-false-negative guards (BLOCK before and after).

# --- false positives that must now ALLOW (rc 0) ---
[ "$(hook_run 'git push origin feat && gh pr create --base main')" = 0 ] \
  && ok "96a: push feat && gh pr create --base main → allow (sibling segment) (#366)" \
  || ng "96a: chained --base main false-blocked the push (#366)"
s96b=$(printf 'cat <<EOF\ndiscuss: git push origin main here\nEOF\n')
[ "$(hook_run "$s96b")" = 0 ] \
  && ok "96b: git push…main inside a heredoc body → allow (data) (#366)" \
  || ng "96b: heredoc-body push text false-blocked (#366)"
s96c=$(printf 'cat <<EOF\nrun git clean -fd to reset\nEOF\n')
[ "$(hook_run "$s96c")" = 0 ] \
  && ok "96c: git clean -f inside a heredoc body → allow (data) (#366)" \
  || ng "96c: heredoc-body git-clean text false-blocked (#366)"
[ "$(hook_run 'git push origin feat ; echo done with main')" = 0 ] \
  && ok "96d: push feat ; echo …main → allow (sibling ; segment) (#366)" \
  || ng "96d: ;-separated main mention false-blocked the push (#366)"

# --- zero-false-negative: genuine protected pushes/cleans MUST still BLOCK (rc 2) ---
[ "$(hook_run 'git push origin main')" = 2 ] \
  && ok "96e: git push origin main still blocked (#366)" \
  || ng "96e: real protected push slipped (#366)"
[ "$(hook_run 'git push -u origin main')" = 2 ] \
  && ok "96f: git push -u origin main still blocked (#366)" \
  || ng "96f: real -u protected push slipped (#366)"
[ "$(hook_run 'git push origin HEAD:main')" = 2 ] \
  && ok "96g: git push origin HEAD:main still blocked (#366)" \
  || ng "96g: HEAD:main refspec push slipped (#366)"
[ "$(hook_run 'GH_TOKEN=x git push origin main')" = 2 ] \
  && ok "96h: env-prefixed real protected push still blocked (#366)" \
  || ng "96h: env-prefixed protected push slipped (#366)"
[ "$(hook_run 'echo x && git push origin main')" = 2 ] \
  && ok "96i: real protected push in a non-first && segment still blocked (#366)" \
  || ng "96i: non-first-segment protected push slipped (#366)"
[ "$(hook_run 'git push origin "main"')" = 2 ] \
  && ok "96j: quoted protected target still blocked (heredoc-only strip keeps it) (#366)" \
  || ng "96j: quoted protected target slipped — false-negative (#366)"
[ "$(hook_run 'git clean -fd')" = 2 ] \
  && ok "96k: real git clean -fd still blocked (#366)" \
  || ng "96k: real git clean slipped (#366)"

# ---------- §97 (#368): SPEC↔code accuracy sweep (G5–G11) ----------
# Doc-only SSOT-accuracy pins: each asserts SPEC now matches implemented behavior.
# Reproduce-first: each FAILS on the pre-#368 SPEC (verified against origin/main).
S97_SPEC="$SHELL_ROOT/SPEC.md"
# 97a (G6): the stale `/onboard-dir-mode (deferred)` marker is gone.
if grep -q 'onboard-dir-mode` (deferred)' "$S97_SPEC"; then
  ng "97a: SPEC still carries the stale /onboard-dir-mode (deferred) marker (#368)"
else
  ok "97a: /onboard-dir-mode (deferred) marker removed (#368)"
fi
# 97b (G7): §3.3 states the scope-guard fail-open contract.
if awk '/^### 3.3/{f=1} f&&/^### 3.4/{exit} f' "$S97_SPEC" | grep -q 'Fail-open contract'; then
  ok "97b: SPEC §3.3 states the scope-guard fail-open contract (#368)"
else
  ng "97b: SPEC §3.3 omits the scope-guard fail-open contract (#368)"
fi
# 97c (G9b): the §6.1 sensitive-file row lists id_rsa* / id_ed25519* (parity with §14 + code).
if grep -qE 'Edit/Write on `\.env`.*id_rsa.*id_ed25519' "$S97_SPEC"; then
  ok "97c: SPEC §6.1 sensitive-file row lists id_rsa*/id_ed25519* (#368)"
else
  ng "97c: SPEC §6.1 sensitive-file row omits id_rsa*/id_ed25519* (drifted from the code) (#368)"
fi
# 97d (G11): the #107 reversibility-preflight marker reflects that the preflight landed (not deferred).
if grep -q 'Per-command preflight implementation is deferred' "$S97_SPEC"; then
  ng "97d: SPEC still says the per-command preflight is deferred (#107 is closed) (#368)"
else
  ok "97d: SPEC reflects the landed per-command substrate preflight (#368)"
fi

# ---------- §98 (#374): /onboard-dir-mode installs the changelog_unreleased substrate (SPEC §18.6) ----------
# SPEC §18.1/§18.6 mandate that tier-3 onboarding install the release-backbone
# authoring substrate — changelog_unreleased/TEMPLATE.md + the six Keep-a-Changelog
# category subdirs each with a .gitkeep — alongside the check-changelog.yml gate.
# Pre-#374: the canonical source tree does not exist under target-substrate/ and
# onboard_target.sh copies none of it, so every assertion below FAILS on the
# pre-#374 tree (reproduce-first). Each is a pure file/grep check (no live-sink write).
S98_SUB="$SHELL_ROOT/.claude/templates/target-substrate/changelog_unreleased"
# §98a: canonical source carries TEMPLATE.md.
if [ -f "$S98_SUB/TEMPLATE.md" ]; then
  ok "98a: target-substrate/changelog_unreleased/TEMPLATE.md present (#374, SPEC §18.6)"
else
  ng "98a: target-substrate/changelog_unreleased/TEMPLATE.md missing (#374, SPEC §18.6)"
fi
# §98b: each of the six Keep-a-Changelog category subdirs carries a .gitkeep
# (empty dirs do not survive git; the placeholder is load-bearing for both the
# source tree and the installed target).
s98b_missing=""
for cat in added changed deprecated removed fixed security; do
  [ -f "$S98_SUB/$cat/.gitkeep" ] || s98b_missing="$s98b_missing $cat"
done
if [ -z "$s98b_missing" ]; then
  ok "98b: all six changelog_unreleased category dirs carry .gitkeep (#374, SPEC §18.6)"
else
  ng "98b: changelog_unreleased category dirs missing .gitkeep:$s98b_missing (#374, SPEC §18.6)"
fi
# §98b2: the canonical source carries ONLY placeholders, not the shell's own
# accumulated <N>.md fragments (adopters start empty).
if ls "$S98_SUB"/*/[0-9]*.md >/dev/null 2>&1; then
  ng "98b2: target-substrate substrate leaked accumulated <N>.md fragments (adopters must start empty) (#374)"
else
  ok "98b2: target-substrate substrate carries only placeholders, no <N>.md fragments (#374)"
fi
# §98c: onboard_target.sh tier-3 actually installs the substrate (references the
# changelog_unreleased path in its copy logic — guards against shipping the source
# tree but never copying it).
if grep -q 'changelog_unreleased' "$SHELL_ROOT/scripts/onboard_target.sh"; then
  ok "98c: onboard_target.sh tier-3 install path references changelog_unreleased (#374)"
else
  ng "98c: onboard_target.sh never copies changelog_unreleased — source tree would ship uninstalled (#374)"
fi
# §98d: the /onboard-dir-mode skill doc lists the substrate in its tier-3 file set.
if grep -q 'changelog_unreleased' "$SHELL_ROOT/.claude/commands/onboard-dir-mode.md"; then
  ok "98d: /onboard-dir-mode tier-3 file set lists changelog_unreleased (#374)"
else
  ng "98d: /onboard-dir-mode tier-3 file set omits changelog_unreleased (#374)"
fi

# ---------- §99 (#376): SPEC names the lint-timeout-absent audit category ----------
# detect_stack.sh:66 emits `audit_log warn lint-timeout-absent notice ...` when
# neither timeout(1) nor gtimeout(1) is on PATH, but pre-#376 the category was
# named in no SPEC enumeration. Bridge pin until #377's generative
# audit-category↔SPEC guard subsumes it. FAILS on the pre-#376 SPEC.
S99_SPEC="$SHELL_ROOT/SPEC.md"
if grep -q 'lint-timeout-absent' "$S99_SPEC"; then
  ok "99a: SPEC §6.1 names the lint-timeout-absent audit category (#376)"
else
  ng "99a: SPEC omits the lint-timeout-absent audit category emitted by detect_stack.sh (#376)"
fi
# §99b: the category is emitted by the code it documents (anchors the doc to reality).
if grep -q 'lint-timeout-absent' "$SHELL_ROOT/.claude/hooks/helpers/detect_stack.sh"; then
  ok "99b: detect_stack.sh emits lint-timeout-absent (SPEC §6.1 doc has a real referent) (#376)"
else
  ng "99b: detect_stack.sh no longer emits lint-timeout-absent — SPEC §6.1 doc is now stale (#376)"
fi

# ---------- §100 (#377): generative SPEC↔code consistency guards (Directive #373) ----------
# Promote the periodic manual sweep (#368) + hand-pinned point assertions (§97)
# into continuous generative guards over two enumerable contract surfaces, in the
# §39c/§58a style (pure shell, deterministic, no network). These would have caught
# the lint-timeout-absent drift (audit category emitted but undocumented) and the
# /activate-directive forward-ref drift this sweep surfaced.

S100_SPEC="$SHELL_ROOT/SPEC.md"
S100_HOOKS="$SHELL_ROOT/.claude/hooks"
S100_CMDS="$SHELL_ROOT/.claude/commands"

# §100a — every LITERAL audit_log category emitted across .claude/hooks/** is
# documented somewhere in SPEC. Pure-comment lines (leading #) are excluded so
# prose like "emits an audit_log warn once" is not mis-read as a category;
# variable-passed categories (audit_log warn "$cat") are inherently un-resolvable
# statically and are simply not matched by the literal extractor.
s100_cats=$(grep -rhE 'audit_log[[:space:]]+(info|warn|block|error)[[:space:]]+[A-Za-z]' "$S100_HOOKS" 2>/dev/null \
  | grep -vE '^[[:space:]]*#' \
  | grep -oE 'audit_log[[:space:]]+(info|warn|block|error)[[:space:]]+[A-Za-z][A-Za-z0-9_-]+' \
  | awk '{print $3}' | sort -u)
s100a_missing=""
for cat in $s100_cats; do
  grep -qF "$cat" "$S100_SPEC" || s100a_missing="$s100a_missing $cat"
done
if [ -z "$s100a_missing" ]; then
  ok "100a: every literal audit_log category in .claude/hooks/** is documented in SPEC ($(printf '%s' "$s100_cats" | wc -w | tr -d ' ') cats) (#377)"
else
  ng "100a: audit categories emitted but undocumented in SPEC:$s100a_missing (#377)"
fi
# §100b — falsifiability: the same extractor+lookup correctly FLAGS a synthetic
# category that is absent from SPEC (proves 100a is not vacuously passing).
if grep -qF 'zzz-fake-cat-377' "$S100_SPEC"; then
  ng "100b: guard self-test tripwire 'zzz-fake-cat-377' unexpectedly present in SPEC (#377)"
else
  ok "100b: audit-category guard is falsifiable (a synthetic absent category is detectable) (#377)"
fi

# §100c — every .claude/commands/*.md command is referenced in SPEC (plain `/cmd`
# token; backticks optional — /discuss is named in §5.19 prose without them). The
# substring match only over-counts (e.g. /activate matches inside
# /activate-directive), which can never cause a false FAIL — it only fails when a
# command has ZERO SPEC references, the real "command exists, SPEC silent" drift.
s100c_missing=""
for f in "$S100_CMDS"/*.md; do
  cmd="/$(basename "$f" .md)"
  grep -qF "$cmd" "$S100_SPEC" || s100c_missing="$s100c_missing $cmd"
done
if [ -z "$s100c_missing" ]; then
  ok "100c: every .claude/commands/*.md command is referenced in SPEC (#377)"
else
  ng "100c: command files with no SPEC reference:$s100c_missing (#377)"
fi

# §100d — no command/agent file steers a user to a SPEC-deprecated alias via
# imperative *forward guidance* (a `Next:` hint or a `via`/`run`/`invoke`/`use`
# verb immediately preceding the command). Descriptive mentions ("absorbs X",
# "relocated from X", "X is a deprecated alias") use no such verb and are not
# flagged. Deprecated set = the §5.12/§5.18 sunset aliases; extend when a new
# alias is retired. The alias's OWN command file is excluded.
S100_DEPRECATED="activate-directive triage"   # SPEC §5.12 / §5.18 deprecated aliases
s100d_hits=""
for dep in $S100_DEPRECATED; do
  while IFS= read -r hit; do
    [ -n "$hit" ] && s100d_hits="$s100d_hits\n$hit"
  done <<EOF100D
$(grep -rniE "(Next:|[^a-z](via|run|invoke|use)[^a-z])[^\`]*\`?/$dep\b" "$S100_CMDS" "$SHELL_ROOT/.claude/agents" 2>/dev/null \
   | grep -vE "commands/$dep\.md")
EOF100D
done
if [ -z "$s100d_hits" ]; then
  ok "100d: no command/agent forward-guidance steers to a deprecated alias (#377)"
else
  ng "100d: forward-guidance to a deprecated alias:$(printf '%b' "$s100d_hits") (#377)"
fi
# §100e — falsifiability: the same forward-guidance pattern matches a synthetic
# `Next: /activate-directive` line (proves 100d is not vacuously passing — this
# is the exact drift shape #376 redirected).
if printf 'Next: /activate-directive <N> when ready' \
   | grep -qiE "(Next:|[^a-z](via|run|invoke|use)[^a-z])[^\`]*\`?/activate-directive\b"; then
  ok "100e: deprecated-alias forward-guidance guard is falsifiable (#377)"
else
  ng "100e: forward-guidance guard fails to flag a synthetic Next:/activate-directive (#377)"
fi

# ---------- 101. /flush affordance + flush → clear → reconstruct lifecycle (#387, Directive #385) ----------
# Doc→Test→Code: this section is authored in the Test phase and FAILS until the
# Code phase adds .claude/commands/flush.md. Anti-vacuity (smoke.sh header): the
# skill-content greps anchor on the CONTRACT phrases the prose must carry
# (active→archived, the .claude/state/ durable target, the native-/clear
# non-invocation), not bare tokens; a missing flush.md fails LOUD via ng.

# §101a: /flush skill exists and declares the pre-clear archive contract.
S101_FLUSH="$SHELL_ROOT/.claude/commands/flush.md"
if [ -f "$S101_FLUSH" ] \
   && grep -q 'active → archived' "$S101_FLUSH" \
   && grep -q '\.claude/state/' "$S101_FLUSH" \
   && grep -qi 'does not.*invoke\|cannot.*invoke\|never.*invoke' "$S101_FLUSH" \
   && grep -q '/clear' "$S101_FLUSH"; then
  ok "101a: /flush skill declares active→archived flush into a durable artifact, no native /clear invocation (#387)"
else
  ng "101a: /flush skill missing or lacks the pre-clear archive contract (active→archived + .claude/state/ + no-native-/clear) (#387)"
fi

# §101b: SPEC §3.7 lifecycle section + §5.24 /flush roster entry present, and the
# TOC carries both rows (heading forms are caret-anchored so a prose mention of
# "3.7" cannot satisfy them).
if grep -qE '^### 3\.7 Context lifecycle: flush → clear → reconstruct' "$SHELL_ROOT/SPEC.md" \
   && grep -qE '^### 5\.24 ' "$SHELL_ROOT/SPEC.md" \
   && grep -qF '§3.7 | Context lifecycle: flush → clear → reconstruct' "$SHELL_ROOT/SPEC.md" \
   && grep -qF '§5.24 |' "$SHELL_ROOT/SPEC.md"; then
  ok "101b: SPEC §3.7 lifecycle + §5.24 /flush sections present in body and TOC (#387)"
else
  ng "101b: SPEC §3.7 / §5.24 heading or TOC row missing (#387)"
fi

# §101c: SPEC TOC is in sync (build_toc.sh --check passes) — adding the headings
# without regenerating the TOC must redden, same guarantee as §28.
if bash "$SHELL_ROOT/scripts/build_toc.sh" --check >/dev/null 2>&1; then
  ok "101c: SPEC TOC in sync after §3.7/§5.24 additions (#387)"
else
  ng "101c: SPEC TOC out of sync — rerun scripts/build_toc.sh (#387)"
fi

# ---------- 102. in-session narrowing levers: SPEC §1.8 + PostToolUse Read nudge (#389, Directive #386) ----------
# Doc→Test→Code: authored in the Test phase; §102b FAILS until the Code phase
# adds the Read arm to post_tool_use.sh. Anti-vacuity (smoke.sh header): §102a
# heading greps are caret-anchored; §102b/c drive the real hook and assert the
# nudge text on stderr (102b) AND its absence under offset/limit (102c) — a
# falsifiable pair, not a one-sided presence check.

# §102a: SPEC §1.8 narrowing-levers section + §6.2 Read-nudge row present, TOC in sync.
if grep -qE '^### 1\.8 In-session narrowing levers' "$SHELL_ROOT/SPEC.md" \
   && grep -qF '§1.8 | In-session narrowing levers' "$SHELL_ROOT/SPEC.md" \
   && grep -qE '\| `Read` of a whole file' "$SHELL_ROOT/SPEC.md" \
   && bash "$SHELL_ROOT/scripts/build_toc.sh" --check >/dev/null 2>&1; then
  ok "102a: SPEC §1.8 levers inventory + §6.2 Read-nudge row present, TOC in sync (#389)"
else
  ng "102a: SPEC §1.8 / §6.2 Read-nudge row missing or TOC out of sync (#389)"
fi

# Driver: pipe a synthetic Read tool_input through post_tool_use.sh from an
# in-scope cwd ($SHELL_ROOT), capturing stderr (the nudge surface) like post_run.
read_nudge_run() {
  local json_input="$1"
  (
    cd "$SHELL_ROOT" || exit 1
    # shellcheck disable=SC2069
    printf '{"tool_name":"Read","tool_input":%s}' "$json_input" \
      | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" bash "$SHELL_ROOT/.claude/hooks/post_tool_use.sh" 2>&1 >/dev/null
  )
}
# SPEC.md is a large (>200-line) in-scope file — the whole-file-load case.
S102_BIGFILE="$SHELL_ROOT/SPEC.md"

# §102b: whole-file Read (no offset/limit) on a large file → nudge fires, rc==0 (positive, non-blocking).
b_out=$(read_nudge_run "{\"file_path\":\"$S102_BIGFILE\"}"); b_rc=$?
if printf '%s' "$b_out" | grep -q 'Read --offset' && [ "$b_rc" = 0 ]; then
  ok "102b: whole-file Read nudges toward a targeted read, non-blocking (rc=0) (#389)"
else
  ng "102b: whole-file Read did not emit the targeted-read nudge at rc=0 (rc=$b_rc) (#389)"
fi

# §102c: falsifiability — the SAME large file Read WITH offset+limit must NOT nudge.
c_out=$(read_nudge_run "{\"file_path\":\"$S102_BIGFILE\",\"offset\":1,\"limit\":40}"); c_rc=$?
if ! printf '%s' "$c_out" | grep -q 'Read --offset' && [ "$c_rc" = 0 ]; then
  ok "102c: targeted Read (offset+limit) suppresses the nudge — guard is falsifiable (#389)"
else
  ng "102c: targeted Read still nudged (or non-zero rc=$c_rc) — guard not offset-aware (#389)"
fi

# ---------- §103 (#392): SPEC §8 directory tree drift-guard (flat-dir leaf counts) ----------
# SPEC §8's "Directory structure" block is authoritative. The four flat leaf-list
# directories (agents/, commands/, helpers/, docs/) are count-checked against disk,
# so a PR that adds/removes an agent/command/helper/doc without updating §8 is caught.
# templates/ and scripts/ carry summarized subtree nodes (leaves churn independently)
# — those are asserted present as text (node-presence), not leaf-counted.
#
# Parsing: slice the §8 fenced block (between the first ``` after the "## 8." heading
# and the next ```), then for each dir count the leaf lines between its node header
# and the next sibling node. awk reads files directly and uses range patterns with
# `exit` — no `... | head` pipe (which SIGPIPEs the upstream under pipefail and fails
# nondeterministically by size, GNU vs BSD). The dir-header line is excluded from its
# own range (consumed by `next`), so an annotation like "← 9 subagents" on the header
# can't be miscounted as a leaf.
S103_SPEC="$SHELL_ROOT/SPEC.md"
S103_BLOCK=$(awk '
  /^## 8\. Directory structure/ {ins=1}
  ins && /^## 9\./ {exit}
  ins
' "$S103_SPEC" | awk '
  /^```/ {fence++; next}
  fence==1 {print}
')

# s103_count <start_re> <end_re> <leaf_re>: count leaf lines strictly between the
# start-marker line (exclusive) and the first end-marker line (exclusive). An end_re
# that never matches counts through end-of-block (used for the last node, docs/).
s103_count() {
  printf '%s\n' "$S103_BLOCK" | awk -v sre="$1" -v ere="$2" -v lre="$3" '
    $0 ~ sre {inrange=1; next}
    inrange && $0 ~ ere {exit}
    inrange && $0 ~ lre {n++}
    END {print n+0}
  '
}

# Listed counts from the §8 block. Ranges delimited by the next sibling node:
#   agents/ → commands/ ; commands/ → hooks/ ; helpers/ → templates/ ; docs/ → EOF.
S103_A_SPEC=$(s103_count '├── agents/'   '├── commands/'  '\.md')
S103_C_SPEC=$(s103_count '├── commands/' '├── hooks/'     '\.md')
S103_H_SPEC=$(s103_count '└── helpers/'  '├── templates/' '\.sh')
S103_D_SPEC=$(s103_count '└── docs/'     '^```NEVER```'   '\.md')

# Actual disk counts. ls into wc — globs that match nothing degrade to 0.
s103_disk() { ls "$@" 2>/dev/null | wc -l | tr -d ' '; }
S103_A_DISK=$(s103_disk "$SHELL_ROOT"/.claude/agents/*.md)
S103_C_DISK=$(s103_disk "$SHELL_ROOT"/.claude/commands/*.md)
S103_H_DISK=$(s103_disk "$SHELL_ROOT"/.claude/hooks/helpers/*.sh)
S103_D_DISK=$(s103_disk "$SHELL_ROOT"/docs/*.md)

S103_DRIFT=""
[ "$S103_A_SPEC" = "$S103_A_DISK" ] || S103_DRIFT="$S103_DRIFT agents(§8=$S103_A_SPEC,disk=$S103_A_DISK)"
[ "$S103_C_SPEC" = "$S103_C_DISK" ] || S103_DRIFT="$S103_DRIFT commands(§8=$S103_C_SPEC,disk=$S103_C_DISK)"
[ "$S103_H_SPEC" = "$S103_H_DISK" ] || S103_DRIFT="$S103_DRIFT helpers(§8=$S103_H_SPEC,disk=$S103_H_DISK)"
[ "$S103_D_SPEC" = "$S103_D_DISK" ] || S103_DRIFT="$S103_DRIFT docs(§8=$S103_D_SPEC,disk=$S103_D_DISK)"

if [ -z "$S103_DRIFT" ]; then
  ok "103a: SPEC §8 flat-dir leaf counts match disk (agents/commands/helpers/docs) (#392)"
else
  ng "103a: SPEC §8 directory tree drifted from disk —$S103_DRIFT (#392)"
fi

# §103b: node-presence for the summarized subtrees (cheap, robust — text not counts).
# templates/ summarizes target-substrate/; scripts/ summarizes lib/ + test/.
if printf '%s\n' "$S103_BLOCK" | grep -qF 'target-substrate/' \
   && printf '%s\n' "$S103_BLOCK" | grep -qF 'lib/' \
   && printf '%s\n' "$S103_BLOCK" | grep -qF 'test/'; then
  ok "103b: SPEC §8 summarized subtree nodes present (target-substrate/, lib/, test/) (#392)"
else
  ng "103b: SPEC §8 missing a summarized subtree node (target-substrate/ / lib/ / test/) (#392)"
fi

# §103c: scripts/ TOP-LEVEL *.sh listing exactness + stale-count guard. Unlike the
# summarized lib//test/ nodes (103b, node-presence only), the top-level scripts ARE
# enumerated leaf-by-leaf in §8, so a script added/removed without a §8 edit must be
# caught. Slice the scripts/ node (├── scripts/ → next top-level sibling ├── workspace/)
# via the awk-range idiom, then RESTRICT to the top level by stopping at the lib/ node —
# so the deeper test/smoke.sh leaf never enters the listed set. Extract basenames, diff
# both directions against disk, and pin the "<N> top-level scripts" header integer.
S103C_SLICE=$(printf '%s\n' "$S103_BLOCK" | awk '
  /├── scripts\// {inrange=1}
  inrange && /│   ├── lib\// {exit}
  inrange
')
S103C_LISTED=$(printf '%s\n' "$S103C_SLICE" | grep -oE '[A-Za-z0-9_.-]+\.sh' | sort -u)
S103C_DISK=$(for f in "$SHELL_ROOT"/scripts/*.sh; do basename "$f"; done | sort -u)
S103C_LISTED_F=$(mktemp); S103C_DISK_F=$(mktemp)
printf '%s\n' "$S103C_LISTED" > "$S103C_LISTED_F"
printf '%s\n' "$S103C_DISK"   > "$S103C_DISK_F"
# comm -3: col1 = listed-only (in §8, not on disk); col2 = disk-only (on disk, not §8).
S103C_ONLY_SPEC=$(comm -23 "$S103C_LISTED_F" "$S103C_DISK_F" | tr '\n' ' ' | tr -s ' ')
S103C_ONLY_DISK=$(comm -13 "$S103C_LISTED_F" "$S103C_DISK_F" | tr '\n' ' ' | tr -s ' ')
rm -f "$S103C_LISTED_F" "$S103C_DISK_F"
S103C_HDR=$(printf '%s\n' "$S103C_SLICE" | grep -oE '[0-9]+ top-level scripts' | grep -oE '^[0-9]+')
S103C_NDISK=$(ls "$SHELL_ROOT"/scripts/*.sh 2>/dev/null | wc -l | tr -d ' ')
S103C_DRIFT=""
[ -z "$(printf '%s' "$S103C_ONLY_SPEC" | tr -d ' ')" ] || S103C_DRIFT="$S103C_DRIFT listed-not-on-disk:$S103C_ONLY_SPEC"
[ -z "$(printf '%s' "$S103C_ONLY_DISK" | tr -d ' ')" ] || S103C_DRIFT="$S103C_DRIFT on-disk-not-listed:$S103C_ONLY_DISK"
[ "$S103C_HDR" = "$S103C_NDISK" ] || S103C_DRIFT="$S103C_DRIFT count(§8=${S103C_HDR:-unparsed},disk=$S103C_NDISK)"
if [ -z "$S103C_DRIFT" ]; then
  ok "103c: SPEC §8 scripts/ top-level *.sh listing + count match disk (#473)"
else
  ng "103c: SPEC §8 scripts/ top-level listing drifted from disk —$S103C_DRIFT (#473)"
fi

# ---------- §104 (#396): always-on injection budget — CLAUDE.md pointer-index discipline ----------
# CLAUDE.md is injected into every session, so it is pure always-on cost. The
# rewrite (#396) turned it into a thin pointer index whose contracts live in full
# in SPEC; two guards keep it from re-bloating back into a second copy.
S104_CLAUDE="$SHELL_ROOT/.claude/CLAUDE.md"

# §104a (PRIMARY, mirror §91): every matcher/mechanism entry in the
# "## What hooks enforce" section must carry a `SPEC §` reference — so each pointer
# names its canonical home and cannot quietly grow into standalone contract prose.
# Scope to the section via heading anchors ("## What hooks enforce" → next "## ").
# Only `- ` bullet lines inside that range are checked (the intro + Escape paragraphs
# reference SPEC § too, but bullets are the matcher pointers we pin). awk reads the
# file directly and collects EVERY offending entry — no `... | head` pipe (which
# would SIGPIPE the upstream under `set -o pipefail` and fail by size, GNU vs BSD)
# and no first-failure short-circuit.
S104A_FAIL=$(awk '
  /^## What hooks enforce/ {ins=1; next}
  ins && /^## / {exit}
  ins && /^- / {
    if (index($0, "SPEC §") == 0) {
      # name the offending entry by its leading bold token if present, else the line
      tok = $0
      if (match($0, /\*\*[^*]+\*\*/)) tok = substr($0, RSTART+2, RLENGTH-4)
      print tok
    }
  }
' "$S104_CLAUDE")
if [ -z "$S104A_FAIL" ]; then
  ok "104a: every '## What hooks enforce' bullet in CLAUDE.md carries a SPEC § reference (#396)"
else
  ng "104a: CLAUDE.md 'What hooks enforce' bullets missing a SPEC § reference: $(printf '%s' "$S104A_FAIL" | tr '\n' ';') (#396)"
fi

# §104b (SECONDARY, mirror §103 numeric style): always-on byte ceiling. SPEC §9
# records a ≤12000-byte budget for the injected CLAUDE.md; over → re-bloat regression.
S104_BYTES=$(wc -c < "$S104_CLAUDE" 2>/dev/null | tr -d ' '); [ -z "$S104_BYTES" ] && S104_BYTES=0
if [ "$S104_BYTES" -le 12000 ]; then
  ok "104b: CLAUDE.md within the always-on injection budget — ${S104_BYTES} ≤ 12000 bytes (SPEC §9) (#396)"
else
  ng "104b: CLAUDE.md over the always-on injection budget — ${S104_BYTES} > 12000 bytes (SPEC §9 re-bloat) (#396)"
fi

# ---------- §105 (#398): friction-observability loop closure — SessionStart §6.5(d) advisory + §5.7.1 park→audit bridge ----------
# The §6.5(d) friction-candidate advisory is the consumer that completes §6.0 P3's
# deferred-positive-face loop: a once-per-session, non-blocking, fail-open, TTL-gated
# ONE-LINE pointer emitted by session_start.sh when the candidate readers surface a
# cluster OR the audit aggregate carries `unattended-park` records; suppressed when
# nothing clusters. §5.7.1 additionally bridges a fresh park into audit.jsonl via an
# `audit_log warn unattended-park parked` emit. All fixtures live in mktemp dirs and
# point the advisory's per-project audit read at a fixture via GHJIG_STATE_DIR_OVERRIDE
# / an explicit log path — the live $SHELL_ROOT state + audit log are never touched
# (§357 AC1 stays green). The advisory CODE is Phase C: 105b/d-advisory/e(ii,iii) are
# intended-RED until it lands; 105a (Doc) + the fail-open/exit-0 arm of 105d are green.

# §105a (Doc/TOC presence; green now — Phase A landed): SPEC §6.5(d) advisory contract
# present with its key tokens, §5.7.1 documents the additive unattended-park emit, and
# the TOC is fresh.
S105_SPEC="$SHELL_ROOT/SPEC.md"
if grep -q 'Friction-candidate advisory' "$S105_SPEC" \
   && grep -q 'SESSION_START_FRICTION_TTL' "$S105_SPEC" \
   && grep -q 'last-friction-surfaced' "$S105_SPEC" \
   && grep -q 'unattended-park' "$S105_SPEC" \
   && bash "$SHELL_ROOT/scripts/build_toc.sh" --check >/dev/null 2>&1; then
  ok "105a: SPEC §6.5(d) advisory contract + §5.7.1 unattended-park emit present, TOC fresh (#398)"
else
  ng "105a: SPEC §6.5(d)/§5.7.1 friction-loop contract incomplete or TOC stale (#398)"
fi

# Shared fake-root driver for 105b/c/d (mirror §30): a self-contained shell copy with
# its own git repo + registry, so session_start.sh reaches the §6.5(d) advisory block.
# The advisory reads the per-project audit aggregate via ghjig_state_dir; we point that
# at a per-call fixture state dir through GHJIG_STATE_DIR_OVERRIDE. A git shim no-ops the
# self-sync fetch so the run stays offline and fast.
S105_PROBE=$(mktemp -d)
S105_FAKE_ROOT="$S105_PROBE/shell"
mkdir -p "$S105_FAKE_ROOT/.claude/hooks/helpers" \
         "$S105_FAKE_ROOT/.claude/state" \
         "$S105_FAKE_ROOT/.claude/audit" \
         "$S105_FAKE_ROOT/scripts/lib"
cp "$SHELL_ROOT/.claude/hooks/session_start.sh" "$S105_FAKE_ROOT/.claude/hooks/"
cp "$SHELL_ROOT/.claude/hooks/hookrt.sh" "$S105_FAKE_ROOT/.claude/hooks/" 2>/dev/null
for h in log escape cwd_guard branch_guard; do
  cp "$SHELL_ROOT/.claude/hooks/helpers/$h.sh" "$S105_FAKE_ROOT/.claude/hooks/helpers/" 2>/dev/null
done
# Carry the candidate readers + their path lib so the advisory can invoke them in-root.
cp "$SHELL_ROOT/scripts/narrowing_candidates.sh" "$S105_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/promotion_candidates.sh" "$S105_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/ceremony_candidates.sh" "$S105_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/lib/audit_log_path.sh" "$S105_FAKE_ROOT/scripts/lib/" 2>/dev/null
: > "$S105_FAKE_ROOT/.claude/state/registry.txt"
(
  cd "$S105_FAKE_ROOT" || exit 1
  git init -q
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
)
S105_GIT_SHIM="$S105_PROBE/bin"
REAL_GIT_105=$(command -v git)
mkdir -p "$S105_GIT_SHIM"
cat > "$S105_GIT_SHIM/git" <<SHIM
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "fetch" ]; then exit 0; fi
done
exec '$REAL_GIT_105' "\$@"
SHIM
chmod +x "$S105_GIT_SHIM/git"

# run_friction_session <state-dir> <ttl> — drive session_start.sh against a fixture
# per-project state dir (its audit/audit.jsonl is the aggregate the advisory reads)
# and capture stdout (the advisory surfaces at SessionStart). Returns the captured
# text via stdout; exit status is the hook's.
run_friction_session() {
  (
    export GHJIG_ROOT_OVERRIDE="$S105_FAKE_ROOT"
    export PATH="$S105_GIT_SHIM:$PATH"
    # Point the ceremony reader (#401) at the fixture repo (only an empty init commit,
    # no ceremony groups) so it stays silent and does not scan the real repo's history.
    export CLAUDE_PROJECT_DIR="$S105_FAKE_ROOT"
    export GHJIG_STATE_DIR_OVERRIDE="$1"
    export SESSION_START_FRICTION_TTL="${2:-21600}"
    # keep the self-sync stamp fresh so only the friction path varies
    touch "$S105_FAKE_ROOT/.claude/state/last-shell-fetched" 2>/dev/null
    bash "$S105_FAKE_ROOT/.claude/hooks/session_start.sh" 2>/dev/null
  )
}

if [ ! -f "$S105_FAKE_ROOT/.claude/hooks/session_start.sh" ] || ! command -v jq >/dev/null 2>&1; then
  ng "105b: jq missing or fake-root setup failed — cannot drive the §6.5(d) advisory (#398)"
  ng "105c: jq missing or fake-root setup failed (#398)"
  ng "105d: jq missing or fake-root setup failed (#398)"
else
  # §105b (surfacing fires; RED until Code): a per-project audit log with an above-
  # threshold escape cluster (force-push, 2 distinct LIVE days — narrowing_candidates.sh
  # thresholds on >=2 distinct UTC days) + no friction stamp → the advisory line appears.
  S105B_STATE="$S105_PROBE/state-b"
  mkdir -p "$S105B_STATE/audit"
  cat > "$S105B_STATE/audit/audit.jsonl" <<'S105FIX'
{"ts":"2026-06-01T10:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
{"ts":"2026-06-02T11:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
S105FIX
  rm -f "$S105B_STATE/last-friction-surfaced"
  s105b_out=$(run_friction_session "$S105B_STATE" 21600)
  if printf '%s\n' "$s105b_out" | grep -qi 'friction'; then
    ok "105b: §6.5(d) advisory surfaces a one-line friction pointer on a clustered audit log (#398)"
  else
    ng "105b: §6.5(d) advisory did not surface on the clustered audit log — Phase C not yet landed (#398)"
  fi

  # §105c (suppressed — falsifiable twin): an audit log with NO above-threshold cluster
  # (a single force-push day → below threshold 2) and NO unattended-park records → no
  # advisory line. Pre-Code this may pass vacuously (nothing is emitted yet); its real
  # value is post-Code as the falsifiable companion to 105b. Robust absence assertion:
  # the captured text must not contain a friction pointer line.
  S105C_STATE="$S105_PROBE/state-c"
  mkdir -p "$S105C_STATE/audit"
  cat > "$S105C_STATE/audit/audit.jsonl" <<'S105FIX'
{"ts":"2026-06-01T10:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
S105FIX
  rm -f "$S105C_STATE/last-friction-surfaced"
  s105c_out=$(run_friction_session "$S105C_STATE" 21600)
  if printf '%s\n' "$s105c_out" | grep -qi 'friction'; then
    ng "105c: §6.5(d) advisory fired with NO above-threshold cluster (should be suppressed) (#398)"
  else
    ok "105c: §6.5(d) advisory stays silent when nothing clusters (falsifiable twin) (#398)"
  fi

  # §105d(i) (TTL-skip; RED until Code): clustered data BUT a fresh stamp (mtime now) →
  # the advisory is skipped (compute runs only when the stamp is stale/absent). Reuses
  # the 105b clustered fixture with a freshly-touched stamp.
  S105D_STATE="$S105_PROBE/state-d"
  mkdir -p "$S105D_STATE/audit"
  cp "$S105B_STATE/audit/audit.jsonl" "$S105D_STATE/audit/audit.jsonl"
  touch "$S105D_STATE/last-friction-surfaced"
  s105d_out=$(run_friction_session "$S105D_STATE" 21600)
  if printf '%s\n' "$s105d_out" | grep -qi 'friction'; then
    ng "105d(i): §6.5(d) advisory fired despite a fresh TTL stamp (should skip) (#398)"
  else
    ok "105d(i): §6.5(d) advisory honors the fresh last-friction-surfaced stamp (TTL-skip) (#398)"
  fi

  # §105d(ii) (fail-open / no-stall; holds regardless, partly inherent): an ABSENT audit
  # log (state dir exists, no audit.jsonl) with no stamp must not stall or crash —
  # session_start.sh still exits 0. Exercises the advisory path's degrade-to-silence arm.
  S105D2_STATE="$S105_PROBE/state-d2"
  mkdir -p "$S105D2_STATE"
  rm -f "$S105D2_STATE/last-friction-surfaced"
  run_friction_session "$S105D2_STATE" 21600 >/dev/null 2>&1; s105d2_rc=$?
  if [ "$s105d2_rc" = 0 ]; then
    ok "105d(ii): session_start exits 0 (fail-open, no stall) when the audit aggregate is absent (#398)"
  else
    ng "105d(ii): session_start did not exit 0 with an absent audit aggregate (rc=$s105d2_rc) (#398)"
  fi
fi
rm -rf "$S105_PROBE"

# §105e (park reaches audit + friction view): ship_park_pr on a FRESH park appends the
# human-readable park-log line (unchanged, additive contract) AND — Phase C — emits one
# `audit_log warn unattended-park parked "reason=<token>"` record into audit.jsonl, so
# park frequency becomes greppable as the §6.5(d) park-frequency signal. (ii)/(iii) are
# RED until the additive emit lands; (i) holds today. Run from a non-repo cwd so the
# `gh pr view` label check yields empty (no real PR) → the fresh-park arm.
if ! command -v jq >/dev/null 2>&1; then
  ng "105e(i): jq missing — cannot run the park→audit bridge check (#398)"
  ng "105e(ii): jq missing (#398)"
  ng "105e(iii): jq missing (#398)"
else
  S105E_DIR=$(mktemp -d)
  S105E_PARKLOG="$S105E_DIR/park.log"
  S105E_STATE="$S105E_DIR/ghjig-state"
  mkdir -p "$S105E_STATE/audit"
  (
    cd "$S105E_DIR" || exit 1
    export GHJIG_ROOT="$SHELL_ROOT"
    export GHJIG_STATE_DIR_OVERRIDE="$S105E_STATE"   # audit_log writes here
    export SHIP_PARK_LOG_PATH="$S105E_PARKLOG"     # park-log isolation seam
    # shellcheck source=/dev/null
    . "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null
    # shellcheck source=/dev/null
    . "$SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh" 2>/dev/null
    ship_park_pr ci-hard-blocker >/dev/null 2>&1
  )
  S105E_AUDIT="$S105E_STATE/audit/audit.jsonl"
  # (i) park-log line still appears (additive, unchanged).
  if [ -f "$S105E_PARKLOG" ] && grep -q 'parked reason=ci-hard-blocker' "$S105E_PARKLOG"; then
    ok "105e(i): ship_park_pr still writes the human-readable park-log line (additive) (#398)"
  else
    ng "105e(i): ship_park_pr did not write the expected park-log line (#398)"
  fi
  # (ii) an unattended-park/parked record landed in audit.jsonl (RED until Code).
  if [ -f "$S105E_AUDIT" ] \
     && grep -v '^[[:space:]]*$' "$S105E_AUDIT" \
        | jq -e 'select(.category=="unattended-park" and .decision=="parked")' >/dev/null 2>&1; then
    ok "105e(ii): fresh park emits an unattended-park/parked record into audit.jsonl (#398)"
  else
    ng "105e(ii): no unattended-park/parked audit record — §5.7.1 bridge not yet landed (#398)"
  fi
  # (iii) that record is greppable as the park-frequency signal the §6.5(d) advisory reads.
  if [ -f "$S105E_AUDIT" ] && grep -q 'unattended-park' "$S105E_AUDIT"; then
    ok "105e(iii): the park record is greppable as the park-frequency signal (#398)"
  else
    ng "105e(iii): park-frequency signal not greppable in audit.jsonl (#398)"
  fi
  rm -rf "$S105E_DIR"
fi

# ---------- §106 (#393): SPEC §9 specs exist for every referenced template ----------
# Contract-hygiene: directive.md / spec.md / readme_for_target.md are referenced
# in prose but historically lacked §9.x body-specs. Guard the three §9.6-9.8
# headings (presence only — cheap, stable) so they cannot silently regress, and
# confirm the TOC stays in sync after the heading additions.
if grep -qE '^### 9\.6 `directive\.md`'          "$SHELL_ROOT/SPEC.md" \
   && grep -qE '^### 9\.7 `spec\.md`'            "$SHELL_ROOT/SPEC.md" \
   && grep -qE '^### 9\.8 `readme_for_target\.md`' "$SHELL_ROOT/SPEC.md" \
   && bash "$SHELL_ROOT/scripts/build_toc.sh" --check >/dev/null 2>&1; then
  ok "106: SPEC §9.6/§9.7/§9.8 specs present for directive/spec/readme_for_target templates, TOC in sync (#393)"
else
  ng "106: SPEC §9 spec missing for a referenced template (directive/spec/readme_for_target) or TOC out of sync (#393)"
fi

# ---------- §107 (#401): ceremony mis-sizing audit consumer (measure-first) ----------
# scripts/ceremony_candidates.sh is a §6.5(d) friction reader that, unlike the two
# audit-log siblings, mines COMMIT HISTORY (the ceremony signal is not in audit.jsonl).
# It groups commits by #<issue> and surfaces both directions: under-ceremony (a feat
# group >1 file with no test/docs phase commit) and over-ceremony (a >=3-commit phase
# arc over a single file). 107a is Doc-phase (green now); 107b-f are RED until Code.

# 107a (Doc; green now — Phase A landed): SPEC §6.5(d) + §6.0 P3 name the reader, the
# scripts tree lists it, and CONFIG catalogs its env knobs.
if grep -q 'ceremony_candidates.sh' "$SHELL_ROOT/SPEC.md" \
   && grep -q 'Ceremony-mismatch line' "$SHELL_ROOT/SPEC.md" \
   && grep -q 'CEREMONY_LOOKBACK' "$SHELL_ROOT/docs/CONFIG.md" \
   && grep -q 'CEREMONY_MIN_COUNT' "$SHELL_ROOT/docs/CONFIG.md"; then
  ok "107a: SPEC §6.5(d)/§6.0 P3 name ceremony_candidates.sh + CONFIG catalogs its knobs (#401)"
else
  ng "107a: SPEC/CONFIG do not fully document the ceremony reader (#401)"
fi

S107_SCRIPT="$SHELL_ROOT/scripts/ceremony_candidates.sh"
if [ ! -f "$S107_SCRIPT" ]; then
  ng "107b: scripts/ceremony_candidates.sh missing — Code not yet landed (#401)"
  ng "107c: over-ceremony detection — script missing (#401)"
  ng "107d: well-sized omitted + clean sentinel + exit 0 — script missing (#401)"
  ng "107e: non-repo/absent dir graceful exit 0 — script missing (#401)"
  ng "107f: session_start.sh wires the reader into the §6.5(d) advisory — Code not landed (#401)"
else
  # Synthetic git fixture: three #<issue> groups exercising both flags + the well-sized
  # negative. Offline, local git only (mirror §105's init style).
  S107_DIR=$(mktemp -d)
  S107_REPO="$S107_DIR/repo"
  mkdir -p "$S107_REPO"
  (
    cd "$S107_REPO" || exit 1
    git init -q
    gc() { git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q "$@"; }
    # #901 under-ceremony: a feat over 2 files, no test/docs phase commit.
    printf 'a\n' > a.sh; printf 'b\n' > b.sh; git add a.sh b.sh; gc -m 'feat(#901): two-file feature, no phasing'
    # #902 over-ceremony: a docs+test+code arc, all over ONE file.
    printf '1\n' > tiny.sh; git add tiny.sh; gc -m 'docs(#902): tiny doc'
    printf '2\n' >> tiny.sh; git add tiny.sh; gc -m 'test(#902): tiny test'
    printf '3\n' >> tiny.sh; git add tiny.sh; gc -m 'feat(#902): tiny code'
    # #903 well-sized: a feat WITH test+docs phase commits over multiple files → omitted.
    printf 'f1\n' > f1.sh; printf 'f2\n' > f2.sh; git add f1.sh f2.sh; gc -m 'feat(#903): multi-file feature'
    printf 't\n' > t1.sh; git add t1.sh; gc -m 'test(#903): tests'
    printf 'd\n' > d1.md; git add d1.md; gc -m 'docs(#903): docs'
  )
  s107_out=$(bash "$S107_SCRIPT" "$S107_REPO" 2>/dev/null); s107_rc=$?

  # 107b: under-ceremony group #901 surfaced.
  if [ "$s107_rc" = 0 ] && printf '%s\n' "$s107_out" | grep -q '901' \
     && printf '%s\n' "$s107_out" | grep -qi 'under'; then
    ok "107b: surfaces the under-ceremony #901 cluster (feat, >1 file, no phase commit) (#401)"
  else
    ng "107b: did not surface the under-ceremony #901 cluster (rc=$s107_rc) (#401)"
  fi
  # 107c: over-ceremony group #902 surfaced.
  if printf '%s\n' "$s107_out" | grep -q '902' && printf '%s\n' "$s107_out" | grep -qi 'over'; then
    ok "107c: surfaces the over-ceremony #902 cluster (phase arc over a single file) (#401)"
  else
    ng "107c: did not surface the over-ceremony #902 cluster (#401)"
  fi
  # 107d: well-sized #903 omitted; clean repo → sentinel; exit 0; output is the indented
  # cluster shape the §6.5(d) grep keys on.
  s107_clean=$(mktemp -d)
  ( cd "$s107_clean" && git init -q && git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m 'chore: init' )
  s107_clean_out=$(bash "$S107_SCRIPT" "$s107_clean" 2>/dev/null); s107_clean_rc=$?
  if ! printf '%s\n' "$s107_out" | grep -q '903' \
     && printf '%s\n' "$s107_out" | grep -qE '^[[:space:]]+.+\|.+=' \
     && [ "$s107_clean_rc" = 0 ] \
     && printf '%s\n' "$s107_clean_out" | grep -qi 'none'; then
    ok "107d: omits the well-sized #903 group, emits the grep-shaped cluster + clean sentinel, exit 0 (#401)"
  else
    ng "107d: well-sized group leaked, wrong output shape, or no clean sentinel (clean_rc=$s107_clean_rc) (#401)"
  fi
  # 107e: a non-repo dir and an absent dir both degrade to silence, exit 0 (fail-open).
  bash "$S107_SCRIPT" "$S107_DIR" >/dev/null 2>&1; s107_e1=$?     # exists, not a git repo
  bash "$S107_SCRIPT" "$S107_DIR/nope" >/dev/null 2>&1; s107_e2=$? # absent
  if [ "$s107_e1" = 0 ] && [ "$s107_e2" = 0 ]; then
    ok "107e: degrades to exit 0 on a non-repo dir and an absent dir (fail-open) (#401)"
  else
    ng "107e: crashed on non-repo/absent dir (non-repo=$s107_e1 absent=$s107_e2) (#401)"
  fi
  # 107f: the §6.5(d) advisory invokes the reader (Code wires it into session_start.sh).
  if grep -q 'ceremony_candidates.sh' "$SHELL_ROOT/.claude/hooks/session_start.sh"; then
    ok "107f: session_start.sh wires ceremony_candidates.sh into the friction advisory (#401)"
  else
    ng "107f: session_start.sh does not invoke ceremony_candidates.sh — advisory not wired (#401)"
  fi
  rm -rf "$S107_DIR" "$s107_clean"
fi

# ---------- §108 (#403): commit-arm does not false-positive on heredoc DATA ----------
# The protected-branch commit sub-arm (pre_tool_use.sh:894) must enter on a REAL
# `git commit` invocation, NOT on the bytes "git commit" inside a heredoc DATA body
# (e.g. `gh issue edit --body "$(cat <<'EOF' ... git commit ... EOF)"`, the real #403
# trigger). The entry uses strip_command_data HEREDOC mode (matching clean :198 /
# merge :333) — under-block-safe, because bash executes command substitutions inside
# double quotes, so `full` mode (which strips quoted interiors) would HIDE a real
# `"$(git commit)"` from the grep while bash still runs it. 108a: heredoc-body
# false-positive allowed (RED pre-fix). 108b/108c: no-under-block guards (a real
# plain commit AND a real commit inside a double-quoted substitution both still block).
if ! command -v jq >/dev/null 2>&1; then
  ng "108a: jq missing — cannot drive the commit-arm DATA test (#403)"
  ng "108b: jq missing (#403)"
else
  S108_DIR=$(mktemp -d)
  S108_TARGET="$S108_DIR/target"
  mkdir -p "$S108_TARGET"
  S108_TARGET=$(cd "$S108_TARGET" && pwd -P)
  (cd "$S108_TARGET" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; })
   git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
  printf '%s\n' "$S108_TARGET" >> "$SMOKE_REG"

  s108_bash_run() {
    local cmd="$1"
    ( cd "$S108_TARGET" || exit 1
      jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 )
    return $?
  }

  # 108a: a gh-issue-edit whose --body carries the git+commit token inside a HEREDOC
  #       body, run on the protected (main) fixture → must be ALLOWED (rc=0). The
  #       real #403 trigger. RED pre-fix.
  sq="'"
  s108_data_cmd="gh issue edit 1 --body \"\$(cat <<${sq}EOF${sq}
prose that merely mentions a git commit invocation inside a heredoc body
EOF
)\""
  s108_bash_run "$s108_data_cmd"; s108a_rc=$?
  if [ "$s108a_rc" = 0 ]; then
    ok "108a: commit arm ignores 'git commit' inside a heredoc --body (no false-positive) (#403)"
  else
    ng "108a: commit arm false-positives on 'git commit' in a heredoc --body (rc=$s108a_rc, want 0) (#403)"
  fi

  # 108b (no under-block): a REAL plain commit on the protected branch still blocks (rc=2).
  s108_real_cmd="git commit -m 'feat(#403): real subject'"
  s108_bash_run "$s108_real_cmd"; s108b_rc=$?
  if [ "$s108b_rc" = 2 ]; then
    ok "108b: a real plain git commit on a protected branch still blocks (no under-block) (#403)"
  else
    ng "108b: real protected-branch commit not blocked (rc=$s108b_rc, want 2) (#403)"
  fi

  # 108c (no under-block — the security-review case): a real commit inside a
  #       DOUBLE-QUOTED command substitution still blocks (rc=2). heredoc mode leaves
  #       "$(...)" intact, so the grep still sees the live invocation; `full` mode
  #       would have stripped it and let a real protected-branch commit slip (rc=0).
  s108_subst_cmd='echo "$(git commit --allow-empty -m sneaky)"'
  s108_bash_run "$s108_subst_cmd"; s108c_rc=$?
  if [ "$s108c_rc" = 2 ]; then
    ok "108c: a real commit inside a double-quoted \$() substitution still blocks (no under-block) (#403)"
  else
    ng "108c: commit in double-quoted \$() slipped past the protected-branch gate (rc=$s108c_rc, want 2) (#403)"
  fi
  rm -rf "$S108_DIR"
fi

# ---------- §109 (#404): is_trusted_filer resolves trust portably across gh --json support ----------
# Reproduce-first: on a gh version that REJECTS `gh issue view --json authorAssociation`
# (Unknown JSON field) but serves `gh api .../issues/N -q .author_association`, the helper
# must still resolve trust. 109a is RED until the helper switches to the gh api form.
# 109b is the park guard: a genuinely unresolvable gh (both forms fail) returns non-zero.
if ! command -v jq >/dev/null 2>&1; then
  ng "109a: jq missing — cannot run the trust-portability check (#404)"
  ng "109b: jq missing (#404)"
else
  S109_DIR=$(mktemp -d)
  S109_SHIM="$S109_DIR/bin"; mkdir -p "$S109_SHIM"
  S109_STATE="$S109_DIR/state"; mkdir -p "$S109_STATE"
  printf 'OWNER\n' > "$S109_STATE/aa_100"   # #100 → OWNER via the api form
  # Stub gh: repo view resolves owner/name; `issue view --json authorAssociation` is
  # REJECTED (the unsupported-field gh version); `api .../issues/N` serves author_association.
  cat > "$S109_SHIM/gh" <<'SHIM'
#!/bin/sh
args="$*"
case "$args" in
  *"--json owner"*) printf 'mock\n'; exit 0 ;;
  *"--json name"*)  printf 'repo\n'; exit 0 ;;
  *"issue view"*"--json authorAssociation"*)
    echo 'Unknown JSON field: "authorAssociation"' >&2; exit 1 ;;
  *"api "*"/issues/"*)
    n=$(printf '%s\n' "$args" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    [ -n "$n" ] && [ -f "$GH109_STATE/aa_$n" ] && cat "$GH109_STATE/aa_$n"
    exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$S109_SHIM/gh"
  # Cache isolation: is_trusted_filer caches via ghjig_state_dir; pin it to a FRESH
  # per-call dir so a §55-seeded fixture can't satisfy the lookup without a gh query.
  S109_ES="$S109_DIR/es"

  # 109a: OWNER resolves trusted (rc=0) even though `issue view --json authorAssociation`
  #       is rejected — i.e. resolution goes through the portable api form. RED pre-fix.
  rm -rf "$S109_ES"
  s109a_rc=$(
    PATH="$S109_SHIM:$PATH" GH109_STATE="$S109_STATE" GHJIG_ROOT="$SHELL_ROOT" \
    GHJIG_STATE_DIR_OVERRIDE="$S109_ES" \
    bash -c '. "$GHJIG_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null
             . "$GHJIG_ROOT/.claude/hooks/helpers/issue_filer.sh" 2>/dev/null
             is_trusted_filer 100; echo $?' | tail -1
  )
  if [ "$s109a_rc" = 0 ]; then
    ok "109a: is_trusted_filer resolves OWNER via gh api despite --json authorAssociation being rejected (#404)"
  else
    ng "109a: trust unresolved (rc=$s109a_rc) — helper still depends on --json authorAssociation (#404)"
  fi

  # 109b (park guard): a gh where BOTH forms fail → is_trusted_filer returns non-zero
  #      (so /activate's "unresolvable → park" guard holds; never a false "trusted").
  cat > "$S109_SHIM/gh" <<'SHIM'
#!/bin/sh
args="$*"
case "$args" in
  *"--json owner"*) printf 'mock\n'; exit 0 ;;
  *"--json name"*)  printf 'repo\n'; exit 0 ;;
esac
exit 1
SHIM
  chmod +x "$S109_SHIM/gh"
  rm -rf "$S109_ES"
  s109b_rc=$(
    PATH="$S109_SHIM:$PATH" GH109_STATE="$S109_STATE" GHJIG_ROOT="$SHELL_ROOT" \
    GHJIG_STATE_DIR_OVERRIDE="$S109_ES" \
    bash -c '. "$GHJIG_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null
             . "$GHJIG_ROOT/.claude/hooks/helpers/issue_filer.sh" 2>/dev/null
             is_trusted_filer 100; echo $?' | tail -1
  )
  if [ "$s109b_rc" != 0 ]; then
    ok "109b: an unresolvable gh returns non-zero (park guard holds; no false trusted) (#404)"
  else
    ng "109b: unresolvable gh wrongly resolved trusted (rc=$s109b_rc) (#404)"
  fi
  rm -rf "$S109_DIR"
fi

# ---------- §357 AC1: live shared sinks untouched by the run ----------
# A smoke run must add ZERO lines to the live audit log and ZERO entries to the
# live scope registry (MISSION "shared code, per-project state" isolation, #357).
# Reads the same LIVE $SHELL_ROOT paths snapshotted at startup — NOT $SMOKE_*,
# else the assertion would be vacuous (it would compare the isolated dir to
# itself). On pre-#357 code this FAILS (fixture fires append to the live audit);
# after the whole-run override it passes (every fire resolves to $SMOKE_STATE).
s357_audit_after=0; [ -f "$S357_LIVE_AUDIT" ] && s357_audit_after=$(wc -l < "$S357_LIVE_AUDIT" | tr -d ' ')
s357_reg_after=0; [ -f "$S357_LIVE_REG" ] && s357_reg_after=$(wc -l < "$S357_LIVE_REG" | tr -d ' ')
if [ "$s357_audit_after" = "$s357_audit_before" ] && [ "$s357_reg_after" = "$s357_reg_before" ]; then
  ok "357: smoke run left the live audit log + scope registry untouched (#357)"
else
  ng "357: smoke polluted live sinks — audit Δ=$((s357_audit_after - s357_audit_before)) registry Δ=$((s357_reg_after - s357_reg_before)) (#357)"
fi

# ---------- §111: /recall episodic-retrieval skill contract (#422) ----------
# Placed before §110 because §110 (the README floor guard) runs last by design.
# Static greps on the helper + command — no network: the pointers-only and cap
# guarantees are STRUCTURAL (field projection + a code cap), so they are pinned
# by inspecting the source, not by a live gh round-trip.
s111_helper="$SHELL_ROOT/.claude/hooks/helpers/recall.sh"
s111_cmd="$SHELL_ROOT/.claude/commands/recall.md"
s111=1; s111_why=""
if [ ! -f "$s111_helper" ]; then
  s111=0; s111_why="${s111_why}helper-missing;"
else
  # (a) pointers-only: projects number,title and NEVER projects a body field
  grep -q -- '--json number,title' "$s111_helper" || { s111=0; s111_why="${s111_why}no-number-title-projection;"; }
  grep -qE -- '--json[[:space:]]+[A-Za-z,]*body' "$s111_helper" && { s111=0; s111_why="${s111_why}body-projected;"; }
  # (b) bounded: RECALL_LIMIT default 5 + --limit honored
  grep -qE 'RECALL_LIMIT:-5' "$s111_helper" || { s111=0; s111_why="${s111_why}cap-default-not-5;"; }
  grep -q -- '--limit' "$s111_helper" || { s111=0; s111_why="${s111_why}no-limit-flag;"; }
  # (c) decision-record coverage: issues + PRs + ADRs arms
  grep -q 'gh search issues' "$s111_helper" || { s111=0; s111_why="${s111_why}no-issues-arm;"; }
  grep -q 'gh search prs' "$s111_helper" || { s111=0; s111_why="${s111_why}no-prs-arm;"; }
  grep -q 'docs/ADRs' "$s111_helper" || { s111=0; s111_why="${s111_why}no-adr-arm;"; }
  # (d) fail-open: a record-unavailable fallback line exists
  grep -q 'decision record unavailable' "$s111_helper" || { s111=0; s111_why="${s111_why}no-fail-open;"; }
  # (f) AC4 (#524) — deep tier is pointers-only STRUCTURALLY: it may project
  # `--json comments` to reach a comment body, but the matched comment TEXT is a
  # PREDICATE never a PRINTER. Pin it two ways: (i) the deep grep must feed a test
  # (`grep -qF` / `grep -Fq`) not a raw `grep -F` whose stdout is the body, and
  # (ii) inside the `--deep`-gated region the emitted line is only the `#<n> title`
  # pointer shape. RED now: no deep branch exists → no comments projection.
  grep -qE -- '--json[[:space:]]+[A-Za-z,]*comments' "$s111_helper" || { s111=0; s111_why="${s111_why}no-deep-comments-projection;"; }
  grep -qE 'grep[[:space:]]+-([A-Za-z]*q[A-Za-z]*F|[A-Za-z]*F[A-Za-z]*q)' "$s111_helper" || { s111=0; s111_why="${s111_why}deep-grep-not-predicate;"; }
fi
# (e) command file delegates to the helper
grep -q 'recall_pointers' "$s111_cmd" 2>/dev/null || { s111=0; s111_why="${s111_why}cmd-no-delegate;"; }
if [ "$s111" = 1 ]; then
  ok "111: /recall helper is pointers-only (number,title, no body projection) + bounded (RECALL_LIMIT=5) + covers issues/prs/ADRs + fail-open (#422) + deep tier is pointers-only (comment grep is a predicate, not a printer) (#524)"
else
  ng "111: /recall contract violated:$s111_why (#422)"
fi

# ---------- §112: enforcement-matcher mutation harness contract (#423) ----------
# Placed before §110 (the README floor guard, which runs last by design). Static
# greps on scripts/test/mutation.sh — the harness itself runs full smoke per
# mutant, so it is a SEPARATE CI job, not invoked from inside smoke (no recursion).
# Here we only pin that the harness exists, seeds the three highest-cost matcher
# mutations (§6.0), and isolates each in a git worktree (never mutates the live tree).
s112_mut="$SHELL_ROOT/scripts/test/mutation.sh"
s112=1; s112_why=""
if [ ! -f "$s112_mut" ]; then
  s112=0; s112_why="${s112_why}harness-missing;"
else
  grep -q 'check_commit_subject' "$s112_mut"     || { s112=0; s112_why="${s112_why}no-commit-format-mutant;"; }
  grep -q 'scan_staged_secrets' "$s112_mut"       || { s112=0; s112_why="${s112_why}no-secret-mutant;"; }
  grep -q 'PROTECTED_BRANCH_PATTERN' "$s112_mut"  || { s112=0; s112_why="${s112_why}no-protected-branch-mutant;"; }
  grep -q 'git worktree add' "$s112_mut"          || { s112=0; s112_why="${s112_why}no-worktree-isolation;"; }
  grep -q '"\$wt/scripts/test/smoke.sh"' "$s112_mut" || { s112=0; s112_why="${s112_why}no-worktree-smoke-run;"; }
fi
if [ "$s112" = 1 ]; then
  ok "112: mutation harness exists, seeds commit-format/secret/protected-branch mutants, worktree-isolated (#423)"
else
  ng "112: mutation harness contract violated:$s112_why (#423)"
fi

# ---------- §113: /replan-check divergence checkpoint contract (#427) ----------
# Placed before §110 (README floor, runs last by design). Static greps on the
# command + helper — the divergence JUDGMENT is LLM (uncheckable here); these pin
# the contract surface: the discriminator phrases, helper delegation, the
# mechanical-facts + fail-open helper shape, and the /sync-pr reference.
s113_cmd="$SHELL_ROOT/.claude/commands/replan-check.md"
s113_helper="$SHELL_ROOT/.claude/hooks/helpers/replan_check.sh"
s113_sync="$SHELL_ROOT/.claude/commands/sync-pr.md"
s113=1; s113_why=""
if [ ! -f "$s113_cmd" ]; then
  s113=0; s113_why="${s113_why}command-missing;"
else
  grep -qi 'structural' "$s113_cmd"            || { s113=0; s113_why="${s113_why}no-structural-term;"; }
  grep -qiE 'cosmetic|mechanical' "$s113_cmd"  || { s113=0; s113_why="${s113_why}no-cosmetic-clause;"; }
  grep -qiE 'unreachable|reachab' "$s113_cmd"  || { s113=0; s113_why="${s113_why}no-ac-reachability;"; }
  grep -q 'replan_check' "$s113_cmd"           || { s113=0; s113_why="${s113_why}cmd-no-delegate;"; }
fi
if [ ! -f "$s113_helper" ]; then
  s113=0; s113_why="${s113_why}helper-missing;"
else
  grep -q 'git diff --name-only' "$s113_helper" || { s113=0; s113_why="${s113_why}no-touched-files-fact;"; }
  grep -qi 'unavailable' "$s113_helper"          || { s113=0; s113_why="${s113_why}no-fail-open;"; }
fi
grep -q 'replan-check' "$s113_sync" 2>/dev/null || { s113=0; s113_why="${s113_why}sync-pr-no-ref;"; }
if [ "$s113" = 1 ]; then
  ok "113: /replan-check declares the structural-vs-cosmetic discriminator + AC-reachability, delegates to a fail-open mechanical-facts helper, and is referenced by /sync-pr (#427)"
else
  ng "113: /replan-check contract violated:$s113_why (#427)"
fi

# ---------- §114: high-asymmetry reviewer tier (#428) ----------
# Placed before §110 (README floor, runs last). The classifier is pure shell
# (no external calls), so the rc-per-kind + off-list falsifiability arm run
# offline by sourcing it directly. The fan-out itself is skill prose (LLM) —
# grep-locked on /ship + /complete-directive + the SPEC §4.11 contract.
s114_helper="$SHELL_ROOT/.claude/hooks/helpers/blast_radius.sh"
s114=1; s114_why=""
if [ ! -f "$s114_helper" ]; then
  s114=0; s114_why="${s114_why}helper-missing;"
else
  # shellcheck source=/dev/null
  . "$s114_helper"
  if command -v is_high_asymmetry >/dev/null 2>&1; then
    for k in merge-security-surface force-push directive-completion irreversible-adr; do
      is_high_asymmetry "$k" 2>/dev/null || { s114=0; s114_why="${s114_why}$k-not-flagged;"; }
    done
    # falsifiability arm: an off-list kind must NOT be flagged (closed set, AC1)
    is_high_asymmetry "ordinary-merge" 2>/dev/null && { s114=0; s114_why="${s114_why}off-list-flagged;"; }
  else
    s114=0; s114_why="${s114_why}no-is_high_asymmetry-fn;"
  fi
fi
grep -qiE 'high-asymmetry|is_high_asymmetry' "$SHELL_ROOT/.claude/commands/ship.md" 2>/dev/null || { s114=0; s114_why="${s114_why}ship-no-tier;"; }
grep -qiE 'high-asymmetry|is_high_asymmetry' "$SHELL_ROOT/.claude/commands/complete-directive.md" 2>/dev/null || { s114=0; s114_why="${s114_why}complete-directive-no-tier;"; }
grep -q '### 4.11 High-asymmetry reviewer tier' "$SHELL_ROOT/SPEC.md" 2>/dev/null || { s114=0; s114_why="${s114_why}no-spec-4.11;"; }
if [ "$s114" = 1 ]; then
  ok "114: is_high_asymmetry flags the closed set (not off-list) + /ship & /complete-directive carry the N-way tier + SPEC §4.11 (#428)"
else
  ng "114: high-asymmetry reviewer tier contract violated:$s114_why (#428)"
fi

# ---------- §115: ghjig_commit slot-assembly helper (#436) ----------
# Behavioral, offline: exercise ghjig_commit against a throwaway git repo (no
# network, no PreToolUse hook — the internal `git commit` is a subprocess of
# this script). Pins: reject-before-commit, happy-path subject hook-visible
# (extract+check accept it, NOT the -F bypass), and multibyte/multi-paragraph
# body round-trip.
s115_helper="$SHELL_ROOT/.claude/hooks/helpers/ghjig_commit.sh"
if [ ! -f "$s115_helper" ]; then
  ng "115: ghjig_commit.sh missing (#436)"
else
  # shellcheck source=/dev/null
  . "$s115_helper"
  if ! command -v ghjig_commit >/dev/null 2>&1; then
    ng "115: ghjig_commit function not defined after sourcing (#436)"
  else
    s115_tmp=$(mktemp -d)
    git -C "$s115_tmp" init -q
    git -C "$s115_tmp" config user.email smoke@example.com
    git -C "$s115_tmp" config user.name smoke
    git -C "$s115_tmp" config commit.gpgsign false   # isolate from a global signing config
    printf 'x\n' > "$s115_tmp/f"
    git -C "$s115_tmp" add f
    s115_long=$(python3 -c 'print("a"*73)' 2>/dev/null || printf 'a%.0s' $(seq 1 73))
    s115=1; s115_why=""

    # (a) reject-before-commit: a 73-char subject must error nonzero AND create no commit
    ( cd "$s115_tmp" && ghjig_commit feat 5 "$s115_long" ) >/dev/null 2>&1 \
      && { s115=0; s115_why="${s115_why}overlong-not-rejected;"; }
    if git -C "$s115_tmp" rev-parse HEAD >/dev/null 2>&1; then
      s115=0; s115_why="${s115_why}committed-despite-reject;"
    fi

    # (b) happy path: valid slots commit; the subject is hook-visible (extract+check accept it)
    if ( cd "$s115_tmp" && ghjig_commit feat 5 "add the thing" "본문 한국어 단락 첫 줄" ) >/dev/null 2>&1; then
      s115_subj=$(git -C "$s115_tmp" log -1 --format=%s)
      s115_xs=$(extract_commit_subject "git commit -m \"$s115_subj\"" "git commit -m \"$s115_subj\"")
      check_commit_subject "$s115_xs" >/dev/null 2>&1 || { s115=0; s115_why="${s115_why}subject-not-hook-accepted;"; }
      # (c) multibyte body round-trips intact
      git -C "$s115_tmp" log -1 --format=%B | grep -q '본문 한국어 단락 첫 줄' || { s115=0; s115_why="${s115_why}body-not-roundtripped;"; }
    else
      s115=0; s115_why="${s115_why}valid-commit-failed;"
    fi

    rm -rf "$s115_tmp"
    if [ "$s115" = 1 ]; then
      ok "115: ghjig_commit rejects-before-commit on overlong subject + happy-path subject is hook-accepted + multibyte body round-trips (#436)"
    else
      ng "115: ghjig_commit contract violated:$s115_why (#436)"
    fi
  fi
fi

# ---------- §116: SPEC §1.9 harness-overlap coverage parity (#450) ----------
# Placed before §110 (the README floor guard, which runs last by design). The
# §1.9 classification must carry exactly one posture row per enumerated mechanism
# in §1.8 (narrowing levers) + §4 (subagents) + §5 (slash commands) + §6.1 (hook
# matchers). NON-VACUOUS by construction: the expected total is four INDEPENDENTLY
# machine-derived counts (the same derivations §74a/§74b already trust), the actual
# count is §1.9 table rows whose posture cell carries a BACKTICKED posture token —
# the code form, so prose mentioning "cede to harness" without backticks does NOT
# match (anti-vacuity #1) — and the `-gt 0` count-guard fails loud on a §1.9
# rename / empty table (anti-vacuity #2). A mechanism added to any of the four
# families bumps the expected total and trips this guard until a §1.9 row is added.
s116_spec="$SHELL_ROOT/SPEC.md"
s116_levers=$(awk '/^### 1\.8 /{i=1;next} /^### 1\.9 /{exit} i&&/^\| \*\*/{n++} END{print n+0}' "$s116_spec")
s116_agents=$(ls "$SHELL_ROOT"/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
s116_cmds=$(grep -cE '^### 5\.[0-9]+ `/' "$s116_spec")
s116_hooks=$(grep -oE 'should_skip [a-z-]+' "$SHELL_ROOT"/.claude/hooks/pre_tool_use.sh | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
s116_exp=$((s116_levers + s116_agents + s116_cmds + s116_hooks))
s116_rows=$(awk '/^### 1\.9 /{i=1;next} /^## 2\. /{exit} i' "$s116_spec" \
            | grep -E '^\|' | grep -cE '`(cede-to-harness|keep-as-policy|keep-as-safety-redundancy)`')
if [ "$s116_rows" -gt 0 ] && [ "$s116_rows" = "$s116_exp" ]; then
  ok "116: SPEC §1.9 classifies all $s116_exp enumerated mechanisms (parity, #450)"
else
  ng "116: SPEC §1.9 coverage parity drift — classified=$s116_rows expected=$s116_exp (levers=$s116_levers agents=$s116_agents cmds=$s116_cmds hooks=$s116_hooks) (#450)"
fi

# ---------- §117: command docs use -F (not -f) for gh api stdin/file body (#452) ----------
# Placed before §110 (the README floor guard, which runs last by design). `gh api
# -f field=@-` sets the LITERAL string "@-" — only `-F field=@-` reads stdin/file.
# A command doc teaching the lowercase form silently corrupts the artifact it writes
# (hit live: /reflect's enrich-in-place PATCH wrote "@-" into a Directive comment).
# The legitimate graphql `-f query=<string>` form has no `=@`, so anchoring on `=@`
# is precise. NON-VACUOUS: a file-count guard fails loud if the commands glob is
# empty (rather than greening on nothing scanned).
s117_files=$(ls "$SHELL_ROOT"/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
s117_bad=$(grep -rlE '\-f [a-zA-Z_]+=@' "$SHELL_ROOT"/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$s117_files" -gt 0 ] && [ "$s117_bad" = 0 ]; then
  ok "117: no .claude/commands/*.md teaches the broken 'gh api -f <field>=@' form (use -F for stdin/file) (#452)"
else
  ng "117: broken 'gh api -f <field>=@' (literal, not stdin) in commands docs — use -F (files=$s117_files bad=$s117_bad) (#452)"
fi

# ---------- §118: shared onboard_checks.sh fact-reporter (#456) ----------
# Phase B (Test). Drives the FORTHCOMING shared mechanical-check script
# scripts/lib/onboard_checks.sh (Execution #456, Directive #454) headlessly: a
# stubbed `gh` on PATH + a temp target dir, asserting the emitted `<check> <status>`
# token for each of the five mechanical checks. The script is the single source the
# later scripts/setup.sh and /onboard both call, so the contract under test here is
# the line protocol they consume:
#   <check-name>  ok|fail  <one-line detail>      (one line per check, ALWAYS exit 0)
# Check names: upstream, permission, ssot:MISSION.md, ssot:SPEC.md, branch-protect, ci.
# The script reaches gh via $PATH (so the shim drives it) and supports --dry-run; it
# REPORTS facts, never gates — every invocation exits 0, even when the branch-protect
# `gh api .../protection` probe errors (non-admin 404/403).
#
# Shim design: one `gh` script serves every sub-case, keyed on state files under
# $S118_STATE. `gh repo view --json isFork`/`--json viewerPermission` answer
# upstream/permission; `gh api .../protection` exits 0 (protected) or non-zero
# (absent/unreadable) per a flag file. SSOT + CI are pure filesystem facts (no gh).
#
# RED until Phase C: with scripts/lib/onboard_checks.sh absent, the guard below
# fails LOUD on every planned assertion (mirrors §107's script-absent pattern) —
# a clean intended failure, not a harness error.
S118_SCRIPT="$SHELL_ROOT/scripts/lib/onboard_checks.sh"
if [ ! -f "$S118_SCRIPT" ]; then
  ng "118a: upstream fork→fail / non-fork→ok — scripts/lib/onboard_checks.sh missing (Phase C not landed) (#456)"
  ng "118b: permission READ→fail / WRITE→ok — script missing (#456)"
  ng "118c: ssot:SPEC.md absent→fail / present→ok (SPEC unconditionally expected) — script missing (#456)"
  ng "118d: ssot:MISSION.md absent→fail / present→ok — script missing (#456)"
  ng "118e: branch-protect present→ok / absent-or-gh-api-error→fail, still exit 0 — script missing (#456)"
  ng "118f: ci .github/workflows present→ok / absent→fail — script missing (#456)"
else
  S118_DIR=$(cd "$(mktemp -d)" && pwd -P)
  S118_SHIM="$S118_DIR/bin"
  S118_STATE="$S118_DIR/state"
  mkdir -p "$S118_SHIM" "$S118_STATE"
  cat > "$S118_SHIM/gh" <<'SHIM'
#!/bin/sh
# Smoke shim for onboard_checks.sh. State files under $S118_STATE drive each answer:
#   isfork     → printed for `gh repo view --json isFork`   (true|false)
#   permission → printed for `gh repo view --json viewerPermission` (READ|WRITE|…)
#   protected  → present ⇒ `gh api .../protection` succeeds; absent ⇒ it errors (non-admin).
case "$*" in
  *"repo view"*"isFork"*)            cat "$S118_STATE/isfork" 2>/dev/null ;;
  *"repo view"*"viewerPermission"*)  cat "$S118_STATE/permission" 2>/dev/null ;;
  *"api"*"protection"*)
    if [ -f "$S118_STATE/protected" ]; then
      printf '{"required_pull_request_reviews":{}}\n'      # protected → success
    else
      echo '{"message":"Not Found"}' >&2; exit 1           # non-admin / absent → error
    fi
    ;;
esac
exit 0
SHIM
  chmod +x "$S118_SHIM/gh"

  # s118_run <target-dir> → echoes the script's stdout; sets s118_rc to its exit code.
  # gh is reached via PATH (shim first); the script runs from the target's cwd.
  s118_run() {
    s118_out=$(
      cd "$1" || exit 99
      PATH="$S118_SHIM:$PATH" S118_STATE="$S118_STATE" bash "$S118_SCRIPT" 2>/dev/null
    ); s118_rc=$?
  }
  # Extract the status token (field 2) for a given check name (field 1) from output.
  s118_status() { printf '%s\n' "$s118_out" | awk -v c="$1" '$1==c{print $2; exit}'; }

  # Two target dirs: a "bare" repo (no SSOT, no CI) and a "full" one (SPEC, MISSION,
  # workflows present). SSOT/CI are filesystem facts, so the dir contents drive them.
  S118_BARE="$S118_DIR/bare"; mkdir -p "$S118_BARE"
  S118_FULL="$S118_DIR/full"; mkdir -p "$S118_FULL/.github/workflows"
  printf '# spec\n'    > "$S118_FULL/SPEC.md"
  printf '# mission\n' > "$S118_FULL/MISSION.md"
  printf 'name: ci\n'  > "$S118_FULL/.github/workflows/ci.yml"

  # 118a: fork→upstream fail; non-fork→upstream ok.
  printf 'true\n'  > "$S118_STATE/isfork"; printf 'WRITE\n' > "$S118_STATE/permission"
  s118_run "$S118_BARE"; s118_fork=$(s118_status upstream)
  printf 'false\n' > "$S118_STATE/isfork"
  s118_run "$S118_BARE"; s118_nofork=$(s118_status upstream)
  if [ "$s118_fork" = fail ] && [ "$s118_nofork" = ok ]; then
    ok "118a: upstream fork→fail, non-fork→ok (#456)"
  else
    ng "118a: upstream wrong (fork=$s118_fork non-fork=$s118_nofork, want fail/ok) (#456)"
  fi

  # 118b: missing push permission (READ)→fail; WRITE→ok.
  printf 'false\n' > "$S118_STATE/isfork"
  printf 'READ\n'  > "$S118_STATE/permission"
  s118_run "$S118_BARE"; s118_pread=$(s118_status permission)
  printf 'WRITE\n' > "$S118_STATE/permission"
  s118_run "$S118_BARE"; s118_pwrite=$(s118_status permission)
  if [ "$s118_pread" = fail ] && [ "$s118_pwrite" = ok ]; then
    ok "118b: permission READ→fail, WRITE→ok (#456)"
  else
    ng "118b: permission wrong (READ=$s118_pread WRITE=$s118_pwrite, want fail/ok) (#456)"
  fi

  # 118c: SPEC.md absent→fail (SPEC unconditionally expected AC); present→ok.
  s118_run "$S118_BARE"; s118_spec_absent=$(s118_status ssot:SPEC.md)
  s118_run "$S118_FULL"; s118_spec_present=$(s118_status ssot:SPEC.md)
  if [ "$s118_spec_absent" = fail ] && [ "$s118_spec_present" = ok ]; then
    ok "118c: ssot:SPEC.md absent→fail, present→ok (SPEC unconditionally expected) (#456)"
  else
    ng "118c: ssot:SPEC.md wrong (absent=$s118_spec_absent present=$s118_spec_present, want fail/ok) (#456)"
  fi

  # 118d: MISSION.md absent→fail; present→ok (same shape).
  s118_run "$S118_BARE"; s118_mission_absent=$(s118_status ssot:MISSION.md)
  s118_run "$S118_FULL"; s118_mission_present=$(s118_status ssot:MISSION.md)
  if [ "$s118_mission_absent" = fail ] && [ "$s118_mission_present" = ok ]; then
    ok "118d: ssot:MISSION.md absent→fail, present→ok (#456)"
  else
    ng "118d: ssot:MISSION.md wrong (absent=$s118_mission_absent present=$s118_mission_present) (#456)"
  fi

  # 118e: branch-protect present→ok; absent OR gh api .../protection ERRORS→fail,
  # and the script must STILL exit 0 (reports facts, never crashes/gates).
  printf 'false\n' > "$S118_STATE/isfork"; printf 'WRITE\n' > "$S118_STATE/permission"
  touch "$S118_STATE/protected"
  s118_run "$S118_BARE"; s118_bp_ok=$(s118_status branch-protect); s118_bp_ok_rc=$s118_rc
  rm -f "$S118_STATE/protected"
  s118_run "$S118_BARE"; s118_bp_fail=$(s118_status branch-protect); s118_bp_fail_rc=$s118_rc
  if [ "$s118_bp_ok" = ok ] && [ "$s118_bp_fail" = fail ] \
     && [ "$s118_bp_ok_rc" = 0 ] && [ "$s118_bp_fail_rc" = 0 ]; then
    ok "118e: branch-protect present→ok, absent/gh-api-error→fail, both exit 0 (#456)"
  else
    ng "118e: branch-protect wrong (ok=${s118_bp_ok}[rc=$s118_bp_ok_rc] fail=${s118_bp_fail}[rc=$s118_bp_fail_rc]) (#456)"
  fi

  # 118f: .github/workflows present→ci ok; absent→ci fail.
  s118_run "$S118_FULL"; s118_ci_present=$(s118_status ci)
  s118_run "$S118_BARE"; s118_ci_absent=$(s118_status ci)
  if [ "$s118_ci_present" = ok ] && [ "$s118_ci_absent" = fail ]; then
    ok "118f: ci .github/workflows present→ok, absent→fail (#456)"
  else
    ng "118f: ci wrong (present=$s118_ci_present absent=$s118_ci_absent, want ok/fail) (#456)"
  fi

  rm -rf "$S118_DIR"
fi

# ---------- §119: setup.sh single-entry orchestrator (#458) ----------
# Phase B (Test). Drives the FORTHCOMING single-entry script scripts/setup.sh
# (Execution #458) headlessly. setup.sh is a thin orchestrator over the existing
# sibling scripts; the contract under test:
#   setup.sh <local-path | repo-url> [--enter]
#   1. deps    → calls scripts/bootstrap.sh
#   2. dispatch on the single positional arg:
#        existing local dir → scripts/register.sh ; repo URL → scripts/clone-into.sh.
#        Tie-breaker: if [ -d "$arg" ] it is a local path regardless of URL shape.
#   3. pre-flight → runs scripts/lib/onboard_checks.sh, ok→✓ / fail→✗.
#   4. dir-mode gate: an always-offered y/N prompt, default N, `read -r resp || resp=N`
#        so EOF / non-TTY → N; only y/Y calls scripts/onboard_target.sh.
#   5. prints next-command guidance; --enter execs claude.
#   6. NEVER writes a user-global file (~/.zshrc, ~/.bashrc, ~/.profile, ~/.claude,
#        git config --global) — the PATH line is printed, never appended.
#
# Isolation mirrors §9b: setup.sh is copied into a fake shell root whose sibling
# deps (bootstrap/register/clone-into/onboard_target) are marker-dropping stubs —
# each touches a sentinel under $S119_MARK when invoked, so we assert WHICH path
# ran. onboard_checks.sh is stubbed to a one-line ok-report (the spec permits a
# stub) so pre-flight neither needs a real `gh` nor gates.
#
# RED until Phase C: with scripts/setup.sh absent the guard below fails LOUD on
# every planned assertion (mirrors §107/§118's script-absent pattern) — a clean
# intended failure, not a harness error.
S119_SCRIPT="$SHELL_ROOT/scripts/setup.sh"
if [ ! -f "$S119_SCRIPT" ]; then
  ng "119a: path arg → register.sh dispatch (not clone-into) — scripts/setup.sh missing (Phase C not landed) (#458)"
  ng "119b: URL arg → clone-into.sh dispatch (not register) — script missing (#458)"
  ng "119c: dir-mode gate non-TTY/EOF → onboard_target.sh NOT called, no hang — script missing (#458)"
  ng "119d: dir-mode gate 'y' → onboard_target.sh called — script missing (#458)"
  ng "119e: source contains no user-global redirect / git config --global — script missing (#458)"
  ng "119f: run against fake \$HOME leaves rc files untouched — script missing (#458)"
else
  # Build a fake shell root holding setup.sh + stubbed siblings.
  S119_FSR=$(cd "$(mktemp -d)" && pwd -P)
  mkdir -p "$S119_FSR/scripts/lib"
  cp "$S119_SCRIPT" "$S119_FSR/scripts/setup.sh"
  chmod +x "$S119_FSR/scripts/setup.sh"
  # Marker-dropping stubs: each writes a sentinel named after itself when invoked.
  for s119_dep in bootstrap register clone-into onboard_target; do
    {
      printf '#!/bin/sh\n'
      printf ': "${S119_MARK:?}"\n'
      printf 'touch "$S119_MARK/%s"\n' "$s119_dep"
      printf 'exit 0\n'
    } > "$S119_FSR/scripts/$s119_dep.sh"
    chmod +x "$S119_FSR/scripts/$s119_dep.sh"
  done
  # onboard_checks.sh stub: one ok line, always exit 0 (fact-reporter contract).
  {
    printf '#!/bin/sh\n'
    printf 'echo "upstream ok stub"\n'
    printf 'exit 0\n'
  } > "$S119_FSR/scripts/lib/onboard_checks.sh"
  chmod +x "$S119_FSR/scripts/lib/onboard_checks.sh"

  # Bounded runner: drives the COPIED setup.sh with a marker dir + a stdin source.
  # $1 = positional arg, $2 = stdin source path (e.g. /dev/null or a printf-fed file).
  # A fresh marker dir per call; if `timeout`/`gtimeout` is present we hard-bound the
  # run (defence-in-depth against a `read` that fails to honor EOF), else fall back
  # to a backgrounded run + kill guard so a hang cannot wedge the suite.
  s119_run() {
    S119_MARK=$(mktemp -d)
    export S119_MARK
    if command -v timeout >/dev/null 2>&1; then
      timeout 10 sh "$S119_FSR/scripts/setup.sh" "$1" < "$2" >/dev/null 2>&1
      s119_rc=$?
    elif command -v gtimeout >/dev/null 2>&1; then
      gtimeout 10 sh "$S119_FSR/scripts/setup.sh" "$1" < "$2" >/dev/null 2>&1
      s119_rc=$?
    else
      sh "$S119_FSR/scripts/setup.sh" "$1" < "$2" >/dev/null 2>&1 &
      s119_pid=$!
      ( sleep 10; kill -9 "$s119_pid" 2>/dev/null ) & s119_killer=$!
      wait "$s119_pid" 2>/dev/null; s119_rc=$?
      kill "$s119_killer" 2>/dev/null
    fi
  }
  # s119_dropped <dep> → 0 if that dep's sentinel exists in the last run's marker dir.
  s119_dropped() { [ -f "${S119_MARK}/$1" ]; }

  # 119a: an existing local dir dispatches to register.sh, NOT clone-into.sh.
  S119_LOCAL=$(cd "$(mktemp -d)" && pwd -P)
  s119_run "$S119_LOCAL" /dev/null
  if s119_dropped register && ! s119_dropped clone-into; then
    ok "119a: path arg → register.sh dispatch (not clone-into) (#458)"
  else
    ng "119a: path arg dispatch wrong (register=$(s119_dropped register && echo y || echo n) clone-into=$(s119_dropped clone-into && echo y || echo n)) (#458)"
  fi
  rm -rf "$S119_LOCAL" "$S119_MARK"

  # 119b: a repo URL dispatches to clone-into.sh, NOT register.sh.
  s119_run "https://example.com/foo.git" /dev/null
  if s119_dropped clone-into && ! s119_dropped register; then
    ok "119b: URL arg → clone-into.sh dispatch (not register) (#458)"
  else
    ng "119b: URL arg dispatch wrong (clone-into=$(s119_dropped clone-into && echo y || echo n) register=$(s119_dropped register && echo y || echo n)) (#458)"
  fi
  rm -rf "$S119_MARK"

  # 119c: dir-mode gate, non-TTY / EOF stdin (< /dev/null) → default N → onboard_target
  # NOT called, and the run must terminate (no hang). A URL arg keeps the dispatch in
  # clone-into (a stub), so onboard_target firing would be the gate, not dispatch.
  s119_run "https://example.com/foo.git" /dev/null
  if ! s119_dropped onboard_target && [ "$s119_rc" != 137 ] && [ "$s119_rc" != 124 ]; then
    ok "119c: dir-mode gate EOF/non-TTY → onboard_target NOT called, no hang (rc=$s119_rc) (#458)"
  else
    ng "119c: dir-mode gate non-TTY wrong (onboard_target=$(s119_dropped onboard_target && echo y || echo n) rc=$s119_rc; 124/137 ⇒ hang/timeout) (#458)"
  fi
  rm -rf "$S119_MARK"

  # 119d: dir-mode gate, stdin = 'y' → onboard_target.sh IS called.
  S119_YES=$(mktemp); printf 'y\n' > "$S119_YES"
  s119_run "https://example.com/foo.git" "$S119_YES"
  if s119_dropped onboard_target; then
    ok "119d: dir-mode gate 'y' → onboard_target.sh called (#458)"
  else
    ng "119d: dir-mode gate 'y' did NOT call onboard_target.sh (#458)"
  fi
  rm -f "$S119_YES"; rm -rf "$S119_MARK"

  # 119e: source-level guard — setup.sh must contain no redirection into a user-global
  # rc file and no `git config --global`. A grep-the-source assertion is robust against
  # whichever branch a run happens to take. Pattern covers > and >> into the rc paths.
  if grep -Eq '>>?[[:space:]]*("?~|"?\$HOME)?/?\.(zshrc|bashrc|profile)|>>?[[:space:]]*"?~?/?\.claude|git[[:space:]]+config[[:space:]]+--global' "$S119_SCRIPT"; then
    ng "119e: setup.sh source contains a user-global redirect or git config --global (#458)"
  else
    ok "119e: setup.sh source has no user-global redirect / git config --global (#458)"
  fi

  # 119f: behavioural backstop — run against a fake $HOME seeded with rc files and
  # assert they are byte-identical afterwards (the PATH line is printed, never written).
  S119_HOME=$(cd "$(mktemp -d)" && pwd -P)
  printf 'orig-zshrc\n'   > "$S119_HOME/.zshrc"
  printf 'orig-bashrc\n'  > "$S119_HOME/.bashrc"
  printf 'orig-profile\n' > "$S119_HOME/.profile"
  s119_pre=$(cat "$S119_HOME/.zshrc" "$S119_HOME/.bashrc" "$S119_HOME/.profile")
  ( S119_MARK=$(mktemp -d); export S119_MARK
    HOME="$S119_HOME" sh "$S119_FSR/scripts/setup.sh" "https://example.com/foo.git" < /dev/null >/dev/null 2>&1
    rm -rf "$S119_MARK" ) || true
  s119_post=$(cat "$S119_HOME/.zshrc" "$S119_HOME/.bashrc" "$S119_HOME/.profile")
  if [ "$s119_pre" = "$s119_post" ] && [ ! -d "$S119_HOME/.claude" ]; then
    ok "119f: run against fake \$HOME left rc files + ~/.claude untouched (#458)"
  else
    ng "119f: run against fake \$HOME mutated an rc file or created ~/.claude (#458)"
  fi
  rm -rf "$S119_HOME"

  unset S119_MARK
  rm -rf "$S119_FSR"
fi

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

ESC_HOOK="$SHELL_ROOT/.claude/hooks/pre_tool_use.sh"
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

# ---------- §137: un-skippable pre-merge gate — push-parity + merge-review (#544, #586) ----------
# SPEC §6.1 (`gh pr merge` matcher rows) + §5.7/§5.7.1. Two independent arms on
# the `gh pr merge` matcher, folded into helpers/ac_closeout_gate.sh:
#
#   push-parity (git-only, #244) — block when the local branch is STRICTLY AHEAD
#     of its pushed remote-tracking head (unpushed commits the merge would leave
#     behind): `git merge-base --is-ancestor <remote> <local>` true AND the two
#     SHAs differ. POSITIVE detection — behind / diverged / no-upstream / detached
#     → allow. Block message names "push your local commits first". Already shipped
#     (#544), so its cases (137p) stay GREEN.
#   merge-review (#586, #585, #543 — REPLACES the retired merge-attestation file
#     arm, #246/#544) — block a `gh pr merge` lacking a passing GitHub review
#     PINNED TO THE CURRENT HEAD. Reads the review OBJECTS authoritatively via
#     `gh api repos/{owner}/{repo}/pulls/<n>/reviews` (state / commit_id /
#     author.login per review), the head via `gh pr view <n> --json headRefOid`,
#     the PR author via `gh pr view <n> --json author`, the merger via `gh api
#     user`, owner/repo via `gh repo view --json nameWithOwner`. AGGREGATION:
#     filter reviews to state ∈ {APPROVED, CHANGES_REQUESTED}, then latest-per-
#     author wins (COMMENTED/PENDING/DISMISSED ignored — mirrors reviewDecision).
#     ALLOW in exactly two shapes: (a) native — an APPROVED review with
#     commit_id==head and no author's filtered-latest is CHANGES_REQUESTED; (b)
#     self-marker — a COMMENTED review@head carrying exactly ONE verdict=approve
#     marker whose author.login == PR-author == merger, no outstanding
#     CHANGES_REQUESTED. BLOCK on: no review / only stale (commit_id!=head) / an
#     author's filtered-latest is CHANGES_REQUESTED / verdict=block / conflicting
#     or multiple markers / empty head. BYPASS (resolve_review_gate → bypass) →
#     allow + a LOUD `audit_log warn merge-review bypass`. FAIL-CLOSED (block) on
#     ANY lookup failure (gh down/timeout, PR unresolvable, malformed JSON, helper
#     miss) — the deliberate divergence from the retired arm's fail-open staleness
#     leg. SPEC §6.1 merge-review row + §5.7.1 review-gate toggle.
#
# The merge-review arm DOES NOT EXIST YET (Phase B / Doc→Test→Code): review_gate_
# accepts, resolve_review_gate, and the merge-review matcher are unwritten, and
# the merge-attestation arm it REPLACES is still in place (its swap is Phase C).
# So every `gh pr merge` in the merge-review cases below falls through to that
# incumbent arm — which blocks on the absent attest file under
# category=merge-attestation (block cases + fail-closed case), or would need an
# attest file to allow (allow / bypass cases) — NEVER to a merge-review decision.
# Each merge-review assertion therefore keys on the `merge-review` audit category
# / rc the absent arm cannot produce (the block/fail-closed cases demand
# category=merge-review, not merge-attestation; the allow/bypass cases demand
# rc=0 the incumbent's presence-block cannot give), so every one reports RED now
# — arm absent ⇒ wrong category or wrong rc ⇒ RED, never a vacuous pass.
# CRITICAL: these cases do NOT seed an attest/pr-<N> file (that would let the
# incumbent arm allow and mask the RED) and do NOT touch the global attest seed
# (smoke.sh ~L59-71) — Phase C reworks that seed together with the matcher swap.

S137_DIR=$(mktemp -d)
S137_SHIM="$S137_DIR/bin"
S137_STATE="$S137_DIR/ghstate"       # GH_SHIM_STATE for the gh shim
S137_ATTEST_OK="$S137_DIR/attest-ok" # GHJIG_STATE_DIR_OVERRIDE carrying a VALID attestation
mkdir -p "$S137_SHIM" "$S137_STATE" "$S137_ATTEST_OK/audit" "$S137_ATTEST_OK/attest"

# gh shim (mirrors §38): canned headRefOid + closingIssuesReferences (empty →
# ac-closeout allows), plus the merge-review canned reads (a full review-object
# ARRAY for `gh api .../pulls/<n>/reviews`; pre-extracted scalar values for the
# `-q`-queried head / PR author / merger / nameWithOwner reads — same idiom as
# the headRefOid arm, the shim ignores `-q` and returns the extracted value the
# caller's `-q` would have produced), plus a forced-DOWN toggle (touch
# $GH_SHIM_STATE/gh_down) that makes every gh call error. The down toggle proves
# the merge-review gate FAILS CLOSED on a lookup failure.
cat > "$S137_SHIM/gh" <<'SHIM'
#!/bin/sh
if [ -f "$GH_SHIM_STATE/gh_down" ]; then
  echo "gh: shim forced down (no network)" >&2
  exit 1
fi
case "$*" in
  *"api"*/reviews*)                    cat "$GH_SHIM_STATE/reviews.json" 2>/dev/null ;;
  *"api user"*)                        cat "$GH_SHIM_STATE/api_user" 2>/dev/null ;;
  *"pr view"*headRefOid*)              cat "$GH_SHIM_STATE/head_ref_oid" 2>/dev/null ;;
  *"pr view"*author*)                  cat "$GH_SHIM_STATE/pr_author" 2>/dev/null ;;
  *"repo view"*nameWithOwner*)         cat "$GH_SHIM_STATE/name_with_owner" 2>/dev/null ;;
  *"pr view"*closingIssuesReferences*) cat "$GH_SHIM_STATE/pr_issues" 2>/dev/null ;;
  *"pr view"*"--json number"*)         cat "$GH_SHIM_STATE/pr_number" 2>/dev/null ;;
esac
exit 0
SHIM
chmod +x "$S137_SHIM/gh"

# Baseline shim state for the push-parity cases: a canned native APPROVED review
# pinned to the current head (commit_id == gh headRefOid) + a nameWithOwner, so
# the merge-review arm ALLOWS (#586, ex-merge-attestation), isolating push-parity
# as the sole decider on those repos.
printf 'parity-head\n' > "$S137_STATE/head_ref_oid"
: > "$S137_STATE/pr_issues"
printf '[{"state":"APPROVED","commit_id":"parity-head","submitted_at":"2020-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"lgtm"}]\n' > "$S137_STATE/reviews.json"
printf 'octo/repo\n' > "$S137_STATE/name_with_owner"

# Build a throwaway git repo in the requested push-parity state; echo its
# working-tree path. Mirrors the §32c throwaway git-init idiom. The remote-
# tracking ref is seeded via a LOCAL bare remote + `git push -u` (no network),
# so both `@{u}` and `origin/<branch>` resolve for whichever the arm reads.
s137_build_repo() {
  local state="$1" d work
  d=$(mktemp -d); work="$d/work"
  git init -q "$work" 2>/dev/null
  (
    cd "$work" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    git checkout -q -b smoke/feat/1-parity 2>/dev/null || true
    git commit --allow-empty -q -m c1
    case "$state" in
      no-upstream) : ;;                                # no remote → no @{u}
      detached)
        git commit --allow-empty -q -m c2
        git checkout -q --detach HEAD ;;
      *)
        git init -q --bare "$d/remote.git"
        git remote add origin "$d/remote.git"
        git push -q -u origin smoke/feat/1-parity
        case "$state" in
          in-sync) : ;;                                # local == pushed
          ahead)   git commit --allow-empty -q -m c2 ;;         # unpushed local commit
          behind)  git commit --allow-empty -q -m c2
                   git push -q origin smoke/feat/1-parity
                   git reset --hard -q HEAD~1 ;;                # local behind remote
          diverged) git commit --allow-empty -q -m c2
                    git push -q origin smoke/feat/1-parity
                    git reset --hard -q HEAD~1
                    git commit --allow-empty -q -m c2prime ;;   # neither is an ancestor
        esac ;;
    esac
  )
  printf '%s' "$work"
}

# Run `gh pr merge 55 --merge` inside a push-parity repo state; register the repo
# so in_scope passes, then de-register + clean. block cases are RED now (arm
# absent ⇒ rc 0 ⇒ the rc==2 assertion fails).
s137_parity_case() {
  local state="$1" expect="$2" repo canon out rc
  repo=$(s137_build_repo "$state")
  canon=$(cd "$repo" && pwd -P)
  # GHJIG_STATE_DIR_OVERRIDE relocates BOTH the audit log AND the scope registry
  # (ghjig_registry_file → $esd/registry.txt), so the repo must be registered in
  # the override's OWN registry or in_scope fails and the hook exits early — which
  # would green/red these cases for the wrong reason. Seed it fresh each run.
  printf '%s\n' "$canon" > "$S137_ATTEST_OK/registry.txt"
  out=$(
    cd "$repo" || exit 1
    # shellcheck disable=SC2069  # intentional: capture stderr, discard stdout
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' 'gh pr merge 55 --merge' | jq -Rs .)" \
      | PATH="$S137_SHIM:$PATH" \
        GH_SHIM_STATE="$S137_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        GHJIG_STATE_DIR_OVERRIDE="$S137_ATTEST_OK" \
        bash "$HOOK" 2>&1 >/dev/null
  )
  rc=$?
  rm -rf "$(dirname "$repo")"
  case "$expect" in
    block)
      if [ "$rc" = 2 ] \
         && printf '%s' "$out" | grep -q 'push-parity' \
         && printf '%s' "$out" | grep -qi 'push your local commits'; then
        ok "137p: push-parity blocks strictly-ahead ($state) merge — names 'push your local commits first' (#544)"
      else
        ng "137p: push-parity should BLOCK strictly-ahead ($state) (rc=$rc; arm absent ⇒ allow ⇒ RED) out=$out (#544)"
      fi ;;
    allow)
      if [ "$rc" = 0 ]; then
        ok "137p: push-parity allows non-strictly-ahead state ($state) (#544)"
      else
        ng "137p: push-parity should ALLOW ($state) (rc=$rc) out=$out (#544)"
      fi ;;
  esac
}

# 137p-a..f: only STRICTLY-AHEAD blocks; every other state allows (positive detection).
s137_parity_case ahead       block
s137_parity_case in-sync     allow
s137_parity_case behind      allow
s137_parity_case diverged    allow
s137_parity_case no-upstream allow
s137_parity_case detached    allow

# 137p-g: SKIP_HOOKS=push-parity escape — on a strictly-ahead repo the skip
# allows + audit-logs the escape. The baseline S137_STATE canned APPROVED@head
# review keeps merge-review from blocking (#586) so the push-parity escape is
# observed in isolation.
S137_SKIP_PSTATE="$S137_DIR/skip-parity"
mkdir -p "$S137_SKIP_PSTATE/audit"
s137_skp_repo=$(s137_build_repo ahead)
s137_skp_canon=$(cd "$s137_skp_repo" && pwd -P)
printf '%s\n' "$s137_skp_canon" > "$S137_SKIP_PSTATE/registry.txt"  # in_scope under the override
skp_before=$(wc -l < "$S137_SKIP_PSTATE/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
skp_rc=$(
  cd "$s137_skp_repo" || exit 1
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' "SKIP_HOOKS=push-parity SKIP_REASON='urgent' gh pr merge 55 --merge" | jq -Rs .)" \
    | PATH="$S137_SHIM:$PATH" GH_SHIM_STATE="$S137_STATE" \
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" GHJIG_STATE_DIR_OVERRIDE="$S137_SKIP_PSTATE" \
      bash "$HOOK" >/dev/null 2>&1
  printf '%s' "$?"
)
skp_after=$(wc -l < "$S137_SKIP_PSTATE/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
skp_tail=""
[ "$(( skp_after - skp_before ))" -gt 0 ] && skp_tail=$(tail -"$(( skp_after - skp_before ))" "$S137_SKIP_PSTATE/audit/audit.jsonl" 2>/dev/null)
rm -rf "$(dirname "$s137_skp_repo")"
if [ "$skp_rc" = 0 ] \
   && printf '%s' "$skp_tail" | grep -q '"category":"push-parity"' \
   && printf '%s' "$skp_tail" | grep -q '"decision":"skip"'; then
  ok "137p: SKIP_HOOKS=push-parity allows + audits the escape (#544)"
else
  ng "137p: push-parity escape should allow + audit skip (rc=$skp_rc; arm absent ⇒ no escape record ⇒ RED) tail=$skp_tail (#544)"
fi

# ── merge-review arm (#586, #585 — replacing merge-attestation) ───────────────
# Each merge-review case gets its OWN gh-shim state dir (canned reviews.json +
# head / PR-author / merger / owner scalars) AND its own GHJIG_STATE_DIR_OVERRIDE
# (per-case audit log + scope registry). The merge runs in $TMP/fake by default
# (no upstream ⇒ push-parity always allows there, so it never masks the
# merge-review decision) — except the bypass case, which runs in a dedicated cwd
# carrying `.claude/state/review-gate=bypass` so resolve_review_gate reads it.
# None of these state dirs carry an attest/pr-55 file, so the incumbent
# merge-attestation arm presence-BLOCKS every one — the RED signal for the
# absent merge-review arm.
S137_RV_HEAD=rvhead-current   # the current PR head SHA the shim reports
S137_RV_OLD=rvhead-super      # a superseded (stale) head SHA

# s137_rv_shim <dir> — seed a shim state dir with sane merge-review defaults
# (native reviewer/merger identities distinct from the PR author). Caller
# overrides reviews.json (+ pr_author/api_user for the self-marker cases).
s137_rv_shim() {
  local d="$1"
  mkdir -p "$d"
  printf '%s\n' "$S137_RV_HEAD" > "$d/head_ref_oid"
  printf 'pr-author-bot\n'      > "$d/pr_author"
  printf 'merger-bot\n'         > "$d/api_user"
  printf 'octo/repo\n'          > "$d/name_with_owner"
  printf '55\n'                 > "$d/pr_number"   # `gh pr view --json number` fallback (covered form has no positional PR)
  : > "$d/pr_issues"            # empty ⇒ ac-closeout allows
}

# s137_rv_case <name> <expect> <shimdir> <statedir> [<cwd>] [<cmd>]
#   Drives <cmd> (default `gh pr merge 55 --merge`) through the hook; asserts rc +
#   (for block/bypass) the per-case audit tail carries the merge-review category.
#   The optional 6th <cmd> param lets the #592 bypass-backstop cases drive the
#   covered ship form (`gh pr merge --auto --merge --delete-branch`, no positional
#   PR — resolves via the shim's `--json number` fallback, seeded by s137_rv_shim).
s137_rv_case() {
  local name="$1" expect="$2" shimdir="$3" statedir="$4" cwd="${5:-$TMP/fake}" cmd="${6:-gh pr merge 55 --merge}"
  local canon out rc before after rvtail
  canon=$(cd "$cwd" && pwd -P)
  # The override relocates the scope registry too — register the cwd in it or
  # in_scope fails and the hook exits early (RED/GREEN for the wrong reason).
  printf '%s\n' "$canon" > "$statedir/registry.txt"
  # Guard the `< file` redirect with [ -f ] — bash opens the redirect BEFORE
  # applying 2>/dev/null, so an absent audit.jsonl would leak a spurious "No
  # such file" line (smoke.sh L40-43). Absent sink snapshots as 0.
  before=0; [ -f "$statedir/audit/audit.jsonl" ] && before=$(wc -l < "$statedir/audit/audit.jsonl" | tr -d ' ')
  out=$(
    cd "$cwd" || exit 1
    # shellcheck disable=SC2069  # intentional: capture stderr, discard stdout
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | jq -Rs .)" \
      | PATH="$S137_SHIM:$PATH" \
        GH_SHIM_STATE="$shimdir" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        GHJIG_STATE_DIR_OVERRIDE="$statedir" \
        bash "$HOOK" 2>&1 >/dev/null
  )
  rc=$?
  after=0; [ -f "$statedir/audit/audit.jsonl" ] && after=$(wc -l < "$statedir/audit/audit.jsonl" | tr -d ' ')
  rvtail=""
  [ "$(( after - before ))" -gt 0 ] && rvtail=$(tail -"$(( after - before ))" "$statedir/audit/audit.jsonl" 2>/dev/null)
  case "$expect" in
    block)
      if [ "$rc" = 2 ] && printf '%s' "$rvtail" | grep -q '"category":"merge-review","decision":"deny"'; then
        ok "137r: merge-review BLOCKS — $name (#586)"
      else
        ng "137r: merge-review should BLOCK — $name (rc=$rc; arm absent ⇒ merge-attestation blocks under the wrong category ⇒ RED) tail=$rvtail out=$out (#586)"
      fi ;;
    allow)
      if [ "$rc" = 0 ]; then
        ok "137r: merge-review ALLOWS — $name (#586)"
      else
        ng "137r: merge-review should ALLOW — $name (rc=$rc; arm absent ⇒ incumbent presence-blocks ⇒ RED) tail=$rvtail out=$out (#586)"
      fi ;;
    bypass)
      if [ "$rc" = 0 ] && printf '%s' "$rvtail" | grep -q '"category":"merge-review","decision":"bypass"'; then
        ok "137r: merge-review BYPASS allows + loud audit — $name (#586)"
      else
        ng "137r: merge-review bypass should allow + emit a loud merge-review bypass audit (rc=$rc; arm absent ⇒ RED) tail=$rvtail out=$out (#586)"
      fi ;;
  esac
}

# 137r-a: BLOCK — no review at all (the review was skipped / never filed).
S137_RV_NONE_SH="$S137_DIR/rv-none-shim"; s137_rv_shim "$S137_RV_NONE_SH"
printf '[]\n' > "$S137_RV_NONE_SH/reviews.json"
S137_RV_NONE_ST="$S137_DIR/rv-none-state"; mkdir -p "$S137_RV_NONE_ST/audit"
s137_rv_case "no review filed" block "$S137_RV_NONE_SH" "$S137_RV_NONE_ST"

# 137r-b: BLOCK — only a STALE review (APPROVED but commit_id != current head).
S137_RV_STALE_SH="$S137_DIR/rv-stale-shim"; s137_rv_shim "$S137_RV_STALE_SH"
printf '[{"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"lgtm"}]\n' \
  "$S137_RV_OLD" > "$S137_RV_STALE_SH/reviews.json"
S137_RV_STALE_ST="$S137_DIR/rv-stale-state"; mkdir -p "$S137_RV_STALE_ST/audit"
s137_rv_case "only a stale APPROVED at a superseded head" block "$S137_RV_STALE_SH" "$S137_RV_STALE_ST"

# 137r-c: BLOCK — an outstanding CHANGES_REQUESTED at the current head.
S137_RV_CR_SH="$S137_DIR/rv-cr-shim"; s137_rv_shim "$S137_RV_CR_SH"
printf '[{"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"needs work"}]\n' \
  "$S137_RV_HEAD" > "$S137_RV_CR_SH/reviews.json"
S137_RV_CR_ST="$S137_DIR/rv-cr-state"; mkdir -p "$S137_RV_CR_ST/audit"
s137_rv_case "outstanding CHANGES_REQUESTED at head" block "$S137_RV_CR_SH" "$S137_RV_CR_ST"

# 137r-d: BLOCK — the B1 aggregation regression case. A native APPROVED@head
# (bob) alongside alice's CHANGES_REQUESTED@head FOLLOWED BY her COMMENTED@head.
# The correct aggregation FILTERS COMMENTED out before per-author-latest, so
# alice's surviving latest stays CHANGES_REQUESTED and the veto BLOCKS. A naive
# "latest row per author" would read alice's latest as COMMENTED, drop the veto,
# and spuriously ALLOW on bob's APPROVED — the exact bug this case pins.
S137_RV_REG_SH="$S137_DIR/rv-regression-shim"; s137_rv_shim "$S137_RV_REG_SH"
printf '[{"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"bob"},"user":{"login":"bob"},"body":"ok"},{"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-02T00:00:00Z","author":{"login":"alice"},"user":{"login":"alice"},"body":"changes please"},{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-03T00:00:00Z","author":{"login":"alice"},"user":{"login":"alice"},"body":"just a passing note"}]\n' \
  "$S137_RV_HEAD" "$S137_RV_HEAD" "$S137_RV_HEAD" > "$S137_RV_REG_SH/reviews.json"
S137_RV_REG_ST="$S137_DIR/rv-regression-state"; mkdir -p "$S137_RV_REG_ST/audit"
s137_rv_case "CHANGES_REQUESTED@head then COMMENTED@head, same author — veto survives (B1)" block "$S137_RV_REG_SH" "$S137_RV_REG_ST"

# 137r-e: ALLOW (native) — an APPROVED review at the current head, no outstanding
# CHANGES_REQUESTED.
S137_RV_APP_SH="$S137_DIR/rv-approved-shim"; s137_rv_shim "$S137_RV_APP_SH"
printf '[{"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"approved"}]\n' \
  "$S137_RV_HEAD" > "$S137_RV_APP_SH/reviews.json"
S137_RV_APP_ST="$S137_DIR/rv-approved-state"; mkdir -p "$S137_RV_APP_ST/audit"
s137_rv_case "native APPROVED at head, no outstanding CHANGES_REQUESTED" allow "$S137_RV_APP_SH" "$S137_RV_APP_ST"

# 137r-f: ALLOW (self-marker) — a COMMENTED review at head carrying EXACTLY ONE
# verdict=approve marker whose review author == PR author == merger (a
# self-shipped PR). Identity/head come from the review OBJECT; only `verdict`
# from the marker text.
S137_RV_SELF_SH="$S137_DIR/rv-selfmarker-shim"; s137_rv_shim "$S137_RV_SELF_SH"
printf 'me\n' > "$S137_RV_SELF_SH/pr_author"
printf 'me\n' > "$S137_RV_SELF_SH/api_user"
printf '[{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"me"},"user":{"login":"me"},"body":"<!-- file-review verdict=approve head=%s reviewer=code-reviewer -->"}]\n' \
  "$S137_RV_HEAD" "$S137_RV_HEAD" > "$S137_RV_SELF_SH/reviews.json"
S137_RV_SELF_ST="$S137_DIR/rv-selfmarker-state"; mkdir -p "$S137_RV_SELF_ST/audit"
# #598: the self-marker branch now ALSO requires resolve_self_review_policy==allow
# (default deny, fail-closed). So this ALLOW case must run in a cwd carrying
# `.claude/state/self-review=allow` — else the new policy default (deny) would
# BLOCK the self-marker and this case would flip red. git-init'd (no upstream ⇒
# push-parity allows) exactly like the 137r-h bypass cwd.
S137_RV_SELF_CWD="$S137_DIR/rv-selfmarker-cwd"
mkdir -p "$S137_RV_SELF_CWD/.claude/state"
( cd "$S137_RV_SELF_CWD" && git init -q && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false && git checkout -q -b smoke/feat/1-selfmarker \
    && git commit --allow-empty -q -m init ) 2>/dev/null || true
printf 'allow\n' > "$S137_RV_SELF_CWD/.claude/state/self-review"
s137_rv_case "self verdict=approve marker@head, author==PR-author==merger, self-review=allow" allow "$S137_RV_SELF_SH" "$S137_RV_SELF_ST" "$S137_RV_SELF_CWD"

# 137r-g: BLOCK — conflicting/multiple markers in one review (a verdict=approve
# AND a verdict=block marker) → ambiguous, fail-closed.
S137_RV_CONF_SH="$S137_DIR/rv-conflict-shim"; s137_rv_shim "$S137_RV_CONF_SH"
printf 'me\n' > "$S137_RV_CONF_SH/pr_author"
printf 'me\n' > "$S137_RV_CONF_SH/api_user"
printf '[{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"me"},"user":{"login":"me"},"body":"<!-- file-review verdict=approve head=%s reviewer=code-reviewer --> and also <!-- file-review verdict=block head=%s reviewer=code-reviewer -->"}]\n' \
  "$S137_RV_HEAD" "$S137_RV_HEAD" "$S137_RV_HEAD" > "$S137_RV_CONF_SH/reviews.json"
S137_RV_CONF_ST="$S137_DIR/rv-conflict-state"; mkdir -p "$S137_RV_CONF_ST/audit"
s137_rv_case "conflicting/multiple markers in one review" block "$S137_RV_CONF_SH" "$S137_RV_CONF_ST"

# 137r-h: BYPASS — resolve_review_gate reads `.claude/state/review-gate=bypass`
# (cwd-relative, read exactly as resolve_mode reads .claude/state/mode, §5.7.1):
# the gate is SKIPPED (merge allowed with no head-pinned review) but every bypass
# merge is LOUDLY audit-logged (`audit_log warn merge-review bypass`). Runs in a
# dedicated cwd carrying that toggle; reviews.json is empty to prove the bypass
# does not consult the gate at all.
S137_RV_BYP_CWD="$S137_DIR/rv-bypass-cwd"
mkdir -p "$S137_RV_BYP_CWD/.claude/state"
( cd "$S137_RV_BYP_CWD" && git init -q && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false && git checkout -q -b smoke/feat/1-bypass \
    && git commit --allow-empty -q -m init ) 2>/dev/null || true
printf 'bypass\n' > "$S137_RV_BYP_CWD/.claude/state/review-gate"
S137_RV_BYP_SH="$S137_DIR/rv-bypass-shim"; s137_rv_shim "$S137_RV_BYP_SH"
printf '[]\n' > "$S137_RV_BYP_SH/reviews.json"
S137_RV_BYP_ST="$S137_DIR/rv-bypass-state"; mkdir -p "$S137_RV_BYP_ST/audit"
s137_rv_case "review-gate=bypass → allow + loud bypass audit" bypass "$S137_RV_BYP_SH" "$S137_RV_BYP_ST" "$S137_RV_BYP_CWD"

# 137r-i: FAIL-CLOSED — gh forced DOWN (every lookup errors) → BLOCK. The
# deliberate divergence from the retired attestation staleness leg (which
# fail-OPEN-allowed on gh down): the safe direction for a merge integrity gate is
# to REQUIRE a review, never to skip it (§5.7.1).
S137_RV_DOWN_SH="$S137_DIR/rv-down-shim"; s137_rv_shim "$S137_RV_DOWN_SH"
printf '[]\n' > "$S137_RV_DOWN_SH/reviews.json"
touch "$S137_RV_DOWN_SH/gh_down"
S137_RV_DOWN_ST="$S137_DIR/rv-down-state"; mkdir -p "$S137_RV_DOWN_ST/audit"
s137_rv_case "gh down / lookup failure → fail-closed block" block "$S137_RV_DOWN_SH" "$S137_RV_DOWN_ST"

# ---- §137r bypass-backstop (#592): the bypass arm is NOT an unconditional skip ----
# Under review-gate=bypass the gate self-skips, EXCEPT it still BLOCKS the exact
# covered ship form (`gh pr merge --auto --merge --delete-branch`, settings.json:4)
# when it is an AGENT SELF-MERGE (PR author == merger). The covered form carries no
# positional PR, so the PR resolves via the shim's `gh pr view --json number`
# fallback (pr_number seeded by s137_rv_shim). All four run in the bypass cwd built
# for 137r-h (carries .claude/state/review-gate=bypass), each with its own state dir.
#
# 137r-j / 137r-m are RED NOW: Phase C (the backstop) is unwritten, so the bypass
# arm allows UNCONDITIONALLY — rc=0 + a merge-review/bypass audit — which is neither
# the rc=2 nor the merge-review/deny the block expectation demands. 137r-k / 137r-l
# are steady-green guards: they must ALLOW (bypass) both before AND after Phase C,
# proving the backstop narrows bypass to covered-form self-merges ONLY (human
# covered-form merges and non-covered self-merges stay allowed).
S137_RV_COVERED='gh pr merge --auto --merge --delete-branch'

# 137r-j: BLOCK — covered form + SELF-merge (PR author == merger) under bypass. The
# static permissions.allow entry alone is no longer the sole guard (#592): the hook
# fails the agent self-merge closed even with the gate bypassed. RED now (bypass
# allows unconditionally ⇒ rc=0/decision=bypass ≠ rc=2/decision=deny).
S137_RV_JSH="$S137_DIR/rv-byp-self-shim"; s137_rv_shim "$S137_RV_JSH"
printf '[]\n' > "$S137_RV_JSH/reviews.json"
printf 'me\n' > "$S137_RV_JSH/pr_author"   # author == merger ⇒ self-merge
printf 'me\n' > "$S137_RV_JSH/api_user"
S137_RV_JST="$S137_DIR/rv-byp-self-state"; mkdir -p "$S137_RV_JST/audit"
s137_rv_case "bypass + covered form + self-merge → backstop BLOCKS (#592)" block \
  "$S137_RV_JSH" "$S137_RV_JST" "$S137_RV_BYP_CWD" "$S137_RV_COVERED"

# 137r-m: BLOCK (fail-closed) — covered form + gh DOWN under bypass. The self-merge
# author/merger lookup errors ⇒ indeterminate ⇒ the backstop fails CLOSED (mirrors
# the required arm's §5.7.1 posture: a merge-integrity gate never fail-opens on an
# outage). RED now (bypass short-circuits before any gh call ⇒ rc=0/bypass).
S137_RV_MSH="$S137_DIR/rv-byp-down-shim"; s137_rv_shim "$S137_RV_MSH"
printf '[]\n' > "$S137_RV_MSH/reviews.json"
printf 'me\n' > "$S137_RV_MSH/pr_author"
printf 'me\n' > "$S137_RV_MSH/api_user"
touch "$S137_RV_MSH/gh_down"
S137_RV_MST="$S137_DIR/rv-byp-down-state"; mkdir -p "$S137_RV_MST/audit"
s137_rv_case "bypass + covered form + gh down → backstop fail-closed BLOCKS (#592)" block \
  "$S137_RV_MSH" "$S137_RV_MST" "$S137_RV_BYP_CWD" "$S137_RV_COVERED"

# 137r-k (steady-green guard): covered form + HUMAN merge (PR author != merger) under
# bypass → ALLOW + loud bypass audit. The backstop needs BOTH covered-form AND
# self-merge; a human ship of the covered form stays bypass-allowed. GREEN before
# (bypass unconditional) AND after (author != merger ⇒ not a self-merge) Phase C.
S137_RV_KSH="$S137_DIR/rv-byp-human-shim"; s137_rv_shim "$S137_RV_KSH"
printf '[]\n' > "$S137_RV_KSH/reviews.json"   # default pr-author-bot != merger-bot ⇒ human
S137_RV_KST="$S137_DIR/rv-byp-human-state"; mkdir -p "$S137_RV_KST/audit"
s137_rv_case "bypass + covered form + human merge → stays allowed (bypass) (#592)" bypass \
  "$S137_RV_KSH" "$S137_RV_KST" "$S137_RV_BYP_CWD" "$S137_RV_COVERED"

# 137r-l (steady-green guard): NON-covered form (`gh pr merge 55 --merge`) + self-merge
# under bypass → ALLOW + loud bypass audit. The backstop guards only the covered ship
# form; a non-covered self-merge is not this hook's concern (the classifier re-engages
# on it elsewhere). GREEN before AND after Phase C (form is not the covered shape).
S137_RV_LSH="$S137_DIR/rv-byp-noncov-shim"; s137_rv_shim "$S137_RV_LSH"
printf '[]\n' > "$S137_RV_LSH/reviews.json"
printf 'me\n' > "$S137_RV_LSH/pr_author"   # self-merge, but NOT the covered form
printf 'me\n' > "$S137_RV_LSH/api_user"
S137_RV_LST="$S137_DIR/rv-byp-noncov-state"; mkdir -p "$S137_RV_LST/audit"
s137_rv_case "bypass + non-covered form + self-merge → stays allowed (bypass) (#592)" bypass \
  "$S137_RV_LSH" "$S137_RV_LST" "$S137_RV_BYP_CWD"

# §137-inv (structural, mirrors §39b): each arm must exist in pre_tool_use.sh as
# an INDEPENDENT matcher reaching its own decided state — i.e. carry both a
# `should_skip <cat>` entry and a `pass_through_trace <cat>` terminal tail (the
# SPEC §6.1 mark_allow/block/pass_through_trace decided-state contract, parity
# with the ac-closeout + merge-strategy arms). push-parity is already shipped
# (GREEN); merge-review is RED now — neither symbol is present for it because the
# arm has not been written (the incumbent still carries merge-attestation).
for inv_cat in push-parity merge-review; do
  if grep -q "should_skip $inv_cat" "$HOOK" \
     && grep -q "pass_through_trace $inv_cat" "$HOOK"; then
    ok "137-inv: '$inv_cat' arm present with should_skip + pass_through_trace decided tail (#544, #586)"
  else
    ng "137-inv: '$inv_cat' arm missing should_skip/pass_through_trace symbol (arm absent ⇒ RED) (#544, #586)"
  fi
done

# §137-inv (runtime compose, mirrors §39d): a benign in-sync merge with a passing
# head-pinned review ALLOWS and both arms decide SILENTLY — no pass-through warn
# for either category (each mark_allow's, no fall-through), composing with
# ac-closeout + merge-strategy on the same `gh pr merge` with no double-decide.
# Seeded to allow under BOTH the incumbent (attest file present + head match) and
# the future merge-review arm (a native APPROVED@head review), so it stays GREEN
# across the Phase-C swap without touching the global attest seed.
S137_INV_STATE="$S137_DIR/inv"
mkdir -p "$S137_INV_STATE/audit" "$S137_INV_STATE/attest"
printf 'head=current-sha-999\n' > "$S137_INV_STATE/attest/pr-55"
printf 'current-sha-999\n' > "$S137_STATE/head_ref_oid"
printf '[{"state":"APPROVED","commit_id":"current-sha-999","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"approved"}]\n' > "$S137_STATE/reviews.json"
printf 'pr-author-bot\n' > "$S137_STATE/pr_author"
printf 'merger-bot\n'    > "$S137_STATE/api_user"
printf 'octo/repo\n'     > "$S137_STATE/name_with_owner"
s137_inv_repo=$(s137_build_repo in-sync)
s137_inv_canon=$(cd "$s137_inv_repo" && pwd -P)
printf '%s\n' "$s137_inv_canon" > "$S137_INV_STATE/registry.txt"  # in_scope under the override
inv_before=$(wc -l < "$S137_INV_STATE/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
inv_rc=$(
  cd "$s137_inv_repo" || exit 1
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' 'gh pr merge 55 --merge' | jq -Rs .)" \
    | PATH="$S137_SHIM:$PATH" GH_SHIM_STATE="$S137_STATE" \
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" GHJIG_STATE_DIR_OVERRIDE="$S137_INV_STATE" \
      bash "$HOOK" >/dev/null 2>&1
  printf '%s' "$?"
)
inv_after=$(wc -l < "$S137_INV_STATE/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
inv_tail=""
[ "$(( inv_after - inv_before ))" -gt 0 ] && inv_tail=$(tail -"$(( inv_after - inv_before ))" "$S137_INV_STATE/audit/audit.jsonl" 2>/dev/null)
rm -rf "$(dirname "$s137_inv_repo")"
if [ "$inv_rc" = 0 ] \
   && ! printf '%s' "$inv_tail" | grep -q '"category":"push-parity","decision":"pass-through"' \
   && ! printf '%s' "$inv_tail" | grep -q '"category":"merge-review","decision":"pass-through"'; then
  ok "137-inv: benign in-sync reviewed merge allows; arms decide silently (no fall-through) (#544, #586)"
else
  ng "137-inv: benign merge must allow with no pass-through for the merge arms (rc=$inv_rc) tail=$inv_tail (#544, #586)"
fi

# ---------- §148: self-review producer classifier exception + per-target policy (#598) ----------
# SPEC §5.7.1 second auto-mode-classifier exception. /ship self-posts its head-pinned review
# via /file-review; on an agent-authored PR that self-approve POST was blocked by the auto-mode
# classifier, stranding the sanctioned unattended self-merge (Directive #584/#587). Fix: a
# fixed-form wildcard-free wrapper (scripts/ghjig_file_review_post.sh) allow-listed as
# Bash(.claude/ghjig-root/scripts/ghjig_file_review_post.sh) — parity with the merge entry —
# PLUS a per-target policy (.claude/state/self-review, resolve_self_review_policy, default deny/
# fail-closed) that the merge-review self-marker branch (§6.1) consults. This block sits BEFORE
# the §137 cleanup so §148f can reuse the live gh shim + s137_rv_* harness.
S148_WRAP_CANON='.claude/ghjig-root/scripts/ghjig_file_review_post.sh'
S148_WRAP_FILE="$SHELL_ROOT/scripts/ghjig_file_review_post.sh"
S148_SET="$SHELL_ROOT/.claude/settings.json"
S148_INJ="$SHELL_ROOT/.claude/settings.injected.json"
S148_FR="$SHELL_ROOT/.claude/commands/file-review.md"
S148_SHIPMODE="$SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh"

# §148a (LOAD-BEARING RED): settings.json carries the exact wildcard-free wrapper entry.
if [ -f "$S148_SET" ] && grep -qF "Bash($S148_WRAP_CANON)" "$S148_SET" 2>/dev/null; then
  ok "148a: settings.json carries exact wrapper allow entry Bash($S148_WRAP_CANON) (#598)"
else
  ng "148a: settings.json missing exact wrapper allow entry Bash($S148_WRAP_CANON) (#598)"
fi

# §148b (LOAD-BEARING RED — presence + narrowness fused): the ONLY ghjig_file_review_post.sh
# allow rule is the exact form (a `…post.sh:*` wildcard would hit the substring but not the
# exact literal → any!=exact fails), AND there is NO raw `gh api …pulls…reviews` allow (which
# would open APPROVE/REQUEST_CHANGES on any PR — past self-COMMENT-only).
if [ -f "$S148_SET" ]; then
  s148_any=$(grep -cF 'ghjig_file_review_post.sh' "$S148_SET" 2>/dev/null || true)
  s148_exact=$(grep -cF "Bash($S148_WRAP_CANON)" "$S148_SET" 2>/dev/null || true)
  s148_rawapi=$(grep -cE 'gh api[^"]*pulls[^"]*reviews' "$S148_SET" 2>/dev/null || true)
else
  s148_any=-1; s148_exact=-1; s148_rawapi=-1
fi
if [ "$s148_exact" -ge 1 ] && [ "$s148_any" = "$s148_exact" ] && [ "$s148_rawapi" = 0 ]; then
  ok "148b: only the exact narrow wrapper allow — no wildcard, no raw gh-api-reviews allow (any=$s148_any exact=$s148_exact rawapi=$s148_rawapi) (#598)"
else
  ng "148b: settings.json must carry only the exact narrow wrapper entry and no broad/raw-api allow (any=$s148_any exact=$s148_exact rawapi=$s148_rawapi) (#598)"
fi

# §148c (LOAD-BEARING RED — cross-target): settings.injected.json carries the identical exact
# narrow entry with the same both-directions + no-raw-api discipline (#591 propagation model).
if [ -f "$S148_INJ" ]; then
  s148c_any=$(grep -cF 'ghjig_file_review_post.sh' "$S148_INJ" 2>/dev/null || true)
  s148c_exact=$(grep -cF "Bash($S148_WRAP_CANON)" "$S148_INJ" 2>/dev/null || true)
  s148c_rawapi=$(grep -cE 'gh api[^"]*pulls[^"]*reviews' "$S148_INJ" 2>/dev/null || true)
else
  s148c_any=-1; s148c_exact=-1; s148c_rawapi=-1
fi
if [ "$s148c_exact" -ge 1 ] && [ "$s148c_any" = "$s148c_exact" ] && [ "$s148c_rawapi" = 0 ]; then
  ok "148c: settings.injected.json carries the exact narrow wrapper entry — propagated to targets (any=$s148c_any exact=$s148c_exact rawapi=$s148c_rawapi) (#598)"
else
  ng "148c: settings.injected.json must carry the exact narrow wrapper entry (cross-target) (any=$s148c_any exact=$s148c_exact rawapi=$s148c_rawapi) (#598)"
fi

# §148d (LOAD-BEARING RED): the wrapper exists, is executable, hardcodes event=COMMENT (NEVER
# APPROVE/REQUEST_CHANGES), and carries an own-PR author guard.
if [ -f "$S148_WRAP_FILE" ] && [ -x "$S148_WRAP_FILE" ] \
   && grep -qF 'event=COMMENT' "$S148_WRAP_FILE" 2>/dev/null \
   && ! grep -qE 'event=(APPROVE|REQUEST_CHANGES)' "$S148_WRAP_FILE" 2>/dev/null \
   && grep -qiE 'author' "$S148_WRAP_FILE" 2>/dev/null; then
  ok "148d: wrapper exists/executable, event=COMMENT only, own-PR author guard present (#598)"
else
  ng "148d: wrapper must exist+executable+event=COMMENT-only (never APPROVE/REQUEST_CHANGES)+own-PR author guard (#598)"
fi

# §148e (LOAD-BEARING RED): resolve_self_review_policy — default deny (fail-closed), state
# allow/deny honored, $GHJIG_SELF_REVIEW env override, garbage→deny. Sourced + called in
# throwaway cwds so the .claude/state/self-review read is cwd-relative (like review-gate).
s148_pol() { ( cd "$1" && . "$S148_SHIPMODE" 2>/dev/null && resolve_self_review_policy 2>/dev/null ); }
S148_POLDIR=$(mktemp -d)
mkdir -p "$S148_POLDIR/none" "$S148_POLDIR/allow/.claude/state" "$S148_POLDIR/deny/.claude/state" "$S148_POLDIR/garbage/.claude/state"
printf 'allow\n' > "$S148_POLDIR/allow/.claude/state/self-review"
printf 'deny\n'  > "$S148_POLDIR/deny/.claude/state/self-review"
printf 'wat?!\n' > "$S148_POLDIR/garbage/.claude/state/self-review"
s148_default=$(s148_pol "$S148_POLDIR/none")
s148_allow=$(s148_pol "$S148_POLDIR/allow")
s148_deny=$(s148_pol "$S148_POLDIR/deny")
s148_garbage=$(s148_pol "$S148_POLDIR/garbage")
s148_env=$( cd "$S148_POLDIR/deny" && GHJIG_SELF_REVIEW=allow bash -c ". \"$S148_SHIPMODE\" 2>/dev/null && resolve_self_review_policy" 2>/dev/null )
rm -rf "$S148_POLDIR"
if [ "$s148_default" = deny ] && [ "$s148_allow" = allow ] && [ "$s148_deny" = deny ] \
   && [ "$s148_garbage" = deny ] && [ "$s148_env" = allow ]; then
  ok "148e: resolve_self_review_policy default=deny, state honored, garbage→deny, env overrides (default=$s148_default allow=$s148_allow deny=$s148_deny garbage=$s148_garbage env=$s148_env) (#598)"
else
  ng "148e: resolve_self_review_policy must default deny + honor state/env + fail-closed on garbage (default=$s148_default allow=$s148_allow deny=$s148_deny garbage=$s148_garbage env=$s148_env) (#598)"
fi

# §148f (LOAD-BEARING RED — behavioral): the merge-review self-marker branch honors the policy.
# Same self-marker shim as 137r-f (author==PR-author==merger COMMENT verdict=approve @head),
# driven through the hook in two cwds: self-review=deny → BLOCK (self-marker NOT accepted; only
# a native second-party APPROVE would satisfy the gate), self-review=allow → ALLOW. Reuses the
# still-live s137 gh shim + s137_rv_* harness.
s148_mk_selfshim() {
  local d="$1"; s137_rv_shim "$d"
  printf 'me\n' > "$d/pr_author"; printf 'me\n' > "$d/api_user"
  printf '[{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"me"},"user":{"login":"me"},"body":"<!-- file-review verdict=approve head=%s reviewer=code-reviewer -->"}]\n' \
    "$S137_RV_HEAD" "$S137_RV_HEAD" > "$d/reviews.json"
}
s148_mk_cwd() {
  local c="$1" pol="$2"
  mkdir -p "$c/.claude/state"
  ( cd "$c" && git init -q && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false && git checkout -q -b smoke/feat/1-selfpol \
      && git commit --allow-empty -q -m init ) 2>/dev/null || true
  printf '%s\n' "$pol" > "$c/.claude/state/self-review"
}
S148F_DENY_SH="$S137_DIR/rv-selfpol-deny-shim"; s148_mk_selfshim "$S148F_DENY_SH"
S148F_DENY_ST="$S137_DIR/rv-selfpol-deny-state"; mkdir -p "$S148F_DENY_ST/audit"
S148F_DENY_CWD="$S137_DIR/rv-selfpol-deny-cwd"; s148_mk_cwd "$S148F_DENY_CWD" deny
s137_rv_case "self-marker@head but self-review=deny → not accepted" block "$S148F_DENY_SH" "$S148F_DENY_ST" "$S148F_DENY_CWD"
S148F_ALLOW_SH="$S137_DIR/rv-selfpol-allow-shim"; s148_mk_selfshim "$S148F_ALLOW_SH"
S148F_ALLOW_ST="$S137_DIR/rv-selfpol-allow-state"; mkdir -p "$S148F_ALLOW_ST/audit"
S148F_ALLOW_CWD="$S137_DIR/rv-selfpol-allow-cwd"; s148_mk_cwd "$S148F_ALLOW_CWD" allow
s137_rv_case "self-marker@head with self-review=allow → accepted" allow "$S148F_ALLOW_SH" "$S148F_ALLOW_ST" "$S148F_ALLOW_CWD"

# §148g (CRITICAL — LOAD-BEARING RED): byte-for-byte drift lock. The settings.json wrapper
# allow inner command AND the file-review.md invocation must both carry the exact wrapper path
# — a silent drift → the emitted command misses the matcher → classifier re-engages → silent
# unattended park (the same failure class this fix closes; mirrors §144f).
s148_set_has=0; s148_fr_has=0
[ -f "$S148_SET" ] && grep -qF "Bash($S148_WRAP_CANON)" "$S148_SET" 2>/dev/null && s148_set_has=1
[ -f "$S148_FR" ] && grep -qF "$S148_WRAP_CANON" "$S148_FR" 2>/dev/null && s148_fr_has=1
if [ "$s148_set_has" = 1 ] && [ "$s148_fr_has" = 1 ]; then
  ok "148g: wrapper path is byte-identical in settings.json and file-review.md (set=$s148_set_has fr=$s148_fr_has) (#598)"
else
  ng "148g: byte-for-byte drift — settings-side=$s148_set_has file-review-side=$s148_fr_has, both must carry '$S148_WRAP_CANON' (#598)"
fi

rm -rf "$S137_DIR"

# ---------- §138: pinned-reproducible shellcheck lint runner (#545) ----------
# SPEC §11 (syntax job). The CI `syntax` job's shellcheck must become a single
# reproducible predicate that a developer runs locally identically — `scripts/lint.sh`
# — with the memory-cliff regression (#543/#539, combined `shellcheck "${files[@]}"`
# peaked ~18 GB RSS and OOM-killed the runner) permanently guarded by a per-file loop,
# and the shellcheck binary version-pinned + SHA256-verified fail-closed so "clean
# locally" and "clean in CI" are one predicate by construction.
#
# The runner DOES NOT EXIST YET (Phase B / Doc→Test→Code): scripts/lint.sh is absent
# and ci.yml still installs shellcheck unpinned via apt-get with no ./scripts/lint.sh
# call. Every product assertion below (a-e) therefore reports RED; f is a
# Doc-phase-confirming guard, expected GREEN (the SPEC §11 rewrite already landed).
# Anti-vacuity: the structural locks (138b, 138e) pair a required POSITIVE anchor with
# the forbidden-form absence, so an empty/comment-only file cannot green them.
S138_LINT="$SHELL_ROOT/scripts/lint.sh"
S138_CI="$SHELL_ROOT/.github/workflows/ci.yml"
S138_SPEC="$SHELL_ROOT/SPEC.md"

# §138a (product): scripts/lint.sh exists AND is executable — the single lint
# predicate CI and developers both invoke. RED now: the file is absent.
if [ -f "$S138_LINT" ] && [ -x "$S138_LINT" ]; then
  ok "138a: scripts/lint.sh exists and is executable (#545)"
else
  ng "138a: scripts/lint.sh missing or not executable (#545)"
fi

# §138b (product, bounded-memory structural lock): lint.sh invokes shellcheck inside a
# per-file loop (single-file loop var `"$f"`) and NEVER as a combined multi-file
# expansion (`"${files[@]}"` or a `*.sh` glob) — the #543/#539 memory-cliff guard.
# Anti-vacuity: require the POSITIVE per-file anchor (count ≥1), not merely the absence
# of the combined form. RED now: file absent ⇒ per-file anchor count 0.
s138b_perfile=$(grep -cE 'shellcheck[^#]*"\$f"' "$S138_LINT" 2>/dev/null)
s138b_combined=$(grep -cE 'shellcheck[^#]*("\$\{files\[@\]\}"|\*\.sh)' "$S138_LINT" 2>/dev/null)
if [ "${s138b_perfile:-0}" -ge 1 ] && [ "${s138b_combined:-0}" -eq 0 ]; then
  ok "138b: lint.sh runs shellcheck per file (\"\$f\") with no combined multi-file expansion (#545)"
else
  ng "138b: lint.sh missing per-file shellcheck loop or still uses a combined \"\${files[@]}\"/glob pass (#545)"
fi

# §138c (product): version pin + fail-closed SHA256 verification present in lint.sh —
# a pinned-version anchor (GHJIG_SHELLCHECK_VERSION) AND a checksum anchor (sha256/
# shasum) AND a fail-closed anchor (exit/error on mismatch). RED now: file absent.
if grep -qF 'GHJIG_SHELLCHECK_VERSION' "$S138_LINT" 2>/dev/null \
   && grep -qiE 'sha256|shasum|sha256sum' "$S138_LINT" 2>/dev/null \
   && grep -qiE 'exit 1|mismatch|does not match' "$S138_LINT" 2>/dev/null; then
  ok "138c: lint.sh pins shellcheck version and SHA256-verifies it fail-closed (#545)"
else
  ng "138c: lint.sh missing version pin (GHJIG_SHELLCHECK_VERSION) or fail-closed SHA256 verification (#545)"
fi

# §138d (product): Linux peak-RSS memory flag present — the per-file pass measured
# under `/usr/bin/time -v` so an approaching-limit regression surfaces legibly. RED
# now: file absent.
if grep -qF '/usr/bin/time' "$S138_LINT" 2>/dev/null; then
  ok "138d: lint.sh measures peak RSS via /usr/bin/time on Linux (#545)"
else
  ng "138d: lint.sh missing /usr/bin/time peak-RSS memory guard (#545)"
fi

# §138e (product, parity structural lock): ci.yml `syntax` job invokes ./scripts/lint.sh
# AND no longer carries the unpinned `apt-get install ... shellcheck` version source.
# Anti-vacuity: require the POSITIVE ./scripts/lint.sh anchor AND the absence of the old
# unpinned install. RED now: ci.yml still apt-installs shellcheck and has no lint.sh call.
s138e_aptshellcheck=$(grep -cE 'apt-get install.*shellcheck' "$S138_CI" 2>/dev/null)
if grep -qF './scripts/lint.sh' "$S138_CI" 2>/dev/null && [ "${s138e_aptshellcheck:-0}" -eq 0 ]; then
  ok "138e: ci.yml syntax job runs ./scripts/lint.sh with no unpinned apt-get shellcheck install (#545)"
else
  ng "138e: ci.yml missing ./scripts/lint.sh call or still apt-get installs unpinned shellcheck (#545)"
fi

# §138f (Doc-phase-confirming — expected GREEN): SPEC §11 references scripts/lint.sh AND
# the version-pinned contract. The Doc commit landed, so this greens now.
if grep -qF 'scripts/lint.sh' "$S138_SPEC" 2>/dev/null \
   && grep -qiE 'pinned|version-pinned' "$S138_SPEC" 2>/dev/null; then
  ok "138f: SPEC §11 documents scripts/lint.sh as version-pinned (#545)"
else
  ng "138f: SPEC §11 missing scripts/lint.sh reference or version-pinned wording (#545)"
fi

# ---------- §139: readability / language-idiom quality axis (#546) ----------
# SPEC §4.5.1 + .claude/rubrics/bash.md. Senior-engineering quality has two axes:
# correctness (shellcheck/tests/reviewer, already covered) and the readability /
# language-idiom axis ("is the bash written the way bash wants to be written").
# The axis is carried as a per-language rubric SSOT, applied by code-reviewer as
# ADVISORY idiom-notes that never escalate to block, with a deterministic subset
# surfaced by a born-advisory checker scripts/lint_bash_idioms.sh.
#
# Doc landed (Phase A): (a)-(e) are product/Doc-confirming and green now. The
# deterministic checker DOES NOT EXIST YET (Phase B/Test): (f) is the load-bearing
# intended-RED — it fails until scripts/lint_bash_idioms.sh lands in Phase C.
S139_RUBRIC="$SHELL_ROOT/.claude/rubrics/bash.md"
S139_CODE_REV="$SHELL_ROOT/.claude/agents/code-reviewer.md"
S139_SPEC="$SHELL_ROOT/SPEC.md"
S139_MISSION="$SHELL_ROOT/MISSION.md"
S139_CHECKER="$SHELL_ROOT/scripts/lint_bash_idioms.sh"
S139_FX_BAD="$SHELL_ROOT/scripts/test/fixtures/idiom/bash/unidiomatic.sh"
S139_FX_GOOD="$SHELL_ROOT/scripts/test/fixtures/idiom/bash/idiomatic.sh"

# §139a (AC2): the bash idiom rubric SSOT exists AND carries each required criterion
# token — the deterministic set (safe_source, git add -A) and the LLM set (function
# altitude, DRY), plus the motivating SMELL and the #276/#490 reuse scope note. The
# `safe_source` criterion heading carries backticks, so match that literal form.
if [ -f "$S139_RUBRIC" ] \
   && grep -qF '`safe_source` discipline' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF 'git add -A' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF 'Function size / altitude' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF 'DRY across helpers' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF 'SMELL: detection-by-attribute-combination' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF "Reuse, don't re-handroll" "$S139_RUBRIC" 2>/dev/null; then
  ok "139a: .claude/rubrics/bash.md carries all required idiom criteria + SMELL + reuse note (#546)"
else
  ng "139a: .claude/rubrics/bash.md missing or lacks a required criterion / SMELL / reuse token (#546)"
fi

# §139b: code-reviewer.md wires the advisory axis — an Idiom notes (advisory) output
# section, the never-block rule (NEVER escalate to block), and the conditional per-
# language rubric read (.claude/rubrics/). All three are the wiring, not the criteria.
if grep -qF 'Idiom notes (advisory)' "$S139_CODE_REV" 2>/dev/null \
   && grep -qF 'NEVER escalate to' "$S139_CODE_REV" 2>/dev/null \
   && grep -qF '.claude/rubrics/' "$S139_CODE_REV" 2>/dev/null; then
  ok "139b: code-reviewer.md wires advisory idiom axis (Idiom notes + never-block + rubric read) (#546)"
else
  ng "139b: code-reviewer.md missing Idiom notes section, never-block rule, or .claude/rubrics/ read (#546)"
fi

# §139c (NARROWING GUARD, invariant #1): the criteria text lives ONLY in the rubric
# file, NOT inlined into the always-loaded reviewer prompt (else the rubric SSOT is a
# second copy that drifts). code-reviewer.md must NOT carry the rubric BODY tokens.
s139c_smell=$(grep -cF 'SMELL: detection-by-attribute-combination' "$S139_CODE_REV" 2>/dev/null)
s139c_norm=$(grep -cF 'normalize once' "$S139_CODE_REV" 2>/dev/null)
if [ "${s139c_smell:-0}" -eq 0 ] && [ "${s139c_norm:-0}" -eq 0 ]; then
  ok "139c: code-reviewer.md does NOT inline the rubric body (criteria stay SSOT in bash.md) (#546)"
else
  ng "139c: code-reviewer.md inlines rubric-body criteria text — drift risk, criteria must stay in bash.md (#546)"
fi

# §139d (AC4): SPEC §4.5.1 subsection exists AND MISSION.md names the axis. Both are
# Doc-confirming (landed in Phase A), so green now.
if grep -qF '#### 4.5.1 Readability / language-idiom review axis' "$S139_SPEC" 2>/dev/null \
   && grep -qF 'readability / language-idiom axis' "$S139_MISSION" 2>/dev/null; then
  ok "139d: SPEC §4.5.1 + MISSION.md carry the readability / language-idiom axis (#546)"
else
  ng "139d: SPEC §4.5.1 subsection or MISSION.md language-idiom-axis sentence missing (#546)"
fi

# §139e (B2 ANTI-VACUITY LOCK): the motivating-smell worked example is structurally
# explicit, not degraded to a bare mention. Require ALL THREE: the exemplar
# (Unidiomatic (but correct)), the discriminator-fix (branch on the discriminator OR
# normalize once), and the correct-but-unidiomatic property (The unidiomatic form is).
if grep -qF 'Unidiomatic (but correct)' "$S139_RUBRIC" 2>/dev/null \
   && { grep -qF 'branch on the explicit discriminator' "$S139_RUBRIC" 2>/dev/null \
        || grep -qF 'normalize once' "$S139_RUBRIC" 2>/dev/null; } \
   && grep -qF 'The unidiomatic form is' "$S139_RUBRIC" 2>/dev/null; then
  ok "139e: bash.md worked example is structurally explicit (exemplar + fix + correct-but-unidiomatic) (#546)"
else
  ng "139e: bash.md worked example degraded — missing exemplar, discriminator-fix, or correctness note (#546)"
fi

# §139f (CHECKER DEMONSTRATION, AC3 — LOAD-BEARING intended-RED): the born-advisory
# deterministic checker flags unidiomatic.sh (emits findings) and clears idiomatic.sh
# (no findings). Both fixtures are shellcheck-warning-CLEAN, proving the idiom axis is
# distinct from the correctness axis. scripts/lint_bash_idioms.sh does not exist until
# Phase C, so this MUST fail now — the intended Phase-B red. Guarded so an absent
# checker (or absent fixture) fails CLEANLY as ng, never a hard error.
if [ ! -f "$S139_FX_BAD" ] || [ ! -f "$S139_FX_GOOD" ]; then
  ng "139f: idiom fixtures missing (unidiomatic.sh / idiomatic.sh) — cannot demonstrate checker (#546)"
elif [ ! -f "$S139_CHECKER" ]; then
  ng "139f: scripts/lint_bash_idioms.sh absent — deterministic idiom checker not yet implemented (#546 Phase C)"
else
  s139f_bad_out="$(bash "$S139_CHECKER" "$S139_FX_BAD" 2>/dev/null)"
  s139f_good_out="$(bash "$S139_CHECKER" "$S139_FX_GOOD" 2>/dev/null)"
  if [ -n "$s139f_bad_out" ] && [ -z "$s139f_good_out" ]; then
    ok "139f: lint_bash_idioms.sh flags unidiomatic.sh and clears idiomatic.sh (#546)"
  else
    ng "139f: lint_bash_idioms.sh did not flag unidiomatic.sh or wrongly flagged idiomatic.sh (#546)"
  fi
fi
# ---------- §140: merge-completeness advisory warn (#548) ----------
# SPEC §6.1 'merge-completeness' advisory row — the POSITIVE completeness face of
# the #544 merge-attestation block (origin: handol #244, an implementation commit
# never pushed so only the Phase-B test reached the head → the merge would land a
# test with no code). An INDEPENDENT advisory arm sequenced AFTER the merge-
# attestation arm on the same `gh pr merge` entry-grep. On a `feat`/`fix` PR whose
# merge diff touches ZERO source files (non-empty file list, every path test/doc)
# it emits `audit_log warn merge-completeness` + a one-line stderr notice and
# ALLOWS (rc 0) — it NEVER blocks. PR type resolves from the PR headRefName
# (`<user>/(feat|fix)/…`) with a PR-title conventional-commit fallback. Source-vs-
# test/doc REUSES the `.shellsecretignore` allow-list via secret_scan_path_allowed
# (no new glob list). One bounded `gh pr view <pr> --json headRefName,title,files`
# feeds both type + file list. Fail-open throughout (gh down / empty list → no warn).
#
# The arm DOES NOT EXIST YET (Phase B / Doc→Test→Code). Assertion (a) is the load-
# bearing INTENDED RED: it observes rc 0 (the merge falls through to allow) but NO
# merge-completeness warn record (the absent arm never writes one) → RED. (b)/(c)/(d)
# hold trivially now (no arm ⇒ no warn) and stay green when Phase C lands the arm.
#
# To REACH the completeness arm, the merge-review arm above must ALLOW first. The
# completeness arm must run even in the gh-DOWN §140d case, where merge-review
# would FAIL CLOSED (#586) — so the repo carries `.claude/state/review-gate=bypass`
# (cwd-relative, resolve_review_gate reads it), which skips merge-review with a
# loud `merge-review bypass` audit and NO gh calls, regardless of gh being down.
# That bypass record is category=merge-review, orthogonal to the merge-completeness
# category the assertions below key on. The repo carries a committed
# `.shellsecretignore` (copied from SHELL_ROOT) at HEAD so the arm's
# secret_scan_path_allowed classifier loads the real test/doc/example globs; it has
# NO upstream so push-parity always allows; ac-closeout allows (empty closingIssues).
S140_DIR=$(mktemp -d)
S140_SHIM="$S140_DIR/bin"
S140_STATE="$S140_DIR/ghstate"   # GH_SHIM_STATE for the gh shim
mkdir -p "$S140_SHIM" "$S140_STATE"

S140_HEAD='mc-head-999'
printf '%s\n' "$S140_HEAD" > "$S140_STATE/head_ref_oid"  # merge-attestation staleness match
printf '77\n' > "$S140_STATE/pr_number"

# gh shim (mirrors §137): a forced-DOWN toggle (touch $GH_SHIM_STATE/gh_down) makes
# every gh call error. headRefOid feeds merge-attestation; closingIssuesReferences
# empty → ac-closeout allows; the NEW `--json headRefName,title,files` call (matched
# by the *files* arm) returns the per-case canned PR JSON object driving the
# completeness arm's type + file-list.
cat > "$S140_SHIM/gh" <<'SHIM'
#!/bin/sh
if [ -f "$GH_SHIM_STATE/gh_down" ]; then
  echo "gh: shim forced down (no network)" >&2
  exit 1
fi
case "$*" in
  *"pr view"*headRefOid*)              cat "$GH_SHIM_STATE/head_ref_oid" 2>/dev/null ;;
  *"pr view"*closingIssuesReferences*) : ;;   # empty → ac-closeout allows
  *"pr view"*files*)                   cat "$GH_SHIM_STATE/pr_view_json" 2>/dev/null ;;
  *"pr view"*number*)                  cat "$GH_SHIM_STATE/pr_number" 2>/dev/null ;;
esac
exit 0
SHIM
chmod +x "$S140_SHIM/gh"

# Throwaway repo with a committed `.shellsecretignore` at HEAD + no upstream. Built
# once; every case runs `gh pr merge 77 --merge` here. Mirrors the §137 build idiom.
s140_repo=$(
  d=$(mktemp -d); work="$d/work"
  git init -q "$work" 2>/dev/null
  (
    cd "$work" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    git checkout -q -b smoke/feat/1-completeness 2>/dev/null || true
    mkdir -p .claude/state
    printf 'bypass\n' > .claude/state/review-gate   # #586: bypass merge-review (survives gh-down §140d)
    cp "$SHELL_ROOT/.shellsecretignore" .shellsecretignore
    git add .shellsecretignore
    git commit -q -m c1
  )
  printf '%s' "$work"
)
S140_CANON=$(cd "$s140_repo" && pwd -P)

# Run `gh pr merge 77 --merge` in the repo with a per-case gh-JSON + state-dir
# override (carrying a VALID pr-77 attestation + its own audit log + registry).
# Sets S140_RC and S140_TAIL (the audit records this fire appended).
s140_case() {
  local pr_json="$1" statedir="$2" before after
  mkdir -p "$statedir/audit"
  printf '%s\n' "$S140_CANON" > "$statedir/registry.txt"       # in_scope under the override
  printf '%s' "$pr_json" > "$S140_STATE/pr_view_json"
  before=$(wc -l < "$statedir/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
  (
    cd "$s140_repo" || exit 1
    # shellcheck disable=SC2069  # intentional: capture stderr, discard stdout
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' 'gh pr merge 77 --merge' | jq -Rs .)" \
      | PATH="$S140_SHIM:$PATH" \
        GH_SHIM_STATE="$S140_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        GHJIG_STATE_DIR_OVERRIDE="$statedir" \
        bash "$HOOK" >/dev/null 2>&1
  )
  S140_RC=$?
  after=$(wc -l < "$statedir/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
  S140_TAIL=""
  [ "$(( after - before ))" -gt 0 ] && S140_TAIL=$(tail -"$(( after - before ))" "$statedir/audit/audit.jsonl" 2>/dev/null)
}

# §140a (LOAD-BEARING INTENDED RED): feat PR + a merge diff that is ALL test/doc
# (README.md matches `*.md`; tests/foo.py matches `tests/`) → the arm should emit a
# merge-completeness warn and ALLOW. RED now: the arm is absent ⇒ rc 0 but NO warn
# record ⇒ the `warn present` conjunct fails ⇒ clean ng (not a hard error).
s140_case '{"headRefName":"ilgyu-yi/feat/99-x","title":"feat(#99): x","files":[{"path":"README.md"},{"path":"tests/foo.py"}]}' "$S140_DIR/a"
if [ "$S140_RC" = 0 ] && printf '%s' "$S140_TAIL" | grep -q '"category":"merge-completeness"'; then
  ok "140a: feat PR whose merge diff is all test/doc → merge-completeness advisory warn + allow (#548)"
else
  ng "140a: feat/all-test-doc merge should WARN + allow (rc=$S140_RC; arm absent ⇒ no merge-completeness warn ⇒ RED) tail=$S140_TAIL (#548)"
fi

# §140b: feat PR whose diff TOUCHES SOURCE (scripts/lint.sh is not allow-listed) →
# no warn, allow. Passes now (no arm ⇒ no warn) and stays green after Phase C.
s140_case '{"headRefName":"ilgyu-yi/feat/99-x","title":"feat(#99): x","files":[{"path":"scripts/lint.sh"}]}' "$S140_DIR/b"
if [ "$S140_RC" = 0 ] && ! printf '%s' "$S140_TAIL" | grep -q '"category":"merge-completeness"'; then
  ok "140b: feat PR touching a source file → no merge-completeness warn, allow (#548)"
else
  ng "140b: feat+source merge must NOT warn (rc=$S140_RC) tail=$S140_TAIL (#548)"
fi

# §140c: NON-feat/fix type (chore branch + chore title) + all-test/doc files → no
# warn, allow (type gate). Passes now and stays green after Phase C.
s140_case '{"headRefName":"ilgyu-yi/chore/99-x","title":"chore: x","files":[{"path":"README.md"},{"path":"tests/foo.py"}]}' "$S140_DIR/c"
if [ "$S140_RC" = 0 ] && ! printf '%s' "$S140_TAIL" | grep -q '"category":"merge-completeness"'; then
  ok "140c: non-feat/fix type + all-test/doc files → no merge-completeness warn, allow (#548)"
else
  ng "140c: chore-type merge must NOT warn (rc=$S140_RC) tail=$S140_TAIL (#548)"
fi

# §140d (FAIL-OPEN): gh forced DOWN on a feat branch → the completeness arm cannot
# fetch its file list → no warn, never a block (rc 0). (merge-attestation also fail-
# opens here — attest file present + gh down — so rc stays 0.) The grep excludes the
# merge-attestation fail-open-skip warn by pinning the category. Green now + after.
touch "$S140_STATE/gh_down"
s140_case '{"headRefName":"ilgyu-yi/feat/99-x","title":"feat(#99): x","files":[{"path":"README.md"}]}' "$S140_DIR/d"
rm -f "$S140_STATE/gh_down"
if [ "$S140_RC" = 0 ] && ! printf '%s' "$S140_TAIL" | grep -q '"category":"merge-completeness"'; then
  ok "140d: gh down (fail-open) → no merge-completeness warn, never blocks (rc 0) (#548)"
else
  ng "140d: gh-down fail-open must allow with no merge-completeness warn (rc=$S140_RC) tail=$S140_TAIL (#548)"
fi

rm -rf "$S140_DIR" "$(dirname "$s140_repo")"
# ---------- 141. one-body phase-split guard (#579) ----------
# Pins the #579 contract: a multi-phase change (Doc/Test/Code) is ONE Execution
# Issue whose phases are *commits*, not three separate issues; the issue-reviewer
# gains an ADVISORY phase-slice Check 6 that flags the split-across-issues
# anti-pattern but NEVER escalates to block (the ship/refine/block grammar is
# unchanged). Structural content-lock (mirrors §132): assert the presence of the
# CHECK and its KEY CONCEPTS via a small set of STABLE tokens, NOT the full literal
# exemplar prose (which will churn). Anti-vacuity: the SPEC lock (141e) requires the
# observable-discriminator AND the never-block clause together on the Phase-slice
# bullet, so a bare mention cannot green it.
#
# 141a was RED before Phase C (issue-reviewer.md Check 6) landed — the intended
# Phase-B failure — and is GREEN once Check 6 is in place. 141b-e are
# Doc-phase-confirming (SPEC §1.2 / §4.7), expected GREEN throughout.
S141_REVIEWER="$SHELL_ROOT/.claude/agents/issue-reviewer.md"
S141_SPEC="$SHELL_ROOT/SPEC.md"

# §141a (LOAD-BEARING INTENDED RED — Phase C target): issue-reviewer.md carries the
# advisory phase-slice Check 6. Stable-token structural lock: a phase-slice token AND
# an advisory-never-block token AND a doc-deliverable/ADR negative concept (terminal
# artifact / ADR) AND a dir-mode Directive distinction token. The load-bearing RED
# drivers are `phase-slice` and `terminal artifact`/`ADR` (both count 0 in the file
# today); the file already carries `Directive` (open-issues fetch line) so that arm
# alone is not distinctive — the AND makes 141a red cleanly until Phase C adds Check 6.
if [ -f "$S141_REVIEWER" ]; then
  if grep -qiE 'phase.slice' "$S141_REVIEWER" \
     && grep -qiE 'advisory|never[^.]*block' "$S141_REVIEWER" \
     && grep -qiE 'terminal artifact|\bADR\b' "$S141_REVIEWER" \
     && grep -qiF 'Directive' "$S141_REVIEWER"; then
    ok "141a: issue-reviewer.md carries the advisory phase-slice Check 6 (phase-slice + never-block + ADR/terminal-artifact negative + Directive distinction) (#579)"
  else
    ng "141a: issue-reviewer.md missing phase-slice Check 6 (expected RED until Phase C: needs phase-slice + advisory-never-block + ADR/terminal-artifact negative + Directive distinction) (#579)"
  fi
else
  ng "141a: issue-reviewer.md file missing (#579)"
fi

# §141b (Doc-confirming, expected GREEN): SPEC §4.7 carries the Phase-slice Check 6
# with the advisory-never-block clause. Line-scoped to the Phase-slice bullet so the
# advisory/never/block tokens must co-occur on the check itself, not scattered.
if [ -f "$S141_SPEC" ]; then
  s141b=$(grep 'Phase-slice' "$S141_SPEC")
  if [ -n "$s141b" ] \
     && printf '%s' "$s141b" | grep -qi 'advisory' \
     && printf '%s' "$s141b" | grep -qi 'never' \
     && printf '%s' "$s141b" | grep -qiF 'block'; then
    ok "141b: SPEC §4.7 Phase-slice Check 6 is advisory and never blocks (#579)"
  else
    ng "141b: SPEC §4.7 missing Phase-slice Check 6 advisory-never-block clause (#579)"
  fi
else
  ng "141b: SPEC.md file missing (#579)"
fi

# §141c (Doc-confirming, expected GREEN): SPEC §1.2 carries the Issue-level corollary
# anchor AND the 1:N carve-out phrasing (constrains issue granularity, NOT PR count;
# issue→PR is 1:N) — so the corollary can't silently drift back to "one PR". Line-scoped.
if [ -f "$S141_SPEC" ]; then
  s141c=$(grep 'Issue-level corollary' "$S141_SPEC")
  if [ -n "$s141c" ] \
     && printf '%s' "$s141c" | grep -qi 'constrains' \
     && printf '%s' "$s141c" | grep -qiF 'PR count' \
     && printf '%s' "$s141c" | grep -qF '1:N'; then
    ok "141c: SPEC §1.2 Issue-level corollary pins the 1:N issue-vs-PR carve-out (#579)"
  else
    ng "141c: SPEC §1.2 missing Issue-level corollary anchor or 1:N carve-out phrasing (#579)"
  fi
else
  ng "141c: SPEC.md file missing (#579)"
fi

# §141d (invariant — verdict grammar unchanged): issue-reviewer.md still emits EXACTLY
# ship/refine/block — the advisory Check 6 added no new verdict token. Assert the three
# canonical verdicts present AND zero non-canonical `VERDICT: <word>` tokens. Passes now
# and must still pass after Phase C.
if [ -f "$S141_REVIEWER" ]; then
  s141d_extra=$(grep -oE 'VERDICT: [a-z]+' "$S141_REVIEWER" | grep -vE 'VERDICT: (ship|refine|block)' | wc -l | tr -d ' ')
  if grep -qF 'VERDICT: ship' "$S141_REVIEWER" \
     && grep -qF 'VERDICT: refine' "$S141_REVIEWER" \
     && grep -qF 'VERDICT: block' "$S141_REVIEWER" \
     && [ "${s141d_extra:-1}" -eq 0 ]; then
    ok "141d: issue-reviewer.md verdict grammar is exactly ship/refine/block — no new verdict (#579)"
  else
    ng "141d: issue-reviewer.md verdict grammar changed — expected exactly ship/refine/block (#579)"
  fi
else
  ng "141d: issue-reviewer.md file missing (#579)"
fi

# §141e (anti-vacuity, expected GREEN): the SPEC §4.7 Phase-slice bullet is not a bare
# mention — it must carry the observable-discriminator concept (open-issues sibling /
# body-defers) AND the never-block clause together on the same bullet. Line-scoped.
if [ -f "$S141_SPEC" ]; then
  s141e=$(grep 'Phase-slice' "$S141_SPEC")
  if [ -n "$s141e" ] \
     && printf '%s' "$s141e" | grep -qiF 'open-issues' \
     && printf '%s' "$s141e" | grep -qiE 'body itself deferring|body-defers|deferring a sibling' \
     && printf '%s' "$s141e" | grep -qi 'never'; then
    ok "141e: SPEC §4.7 Phase-slice bullet pairs the observable discriminator with the never-block clause (#579)"
  else
    ng "141e: SPEC §4.7 Phase-slice bullet missing observable-discriminator (open-issues/body-defers) or never-block clause (#579)"
  fi
else
  ng "141e: SPEC.md file missing (#579)"
fi

# ---------- §143: /file-review producer command content-lock (#585) ----------
# SPEC §5.29 + .claude/commands/file-review.md. `/file-review <pr>` is the verdict-
# materializer — runs code-reviewer on a PR and posts its verdict as a first-class,
# commit_id-pinned GitHub review. It is producer-only (adds/changes/removes NO merge
# gate — that is #586); this content-lock pins the #586 INTEGRATION CONTRACT so it
# cannot drift: the exact machine-readable marker token, the commit_id-pinned REST
# submission (NOT `gh pr review`, which cannot pin a commit — the §4.5 head-pin
# failure), the temp-file body transport with @mention neutralization, ownership
# resolution, <pr> validation, the file-review audit category, and the unconfirmed-
# head → post-nothing fail-closed arm.
#
# Doc landed (Phase A): (i)/(j) are SPEC-confirming and GREEN now. The command file
# DOES NOT EXIST YET (Phase C authors it): (a)-(h) are the load-bearing intended-RED
# — they fail until .claude/commands/file-review.md lands. Each command-file arm
# guards on `[ -f "$S143_CMD" ]` first, so an absent file fails CLEANLY as ng (an
# absence sub-check can never vacuously pass on a missing file).
S143_CMD="$SHELL_ROOT/.claude/commands/file-review.md"
S143_SPEC="$SHELL_ROOT/SPEC.md"

# §143a (INTEGRATION CONTRACT, #586 — LOAD-BEARING RED): the machine-readable marker
# carries the byte-identical token substrings from SPEC §5.29 —
# `<!-- file-review verdict=`, `head=`, and the engine field `reviewer=code-reviewer`.
# #586 binds these to the GitHub-attested review object, so the spelling is a hard
# contract, not free text.
if [ -f "$S143_CMD" ] \
   && grep -qF '<!-- file-review verdict=' "$S143_CMD" 2>/dev/null \
   && grep -qF 'head=' "$S143_CMD" 2>/dev/null \
   && grep -qF 'reviewer=code-reviewer' "$S143_CMD" 2>/dev/null; then
  ok "143a: file-review.md carries the exact marker token (verdict= + head= + reviewer=code-reviewer) (#585)"
else
  ng "143a: file-review.md missing or lacks the exact #586 marker token substrings (#585)"
fi

# §143b (COMMIT_ID PIN — LOAD-BEARING RED): the review is submitted commit_id-pinned
# via REST (`commit_id=` bound + the `pulls/…/reviews` endpoint) AND the plain
# `gh pr review --approve` CLI — which CANNOT pin a commit and would rebind an
# approval to a racing head — is ABSENT as a submission mechanism.
if [ -f "$S143_CMD" ] \
   && grep -qF 'commit_id=' "$S143_CMD" 2>/dev/null \
   && grep -qF 'pulls/' "$S143_CMD" 2>/dev/null \
   && ! grep -qF 'gh pr review --approve' "$S143_CMD" 2>/dev/null; then
  ok "143b: file-review.md pins commit_id via REST (pulls/…/reviews) and never uses gh pr review --approve (#585)"
else
  ng "143b: file-review.md missing commit_id/pulls REST pin, or uses the un-pinnable gh pr review --approve (#585)"
fi

# §143c (BODY TRANSPORT — LOAD-BEARING RED): the reviewer body goes through a written
# temp file (`body=@<file>`) — the activate.md/reflect.md --body-file idiom — and the
# untrusted reviewer text is NEVER interpolated via an inline `--body "` shell arg
# (an injection vector).
if [ -f "$S143_CMD" ] \
   && grep -qF 'body=@' "$S143_CMD" 2>/dev/null \
   && ! grep -qF -- '--body "' "$S143_CMD" 2>/dev/null; then
  ok "143c: file-review.md transports the body via body=@<tempfile>, never inline --body \" (#585)"
else
  ng "143c: file-review.md missing body=@ temp-file transport, or inline-interpolates via --body \" (#585)"
fi

# §143d (INJECTION DEFENSE — LOAD-BEARING RED): whole-body `@mention` neutralization
# is present — the same sanitize idiom SPEC §5.29 and activate.md name, so the posted
# review cannot mass-ping.
if [ -f "$S143_CMD" ] \
   && grep -qF '@mention' "$S143_CMD" 2>/dev/null; then
  ok "143d: file-review.md neutralizes @mention in the review body (#585)"
else
  ng "143d: file-review.md missing @mention neutralization (mass-ping injection defense) (#585)"
fi

# §143e (OWNERSHIP — LOAD-BEARING RED): ownership branching resolves the acting
# identity (`gh api user`) and the PR author (`--json author`) to pick native-review
# vs own-PR COMMENT (GitHub 422s a self approve/request-changes).
if [ -f "$S143_CMD" ] \
   && grep -qF 'gh api user' "$S143_CMD" 2>/dev/null \
   && grep -qF -- '--json author' "$S143_CMD" 2>/dev/null; then
  ok "143e: file-review.md resolves ownership via gh api user + --json author (#585)"
else
  ng "143e: file-review.md missing gh api user / --json author ownership resolution (#585)"
fi

# §143f (INPUT VALIDATION — LOAD-BEARING RED): `<pr>` is validated (the `^[0-9]+$`
# numeric form) before use — untrusted argument handling.
if [ -f "$S143_CMD" ] \
   && grep -qF '^[0-9]+$' "$S143_CMD" 2>/dev/null; then
  ok "143f: file-review.md validates <pr> against ^[0-9]+\$ before use (#585)"
else
  ng "143f: file-review.md missing the <pr> ^[0-9]+\$ validation token (#585)"
fi

# §143g (AUDIT — LOAD-BEARING RED): the command audits under the `file-review`
# category (the SPEC §5.29 decision trail: posted / invalid / aborted).
if [ -f "$S143_CMD" ] \
   && grep -qF 'audit_log' "$S143_CMD" 2>/dev/null \
   && grep -qF 'file-review' "$S143_CMD" 2>/dev/null; then
  ok "143g: file-review.md audits under the file-review category (#585)"
else
  ng "143g: file-review.md missing audit_log under the file-review category (#585)"
fi

# §143h (FAIL-CLOSED-TO-SILENCE — LOAD-BEARING RED): the unconfirmed / unresolvable
# head arm posts NOTHING and audits `invalid` — it never posts an unearned block on
# a head it could not blind-compare to the private PR head (SPEC §5.29 map row).
if [ -f "$S143_CMD" ] \
   && grep -qiF 'post nothing' "$S143_CMD" 2>/dev/null \
   && grep -qF 'invalid' "$S143_CMD" 2>/dev/null; then
  ok "143h: file-review.md fails closed on an unconfirmed head — post nothing + audit invalid (#585)"
else
  ng "143h: file-review.md missing the unconfirmed-head → post-nothing/invalid fail-closed arm (#585)"
fi

# §143i (Doc-confirming, expected GREEN): SPEC §5.29 section header exists.
if [ -f "$S143_SPEC" ] \
   && grep -qF '### 5.29' "$S143_SPEC" 2>/dev/null; then
  ok "143i: SPEC §5.29 /file-review section header present (#585)"
else
  ng "143i: SPEC §5.29 section header missing (#585)"
fi

# §143j (Doc-confirming, expected GREEN): the SAME exact marker token appears in SPEC
# §5.29 — the source of the §143a byte-identical contract (drift lock, both copies).
if [ -f "$S143_SPEC" ] \
   && grep -qF '<!-- file-review verdict=' "$S143_SPEC" 2>/dev/null; then
  ok "143j: SPEC §5.29 documents the exact file-review marker token (#585)"
else
  ng "143j: SPEC §5.29 missing the file-review marker token (#585)"
fi

# ---------- §144: auto-mode-classifier permissions.allow exception + /ship coupling (#587) ----------
# SPEC §5.7.1 "Composition with the auto-mode classifier" + .claude/settings.json
# permissions.allow + .claude/commands/ship.md step 10. #587 defers the auto-mode
# classifier for EXACTLY the /ship clean-merge form via a narrow, order-sensitive
# permissions.allow matcher — no trailing wildcard — so the classifier hands that one
# command to the shell's own merge-review gate (#586). The deferral is sound ONLY while
# review-gate=required; under bypass /ship must WITHHOLD the covered form so the
# classifier re-engages (Directive #584 Constraint 1: no naked self-merge hole).
#
# Phase status: the SPEC clause landed in Phase A (144k/144l GREEN now). Phase C of
# #591 propagates the exact matcher into settings.injected.json (144e intended-RED now
# — the entry is absent until Phase C adds it). The #587 settings.json + ship.md
# entries already landed (144a/144b/144f, 144h/144i/144j GREEN now). The
# narrowness/drift guards (144c/144d/144g) stay green — they lock the "opens nothing
# else" contract.
S144_SET="$SHELL_ROOT/.claude/settings.json"
S144_INJ="$SHELL_ROOT/.claude/settings.injected.json"
S144_SHIP="$SHELL_ROOT/.claude/commands/ship.md"
S144_SPEC="$SHELL_ROOT/SPEC.md"
# The one canonical merge literal, defined ONCE — both the settings.json matcher inner
# command and the ship.md step-10 emitted string must equal it byte-for-byte (§144f).
S144_CANON='gh pr merge --auto --merge --delete-branch'
# Step-10 block, scoped from the `10.` marker to `10.5.` — so tokens that already live
# in step 7.8 (/file-review, bypass) do NOT leak into the step-10 content-locks.
S144_STEP10=$(sed -n '/^10\. If mode is/,/^10\.5\./p' "$S144_SHIP" 2>/dev/null || true)

# §144a (LOAD-BEARING RED): settings.json carries the EXACT matcher, spelled byte-for-byte.
if [ -f "$S144_SET" ] && grep -qF "Bash($S144_CANON)" "$S144_SET" 2>/dev/null; then
  ok "144a: settings.json permissions.allow carries the exact matcher Bash($S144_CANON) (#587)"
else
  ng "144a: settings.json missing the exact permissions.allow matcher Bash($S144_CANON) (#587)"
fi

# §144b (LOAD-BEARING RED — presence + narrowness fused): the ONLY gh-pr-merge allow
# rule is that exact narrow form. Any broad shape (Bash(gh pr merge:*), Bash(gh pr
# merge *), bare Bash(gh pr merge)) matches the `Bash(gh pr merge` prefix but NOT the
# exact literal, so any!=exact fails — a non-vacuous both-directions lock.
if [ -f "$S144_SET" ]; then
  s144_any=$(grep -cF 'Bash(gh pr merge' "$S144_SET" 2>/dev/null || true)
  s144_exact=$(grep -cF "Bash($S144_CANON)" "$S144_SET" 2>/dev/null || true)
else
  s144_any=-1; s144_exact=-1
fi
if [ "$s144_exact" -ge 1 ] && [ "$s144_any" = "$s144_exact" ]; then
  ok "144b: the only gh-pr-merge allow rule is the exact narrow form — no broad/bare allow (any=$s144_any exact=$s144_exact) (#587)"
else
  ng "144b: settings.json must carry exactly the narrow matcher and NO broad gh-pr-merge allow (any=$s144_any exact=$s144_exact) (#587)"
fi

# §144c (narrowness guard, GREEN now / stays green): autoMode.classifyAllShell is NOT
# forced true — that would route ALL shell through the classifier and defeat the narrow
# allow. Guarded on file presence so an absent file fails as ng, not vacuously.
if [ -f "$S144_SET" ] && ! grep -qE '"classifyAllShell"[[:space:]]*:[[:space:]]*true' "$S144_SET" 2>/dev/null; then
  ok "144c: settings.json does not set autoMode.classifyAllShell=true (#587)"
else
  ng "144c: settings.json must not set autoMode.classifyAllShell=true (#587)"
fi

# §144d (narrowness guard, GREEN now / stays green): no permissions.deny entry matches
# gh-pr-merge — a deny would override the allow (deny > allow) and re-block the merge.
# jq-scoped to the deny array so a `gh` mention elsewhere cannot false-trip; jq also
# validates that settings.json is well-formed JSON.
if [ -f "$S144_SET" ]; then
  s144_deny=$(jq -r '[.permissions.deny // [] | .[] | select(test("gh pr merge"))] | length' "$S144_SET" 2>/dev/null || echo err)
else
  s144_deny=err
fi
if [ "$s144_deny" = "0" ]; then
  ok "144d: no permissions.deny entry overrides the gh-pr-merge allow (deny-matches=$s144_deny) (#587)"
else
  ng "144d: a permissions.deny entry matches gh-pr-merge (or settings.json is not valid JSON) (deny-matches=$s144_deny) (#587)"
fi

# §144e (LOAD-BEARING RED — cross-target propagation, presence + narrowness fused):
# #591 inverts the former dogfood-only invariant — the permissions.allow exception IS
# now propagated to injected targets. settings.injected.json must carry the SAME exact
# narrow matcher and, with the SAME both-directions discipline as §144b, NO broad shape:
# any broad form (Bash(gh pr merge:*), Bash(gh pr merge *), bare Bash(gh pr merge)) hits
# the `Bash(gh pr merge` prefix but not the exact literal, so any!=exact fails.
if [ -f "$S144_INJ" ]; then
  s144e_any=$(grep -cF 'Bash(gh pr merge' "$S144_INJ" 2>/dev/null || true)
  s144e_exact=$(grep -cF "Bash($S144_CANON)" "$S144_INJ" 2>/dev/null || true)
else
  s144e_any=-1; s144e_exact=-1
fi
if [ "$s144e_exact" -ge 1 ] && [ "$s144e_any" = "$s144e_exact" ]; then
  ok "144e: settings.injected.json carries the exact narrow matcher Bash($S144_CANON) and NO broad gh-pr-merge allow — propagated to targets (any=$s144e_any exact=$s144e_exact) (#591)"
else
  ng "144e: settings.injected.json must carry exactly the narrow matcher Bash($S144_CANON) and NO broad gh-pr-merge allow — cross-target propagation (any=$s144e_any exact=$s144e_exact) (#591)"
fi

# §144f (CRITICAL — LOAD-BEARING RED): byte-for-byte coupling. The settings.json matcher
# inner command and the ship.md step-10 emitted string must BOTH equal the single
# canonical literal. A silent drift on either side → the emitted command misses the
# matcher → the classifier re-engages → a permanent unattended park. Naming which side
# is present pinpoints a future drift.
s144_set_has=0; s144_ship_has=0
[ -f "$S144_SET" ] && grep -qF "Bash($S144_CANON)" "$S144_SET" 2>/dev/null && s144_set_has=1
[ -f "$S144_SHIP" ] && grep -qF "$S144_CANON" "$S144_SHIP" 2>/dev/null && s144_ship_has=1
if [ "$s144_set_has" = 1 ] && [ "$s144_ship_has" = 1 ]; then
  ok "144f: /ship merge string is byte-identical to the matcher inner command '$S144_CANON' (set=$s144_set_has ship=$s144_ship_has) (#587)"
else
  ng "144f: byte-for-byte coupling broken — matcher-side=$s144_set_has ship-side=$s144_ship_has, both must carry '$S144_CANON' (#587)"
fi

# §144g (drift guard, GREEN now / stays green): the step-10 clean arm carries NO
# positional-PR / --repo / -R gh-pr-merge variant — any of those misses the exact
# matcher (fail-safe = classifier re-engages, never over-allow). Guarded on a non-empty
# step-10 block so a mis-scoped extraction fails as ng, not vacuously.
if [ -n "$S144_STEP10" ] \
   && ! printf '%s\n' "$S144_STEP10" | grep -qE 'gh pr merge[[:space:]]+[0-9]' \
   && ! printf '%s\n' "$S144_STEP10" | grep -qF 'gh pr merge --repo' \
   && ! printf '%s\n' "$S144_STEP10" | grep -qF 'gh pr merge -R'; then
  ok "144g: /ship step-10 uses no positional-PR/--repo gh-pr-merge variant that would miss the matcher (#587)"
else
  ng "144g: /ship step-10 must not carry a positional-PR/--repo gh-pr-merge variant (or step-10 block not found) (#587)"
fi

# §144h (LOAD-BEARING RED): the step-10 required arm posts the head-pinned review via
# /file-review and gates the merge on the exact hook predicate review_gate_accepts.
# Scoped to the step-10 block so the /file-review mention in step 7.8 does not satisfy it.
if [ -n "$S144_STEP10" ] \
   && printf '%s\n' "$S144_STEP10" | grep -qF '/file-review' \
   && printf '%s\n' "$S144_STEP10" | grep -qF 'review_gate_accepts'; then
  ok "144h: /ship step-10 required arm posts via /file-review and gates on review_gate_accepts (#587)"
else
  ng "144h: /ship step-10 required arm missing /file-review post + review_gate_accepts gate (#587)"
fi

# §144i (LOAD-BEARING RED): the required arm branches deterministically on the gate
# result — 0 → merge (the covered form), 1 → PARK with reason merge-review-unsatisfied
# (the plan-mandated distinctive reason token, handling verdict=block and posts-nothing
# uniformly; MEMORY never-forge-merge-gate-evidence).
if [ -n "$S144_STEP10" ] \
   && printf '%s\n' "$S144_STEP10" | grep -qF 'review_gate_accepts' \
   && printf '%s\n' "$S144_STEP10" | grep -qiF 'merge-review-unsatisfied'; then
  ok "144i: /ship step-10 required arm parks (merge-review-unsatisfied) when review_gate_accepts rejects (#587)"
else
  ng "144i: /ship step-10 required arm missing the review_gate_accepts reject → park (merge-review-unsatisfied) branch (#587)"
fi

# §144j (LOAD-BEARING RED — bypass coupling, invariant 4): under review-gate=bypass the
# step-10 arm READS the toggle (resolve_review_gate) and WITHHOLDS the covered form so
# the classifier re-engages → park. Locks `resolve_review_gate` + `re-engage`.
if [ -n "$S144_STEP10" ] \
   && printf '%s\n' "$S144_STEP10" | grep -qF 'resolve_review_gate' \
   && printf '%s\n' "$S144_STEP10" | grep -qiF 're-engage'; then
  ok "144j: /ship step-10 bypass arm reads resolve_review_gate and withholds the covered form → classifier re-engages → park (#587)"
else
  ng "144j: /ship step-10 bypass arm missing resolve_review_gate + classifier-re-engage coupling (#587)"
fi

# §144k (Doc-confirming, expected GREEN): SPEC §5.7.1 clause header present.
if [ -f "$S144_SPEC" ] && grep -qF 'Composition with the auto-mode classifier' "$S144_SPEC" 2>/dev/null; then
  ok "144k: SPEC §5.7.1 'Composition with the auto-mode classifier' clause present (#587)"
else
  ng "144k: SPEC §5.7.1 auto-mode-classifier clause missing (#587)"
fi

# §144l (Doc-confirming, expected GREEN): the load-bearing bypass-coupling paragraph is
# present — the honest-scope invariant that bypass is not a naked merge hole.
if [ -f "$S144_SPEC" ] && grep -qF 'Bypass coupling' "$S144_SPEC" 2>/dev/null; then
  ok "144l: SPEC §5.7.1 bypass-coupling paragraph present (#587)"
else
  ng "144l: SPEC §5.7.1 bypass-coupling paragraph missing (#587)"
fi

# ---------- §142: Python idiom / readability rubric content-lock (#581) ----------
# Mirrors §139 (the bash idiom rubric lock) for the new Python rubric SSOT. #581 is a
# Doc-ONLY addition: it lands ONE file, .claude/rubrics/python.md, applied by
# code-reviewer as ADVISORY idiom-notes (the same axis as bash.md, SPEC §4.5.1). There
# is NO Code phase — no Python deterministic checker (deferred until a bound Python repo
# needs it; python.md §"Deterministic-vs-LLM boundary" records the deferral). So this is
# a DRIFT-GUARD that is GREEN on arrival (python.md landed in Phase A), not a red-first
# test. Each arm is guarded to fail CLEANLY as ng (loud, not a hard error) when the file
# or a token is absent.
S142_RUBRIC="$SHELL_ROOT/.claude/rubrics/python.md"

# §142a: the Python idiom rubric SSOT exists AND carries each required criterion /
# structural token verbatim — the title, the deterministic-vs-LLM boundary, a
# representative spread of the 9 criteria (EAFP, context manager, dataclass, type hint),
# the motivating design SMELL, and the #276/#490 reuse scope note.
if [ -f "$S142_RUBRIC" ] \
   && grep -qF '# Python idiom / readability rubric' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'Deterministic-vs-LLM boundary' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'EAFP' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'context manager' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'dataclass' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'type hint' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'SMELL: type-by-attribute-combination' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF "Reuse, don't re-handroll" "$S142_RUBRIC" 2>/dev/null; then
  ok "142a: .claude/rubrics/python.md carries title + boundary + criteria spread + SMELL + reuse note (#581)"
else
  ng "142a: .claude/rubrics/python.md missing or lacks a required criterion / SMELL / reuse token (#581)"
fi

# §142b (ANTI-VACUITY LOCK, mirrors §139e): the motivating-smell worked example is
# structurally explicit, not degraded to a bare mention. Require ALL THREE: the exemplar
# (Unpythonic (but correct)), the Pythonic discriminator-fix (dispatch / match /
# singledispatch OR the explicit-discriminator phrase), and the correct-but-unpythonic
# property (The unpythonic form is). If any is missing the case fails.
if [ -f "$S142_RUBRIC" ] \
   && grep -qF 'Unpythonic (but correct)' "$S142_RUBRIC" 2>/dev/null \
   && { grep -qF 'dispatch' "$S142_RUBRIC" 2>/dev/null \
        || grep -qF 'match' "$S142_RUBRIC" 2>/dev/null \
        || grep -qF 'singledispatch' "$S142_RUBRIC" 2>/dev/null \
        || grep -qF 'explicit discriminator' "$S142_RUBRIC" 2>/dev/null; } \
   && grep -qF 'The unpythonic form is' "$S142_RUBRIC" 2>/dev/null; then
  ok "142b: python.md worked example is structurally explicit (exemplar + discriminator-fix + correct-but-unpythonic) (#581)"
else
  ng "142b: python.md worked example degraded — missing exemplar, discriminator-fix, or correctness note (#581)"
fi

# §142c (advisory-never-block contract, mirrors bash.md): the rubric records that its
# criteria are advisory and never escalate to block — a `never` + `block` co-occurrence
# on one line, or the standalone `advisory` marker.
if [ -f "$S142_RUBRIC" ] \
   && { grep -qF 'advisory' "$S142_RUBRIC" 2>/dev/null \
        || grep -n 'never' "$S142_RUBRIC" 2>/dev/null | grep -qF 'block'; }; then
  ok "142c: python.md records the advisory-never-block contract (advisory / never+block) (#581)"
else
  ng "142c: python.md missing the advisory-never-block wording (advisory or never+block) (#581)"
fi

# ---------- §145: issue-title principle content-lock (#583) ----------
# Mirrors §142 (the python.md drift-guard): a content-lock that is GREEN on arrival, not
# a red-first test. Phase A of #583 already committed the SPEC §9.2 "Title principle"
# paragraph (the issue title is a plain problem statement, NOT the `<type>(#N):`
# commit/PR-subject form; a guiding norm, not a hard gate). AC4 asks for a drift-guard so
# a later edit that dilutes or drops the principle fails CI. Each arm is `[ -f ]`-guarded
# so an absent SPEC / template fails CLEANLY as ng (loud), not a hard error.
S145_SPEC="$SHELL_ROOT/SPEC.md"
S145_ISSUE_TPL="$SHELL_ROOT/.claude/templates/issue.md"

# §145a: SPEC §9.2 carries the title-principle tokens verbatim — the distinctive header
# phrase (Title principle), the clarity principle (plain problem statement), and the
# anti-commit-form note (used for issue titles — the §9.2-distinctive negation of the
# `<type>(#N):` form). All three must be byte-present or the principle has drifted.
if [ -f "$S145_SPEC" ] \
   && grep -qF 'Title principle' "$S145_SPEC" 2>/dev/null \
   && grep -qF 'plain problem statement' "$S145_SPEC" 2>/dev/null \
   && grep -qF 'used for issue titles' "$S145_SPEC" 2>/dev/null; then
  ok "145a: SPEC §9.2 carries the title principle (Title principle + plain problem statement + used for issue titles) (#583)"
else
  ng "145a: SPEC §9.2 missing a title-principle token (Title principle / plain problem statement / used for issue titles) (#583)"
fi

# §145b (ANTI-VACUITY / norm-not-gate lock): the principle is stated as a guiding norm,
# NOT a hard lint/gate. Require the exact norm-not-format wording so an edit that
# silently promotes the principle into a gate (or collapses the nuance) fails.
if [ -f "$S145_SPEC" ] \
   && grep -qF 'guiding norm, not a rigid format' "$S145_SPEC" 2>/dev/null; then
  ok "145b: SPEC §9.2 keeps the norm-not-gate framing (guiding norm, not a rigid format) (#583)"
else
  ng "145b: SPEC §9.2 lost the norm-not-gate framing (guiding norm, not a rigid format) (#583)"
fi

# §145c (thin-pointer lock): the issue.md template carries the one-line title hint that
# points back to SPEC §9.2 — the plain-problem-statement cue at author time.
if [ -f "$S145_ISSUE_TPL" ] \
   && grep -qF 'Title: a plain problem statement' "$S145_ISSUE_TPL" 2>/dev/null \
   && grep -qF 'SPEC §9.2' "$S145_ISSUE_TPL" 2>/dev/null; then
  ok "145c: issue.md template carries the title hint pointer to SPEC §9.2 (#583)"
else
  ng "145c: issue.md template missing the title hint pointer (Title: a plain problem statement / SPEC §9.2) (#583)"
fi

# ---------- §146: is_covered_ship_merge_form helper unit + presence (#592) ----------
# The #592 bypass backstop blocks IFF BOTH the command is the exact covered ship
# form AND it is a self-merge. is_covered_ship_merge_form is the form half: it
# returns 0 for EXACTLY `gh pr merge --auto --merge --delete-branch` (the
# settings.json:4 static-allow entry, tolerating a leading gh global-flag run) and
# non-zero for anything else. Sourced from ac_closeout_gate.sh the same way the
# hook safe_sources it. RED now: Phase C has not added the function.
#
# ANTI-VACUITY: every assertion runs the helper via s146_rc, which prints 127 when
# the function is ABSENT. The positive requires rc=0 (absent ⇒ 127 ⇒ ng/RED). The
# negatives require a PRESENT-and-non-zero rc (rc != 0 AND rc != 127) — an absent
# function reports 127 and fails the guard, so a negative can NEVER vacuously green
# on the missing helper. All six are RED now and turn GREEN only when the helper
# exists AND classifies each form correctly.
S146_GATE="$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh"

# s146_rc <cmd> — source the gate in a subshell and print is_covered_ship_merge_form's
# exit code, or 127 if the function is undefined (Phase C absent).
s146_rc() {
  (
    # shellcheck source=/dev/null
    . "$S146_GATE" 2>/dev/null
    command -v is_covered_ship_merge_form >/dev/null 2>&1 || { printf 127; exit; }
    is_covered_ship_merge_form "$1" >/dev/null 2>&1
    printf '%s' "$?"
  )
}

# §146a (presence): the function is defined after sourcing ac_closeout_gate.sh.
if [ "$(s146_rc 'gh pr merge --auto --merge --delete-branch')" != 127 ]; then
  ok "146a: is_covered_ship_merge_form defined in ac_closeout_gate.sh (#592)"
else
  ng "146a: is_covered_ship_merge_form undefined — Phase C absent (#592)"
fi

# §146b (positive): the EXACT covered form → 0.
if [ "$(s146_rc 'gh pr merge --auto --merge --delete-branch')" = 0 ]; then
  ok "146b: is_covered_ship_merge_form returns 0 for the exact covered ship form (#592)"
else
  ng "146b: is_covered_ship_merge_form must return 0 for 'gh pr merge --auto --merge --delete-branch' (#592)"
fi

# §146c (negative — extra flag): a superset with an extra flag → non-zero.
s146c=$(s146_rc 'gh pr merge --auto --merge --delete-branch --draft')
if [ "$s146c" != 0 ] && [ "$s146c" != 127 ]; then
  ok "146c: is_covered_ship_merge_form rejects an extra flag (--draft) (#592)"
else
  ng "146c: is_covered_ship_merge_form must reject the covered form + an extra flag (rc=$s146c) (#592)"
fi

# §146d (negative — reordered): the same flags in a different order → non-zero.
s146d=$(s146_rc 'gh pr merge --merge --auto --delete-branch')
if [ "$s146d" != 0 ] && [ "$s146d" != 127 ]; then
  ok "146d: is_covered_ship_merge_form rejects a reordered flag run (#592)"
else
  ng "146d: is_covered_ship_merge_form must reject '--merge --auto --delete-branch' (reordered) (rc=$s146d) (#592)"
fi

# §146e (negative — positional PR): an explicit PR number → non-zero.
s146e=$(s146_rc 'gh pr merge 55 --auto --merge --delete-branch')
if [ "$s146e" != 0 ] && [ "$s146e" != 127 ]; then
  ok "146e: is_covered_ship_merge_form rejects a positional PR number (#592)"
else
  ng "146e: is_covered_ship_merge_form must reject 'gh pr merge 55 --auto --merge --delete-branch' (rc=$s146e) (#592)"
fi

# §146f (negative — wrong strategy): --squash instead of --merge → non-zero.
s146f=$(s146_rc 'gh pr merge --auto --squash --delete-branch')
if [ "$s146f" != 0 ] && [ "$s146f" != 127 ]; then
  ok "146f: is_covered_ship_merge_form rejects a wrong strategy (--squash) (#592)"
else
  ng "146f: is_covered_ship_merge_form must reject '--auto --squash --delete-branch' (wrong strategy) (rc=$s146f) (#592)"
fi

# ---------- §147 label description ≤100 chars (#596) ----------
# GitHub caps label descriptions at 100 chars; an over-length --description
# makes `gh label create` return HTTP 422, which under `set -euo pipefail`
# aborts ensure_v3_labels.sh mid-run and leaves the dir-mode substrate
# half-installed (the subsequent inline directive/initiative labels in
# onboard_target.sh never get created). Assert every description the script
# authors is ≤100 chars. Count-guard (anti-vacuity, top-of-file norm): fail
# loud if the parse finds too few ensure_label lines — a vacuous green here
# would read as coverage while guarding nothing.
S147_SRC="$SHELL_ROOT/scripts/ensure_v3_labels.sh"
if [ ! -f "$S147_SRC" ]; then
  ng "147: MISSING ensure_v3_labels.sh — cannot check label description lengths (#596)"
else
  s147_over=""
  s147_n=0
  while IFS= read -r line; do
    case "$line" in
      ensure_label\ \"*) ;;
      *) continue ;;
    esac
    name=$(printf '%s\n' "$line" | sed -E 's/.*ensure_label "([^"]+)".*/\1/')
    desc=$(printf '%s\n' "$line" | sed -E 's/.*"[0-9A-Fa-f]{6}" +"(.*)"[[:space:]]*$/\1/')
    s147_n=$((s147_n+1))
    if [ "${#desc}" -gt 100 ]; then
      s147_over="$s147_over $name(${#desc})"
    fi
  done < "$S147_SRC"
  if [ "$s147_n" -lt 10 ]; then
    ng "147: parsed only $s147_n ensure_label lines (<10) — parser drift, not a real pass (#596)"
  elif [ -n "$s147_over" ]; then
    ng "147: label descriptions exceed GitHub's 100-char limit:$s147_over (#596)"
  else
    ok "147: all $s147_n ensure_v3_labels.sh label descriptions ≤100 chars (#596)"
  fi
fi

# ---------- results ----------
echo
echo "smoke: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1
