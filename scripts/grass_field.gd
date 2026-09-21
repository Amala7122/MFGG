@tool
extends Node3D
## 草地：一套独立于其它装饰的 MultiMesh 渲染管线。
##
## 为什么从 world_decor.gd 里拆出来单独做：
##   草是场上唯一"数量上万、要逐帧跟着玩家位置变、还带顶点动画"的装饰。
##   花 / 碎石 / 远景松是一次性摆好就再也不动的静态 MultiMesh，把它们和草塞在
##   同一个脚本里，草的分块 / LOD / 淡出 / 踩踏就无处安放 —— 而且任何一处草的
##   改动都要在几千行无关代码里翻找。草现在有自己的脚本、自己的 shader。
##
## 五条设计约束（改动前务必读）：
##
## 1. 【分块是 LOD 与剔除的最小单位】整片草按方格切成约 25 块，每块一套
##    MultiMesh。逐株算距离要遍历上万实例，逐块只有二十几次距离比较。
##    每块还单独设了 custom_aabb，于是引擎的视锥剔除会自动帮我们挡掉身后的块。
##
## 2. 【LOD 同时降"叶片数"和"株数"】近处 3 片叶全量；中距 2 片叶、62% 株数；
##    远处 1 片叶、30% 株数且叶子更宽 —— 用更少的三角形维持相近的绿量。
##    三级共用同一个材质与同一个叶高，切换时不会有颜色或弯曲程度的跳变。
##
## 3. 【淡出逐顶点按相机距离】淡出在 shader 里用 INV_VIEW_MATRIX 取当前视口
##    相机位置来算，比在 CPU 侧按"玩家距离"近似更贴合真实视角。
##
## 4. 【平时没有风】u_wind 默认 0。只有角色走到附近时草才动（魔兽世界那种被
##    踩开再回弹的效果）：CPU 每帧把最近 8 个角色位置 + 强度塞进 u_trample，
##    shader 把叶尖朝远离角色的方向推开，并叠加一层随运动量增大的摆动。
##    角色停下后运动量衰减到 0，草保持"被踩住"的姿态并慢慢立回来。
##
## 5. 【确定性】摆放只用一个固定种子的 RNG，不建碰撞、不进导航。

const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")
const GrassShader := preload("res://shaders/grass.gdshader")

## shader 里 u_trample 数组的长度。两边必须一致，改一端就要改另一端。
const MAX_TRAMPLERS := 8
## 叶高。与 shader 的 u_tuft_height 同源，见上面第 2 条。
const TUFT_HEIGHT := 0.55
## 一片叶的折线段数。这是 UE5 那套分层草地 faux blade 的做法：
## 叶片不是一根直立的三角形，而是一条向上收窄、向外弯的折线。
const BLADE_SEGMENTS := 4
## 每级的叶片数 / 宽度倍率：越远叶片越少、单叶越宽。
## 近处 5 片才像"一丛草"：3 片时叶片之间的空档比草叶还宽，看上去是几根独立
## 插在地上的剑叶；远处回到 1 片宽叶配 30% 株数，靠数量把三角形省回来。
const LOD_BLADES := [5, 3, 1]
const LOD_WIDTH := [1.0, 1.25, 1.6]
## 贴地抬升。草根埋进地面一点点，缓坡上不会露出缝隙。
const GROUND_OFFSET := 0.015
## 踩踏源所在的组：玩家与敌人都会压开草。
const TRAMPLE_GROUPS := ["player", "enemies"]

@export var editor_preview_enabled := false

## 竞技场与配置缓存（_load_params 一次性读进来，不放每帧路径上）。
var _arena: Dictionary = {}
var _radius := 56.0
var _density := 1.0
var _max_instances := 30000
var _scale_min := 0.65
var _scale_max := 1.35
## 每"丛"撒几株。草是抱团长的，不是一颗一颗等距排开的。
var _cluster_size := 4
## 丛内散开的半径（米）。放大会退化成均匀撒点，所以刻意压得很小。
var _cluster_radius := 0.42
## 密度噪声的频率：约 1/22 米一个起伏，做成几十米宽的草甸与土斑。
var _patch_frequency := 0.045
## 噪声低谷处的密度。这个值不能压到接近 0：草原上的节奏是"密草甸 ↔ 稀疏草"，
## 而不是"有草 ↔ 光秃的土"。取 0 会出现大片裸露地块，比均匀更假。
var _bare_ratio := 0.25
var _seed := 18473
var _chunk_target := 25
var _lod_distances := [14.0, 34.0]
var _cull_distance := 72.0
var _fade_start := 46.0
var _lod_ratios := [1.0, 0.62, 0.3]
var _trample_radius := 1.7
var _trample_bend := 0.42
var _sway_amplitude := 0.13
var _sway_frequency := 6.5
var _idle_strength := 0.55
var _trample_ref_speed := 4.6
var _wind := 0.0
var _lod_interval := 0.12

