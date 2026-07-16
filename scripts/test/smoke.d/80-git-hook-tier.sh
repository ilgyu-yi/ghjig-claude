# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after 70-gates-contentlocks.sh (#604). The
# guarded source below never runs at runtime (the orchestrator already sourced
# the preamble); it only lets shellcheck resolve the shared globals.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §152 (#604): local git-hook enforcement tier (SPEC §6.7) ----------
# A committed `.githooks/` tier of adapters (`_lib.sh`, `pre-commit`, `pre-push`,
# `commit-msg`) that SOURCE the existing `.claude/hooks/helpers/` functions and
# call them — copying NO check logic — activated per-clone via a repo-local
# `core.hooksPath`, installed by `scripts/install_git_hooks.sh`. This section
# pins two properties:
#
#   (a) STATIC single-source + shape — the adapters exist, are executable, pin
#       their interpreter, CALL their helper functions, and carry NO copied
#       pattern literal (the §9 single-source invariant), and the installer is
#       repo-local-only (never --global/--system, §3.4 boundary).
#   (b) BEHAVIORAL — driving REAL local git ops (not the CC PreToolUse hook)
#       through the adapters blocks a protected-branch commit, a staged secret,
#       a malformed commit subject, and a protected-ref push (including the
#       load-bearing MULTI-REF push where the protected ref is NOT line 1 of the
#       pre-push stdin) — while NOT false-blocking a clean commit / feature push.
#
# The tier is exercised only when `$SHELL_ROOT/.githooks/<hook>` exists AND is
# executable — pre-Code that dir is absent, so git runs no hook, the "must FAIL"
# cases (correctly) do NOT fail, and the file-shape cases fail on the absent
# files. Every §152 assertion below is therefore RED until the Code phase lands
# `.githooks/` + `scripts/install_git_hooks.sh`.
#
# The literal AWS key below is SPLIT at the source level (`"AKIA""IOSF…"`) so the
# contiguous `AKIA[0-9A-Z]{16}` pattern never appears in THIS file's staged diff
# (keeping the secret_scan self-clean); the runtime value is the full key.

S152_GH="$SHELL_ROOT/.githooks"
S152_INST="$SHELL_ROOT/scripts/install_git_hooks.sh"
S152_ADAPTERS="pre-commit pre-push commit-msg"
S152_ALL="_lib.sh pre-commit pre-push commit-msg"

# ---- 152a: the 4 tier files exist AND are executable (-x). ----
s152a_missing=""; s152a_notexec=""
for f in $S152_ALL; do
  [ -f "$S152_GH/$f" ] || s152a_missing="$s152a_missing $f"
  [ -x "$S152_GH/$f" ] || s152a_notexec="$s152a_notexec $f"
done
if [ -z "$s152a_missing" ] && [ -z "$s152a_notexec" ]; then
  ok "152a: .githooks/{_lib.sh,pre-commit,pre-push,commit-msg} all present + executable (#604)"
else
  ng "152a: .githooks tier files missing:[$s152a_missing] not-exec:[$s152a_notexec] (#604)"
fi

# ---- 152b: each of the 3 adapters pins its interpreter on line 1. ----
s152b_bad=""
for f in $S152_ADAPTERS; do
  if [ -f "$S152_GH/$f" ]; then
    IFS= read -r s152b_first < "$S152_GH/$f" || s152b_first=""
    [ "$s152b_first" = '#!/usr/bin/env bash' ] || s152b_bad="$s152b_bad $f"
  else
    s152b_bad="$s152b_bad $f"
  fi
done
if [ -z "$s152b_bad" ]; then
  ok "152b: pre-commit/pre-push/commit-msg each carry '#!/usr/bin/env bash' on line 1 (#604)"
else
  ng "152b: adapters missing the bash shebang on line 1:[$s152b_bad] (#604)"
fi

