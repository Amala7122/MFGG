# Development tools

`tools/` 保存开发期辅助脚本，不属于正式游戏逻辑。

## probes/

`tools/probes/` 是手动诊断区。这里的脚本可以打印内部状态、API 能力或性能相关观察值，但不承担自动回归测试职责。

当前包括：

- `probes/grass_lod_probe.gd`：移动虚拟玩家并打印草地 LOD / 可见性分布。
- `probes/engine_capability_probe.gd`：核对 Godot 图形 API / 属性与场景绘制对象统计。

如果一个脚本能够稳定地自动判定 PASS / FAIL，应迁入 `tests/`；如果只是临时探索且不再有复用价值，应删除而不是长期堆在根目录。
