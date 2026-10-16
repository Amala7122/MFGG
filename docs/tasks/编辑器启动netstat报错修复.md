# 编辑器启动 netstat 报错修复

- 目标：修复用户启动 `godot-ruin_star_new` 编辑器时出现的 `ERROR: Could not create child process: netstat -ano`。
- 问题登记：I-004，见 [问题台账](../issues.md)。
- 最新反馈：2026-10-08 用户确认「没问题了，godot ai也启用了」；附图显示 `Server connected`、Godot AI v4.3.0。
- 修改范围：Godot AI 插件的 Windows 监听端口查询与针对性自动回归。
- 当前状态：自动验证通过，用户已验收。

## 步骤与事实

1. 定位调用入口：已完成。`addons/godot_ai/utils/port_resolver.gd` 的 `windows_listener_snapshot()` 直接执行短名称 `netstat`；本机存在 `C:/Windows/System32/netstat.exe`。项目启用了 Godot AI 4.3.0，当前打开的引擎为 Godot 4.7.2。
2. 建立回归：已完成。`tests/test_mcp_windows_port_lookup.gd` 在真实本地 TCP 监听端口上验证正常环境和空 PATH 环境的占用、PID 以及释放后状态。修改前两种环境均通过，未复现用户启动时的报错，不能据此将 PATH 缺失认定为根因。
3. 加固系统工具寻址：首版完成。使用 `SystemRoot`（缺失时尝试 `windir`、最后使用 `C:/Windows`）定位 `System32/netstat.exe`，检查存在后才启动；文件缺失时直接保留原 PowerShell 后备查询。解析、端口占用与 PID 语义不变。
4. 使用统一验收入口及目录检查：自动验证通过。修改后隔离导入、错误门槛自检、端口回归均通过；交付前目录检查与 `git diff --check` 通过。
5. 编辑器重新启动观察：用户已验收。用户反馈启动错误消失且 Godot AI 已启用，附图显示服务连接成功；AI 未自行重启编辑器。

## 验证与后续

- 修改前 `python -B tools/project_hygiene.py check` 通过；已有被忽略的项目内引擎副本提示仍保留，未移动这些无关文件。
- 尚未验证：原编辑器进程触发错误时的环境；未断言 PATH 是唯一原因。启动错误消失与插件启用由用户反馈确认。
- 修改前回归通过（并未复现用户报错）：`D:/godot_project/_artifacts/godot-ruin_star_new/mcp_netstat_startup/20261008_203649_e262ca96/reports/summary.json`。包含隔离导入、引擎错误门槛自检、真实端口查询。引擎：Godot `4.7.2.stable.official.ed1daf0bf`。
- 修改后回归通过：`D:/godot_project/_artifacts/godot-ruin_star_new/mcp_netstat_startup/20261008_203852_c2d59688/reports/summary.json`；端口检查日志：同次运行 `logs/test_mcp_windows_port_lookup.stdout.log`、`logs/test_mcp_windows_port_lookup.stderr.log`、`logs/test_mcp_windows_port_lookup.engine.log`。
- 执行命令：`python -B tools/run_acceptance.py --tests test_mcp_windows_port_lookup --task mcp_netstat_startup --timeout 60`；交付检查：`python -B tools/project_hygiene.py check`、`git diff --check`。
- 验证边界：统一验收副本关闭编辑器插件，回归脚本直接调用同一端口查询实现；未重启用户当前编辑器，未验证完整 AI 插件启动流程，未验证 netstat 文件缺失时的 PowerShell 后备分支。仅确认当前机器改动后的查询功能正常，不将原报错根因或消失标记为已确认。
- 两次运行的 `tmp/project/` 隔离副本作为测试证据保留归档，未生成额外正式实现副本。
- 自动产物放项目外 `_artifacts/godot-ruin_star_new/mcp_netstat_startup/`，通过 `tools/run_acceptance.py` 生成。
- 本任务无剩余修复步骤；若同类错误再次出现，按新的完整命令路径与调用栈继续本任务排查。用户截图只能证明服务显示连接成功；不据此推断当前 Codex 会话已具备 Godot MCP 工具。
- 2026-10-08 用户重启 Codex 后的连接检查：本会话已加载 47 个 Godot AI 工具，`session_manage(list)` 确认项目 `D:/godot_project/godot-ruin_star_new/`；`editor_state` 返回 Godot 4.7.2、就绪、游戏停止，当前场景 `res://prototypes/weather_lab/weather_lab.tscn`；`scene_get_hierarchy` 成功读取真实节点。插件与服务版本均为 4.3.0、协议版本 2。本次只读验证，没有运行游戏、切换场景或保存用户场景。
- 连接检查证据：`D:/godot_project/_artifacts/godot-ruin_star_new/mcp_connection_check/20261008_205451_2a67752c/reports/connection.json`。已确认直接编辑器访问恢复；没有逐项试用全部 47 个工具，游戏运行时访问尚未实测。
