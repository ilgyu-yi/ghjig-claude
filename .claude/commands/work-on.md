---
description: Take an issue, create branch + draft PR, invoke planner — all in one. Supports --base for topic-branch / experimental work (SPEC §10.5).
argument-hint: <issue#> [--base <branch>]
---

Parse `$ARGUMENTS`: the issue number plus optional `--base <branch>` (default `main`). Do the following in order:

1. `gh issue view <#> --json title,body,labels` — read the issue. Print it and give the user a brief summary.
2. **Acceptance criteria check** — if the issue body has no criteria or is vague, ask the user to fix it and stop. **Don't start work with an ambiguous goal.**
3. **Resolve target base** — let `BASE` = `--base` arg (default `main`). Then `git fetch origin && git checkout "$BASE" && git pull --ff-only`. If `BASE != main` and the named branch isn't reachable locally or remotely, fail loudly — `/work-on` does NOT auto-create alternate bases. See SPEC §10.5 for the topic-branch pattern.
4. Create branch:
   - `USER=$(gh api user --jq .login)`
   - `TYPE` = from issue label or user confirmation (one of feat/fix/docs/refactor/perf/test/style/build/ci/chore/revert)
   - `SLUG` = kebab-case abbreviation of issue title
   - `git checkout -b "${USER}/${TYPE}/<#>-${SLUG}"`
   - If the branch already exists on remote: `git pull --ff-only origin <branch>`.
5. **Invoke planner agent** — pass issue body, target `MISSION.md`, target `CLAUDE.md`, **and the resolved `BASE`** as input. Receive the plan markdown. The planner output must include non-empty `## Alternatives considered` AND `## Target base` sections (mandatory per SPEC §4.1); the `Target base` value must equal `BASE`. Reject and re-invoke if either is missing or empty.
6. **Reviewer gate** — invoke the `plan-reviewer` subagent (see SPEC §4.8) on the planner output. Pass the planner output, the issue body, and the target MISSION.md. Parse the verdict line (`^VERDICT: (ship|refine|block)`).
   - **`ship`**: proceed to step 7.
   - **`refine: <feedback>`**: re-invoke `planner` with the one-line feedback. Re-invoke `plan-reviewer` on the new output. After two consecutive `refine` verdicts on the latest plan, escalate to the user (or, in unattended mode, treat as `block`).
   - **`block: <reason>`**: stop and post a `gh issue comment` on the linked issue naming the structural problem. In unattended mode, also append one line to `$CLAUDE_ENG_SHELL_ROOT/.claude/state/plan-block.log`.
7. **Wait for user approval of the plan.** Approval requires an **approach check**: confirm with the user that the chosen approach beats the alternatives the planner surfaced, not just that the plan exists. If the alternatives are weak (single option without an explicit forced-choice justification), refine before approval. The approach check is not skipped in Auto / unattended mode. **In `unattended` mode, a clean `plan-reviewer` verdict from step 6 counts as approval** — no human is present, and the reviewer is the substitute.
8. Once approved, **write Phase A (Doc) and make it the first commit on the branch.** Never open the PR with an empty seed commit.
   ```
   # …edit the SSOTs identified by the plan (MISSION, README, CLAUDE.md, ARCHITECTURE, ADR)…
   git add <changed SSOTs>
   # First-line trailer is `Closes #<#>` when BASE == main; otherwise `Refs #<#>`.
   # The issue should auto-close only when work reaches main (SPEC §10.4 / §10.5).
   TRAILER="Closes #<#>"; [ "$BASE" != "main" ] && TRAILER="Refs #<#>"
   # Co-Authored-By trailer is toggleable (SPEC §10.2). Source the helper
   # and conditionally include the line — the `${COAUTHOR:+…}` expansion
   # injects the leading blank line ONLY when the trailer is enabled, so
   # `off` users don't get a trailing blank in the commit message.
   . "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/coauthor.sh"
   COAUTHOR=$(coauthor_trailer)
   git commit -m "<type>(#<#>): <subject>

   ${TRAILER}${COAUTHOR:+

   ${COAUTHOR}}"
   git push -u origin HEAD
   gh pr create --draft --base "$BASE" --title "<type>(#<#>): <subject>" --body "<filled pr_body.md>"
   ```
   `Closes` vs `Refs` — the rule above is the default; the user may override on split (intermediate PR → `Refs`, final consolidator → `Closes`).

   If Phase A isn't ready to commit (e.g. planner output needs more clarification), **defer the PR** — keep the issue + plan in conversation. Don't fall back to an empty seed commit just to open the draft PR; see SPEC §5.3.
9. Print "ready to start" message. Continue with the next phase (Test).
