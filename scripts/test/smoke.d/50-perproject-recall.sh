# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after _preamble.sh (#600). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals defined there.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- 79. /file-issue priority capture (#291) ----------
# /file-issue must capture a P0-P3 priority (parity with /file-directive) so
# eng-mode issues don't land priority-less: ask in attended, default P2 in
# unattended, apply the P<N> label graceful-degradation-guarded, and state the
# contract in SPEC §5.2.
FILE_ISSUE_79="$SHELL_ROOT/.claude/commands/file-issue.md"
if [ -f "$FILE_ISSUE_79" ] \
   && grep -qiE 'priority' "$FILE_ISSUE_79" \
   && grep -qE 'P0\|P1\|P2\|P3|P0` / `P1` / `P2` / `P3|P0`/`P1`/`P2`/`P3' "$FILE_ISSUE_79" \
   && grep -qiE 'default.*\bP2\b' "$FILE_ISSUE_79" \
   && grep -qiE 'graceful-degradation|absent on target' "$FILE_ISSUE_79"; then
  ok "79a: /file-issue captures priority (P0-P3, unattended default P2, degradation-guarded) (#291)"
else
  ng "79a: /file-issue.md missing the priority-capture contract (#291)"
fi
# 79b: SPEC §5.2 documents the /file-issue priority contract.
if grep -qE '\*\*Priority\*\* \(#291' "$SHELL_ROOT/SPEC.md" \
   && grep -qiE 'never lands priority-less|priority-less backlog' "$SHELL_ROOT/SPEC.md"; then
  ok "79b: SPEC §5.2 states the /file-issue priority-capture contract (#291)"
else
  ng "79b: SPEC §5.2 missing the /file-issue priority contract (#291)"
fi

# ---------- 80. stage-0 /bootstrap-repo (#307, Directive #306) ----------
# Stage-0 bootstrap owns the no-default-branch starting state (empty repo /
# unborn HEAD). The protected-branch gate is NAME-based, so on an unborn HEAD
# (`git symbolic-ref --short HEAD` → main while `rev-parse --verify HEAD`
# fails) the seed commit is blocked — correct general behavior. /bootstrap-repo
# owns a single, scoped, audit-logged bypass for that seed commit via the
# `branch` escape. These assertions pin BOTH halves: the gate stays intact for a
# plain unborn-HEAD commit, AND the bootstrap sentinel is honored — plus the
# command file carrying the exact sentinel string (the implementation contract).

# Run the hook in an arbitrary cwd; echo its exit code (2=block, 0=allow).
s80_hook() {
  # $1 = dir, $2 = command string
  ( cd "$1" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$2" | jq -Rs .)" \
      | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1
    printf '%s' "$?" )
}

# Fresh repo with an UNBORN HEAD on `main` — no commit, so HEAD is unborn and
# `git symbolic-ref --short HEAD` reports `main` (the stage-0 starting state).
# The repo is REGISTERED (physical-resolved, like §5b): the hook short-circuits
# (`in_scope || exit 0`) outside the registry, and a real target IS registered
# (clone-into / register) before stage-0 runs — so the gate must be exercised
# inside the registry, exactly as /bootstrap-repo encounters it.
S80_REPO=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S80_REPO" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }) ) || true
printf '%s\n' "$S80_REPO" >> "$SMOKE_REG"
s80_branch=$(cd "$S80_REPO" && git symbolic-ref --short HEAD 2>/dev/null)
s80_unborn=$(cd "$S80_REPO" && git rev-parse --verify HEAD 2>/dev/null || printf 'unborn')

# 80a: fixture sanity — unborn HEAD reporting a protected name (`main`).
if [ "$s80_branch" = main ] && [ "$s80_unborn" = unborn ]; then
  ok "80a: stage-0 fixture is an unborn HEAD on protected name 'main' (#307)"
else
  ng "80a: stage-0 fixture not unborn-on-main (branch='$s80_branch' head='$s80_unborn') (#307)"
fi

# 80b: gate intact — a plain seed commit on the unborn-HEAD `main` is BLOCKED.
if [ "$(s80_hook "$S80_REPO" 'git commit -m "chore: seed first commit (MISSION + README)"')" = "2" ]; then
  ok "80b: plain unborn-HEAD commit blocked — name-based gate intact (#307)"
else
  ng "80b: plain unborn-HEAD commit should be blocked by the protected-branch gate (#307)"
fi

# 80c: bootstrap exception — the SAME commit carrying the stage-0 trailing
# sentinel is ALLOWED (and routes through should_skip, i.e. audit-logged).
s80_seed='git commit -m "chore: seed first commit (MISSION + README)"  # ghjig:skip=branch reason=stage-0-bootstrap-seed-on-unborn-HEAD'
if [ "$(s80_hook "$S80_REPO" "$s80_seed")" = "0" ]; then
  ok "80c: unborn-HEAD seed commit with bootstrap sentinel allowed (#307)"
else
  ng "80c: bootstrap-sentinel seed commit should be allowed via the branch escape (#307)"
fi

# Unregister the fixture and remove it.
s80_tmp=$(mktemp); grep -vxF "$S80_REPO" "$SMOKE_REG" > "$s80_tmp" 2>/dev/null || true
mv "$s80_tmp" "$SMOKE_REG"
rm -rf "$S80_REPO"

# 80d: the command file exists with the skill contract AND documents the EXACT
# in-agent seed-escape recipe the §5.0 contract pins. Post-#479 the working
# in-agent escape is the file token (ghjig_skip.sh), NOT the trailing sentinel
# (which the live Bash tool strips, #478) — so the pin follows the contract to
# the ghjig_skip.sh seed recipe. (§80c still proves the sentinel works where a
# command arrives verbatim — the smoke harness / a real shell.)
BOOTSTRAP_CMD="$SHELL_ROOT/.claude/commands/bootstrap-repo.md"
if [ -f "$BOOTSTRAP_CMD" ] \
   && grep -qE '^## Procedure' "$BOOTSTRAP_CMD" \
   && grep -qE '^## Forbidden' "$BOOTSTRAP_CMD" \
   && grep -qF "scripts/ghjig_skip.sh branch 'chore: seed first commit (MISSION + README)'" "$BOOTSTRAP_CMD"; then
  ok "80d: /bootstrap-repo command file carries Procedure/Forbidden + exact ghjig_skip seed recipe (#307, #479)"
else
  ng "80d: .claude/commands/bootstrap-repo.md missing skill contract or exact ghjig_skip seed recipe (#307, #479)"
fi

# 80e: SPEC §5.0 defines stage-0 as preceding /onboard and names the exception,
# AND is cross-referenced from BOTH §1.7 (bootstrap path) and §5.1 (/onboard) —
# AC #2 of #307 requires both back-references, not just §5.0's existence.
if grep -qE '^### 5\.0 `/bootstrap-repo`' "$SHELL_ROOT/SPEC.md" \
   && grep -qiE 'stage-0' "$SHELL_ROOT/SPEC.md" \
   && grep -qiE 'bootstrap exception \(target repos\)|first-commit exception.*target|target.*first-commit exception' "$SHELL_ROOT/SPEC.md" \
   && grep -qE 'Stage-0 precedes all of this|stage-0.*§5\.0|/bootstrap-repo \(§5\.0\)' "$SHELL_ROOT/SPEC.md" \
   && grep -qE 'Precedes.*`/bootstrap-repo` \(§5\.0\)|Precedes.*stage-0' "$SHELL_ROOT/SPEC.md"; then
  ok "80e: SPEC §5.0 defines stage-0 + target exception + §1.7/§5.1 cross-refs (#307)"
else
  ng "80e: SPEC §5.0 must define stage-0, the target exception, and be cross-ref'd from §1.7 + §5.1 (#307)"
fi

# 80f: .claude/CLAUDE.md documents the stage-0 exception, and the seed README
# template SSOT exists.
if grep -qiE 'stage-0 exception' "$SHELL_ROOT/.claude/CLAUDE.md" \
   && [ -f "$SHELL_ROOT/.claude/templates/readme_for_target.md" ]; then
  ok "80f: CLAUDE.md documents stage-0 exception + readme_for_target.md template present (#307)"
else
  ng "80f: CLAUDE.md stage-0 exception note or readme_for_target.md template missing (#307)"
fi

# 80g: /onboard stays read-only — no mutating git/gh-write command introduced.
ONBOARD_CMD="$SHELL_ROOT/.claude/commands/onboard.md"
if [ -f "$ONBOARD_CMD" ] \
   && ! grep -qE 'gh (issue|pr) create|git (commit|push|checkout -b)|gh label create' "$ONBOARD_CMD"; then
  ok "80g: /onboard remains read-only (no mutating command) (#307)"
else
  ng "80g: /onboard.md must stay read-only — no mutating command (#307)"
fi

# ---------- 81. workflow YAML loadability (#309) ----------
# A workflow file that fails to PARSE startup-fails on GitHub — every job is
# skipped, the run name shows the file path instead of the declared `name:`,
# and it fires on the raw push event regardless of `on:`. Such a failure is
# invisible unless the workflow is a required check. #309's root cause was a
# bash heredoc whose `EOF` terminator sat at column 0, dedenting out of the
# `run: |` block scalar and breaking YAML for the whole file. This regression
# parses EVERY workflow so a future block-scalar break is caught pre-merge.

# Parse one YAML file. rc 0 = parses, 1 = parse error, 2 = no parser available.
s81_yaml_ok() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
    return $?
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$1" >/dev/null 2>&1
    return $?
  fi
  return 2
}

s81_parser=skip
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  s81_parser=python3
elif command -v ruby >/dev/null 2>&1; then
  s81_parser=ruby
fi

if [ "$s81_parser" = skip ]; then
  # No YAML parser in this environment — the GitHub CI run is the backstop.
  ok "81a: workflow-YAML parse regression skipped — no python3-yaml/ruby parser here (#309)"
