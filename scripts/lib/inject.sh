# shellcheck shell=bash
# scripts/lib/inject.sh — shared inject logic for clone-into / register.
# Source and call inject_into "$TARGET".
#
# Per-project binding (#312, Directive #311): inject_into drops an untracked
# `.claude/eng-shell-root` symlink → the canonical shell root and points the
# target's `settings.local.json` at `settings.injected.json` (whose hook
# commands use ${CLAUDE_PROJECT_DIR}/.claude/eng-shell-root/...). Both are added
# to the target's .git/info/exclude. Net effect: a plain `claude` in the target
# resolves the shell with no global CLAUDE_ENG_SHELL_ROOT env. See SPEC §3.2.1.

inject_into() {
  local target="$1"
  : "${CLAUDE_ENG_SHELL_ROOT:?CLAUDE_ENG_SHELL_ROOT must be set}"
  [ -d "$target" ] || { echo "target directory not found: $target" >&2; return 1; }
  target=$(cd "$target" && pwd -P)

  mkdir -p "$target/.claude/agents" "$target/.claude/commands"

  # Per-project binding symlink (#312, Directive #311): lets hooks resolve the
  # canonical shell root via $CLAUDE_PROJECT_DIR/.claude/eng-shell-root, so a
  # plain `claude` works with NO global CLAUDE_ENG_SHELL_ROOT env. Idempotent.
  ln -sfn "$CLAUDE_ENG_SHELL_ROOT" "$target/.claude/eng-shell-root"

  # settings.local.json — Claude Code's this-clone-only slot. Points at the
  # target-facing settings.injected.json, whose hook commands resolve via the
  # binding symlink above; the shell's own settings.json stays env-based (dogfood).
  if [ -e "$target/.claude/settings.local.json" ] && [ ! -L "$target/.claude/settings.local.json" ]; then
    echo "WARN: $target/.claude/settings.local.json exists (real file). Shell settings not injected." >&2
  else
    ln -sfn "$CLAUDE_ENG_SHELL_ROOT/.claude/settings.injected.json" "$target/.claude/settings.local.json"
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
    grep -qxF '.claude/eng-shell-root' "$excl" || printf '.claude/eng-shell-root\n' >> "$excl"
    grep -qxF '.claude/eng-state' "$excl" || printf '.claude/eng-state\n' >> "$excl"
  fi

  # Record in the target's per-project registry (#316). Resolve via the single
  # eng_registry_file resolver, defensively sourcing hookrt from the code root
  # (CLAUDE_ENG_SHELL_ROOT, not $target — the target may not carry hooks).
  command -v eng_registry_file >/dev/null 2>&1 \
    || { [ -n "${CLAUDE_ENG_SHELL_ROOT:-}" ] && [ -f "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/hookrt.sh" ] \
         && . "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/hookrt.sh"; }
  local registry; registry=$(eng_registry_file "$target")
  mkdir -p "$(dirname "$registry")"
  touch "$registry"
  if ! grep -qxF "$target" "$registry"; then
    printf '%s\n' "$target" >> "$registry"
  fi

  echo "OK: shell assets injected into $target"
}
