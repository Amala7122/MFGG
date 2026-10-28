extends SceneTree
## 一次性场景构建工具：生成「圣所回廊试作」的静态 .tscn。
##
## 这个脚本不是运行时地图生成器，只在本机运行一次：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path . \
##       --script res://tools/build_sanctum_arena.gd
##
## 生成的 sanctum_arena.tscn 里所有墙、台阶、柱子、雕像、灯光都是普通节点，
## 可以直接在编辑器中选中、移动、旋转、复制；运行时不依赖本脚本。

const LowPoly := preload("res://scripts/lowpoly_mesh.gd")

const OUT_DIR := "res://prototypes/sanctum_arena"
const LEVEL_PATH := OUT_DIR + "/sanctum_arena.tscn"
const WALKER_PATH := OUT_DIR + "/preview_walker.tscn"
const ART_PATH := "res://assets/generated/valley/sanctum_art.scn"
const MOUNTAIN_PATH := "res://assets/generated/valley/sanctum_mountains.res"
const WALKER_SCRIPT := "res://scripts/preview/preview_walker.gd"
## 主祭坛圣徽：由参考图轮廓描出的闭合多边形（见 assets/generated/valley/ 里的 JSON）。
const SIGIL_PATH := "res://assets/generated/valley/sanctum_sigil_paths.json"

## 坐标约定：+Z 是南（出生方向），-Z 是北（祭坛方向）；+X 是东。
const COURT_X := 20.0
const COURT_Z_MIN := -2.0
const COURT_Z_MAX := 28.0
const COURT_Y := -1.2
const UPPER_Y := 0.0
const OUTER_X := 30.0
const OUTER_Z_MIN := -40.0
const OUTER_Z_MAX := 30.0
const HALL_X := 14.0
const HALL_Z_MIN := -36.0
const HALL_Z_MAX := -4.0
const GATE_SOUTH_Z := 30.0
const GATE_NORTH_Z := -4.0
const SPAWN := Vector3(0.0, 0.18, 52.0)

var scene_root: Node3D
var _mats: Dictionary = {}
var _sigil: Dictionary = {}
var _box_cache: Dictionary = {}
var _cyl_cache: Dictionary = {}
var _rock_cache: Dictionary = {}
var _cone_cache: Dictionary = {}
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_rng.seed = 20261027
	var absolute := ProjectSettings.globalize_path(OUT_DIR)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		push_error("无法创建输出目录：%s" % absolute)
		quit(1)
		return
	_make_materials()
	if not _build_walker_scene():
		quit(1)
		return
	_sigil = _load_sigil_paths()
	if _sigil.is_empty():
		push_error("圣徽轮廓数据缺失或无效：%s" % SIGIL_PATH)
		quit(1)
		return

	scene_root = Node3D.new()
	scene_root.name = "SanctumArena"
	_build_environment()
	_build_backdrop()
	_build_ground()
	_build_outer_walls()
	_build_gatehouse(GATE_SOUTH_Z, 7.0, 5.0, 9.5, "SouthGate", true, false)
	_build_approach()
	_build_balustrades()
	_build_court()
	_build_cloister()
	_build_gatehouse(GATE_NORTH_Z, 7.0, 6.5, 11.0, "InnerGate", false, true)
	_build_hall()
	_build_garths()
	_build_monastery()
	_build_chapels()
	_build_dressing()
	_build_lights()
	_build_preview()
	_own(scene_root)

	var packed := PackedScene.new()
	var pack_error := packed.pack(scene_root)
	if pack_error != OK:
		push_error("PackedScene.pack 失败：%d" % pack_error)
		quit(1)
		return
	var save_error := ResourceSaver.save(packed, LEVEL_PATH)
	if save_error != OK:
		push_error("场景保存失败：%d %s" % [save_error, LEVEL_PATH])
		quit(1)
		return
	print("[圣所回廊] 已生成：", LEVEL_PATH)
	print("[圣所回廊] 节点数：", _count_nodes(scene_root), "  文件字节：",
		FileAccess.get_file_as_string(LEVEL_PATH).length())
	scene_root.free()
	quit()


# ---------------------------------------------------------------- 材质与网格

func _make_materials() -> void:
	_mats["stone"] = _material(Color(1.0, 0.95, 0.86), 0.92, 0.0, true)
	_mats["stone_plain"] = _material(Color(0.33, 0.30, 0.25), 0.92, 0.0, false)
	_mats["stone_wet"] = _material(Color(0.92, 0.88, 0.80), 0.42, 0.02, true)
	_mats["stone_dark"] = _material(Color(0.86, 0.82, 0.74), 0.95, 0.0, true)
	# 主祭坛圣徽：暖白雪花石底板 + 近黑玄武岩浮雕，形成参考图的黑白对比。
	# 雪花石薄板有轻微自发光；它读作嵌在墙龛里的背光石，而不是靠一盏凭空出现的射灯。
	_mats["alabaster"] = _material(Color(0.80, 0.78, 0.72), 0.94, 0.0, false)
	_mats["alabaster"].metallic_specular = 0.12
	_mats["alabaster"].emission_enabled = true
	_mats["alabaster"].emission = Color(0.98, 0.95, 0.88)
	_mats["alabaster"].emission_energy_multiplier = 0.42
	_mats["basalt"] = _material(Color.WHITE, 0.84, 0.0, true)
	_mats["basalt"].metallic_specular = 0.06
	_mats["stone_frame"] = _material(Color(0.30, 0.29, 0.26), 0.9, 0.0, false)
	# 祭坛纺织品：亚麻台布与深红祭坛前帷。颜色写在顶点色里，和石材同一套材质约定。
	_mats["linen"] = _material(Color.WHITE, 1.0, 0.0, true)
	_mats["frontal"] = _material(Color.WHITE, 1.0, 0.0, true)
	_mats["wood"] = _material(Color(0.92, 0.92, 0.92), 0.82, 0.0, true)
	_mats["iron"] = _material(Color(0.80, 0.80, 0.80), 0.38, 0.72, true)
	_mats["iron_plain"] = _material(Color(0.10, 0.11, 0.12), 0.38, 0.72, false)
	_mats["gold"] = _material(Color(1.0, 0.92, 0.72), 0.34, 0.8, true)
	_mats["gold_plain"] = _material(Color(0.56, 0.44, 0.20), 0.34, 0.8, false)
	_mats["statue"] = _material(Color(0.26, 0.27, 0.26), 0.92, 0.0, false)
	_mats["cloth"] = _material(Color(0.95, 0.95, 0.95), 1.0, 0.0, true, false, true)
	_mats["moss"] = _material(Color(0.90, 0.90, 0.90), 1.0, 0.0, true)
	_mats["dirt"] = _material(Color(0.94, 0.94, 0.94), 1.0, 0.0, true)
	_mats["cloud"] = _material(Color(1.0, 1.0, 1.0), 1.0, 0.0, true)
	_mats["props"] = _material(Color(0.92, 0.90, 0.86), 0.86, 0.0, true)
	_mats["person"] = _material(Color(0.95, 0.92, 0.86), 1.0, 0.0, true)
	_mats["candle"] = _material(Color(0.86, 0.82, 0.70), 0.82, 0.0, true)
	_mats["ember"] = _glow(Color(1.0, 0.38, 0.07), 4.5)
	_mats["flame_blue"] = _glow(Color(0.46, 0.80, 1.0), 5.5)
	_mats["flame_red"] = _glow(Color(1.0, 0.20, 0.05), 4.5)
	_mats["flame_yellow"] = _glow(Color(1.0, 0.70, 0.12), 4.0)
	_mats["window"] = _glow(Color(0.30, 0.52, 0.78), 1.25, true)
	_mats["water"] = _water(Color(0.025, 0.055, 0.075, 0.82))
	_mats["shaft"] = _shaft(Color(0.62, 0.76, 0.90, 0.055))
	_mats["crystal"] = _crystal_material(Color(0.42, 0.72, 0.95),
		Color(0.10, 0.35, 0.75), 0.8)
	_mats["crystal_holy"] = _crystal_material(Color(0.72, 0.86, 0.98),
		Color(0.45, 0.65, 0.90), 0.65)


func _crystal_material(base: Color, emission: Color, energy: float) -> StandardMaterial3D:
	var material := _material(base, 0.12, 0.18, true)
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = energy
	material.rim_enabled = true
	material.rim = 0.45
	material.rim_tint = 0.6
	material.metallic_specular = 0.75
	return material


