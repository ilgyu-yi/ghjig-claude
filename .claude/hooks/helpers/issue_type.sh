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
#   is_initiative_issue <issue#>  (#249)
#     rc 0 → Type=Initiative (the issue carries the `initiative` label).
#     rc 1 → not an Initiative (no `initiative` label) OR unresolvable.
#   is_proposed_issue <issue#>
#     rc 0 → the issue carries the `status:proposed` label.
#     rc 1 → no `status:proposed` label OR unresolvable.
#
# Cache asymmetry (deliberate, #171): `is_directive_issue` caches its result
# per-session at
#   $GHJIG_ROOT/.claude/state/issue-type-cache/<owner>__<repo>__<n>
# because the `directive` label is effectively immutable for a Directive's life
# (the trusted-filer-mutate declassify guard enforces this). `is_initiative_issue`
# (#249) caches the same way — the `initiative` label is likewise stable (the
# read-only-except-comments invariant, M1.2, protects it) — but in a SEPARATE
# cache file (`…__<n>.initiative`) so the two type predicates never clobber each
# other's sentinel on a shared key. `is_proposed_issue`
# does NOT cache: the `status:proposed` label is volatile — `/activate` removes
# it — and a stale `proposed` cache entry would keep a just-activated Issue
# blocked by `proposed-protect` until session restart. The cost is one extra
# `gh issue view` per branch-creation attempt, a cold path, not a hot loop.
# A `gh` failure caches no entry / returns rc 1 — the caller fails open (§6.1).

is_directive_issue() {
  local issue="$1" repo="${2:-}"
  case "$issue" in
    ''|*[!0-9]*) return 1 ;;  # not a number → not a directive issue
  esac

  local cache_dir cache_file esd
  esd=$(ghjig_state_dir 2>/dev/null || true)
  if [ -n "$esd" ]; then
    cache_dir="$esd/issue-type-cache"   # per-project (#314)
  else
    : "${GHJIG_ROOT:?GHJIG_ROOT must be set}"
    cache_dir="$GHJIG_ROOT/.claude/state/issue-type-cache"
  fi
  # Cache key: the GH owner/name. An explicit `repo` arg (#276, e.g. a `-R`/URL
  # cross-repo selector) overrides the cwd repo for BOTH the key and the query,
  # so a foreign `owner/repo#N` lookup keys on `owner__repo__N` and can never
  # poison the current repo's same-numbered entry (the #231 collision class).
  # Empty repo → current repo (existing behavior; callers passing only <issue#>
  # are unchanged). If gh repo view fails (not a GH repo / no auth), bail rc 1 —
  # defer Type-awareness to the no-op state per SPEC §6.1 fail-open framing.
  local owner name
  if [ -n "$repo" ]; then
    owner="${repo%%/*}"
    name="${repo##*/}"
  else
    owner=$(gh repo view --json owner -q .owner.login 2>/dev/null) || return 1
    name=$(gh repo view --json name -q .name 2>/dev/null) || return 1
  fi
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
  if [ -n "$repo" ]; then
    labels=$(gh issue view "$issue" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null) || return 1
  else
    labels=$(gh issue view "$issue" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null) || return 1
  fi

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

