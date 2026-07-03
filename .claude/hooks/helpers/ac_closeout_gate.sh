# shellcheck shell=bash
# helpers/ac_closeout_gate.sh — `gh pr merge` AC-closeout gate logic.
# Sourced by pre_tool_use.sh and (optionally) by scripts/ac_closeout.sh.
#
# Public:
#   extract_pr_from_merge_cmd <cmd> — print the first integer argv to
#     `gh pr merge` and return 0, or print nothing and return 1 if the
#     cmd has no explicit PR number. Tolerates flags between `merge`
#     and the number.
#   pr_needs_closeout <pr-num> — query gh for the PR's
#     `closingIssuesReferences`; for each linked issue, check whether
#     it has unchecked AC and lacks a `^## AC closeout` header comment.
#     Returns: 0 = needs closeout (block), 1 = allows, 2 = indeterminate.
#     gh calls are bounded by `timeout 5` (or `gtimeout 5` on macOS;
#     unbounded fallback if neither is present). Indeterminate maps to
#     allow in the caller (fail-open per SPEC §6.1).

extract_pr_from_merge_cmd() {
  local cmd="$1"
  local rest token skip_next=""
  # Strip up to and including `gh pr merge`; the remainder is the argv.
  # No `\b` — BSD sed (macOS) doesn't recognize it. The grep matcher in
  # pre_tool_use.sh already validated that `gh pr merge` is present as a
  # token (with end-anchor so `merge-queue` doesn't slip past), so plain
  # `.*gh[[:space:]]+pr[[:space:]]+merge` is sufficient.
  # #499: also strip a leading gh global-flag run (`gh --repo o/r pr merge …`)
  # so the argv after `pr merge` is captured for the leading-flag forms.
  rest=$(printf '%s' "$cmd" | sed -nE 's/.*gh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge//p')
  # Collapse runs of whitespace so word-split picks tokens cleanly.
  rest=$(printf '%s' "$rest" | tr -s '[:space:]')
  # `set -f` disables pathname expansion so a literal `*` in cmd args
  # (extremely unlikely for `gh pr merge` but defensive — matches the
  # check_destructive_args style in pre_tool_use.sh).
  local _opts=$-
  set -f
  for token in $rest; do
    if [ -n "$skip_next" ]; then skip_next=""; continue; fi
    case "$token" in
      # #500: value-taking flags consume their next token — mirror
      # parse_gh_merge_argv exactly, so a `/pull/N` inside a --body/--subject
      # VALUE is not mis-read as the PR selector (security-review finding).
      --body|-b|--body-file|--subject|-t|--match-head-commit|--author-email|--repo|-R) skip_next=1; continue ;;
      -*) continue ;;
      */pull/*)   # #500: a PR URL selector (`…/pull/N`) — gh accepts it for
                  # `gh pr merge`. Take the digits after the LAST `/pull/`; the
                  # sibling merge-strategy parser (parse_gh_merge_argv) already
                  # handles this form, so without it ac-closeout diverged and
                  # evaluated the wrong (current-branch) PR.
        token="${token##*/pull/}"; token="${token%%[!0-9]*}"
        [ -n "$token" ] && { case "$_opts" in *f*) ;; *) set +f ;; esac; printf '%s' "$token"; return 0; }
        continue ;;
      *[!0-9]*) continue ;;   # only pure-integer tokens count as PR number
      [0-9]*) case "$_opts" in *f*) ;; *) set +f ;; esac; printf '%s' "$token"; return 0 ;;
    esac
  done
  case "$_opts" in *f*) ;; *) set +f ;; esac
  return 1
}

# _ac_run_gh <args...> — wrap a gh call in `timeout 5`; emit to stdout.
# Returns gh's exit code (or 124 on timeout). Fallback to unbounded gh
# if no timeout binary is on PATH.
_ac_run_gh() {
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  fi
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" 5 gh "$@"
  else
    gh "$@"
  fi
}