else
  s81_bad=""
  for wf in "$SHELL_ROOT"/.github/workflows/*.yml "$SHELL_ROOT"/.github/workflows/*.yaml; do
    [ -e "$wf" ] || continue
    if ! s81_yaml_ok "$wf"; then
      s81_bad="$s81_bad $(basename "$wf")"
    fi
  done
  if [ -z "$s81_bad" ]; then
    ok "81a: every .github/workflows/*.yml parses as YAML (parser=$s81_parser) (#309)"
  else
    ng "81a: workflow YAML failed to parse —$s81_bad (parser=$s81_parser) (#309)"
  fi
fi

# ---------- 82. per-project binding + hook self-location (#312, Directive #311) ----------
# The shell must be resolvable per project WITHOUT any global shell-root
# env: a project-local untracked `.claude/ghjig-root` symlink → canonical root,
# hooks invoked via that symlink self-locate their root from BASH_SOURCE (pwd -P),
# and the injected `settings.local.json` symlinks to `settings.injected.json` whose
# hook commands use ${CLAUDE_PROJECT_DIR}/.claude/ghjig-root/... . The shell's
# OWN settings.json resolves via ${CLAUDE_PROJECT_DIR} (dogfood, §133b).

# 82a: with no shell-root env at all, a hook invoked through the project-local
# ghjig-root symlink self-locates the canonical root and still enforces —
# a protected-branch commit is blocked (rc=2). (Red until the self-location code.)
S82_PROJ=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S82_PROJ" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }) \
    && git commit -q --allow-empty -m init 2>/dev/null ) || true
mkdir -p "$S82_PROJ/.claude"
ln -sfn "$SHELL_ROOT" "$S82_PROJ/.claude/ghjig-root"
printf '%s\n' "$S82_PROJ" >> "$SMOKE_REG"   # in_scope needs it registered

s82_hook_noenv() {
  # $1 = project cwd, $2 = hook path (via the symlink), $3 = command ; echoes rc
  ( cd "$1" || exit 1
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$3" | jq -Rs .)" \
      | env -u GHJIG_ROOT_OVERRIDE -u GHJIG_ROOT bash "$2" >/dev/null 2>&1
    printf '%s' "$?" )
}
s82_rc=$(s82_hook_noenv "$S82_PROJ" "$S82_PROJ/.claude/ghjig-root/.claude/hooks/pre_tool_use.sh" \
  'git commit -m "chore: x"')
if [ "$s82_rc" = "2" ]; then
  ok "82a: env-unset hook via ghjig-root symlink self-locates + enforces (protected commit blocked) (#312)"
else
  ng "82a: env-unset hook should self-locate via ghjig-root + block protected commit (rc=$s82_rc) (#312)"
fi

# unregister + remove the fixture
s82_tmp=$(mktemp); grep -vxF "$S82_PROJ" "$SMOKE_REG" > "$s82_tmp" 2>/dev/null || true
mv "$s82_tmp" "$SMOKE_REG"
rm -rf "$S82_PROJ"

# 82b: inject_into creates `.claude/ghjig-root` resolving to the canonical
# root, adds it to .git/info/exclude, and is idempotent (no duplicate exclude line).
S82B=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S82B" && git init -q ) || true
inject_into "$S82B" >/dev/null 2>&1
inject_into "$S82B" >/dev/null 2>&1   # second run — idempotency
s82b_link=$(cd "$S82B/.claude/ghjig-root" 2>/dev/null && pwd -P)
s82b_excl=$(grep -c '^\.claude/ghjig-root$' "$S82B/.git/info/exclude" 2>/dev/null || true)
if [ -L "$S82B/.claude/ghjig-root" ] && [ "$s82b_link" = "$SHELL_ROOT" ] && [ "$s82b_excl" = "1" ]; then
  ok "82b: inject creates ghjig-root → canonical root + idempotent .git/info/exclude (#312)"
else
  ng "82b: inject must create ghjig-root→root (got '$s82b_link') + single exclude line (got $s82b_excl) (#312)"
fi

# 82c: inject points settings.local.json at settings.injected.json (not settings.json).
s82c_tgt=$(readlink "$S82B/.claude/settings.local.json" 2>/dev/null || echo "")
if printf '%s' "$s82c_tgt" | grep -q '/\.claude/settings\.injected\.json$'; then
  ok "82c: injected settings.local.json → settings.injected.json (#312)"
else
  ng "82c: settings.local.json should symlink to settings.injected.json (got '$s82c_tgt') (#312)"
fi
rm -rf "$S82B"

# 82d: settings.injected.json exists and ALL 5 hook commands use the
# ${CLAUDE_PROJECT_DIR}/.claude/ghjig-root/.claude/hooks/ form (count-guarded to 5).
S82_INJ="$SHELL_ROOT/.claude/settings.injected.json"
s82d_n=$(grep -cE '\$\{?CLAUDE_PROJECT_DIR\}?/\.claude/ghjig-root/\.claude/hooks/' "$S82_INJ" 2>/dev/null || true)
if [ -f "$S82_INJ" ] && [ "$s82d_n" = "5" ]; then
  ok "82d: settings.injected.json routes all 5 hook commands via \$CLAUDE_PROJECT_DIR/ghjig-root (#312)"
else
  ng "82d: settings.injected.json must route 5 hook commands via \$CLAUDE_PROJECT_DIR/ghjig-root (got $s82d_n) (#312)"
fi

# 82e: dogfood guard (R1, #533 — supersedes the prior env-var-based rule from
# #312) — the shell's OWN settings.json routes all 5 hook commands via
# ${CLAUDE_PROJECT_DIR}/.claude/hooks/ DIRECTLY (project dir == shell root), with
# NO *_SHELL_ROOT env var on the hook hot path and NO ghjig-root symlink
# hop (that hop is the injected-target form, §82d). Decoupling the hot path from
# the env var is what keeps enforcement armed through an in-place rename of it.
S82_OWN="$SHELL_ROOT/.claude/settings.json"
s82e_n=$(grep -cE '\$\{?CLAUDE_PROJECT_DIR\}?/\.claude/hooks/' "$S82_OWN" 2>/dev/null || true)
# The ghjig-root/_SHELL_ROOT bans are about the HOOK hot path only: no hook command
# routes through the symlink hop or an env var. A permissions.allow entry MAY reference
# `.claude/ghjig-root/` — the shared-code uniform path used to allow-list a shell-owned
# script that must resolve identically in the dogfood shell and every target (#598, the
# ghjig_file_review_post.sh wrapper; same convention ship.md uses for ac_closeout.sh). So
# scope the "no symlink hop" ban to the hook-routing form (`ghjig-root/.claude/hooks`),
# not a blanket file-wide grep.
if [ "$s82e_n" = "5" ] \
   && ! grep -q 'ghjig-root/\.claude/hooks' "$S82_OWN" \
   && ! grep -q '_SHELL_ROOT' "$S82_OWN"; then
  ok "82e: shell's own settings.json routes all 5 hook commands via \${CLAUDE_PROJECT_DIR} directly — no env var, no hook symlink hop (R1, #533)"
else
  ng "82e: shell's own settings.json must route 5 hook commands via \${CLAUDE_PROJECT_DIR} directly (got $s82e_n), no ghjig-root hook hop, no *_SHELL_ROOT (R1, #533)"
fi

# ---------- 83. per-project audit + cache isolation (EI-2a, #314, Directive #311) ----------
# ghjig_state_dir() routes ephemeral assets (audit, caches) to a per-project
# $CLAUDE_PROJECT_DIR/.claude/ghjig-state when CLAUDE_PROJECT_DIR is set (hook
# context), else empty → callers use the legacy shared path. The scope-guard
# registry is NOT moved here (deferred to EI-2b).

# 83a: resolver — set → per-project; unset → empty; override wins. (#314)
# #357: locally unset the whole-run override so each case exercises the branch
# it asserts (per-project / empty); s83_ovr keeps its own inline override.
s83_set=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; unset GHJIG_STATE_DIR_OVERRIDE; CLAUDE_PROJECT_DIR=/tmp/projX ghjig_state_dir )
s83_unset=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; unset GHJIG_STATE_DIR_OVERRIDE CLAUDE_PROJECT_DIR 2>/dev/null; ghjig_state_dir )
s83_ovr=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; GHJIG_STATE_DIR_OVERRIDE=/tmp/ovr CLAUDE_PROJECT_DIR=/tmp/projX ghjig_state_dir )
if [ "$s83_set" = "/tmp/projX/.claude/ghjig-state" ] && [ -z "$s83_unset" ] && [ "$s83_ovr" = "/tmp/ovr" ]; then
  ok "83a: ghjig_state_dir resolves per-project / empty / override (#314)"
else
  ng "83a: ghjig_state_dir resolution wrong (set='$s83_set' unset='$s83_unset' ovr='$s83_ovr') (#314)"
fi

# 83b: audit logs are mutually invisible across two CLAUDE_PROJECT_DIR projects.
S83_A=$(cd "$(mktemp -d)" && pwd -P)
S83_B=$(cd "$(mktemp -d)" && pwd -P)
# #357: unset the override so audit resolves per-project (CLAUDE_PROJECT_DIR), not $SMOKE_STATE.
( export CLAUDE_PROJECT_DIR="$S83_A"; unset GHJIG_STATE_DIR_OVERRIDE; . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; audit_log info test seeded "ei2a-mark-A" ) >/dev/null 2>&1
( export CLAUDE_PROJECT_DIR="$S83_B"; unset GHJIG_STATE_DIR_OVERRIDE; . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; audit_log info test seeded "ei2a-mark-B" ) >/dev/null 2>&1
s83a_log="$S83_A/.claude/ghjig-state/audit/audit.jsonl"
s83b_log="$S83_B/.claude/ghjig-state/audit/audit.jsonl"
if grep -q 'ei2a-mark-A' "$s83a_log" 2>/dev/null && ! grep -q 'ei2a-mark-B' "$s83a_log" 2>/dev/null \
   && grep -q 'ei2a-mark-B' "$s83b_log" 2>/dev/null && ! grep -q 'ei2a-mark-A' "$s83b_log" 2>/dev/null; then
  ok "83b: per-project audit logs mutually invisible (#314)"
else
  ng "83b: audit logs should isolate per CLAUDE_PROJECT_DIR (#314)"
fi
rm -rf "$S83_A" "$S83_B"

# 83c: legacy fallback — CLAUDE_PROJECT_DIR unset → audit lands at the legacy
# $GHJIG_ROOT/.claude/audit path (existing behavior preserved).
S83_LEG=$(cd "$(mktemp -d)" && pwd -P)
( export GHJIG_ROOT="$S83_LEG"; unset CLAUDE_PROJECT_DIR GHJIG_STATE_DIR_OVERRIDE 2>/dev/null
  . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; audit_log info test seeded "ei2a-legacy" ) >/dev/null 2>&1
if grep -q 'ei2a-legacy' "$S83_LEG/.claude/audit/audit.jsonl" 2>/dev/null \
   && [ ! -d "$S83_LEG/.claude/ghjig-state" ]; then
  ok "83c: env-unset audit falls back to legacy shared path (#314)"
else
  ng "83c: env-unset audit should use legacy \$GHJIG_ROOT/.claude/audit (#314)"
fi
rm -rf "$S83_LEG"

# 83d: inject adds .claude/ghjig-state to the target's .git/info/exclude.
S83_INJ=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S83_INJ" && git init -q ) || true
inject_into "$S83_INJ" >/dev/null 2>&1
if grep -qxF '.claude/ghjig-state' "$S83_INJ/.git/info/exclude" 2>/dev/null; then
  ok "83d: inject excludes .claude/ghjig-state in the target (#314)"
else
  ng "83d: inject must add .claude/ghjig-state to .git/info/exclude (#314)"
fi
rm -rf "$S83_INJ"

# ---------- 84. per-project scope-guard registry isolation (EI-2b, #316, Directive #311) ----------
# ghjig_registry_file [project_dir] resolves the scope-guard registry. Argless =
# hook context (rides ghjig_state_dir → CLAUDE_PROJECT_DIR, else legacy shared);
# explicit arg = launcher/CLI context ($arg/.claude/ghjig-state/registry.txt),
# where CLAUDE_PROJECT_DIR is unset because the call precedes the Claude session.
# The registry gates the out-of-scope matcher; missing → in_scope=false → fail-open.

# 84a: resolver resolution — explicit arg / hook (CLAUDE_PROJECT_DIR) / override / legacy.
s84_arg=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; ghjig_registry_file /tmp/projA )
# #357: unset the whole-run override on the override-sensitive (argless) cases —
# s84_hook (rides ghjig_state_dir via CLAUDE_PROJECT_DIR) and s84_leg (legacy
# fallback); s84_arg is explicit-arg (override-immune) and s84_ovr sets its own.
s84_hook=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; unset GHJIG_STATE_DIR_OVERRIDE; CLAUDE_PROJECT_DIR=/tmp/projX ghjig_registry_file )
s84_ovr=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; GHJIG_STATE_DIR_OVERRIDE=/tmp/ovr ghjig_registry_file )
s84_leg=$( . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; export GHJIG_ROOT=/tmp/legroot; unset CLAUDE_PROJECT_DIR GHJIG_STATE_DIR_OVERRIDE 2>/dev/null; ghjig_registry_file )
if [ "$s84_arg" = "/tmp/projA/.claude/ghjig-state/registry.txt" ] \
   && [ "$s84_hook" = "/tmp/projX/.claude/ghjig-state/registry.txt" ] \
   && [ "$s84_ovr" = "/tmp/ovr/registry.txt" ] \
   && [ "$s84_leg" = "/tmp/legroot/.claude/state/registry.txt" ]; then
  ok "84a: ghjig_registry_file resolves arg / hook / override / legacy (#316)"
else
  ng "84a: ghjig_registry_file resolution wrong (arg='$s84_arg' hook='$s84_hook' ovr='$s84_ovr' leg='$s84_leg') (#316)"
fi

# 84b: registrations are mutually invisible across two projects (inject writes per-project).
S84_A=$(cd "$(mktemp -d)" && pwd -P)
S84_B=$(cd "$(mktemp -d)" && pwd -P)
( cd "$S84_A" && git init -q ) || true
( cd "$S84_B" && git init -q ) || true
inject_into "$S84_A" >/dev/null 2>&1
inject_into "$S84_B" >/dev/null 2>&1
s84a_reg="$S84_A/.claude/ghjig-state/registry.txt"
s84b_reg="$S84_B/.claude/ghjig-state/registry.txt"
if grep -qxF "$S84_A" "$s84a_reg" 2>/dev/null && ! grep -qxF "$S84_B" "$s84a_reg" 2>/dev/null \
   && grep -qxF "$S84_B" "$s84b_reg" 2>/dev/null && ! grep -qxF "$S84_A" "$s84b_reg" 2>/dev/null; then
  ok "84b: per-project registries mutually invisible (#316)"
else
  ng "84b: registries should isolate per project (#316)"
fi
rm -rf "$S84_A" "$S84_B"

# 84c: legacy fallback — argless in_scope with no CLAUDE_PROJECT_DIR reads the
# legacy shared $GHJIG_ROOT/.claude/state/registry.txt (back-compat).
S84_LEG=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S84_LEG/.claude/state"
printf '%s\n' "$S84_LEG" > "$S84_LEG/.claude/state/registry.txt"
if ( cd "$S84_LEG"; export GHJIG_ROOT="$S84_LEG"; unset CLAUDE_PROJECT_DIR GHJIG_STATE_DIR_OVERRIDE 2>/dev/null
     . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; . "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"; in_scope ); then
  ok "84c: argless in_scope falls back to legacy shared registry, no project context (#316)"
else
  ng "84c: legacy-shared registry fallback broken (#316)"
fi
rm -rf "$S84_LEG"

# 84d: set -u safety — cwd_guard must not abort with GHJIG_ROOT unset
# (the #312 self-located case); fail-open (return), never crash the guard.
s84d=$( set -u; unset GHJIG_ROOT GHJIG_STATE_DIR_OVERRIDE 2>/dev/null; unset CLAUDE_PROJECT_DIR 2>/dev/null
        . "$SHELL_ROOT/.claude/hooks/hookrt.sh"
        . "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"
        in_scope; printf 'ic=%s ' "$?"; path_in_scope /tmp/x; printf 'pis=%s' "$?" )
if printf '%s' "$s84d" | grep -q 'pis='; then
  ok "84d: cwd_guard set -u-safe with GHJIG_ROOT unset (#316)"
else
  ng "84d: cwd_guard aborts under set -u when GHJIG_ROOT unset (got '$s84d') (#316)"
fi

# 84e: dogfood coherence — self-register write-target == cwd_guard read-target;
# carve-out stays registry-location-independent.
S84_DOG=$(cd "$(mktemp -d)" && pwd -P)
( export GHJIG_ROOT="$SHELL_ROOT"; . "$SHELL_ROOT/scripts/lib/self_register.sh"; ensure_self_registered "$S84_DOG" >/dev/null 2>&1 )
s84e_written="$S84_DOG/.claude/ghjig-state/registry.txt"
# #357: s84e_read is ARGLESS (rides ghjig_state_dir → CLAUDE_PROJECT_DIR); unset the
# whole-run override so it resolves the per-project path it compares against.
s84e_read=$( export CLAUDE_PROJECT_DIR="$S84_DOG"; unset GHJIG_STATE_DIR_OVERRIDE; . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; ghjig_registry_file )
if [ "$s84e_read" = "$s84e_written" ] && grep -qxF "$S84_DOG" "$s84e_written" 2>/dev/null; then
  ok "84e: self-register write-target == cwd_guard read-target (dogfood coherence) (#316)"
else
  ng "84e: dogfood write/read mismatch (read='$s84e_read' written='$s84e_written') (#316)"
fi
if ( export CLAUDE_PROJECT_DIR="$S84_DOG"; unset GHJIG_STATE_DIR_OVERRIDE; . "$SHELL_ROOT/.claude/hooks/hookrt.sh"
     . "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"; path_in_scope "$SHELL_ROOT/.claude/CLAUDE.md" ); then
  ok "84e: shell-root carve-out independent of registry location (#316)"
else
  ng "84e: shell-root carve-out broken under per-project registry (#316)"
fi
rm -rf "$S84_DOG"

# 84f: CLI-context discovery (dr_check_registry_guard) reads the self-describing
# per-project registry from cwd, with CLAUDE_PROJECT_DIR unset (launcher context).
S84_CLI=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S84_CLI/.claude/ghjig-state"
printf '%s\n' "$S84_CLI" > "$S84_CLI/.claude/ghjig-state/registry.txt"
# #357: keep the whole-run override ACTIVE here — dr_check_registry_guard reads
# the registry via explicit-arg (override-immune), so the read is correct either
# way, and the override keeps its project-resolve audit write off the live log.
if ( cd "$S84_CLI"; export GHJIG_ROOT="$SHELL_ROOT"; unset CLAUDE_PROJECT_DIR 2>/dev/null
     . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; . "$SHELL_ROOT/scripts/lib/dir_mode_project_resolve.sh"
     dr_check_registry_guard >/dev/null 2>&1 ); then
  ok "84f: CLI-context discovery reads per-project registry, CLAUDE_PROJECT_DIR unset (#316)"
else
  ng "84f: dr_check_registry_guard should find self-describing per-project registry (#316)"
fi
S84_CLI2=$(cd "$(mktemp -d)" && pwd -P)
if ( cd "$S84_CLI2"; export GHJIG_ROOT="$SHELL_ROOT"; unset CLAUDE_PROJECT_DIR 2>/dev/null
     . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; . "$SHELL_ROOT/scripts/lib/dir_mode_project_resolve.sh"
     dr_check_registry_guard >/dev/null 2>&1 ); then
  ng "84f: unregistered project should fail dr_check_registry_guard (#316)"
else
  ok "84f: unregistered project (no ghjig-state/registry.txt) reads unregistered (#316)"
fi
rm -rf "$S84_CLI" "$S84_CLI2"

# 84g: hook-context back-compat read-floor — a target registered before #316
# (legacy shared registry only, NO per-project ghjig-state/registry.txt) still
# enforces: in_scope falls back to the legacy shared registry even with
# CLAUDE_PROJECT_DIR set (where argless ghjig_registry_file points per-project).
S84_BC=$(cd "$(mktemp -d)" && pwd -P)
S84_BC_ROOT=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S84_BC_ROOT/.claude/state"
printf '%s\n' "$S84_BC" > "$S84_BC_ROOT/.claude/state/registry.txt"   # legacy shared only
# #357: keep CLAUDE_PROJECT_DIR set (hook context) but unset the whole-run
# override so in_scope hits the per-project-absent → legacy back-compat floor.
if ( cd "$S84_BC"; export GHJIG_ROOT="$S84_BC_ROOT"; export CLAUDE_PROJECT_DIR="$S84_BC"; unset GHJIG_STATE_DIR_OVERRIDE
     . "$SHELL_ROOT/.claude/hooks/hookrt.sh"; . "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"
     [ ! -f "$S84_BC/.claude/ghjig-state/registry.txt" ] && in_scope ); then
  ok "84g: hook-context back-compat — pre-#316 target enforces via legacy floor (#316)"
else
  ng "84g: pre-#316 target (legacy-only registry) lost hook enforcement (#316)"
fi
rm -rf "$S84_BC" "$S84_BC_ROOT"

# ---------- 85. shell repo dogfoods its own PR template (#320) ----------
# The shell ships .claude/templates/pr_template_for_target.md to targets but must
# also carry its OWN .github/PULL_REQUEST_TEMPLATE.md (dogfooding, SPEC §9.5/§17).
# Anti-drift contract: the PR template equals the target template with its leading
# install-hint HTML comment line(s) stripped — so editing one without the other
# fails here. The skill path (pr_body.md) is unaffected and not tested here.
S85_PRT="$SHELL_ROOT/.github/PULL_REQUEST_TEMPLATE.md"
S85_SRC="$SHELL_ROOT/.claude/templates/pr_template_for_target.md"
if [ -f "$S85_PRT" ]; then
  ok "85a: .github/PULL_REQUEST_TEMPLATE.md present (dogfood scaffold, #320)"
else
  ng "85a: .github/PULL_REQUEST_TEMPLATE.md missing (#320)"
fi
# 85b: no leftover "install as ..." HTML comment (it IS the installed file).
if [ -f "$S85_PRT" ] && grep -q '^<!--' "$S85_PRT"; then
  ng "85b: PR template still carries an install-hint HTML comment (#320)"
else
  ok "85b: PR template has no install-hint comment (#320)"
fi
# 85c: anti-drift — PR template == target template minus its leading comment line(s).
if [ -f "$S85_PRT" ] && [ -f "$S85_SRC" ]; then
  s85_stripped=$(grep -v '^<!--' "$S85_SRC" | sed '/./,$!d')   # drop comment lines + leading blanks
  s85_actual=$(sed '/./,$!d' "$S85_PRT")                        # normalize leading blanks
  if [ "$s85_stripped" = "$s85_actual" ]; then
    ok "85c: PR template stays in sync with pr_template_for_target.md (#320)"
  else
    ng "85c: PR template drifted from pr_template_for_target.md (#320)"
  fi
else
  ng "85c: PR template or target-template source missing (#320)"
fi

# ---------- 86. work language resolver (EI-1, #323, Directive #322) ----------
# resolve_work_lang (work_lang.sh) resolves the WORK language of durable artifacts.
# SPEC §5.7.2: precedence GHJIG_WORK_LANG env → .claude/state/work-lang
# cwd-relative file → default `en`. Any code accepted verbatim (no enum, not
# ko/en-hardcoded); empty/whitespace → en. Mirrors §11's mode-resolver pattern.
WL_HELPER="$SHELL_ROOT/.claude/hooks/helpers/work_lang.sh"
# shellcheck disable=SC1090
[ -f "$WL_HELPER" ] && . "$WL_HELPER"
WL_TMP=$(cd "$(mktemp -d)" && pwd -P)

# 86a: unset env + no file → default en.
s86a=$( cd "$WL_TMP" || exit; unset GHJIG_WORK_LANG 2>/dev/null
        command -v resolve_work_lang >/dev/null 2>&1 && resolve_work_lang 2>/dev/null )
if [ "$s86a" = "en" ]; then
  ok "86a: resolve_work_lang default → en (unset env + no file) (#323)"
else
  ng "86a: resolve_work_lang default should be en (got '$s86a') (#323)"
fi

# 86b: env layer.
s86b=$( cd "$WL_TMP" || exit; GHJIG_WORK_LANG=ko resolve_work_lang 2>/dev/null )
[ "$s86b" = "ko" ] && ok "86b: GHJIG_WORK_LANG env layer → ko (#323)" \
  || ng "86b: env layer wrong (got '$s86b') (#323)"

# 86c: file layer (cwd-relative .claude/state/work-lang).
mkdir -p "$WL_TMP/.claude/state"; printf 'ja\n' > "$WL_TMP/.claude/state/work-lang"
s86c=$( cd "$WL_TMP" || exit; unset GHJIG_WORK_LANG 2>/dev/null; resolve_work_lang 2>/dev/null )
[ "$s86c" = "ja" ] && ok "86c: .claude/state/work-lang file layer → ja (#323)" \
  || ng "86c: file layer wrong (got '$s86c') (#323)"

# 86d: env overrides file.
s86d=$( cd "$WL_TMP" || exit; GHJIG_WORK_LANG=de resolve_work_lang 2>/dev/null )
[ "$s86d" = "de" ] && ok "86d: env overrides file (#323)" \
  || ng "86d: env should override file (got '$s86d') (#323)"

# 86e: arbitrary code (non-en, non-ko) returned verbatim — generalization, no hardcoding.
s86e=$( cd "$WL_TMP" || exit; GHJIG_WORK_LANG=pt-BR resolve_work_lang 2>/dev/null )
[ "$s86e" = "pt-BR" ] && ok "86e: arbitrary code pt-BR returned verbatim (generalization, #323)" \
  || ng "86e: arbitrary code should pass through (got '$s86e') (#323)"

# 86f: empty/whitespace-only file → en.
printf '   \n' > "$WL_TMP/.claude/state/work-lang"
s86f=$( cd "$WL_TMP" || exit; unset GHJIG_WORK_LANG 2>/dev/null; resolve_work_lang 2>/dev/null )
[ "$s86f" = "en" ] && ok "86f: empty/whitespace work-lang file → en (#323)" \
  || ng "86f: empty file should fall back to en (got '$s86f') (#323)"

# 86g: set -u-safe with everything unset (must not abort).
s86g=$( set -u; cd "$WL_TMP" || exit; rm -f .claude/state/work-lang; unset GHJIG_WORK_LANG 2>/dev/null
        resolve_work_lang; printf ' rc=%s' "$?" )
if printf '%s' "$s86g" | grep -q 'rc=0'; then
  ok "86g: resolve_work_lang set -u-safe, exits 0 (#323)"
else
  ng "86g: resolve_work_lang not set -u-safe (got '$s86g') (#323)"
fi
rm -rf "$WL_TMP"

# ---------- 87. artifact-authoring skills carry the work-language note (EI-3, #327) ----------
# SPEC §5.7.2: each artifact-authoring skill carries a `## Work language` note so
# the instruction reaches the agent at the authoring moment (skills-as-environment).
# Grep-lock with a count-guard (must be exactly 5) — an empty/short match set fails
# (anti-vacuity, smoke.sh:20 discipline). Prose-language compliance is review-judged.
WL87_SKILLS="file-issue file-directive work-on ship complete-directive"
wl87_n=0
for s in $WL87_SKILLS; do
  f="$SHELL_ROOT/.claude/commands/$s.md"
  if [ -f "$f" ] && grep -q '## Work language' "$f" && grep -q 'resolve_work_lang' "$f"; then
    wl87_n=$((wl87_n + 1))
  else
    ng "87: $s.md missing the work-language note (#327)"
  fi
done
if [ "$wl87_n" = 5 ]; then
  ok "87: all 5 artifact-authoring skills carry the work-language note (count-guard, #327)"
else
  ng "87: expected 5 skills with work-language note, got $wl87_n (#327)"
fi

# ---------- 88. bin/ghjig binding-health check (#334) ----------
# An injected target (settings.local.json is a symlink) whose .claude/ghjig-root
# binding is missing/dangling silently no-ops all hooks; bin/ghjig warns at
# launch (the detector the #318-removed SessionStart banner structurally couldn't
# be). Tested against a fake shell root + a stub `claude` on PATH so the tail
# `exec claude` returns 0 instead of launching the real CLI; targets are registered
# in the fake legacy registry so the unregistered-prompt is skipped (no hang).
S88_FAKE=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$S88_FAKE/bin" "$S88_FAKE/.claude/hooks" "$S88_FAKE/.claude/state" "$S88_FAKE/workspace"
cp "$SHELL_ROOT/bin/ghjig" "$S88_FAKE/bin/ghjig"; chmod +x "$S88_FAKE/bin/ghjig"
cp "$SHELL_ROOT/.claude/hooks/hookrt.sh" "$S88_FAKE/.claude/hooks/hookrt.sh"
S88_STUB=$(cd "$(mktemp -d)" && pwd -P); printf '#!/usr/bin/env bash\nexit 0\n' > "$S88_STUB/claude"; chmod +x "$S88_STUB/claude"
S88_VALIDROOT=$(cd "$(mktemp -d)" && pwd -P)   # a real dir for a healthy binding to point at
# shellcheck disable=SC2069  # intentional swap: capture stderr (the warning), discard stdout (same pattern as hook_run)
s88_run() { ( cd "$S88_FAKE" || exit; PATH="$S88_STUB:$PATH" "$S88_FAKE/bin/ghjig" "$1" 2>&1 >/dev/null ); }
s88_reg() { printf '%s\n' "$1" >> "$S88_FAKE/.claude/state/registry.txt"; }   # pre-register → skip prompt

# 88a: injected (settings.local.json symlink) + MISSING ghjig-root → warn.
S88_A=$(cd "$(mktemp -d)" && pwd -P); mkdir -p "$S88_A/.claude"
ln -sfn /dev/null "$S88_A/.claude/settings.local.json"
s88_reg "$S88_A"
printf '%s' "$(s88_run "$S88_A")" | grep -q 'WARN binding-health' \
  && ok "88a: injected + missing binding → warn (#334)" \
  || ng "88a: should warn on missing binding (#334)"

# 88b: injected + HEALTHY ghjig-root (resolves) → silent.
S88_B=$(cd "$(mktemp -d)" && pwd -P); mkdir -p "$S88_B/.claude"
ln -sfn /dev/null "$S88_B/.claude/settings.local.json"
ln -sfn "$S88_VALIDROOT" "$S88_B/.claude/ghjig-root"
s88_reg "$S88_B"
printf '%s' "$(s88_run "$S88_B")" | grep -q 'WARN binding-health' \
  && ng "88b: healthy binding should be silent (#334)" \
  || ok "88b: injected + healthy binding → silent (#334)"

# 88c: NOT injected (no settings.local.json symlink) → silent.
S88_C=$(cd "$(mktemp -d)" && pwd -P); mkdir -p "$S88_C/.claude"
s88_reg "$S88_C"
printf '%s' "$(s88_run "$S88_C")" | grep -q 'WARN binding-health' \
  && ng "88c: non-injected should be silent (#334)" \
  || ok "88c: non-injected dir → silent (#334)"

# 88d: injected + DANGLING ghjig-root (symlink to a missing target) → warn
# (the subtle half of `! -e`, which follows the link).
S88_D=$(cd "$(mktemp -d)" && pwd -P); mkdir -p "$S88_D/.claude"
ln -sfn /dev/null "$S88_D/.claude/settings.local.json"
ln -sfn "$S88_D/.claude/nonexistent-binding-target-$$" "$S88_D/.claude/ghjig-root"
s88_reg "$S88_D"
printf '%s' "$(s88_run "$S88_D")" | grep -q 'WARN binding-health' \
  && ok "88d: injected + dangling binding → warn (#334)" \
  || ng "88d: should warn on dangling binding (#334)"

rm -rf "$S88_FAKE" "$S88_STUB" "$S88_VALIDROOT" "$S88_A" "$S88_B" "$S88_C" "$S88_D"

# ---------- registry (#357) ----------
# No restore needed: the live shared registry was never written this run (the
# whole-run GHJIG_STATE_DIR_OVERRIDE + §41/§50 per-project registration keep every
# write off $SHELL_ROOT/.claude/state/registry.txt). The §357 AC1 assertion at
# the end verifies the live audit log + scope registry are byte-for-byte untouched.

# ---------- §89 (#346): /changelog skill + /ship changelog gate + §18.5 distinction ----------
S89_SKILL="$SHELL_ROOT/.claude/commands/changelog.md"
S89_SHIP="$SHELL_ROOT/.claude/commands/ship.md"
S89_SPEC="$SHELL_ROOT/SPEC.md"

# 89a: the /changelog skill file exists with a `description:` front-matter line.
if [ -f "$S89_SKILL" ] && grep -qE '^description:' "$S89_SKILL"; then
  ok "89a: .claude/commands/changelog.md exists with description front matter (#346)"
else
  ng "89a: .claude/commands/changelog.md missing or lacks description front matter (#346)"
fi

# 89b: the skill carries a Work-language note (it authors a durable artifact — the fragment).
grep -qi 'work language' "$S89_SKILL" 2>/dev/null \
  && ok "89b: changelog.md carries the Work-language note (#346)" \
  || ng "89b: changelog.md lacks the Work-language note (#346)"

# 89c: the skill states validation-delegation — authoring, not a re-validating lint surface (§18.5).
grep -qiE 'delegat.*validation|does not re-?implement|not a .*lint|not a .*check surface' "$S89_SKILL" 2>/dev/null \
  && ok "89c: changelog.md states it delegates validation (authoring, not lint) (#346)" \
  || ng "89c: changelog.md must state it delegates validation to CI, not re-validate (#346)"

# 89d: the skill names BOTH outcomes — write a fragment XOR apply skip-changelog.
if grep -q 'changelog_unreleased' "$S89_SKILL" 2>/dev/null && grep -q 'skip-changelog' "$S89_SKILL" 2>/dev/null; then
  ok "89d: changelog.md offers both fragment-write and skip-changelog outcomes (#346)"
else
  ng "89d: changelog.md must offer fragment-write XOR skip-changelog (#346)"
fi

# 89e: /ship carries the pre-ready changelog gate, ordered BEFORE `gh pr ready`.
if grep -q 'skip-changelog' "$S89_SHIP" 2>/dev/null && grep -q 'gh pr ready' "$S89_SHIP" 2>/dev/null; then
  s89_gate=$(grep -nE 'skip-changelog' "$S89_SHIP" | head -1 | cut -d: -f1)
  s89_ready=$(grep -nE 'gh pr ready' "$S89_SHIP" | tail -1 | cut -d: -f1)
  if [ -n "$s89_gate" ] && [ -n "$s89_ready" ] && [ "$s89_gate" -lt "$s89_ready" ]; then
    ok "89e: ship.md changelog gate precedes gh pr ready (#346)"
  else
    ng "89e: ship.md changelog gate must precede gh pr ready (#346)"
  fi
else
  ng "89e: ship.md lacks the pre-ready changelog gate (skip-changelog) (#346)"
fi

# 89f: SPEC §18.5 distinguishes the forbidden lint skill from the sanctioned authoring affordance.
if grep -qE 'changelog-check.*lint' "$S89_SPEC" && grep -q 'authoring affordance' "$S89_SPEC"; then
  ok "89f: SPEC §18.5 distinguishes lint vs authoring (#346)"
else
  ng "89f: SPEC §18.5 must distinguish the forbidden lint skill from the authoring affordance (#346)"
fi

# 89g: SPEC §18.7 skip-criterion clause exists as the SSOT.
grep -q '18.7 Skip criterion' "$S89_SPEC" \
  && ok "89g: SPEC §18.7 skip-criterion clause present (#346)" \
  || ng "89g: SPEC §18.7 skip-criterion clause missing (#346)"

# ---------- §90 (#347): SPEC as a first-class target SSOT (template + ToC tooling) ----------
S90_TMPL="$SHELL_ROOT/.claude/templates/spec.md"
S90_TOC="$SHELL_ROOT/scripts/build_toc.sh"
S90_SUBWF="$SHELL_ROOT/.claude/templates/target-substrate/workflows"
S90_SPEC="$SHELL_ROOT/SPEC.md"

# 90a: the spec.md template exists with both TOC markers + at least one numbered heading.
if [ -f "$S90_TMPL" ] \
   && grep -qF '<!-- TOC START' "$S90_TMPL" && grep -qF '<!-- TOC END -->' "$S90_TMPL" \
   && grep -qE '^## [0-9]+\. ' "$S90_TMPL"; then
  ok "90a: .claude/templates/spec.md present with TOC markers + numbered headings (#347)"
else
  ng "90a: .claude/templates/spec.md missing markers or numbered headings (#347)"
fi

# 90b: build_toc.sh honors --spec <path> — populate + --check an ARBITRARY SPEC path.
# Runs a COPY in an isolated temp dir (its self-located default SPEC is the temp dir),
# so the real repo SPEC is never touched regardless of parameterization state.
S90_DIR=$(mktemp -d); mkdir -p "$S90_DIR/scripts"
cp "$S90_TOC" "$S90_DIR/scripts/build_toc.sh"
cat > "$S90_DIR/target_spec.md" <<'S90SPEC'
# Target
## Table of contents
<!-- TOC START — generated by scripts/build_toc.sh; do not edit by hand -->
<!-- TOC END -->
## 1. Alpha
body
## 2. Beta
body
S90SPEC
bash "$S90_DIR/scripts/build_toc.sh" --spec "$S90_DIR/target_spec.md" >/dev/null 2>&1
if grep -q '§1' "$S90_DIR/target_spec.md" \
   && bash "$S90_DIR/scripts/build_toc.sh" --spec "$S90_DIR/target_spec.md" --check >/dev/null 2>&1; then
  ok "90b: build_toc.sh --spec populates + checks an arbitrary SPEC path (#347)"
else
  ng "90b: build_toc.sh must accept --spec <path> for a target SPEC (#347)"
fi
rm -rf "$S90_DIR"

# 90c: regression guard — default-path (no --spec) --check still passes on the shell's own SPEC (§28 parity).
bash "$S90_TOC" --check >/dev/null 2>&1 \
  && ok "90c: build_toc.sh default-path --check unchanged on the shell's own SPEC (#347)" \
  || ng "90c: build_toc.sh default behavior regressed on the shell's own SPEC (#347)"

# 90d: the target ToC-freshness workflow ships in the canonical substrate.
[ -f "$S90_SUBWF/check-toc.yml" ] \
  && ok "90d: target-substrate workflows/check-toc.yml present (#347)" \
  || ng "90d: target-substrate workflows/check-toc.yml missing (#347)"

# 90e: the shipped build_toc.sh is byte-identical to the canonical scripts/build_toc.sh (no drift).
if [ -f "$S90_SUBWF/build_toc.sh" ] && cmp -s "$S90_TOC" "$S90_SUBWF/build_toc.sh"; then
  ok "90e: substrate build_toc.sh byte-identical to canonical scripts/build_toc.sh (#347)"
else
  ng "90e: substrate build_toc.sh missing or drifted from scripts/build_toc.sh (#347)"
fi

# 90f: SPEC §1.3 documents SPEC-as-SSOT (paired with MISSION) + the navigation norm.
if grep -q 'frequently-consulted pair' "$S90_SPEC" && grep -q 'heading text is the truth' "$S90_SPEC"; then
  ok "90f: SPEC §1.3 documents SPEC-as-SSOT + navigation norm (#347)"
else
  ng "90f: SPEC §1.3 must document SPEC-as-SSOT pairing + the offset-hint/heading-truth norm (#347)"
fi

# 90g: the spec.md template ships self-consistent — a verbatim copy passes build_toc --check
# (so a target's first SPEC PR is not blocked by a stale ToC). Uses an isolated copy.
# (copy target name avoids a case-insensitive collision with the default SPEC.md path)
S90G_DIR=$(mktemp -d); mkdir -p "$S90G_DIR/scripts"
cp "$S90_TOC" "$S90G_DIR/scripts/build_toc.sh"; cp "$S90_TMPL" "$S90G_DIR/project_spec.md"
bash "$S90G_DIR/scripts/build_toc.sh" --spec "$S90G_DIR/project_spec.md" --check >/dev/null 2>&1 \
  && ok "90g: spec.md template ships with a fresh (self-consistent) ToC (#347)" \
  || ng "90g: spec.md template ToC is stale — a verbatim copy would fail check-toc (#347)"
rm -rf "$S90G_DIR"

# ---------- §90h–§90q (#629): build_toc.sh --check exit-code taxonomy + --migrate ----------
# Contract (SPEC §1.3): --check exits 0 clean / 1 stale-marker / 2 hard-error /
# 3 marker-less (legacy anchor-link ToC) / 4 corrupt-marker (START present, END
# missing). --migrate converts a marker-less anchor-link ToC to the line-number
# marker form: gated on marker absence (no-op on a marker SPEC), transactional
# (refuse byte-unchanged when there is no numbered `## N.` heading), content-
# preserving (replaces only the contiguous ToC-list lines). check-toc.yml maps
# each code to a distinct positive-fix message (§6.0 P4). Mirrors the §90b idiom:
# a COPY of the canonical build_toc.sh run in an isolated temp dir, driven with
# --spec against a per-case fixture; exit code captured via `rc=0; … || rc=$?`.
S90M_DIR=$(mktemp -d); mkdir -p "$S90M_DIR/scripts"
cp "$S90_TOC" "$S90M_DIR/scripts/build_toc.sh"
S90M_TOC="$S90M_DIR/scripts/build_toc.sh"

# 90h: marker-less anchor-link ToC WITH numbered headings → --check exits 3.
cat > "$S90M_DIR/markerless.md" <<'S90MSPEC'
# Target
## Table of contents
- [1. Foo](#1-foo)
- [2. Bar](#2-bar)
## 1. Foo
body
## 2. Bar
body
S90MSPEC
rc=0; bash "$S90M_TOC" --check --spec "$S90M_DIR/markerless.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] \
  && ok "90h: --check on a marker-less anchor-link ToC (numbered headings) exits 3 (#629)" \
  || ng "90h: --check must exit 3 on a marker-less ToC — got $rc (#629)"

# 90i: valid markers but a WRONG body row (+ numbered headings) → --check exits 1 (distinct from 3).
cat > "$S90M_DIR/stale.md" <<'S90MSPEC'
# Target
## Table of contents
<!-- TOC START — generated by scripts/build_toc.sh; do not edit by hand -->
| Section | Title | Line |
|---|---|---|
| §1 | WRONG | 999 |
<!-- TOC END -->
## 1. Foo
body
## 2. Bar
body
S90MSPEC
rc=0; bash "$S90M_TOC" --check --spec "$S90M_DIR/stale.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] \
  && ok "90i: --check on a stale marker ToC exits 1 (distinct from marker-less 3) (#629)" \
  || ng "90i: --check must exit 1 on a stale marker ToC — got $rc (#629)"

# 90j: a TOC START line with NO TOC END → corrupt-marker → --check exits 4.
cat > "$S90M_DIR/corrupt.md" <<'S90MSPEC'
# Target
## Table of contents
<!-- TOC START — generated by scripts/build_toc.sh; do not edit by hand -->
| Section | Title | Line |
|---|---|---|
## 1. Foo
body
S90MSPEC
rc=0; bash "$S90M_TOC" --check --spec "$S90M_DIR/corrupt.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] \
  && ok "90j: --check on a corrupt-marker ToC (START, no END) exits 4 (#629)" \
  || ng "90j: --check must exit 4 on a corrupt-marker ToC — got $rc (#629)"

# 90k: --migrate happy path — marker-less→markers, --check 3→0, idempotent (2nd run
# byte-identical), content-preserving (a sentinel prose line + a trailing `---` survive).
S90M_K="$S90M_DIR/migrate_happy.md"
cat > "$S90M_K" <<'S90MSPEC'
# Target
## Table of contents
- [1. Foo](#1-foo)
- [2. Bar](#2-bar)

SENTINEL_PROSE_629 must survive migrate.

---
## 1. Foo
body
## 2. Bar
body
S90MSPEC
s90k_pre=0; bash "$S90M_TOC" --check --spec "$S90M_K" >/dev/null 2>&1 || s90k_pre=$?
bash "$S90M_TOC" --migrate --spec "$S90M_K" >/dev/null 2>&1
s90k_post=0; bash "$S90M_TOC" --check --spec "$S90M_K" >/dev/null 2>&1 || s90k_post=$?
cp "$S90M_K" "$S90M_DIR/migrate_happy.after1"
bash "$S90M_TOC" --migrate --spec "$S90M_K" >/dev/null 2>&1
if [ "$s90k_pre" -eq 3 ] && [ "$s90k_post" -eq 0 ] \
   && cmp -s "$S90M_K" "$S90M_DIR/migrate_happy.after1" \
   && grep -qF 'SENTINEL_PROSE_629' "$S90M_K" \
   && grep -qxF -- '---' "$S90M_K"; then
  ok "90k: --migrate marker-less→markers (check 3→0), idempotent, preserves prose + trailing --- (#629)"
else
  ng "90k: --migrate happy path failed — check pre=$s90k_pre post=$s90k_post (want 3→0), idempotent/content-preserving (#629)"
fi

# 90l: --migrate REFUSES on a marker-less SPEC with only UNNUMBERED headings —
# non-zero exit AND the SPEC left byte-unchanged (guard-before-mutate, never destroy).
S90M_L="$S90M_DIR/migrate_refuse.md"
cat > "$S90M_L" <<'S90MSPEC'
# Target
## Table of contents
- [Intent](#intent)
- [Design](#design)

## Intent
body
## Design
body
S90MSPEC
cp "$S90M_L" "$S90M_DIR/migrate_refuse.before"
s90l_rc=0; bash "$S90M_TOC" --migrate --spec "$S90M_L" >/dev/null 2>&1 || s90l_rc=$?
if [ "$s90l_rc" -ne 0 ] && cmp -s "$S90M_L" "$S90M_DIR/migrate_refuse.before"; then
  ok "90l: --migrate on unnumbered-only headings refuses (non-zero) + leaves SPEC byte-unchanged (#629)"
else
  ng "90l: --migrate must refuse byte-unchanged on unnumbered headings — rc=$s90l_rc (#629)"
fi

# 90m: --migrate is a byte-unchanged no-op on an already-marker SPEC (gate on marker
# absence), and --check still exits 0. Fixture is populated via write-mode first.
S90M_M="$S90M_DIR/migrate_noop.md"
cat > "$S90M_M" <<'S90MSPEC'
# Target
## Table of contents
<!-- TOC START — generated by scripts/build_toc.sh; do not edit by hand -->
<!-- TOC END -->
## 1. Foo
body
## 2. Bar
body
S90MSPEC
bash "$S90M_TOC" --spec "$S90M_M" >/dev/null 2>&1          # populate fresh marker ToC (write mode)
cp "$S90M_M" "$S90M_DIR/migrate_noop.before"
bash "$S90M_TOC" --migrate --spec "$S90M_M" >/dev/null 2>&1
s90m_rc=0; bash "$S90M_TOC" --check --spec "$S90M_M" >/dev/null 2>&1 || s90m_rc=$?
if cmp -s "$S90M_M" "$S90M_DIR/migrate_noop.before" && [ "$s90m_rc" -eq 0 ]; then
  ok "90m: --migrate on an already-marker SPEC is a byte-unchanged no-op (--check still 0) (#629)"
else
  ng "90m: --migrate must no-op byte-unchanged on a marker SPEC (--check 0) — check=$s90m_rc (#629)"
fi
rm -rf "$S90M_DIR"

# ---- check-toc.yml maps each --check exit code to a distinct positive-fix message ----
S90_CHECKYML="$S90_SUBWF/check-toc.yml"

# 90n: check-toc.yml captures build_toc's exit code (rc capture) rather than a bare `if`.
grep -qF 'rc=$?' "$S90_CHECKYML" \
  && ok "90n: check-toc.yml captures the build_toc.sh exit code (rc capture) (#629)" \
  || ng "90n: check-toc.yml must capture the build_toc.sh exit code to map each to a message (#629)"

# 90o: the rc==3 (marker-less) branch names the positive fix — build_toc.sh --migrate.
grep -qF 'build_toc.sh --migrate' "$S90_CHECKYML" \
  && ok "90o: check-toc.yml rc==3 branch names build_toc.sh --migrate (#629)" \
  || ng "90o: check-toc.yml must map rc==3 (marker-less) to 'run build_toc.sh --migrate' (#629)"

# 90p: the rc==4 (corrupt-marker) branch names repairing/fixing the markers (a positive fix).
grep -qiE '(repair|fix).{0,30}marker' "$S90_CHECKYML" \
  && ok "90p: check-toc.yml rc==4 branch names repairing the ToC markers (#629)" \
  || ng "90p: check-toc.yml must map rc==4 (corrupt-marker) to a repair-the-markers fix (#629)"

# 90q: the stale (rc==1) case still names regenerate, now behind rc-based branching.
if grep -qE '\brc\b' "$S90_CHECKYML" && grep -qi 'regenerat' "$S90_CHECKYML"; then
  ok "90q: check-toc.yml maps the stale (rc==1) case to a regenerate message under rc branching (#629)"
else
  ng "90q: check-toc.yml must keep the stale/regenerate message on an rc-based branch (#629)"
fi

# ---------- §91 (#348): docs/*.md are thin pointers — lead with a SPEC reference ----------
# The docs-thin-pointer norm (SPEC §9): every human-facing docs/*.md digest must
# lead with a "Full details in SPEC §X" reference (within its first two non-empty
# lines — the title + the lead-in), so it cannot become a second copy of canonical
# content that silently drifts from SPEC. Enforcement, not prose (hooks-as-environment).
S91_FAIL=""
for d in "$SHELL_ROOT"/docs/*.md; do
  [ -f "$d" ] || continue
  # First two non-empty lines (title + lead-in). awk reads the file directly and
  # exits after 2 — no `... | head` pipe (which would SIGPIPE the upstream under
  # `set -o pipefail` and fail nondeterministically by file size, GNU vs BSD).
  s91_lead=$(awk 'NF{n++; print; if(n==2) exit}' "$d")
  if [[ "$s91_lead" == *SPEC* ]]; then
    : # leads with a SPEC reference — compliant
  else
    S91_FAIL="$S91_FAIL ${d##*/}"
  fi
