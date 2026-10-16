# prototypes 目录扁平化（结构整理）

> 用户需求：『以后这些都整理干净，一个目录里躺一个东西，不要子目录加子目录的。根本想不起放哪儿了。比如 combat 下面还有一个 spatial，下面放的反而是更常用的小型战斗实验台。』
> 用户同时指定：**等另一会话收尾后再做**（另一 agent 已停）、死代码**归档而不是删除**。

## 目标

`prototypes/` 下**每个实验场一个目录，深度只有一层**；顶部提供一张"哪个台子在哪"的索引表；顺手清掉两个"看着像实验场其实不是"的文件。

## 步骤与状态

| 步骤 | 状态 |
|---|---|
| 1. 清点：每个文件是什么、谁在引用 | 完成 |
| 2. 定映射表（8 条前缀） | 完成 |
| 3. 搬迁 + 改写引用 + 清空目录 | 完成（移 62 个文件、改写 53 个文件） |
| 4. 归档死代码与转发壳 | 完成（`docs/archive/prototypes_cleanup_20261009/`） |
| 5. 修正移动后失效的相对链接 | 完成（`spatial_lab/README.md`、`T03_AUDIT.md` 各 3 条 + 归档快照 1 条） |
| 6. 加"哪个台子在哪"索引表 | 完成（`prototypes/README.md` 顶部） |
| 7. 自动校验 | 完成（见下） |

## 改动入口

| 内容 | 位置 |
|---|---|
| 索引表 + 新目录树 + 约定 | [prototypes/README.md](../../prototypes/README.md) |
| 迁移清单与回退说明 | `_artifacts/godot-ruin_star_new/prototypes_flat/20261009_220000_migrate/reports/`（`migration_report.md`、`manifest_moves.txt`） |
| 归档件 | [docs/archive/prototypes_cleanup_20261009](../archive/prototypes_cleanup_20261009/) |
| 检查改动 | [test_scene_dependencies.gd](../../tests/test_scene_dependencies.gd)（旧入口检查 → 实体场景检查） |

## 结果

```
prototypes/
├─ spatial_lab/          ★小型战斗空间台（常用）+ 空间能力台
├─ combat_lab/           主战斗实验场
├─ visual_lab/           敌人视觉实验场
├─ painterly_lab/        绘画风格实验
├─ weather_lab/          天气 / 天空
├─ enemy_prototypes/     四种程序化敌人（被上面几个共用）
├─ README.md / STATUS.md
└─ legacy/               旧实验归档
```

## 验证结果

- `test_scene_dependencies` **通过** —— 它递归枚举 `res://prototypes` 等目录下每个 `.tscn`/`.tres` 的传递依赖并逐个检查存在性，是本次迁移最强的自动校验。
- `project_hygiene.py check` **通过**（含"文档链接有效"）。
- 相关行为用例（空间台 / 盾卫反应 / 视觉台预览 / 图鉴 / 战斗反馈 / 战斗反应）**全部通过**。
  证据：`_artifacts/godot_ruin_star_new/acceptance/20261009_220428_3f887b3a/reports/summary.md`
- 未验证 / 未通过：`test_shockwave_push` 的 `1 resources still in use` 属已知 **I-041**（音效库 wav 泄漏、间歇性），与本次迁移无关。

## 下一步（未开始）

- 行为脚本（`scripts/prototypes/`）与场景（`prototypes/`）仍分处两棵树。这是项目既定规则，本次未动；若用户也觉得难找，可讨论是否改为随实验场就近存放。
- `STATUS.md` 里的历史状态说明是 2026-10-08 重置时留下的，未逐条复核（按规则不作为现行要求）。
