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

  # A throwaway git repo whose HEAD the wrapper reads (`git rev-parse HEAD`, the
  # local-checkout head arm) and which the shim reports as the PR headRefOid — both
  # head-bind arms must match for the positive cases to reach the POST (#633).
  ( cd "$S610_PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false && git checkout -q -b smoke/fix/610-ghes \
      && git commit --allow-empty -q -m init ) >/dev/null 2>&1 || true
  S610_GHEAD=$(cd "$S610_PROJ" && git rev-parse HEAD 2>/dev/null || echo nohead)

  # The gate cwd opts self-review IN so review_gate_accepts' self-marker shape (b)
  # is reachable (default is deny/fail-closed).
  printf 'allow\n' > "$S610_GCWD/.claude/state/self-review"

  # A fresh, valid review body for the wrapper — marker head= the current head, no header
  # stamps (#633: the caller writes the staging file itself; there is no writer script).
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
  # #633: the producer is ONE link — the caller writes the staging file itself. No writer
  # script and no argv; the harness therefore writes the body straight to the fixed leaf the
  # wrapper resolves under CLAUDE_PROJECT_DIR/.claude/ghjig-state/.
  s610_stage() { mkdir -p "$S610_FRDIR" && cp "$S610_BODY" "$S610_FRDIR/staging"; }
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

# ---------- §154: GHES host resolution — the two NON-review-path host-less sites (#614) ----------
# SPEC §5.29. #610 pinned every host-LESS `gh api` in the review/merge path; #614
# closes the SAME GHES gap on the two remaining non-review sites that resolve gh's
# DEFAULT host (github.com), not the repo's:
#   scripts/lib/onboard_checks.sh   — the branch-protection `gh api …/protection`
#   scripts/release_consolidate.sh  — the CHANGELOG footer reference link
# The Code (host-derivation via `gh repo view --json url`, fail-closed — #610's
# mechanism) DOES NOT EXIST YET, so the two BEHAVIORAL GHES cases (§154-1/-3) are
# RED now and go GREEN when the host-pin/derivation lands. The two github.com
# no-regression cases (§154-2/-4) stay GREEN across the change.
#
# The shims model a machine whose repo lives on github.example.com while gh's
# DEFAULT host is github.com: a `gh api …/protection` (onboard) resolves the repo
# iff it carries `--hostname github.example.com`; a footer link (release) is
# host-correct iff built from the repo host, not a hardcoded github.com.

s614_have_tools=1
command -v git >/dev/null 2>&1 || { ng "154-tools: git required for the #614 GHES host cases (absent) (#614)"; s614_have_tools=0; }
command -v jq  >/dev/null 2>&1 || { ng "154-tools: jq required for the #614 GHES host cases (absent) (#614)"; s614_have_tools=0; }

if [ "$s614_have_tools" = 1 ]; then
  S614_DIR=$(mktemp -d)
  S614_OBIN="$S614_DIR/obin"          # onboard gh shim
  S614_RBIN="$S614_DIR/rbin"          # release gh shim
  mkdir -p "$S614_OBIN" "$S614_RBIN"

  S614_ONBOARD="$SHELL_ROOT/scripts/lib/onboard_checks.sh"
  S614_RELEASE="$SHELL_ROOT/scripts/release_consolidate.sh"

  # ── onboard gh shim ──────────────────────────────────────────────────────────
  # A `gh api …/protection` succeeds (exit 0 → protected) ONLY when the effective
  # host (the --hostname value, else gh's default github.com) equals the repo host.
  # The url arm serves gh's normalized https url the #610 host-derivation chops.
  cat > "$S614_OBIN/gh" <<'SHIM'
#!/bin/sh
: "${GH_SHIM_STATE:?}"
repo_host=$(cat "$GH_SHIM_STATE/repo_host" 2>/dev/null)
default_host=github.com
hostarg=""; prev=""
for a in "$@"; do
  case "$a" in --hostname=*) hostarg="${a#--hostname=}" ;; esac
  [ "$prev" = "--hostname" ] && hostarg="$a"; prev="$a"
