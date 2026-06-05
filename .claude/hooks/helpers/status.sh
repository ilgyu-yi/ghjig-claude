# shellcheck shell=bash
# helpers/status.sh — canonical work-state summary used by /status and
# UserPromptSubmit. Single source of truth so the two surfaces never drift.
# SPEC §5.5.
#
# Public:
#   status_compact — multi-line plaintext block (turn-context surface).
#   status_json    — same fields as stable JSON.
#
# Both modes resolve the same fields. Callers may invoke independently;
# `gh` calls are made at most once per invocation. Results are cached
# per-branch under .claude/state/status-cache/ with STATUS_CACHE_TTL
# seconds (default 5). See SPEC §5.5 "Cache".

# Compute the per-branch cache file path. STATUS_CACHE_DIR_OVERRIDE is
# honored by the smoke tests; production uses the default under
# .claude/state/.
_status_cache_path() {
  local branch="$1"
  local esd; esd=$(eng_state_dir 2>/dev/null || true)
  local dir="${STATUS_CACHE_DIR_OVERRIDE:-${esd:+$esd/status-cache}}"   # per-project (#314)
  [ -n "$dir" ] || dir="${CLAUDE_ENG_SHELL_ROOT:-.}/.claude/state/status-cache"
  local safe
  safe=$(printf '%s' "$branch" | tr '/' '_')
  printf '%s/%s.json' "$dir" "$safe"
}

# Returns 0 iff <file> exists and is younger than STATUS_CACHE_TTL seconds.
_status_cache_fresh() {
  local f="$1"
  [ -f "$f" ] || return 1
  local ttl="${STATUS_CACHE_TTL:-5}"
  local mtime now
  # GNU stat (-c %Y), BSD stat (-f %m).
  if mtime=$(stat -c %Y "$f" 2>/dev/null); then
    :
  elif mtime=$(stat -f %m "$f" 2>/dev/null); then
    :
  else
    return 1
  fi
  now=$(date +%s)
  [ "$((now - mtime))" -le "$ttl" ]
}

