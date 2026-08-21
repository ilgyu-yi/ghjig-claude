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

# §148h-p4 (LOAD-BEARING RED until Code, #655): every reject arm reachable by a plausible HONEST
# MISTAKE carries its own recovery clause on EVERY one of its call sites, in the shape the `stale`
# arm already uses (SPEC §6.0 P4, arm-scoped; §5.29 the authoritative arm set).
#
# What the predicate actually tests — AC4 option (a), corrected: it tests EM-DASH PRESENCE on the
# deny site, NOT that the clause is a well-formed instruction and NOT that it is a genuine recovery. The
# predicate cannot discriminate a recovery from a bare explanation: `deny mtime-changed` carries an
# em dash followed by an EXPLANATION ("the freshness check would not cover the posted bytes"), not
# a recovery, and this predicate would count it as satisfied. It does not claim to tell the two
# apart — em-dash presence is the machine-checkable floor, the recovery WORDING is a human-review
# obligation. The paired §148h-p4-cmt arm pins THIS comment against the predicate: the comment must
# name em-dash presence and must not re-introduce the false clause-shape claim the old comment
# carried, so the comment and the code cannot silently re-drift apart.
#
# The honest-mistake SET IS DERIVED, not hardcoded: it is parsed out of the §5.29 enumeration
# sentence (lead-in `The honest-mistake arms, each carrying a recovery clause:`, cut at the first
# em dash, backticked tokens only — the §148h-doc idiom). The twin-exempt set is parsed the same
# way from the `over-length twin sites of` sentence. A twin-exempt arm needs the clause on ≥1 site
# (its length-bound twin may stay bare); every other honest-mistake arm needs it on ALL sites.
# Iteration is PER CALL SITE (every non-comment `deny <arm>` line), not once per arm name, so a
# clause-bearing first site cannot mask a bare second one (limb 1).
#
# Anti-vacuity floor (B1, plan-reviewer must-graft): the derived set must be NON-EMPTY and must
# contain the sentinels `stale` AND `now-malformed`, else the check fails closed with the distinct
# token <honest-mistake-enumeration-degenerate>. This defends against a reworded / de-backticked
# §5.29 body that empties the derived set → zero iterations → vacuous green. The sentinel is a
# FLOOR, not the inventory, so AC2's add-a-name mutation still grows the set and still bites.
#
# The predicate takes a (spec-source, wrapper-target) pair, so the same code runs over the live
# wrapper (the real lock) and over the §148h-p4-{ac3b,ac6,vac} fixtures below.
S148_P4_SELF="${BASH_SOURCE[0]}"
S148_P4_FIX="$SHELL_ROOT/scripts/test/fixtures/file-review-post"

