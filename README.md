# patrol-scaffold

可复用、供应商无关的「定时巡检」自动化脚手架（Codex skill）。

从一套在用的飞书巡检定时任务系统抽象而来。核心洞察：整套巡检链路里只有最顶层的
「数据源适配器」认识厂商（飞书 Bitable / 腾讯文档智能表格 / Sheets / 本地 JSON），
下面的调度器、worker、关联器、输出、看门狗全部可原样复用。换数据源 = 换一个适配器
+ 改一个 `provider` 配置字段，下游不动。

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
- `references/patrol-blueprint.md` — 全架构 + 真实参数 + 两种落地 + 13 步迁移清单 + 踩坑
- `references/codex-global-rules.md` — Codex 全局规约快照（活文件为准）
- `references/textfile-helper.md` — `TextFile.ps1` 写盘 / 通知 helper API
- `references/scheduled-task-recipe.md` — 触发器层注册 recipe

## License

MIT — 见 [LICENSE](LICENSE)。

---

> 注：`references/codex-global-rules.md` 与 `textfile-helper.md` 为「快照 + 活文件为准」参考资料，落地前请重读其指向的活文件。