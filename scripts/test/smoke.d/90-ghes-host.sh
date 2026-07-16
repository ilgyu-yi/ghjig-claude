# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded source
# below never runs at runtime (the orchestrator already sourced the preamble); it
# only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §153: GHES host resolution — pin the repo host on host-less gh api (#610) ----------
# SPEC §5.29 / §6.1 (merge-review + file-review). Every host-LESS `gh api` call in
# the review/merge path resolves gh's DEFAULT host (github.com), not the repo's, so
# on a GitHub Enterprise Server (GHES) target the identity + the review FETCH/POST
# hit the wrong host. Phase A (already landed, file-review.md) pins `--hostname <h>`
# derived from `gh repo view --json url` on:
#   scripts/ghjig_file_review_post.sh   — the identity (`gh api user`) + the reviews POST
#   .claude/hooks/helpers/ac_closeout_gate.sh:
#       merge_is_self       — the merger (`gh api user`)
#       review_gate_accepts — the reviews FETCH + the self-marker merger (`gh api user`)
# with a charset/non-empty host guard that FAILS CLOSED (never a silent default-host
# fallback). Phase C (the host-pinning) DOES NOT EXIST YET — the behavioral cases
# below (§153-1/-2/-3/-4) are RED now because the code omits `--hostname`, and go
# GREEN when the pin lands. §153-5 (github.com no-regression) + the two static
# content-locks (§153-6/-7) stay GREEN across the change.
#
# ── The dual-host gh shim (the crux) ──────────────────────────────────────────
# A PATH-shadowing `gh` models a machine authed to BOTH github.com (gh's default
# host) AND a GHES host github.example.com. The repo lives on the GHES host. A call
# is "correctly targeted" iff it carries `--hostname <REPO_HOST>` (or the default
# host already IS the repo host, the github.com variant). Per-variant behavior is
# driven by config files under $GH_SHIM_STATE (repo_url / repo_host / default_login
# / repo_login / pr_author / head / reviews.json), so ONE shim serves every case.

S610_GATE="$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh"
S610_SHIPMODE="$SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh"
S610_WRAP_FILE="$SHELL_ROOT/scripts/ghjig_file_review_post.sh"
S610_STAGE_FILE="$SHELL_ROOT/scripts/ghjig_file_review_stage.sh"
S610_CMD="$SHELL_ROOT/.claude/commands/file-review.md"

# Hard tooling deps — fail LOUD (never a silent skip) so a missing tool cannot
# green the behavioral cases vacuously.
s610_have_tools=1
command -v git >/dev/null 2>&1 || { ng "153-tools: git required for the #610 GHES host cases (absent)"; s610_have_tools=0; }
command -v jq  >/dev/null 2>&1 || { ng "153-tools: jq required for the #610 GHES host cases (absent)"; s610_have_tools=0; }

if [ "$s610_have_tools" = 1 ]; then
  S610_DIR=$(mktemp -d)
  S610_BIN="$S610_DIR/bin"
  S610_PROJ="$S610_DIR/proj"
  S610_GCWD="$S610_DIR/gate-cwd"
  mkdir -p "$S610_BIN" "$S610_PROJ" "$S610_GCWD/.claude/state"

  # The dual-host shim. Distinguishes a host-pinned call from a bare one by
  # scanning "$@" for --hostname, and keys review FETCH/POST targeting on whether
  # the effective host equals the repo's host.
  cat > "$S610_BIN/gh" <<'SHIM'
#!/bin/sh
: "${GH_SHIM_STATE:?}"
default_host=github.com

# Extract the --hostname value (both `--hostname H` and `--hostname=H` forms).
hostarg=""
prev=""
for a in "$@"; do
  case "$a" in --hostname=*) hostarg="${a#--hostname=}" ;; esac
  [ "$prev" = "--hostname" ] && hostarg="$a"
  prev="$a"
done

repo_host=$(cat "$GH_SHIM_STATE/repo_host" 2>/dev/null)