## 三级 LOD 共用一份材质：uniform 只更新一次就对整个草地生效。
var _material: ShaderMaterial
## 每块一份记录：{ "center": Vector2, "nodes": Array[MultiMeshInstance3D], "level": int }
var _chunks: Array = []
## 传给 shader 的角色数组，长度恒为 MAX_TRAMPLERS。
var _trample_data := PackedVector4Array()
## 角色 → { "pos": 上帧位置, "motion": 平滑后的运动量 }。跨帧保留才能算出速度。
var _trample_state: Dictionary = {}
## 玩家观察点缓存。由 _update_trample 顺带刷新。
var _observer_points: Array = []
var _time := 0.0
var _lod_timer := 0.0
## 临时诊断：每 40 次刷新打印一次观察点与点亮块数。
var _dbg_tick := 0


func _ready() -> void:
	if Engine.is_editor_hint() and not editor_preview_enabled:
		return
	_load_params()
	_build()
	# 【进树的第一帧之前就把 LOD 摆到与真实距离一致的状态】
	# 否则要等 _lod_interval（0.12 秒）后第一次 _update_visibility() 才纠偏，
	# 纠偏那一瞬间整片草地一起换密度 —— 这就是"第一次走进草地时草少了一批"。
	_refresh_observers()
	_update_visibility()
	# Godot 4 的 _process 默认不跑，必须显式打开；编辑器里则明确关掉，
	# 免得预览场景下每帧去做距离剔除。
	set_process(not Engine.is_editor_hint())


func _process(delta: float) -> void:
	_dbg_tick += 1
	if _chunks.is_empty():
		return
	_time += delta
	_material.set_shader_parameter("u_time", _time)
	_update_trample(delta)
	_lod_timer += delta
	if _lod_timer >= _lod_interval:
		_lod_timer = 0.0
		_update_visibility()


# ---------------------------------------------------------------- 参数

func _load_params() -> void:
	_arena = ArenaUtil.get_params()
	_radius = maxf(float(_arena.get("decor_radius", 56.0)), 1.0)
	_density = maxf(ConfigUtil.get_float("decor.grass_density", 1.0), 0.0)
	_max_instances = maxi(ConfigUtil.get_int("decor.grass_max_instances", 30000), 0)
	_scale_min = maxf(ConfigUtil.get_float("decor.grass_scale_min", 0.65), 0.05)
	_scale_max = maxf(ConfigUtil.get_float("decor.grass_scale_max", 1.35), _scale_min)
	_cluster_size = clampi(ConfigUtil.get_int("decor.grass_cluster_size", 4), 1, 32)
	_cluster_radius = maxf(ConfigUtil.get_float("decor.grass_cluster_radius", 0.42), 0.0)
	_patch_frequency = clampf(
		ConfigUtil.get_float("decor.grass_patch_frequency", 0.045), 0.001, 1.0
	)
	_bare_ratio = clampf(ConfigUtil.get_float("decor.grass_bare_ratio", 0.25), 0.0, 1.0)
	_seed = ConfigUtil.get_int("decor.grass_seed", 18473)
	_chunk_target = clampi(ConfigUtil.get_int("decor.grass_chunk_target", 25), 1, 144)
	var distances := ConfigUtil.get_float_array("decor.grass_lod_distances", [14.0, 34.0])
	if distances.size() >= 2:
		_lod_distances = [
			maxf(float(distances[0]), 1.0),
			maxf(float(distances[1]), float(distances[0]) + 1.0)
		]
	_cull_distance = maxf(
		ConfigUtil.get_float("decor.grass_cull_distance", 72.0), _lod_distances[1] + 2.0
	)
	# 淡出必须在剔除之前走完，否则会被"整块突然消失"打断。
	_fade_start = clampf(
		ConfigUtil.get_float("decor.grass_fade_start", 46.0), 1.0, _cull_distance - 1.0
	)
	var ratios := ConfigUtil.get_float_array("decor.grass_lod_ratios", [1.0, 0.62, 0.3])
	if ratios.size() >= 3:
		_lod_ratios = ratios
	_trample_radius = maxf(ConfigUtil.get_float("decor.grass_trample_radius", 1.7), 0.05)
	_trample_bend = maxf(ConfigUtil.get_float("decor.grass_trample_bend", 0.42), 0.0)
	_sway_amplitude = maxf(ConfigUtil.get_float("decor.grass_sway_amplitude", 0.13), 0.0)
	_sway_frequency = maxf(ConfigUtil.get_float("decor.grass_sway_frequency", 6.5), 0.0)
	_idle_strength = clampf(ConfigUtil.get_float("decor.grass_idle_strength", 0.55), 0.0, 1.0)
	_trample_ref_speed = maxf(ConfigUtil.get_float("decor.grass_trample_ref_speed", 4.6), 0.1)
	_wind = maxf(ConfigUtil.get_float("decor.grass_wind", 0.0), 0.0)
	_lod_interval = maxf(ConfigUtil.get_float("decor.grass_lod_interval", 0.12), 0.02)