s148h_p4_derive_hm() {  # $1=spec-source; prints space-joined honest-mistake arm names, or nothing
  _p4src="$1"
  _p4ln=$(grep -nF 'The honest-mistake arms, each carrying a recovery clause:' "$_p4src" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$_p4ln" ] || return 0
  sed -n "${_p4ln}p" "$_p4src" \
    | sed 's/.*The honest-mistake arms, each carrying a recovery clause://' \
    | sed 's/—.*//' \
    | grep -oE '`[a-z][a-z-]*`' | tr -d '`' | tr '\n' ' '
}
s148h_p4_derive_twin() {  # $1=spec-source; prints space-joined twin-exempt arm names, or nothing
  _p4src="$1"
  _p4ln=$(grep -nF 'over-length twin sites of' "$_p4src" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$_p4ln" ] || return 0
  sed -n "${_p4ln}p" "$_p4src" \
    | sed 's/.*over-length twin sites of//' \
    | sed 's/ stay bare.*//' \
    | grep -oE '`[a-z][a-z-]*`' | tr -d '`' | tr '\n' ' '
}
s148h_p4_sitecheck() {  # $1=wrapper-target $2=hm-set $3=twin-set; prints arms bare on a required site
  _p4tgt="$1"; _p4hm="$2"; _p4tw="$3"; _p4miss=""
  for _p4arm in $_p4hm; do
    _p4sites=$(grep -nE "deny $_p4arm " "$_p4tgt" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#')
    [ -n "$_p4sites" ] || continue
    _p4total=$(printf '%s\n' "$_p4sites" | grep -c .)
    _p4clause=$(printf '%s\n' "$_p4sites" | grep -c '—')
    _p4twin=0
    for _p4t in $_p4tw; do [ "$_p4t" = "$_p4arm" ] && _p4twin=1; done
    if [ "$_p4twin" = 1 ]; then
      [ "$_p4clause" -ge 1 ] || _p4miss="$_p4miss $_p4arm"
    else
      [ "$_p4clause" -eq "$_p4total" ] || _p4miss="$_p4miss $_p4arm"
    fi
  done
  printf '%s' "$_p4miss"
}
s148h_p4_check() {  # $1=spec-source $2=wrapper-target; prints FLOOR:<tok> | MISS:<arms> | OK
  _p4hm=$(s148h_p4_derive_hm "$1"); _p4tw=$(s148h_p4_derive_twin "$1")
  _p4stale=0; _p4now=0
  for _p4a in $_p4hm; do
    [ "$_p4a" = stale ] && _p4stale=1
    [ "$_p4a" = now-malformed ] && _p4now=1
  done
  if [ -z "$_p4hm" ] || [ "$_p4stale" = 0 ] || [ "$_p4now" = 0 ]; then
    printf 'FLOOR:<honest-mistake-enumeration-degenerate>'; return
  fi
  _p4m=$(s148h_p4_sitecheck "$2" "$_p4hm" "$_p4tw")
  if [ -n "$_p4m" ]; then printf 'MISS:%s' "$_p4m"; else printf 'OK'; fi
}

# §148h-p4: the live lock — derive from the real SPEC, check every site of the real wrapper.
s148h_p4_live=$(s148h_p4_check "$SHELL_ROOT/SPEC.md" "$S148_WRAP_FILE")
if [ "$s148h_p4_live" = OK ]; then
  ok "148h-p4: every honest-mistake reject arm carries its recovery clause on all required sites (derived set sound); symlink arms stay terse as hostile input (#655)"
else
  ng "148h-p4: each honest-mistake arm must carry the em-dash recovery clause on every required site, in the shape 'stale' uses ($s148h_p4_live) (#655)"
fi

# §148h-p4-vac (B1 anti-vacuity floor): derive from the de-backticked fixture (anchor present, set
# empty) — the floor must red with its distinct token, never fall through to a vacuous green.
s148h_p4_vac=$(s148h_p4_check "$S148_P4_FIX/vacuity-debackticked.md" "$S148_WRAP_FILE")
if [ "$s148h_p4_vac" = 'FLOOR:<honest-mistake-enumeration-degenerate>' ]; then
  ok "148h-p4-vac: an emptied §5.29 enumeration (anchor present, no backticked names) trips the anti-vacuity floor, not a silent green (#655)"
else
  ng "148h-p4-vac: a de-backticked enumeration must trip the floor token, got '$s148h_p4_vac' (#655)"
fi

# §148h-p4-ac3b (per-site liveness, RED side): a non-exempt arm with one clause site + one bare
# site must red — proving the per-site check bites off the live wrapper too.
s148h_p4_ac3b=$(s148h_p4_check "$SHELL_ROOT/SPEC.md" "$S148_P4_FIX/ac3b-partial-clause.sh")
if [ "$s148h_p4_ac3b" = 'MISS: mtime-unresolvable' ]; then
  ok "148h-p4-ac3b: a non-exempt honest-mistake arm with a bare second site reds the per-site predicate (#655)"
else
  ng "148h-p4-ac3b: a clause-bearing first site must not mask a bare second site, expected MISS: mtime-unresolvable, got '$s148h_p4_ac3b' (#655)"
fi

# §148h-p4-ac6 (symlink-exclusion, GREEN side): bare symlink arms and nothing else — must stay
# green through the predicate, since symlink arms are outside the derived honest-mistake set.
s148h_p4_ac6=$(s148h_p4_check "$SHELL_ROOT/SPEC.md" "$S148_P4_FIX/ac6-symlink-bare.sh")
if [ "$s148h_p4_ac6" = OK ]; then
  ok "148h-p4-ac6: bare symlink arms are not swept into the recovery obligation — predicate stays green (#655)"
else
  ng "148h-p4-ac6: symlink arms must be excluded from the honest-mistake set, got '$s148h_p4_ac6' (#655)"
fi

# §148h-p4-cmt (AC4 comment-vs-predicate self-pin): the §148h-p4 case comment must state what the
# predicate tests — em-dash presence — and must NOT claim the clause is an imperative (the false
# claim the old comment carried), so comment and code cannot re-drift apart.
s148h_p4_cmt=$(awk '/^# §148h-p4 \(LOAD-BEARING/{f=1} f&&/^#/{print} f&&!/^#/{exit}' "$S148_P4_SELF")
s148h_p4_cmt_ok=1
printf '%s' "$s148h_p4_cmt" | grep -qiE 'em[ -]dash' || s148h_p4_cmt_ok=0
printf '%s' "$s148h_p4_cmt" | grep -qi 'imperative' && s148h_p4_cmt_ok=0
if [ "$s148h_p4_cmt_ok" = 1 ]; then
  ok "148h-p4-cmt: the §148h-p4 comment names em-dash presence as the tested property and drops the false 'imperative' claim (#655)"
else
  ng "148h-p4-cmt: the §148h-p4 comment must say 'em dash' and must not claim 'imperative' (#655)"
fi

# §148h-p4-p4lock (AC5, §148h-ttl2 shape): SPEC §6.0 P4 carries the classification sentence's two
# byte strings — the gate-level rule and its arm-level reading. Pins §6.0 P4, not #659's surface.
if grep -qF 'never ship a bare gate' "$SHELL_ROOT/SPEC.md" 2>/dev/null \
   && grep -qF 'never leave an honest-mistake arm bare' "$SHELL_ROOT/SPEC.md" 2>/dev/null; then
  ok "148h-p4-p4lock: SPEC §6.0 P4 states 'never ship a bare gate' and its arm-level reading 'never leave an honest-mistake arm bare' (#655)"
else
  ng "148h-p4-p4lock: SPEC §6.0 P4 must carry both 'never ship a bare gate' and 'never leave an honest-mistake arm bare' (#655)"
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

# §148h-ttl3 (Doc-phase-confirming — GREEN since the Doc commit, #656 AC3): the TTL fall-open
# taxonomy relocated out of escape.sh's inline rationale now lives under SPEC's new sub-section
# `### 7.1 TTL operand validation: the fall-open taxonomy`. This limb pins the two load-bearing
# sentences that #635 got wrong so a reword REDs — built in the §148h-doc anti-vacuity idiom, NOT
# a bare whole-file grep -qF.
#   ANCHOR, fail-closed. The `### 7.1 …` heading is the anchor, occurrence count == 1. Absent =>
#     RED <ttl3-anchor-absent>; duplicated => RED <ttl3-anchor-not-unique>. Never a silent
#     whole-file fallback: without a unique anchor the four substrings below could be satisfied by
#     narration anywhere in SPEC, so the anchor failing closed is the whole point.
#   SCOPE. The check runs over the §7.1 region only — from the heading to the next `### `/`## `
#     heading (awk-cut) — so a matching phrase elsewhere in SPEC cannot green this limb.
#   FOUR SUBSTRINGS, name-which-reddens. Two sentences, two literals each; the message names the
#     specific missing substring, never just "red":
#     LOW-1 (symptom) — `splits the two comparisons into two` AND `leading-zero epochs containing
#       an 8 or 9`: the corrected reach set (only leading-zero epochs with an 8 or 9 fall open in
#       escape.sh, because the wrapper splits the two comparisons where escape.sh joins them).
#     INFO-4 (cause / measurement mode) — `script-file mode` AND `set -uo pipefail`: the meta-claim
#       #635 got wrong twice; locked alongside LOW-1 by plan-reviewer mandate.
s148h_ttl3_hdr='### 7.1 TTL operand validation: the fall-open taxonomy'
s148h_ttl3_n=$(grep -cF "$s148h_ttl3_hdr" "$SHELL_ROOT/SPEC.md" 2>/dev/null)
s148h_ttl3_miss=""
if [ "${s148h_ttl3_n:-0}" = 0 ]; then
  s148h_ttl3_miss=" <ttl3-anchor-absent>"
elif [ "$s148h_ttl3_n" != 1 ]; then
  s148h_ttl3_miss=" <ttl3-anchor-not-unique>"
else
  s148h_ttl3_region=$(awk -v h="$s148h_ttl3_hdr" \
    '$0==h{f=1;next} f&&/^(### |## )/{exit} f{print}' "$SHELL_ROOT/SPEC.md" 2>/dev/null)
  printf '%s' "$s148h_ttl3_region" | grep -qF 'splits the two comparisons into two' \
    || s148h_ttl3_miss="$s148h_ttl3_miss <LOW-1:splits-the-two-comparisons-into-two>"
  printf '%s' "$s148h_ttl3_region" | grep -qF 'leading-zero epochs containing an 8 or 9' \
    || s148h_ttl3_miss="$s148h_ttl3_miss <LOW-1:leading-zero-epochs-containing-an-8-or-9>"
  printf '%s' "$s148h_ttl3_region" | grep -qF 'script-file mode' \
    || s148h_ttl3_miss="$s148h_ttl3_miss <INFO-4:script-file-mode>"
  printf '%s' "$s148h_ttl3_region" | grep -qF 'set -uo pipefail' \
    || s148h_ttl3_miss="$s148h_ttl3_miss <INFO-4:set--uo-pipefail>"
fi
if [ -z "$s148h_ttl3_miss" ]; then
  ok "148h-ttl3: SPEC §7.1 pins the LOW-1 symptom (split comparisons, the 8-or-9 leading-zero reach set) and the INFO-4 measurement mode (script-file mode under set -uo pipefail), scoped to the §7.1 region (#656)"
else
  ng "148h-ttl3: SPEC §7.1 must carry both the LOW-1 symptom and the INFO-4 measurement-mode clauses (missing:$s148h_ttl3_miss) (#656)"
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
s148i_defs=$(ghjig_grep_claude_defs '^[[:space:]]*ghjig_state_dir_cli[[:space:]]*\(\)' "$SHELL_ROOT/.claude" "$SHELL_ROOT/scripts")
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

# §148i-decoy (LOAD-BEARING RED until Code, #642): §148i-cli's tree-wide def-form scan greps the
# WHOLE $SHELL_ROOT/.claude tree, which includes .claude/worktrees/agent-*/ — full repo COPIES a
# worktree-isolated subagent makes (SPEC §1.5, §4.5). A copy of hookrt.sh there carries a genuine
# `ghjig_state_dir_cli()` def-form line, so while any such subagent is live the naive `grep -r`
# double-counts and §148i-cli reds — count=2 though the source tree is fine. This arm plants
# exactly that decoy at the real worktrees path, re-runs §148i-cli's OWN detection expression
# verbatim, and asserts it STILL counts exactly 1: the worktree copy must be EXCLUDED. Pre-fix
# (no exclusion) it counts 2 and reds; Phase C's shared worktrees-exclusion greens it. Anti-
# vacuity: the decoy must actually exist (made=1) and a real non-worktree hookrt.sh def must still
# be found (realfound=1), so a broken fixture reds as untested rather than passing on count=1.
S148I_DECOY_WT="$SHELL_ROOT/.claude/worktrees/agent-decoy"
S148I_DECOY_F="$S148I_DECOY_WT/.claude/hooks/hookrt.sh"
mkdir -p "$S148I_DECOY_WT/.claude/hooks"
printf '%s\n' 'ghjig_state_dir_cli() { :; }' > "$S148I_DECOY_F" 2>/dev/null
s148i_decoy_made=0; [ -f "$S148I_DECOY_F" ] && s148i_decoy_made=1
s148i_decoy_defs=$(ghjig_grep_claude_defs '^[[:space:]]*ghjig_state_dir_cli[[:space:]]*\(\)' "$SHELL_ROOT/.claude" "$SHELL_ROOT/scripts")
s148i_decoy_count=$(printf '%s\n' "$s148i_decoy_defs" | grep -c . )
s148i_decoy_realfound=0
printf '%s\n' "$s148i_decoy_defs" | grep 'hookrt\.sh$' | grep -qv '/worktrees/' && s148i_decoy_realfound=1
rm -rf "$S148I_DECOY_WT"
if [ "$s148i_decoy_made" = 1 ] && [ "$s148i_decoy_realfound" = 1 ] && [ "$s148i_decoy_count" = 1 ]; then
  ok "148i-decoy: §148i-cli's def-form scan excludes .claude/worktrees/agent-*/ copies — a live worktree-isolated subagent can no longer false-red the single-def lock (count=$s148i_decoy_count) (#642)"
else
  ng "148i-decoy: §148i-cli's def-form scan must exclude .claude/worktrees/ — a worktree copy of hookrt.sh double-counts ghjig_state_dir_cli (made=$s148i_decoy_made realfound=$s148i_decoy_realfound count=$s148i_decoy_count want 1) (#642)"
fi

# §148i-neg (paired negative — must stay GREEN both before and after the fix, #642): the
# worktrees-exclusion must not BLIND the original single-def check. A genuine SECOND
# ghjig_state_dir_cli() definition placed OUTSIDE .claude/worktrees/ must still push the count
# past 1. Constructed over a controlled $TMP fixture (never the live tree): two def-form files at
# ordinary, non-worktree paths. §148i-cli's OWN detection expression, run over the fixture, must
# count BOTH (==2). Anti-vacuity: both fixture files must exist and the count is pinned to exactly
# 2 — a fix that over-broadly prunes real source (or a grep that breaks) drops below 2 and reds.
S148I_NEG_DIR="$TMP/s148i-neg"
mkdir -p "$S148I_NEG_DIR/.claude/hooks" "$S148I_NEG_DIR/scripts/helpers"
printf '%s\n' 'ghjig_state_dir_cli() { :; }' > "$S148I_NEG_DIR/.claude/hooks/hookrt.sh"
printf '%s\n' 'ghjig_state_dir_cli() { :; }' > "$S148I_NEG_DIR/scripts/helpers/rogue.sh"
s148i_neg_made=0
[ -f "$S148I_NEG_DIR/.claude/hooks/hookrt.sh" ] && [ -f "$S148I_NEG_DIR/scripts/helpers/rogue.sh" ] && s148i_neg_made=1
s148i_neg_defs=$(ghjig_grep_claude_defs '^[[:space:]]*ghjig_state_dir_cli[[:space:]]*\(\)' "$S148I_NEG_DIR/.claude" "$S148I_NEG_DIR/scripts")
s148i_neg_count=$(printf '%s\n' "$s148i_neg_defs" | grep -c . )
if [ "$s148i_neg_made" = 1 ] && [ "$s148i_neg_count" = 2 ]; then
  ok "148i-neg: a genuine second ghjig_state_dir_cli() def OUTSIDE worktrees still counts>1 — the exclusion never blinds the original single-def check (count=$s148i_neg_count) (#642)"
else
  ng "148i-neg: two real def-forms outside .claude/worktrees/ must both be counted (made=$s148i_neg_made count=$s148i_neg_count want 2) (#642)"
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
# THE SHARED CONTRACT (#670). Byte-identity is the wrong thing to claim — it decayed
# twice unnoticed, which is why #670 is scoped to ENFORCEABILITY. What these two
# windows must agree ABOUT is stated once, here and at the §116 definitions, as two
# rules:
#
#   START RULE    — a window opens on the SECTION'S TITLE, never on its number
#                   (#668). A number is not a stable id: renumbering collapses the
#                   window silently, and a collapsed window reports "row absent"
#                   when the row is present.
#   TERMINATOR    — a window closes on the SHARED terminator `^## |^### `, never on
#                   a hand-picked next-heading literal (#644). `#### ` is NOT a
#                   terminator (position 3 is `#`, not a space), so a genuine
#                   sub-section stays in scope.
#
# Measured at this commit, BOTH halves of this copy violate the start rule and the
# posture half also violates the terminator rule:
#   lever   — opens `/^### 1\.8 /`, closes `/^### 1\.9 /`   (§116: title anchor +
#             shared terminator, hardened at #668/#669)
#   posture — opens `/^### 1\.9 /`, closes `/^## 2\. /`      (§116: SAME number-based
#             start, shared terminator)
#
# So the posture halves do NOT diverge on the start anchor — §116's posture opens on
# a number too, and measured, IT COLLAPSES ON A RENUMBER EXACTLY AS THIS COPY DOES
# (66 -> 0). #670's own table reads as if only this copy were fragile there; it is
# not. Hardening §116's posture is #670-out-of-scope, and the shared residual is
# disclosed here rather than silently inherited.
#
# THE TWO HALVES ARE THEREFORE HELD DIFFERENTLY, and Phase A got this wrong by saying
# this copy is held to agreement "rather than ahead of it" for both. It cannot be, for
# the posture half: #670 also requires this copy's posture to survive a §1.9 renumber,
# so once that holds this copy is AHEAD of §116's posture helper by exactly the residual
# above, and a posture-vs-posture comparison would red on the two LEGITIMATELY differing.
#   lever   — held to AGREEMENT with §116 (§156v), where both conform.
#   posture — held as a renumber BOUND on this copy alone (§156x), not as agreement.
# The arms below are what make any future divergence loud instead of silent.
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
  s156_lever=$(awk '/^### .*[Ii]n-session narrowing levers/{i=1;next} i&&/^## |^### /{exit} i' "$S156_SPEC" \
               | grep -cE '^\| \*\*SSOT change sweep\*\*')
  s156_posture=$(awk '/^### .*Harness-overlap classification/{i=1;next} i&&/^## |^### /{exit} i' "$S156_SPEC" \
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

# ---------- §156v-§156y: §156j's windows vs §116's — agreement + renumber bounds (#670) ----
# WHAT THESE FOUR ARMS ARE FOR. §156j above re-derives §116's two SPEC windows under an
# `s156_` prefix (it must — smoke.sh's header reserves cross-section symbols for
# _preamble.sh). The two copies diverged twice, in PRs that had no reason to look at this
# file, and NOTHING NOTICED. That silence is #670's subject; these arms are the mechanism
# that ends it.
#
# THE CONTRACT UNDER TEST is the one stated at §156j above and at the §116 definitions in
# 50-perproject-recall.sh — two rules, not a byte-identity claim:
#   START RULE — a window opens on the SECTION'S TITLE, never on its number (#668).
#   TERMINATOR — a window closes on the shared `^## |^### `, never on a hand-picked
#                next-heading literal (#644).
#
# RED AT THIS COMMIT, deliberately (Doc -> Test -> Code). Measured here:
#   156v  RED   — §156j's lever window collapses where §116's stays open
#   156w  RED   — §156j's §1.8 lever window reads 0 on a §1.8 renumber (expected 1)
#   156x  RED   — §156j's §1.9 posture window reads 0 on a §1.9 renumber (expected 1)
#   156y  GREEN — the bound below; it is SUPPOSED to be green here (see §156y)
#
# NO LIVE SPEC MUTATION. Every fixture is a copy under the preamble's $TMP, removed by its
# EXIT trap. $S156_SPEC is opened for reading and `cp` only, never written (#670 AC5).
#
# NO THIRD COPY OF THE RULE. Neither §116's regexes nor §156j's are re-spelled here: both
# sides are LIFTED from their own source files and RUN over shared fixtures, so what is
# compared is BEHAVIOUR, not text. A third hand-copy would be one more instance of exactly
# the defect #670 exists to remove. Same technique, and for the same reason, as §156o/§156s
# above — including its BOUNDED search: each lift is confined to the lines ahead of its
# section's first assertion message, so no lift can ever pick up an anchor-shaped line
# belonging to a DIFFERENT arm (§156o's measured lesson: unbounded, its condition lift
# returned §156r's line and every verdict below it said nothing about the guard).
#
# WHY THE LIFTED §116 DEFINITIONS ARE UNSET BEFORE THEY ARE EVAL'd. 50-perproject-recall.sh
# is sourced into THIS shell, so `s116_lever_rows` is already defined when we get here.
# Calling it would (a) violate the header's cross-section reservation and (b) — much worse —
# make a FAILED lift invisible, because the live definition would answer in its place and
# the arm would go green having tested nothing. Each runner therefore unsets the three
# symbols in its subshell first; a lift that returned nothing then yields an empty answer,
# which every arm reads as UNTESTED.
#
# WHY EVERY ARM CARRIES A SAME-INPUT POSITIVE CONTROL. On 156v/156w/156x the fail-closed
# answer (a collapsed window -> 0) is the FAILING one. So a fixture that silently did not
# take reads as the healthy value and GREENS the very arm it was built to red — vacuity in
# the direction that looks like success. Marker-based controls, never count-based: the count
# is the thing under test, so validating the fixture by its count would be circular (§156o's
# renamed-fixture note makes the same point).
#
# MEASURED COST (#670 AC3(ii)). These four arms add ~0.21s wall clock to the suite (three
# runs: 0.23 / 0.21 / 0.21, against a ~160s whole-suite baseline): one `cp` of SPEC.md plus
# two awk rewrites of the resulting ~2.9k-line file, and 12 lifted-derivation runs over the
# three copies. No network, no git, no hook fires, and zero false reds over the suite's
# existing fixtures (measured: the whole-suite assertion set is byte-identical outside these
# four lines). Recorded here rather than in a PR comment because this is where the next
# editor of these two windows will be.
#
# UNCOVERED BY CONSTRUCTION, disclosed rather than mitigated:
#   (a) The TERMINATOR half is not separately witnessed. Measured on a fixture with §2's
#       heading renumbered (`## 2. ` -> `## 20. `), §156j's posture window over-runs its
#       hand-picked `/^## 2\. /` terminator to EOF and the count does NOT move (1 -> 1):
#       the predicate matches one row and there is no second candidate downstream. The
#       divergence is real and unobservable through this predicate, and widening the
#       predicate is #670-out-of-scope. §156v covers the terminator only insofar as a
#       terminator change alters window OPENNESS.
#   (b) §156v compares the two sides on the base and §1.8-renumber fixtures ONLY. The
#       §1.9-renumber fixture is deliberately EXCLUDED: `s116_posture_rows` still opens on
#       the literal `### 1.9 ` and collapses there itself (measured 66 -> 0), a KNOWN
#       residual that 50-perproject-recall.sh records and that #670 puts out of scope. Once
#       §156x is satisfied, §156j's posture is AHEAD of §116's on that fixture, and folding
#       it into the agreement signature would red on the two sides legitimately differing.
#       §156x, not §156v, is what holds the posture start-anchor.
S156V_JSRC="$SHELL_ROOT/scripts/test/smoke.d/70-gates-contentlocks.sh"
S156V_HSRC="$SHELL_ROOT/scripts/test/smoke.d/50-perproject-recall.sh"
S156V_DIR="$TMP/s156v"
# The two §156j variable names, named ONCE: each anchor below is built from the name, so
# the anchor and the name it looks for cannot drift apart.
S156V_LNAME="s156_lever"
S156V_PNAME="s156_posture"

# s156v_stmt <src> <bound> <anchor-re> -> the ONE logical statement that starts at the first
# line matching <anchor-re> within the first <bound> lines, backslash continuations joined.
# Statement-shaped rather than regex-shaped on purpose: it survives §156j being rewritten to
# `awk -v endre=...`, which a lift of the awk PROGRAM alone would not. Empty on a miss.
s156v_stmt() {
  head -n "$2" "$1" 2>/dev/null | awk -v re="$3" '
    !c && $0 ~ re { c = 1 }
    c { print; if ($0 !~ /\\$/) exit }'
}

# s156v_block <src> <bound> <open-re> -> the function definition opening at the first line
# matching <open-re> within the first <bound> lines, through its closing column-0 `}`.
s156v_block() {
  head -n "$2" "$1" 2>/dev/null | awk -v re="$3" '
    !c && $0 ~ re { c = 1 }
    c { print; if ($0 == "}") exit }'
}

# The bounds, and they are not the same shape on the two sides — each is the FIRST
# assertion message that sits BELOW everything its lift needs, which is what makes the
# search unable to reach any other arm.
#
#   §156j side — bounded by §156v's OWN first message, i.e. the top of this block. §156j's
#     first message is NOT usable: it is the `ng` in the `[ ! -f "$S156_SPEC" ]` arm, which
#     sits ABOVE the two assignments, so bounding there cuts the lift off entirely
#     (measured: both lifts returned empty and all four arms below reported UNTESTED).
#     Recorded because the failure was silent in the only way that matters here — it did
#     not crash, it fell straight into the fail-closed branch and looked like a verdict.
#   §116 side — bounded by §116's first message, which sits below all three definitions.
s156v_jb=$(grep -n -m1 -E '^[[:space:]]*(ok|ng) "156v:' "$S156V_JSRC" 2>/dev/null | cut -d: -f1)
s156v_hb=$(grep -n -m1 -E '^[[:space:]]*(ok|ng) "116:' "$S156V_HSRC" 2>/dev/null | cut -d: -f1)
s156v_jlever=""
s156v_jpost=""
s156v_hend=""
s156v_hlev=""
s156v_hpos=""
if [ -f "$S156V_JSRC" ] && [ -n "${s156v_jb:-}" ]; then
  s156v_jlever=$(s156v_stmt "$S156V_JSRC" "$s156v_jb" "^[[:space:]]*$S156V_LNAME=")
  s156v_jpost=$(s156v_stmt "$S156V_JSRC" "$s156v_jb" "^[[:space:]]*$S156V_PNAME=")
fi
if [ -f "$S156V_HSRC" ] && [ -n "${s156v_hb:-}" ]; then
  # DOUBLE-ESCAPED, and that is not a typo: `awk -v` performs escape processing and strips
  # one backslash level, so `\\(` here is the `\(` the ERE engine must see. The greps
  # around it are single-escaped because grep does no such processing. The asymmetry is
  # load-bearing; single-escaping these would make `()` an empty group and the anchor would
  # silently match nothing.
  s156v_hend=$(s156v_stmt "$S156V_HSRC" "$s156v_hb" '^S116_END_RE=')
  s156v_hlev=$(s156v_block "$S156V_HSRC" "$s156v_hb" '^s116_lever_rows\\(\\) \\{$')
  s156v_hpos=$(s156v_block "$S156V_HSRC" "$s156v_hb" '^s116_posture_rows\\(\\) \\{$')
fi
s156v_hdefs=""
if [ -n "$s156v_hend" ] && [ -n "$s156v_hlev" ] && [ -n "$s156v_hpos" ]; then
  s156v_hdefs="$s156v_hend
$s156v_hlev
$s156v_hpos"
fi

# s156v_jrun <fixture> <lifted-stmt> <varname> -> what §156j's OWN statement produces
# against that fixture; empty if it could not be run. The variable is unset inside the
# subshell first, so an empty lift cannot fall through to the live §156j value.
s156v_jrun() {
  local __v="$3"
  ( unset "$__v"; S156_SPEC="$1"; eval "$2"; printf '%s\n' "${!__v-}" ) 2>/dev/null
}

# s156v_hrun <fixture> <fn-name> -> what §116's OWN definition produces against that
# fixture; empty if it could not be run. See the unset rationale in the header comment.
s156v_hrun() {
  ( unset -f s116_lever_rows s116_posture_rows
    unset S116_END_RE
    eval "$s156v_hdefs"
    "$2" "$1" ) 2>/dev/null
}

# s156v_bit <count> -> `1` open, `0` collapsed, `x` NOT MEASURED. The third value keeps a
# lift or fixture failure from reading as a collapsed window, or as agreement.
s156v_bit() {
  case "$1" in
    ''|*[!0-9]*) printf 'x' ;;
    0)           printf '0' ;;
    *)           printf '1' ;;
  esac
}

# Fixtures. Two renumbers of the real SPEC, each into a number SPEC does not already use.
# The targets (§1.42 / §1.43) are deliberately synthetic and MUST stay unused by SPEC — the
# guard below fails loud if SPEC ever grows them. §1.10 was the original target and collided
# once #676 added a real `### 1.10 ` heading (rebase staleness), which left every arm below
# reading UNTESTED; hence numbers far outside the live range.
s156v_base="$S156V_DIR/base.md"
s156v_lv="$S156V_DIR/lever-renum.md"
s156v_pt="$S156V_DIR/posture-renum.md"
s156v_fx=""
s156v_lvok=0
s156v_ptok=0
if [ -f "$S156_SPEC" ] && mkdir -p "$S156V_DIR" 2>/dev/null \
   && cp "$S156_SPEC" "$s156v_base" 2>/dev/null && cmp -s "$S156_SPEC" "$s156v_base" \
   && ! grep -q '^### 1\.42 ' "$s156v_base" && ! grep -q '^### 1\.43 ' "$s156v_base"; then
  s156v_fx=ok
  awk '{sub(/^### 1\.8 /, "### 1.42 "); print}' "$s156v_base" > "$s156v_lv" 2>/dev/null
  awk '{sub(/^### 1\.9 /, "### 1.43 "); print}' "$s156v_base" > "$s156v_pt" 2>/dev/null
  s156v_bl=$(wc -l < "$s156v_base" | tr -d ' ')
  s156v_brow=$(grep -c 'SSOT change sweep' "$s156v_base")
  # MARKER-BASED, never count-based (see the header note). Four conditions per fixture:
  # the new number arrived, the old number is gone, nothing else moved (line count), and
  # the counted row survived the rewrite.
  if [ -s "$s156v_lv" ] \
     && grep -q '^### 1\.42 ' "$s156v_lv" && ! grep -q '^### 1\.8 ' "$s156v_lv" \
     && [ "$(wc -l < "$s156v_lv" | tr -d ' ')" = "$s156v_bl" ] \
     && [ "$(grep -c 'SSOT change sweep' "$s156v_lv")" = "$s156v_brow" ]; then
    s156v_lvok=1
  fi
  if [ -s "$s156v_pt" ] \
     && grep -q '^### 1\.43 ' "$s156v_pt" && ! grep -q '^### 1\.9 ' "$s156v_pt" \
     && [ "$(wc -l < "$s156v_pt" | tr -d ' ')" = "$s156v_bl" ] \
     && [ "$(grep -c 'SSOT change sweep' "$s156v_pt")" = "$s156v_brow" ]; then
    s156v_ptok=1
  fi
fi

# Openness signatures over the SHARED fixture set {base, §1.8-renumber}, one pair of bits
# per fixture: §156j's lever/posture on the left, §116's on the right.
s156v_sig=""
s156v_ref=""
if [ "$s156v_fx" = ok ] && [ "$s156v_lvok" = 1 ] \
   && [ -n "$s156v_jlever" ] && [ -n "$s156v_jpost" ] && [ -n "$s156v_hdefs" ]; then
  for s156v_f in "$s156v_base" "$s156v_lv"; do
    s156v_sig="$s156v_sig$(s156v_bit "$(s156v_jrun "$s156v_f" "$s156v_jlever" "$S156V_LNAME")")"
    s156v_sig="$s156v_sig$(s156v_bit "$(s156v_jrun "$s156v_f" "$s156v_jpost" "$S156V_PNAME")") "
    s156v_ref="$s156v_ref$(s156v_bit "$(s156v_hrun "$s156v_f" s116_lever_rows)")"
    s156v_ref="$s156v_ref$(s156v_bit "$(s156v_hrun "$s156v_f" s116_posture_rows)") "
  done
fi

# §156v — THE AGREEMENT ARM (#670 AC3). This is the arm the Issue exists for: it reds when
# §156j's windows and §116's stop agreeing, without either side's rule being restated here.
if [ -z "$s156v_jlever" ] || [ -z "$s156v_jpost" ]; then
  ng "156v: §156j's own window statements could not be lifted from this file — agreement with §116 is UNTESTED, not satisfied (#670)"
elif [ -z "$s156v_hdefs" ]; then
  ng "156v: §116's window definitions could not be lifted from 50-perproject-recall.sh — agreement is UNTESTED, not satisfied (#670)"
elif [ "$s156v_fx" != ok ] || [ "$s156v_lvok" != 1 ]; then
  ng "156v: the shared §1.8-renumber fixture did not take — a fixture that never moved would green this arm, so it reds as UNTESTED (#670)"
elif [ -z "$s156v_ref" ] || [ "${s156v_ref#*[0x]}" != "$s156v_ref" ]; then
  ng "156v: §116's reference windows did not stay open over the shared fixtures (§116=${s156v_ref:-<none>}) — there is nothing to compare against, UNTESTED (#670)"
elif [ "$s156v_sig" = "$s156v_ref" ]; then
  ok "156v: §156j's windows open where §116's open over the shared fixtures (§156j='$s156v_sig' §116='$s156v_ref' over base,§1.8-renumber) (#670)"
else
  ng "156v: §156j's windows have STOPPED AGREEING with §116's (§156j='$s156v_sig' §116='$s156v_ref', lever/posture bits over base,§1.8-renumber; a 0 is a collapsed window) — §156j will blame the row for a window failure (#670)"
fi

# §156w — §156j's §1.8 lever window survives a §1.8 renumber (#670 AC1). The control is the
# SAME lifted statement on the unmodified copy: if it cannot read 1 there, this arm's
# verdict on the renumbered copy says nothing.
s156v_wb=$(s156v_jrun "$s156v_base" "$s156v_jlever" "$S156V_LNAME")
s156v_wl=$(s156v_jrun "$s156v_lv" "$s156v_jlever" "$S156V_LNAME")
if [ -z "$s156v_jlever" ] || [ "$s156v_fx" != ok ]; then
  ng "156w: §156j's §1.8 lever statement could not be lifted, or the SPEC copy was not made — the renumber bound is UNTESTED, not satisfied (#670)"
elif [ "$s156v_lvok" != 1 ]; then
  ng "156w: the §1.8-renumber fixture did not take — an unrenumbered copy still reads 1 and would GREEN this arm, so it reds as UNTESTED (#670)"
elif [ "$s156v_wb" != 1 ]; then
  ng "156w: §156j's lever window reads '${s156v_wb:-<none>}' on an UNMODIFIED SPEC copy (expected 1) — the control fails, so the renumber verdict says nothing (#670)"
elif [ "$s156v_wl" = 1 ]; then
  ok "156w: §156j's §1.8 lever window survives a §1.8 renumber (rows=$s156v_wl on the renumbered copy, $s156v_wb unmodified) — it opens on the section TITLE, not its number (#668, #670)"
else
  ng "156w: §156j's §1.8 lever window COLLAPSES on a §1.8 renumber (rows='${s156v_wl:-<none>}', expected 1; unmodified=$s156v_wb) — §156j then reports the SSOT-change-sweep row 'mis-shaped or absent' while it is present and correctly shaped (#668, #670)"
fi

# §156x — §156j's §1.9 posture window survives a §1.9 renumber (#670 AC1/AC6). Same shape
# and same control as §156w. This is the half that diverged FIRST (#644) and is equally
# unenforced; see note (b) in the header for why §156v cannot carry it.
s156v_xb=$(s156v_jrun "$s156v_base" "$s156v_jpost" "$S156V_PNAME")
s156v_xp=$(s156v_jrun "$s156v_pt" "$s156v_jpost" "$S156V_PNAME")
if [ -z "$s156v_jpost" ] || [ "$s156v_fx" != ok ]; then
  ng "156x: §156j's §1.9 posture statement could not be lifted, or the SPEC copy was not made — the renumber bound is UNTESTED, not satisfied (#670)"
elif [ "$s156v_ptok" != 1 ]; then
  ng "156x: the §1.9-renumber fixture did not take — an unrenumbered copy still reads 1 and would GREEN this arm, so it reds as UNTESTED (#670)"
elif [ "$s156v_xb" != 1 ]; then
  ng "156x: §156j's posture window reads '${s156v_xb:-<none>}' on an UNMODIFIED SPEC copy (expected 1) — the control fails, so the renumber verdict says nothing (#670)"
elif [ "$s156v_xp" = 1 ]; then
  ok "156x: §156j's §1.9 posture window survives a §1.9 renumber (rows=$s156v_xp on the renumbered copy, $s156v_xb unmodified) — it opens on the section TITLE, not its number (#644, #668, #670)"
else
  ng "156x: §156j's §1.9 posture window COLLAPSES on a §1.9 renumber (rows='${s156v_xp:-<none>}', expected 1; unmodified=$s156v_xb) — §156j then reports the SSOT-change-sweep row 'mis-shaped or absent' while it is present and correctly shaped (#644, #670)"
fi

# §156y — A BOUND, NOT A WITNESS (#670 AC4), and labelled as such because the distinction is
# the whole reason it exists. This arm PASSES at the Test commit; it witnesses no defect and
# discharges no repair. It pins the direction that must NOT change while §156w/§156x are
# repaired: on an UNMODIFIED SPEC, §156j's two windows still read exactly 1 and 1. A window
# widened until it opens on anything would satisfy §156v/§156w/§156x and break this.
if [ -z "$s156v_jlever" ] || [ -z "$s156v_jpost" ]; then
  ng "156y: §156j's window statements could not be lifted — the unmodified-SPEC bound is UNTESTED, not satisfied (#670)"
elif [ "$s156v_fx" != ok ]; then
  ng "156y: no byte-identical SPEC copy was made under \$TMP — the unmodified-SPEC bound is UNTESTED, not satisfied (#670)"
elif [ "$s156v_wb" = 1 ] && [ "$s156v_xb" = 1 ]; then
  ok "156y: on an unmodified SPEC copy §156j still reads lever=$s156v_wb posture=$s156v_xb — BOUND, not witness: green here by design (#670)"
else
  ng "156y: on an unmodified SPEC copy §156j reads lever='${s156v_wb:-<none>}' posture='${s156v_xb:-<none>}' (expected 1 and 1) — the window repair changed the answer it was not allowed to change (#670)"
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
# SPEC §1.10. The rule: a quoted span in a durable-artifact body resolves in the FILE
# it is attributed to, and a span carried ELSEWHERE in the tree but not at the
# attributed site is a `site-mismatch` — the defect an existence-anywhere check
# passes. `scripts/lint_citations.sh` mechanizes the lexical half of part (a) and is
# born advisory (§6.0 P3): it prints findings and exits 0 unconditionally.
#
# §174a is a Doc lock over SPEC §1.10. Every other arm exercises the reader through
# its CLI, which is the surface both authoring commands use, so an arm cannot green
# on a code path the commands do not take. Each arm names its own concern in its
# header comment; no roster of them is kept here, because a roster rots as arms are
# added while each arm's own header does not.
#
# The discriminator is §174b's site-mismatch assertion: an existence-anywhere check
# reports that span as resolving, so a reader that greens §174b is doing the job the
# rule names.
#
# COUNTING DISCIPLINE (PR #677): every count below goes through `s174_count`, which
# anchors at COLUMN 0. Two things on the reader's stdout are author-supplied: the
# attributed path (path-shaped, so a body citing a file named `site-mismatch.md` puts
# that token on a line whose class is something else) and the SPAN, echoed verbatim into
# the INDENTED `search:` line, where it can carry a whole forged `…:3: resolves — …`
# sequence. A count anchored only on `:<line>: <class>` was measured returning 1 where
# the reader's own stderr totals said 0 — so the anchor must exclude the indented line,
# which is exactly what column 0 does. Nothing can SUPPRESS a count; the risk is an arm
# that measures the fixture's text instead of the reader's behaviour.
S174_SPEC="$SHELL_ROOT/SPEC.md"
S174_CHECKER="$SHELL_ROOT/scripts/lint_citations.sh"
S174_FX="$SHELL_ROOT/scripts/test/fixtures/citation/proposed-issue-body.md"
S174_ABSENT="$SHELL_ROOT/scripts/test/fixtures/citation/no-such-body.md"
S174_CMDS=("$SHELL_ROOT/.claude/commands/file-directive.md" "$SHELL_ROOT/.claude/commands/file-issue.md")

# Anchored class count: s174_count <class> "<reader stdout>". Column 0 is load-bearing
# — see COUNTING DISCIPLINE above.
s174_count() { printf '%s\n' "$2" | grep -cE "^[^[:space:]].*:[0-9]+: $1 — " || true; }

# §174a (DOC LOCK, AC4): SPEC §1.10 exists and states BOTH parts with their
# load-bearing halves — part (a) at FILE granularity including the site-mismatch
# case, part (b) with the neither-broader-nor-narrower extent rule.
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
# classification of the committed fixture body, per span. The fixture carries one
# span of each case, so this arm pins the whole class vocabulary at once:
#   - a span absent from the file it names but present elsewhere -> site-mismatch,
#     asserted at its site (`scripts/lint_bash_idioms.sh`). This is the arm an
#     existence-anywhere reader fails.
#   - a span present nowhere -> unresolved, asserted at its attributed file.
#   - two clean spans -> resolves.
#   - a GitHub-attributed span and an unattributed span -> non-defects.
#   - a span inside a fenced block -> never extracted at all.
# The `search:` line is asserted to carry the literal git grep (the report states the
# search, not just the verdict); rung 2's own search is asserted by §174e.
if [ ! -f "$S174_FX" ]; then
  ng "174b: citation fixture body absent ($S174_FX) — the per-span classification is unmeasured (#676)"
elif [ ! -f "$S174_CHECKER" ]; then
  ng "174b: scripts/lint_citations.sh absent — the per-span classification of the fixture body is unmeasured (#676)"
else
  s174b_out="$(bash "$S174_CHECKER" "$S174_FX" 2>/dev/null)"
  s174b_mm=$(s174_count 'site-mismatch' "$s174b_out")
  s174b_mm_site=$(printf '%s\n' "$s174b_out" | grep -E ':[0-9]+: site-mismatch — ' | grep -cF 'scripts/lint_bash_idioms.sh' || true)
  s174b_un=$(s174_count 'unresolved' "$s174b_out")
  s174b_un_site=$(printf '%s\n' "$s174b_out" | grep -E ':[0-9]+: unresolved — ' | grep -cF '.claude/agents/issue-reviewer.md' || true)
  s174b_res=$(s174_count 'resolves' "$s174b_out")
  s174b_gh=$(s174_count 'unresolvable-locally' "$s174b_out")
  s174b_na=$(printf '%s\n' "$s174b_out" | grep -cF 'no-attribution — ' || true)
  # Rung 1 runs WITHOUT -I and rung 3 WITH it, deliberately: the attributed file is
  # author-chosen so "does the file you named carry this" must be answered even for a
  # file git calls binary, while the repo-wide provenance sweep is over text. Both
  # shapes are pinned, so dropping either flag reddens this arm.
  s174b_search=$(printf '%s\n' "$s174b_out" | grep -cE '^[[:space:]]+search: git grep -F -h -n' || true)
  s174b_search3=$(printf '%s\n' "$s174b_out" | grep -cE '^[[:space:]]+search: git grep -I -F -n' || true)
  s174b_fenced=$(printf '%s\n' "$s174b_out" | grep -cF 'the wording blended from two sources in the parked draft' || true)
  if [ "$s174b_mm" -eq 1 ] && [ "$s174b_mm_site" -eq 1 ] \
     && [ "$s174b_un" -eq 1 ] && [ "$s174b_un_site" -eq 1 ] \
     && [ "$s174b_res" -ge 2 ] && [ "$s174b_gh" -ge 1 ] && [ "$s174b_na" -ge 1 ] \
     && [ "$s174b_search" -ge 1 ] && [ "$s174b_search3" -ge 1 ] && [ "$s174b_fenced" -eq 0 ]; then
    ok "174b: lint_citations.sh classifies the fixture per span — 1 site-mismatch at lint_bash_idioms.sh, 1 unresolved at issue-reviewer.md, both clean spans resolve, GitHub-attributed and unattributed spans stay non-defects, fenced text unread (#676)"
  else
    ng "174b: the fixture body must report exactly one site-mismatch (at scripts/lint_bash_idioms.sh) and one unresolved (at .claude/agents/issue-reviewer.md), >=2 resolves, >=1 unresolvable-locally, >=1 no-attribution, >=1 rung-1 'search: git grep -F -h -n' line, >=1 rung-3 'search: git grep -I -F -n' line, and 0 hits from the fenced block — got site-mismatch=$s174b_mm/site=$s174b_mm_site unresolved=$s174b_un/site=$s174b_un_site resolves=$s174b_res unresolvable-locally=$s174b_gh no-attribution=$s174b_na search1=$s174b_search search3=$s174b_search3 fenced=$s174b_fenced (#676)"
  fi
fi

# §174c (ADVISORY POSTURE, AC1/AC3): the reader is born advisory — status 0 on a
# body carrying defects AND on unreadable input, and the unreadable case is marked
# with a fail-open sentinel so a silent no-op cannot pass as a clean body.
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
# body at a step numbered BELOW their reviewer gate, and state that the report is
# advisory. The count-guard (`checked N of 2`) keeps an empty iteration from passing.
s174d_bad=""
s174d_n=0
for s174d_f in "${S174_CMDS[@]}"; do
  s174d_base=$(basename "$s174d_f")
  s174d_n=$(( s174d_n + 1 ))
  if [ ! -f "$s174d_f" ]; then
    s174d_bad="$s174d_bad ${s174d_base}=ABSENT"
    continue
  fi
  s174d_scan=$(awk '
    /^[0-9]+(\.[0-9]+)*\./ { step = $1; sub(/\.$/, "", step) }
    /lint_citations\.sh/ { if (cite == "") cite = step }
    /[Rr]eviewer gate/ { if (gate == "") gate = step }
    /report is advisory/ { adv = 1 }
    END { printf "%s|%s|%s", cite, gate, (adv ? "adv" : "") }
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
# `git grep` — a command that by construction returns NOTHING, since control reaches
# rung 2 only because that grep came back empty. So this arm does not read the
# printed command, it RUNS it: the fixture's `normalized` line names a file and a
# line number, and its own `search:` line, eval'd from the repo root, must print that
# same number. The fixture carries the span (a wording lint_bash_idioms.sh holds only
# across a line wrap) so the class is exercised at all — without it the rung is
# untested and a non-reproducing search ships green.
#
# This arm EVALUATES a command string rebuilt from the reader's own output, so it is
# safe only because its input is a COMMITTED FIXTURE. Reviewers attacked `sq()`
# directly across three rounds — quote breakout, `$(…)`, backticks, `; echo …; #`,
# `${IFS}`, a trailing backslash — and none produced a side effect, but do not
# repoint this arm at a caller-supplied body: that would turn a deliberately quoted
# printer into an injection sink.
if [ ! -f "$S174_FX" ]; then
  ng "174e: citation fixture body absent ($S174_FX) — the normalized rung and its printed search are unmeasured (PR #677)"
elif [ ! -f "$S174_CHECKER" ]; then
  ng "174e: scripts/lint_citations.sh absent — the normalized rung and its printed search are unmeasured (PR #677)"
else
  s174e_out="$(bash "$S174_CHECKER" "$S174_FX" 2>/dev/null)"
  s174e_n=$(s174_count 'normalized' "$s174e_out")
  s174e_rep=$(printf '%s\n' "$s174e_out" | grep -E ':[0-9]+: normalized — ' | head -n 1)
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

# §174f (THE ATTRIBUTED PATH STAYS INSIDE THE TRACKED REPOSITORY, #677): a set of
# attributions built in a throwaway repo, each carrying the SAME span verbatim at the
# place it points to and none of which the reader may resolve or normalise — plus one
# ordinary in-tree attribution it MUST still resolve, so the arm separates containment
# from over-refusal. The exact counts live in the assertion below, where going stale
# makes the arm fail instead of the comment lie. The axes:
#   - a `..` traversal to a file outside the repository. Rung 2 read the attributed
#     file directly, so a body could confirm guesses about any readable path on the
#     machine ("does this file contain X?"). Must be refused BEFORE the read.
#   - an untracked file, present in the tree. Rung 1 (git grep) sees only tracked
#     files, so the verbatim span missed there and rung 2's direct read then reported
#     `normalized` — a normalisation that never happened.
#   - git pathspec magic in the attribution. As a rung-1 pathspec it INVERTED the
#     search into "everywhere but this file" and reported `resolves` for a span living
#     somewhere else entirely.
#   - a TRACKED SYMLINK to a file outside the repository. `in_repo_path` is purely
#     textual, `git ls-files --error-unmatch` confirms a mode-120000 index entry, and
#     `-f` FOLLOWS the link, so all three of the round-2 tests passed and rung 2 read
#     an arbitrary absolute path.
#   - a tracked path reached through a DIRECTORY swapped for a symlink out of the
#     tree. The leaf is not itself a link, so refusing `-L` on it is not enough; only
#     physical resolution of the whole chain catches this one. And here the rung that
#     reads through is rung 1's `git grep`, which falsified the premise that the git
#     rungs are boundary-safe: git enforces a pathspec boundary, never a filesystem
#     one.
#   - object-store attributions: present and absent, lowercase and CASE-VARIED, by
#     spelling and through a tracked symlink alias. `.git/` IS under the repository
#     root, so physical containment admits it, and the working-tree probe that picks
#     the out-of-reach wording would otherwise answer existence questions about the
#     object store; a case-sensitive refusal admits `.GIT/config` on a
#     case-insensitive filesystem. All spellings must produce the SAME sentence — an
#     oracle is a difference, so identity is one assertion here, but NOT the only
#     one: see the mutation lock below.
# Every probe attribution lands on `unresolvable-locally` — a non-defect, so a benign
# attribution is never converted into a false defect either — while the control still
# resolves.
S174F_DIR=$(mktemp -d 2>/dev/null)
S174F_SPAN="the boundary probe span carried verbatim at every attributed site"
if [ ! -f "$S174_CHECKER" ]; then
  ng "174f: scripts/lint_citations.sh absent — the repository-boundary posture is unmeasured (PR #677)"
elif [ -z "$S174F_DIR" ] || [ ! -d "$S174F_DIR" ]; then
  ng "174f: mktemp -d failed — the repository-boundary posture is unmeasured (PR #677)"
else
  S174F_WORK="$S174F_DIR/work"
  mkdir -p "$S174F_WORK" "$S174F_DIR/outdir"
  printf '%s\n' "$S174F_SPAN" > "$S174F_DIR/outside.md"
  printf '%s\n' "$S174F_SPAN" > "$S174F_DIR/outdir/x.md"
  git init -q "$S174F_WORK" 2>/dev/null
  (
    cd "$S174F_WORK" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf '%s\n' "$S174F_SPAN" > tracked.md
    printf '%s\n' "$S174F_SPAN" > elsewhere.md
    printf '%s\n' "$S174F_SPAN" > untracked.md
    : > ':(exclude,top)tracked.md'
    mkdir -p sub realdir
    printf '%s\n' "$S174F_SPAN" > sub/x.md
    printf '%s\n' "$S174F_SPAN" > realdir/inside.md
    ln -s ../outside.md link.md
    # A tracked symlink whose target is `.git`: a mode-120000 blob, so a CLONE
    # materialises it. This was the one object-store gap that needed no worktree write,
    # because the refusal was on the attribution string and not the resolved path.
    ln -s .git gitalias
    # A glob-metacharacter filename beside the file it would glob onto. `:(literal)`
    # disarms the pathspec; without it `a?c.md` matches `abc.md` and a real
    # site-mismatch reports as a clean `resolves` — a FALSE clean, the direction §1.10
    # exists to catch. Asserted separately below, because unlike the refusals it is a
    # classification claim rather than an out-of-corpus one.
    printf '%s\n' "$S174F_SPAN" > abc.md
    printf 'a decoy that carries nothing of the sort\n' > 'a?c.md'
    git add tracked.md elsewhere.md sub/x.md realdir/inside.md link.md gitalias abc.md 'a?c.md' >/dev/null 2>&1
    git commit -q -m seed >/dev/null 2>&1
    # The leaf stays tracked and is not itself a link; its PARENT is swapped.
    rm -rf sub && ln -s "$S174F_DIR/outdir" sub
  ) >/dev/null 2>&1
  {
    printf '# boundary probe\n\n'
    printf -- '- `../outside.md` states *"%s"* — outside the repository.\n' "$S174F_SPAN"
    printf -- '- `untracked.md` states *"%s"* — present but untracked.\n' "$S174F_SPAN"
    printf -- '- `:(exclude,top)tracked.md` states *"%s"* — pathspec magic.\n' "$S174F_SPAN"
    printf -- '- `link.md` states *"%s"* — a tracked symlink out of the tree.\n' "$S174F_SPAN"
    printf -- '- `sub/x.md` states *"%s"* — a tracked leaf under a swapped directory.\n' "$S174F_SPAN"
    printf -- '- `.git/config` states *"%s"* — an object-store path that exists.\n' "$S174F_SPAN"
    printf -- '- `.git/definitely-absent-xyz` states *"%s"* — an object-store path that does not.\n' "$S174F_SPAN"
    printf -- '- `.GIT/config` states *"%s"* — the same path, case-varied, which exists.\n' "$S174F_SPAN"
    printf -- '- `.GIT/definitely-absent-xyz` states *"%s"* — the same, case-varied, absent.\n' "$S174F_SPAN"
    printf -- '- `gitalias/config` states *"%s"* — the object store through a tracked symlink.\n' "$S174F_SPAN"
    printf -- '- `gitalias/definitely-absent-xyz` states *"%s"* — the same alias, absent.\n' "$S174F_SPAN"
    printf -- '- `realdir/` states *"%s"* — a directory, not a file.\n' "$S174F_SPAN"
    printf -- '- `tracked.md` states *"%s"* — the ordinary in-tree control.\n' "$S174F_SPAN"
  } > "$S174F_WORK/probe.md"
  s174f_out="$(bash "$S174_CHECKER" "$S174F_WORK/probe.md" 2>/dev/null)"
  s174f_remote=$(s174_count 'unresolvable-locally' "$s174f_out")
  s174f_leak=$(( $(s174_count 'normalized' "$s174f_out") + $(s174_count 'site-mismatch' "$s174f_out") + $(s174_count 'unresolved' "$s174f_out") ))
  s174f_res=$(s174_count 'resolves' "$s174f_out")
  s174f_ctl=$(printf '%s\n' "$s174f_out" | grep -E ':[0-9]+: resolves — ' | grep -cF 'tracked.md' || true)
  # The two `.git/` lines must be identical apart from the path they name: strip the
  # path and require one distinct sentence, so an existence difference cannot hide.
  # All object-store spellings — lowercase, case-varied, and through a tracked symlink
  # alias — must give ONE sentence. An oracle is a difference, and the alias is the only
  # one of these a plain clone reproduces.
  s174f_gitsent=$(printf '%s\n' "$s174f_out" | grep -iE ':[0-9]+: unresolvable-locally — attributed to (\.git/|gitalias/)' \
    | sed -E 's/^.*:[0-9]+: /<body>: /; s/attributed to (\.[gG][iI][tT]|gitalias)\/[^,]*,/attributed to <path>,/' | sort -u | wc -l | tr -d ' ')
  s174f_gitn=$(printf '%s\n' "$s174f_out" | grep -ciE ':[0-9]+: unresolvable-locally — attributed to (\.git/|gitalias/)' || true)
  # THE MUTATION LOCK. Identity of two sentences is NOT enough on its own: a build in
  # which every refusal degrades to one generic sentence satisfies identity trivially,
  # and that is exactly the inert-reason regression a reviewer re-introduced while all
  # ten arms of this section stayed green. So the arm additionally requires that the
  # refusals carry at least THREE distinct sentences, and that the two physical
  # refusals name their own test by wording. Collapse the reasons and this reddens.
  s174f_distinct=$(printf '%s\n' "$s174f_out" | grep -E '^[^[:space:]].*:[0-9]+: unresolvable-locally — ' \
    | sed -E 's/^.*unresolvable-locally — attributed to [^,]*,//' | sort -u | wc -l | tr -d ' ')
  s174f_symword=$(printf '%s\n' "$s174f_out" | grep -cF 'the working-tree entry there is a symlink' || true)
  # The textual refusal needs its own wording lock. Re-gating it behind `tracked = 1` —
  # the literal bug this reader's comment calls a trap the next edit can re-enter — left
  # ALL of §174 green, because the distinct-sentence count absorbed the collapse. The
  # traversal and the pathspec-magic attributions are the two that must carry it.
  s174f_textword=$(printf '%s\n' "$s174f_out" | grep -cF 'refused before any index or filesystem lookup ran' || true)
  # The regular-file gate. `git ls-files --error-unmatch` answers 0 for a DIRECTORY, so
  # the index test alone calls it tracked; drop the `-f` test and a span living at
  # `realdir/inside.md` but attributed to `realdir/` reports `resolves` — an
  # existence-anywhere-under-a-directory answer, §1.10's discriminator backwards. No
  # arm pinned it.
  s174f_dirword=$(printf '%s\n' "$s174f_out" | grep -cF 'resolves to a directory, not a file' || true)
  # And `:(literal)`: a separate body, because this one asserts a CLASSIFICATION rather
  # than a refusal. Without the literal pathspec, rung 1 globs `a?c.md` onto `abc.md`
  # and reports `resolves`; with it, rung 1 misses and rung 3 finds the wording at
  # `abc.md`, which is the site-mismatch this checks for. The class IS the lock.
  printf -- '- `a?c.md` states *"%s"* — a glob metacharacter beside the file it would match.\n' "$S174F_SPAN" > "$S174F_WORK/glob.md"
  s174f_glob=$(printf '%s\n' "$(bash "$S174_CHECKER" "$S174F_WORK/glob.md" 2>/dev/null)" \
    | grep -E '^[^[:space:]].*:[0-9]+: site-mismatch — ' | grep -cF 'abc.md' || true)
  s174f_escword=$(printf '%s\n' "$s174f_out" | grep -cF 'resolves physically to a path outside this repository' || true)
  if [ "$s174f_remote" -eq 12 ] && [ "$s174f_leak" -eq 0 ] \
     && [ "$s174f_dirword" -eq 1 ] \
     && [ "$s174f_glob" -eq 1 ] \
     && [ "$s174f_res" -eq 1 ] && [ "$s174f_ctl" -eq 1 ] \
     && [ "$s174f_gitn" -eq 6 ] && [ "$s174f_gitsent" -eq 1 ] \
     && [ "$s174f_distinct" -ge 3 ] \
     && [ "$s174f_symword" -eq 1 ] && [ "$s174f_escword" -eq 1 ] \
     && [ "$s174f_textword" -eq 2 ]; then
    ok "174f: a traversal, an untracked file, pathspec magic, a tracked symlink out of the tree, a tracked leaf under a swapped directory and six object-store paths (case-varied, and through a tracked symlink alias a clone reproduces) all report unresolvable-locally — all four object-store spellings share one sentence so existence there is not an oracle, the refusals carry $s174f_distinct distinct sentences and the two physical ones name their own test — while the in-tree control still resolves (PR #677)"
  else
    ng "174f: the twelve out-of-corpus attributions must all report unresolvable-locally with no normalized/site-mismatch/unresolved line; all six object-store spellings (case-varied and symlink-aliased) must yield ONE distinct sentence; the refusals must carry >=3 distinct sentences with the symlink and escapes cases naming their own test; and the in-tree control must still resolve — got unresolvable-locally=$s174f_remote leaked-classes=$s174f_leak resolves=$s174f_res control=$s174f_ctl git-lines=$s174f_gitn git-distinct-sentences=$s174f_gitsent distinct=$s174f_distinct symlink-worded=$s174f_symword escapes-worded=$s174f_escword textual-worded=$s174f_textword directory-worded=$s174f_dirword glob-site-mismatch=$s174f_glob (PR #677)"
  fi
fi
if [ -n "$S174F_DIR" ] && [ -d "$S174F_DIR" ]; then rm -rf "$S174F_DIR"; fi

# §174g (A CLOSED PIPE: STATUS 0, A STATED CUT, AND WORK THAT STOPS, #677): §174c
# measures the UNPIPED invocation only, and the reader died of SIGPIPE with status 141
# the moment a caller read part of the report and stopped. Ignoring the signal fixed
# the status but a failed write is silent, so a TRUNCATED report became
# indistinguishable from a complete one — and for a reader whose whole output a caller
# is instructed to surface verbatim, that reads as a clean body. Worse, the reader
# then kept working for a caller that had stopped reading: measured 10.6 s of grinding
# after `head -3` had returned.
#
# The probe body is GENERATED with many spans rather than reusing the fixture, and
# that is deliberate: the fixture's report is a few KB, which fits inside the pipe
# buffer, so every write could succeed before `head` was ever scheduled and the arm
# would green with no truncation having occurred. A report far larger than the buffer
# makes the cut certain rather than a race.
S174G_DIR=$(mktemp -d 2>/dev/null)
if [ ! -f "$S174_CHECKER" ]; then
  ng "174g: scripts/lint_citations.sh absent — the closed-pipe posture is unmeasured (PR #677)"
elif [ -z "$S174G_DIR" ] || [ ! -d "$S174G_DIR" ]; then
  ng "174g: mktemp -d failed — the closed-pipe posture is unmeasured (PR #677)"
else
  S174G_WORK="$S174G_DIR/work"
  mkdir -p "$S174G_WORK"
  git init -q "$S174G_WORK" 2>/dev/null
  (
    cd "$S174G_WORK" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf 'an ordinary tracked artifact\n' > tracked.md
    git add tracked.md >/dev/null 2>&1
    git commit -q -m seed >/dev/null 2>&1
  ) >/dev/null 2>&1
  {
    printf '# pipe probe\n\n'
    awk 'BEGIN { for (i = 1; i <= 300; i++) printf "- `tracked.md` states *\"absent phrase number %d in a report deliberately built larger than one pipe buffer so the cut is certain rather than scheduled\"* — absent.\n", i }'
  } > "$S174G_WORK/probe.md"
  # The span-count cap would otherwise hold the report under the buffer, so this arm
  # raises it through the documented seam: the property under test is the closed pipe,
  # not the cap (§174j owns that).
  export GHJIG_CITATION_SPAN_COUNT_MAX=400
  s174g_bytes=$(bash "$S174_CHECKER" "$S174G_WORK/probe.md" 2>/dev/null | wc -c | tr -d ' ')
  s174g_t0=$SECONDS
  bash "$S174_CHECKER" "$S174G_WORK/probe.md" 2>"$S174G_DIR/err_cut" | head -n 2 >/dev/null
  s174g_rc=${PIPESTATUS[0]}
  s174g_cut_el=$(( SECONDS - s174g_t0 ))
  s174g_t0=$SECONDS
  bash "$S174_CHECKER" "$S174G_WORK/probe.md" 2>"$S174G_DIR/err_full" >/dev/null
  s174g_rc_full=$?
  s174g_full_el=$(( SECONDS - s174g_t0 ))
  unset GHJIG_CITATION_SPAN_COUNT_MAX
  s174g_cut=$(grep -cF 'TRUNCATED' "$S174G_DIR/err_cut" || true)
  s174g_full=$(grep -cF 'TRUNCATED' "$S174G_DIR/err_full" || true)
  if [ "$s174g_rc" -eq 0 ] && [ "$s174g_rc_full" -eq 0 ] \
     && [ "$s174g_bytes" -gt 65536 ] \
     && [ "$s174g_cut" -ge 1 ] && [ "$s174g_full" -eq 0 ] \
     && [ "$s174g_cut_el" -lt "$s174g_full_el" ]; then
    ok "174g: on a ${s174g_bytes}-byte report cut after two lines the reader exits 0, states the cut with a TRUNCATED sentinel stderr carries only in that case, and STOPS — ${s174g_cut_el}s against ${s174g_full_el}s for the full run (PR #677)"
  else
    ng "174g: a report larger than the pipe buffer, truncated after two lines, must exit 0, write a TRUNCATED sentinel to stderr (and none on a full read), and finish strictly faster than the full run — got rc=$s174g_rc rc_full=$s174g_rc_full bytes=$s174g_bytes sentinel_cut=$s174g_cut sentinel_full=$s174g_full cut=${s174g_cut_el}s full=${s174g_full_el}s (PR #677)"
  fi
fi
if [ -n "$S174G_DIR" ] && [ -d "$S174G_DIR" ]; then rm -rf "$S174G_DIR"; fi

# §174h (EVERY FACTOR OF THE COST IS BOUNDED, #677): rung 2 joined the WHOLE
# attributed file into one awk string — quadratic, no size cap, no timeout: a body
# citing a large tracked artifact plus a phrase it does not carry stalled the caller
# for minutes with no human present (measured 9.6 MB -> over 10 minutes). The scan is
# a sliding window now, but the cost is a PRODUCT and each round found another factor
# of it. All five are measured here, each against the shape that was slow:
#   - 4 MB as 60 000 short lines, one span — the file-size axis.
#   - the SAME 4 MB as ONE line: the per-record normalisation is quadratic in line
#     length, so a one-line file never entered the trim loop (0.32 s at 256 KB
#     doubling cleanly to 66.9 s at 4 MB). Reachable with nothing planted — a minified
#     bundle, a one-line JSON dump, an inlined SVG.
#   - 30 spans against the same file — the multiplier a one-span arm cannot see.
#   - a 1.6 MB BODY on one line: the extractor's own scan is quadratic in one BODY
#     line's length, which is the axis the AUTHOR controls, and it was unbounded while
#     the cited artifact's lines were capped (measured: 118 s in extraction alone).
#   - 250 spans against the span-count cap: rungs 1 and 3 fork a git process per span,
#     so a GitHub-legal 64 KB body of minimal spans ran for two minutes.
# The bounds are deliberately loose (20 s) — they separate linear from quadratic by
# more than an order of magnitude without pinning machine speed.
# §174j shares this repo, so it is nested here — but its ng path is duplicated into
# BOTH guard arms below. Nested inside the success branch alone it emitted neither ok
# nor ng when the precondition failed, so the suite would report fail=0 with one fewer
# assertion: the silent-skip-on-an-absent-target anti-pattern this suite's own header
# names, committed by the section about silent suppression (PR #677).
S174H_DIR=$(mktemp -d 2>/dev/null)
if [ ! -f "$S174_CHECKER" ]; then
  ng "174h: scripts/lint_citations.sh absent — the reader's cost is unmeasured (PR #677)"
  ng "174j: scripts/lint_citations.sh absent — the statement discipline is unmeasured (PR #677)"
elif [ -z "$S174H_DIR" ] || [ ! -d "$S174H_DIR" ]; then
  ng "174h: mktemp -d failed — the reader's cost is unmeasured (PR #677)"
  ng "174j: mktemp -d failed — the statement discipline is unmeasured (PR #677)"
else
  S174H_WORK="$S174H_DIR/work"
  mkdir -p "$S174H_WORK"
  git init -q "$S174H_WORK" 2>/dev/null
  (
    cd "$S174H_WORK" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    awk 'BEGIN { for (i = 0; i < 60000; i++) print "line " i " of a large generated lock-like artifact with filler words" }' > big.md
    awk 'BEGIN { s = ""; for (i = 0; i < 200000; i++) s = s "minified token " i " "; print s }' > oneline.md
    git add big.md oneline.md >/dev/null 2>&1
    git commit -q -m seed >/dev/null 2>&1
  ) >/dev/null 2>&1
  printf '# size probe\n\n- `big.md` states *"a phrase this large artifact does not carry at all"* — absent.\n' > "$S174H_WORK/probe.md"
  printf '# one-line probe\n\n- `oneline.md` states *"a phrase this minified artifact does not carry at all"* — absent.\n' > "$S174H_WORK/probe1.md"
  {
    printf '# multiplier probe\n\n'
    awk 'BEGIN { for (i = 1; i <= 30; i++) printf "- `big.md` states *\"absent phrase number %d that this artifact does not carry\"* — absent.\n", i }'
  } > "$S174H_WORK/probeN.md"
  awk 'BEGIN { s = ""; for (i = 0; i < 40000; i++) s = s "\"absent phrase number " i " not carried\" "; print "- `big.md` " s }' > "$S174H_WORK/probeB.md"
  {
    printf '# span-count probe\n\n'
    awk 'BEGIN { for (i = 1; i <= 250; i++) printf "- `big.md` states *\"absent phrase number %d not carried anywhere\"* — absent.\n", i }'
  } > "$S174H_WORK/probeC.md"
  s174h_t0=$SECONDS
  s174h_cls=$(s174_count 'unresolved' "$(bash "$S174_CHECKER" "$S174H_WORK/probe.md" 2>/dev/null)")
  s174h_el=$(( SECONDS - s174h_t0 ))
  s174h_t0=$SECONDS
  s174h_cls1=$(s174_count 'unresolved' "$(bash "$S174_CHECKER" "$S174H_WORK/probe1.md" 2>/dev/null)")
  s174h_el1=$(( SECONDS - s174h_t0 ))
  s174h_t0=$SECONDS
  s174h_clsN=$(s174_count 'unresolved' "$(bash "$S174_CHECKER" "$S174H_WORK/probeN.md" 2>/dev/null)")
  s174h_elN=$(( SECONDS - s174h_t0 ))
  s174h_t0=$SECONDS
  bash "$S174_CHECKER" "$S174H_WORK/probeB.md" >/dev/null 2>&1
  s174h_elB=$(( SECONDS - s174h_t0 ))
  s174h_t0=$SECONDS
  s174h_clsC=$(s174_count 'unresolved' "$(bash "$S174_CHECKER" "$S174H_WORK/probeC.md" 2>/dev/null)")
  s174h_elC=$(( SECONDS - s174h_t0 ))
  if [ "$s174h_el" -lt 20 ] && [ "$s174h_cls" -eq 1 ] \
     && [ "$s174h_el1" -lt 20 ] && [ "$s174h_cls1" -eq 1 ] \
     && [ "$s174h_elN" -lt 20 ] && [ "$s174h_clsN" -eq 30 ] \
     && [ "$s174h_elB" -lt 20 ] \
     && [ "$s174h_elC" -lt 20 ] && [ "$s174h_clsC" -eq 200 ]; then
    ok "174h: 4 MB as 60 000 lines (${s174h_el}s), the same 4 MB as ONE line (${s174h_el1}s), 30 spans against it (${s174h_elN}s), a 1.6 MB single-line BODY (${s174h_elB}s) and 250 spans capped to 200 (${s174h_elC}s) all finish inside the bound — every factor of the product is capped (PR #677)"
  else
    ng "174h: every factor of the cost must be bounded under 20s — 4 MB many-line (1 unresolved), 4 MB one-line (1 unresolved), 30 spans (30 unresolved), a 1.6 MB one-line body, and 250 spans classified down to the 200 cap — got many=${s174h_el}s/$s174h_cls oneline=${s174h_el1}s/$s174h_cls1 multi=${s174h_elN}s/$s174h_clsN bodyline=${s174h_elB}s spancount=${s174h_elC}s/$s174h_clsC (PR #677)"
  fi

  # §174j (EVERY BOUND THE READER REACHES, IT STATES, #677) — the anti-silence arm,
  # sharing §174h's repo. A cap that suppresses work silently is the defect this whole
  # section is about, committed by the tool that ships the rule: a skipped rung is not
  # a ruled-out one, and the report must not imply otherwise. Two of these were found
  # only because a reviewer diffed against the previous round — a `normalized`
  # (explicitly a non-defect) became an `unresolved` (a defect) with nothing said,
  # and a nested fence voided the check for an arbitrary tail of the body.
  # Every decline this arm can drive, and where each is stated — on the report line it
  # affected where it changes what that line means, on stderr where it does not, which
  # is the rule §1.10 states. No count of the two sides here: this section removed one
  # such census for going stale and should not carry a replacement.
  #   - a span over the length cap
  #   - spans beyond the count cap
  #   - a body line over the line cap
  #   - a line ending on an unpaired ASCII double quote (which also covers a quotation
  #     wrapped across two lines: both halves end unpaired)
  #   - a line ending on an unpaired backtick
  #   - a fenced block that never closes
  #   - a CITED artifact's line over the normalising rung's own cap
  #   - a rung-2 byte budget too small for the file
  #   - a normalising rung whose awk exited nonzero
  # The fence case uses a FOUR-backtick block wrapping a literal three-backtick line —
  # the ordinary way to document fenced markdown, and a parity toggle counts it as
  # three hits and silently drops the rest of the body.
  (
    cd "$S174H_WORK" || exit 1
    awk 'BEGIN { s = ""; for (i = 0; i < 9000; i++) s = s "filler token " i " "; print s "the  double  spaced  phrase  that  only  normalises" }' > longline.md
    git add longline.md >/dev/null 2>&1
    git commit -q -m longline >/dev/null 2>&1
  ) >/dev/null 2>&1
  # Each bound gets a line that reaches THAT bound and no earlier one, and the bounds
  # are ORDERED — a fixture has to respect the order or it measures the wrong cap.
  # Two versions of this fixture got it wrong: the over-long span first sat on a 56 KB
  # line, so the body-line cap dropped it before the span-length cap saw it; then the
  # `longline.md` citation sat fourth, so the count cap dropped it before the
  # normalising rung ran. Both failures looked like a missing statement in the reader.
  # Hence: the span that must reach the normalising rung comes FIRST among the kept
  # spans, and the over-long span sits on an ordinary-length line.
  {
    printf '# statement probe\n\n'
    awk 'BEGIN { s = ""; for (i = 0; i < 120; i++) s = s "filler word " i " "; printf "- `big.md` states *\"%s\"* — an over-long span, on an ordinary-length line.\n", s }'
    printf -- '- `longline.md` states *"the double spaced phrase that only normalises"* — normalises only on a 126 KB line.\n'
    printf -- '- `big.md` states *"second absent phrase kept under the count cap"* — kept.\n'
    printf -- '- `big.md` states *"third absent phrase past the count cap"* — dropped.\n'
    awk 'BEGIN { s = ""; for (i = 0; i < 2000; i++) s = s "filler prose word " i " "; print "- an over-long BODY line: " s }'
    printf -- '- `big.md` says "two words" and \342\200\234a typographic candidate here\342\200\235 too.\n'
    printf -- '- `big.md` says "a paired span of four words" and "an unpaired one\n'
    printf -- '- an unpaired `backtick ends the token scan before "a span of four words here"\n'
    printf '````text\n'
    printf '```\n'
    printf -- '- `big.md` states *"a span the unclosed fence swallows entirely"* — swallowed.\n'
  } > "$S174H_WORK/probeS.md"
  s174j_err=$(GHJIG_CITATION_SPAN_COUNT_MAX=2 bash "$S174_CHECKER" "$S174H_WORK/probeS.md" 2>&1 >/dev/null)
  s174j_out=$(GHJIG_CITATION_SPAN_COUNT_MAX=2 bash "$S174_CHECKER" "$S174H_WORK/probeS.md" 2>/dev/null)
  s174j_budget=$(GHJIG_CITATION_R2_BUDGET=1 bash "$S174_CHECKER" "$S174H_WORK/probe.md" 2>/dev/null)
  s174j_span=$(printf '%s\n' "$s174j_err" | grep -cF 'span(s) over 1000 characters were not classified' || true)
  s174j_count=$(printf '%s\n' "$s174j_err" | grep -cE 'span\(s\) beyond the first 2 were not classified' || true)
  s174j_body=$(printf '%s\n' "$s174j_err" | grep -cF 'body line(s) over 20000 characters were not scanned' || true)
  s174j_fence=$(printf '%s\n' "$s174j_err" | grep -cF 'is never closed' || true)
  s174j_line=$(printf '%s\n' "$s174j_out" | grep -cF 'the normalising rung skipped 1 line(s) over 65536 characters' || true)
  s174j_bud=$(printf '%s\n' "$s174j_budget" | grep -cF 'larger than this run' || true)
  s174j_unpairq=$(printf '%s\n' "$s174j_err" | grep -cF 'unpaired ASCII double quote' || true)
  s174j_unpairb=$(printf '%s\n' "$s174j_err" | grep -cF 'unpaired backtick' || true)
  # Three declines this arm is named for but could not fail on: silencing any one of
  # them left all eleven arms green. Two of the three are the ones the reader's own
  # header calls out as having been silent before the channel existed, which makes an
  # unfailable arm for them the worst of the set.
  s174j_floor=$(printf '%s\n' "$s174j_err" | grep -cF 'under the four-word floor' || true)
  s174j_typo=$(printf '%s\n' "$s174j_err" | grep -cF 'delimited by typographic quotes' || true)
  s174j_fenced2=$(printf '%s\n' "$s174j_err" | grep -cF 'inside fenced blocks were not scanned' || true)
  # The rung-2 note that fires when awk itself FAILS. It is the one decline measured to
  # flip a class — a `normalized` non-defect becomes an `unresolved` defect — which is
  # exactly what the statement exists to prevent, so it gets its own arm rather than
  # riding on the others. The seam is a stub `awk` that fails ONLY the normalising
  # program: it exits 3 when its program text mentions `ENVIRON["SPAN"]`, and execs the
  # real awk otherwise, so `extract` still runs and rung 2 alone breaks. §174k's stub
  # cannot reach this branch, because it kills the extractor before rung 2 is entered.
  s174j_realawk=$(command -v awk 2>/dev/null)
  mkdir -p "$S174H_DIR/awkstub"
  {
    printf '#!/bin/sh\n'
    printf 'case "$*" in *ENVIRON*SPAN*) exit 3 ;; esac\n'
    printf 'exec %s "$@"\n' "$s174j_realawk"
  } > "$S174H_DIR/awkstub/awk"
  chmod +x "$S174H_DIR/awkstub/awk"
  (
    cd "$S174H_WORK" || exit 1
    printf 'a  double  spaced  phrase  that  only  normalises\n' > shortnorm.md
    git add shortnorm.md >/dev/null 2>&1
    git commit -q -m 'chore: shortnorm' >/dev/null 2>&1
  ) >/dev/null 2>&1
  printf -- '- `shortnorm.md` states *"a double spaced phrase that only normalises"* — normalises only.\n' > "$S174H_WORK/probeA.md"
  s174j_awkok=$(s174_count 'normalized' "$(bash "$S174_CHECKER" "$S174H_WORK/probeA.md" 2>/dev/null)")
  s174j_awkfail=$( PATH="$S174H_DIR/awkstub:$PATH" bash "$S174_CHECKER" "$S174H_WORK/probeA.md" 2>/dev/null \
    | grep -cF 'the normalising rung could not run — awk exited 3' || true )
  if [ "$s174j_span" -ge 1 ] && [ "$s174j_count" -ge 1 ] && [ "$s174j_body" -ge 1 ] \
     && [ "$s174j_fence" -ge 1 ] && [ "$s174j_line" -ge 1 ] && [ "$s174j_bud" -ge 1 ] \
     && [ "$s174j_unpairq" -ge 1 ] && [ "$s174j_unpairb" -ge 1 ] \
     && [ "$s174j_floor" -ge 1 ] && [ "$s174j_typo" -ge 1 ] && [ "$s174j_fenced2" -ge 1 ] \
     && [ -n "$s174j_realawk" ] && [ "$s174j_awkok" -eq 1 ] && [ "$s174j_awkfail" -ge 1 ]; then
    ok "174j: every decline states what it suppressed — an over-long span, spans past the count cap, an over-long body line, an unpaired quote, an unpaired backtick, an unclosed fence, and (on the report line each affected) a cited artifact's over-long line, a file over the rung-2 byte budget, and a normalising rung whose awk failed (PR #677)"
  else
    ng "174j: every decline must state its skip — got over-long-span=$s174j_span span-count=$s174j_count body-line=$s174j_body unpaired-quote=$s174j_unpairq unpaired-backtick=$s174j_unpairb four-word-floor=$s174j_floor typographic=$s174j_typo fenced-lines=$s174j_fenced2 unclosed-fence=$s174j_fence cited-line=$s174j_line byte-budget=$s174j_bud awk-normalizes=$s174j_awkok awk-failed-stated=$s174j_awkfail (PR #677)"
  fi
fi
if [ -n "$S174H_DIR" ] && [ -d "$S174H_DIR" ]; then rm -rf "$S174H_DIR"; fi

# §174i (THE BODY'S OWN PATH IS RESOLVED, SO THE SELF-EXCLUSION HOLDS, #677): rung 3
# searches the whole repository minus the body itself, and a committed body is
# TRACKED — so the moment that self-exclusion is wrong, §1.10's discriminator runs
# backwards. Three ways it was wrong, all measured on this branch:
#   - a body whose name starts with `-`: `dirname` / `basename` read it as an option,
#     ROOT silently fell back to the cwd's repo and the exclusion vanished, so a
#     wholly fabricated span matched the body that fabricated it and reported
#     `site-mismatch` — the class that means "real wording, wrong place" pinned on a
#     wording that exists nowhere but the claim.
#   - a body reached through a symlinked path: the body's directory was resolved
#     LOGICALLY while git's top level is physical, so it was not a prefix of ROOT and
#     the exclusion vanished the same way. This needs no symlink of one's own on
#     macOS, where `/var` is one.
#   - a body OUTSIDE any repository: ROOT fell back to the cwd's repo but the
#     exclusion was set to the body's bare BASENAME, so rung 3 excluded an unrelated
#     tracked file that happened to share it — and a real `site-mismatch` was reported
#     `unresolved`, under-reporting the defect the rule exists to catch. The fixture
#     below is exactly that: the outside body is named `carrier.md`, the repo has its
#     own tracked `carrier.md` carrying the span, and the attribution points elsewhere.
S174I_DIR=$(mktemp -d 2>/dev/null)
if [ ! -f "$S174_CHECKER" ]; then
  ng "174i: scripts/lint_citations.sh absent — the body-path resolution is unmeasured (PR #677)"
elif [ -z "$S174I_DIR" ] || [ ! -d "$S174I_DIR" ]; then
  ng "174i: mktemp -d failed — the body-path resolution is unmeasured (PR #677)"
else
  S174I_WORK="$S174I_DIR/real"
  mkdir -p "$S174I_WORK" "$S174I_DIR/away"
  git init -q "$S174I_WORK" 2>/dev/null
  (
    cd "$S174I_WORK" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf 'an ordinary tracked artifact\n' > tracked.md
    printf 'the phrase that only the carrier file holds\n' > carrier.md
    printf -- '- `tracked.md` states *"a wholly fabricated span that exists nowhere at all"* — fabricated.\n' > body.md
    # A DISTINCT fabrication: two bodies carrying the same span would make each the
    # other's site-mismatch, and the arm would fail for its own fixture's reason
    # rather than the property's.
    printf -- '- `tracked.md` states *"another fabrication carried by no artifact whatsoever"* — fabricated.\n' > ./-dashbody.md
    git add tracked.md carrier.md body.md ./-dashbody.md >/dev/null 2>&1
    git commit -q -m seed >/dev/null 2>&1
  ) >/dev/null 2>&1
  ln -s "$S174I_WORK" "$S174I_DIR/link"
  printf -- '- `tracked.md` states *"the phrase that only the carrier file holds"* — carried by carrier.md.\n' > "$S174I_DIR/away/carrier.md"
  s174i_dash=$( cd "$S174I_WORK" && bash "$S174_CHECKER" "-dashbody.md" 2>/dev/null )
  s174i_sym=$( bash "$S174_CHECKER" "$S174I_DIR/link/body.md" 2>/dev/null )
  s174i_out=$( cd "$S174I_WORK" && bash "$S174_CHECKER" "$S174I_DIR/away/carrier.md" 2>/dev/null )
  s174i_dash_un=$(s174_count 'unresolved' "$s174i_dash")
  s174i_dash_mm=$(s174_count 'site-mismatch' "$s174i_dash")
  s174i_sym_un=$(s174_count 'unresolved' "$s174i_sym")
  s174i_sym_mm=$(s174_count 'site-mismatch' "$s174i_sym")
  s174i_out_mm=$(s174_count 'site-mismatch' "$s174i_out")
  s174i_out_site=$(printf '%s\n' "$s174i_out" | grep -E ':[0-9]+: site-mismatch — ' | grep -cF 'carrier.md:1' || true)
  if [ "$s174i_dash_un" -eq 1 ] && [ "$s174i_dash_mm" -eq 0 ] \
     && [ "$s174i_sym_un" -eq 1 ] && [ "$s174i_sym_mm" -eq 0 ] \
     && [ "$s174i_out_mm" -eq 1 ] && [ "$s174i_out_site" -eq 1 ]; then
    ok "174i: a fabricated span reports unresolved from a dash-named body and from a body reached through a symlink, and a body OUTSIDE the repository still reports its site-mismatch at carrier.md — the rung-3 self-exclusion is neither lost nor pointed at the wrong file (PR #677)"
  else
    ng "174i: a committed body's fabricated span must report unresolved (never site-mismatch) whether dash-named or symlink-reached, and an out-of-repo body must still report a real site-mismatch at its carrier — got dash: unresolved=$s174i_dash_un mismatch=$s174i_dash_mm; symlinked: unresolved=$s174i_sym_un mismatch=$s174i_sym_mm; outside: mismatch=$s174i_out_mm at-carrier=$s174i_out_site (PR #677)"
  fi
fi
if [ -n "$S174I_DIR" ] && [ -d "$S174I_DIR" ]; then rm -rf "$S174I_DIR"; fi

# §174k (THE PRODUCER SAYS WHEN IT DIED, AND CANNOT BE KILLED BY BODY TEXT, #677): the
# extractor is an `awk` program reading author-supplied text, and it was piped in through
# a process substitution, which discards its exit status. In a UTF-8 locale one invalid
# byte is FATAL to a regex match, and the extractor applies a regex to every line — so a
# single stray byte stopped extraction mid-body while stdout still carried the header and
# a totals line reading zero. No sentinel, no note, exit 0: a body could be made
# effectively unexaminable behind a report that looked clean. Reachable without contrivance
# — this repository's work language may be Korean, and quoting a CP949/EUC-KR snippet
# produces exactly that byte sequence.
#
# Two independent halves, because one platform's awk is not every platform's:
#   (a) BEHAVIOUR — a body carrying invalid UTF-8 must still classify the spans after it.
#       This is what `LC_ALL=C` on the extractor buys, and it is asserted as an outcome so
#       it holds on any awk, whether or not that awk would have died.
#   (b) SOURCE — the extractor is actually invoked under `LC_ALL=C`, pinned by a grep,
#       because on an awk that tolerates the byte, (a) would pass with the locale fix
#       reverted.
#   (c) BACKSTOP — any other producer failure is STATED. Driven with a stub `awk` on PATH
#       that exits nonzero, so the arm measures the status check rather than a locale.
S174K_DIR=$(mktemp -d 2>/dev/null)
if [ ! -f "$S174_CHECKER" ]; then
  ng "174k: scripts/lint_citations.sh absent — the producer's failure posture is unmeasured (PR #677)"
elif [ -z "$S174K_DIR" ] || [ ! -d "$S174K_DIR" ]; then
  ng "174k: mktemp -d failed — the producer's failure posture is unmeasured (PR #677)"
else
  S174K_WORK="$S174K_DIR/work"
  mkdir -p "$S174K_WORK" "$S174K_DIR/bin"
  git init -q "$S174K_WORK" 2>/dev/null
  (
    cd "$S174K_WORK" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf 'an ordinary tracked artifact\n' > tracked.md
    git add tracked.md >/dev/null 2>&1
    git commit -q -m 'chore: seed' >/dev/null 2>&1
  ) >/dev/null 2>&1
  # A raw invalid-UTF-8 byte pair on line 1, then a span that is a genuine defect.
  printf 'Z: \200\377 an invalid byte pair right at the top\n' > "$S174K_WORK/probe.md"
  printf -- '- `tracked.md` states "a phrase that is a genuine defect here" — must still be reported.\n' >> "$S174K_WORK/probe.md"
  printf '#!/bin/sh\nexit 7\n' > "$S174K_DIR/bin/awk"
  chmod +x "$S174K_DIR/bin/awk"
  s174k_cls=$(s174_count 'unresolved' "$(bash "$S174_CHECKER" "$S174K_WORK/probe.md" 2>/dev/null)")
  s174k_rc=0
  bash "$S174_CHECKER" "$S174K_WORK/probe.md" >/dev/null 2>&1 || s174k_rc=$?
  s174k_locale=$(grep -cE '^[[:space:]]*LC_ALL=C awk ' "$S174_CHECKER" || true)
  s174k_sentinel=$( PATH="$S174K_DIR/bin:$PATH" bash "$S174_CHECKER" "$S174K_WORK/probe.md" 2>&1 >/dev/null \
    | grep -cF 'the extractor exited' || true )
  s174k_src=0
  PATH="$S174K_DIR/bin:$PATH" bash "$S174_CHECKER" "$S174K_WORK/probe.md" >/dev/null 2>&1 || s174k_src=$?
  if [ "$s174k_cls" -eq 1 ] && [ "$s174k_rc" -eq 0 ] \
     && [ "$s174k_locale" -ge 1 ] \
     && [ "$s174k_sentinel" -ge 1 ] && [ "$s174k_src" -eq 0 ]; then
    ok "174k: a body carrying invalid UTF-8 still reports the defect after it, the extractor is invoked under LC_ALL=C, and a producer that dies for any other reason states so on stderr — while the exit code stays 0 on both paths (PR #677)"
  else
    ng "174k: an invalid-UTF-8 body must still classify its later spans (LC_ALL=C on the extractor, pinned in source), a dead producer must state 'the extractor exited' on stderr, and both paths must still exit 0 — got unresolved=$s174k_cls rc=$s174k_rc lc-all-c-sites=$s174k_locale sentinel=$s174k_sentinel rc(stub)=$s174k_src (PR #677)"
  fi
fi
if [ -n "$S174K_DIR" ] && [ -d "$S174K_DIR" ]; then rm -rf "$S174K_DIR"; fi

# §174l (NEUTRALISED BYTES, PR #677): raw C0 control bytes in a body must never
# reach the reader's stdout. CR and ESC are not whitespace, so without
# neutralisation an attribution or span carrying a VT escape sequence reaches the
# column-0 report line, where a terminal renders a redraw instead of the bytes —
# a clean-looking line over a defect report. The extractor turns every C0 control
# except tab into a space, one byte for one; the first probe below carries such
# bytes outside any fence, and a genuine span on the same body must still resolve
# so the arm cannot green on an empty report.
S174L_DIR=$(mktemp -d 2>/dev/null)
if [ ! -f "$S174_CHECKER" ]; then
  ng "174l: scripts/lint_citations.sh absent — the control-byte posture is unmeasured (PR #677)"
elif [ -z "$S174L_DIR" ] || [ ! -d "$S174L_DIR" ]; then
  ng "174l: mktemp -d failed — the control-byte posture is unmeasured (PR #677)"
else
  S174L_WORK="$S174L_DIR/work"
  git init -q "$S174L_WORK" 2>/dev/null
  (
    cd "$S174L_WORK" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf 'a plain control span for the control byte arm\n' > tracked.md
    git add tracked.md >/dev/null 2>&1
    git commit -q -m seed >/dev/null 2>&1
  ) >/dev/null 2>&1
  # Line 1: an ESC[2K/ESC[1G redraw inside the attribution token and a CR inside
  # the span. Line 2: the ordinary control that must still resolve.
  printf -- '- `tr\033[2K\033[1Gacked.md` states "a redraw carrying span for\r this control byte arm" here.\n' > "$S174L_WORK/probe.md"
  # CR inside the ATTRIBUTION token: an attribution is echoed into the report
  # sentence, so a CR surviving neutralisation reaches stdout there — the one
  # channel the span-only probe above cannot exercise.
  printf -- '- `ev\rildoc.md` states "a fake quote attributed here four words" x.\n' >> "$S174L_WORK/probe.md"
  printf -- '- `tracked.md` states "a plain control span for the control byte arm" too.\n' >> "$S174L_WORK/probe.md"
  s174l_out="$(bash "$S174_CHECKER" "$S174L_WORK/probe.md" 2>/dev/null)"
  s174l_ctl=$(printf '%s\n' "$s174l_out" | LC_ALL=C grep -c "$(printf '[\033\r]')" || true)
  s174l_res=$(s174_count 'resolves' "$s174l_out")
  s174l_in=$(LC_ALL=C grep -c "$(printf '[\033\r]')" "$S174L_WORK/probe.md" || true)
  if [ "$s174l_in" -ge 1 ] && [ "$s174l_ctl" -eq 0 ] && [ "$s174l_res" -ge 1 ]; then
    ok "174l: CR and ESC bytes in a body are neutralised before they can reach a report line — the reader's stdout carries no control byte while the body does, and the clean span on the same body still resolves (PR #677)"
  else
    ng "174l: a body carrying CR/ESC outside fences must yield a stdout with zero control bytes and the clean span must still resolve — got body-control-lines=$s174l_in stdout-control-lines=$s174l_ctl resolves=$s174l_res (PR #677)"
  fi
fi
if [ -n "$S174L_DIR" ] && [ -d "$S174L_DIR" ]; then rm -rf "$S174L_DIR"; fi

# §174m (THE NORMALISING RUNG IS BYTE-ORIENTED, PR #677): in a UTF-8 locale one
# invalid byte in a CITED artifact is fatal to awk's regex machinery, and a rung
# that dies there turns a span that normalises — a non-defect — into `unresolved`,
# a defect. `norm_hit` therefore runs its awk under LC_ALL=C, like the extractor.
# Asserted as an OUTCOME under a UTF-8 locale (the first one the system offers)
# so the pin cannot go stale as a string while the behaviour regresses.
S174M_DIR=$(mktemp -d 2>/dev/null)
S174M_LOC=""
# Captured once, and grep runs WITHOUT -q: under pipefail a -q early exit kills
# `locale -a` with SIGPIPE and the pipeline reads as a miss.
s174m_all=$(locale -a 2>/dev/null || true)
for s174m_c in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
  if printf '%s\n' "$s174m_all" | grep -ixF "$s174m_c" >/dev/null; then S174M_LOC="$s174m_c"; break; fi
done
if [ ! -f "$S174_CHECKER" ]; then
  ng "174m: scripts/lint_citations.sh absent — the normalising rung's locale posture is unmeasured (PR #677)"
elif [ -z "$S174M_DIR" ] || [ ! -d "$S174M_DIR" ]; then
  ng "174m: mktemp -d failed — the normalising rung's locale posture is unmeasured (PR #677)"
else
  S174M_WORK="$S174M_DIR/work"
  git init -q "$S174M_WORK" 2>/dev/null
  (
    cd "$S174M_WORK" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    # An invalid UTF-8 byte pair on line 1, then the span WRAPPED across two lines
    # so rung 1 misses and only the normalising rung can find it.
    printf 'Z \200\377 an invalid byte pair right at the top\n' > art.md
    printf 'gamma delta epsilon\nzeta eta theta\n' >> art.md
    git add art.md >/dev/null 2>&1
    git commit -q -m seed >/dev/null 2>&1
  ) >/dev/null 2>&1
  printf -- '- `art.md` states "gamma delta epsilon zeta eta theta" across a wrap.\n' > "$S174M_WORK/probe.md"
  s174m_out="$(LC_ALL="${S174M_LOC:-C}" LANG="${S174M_LOC:-C}" bash "$S174_CHECKER" "$S174M_WORK/probe.md" 2>/dev/null)"
  s174m_norm=$(s174_count 'normalized' "$s174m_out")
  s174m_bad=$(( $(s174_count 'unresolved' "$s174m_out") + $(s174_count 'site-mismatch' "$s174m_out") ))
  if [ "$s174m_norm" -eq 1 ] && [ "$s174m_bad" -eq 0 ]; then
    ok "174m: a wrapped span in a cited artifact that also carries an invalid UTF-8 byte still reports normalized under a UTF-8 locale (${S174M_LOC:-none offered; ran under C}) — the rung is byte-oriented, so an author-supplied byte cannot convert a non-defect into a defect (PR #677)"
  else
    ng "174m: the wrapped span must report normalized (not unresolved/site-mismatch) although its file carries an invalid UTF-8 byte, under locale ${S174M_LOC:-C} — got normalized=$s174m_norm defect-classes=$s174m_bad (PR #677)"
  fi
fi
if [ -n "$S174M_DIR" ] && [ -d "$S174M_DIR" ]; then rm -rf "$S174M_DIR"; fi

# §174n (OBJECT-STORE REFUSAL ON THE RESOLVED PATH IS CASE-FOLDED, PR #677): a
# tracked symlink whose TARGET is a case-varied `.GIT` resolves — on a
# case-insensitive filesystem — to the object store under a spelling a
# case-sensitive pattern admits, because `pwd -P` appends the link target without
# canonicalising case. The resolved-path refusal therefore case-folds, and the
# alias must land on the SAME object-store sentence as a spelled `.git/`
# attribution. On a case-sensitive filesystem the alias target does not exist, so
# the honest refusal there is the absent-parent one — still `unresolvable-locally`;
# the arm asserts the non-defect class on both, and sentence identity where the
# filesystem makes the alias real.
S174N_DIR=$(mktemp -d 2>/dev/null)
if [ ! -f "$S174_CHECKER" ]; then
  ng "174n: scripts/lint_citations.sh absent — the case-folded object-store refusal is unmeasured (PR #677)"
elif [ -z "$S174N_DIR" ] || [ ! -d "$S174N_DIR" ]; then
  ng "174n: mktemp -d failed — the case-folded object-store refusal is unmeasured (PR #677)"
else
  S174N_WORK="$S174N_DIR/work"
  git init -q "$S174N_WORK" 2>/dev/null
  (
    cd "$S174N_WORK" || exit 1
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf 'a case fold probe span for this arm\n' > tracked.md
    ln -s .GIT gitcased
    git add tracked.md gitcased >/dev/null 2>&1
    git commit -q -m seed >/dev/null 2>&1
  ) >/dev/null 2>&1
  : > "$S174N_WORK/S174NCaseProbe"
  s174n_ci=0
  [ -e "$S174N_WORK/s174ncaseprobe" ] && s174n_ci=1
  rm -f "$S174N_WORK/S174NCaseProbe"
  {
    printf -- '- `gitcased/config` states "a case fold probe span for this arm" via the alias.\n'
    printf -- '- `.git/config` states "a case fold probe span for this arm" by spelling.\n'
  } > "$S174N_WORK/probe.md"
  s174n_out="$(bash "$S174_CHECKER" "$S174N_WORK/probe.md" 2>/dev/null)"
  s174n_remote=$(s174_count 'unresolvable-locally' "$s174n_out")
  s174n_leak=$(( $(s174_count 'resolves' "$s174n_out") + $(s174_count 'normalized' "$s174n_out") + $(s174_count 'site-mismatch' "$s174n_out") + $(s174_count 'unresolved' "$s174n_out") ))
  s174n_sent=$(printf '%s\n' "$s174n_out" | grep -E '^[^[:space:]].*:[0-9]+: unresolvable-locally — ' \
    | sed -E 's/^.*unresolvable-locally — attributed to [^,]*,//' | sort -u | wc -l | tr -d ' ')
  if [ "$s174n_remote" -eq 2 ] && [ "$s174n_leak" -eq 0 ] \
     && { [ "$s174n_ci" -eq 0 ] || [ "$s174n_sent" -eq 1 ]; }; then
    if [ "$s174n_ci" -eq 1 ]; then
      ok "174n: a tracked symlink alias to a case-varied .GIT lands on the SAME object-store sentence as a spelled .git/ attribution — the resolved-path refusal is case-folded, so the alias is not an oracle (PR #677)"
    else
      ok "174n: the case-varied .GIT alias stays unresolvable-locally on this case-sensitive filesystem (target absent), and no ladder class leaks — the case-fold path is exercised where the filesystem makes it real (PR #677)"
    fi
  else
    ng "174n: both the .GIT-target alias and the spelled .git/ attribution must report unresolvable-locally with no ladder class leaking, sharing one sentence where the filesystem is case-insensitive — got unresolvable-locally=$s174n_remote leaked=$s174n_leak case-insensitive=$s174n_ci distinct-sentences=$s174n_sent (PR #677)"
  fi
fi
if [ -n "$S174N_DIR" ] && [ -d "$S174N_DIR" ]; then rm -rf "$S174N_DIR"; fi

# ---------- §175: claim half-life discipline (#680) ----------
# SPEC §1.10(c) plus its two agent bindings. Doc-lock shape (the §174a precedent):
# the rule itself is reviewer judgment with no mechanical body-reader, so the
# mechanical face is a content lock over the three contract carriers — SPEC states
# part (c); code-reviewer's default remedy for a volatile claim is removal or
# pinning; finding-judge's recurrence rule takes instance-correction off the table
# for a claim-class finding whose axis key was confirmed in a resolved prior round.
# The CLAUDE.md pointer (AC 5) is deliberately NOT locked here: AC 4's mandate is
# AC 1-3, and §104b already guards that file's mechanical half (the byte budget).
S175_SPEC="$SHELL_ROOT/SPEC.md"
S175_CR="$SHELL_ROOT/.claude/agents/code-reviewer.md"
S175_FJ="$SHELL_ROOT/.claude/agents/finding-judge.md"
if [ ! -f "$S175_SPEC" ] || [ ! -f "$S175_CR" ] || [ ! -f "$S175_FJ" ]; then
  ng "175: SPEC.md or an agent carrier absent — the §1.10(c) half-life discipline is unlocked (#680)"
else
  s175_spec=ok; s175_cr=ok; s175_fj=ok
  grep -qF '**(c) A durable artifact carries no claim that expires before the artifact does' "$S175_SPEC" || s175_spec=MISSING
  grep -qF 'Claim volatility (SPEC §1.10(c))' "$S175_CR" || s175_cr=MISSING
  grep -qF 'Recurrence rule (SPEC §1.10(c))' "$S175_FJ" || s175_fj=MISSING
  if [ "$s175_spec" = ok ] && [ "$s175_cr" = ok ] && [ "$s175_fj" = ok ]; then
    ok "175: SPEC §1.10 carries part (c) and both agent carriers bind it — code-reviewer's removal-or-pin default remedy, finding-judge's recurrence rule (#680)"
  else
    ng "175: the §1.10(c) contract must live in all three carriers — SPEC part (c)=$s175_spec code-reviewer binding=$s175_cr finding-judge recurrence rule=$s175_fj (#680)"
  fi
fi

# ---------- §176: safe_source paths in commands resolve from the repo root (#648) ----------
# safe_source (.claude/hooks/hookrt.sh ~L230) does `[ -f "$1" ]` against the
# CALLER's cwd, so a documented bare-relative `safe_source helpers/X.sh` only
# resolves when cwd happens to be .claude/hooks/; a command file executed from the
# project root fails to source the helper AND emits a false `helper-missing` warn.
# The repo-root-resolvable call-form threads the ghjig-root symlink:
# `.claude/ghjig-root/.claude/hooks/helpers/X.sh` (the form `blast_radius.sh`
# already uses at complete-directive.md:31 / ship.md:18). This arm asserts every
# DOCUMENTED safe_source invocation in .claude/commands/*.md names a path that
# resolves from the repo root.
#
# EXTRACTION CHOICE (#648): a "documented safe_source invocation" is anchored on
# the INVOCATION SHAPE — the literal token `safe_source` followed by whitespace and
# a PATH token drawn from the positive class [A-Za-z0-9._/-]. That positive class
# stops at the closing backtick/quote/space, so the extracted first argument is the
# bare path with surrounding backticks/quotes already excluded. Prose that merely
# writes the word safe_source WITHOUT a following path token (e.g. "on a
# `safe_source` miss, degrade…") yields no token and is correctly ignored — the
# arm is measuring call-forms, not mentions.
#
# RESOLUTION: a token RESOLVES iff [ -f "$SHELL_ROOT/<token>" ]. $SHELL_ROOT is the
# repo root, and .claude/ghjig-root is a symlink to it, so
# `.claude/ghjig-root/.claude/hooks/helpers/X.sh` is a real file from the root while
# a bare `helpers/X.sh` has no counterpart under the root and fails.
#
# WHY THE TWO-SIDED PROOF IS A SEPARATE $TMP FIXTURE (176b), not the live scan:
# the live tree today carries ONLY failing safe_source sites (the 4 bare
# reviewer_audit ones) and NO resolving `safe_source ` site — the blast_radius
# call-forms use the bare word "source", not "safe_source", so they are not
# safe_source invocations. Before the Phase-C fix the live scan is one-sided (all
# offenders); after it, one-sided (all pass). So the demonstrable two-sidedness —
# a resolving path passes, a bare-relative path fails under the SAME
# extractor+resolver — is proven over controlled fixtures in 176b, which stays
# green across the fix and fails loud if a future edit abbreviates the resolver.
s176_extract() {  # $1=file → prints "line:token" for each safe_source invocation
  awk 'BEGIN { re = "safe_source[ \t]+[A-Za-z0-9._/-]+" }
    { s = $0
      while (match(s, re)) {
        tok = substr(s, RSTART, RLENGTH); sub(/^safe_source[ \t]+/, "", tok)
        print NR ":" tok
        s = substr(s, RSTART + RLENGTH) } }' "$1"
}

# §176a (LIVE SCAN, the RED arm): every safe_source path in every command file
# resolves from the repo root. ANTI-VACUITY: a floor of 4 (the four Directive #356
# reject-audit sites known at #648) — a broken extractor that matches zero tokens
# trips the floor and reds as UNTESTED rather than passing vacuously. The floor is
# a `>=`, not an exact count, so it survives future command edits that add sites.
s176_cnt=0; s176_bad=""; s176_floor=4
for s176_f in "$SHELL_ROOT"/.claude/commands/*.md; do
  [ -f "$s176_f" ] || continue
  s176_base=$(basename "$s176_f")
  while IFS=: read -r s176_ln s176_tok; do
    [ -z "$s176_tok" ] && continue
    s176_cnt=$(( s176_cnt + 1 ))
    [ -f "$SHELL_ROOT/$s176_tok" ] || s176_bad="$s176_bad ${s176_base}:${s176_ln}:${s176_tok}"
  done < <(s176_extract "$s176_f")
done
if [ "$s176_cnt" -ge "$s176_floor" ] && [ -z "$s176_bad" ]; then
  ok "176a: every safe_source invocation in .claude/commands/*.md names a repo-root-resolvable path — scanned $s176_cnt (floor $s176_floor) (#648)"
else
  ng "176a: a documented safe_source path does not resolve from the repo root (a bare-relative helpers/X.sh resolves only when cwd is .claude/hooks/) — scanned $s176_cnt (floor $s176_floor), offenders:$s176_bad (#648)"
fi

# §176b (TWO-SIDED FIXTURE PROOF): the same extractor+resolver, run over two
# controlled .md fixtures — one line carrying a resolving safe_source path, one a
# bare-relative path. Asserts the resolving side PASSES the [ -f ] and the bare
# side FAILS it, each yielding exactly one token. This makes the resolvability
# check demonstrably two-sided independent of the live tree's current one-sidedness.
s176_fx="$TMP/s176_cmds"; mkdir -p "$s176_fx"
printf '%s\n' 'Reject-audit: source `hookrt.sh` + `safe_source .claude/ghjig-root/.claude/hooks/helpers/reviewer_audit.sh reviewer-reject`, then …' > "$s176_fx/resolving.md"
printf '%s\n' 'Reject-audit: source `hookrt.sh` + `safe_source helpers/reviewer_audit.sh reviewer-reject`, then …' > "$s176_fx/bare.md"
s176_fx_res_cnt=0; s176_fx_res_unres=0
while IFS=: read -r s176_ln s176_tok; do
  [ -z "$s176_tok" ] && continue
  s176_fx_res_cnt=$(( s176_fx_res_cnt + 1 ))
  [ -f "$SHELL_ROOT/$s176_tok" ] || s176_fx_res_unres=$(( s176_fx_res_unres + 1 ))
done < <(s176_extract "$s176_fx/resolving.md")
s176_fx_bare_cnt=0; s176_fx_bare_unres=0
while IFS=: read -r s176_ln s176_tok; do
  [ -z "$s176_tok" ] && continue
  s176_fx_bare_cnt=$(( s176_fx_bare_cnt + 1 ))
  [ -f "$SHELL_ROOT/$s176_tok" ] || s176_fx_bare_unres=$(( s176_fx_bare_unres + 1 ))
done < <(s176_extract "$s176_fx/bare.md")
if [ "$s176_fx_res_cnt" -eq 1 ] && [ "$s176_fx_res_unres" -eq 0 ] \
   && [ "$s176_fx_bare_cnt" -eq 1 ] && [ "$s176_fx_bare_unres" -eq 1 ]; then
  ok "176b: two-sided — a resolving safe_source path passes and a bare-relative one fails under the same extractor+resolver (#648)"
else
  ng "176b: the resolvability check is not two-sided — resolving(tokens=$s176_fx_res_cnt unresolved=$s176_fx_res_unres, want 1/0) bare(tokens=$s176_fx_bare_cnt unresolved=$s176_fx_bare_unres, want 1/1) (#648)"
fi

# ---------- §177: the bounded execution scope is stated in BOTH reviewer contracts (#650) ----------
# SPEC §4.5 (code-reviewer) + §4.13 (finding-judge) landed the Phase-A contract: a
# reviewer that verifies by execution is WRITE-confined, not read-confined — the run
# is scratch-confined (cwd + every write inside the agent's own scratch directory),
# ambient-tree reads stay permitted, and execution against the ambient worktree (cwd
# IS the tree, or writes LAND in it) is the forbidden departure. Phase C restates that
# scope in each agent file. This arm is the content lock over that restatement.
#
# HONESTY (AC6 — TEXT PRESENCE, NOT RUNTIME CONFORMANCE). This arm verifies only that
# each contract file CARRIES the scope statement. It does NOT — and cannot here —
# verify that a RUNNING reviewer actually kept its cwd and writes inside scratch: that
# would need a per-subagent execution-attribution observable (a PostToolUse-style trail
# naming the executing subagent and its cwd/writes), which SPEC §4.5 records as ABSENT
# today. So this is a "the files STATE the boundary" lock, worded as such in ok/ng — a
# green here says the contract is written, not that the boundary was honoured at runtime.
#
# ANCHOR (what Phase C must write into BOTH .claude/agents/code-reviewer.md and
# .claude/agents/finding-judge.md): a line-anchored heading `## Execution scope (#650)`
# AND the literal phrase `write-confinement, not read-confinement`. The phrase is the
# discriminator that separates this scope from the pre-existing git-only
# `## Working-tree discipline (#285)` line both files already carry — a file that has
# only the #285 discipline (read-only-git, no execution-scope statement) must NOT match.
#
# SYMMETRY (AC7): §177a checks BOTH files independently and NAMES the one lacking the
# scope, so Phase C cannot satisfy it by editing only one file. TWO-SIDEDNESS (AC6) is
# proven both in-tree (a file with the scope passes; a file without it reds) and, so it
# is demonstrable independent of the live tree, over controlled $TMP fixtures in §177b.
# ANTI-VACUITY: §177a asserts both target files exist and are non-empty (were read) —
# an absent/empty file reds as UNTESTED (offender named), never passes by scanning zero.
S177_CR="$SHELL_ROOT/.claude/agents/code-reviewer.md"
S177_FJ="$SHELL_ROOT/.claude/agents/finding-judge.md"
s177_has_scope() {  # $1=file → 0 iff it carries the bounded-execution-scope statement
  grep -qE '^## Execution scope \(#650\)$' "$1" 2>/dev/null \
    && grep -qF 'write-confinement, not read-confinement' "$1" 2>/dev/null
}

# §177a (LIVE SYMMETRY LOCK — LOAD-BEARING RED pre-fix): both reviewer contracts carry
# the scope statement. Names which file lacks it; reds as UNTESTED on an absent/empty file.
s177_miss=""
s177_n=0
for s177_f in "$S177_CR" "$S177_FJ"; do
  s177_base=$(basename "$s177_f")
  if [ ! -s "$s177_f" ]; then
    s177_miss="$s177_miss ${s177_base}=ABSENT-OR-EMPTY"
    continue
  fi
  s177_n=$(( s177_n + 1 ))
  s177_has_scope "$s177_f" || s177_miss="$s177_miss ${s177_base}=NO-EXEC-SCOPE"
done
if [ "$s177_n" -eq 2 ] && [ -z "$s177_miss" ]; then
  ok "177a: TEXT-PRESENCE lock (not runtime conformance) — both code-reviewer.md and finding-judge.md STATE the bounded execution scope (## Execution scope (#650) + 'write-confinement, not read-confinement'); this asserts the contracts CARRY the boundary, NOT that a running reviewer stayed scratch-confined (that needs the per-subagent execution-attribution observable SPEC §4.5 records as absent) (#650)"
else
  ng "177a: each execution-carrying reviewer contract must STATE the bounded execution scope (write-confinement: scratch-confined run+writes, ambient reads permitted) — NOT merely the git-only '## Working-tree discipline (#285)' line both already carry; checked $s177_n of 2, offenders:$s177_miss — TEXT-PRESENCE only, this arm does not verify runtime scratch-confinement (#650)"
fi

# §177b (TWO-SIDED FIXTURE PROOF — stays GREEN across the fix): the same detector run
# over two controlled agent-file-shaped fixtures — one carrying the git discipline AND
# the execution-scope statement (must PASS), one carrying ONLY the git-scoped
# ## Working-tree discipline line (must FAIL). Makes the discrimination demonstrable
# independent of the live tree's current all-missing one-sidedness.
s177_fx="$TMP/s177_agents"; mkdir -p "$s177_fx"
printf '%s\n' \
  '## Working-tree discipline (#285)' \
  'Use read-only git only; never a tree-mutating git command.' \
  '' \
  '## Execution scope (#650)' \
  'The scope is write-confinement, not read-confinement: ambient-tree reads are permitted; the run is scratch-confined (cwd + every write inside your own scratch directory).' \
  > "$s177_fx/with-scope.md"
printf '%s\n' \
  '## Working-tree discipline (#285)' \
  'Use read-only git only; never a tree-mutating git command.' \
  > "$s177_fx/git-only.md"
if s177_has_scope "$s177_fx/with-scope.md" && ! s177_has_scope "$s177_fx/git-only.md"; then
  ok "177b: two-sided — an agent fixture carrying the execution-scope statement passes the detector and one carrying ONLY the git-scoped ## Working-tree discipline (#285) fails it, under the same anchor (#650)"
else
  ng "177b: the execution-scope detector is not two-sided — the with-scope fixture must PASS and the git-only fixture must FAIL under the same anchor (with-scope=$(s177_has_scope "$s177_fx/with-scope.md" && echo pass || echo fail) git-only=$(s177_has_scope "$s177_fx/git-only.md" && echo pass || echo fail)) (#650)"
fi
