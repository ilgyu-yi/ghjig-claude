# MISSION — claude-eng-shell

> Canonical long-term direction for claude-eng-shell.
> Every Directive's `## MISSION fit` field references a section of this file.

## What this exists for

claude-eng-shell is the engineering scaffold a single Claude Code agent (or human + Claude pair) lives inside to do work on a GitHub-standard repository. It captures the procedural discipline of senior engineering — issue → branch → draft PR → reviewed commits → ready merge — and renders it as hooks, slash commands, subagents, and audit trails that an AI agent cannot drift past without leaving evidence.

## The mechanism

The mechanism behind this discipline is **context narrowing.** An AI agent's output quality is bounded by the size and relevance of its working context; free-form sessions accumulate noise and drift, and degrade as their windows fill with material irrelevant to the next decision. Every shell mechanism — Doc → Test → Code phasing, subagent isolation, GitHub artifacts as durable memory, hooks-as-environment, reviewers judging from artifacts not conversations — pushes the active context at any moment toward "as small and relevant as possible." Design choices that *grow* context (long-running conversations, shared subagent windows, reviewers primed by discussion, single-shot do-the-whole-task prompts) work against the mechanism even when they look quality-improving in isolation.

The mechanism cuts two ways: **narrowing** pushes irrelevant material out (phasing, subagent isolation, artifact-only reviewers), and **selective injection** pulls relevant material in from durable memory on demand (targeted reads, SessionStart re-injection, the Plan as a task-scoped manifest). The two halves are dual — narrowing alone starves the agent (hallucination from absence); injection alone distracts it (relevant signal lost in noise, per the *Lost in the Middle* and irrelevant-context-distraction lines of empirical work). Task-scoped artifacts (PR bodies, branch state, `.claude/state/`) follow *active → archived*, not *active → deleted*: the active surface contracts at task end but the artifact persists in durable memory for selective re-injection.

Directives should be evaluated against this two-sided principle, not against abstract quality — a proposal that bloats context past the task is regression, but so is a proposal that strips context-loading past the task. Both failure modes are well-documented; both are equally costly.

## Success looks like

Twelve months out, the shell's success is best summarized as **a Claude Code session running in `unattended` mode against a real engineering issue produces a merged PR whose quality matches what a careful senior engineer would have produced in the same hours.** That requires:

- **The flow holds in unattended runs.** Clean execution end-to-end (issue → branch → Doc → Test → Code → /ship → merge) is the dominant path, not the exception. Hard blockers (incompatible plan, secret detected, AC unticked) surface as audit-logged `parked` states rather than silent regressions.
- **The directing layer works.** A team that picks up claude-eng-shell uses the dir-mode hierarchy (`MISSION.md` → Directive Issue → Execution Issue) to plan two or three weeks of work, ship it under reviewer gates, and reach the Directive's success signals without revising the shell. claude-eng-shell itself is the first concrete example.
- **Multiple repos run on it.** At least two unrelated upstream repos — beyond claude-eng-shell itself — adopt the shell as their canonical Claude Code workflow. Each contributes friction back into the SPEC.
- **The escape hatch stays narrow.** Audit-log queries (`/audit`) show that bypasses (`SKIP_HOOKS=...`) cluster in the small set of legitimate cases the SPEC names — not as a normalized routing around inconvenient gates.
- **The v1+ orchestrator lands.** Automatic mode-switching between eng-mode and dir-mode, kill-switches, and budget controls (SPEC §0.4) ship after v0 operating experience surfaces the right design for them.

## Consuming Initiatives

Direction usually enters the shell as a MISSION section that a Directive references directly. But a team may also commit to a strategic **Initiative** — a bundle of related direction worth reviewing and evolving in its own right — one planning tier above any single Directive. An Initiative arrives from **outside the shell** (written by a person or emitted by a planning tool; the origin is immaterial), and eng-shell **consumes** it: it extracts Directives from the Initiative and executes them, but never authors, edits, rejects, or retires the Initiative itself.

This is the boundary the shell already holds — *it owns the how, not the what and why* — applied one tier higher. eng-shell is the layer that knows the code, and precisely for that reason it is the wrong layer to set top-level strategic direction, where code knowledge would bias the judgment. What keeps the boundary crisp is a single contract: **an Initiative must carry a termination condition evaluable without knowledge of the code.** That condition is what eng-shell works backward from to extract Directives; one that secretly needs code knowledge to assess is not an Initiative yet but execution detail in disguise, and the shell surfaces it back upstream rather than guessing.

Findings flow upward — comments, a *challenge* when execution reality contradicts the Initiative, a completion signal when the extracted work lands — carrying code-derived information (real dependencies, measurability, cost) the planning layer structurally cannot have. But the shell escalates; it does not decide: discarding a strategic commitment is itself a strategic judgment, and that stays upstream. This **generalizes** the directing layer rather than replacing it — a Directive's parent may be a MISSION section *or* an Initiative, and every existing MISSION-parented Directive remains valid (SPEC §1.7).

## Who this is for

The primary user is **a person running Claude Code on a GitHub-standard repository who wants the AI to operate at engineering discipline they themselves would apply.** That person might be:

- A solo engineer using Claude Code to extend a project they own.
- An engineer at a small team standardizing Claude Code workflows so the AI's output is reviewable on the same axes as a human teammate's PRs.
- An engineer running Claude Code overnight (`unattended` mode) against well-scoped issues, expecting wake-up to find quality-controlled merged PRs or audit-logged blockers — not silent half-finished work.

Secondary users include teams adopting AI-assisted engineering more broadly, who can fork the shell, replace the subagent definitions, and keep the rest of the GitHub-standard scaffolding intact.

## Explicitly NOT goals

- **Not a general dotfiles or shell-customization framework.** The shell is scoped to GitHub-standard engineering workflows. Personal shell preferences, prompt customization, and UI theming are out of scope.
- **Not a replacement for engineering judgment.** Every hook has an escape; every reviewer subagent surfaces verdicts humans can override; the directing layer never autonomously decides direction (SPEC §1.7). The shell exists to *catch mistakes* and *enforce discipline*, not to be smart on its own.
- **Not an AI orchestrator for arbitrary tasks.** It's specifically a *Claude Code on GitHub* shell. Multi-agent orchestrators, general AI workflow managers, custom RAG systems are different products.
- **Not the target repo's MISSION or SPEC.** The shell never owns the *what* and *why* of the user's project — that lives in the target repo's `MISSION.md` / `SPEC.md`. The shell owns the *how*.
- **Not an author of Initiatives.** A strategic Initiative — the planning tier above a Directive — arrives from upstream; the shell consumes it and extracts Directives from it, but never writes, edits, rejects, or retires one. Challenging an Initiative escalates a code-derived finding upward; it does not decide the Initiative's fate (see *Consuming Initiatives*; SPEC §1.7).
- **Not a drop-in for non-GitHub workflows.** GitLab, Forgejo, Bitbucket, and bare-git workflows are out of scope. The shell's hooks reference `gh` everywhere; porting belongs to a fork or a future Directive far beyond v0.

## Stakeholders

- **Author**: ilgyu-yi (primary engineer + dogfooder).
- **Future users**: any engineer adopting claude-eng-shell as their Claude Code workflow.
- **AI agents**: the shell is the operating environment Claude Code reads from; the SPEC is the contract Claude Code is held to.

---

*Last reviewed: 2026-05-28.*
