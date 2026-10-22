# 敌人 CPU 物理更新：第一批低风险去重（2026-10-22）

基线分支：`codex/development-snapshot-20261021` / `ebfad38`。用户 4790K + RTX 2080、30只无头对照：正常 25.1 FPS、关闭所有敌人 `_physics_process` 143.8 FPS；对应 39.84→6.95ms/帧，差约32.89ms（帧时间比例82.5%）。这是整个敌人物理回调及其连带调用成本，不是互斥意义上的 GDScript CPU 独占时间。六兵种12次样本均值相加约7.2ms/物理步，不能直接解释约32.9ms/渲染帧的差值；应同时记录每个渲染帧内物理补步数及主线程CPU时间。

本批只实现两项不降频、不扩大误差、不取消判定的重用：

- `SpatialQuery.support(..., reuse_within_step=true)`：仅在多个敌人共享的目标支撑查询中启用，其他身体查询保留原生路径。当同一物理步、同一目标 `global_transform`、同一世界、相同落地状态/角度及 `Destruction.geometry_revision`，且已命中的**静态**支撑物也未移动时，复用正命中值；空命中、动态支撑物依旧每次原生查询。保持 `remember` 旧语义，支持测试与 A/B 关闭开关；`CombatSpatialController.tick` 复用目标支撑变量，去掉同回调重复查询。失效含任一姿态改变、下一物理步、地形版本改变、支撑体位姿改变、失效/离树；不按0.3米近似容差。
- `ProceduralHornet._physics_process`：同一步统一获取本蜂目标悬停高度，供空域更新、盘旋及恢复共同使用；不修改碰撞/飞行/瞄准的反馈频率，不取消任何状态分支。

验证入口：`godot --headless --path . --script res://tests/test_spatial_query_support_cache.gd`（按本机版本替换可执行文件）；并运行原有 `test_combat_spatial_navigation.gd`、`test_navigation_moving_target.gd`、`test_crystal_creature_combat.gd`、`test_new_enemy_visuals.gd`。注意项目已有的 I-354 空间坡道两项和 I-357 图形回归基线问题，必须与改前一致对照，不可放宽断言。

本地没有 Godot 可执行文件，也没有用户机器上的4790K环境：以上是代码修订与可复验测试，**不能宣称FPS已提升或完全解决30怪卡顿**。A/B 需固定同一30敌兵种、位置/种子、目标运动、脚下地形、状态窗口，先检查 `Query.support_cache_hits/misses`，再比较CPU各层微秒、每帧物理补步与正常FPS/p95。

后续结构改造仍应按照既有《百体敌人架构设计》推进：共享目标快照；普通地面WALK不每步支付能力规划；行为意图低频且错峰，物理移动和攻击时序保持60Hz；空域净空的事件化与最大查询预算；避免将伪装成空转的敌人纳入容量验收。
