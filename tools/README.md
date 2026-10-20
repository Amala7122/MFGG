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

自动验收与 `run_probe.py --graphics` 均隔离鼠标和窗口焦点：启动器给子进程设置 `RUIN_STAR_AUTOMATION=1`，隔离工程从窗口创建前启用 `no_focus` 并关闭置顶。游戏通过 `MouseControl.mode` 记录瞄准、暂停与面板恢复请求；自动运行时真实系统鼠标始终可见且不受限。子引擎继承该标记。不要通过直接开原工程运行窗口替代统一入口。

手动试玩继续从正常编辑器启动，不设置自动运行标记。手动录像也使用这一入口；自动窗口不接管键鼠。鼠标隔离回归：`python -B tools/run_acceptance.py --tests test_mouse_control --graphics --task automation_mouse`。它同时检查真实图形窗口模式、捕获/限制请求、暂停恢复、代码绕过，以及无头子进程中未设标记时读回原生 Input。无头引擎忽略物理捕获，不能据此认定真人鼠标捕获已验收。

需要 Python 3.10+：

```powershell
python -B tools/run_acceptance.py
python -B tools/run_acceptance.py --suite full
python -B tools/run_acceptance.py --graphics --tests test_ground_juice test_cloud_shadow_rendering
```

`--task` 指定任务名，`--output` 指定项目外父目录，`--godot` 指定引擎，`--timeout` 指定单项秒数上限。启动前检查目录规范。验收创建隔离工程和存档、关闭副本编辑器/MCP 插件，不读取原游戏成绩或修改原游戏方案。截图和日志通过 `--artifact-dir` 汇入同一次运行，副本位于 `tmp/project/`。

Windows 图形自动运行在创建窗口前禁用焦点／置顶，并由 `automation_windows.py` 将本次测试及子进程首次显示的窗口放到用户工作窗口后面。仅作首次层级放置，不反复争夺焦点、不最小化渲染窗口；`summary.json` 的 `background_windows` 保留实际放置及后台顺序证据。编辑器正常手动运行不经过此守卫。

执行器检查 stdout、stderr、引擎日志；任何脚本/资源 ERROR、非零退出、超时、启动失败或缺失日志都使检查失败。WARNING 保留。每轮真实引擎自检故意注入错误，确认门槛生效。

## 手动诊断与截图

```powershell
python -B tools/run_probe.py tools/probes/engine_capability_probe.gd --task engine_probe
python -B tools/run_probe.py tools/probes/capture_post_process.gd --graphics --task post_process
python -B tools/run_probe.py tools/probes/cloud_field_capture.gd --graphics --task clouds
```

诊断入口同样使用隔离工程、独立日志和报告。脚本参数放最后的 `--args` 后，如 `--args --baseline-snapshot`。截图需图形环境；性能比较保留相同引擎、设备、窗口和运行条件。

主场景纯导航俯视截图与测量：`python -B tools/run_probe.py tools/probes/navigation_main_scene.gd --graphics --task navigation_preview --args --count=128 --frames=900`。数量参数启用全区域投放，固定种子测量体共用正式导航，输出真实位置、停滞、路线与画面；[功能入口与保存方式](../docs/features/敌人导航与俯视观察台.md)。`navigation_route_diagnosis.gd` 保留基线中 N02 / N03 / N09 的实际身体通道诊断；`navigation_stress_diagnosis.gd` 对完整 8×8 取样逐点诊断，不按已知失败坐标选择。

正式第三人称相机的敌人视觉密度对照：`python -B tools/run_probe.py tools/probes/horde_density_capture.gd --graphics --task horde_density_capture`。在隔离工程中使用正式圣所、正式相机和图鉴外观，固定拍摄 18/32/48/64/96/128 个画面内敌人；只判断「海量」观感，不作为战斗性能结论。

正式单人战斗链的固定敌群性能对照：`python -B tools/run_probe.py tools/probes/horde_performance_benchmark.gd --graphics --task horde_performance_100 --args --count=100 --warmup=300 --frames=900 --seed=64768`。探针关闭自动波次并用正式动态投放固定人口，固定正午晴天，保留模型、动画、CharacterBody3D、导航、攻击与特效；玩家静止，玩家与敌人只免伤，不禁用战斗逻辑。先以 `--count=18` 独立运行同条件基线，再与 100 只比较；报告包含真实墙钟帧耗、引擎 process/physics 监视器、绘制量、视锥内数量、导航队列和个体移动情况。若测量中有敌人意外退场，报告仍保留，但运行判失败，不能把缩水后帧率当作固定人口成绩。

同一探针加 `--native-paths`，只在隔离副本中用 [horde_native_steering.gd](probes/horde_native_steering.gd) 替换正式导航控制链，保留全部真实角色的移动/战斗/外观。继续加 `--no-attacks`、`--no-animation`、`--no-visuals` 做分层消融。这些开关只定位成本，关闭功能的成绩不代表产品达标；原生对照也未实现楼层识别、局部避让、能力跨越与完整防坠落。本入口默认固定模拟步进，墙钟帧耗可作相同条件比较，实时游玩另验。分辨率读取以窗口与保存图像为准，`viewport` 为逻辑画布，纹理尺寸接口可能存在 I-098 的放大误报。

