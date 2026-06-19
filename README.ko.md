# claude-eng-shell

[English](README.md) | **한국어**

**[Claude Code](https://docs.claude.com/claude-code)를 위한, 뚜렷한 작업 방식을 강제하는 워크플로 셸입니다.** 숙련된 개발자가 GitHub 저장소에서 지키는 작업 규율 — issue → branch → draft PR → reviewed commits → ready merge — 을 Claude Code 세션에 그대로 입히고, 그 규율을 hook과 slash command, subagent, audit trail로 구현합니다. AI가 엔지니어링 작업을 처음부터 끝까지 직접 끌고 가더라도, 신중한 사람이라면 그냥 넘기지 않을 점검을 건너뛰며 드리프트(drift)하지 않도록 하는 것이 목표입니다.

- **[MISSION.md](MISSION.md)** — 12개월 뒤의 성공은 어떤 모습인지, 누구를 위한 도구인지, 무엇이 명시적으로 목표가 *아닌지*.
- **[SPEC.md](SPEC.md)** — 하나로 완결된 명세서(약 2,000줄). 파일 전체를 읽지 말고, 맨 위 **Table of contents**에서 필요한 절을 찾아 `Read --offset --limit`로 그 부분만 읽으세요.

## Install

```bash
git clone <this-repo-url> claude-eng-shell
cd claude-eng-shell
./scripts/bootstrap.sh                 # checks dependencies only — never edits ~/.zshrc
export PATH="$PWD/bin:$PATH"            # or: alias claude-eng="$PWD/bin/claude-eng"
```

`bootstrap.sh`가 하는 일은 의존성 확인뿐입니다. `git`·`gh`·`jq`는 반드시 있어야 하고, `python3`는 권장합니다(여러 helper가 쓰며, 없으면 정밀도가 떨어지는 방식으로 동작합니다). `~/.zshrc`를 비롯한 사용자 전역(user-global) 파일은 어떤 것도 건드리지 않습니다.

## Quick start

```bash
# Clone a target repo into the shell's workspace/ (or register an external path — see below).
./scripts/clone-into.sh https://github.com/<owner>/<repo>.git
cd workspace/<repo>
claude-eng

# Inside the session — the engineering loop:
> /onboard                      # one-time: check upstream, permissions, SSOT, CI
> /file-issue <description>     # files the Issue as status:proposed
> /activate <issue#>            # Proposed → Active (reviewer-gated; required before /work-on)
> /work-on <issue#>             # branch + draft PR + planner
                                #   …or  /work-on <issue#> --base experiment/foo  (topic-branch flow, SPEC §10.5)
> /ship                         # review, tick AC, mark ready (→ merge in unattended mode)
```

`workspace/`로 clone하는 대신 외부 경로를 등록해도 됩니다.

```bash
./scripts/register.sh ~/code/<repo>     # or: claude-eng ~/code/<repo> — an unregistered path prompts to register
```

## Adopting it on your repo

위의 루프가 실제 프로젝트에서 매끄럽게 돌기 전에, 알아 두면 좋은 네 가지가 있습니다.

**전제조건(Prerequisites).** `bootstrap.sh`가 확인하는 의존성(`git`·`gh`·`jq`, `python3` 권장) 외에, GitHub 흐름에는 PR을 열고 issue를 다룰 수 있는 토큰으로 `gh auth login`이 되어 있어야 합니다. **dir-mode**까지 도입하려면 추가로 `project` 토큰 scope(dir-mode GitHub Project를 `setup_project.sh`가 생성)와 workflow를 push할 권한(issue/Project 미러링이 `.github/workflows/`를 설치)이 필요합니다. 무엇이 빠졌는지는 `/onboard`가 알려 줍니다 — 첫 issue를 올리기 전에 인증부터 맞추세요.

**Footprint — 내 저장소에 무엇이 생기고, 무엇이 추적되는가.** 주입(`clone-into.sh`·`register.sh`)은 target의 `.claude/` 아래에 **심링크**를 만듭니다: `eng-shell-root`(→ 정본 셸), `settings.local.json`(→ 셸의 injected hook), 그리고 `agents/`·`commands/*.md` 자산마다 하나씩 — 여기에 `eng-state/` 아래 per-project 레지스트리/상태 디렉터리가 더해집니다. 셸은 `eng-shell-root`·`settings.local.json`·`eng-state/`를 target의 `.git/info/exclude`에 추가하므로 이들은 `git status`에 절대 나타나지 않고, `agents`·`commands` 심링크는 셸 쪽을 가리킬 뿐 커밋되지 않습니다. 같은 이름의 **실제 파일**이 이미 있으면 *경고를 남기고 건너뜁니다* — 덮어쓰지 않으며, 기존 `.claude/`를 훼손하지 않습니다.

**실행 방법 — `claude-eng` 또는 그냥 `claude`.** Install에서 만든 `claude-eng` PATH 래퍼는 어디서든 동작합니다. 등록된 target 안에서는 그냥 `claude`로 띄워도 됩니다: hook이 `.claude/eng-shell-root` 바인딩 심링크로 셸을 스스로 찾아가므로 전역 `CLAUDE_ENG_SHELL_ROOT` env가 필요 없습니다(SPEC §3.2.1).

**`/onboard`(최초 1회, 읽기 전용).** 등록 직후에 실행하세요. upstream/fork, push 권한, SSOT 파일, `.github/`, branch protection, CI — 여섯 가지를 각각 ✓/✗로 보고하고, **자동으로 바꾸는 것은 없으며**, 권장 다음 행동으로 끝맺습니다. ✗(예: 저장소가 fork이거나 push 권한이 없음 — 셸은 upstream 전용)는 `/file-issue` 전에 환경을 손보라는 신호입니다.

> **dir-mode는 target을 변경합니다.** 위의 것들과 달리 `/onboard-dir-mode`는 공짜 toggle이 아닙니다: issue 템플릿·미러링 workflow·changelog substrate를 추가하는 **PR을 내 저장소에 열고**, label과 GitHub Project를 생성합니다. 의식적으로 도입하세요 — 전체 흐름은 [docs/DIR_MODE_FLOW.md](docs/DIR_MODE_FLOW.md)에 있습니다.

## How the loop runs

운영 계층은 두 가지이고, 둘 다 **generate → review → gated approval → audit**라는 같은 흐름을 따릅니다.

- **eng-mode** — 실제 엔지니어링 작업. `/file-issue` → `/activate` → `/work-on`(branch와 draft PR 생성) → Doc·Test·Code commit → `/ship`(reviewer 실행, AC 체크, ready 전환) → merge.
- **dir-mode** — 방향을 정하는 작업. Directive 하나가 여러 Execution Issue를 "왜 하는가"라는 하나의 맥락으로 묶습니다. 기능 개발이든 refactor든 migration이든 가리지 않으며, Directive 자체는 직접 실행되지 않습니다. `/file-directive` → `/activate` → `/file-issue --parent <N>`로 Execution Issue를 떼어내고, Directive의 success signal이 충족되면 `/complete-directive`. Directive 위에는 **Initiative** 계층을 선택적으로 둘 수 있습니다. 셸이 직접 쓰지 않고 *읽어서 소비만 하는* 계획 아티팩트입니다(`/consume-initiative`, `/initiative-feedback`). 전체 흐름과 substrate 설치(`/onboard-dir-mode`)는 **[docs/DIR_MODE_FLOW.md](docs/DIR_MODE_FLOW.md)**에 정리돼 있고, 여러 PR에 걸친 Directive의 topic-branch 격리는 SPEC §10.5에서 다룹니다.

기본값인 **`attended`** 모드에서는 PR이 ready 상태가 되면 에이전트가 멈추고, 사람이 리뷰하고 merge합니다. **`unattended`** 모드에서는 reviewer subagent가 사람의 승인을 대신하며, `/ship`이 깨끗한 PR은 merge까지, 막힌 곳(hard blocker)이 있으면 park까지 진행합니다. target마다 `echo unattended > .claude/state/mode`로 정하거나, 실행할 때 `/ship --mode=unattended`로 덮어쓸 수 있습니다. 우선순위와 blocker 판정 규칙은 SPEC §5.7.1에 있습니다.

## Why this shape

설계의 출발점은 한 가지 관찰입니다. **AI 에이전트의 출력 품질은 작업 컨텍스트의 크기와 관련성(relevance)이 좌우한다**는 것입니다. 자유 형식 세션은 그때그때 즉흥적으로 파일을 읽고, 대화의 곁가지를 쌓고, 작업 전체를 한 윈도우에 다 담으려 합니다. 그러다 윈도우가 당장 쓸모없는 내용으로 차오르면 드리프트가 생기고, 없는 불변식(invariant)을 지어내고, 전제조건을 놓칩니다. 그래서 이 셸은 작업 하나를 좁고 명확한 단계로 쪼갠 뒤, 지금 단계와 상관없는 것은 활성 컨텍스트 밖으로 밀어냅니다. 엔지니어링 규율은 수단일 뿐이고, 진짜 노리는 효과는 컨텍스트를 좁게 유지하는 것입니다.

- **Doc → Test → Code**는 한 작업을 컨텍스트가 짧은 세 단계로 나눕니다. 각 단계는 자기에게 필요한 것만 읽고, 한 단계의 결과물(doc commit, 실패하는 test commit, 통과하는 test commit)이 곧 다음 단계의 입력이 됩니다.
- **Subagent는 각자 격리된 윈도우에서 돕니다.** `planner`, `doc-writer`, `test-writer`와 `*-reviewer` 계열은 새 컨텍스트에서 시작해 자기 일만 하고 결론(verdict)만 돌려줍니다. 대화 기록(transcript)을 통째로 넘기지 않으니, 탐색이나 계획에 쓴 토큰이 메인 세션을 어지럽히지 않습니다.
- **GitHub 아티팩트가 지속 메모리(durable memory) 역할을 합니다.** branch 상태, PR 본문, AC 체크박스, commit 히스토리, audit log는 세션이 끝나도 남습니다. 다시 시작한 세션은 자기가 어디까지 했는지를 저장소에서 읽어 오고, SessionStart는 그중 지금 필요한 조각만 골라 다시 넣어 줍니다.
- **규칙은 hook이 강제합니다.** 덕분에 에이전트가 규칙을 스스로 단속하느라 컨텍스트를 쓸 필요가 없습니다. protected branch에 직접 commit, secret 노출, 형식이 틀린 메시지, AC를 채우지 않은 merge는 막히고, 꼭 필요할 때 쓰라고 audit log에 남는 escape hatch가 마련돼 있습니다.
- **Reviewer는 대화가 아니라 결과물을 보고 판단합니다.** diff와 PR 본문, MISSION만 볼 뿐, 그것을 만들어 낸 토론은 보지 않습니다. 선입견 없는 새 독자라야 이미 설득당한 독자가 놓치는 문제를 잡아냅니다.

결국 모든 장치가 같은 곳을 겨냥합니다. 매 순간 모델이 들여다보는 컨텍스트를 되도록 작고 관련성 높게 유지하는 것입니다. 이 셸이 긴 대화가 아니라 아티팩트 계층(`MISSION.md` → Directive → Execution Issue → PR → commit)을 중심으로 짜인 것도 그 때문입니다. 각 계층은 저마다 reviewer를 둔 컨텍스트 경계이고, 한 계층의 결과물이 다음 계층의 입력이 됩니다.

## Subagents

모두 아홉 개입니다. `explorer`, `planner`, `doc-writer`, `test-writer`, `code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `activation-reviewer`. 이 가운데 다섯 reviewer(`code-`, `security-`, `issue-`, `plan-`, `activation-`)는 `unattended` 모드에서 사람이 확인하던 단계를 대신합니다. 각각 언제 쓰는지는 [docs/SUBAGENTS.md](docs/SUBAGENTS.md)를 보세요.

## What the hooks enforce

환경이 알아서, 신중한 엔지니어라면 하지 않을 일을 거부하고 모든 차단을 `.claude/audit/audit.jsonl`에 기록합니다. 막는 범위는 대략 이렇습니다.

- **Git 안전** — protected branch에 직접 commit/push, force-push, push한 뒤의 `--amend`, `--no-verify`.
- **Secret과 민감 파일** — staged diff에 섞인 secret 패턴(경로 예외는 `.shellsecretignore`로 지정), 그리고 `.env`·`*.pem`·`credentials*` 편집.
- **범위(scope)** — 등록되지 않은 경로에 대한 Edit/Write, 또는 파괴적인 `rm -rf`·`mv -f`·`cp -f`.
- **워크플로 무결성** — AC를 채우지 않은 `gh pr merge`(`ac-closeout`), default branch로의 `--merge`가 아닌 merge 전략(`merge-strategy`), `status:proposed`나 Directive Issue에서의 branch 생성(`proposed-protect`), Issue의 parent-marker와 어긋나는 label(`label-parent-consistency`), 그리고 trusted-filer Issue 변경.

차단은 모두 우회할 수 있고, 우회한 기록도 함께 남습니다. Claude Code의 Bash 도구 안에서는 명령 뒤에 붙이는 sentinel `<command>  # claude-eng:skip=<category> reason=<why>`을 쓰세요. 명령 앞에 붙이는 `SKIP_HOOKS=<category> SKIP_REASON='<why>' <command>` 형식은 그 문자열이 명령에 그대로 실려 들어가는 환경(실제 shell, smoke harness)에서만 통합니다. 전체 차단 목록과 fail-policy, 튜닝 방법은 **SPEC §6.1 / §6.5 / §7**에 있습니다.

## Configuration toggles

모두 선택 사항입니다. target별 상태는 `.claude/state/`에 저장되며(gitignore 대상), env var를 설정하면 그쪽이 우선합니다. operating mode, Co-Authored-By trailer, 각종 cache TTL과 timeout, unattended park log, dir-mode Project 이름 등 toggle 전체 목록은 **[docs/CONFIG.md](docs/CONFIG.md)**에 정리돼 있습니다.

## Versioning

셸 버전은 최상위 `VERSION` 파일에 [semver](https://semver.org) 0.x 한 줄로 들어 있습니다(v0 동안은 `MAJOR`가 계속 0). 태그는 `v` 뒤에 semver를 붙입니다(예: `v0.2.0`). `claude-eng --version`이 이 값을 출력하는데, registry와 scope 확인보다 먼저 처리되므로 어느 디렉터리에서나 동작합니다. [SemVer 2.0 §4](https://semver.org/#spec-item-4)에 따르면 0.x에서의 버전 bump는 약속이 아니라 참고용 신호일 뿐입니다. 태그는 의미 있는 마일스톤이 merge된 뒤 maintainer가 직접 붙입니다. PR마다 changelog 조각을 `changelog_unreleased/<category>/<N>.md`([TEMPLATE](changelog_unreleased/TEMPLATE.md))에 남겨 두면 `/release <X.Y.Z>`가 이를 [CHANGELOG.md](CHANGELOG.md)로 묶어 줍니다. 전체 규약은 SPEC §18에 있습니다.

## Docs

- [MISSION.md](MISSION.md) — 장기 방향과 성공 기준.
- [SPEC.md](SPEC.md) — 하나로 완결된 명세서(SSOT). 맨 위 TOC에서 시작하세요.
- [docs/ENGINEERING_FLOW.md](docs/ENGINEERING_FLOW.md) — 단계별 엔지니어링 흐름.
- [docs/DIR_MODE_FLOW.md](docs/DIR_MODE_FLOW.md) — dir-mode 흐름(Directive, Initiative, substrate tier).
- [docs/SUBAGENTS.md](docs/SUBAGENTS.md) — subagent 사용 안내.
- [docs/CONFIG.md](docs/CONFIG.md) — 설정 toggle.
- [docs/ESCAPE_HATCH.md](docs/ESCAPE_HATCH.md) — hook을 안전하게 우회하는 법.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — 자주 막히는 경우와 해결책.

## Verify

```bash
./scripts/test/smoke.sh           # 733+ assertions across hooks, helpers, slash commands
./scripts/build_toc.sh --check    # SPEC.md TOC freshness
```
