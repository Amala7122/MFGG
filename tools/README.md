# 开发工具与运行产物

复用工具放这里，自动回归放 `tests/`，一次性材料放本次运行 `tmp/`。共同规则见 [AGENTS](../AGENTS.md)。

## 产物目录

默认位置：`D:/godot_project/_artifacts/godot-ruin_star_new/<任务>/<运行编号>/`。每次新建独立目录：

- `logs/`：stdout、stderr、引擎日志。
- `screenshots/`：截图，可按功能分子目录。
- `reports/`：汇总、JSON、性能 CSV，以及记录源码版本和工作区状态的 `run.json`。
- `tmp/`：隔离工程、故意报错的测试材料和一次性脚本。

Python 工具共用 `artifact_paths.py`，引擎侧共用 `scripts/artifact_paths.gd`；`capture_paths.gd` 是截图兼容入口。编辑器运行按项目建立独立目录；发行版使用 `user://artifacts/`。直接引擎运行未采集 Git 状态，记录中明确标注。

## 自动验收

需要 Python 3.10+：

```powershell
python -B tools/run_acceptance.py
python -B tools/run_acceptance.py --suite full
python -B tools/run_acceptance.py --graphics --tests test_ground_juice test_cloud_shadow_rendering
```

`--task` 指定任务名，`--output` 指定项目外父目录，`--godot` 指定引擎，`--timeout` 指定单项秒数上限。启动前检查目录规范。验收创建隔离工程和存档、关闭副本编辑器/MCP 插件，不读取原游戏成绩或修改原游戏方案。截图和日志通过 `--artifact-dir` 汇入同一次运行，副本位于 `tmp/project/`。

执行器检查 stdout、stderr、引擎日志；任何脚本/资源 ERROR、非零退出、超时、启动失败或缺失日志都使检查失败。WARNING 保留。每轮真实引擎自检故意注入错误，确认门槛生效。

## 手动诊断与截图

```powershell
python -B tools/run_probe.py tools/probes/engine_capability_probe.gd --task engine_probe
python -B tools/run_probe.py tools/probes/capture_post_process.gd --graphics --task post_process
python -B tools/run_probe.py tools/probes/cloud_field_capture.gd --graphics --task clouds
```

诊断入口同样使用隔离工程、独立日志和报告。脚本参数放最后的 `--args` 后，如 `--args --baseline-snapshot`。截图需图形环境；性能比较保留相同引擎、设备、窗口和运行条件。

`probes/` 包括截图工具、云模型/云影对照、地面性能、草地 LOD、引擎能力与 T03 路径观察。性能旧代码对照放 `tests/fixtures/attack_surface/`，其他项目共享原件保留。

`python -B tools/numerics_progression_model.py` 按历史公式读取当前配置，输出到独立 `numerics_model/<运行编号>/reports/`；公式未同步为当前运行代码实测，不作为现行数值验收。

## 目录检查与恢复

```powershell
python -B tools/project_hygiene.py check
python -B tools/project_hygiene.py restore --manifest <迁移清单绝对路径>
```

检查只报告，不删除。恢复默认只预览，明确执行追加 `--apply`；先核对路径与校验值，同名占用或整理后新修改会阻止恢复，需要人工合并。修改过的源码有备份，恢复保全整理版本；新工具与规则文件不自动删除。

本次清单位于项目外 `project_cleanup/20261008_165045_1ddc4433/reports/migration.json`，同目录 `migration.md` 为索引，原源码在 `tmp/before/`。历史验收副本在 `tmp/historical_analysis/` 保留原结构，不将旧布局强行改成新布局。

根目录旧日志归属不确定，保存到 `_artifacts/legacy/20261008_165045_1ddc4433/logs/`。未确认归属的公共截图及其他项目材料保持原位置。
