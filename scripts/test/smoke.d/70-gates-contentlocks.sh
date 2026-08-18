# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §137: un-skippable pre-merge gate — push-parity + merge-review (#544, #586) ----------
# SPEC §6.1 (`gh pr merge` matcher rows) + §5.7/§5.7.1. Two independent arms on
# the `gh pr merge` matcher, folded into helpers/ac_closeout_gate.sh:
#
#   push-parity (git-only, #244) — block when the local branch is STRICTLY AHEAD
#     of its pushed remote-tracking head (unpushed commits the merge would leave
#     behind): `git merge-base --is-ancestor <remote> <local>` true AND the two
#     SHAs differ. POSITIVE detection — behind / diverged / no-upstream / detached
#     → allow. Block message names "push your local commits first". Already shipped
#     (#544), so its cases (137p) stay GREEN.
#   merge-review (#586, #585, #543 — REPLACES the retired merge-attestation file
#     arm, #246/#544) — block a `gh pr merge` lacking a passing GitHub review
#     PINNED TO THE CURRENT HEAD. Reads the review OBJECTS authoritatively via
#     `gh api repos/{owner}/{repo}/pulls/<n>/reviews` (state / commit_id /
#     author.login per review), the head via `gh pr view <n> --json headRefOid`,
#     the PR author via `gh pr view <n> --json author`, the merger via `gh api
#     user`, owner/repo via `gh repo view --json nameWithOwner`. AGGREGATION:
#     filter reviews to state ∈ {APPROVED, CHANGES_REQUESTED}, then latest-per-
#     author wins (COMMENTED/PENDING/DISMISSED ignored — mirrors reviewDecision).
#     ALLOW in exactly two shapes: (a) native — an APPROVED review with
#     commit_id==head and no author's filtered-latest is CHANGES_REQUESTED; (b)
#     self-marker — a COMMENTED review@head carrying exactly ONE verdict=approve
#     marker whose author.login == PR-author == merger, no outstanding
#     CHANGES_REQUESTED. BLOCK on: no review / only stale (commit_id!=head) / an
#     author's filtered-latest is CHANGES_REQUESTED / verdict=block / conflicting
#     or multiple markers / empty head. BYPASS (resolve_review_gate → bypass) →
#     allow + a LOUD `audit_log warn merge-review bypass`. FAIL-CLOSED (block) on
#     ANY lookup failure (gh down/timeout, PR unresolvable, malformed JSON, helper
#     miss) — the deliberate divergence from the retired arm's fail-open staleness
#     leg. SPEC §6.1 merge-review row + §5.7.1 review-gate toggle.
#
# The merge-review arm DOES NOT EXIST YET (Phase B / Doc→Test→Code): review_gate_
# accepts, resolve_review_gate, and the merge-review matcher are unwritten, and
# the merge-attestation arm it REPLACES is still in place (its swap is Phase C).
# So every `gh pr merge` in the merge-review cases below falls through to that
# incumbent arm — which blocks on the absent attest file under
# category=merge-attestation (block cases + fail-closed case), or would need an
# attest file to allow (allow / bypass cases) — NEVER to a merge-review decision.
# Each merge-review assertion therefore keys on the `merge-review` audit category
# / rc the absent arm cannot produce (the block/fail-closed cases demand
# category=merge-review, not merge-attestation; the allow/bypass cases demand
# rc=0 the incumbent's presence-block cannot give), so every one reports RED now
# — arm absent ⇒ wrong category or wrong rc ⇒ RED, never a vacuous pass.
# CRITICAL: these cases do NOT seed an attest/pr-<N> file (that would let the
# incumbent arm allow and mask the RED) and do NOT touch the global attest seed
# (smoke.sh ~L59-71) — Phase C reworks that seed together with the matcher swap.

S137_DIR=$(mktemp -d)
S137_SHIM="$S137_DIR/bin"
S137_STATE="$S137_DIR/ghstate"       # GH_SHIM_STATE for the gh shim
S137_ATTEST_OK="$S137_DIR/attest-ok" # GHJIG_STATE_DIR_OVERRIDE carrying a VALID attestation
mkdir -p "$S137_SHIM" "$S137_STATE" "$S137_ATTEST_OK/audit" "$S137_ATTEST_OK/attest"

# gh shim (mirrors §38): canned headRefOid + closingIssuesReferences (empty →
# ac-closeout allows), plus the merge-review canned reads (a full review-object
# ARRAY for `gh api .../pulls/<n>/reviews`; pre-extracted scalar values for the
# `-q`-queried head / PR author / merger / nameWithOwner reads — same idiom as
# the headRefOid arm, the shim ignores `-q` and returns the extracted value the
# caller's `-q` would have produced), plus a forced-DOWN toggle (touch
# $GH_SHIM_STATE/gh_down) that makes every gh call error. The down toggle proves
# the merge-review gate FAILS CLOSED on a lookup failure.
cat > "$S137_SHIM/gh" <<'SHIM'
#!/bin/sh
if [ -f "$GH_SHIM_STATE/gh_down" ]; then
  echo "gh: shim forced down (no network)" >&2
  exit 1
fi
case "$*" in
  *"api"*/reviews*)                    cat "$GH_SHIM_STATE/reviews.json" 2>/dev/null ;;
  *"api user"*)                        cat "$GH_SHIM_STATE/api_user" 2>/dev/null ;;
  *"pr view"*headRefOid*)              cat "$GH_SHIM_STATE/head_ref_oid" 2>/dev/null ;;
  *"pr view"*author*)                  cat "$GH_SHIM_STATE/pr_author" 2>/dev/null ;;
  *"repo view"*nameWithOwner*)         cat "$GH_SHIM_STATE/name_with_owner" 2>/dev/null ;;
  *"pr view"*closingIssuesReferences*) cat "$GH_SHIM_STATE/pr_issues" 2>/dev/null ;;
  *"pr view"*"--json number"*)         cat "$GH_SHIM_STATE/pr_number" 2>/dev/null ;;
esac
exit 0
SHIM
chmod +x "$S137_SHIM/gh"

# Baseline shim state for the push-parity cases: a canned native APPROVED review
# pinned to the current head (commit_id == gh headRefOid) + a nameWithOwner, so
# the merge-review arm ALLOWS (#586, ex-merge-attestation), isolating push-parity
# as the sole decider on those repos.
printf 'parity-head\n' > "$S137_STATE/head_ref_oid"
: > "$S137_STATE/pr_issues"
printf '[{"state":"APPROVED","commit_id":"parity-head","submitted_at":"2020-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"lgtm"}]\n' > "$S137_STATE/reviews.json"
printf 'octo/repo\n' > "$S137_STATE/name_with_owner"

# Build a throwaway git repo in the requested push-parity state; echo its
# working-tree path. Mirrors the §32c throwaway git-init idiom. The remote-
# tracking ref is seeded via a LOCAL bare remote + `git push -u` (no network),
# so both `@{u}` and `origin/<branch>` resolve for whichever the arm reads.
s137_build_repo() {
  local state="$1" d work
  d=$(mktemp -d); work="$d/work"
  git init -q "$work" 2>/dev/null
  (
    cd "$work" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    git checkout -q -b smoke/feat/1-parity 2>/dev/null || true
    git commit --allow-empty -q -m c1
    case "$state" in
      no-upstream) : ;;                                # no remote → no @{u}
      detached)
        git commit --allow-empty -q -m c2
        git checkout -q --detach HEAD ;;
      *)
        git init -q --bare "$d/remote.git"
        git remote add origin "$d/remote.git"
        git push -q -u origin smoke/feat/1-parity
        case "$state" in
          in-sync) : ;;                                # local == pushed
          ahead)   git commit --allow-empty -q -m c2 ;;         # unpushed local commit
          behind)  git commit --allow-empty -q -m c2
                   git push -q origin smoke/feat/1-parity
                   git reset --hard -q HEAD~1 ;;                # local behind remote
          diverged) git commit --allow-empty -q -m c2
                    git push -q origin smoke/feat/1-parity
                    git reset --hard -q HEAD~1
                    git commit --allow-empty -q -m c2prime ;;   # neither is an ancestor
        esac ;;
    esac
  )
  printf '%s' "$work"
}

# Run `gh pr merge 55 --merge` inside a push-parity repo state; register the repo
# so in_scope passes, then de-register + clean. block cases are RED now (arm
# absent ⇒ rc 0 ⇒ the rc==2 assertion fails).
s137_parity_case() {
  local state="$1" expect="$2" repo canon out rc
  repo=$(s137_build_repo "$state")
  canon=$(cd "$repo" && pwd -P)
  # GHJIG_STATE_DIR_OVERRIDE relocates BOTH the audit log AND the scope registry
  # (ghjig_registry_file → $esd/registry.txt), so the repo must be registered in
  # the override's OWN registry or in_scope fails and the hook exits early — which
  # would green/red these cases for the wrong reason. Seed it fresh each run.
  printf '%s\n' "$canon" > "$S137_ATTEST_OK/registry.txt"
  out=$(
    cd "$repo" || exit 1
    # shellcheck disable=SC2069  # intentional: capture stderr, discard stdout
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' 'gh pr merge 55 --merge' | jq -Rs .)" \
      | PATH="$S137_SHIM:$PATH" \
        GH_SHIM_STATE="$S137_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        GHJIG_STATE_DIR_OVERRIDE="$S137_ATTEST_OK" \
        bash "$HOOK" 2>&1 >/dev/null
  )
  rc=$?
  rm -rf "$(dirname "$repo")"
  case "$expect" in
    block)
      if [ "$rc" = 2 ] \
         && printf '%s' "$out" | grep -q 'push-parity' \
         && printf '%s' "$out" | grep -qi 'push your local commits'; then
        ok "137p: push-parity blocks strictly-ahead ($state) merge — names 'push your local commits first' (#544)"
      else
        ng "137p: push-parity should BLOCK strictly-ahead ($state) (rc=$rc; arm absent ⇒ allow ⇒ RED) out=$out (#544)"
      fi ;;
    allow)
      if [ "$rc" = 0 ]; then
        ok "137p: push-parity allows non-strictly-ahead state ($state) (#544)"
      else
        ng "137p: push-parity should ALLOW ($state) (rc=$rc) out=$out (#544)"
      fi ;;
  esac
}

# 137p-a..f: only STRICTLY-AHEAD blocks; every other state allows (positive detection).
s137_parity_case ahead       block
s137_parity_case in-sync     allow
s137_parity_case behind      allow
s137_parity_case diverged    allow
s137_parity_case no-upstream allow
s137_parity_case detached    allow

# 137p-g: SKIP_HOOKS=push-parity escape — on a strictly-ahead repo the skip
# allows + audit-logs the escape. The baseline S137_STATE canned APPROVED@head
# review keeps merge-review from blocking (#586) so the push-parity escape is
# observed in isolation.
S137_SKIP_PSTATE="$S137_DIR/skip-parity"
mkdir -p "$S137_SKIP_PSTATE/audit"
s137_skp_repo=$(s137_build_repo ahead)
s137_skp_canon=$(cd "$s137_skp_repo" && pwd -P)
printf '%s\n' "$s137_skp_canon" > "$S137_SKIP_PSTATE/registry.txt"  # in_scope under the override
skp_before=$(wc -l < "$S137_SKIP_PSTATE/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
skp_rc=$(
  cd "$s137_skp_repo" || exit 1
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' "SKIP_HOOKS=push-parity SKIP_REASON='urgent' gh pr merge 55 --merge" | jq -Rs .)" \
    | PATH="$S137_SHIM:$PATH" GH_SHIM_STATE="$S137_STATE" \
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" GHJIG_STATE_DIR_OVERRIDE="$S137_SKIP_PSTATE" \
      bash "$HOOK" >/dev/null 2>&1
  printf '%s' "$?"
)
skp_after=$(wc -l < "$S137_SKIP_PSTATE/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
skp_tail=""
[ "$(( skp_after - skp_before ))" -gt 0 ] && skp_tail=$(tail -"$(( skp_after - skp_before ))" "$S137_SKIP_PSTATE/audit/audit.jsonl" 2>/dev/null)
rm -rf "$(dirname "$s137_skp_repo")"
if [ "$skp_rc" = 0 ] \
   && printf '%s' "$skp_tail" | grep -q '"category":"push-parity"' \
   && printf '%s' "$skp_tail" | grep -q '"decision":"skip"'; then
  ok "137p: SKIP_HOOKS=push-parity allows + audits the escape (#544)"
else
  ng "137p: push-parity escape should allow + audit skip (rc=$skp_rc; arm absent ⇒ no escape record ⇒ RED) tail=$skp_tail (#544)"
fi

# ── merge-review arm (#586, #585 — replacing merge-attestation) ───────────────
# Each merge-review case gets its OWN gh-shim state dir (canned reviews.json +
# head / PR-author / merger / owner scalars) AND its own GHJIG_STATE_DIR_OVERRIDE
# (per-case audit log + scope registry). The merge runs in $TMP/fake by default
# (no upstream ⇒ push-parity always allows there, so it never masks the
# merge-review decision) — except the bypass case, which runs in a dedicated cwd
# carrying `.claude/state/review-gate=bypass` so resolve_review_gate reads it.
# None of these state dirs carry an attest/pr-55 file, so the incumbent
# merge-attestation arm presence-BLOCKS every one — the RED signal for the
# absent merge-review arm.
S137_RV_HEAD=rvhead-current   # the current PR head SHA the shim reports
S137_RV_OLD=rvhead-super      # a superseded (stale) head SHA

# s137_rv_shim <dir> — seed a shim state dir with sane merge-review defaults
# (native reviewer/merger identities distinct from the PR author). Caller
# overrides reviews.json (+ pr_author/api_user for the self-marker cases).
s137_rv_shim() {
  local d="$1"
  mkdir -p "$d"
  printf '%s\n' "$S137_RV_HEAD" > "$d/head_ref_oid"
  printf 'pr-author-bot\n'      > "$d/pr_author"
  printf 'merger-bot\n'         > "$d/api_user"
  printf 'octo/repo\n'          > "$d/name_with_owner"
  printf '55\n'                 > "$d/pr_number"   # `gh pr view --json number` fallback (covered form has no positional PR)
  : > "$d/pr_issues"            # empty ⇒ ac-closeout allows
}

# s137_rv_case <name> <expect> <shimdir> <statedir> [<cwd>] [<cmd>]
#   Drives <cmd> (default `gh pr merge 55 --merge`) through the hook; asserts rc +
#   (for block/bypass) the per-case audit tail carries the merge-review category.
#   The optional 6th <cmd> param lets the #592 bypass-backstop cases drive the
#   covered ship form (`gh pr merge --auto --merge --delete-branch`, no positional
#   PR — resolves via the shim's `--json number` fallback, seeded by s137_rv_shim).
s137_rv_case() {
  local name="$1" expect="$2" shimdir="$3" statedir="$4" cwd="${5:-$TMP/fake}" cmd="${6:-gh pr merge 55 --merge}"
  local canon out rc before after rvtail
  canon=$(cd "$cwd" && pwd -P)
  # The override relocates the scope registry too — register the cwd in it or
  # in_scope fails and the hook exits early (RED/GREEN for the wrong reason).
  printf '%s\n' "$canon" > "$statedir/registry.txt"
  # Guard the `< file` redirect with [ -f ] — bash opens the redirect BEFORE
  # applying 2>/dev/null, so an absent audit.jsonl would leak a spurious "No
  # such file" line (smoke.sh L40-43). Absent sink snapshots as 0.
  before=0; [ -f "$statedir/audit/audit.jsonl" ] && before=$(wc -l < "$statedir/audit/audit.jsonl" | tr -d ' ')
  out=$(
    cd "$cwd" || exit 1
    # shellcheck disable=SC2069  # intentional: capture stderr, discard stdout
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | jq -Rs .)" \
      | PATH="$S137_SHIM:$PATH" \
        GH_SHIM_STATE="$shimdir" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        GHJIG_STATE_DIR_OVERRIDE="$statedir" \
        bash "$HOOK" 2>&1 >/dev/null
  )
  rc=$?
  after=0; [ -f "$statedir/audit/audit.jsonl" ] && after=$(wc -l < "$statedir/audit/audit.jsonl" | tr -d ' ')
  rvtail=""
  [ "$(( after - before ))" -gt 0 ] && rvtail=$(tail -"$(( after - before ))" "$statedir/audit/audit.jsonl" 2>/dev/null)
  case "$expect" in
    block)
      if [ "$rc" = 2 ] && printf '%s' "$rvtail" | grep -q '"category":"merge-review","decision":"deny"'; then
        ok "137r: merge-review BLOCKS — $name (#586)"
      else
        ng "137r: merge-review should BLOCK — $name (rc=$rc; arm absent ⇒ merge-attestation blocks under the wrong category ⇒ RED) tail=$rvtail out=$out (#586)"
      fi ;;
    allow)
      if [ "$rc" = 0 ]; then
        ok "137r: merge-review ALLOWS — $name (#586)"
      else
        ng "137r: merge-review should ALLOW — $name (rc=$rc; arm absent ⇒ incumbent presence-blocks ⇒ RED) tail=$rvtail out=$out (#586)"
      fi ;;
    bypass)
      if [ "$rc" = 0 ] && printf '%s' "$rvtail" | grep -q '"category":"merge-review","decision":"bypass"'; then
        ok "137r: merge-review BYPASS allows + loud audit — $name (#586)"
      else
        ng "137r: merge-review bypass should allow + emit a loud merge-review bypass audit (rc=$rc; arm absent ⇒ RED) tail=$rvtail out=$out (#586)"
      fi ;;
  esac
}

# 137r-a: BLOCK — no review at all (the review was skipped / never filed).
S137_RV_NONE_SH="$S137_DIR/rv-none-shim"; s137_rv_shim "$S137_RV_NONE_SH"
printf '[]\n' > "$S137_RV_NONE_SH/reviews.json"
S137_RV_NONE_ST="$S137_DIR/rv-none-state"; mkdir -p "$S137_RV_NONE_ST/audit"
s137_rv_case "no review filed" block "$S137_RV_NONE_SH" "$S137_RV_NONE_ST"

# 137r-b: BLOCK — only a STALE review (APPROVED but commit_id != current head).
S137_RV_STALE_SH="$S137_DIR/rv-stale-shim"; s137_rv_shim "$S137_RV_STALE_SH"
printf '[{"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"lgtm"}]\n' \
  "$S137_RV_OLD" > "$S137_RV_STALE_SH/reviews.json"
S137_RV_STALE_ST="$S137_DIR/rv-stale-state"; mkdir -p "$S137_RV_STALE_ST/audit"
s137_rv_case "only a stale APPROVED at a superseded head" block "$S137_RV_STALE_SH" "$S137_RV_STALE_ST"

# 137r-c: BLOCK — an outstanding CHANGES_REQUESTED at the current head.
S137_RV_CR_SH="$S137_DIR/rv-cr-shim"; s137_rv_shim "$S137_RV_CR_SH"
printf '[{"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"needs work"}]\n' \
  "$S137_RV_HEAD" > "$S137_RV_CR_SH/reviews.json"
S137_RV_CR_ST="$S137_DIR/rv-cr-state"; mkdir -p "$S137_RV_CR_ST/audit"
s137_rv_case "outstanding CHANGES_REQUESTED at head" block "$S137_RV_CR_SH" "$S137_RV_CR_ST"

# 137r-d: BLOCK — the B1 aggregation regression case. A native APPROVED@head
# (bob) alongside alice's CHANGES_REQUESTED@head FOLLOWED BY her COMMENTED@head.
# The correct aggregation FILTERS COMMENTED out before per-author-latest, so
# alice's surviving latest stays CHANGES_REQUESTED and the veto BLOCKS. A naive
# "latest row per author" would read alice's latest as COMMENTED, drop the veto,
# and spuriously ALLOW on bob's APPROVED — the exact bug this case pins.
S137_RV_REG_SH="$S137_DIR/rv-regression-shim"; s137_rv_shim "$S137_RV_REG_SH"
printf '[{"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"bob"},"user":{"login":"bob"},"body":"ok"},{"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-01-02T00:00:00Z","author":{"login":"alice"},"user":{"login":"alice"},"body":"changes please"},{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-03T00:00:00Z","author":{"login":"alice"},"user":{"login":"alice"},"body":"just a passing note"}]\n' \
  "$S137_RV_HEAD" "$S137_RV_HEAD" "$S137_RV_HEAD" > "$S137_RV_REG_SH/reviews.json"
S137_RV_REG_ST="$S137_DIR/rv-regression-state"; mkdir -p "$S137_RV_REG_ST/audit"
s137_rv_case "CHANGES_REQUESTED@head then COMMENTED@head, same author — veto survives (B1)" block "$S137_RV_REG_SH" "$S137_RV_REG_ST"

# 137r-e: ALLOW (native) — an APPROVED review at the current head, no outstanding
# CHANGES_REQUESTED.
S137_RV_APP_SH="$S137_DIR/rv-approved-shim"; s137_rv_shim "$S137_RV_APP_SH"
printf '[{"state":"APPROVED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"approved"}]\n' \
  "$S137_RV_HEAD" > "$S137_RV_APP_SH/reviews.json"
S137_RV_APP_ST="$S137_DIR/rv-approved-state"; mkdir -p "$S137_RV_APP_ST/audit"
s137_rv_case "native APPROVED at head, no outstanding CHANGES_REQUESTED" allow "$S137_RV_APP_SH" "$S137_RV_APP_ST"

# 137r-f: ALLOW (self-marker) — a COMMENTED review at head carrying EXACTLY ONE
# verdict=approve marker whose review author == PR author == merger (a
# self-shipped PR). Identity/head come from the review OBJECT; only `verdict`
# from the marker text.
S137_RV_SELF_SH="$S137_DIR/rv-selfmarker-shim"; s137_rv_shim "$S137_RV_SELF_SH"
printf 'me\n' > "$S137_RV_SELF_SH/pr_author"
printf 'me\n' > "$S137_RV_SELF_SH/api_user"
printf '[{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"me"},"user":{"login":"me"},"body":"<!-- file-review verdict=approve head=%s reviewer=code-reviewer -->"}]\n' \
  "$S137_RV_HEAD" "$S137_RV_HEAD" > "$S137_RV_SELF_SH/reviews.json"
S137_RV_SELF_ST="$S137_DIR/rv-selfmarker-state"; mkdir -p "$S137_RV_SELF_ST/audit"
# #598: the self-marker branch now ALSO requires resolve_self_review_policy==allow
# (default deny, fail-closed). So this ALLOW case must run in a cwd carrying
# `.claude/state/self-review=allow` — else the new policy default (deny) would
# BLOCK the self-marker and this case would flip red. git-init'd (no upstream ⇒
# push-parity allows) exactly like the 137r-h bypass cwd.
S137_RV_SELF_CWD="$S137_DIR/rv-selfmarker-cwd"
mkdir -p "$S137_RV_SELF_CWD/.claude/state"
( cd "$S137_RV_SELF_CWD" && git init -q && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false && git checkout -q -b smoke/feat/1-selfmarker \
    && git commit --allow-empty -q -m init ) 2>/dev/null || true
printf 'allow\n' > "$S137_RV_SELF_CWD/.claude/state/self-review"
s137_rv_case "self verdict=approve marker@head, author==PR-author==merger, self-review=allow" allow "$S137_RV_SELF_SH" "$S137_RV_SELF_ST" "$S137_RV_SELF_CWD"

# 137r-g: BLOCK — conflicting/multiple markers in one review (a verdict=approve
# AND a verdict=block marker) → ambiguous, fail-closed.
S137_RV_CONF_SH="$S137_DIR/rv-conflict-shim"; s137_rv_shim "$S137_RV_CONF_SH"
printf 'me\n' > "$S137_RV_CONF_SH/pr_author"
printf 'me\n' > "$S137_RV_CONF_SH/api_user"
printf '[{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"me"},"user":{"login":"me"},"body":"<!-- file-review verdict=approve head=%s reviewer=code-reviewer --> and also <!-- file-review verdict=block head=%s reviewer=code-reviewer -->"}]\n' \
  "$S137_RV_HEAD" "$S137_RV_HEAD" "$S137_RV_HEAD" > "$S137_RV_CONF_SH/reviews.json"
S137_RV_CONF_ST="$S137_DIR/rv-conflict-state"; mkdir -p "$S137_RV_CONF_ST/audit"
s137_rv_case "conflicting/multiple markers in one review" block "$S137_RV_CONF_SH" "$S137_RV_CONF_ST"

# 137r-h: BYPASS — resolve_review_gate reads `.claude/state/review-gate=bypass`
# (cwd-relative, read exactly as resolve_mode reads .claude/state/mode, §5.7.1):
# the gate is SKIPPED (merge allowed with no head-pinned review) but every bypass
# merge is LOUDLY audit-logged (`audit_log warn merge-review bypass`). Runs in a
# dedicated cwd carrying that toggle; reviews.json is empty to prove the bypass
# does not consult the gate at all.
S137_RV_BYP_CWD="$S137_DIR/rv-bypass-cwd"
mkdir -p "$S137_RV_BYP_CWD/.claude/state"
( cd "$S137_RV_BYP_CWD" && git init -q && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false && git checkout -q -b smoke/feat/1-bypass \
    && git commit --allow-empty -q -m init ) 2>/dev/null || true
printf 'bypass\n' > "$S137_RV_BYP_CWD/.claude/state/review-gate"
S137_RV_BYP_SH="$S137_DIR/rv-bypass-shim"; s137_rv_shim "$S137_RV_BYP_SH"
printf '[]\n' > "$S137_RV_BYP_SH/reviews.json"
S137_RV_BYP_ST="$S137_DIR/rv-bypass-state"; mkdir -p "$S137_RV_BYP_ST/audit"
s137_rv_case "review-gate=bypass → allow + loud bypass audit" bypass "$S137_RV_BYP_SH" "$S137_RV_BYP_ST" "$S137_RV_BYP_CWD"

# 137r-i: FAIL-CLOSED — gh forced DOWN (every lookup errors) → BLOCK. The
# deliberate divergence from the retired attestation staleness leg (which
# fail-OPEN-allowed on gh down): the safe direction for a merge integrity gate is
# to REQUIRE a review, never to skip it (§5.7.1).
S137_RV_DOWN_SH="$S137_DIR/rv-down-shim"; s137_rv_shim "$S137_RV_DOWN_SH"
printf '[]\n' > "$S137_RV_DOWN_SH/reviews.json"
touch "$S137_RV_DOWN_SH/gh_down"
S137_RV_DOWN_ST="$S137_DIR/rv-down-state"; mkdir -p "$S137_RV_DOWN_ST/audit"
s137_rv_case "gh down / lookup failure → fail-closed block" block "$S137_RV_DOWN_SH" "$S137_RV_DOWN_ST"

# ---- §137r bypass-backstop (#592): the bypass arm is NOT an unconditional skip ----
# Under review-gate=bypass the gate self-skips, EXCEPT it still BLOCKS the exact
# covered ship form (`gh pr merge --auto --merge --delete-branch`, settings.json:4)
# when it is an AGENT SELF-MERGE (PR author == merger). The covered form carries no
# positional PR, so the PR resolves via the shim's `gh pr view --json number`
# fallback (pr_number seeded by s137_rv_shim). All four run in the bypass cwd built
# for 137r-h (carries .claude/state/review-gate=bypass), each with its own state dir.
#
# 137r-j / 137r-m are RED NOW: Phase C (the backstop) is unwritten, so the bypass
# arm allows UNCONDITIONALLY — rc=0 + a merge-review/bypass audit — which is neither
# the rc=2 nor the merge-review/deny the block expectation demands. 137r-k / 137r-l
# are steady-green guards: they must ALLOW (bypass) both before AND after Phase C,
# proving the backstop narrows bypass to covered-form self-merges ONLY (human
# covered-form merges and non-covered self-merges stay allowed).
S137_RV_COVERED='gh pr merge --auto --merge --delete-branch'

# 137r-j: BLOCK — covered form + SELF-merge (PR author == merger) under bypass. The
# static permissions.allow entry alone is no longer the sole guard (#592): the hook
# fails the agent self-merge closed even with the gate bypassed. RED now (bypass
# allows unconditionally ⇒ rc=0/decision=bypass ≠ rc=2/decision=deny).
S137_RV_JSH="$S137_DIR/rv-byp-self-shim"; s137_rv_shim "$S137_RV_JSH"
printf '[]\n' > "$S137_RV_JSH/reviews.json"
printf 'me\n' > "$S137_RV_JSH/pr_author"   # author == merger ⇒ self-merge
printf 'me\n' > "$S137_RV_JSH/api_user"
S137_RV_JST="$S137_DIR/rv-byp-self-state"; mkdir -p "$S137_RV_JST/audit"
s137_rv_case "bypass + covered form + self-merge → backstop BLOCKS (#592)" block \
  "$S137_RV_JSH" "$S137_RV_JST" "$S137_RV_BYP_CWD" "$S137_RV_COVERED"

# 137r-m: BLOCK (fail-closed) — covered form + gh DOWN under bypass. The self-merge
# author/merger lookup errors ⇒ indeterminate ⇒ the backstop fails CLOSED (mirrors
# the required arm's §5.7.1 posture: a merge-integrity gate never fail-opens on an
# outage). RED now (bypass short-circuits before any gh call ⇒ rc=0/bypass).
S137_RV_MSH="$S137_DIR/rv-byp-down-shim"; s137_rv_shim "$S137_RV_MSH"
printf '[]\n' > "$S137_RV_MSH/reviews.json"
printf 'me\n' > "$S137_RV_MSH/pr_author"
printf 'me\n' > "$S137_RV_MSH/api_user"
touch "$S137_RV_MSH/gh_down"
S137_RV_MST="$S137_DIR/rv-byp-down-state"; mkdir -p "$S137_RV_MST/audit"
s137_rv_case "bypass + covered form + gh down → backstop fail-closed BLOCKS (#592)" block \
  "$S137_RV_MSH" "$S137_RV_MST" "$S137_RV_BYP_CWD" "$S137_RV_COVERED"

# 137r-k (steady-green guard): covered form + HUMAN merge (PR author != merger) under
# bypass → ALLOW + loud bypass audit. The backstop needs BOTH covered-form AND
# self-merge; a human ship of the covered form stays bypass-allowed. GREEN before
# (bypass unconditional) AND after (author != merger ⇒ not a self-merge) Phase C.
S137_RV_KSH="$S137_DIR/rv-byp-human-shim"; s137_rv_shim "$S137_RV_KSH"
printf '[]\n' > "$S137_RV_KSH/reviews.json"   # default pr-author-bot != merger-bot ⇒ human
S137_RV_KST="$S137_DIR/rv-byp-human-state"; mkdir -p "$S137_RV_KST/audit"
s137_rv_case "bypass + covered form + human merge → stays allowed (bypass) (#592)" bypass \
  "$S137_RV_KSH" "$S137_RV_KST" "$S137_RV_BYP_CWD" "$S137_RV_COVERED"

# 137r-l (steady-green guard): NON-covered form (`gh pr merge 55 --merge`) + self-merge
# under bypass → ALLOW + loud bypass audit. The backstop guards only the covered ship
# form; a non-covered self-merge is not this hook's concern (the classifier re-engages
# on it elsewhere). GREEN before AND after Phase C (form is not the covered shape).
S137_RV_LSH="$S137_DIR/rv-byp-noncov-shim"; s137_rv_shim "$S137_RV_LSH"
printf '[]\n' > "$S137_RV_LSH/reviews.json"
printf 'me\n' > "$S137_RV_LSH/pr_author"   # self-merge, but NOT the covered form
printf 'me\n' > "$S137_RV_LSH/api_user"
S137_RV_LST="$S137_DIR/rv-byp-noncov-state"; mkdir -p "$S137_RV_LST/audit"
s137_rv_case "bypass + non-covered form + self-merge → stays allowed (bypass) (#592)" bypass \
  "$S137_RV_LSH" "$S137_RV_LST" "$S137_RV_BYP_CWD"

# §137-inv (structural, mirrors §39b): each arm must exist in pre_tool_use.sh as
# an INDEPENDENT matcher reaching its own decided state — i.e. carry both a
# `should_skip <cat>` entry and a `pass_through_trace <cat>` terminal tail (the
# SPEC §6.1 mark_allow/block/pass_through_trace decided-state contract, parity
# with the ac-closeout + merge-strategy arms). push-parity is already shipped
# (GREEN); merge-review is RED now — neither symbol is present for it because the
# arm has not been written (the incumbent still carries merge-attestation).
for inv_cat in push-parity merge-review; do
  if grep -q "should_skip $inv_cat" "$HOOK" \
     && grep -q "pass_through_trace $inv_cat" "$HOOK"; then
    ok "137-inv: '$inv_cat' arm present with should_skip + pass_through_trace decided tail (#544, #586)"
  else
    ng "137-inv: '$inv_cat' arm missing should_skip/pass_through_trace symbol (arm absent ⇒ RED) (#544, #586)"
  fi
done