# ---- 152c (AC1, single-source POSITIVE): each adapter CALLS its helper fn. ----
# pre-commit → is_protected_branch + scan_staged_secrets; commit-msg →
# check_commit_subject; pre-push → is_protected_branch. Existence-guarded so an
# absent adapter is a LOUD red (not a vacuous pass on a missing target).
if [ -f "$S152_GH/pre-commit" ] && grep -q 'is_protected_branch' "$S152_GH/pre-commit" \
     && grep -q 'scan_staged_secrets' "$S152_GH/pre-commit" \
   && [ -f "$S152_GH/commit-msg" ] && grep -q 'check_commit_subject' "$S152_GH/commit-msg" \
   && [ -f "$S152_GH/pre-push" ]   && grep -q 'is_protected_branch' "$S152_GH/pre-push"; then
  ok "152c: adapters call their reused helper functions (single-source, AC1) (#604)"
else
  ng "152c: an adapter is absent or does not call its helper fn (single-source, AC1) (#604)"
fi

# ---- 152d (AC1, single-source NEGATIVE): NO copied check-logic literal. ----
# The §9 invariant — no secret pattern (the `AKIA…` literal from secret_scan.sh)
# and no `PROTECTED_BRANCH_PATTERN=` ASSIGNMENT (from git_matcher.sh) is
# duplicated into `.githooks/`; a `$PROTECTED_BRANCH_PATTERN` REFERENCE is fine.
# Existence-guarded so an absent tier fails LOUD rather than passing vacuously.
s152d_akia="AKIA""[0-9A-Z]"   # split source literal; matches the secret_scan.sh pattern head
s152d_bad=""
for f in $S152_ALL; do
  if [ ! -f "$S152_GH/$f" ]; then
    s152d_bad="$s152d_bad $f(absent)"
    continue
  fi
  grep -qE "$s152d_akia" "$S152_GH/$f" && s152d_bad="$s152d_bad $f(secret-literal)"
  grep -q 'PROTECTED_BRANCH_PATTERN=' "$S152_GH/$f" && s152d_bad="$s152d_bad $f(pattern-assign)"
done
if [ -z "$s152d_bad" ]; then
  ok "152d: no copied secret-pattern / PROTECTED_BRANCH_PATTERN= literal in .githooks (single-source, AC1) (#604)"
else
  ng "152d: copied-literal or absent tier file:[$s152d_bad] (single-source, AC1) (#604)"
fi

# ---- 152e: commit-msg reads the message file directly — NOT extract_commit_subject. ----
# extract_commit_subject parses a COMMAND STRING; at the git layer there is no
# command string, only the message-file path. commit-msg must call
# check_commit_subject on line 1, never extract_commit_subject (SPEC §6.7).
if [ -f "$S152_GH/commit-msg" ] \
   && grep -q 'check_commit_subject' "$S152_GH/commit-msg" \
   && ! grep -q 'extract_commit_subject' "$S152_GH/commit-msg"; then
  ok "152e: commit-msg calls check_commit_subject and NOT extract_commit_subject (#604)"
else
  ng "152e: commit-msg absent, or misses check_commit_subject, or wrongly calls extract_commit_subject (#604)"
fi

# ---- 152f: installer is repo-local-only + references core.hooksPath. ----
# scripts/install_git_hooks.sh exists, is executable, sets core.hooksPath, and
# contains NEITHER --global NOR --system (the §3.4 user-global boundary).
if [ -f "$S152_INST" ] && [ -x "$S152_INST" ] \
   && grep -q 'core.hooksPath' "$S152_INST" \
   && ! grep -q -- '--global' "$S152_INST" \
   && ! grep -q -- '--system' "$S152_INST"; then
  ok "152f: install_git_hooks.sh present+exec, sets core.hooksPath, no --global/--system (repo-local-only) (#604)"
else
  ng "152f: install_git_hooks.sh absent/non-exec, or missing core.hooksPath, or uses --global/--system (#604)"
fi

# ---- 152g: SPEC §8 directory-structure block lists .githooks/ (Doc landed — GREEN now). ----
if grep -qE '^[^A-Za-z0-9]*\.githooks/' "$SHELL_ROOT/SPEC.md"; then
  ok "152g: SPEC §8 directory structure lists .githooks/ (#604)"
else
  ng "152g: SPEC §8 must list .githooks/ in the directory-structure block (#604)"
fi

