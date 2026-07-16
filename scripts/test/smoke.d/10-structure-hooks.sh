# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

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
# TMP + its EXIT trap now live in _preamble.sh (shared scratch dir, #600).
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

# 11i (#615): a SUPERSEDED FAILURE check-run must not count — statusCheckRollup can
# retain a stale entry for a check that failed then passed on re-run (e.g. fragment-gate
# before/after a skip-changelog label). ship_classify_blocker must dedup to the LATEST
# check-run per name/context before the FAILURE test, else a clean PR is false-`hard`-parked.
# 11i: {FAILURE(early), SUCCESS(late)} same name → clean. RED pre-fix (any-FAILURE sees the stale entry).
(
  if command -v ship_classify_blocker >/dev/null 2>&1; then
    j='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":[{"name":"gate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:00:05Z"},{"name":"gate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:01:00Z","completedAt":"2026-01-01T00:01:05Z"}]}'
    [ "$(printf '%s' "$j" | ship_classify_blocker 2>/dev/null)" = clean ]
  else exit 1; fi
) && ok "classify: superseded FAILURE (stale, newer SUCCESS same check) → clean (#615)" || ng "classify: a stale FAILURE superseded by a newer SUCCESS should classify clean, not hard (#615)"

# 11j (#615, no-false-clean guard): {SUCCESS(early), FAILURE(late)} same name → hard. A genuinely
# failing LATEST check still parks. Passes pre- and post-fix (locks the safety floor).
(
  if command -v ship_classify_blocker >/dev/null 2>&1; then
    j='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":[{"name":"gate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:00:05Z"},{"name":"gate","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-01T00:01:00Z","completedAt":"2026-01-01T00:01:05Z"}]}'
    [ "$(printf '%s' "$j" | ship_classify_blocker 2>/dev/null)" = hard ]
  else exit 1; fi
) && ok "classify: genuinely-failing LATEST check → hard (no false-clean) (#615)" || ng "classify: a newer FAILURE (latest) must still classify hard (#615)"

# 11k (#615, guard): {SUCCESS(early), PENDING(late)} same name → soft. A fresh in-progress re-run
# is still soft. Passes pre- and post-fix.
(
  if command -v ship_classify_blocker >/dev/null 2>&1; then
    j='{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"APPROVED","statusCheckRollup":[{"name":"gate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:00:05Z"},{"name":"gate","status":"IN_PROGRESS","startedAt":"2026-01-01T00:01:00Z"}]}'
    [ "$(printf '%s' "$j" | ship_classify_blocker 2>/dev/null)" = soft ]
  else exit 1; fi
) && ok "classify: fresh IN_PROGRESS re-run (latest) → soft (#615)" || ng "classify: a newer in-progress check (latest) must classify soft (#615)"

# 11l (#615): {PENDING(early), SUCCESS(late)} same name → clean. A stale in-progress entry
# superseded by a completed SUCCESS must not keep the PR soft. RED pre-fix (any-PENDING sees the stale entry).
(
  if command -v ship_classify_blocker >/dev/null 2>&1; then
    j='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","statusCheckRollup":[{"name":"gate","status":"IN_PROGRESS","startedAt":"2026-01-01T00:00:00Z"},{"name":"gate","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:01:00Z","completedAt":"2026-01-01T00:01:05Z"}]}'
    [ "$(printf '%s' "$j" | ship_classify_blocker 2>/dev/null)" = clean ]
  else exit 1; fi
) && ok "classify: superseded IN_PROGRESS (stale, newer SUCCESS same check) → clean (#615)" || ng "classify: a stale in-progress superseded by a newer SUCCESS should classify clean, not soft (#615)"

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
# HOOK now defined in _preamble.sh (#600).
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
# POST_HOOK now defined in _preamble.sh (#600).
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