case "$*" in
  *"repo view"*url*)
      # The bare-host value the doc's `--jq '.url|sub(...)'` idiom yields (empty
      # for a degenerate url). We serve the extracted value the caller's -q would
      # have produced (mirrors the §137 shim contract).
      cat "$GH_SHIM_STATE/repo_url" 2>/dev/null ;;
  *"repo view"*nameWithOwner*)
      printf 'o/r\n' ;;
  *"api user"*)
      # A repo-host-pinned identity lookup resolves the repo account; any other
      # (bare / default-host / wrong-host) resolves gh's default-host account.
      if [ -n "$hostarg" ] && [ "$hostarg" = "$repo_host" ]; then
        cat "$GH_SHIM_STATE/repo_login" 2>/dev/null
      else
        cat "$GH_SHIM_STATE/default_login" 2>/dev/null
      fi ;;
  *"pr view"*headRefOid*|*"pr view"*number*)
      # Repo-scoped: gh resolves the host from the local git remote, so the author
      # + head are host-correct regardless of --hostname (this is why the repo-
      # scoped calls need no pin — only the host-LESS `gh api user` is broken).
      printf '{"number":55,"headRefOid":"%s","author":{"login":"%s"}}\n' \
        "$(cat "$GH_SHIM_STATE/head" 2>/dev/null)" \
        "$(cat "$GH_SHIM_STATE/pr_author" 2>/dev/null)" ;;
  *"pr view"*author*)
      cat "$GH_SHIM_STATE/pr_author" 2>/dev/null ;;
  *reviews*event=*)
      # The reviews POST. Succeeds (and logs the host) only when correctly
      # targeted at the repo host; otherwise a 404-ish error (rc!=0).
      target="${hostarg:-$default_host}"
      if [ "$target" = "$repo_host" ]; then
        echo "post $target" >> "$GH_SHIM_STATE/post_log"
        printf '{"id":1,"commit_id":"h","state":"COMMENTED","user":"x"}\n'
        exit 0
      fi
      echo "gh: 404 — repo not on host $target" >&2
      exit 1 ;;
  *reviews*)
      # The reviews FETCH. The repo host serves the review array; the default host
      # has no knowledge of a GHES repo → an empty array.
      target="${hostarg:-$default_host}"
      if [ "$target" = "$repo_host" ]; then
        cat "$GH_SHIM_STATE/reviews.json" 2>/dev/null
      else
        printf '[]\n'
      fi ;;
