# shellcheck shell=bash
# scripts/lib/self_register.sh — ensure the shell repo itself is in the registry.
# Source and call ensure_self_registered "$SHELL_ROOT". Idempotent.
# See SPEC.md §3.6 for the rationale.

ensure_self_registered() {
  local shell_root="$1"
  [ -n "$shell_root" ] || { echo "ensure_self_registered: shell_root argument required" >&2; return 1; }
  [ -d "$shell_root" ] || { echo "ensure_self_registered: not a directory: $shell_root" >&2; return 1; }
  shell_root=$(cd "$shell_root" && pwd -P)

  # Write the shell's registration into its own per-project registry (#316), via
  # the single eng_registry_file resolver. Defensively source hookrt from the code
  # root (CLAUDE_ENG_SHELL_ROOT) — the $shell_root arg being registered may be a
  # bare dir without hooks (e.g. the §9 smoke fixture). Dogfood coherence (§3.6):
  # this write-target equals what cwd_guard reads under CLAUDE_PROJECT_DIR=$shell_root.
  command -v eng_registry_file >/dev/null 2>&1 \
    || { [ -n "${CLAUDE_ENG_SHELL_ROOT:-}" ] && [ -f "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/hookrt.sh" ] \
         && . "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/hookrt.sh"; }
  local registry; registry=$(eng_registry_file "$shell_root")
  mkdir -p "$(dirname "$registry")"
  touch "$registry"
  if ! grep -qxF "$shell_root" "$registry"; then
    printf '%s\n' "$shell_root" >> "$registry"
    echo "self-register: added $shell_root"
  else
    echo "self-register: already present ($shell_root)"
  fi
}