# ---------------------------------------------------------------- 构建

func _build() -> void:
	_material = _make_material()
	var meshes := []
	for index in LOD_BLADES.size():
		var mesh := _make_tuft(int(LOD_BLADES[index]), float(LOD_WIDTH[index]))
		# 【必须挂上去】这是三级共用的那一份 ShaderMaterial。
		# 漏掉这一步，草会整个退回引擎的默认材质：纯白、没有顶点色、没有淡出、
		# 没有踩踏与摆动 —— 而 _process 里那些 uniform 依然在每帧被老老实实地更新，
		# 所以从代码上看不出任何异常。
		mesh.surface_set_material(0, _material)
		meshes.append(mesh)
	var side := _chunk_side()
	var total := _target_count()
	# 分桶：同一块的实例放在一起，之后每块按前缀切出三级 LOD。
	# 生成顺序本来就是随机的，所以取前缀就是一次均匀降采样，不需要额外打乱。
	var buckets: Dictionary = {}
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	# 【为什么不能均匀撒点】均匀铺满之后，画面就是一张绿绒地毯：视线找不到任何
	# 疏密节奏，越远越像噪点。自然界的草成片长 —— 有茂密的草甸，也有几乎裸露的
	# 土斑，而草甸里又是一撮一撮的。这里用两级尺度还原：
	#   低频噪声 → 几十米宽的"哪里有草"，smoothstep 拉开对比，做成要么密要么光；
	#   每丛一次撒几株 → 一两米尺度的"抱团"，落点周围散开成一小撮。
	var noise := FastNoiseLite.new()
	noise.seed = _seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = _patch_frequency
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5
	var placed := 0
	# 拒绝采样必须设上限：湖 / 主路 / 遗迹把整片圆盖住时（配置写错很容易发生），
	# 没有上限就是一次死循环，而它发生在场景加载期，表现为"游戏卡在黑屏"。
	# 现在多了密度噪声这一层筛选，命中率进一步下降，所以上限要跟着放宽。
	var attempts := 0
	var attempt_limit := total * 16 + 8192
	while placed < total and attempts < attempt_limit:
		attempts += 1
		var x := rng.randf_range(-_radius, _radius)
		var z := rng.randf_range(-_radius, _radius)
		if x * x + z * z > _radius * _radius:
			continue
		if ArenaUtil.is_masked_out(_arena, x, z):
			continue
		# 噪声 [-1, 1] → 密度 [bare_ratio, 1]。中间调压掉是必要的：
		# 不做 smoothstep 的话噪声平均值会让整片地都停在"中等密度"，等于白做。
		# 区间取 [0.20, 0.68]：噪声的典型值就集中在中段，窗口压在 0.34~0.72 时
		# 会让半个场地落到 bare 那一侧，出来是大片空地而不是疏密相间。
		var patch := clampf((noise.get_noise_2d(x, z) + 1.0) * 0.5, 0.0, 1.0)
		var local_density := lerpf(_bare_ratio, 1.0, smoothstep(0.20, 0.68, patch))
		if rng.randf() > local_density:
			continue
		# 一丛的成员共享同一个高度基准：同一撮草长得差不多高，才有"一丛"的形状；
		# 逐株各自随机高度的话，凑在一起仍然是一把散开的牙签。
		var height_base := rng.randf()
		for member in range(_cluster_size):
			if placed >= total:
				break
			var offset := Vector2.ZERO
			if member > 0:
				var offset_angle := rng.randf_range(0.0, TAU)
				# sqrt 让点在圆内均匀分布，否则会过度堆在圆心。
				var offset_radius := _cluster_radius * sqrt(rng.randf())
				offset = Vector2(cos(offset_angle), sin(offset_angle)) * offset_radius
			var cx := x + offset.x
			var cz := z + offset.y
			if cx * cx + cz * cz > _radius * _radius:
				continue
			if ArenaUtil.is_masked_out(_arena, cx, cz):
				continue
			var key := Vector2i(
				int(floor((cx + _radius) / side)), int(floor((cz + _radius) / side))
			)
			if not buckets.has(key):
				buckets[key] = []
			var bucket: Array = buckets[key]
			bucket.append(_instance_transform(rng, cx, cz, height_base))
			placed += 1
	for key in buckets.keys():
		var transforms: Array = buckets[key]
		_spawn_chunk(key as Vector2i, side, transforms, meshes)
	buckets.clear()


