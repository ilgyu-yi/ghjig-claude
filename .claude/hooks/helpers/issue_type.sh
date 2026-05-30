# shellcheck shell=bash
# .claude/hooks/helpers/issue_type.sh — Type-awareness predicate for dir-mode.
#
# Used by pre_tool_use.sh matchers (SPEC §1.7, §6.1) to distinguish Directive
# Issues (the `directive` label) from Execution Issues (everything else).
#
# Functions:
#   is_directive_issue <issue#>
#     rc 0 → Type=Directive (the issue carries the `directive` label).
#     rc 1 → Type=Execution (no `directive` label) OR unresolvable.
#   is_proposed_issue <issue#>
#     rc 0 → the issue carries the `status:proposed` label.
#     rc 1 → no `status:proposed` label OR unresolvable.
#
# Cache asymmetry (deliberate, #171): `is_directive_issue` caches its result
# per-session at
#   $CLAUDE_ENG_SHELL_ROOT/.claude/state/issue-type-cache/<owner>__<repo>__<n>
# because the `directive` label is effectively immutable for a Directive's life
# (the trusted-filer-mutate declassify guard enforces this). `is_proposed_issue`
# does NOT cache: the `status:proposed` label is volatile — `/activate` removes
# it — and a stale `proposed` cache entry would keep a just-activated Issue
# blocked by `proposed-protect` until session restart. The cost is one extra
# `gh issue view` per branch-creation attempt, a cold path, not a hot loop.
# A `gh` failure caches no entry / returns rc 1 — the caller fails open (§6.1).

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
  # Case-insensitive match anchored on comma-list boundaries (mirrors
  # is_proposed_issue). NOT a grep word-match: `-w` treats `-` as a boundary,
  # so `non-directive`/`directive-foo` would mis-classify (#212).
  if printf '%s' "$labels" | grep -qiE '(^|,)directive(,|$)'; then
    printf 'directive\n' > "$cache_file" 2>/dev/null || true
    return 0
  else
    printf 'execution\n' > "$cache_file" 2>/dev/null || true
    return 1
  fi
}

# is_proposed_issue <issue#> — rc 0 if the issue carries the `status:proposed`
# label, rc 1 otherwise (or if unresolvable). UNCACHED by design (see the
# cache-asymmetry note in the header): the label is volatile under `/activate`.
is_proposed_issue() {
  local issue="$1"
  case "$issue" in
    ''|*[!0-9]*) return 1 ;;  # not a number → cannot be a proposed issue
  esac

  # No cache read/write — query gh fresh every call. gh infers the repo from
  # cwd; no owner/name resolution needed (that was only for the cache key).
  local labels
  labels=$(gh issue view "$issue" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null) || return 1

  # Match the `status:proposed` label exactly within the comma-joined list.
  # The colon is a non-word char, so grep -w is unreliable here — anchor on
  # list boundaries (start/comma … comma/end) instead.
  if printf '%s' "$labels" | grep -qE '(^|,)status:proposed(,|$)'; then
    return 0
  else
    return 1
  fi
}

# issue_has_parent_marker <issue#> — TRI-STATE resolver for the canonical line-1
# `Parent Directive: #N` marker (the same resolver /link-directive writes and
# /reflect + the issues-to-project-mirror / dir-mode-post-merge workflows read;
# every consumer reads the FIRST body line, so "parented" is defined as the
# line-1 marker — see issues-to-project-mirror.yml).
#   rc 0 → marker present (body line 1 matches `^Parent Directive: #[0-9]+$`)
#   rc 1 → resolved, marker ABSENT
#   rc 2 → unresolvable (not a number / gh failure / no auth / issue not found)
# The tri-state is load-bearing for the `label-parent-consistency` matcher
# (§6.1): that matcher blocks `--add-label execution` on the ABSENCE of a marker,
# so it MUST distinguish a resolved-absent body (rc 1 → block) from an
# unresolvable one (rc 2 → fail-open allow). A plain 0/1 predicate would conflate
# the two and block on gh-down — the opposite of the §6.1 fail-open contract.
# UNCACHED, like is_proposed_issue: the marker is volatile (/link-directive
# prepends it post-creation; a relabel may add/remove it), so a stale cache would
# mis-gate a just-edited Issue until session restart.
issue_has_parent_marker() {
  local issue="$1"
  case "$issue" in
    ''|*[!0-9]*) return 2 ;;  # not a number → cannot resolve → fail open
  esac

  local body="" first_line=""
  body=$(gh issue view "$issue" --json body -q .body 2>/dev/null) || return 2
  first_line=$(printf '%s\n' "$body" | head -1 || true)
  if printf '%s' "$first_line" | grep -qE '^Parent Directive: #[0-9]+$'; then
    return 0
  fi
  return 1
}