在上述消融组继续加 `--bare-movement`，会禁用敌人自身的行为回调，用独立群体移动循环驱动相同的 100 个正式身体，分别记录整个循环与 `move_and_slide()` 的直接耗时；用于区分实体碰撞与高层框架成本。此组不执行完整玩法，静止目标汇聚后可能无需再查询路径，不能据此宣布完整敌人达标。

敌人寻路成本拆分：`python -B tools/nav_cost_profile.py --ui=0 --ring=0`。在项目外的隔离副本里注入计时包装（项目内 `scripts/` 一字不改），跑 `probes/navigation_cost_audit.gd`，再把指标按 `search` / `validation` / `shaping` / `planning` / `physics_move` 等分桶写 `reports/nav_cost_buckets.md`。用于判断降低寻路开销应先动哪一层；最高频的三个纯叶子函数只计次不计时，其余仍带 enter/leave 开销，因此绝对耗时不是帧率口径，帧率请用无注入的 `run_probe.py`。任务记录见 [敌人共享寻路](../docs/tasks/敌人共享寻路.md)。

`probes/` 包括截图工具、云模型/云影对照、地面性能、草地 LOD、引擎能力与 T03 路径观察。性能旧代码对照放 `tests/fixtures/attack_surface/`，其他项目共享原件保留。

表面密集纹路诊断：`python -B tools/run_probe.py tools/probes/surface_pattern_diagnosis.gd --graphics --task surface_pattern_diagnosis`。固定主场景镜头，在 11.83 与 17.4 时分别对照云投影、软阴影、阴影深度、偏移、SSAO 与旧云显示；截图和条件报告供手动判读，不自动判定观感。

同一探针的天空云层诊断：`python -B tools/run_probe.py tools/probes/surface_pattern_diagnosis.gd --graphics --task cloud_layer_diagnosis --args --cloud-layers`。固定午间仰视、云覆盖率 0.82，对照程序云可见 / 只留天空 / 旧云开关关闭，并读取旧云节点与材质开关。模糊天空云幕已从正式材质移除，探针不再调用其废弃参数；原五组排查图仍保留在任务记录的历史运行目录。不复刻随机天气的全部雨雾数值。

天气修复像素回归：`python -B tools/run_acceptance.py --tests test_procedural_clouds test_weather_runtime_clouds test_cloud_shadow_rendering test_weather_visual_regressions --graphics --task weather_visual_fix`。实际主场景正午 / 傍晚道路纹路、近景投影、仰视云体与天空背景、高空双层云遮光均有自动判定；产物目录由统一验收入口创建。

圣所布局回归：`python -B tools/run_acceptance.py --tests test_sanctum_layout test_scene_dependencies test_runtime_world_visibility --graphics --task sanctum_layout`。检查正式碰撞、导航、静态缓存和建筑内装饰；四张俯视截图供用户观察。

重建山谷静态资源：`python -B tools/run_probe.py tools/probes/bake_valley_assets.gd --task sanctum_layout_bake`。隔离生成，先保存到该运行 `tmp/baked_valley/`，校验重载后没有生成脚本且节点数量相同。核对成功后将 `sanctum_mountains.res`、`sanctum_art.scn`、`manifest.json` 三文件应用到 `assets/generated/valley/`，保留原文件回退副本及源 / 目标路径、前后 SHA256，不能直接覆盖证据目录。随后执行布局回归，检查正式静态资源被加载而没有再次走源生成。

Boss 直战启动帧诊断：`python -B tools/run_probe.py tools/probes/boss_startup_frame_probe.gd --graphics --task boss_startup_frames`。固定投放种子、正午晴天启动同一正式直战场，记录同步初始化、准备遮罩、导航就绪、Boss 出土、第一招和后续真实墙钟帧间隔，以及首次流水线编译计数；输出 `reports/boss_startup_frames.json`。`playing_frames` 排除准备阶段，`playing_stalls_over_50ms` 保留可玩阶段长帧；原始帧不可混同为稳定 FPS。诊断对照可在末尾加 `--args --without-boss-light` / `--without-leap-fx` / `--without-air-debris` / `--without-flight-shadow` / `--without-ground-dust`，只隐藏对应诊断对象，不写回正式配置。测量时单独运行，不与其他游戏或回归进程并行。

阴天天空背景诊断：同一 `surface_pattern_diagnosis.gd` 探针加 `--args --overcast-sky`，固定全阴天隐藏云团，比较天空可见开关、mie 和白昼 / 地平线调色；只用于定位，不能当作正式配色。

`python -B tools/numerics_progression_model.py` 按历史公式读取当前配置，输出到独立 `numerics_model/<运行编号>/reports/`；公式未同步为当前运行代码实测，不作为现行数值验收。

## 目录检查与恢复

