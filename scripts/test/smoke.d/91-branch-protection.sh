# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded source
# below never runs at runtime (the orchestrator already sourced the preamble); it
# only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §155: tier-3 server-side authority — install_branch_protection.sh (#613) ----------
# SPEC §6.7 "Tier-3 server-side authority (delivered)". The tier-3 capability is
# `scripts/install_branch_protection.sh` — a capability-adaptive escalation ladder:
#   (1) rulesets API + admin  → SET a named per-repo ruleset `ghjig-tier3` BY ID
#       (zero-clobber: never touches a sibling ruleset or classic protection);
#   (2) rulesets unsupported (404/older GHES) + admin → classic
#       branches/{b}/protection FLOOR-MERGE PUT (GET → more-restrictive per facet
#       → PUT the union; never a destructive full-replace);
#   (3) no admin → verify + prescribe, exit 0, never a hard failure.
# Verify (any actor) reads GET rules/branches/{b} ∪ GET branches/{b}/protection over
# five facets and classifies configured/partial/absent/unreadable (fail-closed
# honest: unreadable is never silently promoted to configured). Invariants: host-
# pinned to the repo host (#610/#614), repo-scoped (no git config --global/--system),
# idempotent, SSOT single-source of the facet spec across SET + verify.
#
# Phase C (the script) DOES NOT EXIST YET, so every §155 case below is RED now via
# the else-branch `ng`s and goes GREEN when the script + behavior land.
#
# ── Shim boundary (READ THIS) ─────────────────────────────────────────────────
# The `gh` shim on PATH serves canned JSON per subcommand/args and RECORDS every
# call (argv + any --input payload) to $GH_SHIM_STATE/calls. The assertions test
# CALL SHAPE — host-pin (--hostname <repo-host>), by-id ruleset update, zero-
# clobber (no sibling/DELETE/classic-PUT), the classic floor-merge PUT union, and
# exit codes — NOT GitHub's real server-side enforcement semantics (a shim cannot
# and must not model those). Where a full behavioral assertion is impractical
# pre-Code the AC permits a static content-lock (§155-8).

S613_SCRIPT="$SHELL_ROOT/scripts/install_branch_protection.sh"

# The harness needs only mktemp/grep/awk (always present) + a POSIX sh for the
# shim; the script's own tool deps (gh/jq) are Phase C's concern and are shimmed.
S613_DIR=$(mktemp -d)
S613_BIN="$S613_DIR/bin"
S613_CWD="$S613_DIR/cwd"
mkdir -p "$S613_BIN" "$S613_CWD"

# ── The recording gh shim ─────────────────────────────────────────────────────
# Fixtures live under $GH_SHIM_STATE (one dir per case):
#   repo_url            full `gh repo view --json url` value (empty ⇒ degenerate host)
#   perm                ADMIN | WRITE  (viewerPermission)
#   rulesets_404        (touch) ⇒ the rulesets API 404s (older GHES) → classic fallback
#   rulesets_500        (touch) ⇒ the rulesets API 5xx-errors (NON-404; must NOT be
#                       treated as "unsupported" → must NOT down-convert to classic)
#   rulesets_list.json  the `GET .../rulesets` LIST body (for finding ghjig-tier3 by id)
#   rules_branches.json the `GET .../rules/branches/{b}` verify body ([] ⇒ none)
#   rules_403           (touch) ⇒ that GET 403s (unreadable)
#   rules_500           (touch) ⇒ that GET 5xx-errors (NON-404, NON-403 → unreadable)
#   classic.json        the `GET .../branches/{b}/protection` body (absent file ⇒ 404)
#   classic_403         (touch) ⇒ that GET 403s (unreadable)
#   classic_500         (touch) ⇒ that GET 5xx-errors (NON-404, NON-403 → unreadable)
#   set_fail            (touch) ⇒ the MUTATING call (ruleset PATCH/POST or classic
#                       PUT) exits non-zero — the SET must NOT report success
cat > "$S613_BIN/gh" <<'SHIM'
#!/bin/sh
: "${GH_SHIM_STATE:?}"
d="$GH_SHIM_STATE"

