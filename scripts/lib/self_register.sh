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
  # the single ghjig_registry_file resolver. Defensively source hookrt from the code
  # root (GHJIG_ROOT) — the $shell_root arg being registered may be a
  # bare dir without hooks (e.g. the §9 smoke fixture). Dogfood coherence (§3.6):
  # this write-target equals what cwd_guard reads under CLAUDE_PROJECT_DIR=$shell_root.
  command -v ghjig_registry_file >/dev/null 2>&1 \
    || { [ -n "${GHJIG_ROOT:-}" ] && [ -f "$GHJIG_ROOT/.claude/hooks/hookrt.sh" ] \
         && . "$GHJIG_ROOT/.claude/hooks/hookrt.sh"; }
  local registry; registry=$(ghjig_registry_file "$shell_root")
  mkdir -p "$(dirname "$registry")"
  touch "$registry"
  if ! grep -qxF "$shell_root" "$registry"; then
    printf '%s\n' "$shell_root" >> "$registry"
    echo "self-register: added $shell_root"
  else
    echo "self-register: already present ($shell_root)"
  fi
}
