# Harness-overlap classification

Full details in [SPEC.md §1.9](../SPEC.md). This page is a thin pointer; the classification contract — every shell mechanism's posture toward the Claude Code harness — lives in SPEC, not here.

The Claude Code harness is a **rising floor**: it improves under use and steadily absorbs the generic agent-support primitives (context compaction, lazy tool loading, native subagents, plan mode, file-based memory). SPEC §1.9 records, as standing doctrine, each mechanism's posture toward that floor:

- **`cede-to-harness`** — the harness now does this natively; the shell's version is redundant (a retirement candidate; forward discipline, not deleted in place).
- **`keep-as-policy`** — opinionated GitHub-engineering policy the harness does not encode and should not, staying general.
- **`keep-as-safety-redundancy`** — a deliberately redundant backstop for a high-cost-of-wrong action, kept even where the harness offers a partial native guard.

The classification is **parity-guarded** (smoke §116): a new mechanism in §1.8 / §4 / §5 / §6.1 fails the build until it gains a posture row in SPEC §1.9.