# parse_gh_merge_argv <cmd> — gh-flag-aware parse of a `gh pr merge` command for
# the merge-strategy matcher (#290). Echoes "<strategy>\t<pr>":
#   strategy ∈ merge|squash|rebase|bare — the explicit strategy FLAG token
#     (`--merge`/`-m`, `--squash`/`-s`, `--rebase`/`-r`), NOT a substring, so a
#     `--merge` inside a `--body`/`--subject` *value* is not read as the strategy
#     (#290 A) and the short `-m` is recognized as compliant (#290 C).
#   pr = the first POSITIONAL token (or a `.../pull/N` URL's N), skipping
#     value-taking flags' values (#290 B); empty if the command names none
#     (caller falls back to the current branch's PR).
# Shell-aware tokenization (python3 `shlex`, mirroring check_destructive_args)
# so a quoted multi-word flag value stays one token; `read -ra` fallback when
# python3 is absent (imperfect only for a multi-word quoted value containing a
# bare `--merge`/`-m` token — the degraded path). An unparseable command
# (unclosed quote — which would not execute in a real shell) yields strategy=bare
# so the caller takes the conservative base-resolution path.
parse_gh_merge_argv() {
  local cmd="$1" rest
  # #499: strip a leading gh global-flag run too (see extract_pr_from_merge_cmd).
  rest=$(printf '%s' "$cmd" | sed -nE 's/.*gh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge//p')
  local -a toks=()
  if command -v python3 >/dev/null 2>&1; then
    local _out
    if _out=$(printf '%s' "$rest" | python3 -c '
import shlex, sys
try:
    for t in shlex.split(sys.stdin.read()):
        print(t)
except ValueError:
    sys.exit(2)
' 2>/dev/null); then
      local _t
      while IFS= read -r _t; do [ -n "$_t" ] && toks+=("$_t"); done <<< "$_out"
    else
      printf 'bare\t'; return 0
    fi
  else
    local IFS=$' \t\n' _o=$-
    set -f
    read -ra toks <<< "$rest"
    case "$_o" in *f*) ;; *) set +f ;; esac
  fi
  local strategy=bare pr="" skip_next="" t i
  for ((i=0; i<${#toks[@]}; i++)); do
    t="${toks[$i]}"
    if [ -n "$skip_next" ]; then skip_next=""; continue; fi
    case "$t" in
      --merge|-m)   strategy=merge ;;
      --squash|-s)  strategy=squash ;;
      --rebase|-r)  strategy=rebase ;;
      # Value-taking flags consume their following token (so a value is never
      # mistaken for the PR or a strategy flag). `--flag=value` is one token.
      --body|-b|--body-file|--subject|-t|--match-head-commit|--author-email|--repo|-R) skip_next=1 ;;
      --*=*) : ;;
      -*) : ;;   # other boolean flags (--auto/--admin/--delete-branch/-d/--disable-auto): no value
      *)
        if [ -z "$pr" ]; then
          case "$t" in
            */pull/*) pr="${t##*/pull/}"; pr="${pr%%[!0-9]*}" ;;
            *[!0-9]*) ;;   # non-integer positional → ignore
            *) pr="$t" ;;
          esac
        fi
        ;;
    esac
  done
  printf '%s\t%s' "$strategy" "$pr"
}

# is_pr_merge_command <cmd> — refine the coarse `gh pr merge` substring grep
# (#340). Returns 0 when the `gh … pr … merge` command WORDS survive stripping
# of heredoc bodies and quoted string literals from a copy of the command, i.e.
# this really is a merge invocation. Returns 1 when the words appear only as
# DATA — a heredoc body, a quoted `--body`/`-m` value, a commit message — so the
# merge gates (ac-closeout / merge-strategy) must NOT engage.
#   FAIL-CLOSED: python3 absent, a strip/parse error, or an unclosed quote →
#   return 0 (treat as a merge), so a real merge is never let through by a
#   stripping failure. Deliberate residuals (contrived, and the gate is escapable
#   anyway): a merge wrapped in an executed quoted string (`bash -c "gh pr merge
#   …"`) and a quote-concatenated form (`gh' 'pr' 'merge`) are both stripped and
#   thus not detected — neither was caught by the pre-#340 coarse grep either.
#   `<<<` here-strings are treated as data (a same-line operand), not heredocs.
# Pass the RAW (pre-normalization) command so heredoc newlines are intact —
# pre_tool_use.sh flattens `\n`→space before the matchers run.
is_pr_merge_command() {
  local cmd="$1" stripped
  # Strip heredoc bodies + quoted literals (full mode) via the shared helper
  # (#366 factored this out of the former inline python; behavior preserved).
  # strip_command_data is fail-closed: python3 absent / unclosed quote / parse
  # error returns the cmd UNCHANGED, so the grep below still sees a genuine
  # `gh pr merge` and the gate engages — a stripping failure never lets a real
  # merge through (#340). If the helper itself is somehow absent, fall back to
  # the raw cmd (same fail-closed direction).
  if command -v strip_command_data >/dev/null 2>&1; then
    stripped=$(strip_command_data "$cmd")
  else
    stripped="$cmd"
  fi
  # The `gh … pr … merge` command words must survive stripping (mirrors the
  # coarse entry grep). Present on the residue → a real merge; absent → the words
  # appeared only as DATA (heredoc body / quoted value / commit message).
  # #499: tolerate a leading gh global-flag run before `pr merge` (the entry
  # anchor in pre_tool_use.sh was widened the same way); `pr merge` must stay
  # ADJACENT after the run so a `pr create` body containing `merge` is not read
  # as a merge command.
  printf '%s' "$stripped" | grep -qE '\bgh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge([[:space:]]|$)' && return 0
  return 1
}

