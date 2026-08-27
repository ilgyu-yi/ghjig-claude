# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after 75-audit-unify.sh (#738). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §188: dir-mode lifecycle evidence gates — activation-evidence / completion-evidence (#738, Directive #692) ----------
# Contract home: SPEC §6.1, the two matcher rows landed by the #738 Doc phase.
#   * `gh issue edit <N> --remove-label status:proposed` without FRESH activation
#     evidence blocks: a trusted-author (OWNER/MEMBER/COLLABORATOR) comment whose
#     FIRST LINE is `<!-- activation-verdict: pass -->`, fresh per
#     `pass.createdAt >= max(issue.lastEditedAt // issue.createdAt,
#     lastLabelEvent.createdAt)` — one `gh api graphql` round-trip.
#   * `gh issue close <N> --reason completed` on a `directive`-labelled Issue
#     without a trusted comment whose first line matches
#     `^## Directive Completion \(resolved by ` blocks (existence-only, no
#     freshness); non-`directive` closes are allowed at the label branch.
#   * BOTH fail CLOSED on any lookup failure — gh error/timeout, malformed JSON,
#     a GraphQL HTTP-200-with-`errors` response — and split the block message:
#     evidence-absence names the producing command (`/activate <N>` /
#     `/complete-directive <N>`); lookup-failure carries merge-review's re-run
#     remedy. Escape categories = the matcher names (§7).
#
# Phase C (the matchers) DOES NOT EXIST YET, so every block-side arm below is
# RED at head (the hook allows) and goes GREEN when the matchers land; the
# allow-side arms are vacuously green at head and become predicate-fidelity
# locks post-Code.
#
# Harness: §44's PATH-shim idiom, extended — the `gh` shim RECORDS every argv
# line to $EG_CALLS and serves `gh api graphql` (matched on the adjacent token
# pair `api graphql` in the joined argv) from the per-arm fixture file
# $GH_GQL_FIXTURE; GH_GQL_FAIL=1 fails ONLY the graphql branch (issue/repo view
# stay up, so the sibling fail-open matchers keep resolving and the arm isolates
# the evidence gate's own fail-closed posture). Escape-arm audit assertions read
# `$GHJIG_STATE_DIR_OVERRIDE/audit/audit.jsonl` (the #725 override-routed
# per-project sink; AUDIT_LOG_PATH is a dead seam).

EG_DIR="$TMP/s188"
EG_BIN="$EG_DIR/bin"
EG_TARGET="$EG_DIR/target"
EG_FX="$EG_DIR/fixtures"
EG_STATE="$EG_DIR/state"
EG_CALLS="$EG_DIR/calls.log"
EG_ERR="$EG_DIR/err.txt"
mkdir -p "$EG_BIN" "$EG_TARGET" "$EG_FX" "$EG_STATE"
EG_TARGET=$(cd "$EG_TARGET" && pwd -P)
(cd "$EG_TARGET" && git init -q) || true
# Register the target so cwd_guard accepts it (the §41/§44 pattern). The hook
# resolves the registry at $(ghjig_state_dir)/registry.txt, and each arm rides
# its own GHJIG_STATE_DIR_OVERRIDE — so every per-arm state dir gets its own
# seeded registry (an unseeded registry makes the hook INERT: in_scope fails →
# exit 0 before any matcher, a vacuous allow).
eg_seed_state() { mkdir -p "$1"; printf '%s\n' "$EG_TARGET" > "$1/registry.txt"; }
eg_seed_state "$EG_STATE"

