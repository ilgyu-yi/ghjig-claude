# shellcheck shell=bash
# helpers/ac_closeout_gate.sh — `gh pr merge` AC-closeout gate logic.
# Sourced by pre_tool_use.sh and (optionally) by scripts/ac_closeout.sh.
#
# Public:
#   extract_pr_from_merge_cmd <cmd> — print the first integer argv to
#     `gh pr merge` and return 0, or print nothing and return 1 if the
#     cmd has no explicit PR number. Tolerates flags between `merge`
#     and the number.
#   pr_needs_closeout <pr-num> — query gh for the PR's
#     `closingIssuesReferences`; for each linked issue, check whether
#     it has unchecked AC and lacks a `^## AC closeout` header comment.
#     Returns: 0 = needs closeout (block), 1 = allows, 2 = indeterminate.
#     gh calls are bounded by `timeout 5` (or `gtimeout 5` on macOS;
#     unbounded fallback if neither is present). Indeterminate maps to
#     allow in the caller (fail-open per SPEC §6.1).

extract_pr_from_merge_cmd() {
  local cmd="$1"
  local rest token
  # Strip up to and including `gh pr merge`; the remainder is the argv.
  # No `\b` — BSD sed (macOS) doesn't recognize it. The grep matcher in
  # pre_tool_use.sh already validated that `gh pr merge` is present as a
  # token, so plain `.*gh[[:space:]]+pr[[:space:]]+merge` is sufficient.
  rest=$(printf '%s' "$cmd" | sed -nE 's/.*gh[[:space:]]+pr[[:space:]]+merge//p')
  # Collapse runs of whitespace so word-split picks tokens cleanly.
  rest=$(printf '%s' "$rest" | tr -s '[:space:]')
  for token in $rest; do
    case "$token" in
      -*) continue ;;
      [0-9]*) printf '%s' "$token"; return 0 ;;
    esac
  done
  return 1
}

# _ac_run_gh <args...> — wrap a gh call in `timeout 5`; emit to stdout.
# Returns gh's exit code (or 124 on timeout). Fallback to unbounded gh
# if no timeout binary is on PATH.
_ac_run_gh() {
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  fi
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" 5 gh "$@"
  else
    gh "$@"
  fi
}

pr_needs_closeout() {
  local pr="$1"
  [ -z "$pr" ] && return 2
  command -v gh >/dev/null 2>&1 || return 2

  local issues rc
  issues=$(_ac_run_gh pr view "$pr" --json closingIssuesReferences -q '.closingIssuesReferences[].number' 2>/dev/null)
  rc=$?
  [ "$rc" != 0 ] && return 2
  [ -z "$issues" ] && return 1  # no linked issues → allow

  local n body comments
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    body=$(_ac_run_gh issue view "$n" --json body -q .body 2>/dev/null)
    rc=$?
    [ "$rc" != 0 ] && return 2
    # No unchecked AC on this issue → it's fine.
    if ! printf '%s' "$body" | grep -q '^- \[ \]'; then
      continue
    fi
    comments=$(_ac_run_gh issue view "$n" --json comments -q '.comments[].body' 2>/dev/null)
    rc=$?
    [ "$rc" != 0 ] && return 2
    # Marker present → covered.
    if printf '%s' "$comments" | grep -q '^## AC closeout'; then
      continue
    fi
    # Any one issue missing the marker triggers the block.
    return 0
  done <<< "$issues"

  return 1
}