pr_needs_closeout() {
  local pr="$1"
  [ -z "$pr" ] && return 2
  command -v gh >/dev/null 2>&1 || return 2

  local issues rc
  issues=$(_ac_run_gh pr view "$pr" --json closingIssuesReferences -q '.closingIssuesReferences[].number' 2>/dev/null)
  rc=$?
  [ "$rc" != 0 ] && return 2
  [ -z "$issues" ] && return 1  # no linked issues → allow

  local n body comments
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    body=$(_ac_run_gh issue view "$n" --json body -q .body 2>/dev/null)
    rc=$?
    [ "$rc" != 0 ] && return 2
    # No unchecked AC on this issue → it's fine. #500: recognize all common
    # GitHub task-list bullets (`-`/`*`/`+` and ordered `N.`), optionally
    # indented — not just `- [ ]` — so an unchecked box written another way
    # isn't mistaken for AC-clean.
    if ! printf '%s' "$body" | grep -qE '^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]+\[ \]'; then
      continue
    fi
    # #500: the closeout marker must be (a) the canonical machine shape
    # `## AC closeout (resolved by PR #N)` — a comment that merely starts with
    # `## AC closeout` no longer satisfies the gate — AND (b) authored by a
    # trusted filer (OWNER/MEMBER/MAINTAINER/COLLABORATOR), so a drive-by comment
    # from an untrusted account cannot unlock the merge. The author filter runs
    # as a jq `select` at the gh boundary; only trusted comment bodies return.
    comments=$(_ac_run_gh issue view "$n" --json comments \
      -q '.comments[] | select((.authorAssociation // "") | (. == "OWNER" or . == "MEMBER" or . == "MAINTAINER" or . == "COLLABORATOR")) | .body' 2>/dev/null)
    rc=$?
    [ "$rc" != 0 ] && return 2
    # Canonical marker from a trusted author present → covered.
    if printf '%s' "$comments" | grep -qE '^## AC closeout \(resolved by PR #[0-9]+\)'; then
      continue
    fi
    # Any one issue missing the marker triggers the block.
    return 0
  done <<< "$issues"

  return 1
}

# local_ahead_of_pr <branch> — push-parity check (#244, SPEC §6.1). Returns 0
# (block) ONLY when the local branch is STRICTLY AHEAD of its pushed remote-
# tracking head — i.e. the merge would leave unpushed local commits behind:
#   origin/<branch> exists locally, is an ANCESTOR of HEAD, and the two SHAs
#   differ. git-only + zero-network (reads refs/remotes/origin/<branch>; never
#   fetches). Every other state — behind / diverged / no-upstream / detached /
#   absent-local / not-a-worktree / git-absent — returns 1 (allow), so ONLY the
#   strictly-ahead state blocks (positive detection). set -u-safe.
local_ahead_of_pr() {
  local branch="${1:-}"
  [ -n "$branch" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local remote_ref="refs/remotes/origin/$branch"
  # Upstream must resolve locally (no network). Absent → not ahead.
  local remote_sha local_sha
  remote_sha=$(git rev-parse --verify --quiet "$remote_ref" 2>/dev/null) || return 1
  local_sha=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
  [ -n "$remote_sha" ] && [ -n "$local_sha" ] || return 1
  [ "$remote_sha" = "$local_sha" ] && return 1          # in-sync → allow
  # Strictly ahead iff the remote head is an ancestor of the local HEAD.
  # behind / diverged → the remote is NOT an ancestor → allow.
  git merge-base --is-ancestor "$remote_ref" HEAD 2>/dev/null || return 1
  return 0
}

# attestation_matches <pr> <head> — merge-attestation staleness check (#246,
# #543, SPEC §6.1). Returns 0 iff $(ghjig_state_dir)/attest/pr-<pr> exists AND
# its recorded `head=<sha>` equals <head>. Presence (file exists at all) is a
# separate zero-network fact the caller checks WITHOUT <head>; this predicate
# additionally requires the head to match. set -u-safe (empty state-dir / pr /
# head → 1, never a crash).
attestation_matches() {
  local pr="${1:-}" head="${2:-}"
  [ -n "$pr" ] && [ -n "$head" ] || return 1
  local esd; esd=$(ghjig_state_dir 2>/dev/null) || esd=""
  [ -n "$esd" ] || return 1
  local f="$esd/attest/pr-$pr"
  [ -f "$f" ] || return 1
  local recorded
  recorded=$(sed -n 's/^head=//p' "$f" 2>/dev/null | head -1)
  [ -n "$recorded" ] || return 1
  [ "$recorded" = "$head" ]
}

# write_review_attestation <pr> <head> — record that PR <pr>'s review passed at
# <head>. Writes `head=<sha>` to $(ghjig_state_dir)/attest/pr-<pr> (mkdir -p the
# dir). Called by /ship strictly AFTER the blind-compare pass (an aborted review
# writes nothing). set -u-safe: empty state-dir / pr / head → no-op + return 1,
# never a crash.
write_review_attestation() {
  local pr="${1:-}" head="${2:-}"
  [ -n "$pr" ] && [ -n "$head" ] || return 1
  local esd; esd=$(ghjig_state_dir 2>/dev/null) || esd=""
  [ -n "$esd" ] || return 1
  mkdir -p "$esd/attest" 2>/dev/null || return 1
  printf 'head=%s\n' "$head" > "$esd/attest/pr-$pr"
}
