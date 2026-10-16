# 原型生命周期登记表

> 2026-10-08：以下登记保留供识别已有实验，状态尚未在文档重置后重新核对，不是当前进度或待办清单。后续只按用户当前任务核实相关行，不默认接续表中的“下一步”。

这个文件回答一个问题：**仓库里的实验，现在到底处于什么状态？**

它不替代详细设计文档，也不决定玩法优先级。它只防止“试着做一下”的代码在几周后悄悄变成第二套正式系统。

## 四种状态

| 状态 | 含义 | 允许做什么 |
|---|---|---|
| **Active / 实验中** | 正在验证想法，尚未进入正式游戏 | 可以快速迭代、推翻、加临时工具；不得宣称已正式接入 |
| **Graduating / 毕业中** | 已决定进入正式游戏，正在封口和适配 | 优先修阻断、做试玩和正式接入；原则上停止继续扩张实验范围 |
| **Integrated / 已接入** | 对应能力已经进入主游戏运行路径 | 正式代码成为真相来源；实验场只保留隔离验证用途 |
| **Archived / 已归档** | 历史参考，不再主动开发 | 可以查阅；除非明确“复活”，否则不要继续加功能 |

新需求按根目录 `AGENTS.md` 建立必要的任务记录，不再写入旧备忘录。用户明确要求开发或调整某个实验后，再核实并更新对应登记。

## 当前登记

T03 空间策略（2026-10-07）：程序化三种地面角色与正式近战 / 射手共用 NavSteering 接入能力资源；不是把原型敌人加入正式刷怪。通用演示仍属 **Active**，入口 `prototypes/spatial_lab/capability_lab.tscn`。验证跳障、返程、拒绝无出口下降、破障和墙顶接战；墙顶依赖场景连接，潜地执行器尚未实现。详见 [空间能力](../data/combat_spatial/README.md)。

