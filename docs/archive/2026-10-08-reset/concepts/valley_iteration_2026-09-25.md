# 山谷场景：全景概念图驱动迭代

本轮范围：圣所静态场景。概念图是设计目标，不是引擎实拍。

## 对照图

- 基线实拍：`../../visual_captures/concept_before_north_high.png`
- 根据基线生成的概念图：`valley_panorama_2026-09-25.png`
- 修改后同机位实拍：`../../visual_captures/concept_final_north_high.png`
- 其余 10 个固定机位：`../../visual_captures/concept_final_*.png`

## 已落地

- 远景土路从可玩地形边缘延续到山谷中，并随山势弯曲、逐渐收窄。道路高度按山体**实际三角面**取样，避免中间被山面遮断。
- 两侧廊道补上有缝的石板铺装，局部缺损，并在建筑附近布置小块坍落石。原有柱距和墙体保留，可读出曾经的双侧廊道。
- 坡脚新增成群的松树、阔叶树和低矮灌木；原来不投影的近处批量松树在圣所停用，树的阴影关系更一致。
- 抬亮近山脚色，保留蓝色远山的层次。

## 验证

Godot 4.7.1；11 个固定视角均成功截图。地形最大坡度 34.7°（上限 45°），掩体 20 个、最高 2.4 米，导航 2132 多边形。`test_valley_geometry.gd` 和 `test_runtime_world_visibility.gd` 通过。

固定 14 敌人压力场景，RTX 5060 Ti、窗口 1920×1080，渲染视口纹理 3200×1800：平均 297 FPS，1% 低帧 220 FPS。记录：`../../performance_logs/perf_single_1790309169.csv`。这不是 2080/3060/4060 的实测结果。

## 仍有差距

概念图里的林缘、树冠轮廓、石材风化与柔和光照目前没有完整落地。现有远景道路只是视觉延伸，不属于可行走区域；如果要把该山谷扩成玩法空间，需同步扩地形碰撞与导航。

## 绘图提示词（imagegen 内置模式）

Use case: stylized-concept. Asset type: actionable game environment concept art for rebuilding the supplied Godot scene. Image 1 is the current in-engine panoramic screenshot and is the composition/layout reference. Keep the SAME elevated camera, orientation and approximate placement: a central earth road running away into the valley, paired ruined stone galleries around a central gateway/blue crystal in the foreground, smaller red and golden landmarks to the sides, mountain walls behind. Improve this existing scene into a cohesive, achievable low-poly stylized adventure-game valley, akin to a polished real-time 3D environment on midrange GPU. Make the road vary visibly in width: broad around the ruins and junction, narrow winding farther away, with crisp irregular dirt banks, warm ochre and muted terra cotta facets, occasional embedded stones, no blurry blending. The ruins should read as remains of an actual symmetrical ceremonial building: coherent stone plinths, surviving paired column rhythms, partially collapsed lintels, low connected wall footprints, fallen blocks clustered near their source, weathered warm-grey stone, some moss and grass entering cracks. Preserve navigable openings. Trees group naturally in groves, mix dark conifers and faceted broadleaf trees with consistent soft shadows; clear open meadow near paths, more density toward mountain foothills; occasional rocks and yellow flowers. Distant layered blue mountains and bright blue sky, gentle atmospheric perspective, warm angled sunlight, readable shadows. Blue, amber-gold, and red landmarks remain subtle but visible. Aim for believable form and deliberate large shapes, not dense random detail. No characters, no interface, no text, no annotations, no photoreal textures. Landscape image.
