# shellcheck shell=bash
# scripts/lib/inject.sh — shared inject logic for clone-into / register.
# Source and call inject_into "$TARGET".
#
# Per-project binding (#312, Directive #311): inject_into drops an untracked
# `.claude/ghjig-root` symlink → the canonical shell root and points the
# target's `settings.local.json` at `settings.injected.json` (whose hook
# commands use ${CLAUDE_PROJECT_DIR}/.claude/ghjig-root/...). Both are added
# to the target's .git/info/exclude. Net effect: a plain `claude` in the target
# resolves the shell with no global GHJIG_ROOT env. See SPEC §3.2.1.

# Self-location: resolve GHJIG_ROOT from our own path (test seam:
# GHJIG_ROOT_OVERRIDE). The inherited ambient env is never an input (#539).
GHJIG_ROOT="${GHJIG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"; export GHJIG_ROOT

inject_into() {
  local target="$1"
  [ -d "$target" ] || { echo "target directory not found: $target" >&2; return 1; }
  target=$(cd "$target" && pwd -P)

  mkdir -p "$target/.claude/agents" "$target/.claude/commands"

  # Per-project binding symlink (#312, Directive #311): lets hooks resolve the
  # canonical shell root via $CLAUDE_PROJECT_DIR/.claude/ghjig-root, so a
  # plain `claude` works with NO global GHJIG_ROOT env. Idempotent.
  ln -sfn "$GHJIG_ROOT" "$target/.claude/ghjig-root"

  # settings.local.json — Claude Code's this-clone-only slot. Points at the
  # target-facing settings.injected.json, whose hook commands resolve via the
  # binding symlink above; the shell's own settings.json stays env-based (dogfood).
  if [ -e "$target/.claude/settings.local.json" ] && [ ! -L "$target/.claude/settings.local.json" ]; then
    echo "WARN: $target/.claude/settings.local.json exists (real file). Shell settings not injected." >&2
  else
    ln -sfn "$GHJIG_ROOT/.claude/settings.injected.json" "$target/.claude/settings.local.json"
  fi

  # agents / commands — skip with warning if a same-named asset already exists
  local kind src dest
  for kind in agents commands; do
    if [ -d "$GHJIG_ROOT/.claude/$kind" ]; then
      for src in "$GHJIG_ROOT/.claude/$kind"/*.md; do
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
      printf '\n# GHJig-Claude injection\n.claude/settings.local.json\n' >> "$excl"
    fi
    grep -qxF '.claude/ghjig-root' "$excl" || printf '.claude/ghjig-root\n' >> "$excl"
    grep -qxF '.claude/ghjig-state' "$excl" || printf '.claude/ghjig-state\n' >> "$excl"
  fi

  # Record in the target's per-project registry (#316). Resolve via the single
  # ghjig_registry_file resolver, defensively sourcing hookrt from the code root
  # (GHJIG_ROOT, not $target — the target may not carry hooks).
  command -v ghjig_registry_file >/dev/null 2>&1 \
    || { [ -f "$GHJIG_ROOT/.claude/hooks/hookrt.sh" ] \
         && . "$GHJIG_ROOT/.claude/hooks/hookrt.sh"; }
  local registry; registry=$(ghjig_registry_file "$target")
  mkdir -p "$(dirname "$registry")"
  touch "$registry"
  if ! grep -qxF "$target" "$registry"; then
    printf '%s\n' "$target" >> "$registry"
  fi

  echo "OK: shell assets injected into $target"
}