| 实验 / 系统 | 状态 | 当前入口 | 与正式游戏的关系 | 下一步 / 停止条件 |
|---|---|---|---|---|
| T03 可赋予空间策略与能力 | **Active** | `data/combat_spatial/`、`scripts/combat_spatial_controller.gd`；`prototypes/spatial_lab/capability_lab.tscn` | 三种地面原型及正式近战 / 射手共用策略；能力演示是开发工具 | 用户试玩高台 / 凹坑 / 破障；墙顶当前使用通用场景连接，潜地需真实执行器 |
| 沉积泰坦 Boss 直战台 | **Active** | `prototypes/boss_lab/sediment_titan_boss_lab.tscn` | 复用圣所正式地图、WaveDirector、EnemySpawner 与结算；跳过普通波次，武器按配置满配；放大体型按完整脚印安全投放，接近跃击与正式掩体破障走公共能力 | F6 直接试玩 9 万生命 Boss；R 重新挑战；2.6 普通速度、体型与战斗时长待用户验收；潜地未实现 |
| Combat Lab 战斗测试场 | **Active** | `prototypes/combat_lab/combat_lab.tscn` | 开发工具，不是正式关卡 | 保持稳定，用来验证战斗；不要把正式流程继续塞进 Lab |
| Combat Spatial Lab 小空间测试预设 | **Active** | `prototypes/spatial_lab/combat_spatial_lab.tscn`、`spatial_layout.tscn` | 复用 Combat Lab 投放 / 统计流程，固定验证高低差、掩体、薄板坡、跳跃普攻与 T02 射击；不是正式关卡 | 保留九个起点和成组投放；继续用户试玩，散布调参独立验收 |
| 可赋予环境破坏 | **Active** | `scripts/destructible_component.gd`、`destruction_profile.gd`、`environment_destruction.gd`、`data/destruction/`；Spatial Lab 石块 / 残柱 / 小树 / 矮墙区 | 实验场泰坦砸地、横扫、跃击与跳跃普攻已接入；正式关卡未接入 | 验证实际攻击时机、任意模型 / 多子碰撞赋予、材质复用、实墙遮挡、导航更新及重开恢复 |
| 可赋予战斗反应 | **Active** | `scripts/combat_reactions.gd`、`combat_reaction_profile.gd`、`data/combat_reactions/`；Spatial Lab 泰坦反应组 | 三种原型小怪已接入泰坦跃击危险 / 友军伤害；正式敌人未接入 | 验证撤离成功 / 失败、硬吃 / 击退 / 坠地、存活起飞 / 死亡、跨物种赋予、取消 / 清理与归属；不扩张成完整能力框架 |
| 敌人独立调参系统 | **Active** | `scripts/prototypes/enemy_tuning.gd`、`prototypes/combat_lab/enemy_tuning_panel.gd`、`data/enemies/` | 当前服务程序化敌人实验 | 继续作为实验基础设施；正式敌人接入时再决定哪些能力迁入正式层 |
| 原型群体运动 | **Active** | `scripts/prototypes/enemy_crowd.gd` | 当前只服务程序化原型 | 只有首章正式敌人确实需要时才迁入主游戏；不提前扩成完整群体 AI 框架 |
| 沉积泰坦 | **Integrated（Boss）** | `prototypes/enemy_prototypes/procedural_sediment_titan.tscn`、`scripts/prototypes/procedural_sediment_titan.gd`、`scripts/prototypes/titan_*.gd` | 已作为圣所四波后的正式 Boss 接入；正式方案显式启用接近跃击与破障，圣所掩体可被自身砸地处理；Combat / Visual Lab 继续复用同一实现 | F6 直战台验收 1.65 倍体型、2.6 普通速度、9 万生命与实际战斗时长；潜地未实现，普通敌人投放不因此自动完成 |
| 泥土傀儡 | **Active** | `prototypes/enemy_prototypes/procedural_mud_golem.tscn`、对应脚本与 JSON | Combat Lab 可玩，正式刷怪未使用 | 只有被选入首章正式阵容时才进入 Graduating |
| 迅捷晶兽 | **Active** | `prototypes/enemy_prototypes/procedural_fast_beast.tscn`、对应脚本与 JSON | Combat Lab 可玩，正式刷怪未使用 | 只有被选入首章正式阵容时才进入 Graduating |
| 晶刺蜂 | **Active** | `prototypes/enemy_prototypes/procedural_hornet.tscn`、对应脚本与 JSON | Combat Lab 可玩，正式刷怪未使用 | 只有被选入首章正式阵容时才进入 Graduating |
| 旧近战手感实验场 | **Archived** | `prototypes/legacy/melee/enemy_melee_lab.tscn`、`lab_melee_player`、`lab_beast_target` | 旧 F 键近战参考，不是当前正式玩家能力 | 保留用于查手感思路；正式近战需求另行接入，不继续扩展旧 Lab |
| Enemy Visual Lab 视觉观察台 | **Active** | `prototypes/visual_lab/enemy_visual_lab.tscn`、`scripts/prototypes/enemy_visual_lab.gd` | 开发工具，不参与战斗；用于固定灯光 / 相机条件下检查造型、轮廓、材质与比例 | 长期保留为纯视觉检查入口，不与 Combat Lab 合并 |
| 裂釉镇墓兽外形 | **Active** | `prototypes/visual_lab/tomb_guardian_visual.tscn`、`scripts/prototypes/procedural_tomb_guardian_visual.gd` | 仅在 Enemy Visual Lab 展示外形和姿态；尚无战斗、碰撞和首关接入 | 检查正侧面轮廓与威吓姿态，确认视觉方向后再设计战斗版 |
| 第一版快速野兽剪影 | **Archived** | `prototypes/legacy/visual/fast_beast_prototype.tscn`、`scripts/prototypes/beast_prototype.gd` | 已被后续程序化迅捷晶兽路线替代 | 仅作早期造型历史参考 |
| 手绘风格样板 | **Active** | `prototypes/painterly_lab/painterly_style_lab.tscn` | 独立视觉对照，不属于正式地图 | 固定条件比较形体/材质；不把候选艺术方向当定稿 |
| Weather Lab 天气测试场 | **Active** | `prototypes/weather_lab/weather_lab.tscn` | 主场景的无敌人副本；保留实际地形、植被、玩家和 WeatherEnvironment | 作为天气视觉与参数验证入口；不加入敌人、波次或正式关卡流程 |
| Sky3D 独立实验场 | **Integrated** | `prototypes/weather_lab/sanctum_sky3d_experiment.tscn` | Sky3D / 天气能力已经进入主场景 `WeatherEnvironment` | 保留隔离实验场用于天气和天空验证，正式行为以主场景实现为准 |

## 当前特别容易混淆的边界

### 四个程序化敌人还不是正式敌人

它们已经能打、能调参、能做群体运动，不等于正式关卡已经使用它们。当前正式刷怪仍有自己的旧体系。

只有状态从 **Active → Graduating → Integrated**，才能把“实验场可玩”逐步变成“主游戏已经采用”。

### 沉积泰坦是当前唯一明确进入 Graduating 的敌人原型

泰坦已经进入封口阶段。它现在的目标不是继续证明“还能不能再做一个技能”，而是证明现有交战能否成立、是否公平、是否值得进入首章。

### Combat Lab 不需要“毕业”

测试场本身是开发基础设施。它可以长期保持 Active，只要它仍然服务实验，不侵入正式流程。

### 已归档不等于必须删除

Archived 的价值是让未来的人知道：“这是旧路线，不要误以为它还是当前方案。”

如果某个旧实验重新变得有价值，先在本表把它改回 Active，再开始修改代码。

## 新点子的最短流程

1. **只有想法**：先与用户明确需求，确需记录时写入对应的新任务记录，不写进历史归档。
2. **准备动手试**：创建最小实验，并在这里登记为 Active。
3. **实验成立**：明确是否值得正式接入；不值得就 Archived。
4. **决定接入**：改为 Graduating，写清楚“毕业条件”，停止无边界扩功能。
5. **正式接入完成**：改为 Integrated，并注明主游戏的真实入口。
6. **旧实验仍有参考价值**：可以保留，但它不再是正式逻辑的真相来源。

## 登记模板

以后新增实验时复制一行：

```text
名称 | Active | 入口文件 | 目前与正式游戏的关系 | 明确的验证目标 / 停止条件
```

最重要的不是填表，而是强迫每个实验回答两个问题：

**我现在只是试什么？什么时候算试完？**
