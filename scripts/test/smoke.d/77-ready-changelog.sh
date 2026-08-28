# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after 76-evidence-gates.sh (#742). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §189: gh pr ready changelog-evidence gate (#742, Directive #692) ----------
# Contract home: SPEC §6.1, the `changelog-evidence` matcher row (#742 Doc phase).
#   * `gh pr ready` blocks unless one of two doors holds, LABEL FIRST:
#     (1) the `skip-changelog` label on the PR (§18.7 / CI's own short-circuit),
#     (2) the PR diff genuinely ADDS a fragment
#         `changelog_unreleased/(added|changed|deprecated|removed|fixed|security)/<N>.md`
#         with stem <N> in the allow-set = PR number ∪ closingIssuesReferences —
#         the same set check-changelog.yml (§18.6) computes.
#   * Added-in-diff predicate is HARDENED: a path counts only when it appears in
#     BOTH `^diff --git a/[^ ]* b/<path>$` AND `^\+\+\+ b/<path>$` of one
#     fetched `gh pr diff --patch` output — a file-content line starting
#     `++ b/…` renders as a column-0 `+++ b/…` patch line, so the `+++` grep
#     alone is content-forgeable; the header capture is anchored space-free on
#     the a-path (a legitimate fragment path never contains a space), which
#     rejects both a content-rendered `+++` twin without a matching header and
#     a space-bearing-filename header pairing (§189-f4/f5) — CI (§18.6) stays
#     the backstop for whatever the presence check admits.
#   * PR resolution: explicit integer/URL selector via extract_pr_from_ready_cmd;
#     bare via `gh pr view --json number`. `gh pr ready --undo` is UNGATED —
#     mark_allow'ed before any lookup or skip-token consumption — with `--undo`
#     counted only as an argv token of the ready invocation itself (the
#     refine's token walk stops at a shell command separator, §189-n5/n6).
#   * Fail CLOSED on every lookup failure — gh error/timeout, malformed JSON, a
#     `gh pr diff` transport failure (kept separate from the grep's no-match,
#     the #553 E3 split), a safe_source helper miss — with a THREE-WAY message
#     split: evidence-absence names /changelog (§5.23); stem-outside-allow-set
#     names rename-the-stem-or-fix-Closes (mirroring CI's error text);
#     lookup-failure carries merge-review's re-run remedy. Escape category =
#     `changelog-evidence` (§7).
#
# Authored red-at-head in the #742 Test phase (the arms precede the matcher, per
# Doc → Test → Code); every ok/ng line below states the SHIPPED contract — an
# invariant of the delivered gate, never the authoring-time state.
#
# Harness: §188's recording PATH-shim idiom — the `gh` shim RECORDS every argv
# line to $CE_CALLS and serves `pr view` from the per-arm JSON fixture
# $CE_PRV_FIXTURE (honoring -q/--jq via jq, so both `--json … --jq …` and raw
# JSON consumers resolve) and `pr diff` from the raw-patch fixture
# $CE_DIFF_FIXTURE. Failure knobs isolate one lookup each: CE_PRV_FAIL (every
# pr view exits nonzero), CE_PRV_BARE_FAIL (only the selector-less pr view
# fails — proves explicit-selector resolution never falls back to the bare
# form), CE_PRV_EXPECT (a selector'd pr view serves ONLY when the selector's
# trailing integer matches — proves WHICH PR was resolved), CE_DIFF_FAIL (pr
# diff transport failure). Escape-arm audit assertions read
# `$GHJIG_STATE_DIR_OVERRIDE/audit/audit.jsonl` (the #725 override-routed
# per-project sink).

