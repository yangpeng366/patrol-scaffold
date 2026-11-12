---
name: patrol-scaffold
description: 巡检任务脚手架 agent skill：把「周期性读一张方向表 → 给每行派有界 agent 工作 → 回写 → 出摘要」实例化，用于飞书多维表格（Bitable）/ 腾讯文档智能表格 / 本地 CSV / 命令输出 / 本地 JSON 五种数据源；换源只加 adapter 与模块两个文件，调度器不动；含定时任务（计划任务 / nssm）、凭据与脱敏纪律、离线 fixture 与 PowerShell 自测门禁。
---

Runtime: both `verify-adapter-spec.ps1` and `adapter-contract-test.ps1` require PowerShell 7
(`pwsh`). They are UTF-8 without BOM; Windows PowerShell 5.1 decodes them as ANSI and fails
to parse. Judge reds by pwsh 7 only.

Version: `0.2.0` (`VERSION` is the single source of truth; the git tag is `v0.2.0`).
Changelog in `CHANGELOG.md`; release / packaging / install / upgrade in `docs/releasing.md`.

# patrol-scaffold Skill

A generalized scaffold extracted from the live 飞书巡检定时任务 ecosystem. The
source layer is swappable: the same scheduler drives Feishu Bitable today and
can drive 腾讯文档智能表格 / Sheets / local JSON tomorrow. Use this to spin up a
new patrol loop for any recurring "read a task list -> bounded agent work ->
report" need without re-deriving the architecture.

## Quick start for other agents (run this FIRST)

Before reading further or swapping anything, verify the scaffold runs on your
machine — no credentials, no network:

```
cd <skill-dir>
pwsh -File scripts/adapter-contract-test.ps1
pwsh -File tests/verify-state-externalization.ps1
pwsh -File scripts/patrol-loop.ps1 -TasksFile scripts/sample-tasks.json -Once -DryRun
```

Expected: contract test `pass=3 skip=2 fail=0` (`command` / `csv-file` / `local-json` run for
real; `bitable` / `tencent-docs` are SKIP without credentials, never FAIL); state test
`state externalization: PASS`; `due=1/3 disabled=2` (demo-A / demo-C are `intervalMin=0`
rows, i.e. parked: `0` = disabled, not "every round"), one worker completes, runtime state
lands in `state/patrol-state.json` while `sample-tasks.json` stays read-only, digest lands
in `downloads/patrol-<ts>.json|.md`. Immediate re-run shows `due=0/3 disabled=2` because
`lastRun` is merged from the state file.

If this fails, fix your pwsh / dot-source path FIRST — the scaffold is
meaningless until the pipeline runs end-to-end. Then read
`references/patrol-blueprint.md` for architecture and
`references/local-json-adapter.md` to swap in your real data source.

## When to use (instantiate a new patrol)

- The need is recurring (daily / per-interval), not one-off.
- The "what to do" lives in a row-based source (a table / sheet / doc sections).
- Each row maps to bounded agent work in a local repo or workspace.
- You want read-only collection + bounded execution + a digest, not a full app.

## The 7-layer architecture (provider-agnostic)

1. **Source Adapter** - read rows from a spreadsheet/doc/CLI source into a common
   item shape. Swappable provider: `bitable` | `tencent-docs` | `csv-file` |
   `local-json` | `command`. This is the ONLY layer that knows the vendor.
2. **Scheduler** - round-based loop: due = `now - lastRun >= interval`;
   priority sort (P0 < P1 < P2); worker-pool concurrency cap; round hard
   timeout; global mutex (no concurrent instances).
3. **Worker** - one bounded `codex exec` per item; resume prior thread by id
   else NEW; reset to NEW after N consecutive failures; per-worker timeout.
4. **Sync-back** - write Current Stage / Next Step / achievement back to the
   source row; push the spawned thread id so a human/IDE can take over.
5. **Correlator** - map findings -> local repo git state (branch / last commit /
   uncommitted count) so the digest points at where work happens.
6. **Output** - digest `JSON + MD`; append to Obsidian memory under a dated
   `## <patrol-name>` section (best-effort, never overwrite).
7. **Watchdog** - separate scheduled task; checks log staleness + service
   state + process count; ALERTS only, never does the patrol's work.

Plus a **Trigger** layer (Windows Scheduled Task `-Once` with IgnoreNew, or an
nssm Windows service) that fires the scheduler each interval.

## Source-adapter contract (implement once per provider)

Every provider must expose three canonical functions:

- `Get-PatrolItems`   -> list-items(): `[{ id, title, repoPath, description,
  nextStep, priority, intervalMin, threadId, fake }]`
- `Save-PatrolItems`  -> write-back(id, { currentStage, nextStep, achievement, threadId })
- `Resolve-ItemName`  -> resolve-name(id) -> human label for the digest

Three layers make the swap real (not just documented):

1. **Contract** — `schemas/item.schema.json` is the single source of truth for the
   item shape; `scripts/adapter-contract-test.ps1` validates every row any
   provider produces (offline validator; `Test-Json` hangs offline because it
   fetches the JSON-Schema meta-schema).