func _material(base: Color, roughness: float, metallic: float, vertex_color: bool,
		unshaded := false, double_sided := false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = base
	material.roughness = roughness
	material.metallic = metallic
	material.vertex_color_use_as_albedo = vertex_color
	material.vertex_color_is_srgb = true
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if double_sided:
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _glow(color: Color, energy: float, transparent := false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.roughness = 0.6
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.55
	return material


func _water(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.2
	material.metallic = 0.12
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _shaft(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.disable_receive_shadows = true
	material.no_depth_test = true
	return material


func _box_mesh(size: Vector3, bevel: float) -> ArrayMesh:
	var key := "%.3f,%.3f,%.3f|%.3f" % [size.x, size.y, size.z, bevel]
	if not _box_cache.has(key):
		_box_cache[key] = LowPoly.chamfered_box(size, bevel, Color.WHITE)
	return _box_cache[key]


func _cyl_mesh(top_radius: float, bottom_radius: float, height: float, segments: int) -> CylinderMesh:
	var key := "%.3f|%.3f|%.3f|%d" % [top_radius, bottom_radius, height, segments]
	if not _cyl_cache.has(key):
		var mesh := CylinderMesh.new()
		mesh.top_radius = top_radius
		mesh.bottom_radius = bottom_radius
		mesh.height = height
		mesh.radial_segments = segments
		mesh.rings = 1
		_cyl_cache[key] = mesh
	return _cyl_cache[key]


func _rock_mesh(radius: float, height: float, facets: int, rings: int) -> ArrayMesh:
	var key := "%.3f|%.3f|%d|%d" % [radius, height, facets, rings]
	if not _rock_cache.has(key):
		_rock_cache[key] = LowPoly.faceted_ellipsoid(radius, height, facets, rings, 0.16)
	return _rock_cache[key]


func _cone_mesh(radius: float, height: float, facets: int) -> ArrayMesh:
	var key := "%.3f|%.3f|%d" % [radius, height, facets]
	if not _cone_cache.has(key):
		_cone_cache[key] = LowPoly.faceted_cone(radius, height, facets)
	return _cone_cache[key]


func _append(builder: LowPoly.Builder, mesh: Mesh, xform: Transform3D, tint: Color) -> void:
	if mesh == null:
		return
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray
	if arrays[Mesh.ARRAY_COLOR] != null:
		colors = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array
	if arrays[Mesh.ARRAY_INDEX] != null:
		indices = arrays[Mesh.ARRAY_INDEX]
	var normal_basis := xform.basis.inverse().transposed()
	if indices.size() > 0:
		# 内置 CylinderMesh / TorusMesh 等是索引网格；Builder 只接受三角形顶点流，
		# 必须按索引展开。直接复制顶点会把索引网格拆成三角形碎片。
		for index in indices:
			var i := int(index)
			builder.verts.append(xform * vertices[i])
			builder.normals.append((normal_basis * normals[i]).normalized())
			builder.colors.append((colors[i] if colors.size() > i else Color.WHITE) * tint)
		return
	for i in vertices.size():
		builder.verts.append(xform * vertices[i])
		builder.normals.append((normal_basis * normals[i]).normalized())
		builder.colors.append((colors[i] if colors.size() > i else Color.WHITE) * tint)


func _add_box(builder: LowPoly.Builder, center: Vector3, size: Vector3, tint: Color,
		bevel := 0.03, basis := Basis.IDENTITY) -> void:
	# 水平薄块（墙层、地砖、台阶、梁）不做倒角：倒角只对近景大构件有意义，
	# 逐块倒角会让场景文件膨胀数倍。竖直大块仍保留倒角。
	var use_bevel := bevel
	if size.y <= 0.72:
		use_bevel = 0.0
	_append(builder, _box_mesh(size, use_bevel), Transform3D(basis, center), tint)


func _add_cyl(builder: LowPoly.Builder, center: Vector3, top_radius: float,
		bottom_radius: float, height: float, tint: Color, segments := 10,
		basis := Basis.IDENTITY) -> void:
	_append(builder, _cyl_mesh(top_radius, bottom_radius, height, segments),
		Transform3D(basis, center), tint)


func _add_rock(builder: LowPoly.Builder, center: Vector3, radius: float, height: float,
		tint: Color, basis := Basis.IDENTITY) -> void:
	_append(builder, _rock_mesh(radius, height, 9, 4), Transform3D(basis, center), tint)


func _add_cone(builder: LowPoly.Builder, center: Vector3, radius: float, height: float,
		tint: Color, basis := Basis.IDENTITY) -> void:
	_append(builder, _cone_mesh(radius, height, 8), Transform3D(basis, center), tint)


func _tone(base: Color, amount: float) -> Color:
	return Color(
		clampf(base.r + amount, 0.0, 1.0),
		clampf(base.g + amount, 0.0, 1.0),
		clampf(base.b + amount, 0.0, 1.0),
		base.a
	)


# ---------------------------------------------------------------- 节点工具

func _group(parent: Node, name: String) -> Node3D:
	var node := Node3D.new()
	node.name = name
	parent.add_child(node)
	node.owner = scene_root
	return node


func _mesh_node(parent: Node, name: String, mesh: Mesh, material: Material,
		position := Vector3.ZERO, yaw := 0.0, cast_shadow := true) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	if material != null:
		instance.material_override = material
	instance.position = position
	instance.rotation.y = yaw
	if not cast_shadow:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	instance.owner = scene_root
	return instance


func _commit(parent: Node, name: String, builder: LowPoly.Builder, material: Material,
		cast_shadow := true) -> MeshInstance3D:
	if builder == null or builder.verts.is_empty():
		return null
	return _mesh_node(parent, name, LowPoly.commit(builder), material, Vector3.ZERO, 0.0, cast_shadow)


func _static(parent: Node, name: String, position: Vector3, yaw := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = name
	body.position = position
	body.rotation.y = yaw
	parent.add_child(body)
	body.owner = scene_root
	return body


func _box_collision(body: Node, size: Vector3, center := Vector3.ZERO) -> void:
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	collision.position = center
	body.add_child(collision)
	collision.owner = scene_root


func _own(node: Node) -> void:
	for child in node.get_children():
		if child.owner == null:
			child.owner = scene_root
		if child.scene_file_path.is_empty():
			_own(child)


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


# ---------------------------------------------------------------- 环境

func _build_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.20, 0.245, 0.30)
	sky_material.sky_horizon_color = Color(0.56, 0.61, 0.66)
	sky_material.sky_curve = 0.22
	sky_material.sky_energy_multiplier = 0.95
	sky_material.ground_bottom_color = Color(0.10, 0.11, 0.12)
	sky_material.ground_horizon_color = Color(0.30, 0.32, 0.33)
	sky_material.ground_curve = 0.05
	sky_material.sun_angle_max = 8.0
	sky_material.sun_curve = 0.06
	var sky := Sky.new()
	sky.sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_color = Color(0.64, 0.72, 0.82)
	environment.ambient_light_energy = 0.95
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.05
	environment.tonemap_white = 1.1
	environment.glow_enabled = true
	environment.glow_intensity = 0.40
	environment.glow_bloom = 0.04
	environment.glow_hdr_threshold = 1.1
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_light_color = Color(0.40, 0.46, 0.52)
	environment.fog_light_energy = 0.62
	environment.fog_depth_begin = 42.0
	environment.fog_depth_end = 420.0
	environment.fog_depth_curve = 1.35
	environment.fog_aerial_perspective = 0.48
	environment.fog_sky_affect = 0.15
	environment.ssao_enabled = true
	environment.ssao_intensity = 1.4
	environment.ssao_radius = 1.0
	environment.ssao_power = 1.3
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 0.90
	environment.adjustment_contrast = 1.05
	environment.adjustment_brightness = 1.02
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	scene_root.add_child(world_environment)
	world_environment.owner = scene_root

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-58.0, -38.0, 0.0)
	sun.light_color = Color(0.80, 0.86, 0.94)
	sun.light_energy = 1.35
	sun.light_angular_distance = 4.0
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 95.0
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 2.2
	scene_root.add_child(sun)
	sun.owner = scene_root

	var fill := DirectionalLight3D.new()
	fill.name = "SkyFill"
	fill.rotation_degrees = Vector3(-24.0, 145.0, 0.0)
	fill.light_color = Color(0.58, 0.68, 0.80)
	fill.light_energy = 0.45
	fill.shadow_enabled = false
	scene_root.add_child(fill)
	fill.owner = scene_root


# ---------------------------------------------------------------- 远景

func _build_backdrop() -> void:
	var backdrop := _group(scene_root, "Backdrop")

	var mountain_mesh: Resource = load(MOUNTAIN_PATH)
	if mountain_mesh is Mesh:
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.vertex_color_is_srgb = true
		material.albedo_color = Color(0.52, 0.60, 0.68)
		material.roughness = 1.0
		var mountains := _mesh_node(backdrop, "DistantValley", mountain_mesh as Mesh,
			material, Vector3(0, -2.0, 0), 0.0, false)
		mountains.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	else:
		push_warning("远景山脉资源不可用：%s" % MOUNTAIN_PATH)

	# 只从旧静态美术中取瀑布、瀑布落石和远处土路；近景草地与旧遗迹地砖会
	# 和新场景冲突，不复制。
	var art_resource: Resource = load(ART_PATH)
	if art_resource is PackedScene:
		var art := (art_resource as PackedScene).instantiate()
		for node_name in ["SaddleCascade", "CascadeBoulders", "WindingValleyTrack"]:
			var source := art.get_node_or_null(node_name) as Node3D
			if source == null:
				continue
			var duplicate := source.duplicate()
			duplicate.name = String(node_name)
			backdrop.add_child(duplicate)
			duplicate.owner = scene_root
			_own(duplicate)
			for mesh_child in duplicate.find_children("*", "MeshInstance3D", true, false):
				(mesh_child as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		art.free()
	else:
		push_warning("旧山谷静态美术不可用：%s" % ART_PATH)

	_build_backdrop_forest(backdrop)
	# _build_rock_ridges(backdrop)  # 入口两侧改成香客客房/马厩，不再堆假山


func _build_backdrop_forest(parent: Node3D) -> void:
	var holder := _group(parent, "OuterForest")
	var placed: Array[Vector2] = []
	for attempt in 90:
		if placed.size() >= 34:
			break
		var angle := _rng.randf_range(0.0, TAU)
		var radius := _rng.randf_range(38.0, 82.0)
		var at := Vector2(cos(angle) * radius, sin(angle) * radius + 4.0)
		if at.y > 30.0 and absf(at.x) < 16.0:
			continue
		if absf(at.x) < 33.0 and at.y < 32.0 and at.y > -43.0:
			continue
		var too_close := false
		for other in placed:
			if at.distance_to(other) < 5.0:
				too_close = true
				break
		if too_close:
			continue
		placed.append(at)
		var y := -2.0
		_pine_tree(holder, "Pine_%02d" % placed.size(), Vector3(at.x, y, at.y),
			_rng.randf_range(1.1, 2.2), _rng.randf_range(-0.04, 0.04))
	for index in 2:
		var offsets := [-10.5, 10.5]
		var at := Vector2(offsets[index], 58.0 + _rng.randf_range(-1.5, 2.5))
		_cypress_tree(holder, "Cypress_%02d" % index, Vector3(at.x, 0.0, at.y),
			_rng.randf_range(1.15, 1.4))


func _pine_tree(parent: Node3D, name: String, position: Vector3, scale_value: float,
		tint_shift: float) -> void:
	var body := Node3D.new()
	body.name = name
	body.position = position
	body.scale = Vector3.ONE * scale_value
	parent.add_child(body)
	body.owner = scene_root
	var builder := LowPoly.begin()
	var trunk := Color(0.19, 0.14, 0.09)
	var needle := _tone(Color(0.10, 0.20, 0.13), tint_shift)
	_add_cyl(builder, Vector3(0, 2.0, 0), 0.12, 0.26, 4.0, trunk, 6)
	for tier in 3:
		var radius := 1.35 - tier * 0.32
		var height := 2.1 - tier * 0.3
		_add_cone(builder, Vector3(0, 2.4 + tier * 1.05, 0), radius, height,
			_tone(needle, tier * 0.015), Basis.IDENTITY)
	var mesh := LowPoly.commit(builder)
	_mesh_node(body, "Mesh", mesh, _mats["stone"], Vector3.ZERO, 0.0, false)


func _cypress_tree(parent: Node3D, name: String, position: Vector3, scale_value: float) -> void:
	var body := Node3D.new()
	body.name = name
	body.position = position
	body.scale = Vector3.ONE * scale_value
	parent.add_child(body)
	body.owner = scene_root
	var builder := LowPoly.begin()
	var bark := Color(0.20, 0.16, 0.11)
	var needle := Color(0.075, 0.16, 0.09)
	_add_cyl(builder, Vector3(0, 1.4, 0), 0.10, 0.24, 2.8, bark, 6)
	for tier in 4:
		var radius := 1.05 - tier * 0.2
		var height := 3.1 - tier * 0.3
		_add_cone(builder, Vector3(0, 2.3 + tier * 1.25, 0), radius, height,
			_tone(needle, tier * 0.012), Basis.IDENTITY)
	var mesh := LowPoly.commit(builder)
	_mesh_node(body, "Mesh", mesh, _mats["stone"], Vector3.ZERO, 0.0, false)


func _bare_tree(parent: Node3D, name: String, position: Vector3, scale_value: float) -> void:
	var body := Node3D.new()
	body.name = name
	body.position = position
	body.scale = Vector3.ONE * scale_value
	parent.add_child(body)
	body.owner = scene_root
	var builder := LowPoly.begin()
	var bark := Color(0.16, 0.13, 0.10)
	_add_cyl(builder, Vector3(0, 3.4, 0), 0.13, 0.34, 6.8, bark, 6)
	for index in 7:
		var angle := float(index) * 1.71
		var length := 2.4 - (index % 3) * 0.45
		var direction := Vector3(cos(angle), 0.8 + (index % 4) * 0.18, sin(angle)).normalized()
		var basis := Basis(Vector3.UP, angle) * Basis(Vector3.RIGHT, deg_to_rad(52.0))
		var center := Vector3(0, 3.3 + (index % 4) * 0.75, 0) + direction * length * 0.5
		_add_cyl(builder, center, 0.03, 0.12, length, _tone(bark, 0.02), 5, basis)
	var mesh := LowPoly.commit(builder)
	_mesh_node(body, "Mesh", mesh, _mats["stone"], Vector3.ZERO, 0.0, false)


func _build_rock_ridges(parent: Node3D) -> void:
	_rock_line(parent, "ApproachRidgeWest", Vector2(-9.0, 34.0), Vector2(-12.0, 58.0), 9)
	_rock_line(parent, "ApproachRidgeEast", Vector2(9.0, 34.0), Vector2(12.0, 58.0), 9)


func _build_clouds(parent: Node3D) -> void:
	var holder := _group(parent, "CloudCanopy")
	for index in 13:
		var angle := TAU * float(index) / 13.0 + _rng.randf_range(-0.18, 0.18)
		var radius := _rng.randf_range(120.0, 310.0)
		var center := Vector3(cos(angle) * radius, _rng.randf_range(70.0, 105.0),
			sin(angle) * radius + 10.0)
		var builder := LowPoly.begin()
		for puff in 3:
			var offset := Vector3(_rng.randf_range(-18.0, 18.0),
				_rng.randf_range(-2.0, 2.0), _rng.randf_range(-12.0, 12.0))
			var radius_puff := _rng.randf_range(18.0, 38.0)
			_add_rock(builder, center + offset, radius_puff, radius_puff * 0.22,
				_tone(Color(0.38, 0.41, 0.43), _rng.randf_range(-0.04, 0.04)),
				Basis(Vector3.UP, _rng.randf_range(0.0, TAU)))
		_mesh_node(holder, "Cloud_%02d" % index, LowPoly.commit(builder), _mats["cloud"],
			Vector3.ZERO, 0.0, false)


func _rock_line(parent: Node3D, name: String, from: Vector2, to: Vector2, count: int) -> void:
	var body := StaticBody3D.new()
	body.name = name
	body.add_to_group("preview_rocks")
	parent.add_child(body)
	body.owner = scene_root
	var builder := LowPoly.begin()
	var tint := Color(0.26, 0.28, 0.27)
	for index in count:
		var t := (float(index) + 0.5) / float(count)
		var at := from.lerp(to, t)
		var offset := Vector2(_rng.randf_range(-1.2, 1.2), _rng.randf_range(-1.2, 1.2))
		var radius := _rng.randf_range(1.5, 3.2)
		var height := _rng.randf_range(2.0, 5.5)
		_add_rock(builder, Vector3(at.x + offset.x, height * 0.35, at.y + offset.y),
			radius, height, _tone(tint, _rng.randf_range(-0.03, 0.03)),
			Basis(Vector3.UP, _rng.randf_range(0.0, TAU)))
		_box_collision(body, Vector3(radius * 1.8, height, radius * 1.8),
			Vector3(at.x + offset.x, height * 0.5, at.y + offset.y))
	var mesh := LowPoly.commit(builder)
	_mesh_node(body, "Mesh", mesh, _mats["stone"], Vector3.ZERO, 0.0, true)


# ---------------------------------------------------------------- 地面

func _build_ground() -> void:
	var ground := _group(scene_root, "Ground")

	# 场地外的土石地面：只负责画面与兜底碰撞，玩家被栏杆限制在石道上。
	_outdoor_patch(ground, "ApproachShelf", -12.0, 12.0, 30.0, 64.0, -0.08)
	_outdoor_patch(ground, "SouthLedge", -30.5, 30.5, 30.2, 33.5, -0.08)
	_outdoor_patch(ground, "WestLedge", -33.5, -30.2, -40.0, 30.0, -0.08)
	_outdoor_patch(ground, "EastLedge", 30.2, 33.5, -40.0, 30.0, -0.08)
	_outdoor_patch(ground, "NorthLedge", -33.5, 33.5, -43.5, -40.2, -0.08)
	# 外圈窄岩台要有真实碰撞，否则从侧门出去会直接掉到兜底层。
	_outdoor_collision(ground, "ApproachShelfFloor", -12.0, 12.0, 30.0, 64.0)
	_outdoor_collision(ground, "SouthLedgeFloor", -33.5, 33.5, 30.0, 33.5)
	_outdoor_collision(ground, "EastLedgeFloor", 30.0, 33.5, 24.0, 33.5)
	_outdoor_collision(ground, "WestLedgeFloor", -33.5, -30.0, 24.0, 33.5)
	# 外沿矮栏：让侧门外的环路能走，同时不让人一步踏空。
	var rim_tint := Color(0.30, 0.28, 0.24)
	_wall(ground, "EastLedgeParapet", Vector2(33.5, 24.0), Vector2(33.5, 33.5),
		0.0, 0.78, 0.4, rim_tint)
	_wall(ground, "WestLedgeParapet", Vector2(-33.5, 24.0), Vector2(-33.5, 33.5),
		0.0, 0.78, 0.4, rim_tint)
	_wall(ground, "SouthLedgeParapetEast", Vector2(12.0, 33.5), Vector2(33.5, 33.5),
		0.0, 0.78, 0.4, rim_tint)
	_wall(ground, "SouthLedgeParapetWest", Vector2(-33.5, 33.5), Vector2(-12.0, 33.5),
		0.0, 0.78, 0.4, rim_tint)
	_wall(ground, "ApproachShelfParapetWest", Vector2(-12.0, 34.0), Vector2(-12.0, 64.0),
		0.0, 0.78, 0.4, rim_tint)
	_wall(ground, "ApproachShelfParapetEast", Vector2(12.0, 34.0), Vector2(12.0, 64.0),
		0.0, 0.78, 0.4, rim_tint)

	# 场地外不铺整片碰撞：玩家被栏杆限制在石道上；这里只放一层很低的兜底，
	# 防止跳出去后无限下落。
	var catch := _static(ground, "FallCatch", Vector3(0, -2.4, 6))
	_box_collision(catch, Vector3(84, 0.4, 120))

	_floor(ground, "Approach", -4.5, 4.5, 30.0, 58.0, 0.0, 2.0, Color(0.34, 0.35, 0.34))
	_floor(ground, "SouthLandingW", -20.0, -4.0, 28.0, 30.0, 0.0, 2.5, Color(0.31, 0.32, 0.31))
	_floor(ground, "SouthLandingE", 4.0, 20.0, 28.0, 30.0, 0.0, 2.5, Color(0.31, 0.32, 0.31))
	_floor(ground, "NorthLandingW", -20.0, -4.0, -4.0, -2.0, 0.0, 2.5, Color(0.31, 0.32, 0.31))
	_floor(ground, "NorthLandingE", 4.0, 20.0, -4.0, -2.0, 0.0, 2.5, Color(0.31, 0.32, 0.31))
	_floor(ground, "WestTerrace", -30.0, -20.0, -4.0, 30.0, 0.0, 3.0, Color(0.30, 0.31, 0.30))
	_floor(ground, "EastTerrace", 20.0, 30.0, -4.0, 30.0, 0.0, 3.0, Color(0.30, 0.31, 0.30))
	_floor(ground, "Court", -20.0, 20.0, -2.0, 28.0, COURT_Y, 2.8, Color(0.28, 0.29, 0.28))
	_floor(ground, "Hall", -14.0, 14.0, -36.0, -4.0, 0.0, 2.8, Color(0.29, 0.30, 0.29))
	_floor(ground, "HallServiceWest", -30.0, -14.0, -36.0, -4.0, 0.0, 3.2,
		Color(0.27, 0.28, 0.27))
	_floor(ground, "HallServiceEast", 14.0, 30.0, -36.0, -4.0, 0.0, 3.2,
		Color(0.27, 0.28, 0.27))
	_floor(ground, "RearAmbulatory", -30.0, 30.0, -40.0, -36.0, 0.0, 3.2,
		Color(0.27, 0.28, 0.27))
	_floor(ground, "WestChapelFloor", -30.0, -26.0, 8.0, 16.0, 0.0, 2.0, Color(0.27, 0.28, 0.27))
	_floor(ground, "EastChapelFloor", 26.0, 30.0, 2.0, 10.0, 0.0, 2.0, Color(0.27, 0.28, 0.27))

	# 南、北台阶与西侧中段楼梯。
	_stairs(ground, "SouthSteps", Vector3(0, COURT_Y, 28.0), 0.0, 8.0, 2.0, 1.2, 6)
	_stairs(ground, "NorthSteps", Vector3(0, COURT_Y, -2.0), PI, 8.0, 2.0, 1.2, 6)
	_stairs(ground, "WestMidSteps", Vector3(-17.5, COURT_Y, 11.5), -PI * 0.5, 3.0, 2.5, 1.2, 6)
	_stairs(ground, "EastMidSteps", Vector3(17.5, COURT_Y, 11.5), PI * 0.5, 3.0, 2.5, 1.2, 6)

	# 庭院下沉挡土墙。
	_wall(ground, "CourtRetainWestA", Vector2(-20.0, -2.0), Vector2(-20.0, 10.0),
		COURT_Y, 2.1, 0.6, Color(0.27, 0.28, 0.27))
	_wall(ground, "CourtRetainWestB", Vector2(-20.0, 13.0), Vector2(-20.0, 28.0),
		COURT_Y, 2.1, 0.6, Color(0.27, 0.28, 0.27))
	_wall(ground, "CourtRetainEastA", Vector2(20.0, -2.0), Vector2(20.0, 10.0),
		COURT_Y, 2.1, 0.6, Color(0.27, 0.28, 0.27))
	_wall(ground, "CourtRetainEastB", Vector2(20.0, 13.0), Vector2(20.0, 28.0),
		COURT_Y, 2.1, 0.6, Color(0.27, 0.28, 0.27))
	_wall(ground, "CourtRetainSouthW", Vector2(-20.0, 28.0), Vector2(-4.0, 28.0),
		COURT_Y, 2.1, 0.6, Color(0.27, 0.28, 0.27))
	_wall(ground, "CourtRetainSouthE", Vector2(4.0, 28.0), Vector2(20.0, 28.0),
		COURT_Y, 2.1, 0.6, Color(0.27, 0.28, 0.27))
	_wall(ground, "CourtRetainNorthW", Vector2(-20.0, -2.0), Vector2(-4.0, -2.0),
		COURT_Y, 2.1, 0.6, Color(0.27, 0.28, 0.27))
	_wall(ground, "CourtRetainNorthE", Vector2(4.0, -2.0), Vector2(20.0, -2.0),
		COURT_Y, 2.1, 0.6, Color(0.27, 0.28, 0.27))

	# 石道两侧的矮护墙：把玩家留在仪式道上，同时形成入口框景。
	_wall(ground, "ApproachParapetWestA", Vector2(-5.2, 34.0), Vector2(-5.2, 44.0),
		0.0, 0.85, 0.45, Color(0.30, 0.31, 0.30))
	_wall(ground, "ApproachParapetWestB", Vector2(-5.2, 48.0), Vector2(-5.2, 57.0),
		0.0, 0.85, 0.45, Color(0.30, 0.31, 0.30))
	_wall(ground, "ApproachParapetEastA", Vector2(5.2, 34.0), Vector2(5.2, 44.0),
		0.0, 0.85, 0.45, Color(0.30, 0.31, 0.30))
	_wall(ground, "ApproachParapetEastB", Vector2(5.2, 48.0), Vector2(5.2, 57.0),
		0.0, 0.85, 0.45, Color(0.30, 0.31, 0.30))
	_wall(ground, "ApproachCurbWestA", Vector2(-4.7, 30.0), Vector2(-4.7, 44.0),
		0.0, 0.22, 0.35, Color(0.36, 0.37, 0.35))
	_wall(ground, "ApproachCurbWestB", Vector2(-4.7, 48.0), Vector2(-4.7, 58.0),
		0.0, 0.22, 0.35, Color(0.36, 0.37, 0.35))
	_wall(ground, "ApproachCurbEastA", Vector2(4.7, 30.0), Vector2(4.7, 44.0),
		0.0, 0.22, 0.35, Color(0.36, 0.37, 0.35))
	_wall(ground, "ApproachCurbEastB", Vector2(4.7, 48.0), Vector2(4.7, 58.0),
		0.0, 0.22, 0.35, Color(0.36, 0.37, 0.35))


func _outdoor_collision(parent: Node3D, name: String, x0: float, x1: float, z0: float,
		z1: float) -> void:
	var body := _static(parent, name, Vector3((x0 + x1) * 0.5, -0.2, (z0 + z1) * 0.5))
	_box_collision(body, Vector3(x1 - x0, 0.4, z1 - z0))


func _south_door(parent: Node3D, name: String, x: float, z: float) -> void:
	var body := _static(parent, name, Vector3(x, 0, z))
	var builder := LowPoly.begin()
	var tint := Color(0.31, 0.29, 0.25)
	_add_box(builder, Vector3(0, 4.0, 0), Vector3(4.0, 2.0, 1.5), tint, 0.03)
	_add_box(builder, Vector3(0, 3.05, 0), Vector3(4.4, 0.22, 1.75), tint.lightened(0.08), 0.02)
	_add_box(builder, Vector3(0, 5.2, 0.8), Vector3(0.12, 0.85, 0.12),
		tint.lightened(0.12), 0.01)
	_add_box(builder, Vector3(0, 5.3, 0.8), Vector3(0.58, 0.12, 0.12),
		tint.lightened(0.12), 0.01)
	_add_box(builder, Vector3(0.9, 1.5, -0.45), Vector3(2.15, 2.7, 0.12),
		Color(0.22, 0.15, 0.09), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(4.0, 2.0, 1.5), Vector3(0, 4.0, 0))
	var sill := _static(parent, name + "_Sill", Vector3(x, 0.01, z))
	var sill_mesh := _box_mesh(Vector3(4.4, 0.03, 2.0), 0.02)
	_mesh_node(sill, "Mesh", sill_mesh, _mats["stone_plain"], Vector3.ZERO, 0.0, false)


func _postern(parent: Node3D, name: String, x: float, z: float, side: float) -> void:
	var body := _static(parent, name, Vector3(x, 0, z))
	var builder := LowPoly.begin()
	var tint := Color(0.30, 0.28, 0.24)
	_add_box(builder, Vector3(0, 4.0, 0), Vector3(1.5, 2.0, 2.4), tint, 0.03)
	_add_box(builder, Vector3(0, 3.05, 0), Vector3(1.8, 0.22, 2.8), tint.lightened(0.08), 0.02)
	# 门上的小石十字：这是侧门，不是城堡暗门。
	_add_box(builder, Vector3(float(side) * 0.8, 5.25, 0), Vector3(0.12, 0.9, 0.12),
		tint.lightened(0.12), 0.01)
	_add_box(builder, Vector3(float(side) * 0.8, 5.35, 0), Vector3(0.12, 0.12, 0.62),
		tint.lightened(0.12), 0.01)
	# 半开的木门，贴在洞内侧，不做碰撞。
	_add_box(builder, Vector3(float(-side) * 0.45, 1.5, 1.55), Vector3(0.12, 2.7, 1.15),
		Color(0.22, 0.15, 0.09), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(1.5, 2.0, 2.4), Vector3(0, 4.0, 0))
	var sill := _static(parent, name + "_Sill", Vector3(x, 0.01, z))
	var sill_mesh := _box_mesh(Vector3(1.7, 0.03, 2.7), 0.02)
	_mesh_node(sill, "Mesh", sill_mesh, _mats["stone_plain"], Vector3.ZERO, 0.0, false)


func _outdoor_patch(parent: Node3D, name: String, x0: float, x1: float, z0: float, z1: float,
		base_y: float) -> void:
	var builder := LowPoly.begin()
	var columns := maxi(1, int(ceil((x1 - x0) / 6.0)))
	var rows := maxi(1, int(ceil((z1 - z0) / 6.0)))
	var step_x := (x1 - x0) / float(columns)
	var step_z := (z1 - z0) / float(rows)
	for ix in columns:
		for iz in rows:
			var x_a := x0 + float(ix) * step_x
			var x_b := x_a + step_x
			var z_a := z0 + float(iz) * step_z
			var z_b := z_a + step_z
			var h := base_y
			var corner := Vector3(x_a, h, z_a)
			var corner_b := Vector3(x_b, h, z_a)
			var corner_c := Vector3(x_b, h, z_b)
			var corner_d := Vector3(x_a, h, z_b)
			var tone := _tone(Color(0.115, 0.135, 0.10), _rng.randf_range(-0.002, 0.002))
			LowPoly.push_quad(builder, corner, corner_d, corner_c, corner_b, tone)
	var instance := _mesh_node(parent, name, LowPoly.commit(builder), _mats["dirt"],
		Vector3.ZERO, 0.0, false)
	instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED


func _floor(parent: Node3D, name: String, x0: float, x1: float, z0: float, z1: float,
		y: float, tile: float, tint: Color) -> void:
	var body := _static(parent, name, Vector3((x0 + x1) * 0.5, y - 0.25, (z0 + z1) * 0.5))
	_box_collision(body, Vector3(x1 - x0, 0.5, z1 - z0))
	var builder := LowPoly.begin()
	var width := x1 - x0
	var depth := z1 - z0
	var columns := maxi(1, int(ceil(width / tile)))
	var rows := maxi(1, int(ceil(depth / tile)))
	var step_x := width / float(columns)
	var step_z := depth / float(rows)
	# 地砖下加一层深色垫层：砖缝只露出暗色，而不是透出天空形成亮线。
	_add_box(builder, Vector3(0, 0.06, 0), Vector3(width - 0.02, 0.1, depth - 0.02),
		Color(0.075, 0.08, 0.08), 0.0)
	for ix in columns:
		for iz in rows:
			var local := Vector3(-width * 0.5 + (float(ix) + 0.5) * step_x,
				0.16, -depth * 0.5 + (float(iz) + 0.5) * step_z)
			var tone := _tone(tint, _rng.randf_range(-0.018, 0.018))
			if (ix * 17 + iz * 29) % 41 == 0:
				_add_box(builder, Vector3(local.x, 0.04, local.z),
					Vector3(step_x - 0.04, 0.1, step_z - 0.04), tone.darkened(0.34), 0.01)
				continue
			_add_box(builder, local, Vector3(step_x - 0.035, 0.18, step_z - 0.035), tone, 0.035)
	# 收边石
	_add_box(builder, Vector3(0, 0.24, -depth * 0.5 + 0.16),
		Vector3(width + 0.08, 0.12, 0.38), tint.lightened(0.06), 0.02)
	_add_box(builder, Vector3(0, 0.24, depth * 0.5 - 0.16),
		Vector3(width + 0.08, 0.12, 0.38), tint.lightened(0.06), 0.02)
	_add_box(builder, Vector3(-width * 0.5 + 0.16, 0.24, 0),
		Vector3(0.38, 0.12, depth + 0.08), tint.lightened(0.06), 0.02)
	_add_box(builder, Vector3(width * 0.5 - 0.16, 0.24, 0),
		Vector3(0.38, 0.12, depth + 0.08), tint.lightened(0.06), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, false)


func _floor_runner(parent: Node3D, name: String, x0: float, x1: float, z0: float, z1: float,
		y: float, tint: Color) -> void:
	var builder := LowPoly.begin()
	_add_box(builder, Vector3((x0 + x1) * 0.5, y, (z0 + z1) * 0.5),
		Vector3(x1 - x0, 0.025, z1 - z0), tint, 0.01)
	_add_box(builder, Vector3((x0 + x1) * 0.5, y + 0.01, z0 + 0.12),
		Vector3(x1 - x0 + 0.18, 0.03, 0.2), tint.darkened(0.12), 0.01)
	_add_box(builder, Vector3((x0 + x1) * 0.5, y + 0.01, z1 - 0.12),
		Vector3(x1 - x0 + 0.18, 0.03, 0.2), tint.darkened(0.12), 0.01)
	_mesh_node(parent, name, LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, false)


func _wall(parent: Node3D, name: String, start: Vector2, end: Vector2, base_y: float,
		height: float, thickness: float, tint: Color, broken := false) -> StaticBody3D:
	var length := start.distance_to(end)
	if length < 0.2:
		return null
	var center := (start + end) * 0.5
	var yaw := atan2(-(end.y - start.y), end.x - start.x)
	var body := _static(parent, name, Vector3(center.x, base_y, center.y), yaw)
	var builder := LowPoly.begin()
	var rows := maxi(1, int(round(height / 0.62)))
	var course := height / float(rows)
	var block := 1.55
	for row in rows:
		var cursor := -length * 0.5 + (0.0 if row % 2 == 0 else -block * 0.5)
		while cursor < length * 0.5:
			var span := minf(block, length * 0.5 - cursor)
			if span < 0.24:
				break
			var at := cursor + span * 0.5
			var tone := _tone(tint, _rng.randf_range(-0.015, 0.015)
				+ 0.018 * sin(float(row) * 2.1 + at * 0.7))
			_add_box(builder, Vector3(at, (float(row) + 0.5) * course, 0.0),
				Vector3(span - 0.025, course - 0.02, thickness), tone, 0.035)
			cursor += span
	_add_box(builder, Vector3(0, 0.12, 0), Vector3(length + 0.12, 0.24, thickness + 0.18),
		tint.darkened(0.18), 0.03)
	if not broken:
		_add_box(builder, Vector3(0, height + 0.09, 0),
			Vector3(length + 0.16, 0.18, thickness + 0.22), tint.lightened(0.07), 0.025)
	for bx in [-length * 0.5 + 0.55, length * 0.5 - 0.55]:
		if length > 2.6:
			_add_box(builder, Vector3(bx, height * 0.43, 0),
				Vector3(0.55, height * 0.86, thickness + 0.42), tint.darkened(0.06), 0.03)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	var collision_height := height if not broken else height * 0.9
	_box_collision(body, Vector3(length, collision_height, thickness),
		Vector3(0, collision_height * 0.5, 0))
	return body


func _stairs(parent: Node3D, name: String, low: Vector3, yaw: float, width: float,
		run: float, rise: float, steps: int) -> void:
	var body := _static(parent, name, low, yaw)
	var builder := LowPoly.begin()
	var tread := run / float(steps)
	var step_rise := rise / float(steps)
	for index in steps:
		var z := (float(index) + 0.5) * tread
		var top := (float(index) + 1.0) * step_rise
		var tone := _tone(Color(0.32, 0.33, 0.32), 0.012 * float(index % 3))
		_add_box(builder, Vector3(0, top * 0.5, z), Vector3(width, top, tread + 0.03), tone, 0.025)
		_add_box(builder, Vector3(0, top + 0.035, z + tread * 0.5 - 0.08),
			Vector3(width + 0.08, 0.07, 0.24), tone.lightened(0.1), 0.015)
	_add_box(builder, Vector3(0, 0.04, run * 0.5), Vector3(width + 0.3, 0.08, run + 0.2),
		Color(0.19, 0.20, 0.19), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	var wedge := ConvexPolygonShape3D.new()
	wedge.points = PackedVector3Array([
		Vector3(-width * 0.5, 0.0, 0.0), Vector3(width * 0.5, 0.0, 0.0),
		Vector3(-width * 0.5, 0.0, run), Vector3(width * 0.5, 0.0, run),
		Vector3(-width * 0.5, rise, run), Vector3(width * 0.5, rise, run),
	])
	var collision := CollisionShape3D.new()
	collision.shape = wedge
	body.add_child(collision)
	collision.owner = scene_root


# ---------------------------------------------------------------- 外墙与入口

func _build_outer_walls() -> void:
	var walls := _group(scene_root, "OuterWalls")
	var tint := Color(0.28, 0.29, 0.28)
	_wall(walls, "SouthWestOuter", Vector2(-OUTER_X, GATE_SOUTH_Z), Vector2(-22.0, GATE_SOUTH_Z),
		0.0, 5.0, 1.25, tint)
	_wall(walls, "SouthWestInner", Vector2(-18.0, GATE_SOUTH_Z), Vector2(-8.0, GATE_SOUTH_Z),
		0.0, 5.0, 1.25, tint)
	_wall(walls, "SouthEastInner", Vector2(8.0, GATE_SOUTH_Z), Vector2(18.0, GATE_SOUTH_Z),
		0.0, 5.0, 1.25, tint)
	_wall(walls, "SouthEastOuter", Vector2(22.0, GATE_SOUTH_Z), Vector2(OUTER_X, GATE_SOUTH_Z),
		0.0, 5.0, 1.25, tint)
	_south_door(walls, "WestSouthDoor", -20.0, GATE_SOUTH_Z)
	_south_door(walls, "EastSouthDoor", 20.0, GATE_SOUTH_Z)
	_wall(walls, "WestSouth", Vector2(-OUTER_X, GATE_SOUTH_Z), Vector2(-OUTER_X, 27.2),
		0.0, 5.0, 1.25, tint)
	_wall(walls, "WestNorth", Vector2(-OUTER_X, 24.8), Vector2(-OUTER_X, OUTER_Z_MIN),
		0.0, 5.0, 1.25, tint)
	_wall(walls, "EastSouth", Vector2(OUTER_X, GATE_SOUTH_Z), Vector2(OUTER_X, 27.2),
		0.0, 5.0, 1.25, tint)
	_wall(walls, "EastNorth", Vector2(OUTER_X, 24.8), Vector2(OUTER_X, OUTER_Z_MIN),
		0.0, 5.0, 1.25, tint)
	_postern(walls, "WestPostern", -OUTER_X, 26.0, -1.0)
	_postern(walls, "EastPostern", OUTER_X, 26.0, 1.0)
	_wall(walls, "North", Vector2(-OUTER_X, OUTER_Z_MIN), Vector2(OUTER_X, OUTER_Z_MIN),
		0.0, 5.0, 1.25, tint)
	# 四角不再放城堡角楼：外墙在角部直接交接，南侧岩台通路保持畅通。
	# 入口两侧的钟塔是唯一的竖向高塔。


func _build_gatehouse(z: float, opening: float, side_height: float, tower_height: float,
		name: String, outer: bool, build_sides: bool) -> void:
	var gate := _group(scene_root, name)
	var tint := Color(0.27, 0.28, 0.27)
	var tower_size := 4.5
	var tower_x := opening * 0.5 + tower_size * 0.5
	_tower(gate, "TowerWest", Vector3(-tower_x, 0, z), tower_size, tower_height, tint, outer)
	_tower(gate, "TowerEast", Vector3(tower_x, 0, z), tower_size, tower_height, tint, outer)
	if build_sides:
		# 内门两翼不再封死：在 ±24 m 各留一道 4 m 的侧门，把上层回廊接进
		# 大礼拜堂两侧的庭院，形成绕殿一圈的流线。
		_wall(gate, "SideWestOuter", Vector2(-OUTER_X, z), Vector2(-26.0, z),
			0.0, side_height, 1.3, tint)
		_wall(gate, "SideWestInner", Vector2(-22.0, z), Vector2(-opening * 0.5 - tower_size, z),
			0.0, side_height, 1.3, tint)
		_wall(gate, "SideEastInner", Vector2(opening * 0.5 + tower_size, z), Vector2(22.0, z),
			0.0, side_height, 1.3, tint)
		_wall(gate, "SideEastOuter", Vector2(26.0, z), Vector2(OUTER_X, z),
			0.0, side_height, 1.3, tint)
		for door_x in [-24.0, 24.0]:
			var lintel_body := _static(gate, "SideDoorLintel_%d" % roundi(door_x),
				Vector3(door_x, 0, z))
			var lintel_builder := LowPoly.begin()
			_add_box(lintel_builder, Vector3(0, (4.2 + side_height) * 0.5, 0),
				Vector3(4.0, side_height - 4.2, 1.4), tint, 0.03)
			_add_box(lintel_builder, Vector3(0, 4.05, 0.72), Vector3(4.4, 0.28, 0.3),
				tint.lightened(0.08), 0.02)
			_mesh_node(lintel_body, "Mesh", LowPoly.commit(lintel_builder), _mats["stone"],
				Vector3.ZERO, 0.0, true)
			_box_collision(lintel_body, Vector3(4.0, side_height - 4.2, 1.4),
				Vector3(0, (4.2 + side_height) * 0.5, 0))
			# 侧门门槛只做视觉，不做台阶碰撞。
			var sill := _static(gate, "SideDoorSill_%d" % roundi(door_x),
				Vector3(door_x, 0.015, z))
			var sill_mesh := _box_mesh(Vector3(4.2, 0.04, 2.2), 0.02)
			_mesh_node(sill, "Mesh", sill_mesh, _mats["stone_plain"], Vector3.ZERO, 0.0, false)

	var opening_height := 5.6 if outer else 5.8
	var top := tower_height - 0.8
	var body := _static(gate, "GateMass", Vector3(0, 0, z))
	var builder := LowPoly.begin()
	_add_box(builder, Vector3(0, (opening_height + top) * 0.5, 0),
		Vector3(opening, top - opening_height, 1.5), tint, 0.04)
	# 门楣与托石：直接长在门楼正面，不再用悬空的拱券楔石。
	var lintel_y := opening_height - 0.18
	_add_box(builder, Vector3(0, lintel_y, 0.78), Vector3(opening + 0.9, 0.36, 0.62),
		tint.lightened(0.07), 0.03)
	for index in 7:
		var corbel_x := -opening * 0.5 + 0.45 + float(index) * (opening - 0.9) / 6.0
		_add_box(builder, Vector3(corbel_x, lintel_y - 0.38, 0.86), Vector3(0.38, 0.3, 0.45),
			tint.lightened(0.03), 0.02)
	 # 门楣压顶
	_add_box(builder, Vector3(0, top - 0.35, 0), Vector3(opening + 0.7, 0.7, 1.8),
		tint.lightened(0.08), 0.03)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(opening, top - opening_height, 1.5),
		Vector3(0, (opening_height + top) * 0.5, 0))
	_seal(gate, Vector3(0, top - 0.85, z + 0.84), 0.78 if outer else 0.9)
	# 门上的浅浮雕：十字与两侧圣徒轮廓，替代城堡式闸门。
	var relief := LowPoly.begin()
	_add_box(relief, Vector3(0, opening_height + 0.92, 0.82), Vector3(4.8, 1.15, 0.14),
		tint.lightened(0.05), 0.02)
	_add_box(relief, Vector3(0, opening_height + 0.92, 0.9), Vector3(3.7, 0.88, 0.05),
		Color(0.32, 0.28, 0.22), 0.01)
	_add_box(relief, Vector3(0, opening_height + 0.92, 0.97), Vector3(0.11, 0.78, 0.05),
		Color(0.56, 0.44, 0.20), 0.01)
	_add_box(relief, Vector3(0, opening_height + 1.12, 0.97), Vector3(0.58, 0.11, 0.05),
		Color(0.56, 0.44, 0.20), 0.01)
	for side in [-1.0, 1.0]:
		_add_box(relief, Vector3(float(side) * 1.25, opening_height + 0.82, 0.97),
			Vector3(0.26, 0.58, 0.05), Color(0.42, 0.38, 0.31), 0.01)
	_mesh_node(gate, "PortalRelief", LowPoly.commit(relief), _mats["stone"],
		Vector3(0, 0, z), 0.0, true)
	# 山花与十字：教堂西立面，而不是城垛。
	var gable_height := 2.0
	var gable := PrismMesh.new()
	gable.size = Vector3(opening + 1.4, gable_height, 1.7)
	_mesh_node(gate, "Gable", gable, _mats["stone_plain"],
		Vector3(0, top + gable_height * 0.5, z), 0.0, true)
	_cross_finial(gate, "GableCross", Vector3(0, top + gable_height + 0.35, z), 1.0)

	# 门扇：向内侧打开，保留门洞通行。
	var door_height := opening_height - 0.25
	var leaf_width := opening * 0.5 - 0.08
	_door_leaf(gate, "DoorWest", Vector3(-opening * 0.5, 0, z), -deg_to_rad(102.0),
		leaf_width, door_height, z < 0.0)
	_door_leaf(gate, "DoorEast", Vector3(opening * 0.5, 0, z), deg_to_rad(102.0),
		leaf_width, door_height, z < 0.0)
	# 门槛
	var threshold := _static(gate, "Threshold", Vector3(0, 0.015, z))
	var threshold_mesh := _box_mesh(Vector3(opening + 0.4, 0.04, 2.4), 0.02)
	_mesh_node(threshold, "Mesh", threshold_mesh, _mats["stone_plain"], Vector3.ZERO, 0.0, false)
	# 门槛只做视觉；不建 0.2 m 高的碰撞唇口，避免预览角色卡在门口。


func _cross_finial(parent: Node3D, name: String, position: Vector3, height: float) -> void:
	var body := _static(parent, name, position)
	var builder := LowPoly.begin()
	_add_box(builder, Vector3(0, height * 0.5, 0), Vector3(0.11, height, 0.11),
		Color(0.56, 0.44, 0.20), 0.01)
	_add_box(builder, Vector3(0, height * 0.7, 0), Vector3(0.11, 0.11, height * 0.52),
		Color(0.56, 0.44, 0.20), 0.01)
	_add_box(builder, Vector3(0, 0.08, 0), Vector3(0.34, 0.16, 0.34),
		Color(0.32, 0.28, 0.22), 0.01)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["gold_plain"], Vector3.ZERO, 0.0, false)


func _seal(parent: Node3D, position: Vector3, radius: float) -> void:
	var body := _static(parent, "Seal", position)
	var ring := TorusMesh.new()
	ring.inner_radius = radius * 0.82
	ring.outer_radius = radius
	ring.rings = 24
	ring.ring_segments = 6
	var frame := _mesh_node(body, "Ring", ring, _mats["stone_plain"], Vector3.ZERO, 0.0, true)
	frame.rotation_degrees.x = 90.0
	var inset := CylinderMesh.new()
	inset.top_radius = radius * 0.72
	inset.bottom_radius = radius * 0.72
	inset.height = 0.16
	inset.radial_segments = 24
	var disc := _mesh_node(body, "Glass", inset, _mats["window"], Vector3(0, 0, -0.02), 0.0, false)
	disc.rotation_degrees.x = 90.0
	for index in 2:
		var bar := _static(body, "Cross_%02d" % index, Vector3.ZERO)
		bar.rotation.z = float(index) * PI * 0.5
		var b := LowPoly.begin()
		_add_box(b, Vector3.ZERO, Vector3(radius * 1.45, 0.075, 0.075),
			Color(0.50, 0.42, 0.24), 0.01)
		_mesh_node(bar, "Bar", LowPoly.commit(b), _mats["gold_plain"], Vector3.ZERO, 0.0, false)


func _tower(parent: Node3D, name: String, position: Vector3, size: float, height: float,
		tint: Color, bell_tower := false) -> void:
	var body := _static(parent, name, position)
	var builder := LowPoly.begin()
	_add_box(builder, Vector3(0, height * 0.5, 0), Vector3(size, height, size), tint, 0.05)
	_add_box(builder, Vector3(0, 0.3, 0), Vector3(size + 0.5, 0.6, size + 0.5),
		tint.darkened(0.12), 0.04)
	_add_box(builder, Vector3(0, height * 0.56, 0), Vector3(size + 0.28, 0.3, size + 0.28),
		tint.lightened(0.05), 0.025)
	# 下层尖拱窗（南面），替代城堡箭孔。
	_add_box(builder, Vector3(0, height * 0.36, size * 0.5 + 0.015),
		Vector3(0.62, 1.55, 0.08), Color(0.12, 0.12, 0.12), 0.01)
	_add_box(builder, Vector3(0, height * 0.36 + 0.86, size * 0.5 + 0.02),
		Vector3(0.38, 0.36, 0.08), Color(0.12, 0.12, 0.12), 0.01,
		Basis(Vector3.BACK, deg_to_rad(45.0)))
	# 钟室：百叶窗与青铜钟；不是垛口。
	if bell_tower:
		for face in [1.0, -1.0]:
			var face_z: float = size * 0.5 * face + 0.02 * face
			_add_box(builder, Vector3(0, height * 0.72, face_z),
				Vector3(1.55, 2.0, 0.1), Color(0.10, 0.10, 0.10), 0.01)
			for slat in 4:
				_add_box(builder, Vector3(-0.5 + float(slat) * 0.33, height * 0.72,
					face_z + 0.07 * face), Vector3(0.09, 1.85, 0.07),
					Color(0.20, 0.18, 0.14), 0.01)
		_add_cyl(builder, Vector3(0, height * 0.70, 0), 0.26, 0.38, 0.72,
			Color(0.34, 0.26, 0.13), 10)
		_add_box(builder, Vector3(0, height * 0.70 + 0.48, 0), Vector3(0.9, 0.12, 0.16),
			Color(0.20, 0.15, 0.10), 0.01)
	# 檐口 + 锥形尖顶 + 十字，替代城垛。
	var roof_tint := Color(0.17, 0.18, 0.20)
	var roof_height := maxf(1.8, height * 0.28)
	_add_box(builder, Vector3(0, height + 0.1, 0), Vector3(size + 0.55, 0.24, size + 0.55),
		roof_tint, 0.025)
	_add_cone(builder, Vector3(0, height + 0.22 + roof_height * 0.5, 0),
		size * 0.78, roof_height, roof_tint, Basis.IDENTITY)
	var cross_y := height + 0.22 + roof_height + 0.28
	_add_box(builder, Vector3(0, cross_y, 0), Vector3(0.10, 0.78, 0.10),
		Color(0.55, 0.44, 0.20), 0.01)
	_add_box(builder, Vector3(0, cross_y + 0.18, 0), Vector3(0.10, 0.10, 0.52),
		Color(0.55, 0.44, 0.20), 0.01)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(size, height, size), Vector3(0, height * 0.5, 0))


func _door_leaf(parent: Node3D, name: String, hinge: Vector3, yaw: float, width: float,
		height: float, inner_north: bool) -> void:
	var body := _static(parent, name, hinge, yaw)
	var builder := LowPoly.begin()
	var wood := Color(0.22, 0.14, 0.09)
	_add_box(builder, Vector3(width * 0.5, height * 0.5, 0), Vector3(width, height, 0.16), wood, 0.02)
	for band in 3:
		_add_box(builder, Vector3(width * 0.5, height * (0.2 + band * 0.3), 0.09),
			Vector3(width * 0.96, 0.12, 0.06), Color(0.12, 0.13, 0.13), 0.01)
	for stud in 6:
		_add_box(builder, Vector3(width * (0.25 + (stud % 3) * 0.25),
			height * (0.22 + (stud / 3) * 0.56), 0.1), Vector3(0.08, 0.08, 0.06),
			Color(0.10, 0.11, 0.11), 0.01)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["wood"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(width, height, 0.18), Vector3(width * 0.5, height * 0.5, 0))


func _build_portcullis(parent: Node3D, z: float, opening: float, opening_height: float) -> void:
	var body := _static(parent, "Portcullis", Vector3(0, 0, z))
	var builder := LowPoly.begin()
	var iron := Color(0.12, 0.13, 0.13)
	var bottom := opening_height - 2.3
	for index in 9:
		var x := -opening * 0.5 + 0.28 + float(index) * (opening - 0.56) / 8.0
		_add_box(builder, Vector3(x, bottom + 1.15, 0.0), Vector3(0.1, 2.3, 0.1), iron, 0.012)
	for band in 3:
		_add_box(builder, Vector3(0, bottom + 0.35 + band * 0.8, 0.0),
			Vector3(opening - 0.3, 0.09, 0.12), iron, 0.01)
	# 链条与配重
	_add_box(builder, Vector3(0, opening_height - 0.2, 0.0), Vector3(opening, 0.16, 0.22),
		iron, 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["iron"], Vector3.ZERO, 0.0, false)


func _build_approach() -> void:
	var approach := _group(scene_root, "Approach")
	for side in [-1.0, 1.0]:
		_statue(approach, "GateSaint_%s" % ("W" if side < 0 else "E"),
			Vector3(float(side) * 7.2, 0, 35.0), 0.0 if side < 0 else PI, 1.35,
			Color(0.40, 0.41, 0.39))
	# 门口值守的教团守卫；不挡中央门洞。
	_person(approach, "GateGuardW", Vector3(-3.1, 0, 31.8), PI, "guard",
		Color(0.24, 0.21, 0.17), Color(0.17, 0.15, 0.12), "spear")
	_person(approach, "GateGuardE", Vector3(3.1, 0, 31.8), PI, "guard",
		Color(0.24, 0.21, 0.17), Color(0.17, 0.15, 0.12), "spear")
	# 门内的临时武器架与带箭盾牌，说明这里刚打过。
	var rack := _static(approach, "GateWeaponRack", Vector3(-5.6, 0, 31.2))
	var rb := LowPoly.begin()
	for z in [-0.8, 0.8]:
		_add_box(rb, Vector3(0, 0.8, z), Vector3(0.16, 1.6, 0.16),
			Color(0.24, 0.16, 0.09), 0.01)
	_add_box(rb, Vector3(0, 1.5, 0), Vector3(0.18, 0.14, 1.9), Color(0.24, 0.16, 0.09), 0.01)
	for z in [-0.55, 0.0, 0.55]:
		_add_cyl(rb, Vector3(0.18, 1.25, z), 0.03, 0.04, 1.9, Color(0.38, 0.27, 0.13), 6)
		_add_cone(rb, Vector3(0.18, 2.24, z), 0.07, 0.2, Color(0.24, 0.25, 0.26))
	_mesh_node(rack, "Mesh", LowPoly.commit(rb), _mats["props"], Vector3.ZERO, 0.0, true)
	var shield := _static(approach, "ArrowShield", Vector3(5.4, 0, 31.0))
	var sb := LowPoly.begin()
	_add_box(sb, Vector3(0, 0.85, 0), Vector3(0.16, 1.0, 0.72), Color(0.28, 0.20, 0.12), 0.02)
	_add_cyl(sb, Vector3(0.1, 0.85, 0), 0.13, 0.13, 0.08, Color(0.24, 0.25, 0.26), 8,
		Basis(Vector3.BACK, PI * 0.5))
	for a in [-0.22, 0.12]:
		_add_cyl(sb, Vector3(0.18, 0.9, a), 0.018, 0.022, 0.55,
			Color(0.35, 0.25, 0.13), 5, Basis(Vector3.RIGHT, deg_to_rad(70.0)))
	_mesh_node(shield, "Mesh", LowPoly.commit(sb), _mats["props"], Vector3.ZERO, 0.0, true)



func _build_balustrades() -> void:
	var rails := _group(scene_root, "Balustrades")
	var tint := Color(0.34, 0.35, 0.33)
	# 南、北平台面向庭院的两段栏杆（中间留出楼梯）
	_rail(rails, "SouthRailW", Vector2(-20.0, 28.0), Vector2(-4.0, 28.0), 0.0, tint)
	_rail(rails, "SouthRailE", Vector2(4.0, 28.0), Vector2(20.0, 28.0), 0.0, tint)
	_rail(rails, "NorthRailW", Vector2(-20.0, -2.0), Vector2(-4.0, -2.0), 0.0, tint)
	_rail(rails, "NorthRailE", Vector2(4.0, -2.0), Vector2(20.0, -2.0), 0.0, tint)
	# 东、西平台栏杆；西侧中段留楼梯缺口。
	_rail(rails, "WestRailA", Vector2(-20.0, -2.0), Vector2(-20.0, 10.0), 0.0, tint)
	_rail(rails, "WestRailB", Vector2(-20.0, 13.0), Vector2(-20.0, 28.0), 0.0, tint)
	_rail(rails, "EastRailA", Vector2(20.0, -2.0), Vector2(20.0, 10.0), 0.0, tint)
	_rail(rails, "EastRailB", Vector2(20.0, 13.0), Vector2(20.0, 28.0), 0.0, tint)


func _rail(parent: Node3D, name: String, start: Vector2, end: Vector2, base_y: float,
		tint: Color) -> void:
	# 挡土墙本身已经在 Ground/CourtRetain* 里生成；这里只加扶手与柱头，
	# 不重复生成第二道墙，避免共面闪烁。
	var length := start.distance_to(end)
	if length < 0.2:
		return
	var center := (start + end) * 0.5
	var yaw := atan2(-(end.y - start.y), end.x - start.x)
	var rail_body := _static(parent, name + "_Handrail",
		Vector3(center.x, 0.9, center.y), yaw)
	var rail_builder := LowPoly.begin()
	_add_box(rail_builder, Vector3(0, 0.1, 0), Vector3(length, 0.16, 0.5),
		tint.lightened(0.05), 0.025)
	_mesh_node(rail_body, "Mesh", LowPoly.commit(rail_builder), _mats["stone"],
		Vector3.ZERO, 0.0, true)
	var posts := maxi(2, int(round(length / 2.4)))
	for index in posts + 1:
		var t := float(index) / float(posts)
		var at := start.lerp(end, t)
		var post := _static(parent, name + "_Post_%02d" % index, Vector3(at.x, 0.9, at.y))
		var b := LowPoly.begin()
		_add_box(b, Vector3(0, 0.34, 0), Vector3(0.28, 0.34, 0.28), tint.lightened(0.1), 0.02)
		_mesh_node(post, "Mesh", LowPoly.commit(b), _mats["stone"], Vector3.ZERO, yaw, true)


# ---------------------------------------------------------------- 庭院与回廊

func _build_court() -> void:
	var court := _group(scene_root, "Court")
	_fountain(court, "Fountain", Vector3(0, COURT_Y, 14.0), 0.0)
	_fallen_column(court, "FallenColumnWest", Vector3(-10.5, COURT_Y, 8.0), deg_to_rad(24.0))
	_fallen_column(court, "FallenColumnEast", Vector3(10.0, COURT_Y, 22.0), deg_to_rad(-38.0))
	_wall(court, "LowWallNorthWest", Vector2(-16.0, 20.0), Vector2(-11.0, 20.0),
		COURT_Y, 1.15, 0.55, Color(0.33, 0.34, 0.32))
	_wall(court, "LowWallSouthEast", Vector2(7.0, 5.0), Vector2(12.0, 5.0),
		COURT_Y, 1.15, 0.55, Color(0.33, 0.34, 0.32))
	_wall(court, "BrokenWallSouth", Vector2(-6.0, 24.5), Vector2(-2.0, 24.5),
		COURT_Y, 0.95, 0.5, Color(0.33, 0.34, 0.32), true)
	_wall(court, "LowWallMidWest", Vector2(-14.0, 13.0), Vector2(-10.0, 13.0),
		COURT_Y, 1.25, 0.55, Color(0.31, 0.32, 0.30))
	_fallen_column(court, "FallenColumnMidEast", Vector3(11.5, COURT_Y, 7.0), deg_to_rad(-52.0))
	_rubble(court, "CourtRubbleC", Vector3(6.5, COURT_Y, 20.0), 1.5)
	_bench(court, "BenchSouth", Vector3(-7.0, COURT_Y, 25.0), 0.0)
	_statue(court, "CourtSaintWest", Vector3(-15.0, COURT_Y, 22.0), PI * 0.15, 1.35,
		Color(0.42, 0.43, 0.40))
	_statue(court, "CourtSaintEast", Vector3(15.0, COURT_Y, 6.0), -PI * 0.65, 1.2,
		Color(0.40, 0.41, 0.39))
	_bench(court, "BenchWest", Vector3(-16.0, COURT_Y, 3.0), PI * 0.5)
	_bench(court, "BenchEast", Vector3(16.0, COURT_Y, 16.0), -PI * 0.5)
	_dead_tree(court, "CourtDeadTree", Vector3(-15.5, COURT_Y, 26.0), 1.1)
	_rubble(court, "CourtRubbleA", Vector3(12.5, COURT_Y, 26.0), 2.0)
	_rubble(court, "CourtRubbleB", Vector3(-7.0, COURT_Y, 2.0), 1.6)
	for index in 4:
		var at := Vector3(-15.0 + index * 9.0, COURT_Y + 0.03, 3.5 + (index % 2) * 2.0)
		_floor_stain(court, "CourtStain_%02d" % index, at, 1.8 + index * 0.3)
	for at in [Vector3(-17, COURT_Y + 0.03, 8), Vector3(17, COURT_Y + 0.03, 22),
			Vector3(-13, COURT_Y + 0.03, 25), Vector3(14, COURT_Y + 0.03, 3),
			Vector3(3, COURT_Y + 0.03, 26.5), Vector3(-8, COURT_Y + 0.03, -1)]:
		_floor_stain(court, "EdgeStain_%d_%d" % [roundi(at.x), roundi(at.z)], at, 1.1)


func _build_cloister() -> void:
	var cloister := _group(scene_root, "Cloister")
	for side in [-1.0, 1.0]:
		var x: float = 22.0 * side
		for index in 8:
			var z := -2.0 + index * 4.0
			if side > 0.0 and index == 2:
				continue
			var collapsed: bool = side > 0.0 and index >= 3 and index <= 5
			var pier := _pillar(cloister,
				"CloisterPier_%s_%02d" % [("W" if side < 0 else "E"), index],
				Vector3(x, 0, z), 3.35 if not collapsed else 1.35,
				Color(0.30, 0.31, 0.30), 0.44)
			if collapsed:
				_rubble(cloister, "CloisterRubble_%02d" % index,
					Vector3(x + side * 6.0, 0, z), 1.3)
		# 廊顶横梁与石板；东侧中段塌落，故意留出破口。
		var roof := _group(cloister, "Roof_%s" % ("W" if side < 0 else "E"))
		for index in 8:
			var z := -2.0 + index * 4.0
			if side > 0.0 and index >= 2 and index <= 5:
				continue
			var beam := LowPoly.begin()
			_add_box(beam, Vector3(x + side * 4.0, 3.55, z),
				Vector3(8.0, 0.26, 0.4), Color(0.18, 0.15, 0.12), 0.02)
			_mesh_node(roof, "Beam_%02d" % index, LowPoly.commit(beam), _mats["wood"],
				Vector3.ZERO, 0.0, true)
			var slab := LowPoly.begin()
			_add_box(slab, Vector3(x + side * 4.5, 3.72, z + 2.0),
				Vector3(8.8, 0.18, 3.8), Color(0.29, 0.30, 0.29), 0.04)
			_mesh_node(roof, "Slab_%02d" % index, LowPoly.commit(slab), _mats["stone"],
				Vector3.ZERO, 0.0, true)
		# 廊内侧的长凳与壁灯座
		_bench(cloister, "CloisterBench_%s" % ("W" if side < 0 else "E"),
			Vector3(x + side * 6.0, 0.0, 18.0 if side < 0 else 8.0), 0.0)
		_banner(cloister, "CloisterBanner_%s" % ("W" if side < 0 else "E"),
			Vector3(OUTER_X * side - side * 0.8, 3.0, 20.0 if side < 0 else 4.0),
			PI * 0.5 if side < 0 else -PI * 0.5, Color(0.20, 0.05, 0.06))
	# 东侧倒塌段的碎石堆
	_rubble(cloister, "EastCollapseRubble", Vector3(28.0, 0, 10.0), 1.5)


func _build_garths() -> void:
	var garths := _group(scene_root, "Garths")
	for side in [-1.0, 1.0]:
		var label := "W" if side < 0 else "E"
		var x_col: float = 18.0 * side
		var x_wall: float = 30.0 * side
		# 沿大礼拜堂侧墙的单坡回廊：柱列 + 靠墙屋面。
		for index in 7:
			var z := -8.0 - float(index) * 4.0
			_pillar(garths, "GarthPier_%s_%02d" % [label, index],
				Vector3(x_col, 0, z), 3.2, Color(0.31, 0.29, 0.25), 0.38)
			var roof_builder := LowPoly.begin()
			_add_box(roof_builder, Vector3(18.0 * side - 4.0 * side, 3.45, z + 2.0),
				Vector3(4.2, 0.18, 3.85), Color(0.22, 0.21, 0.19), 0.03)
			_add_box(roof_builder, Vector3(18.0 * side, 3.25, z + 2.0),
				Vector3(0.4, 0.28, 4.0), Color(0.18, 0.15, 0.12), 0.02)
			_mesh_node(garths, "GarthRoof_%s_%02d" % [label, index],
				LowPoly.commit(roof_builder), _mats["stone"], Vector3.ZERO, 0.0, true)
		# 草地、中央水井、长凳、圣像；外侧 5 m 让给修士院/食堂院。
		_garden_patch(garths, "GarthLawn_%s" % label,
			-23.0 if side < 0 else 18.5, -18.5 if side < 0 else 23.0, -34.0, -6.0,
			Color(0.12, 0.18, 0.11))
		_cloister_well(garths, "CloisterWell_%s" % label, Vector3(21.5 * side, 0, -20.0))
		_garden_tree(garths, "GarthTree_%s" % label, Vector3(20.0 * side, 0, -31.0), 1.0)
		_bench(garths, "GarthBench_%s_A" % label, Vector3(20.0 * side, 0, -14.0), PI * 0.5)
		_bench(garths, "GarthBench_%s_B" % label, Vector3(20.0 * side, 0, -25.0), PI * 0.5)
		_statue(garths, "GarthSaint_%s" % label, Vector3(18.8 * side, 0, -31.0),
			-PI * 0.5 * side, 0.8, Color(0.38, 0.35, 0.30), false, true)
		# 从侧门到水井的石铺小径。
		for index in 4:
			var path := _static(garths, "GarthPath_%s_%02d" % [label, index],
				Vector3(21.5 * side, 0.02, -6.0 - float(index) * 3.0))
			var path_builder := LowPoly.begin()
			_add_box(path_builder, Vector3.ZERO, Vector3(2.2, 0.05, 2.8),
				Color(0.34, 0.31, 0.27), 0.02)
			_mesh_node(path, "Mesh", LowPoly.commit(path_builder), _mats["stone"],
				Vector3.ZERO, 0.0, false)
	# 后廊：一圈窄的礼仪通道，把两侧庭院接起来。
	var rear := LowPoly.begin()
	_add_box(rear, Vector3(0, 0.02, -38.0), Vector3(52.0, 0.05, 3.2),
		Color(0.31, 0.29, 0.25), 0.02)
	_mesh_node(garths, "RearAmbulatoryPath", LowPoly.commit(rear), _mats["stone"],
		Vector3.ZERO, 0.0, false)
	_altar_table(garths, "RearStation", Vector3(0, 0, -38.4), 0.75, _mats["flame_red"])


func _garden_patch(parent: Node3D, name: String, x0: float, x1: float, z0: float, z1: float,
		tint: Color) -> void:
	var body := _static(parent, name, Vector3((x0 + x1) * 0.5, 0.005,
		(z0 + z1) * 0.5))
	var builder := LowPoly.begin()
	var columns := maxi(1, int(ceil((x1 - x0) / 3.0)))
	var rows := maxi(1, int(ceil((z1 - z0) / 3.0)))
	var step_x := (x1 - x0) / float(columns)
	var step_z := (z1 - z0) / float(rows)
	for ix in columns:
		for iz in rows:
			var at := Vector3(-(x1 - x0) * 0.5 + (float(ix) + 0.5) * step_x, 0.0,
				-(z1 - z0) * 0.5 + (float(iz) + 0.5) * step_z)
			_add_box(builder, at, Vector3(step_x + 0.02, 0.04, step_z + 0.02),
				_tone(tint, _rng.randf_range(-0.01, 0.01)), 0.0)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["moss"], Vector3.ZERO, 0.0, false)


func _columbarium(parent: Node3D, name: String, x: float, side: float) -> void:
	var body := _static(parent, name, Vector3(x, 0, -20.0))
	var builder := LowPoly.begin()
	var stone := Color(0.30, 0.28, 0.24)
	for index in 6:
		var z := -35.0 + float(index) * 5.0
		_add_box(builder, Vector3(0, 1.45, z), Vector3(0.25, 1.4, 1.25),
			Color(0.16, 0.15, 0.13), 0.02)
		_add_box(builder, Vector3(-0.18 * side, 1.45, z), Vector3(0.18, 1.1, 0.95),
			Color(0.36, 0.33, 0.28), 0.015)
		_add_box(builder, Vector3(-0.18 * side, 2.15, z), Vector3(0.34, 0.2, 1.4),
			stone.lightened(0.06), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)


func _build_monastery() -> void:
	var monastery := _group(scene_root, "Monastery")
	for side in [-1.0, 1.0]:
		_cloister_range(monastery, side)
		_furnish_range(monastery, side)
		_garden_life(monastery, side)
	_build_forecourt()
	_build_cemetery()
	_build_breach_defense()
	var hall := scene_root.get_node_or_null("Hall") as Node3D
	if hall != null:
		var kneeler := _static(hall, "AltarKneeler", Vector3(0.8, 0, -29.4))
		var kb := LowPoly.begin()
		_add_box(kb, Vector3(0, 0.16, 0), Vector3(0.8, 0.32, 0.55),
			Color(0.28, 0.18, 0.10), 0.02)
		_add_box(kb, Vector3(0, 0.34, -0.18), Vector3(0.7, 0.08, 0.34),
			Color(0.42, 0.16, 0.11), 0.01)
		_add_box(kb, Vector3(0, 0.38, 0.18), Vector3(0.42, 0.05, 0.3),
			Color(0.68, 0.60, 0.44), 0.01)
		_mesh_node(kneeler, "Mesh", LowPoly.commit(kb), _mats["props"], Vector3.ZERO, 0.0, true)
		_person(hall, "KneelingMonk", Vector3(0.8, 0, -29.75), 0.0, "pray",
			Color(0.21, 0.20, 0.17), Color(0.15, 0.14, 0.12), "")
	var inner_gate := scene_root.get_node_or_null("InnerGate") as Node3D
	if inner_gate != null:
		_person(inner_gate, "InnerGuardW", Vector3(-4.1, 0, -2.6), PI, "guard",
			Color(0.24, 0.21, 0.17), Color(0.17, 0.15, 0.12), "spear")
		_person(inner_gate, "InnerGuardE", Vector3(4.1, 0, -2.6), PI, "guard",
			Color(0.24, 0.21, 0.17), Color(0.17, 0.15, 0.12), "spear")


func _cloister_range(parent: Node3D, side: float) -> void:
	var label := "W" if side < 0 else "E"
	var inner: float = 25.0 * side
	var outer: float = 30.0 * side
	var back: float = outer - side * 0.45
	var z0 := -34.0
	var z1 := -6.0
	var height := 6.8
	var tint := Color(0.31, 0.29, 0.25)
	var range := _group(parent, "CloisterRange_%s" % label)
	# 外侧承重墙、端墙与内廊墙。内墙留三个门洞，分别进议事厅/缮写室/病房
	# 或厨房/食堂/地窖。
	_wall(range, "BackWall", Vector2(back, z0), Vector2(back, z1), 0.0, height, 0.55, tint)
	_wall(range, "EndSouth", Vector2(inner, z1), Vector2(back, z1), 0.0, height, 0.75, tint)
	_wall(range, "EndNorth", Vector2(inner, z0), Vector2(back, z0), 0.0, height, 0.75, tint)
	var doors: Array = [-30.0, -20.0, -10.0] if side < 0 else [-30.0, -18.0, -8.0]
	var cursor := z0
	for index in doors.size():
		var door_z: float = doors[index]
		var a := door_z - 1.15
		var b := door_z + 1.15
		if a > cursor:
			_wall(range, "InnerWall_%s_%02d" % [label, index],
				Vector2(inner, cursor), Vector2(inner, a), 0.0, height, 0.8, tint)
		# 门洞过梁 + 开着的木门扇
		var lintel := _static(range, "RangeDoorLintel_%s_%02d" % [label, index],
			Vector3(inner, 0, door_z))
		var lb := LowPoly.begin()
		_add_box(lb, Vector3(0, (2.7 + height) * 0.5, 0),
			Vector3(0.95, height - 2.7, 2.3), tint, 0.03)
		_add_box(lb, Vector3(0, 2.62, 0), Vector3(1.15, 0.18, 2.6),
			tint.lightened(0.08), 0.02)
		_add_box(lb, Vector3(float(-side) * 0.48, 1.35, 1.0),
			Vector3(0.1, 2.5, 1.0), Color(0.23, 0.15, 0.09), 0.02)
		_mesh_node(lintel, "Mesh", LowPoly.commit(lb), _mats["stone"],
			Vector3.ZERO, 0.0, true)
		_box_collision(lintel, Vector3(0.95, height - 2.7, 2.3),
			Vector3(0, (2.7 + height) * 0.5, 0))
		cursor = b
	if cursor < z1:
		_wall(range, "InnerWall_%s_End" % label, Vector2(inner, cursor),
			Vector2(inner, z1), 0.0, height, 0.8, tint)
	# 一层顶板/二层楼板，廊内是木/石混合天花。
	var ceiling := _static(range, "RangeCeiling_%s" % label, Vector3((inner + back) * 0.5, 0,
		(z0 + z1) * 0.5))
	var cb := LowPoly.begin()
	_add_box(cb, Vector3(0, 3.3, 0), Vector3(absf(back - inner), 0.3, z1 - z0 - 0.3),
		Color(0.25, 0.21, 0.16), 0.03)
	_mesh_node(ceiling, "Mesh", LowPoly.commit(cb), _mats["stone"], Vector3.ZERO, 0.0, true)
	# 一层房间隔墙
	var partitions: Array = [-26.0, -16.0] if side < 0 else [-24.0, -12.0]
	for pz in partitions:
		_wall(range, "Partition_%s_%d" % [label, roundi(pz)],
			Vector2(inner, pz), Vector2(back, pz), 0.0, 3.2, 0.45,
			Color(0.28, 0.26, 0.22))
	# 上层窗与下层窗：先从外面读成两层，再让室内有光。
	var windows := _static(range, "RangeWindows_%s" % label, Vector3.ZERO)
	var wb := LowPoly.begin()
	var win_z: Array = [-32.0, -24.0, -16.0, -8.0]
	for wz in win_z:
		var face: float = inner - side * 0.42
		_add_box(wb, Vector3(face, 4.9, float(wz)), Vector3(0.12, 1.2, 0.72),
			Color(0.08, 0.13, 0.18), 0.012)
		_add_box(wb, Vector3(face - side * 0.03, 5.55, float(wz)),
			Vector3(0.2, 0.16, 0.95), tint.lightened(0.08), 0.012)
		_add_box(wb, Vector3(face, 2.0, float(wz)), Vector3(0.12, 0.75, 0.55),
			Color(0.10, 0.12, 0.13), 0.01)
	_mesh_node(windows, "Mesh", LowPoly.commit(wb), _mats["stone"], Vector3.ZERO, 0.0, true)
	# 扶壁与层间线脚
	var trim := _static(range, "RangeTrim_%s" % label, Vector3.ZERO)
	var tb := LowPoly.begin()
	for bz in [-32.0, -28.0, -24.0, -20.0, -16.0, -12.0, -8.0]:
		_add_box(tb, Vector3(inner - side * 0.3, 3.0, float(bz)),
			Vector3(0.4, 5.6, 0.5), tint.lightened(0.03), 0.02)
	_add_box(tb, Vector3(inner - side * 0.38, 3.28, (z0 + z1) * 0.5),
		Vector3(0.3, 0.2, z1 - z0), tint.lightened(0.06), 0.02)
	_mesh_node(trim, "Mesh", LowPoly.commit(tb), _mats["stone"], Vector3.ZERO, 0.0, true)
	# 双坡屋顶（一个网格，避免旋转盒的接缝）。
	var roof := _static(range, "RangeRoof_%s" % label, Vector3.ZERO)
	var rb := LowPoly.begin()
	var eave_y := 6.4
	var ridge_y := 8.2
	var ridge_x: float = (inner + outer) * 0.5
	var roof_tint := Color(0.16, 0.17, 0.19)
	for z_pair in [[z0, z1]]:
		var za: float = z_pair[0]
		var zb: float = z_pair[1]
		var a := Vector3(inner, eave_y, za)
		var b := Vector3(ridge_x, ridge_y, za)
		var c := Vector3(ridge_x, ridge_y, zb)
		var d := Vector3(inner, eave_y, zb)
		LowPoly.push_quad(rb, a, b, c, d, roof_tint)
		var e := Vector3(ridge_x, ridge_y, za)
		var f := Vector3(outer, eave_y, za)
		var g := Vector3(outer, eave_y, zb)
		var h := Vector3(ridge_x, ridge_y, zb)
		LowPoly.push_quad(rb, e, f, g, h, roof_tint.lightened(0.03))
		# 两端山墙三角
		LowPoly.push_triangle(rb, Vector3(inner, eave_y, za),
			Vector3(ridge_x, ridge_y, za), Vector3(outer, eave_y, za), roof_tint.darkened(0.05))
		LowPoly.push_triangle(rb, Vector3(outer, eave_y, zb),
			Vector3(ridge_x, ridge_y, zb), Vector3(inner, eave_y, zb), roof_tint.darkened(0.05))
	_add_box(rb, Vector3(ridge_x, ridge_y + 0.12, (z0 + z1) * 0.5),
		Vector3(0.42, 0.3, z1 - z0), Color(0.12, 0.12, 0.13), 0.03)
	_mesh_node(roof, "Mesh", LowPoly.commit(rb), _mats["stone"], Vector3.ZERO, 0.0, true)
	# 朝向庭院的单坡柱廊：让修士院/食堂院的门前有真正的回廊，而不是一堵光墙。
	var walk_posts := _static(range, "RangeWalkPosts_%s" % label, Vector3.ZERO)
	var wp := LowPoly.begin()
	for wz in [-8.0, -12.0, -16.0, -24.0, -28.0, -32.0]:
		_add_box(wp, Vector3(inner - side * 1.8, 1.6, wz), Vector3(0.32, 3.2, 0.32),
			tint.lightened(0.04), 0.02)
		_add_box(wp, Vector3(inner - side * 1.8, 0.18, wz), Vector3(0.55, 0.35, 0.55),
			tint.darkened(0.06), 0.02)
	_mesh_node(walk_posts, "Mesh", LowPoly.commit(wp), _mats["stone"], Vector3.ZERO, 0.0, true)
	var walk_roof := _static(range, "RangeWalkRoof_%s" % label, Vector3.ZERO)
	var wr := LowPoly.begin()
	_add_box(wr, Vector3(inner - side * 0.95, 3.28, -20.0),
		Vector3(2.15, 0.18, 28.0), Color(0.24, 0.21, 0.17), 0.04)
	_add_box(wr, Vector3(inner - side * 1.9, 3.12, -20.0),
		Vector3(0.18, 0.3, 28.0), Color(0.20, 0.15, 0.10), 0.02)
	_mesh_node(walk_roof, "Mesh", LowPoly.commit(wr), _mats["stone"], Vector3.ZERO, 0.0, true)
	# 西侧议事厅门廊与钟；东侧厨房烟囱。
	if side < 0:
		var porch := _static(range, "ChapterPorch", Vector3(inner - side * 0.1, 0, -30.0))
		var pb := LowPoly.begin()
		for jamb in [-1.7, 1.7]:
			_add_box(pb, Vector3(-0.2, 2.0, jamb), Vector3(0.5, 4.0, 0.45),
				tint.lightened(0.04), 0.02)
		_add_box(pb, Vector3(-0.2, 4.1, 0), Vector3(0.6, 0.3, 3.9),
			tint.lightened(0.07), 0.02)
		_add_box(pb, Vector3(-0.35, 5.0, 0), Vector3(0.2, 1.7, 3.2),
			tint, 0.02)
		_add_cyl(pb, Vector3(-0.15, 5.1, 0), 0.18, 0.34, 0.42,
			Color(0.38, 0.28, 0.12), 10)
		_add_rock(pb, Vector3(-0.15, 5.35, 0), 0.12, 0.2, Color(0.38, 0.28, 0.12))
		_mesh_node(porch, "Mesh", LowPoly.commit(pb), _mats["stone"], Vector3.ZERO, 0.0, true)
		_cross_finial(range, "ChapterCross", Vector3(inner - side * 0.2, 6.05, -30.0), 0.9)
	else:
		var chimney := _static(range, "KitchenChimney", Vector3(28.2, 0, -30.0))
		var chb := LowPoly.begin()
		_add_box(chb, Vector3(0, 4.6, 0), Vector3(1.15, 9.2, 1.15),
			tint.darkened(0.04), 0.03)
		_add_box(chb, Vector3(0, 9.25, 0), Vector3(1.55, 0.35, 1.55),
			tint.lightened(0.05), 0.02)
		_mesh_node(chimney, "Mesh", LowPoly.commit(chb), _mats["stone"], Vector3.ZERO, 0.0, true)


func _room_light(parent: Node3D, name: String, position: Vector3) -> void:
	var light := OmniLight3D.new()
	light.name = name
	light.position = position
	light.light_color = Color(1.0, 0.64, 0.36)
	light.light_energy = 3.2
	light.omni_range = 9.0
	light.omni_attenuation = 1.5
	light.shadow_enabled = false
	parent.add_child(light)
	light.owner = scene_root


func _furnish_range(parent: Node3D, side: float) -> void:
	var label := "W" if side < 0 else "E"
	var inner: float = 25.0 * side
	var inside_x: float = inner + side * 2.3
	var group := _group(parent, "RangeInterior_%s" % label)
	if side < 0:
		_furnish_chapter(group, inside_x)
		_furnish_scriptorium(group, inside_x)
		_furnish_infirmary(group, inside_x)
	else:
		_furnish_kitchen(group, inside_x)
		_furnish_refectory(group, inside_x)
		_furnish_cellar(group, inside_x)


func _furnish_chapter(parent: Node3D, x: float) -> void:
	var body := _static(parent, "ChapterFurniture", Vector3(x, 0, -30.0))
	var b := LowPoly.begin()
	_add_box(b, Vector3(0, 0.78, 0), Vector3(1.1, 0.12, 5.2), Color(0.30, 0.20, 0.12), 0.02)
	for leg in [-2.3, 2.3]:
		_add_box(b, Vector3(0, 0.4, leg), Vector3(0.9, 0.7, 0.22),
			Color(0.22, 0.15, 0.10), 0.02)
	for bench_z in [-1.8, 1.8]:
		_add_box(b, Vector3(1.2, 0.45, bench_z), Vector3(0.45, 0.08, 3.4),
			Color(0.30, 0.20, 0.12), 0.02)
		_add_box(b, Vector3(1.2, 0.22, bench_z), Vector3(0.35, 0.42, 3.0),
			Color(0.22, 0.15, 0.10), 0.02)
	_add_box(b, Vector3(0, 1.1, -2.6), Vector3(0.8, 0.9, 0.16),
		Color(0.34, 0.22, 0.13), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(b), _mats["props"], Vector3.ZERO, 0.0, true)
	_room_light(parent, "ChapterLight", Vector3(x, 2.6, -30.0))
	_person(parent, "PriorAnselm", Vector3(x + 0.9, 0, -31.8), PI,
		"stand", Color(0.20, 0.19, 0.17), Color(0.15, 0.14, 0.12), "book")


func _furnish_scriptorium(parent: Node3D, x: float) -> void:
	var body := _static(parent, "ScriptoriumFurniture", Vector3(x, 0, -20.0))
	var b := LowPoly.begin()
	for desk_z in [-23.0, -20.0, -17.0]:
		_add_box(b, Vector3(0, 0.78, desk_z), Vector3(1.0, 0.1, 1.1),
			Color(0.31, 0.21, 0.12), 0.02, Basis(Vector3.RIGHT, deg_to_rad(8.0)))
		for leg in [-0.42, 0.42]:
			_add_box(b, Vector3(0, 0.38, desk_z + leg), Vector3(0.8, 0.7, 0.12),
				Color(0.22, 0.15, 0.10), 0.02)
		_add_box(b, Vector3(-0.1, 0.86, desk_z + 0.1), Vector3(0.34, 0.05, 0.45),
			Color(0.72, 0.66, 0.52), 0.01)
		_add_box(b, Vector3(0.9, 0.45, desk_z), Vector3(0.4, 0.08, 0.6),
			Color(0.28, 0.19, 0.11), 0.02)
	_add_box(b, Vector3(1.8, 1.25, -20.0), Vector3(0.35, 2.5, 4.4),
		Color(0.24, 0.16, 0.10), 0.02)
	for shelf in 3:
		_add_box(b, Vector3(1.62, 0.65 + shelf * 0.55, -20.0), Vector3(0.3, 0.06, 4.0),
			Color(0.34, 0.23, 0.14), 0.01)
	_mesh_node(body, "Mesh", LowPoly.commit(b), _mats["props"], Vector3.ZERO, 0.0, true)
	_room_light(parent, "ScriptoriumLight", Vector3(x, 2.6, -20.0))
	_person(parent, "ScribeBrother", Vector3(x - 0.9, 0, -20.0), PI * 0.5,
		"sit", Color(0.22, 0.21, 0.18), Color(0.16, 0.15, 0.13), "book")


func _furnish_infirmary(parent: Node3D, x: float) -> void:
	var body := _static(parent, "InfirmaryFurniture", Vector3(x, 0, -11.0))
	var b := LowPoly.begin()
	for bed_z in [-13.0, -9.0]:
		_add_box(b, Vector3(0, 0.45, bed_z), Vector3(0.9, 0.18, 2.0),
			Color(0.34, 0.24, 0.15), 0.02)
		_add_box(b, Vector3(0, 0.62, bed_z), Vector3(0.78, 0.14, 1.8),
			Color(0.56, 0.52, 0.42), 0.01)
		_add_box(b, Vector3(0, 0.75, bed_z - 0.55), Vector3(0.66, 0.12, 0.5),
			Color(0.48, 0.18, 0.12), 0.01)
		for leg in [-0.85, 0.85]:
			for leg_side in [-0.38, 0.38]:
				_add_box(b, Vector3(leg_side, 0.22, bed_z + leg), Vector3(0.12, 0.45, 0.12),
					Color(0.22, 0.15, 0.10), 0.01)
	_add_box(b, Vector3(1.3, 0.75, -11.0), Vector3(0.7, 0.1, 1.2),
		Color(0.32, 0.21, 0.12), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(b), _mats["props"], Vector3.ZERO, 0.0, true)
	_room_light(parent, "InfirmaryLight", Vector3(x, 2.6, -11.0))
	_person(parent, "Infirmarian", Vector3(x + 0.8, 0, -11.0), -PI * 0.5,
		"stand", Color(0.25, 0.23, 0.19), Color(0.17, 0.16, 0.13), "basket")


func _furnish_kitchen(parent: Node3D, x: float) -> void:
	var body := _static(parent, "KitchenFurniture", Vector3(x, 0, -30.0))
	var b := LowPoly.begin()
	_add_box(b, Vector3(1.5, 1.25, 0), Vector3(1.9, 2.5, 4.4),
		Color(0.28, 0.25, 0.21), 0.03)
	_add_box(b, Vector3(1.0, 0.9, 0), Vector3(0.8, 0.3, 2.6),
		Color(0.16, 0.12, 0.08), 0.02)
	_add_box(b, Vector3(0.75, 0.45, 0), Vector3(0.7, 0.6, 2.0),
		Color(0.24, 0.18, 0.12), 0.02)
	_add_cyl(b, Vector3(0.4, 0.95, -1.0), 0.48, 0.36, 0.55,
		Color(0.12, 0.12, 0.12), 12)
	_add_cyl(b, Vector3(0.4, 1.27, -1.0), 0.5, 0.5, 0.08,
		Color(0.18, 0.13, 0.08), 12)
	# 吊挂香草/锅具
	for z in [-1.8, 0.0, 1.8]:
		_add_cyl(b, Vector3(-1.4, 2.2, z), 0.07, 0.1, 0.55,
			Color(0.38, 0.24, 0.12), 6)
	_add_box(b, Vector3(-0.2, 0.7, 2.2), Vector3(1.6, 0.12, 0.8),
		Color(0.32, 0.21, 0.12), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(b), _mats["props"], Vector3.ZERO, 0.0, true)
	_room_light(parent, "KitchenLight", Vector3(x, 2.6, -30.0))
	_person(parent, "CookBrother", Vector3(x - 0.6, 0, -30.0), 0.0,
		"work", Color(0.28, 0.22, 0.16), Color(0.20, 0.16, 0.12), "ladle")


func _furnish_refectory(parent: Node3D, x: float) -> void:
	var body := _static(parent, "RefectoryFurniture", Vector3(x, 0, -18.0))
	var b := LowPoly.begin()
	for table_z in [-21.0, -15.0]:
		_add_box(b, Vector3(0, 0.78, table_z), Vector3(1.0, 0.12, 4.6),
			Color(0.32, 0.22, 0.13), 0.02)
		for leg in [-2.0, 2.0]:
			_add_box(b, Vector3(0, 0.4, table_z + leg), Vector3(0.8, 0.7, 0.2),
				Color(0.22, 0.15, 0.10), 0.02)
		for bench_z in [-0.9, 0.9]:
			_add_box(b, Vector3(1.1, 0.45, table_z + bench_z), Vector3(0.4, 0.08, 3.2),
				Color(0.30, 0.20, 0.12), 0.02)
			_add_box(b, Vector3(1.1, 0.22, table_z + bench_z), Vector3(0.3, 0.42, 2.8),
				Color(0.22, 0.15, 0.10), 0.02)
		for bowl in [-1.4, 0.0, 1.4]:
			_add_cyl(b, Vector3(0, 0.9, table_z + bowl), 0.16, 0.11, 0.1,
				Color(0.62, 0.54, 0.38), 10)
	_add_box(b, Vector3(-1.8, 1.9, -18.0), Vector3(0.6, 2.8, 0.8),
		Color(0.25, 0.17, 0.10), 0.02)
	_add_box(b, Vector3(-1.75, 2.8, -18.0), Vector3(0.8, 0.12, 1.0),
		Color(0.34, 0.23, 0.13), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(b), _mats["props"], Vector3.ZERO, 0.0, true)
	_room_light(parent, "RefectoryLight", Vector3(x, 2.6, -18.0))
	_person(parent, "ReaderBrother", Vector3(x - 0.2, 0, -15.4), PI * 0.5,
		"stand", Color(0.22, 0.21, 0.18), Color(0.16, 0.15, 0.13), "book")
	_person(parent, "DiningBrother", Vector3(x + 0.9, 0, -21.0), -PI * 0.5,
		"sit", Color(0.25, 0.23, 0.19), Color(0.17, 0.16, 0.13), "")


func _furnish_cellar(parent: Node3D, x: float) -> void:
	var body := _static(parent, "CellarFurniture", Vector3(x, 0, -9.0))
	var b := LowPoly.begin()
	for barrel in [[-1.2, -10.2], [0.4, -9.0], [-0.5, -7.6], [1.2, -7.4]]:
		_add_cyl(b, Vector3(barrel[0], 0.62, barrel[1]), 0.52, 0.58, 1.24,
			Color(0.30, 0.19, 0.10), 12)
		_add_cyl(b, Vector3(barrel[0], 0.62, barrel[1]), 0.54, 0.54, 0.08,
			Color(0.18, 0.13, 0.09), 12)
	_add_box(b, Vector3(1.7, 0.55, -9.0), Vector3(0.9, 1.1, 1.3),
		Color(0.28, 0.18, 0.10), 0.02)
	for sack in [[-1.5, -8.2], [0.0, -7.2]]:
		_add_rock(b, Vector3(sack[0], 0.35, sack[1]), 0.34, 0.7,
			Color(0.45, 0.39, 0.28))
	_mesh_node(body, "Mesh", LowPoly.commit(b), _mats["props"], Vector3.ZERO, 0.0, true)
	_room_light(parent, "CellarLight", Vector3(x, 2.5, -9.0))
	_person(parent, "Cellarer", Vector3(x - 1.4, 0, -9.0), PI * 0.5,
		"stand", Color(0.24, 0.22, 0.18), Color(0.16, 0.15, 0.13), "book")


func _garden_life(parent: Node3D, side: float) -> void:
	var label := "W" if side < 0 else "E"
	var group := _group(parent, "GardenLife_%s" % label)
	var b := LowPoly.begin()
	if side > 0.0:
		# 菜畦/药草畦、稻草人、三只鸡。
		for bed_z in [-29.0, -25.0, -17.0, -13.0]:
			_add_box(b, Vector3(20.0, 0.22, bed_z), Vector3(2.3, 0.42, 1.15),
				Color(0.28, 0.22, 0.14), 0.02)
			for row in 4:
				_add_box(b, Vector3(19.2 + row * 0.42, 0.48, bed_z),
					Vector3(0.28, 0.16, 0.82), Color(0.13, 0.27, 0.10), 0.02)
		_add_cyl(b, Vector3(19.2, 0.95, -28.0), 0.05, 0.06, 1.9,
			Color(0.26, 0.17, 0.09), 6)
		_add_box(b, Vector3(19.2, 1.55, -28.0), Vector3(1.3, 0.08, 0.08),
			Color(0.26, 0.17, 0.09), 0.01)
		_add_rock(b, Vector3(19.2, 1.85, -28.0), 0.16, 0.3, Color(0.55, 0.46, 0.28))
		_add_cyl(b, Vector3(19.2, 2.02, -28.0), 0.3, 0.22, 0.12,
			Color(0.30, 0.20, 0.10), 8)
		for chicken in [[19.8, -12.0, 0.0], [20.8, -13.2, 0.4], [20.2, -11.0, -0.3]]:
			_add_rock(b, Vector3(chicken[0], 0.25, chicken[1]), 0.18, 0.34,
				Color(0.72, 0.66, 0.52))
			_add_rock(b, Vector3(chicken[0] + 0.12, 0.43, chicken[1] + 0.04),
				0.08, 0.14, Color(0.82, 0.76, 0.60))
			_add_cone(b, Vector3(chicken[0] + 0.22, 0.42, chicken[1] + 0.04),
				0.035, 0.1, Color(0.75, 0.48, 0.08))
			for leg in [-0.06, 0.06]:
				_add_box(b, Vector3(chicken[0] + leg, 0.08, chicken[1]),
					Vector3(0.03, 0.16, 0.03), Color(0.52, 0.36, 0.10), 0.01)
		_person(group, "GardenerBrother", Vector3(20.6, 0, -28.5), PI,
			"work", Color(0.29, 0.25, 0.18), Color(0.19, 0.17, 0.13), "hoe")
	else:
		# 晾衣绳、木盆、井边打水的修士。
		for z in [-23.0]:
			for x in [-22.6, -19.0]:
				_add_cyl(b, Vector3(x, 1.15, z), 0.06, 0.08, 2.3,
					Color(0.24, 0.16, 0.09), 6)
		_add_box(b, Vector3(-20.8, 2.28, -23.0), Vector3(3.7, 0.04, 0.04),
			Color(0.42, 0.36, 0.22), 0.01)
		for index in 3:
			_add_box(b, Vector3(-22.0 + index * 0.95, 1.75, -23.0),
				Vector3(0.78, 1.1, 0.05), Color(0.68, 0.66, 0.58), 0.01)
		_add_cyl(b, Vector3(-19.8, 0.35, -24.4), 0.38, 0.3, 0.45,
			Color(0.34, 0.24, 0.13), 10)
		_person(group, "LaundryBrother", Vector3(-21.0, 0, -24.2), PI * 0.5,
			"work", Color(0.26, 0.23, 0.18), Color(0.17, 0.15, 0.12), "basket")
		_person(group, "WellBrother", Vector3(-22.6, 0, -20.4), PI * 0.5,
			"stand", Color(0.23, 0.21, 0.18), Color(0.16, 0.14, 0.12), "basket")
	_mesh_node(group, "Mesh", LowPoly.commit(b), _mats["props"], Vector3.ZERO, 0.0, true)


func _build_forecourt() -> void:
	var forecourt := _group(scene_root, "Forecourt")
	_hospice(forecourt)
	_stable(forecourt)


func _build_cemetery() -> void:
	var cemetery := _group(scene_root, "Cemetery")
	var b := _static(cemetery, "GraveSlabs", Vector3(0, 0, -38.8))
	var gb := LowPoly.begin()
	for index in 6:
		var x := -22.0 + float(index) * 3.6
		_add_box(gb, Vector3(x, 0.16, 0), Vector3(1.1, 0.18, 2.0),
			Color(0.28, 0.27, 0.24), 0.02)
		_add_box(gb, Vector3(x, 0.75, -0.85), Vector3(0.75, 0.9, 0.16),
			Color(0.33, 0.31, 0.27), 0.02)
	_mesh_node(b, "Mesh", LowPoly.commit(gb), _mats["stone"], Vector3.ZERO, 0.0, true)
	var cross := _static(cemetery, "CemeteryCross", Vector3(-16.0, 0, -38.9))
	var cb := LowPoly.begin()
	_add_box(cb, Vector3(0, 0.18, 0), Vector3(1.2, 0.36, 1.2), Color(0.30, 0.28, 0.24), 0.02)
	_add_box(cb, Vector3(0, 1.8, 0), Vector3(0.18, 3.2, 0.18), Color(0.45, 0.36, 0.20), 0.01)
	_add_box(cb, Vector3(0, 2.3, 0), Vector3(0.9, 0.18, 0.18), Color(0.45, 0.36, 0.20), 0.01)
	_mesh_node(cross, "Mesh", LowPoly.commit(cb), _mats["stone"], Vector3.ZERO, 0.0, true)
	_person(cemetery, "Mourner", Vector3(-19.5, 0, -38.2), PI * 0.5,
		"pray", Color(0.18, 0.17, 0.15), Color(0.13, 0.12, 0.11), "")


func _build_breach_defense() -> void:
	var breach := _group(scene_root, "BreachDefense")
	# 东侧上层回廊的塌落段：临时木撑、碎石、拒马和值守。
	var scaffold := _static(breach, "BreachScaffold", Vector3(22.0, 0, 12.0))
	var sb := LowPoly.begin()
	for x in [-1.6, 1.6]:
		for z in [-2.8, 2.8]:
			_add_box(sb, Vector3(x, 1.6, z), Vector3(0.22, 3.2, 0.22),
				Color(0.28, 0.19, 0.11), 0.01)
	for y in [1.0, 2.0, 3.0]:
		_add_box(sb, Vector3(0, y, -2.8), Vector3(3.5, 0.18, 0.18),
			Color(0.28, 0.19, 0.11), 0.01)
		_add_box(sb, Vector3(0, y, 2.8), Vector3(3.5, 0.18, 0.18),
			Color(0.28, 0.19, 0.11), 0.01)
		_add_box(sb, Vector3(0, y, 0), Vector3(3.5, 0.16, 5.8),
			Color(0.34, 0.25, 0.15), 0.02)
	# 斜撑和靠墙的短梯，读成修缮而不是空木架。
	for side in [-1.0, 1.0]:
		_add_box(sb, Vector3(side * 0.9, 1.5, -2.8), Vector3(0.16, 3.4, 0.16),
			Color(0.24, 0.16, 0.09), 0.01, Basis(Vector3.RIGHT, deg_to_rad(28.0)))
	_add_box(sb, Vector3(2.1, 1.5, -3.3), Vector3(0.16, 3.0, 0.16),
		Color(0.26, 0.18, 0.10), 0.01, Basis(Vector3.BACK, deg_to_rad(-18.0)))
	for rung in 4:
		_add_box(sb, Vector3(2.1, 0.4 + rung * 0.6, -3.3), Vector3(0.7, 0.08, 0.1),
			Color(0.30, 0.21, 0.12), 0.01)
	_mesh_node(scaffold, "Mesh", LowPoly.commit(sb), _mats["props"], Vector3.ZERO, 0.0, true)
	var barricade := _static(breach, "BreachBarricade", Vector3(22.0, 0, 7.0))
	var bb := LowPoly.begin()
	for x in [-2.0, -0.7, 0.7, 2.0]:
		_add_box(bb, Vector3(x, 0.55, 0), Vector3(0.9, 1.1, 0.2),
			Color(0.30, 0.21, 0.13), 0.02)
	for x in [-1.6, 0.0, 1.6]:
		_add_box(bb, Vector3(x, 0.9, 0.22), Vector3(0.18, 1.8, 0.18),
			Color(0.30, 0.21, 0.13), 0.01)
	_mesh_node(barricade, "Mesh", LowPoly.commit(bb), _mats["props"], Vector3.ZERO, 0.0, true)
	_box_collision(barricade, Vector3(4.5, 1.6, 0.5), Vector3(0, 0.8, 0))
	_person(breach, "MasonBrother", Vector3(20.2, 0, 12.0), -PI * 0.5,
		"work", Color(0.28, 0.24, 0.18), Color(0.18, 0.16, 0.12), "hammer")
	_person(breach, "BreachGuard", Vector3(23.8, 0, 8.2), PI,
		"guard", Color(0.22, 0.21, 0.18), Color(0.16, 0.15, 0.13), "spear")


func _person(parent: Node3D, name: String, position: Vector3, yaw: float, pose: String,
		robe: Color, hood: Color, tool: String) -> void:
	var body := _static(parent, name, position, yaw)
	body.add_to_group("People")
	var builder := LowPoly.begin()
	var skin := Color(0.60, 0.46, 0.34)
	var wood := Color(0.24, 0.16, 0.09)
	var iron := Color(0.22, 0.23, 0.24)
	var factor := 1.0
	match pose:
		"pray":
			factor = 0.68
		"sit":
			factor = 0.74
		"work":
			factor = 0.96
	var f := factor
	# 长袍、肩、腰带
	_add_cyl(builder, Vector3(0, 0.63 * f, 0), 0.22, 0.34, 1.24 * f, robe, 8)
	_add_box(builder, Vector3(0, 1.26 * f, 0), Vector3(0.44, 0.42 * f, 0.30), robe.darkened(0.05), 0.02)
	_add_cyl(builder, Vector3(0, 0.91 * f, 0), 0.28, 0.28, 0.07, Color(0.32, 0.23, 0.12), 8)
	# 头、兜帽与面纱
	_add_rock(builder, Vector3(0, 1.62 * f, 0.02), 0.14, 0.30, skin)
	_add_cyl(builder, Vector3(0, 1.52 * f, -0.05), 0.16, 0.27, 0.28, hood, 8)
	_add_box(builder, Vector3(0, 1.55 * f, -0.14), Vector3(0.30, 0.36, 0.10), hood, 0.02)
	# 手臂：自然下垂/祈祷合手/工作前伸/守卫持矛
	for side in [-1.0, 1.0]:
		var ax: float = 0.24 * side
		var ay: float = 1.04 * f
		var az := 0.0
		var arm_length: float = 0.44 * f
		if pose == "pray":
			ax = 0.12 * side
			az = 0.17
			ay = 1.00 * f
		elif pose == "work" and side > 0.0:
			ax = 0.30
			az = 0.24
			ay = 1.02 * f
		elif pose == "guard" and side > 0.0:
			ax = 0.35
			az = 0.10
			ay = 1.05 * f
		_add_cyl(builder, Vector3(ax, ay, az), 0.055, 0.07, arm_length, robe, 6)
		_add_rock(builder, Vector3(ax, ay - arm_length * 0.52, az + (0.14 if pose == "pray" else 0.0)),
			0.06, 0.12, skin)
	# 脚/坐姿
	if pose == "sit":
		for side in [-1.0, 1.0]:
			_add_box(builder, Vector3(0.13 * side, 0.25, 0.24), Vector3(0.18, 0.5, 0.24),
				robe.darkened(0.08), 0.02)
			_add_box(builder, Vector3(0.13 * side, 0.06, 0.38), Vector3(0.16, 0.1, 0.3),
				Color(0.20, 0.15, 0.11), 0.01)
	elif pose != "pray":
		for side in [-1.0, 1.0]:
			_add_box(builder, Vector3(0.13 * side, 0.06, 0.10), Vector3(0.18, 0.12, 0.34),
				Color(0.20, 0.15, 0.11), 0.01)
	if pose == "guard":
		_add_rock(builder, Vector3(0, 1.70 * f, 0.02), 0.17, 0.22,
			Color(0.30, 0.31, 0.32))
		_add_box(builder, Vector3(0, 1.60 * f, 0.17), Vector3(0.08, 0.16, 0.06),
			Color(0.20, 0.21, 0.22), 0.01)
	# 工具
	match tool:
		"spear":
			_add_cyl(builder, Vector3(0.38, 1.2, 0.12), 0.045, 0.05, 2.3, wood, 6)
			_add_cone(builder, Vector3(0.38, 2.38, 0.12), 0.11, 0.28, iron)
			_add_box(builder, Vector3(-0.40, 0.98, 0.22), Vector3(0.10, 0.78, 0.56),
				Color(0.28, 0.20, 0.12), 0.02)
			_add_cyl(builder, Vector3(-0.40, 0.98, 0.22), 0.13, 0.13, 0.09,
				Color(0.25, 0.26, 0.27), 8, Basis(Vector3.BACK, PI * 0.5))
		"staff":
			_add_cyl(builder, Vector3(0.36, 1.1, 0.15), 0.045, 0.055, 2.1, wood, 6)
		"hammer":
			_add_cyl(builder, Vector3(0.34, 1.0, 0.28), 0.05, 0.055, 0.55, wood, 6,
				Basis(Vector3.RIGHT, deg_to_rad(35.0)))
			_add_box(builder, Vector3(0.34, 1.20, 0.50), Vector3(0.28, 0.14, 0.14), iron, 0.01)
		"hoe":
			_add_cyl(builder, Vector3(0.32, 0.85, 0.30), 0.04, 0.05, 1.3, wood, 6,
				Basis(Vector3.RIGHT, deg_to_rad(48.0)))
			_add_box(builder, Vector3(0.32, 0.25, 0.62), Vector3(0.36, 0.08, 0.22), iron, 0.01)
		"ladle":
			_add_cyl(builder, Vector3(0.30, 0.95, 0.30), 0.035, 0.04, 0.55, wood, 6,
				Basis(Vector3.RIGHT, deg_to_rad(50.0)))
			_add_cyl(builder, Vector3(0.30, 0.78, 0.53), 0.10, 0.07, 0.12,
				Color(0.20, 0.20, 0.21), 8)
		"book":
			_add_box(builder, Vector3(0, 1.02 * f, 0.30), Vector3(0.34, 0.05, 0.44),
				Color(0.70, 0.64, 0.48), 0.01)
		"basket":
			_add_cyl(builder, Vector3(0.34, 0.75, 0.20), 0.20, 0.16, 0.28,
				Color(0.38, 0.26, 0.12), 8)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["person"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(0.55, 1.8 * f, 0.55), Vector3(0, 0.9 * f, 0))


func _hospice(parent: Node3D) -> void:
	var x0 := -11.0
	var x1 := -7.0
	var z0 := 42.0
	var z1 := 52.0
	var tint := Color(0.31, 0.29, 0.25)
	var group := _group(parent, "Hospice")
	_wall(group, "BackWall", Vector2(x0, z0), Vector2(x0, z1), 0.0, 4.0, 0.7, tint)
	_wall(group, "SideSouth", Vector2(x0, z0), Vector2(x1, z0), 0.0, 4.0, 0.7, tint)
	_wall(group, "SideNorth", Vector2(x0, z1), Vector2(x1, z1), 0.0, 4.0, 0.7, tint)
	_wall(group, "FrontWallA", Vector2(x1, z0), Vector2(x1, 45.0), 0.0, 4.0, 0.7, tint)
	_wall(group, "FrontWallB", Vector2(x1, 47.0), Vector2(x1, z1), 0.0, 4.0, 0.7, tint)
	var lintel := _static(group, "DoorLintel", Vector3(x1, 0, 46.0))
	var lb := LowPoly.begin()
	_add_box(lb, Vector3(0, 3.3, 0), Vector3(0.8, 1.4, 2.0), tint, 0.03)
	_add_box(lb, Vector3(-0.45, 2.18, 0), Vector3(0.18, 0.15, 2.25), tint.lightened(0.08), 0.02)
	_mesh_node(lintel, "Mesh", LowPoly.commit(lb), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(lintel, Vector3(0.8, 1.4, 2.0), Vector3(0, 3.3, 0))
	# 屋顶、烟囱、门廊、招牌十字
	var roof := _static(group, "HospiceRoof", Vector3.ZERO)
	var rb := LowPoly.begin()
	var a := Vector3(x0, 4.0, z0)
	var b := Vector3((x0 + x1) * 0.5, 5.25, z0)
	var c := Vector3((x0 + x1) * 0.5, 5.25, z1)
	var d := Vector3(x0, 4.0, z1)
	LowPoly.push_quad(rb, a, b, c, d, Color(0.17, 0.18, 0.19))
	LowPoly.push_quad(rb, Vector3((x0 + x1) * 0.5, 5.25, z0), Vector3(x1, 4.0, z0),
		Vector3(x1, 4.0, z1), Vector3((x0 + x1) * 0.5, 5.25, z1),
		Color(0.19, 0.20, 0.21))
	_mesh_node(roof, "Mesh", LowPoly.commit(rb), _mats["stone"], Vector3.ZERO, 0.0, true)
	var chimney := _static(group, "HospiceChimney", Vector3(-9.5, 0, 50.0))
	var cb := LowPoly.begin()
	_add_box(cb, Vector3(0, 3.8, 0), Vector3(0.85, 7.6, 0.85), tint.darkened(0.04), 0.03)
	_add_box(cb, Vector3(0, 7.55, 0), Vector3(1.15, 0.3, 1.15), tint.lightened(0.05), 0.02)
	_mesh_node(chimney, "Mesh", LowPoly.commit(cb), _mats["stone"], Vector3.ZERO, 0.0, true)
	var door := _static(group, "HospiceDoorFrame", Vector3(x1, 0, 46.0))
	var db := LowPoly.begin()
	for z in [-1.2, 1.2]:
		_add_box(db, Vector3(-0.4, 1.3, z), Vector3(0.2, 2.6, 0.25),
			Color(0.22, 0.15, 0.09), 0.02)
	_add_box(db, Vector3(-0.4, 2.68, 0), Vector3(0.22, 0.18, 2.65),
		Color(0.25, 0.17, 0.10), 0.02)
	_mesh_node(door, "Mesh", LowPoly.commit(db), _mats["props"], Vector3.ZERO, 0.0, true)
	_cross_finial(group, "HospiceCross", Vector3(x1 + 0.15, 4.55, 46.0), 0.8)
	# 木构立面、窗、门廊和灯，避免读成一座无窗石盒。
	var facade := _static(group, "HospiceFacade", Vector3.ZERO)
	var fb := LowPoly.begin()
	for wz in [43.2, 49.4]:
		_add_box(fb, Vector3(x1 + 0.02, 2.0, wz), Vector3(0.12, 0.85, 0.65),
			Color(0.08, 0.11, 0.14), 0.01)
		_add_box(fb, Vector3(x1 + 0.08, 2.52, wz), Vector3(0.18, 0.12, 0.9),
			Color(0.24, 0.16, 0.09), 0.01)
	for y in [3.35, 0.6]:
		_add_box(fb, Vector3(x1 + 0.06, y, 47.0), Vector3(0.18, 0.16, 10.0),
			Color(0.24, 0.16, 0.09), 0.01)
	for z in [42.4, 51.6]:
		_add_box(fb, Vector3(x1 + 0.06, 2.0, z), Vector3(0.18, 3.8, 0.16),
			Color(0.24, 0.16, 0.09), 0.01)
	# 门廊
	_add_box(fb, Vector3(x1 + 0.75, 3.15, 46.0), Vector3(1.6, 0.16, 2.9),
		Color(0.20, 0.14, 0.08), 0.02, Basis(Vector3.BACK, deg_to_rad(-7.0)))
	for z in [44.7, 47.3]:
		_add_box(fb, Vector3(x1 + 1.45, 1.55, z), Vector3(0.16, 3.0, 0.16),
			Color(0.24, 0.16, 0.09), 0.01)
	_add_box(fb, Vector3(x1 + 0.3, 2.65, 44.7), Vector3(0.22, 0.35, 0.22),
		Color(0.48, 0.34, 0.14), 0.01)
	_mesh_node(facade, "Mesh", LowPoly.commit(fb), _mats["props"], Vector3.ZERO, 0.0, true)
	# 室内：床、桌、壁炉、旅人、医院修士
	var interior := _static(group, "HospiceInterior", Vector3((x0 + x1) * 0.5, 0, 47.0))
	var ib := LowPoly.begin()
	for bz in [44.0, 49.5]:
		_add_box(ib, Vector3(-1.5, 0.42, bz - 47.0), Vector3(0.9, 0.2, 2.0),
			Color(0.35, 0.24, 0.14), 0.02)
		_add_box(ib, Vector3(-1.5, 0.62, bz - 47.0), Vector3(0.78, 0.16, 1.8),
			Color(0.52, 0.48, 0.38), 0.01)
		_add_box(ib, Vector3(-1.5, 0.78, bz - 47.55), Vector3(0.64, 0.14, 0.5),
			Color(0.42, 0.16, 0.10), 0.01)
	_add_box(ib, Vector3(0.2, 0.72, -1.0), Vector3(0.8, 0.1, 0.9),
		Color(0.32, 0.22, 0.12), 0.02)
	_add_box(ib, Vector3(1.4, 0.7, 1.8), Vector3(0.8, 1.4, 1.8),
		Color(0.27, 0.23, 0.19), 0.02)
	_add_cyl(ib, Vector3(1.1, 0.95, 1.8), 0.36, 0.26, 0.4,
		Color(0.10, 0.10, 0.10), 10)
	_mesh_node(interior, "Mesh", LowPoly.commit(ib), _mats["props"], Vector3.ZERO, 0.0, true)
	_room_light(group, "HospiceLight", Vector3(-9.0, 2.4, 47.0))
	_person(group, "PilgrimAtHospice", Vector3(-8.7, 0, 44.8), PI * 0.5,
		"sit", Color(0.30, 0.22, 0.16), Color(0.18, 0.15, 0.12), "staff")
	_person(group, "Hospitaler", Vector3(-8.4, 0, 49.0), -PI * 0.5,
		"stand", Color(0.22, 0.21, 0.18), Color(0.16, 0.15, 0.13), "basket")
	_banner(group, "HospiceBanner", Vector3(x1 + 0.1, 3.2, 44.0), PI * 0.5,
		Color(0.22, 0.05, 0.06))


func _stable(parent: Node3D) -> void:
	var x0 := 7.0
	var x1 := 11.0
	var z0 := 42.0
	var z1 := 52.0
	var tint := Color(0.28, 0.24, 0.19)
	var group := _group(parent, "Stable")
	_wall(group, "BackWall", Vector2(x1, z0), Vector2(x1, z1), 0.0, 3.8, 0.7, tint)
	_wall(group, "SideSouth", Vector2(x0, z0), Vector2(x1, z0), 0.0, 3.8, 0.7, tint)
	_wall(group, "SideNorth", Vector2(x0, z1), Vector2(x1, z1), 0.0, 3.8, 0.7, tint)
	_wall(group, "FrontWallA", Vector2(x0, z0), Vector2(x0, 44.5), 0.0, 3.8, 0.7, tint)
	_wall(group, "FrontWallB", Vector2(x0, 49.5), Vector2(x0, z1), 0.0, 3.8, 0.7, tint)
	var lintel := _static(group, "StableDoorLintel", Vector3(x0, 0, 47.0))
	var lb := LowPoly.begin()
	_add_box(lb, Vector3(0, 3.1, 0), Vector3(0.8, 1.4, 5.0), tint, 0.03)
	_add_box(lb, Vector3(0.45, 1.85, 0), Vector3(0.18, 0.18, 5.2), tint.lightened(0.06), 0.02)
	_mesh_node(lintel, "Mesh", LowPoly.commit(lb), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(lintel, Vector3(0.8, 1.4, 5.0), Vector3(0, 3.1, 0))
	var roof := _static(group, "StableRoof", Vector3.ZERO)
	var rb := LowPoly.begin()
	LowPoly.push_quad(rb, Vector3(x0, 3.8, z0), Vector3((x0 + x1) * 0.5, 5.2, z0),
		Vector3((x0 + x1) * 0.5, 5.2, z1), Vector3(x0, 3.8, z1),
		Color(0.20, 0.16, 0.11))
	LowPoly.push_quad(rb, Vector3((x0 + x1) * 0.5, 5.2, z0), Vector3(x1, 3.8, z0),
		Vector3(x1, 3.8, z1), Vector3((x0 + x1) * 0.5, 5.2, z1),
		Color(0.18, 0.14, 0.10))
	_mesh_node(roof, "Mesh", LowPoly.commit(rb), _mats["stone"], Vector3.ZERO, 0.0, true)
	# 干草、槽、车、骡子、马夫
	var interior := _static(group, "StableInterior", Vector3(9.0, 0, 47.0))
	var ib := LowPoly.begin()
	for hz in [43.0, 50.5]:
		_add_box(ib, Vector3(0.8, 0.45, hz - 47.0), Vector3(1.4, 0.9, 1.3),
			Color(0.55, 0.45, 0.22), 0.04)
	for sx in [1.3]:
		_add_box(ib, Vector3(sx, 0.55, -1.8), Vector3(0.8, 1.1, 1.8),
			Color(0.22, 0.16, 0.10), 0.02)
	_add_box(ib, Vector3(-0.1, 0.75, -2.0), Vector3(0.9, 0.2, 1.3),
		Color(0.34, 0.23, 0.13), 0.02)
	for wheel in [-0.5, 0.5]:
		_add_cyl(ib, Vector3(0.2, 0.35, -2.0 + wheel), 0.34, 0.34, 0.12,
			Color(0.16, 0.13, 0.10), 10, Basis(Vector3.BACK, PI * 0.5))
	_add_box(ib, Vector3(1.2, 0.5, -2.0), Vector3(0.7, 0.7, 1.2),
		Color(0.32, 0.25, 0.18), 0.02)
	_add_box(ib, Vector3(1.6, 0.45, -2.0), Vector3(0.4, 0.3, 0.8),
		Color(0.20, 0.19, 0.17), 0.02)
	_mesh_node(interior, "Mesh", LowPoly.commit(ib), _mats["props"], Vector3.ZERO, 0.0, true)
	_room_light(group, "StableLight", Vector3(9.0, 2.0, 47.0))
	# 骡子：只做低多边形体块，不追求解剖细节
	var mule := _static(group, "Mule", Vector3(9.0, 0, 49.3))
	var mb := LowPoly.begin()
	_add_box(mb, Vector3(0, 0.95, 0), Vector3(0.62, 0.7, 1.25), Color(0.29, 0.25, 0.20), 0.03)
	_add_box(mb, Vector3(0, 1.35, -0.65), Vector3(0.3, 0.55, 0.35), Color(0.27, 0.23, 0.19), 0.02)
	_add_box(mb, Vector3(0, 1.65, -0.82), Vector3(0.34, 0.42, 0.62), Color(0.30, 0.26, 0.21), 0.02)
	for leg in [-0.35, 0.35]:
		for z in [-0.4, 0.4]:
			_add_box(mb, Vector3(leg, 0.3, z), Vector3(0.12, 0.6, 0.12),
				Color(0.24, 0.20, 0.16), 0.01)
	_add_cyl(mb, Vector3(0, 1.35, 0.62), 0.05, 0.07, 0.5,
		Color(0.20, 0.17, 0.13), 6)
	_mesh_node(mule, "Mesh", LowPoly.commit(mb), _mats["props"], Vector3.ZERO, 0.0, true)
	_box_collision(mule, Vector3(0.9, 1.8, 1.6), Vector3(0, 0.9, 0))
	_person(group, "Stablehand", Vector3(9.0, 0, 44.6), PI * 0.5,
		"work", Color(0.28, 0.23, 0.16), Color(0.18, 0.15, 0.11), "hammer")
	# 马厩立面：干草门、窗、拴马桩、水槽。
	var facade := _static(group, "StableFacade", Vector3.ZERO)
	var fb := LowPoly.begin()
	_add_box(fb, Vector3(x0 - 0.04, 2.85, 47.0), Vector3(0.12, 0.95, 1.4),
		Color(0.07, 0.08, 0.07), 0.01)
	for wz in [43.0, 50.6]:
		_add_box(fb, Vector3(x0 - 0.04, 1.9, wz), Vector3(0.12, 0.7, 0.6),
			Color(0.08, 0.10, 0.11), 0.01)
		_add_box(fb, Vector3(x0 - 0.10, 2.3, wz), Vector3(0.16, 0.12, 0.82),
			Color(0.26, 0.18, 0.10), 0.01)
	for y in [2.45, 0.55]:
		_add_box(fb, Vector3(x0 - 0.08, y, 47.0), Vector3(0.16, 0.16, 9.0),
			Color(0.26, 0.18, 0.10), 0.01)
	# 门外拴马桩与水槽
	for z in [43.8, 48.6]:
		_add_cyl(fb, Vector3(x0 - 1.0, 0.7, z), 0.06, 0.08, 1.4,
			Color(0.24, 0.16, 0.09), 6)
	_add_box(fb, Vector3(x0 - 1.0, 1.3, 50.2), Vector3(0.08, 0.08, 2.1),
		Color(0.32, 0.23, 0.13), 0.01)
	_add_box(fb, Vector3(x0 - 1.25, 0.32, 45.0), Vector3(0.7, 0.5, 1.5),
		Color(0.30, 0.29, 0.26), 0.02)
	_add_box(fb, Vector3(x0 - 1.25, 0.5, 45.0), Vector3(0.55, 0.06, 1.3),
		Color(0.08, 0.14, 0.16), 0.01)
	_mesh_node(facade, "Mesh", LowPoly.commit(fb), _mats["props"], Vector3.ZERO, 0.0, true)

func _build_chapels() -> void:
	_build_chapel("WestChapel", -30.0, -26.0, 8.0, 16.0, -28.0, 12.0, _mats["flame_red"])
	_build_chapel("EastChapel", 30.0, 26.0, 2.0, 10.0, 28.0, 6.0, _mats["flame_yellow"])


func _build_chapel(name: String, outer_x: float, inner_x: float, z0: float, z1: float,
		altar_x: float, altar_z: float, flame_material: Material) -> void:
	var chapel := _group(scene_root, name)
	var tint := Color(0.27, 0.28, 0.27)
	_wall(chapel, "NorthWall", Vector2(outer_x, z0), Vector2(inner_x, z0), 0.0, 4.2, 0.7, tint)
	_wall(chapel, "SouthWall", Vector2(outer_x, z1), Vector2(inner_x, z1), 0.0, 4.2, 0.7, tint)
	# 朝向回廊的内墙留一个门洞。
	_wall(chapel, "FrontWallA", Vector2(inner_x, z0), Vector2(inner_x, altar_z - 1.7),
		0.0, 4.2, 0.8, tint)
	_wall(chapel, "FrontWallB", Vector2(inner_x, altar_z + 1.7), Vector2(inner_x, z1),
		0.0, 4.2, 0.8, tint)
	var roof := LowPoly.begin()
	_add_box(roof, Vector3((outer_x + inner_x) * 0.5, 4.35, (z0 + z1) * 0.5),
		Vector3(absf(inner_x - outer_x) + 0.6, 0.25, absf(z1 - z0) + 0.6),
		Color(0.24, 0.25, 0.24), 0.04)
	_mesh_node(chapel, "Roof", LowPoly.commit(roof), _mats["stone"], Vector3.ZERO, 0.0, true)
	_altar_table(chapel, "Altar", Vector3(altar_x, 0, altar_z), 0.85, flame_material)
	var toward_inner := signf(inner_x - outer_x)
	_bench(chapel, "Bench", Vector3(inner_x - toward_inner * 1.1, 0, altar_z), 0.0)
	_banner(chapel, "Banner", Vector3(inner_x - toward_inner * 0.4, 2.3, altar_z - 2.9),
		0.0, Color(0.18, 0.04, 0.05))
	_add_small_brazier(chapel, "ChapelFire", Vector3(inner_x - toward_inner * 0.9, 0,
		altar_z - 2.0), false)


# ---------------------------------------------------------------- 大厅

func _build_hall() -> void:
	var hall := _group(scene_root, "Hall")
	var tint := Color(0.25, 0.26, 0.25)
	_wall(hall, "RearWall", Vector2(-HALL_X, HALL_Z_MIN), Vector2(HALL_X, HALL_Z_MIN),
		0.0, 7.0, 1.2, tint)
	# 侧墙各开两道门，接进两侧庭院；门高 4.2 m，墙上方保留过梁。
	for side in [-1.0, 1.0]:
		var wall_x: float = HALL_X * side
		_wall(hall, "SideWall_%s_A" % ("W" if side < 0 else "E"),
			Vector2(wall_x, HALL_Z_MAX), Vector2(wall_x, -8.0), 0.0, 7.0, 1.2, tint)
		_wall(hall, "SideWall_%s_B" % ("W" if side < 0 else "E"),
			Vector2(wall_x, -12.0), Vector2(wall_x, -24.0), 0.0, 7.0, 1.2, tint)
		_wall(hall, "SideWall_%s_C" % ("W" if side < 0 else "E"),
			Vector2(wall_x, -28.0), Vector2(wall_x, HALL_Z_MIN), 0.0, 7.0, 1.2, tint)
		for door_z in [-10.0, -26.0]:
			var lintel_body := _static(hall,
				"SideDoorLintel_%s_%d" % ["W" if side < 0 else "E", roundi(door_z)],
				Vector3(wall_x, 0, door_z))
			var lintel_builder := LowPoly.begin()
			_add_box(lintel_builder, Vector3(0, 5.6, 0), Vector3(1.5, 2.8, 4.0), tint, 0.03)
			_add_box(lintel_builder, Vector3(float(-side) * 0.8, 4.05, 0),
				Vector3(0.3, 0.28, 4.4), tint.lightened(0.08), 0.02)
			_mesh_node(lintel_body, "Mesh", LowPoly.commit(lintel_builder), _mats["stone"],
				Vector3.ZERO, 0.0, true)
			_box_collision(lintel_body, Vector3(1.5, 2.8, 4.0), Vector3(0, 5.6, 0))

	for z in [-10.0, -16.0, -22.0, -28.0]:
		for side in [-1.0, 1.0]:
			_pillar(hall, "NaveColumn_%s_%d" % [("W" if side < 0 else "E"), int(absf(z))],
				Vector3(7.0 * side, 0, z), 6.8, Color(0.32, 0.33, 0.31), 0.48, true)
	# 侧墙高窗：给黑暗的中殿补垂直节奏与冷光，而不是把屋顶掀开。
	for side in [-1.0, 1.0]:
		for z in [-16.0, -21.0, -32.0]:
			_hall_window(hall, "SideWindow_%s_%d" % [("W" if side < 0 else "E"), int(absf(z))],
				side, z, 1.75, 3.1)
	# 纵向主梁与横梁
	var structure := LowPoly.begin()
	for side in [-1.0, 1.0]:
		_add_box(structure, Vector3(7.0 * side, 6.82, -20.0), Vector3(0.55, 0.35, 32.0),
			Color(0.21, 0.20, 0.17), 0.03)
	for index in 6:
		var z := -7.0 - index * 5.0
		_add_box(structure, Vector3(0, 6.82, z), Vector3(28.0, 0.32, 0.45),
			Color(0.19, 0.18, 0.15), 0.03)
	_mesh_node(hall, "Beams", LowPoly.commit(structure), _mats["wood"], Vector3.ZERO, 0.0, true)

	# 屋顶：完整覆盖大厅，祭坛上方留方洞给天光；东侧一段故意塌落。
	var roof := _group(hall, "Roof")
	var x_segments := [[-14.0, -7.0], [-7.0, 0.0], [0.0, 7.0], [7.0, 14.0]]
	for iz in 8:
		var z0 := HALL_Z_MAX - float(iz) * 4.0
		var z1 := z0 - 3.8
		for side in 4:
			var x0: float = x_segments[side][0]
			var x1: float = x_segments[side][1]
			if iz >= 6 and side >= 1 and side <= 2:
				continue
			if iz == 3 and side == 3:
				continue
			var builder := LowPoly.begin()
			_add_box(builder, Vector3((x0 + x1) * 0.5, 7.12, (z0 + z1) * 0.5),
				Vector3(x1 - x0 - 0.12, 0.24, z0 - z1 - 0.12),
				Color(0.18, 0.19, 0.19), 0.03)
			_mesh_node(roof, "Roof_%02d_%d" % [iz, side], LowPoly.commit(builder),
				_mats["stone"], Vector3.ZERO, 0.0, true)
	# 屋脊压条：盖住两侧屋顶板之间的细缝，避免天光在殿内形成一条激光线。
	var ridge := LowPoly.begin()
	_add_box(ridge, Vector3(0, 7.3, -20.0), Vector3(0.55, 0.3, 32.0),
		Color(0.16, 0.17, 0.17), 0.02)
	_mesh_node(roof, "Ridge", LowPoly.commit(ridge), _mats["stone"], Vector3.ZERO, 0.0, true)
	# 塌落处的断裂木梁
	var broken := LowPoly.begin()
	_add_box(broken, Vector3(10.8, 6.9, -20.0), Vector3(6.2, 0.22, 0.32),
		Color(0.18, 0.15, 0.12), 0.02, Basis(Vector3.BACK, deg_to_rad(-7.0)))
	_mesh_node(roof, "BrokenBeam", LowPoly.commit(broken), _mats["wood"],
		Vector3.ZERO, 0.0, true)
	# 外观上的双坡屋顶：内部仍保留平顶/天光洞，外部读作教堂中殿。
	var pitch_angle := atan(2.6 / 14.0)
	var slope_length := sqrt(14.0 * 14.0 + 2.6 * 2.6)
	for section in [[HALL_Z_MAX, -27.0], [-35.0, HALL_Z_MIN]]:
		var z0: float = section[0]
		var z1: float = section[1]
		for side in [-1.0, 1.0]:
			var slope := LowPoly.begin()
			_add_box(slope, Vector3(7.0 * side, 8.5, (z0 + z1) * 0.5),
				Vector3(slope_length, 0.24, absf(z0 - z1) - 0.1),
				Color(0.17, 0.18, 0.20), 0.03,
				Basis(Vector3.BACK, -float(side) * pitch_angle))
			_mesh_node(roof, "Pitched_%s_%d" % ["W" if side < 0 else "E", roundi(z0)],
				LowPoly.commit(slope), _mats["stone"], Vector3.ZERO, 0.0, true)
	# 屋脊与两端十字
	var ridge_builder := LowPoly.begin()
	_add_box(ridge_builder, Vector3(0, 9.82, -20.0), Vector3(0.36, 0.3, 32.0),
		Color(0.14, 0.15, 0.17), 0.03)
	_mesh_node(roof, "RidgePitch", LowPoly.commit(ridge_builder), _mats["stone"],
		Vector3.ZERO, 0.0, true)
	_cross_finial(hall, "FrontCross", Vector3(0, 9.95, -4.5), 1.2)
	_cross_finial(hall, "RearCross", Vector3(0, 9.95, -35.5), 1.2)

	# 后墙圣徽与祭坛：高坛背后不再是十字/玫瑰窗，而是本圣所的鲸形圣徽。
	_whale_sigil(hall, Vector3(0, 4.9, -35.30))
	_altar_table(hall, "HighAltar", Vector3(0, 0, -31.0), 1.6, _mats["flame_blue"], false)
	_high_altar_dressing(hall)
	# 祭坛台阶
	for index in 3:
		var step := _static(hall, "AltarStep_%d" % index,
			Vector3(0, 0.0, -27.4 - index * 0.7))
		var b := LowPoly.begin()
		_add_box(b, Vector3(0, 0.16 + index * 0.06, 0),
			Vector3(7.0 - index * 0.8, 0.32 + index * 0.12, 1.0), Color(0.33, 0.34, 0.32), 0.03)
		# 踏步前缘的压边贴在立面上、顶面与踏面齐平，向前挑出 3.5 cm；不是凸起的绊脚条。
		_add_box(b, Vector3(0, 0.32 + float(index) * 0.12 - 0.02, 0.5175),
			Vector3(7.0 - index * 0.8 + 0.08, 0.04, 0.035), Color(0.41, 0.42, 0.39), 0.0)
		_mesh_node(step, "Mesh", LowPoly.commit(b), _mats["stone"], Vector3.ZERO, 0.0, true)
		_box_collision(step, Vector3(7.0 - index * 0.8, 0.32 + index * 0.12, 1.0),
			Vector3(0, 0.16 + index * 0.06, 0))
	_sacred_crystal(hall, "HighAltarCrystal", Vector3(0, 1.48, -31.0), 0.62,
		_mats["crystal_holy"])
	_altar_candles(hall, "AltarCandles", Vector3(0, 1.478, -30.28))
	_candles(hall, "DaisCandlesW", Vector3(-3.2, 0.44, -27.6), 3, 0.35)
	_candles(hall, "DaisCandlesE", Vector3(3.2, 0.44, -27.6), 3, 0.35)
	_chandelier(hall, Vector3(0, 5.2, -18.0), 1.7)
	# 侧廊长凳、倒塌柱与碎石
	for side in [-1.0, 1.0]:
		_bench(hall, "Pew_%s" % ("W" if side < 0 else "E"),
			Vector3(10.8 * side, 0, -14.0), 0.0)
		_bench(hall, "Pew2_%s" % ("W" if side < 0 else "E"),
			Vector3(10.8 * side, 0, -21.0), 0.0)
	_fallen_column(hall, "FallenNaveColumn", Vector3(-9.0, 0, -18.0), deg_to_rad(66.0))
	_rubble(hall, "NaveRubbleA", Vector3(10.5, 0, -27.0), 1.5)
	_rubble(hall, "NaveRubbleB", Vector3(-11.0, 0, -6.5), 1.3)
	# 顶部天光：洞、光柱与聚光
	_light_shaft(hall, Vector3(0, 7.0, -31.0), 7.0)


# ---------------------------------------------------------------- 细节构件

func _hall_window(parent: Node3D, name: String, side: float, z: float, width: float,
		height: float) -> void:
	var body := _static(parent, name, Vector3(13.28 * side, 0, z))
	var builder := LowPoly.begin()
	var x_inner: float = -0.12 * side
	_add_box(builder, Vector3(x_inner, 4.0, 0), Vector3(0.18, height + 0.5, width + 0.5),
		Color(0.16, 0.17, 0.17), 0.02)
	_add_box(builder, Vector3(x_inner - 0.08 * side, 0.9, 0), Vector3(0.45, 0.28, width + 0.8),
		Color(0.26, 0.27, 0.26), 0.02)
	_add_box(builder, Vector3(x_inner - 0.08 * side, 4.0 + height * 0.5 + 0.14, 0),
		Vector3(0.45, 0.28, width + 0.8), Color(0.26, 0.27, 0.26), 0.02)
	for index in 2:
		_add_box(builder, Vector3(x_inner - 0.09 * side, 4.0, -width * 0.5 + index * width),
			Vector3(0.35, height + 0.3, 0.18), Color(0.24, 0.25, 0.24), 0.01)
	_mesh_node(body, "Frame", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	var glass := _static(parent, name + "_Glass", Vector3(13.22 * side, 0, z))
	var pane := LowPoly.begin()
	_add_box(pane, Vector3(0, 4.0, 0), Vector3(0.06, height, width),
		Color(0.55, 0.68, 0.82), 0.0)
	var pane_instance := _mesh_node(glass, "Pane", LowPoly.commit(pane), _mats["window"],
		Vector3.ZERO, 0.0, false)
	pane_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var light := OmniLight3D.new()
	light.name = "WindowGlow"
	light.position = Vector3(10.5 * side, 4.0, z)
	light.light_color = Color(0.52, 0.68, 0.92)
	light.light_energy = 0.65
	light.omni_range = 7.0
	light.omni_attenuation = 1.6
	light.shadow_enabled = false
	parent.add_child(light)
	light.owner = scene_root


func _pillar(parent: Node3D, name: String, position: Vector3, height: float, tint: Color,
		radius := 0.46, round_column := false) -> StaticBody3D:
	var body := _static(parent, name, position)
	var builder := LowPoly.begin()
	_add_box(builder, Vector3(0, 0.25, 0), Vector3(radius * 2.3, 0.5, radius * 2.3),
		tint.darkened(0.12), 0.03)
	_add_box(builder, Vector3(0, 0.6, 0), Vector3(radius * 1.9, 0.2, radius * 1.9),
		tint.lightened(0.05), 0.02)
	if round_column:
		_add_cyl(builder, Vector3(0, height * 0.5 + 0.35, 0), radius * 0.82,
			radius * 0.95, height - 0.9, tint, 10)
		_add_box(builder, Vector3(0, height - 0.2, 0), Vector3(radius * 2.2, 0.4, radius * 2.2),
			tint.lightened(0.07), 0.03)
	else:
		_add_box(builder, Vector3(0, height * 0.5 + 0.35, 0), Vector3(radius * 1.6,
			height - 0.9, radius * 1.6), tint, 0.04)
		_add_box(builder, Vector3(0, height - 0.2, 0), Vector3(radius * 2.0, 0.35, radius * 2.0),
			tint.lightened(0.07), 0.03)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(radius * 2.1, height, radius * 2.1), Vector3(0, height * 0.5, 0))
	return body


func _statue(parent: Node3D, name: String, base: Vector3, yaw: float, scale_value: float,
		tint: Color, wings := false, halo := false) -> void:
	var body := _static(parent, name, base, yaw)
	body.scale = Vector3.ONE * scale_value
	tint = tint.darkened(0.1)
	var builder := LowPoly.begin()
	# 基座
	_add_box(builder, Vector3(0, 0.24, 0), Vector3(1.45, 0.48, 1.45),
		Color(0.28, 0.26, 0.22), 0.04)
	_add_box(builder, Vector3(0, 0.58, 0), Vector3(1.08, 0.22, 1.08),
		Color(0.33, 0.31, 0.27), 0.025)
	# 窄身长袍：下宽上窄，避免“茶壶”轮廓。
	_add_cyl(builder, Vector3(0, 1.58, 0), 0.30, 0.62, 1.8,
		Color(0.35, 0.33, 0.29), 12)
	# 垂褶：正面五道浅折，近看才有的层次。
	for index in 5:
		var x := -0.34 + float(index) * 0.17
		_add_box(builder, Vector3(x, 1.55, 0.42), Vector3(0.06, 1.55, 0.07),
			Color(0.39, 0.36, 0.32), 0.01)
	# 肩与合手
	_add_box(builder, Vector3(0, 2.5, 0), Vector3(0.78, 0.24, 0.46),
		Color(0.34, 0.32, 0.28), 0.03)
	_add_box(builder, Vector3(0, 2.02, 0.30), Vector3(0.30, 0.16, 0.22),
		Color(0.40, 0.37, 0.32), 0.02)
	_add_box(builder, Vector3(0, 1.92, 0.34), Vector3(0.34, 0.10, 0.26),
		Color(0.30, 0.27, 0.23), 0.02)
	# 头与面纱：不覆盖成“壶盖”的尖锥。
	_add_rock(builder, Vector3(0, 2.82, 0.02), 0.19, 0.42,
		Color(0.46, 0.43, 0.37))
	_add_box(builder, Vector3(0, 2.86, -0.15), Vector3(0.38, 0.62, 0.12),
		Color(0.31, 0.29, 0.25), 0.02)
	# 天使翼（仅门口/内门用），两块后掠薄板。
	if wings:
		for side in [-1.0, 1.0]:
			var wing_basis := Basis(Vector3.UP, float(side) * deg_to_rad(24.0)) \
				* Basis(Vector3.BACK, deg_to_rad(-14.0))
			_add_box(builder, Vector3(float(side) * 0.46, 2.55, -0.25),
				Vector3(0.16, 1.15, 0.62), Color(0.38, 0.35, 0.30), 0.02, wing_basis)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["statue"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(1.0, 3.2, 0.85), Vector3(0, 1.6, 0))
	if halo:
		var ring := TorusMesh.new()
		ring.inner_radius = 0.32
		ring.outer_radius = 0.42
		ring.rings = 24
		ring.ring_segments = 6
		var halo_node := _mesh_node(body, "Halo", ring, _mats["gold_plain"],
			Vector3(0, 2.85, -0.26), 0.0, false)
		halo_node.rotation_degrees.x = 90.0


func _altar_table(parent: Node3D, name: String, base: Vector3, scale_value: float,
		flame_material: Material, with_flame := true) -> void:
	var body := _static(parent, name, base)
	var builder := LowPoly.begin()
	_add_box(builder, Vector3(0, 0.22, 0), Vector3(2.9, 0.44, 2.1), Color(0.31, 0.31, 0.29), 0.04)
	# 基座顶沿加一道出挑的压边；石材台座因此有收分，不像一个整块盒子。
	_add_box(builder, Vector3(0, 0.41, 0), Vector3(2.96, 0.06, 2.16), Color(0.36, 0.35, 0.32), 0.0)
	_add_box(builder, Vector3(0, 0.78, 0), Vector3(2.2, 1.1, 1.5), Color(0.35, 0.35, 0.33), 0.04)
	_add_box(builder, Vector3(0, 1.38, 0), Vector3(2.6, 0.16, 1.85), Color(0.46, 0.43, 0.36), 0.025)
	_add_box(builder, Vector3(0, 0.15, 0.95), Vector3(2.0, 0.3, 0.35), Color(0.28, 0.29, 0.28), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(2.7, 1.5, 2.0), Vector3(0, 0.75, 0))
	if not with_flame:
		return
	# 青铜祭坛盆与火焰
	var bowl := _static(parent, name + "_Bowl", base + Vector3(0, 1.48, 0))
	bowl.scale = Vector3.ONE * scale_value
	var bowl_builder := LowPoly.begin()
	_add_cyl(bowl_builder, Vector3(0, 0.18, 0), 0.55, 0.34, 0.3,
		Color(0.26, 0.20, 0.10), 12)
	_mesh_node(bowl, "Bowl", LowPoly.commit(bowl_builder), _mats["gold"], Vector3.ZERO, 0.0, true)
	var flame := _static(parent, name + "_Flame", base + Vector3(0, 1.95, 0))
	flame.scale = Vector3.ONE * scale_value
	var flame_builder := LowPoly.begin()
	_add_cone(flame_builder, Vector3(0, 0.55, 0), 0.32, 1.2, Color(1, 1, 1))
	_add_rock(flame_builder, Vector3(0, 0.32, 0), 0.22, 0.4, Color(1, 1, 1))
	_mesh_node(flame, "Flame", LowPoly.commit(flame_builder), flame_material, Vector3.ZERO, 0.0, false)
	var light := OmniLight3D.new()
	light.name = "FlameLight"
	light.position = base + Vector3(0, 2.6, 0)
	light.light_color = Color(0.55, 0.78, 1.0) if flame_material == _mats["flame_blue"] \
		else Color(1.0, 0.45, 0.12)
	light.light_energy = 2.1
	light.omni_range = 7.0
	light.omni_attenuation = 1.3
	light.shadow_enabled = false
	parent.add_child(light)
	light.owner = scene_root


func _high_altar_dressing(parent: Node3D) -> void:
	# 亚麻台布只覆盖桌面并前垂 10 cm；祭坛主体正面另有深红前帷，不把整张桌子包成布箱。
	var linen := LowPoly.begin()
	var cream := Color(0.88, 0.86, 0.79)
	_add_box(linen, Vector3(0, 1.468, -31.0), Vector3(2.70, 0.018, 1.95), cream, 0.0)
	_add_box(linen, Vector3(0, 1.412, -30.018), Vector3(2.70, 0.102, 0.016),
		cream.darkened(0.03), 0.0)
	# 前垂布下缘折一道窄边，避免布像一块切齐的白板。
	_add_box(linen, Vector3(0, 1.365, -30.006), Vector3(2.70, 0.022, 0.020),
		cream.lightened(0.02), 0.0)
	for side in [-1.0, 1.0]:
		_add_box(linen, Vector3(1.343 * side, 1.424, -31.0),
			Vector3(0.016, 0.07, 1.95), cream.darkened(0.045), 0.0)
	for index in 3:
		var fold_x := -0.9 + float(index) * 0.9
		_add_box(linen, Vector3(fold_x, 1.412, -30.004), Vector3(0.014, 0.09, 0.008),
			cream.darkened(0.09), 0.0)
	_mesh_node(parent, "AltarLinen", LowPoly.commit(linen), _mats["linen"], Vector3.ZERO, 0.0, false)

	# 前帷挂在祭坛主体正面，金线滚边；颜色与南门、中殿的深红幡一致。
	var frontal := LowPoly.begin()
	var madder := Color(0.32, 0.06, 0.065)
	var gold_thread := Color(0.78, 0.63, 0.30)
	_add_box(frontal, Vector3(0, 0.94, -30.238), Vector3(2.04, 0.72, 0.018), madder, 0.0)
	_add_box(frontal, Vector3(0, 1.30, -30.224), Vector3(2.10, 0.032, 0.022), gold_thread, 0.0)
	_add_box(frontal, Vector3(0, 0.58, -30.224), Vector3(2.10, 0.032, 0.022), gold_thread, 0.0)
	for side in [-1.0, 1.0]:
		_add_box(frontal, Vector3(1.034 * side, 0.94, -30.224), Vector3(0.032, 0.752, 0.022),
			gold_thread, 0.0)
	_mesh_node(parent, "AltarFrontal", LowPoly.commit(frontal), _mats["frontal"],
		Vector3.ZERO, 0.0, false)


func _altar_candles(parent: Node3D, name: String, base: Vector3) -> void:
	# 六支高低对称的祭坛蜡烛：三支一组分列圣晶两侧；黄铜接蜡盘接滴蜡。
	var body := _static(parent, name, base)
	var trays := LowPoly.begin()
	var wax := LowPoly.begin()
	var flames := LowPoly.begin()
	var xs := [-1.02, -0.66, -0.30, 0.30, 0.66, 1.02]
	var heights := [0.44, 0.52, 0.60, 0.60, 0.52, 0.44]
	for index in xs.size():
		var x: float = xs[index]
		var height: float = heights[index]
		_add_cyl(trays, Vector3(x, 0.013, 0), 0.12, 0.135, 0.026,
			Color(0.22, 0.18, 0.11), 10)
		_add_cyl(wax, Vector3(x, 0.026 + height * 0.5, 0), 0.045, 0.055, height,
			Color(0.84, 0.80, 0.68), 7)
		_add_cone(flames, Vector3(x, 0.026 + height + 0.08, 0), 0.04, 0.14,
			Color(1.0, 0.62, 0.22))
	_mesh_node(body, "Trays", LowPoly.commit(trays), _mats["gold"], Vector3.ZERO, 0.0, true)
	_mesh_node(body, "Wax", LowPoly.commit(wax), _mats["candle"], Vector3.ZERO, 0.0, true)
	_mesh_node(body, "Flames", LowPoly.commit(flames), _mats["ember"], Vector3.ZERO, 0.0, false)


func _candles(parent: Node3D, name: String, base: Vector3, count: int, spread: float) -> void:
	var body := _static(parent, name, base)
	var wax := LowPoly.begin()
	var flames := LowPoly.begin()
	for index in count:
		var offset := Vector3(_rng.randf_range(-spread, spread), 0.0,
			_rng.randf_range(-spread * 0.55, spread * 0.55))
		var height := _rng.randf_range(0.22, 0.62)
		_add_cyl(wax, offset + Vector3(0, height * 0.5, 0), 0.045, 0.055, height,
			Color(0.82, 0.78, 0.66), 6)
		_add_cone(flames, offset + Vector3(0, height + 0.09, 0), 0.045, 0.16,
			Color(1.0, 0.62, 0.22), Basis.IDENTITY)
	_mesh_node(body, "Wax", LowPoly.commit(wax), _mats["candle"], Vector3.ZERO, 0.0, true)
	_mesh_node(body, "Flames", LowPoly.commit(flames), _mats["ember"], Vector3.ZERO, 0.0, false)


func _chandelier(parent: Node3D, center: Vector3, radius: float) -> void:
	var body := _static(parent, "Chandelier", center)
	var metal := LowPoly.begin()
	for chain in 3:
		var angle := TAU * float(chain) / 3.0
		var top := center + Vector3(cos(angle) * radius * 0.45, 1.8, sin(angle) * radius * 0.45)
		var midpoint := (center + top) * 0.5
		_add_cyl(metal, midpoint - center, 0.025, 0.025, 1.9, Color(0.12, 0.13, 0.13), 5,
			Basis(Vector3.BACK, 0.0))
	var ring := TorusMesh.new()
	ring.inner_radius = radius * 0.85
	ring.outer_radius = radius
	ring.rings = 24
	ring.ring_segments = 6
	_mesh_node(body, "Ring", ring, _mats["iron_plain"], Vector3.ZERO, 0.0, true)
	var wax := LowPoly.begin()
	var flames := LowPoly.begin()
	for index in 8:
		var angle := TAU * float(index) / 8.0
		var at := Vector3(cos(angle) * radius * 0.92, 0.16, sin(angle) * radius * 0.92)
		_add_cyl(wax, at + Vector3(0, 0.14, 0), 0.04, 0.05, 0.28, Color(0.82, 0.78, 0.66), 5)
		_add_cone(flames, at + Vector3(0, 0.36, 0), 0.04, 0.14, Color(1.0, 0.62, 0.22))
	_mesh_node(body, "Candles", LowPoly.commit(wax), _mats["candle"], Vector3.ZERO, 0.0, false)
	_mesh_node(body, "Flames", LowPoly.commit(flames), _mats["ember"], Vector3.ZERO, 0.0, false)
	_mesh_node(body, "Chains", LowPoly.commit(metal), _mats["iron"], Vector3.ZERO, 0.0, false)
	var light := OmniLight3D.new()
	light.name = "ChandelierLight"
	light.position = center + Vector3(0, 0.4, 0)
	light.light_color = Color(1.0, 0.58, 0.28)
	light.light_energy = 1.1
	light.omni_range = 9.0
	light.omni_attenuation = 1.4
	light.shadow_enabled = false
	parent.add_child(light)
	light.owner = scene_root


func _add_small_brazier(parent: Node3D, name: String, position: Vector3, with_light: bool) -> void:
	var body := _static(parent, name, position)
	var builder := LowPoly.begin()
	_add_cyl(builder, Vector3(0, 0.15, 0), 0.28, 0.22, 0.3, Color(0.15, 0.16, 0.16), 8)
	_add_cyl(builder, Vector3(0, 0.55, 0), 0.42, 0.32, 0.22, Color(0.22, 0.18, 0.10), 10)
	_mesh_node(body, "Metal", LowPoly.commit(builder), _mats["iron"], Vector3.ZERO, 0.0, true)
	var flame := _static(parent, name + "_Flame", position + Vector3(0, 0.72, 0))
	var flame_builder := LowPoly.begin()
	_add_cone(flame_builder, Vector3(0, 0.34, 0), 0.18, 0.7, Color(1, 1, 1))
	_add_rock(flame_builder, Vector3(0, 0.12, 0), 0.17, 0.3, Color(1, 1, 1))
	_mesh_node(flame, "Flame", LowPoly.commit(flame_builder), _mats["ember"], Vector3.ZERO, 0.0, false)
	if with_light:
		var light := OmniLight3D.new()
		light.name = "FireLight"
		light.position = position + Vector3(0, 1.4, 0)
		light.light_color = Color(1.0, 0.42, 0.12)
		light.light_energy = 1.5
		light.omni_range = 5.5
		light.omni_attenuation = 1.2
		light.shadow_enabled = false
		parent.add_child(light)
		light.owner = scene_root


func _banner(parent: Node3D, name: String, top: Vector3, yaw: float, color: Color) -> void:
	var body := Node3D.new()
	body.name = name
	body.position = top
	body.rotation.y = yaw
	parent.add_child(body)
	body.owner = scene_root
	var pole := LowPoly.begin()
	_add_cyl(pole, Vector3(0, 0.9, 0), 0.045, 0.045, 1.8, Color(0.16, 0.14, 0.11), 5)
	_add_box(pole, Vector3(0.65, 1.65, 0), Vector3(1.4, 0.1, 0.1), Color(0.16, 0.14, 0.11), 0.01)
	_mesh_node(body, "Pole", LowPoly.commit(pole), _mats["wood"], Vector3.ZERO, 0.0, true)
	var cloth := LowPoly.begin()
	var segments := 6
	for index in segments:
		var t0 := float(index) / float(segments)
		var t1 := float(index + 1) / float(segments)
		var x0 := 0.0 + t0 * 1.2
		var x1 := 0.0 + t1 * 1.2
		var wave0 := sin(t0 * 7.0) * 0.08
		var wave1 := sin(t1 * 7.0) * 0.08
		var y_top := 1.58
		var y_bottom := 0.2 + sin(t0 * 5.0) * 0.12
		LowPoly.push_quad(cloth,
			Vector3(x0, y_top, wave0), Vector3(x1, y_top, wave1),
			Vector3(x1, y_bottom, wave1 * 1.4), Vector3(x0, y_bottom + 0.12, wave0 * 1.4),
			_tone(color, _rng.randf_range(-0.02, 0.02)))
	_mesh_node(body, "Cloth", LowPoly.commit(cloth), _mats["cloth"], Vector3.ZERO, 0.0, false)


func _bench(parent: Node3D, name: String, position: Vector3, yaw: float) -> void:
	var body := _static(parent, name, position, yaw)
	var builder := LowPoly.begin()
	_add_box(builder, Vector3(0, 0.48, 0), Vector3(2.6, 0.16, 0.68), Color(0.24, 0.22, 0.18), 0.03)
	_add_box(builder, Vector3(-1.0, 0.24, 0), Vector3(0.22, 0.48, 0.55), Color(0.20, 0.19, 0.16), 0.02)
	_add_box(builder, Vector3(1.0, 0.24, 0), Vector3(0.22, 0.48, 0.55), Color(0.20, 0.19, 0.16), 0.02)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["wood"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(2.6, 0.65, 0.7), Vector3(0, 0.33, 0))


func _rubble(parent: Node3D, name: String, position: Vector3, radius: float) -> void:
	var body := _static(parent, name, position)
	var builder := LowPoly.begin()
	for index in 7:
		var angle := _rng.randf_range(0.0, TAU)
		var distance := _rng.randf_range(0.0, radius)
		var at := Vector3(cos(angle) * distance, _rng.randf_range(0.12, 0.5), sin(angle) * distance)
		var size := _rng.randf_range(0.35, 0.9)
		var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)) \
			* Basis(Vector3.RIGHT, _rng.randf_range(-0.3, 0.3))
		_add_box(builder, at, Vector3(size, _rng.randf_range(0.2, 0.45), size * 0.8),
			_tone(Color(0.27, 0.28, 0.27), _rng.randf_range(-0.03, 0.03)), 0.03, basis)
	_add_rock(builder, Vector3(0, 0.45, 0), radius * 0.8, radius * 1.2,
		Color(0.24, 0.26, 0.24))
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(radius * 1.6, 0.75, radius * 1.6), Vector3(0, 0.37, 0))


