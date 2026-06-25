# shellcheck shell=bash
# helpers/conventional_commit.sh — commit subject check. Source from hooks.
# check_commit_subject <subject> → 0 ok, 1 bad (reason on stderr).
# extract_commit_subject <raw_cmd> <normalized_cmd> → echoes subject (or empty).

# Extract the commit subject from a `git commit` command (SPEC §6.1.1). Handles:
#   1. plain quoted:           -m "subj" / -m 'subj'  (first line of the value)
#   2. embedded-newline -m:    -m "subj\n\nbody"      (first LINE only, #367 facet 1)
#   3. multiple -m:            -m "subj" -m "body"     (the FIRST -m, #367 facet 2)
#   4. heredoc message:        -m "$(cat <<TAG ... TAG)"  (first non-blank body line)
#   5. -F <file> / no -m:      empty  → caller skips the format check (fail-open)
# Extraction is BOUNDED to the `git commit` command (scans from the `commit`
# token onward) and runs on the RAW command, so a sibling command's heredoc/-m
# in a compound invocation (`cat > f <<EOF … EOF && git commit -F x`) is never
# mistaken for the subject (#367 facet 3). python3 is the primary parser; the
# legacy heredoc-walk + greedy sed is the fallback when python3 is absent
# (degrading toward the prior over-extracting behavior — fails toward BLOCKING,
# never toward letting a malformed subject through).
extract_commit_subject() {
  local raw="$1" norm="$2"
  local subj=""
  # Primary path: a bounded, raw-command parser. On success (even an empty
  # result, e.g. -F-only → fail-open) its output is authoritative. Only a
  # python3 crash (non-zero exit) falls through to the legacy logic below.
  if command -v python3 >/dev/null 2>&1; then
    if subj=$(printf '%s' "$raw" | python3 -c '
import sys, re
raw = sys.stdin.read()
# Bound to the git commit command: scan from the commit token onward (stay
# within the command segment — do not cross a separator into a sibling cmd).
m = re.search(r"\bgit\b[^\n;&|]*?\bcommit\b", raw)
if not m:
    sys.exit(0)                       # no commit token → empty (fail-open)
tail = raw[m.end():]
# First -m / --message, value-separated by = or whitespace (a separator is
# required, matching the prior contract; glued -mfoo is out of scope).
flag = re.search(r"(?:(?<=\s)|^)(?:--message|-m)(?:=|\s)", tail)
if not flag:
    sys.exit(0)                       # no inline -m (e.g. -F only) → empty
i, n = flag.end(), len(tail)
while i < n and tail[i] in " \t":
    i += 1
val = ""
if i < n and tail[i] == "\x27":       # single-quoted value
    k = tail.find("\x27", i + 1)
    val = tail[i+1:k] if k != -1 else tail[i+1:]
elif i < n and tail[i] == "\"":       # double-quoted value (honor backslash)
    k, buf = i + 1, []
    while k < n:
        if tail[k] == "\\" and k + 1 < n:
            buf.append(tail[k+1]); k += 2; continue
        if tail[k] == "\"":
            break
        buf.append(tail[k]); k += 1
    val = "".join(buf)
else:                                 # bareword value (to next whitespace)
    bw = re.match(r"\S+", tail[i:])
    val = bw.group(0) if bw else ""
# Line-1 precedence (#383): if the value first non-blank line is already a valid
# Conventional Commit subject, return it and skip the heredoc walk — a normal -m
# body that merely mentions a heredoc-opener token must not be mis-read as a
# heredoc message. The genuine command-substitution form has the substitution
# opener as its first line (not a valid subject), so it falls through. Patterns
# mirror check_commit_subject (re_required / re_optional).
_req = r"^(feat|fix|docs|refactor|perf)\(#[0-9]+\)!?: .+$"
_opt = r"^(test|style|build|ci|chore|revert)(\(#[0-9]+\))?!?: .+$"
for _ln in val.split("\n"):
    _s = _ln.strip()
    if not _s:
        continue
    if re.match(_req, _s) or re.match(_opt, _s):
        sys.stdout.write(_s)
        sys.exit(0)
    break                              # first non-blank line is not a CC subject
# Heredoc message form: the value embeds $(cat <<TAG ... TAG) → the subject is
# the heredoc body first non-blank, non-tag line.
hd = re.search(r"<<-?\s*([\x27\"]?)([A-Za-z_]\w*)\1", val)
if hd:
    tag = hd.group(2)
    for ln in val[hd.end():].split("\n"):
        s = ln.strip()
        if s == tag:
            break
        if s == "":
            continue
        sys.stdout.write(s)
        break
    sys.exit(0)
sys.stdout.write(val.split("\n", 1)[0])   # plain value → first line only
sys.exit(0)
' 2>/dev/null); then
      printf '%s' "$subj"
      return 0
    fi
    # python3 crashed → fall through to the legacy fallback (safe direction).
    subj=""
  fi
  # ---- Legacy fallback (python3 absent / errored): prior heredoc-walk + greedy
  # sed. Over-extracts on the #367 forms (fails toward blocking), never empties a
  # real subject. ----
  # Line-1 precedence (#383): mirror the python primary — if the -m value first
  # non-blank line is already a valid CC subject, return it and skip the heredoc
  # walk (a normal body mentioning a heredoc-opener token must not be mis-read as
  # a heredoc message). Extract the first physical line carrying the -m value
  # from the raw command; the genuine `$(cat <<TAG` opener fails the check and
  # falls through, so this never short-circuits a real heredoc message.
  local cand
  cand=$(printf '%s\n' "$raw" | sed -nE "s/.*(-m|--message)[[:space:]=]+[\"']?(.*)/\2/p" | head -n1)
  if [ -n "$cand" ] && check_commit_subject "$cand" >/dev/null 2>&1; then
    printf '%s\n' "$cand"
    return 0
  fi
  # Heredoc form: detect `<<TAG` or `<<'TAG'` or `<<-TAG`. Extract the tag
  # name, then return the first body line that is neither blank nor the
  # closing tag. Strip leading whitespace from the returned line (so `<<-`
  # indent-stripped heredocs work too).
  if printf '%s' "$raw" | grep -qE "<<-?[[:space:]]*'?[A-Za-z_][A-Za-z_0-9]*'?"; then
    subj=$(printf '%s\n' "$raw" | awk '
      BEGIN { seen = 0; tag = "" }
      !seen {
        # Look for the heredoc opener on this line; extract the tag name.
        if (match($0, /<<-?[[:space:]]*'\''?[A-Za-z_][A-Za-z_0-9]*'\''?/)) {
          opener = substr($0, RSTART, RLENGTH)
          # strip `<<` and optional `-`
          sub(/^<<-?[[:space:]]*/, "", opener)
          # strip surrounding single quotes if present
          gsub(/'\''/, "", opener)
          tag = opener
          seen = 1
        }
        next
      }
      seen {
        # Closing tag line: tag possibly preceded/followed by whitespace.
        if (tag != "" && $0 ~ "^[[:space:]]*" tag "[[:space:]]*$") { exit }
        # Skip blank lines.
        if ($0 ~ /^[[:space:]]*$/) next
        # Strip leading whitespace and emit the first non-blank body line.
        sub(/^[[:space:]]+/, "", $0)
        print
        exit
      }
    ')
  fi
  if [ -n "$subj" ]; then
    printf '%s\n' "$subj"
    return 0
  fi
  # Plain quoted form. Run the existing single-line sed against the
  # normalized command. Double-quoted `-m "..."` first, then single-quoted.
  subj=$(printf '%s' "$norm" | sed -nE 's/.*-m[[:space:]]+"([^"]*)".*/\1/p; s/.*-m[[:space:]]+'\''([^'\'']*)'\''.*/\1/p' | head -n1)
  if [ -n "$subj" ]; then
    printf '%s\n' "$subj"
    return 0
  fi
  return 0
}

# extract_commit_message <raw_cmd> → echo the FULL commit message (every
# -m/--message value joined by newlines + any top-level heredoc body), BOUNDED to
# the `git commit` command (scans from the commit token, stops at the first
# unquoted command separator). This is the COMPLEMENT of extract_commit_subject,
# which returns only the subject LINE: GitHub auto-closes on a keyword anywhere in
# the commit message body, so the directive-close matcher (#490) needs the whole
# message, not just line 1. extract_commit_subject's subject-only contract is
# unchanged (it is reused widely). Empty when there is no inline message (e.g. a
# -F-only commit) — the caller then has nothing to scan (fail-open). The canonical
# `-m "$(cat <<TAG … TAG)"` form is captured whole by the double-quoted -m value
# read; the top-level heredoc branch covers a `git commit -F- <<TAG … TAG` form.
extract_commit_message() {
  command -v python3 >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$1" | python3 -c '
import sys, re
raw = sys.stdin.read()
m = re.search(r"\bgit\b[^\n;&|]*?\bcommit\b", raw)   # bound start: one line, no separator
if not m:
    sys.exit(0)
s = raw[m.end():]
i, n = 0, len(s)
pieces = []
while i < n:
    c = s[i]
    if c in ";&|\n":                                 # unquoted top-level separator → end of cmd
        break
    hd = re.match(r"<<-?\s*([\x27\"]?)([A-Za-z_]\w*)\1", s[i:])
    if hd:                                           # top-level heredoc (e.g. -F- <<TAG)
        tag = hd.group(2)
        rest = s[i+hd.end():]
        nl = rest.find("\n")
        if nl != -1:
            collected = []
            for ln in rest[nl+1:].split("\n"):
                if ln.strip() == tag:
                    break
                collected.append(ln)
            pieces.append("\n".join(collected))
        i += hd.end()
        continue
    fm = re.match(r"(--message|-m)(=|[ \t]+)", s[i:])
    if fm:
        i += fm.end()
        if i < n and s[i] == "\x27":                 # single-quoted value
            k = s.find("\x27", i + 1)
            if k == -1:
                k = n
            pieces.append(s[i+1:k]); i = k + 1
        elif i < n and s[i] == "\"":                 # double-quoted (backslash-aware; spans newlines)
            k, buf = i + 1, []
            while k < n:
                if s[k] == "\\" and k + 1 < n:
                    buf.append(s[k+1]); k += 2; continue
                if s[k] == "\"":
                    break
                buf.append(s[k]); k += 1
            pieces.append("".join(buf)); i = k + 1
        else:                                        # bareword value (to next whitespace)
            bw = re.match(r"\S+", s[i:])
            if bw:
                pieces.append(bw.group(0)); i += len(bw.group(0))
        continue
    i += 1
sys.stdout.write("\n".join(pieces))
' 2>/dev/null
}

_codepoint_len() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import sys; print(len(sys.stdin.read()))'
  else
    # wc -m counts characters under a UTF-8 locale on BSD and GNU.
    printf '%s' "$1" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' '
  fi
}

check_commit_subject() {
  local subj="$1"
  local re_required='^(feat|fix|docs|refactor|perf)\(#[0-9]+\)!?: .+$'
  local re_optional='^(test|style|build|ci|chore|revert)(\(#[0-9]+\))?!?: .+$'
  if [[ ! "$subj" =~ $re_required ]] && [[ ! "$subj" =~ $re_optional ]]; then
    echo "Not a valid Conventional Commit. feat/fix/docs/refactor/perf require (#N); others are optional." >&2
    echo "  format: <type>(#<N>)[!]: <subject>" >&2
    return 1
  fi
  local rest="${subj#*: }"
  local len
  len=$(_codepoint_len "$rest")
  if [ "$len" -lt 1 ] || [ "$len" -gt 72 ]; then
    echo "Subject length out of codepoint range 1..72 (got $len)" >&2
    return 1
  fi
  return 0
}