```powershell
python -B tools/project_hygiene.py check
python -B tools/project_hygiene.py restore --manifest <迁移清单绝对路径>
```

检查只报告，不删除。恢复默认只预览，明确执行追加 `--apply`；先核对路径与校验值，同名占用或整理后新修改会阻止恢复，需要人工合并。修改过的源码有备份，恢复保全整理版本；新工具与规则文件不自动删除。

`check` 覆盖：项目与工作区根目录散落产物、仍在使用的旧产物目录、脚本中的旧产物输出路径、失效的文档链接，以及项目内的可执行文件与超大文件（`BINARY_SUFFIXES`，或 ≥50 MB）。后一类按是否被 `.gitignore` 排除区分：未排除的判为失败——它会被提交，超过 100 MB 时 GitHub 会拒绝 push；已排除的只打印提示，因为忽略规则不替代目录规范。`run_acceptance.py` 与 `run_probe.py` 启动前都调用 `check`，失败即中止。

门槛自检：在项目根目录放一个未被忽略的 `.exe`（或任意 ≥50 MB 的文件）后运行 `check`，应失败并列出该文件；删除后应恢复通过。

本次清单位于项目外 `project_cleanup/20261008_165045_1ddc4433/reports/migration.json`，同目录 `migration.md` 为索引，原源码在 `tmp/before/`。历史验收副本在 `tmp/historical_analysis/` 保留原结构，不将旧布局强行改成新布局。

根目录旧日志归属不确定，保存到 `_artifacts/legacy/20261008_165045_1ddc4433/logs/`。未确认归属的公共截图及其他项目材料保持原位置。

三种新敌人的视觉截图：`python -B tools/run_probe.py tools/probes/new_enemy_visual_capture.gd --graphics --task new_enemy_visual_capture`。每种生成面板、正面、侧面、三分之四、蓄力和剪影图。

上述新敌人截图命令末尾加 `--args --motion`，可额外生成每种在 12 米和 24 米的待机、蓄力、释放对照。

新怪死亡截图：`python -B tools/run_probe.py tools/probes/enemy_death_capture.gd --graphics --task enemy_death_capture`，输出活体、死亡预备、爆裂/翻身、抖腿、尸体和时间轴，以及爬兽转身/收甲阶段。

六小怪导航/攻击复盘：`python -B tools/run_probe.py tools/probes/creature_navigation_audit.gd --task creature_navigation --args --strict --formal-routes`。读取当前已保存默认方案，验证扑击/近身/蜂针与俯冲、六种绕矮墙/方岩/球岩，并在圣所真实岩石后逐种验证对真实玩家造成伤害。小场地逐例使用独立导航地图；地图未就绪明确失败，失败保存物理轨迹和即时规划诊断。`--repeat-mud-rock --contact-start`可单独连续复现六次泥偶贴岩起步。对应默认值回归为`test_creature_navigation_and_attacks`。

六种混编与泰坦全流程：`python -B tools/run_probe.py tools/probes/sanctum_creature_trial.gd --graphics --task sanctum_trial --timeout 480`。固定个体与波次随机种子，先30秒观察原生攻击，再用实际枪线、必要时正常接近/有限侧移和边界返场完成当前配置三波（30/45/60只）、选卡、同方案泰坦及死亡后结算。记录逐波峰值、每秒人数、命中和技能。玩家补血、观察阶段固定玩家位置并停自动小精灵、弹药补充均仅用于测试。Boss先核对“圣所关底 Boss”全量参数与360000生命、实际受伤和原生技能，再通过真实take_damage注入测试专用伤害推进狂暴与死亡；报告明确标记该控制，不拿它声称真人击杀时长或难度。输出`reports/trial.json`与截图，任何六种技能缺失、开场未达到目标人数、超过人数上限或未通关均失败。

持续黏液物理检查：`python -B tools/run_acceptance.py --tests test_poison_puddle test_crystal_creature_combat`，覆盖大范围周期伤害、离开/回到范围、不同楼层/跳跃、墙体、暂停/到期与投掷者死亡独立。

泰坦圣所边坡原现场：`python -B tools/run_probe.py tools/probes/titan_sanctum_route.gd --task titan_sanctum_route`，读取实际Boss方案/公共生成器，在原失败坐标观察30秒原生接敌；无实际选招则严格失败，输出位置、门控、原生选招与导航诊断。对应自动测试为`test_titan_sanctum_route`。

测试台会话隔离诊断（T00）：`python -B tools/run_probe.py tools/probes/testing_session_probe.gd --task testing_session`。用实际圣所和已保存泰坦参数，对照场景重建、裸 World3D、受控同进程预览，以及独立进程技能执行／中途终止；输出 `reports/testing_session_probe.json`。负对照必须暴露全树目标、共享资源、全局进度及随机序列串扰，诊断整体通过不代表各候选均可采用。加 `--graphics` 可保存同进程预览的真实震拳画面；子预览始终无头并继承隔离工程和自动标记。它是可复用研究工具，尚非统一测试台、正式草稿协议或预览窗口产品。
