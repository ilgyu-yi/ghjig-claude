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
