---
description: Author the changelog fragment for the current PR in-flow, or apply the skip-changelog label — the local pre-image of the check-changelog CI gate (SPEC §18). Authoring affordance, not a lint surface.
argument-hint: [--skip | <category>]
---

Satisfy the §18.1 fragment contract **inside the flow** for the current PR/branch, so the gate is met before CI rather than after a red check (SPEC §5.23, §18.7). This skill is an **authoring affordance**: it *writes* a fragment or *applies* the `skip-changelog` label and **delegates all validation to the CI gate (`check-changelog.yml`, §18.6)** — it never re-implements the fragment-shape rules and is therefore **not** a `/changelog-check` lint surface (the §18.5 non-goal). It does **not re-validate** what CI already checks.

## Procedure

1. **Resolve the PR + allow-set.** Find the current branch's PR (`gh pr view --json number,closingIssuesReferences,files,title,body`). The fragment-number **allow-set** is `PR number ∪ closingIssuesReferences[].number` — computed the **same way as `check-changelog.yml`** (referenced, never re-derived), so a fragment that passes here passes CI. If no PR exists yet, use the branch's issue number (from the branch name / `Closes #N`) and note the fragment can be renamed to the PR number later.

2. **Decide: fragment or skip** (SPEC §18.7 is the SSOT for this decision):
   - **Fragment required** when the PR changes user-/adopter-observable surface — behaviour/contract, CLI/API/schema/protocol, a SPEC contract, or how someone uses/integrates the project.
   - **`skip-changelog` eligible** when there is no such surface — internal `refactor` (unchanged behaviour), `test`-only, `chore`/`build`/`ci`, `style`, or a docs-internal edit changing no contract.
   - When in doubt, write the fragment. `--skip` forces the skip decision; a bare `<category>` argument forces that category for the fragment.

3. **If writing a fragment:**
   - Infer the Keep-a-Changelog **category** from the diff: `added` / `changed` / `deprecated` / `removed` / `fixed` / `security` (or use the `<category>` argument).
   - Write `changelog_unreleased/<category>/<N>.md` where `<N>` is a member of the allow-set (prefer the PR number; an issue number is also valid), as a **single-line markdown bullet** beginning with `- ` and containing `(#<N>)` matching the filename stem (SPEC §18.1).
   - Commit it (`chore(#<N>): add changelog fragment` is fine; the fragment may also ride the feature commit). Validation is CI's job — do not re-check the shape here.

4. **If skipping:** `gh pr edit <PR> --add-label skip-changelog`. Create the label on demand if absent. No fragment is written; the PR will not appear in the eventual `CHANGELOG.md` section.

5. **Confirm** which path was taken (fragment path written, or label applied) and that exactly one of the two now holds.

## Operating mode

- **attended** (default): propose the inferred decision — the drafted fragment line + category, or the skip rationale — and let the human confirm or adjust before writing/labelling.
- **unattended**: apply the decision automatically (reviewer-substitution model, SPEC §1.5). Default to writing a fragment whenever the change is observable; only skip when the change is clearly internal per §18.7.

## Relation to /ship

`/ship`'s mandatory pre-ready gate (step 7.7, SPEC §5.7) is a **presence** check — exactly one of {fragment for an allow-set number, `skip-changelog` label} must hold before `gh pr ready`. When it is unsatisfied, `/ship` invokes this skill. Running `/changelog` standalone earlier in the flow pre-satisfies that gate.

## Work language
Author the **fragment bullet** in the **work language** — `resolve_work_lang` (SPEC §5.7.2), not necessarily the conversation language. Before authoring, recast the change into the work language; your chat replies to the user stay in the communication language. Default (unset) is `en`.