## 密度写成"每平方米几株"而不是一个总数：半径 41 米的内城和半径 86 米的湖畔
## 不该共用同一个数字，换图时也不该有人记得去改它。
func _target_count() -> int:
	# 0.86：粗略扣掉湖 / 主路 / 遗迹这些不长草的保留区。
	var area := PI * _radius * _radius * 0.86
	var wanted := int(round(area * _density))
	# 竞技场里手工调过的 grass_count 仍然算数，但只作下限 ——
	# 那张表记的是"稀疏图刻意少放草"的旧约定，密度提上来之后基本都被盖过。
	var manual := maxi(int(_arena.get("grass_count", 0)), 0)
	return clampi(maxi(wanted, manual), 0, _max_instances)


## 分块边长：由"目标块数"反推，所以大小图都稳定在二十几块（约二十几个 draw call）。
func _chunk_side() -> float:
	var divisions := maxi(int(round(sqrt(float(_chunk_target)))), 2)
	return maxf(_radius * 2.0 / float(divisions), 6.0)


func _instance_transform(
	rng: RandomNumberGenerator, x: float, z: float, height_base: float
) -> Transform3D:
	# 横向尺寸与高度解耦，而且用两种不同的分布：
	#   横向 spread —— 均匀，决定这一株"摊开多宽"；
	#   高度 —— 丛基准（同丛相近，见 _build）+ 一个 pow 偏斜的扰动（多数偏矮）。
	# 原来的写法把 y 直接等同于 scale_factor，整片地的高度就全挤在均值附近，
	# 加上横向缩放也跟着变，看起来就是一张高低整齐的绿毯。
	var spread := rng.randf_range(_scale_min, _scale_max)
	var skew := pow(rng.randf(), 2.2)
	var height_factor := spread * lerpf(0.60, 1.15, lerpf(height_base, skew, 0.45))
	# 不能叫 basis / scale：Node3D 自带同名属性，会触发 SHADOWED_VARIABLE_BASE_CLASS。
	var tuft_basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(
		Vector3(spread * rng.randf_range(0.82, 1.2), height_factor, spread)
	)
	var surface := TerrainFieldUtil.height_at(x, z) + GROUND_OFFSET
	return Transform3D(tuft_basis, Vector3(x, surface, z))


