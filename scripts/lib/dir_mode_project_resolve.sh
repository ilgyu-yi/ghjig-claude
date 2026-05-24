# shellcheck shell=bash
# scripts/lib/dir_mode_project_resolve.sh — shared dir-mode Project-resolution helpers
# (SPEC §1.7 / issue #71). Sourced by:
#   - scripts/setup_project.sh   (find-or-create path; preserves pre-#71 behavior)
#   - scripts/dir_mode_project.sh (find-only path; deterministic gate for /file-directive)
#
# Each function returns a specific rc on failure; parent scripts decide whether
# to translate the rc (setup_project.sh uses `|| exit 1` to stay byte-identical
# with pre-#71 behavior; dir_mode_project.sh propagates `|| exit $?` so callers
# can dispatch on the specific failure mode).
#
# Return codes (also used as dir_mode_project.sh's exit codes):
#   1 — registry guard: cwd not in .claude/state/registry.txt
#   2 — gh not authenticated
#   3 — gh token missing 'project' scope
#   4 — gh repo view failed (no GitHub remote, or owner unresolvable)
#   5 — no Project named "<project-name>" for the resolved owner
#   6 — jq missing
#
# Globals set on success (per function):
#   dr_resolve_owner_repo: DR_OWNER, DR_REPO_NAME, DR_PROJECT_NAME
#   dr_find_project:       DR_PROJECT_NUM
#
# Parent scripts MUST set, before sourcing:
#   DR_SCRIPT_NAME       — string used in stderr prefixes (e.g. "setup_project").
#   DR_AUDIT_CATEGORY    — audit_log category (e.g. "project-setup" / "project-resolve").
#   CLAUDE_ENG_SHELL_ROOT — shell root (for registry path).
# Parent scripts MUST have audit_log available (sourced from hookrt.sh or stubbed
# as a no-op).

: "${DR_SCRIPT_NAME:=dir_mode_project}"
: "${DR_AUDIT_CATEGORY:=project-resolve}"

# Defensive: if the parent forgot to source hookrt.sh (or stub audit_log), the
# lib's `audit_log ... 2>/dev/null || true` calls would emit `command not found`
# to stderr before `|| true` swallows the rc. Stub here keeps stderr clean.
command -v audit_log >/dev/null 2>&1 || audit_log() { :; }

# rc=1 if cwd is not a registered target.
dr_check_registry_guard() {
  local target registry
  target=$(pwd -P)
  registry="$CLAUDE_ENG_SHELL_ROOT/.claude/state/registry.txt"
  if [ ! -f "$registry" ] || ! grep -qxF "$target" "$registry"; then
    echo "$DR_SCRIPT_NAME: refusing — '$target' is not a registered target" >&2
    echo "  Register first: $CLAUDE_ENG_SHELL_ROOT/scripts/register.sh '$target'" >&2
    audit_log block "$DR_AUDIT_CATEGORY" deny "unregistered-path: $target" 2>/dev/null || true
    return 1
  fi
  return 0
}

# rc=2 if gh is not authenticated.
dr_check_gh_auth() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "$DR_SCRIPT_NAME: gh is not authenticated" >&2
    echo "  Run: gh auth login" >&2
    audit_log block "$DR_AUDIT_CATEGORY" deny "gh-not-authenticated" 2>/dev/null || true
    return 2
  fi
  return 0
}

# rc=3 if gh token lacks the 'project' scope.
dr_check_gh_scope() {
  local auth_blob
  auth_blob=$(gh auth status 2>&1 || true)
  if ! printf '%s' "$auth_blob" | grep -iq "token scopes:.*project"; then
    echo "$DR_SCRIPT_NAME: gh token is missing the 'project' scope" >&2
    echo "  Refresh with: gh auth refresh -s project" >&2
    audit_log block "$DR_AUDIT_CATEGORY" deny "missing-project-scope" 2>/dev/null || true
    return 3
  fi
  return 0
}

# rc=6 if jq is not installed.
dr_check_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "$DR_SCRIPT_NAME: jq is required but not installed" >&2
    audit_log block "$DR_AUDIT_CATEGORY" deny "jq-missing" 2>/dev/null || true
    return 6
  fi
  return 0
}

# Resolve owner, repo, and project_name. Sets DR_OWNER / DR_REPO_NAME / DR_PROJECT_NAME.
# rc=4 if gh repo view fails or owner can't be resolved.
dr_resolve_owner_repo() {
  local repo_json
  repo_json=$(gh repo view --json owner,name 2>/dev/null) || {
    echo "$DR_SCRIPT_NAME: gh repo view failed — is this a GitHub-linked repo?" >&2
    audit_log block "$DR_AUDIT_CATEGORY" deny "no-gh-remote" 2>/dev/null || true
    return 4
  }
  DR_OWNER=$(printf '%s' "$repo_json" | jq -r '.owner.login')
  DR_REPO_NAME=$(printf '%s' "$repo_json" | jq -r '.name')
  DR_PROJECT_NAME="${CLAUDE_ENG_PROJECT_NAME:-$DR_REPO_NAME roadmap}"
  if [ -z "$DR_OWNER" ] || [ "$DR_OWNER" = null ]; then
    echo "$DR_SCRIPT_NAME: could not resolve repo owner from gh repo view" >&2
    audit_log block "$DR_AUDIT_CATEGORY" deny "owner-unresolved" 2>/dev/null || true
    return 4
  fi
  return 0
}