done
case "$*" in
  *"repo view"*isFork*)           printf 'false\n' ;;
  *"repo view"*viewerPermission*) printf 'ADMIN\n' ;;
  *"repo view"*defaultBranchRef.name*) printf 'main\n' ;;
  *"repo view"*url*)              printf 'https://%s/o/r\n' "$repo_host" ;;
  *"repo view"*nameWithOwner*)    printf 'o/r\n' ;;
  *api*protection*)
      target="${hostarg:-$default_host}"
      [ "$target" = "$repo_host" ] && exit 0
      echo "gh: 404 — repo not on host $target" >&2
      exit 1 ;;
esac
exit 0
SHIM
  chmod +x "$S614_OBIN/gh"

  S614_OCWD="$S614_DIR/onboard-cwd"; mkdir -p "$S614_OCWD"
  S614_ST_GHES="$S614_DIR/o-ghes"; mkdir -p "$S614_ST_GHES"; printf 'github.example.com\n' > "$S614_ST_GHES/repo_host"
  S614_ST_DOT="$S614_DIR/o-dot";   mkdir -p "$S614_ST_DOT";  printf 'github.com\n'         > "$S614_ST_DOT/repo_host"

  s614_bprotect() {  # $1=state dir -> the `branch-protect` status token
    ( cd "$S614_OCWD" \
        && PATH="$S614_OBIN:$PATH" GH_SHIM_STATE="$1" bash "$S614_ONBOARD" 2>/dev/null ) \
      | awk '$1=="branch-protect"{print $2; exit}'
  }

  # §154-1 (BEHAVIORAL — LOAD-BEARING RED): the /onboard branch-protection check
  # must target the REPO host. The repo is on github.example.com; the shim's
  # `…/protection` succeeds only when the call carries `--hostname github.example.com`.
  # Pre-Code the host-LESS `gh api …/protection` resolves the default host
  # (github.com) → the shim 404s → `branch-protect fail`. Post-Code the derived
  # `--hostname github.example.com` pin → the repo resolves → `branch-protect ok`.
  s614_1=$(s614_bprotect "$S614_ST_GHES")
  if [ "$s614_1" = ok ]; then
    ok "154-1: onboard branch-protection check host-pins to the GHES repo host → reports protected (#614)"
  else
    ng "154-1: host-less gh api …/protection hits the default host → GHES repo unreadable → branch-protect '$s614_1' (want ok) (#614)"
  fi

  # §154-2 (BEHAVIORAL — github.com no-regression): when the repo IS on github.com
  # (default host == repo host), the bare `gh api …/protection` already targets the
  # repo host → protected. GREEN both pre- and post-Code (bare ≡ --hostname github.com).
  s614_2=$(s614_bprotect "$S614_ST_DOT")
  if [ "$s614_2" = ok ]; then
    ok "154-2: onboard branch-protection check on a github.com repo still reports protected — no regression (#614)"
  else
    ng "154-2: github.com no-regression broke — branch-protect must be ok (got '$s614_2') (#614)"
  fi

  # ── release gh shim (serves the #610 host-derivation call, if the Code uses it) ─
  cat > "$S614_RBIN/gh" <<'SHIM'
#!/bin/sh
repo_host="${GH_SHIM_REPO_HOST:-github.com}"
case "$*" in
  *"repo view"*url*)           printf 'https://%s/o/r\n' "$repo_host" ;;
  *"repo view"*nameWithOwner*) printf 'o/r\n' ;;