# ── The recording gh shim ─────────────────────────────────────────────────────
# Serves: `repo view` (smoke-owner/smoke-repo), `issue view <n> --json labels`
# (labels via GH_MOCK_LABELS_<n>), `api graphql` (fixture / forced failure),
# and generic `gh api repos/...` (author_association=NONE, so the pre-existing
# trusted-filer Stage-2 lookup in the not-planned arm resolves to untrusted →
# allow, keeping that arm's verdict the evidence gate's own).
cat > "$EG_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${EG_CALLS:-/dev/null}"
emit() {
  local full="$1"; shift
  local expr="" next=0
  for a in "$@"; do
    if [ "$next" = 1 ]; then expr="$a"; next=0; continue; fi
    { [ "$a" = "-q" ] || [ "$a" = "--jq" ]; } && next=1
  done
  if [ -n "$expr" ] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$full" | jq -r "$expr" 2>/dev/null
  else
    printf '%s' "$full"
  fi
}
case " $* " in
  *" api graphql "*)
    if [ "${GH_GQL_FAIL:-}" = 1 ]; then
      echo "GraphQL: something went wrong (smoke §188 forced failure)" >&2
      exit 1
    fi
    if [ -n "${GH_GQL_FIXTURE:-}" ] && [ -f "$GH_GQL_FIXTURE" ]; then
      cat "$GH_GQL_FIXTURE"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  repo)
    if [ "${2:-}" = view ]; then
      emit '{"owner":{"login":"smoke-owner"},"name":"smoke-repo"}' "$@"
    fi
    ;;
  issue)
    if [ "${2:-}" = view ]; then
      issue="$3"
      var="GH_MOCK_LABELS_${issue}"
      labels="${!var:-}"
      arr="["; first=1; old_ifs="$IFS"; IFS=,
      for l in $labels; do
        [ -z "$l" ] && continue
        [ "$first" = 1 ] && first=0 || arr="$arr,"
        arr="$arr{\"name\":\"$l\"}"
      done
      IFS="$old_ifs"; arr="$arr]"
      emit "{\"labels\":$arr}" "$@"
    fi
    ;;
  api)
    # REST fallback surface (is_trusted_filer): always an untrusted author.
    emit '{"author_association":"NONE"}' "$@"
    ;;
esac
exit 0
MOCK
chmod +x "$EG_BIN/gh"

# ── GraphQL fixtures ──────────────────────────────────────────────────────────
# Timeline: createdAt 09:00 < lastEditedAt 10:00 < lastLabelEvent 10:05 <
# pass 10:10 < unrelated 10:30. Freshness pivot = max(10:00, 10:05) = 10:05.

# Activation: no pass verdict at all. Includes a trusted FIRST-LINE `revise`
# marker — a qualifying-looking non-pass verdict must not satisfy the gate.
cat > "$EG_FX/act_absent.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":2,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"<!-- activation-verdict: revise -->\nFindings: tighten the AC."},{"createdAt":"2026-08-27T10:12:00Z","authorAssociation":"MEMBER","body":"Looks fine otherwise."}]}}}}}
JSON

# Activation: trusted first-line pass marker, strictly newer than both the last
# body edit and the last label event → allow.
cat > "$EG_FX/act_fresh.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"<!-- activation-verdict: pass -->\nActivation review: pass."}]}}}}}
JSON

# Activation: pass.createdAt EQUAL to lastLabelEvent.createdAt — the SPEC
# predicate is `>=`, so equality allows (a same-second comment-then-flip flow
# must not read as stale).
cat > "$EG_FX/act_equal.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:05:00Z","authorAssociation":"OWNER","body":"<!-- activation-verdict: pass -->\nActivation review: pass."}]}}}}}
JSON

# Activation: pass comment OLDER than the last (Un)labeledEvent → stale → block.
cat > "$EG_FX/act_stale_label.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:20:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"<!-- activation-verdict: pass -->\nActivation review: pass."}]}}}}}
JSON

# Activation: fresh pass PLUS a NEWER unrelated comment, no newer body/label
# event → allow (predicate fidelity: the disqualified updatedAt proxy would
# have read this as stale).
cat > "$EG_FX/act_postpass.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":2,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"<!-- activation-verdict: pass -->\nActivation review: pass."},{"createdAt":"2026-08-27T10:30:00Z","authorAssociation":"NONE","body":"Unrelated drive-by note after the verdict."}]}}}}}
JSON

