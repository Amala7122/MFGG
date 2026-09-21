# 敌人手感差异化分析 —— 让每种怪"凭 juice 就能被认出来"

> 目标：玩家可能记不住名字，但记得住感觉。扣扳机第 3 发时身体就知道"这是什么"。

> **注意（2026-09-19）**：本项目的服务器联机与本地分屏功能已整体移除，仅保留单机。
> 下文第 3 节「多人 / 本地分屏的关键约束」及涉及 `shooter_peer_id` / `for_peer_id` 的描述均为历史记录，不再适用。

---

## 0. 一句话结论

**你现在不是缺敌人，是缺"表现层的自由度"。**

15 个图鉴条目（`data/game_config.json:350-364`）填进去了，但只有 2 个脚本壳子（`melee_enemy.gd` / `ranged_enemy.gd`），而所有"打上去那一瞬间会发生什么"的代码，全部写在共享工具类里，且全部是硬编码常量。

结果是：数值差异 ≠ 手感差异。
你现在的差异体现在「要打多久」（hp / damage），没体现在「打成什么样」（受击形变 / 音色 / 死亡表演）。而玩家感知"我打的是谁"，只发生在命中到死亡之间那 0.1~0.6 秒。那段窗口里，你目前给所有东西发的信号量是完全一样的。

---

## 1. 现状诊断（代码证据）

### 1.1 表现层被完全共享，且不可配置

| 表现通道 | 实现位置 | 能否按敌人分叉 |
|---|---|---|
| 受击闪白 | `scripts/enemy_visuals.gd:17-18` | 否，常量 FLASH_EMISSION=(1.0,0.94,0.62) / FLASH_ENERGY=3.2 |
| 受击时长 | `melee_enemy.gd:318`、`ranged_enemy.gd:528` | 否，硬编码 hit_flash_time = 0.1 |
| 受击哆嗦 | `enemy_rig.gd:85-87` flinch() | 否，恒为 1.0，衰减统一 2.6 |
| 走路姿态 | `enemy_rig.gd:20-36` | 全是 @export，但从未被 per-instance 覆写 |
| 命中火花 | `ballistics.gd:206` | 否，颜色只有 3 档，impact_scale 没人传非 1.0 值 |
| 命中音效 | `ballistics.gd:211` | 否，全项目只有 hit / headshot / kill 三个 key |
| 伤害飘字 | `ballistics.gd:215` | 否，只有字号 emphasis 随 impact_scale 变化 |
| 死亡 | `melee_enemy.gd:324-333`、`ranged_enemy.gd:534-541` | 否，roll_drop + queue_free()，零死亡表演 |
| 顿帧 hitstop | —— | 全项目不存在（time_scale / hitstop 零命中） |
| 镜头抖动 | —— | 全项目不存在（shake 仅命中 addons 的 websocket handshake） |

一个反讽：**Boss 反而有个体性**（`boss.gd:229-237` 死亡时炸 8 个火花），杂兵没有。说明这套系统有人会做，只是没给杂兵做。

### 1.2 你已经有"手感数值"，但它们没有一个连着显示器

这是最关键的一条。`enemy_roster.attrs_default`（`game_config.json:340-348`）里躺着 7 个手感维度：turn_speed / accel_ratio / knockback_resistance / stagger_duration / attack_distance_scale / contact_damage / armor。

它们全部只进伤害 / 移动算式，没有一个有视觉或听觉出口：

- 打 armor 0.15 的巨型破坏者（`game_config.json:362`）和打 armor 0 的士兵，视觉上完全一样 —— 看不出这刀被吃了 15%。
- knockback_resistance 0.8 的破坏者，手雷推不动它 —— 但没有任何"我推不动它"的反馈。
- turn_speed 150 度/秒 的破坏者，绕背是有效打法 —— 但玩家读不出"它转不过来"，因为转弯时没有预备动作。

