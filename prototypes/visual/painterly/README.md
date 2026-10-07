# 手绘风格独立样板

状态：Active，视觉探索用，尚未接入正式地图。

## 打开与运行

在 Godot 打开 `painterly_style_lab.tscn`，按 **F6 运行当前场景**。不要按编辑器的 F5，否则会运行正式游戏。场景物体在运行时生成；编辑器的静态视图不显示这些物体。

样板包含连贯草地/道路、少量成组树木和岩石、一座倒角石门、断墙、晶石和远景丘陵。没有角色、战斗、拾取、生产地图碰撞或天气系统。其目的不是证明地图已达标，而是比较形体、轮廓、材质和光照方向。

## 对照与操作

- `1` 原始材质：关闭笔触和绘画式漫反射，保留相同颜色、几何、环境与道路。
- `2` 水粉手绘：默认，大片颜色、轻微表面笔触、柔和漫反射。
- `3` 明显笔触：提高笔触强度，用于判断过强纹理的副作用。
- `4` 水墨丹青：目前优先研究形体与轮廓，淡青绿、纸色留白和淡墨远山。
- `5` 莫奈启发：色光与短碎笔触初稿，尚未按该方向重做模型。
- `6` 塞尚启发：色面组织初稿，尚未按该方向重做模型。
- `7` 梵高启发：流动排线初稿，尚未按该方向重做模型。
- `8` 北斋启发的木版方向：目前优先研究整组剪影、勾线与有限套色。
- 面板“使用专用形体与轮廓”：仅影响水墨 / 木版；关闭时恢复原模型，但颜色、材质、光照不变，用来辨别实际形体变化与单纯换材质。
- 面板滑块：调整笔触强度，不写入游戏设置。
- `L` 晴天 / 阴天 / 夜间；夜间自动打开手电筒。
- `F` 手电筒开关，使用真实 `SpotLight3D`，并非全屏提亮。
- 右键拖动环绕，滚轮缩放；`R` 恢复正面。
- 游戏窗口内 `F5` / `F6` / `F7` 切换背面 / 近景 / 俯视。
- `H` 隐藏调节面板，便于截图。

笔触计算依附模型局部坐标，不使用屏幕坐标或时间，不会随相机滑动。道路颜色直接融合进地面材质，没有悬浮的道路边缘片。主模型保持背面剔除，不使用双面材质掩盖反面问题。勾线使用单独的外扩背壳，只剔除正面，这是轮廓绘制，不是主模型翻面补救。

## 本轮重点：不再把换材质视作完整风格

优先深化用户认可的木版方向，以及必须保留的水墨丹青。其他方向保留为初稿，不宣称已经做成对应画家的艺术风格。

- 树木：弯曲树干、真实支撑枝、非规则树冠；调整树冠位置形成重叠剪影，避免悬浮的圆盘。
- 岩石：非对称肩部、倾斜轮廓与埋入地面的底部，不再完全依赖光滑椭球。
- 水墨山体：单独的逐层收窄、带倾斜山顶的网格；淡墨与断续纵向皴线弱化底层三角面的受光。夜间淡墨亮度单独降低，避免自发光山体。
- 遗迹：专用闭合倒角网格与轻微不规则外形，单独勾勒石块边缘。
- 轮廓：勾线壳共享位置的顶点使用一致的平滑外扩方向，避免硬面法线把轮廓壳撕成毛边；主模型仍保留自己的面法线。
- 原有三种模式恢复原模型和变换，新增树枝隐藏；新形体不污染原有对照。

验收不以预设名称为依据：保持同机位、颜色和光照，关闭/打开形体开关；分别看正面、背面、近景、俯视。模型剪影、分组和转折必须有实际变化，不能只多一层噪声。

### 倒角拓扑检查发现

共用 `LowPolyMesh.chamfered_box` 的原形体通过逐面朝向检查，但边缘配对发现部分面重叠：原有角点仅内缩一个坐标，却同时补入边面，叠加了两种不兼容的截角结构。外扩轮廓会放大这个问题。

本轮仅在独立样板的新形体里使用 `StylizedGeometry.closed_chamfer`：每个角点内缩两个坐标，形成六个主面、十二个边面、八个角面，每条边恰好出现两次且方向相反。正式共用生成器**未修改**；原始对照也保留。后续接入正式地图前需要单独处理共用生成器，不能把逐面朝向通过当作拓扑正确。

## 隔离边界

不改 `project.godot`、正式场景、Graphics 画质预设、DisplaySettings 保存配置或战斗逻辑。样板暂时隐藏全局游戏菜单，并使用独立的 World3D 环境；退出时恢复环境、菜单与暂停状态。参数只在这次运行内有效。

当前仍是程序化风格试验，不等同于美术师完成的手绘场景。水墨/木版已有专用形体与轮廓第一版，但树冠仍偏块面，植被仍较简陋，水墨的浓淡、皴擦和虚实组织尚未完成；其他三种艺术方向仍主要是材质试验。夜间仅验证材质能响应动态照明，不代表完整天气验收。

## 验证

结构、朝向、闭合边缘、形体开关和八种风格恢复检查：

```powershell
& 'D:\godot_project\Godot_v4.7.2-stable_win64_console.exe' --headless --path 'D:\godot_project\godot-zelda' --script res://tests/test_painterly_style_lab.gd --audio-driver Dummy
```

实际渲染截图（三种材质 × 四个角度，加阴天、夜间、调节面板）：

```powershell
& 'D:\godot_project\Godot_v4.7.2-stable_win64_console.exe' --path 'D:\godot_project\godot-zelda' res://prototypes/visual/painterly/painterly_style_lab.tscn --audio-driver Dummy -- --painterly-capture
```

截图输出到项目同级 `D:\godot_project\visual_captures\painterly_lab`，避免被打入游戏。截图模式结束后自动关闭样板。

新增艺术方向截图（五个方向 × 四个角度，加阴天、夜间、原模型同材质对照）：

```powershell
& 'D:\godot_project\Godot_v4.7.2-stable_win64_console.exe' --path 'D:\godot_project\godot-zelda' res://prototypes/visual/painterly/painterly_style_lab.tscn --audio-driver Dummy -- --artist-capture
```

输出到 `D:\godot_project\visual_captures\artist_exploration`。`comparison.png` 是各方向概览；`shape_comparison.png` 是水墨/木版原模型与专用形体的同材质对照，均来自实际渲染截图，不是概念画。

本样板没有战斗压力，不能用它的帧数推断正式游戏性能，亦不作为最低显卡验收结果。

## 艺术参考

仅借鉴艺术语言，不下载名画充当材质，不声称复刻画家作品。

- [大都会博物馆：中国山水画](https://www.metmuseum.org/es/essays/landscape-painting-in-chinese-art)、[梅清山水作品](https://www.metmuseum.org/art/collection/search/36453)：水墨、山石与树木形态的参考。
- [大都会博物馆：北斋《神奈川冲浪里》](https://www.metmuseum.org/art/collection/search/39799)：木版印刷方向的参考。
- [MoMA：印象派](https://www.moma.org/collection/terms/impressionism)：色光与碎笔方向的参考。
- [大都会博物馆：塞尚](https://www.metmuseum.org/essays/paul-cezanne-1839-1906)：色面与体积方向的参考。
- [梵高博物馆：色彩](https://www.vangoghmuseum.nl/en/art-and-stories/stories/vincents-colours)：浓重色彩方向的参考。
