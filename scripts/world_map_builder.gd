@tool
extends Node3D
## 按 data/game_config.json 的 arenas.definitions.<id>.map 建造本张地图的地面内容。
##
## ── 为什么必须做这件事 ──────────────────────────────────────────
##
## 原先 Roads / Lake / AncientRuins / EnemyCamp / 22 棵树是 hyrule_field.tscn 里
## 【无条件】的静态节点：不读竞技场参数，四张图整组继承。实测 quarry 与 dunes 的
## 遮罩根本不覆盖湖的坐标，水面会凭空浮在沙丘上。加一张图必须改 .tscn ——
## 这就是"地图与程序没解耦"的真正含义。
##
## 迁完之后，新增一张图 = 只在 JSON 里加一段 map。
##
## ── 三件职责 ────────────────────────────────────────────────────
##
##   1. 按数据建造。所有落地都走 TerrainField.height_at() 吸附，
##      于是"陈设必须摆在 y≈0"这个隐含前提被彻底消除。
##   2. legacy 退役。hyrule_field.tscn 里那几组写死的节点由这里 queue_free。
##   3. 可回退。map.use_legacy_props 为 true 时保留 legacy 且不建造，
##      于是"出问题时一行切回改动前"。

const ConfigUtil := preload("res://scripts/game_config.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
const TerrainUtil := preload("res://scripts/terrain_field.gd")
const LowPolyMeshUtil := preload("res://scripts/lowpoly_mesh.gd")
const TREE_SCENE := preload("res://scenes/stylized_tree.tscn")
const PINE_SCENE := preload("res://scenes/stylized_pine.tscn")
const ValleyArt := preload("res://scripts/valley_art.gd")

## legacy 节点名：hyrule_field.tscn 里那几组写死的地面内容。
const LEGACY_NODES := ["Roads", "Lake", "AncientRuins", "EnemyCamp", "Forest"]

## 材质表。与迁移前 hyrule_field.tscn 里的 sub_resource 逐值一致，
## 只是从"写在场景里"变成了"按名字取用"。
## 材质颜色同时承担【明度分级】—— 这是本轮最重要的改动。
##
## 【为什么石材必须比地面暗】—— 上一版地面色 0.21、石材 0.23，两者几乎同值。
## 结果遗迹、地面、掩体全落在同一个中灰带里，切面与轮廓都读不出来，整张画面
## 像一块灰泥模型。明度层级是优先级里排在色彩之前的一项，它不能靠对比度
## 后处理补回来：后处理只会把"同值"整体拉开，而分级需要的是【不同值】。
##
## 现在的关系是：天空最亮 → 地面中灰 → 道路略暗于地面 → 遗迹最深。
## 于是纪念碑天然成为暗色剪影，这也是"不用发光描边也能识别"的做法。
const MATERIALS := {
	"path": {"color": Color(0.46, 0.29, 0.14), "roughness": 1.0},
	"path_edge": {"color": Color(0.26, 0.31, 0.16), "roughness": 1.0},
	"path_edge_outer": {"color": Color(0.20, 0.36, 0.14), "roughness": 1.0},
	"court": {"color": Color(0.34, 0.36, 0.31), "roughness": 0.96},
	"sand": {"color": Color(0.30, 0.28, 0.22), "roughness": 0.95},
	"water": {
		"color": Color(0.05, 0.1, 0.15, 0.82),
		"roughness": 0.22, "metallic": 0.1, "transparent": true,
	},
	"stone": {"color": Color(0.38, 0.39, 0.35), "roughness": 0.88},
	"stone_light": {"color": Color(0.52, 0.51, 0.43), "roughness": 0.86},
	"stone_dark": {"color": Color(0.22, 0.24, 0.23), "roughness": 0.9},
	"moss": {"color": Color(0.20, 0.38, 0.12), "roughness": 1.0},
	"wood": {"color": Color(0.13, 0.092, 0.062), "roughness": 0.95},
	"rock": {"color": Color(0.125, 0.133, 0.135), "roughness": 0.92},
}

var _map: Dictionary = {}
var _arena: Dictionary = {}
var _materials: Dictionary = {}


func _ready() -> void:
	var arena := ArenaUtil.get_params()
	_arena = arena
	var raw: Variant = arena.get("map", null)
	_map = raw as Dictionary if raw is Dictionary else {}
	_build_materials()
	if bool(_map.get("use_legacy_props", true)):
		print("[地图] %s 保留场景自带的地面内容（use_legacy_props = true）"
			% ArenaUtil.resolve_id())
		return
	_build_roads()
	_build_water()
	_build_props()
	_build_lights()
	_build_grove()
	if String(_arena.get("_id", "")) == "sanctum":
		var art := ValleyArt.new()
		art.name = "ValleyArt"
		add_child(art)
	_retire_legacy()


func _build_materials() -> void:
	var palette_raw: Variant = _map.get("palette", null)
	var palette := palette_raw as Dictionary if palette_raw is Dictionary else {}
	for key in MATERIALS.keys():
		var spec := MATERIALS[key] as Dictionary
		var material := StandardMaterial3D.new()
		material.albedo_color = _color(palette.get(key, null), spec.get("color", Color.WHITE) as Color)
		# 没有顶点色的基础网格默认仍是白色；道路和倒角石构则可用顶点色做
		# 连续明度变化，不再额外叠加悬浮薄片。
		material.vertex_color_use_as_albedo = true
		material.vertex_color_is_srgb = true
		material.roughness = float(spec.get("roughness", 0.9))
		material.metallic = float(spec.get("metallic", 0.0))
		if bool(spec.get("transparent", false)):
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_materials[key] = material


## 把场景里那几组写死的地面内容退役。
##
## 【为什么是 queue_free 而不是改 .tscn】—— 本项目当前没有可用编辑器
## （MCP 端口 9080 未监听），手改场景树的风险大于收益。而且留着节点、
## 只让它不参与画面，出问题时把 use_legacy_props 改成 true 就能原样回来，
## 对照实验的成本几乎为零。
func _retire_legacy() -> void:
	var scene := get_parent()
	if scene == null:
		return
	var retired := 0
	for name in LEGACY_NODES:
		var node := scene.get_node_or_null(String(name))
		if node == null:
			continue
		node.queue_free()
		retired += 1
	print("[地图] %s 改由配置建造，退役 %d 组场景自带内容"
		% [ArenaUtil.resolve_id(), retired])


## 道路：仍然贴地，但长轴方向每隔几米轻微改变中心和宽度。
## 三层铺装复用同一条轮廓，因此保留清楚的包边关系，同时不再像三把尺子叠在地上。
func _build_roads() -> void:
	var road_index := 0
	for entry in _list("roads"):
		var spec := entry as Dictionary
		var at := _point(spec, "pos", Vector2.ZERO)
		var size := _vector2(spec, "size", Vector2(6.0, 40.0))
		var yaw := deg_to_rad(float(spec.get("yaw", 0.0)))
		var lift := float(spec.get("lift", 0.014))
		var edge := maxf(float(spec.get("edge_width", 0.0)), 0.0)
		var curve_start := float(spec.get("curve_start", 0.0))
		var curve_end := float(spec.get("curve_end", 0.0))
		var seed := 131 + road_index * 977 + int(absf(at.x) * 17.0 + absf(at.y) * 31.0)
		if String(_arena.get("_id", "")) == "sanctum" and edge > 0:
			add_child(_valley_road(size, at, yaw, lift, seed, curve_start, curve_end))
			road_index += 1
			continue
		if edge > 0.0:
			add_child(_road_strip(
				"RoadOuterEdge_%.0f_%.0f" % [at.x, at.y], size, at, yaw,
				"path_edge_outer", lift - 0.007, edge * 1.8, seed, curve_start, curve_end
			))
			add_child(_road_strip(
				"RoadEdge_%.0f_%.0f" % [at.x, at.y], size, at, yaw,
				"path_edge", lift - 0.004, edge, seed, curve_start, curve_end
			))
			add_child(_road_strip(
				"Road_%.0f_%.0f" % [at.x, at.y], size, at, yaw,
				String(spec.get("material", "path")), lift, 0.0, seed, curve_start, curve_end
			))
		else:
			var node := _flat(
				"Road_%.0f_%.0f" % [at.x, at.y], size,
				Vector3(at.x, _ground(at.x, at.y) + lift, at.y),
				String(spec.get("material", "path"))
			)
			node.rotation.y = yaw
			add_child(node)
		road_index += 1


## 路宽按入口、路口和门前空间变化；轮廓与颜色均属于贴地网格。
func _valley_road(size: Vector2, at: Vector2, yaw: float, lift: float, seed: int, curve_start: float, curve_end: float) -> MeshInstance3D:
	var builder := LowPolyMeshUtil.begin()
	var count := maxi(ceili(size.y / 1.5), 8)
	var columns := [-1.0, -0.72, -0.35, 0.0, 0.35, 0.72, 1.0]
	var rows: Array = []
	var turn := Basis(Vector3.UP, yaw)
	for i in range(count + 1):
		var u := float(i) / count
		var phase := float(seed % 29) * 0.37
		var center := lerpf(curve_start, curve_end, smoothstep(0, 1, u)) + sin(u * TAU + phase) * 1.2 * sin(PI * u)
		var station := (turn * Vector3(center, 0, (u - 0.5) * size.y) + Vector3(at.x, 0, at.y))
		var width: float
		if absf(yaw) < 0.1:
			# Narrow approach, broad meeting place, constricted gate passage.
			width = 2.7 + 2.0 * exp(-pow((station.z - 64.0) / 17.0, 2.0))
			width += 4.4 * exp(-pow((station.z - 2.0) / 13.0, 2.0))
			width += 3.5 * exp(-pow((station.z + 24.0) / 9.0, 2.0))
		else:
			width = 1.65 + 1.3 * pow(sin(PI * u), 2.0)
		width += sin(u * 17.0 + phase) * 0.23
		var points: Array[Vector3] = []
		for j in columns.size():
			var col: float = columns[j]
			# A crisp irregular silhouette, not a wide interpolated green halo.
			var edge_offset := sin(i * 2.17 + j * 1.31 + phase) * 0.13
			var along_offset := sin(i * 1.71 + j * 2.19 + phase) * 0.38 * sin(PI * u)
			var local := Vector3(center + col * width + edge_offset, 0, (u - 0.5) * size.y + along_offset)
			var point := turn * local + Vector3(at.x, 0, at.y)
			point.y = _ground(point.x, point.z) + lift + 0.025
			points.append(point)
		rows.append(points)
	for i in count:
		for j in range(columns.size() - 1):
			# Flat, restrained earth facets: all vertices of a patch share one color.
			var tone := 0.98 + 0.032 * sin(i * 0.79 + j * 2.31 + seed)
			var shade := Color(0.53, 0.343, 0.183) * Color(tone, tone, tone)
			# 携带每顶点颜色，正面朝上；道路不创建独立碰撞。
			for pair in [[i, j], [i, j + 1], [i + 1, j], [i, j + 1], [i + 1, j + 1], [i + 1, j]]:
				var p: Vector3 = rows[pair[0]][pair[1]]
				builder.verts.append(p)
				builder.normals.append(TerrainUtil.normal_at(p.x, p.z))
				builder.colors.append(shade)
	var node := MeshInstance3D.new()
	node.name = "ValleyRoad_%d" % seed
	node.mesh = LowPolyMeshUtil.commit(builder)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


func _road_strip(
	name: String, size: Vector2, at: Vector2, yaw: float,
	material_key: String, lift: float, extra: float, seed: int,
	curve_start: float = 0.0, curve_end: float = 0.0
) -> MeshInstance3D:
	var segment_count := maxi(int(ceil(size.y / 4.5)), 5)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for index in range(segment_count + 1):
		var u := float(index) / float(segment_count)
		var fade := pow(sin(PI * u), 2.0)
		var phase := float(seed % 29) * 0.37
		var curve_t := smoothstep(0.0, 1.0, u)
		var center_shift := lerpf(curve_start, curve_end, curve_t) + (
			sin(u * TAU * 1.35 + phase) * 0.22
			+ sin(u * TAU * 3.7 + phase * 0.61) * 0.09
		) * fade
		var width_shift := (
			sin(u * TAU * 2.2 + phase * 1.7) * 0.18
			+ sin(u * TAU * 5.1 + phase * 0.43) * 0.07
		) * fade
		var half_width := maxf(size.x * 0.5 + extra + width_shift, 0.2)
		var z := lerpf(-size.y * 0.5 - extra, size.y * 0.5 + extra, u)
		vertices.append(Vector3(center_shift - half_width, 0.0, z))
		vertices.append(Vector3(center_shift + half_width, 0.0, z))
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
		# 大尺度、连续的路面明度变化。它属于道路网格本身，没有厚度也不会投影。
		var tone := 0.93 + 0.07 * (0.5 + 0.5 * sin(u * TAU * 2.1 + phase * 0.47))
		colors.append(Color(tone, tone, tone, 1.0))
		colors.append(Color(tone, tone, tone, 1.0))
		if index < segment_count:
			var base := index * 2
			indices.append_array(PackedInt32Array([
				base, base + 1, base + 2,
				base + 1, base + 3, base + 2,
			]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	node.material_override = _materials[material_key]
	node.position = Vector3(at.x, _ground(at.x, at.y) + lift, at.y)
	node.rotation.y = yaw
	# 道路是贴地色面，不应像实体一样投出一条薄而黑的阴影。
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## 水体：沙质底床 + 半透明水面。底床略低于水面，形成岸线层次。
func _build_water() -> void:
	for entry in _list("water"):
		var spec := entry as Dictionary
		var at := _point(spec, "pos", Vector2.ZERO)
		var base := _ground(at.x, at.y)
		var bed_size := _vector2(spec, "bed", Vector2(20.0, 14.0))
		var surface_size := _vector2(spec, "surface", Vector2(17.0, 11.0))
		add_child(_flat("LakeBed_%.0f_%.0f" % [at.x, at.y], bed_size,
			Vector3(at.x, base + 0.018, at.y), "sand"))
		add_child(_flat("Water_%.0f_%.0f" % [at.x, at.y], surface_size,
			Vector3(at.x, base + 0.04, at.y), "water"))


## 地面陈设：遗迹、营地、栈桥……都用同一套"基本体 + 材质"描述。
##
## 只在需要站上去时才建碰撞体（solid），其余一律纯视觉 ——
## 迁移前那几根遗迹立柱本来就是没有碰撞的，这里保持同样的可走性。
func _build_props() -> void:
	var props := _list("props").duplicate(true)
	if String(_arena.get("_id", "")) == "sanctum":
		props = _sanctum_ruin_plan(props)
		# 主门前后有三个尺度层：低墙、原门廊、后部高门。所有新增实体走相同碰撞路径。
		for x in [-2.0, 8.0]:
			props.append({"shape":"box", "pos":[x, -35.5], "size":[3.2, 0.35, 3.5], "material":"stone_light", "bevel":0.10, "solid":true})
		for x in [-4.0, 10.0]:
			props.append({"shape":"box", "pos":[x, -58.0], "size":[3.0, 11.8, 3.3], "material":"stone", "bevel":0.12, "solid":true})
			props.append({"shape":"box", "pos":[x, -58.0], "size":[4.0, 0.45, 4.2], "material":"stone_light", "bevel":0.10, "solid":true})
			props.append({"shape":"box", "pos":[x, -58.0], "size":[3.6, 0.48, 3.8], "y":11.5, "material":"stone_light", "bevel":0.09, "solid":true})
		props.append({"shape":"box", "pos":[3.0, -58.0], "size":[17.0, 1.6, 3.5], "y":12.25, "material":"stone", "bevel":0.12, "solid":true})
		# 同组矮墙加略挑出的压顶，让石墙的顶面、正面、基部有明确层级。
		var caps: Array = []
		for entry in props:
			var source := entry as Dictionary
			if source.get("shape", "") != "box" or source.has("y"):
				continue
			var size := _vector3(source, "size", Vector3.ONE)
			if size.y < 1.5 or size.y > 4.1 or maxf(size.x, size.z) < 5.0:
				continue
			var cap := source.duplicate(true)
			cap["size"] = [size.x + 0.20, 0.22, size.z + 0.20]
			cap["y"] = size.y - 0.025
			cap["bevel"] = 0.055
			cap["material"] = "stone_light"
			cap["solid"] = false
			caps.append(cap)
		props.append_array(caps)
	for entry in props:
		var spec := entry as Dictionary
		var at := _point(spec, "pos", Vector2.ZERO)
		var shape := String(spec.get("shape", "box"))
		var material := _material_for(spec)
		var mesh := _make_mesh(shape, spec)
		if mesh == null:
			continue
		var height := _shape_height(shape, spec)
		var node := MeshInstance3D.new()
		node.name = "Prop_%s_%.0f_%.0f" % [shape, at.x, at.y]
		node.mesh = mesh
		node.material_override = material
		# 竖直位置有两种写法：默认"底面贴地"，需要精确摆放时用 y 直接指定
		# （例如横躺的原木，它的几何中心并不在"高度的一半"处）。
		var level := _ground(at.x, at.y) + height * 0.5 + float(spec.get("lift", 0.0))
		if spec.has("y"):
			level = _ground(at.x, at.y) + float(spec.get("y"))
		node.position = Vector3(at.x, level, at.y)
		# rotation 给三轴（度），没有则退回 yaw（绕 Y，度）。
		if spec.has("rotation"):
			var degrees := _vector3(spec, "rotation", Vector3.ZERO)
			node.rotation = Vector3(
				deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)
			)
		else:
			node.rotation.y = deg_to_rad(float(spec.get("yaw", 0.0)))
		if bool(spec.get("solid", false)):
			add_child(_wrap_solid(node, mesh.get_aabb()))
		else:
			add_child(node)


## 把网格包成可站立的静态碰撞体。碰撞盒取网格 AABB ——
## 这样"画面与碰撞同源"，不会出现看不见的台阶或踩空的边。
func _sanctum_ruin_plan(original: Array) -> Array:
	var result: Array = []
	for entry in original:
		var p := _point(entry, "pos", Vector2.ZERO)
		# Replace scattered northern wall pieces and the western room, keep altar and gates.
		if (absf(p.x) > 10.0 and p.y < -10.0) or (p.x < -25.0 and p.y < 12.0):
			continue
		result.append(entry)
	# Two former roofed galleries: matching foundations and column spacing make
	# the absent roof readable. East retains a beam; west exposes fallen masonry.
	for side in [-1.0, 1.0]:
		var x: float = 3.0 + side * 19.0
		result.append(_ruin_block(Vector2(x, -24), Vector3(12, 0.18, 22), 0.09))
		for index in 4:
			var z: float = -33.0 + index * 6.0
			var height: float = 5.6 if (index < 2 and side > 0) else [4.6, 2.1, 3.4, 1.2][index]
			result.append(_ruin_block(Vector2(x - side * 4.5, z), Vector3(2.1, 0.3, 2.1), 0.15))
			result.append(_ruin_block(Vector2(x - side * 4.5, z), Vector3(1.35, height, 1.35), height * 0.5 + 0.3))
		# Rear enclosure survives at decreasing heights; gaps are breaches, not random rotations.
		for index in 3:
			var height: float = [3.8, 2.6, 1.2][index]
			result.append(_ruin_block(Vector2(x + side * 5.2, -31.0 + index * 6), Vector3(1.25, height, 5.6), height * 0.5))
		result.append(_ruin_block(Vector2(x, -34), Vector3(10, 2.8, 1.2), 1.4))
		if side > 0:
			result.append(_ruin_block(Vector2(x - side * 4.5, -30), Vector3(1.8, 0.7, 7.5), 6.0))
		else:
			for index in 5:
				var block := _ruin_block(Vector2(x + 1.5 + sin(index * 2.0), -30 + index * 2.4), Vector3(1.7, 0.65, 1.3), 0.34)
				block["rotation"] = [0, index * 23, 0]
				result.append(block)
	# Western votive chapel: coherent U-plan with a doorway facing the junction.
	result.append(_ruin_block(Vector2(-34, 2), Vector3(11, 0.18, 12), 0.09))
	result.append(_ruin_block(Vector2(-39, 2), Vector3(1.2, 3.8, 12), 1.9))
	result.append(_ruin_block(Vector2(-35, -3.5), Vector3(8, 2.6, 1.2), 1.3))
	result.append(_ruin_block(Vector2(-35, 7.5), Vector3(8, 1.4, 1.2), 0.7))
	result.append(_ruin_block(Vector2(-34, 2), Vector3(2.7, 0.7, 2.7), 0.35))
	result.append({"shape":"diamond", "pos":[-34,2], "radius":0.72, "height":2.0, "y":2.0, "material":"stone_light", "emissive":[1.0,0.78,0.06], "emissive_energy":3.0})
	return result


func _ruin_block(at: Vector2, size: Vector3, level: float) -> Dictionary:
	return {"shape":"box", "pos":[at.x,at.y], "size":[size.x,size.y,size.z], "y":level, "material":"stone", "bevel":0.09, "solid":true}


func _wrap_solid(mesh_node: MeshInstance3D, bounds: AABB) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = mesh_node.name
	# 这批配置生成的实体障碍必须参与导航烘焙。只建物理碰撞会让导航路径
	# 直接穿过石柱/墙体，角色到了现场才被碰撞挡住。
	body.add_to_group("nav_source")
	body.position = mesh_node.position
	body.rotation = mesh_node.rotation
	var shape: Shape3D
	var shape_offset := Vector3.ZERO
	if mesh_node.mesh is ArrayMesh:
		# 倒角构件使用同一网格生成凸碰撞，切角处不再存在看不见的盒碰撞。
		shape = mesh_node.mesh.create_convex_shape(true, false)
	else:
		var box_shape := BoxShape3D.new()
		box_shape.size = bounds.size
		shape = box_shape
		shape_offset = bounds.get_center()
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = shape_offset
	body.add_child(collision)
	# 网格本身归零：它的位姿已经搬到 body 上了。
	mesh_node.position = Vector3.ZERO
	mesh_node.rotation = Vector3.ZERO
	body.add_child(mesh_node)
	return body


## 光源：营火与神龛那种"画面里唯一允许高饱和"的点光。
func _build_lights() -> void:
	for entry in _list("lights"):
		var spec := entry as Dictionary
		var at := _point(spec, "pos", Vector2.ZERO)
		var light := OmniLight3D.new()
		light.name = "MapLight_%.0f_%.0f" % [at.x, at.y]
		light.light_color = _color(spec.get("color", null), Color(1.0, 0.5, 0.2))
		light.light_energy = float(spec.get("energy", 3.0))
		light.omni_range = float(spec.get("range", 8.0))
		light.position = Vector3(
			at.x, _ground(at.x, at.y) + float(spec.get("height", 1.0)), at.y
		)
		add_child(light)


## 树簇。确定性种子 + 环带撒点，位置与数量全部来自配置。
##
## 【必须自己登记进 nav_source】—— 树是有碰撞的导航障碍。迁移前那 22 棵树
## 靠 Forest 节点的 terrain_snap 统一登记；换成自己生成的簇之后，不登记
## 敌人就会直接穿过树干。
func _build_grove() -> void:
	var groves := _list("grove")
	if groves.is_empty():
		return
	var holder := Node3D.new()
	holder.name = "Grove"
	holder.add_to_group("nav_source")
	add_child(holder)
	var rng := RandomNumberGenerator.new()
	for entry in groves:
		var spec := entry as Dictionary
		var center := _point(spec, "center", Vector2.ZERO)
		var count := maxi(int(spec.get("count", 0)), 0)
		var radius := maxf(float(spec.get("radius", 20.0)), 1.0)
		var inner := clampf(float(spec.get("inner_radius", 0.0)), 0.0, radius)
		rng.seed = int(spec.get("seed", 1))
		for index in range(count):
			var angle := TAU * float(index) / float(maxi(count, 1)) \
				+ rng.randf_range(-0.35, 0.35)
			var distance := rng.randf_range(inner, radius)
			var x := center.x + cos(angle) * distance
			var z := center.y + sin(angle) * distance
			# 湖面 / 主路 / 遗迹 / 营地是保留区，树不能长在上面。
			# 判据复用 arena 的遮罩，于是"哪块地不能放东西"只有一处定义。
			if ArenaUtil.is_masked_out(_arena, x, z):
				continue
			var pine_ratio := clampf(float(spec.get("pine_ratio", 0.0)), 0.0, 1.0)
			var tree_scene: PackedScene = TREE_SCENE
			# pine_ratio=0 时不消耗随机数，保证旧地图的树木缩放与旋转逐值不变。
			if pine_ratio > 0.0 and rng.randf() < pine_ratio:
				tree_scene = PINE_SCENE
			var tree := tree_scene.instantiate() as Node3D
			tree.scale = Vector3.ONE * rng.randf_range(
				float(spec.get("scale_min", 0.85)), float(spec.get("scale_max", 1.3))
			)
			tree.position = Vector3(x, _ground(x, z), z)
			tree.rotation.y = rng.randf_range(0.0, TAU)
			holder.add_child(tree)


## ---------------------------------------------------------------- 工具

## 取 map 段里的一个列表。缺项或类型不对时返回空数组（绝不让配置错误炸掉场景）。
func _list(key: String) -> Array:
	var raw: Variant = _map.get(key, null)
	return raw as Array if raw is Array else []


## [x, z] → Vector2。
func _point(spec: Dictionary, key: String, fallback: Vector2) -> Vector2:
	var value: Variant = spec.get(key, null)
	if value is Array and (value as Array).size() >= 2:
		var pair := value as Array
		return Vector2(float(pair[0]), float(pair[1]))
	return fallback


func _vector2(spec: Dictionary, key: String, fallback: Vector2) -> Vector2:
	return _point(spec, key, fallback)


func _vector3(spec: Dictionary, key: String, fallback: Vector3) -> Vector3:
	var value: Variant = spec.get(key, null)
	if value is Array and (value as Array).size() >= 3:
		var parts := value as Array
		return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	return fallback


func _color(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var parts := value as Array
		return Color(float(parts[0]), float(parts[1]), float(parts[2]))
	return fallback


## 地面高度。所有陈设都从这里落地 —— 这是"不再假设 y≈0"的全部依据。
func _ground(x: float, z: float) -> float:
	return TerrainUtil.height_at(x, z)


func _material_for(spec: Dictionary) -> StandardMaterial3D:
	var material := (_materials[String(spec.get("material", "stone"))] as StandardMaterial3D)
	if material == null:
		material = _materials["stone"] as StandardMaterial3D
	var emissive: Variant = spec.get("emissive", null)
	if emissive == null:
		return material
	# 需要自发光的部件（神龛核心、营火）单独复制一份材质，免得改到共享的那份。
	var glow := material.duplicate() as StandardMaterial3D
	var emissive_color := _color(emissive, Color(1.0, 0.4, 0.1))
	glow.emission_enabled = true
	glow.emission = emissive_color
	glow.emission_energy_multiplier = float(spec.get("emissive_energy", 3.0))
	# 只开 emission 在明亮日景里仍会读成原材质颜色。发光体自己的表面也染色，
	# 才能像参考画面里的蓝色晶体和橙色火焰一样成为稳定的探索焦点。
	glow.albedo_color = glow.albedo_color.lerp(emissive_color, 0.78)
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return glow


func _flat(name: String, size: Vector2, at: Vector3, material_key: String) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	node.material_override = _materials[material_key]
	node.position = at
	return node


## 三种基本体。用显式的 radius / radius_top / height 字段而不是一个笼统的 size，
## 因为"圆柱的 size 分别代表什么"本身就是最容易写错的地方。
func _make_mesh(shape: String, spec: Dictionary) -> Mesh:
	match shape:
		"cylinder":
			var cylinder := CylinderMesh.new()
			var radius := maxf(float(spec.get("radius", 0.5)), 0.01)
			cylinder.top_radius = maxf(float(spec.get("radius_top", radius)), 0.01)
			cylinder.bottom_radius = radius
			cylinder.height = maxf(float(spec.get("height", 1.0)), 0.01)
			cylinder.radial_segments = 12
			return cylinder
		"diamond":
			var diamond := SphereMesh.new()
			var diamond_radius := maxf(float(spec.get("radius", 0.5)), 0.01)
			diamond.radius = diamond_radius
			diamond.height = maxf(float(spec.get("height", diamond_radius * 2.0)), 0.01)
			diamond.radial_segments = 4
			diamond.rings = 2
			return diamond
		"sphere":
			var sphere := SphereMesh.new()
			var sphere_radius := maxf(float(spec.get("radius", 0.5)), 0.01)
			sphere.radius = sphere_radius
			sphere.height = maxf(float(spec.get("height", sphere_radius * 2.0)), 0.01)
			sphere.radial_segments = 12
			sphere.rings = 7
			return sphere
		_:
			var box_size := _vector3(spec, "size", Vector3.ONE)
			var bevel := maxf(float(spec.get("bevel", 0.0)), 0.0)
			if bevel > 0.0001:
				if String(_arena.get("_id", "")) == "sanctum" and String(spec.get("material", "")).begins_with("stone") and box_size.y > 1.2:
					return ValleyArt.masonry(box_size, bevel)
				return LowPolyMeshUtil.chamfered_box(box_size, bevel)
			var box := BoxMesh.new()
			box.size = box_size
			return box


## 基本体的竖直尺寸，用来把它摆到"底面贴地"的位置。
func _shape_height(shape: String, spec: Dictionary) -> float:
	if shape == "box":
		return _vector3(spec, "size", Vector3.ONE).y
	return maxf(float(spec.get("height", 1.0)), 0.01)
