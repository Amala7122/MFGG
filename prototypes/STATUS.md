# 原型生命周期登记表

这个文件回答一个问题：**仓库里的实验，现在到底处于什么状态？**

它不替代详细设计文档，也不决定玩法优先级。它只防止“试着做一下”的代码在几周后悄悄变成第二套正式系统。

## 四种状态

| 状态 | 含义 | 允许做什么 |
|---|---|---|
| **Active / 实验中** | 正在验证想法，尚未进入正式游戏 | 可以快速迭代、推翻、加临时工具；不得宣称已正式接入 |
| **Graduating / 毕业中** | 已决定进入正式游戏，正在封口和适配 | 优先修阻断、做试玩和正式接入；原则上停止继续扩张实验范围 |
| **Integrated / 已接入** | 对应能力已经进入主游戏运行路径 | 正式代码成为真相来源；实验场只保留隔离验证用途 |
| **Archived / 已归档** | 历史参考，不再主动开发 | 可以查阅；除非明确“复活”，否则不要继续加功能 |

尚未写代码的点子不进入本表，先记在 `docs/开发备忘录.md`。一旦开始创建实验脚本 / 场景，就应在同一次开发周期里登记到本表。

## 当前登记

| 实验 / 系统 | 状态 | 当前入口 | 与正式游戏的关系 | 下一步 / 停止条件 |
|---|---|---|---|---|
| Combat Lab 战斗测试场 | **Active** | `prototypes/combat/combat_lab.tscn` | 开发工具，不是正式关卡 | 保持稳定，用来验证战斗；不要把正式流程继续塞进 Lab |
| 敌人独立调参系统 | **Active** | `scripts/prototypes/enemy_tuning.gd`、`prototypes/combat/enemy_tuning_panel.gd`、`data/enemies/` | 当前服务程序化敌人实验 | 继续作为实验基础设施；正式敌人接入时再决定哪些能力迁入正式层 |
| 原型群体运动 | **Active** | `scripts/prototypes/enemy_crowd.gd` | 当前只服务程序化原型 | 只有首章正式敌人确实需要时才迁入主游戏；不提前扩成完整群体 AI 框架 |
| 沉积泰坦 | **Graduating** | `prototypes/combat/enemies/procedural_sediment_titan.tscn`、`scripts/prototypes/procedural_sediment_titan.gd`、`scripts/prototypes/titan_*.gd` | 目前仍在 Combat Lab；主游戏未正式接入 | 完成 B0 封口与用户试玩；随后在首章战斗阶段做正式场地适配。封口前不继续无限加招 |
| 泥土傀儡 | **Active** | `prototypes/combat/enemies/procedural_mud_golem.tscn`、对应脚本与 JSON | Combat Lab 可玩，正式刷怪未使用 | 只有被选入首章正式阵容时才进入 Graduating |
| 迅捷晶兽 | **Active** | `prototypes/combat/enemies/procedural_fast_beast.tscn`、对应脚本与 JSON | Combat Lab 可玩，正式刷怪未使用 | 只有被选入首章正式阵容时才进入 Graduating |
| 晶刺蜂 | **Active** | `prototypes/combat/enemies/procedural_hornet.tscn`、对应脚本与 JSON | Combat Lab 可玩，正式刷怪未使用 | 只有被选入首章正式阵容时才进入 Graduating |
| 旧近战手感实验场 | **Archived** | `prototypes/legacy/melee/enemy_melee_lab.tscn`、`lab_melee_player`、`lab_beast_target` | 旧 F 键近战参考，不是当前正式玩家能力 | 保留用于查手感思路；正式近战需求另行接入，不继续扩展旧 Lab |
| Enemy Visual Lab 视觉观察台 | **Active** | `prototypes/visual/enemy_visual_lab.tscn`、`scripts/prototypes/enemy_visual_lab.gd` | 开发工具，不参与战斗；用于固定灯光 / 相机条件下检查造型、轮廓、材质与比例 | 长期保留为纯视觉检查入口，不与 Combat Lab 合并 |
| 第一版快速野兽剪影 | **Archived** | `prototypes/legacy/visual/fast_beast_prototype.tscn`、`scripts/prototypes/beast_prototype.gd` | 已被后续程序化迅捷晶兽路线替代 | 仅作早期造型历史参考 |
| Sky3D 独立实验场 | **Integrated** | `prototypes/environment/sanctum_sky3d_experiment.tscn` | Sky3D / 天气能力已经进入主场景 `WeatherEnvironment` | 保留隔离实验场用于天气和天空验证，正式行为以主场景实现为准 |

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

1. **只有想法**：记进 `docs/开发备忘录.md`，不急着设计完整系统。
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