这些数值对玩家不存在。它们是结算变量，不是表现变量。这是第一矛盾点，也是改造成本最低的地方。

### 1.3 用信号学的语言重述

一次击杀，玩家能接收到的身份信号：

```
身份信号量 = f(受击形变, 受击时长, 受击音色, 火花形貌, 顿帧强度, 位移/不位移, 死亡表演, 死亡音色)
```

当前 f 的 8 个自变量全部是常数，信息熵等于 0。

不管你把 hp 从 40 调到 520、把 scale 从 0.65 调到 1.75，因为过程中的反馈是同一张位图，玩家只会觉得"这个血厚一点 / 这个块大一点"，不会觉得是另一种生物。

体型和血量是静态属性，在扣扳机之前就被看见了；真正的手感发生在扣扳机之后的那 0.1 秒。

---

## 2. 核心方法论：手感应成为配置的一等公民

不要写 15 套手感。做 5 个 Feel Class，每个 Class 一套完整的受击 / 死亡 / 音色签名，15 个条目各自归属一个 Class，允许少量个体 override。

### 2.1 五个 Feel Class（按你现在的 roster 天然聚出来）

| Class | 成员 | scale / hp / spd 特征 | 应该给它的手感 |
|---|---|---|---|
| A 脆皮快腿 | 小型追猎者(40)、迅捷刀手(65)、疾行刺客(55)、猎杀幼体(65)、侦察射手 | ≤0.82 / ≤65 / ≥5.1 | 轻、飘、打上去像打纸，一碰就大幅飞出去，起身快，死时像纸片被掀翻 + 高频碎裂音 |
| B 标准兵 | 近战士兵(90) | 约 1.0 / 90 / 4.0 | 基准线。中等停顿、中等形变、标准木质钝响。其他所有 Class 都以它为锚，偏离它才产生"感觉" |
| C 精英 / 施法 | 狂战士(150)、精英剑士(240)、旋流术士 | 1.05–1.25 / 150–240 | 有前摇。攻击前明显预备；受击时有短暂被激怒的直跺动作；死时能量泄出（紫 / 青带电光） |
| D 铁壁 | 重装战士(210)、大型盾卫(260)、弹墙炮手 | 1.35–1.4 / 210–260 | 钉住感。你打它，它不后退（形变极小），只有擦溅火花 + 金属"铛"。死时向前瘫跪，1.0s 后倒地消失，低频闷轰 |
| E 地标 / 炮台 | 巨型破坏者(520)、重型迫击炮 | ≥1.55 / 520 / ≤2.4 | 墙。几乎零形变，转向有巨大预备动作（明确告诉你可绕背），打上去像敲钢筋。死亡是一个小型事件 + 全场可见冲击环 |

设计要义：A 和 D 的对比必须极端化。一个是纸，一个是墙，中间的 B / C 自然有了层次。不要试图让 15 个都各自不同 —— 玩家的辨识系统只支持 5 加减 2 个类别，超过就全部糊掉。要的是 5 个能立刻认出来的感觉家族，不是 15 个微妙渐变。

### 2.2 八个 Juice 通道（按性价比排序）

#### 通道 1：步态参数化（最高性价比）

`enemy_rig.gd:20-36` 已经全是 @export_range：walk_cadence / run_cadence / walk_swing / run_swing / knee_base_bend / knee_swing_bend / move_lean_degrees / bob_height / arm_swing / pose_smoothing。

这些字段天生支持 per-instance 覆写，只是从来没人传值。在每个 entry 里加一节 gait，在 configure_stats() 时喂进 _rig 即可。

步态是最强的"这是谁"的信号，而且是免费的：一个 0.65 倍大的幼体和一个 0.65 倍大的脆皮，如果共用同一套 walk_cadence 6.2，视觉上就是同一个东西换了皮肤在滑行。

