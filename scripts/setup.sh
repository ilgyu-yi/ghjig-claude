#!/usr/bin/env bash
# scripts/setup.sh — the single host-side entry point for adopting the shell on a
# repo (Execution #458, Directive #454). A thin ORCHESTRATOR over the existing
# single-purpose scripts in the documented adoption order — it never re-implements
# their bodies (SPEC §9 single-source); it just runs them in sequence and renders
# the shared onboard pre-flight:
#
#   ./scripts/setup.sh <local-path | repo-url> [--enter]
#     1. dependency check        -> bootstrap.sh
#     2. dispatch on the single positional arg:
#          an existing local dir -> register.sh ;  a repo URL -> clone-into.sh
#          (tie-breaker: an existing directory is always treated as a local path)
#     3. mechanical pre-flight   -> lib/onboard_checks.sh, rendered as check marks
#     4. dir-mode adoption gate  -> an always-offered y/N prompt (default N); only
#          y/Y runs onboard_target.sh (which opens a PR into the repo, never a push)
#     5. final guidance          -> prints the next command; --enter execs `claude`
#
# Boundary (the MISSION user-global rule): this script NEVER appends to any user
# shell startup file, never touches the user's ~/.claude, and never performs a
# global git-config write. The PATH line in the final guidance is PRINTED only, for
# the user to apply themselves.
#
# POSIX-sh-clean body: the entry point must run identically whether launched via its
# shebang (bash) or a bare `sh scripts/setup.sh`, so it uses `set -eu` and `$0`-based
# self-location rather than the bash-only `set -o pipefail` / BASH_SOURCE that the
# bash-invoked sibling scripts use.

set -eu

# Keep `cd` from echoing/resolving via CDPATH (set once; inherited by subshells).
CDPATH=''

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
SHELL_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)

usage() {
  printf 'usage: setup.sh <local-path | repo-url> [--enter]\n' >&2
}

TARGET=
ENTER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --enter) ENTER=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) printf 'setup: unknown flag: %s\n' "$1" >&2; usage; exit 2 ;;
    *)
      if [ -z "$TARGET" ]; then
        TARGET="$1"
      else
        printf 'setup: unexpected extra argument: %s\n' "$1" >&2; usage; exit 2
      fi
      ;;
  esac
  shift
done

if [ -z "$TARGET" ]; then usage; exit 2; fi

# 1. Dependency check (never modifies user-global files; see bootstrap.sh).
"$SCRIPT_DIR/bootstrap.sh"

# 2. Path-vs-URL dispatch. An existing directory is always a local path; otherwise a
#    URL/SCP-shaped or `.git`-suffixed arg is a clone target.
is_url=0
if [ -d "$TARGET" ]; then
  is_url=0
else
  case "$TARGET" in
    *://*|*@*:*|*.git) is_url=1 ;;
  esac
fi

if [ "$is_url" -eq 1 ]; then
  "$SCRIPT_DIR/clone-into.sh" "$TARGET"
  name=$(basename "$TARGET")
  name=${name%.git}
  target_dir="$SHELL_ROOT/workspace/$name"
else
  "$SCRIPT_DIR/register.sh" "$TARGET"
  target_dir=$(cd -- "$TARGET" 2>/dev/null && pwd -P || printf '%s' "$TARGET")
fi

# 3. Mechanical pre-flight — render onboard_checks.sh's `<check> ok|fail <detail>`
#    lines as check marks. Skip gracefully if the target is not present yet.
if [ -d "$target_dir" ]; then
  printf '\nPre-flight (%s):\n' "$target_dir"
  ( cd -- "$target_dir" && "$SCRIPT_DIR/lib/onboard_checks.sh" ) \
    | while IFS=' ' read -r ck_name ck_status ck_detail; do
        [ -n "$ck_name" ] || continue
        case "$ck_status" in
          ok)   printf '  \342\234\223 %s %s\n' "$ck_name" "$ck_detail" ;;
          fail) printf '  \342\234\227 %s %s\n' "$ck_name" "$ck_detail" ;;
          *)    printf '  - %s %s\n' "$ck_name" "$ck_detail" ;;
        esac
      done
else
  printf '\nPre-flight skipped (target not present yet): %s\n' "$target_dir"
fi

# 4. dir-mode adoption gate — always offered, default N, non-TTY/EOF falls back to N
#    (mirrors bin/claude-eng's `read -r resp || resp=...` pattern). Only y/Y proceeds.
printf '\nInstall dir-mode substrate (labels + issue templates + workflows + Project)?\n'
printf 'This opens a PR into the target repo (never a direct push). [y/N] '
read -r resp || resp=N
case "${resp:-N}" in
  [Yy]|[Yy][Ee][Ss])
    if [ -d "$target_dir" ]; then
      ( cd -- "$target_dir" && "$SCRIPT_DIR/onboard_target.sh" )
    else
      "$SCRIPT_DIR/onboard_target.sh"
    fi
    ;;
  *)
    printf 'Skipped dir-mode — you can run /onboard-dir-mode later.\n'
    ;;
esac

# 5. Final guidance. The PATH line is printed only; nothing is written on your behalf.
printf '\nDone. Next:\n'
if [ -d "$target_dir" ]; then
  printf '  cd %s && claude\n' "$target_dir"
else
  printf '  cd <target> && claude\n'
fi
printf '\nOptional — to run `claude-eng` from any directory, add this yourself (we never edit your shell startup files):\n'
printf '  export PATH="%s/bin:$PATH"\n' "$SHELL_ROOT"

if [ "$ENTER" -eq 1 ] && [ -d "$target_dir" ]; then
  cd -- "$target_dir"
  exec claude
fi
