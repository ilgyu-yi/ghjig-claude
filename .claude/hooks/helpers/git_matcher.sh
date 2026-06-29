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
#   <any other --long-flag[=val] or -X short flag> (#503) — a generic trailing
#     alternative so an UNLISTED valid git global flag (e.g. `--no-lazy-fetch`,
#     git 2.38+) no longer drops the whole `git <verb>` match. The value-taking
#     entries above stay FIRST so POSIX leftmost-longest still consumes their
#     space-separated value (`-c <kv>`); only a space-separated value of an
#     UNLISTED flag is a residual. The `-c alias.<x>=<verb>` rename bypass is a
#     separate, documented §6.1 residual (the alias name is not the gated verb).
# shellcheck disable=SC2034  # consumed via interpolation in pre_tool_use.sh
GIT_PREFIX='\bgit(\s+(-c\s+\S+|-C\s+\S+|-p|--paginate|--no-pager|--git-dir=\S+|--work-tree=\S+|--bare|--namespace=\S+|--literal-pathspecs|--icase-pathspecs|--no-optional-locks|--no-replace-objects|--no-advice|--exec-path(=\S+)?|--config-env=\S+|--[A-Za-z][A-Za-z0-9-]*(=\S+)?|-[A-Za-z]))*\s+'

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

