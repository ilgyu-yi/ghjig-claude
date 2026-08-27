# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after 74-render-ordering.sh (#725). The
# guarded source below never runs at runtime (the orchestrator already sourced
# the preamble); it only lets shellcheck resolve the shared globals.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §187: audit-trail unification — the writer is unconditional (#725) ----------
# Contract home: SPEC §3.2.2 "Audit destination — the writer is unconditional".
# audit_log writes the per-project tier in EVERY context and never writes the
# legacy shared path; its destination resolves through a dedicated resolver:
# GHJIG_STATE_DIR_OVERRIDE → $CLAUDE_PROJECT_DIR/.claude/ghjig-state → the
# MAIN-worktree top level (git --git-common-dir derive) → BASH_SOURCE
# self-location — never a /-rooted degradation. The reader (resolve_audit_log)
# mirrors the rungs and consults the legacy shared file as a READ-ONLY FLOOR,
# only when the per-project file is absent. Every fixture below is a scratch
# tree: GHJIG_ROOT points at a DECOY root so a pre-#725 legacy write lands in
# scratch, and the GHJIG_ROOT_OVERRIDE seam points self-location at scratch
# too — the §357 tripwire (extended to the live per-project sink) fails the
# run if an arm ever leaks a record into the real repo.

S187_FIX=$(mktemp -d)     # fixture project repo (main tree)
S187_DECOY=$(mktemp -d)   # decoy "shell root": absorbs any legacy-path write
(
  cd "$S187_FIX" || exit 1
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
) >/dev/null 2>&1

# §187a: two-sided visibility — a write with NO state env set, fired from
# inside a project repo, must land in THAT project's per-project sink
# (.claude/ghjig-state/audit/audit.jsonl), never on the legacy shared path.
(
  cd "$S187_FIX" || exit 1
  env -u CLAUDE_PROJECT_DIR -u GHJIG_STATE_DIR_OVERRIDE \
    GHJIG_ROOT="$S187_DECOY" GHJIG_ROOT_OVERRIDE="$S187_DECOY" \
    bash -c '. "$1/.claude/hooks/hookrt.sh" && audit_log info test-visibility x "two-sided visibility probe"' \
    _ "$SHELL_ROOT"
) >/dev/null 2>&1
if grep -q 'test-visibility' "$S187_FIX/.claude/ghjig-state/audit/audit.jsonl" 2>/dev/null \
   && ! grep -q 'test-visibility' "$S187_DECOY/.claude/audit/audit.jsonl" 2>/dev/null; then
  ok "187a: env-unset write from a project cwd lands in the project's per-project audit sink, not the legacy path (#725)"
else
  ng "187a: env-unset write missed the per-project sink (per-project=$([ -f "$S187_FIX/.claude/ghjig-state/audit/audit.jsonl" ] && echo present || echo absent) legacy-decoy=$([ -f "$S187_DECOY/.claude/audit/audit.jsonl" ] && echo present || echo absent)) (#725)"
fi

# §187b: worktree write — from a LINKED WORKTREE the record must land in the
# MAIN tree's ghjig-state, not the worktree's own (a worktree's ghjig-state
# dies at teardown — the loss shape SPEC §3.2.2's git-common-dir rung closes).
S187_WT="$S187_FIX-wt"
git -C "$S187_FIX" worktree add -q "$S187_WT" -b s187wt >/dev/null 2>&1
(
  cd "$S187_WT" || exit 1
  env -u CLAUDE_PROJECT_DIR -u GHJIG_STATE_DIR_OVERRIDE \
    GHJIG_ROOT="$S187_DECOY" GHJIG_ROOT_OVERRIDE="$S187_DECOY" \
    bash -c '. "$1/.claude/hooks/hookrt.sh" && audit_log info test-wt-visibility x "worktree write probe"' \
    _ "$SHELL_ROOT"
) >/dev/null 2>&1
if grep -q 'test-wt-visibility' "$S187_FIX/.claude/ghjig-state/audit/audit.jsonl" 2>/dev/null \
   && [ ! -e "$S187_WT/.claude/ghjig-state/audit/audit.jsonl" ]; then
  ok "187b: worktree-context write survives teardown — record lands in the MAIN tree's per-project sink (#725)"
else
  ng "187b: worktree write missed the main tree (main-hits=$(grep -c 'test-wt-visibility' "$S187_FIX/.claude/ghjig-state/audit/audit.jsonl" 2>/dev/null || echo 0) wt-file=$([ -e "$S187_WT/.claude/ghjig-state/audit/audit.jsonl" ] && echo present || echo absent)) (#725)"
fi
git -C "$S187_FIX" worktree remove --force "$S187_WT" >/dev/null 2>&1 || rm -rf "$S187_WT"

