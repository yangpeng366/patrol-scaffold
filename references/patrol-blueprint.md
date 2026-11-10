# Patrol Blueprint (provider-agnostic architecture + concretizations)

This is the deep-dive behind `patrol-scaffold/SKILL.md`. It captures the live
飞书巡检定时任务 ecosystem as ONE generalized architecture, shows two
concretizations (Feishu today, 腾讯文档 swap-in), and ends with an
instantiation checklist for applying the pattern to other user needs.

## Architecture at a glance

```
Trigger (schtasks -Once / nssm)
   |  fires every interval
   v
[Scheduler round] --mutex (1 instance)--> due-list (per-row interval + priority)
   |  worker pool, concurrency cap, round hard-timeout
   v
[Worker x N]  codex exec  (resume threadId else NEW; reset after N fails)
   |  bounded timeout; prompt built from row fields
   v
[Sync-back] write CurrentStage/NextStep/Achievement + threadId -> source row
   |
   +-- [Correlator] map findings -> local repo git state (branch/commit/dirty)
   +-- [Output] digest JSON + MD -> Obsidian memory append
   +-- [Notify] lark-cli im -> user (on completion/block only)

[Watchdog] separate task: log-staleness + service-state + process-count -> ALERT only
```

Only the **Source Adapter** (top of the scheduler) and the **Notify** channel
know a vendor. Everything in between is reusable verbatim.

## Layer detail (with live Feishu params)

### 1. Source Adapter
Reads rows into a common item shape. Provider selectable via one config field.

Live Feishu values:
- provider = `bitable`; tool = `lark-cli base +record-batch-create --as user`
- base `Vb6pb5SJ4aWpEpsqPxvcR5Tqnte`, table `tbl2XGd8bO10NBY5`, view `vewK5iifVn`
- row fields -> item shape:
  - 项目名 -> title
  - 仓库路径 -> repoPath (validated: rejects 中文括号/多仓拼接)
  - 简要描述 -> description
  - 下一步 -> nextStep
  - 优先级 (fldEYpg0Ow, P0/P1/P2) -> priority
  - 巡检间隔(分钟) (fldsIZTCL9) -> intervalMin
  - 假数据模式 -> fake (skip real collection, emit fake findings)
  - codex_thread_id (fldl2M1qYo) -> threadId

### 2. Scheduler
- due = `now - lastRun >= intervalMin`, and only for `intervalMin > 0`;
  `0` / empty / missing / negative interval = **disabled** (parked, never scheduled — no 60-minute fallback)
- priority sort via PriorityOrder {P0=0, P1=1, P2=2}
- worker pool: `MaxPatrolChildren = 3` concurrent active workers (NOT a per-round cap)
- round hard timeout `RoundTimeoutSec = 1500` -> yields to next nssm/schtasks trigger
- global mutex `Global\codex-auto-patrol-loop` -> no concurrent instances
- weekend multiplier 0.5 on weekend days [0,6]
- optional model-promotion window (e.g. glm-5.3-flash, off-hours 23:00-09:00)

### 3. Worker
- one `codex exec` per item via `node .../codex.js`
- per-worker timeout `CodexTimeoutSec = 1800` (30 min)
- resume prior thread by threadId; else NEW
- `MaxConsecutiveFailures = 3` -> reset to NEW (prevents dead-thread loop)
- prompt assembled from row fields + a "time self-control" segment (worker self-splits long tasks across rounds)
- child job dot-sources main script to reuse functions

### 4. Sync-back
- write Current Stage / Next Step / External Achievement back to the source row
- push spawned thread id into the codex_thread_id field -> human/IDE takeover

### 5. Correlator (gitall-correlate pattern)
- match item text -> D:\gitAll repo names (normalized, len>=4)
- per match: branch / last commit / uncommitted count / dirty flag
- enriches digest items with `gitStates[]`
- READ-ONLY: only `git status` / `git log`; never commit/push

### 6. Output
- `downloads/<patrol>-<stamp>.json` (structured) + `.md` (human digest)
- append to `Obsidian Vault\<project>\memory\<date>.md` under `## <patrol-name>`
- best-effort; skill never overwrites existing memory

### 7. Watchdog (Mutual-Watchdog.ps1 pattern)
- separate scheduled task (`patrol-watchdog`, every ~30 min)
- checks: runtime.log freshness (MaxIdleMinutes=45), scheduled-task state,
  service state, codex/worker process count
- ALERTS only (lark-cli im) -> never performs the patrol's work
- anti-runaway: flags disabled tasks + stale logs

### Trigger
- Windows Scheduled Task, `-Once` semantics, IgnoreNew (no overlap)
- or nssm Windows service for long-running variants
- scheduled tasks in the live system: `CodexPatrolCodexAuto`,
  `feishu-doc-patrol`, `feishu-projects-patrol`, `patrol-watchdog`

## Provider interface (contract)

| method | canonical function | returns | notes |
|---|---|---|---|
| `list-items()` | `Get-PatrolItems` | `[{id,title,repoPath,description,nextStep,priority,intervalMin,threadId,fake}]` | the due-filter happens in the scheduler, not here |
| `write-back(id, fields)` | `Save-PatrolItems` | ok/err | fields = currentStage/nextStep/achievement/threadId |
| `resolve-name(id)` | `Resolve-ItemName` | string | human label for digest + correlator |

### 契约的三层落法（2026-11-10 起）

