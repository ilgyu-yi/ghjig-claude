#!/usr/bin/env bash
# scripts/lint_bash_idioms.sh — born-advisory, non-gating bash idiom checker (#546).
# See SPEC §4.5.1.
#
# A THIN WRAPPER, not a lint engine (challenger B1). It surfaces only the
# DETERMINISTIC subset of the bash idiom rubric (.claude/rubrics/bash.md — the
# criteria SSOT); the function-size, DRY, and detection-by-attribute-combination
# smell criteria are LLM-judgment and are applied by code-reviewer, never here.
#
#   1. REUSE, don't re-handroll (invariant #6, #276/#490): for general
#      quoting/array idioms it invokes the ALREADY-PINNED shellcheck resolved by
#      scripts/lint.sh (ensure_pinned_shellcheck) at a BROADER advisory severity
#      (--severity=style) than the CI gate's --severity=warning, so its findings
#      are NON-OVERLAPPING with the gate (softer style/info the gate never blocks).
#      If shellcheck cannot be resolved (offline, no cache) it DEGRADES GRACEFULLY
#      — the shellcheck arm is skipped, the greps still run; never a hard fail.
#   2. Project-policy greps (the only hand-rolled code): a raw `source`/`.` of a
#      helper that bypasses safe_source (rubric §2), and a bare `git add -A`/`-u`
#      (rubric §3, the path-scoped-add discipline).
#
# Advisory by construction: findings print to stdout and the exit code is always 0
# on a normal run — this checker NEVER gates a caller (SPEC §6.0 advisory face). It
# is deliberately NOT wired into the fail-closed CI lint gate (scripts/lint.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the pinned shellcheck by REUSING scripts/lint.sh's resolver. lint.sh
# guards its own main() behind a BASH_SOURCE==$0 check, so sourcing it only
# defines the functions. Degrade gracefully if resolution fails (offline / no
# cache) — the shellcheck arm is optional, the greps are the reliable signal.
SHELLCHECK_BIN=""
# shellcheck source=/dev/null
if source "$SCRIPT_DIR/lint.sh" 2>/dev/null; then
  set +e  # lint.sh sets `set -e`; this checker is advisory and must not abort.
  set +o pipefail
  if command -v ensure_pinned_shellcheck >/dev/null 2>&1; then
    SHELLCHECK_BIN="$(ensure_pinned_shellcheck 2>/dev/null)" || SHELLCHECK_BIN=""
  fi
fi

# --- deterministic project-policy greps (rubric §2, §3) --------------------
# grep -n output is `<lineno>:<text>`; the trailing `grep -vE ':[[:space:]]*#'`
# drops comment-only lines (a `# … safe_source …` mention is not a violation)
# while preserving a trailing comment on a real command line.
report_grep() {
  local f="$1" msg="$2" pat="$3" hits ln
  hits="$(grep -nE "$pat" "$f" 2>/dev/null | grep -vE ':[[:space:]]*#')"
  [ -n "$hits" ] || return 0
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    printf '[idiom] %s: %s:%s\n' "$msg" "$f" "$ln"
  done <<< "$hits"
}

# --- advisory shellcheck arm (reused pinned binary, broader severity) ------
report_shellcheck() {
  local f="$1" out
  [ -n "$SHELLCHECK_BIN" ] || return 0
  out="$("$SHELLCHECK_BIN" --severity=style --shell=bash "$f" 2>/dev/null)"
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

scan_file() {
  local f="$1"
  # §2: raw `source <path>` or `. <path>` of a helper (bypasses safe_source).
  # `safe_source` is not matched: the char before `source` is `_`, excluded by
  # the [^_[:alnum:]] boundary; a leading dot needs trailing whitespace so a
  # path like `foo.sh` (dot then a letter) is not a false positive.
  report_grep "$f" \
    "raw source of a helper — route through safe_source (rubric §2)" \
    '(^|[^_[:alnum:]])(source|\.)[[:space:]]+[[:graph:]]'
  # §3: bare `git add -A` / `git add -u` — must be path-scoped.
  report_grep "$f" \
    "bare git add -A/-u — use a path-scoped add (rubric §3)" \
    'git[[:space:]]+add[[:space:]]+(-A|-u|--all|--update)([^[:alnum:]]|$)'
  # §1: general quoting/array idioms — delegated to the reused pinned shellcheck
  # at a broader-than-gate advisory severity.
  report_shellcheck "$f"
}

main() {
  local f
  if [ "$#" -eq 0 ]; then
    echo "usage: lint_bash_idioms.sh <file.sh> [<file.sh> ...]" >&2
    return 2
  fi
  for f in "$@"; do
    if [ ! -f "$f" ]; then
      echo "skip (not a file): $f" >&2
      continue
    fi
    scan_file "$f"
  done
  # Advisory: always exit 0 — findings on stdout never gate the caller.
  return 0
}

main "$@"