CE_DIR="$TMP/s189"
CE_BIN="$CE_DIR/bin"
CE_TARGET="$CE_DIR/target"
CE_FX="$CE_DIR/fixtures"
CE_STATE="$CE_DIR/state"
CE_CALLS="$CE_DIR/calls.log"
CE_ERR="$CE_DIR/err.txt"
mkdir -p "$CE_BIN" "$CE_TARGET" "$CE_FX" "$CE_STATE"
CE_TARGET=$(cd "$CE_TARGET" && pwd -P)
(cd "$CE_TARGET" && git init -q) || true
# Register the target so cwd_guard accepts it (the §41/§44/§188 pattern); each
# arm rides its own GHJIG_STATE_DIR_OVERRIDE, so every per-arm state dir gets
# its own seeded registry (an unseeded registry makes the hook INERT).
ce_seed_state() { mkdir -p "$1"; printf '%s\n' "$CE_TARGET" > "$1/registry.txt"; }
ce_seed_state "$CE_STATE"

# ── The recording gh shim ─────────────────────────────────────────────────────
cat > "$CE_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CE_CALLS:-/dev/null}"
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
  *" pr diff "*)
    if [ "${CE_DIFF_FAIL:-}" = 1 ]; then
      echo "HTTP 502: transport failure (smoke §189 forced pr-diff failure)" >&2
      exit 1
    fi
    if [ -n "${CE_DIFF_FIXTURE:-}" ] && [ -f "$CE_DIFF_FIXTURE" ]; then
      cat "$CE_DIFF_FIXTURE"
      exit 0
    fi
    echo "smoke §189: no pr-diff fixture armed for: $*" >&2
    exit 1
    ;;
  *" pr view "*)
    if [ "${CE_PRV_FAIL:-}" = 1 ]; then
      echo "GraphQL: Could not resolve to a PullRequest (smoke §189 forced pr-view failure)" >&2
      exit 1
    fi
    # Positional selector after `view` (skip flags and their values).
    sel="" seen=0 skipnext=0
    for a in "$@"; do
      if [ "$seen" = 0 ]; then [ "$a" = view ] && seen=1; continue; fi
      if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
      case "$a" in
        --json|--jq|-q|--repo|-R|-t|--template) skipnext=1 ;;
        -*) ;;
        *) sel="$a"; break ;;
      esac
    done
    if [ -z "$sel" ]; then
      if [ "${CE_PRV_BARE_FAIL:-}" = 1 ]; then
        echo "no pull requests found for the current branch (smoke §189 forced bare-view failure)" >&2
        exit 1
      fi
    elif [ -n "${CE_PRV_EXPECT:-}" ]; then
      seln=$(printf '%s' "$sel" | grep -oE '[0-9]+$')
      if [ "$seln" != "$CE_PRV_EXPECT" ]; then
        echo "GraphQL: Could not resolve to a PullRequest with the number of '$sel' (smoke §189: expected selector $CE_PRV_EXPECT)" >&2
        exit 1
      fi
    fi
    if [ -n "${CE_PRV_FIXTURE:-}" ] && [ -f "$CE_PRV_FIXTURE" ]; then
      emit "$(cat "$CE_PRV_FIXTURE")" "$@"
      exit 0
    fi
    echo "smoke §189: no pr-view fixture armed for: $*" >&2
    exit 1
    ;;
esac
exit 0
MOCK
chmod +x "$CE_BIN/gh"

# ── PR-view fixtures ──────────────────────────────────────────────────────────
# PR 500, closingIssuesReferences [400] → allow-set {500, 400}; 999 is outside.
# One superset JSON serves both the bare number-resolution call and any
# labels/closingIssuesReferences lookup (a real `--json a,b` response is a
# field-subset of this; every jq path an implementation asks for resolves).
cat > "$CE_FX/prv_noskip.json" <<'JSON'
{"number":500,"closingIssuesReferences":[{"number":400}],"labels":[{"name":"enhancement"}]}
JSON

cat > "$CE_FX/prv_skip.json" <<'JSON'
{"number":500,"closingIssuesReferences":[{"number":400}],"labels":[{"name":"enhancement"},{"name":"skip-changelog"}]}
JSON

