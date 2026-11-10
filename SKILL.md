---
name: patrol-scaffold
description: Reusable provider-agnostic blueprint for scheduled "patrol" automations. Read work items from a row-based source (Feishu Bitable, 腾讯文档智能表格, Google Sheets, or local JSON), dispatch a bounded Codex worker per item by per-row interval and priority, sync results back, correlate with local git repos, digest into Obsidian memory, and self-heal via a watchdog. Instantiate this pattern for any recurring "read a task list -> do bounded agent work -> report" need; the live Feishu patrol system is one concretization of it.
---

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
cd <skill-dir>/scripts
pwsh -File adapter-contract-test.ps1
pwsh -File patrol-loop.ps1 -TasksFile sample-tasks.json -Once -DryRun
```

Expected: contract test `pass=1 skip=1 fail=0` (bitable is SKIP without
credentials, never FAIL); `due=3/3`, three workers complete, `sample-tasks.json` gets `lastRun`
written back, digest lands in `downloads/patrol-<ts>.json|.md`. Immediate
re-run shows `due=0/3` (per-row interval filter confirmed).

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

1. **Source Adapter** - read rows from a spreadsheet/doc source into a common
   item shape. Swappable provider: `bitable` | `tencent-docs` | `sheets` |
   `local-json`. This is the ONLY layer that knows the vendor.
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
- No credentials to any file; never commit secrets.
- Correlator only reads `git status/log`; never commit/push.
- Workers do bounded, reversible local work; no publish / external mutation
  unless the row explicitly opts in.

## Files

- `references/adapter-spec.md` - fill-in-the-blank template for adding a data source (11 sections) + test checklist.
- `references/patrol-blueprint.md` - full architecture, real params, two concretizations (Feishu live / 腾讯文档 swap-in), "apply to other needs" 13-step checklist, anti-patterns.
- `schemas/item.schema.json` - item contract (single source of truth).
- `adapters/*.adapter.json` - declarative provider descriptors.
- `references/codex-global-rules.md` - Codex 全局规约快照（活文件 E:\AI-Portable\codex-home\AGENTS.md 为权威源）：UTF-8 无 BOM、pwsh shell 纪律、改文件优先 helper、飞书通禀、文件失寻恢复。
- `references/textfile-helper.md` - TextFile.ps1 API（Set/Add/Get-TextFile、Set-TextFilePatch、BOM 扫除、Send-LarkText），巡检写盘与通知的手术刀。活文件 D:\gitAll\auto-deploy\_lib\TextFile.ps1。
- `references/scheduled-task-recipe.md` - 触发器层：计划任务 round 模型（首选）/ Register-ScheduledTask 模板 / nssm 常驻、看门狗、三条不变量、真实实例与踩坑。
- `references/local-json-adapter.md` - provider=local-json 适配器文档 + 拷贝即跑 dry-run 指南。
- `scripts/` - 最小可跑参考实现：`local-json-adapter.ps1`（源适配器）+ `patrol-provider.ps1`（适配器装配层）+ `adapter-contract-test.ps1`（契约自测）+ `patrol-loop.ps1`（due-list/worker 池/回写/digest，worker 默认 dry-run）+ `sample-tasks.json`（示例任务）。