# Activation: marker present but NOT the first line (the #737 quoted-marker
# defect class) → block.
cat > "$EG_FX/act_interior.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"Quoting the reviewer marker below:\n<!-- activation-verdict: pass -->"}]}}}}}
JSON

# Activation: first-line marker, fresh, but authorAssociation NONE (outside the
# OWNER/MEMBER/COLLABORATOR trust set) → block.
cat > "$EG_FX/act_untrusted.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"NONE","body":"<!-- activation-verdict: pass -->\nSelf-issued pass."}]}}}}}
JSON

# GraphQL HTTP-200-with-errors: the partial-failure shape gh exits 0 on when
# not asked to fail — MUST be treated as a lookup failure (fail closed).
cat > "$EG_FX/gql_errors.json" <<'JSON'
{"data":{"repository":{"issue":null}},"errors":[{"message":"Something went wrong while executing your query."}]}
JSON

# Completion: no completion comment on the directive Issue.
cat > "$EG_FX/comp_absent.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"Progress note: two of three children merged."}]}}}}}
JSON

# Completion: trusted comment whose FIRST LINE matches the §5.13 closing head.
cat > "$EG_FX/comp_present.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"## Directive Completion (resolved by PR #9)\nAll acceptance criteria delivered."}]}}}}}
JSON

# Completion: closing head present but NOT the first line → block.
cat > "$EG_FX/comp_interior.json" <<'JSON'
{"data":{"repository":{"issue":{"lastEditedAt":"2026-08-27T10:00:00Z","createdAt":"2026-08-27T09:00:00Z","timelineItems":{"nodes":[{"createdAt":"2026-08-27T10:05:00Z"}]},"comments":{"totalCount":1,"nodes":[{"createdAt":"2026-08-27T10:10:00Z","authorAssociation":"OWNER","body":"Draft of the closing comment:\n## Directive Completion (resolved by PR #9)"}]}}}}}
JSON

# ── Runner ────────────────────────────────────────────────────────────────────
# eg_run <cmd> [state-dir] — fire pre_tool_use.sh with the shim on PATH.
# Per-arm knobs ride the environment: GH_GQL_FIXTURE, GH_GQL_FAIL.
# Issue label fixtures: #43 = proposed Directive (activation target),
# #44 = active Directive (completion target), #45 = Execution Issue (task).
eg_run() {
  local cmd="$1" state="${2:-$EG_STATE}"
  local stdin_json
  stdin_json=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  (
    cd "$EG_TARGET" || exit 0
    PATH="$EG_BIN:$PATH" \
    GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
    GHJIG_STATE_DIR_OVERRIDE="$state" \
    EG_CALLS="$EG_CALLS" \
    GH_MOCK_LABELS_43="directive,status:proposed" \
    GH_MOCK_LABELS_44="directive" \
    GH_MOCK_LABELS_45="task" \
    GH_GQL_FIXTURE="${GH_GQL_FIXTURE:-}" \
    GH_GQL_FAIL="${GH_GQL_FAIL:-}" \
      bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" <<< "$stdin_json"
  )
  return $?
}

EG_ACT_CMD='gh issue edit 43 --remove-label status:proposed'
EG_COMP_CMD='gh issue close 44 --reason completed'

# ── Activation gate ───────────────────────────────────────────────────────────

# §188-a1: no qualifying pass comment (a trusted first-line `revise` marker and
# an unrelated comment only) → block, naming the evidence-absence remedy
# `/activate 43` and the category.
rc=0
GH_GQL_FIXTURE="$EG_FX/act_absent.json" eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'activation-evidence' "$EG_ERR" && grep -qF '/activate 43' "$EG_ERR"; then
  ok "§188-a1: activation-evidence blocks the Proposed→Active flip without a pass comment, naming /activate 43 (#738)"
else
  ng "§188-a1: expected block(2) + '/activate 43' + 'activation-evidence' on evidence-absent flip; got rc=$rc (#738)"
fi

