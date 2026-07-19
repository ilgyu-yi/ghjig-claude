#!/usr/bin/env bash
# scripts/install_branch_protection.sh — tier-3 server-side authority (SPEC §6.7).
# A capability-adaptive escalation ladder that asserts / classifies / prescribes
# branch protection on the default branch. It selects the strongest server-side
# primitive the actor's permission and the host's API support allow, and degrades
# to prescription rather than failing. Modes:
#
#   install_branch_protection.sh              SET where admin (via the ladder)
#   install_branch_protection.sh --check      classify current state; never mutate
#   install_branch_protection.sh --verify     alias of --check
#   install_branch_protection.sh --prescribe  print the exact gh api / UI commands
#
# Invariants (SPEC §6.7): repo-scoped `gh api` only (NEVER any user-global/system
# scope, §3.4 boundary); host-pinned to the repo host derived from
# `gh repo view --json url` — a host-less gh api mis-targets github.com on a GHES
# repo (#610/#614), a degenerate host FAILS CLOSED; idempotent (ruleset updated by
# id, classic PUT re-asserts the union); and the desired five-facet spec is
# single-sourced in `facet_spec` and consumed by every SET path AND the verifier
# (§9), so SET and verify can never drift.
set -uo pipefail

# Self-locate for a best-effort audit_log (never fatal), mirroring install_git_hooks.sh.
_ibp_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ -f "$_ibp_root/.claude/hooks/hookrt.sh" ]; then
  export GHJIG_ROOT="$_ibp_root"
  # shellcheck source=/dev/null
  . "$_ibp_root/.claude/hooks/hookrt.sh"
else
  audit_log() { :; }
fi

RULESET_NAME="ghjig-tier3"

# ── SSOT: the desired five-facet spec (single source, §9) ─────────────────────
# One row per AC facet, pipe-separated:
#   name | verify-detect-in-rules(GET rules/branches) | verify-detect-in-classic
#        (GET branches/protection) | ruleset-rule-json fragment (empty ⇒ folded
#        into a sibling facet's rule, e.g. review-at-head lives on pull_request).
# Consumed by the verifier AND both SET builders, so classification and assertion
# are defined once and cannot drift.
facet_spec() {
  printf '%s\n' \
'pull_request|"type":[[:space:]]*"pull_request"|"required_pull_request_reviews"|{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_last_push_approval":true}}' \
'review_at_head|"require_last_push_approval":[[:space:]]*true|"require_last_push_approval":[[:space:]]*true|' \
'strict_checks|"strict_required_status_checks_policy":[[:space:]]*true|"strict":[[:space:]]*true|{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[]}}' \
'force_push|"type":[[:space:]]*"non_fast_forward"|"allow_force_pushes":\{"enabled":[[:space:]]*false\}|{"type":"non_fast_forward"}' \
'deletion|"type":[[:space:]]*"deletion"|"allow_deletions":\{"enabled":[[:space:]]*false\}|{"type":"deletion"}'
}

# ── SET builders (both consume facet_spec) ────────────────────────────────────
build_ruleset_payload() {  # a named per-repo ruleset targeting the renamed-safe default
  local rules="" frag
  while IFS='|' read -r _ _ _ frag; do
    [ -n "$frag" ] || continue
    if [ -z "$rules" ]; then rules="$frag"; else rules="$rules,$frag"; fi
  done <<EOF
$(facet_spec)
EOF
  printf '{"name":"%s","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[%s]}\n' \
    "$RULESET_NAME" "$rules"
}