func _fallen_column(parent: Node3D, name: String, position: Vector3, yaw: float) -> void:
	var body := _static(parent, name, position, yaw)
	var builder := LowPoly.begin()
	var stone := Color(0.33, 0.34, 0.32)
	_add_box(builder, Vector3(0, 0.22, 0), Vector3(2.6, 0.44, 1.0), stone.darkened(0.12), 0.03)
	_add_cyl(builder, Vector3(-0.35, 0.66, 0), 0.44, 0.44, 2.7, stone, 10,
		Basis(Vector3.BACK, deg_to_rad(90.0)))
	_add_cyl(builder, Vector3(1.15, 0.62, 0.25), 0.42, 0.42, 2.3, stone.lightened(0.02), 10,
		Basis(Vector3.BACK, deg_to_rad(84.0)) * Basis(Vector3.UP, deg_to_rad(18.0)))
	_add_rock(builder, Vector3(1.8, 0.24, -0.7), 0.5, 0.8, stone.darkened(0.04))
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(3.4, 0.9, 1.2), Vector3(0.4, 0.45, 0))


func _dead_tree(parent: Node3D, name: String, position: Vector3, scale_value: float) -> void:
	var body := _static(parent, name, position)
	body.scale = Vector3.ONE * scale_value
	var builder := LowPoly.begin()
	var bark := Color(0.17, 0.14, 0.10)
	_add_cyl(builder, Vector3(0, 2.5, 0), 0.12, 0.3, 5.0, bark, 7)
	for index in 8:
		var angle := float(index) * 2.1
		var length := 2.1 - (index % 3) * 0.4
		var tilt := Basis(Vector3.UP, angle) * Basis(Vector3.RIGHT, deg_to_rad(56.0))
		_add_cyl(builder, Vector3(0, 2.6 + (index % 3) * 0.55, 0)
			+ Vector3(cos(angle) * length * 0.3, length * 0.32, sin(angle) * length * 0.3),
			0.03, 0.11, length, bark, 5, tilt)
	# 树池
	_add_box(builder, Vector3(0, 0.12, 0), Vector3(2.0, 0.24, 2.0), Color(0.24, 0.25, 0.23), 0.03)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["wood"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(0.8, 5.0, 0.8), Vector3(0, 2.5, 0))