# #622: when e500_404 is present, non-404 (5xx) error messages carry the bare
# substring "404" (a trace id) — to prove the 404 discrimination matches the
# structured HTTP-404 status phrasing, NOT a bare "404" substring.
x404=''; [ -f "$d/e500_404" ] && x404=' (trace-id 404abc)'

# --- method + --input extraction (for the recorded PUT payload) ---
method=GET; prev=
for a in "$@"; do
  case "$a" in --method=*) method=${a#--method=} ;; -X?*) method=${a#-X} ;; esac
  case "$prev" in --method|-X) method=$a ;; esac
  prev=$a
done
inval=; prev=
for a in "$@"; do
  case "$a" in --input=*) inval=${a#--input=} ;; esac
  case "$prev" in --input) inval=$a ;; esac
  prev=$a
done

# --- record the call: one ARGV line, each arg bracketed + space-separated ---
{ printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$d/calls"
if [ -n "$inval" ]; then
  if [ "$inval" = "-" ]; then body=$(cat); else body=$(cat "$inval" 2>/dev/null); fi
  printf 'STDIN: %s\n' "$body" >> "$d/calls"
fi

case "$*" in
  *"repo view"*url*)              cat "$d/repo_url" 2>/dev/null ;;
  *"repo view"*viewerPermission*) cat "$d/perm" 2>/dev/null ;;
  *"repo view"*defaultBranchRef*) printf 'main\n' ;;
  *"repo view"*nameWithOwner*)    printf 'o/r\n' ;;
  *api*rules/branches*)           # the verify "rules" union arm (readable by any actor)
      [ -f "$d/rules_403" ] && { echo 'gh: 403 Forbidden' >&2; exit 1; }
      [ -f "$d/rules_500" ] && { echo "gh: 500 Internal Server Error$x404" >&2; exit 1; }
      cat "$d/rules_branches.json" 2>/dev/null || printf '[]\n' ;;
  *api*rulesets*)                 # the rulesets API (SET path 1)
      [ -f "$d/rulesets_404" ] && { echo 'gh: 404 Not Found (rulesets unsupported)' >&2; exit 1; }
      [ -f "$d/rulesets_500" ] && { echo "gh: 500 Internal Server Error$x404" >&2; exit 1; }
      case "$method" in
        GET) case "$*" in
               *rulesets/*) printf '{"id":0,"name":"ghjig-tier3"}\n' ;;   # a by-id GET
               *)           cat "$d/rulesets_list.json" 2>/dev/null || printf '[]\n' ;;
             esac ;;
        *)   [ -f "$d/set_fail" ] && { echo 'gh: 500 Internal Server Error' >&2; exit 1; }
             printf '{"id":111,"name":"ghjig-tier3"}\n' ;;               # POST/PUT/PATCH accepted
      esac ;;
  *api*branches*protection*)      # classic branch protection (SET path 2 / verify union)
      case "$method" in
        GET) [ -f "$d/classic_403" ] && { echo 'gh: 403 Forbidden' >&2; exit 1; }
             [ -f "$d/classic_500" ] && { echo "gh: 500 Internal Server Error$x404" >&2; exit 1; }
             if [ -f "$d/classic.json" ]; then cat "$d/classic.json"; else echo 'gh: 404 Not Found' >&2; exit 1; fi ;;
        *)   [ -f "$d/set_fail" ] && { echo 'gh: 500 Internal Server Error' >&2; exit 1; }
             printf '{}\n' ;;   # PUT accepted (already recorded above)
      esac ;;
esac
exit 0
SHIM
chmod +x "$S613_BIN/gh"

# ── Fixture builders ──────────────────────────────────────────────────────────
s613_state() {  # $1=repo-url(-or-empty)  $2=perm(ADMIN|WRITE) -> echoes a fresh state dir
  _d=$(mktemp -d)
  printf '%s\n' "$1" > "$_d/repo_url"
  printf '%s\n' "$2" > "$_d/perm"
  : > "$_d/calls"
  printf '%s' "$_d"
}
S613_HOST='https://github.example.com/o/r'   # a non-github.com (GHES) repo url

# Full five-facet "rules/branches" body (all facets present → configured).
s613_rules_full='[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_last_push_approval":true}},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"ci"}]}},{"type":"non_fast_forward"},{"type":"deletion"},{"type":"creation"}]'
# Partial (only PR-required present) → partial.
s613_rules_partial='[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]'

# ── Assertions (gated: the script must exist to exercise behavior) ─────────────
if [ -x "$S613_SCRIPT" ]; then

  # ── §155-1: verify classification (configured / partial / absent / unreadable) ──
  # `--check` classifies the GET rules/branches ∪ classic GET union. The shim's
  # boundary is call shape, not enforcement; the classification WORD in the output
  # is the observable contract.

  # 1a configured — full rules present.
  s1a=$(s613_state "$S613_HOST" ADMIN); printf '%s' "$s613_rules_full" > "$s1a/rules_branches.json"
  o1a=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s1a" bash "$S613_SCRIPT" --check 2>&1)
  if printf '%s' "$o1a" | grep -qw configured && ! printf '%s' "$o1a" | grep -qwE 'unreadable|absent'; then
    ok "155-1a: --check classifies a fully-protected repo as 'configured' (#613)"
  else
    ng "155-1a: full-protection fixture not classified 'configured' (got: $(printf '%s' "$o1a" | tr '\n' ' ')) (#613)"
  fi

  # 1b partial — only some facets present.
  s1b=$(s613_state "$S613_HOST" ADMIN); printf '%s' "$s613_rules_partial" > "$s1b/rules_branches.json"
  o1b=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s1b" bash "$S613_SCRIPT" --check 2>&1)
  if printf '%s' "$o1b" | grep -qw partial; then
    ok "155-1b: --check classifies a partially-protected repo as 'partial' (#613)"
  else
    ng "155-1b: partial fixture not classified 'partial' (got: $(printf '%s' "$o1b" | tr '\n' ' ')) (#613)"
  fi

  # 1c absent — empty rules AND classic 404.
  s1c=$(s613_state "$S613_HOST" ADMIN); printf '[]\n' > "$s1c/rules_branches.json"   # no classic.json ⇒ 404
  o1c=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s1c" bash "$S613_SCRIPT" --check 2>&1)
  if printf '%s' "$o1c" | grep -qw absent; then
    ok "155-1c: --check classifies an unprotected repo as 'absent' (#613)"
  else
    ng "155-1c: empty fixture not classified 'absent' (got: $(printf '%s' "$o1c" | tr '\n' ' ')) (#613)"
  fi

  # 1d unreadable — both GETs 403. Fail-closed honest: NEVER silently 'configured'.
  s1d=$(s613_state "$S613_HOST" WRITE); : > "$s1d/rules_403"; : > "$s1d/classic_403"
  o1d=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s1d" bash "$S613_SCRIPT" --check 2>&1)
  if printf '%s' "$o1d" | grep -qw unreadable && ! printf '%s' "$o1d" | grep -qw configured; then
    ok "155-1d: a 403/error is classified 'unreadable', never silently 'configured' (fail-closed honest) (#613)"
  else
    ng "155-1d: 403 fixture must be 'unreadable' and not 'configured' (got: $(printf '%s' "$o1d" | tr '\n' ' ')) (#613)"
  fi

  # ── §155-2: non-admin readable verify — no 403 hard-fail ──────────────────────
  # A non-admin (WRITE) can read rules/branches, so --check exits 0 and reports.
  s2=$(s613_state "$S613_HOST" WRITE); printf '%s' "$s613_rules_full" > "$s2/rules_branches.json"; : > "$s2/classic_403"
  o2=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s2" bash "$S613_SCRIPT" --check 2>&1); rc2=$?
  if [ "$rc2" -eq 0 ] && printf '%s' "$o2" | grep -qwE 'configured|partial|absent|unreadable'; then
    ok "155-2: non-admin --check reads rules/branches, exits 0 and reports — no 403 hard-fail (rc=$rc2) (#613)"
  else
    ng "155-2: non-admin --check must exit 0 and classify (rc=$rc2, out: $(printf '%s' "$o2" | tr '\n' ' ')) (#613)"
  fi

  # ── §155-3: zero-clobber SET — touch ONLY the ghjig-tier3 ruleset, by id ──────
  # rulesets API + admin. The LIST carries ghjig-tier3 (id 111) + a sibling (id 999).
  # SET must UPDATE 111 by id and touch NOTHING else: no sibling op, no DELETE, no
  # classic protection PUT.
  s3=$(s613_state "$S613_HOST" ADMIN)
  printf '[{"id":111,"name":"ghjig-tier3"},{"id":999,"name":"org-baseline"}]\n' > "$s3/rulesets_list.json"
  ( cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s3" bash "$S613_SCRIPT" ) >/dev/null 2>&1
  s3_byid=$(grep -F 'rulesets/111' "$s3/calls" 2>/dev/null | grep -Ec '\[PUT\]|\[PATCH\]|\[-XPUT\]|\[-XPATCH\]|\[--method\] \[PUT\]|\[--method\] \[PATCH\]')
  s3_sibling=$(grep -c -F 'rulesets/999' "$s3/calls" 2>/dev/null)
  s3_delete=$(grep -Ec '\[DELETE\]|\[-XDELETE\]|\[--method\] \[DELETE\]' "$s3/calls" 2>/dev/null)
  s3_classicput=$(grep -F 'branches/main/protection' "$s3/calls" 2>/dev/null | grep -Ec '\[PUT\]|\[-XPUT\]|\[--method\] \[PUT\]')
  if [ "$s3_byid" -ge 1 ] && [ "$s3_sibling" -eq 0 ] && [ "$s3_delete" -eq 0 ] && [ "$s3_classicput" -eq 0 ]; then
    ok "155-3: SET updates ghjig-tier3 by id (rulesets/111) and clobbers nothing — no sibling/DELETE/classic-PUT (#613)"
  else
    ng "155-3: zero-clobber violated (byid=$s3_byid sibling=$s3_sibling delete=$s3_delete classicPUT=$s3_classicput) (#613)"
  fi

  # ── §155-4: GHES-404 fallback → classic floor-merge PUT (union, not replace) ──
  # rulesets 404 + admin. The classic GET carries a pre-existing STRONGER facet
  # (required_approving_review_count=3). A floor-merge PUT must PRESERVE the 3
  # (union); a destructive desired-only replace would drop it.
  s4=$(s613_state "$S613_HOST" ADMIN); : > "$s4/rulesets_404"
  printf '{"required_pull_request_reviews":{"required_approving_review_count":3},"required_status_checks":{"strict":true,"contexts":["ci"]},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}\n' > "$s4/classic.json"
  ( cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s4" bash "$S613_SCRIPT" ) >/dev/null 2>&1
  s4_put=$(grep -F 'branches/main/protection' "$s4/calls" 2>/dev/null | grep -Ec '\[PUT\]|\[-XPUT\]|\[--method\] \[PUT\]')
  s4_union=$(grep -Ec 'required_approving_review_count[^0-9]*3' "$s4/calls" 2>/dev/null)
  if [ "$s4_put" -ge 1 ] && [ "$s4_union" -ge 1 ]; then
    ok "155-4: rulesets-404 falls back to a classic protection PUT that PRESERVES the stronger facet (floor-merge union) (#613)"
  else
    ng "155-4: classic fallback must issue a union PUT keeping review_count=3 (put=$s4_put union=$s4_union) (#613)"
  fi

  # ── §155-4b: classic floor-merge PRESERVES every stronger facet (the missed HIGH) ──
  # rulesets 404 + admin. The classic GET carries a repo ALREADY stronger than the
  # desired hardcoded template across FIVE facets. A true floor-merge PUT must union-
  # preserve ALL of them; a destructive full-replace (the current defect) emits
  # contexts:[], enforce_admins:null, restrictions:null and drops require_code_owner_
  # reviews — silently DOWNGRADING a stronger repo. Boundary: this asserts the recorded
  # PUT payload's CALL SHAPE (what the union sends), not GitHub's enforcement semantics.
  s4b=$(s613_state "$S613_HOST" ADMIN); : > "$s4b/rulesets_404"
  printf '%s\n' '{"required_status_checks":{"strict":true,"contexts":["ci"]},"enforce_admins":{"enabled":true},"restrictions":{"users":["alice"],"teams":[],"apps":[]},"required_pull_request_reviews":{"require_code_owner_reviews":true,"required_approving_review_count":2,"require_last_push_approval":true}}' > "$s4b/classic.json"
  ( cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s4b" bash "$S613_SCRIPT" ) >/dev/null 2>&1
  # The only recorded STDIN in this fixture is the classic PUT payload (the prior GET
  # carries no --input), so grepping $calls targets that payload.
  s4b_put=$(grep -F 'branches/main/protection' "$s4b/calls" 2>/dev/null | grep -Ec '\[PUT\]|\[-XPUT\]|\[--method\] \[PUT\]')
  s4b_ctx=$(grep -Ec '"contexts":[[:space:]]*\[[^]]*"ci"' "$s4b/calls" 2>/dev/null)            # never emitted as []
  s4b_admins=$(grep -Ec '"enforce_admins":[[:space:]]*(true|\{)' "$s4b/calls" 2>/dev/null)      # never null/false
  s4b_restr=$(grep -Ec '"restrictions":[[:space:]]*\{' "$s4b/calls" 2>/dev/null)               # never null
  s4b_owner=$(grep -Ec '"require_code_owner_reviews":[[:space:]]*true' "$s4b/calls" 2>/dev/null) # preserved
  s4b_count=$(grep -Ec 'required_approving_review_count[^0-9]*[2-9]' "$s4b/calls" 2>/dev/null)   # ≥ current(2)
  if [ "$s4b_put" -ge 1 ] && [ "$s4b_ctx" -ge 1 ] && [ "$s4b_admins" -ge 1 ] \
     && [ "$s4b_restr" -ge 1 ] && [ "$s4b_owner" -ge 1 ] && [ "$s4b_count" -ge 1 ]; then
    ok "155-4b: classic floor-merge PRESERVES every stronger facet (contexts/enforce_admins/restrictions/code-owner/count) — no destructive full-replace (#613)"
  else
    ng "155-4b: classic PUT DOWNGRADES a stronger repo (put=$s4b_put ctx=$s4b_ctx admins=$s4b_admins restr=$s4b_restr owner=$s4b_owner count=$s4b_count; want all ≥1) (#613)"
  fi

  # ── §155-5: degrade without admin — prescribe + exit 0, never mutate ──────────
  s5=$(s613_state "$S613_HOST" WRITE); printf '[]\n' > "$s5/rules_branches.json"
  o5=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s5" bash "$S613_SCRIPT" 2>&1); rc5=$?
  s5_mutate=$(grep -Ec '\[POST\]|\[PUT\]|\[PATCH\]|\[DELETE\]|\[-XPOST\]|\[-XPUT\]|\[-XPATCH\]|\[-XDELETE\]|\[--method\] \[(POST|PUT|PATCH|DELETE)\]' "$s5/calls" 2>/dev/null)
  if [ "$rc5" -eq 0 ] && [ "$s5_mutate" -eq 0 ] && printf '%s' "$o5" | grep -q 'gh api'; then
    ok "155-5: a no-admin SET prescribes (prints gh api commands) and exits 0 with no mutation — never a hard fail (#613)"
  else
    ng "155-5: no-admin SET must exit 0, mutate nothing, and prescribe (rc=$rc5 mutate=$s5_mutate) (#613)"
  fi

  # ── §155-6: host-pin — every gh api call carries --hostname <repo-host> ───────
  s6=$(s613_state "$S613_HOST" ADMIN); printf '%s' "$s613_rules_full" > "$s6/rules_branches.json"
  ( cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s6" bash "$S613_SCRIPT" --check ) >/dev/null 2>&1
  s6_api=$(grep -c -F ' [api]' "$s6/calls" 2>/dev/null)
  s6_pin=$(grep -F ' [api]' "$s6/calls" 2>/dev/null | grep -Ec '\[--hostname\] \[github\.example\.com\]|\[--hostname=github\.example\.com\]')
  if [ "$s6_api" -ge 1 ] && [ "$s6_api" -eq "$s6_pin" ]; then
    ok "155-6: every gh api call host-pins --hostname github.example.com (api=$s6_api pinned=$s6_pin) (#613)"
  else
    ng "155-6: an unpinned gh api call would mis-target github.com (api=$s6_api pinned=$s6_pin) (#613)"
  fi

  # ── §155-6b: degenerate host fails closed — NO default-host api call ──────────
  s6b=$(s613_state "" ADMIN); printf '%s' "$s613_rules_full" > "$s6b/rules_branches.json"
  ( cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s6b" bash "$S613_SCRIPT" --check ) >/dev/null 2>&1
  s6b_api=$(grep -c -F ' [api]' "$s6b/calls" 2>/dev/null)
  if [ "$s6b_api" -eq 0 ]; then
    ok "155-6b: an empty/degenerate repo host fails closed — no gh api call to the default host (#613)"
  else
    ng "155-6b: degenerate host still issued $s6b_api gh api call(s) — would mis-target github.com (#613)"
  fi

  # ── §155-7 (static): repo-scoped — never git config --global/--system ─────────
  if ! grep -Eq 'git[[:space:]]+config[^#]*(--global|--system)' "$S613_SCRIPT"; then
    ok "155-7: the script never touches user-global git config (no --global/--system) — §3.4 boundary (#613)"
  else
    ng "155-7: the script invokes git config --global/--system — user-global boundary violation (#613)"
  fi

  # ── §155-8 (static): SSOT single-source of the five-facet spec ────────────────
  # The desired five-facet definition must be defined ONCE (a single function whose
  # name carries 'facet') and consumed by ≥2 call sites (a SET path + the verifier),
  # so SET and verify can never drift (§9). Phase C: name the single-source function
  # to match /facet/ (e.g. `facet_spec`); a second copy makes this RED.
  s8_def=$(grep -Ec '^[[:space:]]*[A-Za-z0-9_]*facet[A-Za-z0-9_]*[[:space:]]*\(\)' "$S613_SCRIPT")
  s8_all=$(grep -Eco '[A-Za-z0-9_]*facet[A-Za-z0-9_]*' "$S613_SCRIPT")
  if [ "$s8_def" -eq 1 ] && [ "$s8_all" -ge 3 ]; then
    ok "155-8: the five-facet spec is single-sourced (1 facet-fn def, consumed ≥2×) — SET/verify can't drift (#613)"
  else
    ng "155-8: facet spec not single-sourced (defs=$s8_def, refs=$s8_all; want 1 def + ≥2 uses) (#613)"
  fi

  # ── §155-9: SET failure honesty — a failed mutation must NOT report success ────
  # rulesets API + admin, but the mutating PATCH exits non-zero (set_fail). An honest
  # SET must NOT print a success line and must SURFACE the failure (non-zero exit or a
  # failure/error message), never claim success on an ignored non-zero exit status.
  s9=$(s613_state "$S613_HOST" ADMIN); : > "$s9/set_fail"
  printf '[{"id":111,"name":"ghjig-tier3"}]\n' > "$s9/rulesets_list.json"
  o9=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s9" bash "$S613_SCRIPT" 2>&1); rc9=$?
  s9_success=$(printf '%s' "$o9" | grep -Eic 'updated ruleset|created ruleset|zero-clobber|classic floor-merge PUT')
  s9_surfaced=0
  { [ "$rc9" -ne 0 ] || printf '%s' "$o9" | grep -qiE 'fail|error|could not|unable'; } && s9_surfaced=1
  if [ "$s9_success" -eq 0 ] && [ "$s9_surfaced" -eq 1 ]; then
    ok "155-9: a failed mutation is surfaced (rc=$rc9 / message), never falsely reported as success (#613)"
  else
    ng "155-9: SET reported success on a failed mutation (success-lines=$s9_success surfaced=$s9_surfaced rc=$rc9) — dishonest (#613)"
  fi

  # ── §155-10: path-2 gated on 404 ONLY — a non-404 list error must NOT down-convert ──
  # rulesets LIST fails with a NON-404 (500) error + admin. The escalation ladder must
  # fail closed on a transient/5xx list error — it must NOT silently treat it as
  # "rulesets unsupported" and fall through to a DESTRUCTIVE classic protection PUT.
  s10=$(s613_state "$S613_HOST" ADMIN); : > "$s10/rulesets_500"
  ( cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s10" bash "$S613_SCRIPT" ) >/dev/null 2>&1
  s10_classicput=$(grep -F 'branches/main/protection' "$s10/calls" 2>/dev/null | grep -Ec '\[PUT\]|\[-XPUT\]|\[--method\] \[PUT\]')
  if [ "$s10_classicput" -eq 0 ]; then
    ok "155-10: a non-404 (5xx) rulesets-list error does NOT down-convert to a destructive classic PUT (fail-closed) (#613)"
  else
    ng "155-10: a 5xx list error fell through to $s10_classicput classic PUT(s) — path-2 must be gated on 404 ONLY (#613)"
  fi

  # ── §155-11: verify non-404 error → unreadable, never absent (fail-closed honest) ──
  # Both verify GETs fail with a NON-404, NON-403 (500) error. --check must classify
  # 'unreadable' (we could not read state), NEVER 'absent' (which would falsely assert
  # the repo is unprotected on a transient/5xx error).
  s11=$(s613_state "$S613_HOST" ADMIN); : > "$s11/rules_500"; : > "$s11/classic_500"
  o11=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s11" bash "$S613_SCRIPT" --check 2>&1)
  if printf '%s' "$o11" | grep -qw unreadable && ! printf '%s' "$o11" | grep -qw absent; then
    ok "155-11: a non-404/non-403 (5xx) verify error is 'unreadable', never 'absent' (#613)"
  else
    ng "155-11: a 5xx verify error misclassified (got: $(printf '%s' "$o11" | tr '\n' ' ')) — must be 'unreadable', not 'absent' (#613)"
  fi

  # ── §155-12: path-2 current-protection GET is fail-closed on a non-404 error ──
  # rulesets 404 (→ path 2) + admin, but the classic current-protection GET the
  # floor-merge depends on fails with a NON-404 (500). Treating that as {} would
  # floor-merge against a false-empty and PUT a destructive full-replace, silently
  # stripping any existing protection. The current-read must fail closed (no PUT)
  # exactly like the path-1 list gate and run_verify — only a genuine 404 → {}.
  s12=$(s613_state "$S613_HOST" ADMIN); : > "$s12/rulesets_404"; : > "$s12/classic_500"
  ( cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s12" bash "$S613_SCRIPT" ) >/dev/null 2>&1
  s12_classicput=$(grep -F 'branches/main/protection' "$s12/calls" 2>/dev/null | grep -Ec '\[PUT\]|\[-XPUT\]|\[--method\] \[PUT\]')
  if [ "$s12_classicput" -eq 0 ]; then
    ok "155-12: a non-404 (5xx) current-protection GET on path 2 does NOT PUT a destructive full-replace (fail-closed) (#613)"
  else
    ng "155-12: a 5xx current-GET fell through to $s12_classicput classic PUT(s) — the current-read must be gated on 404 ONLY (#613)"
  fi

  # ── §155-13: --prescribe does not mislabel the classic full-replace as floor-merge ──
  # The prescribed classic command is STATIC text built from build_classic_payload '{}'
  # (the bare desired floor) — it cannot read current, so pasting it verbatim on a
  # stronger repo is a destructive downgrade. It must NOT be labeled "floor-merge" and
  # MUST warn it is a full replacement that does not preserve existing protection.
  s13=$(s613_state "$S613_HOST" ADMIN)
  o13=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s13" bash "$S613_SCRIPT" --prescribe 2>&1)
  if printf '%s' "$o13" | grep -qi 'full replacement' && ! printf '%s' "$o13" | grep -qi 'floor-merge'; then
    ok "155-13: --prescribe warns the classic PUT is a full replacement and drops the misleading 'floor-merge' label (#613)"
  else
    ng "155-13: --prescribe must warn 'full replacement' and not label the classic command 'floor-merge' (out: $(printf '%s' "$o13" | tr '\n' ' ')) (#613)"
  fi

  # ── §155-14 (#622): 404 discrimination is structured, not a bare substring — path 1 ──
  # A NON-404 (5xx) rulesets-list error whose message merely CONTAINS the substring
  # "404" (a trace id) must NOT be mistaken for a genuine "rulesets unsupported" 404 →
  # it must fail closed (no classic PUT), like any other non-404 error (§155-10).
  s14=$(s613_state "$S613_HOST" ADMIN); : > "$s14/rulesets_500"; : > "$s14/e500_404"
  ( cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s14" bash "$S613_SCRIPT" ) >/dev/null 2>&1
  s14_classicput=$(grep -F 'branches/main/protection' "$s14/calls" 2>/dev/null | grep -Ec '\[PUT\]|\[-XPUT\]|\[--method\] \[PUT\]')
  if [ "$s14_classicput" -eq 0 ]; then
    ok "155-14: a non-404 list error containing the substring '404' does NOT down-convert to a classic PUT (structured 404 match) (#622)"
  else
    ng "155-14: a 5xx-with-'404'-substring list error fell through to $s14_classicput classic PUT(s) — the 404 gate must match the HTTP status, not a bare substring (#622)"
  fi

  # ── §155-15 (#622): 404 discrimination is structured, not a bare substring — verify ──
  # Both verify GETs fail with a NON-404 (5xx) error whose message CONTAINS "404".
  # --check must classify 'unreadable' (could-not-read), NEVER 'absent' (which a bare
  # substring match would wrongly produce by treating the 5xx as a readable-absent 404).
  s15=$(s613_state "$S613_HOST" ADMIN); : > "$s15/rules_500"; : > "$s15/classic_500"; : > "$s15/e500_404"
  o15=$(cd "$S613_CWD" && PATH="$S613_BIN:$PATH" GH_SHIM_STATE="$s15" bash "$S613_SCRIPT" --check 2>&1)
  if printf '%s' "$o15" | grep -qw unreadable && ! printf '%s' "$o15" | grep -qw absent; then
    ok "155-15: a non-404 verify error containing the substring '404' is 'unreadable', never 'absent' (structured 404 match) (#622)"
  else
    ng "155-15: a 5xx-with-'404'-substring verify error misclassified (got: $(printf '%s' "$o15" | tr '\n' ' ')) — must be 'unreadable' (#622)"
  fi

else
  ng "155-1a: scripts/install_branch_protection.sh absent/non-executable — verify 'configured' untested (#613)"
  ng "155-1b: install_branch_protection.sh absent — verify 'partial' untested (#613)"
  ng "155-1c: install_branch_protection.sh absent — verify 'absent' untested (#613)"
  ng "155-1d: install_branch_protection.sh absent — verify 'unreadable' fail-closed untested (#613)"
  ng "155-2: install_branch_protection.sh absent — non-admin readable verify untested (#613)"
  ng "155-3: install_branch_protection.sh absent — zero-clobber by-id SET untested (#613)"
  ng "155-4: install_branch_protection.sh absent — GHES-404 classic floor-merge PUT untested (#613)"
  ng "155-4b: install_branch_protection.sh absent — classic floor-merge preservation untested (#613)"
  ng "155-5: install_branch_protection.sh absent — no-admin degrade-not-fail untested (#613)"
  ng "155-6: install_branch_protection.sh absent — host-pin untested (#613)"
  ng "155-6b: install_branch_protection.sh absent — degenerate-host fail-closed untested (#613)"
  ng "155-7: install_branch_protection.sh absent — no-user-global boundary untested (#613)"
  ng "155-8: install_branch_protection.sh absent — SSOT single-source facet spec untested (#613)"
  ng "155-9: install_branch_protection.sh absent — SET failure honesty untested (#613)"
  ng "155-10: install_branch_protection.sh absent — non-404 list error fail-closed untested (#613)"
  ng "155-11: install_branch_protection.sh absent — non-404 verify → unreadable untested (#613)"
  ng "155-12: install_branch_protection.sh absent — path-2 current-GET fail-closed untested (#613)"
  ng "155-13: install_branch_protection.sh absent — prescribe full-replace mislabel untested (#613)"
  ng "155-14: install_branch_protection.sh absent — structured-404 path-1 gate untested (#622)"
  ng "155-15: install_branch_protection.sh absent — structured-404 verify untested (#622)"
fi

rm -rf "$S613_DIR"