1. **契约层（硬约束）** — `schemas/item.schema.json` 是 item 结构的唯一事实源；
   `scripts/adapter-contract-test.ps1` 拿它逐行校验任何 provider 的产出。
   离线校验器自带（不用 `Test-Json`：它会去拉 JSON Schema meta-schema，离线会挂）。
2. **装配层（声明式）** — `adapters/<provider>.adapter.json` 声明模块路径、配置、
   三个契约函数与参数；`scripts/patrol-provider.ps1` 负责装配、归一、调用。
   **换 provider = 落两个文件（描述文件 + 模块），`patrol-loop.ps1` 不改一行。**
   形状不一的 item 由 `ConvertTo-PatrolItem` 在边界统一归一
   （坑：`ConvertFrom-Json` 会把 ISO 时间串变成 `[DateTime]`）。
3. **规格层（可抄）** — `references/adapter-spec.md` 是填表式的「加一个数据源」模板，
   11 节：源与触发 / 配置 schema / 触发器构造 / scope / Channel / Thread / Policy /
   执行变量 / 插件入口与循环 / 插件注册 / 测试清单。

旧名 `Read-PatrolItems` 保留为兼容包装（`scripts/BitAbleAdapter.ps1` 末尾），
新描述文件一律用 `Get-PatrolItems`。

## Concretization A - Feishu (live, today)

- provider `bitable`; identity `user` (lark-cli OAuth, no app-secret/tenant-token)
- two patrol flavors sharing this scaffold:
  - **info patrol** (feishu-patrol skill): source = Feishu IM `@me` via
    `lark-cli im +messages-search --query "@"`; self-filter; resolve chat names;
    correlate; digest to Obsidian. CLI-first, browser (puppeteer-core + Edge)
    only as fallback when CLI auth missing.
  - **work-dispatch patrol** (Codex Auto-Patrol): source = Bitable 项目方向表;
    dispatches `codex exec` workers; sync-back to Bitable rows.
- entry scripts: `Start-CodexAutoPatrolLoop.ps1` (-Once),
  `Start-FeishuProjectsWorkLoop.ps1`, `feishu-patrol-cli.py`

## Concretization B - 腾讯文档 swap-in (provider = tencent-docs)

The scheduler/worker/correlator/output/watchdog are unchanged; swap ONLY the
source adapter + notify channel:

1. Create a 腾讯文档智能表格 (smart sheet) with the same columns (项目名 /
   仓库路径 / 优先级 / 巡检间隔(分钟) / 下一步 / codex_thread_id / 假数据模式).
2. Authorize the 腾讯文档 open API (OAuth app; store token under a secrets path,
   NEVER in the repo per AGENTS.md §一 security rule).
3. Implement the adapter behind the same contract:
   - `list-items()` = smart-sheet record list (paginated) -> item shape
   - `write-back()` = smart-sheet record update by record id
   - `resolve-name()` = row title (already present)
4. Set `provider = "tencent-docs"`, `sheet_id`, token path in the patrol config.
5. If the source is an online doc (非表格): `list-items()` parses `##` headings
   as items; `write-back()` updates the section text. Less structural, but works
   for prose-style task lists.
6. Notify channel: replace `lark-cli im` with the 腾讯文档/企业微信 webhook or
   keep Feishu notify if the user lives in Feishu (notify is decoupled from source).

Everything downstream (due-list, worker pool, round timeout, mutex, thread
resume/reset, correlator, digest, watchdog) runs unchanged.

## Apply to other needs - instantiation checklist

1. Confirm the need is recurring (not one-off) and maps to "row -> bounded work".
2. Pick a source provider (bitable / tencent-docs / sheets / local-json). If no
   row source exists, create a small sheet first. 照 `references/adapter-spec.md` 填表，
   落 `adapters/<provider>.adapter.json` + 一个模块脚本，再跑契约自测。
3. Define the item fields -> title/repoPath/nextStep/priority/intervalMin/threadId.
4. Copy the scheduler loop; swap ONLY the source-read function (keep due-list,
   worker pool, mutex, round timeout).
5. Set: MaxPatrolChildren, RoundTimeoutSec, CodexTimeoutSec, MaxConsecutiveFailures.
6. Write the worker prompt template (row fields + "self-split long tasks" segment).
7. Wire sync-back (which fields to write back; which field holds threadId).
8. Wire correlator IF local repos matter (reuse gitall-correlate pattern).
9. Wire output (digest JSON+MD -> memory append).
10. Wire watchdog (staleness threshold + alert channel).
11. Register trigger: `schtasks` `-Once` IgnoreNew, or nssm service.
12. Dry-run with 假数据模式; then one real item with `-Force`; then full round.
13. Notify on completion/block only (AGENTS.md §五: 成则一禀，阻则一禀).

## Anti-patterns / gotchas (live lessons)

- per-round cap ("pick N per round") starves P2 -> use concurrency-cap worker pool.
- single global interval -> use per-row interval + priority.
- hardcoded DOM selectors break on vendor changes -> inspect-before-automate loop.
- BOM in .ps1/.java breaks builds -> always UTF-8 no BOM (AGENTS.md §一).
- credentials in repo -> secrets path / credential manager (AGENTS.md security).
- schtasks overlap -> mutex + IgnoreNew + round hard timeout.
- dead thread resume forever -> MaxConsecutiveFailures resets to NEW.
- long task blocks the round -> round hard timeout yields to next trigger; the
  prompt's "time self-control" segment tells the worker to self-split.
- `lark-cli im +messages-send --text` does not read `@file`; long text must go
  via `Send-LarkText -TextFilePath` (TextFile.ps1) to avoid literal `@xxx`.