esac
exit 0
SHIM
  chmod +x "$S614_RBIN/gh"

  # Build a minimal fixture repo and run release_consolidate --dry-run end-to-end,
  # returning the CHANGELOG footer reference-link line for `origin`=$1, repo_host=$2.
  s614_release_footer() {  # $1=origin url  $2=repo host -> the appended `[X]: …` line (or empty)
    ( proj="$S614_DIR/rel-$2"; rm -rf "$proj"; mkdir -p "$proj/changelog_unreleased/added"
      cd "$proj" || exit 3
      git init -q; git config user.email t@t; git config user.name t; git config commit.gpgsign false
      printf '0.1.0-dev\n' > VERSION
      printf '# Changelog\n\n## [0.0.1] — 2020-01-01\n\n### Added\n\n- seed (#0)\n' > CHANGELOG.md
      printf -- '- something happened (#1)\n' > changelog_unreleased/added/1.md
      git add -A >/dev/null 2>&1; git commit -qm init >/dev/null 2>&1
      git remote add origin "$1"
      PATH="$S614_RBIN:$PATH" GH_SHIM_REPO_HOST="$2" \
        bash "$S614_RELEASE" 0.1.0 --dry-run >/dev/null 2>&1
      grep -F 'releases/tag/v0.1.0' CHANGELOG.md 2>/dev/null | tail -n1 )
  }

  # §154-3 (BEHAVIORAL — LOAD-BEARING RED): the /release CHANGELOG footer link must
  # be built from the REPO host. With a GHES origin the appended line must be
  # `[0.1.0]: https://github.example.com/o/r/releases/tag/v0.1.0`. Pre-Code the
  # origin-parse `sed` only matches literal `github.com` (absent in a GHES remote)
  # so it never rewrites the host and the link hardcodes `https://github.com/…` →
  # a wrong-host (or empty) link, NOT the GHES url. Post-Code the host-generic
  # derivation emits the github.example.com link.
  s614_3=$(s614_release_footer 'git@github.example.com:o/r.git' 'github.example.com')
  if printf '%s' "$s614_3" | grep -qxF '[0.1.0]: https://github.example.com/o/r/releases/tag/v0.1.0'; then
    ok "154-3: release footer link is built from the GHES repo host → github.example.com release URL (#614)"
  else
    ng "154-3: GHES origin → footer link is not the repo-host URL (got: '${s614_3:-<none>}', want github.example.com) (#614)"
  fi

  # §154-4 (BEHAVIORAL — github.com no-regression): a github.com origin still emits
  # `[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0` (the host-generic parse
  # yields the same owner/repo). GREEN both pre- and post-Code.
  s614_4=$(s614_release_footer 'git@github.com:o/r.git' 'github.com')
  if printf '%s' "$s614_4" | grep -qxF '[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0'; then
    ok "154-4: release footer link on a github.com origin still emits the github.com release URL — no regression (#614)"
  else
    ng "154-4: github.com no-regression broke — footer link must be the github.com URL (got: '${s614_4:-<none>}') (#614)"
  fi

  rm -rf "$S614_DIR"
fi

# ---------- §189: GHES host resolution — the evidence gates' graphql round-trip (#745) ----------
# SPEC §6.1 (activation-evidence + completion-evidence), the two rows the #745 Doc
# phase amended. `_evidence_issue_gql` (.claude/hooks/helpers/ac_closeout_gate.sh)
# issues the ONE `gh api graphql` round-trip both evidence gates read with NO
# `--hostname`. `gh api` does no repo inference, so the call resolves gh's DEFAULT
# host (github.com): on a GHES target the repository never resolves (HTTP 200 with
# `errors[].type == NOT_FOUND` and `repository == null`), the gates' jq arm returns
# `lookup`, both callers `|| return 2`, and pre_tool_use.sh's `*)` arms block with
# the lookup-failure message. Every dir-mode activation/completion on a GHES repo
# is therefore hard-blocked. The three sibling `gh api` sites in the same file are
# already host-pinned via `_ac_repo_host` (merge_is_self, review_gate_accepts ×2,
# #610) — this is the one that was missed.
#
# The Code phase pins ONLY the cwd-derived branch. `_ac_repo_host` resolves the
# CWD repo's host, not the target's, so an unconditional pin would send an explicit
# `--repo owner/name` target to the cwd's GHES host and mint a NEW wrong block on a
# path that works today; an explicit selector must keep gh's own selector host
# semantics. Consequence for this suite: driving a case through `--repo` exercises
# the branch the fix leaves alone (green before AND after — vacuous as a RED), so
# the load-bearing RED case is "GHES cwd, NO --repo" (§189-1/-2/-5), and the
# explicit-selector case (§189-4) is a no-break lock, not a defect witness.
#
# ── The shim ──────────────────────────────────────────────────────────────────
# Its own dual-host `gh` (NOT an extension of §153's — five §153 behavioural arms
# depend on that shim's per-variant contract and perturbing it risks regressing
# them). Modelled on §154's: `repo view --json nameWithOwner,url -q .url` serves a
# full `https://<host>/o/r` url, because `_ac_repo_host` reads exactly that field.
# Two independent state knobs, which is what separates the four variants:
#   repo_url — what the CWD repo's `gh repo view` reports (the derivation input)
#   api_host — the host at which the graphql `repository(owner,name)` lookup
#              actually resolves (the TARGET's host)
# A graphql call is correctly targeted iff its effective host (the `--hostname`
# value, else gh's default github.com) equals api_host; otherwise the shim serves
# the real GHES miss shape (200 + NOT_FOUND + repository null). `answer_any`
# makes the shim answer a BARE call too — used only by the degenerate variant, so
# a silent default-host fallback would surface there as a wrong ALLOW.