# §137-inv (runtime compose, mirrors §39d): a benign in-sync merge with a passing
# head-pinned review ALLOWS and both arms decide SILENTLY — no pass-through warn
# for either category (each mark_allow's, no fall-through), composing with
# ac-closeout + merge-strategy on the same `gh pr merge` with no double-decide.
# Seeded to allow under BOTH the incumbent (attest file present + head match) and
# the future merge-review arm (a native APPROVED@head review), so it stays GREEN
# across the Phase-C swap without touching the global attest seed.
S137_INV_STATE="$S137_DIR/inv"
mkdir -p "$S137_INV_STATE/audit" "$S137_INV_STATE/attest"
printf 'head=current-sha-999\n' > "$S137_INV_STATE/attest/pr-55"
printf 'current-sha-999\n' > "$S137_STATE/head_ref_oid"
printf '[{"state":"APPROVED","commit_id":"current-sha-999","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"reviewer"},"user":{"login":"reviewer"},"body":"approved"}]\n' > "$S137_STATE/reviews.json"
printf 'pr-author-bot\n' > "$S137_STATE/pr_author"
printf 'merger-bot\n'    > "$S137_STATE/api_user"
printf 'octo/repo\n'     > "$S137_STATE/name_with_owner"
s137_inv_repo=$(s137_build_repo in-sync)
s137_inv_canon=$(cd "$s137_inv_repo" && pwd -P)
printf '%s\n' "$s137_inv_canon" > "$S137_INV_STATE/registry.txt"  # in_scope under the override
inv_before=$(wc -l < "$S137_INV_STATE/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
inv_rc=$(
  cd "$s137_inv_repo" || exit 1
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(printf '%s' 'gh pr merge 55 --merge' | jq -Rs .)" \
    | PATH="$S137_SHIM:$PATH" GH_SHIM_STATE="$S137_STATE" \
      GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" GHJIG_STATE_DIR_OVERRIDE="$S137_INV_STATE" \
      bash "$HOOK" >/dev/null 2>&1
  printf '%s' "$?"
)
inv_after=$(wc -l < "$S137_INV_STATE/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
inv_tail=""
[ "$(( inv_after - inv_before ))" -gt 0 ] && inv_tail=$(tail -"$(( inv_after - inv_before ))" "$S137_INV_STATE/audit/audit.jsonl" 2>/dev/null)
rm -rf "$(dirname "$s137_inv_repo")"
if [ "$inv_rc" = 0 ] \
   && ! printf '%s' "$inv_tail" | grep -q '"category":"push-parity","decision":"pass-through"' \
   && ! printf '%s' "$inv_tail" | grep -q '"category":"merge-review","decision":"pass-through"'; then
  ok "137-inv: benign in-sync reviewed merge allows; arms decide silently (no fall-through) (#544, #586)"
else
  ng "137-inv: benign merge must allow with no pass-through for the merge arms (rc=$inv_rc) tail=$inv_tail (#544, #586)"
fi

# ---------- §148: self-review producer classifier exception + per-target policy (#598) ----------
# SPEC §5.7.1 second auto-mode-classifier exception. /ship self-posts its head-pinned review
# via /file-review; on an agent-authored PR that self-approve POST was blocked by the auto-mode
# classifier, stranding the sanctioned unattended self-merge (Directive #584/#587). Fix: a
# fixed-form wildcard-free wrapper (scripts/ghjig_file_review_post.sh) allow-listed as
# Bash(.claude/ghjig-root/scripts/ghjig_file_review_post.sh) — parity with the merge entry —
# PLUS a per-target policy (.claude/state/self-review, resolve_self_review_policy, default deny/
# fail-closed) that the merge-review self-marker branch (§6.1) consults. This block sits BEFORE
# the §137 cleanup so §148f can reuse the live gh shim + s137_rv_* harness.
S148_WRAP_CANON='.claude/ghjig-root/scripts/ghjig_file_review_post.sh'
S148_WRAP_FILE="$SHELL_ROOT/scripts/ghjig_file_review_post.sh"
S148_SET="$SHELL_ROOT/.claude/settings.json"
S148_INJ="$SHELL_ROOT/.claude/settings.injected.json"
S148_FR="$SHELL_ROOT/.claude/commands/file-review.md"
S148_SHIPMODE="$SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh"

# §148a (LOAD-BEARING RED): settings.json carries the exact wildcard-free wrapper entry.
if [ -f "$S148_SET" ] && grep -qF "Bash($S148_WRAP_CANON)" "$S148_SET" 2>/dev/null; then
  ok "148a: settings.json carries exact wrapper allow entry Bash($S148_WRAP_CANON) (#598)"
else
  ng "148a: settings.json missing exact wrapper allow entry Bash($S148_WRAP_CANON) (#598)"
fi

# §148b (LOAD-BEARING RED — presence + narrowness fused): the ONLY ghjig_file_review_post.sh
# allow rule is the exact form (a `…post.sh:*` wildcard would hit the substring but not the
# exact literal → any!=exact fails), AND there is NO raw `gh api …pulls…reviews` allow (which
# would open APPROVE/REQUEST_CHANGES on any PR — past self-COMMENT-only).
if [ -f "$S148_SET" ]; then
  s148_any=$(grep -cF 'ghjig_file_review_post.sh' "$S148_SET" 2>/dev/null || true)
  s148_exact=$(grep -cF "Bash($S148_WRAP_CANON)" "$S148_SET" 2>/dev/null || true)
  s148_rawapi=$(grep -cE 'gh api[^"]*pulls[^"]*reviews' "$S148_SET" 2>/dev/null || true)
else
  s148_any=-1; s148_exact=-1; s148_rawapi=-1
fi
if [ "$s148_exact" -ge 1 ] && [ "$s148_any" = "$s148_exact" ] && [ "$s148_rawapi" = 0 ]; then
  ok "148b: only the exact narrow wrapper allow — no wildcard, no raw gh-api-reviews allow (any=$s148_any exact=$s148_exact rawapi=$s148_rawapi) (#598)"
else
  ng "148b: settings.json must carry only the exact narrow wrapper entry and no broad/raw-api allow (any=$s148_any exact=$s148_exact rawapi=$s148_rawapi) (#598)"
fi

# §148c (LOAD-BEARING RED — cross-target): settings.injected.json carries the identical exact
# narrow entry with the same both-directions + no-raw-api discipline (#591 propagation model).
if [ -f "$S148_INJ" ]; then
  s148c_any=$(grep -cF 'ghjig_file_review_post.sh' "$S148_INJ" 2>/dev/null || true)
  s148c_exact=$(grep -cF "Bash($S148_WRAP_CANON)" "$S148_INJ" 2>/dev/null || true)
  s148c_rawapi=$(grep -cE 'gh api[^"]*pulls[^"]*reviews' "$S148_INJ" 2>/dev/null || true)
else
  s148c_any=-1; s148c_exact=-1; s148c_rawapi=-1
fi
if [ "$s148c_exact" -ge 1 ] && [ "$s148c_any" = "$s148c_exact" ] && [ "$s148c_rawapi" = 0 ]; then
  ok "148c: settings.injected.json carries the exact narrow wrapper entry — propagated to targets (any=$s148c_any exact=$s148c_exact rawapi=$s148c_rawapi) (#598)"
else
  ng "148c: settings.injected.json must carry the exact narrow wrapper entry (cross-target) (any=$s148c_any exact=$s148c_exact rawapi=$s148c_rawapi) (#598)"
fi

# §148d (LOAD-BEARING RED): the wrapper exists, is executable, hardcodes event=COMMENT (NEVER
# APPROVE/REQUEST_CHANGES), and carries an own-PR author guard.
if [ -f "$S148_WRAP_FILE" ] && [ -x "$S148_WRAP_FILE" ] \
   && grep -qF 'event=COMMENT' "$S148_WRAP_FILE" 2>/dev/null \
   && ! grep -qE 'event=(APPROVE|REQUEST_CHANGES)' "$S148_WRAP_FILE" 2>/dev/null \
   && grep -qiE 'author' "$S148_WRAP_FILE" 2>/dev/null; then
  ok "148d: wrapper exists/executable, event=COMMENT only, own-PR author guard present (#598)"
else
  ng "148d: wrapper must exist+executable+event=COMMENT-only (never APPROVE/REQUEST_CHANGES)+own-PR author guard (#598)"
fi

# §148e (LOAD-BEARING RED): resolve_self_review_policy — default deny (fail-closed), state
# allow/deny honored, $GHJIG_SELF_REVIEW env override, garbage→deny. Sourced + called in
# throwaway cwds so the .claude/state/self-review read is cwd-relative (like review-gate).
s148_pol() { ( cd "$1" && . "$S148_SHIPMODE" 2>/dev/null && resolve_self_review_policy 2>/dev/null ); }
S148_POLDIR=$(mktemp -d)
mkdir -p "$S148_POLDIR/none" "$S148_POLDIR/allow/.claude/state" "$S148_POLDIR/deny/.claude/state" "$S148_POLDIR/garbage/.claude/state"
printf 'allow\n' > "$S148_POLDIR/allow/.claude/state/self-review"
printf 'deny\n'  > "$S148_POLDIR/deny/.claude/state/self-review"
printf 'wat?!\n' > "$S148_POLDIR/garbage/.claude/state/self-review"
s148_default=$(s148_pol "$S148_POLDIR/none")
s148_allow=$(s148_pol "$S148_POLDIR/allow")
s148_deny=$(s148_pol "$S148_POLDIR/deny")
s148_garbage=$(s148_pol "$S148_POLDIR/garbage")
s148_env=$( cd "$S148_POLDIR/deny" && GHJIG_SELF_REVIEW=allow bash -c ". \"$S148_SHIPMODE\" 2>/dev/null && resolve_self_review_policy" 2>/dev/null )
rm -rf "$S148_POLDIR"
if [ "$s148_default" = deny ] && [ "$s148_allow" = allow ] && [ "$s148_deny" = deny ] \
   && [ "$s148_garbage" = deny ] && [ "$s148_env" = allow ]; then
  ok "148e: resolve_self_review_policy default=deny, state honored, garbage→deny, env overrides (default=$s148_default allow=$s148_allow deny=$s148_deny garbage=$s148_garbage env=$s148_env) (#598)"
else
  ng "148e: resolve_self_review_policy must default deny + honor state/env + fail-closed on garbage (default=$s148_default allow=$s148_allow deny=$s148_deny garbage=$s148_garbage env=$s148_env) (#598)"
fi

# §148f (LOAD-BEARING RED — behavioral): the merge-review self-marker branch honors the policy.
# Same self-marker shim as 137r-f (author==PR-author==merger COMMENT verdict=approve @head),
# driven through the hook in two cwds: self-review=deny → BLOCK (self-marker NOT accepted; only
# a native second-party APPROVE would satisfy the gate), self-review=allow → ALLOW. Reuses the
# still-live s137 gh shim + s137_rv_* harness.
s148_mk_selfshim() {
  local d="$1"; s137_rv_shim "$d"
  printf 'me\n' > "$d/pr_author"; printf 'me\n' > "$d/api_user"
  printf '[{"state":"COMMENTED","commit_id":"%s","submitted_at":"2026-01-01T00:00:00Z","author":{"login":"me"},"user":{"login":"me"},"body":"<!-- file-review verdict=approve head=%s reviewer=code-reviewer -->"}]\n' \
    "$S137_RV_HEAD" "$S137_RV_HEAD" > "$d/reviews.json"
}
s148_mk_cwd() {
  local c="$1" pol="$2"
  mkdir -p "$c/.claude/state"
  ( cd "$c" && git init -q && git config user.email t@t && git config user.name t \
      && git config commit.gpgsign false && git checkout -q -b smoke/feat/1-selfpol \
      && git commit --allow-empty -q -m init ) 2>/dev/null || true
  printf '%s\n' "$pol" > "$c/.claude/state/self-review"
}
S148F_DENY_SH="$S137_DIR/rv-selfpol-deny-shim"; s148_mk_selfshim "$S148F_DENY_SH"
S148F_DENY_ST="$S137_DIR/rv-selfpol-deny-state"; mkdir -p "$S148F_DENY_ST/audit"
S148F_DENY_CWD="$S137_DIR/rv-selfpol-deny-cwd"; s148_mk_cwd "$S148F_DENY_CWD" deny
s137_rv_case "self-marker@head but self-review=deny → not accepted" block "$S148F_DENY_SH" "$S148F_DENY_ST" "$S148F_DENY_CWD"
S148F_ALLOW_SH="$S137_DIR/rv-selfpol-allow-shim"; s148_mk_selfshim "$S148F_ALLOW_SH"
S148F_ALLOW_ST="$S137_DIR/rv-selfpol-allow-state"; mkdir -p "$S148F_ALLOW_ST/audit"
S148F_ALLOW_CWD="$S137_DIR/rv-selfpol-allow-cwd"; s148_mk_cwd "$S148F_ALLOW_CWD" allow
s137_rv_case "self-marker@head with self-review=allow → accepted" allow "$S148F_ALLOW_SH" "$S148F_ALLOW_ST" "$S148F_ALLOW_CWD"

# §148g (CRITICAL — LOAD-BEARING RED): byte-for-byte drift lock. The settings.json wrapper
# allow inner command AND the file-review.md invocation must both carry the exact wrapper path
# — a silent drift → the emitted command misses the matcher → classifier re-engages → silent
# unattended park (the same failure class this fix closes; mirrors §144f).
s148_set_has=0; s148_fr_has=0
[ -f "$S148_SET" ] && grep -qF "Bash($S148_WRAP_CANON)" "$S148_SET" 2>/dev/null && s148_set_has=1
[ -f "$S148_FR" ] && grep -qF "$S148_WRAP_CANON" "$S148_FR" 2>/dev/null && s148_fr_has=1
if [ "$s148_set_has" = 1 ] && [ "$s148_fr_has" = 1 ]; then
  ok "148g: wrapper path is byte-identical in settings.json and file-review.md (set=$s148_set_has fr=$s148_fr_has) (#598)"
else
  ng "148g: byte-for-byte drift — settings-side=$s148_set_has file-review-side=$s148_fr_has, both must carry '$S148_WRAP_CANON' (#598)"
fi

rm -rf "$S137_DIR"

# ---------- §148h/§148i/§148j: /file-review SINGLE-WRAPPER producer (#602, #633) ----------
# SPEC §5.7.1 — "The producer is one link, not two", "Re-stat equality", "Head-staleness
# guard — retained, not subsumed", "Security ledger — two-sided" — and §5.29 "The wrapper's
# accept set" / "Audit".
#
# #602 moved the body off stdin onto a staged state file written by a SEPARATE writer script
# invoked with a variable tempfile argv. That argv was not allow-coverable wildcard-free, so
# an unattended /ship parked one step before the POST, and the only allow form that could have
# matched would have auto-approved an arbitrary-path read whose content the wrapper publishes
# verbatim. #633 DELETES the writer: /file-review writes the sanitized body ITSELF to the fixed
# `<esd>/file-review/staging` — no `created=`/`head=` header stamps, body only — and the single
# already-allow-covered BARE wrapper reads it in the contracted order
#     stat -> slurp -> stat (equal) -> one-shot unlink -> validate -> POST
# with the freshness bound moved onto the file's mtime (portable BSD/GNU stat; a future-dated
# mtime is its OWN reject arm) and the head-staleness guard RETAINED as two arms the wrapper
# evaluates itself (marker head= vs resolved headRefOid; local `git rev-parse HEAD` vs the same
# head). Every reject is audited file-review/rejected carrying the ARM NAME ONLY.
#
# RED until Phase C deletes the writer and rewrites the wrapper's read/validate path.
#
# The deleted script's basename is assembled from two fragments so this section can assert its
# TOTAL ABSENCE from the tree without its own assertion counting as a surviving reference.
S148_STAGE_BASE="ghjig_file_review_""stage.sh"
S148_STAGE_FILE="$SHELL_ROOT/scripts/$S148_STAGE_BASE"
S148_STAGING_CANON='.claude/ghjig-state/file-review/staging'
S148_ACGATE="$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh"
# The canonical marker regex — byte-identical in ac_closeout_gate.sh (the merge-side consumer)
# and in the wrapper (the producer-side accept set). Pinning the literal here makes this smoke
# the third anchor, so producer/consumer parse drift cannot land silently (SPEC §5.29).
S148_MARKER_RX='<!-- file-review verdict=[A-Za-z]+ head=[^[:space:]]+ reviewer=code-reviewer -->'

# §148h (LOAD-BEARING RED — single-wrapper reader shape): the wrapper never slurps stdin,
# sources hookrt.sh + resolves via the shared ghjig_state_dir_cli, names the fixed
# `file-review/staging` leaf (NOT the retired `file-review/body`), carries the 60s TTL and the
# one-shot `rm -f`, and reads the mtime through BOTH portable branches — a platform with
# neither must fail closed, never silently skip the TTL.
s148h_nocat=0; s148h_src=0; s148h_cli=0; s148h_leaf=0; s148h_nobody=0
s148h_ttl=0; s148h_rmf=0; s148h_bsd=0; s148h_gnu=0
if [ -f "$S148_WRAP_FILE" ]; then
  grep -qF 'body=$(cat)' "$S148_WRAP_FILE" 2>/dev/null || s148h_nocat=1
  grep -qF 'hookrt.sh'           "$S148_WRAP_FILE" 2>/dev/null && s148h_src=1
  grep -qF 'ghjig_state_dir_cli' "$S148_WRAP_FILE" 2>/dev/null && s148h_cli=1
  grep -qF 'file-review/staging' "$S148_WRAP_FILE" 2>/dev/null && s148h_leaf=1
  grep -qF 'file-review/body'    "$S148_WRAP_FILE" 2>/dev/null || s148h_nobody=1
  grep -qE '(^|[^0-9])60([^0-9]|$)' "$S148_WRAP_FILE" 2>/dev/null && s148h_ttl=1
  grep -qF 'rm -f'      "$S148_WRAP_FILE" 2>/dev/null && s148h_rmf=1
  grep -qF 'stat -f %m' "$S148_WRAP_FILE" 2>/dev/null && s148h_bsd=1
  grep -qF 'stat -c %Y' "$S148_WRAP_FILE" 2>/dev/null && s148h_gnu=1
fi
if [ "$s148h_nocat$s148h_src$s148h_cli$s148h_leaf$s148h_nobody$s148h_ttl$s148h_rmf$s148h_bsd$s148h_gnu" = 111111111 ]; then
  ok "148h: wrapper reads the fixed file-review/staging leaf via ghjig_state_dir_cli — no stdin slurp, 60s mtime TTL, one-shot rm -f, portable BSD+GNU stat (#633)"
else
  ng "148h: wrapper must read <esd>/file-review/staging (never .../body) via ghjig_state_dir_cli with a 60s mtime TTL, one-shot rm -f and BOTH stat branches (nocat=$s148h_nocat src=$s148h_src cli=$s148h_cli leaf=$s148h_leaf nobody=$s148h_nobody ttl=$s148h_ttl rmf=$s148h_rmf bsd=$s148h_bsd gnu=$s148h_gnu) (#633)"
fi

# §148h-bare (regression lock — must stay GREEN; the premise of the whole exception): the
# wrapper consumes NO script argv. A variable argv is exactly what made the retired writer
# un-coverable wildcard-free; if the wrapper ever grows one, the exact entry `Bash(<wrapper>)`
# stops matching, the classifier re-engages, and the unattended park returns silently — so the
# collapse must not smuggle an argument back in. The scan targets the argv-CONSUMING idioms
# (`$@`, `$#`, `${1:-…}`, `${1}`), not a bare `$1`, which is the repo's ordinary
# function-parameter form (`fail()` / `deny()` helpers) and says nothing about the script's own
# command line.
s148h_argv=0
[ -f "$S148_WRAP_FILE" ] && grep -qE '\$[@#]|\$\{1[:}]' "$S148_WRAP_FILE" 2>/dev/null && s148h_argv=1
if [ "$s148h_argv" = 0 ]; then
  ok "148h-bare: wrapper consumes no script argv — stays invocable bare, the exact allow entry keeps matching (#598, #633)"
else
  ng "148h-bare: wrapper must consume NO script argv — a variable argv is not allow-coverable wildcard-free (#633)"
fi

# §148h-ord (LOAD-BEARING RED — contracted order + TOCTOU foreclosure): stat → slurp → re-stat
# → unlink → POST. Assert an mtime read BEFORE the slurp and another AFTER it (the re-stat that
# makes the freshness check certify the bytes actually posted), the one-shot unlink after the
# last mtime read, and the POST after the unlink. Comment lines are excluded so prose cannot
# masquerade as the code form. An "mtime read" is either an inline portable `stat` or a call to
# a locally-defined mtime helper, so the lock constrains ORDER, not factoring.
s148h_mt_lns=$(grep -nE 'stat -[fc] %[mY]|\$\([A-Za-z_]*mtime' "$S148_WRAP_FILE" 2>/dev/null \
                 | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1)
s148h_slurp_ln=$(grep -nE '\$\(cat "\$' "$S148_WRAP_FILE" 2>/dev/null \
                 | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
s148h_rm_ln=$(grep -nF 'rm -f' "$S148_WRAP_FILE" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
s148h_post_ln=$(grep -nE 'gh api.*reviews' "$S148_WRAP_FILE" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
s148h_pre=0; s148h_postmt=0; s148h_lastmt=""
if [ -n "$s148h_slurp_ln" ]; then
  for s148h_l in $s148h_mt_lns; do
    [ "$s148h_l" -lt "$s148h_slurp_ln" ] && s148h_pre=1
    [ "$s148h_l" -gt "$s148h_slurp_ln" ] && s148h_postmt=1
  done
fi
[ -n "$s148h_mt_lns" ] && s148h_lastmt=$(printf '%s\n' "$s148h_mt_lns" | sort -n | tail -1)
if [ "$s148h_pre" = 1 ] && [ "$s148h_postmt" = 1 ] \
   && [ -n "$s148h_rm_ln" ] && [ -n "$s148h_post_ln" ] && [ -n "$s148h_lastmt" ] \
   && [ "$s148h_lastmt" -lt "$s148h_rm_ln" ] && [ "$s148h_rm_ln" -lt "$s148h_post_ln" ]; then
  ok "148h-ord: stat → slurp(L$s148h_slurp_ln) → re-stat(L$s148h_lastmt) → unlink(L$s148h_rm_ln) → POST(L$s148h_post_ln) (#602, #633)"
else
  ng "148h-ord: contracted order must be stat→slurp→re-stat→unlink→POST (pre=$s148h_pre post-mt=$s148h_postmt slurp=$s148h_slurp_ln lastmt=$s148h_lastmt rm=$s148h_rm_ln post=$s148h_post_ln) (#633)"
fi

# §148h-fc (LOAD-BEARING RED until Code, #647): EVERY fail-closed guard line sits ABOVE the
# reviews POST, and the wrapper's reject-arm INVENTORY is complete by name.
#
# The old form took only the FIRST match (`head -1`) and so could not detect the removal of any
# arm but the first — the #635 deletion of the `0*` mtime arm left it green. Widened here on two
# axes, and both limits are recorded honestly because a later round would otherwise rediscover
# them by hand:
#   (a) position — comment-filtered (`:146` is a full-line comment that matches the keyword set,
#       so the unfiltered grep was reading prose as code), every match must precede the POST.
#       Measured: predicate (a) ALONE stays green even with the entire staging-validation block
#       deleted, because the surviving symlink/marker/head arms still precede the POST. It pins
#       ORDER, not existence.
#   (b) existence — each contracted arm name appears as a `deny <name>` call. This is the limb
#       that reds when the block is deleted (10 of the 17 names vanish). It still cannot see the
#       removal of the `0*` ALTERNATIVE from a surviving arm, because the arm NAME survives —
#       only the behavioural §148j-oct-mt catches that. Source greps and behavioural locks are
#       complementary here, not redundant.
# The inventory is SPEC §5.29's, by name rather than by count: a count is what drifted (it read
# "all three mtime arms" against five) and a count cannot say WHICH arm went missing.
s148h_arms="symlink-dir symlink-leaf staging-absent staging-irregular staging-unreadable
staging-empty mtime-unresolvable mtime-changed mtime-malformed now-malformed mtime-future stale
marker-count marker-head-absent marker-head-mismatch local-head-unresolvable local-head-mismatch"
s148h_guard_lns=$(grep -nEi '(empty|absent|stale|malformed|symlink|mismatch).*(fail|deny|exit)|(fail|deny|exit).*(empty|absent|stale|malformed|symlink|mismatch)' "$S148_WRAP_FILE" 2>/dev/null \
                    | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1)
s148h_fc_n=0; s148h_fc_after=0
for s148h_l in $s148h_guard_lns; do
  s148h_fc_n=$((s148h_fc_n + 1))
  { [ -n "$s148h_post_ln" ] && [ "$s148h_l" -lt "$s148h_post_ln" ]; } || s148h_fc_after=$s148h_l
done
s148h_fc_miss=""
for s148h_arm in $s148h_arms; do
  grep -nE "deny $s148h_arm " "$S148_WRAP_FILE" 2>/dev/null | grep -qvE '^[0-9]+:[[:space:]]*#' || s148h_fc_miss="$s148h_fc_miss $s148h_arm"
done
if [ "$s148h_fc_n" -gt 0 ] && [ "$s148h_fc_after" = 0 ] && [ -z "$s148h_fc_miss" ]; then
  ok "148h-fc: all $s148h_fc_n fail-closed guard lines precede the POST (L$s148h_post_ln) and every contracted reject arm is present by name (#602, #633, #647)"
else
  ng "148h-fc: every fail-closed guard must precede the reviews POST and the SPEC §5.29 arm inventory must be complete (guards=$s148h_fc_n after-post=$s148h_fc_after post=$s148h_post_ln missing:$s148h_fc_miss) (#647)"
fi

# §148h-p4 (LOAD-BEARING RED until Code, #647): every reject arm reachable by a plausible HONEST
# MISTAKE names its own recovery, in the shape the `stale` arm already uses — an em dash followed
# by an imperative (SPEC §6.0 P4, arm-scoped). `stale` is included as the template anchor, so the
# shape this lock demands cannot drift away from the one instance of it that exists.
# The two symlink arms are EXEMPT by contract, not by oversight: a symlinked staging leaf is
# hostile input, there is no honest recovery to name, and drafting one would only coach the
# attempt (SPEC §5.29).
s148h_p4_miss=""
for s148h_arm in staging-irregular staging-unreadable staging-empty now-malformed stale; do
  grep -nE "deny $s148h_arm " "$S148_WRAP_FILE" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q '—' \
    || s148h_p4_miss="$s148h_p4_miss $s148h_arm"
done
if [ -z "$s148h_p4_miss" ]; then
  ok "148h-p4: every honest-mistake reject arm carries its own recovery clause; the symlink arms stay terse as hostile input (#647)"
else
  ng "148h-p4: honest-mistake arms must name their recovery in the shape 'stale' uses (bare:$s148h_p4_miss) (#647)"
fi

# §148h-doc (Doc-phase-confirming — GREEN since the Doc commit): SPEC §5.29 states the wrapper's
# reject set as the same inventory §148h-fc reads off the script, each name as a BACKTICKED code
# span. The backticks are load-bearing: `stale` occurs bare on dozens of SPEC lines as ordinary
# prose, so a bare-name grep would be satisfied by narration and this limb would be vacuous.
# The command doc carries the three arms that were absent from both surfaces (#647 AC 4).
# SCOPED TO THE ENUMERATION — not the file, and not the whole line either. Two narrowings, each
# measured the only way that settles it: delete every one of the 17 names in turn from the
# evaluation-order list and count which deletions this limb cannot see.
#   whole-file grep    -> 6 of 17 invisible. Five (`staging-irregular`, `staging-unreadable`,
#                         `staging-empty`, `now-malformed`, `stale`) are also backticked in the
#                         §5.29 recovery sentence; `mtime-malformed` is the sixth. (This measurement
#                         predates #647's Doc commit, which removed FOUR of those five from §6.0 P4.
#                         `stale` is still there, deliberately, as the shape template. The count
#                         holds via the §5.29 sentence alone either way.)
#   whole-LINE grep    -> 2 of 17 invisible (`staging-irregular`, `mtime-malformed`). The anchor
#                         line NARRATES those two as backticked spans in addition to enumerating
#                         them, so the line carries its own neighbour. That is also why
#                         `mtime-malformed` was invisible to the whole-file form: BOTH of its
#                         occurrences are on this one line, so line-scoping removed nothing for it.
#   enumeration only   -> 0 of 17. Measured, not argued.
# A colour-only mutation check could not have caught the middle step: the five-name deletion went
# RED there while naming only four, because `staging-irregular` was masked inside it. Assert WHICH
# names the red reports, never just that it went red.
# Two anchors, occurrence count 1 each, each failing closed with its own diagnostic token: the
# sentence anchor locates the line, the `The arms, in evaluation order:` lead-in cuts the
# enumeration out of it. Absent anchor => fail closed, never a silent whole-file fallback.
# Neither anchor pins the sentence BODY — rewriting the narration clause wholesale leaves this limb
# GREEN (measured). That is the ceiling: an anti-drift lock, not a rename tax.
# Residual, accepted rather than papered over: when the lead-in anchor is absent the diagnostic
# token leads the message but all 17 names still trail it as false "missing" entries. Fail-closed
# and diagnostic-first, so it is noise on a run that is already red.
s148h_bt='`'
s148h_doc_miss=""
s148h_inv_ln=$(grep -nF 'The inventory is stated by name, not by count' "$SHELL_ROOT/SPEC.md" 2>/dev/null | head -1 | cut -d: -f1)
if [ -z "$s148h_inv_ln" ]; then
  s148h_doc_miss=" <inventory-sentence-anchor-absent>"
else
  s148h_inv=$(sed -n "${s148h_inv_ln}p" "$SHELL_ROOT/SPEC.md" | sed -n 's/.*The arms, in evaluation order://p')
  [ -n "$s148h_inv" ] || s148h_doc_miss=" <inventory-enumeration-lead-in-absent>"
  for s148h_arm in $s148h_arms; do
    printf '%s' "$s148h_inv" | grep -qF "$s148h_bt$s148h_arm$s148h_bt" \
      || s148h_doc_miss="$s148h_doc_miss $s148h_arm"
  done
fi
s148h_doc_cmd_miss=""
for s148h_arm in staging-irregular mtime-malformed now-malformed; do
  grep -qF "$s148h_arm" "$SHELL_ROOT/.claude/commands/file-review.md" 2>/dev/null \
    || s148h_doc_cmd_miss="$s148h_doc_cmd_miss $s148h_arm"
done
if [ -z "$s148h_doc_miss" ] && [ -z "$s148h_doc_cmd_miss" ]; then
  ok "148h-doc: SPEC §5.29 names every wrapper reject arm as a code span and the command doc names the staging-irregular / mtime-malformed / now-malformed arms (#647)"
else
  ng "148h-doc: the doc enumerations must name every arm (SPEC missing:$s148h_doc_miss command-doc missing:$s148h_doc_cmd_miss) (#647)"
fi

# §148h-ttl2 (Doc-phase-confirming — GREEN since the Doc commit): SPEC §7 records the rule BOTH
# TTLs rest on — the check validates both of its operands, the stored timestamp AND the clock
# reading it is compared against, and an out-of-range value on either fail-safe-blocks and
# consumes the token. A comparison against an unvalidated clock is not a TTL (#647 AC 8).
if grep -qF 'validates both of its operands' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qF 'an out-of-range value on **either** operand fail-safe-blocks **and consumes the token**' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "148h-ttl2: SPEC §7 binds the TTL to BOTH operands — an out-of-range clock reading blocks and consumes, like an out-of-range created (#647)"
else
  ng "148h-ttl2: SPEC §7 must state that the TTL validates both operands and that either out of range blocks + consumes (#647)"
fi

# §148i-del (LOAD-BEARING RED — the deletion is complete): the retired writer script is GONE
# and its basename survives NOWHERE in the AC-named surfaces (SPEC.md, .claude/commands/,
# scripts/, scripts/test/). A surviving reference is either a dangling doc pointer or a live
# call site that would fail at runtime.
#
# `.claude/hooks` joins the roots, and a PHRASE lock joins the basename lock (#647). Both close
# the same measured blind spot: `hookrt.sh` described the writer in the PRESENT TENSE for two
# releases after it was deleted, and neither the old root set nor the basename grep could see it
# — the comment named the writer in prose, never by filename. The phrase arm exempts lines that
# already qualify the reference as `retired`/`deleted`, which is how a comment is allowed to keep
# explaining the history without asserting the writer still exists.
# The phrase limb reads the SAME root set as the basename limb (`.claude/hooks`, recursive), not
# `hookrt.sh` alone. It was hard-scoped to that one file while the basename roots were being
# widened, so a present-tense description in any OTHER hook file was invisible to both limbs even
# though the case comment claimed both closed the blind spot. Deliberately NOT widened past
# `.claude/hooks` to `SPEC.md`/`scripts/`: "stage writer" appears there in legitimate historical
# narration, where the `retired|deleted` exemption would be carrying the entire load.
s148i_del_gone=0; [ -e "$S148_STAGE_FILE" ] || s148i_del_gone=1
s148i_del_refs=$(grep -rlF "$S148_STAGE_BASE" \
                   "$SHELL_ROOT/SPEC.md" "$SHELL_ROOT/.claude/commands" "$SHELL_ROOT/scripts" \
                   "$SHELL_ROOT/.claude/hooks" \
                   2>/dev/null | grep -c . || true)
s148i_del_phrase=$(grep -rniE 'stage writer' "$SHELL_ROOT/.claude/hooks" 2>/dev/null \
                     | grep -viE 'retired|deleted' | grep -c . || true)
if [ "$s148i_del_gone" = 1 ] && [ "$s148i_del_refs" = 0 ] && [ "$s148i_del_phrase" = 0 ]; then
  ok "148i-del: the retired stage writer is deleted, referenced nowhere in SPEC.md / .claude/commands / scripts / .claude/hooks, and no file under .claude/hooks describes it in the present tense (refs=$s148i_del_refs) (#633, #647)"
else
  ng "148i-del: the stage writer must be deleted with no surviving reference and no present-tense description anywhere under .claude/hooks (present=$((1 - s148i_del_gone)) refs=$s148i_del_refs unqualified-phrases=$s148i_del_phrase) (#647)"
fi

# §148i-set (LOAD-BEARING RED — allow-surface parity + anti-return lock): NEITHER settings file
# may reference the retired writer in permissions.allow in ANY form (bare or wildcard), and the
# two allow lists must match. §148b/§148c/§148i-reg count only the literal
# `ghjig_file_review_post.sh`, so a stage-script entry is invisible to them — this lock closes
# that blind spot. A `:*` entry for the writer was the tempting wrong fix: it would have
# auto-approved an arbitrary-path read with no visible prompt.
s148i_set_ref=0; s148i_inj_ref=0; s148i_parity=0
[ -f "$S148_SET" ] && grep -qF "$S148_STAGE_BASE" "$S148_SET" 2>/dev/null && s148i_set_ref=1
[ -f "$S148_INJ" ] && grep -qF "$S148_STAGE_BASE" "$S148_INJ" 2>/dev/null && s148i_inj_ref=1
s148i_allow_of() {  # $1=settings file -> permissions.allow, one entry per line
  [ -f "$1" ] || return 0
  if command -v jq >/dev/null 2>&1; then jq -r '.permissions.allow[]?' "$1" 2>/dev/null
  else grep -oE '"Bash\([^"]*\)"' "$1" 2>/dev/null; fi
}
s148i_a_set=$(s148i_allow_of "$S148_SET"); s148i_a_inj=$(s148i_allow_of "$S148_INJ")
[ -n "$s148i_a_set" ] && [ "$s148i_a_set" = "$s148i_a_inj" ] && s148i_parity=1
if [ "$s148i_set_ref" = 0 ] && [ "$s148i_inj_ref" = 0 ] && [ "$s148i_parity" = 1 ]; then
  ok "148i-set: neither settings file references the retired writer in any form, and the two allow lists are identical (#633)"
else
  ng "148i-set: the retired writer must appear in NO allow entry (bare or wildcard) and the two allow lists must match (set_ref=$s148i_set_ref inj_ref=$s148i_inj_ref parity=$s148i_parity) (#633)"
fi

# §148i-cli (regression lock — single shared sync point, retargeted): ghjig_state_dir_cli is
# DEFINED EXACTLY ONCE in the tree (anchored def-form grep, so the file-review.md prose mention
# does not count), that one definition lives in hookrt.sh, and the wrapper — now its ONLY
# caller, the writer having been deleted — calls it without re-defining it.
s148i_defs=$(grep -rlE '^[[:space:]]*ghjig_state_dir_cli[[:space:]]*\(\)' "$SHELL_ROOT/.claude" "$SHELL_ROOT/scripts" 2>/dev/null | sort -u)
s148i_defcount=$(printf '%s\n' "$s148i_defs" | grep -c . )
s148i_in_hookrt=0
printf '%s\n' "$s148i_defs" | grep -q 'hookrt\.sh$' && s148i_in_hookrt=1
s148i_wrap_redef=0; s148i_wrap_calls=0
if [ -f "$S148_WRAP_FILE" ]; then
  grep -qE '^[[:space:]]*ghjig_state_dir_cli[[:space:]]*\(\)' "$S148_WRAP_FILE" 2>/dev/null && s148i_wrap_redef=1
  grep -qF 'ghjig_state_dir_cli' "$S148_WRAP_FILE" 2>/dev/null && s148i_wrap_calls=1
fi
if [ "$s148i_defcount" = 1 ] && [ "$s148i_in_hookrt" = 1 ] && [ "$s148i_wrap_redef" = 0 ] && [ "$s148i_wrap_calls" = 1 ]; then
  ok "148i-cli: ghjig_state_dir_cli defined exactly once (in hookrt.sh); the wrapper is its only caller and never re-defines it (count=$s148i_defcount hookrt=$s148i_in_hookrt) (#602, #633)"
else
  ng "148i-cli: ghjig_state_dir_cli must be a single hookrt.sh definition the wrapper calls, never re-defines (count=$s148i_defcount hookrt=$s148i_in_hookrt redef=$s148i_wrap_redef calls=$s148i_wrap_calls) (#602, #633)"
fi

# §148i-clibranch (LOAD-BEARING RED — writer/reader path agreement is CHECKABLE): the agent
# writes the project-dir-relative literal `.claude/ghjig-state/file-review/staging` while the
# wrapper resolves its own path via ghjig_state_dir_cli. `hookrt.sh:95-97` records that a
# Bash-tool subprocess OFTEN runs with CLAUDE_PROJECT_DIR unset, so the live branch is the
# `git rev-parse --show-toplevel` one. Pin exactly that branch: no override, CLAUDE_PROJECT_DIR
# UNSET, cwd at the project root → <project-root>/.claude/ghjig-state. If it drifts, the two
# links of the producer silently disagree and /ship parks — the failure #633 exists to remove.
S148CB_DIR=$(mktemp -d)
( cd "$S148CB_DIR" && git init -q && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false && git commit --allow-empty -q -m init ) >/dev/null 2>&1 || true
s148cb_got=$( unset GHJIG_STATE_DIR_OVERRIDE CLAUDE_PROJECT_DIR
              cd "$S148CB_DIR" && . "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null \
              && ghjig_state_dir_cli 2>/dev/null )
s148cb_want="$(cd "$S148CB_DIR" && pwd -P)/.claude/ghjig-state"
rm -rf "$S148CB_DIR"
if [ -n "$s148cb_got" ] && [ "$s148cb_got" = "$s148cb_want" ]; then
  ok "148i-clibranch: CLAUDE_PROJECT_DIR unset + no override + cwd at the git top level → ghjig_state_dir_cli == <project-root>/.claude/ghjig-state (#633)"
else
  ng "148i-clibranch: the live Bash-tool branch must resolve to the project-root state dir (got='$s148cb_got' want='$s148cb_want') (#633)"
fi

# §148i-marker (LOAD-BEARING RED — producer/consumer parse anti-drift): the wrapper counts
# markers with the BYTE-IDENTICAL canonical regex the merge-side consumer uses. A looser
# producer parse would POST a body the merge gate then rejects, moving the park from the free
# pre-POST side to the UNRETRACTABLE published-review side (SPEC §5.29).
s148i_rx_gate=0; s148i_rx_wrap=0
[ -f "$S148_ACGATE" ]    && grep -qF "$S148_MARKER_RX" "$S148_ACGATE"    2>/dev/null && s148i_rx_gate=1
[ -f "$S148_WRAP_FILE" ] && grep -qF "$S148_MARKER_RX" "$S148_WRAP_FILE" 2>/dev/null && s148i_rx_wrap=1
if [ "$s148i_rx_gate" = 1 ] && [ "$s148i_rx_wrap" = 1 ]; then
  ok "148i-marker: the canonical marker regex is byte-identical in ac_closeout_gate.sh and the wrapper (#633)"
else
  ng "148i-marker: producer + consumer must share the marker regex byte-for-byte (gate=$s148i_rx_gate wrapper=$s148i_rx_wrap) (#633)"
fi

# §148i-audit (LOAD-BEARING RED — the block's deferred positive face): the wrapper audits
# file-review/rejected on its fail-closed arms. Two mechanism details are load-bearing and easy
# to get wrong: audit_log resolves its log via ghjig_state_dir (NOT _cli), so the call needs an
# explicit state-dir env prefix or the record lands outside the project; and a failing
# audit_log must never abort the reject under `set -euo pipefail` — it must not convert a
# fail-closed refusal into anything else (SPEC §5.29 Audit).
s148i_au_call=0; s148i_au_dec=0; s148i_au_guard=0; s148i_au_prefix=0
if [ -f "$S148_WRAP_FILE" ]; then
  grep -qF 'audit_log' "$S148_WRAP_FILE" 2>/dev/null && s148i_au_call=1
  grep -qE 'audit_log.*file-review' "$S148_WRAP_FILE" 2>/dev/null \
    && grep -qF 'rejected' "$S148_WRAP_FILE" 2>/dev/null && s148i_au_dec=1
  grep -qE '\|\|[[:space:]]*true' "$S148_WRAP_FILE" 2>/dev/null && s148i_au_guard=1
  grep -qE 'CLAUDE_PROJECT_DIR=' "$S148_WRAP_FILE" 2>/dev/null && s148i_au_prefix=1
fi
if [ "$s148i_au_call$s148i_au_dec$s148i_au_guard$s148i_au_prefix" = 1111 ]; then
  ok "148i-audit: wrapper audits file-review/rejected with an explicit state-dir env prefix and a non-aborting guard (#633)"
else
  ng "148i-audit: every fail-closed arm must audit file-review/rejected, with an explicit state-dir env prefix and a '|| true' guard (call=$s148i_au_call dec=$s148i_au_dec guard=$s148i_au_guard prefix=$s148i_au_prefix) (#633)"
fi

# §148i-doc (LOAD-BEARING RED — the doc names the write target, not a deleted script):
# file-review.md must name the fixed staging path the agent writes, invoke the wrapper BARE (no
# `| …/ghjig_file_review_post.sh` pipe — a pipe makes the covered command non-bare → the
# classifier re-engages, the exact failure #602 forecloses), and no longer reference the retired
# writer. Positive + negative fused so a stripped doc cannot green it vacuously; the positive
# anchor MOVES from the now-deleted stage-ref to the staging-path literal + the wrapper path.
s148i_pipe=0; s148i_staging_ref=0; s148i_wrap_ref=0; s148i_stage_ref=0
if [ -f "$S148_FR" ]; then
  grep -qE '\|[[:space:]]*(\.?/)?\.claude/ghjig-root/scripts/ghjig_file_review_post\.sh' "$S148_FR" 2>/dev/null && s148i_pipe=1
  grep -qF "$S148_STAGING_CANON" "$S148_FR" 2>/dev/null && s148i_staging_ref=1
  grep -qF "$S148_WRAP_CANON"    "$S148_FR" 2>/dev/null && s148i_wrap_ref=1
  grep -qF "$S148_STAGE_BASE"    "$S148_FR" 2>/dev/null && s148i_stage_ref=1
fi
if [ "$s148i_pipe" = 0 ] && [ "$s148i_staging_ref" = 1 ] && [ "$s148i_wrap_ref" = 1 ] && [ "$s148i_stage_ref" = 0 ]; then
  ok "148i-doc: file-review.md names $S148_STAGING_CANON, invokes the wrapper bare, and no longer references the retired writer (#602, #633)"
else
  ng "148i-doc: file-review.md must name $S148_STAGING_CANON + the bare wrapper and drop the retired writer (pipe=$s148i_pipe staging=$s148i_staging_ref wrap=$s148i_wrap_ref stale_stage=$s148i_stage_ref) (#633)"
fi

# §148i-reg (regression re-affirm — must stay GREEN): the #598 invariants the #602
# retarget must not regress — settings.json carries ONLY the exact narrow wrapper allow
# (no wildcard, no raw gh-api-reviews) [§148b] AND the wrapper stays event=COMMENT-only
# with an own-PR author guard [§148d]. Re-run both so the retarget cannot silently drop
# the boundary while flipping §148h green.
s148i_narrow=0
if [ -f "$S148_SET" ]; then
  s148i_any=$(grep -cF 'ghjig_file_review_post.sh' "$S148_SET" 2>/dev/null || true)
  s148i_exact=$(grep -cF "Bash($S148_WRAP_CANON)" "$S148_SET" 2>/dev/null || true)
  s148i_raw=$(grep -cE 'gh api[^"]*pulls[^"]*reviews' "$S148_SET" 2>/dev/null || true)
  [ "$s148i_exact" -ge 1 ] && [ "$s148i_any" = "$s148i_exact" ] && [ "$s148i_raw" = 0 ] && s148i_narrow=1
fi
s148i_shape=0
if [ -f "$S148_WRAP_FILE" ] && [ -x "$S148_WRAP_FILE" ] \
   && grep -qF 'event=COMMENT' "$S148_WRAP_FILE" 2>/dev/null \
   && ! grep -qE 'event=(APPROVE|REQUEST_CHANGES)' "$S148_WRAP_FILE" 2>/dev/null \
   && grep -qiE 'author' "$S148_WRAP_FILE" 2>/dev/null; then
  s148i_shape=1
fi
if [ "$s148i_narrow" = 1 ] && [ "$s148i_shape" = 1 ]; then
  ok "148i-reg: #598 invariants intact — narrow exact allow (§148b) + event=COMMENT-only own-PR guard (§148d) survive the retarget (#602)"
else
  ng "148i-reg: retarget must preserve the narrow allow + COMMENT-only own-PR guard (narrow=$s148i_narrow shape=$s148i_shape) (#602)"
fi

# §148j (LOAD-BEARING RED — behavioral round trip, agent-written staging file): drive the REAL
# wrapper against a gh shim that records reviews POSTs. The staging file is written DIRECTLY —
# no writer script, that IS the change — body only, no header stamps. A fresh, marker-matching,
# head-matching body → exactly ONE POST + the file unlinked; every fail-closed input → NO POST.
# State resolves under CLAUDE_PROJECT_DIR/.claude/ghjig-state/file-review via the shared
# ghjig_state_dir_cli() (override unset so CLAUDE_PROJECT_DIR is the sync point), except the
# audit case, which unsets CLAUDE_PROJECT_DIR to exercise the live git-top-level branch.
S148J_DIR=$(mktemp -d)
S148J_BIN="$S148J_DIR/bin"; S148J_ST="$S148J_DIR/ghstate"; S148J_PROJ="$S148J_DIR/proj"
mkdir -p "$S148J_BIN" "$S148J_ST" "$S148J_PROJ"
cat > "$S148J_BIN/gh" <<'SHIM'
#!/bin/sh
case "$*" in
  *api*reviews*)  : "${GH_SHIM_STATE:?}"; echo post >> "$GH_SHIM_STATE/post_log"
                  echo '{"id":1,"commit_id":"h","state":"COMMENTED","user":"me"}' ;;
  *"api user"*)   cat "$GH_SHIM_STATE/api_user" 2>/dev/null ;;
  *"pr view"*)    cat "$GH_SHIM_STATE/pr_view" 2>/dev/null ;;
  *"repo view"*)  cat "$GH_SHIM_STATE/name_with_owner" 2>/dev/null ;;
esac
exit 0
SHIM
chmod +x "$S148J_BIN/gh"
( cd "$S148J_PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false && git checkout -q -b smoke/feat/1-frpost \
    && git commit --allow-empty -q -m init ) >/dev/null 2>&1 || true
S148J_HEAD=$(cd "$S148J_PROJ" && git rev-parse HEAD 2>/dev/null || echo nohead)
printf 'me\n'        > "$S148J_ST/api_user"
printf 'octo/repo\n' > "$S148J_ST/name_with_owner"
s148j_prview() { printf '{"number":55,"headRefOid":"%s","author":{"login":"me"}}\n' "$1" > "$S148J_ST/pr_view"; }
s148j_prview "$S148J_HEAD"
S148J_ESD="$S148J_PROJ/.claude/ghjig-state"
S148J_FRDIR="$S148J_ESD/file-review"
S148J_SF="$S148J_FRDIR/staging"
s148j_reset() { rm -f "$S148J_ST/post_log" 2>/dev/null; rm -rf "$S148J_FRDIR" 2>/dev/null; s148j_prview "$S148J_HEAD"; }
s148j_posts() { if [ -f "$S148J_ST/post_log" ]; then wc -l < "$S148J_ST/post_log" | tr -d ' '; else echo 0; fi; }
s148j_left()  { if [ -e "$S148J_SF" ]; then echo "$S148J_SF"; fi; }
s148j_marker() { printf '<!-- file-review verdict=approve head=%s reviewer=code-reviewer -->' "${1:-$S148J_HEAD}"; }
# The agent-write link: the sanitized body goes to the staging file DIRECTLY, body only.
s148j_write() { mkdir -p "$S148J_FRDIR"; { s148j_marker "${1:-}"; printf '\nlgtm\n'; } > "$S148J_SF"; }
# Portable relative-mtime set — the repo idiom (BSD `date -v`, GNU `date -d`); `touch -t` takes
# a .SS suffix on both, so second-granularity offsets are expressible.
s148j_mtime() {  # $1=BSD offset (e.g. -120S)   $2=GNU phrase (e.g. '120 seconds ago')
  s148j_ts=$(date -v"$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "$2" +%Y%m%d%H%M.%S)
  touch -t "$s148j_ts" "$S148J_SF" 2>/dev/null || true
}
# The optional $1 is a case-private shim directory prepended to PATH for THIS CALL ONLY (#647).
# A positional PARAMETER, not an ambient variable, on purpose: a parameter has no lifetime past
# the call, so shim leakage into a later case is structurally impossible rather than something a
# future editor has to remember to clear. That is not theoretical — a leaked `stat`/`date` shim
# was measured to turn a REAL guard deletion from red to green in the downstream cases, silently
# defanging eight `posts==0` assertions. Every pre-#647 call site passes no argument, so `${1:-}`
# is empty and PATH is byte-identical to the pre-seam form.
s148j_post() { local _shim="${1:-}"; ( unset GHJIG_STATE_DIR_OVERRIDE; cd "$S148J_PROJ" \
                   && CLAUDE_PROJECT_DIR="$S148J_PROJ" PATH="${_shim:+$_shim:}$S148J_BIN:$PATH" \
                      GH_SHIM_STATE="$S148J_ST" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
                      bash "$S148_WRAP_FILE" </dev/null ) >/dev/null 2>&1 || true; }
# The same call with CLAUDE_PROJECT_DIR UNSET — the live Bash-tool shape (hookrt.sh:95-97),
# where ghjig_state_dir_cli falls to the git-top-level branch and audit_log's own
# ghjig_state_dir would resolve EMPTY without an explicit env prefix.
# It carries the same optional shim parameter for parity of the two drivers; no case uses it
# today, so it is offered as a seam and claimed as nothing more.
s148j_post_nopd() { local _shim="${1:-}"; ( unset GHJIG_STATE_DIR_OVERRIDE CLAUDE_PROJECT_DIR; cd "$S148J_PROJ" \
                        && PATH="${_shim:+$_shim:}$S148J_BIN:$PATH" GH_SHIM_STATE="$S148J_ST" \
                           GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
                           bash "$S148_WRAP_FILE" </dev/null ) >/dev/null 2>&1 || true; }

# 148j-fresh (LOAD-BEARING RED): fresh agent-written body → exactly ONE POST + file unlinked.
s148j_reset; s148j_write; s148j_post
s148j_fp=$(s148j_posts); s148j_fl=$(s148j_left)
if [ "$s148j_fp" = 1 ] && [ -z "$s148j_fl" ]; then
  ok "148j-fresh: fresh agent-written staging body → exactly one reviews POST + file unlinked (#602, #633)"
else
  ng "148j-fresh: a fresh staging body must POST once and unlink the file (posts=$s148j_fp left='$s148j_fl') (#633)"
fi

# 148j-absent: no staging file → NO POST (fail-closed).
s148j_reset; s148j_post; s148j_p=$(s148j_posts)
if [ "$s148j_p" = 0 ]; then ok "148j-absent: no staging file → NO reviews POST (fail-closed) (#602, #633)"
else ng "148j-absent: an absent staging file must not POST (posts=$s148j_p) (#633)"; fi

# 148j-empty: zero-byte staging file → NO POST.
s148j_reset; mkdir -p "$S148J_FRDIR"; : > "$S148J_SF"
s148j_post; s148j_p=$(s148j_posts)
if [ "$s148j_p" = 0 ]; then ok "148j-empty: empty staging file → NO reviews POST (fail-closed) (#602, #633)"
else ng "148j-empty: an empty staging file must not POST (posts=$s148j_p) (#633)"; fi

# 148j-stale (RETAINED, retargeted from the created= stamp to the file's mtime): mtime older
# than the 60s TTL → NO POST + poison file unlinked.
s148j_reset; s148j_write; s148j_mtime -120S '120 seconds ago'
s148j_post; s148j_p=$(s148j_posts); s148j_l=$(s148j_left)
if [ "$s148j_p" = 0 ] && [ -z "$s148j_l" ]; then ok "148j-stale: mtime >60s old → NO POST + poison file unlinked (#602, #633)"
else ng "148j-stale: a stale staging body must not POST and must be unlinked (posts=$s148j_p left='$s148j_l') (#633)"; fi

# 148j-future (RETAINED, retargeted to mtime): a future-dated mtime is its OWN reject arm —
# `now - mt <= 60` alone PASSES for it, so without the explicit arm the guard silently
# disappears in the move off the created= stamp (SPEC §5.7.1).
s148j_reset; s148j_write; s148j_mtime +120S '120 seconds'
s148j_post; s148j_p=$(s148j_posts)
if [ "$s148j_p" = 0 ]; then ok "148j-future: future-dated mtime → NO reviews POST (fail-closed) (#602, #633)"
else ng "148j-future: a future-dated staging body must not POST (posts=$s148j_p) (#633)"; fi

# ---------- §148j-oct: both operands of the TTL subtraction, locked behaviourally (#647) -------
# The wrapper's freshness check is `[ "$(( now - mt1 ))" -le 60 ] || deny stale`. An operand that
# is not a plain epoch makes that arithmetic expansion FAIL, and a failed expansion does not fail
# the `[ … ] || deny` list — it SKIPS the list, so the freshness check is never evaluated and
# execution reaches the POST. Both operands therefore need the same guard; one of them has had it
# since #635 and the other has never had it.
#
# Script-file mode is load-bearing, not incidental: run as a script the arithmetic error prints
# and control continues (the defect); the identical statements under `bash -c` abort and show the
# SAFE behaviour, which is how the guard came to be cleared twice by probing (#635). The §148j
# driver already invokes `bash "$S148_WRAP_FILE"`, which is the mode the defect lives in.
#
# The shim constants are BAKED at case setup rather than read live inside the shim: the wrapper
# calls fr_mtime twice and requires mt1 == mt2, so a live-clock `stat` shim can flake into the
# `mtime-changed` arm and green for a reason the case does not name. Each shim gets its own
# directory, handed to the driver as a call-scoped positional parameter.
S148J_OCT="$S148J_DIR/oct"
mkdir -p "$S148J_OCT/mt-bad" "$S148J_OCT/mt-ok" "$S148J_OCT/now-bad" "$S148J_OCT/now-ok"
s148j_real_stat=$(command -v stat 2>/dev/null || echo /usr/bin/stat)
s148j_real_date=$(command -v date 2>/dev/null || echo /bin/date)
# Answer only for the staging path and exec the real binary otherwise. That scoping is hardening,
# not what makes the case valid (a blunt shim discriminates identically) — it keeps a future
# `stat` consumer inside the wrapper subshell reading the truth.
s148j_mk_stat() {  # $1=shim dir  $2=mtime string the shim reports for the staging file
  cat > "$1/stat" <<STATSHIM
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "$S148J_SF" ] && { echo "$2"; exit 0; }
done
exec "$s148j_real_stat" "\$@"
STATSHIM
  chmod +x "$1/stat"
}
# Intercept `+%s` ONLY: audit_log stamps its records with `date -u +%FT%TZ`, and a shim that also
# captured that would make a reject unobservable for a reason the case does not name.
s148j_mk_date() {  # $1=shim dir  $2=prefix prepended to the real epoch for `date +%s`
  cat > "$1/date" <<DATESHIM
#!/bin/sh
[ "\$1" = "+%s" ] && { echo "$2\$("$s148j_real_date" +%s)"; exit 0; }
exec "$s148j_real_date" "\$@"
DATESHIM
  chmod +x "$1/date"
}

# 148j-oct-mt (regression lock — must stay GREEN; AC 1): a leading-zero staging mtime is rejected
# as `mtime-malformed` → NO POST. This is the behavioural lock the restored `0*` arm had none of:
# with that one alternative removed, this exact input publishes a ten-minute-stale body. It has
# to be behavioural, because a source grep is what failed — §148h-fc greens on a `0*`-removed
# wrapper too, since the arm NAME survives the edit.
s148j_mk_stat "$S148J_OCT/mt-bad" "0$(( $(date +%s) - 600 ))"
s148j_reset; s148j_write
s148j_post "$S148J_OCT/mt-bad"; s148j_p=$(s148j_posts)
if [ "$s148j_p" = 0 ]; then ok "148j-oct-mt: a leading-zero staging mtime is rejected before the TTL arithmetic → NO reviews POST (#647)"
else ng "148j-oct-mt: a leading-zero staging mtime must not reach the POST (posts=$s148j_p) (#647)"; fi

# 148j-oct-mt-ok (non-vacuity half of §148j-oct-mt; AC 2): the identical shim mechanism reporting
# a PLAIN epoch inside the TTL still posts, so the lock above cannot pass by blocking everything.
s148j_mk_stat "$S148J_OCT/mt-ok" "$(( $(date +%s) - 5 ))"
s148j_reset; s148j_write
s148j_post "$S148J_OCT/mt-ok"; s148j_p=$(s148j_posts)
if [ "$s148j_p" = 1 ]; then ok "148j-oct-mt-ok: the same stat shim reporting a plain in-TTL epoch still POSTs once — the mtime lock rejects the shape, not the shim (#647)"
else ng "148j-oct-mt-ok: a plain in-TTL mtime must still POST under the stat shim (posts=$s148j_p) (#647)"; fi

# 148j-oct-now (LOAD-BEARING RED until Code; AC 3): the TTL's OTHER operand. `now=$(date +%s)`
# feeds the same subtraction, so a leading-zero CLOCK reading breaks it identically — and the
# staging mtime here is an ordinary ten-minute-stale epoch that the `stale` arm exists to reject.
# A guard on one operand and none on its twin is the asymmetry this lock closes: what the TTL
# compares against has to be validated to the same standard as what it compares.
s148j_mk_date "$S148J_OCT/now-bad" 0
s148j_reset; s148j_write; s148j_mtime -600S '600 seconds ago'
s148j_post "$S148J_OCT/now-bad"; s148j_p=$(s148j_posts)
if [ "$s148j_p" = 0 ]; then ok "148j-oct-now: a leading-zero clock reading is rejected before the TTL arithmetic → a stale body gets NO reviews POST (#647)"
else ng "148j-oct-now: a malformed clock reading must not carry a stale body past the TTL to the POST (posts=$s148j_p) (#647)"; fi

# 148j-oct-now-ok (non-vacuity half of §148j-oct-now): the identical shim mechanism emitting a
# plain epoch still posts a fresh body, so the clock lock rejects the shape, not the shim.
s148j_mk_date "$S148J_OCT/now-ok" ""
s148j_reset; s148j_write
s148j_post "$S148J_OCT/now-ok"; s148j_p=$(s148j_posts)
if [ "$s148j_p" = 1 ]; then ok "148j-oct-now-ok: the same date shim emitting a plain epoch still POSTs a fresh body once (#647)"
else ng "148j-oct-now-ok: a plain clock reading must still POST a fresh body under the date shim (posts=$s148j_p) (#647)"; fi

# 148j-canary (anti-vacuity backstop for the shim seam): the SHARED $S148J_BIN that every §148j
# case reads still holds exactly the `gh` shim after the four cases above. Each of those handed
# its shim to the driver as a call-scoped parameter; a shim that ever landed in the shared dir
# instead would stay on PATH for the rest of the family, where a `stat`/`date` answer of its own
# can turn a real guard deletion green and silently defang eight `posts == 0` assertions. Safe
# against §148j-restat's transient `cat` shim below — nothing resets between its create and its
# removal, so this canary never sees it.
s148j_bin_ls=$(ls "$S148J_BIN" 2>/dev/null | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
if [ "$s148j_bin_ls" = "gh" ]; then ok "148j-canary: the shared §148j shim dir holds exactly the gh shim — every case-private shim stayed call-scoped (#647)"
else ng "148j-canary: a case-private shim leaked into the shared §148j shim dir (contents='$s148j_bin_ls') (#647)"; fi

# 148j-restat (NEW): the freshness check must certify the bytes actually POSTED. A concurrent
# rewrite between the pre-slurp stat and the read is simulated by a `cat` shim that bumps the
# file's mtime immediately after reading it; the post-slurp re-stat must then differ → NO POST.
s148j_reset; s148j_write; s148j_mtime -10S '10 seconds ago'
cat > "$S148J_BIN/cat" <<'CATSHIM'
#!/bin/sh
/bin/cat "$@"
rc=$?
for f in "$@"; do [ -f "$f" ] && touch "$f"; done
exit $rc
CATSHIM
chmod +x "$S148J_BIN/cat"
s148j_post; s148j_p=$(s148j_posts)
rm -f "$S148J_BIN/cat"
if [ "$s148j_p" = 0 ]; then ok "148j-restat: mtime changed between the pre- and post-slurp stat → NO reviews POST (#633)"
else ng "148j-restat: a body rewritten during the slurp must not POST — the re-stat must fail closed (posts=$s148j_p) (#633)"; fi

# 148j-marker0 (RETAINED from -malformed, retargeted to the marker contract): zero canonical
# markers → NO POST + poison file unlinked.
s148j_reset; mkdir -p "$S148J_FRDIR"; printf 'lgtm, no marker here\n' > "$S148J_SF"
s148j_post; s148j_p=$(s148j_posts); s148j_l=$(s148j_left)
if [ "$s148j_p" = 0 ] && [ -z "$s148j_l" ]; then ok "148j-marker0: zero canonical markers → NO POST + poison file unlinked (#602, #633)"
else ng "148j-marker0: a body with no canonical marker must not POST and must be unlinked (posts=$s148j_p left='$s148j_l') (#633)"; fi

# 148j-marker2 (NEW): two concrete markers → NO POST. A looser producer parse would POST a body
# the merge gate then rejects, moving the park to the unretractable published-review side.
s148j_reset; mkdir -p "$S148J_FRDIR"
{ s148j_marker; printf '\nquoting a second concrete instance:\n'; s148j_marker; printf '\n'; } > "$S148J_SF"
s148j_post; s148j_p=$(s148j_posts)
if [ "$s148j_p" = 0 ]; then ok "148j-marker2: two canonical markers → NO reviews POST (fail-closed) (#633)"
else ng "148j-marker2: a body carrying two canonical markers must not POST (posts=$s148j_p) (#633)"; fi

# 148j-headmiss (RETAINED, retargeted from the head= stamp to the MARKER arm): the marker's
# head= IS the remote head the review was performed against, so a foreign push that advances
# the PR head after /file-review computed it must not let the wrapper pin commit_id to a head
# no reviewer ever saw.
s148j_reset; s148j_write "foreign-push-$S148J_HEAD"
s148j_post; s148j_p=$(s148j_posts); s148j_l=$(s148j_left)
if [ "$s148j_p" = 0 ] && [ -z "$s148j_l" ]; then ok "148j-headmiss: marker head= != resolved headRefOid → NO POST + poison file unlinked (#602, #633)"
else ng "148j-headmiss: a marker/head mismatch must not POST and must be unlinked (posts=$s148j_p left='$s148j_l') (#633)"; fi

# 148j-localhead (NEW — the shell-authored belt): the marker head EQUALS the resolved head, but
# the local checkout sits on a different commit. This is exactly what the retired stamp
# compared; it stays a staleness guard, not anti-forge.
s148j_reset; s148j_prview deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
s148j_write deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
s148j_post; s148j_p=$(s148j_posts)
s148j_prview "$S148J_HEAD"
if [ "$s148j_p" = 0 ]; then ok "148j-localhead: local git HEAD != resolved headRefOid → NO reviews POST (fail-closed) (#633)"
else ng "148j-localhead: a local-checkout head mismatch must not POST (posts=$s148j_p) (#633)"; fi

# 148j-symleaf (NEW): a symlinked staging LEAF restores the arbitrary-path read #633 retires —
# `stat` defaults to lstat on both BSD and GNU, so the link reports its own fresh mtime while
# the content read follows to an arbitrary target and [ -r ] / [ -s ] / [ -f ] all pass.
s148j_reset; mkdir -p "$S148J_FRDIR"
{ s148j_marker; printf '\nelsewhere\n'; } > "$S148J_DIR/elsewhere.txt"
ln -s "$S148J_DIR/elsewhere.txt" "$S148J_SF" 2>/dev/null || true
s148j_post; s148j_p=$(s148j_posts); rm -f "$S148J_SF"
if [ "$s148j_p" = 0 ]; then ok "148j-symleaf: symlinked staging leaf → NO reviews POST (fail-closed) (#633)"
else ng "148j-symleaf: a symlinked staging leaf must not POST — that IS the arbitrary-path read (posts=$s148j_p) (#633)"; fi

# 148j-symdir (NEW): with the file-review DIRECTORY component a symlink, the leaf is a genuine
# regular file and every leaf-only check passes — leaf-only guarding is provably insufficient.
s148j_reset; rm -rf "$S148J_FRDIR"
mkdir -p "$S148J_ESD/fr-real"
{ s148j_marker; printf '\nvia a symlinked dir\n'; } > "$S148J_ESD/fr-real/staging"
ln -s "$S148J_ESD/fr-real" "$S148J_FRDIR" 2>/dev/null || true
s148j_post; s148j_p=$(s148j_posts); rm -f "$S148J_FRDIR"; rm -rf "$S148J_ESD/fr-real"
if [ "$s148j_p" = 0 ]; then ok "148j-symdir: symlinked file-review directory component → NO reviews POST (fail-closed) (#633)"
else ng "148j-symdir: a symlinked file-review directory component must not POST — leaf-only checks are insufficient (posts=$s148j_p) (#633)"; fi

# 148j-audit (LOAD-BEARING RED — the deferred positive face lands where it can be READ): a
# reject run in the LIVE Bash-tool shape (CLAUDE_PROJECT_DIR unset) must write a
# file-review/rejected record into the per-project audit log the wrapper itself resolved, and
# must NOT echo body content into it. Without an explicit env prefix audit_log's own
# ghjig_state_dir resolves empty and the record lands outside the project — invisible blocks.
s148j_reset; rm -rf "$S148J_ESD/audit"
s148j_write; s148j_mtime -120S '120 seconds ago'
s148j_post_nopd; s148j_p=$(s148j_posts)
s148j_aud=0; s148j_leak=0
if [ -f "$S148J_ESD/audit/audit.jsonl" ]; then
  grep -q '"category":"file-review"' "$S148J_ESD/audit/audit.jsonl" 2>/dev/null \
    && grep -q '"decision":"rejected"' "$S148J_ESD/audit/audit.jsonl" 2>/dev/null && s148j_aud=1
  grep -q 'lgtm' "$S148J_ESD/audit/audit.jsonl" 2>/dev/null && s148j_leak=1
fi
if [ "$s148j_p" = 0 ] && [ "$s148j_aud" = 1 ] && [ "$s148j_leak" = 0 ]; then
  ok "148j-audit: a reject audits file-review/rejected into the per-project log, arm name only — no body content (#633)"
else
  ng "148j-audit: every reject must audit file-review/rejected into the wrapper-resolved per-project log, carrying the arm name only (posts=$s148j_p audited=$s148j_aud body-leak=$s148j_leak) (#633)"
fi

rm -rf "$S148J_DIR"

# ---------- §138: pinned-reproducible shellcheck lint runner (#545) ----------
# SPEC §11 (syntax job). The CI `syntax` job's shellcheck must become a single
# reproducible predicate that a developer runs locally identically — `scripts/lint.sh`
# — with the memory-cliff regression (#543/#539, combined `shellcheck "${files[@]}"`
# peaked ~18 GB RSS and OOM-killed the runner) permanently guarded by a per-file loop,
# and the shellcheck binary version-pinned + SHA256-verified fail-closed so "clean
# locally" and "clean in CI" are one predicate by construction.
#
# The runner DOES NOT EXIST YET (Phase B / Doc→Test→Code): scripts/lint.sh is absent
# and ci.yml still installs shellcheck unpinned via apt-get with no ./scripts/lint.sh
# call. Every product assertion below (a-e) therefore reports RED; f is a
# Doc-phase-confirming guard, expected GREEN (the SPEC §11 rewrite already landed).
# Anti-vacuity: the structural locks (138b, 138e) pair a required POSITIVE anchor with
# the forbidden-form absence, so an empty/comment-only file cannot green them.
S138_LINT="$SHELL_ROOT/scripts/lint.sh"
S138_CI="$SHELL_ROOT/.github/workflows/ci.yml"
S138_SPEC="$SHELL_ROOT/SPEC.md"

# §138a (product): scripts/lint.sh exists AND is executable — the single lint
# predicate CI and developers both invoke. RED now: the file is absent.
if [ -f "$S138_LINT" ] && [ -x "$S138_LINT" ]; then
  ok "138a: scripts/lint.sh exists and is executable (#545)"
else
  ng "138a: scripts/lint.sh missing or not executable (#545)"
fi

# §138b (product, bounded-memory structural lock): lint.sh invokes shellcheck inside a
# per-file loop (single-file loop var `"$f"`) and NEVER as a combined multi-file
# expansion (`"${files[@]}"` or a `*.sh` glob) — the #543/#539 memory-cliff guard.
# Anti-vacuity: require the POSITIVE per-file anchor (count ≥1), not merely the absence
# of the combined form. RED now: file absent ⇒ per-file anchor count 0.
s138b_perfile=$(grep -cE 'shellcheck[^#]*"\$f"' "$S138_LINT" 2>/dev/null)
s138b_combined=$(grep -cE 'shellcheck[^#]*("\$\{files\[@\]\}"|\*\.sh)' "$S138_LINT" 2>/dev/null)
if [ "${s138b_perfile:-0}" -ge 1 ] && [ "${s138b_combined:-0}" -eq 0 ]; then
  ok "138b: lint.sh runs shellcheck per file (\"\$f\") with no combined multi-file expansion (#545)"
else
  ng "138b: lint.sh missing per-file shellcheck loop or still uses a combined \"\${files[@]}\"/glob pass (#545)"
fi

# §138c (product): version pin + fail-closed SHA256 verification present in lint.sh —
# a pinned-version anchor (GHJIG_SHELLCHECK_VERSION) AND a checksum anchor (sha256/
# shasum) AND a fail-closed anchor (exit/error on mismatch). RED now: file absent.
if grep -qF 'GHJIG_SHELLCHECK_VERSION' "$S138_LINT" 2>/dev/null \
   && grep -qiE 'sha256|shasum|sha256sum' "$S138_LINT" 2>/dev/null \
   && grep -qiE 'exit 1|mismatch|does not match' "$S138_LINT" 2>/dev/null; then
  ok "138c: lint.sh pins shellcheck version and SHA256-verifies it fail-closed (#545)"
else
  ng "138c: lint.sh missing version pin (GHJIG_SHELLCHECK_VERSION) or fail-closed SHA256 verification (#545)"
fi

# §138d (product): Linux peak-RSS memory flag present — the per-file pass measured
# under `/usr/bin/time -v` so an approaching-limit regression surfaces legibly. RED
# now: file absent.
if grep -qF '/usr/bin/time' "$S138_LINT" 2>/dev/null; then
  ok "138d: lint.sh measures peak RSS via /usr/bin/time on Linux (#545)"
else
  ng "138d: lint.sh missing /usr/bin/time peak-RSS memory guard (#545)"
fi

# §138e (product, parity structural lock): ci.yml `syntax` job invokes ./scripts/lint.sh
# AND no longer carries the unpinned `apt-get install ... shellcheck` version source.
# Anti-vacuity: require the POSITIVE ./scripts/lint.sh anchor AND the absence of the old
# unpinned install. RED now: ci.yml still apt-installs shellcheck and has no lint.sh call.
s138e_aptshellcheck=$(grep -cE 'apt-get install.*shellcheck' "$S138_CI" 2>/dev/null)
if grep -qF './scripts/lint.sh' "$S138_CI" 2>/dev/null && [ "${s138e_aptshellcheck:-0}" -eq 0 ]; then
  ok "138e: ci.yml syntax job runs ./scripts/lint.sh with no unpinned apt-get shellcheck install (#545)"
else
  ng "138e: ci.yml missing ./scripts/lint.sh call or still apt-get installs unpinned shellcheck (#545)"
fi

# §138f (Doc-phase-confirming — expected GREEN): SPEC §11 references scripts/lint.sh AND
# the version-pinned contract. The Doc commit landed, so this greens now.
if grep -qF 'scripts/lint.sh' "$S138_SPEC" 2>/dev/null \
   && grep -qiE 'pinned|version-pinned' "$S138_SPEC" 2>/dev/null; then
  ok "138f: SPEC §11 documents scripts/lint.sh as version-pinned (#545)"
else
  ng "138f: SPEC §11 missing scripts/lint.sh reference or version-pinned wording (#545)"
fi

# ---------- §139: readability / language-idiom quality axis (#546) ----------
# SPEC §4.5.1 + .claude/rubrics/bash.md. Senior-engineering quality has two axes:
# correctness (shellcheck/tests/reviewer, already covered) and the readability /
# language-idiom axis ("is the bash written the way bash wants to be written").
# The axis is carried as a per-language rubric SSOT, applied by code-reviewer as
# ADVISORY idiom-notes that never escalate to block, with a deterministic subset
# surfaced by a born-advisory checker scripts/lint_bash_idioms.sh.
#
# Doc landed (Phase A): (a)-(e) are product/Doc-confirming and green now. The
# deterministic checker DOES NOT EXIST YET (Phase B/Test): (f) is the load-bearing
# intended-RED — it fails until scripts/lint_bash_idioms.sh lands in Phase C.
S139_RUBRIC="$SHELL_ROOT/.claude/rubrics/bash.md"
S139_CODE_REV="$SHELL_ROOT/.claude/agents/code-reviewer.md"
S139_SPEC="$SHELL_ROOT/SPEC.md"
S139_MISSION="$SHELL_ROOT/MISSION.md"
S139_CHECKER="$SHELL_ROOT/scripts/lint_bash_idioms.sh"
S139_FX_BAD="$SHELL_ROOT/scripts/test/fixtures/idiom/bash/unidiomatic.sh"
S139_FX_GOOD="$SHELL_ROOT/scripts/test/fixtures/idiom/bash/idiomatic.sh"

# §139a (AC2): the bash idiom rubric SSOT exists AND carries each required criterion
# token — the deterministic set (safe_source, git add -A) and the LLM set (function
# altitude, DRY), plus the motivating SMELL and the #276/#490 reuse scope note. The
# `safe_source` criterion heading carries backticks, so match that literal form.
if [ -f "$S139_RUBRIC" ] \
   && grep -qF '`safe_source` discipline' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF 'git add -A' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF 'Function size / altitude' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF 'DRY across helpers' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF 'SMELL: detection-by-attribute-combination' "$S139_RUBRIC" 2>/dev/null \
   && grep -qF "Reuse, don't re-handroll" "$S139_RUBRIC" 2>/dev/null; then
  ok "139a: .claude/rubrics/bash.md carries all required idiom criteria + SMELL + reuse note (#546)"
else
  ng "139a: .claude/rubrics/bash.md missing or lacks a required criterion / SMELL / reuse token (#546)"
fi

# §139b: code-reviewer.md wires the advisory axis — an Idiom notes (advisory) output
# section, the never-block rule (NEVER escalate to block), and the conditional per-
# language rubric read (.claude/rubrics/). All three are the wiring, not the criteria.
if grep -qF 'Idiom notes (advisory)' "$S139_CODE_REV" 2>/dev/null \
   && grep -qF 'NEVER escalate to' "$S139_CODE_REV" 2>/dev/null \
   && grep -qF '.claude/rubrics/' "$S139_CODE_REV" 2>/dev/null; then
  ok "139b: code-reviewer.md wires advisory idiom axis (Idiom notes + never-block + rubric read) (#546)"
else
  ng "139b: code-reviewer.md missing Idiom notes section, never-block rule, or .claude/rubrics/ read (#546)"
fi

# §139c (NARROWING GUARD, invariant #1): the criteria text lives ONLY in the rubric
# file, NOT inlined into the always-loaded reviewer prompt (else the rubric SSOT is a
# second copy that drifts). code-reviewer.md must NOT carry the rubric BODY tokens.
s139c_smell=$(grep -cF 'SMELL: detection-by-attribute-combination' "$S139_CODE_REV" 2>/dev/null)
s139c_norm=$(grep -cF 'normalize once' "$S139_CODE_REV" 2>/dev/null)
if [ "${s139c_smell:-0}" -eq 0 ] && [ "${s139c_norm:-0}" -eq 0 ]; then
  ok "139c: code-reviewer.md does NOT inline the rubric body (criteria stay SSOT in bash.md) (#546)"
else
  ng "139c: code-reviewer.md inlines rubric-body criteria text — drift risk, criteria must stay in bash.md (#546)"
fi

# §139d (AC4): SPEC §4.5.1 subsection exists AND MISSION.md names the axis. Both are
# Doc-confirming (landed in Phase A), so green now.
if grep -qF '#### 4.5.1 Readability / language-idiom review axis' "$S139_SPEC" 2>/dev/null \
   && grep -qF 'readability / language-idiom axis' "$S139_MISSION" 2>/dev/null; then
  ok "139d: SPEC §4.5.1 + MISSION.md carry the readability / language-idiom axis (#546)"
else
  ng "139d: SPEC §4.5.1 subsection or MISSION.md language-idiom-axis sentence missing (#546)"
fi

# §139e (B2 ANTI-VACUITY LOCK): the motivating-smell worked example is structurally
# explicit, not degraded to a bare mention. Require ALL THREE: the exemplar
# (Unidiomatic (but correct)), the discriminator-fix (branch on the discriminator OR
# normalize once), and the correct-but-unidiomatic property (The unidiomatic form is).
if grep -qF 'Unidiomatic (but correct)' "$S139_RUBRIC" 2>/dev/null \
   && { grep -qF 'branch on the explicit discriminator' "$S139_RUBRIC" 2>/dev/null \
        || grep -qF 'normalize once' "$S139_RUBRIC" 2>/dev/null; } \
   && grep -qF 'The unidiomatic form is' "$S139_RUBRIC" 2>/dev/null; then
  ok "139e: bash.md worked example is structurally explicit (exemplar + fix + correct-but-unidiomatic) (#546)"
else
  ng "139e: bash.md worked example degraded — missing exemplar, discriminator-fix, or correctness note (#546)"
fi

# §139f (CHECKER DEMONSTRATION, AC3 — LOAD-BEARING intended-RED): the born-advisory
# deterministic checker flags unidiomatic.sh (emits findings) and clears idiomatic.sh
# (no findings). Both fixtures are shellcheck-warning-CLEAN, proving the idiom axis is
# distinct from the correctness axis. scripts/lint_bash_idioms.sh does not exist until
# Phase C, so this MUST fail now — the intended Phase-B red. Guarded so an absent
# checker (or absent fixture) fails CLEANLY as ng, never a hard error.
if [ ! -f "$S139_FX_BAD" ] || [ ! -f "$S139_FX_GOOD" ]; then
  ng "139f: idiom fixtures missing (unidiomatic.sh / idiomatic.sh) — cannot demonstrate checker (#546)"
elif [ ! -f "$S139_CHECKER" ]; then
  ng "139f: scripts/lint_bash_idioms.sh absent — deterministic idiom checker not yet implemented (#546 Phase C)"
else
  s139f_bad_out="$(bash "$S139_CHECKER" "$S139_FX_BAD" 2>/dev/null)"
  s139f_good_out="$(bash "$S139_CHECKER" "$S139_FX_GOOD" 2>/dev/null)"
  if [ -n "$s139f_bad_out" ] && [ -z "$s139f_good_out" ]; then
    ok "139f: lint_bash_idioms.sh flags unidiomatic.sh and clears idiomatic.sh (#546)"
  else
    ng "139f: lint_bash_idioms.sh did not flag unidiomatic.sh or wrongly flagged idiomatic.sh (#546)"
  fi
fi
# ---------- §140: merge-completeness advisory warn (#548) ----------
# SPEC §6.1 'merge-completeness' advisory row — the POSITIVE completeness face of
# the #544 merge-attestation block (origin: handol #244, an implementation commit
# never pushed so only the Phase-B test reached the head → the merge would land a
# test with no code). An INDEPENDENT advisory arm sequenced AFTER the merge-
# attestation arm on the same `gh pr merge` entry-grep. On a `feat`/`fix` PR whose
# merge diff touches ZERO source files (non-empty file list, every path test/doc)
# it emits `audit_log warn merge-completeness` + a one-line stderr notice and
# ALLOWS (rc 0) — it NEVER blocks. PR type resolves from the PR headRefName
# (`<user>/(feat|fix)/…`) with a PR-title conventional-commit fallback. Source-vs-
# test/doc REUSES the `.shellsecretignore` allow-list via secret_scan_path_allowed
# (no new glob list). One bounded `gh pr view <pr> --json headRefName,title,files`
# feeds both type + file list. Fail-open throughout (gh down / empty list → no warn).
#
# The arm DOES NOT EXIST YET (Phase B / Doc→Test→Code). Assertion (a) is the load-
# bearing INTENDED RED: it observes rc 0 (the merge falls through to allow) but NO
# merge-completeness warn record (the absent arm never writes one) → RED. (b)/(c)/(d)
# hold trivially now (no arm ⇒ no warn) and stay green when Phase C lands the arm.
#
# To REACH the completeness arm, the merge-review arm above must ALLOW first. The
# completeness arm must run even in the gh-DOWN §140d case, where merge-review
# would FAIL CLOSED (#586) — so the repo carries `.claude/state/review-gate=bypass`
# (cwd-relative, resolve_review_gate reads it), which skips merge-review with a
# loud `merge-review bypass` audit and NO gh calls, regardless of gh being down.
# That bypass record is category=merge-review, orthogonal to the merge-completeness
# category the assertions below key on. The repo carries a committed
# `.shellsecretignore` (copied from SHELL_ROOT) at HEAD so the arm's
# secret_scan_path_allowed classifier loads the real test/doc/example globs; it has
# NO upstream so push-parity always allows; ac-closeout allows (empty closingIssues).
S140_DIR=$(mktemp -d)
S140_SHIM="$S140_DIR/bin"
S140_STATE="$S140_DIR/ghstate"   # GH_SHIM_STATE for the gh shim
mkdir -p "$S140_SHIM" "$S140_STATE"

S140_HEAD='mc-head-999'
printf '%s\n' "$S140_HEAD" > "$S140_STATE/head_ref_oid"  # merge-attestation staleness match
printf '77\n' > "$S140_STATE/pr_number"

# gh shim (mirrors §137): a forced-DOWN toggle (touch $GH_SHIM_STATE/gh_down) makes
# every gh call error. headRefOid feeds merge-attestation; closingIssuesReferences
# empty → ac-closeout allows; the NEW `--json headRefName,title,files` call (matched
# by the *files* arm) returns the per-case canned PR JSON object driving the
# completeness arm's type + file-list.
cat > "$S140_SHIM/gh" <<'SHIM'
#!/bin/sh
if [ -f "$GH_SHIM_STATE/gh_down" ]; then
  echo "gh: shim forced down (no network)" >&2
  exit 1
fi
case "$*" in
  *"pr view"*headRefOid*)              cat "$GH_SHIM_STATE/head_ref_oid" 2>/dev/null ;;
  *"pr view"*closingIssuesReferences*) : ;;   # empty → ac-closeout allows
  *"pr view"*files*)                   cat "$GH_SHIM_STATE/pr_view_json" 2>/dev/null ;;
  *"pr view"*number*)                  cat "$GH_SHIM_STATE/pr_number" 2>/dev/null ;;
