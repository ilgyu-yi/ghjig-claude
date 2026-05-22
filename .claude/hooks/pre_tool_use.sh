#!/usr/bin/env bash
set -uo pipefail

SHELL_ROOT="${CLAUDE_ENG_SHELL_ROOT:-}"
[ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0

# Primitive bootstrap of the hook runtime (SPEC §6.1). hookrt.sh hosts
# audit_log + safe_source; if absent, stderr-only warn and exit (cannot
# audit-log the absence of the audit-logger).
hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
if [ ! -f "$hookrt" ]; then
  printf '[claude-eng-shell] WARN hookrt-missing: %s not loaded — hook exiting\n' "$hookrt" >&2
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

  for arg in "${args[@]}"; do
    case "$arg" in
      -*) continue ;;
      rm|mv|cp|sudo|doas|time|env) continue ;;
    esac
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

    # Normalize multiline backslash-continuation and stray newlines so the
    # matchers see a single logical command. Collapse `\\\n` first, then
    # remaining newlines, then runs of whitespace. See SPEC §6.1
    # "Implementation note" for the framing.
    cmd=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -E 's/\\[[:space:]]+/ /g; s/[[:space:]]+/ /g')

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
    # Heredoc pattern excludes `<<<` here-strings (preceding-char check).
    if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(eval|bash[[:space:]]+-c|sh[[:space:]]+-c|python[[:space:]]*[0-9.]*[[:space:]]+-c)([^[:alnum:]_]|$)' \
       || printf '%s' "$cmd" | grep -qE '(^|[^<])<<-?[[:space:]]*[A-Za-z_]'; then
      audit_log warn bypass-suspect notice "$cmd"
    fi

    # Destructive command with out-of-scope path arg
    if printf '%s' "$cmd" | grep -qE '\b(rm|mv|cp)\s+(-[A-Za-z]*[fF][A-Za-z]*\s+)+'; then
      if ! check_destructive_args "$cmd"; then
        should_skip out-of-scope || block out-of-scope "destructive command points outside registry: $cmd"
      fi
    fi
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}reset\s+--hard\b"; then
      should_skip destructive || block destructive "git reset --hard blocked"
    fi
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}clean\s+-[A-Za-z]*f"; then
      should_skip destructive || block destructive "git clean -f blocked"
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
      if ! is_protected_branch; then
        should_skip backmerge \
          || block backmerge "backmerge blocked — use 'git pull --rebase origin <base>' instead (or SKIP_HOOKS=backmerge for exceptional cases)"
      fi
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
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
      if ! should_skip ac-closeout; then
        # ac_closeout_gate.sh is matcher-scoped (only sourced on the
        # `gh pr merge` path), so the safe_source call lives here, not
        # at file top. If safe_source returns 1 (helper missing) it has
        # already emitted the helper-missing warn — short-circuit out.
        if safe_source "$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh" ac-closeout; then
          ac_pr=$(extract_pr_from_merge_cmd "$cmd" || true)
          if [ -z "$ac_pr" ] && command -v gh >/dev/null 2>&1; then
            ac_pr=$(gh pr view --json number -q .number 2>/dev/null || true)
          fi
          if [ -n "$ac_pr" ]; then
            pr_needs_closeout "$ac_pr"
            ac_rc=$?
            case "$ac_rc" in
              0) block ac-closeout "linked issue has unchecked AC and no '## AC closeout' marker comment. Run: scripts/ac_closeout.sh $ac_pr (idempotent). Or SKIP_HOOKS=ac-closeout SKIP_REASON='<why>' for legitimate edge cases." ;;
              2) audit_log warn ac-closeout notice "indeterminate (gh timeout / missing / malformed); merge allowed per fail-open" ;;
            esac
          else
            audit_log warn ac-closeout notice "could not resolve PR number from cmd or current branch; merge allowed per fail-open"
          fi
        fi
      fi
    fi

    # Force push
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}push\b.*(\-f\b|\-\-force\b|\-\-force-with-lease\b)"; then
      should_skip force-push || block force-push "force push blocked"
    fi

    # Direct push to protected branch
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}push\b.*\b(${PROTECTED_BRANCH_PATTERN})\b"; then
      should_skip branch || block branch "direct push to protected branch blocked"
    fi

    # --no-verify
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}commit\b.*\-\-no-verify\b"; then
      should_skip no-verify || block no-verify "--no-verify blocked"
    fi

    # --amend (only when the commit is already pushed)
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}commit\b.*\-\-amend\b"; then
      if git rev-parse '@{upstream}' >/dev/null 2>&1; then
        if git merge-base --is-ancestor HEAD '@{upstream}' 2>/dev/null; then
          should_skip amend || block amend "--amend of an already-pushed commit blocked"
        fi
      fi
    fi

    # git commit body: protected branch / commit format / secrets / lint
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}commit\b" \
       && ! printf '%s' "$cmd" | grep -qE '\-\-allow-empty\b' ; then
      if is_protected_branch; then
        should_skip branch || block branch "commit on protected branch ($(branch_label)) blocked"
      fi
      subj=$(extract_commit_subject "$raw_cmd" "$cmd")
      if [ -n "$subj" ]; then
        err=$(check_commit_subject "$subj" 2>&1) || {
          should_skip commit-format || block commit-format "$err"
        }
      fi
      if ! err=$(scan_staged_secrets 2>&1); then
        should_skip secret || block secret "$err"
      fi
      lint=$(detect_lint_cmd)
      if [ -n "$lint" ]; then
        if ! run_bounded_lint "$lint" >/dev/null 2>&1; then
          should_skip format || block format "lint failed or timed out (CLAUDE_ENG_LINT_TIMEOUT=${CLAUDE_ENG_LINT_TIMEOUT:-30}s): $lint"
        fi
      fi
    fi
    ;;

  Edit|Write|MultiEdit)
    target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
    [ -z "$target" ] && exit 0

    # Shell self-modification: skip all checks.
    case "$target/" in "$SHELL_ROOT"/*) exit 0 ;; esac

    # Edit on protected branch
    if is_protected_branch; then
      should_skip branch || block branch "edit on protected branch blocked: $target"
    fi

    # Outside registry
    if ! path_in_scope "$target"; then
      should_skip out-of-scope || block out-of-scope "edit outside registry blocked: $target"
    fi

    # Sensitive files
    base=$(basename "$target")
    case "$base" in
      .env|.env.*|*.pem|credentials|credentials.*|id_rsa|id_rsa.*|id_ed25519|id_ed25519.*)
        should_skip sensitive || block sensitive "sensitive file edit blocked: $target"
        ;;
    esac
    ;;
esac

exit 0
