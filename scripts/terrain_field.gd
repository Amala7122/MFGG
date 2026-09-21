@tool
extends StaticBody3D
class_name TerrainField
## 战场地形：把原来的"平板地面 + 6 个球体假山（长方体碰撞，等于垂直墙）"
## 换成一张程序化高度场。
##
## 三条硬约束（改动前务必读）：
##
## 1. 坡度必须可走。敌人没有寻路，只会朝玩家直线推进，任何"墙式"结构都会
##    让它们卡死在障碍前。这里用 (1-d²)² 钟形剖面，最陡处约 23°~29°，
##    远低于 Godot 默认 45° 的可行走上限。
##
## 2. 道路 / 湖 / 遗迹 / 营地 / 出生点必须保持 0 高度。这些陈设全部按
##    y=0 手工摆放，一旦抬升就会悬空或埋地。
##
## 3. 高度函数是纯静态的。草地、树木、刷怪点都直接查询 height_at() 对齐，
##    不存在"两套地形真相"。
##
## 另有一条容易踩的坑：三角形绕序必须让法线朝上。
## Godot 认定的正面法线是 cross(v2-v0, v1-v0)，写反了会同时造成两个后果 ——
## 碰撞射线穿透地面（画面还在，极难发现），以及**导航网格烘焙把整片地形
## 判为不可行走**（烘焙"成功"但只产出掩体顶面那几十个多边形）。
## 这里已经修正，并且下面两处都保留了注释说明。

const ArenaUtil := preload("res://scripts/arena.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")

## 默认地形覆盖范围（"湖畔遗址"竞技场的大小，与原 Ground 的 120×120 平面一致）。
const DEFAULT_EXTENT := 60.0
## 网格格距（配置 terrain.cell_size，见 _cell_size()）。1 米时与物理格距一致，
## 避免碰撞与画面错位；分段数由体量推出来，所以竞技场改大小不会顺带改变格距。

## 默认山丘：[中心x, 中心z, 半径x, 半径z, 高度]。
## 【只在配置缺失时使用】—— 正常情况下山丘由竞技场提供。
##
## 位置取自原来 6 个 SphereMesh 假山，剖面换成可攀爬的钟形。
## 注意第一座：原来的 HillNW 在 (-47, -43)，中心距离遗迹区角点 (-40, -40)
## 只有 7.6 米。遗迹需要保持 0 高度，于是平坦遮罩会在 6 米内把这 4.8 米的
## 山体硬压回去 —— 实测制造了 52° 的陡坡墙（敌人会被卡住）。
## 向外挪到 (-52, -49) 后，山脚在遗迹角点处已衰减到 0.04 米，问题消失。
const DEFAULT_HILLS: Array = [
	[-52.0, -49.0, 17.0, 14.0, 5.0],
	[45.0, -44.0, 22.0, 16.0, 6.0],
	[-53.0, 5.0, 14.0, 24.0, 5.0],
	[53.0, 2.0, 14.0, 25.0, 5.0],
	[-38.0, 48.0, 24.0, 15.0, 5.5],
	[38.0, 49.0, 22.0, 14.0, 5.0],
]

## 默认遮罩。同样只在配置缺失时使用；[x0, x1, z0, z1, margin]。
const DEFAULT_MASK_RECTS: Array = [
	[9.0, 40.0, 8.0, 31.0, 8.0],          # 湖
	[-3.8, 3.8, -48.0, 34.0, 7.0],        # 主路
	[-40.0, -18.0, -40.0, -18.0, 6.0],    # 遗迹
	[-1.0, 9.0, -16.0, -6.0, 5.0],        # 营地
]
## [cx, cz, radius, margin]
const DEFAULT_MASK_CIRCLES: Array = [
	[0.0, 13.0, 3.0, 4.0],                # 玩家出生点
]

## 当前竞技场。由 Arena 决定，在第一次 height_at() 时惰性应用 ——
## 节点的 _ready() 顺序不确定，惰性初始化能保证"谁先用谁负责初始化"。
static var _arena_params: Dictionary = {}
static var _hills_table: Array = DEFAULT_HILLS
static var _mask_rects: Array = DEFAULT_MASK_RECTS
static var _mask_circles: Array = DEFAULT_MASK_CIRCLES
static var _extent := DEFAULT_EXTENT
## 已应用的竞技场 id。不能只用一个 bool —— 静态状态在一次【进程】内是持续的，
## 而阶段推进是靠重载场景来换竞技场的：只记 "已应用过" 的话，第二次加载会
## 沿用地形早已换掉的上一个竞技场。
static var _applied_id := ""