# Load a cached JSON file into STATUS_* vars via a single jq @sh pass.
_status_cache_load() {
  local f="$1"
  command -v jq >/dev/null 2>&1 || return 1
  local script
  script=$(jq -r '
    to_entries[] | "STATUS_" + (.key | ascii_upcase) + "=" + (.value // "" | @sh)
  ' "$f" 2>/dev/null) || return 1
  [ -n "$script" ] || return 1
  eval "$script"
}

# Write the current STATUS_* set to <file> atomically. Failures (disk
# full, EACCES, jq missing) are intentionally silent: a missed cache
# write is a perf regression, not a correctness one — the next call
# simply misses again and refetches via gh.
_status_cache_write() {
  local f="$1"
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null
  local tmp="$f.tmp.$$"
  jq -n \
    --arg branch "$STATUS_BRANCH" \
    --arg dirty "$STATUS_DIRTY" \
    --arg pr_num "$STATUS_PR_NUM" \
    --arg pr_state "$STATUS_PR_STATE" \
    --arg pr_title "$STATUS_PR_TITLE" \
    --arg pr_base "$STATUS_PR_BASE" \
    --arg issue_num "$STATUS_ISSUE_NUM" \
    --arg issue_title "$STATUS_ISSUE_TITLE" \
    --arg tasks_done "$STATUS_TASKS_DONE" \
    --arg tasks_total "$STATUS_TASKS_TOTAL" \
    --arg next "$STATUS_NEXT" \
    --arg phase "$STATUS_PHASE" \
    --arg ci "$STATUS_CI" \
    --arg mode "$STATUS_MODE" \
    '{branch:$branch,dirty:$dirty,pr_num:$pr_num,pr_state:$pr_state,pr_title:$pr_title,pr_base:$pr_base,issue_num:$issue_num,issue_title:$issue_title,tasks_done:$tasks_done,tasks_total:$tasks_total,next:$next,phase:$phase,ci:$ci,mode:$mode}' \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}

# Internal: populate STATUS_* vars by querying git + gh + the PR body.
_status_collect() {
  STATUS_BRANCH=""
  STATUS_DIRTY=""
  STATUS_PR_NUM=""
  STATUS_PR_STATE=""
  STATUS_PR_TITLE=""
  STATUS_ISSUE_NUM=""
  STATUS_ISSUE_TITLE=""
  STATUS_PR_BASE=""
  STATUS_TASKS_DONE=""
  STATUS_TASKS_TOTAL=""
  STATUS_NEXT=""
  STATUS_PHASE=""
  STATUS_CI=""
  STATUS_MODE=""

  command -v git >/dev/null 2>&1 || return 0
  STATUS_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

  # Cache short-circuit (SPEC §5.5 Cache). After computing the branch
  # we know the cache key; if the cache is fresh, load + return.
  if [ -n "$STATUS_BRANCH" ]; then
    local _cache_file
    _cache_file=$(_status_cache_path "$STATUS_BRANCH")
    if _status_cache_fresh "$_cache_file" && _status_cache_load "$_cache_file"; then
      return 0
    fi
  fi

  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    STATUS_DIRTY="dirty"
  fi

  if command -v gh >/dev/null 2>&1; then
    local pr_json
    pr_json=$(gh pr view --json number,isDraft,title,body,baseRefName 2>/dev/null)
    if [ -n "$pr_json" ] && command -v jq >/dev/null 2>&1; then
      STATUS_PR_NUM=$(printf '%s' "$pr_json" | jq -r '.number // ""' 2>/dev/null)
      local is_draft
      is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false' 2>/dev/null)
      [ "$is_draft" = "true" ] && STATUS_PR_STATE="draft" || STATUS_PR_STATE="ready"
      STATUS_PR_TITLE=$(printf '%s' "$pr_json" | jq -r '.title // ""' 2>/dev/null)
      STATUS_PR_BASE=$(printf '%s' "$pr_json" | jq -r '.baseRefName // ""' 2>/dev/null)
      local body
      body=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null)

      # Issue from `Closes #N` / `Refs #N` on the first non-empty line.
      local closes_line
      closes_line=$(printf '%s\n' "$body" | grep -m1 -E '^(Closes|Refs) #[0-9]+')
      if [ -n "$closes_line" ]; then
        STATUS_ISSUE_NUM=$(printf '%s' "$closes_line" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
        if [ -n "$STATUS_ISSUE_NUM" ]; then
          STATUS_ISSUE_TITLE=$(gh issue view "$STATUS_ISSUE_NUM" --json title --jq .title 2>/dev/null)
        fi
      fi

      # Checklist progress from "- [x]" / "- [ ]" lines. awk over grep -c
      # because the latter exits 1 on zero matches AND prints "0", which
      # combined with `|| printf '0'` produced "0\n0" and broke the
      # subsequent arithmetic. awk always prints exactly one integer.
      STATUS_TASKS_DONE=$(printf '%s\n' "$body" | awk '/^- \[x\]/ {c++} END {print c+0}')
      local tasks_open
      tasks_open=$(printf '%s\n' "$body" | awk '/^- \[ \]/ {c++} END {print c+0}')
      STATUS_TASKS_TOTAL=$((STATUS_TASKS_DONE + tasks_open))

      # Next unchecked item + the phase it sits under. Walks line-by-line;
      # tracks the most recent phase heading while scanning toward the first
      # unchecked checklist item, then stops. Phase is one of Doc/Test/Code/
      # Review/Ship — whichever section the next-to-do lives in.
      local current_phase=""
      local next_item=""
      while IFS= read -r line; do
        [ -n "$next_item" ] && continue
        case "$line" in
          *"**Phase A"*|*"**Doc**"*|*"Phase A — Doc"*) current_phase="Doc";;
          *"**Phase B"*|*"**Test**"*|*"Phase B — Test"*) current_phase="Test";;
          *"**Phase C"*|*"**Code**"*|*"Phase C — Code"*) current_phase="Code";;
          *"## Ship gate"*) current_phase="Ship";;
        esac
        case "$line" in
          "- [ ] "*)
            next_item=${line#- \[ \] }
            ;;
        esac
      done <<EOF
$body
EOF
      STATUS_NEXT="$next_item"
      STATUS_PHASE="$current_phase"
    fi

    # CI status — single token or `-`.
    local ci_state
    ci_state=$(gh pr checks --json state --jq '[.[].state] | unique | join(",")' 2>/dev/null)
    [ -n "$ci_state" ] && STATUS_CI="$ci_state"
  fi

  if [ -f "${CLAUDE_ENG_SHELL_ROOT:-}/.claude/hooks/helpers/ship_mode.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh"
    STATUS_MODE=$(resolve_mode 2>/dev/null)
  fi

  # Persist the freshly-collected state for the next invocation within
  # the TTL window. Skips silently if we couldn't get a branch (no git
  # repo / empty rev-parse) — no key, no cache.
  if [ -n "$STATUS_BRANCH" ]; then
    _status_cache_write "$(_status_cache_path "$STATUS_BRANCH")"
  fi
}

# Print "-" if the argument is empty; otherwise the argument itself.
_status_or_dash() { [ -n "$1" ] && printf '%s' "$1" || printf '%s' "-"; }

status_compact() {
  _status_collect
  printf '[claude-eng-shell]\n'
  local branch_line="$STATUS_BRANCH"
  [ -n "$STATUS_DIRTY" ] && branch_line="$branch_line ($STATUS_DIRTY)"
  printf 'branch: %s\n' "$(_status_or_dash "$branch_line")"

  local issue_line="-"
  if [ -n "$STATUS_ISSUE_NUM" ]; then
    issue_line="#$STATUS_ISSUE_NUM"
    [ -n "$STATUS_ISSUE_TITLE" ] && issue_line="$issue_line $STATUS_ISSUE_TITLE"
  fi
  printf 'issue: %s\n' "$issue_line"

  local pr_line="-"
  if [ -n "$STATUS_PR_NUM" ]; then
    pr_line="#$STATUS_PR_NUM $STATUS_PR_STATE"
    # Surface a non-`main` base so the user sees which work-stack the
    # PR belongs to (topic-branch / experimental flows, SPEC §10.5).
    if [ -n "$STATUS_PR_BASE" ] && [ "$STATUS_PR_BASE" != "main" ]; then
      pr_line="$pr_line → $STATUS_PR_BASE"
    fi
    pr_line="$pr_line [$STATUS_TASKS_DONE/$STATUS_TASKS_TOTAL tasks] ci: $(_status_or_dash "$STATUS_CI")"
  fi
  printf 'pr: %s\n' "$pr_line"

  printf 'phase: %s\n' "$(_status_or_dash "$STATUS_PHASE")"
  printf 'next: %s\n' "$(_status_or_dash "$STATUS_NEXT")"
  printf 'mode: %s\n' "$(_status_or_dash "$STATUS_MODE")"
}

status_json() {
  _status_collect
  # jq is required for status_json. If absent, emit a minimal {} so callers
  # that parse get a valid JSON object rather than empty stdin.
  if ! command -v jq >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi
  jq -n \
    --arg branch "$STATUS_BRANCH" \
    --arg dirty "$STATUS_DIRTY" \
    --arg pr_num "$STATUS_PR_NUM" \
    --arg pr_state "$STATUS_PR_STATE" \
    --arg pr_title "$STATUS_PR_TITLE" \
    --arg pr_base "$STATUS_PR_BASE" \
    --arg issue_num "$STATUS_ISSUE_NUM" \
    --arg issue_title "$STATUS_ISSUE_TITLE" \
    --arg tasks_done "$STATUS_TASKS_DONE" \
    --arg tasks_total "$STATUS_TASKS_TOTAL" \
    --arg next_item "$STATUS_NEXT" \
    --arg phase "$STATUS_PHASE" \
    --arg ci "$STATUS_CI" \
    --arg mode "$STATUS_MODE" \
    '{
      branch: ($branch | select(. != "") // null),
      dirty: ($dirty == "dirty"),
      pr: (if $pr_num != "" then {
            number: ($pr_num | tonumber),
            state: $pr_state,
            title: $pr_title,
            base: ($pr_base | select(. != "") // null),
            tasks: {done: ($tasks_done | tonumber), total: ($tasks_total | tonumber)}
          } else null end),
      issue: (if $issue_num != "" then {
            number: ($issue_num | tonumber),
            title: $issue_title
          } else null end),
      next: ($next_item | select(. != "") // null),
      phase: ($phase | select(. != "") // null),
      ci: ($ci | select(. != "") // null),
      mode: ($mode | select(. != "") // null)
    }'
}