## 一块草地 = 三级 MultiMesh，但同一时刻只有一级 visible，
## 于是每块的开销恒为一个 draw call。
func _spawn_chunk(key: Vector2i, side: float, transforms: Array, meshes: Array) -> void:
	var count := transforms.size()
	if count <= 0:
		return
	var center := Vector2(
		-_radius + (float(key.x) + 0.5) * side,
		-_radius + (float(key.y) + 0.5) * side
	)
	var nodes: Array = []
	for level in meshes.size():
		var ratio := float(_lod_ratios[mini(level, _lod_ratios.size() - 1)])
		var level_count := clampi(int(round(float(count) * ratio)), 1, count)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = meshes[level]
		multimesh.instance_count = level_count
		for index in range(level_count):
			multimesh.set_instance_transform(index, transforms[index])
		# 【AABB 必须留余量】shader 会把叶尖推开最多半米，而引擎的视锥剔除
		# 用的是这个盒子。给得太紧会出现"走近了草反而整块消失"。
		multimesh.custom_aabb = AABB(
			Vector3(center.x - side * 0.5 - 1.5, -4.0, center.y - side * 0.5 - 1.5),
			Vector3(side + 3.0, 14.0, side + 3.0)
		)
		var instance := MultiMeshInstance3D.new()
		instance.name = "Grass_%d_%d_L%d" % [key.x, key.y, level]
		instance.multimesh = multimesh
		# 草不投影：上万株双面片进阴影 pass 等于按实例数再画一遍，
		# 而十几厘米高的草在画面里根本没有可辨的影子。
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# 【先全部隐藏】分块建好时不显示任何一级，由 _update_visibility() 按真实
		# 距离点亮。反过来做（默认显示最高那一级）会让整片草地在第一次 LOD 计算
		# 之前按 100% 密度画出来，计算过后远处又被整片降到 30% —— 玩家看到的就是
		# "走进草地时忽然少掉一大批草"，而此后 LOD 已经稳定，再走也不复现。
		instance.visible = false
		add_child(instance)
		nodes.append(instance)
	_chunks.append({"center": center, "nodes": nodes, "level": -1})


# ---------------------------------------------------------------- 每帧

## 收集角色位置 → 算运动量 → 取最近的若干个塞进 shader。
func _update_trample(delta: float) -> void:
	if _trample_data.size() != MAX_TRAMPLERS:
		_trample_data.resize(MAX_TRAMPLERS)
	var previous_observers := _observer_points
	var focus := _refresh_observers()
	# 【观察点一变，LOD 必须立刻重算，不能等定时器】
	# 玩家刚生成、切场景相机都会走到这里。若还等那 0.12 秒的 tick，
	# 这段窗口里整片草地挂的是上一份可见性 —— 玩家看到的是"草地是空的，
	# 过一下才长出来"，而离屏截图流程更是直接拍到一片空草地。
	# _refresh_observers 每次都重新绑定数组，所以这里比较的是新旧两份内容。
	if previous_observers != _observer_points:
		_update_visibility()
	var candidates: Array = []
	for node in _trample_sources():
		var body := node as Node3D
		var position := body.global_position
		var state: Dictionary = _trample_state.get(body, {})
		if state.is_empty():
			state = {"pos": position, "motion": 0.0}
			_trample_state[body] = state
		var previous: Vector3 = state["pos"]
		var speed := Vector2(position.x - previous.x, position.z - previous.z).length() \
			/ maxf(delta, 0.0001)
		var target := clampf(speed / _trample_ref_speed, 0.0, 1.0)
		# 平滑，避免单帧抖动（击退 / 传送）让草瞬间弹开。
		var motion := lerpf(float(state["motion"]), target, clampf(delta * 6.0, 0.0, 1.0))
		state["motion"] = motion
		state["pos"] = position
		candidates.append([
			Vector2(position.x - focus.x, position.z - focus.y).length_squared(),
			position.x, position.z, motion
		])
	# 敌人会不断生成和销毁，状态表必须跟着清理，否则会越攒越多。
	for body in _trample_state.keys():
		if not is_instance_valid(body):
			_trample_state.erase(body)
	candidates.sort_custom(_nearer)
	var count := mini(candidates.size(), MAX_TRAMPLERS)
	for index in range(MAX_TRAMPLERS):
		if index < count:
			var item: Array = candidates[index]
			var motion := float(item[3])
			# 站着不动时强度降到 idle：脚下依然是被踩住的样子，但不再摆动。
			_trample_data[index] = Vector4(
				float(item[1]), float(item[2]),
				_idle_strength + (1.0 - _idle_strength) * motion,
				motion
			)
		else:
			_trample_data[index] = Vector4.ZERO
	_material.set_shader_parameter("u_trample", _trample_data)
	_material.set_shader_parameter("u_trample_count", count)