建议配置：
- A 脆皮：walk_cadence 11、run_cadence 15、bob_height 0.09、move_lean -14 度 —— 碎步高频、上下颠，像虫子
- D 铁壁：walk_cadence 3.4、bob_height 0.02、move_lean -2 度、knee_base_bend 0.3 —— 沉重缓慢、几乎不起伏，像坦克
- E 地标：再慢一档 + pose_smoothing 5.0 —— 动作惯性极大，起步和刹车各要半秒

#### 通道 2：受击形变 —— 把 flinch 参数化

现状 `_rig.flinch()` 恒等于 1.0（`enemy_rig.gd:85`）。改成 `flinch(intensity: float = 1.0)`，由 knockback_resistance 反推：`intensity = 1.0 - knockback_resistance`。

- A 脆皮（res 0）→ 1.0 → 整向后弹 + 头大幅仰起，像被扇了一巴掌
- D 铁壁（res 0.3–0.5）→ 0.5–0.7 → 只有肩膀沉一下
- E 破坏者（res 0.8）→ 0.2 → 几乎不动，只有材质闪

"打到打不动的东西"必须看得见。现在 knockback_resistance 0.8 白写了。

同时把受击时长从写死的 0.1 改成随 Class：A 0.06s（脆快干净），E 0.22s（慢沉滞重）。

#### 通道 3：死亡表演（第二重要）

现在 die() 只有 roll_drop + queue_free()。你把一个敌人从"可交互"变成"不存在"只用了 0 帧。而死亡的 0.5 秒恰恰是定义"我打的是这货"最有效的证据。

| Class | 死亡编排 | 时长 | 新音效 key |
|---|---|---|---|
| A 脆皮 | 向上弹起 + 绕轴翻转 + 顶点处炸成一撮碎片点云 | 0.4s | death_squish 高频短促 |
| B 标准 | 后仰倒 + 落地后 0.5s 内沉入地面（Y 缓沉 + scale 归零） | 0.6s | death_body 钝响落地 |
| C 精英 | 原地僵直 0.3s + 一圈能量外泄 + 瘫软 | 0.8s | death_energy 下行扫频 + 噪声尾巴 |
| D 铁壁 | 向前跪 → 停顿 → 侧倒 → 解体 | 1.0s | death_armor 金属刮擦 + 低频落地轰 |
| E 地标 | 短暂停顿 → 自身抖动 → 小型 radial burst + 玩家可见冲击环 | 1.2s | death_titan 炸裂 + 余震 |

注意：Boss 已经有"死亡要看得见"的意识（`boss.gd:228` 注释写着"避免它静悄悄地消失"）。杂兵缺同一件事。

#### 通道 4：音色分化（半天工作量，收益极大）

`audio_manager.gd:_synth()`（116-145 行）目前只能合成 sine + noise。只需要加一个参数：

```gdscript
func _synth(duration, freq_start, freq_end, decay, noise_mix, gain, wave := 0) -> AudioStreamWAV:
    # wave: 0=sine 1=triangle 2=square 3=saw
```

方波 / 锯齿立刻就是"金属 / 机械"，纯 sine 是"钝器 / 血肉"。一个 hit 音色裂变成 6 个 family：

| key | 给谁 | 音色方向 |
|---|---|---|
| hit_flesh | A 脆皮 | 短、闷、中频、decay 高（软） |
| hit_meat | B 标准 | 中性的"啪" |
| hit_metal | D 铁壁 | 方波 + 余响长 + 二次泛音，出"铛" |
| hit_energy | C 精英 | 下行扫频 + 轻微 chorus，电子质感 |
| hit_titan | E 地标 | 极低频 + 强噪声，像敲混凝土 |
| hit_deflect | 被 armor 吃掉的伤害 | 高频、短、极脆的"叮"，不放伤害数字 |

每个 entry 加 sfx_family 字段，resolve_hit 时从 target 上取。人的听觉对 pitch / timbre 的辨识力远高于对视觉细节的辨识力，这是"凭耳朵就知道打的是谁"的关键。

#### 通道 5：已有 attr 的可视化（补旧债）

