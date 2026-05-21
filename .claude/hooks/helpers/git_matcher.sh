# shellcheck shell=bash
# helpers/git_matcher.sh — shared patterns for git subcommand matching and
# the protected-branch policy. Source from any hook that needs to match git
# subcommands tolerantly OR gate on protected branches.

# PROTECTED_BRANCH_PATTERN is the ERE fragment naming branches the shell
# treats as protected. Used by enforcement matchers (direct push, backmerge)
# inside pre_tool_use.sh. PROTECTED_BRANCH_CASE_GLOB is the case-statement
# form of the same policy. The two forms exist because bash globs and EREs
# are different metacharacter languages — keeping both centralized closes
# the drift surface between push/merge regex matchers and `is_protected_branch`'s
# symbolic-ref check.
#
# Single source of truth for SPEC §6.1 "direct commit/push to protected
# branch" and §6.1 "backmerge blocked". Adding a new protected pattern
# (e.g. `hotfix/*`) is a one-edit change here. The `main master` static
# subset is enumerated by `branch_guard.sh::_protected_static_refs` for
# the detached-HEAD tip-equality check.
#
# Behavior preserved byte-exact against the prior `release/\S+` ERE
# matchers in pre_tool_use.sh: `release/foo` matches, `release/foo bar`
# (whitespace) does not. The legacy `case "$b" in main|master|release/*)`
# in branch_guard.sh was looser — its `*` glob would have matched
# `release/foo bar` too — but git's own check-ref-format rejects branch
# names with whitespace, so that codepath was unreachable in practice
# and the refactor tightens an already-dead case rather than weakening
# enforcement.
# Tightening further (e.g. `release/[^[:space:]/]+`) is a separate concern.
#
# Consumers: pre_tool_use.sh matchers use the ERE form via grep -qE
# interpolation. branch_guard.sh::is_protected_branch uses the ERE
# form via `grep -qE` (subprocess fork, but only 1–3 calls per hook —
# tolerated for SSOT). The case-glob form is currently unused at
# runtime; kept for callers that want a glob-context pattern without
# spawning grep. See alternatives in PR #16.
# shellcheck disable=SC2034  # sourced by every hook that gates on branches
PROTECTED_BRANCH_PATTERN='main|master|release/\S+'
# shellcheck disable=SC2034  # kept for callers wanting a glob-context pattern
PROTECTED_BRANCH_CASE_GLOB='main|master|release/*'

# GIT_PREFIX is an ERE fragment that matches `git` followed by zero or more
# standard git-level options between `git` and the subcommand. Used as a
# prefix in every `git <subcommand>` matcher so the downstream gates fire
# even when the user supplies common option prefixes. See SPEC §6.1
# "Git option-prefix tolerance" for the contract.
#
# Tolerated options (single source of truth):
#   -c <key>=<value>             — per-invocation config
#   -C <path>                    — change directory
#   -p, --paginate               — page output
#   --no-pager                   — suppress pager
#   --git-dir=<path>             — custom .git
#   --work-tree=<path>           — custom work tree
#   --bare                       — bare repo flag
#   --namespace=<ref>            — ref namespace
#   --literal-pathspecs          — literal pathspec matching
#   --icase-pathspecs            — case-insensitive pathspec
#   --no-optional-locks          — skip refresh/index locks
#   --no-replace-objects         — disregard replace refs
#   --no-advice                  — suppress advice hints
#   --exec-path[=<path>]         — git exec path
#   --config-env=<name>=<envvar> — config from env
# shellcheck disable=SC2034  # consumed via interpolation in pre_tool_use.sh
GIT_PREFIX='\bgit(\s+(-c\s+\S+|-C\s+\S+|-p|--paginate|--no-pager|--git-dir=\S+|--work-tree=\S+|--bare|--namespace=\S+|--literal-pathspecs|--icase-pathspecs|--no-optional-locks|--no-replace-objects|--no-advice|--exec-path(=\S+)?|--config-env=\S+))*\s+'