esac
exit 0
SHIM
chmod +x "$S140_SHIM/gh"

# Throwaway repo with a committed `.shellsecretignore` at HEAD + no upstream. Built
# once; every case runs `gh pr merge 77 --merge` here. Mirrors the §137 build idiom.
s140_repo=$(
  d=$(mktemp -d); work="$d/work"
  git init -q "$work" 2>/dev/null
  (
    cd "$work" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    git checkout -q -b smoke/feat/1-completeness 2>/dev/null || true
    mkdir -p .claude/state
    printf 'bypass\n' > .claude/state/review-gate   # #586: bypass merge-review (survives gh-down §140d)
    cp "$SHELL_ROOT/.shellsecretignore" .shellsecretignore
    git add .shellsecretignore
    git commit -q -m c1
  )
  printf '%s' "$work"
)
S140_CANON=$(cd "$s140_repo" && pwd -P)

# Run `gh pr merge 77 --merge` in the repo with a per-case gh-JSON + state-dir
# override (carrying a VALID pr-77 attestation + its own audit log + registry).
# Sets S140_RC and S140_TAIL (the audit records this fire appended).
s140_case() {
  local pr_json="$1" statedir="$2" before after
  mkdir -p "$statedir/audit"
  printf '%s\n' "$S140_CANON" > "$statedir/registry.txt"       # in_scope under the override
  printf '%s' "$pr_json" > "$S140_STATE/pr_view_json"
  before=$(wc -l < "$statedir/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
  (
    cd "$s140_repo" || exit 1
    # shellcheck disable=SC2069  # intentional: capture stderr, discard stdout
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' 'gh pr merge 77 --merge' | jq -Rs .)" \
      | PATH="$S140_SHIM:$PATH" \
        GH_SHIM_STATE="$S140_STATE" \
        GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        GHJIG_STATE_DIR_OVERRIDE="$statedir" \
        bash "$HOOK" >/dev/null 2>&1
  )
  S140_RC=$?
  after=$(wc -l < "$statedir/audit/audit.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
  S140_TAIL=""
  [ "$(( after - before ))" -gt 0 ] && S140_TAIL=$(tail -"$(( after - before ))" "$statedir/audit/audit.jsonl" 2>/dev/null)
}

# §140a (LOAD-BEARING INTENDED RED): feat PR + a merge diff that is ALL test/doc
# (README.md matches `*.md`; tests/foo.py matches `tests/`) → the arm should emit a
# merge-completeness warn and ALLOW. RED now: the arm is absent ⇒ rc 0 but NO warn
# record ⇒ the `warn present` conjunct fails ⇒ clean ng (not a hard error).
s140_case '{"headRefName":"ilgyu-yi/feat/99-x","title":"feat(#99): x","files":[{"path":"README.md"},{"path":"tests/foo.py"}]}' "$S140_DIR/a"
if [ "$S140_RC" = 0 ] && printf '%s' "$S140_TAIL" | grep -q '"category":"merge-completeness"'; then
  ok "140a: feat PR whose merge diff is all test/doc → merge-completeness advisory warn + allow (#548)"
else
  ng "140a: feat/all-test-doc merge should WARN + allow (rc=$S140_RC; arm absent ⇒ no merge-completeness warn ⇒ RED) tail=$S140_TAIL (#548)"
fi

# §140b: feat PR whose diff TOUCHES SOURCE (scripts/lint.sh is not allow-listed) →
# no warn, allow. Passes now (no arm ⇒ no warn) and stays green after Phase C.
s140_case '{"headRefName":"ilgyu-yi/feat/99-x","title":"feat(#99): x","files":[{"path":"scripts/lint.sh"}]}' "$S140_DIR/b"
if [ "$S140_RC" = 0 ] && ! printf '%s' "$S140_TAIL" | grep -q '"category":"merge-completeness"'; then
  ok "140b: feat PR touching a source file → no merge-completeness warn, allow (#548)"
else
  ng "140b: feat+source merge must NOT warn (rc=$S140_RC) tail=$S140_TAIL (#548)"
fi

# §140c: NON-feat/fix type (chore branch + chore title) + all-test/doc files → no
# warn, allow (type gate). Passes now and stays green after Phase C.
s140_case '{"headRefName":"ilgyu-yi/chore/99-x","title":"chore: x","files":[{"path":"README.md"},{"path":"tests/foo.py"}]}' "$S140_DIR/c"
if [ "$S140_RC" = 0 ] && ! printf '%s' "$S140_TAIL" | grep -q '"category":"merge-completeness"'; then
  ok "140c: non-feat/fix type + all-test/doc files → no merge-completeness warn, allow (#548)"
else
  ng "140c: chore-type merge must NOT warn (rc=$S140_RC) tail=$S140_TAIL (#548)"
fi

# §140d (FAIL-OPEN): gh forced DOWN on a feat branch → the completeness arm cannot
# fetch its file list → no warn, never a block (rc 0). (merge-attestation also fail-
# opens here — attest file present + gh down — so rc stays 0.) The grep excludes the
# merge-attestation fail-open-skip warn by pinning the category. Green now + after.
touch "$S140_STATE/gh_down"
s140_case '{"headRefName":"ilgyu-yi/feat/99-x","title":"feat(#99): x","files":[{"path":"README.md"}]}' "$S140_DIR/d"
rm -f "$S140_STATE/gh_down"
if [ "$S140_RC" = 0 ] && ! printf '%s' "$S140_TAIL" | grep -q '"category":"merge-completeness"'; then
  ok "140d: gh down (fail-open) → no merge-completeness warn, never blocks (rc 0) (#548)"
else
  ng "140d: gh-down fail-open must allow with no merge-completeness warn (rc=$S140_RC) tail=$S140_TAIL (#548)"
fi

rm -rf "$S140_DIR" "$(dirname "$s140_repo")"
# ---------- 141. one-body phase-split guard (#579) ----------
# Pins the #579 contract: a multi-phase change (Doc/Test/Code) is ONE Execution
# Issue whose phases are *commits*, not three separate issues; the issue-reviewer
# gains an ADVISORY phase-slice Check 6 that flags the split-across-issues
# anti-pattern but NEVER escalates to block (the ship/refine/block grammar is
# unchanged). Structural content-lock (mirrors §132): assert the presence of the
# CHECK and its KEY CONCEPTS via a small set of STABLE tokens, NOT the full literal
# exemplar prose (which will churn). Anti-vacuity: the SPEC lock (141e) requires the
# observable-discriminator AND the never-block clause together on the Phase-slice
# bullet, so a bare mention cannot green it.
#
# 141a was RED before Phase C (issue-reviewer.md Check 6) landed — the intended
# Phase-B failure — and is GREEN once Check 6 is in place. 141b-e are
# Doc-phase-confirming (SPEC §1.2 / §4.7), expected GREEN throughout.
S141_REVIEWER="$SHELL_ROOT/.claude/agents/issue-reviewer.md"
S141_SPEC="$SHELL_ROOT/SPEC.md"

# §141a (LOAD-BEARING INTENDED RED — Phase C target): issue-reviewer.md carries the
# advisory phase-slice Check 6. Stable-token structural lock: a phase-slice token AND
# an advisory-never-block token AND a doc-deliverable/ADR negative concept (terminal
# artifact / ADR) AND a dir-mode Directive distinction token. The load-bearing RED
# drivers are `phase-slice` and `terminal artifact`/`ADR` (both count 0 in the file
# today); the file already carries `Directive` (open-issues fetch line) so that arm
# alone is not distinctive — the AND makes 141a red cleanly until Phase C adds Check 6.
if [ -f "$S141_REVIEWER" ]; then
  if grep -qiE 'phase.slice' "$S141_REVIEWER" \
     && grep -qiE 'advisory|never[^.]*block' "$S141_REVIEWER" \
     && grep -qiE 'terminal artifact|\bADR\b' "$S141_REVIEWER" \
     && grep -qiF 'Directive' "$S141_REVIEWER"; then
    ok "141a: issue-reviewer.md carries the advisory phase-slice Check 6 (phase-slice + never-block + ADR/terminal-artifact negative + Directive distinction) (#579)"
  else
    ng "141a: issue-reviewer.md missing phase-slice Check 6 (expected RED until Phase C: needs phase-slice + advisory-never-block + ADR/terminal-artifact negative + Directive distinction) (#579)"
  fi
else
  ng "141a: issue-reviewer.md file missing (#579)"
fi

# §141b (Doc-confirming, expected GREEN): SPEC §4.7 carries the Phase-slice Check 6
# with the advisory-never-block clause. Line-scoped to the Phase-slice bullet so the
# advisory/never/block tokens must co-occur on the check itself, not scattered.
if [ -f "$S141_SPEC" ]; then
  s141b=$(grep 'Phase-slice' "$S141_SPEC")
  if [ -n "$s141b" ] \
     && printf '%s' "$s141b" | grep -qi 'advisory' \
     && printf '%s' "$s141b" | grep -qi 'never' \
     && printf '%s' "$s141b" | grep -qiF 'block'; then
    ok "141b: SPEC §4.7 Phase-slice Check 6 is advisory and never blocks (#579)"
  else
    ng "141b: SPEC §4.7 missing Phase-slice Check 6 advisory-never-block clause (#579)"
  fi
else
  ng "141b: SPEC.md file missing (#579)"
fi

# §141c (Doc-confirming, expected GREEN): SPEC §1.2 carries the Issue-level corollary
# anchor AND the 1:N carve-out phrasing (constrains issue granularity, NOT PR count;
# issue→PR is 1:N) — so the corollary can't silently drift back to "one PR". Line-scoped.
if [ -f "$S141_SPEC" ]; then
  s141c=$(grep 'Issue-level corollary' "$S141_SPEC")
  if [ -n "$s141c" ] \
     && printf '%s' "$s141c" | grep -qi 'constrains' \
     && printf '%s' "$s141c" | grep -qiF 'PR count' \
     && printf '%s' "$s141c" | grep -qF '1:N'; then
    ok "141c: SPEC §1.2 Issue-level corollary pins the 1:N issue-vs-PR carve-out (#579)"
  else
    ng "141c: SPEC §1.2 missing Issue-level corollary anchor or 1:N carve-out phrasing (#579)"
  fi
else
  ng "141c: SPEC.md file missing (#579)"
fi

# §141d (invariant — verdict grammar unchanged): issue-reviewer.md still emits EXACTLY
# ship/refine/block — the advisory Check 6 added no new verdict token. Assert the three
# canonical verdicts present AND zero non-canonical `VERDICT: <word>` tokens. Passes now
# and must still pass after Phase C.
if [ -f "$S141_REVIEWER" ]; then
  s141d_extra=$(grep -oE 'VERDICT: [a-z]+' "$S141_REVIEWER" | grep -vE 'VERDICT: (ship|refine|block)' | wc -l | tr -d ' ')
  if grep -qF 'VERDICT: ship' "$S141_REVIEWER" \
     && grep -qF 'VERDICT: refine' "$S141_REVIEWER" \
     && grep -qF 'VERDICT: block' "$S141_REVIEWER" \
     && [ "${s141d_extra:-1}" -eq 0 ]; then
    ok "141d: issue-reviewer.md verdict grammar is exactly ship/refine/block — no new verdict (#579)"
  else
    ng "141d: issue-reviewer.md verdict grammar changed — expected exactly ship/refine/block (#579)"
  fi
else
  ng "141d: issue-reviewer.md file missing (#579)"
fi

# §141e (anti-vacuity, expected GREEN): the SPEC §4.7 Phase-slice bullet is not a bare
# mention — it must carry the observable-discriminator concept (open-issues sibling /
# body-defers) AND the never-block clause together on the same bullet. Line-scoped.
if [ -f "$S141_SPEC" ]; then
  s141e=$(grep 'Phase-slice' "$S141_SPEC")
  if [ -n "$s141e" ] \
     && printf '%s' "$s141e" | grep -qiF 'open-issues' \
     && printf '%s' "$s141e" | grep -qiE 'body itself deferring|body-defers|deferring a sibling' \
     && printf '%s' "$s141e" | grep -qi 'never'; then
    ok "141e: SPEC §4.7 Phase-slice bullet pairs the observable discriminator with the never-block clause (#579)"
  else
    ng "141e: SPEC §4.7 Phase-slice bullet missing observable-discriminator (open-issues/body-defers) or never-block clause (#579)"
  fi
else
  ng "141e: SPEC.md file missing (#579)"
fi

# ---------- §143: /file-review producer command content-lock (#585) ----------
# SPEC §5.29 + .claude/commands/file-review.md. `/file-review <pr>` is the verdict-
# materializer — runs code-reviewer on a PR and posts its verdict as a first-class,
# commit_id-pinned GitHub review. It is producer-only (adds/changes/removes NO merge
# gate — that is #586); this content-lock pins the #586 INTEGRATION CONTRACT so it
# cannot drift: the exact machine-readable marker token, the commit_id-pinned REST
# submission (NOT `gh pr review`, which cannot pin a commit — the §4.5 head-pin
# failure), the temp-file body transport with @mention neutralization, ownership
# resolution, <pr> validation, the file-review audit category, and the unconfirmed-
# head → post-nothing fail-closed arm.
#
# Doc landed (Phase A): (i)/(j) are SPEC-confirming and GREEN now. The command file
# DOES NOT EXIST YET (Phase C authors it): (a)-(h) are the load-bearing intended-RED
# — they fail until .claude/commands/file-review.md lands. Each command-file arm
# guards on `[ -f "$S143_CMD" ]` first, so an absent file fails CLEANLY as ng (an
# absence sub-check can never vacuously pass on a missing file).
S143_CMD="$SHELL_ROOT/.claude/commands/file-review.md"
S143_SPEC="$SHELL_ROOT/SPEC.md"

# §143a (INTEGRATION CONTRACT, #586 — LOAD-BEARING RED): the machine-readable marker
# carries the byte-identical token substrings from SPEC §5.29 —
# `<!-- file-review verdict=`, `head=`, and the engine field `reviewer=code-reviewer`.
# #586 binds these to the GitHub-attested review object, so the spelling is a hard
# contract, not free text.
if [ -f "$S143_CMD" ] \
   && grep -qF '<!-- file-review verdict=' "$S143_CMD" 2>/dev/null \
   && grep -qF 'head=' "$S143_CMD" 2>/dev/null \
   && grep -qF 'reviewer=code-reviewer' "$S143_CMD" 2>/dev/null; then
  ok "143a: file-review.md carries the exact marker token (verdict= + head= + reviewer=code-reviewer) (#585)"
else
  ng "143a: file-review.md missing or lacks the exact #586 marker token substrings (#585)"
fi

# §143b (COMMIT_ID PIN — LOAD-BEARING RED): the review is submitted commit_id-pinned
# via REST (`commit_id=` bound + the `pulls/…/reviews` endpoint) AND the plain
# `gh pr review --approve` CLI — which CANNOT pin a commit and would rebind an
# approval to a racing head — is ABSENT as a submission mechanism.
if [ -f "$S143_CMD" ] \
   && grep -qF 'commit_id=' "$S143_CMD" 2>/dev/null \
   && grep -qF 'pulls/' "$S143_CMD" 2>/dev/null \
   && ! grep -qF 'gh pr review --approve' "$S143_CMD" 2>/dev/null; then
  ok "143b: file-review.md pins commit_id via REST (pulls/…/reviews) and never uses gh pr review --approve (#585)"
else
  ng "143b: file-review.md missing commit_id/pulls REST pin, or uses the un-pinnable gh pr review --approve (#585)"
fi

# §143c (BODY TRANSPORT — LOAD-BEARING RED): the reviewer body goes through a written
# temp file (`body=@<file>`) — the activate.md/reflect.md --body-file idiom — and the
# untrusted reviewer text is NEVER interpolated via an inline `--body "` shell arg
# (an injection vector).
if [ -f "$S143_CMD" ] \
   && grep -qF 'body=@' "$S143_CMD" 2>/dev/null \
   && ! grep -qF -- '--body "' "$S143_CMD" 2>/dev/null; then
  ok "143c: file-review.md transports the body via body=@<tempfile>, never inline --body \" (#585)"
else
  ng "143c: file-review.md missing body=@ temp-file transport, or inline-interpolates via --body \" (#585)"
fi

# §143d (INJECTION DEFENSE — LOAD-BEARING RED): whole-body `@mention` neutralization
# is present — the same sanitize idiom SPEC §5.29 and activate.md name, so the posted
# review cannot mass-ping.
if [ -f "$S143_CMD" ] \
   && grep -qF '@mention' "$S143_CMD" 2>/dev/null; then
  ok "143d: file-review.md neutralizes @mention in the review body (#585)"
else
  ng "143d: file-review.md missing @mention neutralization (mass-ping injection defense) (#585)"
fi

# §143e (OWNERSHIP — LOAD-BEARING RED): ownership branching resolves the acting
# identity (`gh api user`) and the PR author (`--json author`) to pick native-review
# vs own-PR COMMENT (GitHub 422s a self approve/request-changes).
if [ -f "$S143_CMD" ] \
   && grep -qF 'gh api user' "$S143_CMD" 2>/dev/null \
   && grep -qF -- '--json author' "$S143_CMD" 2>/dev/null; then
  ok "143e: file-review.md resolves ownership via gh api user + --json author (#585)"
else
  ng "143e: file-review.md missing gh api user / --json author ownership resolution (#585)"
fi

# §143f (INPUT VALIDATION — LOAD-BEARING RED): `<pr>` is validated (the `^[0-9]+$`
# numeric form) before use — untrusted argument handling.
if [ -f "$S143_CMD" ] \
   && grep -qF '^[0-9]+$' "$S143_CMD" 2>/dev/null; then
  ok "143f: file-review.md validates <pr> against ^[0-9]+\$ before use (#585)"
else
  ng "143f: file-review.md missing the <pr> ^[0-9]+\$ validation token (#585)"
fi

# §143g (AUDIT — LOAD-BEARING RED): the command audits under the `file-review`
# category (the SPEC §5.29 decision trail: posted / invalid / aborted).
if [ -f "$S143_CMD" ] \
   && grep -qF 'audit_log' "$S143_CMD" 2>/dev/null \
   && grep -qF 'file-review' "$S143_CMD" 2>/dev/null; then
  ok "143g: file-review.md audits under the file-review category (#585)"
else
  ng "143g: file-review.md missing audit_log under the file-review category (#585)"
fi

# §143h (FAIL-CLOSED-TO-SILENCE — LOAD-BEARING RED): the unconfirmed / unresolvable
# head arm posts NOTHING and audits `invalid` — it never posts an unearned block on
# a head it could not blind-compare to the private PR head (SPEC §5.29 map row).
if [ -f "$S143_CMD" ] \
   && grep -qiF 'post nothing' "$S143_CMD" 2>/dev/null \
   && grep -qF 'invalid' "$S143_CMD" 2>/dev/null; then
  ok "143h: file-review.md fails closed on an unconfirmed head — post nothing + audit invalid (#585)"
else
  ng "143h: file-review.md missing the unconfirmed-head → post-nothing/invalid fail-closed arm (#585)"
fi

# §143i (Doc-confirming, expected GREEN): SPEC §5.29 section header exists.
if [ -f "$S143_SPEC" ] \
   && grep -qF '### 5.29' "$S143_SPEC" 2>/dev/null; then
  ok "143i: SPEC §5.29 /file-review section header present (#585)"
else
  ng "143i: SPEC §5.29 section header missing (#585)"
fi

# §143j (Doc-confirming, expected GREEN): the SAME exact marker token appears in SPEC
# §5.29 — the source of the §143a byte-identical contract (drift lock, both copies).
if [ -f "$S143_SPEC" ] \
   && grep -qF '<!-- file-review verdict=' "$S143_SPEC" 2>/dev/null; then
  ok "143j: SPEC §5.29 documents the exact file-review marker token (#585)"
else
  ng "143j: SPEC §5.29 missing the file-review marker token (#585)"
fi

# ---------- §144: auto-mode-classifier permissions.allow exception + /ship coupling (#587) ----------
# SPEC §5.7.1 "Composition with the auto-mode classifier" + .claude/settings.json
# permissions.allow + .claude/commands/ship.md step 10. #587 defers the auto-mode
# classifier for EXACTLY the /ship clean-merge form via a narrow, order-sensitive
# permissions.allow matcher — no trailing wildcard — so the classifier hands that one
# command to the shell's own merge-review gate (#586). The deferral is sound ONLY while
# review-gate=required; under bypass /ship must WITHHOLD the covered form so the
# classifier re-engages (Directive #584 Constraint 1: no naked self-merge hole).
#
# Phase status: the SPEC clause landed in Phase A (144k/144l GREEN now). Phase C of
# #591 propagates the exact matcher into settings.injected.json (144e intended-RED now
# — the entry is absent until Phase C adds it). The #587 settings.json + ship.md
# entries already landed (144a/144b/144f, 144h/144i/144j GREEN now). The
# narrowness/drift guards (144c/144d/144g) stay green — they lock the "opens nothing
# else" contract.
S144_SET="$SHELL_ROOT/.claude/settings.json"
S144_INJ="$SHELL_ROOT/.claude/settings.injected.json"
S144_SHIP="$SHELL_ROOT/.claude/commands/ship.md"
S144_SPEC="$SHELL_ROOT/SPEC.md"
# The one canonical merge literal, defined ONCE — both the settings.json matcher inner
# command and the ship.md step-10 emitted string must equal it byte-for-byte (§144f).
S144_CANON='gh pr merge --auto --merge --delete-branch'
# Step-10 block, scoped from the `10.` marker to `10.5.` — so tokens that already live
# in step 7.8 (/file-review, bypass) do NOT leak into the step-10 content-locks.
S144_STEP10=$(sed -n '/^10\. If mode is/,/^10\.5\./p' "$S144_SHIP" 2>/dev/null || true)

# §144a (LOAD-BEARING RED): settings.json carries the EXACT matcher, spelled byte-for-byte.
if [ -f "$S144_SET" ] && grep -qF "Bash($S144_CANON)" "$S144_SET" 2>/dev/null; then
  ok "144a: settings.json permissions.allow carries the exact matcher Bash($S144_CANON) (#587)"
else
  ng "144a: settings.json missing the exact permissions.allow matcher Bash($S144_CANON) (#587)"
fi

# §144b (LOAD-BEARING RED — presence + narrowness fused): the ONLY gh-pr-merge allow
# rule is that exact narrow form. Any broad shape (Bash(gh pr merge:*), Bash(gh pr
# merge *), bare Bash(gh pr merge)) matches the `Bash(gh pr merge` prefix but NOT the
# exact literal, so any!=exact fails — a non-vacuous both-directions lock.
if [ -f "$S144_SET" ]; then
  s144_any=$(grep -cF 'Bash(gh pr merge' "$S144_SET" 2>/dev/null || true)
  s144_exact=$(grep -cF "Bash($S144_CANON)" "$S144_SET" 2>/dev/null || true)
else
  s144_any=-1; s144_exact=-1
fi
if [ "$s144_exact" -ge 1 ] && [ "$s144_any" = "$s144_exact" ]; then
  ok "144b: the only gh-pr-merge allow rule is the exact narrow form — no broad/bare allow (any=$s144_any exact=$s144_exact) (#587)"
else
  ng "144b: settings.json must carry exactly the narrow matcher and NO broad gh-pr-merge allow (any=$s144_any exact=$s144_exact) (#587)"
fi

# §144c (narrowness guard, GREEN now / stays green): autoMode.classifyAllShell is NOT
# forced true — that would route ALL shell through the classifier and defeat the narrow
# allow. Guarded on file presence so an absent file fails as ng, not vacuously.
if [ -f "$S144_SET" ] && ! grep -qE '"classifyAllShell"[[:space:]]*:[[:space:]]*true' "$S144_SET" 2>/dev/null; then
  ok "144c: settings.json does not set autoMode.classifyAllShell=true (#587)"
else
  ng "144c: settings.json must not set autoMode.classifyAllShell=true (#587)"
fi

# §144d (narrowness guard, GREEN now / stays green): no permissions.deny entry matches
# gh-pr-merge — a deny would override the allow (deny > allow) and re-block the merge.
# jq-scoped to the deny array so a `gh` mention elsewhere cannot false-trip; jq also
# validates that settings.json is well-formed JSON.
if [ -f "$S144_SET" ]; then
  s144_deny=$(jq -r '[.permissions.deny // [] | .[] | select(test("gh pr merge"))] | length' "$S144_SET" 2>/dev/null || echo err)
else
  s144_deny=err
fi
if [ "$s144_deny" = "0" ]; then
  ok "144d: no permissions.deny entry overrides the gh-pr-merge allow (deny-matches=$s144_deny) (#587)"
else
  ng "144d: a permissions.deny entry matches gh-pr-merge (or settings.json is not valid JSON) (deny-matches=$s144_deny) (#587)"
fi

# §144e (LOAD-BEARING RED — cross-target propagation, presence + narrowness fused):
# #591 inverts the former dogfood-only invariant — the permissions.allow exception IS
# now propagated to injected targets. settings.injected.json must carry the SAME exact
# narrow matcher and, with the SAME both-directions discipline as §144b, NO broad shape:
# any broad form (Bash(gh pr merge:*), Bash(gh pr merge *), bare Bash(gh pr merge)) hits
# the `Bash(gh pr merge` prefix but not the exact literal, so any!=exact fails.
if [ -f "$S144_INJ" ]; then
  s144e_any=$(grep -cF 'Bash(gh pr merge' "$S144_INJ" 2>/dev/null || true)
  s144e_exact=$(grep -cF "Bash($S144_CANON)" "$S144_INJ" 2>/dev/null || true)
else
  s144e_any=-1; s144e_exact=-1
fi
if [ "$s144e_exact" -ge 1 ] && [ "$s144e_any" = "$s144e_exact" ]; then
  ok "144e: settings.injected.json carries the exact narrow matcher Bash($S144_CANON) and NO broad gh-pr-merge allow — propagated to targets (any=$s144e_any exact=$s144e_exact) (#591)"
else
  ng "144e: settings.injected.json must carry exactly the narrow matcher Bash($S144_CANON) and NO broad gh-pr-merge allow — cross-target propagation (any=$s144e_any exact=$s144e_exact) (#591)"
fi

# §144f (CRITICAL — LOAD-BEARING RED): byte-for-byte coupling. The settings.json matcher
# inner command and the ship.md step-10 emitted string must BOTH equal the single
# canonical literal. A silent drift on either side → the emitted command misses the
# matcher → the classifier re-engages → a permanent unattended park. Naming which side
# is present pinpoints a future drift.
s144_set_has=0; s144_ship_has=0
[ -f "$S144_SET" ] && grep -qF "Bash($S144_CANON)" "$S144_SET" 2>/dev/null && s144_set_has=1
[ -f "$S144_SHIP" ] && grep -qF "$S144_CANON" "$S144_SHIP" 2>/dev/null && s144_ship_has=1
if [ "$s144_set_has" = 1 ] && [ "$s144_ship_has" = 1 ]; then
  ok "144f: /ship merge string is byte-identical to the matcher inner command '$S144_CANON' (set=$s144_set_has ship=$s144_ship_has) (#587)"
else
  ng "144f: byte-for-byte coupling broken — matcher-side=$s144_set_has ship-side=$s144_ship_has, both must carry '$S144_CANON' (#587)"
fi

# §144g (drift guard, GREEN now / stays green): the step-10 clean arm carries NO
# positional-PR / --repo / -R gh-pr-merge variant — any of those misses the exact
# matcher (fail-safe = classifier re-engages, never over-allow). Guarded on a non-empty
# step-10 block so a mis-scoped extraction fails as ng, not vacuously.
if [ -n "$S144_STEP10" ] \
   && ! printf '%s\n' "$S144_STEP10" | grep -qE 'gh pr merge[[:space:]]+[0-9]' \
   && ! printf '%s\n' "$S144_STEP10" | grep -qF 'gh pr merge --repo' \
   && ! printf '%s\n' "$S144_STEP10" | grep -qF 'gh pr merge -R'; then
  ok "144g: /ship step-10 uses no positional-PR/--repo gh-pr-merge variant that would miss the matcher (#587)"
else
  ng "144g: /ship step-10 must not carry a positional-PR/--repo gh-pr-merge variant (or step-10 block not found) (#587)"
fi

# §144h (LOAD-BEARING RED): the step-10 required arm posts the head-pinned review via
# /file-review and gates the merge on the exact hook predicate review_gate_accepts.
# Scoped to the step-10 block so the /file-review mention in step 7.8 does not satisfy it.
if [ -n "$S144_STEP10" ] \
   && printf '%s\n' "$S144_STEP10" | grep -qF '/file-review' \
   && printf '%s\n' "$S144_STEP10" | grep -qF 'review_gate_accepts'; then
  ok "144h: /ship step-10 required arm posts via /file-review and gates on review_gate_accepts (#587)"
else
  ng "144h: /ship step-10 required arm missing /file-review post + review_gate_accepts gate (#587)"
fi

# §144i (LOAD-BEARING RED): the required arm branches deterministically on the gate
# result — 0 → merge (the covered form), 1 → PARK with reason merge-review-unsatisfied
# (the plan-mandated distinctive reason token, handling verdict=block and posts-nothing
# uniformly; MEMORY never-forge-merge-gate-evidence).
if [ -n "$S144_STEP10" ] \
   && printf '%s\n' "$S144_STEP10" | grep -qF 'review_gate_accepts' \
   && printf '%s\n' "$S144_STEP10" | grep -qiF 'merge-review-unsatisfied'; then
  ok "144i: /ship step-10 required arm parks (merge-review-unsatisfied) when review_gate_accepts rejects (#587)"
else
  ng "144i: /ship step-10 required arm missing the review_gate_accepts reject → park (merge-review-unsatisfied) branch (#587)"
fi

# §144j (LOAD-BEARING RED — bypass coupling, invariant 4): under review-gate=bypass the
# step-10 arm READS the toggle (resolve_review_gate) and WITHHOLDS the covered form so
# the classifier re-engages → park. Locks `resolve_review_gate` + `re-engage`.
if [ -n "$S144_STEP10" ] \
   && printf '%s\n' "$S144_STEP10" | grep -qF 'resolve_review_gate' \
   && printf '%s\n' "$S144_STEP10" | grep -qiF 're-engage'; then
  ok "144j: /ship step-10 bypass arm reads resolve_review_gate and withholds the covered form → classifier re-engages → park (#587)"
else
  ng "144j: /ship step-10 bypass arm missing resolve_review_gate + classifier-re-engage coupling (#587)"
fi

# §144k (Doc-confirming, expected GREEN): SPEC §5.7.1 clause header present.
if [ -f "$S144_SPEC" ] && grep -qF 'Composition with the auto-mode classifier' "$S144_SPEC" 2>/dev/null; then
  ok "144k: SPEC §5.7.1 'Composition with the auto-mode classifier' clause present (#587)"
else
  ng "144k: SPEC §5.7.1 auto-mode-classifier clause missing (#587)"
fi

# §144l (Doc-confirming, expected GREEN): the load-bearing bypass-coupling paragraph is
# present — the honest-scope invariant that bypass is not a naked merge hole.
if [ -f "$S144_SPEC" ] && grep -qF 'Bypass coupling' "$S144_SPEC" 2>/dev/null; then
  ok "144l: SPEC §5.7.1 bypass-coupling paragraph present (#587)"
else
  ng "144l: SPEC §5.7.1 bypass-coupling paragraph missing (#587)"
fi

# ---------- §142: Python idiom / readability rubric content-lock (#581) ----------
# Mirrors §139 (the bash idiom rubric lock) for the new Python rubric SSOT. #581 is a
# Doc-ONLY addition: it lands ONE file, .claude/rubrics/python.md, applied by
# code-reviewer as ADVISORY idiom-notes (the same axis as bash.md, SPEC §4.5.1). There
# is NO Code phase — no Python deterministic checker (deferred until a bound Python repo
# needs it; python.md §"Deterministic-vs-LLM boundary" records the deferral). So this is
# a DRIFT-GUARD that is GREEN on arrival (python.md landed in Phase A), not a red-first
# test. Each arm is guarded to fail CLEANLY as ng (loud, not a hard error) when the file
# or a token is absent.
S142_RUBRIC="$SHELL_ROOT/.claude/rubrics/python.md"

# §142a: the Python idiom rubric SSOT exists AND carries each required criterion /
# structural token verbatim — the title, the deterministic-vs-LLM boundary, a
# representative spread of the 9 criteria (EAFP, context manager, dataclass, type hint),
# the motivating design SMELL, and the #276/#490 reuse scope note.
if [ -f "$S142_RUBRIC" ] \
   && grep -qF '# Python idiom / readability rubric' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'Deterministic-vs-LLM boundary' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'EAFP' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'context manager' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'dataclass' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'type hint' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF 'SMELL: type-by-attribute-combination' "$S142_RUBRIC" 2>/dev/null \
   && grep -qF "Reuse, don't re-handroll" "$S142_RUBRIC" 2>/dev/null; then
  ok "142a: .claude/rubrics/python.md carries title + boundary + criteria spread + SMELL + reuse note (#581)"
else
  ng "142a: .claude/rubrics/python.md missing or lacks a required criterion / SMELL / reuse token (#581)"
fi

# §142b (ANTI-VACUITY LOCK, mirrors §139e): the motivating-smell worked example is
# structurally explicit, not degraded to a bare mention. Require ALL THREE: the exemplar
# (Unpythonic (but correct)), the Pythonic discriminator-fix (dispatch / match /
# singledispatch OR the explicit-discriminator phrase), and the correct-but-unpythonic
# property (The unpythonic form is). If any is missing the case fails.
if [ -f "$S142_RUBRIC" ] \
   && grep -qF 'Unpythonic (but correct)' "$S142_RUBRIC" 2>/dev/null \
   && { grep -qF 'dispatch' "$S142_RUBRIC" 2>/dev/null \
        || grep -qF 'match' "$S142_RUBRIC" 2>/dev/null \
        || grep -qF 'singledispatch' "$S142_RUBRIC" 2>/dev/null \
        || grep -qF 'explicit discriminator' "$S142_RUBRIC" 2>/dev/null; } \
   && grep -qF 'The unpythonic form is' "$S142_RUBRIC" 2>/dev/null; then
  ok "142b: python.md worked example is structurally explicit (exemplar + discriminator-fix + correct-but-unpythonic) (#581)"
else
  ng "142b: python.md worked example degraded — missing exemplar, discriminator-fix, or correctness note (#581)"
fi

# §142c (advisory-never-block contract, mirrors bash.md): the rubric records that its
# criteria are advisory and never escalate to block — a `never` + `block` co-occurrence
# on one line, or the standalone `advisory` marker.
if [ -f "$S142_RUBRIC" ] \
   && { grep -qF 'advisory' "$S142_RUBRIC" 2>/dev/null \
        || grep -n 'never' "$S142_RUBRIC" 2>/dev/null | grep -qF 'block'; }; then
  ok "142c: python.md records the advisory-never-block contract (advisory / never+block) (#581)"
else
  ng "142c: python.md missing the advisory-never-block wording (advisory or never+block) (#581)"
fi

# ---------- §145: issue-title principle content-lock (#583) ----------
# Mirrors §142 (the python.md drift-guard): a content-lock that is GREEN on arrival, not
# a red-first test. Phase A of #583 already committed the SPEC §9.2 "Title principle"
# paragraph (the issue title is a plain problem statement, NOT the `<type>(#N):`
# commit/PR-subject form; a guiding norm, not a hard gate). AC4 asks for a drift-guard so
# a later edit that dilutes or drops the principle fails CI. Each arm is `[ -f ]`-guarded
# so an absent SPEC / template fails CLEANLY as ng (loud), not a hard error.
S145_SPEC="$SHELL_ROOT/SPEC.md"
S145_ISSUE_TPL="$SHELL_ROOT/.claude/templates/issue.md"

# §145a: SPEC §9.2 carries the title-principle tokens verbatim — the distinctive header
# phrase (Title principle), the clarity principle (plain problem statement), and the
# anti-commit-form note (used for issue titles — the §9.2-distinctive negation of the
# `<type>(#N):` form). All three must be byte-present or the principle has drifted.
if [ -f "$S145_SPEC" ] \
   && grep -qF 'Title principle' "$S145_SPEC" 2>/dev/null \
   && grep -qF 'plain problem statement' "$S145_SPEC" 2>/dev/null \
   && grep -qF 'used for issue titles' "$S145_SPEC" 2>/dev/null; then
  ok "145a: SPEC §9.2 carries the title principle (Title principle + plain problem statement + used for issue titles) (#583)"
else
  ng "145a: SPEC §9.2 missing a title-principle token (Title principle / plain problem statement / used for issue titles) (#583)"
fi

# §145b (ANTI-VACUITY / norm-not-gate lock): the principle is stated as a guiding norm,
# NOT a hard lint/gate. Require the exact norm-not-format wording so an edit that
# silently promotes the principle into a gate (or collapses the nuance) fails.
if [ -f "$S145_SPEC" ] \
   && grep -qF 'guiding norm, not a rigid format' "$S145_SPEC" 2>/dev/null; then
  ok "145b: SPEC §9.2 keeps the norm-not-gate framing (guiding norm, not a rigid format) (#583)"
else
  ng "145b: SPEC §9.2 lost the norm-not-gate framing (guiding norm, not a rigid format) (#583)"
fi

# §145c (thin-pointer lock): the issue.md template carries the one-line title hint that
# points back to SPEC §9.2 — the plain-problem-statement cue at author time.
if [ -f "$S145_ISSUE_TPL" ] \
   && grep -qF 'Title: a plain problem statement' "$S145_ISSUE_TPL" 2>/dev/null \
   && grep -qF 'SPEC §9.2' "$S145_ISSUE_TPL" 2>/dev/null; then
  ok "145c: issue.md template carries the title hint pointer to SPEC §9.2 (#583)"
else
  ng "145c: issue.md template missing the title hint pointer (Title: a plain problem statement / SPEC §9.2) (#583)"
fi

# ---------- §146: is_covered_ship_merge_form helper unit + presence (#592) ----------
# The #592 bypass backstop blocks IFF BOTH the command is the exact covered ship
# form AND it is a self-merge. is_covered_ship_merge_form is the form half: it
# returns 0 for EXACTLY `gh pr merge --auto --merge --delete-branch` (the
# settings.json:4 static-allow entry, tolerating a leading gh global-flag run) and
# non-zero for anything else. Sourced from ac_closeout_gate.sh the same way the
# hook safe_sources it. RED now: Phase C has not added the function.
#
# ANTI-VACUITY: every assertion runs the helper via s146_rc, which prints 127 when
# the function is ABSENT. The positive requires rc=0 (absent ⇒ 127 ⇒ ng/RED). The
# negatives require a PRESENT-and-non-zero rc (rc != 0 AND rc != 127) — an absent
# function reports 127 and fails the guard, so a negative can NEVER vacuously green
# on the missing helper. All six are RED now and turn GREEN only when the helper
# exists AND classifies each form correctly.
S146_GATE="$SHELL_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh"

# s146_rc <cmd> — source the gate in a subshell and print is_covered_ship_merge_form's
# exit code, or 127 if the function is undefined (Phase C absent).
s146_rc() {
  (
    # shellcheck source=/dev/null
    . "$S146_GATE" 2>/dev/null
    command -v is_covered_ship_merge_form >/dev/null 2>&1 || { printf 127; exit; }
    is_covered_ship_merge_form "$1" >/dev/null 2>&1
    printf '%s' "$?"
  )
}

# §146a (presence): the function is defined after sourcing ac_closeout_gate.sh.
if [ "$(s146_rc 'gh pr merge --auto --merge --delete-branch')" != 127 ]; then
  ok "146a: is_covered_ship_merge_form defined in ac_closeout_gate.sh (#592)"
else
  ng "146a: is_covered_ship_merge_form undefined — Phase C absent (#592)"
fi

# §146b (positive): the EXACT covered form → 0.
if [ "$(s146_rc 'gh pr merge --auto --merge --delete-branch')" = 0 ]; then
  ok "146b: is_covered_ship_merge_form returns 0 for the exact covered ship form (#592)"
else
  ng "146b: is_covered_ship_merge_form must return 0 for 'gh pr merge --auto --merge --delete-branch' (#592)"
fi

# §146c (negative — extra flag): a superset with an extra flag → non-zero.
s146c=$(s146_rc 'gh pr merge --auto --merge --delete-branch --draft')
if [ "$s146c" != 0 ] && [ "$s146c" != 127 ]; then
  ok "146c: is_covered_ship_merge_form rejects an extra flag (--draft) (#592)"
else
  ng "146c: is_covered_ship_merge_form must reject the covered form + an extra flag (rc=$s146c) (#592)"
fi

# §146d (negative — reordered): the same flags in a different order → non-zero.
s146d=$(s146_rc 'gh pr merge --merge --auto --delete-branch')
if [ "$s146d" != 0 ] && [ "$s146d" != 127 ]; then
  ok "146d: is_covered_ship_merge_form rejects a reordered flag run (#592)"
else
  ng "146d: is_covered_ship_merge_form must reject '--merge --auto --delete-branch' (reordered) (rc=$s146d) (#592)"
fi

# §146e (negative — positional PR): an explicit PR number → non-zero.
s146e=$(s146_rc 'gh pr merge 55 --auto --merge --delete-branch')
if [ "$s146e" != 0 ] && [ "$s146e" != 127 ]; then
  ok "146e: is_covered_ship_merge_form rejects a positional PR number (#592)"
else
  ng "146e: is_covered_ship_merge_form must reject 'gh pr merge 55 --auto --merge --delete-branch' (rc=$s146e) (#592)"
fi

# §146f (negative — wrong strategy): --squash instead of --merge → non-zero.
s146f=$(s146_rc 'gh pr merge --auto --squash --delete-branch')
if [ "$s146f" != 0 ] && [ "$s146f" != 127 ]; then
  ok "146f: is_covered_ship_merge_form rejects a wrong strategy (--squash) (#592)"
else
  ng "146f: is_covered_ship_merge_form must reject '--auto --squash --delete-branch' (wrong strategy) (rc=$s146f) (#592)"
fi

# ---------- §147 label description ≤100 chars (#596) ----------
# GitHub caps label descriptions at 100 chars; an over-length --description
# makes `gh label create` return HTTP 422, which under `set -euo pipefail`
# aborts ensure_v3_labels.sh mid-run and leaves the dir-mode substrate
# half-installed (the subsequent inline directive/initiative labels in
# onboard_target.sh never get created). Assert every description the script
# authors is ≤100 chars. Count-guard (anti-vacuity, top-of-file norm): fail
# loud if the parse finds too few ensure_label lines — a vacuous green here
# would read as coverage while guarding nothing.
S147_SRC="$SHELL_ROOT/scripts/ensure_v3_labels.sh"
if [ ! -f "$S147_SRC" ]; then
  ng "147: MISSING ensure_v3_labels.sh — cannot check label description lengths (#596)"
else
  s147_over=""
  s147_n=0
  while IFS= read -r line; do
    case "$line" in
      ensure_label\ \"*) ;;
      *) continue ;;
    esac
    name=$(printf '%s\n' "$line" | sed -E 's/.*ensure_label "([^"]+)".*/\1/')
    desc=$(printf '%s\n' "$line" | sed -E 's/.*"[0-9A-Fa-f]{6}" +"(.*)"[[:space:]]*$/\1/')
    s147_n=$((s147_n+1))
    if [ "${#desc}" -gt 100 ]; then
      s147_over="$s147_over $name(${#desc})"
    fi
  done < "$S147_SRC"
  if [ "$s147_n" -lt 10 ]; then
    ng "147: parsed only $s147_n ensure_label lines (<10) — parser drift, not a real pass (#596)"
  elif [ -n "$s147_over" ]; then
    ng "147: label descriptions exceed GitHub's 100-char limit:$s147_over (#596)"
  else
    ok "147: all $s147_n ensure_v3_labels.sh label descriptions ≤100 chars (#596)"
  fi
fi

# ---------- §149: smoke.sh split + shellcheck re-coverage (#600) ----------
# smoke.sh grew until its OWN shellcheck peak (~20 GiB RSS at ~16k lines) OOM-killed
# the ubuntu CI runner; #599 mitigated by exempting smoke.sh from shellcheck (bash -n
# only). #600 splits the suite into a thin orchestrator + sourced scripts/test/smoke.d/
# section files (one process → byte-identical pass/fail semantics) so each shellcheck
# unit fits the runner, removes the #599 exemption, and adds a deterministic per-file
# line-count cliff guard (line_cap) to lint.sh. These structural locks are RED until
# the Code phase lands the split; they travel into a smoke.d/ section on carve.
S149_LINT="$SHELL_ROOT/scripts/lint.sh"
S149_SMOKED="$SHELL_ROOT/scripts/test/smoke.d"

# §149a (LOAD-BEARING RED): the split landed — smoke.d/ holds >=2 sourced section files.
s149_n=0
[ -d "$S149_SMOKED" ] && s149_n=$(find "$S149_SMOKED" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | grep -c .)
if [ "$s149_n" -ge 2 ]; then
  ok "149a: scripts/test/smoke.d/ holds >=2 sourced section files (count=$s149_n) (#600)"
else
  ng "149a: smoke.d/ must hold >=2 section files after the split (count=$s149_n) (#600)"
fi

# §149b (LOAD-BEARING RED): lint.sh no longer exempts smoke.sh from shellcheck — the
# #599 sc_exempt arm is gone, so every (now-bounded) file is statically analyzed again.
if [ -f "$S149_LINT" ] && ! grep -q 'sc_exempt' "$S149_LINT" 2>/dev/null; then
  ok "149b: lint.sh no longer carries the #599 smoke.sh shellcheck exemption — full re-coverage (#600)"
else
  ng "149b: lint.sh still carries the #599 sc_exempt smoke.sh exemption — must be removed post-split (#600)"
fi

# §149c (LOAD-BEARING RED): lint.sh carries a deterministic per-file line-count cliff
# guard (token `line_cap`) — the un-flakeable hard gate that catches the next file
# approaching the RSS cliff before an OOM (the RSS flag stays non-fatal, §11).
if [ -f "$S149_LINT" ] && grep -q 'line_cap' "$S149_LINT" 2>/dev/null; then
  ok "149c: lint.sh carries a per-file line-count cliff guard (line_cap) (#600)"
else
  ng "149c: lint.sh must add a deterministic per-file line-count cliff guard (line_cap) (#600)"
fi

# ---------- §156: SSOT change sweep protocol content-lock (SPEC §1.3.1, #640) ----------
# GREEN-AT-DOC by design (the §126a/§127a/§129b shape, precedent #528 at 60-*.sh:1348),
# NOT red-first: #640 is a doctrine-only Issue whose Directive-level plan carries an
# explicit `Code: n/a`, so SPEC §1.3.1 IS the deliverable and smoke IS its only
# assertion surface. These locks exist so the two LATER Execution Issues of Directive
# #636 — which must implement exactly these code forms — cannot silently rename or drop
# one, and so a later prose edit cannot dilute the two load-bearing negative results.
#
# ANTI-VACUITY: every content arm reads a WINDOW bounded to §1.3.1 (awk from the
# `#### 1.3.1` heading, terminating at the next heading of depth <= 4), never the whole
# SPEC — several of these tokens (`inconclusive`, `read-through`, "first-class") also
# occur elsewhere in SPEC, so an unscoped grep would green on an unrelated section. The
# window itself is COUNT-GUARDED (§156a): a lock over an empty window passes vacuously,
# which is precisely anti-pattern #2 in the smoke.sh header. If the window collapses,
# §156a fails LOUD and the content arms do not run as fake passes.
S156_SPEC="$SHELL_ROOT/SPEC.md"
s156_win=""
s156_n=0
if [ -f "$S156_SPEC" ]; then
  # Depth-<=4 terminator written as an explicit alternation rather than `^#{1,4} `:
  # ERE interval support in awk is not universal, and `^(#|##|###|####) ` correctly
  # excludes `##### ` (five hashes are not followed by a space at any of the four arms).
  #
  # FENCE-AWARE: a fenced line beginning `# ` (a shell comment inside a ``` block) is
  # indistinguishable from a depth-1 heading to a line-oriented terminator, so it would
  # truncate the window mid-section — observed once, when a `# exactly one of …` comment
  # was added inside this section's own trailer fence and silently cut the window from 21
  # lines to 13. The `f` toggle tracks fence state so the terminator only fires OUTSIDE a
  # fence; the floor below then guards what remains.
  s156_win=$(awk '/^#### 1\.3\.1 /{i=1;next} !i{next} /^```/{f=!f} !f&&/^(#|##|###|####) /{exit} i' "$S156_SPEC")
  s156_n=$(printf '%s\n' "$s156_win" | grep -c .)
fi

# s156_re / s156_fx — window-scoped ERE / fixed-string probes. Both read ONLY the
# extracted window, so no arm can be satisfied by text outside §1.3.1.
s156_re() { printf '%s\n' "$s156_win" | grep -qE "$1"; }
s156_fx() { printf '%s\n' "$s156_win" | grep -qF "$1"; }

if [ ! -f "$S156_SPEC" ]; then
  ng "156: SPEC.md absent — cannot assert the §1.3.1 SSOT change sweep protocol (#640)"
elif [ "$s156_n" -lt 18 ] || [ "$s156_n" -gt 60 ]; then
  # TWO-SIDED, because the extractor is fence-aware and that INVERTED the failure
  # mode rather than removing it (#643). ONE unbalanced ``` inside §1.3.1 does not
  # make the toggle stick — it INVERTS THE PARITY from that point on, so headings
  # sitting in real prose are ignored while `#`-prefixed lines inside genuine
  # fenced blocks are honoured as terminators. Measured on the over-extension
  # fixture (SPEC.md plus one injected marker, 2895 lines): the window spans
  # 269-739 and exits at 740 on a shell comment inside a ```bash fence — 368
  # non-blank lines against a healthy 22, stable across six injection offsets.
  # When the window over-extends like that, a floor alone reports the locks
  # "load-bearing" over §1.4–§3.
  #
  # 22 non-blank lines at this commit — RE-MEASURED, not carried forward from the
  # stale 21 this comment used to carry (#643 AC5). No history is reconstructed
  # here on purpose: the count is deliberately NOT pinned by an arm (per §156j's
  # neighbouring note), so nothing can ever catch a narrative about it drifting,
  # and this line has already carried two successive wrong provenance stories.
  # Re-measure it; do not re-tell it.
  #
  # The floor tolerates ordinary prose tightening and catches a collapsed or
  # renamed heading; the ceiling leaves §1.3.1 room to nearly triple while sitting
  # six-fold below the ~368 a desync produces today. Both values are deliberately
  # NOT repeated here — they are on the two lines directly below, and a fourth
  # hand-synced copy is a fourth thing to keep in sync (#673). The bounds are NAMED in both
  # messages so a failure says which side tripped, and §156o/§156p parse those two
  # spellings — renaming them fails CLOSED (measured: both arms red), so it is not
  # a silent hazard.
  ng "156a: SPEC §1.3.1 window out of bounds (non-blank lines=$s156_n, floor=18, ceiling=60) — below the floor the content locks would pass VACUOUSLY; above the ceiling the window has over-extended past §1.3.1 and the locks would be asserted over unrelated sections (#640, #643)"
else
  ok "156a: SPEC §1.3.1 window resolves within bounds (non-blank lines=$s156_n, floor=18, ceiling=60) — content locks below are load-bearing (#640, #643)"

  # §156b: the two commit-trailer KEYS, anchored to the code form (line-start inside the
  # fenced grammar block), not a backticked prose mention — the later Execution Issues
  # parse exactly these keys, so a rename must trip here.
  if s156_re '^SSOT-sweep: ' && s156_re '^SSOT-sweep-tier: '; then
    ok "156b: §1.3.1 declares both trailer keys in code form (SSOT-sweep: / SSOT-sweep-tier:) (#640)"
  else
    ng "156b: §1.3.1 missing a trailer key in code form (expected line-anchored 'SSOT-sweep: ' and 'SSOT-sweep-tier: ') (#640)"
  fi

  # §156c: both tier names, pinned to the tier trailer's VALUE grammar rather than to
  # the bold prose mentions — the grammar line is what an implementation must match.
  if s156_re '^SSOT-sweep-tier: term-sweep\|read-through$'; then
    ok "156c: §1.3.1 pins the tier vocabulary in the trailer grammar (term-sweep|read-through) (#640)"
  else
    ng "156c: §1.3.1 lost the tier value grammar line 'SSOT-sweep-tier: term-sweep|read-through' (#640)"
  fi

  # §156d: the third outcome. `inconclusive` is backticked (a code form) and is bound to
  # a non-zero exit — the whole point is that it is NOT a pass-and-warn.
  if s156_re '`inconclusive`.*non-zero exit'; then
    ok "156d: §1.3.1 keeps the backticked \`inconclusive\` outcome bound to a non-zero exit (#640)"
  else
    ng "156d: §1.3.1 lost the \`inconclusive\` code form or its non-zero-exit binding (#640)"
  fi

  # §156e: the `!` scope-negation form — backticked, and tied to the word it defines, so
  # an unrelated exclamation mark in prose cannot satisfy it.
  if s156_re '`!`.*negat'; then
    ok "156e: §1.3.1 defines the leading \`!\` scope-negation form (#640)"
  else
    ng "156e: §1.3.1 lost the leading \`!\` scope-negation form (#640)"
  fi

  # §156f: routing. `/complete-directive` must be named as the consumer of the
  # inconclusive signal — the same line, so a stray mention elsewhere is not enough.
  if s156_re 'consumer.*`/complete-directive`'; then
    ok "156f: §1.3.1 names \`/complete-directive\` as the consumer of the inconclusive signal (#640)"
  else
    ng "156f: §1.3.1 no longer names \`/complete-directive\` as the signal's consumer (#640)"
  fi

  # §156g: anchor resolution is a GENERIC markdown heading parse, so an SSOT with
  # unnumbered headings is a first-class case rather than a degraded one. All three
  # tokens are required: dropping "first-class" would leave the degradation reading open.
  if s156_fx 'generic markdown heading parse' && s156_fx 'unnumbered' && s156_fx 'first-class'; then
    ok "156g: §1.3.1 resolves anchors by a generic markdown heading parse — unnumbered headings are first-class (#640)"
  else
    ng "156g: §1.3.1 lost the generic-heading-parse / unnumbered / first-class guarantee (#640)"
  fi

  # §156h: the load-bearing NEGATIVE result — mechanical derivation of the retired set
  # from a diff does not work, and is closed to re-proposal. A later Issue that deletes
  # this sentence re-opens a settled dead end.
  if s156_re 'Deriving the retired set mechanically' && s156_re '\*\*not\*\* work' \
     && s156_fx 'not to be re-proposed'; then
    ok "156h: §1.3.1 keeps the negative result — mechanical derivation of the retired set does not work, not to be re-proposed (#640)"
  else
    ng "156h: §1.3.1 lost the mechanical-derivation negative result or its not-to-be-re-proposed closure (#640)"
  fi

  # §156i: the two-sets distinction (the sweep INPUT vs the evidence INPUT). Anchored on
  # the bolded term forms the section actually uses, plus the framing sentence.
  if s156_fx '**candidate-term set**' && s156_fx '**declared retirement set**' \
     && s156_re 'Two sets, deliberately different'; then
    ok "156i: §1.3.1 keeps the two-sets distinction (**candidate-term set** wide vs **declared retirement set** narrow) (#640)"
  else
    ng "156i: §1.3.1 collapsed the two-sets distinction (candidate-term set vs declared retirement set) (#640)"
  fi

  # §156l: the TIER BOUNDARY predicate itself — the one decision this Issue calls a
  # "fixed tier boundary" (AC1), and the decision a challenger won over the base plan.
  # Locked on the measured-reach form (anchors + non-SSOT carrier), NOT on the rejected
  # direction-keyed form: an edit reverting to "subtractive vs additive" must fail here.
  if s156_re 'affected heading anchors number more than one' \
     && s156_re 'non-SSOT carrier file is touched' \
     && s156_re 'Direction.*never to the gate'; then
    ok "156l: §1.3.1 fixes the tier boundary on measured reach (anchors + non-SSOT carrier) and excludes direction from the gate (#640)"
  else
    ng "156l: §1.3.1 lost the measured-reach tier boundary or readmitted direction into the gate (#640)"
  fi

  # §156m: the MONOTONICITY DIRECTION — widen-yes / narrow-never — plus the re-anchor
  # carve-out the parent Directive states. §156d locks the `inconclusive` machinery;
  # this locks the rule that machinery guards.
  # PHRASES, not bare words (#643 AC6). `widened` and `re-anchor` were each
  # individually satisfiable by unrelated prose anywhere in the window; only the
  # conjunction carried the lock. Pinned to the forms §1.3.1 actually uses, so
  # each conjunct now bites on its own.
  if s156_re 'may be \*\*widened\*\*' && s156_re 'never be narrowed' \
     && s156_re '\*\*re-anchor\*\* accompanying a heading rename'; then
    ok "156m: §1.3.1 keeps widen-yes / narrow-never with the re-anchor carve-out (#640)"
  else
    ng "156m: §1.3.1 lost the monotonicity direction or the re-anchor carve-out (#640)"
  fi

  # §156n: the EMPTY DECLARATION is a production of the grammar, not an omission. The
  # section makes absent-vs-empty load-bearing, so the empty form needs a parseable
  # token; a reader that cannot parse it cannot tell the two states apart.
  if s156_re '^SSOT-sweep: none$' && s156_re 'empty declaration'; then
    ok "156n: §1.3.1 states the empty declaration as a grammar production (SSOT-sweep: none) (#640)"
  else
    ng "156n: §1.3.1 lost the empty-declaration token from the trailer grammar (#640)"
  fi
fi

# ---------- §156o–§156r: the §1.3.1 window is bounded on BOTH sides (#643) ----------
# The count-guard above was a FLOOR only at e8aa0db. The fence-awareness that closed the
# truncation gap (#641) opened the opposite one: with an ODD number of ``` markers
# inside §1.3.1 the extra marker INVERTS the `f` parity from that point on, so headings in real prose
# stop terminating the window and it runs on — measured, to line 740 of the 2895-line
# over-extension fixture (SPEC.md is 2894),
# swallowing §1.4 through §3.2. A floor cannot see that; the
# guard then reports the eleven content locks "load-bearing" over a window whose
# scope it has not checked, which is anti-pattern #2 in the smoke.sh header wearing
# the opposite sign.
#
# WITNESS HONESTY — only ONE of the four arms below is a witness:
#   §156p (over-extension) is the WITNESS. It is RED at e8aa0db (the Test commit,
#   guard floor-only) and greens only
#          when a ceiling exists.
#   §156o (both bounds named), §156q (truncation), §156r (healthy) are BOUNDS, not
#          witnesses. §156q and §156r pass BEFORE and AFTER the fix by construction —
#          they exist to prove the ceiling does not blind the floor (§156q) and that
#          the pair is not simply always-failing (§156r). Neither is evidence that the
#          defect was repaired; only §156p is. (§156o is red at e8aa0db for the same reason
#          §156p is, but it reads the guard's TEXT, not its behaviour.)
#
# NO LIVE SPEC MUTATION. All three fixtures are copies under the preamble's $TMP,
# removed by its EXIT trap; $S156_SPEC is only ever read.
#
# DECISION SOURCE (#673). Every arm here drives the live guard: its EXTRACTOR is lifted
# verbatim out of the guard's own `s156_win=$(awk …)` source line, and its DECISION is
# taken by EVALUATING the guard's own condition line, lifted the same way (see the lift
# below and §156s). Nothing in this block re-implements §156a's comparison, so the two
# directions are covered together:
#   OMISSION  — a bound the guard never declares and never executes cannot bind anything,
#               and reads here exactly as it behaves there: absent (§156p reds).
#   DIVERGENCE — a bound the guard DECLARES but does not EXECUTE, or executes but does not
#               declare, is caught by the composition: §156s (the condition can be read at
#               all) + §156t (the two `156a:` messages agree with each other) + §156u
#               (what the messages declare equals the numerals the condition executes).
#               This is #643 round-1's F4b vector; #673 is its repair, not its deferral.
#
# UNCOVERED BY CONSTRUCTION, deliberately: a bound changed WRONGLY but CONSISTENTLY — in
# the condition and in both messages together — stays green here. It has to. #673 AC2 asks
# for exactly that: the arms must DERIVE the bound rather than restate it, so a ceiling
# retuned everywhere at once is indistinguishable from a legitimate retuning. Whether the
# two values are the RIGHT ones is a judgement no arm in this file makes (#643, locked). No
# bound numeral is repeated in this block, on purpose — a copy here would be one more thing
# to keep in sync and would silently satisfy AC1 while re-creating #673's own defect.
#
# FAIL-CLOSED ON A REFACTOR. The lift anchor is broad (`^elif .*s156_n.*; then$`, and an
# arithmetic `(( s156_n < … || s156_n > … ))` rewrite is measured to lift and evaluate
# cleanly), but a rewrite it cannot recognise yields an empty condition, which is
# UNEVALUABLE, not accepting: §156s reds and §156p/§156q/§156r red as UNTESTED rather than
# reporting a bound they never applied.
#
# RUNNABLE AGAINST e8aa0db (the pre-#643 Test commit, guard floor-only) — #643 round 1's
# measured deferral reason and #673 AC3's binding constraint. Measured for this design:
# `✗156o ✗156p ✓156q ✓156r`, clean `ng` assertion failures, no `unbound variable` under
# `set -u`. The lifted condition names only `s156_n`, which s156o_accepts binds as a
# function-local before evaluating it, so a floor-only condition evaluates there exactly as
# it does here.
#
# SHARED BLINDSPOT, disclosed rather than mitigated: no arm in this block ever executes
# §156a itself. All of them SIMULATE it from its source text — the extractor and now the
# condition are the guard's real bytes, but they are re-run over fixtures, not observed
# firing. An edit that leaves both source lines intact and breaks §156a some other way
# (its surrounding `if`/`elif` chain, the variable it feeds) is invisible here.
S156O_SRC="$SHELL_ROOT/scripts/test/smoke.d/70-gates-contentlocks.sh"
s156o_msgs=""
s156o_floor=""
s156o_ceil=""
s156o_prog=""
# s156o_cbound — the guard's own first `156a` assertion-message line number. It is the
# LIFT BOUND, and the bound is load-bearing rather than tidy: the lift anchor
# `^elif .*s156_n.*; then$` is deliberately broad enough to survive a rewrite of the
# condition's shape, and unbounded it also matches §156r's own
# `elif [ "$s156o_hn" -ne "$s156_n" ]; then` below. Against a guard refactored to a form
# that no longer names s156_n, an unbounded -m1 lift picks up THAT line instead — so the
# arms would decide from a condition that is not §156a's, and their verdicts would say
# nothing about the guard. Measured, and this is the whole rationale: bounded, the lift
# returns empty; unbounded, it returns §156r's line.
# Searching only ahead of the first `156a` message cannot reach any arm of this block.
#
# s156o_cond — §156a's executed condition, lifted verbatim within that bound and stripped
# of its `elif`/`; then` wrapper. Empty means the lift failed, which every consumer treats
# as UNTESTED (never as agreement).
s156o_cbound=""
s156o_cond=""
if [ -f "$S156O_SRC" ]; then
  s156o_msgs=$(grep -E '^[[:space:]]*(ok|ng) "156a:' "$S156O_SRC")
  s156o_floor=$(printf '%s\n' "$s156o_msgs" | grep -oE 'floor=[0-9]+' | head -1 | cut -d= -f2)
  s156o_ceil=$(printf '%s\n' "$s156o_msgs" | grep -oE 'ceiling=[0-9]+' | head -1 | cut -d= -f2)
  # Line-anchored so this arm's own quoted copy of the pattern cannot match first.
  s156o_line=$(grep -m1 -E '^[[:space:]]*s156_win=\$\(awk ' "$S156O_SRC")
  case "$s156o_line" in
    *"awk '"*) s156o_prog=${s156o_line#*awk \'}; s156o_prog=${s156o_prog%\'*} ;;
  esac
  s156o_cbound=$(grep -n -m1 -E '^[[:space:]]*(ok|ng) "156a:' "$S156O_SRC" | cut -d: -f1)
  if [ -n "$s156o_cbound" ]; then
    s156o_cline=$(head -n "$s156o_cbound" "$S156O_SRC" | grep -m1 -E '^elif .*s156_n.*; then$')
    case "$s156o_cline" in
      elif\ *\;\ then) s156o_cond=${s156o_cline#elif }; s156o_cond=${s156o_cond%; then} ;;
    esac
  fi
fi

# s156o_accepts <non-blank-line-count> — THREE-VALUED, and the three values are the point:
#   0 ACCEPT       — the guard's own condition, evaluated at that count, does NOT trip
#   1 REJECT       — it trips
#   2 UNEVALUABLE  — the condition could not be lifted, or evaluating it failed
# It does not mirror §156a's decision any more; it RUNS it. The lifted text is EVALUATED in
# a SUBSHELL with `s156_n` bound function-locally, so a condition naming a variable that is
# unbound at this point in the suite kills the subshell under `set -u` and comes back as
# UNEVALUABLE instead of killing the run. The two sentinel exits (10/11) are what separate a
# genuine verdict from any failure mode of eval itself — a shell that died on the condition
# exits 1/2/127, all of which land in UNEVALUABLE. Callers must branch on all three: folding
# 2 into "not accepted" would green §156p/§156q on a condition they never managed to run.
s156o_accepts() {
  # shellcheck disable=SC2034  # read by the lifted condition below, via eval
  local s156_n="$1"
  local rc=0
  ( eval "if $s156o_cond; then exit 11; else exit 10; fi" ) >/dev/null 2>&1
  rc=$?
  case "$rc" in
    10) return 0 ;;
    11) return 1 ;;
    *)  return 2 ;;
  esac
}