S745_GATE="$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh"

# Hard tooling deps — fail LOUD (never a silent skip): the gates' verdict is a jq
# expression, so a missing jq would collapse every arm to the fail-closed rc and
# green §189-2 vacuously.
s745_have_tools=1
command -v jq >/dev/null 2>&1 || { ng "189-tools: jq required for the #745 evidence-graphql host cases (absent) (#745)"; s745_have_tools=0; }
[ -f "$S745_GATE" ] || { ng "189-tools: ac_closeout_gate.sh not found at $S745_GATE (#745)"; s745_have_tools=0; }

if [ "$s745_have_tools" = 1 ]; then
  S745_DIR="$TMP/s745"
  S745_BIN="$S745_DIR/bin"
  S745_FX="$S745_DIR/fixtures"
  S745_CWD="$S745_DIR/cwd"
  mkdir -p "$S745_BIN" "$S745_FX" "$S745_CWD"

  cat > "$S745_BIN/gh" <<'SHIM'
#!/bin/sh
: "${GH_SHIM_STATE:?}"
default_host=github.com

# Extract the --hostname value (both `--hostname H` and `--hostname=H` forms).
hostarg=""; prev=""
for a in "$@"; do
  case "$a" in --hostname=*) hostarg="${a#--hostname=}" ;; esac
  [ "$prev" = "--hostname" ] && hostarg="$a"
  prev="$a"
done

api_host=$(cat "$GH_SHIM_STATE/api_host" 2>/dev/null)

case " $* " in
  *" api graphql "*)
      target="${hostarg:-$default_host}"
      if [ "$target" = "$api_host" ] || [ -f "$GH_SHIM_STATE/answer_any" ]; then
        [ -n "${GH_GQL_FIXTURE:-}" ] && cat "$GH_GQL_FIXTURE" 2>/dev/null
        exit 0
      fi
      # The GHES miss: `gh api` resolved the WRONG host, so the repository never
      # resolves — HTTP 200 carrying a NOT_FOUND error with repository == null.
      printf '{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository with the name."}]}\n'
      exit 0 ;;
  # `gh repo view` / `gh issue view` are REPO-SCOPED: gh infers the host from the
  # local git remote, so they are host-correct with or without --hostname (which
  # is why only the host-LESS `gh api` is broken). Keyed on the caller's exact -q
  # expression so the three repo-view reads stay distinguishable.
  *" -q .url "*)         cat "$GH_SHIM_STATE/repo_url" 2>/dev/null; exit 0 ;;
  *" -q .owner.login "*) printf 'o\n'; exit 0 ;;
  *" -q .name "*)        printf 'r\n'; exit 0 ;;
  *" issue view "*labels*) printf 'directive\n'; exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$S745_BIN/gh"

  # ── GraphQL fixtures ────────────────────────────────────────────────────────
  # Timeline: createdAt 09:00 < lastEditedAt 10:00 < lastLabelEvent 10:05 <
  # pass 10:10. Freshness pivot = max(10:00, 10:05) = 10:05.
  cat > "$S745_FX/act_fresh.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"<!-- activation-verdict: pass -->\nActivation review: pass."}]}}}}}
