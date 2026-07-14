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