# ---------- §152 behavioral — REAL git ops through the .githooks adapters ----------
# Each case is a hermetic bare-remote+working-repo fixture (own mktemp, cleaned
# up). core.hooksPath is set to the ABSOLUTE $SHELL_ROOT/.githooks so the REAL
# adapters run; a .claude/ghjig-root binding lets _lib.sh self-locate the shell
# tree (SPEC §3.2.1 idiom). commit.gpgsign=false + a dummy identity make the hook
# the ONLY possible blocking signal. jq is NOT needed (no CC-hook JSON here); git
# IS, so guard git with a LOUD ng (never a silent skip), mirroring §151.
if ! command -v git >/dev/null 2>&1; then
  for s in 152h 152i 152j 152k 152l 152m 152n; do
    ng "$s: git missing — cannot drive the .githooks adapters (#604)"
  done
else
  # Common fixture setup: init on main, dummy identity, no-gpg, binding symlink,
  # register in the isolated smoke registry. Does NOT arm (caller arms when ready).
  s152_setup() {
    ( cd "$1" || exit 1
      (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; })
      git config user.email t@t
      git config user.name t
      git config commit.gpgsign false
      mkdir -p .claude
      ln -sfn "$SHELL_ROOT" .claude/ghjig-root )
    printf '%s\n' "$1" >> "$SMOKE_REG"
  }
  # Arm the tier: absolute core.hooksPath → the real adapters run for this repo.
  s152_arm() { ( cd "$1" && git config core.hooksPath "$SHELL_ROOT/.githooks" ); }
  # Unregister + remove a fixture.
  s152_cleanup() {
    local t; t=$(mktemp)
    grep -vxF "$1" "$SMOKE_REG" > "$t" 2>/dev/null || true
    mv "$t" "$SMOKE_REG"
    rm -rf "${@}"
  }
  # Full AWS key, assembled at runtime (source stays secret-scan-clean).
  s152_awskey="AKIA""IOSFODNN7EXAMPLE"

  # 152h: pre-commit protected-branch — a direct commit on `main` must FAIL.
  s152h=$(cd "$(mktemp -d)" && pwd -P); s152_setup "$s152h"; s152_arm "$s152h"
  ( cd "$s152h" && git commit --allow-empty -q -m 'feat(#604): seed on main' ) >/dev/null 2>&1
  s152h_rc=$?
  if [ "$s152h_rc" -ne 0 ]; then
    ok "152h: pre-commit blocks a direct commit to protected branch main (rc=$s152h_rc) (#604)"
  else
    ng "152h: direct commit to main should be blocked by pre-commit (rc=$s152h_rc, want non-zero) (#604)"
  fi
  s152_cleanup "$s152h"

  # 152i: pre-commit secret — staging a real AWS-key line then committing on a
  #       feature branch must FAIL (well-formed subject, so only the secret blocks).
  s152i=$(cd "$(mktemp -d)" && pwd -P); s152_setup "$s152i"; s152_arm "$s152i"
  ( cd "$s152i" && git checkout -q -b feat/leak \
      && printf 'aws_access_key_id = %s\n' "$s152_awskey" > leak.txt \
      && git add leak.txt \
      && git commit -q -m 'feat(#604): add config' ) >/dev/null 2>&1
  s152i_rc=$?
  if [ "$s152i_rc" -ne 0 ]; then
    ok "152i: pre-commit blocks a staged secret (AWS key) on a feature branch (rc=$s152i_rc) (#604)"
  else
    ng "152i: staged secret should be blocked by pre-commit (rc=$s152i_rc, want non-zero) (#604)"
  fi
  s152_cleanup "$s152i"

  # 152j: commit-msg malformed subject — a non-conventional subject must FAIL.
  s152j=$(cd "$(mktemp -d)" && pwd -P); s152_setup "$s152j"; s152_arm "$s152j"
  ( cd "$s152j" && git checkout -q -b feat/msg \
      && git commit --allow-empty -q -m 'not a conventional subject' ) >/dev/null 2>&1
  s152j_rc=$?
  if [ "$s152j_rc" -ne 0 ]; then
    ok "152j: commit-msg blocks a non-conventional commit subject (rc=$s152j_rc) (#604)"
  else
    ng "152j: malformed commit subject should be blocked by commit-msg (rc=$s152j_rc, want non-zero) (#604)"
  fi
  s152_cleanup "$s152j"

  # 152k: commit-msg no-false-block — a well-formed subject must SUCCEED.
  s152k=$(cd "$(mktemp -d)" && pwd -P); s152_setup "$s152k"; s152_arm "$s152k"
  ( cd "$s152k" && git checkout -q -b feat/ok \
      && git commit --allow-empty -q -m 'feat(#604): valid subject' ) >/dev/null 2>&1
  s152k_rc=$?
  if [ "$s152k_rc" -eq 0 ]; then
    ok "152k: commit-msg allows a well-formed conventional subject (no false-block) (#604)"
  else
    ng "152k: well-formed 'feat(#604): …' subject should NOT be blocked (rc=$s152k_rc, want 0) (#604)"
  fi
  s152_cleanup "$s152k"

  # 152l: pre-push protected — pushing `main` to a bare remote must FAIL. The seed
  #       commit on main is made BEFORE arming (so the pre-commit gate doesn't
  #       block fixture setup) — the push is the only hook-guarded op here.
  s152l=$(cd "$(mktemp -d)" && pwd -P); s152l_rem="$s152l.git"
  s152_setup "$s152l"; git init --bare -q "$s152l_rem"
  ( cd "$s152l" && git commit --allow-empty -q -m 'feat(#604): seed' \
      && git remote add origin "$s152l_rem" )
  s152_arm "$s152l"
  ( cd "$s152l" && git push -q origin main ) >/dev/null 2>&1
  s152l_rc=$?
  if [ "$s152l_rc" -ne 0 ]; then
    ok "152l: pre-push blocks a push of protected ref main (rc=$s152l_rc) (#604)"
  else
    ng "152l: push of protected ref main should be blocked by pre-push (rc=$s152l_rc, want non-zero) (#604)"
  fi
  s152_cleanup "$s152l" "$s152l_rem"

  # 152m: pre-push no-false-block — pushing a non-protected feature branch SUCCEEDS.
  s152m=$(cd "$(mktemp -d)" && pwd -P); s152m_rem="$s152m.git"
  s152_setup "$s152m"; git init --bare -q "$s152m_rem"
  ( cd "$s152m" && git commit --allow-empty -q -m 'feat(#604): seed' \
      && git checkout -q -b feat/ship \
      && git remote add origin "$s152m_rem" )
  s152_arm "$s152m"
  ( cd "$s152m" && git push -q origin feat/ship ) >/dev/null 2>&1
  s152m_rc=$?
  if [ "$s152m_rc" -eq 0 ]; then
    ok "152m: pre-push allows a push of a non-protected feature branch (no false-block) (#604)"
  else
    ng "152m: feature-branch push should NOT be blocked by pre-push (rc=$s152m_rc, want 0) (#604)"
  fi
  s152_cleanup "$s152m" "$s152m_rem"

  # 152n (load-bearing): pre-push MULTI-REF — a single push of a CLEAN feature ref
  #       AND protected `main` in one invocation must FAIL. The clean ref is
  #       ordered FIRST on the refspec (so it arrives on pre-push stdin line 1); a
  #       single-`read` adapter inspecting only line 1 would wrongly PASS, so this
  #       proves the adapter iterates ALL stdin ref lines (SPEC §6.7 while-read).
  s152n=$(cd "$(mktemp -d)" && pwd -P); s152n_rem="$s152n.git"
  s152_setup "$s152n"; git init --bare -q "$s152n_rem"
  ( cd "$s152n" && git commit --allow-empty -q -m 'feat(#604): seed' \
      && git branch feat/multi \
      && git remote add origin "$s152n_rem" )
  s152_arm "$s152n"
  ( cd "$s152n" && git push -q origin feat/multi main ) >/dev/null 2>&1
  s152n_rc=$?
  if [ "$s152n_rc" -ne 0 ]; then
    ok "152n: multi-ref push (clean feat/multi FIRST + protected main) is blocked — adapter iterates all refs (rc=$s152n_rc) (#604)"
  else
    ng "152n: multi-ref push carrying protected main should be blocked (rc=$s152n_rc, want non-zero) — a line-1-only adapter would miss it (#604)"
  fi
  s152_cleanup "$s152n" "$s152n_rem"
fi
