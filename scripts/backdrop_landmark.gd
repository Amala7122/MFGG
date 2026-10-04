@tool
extends Node3D
## 场地外的背景地景：几百米地台 + 远景色层。
##
## 竞技场只有有限尺寸，世界是一块方板。相机往外看是一条笔直的矩形切边 ——
## "浮空板"感就是这么来的。地台负责消掉它。
##
## ── 这里【不】再放中距离巨构 ───────────────────────────────────
##
## 上一版在 70~190m 随机撒了 15m 高墙 / 30m 方柱 / 60m 门框。结果是：
## 四张地图外圈长出一模一样的随机大结构（因为这套布局只按种子生成，
## 不读任何地图参数），而且它们彼此无轴线、无分组，读起来就是"插在地上的板"。
##
## 【结论】纪念碑归地图所有（见 arenas.definitions.<id>.map.props），
## 背景只负责两件事：托住地、在地平线上给出层次。
## 所以这里只剩远处两组、成角度分布的体量：
##   180~420m  断续山脊线（低而长，提供地平线结构）
##   380~680m  远景塔体（高而窄，提供灭点与剪影）
## 数量由竞技场参数 landscape.* 决定，不同地图可以完全不同。
##
## 【红线一：不可交互】—— 无碰撞体、不入 nav_source 组。navigation_region.gd
## 只用 SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN + 组 nav_source 收集源几何，
## 所以不入组就对导航烘焙与 Jolt 完全不可见。这是它能存在的全部依据。
##
## 【红线二：默认绘制调用锁死 2 个】地台一个 ArrayMesh，
## 地标一个 ArrayMesh。统一天气场景的云由 WeatherSystem 下的程序云场负责；
## 旧 Sky3D 实验仍保留单独的背景云提交。
##
## 【红线三：稀疏】—— 严禁"小房子 × 40"。宁可只有几个体块，也要让每个体块
## 都大到能单独撑起构图。

