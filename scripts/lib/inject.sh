# shellcheck shell=bash
# scripts/lib/inject.sh — shared inject logic for clone-into / register.
# Source and call inject_into "$TARGET".

inject_into() {
  local target="$1"
  : "${CLAUDE_ENG_SHELL_ROOT:?CLAUDE_ENG_SHELL_ROOT must be set}"
  [ -d "$target" ] || { echo "target directory not found: $target" >&2; return 1; }
  target=$(cd "$target" && pwd -P)

  mkdir -p "$target/.claude/agents" "$target/.claude/commands"

  # settings.local.json — Claude Code's this-clone-only slot
  if [ -e "$target/.claude/settings.local.json" ] && [ ! -L "$target/.claude/settings.local.json" ]; then
    echo "WARN: $target/.claude/settings.local.json exists (real file). Shell settings not injected." >&2
  else
    ln -sfn "$CLAUDE_ENG_SHELL_ROOT/.claude/settings.json" "$target/.claude/settings.local.json"
  fi

  # agents / commands — skip with warning if a same-named asset already exists
  local kind src dest
  for kind in agents commands; do
    if [ -d "$CLAUDE_ENG_SHELL_ROOT/.claude/$kind" ]; then
      for src in "$CLAUDE_ENG_SHELL_ROOT/.claude/$kind"/*.md; do
        [ -e "$src" ] || continue
        dest="$target/.claude/$kind/$(basename "$src")"
        if [ -e "$dest" ] && [ ! -L "$dest" ]; then
          echo "WARN: $dest exists. Shell asset injection skipped." >&2
        else
          ln -sfn "$src" "$dest"
        fi
      done
    fi
  done

  # Hide the shell injection from the target's git via .git/info/exclude
  if [ -d "$target/.git" ]; then
    local excl="$target/.git/info/exclude"
    mkdir -p "$(dirname "$excl")"
    touch "$excl"
    if ! grep -qxF '.claude/settings.local.json' "$excl"; then
      printf '\n# claude-eng-shell injection\n.claude/settings.local.json\n' >> "$excl"
    fi
  fi

  # Record in registry
  local registry="$CLAUDE_ENG_SHELL_ROOT/.claude/state/registry.txt"
  mkdir -p "$(dirname "$registry")"
  touch "$registry"
  if ! grep -qxF "$target" "$registry"; then
    printf '%s\n' "$target" >> "$registry"
  fi

  echo "OK: shell assets injected into $target"
}