| attr | 现在只有 | 该配的表现出口 |
|---|---|---|
| armor 减伤 | 进算式 | 伤害低于阈值时 → hit_deflect 音 + 灰白小数字 + 无命中标记 + 火星向下擦 |
| knockback_resistance | 削推力 | 通道 2 的受击形变强度（不再沉默，而是可见的不动） |
| turn_speed | 限制 rotation | 转身前 0.2s 的预备动作（抬肩 / 侧倾），让玩家读出"它转不过来"，绕背从理论变成爽点 |
| accel_ratio | 限制加速度 | 启动前一小段抖动 / 前倾，给出"它要扑过来了"的可读性 |
| contact_damage | 每秒结算 | 贴身距离内持续电弧 / 腐蚀光，把"别蹭"变成可见规则 |
| stagger_duration | 计时器 | 硬直期间有明显僵直姿（头垂、膝屈），给"我打断它了"的成就感 |

#### 通道 6：顿帧 hitstop（先每个 Class 固定 ms）

全项目目前没有。最简单的版本不需要改 Engine.time_scale（那会影响 UI、网络和另一个分屏座位）：

- 做一个本地 ImpactFrame 单例，`hitstop_request(ms, for_peer_id)`
- 只缩放该 peer 的 Player 的 delta 与武器 delta，敌人 AI 完全不动
- 建议值：A 0ms（脆皮不给顿，击杀才给 40ms）、B 40ms、C 60ms、D 90ms、E 120ms

设计逻辑：顿帧的作用是"这一刀有分量"。给得越少越轻松，越多越像砍进一件重物。**顿帧时长直接等于这个敌人的体重。**

#### 通道 7：火花形貌

现在 spawn_impact 只有一个 scale_multiplier。加一个 shape 枚举：

- 崩溅（flesh）：沿法线 ± 随机 60 度，重力下落，橙红
- 擦火花（metal）：沿表面切向飞（不是法线），亮黄白，数量少但更亮
- 能量（energy）：向上 + 缓衰减 + 色相偏移

打铁和打肉的火花飞的方向就不一样 —— 这一个细节几乎不用资源。

#### 通道 8：最后一刀的仪式

resolve_hit 已经传了 killed 布尔值（`ballistics.gd:130`）。现在 kill 只多放一个通用音。改成：

- 击杀那一发：伤害数字 emphasis 传 1.8（DamageNumber 已支持），上飘更快、延时淡出
- 击杀音效走该 Class 的 death_*，而不是通用 kill
- 准星命中标记：普通白环，击杀变成该 Class 主色 + 一次径向爆（PlayerHUD._on_hit_confirmed 已就位，且已支持 shooter_peer_id 路由）

---

## 3. 多人 / 本地分屏的关键约束

项目是服务器权威 + MultiplayerSpawner 复制。Juice 全部是本地表现，绝不能进复制。三个坑：

### 3.1 顿帧和抖动必须按"开枪者"路由

`EventBus.hit_confirmed(headshot, killed, shooter_peer_id)`（`event_bus.gd:66`）已经带 shooter_peer_id，`player_hud.gd:204` 也已经用 _owner_peer_id 做过过滤。复用这套：本地分屏时 A 座打中，只能 A 的坐位抖，B 完全无感；网络联机同理。

### 3.2 死亡表演：服务器现在会立刻 queue_free()

`melee_enemy.gd:333` / `ranged_enemy.gd:541` 死了马上释放，尸体连一帧表演时间都没有。

推荐解法（服务器权威侧改造，不需要新的同步属性）：

```gdscript
# die() 里，取代 queue_free：
remove_from_group("enemies")        # 立刻退出打击查询
set_collision_layer_value(1, false) # 不再吃子弹
_dead = true                        # _physics_process 早退
_play_death_choreography(class_id)  # 播死亡编排
await get_tree().create_timer(death_linger).timeout
queue_free()
```