## 逐块决定 LOD 与可见性。距离取"到玩家的最小值"。
func _update_visibility() -> void:
	if _observer_points.is_empty():
		return
	var near_distance := float(_lod_distances[0])
	var mid_distance := float(_lod_distances[1])
	var near_squared := near_distance * near_distance
	var mid_squared := mid_distance * mid_distance
	var cull_squared := _cull_distance * _cull_distance
	var side := _chunk_side()
	for chunk in _chunks:
		var center: Vector2 = chunk["center"]
		# 【量的是"到这块草的最近距离"，不是到块中心的距离】
		# 大图上 side 能到 34 米，比中距阈值还大。按中心距离算的话，整块的 LOD
		# 只取决于那一个点：站在块中央时整块拿最高细节，走出 14 米整块又一起降
		# 级，一整片草同时少掉四成。改成矩形距离之后，切换点才落在"真的走到离
		# 这片草这么近"的位置上。
		var nearest := INF
		for point in _observer_points:
			var dx := maxf(absf(float(point.x) - center.x) - side * 0.5, 0.0)
			var dz := maxf(absf(float(point.y) - center.y) - side * 0.5, 0.0)
			nearest = minf(nearest, dx * dx + dz * dz)
		var current := int(chunk["level"])
		# 滞后：已经点亮的块放宽 12% 才降级。玩家沿着 LOD 边界走时，没有滞后就会
		# 在两级之间反复横跳，每跳一次就是一次整片密度突变。
		var stay := 1.12 if current >= 0 else 1.0
		var level := -1
		if nearest <= near_squared * stay:
			level = 0
		elif nearest <= mid_squared * stay:
			level = 1
		elif nearest <= cull_squared * stay:
			level = 2
		if level == current:
			continue
		chunk["level"] = level
		var nodes: Array = chunk["nodes"]
		for index in nodes.size():
			var instance: Node3D = nodes[index]
			instance.visible = (index == level)


## 刷新玩家观察点，并返回"取最近角色"用的参考点。
func _refresh_observers() -> Vector2:
	_observer_points = []
	var sum := Vector2.ZERO
	var count := 0
	for node in _player_nodes():
		var body := node as Node3D
		var point := Vector2(body.global_position.x, body.global_position.z)
		_observer_points.append(point)
		sum += point
		count += 1
	if count == 0:
		# 还没刷出玩家（例如刚进场景的第一帧）时用主视口相机顶上，
		# 免得整片草在第一帧被判成"超出剔除距离"而闪一下。
		var viewport := get_viewport()
		var camera := viewport.get_camera_3d() if viewport != null else null
		if camera != null:
			_observer_points.append(
				Vector2(camera.global_position.x, camera.global_position.z)
			)
			return _observer_points[0] as Vector2
	if _dbg_tick % 60 == 1:
		var lit := 0
		for chunk in _chunks:
			if int(chunk["level"]) >= 0:
				lit += 1
		print("[grass] proc帧=", _dbg_tick, " 观察点=", _observer_points.size(),
			" 玩家=", _player_nodes().size(), " 点亮块=", lit)
		return Vector2.ZERO
	return sum / float(count)


func _player_nodes() -> Array:
	var tree := get_tree()
	if tree == null:
		return []
	return tree.get_nodes_in_group("player")


func _trample_sources() -> Array:
	var tree := get_tree()
	var out := []
	if tree == null:
		return out
	for group_name in TRAMPLE_GROUPS:
		for node in tree.get_nodes_in_group(String(group_name)):
			if node is Node3D:
				out.append(node)
	return out


static func _nearer(a: Array, b: Array) -> bool:
	return float(a[0]) < float(b[0])


# ---------------------------------------------------------------- 资源

func _make_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GrassShader
	material.set_shader_parameter("u_fade_start", _fade_start)
	material.set_shader_parameter("u_fade_end", _cull_distance)
	material.set_shader_parameter("u_trample_radius", _trample_radius)
	material.set_shader_parameter("u_trample_bend", _trample_bend)
	material.set_shader_parameter("u_sway_amplitude", _sway_amplitude)
	material.set_shader_parameter("u_sway_frequency", _sway_frequency)
	material.set_shader_parameter("u_wind", _wind)
	material.set_shader_parameter("u_tuft_height", TUFT_HEIGHT)
	material.set_shader_parameter("u_time", 0.0)
	material.set_shader_parameter("u_trample_count", 0)
	_trample_data.resize(MAX_TRAMPLERS)
	material.set_shader_parameter("u_trample", _trample_data)
	return material