build_classic_payload() {  # floor-merge union of desired-vs-current, per facet (never a destructive full-replace)
  local current="$1" desired_count
  # SSOT: the desired approving-review floor is read from facet_spec (single source,
  # §9) — the classic union and the ruleset payload cannot drift on the review count.
  desired_count=$(facet_spec \
    | sed -n 's/.*"required_approving_review_count":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$desired_count" ] || desired_count=1
  # `gh api …/protection` GET is object-shaped; guard against a non-JSON body.
  printf '%s' "$current" | jq empty >/dev/null 2>&1 || current='{}'
  # Floor-merge: for each facet emit the MORE-restrictive of current-vs-desired, and
  # PRESERVE any org-added stronger facet the current protection already carries. Never
  # emit contexts:[] / enforce_admins:null / restrictions:null over an existing value —
  # a classic PUT is a full-replacement, so a desired-only payload would silently
  # downgrade a stronger repo. desired = {contexts:[], enforce_admins: not-forced,
  # linear/conversation/lock/block: not-forced, force_push/deletion: disallowed}.
  printf '%s' "$current" | jq -c --argjson want "$desired_count" '
    def logins($a): [ ($a // [])[] | if type=="object" then (.login // .slug // .name // .) else . end ];
    . as $cur
    | {
        required_status_checks: {
          strict: true,
          contexts: (($cur.required_status_checks.contexts // []) | unique)   # current ∪ desired([])
        },
        enforce_admins: ($cur.enforce_admins.enabled // false),               # preserve current-true; never force
        required_pull_request_reviews: (
          {
            required_approving_review_count: ([($cur.required_pull_request_reviews.required_approving_review_count // 0), $want] | max),
            require_last_push_approval: (($cur.required_pull_request_reviews.require_last_push_approval // false) or true),
            require_code_owner_reviews: ($cur.required_pull_request_reviews.require_code_owner_reviews // false),
            dismiss_stale_reviews: ($cur.required_pull_request_reviews.dismiss_stale_reviews // false)
          }
          + (if $cur.required_pull_request_reviews.dismissal_restrictions
             then {dismissal_restrictions: {
                     users: logins($cur.required_pull_request_reviews.dismissal_restrictions.users),
                     teams: logins($cur.required_pull_request_reviews.dismissal_restrictions.teams)}}
             else {} end)
        ),
        restrictions: (if $cur.restrictions
                       then {users: logins($cur.restrictions.users),
                             teams: logins($cur.restrictions.teams),
                             apps:  logins($cur.restrictions.apps)}
                       else null end),                                        # preserve current; never null-over-existing
        allow_force_pushes: false,
        allow_deletions: false
      }
      + (if ($cur.required_linear_history.enabled // false)         then {required_linear_history: true}         else {} end)
      + (if ($cur.required_conversation_resolution.enabled // false) then {required_conversation_resolution: true} else {} end)
      + (if ($cur.lock_branch.enabled // false)                    then {lock_branch: true}                    else {} end)
      + (if ($cur.block_creations.enabled // false)                then {block_creations: true}                else {} end)
  '
}

# ── Verify (any actor; reads rules ∪ classic, classifies the five facets) ──────
# Emits per-facet present/missing lines plus ONE overall status word among
# configured / partial / absent / unreadable. Fail-closed honest: a 403 on both
# reads is 'unreadable', never silently promoted to 'configured'.
run_verify() {
  local rules_json="" rules_readable=1 classic_json="" classic_readable=1
  local out err
  out=$(mktemp); err=$(mktemp)

  # Readable-but-absent is allowed ONLY on a genuine 404. Any other read failure
  # (403 / 5xx / network) is 'unreadable' — never silently classified 'absent'.
  if gh api "repos/{owner}/{repo}/rules/branches/$DEFAULT_BRANCH" --hostname "$HOST" >"$out" 2>"$err"; then
    rules_json=$(cat "$out")
  elif grep -q 404 "$err"; then rules_json=""       # readable-but-absent
  else rules_readable=0; fi                          # 403/5xx/network → unreadable

  if gh api "repos/{owner}/{repo}/branches/$DEFAULT_BRANCH/protection" --hostname "$HOST" >"$out" 2>"$err"; then
    classic_json=$(cat "$out")
  elif grep -q 404 "$err"; then classic_json=""     # readable-but-absent
  else classic_readable=0; fi                        # 403/5xx/network → unreadable
  rm -f "$out" "$err"

  local name rdet cdet present=0 total=0 hit
  while IFS='|' read -r name rdet cdet _; do
    [ -n "$name" ] || continue
    total=$((total + 1)); hit=0
    if [ "$rules_readable" -eq 1 ] && [ -n "$rules_json" ] \
       && printf '%s' "$rules_json" | grep -Eq "$rdet"; then hit=1; fi
    if [ "$classic_readable" -eq 1 ] && [ -n "$classic_json" ] \
       && printf '%s' "$classic_json" | grep -Eq "$cdet"; then hit=1; fi
    if [ "$hit" -eq 1 ]; then
      present=$((present + 1)); printf 'facet %-16s present\n' "$name"
    elif [ "$rules_readable" -eq 0 ] && [ "$classic_readable" -eq 0 ]; then
      printf 'facet %-16s unreadable\n' "$name"
    else
      printf 'facet %-16s missing\n' "$name"
    fi
  done <<EOF
$(facet_spec)
EOF

  local overall
  if [ "$rules_readable" -eq 0 ] && [ "$classic_readable" -eq 0 ]; then
    overall=unreadable
  elif [ "$present" -eq "$total" ]; then overall=configured
  elif [ "$present" -gt 0 ]; then overall=partial
  else overall=absent; fi

  # Honesty fold-in: report the bypass surface; NEVER force enforce_admins:true.
  if [ "$classic_readable" -eq 1 ] && printf '%s' "$classic_json" | grep -q '"enforce_admins"'; then
    printf 'bypass enforce_admins reported (not-forced)\n'
  else
    printf 'bypass surface reported (not-forced)\n'
  fi
  printf 'branch-protection status: %s (%d/%d facets)\n' "$overall" "$present" "$total"
}

# ── Prescribe (print the exact commands to reach the desired state) ────────────
prescribe() {
  printf 'install_branch_protection: run these as an admin on %s to reach the desired state:\n' "$HOST"
  printf '  # rulesets API (preferred): create/update the %s ruleset by id\n' "$RULESET_NAME"
  printf '  gh api repos/{owner}/{repo}/rulesets --hostname %s --method POST --input - <<'"'"'JSON'"'"'\n' "$HOST"
  printf '  %s\n' "$(build_ruleset_payload)"
  printf '  JSON\n'
  printf '  # classic fallback (older GHES / no rulesets). PREFER the SET path\n'
  printf '  # (install_branch_protection.sh, no arg): it merges the desired floor into the\n'
  printf '  # current protection non-destructively. A raw PUT is a FULL REPLACEMENT — the\n'
  printf '  # payload below is the minimum desired floor ONLY and does NOT preserve stronger\n'
  printf '  # existing protection. If you must PUT by hand, GET the current protection first and merge.\n'
  printf '  gh api repos/{owner}/{repo}/branches/%s/protection --hostname %s --method PUT --input - <<'"'"'JSON'"'"'\n' "$DEFAULT_BRANCH" "$HOST"
  printf '  %s\n' "$(build_classic_payload '{}')"
  printf '  JSON\n'
}

# ── SET ladder (admin only; highest authority first, degrade-not-fail) ─────────
set_via_ladder() {
  local list our_id payload current err
  err=$(mktemp)
  # Path 1: rulesets API + admin → zero-clobber update of OUR ruleset, by id.
  if list=$(gh api "repos/{owner}/{repo}/rulesets" --hostname "$HOST" 2>"$err"); then
    rm -f "$err"
    # Resolve OUR ruleset's id from the list with jq (robust to nested _links, unlike a
    # brace-split), so we update strictly BY ID (zero-clobber; never a sibling ruleset).
    our_id=$(printf '%s' "$list" | jq -r '.[]? | select(.name=="'"$RULESET_NAME"'") | .id' 2>/dev/null | head -1)
    payload=$(build_ruleset_payload)
    if [ -n "$our_id" ] && [ "$our_id" != "null" ]; then
      # SET honesty: capture the mutation's exit status — never report success on a
      # failed (ignored non-zero) mutation.
      if printf '%s' "$payload" | gh api "repos/{owner}/{repo}/rulesets/$our_id" \
           --method PATCH --hostname "$HOST" --input - >/dev/null 2>&1; then
        printf 'install_branch_protection: updated ruleset %s (id %s) by id — zero-clobber.\n' "$RULESET_NAME" "$our_id"
        ( audit_log info tier3 ruleset-set "ruleset=$RULESET_NAME host=$HOST id=$our_id" ) >/dev/null 2>&1 || true
        return 0
      fi
      printf 'install_branch_protection: ruleset %s (id %s) SET failed — state unchanged.\n' "$RULESET_NAME" "$our_id" >&2
      ( audit_log warn tier3 ruleset-set-failed "ruleset=$RULESET_NAME host=$HOST id=$our_id" ) >/dev/null 2>&1 || true
      return 1
    fi
    if printf '%s' "$payload" | gh api "repos/{owner}/{repo}/rulesets" \
         --method POST --hostname "$HOST" --input - >/dev/null 2>&1; then
      printf 'install_branch_protection: created ruleset %s.\n' "$RULESET_NAME"
      ( audit_log info tier3 ruleset-set "ruleset=$RULESET_NAME host=$HOST created=1" ) >/dev/null 2>&1 || true
      return 0
    fi
    printf 'install_branch_protection: ruleset %s creation failed — state unchanged.\n' "$RULESET_NAME" >&2
    ( audit_log warn tier3 ruleset-set-failed "ruleset=$RULESET_NAME host=$HOST created=0" ) >/dev/null 2>&1 || true
    return 1
  fi

  # Path 1 failed. Fall to the classic path ONLY on a genuine 404 (rulesets
  # unsupported / older GHES). Any OTHER error (403/5xx/network) FAILS CLOSED — never a
  # silent down-convert to a destructive classic full-replace on a transient error.
  if ! grep -q '404' "$err"; then
    printf 'install_branch_protection: rulesets list failed (non-404) on %s — refusing to down-convert to a classic PUT (fail-closed):\n' "$HOST" >&2
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"

  # Path 2: rulesets unsupported (genuine 404) + admin → classic floor-merge PUT.
  # The current-protection GET the floor-merge depends on is itself fail-closed —
  # the SAME discipline as the path-1 list gate above and run_verify: a genuine 404
  # means "no protection yet" (safe to create from '{}'); any OTHER read error
  # (403/5xx/network) leaves the current state UNKNOWN, so refuse the PUT rather
  # than floor-merge against a false-empty and silently strip existing protection.
  err=$(mktemp)
  if current=$(gh api "repos/{owner}/{repo}/branches/$DEFAULT_BRANCH/protection" \
       --hostname "$HOST" 2>"$err"); then
    rm -f "$err"
  elif grep -q '404' "$err"; then
    current='{}'; rm -f "$err"
  else
    printf 'install_branch_protection: current protection on %s unreadable (non-404) — refusing classic PUT (fail-closed):\n' "$DEFAULT_BRANCH" >&2
    cat "$err" >&2; rm -f "$err"
    ( audit_log warn tier3 classic-current-unreadable "branch=$DEFAULT_BRANCH host=$HOST" ) >/dev/null 2>&1 || true
    return 1
  fi
  payload=$(build_classic_payload "$current")
  if printf '%s' "$payload" | gh api "repos/{owner}/{repo}/branches/$DEFAULT_BRANCH/protection" \
       --method PUT --hostname "$HOST" --input - >/dev/null 2>&1; then
    printf 'install_branch_protection: classic floor-merge PUT on %s (union, never a full-replace).\n' "$DEFAULT_BRANCH"
    ( audit_log info tier3 classic-set "branch=$DEFAULT_BRANCH host=$HOST" ) >/dev/null 2>&1 || true
    return 0
  fi
  printf 'install_branch_protection: classic protection PUT failed on %s — state unchanged.\n' "$DEFAULT_BRANCH" >&2
  ( audit_log warn tier3 classic-set-failed "branch=$DEFAULT_BRANCH host=$HOST" ) >/dev/null 2>&1 || true
  return 1
}

# ── Arg parse ─────────────────────────────────────────────────────────────────
MODE="set"
case "${1:-}" in
  --check|--verify) MODE="verify" ;;
  --prescribe)      MODE="prescribe" ;;
  "")               MODE="set" ;;
  *) echo "install_branch_protection: unknown arg: $1 (use --check/--verify or --prescribe)" >&2; exit 2 ;;
esac

# ── Host-pin (fail closed on a degenerate host; #610/#614 idiom) ──────────────
# Derive the repo host from gh's normalized url, then pin every gh api call with
# --hostname. A host-less gh api resolves gh's DEFAULT host (github.com) and would
# mis-target a GHES repo — so an empty/degenerate host fails CLOSED (never a
# default-host call). Mirrors scripts/lib/onboard_checks.sh:88-105.
REPO_URL=$(gh repo view --json url --jq .url 2>/dev/null)
HOST=${REPO_URL#*://}; HOST=${HOST#*@}; HOST=${HOST%%/*}
case "$HOST" in
  ''|*[!A-Za-z0-9.:-]*)
    echo "install_branch_protection: could not resolve repo host from url (${REPO_URL}) — authenticate gh to that host; refusing a default-host call (fail-closed)." >&2
    exit 1 ;;
esac

DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
PERM=$(gh repo view --json viewerPermission --jq .viewerPermission 2>/dev/null)

case "$MODE" in
  verify)    run_verify; exit 0 ;;
  prescribe) prescribe;  exit 0 ;;
  set)
    if [ "$PERM" = "ADMIN" ]; then
      set_via_ladder
      exit $?
    fi
    # No admin → verify + prescribe, exit 0, never a hard failure, never mutate.
    echo "install_branch_protection: not an admin (viewerPermission=${PERM:-unknown}) — verify + prescribe only, no mutation."
    run_verify
    prescribe
    exit 0
    ;;
esac
