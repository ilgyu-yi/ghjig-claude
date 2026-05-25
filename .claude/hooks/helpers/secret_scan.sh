# shellcheck shell=bash
# helpers/secret_scan.sh — pattern scan over the staged diff. Source from hooks.
#
# Public:
#   scan_staged_secrets — walks `git diff --cached --unified=0` extracting
#     (file, line, content) tuples, drops any whose `file` matches an entry
#     in `.shellsecretignore` at the target-repo root, and runs each
#     surviving line through 11 secret patterns. On any hit: emits one
#     `<file>:<line>: <pattern-id>` line per location to stderr, then the
#     legacy summary, and returns 1. No hits → return 0.
#
# `.shellsecretignore` is gitignore-narrow: glob match via bash `case`,
# trailing `/` expands to prefix + recursive (`docs/` matches `docs/foo`
# and `docs/sub/file`). No negation, no `**`, no anchored `/foo`. Missing
# file → no allow-list (today's behavior preserved). See SPEC §6.1.
#
# Patterns and their short IDs are parallel arrays. IDs are stable across
# reorder; new patterns must add both an entry to SECRET_IDS and to
# SECRET_PATTERNS at the same index.
#
# Bash 3.2 compatibility: avoid nested parameter expansion. Use sed for
# trailing-whitespace trim; bash on macOS (system /bin/bash) is still 3.2.

SECRET_IDS=(
  aws-akia
  aws-secret
  gh-pat-classic
  gh-pat-oauth
  gh-pat-fine
  gitlab-pat
  anthropic-key
  openai-key
  slack-token
  private-key
  password-literal
)

SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}'
  'aws(_| )secret(_| )access(_| )key.*[A-Za-z0-9/+=]{40}'
  'ghp_[A-Za-z0-9]{36}'
  'gho_[A-Za-z0-9]{36}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'glpat-[A-Za-z0-9_-]{20}'
  'sk-ant-[A-Za-z0-9_-]+'
  'sk-[A-Za-z0-9]{40,}'
  'xox[bpoa]-[A-Za-z0-9-]+'
  '-----BEGIN [A-Z ]+PRIVATE KEY-----'
  'password[[:space:]]*[:=][[:space:]]*["'\''][^"'\'' ]{8,}["'\'']'
)

# _secret_load_allow_list
#   Populates SECRET_ALLOW_ENTRIES (global) from `.shellsecretignore`
#   **at HEAD**, not the working tree. Same-commit additions to the
#   allow-list cannot self-bypass: the entry must be on a prior commit
#   to take effect for this commit. (Security review of #25 flagged the
#   working-tree read as a MEDIUM self-bypass vector.) Initial introduction
#   of `.shellsecretignore` therefore requires two commits — the file
#   first, then the work it covers. Pre-HEAD setup (no `.shellsecretignore`
#   at HEAD yet) = no allow-list = today's strict behavior.
#   Trims trailing whitespace via sed; drops blanks and `#` comments.
_secret_load_allow_list() {
  SECRET_ALLOW_ENTRIES=()
  local raw
  # `git show HEAD:.shellsecretignore` exits non-zero if file is absent at
  # HEAD; either case yields an empty allow-list (silent — no error to
  # avoid false alarms on fresh repos with no commits yet).
  raw=$(git show HEAD:.shellsecretignore 2>/dev/null) || return 0
  [ -z "$raw" ] && return 0
  local entry
  while IFS= read -r entry || [ -n "$entry" ]; do
    SECRET_ALLOW_ENTRIES+=("$entry")
  done < <(printf '%s\n' "$raw" | sed -E 's/[[:space:]]+$//' | grep -Ev '^[[:space:]]*(#|$)')
}