# Malformed JSON (truncated) with gh exit 0 — must read as LOOKUP failure.
cat > "$CE_FX/prv_malformed.json" <<'JSON'
{"number":500,"closingIssuesReferences":[
JSON

# ── PR-diff fixtures (raw `gh pr diff --patch` output) ────────────────────────
# Genuine add of changelog_unreleased/added/400.md (400 ∈ allow-set): the path
# appears in BOTH the `diff --git` header and the `+++ b/` line, plus an
# unrelated second-file hunk so the grep is not the whole document.
cat > "$CE_FX/diff_frag400.patch" <<'PATCH'
diff --git a/changelog_unreleased/added/400.md b/changelog_unreleased/added/400.md
new file mode 100644
index 0000000..53d8a24
--- /dev/null
+++ b/changelog_unreleased/added/400.md
@@ -0,0 +1 @@
+- Gate `gh pr ready` on changelog-fragment evidence (#400)
diff --git a/scripts/foo.sh b/scripts/foo.sh
index 2b8c15c..9ae7f01 100644
--- a/scripts/foo.sh
+++ b/scripts/foo.sh
@@ -1,2 +1,3 @@
 #!/usr/bin/env bash
+echo gate
 exit 0
PATCH

# No fragment anywhere in the diff.
cat > "$CE_FX/diff_nofrag.patch" <<'PATCH'
diff --git a/scripts/foo.sh b/scripts/foo.sh
index 2b8c15c..9ae7f01 100644
--- a/scripts/foo.sh
+++ b/scripts/foo.sh
@@ -1,2 +1,3 @@
 #!/usr/bin/env bash
+echo gate
 exit 0
PATCH

# Genuine add of changelog_unreleased/added/999.md — 999 ∉ {500,400}.
cat > "$CE_FX/diff_frag999.patch" <<'PATCH'
diff --git a/changelog_unreleased/added/999.md b/changelog_unreleased/added/999.md
new file mode 100644
index 0000000..53d8a24
--- /dev/null
+++ b/changelog_unreleased/added/999.md
@@ -0,0 +1 @@
+- Gate `gh pr ready` on changelog-fragment evidence (#999)
PATCH

# FORGED `+++` line (the hardened-predicate target): the ONLY occurrence of
# changelog_unreleased is a hunk CONTENT line — a file whose content line reads
# `++ b/changelog_unreleased/added/500.md` renders with the added-line `+`
# prefix as a column-0 `+++ b/changelog_unreleased/added/500.md` patch line.
# No `diff --git … changelog_unreleased …` header exists, so the intersection
# predicate must reject what a `+++`-only grep (CI's) would accept.
cat > "$CE_FX/diff_forged.patch" <<'PATCH'
diff --git a/notes/evil.txt b/notes/evil.txt
new file mode 100644
index 0000000..4d5fcb1
--- /dev/null
+++ b/notes/evil.txt
@@ -0,0 +1,2 @@
+harmless first line
+++ b/changelog_unreleased/added/500.md
PATCH

# FORGED space-bearing header pairing (#743 round-1 F3): a real diff of a dir
# literally named `x b` yields the header
# `diff --git a/x b/changelog_unreleased/added/500.md b/x b/…` — a greedy
# `a/.* b/` capture reads `changelog_unreleased/added/500.md` out of it — and
# an unrelated second file's content line renders as the column-0
# `+++ b/changelog_unreleased/added/500.md` twin. A legitimate fragment path
# never contains a space, so the space-free header anchor must reject the pair.
cat > "$CE_FX/diff_forged_hdr.patch" <<'PATCH'
diff --git a/x b/changelog_unreleased/added/500.md b/x b/changelog_unreleased/added/500.md
new file mode 100644
index 0000000..53d8a24
--- /dev/null
+++ b/x b/changelog_unreleased/added/500.md
@@ -0,0 +1 @@
+payload in the space-bearing-named file
diff --git a/notes/e.txt b/notes/e.txt
new file mode 100644
index 0000000..4d5fcb1
--- /dev/null
+++ b/notes/e.txt
@@ -0,0 +1,2 @@
+harmless first line
+++ b/changelog_unreleased/added/500.md
PATCH

# ── Runner ────────────────────────────────────────────────────────────────────
# ce_run <cmd> [state-dir] [root] — fire pre_tool_use.sh with the shim on PATH.
# Per-arm knobs ride the environment: CE_PRV_FIXTURE, CE_PRV_FAIL,
# CE_PRV_BARE_FAIL, CE_PRV_EXPECT, CE_DIFF_FIXTURE, CE_DIFF_FAIL. [root]
# defaults to the live shell root; the helper-miss arm passes a stripped copy
# through the GHJIG_ROOT_OVERRIDE seam (SPEC §3.2.1).
ce_run() {
  local cmd="$1" state="${2:-$CE_STATE}" root="${3:-$SHELL_ROOT}"
  local stdin_json
  stdin_json=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  (
    cd "$CE_TARGET" || exit 0
    PATH="$CE_BIN:$PATH" \
    GHJIG_ROOT_OVERRIDE="$root" \
    GHJIG_STATE_DIR_OVERRIDE="$state" \
    CE_CALLS="$CE_CALLS" \
    CE_PRV_FIXTURE="${CE_PRV_FIXTURE:-}" \
    CE_PRV_FAIL="${CE_PRV_FAIL:-}" \
    CE_PRV_BARE_FAIL="${CE_PRV_BARE_FAIL:-}" \
    CE_PRV_EXPECT="${CE_PRV_EXPECT:-}" \
    CE_DIFF_FIXTURE="${CE_DIFF_FIXTURE:-}" \
    CE_DIFF_FAIL="${CE_DIFF_FAIL:-}" \
      bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" <<< "$stdin_json"
  )
  return $?
}

CE_READY_CMD='gh pr ready'

# ── Fragment door ─────────────────────────────────────────────────────────────

# §189-f1: fragment evidence present — the diff genuinely adds
# changelog_unreleased/added/400.md (header + `+++ b/` both) and 400 is in the
# allow-set {500,400} → `gh pr ready` allowed.
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_frag400.patch" \
  ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 0 ]; then
  ok "§189-f1: genuinely-added allow-set fragment (closing-issue stem 400) → ready allowed (#742)"
else
  ng "§189-f1: expected allow(0) with an allow-set fragment in the diff; got rc=$rc — $(head -1 "$CE_ERR") (#742)"
fi

# §189-f2: no fragment in the diff, no skip label → block with the
# EVIDENCE-ABSENCE face: names /changelog (§5.23) and the category.
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_nofrag.patch" \
  ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'changelog-evidence' "$CE_ERR" && grep -qE '/changelog([^_]|$)' "$CE_ERR"; then
  ok "§189-f2: no fragment + no label → evidence-absence block naming /changelog (#742)"
else
  ng "§189-f2: expected block(2) + 'changelog-evidence' + '/changelog' on a fragment-less diff; got rc=$rc (#742)"
fi

# §189-f3: a fragment IS genuinely added but its stem 999 is outside the
# allow-set {500,400} → block with the STEM face — rename-the-stem-or-fix-Closes
# (mirroring CI's error text), DISTINCT from the evidence-absence face: no
# `/changelog` command remedy (the fragment exists; authoring another is not
# the fix — the `/changelog` grep tolerates only the path form
# `changelog_unreleased/`, which legitimately names the offending file).
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_frag999.patch" \
  ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qi 'rename' "$CE_ERR" && grep -qi 'closes' "$CE_ERR" \
   && ! grep -qE '/changelog([^_]|$)' "$CE_ERR"; then
  ok "§189-f3: fragment stem outside the allow-set → rename-or-fix-Closes block, distinct from the /changelog face (#742)"
else
  ng "§189-f3: expected block(2) + rename/Closes remedy (and no /changelog remedy) on stem 999 outside {500,400}; got rc=$rc (#742)"
fi

# §189-f4: forged `+++` — the only changelog_unreleased occurrence is a hunk
# CONTENT line rendering as a column-0 `+++ b/changelog_unreleased/added/500.md`
# with NO `diff --git` header for that path → the hardened both-greps predicate
# rejects it → evidence-absence block (a `+++`-only grep would wrongly allow).
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_forged.patch" \
  ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'changelog-evidence' "$CE_ERR" && grep -qE '/changelog([^_]|$)' "$CE_ERR"; then
  ok "§189-f4: content-forged '+++ b/' line without a diff-header twin → evidence-absence block (hardened predicate) (#742)"
else
  ng "§189-f4: expected block(2) + '/changelog' on the forged-+++ diff (content line, no diff --git header); got rc=$rc (#742)"
fi

# §189-f5: forged pairing via a SPACE-BEARING filename (#743 round-1 F3): the
# diff_forged_hdr fixture pairs the space-bearing `diff --git` header (whose
# greedy `a/.* b/` capture would yield `changelog_unreleased/added/500.md`,
# stem 500 ∈ allow-set {500,400}) with the cross-file content-rendered column-0
# `+++ b/changelog_unreleased/added/500.md` twin — no fragment named 500.md is
# actually added. The space-free-anchored header capture must reject it →
# evidence-absence block (the greedy capture would have wrongly allowed).
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_forged_hdr.patch" \
  ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'changelog-evidence' "$CE_ERR" && grep -qE '/changelog([^_]|$)' "$CE_ERR"; then
  ok "§189-f5: space-bearing forged header + cross-file '+++' twin → rejected, evidence-absence block (#742)"
else
  ng "§189-f5: expected block(2) + '/changelog' on the space-bearing-header forgery; got rc=$rc (#742)"
fi

# ── Label door ────────────────────────────────────────────────────────────────

# §189-l1: skip-changelog label on the PR → allowed, and label-first
# short-circuit: the recording shim shows ZERO `pr diff` invocations (the
# fragment lookup is never paid when the label door holds; no diff fixture is
# armed, so a stray diff call would fail the transport branch loudly anyway).
: > "$CE_CALLS"
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_skip.json" \
  ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 0 ] && ! grep -q 'pr diff' "$CE_CALLS"; then
  ok "§189-l1: skip-changelog label → ready allowed with zero pr-diff lookups (label door first) (#742)"
else
  ng "§189-l1: expected allow(0) + no 'pr diff' in the shim call log with the skip label; got rc=$rc (#742)"
fi

# ── §7 escape ─────────────────────────────────────────────────────────────────

# §189-e1: the file-token escape — mint via scripts/ghjig_skip.sh under the
# arm's own state dir, then the SAME no-evidence command (pr view down, proving
# the skip and not an allow path) passes AND the escape lands in the
# override-routed per-project audit file (#725).
CE_ESC="$CE_DIR/esc-state"
ce_seed_state "$CE_ESC"
GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" GHJIG_STATE_DIR_OVERRIDE="$CE_ESC" \
  "$SHELL_ROOT/scripts/ghjig_skip.sh" changelog-evidence "pr ready" "smoke §189 sanctioned ready" >/dev/null 2>&1
rc=0
CE_PRV_FAIL=1 ce_run "$CE_READY_CMD" "$CE_ESC" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 0 ] \
   && grep -q '"event":"escape".*"category":"changelog-evidence".*"decision":"skip"' "$CE_ESC/audit/audit.jsonl" 2>/dev/null; then
  ok "§189-e1: ghjig_skip token allows the no-evidence ready AND leaves an escape audit record (#742)"
else
  ng "§189-e1: expected allow(0) + escape/skip audit record for changelog-evidence; got rc=$rc (#742)"
fi

# ── Fail-closed lookups ───────────────────────────────────────────────────────

# §189-x1: `gh pr view` exits nonzero → fail-closed block with the
# LOOKUP-FAILURE face — carries the re-run remedy and NOT the evidence-absence
# /changelog remedy (the three faces are distinct, SPEC §6.1).
rc=0
CE_PRV_FAIL=1 ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qi 're-run' "$CE_ERR" && ! grep -qE '/changelog([^_]|$)' "$CE_ERR"; then
  ok "§189-x1: pr-view failure → fail-closed lookup-failure block (re-run remedy, not /changelog) (#742)"
else
  ng "§189-x1: expected block(2) + 're-run' (and no '/changelog') on a failing pr view; got rc=$rc (#742)"
fi

# §189-x2: `gh pr view` exits 0 with MALFORMED JSON → same lookup-failure
# block, NOT a silent allow and NOT evidence-absence.
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_malformed.json" ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qi 're-run' "$CE_ERR" && ! grep -qE '/changelog([^_]|$)' "$CE_ERR"; then
  ok "§189-x2: malformed pr-view JSON → fail-closed lookup-failure block (#742)"
else
  ng "§189-x2: expected block(2) + 're-run' (and no '/changelog') on malformed JSON; got rc=$rc (#742)"
fi

# §189-x3: pr view resolves but `gh pr diff` fails (transport) → LOOKUP-FAILURE
# face, not the no-fragment face — the #553 E3 split check-changelog.yml itself
# carries: a transport failure must never read as "no fragment added".
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FAIL=1 \
  ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -qi 're-run' "$CE_ERR" && ! grep -qE '/changelog([^_]|$)' "$CE_ERR"; then
  ok "§189-x3: pr-diff transport failure → lookup-failure block, kept separate from no-fragment (#553 E3 split) (#742)"
else
  ng "§189-x3: expected block(2) + 're-run' (and no '/changelog') on a pr-diff transport failure; got rc=$rc (#742)"
fi

# §189-x4: helper miss — a shell-root copy WITHOUT ac_closeout_gate.sh (the
# §6.1 helper table hosts the #742 gate functions there), reached through the
# GHJIG_ROOT_OVERRIDE seam → the changelog-evidence arm fails CLOSED on the
# safe_source miss (the deliberate merge-review-mirroring exception to the
# fail-open helper posture).
CE_MISS_ROOT="$CE_DIR/miss-root"
mkdir -p "$CE_MISS_ROOT/.claude"
cp -R "$SHELL_ROOT/.claude/hooks" "$CE_MISS_ROOT/.claude/hooks"
rm -f "$CE_MISS_ROOT/.claude/hooks/helpers/ac_closeout_gate.sh"
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_frag400.patch" \
  ce_run "$CE_READY_CMD" "$CE_STATE" "$CE_MISS_ROOT" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'changelog-evidence' "$CE_ERR"; then
  ok "§189-x4: gate helper missing → changelog-evidence fails CLOSED (block), not silently open (#742)"
else
  ng "§189-x4: expected block(2) + 'changelog-evidence' with ac_closeout_gate.sh absent; got rc=$rc (#742)"
fi

# ── Anchor / resolution ───────────────────────────────────────────────────────

# §189-n1: leading global-flag run (`gh --repo o/r pr ready`) still matches
# (#499 entry-anchor tolerance, `pr ready` pair adjacent) → the no-evidence
# fixture blocks it exactly like the bare form.
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_nofrag.patch" \
  ce_run 'gh --repo o/r pr ready' >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 2 ] && grep -q 'changelog-evidence' "$CE_ERR"; then
  ok "§189-n1: 'gh --repo o/r pr ready' matches through the leading global-flag run → gated (#742)"
else
  ng "§189-n1: expected block(2) on the global-flag form without evidence (#499 anchor tolerance); got rc=$rc (#742)"
fi

# §189-n2: explicit selector `gh pr ready 500` resolves PR 500 WITHOUT the bare
# current-branch lookup: the shim FAILS any selector-less pr view
# (CE_PRV_BARE_FAIL) and serves only selector 500 (CE_PRV_EXPECT) — so the
# allow proves both the resolved number and that the explicit form never falls
# back to bare resolution (a wrong PR or a bare fallback would fail closed).
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_frag400.patch" \
CE_PRV_BARE_FAIL=1 CE_PRV_EXPECT=500 \
  ce_run 'gh pr ready 500' >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 0 ]; then
  ok "§189-n2: explicit 'gh pr ready 500' resolves PR 500 (selector-only, no bare-view fallback) → evidence allows (#742)"
else
  ng "§189-n2: expected allow(0) with selector-500-only fixtures (bare view forced down); got rc=$rc — $(head -1 "$CE_ERR") (#742)"
fi

# §189-n3: bare `gh pr ready` resolves the current-branch PR via the shimmed
# `gh pr view --json number` (→ 500); any selector'd follow-up lookup is pinned
# to 500 (CE_PRV_EXPECT) → the allow-set fragment admits it.
rc=0
CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_frag400.patch" \
CE_PRV_EXPECT=500 \
  ce_run "$CE_READY_CMD" >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 0 ]; then
  ok "§189-n3: bare 'gh pr ready' resolves via pr view --json number → 500 → evidence allows (#742)"
else
  ng "§189-n3: expected allow(0) on bare-form resolution to PR 500; got rc=$rc — $(head -1 "$CE_ERR") (#742)"
fi

# §189-n4: `gh pr ready --undo` is UNGATED (draft-ward is the safe direction):
# allowed with ZERO gh lookups — both lookup knobs are forced down, so any
# attempted pr view/pr diff would fail-closed-block, and the call log stays
# empty of both (mark_allow precedes any lookup or skip-token consumption).
: > "$CE_CALLS"
rc=0
CE_PRV_FAIL=1 CE_DIFF_FAIL=1 ce_run 'gh pr ready --undo' >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 0 ] && ! grep -qE 'pr (view|diff)' "$CE_CALLS"; then
  ok "§189-n4: 'gh pr ready --undo' is ungated — allowed with zero pr view/diff lookups (#742)"
else
  ng "§189-n4: expected allow(0) + no pr view/diff in the shim call log on --undo; got rc=$rc (#742)"
fi

# §189-n5: separator-smuggled `--undo` stays GATED (#743 round-1 F2): in
# `gh pr ready ; : --undo`, `gh pr ready # --undo`, and
# `gh pr ready && echo --undo`, the `--undo` belongs to a DIFFERENT command —
# the refine's argv-token walk terminates at the shell command separator, so
# each form is gated and, with a fragment-less diff armed, blocks with the
# evidence-absence face (a whole-string `--undo` match would execute a bare
# ready ungated, with no audit trail).
n5_bad=""
for n5_cmd in 'gh pr ready ; : --undo' 'gh pr ready # --undo' 'gh pr ready && echo --undo'; do
  rc=0
  CE_PRV_FIXTURE="$CE_FX/prv_noskip.json" CE_DIFF_FIXTURE="$CE_FX/diff_nofrag.patch" \
    ce_run "$n5_cmd" >/dev/null 2>"$CE_ERR" || rc=$?
  { [ "$rc" = 2 ] && grep -q 'changelog-evidence' "$CE_ERR"; } || n5_bad="$n5_bad[$n5_cmd → rc=$rc] "
done
if [ -z "$n5_bad" ]; then
  ok "§189-n5: separator-smuggled --undo (';', '#', '&&') stays gated — blocked without evidence (#742)"
else
  ng "§189-n5: expected block(2) + 'changelog-evidence' on every separator-smuggled --undo form; failed: $n5_bad(#742)"
fi

# §189-n6: genuine `gh pr ready 123 --undo` (selector form) stays UNGATED with
# zero lookups — `--undo` here IS an argv token of the ready invocation, so
# the refine allows before any pr view/diff call (both lookup knobs are forced
# down, and the call log must stay empty of both).
: > "$CE_CALLS"
rc=0
CE_PRV_FAIL=1 CE_DIFF_FAIL=1 ce_run 'gh pr ready 123 --undo' >/dev/null 2>"$CE_ERR" || rc=$?
if [ "$rc" = 0 ] && ! grep -qE 'pr (view|diff)' "$CE_CALLS"; then
  ok "§189-n6: 'gh pr ready 123 --undo' is ungated — allowed with zero pr view/diff lookups (#742)"
else
  ng "§189-n6: expected allow(0) + no pr view/diff lookups on the selector --undo form; got rc=$rc (#742)"
fi
