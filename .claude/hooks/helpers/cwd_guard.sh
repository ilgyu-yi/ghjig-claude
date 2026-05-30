# shellcheck shell=bash
# helpers/cwd_guard.sh — registry-based scope checks. Source from hooks.

# in_scope: returns 0 if PWD is inside any registry entry, 1 otherwise.
in_scope() {
  local registry="$CLAUDE_ENG_SHELL_ROOT/.claude/state/registry.txt"
  [ -f "$registry" ] || return 1
  local pwd_real
  pwd_real=$(cd "$PWD" 2>/dev/null && pwd -P) || return 1
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    entry="${entry%/}"   # normalize a trailing slash (#218): else `"$entry"/*` → `//*` never matches
    case "$pwd_real/" in
      "$entry"/*) return 0 ;;
    esac
    [ "$pwd_real" = "$entry" ] && return 0
  done < "$registry"
  return 1
}

# path_in_scope <path>: returns 0 if the path lies inside registry (or the shell itself).
path_in_scope() {
  local p="$1"
  [ -z "$p" ] && return 1
  # Substitute common env-var literals (as they may appear in Bash command args)
  case "$p" in
    '$HOME'|'$HOME'/*) p="${HOME}${p#'$HOME'}" ;;
    \~|\~/*) p="${HOME}${p#\~}" ;;
  esac
  # Make absolute
  case "$p" in
    /*) ;;
    *) p="$(pwd -P)/$p" ;;
  esac
  # Walk up to the first existing directory ancestor, then physical-resolve.
  # Covers files, missing paths, and existing dirs uniformly.
  local ancestor="$p" suffix=""
  while [ ! -d "$ancestor" ] && [ "$ancestor" != "/" ] && [ -n "$ancestor" ]; do
    suffix="/$(basename "$ancestor")$suffix"
    local next; next=$(dirname "$ancestor")
    [ "$next" = "$ancestor" ] && break
    ancestor="$next"
  done
  if [ -d "$ancestor" ]; then
    p="$(cd "$ancestor" 2>/dev/null && pwd -P)$suffix"
  fi
  # Allow shell self-modification
  case "$p/" in
    "$CLAUDE_ENG_SHELL_ROOT"/*) return 0 ;;
  esac
  local registry="$CLAUDE_ENG_SHELL_ROOT/.claude/state/registry.txt"
  [ -f "$registry" ] || return 1
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    entry="${entry%/}"   # normalize a trailing slash (#218): else `"$entry"/*` → `//*` never matches
    case "$p/" in
      "$entry"/*) return 0 ;;
    esac
    [ "$p" = "$entry" ] && return 0
  done < "$registry"
  return 1
}