## 一簇草：blades 片叶子绕一圈，越远的级别叶片越少、单叶越宽。
func _make_tuft(blades: int, width_scale: float) -> ArrayMesh:
	var builder := LowPolyMeshUtil.begin()
	var root := Color(0.10, 0.26, 0.085, 1.0)
	var tip_color := Color(0.27, 0.46, 0.13, 1.0)
	for index in range(blades):
		_push_blade(builder, index, blades, width_scale, root, tip_color)
	return LowPolyMeshUtil.commit(builder)


## 一片叶：SEGMENTS 段折线，越往上越向外弯、越窄，叶尖收成一个点。
##
## 【为什么不是一整个三角形】一片叶如果只是一个底宽顶尖的直立三角形，
## 侧对相机就是一根细长的尖刺 —— 放大到两万株，整片地就变成"插满刀子"。
## 折线弯出弧度之后，同一片叶从任何角度都能看到受光的宽面与向外的弯势，
## 这是草看起来像草而不是像碎玻璃的关键。
func _push_blade(
	builder: LowPolyMesh.Builder, index: int, blades: int, width_scale: float,
	root: Color, tip_color: Color
) -> void:
	var angle := TAU * float(index) / float(blades) + 0.7
	var outward := Vector3(cos(angle), 0.0, sin(angle))
	var across_dir := Vector3(-sin(angle), 0.0, cos(angle))
	var tilt := 0.55 + 0.22 * float(index % 2)
	# 簇内每片叶的高度也要错开：三片齐刷刷一样高，远看就是一排牙签。
	# 上限取 0.92，给下面 apex 的抬升留余量，整片叶仍然不超过 TUFT_HEIGHT。
	var height_ratio := 0.60 + 0.32 * float((index * 5 + 2) % 3) * 0.5
	var height := TUFT_HEIGHT * height_ratio
	var width := 0.052 * width_scale
	var prev_center := Vector3.ZERO
	var prev_left := Vector3.ZERO
	var prev_right := Vector3.ZERO
	var prev_color := root
	# 从 0 起：step 0 是贴地的那一圈（ratio = 0 → y = 0），叶根才不会悬空。
	for step in range(0, BLADE_SEGMENTS + 1):
		var ratio := float(step) / float(BLADE_SEGMENTS)
		var bend := tilt * ratio * ratio
		# 水平外扩量必须和叶高匹配：0.30 米外扩配 0.4 米的叶高，叶子会歪到快
		# 贴地，远看是一片倒伏的碎玻璃。0.11 米是"站得住、叶尖自然外垂"的量。
		var center := outward * (0.03 + bend * 0.11) + Vector3(0.0, height * ratio, 0.0)
		# 叶根 = width，到腰线微微鼓出一点点，再一路收到叶尖的 28%。
		var half := width * (1.0 + 0.25 * sin(PI * ratio)) * (1.0 - 0.72 * ratio * ratio)
		var left := center - across_dir * half
		var right := center + across_dir * half
		var color := root.lerp(tip_color, ratio)
		if step == 0:
			prev_center = center
			prev_left = left
			prev_right = right
			prev_color = color
			continue
		LowPolyMeshUtil.push_quad(
			builder, prev_left, prev_right, right, left, prev_color
		)
		prev_center = center
		prev_left = left
		prev_right = right
		prev_color = color
	# 叶尖：最后一段收成一个点，再往上抽一点点。
	# 用 min 和 TUFT_HEIGHT 封顶 —— shader 的弯曲权重是 y / u_tuft_height，
	# 超过了会被 clamp 成刚性平移；但不能直接写成 TUFT_HEIGHT，
	# 那会把每一片叶的顶都钉在同一高度，一簇草就成了平头。
	var apex := prev_center + outward * 0.03
	apex.y = minf(height + TUFT_HEIGHT * 0.09, TUFT_HEIGHT)
	LowPolyMeshUtil.push_triangle(builder, prev_left, prev_right, apex, prev_color)

