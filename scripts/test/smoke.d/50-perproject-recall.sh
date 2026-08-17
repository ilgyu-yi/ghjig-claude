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

# 90r: --migrate on the COMMON layout — a BLANK LINE between the `## Table of contents`
# heading and its anchor-link list (the real-world legacy shape). The splice must skip
# the leading blank, delete the whole anchor list, and leave exactly ONE marker ToC —
# no duplicated ToC, no orphan anchor list. Pins the content-preservation gap (#629).
S90M_R="$S90M_DIR/migrate_blankgap.md"
cat > "$S90M_R" <<'S90MSPEC'
# Target
## Table of contents

- [1. Foo](#1-foo)
- [2. Bar](#2-bar)

SENTINEL_PROSE_629R must survive migrate.

## 1. Foo
body
## 2. Bar
body
S90MSPEC
bash "$S90M_TOC" --migrate --spec "$S90M_R" >/dev/null 2>&1
s90r_rc=0; bash "$S90M_TOC" --check --spec "$S90M_R" >/dev/null 2>&1 || s90r_rc=$?
s90r_anchors=$(grep -c '](#' "$S90M_R")
s90r_markers=$(grep -cF '<!-- TOC START' "$S90M_R")
if [ "$s90r_rc" -eq 0 ] && [ "$s90r_anchors" -eq 0 ] \
   && grep -qF 'SENTINEL_PROSE_629R' "$S90M_R" && [ "$s90r_markers" -eq 1 ]; then
  ok "90r: --migrate on the blank-line-gap layout leaves ONE marker ToC — no duplicated/orphan anchor list (#629)"
else
  ng "90r: --migrate must delete the anchor list across a heading→list blank gap — check=$s90r_rc anchors=$s90r_anchors markers=$s90r_markers (#629)"
fi

# 90s (#631): the --check exit-3 (marker-less) STDERR message must name the numbered
# `## N.` heading precondition AND a by-hand alternative (SPEC §5.1 step 8, §1.3) —
# not just "run --migrate", which mis-recommends a migrate that would refuse on an
# unnumbered SPEC. Captures the exit-3 stderr from the §90h marker-less fixture
# (isolates it from the unrelated exit-5 --migrate-refuse message). RED until Phase C
# rewords the render_toc_into exit-3 emit.
s90s_msg=$(bash "$S90M_TOC" --check --spec "$S90M_DIR/markerless.md" 2>&1 >/dev/null)
if printf '%s' "$s90s_msg" | grep -qi 'numbered' \
   && printf '%s' "$s90s_msg" | grep -qF '## N.' \
   && printf '%s' "$s90s_msg" | grep -qiE 'by hand|manually'; then
  ok "90s: build_toc.sh --check exit-3 message names the numbered ## N. precondition + a by-hand alternative (#631)"
else
  ng "90s: build_toc.sh --check exit-3 message must name the numbered ## N. precondition + a by-hand alternative — got: $s90s_msg (#631)"
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

# 90t (#631): the rc==3 (marker-less) branch message ALSO names the numbered `## N.`
# heading precondition + a by-hand alternative (SPEC §5.1 step 8, §1.3), while STILL
# naming the literal build_toc.sh --migrate (so 90o stays green). Asserted on the same
# echo line that carries build_toc.sh --migrate — the migrate recommendation and its
# precondition belong together. RED until Phase C rewords the rc==3 branch.
s90t_line=$(grep -F 'build_toc.sh --migrate' "$S90_CHECKYML")
if printf '%s' "$s90t_line" | grep -qF 'build_toc.sh --migrate' \
   && printf '%s' "$s90t_line" | grep -qF '## N.' \
   && printf '%s' "$s90t_line" | grep -qiE 'by hand|manually'; then
  ok "90t: check-toc.yml rc==3 message names the numbered ## N. precondition + by-hand alt, still names build_toc.sh --migrate (#631)"
else
  ng "90t: check-toc.yml rc==3 message must name the numbered ## N. precondition + a by-hand alternative while keeping build_toc.sh --migrate (#631)"
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
for r in issue-reviewer plan-reviewer code-reviewer finding-judge; do
  rf="$SHELL_ROOT/.claude/agents/$r.md"
  if [ -f "$rf" ] && grep -qF 'SPEC §6.0' "$rf"; then
    : # references the enforcement-style principle — wired
  else
    S92_FAIL="$S92_FAIL $r"
  fi
done
if [ -z "$S92_FAIL" ]; then
  ok "92: issue/plan/code-reviewer + finding-judge prompts reference SPEC §6.0 (enforcement-style lens) (#354, +finding-judge #645)"
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
# THE SINGLE DEFINITION of "what ends a §1.x window" (#644, widened to §1.8 by
# #668). Used by BOTH live derivations (§1.8's lever count and §1.9's posture
# count) AND the shared fixture builder, so the guards and the arms that bound
# them cannot drift apart — which is the whole reason those derivations were
# extracted into functions in the first place.
#
# DEFINED HERE, ABOVE THE FIRST CONSUMER, DELIBERATELY. `s116_lever_rows` runs
# ~30 lines below and takes this as `-v endre=`; defined after it, the first call
# expands an unset variable, the command substitution's subshell dies under
# `set -u`, and `s116_levers` becomes EMPTY. Measured, that is WORSE than it
# sounds: the suite runs `set -uo pipefail` with no `-e`, so the assignment still
# completes, an empty-but-set variable evaluates as 0 in `$(( ))`, and §116 and
# §116c both red with an ORDINARY PARITY MESSAGE carrying `expected=60` (§116's
# also shows an empty `levers=` field), accompanied only by one `unbound
# variable` line on stderr. A
# parity-shaped red is indistinguishable from genuine §1.9 drift except for that
# stderr line, which is exactly the wrong-cause failure §116 exists to avoid.
# Order is load-bearing, not cosmetic.
#
# DEPTH 2-3, not "depth <= 3". `^# ` is deliberately ABSENT: it matches any
# shell comment, and SPEC carries 16 such lines inside fenced examples, so
# including it would collapse the window to 0 the day §1.9 gains a fenced
# example (measured). Dropping it costs nothing — the only thing it could ever
# terminate on is a SECOND document H1 appearing after §1.9, in a file with
# exactly one H1 (line 1) across 2,893 lines, and the `i&&` guard already keeps
# line 1 from closing a window that has not opened.
#
# RESIDUAL, named rather than rounded off: this rule is line-oriented and knows
# nothing about code fences, so 9 fence-interior `^## ` lines elsewhere in SPEC
# remain collidable. Accepted for #644 — §1.9 carries no fence today and the
# failure is loud (§116 reds at classified=0) rather than silent. Fence-state
# tracking is deliberately NOT attempted here.
S116_END_RE='^## |^### '

# THE SHARED WINDOW CONTRACT (#670). `70-gates-contentlocks.sh` §156j re-derives
# these same two windows under an `s156_` prefix — it cannot call the helpers below,
# because smoke.sh's header reserves cross-section symbols for _preamble.sh. The two
# copies must agree, and what they agree ABOUT is stated here and at §156j, not as a
# claim of byte-identity (that claim decayed twice unnoticed):
#
#   START RULE — a window opens on the SECTION'S TITLE, never on its number (#668).
#   TERMINATOR — a window closes on $S116_END_RE above, never on a hand-picked
#                next-heading literal (#644).
#
# `s116_lever_rows` below satisfies both. `s116_posture_rows` satisfies the
# terminator rule but still opens on the literal `### 1.9 `, so it collapses to 0 on
# a §1.9 renumber (measured: 66 -> 0). That is a KNOWN residual, out of scope for
# #670 and unhardened here on purpose — recorded so the next editor does not read
# the posture helper as already conforming. §156j is held to AGREEMENT with these,
# not ahead of them, and §156v reds if the two stop agreeing.

# NEITHER END IS A SECTION NUMBER (#668). The window used to open on the literal
# `### 1.8 ` and close on the literal `### 1.9 `, so it broke in both directions:
# a `### 1.8.5` sibling sat INSIDE the window and inflated the count (6 -> 7),
# while renumbering §1.8 meant the window never opened at all (-> 0). Both feed
# `s116_exp`, and both therefore red §116 *and* §116c for a cause outside the
# parity being checked — with §116c's message wrongly blaming the SPEC copy.
#
# The start anchors on the section TITLE, which survives renumbering and matches
# exactly one line; the end reuses $S116_END_RE, the same definition §1.9's
# window uses, rather than re-spelling it. `#### ` is not a terminator (position
# 4 is `#`, not a space), so a genuine `#### 1.8.1` sub-section of §1.8 stays in
# scope and its rows still count — §116g pins that direction.
# s116_lever_rows <spec-file> → count of §1.8 narrowing-lever table rows in that
# file. THE SINGLE DERIVATION of the lever count: the live `s116_levers` below
# AND the §116e-§116g lever-window arms (#668) both call it, so the window rule
# lives in exactly one place and cannot be repaired in one caller while drifting
# in the other. Same shape, and for the same reason, as s116_posture_rows below.
s116_lever_rows() {
  awk -v endre="$S116_END_RE" \
    '/^### .*[Ii]n-session narrowing levers/{i=1;next} i&&$0~endre{exit} i&&/^\| \*\*/{n++} END{print n+0}' "$1"
}
s116_levers=$(s116_lever_rows "$s116_spec")
s116_agents=$(ls "$SHELL_ROOT"/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
s116_cmds=$(grep -cE '^### 5\.[0-9]+ `/' "$s116_spec")
s116_hooks=$(grep -oE 'should_skip [a-z-]+' "$SHELL_ROOT"/.claude/hooks/pre_tool_use.sh | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
s116_exp=$((s116_levers + s116_agents + s116_cmds + s116_hooks))
# s116_posture_rows <spec-file> → count of §1.9 posture rows in that file. The
# SINGLE derivation of the count: the live parity arm below AND the §116a-§116c
# window-terminator arms (#644) both call it, so the window rule lives in exactly
# one place and cannot be fixed in one caller while drifting in the other.

s116_posture_rows() {
  # `#### ` is NOT a terminator — position 3 is `#`, not a space — so a genuine
  # `#### 1.9.1` sub-section of §1.9 stays in scope and its rows still count
  # (§116b pins that direction).
  #
  # The `i&&` guard is LOAD-BEARING, not defensive: without it the terminator
  # matches every EARLIER `## `/`### ` heading and awk exits before the window
  # ever opens, yielding 0 (measured on the real SPEC). That would not fail
  # silently — §116's `-gt 0` check and the §116a-§116c baseline guards all catch
  # it — but the guard is what keeps the rule scoped to the window it describes.
  awk -v endre="$S116_END_RE" '/^### 1\.9 /{i=1;next} i&&$0~endre{exit} i' "$1" \
    | grep -E '^\|' | grep -cE '`(cede-to-harness|keep-as-policy|keep-as-safety-redundancy)`'
}
s116_rows=$(s116_posture_rows "$s116_spec")
if [ "$s116_rows" -gt 0 ] && [ "$s116_rows" = "$s116_exp" ]; then
  ok "116: SPEC §1.9 classifies all $s116_exp enumerated mechanisms (parity, #450)"
else
  ng "116: SPEC §1.9 coverage parity drift — classified=$s116_rows expected=$s116_exp (levers=$s116_levers agents=$s116_agents cmds=$s116_cmds hooks=$s116_hooks) (#450)"
fi

# ---------- §116a-§116g: §116's two windowed extractors (#644, #668) ----------
# Phase B (Test). §116 derives its verdict from TWO windowed walks of SPEC —
# §1.9's posture-row count (`s116_posture_rows`, arms §116a-§116c, #644) and
# §1.8's lever-row count (`s116_lever_rows`, arms §116e-§116g, #668) — and both
# feed the same comparison. The arms share ONE fixture builder and ONE
# $S116_END_RE, so "what ends a §1.x window" is spelled once for every window
# under test. §116d is the AC5 sentinel for every fixture below and is kept LAST
# by design.
#
# THE ROW WINDOW (#644): §116's posture-row window opens at `### 1.9 ` and must
# close at the NEXT WINDOW-CLOSING HEADING (depth 2-3) — not at the literal
# `## 2. `. With the literal terminator, everything authored between §1.9 and
# `## 2. ` (a new `### 1.10`, say) sits INSIDE the counting window, so an
# unrelated table row quoting a backticked posture token inflates the count and
# reds §116 for a cause outside its subject. A genuine `#### 1.9.1` sub-section
# of §1.9 must stay INSIDE.
#
# THE LEVER WINDOW (#668): the same shape, one section up and on BOTH ends.
# `s116_lever_rows`' window must open on §1.8's TITLE and close on the shared
# $S116_END_RE. With the literal ends it carried before #668 — opening at
# `### 1.8 `, closing at `### 1.9 ` — it broke in both directions: (a) a
# `| **`-shaped row in a new `### 1.8.5` sibling counted as a lever it is not,
# and (b) renumbering §1.8 collapsed the window to 0 and silently dropped every
# real lever from `s116_exp`. A genuine `#### 1.8.1` sub-section of §1.8 must
# stay INSIDE.
#
# Fixtures are COPIES under $TMP (cleaned by the preamble's EXIT trap); no arm
# writes to the real SPEC.md, and §116d pins that (AC5) — nothing here removes a
# path, so there is no cleanup to prefix-guard.
#
# WITNESS HONESTY (#644, the row window): only §116a reds against the current
# row-window terminator. §116b and
# §116c pass both before and after the fix — they are REGRESSION GUARDS bounding
# the fix (b: it must not shrink the real scope; c: the pair is not
# always-failing), not witnesses. §116b does carry one load-bearing job for
# §116a: it proves the decoy row IS countable when in scope, so a green §116a
# cannot be a decoy that simply never matched the counting regex.
#
# WITNESS HONESTY (#668, the lever window): §116e and §116f are WITNESSES — each
# red against the PRE-#668 `s116_lever_rows` (measured: 7 and 0 against a
# baseline of 6). §116g is a BOUND, not a witness: it reads 7 both before and
# after the repair, so it constrains the repair's shape rather than
# demonstrating the defect. It is labelled that way at its own arm too.
S116W_DIR="$TMP/s116w"
mkdir -p "$S116W_DIR"
S116W_MARK='smoke-fixture-decoy-644'
# s116w_fixture <open-re> <heading-line> <decoy-row> <out-file> — a SPEC.md copy
# with <heading-line> plus ONE <decoy-row> spliced in at THE END OF the section
# <open-re> opens, i.e. immediately before the first following line that
# $S116_END_RE says closes a §1.x window. Only the heading DEPTH differs between
# the exclusion and the inclusion fixture of each pair, so the heading rule
# stays the single variable under test.
#
# ONE BUILDER FOR BOTH WINDOWS (#668). §1.9's arms (#644) and §1.8's arms (#668)
# pass different <open-re>/<decoy-row> and share everything else, so the splice
# rule — "the end of a §1.x section" — exists in exactly one place, for the same
# reason $S116_END_RE does. A second builder would be the drift that shared
# definition exists to prevent.
#
# ANCHORED TO THE SECTION UNDER TEST, NOT TO A DOCUMENT-GLOBAL LITERAL (#644
# round-1 F1). An earlier revision spliced at the literal `## 2. `, which is the
# end of §1.9 only while §1.9 happens to be §1's LAST subsection. The moment a
# real `### 1.10` lands, that anchor puts §116b's decoy BEHIND the window it is
# meant to be inside, and the arm reds for a cause outside its own subject — the
# very pathology §116a exists to prevent, reproduced one level up in the fixture
# that bounds it. #644 names three Active Directives planning a §1.x section, so
# this is the anticipated future, not a hypothetical. The same reasoning binds
# the §1.8 fixtures: they splice at the end of §1.8 as $S116_END_RE finds it,
# never at the literal `### 1.9 `. The anchor reuses $S116_END_RE rather than
# re-spelling the heading rule, so it cannot drift from the derivation.
# ESCAPE SPLIT, because the two engines disagree and the difference is silent
# (#668 round 2). `awk -v` performs escape processing on the VALUE, so a literal
# dot must be written `\\.` here — the four `s116w_fixture` calls below do that.
# `grep` does NOT, so the two `grep` call sites further down (`s116l_h_orig`, and
# §116f's leftover-heading guard) must keep the single `\.` form. Applying the
# `awk` form to a `grep` site does not fail loudly: `grep -c '^### 1\\.8 '`
# returns 0 on ANY file, so §116f's `!= 0` leftover check would never fire and
# the anti-vacuity guard would SILENTLY STOP GUARDING. Measured both ways during
# #668's round-2 review, after exactly that over-application was made and caught.
s116w_fixture() {
  awk -v openre="$1" -v h="$2" -v row="$3" -v endre="$S116_END_RE" '
    !i&&$0~openre   { i=1; print; next }
    i&&!d&&$0~endre { print h; print ""; print row; print ""; d=1 }
    { print }' "$s116_spec" > "$4"
}
S116W_ROW="| $S116W_MARK (§0) | \`keep-as-policy\` | decoy row planted by smoke §116a/§116b (#644). |"
s116w_excl="$S116W_DIR/excl.md"
s116w_incl="$S116W_DIR/incl.md"
s116w_pristine="$S116W_DIR/pristine.md"
cp "$s116_spec" "$s116w_pristine"
s116w_fixture '^### 1\\.9 ' '### 1.10 Smoke fixture decoy section (#644)'  "$S116W_ROW" "$s116w_excl"
s116w_fixture '^### 1\\.9 ' '#### 1.9.1 Smoke fixture sub-section (#644)'  "$S116W_ROW" "$s116w_incl"

# ---- §116e-§116g fixtures (#668), built HERE, up front, alongside the #644
# ones so that §116d — which runs LAST and pins AC5 — covers these too. Same
# builder, same anchor discipline; only the section and the decoy row's SHAPE
# differ (§1.8's window counts `| **`-leading rows; §1.9's counts backticked
# posture tokens). The decoy carries no posture token, so it is inert to
# s116_posture_rows even if a future window ever spans both sections.
S116L_MARK='smoke-fixture-decoy-668'
S116L_ROW="| **$S116L_MARK** (§0) | decoy lever row planted by smoke §116e/§116g (#668). | **Guidance** — fixture only. |"
s116l_excl="$S116W_DIR/lever-excl.md"
s116l_incl="$S116W_DIR/lever-incl.md"
s116l_renum="$S116W_DIR/lever-renum.md"
s116w_fixture '^### 1\\.8 ' '### 1.8.5 Smoke fixture decoy section (#668)' "$S116L_ROW" "$s116l_excl"
s116w_fixture '^### 1\\.8 ' '#### 1.8.1 Smoke fixture sub-section (#668)'  "$S116L_ROW" "$s116l_incl"
# §116f's fixture is a RENAME, not a splice: §1.8's heading keeps its TITLE and
# loses its NUMBER, which is the only thing the start anchor may legitimately
# depend on. Derived from the live heading line — no SPEC title is hardcoded
# here — so the copy differs from the real SPEC in exactly that one line, and a
# §1.8 that has already been renumbered upstream leaves $s116l_h_orig empty and
# trips §116f's fixture guard rather than quietly producing a no-op copy.
s116l_h_orig=$(grep -m1 '^### 1\.8 ' "$s116_spec")
s116l_h_renum="### 1.8a ${s116l_h_orig#\#\#\# 1.8 }"
awk -v o="$s116l_h_orig" -v n="$s116l_h_renum" '!r&&$0==o { print n; r=1; next } { print }' \
  "$s116_spec" > "$s116l_renum"
# Lever-count baseline over the untouched SPEC, the DENOMINATOR every §116e-§116g
# comparison is gated on: `-gt 0` fails LOUD if the lever window collapsed (a
# §1.8 rename, an awk that exits before the window opens) rather than letting an
# empty window read as agreement.
s116l_base=$(s116_lever_rows "$s116_spec")
# Baseline over the untouched SPEC. `-gt 0` below fails LOUD if the window
# collapsed (a §1.9 rename, an awk that exits before the window opens) rather
# than reading an empty window as agreement.
s116w_base=$(s116_posture_rows "$s116_spec")

# §116a (AC2, THE WITNESS — RED until the terminator is scoped): a decoy posture
# row inside a `### 1.10` is OUT of §1.9 and must not move the count.
s116w_a=$(s116_posture_rows "$s116w_excl")
if [ ! -s "$s116w_excl" ] || [ "$(grep -c "$S116W_MARK" "$s116w_excl")" != 1 ]; then
  ng "116a: fixture not built — '### 1.10' decoy SPEC copy missing or lacks exactly one decoy row (#644)"
elif [ "$s116w_base" -gt 0 ] && [ "$s116w_a" = "$s116w_base" ]; then
  ok "116a: a posture row inside a '### 1.10' is EXCLUDED from the §1.9 window (count stays $s116w_base) (#644)"
else
  ng "116a: §116's window admits a '### 1.10' — count=$s116w_a baseline=$s116w_base; the terminator must be the next window-closing heading (depth 2-3), not the literal '## 2. ' (#644)"
fi

# §116b (AC3, regression guard — green before and after): the SAME row inside a
# `#### 1.9.1` is a genuine §1.9 sub-section and stays counted. Doubles as
# §116a's non-vacuity proof (the decoy row does match the counting regex).
s116w_b=$(s116_posture_rows "$s116w_incl")
if [ ! -s "$s116w_incl" ] || [ "$(grep -c "$S116W_MARK" "$s116w_incl")" != 1 ]; then
  ng "116b: fixture not built — '#### 1.9.1' decoy SPEC copy missing or lacks exactly one decoy row (#644)"
elif [ "$s116w_base" -gt 0 ] && [ "$s116w_b" = "$((s116w_base + 1))" ]; then
  ok "116b: a posture row inside a '#### 1.9.1' is still INCLUDED (count $s116w_base → $s116w_b) (#644)"
else
  ng "116b: §116's window lost a genuine '#### 1.9.1' sub-section row — count=$s116w_b expected=$((s116w_base + 1)) (#644)"
fi

# §116c (AC4, regression guard — green before and after): an UNMODIFIED copy
# still balances against the independently derived expectation, so §116a+§116b
# are not simply bounding an always-failing derivation.
s116w_c=$(s116_posture_rows "$s116w_pristine")
if [ ! -s "$s116w_pristine" ]; then
  ng "116c: fixture not built — pristine SPEC copy missing or empty (#644)"
elif [ "$s116w_c" -gt 0 ] && [ "$s116w_c" = "$s116_exp" ]; then
  ok "116c: an unmodified SPEC copy still balances ($s116w_c = $s116_exp) (#644)"
else
  ng "116c: unmodified SPEC copy no longer balances — classified=$s116w_c expected=$s116_exp (#644)"
fi

# §116e (#668 AC2, THE WITNESS — RED until the lever window's terminator stops
# being the literal `### 1.9 `): a decoy `| **`-shaped row inside a NEW
# `### 1.8.5` sibling section is OUT of §1.8's lever table and must not move the
# count. Measured pre-fix: levers=7 against a baseline of 6, i.e. an unrelated
# table row inflates s116_exp and reds §116 — AND §116c, whose message then
# blames the SPEC copy — for a cause outside either arm's subject.
s116l_e=$(s116_lever_rows "$s116l_excl")
if [ ! -s "$s116l_excl" ] || [ "$(grep -c "$S116L_MARK" "$s116l_excl")" != 1 ]; then
  ng "116e: fixture not built — '### 1.8.5' decoy SPEC copy missing or lacks exactly one decoy lever row (#668)"
elif [ "$s116l_base" -gt 0 ] && [ "$s116l_e" = "$s116l_base" ]; then
  ok "116e: a '| **' row inside a '### 1.8.5' is EXCLUDED from the §1.8 lever window (count stays $s116l_base) (#668)"
else
  ng "116e: §116's lever window admits a '### 1.8.5' — levers=$s116l_e baseline=$s116l_base; the terminator must be the shared \$S116_END_RE, not the literal '### 1.9 ' (#668)"
fi

# §116f (#668 AC4, THE WITNESS — RED until the START anchor stops being the
# literal `### 1.8 `): a SPEC copy whose §1.8 is RENUMBERED (title untouched)
# must still yield the same lever count. Measured pre-fix: levers=0 against a
# baseline of 6 — the window never opens, so every lever silently vanishes from
# s116_exp. The fixture guard is on the DENOMINATOR: it demands the renumbered
# heading be present exactly once AND the old numbering be gone, so a rename
# that silently did nothing fails loud instead of reading as a pass.
s116l_f=$(s116_lever_rows "$s116l_renum")
if [ ! -s "$s116l_renum" ] || [ -z "$s116l_h_orig" ] \
   || [ "$(grep -cF "$s116l_h_renum" "$s116l_renum")" != 1 ] \
   || [ "$(grep -c '^### 1\.8 ' "$s116l_renum")" != 0 ]; then
  ng "116f: fixture not built — renumbered SPEC copy missing, or its §1.8 heading was not rewritten to '### 1.8a <same title>' (#668)"
elif [ "$s116l_base" -gt 0 ] && [ "$s116l_f" = "$s116l_base" ]; then
  ok "116f: renumbering §1.8 keeps its levers in the window (count stays $s116l_base) (#668)"
else
  ng "116f: §116's lever window opens only at the literal '### 1.8 ' — levers=$s116l_f baseline=$s116l_base; anchor the start on the section TITLE, not on its number (#668)"
fi

# §116g (#668 AC3, a BOUND — NOT a witness: measured 7 both before and after the
# repair): the SAME decoy row inside a genuine `#### 1.8.1` sub-section of §1.8
# is still COUNTED, so scoping the terminator must not shrink the lever window's
# real reach (`#### ` is depth 4 and $S116_END_RE deliberately stops at 3).
# It also carries §116e's non-vacuity: it proves the IDENTICAL row IS countable
# when in scope, so a green §116e cannot be a decoy that simply never matched
# `^\| \*\*`.
s116l_g=$(s116_lever_rows "$s116l_incl")
if [ ! -s "$s116l_incl" ] || [ "$(grep -c "$S116L_MARK" "$s116l_incl")" != 1 ]; then
  ng "116g: fixture not built — '#### 1.8.1' decoy SPEC copy missing or lacks exactly one decoy lever row (#668)"
elif [ "$s116l_base" -gt 0 ] && [ "$s116l_g" = "$((s116l_base + 1))" ]; then
  ok "116g: a '| **' row inside a '#### 1.8.1' is still INCLUDED (count $s116l_base → $s116l_g) (#668)"
else
  ng "116g: §116's lever window lost a genuine '#### 1.8.1' sub-section row — levers=$s116l_g expected=$((s116l_base + 1)) (#668)"
fi

# §116d (AC5, regression guard — green before and after; kept LAST by design so
# it covers every fixture above, #644's and #668's alike): the real SPEC.md is
# byte-identical to the copy taken before any fixture was built. Pins that the
# fixture builder writes only to $TMP.
if [ -s "$s116w_pristine" ] && cmp -s "$s116_spec" "$s116w_pristine"; then
  ok "116d: the real SPEC.md is unmutated by the §116a-§116g fixtures (#644, #668)"
else
  ng "116d: SPEC.md changed while the §116 window fixtures ran — a fixture wrote to the real SSOT (#644, #668)"
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

  # ---- §118g–§118n (#631): fact-report toc-format + docs-pointer (Phase B, RED) ----
  # Two NEW fact-reporting lines the shared onboard_checks.sh must emit (SPEC §5.1
  # step 8 "Doc-shape fact checks", §1.3) — both gh-free and both NON-GATING, so the
  # script MUST still exit 0 in EVERY case. Field-1-keyed lookup reuses s118_status;
  # a sibling s118_detail extracts the free-text detail (field 3+) for offender naming.
  #   toc-format: keys off `build_toc.sh --check --spec SPEC.md`'s exit code
  #     (0|1→ok, 3→fail marker-less, 4→fail corrupt, *→ok; SPEC.md absent→ok/skip via
  #     the [ -f SPEC.md ] guard, so build_toc is never called on an absent SPEC).
  #   docs-pointer: ok when every docs/*.md leads (first two non-empty lines contain
  #     SPEC, §91 parity); fail listing offenders; ok when no docs/*.md.
  # RED until Phase C: onboard_checks.sh emits NEITHER line yet, so each status lookup
  # returns "" (≠ ok/fail) and every assertion fails LOUD — an intended RED, not a
  # harness error. (The exit-0 sub-condition already passes; the status one is what
  # is red.) Phase C emits build_toc via onboard_checks.sh self-locating ../build_toc.sh
  # and invoking it with `--spec SPEC.md` from the target cwd (s118_run cd's there),
  # under `set -uo pipefail` with a `toc_rc=0` pre-init before `|| toc_rc=$?`.
  s118_detail() { printf '%s\n' "$s118_out" | awk -v c="$1" '$1==c{ $1=""; $2=""; sub(/^ */,""); print; exit }'; }

  # --- toc-format fixtures: each in its own target dir with a SPEC.md (or none) ---
  # marker-less anchor-link ToC WITH numbered headings → build_toc --check exit 3.
  S118_TML="$S118_DIR/toc_markerless"; mkdir -p "$S118_TML"
  cat > "$S118_TML/SPEC.md" <<'S118SPEC'
# Target
## Table of contents
- [1. Foo](#1-foo)
- [2. Bar](#2-bar)
## 1. Foo
body
## 2. Bar
body
S118SPEC

  # corrupt markers: TOC START present, no TOC END → build_toc --check exit 4.
  S118_TCORRUPT="$S118_DIR/toc_corrupt"; mkdir -p "$S118_TCORRUPT"
  cat > "$S118_TCORRUPT/SPEC.md" <<'S118SPEC'
# Target
## Table of contents
<!-- TOC START — generated by scripts/build_toc.sh; do not edit by hand -->
| Section | Title | Line |
|---|---|---|
## 1. Foo
body
S118SPEC

  # healthy marker line-number ToC (fresh) — populated via the real build_toc.sh
  # write mode so `--check` exits 0.
  S118_TOK="$S118_DIR/toc_fresh"; mkdir -p "$S118_TOK"
  cat > "$S118_TOK/SPEC.md" <<'S118SPEC'
# Target
## Table of contents
<!-- TOC START — generated by scripts/build_toc.sh; do not edit by hand -->
<!-- TOC END -->
## 1. Foo
body
## 2. Bar
body
S118SPEC
  bash "$SHELL_ROOT/scripts/build_toc.sh" --spec "$S118_TOK/SPEC.md" >/dev/null 2>&1

  # stale-but-markered ToC: valid markers, WRONG body row → build_toc --check exit 1
  # → toc-format ok (this check is FORMAT, not freshness — SPEC §5.1 step 8).
  S118_TSTALE="$S118_DIR/toc_stale"; mkdir -p "$S118_TSTALE"
  cat > "$S118_TSTALE/SPEC.md" <<'S118SPEC'
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
S118SPEC

  # 118g: toc-format on a marker-less anchor-link SPEC (--check 3) → fail, exit 0.
  s118_run "$S118_TML"; s118_tf_ml=$(s118_status toc-format); s118_tf_ml_rc=$s118_rc
  if [ "$s118_tf_ml" = fail ] && [ "$s118_tf_ml_rc" = 0 ]; then
    ok "118g: toc-format on a marker-less SPEC → fail, onboard_checks exit 0 (#631)"
  else
    ng "118g: toc-format marker-less wrong (status=$s118_tf_ml [rc=$s118_tf_ml_rc], want fail/0) (#631)"
  fi

  # 118h: toc-format on a corrupt-marker SPEC (START, no END → --check 4) → fail, exit 0.
  s118_run "$S118_TCORRUPT"; s118_tf_c=$(s118_status toc-format); s118_tf_c_rc=$s118_rc
  if [ "$s118_tf_c" = fail ] && [ "$s118_tf_c_rc" = 0 ]; then
    ok "118h: toc-format on a corrupt-marker SPEC → fail, onboard_checks exit 0 (#631)"
  else
    ng "118h: toc-format corrupt-marker wrong (status=$s118_tf_c [rc=$s118_tf_c_rc], want fail/0) (#631)"
  fi

  # 118i: toc-format on a fresh marker line-number ToC (--check 0) → ok, exit 0.
  s118_run "$S118_TOK"; s118_tf_ok=$(s118_status toc-format); s118_tf_ok_rc=$s118_rc
  if [ "$s118_tf_ok" = ok ] && [ "$s118_tf_ok_rc" = 0 ]; then
    ok "118i: toc-format on a fresh marker ToC → ok, onboard_checks exit 0 (#631)"
  else
    ng "118i: toc-format fresh-marker wrong (status=$s118_tf_ok [rc=$s118_tf_ok_rc], want ok/0) (#631)"
  fi

  # 118j: SPEC.md absent → toc-format ok (skip; the [ -f SPEC.md ] guard never calls
  # build_toc), exit 0. Reuses the SPEC-less S118_BARE dir.
  s118_run "$S118_BARE"; s118_tf_abs=$(s118_status toc-format); s118_tf_abs_rc=$s118_rc
  if [ "$s118_tf_abs" = ok ] && [ "$s118_tf_abs_rc" = 0 ]; then
    ok "118j: toc-format when SPEC.md absent → ok (skip), onboard_checks exit 0 (#631)"
  else
    ng "118j: toc-format absent-SPEC wrong (status=$s118_tf_abs [rc=$s118_tf_abs_rc], want ok/0) (#631)"
  fi

  # 118k: stale-but-markered ToC (--check 1) → toc-format ok — proves FORMAT ≠ freshness. exit 0.
  s118_run "$S118_TSTALE"; s118_tf_st=$(s118_status toc-format); s118_tf_st_rc=$s118_rc
  if [ "$s118_tf_st" = ok ] && [ "$s118_tf_st_rc" = 0 ]; then
    ok "118k: toc-format on a stale-but-markered ToC → ok (format ≠ freshness), exit 0 (#631)"
  else
    ng "118k: toc-format stale-marker wrong (status=$s118_tf_st [rc=$s118_tf_st_rc], want ok/0) (#631)"
  fi

  # --- docs-pointer fixtures ---
  S118_DP_OK="$S118_DIR/docs_ok"; mkdir -p "$S118_DP_OK/docs"
  printf '# Recall digest\nFull details in SPEC §5.25.\n' > "$S118_DP_OK/docs/x.md"

  S118_DP_FAIL="$S118_DIR/docs_fail"; mkdir -p "$S118_DP_FAIL/docs"
  printf '# Recall digest\nFull details in SPEC §5.25.\n' > "$S118_DP_FAIL/docs/x.md"
  printf '# Widget guide\nThis restates the widget contract inline.\n' > "$S118_DP_FAIL/docs/y.md"

  S118_DP_NONE="$S118_DIR/docs_none"; mkdir -p "$S118_DP_NONE"

  # 118l: every docs/*.md leads with a SPEC reference → docs-pointer ok, exit 0.
  s118_run "$S118_DP_OK"; s118_dp_ok=$(s118_status docs-pointer); s118_dp_ok_rc=$s118_rc
  if [ "$s118_dp_ok" = ok ] && [ "$s118_dp_ok_rc" = 0 ]; then
    ok "118l: docs-pointer — all docs/*.md lead with SPEC → ok, exit 0 (#631)"
  else
    ng "118l: docs-pointer all-ok wrong (status=$s118_dp_ok [rc=$s118_dp_ok_rc], want ok/0) (#631)"
  fi

  # 118m: an offending docs/y.md (no SPEC in its first two non-empty lines) →
  # docs-pointer fail, the detail NAMES the offender (y.md), exit 0.
  s118_run "$S118_DP_FAIL"; s118_dp_f=$(s118_status docs-pointer); s118_dp_f_rc=$s118_rc
  s118_dp_f_detail=$(s118_detail docs-pointer)
  if [ "$s118_dp_f" = fail ] && [ "$s118_dp_f_rc" = 0 ] \
     && printf '%s' "$s118_dp_f_detail" | grep -qF 'y.md'; then
    ok "118m: docs-pointer — offender → fail, detail names y.md, exit 0 (#631)"
  else
    ng "118m: docs-pointer offender wrong (status=$s118_dp_f [rc=$s118_dp_f_rc] detail='$s118_dp_f_detail', want fail/0 naming y.md) (#631)"
  fi

  # 118n: no docs/ dir → docs-pointer ok (vacuously true), exit 0.
  s118_run "$S118_DP_NONE"; s118_dp_n=$(s118_status docs-pointer); s118_dp_n_rc=$s118_rc
  if [ "$s118_dp_n" = ok ] && [ "$s118_dp_n_rc" = 0 ]; then
    ok "118n: docs-pointer — no docs/ dir → ok, exit 0 (#631)"
  else
    ng "118n: docs-pointer no-docs wrong (status=$s118_dp_n [rc=$s118_dp_n_rc], want ok/0) (#631)"
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

# ---------- §159 (#660): interpreter helpers key on OUTPUT VALIDITY (SPEC §6.1.2) ----------
# `strip_command_data` and `space_glued_separators` (helpers/git_matcher.sh) both
# declare a FAIL-CLOSED contract while selecting their python3 result by EXIT
# STATUS behind a `command -v python3` presence gate. Those two answer "did
# something run?", not "is this a result I may use?" — so a python3 that exits 0
# with a site/venv banner on stdout takes the SUCCESS branch and its banner is
# returned AS the stripped command. The caller's arm-entry grep then misses and
# the arm never runs. At the second site the write is IN-PLACE
# (`space_glued_separators "$cmd" cmd`, pre_tool_use.sh:157) into the arm-entry
# variable with 74 references, so the junk replaces the command every downstream
# arm greps — which is why fixing only the first site leaves the force-push,
# protected-push and gh-pr-merge gates wide open (measured).
#
# SPEC §6.1.2 enumerates the fail-closed set by OUTCOME: interpreter ABSENT,
# NON-ZERO exit, EXIT-0-WITH-JUNK, EXIT-0-PARTIAL, and payload on STDERR with
# stdout empty. Fail-closed MEANS returning the command UNCHANGED (the arm's grep
# then runs against the full text): an unstripped command can only make an arm
# match MORE — a recoverable false-trip of the #403/#440/#605 shape — while junk
# makes it match LESS, and on these arms less means no match at all, i.e. a silent
# wrong-allow on irreversible gates.
#
# Arms. 159a/159c/159f/159h are the RED propositions (the defect); 159b/159d/159g
# are no-under-block / no-blinding guards that pass today and must keep passing.
#   159-fixture  curated-PATH shim farm + registered target repo (count-guarded)
#   159a  strip_command_data fails closed under all 5 pathologies × 3 modes  RED
#   159b  stderr-only NOISE beside a correct stdout must still STRIP (2>/dev/null
#         already handles it) — an over-eager fix reds here                 GREEN
#   159c  space_glued_separators fails closed under the same pathologies    RED
#   159d  no blinding: a 44-record differential over the #340/#367/#403/#440 +
#         trailing-newline shapes is byte-identical to recorded behaviour   GREEN
#   159e  in_scope control BOTH ways — proves an rc=0 below is a real ALLOW and
#         not "the guard never ran"                                         GREEN
#   159f  end-to-end: 5 irreversible gates block (rc=2) under a banner python3 RED
#   159g  end-to-end: the §108 heredoc-DATA-only command still allowed (rc=0)
#         under a HEALTHY python3                                          GREEN
#   159h  end-to-end: that same command BLOCKS (rc=2) under a banner python3 —
#         fail-closed leaves it UNSTRIPPED, so the arm runs; pre-fix it is rc=0
#         for the wrong reason (the arm grepped the banner)                 RED
#
# Anti-vacuity (smoke.sh Theme E): every arm carries a fixture guard — the shim
# resolved on PATH *and* actually INVOKED (marker file) — and every aggregate
# carries a count-guard, so a shim that never fires or a curated PATH that does
# not take effect fails LOUD instead of greening. Each failure mode gets its own
# subshell exit code so a fixture miss can never masquerade as the intended
# failure. `command -v` results are path-filtered before linking: under a shell
# that wraps a tool (e.g. `grep`) as a FUNCTION, `command -v` prints the bare
# name, and symlinking that would silently produce a dangling link.
S660_DIR="$TMP/iv660"                    # under $TMP → cleaned by the shared EXIT trap
S660_BIN="$S660_DIR/bin"                 # curated PATH + mode-driven python3 shim
S660_NOPY="$S660_DIR/nopy"               # same, with NO python3 at all (absent leg)
S660_E2E="$S660_DIR/e2e"                 # curated PATH + always-banner python3 shim
S660_STATE="$S660_DIR/state"             # shim invocation markers
S660_REG_ON="$S660_DIR/state-on"         # isolated ghjig state dir, registry POPULATED
S660_REG_OFF="$S660_DIR/state-off"       # isolated ghjig state dir, registry EMPTY
mkdir -p "$S660_BIN" "$S660_NOPY" "$S660_E2E" "$S660_STATE" "$S660_REG_ON" "$S660_REG_OFF"

# The real python3, by ABSOLUTE path — the `noisy` shim mode execs it, and 159b/159d
# need it for their reference/golden legs. Empty ⇒ those two arms skip LOUD.
S660_REAL_PY=$(command -v python3 2>/dev/null || true)
case "$S660_REAL_PY" in /*) ;; *) S660_REAL_PY="" ;; esac

# `gh` is deliberately NOT linked into the farm: the five §159f rows were measured
# to reach rc=2 with no `gh` on PATH, so omitting it keeps the fixture off the
# network and off gh-auth state entirely.
s660_missing=""
for s660_t in sed awk grep head tail tr wc cat cut sort uniq git jq date mkdir rm ls env sh bash id find dirname basename mktemp touch chmod xargs od; do
  s660_src=$(command -v "$s660_t" 2>/dev/null) || { s660_missing="$s660_missing $s660_t"; continue; }
  case "$s660_src" in /*) ;; *) s660_missing="$s660_missing $s660_t(not-a-path)"; continue ;; esac
  ln -sf "$s660_src" "$S660_BIN/$s660_t"
  ln -sf "$s660_src" "$S660_NOPY/$s660_t"
  ln -sf "$s660_src" "$S660_E2E/$s660_t"
done

cat > "$S660_BIN/python3" <<'S660PY'
#!/bin/sh
# #660 fixture: a python3 that EXITS 0 while producing output the caller must
# REJECT. Every mode exits 0 on purpose — that is the whole point: rc says
# "something ran", which is not the question a fail-closed contract asks.
: "${S660_STATE:?}"
echo call >> "$S660_STATE/py_calls"          # invocation marker (anti-vacuity)
case "${S660_PY_MODE:?}" in
  # exit-0-with-junk: a site/venv/PYTHONSTARTUP banner INSTEAD OF the payload.
  banner)  cat >/dev/null 2>&1; printf 'Python 3.12.0 (venv site banner on stdout)\n' ;;
  # exit-0-partial: a truncated/interrupted write — a genuine PREFIX of the payload,
  # so a naive "non-empty output" test would admit it.
  partial) head -c 12 ;;
  # exit-0 with nothing at all.
  empty)   cat >/dev/null 2>&1 ;;
  # payload on STDERR, stdout empty. Shaped like a real answer so the only thing
  # rejecting it is the channel it arrived on.
  stderr)  cat >/dev/null 2>&1; printf 'gh issue edit 1 --body \n' >&2 ;;
  # NON-ZERO EXIT with junk on stdout — SPEC §6.1.2's remaining enumerated outcome,
  # named verbatim by #660 AC item 4. Green on BOTH sides of the fix (measured: the
  # pre-fix blob already closed on rc!=0 — that is precisely what an rc-keyed selector
  # DID cover), so this is a regression + AC-coverage guard, NOT a defect witness.
  crash)   cat >/dev/null 2>&1; printf 'Traceback (most recent call last)\n'; exit 1 ;;
  # NOT a pathology (159b): correct stdout from the real interpreter PLUS noise on
  # stderr, which the helper's existing `2>/dev/null` already handles.
  noisy)   printf 'DeprecationWarning: fixture noise\n' >&2; exec "${S660_REAL_PY:?}" "$@" ;;
  # A typo'd S660_PY_MODE must not silently degrade to `empty`. MEASURED: a bare
  # `exit 1` here does NOT red the arm — empty stdout is unframed, so the helper fails
  # closed, `[ out = in ]` PASSES and the closed-counter increments. A stderr complaint
  # is swallowed by the subshells' `) 2>/dev/null`. The signal must be OUT-OF-BAND.
  *)       : > "$S660_STATE/bad_mode" ;;
esac
exit 0
S660PY
chmod +x "$S660_BIN/python3"
cp "$S660_BIN/python3" "$S660_E2E/python3"

# The corpus. `printf -v` (not `$( )`) so the trailing-newline shape keeps its
# trailing newlines all the way into the helper — the one shape where the frame's
# disclosed residual is observable on the RAW return.
s660_corpus_cmd() {
  local _id="$1" _ov="$2" sq="'"
  case "$_id" in
    # A heredoc body AND a -m value AND quoted literals: all three strip modes
    # change it when the interpreter is healthy, so "returned unchanged" is a
    # meaningful assertion rather than a tautology.
    failclosed)  printf -v "$_ov" '%s' "gh issue edit 1 --body \"\$(cat <<${sq}EOF${sq}
git commit --no-verify and git push --force origin main
EOF
)\" -m \"note\"" ;;
    340-quoted)  printf -v "$_ov" '%s' 'gh pr merge 7 --squash --body "prose that says gh pr merge"' ;;
    367-heredoc) printf -v "$_ov" '%s' "gh issue edit 1 --body \"\$(cat <<${sq}EOF${sq}
git push origin main
EOF
)\"" ;;
    403-commit)  printf -v "$_ov" '%s' "gh issue edit 1 --body \"\$(cat <<${sq}EOF${sq}
prose that mentions a git commit invocation
EOF
)\"" ;;
    440-msg)     printf -v "$_ov" '%s' 'git commit -m "docs(#440): git push --force origin main documented"' ;;
    440-eq)      printf -v "$_ov" '%s' 'git commit --message="git push origin main"' ;;
    440-target)  printf -v "$_ov" '%s' 'git push origin "main"' ;;
    unclosed)    printf -v "$_ov" '%s' 'git commit -m "unclosed quote' ;;
    trailnl)     printf -v "$_ov" '%s' 'git status

' ;;
    plain)       printf -v "$_ov" '%s' 'git commit -m x && git push origin feat/y' ;;
    glued)       printf -v "$_ov" '%s' 'git commit -m "x"&&git push --force origin main' ;;
    *) return 1 ;;
  esac
}
s660_hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
# OUT-PARAMS: both are written indirectly (`printf -v`) by s660_corpus_cmd and by
# space_glued_separators, so pre-declare them for shellcheck (SC2154).
s660_in=""; s660_out=""

# Recorded differential (159d): `<corpus-id>|<mode>|<hex of the output>`, captured
# at Phase-B time from the CURRENT implementation under a healthy python3. `mode`
# ∈ heredoc/message/full is strip_command_data measured AT THE `$( )` CALLER
# BOUNDARY — see that helper's RESIDUAL header for which call sites wrap and
# which do not; the tally lives there, not here, so it cannot drift twice. `sgs` is
# space_glued_separators measured RAW, because its sole call site is a `printf -v`
# in-place write and raw IS its caller boundary. Hex, not text, so a stray newline
# or trailing space cannot be silently normalized away by the comparison.
S660_GOLDEN=$(cat <<'S660GOLD'
failclosed|heredoc|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a2922202d6d20226e6f746522
failclosed|message|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a2922202d6d20
failclosed|full|676820697373756520656469742031202d2d626f647920202d6d20
failclosed|sgs|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a67697420636f6d6d6974202d2d6e6f2d76657269667920616e64206769742070757368202d2d666f726365206f726967696e206d61696e0a454f460a2922202d6d20226e6f746522
340-quoted|heredoc|6768207072206d657267652037202d2d737175617368202d2d626f6479202270726f736520746861742073617973206768207072206d6572676522
340-quoted|message|6768207072206d657267652037202d2d737175617368202d2d626f6479202270726f736520746861742073617973206768207072206d6572676522
340-quoted|full|6768207072206d657267652037202d2d737175617368202d2d626f647920
340-quoted|sgs|6768207072206d657267652037202d2d737175617368202d2d626f6479202270726f736520746861742073617973206768207072206d6572676522
367-heredoc|heredoc|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a2922
367-heredoc|message|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a2922
367-heredoc|full|676820697373756520656469742031202d2d626f647920
367-heredoc|sgs|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a6769742070757368206f726967696e206d61696e0a454f460a2922
403-commit|heredoc|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a2922
403-commit|message|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a2922
403-commit|full|676820697373756520656469742031202d2d626f647920
403-commit|sgs|676820697373756520656469742031202d2d626f647920222428636174203c3c27454f46270a70726f73652074686174206d656e74696f6e7320612067697420636f6d6d697420696e766f636174696f6e0a454f460a2922
440-msg|heredoc|67697420636f6d6d6974202d6d2022646f63732823343430293a206769742070757368202d2d666f726365206f726967696e206d61696e20646f63756d656e74656422
440-msg|message|67697420636f6d6d6974202d6d20
440-msg|full|67697420636f6d6d6974202d6d20
440-msg|sgs|67697420636f6d6d6974202d6d2022646f63732823343430293a206769742070757368202d2d666f726365206f726967696e206d61696e20646f63756d656e74656422
440-eq|heredoc|67697420636f6d6d6974202d2d6d6573736167653d226769742070757368206f726967696e206d61696e22
440-eq|message|67697420636f6d6d6974202d2d6d6573736167653d
440-eq|full|67697420636f6d6d6974202d2d6d6573736167653d
440-eq|sgs|67697420636f6d6d6974202d2d6d6573736167653d226769742070757368206f726967696e206d61696e22
440-target|heredoc|6769742070757368206f726967696e20226d61696e22
440-target|message|6769742070757368206f726967696e20226d61696e22
440-target|full|6769742070757368206f726967696e20
440-target|sgs|6769742070757368206f726967696e20226d61696e22
unclosed|heredoc|67697420636f6d6d6974202d6d2022756e636c6f7365642071756f7465
unclosed|message|67697420636f6d6d6974202d6d2022756e636c6f7365642071756f7465
unclosed|full|67697420636f6d6d6974202d6d2022756e636c6f7365642071756f7465
unclosed|sgs|67697420636f6d6d6974202d6d2022756e636c6f7365642071756f7465
trailnl|heredoc|67697420737461747573
trailnl|message|67697420737461747573
trailnl|full|67697420737461747573
trailnl|sgs|67697420737461747573
plain|heredoc|67697420636f6d6d6974202d6d2078202626206769742070757368206f726967696e20666561742f79
plain|message|67697420636f6d6d6974202d6d20202626206769742070757368206f726967696e20666561742f79
plain|full|67697420636f6d6d6974202d6d2078202626206769742070757368206f726967696e20666561742f79
plain|sgs|67697420636f6d6d6974202d6d2078202626206769742070757368206f726967696e20666561742f79
glued|heredoc|67697420636f6d6d6974202d6d2022782226266769742070757368202d2d666f726365206f726967696e206d61696e
glued|message|67697420636f6d6d6974202d6d2026266769742070757368202d2d666f726365206f726967696e206d61696e
glued|full|67697420636f6d6d6974202d6d2026266769742070757368202d2d666f726365206f726967696e206d61696e
glued|sgs|67697420636f6d6d6974202d6d20227822202626206769742070757368202d2d666f726365206f726967696e206d61696e
S660GOLD
)

# Target repo for the end-to-end arms: on the protected branch `main`, registered
# in $S660_REG_ON's registry (a per-§159 isolated ghjig state dir, so nothing here
# perturbs $SMOKE_REG or the §357 live-sink backstop).
S660_TARGET="$S660_DIR/target"
mkdir -p "$S660_TARGET"
S660_TARGET=$(cd "$S660_TARGET" && pwd -P)
(cd "$S660_TARGET" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; })
 git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
printf '%s\n' "$S660_TARGET" > "$S660_REG_ON/registry.txt"
: > "$S660_REG_OFF/registry.txt"

# Fixture count-guard. `! -L` on the shims: a symlink there would mean the heredoc
# wrote THROUGH a coreutils link instead of installing the shim.
if [ -z "$s660_missing" ] \
   && [ -x "$S660_BIN/python3" ] && [ ! -L "$S660_BIN/python3" ] \
   && [ -x "$S660_E2E/python3" ] && [ ! -L "$S660_E2E/python3" ] \
   && [ ! -e "$S660_NOPY/python3" ] \
   && [ -d "$S660_TARGET/.git" ] && [ -s "$S660_REG_ON/registry.txt" ]; then
  ok "159-fixture: #660 curated-PATH shim farm + registered main-branch target built"
else
  ng "159-fixture: #660 shim setup incomplete (missing:${s660_missing:- none}) — 159a–159g below are not trustworthy"
fi

# 159a (#660): strip_command_data FAILS CLOSED — returns the command BYTE-IDENTICAL
# to its input — under every enumerated pathology (SPEC §6.1.2) in every mode. RED
# pre-fix on the four exit-0 pathologies (rc-keyed selection returns the junk); the
# `absent` leg is the only one the pre-fix `command -v` gate happens to cover.
# Subshell exits: 3 = shim not on PATH, 4 = shim never ran, 5 = RETURN ≠ INPUT (the
# defect), 6 = python3 still resolvable on the no-python3 PATH, 7 = corpus builder failed.
s660_closed=0; s660_bad=""
for s660_mode in banner partial empty stderr crash; do
  for s660_m in heredoc message full; do
    : > "$S660_STATE/py_calls"; rm -f "$S660_STATE/bad_mode"
    if (
        . "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
        export PATH="$S660_BIN" S660_STATE S660_PY_MODE="$s660_mode"
        [ "$(command -v python3)" = "$S660_BIN/python3" ] || exit 3
        s660_corpus_cmd failclosed s660_in || exit 7
        s660_out=$(strip_command_data "$s660_in" "$s660_m")
        [ -s "$S660_STATE/py_calls" ] || exit 4
        [ ! -e "$S660_STATE/bad_mode" ] || exit 8
        [ "$s660_out" = "$s660_in" ] || exit 5
      ) 2>/dev/null; then
      s660_closed=$((s660_closed+1))
    else
      s660_bad="$s660_bad $s660_mode/$s660_m(rc=$?)"
    fi
  done
done
for s660_m in heredoc message full; do
  if (
      . "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
      export PATH="$S660_NOPY"
      command -v python3 >/dev/null 2>&1 && exit 6
      s660_corpus_cmd failclosed s660_in || exit 7
      s660_out=$(strip_command_data "$s660_in" "$s660_m")
      [ ! -e "$S660_STATE/bad_mode" ] || exit 8
      [ "$s660_out" = "$s660_in" ] || exit 5
    ) 2>/dev/null; then
    s660_closed=$((s660_closed+1))
  else
    s660_bad="$s660_bad absent/$s660_m(rc=$?)"
  fi
done
if [ "$s660_closed" -eq 18 ]; then
  ok "159a: strip_command_data fails closed on every SPEC §6.1.2 pathology × 3 strip modes ($s660_closed/18) (#660)"
else
  ng "159a: strip_command_data returned interpreter JUNK as the stripped command — only $s660_closed/18 failed closed, failed:$s660_bad (5=return≠input, 3=shim off PATH, 4=shim never ran, 6=python3 on the no-python PATH, 7=corpus builder failed, 8=UNKNOWN shim mode — a typo'd S660_PY_MODE, which would otherwise degrade silently to the empty-output mode) (#660)"
fi

# 159b (#660, no-blinding at the unit level): noise on STDERR beside a CORRECT
# stdout is NOT a pathology — the helper's existing `2>/dev/null` already handles
# it, so the strip must still happen. A fix that keys on "anything on stderr" or
# otherwise over-rejects reds here. Reference = the same call under the real
# python3, and the reference must DIFFER from the input or the arm would be vacuous.
# Subshell exits: 3 = shim not on PATH, 4 = shim never ran, 5 = result ≠ reference,
# 6 = reference == input (corpus stopped discriminating), 7 = corpus builder failed.
if [ -z "$S660_REAL_PY" ]; then
  ok "159b: SKIPPED — no python3 on this host, the stderr-noise reference leg is not runnable (#660)"
else
  s660_stripped=0; s660_bad=""
  for s660_m in heredoc message full; do
    : > "$S660_STATE/py_calls"; rm -f "$S660_STATE/bad_mode"
    if (
        . "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
        s660_corpus_cmd failclosed s660_in || exit 7
        s660_ref=$(strip_command_data "$s660_in" "$s660_m")     # ambient real python3
        [ "$s660_ref" != "$s660_in" ] || exit 6
        export PATH="$S660_BIN" S660_STATE S660_REAL_PY S660_PY_MODE=noisy
        [ "$(command -v python3)" = "$S660_BIN/python3" ] || exit 3
        s660_got=$(strip_command_data "$s660_in" "$s660_m")
        [ -s "$S660_STATE/py_calls" ] || exit 4
        [ "$s660_got" = "$s660_ref" ] || exit 5
      ) 2>/dev/null; then
      s660_stripped=$((s660_stripped+1))
    else
      s660_bad="$s660_bad $s660_m(rc=$?)"
    fi
  done
  if [ "$s660_stripped" -eq 3 ]; then
    ok "159b: stderr-only NOISE beside correct stdout still strips (3/3 modes) (#660)"
  else
    ng "159b: an over-eager validity test BLINDED the stripper on harmless stderr noise — only $s660_stripped/3 stripped, failed:$s660_bad (5=result≠reference, 6=reference==input, 3=shim off PATH, 4=shim never ran, 7=corpus builder failed, 8=UNKNOWN shim mode) (#660)"
  fi
fi

# 159c (#660): the SECOND site. space_glued_separators fails closed under the same
# pathologies — and this is the one that fixing only strip_command_data leaves
# broken (measured: force-push / protected-push / gh-pr-merge stay rc=0). Compared
# RAW, not through `$( )`: its sole call site is `space_glued_separators "$cmd" cmd`
# (pre_tool_use.sh:157), an in-place write into the arm-entry variable.
# Subshell exits: 3 = shim not on PATH, 4 = shim never ran, 5 = WRITTEN ≠ INPUT
# (the defect), 6 = python3 still resolvable on the no-python3 PATH, 7 = corpus failed.
s660_closed=0; s660_bad=""
for s660_mode in banner partial empty stderr crash; do
  : > "$S660_STATE/py_calls"; rm -f "$S660_STATE/bad_mode"
  if (
      . "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
      export PATH="$S660_BIN" S660_STATE S660_PY_MODE="$s660_mode"
      [ "$(command -v python3)" = "$S660_BIN/python3" ] || exit 3
      s660_corpus_cmd glued s660_in || exit 7
      space_glued_separators "$s660_in" s660_out
      [ -s "$S660_STATE/py_calls" ] || exit 4
      [ ! -e "$S660_STATE/bad_mode" ] || exit 8
      [ "$s660_out" = "$s660_in" ] || exit 5
    ) 2>/dev/null; then
    s660_closed=$((s660_closed+1))
  else
    s660_bad="$s660_bad $s660_mode(rc=$?)"
  fi
done
if (
    . "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
    export PATH="$S660_NOPY"
    command -v python3 >/dev/null 2>&1 && exit 6
    s660_corpus_cmd glued s660_in || exit 7
    space_glued_separators "$s660_in" s660_out
    [ ! -e "$S660_STATE/bad_mode" ] || exit 8
    [ "$s660_out" = "$s660_in" ] || exit 5
  ) 2>/dev/null; then
  s660_closed=$((s660_closed+1))
else
  s660_bad="$s660_bad absent(rc=$?)"
fi
if [ "$s660_closed" -eq 6 ]; then
  ok "159c: space_glued_separators fails closed on every SPEC §6.1.2 pathology ($s660_closed/6) (#660)"
else
  ng "159c: space_glued_separators wrote interpreter JUNK into the arm-entry \$cmd — only $s660_closed/6 failed closed, failed:$s660_bad (5=written≠input, 3=shim off PATH, 4=shim never ran, 6=python3 on the no-python PATH, 7=corpus builder failed) (#660)"
fi

# 159d (#660, no blinding): under a HEALTHY python3, the whole 44-record
# differential — 11 command shapes (#340 quoted literal, #367/#403 heredoc bodies,
# #440 message-value in `-m`, `=`-glued and quoted-TARGET forms, an unclosed quote,
# a TRAILING-NEWLINE command, a plain multi-segment command, a glued separator)
# × strip_command_data's 3 modes + space_glued_separators — must be BYTE-IDENTICAL
# to the recorded behaviour. This is the guard against "fail closed by always
# returning the command unchanged": 23 of the 44 records differ from their input,
# so such a fix reds on 23 of them. The trailing-newline shape is compared at the
# `$( )` caller boundary for the strip modes (the frame's disclosed residual is
# only observable on a RAW return, and no strip call site reads raw) and raw for
# `sgs` (whose call site IS raw).
if [ -z "$S660_REAL_PY" ]; then
  ok "159d: SKIPPED — no python3 on this host, the healthy-interpreter differential is not runnable (#660)"
else
  s660_gres=$(
    . "$SHELL_ROOT/.claude/hooks/helpers/git_matcher.sh"
    s660_gm=0; s660_gt=0; s660_gd=0; s660_gb=""
    while IFS='|' read -r s660_gid s660_gmode s660_ghex; do
      [ -n "$s660_gid" ] || continue
      s660_gt=$((s660_gt+1))
      if ! s660_corpus_cmd "$s660_gid" s660_in; then
        s660_gb="$s660_gb $s660_gid/$s660_gmode(no-corpus)"; continue
      fi
      if [ "$s660_gmode" = sgs ]; then
        space_glued_separators "$s660_in" s660_out
      else
        s660_out=$(strip_command_data "$s660_in" "$s660_gmode")
      fi
      s660_outhex=$(s660_hex "$s660_out")
      [ "$s660_outhex" = "$(s660_hex "$s660_in")" ] || s660_gd=$((s660_gd+1))
      if [ "$s660_outhex" = "$s660_ghex" ]; then
        s660_gm=$((s660_gm+1))
      else
        s660_gb="$s660_gb $s660_gid/$s660_gmode"
      fi
    done <<< "$S660_GOLDEN"
    printf '%s|%s|%s|%s' "$s660_gm" "$s660_gt" "$s660_gd" "$s660_gb"
  ) 2>/dev/null
  IFS='|' read -r s660_gm s660_gt s660_gd s660_gb <<< "$s660_gres"
  if [ "${s660_gt:-0}" -eq 44 ] && [ "${s660_gm:-0}" -eq 44 ] && [ "${s660_gd:-0}" -ge 23 ]; then
    ok "159d: healthy-python3 differential byte-identical over 44 records, 23+ of them non-trivial (#660)"
  else
    ng "159d: the differential DRIFTED (or the fix blinded the stripper) — matched ${s660_gm:-?}/${s660_gt:-?} records, ${s660_gd:-?} differ from their input (want 44/44 and >=23), drifted:${s660_gb:- none} (#660)"
  fi
fi

# 159e (#660): the in_scope control, BOTH ways, inside this very fixture (curated
# PATH, banner python3, same target repo). Without it an rc=0 in 159f–159h would be
# indistinguishable from "the guard never ran at all" — a green-looking
# no-measurement. Uses an out-of-registry Edit/Write — a matcher that does NOT go
# through either interpreter site — so the control's verdict is independent of #660
# in both directions.
if ! command -v jq >/dev/null 2>&1; then
  ng "159e: jq missing — cannot drive the in_scope control (#660)"
  ng "159f: jq missing (#660)"
  ng "159g: jq missing (#660)"
  ng "159h: jq missing (#660)"
else
  s660_hook_run() {   # $1 = ghjig state dir, $2 = tool JSON, $3 = shim|real python3
    ( cd "$S660_TARGET" || exit 99
      if [ "$3" = shim ]; then export PATH="$S660_E2E" S660_STATE S660_PY_MODE=banner; fi
      printf '%s' "$2" \
        | GHJIG_STATE_DIR_OVERRIDE="$1" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
          bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 )
    return $?
  }
  s660_bash_json() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

  s660_ctl_json=$(jq -nc --arg p "$S660_DIR/outside-the-registry.txt" \
    '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}')
  s660_hook_run "$S660_REG_ON"  "$s660_ctl_json" shim; s660_ctl_on=$?
  s660_hook_run "$S660_REG_OFF" "$s660_ctl_json" shim; s660_ctl_off=$?
  if [ "$s660_ctl_on" = 2 ] && [ "$s660_ctl_off" = 0 ]; then
    ok "159e: in_scope control both ways — registry populated blocks (2), emptied allows (0) (#660)"
  else
    ng "159e: the fixture's guard is not measuring — registry-populated rc=$s660_ctl_on (want 2), registry-emptied rc=$s660_ctl_off (want 0); every rc below is unmeasured (#660)"
  fi

  # 159f: the five irreversible gates, end-to-end, with the banner python3 on the
  # curated PATH and cwd inside the registered repo on `main`. All five must block
  # (rc=2). RED pre-fix: measured rc=0 for all five, because the junk return makes
  # every arm-entry grep miss. `git commit` and `--no-verify` recover once
  # strip_command_data alone is fixed; force-push, protected-push and `gh pr merge`
  # need the space_glued_separators site fixed too.
  s660_blocked=0; s660_bad=""
  for s660_row in \
    "commit|git commit -m 'fix(#660): real subject'" \
    "no-verify|git commit -m 'fix(#660): real subject' --no-verify" \
    "force-push|git push --force origin main" \
    "protected-push|git push origin main" \
    "pr-merge|gh pr merge 1 --squash" \
    ; do
    s660_name=${s660_row%%|*}; s660_cmd=${s660_row#*|}
    : > "$S660_STATE/py_calls"; rm -f "$S660_STATE/bad_mode"
    s660_hook_run "$S660_REG_ON" "$(s660_bash_json "$s660_cmd")" shim; s660_rc=$?
    if [ ! -s "$S660_STATE/py_calls" ]; then
      s660_bad="$s660_bad $s660_name(shim-never-ran)"
    elif [ "$s660_rc" = 2 ]; then
      s660_blocked=$((s660_blocked+1))
    else
      s660_bad="$s660_bad $s660_name(rc=$s660_rc)"
    fi
  done
  if [ "$s660_blocked" -eq 5 ]; then
    ok "159f: all 5 irreversible gates still block under a banner python3 (5/5) (#660)"
  else
    ng "159f: a banner python3 SILENTLY ALLOWED an irreversible gate — only $s660_blocked/5 blocked, allowed:$s660_bad (want rc=2 each; 159e proves an rc=0 here is a real ALLOW) (#660)"
  fi

  # The §108 (#403) heredoc-DATA-only command: `git commit` appearing SOLELY inside
  # a heredoc body. Its verdict is interpreter-dependent by design, so it is pinned
  # in BOTH interpreter states — and the pair is the sharpest statement of what
  # fail-closed means here.
  s660_sq="'"
  s660_data_cmd="gh issue edit 1 --body \"\$(cat <<${s660_sq}EOF${s660_sq}
prose that merely mentions a git commit invocation inside a heredoc body
EOF
)\""

  # 159g (no blinding / no #403 regression): with a HEALTHY python3 the strip
  # succeeds, so the command must still be ALLOWED (rc=0) — §108's own guarantee,
  # re-measured here inside the #660 fixture so a fix that mis-frames a legitimate
  # payload (and thus fails closed even when the interpreter worked) is caught.
  # Runs on the AMBIENT PATH, so it is guarded on a real python3 rather than on the
  # shim marker; no python3 ⇒ LOUD named skip, never a silent pass.
  if [ -z "$S660_REAL_PY" ]; then
    ok "159g: SKIPPED — no python3 on this host, the healthy-interpreter §108 row is not runnable (#660)"
  else
    s660_hook_run "$S660_REG_ON" "$(s660_bash_json "$s660_data_cmd")" real; s660_ok_rc=$?
    if [ "$s660_ok_rc" = 0 ]; then
      ok "159g: under a healthy python3 the §108 heredoc-DATA-only command is still allowed (#403, #660)"
    else
      ng "159g: the fix BLINDED a healthy strip — the §108 heredoc-DATA-only command now false-trips (rc=$s660_ok_rc, want 0) (#403, #660)"
    fi
  fi

  # 159h (#660): the same command under the BANNER python3 must BLOCK (rc=2). This
  # is the direction SPEC §6.1.2 prescribes and docs/TROUBLESHOOTING.md indexes:
  # fail-closed returns the command UNSTRIPPED, so the arm's grep runs against the
  # full text and the #403-shape false-trip legitimately returns — a recoverable,
  # §7-escapable cost whose recovery is "make python3 runnable". RED pre-fix, where
  # this row is rc=0 for the WRONG reason: the arm greps the banner and matches
  # nothing. Pairing it with 159g is what distinguishes "fail closed to unstripped"
  # from "returned junk", which the rc alone cannot tell apart pre-fix.
  : > "$S660_STATE/py_calls"; rm -f "$S660_STATE/bad_mode"
  s660_hook_run "$S660_REG_ON" "$(s660_bash_json "$s660_data_cmd")" shim; s660_data_rc=$?
  if [ ! -s "$S660_STATE/py_calls" ]; then
    ng "159h: the banner python3 shim never ran — the fail-closed-means-unstripped row is unmeasured (#660)"
  elif [ "$s660_data_rc" = 2 ]; then
    ok "159h: a banner python3 leaves the command UNSTRIPPED, so the arm still runs (rc=2) (#660)"
  else
    ng "159h: a banner python3 made the commit arm grep JUNK instead of the unstripped command (rc=$s660_data_rc, want 2; 159e proves this rc is measured) (#660)"
  fi
fi

# ---------- §160 (#662): refuse what the tokenizer cannot parse, at THREE sites (SPEC §6.1.2) ----------
# #660 fixed the two `git_matcher.sh` stripper sites. Three more share the same
# root — a delegated interpreter's output admitted without first asking whether it
# is a result the caller MAY USE — and the two the strippers' framing predicate
# does NOT reach on its own, because here the fail-closed direction is INVERTED:
#
#   1. check_destructive_args (pre_tool_use.sh) keys on `command -v python3` and
#      then on EXIT STATUS. Junk becomes the token LIST the caller ITERATES, and
#      path_in_scope absolutises every relative junk token against `pwd -P` — i.e.
#      INTO the registry. Its `set -f` + `read -ra` fallback rung additionally
#      leaks every QUOTED operand form: `rm -rf "/etc/httpd"` word-splits to a
#      literal `"/etc/httpd"` which is not `/`-anchored, so it too absolutises
#      in-scope. An EMPTY payload frames perfectly validly and reads as a
#      COMPLETED CHECK THAT CHECKED NOTHING (zero path_in_scope calls, return 0).
#   2. parse_env_prefix (helpers/escape.sh) keys on JQ'S EXIT STATUS, and `jq`
#      exits 0 with EMPTY output on empty input — so on any python3 outcome that
#      writes nothing to stdout the `||` fallback never fires and the BLANK is
#      substituted back over `cmd`, which every later Bash matcher greps. Two of
#      the five enumerated outcomes therefore never reach site 1 at all: this is a
#      PRECONDITION for measuring the tokenizer, not an adjacent concern.
#   3. `python3 -c` puts the CWD on sys.path, so a `./shlex.py` planted at an
#      IN-REGISTRY path — a write the shell's own Edit/Write guard permits by
#      design — makes a PERFECTLY HEALTHY interpreter return arbitrary tokens at
#      both of the above sites. `-I` (isolated mode) drops cwd from sys.path.
#
# Arms. 160b/160d/160e/160f/160g/160h are the RED propositions; 160-fixture/160a/
# 160c are the anti-vacuity spine and the no-blinding guard, green on both sides.
#   160-fixture  curated-PATH shim farm + registered target + victim (count-guarded)
#   160a  in_scope control BOTH ways + a same-PATH POSITIVE CONTROL on every one
#         of the 10 PATH/mode variants the arms below use                  GREEN
#   160b  all 5 enumerated outcomes × 3 operand forms block an out-of-registry
#         `rm -rf` (the QUOTED forms are the ones the fallback rung leaks)  RED
#   160c  no blinding: under a HEALTHY interpreter the shipped verdict table is
#         unchanged (in-registry allowed, $HOME/~ still resolving)          GREEN
#   160d  the DISCLOSED over-block, keyed PER OUTCOME, not in aggregate     RED
#   160e  exit-0-partial with a PLAUSIBLE SINGLE TOKEN (`rm`) — an all-command-
#         position list is a FAILED check, not a successful one             RED
#   160f  the upstream BLANKING: under an empty-stdout python3 three irreversible
#         git gates die upstream of the destructive matcher                 RED
#   160g  the `./shlex.py` plant under a HEALTHY interpreter — BOTH -I sites  RED
#   160h  the EMPTY-ARRAY crash: an empty token list must be REFUSED, not run
#         into `for a in "${args[@]}"` under set -u (fatal on bash 3.2.57)   RED
#   160i  the COOPERATIVE ./re.py plant (#664): a validly-FRAMED but ELIDED
#         command forges the force-push verdict under a HEALTHY interpreter  RED
#   160j  the form-independent STATIC lock (#664): every python3 -c/stdin
#         invocation under .claude/hooks/ carries -I (10 unisolated pre-fix) RED
#
# Anti-vacuity (smoke.sh Theme E) — SHARPEST here of anywhere in the suite,
# because on this guard the fail-closed answer IS "block": a BROKEN fixture
# produces exactly the value a block-expecting arm wants and greens. Four measured
# near-misses this round, each of which greened while measuring nothing:
#   (a) a "python3-absent" PATH that still contained /usr/bin — both columns ran
#       the same healthy interpreter and the rows looked identical;
#   (b) a curated PATH so minimal it broke the hook entirely — the positive
#       control itself returned rc=0, a pure no-measurement;
#   (c) `ln -s "$(command -v grep)"` under a shell where `grep` is a FUNCTION —
#       `command -v` prints the bare name and the link dangles silently;
#   (d) a bare `exit 1` default for an unknown shim mode — measured on #661 to
#       leave the equivalent arm 18/18 green, because empty output IS the
#       fail-closed answer and the stderr complaint is swallowed by `2>/dev/null`.
# So: every `command -v` result is PATH-FILTERED before linking (`case $src in /*`),
# the positive control runs on EVERY PATH variant (160a) and is re-run WITH the
# plant in place (160g), every arm asserts the shim was actually INVOKED, an
# unknown shim mode writes an OUT-OF-BAND marker file, and every failure mode gets
# its own exit code so a fixture miss can never masquerade as the intended failure.
S662_DIR="$TMP/iv662"                    # under $TMP → cleaned by the shared EXIT trap
S662_BIN="$S662_DIR/bin"                 # curated PATH + mode-driven python3 shim
S662_NOPY="$S662_DIR/nopy"               # same, with NO python3 at all (absent leg)
S662_HEAL="$S662_DIR/heal"               # same, with the REAL python3 (healthy leg)
S662_STATE="$S662_DIR/state"             # shim invocation markers
S662_REG_ON="$S662_DIR/state-on"         # isolated ghjig state dir, registry POPULATED
S662_REG_OFF="$S662_DIR/state-off"       # isolated ghjig state dir, registry EMPTY
mkdir -p "$S662_BIN" "$S662_NOPY" "$S662_HEAL" "$S662_STATE" "$S662_REG_ON" "$S662_REG_OFF"

# The real python3 by ABSOLUTE path. Empty ⇒ the healthy-leg arms skip LOUD rather
# than silently measuring the ABSENT rung under a "healthy" label.
S662_REAL_PY=$(command -v python3 2>/dev/null || true)
case "$S662_REAL_PY" in /*) ;; *) S662_REAL_PY="" ;; esac

s662_missing=""
for s662_t in sed awk grep head tail tr wc cat cut sort uniq git jq date mkdir rm ls env sh bash id find dirname basename mktemp touch chmod xargs od; do
  s662_src=$(command -v "$s662_t" 2>/dev/null) || { s662_missing="$s662_missing $s662_t"; continue; }
  case "$s662_src" in /*) ;; *) s662_missing="$s662_missing $s662_t(not-a-path)"; continue ;; esac
  ln -sf "$s662_src" "$S662_BIN/$s662_t"
  ln -sf "$s662_src" "$S662_NOPY/$s662_t"
  ln -sf "$s662_src" "$S662_HEAL/$s662_t"
done
[ -n "$S662_REAL_PY" ] && ln -sf "$S662_REAL_PY" "$S662_HEAL/python3"

# The mode-driven python3 shim. Every mode exits 0 unless it names otherwise —
# that is the point: rc answers "did something run?", which is not the question a
# fail-closed contract asks. The shim also RECORDS WHICH CALL SITE it served, so
# 160h can degrade exactly one site while leaving the other healthy (without that,
# the upstream blanking hides the tokenizer's own empty-list behaviour entirely).
# Site discrimination is by PROGRAM TEXT and is therefore fixture-fragile BY
# DESIGN: if a fix changes the program so `cda` is never recorded, 160h fails LOUD
# (exit 9) instead of greening on an unmeasured healthy run. It scans ALL argv
# words, so adding `-I` (which shifts the program from $2 to $3) does not blind it.
cat > "$S662_BIN/python3" <<'S662PY'
#!/bin/sh
: "${S662_STATE:?}"
_site=other
for _a in "$@"; do
  case "$_a" in
    *json*shlex*|*shlex*json*) _site=pep ;;                       # parse_env_prefix
    *shlex*) [ "$_site" = pep ] || _site=cda ;;                   # check_destructive_args
  esac
done
printf '%s\n' "$_site" >> "$S662_STATE/py_calls"
case "${S662_PY_MODE:?}" in
  # exit-0-with-junk: a site/venv/PYTHONSTARTUP banner INSTEAD OF the payload.
  banner)   cat >/dev/null 2>&1; printf 'Python 3.12.0 (venv site banner on stdout)\n' ;;
  # exit-0-partial: a truncated write — a genuine PREFIX of the payload.
  partial)  head -c 12 ;;
  # exit-0-partial in its most PLAUSIBLE form (160e): the write was interrupted
  # after the FIRST token. `rm` is a well-formed one-element token list — and one
  # that consists entirely of command-position words, so the caller's loop runs
  # ZERO path_in_scope calls and returns SUCCESS. Non-empty, so a bare
  # "is there output?" test admits it.
  onetoken) cat >/dev/null 2>&1; printf 'rm\n' ;;
  # exit 0 with nothing at all.
  empty)    cat >/dev/null 2>&1 ;;
  # the payload on STDERR, stdout empty. Shaped like a real token list, so the
  # only thing rejecting it is the channel it arrived on.
  stderr)   cat >/dev/null 2>&1; printf 'rm\n-rf\n/tmp/x\n' >&2 ;;
  # NON-ZERO exit with junk on stdout. Green on BOTH sides of the fix at this site
  # (the pre-fix `if ! tok_out=$(…)` already closes on rc≠0) — a regression +
  # enumerated-outcome coverage guard, NOT a defect witness.
  crash)    cat >/dev/null 2>&1; printf 'Traceback (most recent call last)\n'; exit 1 ;;
  # NOT a pathology (160c): the REAL interpreter plus harmless stderr noise. A fix
  # that keys on "anything on stderr" instead of on output validity reds there.
  noisy)    printf 'DeprecationWarning: fixture noise\n' >&2; exec "${S662_REAL_PY:?}" "$@" ;;
  # 160h: HEALTHY for parse_env_prefix, EMPTY STDOUT for check_destructive_args.
  # Isolates the tokenizer's empty-token-list handling from the upstream blanking,
  # which today swallows every empty-stdout outcome before the matcher is reached.
  emptytok) if [ "$_site" = cda ]; then cat >/dev/null 2>&1; else exec "${S662_REAL_PY:?}" "$@"; fi ;;
  # A typo'd S662_PY_MODE must not silently degrade into a mode that greens. A bare
  # `exit 1` is NOT sufficient (measured on #661: 18/18 green, measuring nothing) —
  # the signal has to be OUT-OF-BAND, because both empty output and a non-zero exit
  # are values a block-expecting arm accepts.
  *)        : > "$S662_STATE/bad_mode" ;;
esac
exit 0
S662PY
chmod +x "$S662_BIN/python3"

# The registered target repo (cwd for every hook fire) and the VICTIM path, which
# is outside BOTH the registry AND $GHJIG_ROOT — path_in_scope carves out
# $GHJIG_ROOT unconditionally, so a victim under the shell root would be allowed
# for a reason that has nothing to do with the tokenizer.
S662_TARGET="$S662_DIR/target"
mkdir -p "$S662_TARGET"
S662_TARGET=$(cd "$S662_TARGET" && pwd -P)
(cd "$S662_TARGET" && (git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; })
 git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null 2>&1
mkdir -p "$S662_TARGET/build" "$S662_TARGET/build dir"
printf '%s\n' "$S662_TARGET" > "$S662_REG_ON/registry.txt"
: > "$S662_REG_OFF/registry.txt"
S662_VICTIM="$S662_DIR/victim-outside-registry"
mkdir -p "$S662_VICTIM"
S662_VICTIM=$(cd "$S662_VICTIM" && pwd -P)

# $1 = ghjig state dir, $2 = tool JSON, $3 = curated PATH dir (or `ambient`),
# $4 = S662_PY_MODE. Script-file mode under the harness's own `set -uo pipefail`
# — never `bash -c`, whose quoting would re-tokenize the very strings under test.
s662_hook_run() {
  ( cd "$S662_TARGET" || exit 99
    if [ "$3" != ambient ]; then export PATH="$3"; fi
    export S662_STATE S662_REAL_PY S662_PY_MODE="$4"
    printf '%s' "$2" \
      | GHJIG_STATE_DIR_OVERRIDE="$1" GHJIG_ROOT_OVERRIDE="$SHELL_ROOT" \
        bash "$SHELL_ROOT/.claude/hooks/pre_tool_use.sh" >/dev/null 2>&1 )
  return $?
}

if ! command -v jq >/dev/null 2>&1; then
  for s662_a in 160-fixture 160a 160b 160c 160d 160e 160f 160g 160h 160i; do
    ng "$s662_a: jq missing — the whole §160 fixture is undrivable (#662)"
  done
else
  s662_bash_json() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
  # The positive control: an Edit on an IN-REGISTRY `.env`. Deliberately a matcher
  # with NO python3 leg at all, so its rc=2 says "the hook is alive on THIS PATH"
  # and nothing about #662 in either direction. In-registry (not out-of-scope) so
  # it measures the sensitive-file arm rather than re-measuring in_scope.
  s662_ctl_json=$(jq -nc --arg p "$S662_TARGET/.env" \
    '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"a",new_string:"b"}}')

  # ---- 160-fixture: count-guard. `! -L` on the shim: a symlink there would mean
  # the heredoc wrote THROUGH a coreutils link instead of installing the shim.
  # The nopy leg is asserted by RESOLUTION, not just by absence of the file —
  # near-miss (a) above was a curated PATH that still reached a real python3.
  s662_nopy_clean=no
  ( PATH="$S662_NOPY"; command -v python3 >/dev/null 2>&1 ) || s662_nopy_clean=yes
  s662_heal_ok=no
  [ -z "$S662_REAL_PY" ] || { [ "$( ( PATH="$S662_HEAL"; command -v python3 ) )" = "$S662_HEAL/python3" ] && s662_heal_ok=yes; }
  if [ -z "$s662_missing" ] \
     && [ -x "$S662_BIN/python3" ] && [ ! -L "$S662_BIN/python3" ] \
     && [ "$s662_nopy_clean" = yes ] \
     && [ -d "$S662_TARGET/.git" ] && [ -s "$S662_REG_ON/registry.txt" ] \
     && [ -d "$S662_VICTIM" ] && [ ! -e "$S662_REG_ON/registry.txt.bak" ]; then
    ok "160-fixture: #662 curated-PATH shim farm + registered target + out-of-registry victim built"
  else
    ng "160-fixture: #662 shim setup incomplete (missing:${s662_missing:- none}, nopy-clean=$s662_nopy_clean, heal=$s662_heal_ok) — 160a–160h below are not trustworthy (#662)"
  fi

  # ---- 160a: the anti-vacuity spine. The positive control on EVERY PATH/mode
  # variant the arms below use (10 of them) must return rc=2, and the SAME probe
  # with the registry EMPTIED must return rc=0. Without the first half an rc=0
  # below could mean "the curated PATH broke the hook"; without the second half an
  # rc=2 could mean "everything blocks here". Both halves are needed because on
  # this guard the fail-closed answer IS the value the block arms want.
  s662_ctl_ok=0; s662_ctl_bad=""
  for s662_row in "bin|banner" "bin|partial" "bin|onetoken" "bin|empty" "bin|stderr" \
                  "bin|crash" "bin|noisy" "bin|emptytok" "nopy|absent" "heal|healthy"; do
    s662_pd=${s662_row%%|*}; s662_md=${s662_row#*|}
    case "$s662_pd" in
      bin) s662_path="$S662_BIN" ;;
      nopy) s662_path="$S662_NOPY" ;;
      *) s662_path="$S662_HEAL" ;;
    esac
    if [ -z "$S662_REAL_PY" ] && { [ "$s662_md" = noisy ] || [ "$s662_md" = emptytok ] || [ "$s662_md" = healthy ]; }; then
      s662_ctl_ok=$((s662_ctl_ok+1)); continue     # leg not runnable; its arm skips LOUD below
    fi
    s662_hook_run "$S662_REG_ON" "$s662_ctl_json" "$s662_path" "$s662_md"; s662_rc=$?
    if [ "$s662_rc" = 2 ]; then s662_ctl_ok=$((s662_ctl_ok+1)); else s662_ctl_bad="$s662_ctl_bad $s662_pd/$s662_md(rc=$s662_rc)"; fi
  done
  s662_hook_run "$S662_REG_OFF" "$s662_ctl_json" "$S662_BIN" banner; s662_ctl_off=$?
  if [ "$s662_ctl_ok" -eq 10 ] && [ "$s662_ctl_off" = 0 ]; then
    ok "160a: same-PATH positive control alive on all 10 PATH/mode variants (rc=2) and in_scope control both ways (registry emptied → rc=0) (#662)"
  else
    ng "160a: the §160 fixture is NOT MEASURING — positive control passed only $s662_ctl_ok/10 (dead:$s662_ctl_bad, want rc=2 each), registry-emptied rc=$s662_ctl_off (want 0); every rc in 160b–160h is unmeasured (#662)"
  fi

  # ---- 160b (RED): the five SPEC §6.1.2 outcomes × three operand forms. An
  # out-of-registry `rm -rf` must BLOCK under every one. The QUOTED forms are the
  # fallback rung's own leak (`"/…"` is not `/`-anchored → absolutised against
  # `pwd -P` → in-scope), so bare-only coverage would miss half the defect.
  # Measured pre-fix: 14 of 18 rows rc=0. Only crash/{bare,quoted,squoted} (the
  # rc≠0 outcome an rc-keyed selector DOES cover) and absent/bare block today.
  # Row codes: rc is the hook's exit; 4 = shim never ran; 8 = unknown shim mode.
  s662_blocked=0; s662_bad=""
  for s662_mode in banner partial empty stderr crash absent; do
    s662_path="$S662_BIN"; [ "$s662_mode" = absent ] && s662_path="$S662_NOPY"
    for s662_form in bare dquoted squoted; do
      case "$s662_form" in
        bare)    s662_cmd="rm -rf $S662_VICTIM" ;;
        dquoted) s662_cmd="rm -rf \"$S662_VICTIM\"" ;;
        squoted) s662_cmd="rm -rf '$S662_VICTIM'" ;;
      esac
      : > "$S662_STATE/py_calls"; rm -f "$S662_STATE/bad_mode"
      s662_hook_run "$S662_REG_ON" "$(s662_bash_json "$s662_cmd")" "$s662_path" "$s662_mode"; s662_rc=$?
      if [ -e "$S662_STATE/bad_mode" ]; then
        s662_bad="$s662_bad $s662_mode/$s662_form(rc=8-unknown-shim-mode)"
      elif [ "$s662_mode" != absent ] && [ ! -s "$S662_STATE/py_calls" ]; then
        s662_bad="$s662_bad $s662_mode/$s662_form(rc=4-shim-never-ran)"
      elif [ "$s662_rc" = 2 ]; then
        s662_blocked=$((s662_blocked+1))
      else
        s662_bad="$s662_bad $s662_mode/$s662_form(rc=$s662_rc)"
      fi
    done
  done
  if [ "$s662_blocked" -eq 18 ]; then
    ok "160b: an out-of-registry rm -rf blocks under all 5 §6.1.2 outcomes × 3 operand forms (18/18) (#662)"
  else
    ng "160b: a degraded python3 SILENTLY ALLOWED rm -rf outside the registry — only $s662_blocked/18 blocked, allowed:$s662_bad (want rc=2 each; the exit-0 rows are junk laundered into scope by path_in_scope's pwd-absolutisation, the absent/quoted rows are the fallback rung's own leak; 160a proves an rc=0 here is a REAL allow) (#662)"
  fi

  # ---- 160c (GREEN, no-blinding regression guard): under a HEALTHY interpreter
  # the shipped verdict table must be BYTE-FOR-BYTE what it is today. "Block
  # everything" is not a fix; neither is a validity predicate so eager that
  # harmless stderr noise beside a correct stdout blinds the tokenizer (the
  # `noisy` rows). The $HOME/~/${HOME} rows pin that path_in_scope's substitution
  # arms still resolve as before (issue #662 AC6). Rows are `name|want-rc|command`.
  if [ -z "$S662_REAL_PY" ]; then
    ok "160c: SKIPPED — no python3 on this host, the healthy-interpreter verdict table is not runnable (#662)"
  else
    s662_gm=0; s662_gt=0; s662_bad=""
    for s662_row in \
      "healthy-rel|0|rm -rf ./build" \
      "healthy-abs|0|rm -rf $S662_TARGET/build" \
      "healthy-quoted-space|0|rm -rf \"$S662_TARGET/build dir\"" \
      "healthy-unrelated-quote|0|mv ./a ./b && echo \"done\"" \
      "healthy-tilde|2|rm -rf ~/no-such-662-victim" \
      "healthy-home-var|2|rm -rf \$HOME/no-such-662-victim" \
      "healthy-home-brace|2|rm -rf \${HOME}/no-such-662-victim" \
      "noisy-in-registry|0|rm -rf ./build" \
      "noisy-out-of-registry|2|rm -rf $S662_VICTIM" \
      ; do
      IFS='|' read -r s662_name s662_want s662_cmd <<< "$s662_row"
      s662_gt=$((s662_gt+1))
      case "$s662_name" in
        noisy-*) s662_path="$S662_BIN"; s662_mode=noisy ;;
        *)       s662_path="$S662_HEAL"; s662_mode=healthy ;;
      esac
      s662_hook_run "$S662_REG_ON" "$(s662_bash_json "$s662_cmd")" "$s662_path" "$s662_mode"; s662_rc=$?
      if [ "$s662_rc" = "$s662_want" ]; then
        s662_gm=$((s662_gm+1))
      else
        s662_bad="$s662_bad $s662_name(rc=$s662_rc,want=$s662_want)"
      fi
    done
    if [ "$s662_gm" -eq 9 ] && [ "$s662_gt" -eq 9 ]; then
      ok "160c: under a healthy python3 the destructive matcher's verdict table is unchanged (9/9, incl. stderr-noise and the \$HOME/~ arms) (#662)"
    else
      ng "160c: the fix BLINDED or OVER-BLOCKED a healthy interpreter — only $s662_gm/$s662_gt verdicts unchanged, drifted:$s662_bad (a fix that blocks everything is not a fix, #662 AC1/AC6) (#662)"
    fi
  fi

  # ---- 160d (RED): the DISCLOSED over-block, keyed PER OUTCOME. The refusal keys
  # on the WHOLE command string, not the destructive segment, so a fully
  # in-registry `mv ./a ./b && echo "done"` — the quote living in an UNRELATED
  # segment — blocks whenever the interpreter is degraded (SPEC §6.1.2). Stated in
  # aggregate the comparison to shipped behaviour would be FALSE, so it is pinned
  # per outcome: for `crash` this is NARROWER than today (today's `return 1`
  # already blocks every in-registry destructive command — that row is green now);
  # for `absent` it is a WIDENING, 0 → 2. Measured pre-fix: 5 of 6 rows rc=0.
  s662_blocked=0; s662_bad=""
  for s662_mode in banner partial empty stderr crash absent; do
    s662_path="$S662_BIN"; [ "$s662_mode" = absent ] && s662_path="$S662_NOPY"
    : > "$S662_STATE/py_calls"; rm -f "$S662_STATE/bad_mode"
    s662_hook_run "$S662_REG_ON" "$(s662_bash_json "mv ./a ./b && echo \"done\"")" "$s662_path" "$s662_mode"; s662_rc=$?
    if [ -e "$S662_STATE/bad_mode" ]; then
      s662_bad="$s662_bad $s662_mode(rc=8-unknown-shim-mode)"
    elif [ "$s662_rc" = 2 ]; then
      s662_blocked=$((s662_blocked+1))
    else
      s662_bad="$s662_bad $s662_mode(rc=$s662_rc)"
    fi
  done
  if [ "$s662_blocked" -eq 6 ]; then
    ok "160d: a degraded interpreter refuses rather than degrades — the disclosed whole-command over-block holds on all 6 outcomes (#662)"
  else
    ng "160d: the fallback rung DEGRADED to a weaker parse instead of refusing — only $s662_blocked/6 outcomes blocked the quote-bearing in-registry command, allowed:$s662_bad (want rc=2 each; narrower than today for crash, a widening for absent — SPEC §6.1.2) (#662)"
  fi

  # ---- 160e (RED): exit-0-partial in its most PLAUSIBLE form. The shim writes a
  # single well-formed token, `rm`. It is non-empty (so a bare output-presence test
  # admits it) and consists entirely of COMMAND-POSITION words, so the caller's
  # loop makes ZERO path_in_scope calls and returns SUCCESS — a one-token
  # all-command-position list must be read as a FAILED check, not a successful one.
  # Measured pre-fix: rc=0.
  : > "$S662_STATE/py_calls"; rm -f "$S662_STATE/bad_mode"
  s662_hook_run "$S662_REG_ON" "$(s662_bash_json "rm -rf $S662_VICTIM")" "$S662_BIN" onetoken; s662_rc=$?
  if [ -e "$S662_STATE/bad_mode" ]; then
    ng "160e: UNKNOWN shim mode (typo'd S662_PY_MODE) — the single-plausible-token row is unmeasured (#662)"
  elif [ ! -s "$S662_STATE/py_calls" ]; then
    ng "160e: the onetoken shim never ran — the single-plausible-token row is unmeasured (#662)"
  elif [ "$s662_rc" = 2 ]; then
    ok "160e: a one-token all-command-position list is treated as a FAILED check (rc=2) (#662)"
  else
    ng "160e: a truncated one-token list ('rm') was accepted as a COMPLETED check that checked nothing — rc=$s662_rc, want 2 (zero path_in_scope calls read as 'every operand was in scope'; 160a proves this rc is measured) (#662)"
  fi

  # ---- 160f (RED): the UPSTREAM blanking, a separate arm from 160b because these
  # commands die BEFORE the destructive matcher is ever reached. parse_env_prefix
  # keys on JQ's exit status and `jq` exits 0 with EMPTY output on empty input, so
  # on any python3 outcome that writes nothing to stdout the blank is substituted
  # back over `cmd` and EVERY Bash matcher greps an empty string. Measured pre-fix:
  # all 6 rows rc=0, with the same-PATH positive control (160a) at rc=2 — the hook
  # was alive and matching nothing.
  s662_blocked=0; s662_bad=""
  for s662_mode in empty stderr; do
    for s662_cmd in "git push --force origin main" "git reset --hard" "git clean -fd"; do
      : > "$S662_STATE/py_calls"; rm -f "$S662_STATE/bad_mode"
      s662_hook_run "$S662_REG_ON" "$(s662_bash_json "$s662_cmd")" "$S662_BIN" "$s662_mode"; s662_rc=$?
      if [ -e "$S662_STATE/bad_mode" ]; then
        s662_bad="$s662_bad $s662_mode/${s662_cmd% *}(rc=8-unknown-shim-mode)"
      elif [ ! -s "$S662_STATE/py_calls" ]; then
        s662_bad="$s662_bad $s662_mode/${s662_cmd% *}(rc=4-shim-never-ran)"
      elif [ "$s662_rc" = 2 ]; then
        s662_blocked=$((s662_blocked+1))
      else
        s662_bad="$s662_bad $s662_mode/${s662_cmd% *}(rc=$s662_rc)"
      fi
    done
  done
  # Guard: the same three commands under a HEALTHY interpreter must block, or the
  # six rows above prove nothing about the blanking.
  s662_ref=0
  if [ -n "$S662_REAL_PY" ]; then
    for s662_cmd in "git push --force origin main" "git reset --hard" "git clean -fd"; do
      s662_hook_run "$S662_REG_ON" "$(s662_bash_json "$s662_cmd")" "$S662_HEAL" healthy; s662_rc=$?
      [ "$s662_rc" = 2 ] && s662_ref=$((s662_ref+1))
    done
  else
    s662_ref=3    # not runnable; 160a already proved the hook is alive on this PATH
  fi
  if [ "$s662_blocked" -eq 6 ] && [ "$s662_ref" -eq 3 ]; then
    ok "160f: an empty-stdout python3 no longer blanks the command — 3 irreversible git gates still block on both empty-stdout outcomes (6/6) (#662)"
  else
    ng "160f: an empty-stdout python3 BLANKED \$cmd upstream and every Bash matcher greped an empty string — only $s662_blocked/6 blocked, allowed:$s662_bad; healthy reference $s662_ref/3 (want 3, else the arm is unmeasured) (parse_env_prefix keys on jq's exit status, and jq exits 0 with empty output on empty input — SPEC §6.1.2) (#662)"
  fi

  # ---- 160g (RED): the `./shlex.py` plant. `python3 -c` puts the CWD on
  # sys.path, so a file written to an IN-REGISTRY path — a write the shell's own
  # Edit/Write scope guard PERMITS BY DESIGN — shadows the stdlib module both
  # programs import, and a PERFECTLY HEALTHY interpreter returns whatever it says.
  # The plant forges ACTIVELY (it returns real tokens, `echo harmless`) rather than
  # returning nothing, so this arm does not ride on the 160f blanking and stays a
  # live witness after 160f is fixed.
  #
  # BOTH -I sites are load-bearing, verified by mutation at Phase-B time
  # (rc per row, plant in place, healthy interpreter):
  #        -I at:   none    cda-only   pep-only   both
  #   rm -rf <out>    0         0          0        2
  #   git push -f     0         0          2        2
  #   git reset       0         0          2        2
  #   git clean -fd   0         0          2        2
  # cda-only leaves ALL FOUR forged, because parse_env_prefix substitutes the
  # plant's output back over the command string every later matcher reads; pep-only
  # leaves the rm row forged. Hence the four rows below, not one.
  if [ -z "$S662_REAL_PY" ]; then
    ok "160g: SKIPPED — no python3 on this host, the cwd-import plant is not runnable (#662)"
  else
    # Negative leg FIRST, with no plant: these must already block, or the plant
    # rows below measure nothing.
    s662_ref=0
    for s662_cmd in "rm -rf $S662_VICTIM" "git push --force origin main" "git reset --hard" "git clean -fd"; do
      s662_hook_run "$S662_REG_ON" "$(s662_bash_json "$s662_cmd")" "$S662_HEAL" healthy; s662_rc=$?
      [ "$s662_rc" = 2 ] && s662_ref=$((s662_ref+1))
    done
    cat > "$S662_TARGET/shlex.py" <<'S662PLANT'
def split(s, comments=False, posix=True):
    return ["echo", "harmless"]
def join(seq):
    return "echo harmless"
def quote(s):
    return s
S662PLANT
    s662_blocked=0; s662_bad=""
    for s662_cmd in "rm -rf $S662_VICTIM" "git push --force origin main" "git reset --hard" "git clean -fd"; do
      s662_hook_run "$S662_REG_ON" "$(s662_bash_json "$s662_cmd")" "$S662_HEAL" healthy; s662_rc=$?
      if [ "$s662_rc" = 2 ]; then s662_blocked=$((s662_blocked+1)); else s662_bad="$s662_bad ${s662_cmd% *}(rc=$s662_rc)"; fi
    done
    # Positive control re-measured WITH the plant in place and on the same PATH:
    # proves the plant disarms the python3-delegating matchers specifically, not
    # the hook as a whole.
    s662_hook_run "$S662_REG_ON" "$s662_ctl_json" "$S662_HEAL" healthy; s662_ctl_plant=$?
    rm -f "$S662_TARGET/shlex.py"
    rm -rf "$S662_TARGET/__pycache__"
    if [ "$s662_blocked" -eq 4 ] && [ "$s662_ref" -eq 4 ] && [ "$s662_ctl_plant" = 2 ]; then
      ok "160g: a ./shlex.py planted inside the registry cannot forge the decision under a healthy python3 (4/4 still block) (#662)"
    else
      ng "160g: an in-registry ./shlex.py FORGED the verdict of a healthy interpreter — only $s662_blocked/4 blocked, allowed:$s662_bad; no-plant reference $s662_ref/4 (want 4) and same-PATH control rc=$s662_ctl_plant (want 2, else the arm is unmeasured) (python3 -c puts cwd on sys.path; -I is needed at BOTH check_destructive_args and parse_env_prefix — SPEC §6.1.2) (#662)"
    fi
  fi

  # ---- 160h (RED): the EMPTY-ARRAY crash. An empty token list frames perfectly
  # validly and is the one outcome the strippers' predicate does NOT reject, so the
  # tokenizer must refuse it explicitly. Today it reaches
  # `for arg in "${args[@]}"` with an empty array under `set -u`, which on bash
  # 3.2.57 is a FATAL `args[@]: unbound variable` — the hook exits 1, which is a
  # NON-BLOCKING allow AND skips every later matcher. The second row proves the
  # second half: it also carries `git reset --hard`, whose own arm sits below the
  # destructive one and never runs. Reachable ONLY through the site-aware shim
  # (the upstream blanking hides it otherwise), so this arm REDS TODAY at rc=1 —
  # it is a live witness, not a forward guard.
  if [ -z "$S662_REAL_PY" ]; then
    ok "160h: SKIPPED — no python3 on this host, the site-isolated empty-token-list leg is not runnable (#662)"
  else
    s662_blocked=0; s662_bad=""
    for s662_cmd in "rm -rf $S662_VICTIM" "rm -rf $S662_VICTIM && git reset --hard"; do
      : > "$S662_STATE/py_calls"; rm -f "$S662_STATE/bad_mode"
      s662_hook_run "$S662_REG_ON" "$(s662_bash_json "$s662_cmd")" "$S662_BIN" emptytok; s662_rc=$?
      if [ -e "$S662_STATE/bad_mode" ]; then
        s662_bad="$s662_bad ${s662_cmd% *}(rc=8-unknown-shim-mode)"
      elif ! grep -q '^cda$' "$S662_STATE/py_calls" 2>/dev/null; then
        s662_bad="$s662_bad ${s662_cmd% *}(rc=9-shim-no-longer-discriminates-the-tokenizer-call)"
      elif [ "$s662_rc" = 2 ]; then
        s662_blocked=$((s662_blocked+1))
      else
        s662_bad="$s662_bad ${s662_cmd% *}(rc=$s662_rc)"
      fi
    done
    if [ "$s662_blocked" -eq 2 ]; then
      ok "160h: an EMPTY token list is refused (rc=2), not iterated into a fatal unbound-variable (2/2) (#662)"
    else
      ng "160h: an empty token list crashed the hook instead of being refused — $s662_blocked/2 blocked, failed:$s662_bad (rc=1 is the bash 3.2.57 fatal 'args[@]: unbound variable' → a non-blocking allow that also skips every later matcher; rc=0 would be a completed check that checked nothing) (#662)"
    fi
  fi

  # ---- 160i (RED, #664): the measured COOPERATIVE plant. #660's constant-tag
  # frame rejects a *degraded* interpreter, but the plant controls the PAYLOAD,
  # not the tag: a cooperative in-registry ./re.py runs strip_command_data to
  # completion and emits a validly-FRAMED but ELIDED command, so the force-push
  # AND protected-push arms (both `message` mode — pre_tool_use.sh:1166/:1245 via
  # git_matcher.sh:118) grep only spaces and never fire. Measured end-to-end
  # pre-fix: `git push --force origin main` is rc=0 WITH the plant, rc=2 without —
  # a real allow through a LIVE hook, silent because block() is never reached and
  # nothing is audited. `-I` at git_matcher.sh:118 (drops cwd from sys.path)
  # closes it. This arm REDS pre-fix (the cooperative row measures rc=0).
  #
  # Five legs, each its own rc so a fixture miss cannot masquerade as the verdict:
  #   ref     no plant, healthy interpreter — must already block (rc=2) or the
  #           cooperative leg measures nothing
  #   shadow  FIXTURE INTEGRITY: a bare `python3 -c` from the target cwd must
  #           resolve `re` to the PLANTED ./re.py, not the stdlib — proves the
  #           plant is live (the #662 five-agent trap: a plant that never loads
  #           gives rc=2 and greens this block-expecting arm)
  #   coop    the cooperative plant present — the measured bypass (rc=0 pre-fix)
  #   ctl     same-PATH positive control WITH the plant: an Edit on .env has no
  #           re-importing python3 leg, so its rc=2 says the middle cell is a REAL
  #           allow, not a dead fixture
  #   broken  the plant replaced with `raise ImportError`: `import re` fails,
  #           python3 exits non-zero, stdout empty → unframed → fail-closed → rc=2,
  #           BYTE-IDENTICAL to healthy for this input. Asserted as its OWN leg and
  #           explicitly NOT a bypass witness — a broken plant is the exact shape
  #           of the earlier negative that "looked conclusive and was not" (SPEC
  #           §6.1.2); keeping it prevents a future fixture regression from the
  #           cooperative plant to a broken one greening while measuring nothing.
  if [ -z "$S662_REAL_PY" ]; then
    ok "160i: SKIPPED — no python3 on this host, the cooperative ./re.py plant is not runnable (#664)"
  else
    s664_fp=$(s662_bash_json "git push --force origin main")
    s662_hook_run "$S662_REG_ON" "$s664_fp" "$S662_HEAL" healthy; s664_ref=$?
    # The cooperative plant, EXACTLY as issue #664 AC2 specifies: it runs the
    # program to completion (finditer → [], so no heredoc walk) and, in `message`
    # mode, returns a match for any flag pattern containing "message"/"--file" with
    # EMPTY groups — which elides every command word, leaving a framed run of
    # spaces the arms' entry greps miss.
    cat > "$S662_TARGET/re.py" <<'S664PLANT'
class _M:
    def __init__(self, g1="", g2=" "): self._g = (None, g1, g2)
    def group(self, i): return self._g[i]
    def start(self): return 0
class _P:
    def __init__(self, pat): self.pat = pat
    def match(self, s, pos=None):
        # the heredoc-delimiter pattern must NOT match; the message-flag one must
        if "message" in self.pat or "--file" in self.pat:
            return _M("", " ")
        return None
    def finditer(self, s): return []
def compile(pat, *a, **k): return _P(pat)
def finditer(pat, s, *a, **k): return []
def match(pat, s, *a, **k): return None
S664PLANT
    s664_shadow=$( cd "$S662_TARGET" && PATH="$S662_HEAL" python3 -c 'import re,sys; sys.stdout.write(re.__file__)' 2>/dev/null )
    s662_hook_run "$S662_REG_ON" "$s664_fp" "$S662_HEAL" healthy; s664_coop=$?
    s662_hook_run "$S662_REG_ON" "$s662_ctl_json" "$S662_HEAL" healthy; s664_ctl=$?
    printf 'raise ImportError("planted")\n' > "$S662_TARGET/re.py"
    s662_hook_run "$S662_REG_ON" "$s664_fp" "$S662_HEAL" healthy; s664_broken=$?
    rm -f "$S662_TARGET/re.py"
    rm -rf "$S662_TARGET/__pycache__"
    # The shadow probe decides whether the cwd-plant STDLIB-shadow class applies on
    # THIS interpreter, THREE-way:
    #   plant path  → cwd is searched ahead of the stdlib for a bare -c (system
    #                 python 3.9, the primary environment): the plant is live, run
    #                 the full behavioral assertion.
    #   other path  → `import re` resolved to the stdlib despite ./re.py in cwd, so
    #                 cwd is NOT searched ahead of it (safe-path default on 3.11+ /
    #                 PYTHONSAFEPATH, or an isolating Homebrew/CI build; observed on
    #                 the CI macos python@3.14 runner). The class does not apply
    #                 here, so the behavioral leg is out of scope — SKIP, not red
    #                 (same posture as the no-python3 skip). NOT a coverage loss:
    #                 §160j enforces -I at every site unconditionally, and the
    #                 primary interpreter still runs the assertion.
    #   empty       → the probe did not run / import re at all: a broken fixture.
    if [ "$s664_shadow" = "$S662_TARGET/re.py" ]; then
      if [ "$s664_ref" = 2 ] && [ "$s664_coop" = 2 ] && [ "$s664_ctl" = 2 ] && [ "$s664_broken" = 2 ]; then
        ok "160i: a cooperative in-registry ./re.py cannot forge the force-push verdict under a healthy python3 — blocks with plant (rc=2), without it (rc=2), broken plant fails closed (rc=2), .env control alive (rc=2) (#664)"
      else
        ng "160i: a cooperative in-registry ./re.py ELIDED the command and FORGED a healthy interpreter's force-push verdict — plant rc=$s664_coop (want 2; pre-fix this is 0, the measured bypass), no-plant reference rc=$s664_ref (want 2), .env control rc=$s664_ctl (want 2, else the arm is unmeasured), broken-plant rc=$s664_broken (want 2, fail-closed and byte-identical to healthy — NOT a substitute for the cooperative leg) (strip_command_data at git_matcher.sh:118 needs python3 -I -c; SPEC §6.1.2) (#664)"
      fi
    elif [ -n "$s664_shadow" ]; then
      ok "160i: SKIPPED — this python3 does not place cwd ahead of the stdlib for a bare -c (re resolved to '$s664_shadow'), so the cwd-plant stdlib-shadow class does not apply on this interpreter; §160j enforces -I regardless (#664)"
    else
      ng "160i: the shadow probe produced NO output — a bare python3 -c failed to run or import re at all, so the fixture is broken, not measured (#664)"
    fi
  fi
fi

# ---- 160j (RED, #664): the form-independent STATIC lock. Every non-comment line
# under .claude/hooks/ that invokes python3 in -c or stdin form must carry -I — a
# new site, or a dropped flag, reds here without anyone re-running a plant (SPEC
# §6.1.2). SEMANTICS CHOICE (one, implemented exactly): the matcher is
# INVOCATION-SHAPED, anchored on a python3 that runs from a command position — the
# line start, or immediately after a pipe / `$(` / backtick / `exec ` / `;` / `&&`
# — with an OPTIONAL `NAME=value …` environment-assignment prefix admitted between
# the anchor and `python3`. NOT any substring. The env-prefix admission is the #684
# round-1 fix: the shipped anchored form matched only plain-pipe invocations and
# missed the env-prefix idiom (`$(CMD="$cmd" python3 -c …)`, live at
# 60-escape-identity.sh:1528) — the exact escape B1 was carried forward to close,
# so the matcher must SEE it (SPEC §1.10(c): a durable claim's coverage must not
# exceed what it measures). This still deliberately excludes the two PROSE recovery
# strings at pre_tool_use.sh:113/:128 (they follow a bare `(`, not `$(` or a
# command anchor) and the `command -v python3` availability probes (a token-
# boundary matcher would false-red those — measured, disqualified). It remains an
# anchor ENUMERATION, not a universal: exotic launchers (`if python3`, `time
# python3`) sit outside it — the SPEC sentence names the anchored shapes rather
# than claiming literally "every" form. Pre-fix census: 12 real invocation sites, 2
# already -I (#662 at pre_tool_use.sh:86 / escape.sh:215), 10 not → RED. Phase C
# adds -I to the 10 → 0 unisolated → green. The positive counts are the anti-
# vacuity floor: a regex that matched nothing would report 0 violations and green
# pre-fix, so the arm refuses to pass unless it SEES the known sites (total >= 12)
# and its -I arm is alive (iso >= 2). This arm needs no jq or python3, so it sits
# OUTSIDE the jq gate above.
s664j_dir="$SHELL_ROOT/.claude/hooks"
s664j_re='(^|\||\$\(|`|exec[[:space:]]+|;[[:space:]]*|&&[[:space:]]*)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*python3([[:space:]]|$)'
s664j_sites=$(grep -rnE "$s664j_re" "$s664j_dir" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
s664j_total=$(printf '%s\n' "$s664j_sites" | grep -cE 'python3')
s664j_iso=$(printf '%s\n' "$s664j_sites" | grep -cE 'python3[[:space:]]+-I')
s664j_bad=$(printf '%s\n' "$s664j_sites" | grep -vE 'python3[[:space:]]+-I' | grep -cE 'python3')
s664j_badsites=$(printf '%s\n' "$s664j_sites" | grep -vE 'python3[[:space:]]+-I' | grep -E 'python3' | sed 's#.*/\.claude/hooks/##; s/:.*//' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
if [ "$s664j_total" -lt 12 ]; then
  ng "160j: the invocation-shaped python3 matcher lost sites — found only $s664j_total invocation site(s) under .claude/hooks/ (want >=12); the static lock is UNMEASURED, not passing (#664)"
elif [ "$s664j_iso" -lt 2 ]; then
  ng "160j: the -I detection arm matched nothing ($s664j_iso, want >=2 — the two #662 sites already carry -I); the matcher is broken, the arm is unmeasured (#664)"
elif [ "$s664j_bad" -eq 0 ]; then
  ok "160j: every python3 -c/stdin invocation under .claude/hooks/ carries -I ($s664j_total sites, $s664j_iso isolated, 0 unisolated) (#664)"
else
  ng "160j: $s664j_bad python3 -c/stdin invocation site(s) under .claude/hooks/ run WITHOUT -I (of $s664j_total total; by file: $s664j_badsites) — a cwd import can shadow a non-preloaded module and forge the decision (SPEC §6.1.2). Fix: python3 -I -c (#664)"
fi

