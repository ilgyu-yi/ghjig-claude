---
description: Classify code-vs-SPEC drift candidates and reconcile them — propose a SPEC update only after explicit user approval; never edit SPEC to match possibly-buggy code (SPEC §5.27, Directive #455).
argument-hint: [<path>]
---

Reconcile code-vs-SPEC drift. The detector `scripts/spec_drift_candidates.sh` (§6.5(d), #462) is the *perception* half — it surfaces **code-ahead drift candidates** (a commit that touched a SPEC-referenced repo path without co-touching `SPEC.md`). `/reconcile-spec` is the *judgment + action* half: it reads the relevant SPEC section(s) and the drifted commits/code, classifies each candidate, and takes the per-disposition action — **never silently rewriting SPEC to match possibly-buggy code** (the load-bearing invariant of Directive #455).

An optional `<path>` argument scopes reconciliation to a single drift candidate; with no argument, all surfaced candidates are processed.

## Procedure

0. **Resolve mode** via `resolve_mode` (`.claude/ghjig-root/.claude/hooks/helpers/ship_mode.sh`) — `attended` (default) or `unattended`. This governs whether a SPEC edit may be applied (see Operating mode).

1. **Run the detector** from the target repo's cwd:
   ```bash
   GR="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/ghjig-root"
   [ -e "$GR/.claude" ] || { echo "GHJig: not inside a registered project (cd to the project root, or run scripts/register.sh)"; exit 1; }
   "$GR/scripts/spec_drift_candidates.sh"
   ```
   Parse its `  <path> | drift-commits=N` cluster lines. The `  (no spec-drift candidates)` sentinel → nothing to do; report and stop. If `<path>` was given, keep only that candidate.

2. **Classify each candidate — into exactly one of three dispositions, BEFORE any SPEC edit.** For each candidate path, read the SPEC section(s) that reference it and the drifting commits (`git log -p -- <path>` since the divergence) and decide which one disposition holds:
   - **`spec-ahead`** — SPEC describes intended/in-progress behaviour the code has not implemented yet. SPEC leads. → **track, no edit.**
   - **`code-ahead-correct`** — the code is right and SPEC is stale (the code legitimately moved and the behaviour SPEC describes is now wrong/out of date). → **propose a SPEC update to match the code**, applied only after explicit user approval (step 3).
   - **`code-wrong`** — the divergence is a code **bug**: SPEC is right and the code drifted away from it. → **never edit SPEC.** Route to a code fix (or file a bug); SPEC is the correct contract and must stand.

   State the chosen disposition and the evidence for it per candidate before proceeding. When uncertain between `code-ahead-correct` and `code-wrong`, default to **NOT** editing SPEC (treat as `code-wrong` / surface for a human) — enshrining a bug as the contract is the expensive, irreversible error this command exists to prevent.

3. **Act per disposition** (the user-approval gate lives here):
   - `spec-ahead` → record the classification; **no SPEC edit**. Audit `audit_log info spec-reconcile tracked "path=<path> disposition=spec-ahead"`.
   - `code-ahead-correct` → present the **proposed SPEC edit** (the exact diff) and the rationale, and **pause for explicit user approval**. Only on an explicit approval: apply the edit, regenerate the SPEC ToC in the same change if line counts shift (`scripts/build_toc.sh`), and audit `audit_log info spec-reconcile applied "path=<path> disposition=code-ahead-correct"`. On reject/no-approval: do not edit; record and move on.
   - `code-wrong` → **never edit SPEC.** Route to a code fix or file a bug describing the drift, and audit `audit_log info spec-reconcile routed "path=<path> disposition=code-wrong"`.

## Operating mode

- **attended** (default): surface each classification + (for `code-ahead-correct`) the proposed SPEC edit, and **pause for explicit user approval** before applying it. The user may approve, reject, or re-classify.
- **unattended**: **never auto-apply** a SPEC correction. A SPEC-to-match-code edit is a content/direction change, and the directing layer never autonomously sets direction (SPEC §1.7) — so a `code-ahead-correct` candidate is **surfaced and parked**, not self-approved. Audit `audit_log info spec-reconcile parked "path=<path> disposition=code-ahead-correct reason=unattended-no-auto-apply"`. `spec-ahead` (track) and `code-wrong` (route) are non-mutating and proceed in both modes.

Classification *correctness* is agent judgment (it reads SPEC + code and decides), the same shape as `/onboard`'s SSOT-drafting half — it is not a mechanically-verified property. The structural guarantees (the three dispositions, the approval gate, the never-edit-on-`code-wrong` invariant, the unattended no-auto-apply rule) are the contract; the judgment quality is the operator's to review.

## Escape

`SKIP_HOOKS=<cat> SKIP_REASON='<why>' /reconcile-spec` per SPEC §7. Audit-logged.

## Forbidden

- Editing `SPEC.md` on a `code-wrong` disposition — the code is the bug; SPEC stands. Route to a code fix / bug instead.
- Applying a `code-ahead-correct` SPEC edit without explicit user approval — the gate is mandatory.
- Self-approving or auto-applying a SPEC correction in `unattended` mode — surface/park it.
- Silently rewriting SPEC to match the code without first classifying the divergence (the disposition is decided *before* any edit).

## Work language
Author any **SPEC edit** and the **audit `reason` text** in the **work language** — `resolve_work_lang` (SPEC §5.7.2), not necessarily the conversation language. Your chat replies to the user stay in the communication language.
