#!/usr/bin/env bash
# shellcheck shell=bash
# .claude/hooks/helpers/issue_filer.sh — filer-trust predicate for dir-mode v3.
#
# Used by pre_tool_use.sh's `trusted-filer-mutate` matcher (SPEC §1.5, §6.1)
# to distinguish Issues authored by trusted filers (OWNER / MEMBER /
# MAINTAINER / COLLABORATOR per GitHub's authorAssociation) from untrusted
# filers (CONTRIBUTOR / FIRST_TIME_CONTRIBUTOR / FIRST_TIMER / NONE / bots).
#
# Function:
#   is_trusted_filer <issue#>
#     rc 0 → trusted filer (one of OWNER/MEMBER/MAINTAINER/COLLABORATOR).
#     rc 1 → untrusted filer OR unresolvable. Per SPEC §6.1 fail-open
#            framing, unresolvable cases (gh down, no auth, network error)
#            return 1 to the caller, which fails-open by skipping the
#            extra protection — the underlying action proceeds under the
#            regular attended/unattended mode rules.
#
# Caches per-session at
#   $CLAUDE_ENG_SHELL_ROOT/.claude/state/issue-filer-cache/<owner>__<repo>__<n>
# so a hot loop of matcher invocations doesn't issue an N+1 cascade of
# `gh issue view --json authorAssociation` calls. Cache file content is
# the literal authorAssociation string (e.g., "OWNER", "NONE", "MEMBER")
# for forensic readability. The cache directory is gitignored.
#
# Known limitation (per Directive #92 Notes / brief §11): bot-filed Issues
# (Dependabot, GitHub Actions) carry authorAssociation="NONE" and are
# currently treated as untrusted. If real friction surfaces, a separate
# bot-aware override can be added without changing the trust-tier
# definition.

is_trusted_filer() {
  local issue="$1"
  case "$issue" in
    ''|*[!0-9]*) return 1 ;;
  esac

  : "${CLAUDE_ENG_SHELL_ROOT:?CLAUDE_ENG_SHELL_ROOT must be set}"

  local cache_dir cache_file
  cache_dir="$CLAUDE_ENG_SHELL_ROOT/.claude/state/issue-filer-cache"

  local owner name
  owner=$(gh repo view --json owner -q .owner.login 2>/dev/null) || return 1
  name=$(gh repo view --json name -q .name 2>/dev/null) || return 1
  cache_file="$cache_dir/${owner}__${name}__${issue}"

  # Initialize explicitly: `local assoc` (no value) leaves the var
  # in a "declared-unset" state under bash 5+ with `set -u`, and the
  # `[ -z "$assoc" ]` check below would trigger an unbound-variable
  # exit. macOS bash 3.2 happens to treat `local var` as empty-string
  # by default; ubuntu CI's bash 5.x is strict. Always initialize.
  local assoc=""
  if [ -f "$cache_file" ]; then
    assoc=$(cat "$cache_file" 2>/dev/null) || assoc=""
  fi

  if [ -z "$assoc" ]; then
    assoc=$(gh issue view "$issue" --json authorAssociation -q '.authorAssociation' 2>/dev/null) || return 1
    [ -z "$assoc" ] && return 1
    mkdir -p "$cache_dir" 2>/dev/null || true
    printf '%s\n' "$assoc" > "$cache_file" 2>/dev/null || true
  fi

  case "$assoc" in
    OWNER|MEMBER|MAINTAINER|COLLABORATOR) return 0 ;;
    *) return 1 ;;
  esac
}