# §188-a1b: the gated label as a comma-list element (`--remove-label
# P2,status:proposed`) is the same flip — same block (SPEC §6.1: both separator
# forms and comma-list tokenization, same as the declassify arm).
rc=0
GH_GQL_FIXTURE="$EG_FX/act_absent.json" eg_run 'gh issue edit 43 --remove-label P2,status:proposed' >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'activation-evidence' "$EG_ERR"; then
  ok "§188-a1b: activation-evidence catches status:proposed as a comma-list element (#738)"
else
  ng "§188-a1b: expected block(2) on '--remove-label P2,status:proposed' without evidence; got rc=$rc (#738)"
fi

# §188-a2: trusted first-line pass marker STRICTLY newer than the last body
# edit and the last label event → allow.
rc=0
GH_GQL_FIXTURE="$EG_FX/act_fresh.json" eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ]; then
  ok "§188-a2: fresh trusted pass comment → flip allowed (#738)"
else
  ng "§188-a2: expected allow(0) on fresh pass evidence; got rc=$rc — $(head -1 "$EG_ERR") (#738)"
fi

# §188-a2b: pass.createdAt EQUAL to lastLabelEvent.createdAt → allow (the SPEC
# predicate is `>=`; a strict `>` would read a same-second comment-then-flip
# flow as stale).
rc=0
GH_GQL_FIXTURE="$EG_FX/act_equal.json" eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ]; then
  ok "§188-a2b: pass timestamp == last label event → allowed (>= boundary) (#738)"
else
  ng "§188-a2b: expected allow(0) at the >= equality boundary; got rc=$rc (#738)"
fi

# §188-a3: pass comment OLDER than the last label event → stale → block, and
# the message names the staleness class.
rc=0
GH_GQL_FIXTURE="$EG_FX/act_stale_label.json" eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qiE 'stale|fresh' "$EG_ERR"; then
  ok "§188-a3: pass comment older than the last label event → stale → block (#738)"
else
  ng "§188-a3: expected block(2) naming staleness on a post-pass label event; got rc=$rc (#738)"
fi

# §188-a4: fresh pass + a NEWER unrelated comment (no newer body/label event)
# → allow. Predicate fidelity: the rejected updatedAt proxy reads this as stale.
rc=0
GH_GQL_FIXTURE="$EG_FX/act_postpass.json" eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ]; then
  ok "§188-a4: a post-pass unrelated comment does not stale the evidence (#738)"
else
  ng "§188-a4: expected allow(0) with a newer unrelated comment; got rc=$rc — updatedAt-proxy regression (#738)"
fi

# §188-a5: marker present only as an INTERIOR line of the trusted comment (the
# #737 quoted-marker class) → block.
rc=0
GH_GQL_FIXTURE="$EG_FX/act_interior.json" eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'activation-evidence' "$EG_ERR"; then
  ok "§188-a5: interior-line marker does not satisfy the line-1 anchor → block (#738)"
else
  ng "§188-a5: expected block(2) on an interior-line marker (#737 class); got rc=$rc (#738)"
fi

# §188-a6: first-line marker from an UNTRUSTED author (NONE) → block.
rc=0
GH_GQL_FIXTURE="$EG_FX/act_untrusted.json" eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'activation-evidence' "$EG_ERR"; then
  ok "§188-a6: untrusted-author pass marker does not satisfy the gate → block (#738)"
else
  ng "§188-a6: expected block(2) on a NONE-association pass marker; got rc=$rc (#738)"
fi

# §188-a7: gh graphql fails (non-zero exit) → fail CLOSED with the
# LOOKUP-FAILURE message: carries the re-run remedy and does NOT carry the
# evidence-absence remedy (the two messages are distinct, SPEC §6.1).
rc=0
GH_GQL_FAIL=1 eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qi 're-run' "$EG_ERR" && ! grep -qF '/activate 43' "$EG_ERR"; then
  ok "§188-a7: graphql lookup failure → fail-closed block with the re-run remedy, not the /activate remedy (#738)"
else
  ng "§188-a7: expected block(2) + 're-run' (and no '/activate 43') on gh failure; got rc=$rc (#738)"