done
if [ -z "$S91_FAIL" ]; then
  ok "91: every docs/*.md leads with a SPEC reference (thin-pointer norm, SPEC §9) (#348)"
else
  ng "91: docs/*.md not leading with a SPEC reference:$S91_FAIL (SPEC §9 thin-pointer norm) (#348)"
fi

# ---------- §120 (#627): target-side check-ssot-home gate — SSOT-home discipline ----------
# The shipped tier-3 CI gate (.claude/templates/target-substrate/workflows/
# check-ssot-home.sh, SPEC §1.3 "Target-side enforcement") ports internal smoke
# §91 (docs-thin-pointer, Rule 1) into bound targets and adds a Rule-2 SSOT-
# presence arm + a track-active guard. Models the §90 idiom: EXECUTE the checked-
# in script against a synthesized fixture in an isolated `mktemp -d` root, capture
# exit code (+ stderr remediation substring), assert. One ok/ng per fixture.
# Contract tokens asserted verbatim from SPEC §1.3:
#   Rule 1 fail → stderr contains "home this contract prose in SPEC.md"
#   Rule 2 fail → stderr contains "create SPEC.md as the content home"
S120_CHK="$S90_SUBWF/check-ssot-home.sh"     # the Phase-C script under test
S120_STUB_SRC="$S90_TMPL"                    # scaffold: an all-<…>-placeholder body → the structural stub detector fires (not a byte-compare)

# A substantive, real SPEC.md (clearly NOT the scaffold) reused by the pass fixtures.
S120_REALSPEC='# Acme — Specification

## 1. Overview
Acme is a widget pipeline that ingests purchase orders and emits invoices.

## 2. Contracts
The HTTP API exposes POST /orders and GET /invoices/{id} with a stable JSON schema.

## 3. Non-goals
Acme does not handle payments or shipping logistics.
'

# Run the gate against a populated root. Captures STDERR ONLY (stdout discarded)
# so the remediation-substring assertions honor the contract that the positive
# next step lands on stderr. Sets S120_RC + S120_ERR. Under `set -uo pipefail`
# (no `-e`) the non-zero rc of a failing fixture does not abort the section.
s120_run() {  # $1 = root dir
  S120_ERR=$(bash "$S120_CHK" --root "$1" 2>&1 1>/dev/null); S120_RC=$?
}

# --- F1 (120a): contract-less repo → track-active guard skips clean (exit 0). ---
S120_F1=$(mktemp -d); mkdir -p "$S120_F1/docs"
printf '# Guide\nA getting-started guide with no contract reference here.\n' > "$S120_F1/docs/guide.md"
s120_run "$S120_F1"
[ "$S120_RC" = 0 ] \
  && ok "120a (F1): contract-less repo (no SPEC.md, docs claim none) → exit 0, skip clean (#627)" \
  || ng "120a (F1): contract-less repo must skip clean (exit 0), got rc=$S120_RC (#627)"
rm -rf "$S120_F1"

# --- F2 (120b): compliant docs pointer + a real SPEC.md → exit 0. ---
S120_F2=$(mktemp -d); mkdir -p "$S120_F2/docs"
printf '# Guide\nFull details in SPEC §2.\n' > "$S120_F2/docs/guide.md"
printf '%s' "$S120_REALSPEC" > "$S120_F2/SPEC.md"
s120_run "$S120_F2"
[ "$S120_RC" = 0 ] \
  && ok "120b (F2): compliant docs pointer + real SPEC.md → exit 0 (#627)" \
  || ng "120b (F2): compliant + real SPEC.md must pass (exit 0), got rc=$S120_RC (#627)"
rm -rf "$S120_F2"

# --- F3 (120c): thin-pointer PASS — title + lead-in pointer, real SPEC.md → exit 0. ---
S120_F3=$(mktemp -d); mkdir -p "$S120_F3/docs"
printf '# X\nFull details in SPEC §3.\n' > "$S120_F3/docs/x.md"
printf '%s' "$S120_REALSPEC" > "$S120_F3/SPEC.md"
s120_run "$S120_F3"
[ "$S120_RC" = 0 ] \
  && ok "120c (F3): thin-pointer (SPEC ref in first two non-empty lines) passes → exit 0 (#627)" \
  || ng "120c (F3): thin-pointer PASS misfired, got rc=$S120_RC (#627)"
rm -rf "$S120_F3"

# --- F4 (120d): thin-pointer FAIL — real SPEC.md (track-active) + a docs file with
#     no SPEC in its first two non-empty lines → exit 1 + Rule-1 remediation. ---
S120_F4=$(mktemp -d); mkdir -p "$S120_F4/docs"
printf '%s' "$S120_REALSPEC" > "$S120_F4/SPEC.md"
printf '# Y\nSome prose that never references the single source of truth.\n' > "$S120_F4/docs/y.md"
s120_run "$S120_F4"
if [ "$S120_RC" = 1 ] && [[ "$S120_ERR" == *"home this contract prose in SPEC.md"* ]]; then
  ok "120d (F4): fat docs (no SPEC lead) → exit 1 + 'home this contract prose in SPEC.md' (#627)"
else
  ng "120d (F4): Rule-1 fail expected exit 1 + remediation, got rc=$S120_RC err=[$S120_ERR] (#627)"
fi
rm -rf "$S120_F4"

# --- F5 (120e): SSOT-presence FAIL (absent) — docs lead with an anchored SPEC §
#     pointer but no SPEC.md → exit 1 + Rule-2 remediation. ---
S120_F5=$(mktemp -d); mkdir -p "$S120_F5/docs"
printf '# API\nFull details in SPEC §4.\n' > "$S120_F5/docs/api.md"
s120_run "$S120_F5"
if [ "$S120_RC" = 1 ] && [[ "$S120_ERR" == *"create SPEC.md as the content home"* ]]; then
  ok "120e (F5): docs claim SPEC but SPEC.md absent → exit 1 + 'create SPEC.md as the content home' (#627)"
else
  ng "120e (F5): Rule-2 (absent) expected exit 1 + remediation, got rc=$S120_RC err=[$S120_ERR] (#627)"
fi
rm -rf "$S120_F5"

# --- F6 (120f): SSOT-presence PASS (homed) — F5's docs + a real SPEC.md → exit 0. ---
S120_F6=$(mktemp -d); mkdir -p "$S120_F6/docs"
printf '# API\nFull details in SPEC §4.\n' > "$S120_F6/docs/api.md"
printf '%s' "$S120_REALSPEC" > "$S120_F6/SPEC.md"
s120_run "$S120_F6"
[ "$S120_RC" = 0 ] \
  && ok "120f (F6): docs claim SPEC + a real SPEC.md present → exit 0 (#627)" \
  || ng "120f (F6): homed SSOT must pass (exit 0), got rc=$S120_RC (#627)"
rm -rf "$S120_F6"

# --- F7 (120g): stub FAIL — docs claim SPEC + a SPEC.md whose body is still all
#     <…> placeholders (the spec.md scaffold, placeholders substituted to realistic
#     values) → the structural stub detector fires → exit 1. A stub counts as absent
#     for Rule 2. ---
S120_F7=$(mktemp -d); mkdir -p "$S120_F7/docs"
printf '# API\nFull details in SPEC §4.\n' > "$S120_F7/docs/api.md"
sed -e 's/{{ project }}/Acme/g' -e 's/{{ today }}/2026-07-20/g' "$S120_STUB_SRC" > "$S120_F7/SPEC.md"
s120_run "$S120_F7"
[ "$S120_RC" = 1 ] \
  && ok "120g (F7): scaffold-stub SPEC.md counts as absent → exit 1 (#627)" \
  || ng "120g (F7): stub SPEC.md must fail Rule 2 (exit 1), got rc=$S120_RC (#627)"
rm -rf "$S120_F7"

# --- F9 (120h): substantive-short SPEC PASS — the critical stub false-fail guard.
#     A real mid-onboarding SPEC.md with genuine prose in §1/§2 but one section body
#     still a <…> placeholder has real body lines → the structural detector does NOT
#     treat it as a stub → exit 0. ---
S120_F9=$(mktemp -d); mkdir -p "$S120_F9/docs"
printf '# API\nFull details in SPEC §2.\n' > "$S120_F9/docs/api.md"
printf '%s' '# Acme — Specification

## 1. Overview
Acme ingests purchase orders and emits invoices for the warehouse team.

## 2. Contracts
POST /orders accepts a JSON order; GET /invoices/{id} returns the stored invoice.

## 3. Non-goals
<not decided yet>
' > "$S120_F9/SPEC.md"
s120_run "$S120_F9"
[ "$S120_RC" = 0 ] \
  && ok "120h (F9): real short SPEC (genuine §1/§2 prose, one <…> placeholder) not read as stub → exit 0 (#627)" \
  || ng "120h (F9): substantive-short SPEC misread as stub, got rc=$S120_RC (#627)"
rm -rf "$S120_F9"

# --- F10 (120i): stub detection is STRUCTURAL, not a byte-compare to the scaffold.
#     A SPEC.md with CUSTOMIZED headings (nothing like the scaffold's text) but an
#     all-<…>-placeholder body must still be read as a stub → exit 1. This pins the
#     SPEC §1.3 Rule 2 guarantee that detection keys on the body being all-placeholder,
#     NOT on byte-identity to .claude/templates/spec.md (which is absent in targets). ---
S120_F10=$(mktemp -d); mkdir -p "$S120_F10/docs"
printf '# API\nFull details in SPEC §7.\n' > "$S120_F10/docs/api.md"
printf '%s' '# Widgetron — Behaviour Spec

## 7. Ingest surface
<TODO: describe the ingest surface.>

## 8. Storage guarantees
<TODO: describe the storage guarantees.>
' > "$S120_F10/SPEC.md"
s120_run "$S120_F10"
[ "$S120_RC" = 1 ] \
  && ok "120i (F10): all-placeholder body with custom headings is a stub (structural, not byte-identity) → exit 1 (#627)" \
  || ng "120i (F10): custom-heading all-placeholder SPEC must be read as a stub (exit 1), got rc=$S120_RC (#627)"
