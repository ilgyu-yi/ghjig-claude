# shellcheck shell=bash
# helpers/coauthor.sh — Co-Authored-By trailer toggle. Source from
# /work-on (or any commit-flow consumer).
#
# Public:
#   coauthor_trailer — prints the trailer line + newline when enabled,
#                      empty when disabled. Honors (high → low):
#                        1. $CLAUDE_ENG_COAUTHOR env (`on` / `off`)
#                        2. .claude/state/coauthor per-target file
#                        3. default `on`
#
# Unknown values fail-safe to `on` with a one-line stderr warning that
# names the source — mirrors SPEC §5.7.1's resolve_mode pattern. See
# SPEC §10.2 "Co-Authored-By trailer toggle".

_coauthor_resolve() {
  local source value
  if [ -n "${CLAUDE_ENG_COAUTHOR:-}" ]; then
    source="\$CLAUDE_ENG_COAUTHOR"
    value="$CLAUDE_ENG_COAUTHOR"
  elif [ -f "${CLAUDE_ENG_SHELL_ROOT:-}/.claude/state/coauthor" ]; then
    source=".claude/state/coauthor"
    value=$(tr -d '[:space:]' < "$CLAUDE_ENG_SHELL_ROOT/.claude/state/coauthor")
  else
    printf '%s' "on"
    return
  fi
  case "$value" in
    on|off) printf '%s' "$value" ;;
    *)
      printf 'coauthor: unknown value %q in %s — falling back to "on"\n' "$value" "$source" >&2
      printf '%s' "on"
      ;;
  esac
}

coauthor_trailer() {
  case "$(_coauthor_resolve)" in
    off) return 0 ;;
    *)   printf 'Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' ;;
  esac
}