# space_glued_separators <cmd> <outvar> — re-separate a GLUED unquoted command
# separator (`&&`/`||`/`;`/`|`) into a space-padded boundary, so it survives the
# `parse_env_prefix` shlex round-trip as its own token (#446). A separator glued
# to an adjacent token — `git commit -m "x"&&git push --force origin main` (no
# space) — otherwise folds into a single shlex token (`'x&&git'`), DESTROYING the
# following `git push` verb that every downstream arm's entry-grep keys on → a
# false-negative on the irreversible force-push/protected gate (SPEC §6.0 P1).
#
# QUOTE-AWARE (the central correctness invariant): only separators OUTSIDE quoted
# string values are padded. A `&&`/`;`/`|` INSIDE a quoted `-m`/`--message` value
# is data, not a boundary, and is never re-separated — so we never INVENT a
# boundary the user's command lacked (composes with the #440 message-value
# elision; no over-block). The separator set mirrors push_segments' awk regex.
#
# Idempotent: an already-spaced separator is normalized to single spaces, not
# doubled. python3-absent → pass-through no-op: on that path parse_env_prefix
# does NOT fold (it passes $cmd through unchanged), so the glued verb stays
# intact for the entry-grep and there is nothing to repair.
space_glued_separators() {
  local _sgs_cmd="$1" _sgs_outvar="$2" _sgs_out
  if ! command -v python3 >/dev/null 2>&1; then
    printf -v "$_sgs_outvar" '%s' "$_sgs_cmd"
    return
  fi
  if _sgs_out=$(printf '%s' "$_sgs_cmd" | python3 -c '
import sys
s = sys.stdin.read()
out = []
i, n = 0, len(s)
in_s = in_d = False
def pad(tok):
    while out and out[-1] == " ":
        out.pop()
    out.append(" "); out.append(tok); out.append(" ")
while i < n:
    c = s[i]
    if in_s:
        out.append(c)
        if c == "\x27": in_s = False
        i += 1; continue
    if in_d:
        out.append(c)
        if c == "\\" and i + 1 < n:
            out.append(s[i+1]); i += 2; continue
        if c == "\"": in_d = False
        i += 1; continue
    if c == "\x27":
        in_s = True; out.append(c); i += 1; continue
    if c == "\"":
        in_d = True; out.append(c); i += 1; continue
    two = s[i:i+2]
    if two in ("&&", "||"):
        pad(two); i += 2
        while i < n and s[i] == " ": i += 1
        continue
    if c in (";", "|"):
        pad(c); i += 1
        while i < n and s[i] == " ": i += 1
        continue
    if c == "&":
        # Lone background "&" — pad it like the other separators UNLESS it is part
        # of a redirect (immediately adjacent to ">" or "<": >&, &>, N>&M, <&, &>>),
        # which is a redirect operator, not a separator (#476). "&&" is consumed by
        # the two-char arm above, so a "&" reaching here is a genuine lone "&".
        prev = s[i-1] if i > 0 else ""
        nxt = s[i+1] if i + 1 < n else ""
        if prev in (">", "<") or nxt in (">", "<"):
            out.append(c); i += 1; continue
        pad("&"); i += 1
        while i < n and s[i] == " ": i += 1
        continue
    out.append(c); i += 1
sys.stdout.write("".join(out).strip())
' 2>/dev/null); then
    printf -v "$_sgs_outvar" '%s' "$_sgs_out"
  else
    printf -v "$_sgs_outvar" '%s' "$_sgs_cmd"   # fail-open: parse error → unchanged
  fi
}

# push_segments <cmd> — split <cmd> on unquoted command separators
# (&& || ; | & and newline) and print each segment containing a `git push` token,
# one per line (#366). The protected-push arm greps the protected-token pattern
# per emitted segment, so a protected token in a SIBLING non-push segment
# (`git push origin feat && gh pr create --base main`) is never matched against
# the push command. Feed it a heredoc-stripped command so separators inside a
# heredoc body are not split points. Emits nothing when no segment has a push.
push_segments() {
  printf '%s' "$1" | awk '
    { nf = split($0, parts, /&&|\|\||;|\||&/)
      for (k = 1; k <= nf; k++) print parts[k] }
  ' | grep -E "${GIT_PREFIX}push\b"
}

# directive_close_violation <text> — scan <text> for a GitHub auto-close keyword
# (close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved — case-insensitive,
# optional `:`) immediately preceding an issue reference `#N`, and return success
# (echoing the FIRST such `#N`) iff that `#N` is a DIRECTIVE Issue. GitHub auto-closes
# a referenced Issue at merge when this grammar appears anywhere in a PR body OR a
# commit message; for a Directive that bypasses /complete-directive's signal gate
# (SPEC §5.13). This detector is SHARED by both the gh-pr-body arm and the
# commit-message arm so the grammar can never drift between the two vectors (#490;
# the #276 resolve_gh_issue_target anti-drift precedent).
#
# Per-`#N` FAIL-OPEN (parity with proposed-protect / initiative-readonly): if
# is_directive_issue is undefined, or cannot resolve a given `#N` (gh down / no auth /
# non-numeric → it returns non-zero), that `#N` is treated as "not a Directive" and
# skipped — the matcher never blocks on an unresolved type. Returns 1 (no violation,
# no output) when no referenced `#N` resolves to a Directive. Execution Issues
# therefore never block (`Closes #<execution>` is the normal resolving trailer), and
# a non-close mention (`Refs #N`, `advances #N`, prose) never matches the grammar.
#
# BSD/macOS-safe: a single `grep -ioE` extracts the keyword+`#N` pairs (a leading
# non-alpha / line-start guard rejects substrings like "disclose #5"; the guard
# char is dropped when the bare `#N` is re-extracted), then a bash loop calls the
# predicate. No GNU-only `\b` / PCRE. The leading guard is intentionally permissive
# (a digit-prefixed keyword still matches) — it errs toward BLOCKING, the fail-safe
# direction for this high-asymmetry gate (§6.0 P1; a false block costs a rename).
directive_close_violation() {
  local text="$1" refs n
  command -v is_directive_issue >/dev/null 2>&1 || return 1   # no predicate → fail-open
  refs=$(printf '%s' "$text" \
    | grep -ioE '(^|[^[:alpha:]])(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)):?[[:space:]]+#[0-9]+' \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
  [ -n "$refs" ] || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if is_directive_issue "$n"; then
      printf '%s' "$n"
      return 0
    fi
  done <<< "$refs"
  return 1
}

# extract_gh_pr_body <cmd> — echo the INLINE `--body`/`-b` value of a `gh pr`
# command (create/edit). `--body-file`/`-F` (incl. the stdin `-F -` form) is
# deliberately NOT read — a documented residual (SPEC §6.1): reading an arbitrary
# file path would add an IO / path-resolution / TOCTOU surface disproportionate to
# the vector. Used by the directive-close PR-body arm. Empty output when there is
# no inline body (incl. the --body-file / stdin form). python3-absent → empty (the
# arm then has nothing to scan → fail-open).
extract_gh_pr_body() {
  command -v python3 >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$1" | python3 -c '
import sys, re
cmd = sys.stdin.read()
# --body / -b as a whole flag token (word-boundary), value introduced by = or
# whitespace. "--body-file" starts with "--body" but is followed by "-", which the
# (=|[ \t]+) group cannot match, so --body-file is correctly NOT read here.
m = re.search(r"(?:(?<=\s)|^)(--body|-b)(=|[ \t]+)", cmd)
if not m:
    sys.exit(0)
i, n = m.end(), len(cmd)
if i < n and cmd[i] == "\x27":                       # single-quoted value
    k = cmd.find("\x27", i + 1)
    sys.stdout.write(cmd[i+1:k] if k != -1 else cmd[i+1:]); sys.exit(0)
if i < n and cmd[i] == "\"":                         # double-quoted (backslash-aware)
    k, buf = i + 1, []
    while k < n:
        if cmd[k] == "\\" and k + 1 < n:
            buf.append(cmd[k+1]); k += 2; continue
        if cmd[k] == "\"":
            break
        buf.append(cmd[k]); k += 1
    sys.stdout.write("".join(buf)); sys.exit(0)
bw = re.match(r"\S+", cmd[i:])                       # bareword value
sys.stdout.write(bw.group(0) if bw else "")
' 2>/dev/null
}