func _add_crystal_shard(builder: LowPoly.Builder, base: Vector3, radius: float,
		height: float, tint: Color, tilt_x: float, tilt_z: float) -> void:
	var basis := Basis(Vector3.RIGHT, tilt_x) * Basis(Vector3.BACK, tilt_z)
	var body_height := height * 0.62
	var tip_height := height * 0.38
	var body_center := base + basis * Vector3(0, body_height * 0.5, 0)
	_add_cyl(builder, body_center, radius * 0.62, radius, body_height, tint, 8, basis)
	var tip_center := base + basis * Vector3(0, body_height + tip_height * 0.5, 0)
	_add_cone(builder, tip_center, radius * 0.62, tip_height, tint.lightened(0.08), basis)


func _crystal_cluster(parent: Node3D, name: String, position: Vector3, scale_value: float,
		material: Material, is_main := false, halo := false) -> void:
	var body := _static(parent, name, position)
	body.scale = Vector3.ONE * scale_value
	body.add_to_group("Crystals")
	var builder := LowPoly.begin()
	var specs := [
		[0.0, 0.0, 0.74, 4.4, 0.0, 0.0],
		[-0.9, 0.5, 0.52, 3.2, -0.14, 0.10],
		[0.9, 0.35, 0.48, 2.8, 0.18, -0.08],
		[-0.35, -0.85, 0.42, 2.3, 0.10, 0.20],
		[0.52, -0.72, 0.36, 1.9, -0.18, -0.12],
	]
	for index in specs.size():
		var spec: Array = specs[index]
		var tint := Color(0.62, 0.86, 1.0).lightened(float(index) * 0.035)
		_add_crystal_shard(builder, Vector3(float(spec[0]), 0, float(spec[1])),
			float(spec[2]), float(spec[3]), tint, float(spec[4]), float(spec[5]))
	_mesh_node(body, "Mesh", LowPoly.commit(builder), material, Vector3.ZERO, 0.0, true)
	if halo:
		var ring := TorusMesh.new()
		ring.inner_radius = 1.25
		ring.outer_radius = 1.43
		ring.rings = 32
		ring.ring_segments = 6
		var halo_node := _mesh_node(body, "Halo", ring, _mats["gold_plain"],
			Vector3(0, 2.55, -0.4), 0.0, false)
		halo_node.rotation_degrees.x = 90.0
	if is_main:
		var light := OmniLight3D.new()
		light.name = "CrystalLight"
		light.position = Vector3(0, 2.9, 0)
		light.light_color = Color(0.55, 0.80, 1.0)
		light.light_energy = 0.8
		light.omni_range = 10.0
		light.omni_attenuation = 1.2
		light.shadow_enabled = false
		body.add_child(light)
		light.owner = scene_root