rm -rf "$S120_F10"

# ---------- §92 (#354): SPEC §6.0 wired into the review layer (enforcement-style lens) ----------
# §6.0's own P4 forbids "guidance with no gate behind it"; the enforcement-style
# principle must therefore be referenced by the artifact-judging reviewers that
# apply it, not merely documented. Structural fixed-string grep for the stable
# token "SPEC §6.0" (not a sentence — robust to future rewordings of the lens);
# collect every missing reviewer before reporting (no first-failure short-circuit).
S92_FAIL=""
for r in issue-reviewer plan-reviewer code-reviewer; do
  rf="$SHELL_ROOT/.claude/agents/$r.md"
  if [ -f "$rf" ] && grep -qF 'SPEC §6.0' "$rf"; then
    : # references the enforcement-style principle — wired
  else
    S92_FAIL="$S92_FAIL $r"
  fi
done
if [ -z "$S92_FAIL" ]; then
  ok "92: issue/plan/code-reviewer prompts reference SPEC §6.0 (enforcement-style lens) (#354)"
else
  ng "92: reviewer prompts missing SPEC §6.0 reference:$S92_FAIL (#354)"
fi

# ---------- 93. audit source discriminator + reviewer-reject instrumentation (#361, Directive #356 signals 1+3) ----------
# All fires here resolve to $SMOKE_AUDIT (the whole-run GHJIG_STATE_DIR_OVERRIDE),
# so they do NOT touch the live sinks the §357 backstop (just below) measures.
# hook_run inherits the process env (only GHJIG_ROOT_OVERRIDE is prefix-set),
# so the global GHJIG_AUDIT_SOURCE=test flows through; a subshell that
# unsets / re-sets it exercises the default + forged-value branches.

# Helper: emit one audit-producing fixture fire and echo the LAST record's
# .source (eval "ls" → a bypass-suspect warn, a clean audit-emitting fire).
s93_last_source() {  # echoes the .source of the newest $SMOKE_AUDIT record
  hook_run 'eval "ls -la"' >/dev/null
  tail -n 1 "$SMOKE_AUDIT" 2>/dev/null | jq -r '.source // "ABSENT"' 2>/dev/null
}

if ! command -v jq >/dev/null 2>&1; then
  ng "89: jq not installed — cannot scan audit source field (#361)"
else
  # 89a — the source field is present and resolves `test` under the harness
  # marker (exported globally at smoke start). RED pre-#361 (no field → ABSENT).
  s93a=$(s93_last_source)
  [ "$s93a" = "test" ] \
    && ok "93a: audit record carries source=test under harness marker (#361)" \
    || ng "93a: audit source not 'test' under harness marker (got '$s93a') (#361)"

  # 89b (AC#2 default-live) — marker UNSET → source=live. A real session has no
  # marker, so its records must be live. RED pre-#361.
  s93b=$( unset GHJIG_AUDIT_SOURCE; s93_last_source )
  [ "$s93b" = "live" ] \
    && ok "93b: marker unset → source=live (real-session default) (#361)" \
    || ng "93b: marker unset did not resolve source=live (got '$s93b') (#361)"

  # 89c (AC#2 anti-reclassification) — a FORGED non-`test` value (smoke) must
  # still resolve `live`: only the exact token `test` flips the field, so a real
  # action cannot reclassify itself to dodge a friction signal. RED pre-#361.
  s93c=$( export GHJIG_AUDIT_SOURCE=smoke; s93_last_source )
  [ "$s93c" = "live" ] \
    && ok "93c: forged GHJIG_AUDIT_SOURCE=smoke still resolves source=live (#361)" \
    || ng "93c: forged non-test marker leaked into source (got '$s93c') (#361)"

  # 89d — jq still parses every line after the new field lands (shape integrity).
  if jq -c '.' "$SMOKE_AUDIT" >/dev/null 2>&1; then
    ok "93d: audit.jsonl still one-JSON-object-per-line with the source field (#361)"
  else
    ng "93d: audit.jsonl no longer fully jq-parseable after source field (#361)"
  fi

  # 89e — reviewer_reject_audit helper emits a categorized reject record. RED
  # pre-#361 (helper absent → source fails → nothing emitted).
  s93e_before=$(wc -l < "$SMOKE_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$s93e_before" ] && s93e_before=0
  (
    # shellcheck disable=SC1091
    . "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null
    . "$SHELL_ROOT/.claude/hooks/helpers/reviewer_audit.sh" 2>/dev/null
    reviewer_reject_audit issue-review scope-bleed 999 2>/dev/null
  )
  s93e_after=$(wc -l < "$SMOKE_AUDIT" 2>/dev/null | tr -d ' '); [ -z "$s93e_after" ] && s93e_after=0
  if [ "$s93e_after" -gt "$s93e_before" ] \
     && tail -n "$((s93e_after - s93e_before))" "$SMOKE_AUDIT" 2>/dev/null \
        | jq -e 'select(.event=="warn" and .category=="issue-review" and .decision=="reject" and (.reason | test("class=scope-bleed issue=#999")))' >/dev/null 2>&1; then
    ok "93e: reviewer_reject_audit emits warn/issue-review/reject with class+issue (#361)"
  else
    ng "93e: reviewer_reject_audit did not emit the expected reject record (#361)"
  fi

  # 89f — structural: each of the 4 reviewer-invoking skills references the
  # reject-audit emission (reviewer_reject_audit or the reason-class token).
  s93f_fail=
  for f in file-issue work-on activate complete-directive; do
    grep -q 'reviewer_reject_audit\|reason-class\|reason_class' "$SHELL_ROOT/.claude/commands/$f.md" 2>/dev/null \
      || s93f_fail="$s93f_fail $f"
  done
  [ -z "$s93f_fail" ] \
    && ok "93f: all 4 reviewer-invoking skills wire the reject-audit emission (#361)" \
    || ng "93f: skills missing reject-audit wiring:$s93f_fail (#361)"
fi

# ---------- §94 (#363): audit-log consumers — narrowing detector + promotion report (Directive #356 signals 2/4/5) ----------
# Read-only reporters run against a SYNTHETIC fixture audit.jsonl (mktemp, passed
# as the path arg) — never the live/$SMOKE log — so the assertions don't couple
# to real escape history and cannot pollute the live sinks (§357 AC1 stays green).

# 94a: SPEC §6.0 P3 references the audit log as a P3 consumer surface, names both
# scripts, and states the dual-positive-channel concept (signal 5). (Doc-phase; green early.)
if grep -q 'narrowing_candidates.sh' "$SHELL_ROOT/SPEC.md" \
   && grep -q 'promotion_candidates.sh' "$SHELL_ROOT/SPEC.md" \
   && grep -q 'dual-positive' "$SHELL_ROOT/SPEC.md"; then
  ok "94a: SPEC §6.0 P3 names both consumers + the dual-positive-channel concept (#363)"
else
  ng "94a: SPEC §6.0 P3 must name the two consumer scripts + the dual-positive channel (#363)"
fi

S94_NARROW="$SHELL_ROOT/scripts/narrowing_candidates.sh"
S94_PROMO="$SHELL_ROOT/scripts/promotion_candidates.sh"
if [ ! -f "$S94_NARROW" ] || [ ! -f "$S94_PROMO" ]; then
  ng "94b: scripts/narrowing_candidates.sh / promotion_candidates.sh missing — Code not yet landed (#363)"
  ng "94c: narrowing below-threshold/test-exclusion — scripts missing (#363)"
  ng "94d: promotion surfaced above threshold — scripts missing (#363)"
  ng "94e: promotion below-threshold + legacy-skip — scripts missing (#363)"
  ng "94f: empty/absent-log graceful exit 0 — scripts missing (#363)"
elif ! command -v jq >/dev/null 2>&1; then
  ng "94b: jq not installed — cannot run consumer-script smoke (#363)"
