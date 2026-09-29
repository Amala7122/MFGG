# MFGG

MFGG 是一个使用 Godot 4.7.x 开发的第三人称动作 / 探索游戏原型。项目目前正在从“生存战斗原型”收敛为可完整游玩的首章体验：探索、战斗、获取收获、返回营地并推进进度。

> 当前工程名仍保留一部分早期 `godot-zelda` / `hyrule_field` 命名。这些属于历史命名，暂不影响运行，计划在首章结构稳定后统一整理。

## 快速入口

- 主项目：`project.godot`
- 主场景：`scenes/hyrule_field.tscn`
- 全局数值配置：`data/game_config.json`
- 可调参数说明：`docs/参数速查表.md`
- 当前进度与下一步：`docs/项目总进度与下一步.md`
- 稳定性 / 性能基线：`docs/稳定性与性能基线.md`
- 战斗实验室：`prototypes/README.md`
- 文档索引：`docs/README.md`

## 目录地图

| 目录 | 用途 |
|---|---|
| `scenes/` | 正式游戏场景，以及独立的 experiments / prototypes 场景 |
| `scripts/` | 正式运行脚本；`scripts/prototypes/` 为实验敌人与实验逻辑 |
| `prototypes/` | 统一实验区：`combat/` 当前实验、`environment/` 环境实验、`legacy/` 历史实验 |
| `data/` | 游戏配置、敌人配置、实验预设 |
| `assets/` | 项目资产；其中 `assets/generated/valley/` 是当前导出仍会使用的静态山谷资源 |
| `shaders/` | 正式使用的 shader |
| `theme/` | UI 主题与字体 |
| `addons/` | Godot 插件，例如 Sky3D 与 Godot MCP |
| `tests/` | 稳定性与回归测试 |
| `tools/` | 开发期辅助工具 |
| `docs/` | 设计、进度、数值、视觉与技术记录 |

## 当前工程边界

正式游戏与实验系统目前同时存在。尤其是旧版正式敌人体系，与 Combat Lab 中的新程序化敌人体系仍处于并行阶段。

整理原则：

1. 实验先在 prototype 区域验证。
2. 验证通过后逐步接入正式场景。
3. 正式接入后再决定旧实现是退役、归档还是继续保留。
4. 不为了“目录漂亮”提前大规模搬动仍在开发中的脚本和场景。

## 配置与存档

平衡与玩法参数优先集中在：

`data/game_config.json`

程序化敌人的实验参数位于：

`data/enemies/`

本机工具配置不提交真实路径。仓库只保留示例：

- `active-game.example.json`
- `opencode.example.json`

实际的 `active-game.json` 与 `opencode.json` 已由 `.gitignore` 排除。

## Git 约定

不提交 Godot 缓存、构建产物、运行日志、视觉抓图、性能日志和本机 AI 工具缓存。

主要排除项包括：

`.godot/`、`build/`、`visual_captures/`、`performance_logs/`、`.godot-mcp/`

## 开发方向

当前优先顺序以 `docs/项目总进度与下一步.md` 为准。近期重点是收尾当前 Boss / 战斗实验，并把已有系统串成一段有开始、过程、结尾的首章试玩流程，而不是继续无限扩张新系统。