func _add_cone_facets(builder: LowPoly.Builder, center: Vector3, radius: float, height: float,
		tint: Color, facets: int, basis := Basis.IDENTITY) -> void:
	_append(builder, LowPoly.faceted_cone(radius, height, facets),
		Transform3D(basis, center), tint)


func _crystal_prism_mesh(radius: float, body_height: float, tip_height: float,
		sides: int) -> ArrayMesh:
	# 单根六棱晶：直柱 + 锥尖，逐面平法线，避免内置 CylinderMesh 的平滑法线把
	# 晶体糊成一根蓝色圆锥。
	var builder := LowPoly.begin()
	var ring0: Array[Vector3] = []
	var ring1: Array[Vector3] = []
	for index in sides:
		var angle := TAU * float(index) / float(sides)
		ring0.append(Vector3(cos(angle) * radius, 0, sin(angle) * radius))
		ring1.append(Vector3(cos(angle) * radius, body_height, sin(angle) * radius))
	var top := Vector3(0, body_height + tip_height, 0)
	var bottom := Vector3(0, 0, 0)
	for index in sides:
		var next := (index + 1) % sides
		var light := Color(0.80, 0.93, 1.0) if index % 2 == 0 else Color(0.58, 0.79, 0.96)
		LowPoly.push_quad(builder, ring0[index], ring1[index], ring1[next], ring0[next], light)
		LowPoly.push_triangle(builder, ring1[index], top, ring1[next],
			light.lightened(0.10))
		LowPoly.push_triangle(builder, ring0[index], ring0[next], bottom,
			Color(0.42, 0.64, 0.82))
	return LowPoly.commit(builder)


