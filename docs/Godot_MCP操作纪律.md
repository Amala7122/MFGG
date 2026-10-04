# Godot MCP 操作纪律

> **这份文档不是 `dsh-godot-ai` 随包技能 `godot-ai-orchestration` 的拷贝。**
>
> 那个技能 `upstream` 指向 `hi-godot/godot-ai/tree/**v3.1.5**`，正文写"**45 个工具**"。
> 本项目实际运行的是 godot-ai **4.3.0** + Godot **4.7.2**（47 个工具），跨了一个大版本。
> 因此本文每条都在本机环境里重新核对过，并标注证据等级与陈旧风险。
>
> 核对日期：**2026-10-04**。Godot 4.8 发布后需重新核对"机制已变"与"待实测"两类条目。

## 环境基线

| 项 | 值 |
|---|---|
| Godot | 4.7.2-stable (official) |
| godot-ai addon | 4.3.0 |
| godot-ai MCP 服务 | 4.3.0（`uvx --from godot-ai==4.3.0 godot-ai attach --port 8000 --ws-port 9500`） |
| attach 协议 | protocol_version 2 |
| MCP 工具数 | 47 |
| MCP 注册位置 | `$DSH_HOME/cordis.patch.yml`（由 Godot addon 写入，HOME 层，对所有会话生效） |
| 项目 | `D:/godot_project/godot-zelda/`，主场景 `res://scenes/hyrule_field.tscn` |

## 证据等级约定

| 标记 | 含义 |
|---|---|
| ✅ | 已核实 —— 读过 4.3.0 源码或本机实测 |
| 📄 | 与 4.3.0 自带工具文档一致，但**尚未实测** |
| 🔄 | **机制已变** —— v3.1.5 的写法已不适用，已附 4.3.0 的新机制 |
| ❌ | **不适用** —— 属于 `dsh-godot-ai` 插件特性，不是 MCP 能力 |

---

## 1. `batch_execute` 的回滚是**整批**的 —— 📄

任一条子命令失败且返回 `rolled_back: true` 时，**前面已经显示 `ok` 的命令也一并被撤销**（走场景 undo 历史）。
所以修正后必须**重放并回读整批**，不能只补失败那一条。

- 4.3.0 的工具文档确实写着 `undo` 默认 `true`，且"any successful sub-commands are rolled back"——与旧技能一致。
- **但这条尚未在本机实测。** 实测方法见文末。

## 2. 写入前先读，不要凭描述推断现状 —— ✅

版本无关的纪律，保留。顺序：`session_manage(op="list")` 发现编辑器 → `editor_state` 确认项目/场景/readiness/play state → 再读目标（层级、属性、脚本、资源）→ 才动手。

## 3. `project_run` 现在是**幂等**的 —— 🔄 机制已变

**旧技能说**：`mode="current"` 可能启动旧标签页，所以验证隔离目标要用 `mode="custom"`。

**4.3.0 的实际情况**（`addons/godot_ai/handlers/project_handler.gd:230-297`）：

```gdscript
if EditorInterface.is_playing_scene():
    return ...(was_already_running = true, "Project was already running; no action taken")
...
match mode:
    "main":    EditorInterface.play_main_scene()
    "current": EditorInterface.play_current_scene()
    "custom":  EditorInterface.play_custom_scene(scene_path)
```

危险**换了形态**：不是"开错标签页"，而是"**已经有东西在跑时，你的 run 请求静默变成空操作**"——你依然会验错场景，只是信号变成了返回里的 `was_already_running`。

**正确做法（4.3.0）**：

1. 跑之前先 `project_manage(op="stop")`（幂等，未运行也成功），或至少检查返回的 `was_already_running`。
2. 验证具体目标时用 `mode="custom"` + 显式 `scene`——4.3.0 会对该路径做 `McpPathValidator.loadable_error` 校验，比 `current` 更严。
3. 跑完立刻核对 `editor_state.current_scene` 与目标路径；不一致就 stop 重跑，**不要**去读或修那个意外启动的场景。

**附加（4.3.0 新增的可用杠杆）**：`project_run(autosave=false)` 会临时关掉 `run/auto_save/save_before_running`，跑完还原，不污染用户偏好（源码注释标注 issue #81）。做冒烟测试时用它，避免为了跑一次而落盘。

## 4. 判定运行状态用 `game_status.status`，不要只看 `is_playing` —— 📄

`editor_state` 返回 `game_status.status`，取值语义不同：`live`（helper 在线）/ `launching`（继续轮询）/ `break`（卡在调试器断点，**不会自己恢复**）/ `no_helper`（进程在但没助手）/ `stopped`。

- 本机已观察到 `stopped`。
- 其余取值**尚未实测**，但 4.3.0 的工具文档明确描述了 `break` 与 `no_helper`——结构存在。
- `break` 的处理：`project_manage(op="stop")` → 修最早的解析错误 → 重新 run。

