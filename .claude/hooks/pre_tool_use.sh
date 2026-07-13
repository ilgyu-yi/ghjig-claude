#!/usr/bin/env bash
set -uo pipefail

SHELL_ROOT="${GHJIG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
[ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0
# Export the resolved root (#312, #537) so helpers that reference $GHJIG_ROOT
# resolve with no global env. Internal/exported-only: the ambient env is never
# consulted here; GHJIG_ROOT_OVERRIDE is a test-only seam (SPEC §3.2.1).
export GHJIG_ROOT="$SHELL_ROOT"

# Primitive bootstrap of the hook runtime (SPEC §6.1). hookrt.sh hosts
# audit_log + safe_source; if absent, stderr-only warn and exit (cannot
# audit-log the absence of the audit-logger).
hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
if [ ! -f "$hookrt" ]; then
  printf '[GHJig-Claude] WARN hookrt-missing: %s not loaded — hook exiting\n' "$hookrt" >&2
  exit 0
fi
# shellcheck source=/dev/null
. "$hookrt"

# Every other helper goes through safe_source — missing → audit warn,
# return 1 → caller short-circuits the matcher arm. SPEC §6.1 table.
safe_source "$SHELL_ROOT/.claude/hooks/helpers/escape.sh"               escape           || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"            out-of-scope     || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/detect_stack.sh"         format           || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/branch_guard.sh"         branch           || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/conventional_commit.sh"  commit-format    || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/secret_scan.sh"          secret           || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"          commit-format    || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"           proposed-protect || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/issue_filer.sh"          trusted-filer-mutate || true

# If cwd_guard.sh wasn't loaded, `in_scope` is undefined → rc=127 → exit 0
# (the matcher would have nothing to guard anyway). safe_source has
# already emitted the helper-missing warn above.
in_scope 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[ -z "$tool" ] && exit 0

block() {
  local cat="$1" msg="$2"
  audit_log block "$cat" deny "$msg"
  printf '%s\n' "$msg" >&2
  exit 2
}

# Scan args of a Bash command for paths outside the registry.
# Shell-aware: tokenizes via python3 `shlex.split` so quoted paths with spaces
# stay intact and literal globs (`*`) are not pathname-expanded. Falls back to
# `set -f` + `read -ra` when python3 is absent — quoting is lost in that
# fallback, but globbing is still disabled and out-of-scope paths still block
# (the corrupted token does not prefix-match any registry entry).
check_destructive_args() {
  local cmd="$1"
  local arg
  local -a args=()
  if command -v python3 >/dev/null 2>&1; then
    local tok_out
    if ! tok_out=$(printf '%s' "$cmd" | python3 -c '
import shlex, sys
try:
    for t in shlex.split(sys.stdin.read()):
        print(t)
except ValueError:
    sys.exit(2)
' 2>/dev/null); then
      # shlex parse failed (unclosed quote, dangling backslash). Fail closed —
      # we cannot reason about which paths the command would have touched.
      return 1
    fi
    local tok
    while IFS= read -r tok; do
      [ -n "$tok" ] && args+=("$tok")
    done <<< "$tok_out"
  else
    local _opts=$-
    set -f
    read -ra args <<< "$cmd"
    case "$_opts" in *f*) ;; *) set +f ;; esac
  fi

  # #555 A5: skip the verb/wrapper words (rm|mv|cp|sudo|doas|time|env) ONLY when
  # they sit in COMMAND position (the leading wrapper→verb prefix). Pre-fix the
  # skip fired on ANY token equal to one of those words regardless of position,
  # so an OPERAND literally named `env`/`time`/etc. (`mv <in-scope> env`) skipped
  # path_in_scope entirely → a bypass. `at_cmd` stays true across leading wrappers
  # (sudo/doas/time/env) and drops the moment the destructive verb (rm/mv/cp) — or
  # any other first word — is seen, so every subsequent operand is scope-checked.
  local at_cmd=1
  for arg in "${args[@]}"; do
    case "$arg" in
      -*) continue ;;
    esac
    if [ -n "$at_cmd" ]; then
      case "$arg" in
        rm|mv|cp) at_cmd=; continue ;;            # destructive verb → operands follow
        sudo|doas|time|env) continue ;;           # leading wrapper → still command position
      esac
      at_cmd=   # any other leading word is the command; operands follow
    fi
    case "$arg" in
      '$HOME'|'$HOME'/*) arg="${HOME}${arg#'$HOME'}" ;;
      '${HOME}'|'${HOME}'/*) arg="${HOME}${arg#'${HOME}'}" ;;
      \~|\~/*) arg="${HOME}${arg#\~}" ;;
    esac
    path_in_scope "$arg" || return 1
  done
  return 0
}

case "$tool" in
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    [ -z "$cmd" ] && exit 0

    # Keep the raw command (with newlines) for matchers that need multi-line
    # context — currently extract_commit_subject for the heredoc -m form.
    raw_cmd="$cmd"

    # Parse the SPEC §7 TRAILING-sentinel escape (`# ghjig:skip=<cat>
    # reason=<why>`) from the RAW command before normalization (#206). This is
    # the in-harness escape: the live Bash tool consumes a leading VAR= prefix
    # (handled by parse_env_prefix below) before it reaches tool_input.command,
    # but a trailing #-comment survives. Must run pre-normalization — the tr/sed
    # + shlex below would mangle the `#`. On match it exports SKIP_HOOKS/
    # SKIP_REASON and strips the sentinel from raw_cmd; rebase cmd on the
    # stripped raw_cmd so the reason text can't bleed into a matcher. A leading
    # env-prefix (parse_env_prefix, below) runs after and wins if both present.
    parse_skip_sentinel "$raw_cmd" raw_cmd
    cmd="$raw_cmd"

    # Bind the file-token escape channel (#479) to THIS command: should_skip's
    # token reader honors a token only when its cmd_fingerprint is a substring
    # of $ESCAPE_BIND_CMD. Set only here on the Bash path — the Edit/Write arm
    # has no command string, so the channel is Bash-only by design (SPEC §7).
    export ESCAPE_BIND_CMD="$raw_cmd"

    # Normalize multiline backslash-continuation and stray newlines so the
    # matchers see a single logical command. Collapse `\\\n` first, then
    # remaining newlines, then runs of whitespace. See SPEC §6.1
    # "Implementation note" for the framing.
    cmd=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -E 's/\\[[:space:]]+/ /g; s/[[:space:]]+/ /g')

    # Re-separate a glued unquoted command separator (`&&`/`||`/`;`/`|`) into a
    # space-padded boundary, BEFORE parse_env_prefix's shlex round-trip below
    # (#446). A separator glued to an adjacent token — `commit -m "x"&&git push`
    # — would otherwise fold into one shlex token (`'x&&git'`), destroying the
    # following `git push` verb every downstream arm's entry-grep keys on → a
    # false-negative on the irreversible force-push/protected gate (SPEC §6.0
    # P1). Quote-aware: an operator INSIDE a quoted `-m`/`--message` value is
    # data (composes with the #440 elision) and is never re-separated — so no
    # boundary is invented. See git_matcher.sh::space_glued_separators.
    space_glued_separators "$cmd" cmd

    # Parse the SPEC §7 escape-hatch env-prefix (SKIP_HOOKS=, SKIP_REASON=,
    # etc.) out of the cmd string, export it into this shell, and strip the
    # prefix tokens before downstream matchers run. Claude Code's hook
    # subprocess does not inherit env-prefixes from the user's cmd, so
    # without this parse the documented escape hatch silently no-ops.
    parse_env_prefix "$cmd" cmd

    # Bypass-suspect patterns — eval / bash -c / sh -c / python -c /
    # heredoc-spawned shells. Don't block (hooks aren't a sandbox; see
    # §6.1 framing) and **don't short-circuit** the downstream matchers —
    # emit a warn entry so the trail exists, then continue. This means
    # `eval "git push --force"` still gets blocked by the force-push
    # matcher on the literal substring, while plain `eval "ls"` warns
    # and proceeds.
    # Heredoc branch is scoped to *shell-spawning* heredocs per SPEC §6.1
    # ("heredoc-spawned shells (bash <<EOF)") — a shell verb (bash/sh/zsh,
    # optionally /path/-prefixed or env-wrapped, with short flags) in command
    # position governing `<<`. So `bash <<EOF`, `env bash <<EOF`, `/bin/bash
    # <<EOF` warn, while benign data heredocs do NOT — incl. a `.sh`/`.zsh`
    # *operand* (`cat foo.sh <<EOF`), since only the verb + short flags may sit
    # between it and `<<`. Excludes `<<<` here-strings (delimiter check). Residual
    # under-warn: a shell reached via a *non-space* adjacency (backtick, `>`, tab)
    # — warn-only matcher, so an under-warn costs an audit line, not a gate (§6.0).
    if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(eval|bash[[:space:]]+-c|sh[[:space:]]+-c|python[[:space:]]*[0-9.]*[[:space:]]+-c)([^[:alnum:]_]|$)' \
       || printf '%s' "$cmd" | grep -qE '(^| |;|\||&|\(|\{)(env )?(/[^ ]*/)?(bash|sh|zsh)( -[A-Za-z]+)* *['\''"]*<<-?[[:space:]]*['\''"]*[A-Za-z_]'; then
      decided=
      audit_log warn bypass-suspect notice "$cmd"
      decided=1
      # Tail no-op for an always-emits matcher; the pass_through_trace symbol
      # is kept so the §39b structural sweep sees the uniform shape across
      # all matchers (SPEC §6.1 invariant safety net).
      [ -z "$decided" ] && pass_through_trace bypass-suspect "$cmd"
    fi

    # Destructive command with out-of-scope path arg. Entry pre-filter: an
    # rm/mv/cp verb followed — ANYWHERE in its own argument run — by a force OR
    # recursive flag in any surface form: clustered (-rf), separated (-r -f),
    # long (--force/--recursive), non-first (-i -rf), AND **after operands**
    # (`rm <path> -rf`, valid GNU syntax — the #277 bypass the old
    # flag-must-precede-operands regex missed). The `([^;|&]*\s)?` segment spans
    # operands between the verb and the flag but **stops at a pipeline boundary**
    # (`;` `|` `&`), so a flag belonging to ANOTHER pipeline command does not
    # trigger this arm (#212 cross-command anchoring preserved). The trailing
    # `(\s|$)` + leading `\s` keep the flag a whole token (a `-rf` inside a
    # filename like `my-rf-file` is not matched). Over-entry is harmless:
    # check_destructive_args makes the real in-scope/out-of-scope decision and
    # already inspects every operand regardless of flag position.
    # #555 A3: the flagless second arm skips an optional leading `--` end-of-options
    # marker before the operand test, so `mv -- <src> <out-of-registry>` (POSIX
    # `--` guard) still ENTERS check_destructive_args instead of evading both arms
    # (the raw `[^-...]` after `mv ` saw the `--` and bailed). check_destructive_args
    # treats `--` as a flag (skipped) and scope-checks every operand, so an all-in-
    # scope `mv -- a b` still passes — the change only widens ENTRY (tightens the gate).
    if printf '%s' "$cmd" | grep -qE '\b(rm|mv|cp)\s+([^;|&]*\s)?(-[A-Za-z]*[fFrR][A-Za-z]*|--force|--recursive)(\s|$)' \
       || printf '%s' "$cmd" | grep -qE '\b(mv|cp)\s+(--\s+)?[^-;|&[:space:]]'; then
      # #505: the second arm enters check_destructive_args for a FLAGLESS mv/cp
      # that has an operand — a flagless `mv in /out` clobbers an out-of-registry
      # DEST yet carries no force/recursive flag, so the first (flag-keyed) arm
      # missed it. check_destructive_args inspects EVERY operand (incl. the dest),
      # so an all-in-scope mv/cp still passes; `rm` is intentionally NOT broadened
      # (an unforced single-file rm stays un-gated, #212).
      decided=
      if ! check_destructive_args "$cmd"; then
        should_skip out-of-scope && decided=1 || block out-of-scope "destructive command points outside registry: $cmd"
      else
        # In-scope rm/mv/cp -f is the common happy path (`rm -rf ./node_modules`).
        # No audit emission needed; mark_allow satisfies the invariant via flag.
        mark_allow out-of-scope
      fi
      [ -z "$decided" ] && pass_through_trace out-of-scope "$cmd"
    fi
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}reset\s+--hard\b"; then
      decided=
      # #555 A2: refine — message-strip raw_cmd so a `git reset --hard` mentioned
      # only inside a -m/-F commit MESSAGE (data) doesn't false-block; a real
      # invocation still blocks. `message` mode elides only the message-flag VALUE
      # and never a real command verb, so this can't under-block (parity with the
      # force-push/protected-push arms that already elide via strip_command_data …
      # message). grep-count into a var (a refining conditional grep would be
      # mis-read by the §39b matcher-entry awk). Fail-closed: strip → raw on failure.
      gr_hit=$(printf '%s' "$(strip_command_data "$raw_cmd" message)" | grep -cE "${GIT_PREFIX}reset\s+--hard\b")
      if [ "${gr_hit:-0}" -gt 0 ]; then
        should_skip destructive && decided=1 || block destructive "git reset --hard blocked"
      else
        decided=1   # reset --hard only inside a commit-message value → allow (silent)
      fi
      [ -z "$decided" ] && pass_through_trace destructive "$cmd"
    fi
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}clean\s+-[A-Za-z]*f"; then
      decided=
      # #366: refine — heredoc-strip raw_cmd so a `git clean -f` mentioned only
      # inside a heredoc body (data) doesn't false-trip; a real invocation still
      # blocks. Heredoc-only (parity with the push arm): a real -f flag is never
      # inside a heredoc body, so this can't under-block. The hit is computed into
      # a var via grep-count (a refining conditional grep would be mis-read by the
      # §39b matcher-entry awk). Fail-closed via strip_command_data (raw on fail).
      # #555 A2: `message`-mode strip (⊇ heredoc) — also elides a -m/-F commit
      # MESSAGE value so a `git clean -f` documented inside a commit message
      # doesn't false-block; a real -f flag is never a message value, so this
      # can't under-block. Fail-closed via strip_command_data (raw on failure).
      gc_hit=$(printf '%s' "$(strip_command_data "$raw_cmd" message)" | grep -cE "${GIT_PREFIX}clean\s+-[A-Za-z]*f")
      if [ "${gc_hit:-0}" -gt 0 ]; then
        should_skip destructive && decided=1 || block destructive "git clean -f blocked"
      else
        decided=1   # clean -f only inside heredoc data → allow (silent)
      fi
      [ -z "$decided" ] && pass_through_trace destructive "$cmd"
    fi

    # Backmerge: `git merge <protected>` (optionally prefixed with
    # `origin/` or `upstream/`) while NOT currently on a protected
    # branch. The recommended motion when the base advances is the
    # rebase pull form (SPEC §13). See §6.1 row.
    #
    # The matcher tolerates intermediate option tokens (e.g.
    # `--no-ff`, `--no-edit`, `-m "msg"`, `--strategy=ours`) between
    # `merge` and the ref. `(\s+\S+)*` consumes them; backtracking
    # then aligns to the final protected-ref token. `(\s|$)` anchors
    # the ref end so substring-like names (`mainframe`, `master-key`)
    # don't false-positive. The remote-prefix is pinned to `origin/`
    # / `upstream/` so a feature branch named `feature/main` doesn't
    # match (the loose `\S+/` form would have swallowed `feature/`).
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}merge(\s+\S+)*\s+((origin|upstream)/)?(${PROTECTED_BRANCH_PATTERN})(\s|$)"; then
      decided=
      if ! is_protected_branch; then
        should_skip backmerge && decided=1 \
          || block backmerge "backmerge blocked — use 'git pull --rebase origin <base>' instead (or SKIP_HOOKS=backmerge for exceptional cases)"
      else
        # On a protected branch, `git merge <base>` is the local-merge-of-a-PR
        # path explicitly allowed by SPEC §6.1. Happy path; no audit emission.
        mark_allow backmerge
      fi
      [ -z "$decided" ] && pass_through_trace backmerge "$cmd"
    fi

    # gh pr merge — block when a linked issue (closingIssuesReferences) has
    # unchecked AC items and no `^## AC closeout` header comment yet.
    # SPEC §6.1 'ac-closeout' row; helper scripts/ac_closeout.sh satisfies
    # by construction; /ship step 7.6 runs it automatically. Fail-open
    # (audit warn) on indeterminate state per SPEC §6.1 framing.
    # Anchored end (\s|$) so future `gh pr merge-queue` or similar
    # subcommands don't false-positive — `\b` alone would have matched
    # `merge-queue` because `-` is a non-word boundary. Matches the
    # backmerge matcher's anchor style at line 142.
    # #499: tolerate a leading gh GLOBAL-FLAG run (`gh --repo o/r pr merge`,
    # `gh -R o/r …`, `gh --repo=o/r …`) so a global flag before the subcommand
    # can't bypass the gate. Each leading token is `-X`/`--xxx[=val]` with an
    # optional non-flag value (`o/r`); `pr merge` must stay ADJACENT after the
    # run, so the word `merge` buried in a `pr create` body/title still misses.
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge([[:space:]]|$)'; then
      decided=
      if should_skip ac-closeout; then
        decided=1
      else
        # ac_closeout_gate.sh is matcher-scoped (only sourced on the
        # `gh pr merge` path), so the safe_source call lives here, not
        # at file top. If safe_source returns 1 (helper missing) it has
        # already emitted the helper-missing warn — short-circuit out.
        if safe_source "$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh" ac-closeout; then
          # #340: refine the coarse substring grep — `gh pr merge` appearing only
          # as DATA (a heredoc body, a quoted `--body`/`-m` value, a commit
          # message) is not a merge command, so the gate must not engage. raw_cmd
          # (pre-normalization) keeps the heredoc newlines that line ~125's
          # `tr '\n' ' '` would erase. Fail-closed: is_pr_merge_command returns
          # is-merge on python3 absence / parse uncertainty, so a real merge is
          # never let by; the executed-quoted-string form is a documented residual.
          if command -v is_pr_merge_command >/dev/null 2>&1 && ! is_pr_merge_command "$raw_cmd"; then
            mark_allow ac-closeout
            decided=1
          else
            ac_pr=$(extract_pr_from_merge_cmd "$cmd" || true)
            if [ -z "$ac_pr" ] && command -v gh >/dev/null 2>&1; then
              ac_pr=$(gh pr view --json number -q .number 2>/dev/null || true)
            fi
            if [ -n "$ac_pr" ]; then
              pr_needs_closeout "$ac_pr"
              ac_rc=$?
              case "$ac_rc" in
                0)
                  # Type-awareness (SPEC §1.7, §6.1) — if the linked closing issue
                  # is a Directive, the AC-closeout gate doesn't apply (Directives
                  # close via /complete-directive + activation-reviewer, not by AC
                  # checkboxes). Skip the block, info-log, and let merge proceed.
                  ac_directive_skip=
                  if command -v is_directive_issue >/dev/null 2>&1; then
                    ac_closing=$(gh pr view "$ac_pr" --json closingIssuesReferences \
                      -q '[.closingIssuesReferences[].number] | join(" ")' 2>/dev/null || true)
                    if [ -n "$ac_closing" ]; then
                      ac_all_directive=1
                      for ac_iss in $ac_closing; do
                        if ! is_directive_issue "$ac_iss"; then
                          ac_all_directive=0
                          break
                        fi
                      done
                      if [ "$ac_all_directive" = 1 ]; then
                        audit_log info ac-closeout notice "all closing issues are Type=Directive; skipping AC-closeout per §1.7 Type-awareness"
                        ac_directive_skip=1
                        decided=1
                      fi
                    fi
                  fi
                  [ -z "$ac_directive_skip" ] && block ac-closeout "linked issue has unchecked AC and no '## AC closeout' marker comment. Run: scripts/ac_closeout.sh $ac_pr (idempotent). Or SKIP_HOOKS=ac-closeout SKIP_REASON='<why>' for legitimate edge cases."
                  ;;
                1) mark_allow ac-closeout; decided=1 ;;
                2) audit_log warn ac-closeout notice "indeterminate (gh timeout / missing / malformed); merge allowed per fail-open"; decided=1 ;;
              esac
            else
              audit_log warn ac-closeout notice "could not resolve PR number from cmd or current branch; merge allowed per fail-open"
              decided=1
            fi
          fi
        else
          # safe_source emitted helper-missing warn already
          decided=1
        fi
      fi
      [ -z "$decided" ] && pass_through_trace ac-closeout "$cmd"
    fi

    # merge-strategy (#288) — enforce SPEC §5.7.1: `gh pr merge` to the DEFAULT
    # branch must be `--merge` (no-ff merge commit) so the Doc→Test→Code arc is
    # preserved on the trunk (§1.2). squash/rebase/bare → block; `--merge` →
    # allow; any strategy when base != default branch → allow (topic-branch
    # consolidation, §10.5). Independent of the ac-closeout arm above (own
    # `should_skip` category; both fire on `gh pr merge`, each decides on its own).
    # #499: same leading global-flag-run widening as the ac-closeout anchor above
    # (`pr merge` must stay ADJACENT after the run so a `pr create` body whose
    # text contains `merge` is not over-blocked).
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge([[:space:]]|$)'; then
      decided=
      # Strategy + PR via a gh-flag-aware token walk (parse_gh_merge_argv, #290):
      # strategy is the explicit flag token (so `--merge` inside a --body value
      # isn't read as the strategy, and short -m/-s/-r are recognized), PR is the
      # first positional (or pull-URL), skipping value-flag values. Done up front
      # (not via an `if printf…grep` arm, which the §39b structural awk would
      # mis-read as a second matcher entry). safe_source-scoped, like ac-closeout.
      ms_strategy=bare ; ms_pr= ; ms_is_merge=1
      if safe_source "$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh" merge-strategy; then
        # #340: same command-word refinement as ac-closeout — `gh pr merge` text
        # inside a heredoc body / quoted literal / commit message is data, not a
        # merge. raw_cmd keeps heredoc newlines; fail-closed (is-merge) on any
        # parse uncertainty, so a real merge is never let past this gate either.
        if command -v is_pr_merge_command >/dev/null 2>&1 && ! is_pr_merge_command "$raw_cmd"; then
          ms_is_merge=0
        fi
        ms_parsed=$(parse_gh_merge_argv "$cmd")
        ms_strategy=${ms_parsed%%	*}
        ms_pr=${ms_parsed#*	}
      fi
      if should_skip merge-strategy; then
        decided=1
      elif [ "$ms_is_merge" = 0 ]; then
        # #340: `gh pr merge` appears only as data — not a merge command.
        mark_allow merge-strategy
        decided=1
      # An explicit `--merge` is allowed SILENTLY with no base resolution — keeps
      # the §39d "silent on --merge" invariant and skips gh calls on the happy path.
      elif [ "$ms_strategy" = merge ]; then
        mark_allow merge-strategy
        decided=1
      else
        # Non-`--merge` strategy (squash / rebase / bare). Resolve the PR base and
        # the repo default branch; block only when base == default. Bounded gh via
        # _ac_run_gh (timeout 5, macOS-safe). Fail-open if either is unresolvable.
        ms_base= ; ms_default=
        if command -v _ac_run_gh >/dev/null 2>&1; then
          if [ -n "$ms_pr" ]; then
            ms_base=$(_ac_run_gh pr view "$ms_pr" --json baseRefName -q .baseRefName 2>/dev/null || true)
          else
            ms_base=$(_ac_run_gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)
          fi
          ms_default=$(_ac_run_gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
        fi
        if [ -z "$ms_base" ] || [ -z "$ms_default" ]; then
          audit_log warn merge-strategy notice "base/default-branch unresolved — allowing (fail-open, §6.1)"
          decided=1
        elif [ "$ms_base" = "$ms_default" ]; then
          block merge-strategy "Merge to the default branch '${ms_default}' must use --merge (no-ff merge commit) to preserve the Doc→Test→Code arc on the trunk (SPEC §5.7.1). Re-run: gh pr merge ${ms_pr:-<pr>} --merge --delete-branch. squash/rebase are allowed only on a non-default base (topic-branch consolidation, §10.5). Or SKIP_HOOKS=merge-strategy SKIP_REASON='<why>' for a sanctioned exception."
        else
          mark_allow merge-strategy
          decided=1
        fi
      fi
      [ -z "$decided" ] && pass_through_trace merge-strategy "$cmd"
    fi

    # push-parity (#244) — block `gh pr merge` when the local branch is STRICTLY
    # AHEAD of its pushed remote-tracking head (unpushed local commits the merge
    # would silently leave behind). git-only + zero-network (local_ahead_of_pr
    # reads refs/remotes/origin — NO gh call), positive detection: behind /
    # diverged / no-upstream / detached / absent-local all ALLOW. Independent
    # matcher (own `should_skip` category); composes with ac-closeout +
    # merge-strategy on the same `gh pr merge`, decides on its own. SPEC §6.1
    # 'push-parity' row, §5.7. Same leading-global-flag-run anchor as above.
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge([[:space:]]|$)'; then
      decided=
      if should_skip push-parity; then
        decided=1
      elif safe_source "$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh" push-parity; then
        # #340 data-refine: `gh pr merge` appearing only as data (heredoc body /
        # quoted value / commit message) is not a merge command → allow.
        if command -v is_pr_merge_command >/dev/null 2>&1 && ! is_pr_merge_command "$raw_cmd"; then
          mark_allow push-parity
          decided=1
        else
          pp_branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)  # empty ⇒ detached ⇒ allow
          if command -v local_ahead_of_pr >/dev/null 2>&1 && local_ahead_of_pr "$pp_branch"; then
            block push-parity "unpushed local commits on '${pp_branch}' would be left behind by this merge — push your local commits first: git push, then re-run the merge. Or SKIP_HOOKS=push-parity SKIP_REASON='<why>' for a sanctioned exception."
          else
            mark_allow push-parity
            decided=1
          fi
        fi
      else
        # safe_source emitted the push-parity helper-missing warn already.
        decided=1
      fi
      [ -z "$decided" ] && pass_through_trace push-parity "$cmd"
    fi

    # merge-review (#586, #585, #543 — REPLACES the retired merge-attestation
    # file arm, #246/#544) — block a `gh pr merge` lacking a passing GitHub
    # review PINNED TO THE CURRENT HEAD. Governed by the review-gate toggle
    # (§5.7.1): `bypass` → allow + a LOUD `audit_log warn merge-review bypass`;
    # `required` (default) → review_gate_accepts decides (native APPROVED@head,
    # or a self verdict=approve marker@head where author==PR-author==merger).
    # FAIL-CLOSED (block) on any lookup failure — unresolvable PR/head, gh
    # error/timeout/down, malformed JSON, safe_source helper miss — the
    # deliberate divergence from the retired arm's fail-open staleness leg (the
    # safe direction for a merge integrity gate is to REQUIRE a review, §5.7.1).
    # Independent matcher (own `should_skip` category); same entry anchor +
    # is_pr_merge_command refine + extract_pr_from_merge_cmd PR resolution as the
    # sibling gh-pr-merge arms. SPEC §6.1 'merge-review' row, §5.7.1 toggle.
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge([[:space:]]|$)'; then
      decided=
      if should_skip merge-review; then
        decided=1
      elif safe_source "$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh" merge-review; then
        if command -v is_pr_merge_command >/dev/null 2>&1 && ! is_pr_merge_command "$raw_cmd"; then
          mark_allow merge-review
          decided=1
        else
          # Resolve the review-gate toggle (resolve_review_gate lives in
          # ship_mode.sh; safe_source it. A helper miss fails CLOSED for THIS
          # arm — keep the default `required`, never open the gate silently).
          mr_gate=required
          if safe_source "$SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh" merge-review \
             && command -v resolve_review_gate >/dev/null 2>&1; then
            mr_gate=$(resolve_review_gate)
          fi
          if [ "$mr_gate" = bypass ]; then
            # Bypass backstop (#592): the static permissions.allow entry is no
            # longer the SOLE guard for the covered ship form. Under bypass the
            # gate self-skips (LOUD audit, no gh calls) for every form EXCEPT the
            # exact covered ship form (`gh pr merge --auto --merge --delete-branch`)
            # driven as an AGENT SELF-MERGE (PR author == merger) — that one still
            # BLOCKS, and a covered form whose author/merger lookup is
            # INDETERMINATE (gh error/timeout/down) fails CLOSED (mirrors the
            # required arm's §5.7.1 posture). Human covered-form merges and every
            # non-covered form stay allowed + loudly audited.
            if ! command -v is_covered_ship_merge_form >/dev/null 2>&1; then
              # Backstop form-classifier helper missing → cannot rule out a covered
              # agent self-merge → fail CLOSED, symmetric with the merge_is_self-miss
              # leg below (a whole-file safe_source miss already blocks upstream; this
              # guards the stale-but-sourceable-file edge, #592).
              block merge-review "merge-review: the bypass covered-form backstop helper (is_covered_ship_merge_form) is unavailable — failing closed under review-gate=bypass, cannot rule out a covered agent self-merge (#592). SKIP_HOOKS=merge-review SKIP_REASON='<why>' for a sanctioned exception."
            elif is_covered_ship_merge_form "$cmd"; then
              mr_pr=$(extract_pr_from_merge_cmd "$cmd" || true)
              if [ -z "$mr_pr" ] && command -v gh >/dev/null 2>&1; then
                mr_pr=$(gh pr view --json number -q .number 2>/dev/null || true)
              fi
              if command -v merge_is_self >/dev/null 2>&1; then
                merge_is_self "$mr_pr"; mr_self_rc=$?
              else
                mr_self_rc=2   # helper miss → indeterminate → fail closed
              fi
              if [ "$mr_self_rc" = 1 ]; then
                # author != merger → a human ship of the covered form → allow.
                audit_log warn merge-review bypass "review-gate=bypass — covered ship form admitted as a human merge (author != merger); no head-pinned review (§5.7.1, #592)"
                mark_allow merge-review
                decided=1
              else
                # self-merge (0) OR indeterminate lookup (2) → BLOCK even under
                # bypass. Single deny record (block emits it); no extra audit_log.
                block merge-review "merge-review: the covered ship form (\`gh pr merge --auto --merge --delete-branch\`) as an agent self-merge is blocked even under review-gate=bypass (#592) — the static allow is not the sole guard: PR author == merger, or the author/merger lookup failed and the gate fails closed. Have a human merge, post a head-pinned review via /file-review, or SKIP_HOOKS=merge-review SKIP_REASON='<why>' for a sanctioned exception."
              fi
            else
              # Non-covered form under bypass: skip the gate, but LOUDLY audit every
              # bypass merge (§5.7.1) so a standing bypass never goes unobserved.
              audit_log warn merge-review bypass "review-gate=bypass — merge admitted with no head-pinned review (§5.7.1)"
              mark_allow merge-review
              decided=1
            fi
          else
            mr_pr=$(extract_pr_from_merge_cmd "$cmd" || true)
            if [ -z "$mr_pr" ] && command -v gh >/dev/null 2>&1; then
              mr_pr=$(gh pr view --json number -q .number 2>/dev/null || true)
            fi
            mr_head=
            if [ -n "$mr_pr" ] && command -v _ac_run_gh >/dev/null 2>&1; then
              mr_head=$(_ac_run_gh pr view "$mr_pr" --json headRefOid -q .headRefOid 2>/dev/null || true)
            fi
            if [ -z "$mr_pr" ] || [ -z "$mr_head" ]; then
              # PR / head unresolvable (gh error/timeout/down, or no PR) → the
              # gate fails CLOSED (block), never fail-open (§5.7.1).
              block merge-review "merge-review: could not resolve the PR number and current head for this merge (gh error/timeout, or no PR resolvable) — the gate fails closed. Confirm the PR exists and gh is reachable, then re-run. Or SKIP_HOOKS=merge-review SKIP_REASON='<why>' for a sanctioned exception."
            elif command -v review_gate_accepts >/dev/null 2>&1 && review_gate_accepts "$mr_pr" "$mr_head"; then
              mark_allow merge-review
              decided=1
            else
              block merge-review "no passing GitHub review pinned to PR #${mr_pr}'s current head — a skipped review, a stale-head review, an outstanding CHANGES_REQUESTED, or a marker verdict=block blocks this merge (SPEC §6.1). Post a head-pinned review via /file-review, then re-run. Or set .claude/state/review-gate=bypass (loudly audited, §5.7.1), or SKIP_HOOKS=merge-review SKIP_REASON='<why>'."
            fi
          fi
        fi
      else
        # safe_source could not load the gate helper — the merge-review arm is
        # the deliberate exception to the sibling arms' fail-OPEN posture: it
        # fails CLOSED (block) on a helper miss too (SPEC §5.7.1, §1732).
        block merge-review "merge-review: gate helper (ac_closeout_gate.sh) unavailable — the gate fails closed (SPEC §5.7.1). Or SKIP_HOOKS=merge-review SKIP_REASON='<why>' for a sanctioned exception."
      fi
      [ -z "$decided" ] && pass_through_trace merge-review "$cmd"
    fi

    # merge-completeness (#548) — INDEPENDENT advisory arm, WARN-ONLY, sequenced
    # immediately after merge-review on the SAME `gh pr merge` entry grep. The
    # positive-completeness face of the #544 merge gate: on a `feat`/`fix` PR
    # whose merge diff touches ZERO source files (non-empty file list, every path
    # test/doc per the reused `.shellsecretignore` classifier) it emits an
    # `audit_log warn merge-completeness` record + a one-line stderr notice and
    # ALLOWS. PR type resolves from headRefName (`<user>/(feat|fix)/…`) with a
    # PR-title conventional-commit fallback; one bounded `gh pr view --json
    # headRefName,title,files` (merge_completeness_probe) feeds both type + file
    # list. It NEVER blocks and has NO skip category — fail-open throughout (PR
    # unresolvable / gh down / empty JSON / empty list / helper miss → no warn,
    # allow). Runs only when every block arm above already allowed. SPEC §6.1
    # 'merge-completeness' row.
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge([[:space:]]|$)'; then
      decided=
      if safe_source "$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh" merge-completeness; then
        if command -v is_pr_merge_command >/dev/null 2>&1 && ! is_pr_merge_command "$raw_cmd"; then
          mark_allow merge-completeness
          decided=1
        else
          mc_pr=$(extract_pr_from_merge_cmd "$cmd" || true)
          if [ -z "$mc_pr" ] && command -v gh >/dev/null 2>&1; then
            mc_pr=$(gh pr view --json number -q .number 2>/dev/null || true)
          fi
          if [ -z "$mc_pr" ]; then
            # PR unresolvable → no key for the advisory; fail-open allow, no warn.
            mark_allow merge-completeness
            decided=1
          else
            mc_probe=$(merge_completeness_probe "$mc_pr" 2>/dev/null || true)
            mc_type=${mc_probe%%$'\t'*}
            mc_zero=${mc_probe#*$'\t'}
            if { [ "$mc_type" = feat ] || [ "$mc_type" = fix ]; } && [ "$mc_zero" = 1 ]; then
              audit_log warn merge-completeness advisory "PR #${mc_pr} (${mc_type}) merge diff touches zero source files (all test/doc) — verify the implementation reached the PR head before merging (advisory, never blocks, §6.1)"
              printf '[GHJig-Claude] merge-completeness: PR #%s (%s) merge diff is test/doc-only — no source file changed; confirm the implementation is on the PR head before merging.\n' "$mc_pr" "$mc_type" >&2
            fi
            # Every path here allows — advisory arm never blocks.
            mark_allow merge-completeness
            decided=1
          fi
        fi
      else
        # safe_source emitted the merge-completeness helper-missing warn already.
        decided=1
      fi
      [ -z "$decided" ] && pass_through_trace merge-completeness "$cmd"
    fi

    # proposed-protect — block branch-creation referencing an Issue that is not
    # yet a branchable Execution Issue (SPEC §1.7, §6.1, §10.5). Generalized from
    # directive-protect (#171): block when the target Issue is EITHER
    # status:proposed (any type — not-yet-activated; run /activate first) OR a
    # Directive (any status — Directives never branch; use /file-issue --parent).
    # Subsumes the old Directive-only check: a status-only check would let an
    # Active Directive branch — a §10.5 regression. The branch-name convention
    # <user>/<type>/<N>-<slug> (CLAUDE.md / SPEC §10.1) encodes the issue number;
    # extract <N> and evaluate both predicates. Each predicate fails open
    # independently (gh down / no auth / undefined function → that arm does not
    # block) per SPEC §6.1.
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}checkout[[:space:]]+-b[[:space:]]+[A-Za-z0-9._-]+/[a-z]+/[0-9]+-"; then
      decided=
      if should_skip proposed-protect; then
        decided=1
      else
        # Extract the issue number via bash builtin regex. GIT_PREFIX uses
        # PCRE-style \b/\s/\S that sed -E (BSD/macOS) doesn't support; bash
        # =~ uses POSIX ERE which is fine for this branch-name shape.
        pp_issue=
        if [[ "$cmd" =~ checkout[[:space:]]+-b[[:space:]]+[A-Za-z0-9._-]+/[a-z]+/([0-9]+)- ]]; then
          pp_issue="${BASH_REMATCH[1]}"
        fi
        pp_is_proposed=
        pp_is_directive=
        if [ -n "$pp_issue" ]; then
          if command -v is_proposed_issue >/dev/null 2>&1 && is_proposed_issue "$pp_issue"; then
            pp_is_proposed=1
          fi
          if command -v is_directive_issue >/dev/null 2>&1 && is_directive_issue "$pp_issue"; then
            pp_is_directive=1
          fi
        fi
        if [ -n "$pp_is_proposed" ]; then
          # status:proposed arm wins on overlap (proposed Directive) — activation
          # is the next legitimate action regardless of type.
          block proposed-protect "Issue #${pp_issue} is status:proposed — Issue-ops only, not yet actionable. Run /activate ${pp_issue} (once available) to validate it before branching. Or SKIP_HOOKS=proposed-protect SKIP_REASON='<why>' for legitimate edge cases."
        elif [ -n "$pp_is_directive" ]; then
          block proposed-protect "Issue #${pp_issue} is a Directive (Type=Directive, SPEC §1.7/§10.5). Directives do not branch into engineering PRs — the Directive scopes the work, Execution Issues do it. Use /file-issue --parent ${pp_issue}. Or SKIP_HOOKS=proposed-protect SKIP_REASON='<why>' for legitimate edge cases."
        else
          # Neither proposed nor a Directive, or predicates unresolvable
          # (gh down, no auth, helper/function missing) — fail-open per SPEC §6.1.
          mark_allow proposed-protect
          decided=1
        fi
      fi
      [ -z "$decided" ] && pass_through_trace proposed-protect "$cmd"
    fi

    # trusted-filer-mutate — block close / declassify mutations against
    # Issues authored by trusted filers (OWNER / MEMBER / MAINTAINER /
    # COLLABORATOR per GitHub's authorAssociation). Mode-independent layer
    # above attended/unattended per SPEC §1.5 (filer-aware invariants).
    # Two sub-arms:
    #   a) `gh issue close <N>` without `--reason completed` AND on a
    #      trusted-filer Issue → block (close-as-not-planned and
    #      close-as-duplicate are the harmful cases the invariant guards
    #      against). Allowed: `--reason completed` regardless of filer.
    #   b) `gh issue edit <N> --remove-label directive` on ANY Issue →
    #      block (de-classifying a Directive bypasses dir-mode review
    #      and should always require human confirm).
    # Both arms escape via `SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='<why>'`.
    # Fail-open if is_trusted_filer is unavailable or can't resolve (gh
    # down, no auth) — the underlying action proceeds under the existing
    # attended/unattended rules.
    # #499: tolerate a leading gh global-flag run (`gh -R o/r issue close`,
    # `gh --repo o/r issue …`) before the subcommand — same widening as the
    # `gh pr merge` anchors above; `issue (close|edit)` stays ADJACENT.
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*issue[[:space:]]+(close|edit)\b'; then
      decided=
      if should_skip trusted-filer-mutate; then
        decided=1
      else
        # Sub-arm b: `gh issue edit <N> --remove-label directive` blocks
        # on any filer, no `is_trusted_filer` resolution needed. Accept both
        # the space- and =-separated forms (optionally quoted), AND a
        # comma-joined value list where `directive` is any element
        # (`--remove-label other,directive`) — gh removes every listed label.
        # The leading `([^"' ]*,)?` allows any list prefix before `directive`;
        # the `([[:space:],"']|$)` tail is the word boundary so a longer label
        # like `directive-foo` does not over-match (#211).
        tfm_declassify_re='--remove-label[=[:space:]]+["'"'"']?([^"'"'"' ]*,)?directive([[:space:],"'"'"']|$)'
        # Selector accepts a bare number, a quoted number (the `["']?` absorbs a
        # leading quote), and a gh URL with a case-insensitive scheme (gh accepts
        # `HTTPS://`) — #223. On the `["']?` guard: `parse_env_prefix` (escape.sh,
        # run unconditionally above) shlex round-trips `$cmd` (`shlex.split` →
        # `shlex.join`) ONLY when python3+jq are present — there a quoted `"100"`
        # is normalized to a bare `100` and the `["']?` is a harmless no-op. When
        # python3/jq are absent, `parse_env_prefix` passes `$cmd` through
        # unchanged so a quoted selector keeps its quotes — the `["']?` is what
        # matches it in that fallback path. The declassify arm only confirms it's
        # `gh issue edit <selector>`; it does not use the number.
        # #499: tolerate a leading gh global-flag run (`gh --repo o/r issue edit`)
        # before the subcommand — same widening as the entry anchor.
        tfm_edit_sel_re='gh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*issue[[:space:]]+edit[[:space:]]+["'"'"']?([0-9]+|[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]"'"'"']+)'
        if [[ "$cmd" =~ $tfm_edit_sel_re ]] \
           && [[ "$cmd" =~ $tfm_declassify_re ]]; then
          block trusted-filer-mutate "Removing the 'directive' label declassifies an Issue and bypasses dir-mode review. Human-confirm required always (SPEC §1.5 filer-aware invariants). Or SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='<why>' for legitimate edge cases."
        # Sub-arm a: `gh issue close <N>` — two-stage check.
        #   Stage 1 (discussion-tier, SPEC §5.19, Issue #116): if the Issue
        #     carries the `discussion` label, close MUST use `--reason completed`
        #     OR `--reason "not planned"` (the two paths from SPEC §5.19). Bare
        #     close (no `--reason`) is blocked — discussion tier has exactly
        #     two close paths. The not-planned match tolerates both the gh-valid
        #     space form and the legacy underscore so the hook is never itself
        #     the blocker (#216); `gh` rejects the underscore at its own boundary.
        #   Stage 2 (trusted-filer, existing): if not a discussion Issue, fall
        #     through to the trusted-filer check — block close-without-`--reason
        #     completed` on Issues authored by trusted filers (OWNER / MEMBER /
        #     MAINTAINER / COLLABORATOR).
        # #499: tolerate a leading gh global-flag run (`gh -R o/r issue close`)
        # before the subcommand. The flag-run adds two capture groups ahead of
        # the selector, so the selector value is BASH_REMATCH[3] below (not [1]).
        elif tfm_close_sel_re='gh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*issue[[:space:]]+close[[:space:]]+["'"'"']?([0-9]+|[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]"'"'"']+)'
             [[ "$cmd" =~ $tfm_close_sel_re ]]; then
          # Normalize the selector to a pure issue number (#223): gh accepts a
          # URL or quoted number, but is_trusted_filer / the cache key / the
          # block message all need a bare number (is_trusted_filer returns
          # "not trusted" → fail-open on any non-number). For a URL, take the
          # segment after the LAST `/issues/` (so `…/issues/55/issues/100` →
          # 100, matching gh's target) then its leading digits; otherwise strip
          # to digits. Pure parameter expansion — no second `=~`, so no
          # BASH_REMATCH clobber.
          tf_sel="${BASH_REMATCH[3]}"
          case "$tf_sel" in
            */issues/*) tf_issue="${tf_sel##*/issues/}"; tf_issue="${tf_issue%%[!0-9]*}" ;;
            *)          tf_issue="${tf_sel//[^0-9]/}" ;;
          esac
          # Extract owner/name from a URL selector so the trust + discussion
          # lookups resolve against the URL's repo, not the current one (#231).
          # Pure parameter expansion (no `=~` — would clobber BASH_REMATCH).
          # Validate exactly owner/name (one slash, no whitespace); anything else
          # → empty → fall back to the current repo (fail-soft, no over-block).
          tf_repo=""
          case "$tf_sel" in
            *://*/*/issues/*)
              tf_repo="${tf_sel#*://}"          # host/owner/name/.../issues/N
              tf_repo="${tf_repo#*/}"           # owner/name/.../issues/N
              tf_repo="${tf_repo%%/issues/*}"   # owner/name (or owner/name/extra)
              case "$tf_repo" in
                */*/*) tf_repo="" ;;            # more than owner/name → bail
                */*) : ;;                       # exactly owner/name → keep
                *) tf_repo="" ;;                # missing a segment → bail
              esac
              case "$tf_repo" in *[[:space:]]*) tf_repo="" ;; esac
              ;;
          esac
          # If no URL-derived repo, parse an explicit `--repo owner/name` flag
          # (#237, completing #231) or gh's `-R` short alias for it (#242): gh
          # accepts `<number> --repo owner/name` / `<number> -R owner/name` as a
          # foreign-repo selector, and without this the flag form leaves tf_repo
          # empty so trust/discussion resolve against the CURRENT repo — the same
          # cross-repo fail-open #231 closed for the URL form. Own `=~` clobbers
          # BASH_REMATCH, but tf_sel/tf_issue and the URL tf_repo are already
          # saved above. Try the long form first, then `-R` (anchored to a
          # preceding space so it can't match inside another token; `-R` is
          # case-sensitive and never a substring of the lowercase `--repo`).
          # Accept owner/name or gh's documented [HOST/]owner/name (gh resolves
          # the host); reject a bare token, a trailing slash, or >3 segments →
          # empty → fall back to the current repo (fail-soft).
          if [ -z "$tf_repo" ]; then
            tfm_repo_flag_re='--repo[=[:space:]]+["'"'"']?([^[:space:]"'"'"']+)'
            tfm_repo_short_re='[[:space:]]-R[=[:space:]]+["'"'"']?([^[:space:]"'"'"']+)'
            tf_repo_flag=
            if [[ "$cmd" =~ $tfm_repo_flag_re ]]; then
              tf_repo_flag="${BASH_REMATCH[1]}"
            elif [[ "$cmd" =~ $tfm_repo_short_re ]]; then
              tf_repo_flag="${BASH_REMATCH[1]}"
            fi
            case "$tf_repo_flag" in
              ''|*/*/*/*|*/) : ;;                    # empty / >3 segments / trailing slash → bail
              */*/*|*/*)  tf_repo="$tf_repo_flag" ;; # [host/]owner/name → keep
              *)          : ;;                       # bare token → bail
            esac
          fi
          # #555 A6: final validation of the resolved tf_repo (URL- or flag-
          # derived). The parses above validate segment COUNT only, so a `.`/`..`
          # path segment (`../../evil/issues/1`, `owner/..`) or an out-of-charset
          # segment slipped through — the trust/discussion `gh issue view --repo`
          # would then resolve against an attacker-chosen repo. Reject a dot-segment
          # and enforce the GitHub owner/repo charset; a rejected value → empty →
          # fall back to the CURRENT repo (fail-soft, tightening the trust check).
          if [ -n "$tf_repo" ]; then
            case "/$tf_repo/" in
              */../*|*/./*) tf_repo="" ;;            # . or .. path segment → bail
            esac
          fi
          if [ -n "$tf_repo" ]; then
            case "$tf_repo" in
              *[!A-Za-z0-9._/-]*) tf_repo="" ;;      # out-of-charset segment → bail
            esac
          fi
          tf_completed=
          tf_not_planned=
          # #505: accept the equals form `--reason=completed` (gh-valid) too,
          # mirroring the matcher's other `[=[:space:]]` selectors — the
          # space-only form falsely blocked a legitimate completed-close.
          if [[ "$cmd" =~ --reason[=[:space:]]+completed ]]; then tf_completed=1; fi
          # Tolerate both the gh-valid space form (`--reason "not planned"`,
          # optionally quoted) and the legacy underscore (#216).
          tf_notplanned_re='--reason[=[:space:]]+["'"'"']?not[_[:space:]]planned'
          if [[ "$cmd" =~ $tf_notplanned_re ]]; then tf_not_planned=1; fi
          # Stage 1: classify discussion-tier FIRST, independent of the close
          # reason (#236). A `--reason completed` close is always allowed (the
          # final else), so the query is skipped only for that; for any other
          # close it runs, so a sanctioned `--reason "not planned"` close on a
          # discussion Issue is recognized as the §5.19 no-action path instead of
          # being short-circuited into the Stage-2 trusted-filer block.
          tf_is_discussion=
          if [ -z "$tf_completed" ] && command -v gh >/dev/null 2>&1; then
            if [ -n "$tf_repo" ]; then
              tf_labels=$(gh issue view "$tf_issue" --repo "$tf_repo" --json labels --jq '.labels[].name' 2>/dev/null)
            else
              tf_labels=$(gh issue view "$tf_issue" --json labels --jq '.labels[].name' 2>/dev/null)
            fi
            if printf '%s\n' "$tf_labels" | grep -qx discussion; then
              tf_is_discussion=1
            fi
          fi
          if [ -n "$tf_is_discussion" ]; then
            # Discussion-tier (SPEC §5.19): exactly two close paths — `completed`
            # (allowed via the final else) or `"not planned"` (the no-action path,
            # allowed regardless of filer trust, #236). A bare close or
            # `--reason duplicate` is blocked.
            if [ -n "$tf_not_planned" ]; then
              mark_allow trusted-filer-mutate
              decided=1
            else
              block trusted-filer-mutate "Issue #${tf_issue} is discussion-tier (SPEC §5.19). Close via '/resolve-discussion ${tf_issue} --promoted-to <M>' (concrete Issue filed) or '/resolve-discussion ${tf_issue} --no-action \"<reason>\"' (nothing to do). A bare close or --reason duplicate is blocked — discussion tier has exactly two close paths (--reason completed | \"not planned\"). Or SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='<why>' for legitimate edge cases."
            fi
          # Stage 2: trusted-filer enforcement — NON-discussion Issues only.
          elif [ -z "$tf_completed" ] && command -v is_trusted_filer >/dev/null 2>&1; then
            if is_trusted_filer "$tf_issue" "$tf_repo"; then
              block trusted-filer-mutate "Issue #${tf_issue} was authored by a trusted filer (OWNER / MEMBER / MAINTAINER / COLLABORATOR). Closing without --reason completed (i.e., not-planned or duplicate) requires human confirm. Use 'gh issue close ${tf_issue} --reason completed' if evidence of completion exists, or SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='<why>' for legitimate edge cases."
            else
              mark_allow trusted-filer-mutate
              decided=1
            fi
          else
            # --reason completed / --reason "not planned" OR helper unavailable → fail-open per §6.1.
            mark_allow trusted-filer-mutate
            decided=1
          fi
        else
          # gh issue edit without --remove-label directive — out of scope.
          mark_allow trusted-filer-mutate
          decided=1
        fi
      fi
      [ -z "$decided" ] && pass_through_trace trusted-filer-mutate "$cmd"
    fi

    # label-parent-consistency — block `gh issue edit <N> --add-label
    # {execution|task|bug}` when the label contradicts the Issue body's line-1
    # `Parent Directive: #N` marker (SPEC §6.1, Issue #199). Converts the
    # advisory #197 reviewer/skill layer into runtime enforcement — fires
    # regardless of which agent/path applies the label.
    #   - `execution` with NO marker → block (execution Issues require a parent,
    #     SPEC §1.7:309).
    #   - `task`/`bug` WITH a marker present → block (standalone types must not
    #     be parented; the marker is a relabel-or-drop type smell).
    # Scoped to the --add-label edit path only; the `gh issue create` path is
    # already label↔marker-consistent via /file-issue (post-#197).
    # issue_has_parent_marker is TRI-STATE (0=present, 1=resolved-absent,
    # 2=unresolvable). The block fires only on a positively-resolved
    # contradiction; an unresolvable body (rc 2) or an undefined predicate
    # fails open per SPEC §6.1 (parity with proposed-protect / trusted-filer-mutate).
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+issue[[:space:]]+edit\b.*--add-label\b'; then
      decided=
      if should_skip label-parent-consistency; then
        decided=1
      else
        # Selector normalization (#276): resolve the issue number AND a `-R`/`--repo`
        # or URL-embedded target repo via the shared helper, tolerant of selector
        # form (bare/quoted/URL — A1) and flag order (A2). The repo (A3) is threaded
        # into every predicate below so a cross-repo `--add-label` edit resolves the
        # marker/labels against the COMMAND's target, not the cwd repo.
        lpc_issue=
        lpc_repo=
        if command -v resolve_gh_issue_target >/dev/null 2>&1; then
          # Capture FIRST, then split — never `IFS=$'\t' read <<< "$(...)"`, whose
          # prefix would leak tab-IFS into the helper's own tokenizer (#276).
          lpc_target="$(resolve_gh_issue_target "$cmd" 'edit')"
          IFS=$'\t' read -r lpc_issue lpc_repo <<< "$lpc_target"
        elif [[ "$cmd" =~ gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+([0-9]+) ]]; then
          lpc_issue="${BASH_REMATCH[1]}"   # fail-soft: pre-#276 issue_type.sh w/o the helper
        fi
        # Which gated type label is being added? Only execution/task/bug are
        # gated; accept space- or =-separated, optionally quoted, and the gated
        # token anywhere in a comma-joined value list (--add-label other,execution)
        # via the leading `([^"' ]*,)?` prefix (#212). NOTE: that prefix is a
        # capture group, so the gated label is BASH_REMATCH[2], not [1].
        # Gated labels: execution/task/bug (parent-marker consistency, #199) plus
        # the two tier type-keys initiative/directive (#251). The gated token is
        # BASH_REMATCH[2] (the leading `([^"' ]*,)?` comma-prefix is group 1).
        # Terminator (#278 Theme C): a TRUE label boundary — comma (next label in
        # a list), whitespace / closing quote (end of the --add-label value), or
        # end-of-string. NOT `[^a-z]`: `-` and `_` are valid label-name chars, so
        # `[^a-z]` let `directive-foo` / `task_old` over-match the bare type token
        # and falsely trip this matcher on a custom label that merely starts with
        # one. (A letter suffix like `executionish` was already excluded; this
        # closes the hyphen/underscore-suffix gap.)
        lpc_label=
        lpc_label_re='--add-label[=[:space:]]+["'"'"']?([^"'"'"' ]*,)?(execution|task|bug|initiative|directive)(,|[[:space:]]|["'"'"']|$)'
        if [[ "$cmd" =~ $lpc_label_re ]]; then
          lpc_label="${BASH_REMATCH[2]}"
        fi
        if [ -z "$lpc_label" ] || [ -z "$lpc_issue" ]; then
          # Not a gated label / no issue number → fail open.
          mark_allow label-parent-consistency
          decided=1
        elif [ "$lpc_label" = initiative ] || [ "$lpc_label" = directive ]; then
          # Tier type-keys (#251): (a) initiative/directive mutual-exclusivity and
          # (b) the Directive parent-XOR. Fail open if the type predicates are
          # unavailable.
          if ! command -v is_directive_issue >/dev/null 2>&1 \
             || ! command -v is_initiative_issue >/dev/null 2>&1; then
            mark_allow label-parent-consistency
            decided=1
          elif [ "$lpc_label" = initiative ] && is_directive_issue "$lpc_issue" "$lpc_repo"; then
            block label-parent-consistency "Issue #${lpc_issue}: --add-label initiative on a Directive is blocked — the 'initiative' and 'directive' tier type-keys are mutually exclusive (SPEC §1.7). An Issue is a Directive or an Initiative, not both. Or SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>'."
          elif [ "$lpc_label" = directive ] && is_initiative_issue "$lpc_issue" "$lpc_repo"; then
            block label-parent-consistency "Issue #${lpc_issue}: --add-label directive on an Initiative is blocked — the 'directive' and 'initiative' tier type-keys are mutually exclusive (SPEC §1.7). Or SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>'."
          elif [ "$lpc_label" = directive ]; then
            # (b) parent-XOR: a Directive needs exactly one parent kind — a
            # `## MISSION fit` field XOR a line-1 `Parent Initiative: #N` marker.
            if ! command -v issue_has_mission_fit_field >/dev/null 2>&1 \
               || ! command -v issue_has_initiative_parent_marker >/dev/null 2>&1; then
              mark_allow label-parent-consistency
              decided=1
            else
              issue_has_mission_fit_field "$lpc_issue" "$lpc_repo"; lpc_mf=$?
              issue_has_initiative_parent_marker "$lpc_issue" "$lpc_repo"; lpc_im=$?
              if [ "$lpc_mf" = 2 ] || [ "$lpc_im" = 2 ]; then
                mark_allow label-parent-consistency   # unresolvable → fail open
                decided=1
              elif [ "$lpc_mf" = 0 ] && [ "$lpc_im" = 0 ]; then
                block label-parent-consistency "Issue #${lpc_issue}: --add-label directive — a Directive must have exactly ONE parent kind, but the body has BOTH a '## MISSION fit' field and a line-1 'Parent Initiative: #N' marker (SPEC §1.7 parent-XOR). Keep one: drop the MISSION-fit field for an Initiative-parented Directive, or drop the Parent Initiative marker for a MISSION-parented one. Or SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>'."
              elif [ "$lpc_mf" = 1 ] && [ "$lpc_im" = 1 ]; then
                block label-parent-consistency "Issue #${lpc_issue}: --add-label directive — a Directive must have exactly ONE parent kind, but the body has NEITHER a '## MISSION fit' field NOR a line-1 'Parent Initiative: #N' marker (SPEC §1.7 parent-XOR). Add one. Or SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>'."
              else
                mark_allow label-parent-consistency   # exactly one → allow
                decided=1
              fi
            fi
          else
            # --add-label initiative on a non-Directive Issue → allowed (the
            # mutual-exclusivity only blocks the initiative↔directive collision).
            mark_allow label-parent-consistency
            decided=1
          fi
        elif ! command -v issue_has_parent_marker >/dev/null 2>&1; then
          mark_allow label-parent-consistency
          decided=1
        else
          issue_has_parent_marker "$lpc_issue" "$lpc_repo"
          lpc_rc=$?
          if [ "$lpc_rc" = 2 ]; then
            # Unresolvable body (gh down / no auth / not found) → fail open.
            mark_allow label-parent-consistency
            decided=1
          elif [ "$lpc_label" = execution ] && [ "$lpc_rc" = 1 ]; then
            block label-parent-consistency "Issue #${lpc_issue}: --add-label execution needs a 'Parent Directive: #N' marker on body line 1 — an execution Issue is parented under a Directive (SPEC §1.7). Set the marker first (/link-directive ${lpc_issue} <directive-#>), then relabel; or use --add-label task for standalone work. Or SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>' for a legitimate two-step edit."
          elif { [ "$lpc_label" = task ] || [ "$lpc_label" = bug ]; } && [ "$lpc_rc" = 0 ]; then
            block label-parent-consistency "Issue #${lpc_issue}: --add-label ${lpc_label} contradicts the 'Parent Directive: #N' marker on body line 1 — task/bug are standalone and must not be parented. Relabel execution, or drop the parent marker. Or SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>' for a legitimate edge case."
          else
            # Consistent (execution+marker, or task/bug+no-marker) → allow.
            mark_allow label-parent-consistency
            decided=1
          fi
        fi
      fi
      [ -z "$decided" ] && pass_through_trace label-parent-consistency "$cmd"
    fi

    # initiative-readonly (#251) — an Initiative Issue is read-only to the shell
    # except for appended comments (SPEC §1.7). Block mutating gh verbs
    # (`issue edit`/`close`/`reopen`, which subsume `--add-label`/`--remove-label`/
    # `--body`/`--title`) targeting an `initiative` Issue; `gh issue comment` is
    # not a mutating verb and so is never matched → always allowed. The selector
    # is normalized to a bare issue number (bare / quoted / URL forms) before
    # is_initiative_issue resolves it against the current repo (Initiatives are
    # same-repo, §1.7). Fail-open per §6.1 (parity with trusted-filer-mutate /
    # proposed-protect).
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+issue[[:space:]]+(edit|close|reopen)\b'; then
      decided=
      if should_skip initiative-readonly; then
        decided=1
      else
        # Selector via the shared helper (#276): tolerant of form (bare/quoted/URL
        # — already handled pre-#276) AND flag order (new: `gh issue close --foo x N`).
        # NOTE: the helper also resolves a `-R`/`--repo` target, but initiative-readonly
        # deliberately IGNORES it and resolves against the CURRENT repo — cross-repo
        # Initiatives are out of scope (SPEC §1.7:333; they would reintroduce the
        # cross-repo-trust surface), so this matcher only governs same-repo Initiatives.
        iro_issue=
        if command -v resolve_gh_issue_target >/dev/null 2>&1; then
          iro_target="$(resolve_gh_issue_target "$cmd" 'edit|close|reopen')"   # capture before split (#276)
          IFS=$'\t' read -r iro_issue _iro_repo <<< "$iro_target"
        elif [[ "$cmd" =~ gh[[:space:]]+issue[[:space:]]+(edit|close|reopen)[[:space:]]+["'"'"']?([0-9]+|[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]"'"'"']+) ]]; then
          iro_sel="${BASH_REMATCH[2]}"   # fail-soft: pre-#276 issue_type.sh w/o the helper
          case "$iro_sel" in
            */issues/*) iro_issue="${iro_sel##*/issues/}"; iro_issue="${iro_issue%%[!0-9]*}" ;;
            *)          iro_issue="${iro_sel//[^0-9]/}" ;;
          esac
        fi
        if [ -z "$iro_issue" ] || ! command -v is_initiative_issue >/dev/null 2>&1; then
          mark_allow initiative-readonly
          decided=1
        elif is_initiative_issue "$iro_issue"; then
          block initiative-readonly "Issue #${iro_issue} is an Initiative — read-only to the shell except for appended comments (SPEC §1.7). The shell consumes Initiatives; it does not edit, close, relabel, or retire them. Use 'gh issue comment ${iro_issue}' to surface findings upward (a challenge/completion comment); revise/retire decisions belong to the upstream owner. Or SKIP_HOOKS=initiative-readonly SKIP_REASON='<why>' for a sanctioned maintainer edit."
        else
          mark_allow initiative-readonly
          decided=1
        fi
      fi
      [ -z "$decided" ] && pass_through_trace initiative-readonly "$cmd"
    fi

    # directive-close (#490) — block a GitHub close keyword + Directive #N in the
    # INLINE --body/-b of `gh pr create`/`gh pr edit`. GitHub auto-closes a
    # referenced Issue at merge when a close keyword (close/closes/closed,
    # fix/fixes/fixed, resolve/resolves/resolved) precedes #N anywhere in the PR
    # body; for a Directive that bypasses /complete-directive's signal gate
    # (SPEC §5.13). Execution Issues are unaffected — their merge legitimately
    # resolves them. The shared detector reads the INLINE body only; --body-file/-F
    # (incl. stdin `-F -`, the /ship & /sync-pr path) is a documented residual
    # (§6.1). Per-#N fail-open via is_directive_issue (an unresolved type skips that
    # #N). The commit-message vector lives in the commit-format umbrella arm below.
    if printf '%s' "$cmd" | grep -qE '\bgh\b[^|;&]*\bpr\b[^|;&]*\b(create|edit)\b'; then
      decided=
      if should_skip directive-close; then
        decided=1
      else
        dc_hit=
        if command -v extract_gh_pr_body >/dev/null 2>&1 && command -v directive_close_violation >/dev/null 2>&1; then
          dc_body=$(extract_gh_pr_body "$raw_cmd")
          if [ -n "$dc_body" ]; then
            dc_hit=$(directive_close_violation "$dc_body") || dc_hit=
          fi
        fi
        if [ -n "$dc_hit" ]; then
          block directive-close "PR body has a close keyword referencing Directive #${dc_hit} — GitHub would auto-close it at merge, bypassing /complete-directive (signal-gated, SPEC §5.13). Directives close only via /complete-directive; use 'Refs #${dc_hit}' or 'advances #${dc_hit}', not a close keyword. Or SKIP_HOOKS=directive-close SKIP_REASON='<why>' for a sanctioned exception."
        else
          mark_allow directive-close
          decided=1
        fi
      fi
      [ -z "$decided" ] && pass_through_trace directive-close "$cmd"
    fi

    # Force push — scoped to protected targets, with an explicit-target
    # requirement (#204). Force-push to a non-protected branch is the normal
    # rebase-pull tail (SPEC §13) and is allowed — but ONLY when the target
    # branch is named explicitly (`git push --force-with-lease origin <branch>`).
    #   - a PROTECTED branch named anywhere in the command → block.
    #   - a BARE / remote-only force-push (no explicit refspec) → block with
    #     guidance to name the target. The bare form is NOT HEAD-resolved: a
    #     no-refspec push's real destination is config-dependent (push.default,
    #     branch upstream, remote.*.push), so the current branch name is not a
    #     reliable proxy — a feature branch tracking origin/main could otherwise
    #     clobber main. Fail-safe: when the target can't be confirmed
    #     non-protected, block. Escape: SKIP_HOOKS=force-push.
    # #555 A4: the short-force alternative `(^|space)-[A-Za-z]*f[A-Za-z]*\b`
    # matches a BUNDLED short cluster (`-uf`/`-fu`) whose `f` had no isolated
    # `-f\b` token → the bare bundled force previously skipped the irreversible
    # fail-safe block entirely. Anchored to a token start (`(^|[[:space:]])`) so a
    # branch NAME containing `-f` (`my-feature`) is not mis-read as a flag. Entry
    # is a coarse pre-filter; fp_force_segs below re-confirms per push segment.
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}push\b.*((^|[[:space:]])\-[A-Za-z]*f[A-Za-z]*\b|\-\-force\b|\-\-force-with-lease\b)"; then
      decided=
      # Isolate the actual git-push SEGMENT(s) (heredoc-stripped) so a force flag,
      # protected token, or target named in a SIBLING segment (gh pr create --base
      # main, a heredoc body) can't leak into the checks below (#437, mirroring
      # the #366 branch arm). Every refinement is a value-assignment grep — never
      # an `if printf|grep -qE` — so the §39b structural sweep counts only the one
      # matcher-entry line above.
      # Collapse backslash-newline line-continuations (awk: join a line ending in
      # `\` with the next) BEFORE segmenting, else a `git \<nl> push \<nl> --force`
      # continuation splits across newlines and no segment carries `git push`
      # together (#17 regression guard). Heredoc bodies are already stripped.
      # #555 A4: same bundled-short-force alternative as the entry grep, so a
      # `git push -uf origin x` push segment is recognized as force-bearing here
      # too (else the entry over-matched but the seg filter dropped it → no gate).
      fp_force_segs=$(push_segments "$(strip_command_data "$raw_cmd" message | awk '{ if (sub(/\\$/,"")) printf "%s ", $0; else print }')" | grep -E "((^|[[:space:]])\-[A-Za-z]*f[A-Za-z]*\b|\-\-force\b|\-\-force-with-lease\b)")
      if [ -z "$fp_force_segs" ]; then
        # The force flag lived only in a non-push sibling segment → not a
        # force-push → allow (silent).
        decided=1
      else
        # Protected token / ref-set checked against the force-bearing push
        # segment(s) ONLY. Case-insensitive (`-i`): a remote `MAIN`/`Main`
        # collides with `main` on case-insensitive filesystems — still a
        # protected-clobber path.
        fp_protected=
        printf '%s\n' "$fp_force_segs" | grep -qiE "\b(${PROTECTED_BRANCH_PATTERN})\b" && fp_protected=1
        # --mirror/--all/--branches push EVERY ref (incl. protected) with no single
        # verifiable target — same fail-safe as a bare push.
        fp_refset=
        printf '%s\n' "$fp_force_segs" | grep -qE '(^|[[:space:]])--(mirror|all|branches)([[:space:]]|=|$)' && fp_refset=1
        if should_skip force-push; then
          decided=1
        elif [ -n "$fp_protected" ]; then
          block force-push "force push to a protected branch (${PROTECTED_BRANCH_PATTERN//|/, }) blocked"
        elif [ -n "$fp_refset" ]; then
          block force-push "force push with --mirror/--all/--branches is blocked: it targets every ref (including protected branches) with no verifiable single target. Name one branch: 'git push --force-with-lease origin <branch>'. Or SKIP_HOOKS=force-push SKIP_REASON='<why>'."
        else
          # Per force-bearing push SEGMENT, count positional (non-flag) tokens
          # after `push`. An explicit <remote> <refspec> pair (>=2 positionals)
          # names the target; with no protected token above it is verified
          # non-protected. Block if ANY force-bearing segment lacks a named target
          # (bare/remote-only) — its real destination is config-dependent
          # (push.default / upstream tracking) and can't be confirmed non-protected.
          fp_bare=
          while IFS= read -r fp_seg; do
            [ -n "$fp_seg" ] || continue
            fp_positionals=0
            fp_seen_push=
            fp_skip_next=
            read -ra fp_arr <<< "$fp_seg"
            for fp_tok in "${fp_arr[@]}"; do
              if [ -z "$fp_seen_push" ]; then
                [ "$fp_tok" = push ] && fp_seen_push=1
                continue
              fi
              if [ -n "$fp_skip_next" ]; then fp_skip_next=; continue; fi
              case "$fp_tok" in
                -o|--push-option|--repo|--receive-pack|--exec) fp_skip_next=1 ;;
                -*) ;;  # flag — not a positional
                *) fp_positionals=$((fp_positionals + 1)) ;;
              esac
            done
            [ "$fp_positionals" -ge 2 ] || fp_bare=1
          done <<< "$fp_force_segs"
          if [ -n "$fp_bare" ]; then
            block force-push "force push needs an explicit target branch: use 'git push --force-with-lease origin <branch>'. A bare or remote-only force-push is blocked because its real destination is config-dependent (push.default / upstream tracking) and can't be confirmed non-protected. Or SKIP_HOOKS=force-push SKIP_REASON='<why>'."
          else
            # Every force-bearing push segment names an explicit non-protected
            # target → the rebase-pull tail (§13). Allow.
            mark_allow force-push
            decided=1
          fi
        fi
      fi
      [ -z "$decided" ] && pass_through_trace force-push "$cmd"
    fi

    # Direct push to protected branch (#366: scan only the git-push command
    # SEGMENT after heredoc-stripping, not a whole-command substring — so a
    # protected token inside a heredoc body or in a sibling non-push segment
    # (`git push origin feat && gh pr create --base main`) doesn't false-trip.
    # Coarse `push` entry kept for the §39b matcher-entry check; refined below.
    # Fail-closed: strip_command_data falls back to raw_cmd on failure, and
    # push_segments only ever drops NON-push segments, so a genuine protected
    # push (incl. a quoted target — quotes are NOT stripped on this arm) still
    # matches. Heredoc-only strip: quote-stripping the push arm could drop a
    # quoted protected target (`git push origin "main"`) — a false-negative.)
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}push\b"; then
      decided=
      # Refine: count push-bearing segments (heredoc-stripped) that carry a
      # protected token. The hit is computed into a var via grep-count rather
      # than a refining conditional grep, which the §39b structural awk would
      # mis-read as a second matcher entry (the merge-strategy arm does the same).
      pp_hit=$(push_segments "$(strip_command_data "$raw_cmd" message)" | grep -cE "\b(${PROTECTED_BRANCH_PATTERN})\b")
      if [ "${pp_hit:-0}" -gt 0 ]; then
        should_skip branch && decided=1 || block branch "direct push to protected branch blocked"
      else
        decided=1   # git push present but no protected token in any push segment → allow (silent)
      fi
      [ -z "$decided" ] && pass_through_trace branch "$cmd"
    fi

    # --no-verify
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}commit\b.*\-\-no-verify\b"; then
      decided=
      should_skip no-verify && decided=1 || block no-verify "--no-verify blocked"
      [ -z "$decided" ] && pass_through_trace no-verify "$cmd"
    fi

    # --amend (only when the commit is already pushed)
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}commit\b.*\-\-amend\b"; then
      decided=
      if git rev-parse '@{upstream}' >/dev/null 2>&1; then
        if git merge-base --is-ancestor HEAD '@{upstream}' 2>/dev/null; then
          should_skip amend && decided=1 || block amend "--amend of an already-pushed commit blocked"
        else
          # Local amend (commit ahead of upstream). Common case during draft
          # work — happy path with no audit emission.
          mark_allow amend
        fi
      else
        # No upstream tracked → local amend allowed. Happy path.
        mark_allow amend
      fi
      [ -z "$decided" ] && pass_through_trace amend "$cmd"
    fi

    # git commit body: protected branch / commit format / secrets / lint
    # Umbrella matcher with 4 sub-checks each carrying its own category.
    # `decided` is set by ANY firing sub-arm (block exits, escape audits).
    # All four sub-checks passing IS the common happy path (every clean
    # commit) — mark_allow keeps audit.jsonl quiet on that path; the
    # pass-through tail is the safety net for an unforeseen anomaly.
    # No --allow-empty carve-out (#209): an empty commit is still a
    # protected-branch write and still carries a subject; the secret/lint
    # sub-checks are harmless no-ops on an empty staged set. Excluding it
    # skipped all four gates in one flag.
    # #403: gate the entry on strip_command_data (heredoc mode) so a literal
    # "git commit" appearing only inside a heredoc DATA body (e.g. a
    # `gh issue edit --body "$(cat <<'EOF' ... git commit ... EOF)"`) does not
    # false-trip the arm — matching the sibling clean (:198) and merge (:333) arms,
    # which use heredoc mode for the same reason. heredoc (NOT full) mode is the
    # under-block-safe choice: `full` strips the interior of every double-quoted
    # span, but bash executes command substitutions inside double quotes, so a real
    # `git commit` in `"$(git commit …)"` would be hidden from the grep yet still
    # run — heredoc mode leaves quoted substitutions intact, so a real invocation
    # always matches. Residual (accepted): a plain double-quoted literal that merely
    # mentions "git commit" with no heredoc still false-blocks; use --body-file or a
    # heredoc body. The unstripped raw still feeds extract_commit_subject below.
    if printf '%s' "$(strip_command_data "$raw_cmd" heredoc)" | grep -qE "${GIT_PREFIX}commit\b" ; then
      decided=
      if is_protected_branch; then
        should_skip branch && decided=1 || block branch "commit on protected branch ($(branch_label)) blocked"
      fi
      subj=$(extract_commit_subject "$raw_cmd" "$cmd")
      if [ -n "$subj" ]; then
        err=$(check_commit_subject "$subj" 2>&1) || {
          should_skip commit-format && decided=1 || block commit-format "$err"
        }
      fi
      # directive-close (#490): block a close keyword + Directive #N anywhere in the
      # commit MESSAGE (subject OR body — GitHub auto-closes on a keyword anywhere in
      # the message, so a subject-only scan would miss a body trailer). The shared
      # detector (helpers/git_matcher.sh) is fed the FULL message via
      # extract_commit_message (the complement of the subject-only extract_commit_subject
      # above). Its own escape category (directive-close), sibling to the umbrella's
      # branch / commit-format / secret / format sub-checks.
      # Per-#N fail-open; Execution Issues pass (`Closes #<execution>` is correct).
      if command -v directive_close_violation >/dev/null 2>&1 && command -v extract_commit_message >/dev/null 2>&1; then
        ccmsg=$(extract_commit_message "$raw_cmd")
        if [ -n "$ccmsg" ] && dc_hit=$(directive_close_violation "$ccmsg"); then
          should_skip directive-close && decided=1 || block directive-close "commit message has a close keyword referencing Directive #${dc_hit} — GitHub would auto-close it at merge, bypassing /complete-directive (signal-gated, SPEC §5.13). Use 'Refs #${dc_hit}' or 'advances #${dc_hit}', not a close keyword. Or SKIP_HOOKS=directive-close SKIP_REASON='<why>' for a sanctioned exception."
        fi
      fi
      # Guarded like the sibling matchers (#213): if scan_staged_secrets is
      # undefined (secret_scan.sh failed to source — the session-restart
      # helper-miss safe_source degrades gracefully), skip the secret arm
      # (fail-open per the SPEC §6.1 fail-policy table) rather than blocking
      # every commit with `command not found`.
      if command -v scan_staged_secrets >/dev/null 2>&1 && ! err=$(scan_staged_secrets 2>&1); then
        should_skip secret && decided=1 || block secret "$err"
      fi
      lint=$(detect_lint_cmd)
      if [ -n "$lint" ]; then
        if ! run_bounded_lint "$lint" >/dev/null 2>&1; then
          should_skip format && decided=1 || block format "lint failed or timed out (GHJIG_LINT_TIMEOUT=${GHJIG_LINT_TIMEOUT:-30}s): $lint"
        fi
      fi
      # Happy path — all four sub-checks evaluated to no-problem. mark_allow
      # is no-op + decided=1; the pass-through line below remains as the
      # invariant safety net but is unreachable for this matcher today.
      [ -z "$decided" ] && mark_allow commit-format
      [ -z "$decided" ] && pass_through_trace commit-format "$cmd"
    fi
    ;;

  Edit|Write|MultiEdit)
    target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
    [ -z "$target" ] && exit 0

    # #555 A1: normalize $target LEXICALLY (a pure-string collapse of `.`/`..`
    # segments — NO `pwd -P`/`realpath`/`[ -d ]`/any filesystem access) BEFORE the
    # carve-out prefix matches below. Pre-fix the carve-outs prefix-matched the RAW
    # $target, so a `..`-laden absolute path (`$SHELL_ROOT/../../etc/passwd`) matched
    # `"$SHELL_ROOT"/*`, set the carve-out flag, and skipped the out-of-scope gate
    # (:1180 normalizes, but the carve-out short-circuits before it). A PHYSICAL
    # resolve only collapses `..` when the ancestor dir EXISTS — a security matcher
    # must neutralize a `..`-escape even for a not-yet-existing target (an Edit/Write
    # routinely CREATES a path, and `$HOME/.claude` is absent on CI runners), so a
    # physical resolve fell back to the raw path there and the bypass re-opened.
    # Collapsing purely lexically grants a carve-out only to a path lexically UNDER
    # the root regardless of what exists on disk — a traversal escape falls through
    # to the out-of-scope block (tightening). Used ONLY for the two carve-out case
    # matches; $target itself is preserved for the sensitive-file check and block
    # messages. Make $target absolute first (prefix cwd), then fold segments.
    resolved_target="$target"
    case "$resolved_target" in
      /*) ;;
      *) resolved_target="$(pwd -P)/$resolved_target" ;;
    esac
    # Lexical `.`/`..` collapse — walk segments, drop `.`/empty, pop on `..`. No
    # filesystem access, so an absent ancestor cannot defeat the normalization.
    _rt_norm=""; _rt_rest="$resolved_target"
    while [ -n "$_rt_rest" ]; do
      _rt_seg="${_rt_rest%%/*}"
      case "$_rt_rest" in */*) _rt_rest="${_rt_rest#*/}" ;; *) _rt_rest="" ;; esac
      case "$_rt_seg" in
        ''|.) ;;                              # `//` empty or `.` → drop
        ..) _rt_norm="${_rt_norm%/*}" ;;      # pop last kept segment (root-clamped)
        *)  _rt_norm="$_rt_norm/$_rt_seg" ;;  # keep
      esac
    done
    resolved_target="${_rt_norm:-/}"

    # Shell self-modification carve-out (#210): paths under
    # $GHJIG_ROOT/ skip the branch + out-of-scope checks (the
    # shell legitimately edits its own substrate, which is outside the
    # target repo's branch/registry model). It must NOT early-exit before
    # the sensitive-file check below: writing a .env / *.pem / credentials*
    # under the shell root is just as bad, and CLAUDE.md / SPEC §6.1/§14
    # document the sensitive check as firing under BOTH carve-outs. So we
    # set a flag (mirroring the $HOME/.claude/ carve-out) and fall through.
    shell_self_mod=
    case "$resolved_target/" in "$SHELL_ROOT"/*) shell_self_mod=1 ;; esac

    # User-global auto-memory carve-out (issue #91): paths under
    # $HOME/.claude/ are legitimate write targets for the persistent
    # memory tier and other Claude Code user-global state. The branch
    # check (protected-branch on the current repo) doesn't apply
    # because the file isn't tracked by the current repo's git, and
    # the out-of-scope (registry) check doesn't apply because
    # user-global state is intentionally outside the registry. The
    # sensitive-file check (.env / *.pem / credentials*) STILL fires
    # — no carve-out for that, because writing a credentials file
    # into ~/.claude/ would be just as bad.
    user_global_memory=
    case "$resolved_target/" in
      "$HOME"/.claude/*) user_global_memory=1 ;;
    esac

    # Edit on protected branch
    if is_protected_branch && [ -z "$user_global_memory" ] && [ -z "$shell_self_mod" ]; then
      should_skip branch || block branch "edit on protected branch blocked: $target"
    fi

    # Outside registry
    if [ -z "$user_global_memory" ] && [ -z "$shell_self_mod" ] && ! path_in_scope "$target"; then
      should_skip out-of-scope || block out-of-scope "edit outside registry blocked: $target"
    fi

    # Sensitive files — applies regardless of EITHER carve-out (#210). Match the
    # lexical basename AND, when the final component is a symlink, the
    # python3-realpath-resolved basename (#234) — else a symlink named
    # innocuously (`ln -s ~/.ssh/id_rsa ./innocent`; the `ln` isn't gated) would
    # let an Edit write through the link into a sensitive target. `python3`
    # absent / unresolvable → lexical-only (fail-soft). TOCTOU + hardlinks
    # out of scope. Path is piped via stdin, never interpolated into the python.
    base=$(basename "$target")
    sens_resolved=""
    if [ -L "$target" ] && command -v python3 >/dev/null 2>&1; then
      sens_rp=$(printf '%s' "$target" | python3 -c 'import os,sys; sys.stdout.write(os.path.realpath(sys.stdin.read()))' 2>/dev/null)
      [ -n "$sens_rp" ] && sens_resolved=$(basename "$sens_rp")
    fi
    # #501: match case-INSENSITIVELY (so `.ENV`/`X.PEM` don't slip past) and use
    # the documented `credentials*`/`id_rsa*`/`id_ed25519*` PREFIX globs (SPEC
    # §6.1 / CLAUDE.md) rather than the narrower `credentials.*` — so
    # `credentialsX`/`id_rsa_backup` block — plus `*.pem.*` for a double-extension
    # backup key (`key.pem.txt`). One helper, used for both the lexical basename
    # and the symlink-resolved one, so the two can't drift.
    _sens_match() {  # $1 = basename → rc 0 if it names a sensitive file
      local b; b=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
      case "$b" in
        .env|.env.*|*.pem|*.pem.*|credentials*|id_rsa*|id_ed25519*) return 0 ;;
      esac
      return 1
    }
    sens_hit=
    _sens_match "$base" && sens_hit=1
    if [ -z "$sens_hit" ] && [ -n "$sens_resolved" ]; then
      _sens_match "$sens_resolved" && sens_hit=1
    fi
    if [ -n "$sens_hit" ]; then
      should_skip sensitive || block sensitive "sensitive file edit blocked: $target${sens_resolved:+ (symlink to a sensitive target)}"
    fi
    ;;
esac

exit 0
