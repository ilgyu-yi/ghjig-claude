---
description: After a PR merges, post a reflection comment on the parent Directive (when one exists) summarizing the PR's contribution toward that Directive's success signals (SPEC §5.7 dir-mode integration, added by tracking #41 child #6).
argument-hint: [<pr-#>]
---

Post a structured reflection comment on a PR's parent Directive summarizing what the PR contributed and which success signals it advances. Run after merge; idempotent.

## Procedure

1. **Resolve the PR** — either the argument `<pr-#>` or the current branch's merged PR. Fetch via `gh pr view <pr> --json number,title,body,mergedAt,closingIssuesReferences,url`. If `mergedAt` is null: stop with error ("PR not merged yet; /reflect runs post-merge").

2. **Find the parent Directive** — for each issue in `closingIssuesReferences`, read the issue body and look for the regex `^Parent Directive: #(\d+)$`. If multiple Issues each have a Parent Directive, pick the first; if none, stop with output `/reflect: no parent Directive on closing Issues; nothing to post.` (No error; this is a normal no-op.)

3. **Classify existing reflection** (idempotency, #329) — scan the parent Directive's comments (`gh issue view <D> --comments --json comments`) and classify by **content marker**, NOT the PR URL. The URL is shared by both the workflow stub and the enriched form, so a URL-keyed check would always no-op against the workflow's at-merge stub and the enrichment would never happen — the #329 bug. Three branches:
   - A comment contains `<!-- reflect-enriched pr=#<P> -->` → **already enriched**: stop with `/reflect: Directive #<D> already enriched for PR #<P>; no-op.` Audit `audit_log info directive-reflect skipped "already-enriched: directive=#<D> pr=#<P>"`.
   - Else a comment contains `<!-- reflect-stub pr=#<P> -->` (the hook-enforced workflow floor) → **enrich in place**: capture that comment's **REST id** (the trailing integer of its `.url`, `…#issuecomment-<id>` — NOT the GraphQL `.id` node id) and take the PATCH branch in step 5.
   - Else → **post fresh** (step 5 post branch).

4. **Compose the reflection comment**:
   ```markdown
   ## Reflection from PR #<P> (resolved by /reflect)
   <!-- reflect-enriched pr=#<P> -->

   **PR**: [#<P>: <title>](<url>) — merged <mergedAt>
   **Linked Execution Issue**: #<N> (auto-closed)
   **Parent Directive**: #<D>

   ### Contribution
   <One-paragraph summary of what the PR did, derived from the PR body's "## Goal" and "## Checklist" sections. Aim for 3-5 sentences.>

   ### Success signals advanced
   - **<signal text>** — <evidence sentence; AC ticked, smoke section, etc.>
   - **<signal text>** — <evidence sentence>

   ### Next
   <One sentence on what's still open toward this Directive's signals.>
   ```
   Read the Directive's `## Success signals` section from its body (the same field `activation-reviewer` uses at completion time). For each signal, search the PR body / AC closeout comment for evidence; if no evidence is found, mark the signal as "not advanced by this PR" rather than fabricating a claim.

5. **Write the comment** — branch on step 3's classification. Pass the body via stdin / a temp file (`--body-file` / `-f body=@-`), **never** argument-interpolated, so PR/Directive text cannot inject `gh` arguments:
   - **enrich in place** (step 3 found the `reflect-stub`): edit the bot-authored stub by REST id — `printf '%s' "<composed>" | gh api -X PATCH "/repos/<owner>/<repo>/issues/comments/<id>" -f body=@-`. (`gh issue comment --edit-last` can't be used — it only edits the caller's own last comment, and the stub is authored by `github-actions[bot]`.) This swaps the `reflect-stub` marker for `reflect-enriched` in place, preserving the comment's position.
   - **post fresh** (no stub or enriched comment present): `gh issue comment <D> --body-file <file>`.
   Capture the comment URL.

6. **Audit log** — `audit_log info directive-reflect posted "directive=#<D> pr=#<P> issue=#<N>"`.

7. **Output**:
   ```
   /reflect: posted reflection on Directive #<D> for PR #<P>.
   Comment: <url>
   ```

## Operating mode

Same in attended and unattended modes. The comment is a record, not a gate — no reviewer needed.

## When to invoke

- **Canonical hook-enforced path**: `.github/workflows/dir-mode-post-merge.yml` (Directive #61) posts a **stub** reflection (marked `<!-- reflect-stub pr=#N -->`) automatically on every merged PR with a `Parent Directive: #N` marker, regardless of who merged. A later `/reflect` run **enriches that stub in place** (step 5 PATCH branch), swapping the marker for `<!-- reflect-enriched pr=#N -->`. The two paths dedupe via the **content markers** (step 3), not the shared PR URL — a URL-keyed check would make `/reflect` no-op against the workflow stub and never enrich it (the #329 bug).
- **After `/ship`** finishes a `clean` merge in unattended mode — the user can chain `/reflect` to record the progress trail.
- **Manually** after a PR has merged — useful for backfilling reflections on past PRs or for producing a richer per-signal evidence block than the Action's auto-generated stub.
- **Not from `/ship` automatically** — auto-posting the comment from `/ship`'s procedure would couple two distinct artifacts (the ship action + the dir-mode reflection) and make idempotency harder to reason about. `/ship` step 10.5 records the bare `directive-exec-count` audit; `/reflect` is the human-readable counterpart; the workflow is the hook-enforced floor.

## Forbidden

- Posting the reflection comment on a PR that hasn't merged.
- Posting a **second** reflection when an enriched one (`<!-- reflect-enriched pr=#<P> -->`) already exists (idempotency). A bare workflow stub (`<!-- reflect-stub pr=#<P> -->`) is NOT a reason to skip — it is the thing to enrich in place.
- Fabricating signal-evidence — if the PR didn't advance a signal, the comment says so rather than claiming a tick.
- Closing the parent Directive — `/reflect` records progress; only `/complete-directive` flips the Status (SPEC §2.1, §5.13).