# ---------------------------------------------------------------- 竞技场

## 应用竞技场参数。构建器不需要主动调用：height_at() 第一次被调用时会惰性应用，
## 所以无论场景树里谁先 _ready()，拿到的都是同一套地形。
static func apply_arena(params: Dictionary) -> void:
	_arena_params = params
	_extent = clampf(float(params.get("extent", DEFAULT_EXTENT)), 20.0, 120.0)
	# 一律用"键是否存在"判断，而不是"结果是否为空" ——
	# `"mask_rects": []` 的语义是【明确不要矩形遮罩】（风蚀沙丘就是这样一片开阔地），
	# 若按"空就当缺省"处理，它会被套回湖畔那套湖/路/遗迹遮罩，在绝对坐标上
	# 凭空压平三块区域。这两种情况必须区分。
	_hills_table = ArenaUtil.generate_hills(params) if params.has("hills") or params.has("hill_layout") \
		else DEFAULT_HILLS
	_mask_rects = ArenaUtil.rect_masks(params) if params.has("mask_rects") else DEFAULT_MASK_RECTS
	_mask_circles = ArenaUtil.circle_masks(params) if params.has("mask_circles") \
		else DEFAULT_MASK_CIRCLES
	_applied_id = String(params.get("_id", ""))


static func _ensure_arena() -> void:
	var wanted := ArenaUtil.resolve_id()
	if _applied_id == wanted:
		return
	apply_arena(ArenaUtil.get_params())


## 当前地形覆盖范围（各竞技场可以不同）。
static func get_extent() -> float:
	_ensure_arena()
	return _extent


## 当前网格分段数。由体量按固定格距推出来。
static func get_steps() -> int:
	_ensure_arena()
	return maxi(roundi(_extent * 2.0 / _cell_size()), 8)


static func _cell_size() -> float:
	return maxf(ConfigUtil.get_float("terrain.cell_size", 1.0), 0.25)


## 当前山丘表（探针 / 调试用）。
static func get_hills() -> Array:
	_ensure_arena()
	return _hills_table


## 当前竞技场参数（探针 / 调试用）。
static func get_arena_params() -> Dictionary:
	_ensure_arena()
	return _arena_params


# ---------------------------------------------------------------- 高度场（纯函数）

## 世界坐标 (x, z) 处的地面高度。
static func height_at(x: float, z: float) -> float:
	_ensure_arena()
	return (_rolling(x, z) + _hills(x, z)) * _flat_mask(x, z)


## 地表法线。用相邻采样差分而不是网格法线，缓坡上不会出现条纹。
static func normal_at(x: float, z: float) -> Vector3:
	var e := 0.5
	var dx := height_at(x + e, z) - height_at(x - e, z)
	var dz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


## 起伏（幅度之和约 ±1.5 米，坡度不到 4°）。
##
## 【振幅】来自配置 terrain.rolling_amplitudes —— 它就是"起伏量程"，与
## navigation.agent_max_slope / agent_max_climb 强耦合，是唯一会改变可走性的旋钮。
##
## 【频率与相位】刻意留在代码里：改它等于换一张地形，而不是调难度。
static func _rolling(x: float, z: float) -> float:
	var amplitudes := _rolling_amplitudes()
	var h := sin(x * 0.078) * cos(z * 0.064) * float(amplitudes[0])
	h += sin(x * 0.163 + 1.7) * cos(z * 0.152 - 0.6) * float(amplitudes[1])
	h += sin((x + z) * 0.049 - 2.1) * float(amplitudes[2])
	return h


## 三层起伏的振幅。缓存一份：_rolling 是纯函数，会被每张地形逐顶点调用上万次，
## 不能每次都去点号查找配置。
static var _roll_cache: Array = []

static func _rolling_amplitudes() -> Array:
	if _roll_cache.is_empty():
		_roll_cache = ConfigUtil.get_float_array("terrain.rolling_amplitudes", [0.85, 0.38, 0.32])
	return _roll_cache