# Fixtures. -1 means NOT MEASURED, so no arm can read a zero as agreement.
S156O_DIR="$TMP/s156o"
s156o_hn=-1; s156o_on=-1; s156o_tn=-1
s156o_hfence=-1; s156o_ofence=-1
if [ -f "$S156_SPEC" ] && [ -n "$s156o_prog" ] && mkdir -p "$S156O_DIR" 2>/dev/null; then
  if cp "$S156_SPEC" "$S156O_DIR/healthy.md" 2>/dev/null && [ -s "$S156O_DIR/healthy.md" ]; then
    # (b) over-extension: ONE unclosed fence opened immediately after the §1.3.1
    # heading — the minimum mutation that desyncs the toggle. (c) truncation: the
    # heading renamed, so the window never opens.
    awk '{print} /^#### 1\.3\.1 /{print "```"}' "$S156O_DIR/healthy.md" > "$S156O_DIR/overextended.md" 2>/dev/null
    awk '/^#### 1\.3\.1 /{sub(/^#### 1\.3\.1 /, "#### 1.3.1-renamed ")} {print}' \
      "$S156O_DIR/healthy.md" > "$S156O_DIR/renamed.md" 2>/dev/null
    s156o_hfence=$(grep -c '^```' "$S156O_DIR/healthy.md")
    [ -s "$S156O_DIR/overextended.md" ] && s156o_ofence=$(grep -c '^```' "$S156O_DIR/overextended.md")
    s156o_hn=$(awk "$s156o_prog" "$S156O_DIR/healthy.md" | grep -c .)
    [ -s "$S156O_DIR/overextended.md" ] && s156o_on=$(awk "$s156o_prog" "$S156O_DIR/overextended.md" | grep -c .)
    # The renamed fixture is validated by its MARKER, not by its count: a count of 0
    # is the very thing §156q asserts, so reading 0 as proof the fixture built would
    # be circular. Only if the rename actually landed is the count trusted.
    if [ -s "$S156O_DIR/renamed.md" ] && grep -q '^#### 1\.3\.1-renamed ' "$S156O_DIR/renamed.md" \
       && ! grep -q '^#### 1\.3\.1 ' "$S156O_DIR/renamed.md"; then
      s156o_tn=$(awk "$s156o_prog" "$S156O_DIR/renamed.md" | grep -c .)
    fi
  fi
