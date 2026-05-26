# MISSION — claude-eng-shell

> Canonical long-term direction for claude-eng-shell.
> Per dir-mode v3 reframe ([ADR-0003](docs/ADRs/0003-issues-ssot-substrate.md) Decision 6), this document supersedes the v0/v1 Goal-as-Item artifact. Every Directive's `## MISSION fit` field references a section of this file.

## What this exists for

claude-eng-shell is the engineering scaffold a single Claude Code agent (or human + Claude pair) lives inside to do work on a GitHub-standard repository. It captures the procedural discipline of senior engineering — issue → branch → draft PR → reviewed commits → ready merge — and renders it as hooks, slash commands, subagents, and audit trails that an AI agent cannot drift past without leaving evidence.

## Success looks like

Twelve months out, the shell's success is best summarized as **a Claude Code session running in `unattended` mode against a real engineering issue produces a merged PR whose quality matches what a careful senior engineer would have produced in the same hours.** That requires:

- **The flow holds in unattended runs.** Clean execution end-to-end (issue → branch → Doc → Test → Code → /ship → merge) is the dominant path, not the exception. Hard blockers (incompatible plan, secret detected, AC unticked) surface as audit-logged `parked` states rather than silent regressions.
- **The directing layer works.** A team that picks up claude-eng-shell uses the dir-mode hierarchy (Goal → Directive → Execution Issue) to plan two or three weeks of work, ship it under reviewer gates, and reach the Directive's success signals without revising the shell. This Goal Item is the first concrete example.
- **Multiple repos run on it.** At least two unrelated upstream repos — beyond claude-eng-shell itself — adopt the shell as their canonical Claude Code workflow. Each contributes friction back into the SPEC.
- **The escape hatch stays narrow.** Audit-log queries (`/audit`) show that bypasses (`SKIP_HOOKS=...`) cluster in the small set of legitimate cases the SPEC names — not as a normalized routing around inconvenient gates.
- **The v1+ orchestrator lands.** Automatic mode-switching between eng-mode and dir-mode, kill-switches, and budget controls (SPEC §0.4) ship after v0 operating experience surfaces the right design for them.

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
- **Not a drop-in for non-GitHub workflows.** GitLab, Forgejo, Bitbucket, and bare-git workflows are out of scope. The shell's hooks reference `gh` everywhere; porting belongs to a fork or a future Directive far beyond v0.

## Stakeholders

- **Author**: ilgyu-yi (primary engineer + dogfooder).
- **Future users**: any engineer adopting claude-eng-shell as their Claude Code workflow.
- **AI agents**: the shell is the operating environment Claude Code reads from; the SPEC is the contract Claude Code is held to.

## Last reviewed: 2026-05-25


---

*Last reviewed: 2026-05-26. Updated by Directive #92 cluster I migration (transcribed from PVTI #84, the v0/v1 Goal Item that this MISSION.md supersedes).*
