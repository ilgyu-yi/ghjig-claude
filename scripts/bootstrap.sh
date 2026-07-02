#!/usr/bin/env bash
set -euo pipefail

# Checks the shell environment only — never modifies user-global files (~/.zshrc, ~/.claude, etc.).

SHELL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export GHJIG_ROOT="$SHELL_ROOT"

ok() { printf '✓ %s\n' "$1"; }
warn() { printf '⚠ %s\n' "$1" >&2; }
info() { printf 'ℹ %s\n' "$1"; }
fail() { printf '✗ %s\n' "$1" >&2; FAILED=1; }

FAILED=0

# Required dependencies
for tool in git gh jq; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool installed"; else fail "$tool missing"; fi
done

# Recommended dependencies
if command -v python3 >/dev/null 2>&1; then
  ok "python3 installed"
else
  warn "python3 missing (recommended for commit subject codepoint measurement)"
fi

# gh auth
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ok "gh authenticated"; else fail "gh auth required. Run \`gh auth login\`."; fi
fi

# Shell directory structure
for d in .claude/agents .claude/commands .claude/hooks .claude/templates bin scripts workspace; do
  [ -d "$SHELL_ROOT/$d" ] && ok "$d/ exists" || fail "$d/ missing"
done

# Create runtime dirs (.claude/audit, .claude/state)
mkdir -p "$SHELL_ROOT/.claude/audit" "$SHELL_ROOT/.claude/state"
ok ".claude/audit/, .claude/state/ ready"

# Self-register: ensure the shell repo is in its own registry so its hooks
# fire when working on the shell itself (SPEC §3.6). Idempotent.
. "$SHELL_ROOT/scripts/lib/self_register.sh"
if msg=$(ensure_self_registered "$SHELL_ROOT" 2>&1); then
  ok "$msg"
else
  fail "self-register failed: $msg"
fi

# Install guidance (no auto-install).
# Shell aliases live in the user's interactive rc and are invisible to this
# subprocess, so we don't try to detect "is ghjig accessible" — that check
# only sees PATH and would false-alarm on the alias path (#4). Always surface
# both options as info; the user picks one and edits their own rc.
ok "ghjig wrapper: $SHELL_ROOT/bin/ghjig"
info "to invoke as 'ghjig', pick one (your rc, not ours):"
info "    - add $SHELL_ROOT/bin to PATH (visible to subprocesses)"
info "    - or: alias ghjig=$SHELL_ROOT/bin/ghjig (per-shell; bootstrap can't see it)"

if [ "${FAILED:-0}" = 1 ]; then
  echo
  echo "bootstrap: one or more checks failed." >&2
  exit 1
fi
echo "bootstrap complete."