fi

# Verdicts, taken ONCE and stored, because s156o_accepts is three-valued and
# `if s156o_accepts "$n"; then` would silently fold UNEVALUABLE into REJECT — greening
# §156p/§156q on a condition the arms never managed to run. 2 (UNEVALUABLE) is also the
# initial value, so an unbuilt fixture is never mistaken for a verdict.
s156o_hv=2; s156o_ov=2; s156o_tv=2
if [ "$s156o_hn" -ge 0 ]; then s156o_accepts "$s156o_hn"; s156o_hv=$?; fi
if [ "$s156o_on" -ge 0 ]; then s156o_accepts "$s156o_on"; s156o_ov=$?; fi
if [ "$s156o_tn" -ge 0 ]; then s156o_accepts "$s156o_tn"; s156o_tv=$?; fi

# §156o — AC1: the guard names BOTH bounds in its own assertion message, so a failure
# says WHICH SIDE tripped. Reads the guard's text; §156p reads its behaviour.
if [ -z "$s156o_msgs" ]; then
  ng "156o: cannot read this suite's own 156a assertion messages — the window-bound arms below would be vacuous (#643)"
elif [ -n "$s156o_floor" ] && [ -n "$s156o_ceil" ]; then
  ok "156o: the §1.3.1 window guard names both bounds in its assertion message (floor=$s156o_floor ceiling=$s156o_ceil) — a failure names which side tripped (#643)"