## 山丘。用 (1-d²)² 而不是 cos 或 sqrt：它在边缘处斜率为 0、在 d≈0.58 处最陡，
## 因此山脚平滑接入平地、坡面又足够缓 —— 这正是"能走上去"的关键。
static func _hills(x: float, z: float) -> float:
	var h := 0.0
	for hill in _hills_table:
		var dx := (x - float(hill[0])) / float(hill[2])
		var dz := (z - float(hill[1])) / float(hill[3])
		var d := sqrt(dx * dx + dz * dz)
		if d >= 1.0:
			continue
		var falloff := 1.0 - d * d
		h += float(hill[4]) * falloff * falloff
	return h


## 建筑区遮罩：0 = 完全压平，1 = 允许完整起伏。
## 遮罩表来自竞技场；缺省时用 DEFAULT_MASK_* （与改动前逐点一致）。
static func _flat_mask(x: float, z: float) -> float:
	var mask := 1.0
	for rect in _mask_rects:
		var r := rect as Array
		mask = minf(mask, _rect_mask(
			x, z, float(r[0]), float(r[1]), float(r[2]), float(r[3]), float(r[4])
		))
	for circle in _mask_circles:
		var c := circle as Array
		mask = minf(mask, _circle_mask(
			x, z, float(c[0]), float(c[1]), float(c[2]), float(c[3])
		))
	return mask


## 该点是否已被完全压平（湖面 / 主路 / 遗迹内部）。刷怪锚点校验用。
static func is_flat_at(x: float, z: float) -> bool:
	_ensure_arena()
	return _flat_mask(x, z) <= 0.001


static func _rect_mask(
	x: float, z: float, x0: float, x1: float, z0: float, z1: float, margin: float
) -> float:
	var dx := maxf(maxf(x0 - x, x - x1), 0.0)
	var dz := maxf(maxf(z0 - z, z - z1), 0.0)
	return smoothstep(0.0, margin, sqrt(dx * dx + dz * dz))


static func _circle_mask(
	x: float, z: float, cx: float, cz: float, radius: float, margin: float
) -> float:
	var dx := x - cx
	var dz := z - cz
	return smoothstep(radius, radius + margin, sqrt(dx * dx + dz * dz))


# ---------------------------------------------------------------- 构建

## 原来的草地色，作为竞技场未指定 ground_color 时的兜底。
const DEFAULT_GROUND_COLOR := Color(0.19, 0.46, 0.16, 1.0)

## 本竞技场的体量 / 分段数 / 地面色。缓存成实例字段：下面两个构建函数在
## 双重循环里会读很多次，反复穿过静态访问器不值得。
## 注意不要叫 _extent —— 静态区已经有一个同名变量，而 GDScript 的静态变量与
## 实例变量共用名字解析空间，重名会直接编译失败（本次就踩了一次）。
var _build_extent := DEFAULT_EXTENT
var _steps := 120
var _material_color := DEFAULT_GROUND_COLOR
var _highland_color := Color(0.38, 0.53, 0.24, 1.0)
var _dry_color := Color(0.46, 0.50, 0.23, 1.0)
@export var editor_preview_enabled := false


func _ready() -> void:
	if Engine.is_editor_hint() and not editor_preview_enabled:
		return
	# 加入导航源分组：navigation_region.gd 按组递归收集几何来烘焙导航网格。
	if not Engine.is_editor_hint():
		add_to_group("nav_source")
	_build_extent = get_extent()
	_steps = get_steps()
	_material_color = _resolve_ground_color()
	_highland_color = _resolve_palette_color("ground_high_color", _material_color.lightened(0.16))
	_dry_color = _resolve_palette_color("ground_dry_color", _material_color.lerp(Color(0.55, 0.48, 0.22), 0.22))
	var heights := _sample_heights()
	_facet_visual_mesh()
	if not Engine.is_editor_hint():
		_build_collision(heights)


## 地面主色由竞技场决定（草地绿 / 岩层灰 / 沙黄 …），缺省回退到原来的草地色。
func _resolve_ground_color() -> Color:
	var value: Variant = get_arena_params().get("ground_color", null)
	if value is Array and (value as Array).size() >= 4:
		var color := value as Array
		return Color(float(color[0]), float(color[1]), float(color[2]), float(color[3]))
	return DEFAULT_GROUND_COLOR


func _resolve_palette_color(key: String, fallback: Color) -> Color:
	var value: Variant = get_arena_params().get(key, null)
	if value is Array and (value as Array).size() >= 3:
		var color := value as Array
		return Color(float(color[0]), float(color[1]), float(color[2]), 1.0)
	return fallback


