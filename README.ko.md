# claude-eng-shell

[English](README.md) | **한국어**

**[Claude Code](https://docs.claude.com/claude-code)를 위한, 강한 의견(opinionated)을 담은 워크플로 셸입니다.** 이 셸은 Claude Code 세션을, 숙련된 사람이 GitHub 저장소에서 적용할 엔지니어링 규율 — issue → branch → draft PR → reviewed commits → ready merge — 으로 감싸고, 그 규율을 hook, slash command, subagent, 그리고 audit trail로 구현합니다. 목적은 AI가 엔지니어링 작업을 처음부터 끝까지 주도하면서도, 신중한 사람이라면 건너뛰지 않을 점검들을 지나쳐 드리프트(drift)하지 않도록 하는 것입니다.

- **[MISSION.md](MISSION.md)** — 12개월 후의 성공이 어떤 모습인지, 누구를 위한 것인지, 그리고 명시적으로 목표가 아닌 것이 무엇인지.
- **[SPEC.md](SPEC.md)** — 단일하고 자기완결적인 명세서(약 1,900줄). 맨 위의 **Table of contents**에서 시작해, 파일 전체를 로드하지 말고 `Read --offset --limit`로 개별 섹션을 읽으세요.

## Why this shape

작지만 핵심을 떠받치는 관찰 하나가 설계를 이끕니다: **AI 에이전트의 출력 품질은 작업 컨텍스트의 크기와 관련성(relevance)에 의해 제한된다.** 자유 형식 세션은 파일을 임기응변으로 읽고, 대화의 곁가지를 쌓으며, 작업 전체를 하나의 윈도우에 담아두기를 모델에 요구합니다. 그 윈도우가 다음 결정과 무관한 자료로 채워질수록 성능은 저하됩니다 — 드리프트, 환각된 불변식(invariant), 절반만 끝난 구현, 잃어버린 전제조건.

그래서 이 셸은 에이전트에게 "작업 전체를 하라"는 더 나은 지시를 주려 하지 않습니다. 대신 하나의 작업을 일련의 **좁고 잘 정의된 단계(phase)**로 쪼개고, 현재 단계에 속하지 않는 모든 것을 활성 컨텍스트 *밖으로* 밀어냅니다. 엔지니어링 규율이 지렛대이고, 컨텍스트 규율이 그 효과입니다:

- **Doc → Test → Code는 작업을 짧은-컨텍스트 3단계로 나눕니다.** doc 단계는 SSOT(MISSION, SPEC, CLAUDE.md)를 읽습니다. test 단계는 방금 작성한 contract와 test rig를 읽습니다. code 단계는 실패하는 test와 관련 구현을 읽습니다. 셋 중 어느 것도 나머지를 작업 기억에 담을 필요가 없으며, 각 단계의 산출물(doc commit, 실패-test commit, 통과-test commit)이 다음 단계가 필요로 하는 입력입니다 — 그 이상은 없습니다.
- **Subagent는 격리된 컨텍스트 윈도우에서 실행됩니다.** `planner`, `doc-writer`, `test-writer`, 그리고 `*-reviewer` 계열은 각각 새 컨텍스트로 시작해 자기 일을 하고 요약을 반환합니다. 탐색 소모, 계획의 우회, 리뷰 추론이 메인 세션을 오염시키지 않습니다. 메인 에이전트는 transcript가 아니라 verdict를 읽습니다.
- **GitHub 아티팩트가 지속 메모리(durable memory)입니다.** branch 상태, draft-PR 본문, AC 체크박스, 병합된 commit 히스토리, audit log — 이들은 세션을 넘어 살아남습니다. 재개된 세션은 자기 위치를, 더 이상 존재하지 않을 수도 있는 긴 대화 transcript가 아니라 저장소에서 읽습니다. SessionStart는 작업이 현재 놓인 위치와 관련된 조각만 다시 주입합니다.
- **Hook이 규칙을 강제하므로 에이전트가 그것을 기억할 필요가 없습니다.** protected-branch commit, diff 속 secret, 잘못된 형식의 commit 메시지, AC 미체크 merge — 환경이 거부하며, 정당한 경우를 위한 audit-log된 escape hatch가 있습니다. 에이전트의 컨텍스트는 SPEC의 모든 규칙으로 자신을 단속하는 일이 아니라 작업에 집중한 채로 유지됩니다.
- **Reviewer는 대화가 아니라 아티팩트로부터 판단합니다.** `code-reviewer`, `security-reviewer`, `activation-reviewer`와 그 동료들은 그것들을 만들어낸 토론이 아니라 diff + PR 본문 + MISSION을 봅니다. 쉰 개의 메시지 전에 설득력 있게 들렸던 주장은 게이트에서 아무런 무게도 갖지 못합니다. 이 격리가 핵심입니다: 새로운 독자는 미리 선입견을 가진 독자가 잡지 못하는 것을 잡아냅니다.

종합하면: 이 셸의 메커니즘들은 서로 위에 쌓아 올린 독립적인 좋은-엔지니어링 관행이 아닙니다. 그것들은 모두 같은 지렛대를 겨냥합니다 — 어느 순간이든 모델이 추론하고 있는 컨텍스트 조각을 가능한 한 작고 관련성 높게 유지하는 것.

이것이 이 셸이 긴 대화가 아니라 아티팩트 계층(`MISSION.md` → Directive Issue → Execution Issue → PR → commits)을 중심으로 구조화된 이유입니다. 각 계층은 컨텍스트 경계입니다. 각 계층은 자체 reviewer를 갖습니다. 각 계층의 산출물은 다음 계층이 읽는 것입니다.

## How the loop runs

두 개의 운영 계층(operating layer)이 있고, 둘 다 같은 generate → review → gated approval → audit 패턴을 따릅니다:

- **eng-mode** — 엔지니어링 실행. `/file-issue` → `/work-on <N>` (branch + draft PR 생성) → Doc → Test → Code commit들 → `/ship` (reviewer 실행, AC 체크, ready 전환) → merge.
- **dir-mode** — 유지보수 디렉팅. `/file-directive` → `/activate` → `/file-issue --parent <N>`로 Execution Issue 분기 → success signal이 충족되면 `/complete-directive`. v0에서는 수동 모드 전환; 자동 전환하는 orchestrator는 v1+입니다(SPEC §0.4).

`unattended` 모드에서는 reviewer subagent가 각 체크포인트의 사람 승인을 대체합니다; `attended` 모드(기본)에서는 에이전트가 PR-ready에서 멈추고 사람 리뷰를 기다립니다.

## Install

```bash
git clone <this-repo-url> claude-eng-shell
cd claude-eng-shell
./scripts/bootstrap.sh
```

`bootstrap.sh`는 의존성만 점검합니다 — `git`, `gh`, `jq`는 필수이고, `python3`는 권장됩니다(여러 helper가 사용하며, python이 없으면 덜 정밀한 동작으로 폴백). 이 스크립트는 `~/.zshrc`나 그 밖의 사용자 전역(user-global) 파일을 절대 수정하지 않습니다. 바이너리를 `PATH`에 추가하거나 직접 alias를 거세요:

```bash
export PATH="$PWD/bin:$PATH"
# or
alias claude-eng="$PWD/bin/claude-eng"
```

## Quick start

```bash
# Clone a target repo into the shell's workspace/.
./scripts/clone-into.sh https://github.com/<owner>/<repo>.git
cd workspace/<repo>
claude-eng

# Inside the session:
> /onboard
> /file-issue <description>                   # files the Issue as status:proposed
> /activate <issue#>                          # Proposed → Active (reviewer-gated; required before /work-on)
> /work-on <issue#>                           # default: branches from main
> /work-on <issue#> --base experiment/foo     # topic-branch flow (SPEC §10.5)
> /ship
```

외부 경로도 등록할 수 있습니다:

```bash
./scripts/register.sh ~/code/<repo>
# or: claude-eng ~/code/<repo>   ← unregistered path prompts to register
```

### Dir-mode: Directive-scoped work

**Directive**는 하나 이상의 Execution Issue를 범위로 묶는 중기적 방향성 컨텍스트입니다(SPEC §1.7, §2.1). 작업이 2-3개의 PR에 걸치거나 "왜 이 일을 하는가"라는 일관된 앵커가 필요할 때 사용하세요 — refactor, migration, 하위 시스템을 가진 feature 등. 일회성 변경에는 일반 `/file-issue`로 충분합니다.

**단일-Directive 흐름(가장 흔함):**

```bash
# Inside the session:
> /file-directive               # author Directive; status:proposed, reviewer-gated
> /activate <N>                 # Proposed → Active (removes status:proposed)
                                # (`/activate-directive` is a deprecated one-cycle alias)
> /file-issue --parent <N> <description>   # spawn Execution Issue parented under Directive #N
> /activate <execution-#>       # Proposed → Active (every Issue is gated before /work-on)
> /work-on <execution-#>        # eng-mode from here on
> /ship
# ... repeat /file-issue --parent / /activate / /work-on / /ship per Execution Issue ...
> /complete-directive <N>       # reviewer evaluates closed-Execution-Issue evidence
```

**topic-branch 격리를 사용하는 다중-PR Directive(SPEC §10.5):**

작업이 여러 PR에 걸쳐 있고 통합(consolidation) 전까지 `main`으로부터 격리하고 싶을 때:

```bash
# Create the topic branch from main (the shell does NOT auto-create it):
$ git checkout main && git pull
$ git checkout -b feature/directive-<N> && git push -u origin feature/directive-<N>

# Inside the session, for each Execution Issue under the Directive:
> /file-issue --parent <N> <description>
> /activate <execution-#>                                # Proposed → Active (required before /work-on)
> /work-on <execution-#> --base feature/directive-<N>   # sub-task PR; uses Refs #<execution-#>
> /ship

# When all Execution Issues are done, consolidate to main:
$ gh pr create --base main --head feature/directive-<N> --title "..." --body "$(cat <<'EOF'
Closes #<exec-1>
Closes #<exec-2>
...
EOF
)"

# Then close the Directive:
> /complete-directive <N>
```

Directive Issue 자체는 절대 branch되지 않습니다 — `proposed-protect` hook이 Directive Issue(그리고 모든 `status:proposed` Issue)에 대한 `git checkout -b`를 막습니다. Directive는 작업의 범위를 정하고, Execution Issue가 실제 작업을 합니다.

### Dir-mode substrate (Project v2)

**dir-mode**(SPEC §1.7)에서 정식 설치 도구는 `/onboard-dir-mode --tier 3`입니다 — GitHub Project v2 substrate(그리고 label, Issue template, workflow)를 프로비저닝하고 `scripts/setup_project.sh`를 대신 호출해 줍니다. 등록된 target repo 안에서 Project 부트스트랩만 (재)실행하려면:

```bash
./scripts/setup_project.sh   # idempotent — creates "<repo-name> roadmap" with
                             # 4 gh-created fields (Type, Status, Priority, Parent)
                             # and links to the repo. On re-run, reconciles
                             # SINGLE_SELECT options additively (preserves
                             # user-added options). The Iteration field is
                             # user-added via the GH UI (gh CLI lacks the
                             # ITERATION data-type). Schema locked inline in
                             # scripts/setup_project.sh.
```

## Operating modes

| Mode | `/ship` terminal behavior | Use |
|---|---|---|
| `attended` (default) | stops at PR-ready | human reviews + merges |
| `unattended` | continues to merge (clean) or park (hard blocker) | overnight runs, batched fixes |

target별로 `echo unattended > .claude/state/mode`로 설정합니다. 호출별로 `/ship --mode=unattended`로 재정의합니다. 전체 해석 우선순위와 blocker 분류는 SPEC §5.7.1을 참고하세요.

## What the hooks actually enforce

- protected-branch 직접 commit/push, force push, push 이후의 `--amend`, `--no-verify`
- staged diff 속 secret 패턴(`file:line: <id>` 마커를 출력; target-repo 루트의 `.shellsecretignore`로 경로 allow-list 지정)
- `.env`, `*.pem`, `credentials*`에 대한 편집
- 등록된 범위 밖의 Edit/Write, 그리고 out-of-registry 경로에 대한 `rm -rf`/`mv -f`/`cp -f`
- linked issue에 미체크 AC가 있고 `## AC closeout` 마커 comment가 없는 상태의 `gh pr merge`(`/ship` 7.6 단계가 `scripts/ac_closeout.sh`를 호출해 구성적으로 충족시킴)
- 모든 `status:proposed` Issue에 대한 branch 생성(먼저 `/activate <N>` 실행) 또는 모든 Directive Issue에 대한 branch 생성(Directive는 직접 실행될 수 없음 — `/file-issue --parent`로 Execution Issue를 분기). 이것이 `proposed-protect` hook입니다.
- trusted-filer Issue에 대해 `--reason completed` 없는 `gh issue close`; 모든 filer로부터의 `--remove-label directive`

모든 block은 `SKIP_HOOKS=<category> SKIP_REASON='<why>' <command>`로 escape 가능하며 `.claude/audit/audit.jsonl`에 audit-log됩니다. SessionStart는 silent-no-op 상태를 표면화합니다(workspace는 주입되었으나 `claude-eng` 대신 plain `claude`로 실행된 경우, 또는 `hookrt.sh`가 없는 경우) — 그렇지 않으면 hook이 경고 없이 증발합니다. 전체 강제(enforcement) 표면과 반복되는 false positive에 대한 구조적 튜닝 메커니즘은 SPEC §6.1 / §6.5 / §7을 참고하세요.

## Subagents

총 아홉 개: `explorer`, `planner`, `doc-writer`, `test-writer`, `code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `activation-reviewer`. 다섯 reviewer(`code-`, `security-`, `issue-`, `plan-`, `activation-`)는 `unattended` 모드에서 human-confirm 체크포인트를 대체합니다. (triage classifier는 #173에서 폐기되었습니다 — `/activate`가 그 게이트를 흡수합니다.) 각각을 언제 사용하는지는 [docs/SUBAGENTS.md](docs/SUBAGENTS.md)를 참고하세요.

## More commands

전체 command 표면은 SPEC §5에 문서화되어 있습니다; `/file-issue` / `/work-on` / `/ship` / dir-mode 외에 가장 많이 쓰이는 것들:

- `/discuss <observation>` — "버그는 아닌데 이상한" 관찰을 위한 마찰 없는 filing(SPEC §5.19). rationale-triad 게이트를 우회합니다; promoted(구체적 Issue가 filed됨) 또는 no-action으로 close.
- `/audit [<filter>]` — 최근 block, escape, warn에 대해 audit log를 조회. filter는 로그에 대한 부분 문자열 매치입니다(예: `/audit force-push`, `/audit escape`). 예기치 않게 발동한 hook을 디버깅할 때 사용하세요.
- `/status` — 현재 branch / issue / PR / phase 상태의 일회성 요약.
- `/release <X.Y.Z>` — 버전이 매겨진 release를 cut(PR별 changelog fragment를 통합; SPEC §18).
- `/onboard-dir-mode [--tier 1|2|3] [--dry-run]` — v3 dir-mode substrate(label, Issue template, workflow, Project v2)를 target repo에 설치. tier-aware, idempotent.

hook이 당신을 block했다면, [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)와 [docs/ESCAPE_HATCH.md](docs/ESCAPE_HATCH.md)에서 시작하세요.

## Versioning

셸 버전은 최상위 `VERSION` 파일에 [semver](https://semver.org) 0.x의 한 줄로 저장됩니다 — v0 전반에 걸쳐 `MAJOR=0`인 `MAJOR.MINOR.PATCH`. 태그는 `v` + semver를 따릅니다(예: `v0.2.0`).

```bash
claude-eng --version       # → prints VERSION-file contents (or `git describe` fallback)
```

`--version`은 registry 해석과 scope guard 이전에 단락(short-circuit)되므로, 등록되지 않은 경로를 포함해 어떤 cwd에서도 동작합니다.

**v0 규약**(Directive #122에 의해 고정):

- 형식은 semver 0.x입니다. [SemVer 2.0 §4](https://semver.org/#spec-item-4)에 따라 0.x는 호환성 보장을 갖지 않습니다 — 0.x 내의 bump는 계약이 아니라 정보 신호입니다.
- 0.x 밖으로의 bump(`1.0.0`으로)는 첫 비-자기(non-self) 채택자의 dogfooding을 위해 예약되어 있습니다. v0에서는 어떤 hook / CI / onboard도 semver bump 의미론을 강제하지 않습니다.
- 태그는 의미 있는 마일스톤이 `main`에 merge된 후 maintainer가 수동으로 push합니다(PR별 주기 없음).

변경 작성자를 위해: PR별 changelog fragment는 `changelog_unreleased/<category>/<N>.md` 아래에 둡니다 — [`changelog_unreleased/TEMPLATE.md`](changelog_unreleased/TEMPLATE.md)와 SPEC §18(Release backbone)에서 계약을 확인하세요. 저장소 루트의 [`CHANGELOG.md`](CHANGELOG.md)가 통합된 히스토리를 담습니다.

## Configuration toggles

모두 선택 사항입니다. target별 상태 파일은 `.claude/state/` 아래에 있습니다(gitignored); 설정된 경우 env var가 우선합니다.

| Knob | File | Env | Default | Purpose |
|---|---|---|---|---|
| Operating mode | `mode` | `CLAUDE_ENG_SHELL_MODE` | `attended` | `/ship` terminal behavior (§5.7.1) |
| Co-Authored-By trailer | `coauthor` | `CLAUDE_ENG_COAUTHOR` | `on` | Include the trailer in `/work-on` commits (§10.2) |
| Status cache TTL | — | `STATUS_CACHE_TTL` | `5` | Seconds before re-querying `gh` from `_status_collect` (§5.5) |
| Session-start fetch TTL | — | `SESSION_START_FETCH_TTL` | `21600` | Seconds before the shell-behind `git fetch` runs again (§6.5) |
| Session-start fetch timeout | — | `SESSION_START_FETCH_TIMEOUT` | `5` | Per-fetch `timeout(1)` bound when the TTL elapses (§6.5) |
| Commit-time lint timeout | — | `CLAUDE_ENG_LINT_TIMEOUT` | `30` | Bound on the commit gate's lint (§6.1) |
| Stop-hook throttle | — | `CLAUDE_ENG_STOP_THROTTLE` | `5` | Suggest `/review` every Nth response from the Stop hook (§6.3) |
| Unattended park log | — | `SHIP_PARK_LOG_PATH` | `.claude/state/unattended-park.log` | Where `/ship` appends park entries in `unattended` mode (§5.7.1) |
| PR cache repo override | — | `PR_CACHE_REPO` | — | Override the `owner/repo` `pr_cache` queries; falls back to `gh repo view` of the cwd (§5.4) |
| Behavioral smoke gate | — | `CLAUDE_ENG_BEHAVIORAL_SMOKE` | unset | Set to `1` to exercise live `activation-reviewer` in smoke §42e (SPEC §4.9.3); default-unset keeps smoke offline + deterministic |
| Dir-mode Project name | — | `CLAUDE_ENG_PROJECT_NAME` | `<repo-name> roadmap` (literal) | Override the dir-mode Project v2 title resolved by `scripts/setup_project.sh` and `scripts/dir_mode_project.sh resolve` (SPEC §1.7 Substrate guard) |

*`STATUS_CACHE_DIR_OVERRIDE`는 내부 전용(`helpers/status.sh`를 위한 smoke-test 배관)이며 의도적으로 목록에 포함하지 않았습니다.*

## Docs

- [MISSION.md](MISSION.md) — 장기 방향성과 성공 기준.
- [SPEC.md](SPEC.md) — 단일하고 자기완결적인 명세서(SSOT). 맨 위의 TOC에서 시작하세요.
- [docs/ENGINEERING_FLOW.md](docs/ENGINEERING_FLOW.md) — 단계별 엔지니어링 흐름.
- [docs/SUBAGENTS.md](docs/SUBAGENTS.md) — subagent 사용 가이드.
- [docs/ESCAPE_HATCH.md](docs/ESCAPE_HATCH.md) — hook을 안전하게 우회하기.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — 흔한 block과 해결책.


## Verify

```bash
./scripts/test/smoke.sh           # ~350+ assertions across hooks, helpers, slash commands
./scripts/build_toc.sh --check    # SPEC.md TOC freshness
```
