# Development tools

`tools/` 保存开发期辅助脚本，不属于正式游戏逻辑。

## run_acceptance.py

统一验收入口，要求 Python 3.10+。在项目根目录执行：

```powershell
python tools/run_acceptance.py
python tools/run_acceptance.py --suite full
python tools/run_acceptance.py --graphics --tests test_ground_juice test_enemy_deployment
python tools/run_acceptance.py --graphics --tests test_player_presentation test_ui_surfaces test_upgrade_effects test_cinematic_flow_lifecycle test_cloud_shadow_rendering
```

默认创建隔离工程和存档，不读取原游戏成绩/显示设置，关闭副本的编辑器/MCP 插件。结果和原始日志保存在项目同级 `_analysis/acceptance/`；`--output` 可指定其他项目外目录，`--godot` 指定引擎文件，`--timeout` 指定每项的秒数上限。每次检查前都会执行真实引擎错误门槛自检，`--self-test-only` 可只跑该自检。

打印 PASS 或退出 0 仍可能包含引擎错误。入口同时扫描 stdout、stderr 和引擎日志，任何 `SCRIPT ERROR:` / `ERROR:`、非零退出、超时、启动失败或缺失日志都使验收失败；WARNING 记录而不当作脚本/资源错误。汇总同时提供 Markdown 和 JSON。无界面的完整检查明确列出跳过的图形专属检查；图形验收需要带 `--graphics`。

## probes/

`tools/probes/` 是手动诊断区。这里的脚本可以打印内部状态、API 能力或性能相关观察值，但不承担自动回归测试职责。

当前包括：

- `probes/grass_lod_probe.gd`：移动虚拟玩家并打印草地 LOD / 可见性分布。
- `probes/engine_capability_probe.gd`：核对 Godot 图形 API / 属性与场景绘制对象统计。
- `probes/cloud_field_capture.gd`：在天气实验场固定机位拍摄稀疏、多云、厚云、夜间、云底细节及切面/圆润版六模型地面陈列；使用图形渲染运行，截图写入项目同级 `visual_captures/procedural_clouds_v1/`。
- `probes/cloud_shadow_benchmark.gd`：固定 1080p 天气实验场镜头，交替比较关闭/硬/柔云影，记录 GPU/CPU 渲染时间、阴影绘制批次/三角形和对照截图；另拍单云强/弱日光、旧深度错误和风推动对照，`-- --capture-only` 可仅拍对照。使用图形渲染运行，写入项目同级 `visual_captures/cloud_shadows_v1/`。冻结游戏模拟以隔离阴影开销，不代表完整战斗性能。

如果一个脚本能够稳定地自动判定 PASS / FAIL，应迁入 `tests/`；如果只是临时探索且不再有复用价值，应删除而不是长期堆在根目录。