func _sacred_crystal(parent: Node3D, name: String, position: Vector3, scale_value: float,
		material: Material) -> void:
	# 单根六棱晶体：柱身 + 锥尖，不再用簇状小晶体。
	var body := _static(parent, name, position)
	body.scale = Vector3.ONE * scale_value
	body.add_to_group("Crystals")
	# 圣晶不是直接立在台面上：它插在一个低矮的深色石质圣龛座里，座口有一圈金箍。
	var plinth := CylinderMesh.new()
	plinth.top_radius = 1.02
	plinth.bottom_radius = 1.12
	plinth.height = 0.16
	plinth.radial_segments = 12
	plinth.rings = 1
	_mesh_node(body, "ReliquaryPlinth", plinth, _mats["stone_frame"],
		Vector3(0, 0.08, 0), 0.0, true)
	var rim := TorusMesh.new()
	rim.inner_radius = 1.02
	rim.outer_radius = 1.12
	rim.rings = 24
	rim.ring_segments = 6
	_mesh_node(body, "PlinthRim", rim, _mats["gold_plain"],
		Vector3(0, 0.16, 0), 0.0, false)
	var crystal_mesh := _crystal_prism_mesh(0.95, 2.2, 1.1, 6)
	_mesh_node(body, "Mesh", crystal_mesh, material, Vector3.ZERO, 0.0, true)
	var light := OmniLight3D.new()
	light.name = "CrystalLight"
	light.position = Vector3(0, 2.2, 0)
	light.light_color = Color(0.64, 0.82, 1.0)
	light.light_energy = 1.1
	light.omni_range = 8.0
	light.omni_attenuation = 1.3
	light.shadow_enabled = false
	body.add_child(light)
	light.owner = scene_root


