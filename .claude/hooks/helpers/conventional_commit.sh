# shellcheck shell=bash
# helpers/conventional_commit.sh — commit subject check. Source from hooks.
# check_commit_subject <subject> → 0 ok, 1 bad (reason on stderr).
# extract_commit_subject <raw_cmd> <normalized_cmd> → echoes subject (or empty).

# Extract the commit subject from a `git commit` command. Supports two -m forms:
#   1. plain quoted:        -m "subj"  /  -m 'subj'
#   2. heredoc body:        -m "$(cat <<TAG ... TAG)"   (TAG may be 'EOF' / EOF / -EOF)
# Heredoc handling walks the RAW (pre-whitespace-normalization) command to find
# the first non-blank, non-closing-tag line of the heredoc body. Plain form
# falls back to the existing single-line sed against the normalized command.
extract_commit_subject() {
  local raw="$1" norm="$2"
  local subj=""
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