fi

# §188-a7b: GraphQL HTTP-200-with-errors (gh exit 0, `errors` populated, issue
# null) → same lookup-failure block, NOT a silent allow and NOT evidence-absence.
rc=0
GH_GQL_FIXTURE="$EG_FX/gql_errors.json" eg_run "$EG_ACT_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qi 're-run' "$EG_ERR"; then
  ok "§188-a7b: 200-with-errors GraphQL response → fail-closed lookup-failure block (#738)"
else
  ng "§188-a7b: expected block(2) + 're-run' on a 200-with-errors response; got rc=$rc (#738)"
fi

# §188-a8: the §7 file-token escape — mint via scripts/ghjig_skip.sh under the
# arm's own state dir, then the SAME flip (with graphql down, proving the skip
# and not the allow path) passes AND the escape lands in the override-routed
# per-project audit file (#725; AUDIT_LOG_PATH is a dead seam).
EG_ESC_A="$EG_DIR/esc-act-state"
eg_seed_state "$EG_ESC_A"
GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" GHJIG_STATE_DIR_OVERRIDE="$EG_ESC_A" \
  "$SHELL_ROOT/scripts/ghjig_skip.sh" activation-evidence "status:proposed" "smoke §188 sanctioned flip" >/dev/null 2>&1
rc=0
GH_GQL_FAIL=1 eg_run "$EG_ACT_CMD" "$EG_ESC_A" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ] \
   && grep -q '"category":"activation-evidence"' "$EG_ESC_A/audit/audit.jsonl" 2>/dev/null \
   && grep -q '"event":"escape".*"category":"activation-evidence".*"decision":"skip"' "$EG_ESC_A/audit/audit.jsonl" 2>/dev/null; then
  ok "§188-a8: ghjig_skip token allows the flip AND leaves an escape audit record (#738)"
else
  ng "§188-a8: expected allow(0) + escape/skip audit record for activation-evidence; got rc=$rc (#738)"
fi

# §188-a9: an UNRELATED label edit (`--remove-label P2`) is out of the matcher's
# scope — allowed, with ZERO `gh api graphql` calls (one-call-per-gated-fire:
# ungated edits must not pay the lookup). Fresh state dir forces the sibling
# matchers' issue-type lookups through the shim, so a non-empty call log proves
# the shim served this arm (anti-vacuity) while the graphql grep stays empty.
EG_A9_STATE="$EG_DIR/a9-state"
eg_seed_state "$EG_A9_STATE"
: > "$EG_CALLS"
rc=0
eg_run 'gh issue edit 43 --remove-label P2' "$EG_A9_STATE" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ] && [ -s "$EG_CALLS" ] && ! grep -q 'api graphql' "$EG_CALLS"; then
  ok "§188-a9: unrelated label edit allowed with zero graphql calls (#738)"
else
  ng "§188-a9: expected allow(0) + no 'api graphql' in the shim call log (log non-empty); got rc=$rc (#738)"
fi

# ── Completion gate ───────────────────────────────────────────────────────────

# §188-c1: `--reason completed` close on a `directive` Issue with NO completion
# comment → block, naming `/complete-directive 44` and the category.
rc=0
GH_GQL_FIXTURE="$EG_FX/comp_absent.json" eg_run "$EG_COMP_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'completion-evidence' "$EG_ERR" && grep -qF '/complete-directive 44' "$EG_ERR"; then
  ok "§188-c1: completion-evidence blocks a directive close without the closing comment, naming /complete-directive 44 (#738)"
else
  ng "§188-c1: expected block(2) + '/complete-directive 44' + 'completion-evidence'; got rc=$rc (#738)"
fi

# §188-c2: trusted first-line `## Directive Completion (resolved by …` comment
# exists → allow (existence-only, no freshness predicate).
rc=0
GH_GQL_FIXTURE="$EG_FX/comp_present.json" eg_run "$EG_COMP_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ]; then
  ok "§188-c2: directive close with the §5.13 closing comment → allowed (#738)"
