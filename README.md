# patrol-scaffold

可复用、供应商无关的「定时巡检」自动化脚手架（Codex skill）。

从一套在用的飞书巡检定时任务系统抽象而来。核心洞察：整套巡检链路里只有最顶层的
「数据源适配器」认识厂商（飞书 Bitable / 腾讯文档智能表格 / Sheets / 本地 JSON），
下面的调度器、worker、关联器、输出、看门狗全部可原样复用。换数据源 = 换一个适配器
+ 改一个 `provider` 配置字段，下游不动。

**适应性的三层落法**（这版起）：契约有 schema 与自测硬约束，装配靠声明式描述文件，
扩展有填表式规格模板。新增一个 provider = 两个文件 + 一次自测 PASS，**主循环不改**。

## 解决什么问题

任何「周期性读一个任务表 → 给每行派发一段有界 agent 工作 → 回写结果 → 摘要入库 →
看门狗自愈」的 recurring 需求，都能用这套蓝图快速实例化，不必每次重造架构。

## 七层架构（只有第 1 层认识厂商）

1. **Source Adapter** — 读行数据为统一 item 结构（可换 provider）
2. **Scheduler** — 按每行 interval + 优先级算 due-list；worker 池并发上限；round 硬超时；全局 mutex
3. **Worker** — 每项一段有界 `codex exec`；按 threadId 续跑否则新建；连续失败 N 次重置
4. **Sync-back** — 回写 CurrentStage / NextStep / Achievement + threadId 到源行
5. **Correlator** — 映射发现 → 本地仓 git 状态
6. **Output** — digest JSON + MD → 记忆库追加
7. **Watchdog** — 独立任务查存活 + 告警，不替主流程做事

外加 **Trigger 层**（计划任务 round 模型 / nssm 常驻）。

## 两种落地

- **飞书（在用）**：provider=`bitable`，`lark-cli base` 读项目方向表 → 派发 `codex exec` → 回写 Bitable。
- **腾讯文档**：provider=`tencent-docs`，智能表格行 1:1 映射同一 item 契约，下游全不变。

## 其他 Agent 快速上手（先跑通命令行再谈架构）

拿到这套 skill 后，**第一步**是 dry-run 验证链路在你的机器上能通（实测为准，无凭据无网络）：

```powershell
cd scripts
pwsh -File adapter-contract-test.ps1      # 契约自测：适配器装配 + 每行过 schema
pwsh -File patrol-loop.ps1 -TasksFile sample-tasks.json -Once -DryRun
```

预期：契约自测 `pass=2 skip=2 fail=0`（csv-file / local-json 实跑，bitable / tencent-docs 无凭据时为 SKIP 而非 FAIL）；
`due=3/3`，三个 worker 完成，`sample-tasks.json` 的 `lastRun` 被回写，digest 落在
`downloads/patrol-<ts>.json|.md`。立即重跑：`due=0/3`（证 per-row interval 过滤生效）。

跑不通先修 pwsh / 路径——链路跑不通之前，架构读了也白读。跑通后再读 `references/patrol-blueprint.md` 理解架构、`references/local-json-adapter.md` 换真实数据源。

## 安装

```bash
# 方式一：Codex skill-installer 从本仓安装（推荐）
#   调用 skill-installer skill，传入本 repo 路径
#
# 方式二：手动
#   把本目录拷到 $CODEX_HOME/skills/patrol-scaffold/
```

安装后，任何会话遇到 recurring 巡检需求时调用 `patrol-scaffold` skill 即可拿到蓝图。

## 文件

- `SKILL.md` — 入口（七层架构 + 适配器契约 + 安全边界）
- `references/adapter-spec.md` — **加一个数据源的填表式模板（11 节）**
- `references/patrol-blueprint.md` — 全架构 + 真实参数 + 两种落地 + 13 步迁移清单 + 踩坑
- `schemas/item.schema.json` — item 契约唯一事实源
- `adapters/*.adapter.json` — provider 声明式描述（模块 / 配置 / 契约函数）
- `adapters/tencent-docs.adapter.json` + `scripts/tencent-docs-adapter.ps1` — 腾讯文档智能表格（第二类真实适配器）
- `adapters/csv-file.adapter.json` + `scripts/csv-file-adapter.ps1` — 本地 CSV 文件（第三类适配器，零网络零凭据；`Import-Csv` 解析、列映射可配、写回只改目标行）
- `scripts/patrol-provider.ps1` — 适配器装配层（导入、归一、调用）
- `scripts/adapter-contract-test.ps1` — 适配器契约自测（离线校验器）
- `tests/verify-tencent-docs-adapter.ps1` — tencent-docs 端到端自测（本地 mock 服务，无需真凭据）
- `tests/verify-csv-file-adapter.ps1` — csv-file 离线自测（%TEMP% 沙箱：列映射 / 引号逗号换行 / 缺列报错 / 写回字节保真 / 无 BOM）
- `docs/tencent-docs-adapter.md` — tencent-docs 的 11 节适配器规格与落地待办
- `references/csv-file-adapter.md` — csv-file 的 11 节适配器规格 + 「这类源什么时候该用 / 不该用」
- `references/external-dependencies.md` — 外部依赖索引（权威源 / 取法 / 降级），**不随仓分发**
- `references/scheduled-task-recipe.md` — 触发器层注册 recipe
- `tests/verify-no-secrets.ps1` — 密钥卫生门禁：扫全部受控文件，命中即非零退出
- `tests/verify-provider-isolation.ps1` — 多 provider 同进程同名函数不串味（装配层回归）
- `tests/verify-secret-history.ps1` — 历史密钥盘点：只报告命中提交，不改历史
- `.githooks/pre-commit` — 把门禁挂到提交前：`git config core.hooksPath .githooks`
- `.github/workflows/verify.yml` — CI（windows-latest / shell: pwsh）：契约自测 + csv-file 离线自测 + 密钥卫生

## License

MIT — 见 [LICENSE](LICENSE)。

---

> 注：本仓**不含任何外部依赖副本**。规约、helper 一律读活文件或由 agent 自行下载，
> 取法见 `references/external-dependencies.md`；取不到时按该页「最小纪律」办。
