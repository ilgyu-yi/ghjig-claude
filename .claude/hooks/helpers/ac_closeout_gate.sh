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

# _ac_repo_host — derive the repo's HOST from `gh repo view --json url` so the
# host-LESS `gh api` calls below can be pinned to the repo host instead of gh's
# DEFAULT host (github.com). `gh api` does NO repo inference; on a GHES target an
# unpinned `gh api` hits github.com → the review is unreadable and identities
# mismatch (a self-merge bypass). The url is gh's NORMALIZED https url, so the
# chop sidesteps SSH/HTTPS remote parsing; `nameWithOwner,url` is queried (the
# `.url` field) so the JSON shape matches the sibling nameWithOwner read.
# Echoes the validated host on success; echoes NOTHING and returns non-zero on an
# unusable (empty / invalid-charset) host — the caller fails CLOSED, NEVER a
# silent default-host fallback (which would reintroduce the bypass). Timeout-
# bounded via _ac_run_gh (#610).
_ac_repo_host() {
  local url h rc
  url=$(_ac_run_gh repo view --json nameWithOwner,url -q .url 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1
  h=${url#*://}; h=${h#*@}; h=${h%%/*}
  case "$h" in
    ''|*[!A-Za-z0-9.:-]*) return 1 ;;
  esac
  printf '%s' "$h"
}

# is_covered_ship_merge_form <cmd> — returns 0 iff the argv AFTER `gh pr merge`
# is EXACTLY the covered ship form `--auto --merge --delete-branch`
# (settings.json permissions.allow entry, #592). Uses the same sed-strip idiom as
# extract_pr_from_merge_cmd (tolerating a leading gh global-flag run), then
# whitespace-collapses and trims the remainder before an exact string compare.
# Non-zero for any deviation: an extra flag, a reordered flag run, a positional PR
# number, a wrong strategy (`--squash`/`--rebase`), or the bare form. This is the
# form half of the bypass backstop (the self-merge half is merge_is_self).
is_covered_ship_merge_form() {
  local cmd="$1" rest
  rest=$(printf '%s' "$cmd" | sed -nE 's/.*gh[[:space:]]+(-{1,2}[A-Za-z][^[:space:]]*([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*pr[[:space:]]+merge//p')
  rest=$(printf '%s' "$rest" | tr -s '[:space:]' ' ')
  rest="${rest# }"; rest="${rest% }"
  [ "$rest" = '--auto --merge --delete-branch' ]
}

# merge_is_self <pr> — is this merge an AGENT SELF-MERGE (the PR author is also the
# merger)? Mirrors review_gate_accepts' author/merger resolution: the PR author via
# `gh pr view <pr> --json author`, the merger via `gh api user`, both timeout-bounded
# through _ac_run_gh. Returns:
#   0 — author == merger (self-merge)
#   1 — author != merger (a human/other merger)
#   2 — INDETERMINATE: empty PR, gh absent, or any gh lookup failure (error/
#       timeout/down/empty) — the caller fails CLOSED on 2 (§5.7.1, #592).
merge_is_self() {
  local pr="$1" rc pr_author merger h
  [ -n "$pr" ] || return 2
  command -v gh >/dev/null 2>&1 || return 2
  pr_author=$(_ac_run_gh pr view "$pr" --json author -q .author.login 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 2
  [ -n "$pr_author" ] || return 2
  # Resolve the merger identity AT THE REPO HOST; an unusable host is INDETERMINATE
  # (return 2 → the caller blocks), never a silent default-host fallback (#610).
  h=$(_ac_repo_host) || return 2
  [ -n "$h" ] || return 2
  merger=$(_ac_run_gh api user --hostname "$h" -q .login 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 2
  [ -n "$merger" ] || return 2
  [ "$pr_author" = "$merger" ] && return 0
  return 1
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

# merge_completeness_probe <pr> — single bounded `gh pr view` round-trip feeding
# BOTH the type gate and the source-vs-test/doc classification for the
# merge-completeness advisory arm (#548, SPEC §6.1 'merge-completeness' row).
# Echoes "<type>\t<zero_source>":
#   <type>        feat|fix — resolved from the PR headRefName (`<user>/(feat|fix)/…`),
#                 with a PR-title conventional-commit prefix fallback
#                 (`feat:`/`feat(…)`/`feat!:`, likewise `fix`). EMPTY for any other
#                 type — this arm only warns on feat/fix.
#   <zero_source> 1 when the file list is NON-EMPTY and EVERY path is allow-listed
#                 (test/doc) by the reused secret_scan classifier; 0 otherwise
#                 (has source, empty list, or any error).
# ONE gh round-trip total (`--json headRefName,title,files`). Fail-open throughout:
# empty PR / gh absent / gh down / empty JSON / empty file list → "<type>\t0" (no
# warn); the secret_scan classifier missing fails open to has-source (0). NEVER
# errors, NEVER blocks — advisory only.
merge_completeness_probe() {
  local pr="$1"
  local type="" zero_source=0
  [ -z "$pr" ] && { printf '\t0'; return 0; }
  command -v gh >/dev/null 2>&1 || { printf '\t0'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '\t0'; return 0; }

  local json rc
  json=$(_ac_run_gh pr view "$pr" --json headRefName,title,files 2>/dev/null)
  rc=$?
  if [ "$rc" != 0 ] || [ -z "$json" ]; then printf '\t0'; return 0; fi

  local head title
  head=$(printf '%s' "$json" | jq -r '.headRefName // empty' 2>/dev/null)
  title=$(printf '%s' "$json" | jq -r '.title // empty' 2>/dev/null)

  # type: branch `<user>/(feat|fix)/…` first, then the PR-title CC-prefix fallback.
  if printf '%s' "$head" | grep -qE '^[^/]+/feat/'; then
    type=feat
  elif printf '%s' "$head" | grep -qE '^[^/]+/fix/'; then
    type=fix
  elif printf '%s' "$title" | grep -qE '^feat[(!:]'; then
    type=feat
  elif printf '%s' "$title" | grep -qE '^fix[(!:]'; then
    type=fix
  fi

  # Non-feat/fix → the arm will not warn; skip file classification entirely.
  if [ -z "$type" ]; then printf '%s\t0' "$type"; return 0; fi

  local files
  files=$(printf '%s' "$json" | jq -r '.files[]?.path // empty' 2>/dev/null)
  [ -z "$files" ] && { printf '%s\t0' "$type"; return 0; }   # empty list → no warn

  # Reuse the `.shellsecretignore` classifier (no new glob list). safe_source it
  # if the hook context has not already sourced it; fail-open to has-source (0)
  # when the classifier is unavailable.
  if ! command -v secret_scan_path_allowed >/dev/null 2>&1; then
    if command -v safe_source >/dev/null 2>&1; then
      safe_source "${SHELL_ROOT:-}/.claude/hooks/helpers/secret_scan.sh" merge-completeness || true
    fi
  fi
  command -v secret_scan_path_allowed >/dev/null 2>&1 || { printf '%s\t0' "$type"; return 0; }
  command -v _secret_load_allow_list >/dev/null 2>&1 && _secret_load_allow_list

  local f any_source=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! secret_scan_path_allowed "$f"; then any_source=1; break; fi
  done <<< "$files"

  [ "$any_source" = 0 ] && zero_source=1
  printf '%s\t%s' "$type" "$zero_source"
  return 0
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

# review_gate_accepts <pr> <head> — merge-review gate acceptance (#586, SPEC
# §6.1 'merge-review' row, replacing the retired attestation arm #246/#543).
# Returns 0 (ALLOW) iff a passing GitHub review is PINNED TO <head>; 1 (BLOCK)
# otherwise. Reads the review OBJECTS authoritatively via
# `gh api repos/{owner}/{repo}/pulls/<n>/reviews` (state / commit_id /
# author.login per review), owner/repo via `gh repo view --json nameWithOwner`,
# the PR author via `gh pr view <n> --json author`, the merger via `gh api user`.
# All gh calls are timeout-bounded (_ac_run_gh). Identity + head come from the
# object; only `verdict` is read from marker text (bounds a prompt-injection-
# flipped verdict). set -u-safe.
#
# FAIL-CLOSED (return 1) on ANY lookup failure — empty head (B2 guard), gh
# error/timeout/down, malformed JSON, empty result — the deliberate divergence
# from the retired arm's fail-open staleness leg (SPEC §5.7.1: the safe
# direction for a merge integrity gate is to require a review, not skip it).
#
# AGGREGATION (B1): filter reviews to state ∈ {APPROVED, CHANGES_REQUESTED},
# then take each author's LATEST surviving review (by submitted_at). If any
# author's filtered-latest is CHANGES_REQUESTED → BLOCK (COMMENTED/PENDING/
# DISMISSED are dropped BEFORE the per-author-latest, so a later COMMENTED never
# masks an outstanding veto). reviewDecision is NOT consulted (null on
# non-branch-protected repos → would fail open).
# ALLOW in exactly two shapes:
#   (a) native — an APPROVED review with commit_id==head, no outstanding CR.
#   (b) self-marker — a COMMENTED review with commit_id==head carrying EXACTLY
#       ONE `verdict=approve` marker whose review author.login == PR-author ==
#       merger, no outstanding CR. Conflicting / multiple markers → BLOCK (B2).
review_gate_accepts() {
  local pr="${1:-}" head="${2:-}"
  [ -n "$pr" ] || return 1
  [ -n "$head" ] || return 1            # empty head → block (B2 guard)
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local rc

  # owner/repo → the reviews API path.
  local nwo
  nwo=$(_ac_run_gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1
  [ -n "$nwo" ] || return 1

  # Pin the host-LESS gh api calls (the reviews FETCH + the self-marker merger)
  # to the REPO host; else they hit gh's default host (github.com) and a GHES
  # review is unreadable / the merger identity mismatches. Fail CLOSED (not-
  # accepted) on an unusable host — never a silent default-host fallback (#610).
  local h
  h=$(_ac_repo_host) || return 1
  [ -n "$h" ] || return 1

  # The review objects (state / commit_id / author.login per review).
  local reviews
  reviews=$(_ac_run_gh api "repos/$nwo/pulls/$pr/reviews" --hostname "$h" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1
  [ -n "$reviews" ] || return 1
  printf '%s' "$reviews" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1

  # Outstanding CHANGES_REQUESTED? Filter to APPROVED/CHANGES_REQUESTED, take the
  # latest per author, then test whether any survivor is CHANGES_REQUESTED (B1).
  local cr
  cr=$(printf '%s' "$reviews" | jq -r '
    [ .[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED") ]
    | group_by(.author.login // .user.login // "")
    | map(sort_by(.submitted_at) | last | .state)
    | any(. == "CHANGES_REQUESTED")
  ' 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1             # jq error → fail-closed
  [ "$cr" = "true" ] && return 1        # outstanding veto → block

  # (a) native — an APPROVED review pinned to the current head.
  local native
  native=$(printf '%s' "$reviews" | jq -r --arg h "$head" \
    'any(.[]; .state=="APPROVED" and .commit_id==$h)' 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1
  [ "$native" = "true" ] && return 0

  # (b) self-marker — a COMMENTED review at head, author == PR-author == merger,
  # carrying EXACTLY ONE verdict=approve marker (multiple/conflicting → block).
  # Additionally gated on the per-target self-review policy (#598): a self-marker
  # is accepted ONLY when resolve_self_review_policy yields `allow`. Under `deny`
  # (the target default) the self-marker does NOT satisfy the gate — only a native
  # second-party APPROVED (shape (a), already checked above) does. Fail CLOSED to
  # `deny` if the resolver is unavailable (a helper miss must never silently accept
  # a self-approval), mirroring the resolve_review_gate fail-closed posture.
  local self_policy=deny
  if command -v resolve_self_review_policy >/dev/null 2>&1; then
    self_policy=$(resolve_self_review_policy 2>/dev/null || printf 'deny')
  fi
  [ "$self_policy" = allow ] || return 1

  local pr_author merger
  pr_author=$(_ac_run_gh pr view "$pr" --json author -q .author.login 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1
  merger=$(_ac_run_gh api user --hostname "$h" -q .login 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1
  [ -n "$pr_author" ] && [ "$pr_author" = "$merger" ] || return 1

  # Bodies of COMMENTED reviews AT head authored by the (PR-author==merger) self.
  local self_bodies
  self_bodies=$(printf '%s' "$reviews" | jq -r --arg h "$head" --arg who "$pr_author" \
    '.[] | select(.state=="COMMENTED" and .commit_id==$h and ((.author.login // .user.login)==$who)) | .body' \
    2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 1

  # Count ALL file-review markers (any verdict) across those bodies; the only
  # accepting shape is a SINGLE verdict=approve marker — multiple or conflicting
  # markers (e.g. approve + block) fail closed (B2).
  local markers marker_count=0 verdict
  markers=$(printf '%s' "$self_bodies" \
    | grep -oE '<!-- file-review verdict=[A-Za-z]+ head=[^[:space:]]+ reviewer=code-reviewer -->' 2>/dev/null)
  [ -n "$markers" ] && marker_count=$(printf '%s\n' "$markers" | grep -c .)
  [ "$marker_count" = 1 ] || return 1
  verdict=$(printf '%s' "$markers" | sed -nE 's/.*verdict=([A-Za-z]+).*/\1/p')
  [ "$verdict" = approve ] && return 0
  return 1
}