# secret_scan_path_allowed <path>
#   Returns 0 if <path> matches any entry in the loaded allow list, 1
#   otherwise. Caller must have invoked _secret_load_allow_list first
#   (scan_staged_secrets does this).
#
# `${arr[@]+"${arr[@]}"}` guards against bash 3.2's `set -u` "unbound
# variable" error on an empty/undeclared indexed array — the `+:` form
# is the portable empty-safe expansion. Without this, smoke (which runs
# with `set -uo pipefail`) errors before reaching the loop body.
secret_scan_path_allowed() {
  # Variable naming: avoid `local path` — zsh has a built-in tied array
  # $path that mirrors $PATH, and `local path="..."` clobbers the search
  # path, breaking subsequent command resolution. Use `file_path` instead
  # (#82). Defensive even though pre_tool_use.sh launches us under bash
  # today; helpers may be sourced from slash commands or other entrypoints
  # that run under zsh on macOS.
  local file_path="$1"
  local entry pat
  for entry in ${SECRET_ALLOW_ENTRIES[@]+"${SECRET_ALLOW_ENTRIES[@]}"}; do
    case "$entry" in
      */)
        pat="${entry%/}"
        # shellcheck disable=SC2254  # intentional unquoted glob in case pattern
        case "$file_path" in
          $pat) return 0 ;;
          $pat/*) return 0 ;;
        esac
        ;;
      *)
        # shellcheck disable=SC2254  # intentional unquoted glob in case pattern
        case "$file_path" in $entry) return 0 ;; esac
        ;;
    esac
  done
  return 1
}

# scan_staged_secrets — see header. Returns 0 if no hit, 1 if hit (with
# per-line markers + legacy summary on stderr).
scan_staged_secrets() {
  local diff
  diff=$(git diff --cached --unified=0 2>/dev/null) || return 0
  [ -z "$diff" ] && return 0

  _secret_load_allow_list

  local file="" lineno=0 line content i hit=0 first_pat=""
  local stderr_buf=""
  local hunk plus expect_plusplusplus=0
  # State machine: `+++ ` is only a real diff header when the immediately
  # preceding line was `--- ` (the `a/` side). Otherwise `+++ <text>` is an
  # added content line whose body starts with `++ ` (two pluses + space) —
  # security review of #25 demonstrated that the naive case-glob misparsed
  # such a content line, reassigning `file` to attacker-supplied text and
  # bypassing the scan via the allow-list.
  while IFS= read -r line; do
    case "$line" in
      '--- '*)
        expect_plusplusplus=1
        ;;
      '+++ '*)
        if [ "$expect_plusplusplus" = 1 ]; then
          # Real diff header (preceded by `--- `).
          expect_plusplusplus=0
          if [ "$line" = '+++ /dev/null' ]; then
            file=""
          else
            file="${line#+++ }"
            file="${file#b/}"
          fi
          lineno=0
        else
          # Content line whose body starts with `++ ` — treat as added content.
          lineno=$((lineno + 1))
          [ -z "$file" ] && continue
          if secret_scan_path_allowed "$file"; then
            continue
          fi
          content="${line#+}"
          for i in "${!SECRET_PATTERNS[@]}"; do
            # `--` separates options from pattern so leading-`-` patterns
            # (e.g. `-----BEGIN ... PRIVATE KEY-----`) are not consumed as
            # grep options on BSD grep (macOS). Security review HIGH-2.
            if printf '%s' "$content" | grep -qE -- "${SECRET_PATTERNS[$i]}"; then
              hit=1
              stderr_buf="${stderr_buf}${file}:${lineno}: ${SECRET_IDS[$i]}"$'\n'
              [ -z "$first_pat" ] && first_pat="${SECRET_PATTERNS[$i]}"
              break
            fi
          done
        fi
        ;;
      '@@'*)
        expect_plusplusplus=0
        hunk="${line#@@ }"
        hunk="${hunk%% @@*}"
        # Extract the +C portion (after the space-+ separator, drop optional `,D`).
        plus="${hunk##*+}"
        plus="${plus%% *}"
        lineno="${plus%%,*}"
        # The next `+` content line is at `lineno`; increment AFTER use.
        lineno=$((lineno - 1))
        ;;
      '+'*)
        expect_plusplusplus=0
        lineno=$((lineno + 1))
        [ -z "$file" ] && continue
        if secret_scan_path_allowed "$file"; then
          continue
        fi
        content="${line#+}"
        for i in "${!SECRET_PATTERNS[@]}"; do
          # See note above re: leading-`--` for BSD-grep option-parsing.
          if printf '%s' "$content" | grep -qE -- "${SECRET_PATTERNS[$i]}"; then
            hit=1
            stderr_buf="${stderr_buf}${file}:${lineno}: ${SECRET_IDS[$i]}"$'\n'
            [ -z "$first_pat" ] && first_pat="${SECRET_PATTERNS[$i]}"
            break
          fi
        done
        ;;
      *)
        expect_plusplusplus=0
        # Other diff metadata (diff --git, index, Binary, rename,
        # \ No newline) — ignore. Parser is intentionally narrow.
        ;;
    esac
  done <<< "$diff"

  if [ "$hit" = 1 ]; then
    printf '%s' "$stderr_buf" >&2
    echo "Possible secret pattern detected (only paths/lines audited; body never logged): $first_pat" >&2
    return 1
  fi
  return 0
}