2. **Assembly** — `adapters/<provider>.adapter.json` declares module path, config,
   the three functions and their args; `scripts/patrol-provider.ps1` imports,
   normalizes (`ConvertTo-PatrolItem`) and calls them. Swap provider by dropping
   in TWO files — the scheduler / worker / correlator / output / watchdog and
   `patrol-loop.ps1` itself stay untouched.
3. **Spec** — `references/adapter-spec.md` is a fill-in-the-blank 11-section
   template for adding a provider (source/trigger, config schema, scope,
   channel, thread, policy, execution vars, plugin entry/loop, registration,
   test checklist).

Adding a provider = 2 files + one contract-test PASS. If you find yourself
editing `patrol-loop.ps1`, the contract has a hole: fix the contract first.

## Verifying a new provider (acceptance commands)

Adding a provider = descriptor + module (`references/adapter-spec.md`); the wiring
checklist (required keys, function signatures, `${...}` sources, failure table) is in
`references/adding-a-provider.md`. It is not "connected" until these pass:

```
pwsh -NoProfile -File tests/verify-adapter-spec.ps1                      # descriptor/spec drift (offline, read-only)
pwsh -NoProfile -File scripts/adapter-contract-test.ps1                  # contract test over EVERY descriptor
pwsh -NoProfile -File scripts/adapter-contract-test.ps1 -Provider <name> # one provider only (legacy usage kept)
```

`verify-adapter-spec.ps1` walks `adapters/*.adapter.json` and checks: required keys and their
types; provider non-empty, unique and matching the file name; `module` a relative path that
exists; `kind` in `file|cli|api`; every declared `function` (three slots plus
`optional.<slot>`) actually defined by the module after a **read-only** dot-source — the
write-back function is never called; every `${...}` placeholder in `args` resolvable from
`config` (`${tasksFile}` excepted, the assembly layer injects it); **every `args` key in a
slot is one of the named parameters that slot's `function` really declares** (`E-ARGNAME`,
compared literally so casing counts; only `args` keys ⊆ declared parameters is enforced —
`-Items`/`-Item` are injected by the assembly layer and must not appear in `args`);
`optional` an object.
Unknown top-level keys are a **failure, not ignored** — a typo'd `writeback` would otherwise
be silently defaulted; a missing `optional` key is only a WARN. Non-zero exit on any failure,
and the script ships a self-test that builds good/broken fixtures in %TEMP% and asserts all
14 rules really go red while the good ones stay green, so a green run can be believed.

`adapter-contract-test.ps1` loops all descriptors, prints `[PASS]/[SKIP]/[FAIL]` per provider,
and names a missing module or missing function explicitly (including capability functions
under `optional`) instead of silently skipping. Credentialed providers stay SKIP, never FAIL.

Runtime: both `verify-adapter-spec.ps1` and `adapter-contract-test.ps1` require PowerShell 7
(`pwsh`). They are UTF-8 without BOM; Windows PowerShell 5.1 decodes them as ANSI and fails
to parse. Judge reds by pwsh 7 only.

## Concretizations (reference)

- **Feishu (live):** provider=`bitable` via `lark-cli base --as user`; fields
  项目名 / 仓库路径 / 优先级 / 巡检间隔(分钟) / 假数据模式 / codex_thread_id.
  Real params in `references/patrol-blueprint.md` (MaxPatrolChildren=3,
  RoundTimeoutSec=1500, CodexTimeoutSec=1800, MaxConsecutiveFailures=3).
- **腾讯文档:** provider=`tencent-docs`; 智能表格 rows map 1:1 to the item
  shape behind the same `list-items()` / `write-back()` contract; use the
  腾讯文档 open API (smart-sheet record list/update). An online doc (非表格)
  -> parse `##` sections as items.

## Safety (non-negotiable)

- READ-ONLY in the source system unless sync-back is explicitly enabled.
- 密钥卫生（最小纪律，本仓强制）：密钥只从环境变量（如 `$env:TYPESAFE_API_KEY`）或仓库外的
  密钥文件读（`~/.openclaw/secrets/typesafe.key` 一类）；仓内任何位置——SKILL.md /
  references / scripts / tests / fixtures——不得出现明文。提交前跑
  `pwsh -File tests/verify-no-secrets.ps1`，非零退出不得提交；报错、日志、工单里只写前缀 + 长度。
  历史命中用 `pwsh -File tests/verify-secret-history.ps1` 只做盘点，不自动改历史：命中即视为已泄露，
  只轮换密钥并收紧读取路径，不硬改历史（force-push 清不掉协作者克隆、镜像与 reflog 里的旧对象）。
- Correlator only reads `git status/log`; never commit/push.
- Workers do bounded, reversible local work; no publish / external mutation
  unless the row explicitly opts in.

## Files

- `VERSION` - version single source of truth (`0.2.0`, no `v`; the git tag carries the `v`).
- `CHANGELOG.md` - Added / Changed / Fixed / Known limits per version; `0.2.0` also records
  which providers are only SKIP-covered.