else
  S94_DIR=$(mktemp -d)
  # Narrowing fixture: force-push has 2 distinct LIVE days (→ surfaced, threshold 2);
  # merge-strategy 1 day (below); secret has 2 TEST-source days (excluded → not
  # surfaced); out-of-scope is a legacy line with no source field (→ treated live,
  # must not crash).
  cat > "$S94_DIR/narrow.jsonl" <<'S94FIX'
{"ts":"2026-06-01T10:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
{"ts":"2026-06-02T11:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
{"ts":"2026-06-03T12:00:00Z","event":"escape","category":"merge-strategy","decision":"skip","reason":"one off","cwd":"/x","source":"live"}
{"ts":"2026-06-01T08:00:00Z","event":"escape","category":"secret","decision":"skip","reason":"test fixture","cwd":"/x","source":"test"}
{"ts":"2026-06-02T08:00:00Z","event":"escape","category":"secret","decision":"skip","reason":"test fixture","cwd":"/x","source":"test"}
{"ts":"2026-06-04T09:00:00Z","event":"escape","category":"out-of-scope","decision":"skip","reason":"legacy no source"}
S94FIX
  s94_n_out=$(bash "$S94_NARROW" "$S94_DIR/narrow.jsonl" 2>/dev/null); s94_n_rc=$?
  if [ "$s94_n_rc" = 0 ] && printf '%s\n' "$s94_n_out" | grep -q 'force-push'; then
    ok "94b: narrowing surfaces the 2-distinct-day force-push escape cluster (#363)"
  else
    ng "94b: narrowing did not surface the 2-day force-push cluster (rc=$s94_n_rc) (#363)"
  fi
  if printf '%s\n' "$s94_n_out" | grep -q 'merge-strategy' || printf '%s\n' "$s94_n_out" | grep -q 'secret'; then
    ng "94c: narrowing wrongly surfaced a below-threshold (merge-strategy) or test-source (secret) cluster (#363)"
  else
    ok "94c: narrowing omits single-day + test-source clusters (LIVE-only, threshold) (#363)"
  fi

  # Promotion fixture: issue-review×scope-bleed has 3 rejects (→ surfaced, threshold 3);
  # plan-review×conflict 2 (below); a legacy warn/reject reason with no class= (→ skipped).
  cat > "$S94_DIR/promo.jsonl" <<'S94FIX'
{"ts":"2026-06-01T10:00:00Z","event":"warn","category":"issue-review","decision":"reject","reason":"class=scope-bleed issue=#10","cwd":"/x","source":"live"}
{"ts":"2026-06-01T11:00:00Z","event":"warn","category":"issue-review","decision":"reject","reason":"class=scope-bleed issue=#11","cwd":"/x","source":"live"}
{"ts":"2026-06-02T10:00:00Z","event":"warn","category":"issue-review","decision":"reject","reason":"class=scope-bleed issue=#12","cwd":"/x","source":"live"}
{"ts":"2026-06-02T11:00:00Z","event":"warn","category":"plan-review","decision":"reject","reason":"class=conflict issue=#13","cwd":"/x","source":"live"}
{"ts":"2026-06-03T10:00:00Z","event":"warn","category":"plan-review","decision":"reject","reason":"class=conflict issue=#14","cwd":"/x","source":"live"}
{"ts":"2026-06-03T11:00:00Z","event":"warn","category":"legacy-cat","decision":"reject","reason":"no class token here","cwd":"/x"}
S94FIX
  s94_p_out=$(bash "$S94_PROMO" "$S94_DIR/promo.jsonl" 2>/dev/null); s94_p_rc=$?
  if [ "$s94_p_rc" = 0 ] && printf '%s\n' "$s94_p_out" | grep -q 'issue-review' && printf '%s\n' "$s94_p_out" | grep -q 'scope-bleed'; then
    ok "94d: promotion surfaces issue-review×scope-bleed above the reject threshold (#363)"
  else
    ng "94d: promotion did not surface the 3-reject issue-review/scope-bleed group (rc=$s94_p_rc) (#363)"
  fi
  if printf '%s\n' "$s94_p_out" | grep -q 'conflict'; then
    ng "94e: promotion wrongly surfaced the below-threshold plan-review/conflict group (#363)"
  else
    ok "94e: promotion omits below-threshold group + skips the legacy no-class line (#363)"
  fi

  # 94f: empty + absent log → graceful, exit 0 (no crash, fail-open).
  : > "$S94_DIR/empty.jsonl"
  bash "$S94_NARROW" "$S94_DIR/empty.jsonl" >/dev/null 2>&1; s94_e1=$?
  bash "$S94_PROMO" "$S94_DIR/empty.jsonl" >/dev/null 2>&1; s94_e2=$?
  bash "$S94_NARROW" "$S94_DIR/does-not-exist.jsonl" >/dev/null 2>&1; s94_e3=$?
  if [ "$s94_e1" = 0 ] && [ "$s94_e2" = 0 ] && [ "$s94_e3" = 0 ]; then
    ok "94f: both consumers degrade gracefully (exit 0) on empty + absent log (#363)"
  else
    ng "94f: a consumer crashed on empty/absent log (narrow-empty=$s94_e1 promo-empty=$s94_e2 narrow-absent=$s94_e3) (#363)"
  fi
  rm -rf "$S94_DIR"
fi

# ---------- §95 (#365): audit record-shape SPEC examples carry source; info event documented (G1+G4) ----------
# The §6.1 helper-missing example and the §7 escape example are the canonical
# record-shape contract a consumer copies from; they must include every field
# audit_log's printf emits (hookrt.sh now appends "source" last on EVERY record,
# #361). And the info event kind, emitted by audit_log info (pre_tool_use.sh +
# dir-mode flows), must be documented as a valid event. Reproduce-first: these
# fail on the pre-#365 SPEC (examples omit source; info undocumented).
S95_SPEC="$SHELL_ROOT/SPEC.md"
# 95a: §6.1 helper-missing example carries the source field (G1).
if grep -E '"decision":"helper-missing"' "$S95_SPEC" | grep -q '"source"'; then
  ok "95a: SPEC helper-missing example includes the source field (#365)"
else
  ng "95a: SPEC helper-missing example omits source — drifted from hookrt.sh printf (#365)"
fi
# 95b: §7 escape-skip example carries the source field (G1).
if grep -E '"event":"escape"' "$S95_SPEC" | grep -q '"source"'; then
  ok "95b: SPEC §7 escape example includes the source field (#365)"
else
  ng "95b: SPEC §7 escape example omits source — drifted from hookrt.sh printf (#365)"
fi
# 95c: the info event kind is documented as a valid event (G4) — reconciles the
# "not new event-type kinds" line with the info record audit_log actually emits.
if grep -q 'Event-kind set' "$S95_SPEC" && grep -qE 'event.*\binfo\b|\binfo\b.*informational' "$S95_SPEC"; then
  ok "95c: SPEC documents the info event kind in the event-kind set (#365)"
else
  ng "95c: SPEC does not document the info event kind audit_log emits (#365)"
fi

# ---------- §96 (#366): protected-push / git-clean — token-as-data + sibling-segment FPs ----------
# The protected-push arm scans only the git-push command SEGMENT after heredoc-
# stripping (not a whole-command substring), and the git-clean arm heredoc-strips
# too. So a protected token in a sibling non-push segment or inside a heredoc body
# no longer false-blocks; genuine protected pushes still block (zero false-neg).
# hook_run rc: 2=block, 0=allow. 96a-d are RED pre-fix (old substring blocks them);
# 96e-k are zero-false-negative guards (BLOCK before and after).

# --- false positives that must now ALLOW (rc 0) ---
[ "$(hook_run 'git push origin feat && gh pr create --base main')" = 0 ] \
  && ok "96a: push feat && gh pr create --base main → allow (sibling segment) (#366)" \
  || ng "96a: chained --base main false-blocked the push (#366)"
s96b=$(printf 'cat <<EOF\ndiscuss: git push origin main here\nEOF\n')
[ "$(hook_run "$s96b")" = 0 ] \
  && ok "96b: git push…main inside a heredoc body → allow (data) (#366)" \
  || ng "96b: heredoc-body push text false-blocked (#366)"
s96c=$(printf 'cat <<EOF\nrun git clean -fd to reset\nEOF\n')
[ "$(hook_run "$s96c")" = 0 ] \
  && ok "96c: git clean -f inside a heredoc body → allow (data) (#366)" \
  || ng "96c: heredoc-body git-clean text false-blocked (#366)"
[ "$(hook_run 'git push origin feat ; echo done with main')" = 0 ] \
  && ok "96d: push feat ; echo …main → allow (sibling ; segment) (#366)" \
  || ng "96d: ;-separated main mention false-blocked the push (#366)"

# --- zero-false-negative: genuine protected pushes/cleans MUST still BLOCK (rc 2) ---
[ "$(hook_run 'git push origin main')" = 2 ] \
  && ok "96e: git push origin main still blocked (#366)" \
  || ng "96e: real protected push slipped (#366)"
[ "$(hook_run 'git push -u origin main')" = 2 ] \
  && ok "96f: git push -u origin main still blocked (#366)" \
  || ng "96f: real -u protected push slipped (#366)"
[ "$(hook_run 'git push origin HEAD:main')" = 2 ] \
  && ok "96g: git push origin HEAD:main still blocked (#366)" \
  || ng "96g: HEAD:main refspec push slipped (#366)"
[ "$(hook_run 'GH_TOKEN=x git push origin main')" = 2 ] \
  && ok "96h: env-prefixed real protected push still blocked (#366)" \
  || ng "96h: env-prefixed protected push slipped (#366)"
[ "$(hook_run 'echo x && git push origin main')" = 2 ] \
  && ok "96i: real protected push in a non-first && segment still blocked (#366)" \
  || ng "96i: non-first-segment protected push slipped (#366)"
[ "$(hook_run 'git push origin "main"')" = 2 ] \
  && ok "96j: quoted protected target still blocked (heredoc-only strip keeps it) (#366)" \
  || ng "96j: quoted protected target slipped — false-negative (#366)"
[ "$(hook_run 'git clean -fd')" = 2 ] \
  && ok "96k: real git clean -fd still blocked (#366)" \
  || ng "96k: real git clean slipped (#366)"

# ---------- §97 (#368): SPEC↔code accuracy sweep (G5–G11) ----------
# Doc-only SSOT-accuracy pins: each asserts SPEC now matches implemented behavior.
# Reproduce-first: each FAILS on the pre-#368 SPEC (verified against origin/main).
S97_SPEC="$SHELL_ROOT/SPEC.md"
# 97a (G6): the stale `/onboard-dir-mode (deferred)` marker is gone.
if grep -q 'onboard-dir-mode` (deferred)' "$S97_SPEC"; then
  ng "97a: SPEC still carries the stale /onboard-dir-mode (deferred) marker (#368)"
else
  ok "97a: /onboard-dir-mode (deferred) marker removed (#368)"
fi
# 97b (G7): §3.3 states the scope-guard fail-open contract.
if awk '/^### 3.3/{f=1} f&&/^### 3.4/{exit} f' "$S97_SPEC" | grep -q 'Fail-open contract'; then
  ok "97b: SPEC §3.3 states the scope-guard fail-open contract (#368)"
else
  ng "97b: SPEC §3.3 omits the scope-guard fail-open contract (#368)"
fi
# 97c (G9b): the §6.1 sensitive-file row lists id_rsa* / id_ed25519* (parity with §14 + code).
if grep -qE 'Edit/Write on `\.env`.*id_rsa.*id_ed25519' "$S97_SPEC"; then
  ok "97c: SPEC §6.1 sensitive-file row lists id_rsa*/id_ed25519* (#368)"
else
  ng "97c: SPEC §6.1 sensitive-file row omits id_rsa*/id_ed25519* (drifted from the code) (#368)"
fi
# 97d (G11): the #107 reversibility-preflight marker reflects that the preflight landed (not deferred).
if grep -q 'Per-command preflight implementation is deferred' "$S97_SPEC"; then
  ng "97d: SPEC still says the per-command preflight is deferred (#107 is closed) (#368)"
else
  ok "97d: SPEC reflects the landed per-command substrate preflight (#368)"
fi

# ---------- §98 (#374): /onboard-dir-mode installs the changelog_unreleased substrate (SPEC §18.6) ----------
# SPEC §18.1/§18.6 mandate that tier-3 onboarding install the release-backbone
# authoring substrate — changelog_unreleased/TEMPLATE.md + the six Keep-a-Changelog
# category subdirs each with a .gitkeep — alongside the check-changelog.yml gate.
# Pre-#374: the canonical source tree does not exist under target-substrate/ and
# onboard_target.sh copies none of it, so every assertion below FAILS on the
# pre-#374 tree (reproduce-first). Each is a pure file/grep check (no live-sink write).
S98_SUB="$SHELL_ROOT/.claude/templates/target-substrate/changelog_unreleased"
# §98a: canonical source carries TEMPLATE.md.
if [ -f "$S98_SUB/TEMPLATE.md" ]; then
  ok "98a: target-substrate/changelog_unreleased/TEMPLATE.md present (#374, SPEC §18.6)"
else
  ng "98a: target-substrate/changelog_unreleased/TEMPLATE.md missing (#374, SPEC §18.6)"
fi
# §98b: each of the six Keep-a-Changelog category subdirs carries a .gitkeep
# (empty dirs do not survive git; the placeholder is load-bearing for both the
# source tree and the installed target).
s98b_missing=""
for cat in added changed deprecated removed fixed security; do
  [ -f "$S98_SUB/$cat/.gitkeep" ] || s98b_missing="$s98b_missing $cat"
done
if [ -z "$s98b_missing" ]; then
  ok "98b: all six changelog_unreleased category dirs carry .gitkeep (#374, SPEC §18.6)"
else
  ng "98b: changelog_unreleased category dirs missing .gitkeep:$s98b_missing (#374, SPEC §18.6)"
fi
# §98b2: the canonical source carries ONLY placeholders, not the shell's own
# accumulated <N>.md fragments (adopters start empty).
if ls "$S98_SUB"/*/[0-9]*.md >/dev/null 2>&1; then
  ng "98b2: target-substrate substrate leaked accumulated <N>.md fragments (adopters must start empty) (#374)"
else
  ok "98b2: target-substrate substrate carries only placeholders, no <N>.md fragments (#374)"
fi
# §98c: onboard_target.sh tier-3 actually installs the substrate (references the
# changelog_unreleased path in its copy logic — guards against shipping the source
# tree but never copying it).
if grep -q 'changelog_unreleased' "$SHELL_ROOT/scripts/onboard_target.sh"; then
  ok "98c: onboard_target.sh tier-3 install path references changelog_unreleased (#374)"
else
  ng "98c: onboard_target.sh never copies changelog_unreleased — source tree would ship uninstalled (#374)"
fi
# §98d: the /onboard-dir-mode skill doc lists the substrate in its tier-3 file set.
if grep -q 'changelog_unreleased' "$SHELL_ROOT/.claude/commands/onboard-dir-mode.md"; then
  ok "98d: /onboard-dir-mode tier-3 file set lists changelog_unreleased (#374)"
else
  ng "98d: /onboard-dir-mode tier-3 file set omits changelog_unreleased (#374)"
fi

# ---------- §99 (#376): SPEC names the lint-timeout-absent audit category ----------
# detect_stack.sh:66 emits `audit_log warn lint-timeout-absent notice ...` when
# neither timeout(1) nor gtimeout(1) is on PATH, but pre-#376 the category was
# named in no SPEC enumeration. Bridge pin until #377's generative
# audit-category↔SPEC guard subsumes it. FAILS on the pre-#376 SPEC.
S99_SPEC="$SHELL_ROOT/SPEC.md"
if grep -q 'lint-timeout-absent' "$S99_SPEC"; then
  ok "99a: SPEC §6.1 names the lint-timeout-absent audit category (#376)"
else
  ng "99a: SPEC omits the lint-timeout-absent audit category emitted by detect_stack.sh (#376)"
fi
# §99b: the category is emitted by the code it documents (anchors the doc to reality).
if grep -q 'lint-timeout-absent' "$SHELL_ROOT/.claude/hooks/helpers/detect_stack.sh"; then
  ok "99b: detect_stack.sh emits lint-timeout-absent (SPEC §6.1 doc has a real referent) (#376)"
else
  ng "99b: detect_stack.sh no longer emits lint-timeout-absent — SPEC §6.1 doc is now stale (#376)"
fi

# ---------- §100 (#377): generative SPEC↔code consistency guards (Directive #373) ----------
# Promote the periodic manual sweep (#368) + hand-pinned point assertions (§97)
# into continuous generative guards over two enumerable contract surfaces, in the
# §39c/§58a style (pure shell, deterministic, no network). These would have caught
# the lint-timeout-absent drift (audit category emitted but undocumented) and the
# /activate-directive forward-ref drift this sweep surfaced.

S100_SPEC="$SHELL_ROOT/SPEC.md"
S100_HOOKS="$SHELL_ROOT/.claude/hooks"
S100_CMDS="$SHELL_ROOT/.claude/commands"

# §100a — every LITERAL audit_log category emitted across .claude/hooks/** is
# documented somewhere in SPEC. Pure-comment lines (leading #) are excluded so
# prose like "emits an audit_log warn once" is not mis-read as a category;
# variable-passed categories (audit_log warn "$cat") are inherently un-resolvable
# statically and are simply not matched by the literal extractor.
s100_cats=$(grep -rhE 'audit_log[[:space:]]+(info|warn|block|error)[[:space:]]+[A-Za-z]' "$S100_HOOKS" 2>/dev/null \
  | grep -vE '^[[:space:]]*#' \
  | grep -oE 'audit_log[[:space:]]+(info|warn|block|error)[[:space:]]+[A-Za-z][A-Za-z0-9_-]+' \
  | awk '{print $3}' | sort -u)
s100a_missing=""
for cat in $s100_cats; do
  grep -qF "$cat" "$S100_SPEC" || s100a_missing="$s100a_missing $cat"
done
if [ -z "$s100a_missing" ]; then
  ok "100a: every literal audit_log category in .claude/hooks/** is documented in SPEC ($(printf '%s' "$s100_cats" | wc -w | tr -d ' ') cats) (#377)"
else
  ng "100a: audit categories emitted but undocumented in SPEC:$s100a_missing (#377)"
fi
# §100b — falsifiability: the same extractor+lookup correctly FLAGS a synthetic
# category that is absent from SPEC (proves 100a is not vacuously passing).
if grep -qF 'zzz-fake-cat-377' "$S100_SPEC"; then
  ng "100b: guard self-test tripwire 'zzz-fake-cat-377' unexpectedly present in SPEC (#377)"
else
  ok "100b: audit-category guard is falsifiable (a synthetic absent category is detectable) (#377)"
fi

# §100c — every .claude/commands/*.md command is referenced in SPEC (plain `/cmd`
# token; backticks optional — /discuss is named in §5.19 prose without them). The
# substring match only over-counts (e.g. /activate matches inside
# /activate-directive), which can never cause a false FAIL — it only fails when a
# command has ZERO SPEC references, the real "command exists, SPEC silent" drift.
s100c_missing=""
for f in "$S100_CMDS"/*.md; do
  cmd="/$(basename "$f" .md)"
  grep -qF "$cmd" "$S100_SPEC" || s100c_missing="$s100c_missing $cmd"
done
if [ -z "$s100c_missing" ]; then
  ok "100c: every .claude/commands/*.md command is referenced in SPEC (#377)"
else
  ng "100c: command files with no SPEC reference:$s100c_missing (#377)"
fi

# §100d — no command/agent file steers a user to a SPEC-deprecated alias via
# imperative *forward guidance* (a `Next:` hint or a `via`/`run`/`invoke`/`use`
# verb immediately preceding the command). Descriptive mentions ("absorbs X",
# "relocated from X", "X is a deprecated alias") use no such verb and are not
# flagged. Deprecated set = the §5.12/§5.18 sunset aliases; extend when a new
# alias is retired. The alias's OWN command file is excluded.
S100_DEPRECATED="activate-directive triage"   # SPEC §5.12 / §5.18 deprecated aliases
s100d_hits=""
for dep in $S100_DEPRECATED; do
  while IFS= read -r hit; do
    [ -n "$hit" ] && s100d_hits="$s100d_hits\n$hit"
  done <<EOF100D
$(grep -rniE "(Next:|[^a-z](via|run|invoke|use)[^a-z])[^\`]*\`?/$dep\b" "$S100_CMDS" "$SHELL_ROOT/.claude/agents" 2>/dev/null \
   | grep -vE "commands/$dep\.md")
EOF100D
done
if [ -z "$s100d_hits" ]; then
  ok "100d: no command/agent forward-guidance steers to a deprecated alias (#377)"
else
  ng "100d: forward-guidance to a deprecated alias:$(printf '%b' "$s100d_hits") (#377)"
fi
# §100e — falsifiability: the same forward-guidance pattern matches a synthetic
# `Next: /activate-directive` line (proves 100d is not vacuously passing — this
# is the exact drift shape #376 redirected).
if printf 'Next: /activate-directive <N> when ready' \
   | grep -qiE "(Next:|[^a-z](via|run|invoke|use)[^a-z])[^\`]*\`?/activate-directive\b"; then
  ok "100e: deprecated-alias forward-guidance guard is falsifiable (#377)"
else
  ng "100e: forward-guidance guard fails to flag a synthetic Next:/activate-directive (#377)"
fi

# ---------- 101. /flush affordance + flush → clear → reconstruct lifecycle (#387, Directive #385) ----------
# Doc→Test→Code: this section is authored in the Test phase and FAILS until the
# Code phase adds .claude/commands/flush.md. Anti-vacuity (smoke.sh header): the
# skill-content greps anchor on the CONTRACT phrases the prose must carry
# (active→archived, the .claude/state/ durable target, the native-/clear
# non-invocation), not bare tokens; a missing flush.md fails LOUD via ng.

# §101a: /flush skill exists and declares the pre-clear archive contract.
S101_FLUSH="$SHELL_ROOT/.claude/commands/flush.md"
if [ -f "$S101_FLUSH" ] \
   && grep -q 'active → archived' "$S101_FLUSH" \
   && grep -q '\.claude/state/' "$S101_FLUSH" \
   && grep -qi 'does not.*invoke\|cannot.*invoke\|never.*invoke' "$S101_FLUSH" \
   && grep -q '/clear' "$S101_FLUSH"; then
  ok "101a: /flush skill declares active→archived flush into a durable artifact, no native /clear invocation (#387)"
else
  ng "101a: /flush skill missing or lacks the pre-clear archive contract (active→archived + .claude/state/ + no-native-/clear) (#387)"
fi

# §101b: SPEC §3.7 lifecycle section + §5.24 /flush roster entry present, and the
# TOC carries both rows (heading forms are caret-anchored so a prose mention of
# "3.7" cannot satisfy them).
if grep -qE '^### 3\.7 Context lifecycle: flush → clear → reconstruct' "$SHELL_ROOT/SPEC.md" \
   && grep -qE '^### 5\.24 ' "$SHELL_ROOT/SPEC.md" \
   && grep -qF '§3.7 | Context lifecycle: flush → clear → reconstruct' "$SHELL_ROOT/SPEC.md" \
   && grep -qF '§5.24 |' "$SHELL_ROOT/SPEC.md"; then
  ok "101b: SPEC §3.7 lifecycle + §5.24 /flush sections present in body and TOC (#387)"
else
  ng "101b: SPEC §3.7 / §5.24 heading or TOC row missing (#387)"
fi

# §101c: SPEC TOC is in sync (build_toc.sh --check passes) — adding the headings
# without regenerating the TOC must redden, same guarantee as §28.
if bash "$SHELL_ROOT/scripts/build_toc.sh" --check >/dev/null 2>&1; then
  ok "101c: SPEC TOC in sync after §3.7/§5.24 additions (#387)"
else
  ng "101c: SPEC TOC out of sync — rerun scripts/build_toc.sh (#387)"
fi

# ---------- 102. in-session narrowing levers: SPEC §1.8 + PostToolUse Read nudge (#389, Directive #386) ----------
# Doc→Test→Code: authored in the Test phase; §102b FAILS until the Code phase
# adds the Read arm to post_tool_use.sh. Anti-vacuity (smoke.sh header): §102a
# heading greps are caret-anchored; §102b/c drive the real hook and assert the
# nudge text on stderr (102b) AND its absence under offset/limit (102c) — a
# falsifiable pair, not a one-sided presence check.

# §102a: SPEC §1.8 narrowing-levers section + §6.2 Read-nudge row present, TOC in sync.
if grep -qE '^### 1\.8 In-session narrowing levers' "$SHELL_ROOT/SPEC.md" \
   && grep -qF '§1.8 | In-session narrowing levers' "$SHELL_ROOT/SPEC.md" \
   && grep -qE '\| `Read` of a whole file' "$SHELL_ROOT/SPEC.md" \
   && bash "$SHELL_ROOT/scripts/build_toc.sh" --check >/dev/null 2>&1; then
  ok "102a: SPEC §1.8 levers inventory + §6.2 Read-nudge row present, TOC in sync (#389)"
else
  ng "102a: SPEC §1.8 / §6.2 Read-nudge row missing or TOC out of sync (#389)"
fi

# Driver: pipe a synthetic Read tool_input through post_tool_use.sh from an
# in-scope cwd ($SHELL_ROOT), capturing stderr (the nudge surface) like post_run.
read_nudge_run() {
  local json_input="$1"
  (
    cd "$SHELL_ROOT" || exit 1
    # shellcheck disable=SC2069
    printf '{"tool_name":"Read","tool_input":%s}' "$json_input" \
      | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" bash "$SHELL_ROOT/.claude/hooks/post_tool_use.sh" 2>&1 >/dev/null
  )
}
# SPEC.md is a large (>200-line) in-scope file — the whole-file-load case.
S102_BIGFILE="$SHELL_ROOT/SPEC.md"

# §102b: whole-file Read (no offset/limit) on a large file → nudge fires, rc==0 (positive, non-blocking).
b_out=$(read_nudge_run "{\"file_path\":\"$S102_BIGFILE\"}"); b_rc=$?
if printf '%s' "$b_out" | grep -q 'Read --offset' && [ "$b_rc" = 0 ]; then
  ok "102b: whole-file Read nudges toward a targeted read, non-blocking (rc=0) (#389)"
else
  ng "102b: whole-file Read did not emit the targeted-read nudge at rc=0 (rc=$b_rc) (#389)"
fi

# §102c: falsifiability — the SAME large file Read WITH offset+limit must NOT nudge.
c_out=$(read_nudge_run "{\"file_path\":\"$S102_BIGFILE\",\"offset\":1,\"limit\":40}"); c_rc=$?
if ! printf '%s' "$c_out" | grep -q 'Read --offset' && [ "$c_rc" = 0 ]; then
  ok "102c: targeted Read (offset+limit) suppresses the nudge — guard is falsifiable (#389)"
else
  ng "102c: targeted Read still nudged (or non-zero rc=$c_rc) — guard not offset-aware (#389)"
fi

# ---------- §103 (#392): SPEC §8 directory tree drift-guard (flat-dir leaf counts) ----------
# SPEC §8's "Directory structure" block is authoritative. The four flat leaf-list
# directories (agents/, commands/, helpers/, docs/) are count-checked against disk,
# so a PR that adds/removes an agent/command/helper/doc without updating §8 is caught.
# templates/ and scripts/ carry summarized subtree nodes (leaves churn independently)
# — those are asserted present as text (node-presence), not leaf-counted.
#
# Parsing: slice the §8 fenced block (between the first ``` after the "## 8." heading
# and the next ```), then for each dir count the leaf lines between its node header
# and the next sibling node. awk reads files directly and uses range patterns with
# `exit` — no `... | head` pipe (which SIGPIPEs the upstream under pipefail and fails
# nondeterministically by size, GNU vs BSD). The dir-header line is excluded from its
# own range (consumed by `next`), so an annotation like "← 9 subagents" on the header
# can't be miscounted as a leaf.
S103_SPEC="$SHELL_ROOT/SPEC.md"
S103_BLOCK=$(awk '
  /^## 8\. Directory structure/ {ins=1}
  ins && /^## 9\./ {exit}
  ins
' "$S103_SPEC" | awk '
  /^```/ {fence++; next}
  fence==1 {print}
')

# s103_count <start_re> <end_re> <leaf_re>: count leaf lines strictly between the
# start-marker line (exclusive) and the first end-marker line (exclusive). An end_re
# that never matches counts through end-of-block (used for the last node, docs/).
s103_count() {
  printf '%s\n' "$S103_BLOCK" | awk -v sre="$1" -v ere="$2" -v lre="$3" '
    $0 ~ sre {inrange=1; next}
    inrange && $0 ~ ere {exit}
    inrange && $0 ~ lre {n++}
    END {print n+0}
  '
}

# Listed counts from the §8 block. Ranges delimited by the next sibling node:
#   agents/ → commands/ ; commands/ → hooks/ ; helpers/ → templates/ ; docs/ → EOF.
S103_A_SPEC=$(s103_count '├── agents/'   '├── commands/'  '\.md')
S103_C_SPEC=$(s103_count '├── commands/' '├── hooks/'     '\.md')
S103_H_SPEC=$(s103_count '└── helpers/'  '├── templates/' '\.sh')
S103_D_SPEC=$(s103_count '└── docs/'     '^```NEVER```'   '\.md')

# Actual disk counts. ls into wc — globs that match nothing degrade to 0.
s103_disk() { ls "$@" 2>/dev/null | wc -l | tr -d ' '; }
S103_A_DISK=$(s103_disk "$SHELL_ROOT"/.claude/agents/*.md)
S103_C_DISK=$(s103_disk "$SHELL_ROOT"/.claude/commands/*.md)
S103_H_DISK=$(s103_disk "$SHELL_ROOT"/.claude/hooks/helpers/*.sh)
S103_D_DISK=$(s103_disk "$SHELL_ROOT"/docs/*.md)

S103_DRIFT=""
[ "$S103_A_SPEC" = "$S103_A_DISK" ] || S103_DRIFT="$S103_DRIFT agents(§8=$S103_A_SPEC,disk=$S103_A_DISK)"
[ "$S103_C_SPEC" = "$S103_C_DISK" ] || S103_DRIFT="$S103_DRIFT commands(§8=$S103_C_SPEC,disk=$S103_C_DISK)"
[ "$S103_H_SPEC" = "$S103_H_DISK" ] || S103_DRIFT="$S103_DRIFT helpers(§8=$S103_H_SPEC,disk=$S103_H_DISK)"
[ "$S103_D_SPEC" = "$S103_D_DISK" ] || S103_DRIFT="$S103_DRIFT docs(§8=$S103_D_SPEC,disk=$S103_D_DISK)"

if [ -z "$S103_DRIFT" ]; then
  ok "103a: SPEC §8 flat-dir leaf counts match disk (agents/commands/helpers/docs) (#392)"
else
  ng "103a: SPEC §8 directory tree drifted from disk —$S103_DRIFT (#392)"
fi

# §103b: node-presence for the summarized subtrees (cheap, robust — text not counts).
# templates/ summarizes target-substrate/; scripts/ summarizes lib/ + test/.
if printf '%s\n' "$S103_BLOCK" | grep -qF 'target-substrate/' \
   && printf '%s\n' "$S103_BLOCK" | grep -qF 'lib/' \
   && printf '%s\n' "$S103_BLOCK" | grep -qF 'test/'; then
  ok "103b: SPEC §8 summarized subtree nodes present (target-substrate/, lib/, test/) (#392)"
else
  ng "103b: SPEC §8 missing a summarized subtree node (target-substrate/ / lib/ / test/) (#392)"
fi

# §103c: scripts/ TOP-LEVEL *.sh listing exactness + stale-count guard. Unlike the
# summarized lib//test/ nodes (103b, node-presence only), the top-level scripts ARE
# enumerated leaf-by-leaf in §8, so a script added/removed without a §8 edit must be
# caught. Slice the scripts/ node (├── scripts/ → next top-level sibling ├── workspace/)
# via the awk-range idiom, then RESTRICT to the top level by stopping at the lib/ node —
# so the deeper test/smoke.sh leaf never enters the listed set. Extract basenames, diff
# both directions against disk, and pin the "<N> top-level scripts" header integer.
S103C_SLICE=$(printf '%s\n' "$S103_BLOCK" | awk '
  /├── scripts\// {inrange=1}
  inrange && /│   ├── lib\// {exit}
  inrange
')
S103C_LISTED=$(printf '%s\n' "$S103C_SLICE" | grep -oE '[A-Za-z0-9_.-]+\.sh' | sort -u)
S103C_DISK=$(for f in "$SHELL_ROOT"/scripts/*.sh; do basename "$f"; done | sort -u)
S103C_LISTED_F=$(mktemp); S103C_DISK_F=$(mktemp)
printf '%s\n' "$S103C_LISTED" > "$S103C_LISTED_F"
printf '%s\n' "$S103C_DISK"   > "$S103C_DISK_F"
# comm -3: col1 = listed-only (in §8, not on disk); col2 = disk-only (on disk, not §8).
S103C_ONLY_SPEC=$(comm -23 "$S103C_LISTED_F" "$S103C_DISK_F" | tr '\n' ' ' | tr -s ' ')
S103C_ONLY_DISK=$(comm -13 "$S103C_LISTED_F" "$S103C_DISK_F" | tr '\n' ' ' | tr -s ' ')
rm -f "$S103C_LISTED_F" "$S103C_DISK_F"
S103C_HDR=$(printf '%s\n' "$S103C_SLICE" | grep -oE '[0-9]+ top-level scripts' | grep -oE '^[0-9]+')
S103C_NDISK=$(ls "$SHELL_ROOT"/scripts/*.sh 2>/dev/null | wc -l | tr -d ' ')
S103C_DRIFT=""
[ -z "$(printf '%s' "$S103C_ONLY_SPEC" | tr -d ' ')" ] || S103C_DRIFT="$S103C_DRIFT listed-not-on-disk:$S103C_ONLY_SPEC"
[ -z "$(printf '%s' "$S103C_ONLY_DISK" | tr -d ' ')" ] || S103C_DRIFT="$S103C_DRIFT on-disk-not-listed:$S103C_ONLY_DISK"
[ "$S103C_HDR" = "$S103C_NDISK" ] || S103C_DRIFT="$S103C_DRIFT count(§8=${S103C_HDR:-unparsed},disk=$S103C_NDISK)"
if [ -z "$S103C_DRIFT" ]; then
  ok "103c: SPEC §8 scripts/ top-level *.sh listing + count match disk (#473)"
else
  ng "103c: SPEC §8 scripts/ top-level listing drifted from disk —$S103C_DRIFT (#473)"
fi

# ---------- §104 (#396): always-on injection budget — CLAUDE.md pointer-index discipline ----------
# CLAUDE.md is injected into every session, so it is pure always-on cost. The
# rewrite (#396) turned it into a thin pointer index whose contracts live in full
# in SPEC; two guards keep it from re-bloating back into a second copy.
S104_CLAUDE="$SHELL_ROOT/.claude/CLAUDE.md"

# §104a (PRIMARY, mirror §91): every matcher/mechanism entry in the
# "## What hooks enforce" section must carry a `SPEC §` reference — so each pointer
# names its canonical home and cannot quietly grow into standalone contract prose.
# Scope to the section via heading anchors ("## What hooks enforce" → next "## ").
# Only `- ` bullet lines inside that range are checked (the intro + Escape paragraphs
# reference SPEC § too, but bullets are the matcher pointers we pin). awk reads the
# file directly and collects EVERY offending entry — no `... | head` pipe (which
# would SIGPIPE the upstream under `set -o pipefail` and fail by size, GNU vs BSD)
# and no first-failure short-circuit.
S104A_FAIL=$(awk '
  /^## What hooks enforce/ {ins=1; next}
  ins && /^## / {exit}
  ins && /^- / {
    if (index($0, "SPEC §") == 0) {
      # name the offending entry by its leading bold token if present, else the line
      tok = $0
      if (match($0, /\*\*[^*]+\*\*/)) tok = substr($0, RSTART+2, RLENGTH-4)
      print tok
    }
  }
' "$S104_CLAUDE")
if [ -z "$S104A_FAIL" ]; then
  ok "104a: every '## What hooks enforce' bullet in CLAUDE.md carries a SPEC § reference (#396)"
else
  ng "104a: CLAUDE.md 'What hooks enforce' bullets missing a SPEC § reference: $(printf '%s' "$S104A_FAIL" | tr '\n' ';') (#396)"
fi

# §104b (SECONDARY, mirror §103 numeric style): always-on byte ceiling. SPEC §9
# records a ≤12000-byte budget for the injected CLAUDE.md; over → re-bloat regression.
S104_BYTES=$(wc -c < "$S104_CLAUDE" 2>/dev/null | tr -d ' '); [ -z "$S104_BYTES" ] && S104_BYTES=0
if [ "$S104_BYTES" -le 12000 ]; then
  ok "104b: CLAUDE.md within the always-on injection budget — ${S104_BYTES} ≤ 12000 bytes (SPEC §9) (#396)"
else
  ng "104b: CLAUDE.md over the always-on injection budget — ${S104_BYTES} > 12000 bytes (SPEC §9 re-bloat) (#396)"
fi

# ---------- §105 (#398): friction-observability loop closure — SessionStart §6.5(d) advisory + §5.7.1 park→audit bridge ----------
# The §6.5(d) friction-candidate advisory is the consumer that completes §6.0 P3's
# deferred-positive-face loop: a once-per-session, non-blocking, fail-open, TTL-gated
# ONE-LINE pointer emitted by session_start.sh when the candidate readers surface a
# cluster OR the audit aggregate carries `unattended-park` records; suppressed when
# nothing clusters. §5.7.1 additionally bridges a fresh park into audit.jsonl via an
# `audit_log warn unattended-park parked` emit. All fixtures live in mktemp dirs and
# point the advisory's per-project audit read at a fixture via GHJIG_STATE_DIR_OVERRIDE
# / an explicit log path — the live $SHELL_ROOT state + audit log are never touched
# (§357 AC1 stays green). The advisory CODE is Phase C: 105b/d-advisory/e(ii,iii) are
# intended-RED until it lands; 105a (Doc) + the fail-open/exit-0 arm of 105d are green.

# §105a (Doc/TOC presence; green now — Phase A landed): SPEC §6.5(d) advisory contract
# present with its key tokens, §5.7.1 documents the additive unattended-park emit, and
# the TOC is fresh.
S105_SPEC="$SHELL_ROOT/SPEC.md"
if grep -q 'Friction-candidate advisory' "$S105_SPEC" \
   && grep -q 'SESSION_START_FRICTION_TTL' "$S105_SPEC" \
   && grep -q 'last-friction-surfaced' "$S105_SPEC" \
   && grep -q 'unattended-park' "$S105_SPEC" \
   && bash "$SHELL_ROOT/scripts/build_toc.sh" --check >/dev/null 2>&1; then
  ok "105a: SPEC §6.5(d) advisory contract + §5.7.1 unattended-park emit present, TOC fresh (#398)"
