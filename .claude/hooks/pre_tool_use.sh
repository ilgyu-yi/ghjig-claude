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

    # Parse the SPEC §7 TRAILING-sentinel escape (`# claude-eng:skip=<cat>
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

    # Destructive command with out-of-scope path arg. Entry pre-filter: an
    # rm/mv/cp verb followed (within its own option run) by a force OR recursive
    # flag in any surface form — clustered (-rf), separated (-r -f), long
    # (--force/--recursive), or non-first (-i -rf). Anchored to the verb's
    # option run so a flag belonging to another pipeline command does not
    # trigger it (#212). Over-entry is harmless: check_destructive_args allows
    # in-scope/non-destructive operands.
    if printf '%s' "$cmd" | grep -qE '\b(rm|mv|cp)\s+((-[A-Za-z]+|--[a-z-]+)\s+)*(-[A-Za-z]*[fFrR][A-Za-z]*|--force|--recursive)'; then
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
        else
          # safe_source emitted helper-missing warn already
          decided=1
        fi
      fi
      [ -z "$decided" ] && pass_through_trace ac-closeout "$cmd"
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
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+issue[[:space:]]+(close|edit)\b'; then
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
        tfm_edit_sel_re='gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+["'"'"']?([0-9]+|[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]"'"'"']+)'
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
        elif tfm_close_sel_re='gh[[:space:]]+issue[[:space:]]+close[[:space:]]+["'"'"']?([0-9]+|[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]"'"'"']+)'
             [[ "$cmd" =~ $tfm_close_sel_re ]]; then
          # Normalize the selector to a pure issue number (#223): gh accepts a
          # URL or quoted number, but is_trusted_filer / the cache key / the
          # block message all need a bare number (is_trusted_filer returns
          # "not trusted" → fail-open on any non-number). For a URL, take the
          # segment after the LAST `/issues/` (so `…/issues/55/issues/100` →
          # 100, matching gh's target) then its leading digits; otherwise strip
          # to digits. Pure parameter expansion — no second `=~`, so no
          # BASH_REMATCH clobber.
          tf_sel="${BASH_REMATCH[1]}"
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
          tf_completed=
          tf_not_planned=
          if [[ "$cmd" =~ --reason[[:space:]]+completed ]]; then tf_completed=1; fi
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
    if printf '%s' "$cmd" | grep -qE '\bgh[[:space:]]+issue[[:space:]]+edit[[:space:]]+[0-9]+\b.*--add-label\b'; then
      decided=
      if should_skip label-parent-consistency; then
        decided=1
      else
        lpc_issue=
        if [[ "$cmd" =~ gh[[:space:]]+issue[[:space:]]+edit[[:space:]]+([0-9]+) ]]; then
          lpc_issue="${BASH_REMATCH[1]}"
        fi
        # Which gated type label is being added? Only execution/task/bug are
        # gated; accept space- or =-separated, optionally quoted, and the gated
        # token anywhere in a comma-joined value list (--add-label other,execution)
        # via the leading `([^"' ]*,)?` prefix (#212). NOTE: that prefix is a
        # capture group, so the gated label is BASH_REMATCH[2], not [1].
        # Gated labels: execution/task/bug (parent-marker consistency, #199) plus
        # the two tier type-keys initiative/directive (#251). The gated token is
        # BASH_REMATCH[2] (the leading `([^"' ]*,)?` comma-prefix is group 1).
        lpc_label=
        lpc_label_re='--add-label[=[:space:]]+["'"'"']?([^"'"'"' ]*,)?(execution|task|bug|initiative|directive)([^a-z]|$)'
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
          elif [ "$lpc_label" = initiative ] && is_directive_issue "$lpc_issue"; then
            block label-parent-consistency "Issue #${lpc_issue}: --add-label initiative on a Directive is blocked — the 'initiative' and 'directive' tier type-keys are mutually exclusive (SPEC §1.7). An Issue is a Directive or an Initiative, not both. Or SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>'."
          elif [ "$lpc_label" = directive ] && is_initiative_issue "$lpc_issue"; then
            block label-parent-consistency "Issue #${lpc_issue}: --add-label directive on an Initiative is blocked — the 'directive' and 'initiative' tier type-keys are mutually exclusive (SPEC §1.7). Or SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>'."
          elif [ "$lpc_label" = directive ]; then
            # (b) parent-XOR: a Directive needs exactly one parent kind — a
            # `## MISSION fit` field XOR a line-1 `Parent Initiative: #N` marker.
            if ! command -v issue_has_mission_fit_field >/dev/null 2>&1 \
               || ! command -v issue_has_initiative_parent_marker >/dev/null 2>&1; then
              mark_allow label-parent-consistency
              decided=1
            else
              issue_has_mission_fit_field "$lpc_issue"; lpc_mf=$?
              issue_has_initiative_parent_marker "$lpc_issue"; lpc_im=$?
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
          issue_has_parent_marker "$lpc_issue"
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
        iro_issue=
        iro_sel_re='gh[[:space:]]+issue[[:space:]]+(edit|close|reopen)[[:space:]]+["'"'"']?([0-9]+|[Hh][Tt][Tt][Pp][Ss]?://[^[:space:]"'"'"']+)'
        if [[ "$cmd" =~ $iro_sel_re ]]; then
          iro_sel="${BASH_REMATCH[2]}"
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
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}push\b.*(\-f\b|\-\-force\b|\-\-force-with-lease\b)"; then
      decided=
      # Protected-token presence + ref-set flags, computed off the `if printf|grep`
      # form so the §39b structural sweep counts only the one matcher-entry line
      # above. Case-insensitive (`-i`): a remote `MAIN`/`Main` collides with `main`
      # on case-insensitive filesystems (default macOS/Windows), so a case-folded
      # name is still a protected-clobber path.
      fp_protected=
      printf '%s' "$cmd" | grep -qiE "\b(${PROTECTED_BRANCH_PATTERN})\b" && fp_protected=1
      # --mirror/--all/--branches push EVERY ref (incl. protected) with no single
      # verifiable target — and --mirror deletes remote refs absent locally. They
      # carry no explicit branch to check, so they fall under the same
      # "target can't be confirmed non-protected → block" fail-safe as a bare push.
      fp_refset=
      printf '%s' "$cmd" | grep -qE '(^|[[:space:]])--(mirror|all|branches)([[:space:]]|=|$)' && fp_refset=1
      if should_skip force-push; then
        decided=1
      elif [ -n "$fp_protected" ]; then
        block force-push "force push to a protected branch (${PROTECTED_BRANCH_PATTERN//|/, }) blocked"
      elif [ -n "$fp_refset" ]; then
        block force-push "force push with --mirror/--all/--branches is blocked: it targets every ref (including protected branches) with no verifiable single target. Name one branch: 'git push --force-with-lease origin <branch>'. Or SKIP_HOOKS=force-push SKIP_REASON='<why>'."
      else
        # Count positional (non-flag) tokens after `push`. An explicit
        # <remote> <refspec> pair (>=2 positionals) means the target is named
        # and — with no protected token present above — verified non-protected.
        # Skip values of the value-taking push flags so they aren't miscounted
        # as positionals (would over-count and wrongly allow a bare push).
        fp_positionals=0
        fp_seen_push=
        fp_skip_next=
        read -ra fp_arr <<< "$cmd"
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
        if [ "$fp_positionals" -ge 2 ]; then
          # Explicit <remote> <refspec>, non-protected → the rebase-pull tail. Allow.
          mark_allow force-push
          decided=1
        else
          block force-push "force push needs an explicit target branch: use 'git push --force-with-lease origin <branch>'. A bare or remote-only force-push is blocked because its real destination is config-dependent (push.default / upstream tracking) and can't be confirmed non-protected. Or SKIP_HOOKS=force-push SKIP_REASON='<why>'."
        fi
      fi
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
    # No --allow-empty carve-out (#209): an empty commit is still a
    # protected-branch write and still carries a subject; the secret/lint
    # sub-checks are harmless no-ops on an empty staged set. Excluding it
    # skipped all four gates in one flag.
    if printf '%s' "$cmd" | grep -qE "${GIT_PREFIX}commit\b" ; then
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

    # Shell self-modification carve-out (#210): paths under
    # $CLAUDE_ENG_SHELL_ROOT/ skip the branch + out-of-scope checks (the
    # shell legitimately edits its own substrate, which is outside the
    # target repo's branch/registry model). It must NOT early-exit before
    # the sensitive-file check below: writing a .env / *.pem / credentials*
    # under the shell root is just as bad, and CLAUDE.md / SPEC §6.1/§14
    # document the sensitive check as firing under BOTH carve-outs. So we
    # set a flag (mirroring the $HOME/.claude/ carve-out) and fall through.
    shell_self_mod=
    case "$target/" in "$SHELL_ROOT"/*) shell_self_mod=1 ;; esac

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
    sens_hit=
    case "$base" in
      .env|.env.*|*.pem|credentials|credentials.*|id_rsa|id_rsa.*|id_ed25519|id_ed25519.*) sens_hit=1 ;;
    esac
    if [ -z "$sens_hit" ] && [ -n "$sens_resolved" ]; then
      case "$sens_resolved" in
        .env|.env.*|*.pem|credentials|credentials.*|id_rsa|id_rsa.*|id_ed25519|id_ed25519.*) sens_hit=1 ;;
      esac
    fi
    if [ -n "$sens_hit" ]; then
      should_skip sensitive || block sensitive "sensitive file edit blocked: $target${sens_resolved:+ (symlink to a sensitive target)}"
    fi
    ;;
esac

exit 0
