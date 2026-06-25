# shellcheck shell=bash
# helpers/escape.sh — SKIP_HOOKS handling. Source from hooks.
# Usage: should_skip <category>  → returns 0 if skipping (audit-logged), 1 otherwise.

should_skip() {
  local cat="$1"
  [ -z "${SKIP_HOOKS:-}" ] && return 1
  case ",${SKIP_HOOKS}," in
    *",all,"*|*",${cat},"*)
      local reason="${SKIP_REASON:-unspecified}"
      audit_log escape "$cat" skip "$reason"
      return 0
      ;;
  esac
  return 1
}

# parse_env_prefix <cmd> <outvar>
#   Parses the SPEC §7 escape-hatch env-prefix (`SKIP_HOOKS=…` and
#   `SKIP_REASON=…`) from the leading edge of <cmd>, exports those pairs
#   into the calling shell, and writes the stripped cmd into the variable
#   named by <outvar> (via `printf -v`, so no subshell loses the exports).
#
# Only `SKIP_HOOKS` and `SKIP_REASON` are recognized — any other ALLCAPS
# `K=V` leading token is treated as an ordinary cmd argument and left in
# place. This is deliberate: a permissive allow-list would let a crafted
# `PATH=/evil git commit …` redirect downstream `command -v` lookups in
# the hook (which then `eval` the resolved binary), exfiltrating the
# guardrail. Restricting to the SPEC-documented variables closes that
# vector while keeping the documented syntax intact.
#
# Why a nameref-style outvar instead of stdout: `outvar=$(parse_env_prefix
# …)` would put the function body in a subshell, and any exports inside
# would be discarded when that subshell exited. The <outvar> argument must
# be a valid bash identifier; callers pass it as a literal.
#
# Falls back to a no-op (outvar set to cmd unchanged, no env exports) when
# python3 or jq is absent. The escape hatch then behaves as it did before
# this PR (broken on minimal hosts), which is no worse than the prior state.
parse_env_prefix() {
  # All internals are `_pep_`-prefixed so they cannot shadow a caller-
  # supplied outvar name through bash's dynamic scope. In particular,
  # naming the parameter local `cmd` and the caller passing `cmd` as
  # outvar would route `printf -v "$outvar"` to the function-local,
  # silently dropping the stripped result.
  local _pep_cmd="$1"
  local _pep_outvar="$2"
  if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf -v "$_pep_outvar" '%s' "$_pep_cmd"
    return
  fi
  local _pep_out
  _pep_out=$(printf '%s' "$_pep_cmd" | python3 -c '
import json, re, shlex, sys
ALLOW = {"SKIP_HOOKS", "SKIP_REASON"}
data = sys.stdin.read()
try:
    toks = shlex.split(data)
except ValueError:
    print(json.dumps({"env": [], "cmd": data}))
    sys.exit(0)
pat = re.compile(r"^([A-Z_][A-Z0-9_]*)=(.*)$", re.DOTALL)
env = []
i = 0
while i < len(toks):
    m = pat.match(toks[i])
    if not m or m.group(1) not in ALLOW:
        break
    env.append([m.group(1), m.group(2)])
    i += 1
try:
    rest = shlex.join(toks[i:])  # Python 3.8+
except AttributeError:
    rest = " ".join(toks[i:])
print(json.dumps({"env": env, "cmd": rest}))
' 2>/dev/null) || {
    printf -v "$_pep_outvar" '%s' "$_pep_cmd"
    return
  }
  local _pep_env_lines _pep_stripped _pep_kv
  _pep_env_lines=$(printf '%s' "$_pep_out" | jq -r '.env[]? | "\(.[0])=\(.[1])"' 2>/dev/null) || _pep_env_lines=""
  _pep_stripped=$(printf '%s' "$_pep_out" | jq -r '.cmd // ""' 2>/dev/null) || _pep_stripped="$_pep_cmd"
  while IFS= read -r _pep_kv; do
    [ -z "$_pep_kv" ] && continue
    # shellcheck disable=SC2163  # $_pep_kv holds the literal KEY=VALUE form
    export "$_pep_kv"
  done <<< "$_pep_env_lines"
  printf -v "$_pep_outvar" '%s' "$_pep_stripped"
}