func _sample_heights() -> PackedFloat32Array:
	var step := (_build_extent * 2.0) / float(_steps)
	var data := PackedFloat32Array()
	data.resize((_steps + 1) * (_steps + 1))
	for iz in range(_steps + 1):
		var z := -_build_extent + float(iz) * step
		var row := iz * (_steps + 1)
		for ix in range(_steps + 1):
			data[row + ix] = height_at(-_build_extent + float(ix) * step, z)
	return data


func _build_visual(heights: PackedFloat32Array) -> void:
	var step := (_build_extent * 2.0) / float(_steps)
	var count := (_steps + 1) * (_steps + 1)
	var stride := _steps + 1
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(count)
	normals.resize(count)
	uvs.resize(count)
	for iz in range(stride):
		var z := -_build_extent + float(iz) * step
		for ix in range(stride):
			var x := -_build_extent + float(ix) * step
			var index := iz * stride + ix
			verts[index] = Vector3(x, heights[index], z)
			# 法线用相邻高度差分，省掉每顶点 4 次三角函数。
			var hl := heights[iz * stride + maxi(ix - 1, 0)]
			var hr := heights[iz * stride + mini(ix + 1, _steps)]
			var hb := heights[maxi(iz - 1, 0) * stride + ix]
			var hf := heights[mini(iz + 1, _steps) * stride + ix]
			normals[index] = Vector3(hl - hr, 2.0 * step, hb - hf).normalized()
			uvs[index] = Vector2(x, z) * 0.25

	var indices := PackedInt32Array()
	indices.resize(_steps * _steps * 6)
	var cursor := 0
	for iz in range(_steps):
		for ix in range(_steps):
			var a := iz * stride + ix
			var b := a + 1
			var c := a + stride
			var d := c + 1
			# 绕序必须是 (a,b,c)/(b,d,c)。Godot 认定的正面法线是
			# cross(v2-v0, v1-v0)，写反了法线就朝下 —— 后果不只是背面剔除，
			# 更严重的是【导航网格烘焙会把整片地面判为不可行走】。
			indices[cursor] = a
			indices[cursor + 1] = b
			indices[cursor + 2] = c
			indices[cursor + 3] = b
			indices[cursor + 4] = d
			indices[cursor + 5] = c
			cursor += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _make_material())
	var instance := MeshInstance3D.new()
	instance.name = "TerrainMesh"
	instance.mesh = mesh
	add_child(instance)


## 把视觉网格换成"粗采样 + 共享顶点 + 连续法线"的风格化版本。
##
## 【为什么只换视觉、不碰碰撞】
## 三条玩法契约（坡度可走 / 掩体挡视线 / 导航烘焙）全都建立在 height_at()
## 与 1 米碰撞采样之上。只降视觉采样密度，这三条天然保持成立。
##
## 【为什么不用阶梯 / Terracing】台阶的立边会成为超过 agent_max_climb(0.5m)
## 的墙，敌人直接卡死。要切面感就只能靠"粗采样 + 硬边"，不能靠台阶。
##
## 旧版把每一个 4m 网格拆成互不共享的硬边三角形；俯视时整片草地像碎玻璃，
## 遮罩过渡附近尤其明显。现在保留低密度轮廓，但让顶点与法线连续，地面先读成
## 一整块缓坡，再由树、岩石、道路和远山提供低多边形语言。
func _facet_visual_mesh() -> void:
	var instance := get_node_or_null("TerrainMesh") as MeshInstance3D
	if instance == null:
		instance = MeshInstance3D.new()
		instance.name = "TerrainMesh"
		add_child(instance)
	var step := maxf(ConfigUtil.get_float("terrain.visual_cell_size", 4.0), 0.5)
	var steps := maxi(roundi(_build_extent * 2.0 / step), 2)
	var stride := steps + 1
	var count := stride * stride
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(count)
	normals.resize(count)
	colors.resize(count)
	for iz in range(stride):
		var z := -_build_extent + minf(float(iz) * step, _build_extent * 2.0)
		for ix in range(stride):
			var x := -_build_extent + minf(float(ix) * step, _build_extent * 2.0)
			var index := iz * stride + ix
			var height := height_at(x, z)
			vertices[index] = Vector3(x, height, z)
			normals[index] = normal_at(x, z)
			colors[index] = _facet_color(x, z, height)
	var indices := PackedInt32Array()
	indices.resize(steps * steps * 6)
	var cursor := 0
	for iz in range(steps):
		for ix in range(steps):
			var a := iz * stride + ix
			var b := a + 1
			var c := a + stride
			var d := c + 1
			if (ix + iz) % 2 == 0:
				indices.set(cursor, a); indices.set(cursor + 1, b); indices.set(cursor + 2, c)
				indices.set(cursor + 3, b); indices.set(cursor + 4, d); indices.set(cursor + 5, c)
			else:
				indices.set(cursor, a); indices.set(cursor + 1, d); indices.set(cursor + 2, c)
				indices.set(cursor + 3, a); indices.set(cursor + 4, b); indices.set(cursor + 5, d)
			cursor += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _make_material())
	instance.mesh = mesh


