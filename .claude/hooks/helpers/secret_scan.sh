# shellcheck shell=bash
# helpers/secret_scan.sh — pattern scan over the staged diff. Source from hooks.

scan_staged_secrets() {
  local added
  added=$(git diff --cached 2>/dev/null | grep -E '^\+[^+]' | sed 's/^\+//')
  [ -z "$added" ] && return 0
  local p
  for p in \
    'AKIA[0-9A-Z]{16}' \
    'aws(_| )secret(_| )access(_| )key.*[A-Za-z0-9/+=]{40}' \
    'ghp_[A-Za-z0-9]{36}' \
    'gho_[A-Za-z0-9]{36}' \
    'github_pat_[A-Za-z0-9_]{20,}' \
    'glpat-[A-Za-z0-9_-]{20}' \
    'sk-ant-[A-Za-z0-9_-]+' \
    'sk-[A-Za-z0-9]{40,}' \
    'xox[bpoa]-[A-Za-z0-9-]+' \
    '-----BEGIN [A-Z ]+PRIVATE KEY-----' \
    'password[[:space:]]*[:=][[:space:]]*["'\''][^"'\'' ]{8,}["'\'']' \
  ; do
    if echo "$added" | grep -qE "$p"; then
      echo "Possible secret pattern detected (only paths/lines audited; body never logged): $p" >&2
      return 1
    fi
  done
  return 0
}