## 5. `input_sequence` 只保证 action 的 **pressed 状态** —— 📄

4.3.0 文档对 `input_action` 的描述是"**Set a project action's pressed state directly in the running game**"——注意是"直接设置按压状态"，**不是注入 `InputEvent`**。这与旧技能的警告一致：不保证产生 `_input` / `_unhandled_input`，也不保证脚本在同一帧看到 `is_action_just_pressed`。

**推论**：需要判边的自动化验证，用上一帧状态自行判边（`is_action_pressed` + 缓存上一帧），不要指望 `just_pressed`。

**但尚未实测。** 这是本清单里最需要实测的一条。

## 6. 优先结构化查询，慎用 `game_eval` —— ✅ 4.3.0 文档自证

`game_eval` 是在运行中的游戏里执行 GDScript，可能因解析/运行异常让 helper 进入 `break`。4.3.0 的 `editor_state` 文档自己就写了：`game_status.status="break"` 意味着"游戏进程停在远程调试断点，**不会自行恢复**——需调用 `project_manage(op="stop")`"。

所以"能用结构化 `game_manage` 查询就别用 eval"在 4.3.0 依然成立，且被官方文档直接支持。临时 eval 改状态只用于诊断/构图，重跑后再做玩法验收，避免污染证据。

**注意（4.3.0 变化）**：`game_eval` 已**不再是独立工具**，而是 `editor_manage` 的一个 `op`。

## 7. Adaptive runtime 的执行预算 —— ❌ 不适用

旧技能提到"Adaptive runtime 会拒绝第 4 次相同请求、第 3 次项目启动、第 9 次 `game_eval`"。

这是 **`dsh-godot-ai` 插件的 preset 行为，不是 MCP 能力**（插件代码里有 `ADAPTIVE_READ_ONLY_TOOLS`、`guardAdaptiveProjectRun`）。只有选中 `godot-creator-adaptive` preset 时才存在；本项目的默认会话是插件旁观状态，**这些拒绝根本不会发生**。

→ 不要把这条当成本项目的操作约束。

## 8. 证据分级：不得声称高于实际证据等级的验收 —— ✅ 版本无关

报告实际证据：读回值、run id、日志结果、测试结果、视觉描述。**没有证据就说明未验证。**

视觉验收按降级链选择：模型直接读图 → 专用视觉桥 → 尺寸/像素/颜色 + 运行时 UI 回读。`editor_screenshot` 截图前确认对应 run 仍为 `live`，并记录 `stale_frame` 与 run token。

---

## 4.3.0 相对旧技能描述的实测差异

| 项 | 旧技能（v3.1.5） | 本机实测（4.3.0） |
|---|---|---|
| 工具总数 | 45 | **47** |
| 技能未提及的新工具 | — | `custom_manage`、`navigation_manage` |
| `game_eval` 位置 | 独立工具 | **`editor_manage` 的 op** |
| `project_run` | 非幂等，`current` 可能开旧标签 | **幂等**：已在跑 → 空操作 + `was_already_running` |
| `mode="custom"` | 未说明校验 | 走 `McpPathValidator` 路径校验 |
| 运行前保存 | 未说明 | `autosave=false` 可临时抑制（issue #81） |
| Adaptive 预算 | 列为纪律 | 插件特性，本项目不适用 |

**路由表覆盖度**：旧技能提到的工具名中，45/47 依然准确；差异仅上述两项。

## 待实测清单

以下三条只做到"与 4.3.0 文档一致"，尚未在本机跑过。实测后应把标记从 📄 改为 ✅ 或修正：

1. **`batch_execute` 整批回滚** —— 在一个**临时场景**里发一批"一条成功 + 一条失败"的命令，检查成功那条是否被撤销、返回是否含 `rolled_back: true`。安全前提：MCP 的场景修改在内存中，**不调用 `scene_save` 就不会落盘**；测完用 `scene_open(force_reload=true)` 丢弃。
2. **`input_sequence` 的判边行为** —— 跑起游戏，对一个 action 发 `input_sequence`，同时用脚本或 `game_manage` 回读 `is_action_just_pressed`，确认它是否在同一帧为真。
3. **`game_status.status` 全取值** —— 正常 run 观察 `launching → live`；故意用有语法错的脚本 run，观察是否进入 `break`，并验证 `stop` 能恢复。

## 维护约定

- 本文只在**实际核对过**之后修改，并在表格里记录环境版本。
- Godot 4.8 / godot-ai 下一大版本发布后，优先复核"机制已变"与"待实测"两类。
- 上游来源：`godot-ai` 的 `protocol/attach.py:41-48` 明确说明——工具目录哈希在 attach protocol v1 中**仅用于诊断**，真正的门禁是"包主版本 + attach 协议 + 端口 + 排除域"。