else
  ng "105a: SPEC §6.5(d)/§5.7.1 friction-loop contract incomplete or TOC stale (#398)"
fi

# Shared fake-root driver for 105b/c/d (mirror §30): a self-contained shell copy with
# its own git repo + registry, so session_start.sh reaches the §6.5(d) advisory block.
# The advisory reads the per-project audit aggregate via ghjig_state_dir; we point that
# at a per-call fixture state dir through GHJIG_STATE_DIR_OVERRIDE. A git shim no-ops the
# self-sync fetch so the run stays offline and fast.
S105_PROBE=$(mktemp -d)
S105_FAKE_ROOT="$S105_PROBE/shell"
mkdir -p "$S105_FAKE_ROOT/.claude/hooks/helpers" \
         "$S105_FAKE_ROOT/.claude/state" \
         "$S105_FAKE_ROOT/.claude/audit" \
         "$S105_FAKE_ROOT/scripts/lib"
cp "$SHELL_ROOT/.claude/hooks/session_start.sh" "$S105_FAKE_ROOT/.claude/hooks/"
cp "$SHELL_ROOT/.claude/hooks/hookrt.sh" "$S105_FAKE_ROOT/.claude/hooks/" 2>/dev/null
for h in log escape cwd_guard branch_guard; do
  cp "$SHELL_ROOT/.claude/hooks/helpers/$h.sh" "$S105_FAKE_ROOT/.claude/hooks/helpers/" 2>/dev/null
done
# Carry the candidate readers + their path lib so the advisory can invoke them in-root.
cp "$SHELL_ROOT/scripts/narrowing_candidates.sh" "$S105_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/promotion_candidates.sh" "$S105_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/ceremony_candidates.sh" "$S105_FAKE_ROOT/scripts/" 2>/dev/null
cp "$SHELL_ROOT/scripts/lib/audit_log_path.sh" "$S105_FAKE_ROOT/scripts/lib/" 2>/dev/null
: > "$S105_FAKE_ROOT/.claude/state/registry.txt"
(
  cd "$S105_FAKE_ROOT" || exit 1
  git init -q
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
)
S105_GIT_SHIM="$S105_PROBE/bin"
REAL_GIT_105=$(command -v git)
mkdir -p "$S105_GIT_SHIM"
cat > "$S105_GIT_SHIM/git" <<SHIM
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = "fetch" ]; then exit 0; fi
done
exec '$REAL_GIT_105' "\$@"
SHIM
chmod +x "$S105_GIT_SHIM/git"

# run_friction_session <state-dir> <ttl> — drive session_start.sh against a fixture
# per-project state dir (its audit/audit.jsonl is the aggregate the advisory reads)
# and capture stdout (the advisory surfaces at SessionStart). Returns the captured
# text via stdout; exit status is the hook's.
run_friction_session() {
  (
    export GHJIG_ROOT_OVERRIDE="$S105_FAKE_ROOT"
    export PATH="$S105_GIT_SHIM:$PATH"
    # Point the ceremony reader (#401) at the fixture repo (only an empty init commit,
    # no ceremony groups) so it stays silent and does not scan the real repo's history.
    export CLAUDE_PROJECT_DIR="$S105_FAKE_ROOT"
    export GHJIG_STATE_DIR_OVERRIDE="$1"
    export SESSION_START_FRICTION_TTL="${2:-21600}"
    # keep the self-sync stamp fresh so only the friction path varies
    touch "$S105_FAKE_ROOT/.claude/state/last-shell-fetched" 2>/dev/null
    bash "$S105_FAKE_ROOT/.claude/hooks/session_start.sh" 2>/dev/null
  )
}

if [ ! -f "$S105_FAKE_ROOT/.claude/hooks/session_start.sh" ] || ! command -v jq >/dev/null 2>&1; then
  ng "105b: jq missing or fake-root setup failed — cannot drive the §6.5(d) advisory (#398)"
  ng "105c: jq missing or fake-root setup failed (#398)"
  ng "105d: jq missing or fake-root setup failed (#398)"
else
  # §105b (surfacing fires; RED until Code): a per-project audit log with an above-
  # threshold escape cluster (force-push, 2 distinct LIVE days — narrowing_candidates.sh
  # thresholds on >=2 distinct UTC days) + no friction stamp → the advisory line appears.
  S105B_STATE="$S105_PROBE/state-b"
  mkdir -p "$S105B_STATE/audit"
  cat > "$S105B_STATE/audit/audit.jsonl" <<'S105FIX'
{"ts":"2026-06-01T10:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
{"ts":"2026-06-02T11:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
S105FIX
  rm -f "$S105B_STATE/last-friction-surfaced"
  s105b_out=$(run_friction_session "$S105B_STATE" 21600)
  if printf '%s\n' "$s105b_out" | grep -qi 'friction'; then
    ok "105b: §6.5(d) advisory surfaces a one-line friction pointer on a clustered audit log (#398)"
  else
    ng "105b: §6.5(d) advisory did not surface on the clustered audit log — Phase C not yet landed (#398)"
  fi

  # §105c (suppressed — falsifiable twin): an audit log with NO above-threshold cluster
  # (a single force-push day → below threshold 2) and NO unattended-park records → no
  # advisory line. Pre-Code this may pass vacuously (nothing is emitted yet); its real
  # value is post-Code as the falsifiable companion to 105b. Robust absence assertion:
  # the captured text must not contain a friction pointer line.
  S105C_STATE="$S105_PROBE/state-c"
  mkdir -p "$S105C_STATE/audit"
  cat > "$S105C_STATE/audit/audit.jsonl" <<'S105FIX'
{"ts":"2026-06-01T10:00:00Z","event":"escape","category":"force-push","decision":"skip","reason":"rebase tail","cwd":"/x","source":"live"}
S105FIX
  rm -f "$S105C_STATE/last-friction-surfaced"
  s105c_out=$(run_friction_session "$S105C_STATE" 21600)
  if printf '%s\n' "$s105c_out" | grep -qi 'friction'; then
    ng "105c: §6.5(d) advisory fired with NO above-threshold cluster (should be suppressed) (#398)"
  else
    ok "105c: §6.5(d) advisory stays silent when nothing clusters (falsifiable twin) (#398)"
  fi

  # §105d(i) (TTL-skip; RED until Code): clustered data BUT a fresh stamp (mtime now) →
  # the advisory is skipped (compute runs only when the stamp is stale/absent). Reuses
  # the 105b clustered fixture with a freshly-touched stamp.
  S105D_STATE="$S105_PROBE/state-d"
  mkdir -p "$S105D_STATE/audit"
  cp "$S105B_STATE/audit/audit.jsonl" "$S105D_STATE/audit/audit.jsonl"
  touch "$S105D_STATE/last-friction-surfaced"
  s105d_out=$(run_friction_session "$S105D_STATE" 21600)
  if printf '%s\n' "$s105d_out" | grep -qi 'friction'; then
    ng "105d(i): §6.5(d) advisory fired despite a fresh TTL stamp (should skip) (#398)"
  else
    ok "105d(i): §6.5(d) advisory honors the fresh last-friction-surfaced stamp (TTL-skip) (#398)"
  fi

  # §105d(ii) (fail-open / no-stall; holds regardless, partly inherent): an ABSENT audit
  # log (state dir exists, no audit.jsonl) with no stamp must not stall or crash —
  # session_start.sh still exits 0. Exercises the advisory path's degrade-to-silence arm.
  S105D2_STATE="$S105_PROBE/state-d2"
  mkdir -p "$S105D2_STATE"
  rm -f "$S105D2_STATE/last-friction-surfaced"
  run_friction_session "$S105D2_STATE" 21600 >/dev/null 2>&1; s105d2_rc=$?
  if [ "$s105d2_rc" = 0 ]; then
    ok "105d(ii): session_start exits 0 (fail-open, no stall) when the audit aggregate is absent (#398)"
  else
    ng "105d(ii): session_start did not exit 0 with an absent audit aggregate (rc=$s105d2_rc) (#398)"
  fi
fi
rm -rf "$S105_PROBE"

# §105e (park reaches audit + friction view): ship_park_pr on a FRESH park appends the
# human-readable park-log line (unchanged, additive contract) AND — Phase C — emits one
# `audit_log warn unattended-park parked "reason=<token>"` record into audit.jsonl, so
# park frequency becomes greppable as the §6.5(d) park-frequency signal. (ii)/(iii) are
# RED until the additive emit lands; (i) holds today. Run from a non-repo cwd so the
# `gh pr view` label check yields empty (no real PR) → the fresh-park arm.
if ! command -v jq >/dev/null 2>&1; then
  ng "105e(i): jq missing — cannot run the park→audit bridge check (#398)"
  ng "105e(ii): jq missing (#398)"
  ng "105e(iii): jq missing (#398)"
else
  S105E_DIR=$(mktemp -d)
  S105E_PARKLOG="$S105E_DIR/park.log"
  S105E_STATE="$S105E_DIR/ghjig-state"
  mkdir -p "$S105E_STATE/audit"
  (
    cd "$S105E_DIR" || exit 1
    export GHJIG_ROOT="$SHELL_ROOT"
    export GHJIG_STATE_DIR_OVERRIDE="$S105E_STATE"   # audit_log writes here
    export SHIP_PARK_LOG_PATH="$S105E_PARKLOG"     # park-log isolation seam
    # shellcheck source=/dev/null
    . "$SHELL_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null
    # shellcheck source=/dev/null
    . "$SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh" 2>/dev/null
    ship_park_pr ci-hard-blocker >/dev/null 2>&1
  )
  S105E_AUDIT="$S105E_STATE/audit/audit.jsonl"
  # (i) park-log line still appears (additive, unchanged).
  if [ -f "$S105E_PARKLOG" ] && grep -q 'parked reason=ci-hard-blocker' "$S105E_PARKLOG"; then
    ok "105e(i): ship_park_pr still writes the human-readable park-log line (additive) (#398)"
  else
    ng "105e(i): ship_park_pr did not write the expected park-log line (#398)"
  fi
  # (ii) an unattended-park/parked record landed in audit.jsonl (RED until Code).
  if [ -f "$S105E_AUDIT" ] \
     && grep -v '^[[:space:]]*$' "$S105E_AUDIT" \
        | jq -e 'select(.category=="unattended-park" and .decision=="parked")' >/dev/null 2>&1; then
    ok "105e(ii): fresh park emits an unattended-park/parked record into audit.jsonl (#398)"
  else
    ng "105e(ii): no unattended-park/parked audit record — §5.7.1 bridge not yet landed (#398)"
  fi
  # (iii) that record is greppable as the park-frequency signal the §6.5(d) advisory reads.
  if [ -f "$S105E_AUDIT" ] && grep -q 'unattended-park' "$S105E_AUDIT"; then
    ok "105e(iii): the park record is greppable as the park-frequency signal (#398)"
  else
    ng "105e(iii): park-frequency signal not greppable in audit.jsonl (#398)"
  fi
  rm -rf "$S105E_DIR"
fi

# ---------- §106 (#393): SPEC §9 specs exist for every referenced template ----------
# Contract-hygiene: directive.md / spec.md / readme_for_target.md are referenced
# in prose but historically lacked §9.x body-specs. Guard the three §9.6-9.8
# headings (presence only — cheap, stable) so they cannot silently regress, and
# confirm the TOC stays in sync after the heading additions.
if grep -qE '^### 9\.6 `directive\.md`'          "$SHELL_ROOT/SPEC.md" \
   && grep -qE '^### 9\.7 `spec\.md`'            "$SHELL_ROOT/SPEC.md" \
   && grep -qE '^### 9\.8 `readme_for_target\.md`' "$SHELL_ROOT/SPEC.md" \
   && bash "$SHELL_ROOT/scripts/build_toc.sh" --check >/dev/null 2>&1; then
  ok "106: SPEC §9.6/§9.7/§9.8 specs present for directive/spec/readme_for_target templates, TOC in sync (#393)"
else
  ng "106: SPEC §9 spec missing for a referenced template (directive/spec/readme_for_target) or TOC out of sync (#393)"
fi

# ---------- §107 (#401): ceremony mis-sizing audit consumer (measure-first) ----------
# scripts/ceremony_candidates.sh is a §6.5(d) friction reader that, unlike the two
# audit-log siblings, mines COMMIT HISTORY (the ceremony signal is not in audit.jsonl).
# It groups commits by #<issue> and surfaces both directions: under-ceremony (a feat
# group >1 file with no test/docs phase commit) and over-ceremony (a >=3-commit phase
# arc over a single file). 107a is Doc-phase (green now); 107b-f are RED until Code.

# 107a (Doc; green now — Phase A landed): SPEC §6.5(d) + §6.0 P3 name the reader, the
# scripts tree lists it, and CONFIG catalogs its env knobs.
if grep -q 'ceremony_candidates.sh' "$SHELL_ROOT/SPEC.md" \
   && grep -q 'Ceremony-mismatch line' "$SHELL_ROOT/SPEC.md" \
   && grep -q 'CEREMONY_LOOKBACK' "$SHELL_ROOT/docs/CONFIG.md" \
   && grep -q 'CEREMONY_MIN_COUNT' "$SHELL_ROOT/docs/CONFIG.md"; then
  ok "107a: SPEC §6.5(d)/§6.0 P3 name ceremony_candidates.sh + CONFIG catalogs its knobs (#401)"
else
  ng "107a: SPEC/CONFIG do not fully document the ceremony reader (#401)"
fi

S107_SCRIPT="$SHELL_ROOT/scripts/ceremony_candidates.sh"
if [ ! -f "$S107_SCRIPT" ]; then
  ng "107b: scripts/ceremony_candidates.sh missing — Code not yet landed (#401)"
  ng "107c: over-ceremony detection — script missing (#401)"
  ng "107d: well-sized omitted + clean sentinel + exit 0 — script missing (#401)"
  ng "107e: non-repo/absent dir graceful exit 0 — script missing (#401)"
  ng "107f: session_start.sh wires the reader into the §6.5(d) advisory — Code not landed (#401)"
else
  # Synthetic git fixture: three #<issue> groups exercising both flags + the well-sized
  # negative. Offline, local git only (mirror §105's init style).
  S107_DIR=$(mktemp -d)
  S107_REPO="$S107_DIR/repo"
  mkdir -p "$S107_REPO"
  (
    cd "$S107_REPO" || exit 1
    git init -q
    gc() { git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q "$@"; }
    # #901 under-ceremony: a feat over 2 files, no test/docs phase commit.
    printf 'a\n' > a.sh; printf 'b\n' > b.sh; git add a.sh b.sh; gc -m 'feat(#901): two-file feature, no phasing'
    # #902 over-ceremony: a docs+test+code arc, all over ONE file.
    printf '1\n' > tiny.sh; git add tiny.sh; gc -m 'docs(#902): tiny doc'
    printf '2\n' >> tiny.sh; git add tiny.sh; gc -m 'test(#902): tiny test'
    printf '3\n' >> tiny.sh; git add tiny.sh; gc -m 'feat(#902): tiny code'
    # #903 well-sized: a feat WITH test+docs phase commits over multiple files → omitted.
    printf 'f1\n' > f1.sh; printf 'f2\n' > f2.sh; git add f1.sh f2.sh; gc -m 'feat(#903): multi-file feature'
    printf 't\n' > t1.sh; git add t1.sh; gc -m 'test(#903): tests'
    printf 'd\n' > d1.md; git add d1.md; gc -m 'docs(#903): docs'
  )
  s107_out=$(bash "$S107_SCRIPT" "$S107_REPO" 2>/dev/null); s107_rc=$?

  # 107b: under-ceremony group #901 surfaced.
  if [ "$s107_rc" = 0 ] && printf '%s\n' "$s107_out" | grep -q '901' \
     && printf '%s\n' "$s107_out" | grep -qi 'under'; then
    ok "107b: surfaces the under-ceremony #901 cluster (feat, >1 file, no phase commit) (#401)"
  else
    ng "107b: did not surface the under-ceremony #901 cluster (rc=$s107_rc) (#401)"
  fi
  # 107c: over-ceremony group #902 surfaced.
  if printf '%s\n' "$s107_out" | grep -q '902' && printf '%s\n' "$s107_out" | grep -qi 'over'; then
    ok "107c: surfaces the over-ceremony #902 cluster (phase arc over a single file) (#401)"
  else
    ng "107c: did not surface the over-ceremony #902 cluster (#401)"
  fi
  # 107d: well-sized #903 omitted; clean repo → sentinel; exit 0; output is the indented
  # cluster shape the §6.5(d) grep keys on.
  s107_clean=$(mktemp -d)
  ( cd "$s107_clean" && git init -q && git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m 'chore: init' )
  s107_clean_out=$(bash "$S107_SCRIPT" "$s107_clean" 2>/dev/null); s107_clean_rc=$?
  if ! printf '%s\n' "$s107_out" | grep -q '903' \
     && printf '%s\n' "$s107_out" | grep -qE '^[[:space:]]+.+\|.+=' \
     && [ "$s107_clean_rc" = 0 ] \
     && printf '%s\n' "$s107_clean_out" | grep -qi 'none'; then
    ok "107d: omits the well-sized #903 group, emits the grep-shaped cluster + clean sentinel, exit 0 (#401)"
  else
    ng "107d: well-sized group leaked, wrong output shape, or no clean sentinel (clean_rc=$s107_clean_rc) (#401)"
  fi
  # 107e: a non-repo dir and an absent dir both degrade to silence, exit 0 (fail-open).
  bash "$S107_SCRIPT" "$S107_DIR" >/dev/null 2>&1; s107_e1=$?     # exists, not a git repo
  bash "$S107_SCRIPT" "$S107_DIR/nope" >/dev/null 2>&1; s107_e2=$? # absent
  if [ "$s107_e1" = 0 ] && [ "$s107_e2" = 0 ]; then
    ok "107e: degrades to exit 0 on a non-repo dir and an absent dir (fail-open) (#401)"
  else
    ng "107e: crashed on non-repo/absent dir (non-repo=$s107_e1 absent=$s107_e2) (#401)"
  fi
  # 107f: the §6.5(d) advisory invokes the reader (Code wires it into session_start.sh).
  if grep -q 'ceremony_candidates.sh' "$SHELL_ROOT/.claude/hooks/session_start.sh"; then
    ok "107f: session_start.sh wires ceremony_candidates.sh into the friction advisory (#401)"
  else
    ng "107f: session_start.sh does not invoke ceremony_candidates.sh — advisory not wired (#401)"
  fi
  rm -rf "$S107_DIR" "$s107_clean"
fi

# ---------- §108 (#403): commit-arm does not false-positive on heredoc DATA ----------
# The protected-branch commit sub-arm (pre_tool_use.sh:894) must enter on a REAL
# `git commit` invocation, NOT on the bytes "git commit" inside a heredoc DATA body
# (e.g. `gh issue edit --body "$(cat <<'EOF' ... git commit ... EOF)"`, the real #403
# trigger). The entry uses strip_command_data HEREDOC mode (matching clean :198 /
# merge :333) — under-block-safe, because bash executes command substitutions inside
# double quotes, so `full` mode (which strips quoted interiors) would HIDE a real
# `"$(git commit)"` from the grep while bash still runs it. 108a: heredoc-body
# false-positive allowed (RED pre-fix). 108b/108c: no-under-block guards (a real
# plain commit AND a real commit inside a double-quoted substitution both still block).
if ! command -v jq >/dev/null 2>&1; then
  ng "108a: jq missing — cannot drive the commit-arm DATA test (#403)"
  ng "108b: jq missing (#403)"
else
  S108_DIR=$(mktemp -d)
  S108_TARGET="$S108_DIR/target"
  mkdir -p "$S108_TARGET"
  S108_TARGET=$(cd "$S108_TARGET" && pwd -P)
  (cd "$S108_TARGET" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; })
   git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
  printf '%s\n' "$S108_TARGET" >> "$SMOKE_REG"

  s108_bash_run() {
    local cmd="$1"
    ( cd "$S108_TARGET" || exit 1
      jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 )
    return $?
  }

  # 108a: a gh-issue-edit whose --body carries the git+commit token inside a HEREDOC
  #       body, run on the protected (main) fixture → must be ALLOWED (rc=0). The
  #       real #403 trigger. RED pre-fix.
  sq="'"
  s108_data_cmd="gh issue edit 1 --body \"\$(cat <<${sq}EOF${sq}
prose that merely mentions a git commit invocation inside a heredoc body
EOF
)\""
  s108_bash_run "$s108_data_cmd"; s108a_rc=$?
  if [ "$s108a_rc" = 0 ]; then
    ok "108a: commit arm ignores 'git commit' inside a heredoc --body (no false-positive) (#403)"
  else
    ng "108a: commit arm false-positives on 'git commit' in a heredoc --body (rc=$s108a_rc, want 0) (#403)"
  fi

  # 108b (no under-block): a REAL plain commit on the protected branch still blocks (rc=2).
  s108_real_cmd="git commit -m 'feat(#403): real subject'"
  s108_bash_run "$s108_real_cmd"; s108b_rc=$?
  if [ "$s108b_rc" = 2 ]; then
    ok "108b: a real plain git commit on a protected branch still blocks (no under-block) (#403)"
  else
    ng "108b: real protected-branch commit not blocked (rc=$s108b_rc, want 2) (#403)"
  fi

  # 108c (no under-block — the security-review case): a real commit inside a
  #       DOUBLE-QUOTED command substitution still blocks (rc=2). heredoc mode leaves
  #       "$(...)" intact, so the grep still sees the live invocation; `full` mode
  #       would have stripped it and let a real protected-branch commit slip (rc=0).
  s108_subst_cmd='echo "$(git commit --allow-empty -m sneaky)"'
  s108_bash_run "$s108_subst_cmd"; s108c_rc=$?
  if [ "$s108c_rc" = 2 ]; then
    ok "108c: a real commit inside a double-quoted \$() substitution still blocks (no under-block) (#403)"
  else
    ng "108c: commit in double-quoted \$() slipped past the protected-branch gate (rc=$s108c_rc, want 2) (#403)"
  fi
  rm -rf "$S108_DIR"
fi

# ---------- §150 (#605): --no-verify arm does not false-positive on heredoc DATA ----------
# Sibling to §108 (#403): the --no-verify matcher arm (pre_tool_use.sh:1204) scans the
# RAW $cmd for `git ... commit ... --no-verify`, unlike every neighbouring arm (the clean
# :198, merge :333, and the adjacent commit-umbrella :1250) which first pass raw_cmd
# through strip_command_data. So a NON-git command whose heredoc DATA body merely mentions
# the tokens `git commit ... --no-verify` on one line false-trips the `--no-verify blocked`
# block. The Code fix gates the entry on strip_command_data "$raw_cmd" heredoc (heredoc
# mode — matching the sibling arms; under-block-safe because a real "$(git commit --no-verify)"
# substitution is left intact). 150a: heredoc-body false-positive must be ALLOWED (RED
# pre-fix). 150b: no-under-block guard — a real trailing `--no-verify` flag still blocks.
if ! command -v jq >/dev/null 2>&1; then
  ng "150a: jq missing — cannot drive the --no-verify DATA test (#605)"
  ng "150b: jq missing (#605)"