else
  ng "156o: the §1.3.1 window guard declares only one bound (floor=${s156o_floor:-<none>} ceiling=${s156o_ceil:-<none>}) — a failure cannot name which side tripped (#643)"
fi

# §156p — AC2, THE WITNESS. One unclosed fence inside §1.3.1 must make the guard fail
# LOUD. RED at e8aa0db: the floor admits the over-extended window.
if [ "$s156o_hn" -lt 0 ] || [ "$s156o_on" -lt 0 ]; then
  ng "156p: over-extension fixture not built (healthy n=$s156o_hn over n=$s156o_on) — the ceiling is UNTESTED, not satisfied (#643)"
elif [ "$s156o_ofence" -ne $((s156o_hfence + 1)) ]; then
  ng "156p: over-extension fixture did not take (fence markers healthy=$s156o_hfence over=$s156o_ofence, expected +1) — arm would be vacuous (#643)"
elif [ "$s156o_on" -le "$s156o_hn" ]; then
  ng "156p: over-extension fixture did not over-extend (over n=$s156o_on vs healthy n=$s156o_hn) — arm would be vacuous (#643)"
elif [ "$s156o_ov" -ge 2 ]; then
  ng "156p: §156a's executed condition could not be evaluated at n=$s156o_on (lifted='${s156o_cond:-<none>}') — the ceiling is UNTESTED, not satisfied (#673)"
elif [ "$s156o_ov" -eq 0 ]; then
  ng "156p: an unclosed fence in §1.3.1 runs the window to $s156o_on non-blank lines (healthy=$s156o_hn) and the guard's EXECUTED condition ACCEPTS it (declared floor=${s156o_floor:-<none>} ceiling=${s156o_ceil:-<none>}) — the content locks would be called load-bearing over §1.4–§3 (#643, #673)"
else
  ok "156p: an unclosed fence in §1.3.1 over-extends the window to $s156o_on non-blank lines and the guard's EXECUTED condition REJECTS it (declared floor=${s156o_floor:-<none>} ceiling=${s156o_ceil:-<none>}) (#643, #673)"
fi

# §156q — AC3, a BOUND (not a witness; passes before and after). The ceiling must not
# blind the floor: a renamed heading still collapses the window and still fails loud.
if [ "$s156o_tn" -lt 0 ]; then
  ng "156q: renamed-heading fixture not built or rename did not land — the floor is UNTESTED, not satisfied (#643)"
elif [ "$s156o_tn" -ne 0 ]; then
  ng "156q: renamed-heading fixture left a non-empty window (n=$s156o_tn, expected 0) — arm would be vacuous (#643)"
elif [ "$s156o_tv" -ge 2 ]; then
  ng "156q: §156a's executed condition could not be evaluated at n=$s156o_tn (lifted='${s156o_cond:-<none>}') — the floor is UNTESTED, not satisfied (#673)"
elif [ "$s156o_tv" -eq 0 ]; then
  ng "156q: a renamed §1.3.1 heading collapses the window to 0 non-blank lines and the guard's EXECUTED condition ACCEPTS it (declared floor=${s156o_floor:-<none>} ceiling=${s156o_ceil:-<none>}) (#643, #673)"
else
  ok "156q: a renamed §1.3.1 heading collapses the window to 0 non-blank lines and the guard's EXECUTED condition REJECTS it — the ceiling does not blind the floor (#643, #673)"
fi

# §156r — AC4, a BOUND (not a witness; passes before and after). The two rejections
# above are not an always-fail: the unmodified SPEC still passes. The count equality
# is also the anti-drift check — a fixture path that no longer reproduces the live
# window fails loud instead of quietly measuring something else.
if [ ! -f "$S156_SPEC" ]; then
  ng "156r: SPEC.md absent — the healthy-window bound is UNTESTED, not satisfied (#643)"
elif [ "$s156o_hn" -lt 0 ]; then
  ng "156r: healthy fixture not built or the guard's extractor could not be lifted from its source — bound UNTESTED (#643)"
elif [ "$s156o_hn" -ne "$s156_n" ]; then
  ng "156r: healthy fixture window ($s156o_hn) disagrees with the live §156a window ($s156_n) — the fixture path no longer reproduces the guard (#643)"
elif [ "$s156o_hv" -ge 2 ]; then
  ng "156r: §156a's executed condition could not be evaluated at n=$s156o_hn (lifted='${s156o_cond:-<none>}') — the healthy-window bound is UNTESTED, not satisfied (#673)"
elif [ "$s156o_hv" -eq 0 ]; then
  ok "156r: the unmodified SPEC §1.3.1 window ($s156o_hn non-blank lines) is ACCEPTED by the guard's EXECUTED condition (declared floor=${s156o_floor:-<none>} ceiling=${s156o_ceil:-<none>}) (#643, #673)"
else
  ng "156r: the unmodified SPEC §1.3.1 window ($s156o_hn non-blank lines) is REJECTED by the guard's EXECUTED condition (declared floor=${s156o_floor:-<none>} ceiling=${s156o_ceil:-<none>}) — the bounds are always-failing (#643, #673)"
fi

# ---------- §156s/§156t/§156u: DECLARED bounds vs the EXECUTED condition (#673) -----------
# §156p/§156q/§156r above now DECIDE by evaluating the guard's own lifted condition, so a
# bound the guard executes is measured directly. What they no longer check is the guard's
# TEXT: §156a also tells a failing reader a floor and a ceiling, and those messages can
# drift away from the condition without any arm above noticing. Measured at 469d9fb:
# deleting only the executed ceiling clause and leaving both messages intact left the whole
# suite green, §156o included. The three arms below close that gap in the order the
# composition needs — first that the executed condition can be READ at all (§156s), then
# that the two messages agree with EACH OTHER (§156t), then that they agree with the
# numerals the condition EXECUTES (§156u).
#
# The lift itself (s156o_cbound / s156o_cond) is above, next to the extractor lift, because
# s156o_accepts consumes it before §156p runs; its bound rationale is documented there.

# §156s — the composition's PRECONDITION. Reading the executed condition is what lets an
# arm stop re-implementing §156a's decision from its messages; if the lift comes back
# empty there is nothing to compose and the block is back to reading the messages only.
if [ -z "$s156o_cbound" ]; then
  ng "156s: cannot locate this suite's own 156a assertion message — the condition lift has no search bound, so the executed condition is UNTESTED, not satisfied (#673)"
elif [ -z "$s156o_cond" ]; then
  ng "156s: §156a's executed condition could not be lifted from this suite's own source (anchor '^elif .*s156_n.*; then\$', bounded to lines 1-$s156o_cbound) — the executed bound is UNTESTED, not satisfied (#673)"
else
  ok "156s: §156a's executed condition lifts from this suite's own source, bounded to lines 1-$s156o_cbound (#673)"
fi

# §156t — MESSAGE CONSISTENCY, and specifically the `head -1` blind spot. §156a states its
# bounds TWICE, once in each branch, and s156o_floor/s156o_ceil keep only the FIRST spelling
# of each. So changing the ceiling in exactly one of the two messages is invisible to §156o
# (a ceiling is still named) and can be invisible to §156u too (it compares the first one,
# which may be the untouched copy). Both messages describe the SAME condition, so more than
# one distinct value for either bound is a defect on its face: one of them is telling a
# failing reader a bound the guard does not apply. Counted as DISTINCT values, not
# occurrences — two branches legitimately repeat the same pair.
s156t_floors=$(printf '%s\n' "$s156o_msgs" | grep -oE 'floor=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ')
s156t_ceils=$(printf '%s\n' "$s156o_msgs" | grep -oE 'ceiling=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ')
s156t_nf=$(printf '%s\n' "$s156o_msgs" | grep -oE 'floor=[0-9]+' | sort -u | grep -c .)
s156t_nc=$(printf '%s\n' "$s156o_msgs" | grep -oE 'ceiling=[0-9]+' | sort -u | grep -c .)
if [ -z "$s156o_msgs" ]; then
  ng "156t: cannot read this suite's own 156a assertion messages — message consistency is UNTESTED, not satisfied (#673)"
elif [ "$s156t_nf" -le 1 ] && [ "$s156t_nc" -le 1 ]; then
  ok "156t: §156a's two assertion messages declare one bound pair between them (floor={ ${s156t_floors:-<none> }} ceiling={ ${s156t_ceils:-<none> }}) (#673)"
else
  ng "156t: §156a's two assertion messages disagree with each other (floor={ ${s156t_floors:-<none> }} ceiling={ ${s156t_ceils:-<none> }}) — one branch tells a failing reader a bound the other does not, and only the first is read below (#673)"
fi

# §156u — AC1: what the guard TELLS a failing reader must be what it APPLIES. §156o
# asserts both bounds are named and §156s asserts the condition can be read; neither
# compares them, so a guard whose two messages CONSISTENTLY declare a ceiling its
# condition does not execute satisfies both arms. (Numerals are deliberately not used
# to illustrate that here: this block went from four hand-synced copies of the bound
# to two, and an example numeral is one more thing a reader can mistake for the real
# value once the real value moves — #673.)
# Compared as SETS of numerals: the two surfaces order
# and spell their bounds differently, and neither ordering is a property worth locking.
#
# SYMMETRIC PIPELINE, deliberately. Both sides end in the same sort/tr tail, so a bound
# absent from BOTH surfaces contributes to neither set and the two compare EQUAL. That is
# the e8aa0db case — floor only, no ceiling in the condition and none in the messages —
# and it must read as AGREEMENT: an asymmetric pipeline reds there on "" vs " " and costs
# this block its runnability against the pre-#643 tree, which is #643 round 1's measured
# deferral reason. Only the DECLARED side is count-guarded, because a guard that declares
# no numeral at all gives the comparison nothing to bite on — UNTESTED, not agreement.
#
# The executed side matches the OPERAND, never a bare integer: the condition names
# `s156_n`, whose own digits would otherwise enter the set and make parity unsatisfiable.
s156u_set() { grep -oE '[0-9]+' | sort -un | tr '\n' ' '; }
s156u_dec=$(printf '%s\n' "$s156o_msgs" | grep -oE '(floor|ceiling)=[0-9]+' | s156u_set)
s156u_exe=$(printf '%s\n' "$s156o_cond" | grep -oE '([-](lt|gt|le|ge)|[<>]=?)[[:space:]]*[0-9]+' | s156u_set)
if [ -z "$s156o_cbound" ]; then
  ng "156u: cannot locate this suite's own 156a assertion message — declared-vs-executed parity is UNTESTED, not satisfied (#673)"
elif [ -z "$s156o_cond" ]; then
  ng "156u: §156a's executed condition could not be lifted — declared-vs-executed parity is UNTESTED, not satisfied (#673)"
elif [ -z "$s156u_dec" ]; then
  ng "156u: the guard's 156a messages declare no numeric bound — parity has nothing to compare, UNTESTED, not satisfied (#673)"
elif [ "$s156u_dec" = "$s156u_exe" ]; then
  ok "156u: the bounds §156a DECLARES agree with the numerals its condition EXECUTES (declared={ $s156u_dec} executed={ $s156u_exe}) (#673)"
else
  ng "156u: the bounds §156a DECLARES diverge from the numerals its condition EXECUTES (declared={ $s156u_dec} executed={ $s156u_exe}) — a failing reader is told a bound the guard does not apply, or a bound it applies is invisible here (#673)"
fi

