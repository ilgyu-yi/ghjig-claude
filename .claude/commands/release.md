---
description: Cut a versioned release — consolidates per-PR changelog fragments into a new CHANGELOG.md section, writes VERSION, opens a release/X.Y.Z draft PR. Documents the post-merge tag + GitHub Release step.
argument-hint: <X.Y.Z> [--base <branch>] [--dry-run]
---

Consume the fragment-contract substrate (SPEC §18) and produce a release PR. The deterministic work lives in `scripts/release_consolidate.sh` so smoke exercises it directly; this skill is the interactive wrapper that branches, commits, reviewer-gates, and opens the PR.

## Procedure

1. **Parse `$ARGUMENTS`** —
   - `<X.Y.Z>` (required) — semver 0.x; the helper rejects `MAJOR > 0` with explicit `SPEC §3.5 / §18.2 MAJOR=0 invariant` message. Reject anything not matching `^0\.[0-9]+\.[0-9]+$` as a `semver` format error.
   - `--base <branch>` (default `main`) — target base for the release PR. Maintenance-line cuts pass a `*-maintenance` branch per SPEC §18.3 / §10.5.
   - `--dry-run` — pass through to the helper; the helper stages mutations but does NOT commit, push, or branch. Used by smoke; humans rarely invoke this.

