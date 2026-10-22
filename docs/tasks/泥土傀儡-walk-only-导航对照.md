# 泥土傀儡 WALK-only 导航替换：独立 A/B 实验

状态：**未在 Godot 中执行，默认关闭，不可作为生产修复合并。**

## 为什么选泥土傀儡

用户 4790K+2080 的 30 只 headless 基线：正常 25.1 FPS；禁用30只敌人的 `_physics_process` 为143.8FPS。单只泥土傀儡物理步约527µs（7只合计3.7ms/物理步），角蜂373µs（5只合计1.9ms/物理步）。首批共享支撑缓存与蜂飞行高度去重，用户实机无可觉察收益。不能继续靠小缓存猜问题。

泥土傀儡 `ground.tres` 只有 WALK capability，但它的正常脚本仍每步进入 `NavSteering.tick -> CombatSpatialController.tick`；随后普通追击又进入 `NavSteering.ground_velocity -> CombatSpatialController.adjust_ground_motion -> NavSteering.raw_ground_velocity`。本实验**尝试直接绕过完整空间任务规划**，并保留每步真实位置、朝向、攻击队列、攻击命中、击退、受击、碰撞、跨坎与地面安全检查。

## 两个路径

- 默认：**完全保持旧行为**，不产生实验调用或频繁计时。
- 新：`--mud-walk-only` 开启；仅普通已落地 IDLE/WALK、AI启用、移动已激活、目标有效、导航地图已同步、空间控制器无正在执行的特殊行为/错误状态时跳过 `CombatSpatialController.tick`。`NavSteering.direction_to` 使用原生 `NavigationAgent3D`，每物理步仍执行 `gate_motion` 边缘保护、`GroundMovement.move` 和现有近战几何命中验证。地图版本或破坏版本变化立即 `repath`；不安全的移动会使空间状态转 `unsafe_drop`，下一步回到旧链路；原生导航连续0.3秒给不出前进方向，也会让旧规划器接管至少1秒以尝试恢复。其他兵种完全不变。

**未覆盖/重要风险：** 原始空间规划器对目标所在层级、绕路、无路点、悬崖退让与受困恢复承担较多职责。新模式只是结构消融，不承诺复杂多层/陡坡/破坏物环境行为等价。若新模式使敌人长时间停滞、越层、跌落、瞬移、无故无法攻击，即使帧率升高也判失败。原生导航地图的体型净空问题 I-097 未修，不能据新模式直接移除其余碰撞和边缘守卫。

## 实机验证

原本的启动命令后面添加 `-- --mud-walk-only`（Godot 自身参数和游戏用户参数用双横线分开），例如：

```powershell
.\Godot_v4.7.2-stable_win64.exe --path . -- --mud-walk-only --perf-log --perf-output=D:\tmp\mud_walk_trial
```

上述命令打开正式图形游戏，进入战斗后再测；单独以 `--headless --path .` 启动菜单并不等于生成30只敌人。若要无头重放，需另用真正加载遭遇战的既有探针。用相同场景配置、相同30只构成、随机种子、玩家移动和物理频率测量。**先运行无 `--mud-walk-only` 的对照。** 启动后的控制台约每600个物理帧打印一次 `[mud-walk-only]` 累计直接步数和原链回退数；直接步数占比过低时，说明本对照没有覆盖测试场景。

至少需要对照：
- 30混合怪、30泥土傀儡；玩家静止/持续移动；
- 崖边/坑沿/不同楼层/厚障碍/破坏物改图/重开；
- 攻击队列和地面预警并发、近战命中、受击击退/死亡；
- FPS 中位/p95/p99、物理补步数及观察到的AI停顿、死亡人口。
- 现有 `tests/test_combat_spatial_navigation.gd`、`tests/test_navigation_moving_target.gd`、`tests/test_enemy_roster.gd` 回归（仍可能受已记录 I-354 的既有失败影响，需修改前对照）。

原则：这是架构方向的低风险隔离**实验开关**，并非产品默认解决方案，未经 Godot 编译、回归和用户实机对照不得标记“完成优化”。
