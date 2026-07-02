#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: clone-into.sh <upstream-repo-url>" >&2; exit 2; }
[ $# -ge 1 ] || usage

URL="$1"
SHELL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export GHJIG_ROOT="$SHELL_ROOT"

. "$SHELL_ROOT/scripts/lib/inject.sh"

NAME=$(basename "$URL" .git)
TARGET="$SHELL_ROOT/workspace/$NAME"

if [ -e "$TARGET" ]; then
  echo "already exists: $TARGET" >&2
  exit 1
fi

git clone -- "$URL" "$TARGET"
inject_into "$TARGET"

# Fork detection
if command -v gh >/dev/null 2>&1; then
  if (cd "$TARGET" && gh repo view --json isFork --jq .isFork 2>/dev/null | grep -q true); then
    echo "WARN: this repo is a fork. GHJig-Claude is upstream-only." >&2
  fi
fi

echo "next: cd $TARGET && ghjig"