# parse_skip_sentinel <raw_cmd> <outvar> — TRAILING-sentinel escape (SPEC §7,
# #206). Recognizes `# claude-eng:skip=<cat>[,<cat>...] reason=<why>` at the tail
# of the RAW command and, on match, exports SKIP_HOOKS / SKIP_REASON (mirroring
# parse_env_prefix's contract so every matcher's `should_skip` works unchanged)
# and writes the sentinel-stripped command to <outvar>. No-op (outvar = input,
# no exports) when absent.
#
# OBSERVED (this harness, 2026-06; the harness is a moving floor — re-verify):
# NEITHER escape form reaches `tool_input.command` in the live Claude Code Bash
# tool. The leading `VAR=val` env-prefix is consumed as the spawned subprocess's
# own environment, AND the trailing `#`-comment is also stripped before the hook
# sees it — so `should_skip` reads an empty `$SKIP_HOOKS` and the matcher still
# blocks. The parser below is correct (it sets SKIP_HOOKS when fed the literal
# string in isolation); the gap is purely harness command-delivery. There is
# therefore no working in-harness escape: run a sanctioned guarded op in a real
# terminal (no PreToolUse hook fires there) or via a non-protected branch +
# rename. Full contract + recourse: SPEC §7. Restoring an in-agent channel is
# tracked in #479. (The parsing contract below is still exercised by the smoke
# harness and a real shell that passes the prefix verbatim.)
#
# MUST be called on the RAW command BEFORE the hook's whitespace-normalization
# + shlex pass, which would quote/mangle the `#`.
# The `claude-eng:skip=` namespace keeps an ordinary trailing comment from being
# read as an escape; the sentinel is one-shot (it travels with the single
# command — no persistent bypass state). All `[A-Za-z0-9,_-]` category chars
# only; the reason is captured verbatim and JSON-encoded by audit_log downstream.
#
# COMMENT-TOKEN GUARD (#208): the sentinel is honored ONLY when its `#` is a
# genuine UNQUOTED shell comment token — a `#` the executed shell itself treats
# as the start of a comment. A `#` inside a quoted argument (e.g.
# `gh pr comment 5 --body "x # claude-eng:skip=all reason=y"`) is argument text,
# not a comment: the shell runs the whole command, so honoring it would let
# ordinary quoted text (a commit message, a PR-body paste, audit output quoting
# the sentinel) silently disarm every matcher with a falsified audit reason. The
# offset of the last unquoted comment `#` is resolved with python3 (the same
# dependency parse_env_prefix uses); python3 absent → the sentinel is NOT honored
# (fail-safe no-op: enforcement stays armed, never a spurious skip).
parse_skip_sentinel() {
  local _pss_in="$1" _pss_outvar="$2"
  # Fast path: no namespaced sentinel present anywhere → nothing to honor, and
  # we avoid spawning python3 on the (overwhelmingly common) no-escape command.
  case "$_pss_in" in
    *'claude-eng:skip='*) : ;;
    *) printf -v "$_pss_outvar" '%s' "$_pss_in"; return ;;
  esac
  # Comment-token guard: emit the comment suffix (from the first UNQUOTED `#`
  # boundary token to end of string) iff one exists; empty otherwise. A small
  # quote/escape state machine that models all three bash string forms —
  # double `"…"`, literal single `'…'`, and ANSI-C `$'…'` (where `\'` is an
  # escaped quote, so a naive single-quote scan would mis-close it and expose a
  # `$'x\' #sentinel'` bypass — #208 security review). A `#` is a comment only at
  # a word boundary (start of string, or after space/tab/newline). `chr()`
  # literals avoid embedding `'`/`"`/`#`/`\` in this single-quoted python source.
  local _pss_comment=""
  if command -v python3 >/dev/null 2>&1; then
    _pss_comment=$(printf '%s' "$_pss_in" | python3 -c '
import sys
s = sys.stdin.read()
DQ = chr(34); SQ = chr(39); BS = chr(92); HS = chr(35)
SP = chr(32); TB = chr(9); NL = chr(10); DOL = chr(36); AN = chr(1)
i = 0; n = len(s); q = None; off = -1
while i < n:
    c = s[i]
    if q == AN:
        # ANSI-C $(...) string: backslash escapes next; closes at unescaped quote.
        if c == BS:
            i += 2; continue
        if c == SQ:
            q = None
    elif q == DQ:
        if c == BS:
            i += 2; continue
        if c == DQ:
            q = None
    elif q == SQ:
        # literal single quotes: no escapes, closes only at the next quote.
        if c == SQ:
            q = None
    else:
        if c == DOL and i + 1 < n and s[i+1] == SQ:
            q = AN; i += 2; continue
        if c == BS:
            i += 2; continue
        if c == DQ:
            q = DQ
        elif c == SQ:
            q = SQ
        elif c == HS and (i == 0 or s[i-1] == SP or s[i-1] == TB or s[i-1] == NL):
            off = i; break
    i += 1
if off >= 0:
    sys.stdout.write(s[off:])
' 2>/dev/null) || _pss_comment=""
  fi
  if [ -z "$_pss_comment" ]; then
    printf -v "$_pss_outvar" '%s' "$_pss_in"
    return
  fi
  # SINGLE TRAILING LINE only. `[[:blank:]]` (space/tab, NOT newline) and a
  # control-char-free reason (`[^[:cntrl:]]`, excludes newline) confine the match
  # to the comment's first line — anchored at end-of-string. A line-1 sentinel
  # whose comment suffix spans the newline into a dangerous later line fails this
  # `$`-anchored match (the newline guard is belt-and-suspenders) → not honored,
  # so it can never strip/disarm that later line.
  local _pss_re='[[:blank:]]*#[[:blank:]]*claude-eng:skip=([A-Za-z0-9,_-]+)([[:blank:]]+reason=([^[:cntrl:]]*))?[[:blank:]]*$'
  if [[ "$_pss_comment" =~ $_pss_re ]] && [[ "${BASH_REMATCH[0]}" != *$'\n'* ]]; then
    # Exact suffix removal (locale-independent). If the comment is not a true
    # suffix of the raw command (e.g. a trailing newline after it that command
    # substitution dropped), the removal is a no-op — then do NOT honor, to
    # preserve the pre-#208 "no clean strip → no escape" safety.
    local _pss_stripped="${_pss_in%"$_pss_comment"}"
    if [ "$_pss_stripped" != "$_pss_in" ]; then
      export SKIP_HOOKS="${BASH_REMATCH[1]}"
      local _pss_reason="${BASH_REMATCH[3]:-}"
      export SKIP_REASON="${_pss_reason:-unspecified}"
      # Trim the blanks left before the `#`.
      if [[ "$_pss_stripped" =~ ^(.*[^[:blank:]])[[:blank:]]*$ ]]; then
        _pss_stripped="${BASH_REMATCH[1]}"
      fi
      printf -v "$_pss_outvar" '%s' "$_pss_stripped"
      return
    fi
  fi
  printf -v "$_pss_outvar" '%s' "$_pss_in"
}
