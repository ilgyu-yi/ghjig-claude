#!/usr/bin/env bash
# scripts/install_git_hooks.sh — activate / verify / deactivate the committed
# local git-hook enforcement tier (SPEC §6.7) by setting the REPO-LOCAL
# core.hooksPath to .githooks/. Repo-local ONLY (never a user-global or
# machine-wide git config scope), so the shell never touches user-global state
# (§3.4 boundary); it reverts with `git config --unset core.hooksPath`. Idempotent.
#
# Usage:
#   install_git_hooks.sh              install (set core.hooksPath=.githooks)
#   install_git_hooks.sh --check      report activation; exit non-zero if inert
#   install_git_hooks.sh --uninstall  unset core.hooksPath
set -uo pipefail

_HOOKS_REL=".githooks"

# Self-locate for a best-effort audit_log (never fatal).
_igh_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ -f "$_igh_root/.claude/hooks/hookrt.sh" ]; then
  export GHJIG_ROOT="$_igh_root"
  # shellcheck source=/dev/null
  . "$_igh_root/.claude/hooks/hookrt.sh"
else
  audit_log() { :; }
fi

# Refuse outside a git work tree.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "install_git_hooks: not inside a git work tree — nothing to do." >&2
  exit 1
fi
_igh_top="$(git rev-parse --show-toplevel 2>/dev/null)"

_igh_current() { git config --local --get core.hooksPath 2>/dev/null || true; }

case "${1:-}" in
  --check)
    _cur="$(_igh_current)"
    if [ "$_cur" = "$_HOOKS_REL" ]; then
      echo "install_git_hooks: tier ACTIVE (core.hooksPath=$_cur)."
      exit 0
    fi
    echo "install_git_hooks: tier INERT (core.hooksPath='${_cur:-<unset>}', expected $_HOOKS_REL). Activate: scripts/install_git_hooks.sh" >&2
    exit 1
    ;;
  --uninstall)
    git config --local --unset core.hooksPath 2>/dev/null || true
    ( audit_log info git-hook-tier uninstalled "core.hooksPath unset (repo=$_igh_top)" ) >/dev/null 2>&1 || true
    echo "install_git_hooks: tier deactivated (core.hooksPath unset)."
    exit 0
    ;;
  "")
    : # fall through to install
    ;;
  *)
    echo "install_git_hooks: unknown arg: $1 (use --check or --uninstall)" >&2
    exit 2
    ;;
esac

# Install (default). Idempotent — re-running just re-asserts the same value.
git config --local core.hooksPath "$_HOOKS_REL"

# Defensively ensure the adapters carry the executable bit.
for _igh_h in _lib.sh pre-commit pre-push commit-msg; do
  [ -f "$_igh_top/$_HOOKS_REL/$_igh_h" ] && chmod +x "$_igh_top/$_HOOKS_REL/$_igh_h" 2>/dev/null || true
done

( audit_log info git-hook-tier installed "core.hooksPath=$_HOOKS_REL (repo=$_igh_top)" ) >/dev/null 2>&1 || true
echo "install_git_hooks: tier activated (core.hooksPath=$_HOOKS_REL)."
exit 0
