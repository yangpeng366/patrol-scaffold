# 数据源适配器规格模板（加一个新 provider，照此填）

> 这是一张**填表式**的表：照 11 节填完，一个新数据源就接进了巡检骨架。
> 填完必须过 `scripts/adapter-contract-test.ps1`（契约自测），否则不算接上。
> 骨架原理见 `references/patrol-blueprint.md`；契约见 `schemas/item.schema.json`。

---

## 0. 先决判断

- [ ] 需求是**周期性**的（不是一次性任务）
- [ ] 「要做什么」能落成**行**（表行 / 文档小节 / 数组条目）
- [ ] 每行对应**有界**的工作（一段有界 agent 工作，不是长期跑的任务）
- [ ] 行列里能读出：id、标题、优先级、间隔（其余可空）

四项有一条不满足，就不该用这套骨架，别硬套。

---

## 1. 源与触发映射（Source → Trigger）

| 项 | 填 |
|---|---|
| 数据源是什么 | 例：某系统的工单表 / 一个 markdown 文档 / 一个 API |
| 一次「读」的范围 | 例：全表 / 指定视图 / 指定目录 / 增量游标 |
| 触发方式 | 例：Windows 计划任务 `-Once` + IgnoreNew（首选）/ nssm 常驻 |
| 触发间隔 | 例：每 30 分钟一轮（轮内再按行间隔过滤） |
| 单实例保证 | 全局 mutex（例 `Global\patrol-<name>`）+ 轮次硬超时 |

**规则**：触发层不认识厂商；换源不动触发。

---

## 2. 配置 schema（字段 / 类型 / 默认 / 健康度）

| 键 | 类型 | 默认 | 健康度判据 |
|---|---|---|---|
| 例：`configPath` | string（绝对路径） | 空 | 非空且文件存在 |
| 例：`identity` | string | `user` | 属于允许值集合 |
| 例：`tasksFile` | string | `sample-tasks.json` | 可写目录 |

**规则**：
- 凭据**不入仓**：只存路径，token 走环境变量或凭据管理器（AGENTS.md 安全条）
- 外部依赖（如 `lark-base-helpers.ps1`）用**环境变量给路径**，别把本机绝对路径写死进仓
- 健康度判据要能被看门狗读：给一个「怎样算坏了」的布尔判据

---

## 3. 触发器构造

- [ ] 计划任务名：`CodexPatrol-<name>`
- [ ] 轮次硬超时：例 `RoundTimeoutSec = 1500`（超时让位给下一次触发，不堆叠）
- [ ] 并发上限：例 `MaxPatrolChildren = 3`（并发上限，非每轮取 N 条——后者会饿死 P2）
- [ ] 失败重置：连续 N 次失败后不复用旧线程（防死线程空转）

---

## 4. 接收范围（scope）

| 项 | 填 |
|---|---|
| 哪些行进入巡检 | 例：视图 `vewX` 下的全部行 |
| 哪些行明确排除 | 例：状态为「已完成」「归档」的行 |
| 每次最多取多少 | 例：100 行/轮（分页续取） |
| 假数据/演练开关 | 例：`fake` 列开则只产样本不真跑 |

---

## 5. 回复通道（Channel）

| 项 | 填 |
|---|---|
| 结果写回哪 | 例：源表的「当前阶段/下一步/外部成就」三列 |
| 写回开关 | 例：默认只读；写回须**配置开 + 显式开**双重门 |
| 人工通知 | 例：飞书机器人，只在「成/阻」各报一次 |
| 通知通道与源解耦 | 源是 A、通知走 B 是允许的（飞书源 + 企业微信通知） |

---

## 6. 线程上下文（Thread）

- [ ] 行内 `threadId` 列：worker 续跑用它（空则新建）
- [ ] 回写时把新线程 id 推回该列，让人能接手
- [ ] 连续失败 N 次后重置为新建（否则死线程永远续跑）

---

## 7. 策略（Policy）

