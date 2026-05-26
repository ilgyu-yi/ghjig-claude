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
safe_source "$SHELL_ROOT/.claude/hooks/helpers/issue_type.sh"           directive-protect || true
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
      decided=
      audit_log warn bypass-suspect notice "$cmd"
      decided=1
      # Tail no-op for an always-emits matcher; the pass_through_trace symbol
      # is kept so the §39b structural sweep sees the uniform shape across
      # all matchers (SPEC §6.1 invariant safety net).
      [ -z "$decided" ] && pass_through_trace bypass-suspect "$cmd"
    fi

    # Destructive command with out-of-scope path arg
    if printf '%s' "$cmd" | grep -qE '\b(rm|mv|cp)\s+(-[A-Za-z]*[fF][A-Za-z]*\s+)+'; then
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
      should_skip destructive && decided=1 || block destructive "git reset --hard blocked"
      [ -z "$decided" ] && pass_through_trace destructive "$cmd"
    fi
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}clean\s+-[A-Za-z]*f"; then
      decided=
      should_skip destructive && decided=1 || block destructive "git clean -f blocked"
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
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
      decided=
      if should_skip ac-closeout; then
        decided=1
      else
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
              0)
                # Type-awareness (SPEC §1.7, §6.1) — if the linked closing issue
                # is a Directive, the AC-closeout gate doesn't apply (Directives
                # close via /complete-directive + directive-reviewer, not by AC
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
        else
          # safe_source emitted helper-missing warn already
          decided=1
        fi
      fi
      [ -z "$decided" ] && pass_through_trace ac-closeout "$cmd"
    fi

    # directive-protect — block branch-creation referencing a Directive Issue
    # (SPEC §1.7, §6.1). The branch-name convention <user>/<type>/<N>-<slug>
    # (CLAUDE.md / SPEC §10.1) encodes the issue number; we extract <N> and
    # check is_directive_issue. If yes, refuse the branch creation with a
    # redirect to /activate-directive (if Planned) or /file-issue --parent
    # (if Active).
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}checkout[[:space:]]+-b[[:space:]]+[A-Za-z0-9._-]+/[a-z]+/[0-9]+-"; then
      decided=
      if should_skip directive-protect; then
        decided=1
      elif command -v is_directive_issue >/dev/null 2>&1; then
        # Extract the issue number via bash builtin regex. GIT_PREFIX uses
        # PCRE-style \b/\s/\S that sed -E (BSD/macOS) doesn't support; bash
        # =~ uses POSIX ERE which is fine for this branch-name shape.
        dp_issue=
        if [[ "$cmd" =~ checkout[[:space:]]+-b[[:space:]]+[A-Za-z0-9._-]+/[a-z]+/([0-9]+)- ]]; then
          dp_issue="${BASH_REMATCH[1]}"
        fi
        if [ -n "$dp_issue" ] && is_directive_issue "$dp_issue"; then
          block directive-protect "Issue #${dp_issue} is a Directive (Type=Directive, SPEC §1.7). Directives do not branch into engineering PRs. Use /activate-directive ${dp_issue} (if Planned) or /file-issue --parent ${dp_issue} (if Active). Or SKIP_HOOKS=directive-protect SKIP_REASON='<why>' for legitimate edge cases."
        else
          # Either issue # is not a Directive, or is_directive_issue failed
          # (gh down, no auth) — fail-open per SPEC §6.1.
          mark_allow directive-protect
          decided=1
        fi
      else
        # helper missing → safe_source already warned at file top; fail-open.
        mark_allow directive-protect
        decided=1
      fi
      [ -z "$decided" ] && pass_through_trace directive-protect "$cmd"
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
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+issue[[:space:]]+(close|edit)\b'; then
      decided=
      if should_skip trusted-filer-mutate; then
        decided=1
      else
        # Sub-arm b: `gh issue edit <N> --remove-label directive` blocks
        # on any filer, no `is_trusted_filer` resolution needed.
        if [[ "$cmd" =~ gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+([0-9]+).*--remove-label[[:space:]]+directive ]]; then
          block trusted-filer-mutate "Removing the 'directive' label declassifies an Issue and bypasses dir-mode review. Human-confirm required always (SPEC §1.5 filer-aware invariants). Or SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='<why>' for legitimate edge cases."
        # Sub-arm a: `gh issue close <N>` without `--reason completed`.
        elif [[ "$cmd" =~ gh[[:space:]]+issue[[:space:]]+close[[:space:]]+([0-9]+) ]]; then
          tf_issue="${BASH_REMATCH[1]}"
          tf_completed=
          if [[ "$cmd" =~ --reason[[:space:]]+completed ]]; then tf_completed=1; fi
          if [ -z "$tf_completed" ] && command -v is_trusted_filer >/dev/null 2>&1; then
            if is_trusted_filer "$tf_issue"; then
              block trusted-filer-mutate "Issue #${tf_issue} was authored by a trusted filer (OWNER / MEMBER / MAINTAINER / COLLABORATOR). Closing without --reason completed (i.e., not-planned or duplicate) requires human confirm. Use 'gh issue close ${tf_issue} --reason completed' if evidence of completion exists, or SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='<why>' for legitimate edge cases."
            else
              mark_allow trusted-filer-mutate
              decided=1
            fi
          else
            # --reason completed OR helper unavailable → fail-open per §6.1.
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

    # Force push
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}push\b.*(\-f\b|\-\-force\b|\-\-force-with-lease\b)"; then
      decided=
      should_skip force-push && decided=1 || block force-push "force push blocked"
      [ -z "$decided" ] && pass_through_trace force-push "$cmd"
    fi

    # Direct push to protected branch
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}push\b.*\b(${PROTECTED_BRANCH_PATTERN})\b"; then
      decided=
      should_skip branch && decided=1 || block branch "direct push to protected branch blocked"
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
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}commit\b" \
       && ! printf '%s' "$cmd" | grep -qE '\-\-allow-empty\b' ; then
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
      if ! err=$(scan_staged_secrets 2>&1); then
        should_skip secret && decided=1 || block secret "$err"
      fi
      lint=$(detect_lint_cmd)
      if [ -n "$lint" ]; then
        if ! run_bounded_lint "$lint" >/dev/null 2>&1; then
          should_skip format && decided=1 || block format "lint failed or timed out (CLAUDE_ENG_LINT_TIMEOUT=${CLAUDE_ENG_LINT_TIMEOUT:-30}s): $lint"
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

    # Shell self-modification: skip all checks.
    case "$target/" in "$SHELL_ROOT"/*) exit 0 ;; esac

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
    case "$target/" in
      "$HOME"/.claude/*) user_global_memory=1 ;;
    esac

    # Edit on protected branch
    if is_protected_branch && [ -z "$user_global_memory" ]; then
      should_skip branch || block branch "edit on protected branch blocked: $target"
    fi

    # Outside registry
    if [ -z "$user_global_memory" ] && ! path_in_scope "$target"; then
      should_skip out-of-scope || block out-of-scope "edit outside registry blocked: $target"
    fi

    # Sensitive files — applies regardless of user_global_memory.
    base=$(basename "$target")
    case "$base" in
      .env|.env.*|*.pem|credentials|credentials.*|id_rsa|id_rsa.*|id_ed25519|id_ed25519.*)
        should_skip sensitive || block sensitive "sensitive file edit blocked: $target"
        ;;
    esac
    ;;
esac

exit 0
