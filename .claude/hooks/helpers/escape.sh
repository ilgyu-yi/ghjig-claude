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
# This is the form that survives the live Claude Code Bash tool: the harness
# consumes a leading `VAR=val` env-prefix as the spawned subprocess's own
# environment, so it never reaches `tool_input.command` (parse_env_prefix then
# has nothing to read) — but a trailing `#`-comment stays inside the command and
# is ignored by the executed shell. MUST be called on the RAW command BEFORE the
# hook's whitespace-normalization + shlex pass, which would quote/mangle the `#`.
# The `claude-eng:skip=` namespace keeps an ordinary trailing comment from being
# read as an escape; the sentinel is one-shot (it travels with the single
# command — no persistent bypass state). All `[A-Za-z0-9,_-]` category chars
# only; the reason is captured verbatim and JSON-encoded by audit_log downstream.
parse_skip_sentinel() {
  local _pss_in="$1" _pss_outvar="$2"
  local _pss_re='[[:space:]]*#[[:space:]]*claude-eng:skip=([A-Za-z0-9,_-]+)([[:space:]]+reason=(.*))?[[:space:]]*$'
  if [[ "$_pss_in" =~ $_pss_re ]]; then
    export SKIP_HOOKS="${BASH_REMATCH[1]}"
    local _pss_reason="${BASH_REMATCH[3]:-}"
    export SKIP_REASON="${_pss_reason:-unspecified}"
    printf -v "$_pss_outvar" '%s' "${_pss_in%"${BASH_REMATCH[0]}"}"
  else
    printf -v "$_pss_outvar" '%s' "$_pss_in"
  fi
}