esac
exit 0
SHIM
  chmod +x "$S610_BIN/gh"

  # A throwaway git repo the wrapper's stage writer reads (`git rev-parse HEAD`)
  # and whose HEAD the shim reports as the PR headRefOid (head-bind must match).
  ( cd "$S610_PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false && git checkout -q -b smoke/fix/610-ghes \
      && git commit --allow-empty -q -m init ) >/dev/null 2>&1 || true
  S610_GHEAD=$(cd "$S610_PROJ" && git rev-parse HEAD 2>/dev/null || echo nohead)

  # The gate cwd opts self-review IN so review_gate_accepts' self-marker shape (b)
  # is reachable (default is deny/fail-closed).
  printf 'allow\n' > "$S610_GCWD/.claude/state/self-review"

  # A fresh, valid staged body (created=now, head=current) for the wrapper.
  S610_BODY="$S610_DIR/body.txt"
  printf '<!-- file-review verdict=approve head=%s reviewer=code-reviewer -->\nlgtm\n' "$S610_GHEAD" > "$S610_BODY"

  s610_review_json() {  # $1=commit_id -> a single COMMENTED verdict=approve self-marker@head by ghes-user
    printf '[{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"ghes-user"},"user":{"login":"ghes-user"},"body":"<!-- file-review verdict=approve head=%s reviewer=code-reviewer -->"}]\n' \
      "$1" "$1"
  }

  # ── State dirs, one per variant ──────────────────────────────────────────────
  # GHES: repo on github.example.com, default host is github.com (wrong account).
  S610_ST_GHES="$S610_DIR/st-ghes"; mkdir -p "$S610_ST_GHES"
  printf 'github.example.com\n' > "$S610_ST_GHES/repo_url"
  printf 'github.example.com\n' > "$S610_ST_GHES/repo_host"
  printf 'dotcom-user\n'        > "$S610_ST_GHES/default_login"
  printf 'ghes-user\n'          > "$S610_ST_GHES/repo_login"
  printf 'ghes-user\n'          > "$S610_ST_GHES/pr_author"
  printf '%s\n' "$S610_GHEAD"   > "$S610_ST_GHES/head"
  s610_review_json "$S610_GHEAD" > "$S610_ST_GHES/reviews.json"

  # DEGENERATE: `gh repo view --json url` yields an empty/hostless value.
  S610_ST_DEGEN="$S610_DIR/st-degen"; mkdir -p "$S610_ST_DEGEN"
  : > "$S610_ST_DEGEN/repo_url"                               # empty → degenerate host
  printf 'github.example.com\n' > "$S610_ST_DEGEN/repo_host"
  printf 'dotcom-user\n'        > "$S610_ST_DEGEN/default_login"
  printf 'ghes-user\n'          > "$S610_ST_DEGEN/repo_login"
  printf 'ghes-user\n'          > "$S610_ST_DEGEN/pr_author"
  printf '%s\n' "$S610_GHEAD"   > "$S610_ST_DEGEN/head"
  s610_review_json "$S610_GHEAD" > "$S610_ST_DEGEN/reviews.json"

  # DOTCOM: repo on github.com — the default host already IS the repo host, so a
  # bare call is correctly targeted (no-regression baseline).
  S610_ST_DOTCOM="$S610_DIR/st-dotcom"; mkdir -p "$S610_ST_DOTCOM"
  printf 'github.com\n' > "$S610_ST_DOTCOM/repo_url"
  printf 'github.com\n' > "$S610_ST_DOTCOM/repo_host"
  printf 'ghes-user\n'  > "$S610_ST_DOTCOM/default_login"
  printf 'ghes-user\n'  > "$S610_ST_DOTCOM/repo_login"
  printf 'ghes-user\n'  > "$S610_ST_DOTCOM/pr_author"
  printf '%s\n' "$S610_GHEAD" > "$S610_ST_DOTCOM/head"
  s610_review_json "$S610_GHEAD" > "$S610_ST_DOTCOM/reviews.json"

  S610_FRDIR="$S610_PROJ/.claude/ghjig-state/file-review"
  s610_reset() { rm -f "$1/post_log" 2>/dev/null; rm -rf "$S610_FRDIR" 2>/dev/null; }
  s610_posts() { if [ -f "$1/post_log" ]; then wc -l < "$1/post_log" | tr -d ' '; else echo 0; fi; }
  s610_stage() { ( unset GHJIG_STATE_DIR_OVERRIDE; cd "$S610_PROJ" \
                      && CLAUDE_PROJECT_DIR="$S610_PROJ" PATH="$S610_BIN:$PATH" \
                         GH_SHIM_STATE="$1" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
                         bash "$S610_STAGE_FILE" "$S610_BODY" ) >/dev/null 2>&1 || true; }
  s610_post()  { ( unset GHJIG_STATE_DIR_OVERRIDE; cd "$S610_PROJ" \
                      && CLAUDE_PROJECT_DIR="$S610_PROJ" PATH="$S610_BIN:$PATH" \
                         GH_SHIM_STATE="$1" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
                         bash "$S610_WRAP_FILE" </dev/null ) >/dev/null 2>&1 || true; }

  # Drive review_gate_accepts by sourcing the real gate + ship_mode in a subshell
  # under the shim, from the self-review=allow cwd. Echoes the rc.
  s610_accepts() {  # $1=state dir
    ( cd "$S610_GCWD" || exit 3
      export PATH="$S610_BIN:$PATH" GH_SHIM_STATE="$1"
      . "$S610_SHIPMODE" 2>/dev/null || true
      . "$S610_GATE" 2>/dev/null || true
      command -v review_gate_accepts >/dev/null 2>&1 || { echo 3; exit; }
      review_gate_accepts 55 "$S610_GHEAD" >/dev/null 2>&1
      echo $?
    )
  }
  s610_isself() {  # $1=state dir
    ( cd "$S610_GCWD" || exit 3
      export PATH="$S610_BIN:$PATH" GH_SHIM_STATE="$1"
      . "$S610_GATE" 2>/dev/null || true
      command -v merge_is_self >/dev/null 2>&1 || { echo 3; exit; }
      merge_is_self 55 >/dev/null 2>&1
      echo $?
    )
  }

  # §153-1 (BEHAVIORAL — LOAD-BEARING RED): the wrapper's own-PR guard + reviews
  # POST must target the REPO host. The current-branch PR author resolves to
  # ghes-user (repo-scoped). Pre-Code the bare `gh api user` resolves the DEFAULT
  # host (dotcom-user) ≠ author → guard fails closed → NO POST. Post-Code the
  # host-pinned identity is ghes-user == author → posts, and the POST carries the
  # GHES host.
  s610_reset "$S610_ST_GHES"; s610_stage "$S610_ST_GHES"; s610_post "$S610_ST_GHES"
  s610_1p=$(s610_posts "$S610_ST_GHES")
  if [ "$s610_1p" = 1 ] && grep -q 'github.example.com' "$S610_ST_GHES/post_log" 2>/dev/null; then
    ok "153-1: wrapper own-PR guard resolves the repo-host identity → posts the self review to the GHES host (#610)"
  else
    ng "153-1: host-less gh api user reads the default-host account → own-PR guard fails → no GHES-host POST (posts=$s610_1p) (#610)"
  fi

  # §153-2 (BEHAVIORAL — LOAD-BEARING RED): review_gate_accepts must FETCH the
  # reviews from the repo host. Pre-Code the unpinned FETCH hits the default host
  # → empty array (repo not there) → not accepted (rc 1). Post-Code the pinned
  # FETCH serves the self-marker@head + the pinned merger == PR-author → accepts.
  s610_2rc=$(s610_accepts "$S610_ST_GHES")
  if [ "$s610_2rc" = 0 ]; then
    ok "153-2: review_gate_accepts reads the head-pinned review at the repo host → accepts (#610)"
  else
    ng "153-2: host-less reviews FETCH hits the default host → empty → review_gate_accepts does not accept (rc=$s610_2rc, want 0) (#610)"
  fi

  # §153-3 (BEHAVIORAL — LOAD-BEARING RED): merge_is_self must resolve the merger
  # identity at the repo host. Pre-Code the bare `gh api user` → dotcom-user ≠
  # author ghes-user → 1 (not-self). Post-Code the pinned merger == author → 0.
  s610_3rc=$(s610_isself "$S610_ST_GHES")
  if [ "$s610_3rc" = 0 ]; then
    ok "153-3: merge_is_self resolves the merger at the repo host → detects the self-merge (0) (#610)"
  else
    ng "153-3: host-less merger identity ≠ repo-host author → merge_is_self returns not-self (rc=$s610_3rc, want 0) (#610)"
  fi

  # §153-4 (BEHAVIORAL — fail-closed lock): a degenerate/hostless `gh repo view
  # --json url` must FAIL CLOSED — the wrapper posts NOTHING and merge_is_self
  # returns 2 (block/indeterminate), NEVER a silent default-host fallback. Post-
  # Code the charset/non-empty host guard aborts before any host-pinned call.
  s610_reset "$S610_ST_DEGEN"; s610_stage "$S610_ST_DEGEN"; s610_post "$S610_ST_DEGEN"
  s610_4p=$(s610_posts "$S610_ST_DEGEN")
  s610_4rc=$(s610_isself "$S610_ST_DEGEN")
  if [ "$s610_4p" = 0 ] && [ "$s610_4rc" = 2 ]; then
    ok "153-4: degenerate/hostless repo url → wrapper posts nothing + merge_is_self blocks (2), no default-host fallback (#610)"
  else
    ng "153-4: a hostless repo url must fail closed — no POST + merge_is_self=2 (posts=$s610_4p isself=$s610_4rc, want 0/2) (#610)"
  fi

  # §153-5 (BEHAVIORAL — github.com no-regression): when the repo IS on github.com
  # (the default host already the repo host), the wrapper still posts and
  # merge_is_self still detects self — GREEN both pre- and post-Code.
  s610_reset "$S610_ST_DOTCOM"; s610_stage "$S610_ST_DOTCOM"; s610_post "$S610_ST_DOTCOM"
  s610_5p=$(s610_posts "$S610_ST_DOTCOM")
  s610_5rc=$(s610_isself "$S610_ST_DOTCOM")
  if [ "$s610_5p" = 1 ] && [ "$s610_5rc" = 0 ]; then
    ok "153-5: github.com repo (default host == repo host) — wrapper posts + merge_is_self detects self, no regression (#610)"
  else
    ng "153-5: github.com no-regression broke — wrapper must post + merge_is_self=0 (posts=$s610_5p isself=$s610_5rc) (#610)"
  fi

  rm -rf "$S610_DIR"
fi

# §153-6 (STATIC content-lock — GREEN, Phase A landed): file-review.md's <pr>
# validation is HOST-AGNOSTIC — it carries the `^https?://[^/]+/[^/]+/[^/]+/pull/`
# any-host regex, KEEPS the numeric `^[0-9]+$` arm, and the reject text NO LONGER
# hardcodes a "github.com pull URL". Positive + negative fused so a stray edit
# cannot green it vacuously.
s610_6_re=0; s610_6_num=0; s610_6_nohard=1
if [ -f "$S610_CMD" ]; then
  grep -qF '^https?://[^/]+/[^/]+/[^/]+/pull/' "$S610_CMD" 2>/dev/null && s610_6_re=1
  grep -qF '^[0-9]+$' "$S610_CMD" 2>/dev/null && s610_6_num=1
  grep -qF 'github.com pull URL' "$S610_CMD" 2>/dev/null && s610_6_nohard=0
fi
if [ "$s610_6_re" = 1 ] && [ "$s610_6_num" = 1 ] && [ "$s610_6_nohard" = 1 ]; then
  ok "153-6: file-review.md <pr> validation is host-agnostic (any-host pull regex + ^[0-9]+\$ arm, no 'github.com pull URL' reject text) (#610)"
else
  ng "153-6: file-review.md must accept an any-host pull URL + keep ^[0-9]+\$ and drop 'github.com pull URL' (re=$s610_6_re num=$s610_6_num nohard=$s610_6_nohard) (#610)"
fi

# §153-7 (STATIC content-lock — GREEN, do not break §143e): the ownership lookup
# still uses the literal `gh api user` (the `--hostname` pin trails it). This
# guards that the #610 pin did not accidentally rewrite the token §143e keys on.
if [ -f "$S610_CMD" ] && grep -qF 'gh api user' "$S610_CMD" 2>/dev/null; then
  ok "153-7: file-review.md still carries the literal 'gh api user' ownership lookup (§143e stays green) (#610)"
else
  ng "153-7: file-review.md lost the literal 'gh api user' token — would break the §143e content-lock (#610)"
fi