# §156j — POSITIVE parity assertion: the §1.8 lever row and the §1.9 posture row
# added for the SSOT change sweep are shaped so §116's OWN derivations count them, and
# §116's parity therefore still balances. The awk/grep expressions below are
# re-derived here under an s156_ prefix rather than reading §116's s116_* variables,
# because the smoke.sh header reserves cross-section symbols for smoke.d/_preamble.sh.
#
# THEY ARE NO LONGER §116'S VERBATIM, and nothing enforces that they ever were
# (#670). An earlier revision of this comment claimed byte-identity; measured, the
# claim is false in BOTH halves — the posture window diverged at #644/#667 (§116
# moved to a shared terminator while this copy kept `/^## 2\. /`) and the lever
# window at #668/#669 (§116 moved to a title anchor). Neither divergence reddened
# anything, because no arm compares the two files: a claim of byte-identity that
# nothing checks decays silently, which is why #670 is scoped to that claim's
# ENFORCEABILITY and not only to the windows.
#
# The live consequence here is bounded and one-sided: renumbering §1.8 collapses
# this copy's lever window, so `s156_lever` reads 0 and the `ng` below reports the
# row as "mis-shaped or absent" when it is present and correctly shaped. A new
# `### 1.8.5` sibling does NOT break it — but only because the predicate counts one
# specific row rather than every `| **` row; the window itself admits the sibling
# exactly as §116's did. Tracked in #670, deliberately not repaired here. Nothing is hardcoded: expected and
# actual are both machine-derived (both are 65 at this commit — recorded here as a
# provenance note only, deliberately NOT pinned, since any of the four families may
# legitimately grow).
if [ ! -f "$S156_SPEC" ]; then
  ng "156j: SPEC.md absent — cannot assert §1.8/§1.9 SSOT-change-sweep parity (#640)"
else
  s156_lever=$(awk '/^### 1\.8 /{i=1;next} /^### 1\.9 /{exit} i' "$S156_SPEC" \
               | grep -cE '^\| \*\*SSOT change sweep\*\*')
  s156_posture=$(awk '/^### 1\.9 /{i=1;next} /^## 2\. /{exit} i' "$S156_SPEC" \
                 | grep -E '^\|.*SSOT change sweep' \
                 | grep -cE '`(cede-to-harness|keep-as-policy|keep-as-safety-redundancy)`')
  # §156j: both new rows exist AND match the exact shapes §116 counts — a lever row
  # opening `| **` (so it lands in s116_levers) and a §1.9 row carrying a BACKTICKED
  # posture token (so it lands in s116_rows). A row present but mis-shaped would keep
  # §116 balanced-looking only by cancelling out; requiring 1 of each rules that out.
  if [ "$s156_lever" = 1 ] && [ "$s156_posture" = 1 ]; then
    ok "156j: SSOT change sweep is registered as a §1.8 lever row and a backticked §1.9 posture row, in the shapes §116 counts (#640)"
  else
    ng "156j: SSOT change sweep rows mis-shaped or absent — §1.8 lever rows=$s156_lever §1.9 posture rows=$s156_posture (expected 1 and 1) (#640)"
  fi
fi

# ---------- §157: finding-judge contract + routing (SPEC §4.13, #645) ----------
# MIXED by design, and deliberately so.
#
#   CONTRACT arms (157a–157u) are GREEN-AT-DOC — the same shape §156 states at :2066,
#   NOT red-first. `.claude/agents/finding-judge.md` IS the deliverable contract SSOT
#   (SPEC §9: SPEC references the agent prompt, it does not restate it), so the Doc phase
#   already satisfies them. They exist so a later edit cannot rename a record field, drop
#   one of the three anti-swing rules, weaken a closed menu into a free-text hatch, or
#   dilute one of the load-bearing negative results.
#   ROUTING arms (157v–157x) were LOAD-BEARING RED at 58b43ee: `/review` step 3.5 and
#   `/ship` step 1.5 were the Code phase. They are GREEN from 9aa6e85 on (measured:
#   `finding-judge` refs in review.md/ship.md go 0 -> 2 across that commit) — anchored
#   rather than left present-tense, because "at this commit" goes stale the moment the
#   Code phase lands and cannot be re-checked afterwards (#673).
#
# ANTI-VACUITY. 157a count-guards the contract file — a lock over an absent or gutted file
# passes vacuously, anti-pattern #2 in the smoke.sh header. Every anti-swing arm reads a
# fixture SLICE bounded by the PAIRED literal markers `<!-- fixture:<name>:start -->` /
# `<!-- fixture:<name>:end -->`, count-guarded at 157m. A paired literal terminator needs
# no fence tracking: §156's terminator is heading-SHAPED, so a fenced `# ` comment line is
# indistinguishable from it; an HTML-comment marker pair has no such collision, and a
# fenced line cannot forge one.
#
# TWO-SIDED (Issue #645 AC "a two-sided pair per assertion"). Each of the three anti-swing
# rules carries BOTH a must-fail and a must-pass side, and all three ship together — a
# subset is not the contract. The swing-vacuity rule is paired the same way.
S157_AGENT="$SHELL_ROOT/.claude/agents/finding-judge.md"
S157_REVIEW="$SHELL_ROOT/.claude/commands/review.md"
S157_SHIP="$SHELL_ROOT/.claude/commands/ship.md"
S157_HOOK="$SHELL_ROOT/.claude/hooks/pre_tool_use.sh"

s157_n=0
[ -f "$S157_AGENT" ] && s157_n=$(grep -c . "$S157_AGENT")

# Fixed-string / ERE probes over the contract file.
s157_fx() { grep -qF "$1" "$S157_AGENT"; }
s157_re() { grep -qE "$1" "$S157_AGENT"; }
# Slice one fixture body out by its paired literal markers. `i` is set on EVERY matching
# start line and cleared on EVERY matching end line — it re-opens freely, so a stray or
# forged second marker pair DOES extend the slice. That is why §157m asserts each of the
# six markers occurs exactly once; the slice-length window alone does not catch it.
s157_slice() {
  awk -v n="$1" '
    $0 == "<!-- fixture:" n ":start -->" { i = 1; next }
    $0 == "<!-- fixture:" n ":end -->"   { i = 0 }
    i' "$S157_AGENT"
}
s157_sfx() { printf '%s\n' "$1" | grep -qF "$2"; }
s157_cnt() { printf '%s\n' "$1" | grep -c .; }

if [ ! -f "$S157_AGENT" ]; then
  ng "157: .claude/agents/finding-judge.md must exist — it is the finding-judge contract SSOT (SPEC §4.13) (#645)"
elif [ "$s157_n" -lt 120 ]; then
  # 156 non-blank lines at this commit; floor 120 catches a gutted or truncated contract
  # while tolerating ordinary prose tightening. No ceiling, and that is safe here: the
  # count spans the WHOLE file (no terminator to run away), so growth cannot make any
  # lock below vacuous — only shrinkage can (anti-swing rule 2's unbounded-end clause).
  ng "157a: the finding-judge contract file must be a whole contract (non-blank lines=$s157_n, floor=120) — the locks below would pass VACUOUSLY (#645)"
else
  ok "157a: finding-judge contract file resolves whole (non-blank lines=$s157_n) — the locks below are load-bearing (#645)"

  # §157b: the per-finding RECORD GRAMMAR, every field line-anchored to its code form
  # inside the Output fence — not a backticked prose mention. An author parses exactly
  # these lines, so a renamed or dropped field must trip here. Count-guarded: the loop
  # asserts it actually iterated all 12 patterns.
  s157_gn=0
  s157_gmiss=""
  while IFS= read -r s157_pat; do
    [ -z "$s157_pat" ] && continue
    s157_gn=$((s157_gn + 1))
    s157_re "$s157_pat" || s157_gmiss="$s157_gmiss [$s157_pat]"
  done <<'S157_GRAMMAR'
^finding: <short id> — <one-line restatement of the reviewer's finding>$
^site: <path>#<stable-anchor>$
^axis-key: <site>::<kind>$
^verdict: confirmed \| refuted$
^evidence: executed=<cmd> mode=<\.\.\.> matches-artifact-mode=<yes\|no> result=<\.\.\.>$
^action: fix-now \| defer-to-issue \| drop$
^remedy-survives: yes \| no \| n/a$
^axis: <token from the menu> \| none — discrete \(<why it is discrete>\)$
^target-position: low \| high \| interior \| n/a$
^justification: <the independent ground, or `unjustified — needs measurement`>$
^prior-round: <N>@<sha> \| none \(first round\) \| unresolved — <reason>$
^swing: none \| opposite-end \| not-evaluated \| n/a$
S157_GRAMMAR
  if [ "$s157_gn" = 12 ] && [ -z "$s157_gmiss" ]; then
    ok "157b: the judged-list record grammar carries all 12 field lines in code form (verdict/confirmed/refuted, evidence, action/fix-now/defer-to-issue/drop, remedy-survives, axis, target-position, justification, prior-round, swing) (#645)"
  else
    ng "157b: the judged-list record grammar must carry all 12 field lines in code form (patterns checked=$s157_gn expected=12, missing:$s157_gmiss) (#645)"
  fi

  # §157c: the MODE-AWARE evidence grammar. The mode enumeration and the
  # matches-artifact-mode field are the #633 lesson made structural: a wrong-mode
  # reproduction is not a measurement, so `=no` must not resolve a finding.
  if s157_fx 'mode=<script-file|bash -c|function-sourced|hook-fired|CI>' \
     && s157_fx 'matches-artifact-mode=<yes|no>' \
     && s157_fx 'A wrong-mode measurement is not a measurement' \
     && s157_fx 'matches-artifact-mode=no'; then
    ok "157c: the evidence grammar is mode-aware — mode enumeration + matches-artifact-mode, and a wrong-mode measurement resolves nothing (#645)"
  else
    ng "157c: the evidence grammar must state the mode enumeration, matches-artifact-mode, and that a wrong-mode measurement resolves nothing (#645)"
  fi

  # §157d: a refuted finding is retained, excluded from the fix list, and NEVER converted
  # into defer-to-issue — filing an issue for a false positive launders it into durable
  # memory. Locked on both the prose sentence and the Rules bullet that repeats it.
  if s157_fx 'never convertible to `defer-to-issue`' \
     && s157_fx 'Do **NOT** convert a `refuted` finding into `defer-to-issue`' \
     && s157_fx 'excluded from the fix list'; then
    ok "157d: a refuted finding is retained, excluded from the fix list, and never convertible to defer-to-issue (#645)"
  else
    ng "157d: the contract must keep refuted findings retained, fix-list-excluded, and never convertible to defer-to-issue (#645)"
  fi

  # §157e: VERDICT NON-INTERFERENCE (invariant 4) — code-reviewer's verdict grammar is
  # not the judge's to change, even when every finding under it is refuted.
  if s157_fx "You never alter \`code-reviewer\`'s verdict token" \
     && s157_fx 'A `block` stays a `block`' \
     && s157_fx "Do **NOT** alter, restate, or reinterpret \`code-reviewer\`'s verdict token"; then
    ok "157e: the judge never alters code-reviewer's verdict token — a block stays a block even when every finding in it is refuted (#645)"
  else
    ng "157e: the contract must state verdict non-interference — a block stays a block and the verdict token is never altered (#645)"
  fi

  # §157f: the axis vocabulary is a CLOSED menu whose every token names BOTH ends, which
  # is what makes target-position and "opposite end of the same axis" expressible at all.
  # Row count is measured, not assumed, so a silently emptied table fails loud.
  # Floor 8, ceiling deliberately UNBOUNDED: a ninth both-ends token would be a legitimate
  # menu extension and a ceiling would false-red on it. Safe because extra rows cannot make
  # this lock vacuous — the arm also requires the closed-menu, both-ends and discrete-hatch
  # strings, which more rows do not satisfy. (Rule 2 of the contract this file locks, applied
  # to the lock itself: a bound states both ends, or says why one end is open and why that is safe.)
  s157_axis=$(grep -cE '^\| `[a-z-]+↔[a-z-]+` \| [a-z-]+ \| [a-z-]+ \|$' "$S157_AGENT")
  if [ "$s157_axis" -ge 8 ] && s157_fx 'a closed menu' && s157_fx 'Every token names both ends' \
     && s157_fx 'no free-text axis field' && s157_fx 'axis: none — discrete'; then
    ok "157f: the axis vocabulary is a closed both-ends menu (rows=$s157_axis, low/high columns), with no free-text hatch and one discrete escape (#645)"
  else
    ng "157f: the axis vocabulary must be a closed both-ends menu with no free-text field and the discrete hatch (both-ends rows=$s157_axis, floor=8) (#645)"
  fi

  # §157g: the axis KEY is <site>::<kind> on a stable named anchor and NEVER a line
  # number — lines move between rounds, so a line-numbered key breaks cross-round matching
  # exactly when swing detection needs it.
  if s157_fx '`<site>::<kind>`' && s157_fx 'stable named anchor' && s157_fx 'Never a line number'; then
    ok "157g: the axis key is <site>::<kind> on a stable named anchor, never a line number (#645)"
  else
    ng "157g: the contract must key axes as <site>::<kind> on a stable named anchor and exclude line numbers (#645)"
  fi

  # §157h: prior-round is TRI-STATE. Collapsing it to a boolean is what makes a vacuous
  # `swing: none` possible, so all three productions are load-bearing.
  if s157_fx '`<N>@<sha>` — resolved' && s157_fx '`none (first round)` — no prior canonical marker' \
     && s157_fx '`unresolved — <reason>`'; then
    ok "157h: prior-round is tri-state — <N>@<sha> resolved / none (first round) / unresolved — <reason> (#645)"
  else
    ng "157h: prior-round must stay tri-state (<N>@<sha> / none (first round) / unresolved — <reason>) (#645)"
  fi

  # §157i: zero findings pays no judgment (invariant 8 — the acting context does not grow).
  if s157_fx 'Zero findings → stop' && s157_fx 'Return immediately'; then
    ok "157i: a review with no findings costs no judgment — the judge returns immediately (#645)"
  else
    ng "157i: the contract must skip judgment entirely on a zero-finding review (#645)"
  fi

  # §157j: DURABLE-BEFORE-FIX (invariant 15) plus the no-PR mode. The ordering binds
  # list-vs-fix; a PR-less review declares `durable: none (<mode>)` explicitly rather than
  # silently dropping the ordering.
  if s157_fx 'before the author writes any fix' && s157_fx 'may not be relaxed' \
     && s157_fx 'durable: none (<mode>)' && s157_fx 'durable: none (--staged)'; then
    ok "157j: the judged list is durable before the fix, and a no-PR mode declares durable: none (<mode>) explicitly (#645)"
  else
    ng "157j: the contract must keep durable-before-fix unrelaxable and require an explicit durable: none (<mode>) where there is no PR (#645)"
  fi

  # §157k: FAIL-OPEN, LOUDLY (invariant 14). An unavailable advisory layer degrades to
  # today's direct-to-author path; parking on it would convert an aid into a blocker.
  if s157_fx 'judgment: unavailable' && s157_fx 'Never park' && s157_fx 'audit_log warn'; then
    ok "157k: an unjudgeable round returns judgment: unavailable, the caller proceeds on the raw findings, and the judge never parks (#645)"
  else
    ng "157k: the contract must fail open with judgment: unavailable + audit_log warn and never park (#645)"
  fi

  # §157l: the enforcement-face lens is cited where it does work — P1 grounds an extreme
  # anti-swing position, P3 makes the discrete hatch observe-only. §92 asserts the bare
  # token's presence across the reviewer roster; this asserts the two principles it uses.
  if s157_fx 'SPEC §6.0 P1' && s157_fx 'SPEC §6.0 P3'; then
    ok "157l: the contract grounds its enforcement face in SPEC §6.0 — P1 for an extreme position, P3 for the observe-only discrete hatch (#645)"
  else
    ng "157l: the contract must cite SPEC §6.0 P1 (extreme-position ground) and P3 (observe-only discrete hatch) (#645)"
  fi

  # §157m: the three anti-swing FIXTURES resolve as distinct non-empty slices. BOUNDED
  # BOTH ENDS (15 lines each at this commit): the floor catches a collapsed or renamed
  # marker pair, the ceiling catches a runaway end marker that would swallow the rest of
  # the file and make every slice-scoped arm below read the whole contract instead.
  # MARKER UNIQUENESS is the load-bearing half: the length window alone passes a forged
  # duplicate pair (measured — a gutted fixture plus a forged pair at EOF left every arm
  # green, reading the forgery). Each of the six markers must occur EXACTLY once — floor
  # and ceiling both 1, because a fixture is delimited by exactly one pair by definition,
  # so a second pair is a forgery, not a variant.
  s157_mk() { grep -cxF "<!-- fixture:$1:$2 -->" "$S157_AGENT"; }
  s157_mkok=1; s157_mkwhy=""
  for s157_fxname in directional-only both-endpoints extreme-justified; do
    s157_ms=$(s157_mk "$s157_fxname" start); s157_me=$(s157_mk "$s157_fxname" end)
    if [ "$s157_ms" != 1 ] || [ "$s157_me" != 1 ]; then
      s157_mkok=0; s157_mkwhy="$s157_mkwhy $s157_fxname(start=$s157_ms,end=$s157_me)"
    fi
  done
  s157_d=$(s157_slice directional-only)
  s157_b=$(s157_slice both-endpoints)
  s157_x=$(s157_slice extreme-justified)
  s157_dn=$(s157_cnt "$s157_d"); s157_bn=$(s157_cnt "$s157_b"); s157_xn=$(s157_cnt "$s157_x")
  if [ "$s157_dn" -ge 10 ] && [ "$s157_dn" -le 40 ] \
     && [ "$s157_bn" -ge 10 ] && [ "$s157_bn" -le 40 ] \
     && [ "$s157_xn" -ge 10 ] && [ "$s157_xn" -le 40 ] \
     && [ "$s157_d" != "$s157_b" ] && [ "$s157_b" != "$s157_x" ] && [ "$s157_d" != "$s157_x" ] \
     && [ "$s157_mkok" = 1 ]; then
    ok "157m: each of the six fixture markers occurs exactly once, and the three fixtures slice out non-empty, bounded (10..40 lines: $s157_dn/$s157_bn/$s157_xn) and mutually distinct (#645)"
  else
    ng "157m: the three anti-swing fixtures must carry exactly one marker pair each and slice out bounded (10..40) and mutually distinct — got directional-only=$s157_dn both-endpoints=$s157_bn extreme-justified=$s157_xn marker-dupes=[${s157_mkwhy:- none}] (#645)"
  fi

  # ---- anti-swing rule 1 (directional-only justification) — two-sided ----
  # §157n MUST-FAIL side: a justification that is only the previous failure's direction
  # is marked unjustified and sent back for measurement, never passed through.
  if s157_sfx "$s157_d" 'unjustified — needs measurement' \
     && s157_fx 'An item whose only justification is directional is marked'; then
    ok "157n: rule 1 must-fail — a purely directional justification is marked unjustified — needs measurement and is measured, not passed through (#645)"
  else
    ng "157n: rule 1's must-fail fixture must mark a purely directional justification unjustified — needs measurement (#645)"
  fi
  # §157o MUST-PASS side: the independently-justified fixture is NOT swept up by rule 1.
  # Slice-scoped by necessity — the token is present elsewhere in the file, so a
  # whole-file negative grep could never distinguish the two sides.
  if ! s157_sfx "$s157_x" 'unjustified — needs measurement'; then
    ok "157o: rule 1 must-pass — an independently justified item carries no unjustified marker (#645)"
  else
    ng "157o: rule 1's must-pass fixture must NOT carry unjustified — needs measurement; an independent ground satisfies rule 1 (#645)"
  fi

  # ---- anti-swing rule 2 (a bound states both endpoints) — two-sided ----
  # §157p MUST-FAIL side: the rule itself states the rejection, so a one-endpoint bound
  # with no unbounded-and-safe statement has a stated verdict rather than a silent pass.
  if s157_fx 'A floor with no ceiling (or a ceiling with no floor) and no such statement fails this rule' \
     && s157_fx 'why one end is unbounded'; then
    ok "157p: rule 2 must-fail — a one-endpoint bound with no unbounded-and-safe statement fails the stated rule (#645)"
  else
    ng "157p: rule 2 must state that a one-endpoint bound lacking an unbounded-and-safe statement fails (#645)"
  fi
  # §157q MUST-PASS side: the conforming fixture states both endpoints, each with the
  # measurement it comes from, and therefore occupies the interior.
  if s157_sfx "$s157_b" 'both endpoints' && s157_sfx "$s157_b" 'floor' \
     && s157_sfx "$s157_b" 'ceiling' && s157_sfx "$s157_b" 'target-position: interior'; then
    ok "157q: rule 2 must-pass — the conforming fixture states both endpoints (floor and ceiling) and passes as fix-now (#645)"
  else
    ng "157q: rule 2's must-pass fixture must state both endpoints — floor and ceiling — of its bound (#645)"
  fi

  # ---- anti-swing rule 3 (an extreme position is permitted when justified) — two-sided ----
  # Both fixtures sit at the SAME extreme (target-position: high); only the justification
  # differs, which is precisely the distinction rule 3 draws. This is the pair invariant 16
  # names: rule 3 is not optional, and the menu of three grounds is closed.
  # §157r MUST-FAIL side: an extreme reached by the last failure's direction is unjustified.
  if s157_sfx "$s157_d" 'target-position: high' \
     && printf '%s\n' "$s157_d" | grep '^justification: ' | grep -qF 'unjustified' \
     && s157_fx "because of the last failure's direction"; then
    ok "157r: rule 3 must-fail — an extreme position justified only by the previous failure's direction is unjustified (#645)"
  else
    ng "157r: rule 3's must-fail fixture must show an extreme position reached directionally and marked unjustified (#645)"
  fi
  # §157s MUST-PASS side: the same extreme, reached by one of the three sanctioned
  # independent grounds, is permitted — the rule is not "never go to the end of the axis".
  # The `unjustified` exclusion is load-bearing, not belt-and-braces: the rule-1 marker
  # `unjustified — needs measurement` itself contains "measurement", so a ground-matching
  # grep alone would accept the very text this side must reject (caught by mutation).
  s157_xj=$(printf '%s\n' "$s157_x" | grep '^justification: ')
  if s157_sfx "$s157_x" 'target-position: high' \
     && printf '%s\n' "$s157_xj" | grep -qE 'SPEC §6\.0 P1|definitional absolute|measur' \
     && ! s157_sfx "$s157_xj" 'unjustified' \
     && s157_fx 'cost-asymmetry, a definitional absolute, or a measurement'; then
    ok "157s: rule 3 must-pass — the same extreme is permitted when justified independently (SPEC §6.0 P1 cost-asymmetry, definitional absolute, or measurement) (#645)"
  else
    ng "157s: rule 3's must-pass fixture must justify its extreme by one of the three independent grounds (#645)"
  fi

  # ---- swing vacuity — two-sided ----
  # §157t PERMITTED side: swing: none is legal only over a RESOLVED prior round, and the
  # conforming fixture pairs a resolved <N>@<sha> with it.
  if s157_fx 'is legal **only** when the prior round resolved' \
     && s157_sfx "$s157_b" 'prior-round: 2@a1b2c3d' && s157_sfx "$s157_b" 'swing: none'; then
    ok "157t: swing: none is legal only over a resolved prior round, and the fixture pairs it with prior-round: 2@a1b2c3d (#645)"
  else
    ng "157t: the contract must permit swing: none only over a resolved prior round, with a fixture pairing the two (#645)"
  fi
  # §157u FORBIDDEN side: over an unresolved prior round the verdict is not-evaluated, and
  # a swing: none there is the named vacuous pass. Asserted on the fixture too — its
  # record carries no bare `swing: none` line at all.
  if s157_fx 'is a vacuous pass' && s157_fx 'and it is forbidden' \
     && s157_sfx "$s157_x" 'prior-round: none (first round)' \
     && s157_sfx "$s157_x" 'swing: not-evaluated' \
     && ! printf '%s\n' "$s157_x" | grep -qx 'swing: none'; then
    ok "157u: an unresolved prior round yields swing: not-evaluated — a swing: none there is the forbidden vacuous pass (#645)"
  else
    ng "157u: the contract must forbid swing: none over an unresolved prior round and require swing: not-evaluated (#645)"
  fi
fi

# §157v (LOAD-BEARING RED): /review routes the findings through the judge at step 3.5 —
# after the head-pin blind-compare resolves which artifact was reviewed (step 3) and
# before the results are combined and reported to the author (step 4).
if [ ! -f "$S157_REVIEW" ]; then
  ng "157v: .claude/commands/review.md must exist to carry the step-3.5 finding-judge dispatch (#645)"
else
  s157_rv3=$(grep -n '^3\. ' "$S157_REVIEW" | head -1 | cut -d: -f1)
  s157_rv35=$(grep -n '^3\.5\. ' "$S157_REVIEW" | head -1 | cut -d: -f1)
  s157_rv4=$(grep -n '^4\. ' "$S157_REVIEW" | head -1 | cut -d: -f1)
  s157_rvblk=$(awk '/^3\.5\. /{i=1} i&&/^4\. /{exit} i' "$S157_REVIEW")
  if [ -n "$s157_rv3" ] && [ -n "$s157_rv35" ] && [ -n "$s157_rv4" ] \
     && [ "$s157_rv3" -lt "$s157_rv35" ] && [ "$s157_rv35" -lt "$s157_rv4" ] \
     && s157_sfx "$s157_rvblk" 'finding-judge'; then
    ok "157v: /review dispatches finding-judge at step 3.5, between the head-pin blind-compare (3) and combine-and-report (4) (#645)"
  else
    ng "157v: /review must dispatch finding-judge at step 3.5, between the head-pin blind-compare and combine-and-report (line 3=[$s157_rv3] 3.5=[$s157_rv35] 4=[$s157_rv4]) (#645)"
  fi
fi

# §157w (LOAD-BEARING RED): /ship routes the findings through the judge at step 1.5 —
# after code-reviewer produces them (step 1) and BEFORE the blocker stop is acted on, which
# is the whole point: judged first, then acted on.
# §157x (LOAD-BEARING RED): and the call site states the non-conversion contract — the
# judge never converts code-reviewer's verdict token, so a block still stops the ship
# however many findings under it are refuted (invariant 4).
if [ ! -f "$S157_SHIP" ]; then
  ng "157w: .claude/commands/ship.md must exist to carry the step-1.5 finding-judge dispatch (#645)"
  ng "157x: .claude/commands/ship.md must exist to carry the non-conversion contract at the judge call site (#645)"
else
  s157_sh1=$(grep -n '^1\. ' "$S157_SHIP" | head -1 | cut -d: -f1)
  s157_sh15=$(grep -n '^1\.5\. ' "$S157_SHIP" | head -1 | cut -d: -f1)
  s157_sh2=$(grep -n '^2\. ' "$S157_SHIP" | head -1 | cut -d: -f1)
  s157_shblk=$(awk '/^1\.5\. /{i=1} i&&/^2\. /{exit} i' "$S157_SHIP")
  if [ -n "$s157_sh1" ] && [ -n "$s157_sh15" ] && [ -n "$s157_sh2" ] \
     && [ "$s157_sh1" -lt "$s157_sh15" ] && [ "$s157_sh15" -lt "$s157_sh2" ] \
     && s157_sfx "$s157_shblk" 'finding-judge'; then
    ok "157w: /ship dispatches finding-judge at step 1.5, after code-reviewer and before the blocker stop is acted on (#645)"
  else
    ng "157w: /ship must dispatch finding-judge at step 1.5, between code-reviewer (1) and the security surface check (2), before the blocker stop is acted on (line 1=[$s157_sh1] 1.5=[$s157_sh15] 2=[$s157_sh2]) (#645)"
  fi
  # THREAT MODEL — read this before hardening it again. Like every content lock in §157,
  # this is a DRIFT guard, not an adversarial gate: it fires when a later edit deletes the
  # sentence or changes its meaning by accident. An author who deliberately writes the
  # inverse is NOT in scope and cannot be — a presence lock proves a sentence is there, and
  # can never prove no neighbouring sentence contradicts it (measured: appending a
  # contradicting section to the contract file leaves 157e green — an arm no round of
  # this hardening touched; 157e and this arm landed together in the Phase-B commit). Earlier rounds hardened this line against invented
  # adversarial text; that was a category error, not a defect found. Do not repeat it.
  #
  # Shape: ONE whole-sentence match, not a pile of weak probes. A four-conjunct form here
  # was measured to discriminate nothing on two of its four probes (`block` and `verdict`
  # are matched by the step-1.5 HEADER line alone), which is the accretion the bash rubric's
  # criterion 6 names. The literal runs THROUGH the terminating period — a bound with one
  # stated end and one arbitrary end is the floor-without-ceiling shape rule 2 forbids, and
  # an earlier form stopped mid-sentence. `tr -d '*'` normalizes markdown emphasis away, so
  # a cosmetic `**` move does not red; the drift this guards is semantic, not typographic.
  # Known cost, kept deliberately: a contract-preserving REWORD reds. For a drift guard that
  # is the point — the sentence is the contract, and rewording it should draw a reader.
  # That surface grew with the literal when it was extended to the terminating period
  # (90 -> 194 bytes); the trade was taken knowingly, not discovered.
  s157_shnorm=$(printf '%s\n' "$s157_shblk" | tr -d '*')
  if s157_sfx "$s157_shnorm" 'verdict token is untouched — the judge never converts it. A `block` still stops the ship, however many findings under that verdict the judge refutes; a `ship after fix` still requires the fix.'; then
    ok "157x: the /ship judge call site states the non-conversion contract — a block still stops the ship, and the judge never converts code-reviewer's verdict token (#645)"
  else
    ng "157x: the /ship step-1.5 call site must state that the judge never converts code-reviewer's verdict token and that a block still stops the ship (#645)"
  fi
fi

# §157y: inserting a fractional step RENUMBERS NOTHING — the fractional-step idiom
# (/ship's own 7.5/7.6/7.7/7.8/10.5) exists precisely so the successor numbers other
# SSOT prose cites stay valid. Every /ship step 2..11 and /review step 4 survive.
s157_renum=""
if [ -f "$S157_SHIP" ]; then
  for s157_s in 2 3 4 5 6 7 8 9 10 11; do
    grep -qE "^$s157_s\. " "$S157_SHIP" || s157_renum="$s157_renum ship:$s157_s"
  done
else
  s157_renum="$s157_renum ship:MISSING"
fi
if [ -f "$S157_REVIEW" ]; then
  grep -qE '^4\. ' "$S157_REVIEW" || s157_renum="$s157_renum review:4"
else
  s157_renum="$s157_renum review:MISSING"
fi
if [ -z "$s157_renum" ]; then
  ok "157y: the judge steps renumber no successor — /ship keeps steps 2..11 and /review keeps step 4 (#645)"
else
  ng "157y: the judge steps must renumber no successor — missing:$s157_renum (#645)"
fi

# §157z (NEGATIVE arm, invariant 3): the judge is an authoring aid, NOT a merge gate. It
# appears in no PreToolUse matcher, and the should_skip category set is unchanged — §5.29
# and the §6.1 matchers keep sole ownership of the merge gates. Both halves are measured
# (a bare absence grep would green on a missing hook file, so presence is required too).
s157_hookhit=$(grep -c 'finding-judge' "$S157_HOOK" 2>/dev/null || true)
s157_cats=$(grep -oE 'should_skip [a-z-]+' "$S157_HOOK" 2>/dev/null | awk '{print $2}' | sort -u | grep -c .)
if [ -f "$S157_HOOK" ] && [ "$s157_hookhit" = 0 ] && [ "$s157_cats" = 20 ]; then
  ok "157z: finding-judge adds no merge gate — absent from pre_tool_use.sh, should_skip categories unchanged at $s157_cats (#645)"
else
  ng "157z: finding-judge must add no merge gate — pre_tool_use.sh mentions=$s157_hookhit (expected 0), should_skip categories=$s157_cats (expected 20) (#645)"
fi

