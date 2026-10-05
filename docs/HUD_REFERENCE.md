# 轻量玻璃 HUD：参考图落实与验收

本轮以用户确认的 `codex-clipboard-d62c857e-8f36-4e46-8a44-6d4662309765.png` 为视觉基准。不是新增设计方向。

## 保持的约束

- 弹药、生命护盾、E/Q 三组共用底部基线，距底边 26 逻辑像素。
- 小地图、时间条、Q 的最右点共用右基线，距右边 22 逻辑像素。
- E/Q **组合总宽**等于小地图宽度 162。E 是平行四边形；Q 是斜左边、近直右边、右下短切角，不能把 Q 改成平行四边形。
- 主弹药只倾斜字形，文字基线水平。默认只显示当前弹匣、容量、备弹；装填时才增加进度提示。
- 常驻战斗 HUD 不恢复武器等级、伤害、击杀统计或狙击信息条。既有数据接口仍保留。

字形变换特别注意：`FontVariation.variation_transform` 的 FreeType 分量传递顺序不同于 Canvas 的矩阵列顺序。正确横向切变使用 `Transform2D(Vector2(1, s), Vector2(0, 1), Vector2.ZERO)`；不能写成 `Vector2(1, 0), Vector2(s, 1)`，后者会纵向错切字形。[Godot 4.7.2 字体实现](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/text_server_adv/text_server_adv.cpp) 可查 `FT_Matrix` 的分量顺序。

运行 `tests/test_ammo_typography.gd` 比较 0–9 与 `/` 在 23、35、46、60 四个字号的实际轮廓：每个点的 y 必须不变，x 只随高度变化。该测试覆盖 44 个字形/字号组合，另以旧变换作为负对照，避免再靠更换正负号猜方向。附加 `-- --capture` 会生成带水平辅助线的修改前后对照图 `visual_captures/hud_review/ammo_typography.png`。

## 逻辑尺寸（1152×648 排版空间）

| 组件 | 宽×高 | 说明 |
| --- | --- | --- |
| 弹药 | 210×96 | 左上短切角，右侧长斜边；主数字 60，三位数 46，四位数 35 |
| 生命护盾 | 242×50 | 两行，小图标和数字，圆头连续条；保留掉血残影 |
| 技能组合 | 162×46 | E 82、Q 83、轮廓包围盒重叠 3；实际轮廓不重叠 |
| 小地图 | 162×148 | 顶边距 20，上左短切角，无厚边框 |
| 游戏时钟 | 162×30 | 地图下间距 4；时间右侧、日/月图标左侧 |

窗口缩放和用户 UI 缩放继续由现有显示系统管理。截图验收固定本次运行的窗口和缩放，不覆盖玩家存档。

## 玻璃与小地图

玻璃背景和前景分层：只对背景做轻微模糊和去色，文字、图标、极细断面保持清晰。没有外部光晕、彩色玻璃或碎片纹理。玻璃遮罩由真实多边形生成，内部反光不能溢出。

实现参考 [Godot 屏幕读取着色器文档](https://docs.godotengine.org/en/4.4/tutorials/shaders/screen-reading_shaders.html)：共享屏幕采样，使用 mipmap 轻微柔化背景。`shaders/hud_black_glass.gdshader` 是材质参数入口。

小地图保留真实导航信息：512×512 烘焙高度底图、柔和山坡明暗、等高线、实际树冠、实际道路曲线和遗迹投影；敌人和玩家仍为动态标志。不把参考图里的装饰河流添加成不存在的地图信息。

## 回归验收

菜单与拾取通知沿用同一黑玻璃：`menu_panel.gd` 提供内容底板，`glass_button.gd` 保留原生按钮交互，`readout_plate.gd` 的 `glass_style` 使用上下两行统计，避免标签与大读数挤在同一基线。开始页只有「遗迹星球」、必要的关卡选择与开始/设置/退出按钮，不含玩法介绍或操作表。背景为真实场景的静态相机，开局重载时释放。

拾取通知仍最多三条、2.8 秒后消失；普通生命/弹药补给仍不额外弹文字。黑玻璃底层与文字一同淡出，右边界跟随地图，纵向避开地图、时钟和 FPS。长文字截断，避免越出底板。

玻璃着色器输出保留输入 `COLOR.a`（父节点的调制透明度），另外用 `surface_opacity` 控制各条通知的生命周期，防止菜单文字淡入时玻璃抢先出现。参见 [Godot CanvasItem 的 COLOR 输入/输出说明](https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/canvas_item_shader.html#color-and-texture)。

项目名称改为「遗迹星球」。用固定的自定义用户目录保留原有 `godot-zelda` 存档/显示设置路径（Windows 为 `Godot/app_userdata/godot-zelda`），不移动或覆盖存档。参见 [Godot 用户目录说明](https://docs.godotengine.org/en/4.6/classes/class_projectsettings.html#class-projectsettings-property-application-config-use-custom-user-dir)。

运行 `tests/test_ui_surfaces.gd` 检查开始/设置/暂停/结算的状态切换、布局及通知生命周期；附加 `-- --capture` 在 `visual_captures/ui_surfaces/` 生成实际截图。

运行 `tests/capture_hud_review.gd`，生成项目同级 `visual_captures/hud_review/` 中七张实际游戏截图：白天、低血量/冷却/装填、夜雨、波间休整、1280×720、三位数弹匣、2560×1440 与 115% UI 缩放。

脚本逐状态检查底部/右侧基线、技能组与地图等宽，以及玻璃多边形可三角化、E 的平行斜边、Q 的五点轮廓。自动检查不能代替最终视觉验收；截图必须与参考图对照查看。