- [ ] 源系统默认**只读**，写回必须显式开
- [ ] worker 只做有界、可逆的本地改动；不发布、不动外部系统，除非该行显式声明
- [ ] 关联器（correlator）只读 `git status/log`，不 commit/push

---

## 8. 执行变量

| 变量 | 来源 | 用途 |
|---|---|---|
| `title` / `repoPath` / `description` / `nextStep` | 行字段 | 拼 worker prompt |
| `priority` | 行字段 | 排序（P0 先） |
| `intervalMin` | 行字段 | 到期判定（`> 0` 才参与调度；`0` / 空 / 缺列 = 停跑） |
| `threadId` | 行字段 | 续跑 |
| `fake` | 行字段 | 演练开关 |

**规则**：prompt 里带上「时间自控：超时主动拆分到下一轮」，避免一轮跑不完拖死整轮。

---

## 9. 插件入口与循环（适配器模块）

模块只需提供三个函数，名字与契约一致：

```powershell
function Get-PatrolItems   { param(...) }   # list-items()
function Save-PatrolItems  { param(...) }   # write-back()
function Resolve-ItemName  { param(...) }   # resolve-name()
```

- 模块路径写进描述文件的 `module` 字段；缺函数 → 装配期直接报错（不等到运行时才发现）
- 形状不一的 item 由 provider 层统一归一（`ConvertTo-PatrolItem`），适配器自己不必造轮子

---

## 10. 插件注册（描述文件）

在 `adapters/<provider>.adapter.json` 落一个文件：

```json
{
  "provider": "<name>",
  "title": "<人可读名>",
  "module": "scripts/<name>-adapter.ps1",
  "kind": "file | cli | api",
  "needsCredentials": false,
  "needsNetwork": false,
  "description": "<一句话>",
  "config": { "<key>": "<默认值>" },
  "listItems":   { "function": "Get-PatrolItems",  "args": { "<参数>": "${<key>}" } },
  "writeBack":   { "function": "Save-PatrolItems", "args": { "<参数>": "${<key>}" } },
  "resolveName": { "function": "Resolve-ItemName", "args": {} },
  "optional":    { "syncBack": { "function": "<函数>", "args": {} } }
}
```

- `${token}` 由调用方注入（`-Values` 或环境变量 `PATROL_<PROVIDER>_<KEY>`）
- 槽位 `args` 的键名必须是该槽位 `function` 在模块 `param(...)` 里真实声明的具名参数（逐字含大小写；
  `verify-adapter-spec.ps1` 的 `E-ARGNAME` 会静态挡）。`-Items` / `-Item` 由装配层注入，不要写进 `args`；
  反方向不要求：函数声明了但 `args` 没给的参数（如 `$Items`）是合法的
- `optional` 放能力型函数（如 bitable 的 syncBack）；没有就留空对象

---

## 11. 测试清单

**必做（自动化）**

- [ ] `pwsh -File scripts/adapter-contract-test.ps1 -Provider <name>` → PASS
      （装配 → list-items 实跑 → 每行过 schema → resolve-name 非空）
- [ ] `pwsh -File scripts/patrol-loop.ps1 -TasksFile <样本> -Once -DryRun` → due/completed 数符合预期
- [ ] digest JSON 的 `method` 字段 == provider 名（不是写死的旧名）
- [ ] 立刻重跑一轮 → due=0（行间隔过滤生效）

**必做（人工）**

- [ ] 凭据缺失时是 SKIP 而不是 FAIL
- [ ] 只读模式下游系统零写入
- [ ] 写回开关：配置开 + 显式开，两个都开才写

**不该有的**

- [ ] 描述文件里没有本机绝对路径
- [ ] 仓里没有 token / key / 口令
- [ ] 仓里没有运行时产物（downloads/ reports/ state/）

---

## 完成标准

新增一个 provider = **两个文件**（描述文件 + 模块）+ 一次契约自测 PASS。
若你发现还得改 `patrol-loop.ps1`，说明契约有缺口——先补契约，再改骨架。