# is_initiative_issue <issue#> — rc 0 if the issue carries the `initiative`
# label (Type=Initiative, the planning tier above a Directive, SPEC §1.7), rc 1
# otherwise OR unresolvable. Symmetric to is_directive_issue; caches in a SEPARATE
# file (`…__<n>.initiative`) with its own sentinels so it never clobbers / is
# clobbered by the directive/execution cache on a shared key (#249).
is_initiative_issue() {
  local issue="$1" repo="${2:-}"
  case "$issue" in
    ''|*[!0-9]*) return 1 ;;  # not a number → not an initiative issue
  esac

  local cache_dir cache_file esd
  esd=$(ghjig_state_dir 2>/dev/null || true)
  if [ -n "$esd" ]; then
    cache_dir="$esd/issue-type-cache"   # per-project (#314)
  else
    : "${GHJIG_ROOT:?GHJIG_ROOT must be set}"
    cache_dir="$GHJIG_ROOT/.claude/state/issue-type-cache"
  fi
  # Repo override (#276): same contract as is_directive_issue — an explicit
  # owner/name keys (and queries) the foreign repo; empty → current repo. The
  # `.initiative` cache suffix is preserved on the repo-qualified key so the
  # initiative sentinel never collides with the directive/execution sentinel.
  local owner name
  if [ -n "$repo" ]; then
    owner="${repo%%/*}"
    name="${repo##*/}"
  else
    owner=$(gh repo view --json owner -q .owner.login 2>/dev/null) || return 1
    name=$(gh repo view --json name -q .name 2>/dev/null) || return 1
  fi
  cache_file="$cache_dir/${owner}__${name}__${issue}.initiative"

  if [ -f "$cache_file" ]; then
    local cached
    cached=$(cat "$cache_file" 2>/dev/null) || true
    case "$cached" in
      initiative) return 0 ;;
      not-initiative) return 1 ;;
      # any other value → fall through to refetch
    esac
  fi

  local labels
  if [ -n "$repo" ]; then
    labels=$(gh issue view "$issue" --repo "$repo" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null) || return 1
  else
    labels=$(gh issue view "$issue" --json labels -q '[.labels[].name] | join(",")' 2>/dev/null) || return 1
  fi

  mkdir -p "$cache_dir" 2>/dev/null || true
  # Comma-list boundary match (mirrors is_directive_issue; NOT a grep word-match,
  # so `initiative-foo` does not over-match).
  if printf '%s' "$labels" | grep -qiE '(^|,)initiative(,|$)'; then
    printf 'initiative\n' > "$cache_file" 2>/dev/null || true
    return 0
  else
    printf 'not-initiative\n' > "$cache_file" 2>/dev/null || true
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
  local issue="$1" repo="${2:-}"
  case "$issue" in
    ''|*[!0-9]*) return 2 ;;  # not a number → cannot resolve → fail open
  esac

  local body="" first_line=""
  if [ -n "$repo" ]; then
    body=$(gh issue view "$issue" --repo "$repo" --json body -q .body 2>/dev/null) || return 2
  else
    body=$(gh issue view "$issue" --json body -q .body 2>/dev/null) || return 2
  fi
  first_line=$(printf '%s\n' "$body" | head -1 || true)
  first_line=${first_line%$'\r'}  # #505: tolerate a trailing CRLF \r (Windows/paste)
  if printf '%s' "$first_line" | grep -qE '^Parent Directive: #[0-9]+$'; then
    return 0
  fi
  return 1
}

# issue_has_initiative_parent_marker <issue#> — TRI-STATE resolver for the line-1
# `Parent Initiative: #N` marker that parents a *Directive* under an Initiative
# (#249). DISTINCT from issue_has_parent_marker (which resolves the
# `Parent Directive: #N` marker that parents an *Execution Issue* under a
# Directive): the two markers sit on different artifact types, so a
# `Parent Directive` line is NOT an initiative-parent marker (returns rc 1 here).
# Generalizing the existing resolver would have let an `execution`-labelled Issue
# parented to an Initiative pass label-parent-consistency — hence a separate
# predicate. Same tri-state contract (0 present / 1 absent / 2 unresolvable) and
# UNCACHED rationale as issue_has_parent_marker.
#   rc 0 → marker present (body line 1 matches `^Parent Initiative: #[0-9]+$`)
#   rc 1 → resolved, marker ABSENT
#   rc 2 → unresolvable (not a number / gh failure / no auth / issue not found)
issue_has_initiative_parent_marker() {
  local issue="$1" repo="${2:-}"
  case "$issue" in
    ''|*[!0-9]*) return 2 ;;  # not a number → cannot resolve → fail open
  esac

  local body="" first_line=""
  if [ -n "$repo" ]; then
    body=$(gh issue view "$issue" --repo "$repo" --json body -q .body 2>/dev/null) || return 2
  else
    body=$(gh issue view "$issue" --json body -q .body 2>/dev/null) || return 2
  fi
  first_line=$(printf '%s\n' "$body" | head -1 || true)
  first_line=${first_line%$'\r'}  # #505: tolerate a trailing CRLF \r (Windows/paste)
  if printf '%s' "$first_line" | grep -qE '^Parent Initiative: #[0-9]+$'; then
    return 0
  fi
  return 1
}

# issue_has_mission_fit_field <issue#> — TRI-STATE resolver for a Directive's
# `## MISSION fit` body field, the MISSION-section parent kind (§1.7/§2.1, #251).
# Unlike the line-1 `Parent {Directive,Initiative}` markers, the MISSION-fit field
# is a heading ANYWHERE in the body. Used by the label-parent-consistency
# parent-XOR alongside issue_has_initiative_parent_marker. Same tri-state +
# UNCACHED contract as the marker resolvers.
#   rc 0 → a `## MISSION fit` heading is present in the body
#   rc 1 → resolved, heading ABSENT
#   rc 2 → unresolvable (not a number / gh failure / no auth / issue not found)
issue_has_mission_fit_field() {
  local issue="$1"
  case "$issue" in
    ''|*[!0-9]*) return 2 ;;
  esac

  local repo="${2:-}"
  local body=""
  if [ -n "$repo" ]; then
    body=$(gh issue view "$issue" --repo "$repo" --json body -q .body 2>/dev/null) || return 2
  else
    body=$(gh issue view "$issue" --json body -q .body 2>/dev/null) || return 2
  fi
  if printf '%s\n' "$body" | grep -qE '^##[[:space:]]+MISSION fit[[:space:]]*$'; then
    return 0
  fi
  return 1
}