func _cloister_well(parent: Node3D, name: String, position: Vector3) -> void:
	var body := _static(parent, name, position)
	var builder := LowPoly.begin()
	_add_cyl(builder, Vector3(0, 0.42, 0), 1.35, 1.55, 0.84,
		Color(0.30, 0.28, 0.24), 16)
	_add_cyl(builder, Vector3(0, 0.86, 0), 1.08, 1.08, 0.06,
		Color(0.05, 0.08, 0.09), 16)
	for side in [-1.0, 1.0]:
		_add_box(builder, Vector3(float(side) * 1.35, 1.55, 0), Vector3(0.22, 1.5, 0.22),
			Color(0.22, 0.17, 0.12), 0.02)
	_add_box(builder, Vector3(0, 2.95, 0), Vector3(3.2, 0.18, 1.8),
		Color(0.19, 0.16, 0.12), 0.03)
	_add_cyl(builder, Vector3(0.55, 1.55, 0), 0.16, 0.2, 0.28,
		Color(0.20, 0.16, 0.11), 8)
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(3.2, 1.0, 3.2), Vector3(0, 0.5, 0))


func _garden_tree(parent: Node3D, name: String, position: Vector3, scale_value: float) -> void:
	var body := Node3D.new()
	body.name = name
	body.position = position
	body.scale = Vector3.ONE * scale_value
	parent.add_child(body)
	body.owner = scene_root
	var builder := LowPoly.begin()
	_add_cyl(builder, Vector3(0, 1.3, 0), 0.16, 0.30, 2.6,
		Color(0.22, 0.16, 0.10), 7)
	_add_rock(builder, Vector3(0, 3.0, 0), 1.15, 1.7, Color(0.12, 0.22, 0.10))
	_add_rock(builder, Vector3(-0.55, 3.55, 0.2), 0.72, 1.1, Color(0.15, 0.26, 0.12))
	_add_rock(builder, Vector3(0.55, 3.5, -0.15), 0.66, 1.0, Color(0.13, 0.23, 0.10))
	_mesh_node(body, "Mesh", LowPoly.commit(builder), _mats["moss"], Vector3.ZERO, 0.0, true)
	_box_collision(body, Vector3(0.9, 2.6, 0.9), Vector3(0, 1.3, 0))


func _fountain(parent: Node3D, name: String, position: Vector3, crystal_scale := 0.0) -> void:
	var body := _static(parent, name, position)
	var builder := LowPoly.begin()
	var stone := Color(0.24, 0.25, 0.24)
	_add_cyl(builder, Vector3(0, 0.16, 0), 3.0, 3.2, 0.32, stone.darkened(0.1), 24)
	_add_cyl(builder, Vector3(0, 0.5, 0), 2.8, 2.85, 0.55, stone, 24)
	if crystal_scale <= 0.0:
		# 中央不是完整雕像，而是一截断柱与斜置的柱头：更像被遗弃的圣所。
		_add_box(builder, Vector3(0, 0.95, 0), Vector3(1.3, 0.4, 1.3), stone.darkened(0.12), 0.03)
		_add_cyl(builder, Vector3(0, 1.75, 0), 0.42, 0.52, 1.4, stone, 10)
		_add_box(builder, Vector3(0, 2.5, 0), Vector3(0.95, 0.24, 0.95), stone.lightened(0.04), 0.02)
		_add_box(builder, Vector3(0.28, 2.85, -0.18), Vector3(0.55, 0.5, 0.55),
			stone.darkened(0.06), 0.02, Basis(Vector3.BACK, deg_to_rad(24.0)))
		_add_rock(builder, Vector3(-0.62, 2.45, 0.35), 0.34, 0.5, stone.darkened(0.04),
			Basis(Vector3.UP, 0.7))
	_mesh_node(body, "Basin", LowPoly.commit(builder), _mats["stone"], Vector3.ZERO, 0.0, true)
	var rim := TorusMesh.new()
	rim.inner_radius = 2.32
	rim.outer_radius = 2.72
	rim.rings = 32
	rim.ring_segments = 6
	_mesh_node(body, "Rim", rim, _mats["stone_plain"], Vector3(0, 0.8, 0), 0.0, true)
	_box_collision(body, Vector3(5.8, 1.0, 5.8), Vector3(0, 0.5, 0))
	var water := _static(parent, name + "_Water", position + Vector3(0, 0.79, 0))
	var disc := CylinderMesh.new()
	disc.top_radius = 2.45
	disc.bottom_radius = 2.45
	disc.height = 0.035
	disc.radial_segments = 32
	_mesh_node(water, "Water", disc, _mats["water"], Vector3.ZERO, 0.0, false)
	if crystal_scale > 0.0:
		_crystal_cluster(parent, name + "_SacredCrystal", position + Vector3(0, 0.94, 0),
			crystal_scale, _mats["crystal"], crystal_scale >= 0.9, crystal_scale >= 0.9)


func _floor_stain(parent: Node3D, name: String, position: Vector3, radius: float) -> void:
	var body := _static(parent, name, position)
	var builder := LowPoly.begin()
	_add_rock(builder, Vector3.ZERO, radius, 0.02, Color(0.18, 0.22, 0.16))
	_mesh_node(body, "Stain", LowPoly.commit(builder), _mats["moss"], Vector3.ZERO, 0.0, false)