else
  S150_DIR=$(mktemp -d)
  S150_TARGET="$S150_DIR/target"
  mkdir -p "$S150_TARGET"
  S150_TARGET=$(cd "$S150_TARGET" && pwd -P)
  # Feature (non-protected) branch: --no-verify is branch-independent, and a feature
  # branch keeps the protected-branch commit umbrella out of the picture entirely.
  (cd "$S150_TARGET" && (git init -q -b feat/x 2>/dev/null || { git init -q && git checkout -q -b feat/x; })
   git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
  printf '%s\n' "$S150_TARGET" >> "$SMOKE_REG"

  s150_bash_run() {
    local cmd="$1"
    ( cd "$S150_TARGET" || exit 1
      jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 )
    return $?
  }

  # 150a: a gh-issue-create whose --body carries the `git commit ... --no-verify` tokens
  #       on one HEREDOC body line → must be ALLOWED (rc=0). The real #605 false-positive.
  #       RED pre-fix (the raw scan matches the data line and blocks with rc=2).
  sq="'"
  s150_data_cmd="gh issue create --title x --body \"\$(cat <<${sq}EOF${sq}
to skip the pre-commit gate you can run git commit --no-verify by hand
EOF
)\""
  s150_bash_run "$s150_data_cmd"; s150a_rc=$?
  if [ "$s150a_rc" = 0 ]; then
    ok "150a: --no-verify arm ignores the tokens inside a heredoc --body (no false-positive) (#605)"
  else
    ng "150a: --no-verify arm false-positives on 'git commit ... --no-verify' in a heredoc --body (rc=$s150a_rc, want 0) (#605)"
  fi

  # 150b (no under-block): a REAL `git commit` with a trailing `--no-verify` flag still
  #       blocks (rc=2). Passes now and must keep passing after the heredoc-strip fix
  #       (strip_command_data heredoc leaves a flag-bearing invocation with no heredoc intact).
  s150_real_cmd="git commit -m 'fix(#605): real subject' --no-verify"
  s150_bash_run "$s150_real_cmd"; s150b_rc=$?
  if [ "$s150b_rc" = 2 ]; then
    ok "150b: a real 'git commit --no-verify' still blocks (no under-block) (#605)"
  else
    ng "150b: real 'git commit --no-verify' not blocked (rc=$s150b_rc, want 2) (#605)"
  fi
  rm -rf "$S150_DIR"
fi

# ---------- §151 (#607): --amend arm does not false-positive on heredoc DATA ----------
# Twin of §150 (#605): the --amend matcher arm (pre_tool_use.sh:1217) scanned the RAW $cmd
# for `git ... commit ... --amend`, unlike every neighbouring arm (the clean :198, merge :333,
# the adjacent --no-verify arm fixed in #605, and the commit-umbrella :1256) which first pass
# raw_cmd through strip_command_data. So a NON-git command whose heredoc DATA body merely
# mentions the tokens `git commit ... --amend` on one line false-trips the `--amend of an
# already-pushed commit blocked` block. The Code fix gates the entry on strip_command_data
# "$raw_cmd" heredoc (heredoc mode — matching the sibling arms; under-block-safe because a real
# "$(git commit --amend)" substitution is left intact). 151a: heredoc-body false-positive must
# be ALLOWED (RED pre-fix). 151b: no-under-block guard — a genuine `git commit --amend` of an
# already-pushed commit still blocks.
#
# The amend block is conditional on the commit being pushed (HEAD an ancestor of @{upstream}),
# so unlike §150 this fixture is a bare "remote" + clone: after the initial push, the working
# clone's HEAD == origin/feat/x, which satisfies the ancestor check. That makes 151a a genuine
# RED (the raw scan matches the DATA line AND the pushed condition holds → block) and lets 151b
# exercise the real-amend block on the same fixture.
if ! command -v jq >/dev/null 2>&1; then
  ng "151a: jq missing — cannot drive the --amend DATA test (#607)"
  ng "151b: jq missing (#607)"
else
  S151_DIR=$(mktemp -d)
  S151_REMOTE="$S151_DIR/remote.git"
  S151_TARGET="$S151_DIR/target"
  git init -q --bare "$S151_REMOTE" >/dev/null 2>&1
  git clone -q "$S151_REMOTE" "$S151_TARGET" >/dev/null 2>&1
  S151_TARGET=$(cd "$S151_TARGET" && pwd -P)
  (cd "$S151_TARGET" || exit 1
   git checkout -q -b feat/x 2>/dev/null || git checkout -q feat/x
   git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
   git push -q -u origin feat/x) >/dev/null 2>&1
  printf '%s\n' "$S151_TARGET" >> "$SMOKE_REG"

  s151_bash_run() {
    local cmd="$1"
    ( cd "$S151_TARGET" || exit 1
      jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 )
    return $?
  }

  # 151a: a gh-issue-create whose --body carries the `git commit ... --amend` tokens on one
  #       HEREDOC body line, run on the already-pushed feature branch → must be ALLOWED (rc=0).
  #       The real #607 false-positive. RED pre-fix (the raw scan matches the DATA line, the
  #       pushed condition holds, so it blocks with rc=2).
  sq="'"
  s151_data_cmd="gh issue create --title x --body \"\$(cat <<${sq}EOF${sq}
to reword the last commit you can run git commit --amend by hand
EOF
)\""
  s151_bash_run "$s151_data_cmd"; s151a_rc=$?
  if [ "$s151a_rc" = 0 ]; then
    ok "151a: --amend arm ignores the tokens inside a heredoc --body (no false-positive) (#607)"
  else
    ng "151a: --amend arm false-positives on 'git commit ... --amend' in a heredoc --body (rc=$s151a_rc, want 0) (#607)"
  fi

  # 151b (no under-block): a REAL `git commit --amend` of an already-pushed commit still blocks
  #       (rc=2). Passes now and must keep passing after the heredoc-strip fix (strip_command_data
  #       heredoc leaves a flag-bearing invocation with no heredoc intact).
  s151_real_cmd="git commit --amend -m 'fix(#607): reword'"
  s151_bash_run "$s151_real_cmd"; s151b_rc=$?
  if [ "$s151b_rc" = 2 ]; then
    ok "151b: a real 'git commit --amend' of a pushed commit still blocks (no under-block) (#607)"
  else
    ng "151b: real 'git commit --amend' of a pushed commit not blocked (rc=$s151b_rc, want 2) (#607)"
  fi
  rm -rf "$S151_DIR"
fi

# ---------- §109 (#404): is_trusted_filer resolves trust portably across gh --json support ----------
# Reproduce-first: on a gh version that REJECTS `gh issue view --json authorAssociation`
# (Unknown JSON field) but serves `gh api .../issues/N -q .author_association`, the helper
# must still resolve trust. 109a is RED until the helper switches to the gh api form.
# 109b is the park guard: a genuinely unresolvable gh (both forms fail) returns non-zero.
if ! command -v jq >/dev/null 2>&1; then
  ng "109a: jq missing — cannot run the trust-portability check (#404)"
  ng "109b: jq missing (#404)"
else
  S109_DIR=$(mktemp -d)
  S109_SHIM="$S109_DIR/bin"; mkdir -p "$S109_SHIM"
  S109_STATE="$S109_DIR/state"; mkdir -p "$S109_STATE"
  printf 'OWNER\n' > "$S109_STATE/aa_100"   # #100 → OWNER via the api form
  # Stub gh: repo view resolves owner/name; `issue view --json authorAssociation` is
  # REJECTED (the unsupported-field gh version); `api .../issues/N` serves author_association.
  cat > "$S109_SHIM/gh" <<'SHIM'
#!/bin/sh
args="$*"
case "$args" in
  *"--json owner"*) printf 'mock\n'; exit 0 ;;
  *"--json name"*)  printf 'repo\n'; exit 0 ;;
  *"issue view"*"--json authorAssociation"*)
    echo 'Unknown JSON field: "authorAssociation"' >&2; exit 1 ;;
  *"api "*"/issues/"*)
    n=$(printf '%s\n' "$args" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    [ -n "$n" ] && [ -f "$GH109_STATE/aa_$n" ] && cat "$GH109_STATE/aa_$n"
    exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$S109_SHIM/gh"
  # Cache isolation: is_trusted_filer caches via ghjig_state_dir; pin it to a FRESH
  # per-call dir so a §55-seeded fixture can't satisfy the lookup without a gh query.
  S109_ES="$S109_DIR/es"

  # 109a: OWNER resolves trusted (rc=0) even though `issue view --json authorAssociation`
  #       is rejected — i.e. resolution goes through the portable api form. RED pre-fix.
  rm -rf "$S109_ES"
  s109a_rc=$(
    PATH="$S109_SHIM:$PATH" GH109_STATE="$S109_STATE" GHJIG_ROOT="$SHELL_ROOT" \
    GHJIG_STATE_DIR_OVERRIDE="$S109_ES" \
    bash -c '. "$GHJIG_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null
             . "$GHJIG_ROOT/.claude/hooks/helpers/issue_filer.sh" 2>/dev/null
             is_trusted_filer 100; echo $?' | tail -1
  )
  if [ "$s109a_rc" = 0 ]; then
    ok "109a: is_trusted_filer resolves OWNER via gh api despite --json authorAssociation being rejected (#404)"
  else
    ng "109a: trust unresolved (rc=$s109a_rc) — helper still depends on --json authorAssociation (#404)"
  fi

  # 109b (park guard): a gh where BOTH forms fail → is_trusted_filer returns non-zero
  #      (so /activate's "unresolvable → park" guard holds; never a false "trusted").
  cat > "$S109_SHIM/gh" <<'SHIM'
#!/bin/sh
args="$*"
case "$args" in
  *"--json owner"*) printf 'mock\n'; exit 0 ;;
  *"--json name"*)  printf 'repo\n'; exit 0 ;;
esac
exit 1
SHIM
  chmod +x "$S109_SHIM/gh"
  rm -rf "$S109_ES"
  s109b_rc=$(
    PATH="$S109_SHIM:$PATH" GH109_STATE="$S109_STATE" GHJIG_ROOT="$SHELL_ROOT" \
    GHJIG_STATE_DIR_OVERRIDE="$S109_ES" \
    bash -c '. "$GHJIG_ROOT/.claude/hooks/hookrt.sh" 2>/dev/null
             . "$GHJIG_ROOT/.claude/hooks/helpers/issue_filer.sh" 2>/dev/null
             is_trusted_filer 100; echo $?' | tail -1
  )
  if [ "$s109b_rc" != 0 ]; then
    ok "109b: an unresolvable gh returns non-zero (park guard holds; no false trusted) (#404)"
  else
    ng "109b: unresolvable gh wrongly resolved trusted (rc=$s109b_rc) (#404)"
  fi
  rm -rf "$S109_DIR"
fi

# ---------- §357 AC1: live shared sinks untouched by the run ----------
# A smoke run must add ZERO lines to the live audit log and ZERO entries to the
# live scope registry (MISSION "shared code, per-project state" isolation, #357).
# Reads the same LIVE $SHELL_ROOT paths snapshotted at startup — NOT $SMOKE_*,
# else the assertion would be vacuous (it would compare the isolated dir to
# itself). On pre-#357 code this FAILS (fixture fires append to the live audit);
# after the whole-run override it passes (every fire resolves to $SMOKE_STATE).
s357_audit_after=0; [ -f "$S357_LIVE_AUDIT" ] && s357_audit_after=$(wc -l < "$S357_LIVE_AUDIT" | tr -d ' ')
s357_reg_after=0; [ -f "$S357_LIVE_REG" ] && s357_reg_after=$(wc -l < "$S357_LIVE_REG" | tr -d ' ')
if [ "$s357_audit_after" = "$s357_audit_before" ] && [ "$s357_reg_after" = "$s357_reg_before" ]; then
  ok "357: smoke run left the live audit log + scope registry untouched (#357)"
else
  ng "357: smoke polluted live sinks — audit Δ=$((s357_audit_after - s357_audit_before)) registry Δ=$((s357_reg_after - s357_reg_before)) (#357)"
fi

# ---------- §111: /recall episodic-retrieval skill contract (#422) ----------
# Placed before §110 because §110 (the README floor guard) runs last by design.
# Static greps on the helper + command — no network: the pointers-only and cap
# guarantees are STRUCTURAL (field projection + a code cap), so they are pinned
# by inspecting the source, not by a live gh round-trip.
s111_helper="$SHELL_ROOT/.claude/hooks/helpers/recall.sh"
s111_cmd="$SHELL_ROOT/.claude/commands/recall.md"
s111=1; s111_why=""
if [ ! -f "$s111_helper" ]; then
  s111=0; s111_why="${s111_why}helper-missing;"
else
  # (a) pointers-only: projects number,title and NEVER projects a body field
  grep -q -- '--json number,title' "$s111_helper" || { s111=0; s111_why="${s111_why}no-number-title-projection;"; }
  grep -qE -- '--json[[:space:]]+[A-Za-z,]*body' "$s111_helper" && { s111=0; s111_why="${s111_why}body-projected;"; }
  # (b) bounded: RECALL_LIMIT default 5 + --limit honored
  grep -qE 'RECALL_LIMIT:-5' "$s111_helper" || { s111=0; s111_why="${s111_why}cap-default-not-5;"; }
  grep -q -- '--limit' "$s111_helper" || { s111=0; s111_why="${s111_why}no-limit-flag;"; }
  # (c) decision-record coverage: issues + PRs + ADRs arms
  grep -q 'gh search issues' "$s111_helper" || { s111=0; s111_why="${s111_why}no-issues-arm;"; }
  grep -q 'gh search prs' "$s111_helper" || { s111=0; s111_why="${s111_why}no-prs-arm;"; }
  grep -q 'docs/ADRs' "$s111_helper" || { s111=0; s111_why="${s111_why}no-adr-arm;"; }
  # (d) fail-open: a record-unavailable fallback line exists
  grep -q 'decision record unavailable' "$s111_helper" || { s111=0; s111_why="${s111_why}no-fail-open;"; }
  # (f) AC4 (#524) — deep tier is pointers-only STRUCTURALLY: it may project
  # `--json comments` to reach a comment body, but the matched comment TEXT is a
  # PREDICATE never a PRINTER. Pin it two ways: (i) the deep grep must feed a test
  # (`grep -qF` / `grep -Fq`) not a raw `grep -F` whose stdout is the body, and
  # (ii) inside the `--deep`-gated region the emitted line is only the `#<n> title`
  # pointer shape. RED now: no deep branch exists → no comments projection.
  grep -qE -- '--json[[:space:]]+[A-Za-z,]*comments' "$s111_helper" || { s111=0; s111_why="${s111_why}no-deep-comments-projection;"; }
  grep -qE 'grep[[:space:]]+-([A-Za-z]*q[A-Za-z]*F|[A-Za-z]*F[A-Za-z]*q)' "$s111_helper" || { s111=0; s111_why="${s111_why}deep-grep-not-predicate;"; }
fi
# (e) command file delegates to the helper
grep -q 'recall_pointers' "$s111_cmd" 2>/dev/null || { s111=0; s111_why="${s111_why}cmd-no-delegate;"; }
if [ "$s111" = 1 ]; then
  ok "111: /recall helper is pointers-only (number,title, no body projection) + bounded (RECALL_LIMIT=5) + covers issues/prs/ADRs + fail-open (#422) + deep tier is pointers-only (comment grep is a predicate, not a printer) (#524)"
else
  ng "111: /recall contract violated:$s111_why (#422)"
fi

# ---------- §112: enforcement-matcher mutation harness contract (#423) ----------
# Placed before §110 (the README floor guard, which runs last by design). Static
# greps on scripts/test/mutation.sh — the harness itself runs full smoke per
# mutant, so it is a SEPARATE CI job, not invoked from inside smoke (no recursion).
# Here we only pin that the harness exists, seeds the three highest-cost matcher
# mutations (§6.0), and isolates each in a git worktree (never mutates the live tree).
s112_mut="$SHELL_ROOT/scripts/test/mutation.sh"
s112=1; s112_why=""
if [ ! -f "$s112_mut" ]; then
  s112=0; s112_why="${s112_why}harness-missing;"
else
  grep -q 'check_commit_subject' "$s112_mut"     || { s112=0; s112_why="${s112_why}no-commit-format-mutant;"; }
  grep -q 'scan_staged_secrets' "$s112_mut"       || { s112=0; s112_why="${s112_why}no-secret-mutant;"; }
  grep -q 'PROTECTED_BRANCH_PATTERN' "$s112_mut"  || { s112=0; s112_why="${s112_why}no-protected-branch-mutant;"; }
  grep -q 'git worktree add' "$s112_mut"          || { s112=0; s112_why="${s112_why}no-worktree-isolation;"; }
  grep -q '"\$wt/scripts/test/smoke.sh"' "$s112_mut" || { s112=0; s112_why="${s112_why}no-worktree-smoke-run;"; }
fi
if [ "$s112" = 1 ]; then
  ok "112: mutation harness exists, seeds commit-format/secret/protected-branch mutants, worktree-isolated (#423)"
else
  ng "112: mutation harness contract violated:$s112_why (#423)"
fi

# ---------- §113: /replan-check divergence checkpoint contract (#427) ----------
# Placed before §110 (README floor, runs last by design). Static greps on the
# command + helper — the divergence JUDGMENT is LLM (uncheckable here); these pin
# the contract surface: the discriminator phrases, helper delegation, the
# mechanical-facts + fail-open helper shape, and the /sync-pr reference.
s113_cmd="$SHELL_ROOT/.claude/commands/replan-check.md"
s113_helper="$SHELL_ROOT/.claude/hooks/helpers/replan_check.sh"
s113_sync="$SHELL_ROOT/.claude/commands/sync-pr.md"
s113=1; s113_why=""
if [ ! -f "$s113_cmd" ]; then
  s113=0; s113_why="${s113_why}command-missing;"
else
  grep -qi 'structural' "$s113_cmd"            || { s113=0; s113_why="${s113_why}no-structural-term;"; }
  grep -qiE 'cosmetic|mechanical' "$s113_cmd"  || { s113=0; s113_why="${s113_why}no-cosmetic-clause;"; }
  grep -qiE 'unreachable|reachab' "$s113_cmd"  || { s113=0; s113_why="${s113_why}no-ac-reachability;"; }
  grep -q 'replan_check' "$s113_cmd"           || { s113=0; s113_why="${s113_why}cmd-no-delegate;"; }
fi
if [ ! -f "$s113_helper" ]; then
  s113=0; s113_why="${s113_why}helper-missing;"
else
  grep -q 'git diff --name-only' "$s113_helper" || { s113=0; s113_why="${s113_why}no-touched-files-fact;"; }
  grep -qi 'unavailable' "$s113_helper"          || { s113=0; s113_why="${s113_why}no-fail-open;"; }
fi
grep -q 'replan-check' "$s113_sync" 2>/dev/null || { s113=0; s113_why="${s113_why}sync-pr-no-ref;"; }
if [ "$s113" = 1 ]; then
  ok "113: /replan-check declares the structural-vs-cosmetic discriminator + AC-reachability, delegates to a fail-open mechanical-facts helper, and is referenced by /sync-pr (#427)"
else
  ng "113: /replan-check contract violated:$s113_why (#427)"
fi

# ---------- §114: high-asymmetry reviewer tier (#428) ----------
# Placed before §110 (README floor, runs last). The classifier is pure shell
# (no external calls), so the rc-per-kind + off-list falsifiability arm run
# offline by sourcing it directly. The fan-out itself is skill prose (LLM) —
# grep-locked on /ship + /complete-directive + the SPEC §4.11 contract.
s114_helper="$SHELL_ROOT/.claude/hooks/helpers/blast_radius.sh"
s114=1; s114_why=""
if [ ! -f "$s114_helper" ]; then
  s114=0; s114_why="${s114_why}helper-missing;"
else
  # shellcheck source=/dev/null
  . "$s114_helper"
  if command -v is_high_asymmetry >/dev/null 2>&1; then
    for k in merge-security-surface force-push directive-completion irreversible-adr; do
      is_high_asymmetry "$k" 2>/dev/null || { s114=0; s114_why="${s114_why}$k-not-flagged;"; }
    done
    # falsifiability arm: an off-list kind must NOT be flagged (closed set, AC1)
    is_high_asymmetry "ordinary-merge" 2>/dev/null && { s114=0; s114_why="${s114_why}off-list-flagged;"; }
  else
    s114=0; s114_why="${s114_why}no-is_high_asymmetry-fn;"
  fi
fi
grep -qiE 'high-asymmetry|is_high_asymmetry' "$SHELL_ROOT/.claude/commands/ship.md" 2>/dev/null || { s114=0; s114_why="${s114_why}ship-no-tier;"; }
grep -qiE 'high-asymmetry|is_high_asymmetry' "$SHELL_ROOT/.claude/commands/complete-directive.md" 2>/dev/null || { s114=0; s114_why="${s114_why}complete-directive-no-tier;"; }
grep -q '### 4.11 High-asymmetry reviewer tier' "$SHELL_ROOT/SPEC.md" 2>/dev/null || { s114=0; s114_why="${s114_why}no-spec-4.11;"; }
if [ "$s114" = 1 ]; then
  ok "114: is_high_asymmetry flags the closed set (not off-list) + /ship & /complete-directive carry the N-way tier + SPEC §4.11 (#428)"
else
  ng "114: high-asymmetry reviewer tier contract violated:$s114_why (#428)"
fi

# ---------- §115: ghjig_commit slot-assembly helper (#436) ----------
# Behavioral, offline: exercise ghjig_commit against a throwaway git repo (no
# network, no PreToolUse hook — the internal `git commit` is a subprocess of
# this script). Pins: reject-before-commit, happy-path subject hook-visible
# (extract+check accept it, NOT the -F bypass), and multibyte/multi-paragraph
# body round-trip.
s115_helper="$SHELL_ROOT/.claude/hooks/helpers/ghjig_commit.sh"
if [ ! -f "$s115_helper" ]; then
  ng "115: ghjig_commit.sh missing (#436)"
else
  # shellcheck source=/dev/null
  . "$s115_helper"
  if ! command -v ghjig_commit >/dev/null 2>&1; then
    ng "115: ghjig_commit function not defined after sourcing (#436)"
  else
    s115_tmp=$(mktemp -d)
    git -C "$s115_tmp" init -q
    git -C "$s115_tmp" config user.email smoke@example.com
    git -C "$s115_tmp" config user.name smoke
    git -C "$s115_tmp" config commit.gpgsign false   # isolate from a global signing config
    printf 'x\n' > "$s115_tmp/f"
    git -C "$s115_tmp" add f
    s115_long=$(python3 -c 'print("a"*73)' 2>/dev/null || printf 'a%.0s' $(seq 1 73))
    s115=1; s115_why=""

    # (a) reject-before-commit: a 73-char subject must error nonzero AND create no commit
    ( cd "$s115_tmp" && ghjig_commit feat 5 "$s115_long" ) >/dev/null 2>&1 \
      && { s115=0; s115_why="${s115_why}overlong-not-rejected;"; }
    if git -C "$s115_tmp" rev-parse HEAD >/dev/null 2>&1; then
      s115=0; s115_why="${s115_why}committed-despite-reject;"
    fi

    # (b) happy path: valid slots commit; the subject is hook-visible (extract+check accept it)
    if ( cd "$s115_tmp" && ghjig_commit feat 5 "add the thing" "본문 한국어 단락 첫 줄" ) >/dev/null 2>&1; then
      s115_subj=$(git -C "$s115_tmp" log -1 --format=%s)
      s115_xs=$(extract_commit_subject "git commit -m \"$s115_subj\"" "git commit -m \"$s115_subj\"")
      check_commit_subject "$s115_xs" >/dev/null 2>&1 || { s115=0; s115_why="${s115_why}subject-not-hook-accepted;"; }
      # (c) multibyte body round-trips intact
      git -C "$s115_tmp" log -1 --format=%B | grep -q '본문 한국어 단락 첫 줄' || { s115=0; s115_why="${s115_why}body-not-roundtripped;"; }
    else
      s115=0; s115_why="${s115_why}valid-commit-failed;"
    fi

    rm -rf "$s115_tmp"
    if [ "$s115" = 1 ]; then
      ok "115: ghjig_commit rejects-before-commit on overlong subject + happy-path subject is hook-accepted + multibyte body round-trips (#436)"
    else
      ng "115: ghjig_commit contract violated:$s115_why (#436)"
    fi
  fi
