# ADR 0003: Issues-as-SSOT substrate (dir-mode v3 reframe)

- Date: 2026-05-26
- Status: Accepted
- Context PR: (this PR — cluster J1 of Directive #92)
- Supersedes: ADR-0002 substantively; ADR-0001 partially (Goal-as-substrate-item portion)

## Context

dir-mode v0 (locked by ADR-0001 + ADR-0002, 2026-05-24) placed the Goal / Directive / Execution triad on a GitHub Projects v2 substrate with seven custom fields. Two days of operation surfaced a class of friction that is **structural**, not incidental:

1. **Owner-scoped substrate vs repo-level state.** Project v2 is owned by a user or org; not all repo collaborators have Project access. Storing `Status` / `Type` / `Priority` / `Parent` on Project fields means write access is non-uniform with repo access — a blocker for multi-developer OSS adoption (Directive #84 Goal Item criterion #3 names exactly this case).
2. **Dual-recording sync drift.** Multiple concepts existed in both label and field form (`Type=Directive` field ↔ `directive` label, `Parent` field ↔ body marker, `Success Signals` field ↔ body section). Different consumers (hooks, `/list-directives`, `/reflect`, dir-mode-post-merge workflow) read from different sources, creating silent drift surface.
3. **Filing-time ceremony.** `/file-directive` ran a substantive `directive-reviewer` at filing time AND required Project write access. Foreign to OSS norms where Issues are the open proposal channel and maintainer triage is the gate. External contributors couldn't propose Directives without Project access.
4. **`Goal` artifact duplicating `MISSION.md`.** PVTI #84 (the Final Goal Item) carried 5-section MISSION.md content in PVTI form. Two representations for one concept; the doc-as-code `MISSION.md` is authoritative.
5. **`Revised` state had no SSOT.** Specified as "transient — flip Status briefly, return to Active" (SPEC §5.16). The state of being-in-revision could not be expressed in any persistent SSOT.

The remediation pattern that emerged through directional review (2026-05-26, recorded in the dir-mode v3 brief at `/tmp/dir-mode-v3/brief.md` and in Directive #92's body): **make Issues the SSOT for all repo-level concepts**, keep Project as a single-direction-mirrored derived view, eliminate the `Goal` artifact, drop the `Revised` state, adopt file-first / triage-later, and add a filer-aware invariant layer that's independent of the attended/unattended mode axis.

## Decision

The dir-mode substrate moves to **Issues-as-SSOT**, with Project v2 retained as a derived view. The eight specific decisions locked here:

### 1. ADR-0003 fully supersedes ADR-0002's substrate decisions in one step

No phased migration. Friction is structural; phasing leaves the worst sync surface in place during the transition. The v3 reframe lands as a coordinated set of PRs across clusters A–J (per Directive #92).

### 2. `/file-directive` retains its filing-time substantive reviewer gate

Maintainer self-discipline floor preserved. The substantive review at filing prevents low-quality Directive proposals from polluting the queue. The lighter `triage-reviewer` (cluster B) handles binary classification at `/triage`, not substance.

### 3. `/triage` skill ships with templates as one atomic first-release

Cluster A (Issue templates) and cluster B (`/triage` skill) ship in the same release window. Templates without `/triage` means no maintainer review path; `/triage` without templates means no structured input for the classifier. The two halves are mutually load-bearing.

### 4. Mis-template usage is handled by strict reject + refile (NOT relabel)

Single data-integrity invariant: every open Issue matches its template; no label/body mismatch ever survives. When `/triage` rejects, the original Issue closes-as-not-planned and the maintainer manually refiles in the correct template. AI does NOT autonomously refile (per §6 filer-aware invariants + the directive brief's §10 non-goal #8). The original body may be reused; only the template envelope is replaced.

### 5. `Iteration` lives on Project (owner cadence); `Milestone` lives on Issues (repo deliverable grouping)

These are different concepts, not competitors for one slot. `Iteration` is owner-level (user-managed via the GH UI, 2-week cycles by default); `Milestone` is GitHub-native, repo-level, and aligns with release / deliverable grouping. The mirror workflow (cluster D) does NOT mirror Iteration — it's user-managed; mirroring it would conflate scope.

### 6. `Goal` artifact eliminated. `MISSION.md` is the canonical repo direction

The five-section MISSION.md format (What this exists for / Success looks like / Who this is for / Explicitly NOT goals / Stakeholders) is the canonical long-term anchor. `Directive` bodies reference MISSION sections; `directive-reviewer` checks alignment with MISSION instead of with a separate `Goal` Item. PVTI #84 (the only `Type=Goal` Item) is snapshotted and deleted by cluster I's migration; its content has been transcribed into `MISSION.md` (verified before deletion).

The "early v0 state" Goal-bootstrap allowance in `directive-reviewer.md` line 91 is removed for this repo specifically; it stays valid for other target repos onboarding the shell whose first Directive precedes their first `MISSION.md`.

### 7. Directive Status reduced to 4 states: `Proposed / Active / Blocked / Completed`

`Revised` is dropped. `/revise-directive` emits an audit-log entry (`directive-revise reconciled`) and archives the prior body as a comment, but does NOT flip Status — the body revision IS the durable evidence, no transient state needed. The mirror workflow recognizes 4 Status values, not 5.

### 8. Migration via snapshot + delete of existing PVTI items, restart fresh

Repo has minimal dir-mode data: PVTI #84 (the Goal Item) plus possibly a few Directives that activated against Project #2 substrate. A snapshot under `.claude/state/v2-snapshot/<ISO>/` preserves history; the PVTI items are then deleted from Project #2. The Project is reset to empty state; new mirrored entries appear via the cluster D workflow.

No legacy-compatibility mode. New flows from PR merge date; old flows decommissioned. This is a one-time event executed as part of cluster I's PR.

## Alternatives considered

### A1. Phased migration: keep some fields on Project, move others to labels

Rejected. Phasing leaves the worst sync-surface bug (dual-recording label vs field) in place during the transition. The cost of running both stores in parallel is higher than the cost of the one-time migration.

### A2. Bidirectional sync (Project edits propagate back to Issues)

Rejected per Directive #92 brief §10 non-goal #5. Project is derived; edits drift on the next mirror event. Two-way sync requires conflict resolution (which side wins?) that would either (a) silently lose Project edits — surprising — or (b) overwrite Issue state — defeats Issues-as-SSOT. One-way mirror with documented "Project is derived" is cleaner.

### A3. Keep `Goal` as a separate Issue type (Type=Goal label on a real Issue)

Rejected per Decision 6. `MISSION.md` is doc-as-code and authoritative for the repo's long-term direction. Duplicating the canonical direction into an Issue creates two representations; revising one without the other surfaces drift. `directive-reviewer` checking `MISSION.md` directly is structurally simpler.

### A4. AI-driven autonomous refile in unattended mode

Rejected per Decision 4 + §6 filer-aware invariants + brief §10 non-goal #8. Auto-refiling in unattended mode would mean AI files Issues on behalf of users — a higher-stakes action than the substantive-review unattended escape (which only halts at PR-ready, doesn't create new artifacts). Acceptable degraded behavior: unattended `/triage` REJECT halts the queue; the maintainer's next session resumes.

### A5. Cross-repo Directive graph (Directive in repo A references Directive in repo B)

Deferred to v1+ per brief §10 non-goal #1. v0 v3 keeps Directives repo-scoped. Owner-level strategic anchors beyond MISSION.md are out of scope.

### A6. Per-label ACL via custom workflows

Deferred per brief §10 non-goal #4. GitHub native role-based label permissions suffice for v0; a maintainers-allowlist Action is v1+ if real abuse surfaces.

### A7. `Goal` as a deliberation-shaped Directive

Considered (this is essentially how Directive #84 worked — Directive that authored a Goal Item). Rejected for the reframe because Directive #84's only purpose was to bootstrap the Goal Item; once `MISSION.md` becomes the canonical direction, Directives reference its sections directly rather than instantiating a separate Goal artifact. The Directive shape is preserved for actual deliberation-shaped work (Directive #92 itself is a Directive that authors this ADR + the substrate flip).

## Consequences

**Positive**:
- **Collaboration-safe substrate.** Repo collaborators can read/write all dir-mode state via Issues, regardless of Project access. Multi-developer OSS adoption unblocked.
- **No sync drift surface.** Each concept has one SSOT: Issues for state, MISSION.md for direction. Hooks, commands, and workflows all read from the same source.
- **OSS-standard filing.** External contributors propose Directives via the `directive-proposal.yml` Issue Form; maintainer triages via `/triage`. Matches the broader Issue-template ecosystem.
- **Project preserved as cross-repo dashboard.** Project remains a first-class personal / team UI for cross-repo iteration planning, without being load-bearing for any single repo's state.
- **Goal-bootstrap retired for this repo.** Future Directives reference `MISSION.md` sections directly, not a placeholder `(no Goal item yet)` text.
- **`/revise-directive` simplified.** No transient state to manage; the audit-log + archive-comment ARE the revision evidence.

**Negative**:
- **Migration is destructive.** Snapshot + delete of PVTI items. Reversibility is via the snapshot directory; restoration would require manual recreation. Acceptable given the minimal data set.
- **Project mutations require additional token scope.** The mirror workflow needs Project v2 mutation grants beyond `GITHUB_TOKEN`'s default `issues: write`. Maintainer must grant once, out-of-band. Documented in `issues-to-project-mirror.yml` header.
- **`directive-reviewer.md` line 91 bootstrap allowance retired for this repo.** Future Directives in *this* repo must cite a MISSION.md section; the allowance stays for other target repos onboarding the shell.
- **Filing-time ceremony stays for `/file-directive`.** External contributors using `directive-proposal.yml` skip this gate (their filing is template-validated server-side); `/file-directive` users get the substantive reviewer treatment. Two filing paths with different review timing — documented in cluster B's reviewer composition paragraph (SPEC §4.10).
- **`Type=Goal` Project option deleted.** Any external tool reading the Project's `Type` field will see only `Directive` / `Execution` options. Acceptable; no known external consumer.

**Neutral**:
- **Iteration field stays user-managed.** Cluster D mirror workflow does NOT mirror Iteration; the field remains owner-level cadence per brief Decision 5.
- **`Confidence` and `Success Signals` Project fields removed.** Content moves to Directive body sections; the Project no longer carries these. ADR-0002's per-field schema for those fields becomes informational-only.
- **One-time migration timing.** Cluster I (the migration) lands LAST per Directive #92 sequencing — after clusters E/F/G/H. Until then, the Project still carries old `Type=Goal` options and PVTI #84.

## Notes

- **Source brief**: dir-mode v3 brief authored 2026-05-26, saved at `/tmp/dir-mode-v3/brief.md` for cross-invocation reference during this session. Content also reflected in Directive #92's Issue body.
- **Predecessor ADRs**:
  - [`0001-v0-director-mode-decisions.md`](0001-v0-director-mode-decisions.md) — six core v0 decisions; the Goal-as-substrate-item portion is superseded by this ADR.
  - [`0002-directive-project-field-schema.md`](0002-directive-project-field-schema.md) — per-field schema for the v0 Project substrate; substantively superseded by this ADR.
- **Implementation tracking**: Directive #92 (`directive: dir-mode v3 reframe — Issues-as-SSOT substrate (supersedes ADR-0002)`), Active in Project #2. Cluster issues #93 (cluster A), #94 (B), #95 (C), #96 (umbrella for D-J).
- **Smoke**: cluster A's smoke section is §54 (#93); cluster C is §55 (#95); cluster B is §56 (#94); cluster D is §57 (#96). Subsequent clusters land their own §58+ sections.
- **Cluster J's two halves**: this ADR is cluster J1. Cluster J2 (separate PR) adds the "Superseded by ADR-0003" header note to ADR-0001 + ADR-0002. J1 + J2 together complete cluster J.
- **Filer-aware invariants** (cluster C, SPEC §1.5): the mode-independent layer added by this reframe is documented inline at SPEC §1.5; this ADR doesn't re-spec it.
- **Audit categories** added by the reframe: `triage` (cluster B), `trusted-filer-mutate` (cluster C), `mirror-stale-warn` (cluster D — reserved for v1+ monitoring; not emitted today).