else
  ng "§188-c2: expected allow(0) with completion evidence present; got rc=$rc — $(head -1 "$EG_ERR") (#738)"
fi

# §188-c3: a NON-directive Issue (#45: task) closes as completed WITHOUT
# evidence — allowed at the label branch. graphql is down, so an allow here
# proves the label branch short-circuits before any evidence lookup.
rc=0
GH_GQL_FAIL=1 eg_run 'gh issue close 45 --reason completed' >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ]; then
  ok "§188-c3: non-directive close needs no completion evidence (label branch) (#738)"
else
  ng "§188-c3: expected allow(0) on an Execution-issue close; got rc=$rc (#738)"
fi

# §188-c4: `--reason "not planned"` on the directive Issue — the
# completion-evidence matcher stays SILENT (it gates only `--reason completed`;
# the shim's NONE author association keeps the pre-existing trusted-filer arm
# on its allow path, so the verdict isolates this matcher).
rc=0
GH_GQL_FAIL=1 eg_run 'gh issue close 44 --reason "not planned"' >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ] && ! grep -q 'completion-evidence' "$EG_ERR"; then
  ok "§188-c4: not-planned close is outside the completion-evidence matcher (silent) (#738)"
else
  ng "§188-c4: expected allow(0) with no completion-evidence message on not-planned; got rc=$rc (#738)"
fi

# §188-c5: graphql fails on the gated close → fail-closed LOOKUP-FAILURE block
# (re-run remedy, not the /complete-directive evidence-absence remedy).
rc=0
GH_GQL_FAIL=1 eg_run "$EG_COMP_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qi 're-run' "$EG_ERR" && ! grep -qF '/complete-directive 44' "$EG_ERR"; then
  ok "§188-c5: completion lookup failure → fail-closed block with the re-run remedy (#738)"
else
  ng "§188-c5: expected block(2) + 're-run' (and no '/complete-directive 44') on gh failure; got rc=$rc (#738)"
fi

# §188-c5b: 200-with-errors on the gated close → same lookup-failure block.
rc=0
GH_GQL_FIXTURE="$EG_FX/gql_errors.json" eg_run "$EG_COMP_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qi 're-run' "$EG_ERR"; then
  ok "§188-c5b: 200-with-errors on the completion lookup → fail-closed block (#738)"
else
  ng "§188-c5b: expected block(2) + 're-run' on a 200-with-errors response; got rc=$rc (#738)"
fi

# §188-c6: the §7 escape for completion-evidence — token minted, gated close
# (graphql down) allowed, escape record in the arm's per-project audit file.
EG_ESC_C="$EG_DIR/esc-comp-state"
eg_seed_state "$EG_ESC_C"
GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" GHJIG_STATE_DIR_OVERRIDE="$EG_ESC_C" \
  "$SHELL_ROOT/scripts/ghjig_skip.sh" completion-evidence "--reason completed" "smoke §188 sanctioned close" >/dev/null 2>&1
rc=0
GH_GQL_FAIL=1 eg_run "$EG_COMP_CMD" "$EG_ESC_C" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 0 ] \
   && grep -q '"event":"escape".*"category":"completion-evidence".*"decision":"skip"' "$EG_ESC_C/audit/audit.jsonl" 2>/dev/null; then
  ok "§188-c6: ghjig_skip token allows the close AND leaves an escape audit record (#738)"
else
  ng "§188-c6: expected allow(0) + escape/skip audit record for completion-evidence; got rc=$rc (#738)"
fi

# §188-c7: closing head present only as an INTERIOR line → block (line-1
# anchor, same #737 class as the activation arm).
rc=0
GH_GQL_FIXTURE="$EG_FX/comp_interior.json" eg_run "$EG_COMP_CMD" >/dev/null 2>"$EG_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'completion-evidence' "$EG_ERR"; then
  ok "§188-c7: interior-line closing head does not satisfy the completion gate → block (#738)"
else
  ng "§188-c7: expected block(2) on an interior-line closing head; got rc=$rc (#738)"
fi