fi

# ---------- §116: SPEC §1.9 harness-overlap coverage parity (#450) ----------
# Placed before §110 (the README floor guard, which runs last by design). The
# §1.9 classification must carry exactly one posture row per enumerated mechanism
# in §1.8 (narrowing levers) + §4 (subagents) + §5 (slash commands) + §6.1 (hook
# matchers). NON-VACUOUS by construction: the expected total is four INDEPENDENTLY
# machine-derived counts (the same derivations §74a/§74b already trust), the actual
# count is §1.9 table rows whose posture cell carries a BACKTICKED posture token —
# the code form, so prose mentioning "cede to harness" without backticks does NOT
# match (anti-vacuity #1) — and the `-gt 0` count-guard fails loud on a §1.9
# rename / empty table (anti-vacuity #2). A mechanism added to any of the four
# families bumps the expected total and trips this guard until a §1.9 row is added.
s116_spec="$SHELL_ROOT/SPEC.md"
s116_levers=$(awk '/^### 1\.8 /{i=1;next} /^### 1\.9 /{exit} i&&/^\| \*\*/{n++} END{print n+0}' "$s116_spec")
s116_agents=$(ls "$SHELL_ROOT"/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
s116_cmds=$(grep -cE '^### 5\.[0-9]+ `/' "$s116_spec")
s116_hooks=$(grep -oE 'should_skip [a-z-]+' "$SHELL_ROOT"/.claude/hooks/pre_tool_use.sh | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
s116_exp=$((s116_levers + s116_agents + s116_cmds + s116_hooks))
s116_rows=$(awk '/^### 1\.9 /{i=1;next} /^## 2\. /{exit} i' "$s116_spec" \
            | grep -E '^\|' | grep -cE '`(cede-to-harness|keep-as-policy|keep-as-safety-redundancy)`')
if [ "$s116_rows" -gt 0 ] && [ "$s116_rows" = "$s116_exp" ]; then
  ok "116: SPEC §1.9 classifies all $s116_exp enumerated mechanisms (parity, #450)"
else
  ng "116: SPEC §1.9 coverage parity drift — classified=$s116_rows expected=$s116_exp (levers=$s116_levers agents=$s116_agents cmds=$s116_cmds hooks=$s116_hooks) (#450)"
fi

# ---------- §117: command docs use -F (not -f) for gh api stdin/file body (#452) ----------
# Placed before §110 (the README floor guard, which runs last by design). `gh api
# -f field=@-` sets the LITERAL string "@-" — only `-F field=@-` reads stdin/file.
# A command doc teaching the lowercase form silently corrupts the artifact it writes
# (hit live: /reflect's enrich-in-place PATCH wrote "@-" into a Directive comment).
# The legitimate graphql `-f query=<string>` form has no `=@`, so anchoring on `=@`
# is precise. NON-VACUOUS: a file-count guard fails loud if the commands glob is
# empty (rather than greening on nothing scanned).
s117_files=$(ls "$SHELL_ROOT"/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
s117_bad=$(grep -rlE '\-f [a-zA-Z_]+=@' "$SHELL_ROOT"/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$s117_files" -gt 0 ] && [ "$s117_bad" = 0 ]; then
  ok "117: no .claude/commands/*.md teaches the broken 'gh api -f <field>=@' form (use -F for stdin/file) (#452)"
else
  ng "117: broken 'gh api -f <field>=@' (literal, not stdin) in commands docs — use -F (files=$s117_files bad=$s117_bad) (#452)"
fi

# ---------- §118: shared onboard_checks.sh fact-reporter (#456) ----------
# Phase B (Test). Drives the FORTHCOMING shared mechanical-check script
# scripts/lib/onboard_checks.sh (Execution #456, Directive #454) headlessly: a
# stubbed `gh` on PATH + a temp target dir, asserting the emitted `<check> <status>`
# token for each of the five mechanical checks. The script is the single source the
# later scripts/setup.sh and /onboard both call, so the contract under test here is
# the line protocol they consume:
#   <check-name>  ok|fail  <one-line detail>      (one line per check, ALWAYS exit 0)
# Check names: upstream, permission, ssot:MISSION.md, ssot:SPEC.md, branch-protect, ci.
# The script reaches gh via $PATH (so the shim drives it) and supports --dry-run; it
# REPORTS facts, never gates — every invocation exits 0, even when the branch-protect
# `gh api .../protection` probe errors (non-admin 404/403).
#
# Shim design: one `gh` script serves every sub-case, keyed on state files under
# $S118_STATE. `gh repo view --json isFork`/`--json viewerPermission` answer
# upstream/permission; `gh api .../protection` exits 0 (protected) or non-zero
# (absent/unreadable) per a flag file. SSOT + CI are pure filesystem facts (no gh).
#
# RED until Phase C: with scripts/lib/onboard_checks.sh absent, the guard below
# fails LOUD on every planned assertion (mirrors §107's script-absent pattern) —
# a clean intended failure, not a harness error.
S118_SCRIPT="$SHELL_ROOT/scripts/lib/onboard_checks.sh"
if [ ! -f "$S118_SCRIPT" ]; then
  ng "118a: upstream fork→fail / non-fork→ok — scripts/lib/onboard_checks.sh missing (Phase C not landed) (#456)"
  ng "118b: permission READ→fail / WRITE→ok — script missing (#456)"
  ng "118c: ssot:SPEC.md absent→fail / present→ok (SPEC unconditionally expected) — script missing (#456)"
  ng "118d: ssot:MISSION.md absent→fail / present→ok — script missing (#456)"
  ng "118e: branch-protect present→ok / absent-or-gh-api-error→fail, still exit 0 — script missing (#456)"
  ng "118f: ci .github/workflows present→ok / absent→fail — script missing (#456)"
else
  S118_DIR=$(cd "$(mktemp -d)" && pwd -P)
  S118_SHIM="$S118_DIR/bin"
  S118_STATE="$S118_DIR/state"
  mkdir -p "$S118_SHIM" "$S118_STATE"
  cat > "$S118_SHIM/gh" <<'SHIM'
#!/bin/sh
# Smoke shim for onboard_checks.sh. State files under $S118_STATE drive each answer:
#   isfork     → printed for `gh repo view --json isFork`   (true|false)
#   permission → printed for `gh repo view --json viewerPermission` (READ|WRITE|…)
#   protected  → present ⇒ `gh api .../protection` succeeds; absent ⇒ it errors (non-admin).
case "$*" in
  *"repo view"*"isFork"*)            cat "$S118_STATE/isfork" 2>/dev/null ;;
  *"repo view"*"viewerPermission"*)  cat "$S118_STATE/permission" 2>/dev/null ;;
  *"repo view"*defaultBranchRef.name*) printf 'main\n' ;;
  *"repo view"*"url"*)               printf 'https://github.com/o/r\n' ;;  # #614: host-derivation read
  *"api"*"protection"*)
    if [ -f "$S118_STATE/protected" ]; then
      printf '{"required_pull_request_reviews":{}}\n'      # protected → success
    else
      echo '{"message":"Not Found"}' >&2; exit 1           # non-admin / absent → error
    fi
    ;;
esac
exit 0
SHIM
  chmod +x "$S118_SHIM/gh"

  # s118_run <target-dir> → echoes the script's stdout; sets s118_rc to its exit code.
  # gh is reached via PATH (shim first); the script runs from the target's cwd.
  s118_run() {
    s118_out=$(
      cd "$1" || exit 99
      PATH="$S118_SHIM:$PATH" S118_STATE="$S118_STATE" bash "$S118_SCRIPT" 2>/dev/null
    ); s118_rc=$?
  }
  # Extract the status token (field 2) for a given check name (field 1) from output.
  s118_status() { printf '%s\n' "$s118_out" | awk -v c="$1" '$1==c{print $2; exit}'; }

  # Two target dirs: a "bare" repo (no SSOT, no CI) and a "full" one (SPEC, MISSION,
  # workflows present). SSOT/CI are filesystem facts, so the dir contents drive them.
  S118_BARE="$S118_DIR/bare"; mkdir -p "$S118_BARE"
  S118_FULL="$S118_DIR/full"; mkdir -p "$S118_FULL/.github/workflows"
  printf '# spec\n'    > "$S118_FULL/SPEC.md"
  printf '# mission\n' > "$S118_FULL/MISSION.md"
  printf 'name: ci\n'  > "$S118_FULL/.github/workflows/ci.yml"

  # 118a: fork→upstream fail; non-fork→upstream ok.
  printf 'true\n'  > "$S118_STATE/isfork"; printf 'WRITE\n' > "$S118_STATE/permission"
  s118_run "$S118_BARE"; s118_fork=$(s118_status upstream)
  printf 'false\n' > "$S118_STATE/isfork"
  s118_run "$S118_BARE"; s118_nofork=$(s118_status upstream)
  if [ "$s118_fork" = fail ] && [ "$s118_nofork" = ok ]; then
    ok "118a: upstream fork→fail, non-fork→ok (#456)"
  else
    ng "118a: upstream wrong (fork=$s118_fork non-fork=$s118_nofork, want fail/ok) (#456)"
  fi

  # 118b: missing push permission (READ)→fail; WRITE→ok.
  printf 'false\n' > "$S118_STATE/isfork"
  printf 'READ\n'  > "$S118_STATE/permission"
  s118_run "$S118_BARE"; s118_pread=$(s118_status permission)
  printf 'WRITE\n' > "$S118_STATE/permission"
  s118_run "$S118_BARE"; s118_pwrite=$(s118_status permission)
  if [ "$s118_pread" = fail ] && [ "$s118_pwrite" = ok ]; then
    ok "118b: permission READ→fail, WRITE→ok (#456)"
  else
    ng "118b: permission wrong (READ=$s118_pread WRITE=$s118_pwrite, want fail/ok) (#456)"
  fi

  # 118c: SPEC.md absent→fail (SPEC unconditionally expected AC); present→ok.
  s118_run "$S118_BARE"; s118_spec_absent=$(s118_status ssot:SPEC.md)
  s118_run "$S118_FULL"; s118_spec_present=$(s118_status ssot:SPEC.md)
  if [ "$s118_spec_absent" = fail ] && [ "$s118_spec_present" = ok ]; then
    ok "118c: ssot:SPEC.md absent→fail, present→ok (SPEC unconditionally expected) (#456)"
  else
    ng "118c: ssot:SPEC.md wrong (absent=$s118_spec_absent present=$s118_spec_present, want fail/ok) (#456)"
  fi

  # 118d: MISSION.md absent→fail; present→ok (same shape).
  s118_run "$S118_BARE"; s118_mission_absent=$(s118_status ssot:MISSION.md)
  s118_run "$S118_FULL"; s118_mission_present=$(s118_status ssot:MISSION.md)
  if [ "$s118_mission_absent" = fail ] && [ "$s118_mission_present" = ok ]; then
    ok "118d: ssot:MISSION.md absent→fail, present→ok (#456)"
  else
    ng "118d: ssot:MISSION.md wrong (absent=$s118_mission_absent present=$s118_mission_present) (#456)"
  fi

  # 118e: branch-protect present→ok; absent OR gh api .../protection ERRORS→fail,
  # and the script must STILL exit 0 (reports facts, never crashes/gates).
  printf 'false\n' > "$S118_STATE/isfork"; printf 'WRITE\n' > "$S118_STATE/permission"
  touch "$S118_STATE/protected"
  s118_run "$S118_BARE"; s118_bp_ok=$(s118_status branch-protect); s118_bp_ok_rc=$s118_rc
  rm -f "$S118_STATE/protected"
  s118_run "$S118_BARE"; s118_bp_fail=$(s118_status branch-protect); s118_bp_fail_rc=$s118_rc
  if [ "$s118_bp_ok" = ok ] && [ "$s118_bp_fail" = fail ] \
     && [ "$s118_bp_ok_rc" = 0 ] && [ "$s118_bp_fail_rc" = 0 ]; then
    ok "118e: branch-protect present→ok, absent/gh-api-error→fail, both exit 0 (#456)"
  else
    ng "118e: branch-protect wrong (ok=${s118_bp_ok}[rc=$s118_bp_ok_rc] fail=${s118_bp_fail}[rc=$s118_bp_fail_rc]) (#456)"
  fi

  # 118f: .github/workflows present→ci ok; absent→ci fail.
  s118_run "$S118_FULL"; s118_ci_present=$(s118_status ci)
  s118_run "$S118_BARE"; s118_ci_absent=$(s118_status ci)
  if [ "$s118_ci_present" = ok ] && [ "$s118_ci_absent" = fail ]; then
    ok "118f: ci .github/workflows present→ok, absent→fail (#456)"
  else
    ng "118f: ci wrong (present=$s118_ci_present absent=$s118_ci_absent, want ok/fail) (#456)"
  fi

  rm -rf "$S118_DIR"
fi

# ---------- §119: setup.sh single-entry orchestrator (#458) ----------
# Phase B (Test). Drives the FORTHCOMING single-entry script scripts/setup.sh
# (Execution #458) headlessly. setup.sh is a thin orchestrator over the existing
# sibling scripts; the contract under test:
#   setup.sh <local-path | repo-url> [--enter]
#   1. deps    → calls scripts/bootstrap.sh
#   2. dispatch on the single positional arg:
#        existing local dir → scripts/register.sh ; repo URL → scripts/clone-into.sh.
#        Tie-breaker: if [ -d "$arg" ] it is a local path regardless of URL shape.
#   3. pre-flight → runs scripts/lib/onboard_checks.sh, ok→✓ / fail→✗.
#   4. dir-mode gate: an always-offered y/N prompt, default N, `read -r resp || resp=N`
#        so EOF / non-TTY → N; only y/Y calls scripts/onboard_target.sh.
#   5. prints next-command guidance; --enter execs claude.
#   6. NEVER writes a user-global file (~/.zshrc, ~/.bashrc, ~/.profile, ~/.claude,
#        git config --global) — the PATH line is printed, never appended.
#
# Isolation mirrors §9b: setup.sh is copied into a fake shell root whose sibling
# deps (bootstrap/register/clone-into/onboard_target) are marker-dropping stubs —
# each touches a sentinel under $S119_MARK when invoked, so we assert WHICH path
# ran. onboard_checks.sh is stubbed to a one-line ok-report (the spec permits a
# stub) so pre-flight neither needs a real `gh` nor gates.
#
# RED until Phase C: with scripts/setup.sh absent the guard below fails LOUD on
# every planned assertion (mirrors §107/§118's script-absent pattern) — a clean
# intended failure, not a harness error.
S119_SCRIPT="$SHELL_ROOT/scripts/setup.sh"
if [ ! -f "$S119_SCRIPT" ]; then
  ng "119a: path arg → register.sh dispatch (not clone-into) — scripts/setup.sh missing (Phase C not landed) (#458)"
  ng "119b: URL arg → clone-into.sh dispatch (not register) — script missing (#458)"
  ng "119c: dir-mode gate non-TTY/EOF → onboard_target.sh NOT called, no hang — script missing (#458)"
  ng "119d: dir-mode gate 'y' → onboard_target.sh called — script missing (#458)"
  ng "119e: source contains no user-global redirect / git config --global — script missing (#458)"
  ng "119f: run against fake \$HOME leaves rc files untouched — script missing (#458)"
else
  # Build a fake shell root holding setup.sh + stubbed siblings.
  S119_FSR=$(cd "$(mktemp -d)" && pwd -P)
  mkdir -p "$S119_FSR/scripts/lib"
  cp "$S119_SCRIPT" "$S119_FSR/scripts/setup.sh"
  chmod +x "$S119_FSR/scripts/setup.sh"
  # Marker-dropping stubs: each writes a sentinel named after itself when invoked.
  for s119_dep in bootstrap register clone-into onboard_target; do
    {
      printf '#!/bin/sh\n'
      printf ': "${S119_MARK:?}"\n'
      printf 'touch "$S119_MARK/%s"\n' "$s119_dep"
      printf 'exit 0\n'
    } > "$S119_FSR/scripts/$s119_dep.sh"
    chmod +x "$S119_FSR/scripts/$s119_dep.sh"
  done
  # onboard_checks.sh stub: one ok line, always exit 0 (fact-reporter contract).
  {
    printf '#!/bin/sh\n'
    printf 'echo "upstream ok stub"\n'
    printf 'exit 0\n'
  } > "$S119_FSR/scripts/lib/onboard_checks.sh"
  chmod +x "$S119_FSR/scripts/lib/onboard_checks.sh"

  # Bounded runner: drives the COPIED setup.sh with a marker dir + a stdin source.
  # $1 = positional arg, $2 = stdin source path (e.g. /dev/null or a printf-fed file).
  # A fresh marker dir per call; if `timeout`/`gtimeout` is present we hard-bound the
  # run (defence-in-depth against a `read` that fails to honor EOF), else fall back
  # to a backgrounded run + kill guard so a hang cannot wedge the suite.
  s119_run() {
    S119_MARK=$(mktemp -d)
    export S119_MARK
    if command -v timeout >/dev/null 2>&1; then
      timeout 10 sh "$S119_FSR/scripts/setup.sh" "$1" < "$2" >/dev/null 2>&1
      s119_rc=$?
    elif command -v gtimeout >/dev/null 2>&1; then
      gtimeout 10 sh "$S119_FSR/scripts/setup.sh" "$1" < "$2" >/dev/null 2>&1
      s119_rc=$?
    else
      sh "$S119_FSR/scripts/setup.sh" "$1" < "$2" >/dev/null 2>&1 &
      s119_pid=$!
      ( sleep 10; kill -9 "$s119_pid" 2>/dev/null ) & s119_killer=$!
      wait "$s119_pid" 2>/dev/null; s119_rc=$?
      kill "$s119_killer" 2>/dev/null
    fi
  }
  # s119_dropped <dep> → 0 if that dep's sentinel exists in the last run's marker dir.
  s119_dropped() { [ -f "${S119_MARK}/$1" ]; }

  # 119a: an existing local dir dispatches to register.sh, NOT clone-into.sh.
  S119_LOCAL=$(cd "$(mktemp -d)" && pwd -P)
  s119_run "$S119_LOCAL" /dev/null
  if s119_dropped register && ! s119_dropped clone-into; then
    ok "119a: path arg → register.sh dispatch (not clone-into) (#458)"
  else
    ng "119a: path arg dispatch wrong (register=$(s119_dropped register && echo y || echo n) clone-into=$(s119_dropped clone-into && echo y || echo n)) (#458)"
  fi
  rm -rf "$S119_LOCAL" "$S119_MARK"

  # 119b: a repo URL dispatches to clone-into.sh, NOT register.sh.
  s119_run "https://example.com/foo.git" /dev/null
  if s119_dropped clone-into && ! s119_dropped register; then
    ok "119b: URL arg → clone-into.sh dispatch (not register) (#458)"
  else
    ng "119b: URL arg dispatch wrong (clone-into=$(s119_dropped clone-into && echo y || echo n) register=$(s119_dropped register && echo y || echo n)) (#458)"
  fi
  rm -rf "$S119_MARK"

  # 119c: dir-mode gate, non-TTY / EOF stdin (< /dev/null) → default N → onboard_target
  # NOT called, and the run must terminate (no hang). A URL arg keeps the dispatch in
  # clone-into (a stub), so onboard_target firing would be the gate, not dispatch.
  s119_run "https://example.com/foo.git" /dev/null
  if ! s119_dropped onboard_target && [ "$s119_rc" != 137 ] && [ "$s119_rc" != 124 ]; then
    ok "119c: dir-mode gate EOF/non-TTY → onboard_target NOT called, no hang (rc=$s119_rc) (#458)"
  else
    ng "119c: dir-mode gate non-TTY wrong (onboard_target=$(s119_dropped onboard_target && echo y || echo n) rc=$s119_rc; 124/137 ⇒ hang/timeout) (#458)"
  fi
  rm -rf "$S119_MARK"

  # 119d: dir-mode gate, stdin = 'y' → onboard_target.sh IS called.
  S119_YES=$(mktemp); printf 'y\n' > "$S119_YES"
  s119_run "https://example.com/foo.git" "$S119_YES"
  if s119_dropped onboard_target; then
    ok "119d: dir-mode gate 'y' → onboard_target.sh called (#458)"
  else
    ng "119d: dir-mode gate 'y' did NOT call onboard_target.sh (#458)"
  fi
  rm -f "$S119_YES"; rm -rf "$S119_MARK"

  # 119e: source-level guard — setup.sh must contain no redirection into a user-global
  # rc file and no `git config --global`. A grep-the-source assertion is robust against
  # whichever branch a run happens to take. Pattern covers > and >> into the rc paths.
  if grep -Eq '>>?[[:space:]]*("?~|"?\$HOME)?/?\.(zshrc|bashrc|profile)|>>?[[:space:]]*"?~?/?\.claude|git[[:space:]]+config[[:space:]]+--global' "$S119_SCRIPT"; then
    ng "119e: setup.sh source contains a user-global redirect or git config --global (#458)"
  else
    ok "119e: setup.sh source has no user-global redirect / git config --global (#458)"
  fi

  # 119f: behavioural backstop — run against a fake $HOME seeded with rc files and
  # assert they are byte-identical afterwards (the PATH line is printed, never written).
  S119_HOME=$(cd "$(mktemp -d)" && pwd -P)
  printf 'orig-zshrc\n'   > "$S119_HOME/.zshrc"
  printf 'orig-bashrc\n'  > "$S119_HOME/.bashrc"
  printf 'orig-profile\n' > "$S119_HOME/.profile"
  s119_pre=$(cat "$S119_HOME/.zshrc" "$S119_HOME/.bashrc" "$S119_HOME/.profile")
  ( S119_MARK=$(mktemp -d); export S119_MARK
    HOME="$S119_HOME" sh "$S119_FSR/scripts/setup.sh" "https://example.com/foo.git" < /dev/null >/dev/null 2>&1
    rm -rf "$S119_MARK" ) || true
  s119_post=$(cat "$S119_HOME/.zshrc" "$S119_HOME/.bashrc" "$S119_HOME/.profile")
  if [ "$s119_pre" = "$s119_post" ] && [ ! -d "$S119_HOME/.claude" ]; then
    ok "119f: run against fake \$HOME left rc files + ~/.claude untouched (#458)"
  else
    ng "119f: run against fake \$HOME mutated an rc file or created ~/.claude (#458)"
  fi
  rm -rf "$S119_HOME"

  unset S119_MARK
  rm -rf "$S119_FSR"
fi

