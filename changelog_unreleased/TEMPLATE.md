# Changelog fragment authoring

Every PR that lands an end-user-observable change adds a **changelog fragment** to this directory. The next `/release X.Y.Z` consolidates all present fragments into a new section in `CHANGELOG.md` at repo root, grouped by category, and deletes the consumed fragments in the same commit.

## Where it goes

`changelog_unreleased/<category>/<N>.md` where:

- `<category>` is one of six [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) categories. Pick by the kind of change:
  - `added/` — new features, new commands, new public surfaces.
  - `changed/` — behavior or appearance of existing features changes for the user.
  - `deprecated/` — feature still works but is on its way out; users should migrate.
  - `removed/` — feature no longer present.
  - `fixed/` — bug fix the user would notice.
  - `security/` — fix for a vulnerability or a security-posture improvement.
- `<N>` is the PR number that introduces the fragment (or the issue number when filing the fragment ahead of the PR). Positive integer; **filename stem must equal the `<N>` referenced inside the bullet**.

## What it contains

A **single-line markdown bullet** beginning with `- `. The bullet **must contain `(#<N>)`** where `<N>` matches the filename stem. The CI fragment-check rejects:

- Files outside the six category subdirectories.
- Filenames whose stem is not a positive integer.
- Bullets whose `(#<N>)` reference does not match the filename stem.

That is the entire contract. No YAML frontmatter. No multi-paragraph prose. No nested headers. The directory is the category, the filename is the issue/PR link, the bullet is the user-facing line.

## Example

`changelog_unreleased/added/142.md`:

```markdown
- New `/release` skill consolidates per-PR fragments into a versioned `CHANGELOG.md` section and creates the matching tag + Release on merge. (#142)
```

## Skipping

A PR with no observable end-user behavior change — pure docs-fix typo, dependency-only chore, internal refactor — may apply the `skip-changelog` label to the PR instead of adding a fragment. PRs that take this path produce no fragment and do not appear in the eventual `CHANGELOG.md` section.

## See also

- The release-backbone contract in this project's SPEC, section "Release backbone".
- `CHANGELOG.md` at the repo root for the consolidated history.
