# shellcheck shell=bash
# .claude/hooks/helpers/issue_type.sh — Type-awareness predicate for dir-mode.
#
# Used by pre_tool_use.sh matchers (SPEC §1.7, §6.1) to distinguish Directive
# Issues (the `directive` label) from Execution Issues (everything else).
#
# Function:
#   is_directive_issue <issue#>
#     rc 0 → Type=Directive (the issue carries the `directive` label).
#     rc 1 → Type=Execution (no `directive` label) OR unresolvable.
#
# Caches the result per-session at
#   $CLAUDE_ENG_SHELL_ROOT/.claude/state/issue-type-cache/<owner>__<repo>__<n>
# so a hot loop of matcher invocations doesn't issue an N+1 cascade of
# `gh issue view` calls. Cache lifetime: per-session; the cache directory is
# gitignored. A `gh` failure caches no entry — the next invocation retries.

is_directive_issue() {
  local issue="$1"
  case "$issue" in
    ''|*[!0-9]*) return 1 ;;  # not a number → not a directive issue
  esac

  : "${CLAUDE_ENG_SHELL_ROOT:?CLAUDE_ENG_SHELL_ROOT must be set}"

  local cache_dir cache_file
  cache_dir="$CLAUDE_ENG_SHELL_ROOT/.claude/state/issue-type-cache"
  # Cache key: use the repo's GH owner/name (resolved once per invocation).
  # If gh repo view fails (not a GH repo or no auth), bail rc 1 — defer
  # Type-awareness to the no-op state per SPEC §6.1 fail-open framing.
  local owner name
  owner=$(gh repo view --json owner -q .owner.login 2>/dev/null) || return 1
  name=$(gh repo view --json name -q .name 2>/dev/null) || return 1
  cache_file="$cache_dir/${owner}__${name}__${issue}"

  if [ -f "$cache_file" ]; then
    local cached
    cached=$(cat "$cache_file" 2>/dev/null) || true
    case "$cached" in
      directive) return 0 ;;
      execution) return 1 ;;
      # any other value → fall through to refetch
    esac
  fi

  # Fetch labels via gh. If the issue doesn't exist or gh fails, return 1
  # without caching — the hook will fail-open per SPEC §6.1.
  local labels
  labels=$(gh issue view "$issue" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null) || return 1

  mkdir -p "$cache_dir" 2>/dev/null || true
  # Case-insensitive whole-word match against the comma-separated list.
  if printf '%s' "$labels" | grep -qiwE 'directive'; then
    printf 'directive\n' > "$cache_file" 2>/dev/null || true
    return 0
  else
    printf 'execution\n' > "$cache_file" 2>/dev/null || true
    return 1
  fi
}
