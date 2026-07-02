#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: register.sh <abs-path>" >&2; exit 2; }
[ $# -ge 1 ] || usage

TARGET="$1"
[ -d "$TARGET" ] || { echo "directory not found: $TARGET" >&2; exit 1; }
TARGET=$(cd "$TARGET" && pwd -P)

SHELL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export GHJIG_ROOT="$SHELL_ROOT"

. "$SHELL_ROOT/scripts/lib/inject.sh"

# Shell self-registration: target == SHELL_ROOT is a no-op for workspace symlinks
# and inject_into (the shell IS the inject source; a workspace/<basename> symlink
# would loop into workspace/ contained within SHELL_ROOT). See SPEC §3.6.
if [ "$TARGET" = "$SHELL_ROOT" ]; then
  . "$SHELL_ROOT/scripts/lib/self_register.sh"
  ensure_self_registered "$SHELL_ROOT"
  exit 0
fi

# If not already inside workspace/, also create a symlink for convenience.
if [[ "$TARGET" != "$SHELL_ROOT/workspace/"* ]]; then
  LINK="$SHELL_ROOT/workspace/$(basename "$TARGET")"
  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    echo "WARN: $LINK exists (real file). Symlink not created." >&2
  else
    ln -sfn "$TARGET" "$LINK"
  fi
fi

inject_into "$TARGET"