- `docs/releasing.md` - release procedure: the eight local gates and their expected output, archive
  build/verify, install / upgrade / rollback, and the SKIP-is-not-a-blocker policy.
- `scripts/build-release.ps1` - reproducible archive builder that re-opens its own zip and
  proves: manifest equality, per-entry hashes, no runtime/temp files, `VERSION` match,
  `scripts/sample-tasks.json` byte-equal to HEAD (user edits excluded), no secrets.
- `references/adapter-spec.md` - fill-in-the-blank template for adding a data source (11 sections) + test checklist.
- `references/patrol-blueprint.md` - full architecture, real params, two concretizations (Feishu live / 腾讯文档 swap-in), "apply to other needs" 13-step checklist, anti-patterns.
- `schemas/item.schema.json` - item contract (single source of truth).
- `prompts/decide-next-action.md` + `scripts/decide-next-action.ps1` - 模型决策层（只判「下一步做什么」，调度/解析仍归代码）：worker 拿到 item 行后，把「项目 / 目标 / 下一步 / 最近结果 / 上次成果」填进提示词贴给任意 LLM，固定三行回答（`动作` / `理由` / `人工介入`）交给 `pwsh -File scripts/decide-next-action.ps1 -InputFile <回答> -OutputFile <json>`（省略 `-OutputFile` 写 `%TEMP%`）解析成 JSON；脚本只喂输入/解析输出/落盘，不做业务判断，缺字段或重复字段直接报错退出码 2 而不是猜，可复用做法用 `沉淀: - <做法> — <命令>` 一行追加。离线自测：`pwsh -File tests/verify-decision-prompt.ps1`。
- `adapters/*.adapter.json` - declarative provider descriptors.
- `adapters/command.adapter.json` + `scripts/command-adapter.ps1` - provider=command：一次命令调用输出 JSON 的源（SCNet / 任意 CLI / 数据库导出）。子进程执行、超时杀进程树、退出码透传、信封 itemsPath / 字段名 fieldMap 可配；零凭据，mock 命令随仓分发（`tests/fixtures/command/`）所以 CI 可真跑。
- `docs/adapting-a-provider.md` - 加一个数据源要动多少东西：command 适配的实测账（核心 0 行）、8 步清单、常见坑、何时只加 adapter / 何时动核心、**§8 当前 provider 支持边界与 SKIP 恢复条件**。
- `references/external-dependencies.md` - 外部依赖索引：Codex 全局规约、TextFile.ps1、lark-cli、lark-base-helpers.ps1、codex CLI —— 只记「权威源在哪 / 怎么取 / 取不到怎么办」，**不随仓分发**；取不到时的最小纪律底线也在该页。
- `references/scheduled-task-recipe.md` - 触发器层：计划任务 round 模型（首选）/ Register-ScheduledTask 模板 / nssm 常驻、看门狗、三条不变量、真实实例与踩坑。
- `tests/verify-no-secrets.ps1` - 密钥卫生门禁：`git ls-files` 全量扫受控文件（token 形态 / Bearer /
  凭据变量赋字面量 / AK-IA / gh-p_），并断言两个 JEV verify 脚本只从环境变量或仓库外密钥文件读；命中 FAIL 非零退出。
- `tests/verify-secret-history.ps1` - 历史盘点（`git log -p --all`），只报告命中提交/文件 + 轮换建议，永不失败、不改历史。
- `tests/verify-provider-isolation.ps1` - 装配层回归：四个 provider（bitable / tencent-docs / local-json / command）同名函数（Get-PatrolItems 等）同进程依次装配时互不串味；老实现必红。
- `tests/verify-command-adapter.ps1` - command 离线自测：mock 命令 / 信封与 itemsPath / 退出码 / 超时 / banner / fieldMap / 镜像幂等 / 与 local-json 形状一致。
- `references/local-json-adapter.md` - provider=local-json 适配器文档 + 拷贝即跑 dry-run 指南。
- `references/csv-file-adapter.md` - provider=csv-file 的 11 节规格：本地 CSV 源（零网络零凭据），含「什么时候该用 / 不该用」与已知边界。
- `tests/verify-adapter-spec.ps1` - descriptor/spec drift gate: required keys and types, unique provider matching the file name, module path exists, declared functions exist after a read-only dot-source, `${...}` placeholders resolvable in `config`; built-in broken-fixture self-test.
- `scripts/adapter-contract-test.ps1` - contract self-test over **every** descriptor (assembly -> list-items -> per-row schema -> resolve-name; write-back only checked for existence/callability).
- `scripts/` - 最小可跑参考实现：`local-json-adapter.ps1`（源适配器）+ `csv-file-adapter.ps1`（CSV 源适配器，`Import-Csv` 解析、列映射可配、写回只改目标行且无 BOM）+ `patrol-provider.ps1`（适配器装配层）+ `patrol-loop.ps1`（due-list/worker 池/回写/digest，worker 默认 dry-run）+ `sample-tasks.json` / `sample-tasks.csv`（示例任务）。