func _load_sigil_paths() -> Dictionary:
	var file := FileAccess.open(SIGIL_PATH, FileAccess.READ)
	if file == null:
		push_error("无法读取圣徽轮廓：%s" % SIGIL_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("圣徽轮廓不是 JSON 对象：%s" % SIGIL_PATH)
		return {}
	var data: Dictionary = parsed
	var outer := _json_ring(data.get("outer", []))
	if outer.size() < 3:
		push_error("圣徽外轮廓点数不足")
		return {}
	var holes: Array[PackedVector2Array] = []
	for entry in data.get("holes", []):
		var hole := _json_ring(entry)
		if hole.size() >= 3:
			holes.append(hole)
	var all_rings: Array = [outer]
	all_rings.append_array(holes)
	var max_radius := 0.0
	for ring_entry in all_rings:
		var ring: PackedVector2Array = ring_entry
		for point in ring:
			max_radius = maxf(max_radius, point.length())
	var bbox: Dictionary = data.get("bbox", {})
	var hole_counts := PackedInt32Array()
	for hole in holes:
		hole_counts.append(hole.size())
	print("[圣所回廊] 圣徽轮廓：%d 点外环 + %s，包围高 %.4f，最大半径 %.4f" % [
		outer.size(), str(hole_counts), float(bbox.get("height", 0.0)), max_radius])
	return {"outer": outer, "holes": holes, "max_radius": max_radius}


func _json_ring(value: Variant) -> PackedVector2Array:
	var ring := PackedVector2Array()
	if typeof(value) != TYPE_ARRAY:
		return ring
	for entry in value:
		if typeof(entry) == TYPE_ARRAY and entry.size() >= 2:
			ring.append(Vector2(float(entry[0]), float(entry[1])))
	return ring


func _ring_area(ring: PackedVector2Array) -> float:
	var twice := 0.0
	for index in ring.size():
		var a := ring[index]
		var b := ring[(index + 1) % ring.size()]
		twice += a.x * b.y - b.x * a.y
	return twice * 0.5


func _scale_ring(ring: PackedVector2Array, scale_value: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(ring.size())
	for index in ring.size():
		result[index] = ring[index] * scale_value
	return result


func _grow_ring(ring: PackedVector2Array, delta: float) -> PackedVector2Array:
	var grown: Array[PackedVector2Array] = Geometry2D.offset_polygon(ring, delta)
	if grown.is_empty():
		return ring
	var best: PackedVector2Array = grown[0]
	var best_area := absf(_ring_area(best))
	for candidate in grown:
		var area := absf(_ring_area(candidate))
		if area > best_area:
			best_area = area
			best = candidate
	return best


## 把闭合轮廓挤出成硬边浮雕：正面按轮廓三角化，侧壁逐边生成。
## base_z 是贴在底板上的背面，depth 决定凸出高度；轮廓必须按 XY 平面给出。
func _prism_mesh(points: PackedVector2Array, base_z: float, depth: float,
		front_color: Color, side_color: Color) -> ArrayMesh:
	if points.size() < 3:
		return null
	var ring := points.duplicate()
	if _ring_area(ring) < 0.0:
		ring.reverse()
	var indices := Geometry2D.triangulate_polygon(ring)
	if indices.is_empty():
		var alt := ring.duplicate()
		alt.reverse()
		indices = Geometry2D.triangulate_polygon(alt)
		if not indices.is_empty():
			ring = alt
	if indices.is_empty():
		push_error("圣徽轮廓三角化失败（%d 点）" % ring.size())
		return null
	var builder := LowPoly.begin()
	var front_z := base_z + depth
	var covered := 0.0
	for index in range(0, indices.size(), 3):
		var a := ring[int(indices[index])]
		var b := ring[int(indices[index + 1])]
		var c := ring[int(indices[index + 2])]
		var cross := (b - a).cross(c - a)
		covered += absf(cross) * 0.5
		if cross < 0.0:
			var swap := b
			b = c
			c = swap
		LowPoly.push_triangle(builder,
			Vector3(a.x, a.y, front_z), Vector3(b.x, b.y, front_z),
			Vector3(c.x, c.y, front_z), front_color)
	var expected := absf(_ring_area(ring))
	if expected > 0.001 and absf(covered - expected) > expected * 0.01:
		push_error("圣徽三角面积不符：覆盖 %.3f / 轮廓 %.3f" % [covered, expected])
	for index in ring.size():
		var p0 := ring[index]
		var p1 := ring[(index + 1) % ring.size()]
		LowPoly.push_quad(builder,
			Vector3(p0.x, p0.y, front_z), Vector3(p0.x, p0.y, base_z),
			Vector3(p1.x, p1.y, base_z), Vector3(p1.x, p1.y, front_z), side_color)
	return LowPoly.commit(builder)


func _ring_pt(radius: float, angle: float, z: float) -> Vector3:
	return Vector3(cos(angle) * radius, sin(angle) * radius, z)


func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> PackedVector3Array:
	var points := PackedVector3Array()
	points.append(a)
	points.append(b)
	points.append(c)
	points.append(d)
	return points


## 提交一个平面四边形；points 的顺序不限，按 outward 统一朝外。
func _push_face(builder: LowPoly.Builder, points: PackedVector3Array, outward: Vector3,
		color: Color) -> void:
	if points.size() < 3:
		return
	var normal := (points[1] - points[0]).cross(points[2] - points[0])
	if normal.dot(outward) < 0.0:
		var reversed := PackedVector3Array()
		for index in range(points.size() - 1, -1, -1):
			reversed.append(points[index])
		points = reversed
	for index in range(1, points.size() - 1):
		LowPoly.push_triangle(builder, points[0], points[index], points[index + 1], color)


## 石框：一圈整体凿出来的圆环，前脸有内外倒棱和 16 道浅灰缝。
## 不在环上切出 24 道深槽，避免整个圣徽读成齿轮或轮盘。
func _sigil_stone_frame_mesh() -> ArrayMesh:
	var builder := LowPoly.begin()
	var segments := 64
	var inner := 2.15
	var inner_front := 2.20
	var outer_front := 2.50
	var outer := 2.55
	var front := 0.12
	var chamfer_z := 0.085
	var back := -0.28
	var base_tint := Color(0.355, 0.345, 0.315)
	var front_tint := base_tint
	var chamfer_tint := base_tint.darkened(0.05)
	var outer_side_tint := base_tint.darkened(0.12)
	var inner_side_tint := base_tint.darkened(0.18)
	for index in segments:
		var a0 := TAU * float(index) / float(segments)
		var a1 := TAU * float(index + 1) / float(segments)
		var mid := (a0 + a1) * 0.5
		var radial := Vector3(cos(mid), sin(mid), 0.0)
		_push_face(builder, _quad(
			_ring_pt(inner_front, a0, front), _ring_pt(outer_front, a0, front),
			_ring_pt(outer_front, a1, front), _ring_pt(inner_front, a1, front)),
			Vector3.BACK, front_tint)
		_push_face(builder, _quad(
			_ring_pt(outer_front, a0, front), _ring_pt(outer, a0, chamfer_z),
			_ring_pt(outer, a1, chamfer_z), _ring_pt(outer_front, a1, front)),
			(radial + Vector3(0, 0, 0.8)).normalized(), chamfer_tint)
		_push_face(builder, _quad(
			_ring_pt(outer, a0, chamfer_z), _ring_pt(outer, a0, back),
			_ring_pt(outer, a1, back), _ring_pt(outer, a1, chamfer_z)),
			radial, outer_side_tint)
		_push_face(builder, _quad(
			_ring_pt(inner_front, a0, front), _ring_pt(inner, a0, chamfer_z),
			_ring_pt(inner, a1, chamfer_z), _ring_pt(inner_front, a1, front)),
			(-radial + Vector3(0, 0, 0.8)).normalized(), chamfer_tint)
		_push_face(builder, _quad(
			_ring_pt(inner, a0, chamfer_z), _ring_pt(inner, a0, back),
			_ring_pt(inner, a1, back), _ring_pt(inner, a1, chamfer_z)),
			-radial, inner_side_tint)
		_push_face(builder, _quad(
			_ring_pt(inner, a0, back), _ring_pt(outer, a0, back),
			_ring_pt(outer, a1, back), _ring_pt(inner, a1, back)),
			Vector3.FORWARD, outer_side_tint)
	# 浅灰缝：只画在前脸表面，深度不到 2 mm，不会形成深槽阴影。
	var joints := 16
	for index in joints:
		var angle := TAU * float(index) / float(joints)
		var crack := index == 10
		var half := 0.008 if crack else 0.0035
		var mortar := Color(0.12, 0.12, 0.11) if crack else Color(0.19, 0.185, 0.17)
		_push_face(builder, _quad(
			_ring_pt(inner_front, angle - half, 0.1215),
			_ring_pt(outer_front, angle - half, 0.1215),
			_ring_pt(outer_front, angle + half, 0.1215),
			_ring_pt(inner_front, angle + half, 0.1215)),
			Vector3.BACK, mortar)
	return LowPoly.commit(builder)


func _sigil_gold_band_mesh() -> ArrayMesh:
	# 平嵌在雪花石边缘的鎏金铜带：宽 7 cm，向前只凸 1.8 cm。
	var builder := LowPoly.begin()
	var segments := 64
	var inner := 2.02
	var outer := 2.09
	var front := 0.022
	var back := 0.004
	var gold_tint := Color(0.76, 0.62, 0.31)
	for index in segments:
		var a0 := TAU * float(index) / float(segments)
		var a1 := TAU * float(index + 1) / float(segments)
		_push_face(builder, _quad(
			_ring_pt(inner, a0, front), _ring_pt(outer, a0, front),
			_ring_pt(outer, a1, front), _ring_pt(inner, a1, front)),
			Vector3.BACK, gold_tint)
		_push_face(builder, _quad(
			_ring_pt(outer, a0, front), _ring_pt(outer, a0, back),
			_ring_pt(outer, a1, back), _ring_pt(outer, a1, front)),
			Vector3(cos(a0), sin(a0), 0.0), gold_tint.darkened(0.14))
		_push_face(builder, _quad(
			_ring_pt(inner, a0, front), _ring_pt(inner, a0, back),
			_ring_pt(inner, a1, back), _ring_pt(inner, a1, front)),
			Vector3(-cos(a0), -sin(a0), 0.0), gold_tint.darkened(0.14))
	return LowPoly.commit(builder)


func _sigil_repair_staple(parent: Node3D) -> void:
	# 圣所遭袭后修过的一处石缝：铁锔子跨过 225° 的修补裂缝。
	var angle := TAU * 10.0 / 16.0
	var radial := Vector3(cos(angle), sin(angle), 0.0)
	var tangent := Vector3(-sin(angle), cos(angle), 0.0)
	var center := radial * 2.35 + Vector3(0, 0, 0.130)
	var builder := LowPoly.begin()
	_add_box(builder, center, Vector3(0.055, 0.26, 0.012), Color(0.42, 0.42, 0.45),
		0.003, Basis(Vector3.BACK, angle))
	for offset in [-0.125, 0.125]:
		var off: float = offset
		_add_box(builder, center + tangent * off + Vector3(0, 0, 0.003),
			Vector3(0.075, 0.055, 0.010), Color(0.36, 0.36, 0.39), 0.003,
			Basis(Vector3.BACK, angle))
	_mesh_node(parent, "RepairStaple", LowPoly.commit(builder), _mats["iron"],
		Vector3.ZERO, 0.0, false)


func _whale_sigil(parent: Node3D, center: Vector3) -> void:
	if _sigil.is_empty():
		return
	var outer: PackedVector2Array = _sigil["outer"]
	var holes: Array = _sigil["holes"]
	var max_radius: float = _sigil["max_radius"]
	var mark_width := 1.86 / maxf(max_radius, 0.001)
	var body := _static(parent, "WhaleSigil", center)
	body.add_to_group("Sigils")
	body.add_to_group("WhaleSigil")

	# 圆盘底板：背光雪花石。正面与墙内侧齐平，后方嵌进墙体，只在前方留 30 cm 厚石层。
	var field := CylinderMesh.new()
	field.top_radius = 2.10
	field.bottom_radius = 2.10
	field.height = 0.30
	field.radial_segments = 64
	field.rings = 1
	var field_instance := _mesh_node(body, "AlabasterField", field, _mats["alabaster"],
		Vector3(0, 0, -0.15), 0.0, false)
	field_instance.rotation_degrees.x = 90.0

	# 石框不再是一整圈车出来的圆环，而是 24 块楔石砌成的圆窗框。
	var frame := _sigil_stone_frame_mesh()
	if frame == null:
		push_error("圣徽石框网格为空")
	else:
		_mesh_node(body, "StoneFrame", frame, _mats["stone"], Vector3.ZERO, 0.0, true)
	var band := _sigil_gold_band_mesh()
	if band != null:
		_mesh_node(body, "GildedBand", band, _mats["gold"], Vector3.ZERO, 0.0, false)

	# 深色鲸形浮雕：参考图的黑剪影；腹部与眼斑用同一种雪花石嵌片补回去。
	var relief := _prism_mesh(_scale_ring(outer, mark_width), 0.0, 0.09,
		Color(0.055, 0.060, 0.068), Color(0.030, 0.033, 0.038))
	if relief == null:
		push_error("圣徽浮雕网格为空")
	else:
		_mesh_node(body, "LeviathanRelief", relief, _mats["basalt"], Vector3.ZERO, 0.0, true)
	for index in holes.size():
		var hole: PackedVector2Array = holes[index]
		var inlay := _prism_mesh(_grow_ring(_scale_ring(hole, mark_width), 0.012), 0.08, 0.03,
			Color.WHITE, Color.WHITE)
		if inlay == null:
			push_error("圣徽嵌片 %d 网格为空" % index)
			continue
		_mesh_node(body, "AlabasterInlay_%02d" % index, inlay,
			_mats["alabaster"], Vector3.ZERO, 0.0, false)
	_sigil_repair_staple(body)

	# 背光雪花石的暖色溢光：只照亮石框与浮雕侧壁，不再从殿内打一盏无来源的射灯。
	var spill := OmniLight3D.new()
	spill.name = "AlabasterSpill"
	spill.position = Vector3(0, -0.15, 0.95)
	spill.light_color = Color(1.0, 0.97, 0.91)
	spill.light_energy = 0.5
	spill.omni_range = 3.4
	spill.omni_attenuation = 1.7
	spill.shadow_enabled = false
	body.add_child(spill)
	spill.owner = scene_root

	print("[圣所回廊] 圣徽已放置：宽 %.2f m，中心 (%.2f, %.2f, %.2f)" % [
		mark_width, center.x, center.y, center.z])


func _light_shaft(parent: Node3D, top: Vector3, height: float) -> void:
	# 之前这里有一根透明锥体假光柱；锥体接缝在画面中央形成一条垂直亮线，
	# 比光柱本身更抢眼。预览阶段先只保留真实聚光灯与天光洞。
	var spot := SpotLight3D.new()
	spot.name = "AltarSpot"
	spot.position = top + Vector3(0.2, 1.0, 0)
	spot.rotation_degrees = Vector3(-90, 0, 0)
	spot.light_color = Color(0.68, 0.80, 0.95)
	spot.light_energy = 3.2
	spot.spot_range = 18.0
	spot.spot_angle = 34.0
	spot.spot_attenuation = 0.7
	spot.shadow_enabled = true
	parent.add_child(spot)
	spot.owner = scene_root


# ---------------------------------------------------------------- 灯光与预览

func _build_dressing() -> void:
	var braziers := _group(scene_root, "Braziers")
	_add_small_brazier(braziers, "GateFireW", Vector3(-4.0, 0, 31.7), true)
	_add_small_brazier(braziers, "GateFireE", Vector3(4.0, 0, 31.7), true)
	_add_small_brazier(braziers, "SouthLandingFireW", Vector3(-8.0, 0, 27.2), true)
	_add_small_brazier(braziers, "SouthLandingFireE", Vector3(8.0, 0, 27.2), true)
	_add_small_brazier(braziers, "CourtFireW", Vector3(-17.0, COURT_Y, 16.0), true)
	_add_small_brazier(braziers, "CourtFireE", Vector3(18.0, COURT_Y, 19.0), true)
	_add_small_brazier(braziers, "InnerGateFireW", Vector3(-5.0, 0, -3.0), true)
	_add_small_brazier(braziers, "InnerGateFireE", Vector3(5.0, 0, -3.0), true)
	_add_small_brazier(braziers, "HallFireW", Vector3(-5.5, 0, -8.5), true)
	_add_small_brazier(braziers, "HallFireE", Vector3(5.5, 0, -8.5), true)
	_add_small_brazier(braziers, "AltarFireW", Vector3(-3.0, 0, -29.0), true)
	_add_small_brazier(braziers, "AltarFireE", Vector3(3.0, 0, -29.0), true)

	var statues := _group(scene_root, "Statues")
	_statue(statues, "InnerGateSaintW", Vector3(-11.2, 2.3, -3.45), PI * 0.2, 0.82,
		Color(0.40, 0.41, 0.39), true, true)
	_statue(statues, "InnerGateSaintE", Vector3(11.2, 2.3, -3.45), -PI * 0.2, 0.82,
		Color(0.40, 0.41, 0.39), true, true)
	for side in [-1.0, 1.0]:
		var corbel := _static(statues, "InnerGateCorbel_%s" % ("W" if side < 0 else "E"),
			Vector3(11.2 * side, 2.1, -3.55))
		var corbel_builder := LowPoly.begin()
		_add_box(corbel_builder, Vector3.ZERO, Vector3(1.6, 0.35, 1.0),
			Color(0.31, 0.29, 0.25), 0.025)
		_mesh_node(corbel, "Mesh", LowPoly.commit(corbel_builder), _mats["stone"],
			Vector3.ZERO, 0.0, true)
	_statue(statues, "HallSaintW", Vector3(-11.8, 0.0, -20.0), PI * 0.5, 1.2,
		Color(0.39, 0.40, 0.38), false, true)
	_statue(statues, "HallSaintE", Vector3(11.8, 0.0, -20.0), -PI * 0.5, 1.2,
		Color(0.39, 0.40, 0.38), false, true)

	var banners := _group(scene_root, "Banners")
	_banner(banners, "GateBannerW", Vector3(-6.4, 5.2, 30.4), 0.0, Color(0.30, 0.05, 0.05))
	_banner(banners, "GateBannerE", Vector3(6.4, 5.2, 30.4), 0.0, Color(0.30, 0.05, 0.05))
	_banner(banners, "HallBannerW", Vector3(-6.7, 4.4, -14.0), PI * 0.5, Color(0.16, 0.05, 0.07))
	_banner(banners, "HallBannerE", Vector3(6.7, 4.4, -14.0), -PI * 0.5, Color(0.16, 0.05, 0.07))

	var rubble := _group(scene_root, "Rubble")
	_rubble(rubble, "OuterRubbleW", Vector3(-25.0, 0, 25.0), 2.2)
	_rubble(rubble, "OuterRubbleE", Vector3(26.0, 0, 21.0), 2.0)
	# 高坛两侧的石块以前堆到后墙脚下，正好挡在圣徽前；遭袭的痕迹留在东回廊与中殿侧廊，
	# 高坛本身保持被教团清理过的状态。
	_rubble(rubble, "GateRubbleW", Vector3(-8.0, 0, 28.5), 1.8)
	_rubble(rubble, "GateRubbleE", Vector3(8.0, 0, 28.5), 1.8)


func _build_lights() -> void:
	var lights := _group(scene_root, "Lights")
	# 庭院与大厅的补光：只在关键机位，不制造大量带阴影点光。
	var court_fill := OmniLight3D.new()
	court_fill.name = "CourtFill"
	court_fill.position = Vector3(0, 7.0, 13.0)
	court_fill.light_color = Color(0.52, 0.62, 0.76)
	court_fill.light_energy = 0.8
	court_fill.omni_range = 30.0
	court_fill.omni_attenuation = 1.6
	court_fill.shadow_enabled = false
	lights.add_child(court_fill)
	court_fill.owner = scene_root

	var hall_fill := OmniLight3D.new()
	hall_fill.name = "HallFill"
	hall_fill.position = Vector3(0, 5.5, -20.0)
	hall_fill.light_color = Color(0.55, 0.63, 0.76)
	hall_fill.light_energy = 0.95
	hall_fill.omni_range = 26.0
	hall_fill.omni_attenuation = 1.8
	hall_fill.shadow_enabled = false
	lights.add_child(hall_fill)
	hall_fill.owner = scene_root

	var altar_fill := SpotLight3D.new()
	altar_fill.name = "AltarRim"
	altar_fill.position = Vector3(0, 5.0, -26.0)
	altar_fill.rotation_degrees = Vector3(-25.0, 180.0, 0.0)
	altar_fill.light_color = Color(0.72, 0.84, 1.0)
	altar_fill.light_energy = 1.2
	altar_fill.spot_range = 12.0
	altar_fill.spot_angle = 42.0
	altar_fill.shadow_enabled = false
	lights.add_child(altar_fill)
	altar_fill.owner = scene_root


func _build_preview() -> void:
	var preview := _group(scene_root, "Preview")
	var walker_scene: Resource = load(WALKER_PATH)
	if walker_scene is PackedScene:
		var walker := (walker_scene as PackedScene).instantiate() as Node3D
		walker.name = "PreviewWalker"
		walker.position = SPAWN
		preview.add_child(walker)
		walker.owner = scene_root
	else:
		push_warning("预览行走场景不可用：%s" % WALKER_PATH)

	var markers := _group(scene_root, "Markers")
	_marker(markers, "PlayerSpawn", SPAWN)
	_marker(markers, "Camera_Approach", Vector3(0, 1.7, 52))
	_marker(markers, "Camera_Gate", Vector3(0, 1.7, 38))
	_marker(markers, "Camera_Court", Vector3(0, 1.7, 24))
	_marker(markers, "Camera_Cloister", Vector3(-25, 1.7, 14))
	_marker(markers, "Camera_Nave", Vector3(0, 1.7, -8))
	_marker(markers, "Camera_Altar", Vector3(0, 1.7, -24))
	_marker(markers, "Camera_Overview", Vector3(34, 26, 46))


func _marker(parent: Node3D, name: String, position: Vector3) -> void:
	var marker := Marker3D.new()
	marker.name = name
	marker.position = position
	parent.add_child(marker)
	marker.owner = scene_root


# ---------------------------------------------------------------- 预览角色场景

func _build_walker_scene() -> bool:
	var walker := CharacterBody3D.new()
	walker.name = "PreviewWalker"
	var script: Script = load(WALKER_SCRIPT)
	if script == null:
		push_error("预览控制脚本不可用：%s" % WALKER_SCRIPT)
		return false
	walker.set_script(script)
	walker.collision_layer = 1
	walker.collision_mask = 1

	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.33
	capsule.height = 1.78
	collision.shape = capsule
	collision.position = Vector3(0, 0.89, 0)
	walker.add_child(collision)
	collision.owner = walker

	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 1.62, 0)
	walker.add_child(head)
	head.owner = walker
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = 76.0
	camera.near = 0.04
	camera.far = 2200.0
	camera.current = true
	head.add_child(camera)
	camera.owner = walker

	var canvas := CanvasLayer.new()
	canvas.name = "UI"
	canvas.layer = 10
	walker.add_child(canvas)
	canvas.owner = walker

	var root_control := Control.new()
	root_control.name = "Root"
	root_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(root_control)
	root_control.owner = walker

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.position = Vector2(16, 16)
	panel.custom_minimum_size = Vector2(420, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.015, 0.02, 0.025, 0.84)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.48, 0.54, 0.60, 0.55)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	root_control.add_child(panel)
	panel.owner = walker

	var margin := MarginContainer.new()
	margin.name = "Margin"
	panel.add_child(margin)
	margin.owner = walker
	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)
	vbox.owner = walker

	var title := Label.new()
	title.name = "Title"
	title.text = "圣所回廊 · 编辑器预览"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(0.88, 0.91, 0.94))
	vbox.add_child(title)
	title.owner = walker

	var controls := Label.new()
	controls.name = "Controls"
	controls.text = "WASD 移动 · Shift 冲刺 · 空格 跳\n左键锁定视角 · Esc 释放 · R 回到起点"
	controls.add_theme_font_size_override("font_size", 13)
	controls.add_theme_color_override("font_color", Color(0.72, 0.77, 0.82))
	controls.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(controls)
	controls.owner = walker

	var hint := Label.new()
	hint.name = "Hint"
	hint.text = "点击画面锁定视角"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.52, 0.78, 0.92))
	vbox.add_child(hint)
	hint.owner = walker

	var crosshair := ColorRect.new()
	crosshair.name = "Crosshair"
	crosshair.color = Color(0.86, 0.92, 1.0, 0.68)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.anchor_left = 0.5
	crosshair.anchor_top = 0.5
	crosshair.anchor_right = 0.5
	crosshair.anchor_bottom = 0.5
	crosshair.offset_left = -2
	crosshair.offset_top = -2
	crosshair.offset_right = 2
	crosshair.offset_bottom = 2
	root_control.add_child(crosshair)
	crosshair.owner = walker

	var packed := PackedScene.new()
	if packed.pack(walker) != OK:
		push_error("预览角色场景打包失败")
		return false
	if ResourceSaver.save(packed, WALKER_PATH) != OK:
		push_error("预览角色场景保存失败：%s" % WALKER_PATH)
		return false
	walker.free()
	print("[圣所回廊] 已生成预览角色：", WALKER_PATH)
	return true
