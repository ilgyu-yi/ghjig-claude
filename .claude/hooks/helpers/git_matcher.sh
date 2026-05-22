# shellcheck shell=bash
# helpers/git_matcher.sh — shared patterns for git subcommand matching and
# the protected-branch policy. Source from any hook that needs to match git
# subcommands tolerantly OR gate on protected branches.

# PROTECTED_BRANCH_PATTERN is the ERE fragment naming branches the shell
# treats as protected. Single source of truth for SPEC §6.1 "direct
# commit/push to protected branch" and "backmerge blocked"; adding a new
# protected pattern (e.g. `hotfix/*`) is a one-edit change here.
#
# Behavior preserved byte-exact against the prior `release/\S+` ERE
# matchers in pre_tool_use.sh: `release/foo` matches, `release/foo bar`
# (whitespace) does not. The legacy `case "$b" in main|master|release/*)`
# in branch_guard.sh was looser — its `*` glob would have matched
# `release/foo bar` — but git's own check-ref-format rejects branch
# names with whitespace, so that codepath was unreachable in practice.
# Tightening further (e.g. `release/[^[:space:]/]+`) is a separate concern.
#
# Consumers: pre_tool_use.sh matchers interpolate the ERE form via
# `grep -qE`; branch_guard.sh::is_protected_branch likewise uses
# `grep -qE` (subprocess fork, 1–3 calls per hook — tolerated for SSOT).
# branch_guard.sh enumerates the `main master` static-name subset
# inline for the detached-HEAD tip-equality check; release/* is matched
# via `git for-each-ref refs/heads/release/*`.
# shellcheck disable=SC2034  # sourced by every hook that gates on branches
PROTECTED_BRANCH_PATTERN='main|master|release/\S+'

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
