# shellcheck shell=bash
# scripts/lib/self_register.sh — ensure the shell repo itself is in the registry.
# Source and call ensure_self_registered "$SHELL_ROOT". Idempotent.
# See SPEC.md §3.6 for the rationale.

ensure_self_registered() {
  local shell_root="$1"
  [ -n "$shell_root" ] || { echo "ensure_self_registered: shell_root argument required" >&2; return 1; }
  [ -d "$shell_root" ] || { echo "ensure_self_registered: not a directory: $shell_root" >&2; return 1; }
  shell_root=$(cd "$shell_root" && pwd -P)

  local registry="$shell_root/.claude/state/registry.txt"
  mkdir -p "$(dirname "$registry")"
  touch "$registry"
  if ! grep -qxF "$shell_root" "$registry"; then
    printf '%s\n' "$shell_root" >> "$registry"
    echo "self-register: added $shell_root"
  else
    echo "self-register: already present ($shell_root)"
  fi
}
