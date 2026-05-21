# shellcheck shell=bash
# helpers/gh_state.sh — gh CLI wrappers. Source from hooks.

current_pr_number() {
  gh pr view --json number --jq .number 2>/dev/null
}

current_pr_field() {
  local n="$1" field="$2"
  gh pr view "$n" --json "$field" --jq ".$field" 2>/dev/null
}

current_pr_state_line() {
  local n="${1:-$(current_pr_number)}"
  [ -n "$n" ] || return 1
  gh pr view "$n" --json isDraft,headRefName,title \
    --jq '"\(.isDraft)|\(.headRefName)|\(.title)"' 2>/dev/null
}

pr_is_draft() {
  local n="${1:-$(current_pr_number)}"
  [ -n "$n" ] || return 1
  local d
  d=$(gh pr view "$n" --json isDraft --jq .isDraft 2>/dev/null) || return 1
  [ "$d" = "true" ]
}

issue_body() {
  local n="$1"
  gh issue view "$n" --json body --jq .body 2>/dev/null
}