## 地面的颜色分层：高度给明度骨架，一组低频波形形成非常克制的大块草色变化。
## 颜色在共享顶点之间连续插值，不再让每个网格单元成为一张独立色纸。
func _facet_color(x: float, z: float, height: float) -> Color:
	var height_mix := clampf((height + 0.5) / 9.5, 0.0, 0.48)
	var color := _material_color.lerp(_highland_color, height_mix)
	var broad_patch := sin(x * 0.047 + z * 0.031) * cos(z * 0.039 - x * 0.024)
	if broad_patch > 0.20:
		color = color.lerp(_dry_color, clampf((broad_patch - 0.20) * 0.15, 0.0, 0.09))
	elif broad_patch < -0.22:
		color = color.darkened(clampf((-broad_patch - 0.22) * 0.045, 0.0, 0.025))
	return color


## 碰撞直接用与画面完全相同的三角形，保证两者永不出现高度差。
##
## 没用 HeightMapShape3D 是因为它的格距固定 1 米且数据行列顺序容易弄反
## （一旦反了，画面与碰撞会整体镜像，很难排查）；凹面体虽然重一些，
## 但它是静态关卡几何的标准做法，且与网格严格一致。
func _build_collision(heights: PackedFloat32Array) -> void:
	var step := (_build_extent * 2.0) / float(_steps)
	var stride := _steps + 1
	var faces := PackedVector3Array()
	faces.resize(_steps * _steps * 6)
	var cursor := 0
	for iz in range(_steps):
		var z0 := -_build_extent + float(iz) * step
		var z1 := -_build_extent + float(iz + 1) * step
		for ix in range(_steps):
			var x0 := -_build_extent + float(ix) * step
			var x1 := -_build_extent + float(ix + 1) * step
			var a := Vector3(x0, heights[iz * stride + ix], z0)
			var b := Vector3(x1, heights[iz * stride + ix + 1], z0)
			var c := Vector3(x0, heights[(iz + 1) * stride + ix], z1)
			var d := Vector3(x1, heights[(iz + 1) * stride + ix + 1], z1)
			# 与 _build_visual 保持同一绕序（法线朝上）。
			faces[cursor] = a
			faces[cursor + 1] = b
			faces[cursor + 2] = c
			faces[cursor + 3] = b
			faces[cursor + 4] = d
			faces[cursor + 5] = c
			cursor += 6
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# 关键：ConcavePolygonShape3D 默认【只让正面参与碰撞】。
	# 程序化生成的三角形绕序一旦反了，法线就朝下，从上方打下来的射线会
	# 直接穿过整片地面（画面还在，所以极难发现）。开启双面碰撞把这个
	# 风险彻底消除，代价只是一点碰撞开销。
	shape.backface_collision = true
	var collision := CollisionShape3D.new()
	collision.name = "TerrainCollision"
	collision.shape = shape
	add_child(collision)


## 关闭背面剔除：程序化网格的三角形绕序容易搞反，而法线是我们显式写入的，
## 光照本来就正确，所以禁用剔除比赌绕序更稳。
func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	# 【必须是白色，不能是 _material_color】
	# vertex_color_use_as_albedo = true 时，最终反照率 = albedo_color × 顶点色。
	# 两边都填 ground_color 的话，0.13 会被平方成 0.015 再走 sRGB 转线性，
	# 结果约 0.0002 —— 整片地形压成死黑，而浅色的掩体与道路看起来就像浮在空气里。
	# 颜色现在只由顶点色携带（见 _facet_color），albedo_color 必须让位。
	material.albedo_color = Color.WHITE
	# 顶点色当反照率用：切面按高度分层，值是烘进顶点的，运行时代价为零。
	# vertex_color_is_srgb 不能省 —— albedo_color 走 sRGB 转线性，顶点色默认
	# 按线性直读，同一串数字会差近一个数量级。
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 0.98
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
