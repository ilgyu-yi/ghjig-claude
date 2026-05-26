# ADR 0002: Directive / Project v2 field schema

- Date: 2026-05-24
- Status: Accepted (Superseded — see header note)
- Context PR: #48 (tracker: #41 child #2 / issue #43)

> **Header note (2026-05-26 / Directive #92 cluster J2)**: this ADR is **substantively superseded by [ADR-0003](0003-issues-ssot-substrate.md)** (dir-mode v3 reframe — Issues-as-SSOT substrate). The Project v2 field schema documented here remains the *derived-view* schema (the mirror workflow's target field set), but it is no longer the authoritative SSOT for dir-mode state. Specific changes per ADR-0003: (1) `Type` field loses the `Goal` option (Goal artifact eliminated; MISSION.md is canonical); (2) `Status` field's option set narrows from 5 (`Planned / Active / Completed / Blocked / Revised`) to 4 (`Proposed / Active / Blocked / Completed`) — `Revised` is dropped; `Planned` is renamed to `Proposed` to align with the OSS-standard "filed but not yet triaged" semantic; (3) `Confidence` and `Success Signals` Project fields are removed (content moves to Issue body sections); (4) `Iteration` stays user-managed on Project per ADR-0003 Decision 5; (5) `Parent` stays as TEXT, mirrored from the Issue body's `Parent Directive: #N` line-1 marker. The two-layer idempotency contract (field existence + SINGLE_SELECT option-set correctness, from issue #76) carries forward to the v3 schema. `scripts/setup_project.sh` is updated in cluster G to declare the v3 field schema; the mirror workflow (cluster D, `.github/workflows/issues-to-project-mirror.yml`) is the runtime data path that populates fields from Issue state. This ADR is preserved as the historical lock document for v0 substrate; future per-field decisions reference ADR-0003.

## Context

ADR-0001 (PR #48) locked the six core decisions for v0 director-mode, including **GitHub Projects v2 as substrate**. That ADR named the field set in passing (`Type / Status / Iteration / Priority / Parent / Confidence / Success Signals`) but did not lock per-field types, allowed values, or population conventions. This ADR closes that gap.

The substrate is created by `scripts/setup_project.sh` (introduced by this PR). Once a Directive is filed against the substrate, field renames or type changes are migration-grade — the Projects v2 API does not allow lossless type conversion on populated fields. This ADR therefore locks the schema *before* any data lands.

## Decision

### Field schema (six script-managed + one user-managed = seven total)

| Field | Type | Values / Notes | Created by | Used by |
|-------|------|----------------|-----------|---------|
| `Type` | `SINGLE_SELECT` | `Goal`, `Directive`, `Execution` | `setup_project.sh` | All rows; primary `Type`-awareness key (SPEC §1.7, §6.1) |
| `Status` | `SINGLE_SELECT` | `Planned`, `Active`, `Completed`, `Blocked`, `Revised` | `setup_project.sh` | Directive primarily; Execution rows use repo-native open/closed state |
| `Iteration` | `ITERATION` | 2-week cadence, Monday-start (recommended; user picks at creation time) | **User via GH UI** (see "Iteration constraint" below) | Directive (optional cycle reference) |
| `Priority` | `SINGLE_SELECT` | `P0`, `P1`, `P2`, `P3` | `setup_project.sh` | Directive + Execution (ordering field) |
| `Parent` | `TEXT` | Free-form text storing `#N` reference to parent Directive Issue | `setup_project.sh` | Execution (and recursive Directive parenting if v1+ enables it) |
| `Confidence` | `NUMBER` | 0–100 (convention; field type does not enforce range) | `setup_project.sh` | Directive only (by convention; ignored on Execution rows) |
| `Success Signals` | `TEXT` | Free-form text; multi-line markdown allowed | `setup_project.sh` | Directive only (by convention) |

#### Iteration constraint

`gh project field-create --data-type` (as of `gh 2.50.0`) accepts only `TEXT | SINGLE_SELECT | DATE | NUMBER`. **`ITERATION` is not exposed by the CLI** — it must be created via `gh api graphql` (with a multi-step mutation flow) or manually via the GitHub UI.

v0 resolution: **script creates the six CLI-supported fields; `Iteration` is left for the user to add manually via the Project's "+ field" button.** The setup script prints a one-time hint after first-run telling users they can add an Iteration field with their preferred cadence in the GH UI (it takes ~30 seconds). The `Iteration` field is referenced by `/list-directives --iteration <name>` (PR #45) but the flag is optional — Directives without an Iteration value behave as "no cycle assigned."

GraphQL automation of the Iteration field is recorded as v1+ work, parallel to the deferred Board/Roadmap view creation (axis 9 above). Both are GraphQL-only operations that drift independently of the `gh project` CLI; both are gated behind the same v1+ trigger ("real friction surfaces from real v0 use").

### Project ownership and naming

- **Owner**: same as the target repo's owner (user or org). Resolved at script invocation time via `gh repo view --json owner`.
- **Name**: `<repo-name> roadmap` by default; override via `CLAUDE_ENG_PROJECT_NAME` env var.
- **Linkage**: linked back to the target repo via `gh project link` so the Project surfaces in the repo's Projects tab.

### Views

Default Layout (Table) is auto-created by `gh project create` and is sufficient for v0. Board / Roadmap layouts are **deferred to user-customizable post-setup** — `gh project` lacks view-management subcommands, and the GraphQL alternative drifts independently of the CLI. The setup script prints a one-time hint after first-run telling users they can add views via the GH UI in two clicks.

### Idempotency

The script is idempotent at **two layers**: field existence AND SINGLE_SELECT option-set correctness. For field existence, it queries existing fields via `gh project field-list`, parses with `jq`, and only invokes `gh project field-create` for missing fields. For SINGLE_SELECT options (`Type`, `Status`, `Priority`), when the field already exists the script diffs current options against the declared set and upserts missing options via the `updateProjectV2Field` GraphQL mutation; the contract is **additive**: user-added options outside the declared set are preserved (never removed). This second layer was added by issue #76 — GitHub auto-creates a default `Status` field with `Todo / In Progress / Done` on every new Project v2, so without option reconciliation the script's `field 'Status' exists — skipped` log line silently bypassed the dir-mode option set. Per-field decisions (`created` vs `skipped` vs `reconciled`) are audit-logged as category `project-setup`. Re-running against a fully-populated, option-aligned Project produces ≥6 `skipped` audit lines (the six CLI-supported fields) and exits 0. The `Iteration` field is reported separately in the post-run hint — its presence is checked but never auto-created.

## Alternatives considered

### Per-field type choices

1. **`Priority` as `NUMBER` (e.g., 1–100) vs `SINGLE_SELECT` (P0–P3).** Chose SINGLE_SELECT — UI-inspectable per ADR-0001 constraint, implicit sort order from the option list, no "Priority=37 — what does that mean?" cognitive load. NUMBER would allow finer ranking but v0 has no sub-bucket consumer. Migration path is open: Projects v2 supports field type conversion on empty fields, and a future SINGLE_SELECT → NUMBER conversion would only need a one-time UI step plus an ADR update.

2. **`Parent` as a native GitHub Issue link vs `TEXT`.** Projects v2 has no first-class "parent issue" relation as of 2026-05. The TEXT field stores `#N` strings parseable by a stable regex (`^Parent Directive: #(\d+)$` on issue bodies; raw `#N` in the Project field). When GitHub ships a native relation, this ADR will need a successor.

3. **`Confidence` as `NUMBER` vs `SINGLE_SELECT` (low/medium/high).** Chose NUMBER — gives Directive authors finer expressiveness (35 vs 60 vs 85 carries information that low/medium/high collapses). The directive-reviewer subagent (PR #44, SPEC §4.9) does not consume `Confidence` mechanically in v0 — it's documentation for the human / future roadmap-reviewer.

4. **`Confidence` and `Success Signals` Directive-only via custom-field-scoping vs convention.** Projects v2 has no per-row field visibility. Both fields exist on every row; the convention is that Execution rows ignore them. Documented here rather than enforced — a future improvement could add a hook check that flags non-empty `Confidence` on an Execution row, but it's not v0 scope.

### Substrate choices

5. **Projects v2 vs a flat file in the target repo (`.claude/state/directives.json`).** Chose Projects v2 — preserves the ADR-0001 commitment to "human can read on github.com without our shell installed." A flat file would be simpler but breaks the UI-inspectability constraint and requires a parallel SSOT for the same data.

6. **Projects v2 vs custom database / external service.** Same rejection as #5 plus the gh-only constraint from ADR-0001.

### Naming choices

7. **Project name fixed (`claude-eng-shell roadmap`) vs `<repo-name> roadmap` + env override.** Chose the dynamic form — fixed names collide across multiple targets owned by the same user/org. Env override (`CLAUDE_ENG_PROJECT_NAME`) covers the rare case where the owner already has a Project with that name from another tool.

### Idempotency strategy

8. **Query-first via `field-list` + `jq` vs try-create-and-ignore-already-exists.** Chose query-first — produces clean per-field audit decisions, resilient to `gh` stderr-wording drift, matches the diff reviewers will scan when debugging schema drift.

### View management

9. **GraphQL view creation via `gh api graphql` vs default-Table-only + manual instructions.** Chose default-Table — GraphQL adds an untested-by-`gh` API surface that drifts independently. Default Table is auto-created and functionally sufficient; Board/Roadmap are convenience-only and trivial for the user to add via UI. ADR records the GraphQL escape hatch for v1+ if real friction surfaces.

## Consequences

**Positive**:
- **One ADR, one schema-frozen moment.** Future maintainers reading this file know exactly what shape the substrate has and why each field is the type it is.
- **UI-inspectability preserved.** Every field choice was made with "can a human read this on github.com" in mind.
- **Idempotent setup.** Re-running `setup_project.sh` is safe — useful when adding new fields in a future schema-bump PR.
- **Migration paths preserved** where reasonable (Priority SINGLE_SELECT → NUMBER on empty fields; Parent TEXT → native-relation when GitHub ships one).

**Negative**:
- **Manual view setup** required for Board/Roadmap (axis 9). User-visible friction that v1+ may close via GraphQL.
- **`Confidence` and `Success Signals` populated on all rows** (axis 4). Cosmetic noise on Execution rows; not load-bearing.
- **`Parent` as TEXT** prevents Projects v2 from rendering the parent-child relationship as a first-class connection (axis 2). Cross-references work via issue body markers (`Parent Directive: #N`) instead.

**Neutral**:
- **`Iteration` default cadence** (2-week / Monday-start) is editable via UI without breaking field references; teams with different cadences customize once at setup.
- **`gh project` CLI maturity** (`gh project field-create --single-select-option …`) has changed syntactically across minor `gh` releases. The setup script pins a minimum `gh` version in its precheck.

## Notes

- **Tracking issue**: [#41](https://github.com/ilgyu-yi/claude-eng-shell/issues/41).
- **Implementation issue**: [#43](https://github.com/ilgyu-yi/claude-eng-shell/issues/43).
- **Predecessor ADR**: [`0001-v0-director-mode-decisions.md`](0001-v0-director-mode-decisions.md) — locks the six core decisions this ADR builds on.
- **AC #6 amendment**: the issue body's AC #6 ("ensure 3 views exist") is reframed by this ADR to "default Table view suffices for v0; Board/Roadmap are user-customizable." The closing PR ticks AC #6 with this reframing.
- **Minimum `gh` version**: pinned in `scripts/setup_project.sh` precheck. As of writing: `2.40` (the version that stabilized `gh project field-create` flag syntax).
- **Audit category**: all setup events use `project-setup` (per SPEC §6.1 fail-policy convention).
- **Smoke**: `scripts/test/smoke.sh` §41 mocks `gh` via `PATH`-overlay and asserts the four edges (first-run creates, second-run skips, unregistered-path refuses, no-auth refuses).