期间 health 恒为 0、不参与任何结算、位置基本不动 —— 不需要改复制配置（当前只同步 position / rotation / health 三项，见 `enemy_spawner.gd:196-202`）。

备选的"客户端本地尸体特效"方案不推荐：两端不一致、分屏会出双份。既然规模不大，走服务端延迟释放最干净。

### 3.3 不要用 Engine.time_scale

会冻结 UI 动画、网络轮询，并且会把两个本地座位一起冻住。必须走 per-player 的 delta 缩放。

---

## 4. 落地优先级（性价比 = 视觉收益 ÷ 工作量）

| # | 改动 | 工作量 | 收益 | 备注 |
|---|---|---|---|---|
| 1 | 步态 gait 参数化 | 半天 | 5 星 | enemy_rig 的 @export 已就位，只缺一个入口 + JSON |
| 2 | 受击形变 + 闪白参数化（由 knockback_resistance / armor 反推） | 半天 | 5 星 | 不改结构，只把常量换成配置驱动 |
| 3 | 音色 family（给 _synth 加 waveform 参数 + 6 个新 key） | 半天 | 5 星 | 听觉是最廉价的辨识通道 |
| 4 | 死亡表演 5 套（复用现有 ObjectPool 模式） | 2-3 天 | 5 星 | 定义"消亡手感"的主力 |
| 5 | armor 可见化 / 擦碰 deflect | 半天 | 4 星 | 让已存在的 attr 第一次被感知 |
| 6 | 顿帧 per-Class | 1 天 | 4 星 | 注意 per-peer 路由 |
| 7 | 火花形貌 + 击杀仪式 | 1 天 | 3 星 | 锦上添花 |

第 1 + 2 + 3 项加在一起约 1.5 天，能让敌人从"都一个样"变成"至少能分出三四个感觉家族"。第 4 项是让它真正"记得住"的一步。

---

## 5. 验收方法：怎么知道做对了

不要靠自己感觉，做盲测：

1. **屏蔽语义信息**：录像时把 `HealthLabel`（`melee_enemy.gd:342` 输出的 标题 + 血条）关掉，把 armor_color 的 tint 也统一成中性灰。
2. **只留 juice**：播放录像，问自己或被试 —— "这一梭子打的是哪种？" 认对的判据是**过程**，不是外观。
3. **三重剥离测试**：
   - 只开视觉、关声音 → 能否分出 A / D / E？
   - 只开声音、闭眼 → 能否分辨？
   - 只看 0.3 秒的死亡片段 → 能否说出这是哪个家族？

   第三条如果过不了，说明死亡表演还没做到位 —— 而死亡表演恰恰是最容易做到位的那条。

4. **数值侧对照**（给每种敌人的"精力预算"定锚点）。击败耗时必须和手感分层对齐 —— 打上去像棉花的东西，也必须在一秒内倒下：

   | Class | 目标 TTK（默认武器满级） | 目标 HTK（发） |
   |---|---|---|
   | A 脆皮 | 0.6-0.9s | 4-6 |
   | B 标准 | 1.2-1.6s | 9-12 |
   | C 精英 | 2.0-2.8s | 16-22 |
   | D 铁壁 | 3.2-4.2s | 26-34 |
   | E 地标 | 6.0s+ / 需要爆头或爆炸武器 | 50+ |

   现在远程走 health_tier 档位（`ballistics.ranged_health`）、近战走 health × 等级成长（`enemy_spawner.gd:209-216`），两条路径的量纲并不相同 —— 建议统一按上表反推一次基准值，避免"同属 D 类，一个耗 3 秒一个耗 6 秒"造成的手感错位。

---

## 6. 最后：一个判断原则

下次要加新敌人时，问自己一个问题：

> **如果把这个敌人的名字、颜色、体型、血条全部藏起来，玩家还能凭"打上去 + 倒下去"这两种感觉认出它吗？**

如果答案是不能，那它不是一种新敌人，只是一种新数值。
