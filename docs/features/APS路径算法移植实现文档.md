# APS 路径算法移植实现文档（Godot 4 / ruin-star-new）

状态：**P0–P4 与 P6 已实施，P5 未做，P7 未开工**。方案部分（第 1–14 节）保持原样；本轮实施事实、适配清单、实测数字与未完成项见文末 **第 15 节**。
目标工程：`godot-ruin_star_new`。来源插件：`D:/godot_project/Adaptive64768b7cb9a5V14`（AdaptivePathfindingSystem 2.06，UE 5.8，仅 Win64）。
证据来源：本轮 6 份逐行研究报告（路径见文末第 12 节），全部带 `文件:行号`；本文所有 APS 侧结论都能落到具体函数与行号，Godot 侧结论能落到函数与行号。

关联：[任务记录](../tasks/UE_APS敌人导航插件研究.md)（同一任务的持续记录）、[问题台账](../issues.md)、[待做台账](../backlog.md)、[现有功能说明](敌人导航与俯视观察台.md)。
机器可读执行计划（PTC 模式用）：[APS路径算法移植实现文档.plan.json](APS路径算法移植实现文档.plan.json)。

---

## 目录

1. [一句话结论](#1-一句话结论)
2. [移植边界：值得移植什么、不值得移植什么](#2-移植边界)
3. [APS 的完整调用链与算法全景](#3-aps-的完整调用链与算法全景)
4. [逐阶段精读（含公式、常量、回退链）](#4-逐阶段精读)
5. [UE → Godot 原语映射与单位换算](#5-ue--godot-原语映射与单位换算)
6. [现状差距：现在这套「借鉴」到底缺什么](#6-现状差距)
7. [移植目标、非目标与硬约束](#7-移植目标非目标与硬约束)
8. [阶段化实施计划 P0–P7](#8-阶段化实施计划-p0p7)
9. [参数与调参入口设计](#9-参数与调参入口设计)
10. [观测台与调试信息设计（可直接复用 APS 配色/日志方案）](#10-观测台与调试信息设计)
11. [验收矩阵与新增测试](#11-验收矩阵与新增测试)
12. [PTC 模式执行指引](#12-ptc-模式执行指引)
13. [风险与未验证项](#13-风险与未验证项)
14. [源码证据索引](#14-源码证据索引)

---

## 1. 一句话结论

APS 的全部价值集中在**一条同步的、对已算出路径做几何形状加工的流水线**：

```
基础路径 → 机动区检测 → 侧路注入 → 自适应圆角 → 弧长重采样 → 弧形/波形/车道偏移形变 → 逐点投影与段验证 → 缩幅/绝对宽度回退 → 全路径终检
```

它**不做**速度、加速度、避障力、到达判定、脱困（全插件 grep 无 `AcceptanceRadius`/`MaxSpeed`/`Separation`/`stuck` 命中），也**没有**替换 A*（基础路径仍走 Detour `findPath`）。跟随层只做三件事：切 corridor 段、把**段末多边形中心**当目标交给 CrowdManager、临时关掉 crowd 的捷径优化——而且默认配置下 corridor 根本不构建，严格跟随必然回落。所以：

- 要移植的是**路径形状与它的失败回退机制**，以及**它的验证/缩幅策略**；
- 不要移植跟随与避障——`godot-ruin_star_new` 的 `NavSteering` + `CombatSpatialController` 已有更贴合本项目的一套（身体通道、真实支撑、脱困、换路）；
- 本次移植的真正增量是：**APS 的几何形状数学**（公式可 1:1 复刻）+ **APS 的分级回退顺序**（缩幅→绝对宽度→保留基准点→整条放弃）+ **本项目现成实现所缺的分帧能力**（把整条流水线做成可暂停的状态机，才有机会修掉 I-064 的 38 ms 单次阻塞，以及 I-066 的「走一步停一下」）。

---

## 2. 移植边界

### 2.1 明确移植（有源码依据）

| 项 | APS 来源（文件:行号） | 为什么值得 |
|---|---|---|
| 圆角打分模型（窗口双锚 + 乘性置信 + 事件分类） | `APS_PathMode_LowLevelArc.cpp:1046-1547`（打分 `:1312`/`:1316`/`:1318-1326`） | 现有实现只有一个 `dot > 0.98` 的判据（`navigation_path.gd:66`），无法区分「真拐角」与「路径点抖动」 |
| 二次 Bézier 圆角与采样数规律 | 同上 `:1395-1413`、`:1479-1506` | 公式纯 2D，可直接复刻；采样数随拐角强度插值 |
| 缩幅枚举 `GOffsetScales`（8 档 1.0→0.125） | `:39`，消费点 `:1432-1452`（选侧）、`:3111-3158`（逐点） | 现有实现也有 3 档 `[1.0,0.5,0.25]`（`navigation_path.gd:70/97`），档位粒度与用途不同 |
| 绝对宽度回退 `GArcAbsFallbackAmps`（600/450/300/200/120/80 uu） | `:43`，消费点 `:3232-3319` | 长路径上相对缩幅会全部失效，这是唯一兜底 |
| 弧形包络 `ComputeArcShape` | `:2273-2302` | 纯公式，1:1 可移植 |
| 左右符号 `ComputeLocalSideSign`（Wavy 蛇形） | `:2309-2330` | 现有实现完全没有波形，这是「不同角色走不同路线」的来源 |
| 幅度公式 `BaseAmp = 0.25·Dist2D·clamp(|S|,0,3)/3` | `:2959-2963` | 幅度随路线长度与强度自洽缩放 |
| 稀疏形变 `bSparseWarp = NumPts > 64 && |S| < 1.5` | `:2984-2991` | 点密集时的性能保护 |
| 逐点候选验证顺序（投影 → 前段 → 后段 → 区域代价） | `:3119-3158`、`:3160-3202` | 「先投影再验两段」的顺序保证了形变点不会脱离网格 |
| 两级缩幅 + 保留基准点 + 全路径终检 | `:3111-3333`、`:3336-3344` | 失败时保留基准点，整条终检失败则连圆角一起丢弃 |
| 弧长重采样（400 uu/点，上限 128，含 `NumMidPoints+2` 下限） | `:907-986`（`:944`/`:946`） | 现有实现完全没有重采样阶段 |
| 侧路注入的候选生成与长度 sanity | `:2345-2859`、常量 `:47-58` | 大车道偏移下的绕行；可选，优先级低于上面几项 |
| 调试配色（12 语义槽 × 8 调色板 + 稳定哈希取色） | `APS_DebugColorUtils.cpp`（报告 §23） | 观察台直接可用，多角色可区分且跨帧稳定 |
| 日志失败原因枚举 + KPI 汇总行 | `APS_NavLogs.cpp:9-16`、`LowLevelArc` 各处 `bDbg` 分支 | 观察台与压力报告可直接消费 |
| 帧预算可中断化的设计参考 | APS **没有**做（`FindPath` 全同步），只有 `APS_AsyncArcPathTask` 死代码；但 `APS_AsyncArcPathTask.cpp` 的「请求 → 结果」分离形态可作参考 | 用来设计本项目自己的可恢复状态机 |

### 2.2 明确不移植

| 项 | 依据 | 处理 |
|---|---|---|
| UE Recast/Detour 基础搜索 | `APS_PathMode_LowLevelBase.cpp:289` 只是 `dtNavMeshQuery::findPath` 包装 | 保留 Godot `NavigationServer3D.query_path` |
| `APSDetour` 的 `dtNodePool`/`dtNodeQueue` | 唯一消费者是一句 `using namespace`，无实例化；`LowLevelTiles.h:14` 自承是「日后替换 A* 内核」的脚手架 | 不移植 |
| 异步任务 `FAPSArcPathTask` | 全树无调度点（4 处符号命中全在自身文件） | 不移植，本项目自己做分帧 |
| Crowd 跟随层 | `APS_CrowdFollowingComponent.cpp:130-162`：段末多边形中心为目标，不承诺逐点跟随曲线；且默认 `bBuildCrowdCompatiblePathCorridor=false` 使走廊为空、严格模式必然回落 | 不移植，沿用 `NavSteering` |
| NavArea 代价 | `TryGetAreaCostFromPolyRef`（`:643-672`），Godot 无对应概念 | 留空实现一个 `candidate_cost()` 钩子，默认恒 0；差异登记 |
| 自定义路径旁路 `FindCustomPath` | `:3360-3409`、`:3542-3556` 命中后跳过全部处理 | 不移植；本项目不需要「外部整条接管」入口 |

---

## 3. APS 的完整调用链与算法全景

### 3.1 接入方式（极简，无对象、无注册）

- 唯一注册点：`APS_NavigationData.cpp:32` `FindPathImplementation = FindPath;`（替换静态委托，不是重写虚函数）。
- 唯一分派器：`APS_NavigationData.cpp:89-108` 的 `switch`，**无优先级机制**，`default` 落 `EngineOnly`。
- 默认模式有歧义：头文件 `APS_NavigationData.h:41` 写 `APS_Arc`，构造函数 `APS_NavigationData.cpp:35` 覆写为 `APS_LowLevelArc` → **运行时默认是 3850 行的 LowLevelArc**。`APS_Experimental` 完全等价于 `APS_Arc`（`APS_PathMode_Experimental.cpp:20`）。

### 3.2 主入口 `APSPathModeLowLevelArc::FindPath`（`:3452-3834`）

步骤顺序（每步都有行号，来自报告 `research_lowlevelarc_tail.md`）：

1. `:3459` 读调试开关；`:3461` 结果先置 `Error`。
2. `:3463-3481` NavData / Detour / Filter 三重空守卫。
3. `:3484-3497` 复用或新建 `FNavMeshPath` 并写 `Result.Path`。
4. `:3505` `ApplyFlags(Query.NavDataFlags)`；`:3508-3522` 起终点近似相等 → 单点 + `MarkReady` + `Success` 提前返回。
5. `:3526` `Dist2D`；`:3542-3556` **自定义路径旁路**（命中即跳过全部后续处理）。
6. `:3560` 拉接口参数；`:3562-3564` `bUseArc = 接口位 && Dist2D >= aps.Arc.MinDistance`。
7. `:3570` 取 Detour filter；`:3578` `APSQuery.Init(MaxNodes)`，节点预算 `:468-474` 按距离 256/512/1024/2048。
8. `:3586-3588` extent 转换；`:3590-3596` 三个布尔判据（是否允许 LOS 捷径等）。
9. `:3606-3616` **基础路径**；失败 `:3618` 直接 `Fail`（无部分路径降级）。
10. `:3626-3734` 机动区 + **侧路注入**。
11. `:3736-3749` **WarpPathToArc**（圆角 → 重采样 → 弧形形变 → 逐点候选）。
12. `:3763-3794` Crowd 走廊三分支（重建 / 填基础走廊 / 完全关闭）。
13. `:3796-3808` `MarkReady` + 结果判定：`bPartial && !bAllowPartialPaths` → `Fail`。

**重要缺口（Godot 侧要补）**：整条流程同步执行，没有分帧、没有异步、没有缓存；`bPartial` 只写不读（`:795` 写入、`:3801` 唯一使用），且**没有任何 partial 标记被写到结果或路径对象上**。

### 3.3 管线全景（代码注释 `:2338-2339` 自述的顺序）

```
BuildBaseDetourPath        (:712-838)    投影 → 可选 LOS 捷径 → A* → findStraightPath
BuildManeuverZones         (:1704-2027)  XYTurn/Slope/Mixed 事件检测 + 区间合并
AppendDirectCorner*Zones   (:2029-2208)  弱转角但锚点被挡 → 补直转角 zone
AppendSyntheticFallbackZone(:2210-2266)  无候选时在 35%–65% 段造保底 zone
TryInjectManeuverSideRoutes(:2345-2859)  8 相对档 × 2 侧 + 6 绝对档，逐候选 A* 重查
BuildAdaptiveCornerFilletPath(:1046-1547) 窗口双锚打分 → 二次 Bézier 圆角
BuildArcSamplingPath       (:907-986)    弧长等分，400 uu/点，上限 128
WarpPathToArc              (:2869-3345)  弧形/波形/车道偏移 + 逐点投影验证 + 缩幅回退
                          (:3336-3344)   全路径终检，失败则整体放弃形变
```

---

## 4. 逐阶段精读

### 4.1 投影与段验证（`:523-641`、`:841-894`）

- `FindNearestPoly`（`:523-574`）：UE→Recast 轴序换算在 `:536`，`OutRef == 0` 判失败。
- `HasNavmeshLineOfSight`（`:577-641`）：单次 `raycast`，`maxPath` **硬编码 8**，判据只有 `dtStatusSucceed && T >= 0.999`，**忽略** `RayPathCount` 与 `DT_BUFFER_TOO_SMALL`。
- `ValidateNavMeshSegment`（`:841-868`）：先对 A、B 各做一次投影，再对**投影后的弦**做 LOS。含义：真正限制侧偏预算的是 `Extent`，不是输入点本身。
- `ValidatePathOnNavMesh`（`:870-894`）：逐段短路。

**移植注意**：Godot 没有 navmesh 表面 LOS API。等价物是「沿段密集采样 + 投影误差判据」，而本项目已有这个能力（`spatial_query.gd:ground_segment`），但它是**重**的（含全身 `motion_clear`，单次最高 38.222 ms，I-064）。因此移植时必须做成**两级验证**（见 4.7 与 P3）。

### 4.2 圆角 `BuildAdaptiveCornerFilletPath`（`:1046-1547`）

**打分模型**（唯一原样可复刻的部分）：

```
AngleScore      = lerp(LocalCornerStrength, WindowCornerStrength, 0.70)        :1312
VisibilityFactor= 1.0 未测 / 1.15 锚点被挡 / 0.72 锚点通畅                       :1301-1311
CrossFactor     = 1.0 同号 / 0.60 叉积不同号                                     :1276-1278
Persistence     = lerp(0.45, 1.0, clamp(MaxNeighborSupport/0.35, 0, 1))         :1296-1299
FinalCornerScore= AngleScore · VisibilityFactor · CrossFactor · Persistence      :1316
FinalEventScore = max(FinalCornerScore, SlopeCornerStrength)                     :1316
```

**事件分类**（`:1318-1326`）：坡度阈值 0.35，`|CrossZ| < 0.05` 视为直行，分 `xy` / `slope` / `mixed`。

**五级跳过**（全部退化为「保留原角点」）：

| 回退 | 条件 | 行号 |
|---|---|---|
| 整体旁路 | `InNum < 3` 或 `NumMidPoints <= 0` 或 `LaneOffset ≈ 0` | `:1057` |
| 短段 | 任一相邻段 < `MinSegmentLenForFillet = 8 uu` | `:1229-1241` |
| 噪声 | 窗口分 < 0.20 且局部分 < 0.35 且坡度分 < 0.35 | `:1328-1348` |
| 弱角 | `FinalEventScore < StrongCornerThreshold = 0.35` | `:1350-1370` |
| 过密 | 距上一接受角 < `MinCornerSpacing` 且分数 < 上者 × 1.35 | `:1372-1391` |
| 圆角过小 | `FilletDistance < MinFilletDistance = 4 uu` | `:1399-1413` |
| 点预算 | `OutPoints.Num() + FilletSamples + 2 + 1 > 192` | `:1484-1489` |

**几何**（`:1395-1506`）：

```
MaxFilletDistance = 0.45 · min(lenIn, lenOut)
DesiredWidth      = |LaneOffset| · (坡度主导 ? slopeStrength : cornerStrength)
FilletDistance    = clamp(DesiredWidth · (0.6 + 0.4·cornerStrength), 0, MaxFilletDistance)
Entry = corner − dirIn·FilletDistance ;  Exit = corner + dirOut·FilletDistance
Control = corner + PreferredBaseSide · Lanesign · DesiredWidth          (:1477)
Bézier  : P(U) = (1−U)²·Entry + 2(1−U)U·Control + U²·Exit
采样数  : FilletSamples = clamp(round(lerp(2, clamp(NumMidPoints,2,6), strength)), 2, DetailSamples)
采样参数: U = k / (FilletSamples + 1)，k = 1..FilletSamples（显式排除端点）
```

**选侧**：坡度事件遍历 `GOffsetScales` 探测左右自由度（`:1432-1452`）；XY 事件直接取弯外侧（`:1470-1475`），**不做通行性验证**。

### 4.3 重采样 `BuildArcSamplingPath`（`:907-986`）

```
TargetArcSegmentLength = 400 uu                                        :944
DistanceDrivenTotal    = ceil(TotalLen / 400) + 1                      :941-946
DesiredTotal           = min( max3(NumMidPoints + 2, DistanceDrivenTotal, InNum), 128 )   :946
```
- 纯 2D 段长（Z 不参与），按弧长等分，**不按曲率加密**。
- `NodeRef` 直接沿用源段（`:980`，注释自承「will be snapped later anyway」）。
- 已知缺陷：`:964-968` 与 `:985` 可能重复追加末点，产生重复点/零长段。

### 4.4 弧形形变 `WarpPathToArc`（`:2869-3345`）

**早退**：`Dist2D < GetMinArcDistance()`（cvar `aps.Arc.MinDistance` **未注册**，恒 300 uu = 3.0 m，`:462-466`）；`|ArcStrength| < 0.1`；`NumPts <= 2`；`BaseAmp ≈ 0`。

**幅度**：
```
GlobalSideSign = (ArcStrength >= 0) ? +1 : −1                     :2959
StrengthNorm   = clamp(|ArcStrength|, 0, 3) / 3                   :2961-2962
BaseAmp        = 0.25 · Dist2D · StrengthNorm                     :2963
MinRelativeAmp = BaseAmp · 0.125                                  :2973
```

**形状函数**（`:2273-2302`，可直接照抄）：
```
Outer = sin(π·t)
Smooth: Exp = 1 + (clamp(NumMidPoints,1,6) − 1)·0.5 ;  Shape = Outer^Exp
Wavy  : Humps = clamp(NumMidPoints,1,6)              ;  Shape = Outer · |sin(Humps·π·t)|
两侧：Smooth → 恒 GlobalSideSign；Wavy → GlobalSideSign · sign(sin(Humps·π·t))   :2309-2330
```

**每点偏移**（`:2986-3054`）：
```
t           = CumulativeDist[i] / TotalLen
Right       = (−dir2D.z, 0, dir2D.x)                    ← UE 里是 (−Dir.Y, Dir.X, 0)
ArcOffset   = Right · (LocalSideSign · BaseAmp · Shape)
CornerLane  = CornerOffsetDir · LaneOffset · clamp(1 − dot(dirIn,dirOut), 0, 1)   （弯外侧，按 CrossZ 定侧）
ZoneLane    = 主导机动区包络 α 决定的额外侧移（CornerLane 再乘 (1−α) 防重复）
稀疏保护    : NumPts > 64 且 |ArcStrength| < 1.5 → 跳过偶数索引          :2984-2991
```

**逐点候选**（`:3111-3333`）：

| 层级 | 候选 | 每候选的检查顺序 |
|---|---|---|
| 1（相对） | `GOffsetScales` 8 档 {1, .875, .75, .625, .5, .375, .25, .125} 乘 `Offset` | ① 投影 `FindNearestPoly`（失败→下一档）② `ValidateNavMeshSegment(prev, cand)` ③ `ValidateNavMeshSegment(cand, next)` ④ 区域代价 ≤ 基准 + 0.001 |
| 2（绝对） | `GArcAbsFallbackAmps` {600,450,300,200,120,80} uu，**只试小于 `MinRelativeAmp` 的档**，车道偏移部分保持全幅 | 同 ①②③④，弧形部分用固定宽度重建 |
| 兜底 | 全部失败 → **保留基准点** | `:3320-3333` |
| 终检 | 整条形变路径 `ValidatePathOnNavMesh` | 失败 → **连圆角一起丢弃**，回到原始 Detour 点（`:3336-3344`） |

### 4.5 侧路注入（可选阶段，`:2345-2859`）

激活需**同时**满足：`|LaneOffset| >= 180 uu`、`Zone.RequestedWidth >= 130 uu`、`Zone.Strength >= 0.32`（`:47-49`）。
候选 = 8 相对档 × 2 侧 + 6 绝对档（`:2534-2560`）；每候选：投影 → 代价比较 → 两段验证 → 失败则**对两小段重新 A*（禁用 LOS 捷径）** → 长度 sanity `≤ DirectLen·5 + 150 uu`（`:54-55`）→ `ValidatePathOnNavMesh` → 预算（每次注入 ≤ 24 点、基础路径 ≤ 96 点，`:50-51`）→ 逆序 splice（可替换则替换，否则插入并按 1.0 uu 裁剪）。
兜底 zone：路径 35%–65% 段造 `Strength=1`（`:63-65`、`:2210-2266`）。

**移植建议**：这一阶段的收益（大车道偏移下的绕行）与成本（成倍 A* + 验证）都远高于前四项，**排在 P6 之后**，且默认关闭。

### 4.6 机动区检测（`:1704-2027`，侧路阶段的前置）

局部三点转角与 ±`WindowLookDistance` 窗口锚点转角按 **0.70** 混合；两级噪声过滤；区间合并。
`WindowLookDistance = clamp(|LaneAbs|·1.35, 110, 480) uu`；`MergeGap = clamp(|LaneAbs|·0.9 + N·16, 80, 260) uu`；
`ZoneHalfLength = clamp((|LaneAbs|·1.4 + N·20 + 90)·TypeMul·lerp(0.78,1.08,Strength), 90, 640) uu`。

### 4.7 性能真相（决定移植形态）

| 事实 | 依据 |
|---|---|
| `FindPath` 全同步，无分帧、无异步、无缓存 | `:3452-3834`；唯一的 `AsyncTask` 在 `:407`（调试画线） |
| `FAPSArcPathTask` 是**未接线的死代码** | 全树 4 处符号命中全在自身文件；`FAsyncTask`/`new FAPSArcPathTask` 零命中 |
| 圆角内的弧长查询是 O(N²) | `GetPointAtPathDistance :1652-1656` 每次从索引 1 线性扫描；每角调用两次（`:1250-1251`） |
| 输入点数无上限，输出两级上限不一致（192 → 128） | `:1089`、`:946` |
| 点预算耗尽后**尾部角点确定性失去圆角** | `:1485`（`OutPoints` 只增不减） |
| 插件对大量敌人同时重算没有实测数据 | 包内无测试、无 README、无 Config |

---

## 5. UE → Godot 原语映射与单位换算

**单位**：UE 1 uu = 1 cm，Godot 1 单位 = 1 m ⇒ **数值 ÷ 100**。
**轴向**：UE Z-up（水平面 = XY）；Godot Y-up（水平面 = XZ）⇒ `(x, y, z)_UE → (x, z, y)_Godot`，右向量 `(−d.y, d.x, 0)_UE → (−d.z, 0, d.x)_Godot`（现有 `navigation_path.gd:103` 已是这个形式）。

| APS 原语 | Godot 对应 | 适配说明 |
|---|---|---|
| `dtNavMeshQuery::findPath`（`:780`） | `NavigationServer3D.query_path`（`spatial_route_planner.gd:169`） | 已存在；两种 `path_postprocessing` 互换保留（`:161-162`） |
| `findNearestPoly(Extent)`（`:523-574`） | `NavigationServer3D.map_get_closest_point` | Godot 投影**不受 Extent 限制**，必须自己加几何门限：水平位移 ≤ `extent_h`、`|Δy| ≤ extent_v`（现有 `navigation_path.gd:37` 用 0.35 m / 0.5 m） |
| `hasNavmeshLineOfSight`（`:577-641`） | 无直接 API | **一级（便宜）**：沿段采样只做投影误差检查；**二级（重）**：`Query.ground_segment`（身体 + 支撑）。见 P3 |
| NavArea 代价（`:643-672`） | 无概念 | 留 `candidate_cost(point) -> float` 钩子，默认 0；差异写入文档 |
| `GOffsetScales` / `GArcAbsFallbackAmps` | 直接用 | uu → m 换算 |
| `ComputeArcShape` / `ComputeLocalSideSign` / `BaseAmp` | 直接用 | 纯数学 |
| 圆角打分（`:1316`） | 直接用 | 纯数学；`CrossZ` 用 Godot XZ 叉积 |
| corridor / crowd（`:3763-3794`） | 不移植 | 沿用自己的跟随与脱困 |
| 帧预算 / 异步 | **自建可恢复状态机** | APS 无此能力，参考 `combat_spatial_controller.gd:12/155/161` 的 2.2 ms / 700 µs 预算 |

---

## 6. 现状差距

现有「借鉴 APS」的实现只有 `scripts/navigation_path.gd`（116 行）的 `shape()`，与 APS 真实源码逐条对照后，差距如下（全部带行号，均由本轮侦察报告核对）：

| # | 现象 | 代码位置 | 对应 APS 环节 |
|---|---|---|---|
| 1 | **没有波形**：只有一次性固定符号侧偏，无周期摆动 | `navigation_path.gd:92-116`（符号 `:96`） | `ComputeArcShape` Wavy / `ComputeLocalSideSign`（`:2293-2330`） |
| 2 | **圆角只作用于前 16 个拐点**（`i <= 16`），第 17 个之后只保留原角点；侧偏阶段仍遍历全部内部点 | `navigation_path.gd:69`（侧偏遍历见 `:100`） | APS 无此上限（只有输出点预算 192） |
| 3 | **没有重采样阶段** | `shape()` 直接逐点处理 | `BuildArcSamplingPath`（`:907-986`） |
| 4 | **没有绝对宽度回退**；相对缩幅只有 3 档 | `navigation_path.gd:70`、`:97` | `GOffsetScales` 8 档 + `GArcAbsFallbackAmps` 6 档 |
| 5 | **没有整条终检**：逐点接受后没有全路径复检 | `shape()` 返回前 | `ValidatePathOnNavMesh`（`:3336-3344`） |
| 6 | **顺序与文档相反**：先身体验证（`_physical_walk_points`）再成形，文档写成「成形→验证」 | `spatial_route_planner.gd:175-177` | APS 是「基础路径 → 成形 → 逐点验证 → 终检」 |
| 7 | **默认 `lane_offset = 0.0`**，正式配置下侧偏实际未启用 | `data/navigation/steering.json:3` | — |
| 8 | 圆角只有「夹角 > 0.98 就跳过」一个判据，无打分、无事件分类 | `navigation_path.gd:66` | 4.2 的打分模型 |
| 9 | 整条流水线**同步不可中断**，`advance` 单次最高 38.222 ms，远超 2.2 ms 预算 | `spatial_route_planner.gd:127-189`；`combat_spatial_controller.gd:161`；I-064 | APS 同样同步（`FindPath`），但本项目预算更小、代价更高 |
| 10 | `revision` 只有自增、无读取方（死代码） | `navigation_path.gd:6`、`:21` | — |
| 11 | `settings()` 每次返回 `duplicate()`，而 `nav_steering.gd:209` 每次重规划判定都调用一次 | `navigation_path.gd:13` | — |
| 12 | `apply()` 用固定 3 键**整体重建**字典，新增键会被静默丢弃 | `navigation_path.gd:16-20` | — |

---

## 7. 移植目标、非目标与硬约束

**目标**
1. 在 Godot 里复刻 APS 的**路径形状数学**，并保留本项目更强的**身体/支撑/能力**检查（不降级判定标准）。
2. 把形状流水线做成**可配置、可分帧**的独立模块，使 I-064（性能）与 I-066（走停）有可测的修复路径。
3. 形状、跟随、避障三者**分开观察、分开调参**；同一套实现同时服务正式敌人与观察台（禁止复制第二套数值）。
4. 每项改动都能追溯到 APS 源码函数/行号；没有来源的改动明确标为自行设计。

**非目标**
- 不把 UE 二进制或 Recast/Detour 接入 Godot；不替换 `NavigationServer3D` 寻路；不改地图几何与烘焙参数（除发现硬缺陷）。
- 不移植 crowd 跟随、避障力、到达判定、脱困。
- 不为本任务对测试地图做特殊处理；不按地图名/障碍名/坐标分支。
- 不在用户明确说「继续」之前改动正式敌人的导航表现。

**硬约束（项目规则）**
- 共用实现：`nav_steering.gd` / `combat_spatial_controller.gd` / `spatial_route_planner.gd` / `navigation_path.gd` / `spatial_query.gd` 是单一实现，改动会同时影响正式近战、正式远程、原型敌人、观察台与全部验收（`AGENTS.md:77`、侦察报告 §9.2）。
- 新增调参键必须同时改 4 处：`navigation_path.apply` 白名单、`settings()`、`data/navigation/steering.json`、观察台 UI（`navigation_lab.gd:392-431`）；否则静默失效（侦察报告 §9.1-7）。
- 产物一律写项目外 `_artifacts/godot-ruin_star_new/<task>/<run>/{logs,screenshots,reports,tmp}`；测试放 `tests/`；手动探针放 `tools/probes/`；交付前跑 `python -B tools/project_hygiene.py check`。
- 观感/手感是否满意由用户判定，自动通过不等于用户满意。

---

## 8. 阶段化实施计划 P0–P7

每个阶段都给出：改动入口（文件:函数）、验收命令、证据路径、回退方式。**P0–P2 不改变正式敌人表现**；P4 起才会影响手感，P7 才评估正式接入。

### P0 观测与基线（不改行为）
- 入口：`scripts/prototypes/navigation_lab.gd`（绘制与面板）、`tools/probes/navigation_main_scene.gd`。
- 内容：同时绘制**基础网格路径**（`NavigationPathQueryResult3D.path`，`spatial_route_planner.gd:169` 的结果）、**成形路径**（`shape()` 输出）、**实际轨迹**三段；显示流水线分段耗时（导航查询 / `_physical_walk_points` / `shape`）与计数（候选数、缩幅档位命中数、拒绝原因分布、终检失败次数）。
- 验收：`python -B tools/run_probe.py tools/probes/navigation_main_scene.gd --graphics --task aps_port_p0 --args --count=128 --frames=900`；并跑一次导航回归确认行为未变。
- 证据：`_artifacts/godot-ruin_star_new/aps_port_p0/<run>/`（截图 + 报告）。

### P1 抽出形状管线模块（结构改造，行为等价）
- 新增 `scripts/nav_arc_shape.gd`：把 `shape()` 拆成可枚举的阶段 `[fillet, resample, warp, validate, final_gate]`，每阶段产出/消费点列并记录统计；`navigation_path.shape()` 变成薄适配层，参数映射到「能复现当前行为」的一组值（`arc_strength = 0`、`num_midpoints = 3`、`corner_rounding → fillet_scale`、`lane_offset` 原值）。
- 关键约束：**本阶段结束时验收结果必须与 P0 基线一致**（到达数、`path_requests`、报告字段逐项相同），以此证明结构改造没有行为漂移。
- 入口：`scripts/navigation_path.gd:42`、新增 `scripts/nav_arc_shape.gd`。
- 验收：`python -B tools/run_acceptance.py --tests test_navigation_main_scene test_navigation_obstacles --task aps_port_p1 --timeout 240`。
- 回退：`navigation_path.shape()` 保留旧实现分支（用常量或 git 回退），不删代码直到 P2 通过。

### P2 忠实移植圆角与侧偏数学（默认参数保持现状）
- 内容：4.2 的打分模型与五级跳过、4.3 的重采样、4.4 的 `ComputeArcShape` / `ComputeLocalSideSign` / `BaseAmp` / 稀疏形变、4.1 的一级投影验证。
- 单位换算按第 5 节；`GMinPathPointDistance2D = 1.0 uu` 在 Godot 里抬到 **0.05 m**（Godot 导航网格精度与浮点尺度不同，0.01 m 会大量重复点；作为**明确标注的适配改动**）。
- 参数默认值选成「不改变现状」：`arc_strength = 0.0`、`num_midpoints = 3`、`arc_mode = smooth`、`lane_offset = 0.0`。
- 新增纯数学守卫测试 `tests/test_nav_path_shape.gd`：
  - `Smooth(N=1) → sin(πt)`；`Smooth(N=6) → sin(πt)^3.5`；`Wavy(N=3) → sin(πt)·|sin(3πt)|`（取若干 t 采样比对）；
  - 重采样点数 = `min(max3(N+2, ceil(len/4.0)+1, in_num), 128)`；
  - 缩幅链严格枚举为 8 档且单调；
  - 全部候选被拒时输出必须**逐点等于**基准点；
  - 首末端点坐标保持不变。
- 验收：`python -B tools/run_acceptance.py --tests test_nav_path_shape test_navigation_main_scene test_navigation_obstacles --task aps_port_p2 --timeout 240`。

### P3 候选验证与回退链（两级验证 + 绝对宽度 + 终检）
- 内容：把 4.4 的逐点候选做完整——一级（投影 + 采样投影误差，便宜）先筛，二级（`Query.ground_segment`）只对通过一级且不超预算的候选执行；8 档相对缩幅（乘在「弧形 + 车道偏移」整体上）→ 6 档绝对宽度（弧形固定宽度、车道偏移全幅）→ 保留基准点 → 全路径终检（终检用一级验证；二级已逐点做过）。
- 目的：**在保持「整段身体通道」判定标准不降级的前提下**，把昂贵查询的次数压到与现状同量级或更低。
- 入口：`scripts/nav_arc_shape.gd`、`scripts/spatial_query.gd`（如需新增只读的一级验证辅助函数，不改现有函数语义）。
- 验收：扩展 `tests/test_navigation_obstacles.gd` 或新增 `tests/test_nav_shape_fallback.gd`：窄通道里大 `lane_offset` 必须缩幅（断言实际命中档位 ≤ 某档）、断开地面仍不可达、受阻旧路点仍能脱困、无穿墙（沿用现有身体断言）。
- 证据：报告里记录每个用例的候选数、命中档位、一级/二级查询次数。

### P4 接入与跟随策略（消除走停，针对 I-066）
- 内容（**必须按 APS 的「一次请求一次成形」语义对齐**）：
  1. 有已验证路线时**绝不把水平速度清零**；规划期间继续沿保留路线走（`combat_spatial_controller.gd:358` 的闸门与 `nav_steering.raw_ground_velocity` 的零速分支都要改）。
  2. 结果只在「请求时采样的目标点」仍有效时发布；玩家位移超阈值时**丢弃**结果，但**不清零速度**。
  3. 目标重算阈值按「采样点」而不是「当前玩家位置」计算，避免玩家持续移动时每次都判定失效（APS 在请求时读参数、请求后不再自我失效）。
  4. 保留每角色固定车道符号（现有 `navigation_path.gd:95-96` 的 `navigation_identity`），并加**滞后**避免符号抖动。
- 入口：`scripts/nav_steering.gd:170/209/260`、`scripts/combat_spatial_controller.gd:343/358`。
- 新增测试 `tests/test_navigation_moving_target.gd`：目标持续移动（等价玩家走速 5 m/s、冲刺 ×1.7、随机转向、固定种子），断言：
  - 非攻击帧的水平速度为零的比例 ≤ 阈值（阈值由 P0 基线确定，不拍脑袋）；
  - 最长连续零速帧数 ≤ 阈值；
  - 每秒重算次数上限；
  - 稳定保持追击距离区间；
  - 同时覆盖**正式近战控制链**（绑 `attack_pose`，即 `spatial_route_planner.set_attack_goal` 的 40 个接战候选）与纯移动测量体两组。
- 验收：`python -B tools/run_acceptance.py --tests test_navigation_moving_target test_navigation_main_scene test_navigation_obstacles --task aps_port_p4 --timeout 300`。

### P5 分帧与预算（针对 I-064）
- 内容：把 `nav_arc_shape.gd` 做成**可恢复状态机**（阶段游标 + 点游标 + 候选游标），`advance(deadline_usec)` 在预算耗尽时返回并保存现场；`spatial_route_planner.advance` 与 `combat_spatial_controller.process_jobs` 的预算语义不变（2.2 ms / 单任务 ≤ 700 µs），但现在能**在流水线内部**切分。
- 附加：把 `walk_route` 的两次 `postprocessing` 尝试与修复式重试也纳入同一可暂停结构（现状 `:161-188` 全同步）。
- 验收：重跑压力与持续迁移，断言 `last_job_usec` P95 ≤ 预算、单次最大值有上限（用 `test_navigation_stress.gd:162` 已有读数），且到达数与 P3 一致；同时记录「被打断次数」与「跨帧完成率」。
  `python -B tools/run_acceptance.py --tests test_navigation_stress test_navigation_stress_soak --task aps_port_p5 --timeout 1200`

### P6 观测台与调参落盘
- 内容：观察台新增参数（见第 9 节）、模式切换（smooth/wavy）、三段路线绘制与 APS 风格配色（见第 10 节）、失败原因分布面板、「相同种子重播」保持。
- 保存语义沿用现有约定：`另存命名方案` → `data/navigation/presets/<名称>.json`；`将导航参数设为项目默认` → `data/navigation/steering.json`；面板显示「未保存」。
- 验收：`python -B tools/run_probe.py tools/probes/navigation_main_scene.gd --graphics --task aps_port_p6 --args --count=128 --frames=900` + 截图检查 + `python -B tools/project_hygiene.py check`。

### P7 正式接入评估（需用户明确同意）
- 前提：P4/P5 的持续移动与性能证据齐备。
- 内容：按敌人数据（不是全局）下发形状参数（近战/远程/大型体各异），跑 8 项回归 + 压力，量化战斗内帧率与视觉观感，交用户试玩。
- 明确不自动执行。

---

## 9. 参数与调参入口设计

新增键全部落在 `data/navigation/steering.json`，并在 `navigation_path.apply()` 白名单、观察台 UI 同步登记（否则静默失效）。

| 键 | 单位/范围 | 默认（保持现状） | APS 来源 | 作用 |
|---|---|---|---|---|
| `arc_strength` | −3～3 | `0.0` | `:2959-2963` | 弯曲强度与方向（正=右侧）；`|S| < 0.1` 关闭 |
| `arc_num_midpoints` | 1～6（整数） | `3` | `:2287`、`:2295` | Smooth 的包络指数 / Wavy 的波峰数 |
| `arc_mode` | `smooth`/`wavy` | `smooth` | `:2285`、`:2315` | 单侧鼓包 / 蛇形交替 |
| `arc_min_distance` | 米，0～50 | `3.0` | `:462-466`（300 uu） | 低于此水平距离不做弧形 |
| `lane_offset` | 米，−3～3 | `0.0` | 圆角/机动区共同消费 | 车道偏移；**绝对值 ≥ 1.8 m 才触发侧路注入**（`:47`，P6 才实现） |
| `corner_rounding` | 米，0～2 | `0.8` | 现有键，映射到 `DesiredWidth` 上限 | 保留兼容，不删 |
| `goal_replan_distance` | 米，0.2～3 | `0.8` | 现有键 | 目标累计位移阈值 |
| `shape_max_points` | 整数，16～192 | `128` | `:946`、`:1089` | 重采样/圆角输出点上限 |
| `arc_resample_length` | 米，0.5～10 | `4.0` | `:944`（400 uu） | 弧长重采样目标段长 |
| `arc_sparse_warp` | bool | `true` | `:2984` | 点密集时跳过奇数点 |
| `shape_final_gate` | bool | `true` | `:3336-3344` | 是否启用全路径终检（关闭仅用于对照实验） |

**移植时明确改动的常数（必须写进文档与注释）**
- `GMinPathPointDistance2D`：1.0 uu → **0.05 m**（Godot 尺度与网格精度不同）。
- 所有 uu 常量按 ÷100 换算后再四舍五入到厘米级。
- `Extent` 门限：APS 由查询半径/高度给出；本项目用 `Query.dimensions(body)` 的 `radius`/`half_height` + 既有余量（`navigation_path.gd:37` 的 0.35 m / 0.5 m 作为起点）。

---

## 10. 观测台与调试信息设计

直接采用 APS 的调试信息结构（报告 `research_nav_crowd_debug.md` §19–§24），映射到 Godot 的 `ImmediateMesh`/`Node3D` 绘制：

| APS 元素 | APS 出处 | Godot 落点 |
|---|---|---|
| 两类图元：线段、点（各上限 4096，绝对过期时间） | `APS_DebugOverlaySubsystem` | 观察台内两个数组 + 过期清理 |
| 12 个语义槽 | `APS_DebugColorUtils` | 基础路径 / 成形路径 / 实际轨迹 / 候选锚点 / 候选峰点 / 失败锚点 / 失败路点 / 失败连线 / 已注入锚点 / 已注入峰点 / 侧向路点 / 注入路线 |
| 8 套调色板 + `(Owner + 首点 + 末点)` 的 20 单位网格哈希取色 | 同上 | 每个测量体/敌人固定颜色，跨帧稳定、多体可区分 |
| 语义色规律：红=失败、蓝紫=候选、青蓝=已注入、品红=侧向路点、橙=注入路线、绿=最终 | 同上 | 沿用 |
| 失败原因枚举文本（`no-navmesh-poly`/`area-cost`/`too-long`/`local-path-fail`/`segment-validation`/`route-rejected`） | `LowLevelArc` 各处 `bDbg` | 面板按原因计数，报告写入 `reports/*.json` |
| KPI 汇总行（zones/candidates/attempted/injected/failed） | `:3751-3761` | 报告新增字段：候选数、缩幅命中档位、一级/二级查询次数、终检失败次数 |
| APS 的绘制**无深度剔除**（屏幕空间画线） | `SAPS_DebugOverlayWidget` | Godot 侧按需选择是否 `no_depth_test`，默认保留遮挡以判断真实空间关系 |

---

## 11. 验收矩阵与新增测试

| 用例 | 现有/新增 | 断言（不放宽判定） | 命令 |
|---|---|---|---|
| 主场景三种子 | 现有 `test_navigation_main_scene.gd` | 连通区全部投放且到达；0.2 m 缓降允许、0.65 m 断落拒绝 | `--tests test_navigation_main_scene` |
| 独立障碍 16 组 + 移动目标 + 断路 | 现有 `test_navigation_obstacles.gd` | 到达、`path_requests < 24`、受阻旧路点脱困、断路不可达不掉落、接触余量三向 | `--tests test_navigation_obstacles` |
| 全区域/多体压力 | 现有 `test_navigation_stress.gd` / `_soak` | 64/64 分区、每轮到达数、不得失去支撑、`last_job_usec` 分位 | `--tests test_navigation_stress test_navigation_stress_soak` |
| 形状数学 | **新增** `tests/test_nav_path_shape.gd` | 包络公式、重采样点数公式、缩幅链枚举、全拒时逐点等于基准、端点不变 | 见 P2 |
| 回退链 | **新增** `tests/test_nav_shape_fallback.gd` | 窄通道缩幅命中档位、终检失败回退、不可达不变 | 见 P3 |
| 持续移动目标 + 正式近战链 | **新增** `tests/test_navigation_moving_target.gd` | 零速比例/最长零速帧/每秒重算上限/追击距离区间；含 `attack_pose` 组与纯移动组 | 见 P4 |
| 图形观察 | 现有探针 + 观察台 | 三段路线可见、面板可读、截图留档 | `tools/probes/navigation_main_scene.gd --graphics` |

**不可放宽**：身体通道、真实支撑、坡度、落差、能力进出口、断路不可达；不得为了到达率降低这些判定。

---

## 12. PTC 模式执行指引

### 12.1 PTC 是什么（本机核实的版本）

DSH 有三套 agent 预设：`minimal` / `ptc` / `standard`（打包于 `resources/app.asar` 的 `dsh-web-app/presets/{minimal,ptc,standard}.patch.yml`）。**PTC = Programmatic Tool Calling**：模型不再逐个调用工具，而是拿到一个 `run_code` 工具——写一段 **TypeScript（async 函数体，允许顶层 `await`/`return`）**，通过 `await tools.<name>(args)` 调用宿主提供的工具，程序在一个**全新的受管 Node 进程**里执行（`@deepseek-ai/dsh-ptc-runtime-node`），只有 `print`/`return` 的内容成为程序输出，宿主按调用会话的文件策略约束程序；嵌套的每次工具调用会单独记录，但进入模型历史的只有外层结果。

### 12.2 怎么开

1. **首选**：在 GUI 里选择 PTC 预设开始会话（预设选择入口的界面文案未核实，**以实际界面为准**）。
2. **或者**改 profile 的预设注册表（当前是 `standard`）：
   文件 `C:\Users\ZXG\.dsh\profiles\desktop\cordis.patch.yml`，把

   ```yaml
   - id: agent-preset-registry
     name: "@deepseek-ai/dsh-agent-preset-registry"
     config:
       default: standard
       selectedDefault: standard
   ```

   的 `default` / `selectedDefault` 改为 `ptc`，重启 DSH。
3. **验证已生效**：会话里只应出现 `run_code`（加工作流类）这一个大工具，而不是逐个工具；`run_code` 的 `code` 参数说明里会有「body of an async TypeScript function」「Call tools as `await tools.name(args)`」。

### 12.3 对执行本方案的四条硬影响

1. **run 之间没有状态**：每次 `run_code` 都是新进程。所以：计划是**文件**（`docs/features/APS路径算法移植实现文档.plan.json`，只读事实源），进度也是**文件**（`_artifacts/godot-ruin_star_new/aps_port/state.json`，每步结束后原子写回）。
2. **一次程序多做几件事**：同一步的「读计划 → 改文件 → 跑验收 → 解析报告 → 写状态」应在一个程序里完成，减少 run 次数与上下文往返。
3. **输出必须自净**：程序只 `return` 结构化的短结果（例如 `{step, ok, evidence, counters}`），不要把整份报告或大段源码返回；详细内容写进产物文件。
4. **每步自带断言**：程序内先用读取/命令校验（文件存在、关键字符串命中、验收 `summary.json` 的字段、命令退出码），再写状态；失败就把 `{ok:false, reason, evidence}` 返回，不要带着错误继续。

### 12.4 推荐的第一个程序（P0 前置检查，可直接改路径使用）

```ts
// description: "Verify APS port plan prerequisites"
const planPath = "godot-ruin_star_new/docs/features/APS路径算法移植实现文档.plan.json";
const plan = JSON.parse(await tools.read_file({ path: planPath }));   // 工具名以会话 system prompt 的声明为准
const required = [
  "godot-ruin_star_new/scripts/navigation_path.gd",
  "godot-ruin_star_new/scripts/nav_steering.gd",
  "godot-ruin_star_new/scripts/spatial_route_planner.gd",
  "godot-ruin_star_new/scripts/spatial_query.gd",
  "godot-ruin_star_new/scripts/combat_spatial_controller.gd",
  "godot-ruin_star_new/data/navigation/steering.json",
];
const missing = [];
for (const p of required) {
  const r = await tools.read_file({ path: p });   // 不存在时按工具约定返回错误对象
  if (!r || r.error) missing.push(p);
}
console.log(`plan steps: ${plan.steps.length}`);
return { ok: missing.length === 0, missing, next: plan.steps[0]?.id ?? null };
```

### 12.5 每步的固定循环（建议写成一个程序模板）

```
读 state.json → 取第一个 status != "done" 且未被 gate 阻塞的 step
→ 按 plan.steps[i].write_scopes 改文件（同一步内只碰这些路径）
→ 跑 plan.steps[i].commands，收集退出码与报告摘要
→ 断言 plan.steps[i].gate.assertions（字段存在、数值区间、字符串命中）
→ 写回 state.json（含 evidence 路径、时间、命令、结果）
→ return 短结果
```

### 12.6 分工建议

- P0–P3（形状数学与回退链）**适合 PTC**：文件面小（`nav_arc_shape.gd` + `navigation_path.gd` + 两个新测试），断言是纯数学，可高度并行地在一个程序里跑多组数值比对。
- P4–P5（跟随策略与分帧）**适合普通会话 + 人工观察**：涉及手感与真实运行，需要看轨迹、看截图、可能多轮调整。
- P7（正式接入）**必须由用户明确同意**后开始，不适合自动连续执行。

---

## 13. 风险与未验证项

**未验证（本轮没有做）**
- 未编译 UE、未运行插件、未观测 APS 的真实轨迹与性能；所有 APS 结论都是静态源码结论。
- 未在 Godot 里实现任何新算法；第 6 节的差距是代码核对结论，不是运行结论。
- 第 12 节 PTC 预设的**界面文案与绑定名**未核实（预设文件名与 `run_code` 契约已核实）。
- 插件侧未确认项（来自研究报告）：`Extent` 的来源函数 `GetModifiedQueryExtent` 在插件源码内检索不到声明；`aps.Arc.MinDistance` 可能由包外注册；UE 对 `Result.Path` 为空但 `Success` 的处理；`PathCorridorCost` 全 0 对 DetourCrowd 的影响。

**移植风险（有代码依据）**
1. **验证强度差异**：APS 的段验证只是 navmesh 表面 LOS，**不懂胶囊半径与净空**；本项目现有判定更严格。移植时必须保留本项目标准，否则会出现「APS 能过、本项目不能过」的候选——这是**预期行为**，不是 bug。
2. **两级上限不一致会抹平圆角**：APS 里 192 → 128 的等分重采样不按曲率加密。移植时要么把上限做成参数并在 P6 观察，要么按曲率自适应（后者属自行设计，需标注）。
3. **终检回退会连圆角一起丢**：长路径上「全路径终检失败」= 完全回退到未加工路径。本项目要把这个事件**计数并出报告**，否则很难解释「某条路突然变直」。
4. **性能风险**：圆角打分的邻域支持与弧长查询在原实现里是 O(N²)；移植时用前缀和/游标消除，不要把 O(N²) 带进来。
5. **走停修复的副作用**：不再清零速度可能让敌人在规划期间沿旧路线走进已失效区域。必须有「旧路线剩余长度 < 阈值时降速」与「失效即尽快重算」的兜底，且这属于**自行设计**，要在 P4 用持续移动测试证明。
6. **默认参数即现状**：P2 若默认不是 `arc_strength = 0`，会立刻改变正式敌人表现——这是不允许的（用户尚未同意接入）。

---

## 14. 源码证据索引

**本轮研究报告（项目外产物，逐行核对，含全部行号与常量表）**

| 报告 | 覆盖 | 报告路径 |
|---|---|---|
| LowLevelArc 1/3 | `APS_PathMode_LowLevelArc.cpp:1-1709`（投影、LOS、基线路径、圆角、重采样、工具函数） | `_artifacts/Adaptive64768b7cb9a5V14/aps_ptc_port/20261011_121500_fb1548bc/reports/research_lowlevelarc_1.md` |
| LowLevelArc 2/3 | `:1701-3850`（机动区、侧路注入、弧形形变、主入口） | 同目录 `research_lowlevelarc_2.md` |
| LowLevelArc 尾部补齐 | `:3300-3850`（主入口逐步、参数拉取、Crowd 走廊分支） | 同目录 `research_lowlevelarc_tail.md` |
| 路径模式层与基础层 | `APSArc`(672) / `AsyncArcPathTask`(418) / `LowLevelBase`(400) / `LowLevelTiles`(382) + 注册分派 | 同目录 `research_pathmodes.md` |
| 导航/群体/Detour/调试 | `NavigationData` / `CrowdFollowingComponent` / `DetourNode` / 调试与可视化 / 模块启动 | 同目录 `research_nav_crowd_debug.md` |
| Godot 现状侦察 | 调用链、接口清单、配置、扩展点、测试命令、分帧位置 | 同目录 `recon_godot_nav.md` |

**关键锚点速查（APS 侧）**

| 主题 | 文件:行号 |
|---|---|
| 默认模式覆写 | `APS_NavigationData.cpp:35` |
| 注册与分派 | `APS_NavigationData.cpp:32`、`:89-108` |
| 主入口 | `LowLevelArc.cpp:3452-3834` |
| 管线注释 | `LowLevelArc.cpp:2338-2339` |
| 形状函数 | `LowLevelArc.cpp:2273-2330` |
| 幅度公式 | `LowLevelArc.cpp:2959-2963` |
| 缩幅档位 | `LowLevelArc.cpp:39`、候选循环 `:3119-3158`、绝对档 `:3232-3319` |
| 终检回退 | `LowLevelArc.cpp:3336-3344` |
| 圆角打分 | `LowLevelArc.cpp:1312-1326` |
| 圆角几何 | `LowLevelArc.cpp:1395-1413`、`:1477-1506` |
| 重采样 | `LowLevelArc.cpp:907-986` |
| 侧路常量 | `LowLevelArc.cpp:47-58` |
| 侧路注入 | `LowLevelArc.cpp:2345-2859` |
| 死代码异步任务 | `APS_AsyncArcPathTask.cpp`（全树无调度点） |
| 跟随层（不移植） | `APS_CrowdFollowingComponent.cpp:130-162` |
| 调试配色 | `Private/Debug/APS_DebugColorUtils.cpp` |
| 日志开关 | `APS_NavLogs.cpp:9-16` |

**关键锚点速查（本项目侧）**

| 主题 | 文件:行号 |
|---|---|
| 形状后处理（唯一汇合点） | `scripts/navigation_path.gd:42`（圆角 `:57-91`、侧偏 `:92-116`、16 角上限 `:69`） |
| 基础路径与修复重试 | `scripts/spatial_route_planner.gd:127-189`（postprocessing 互换 `:161-162`、`_physical_walk_points:191`） |
| 逐帧跟随与脱困 | `scripts/nav_steering.gd:170`、`:260`、状态机 `:332-439`、接触偏转 `:454-480` |
| 空间控制器与预算 | `scripts/combat_spatial_controller.gd:12`、`:155`、`:161`、`:343`、`:358`、`_recover_walk:681` |
| 身体/支撑/通道查询 | `scripts/spatial_query.gd:283-344`（采样 0.45/0.15 m 在 `:286`） |
| 共用配置 | `data/navigation/steering.json`（3 键）、`data/game_config.json` 的 `navigation` 段 |
| 观察台 | `scripts/prototypes/navigation_lab.gd:392-441`、`scripts/prototypes/navigation_test_actor.gd` |
| 测试与验收入口 | `tools/run_acceptance.py:214-222`、`tools/run_probe.py`、`tools/artifact_paths.py:26-43` |

---

## 15. 实施记录（2026-10-11 下午轮）

本节只记录已经发生的事实：改了什么、跑出什么数字、哪些没做。观感/手感是否满意仍由用户判定。

### 15.1 落地范围

| 步骤 | 状态 | 事实 |
|---|---|---|
| P0 观测与基线 | 完成 | 改造前主场景三种子与独立障碍验收通过，作为对照基线 |
| P1 抽出形状管线模块 | 完成 | `shape()` 拆成 fillet → resample → warp → validate → final_gate；当时用 `shape_model=legacy` 分支做对照运行，证明结构改造没有行为漂移。P2 通过后该对照分支已按计划删除（不再有生产调用点），证据保留在产物目录 |
| P2 圆角与侧偏数学移植 | 完成 | 打分模型、窗口双锚、乘性置信、事件分类、二次 Bézier、弧长重采样、`ComputeArcShape`/`ComputeLocalSideSign`/`BaseAmp`、稀疏形变全部落地；纯数学守卫测试通过 |
| P3 两级验证与回退链 | 完成 | 一级投影筛选 + 二级 `ground_segment` 完整身体通道；8 档相对缩幅 → 6 档绝对宽度 → 保留基准点 → 全路径终检；真实几何回退测试通过 |
| P4 接入与跟随策略 | 完成（范围收窄，见 15.4） | 保留路线的时效语义：请求时采样的结果不再因目标继续移动而作废，并对「目标位移触发重算」追加 `replan_interval` 限速 |
| P5 分帧与预算（I-064） | **未做** | 形状流水线仍是同步调用；`advance` 单次阻塞未拆 |
| P6 观测台与调参落盘 | 完成（参数面板与三段路线） | 新增 8 个控件、三段路线绘制、成形统计行；预设与「设为默认」沿用原约定 |
| P7 正式接入评估 | **未开工** | 需用户明确同意，未自动开始 |

### 15.2 代码与配置入口

| 文件 | 改动 |
|---|---|
| [nav_arc_shape.gd](../../scripts/nav_arc_shape.gd) | **新增**。APS 流水线的 Godot 实现，常量与函数都带 APS 源文件行号 |
| [navigation_path.gd](../../scripts/navigation_path.gd) | 变成薄适配层：只做参数白名单合并、范围夹取与调用；`settings()` 不再每次复制（旧 I-070），`apply()` 改为「默认值 + 白名单合并」不再丢弃新键（旧 I-071）；P2 通过后删除了 P1 的 `shape_model` 对照分支（已无生产调用点） |
| [spatial_route_planner.gd](../../scripts/spatial_route_planner.gd) | walk 段新增 `base` 字段：保存成形前的真实落脚点列，供观察台画基础网格路径 |
| [combat_spatial_controller.gd](../../scripts/combat_spatial_controller.gd) | P4：`_publish_route` 不再因目标移动作废整条结果；目标位移触发的重算追加 `replan_interval` 限速。开关 `hold_route_enabled` 供同一场景做改造前/后对照 |
| [navigation_lab.gd](../../scripts/prototypes/navigation_lab.gd) | 新增 arc_strength / arc_num_midpoints / arc_min_distance / arc_resample_length / shape_max_points / arc_mode / arc_sparse_warp / shape_final_gate 八个控件；三段路线配色；成形统计行 |
| [steering.json](../../data/navigation/steering.json) | 从 3 键扩到 11 键（默认值全部保持现状） |
| [test_nav_path_shape.gd](../../tests/test_nav_path_shape.gd) | **新增**。包络公式、重采样点数公式、缩幅链枚举、幅度公式、侧符号、端点查找 |
| [test_nav_shape_fallback.gd](../../tests/test_nav_shape_fallback.gd) | **新增**。真实几何：无导航面/全部候选被拒 → 逐点等于基准点；弧形被接受且命中档位 ≤ 1.0；断路终检失败 → 回到基准路径 |
| [test_navigation_moving_target.gd](../../tests/test_navigation_moving_target.gd) | **新增**。持续移动目标 × 纯移动组/接战链 × P4 开关，四相位同种子对照 |

### 15.3 与 APS 的刻意差异（移植适配，全部写在代码注释里）

1. **判定不放宽**：APS 的段验证只是 navmesh 表面 LOS，不懂胶囊半径与净空；这里一级用投影门限（水平 ≤ 0.35 m、垂直 ≤ 0.5 m），二级一律用本项目 `Query.ground_segment` 的完整身体通道。
2. `GMinPathPointDistance2D` 1.0 uu → **0.05 m**（Godot 网格精度与浮点尺度不同）。
3. **宽度来源不同**：APS 用 `|LaneOffset|` 同时驱动圆角与弧宽；本项目保留既有语义 —— `corner_rounding` 决定圆角切除距离、`lane_offset` 决定车道偏移。故 `BASE_FILLET_SCALE`/`STRENGTH_FILLET_SCALE` 由 APS 的 0.6/0.4 适配为 1.0/0.0，`MAX_SEGMENT_PORTION` 由 0.45 适配为 0.40（与移植前上限一致）。
4. **打分阈值默认放宽**：APS 的 `StrongCornerThreshold 0.35`、`MinWindowStrength 0.20`、噪声局部门槛 0.35 在默认配置下适配为 **0.02**，以保持移植前「相邻段夹角 > 0.98 才跳过圆角」的接受面；`MIN_FILLET_DISTANCE` 由 4 uu 改为 0.10 m 同理。把这几个阈值设回 APS 原值即得 APS 语义。
5. **角点数上限**：APS 只有 192 点预算，没有角点数上限；这里额外限制 `MAX_FILLET_CORNERS = 64`，避免一次重算内的 `ground_segment` 次数失控。移植前的 `i <= 16` 上限（旧 I-067）已删除。
6. **弧长查询**：APS 的 `GetPointAtPathDistance` 每次从索引 1 线性扫描（O(N²)）；这里用单调游标。

### 15.4 P4 的范围收窄（A/B 实测决定）

先按方案原文实现了四条（不清零速度、过期结果不作废、阈值按采样点、车道符号滞后）。在 [test_navigation_moving_target.gd](../../tests/test_navigation_moving_target.gd) 的四相位对照里，**「直行风格不清空保留路线」与「规划期间按上一步方向降速保留」让接战链的零速比例与最长停顿变差**（0.0398 → 0.0764、183 → 195 帧），因此按门禁回退这两条，只保留经过实测改善的部分。

改造前/后（同一场景、同一种子、同一目标轨迹；改造前 = `hold_route_enabled = false`）：

| 相位 | 真正在追的个体 | 零速比例 | 最长连续零速 | 每角色每秒重算 | 与目标平均距离 m | 规划任务 p50/p95 µs |
|---|---:|---:|---:|---:|---:|---:|
| 改造前 · 纯移动 | 11/24 | 0.393 | 497 | 0.083 | 50.27 | 8463 / 17977 |
| 改造前 · 接战链 | 5/24 | 0.414 | 498 | 0.038 | 47.43 | 7232 / 32835 |
| 改造后 · 纯移动 | 24/24 | **0.105** | **151** | 1.190 | 38.80 | 2290 / 13659 |
| 改造后 · 接战链 | 24/24 | **0.088** | **221** | 0.077 | 38.84 | 2462 / 17425 |

统计口径：预热 300 帧不计；只统计预热后累计位移 > 20 m 的个体（否则投放后就被地形挡住的个体会淹没信号）。

### 15.5 验收证据

| 步骤 | 命令 | 结果 |
|---|---|---|
| P0 基线 | `run_acceptance.py --tests test_navigation_main_scene test_navigation_obstacles --task aps_port_p0` | 通过；[产物](../../../_artifacts/godot-ruin_star_new/aps_port_p0/20261011_124719_a42a9870/reports/summary.md) |
| P1 结构等价 | 同上，当时的 `shape_model=legacy` 对照分支（P2 通过后已删除） | 障碍用例逐项一致，主场景仅帧数 ±1 / 位移 ≤ 0.013 m；[产物](../../../_artifacts/godot-ruin_star_new/aps_port_p1_legacy/20261011_125249_a6c373d3/reports/summary.md)、[重复运行](../../../_artifacts/godot-ruin_star_new/aps_port_p1_legacy_b/20261011_125338_0f1d53a5/reports/summary.md) |
| P2/P3 | `run_acceptance.py --tests test_nav_path_shape test_navigation_main_scene test_navigation_obstacles --task aps_port_p2b` | 全部通过；[产物](../../../_artifacts/godot-ruin_star_new/aps_port_p2b/20261011_125539_22e8620c/reports/summary.md) |
| P3 回退链 | `run_acceptance.py --tests test_nav_shape_fallback --task aps_port_p3c` | 通过；[回退链报告](../../../_artifacts/godot-ruin_star_new/aps_port_p3c/20261011_125844_79f06824/reports/test_nav_shape_fallback.json) |
| P4 持续移动 | `run_acceptance.py --tests test_navigation_moving_target --task aps_port_p4g` | 通过；[四相位原始数据](../../../_artifacts/godot-ruin_star_new/aps_port_p4g/20261011_130825_c8688ad7/reports/test_navigation_moving_target.json) |
| P6 图形观察 | `run_probe.py tools/probes/navigation_main_scene.gd --graphics --task aps_port_p6 --args --count=128 --frames=900` | 通过；[截图](../../../_artifacts/godot-ruin_star_new/aps_port_p6/20261011_131351_5528d28b/screenshots/navigation_top_view.png)（1920×1080、128 个体，参数面板 11 项可读，蓝/绿/彩三段路线可见） |
| 八项回归 + 新测试 | `run_acceptance.py --tests test_navigation_main_scene test_navigation_obstacles test_combat_spatial_policy test_combat_spatial_navigation test_combat_spatial_capabilities test_combat_spatial_attacks test_enemy_deployment test_sanctum_layout test_nav_path_shape test_nav_shape_fallback --task aps_port_regression` | 全部通过；[产物](../../../_artifacts/godot-ruin_star_new/aps_port_regression/20261011_131454_f5d06a8e/reports/summary.md) |
| 交付验收（最终代码） | `run_acceptance.py --tests test_nav_path_shape test_nav_shape_fallback test_navigation_obstacles test_navigation_main_scene test_navigation_moving_target --task aps_port_delivery` | 全部通过；[产物](../../../_artifacts/godot-ruin_star_new/aps_port_delivery/20261011_131931_edf4336b/reports/summary.md)。本次 A/B：对照 纯移动/接战链 零速 0.4406/0.4147、最长停顿 878/499 帧、在追个体 12/6；保留 纯移动/接战链 零速 0.2282/0.0891、最长停顿 273/172 帧、在追个体 24/24 |

> 独立障碍的 `corner / angle=0.00 / spatial=false` 用例在 10 次运行中出现 1 次未到达（累计 65.19 m、`path_requests` 0、状态 approach）；该用例走纯 NavSteering 原生跟随，不经过本轮形状流水线，已按事实登记 I-073，未定位根因。

**同一配置重复运行也不是逐位确定的**：两次相同代码的运行会相差 1–2 个物理帧与毫米级位移（P1 的两次对照运行已证明），所以门禁按「严格字段（到达数、path_requests、状态、恢复计数）一致 + 位移/帧数容差」判定，而不是逐字节比较。

**默认配置下的残留差异**：主场景三种子里有两个个体累计位移相差 ≤ 0.272 m（约 0.5%），到达数、path_requests、状态完全一致。差异来自删除了旧 `i <= 16` 圆角上限这一项有意的移植修正（旧 I-067）。独立障碍用例（`corner_rounding=2.0, lane_offset=1.0` 的最大成形配置）形状差异更大（最大约 4 m 累计位移），因为原有的「整条路线等量侧移」被 APS 的「按转角强度加权的局部车道偏移」替换；16 组用例全部仍然到达、`path_requests` 不增。

### 15.6 未完成与风险

- **P5（I-064）未做**：形状流水线仍是同步调用，`advance` 里的整段物理通道查询仍不能内部暂停；本轮未新增分帧状态机，也没有改动 2.2 ms 帧预算语义。P4 的限速只把规划队列压力降下来（任务 p50 从 8.5 ms 降到 2.3 ms），不等于单次阻塞已解决。
- **P7 未开工**：按正式敌人数据下发形状参数需要用户明确同意。
- **APS 侧路注入（原文档 4.5 节）未实现**：需要成倍重查 A*，原计划排在 P6 之后且默认关闭；本轮只实现到「逐点候选 + 回退链」。
- **绝对宽度档（6 档）在本项目参数下几乎打不到**：只有 `BaseAmp > 6.4 m`（即 `min_relative > 0.8 m`）时才有候选，纯数学测试只能覆盖表与顺序；真实命中留待后续用例。
- 观感与手感由用户判定；自动通过只代表上述用例通过。

### 15.7 追加轮：WASD 连续移动目标与动态改线

- **观察台**：新增 WASD 连续控制目标（Shift 冲刺 ×1.7）、「目标速度」滑杆（默认 3.2 m/s）与开关；目标按真实地面逐物理帧推进，前方无立足点时不动。
- **动态改线**：在规划器已证明为「直行」的路段上，最后一段的瞄准点从「规划时刻的落点」连续切换为「当前目标」（每 0.08 秒重估 `NavSteering.live_direct_ok` 的 0.3 米身体探测，带 75° 容差角）。绕行/跨越段仍严格按路点走。
- **实测（[test_navigation_live_aim.gd](../../tests/test_navigation_live_aim.gd)，单测量体追 5 m/s 折线目标）**：速度方向与目标方向平均夹角 **0.259° → 0.003°**，末距 1.11 m → 1.08 m；折线目标下的平均追击距离波动大，只记录不判定。
- **为什么限定直行段**：不限定版本让独立障碍回归在 4 次运行里失败 2 次（`no_capability_route`、贴墙蹭行）；限定后同一回归连续 3 次通过。
- 验证：[WASD + 动态改线回归](../../../_artifacts/godot-ruin_star_new/aps_wasd/20261011_134931_f96fdac4/reports/summary.md)（主场景、持续移动、空间导航/策略/能力/攻击全部通过）、[观察台截图](../../../_artifacts/godot-ruin_star_new/aps_wasd_preview/20261011_135148_8d7b0891/screenshots/navigation_top_view.png)。

