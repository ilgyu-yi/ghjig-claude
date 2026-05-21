# shellcheck shell=bash
# helpers/pr_cache.sh — persistent "last seen PR body" cache. Source from
# /sync-pr, /ship, /work-on. SPEC §5.4.
#
# Cache location: $PR_CACHE_DIR (override; defaults to
# $CLAUDE_ENG_SHELL_ROOT/.claude/state/pr-cache).
#
# Filename: <owner>%2F<repo>__pr-<n>.json — '/' URL-encoded as '%2F' so
# `<owner>/<repo>` slug boundaries survive the filename. Per-PR file holds:
#   { "last_seen_body_sha256": "...", "last_synced_head": "...",
#     "last_synced_at": "..." }
#
# Public:
#   pr_cache_read <pr_number>                          — print cached SHA;
#                                                        exit 0 if absent/valid,
#                                                        exit 2 + stderr if corrupt
#   pr_cache_write <pr_number> <body_sha256> <head>    — atomic write
#   pr_cache_check <pr_number> <remote_body_sha256>    — exit 0 if absent/match, !=0 + stderr if mismatch

_pr_cache_dir() {
  printf '%s' "${PR_CACHE_DIR:-${CLAUDE_ENG_SHELL_ROOT:-.}/.claude/state/pr-cache}"
}

_pr_cache_key() {
  # Derive <owner-url-encoded>__<repo-url-encoded>__pr-<n>. PR_CACHE_REPO
  # override for tests. URL-encode '/' as '%2F' so the `/` boundary survives
  # the filename — `tr '/' '_'` previously collapsed `acme/my_repo` and
  # `acme_my/repo` to the same key. GitHub repo names are restricted to
  # [A-Za-z0-9._-], so '/' is the only character ever encoded.
  local n="$1" repo=""
  if [ -n "${PR_CACHE_REPO:-}" ]; then
    repo="$PR_CACHE_REPO"
  elif command -v gh >/dev/null 2>&1; then
    repo=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)
  fi
  [ -z "$repo" ] && repo="unknown/unknown"
  printf '%s__pr-%s' "$(printf '%s' "$repo" | sed 's|/|%2F|g')" "$n"
}

_pr_cache_path() {
  printf '%s/%s.json' "$(_pr_cache_dir)" "$(_pr_cache_key "$1")"
}

pr_cache_read() {
  # Distinguishes three cases:
  #   - file absent           → exit 0, stdout empty (caller treats as first sync)
  #   - file present + valid  → exit 0, stdout = SHA
  #   - file present + corrupt→ exit 2, stderr warning (caller must abort)
  local path
  path=$(_pr_cache_path "$1")
  [ -f "$path" ] || return 0

  local sha=""
  if command -v jq >/dev/null 2>&1; then
    sha=$(jq -er '.last_seen_body_sha256 // ""' "$path" 2>/dev/null)
    if [ $? -ne 0 ]; then
      printf 'pr_cache: corrupt cache file at %s (jq parse failed)\n' "$path" >&2
      return 2
    fi
  else
    # Fallback parse — match the simple flat JSON we write.
    sha=$(grep -oE '"last_seen_body_sha256"[[:space:]]*:[[:space:]]*"[^"]*"' "$path" 2>/dev/null \
      | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
    # Heuristic for corruption when jq is missing: file is non-empty but no
    # key was found.
    if [ -z "$sha" ] && [ -s "$path" ]; then
      printf 'pr_cache: corrupt cache file at %s (key not found in fallback parse)\n' "$path" >&2
      return 2
    fi
  fi
  printf '%s' "$sha"
}

pr_cache_write() {
  local n="$1" body_sha="$2" head="${3:-}"
  local dir path tmp ts
  dir=$(_pr_cache_dir)
  path=$(_pr_cache_path "$n")
  tmp="$path.tmp.$$"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$dir" 2>/dev/null || return 1

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg sha "$body_sha" \
      --arg head "$head" \
      --arg ts "$ts" \
      '{last_seen_body_sha256: $sha, last_synced_head: $head, last_synced_at: $ts}' \
      > "$tmp" || return 1
  else
    # Minimal hand-formatted JSON if jq is missing.
    printf '{"last_seen_body_sha256":"%s","last_synced_head":"%s","last_synced_at":"%s"}\n' \
      "$body_sha" "$head" "$ts" > "$tmp" || return 1
  fi

  mv -f "$tmp" "$path"
}

pr_cache_check() {
  local n="$1" remote_sha="$2"
  local cached rc
  cached=$(pr_cache_read "$n")
  rc=$?
  # Corrupt cache → forward the abort; pr_cache_read already wrote to stderr.
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if [ -z "$cached" ]; then
    # No cache yet — first sync; treat as match.
    return 0
  fi
  if [ "$cached" = "$remote_sha" ]; then
    return 0
  fi
  printf 'pr_cache: external edit detected for PR #%s (cached=%s remote=%s)\n' \
    "$n" "$cached" "$remote_sha" >&2
  return 1
}