2. **Preflight** (delegate to helper) — `scripts/release_consolidate.sh <X.Y.Z> [--base <branch>] [--dry-run]` performs:
   - Clean working tree assertion (refuse with "git reset --hard HEAD to retry" error if dirty).
   - On target base (`git fetch origin && git checkout <base> && git pull --ff-only`).
   - `git fetch --tags origin` to refresh tag view.
   - Refuse with `release/X.Y.Z branch already exists on origin` if the branch is present.
   - Refuse with `vX.Y.Z already released` (exit 0, no mutation) if the tag is present — idempotent retry per SPEC §18.4.
   - **Manifest-match check** (verify, not write-back; SPEC §18.2 / §6.6, #469): resolve the detected stack's version field via `detect_version` and refuse (naming both versions + the bump fix) on a confident mismatch with `X.Y.Z`. An unknown stack / absent or unparseable field degrades to a graceful skip with a note. The manifest is read, never written.

3. **Fragment scan + validate** (helper) —
   - Enumerate `changelog_unreleased/<category>/*.md` across the six Keep-a-Changelog categories.
   - For each fragment: (a) filename stem `<N>` is a positive integer, (b) the bullet contains `(#<N>)` matching the stem (substring match — cross-references to other issues inside the bullet are allowed).
   - If no fragments exist, exit non-zero with stderr naming `no fragments` + the `changelog_unreleased/` path.
   - On validation failure, exit non-zero with stderr naming the offending file + the specific mismatch (stem vs `(#N)` ref).

4. **VERSION write-back** (helper) — strip any `-dev` suffix from the top-level `VERSION` and write `X.Y.Z`. Resolution-time queries fall back to `git describe --tags`; write-back is `VERSION`-only per SPEC §18.2.

5. **CHANGELOG consolidate** (helper) —
   - Build the new section: `## [X.Y.Z] — YYYY-MM-DD` (UTC date via `date -u +%Y-%m-%d`).
   - For each category with at least one fragment, append `### <Category>` subheading + the verbatim bullets from each fragment in stem-ascending order.
   - Prepend the new section to `CHANGELOG.md` immediately below the file header.
   - Append `[X.Y.Z]: https://github.com/<owner>/<repo>/releases/tag/vX.Y.Z` reference link at the file footer.

6. **Fragment cleanup** (helper) — `git rm` every consumed fragment file. The six `.gitkeep` placeholders stay.

7. **--dry-run gate** — if `--dry-run` was passed, the helper stages everything (`git add VERSION CHANGELOG.md`; `git rm` already staged the removals) and exits 0. Smoke inspects via `git diff --cached`. The skill stops here in dry-run mode and prints `dry-run: changes staged; not committing`. Otherwise continue.

8. **Branch + commit** — create `release/X.Y.Z`, write the `branch`-category file-based skip token, then commit the staged diff:
   ```bash
   git checkout -b release/<X.Y.Z>
   scripts/ghjig_skip.sh branch 'chore: release <X.Y.Z>' '/release branch commit'
   git commit -m "chore: release <X.Y.Z>" -m "Consolidated $(N) fragments. See CHANGELOG.md ## [<X.Y.Z>]."
   ```
   The token's fingerprint is the **commit subject** `chore: release <X.Y.Z>` (high-entropy, distinguishing — SPEC §7). The hook reads it at fire time, audits it, and consumes it. The in-harness-inert leading form `SKIP_HOOKS=branch SKIP_REASON='/release branch commit' git commit …` remains the **verbatim-shell** equivalent for a real terminal, but does **not** disarm the matcher in-harness (it is stripped before the hook).

   The subject is the **scopeless** `chore: release <X.Y.Z>`, not `chore(release): …`: the conventional-commit matcher (SPEC §6.1, `commit-format` category) permits only a `(#N)` scope or no scope (`conventional_commit.sh` `re_optional`), so a `(release)` scope is rejected — and the `branch` escape covers only the `branch` category, *not* `commit-format`. Scopeless fits the repo's "scope = issue number" convention with zero hook change.

   The `branch` escape is **structurally required**: the protected-branch matcher (SPEC §6.1, `helpers/git_matcher.sh` pattern `release/\S+`) blocks all direct commits on `release/X.Y.Z`, and this is the one purposeful commit `/release` makes. Audit-logged with the documented reason; `/audit` can filter on it to distinguish legitimate uses from drift.

9. **Reviewer gate** (`unattended` mode only) — invoke `code-reviewer` (SPEC §4.5) against the staged release diff before opening the PR. On `block` verdict, stop with the reason and leave the branch in place for the maintainer to inspect. On `refine`, surface the feedback; the helper does not auto-revise (the release diff is deterministic). On `ship`, proceed. Skip in `attended` mode (the human reviews the PR after creation). Escape: `SKIP_HOOKS=release-review SKIP_REASON='<why>'`.

10. **Push + draft PR** —
    ```bash
    git push -u origin HEAD
    gh pr create --draft --base "<base>" \
      --title "chore: release <X.Y.Z>" \
      --body-file <(printf '%s\n' "Release <X.Y.Z>. Consolidates <N> changelog fragments into CHANGELOG.md ## [<X.Y.Z>]. VERSION updated to <X.Y.Z>.")
    ```
    The PR body includes the newly-prepended `## [X.Y.Z]` section verbatim for reviewer convenience.

11. **Audit log** — `audit_log info release created "version=<X.Y.Z> base=<branch> pr=<pr-num>"`.

12. **Output** —
    ```
    Release PR opened: <pr-url>
    VERSION: <X.Y.Z>
    Fragments consolidated: <N>
    Post-merge: run `gh release create v<X.Y.Z> --target <merge-sha> --notes-file <(awk '/^## \[<X.Y.Z>\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md)` then `scripts/release_verify.sh <X.Y.Z>` after the PR merges.
    ```

## Post-merge tag + GitHub Release

After the release PR merges to the target base, the maintainer (or the `unattended` continuation of `/ship`) runs:

```bash
GR="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/ghjig-root"
[ -e "$GR/.claude" ] || { echo "GHJig: not inside a registered project (cd to the project root, or run scripts/register.sh)"; exit 1; }
git fetch origin
git checkout <base>
git pull --ff-only
MERGE_SHA=$(git rev-parse HEAD)
awk '/^## \[<X.Y.Z>\]/{f=1; next} /^## \[/{f=0} f' CHANGELOG.md > /tmp/release-notes-v<X.Y.Z>.md
gh release create v<X.Y.Z> --title v<X.Y.Z> --target "$MERGE_SHA" --notes-file /tmp/release-notes-v<X.Y.Z>.md
"$GR/scripts/release_verify.sh" <X.Y.Z>   # confirms the tag + Release-with-notes landed
```

**No `--verify-tag`** (#448): that flag *aborts* `gh release create` unless the tag already exists, but the tag and Release are created **together** here (the tag is made from `--target`), so `--verify-tag` would always abort on a fresh release. Omitting it lets `gh release create` make both.

**Post-merge verify** (#471, SPEC §18.2): `scripts/release_verify.sh <X.Y.Z>` is a **read-only, fail-open** confirmation run *after* the create — it checks the `vX.Y.Z` tag exists and a GitHub Release with **non-empty notes** is present, printing an advisory line on a missing tag / missing or empty-notes Release. It never creates anything and exits 0 on every path (gh error / offline → a single advisory line), so it observes the result without blocking the flow. The `/ship` `unattended` post-merge continuation runs it after its `gh release create`.

This is intentionally manual per Directive #128 non-goal ("No automated distribution") — the one-liner stays visible and auditable rather than buried in a workflow. Adopters who want full automation can wrap this in a `release-tag.yml` workflow downstream without changing the skill.

Re-running `gh release create` on an existing tag fails with a clear `release already exists` message — idempotent at the gh-CLI layer.

## Operating mode

- **attended**: step 9 reviewer gate is skipped; the human reviews the PR after `gh pr create`. Post-merge tag/Release step is run manually by the maintainer.
- **unattended**: step 9 reviewer gate runs (`code-reviewer` substitutes for human review per SPEC §1.5). Post-merge step is run by the `/ship` continuation after auto-merge.

## Escapes

- `scripts/ghjig_skip.sh branch 'chore: release <X.Y.Z>' '/release branch commit'` — the `branch` file-based skip token (SPEC §7), structurally required for step 8 (the one purposeful commit on the `release/X.Y.Z` branch). Audit-logged + consumed on read. Reuse outside `/release` invocations is a smell — `/audit` should filter on the documented reason string. (The leading `SKIP_HOOKS=branch SKIP_REASON='/release branch commit'` form is the verbatim-shell equivalent for a real terminal; it does not land in-harness.)
- `SKIP_HOOKS=release-review SKIP_REASON='<why>'` — bypass the reviewer gate at step 9. Audit-logged.

## Forbidden

- Tagging without a prior PR merge — tag creation always references a merge commit on the target base.
- Direct `git tag` without `gh release create` — the GitHub Release and the tag must be created together so the Release page is sourced from the CHANGELOG section.
- Third-party GitHub Action references (`uses:` on a non-`actions/` action) — the post-merge step is bash + `gh` + `git` only per Directive #128 constraint.
- Auto-bumping `VERSION` to the next `-dev` value in the release commit — that's a separate in-line edit in the first PR after the release lands. Documented in Open questions of Issue #131 plan.

## Audit categories

- `release/created` — release PR opened successfully.
- `release/idempotent` — already-released tag detected; no mutation.
- `release/blocked` — preflight or validation failure; helper exited non-zero.
