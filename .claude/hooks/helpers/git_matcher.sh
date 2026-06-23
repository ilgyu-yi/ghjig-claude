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

# strip_command_data <cmd> [mode] — print <cmd> with heredoc bodies removed
# (and, in the default "full" mode, quoted string literals removed too) so a
# subsequent token grep sees command words, not DATA. Factored from #340's
# is_pr_merge_command stripper, shared by the protected-push and git-clean arms
# (#366). Three modes:
#   "heredoc" — strip ONLY heredoc bodies. For the protected-push / git-clean
#     arms: the matched token (a branch positional, a -f flag) may be legitimately
#     quoted, so quote-stripping could drop a genuine quoted target/flag and miss
#     a real action (false-negative). Heredoc-only never removes a real command.
#   "message" (#440) — heredoc strip PLUS elide only the argument VALUES of
#     `-m`/`--message`/`-F`/`--file` (the commit-message data, in `=`-glued,
#     quoted, or bareword form). For the force-push / protected-push arms: a
#     force/protected literal documented inside a commit MESSAGE body is data,
#     not a command, so it must not false-trip — but the elision is anchored
#     strictly to the message-flag token, so a quoted push TARGET (`origin "main"`,
#     which has no preceding message-flag) is NEVER removed (no false-negative).
#     `message ⊇ heredoc` (a superset single pass).
#   "full" (default) — strip heredoc bodies AND all quoted literals. For
#     is_pr_merge_command (#340), which must see through a quoted
#     `--body "…gh pr merge…"`; #340 already accepts the quote-obfuscation residual.
# FAIL-CLOSED: python3 absent, an unclosed quote (full OR message mode), or any
# parse error prints the cmd UNCHANGED (return 0) — the caller's grep then runs
# against the full command, so a token that should block is never stripped away
# by a failure (a missed message-elision degrades to today's recoverable
# false-trip; it never over-strips a genuine target).
# Pass the RAW (pre-normalization) command so heredoc newlines are intact.
strip_command_data() {
  local cmd="$1" mode="${2:-full}" out
  command -v python3 >/dev/null 2>&1 || { printf '%s' "$cmd"; return 0; }
  if out=$(printf '%s' "$cmd" | python3 -c '
import sys, re
mode = sys.argv[1] if len(sys.argv) > 1 else "full"
cmd = sys.stdin.read()
# 1. Strip heredoc bodies (always). Opener is << or <<- + optionally-quoted
#    delimiter word; <<< is a here-string (same-line operand), not a heredoc.
lines = cmd.split("\n")
delim_re = re.compile(r"<<-?\s*([\"\x27]?)([A-Za-z_][A-Za-z0-9_]*)\1")
out = []
i, n = 0, len(lines)
while i < n:
    line = lines[i]
    delim = None
    for mm in re.finditer(r"<<", line):
        p = mm.start()
        if line[p:p+3] == "<<<":
            continue
        dm = delim_re.match(line[p:])
        if dm:
            delim = dm.group(2)
            break
    out.append(line)
    if delim is not None:
        i += 1
        while i < n and lines[i].strip() != delim:
            i += 1
    i += 1
stripped = "\n".join(out)
if mode == "message":
    # Elide ONLY the argument VALUES of -m/--message/-F/--file (commit-message
    # data). The elision is anchored to a message-flag token at a word boundary,
    # so a quoted push TARGET (origin "main") — which has no preceding
    # message-flag — is NEVER removed. Unclosed value quote → exit(2) (caller
    # fail-closes to the unstripped command; never an over-strip).
    s = stripped
    res = []
    i, mlen = 0, len(s)
    flagre = re.compile(r"(--message|--file|-m|-F)(=|[ \t]|$)")
    seps = (" ", "\t", "\n", ";", "&", "|", "(")
    while i < mlen:
        at_b = (i == 0) or (s[i-1] in seps)
        mm = flagre.match(s, i) if at_b else None
        if mm:
            res.append(mm.group(1)); i += len(mm.group(1))
            if mm.group(2) == "=":
                res.append("="); i += 1
            else:
                while i < mlen and s[i] in (" ", "\t"):
                    res.append(s[i]); i += 1
            # elide the value token at i (quoted or bareword) — appended to nothing
            if i < mlen and s[i] == "\x27":           # single-quoted value
                k = s.find("\x27", i + 1)
                if k == -1:
                    sys.exit(2)
                i = k + 1
            elif i < mlen and s[i] == "\"":           # double-quoted (backslash-aware)
                k = i + 1
                while k < mlen:
                    if s[k] == "\\":
                        k += 2; continue
                    if s[k] == "\"":
                        break
                    k += 1
                if k >= mlen:
                    sys.exit(2)
                i = k + 1
            else:                                      # bareword to next whitespace
                while i < mlen and s[i] not in (" ", "\t", "\n"):
                    i += 1
            continue
        res.append(s[i]); i += 1
    sys.stdout.write("".join(res))
    sys.exit(0)
if mode != "full":
    sys.stdout.write(stripped)
    sys.exit(0)
# 2. full mode: remove quoted string literals (interior can never be a command word).
def strip_quotes(s):
    res = []
    j, m = 0, len(s)
    while j < m:
        c = s[j]
        if c == "\x27":                    # single quote: literal to next quote
            k = s.find("\x27", j + 1)
            if k == -1:
                return None
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
                return None
            j = k + 1
            continue
        res.append(c)
        j += 1
    return "".join(res)
residue = strip_quotes(stripped)
if residue is None:
    sys.exit(2)                            # ambiguous → caller fail-closes (prints original)
sys.stdout.write(residue)
sys.exit(0)
' "$mode" 2>/dev/null); then
    printf '%s' "$out"
  else
    printf '%s' "$cmd"                     # fail-closed: parse error / ambiguity → original
  fi
}

# push_segments <cmd> — split <cmd> on unquoted command separators
# (&& || ; | and newline) and print each segment containing a `git push` token,
# one per line (#366). The protected-push arm greps the protected-token pattern
# per emitted segment, so a protected token in a SIBLING non-push segment
# (`git push origin feat && gh pr create --base main`) is never matched against
# the push command. Feed it a heredoc-stripped command so separators inside a
# heredoc body are not split points. Emits nothing when no segment has a push.
push_segments() {
  printf '%s' "$1" | awk '
    { nf = split($0, parts, /&&|\|\||;|\|/)
      for (k = 1; k <= nf; k++) print parts[k] }
  ' | grep -E "${GIT_PREFIX}push\b"
}
