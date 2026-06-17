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
  local rest token
  # Strip up to and including `gh pr merge`; the remainder is the argv.
  # No `\b` — BSD sed (macOS) doesn't recognize it. The grep matcher in
  # pre_tool_use.sh already validated that `gh pr merge` is present as a
  # token (with end-anchor so `merge-queue` doesn't slip past), so plain
  # `.*gh[[:space:]]+pr[[:space:]]+merge` is sufficient.
  rest=$(printf '%s' "$cmd" | sed -nE 's/.*gh[[:space:]]+pr[[:space:]]+merge//p')
  # Collapse runs of whitespace so word-split picks tokens cleanly.
  rest=$(printf '%s' "$rest" | tr -s '[:space:]')
  # `set -f` disables pathname expansion so a literal `*` in cmd args
  # (extremely unlikely for `gh pr merge` but defensive — matches the
  # check_destructive_args style in pre_tool_use.sh).
  local _opts=$-
  set -f
  for token in $rest; do
    case "$token" in
      -*) continue ;;
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
  rest=$(printf '%s' "$cmd" | sed -nE 's/.*gh[[:space:]]+pr[[:space:]]+merge//p')
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
  local cmd="$1" rc
  command -v python3 >/dev/null 2>&1 || return 0   # fail-closed: no python3 → treat as merge
  printf '%s' "$cmd" | python3 -c '
import sys, re

cmd = sys.stdin.read()

# 1. Strip heredoc bodies. A heredoc opener is `<<` or `<<-` followed by an
#    optionally-quoted delimiter word; `<<<` is a here-string (same-line
#    operand) and is NOT a heredoc, so it is skipped here and handled as a
#    quoted/plain word by step 2.
lines = cmd.split("\n")
delim_re = re.compile(r"<<-?\s*([\"\x27]?)([A-Za-z_][A-Za-z0-9_]*)\1")
out = []
i, n = 0, len(lines)
while i < n:
    line = lines[i]
    delim = None
    for mm in re.finditer(r"<<", line):
        p = mm.start()
        if line[p:p+3] == "<<<":          # here-string, not a heredoc
            continue
        dm = delim_re.match(line[p:])
        if dm:
            delim = dm.group(2)
            break
    out.append(line)
    if delim is not None:
        i += 1
        # `.strip()` is more lenient than bash (bash wants an exact match for
        # `<<`, tabs-only stripping for `<<-`). The divergence is deliberately on
        # the SAFE side: a lenient terminator closes the heredoc earlier-or-equal
        # to bash, so a line bash would execute is never dropped → no MERGE→DATA
        # leak via heredocs.
        while i < n and lines[i].strip() != delim:
            i += 1                         # drop body line (data, not command)
        # keep the terminator line if present — it carries no command words
    i += 1
stripped = "\n".join(out)

# 2. Remove quoted string literals; their interior can never be command words.
def strip_quotes(s):
    res = []
    j, m = 0, len(s)
    while j < m:
        c = s[j]
        if c == "\x27":                    # single quote: literal to next quote
            k = s.find("\x27", j + 1)
            if k == -1:
                return None                # unclosed → ambiguous
            j = k + 1
            continue
        if c == "\"":                      # double quote: honor backslash-escapes
            k = j + 1
            while k < m:
                if s[k] == "\\":
                    k += 2
                    continue
                if s[k] == "\"":
                    break
                k += 1
            if k >= m:
                return None                # unclosed → ambiguous
            j = k + 1
            continue
        res.append(c)
        j += 1
    return "".join(res)

residue = strip_quotes(stripped)
if residue is None:
    sys.exit(2)                            # ambiguous → caller fail-closes to merge

# 3. The command words must survive stripping. Mirror the coarse grep shape
#    (\bgh\s+pr\s+merge followed by whitespace or end). Exit 7 (a reserved,
#    distinguished value) is the ONLY signal for "pure data — not a merge"; the
#    word-match case exits 0. This keeps the caller fail-closed: an unhandled
#    exception / syntax error exits 1 (NOT 7), and ambiguity exits 2 — both fall
#    through to "treat as merge" rather than being misread as data.
sys.exit(0 if re.search(r"\bgh\s+pr\s+merge(\s|$)", residue, re.M) else 7)
' >/dev/null 2>&1
  rc=$?
  # Exit 7 is the sole "pure data" signal. Everything else — 0 (words survived),
  # 2 (ambiguous), 1 (python crash / syntax error), or any other code — maps to
  # "is a merge" so a stripping failure can never let a real merge through.
  [ "$rc" = 7 ] && return 1                # python3 exit 7 = pure data → not a merge
  return 0                                 # fail-closed: merge on 0 / 2 / crash / other
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
    # No unchecked AC on this issue → it's fine.
    if ! printf '%s' "$body" | grep -q '^- \[ \]'; then
      continue
    fi
    comments=$(_ac_run_gh issue view "$n" --json comments -q '.comments[].body' 2>/dev/null)
    rc=$?
    [ "$rc" != 0 ] && return 2
    # Marker present → covered.
    if printf '%s' "$comments" | grep -q '^## AC closeout'; then
      continue
    fi
    # Any one issue missing the marker triggers the block.
    return 0
  done <<< "$issues"

  return 1
}
