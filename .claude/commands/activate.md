---
description: Activate a Proposed Issue (Directive OR Execution) — runs activation-reviewer; on pass removes status:proposed (→ Active). No-arg batch-scans all open status:proposed Issues. Polymorphic; absorbs /activate-directive and /triage.
argument-hint: "[<issue-#>]"
---

Transition a `Proposed` Issue to `Active` by removing the `status:proposed` label after a fresh `activation-reviewer` (SPEC §4.9) pass on the current body. `/activate` is **type-neutral** — it handles Directives and Execution Issues (`task`/`bug`) alike; the reviewer dispatches by type label. This is the observer-side gate of the full-symmetry lifecycle (SPEC §2.1, §5.12).

Status is encoded as labels on the Issue (Issues are SSOT). The Project Status field is mirrored by `.github/workflows/issues-to-project-mirror.yml`; `/activate` does NOT write to the Project directly.

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | cut -f1 | grep -qx directive` fails. Fail-open on `gh` network errors.

1. **Mode select** from `$ARGUMENTS`:
   - **`<issue-#>` present → single mode** (step 2).
   - **no arg → batch mode**: `gh issue list --label status:proposed --state open --json number --limit 200`. For each `<N>`, apply the **loop-safety skip** then run steps 2–4. Skip is per SPEC §2.1: read the Issue's comments and its `updatedAt`; if the latest `<!-- activation-verdict: <verdict> -->` marker comment post-dates the last body/label modification, the verdict was already delivered and the author hasn't acted — **skip** this Issue (independent of the `awaiting-author` label). In `attended` mode, surface each `reject` to the operator; in `unattended` mode, auto-apply the filer matrix in step 4. **Batch mode scans only `status:proposed`, so it does NOT sweep Blocked Directives** — unblocking (§5.17) is single-mode `/activate <N>` only (auto-unblocking would silently reverse a deliberate maintainer block, the same filer-judgment reasoning that keeps `reject`/discussion-promotion out of `unattended`).
     - **Stale-discussion surface** (relocated from `/triage` by #173; SPEC §5.19 step 2.5): after the `status:proposed` sweep, also fetch open `discussion`-labeled Issues older than 14 days (`gh issue list --label discussion --state open --json number,title,createdAt --limit 100`) and surface them as a maintainer-decision queue — for each: *"discussion #N (open X days): promote / dismiss / let-incubate."* Resolve via `/resolve-discussion <N> --promoted-to <M>` or `--no-action "<reason>"`. **Mode-independent:** AI surfaces the queue but does NOT autonomously promote or dismiss, even in `unattended` (maintainer judgment, same filer-aware invariant as the reject path).

2. **Resolve + validate** — `gh issue view <N> --json title,body,state,labels,author,authorAssociation`.
   - `state != OPEN` → error (`"Issue is not open — state <X>"`) and skip/stop.
   - **Re-activatable state** — the Issue must carry `status:proposed` (Proposed) **or** `status:blocked` (an Active-but-Blocked Directive being unblocked, §5.17). If **neither** label is present the Issue is already plain Active → error (`"Issue #<N> is already Active (no status:proposed or status:blocked label)"`) and skip/stop. (A `status:blocked` Issue routes through the same reviewer gate below — unblocking re-validates the current body.)
   - Determine **type** (tri-state, aligned with `activation-reviewer`'s §4.9 dispatch): `initiative` label present → **refuse** — abort with `"Issue #<N> is an Initiative; Initiatives are consumed via /consume-initiative, not activated (read-only to the shell and outside the Proposed→Active lifecycle — §1.7/§2.1)."` (An Initiative never carries `status:proposed`, so this guard normally never fires; it defends against a hand-applied label, since a bare `directive`-else-Execution split would mis-type such an Issue as Execution.) Otherwise: `directive` label present → Directive; else Execution (`task`/`bug`).

3. **Reviewer gate** — invoke the `activation-reviewer` subagent (SPEC §4.9) on the current body, passing the resolved type, and — for Directives — the active-Directive list, or — for Execution Issues — the parent-Directive state + the open-Issues snapshot. Parse the verdict line (`^VERDICT: (pass|revise|reject)`).

   > Reviewer invocation is robust to the SPEC §4.9.3 session-restart caveat: if `subagent_type: activation-reviewer` falls back to `general-purpose` mid-session, the agent file's self-describing prompt makes the fallback functionally complete. Do not depend on a fresh session.

4. **Apply the verdict:**

   - **`pass`** → remove the activation labels that are **present** (from the step-2 label fetch — guard each removal, because `gh issue edit --remove-label <L>` errors when `<L>` is absent): `--remove-label status:proposed` if present; `--remove-label status:blocked` if present (the unblock, §5.17 — the mirror reconciles Status=Active on `issues.unlabeled`); `--remove-label awaiting-author` if present. The Issue is now Active. Post a brief `<!-- activation-verdict: pass -->` confirmation comment. Audit: `audit_log info activation activated "issue=#<N> type=<directive|execution> unblocked=<yes|no>"`.

   - **`revise`** → post the reviewer findings as a comment whose body includes the marker `<!-- activation-verdict: revise -->`. Retain `status:proposed`; `gh issue edit <N> --add-label awaiting-author`. **Escalation:** before posting, count existing `<!-- activation-verdict: revise -->` markers on the Issue; if this would be the **N=3rd**, treat the verdict as `reject` instead (escalation backstop). Audit: `audit_log info activation revise "issue=#<N> round=<k>"`.

   - **`reject`** → post the reviewer's verdict + structured fields (`verdict`/`reason`/`refile-target-type`/`refile-target-parent`/`refile-body-draft`) as a comment carrying `<!-- activation-verdict: reject -->`. Then apply **filer-aware handling** (verdict is content-only; handling keys on trust). Resolve trust via `is_trusted_filer <N>` (`.claude/hooks/helpers/issue_filer.sh`; `authorAssociation` ∈ OWNER/MEMBER/MAINTAINER/COLLABORATOR). **Trust must resolve positively** to take the untrusted-close path: if the trust check is *unresolvable* (`gh` down / no auth / empty `authorAssociation`), **park** — surface to the operator (attended) or leave the Issue open + log (unattended); do NOT auto-close on an unresolved trust check (a transient failure must not close a possibly-trusted filer's Issue).
     - **Trusted filer** → keep the Issue **open**, retain `status:proposed`, `--add-label awaiting-author`. **Never close** (composes with the `trusted-filer-mutate` hook, SPEC §6.1). The filer decides next.
     - **Untrusted filer (resolved), `refile-body-draft` present** → `gh issue close <N> --reason "not planned"`, then auto-create a `discussion`-tier Issue (SPEC §5.19) from the **sanitized** draft. **Transport (security, #172):** write the sanitized draft to a temp file and create with `gh issue create --body-file <file>` — **never** inline `--body "<untrusted text>"` (inline interpolation of untrusted backticks / `$(...)` / quote-breakouts is a shell-injection vector). **Sanitize before writing:** (a) neutralize **every** `@mention` anywhere in the body (e.g. prefix with a zero-width break or backtick-quote `@`), not just leading ones, so the new Issue cannot mass-ping; (b) use a **fixed** title `discussion: refile of #<N>` — never interpolate untrusted text into the title or any `gh` argument; (c) append a lineage line `Refiled from #<N> (activation reject).`; (d) autoloading images are left to GitHub's camo image proxy (accepted residual — camo strips the originating IP); do not render the draft anywhere outside the Issue body. Audit: `audit_log info activation refiled "from=#<N> discussion=#<M>"`. (Note: the original is closed `--reason "not planned"` — the **space** form, which is the only value `gh issue close --reason` accepts for "not planned"; `not_planned` (underscore) is rejected by `gh`. The auto-created discussion is later closed via `/resolve-discussion`, which also uses the space form at the `gh` boundary — the spelling is the same in both contexts, #216.)
     - **Untrusted filer (resolved), no draft** → `gh issue close <N> --reason "not planned"` with a brief reason comment. No discussion. Audit: `audit_log info activation rejected "issue=#<N>"`.

5. **Output** (single mode):
   ```
   /activate #<N>: <verdict>
   <pass: "Active (status:proposed removed)" | revise: "awaiting-author — author edits + re-run /activate" | reject: <filer-handling summary>>
   ```
   Batch mode prints one line per processed Issue + a trailing summary (`activated K, revise R, reject J, skipped S`).

## Operating mode

- **attended**: step 3's verdict surfaces to the user before applying; `reject` in batch mode surfaces for the operator's decision.
- **unattended**: the verdict gates directly; batch mode auto-applies the filer matrix (including the untrusted-reject auto-discussion) and moves on. `reject` is terminal — no auto-regeneration (SPEC §2.1; that is an explicit Directive #167 non-goal).

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /activate <N>` bypasses the reviewer gate. Audit-logged.

## Forbidden

- Activating an Issue without the `status:proposed` label (not in Proposed state).
- Closing a **trusted** filer's Issue on `reject` — trusted rejects keep the Issue open with `awaiting-author`.
- Assigning a parent Directive on the reviewer's behalf — the reviewer suggests; the author assigns (SPEC §4.9).
- Creating the auto-discussion from untrusted `refile-body-draft` text via inline `--body` — use `--body-file` from a written, sanitized file. Never interpolate untrusted text into the title or any `gh` argument; never skip the `#<N>` lineage line or the whole-body `@mention` neutralization.
- Auto-closing on `reject` when the trust check is unresolvable — park instead.
- Writing to the Project Item directly — that's the mirror workflow's job.