# §187c: reader preference — with BOTH a populated per-project file and a
# populated legacy floor, resolve_audit_log returns the per-project path; with
# the per-project file absent it returns the floor (read-only back-compat —
# SPEC §3.2.2 "Audit read-floor"). Exercised on the CLAUDE_PROJECT_DIR rung;
# §135d covers the same preference on the self-location rung.
mkdir -p "$S187_FIX/.claude/ghjig-state/audit" "$S187_DECOY/.claude/audit"
printf '{"probe":"pp"}\n'    >> "$S187_FIX/.claude/ghjig-state/audit/audit.jsonl"
printf '{"probe":"floor"}\n' >> "$S187_DECOY/.claude/audit/audit.jsonl"
s187c_pp=$(
  env -u GHJIG_STATE_DIR_OVERRIDE -u GHJIG_ROOT \
    CLAUDE_PROJECT_DIR="$S187_FIX" GHJIG_ROOT_OVERRIDE="$S187_DECOY" \
    bash -c '. "$1/lib/audit_log_path.sh" && resolve_audit_log' _ "$SHELL_ROOT/scripts" 2>/dev/null
)
if [ "$s187c_pp" = "$S187_FIX/.claude/ghjig-state/audit/audit.jsonl" ]; then
  ok "187c: both files present → resolve_audit_log prefers the per-project path (#725)"
else
  ng "187c: both files present but resolve_audit_log returned '$s187c_pp' (want the per-project path '$S187_FIX/.claude/ghjig-state/audit/audit.jsonl') (#725)"
fi
S187C_STASH=$(mktemp -d)
mv "$S187_FIX/.claude/ghjig-state/audit/audit.jsonl" "$S187C_STASH/audit.jsonl" 2>/dev/null
s187c_fl=$(
  env -u GHJIG_STATE_DIR_OVERRIDE -u GHJIG_ROOT \
    CLAUDE_PROJECT_DIR="$S187_FIX" GHJIG_ROOT_OVERRIDE="$S187_DECOY" \
    bash -c '. "$1/lib/audit_log_path.sh" && resolve_audit_log' _ "$SHELL_ROOT/scripts" 2>/dev/null
)
if [ "$s187c_fl" = "$S187_DECOY/.claude/audit/audit.jsonl" ]; then
  ok "187c-floor: per-project file absent → resolve_audit_log returns the read-only legacy floor (#725)"
else
  ng "187c-floor: per-project file absent but resolve_audit_log returned '$s187c_fl' (want the floor '$S187_DECOY/.claude/audit/audit.jsonl') (#725)"
fi
mv "$S187C_STASH/audit.jsonl" "$S187_FIX/.claude/ghjig-state/audit/audit.jsonl" 2>/dev/null || true
rm -rf "$S187C_STASH"

# §187d: degradation — env fully unset, cwd NOT a git repo. The write must land
# at the (seam-redirected) self-located shell-root per-project file, or fail
# cleanly rc!=0 with NO /-rooted path creation attempt (the retired
# `${GHJIG_ROOT:-}` degradation mkdir'd "/.claude" — SPEC §3.2.2 names this
# loss shape; the record reached neither file).
S187D_CWD=$(mktemp -d)
s187d_err=$(
  cd "$S187D_CWD" || exit 9
  env -u CLAUDE_PROJECT_DIR -u GHJIG_STATE_DIR_OVERRIDE -u GHJIG_ROOT \
    GHJIG_ROOT_OVERRIDE="$S187_DECOY" \
    bash -c '. "$1/.claude/hooks/hookrt.sh" && audit_log info test-degrade x "degradation probe"' \
    _ "$SHELL_ROOT" 2>&1 >/dev/null
)
s187d_rc=$?
# A /-rooted creation attempt surfaces as a rooted "/.claude" in the error text
# (preceded by a space or quote); the decoy's own paths never match that shape.
s187d_rooted_pat=$(printf '[ \047"]/\\.claude')
s187d_ok=0; s187d_mode=""
if grep -q 'test-degrade' "$S187_DECOY/.claude/ghjig-state/audit/audit.jsonl" 2>/dev/null; then
  s187d_ok=1; s187d_mode="self-located per-project write"
elif [ "$s187d_rc" != 0 ] && ! printf '%s\n' "$s187d_err" | grep -Eq "$s187d_rooted_pat"; then
  s187d_ok=1; s187d_mode="clean rc=$s187d_rc failure, no /-rooted attempt"
fi
if [ "$s187d_ok" = 1 ]; then
  ok "187d: env-unset non-repo write degrades cleanly ($s187d_mode) (#725)"
else
  ng "187d: env-unset non-repo write neither landed at the self-located per-project sink nor failed cleanly (rc=$s187d_rc err=$(printf '%s' "$s187d_err" | head -c 160)) (#725)"
fi
rm -rf "$S187D_CWD"

rm -rf "$S187_FIX" "$S187_DECOY"