const ConfigUtil := preload("res://scripts/game_config.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
## 用 preload 而不是全局类名引用几何工厂。
## 【原因】class_name 注册在 .godot/global_script_class_cache.cfg 里，而那是由
## 编辑器扫描维护的。本项目当前没有编辑器在跑（9080 未监听），命令行启动时
## 新脚本的全局类名根本不在缓存里 —— 表现是"类型找不到"的解析错误，
## 而 preload 不受这件事影响，正好也是本项目其它脚本一贯的写法。
const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")
## 地台内圈要读地形高度，才能和地形边缘对齐。
const TerrainUtil := preload("res://scripts/terrain_field.gd")
const CloudShader := preload("res://shaders/backdrop_cloud.gdshader")
const CloudLighting := preload("res://scripts/cloud_lighting.gd")
const ValleyArt := preload("res://scripts/valley_art.gd")

## 地台内圈跟随地形高度、向外在这么多米内回落到 y=0。
##
## 【为什么必须对齐】—— 地形是一块有起伏的方板，地台是一律 y=0 的环。
## 两者在交界处高低不同，于是出现一条硬边台阶（多角度截图里在门框底部
## 和左侧地平线都能看到）。台阶和悬空是同一类错误：接缝没有藏起来。
##
## 18m 这个值要大于地形边缘的最大起伏，否则回落段自己又成了一道坡。
const EDGE_BLEND := 18.0

## 景层能到达的最大半径。地台半径 900，但体块有【切向长度】——
## 一个长 340m 的脊以 700m 为圆心摆放，它的角可以伸到 870m 以外，
## 越过地台边缘落进虚空，表现就是"底部齐平的巨大石板悬在天上"。
## 所以景层的【中心距离 + 半个最长边】必须留在这条线之内。
const LANDMARK_MAX_RADIUS := 720.0

## 地台外缘。远到足以让 150m 的塔体有立足之地。
const SKIRT_RADIUS := 900.0
## 地台的分段数。刻意很低 —— 这是远景，要的是大切面而不是平滑。
const SKIRT_SEGMENTS := 26
## 方形边界每边的分段。主地形本身是方形，因此地台也必须从同一条方形边界
## 接出去；用圆环会在四个角与主地形大面积重叠，形成俯视图里的绿色三角碎片。
const SKIRT_EDGE_SEGMENTS := 12

var _seed: int = 0
var _rng := RandomNumberGenerator.new()
var _sky_tint := Color(0.55, 0.60, 0.65)
var _land_color := Color(0.16, 0.19, 0.17)
## 竞技场级的远景参数（landscape.*）。缺项时用下面的兜底值，
## 于是"没配的地图"也有一套克制的默认远景，而不是随机生成一套。
var _landscape: Dictionary = {}
## 地台内圈半径，供 _edge_height 判断"离地形边缘还有多远"。
var _inner: float = 0.0
var _cloud_mesh: MeshInstance3D
var _cloud_time := 0.0


func _ready() -> void:
	# 【必须延后一帧再建】—— 地台内圈高度要读 TerrainUtil.height_at()，
	# 而那是场景 _ready() 里 apply_arena() 之后才有效的静态缓存。
	# 本节点是 autoload 挂上去的，_ready 早于场景 _ready；直接读会拿到
	# 兜底高度，结果不是接缝消失，而是接缝换了个位置。
	call_deferred("_build")


func _build() -> void:
	var arena := ArenaUtil.get_params()
	_seed = ArenaUtil.SEED_BASE + String(arena.get("_id", "")).hash()
	_rng.seed = _seed
	_read_palette(arena)
	var raw: Variant = arena.get("landscape", null)
	_landscape = raw as Dictionary if raw is Dictionary else {}
	var sky3d_lighting := _uses_sky3d_lighting()
	if String(arena.get("_id", "")) == "sanctum":
		var valley := MeshInstance3D.new()
		valley.name = "ContinuousValley"
		valley.mesh = ValleyArt.mountains()
		valley.material_override = _make_material(false, true)
		valley.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(valley)
		if not _uses_procedural_cloud_field():
			_cloud_mesh = _build_clouds()
			add_child(_cloud_mesh)
			_update_editor_cloud_tint()
		return
	add_child(_build_skirt(arena, sky3d_lighting))
	if sky3d_lighting:
		# 远景云独立成第三个提交：保持低模轮廓，但不再当作近处实体受直射光。
		add_child(_build_landforms(true))
		if not _uses_procedural_cloud_field():
			_cloud_mesh = _build_clouds()
			add_child(_cloud_mesh)
			_update_editor_cloud_tint()
	else:
		add_child(_build_landmarks())


func _process(delta: float) -> void:
	if not is_instance_valid(_cloud_mesh):
		return
	# 高空云层的慢漂移与地表阵风不同；风静时仍可缓慢移动。
	_cloud_time += delta
	_cloud_mesh.rotation.y = _cloud_time * 0.00055
	var material := _cloud_mesh.material_override as ShaderMaterial
	if material != null:
		material.set_shader_parameter("cloud_time", _cloud_time)
	_update_editor_cloud_tint()


func _update_editor_cloud_tint() -> void:
	# WeatherSystem 只在游戏中运行；编辑器里的程序化预览必须自行跟随 Sky3D。
	if not Engine.is_editor_hint() or not is_instance_valid(_cloud_mesh):
		return
	var scene_root := get_tree().edited_scene_root
	if scene_root == null:
		return
	var sky := scene_root.find_child("Sky3D", true, false)
	var sun := sky.get_node_or_null("SunLight") as DirectionalLight3D if sky != null else null
	var material := _cloud_mesh.material_override as ShaderMaterial
	if material != null:
		material.set_shader_parameter("cloud_tint", CloudLighting.tint_for_sun(sun))


## 天空与地景基调色。天空色直接决定远景向哪个方向收敛 ——
## 远景越远越接近它，于是"空间巨大感"是由画面自己长出来的，不是靠雾糊的。
func _read_palette(arena: Dictionary) -> void:
	var lighting := ConfigUtil.get_dictionary(
		"lighting.arenas.%s" % String(arena.get("_id", ""))
	)
	_sky_tint = _array_to_color(lighting.get("sky_horizon"), _sky_tint)
	# 【地表色必须取竞技场的 ground_color，不能取 fog_color】
	# fog_color 是"雾的亮度"，本身就是浅灰；拿它当地表色，地台会渲成一片
	# 惨白的沙滩（实测第一版就是这样）。地台要和地形是同一块地，
	# 所以它必须从地面色出发，只按距离向天空色抬。
	_land_color = _array_to_color(arena.get("ground_color"), _land_color)


## 地台：从竞技场边缘铺到几百米外的大切面盘。
## 它同时干三件事：消掉矩形切边、托住巨型体量、用逐级变亮变冷的颜色
## 把空间纵深画出来。
func _build_skirt(arena: Dictionary, stylized_lighting: bool = false) -> MeshInstance3D:
	var extent := float(arena.get("extent", 60.0))
	# 向主地形内侧压 2m，并把地台略微下沉：接缝被主地形覆盖，但不会共面闪烁。
	var inner := extent - 2.0
	_inner = inner
	var builder := LowPolyMeshUtil.begin()
	# 公共几何工具统一保证 Godot 正面与光照法线同向，这里不再局部翻法线。
	for index in range(SKIRT_SEGMENTS):
		_push_skirt_quad(builder, inner, index)
	var instance := MeshInstance3D.new()
	instance.name = "BackdropSkirt"
	instance.mesh = LowPolyMeshUtil.commit(builder)
	# 旧天空继续使用固定远景色；Sky3D 实验让外圈跟随太阳、月亮与天空环境光，
	# 但使用包裹漫反射并禁止接收阴影，避免日落时整个外圈坠成黑色。
	instance.material_override = _make_material(not stylized_lighting, stylized_lighting)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


## 地台的一圈方形带。半径按指数拉开：近处密、远处稀，远处的面更大。
func _push_skirt_quad(builder: LowPolyMeshUtil.Builder, inner: float, index: int) -> void:
	var t0 := float(index) / float(SKIRT_SEGMENTS)
	var t1 := float(index + 1) / float(SKIRT_SEGMENTS)
	var r0 := inner + (SKIRT_RADIUS - inner) * pow(t0, 2.2)
	var r1 := inner + (SKIRT_RADIUS - inner) * pow(t1, 2.2)
	# 【只走 0.30，不要再多了】—— 这个系数决定"远处地面最终有多接近天空"。
	# 走 0.55 时远端地色几乎追平天际色，地平线消失，站在上面的山脊与远塔
	# 失去地面参照，整片读成悬空（多角度截图实测）。远端变亮变冷应该由
	# 分段雾负责，顶点色这里只要保证【任何距离上地面都比天空暗】。
	var skirt_base := _land_color.lightened(0.17)
	var color := LowPolyMeshUtil.grade_by_distance(skirt_base, _sky_tint, t0 * 0.30)
	for side in range(4):
		for segment in range(SKIRT_EDGE_SEGMENTS):
			var u0 := float(segment) / float(SKIRT_EDGE_SEGMENTS)
			var u1 := float(segment + 1) / float(SKIRT_EDGE_SEGMENTS)
			var q0 := _square_perimeter_point(r0, side, u0)
			var q1 := _square_perimeter_point(r0, side, u1)
			var q2 := _square_perimeter_point(r1, side, u1)
			var q3 := _square_perimeter_point(r1, side, u0)
			var p0 := Vector3(q0.x, _edge_height(q0.x, q0.y, r0), q0.y)
			var p1 := Vector3(q1.x, _edge_height(q1.x, q1.y, r0), q1.y)
			var p2 := Vector3(q2.x, _edge_height(q2.x, q2.y, r1), q2.y)
			var p3 := Vector3(q3.x, _edge_height(q3.x, q3.y, r1), q3.y)
			LowPolyMeshUtil.push_quad(builder, p0, p1, p2, p3, color)


func _square_perimeter_point(half_size: float, side: int, u: float) -> Vector2:
	match side:
		0:
			return Vector2(lerpf(-half_size, half_size, u), -half_size)
		1:
			return Vector2(half_size, lerpf(-half_size, half_size, u))
		2:
			return Vector2(lerpf(half_size, -half_size, u), half_size)
		_:
			return Vector2(-half_size, lerpf(half_size, -half_size, u))


## 地台在 (x,z) 处的高度：内圈贴地形，向外在 EDGE_BLEND 米内回落到 0。
func _edge_height(x: float, z: float, radius: float) -> float:
	var t := clampf((radius - _inner) / EDGE_BLEND, 0.0, 1.0)
	if t >= 1.0:
		return 0.0
	return TerrainUtil.height_at(x, z) * (1.0 - t) - 0.06 * (1.0 - t)


## 远景色层。全部是 Cube，区别只在尺度与远近。
##
## 【分布方式：按角度均分 + 抖动，而不是纯随机】—— 纯随机会在某些方向堆成一团、
## 另一些方向空着，地平线的节奏就散了。按角度均分保证任何方向望出去都有层次。
## 竞技场可以用 landscape.angle_offset 把整圈层错开，让不同地图的主视方向不同。
func _build_landmarks() -> MeshInstance3D:
	var builder := LowPolyMeshUtil.begin()
	_push_cloud_banks(builder)
	_push_landforms(builder)
	return _commit_landmark_mesh(builder, "BackdropLandmarks", false)


## Sky3D 路径把云和陆地拆开。远山保留面法线参与受光，低模切面因此会跟随
## 太阳/月亮方向变化；不接收阴影，远景不会被近景物体切出不合理的大黑块。
func _build_landforms(stylized_lighting: bool) -> MeshInstance3D:
	var builder := LowPolyMeshUtil.begin()
	_push_landforms(builder)
	return _commit_landmark_mesh(builder, "BackdropLandforms", stylized_lighting)


func _build_clouds() -> MeshInstance3D:
	var builder := LowPolyMeshUtil.begin()
	_push_cloud_banks(builder)
	var instance := MeshInstance3D.new()
	instance.name = "BackdropClouds"
	instance.mesh = LowPolyMeshUtil.commit(builder)
	var material := ShaderMaterial.new()
	material.shader = CloudShader
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.extra_cull_margin = 12.0
	return instance


func _push_landforms(builder: LowPolyMeshUtil.Builder) -> void:
	_push_horizon_berms(builder)
	_push_foothills(builder)
	_push_ridges(builder)
	_push_towers(builder)


func _commit_landmark_mesh(
	builder: LowPolyMeshUtil.Builder, node_name: String, stylized_lighting: bool
) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = LowPolyMeshUtil.commit(builder)
	instance.material_override = _make_material(not stylized_lighting, stylized_lighting)
	# 远景已经远在 directional_shadow_max_distance 之外，投影只是白烧性能。
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


## 参考画面里天空并不是一张空色纸，而是由横向云带把山峰一层层切开。
## 云仍合并成一次绘制提交；Sky3D 路径另用独立材质处理高空色调与移动。
func _push_cloud_banks(builder: LowPolyMeshUtil.Builder) -> void:
	var count := maxi(int(_landscape.get("cloud_bank_count", 8)), 0)
	if count <= 0:
		return
	var offset := deg_to_rad(float(_landscape.get("angle_offset", 0.0))) + 0.31
	for index in range(count):
		var angle := offset + TAU * float(index) / float(count) \
			+ _rng.randf_range(-0.11, 0.11)
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		# 离开山峰附近的低空：云是远处的大气层，不是放大了的场景道具。
		var distance := _rng.randf_range(760.0, 880.0)
		var cluster_center := radial * distance + Vector3(0.0, _rng.randf_range(295.0, 365.0), 0.0)
		var puff_count := _rng.randi_range(5, 6)
		for puff_index in range(puff_count):
			var centered := float(puff_index) - float(puff_count - 1) * 0.5
			var center := cluster_center \
				+ tangent * (centered * _rng.randf_range(60.0, 80.0)) \
				+ radial * _rng.randf_range(-12.0, 12.0) \
				+ Vector3(0.0, _rng.randf_range(-15.0, 20.0) - absf(centered) * 3.0, 0.0)
			var size := Vector3(
				_rng.randf_range(80.0, 115.0),
				_rng.randf_range(31.0, 48.0),
				_rng.randf_range(30.0, 48.0)
			)
			_push_cloud_puff(builder, center, size, 10)


func _push_cloud_puff(
	builder: LowPolyMeshUtil.Builder, center: Vector3, size: Vector3, facets: int
) -> void:
	var underside := _sky_tint.lerp(Color(0.76, 0.83, 0.90), 0.45)
	var side_color := _sky_tint.lerp(Color(0.92, 0.945, 0.97), 0.78)
	var top_color := Color(0.96, 0.97, 0.985, 1.0)
	var lower: Array[Vector3] = []
	var middle: Array[Vector3] = []
	var upper: Array[Vector3] = []
	for index in range(facets):
		var phase := TAU * float(index) / float(facets)
		var oval := Vector3(cos(phase) * size.x, 0.0, sin(phase) * size.z)
		lower.append(center + oval * 0.72 - Vector3(0.0, size.y * 0.22, 0.0))
		middle.append(center + oval)
		upper.append(center + oval * 0.62 + Vector3(0.0, size.y * 0.22, 0.0))
	var bottom := center - Vector3(0.0, size.y * 0.30, 0.0)
	var top := center + Vector3(size.x * 0.08, size.y * 0.48, -size.z * 0.04)
	for index in range(facets):
		var next := (index + 1) % facets
		LowPolyMeshUtil.push_triangle(builder, bottom, lower[next], lower[index], underside)
		LowPolyMeshUtil.push_quad(builder, lower[index], lower[next], middle[next], middle[index], underside)
		LowPolyMeshUtil.push_quad(builder, middle[index], middle[next], upper[next], upper[index], side_color)
		LowPolyMeshUtil.push_triangle(builder, upper[index], upper[next], top, top_color)


## 最内圈是贴近地表色的低丘。它们不负责形成山峰，只负责遮住远山根部，
## 把可玩地形、背景地台和第一层山脚缝在一起。
func _push_horizon_berms(builder: LowPolyMeshUtil.Builder) -> void:
	var count := maxi(int(_landscape.get("berm_count", 12)), 0)
	var offset := deg_to_rad(float(_landscape.get("angle_offset", 0.0))) - 0.09
	for index in range(count):
		var angle := offset + TAU * float(index) / float(maxi(count, 1)) \
			+ _rng.randf_range(-0.10, 0.10)
		_push_mountain(
			builder, _rng.randf_range(145.0, 200.0), angle,
			_rng.randf_range(62.0, 108.0), _rng.randf_range(48.0, 82.0),
			_rng.randf_range(8.0, 16.0), 10,
			0.22, 0.07, 0.80, 0.42, 0.08
		)


## 近层山脚仍带地表绿，只比低丘更高、更冷；它是场地与蓝色远山之间的过渡。
func _push_foothills(builder: LowPolyMeshUtil.Builder) -> void:
	var count := maxi(int(_landscape.get("foothill_count", 10)), 0)
	var offset := deg_to_rad(float(_landscape.get("angle_offset", 0.0))) + 0.18
	for index in range(count):
		var angle := offset + TAU * float(index) / float(maxi(count, 1)) \
			+ _rng.randf_range(-0.13, 0.13)
		_push_mountain(
			builder, _rng.randf_range(175.0, 280.0), angle,
			_rng.randf_range(90.0, 155.0), _rng.randf_range(65.0, 115.0),
			_rng.randf_range(28.0, 56.0), 11,
			0.38, 0.12, 0.60, 0.43, 0.12
		)


## 一个低多边形山体：宽阔基座、收窄肩部和偏心峰顶。
## 所有山共用一个 ArrayMesh，因此仍然只有一次绘制提交。
func _push_mountain(
	builder: LowPolyMeshUtil.Builder,
	distance: float,
	angle: float,
	width: float,
	depth: float,
	height: float,
	facets: int,
	grade_start: float = 0.46,
	grade_range: float = 0.34,
	shoulder_scale: float = 0.52,
	shoulder_height: float = 0.38,
	facet_contrast: float = 0.18
) -> void:
	var radial := Vector3(cos(angle), 0.0, sin(angle))
	var tangent := Vector3(-sin(angle), 0.0, cos(angle))
	var center := radial * distance
	var base: Array[Vector3] = []
	var shoulder: Array[Vector3] = []
	for index in range(facets):
		var phase := TAU * float(index) / float(facets)
		var uneven := _rng.randf_range(0.82, 1.12)
		var offset := (
			tangent * cos(phase) * width * 0.5
			+ radial * sin(phase) * depth * 0.5
		) * uneven
		base.append(center + offset + Vector3(0.0, -2.0, 0.0))
		shoulder.append(center + offset * shoulder_scale + Vector3(0.0, height * shoulder_height, 0.0))
	var peak := center + tangent * _rng.randf_range(-width * 0.12, width * 0.12) \
		+ radial * _rng.randf_range(-depth * 0.08, depth * 0.08) \
		+ Vector3(0.0, height, 0.0)
	var distance_ratio := clampf(distance / SKIRT_RADIUS, 0.0, 1.0)
	var base_color := LowPolyMeshUtil.grade_by_distance(
		_land_color, _sky_tint, grade_start + distance_ratio * grade_range
	)
	for index in range(facets):
		var next := (index + 1) % facets
		# 越远的层对比越低：近丘保留大切面，最远层只留下安静的轮廓。
		var light_step := 1.0 - facet_contrast * 0.5 \
			+ facet_contrast * 0.5 * sin(angle + float(index) * 1.7)
		var face_color := base_color * light_step
		face_color.a = 1.0
		LowPolyMeshUtil.push_quad(
			builder, base[index], base[next], shoulder[next], shoulder[index],
			face_color.darkened(facet_contrast * 0.35)
		)
		LowPolyMeshUtil.push_triangle(
			builder, shoulder[index], shoulder[next], peak, face_color
		)


## 往盒子表里加一个立方体。size 是全尺寸，y 是地面起算的高度。
func _add_box(
	boxes: Array, distance: float, angle: float, size: Vector3, yaw: float
) -> void:
	# 半径按体块的最大水平半径自动收进来，保证任何尺寸的体块都留在地台上。
	# 把这道约束放在唯一的入盒口，就不会出现"某个新加的景层忘了收半径"。
	var max_half := maxf(size.x, size.z) * 0.5
	var radius := minf(distance, LANDMARK_MAX_RADIUS - max_half)
	var position := Vector3(cos(angle) * radius, size.y * 0.5, sin(angle) * radius)
	var ratio := clampf(distance / SKIRT_RADIUS, 0.0, 1.0)
	# 【只走一小段】—— 实测把远景体量的顶点色也大幅推向天空色之后，最远那座塔
	# 反而比它背后的天空更亮，剪影逻辑整个反过来（"远景发光"）。距离带来的变亮
	# 交给雾去做，顶点色这里只做很轻的一档，保证任何距离上体量都比天空暗。
	var color := LowPolyMeshUtil.grade_by_distance(_land_color, _sky_tint, ratio * 0.2)
	boxes.append({
		"position": position,
		"size": size,
		"yaw": yaw,
		"color": color,
	})


## 中层山脊：比山脚更冷、更高，但仍保留横向展开的轮廓。
##
## 【距离从 180~420m 推到 480~700m】—— 原距离上它们落在中景，读起来是一堆
## 大小不一的灰色石板随意摆着，既不像山也不像建筑；而且那个距离的雾还不够浓，
## 地面与天空的亮度差被压得最扁，于是它们看起来是"悬在地平线上方"。
## 推到 480m 之外以后，雾把它们压成低对比的大型剪影，才符合
## "500m+ 只剩大型 silhouette"这条要求。
func _push_ridges(builder: LowPolyMeshUtil.Builder) -> void:
	var count := maxi(int(_landscape.get("ridge_count", 7)), 0)
	var offset := deg_to_rad(float(_landscape.get("angle_offset", 0.0)))
	for index in range(count):
		var angle := offset + TAU * float(index) / float(maxi(count, 1)) \
			+ _rng.randf_range(-0.16, 0.16)
		var distance := _rng.randf_range(320.0, 500.0)
		_push_mountain(
			builder, distance, angle,
			_rng.randf_range(140.0, 220.0), _rng.randf_range(100.0, 165.0),
			_rng.randf_range(70.0, 130.0), 12,
			0.52, 0.18, 0.54, 0.36, 0.13
		)


## 最远层：高而窄、颜色最接近天空，只用来给地平线立几个灭点。
func _push_towers(builder: LowPolyMeshUtil.Builder) -> void:
	var count := maxi(int(_landscape.get("tower_count", 4)), 0)
	if count <= 0:
		return
	# 与山脊错开半个间隔，于是"塔立在山脊之间"而不是叠在一起。
	var offset := deg_to_rad(float(_landscape.get("angle_offset", 0.0))) \
		+ PI / float(count)
	for index in range(count):
		var angle := offset + TAU * float(index) / float(count) \
			+ _rng.randf_range(-0.22, 0.22)
		var distance := _rng.randf_range(470.0, 620.0)
		var side := _rng.randf_range(58.0, 86.0)
		_push_mountain(
			builder, distance, angle, side, side * _rng.randf_range(0.75, 1.15),
			_rng.randf_range(120.0, 195.0), 10,
			0.68, 0.12, 0.42, 0.26, 0.07
		)


## 地台与地标共用的材质。<br>
## 顶点色当反照率用：远景的分级色是【烘进顶点】的，运行时代价为零。
## cast_shadow 由调用方关掉 —— 远景远在 directional_shadow_max_distance 之外。
func _make_material(
	unshaded: bool = false, stylized_lighting: bool = false
) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	# 【这一行不能省】albedo_color 按 sRGB 转线性，而顶点色默认被当作【线性】
	# 直读。同一串 0.13 走两条路会差近一个数量级 —— 实测表现是"地台用地面色却
	# 亮成了沙滩"。打开它，顶点色才和 albedo_color 用同一套色彩约定。
	material.vertex_color_is_srgb = true
	material.roughness = 0.95
	material.metallic = 0.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 背景山色本身已经按距离与切面烘好。让它继续吃游戏主光会导致某个观察方向
	# 整圈山脚变成黑墙；远景用无光照材质后，各方向的空气透视关系保持一致。
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	elif stylized_lighting:
		# Lambert Wrap 让背光面仍保留少量主光，配合 Sky3D 的环境光可避免巨大
		# 远山在太阳贴近地平线时变成黑墙；面法线仍然保留低多边形明暗切面。
		material.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
		material.disable_receive_shadows = true
	# 高光压到最低：远景不需要镜面反射，只要一块干净的哑光面。
	material.metallic_specular = 0.05
	return material


## 主场景与实验场景都使用 Sky3D，远景与云分别使用对应的受光策略。
func _uses_procedural_cloud_field() -> bool:
	var scene := get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
	return scene != null and scene.find_child("ProceduralCloudField", true, false) != null


func _uses_sky3d_lighting() -> bool:
	if not is_inside_tree():
		return false
	var candidate := get_tree().root.find_child("Sky3D", true, false)
	if not (candidate is WorldEnvironment):
		return false
	var attached := candidate.get_script() as Script
	return attached != null and attached.resource_path == "res://addons/sky_3d/src/Sky3D.gd"


func _array_to_color(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var parts := value as Array
		return Color(float(parts[0]), float(parts[1]), float(parts[2]))
	return fallback
