---
description: Triage Issues with `needs-triage` or `status:proposed` labels — binary accept/reject per Issue via triage-reviewer; strict reject + refile semantics (no relabel) per SPEC §1.7 + Directive #92 brief §5.2 / §5.3 / Decision 4.
argument-hint: "[--limit <N>]"
---

Triage open Issues that carry `needs-triage` (raw filings) or `status:proposed` (Directive proposals awaiting maintainer ratification). For each, AI proposes ACCEPT or REJECT; the maintainer confirms; on REJECT the original Issue closes-as-not-planned and the maintainer refiles in the correct template.

Triage is the **maintainer's binary decision** per Issue. The triage-reviewer subagent (§4.10) is the classifier — checks whether the Issue's body matches its claimed template. The substantive review of Directive content remains at `/activate-directive` (via `activation-reviewer`, §4.9).

## Procedure

1. **Parse arguments** — `--limit <N>` optional (default: 20). Caps the number of Issues processed in one invocation; large queues should be triaged in batches to keep the maintainer's confirmation flow tractable.

2. **Fetch the triage queue**:
   ```bash
   gh issue list \
     --state open \
     --search "label:needs-triage OR label:\"status:proposed\"" \
     --limit "<N>" \
     --json number,title,body,labels,author
   ```
   Sort by `createdAt` ascending (oldest first) so older Issues are processed before newer ones.

2.5. **Stale-discussion surface** (Issue #116; SPEC §5.19) — fetch open `discussion`-labeled Issues older than 14 days separately. These are not in the triage-classification queue (no `triage-reviewer` invocation; discussions don't have a template to validate against). Surface them as a maintainer-decision queue:
   ```bash
   gh issue list \
     --state open \
     --label discussion \
     --search "created:<$(date -u -v-14d +%Y-%m-%d 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%d)" \
     --json number,title,createdAt \
     --limit 50
   ```
   For each, surface: "discussion #<N>: <title> (open <X> days). Choices: promote / dismiss / let-incubate". Maintainer decides:
   - **promote** → file a concrete Issue (`/file-issue` or `/file-directive`) referencing the discussion; then run `/resolve-discussion <N> --promoted-to <new-issue-#>`.
   - **dismiss** → `/resolve-discussion <N> --no-action "<reason>"`.
   - **let-incubate** → no action; will resurface in the next `/triage` run if still open.
   In **unattended mode**: AI surfaces the queue but does NOT autonomously promote or dismiss (same filer-aware invariant as the REJECT path — discussion resolution requires maintainer judgment).

3. **For each Issue, invoke `triage-reviewer`** (SPEC §4.10) with the Issue's title + body + labels + authorAssociation. Parse the verdict line:
   - `VERDICT: ACCEPT — <reason>`
   - `VERDICT: REJECT — refile as <template-name>: <reason>`

4. **Surface to the maintainer** (attended mode):
   - Print the Issue number + title + the reviewer's verdict line + a one-line summary.
   - Maintainer responds: `accept`, `reject`, `skip`, `quit`.
     - `accept` → apply ACCEPT action (step 5a).
     - `reject` → apply REJECT action (step 5b).
     - `skip` → leave Issue untouched; move to next.
     - `quit` → stop processing; remaining Issues stay in the queue.
   - In **unattended mode**: AI auto-applies the reviewer's verdict — `ACCEPT` runs step 5a; `REJECT` STOPS (per filer-aware invariants §1.5 + brief §10 non-goal #8 — AI does NOT autonomously refile, even in unattended mode). Log a `triage rejected-skip` audit line so the maintainer's next session sees the queue.

5a. **ACCEPT action**:
   - If the Issue has `needs-triage` label, remove it (`gh issue edit <N> --remove-label needs-triage`). `status:proposed` stays — that label is removed by `/activate-directive` after substantive review, not by `/triage`.
   - `audit_log info triage decided "issue=#<N> action=accept template=<resolved-template>"`.

5b. **REJECT action** (strict reject + refile per Decision 4):
   - Print the refile recommendation to the maintainer + the body extract that should be reused under the correct template.
   - Maintainer (NOT AI) runs `gh issue create --template <correct-template>` — possibly copy-pasting body content. New Issue is filed; its number is `<M>`.
   - `gh issue close <N> --reason "not planned"` — note that `gh issue close` on a trusted-filer Issue without `--reason completed` is blocked by the `trusted-filer-mutate` hook matcher (SPEC §6.1) UNLESS the maintainer escapes with `SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='triage-reject: refiled as #<M>'`. The `/triage` flow recommends including this escape automatically in the close-as-not-planned step, with a structured reason so the audit trail names the refile target.
   - Post a closing comment on `<N>`:
     ```
     This Issue was filed via <claimed-template> but its content fits <correct-template>.
     Refiled as #<M> using the correct template. Original Issue preserved for reference.
     Reactions and comments do not migrate.
     ```
   - `audit_log info triage refiled "from=#<N> to=#<M> reason=<short>"`.

6. **Loop step 3-5** until the queue is empty or the maintainer quits.

7. **Output summary**:
   ```
   Triaged <K> issues: <A> accepted, <R> rejected (refiled to <RR>), <S> skipped.
   Queue remaining: <Q> issues.
   ```

## Operating mode

- **attended** (default): each verdict surfaces to the maintainer for confirmation before applying. The triage-reviewer's verdict is advisory.
- **unattended**: ACCEPT auto-applies; REJECT halts (per brief §10 non-goal #8 — AI does NOT autonomously refile). The reject-skip is logged for the next maintainer session.

## Escape

No `SKIP_HOOKS=triage` escape — there's no hook gating triage decisions. The maintainer's confirmation step (in attended mode) or the auto-halt (in unattended mode) is the only escape from a misguided reviewer verdict.

## Forbidden

- AI autonomously running `gh issue create` to refile (per brief §6 + §10 non-goal #8). Maintainer must execute the refile manually.
- Relabeling the original Issue's `directive` label to `task` (or any cross-template relabel). The strict invariant per Decision 4: every open Issue matches its template; mis-template Issues close + refile, they don't relabel.
- Closing the Issue without the closing comment (step 5b second-to-last bullet). The comment is the canonical bread-crumb to the refiled Issue.
- Skipping the `audit_log triage` line. Per SPEC §2.1, `triage` is one of the dir-mode audit categories; the trail must exist for `/audit` queries.