# Find the Project by name. Sets DR_PROJECT_NUM on success. rc=5 if not found.
# Caller must have already populated DR_OWNER and DR_PROJECT_NAME via dr_resolve_owner_repo.
dr_find_project() {
  local existing
  existing=$(gh project list --owner "$DR_OWNER" --format json --limit 100 2>/dev/null \
    | jq -r --arg name "$DR_PROJECT_NAME" '.projects[]? | select(.title==$name) | .number' \
    | head -1)
  if [ -z "$existing" ]; then
    echo "$DR_SCRIPT_NAME: no Project named '$DR_PROJECT_NAME' for owner '$DR_OWNER' — run scripts/setup_project.sh first" >&2
    audit_log block "$DR_AUDIT_CATEGORY" deny "no-project: $DR_PROJECT_NAME" 2>/dev/null || true
    return 5
  fi
  # shellcheck disable=SC2034  # consumed by parent script after dr_find_project returns
  DR_PROJECT_NUM="$existing"
  return 0
}

# Reconcile a SINGLE_SELECT field's options additively (issue #76).
# Diffs declared options against the field's current options; on non-empty
# diff, invokes the updateProjectV2Field GraphQL mutation with the UNION
# (current ∪ declared) so user-added options outside the declared set are
# preserved. Idempotent: empty diff is a no-op with an aligned-stdout marker.
#
# Cosmetic note: the GraphQL mutation replaces option color metadata; new
# options default to GRAY, and existing options' colors are not preserved
# (the `gh project field-list` JSON does not surface option colors, so a
# read-and-restore round-trip would require a second GraphQL query). Names
# and option name-matching for selection references are preserved.
#
# Safety note: option names are interpolated directly into the GraphQL
# mutation string. Names containing `"` or `\` are not supported — they
# would break the mutation parse and trigger the audit warn path. The
# three declared sets (Type/Status/Priority) all use alphanumeric + space
# names; the additive-preservation path reads back user-added names from
# GitHub via `gh project field-list`, so a user who manually created an
# option with a quote/backslash is the only scenario that hits this. If
# real friction surfaces, escape via `${o//\\/\\\\}` then `${o//\"/\\\"}`
# before interpolation.
#
# Args: <project_num> <owner> <field_name> <declared_csv>
# rc:   0 always (failures emit audit warn but do not propagate — the
#       additive contract means a missed reconcile is not substrate-breaking,
#       just user-visible drift on the next file-directive attempt).
dr_reconcile_select_options() {
  local proj="$1" own="$2" fname="$3" decl="$4"
  local fields_json fid current_opts missing_opts union_opts
  fields_json=$(gh project field-list "$proj" --owner "$own" --format json --limit 100 2>/dev/null) || {
    audit_log warn "$DR_AUDIT_CATEGORY" notice "reconcile-skip: field-list failed for '$fname'" 2>/dev/null || true
    return 0
  }
  fid=$(printf '%s' "$fields_json" | jq -r --arg name "$fname" '.fields[]? | select(.name==$name) | .id // empty' | head -1)
  if [ -z "$fid" ]; then
    audit_log warn "$DR_AUDIT_CATEGORY" notice "reconcile-skip: field '$fname' not found" 2>/dev/null || true
    return 0
  fi
  current_opts=$(printf '%s' "$fields_json" \
    | jq -r --arg name "$fname" '.fields[]? | select(.name==$name) | .options[]?.name // empty' \
    | tr '\n' ',' | sed 's/,$//')
  # Diff: missing = declared − current.
  missing_opts=""
  local IFS_save="$IFS"
  IFS=','
  local -a dec_arr=()
  read -ra dec_arr <<< "$decl"
  IFS="$IFS_save"
  local opt
  for opt in "${dec_arr[@]}"; do
    [ -z "$opt" ] && continue
    if ! printf ',%s,' "$current_opts" | grep -qF ",$opt,"; then
      missing_opts="${missing_opts:+$missing_opts,}$opt"
    fi
  done
  if [ -z "$missing_opts" ]; then
    echo "  field '$fname' (SINGLE_SELECT) — options already aligned"
    audit_log info "$DR_AUDIT_CATEGORY" skipped "field: $fname options-aligned" 2>/dev/null || true
    return 0
  fi
  # Union for the mutation payload (additive — preserve user-added options).
  if [ -n "$current_opts" ]; then
    union_opts="$current_opts,$missing_opts"
  else
    union_opts="$missing_opts"
  fi
  # Build the GraphQL singleSelectOptions list literal (enum colors NOT quoted).
  local gql_opts="" first=1 o
  IFS=','
  local -a all_arr=()
  read -ra all_arr <<< "$union_opts"
  IFS="$IFS_save"
  for o in "${all_arr[@]}"; do
    [ -z "$o" ] && continue
    if [ "$first" = 1 ]; then first=0; else gql_opts="$gql_opts, "; fi
    gql_opts="${gql_opts}{name: \"$o\", color: GRAY, description: \"\"}"
  done
  local mutation
  mutation=$(cat <<GQL
mutation {
  updateProjectV2Field(input: {
    fieldId: "$fid",
    singleSelectOptions: [$gql_opts]
  }) { projectV2Field { ... on ProjectV2SingleSelectField { name } } }
}
GQL
)
  if gh api graphql -f query="$mutation" >/dev/null 2>&1; then
    local n_added
    n_added=$(printf '%s' "$missing_opts" | tr ',' '\n' | grep -c .)
    echo "  field '$fname' (SINGLE_SELECT) — $n_added option(s) added"
    audit_log info "$DR_AUDIT_CATEGORY" reconciled "field: $fname options=+$n_added" 2>/dev/null || true
  else
    audit_log warn "$DR_AUDIT_CATEGORY" notice "reconcile-failed: '$fname' graphql-mutation-failed" 2>/dev/null || true
  fi
  return 0
}
