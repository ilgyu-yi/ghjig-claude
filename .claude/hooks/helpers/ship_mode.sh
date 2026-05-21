# shellcheck shell=bash
# helpers/ship_mode.sh — operating-mode resolution + post-ready dispatch.
# Source from /ship and /status. SPEC §5.7.1.

# resolve_mode [--mode=VALUE]
# Stdout: `attended` or `unattended`.
# Unknown values fail closed to `attended` with a stderr warning naming
# the offending surface (flag/env/file). The surface is internal to the
# warning; not exposed as a return value — callers that need the bare
# mode use `mode=$(resolve_mode)` and don't have to think about scoping.
resolve_mode() {
  local flag_val="" arg raw="" surface=""
  for arg in "$@"; do
    case "$arg" in
      --mode=*) flag_val="${arg#--mode=}";;
    esac
  done

  if [ -n "$flag_val" ]; then
    raw="$flag_val"; surface="flag"
  elif [ -n "${CLAUDE_ENG_SHELL_MODE:-}" ]; then
    raw="$CLAUDE_ENG_SHELL_MODE"; surface="env"
  elif [ -f .claude/state/mode ]; then
    raw=$(head -c 64 .claude/state/mode 2>/dev/null | tr -d '[:space:]')
    surface="file"
  fi

  case "$raw" in
    attended|unattended) printf '%s\n' "$raw";;
    "")                  printf '%s\n' "attended";;
    *)
      printf 'ship_mode: unknown mode %q from %s — using attended\n' \
        "$raw" "$surface" >&2
      printf '%s\n' "attended"
      ;;
  esac
}

# ship_classify_blocker — JSON on stdin → `clean` | `soft` | `hard` on stdout.
# Input shape: subset of `gh pr view --json mergeable,mergeStateStatus,statusCheckRollup,reviewDecision,reviewRequests`.
ship_classify_blocker() {
  local json
  json=$(cat)
  if [ -z "$json" ]; then
    printf 'ship_classify_blocker: no input on stdin — defaulting to hard\n' >&2
    printf 'hard\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'ship_classify_blocker: jq not found — defaulting to hard\n' >&2
    printf 'hard\n'
    return 0
  fi

  if printf '%s' "$json" | jq -e \
       '(.statusCheckRollup // []) | map(.status // .conclusion // "") |
        any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED")' \
       >/dev/null 2>&1; then
    printf 'soft\n'; return 0
  fi

  local review_decision review_requests_len merge_state
  review_decision=$(printf '%s' "$json" | jq -r '.reviewDecision // ""' 2>/dev/null)
  review_requests_len=$(printf '%s' "$json" | jq -r '(.reviewRequests // []) | length' 2>/dev/null)
  merge_state=$(printf '%s' "$json" | jq -r '.mergeStateStatus // ""' 2>/dev/null)

  if [ "$review_decision" = "REVIEW_REQUIRED" ] && [ "${review_requests_len:-0}" = "0" ]; then
    printf 'hard\n'; return 0
  fi

  if printf '%s' "$json" | jq -e \
       '(.statusCheckRollup // []) | map(.conclusion // "") |
        any(. == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT")' \
       >/dev/null 2>&1; then
    printf 'hard\n'; return 0
  fi

  if [ "$merge_state" = "BLOCKED" ]; then
    printf 'hard\n'; return 0
  fi

  case "$review_decision" in
    ""|APPROVED) printf 'clean\n';;
    *)           printf 'hard\n';;
  esac
}

# ship_decide_post_ready <mode> [<classification>]
# Stdout: `stop` | `merge` | `fix-and-wait` | `park`.
# Attended always returns `stop` and ignores the second arg.
ship_decide_post_ready() {
  local mode="${1:-attended}"
  local class="${2:-}"
  case "$mode" in
    attended)
      printf 'stop\n'
      ;;
    unattended)
      case "$class" in
        clean) printf 'merge\n';;
        soft)  printf 'fix-and-wait\n';;
        hard)  printf 'park\n';;
        *)     printf 'park\n';;
      esac
      ;;
    *)
      printf 'stop\n'
      ;;
  esac
}

# ship_park_pr <reason-token>
# Idempotent. On a fresh park (label `unattended-parked` not yet present):
#   Stdout: deterministic comment string (reason token verbatim).
#   Side effect: appends one timestamped park line to $SHIP_PARK_LOG_PATH.
# On a repeat park (label already present from a previous park):
#   Stdout: empty.
#   Side effect: appends one `park-suppressed: <reason>` line to the log.
# Default log path: $CLAUDE_ENG_SHELL_ROOT/.claude/state/unattended-park.log.
#
# Cwd requirement: the label check uses `gh pr view --json labels` with no
# explicit PR identifier, so `gh`'s branch→PR detection picks the current
# branch's PR. The caller's cwd must be inside the target repo's worktree on
# the PR's branch. `/ship` callers satisfy this; cron/CI callers may need to
# `cd` first or extend this helper to accept an explicit PR number.
ship_park_pr() {
  local reason="${1:-unspecified}"
  local log_path="${SHIP_PARK_LOG_PATH:-$CLAUDE_ENG_SHELL_ROOT/.claude/state/unattended-park.log}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true

  local labels=""
  if command -v gh >/dev/null 2>&1; then
    labels=$(gh pr view --json labels --jq '.labels[].name' 2>/dev/null)
  fi

  # Whitespace-tolerant exact-line match: tolerate leading/trailing spaces
  # on either side of the label name (clean gh output has neither, but a
  # future shim or formatter mustn't slip past silently).
  if printf '%s\n' "$labels" | grep -qE '^[[:space:]]*unattended-parked[[:space:]]*$'; then
    printf '%s park-suppressed: %s\n' "$ts" "$reason" >> "$log_path"
    return 0
  fi

  printf '%s parked reason=%s\n' "$ts" "$reason" >> "$log_path"

  printf 'unattended-parked\n'
  printf 'reason: %s\n' "$reason"
  printf 'time: %s\n' "$ts"
  printf 'See SPEC §5.7.1 for the operating-mode contract.\n'
}