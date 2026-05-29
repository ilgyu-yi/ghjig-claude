# Troubleshooting

Common blocks and how to resolve them.

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| `Not a valid Conventional Commit` | Missing `(#N)` on `feat`/`fix`/`docs`/`refactor`/`perf`, or a typo'd type | Use `<type>(#<N>)[!]: <≤72 chars>`. `chore` and other optional types may omit `(#N)`. |
| `Subject length out of codepoint range 1..72` | Subject is empty or longer than 72 codepoints | Shorten. Detail goes in the body. |
| `commit on protected branch blocked` | Direct commit on main/master/release/* | Create a feature branch via `/work-on <issue#>`. |
| `force push blocked` | Used `--force`/`-f`/`--force-with-lease` | Plain `git push` where possible. If truly needed: `SKIP_HOOKS=force-push SKIP_REASON='...'`. |
| `--amend of an already-pushed commit blocked` | Amending a commit that's already on upstream | Make a new commit (`git commit -m`). History rewriting is a separate procedure. |
| `<file>:<line>: <pattern-id>` followed by `Possible secret pattern detected` | API key / PAT / similar in staged diff. The marker line gives the exact location; pattern-id (`aws-akia`, `gh-pat-classic`, etc.) names the matched rule | If real secret: remove and audit history. Legitimate doc/test fixture: add the path to `.shellsecretignore` at the target-repo root (gitignore-narrow globs; read from `HEAD`, so a new entry needs its own commit before the work it covers). Last resort: `SKIP_HOOKS=secret SKIP_REASON='...'`. |
| `sensitive file edit blocked` | Editing `.env`/`*.pem`/`credentials*` | These usually shouldn't be git-tracked. If truly needed, escape. |
| `edit outside registry blocked` | Edit/Write target is outside a registered path | (1) Verify the target is what you intended. (2) The shell deliberately stays within registered paths. For genuine outside work, escape. |
| Hook seems inactive | Current cwd isn't registered (check `.claude/state/registry.txt`) | Register with `scripts/register.sh <path>`. If you're working on the shell repo itself, re-run `scripts/bootstrap.sh` — it self-registers (§3.6). |
| `[claude-eng-shell] WARN inject-consistency: ...` (stderr at session start) | Workspace has `.claude/settings.local.json` as a shell-injected symlink, but the session launched via plain `claude` so `CLAUDE_ENG_SHELL_ROOT` is unset → every hook silently no-ops | Exit and relaunch with `claude-eng`, or `export CLAUDE_ENG_SHELL_ROOT=<path-to-shell-repo>` and restart. SPEC §6.5(c). |
| `linked issue has unchecked AC and no '## AC closeout' marker comment` (on `gh pr merge`) | The PR's `closingIssuesReferences` includes an issue whose body has `- [ ]` items and no comment whose first line is `## AC closeout`. Without the comment, the issue auto-closes with its AC list reading as "nothing was done" — SPEC §1.4 violation. | Run `scripts/ac_closeout.sh <pr-num>` — idempotent; posts the canonical closeout comment on every linked issue that needs one. `/ship` step 7.6 invokes it automatically. For emergencies or no-AC issues: `SKIP_HOOKS=ac-closeout SKIP_REASON='<why>'` (audit-logged). |
| `claude-eng` not found | PATH not set | `export PATH="$SHELL_ROOT/bin:$PATH"` or alias. Editing `~/.zshrc` is your call. |
| `branching from a Directive Issue is blocked — use /activate-directive (Proposed) or /file-issue --parent (Active)` (on `git checkout -b <user>/<type>/<N>-<slug>`) | `directive-protect` hook matcher caught `<N>` as a Directive. Directives are gated by `/complete-directive` + `activation-reviewer`, not by engineering-flow `Closes #N` semantics. See SPEC §1.7 / §6.1 type-aware engineering hooks. | If `<N>` is Proposed: run `/activate-directive <N>` first. If Active: file an Execution Issue under it via `/file-issue --parent <N>` and `/work-on` the new Issue. Last resort: `SKIP_HOOKS=directive-protect SKIP_REASON='<why>'`. |
| `closing a trusted-filer Issue without --reason completed is blocked` OR `removing the directive label is blocked — declassifies the Directive` (on `gh issue close` or `gh issue edit --remove-label directive`) | `trusted-filer-mutate` hook matcher (SPEC §1.5) caught a mutation that would either declassify a Directive or auto-close-as-not-planned a trusted-filer Issue. Mode-independent — fires under both `attended` and `unattended`. | For Directive completion: use `/complete-directive <N>` (which closes with `--reason completed` after `activation-reviewer` evidence pass). For declassification: human confirm required — re-run with `SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='maintainer reclassifying #<N> as Execution Issue'`. |
| `activation-reviewer block: <reason>` (on `/file-directive`, `/activate-directive`, `/complete-directive`, `/revise-directive`) | The Directive body or completion evidence failed one of five reviewer checks (schema completeness, success-signal verifiability, scope clarity, non-goal clarity, active-Directive conflict; completion adds evidence sufficiency). See SPEC §4.9.1. In `attended` mode the verdict surfaces; in `unattended` the work parks. | Address the reviewer's `<reason>` and re-run the command. For a wrongly-blocked Directive where you accept the responsibility: `SKIP_HOOKS=directive-review SKIP_REASON='<why>'` (audit-logged). Parked filings live in `.claude/state/directive-block.log`. |
| `target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first` (on any `/*-directive` command) | The target repo doesn't carry the dir-mode label set. The 7 dir-mode commands carry an idempotent substrate-preflight that aborts when `gh label list \| grep -qx directive` returns nothing. Fail-open on `gh` network errors per SPEC §1.7 reversibility framing. | Run `/onboard-dir-mode --tier 2` (or `--tier 3`) to install the substrate via a PR to the target. Confirm with `gh label list \| grep '^directive'`. If you're certain the substrate is present and the check is wrong (e.g., `gh` is down): `SKIP_HOOKS=substrate-preflight SKIP_REASON='gh outage'`. |

## Reading the audit log

```bash
cat .claude/audit/audit.jsonl | tail -50
# or from inside Claude: /audit force-push
```

Repeated escapes in the same category mean the hook needs tuning.