# ---------- §158: the reviewer scratch recipe is a REAL isolation primitive (#646) ----------
# SPEC §1.5 / §4.11 name a SECOND isolation axis: worktree isolation separates git TREES, it
# does not separate the session SCRATCHPAD, which every subagent of a session shares by path.
# What ships against that is a recipe inside the reviewer contracts — no helper script, by
# measured decision — so the only thing that can rot is the recipe itself. This arm therefore
# locks no PROSE: it EXTRACTS each contract's own `mktemp -d` command out of BOTH
# `.claude/agents/code-reviewer.md` and `.claude/agents/security-reviewer.md` and RUNS it,
# K-way concurrently, per contract, then asserts the property
# the contract claims for it ("`mktemp -d`'s `O_EXCL` retry is what makes two concurrent
# invocations unable to receive the same path"), plus 0700 and directory-ness. Doc↔behaviour,
# not doc↔doc: the contract's own command must actually produce what the contract advertises.
#
# WHY A GREEN HERE IS NOT A VACUOUS PASS. Because the command is read FROM the contract, this
# arm turns green the instant the Doc commit is in the tree — so its RED lives one commit
# earlier, and was verified there rather than asserted. At the pre-Doc base (269323c~1),
#   grep -n "mktemp\|scratch" .claude/agents/code-reviewer.md .claude/agents/security-reviewer.md
# returns NOTHING; the extraction below then finds no command, the K runs of `mktemp -d ""`
# all fail, and 158a fails with `collected 0 of 5` naming `extracted template=<none: ...>` —
# a LOUD count-guard failure, not a silent skip on an absent target (smoke.sh:25, anti-pattern
# #2). Reproducing the RED needs a HYBRID tree, and the obvious recipe does NOT work:
# running the suite at `269323c~1` yields SILENCE, not a red, because that tree predates the
# Test commit and so contains no §158 at all — which is itself the silent-skip shape this
# comment argues against. What reproduces it is the head's smoke file over the PRE-DOC
# contracts, in a private scratch dir (never the shared scratchpad root, per this very arm's
# subject):
#   S=$(mktemp -d "<scratch-root>/ghjig-s158-repro-XXXXXXXX")
#   git archive HEAD | tar -x -C "$S"                      # head tree, incl. this arm
#   git show 269323c~1:.claude/agents/code-reviewer.md     > "$S/.claude/agents/code-reviewer.md"
#   git show 269323c~1:.claude/agents/security-reviewer.md > "$S/.claude/agents/security-reviewer.md"
#   bash "$S/scripts/test/smoke.sh" 2>&1 | grep 158
#
# MUTATION-CHECKED (each against a tree materialised from the Doc commit; each went red):
#   code-reviewer template → `<scratch-root>/../ghjig-escapes-XXXXXXXX` → 158c (physical-path
#     residency — the printed string still prefixes the root; the resolved path does not).
#   code-reviewer template → `<scratch-root>/ghjig-code-reviewer` (no X) → 158a `collected 1
#     of 5`; BSD mktemp accepts an X-less template, so the first run wins the name and the
#     other four lose the mkdtemp race — the partial collection is the drift 158a exists to name.
#   SAME `../` escape planted in security-reviewer.md instead → 158c[security-reviewer].
#     CONTROL, measured not assumed: that identical mutation against the PREVIOUS revision of
#     this arm (which extracted from code-reviewer.md only) scored `pass=4 fail=0` — fully
#     green on a contract telling its reviewer to escape the scratch root. Locking presence
#     (158d) never covered this: the copy that could no longer be DELETED could still ROT.
#   security-reviewer template → an ABSOLUTE path outside the test root → refused by the
#     prefix gate below BEFORE execution, `find` confirming 0 directories created outside.
#     `cd "$S158_ROOT"` bounds a RELATIVE template only; mktemp ignores cwd for an absolute
#     one, so without the gate the K runs land wherever the doc says and 158c reports it only
#     after the fact. Exactly one red per fault — the gate `continue`s past this contract's
#     158a-c rather than also tripping the count-guard on the emptied template.
# Both execution-verifying contracts are locked, not just one: #646 AC2 names
# `security-reviewer` and `code-reviewer` by name, and §4.6 calls the security reviewer's
# approve the highest-cost one — so its copy of the recipe must not be silently deletable.
# Deliberately NOT a glob over `.claude/agents/*.md`: the other contracts carry no scratch
# recipe by design, and a glob would red on every future agent that legitimately has none.
S158_ALL_AGENTS=( "$SHELL_ROOT/.claude/agents/code-reviewer.md" \
                  "$SHELL_ROOT/.claude/agents/security-reviewer.md" )
S158_K=5

# 158a-c run PER CONTRACT — each named contract's own template is extracted and executed.
# The control that settles why (the same escape scoring 4/4 green when only code-reviewer.md
# was executed) is recorded once, under MUTATION-CHECKED above; not restated here.
for s158_agent in "${S158_ALL_AGENTS[@]}"; do
s158_role=$(basename "$s158_agent" .md)
S158_ROOT="$TMP/s158-scratch-root/$s158_role"  # stands in for <scratch-root>; ONLY dir written
S158_OUT="$TMP/s158-collect/$s158_role"        # per-invocation stdout, kept OUT of the root
mkdir -p "$S158_ROOT" "$S158_OUT"

# Extraction, anchored twice over. The awk window opens only on the exact `## Scratch
# discipline (#646)` heading and closes at the next `## ` heading, so no other section can
# donate a match; inside it the grep is anchored to the CODE form of the whole line
# (`^S=$(mktemp -d "…")$`), so the section's own PROSE mention of `mktemp -d` on the
# rationale line cannot satisfy it either (smoke.sh:21, anti-pattern #1).
s158_line=$(awk '/^## Scratch discipline \(#646\)$/ {i=1; next} /^## / {if (i) exit} i' \
              "$s158_agent" 2>/dev/null | grep -E '^S=\$\(mktemp -d "[^"]+"\)$' | head -n 1)
s158_tmpl=$(printf '%s\n' "$s158_line" | sed -E 's/^S=\$\(mktemp -d "([^"]+)"\)$/\1/')
s158_show="$s158_tmpl"
[ -n "$s158_show" ] || s158_show='<none: no S=$(mktemp -d "...") line under ## Scratch discipline (#646)>'
# The contract writes the placeholder `<scratch-root>`; the test supplies its own root for it.
# PREFIX GATE, before any execution: the template must be rooted at the literal placeholder.
# `cd "$S158_ROOT"` bounds a RELATIVE template only, so an absolute one would execute outside
# the test root (measured above). A legitimate contract template always starts with the
# placeholder, so this refuses nothing real; 158c is retained for the relative-`..` escape.
s158_rooted=1
case "$s158_tmpl" in '<scratch-root>/'*) ;; *) s158_rooted=0 ;; esac
if [ -n "$s158_tmpl" ] && [ "$s158_rooted" = 0 ]; then
  ng "158a[$s158_role]: the extracted template must be rooted at the literal <scratch-root>/ before it is executed — got $s158_show; refusing to run it (#646)"
  continue   # one red per fault: skip this contract's 158a-c rather than also red the count-guard
fi
s158_cmd="${s158_tmpl//<scratch-root>/$S158_ROOT}"

# K concurrent invocations of exactly that command. Each subshell runs INSIDE $S158_ROOT, so
# even a template that lost its placeholder (and would therefore resolve relative) cannot
# write outside the test's own temp root; 158c then reports the relative path it produced.
s158_i=1
while [ "$s158_i" -le "$S158_K" ]; do
  ( cd "$S158_ROOT" && mktemp -d "$s158_cmd" ) >"$S158_OUT/out.$s158_i" 2>/dev/null &
  s158_i=$((s158_i + 1))
done
wait

s158_got=$(cat "$S158_OUT"/out.* 2>/dev/null)
s158_n=$(printf '%s\n' "$s158_got" | grep -c .)

# §158a COUNT-GUARD. Without it an extraction that finds nothing collects nothing, and both
# limbs below ("all distinct", "all 0700") are trivially true over the empty set.
if [ "$s158_n" -ne "$S158_K" ]; then
  ng "158a[$s158_role]: the mktemp -d command extracted from $s158_role.md '## Scratch discipline (#646)' must mint $S158_K paths under $S158_K concurrent runs — collected $s158_n of $S158_K; extracted template=$s158_show — 158b/158c below would pass VACUOUSLY (#646)"
else
  ok "158a[$s158_role]: the contract's own mktemp -d command ran $S158_K ways concurrently and collected $s158_n of $S158_K paths (template=$s158_show) — 158b/158c are load-bearing (#646)"

  # §158b: the paired limb of the contract's own claim — two concurrent invocations do not
  # receive the same path. The guarantee is mktemp's O_EXCL retry, which is exactly why the
  # contract says to use the primitive rather than invent a name; this measures it under
  # contention, where a hand-rolled `$$`/timestamp name is at its weakest.
  s158_u=$(printf '%s\n' "$s158_got" | sort -u | grep -c .)
  if [ "$s158_u" -eq "$S158_K" ]; then
    ok "158b[$s158_role]: $S158_K concurrent invocations received $s158_u distinct paths — no two agents collide (#646)"
  else
    s158_dup=$(printf '%s\n' "$s158_got" | sort | uniq -d | tr '\n' ' ')
    ng "158b[$s158_role]: $S158_K concurrent invocations must receive $S158_K distinct paths — sort -u yielded $s158_u; repeated:$s158_dup (#646)"
  fi

  # §158c: each minted path is a DIRECTORY, mode 700, and lands under the root the test
  # supplied for `<scratch-root>`. 0700 is what makes the dir private; residency is what makes
  # the placeholder substitution real rather than decorative. Residency is measured on the
  # PHYSICAL path (`cd … && pwd -P`), never on the printed string: a template carrying a `..`
  # component still string-prefixes the root while landing outside it, and a prefix-only test
  # passes it (mutation-checked above). Loop count-guarded so an empty read cannot report all-N.
  s158_rootreal=$(cd "$S158_ROOT" 2>/dev/null && pwd -P)
  s158_seen=0
  s158_bad=""
  while IFS= read -r s158_p; do
    [ -z "$s158_p" ] && continue
    s158_seen=$((s158_seen + 1))
    if [ ! -d "$s158_p" ]; then
      s158_bad="$s158_bad [$s158_p: not a directory]"
      continue
    fi
    s158_real=$(cd "$s158_p" 2>/dev/null && pwd -P)
    case "$s158_real" in
      "$s158_rootreal"/*) ;;
      *) s158_bad="$s158_bad [$s158_p: resolves outside, to ${s158_real:-?}]"; continue ;;
    esac
    s158_mode=$(stat -c '%a' "$s158_p" 2>/dev/null || stat -f '%OLp' "$s158_p" 2>/dev/null || printf '?')
    [ "$s158_mode" = 700 ] || s158_bad="$s158_bad [$s158_p: mode $s158_mode]"
  done <<S158_PATHS
$s158_got
S158_PATHS
  if [ "$s158_seen" -eq "$S158_K" ] && [ -z "$s158_bad" ]; then
    ok "158c[$s158_role]: all $s158_seen minted paths are mode-700 directories under the supplied <scratch-root> (#646)"
  else
    ng "158c[$s158_role]: every minted path must be a mode-700 directory under $S158_ROOT — checked $s158_seen of $S158_K, offenders:$s158_bad (#646)"
  fi
fi
done  # per-contract loop (F-1): 158a-c asserted once per named contract, not once total

# §158d (coverage lock — the recipe must be present in BOTH execution-verifying contracts).
# 158a-c now execute BOTH contracts' templates, so a deleted section already reds there (the
# extraction returns nothing and 158a's count-guard fires). This arm is still not redundant:
# it separates ABSENCE from BREAKAGE — a section deleted from security-reviewer.md and one
# whose template merely stopped working produce the same 158a red, and only this arm says
# which. It also names an ABSENT FILE loudly instead of grepping to zero and passing, and it
# is the only arm that would catch a SECOND heading or a SECOND template (a duplicated recipe
# that 158a's `head -n 1` would silently read past).
s158d_miss=""
s158d_n=0
for s158d_f in "${S158_ALL_AGENTS[@]}"; do
  s158d_n=$(( s158d_n + 1 ))
  s158d_base=$(basename "$s158d_f")
  if [ ! -f "$s158d_f" ]; then
    s158d_miss="$s158d_miss ${s158d_base}=ABSENT"
    continue
  fi
  s158d_h=$(grep -c '^## Scratch discipline (#646)$' "$s158d_f" 2>/dev/null || true)
  s158d_t=$(awk '/^## Scratch discipline \(#646\)$/{f=1;next} /^## /{f=0} f' "$s158d_f" 2>/dev/null \
              | grep -cE '^S=\$\(mktemp -d "[^"]+"\)$' || true)
  [ "$s158d_h" = 1 ] || s158d_miss="$s158d_miss ${s158d_base}=headings:${s158d_h}"
  [ "$s158d_t" = 1 ] || s158d_miss="$s158d_miss ${s158d_base}=templates:${s158d_t}"
done
if [ "$s158d_n" -eq 2 ] && [ -z "$s158d_miss" ]; then
  ok "158d: both execution-verifying contracts carry the scratch recipe — one heading and one extractable template each, checked $s158d_n of 2 (#646)"
else
  ng "158d: every execution-verifying contract must carry exactly one '## Scratch discipline (#646)' heading and one mktemp -d template — checked $s158d_n of 2, offenders:$s158d_miss (#646)"
fi


# ---------- §174: citation resolution at the attributed site (#676) ----------
# SPEC §1.10 states the evidence discipline for durable-artifact bodies. Part (a)
# — the only mechanized half — says a quoted span resolves in the FILE it is
# attributed to, so a real string hung on a file that does not contain it is a
# site-mismatch and not a pass. scripts/lint_citations.sh is the born-advisory
# reader of that half: it extracts a proposed body's quoted spans, reports per
# span the search it ran and the outcome, and always exits 0.
#
# §174a is a Doc lock over SPEC §1.10. §174b-§174h exercise the reader through its
# public interface (argv path in, report on stdout, status out) against the
# committed fixture body and throwaway repos — no internals, no mocking. Each arm
# is guarded so an absent checker or fixture fails CLEANLY as ng, never a hard
# error. §174e-§174h are the #677 review round: the printed search must reproduce
# its own result, the attributed path must stay inside the repository, a closed
# pipe must not turn the advisory posture into a 141, and the normalising rung
# must not stall on a large file.
#
# The discriminator is §174b's site-mismatch assertion: an existence-anywhere
# check passes that span (the wording is real, it just lives in CHANGELOG.md) and
# therefore fails this arm. A reader that greens §174b is doing the job the rule
# names; one that greens every other arm and reds this one is not.
S174_SPEC="$SHELL_ROOT/SPEC.md"
S174_CHECKER="$SHELL_ROOT/scripts/lint_citations.sh"
S174_FX="$SHELL_ROOT/scripts/test/fixtures/citation/proposed-issue-body.md"
S174_ABSENT="$SHELL_ROOT/scripts/test/fixtures/citation/no-such-body.md"
S174_CMDS=("$SHELL_ROOT/.claude/commands/file-directive.md" "$SHELL_ROOT/.claude/commands/file-issue.md")

# §174a (DOC LOCK, AC4): SPEC §1.10 exists and states BOTH parts with their
# load-bearing halves — (a) resolution at the attributed file plus the
# site-mismatch case that motivates it, (b) the literal command AND its literal
# output, with the extent rule (neither broader nor narrower). A §1.10 that kept
# the heading and lost either part's operative clause reds here.
if [ ! -f "$S174_SPEC" ]; then
  ng "174a: SPEC.md absent — cannot lock the §1.10 evidence discipline (#676)"
elif grep -qF '### 1.10 Evidence discipline for durable-artifact bodies' "$S174_SPEC" \
   && grep -qF '**(a) A quotation resolves in the file it is attributed to.**' "$S174_SPEC" \
   && grep -qF 'site-mismatch' "$S174_SPEC" \
   && grep -qF '**(b) A corpus-quantified claim carries the literal command and its literal output.**' "$S174_SPEC" \
   && grep -qF 'neither broader nor narrower' "$S174_SPEC"; then
  ok "174a: SPEC §1.10 states both parts — (a) resolution at the attributed file incl. site-mismatch, (b) literal command + output, neither broader nor narrower (#676)"
else
  ng "174a: SPEC §1.10 must carry the heading, part (a) with the site-mismatch case, and part (b) with the neither-broader-nor-narrower extent rule (#676)"
fi

# §174b (CHECKER DEMONSTRATION, AC2/AC3/AC6 — the load-bearing arm): the reader's
# per-span classification of the committed fixture body. Asserted as counts by
# class: stdout carries one report line per span for EVERY class except
# `no-attribution`, whose spans are GROUPED into a single line, and nothing else
# on stdout carries a class token.
#   - exactly ONE site-mismatch, and it names scripts/lint_bash_idioms.sh (the real
#     wording that lives only in CHANGELOG.md) — the AC-6 discriminator;
#   - exactly ONE unresolved, and it names .claude/agents/issue-reviewer.md (the
#     fabricated span). Exactly one, because the fixture's two silent bounds — the
#     sub-four-word span and the span inside the fenced block — each add a second
#     defect line when the four-word floor or the fence exclusion is dropped (the
#     first as a second unresolved, the second as a second site-mismatch);
#   - at least TWO resolves: the plain-delimited span and the star-delimited one, so
#     dropping either delimiter form reds;
#   - the GitHub-attributed span reported unresolvable-locally and the unattributed
#     one no-attribution — both non-defect classes, which is why the defect counts
#     above are 1 and not 2 or 3;
#   - every reported span backed by an indented `search:` line carrying the literal
#     invocation that produced it — `git grep -F` on rungs 1, 3 and 4 (AC1: report
#     the search, not just the verdict); rung 2's own search is asserted by §174e;
#   - the fenced draft line never extracted.
if [ ! -f "$S174_FX" ]; then
  ng "174b: citation fixture body absent ($S174_FX) — the per-span classification is unmeasured (#676)"
elif [ ! -f "$S174_CHECKER" ]; then
  ng "174b: scripts/lint_citations.sh absent — the per-span classification of the fixture body is unmeasured (#676)"
else
  s174b_out="$(bash "$S174_CHECKER" "$S174_FX" 2>/dev/null)"
  s174b_mm=$(printf '%s\n' "$s174b_out" | grep -cF 'site-mismatch' || true)
  s174b_mm_site=$(printf '%s\n' "$s174b_out" | grep -F 'site-mismatch' | grep -cF 'scripts/lint_bash_idioms.sh' || true)
  s174b_un=$(printf '%s\n' "$s174b_out" | grep -cw 'unresolved' || true)
  s174b_un_site=$(printf '%s\n' "$s174b_out" | grep -w 'unresolved' | grep -cF '.claude/agents/issue-reviewer.md' || true)
  s174b_res=$(printf '%s\n' "$s174b_out" | grep -cw 'resolves' || true)
  s174b_gh=$(printf '%s\n' "$s174b_out" | grep -cF 'unresolvable-locally' || true)
  s174b_na=$(printf '%s\n' "$s174b_out" | grep -cF 'no-attribution' || true)
  s174b_search=$(printf '%s\n' "$s174b_out" | grep -cE '^[[:space:]]+search:.*git grep -F' || true)
  s174b_fenced=$(printf '%s\n' "$s174b_out" | grep -cF 'the wording blended from two sources in the parked draft' || true)
  if [ "$s174b_mm" -eq 1 ] && [ "$s174b_mm_site" -eq 1 ] \
     && [ "$s174b_un" -eq 1 ] && [ "$s174b_un_site" -eq 1 ] \
     && [ "$s174b_res" -ge 2 ] && [ "$s174b_gh" -ge 1 ] && [ "$s174b_na" -ge 1 ] \
     && [ "$s174b_search" -ge 1 ] && [ "$s174b_fenced" -eq 0 ]; then
    ok "174b: lint_citations.sh classifies the fixture per span — 1 site-mismatch at lint_bash_idioms.sh, 1 unresolved at issue-reviewer.md, both clean spans resolve, GitHub-attributed and unattributed spans stay non-defects, fenced text unread (#676)"
  else
    ng "174b: the fixture body must report exactly one site-mismatch (at scripts/lint_bash_idioms.sh) and one unresolved (at .claude/agents/issue-reviewer.md), >=2 resolves, >=1 unresolvable-locally, >=1 no-attribution, >=1 indented 'search:' git grep -F line, and 0 hits from the fenced block — got site-mismatch=$s174b_mm/site=$s174b_mm_site unresolved=$s174b_un/site=$s174b_un_site resolves=$s174b_res unresolvable-locally=$s174b_gh no-attribution=$s174b_na search=$s174b_search fenced=$s174b_fenced (#676)"
  fi
fi

# §174c (ADVISORY POSTURE, AC1/AC3): the reader is born advisory — status 0 on a
# body it has findings about AND status 0 on input it cannot read, where the
# unreadable case still says so with a `fail-open` sentinel rather than going
# silent. A caller can therefore never be gated by it, and a silent no-op can
# never be mistaken for a clean body.
if [ ! -f "$S174_FX" ]; then
  ng "174c: citation fixture body absent ($S174_FX) — the always-exit-0 posture is unmeasured (#676)"
elif [ ! -f "$S174_CHECKER" ]; then
  ng "174c: scripts/lint_citations.sh absent — the always-exit-0 + fail-open-sentinel posture is unmeasured (#676)"
else
  bash "$S174_CHECKER" "$S174_FX" >/dev/null 2>&1; s174c_rc_fx=$?
  s174c_absent_out="$(bash "$S174_CHECKER" "$S174_ABSENT" 2>&1)"; s174c_rc_absent=$?
  s174c_sentinel=$(printf '%s\n' "$s174c_absent_out" | grep -cF 'fail-open' || true)
  if [ "$s174c_rc_fx" -eq 0 ] && [ "$s174c_rc_absent" -eq 0 ] && [ "$s174c_sentinel" -ge 1 ]; then
    ok "174c: lint_citations.sh exits 0 on a body carrying defects and on unreadable input, and marks the unreadable case with a fail-open sentinel (#676)"
  else
    ng "174c: the reader must exit 0 on both the fixture and a nonexistent path and print a 'fail-open' sentinel for the unreadable one — got rc(fixture)=$s174c_rc_fx rc(absent)=$s174c_rc_absent sentinel=$s174c_sentinel (#676)"
  fi
fi

# §174d (WIRING LOCK, AC5): both authoring commands run the reader on the proposed
# body BEFORE their reviewer gate, and say the report is advisory. Asserted
# positionally rather than by a hardcoded step label: the step number in effect at
# the lint_citations.sh mention must sort numerically BELOW the step number of the
# 'Reviewer gate' step in the same file (/file-directive gates at 2, /file-issue at
# 4), so renumbering the procedure keeps the arm true while moving the check after
# the gate reds it. A count-guard pins that BOTH command files were read.
s174d_bad=""
s174d_n=0
for s174d_f in "${S174_CMDS[@]}"; do
  s174d_base=$(basename "$s174d_f")
  s174d_n=$(( s174d_n + 1 ))
  if [ ! -f "$s174d_f" ]; then
    s174d_bad="$s174d_bad ${s174d_base}=ABSENT"
    continue
  fi
  # cite = step in effect where lint_citations.sh is first named; gate = step of the
  # reviewer gate; adv = the citation step states the advisory posture.
  s174d_scan=$(awk '
    {
      if (match($0, /^[0-9]+(\.[0-9]+)*\./)) {
        step = substr($0, RSTART, RLENGTH - 1)
        if (inblk && step != cite) inblk = 0
        cur = step
      }
      if (cite == "" && index($0, "lint_citations.sh") > 0) { cite = cur; inblk = 1 }
      if (inblk && $0 ~ /[Aa]dvisory/) adv = 1
      if (gate == "" && index($0, "Reviewer gate") > 0) gate = cur
    }
    END { printf "%s|%s|%s\n", cite, gate, (adv ? "adv" : "noadv") }
  ' "$s174d_f")
  s174d_cite=${s174d_scan%%|*}
  s174d_rest=${s174d_scan#*|}
  s174d_gate=${s174d_rest%%|*}
  s174d_adv=${s174d_rest#*|}
  if [ -z "$s174d_cite" ]; then
    s174d_bad="$s174d_bad ${s174d_base}=no-citation-step"
  elif [ -z "$s174d_gate" ]; then
    s174d_bad="$s174d_bad ${s174d_base}=no-reviewer-gate-step"
  elif ! awk -v a="$s174d_cite" -v b="$s174d_gate" 'BEGIN { exit !(a + 0 < b + 0) }'; then
    s174d_bad="$s174d_bad ${s174d_base}=step${s174d_cite}-not-before-gate${s174d_gate}"
  elif [ "$s174d_adv" != "adv" ]; then
    s174d_bad="$s174d_bad ${s174d_base}=step${s174d_cite}-silent-on-advisory"
  fi
done
if [ "$s174d_n" -eq 2 ] && [ -z "$s174d_bad" ]; then
  ok "174d: /file-directive and /file-issue both run lint_citations.sh at a step numbered below their reviewer gate, stating the report is advisory — checked $s174d_n of 2 (#676)"
else
  ng "174d: each authoring command must name lint_citations.sh at a step numbered below its 'Reviewer gate' step and state the report is advisory — checked $s174d_n of 2, offenders:$s174d_bad (#676)"
fi

# §174e (THE PRINTED SEARCH REPRODUCES ITS OWN RESULT, #677): `normalized` is the
# one rung whose search is not a `git grep`, and its report used to print rung 1's
# `git grep` — a command that by construction returns NOTHING, since control
# reaches rung 2 only because that grep came back empty. So this arm does not read
# the printed command, it RUNS it: the fixture's `normalized` line names a file and
# a line number, and its own `search:` line, eval'd from the repo root, must print
# that same number. The fixture carries the span (a wording lint_bash_idioms.sh
# holds only across a line wrap) so the class is exercised at all — without it the
# rung is untested and a non-reproducing search ships green.
if [ ! -f "$S174_FX" ]; then
  ng "174e: citation fixture body absent ($S174_FX) — the normalized rung and its printed search are unmeasured (PR #677)"
elif [ ! -f "$S174_CHECKER" ]; then
  ng "174e: scripts/lint_citations.sh absent — the normalized rung and its printed search are unmeasured (PR #677)"
else
  s174e_out="$(bash "$S174_CHECKER" "$S174_FX" 2>/dev/null)"
  s174e_n=$(printf '%s\n' "$s174e_out" | grep -cF ': normalized — ' || true)
  s174e_rep=$(printf '%s\n' "$s174e_out" | grep -F ': normalized — ' | head -n 1)
  s174e_site=$(printf '%s\n' "$s174e_rep" | sed -E 's/^.*: normalized — ([^ :]+):([0-9]+).*$/\1/')
  s174e_lno=$(printf '%s\n' "$s174e_rep" | sed -E 's/^.*: normalized — ([^ :]+):([0-9]+).*$/\2/')
  s174e_cmd=$(printf '%s\n' "$s174e_out" \
    | awk '/: normalized — /{ getline; sub(/^[[:space:]]*search: /, ""); print; exit }')
  s174e_rerun=""
  if [ -n "$s174e_cmd" ]; then
    s174e_rerun=$( ( cd "$SHELL_ROOT" && eval "$s174e_cmd" ) 2>/dev/null | head -n 1)
  fi
  if [ "$s174e_n" -eq 1 ] && [ "$s174e_site" = "scripts/lint_bash_idioms.sh" ] \
     && [ -n "$s174e_lno" ] && [ "$s174e_rerun" = "$s174e_lno" ]; then
    ok "174e: the fixture exercises the normalized rung once (at scripts/lint_bash_idioms.sh:$s174e_lno) and its printed search, re-run verbatim, returns that same line — the report states a search that reproduces it (PR #677)"
  else
    ng "174e: the fixture must report exactly one normalized span at scripts/lint_bash_idioms.sh whose printed 'search:' command, re-run from the repo root, prints the reported line — got n=$s174e_n site=$s174e_site line=$s174e_lno rerun=$s174e_rerun (PR #677)"
  fi
fi

# §174f (THE ATTRIBUTED PATH STAYS INSIDE THE TRACKED REPOSITORY, #677): three
# attributions built in a throwaway repo, each carrying the SAME span verbatim at
# the place it points to, and none of which the reader may resolve or normalise:
#   - a `..` traversal to a file outside the repository. Rung 2 read the attributed
#     file directly, so a body could confirm guesses about any readable path on the
#     machine ("does this file contain X?"). Must be refused BEFORE the read.
#   - an untracked file, present in the tree. Rung 1 (git grep) sees only tracked
#     files, so the verbatim span missed there and rung 2's direct read then
#     reported `normalized` — a normalisation that never happened.
#   - git pathspec magic in the attribution. As a rung-1 pathspec it INVERTED the
#     search into "everywhere but this file" and reported `resolves` for a span
#     living somewhere else entirely.
# All three must land on `unresolvable-locally` — a non-defect, so a benign
# attribution is never converted into a false defect either.
S174F_DIR=$(mktemp -d)
S174F_WORK="$S174F_DIR/work"
S174F_SPAN="the boundary probe span carried verbatim at every attributed site"
mkdir -p "$S174F_WORK"
printf '%s\n' "$S174F_SPAN" > "$S174F_DIR/outside.md"
git init -q "$S174F_WORK" 2>/dev/null
(
  cd "$S174F_WORK" || exit 1
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  printf '%s\n' "$S174F_SPAN" > tracked.md
  printf '%s\n' "$S174F_SPAN" > elsewhere.md
  printf '%s\n' "$S174F_SPAN" > untracked.md
  : > ':(exclude,top)tracked.md'
  git add tracked.md elsewhere.md >/dev/null 2>&1
  git commit -q -m seed >/dev/null 2>&1
) >/dev/null 2>&1
{
  printf '# boundary probe\n\n'
  printf -- '- `../outside.md` states *"%s"* — outside the repository.\n' "$S174F_SPAN"
  printf -- '- `untracked.md` states *"%s"* — present but untracked.\n' "$S174F_SPAN"
  printf -- '- `:(exclude,top)tracked.md` states *"%s"* — pathspec magic.\n' "$S174F_SPAN"
} > "$S174F_WORK/probe.md"
if [ ! -f "$S174_CHECKER" ]; then
  ng "174f: scripts/lint_citations.sh absent — the repository-boundary posture is unmeasured (PR #677)"
else
  s174f_out="$(bash "$S174_CHECKER" "$S174F_WORK/probe.md" 2>/dev/null)"
  s174f_remote=$(printf '%s\n' "$s174f_out" | grep -cF 'unresolvable-locally' || true)
  s174f_leak=$(printf '%s\n' "$s174f_out" | grep -cE 'normalized|resolves|site-mismatch|unresolved' || true)
  s174f_untracked=$(printf '%s\n' "$s174f_out" | grep -cF 'the working tree carries but git does not track' || true)
  if [ "$s174f_remote" -eq 3 ] && [ "$s174f_leak" -eq 0 ] && [ "$s174f_untracked" -eq 1 ]; then
    ok "174f: a traversal, an untracked file and a pathspec-magic attribution all report unresolvable-locally — nothing outside the tracked repository is read, and the untracked case names its own reason instead of claiming a normalisation (PR #677)"
  else
    ng "174f: the three out-of-corpus attributions must all report unresolvable-locally with no resolves/normalized/site-mismatch/unresolved line, and the untracked one must say so — got unresolvable-locally=$s174f_remote leaked-classes=$s174f_leak untracked-worded=$s174f_untracked (PR #677)"
  fi
fi
rm -rf "$S174F_DIR"

# §174g (ADVISORY POSTURE SURVIVES A CLOSED PIPE, #677): §174c measures the UNPIPED
# invocation only, and the reader died of SIGPIPE with status 141 the moment a
# caller read part of the report and stopped (a `head -n 2` on the pipe) — the
# exit-0 guarantee four artifacts assert, broken by the most ordinary way to read a
# long report.
if [ ! -f "$S174_FX" ] || [ ! -f "$S174_CHECKER" ]; then
  ng "174g: fixture or checker absent — the closed-pipe exit status is unmeasured (PR #677)"
else
  bash "$S174_CHECKER" "$S174_FX" 2>/dev/null | head -n 2 >/dev/null
  s174g_rc=${PIPESTATUS[0]}
  if [ "$s174g_rc" -eq 0 ]; then
    ok "174g: the reader still exits 0 when the caller closes the pipe after two lines — SIGPIPE never turns the advisory posture into a 141 (PR #677)"
  else
    ng "174g: a piped invocation truncated after two lines must still exit 0 — got $s174g_rc (PR #677)"
  fi
fi

# §174h (THE NORMALISING RUNG IS BOUNDED, #677): rung 2 joined the WHOLE attributed
# file into one awk string, one concatenation per line — quadratic, with no size cap
# and no timeout. A body citing a large tracked artifact plus a phrase it does not
# carry stalled the caller for minutes with no human present (measured: 9.6 MB → over
# 10 minutes). The scan is now a sliding window, linear in file size. The bound below
# is deliberately loose (a 4 MB file, 20 s) — it separates linear from quadratic by
# more than an order of magnitude without pinning machine speed.
S174H_DIR=$(mktemp -d)
S174H_WORK="$S174H_DIR/work"
mkdir -p "$S174H_WORK"
git init -q "$S174H_WORK" 2>/dev/null
(
  cd "$S174H_WORK" || exit 1
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  awk 'BEGIN { for (i = 0; i < 60000; i++) print "line " i " of a large generated lock-like artifact with filler words" }' > big.md
  git add big.md >/dev/null 2>&1
  git commit -q -m seed >/dev/null 2>&1
) >/dev/null 2>&1
printf '# size probe\n\n- `big.md` states *"a phrase this large artifact does not carry at all"* — absent.\n' > "$S174H_WORK/probe.md"
if [ ! -f "$S174_CHECKER" ]; then
  ng "174h: scripts/lint_citations.sh absent — the normalising rung's cost is unmeasured (PR #677)"
else
  s174h_t0=$SECONDS
  s174h_out="$(bash "$S174_CHECKER" "$S174H_WORK/probe.md" 2>/dev/null)"
  s174h_el=$(( SECONDS - s174h_t0 ))
  s174h_cls=$(printf '%s\n' "$s174h_out" | grep -cw 'unresolved' || true)
  if [ "$s174h_el" -lt 20 ] && [ "$s174h_cls" -eq 1 ]; then
    ok "174h: a span absent from a 4 MB tracked file is classified in ${s174h_el}s — the normalising rung scans linearly instead of stalling the caller (PR #677)"
  else
    ng "174h: the normalising rung must finish a 4 MB tracked file well under 20s and still report the span unresolved — took ${s174h_el}s, unresolved=$s174h_cls (PR #677)"
  fi
fi
rm -rf "$S174H_DIR"
