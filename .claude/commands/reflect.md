---
description: After a PR merges, post a reflection comment on the parent Directive (when one exists) summarizing the PR's contribution toward that Directive's success signals (SPEC §5.7 dir-mode integration, added by tracking #41 child #6).
argument-hint: [<pr-#>]
---

Post a structured reflection comment on a PR's parent Directive summarizing what the PR contributed and which success signals it advances. Run after merge; idempotent.

## Procedure

1. **Resolve the PR** — either the argument `<pr-#>` or the current branch's merged PR. Fetch via `gh pr view <pr> --json number,title,body,mergedAt,closingIssuesReferences,url`. If `mergedAt` is null: stop with error ("PR not merged yet; /reflect runs post-merge").

2. **Find the parent Directive** — for each issue in `closingIssuesReferences`, read the issue body and look for the regex `^Parent Directive: #(\d+)$`. If multiple Issues each have a Parent Directive, pick the first; if none, stop with output `/reflect: no parent Directive on closing Issues; nothing to post.` (No error; this is a normal no-op.)

3. **Idempotency check** — scan the parent Directive Issue's existing comments (`gh issue view <D> --comments`) for an existing comment containing the merged PR's URL. If found, stop with `/reflect: parent Directive #<D> already has a reflection comment for PR #<P>; idempotent no-op.` Audit: `audit_log info directive-reflect skipped "already-posted: directive=#<D> pr=#<P>"`.

4. **Compose the reflection comment**:
   ```markdown
   ## Reflection from PR #<P> (resolved by /reflect)

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
   Read the Directive's `## Success signals` section from its body (the same field `directive-reviewer` uses at completion time). For each signal, search the PR body / AC closeout comment for evidence; if no evidence is found, mark the signal as "not advanced by this PR" rather than fabricating a claim.

5. **Post the comment** — `gh issue comment <D> --body "<composed>"`. Capture the new comment URL.

6. **Audit log** — `audit_log info directive-reflect posted "directive=#<D> pr=#<P> issue=#<N>"`.

7. **Output**:
   ```
   /reflect: posted reflection on Directive #<D> for PR #<P>.
   Comment: <url>
   ```

## Operating mode

Same in attended and unattended modes. The comment is a record, not a gate — no reviewer needed.

## When to invoke

- **Canonical hook-enforced path**: `.github/workflows/dir-mode-post-merge.yml` (Directive #61) posts the reflection automatically on every merged PR with a `Parent Directive: #N` marker, regardless of who merged. The Markdown procedure here remains valid for Claude-in-loop runs — both paths arrive at the same comment shape and the existing-URL idempotency check dedupes.
- **After `/ship`** finishes a `clean` merge in unattended mode — the user can chain `/reflect` to record the progress trail.
- **Manually** after a PR has merged — useful for backfilling reflections on past PRs or for producing a richer per-signal evidence block than the Action's auto-generated stub.
- **Not from `/ship` automatically** — auto-posting the comment from `/ship`'s procedure would couple two distinct artifacts (the ship action + the dir-mode reflection) and make idempotency harder to reason about. `/ship` step 10.5 records the bare `directive-exec-count` audit; `/reflect` is the human-readable counterpart; the workflow is the hook-enforced floor.

## Forbidden

- Posting the reflection comment on a PR that hasn't merged.
- Posting if an existing reflection comment for this PR already exists on the Directive (idempotency).
- Fabricating signal-evidence — if the PR didn't advance a signal, the comment says so rather than claiming a tick.
- Closing the parent Directive — `/reflect` records progress; only `/complete-directive` flips the Status (SPEC §2.1, §5.13).
