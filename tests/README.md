# Automated tests

`tests/` 只放可以明确给出通过 / 失败结果的自动检查。

当前测试：

- `test_stability_contracts.gd`：核心运行契约，例如画质档位、坠落处理、击杀归属、目标相机等。
- `test_lowpoly_mesh.gd`：低多边形倒角网格的绕序、法线、尺寸与碰撞生成。
- `test_runtime_world_visibility.gd`：正式主场景运行时的关键世界节点可见性，以及帧率 / VSync 基线。

约定：

1. 自动测试必须通过退出码表达成功或失败。
2. 只打印观察数据、需要人工判断的脚本不要放在这里。
3. 一次性或手动诊断脚本放在 `tools/probes/`。
4. 已不存在的历史测试名不要继续写进“当前自动检查”清单。