JSON
  cat > "$S745_FX/act_absent.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"<!-- activation-verdict: revise -->\nFindings: tighten the AC."}]}}}}}
JSON
  cat > "$S745_FX/act_stale.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:20:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"<!-- activation-verdict: pass -->\nActivation review: pass."}]}}}}}
JSON
  cat > "$S745_FX/comp_present.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"## Directive Completion (resolved by PR #9)\nAll acceptance criteria delivered."}]}}}}}
JSON

  # ── Variants ────────────────────────────────────────────────────────────────
  # GHES: cwd repo AND target both on github.example.com; gh's default host is
  # github.com, which knows nothing of the repo.
  S745_ST_GHES="$S745_DIR/st-ghes"; mkdir -p "$S745_ST_GHES"
  printf 'https://github.example.com/o/r\n' > "$S745_ST_GHES/repo_url"
  printf 'github.example.com\n'             > "$S745_ST_GHES/api_host"

  # DEGENERATE: `gh repo view --json url` yields an empty/hostless value, so no
  # host can be derived — and the shim ANSWERS a bare default-host call, so a
  # silent fallback would show up as a wrong ALLOW rather than a quiet pass.
  S745_ST_DEGEN="$S745_DIR/st-degen"; mkdir -p "$S745_ST_DEGEN"
  : > "$S745_ST_DEGEN/repo_url"
  printf 'github.example.com\n' > "$S745_ST_DEGEN/api_host"
  : > "$S745_ST_DEGEN/answer_any"

  # DOTCOM: repo on github.com — the default host already IS the repo host.
  S745_ST_DOTCOM="$S745_DIR/st-dotcom"; mkdir -p "$S745_ST_DOTCOM"
  printf 'https://github.com/o/r\n' > "$S745_ST_DOTCOM/repo_url"
  printf 'github.com\n'             > "$S745_ST_DOTCOM/api_host"

  # EXPLICIT-SELECTOR: the cwd repo is on GHES but the caller names a target that
  # lives on gh's DEFAULT host (`--repo o/n`, the #231/#237 URL/flag shapes). This
  # is the live workaround, and the case an unconditional cwd-derived pin breaks.
  S745_ST_XSEL="$S745_DIR/st-xsel"; mkdir -p "$S745_ST_XSEL"
  printf 'https://github.example.com/o/r\n' > "$S745_ST_XSEL/repo_url"
  printf 'github.com\n'                     > "$S745_ST_XSEL/api_host"

  # ── Drivers: source the REAL gate in a subshell under the shim, echo the rc ──
  s745_act() {  # $1=state dir  $2=fixture  $3=issue#  [$4=owner/name] -> rc
    ( cd "$S745_CWD" || exit 9
      export PATH="$S745_BIN:$PATH" GH_SHIM_STATE="$1" GH_GQL_FIXTURE="$2"
      # shellcheck source=/dev/null
      . "$S745_GATE" 2>/dev/null || true
      command -v activation_evidence_fresh >/dev/null 2>&1 || { echo 9; exit; }
      activation_evidence_fresh "$3" "${4:-}" >/dev/null 2>&1
      echo $?
    )
  }
  s745_comp() {  # $1=state dir  $2=fixture  $3=issue#  [$4=owner/name] -> rc
    ( cd "$S745_CWD" || exit 9
      export PATH="$S745_BIN:$PATH" GH_SHIM_STATE="$1" GH_GQL_FIXTURE="$2"
      # shellcheck source=/dev/null
      . "$S745_GATE" 2>/dev/null || true
      command -v completion_evidence_present >/dev/null 2>&1 || { echo 9; exit; }
      completion_evidence_present "$3" "${4:-}" >/dev/null 2>&1
      echo $?
    )
  }
  s745_gql() {  # $1=state dir  $2=fixture  $3=issue#  $4=owner/name -> resolved|lookup|rc-<n>
    ( cd "$S745_CWD" || exit 9
      export PATH="$S745_BIN:$PATH" GH_SHIM_STATE="$1" GH_GQL_FIXTURE="$2"
      # shellcheck source=/dev/null
      . "$S745_GATE" 2>/dev/null || true
      command -v _evidence_issue_gql >/dev/null 2>&1 || { echo "fn-absent"; exit; }
      local json rc=0
      json=$(_evidence_issue_gql "$3" "$4" 2>/dev/null) || rc=$?
      [ "$rc" = 0 ] || { echo "rc-$rc"; exit; }
      printf '%s' "$json" | jq -r '
        if ((.errors // []) | length) > 0 or (.data.repository.issue == null)
        then "lookup" else "resolved" end' 2>/dev/null || echo "jq-fail"
    )
  }

  # §189-1 (BEHAVIORAL — LOAD-BEARING RED, AC2): on a GHES cwd with NO --repo,
  # activation_evidence_fresh must keep its full verdict taxonomy — 0 fresh /
  # 1 absent / 3 stale. Pre-Code the host-LESS `gh api graphql` resolves gh's
  # default host, the repository is NOT_FOUND there, and all three collapse to
  # the fail-closed 2 (the hard block this issue reports). Post-Code the derived
  # `--hostname github.example.com` pin reaches the repo and the three verdicts
  # separate again.
  s745_1f=$(s745_act "$S745_ST_GHES" "$S745_FX/act_fresh.json" 43)
  s745_1a=$(s745_act "$S745_ST_GHES" "$S745_FX/act_absent.json" 43)
  s745_1s=$(s745_act "$S745_ST_GHES" "$S745_FX/act_stale.json" 43)
  if [ "$s745_1f" = 0 ] && [ "$s745_1a" = 1 ] && [ "$s745_1s" = 3 ]; then
    ok "189-1: GHES cwd, no --repo — activation_evidence_fresh host-pins the graphql round-trip and returns 0/1/3 for fresh/absent/stale (#745)"
  else
    ng "189-1: host-less gh api graphql hits the default host → GHES repo NOT_FOUND → the verdicts collapse to the fail-closed rc (fresh=$s745_1f absent=$s745_1a stale=$s745_1s, want 0/1/3) (#745)"
  fi

  # §189-2 (BEHAVIORAL — LOAD-BEARING RED, fail-closed lock): a degenerate/
  # hostless `gh repo view --json url` yields NO derivable host → the gate must
  # return 2 (block/indeterminate), NEVER fall back to the default host. This
  # shim ANSWERS the bare default-host call with the FRESH fixture, so the
  # forbidden fallback shows up as a wrong ALLOW (0) — which is exactly what the
  # un-pinned head does. Post-Code the #610 charset/non-empty guard aborts before
  # the round-trip.
  s745_2=$(s745_act "$S745_ST_DEGEN" "$S745_FX/act_fresh.json" 43)
  if [ "$s745_2" = 2 ]; then
    ok "189-2: undrivable repo host → the evidence lookup fails CLOSED (2), never a silent default-host answer (#745)"
  else
    ng "189-2: a hostless repo url must fail closed — got rc=$s745_2 (want 2); rc=0 is the default host's answer leaking through as an ALLOW (#745)"
  fi

  # §189-3 (BEHAVIORAL — github.com no-regression): when the repo IS on github.com
  # the default host already is the repo host, so the bare call is already
  # correctly targeted — fresh evidence reads fresh (0) both pre- and post-Code
  # (bare ≡ --hostname github.com).
  s745_3=$(s745_act "$S745_ST_DOTCOM" "$S745_FX/act_fresh.json" 43)
  if [ "$s745_3" = 0 ]; then
    ok "189-3: github.com repo (default host == repo host) — fresh activation evidence still reads fresh, no regression (#745)"
  else
    ng "189-3: github.com no-regression broke — activation_evidence_fresh must be 0 on fresh evidence (got rc=$s745_3) (#745)"
  fi

  # §189-4 (BEHAVIORAL — no-break lock on the live workaround): an EXPLICIT
  # `owner/name` selector from a GHES cwd names a target on gh's DEFAULT host, so
  # the lookup resolves TODAY. `_ac_repo_host` derives the CWD host, not the
  # target's — an unconditional pin would send `--hostname github.example.com`
  # here and turn a working path into a NOT_FOUND. GREEN pre- AND post-Code; it
  # goes RED only if the Code pins the explicit-selector branch too.
  s745_4=$(s745_gql "$S745_ST_XSEL" "$S745_FX/act_fresh.json" 43 "o/n")
  if [ "$s745_4" = resolved ]; then
    ok "189-4: explicit owner/name selector from a GHES cwd keeps gh's own selector host semantics — still resolves (#745)"
  else
    ng "189-4: the explicit-selector path must stay resolvable (got '$s745_4', want resolved) — a cwd-derived pin on this branch breaks a working path (#745)"
  fi

  # §189-5 (BEHAVIORAL — LOAD-BEARING RED, the second §6.1 row): the completion
  # gate rides the SAME round-trip, so it carries the SAME defect. On a
  # `directive`-labelled Issue with the §5.13 closing comment present, the gate
  # must return 0. Pre-Code the label branch passes (repo-scoped `gh issue view`
  # is host-correct) and then the host-less graphql NOT_FOUNDs → 2. Post-Code the
  # pinned round-trip sees the comment → 0.
  s745_5=$(s745_comp "$S745_ST_GHES" "$S745_FX/comp_present.json" 44)
  if [ "$s745_5" = 0 ]; then
    ok "189-5: GHES cwd — completion_evidence_present reads the closing comment through the host-pinned round-trip (0) (#745)"
  else
    ng "189-5: host-less graphql → the directive's completion comment is unreadable on GHES (rc=$s745_5, want 0) (#745)"
  fi
fi

# §189-6 (STATIC content-lock — RED at head, fused positive+negative in the
# §153-6/-7 shape): scoped to `_evidence_issue_gql`'s OWN function body (from its
# `() {` to the closing `}`) — a file-wide grep would be vacuously green, since the
# three sibling `gh api` sites in the same file already carry `--hostname` (#610).
# Inside that body: `--hostname` must appear (the host pin, in whatever shape the
# Code chooses — a literal flag pair, an array, a variable run) AND the literal
# adjacent `api graphql` token must survive (the token §188's shim matcher and the
# sibling call-shape reads key on). Fused so neither half can green the arm alone:
# deleting the round-trip would satisfy a naive "no unpinned call" negative, and a
# `--hostname` added anywhere else in the file does not satisfy the scoped positive.
s745_6_body=""
[ -f "$S745_GATE" ] && s745_6_body=$(awk '/^_evidence_issue_gql\(\)[[:space:]]*\{/{f=1} f{print; if ($0 ~ /^\}/) exit}' "$S745_GATE" 2>/dev/null)
s745_6_pin=0; s745_6_tok=0
printf '%s' "$s745_6_body" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*#.*$//' | grep -q -- '--hostname' && s745_6_pin=1
printf '%s' "$s745_6_body" | grep -qE '(^|[^-[:alnum:]])api[[:space:]]+graphql([^-[:alnum:]]|$)' && s745_6_tok=1
if [ "$s745_6_pin" = 1 ] && [ "$s745_6_tok" = 1 ]; then
  ok "189-6: _evidence_issue_gql's body carries the --hostname pin and still carries the literal 'api graphql' token (#745)"
else
  ng "189-6: the evidence round-trip must be host-pinned inside _evidence_issue_gql while keeping the literal 'api graphql' token (pin=$s745_6_pin tok=$s745_6_tok) (#745)"
fi