# resolve_gh_issue_target <cmd> <verb-alternation> — extract the target issue
# number and (optionally) the owner/name repo from a `gh issue <verb> ...`
# command, tolerant of (a) selector FORM — bare / quoted / URL — and (b) flag
# ORDER (the positional issue arg need not immediately follow the verb). Echoes
# "<issue><TAB><repo>" (either field may be empty). Shared by the
# label-parent-consistency and initiative-readonly matchers (#276) so the
# selector parsers do not drift independently (the A1/A2 bypass class that this
# function closes). Portability: echo + `IFS=$'\t' read`, NOT bash-4 namerefs
# (macOS bash 3.2 is a supported target). Fail-soft: an unparseable command
# yields an empty issue → the caller's existing `[ -z "$issue" ]` arm fails open.
#
# Flag-order heuristic: gh's `issue edit/close/reopen` flags overwhelmingly take
# a value (`--add-label X`, `--body X`, `--repo X`, `-R X`); the FIRST positional
# token that is a bare integer is the issue selector. We skip each `-flag` and its
# following value token (the `--flag=value` form consumes a single token), so a
# flag value that happens to contain digits (`--repo o/r2`) is never mistaken for
# the issue number. Boolean flags before the positional are vanishingly rare on
# these subcommands; treating a flag as value-taking is the safe over-skip.
resolve_gh_issue_target() {
  local cmd="$1" verbs="$2"
  local issue="" repo=""
  printf '%s' "$cmd" | grep -qE "\\bgh[[:space:]]+issue[[:space:]]+(${verbs})\\b" || { printf '\t'; return 0; }
  # URL form anywhere → issue + owner/name straight from the URL (authoritative).
  if [[ "$cmd" =~ [Hh][Tt][Tt][Pp][Ss]?://[^[:space:]\"\']+/([^/[:space:]\"\']+)/([^/[:space:]\"\']+)/issues/([0-9]+) ]]; then
    printf '%s\t%s' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return 0
  fi
  # Bare/flag-ordered: tokenize and walk, skipping flags (+ their value token).
  # Tokenize SHELL-AWARE (quotes preserved) so a quoted flag value's interior
  # digits — `--body "fixes 99 things"` — are not mistaken for the positional
  # issue selector (#283). Mirror check_destructive_args: python3 `shlex.split`,
  # else a `read -ra` fallback. On an unparseable command (unclosed quote) emit
  # an empty issue → the caller fails open (such a command would not execute in
  # a real shell anyway). The `read -ra` fallback keeps the #276 local-IFS pin so
  # a caller's `IFS=$'\t'` cannot leak into this command substitution.
  local -a toks=()
  if command -v python3 >/dev/null 2>&1; then
    local _tok_out
    if _tok_out=$(printf '%s' "$cmd" | python3 -c '
import shlex, sys
try:
    for t in shlex.split(sys.stdin.read()):
        print(t)
except ValueError:
    sys.exit(2)
' 2>/dev/null); then
      local _t
      while IFS= read -r _t; do [ -n "$_t" ] && toks+=("$_t"); done <<< "$_tok_out"
    else
      printf '\t'; return 0   # unparseable (unclosed quote) → fail open
    fi
  else
    local IFS=$' \t\n'
    read -ra toks <<< "$cmd"
  fi
  local i t skip_next=""
  for ((i=0; i<${#toks[@]}; i++)); do
    t="${toks[$i]}"
    if [ -n "$skip_next" ]; then skip_next=""; continue; fi
    case "$t" in
      --repo=*|-R=*) repo="${t#*=}"; continue ;;
      --repo|-R)     repo="${toks[$((i+1))]:-}"; skip_next=1; continue ;;
      --*=*)         continue ;;             # long flag with inline value → 1 token
      -*)            skip_next=1; continue ;; # flag consumes its value token
    esac
    # A positional token: the issue selector is the first bare integer one.
    if [ -z "$issue" ]; then
      case "$t" in
        ''|*[!0-9]*) ;;        # gh / issue / verb / non-numeric positionals → skip
        *) issue="$t" ;;
      esac
    fi
  done
  # Normalize a host-prefixed repo (#283): gh accepts `[HOST/]OWNER/REPO`, so a
  # `--repo github.com/o/r` arrives as three segments; strip the leading host so
  # downstream `${repo%%/*}`/`${repo##*/}` derive owner=o, name=r (not
  # owner=github.com, name=r → a wrong-repo / fail-open lookup). A plain
  # `owner/name` (one slash) is unchanged.
  case "$repo" in
    */*/*) repo="${repo#*/}" ;;
  esac
  printf '%s\t%s' "$issue" "$repo"
}
