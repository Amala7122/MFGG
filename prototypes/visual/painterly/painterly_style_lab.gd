extends Node3D
## Isolated visual experiment. Does not read/write production graphics presets,
## saved settings, map generation, combat, or the production player scene.

const Geometry := preload("res://scripts/lowpoly_mesh.gd")
const PaintShader := preload("res://prototypes/visual/painterly/painted_surface.gdshader")
const ArtistShader := preload("res://prototypes/visual/painterly/artist_surface.gdshader")
const ArtistSkyShader := preload("res://prototypes/visual/painterly/artist_sky.gdshader")
const ArtistPresets := preload("res://prototypes/visual/painterly/artist_presets.gd")
const StylizedGeometry := preload("res://prototypes/visual/painterly/stylized_geometry.gd")
const OutlineShader := preload("res://prototypes/visual/painterly/ink_outline.gdshader")
const CapturePaths := preload("res://scripts/capture_paths.gd")
const UiTheme := preload("res://scripts/ui_theme.gd")
const STYLE_NAMES := ["原始材质", "水粉手绘", "明显笔触", "水墨丹青 · 山水留白", "莫奈启发 · 印象色光", "塞尚启发 · 色面建构", "梵高启发 · 律动厚涂", "北斋启发 · 木版套色"]
const LIGHT_NAMES := ["晴天", "阴天", "夜间 · 手电筒"]
const CAMERA_VIEWS := [
	[Vector3(12, 6.0, 21), Vector3(0, 2.0, -3)],
	[Vector3(-15, 6.5, -14), Vector3(0, 2, 0)],
	[Vector3(6.5, 3.4, 6), Vector3(-2, 1.8, -2)],
	[Vector3(0, 25, 19), Vector3(0, 0, -3)],
]

var style_index := 1
var lighting_index := 0
var brush_strength := 0.65
var shape_studies_enabled := true
var surface_records: Array[Dictionary] = []
var environment: Environment
var camera: Camera3D
var sun: DirectionalLight3D
var flashlight: SpotLight3D
var ui: CanvasLayer
var style_picker: OptionButton
var lighting_picker: OptionButton
var status_label: Label
var description_label: Label
var orbit_target := Vector3(0, 2, -3)
var orbit_yaw := 0.0
var orbit_pitch := 0.25
var orbit_distance := 25.0
var _guard_frames := 4
var _flow: CanvasLayer
var _previous_flow_mode: int
var _previous_flow_visible := false
var _previous_paused := false
var _previous_mouse_mode: int
var _previous_environment: Environment
var _sky_material: ProceduralSkyMaterial
var _artist_sky_material: ShaderMaterial
var _capture_requested := false

func _ready() -> void:
	_previous_paused = get_tree().paused
	_previous_mouse_mode = Input.mouse_mode
	_flow = get_node_or_null("/root/GameFlow") as CanvasLayer
	if _flow:
		_previous_flow_mode = _flow.process_mode
		_previous_flow_visible = _flow.visible
	_isolate()
	_build_environment()
	_build_meadow()
	_build_composition()
	_build_shape_variants()
	_build_camera()
	_build_controls()
	set_style(1)
	set_lighting(0)
	set_view(0)
	_capture_requested = "--painterly-capture" in OS.get_cmdline_user_args() or "--artist-capture" in OS.get_cmdline_user_args()
	if _capture_requested:
		capture_suite.call_deferred()

func _isolate() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _flow:
		_flow.process_mode = Node.PROCESS_MODE_DISABLED
		_flow.visible = false

func _exit_tree() -> void:
	if is_instance_valid(_flow):
		_flow.process_mode = _previous_flow_mode
		_flow.visible = _previous_flow_visible
	if get_tree():
		get_tree().paused = _previous_paused
	Input.mouse_mode = _previous_mouse_mode as Input.MouseMode
	if is_inside_tree():
		get_world_3d().environment = _previous_environment

func _process(_delta: float) -> void:
	if _guard_frames > 0:
		_isolate()
		_guard_frames -= 1

func _build_environment() -> void:
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	_sky_material = ProceduralSkyMaterial.new()
	_sky_material.sky_top_color = Color("719ebf")
	_sky_material.sky_horizon_color = Color("c7d9d7")
	_sky_material.ground_horizon_color = Color("c7d9d7")
	_sky_material.ground_bottom_color = Color("738970")
	sky.sky_material = _sky_material
	_artist_sky_material = ShaderMaterial.new()
	_artist_sky_material.shader = ArtistSkyShader
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("bfd1d8")
	environment.ambient_light_energy = 0.7
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.fog_enabled = true
	environment.fog_density = 0.004
	environment.fog_light_color = Color("b6cad2")
	environment.fog_sky_affect = 0.15
	environment.ssao_enabled = true
	environment.ssao_radius = 0.7
	environment.ssao_intensity = 0.55
	# No WorldEnvironment node: the production graphics director deliberately
	# cannot discover and overwrite this laboratory's environment.
	_previous_environment = get_world_3d().environment
	get_world_3d().environment = environment
	sun = DirectionalLight3D.new()
	sun.name = "LabSun"
	sun.rotation_degrees = Vector3(-43, -36, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80
	sun.light_angular_distance = 1.8
	add_child(sun)

static func meadow_height(x: float, z: float) -> float:
	return 0.26 * sin(x * 0.18) * cos(z * 0.16) + 0.12 * sin(z * 0.22)

func _build_meadow() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	const CELLS := 72
	const STEP := 1.0
	for z in CELLS:
		for x in CELLS:
			var px := (float(x) - CELLS * 0.5) * STEP
			var pz := (float(z) - CELLS * 0.5) * STEP
			# Godot front faces are clockwise; mathematical cross product faces down.
			for offset: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
				var vx := px + offset.x * STEP
				var vz := pz + offset.y * STEP
				var dx := (meadow_height(vx + 0.05, vz) - meadow_height(vx - 0.05, vz)) / 0.1
				var dz := (meadow_height(vx, vz + 0.05) - meadow_height(vx, vz - 0.05)) / 0.1
				surface.set_normal(Vector3(-dx, 1, -dz).normalized())
				surface.set_uv(Vector2(vx, vz))
				surface.add_vertex(Vector3(vx, meadow_height(vx, vz), vz))
	var meadow := _add_surface("MeadowAndRoad", surface.commit(), Vector3.ZERO, Color("748c49"), 0.65, true)
	# This near-flat sample does not need terrain self-shadowing. It still
	# receives shadows from props; excluding it as a caster avoids grazing-angle
	# shadow-map acne on the shallow undulations.
	meadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _add_surface(node_name: String, mesh: Mesh, pos: Vector3, color: Color, scale_value: float = 2.0, is_ground: bool = false) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = pos
	add_child(instance)
	# Keep the exact same shader/color pipeline for A/B comparisons. A standard
	# material here would also change the diffuse BRDF, confounding the comparison.
	var plain := ShaderMaterial.new()
	plain.shader = PaintShader
	plain.set_shader_parameter("base_color", color)
	plain.set_shader_parameter("brush_strength", 0.0)
	plain.set_shader_parameter("light_softness", 0.0)
	plain.set_shader_parameter("ground_surface", is_ground)
	var painted := ShaderMaterial.new()
	painted.shader = PaintShader
	painted.set_shader_parameter("base_color", color)
	painted.set_shader_parameter("brush_scale", scale_value)
	painted.set_shader_parameter("ground_surface", is_ground)
	# Ground keeps the same integrated road in the baseline.
	var artist := ShaderMaterial.new()
	artist.shader = ArtistShader
	artist.set_shader_parameter("brush_scale", scale_value)
	var kind := ArtistPresets.surface_kind(node_name, is_ground)
	artist.set_shader_parameter("surface_kind", kind)
	surface_records.append({"node": instance, "asset_name": node_name, "plain": plain, "painted": painted, "artist": artist, "kind": kind, "ground": is_ground})
	return instance

func _stone(node_name: String, pos: Vector3, size: Vector3, color: Color = Color("a19c80"), bevel: float = 0.12) -> MeshInstance3D:
	var stone := _add_surface(node_name, Geometry.chamfered_box(size, bevel), pos, color, 1.8)
	surface_records.back()["source_bevel"] = bevel
	return stone

func _ellipsoid(node_name: String, pos: Vector3, size: Vector3, color: Color, brush_scale_value: float = 2.0) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 1
	mesh.height = 2
	mesh.radial_segments = 32
	mesh.rings = 16
	var instance := _add_surface(node_name, mesh, pos, color, brush_scale_value)
	instance.scale = size
	return instance

func _build_composition() -> void:
	# A single simple ruin focal point, coherent masses, open paths and grouped
	# vegetation. No loose terrain plates, floating road decals or tiny debris.
	_stone("Threshold", Vector3(0, 0.12, -6), Vector3(7, 0.4, 3.2), Color("9a9278"), 0.10)
	for x: float in [-2.6, 2.6]:
		_stone("GateFoot", Vector3(x, 0.42, -6), Vector3(1.6, 0.6, 1.6))
		for j in 4:
			_stone("GateBlock", Vector3(x, 1.25 + j * 1.1, -6), Vector3(1.10, 1.08, 1.2), Color("a29e83"), 0.09)
		_stone("GateCapital", Vector3(x, 5.18, -6), Vector3(1.55, 0.36, 1.55), Color("b0aa8b"), 0.08)
	_stone("Lintel", Vector3(0, 5.65, -6), Vector3(6.9, 0.7, 1.5), Color("ada78a"), 0.16)
	_stone("BrokenWallLeft", Vector3(-5, 0.9, -2.5), Vector3(3.8, 1.6, 1.2))
	_stone("BrokenWallRight", Vector3(5, 0.8, -6.5), Vector3(3, 1.4, 1.3))
	_stone("FallenPillar", Vector3(-5.5, 0.28, 4), Vector3(3.2, 0.55, 0.85))
	_stone("StandingFragment", Vector3(7, 1.4, 0), Vector3(1, 2.8, 1.1))
	var crystal := Geometry.begin()
	var ring := [Vector3(0.36, 0, 0), Vector3(0, 0, 0.36), Vector3(-0.36, 0, 0), Vector3(0, 0, -0.36)]
	for apex: Vector3 in [Vector3(0, 0.65, 0), Vector3(0, -0.65, 0)]:
		for i in 4:
			var a: Vector3 = ring[i]
			var b: Vector3 = ring[(i + 1) % 4]
			if (b - a).cross(apex - a).dot((a + b + apex) / 3) < 0:
				Geometry.push_triangle(crystal, a, apex, b, Color.WHITE)
			else:
				Geometry.push_triangle(crystal, a, b, apex, Color.WHITE)
	_add_surface("Crystal", Geometry.commit(crystal), Vector3(0, 1.9, -6), Color("65d6c3"))
	# Large, overlapping smooth crowns; brush accents should read as pigment,
	# not triangulation. Each crown remains one opaque watertight surface.
	for item: Array in [[-9.0, 6.0, 1.15], [-8.0, -9.0, 0.9], [9.0, -12.0, 1.1], [10.0, 4.0, 0.9], [-13.0, -17.0, 0.8]]:
		_tree(Vector3(float(item[0]), 0, float(item[1])), float(item[2]))
	for item: Array in [[-5.5, 8.0, 1.7], [6.0, 5.0, 1.0], [-10.0, -3.0, 1.3], [8.5, -8.0, 1.4], [4.5, 10.0, 0.6]]:
		var x := float(item[0])
		var z := float(item[1])
		var radius := float(item[2])
		var rock := _ellipsoid("Boulder", Vector3(x, meadow_height(x, z) + radius * 0.38, z), Vector3(radius, radius * 0.65, radius * 0.85), Color("898e80"), 3.2)
		rock.rotation_degrees = Vector3(8, x * 7, 5)
	# Far silhouettes are broad overlapping hills, not isolated triangle peaks.
	for item: Array in [[-30.0, -40.0, 24.0, 11.0], [5.0, -53.0, 30.0, 17.0], [33.0, -42.0, 25.0, 13.0], [-47.0, -11.0, 21.0, 9.0], [46.0, 7.0, 21.0, 9.0], [0.0, 48.0, 36.0, 10.0]]:
		var ridge := _ellipsoid("DistantRidge", Vector3(float(item[0]), -3, float(item[1])), Vector3(float(item[2]), float(item[3]), float(item[2]) * 0.65), Color("889eaa"), 0.13)
		ridge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Sparse grouped plants: enough scale cues without filling every spare pixel.
	var rng := RandomNumberGenerator.new()
	rng.seed = 63021
	for cluster: Vector2 in [Vector2(-6, 6), Vector2(5, -3), Vector2(-7, -4), Vector2(8, 9), Vector2(-11, 8)]:
		for i in 14:
			var p := cluster + Vector2(rng.randf_range(-1.5, 1.5), rng.randf_range(-1.0, 1.0))
			var blade := CylinderMesh.new()
			blade.top_radius = 0
			blade.bottom_radius = rng.randf_range(0.06, 0.12)
			blade.height = rng.randf_range(0.3, 0.65)
			blade.radial_segments = 5
			var plant := _add_surface("GrassTuft", blade, Vector3(p.x, meadow_height(p.x, p.y) + blade.height / 2, p.y), Color("5a7940"), 4)
			plant.rotation_degrees.z = rng.randf_range(-12, 12)
		for i in 3:
			var p := cluster + Vector2(rng.randf_range(-1, 1), rng.randf_range(-0.6, 0.6))
			_ellipsoid("Wildflower", Vector3(p.x, meadow_height(p.x, p.y) + 0.3, p.y), Vector3(0.1, 0.13, 0.1), Color("d6bc62"), 4)

func _tree(pos: Vector3, tree_scale: float) -> void:
	pos.y = meadow_height(pos.x, pos.z)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.22 * tree_scale
	trunk.bottom_radius = 0.33 * tree_scale
	trunk.height = 3.8 * tree_scale
	trunk.radial_segments = 12
	_add_surface("TreeTrunk", trunk, pos + Vector3(0, trunk.height / 2, 0), Color("71563c"), 3)
	_ellipsoid("CrownLower", pos + Vector3(0, 3.8, 0) * tree_scale, Vector3(2.25, 1.2, 1.8) * tree_scale, Color("577944"), 2.3)
	_ellipsoid("CrownLeft", pos + Vector3(-0.6, 4.8, 0.1) * tree_scale, Vector3(1.5, 1.25, 1.5) * tree_scale, Color("71934d"), 2.3)
	_ellipsoid("CrownTop", pos + Vector3(0.55, 5.3, 0) * tree_scale, Vector3(1.15, 1.15, 1.25) * tree_scale, Color("849c55"), 2.3)
	# Only the shape studies show these supporting boughs. Retained gouache
	# remains untouched; each limb is a closed, tapered, real 3D mesh.
	for direction: Vector3 in [Vector3(-1.45, 1.0, 0.25), Vector3(1.15, 1.35, -0.2)]:
		var start := pos + Vector3(0.15, 2.75, 0) * tree_scale
		var end := start + direction * tree_scale
		var branch_mesh := CylinderMesh.new()
		branch_mesh.height = start.distance_to(end)
		branch_mesh.bottom_radius = 0.17 * tree_scale
		branch_mesh.top_radius = 0.07 * tree_scale
		branch_mesh.radial_segments = 10
		var branch := _add_surface("TreeBranch", branch_mesh, (start + end) / 2, Color("71563c"), 3)
		branch.quaternion = Quaternion(Vector3.UP, (end - start).normalized())
		surface_records.back()["artist_only"] = true
		branch.visible = false

func _build_shape_variants() -> void:
	for record: Dictionary in surface_records:
		var node := record.node as MeshInstance3D
		record["base_mesh"] = node.mesh
		record["base_transform"] = node.transform
		var kind: int = record.kind
		var variants: Array[Mesh] = []
		for ink in [true, false]:
			if kind in [2, 4, 5] and node.mesh is SphereMesh:
				variants.append(StylizedGeometry.organic_mass(kind, ink))
			elif kind == 3 and node.mesh is CylinderMesh:
				variants.append(StylizedGeometry.bent_trunk(node.mesh, ink))
			elif kind == 1 and node.mesh is ArrayMesh:
				variants.append(StylizedGeometry.carved_stone(node.mesh, ink, record.source_bevel))
			else:
				variants.append(node.mesh)
		record["shape_variants"] = variants
		record["contour_variants"] = [StylizedGeometry.contour_shell(variants[0]), StylizedGeometry.contour_shell(variants[1])]
		var outline := MeshInstance3D.new()
		outline.name = "InkContour"
		outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := ShaderMaterial.new()
		material.shader = OutlineShader
		outline.material_override = material
		outline.visible = false
		node.add_child(outline)
		record["outline"] = outline

func _apply_shape_style(record: Dictionary) -> void:
	var node := record.node as MeshInstance3D
	node.mesh = record.base_mesh
	node.transform = record.base_transform
	var outline := record.outline as MeshInstance3D
	outline.visible = false
	if record.get("artist_only", false):
		node.visible = shape_studies_enabled and style_index in [3, 7]
	if not shape_studies_enabled or style_index not in [3, 7]:
		return
	var ink := style_index == 3
	node.mesh = record.shape_variants[0 if ink else 1]
	var kind: int = record.kind
	if kind == 2 and node.mesh is ArrayMesh:
		node.scale *= Vector3(1.14, 0.85 if ink else 0.95, 1.06)
		# Use semantic asset names, not Godot's auto-renamed sibling node names.
		# Overlapping foliage forms one silhouette rather than floating saucers.
		var tree_scale := node.scale.x / (1.14 * (1.15 if record.asset_name == "CrownTop" else 1.5 if record.asset_name == "CrownLeft" else 2.25))
		if record.asset_name == "CrownTop":
			node.position.y -= (0.85 if ink else 0.35) * tree_scale
		elif record.asset_name == "CrownLeft":
			node.position.y -= (0.6 if ink else 0.25) * tree_scale
	if kind == 5:
		node.scale.y *= 1.05 if ink else 1.15
	outline.mesh = record.contour_variants[0 if ink else 1]
	outline.visible = kind in [1, 2, 3, 4] and not record.asset_name.begins_with("Grass")
	var material := outline.material_override as ShaderMaterial
	material.set_shader_parameter("line_width", 0.042 if ink else 0.024)
	material.set_shader_parameter("ink_color", Color("172b23") if ink else Color("293e3e"))

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "LabCamera"
	camera.fov = 55
	camera.far = 240
	add_child(camera)
	camera.make_current()
	flashlight = SpotLight3D.new()
	flashlight.name = "LabFlashlight"
	flashlight.position = Vector3(0.25, -0.15, -0.15)
	flashlight.light_color = Color("fff0d6")
	flashlight.light_energy = 7
	flashlight.spot_range = 35
	flashlight.spot_angle = 28
	flashlight.spot_attenuation = 0.7
	flashlight.spot_angle_attenuation = 0.8
	flashlight.shadow_enabled = true
	camera.add_child(flashlight)

func set_style(index: int) -> void:
	style_index = clampi(index, 0, STYLE_NAMES.size() - 1)
	for record: Dictionary in surface_records:
		_apply_shape_style(record)
		var material := record.painted as ShaderMaterial
		material.set_shader_parameter("brush_strength", 0.0 if style_index == 0 else minf(1.0, brush_strength * 1.5) if style_index == 2 else brush_strength)
		material.set_shader_parameter("light_softness", 0.0 if style_index == 0 else 0.55)
		if style_index < 3:
			(record.node as MeshInstance3D).material_override = record.plain if style_index == 0 else material
		else:
			var preset: Dictionary = ArtistPresets.PRESETS[style_index - 3]
			var artist := record.artist as ShaderMaterial
			artist.set_shader_parameter("artist_mode", preset.mode)
			artist.set_shader_parameter("base_color", Color(preset.palette[record.kind]))
			artist.set_shader_parameter("road_color", Color(preset.palette[7]))
			artist.set_shader_parameter("brush_strength", brush_strength)
			artist.set_shader_parameter("light_softness", preset.softness)
			(record.node as MeshInstance3D).material_override = artist
	_apply_atmosphere()
	if style_picker:
		style_picker.select(style_index)
	_refresh_status()

func set_brush_strength(value: float) -> void:
	brush_strength = clampf(value, 0, 1)
	set_style(style_index)

func set_shape_studies_enabled(value: bool) -> void:
	shape_studies_enabled = value
	set_style(style_index)

func set_lighting(index: int) -> void:
	lighting_index = clampi(index, 0, LIGHT_NAMES.size() - 1)
	_apply_atmosphere()
	flashlight.visible = lighting_index == 2
	if lighting_picker:
		lighting_picker.select(lighting_index)
	_refresh_status()

func _apply_atmosphere() -> void:
	sun.light_energy = [1.35, 0.55, 0.06][lighting_index]
	sun.light_color = [Color("ffe1b4"), Color("dee5ec"), Color("7190ad")][lighting_index]
	environment.ambient_light_energy = [0.7, 0.86, 0.22][lighting_index]
	environment.ambient_light_color = [Color("bfd1d8"), Color("cad4da"), Color("6b829b")][lighting_index]
	environment.fog_light_color = [Color("b6cad2"), Color("b9c5cb"), Color("344454")][lighting_index]
	_sky_material.sky_top_color = [Color("719ebf"), Color("8e9da5"), Color("172431")][lighting_index]
	_sky_material.sky_horizon_color = environment.fog_light_color
	_sky_material.ground_horizon_color = environment.fog_light_color
	environment.fog_density = 0.004
	if style_index < 3:
		environment.sky.sky_material = _sky_material
		return
	var preset: Dictionary = ArtistPresets.PRESETS[style_index - 3]
	environment.sky.sky_material = _artist_sky_material
	for record: Dictionary in surface_records:
		(record.artist as ShaderMaterial).set_shader_parameter("ridge_wash_energy", [0.7, 0.62, 0.025][lighting_index])
	sun.light_energy *= float(preset.sun_scale)
	environment.ambient_light_energy *= float(preset.ambient_scale)
	environment.fog_density = float(preset.fog)
	if lighting_index != 2:
		sun.light_color = Color(preset.sun)
		environment.ambient_light_color = Color(preset.ambient)
		environment.fog_light_color = Color(preset.horizon)
	_artist_sky_material.set_shader_parameter("artist_mode", preset.mode)
	_artist_sky_material.set_shader_parameter("sky_top", Color(preset.sky))
	_artist_sky_material.set_shader_parameter("sky_horizon", Color(preset.horizon))
	_artist_sky_material.set_shader_parameter("weather_brightness", [1.0, 0.8, 0.07][lighting_index])
	_artist_sky_material.set_shader_parameter("brush_strength", brush_strength)

func set_view(index: int) -> void:
	var view: Array = CAMERA_VIEWS[index % CAMERA_VIEWS.size()]
	camera.position = view[0]
	orbit_target = view[1]
	camera.look_at(orbit_target)
	var offset := camera.position - orbit_target
	orbit_distance = offset.length()
	orbit_yaw = atan2(offset.x, offset.z)
	orbit_pitch = asin(offset.y / orbit_distance)

func _orbit() -> void:
	camera.position = orbit_target + Vector3(sin(orbit_yaw) * cos(orbit_pitch), sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch)) * orbit_distance
	camera.look_at(orbit_target)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		orbit_yaw -= event.relative.x * 0.005
		orbit_pitch = clampf(orbit_pitch + event.relative.y * 0.005, 0.04, 1.45)
		_orbit()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			orbit_distance = maxf(4, orbit_distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			orbit_distance = minf(65, orbit_distance * 1.1)
		_orbit()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8: set_style(event.physical_keycode - KEY_1)
			KEY_L: set_lighting((lighting_index + 1) % 3)
			KEY_F: flashlight.visible = not flashlight.visible
			KEY_H: ui.visible = not ui.visible
			KEY_R: set_view(0)
			KEY_F5: set_view(1)
			KEY_F6: set_view(2)
			KEY_F7: set_view(3)

func _build_controls() -> void:
	ui = CanvasLayer.new()
	ui.layer = 110
	add_child(ui)
	var panel := PanelContainer.new()
	panel.position = Vector2(24, 24)
	panel.custom_minimum_size = Vector2(370, 0)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.055, 0.065, 0.07, 0.88)
	box.content_margin_left = 20
	box.content_margin_right = 20
	box.content_margin_top = 16
	box.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", box)
	panel.theme = UiTheme.get_theme()
	ui.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)
	var title := Label.new()
	title.text = "手绘风格 · 独立样板"
	title.add_theme_color_override("font_color", Color("ede8d9"))
	title.add_theme_font_size_override("font_size", 23)
	column.add_child(title)
	style_picker = OptionButton.new()
	for text_value: String in STYLE_NAMES:
		style_picker.add_item(text_value)
	style_picker.item_selected.connect(set_style)
	column.add_child(style_picker)
	lighting_picker = OptionButton.new()
	for text_value: String in LIGHT_NAMES:
		lighting_picker.add_item(text_value)
	lighting_picker.item_selected.connect(set_lighting)
	column.add_child(lighting_picker)
	var shape_toggle := CheckBox.new()
	shape_toggle.text = "使用专用形体与轮廓（仅水墨 / 木版）"
	shape_toggle.button_pressed = shape_studies_enabled
	shape_toggle.toggled.connect(set_shape_studies_enabled)
	shape_toggle.add_theme_font_size_override("font_size", 14)
	column.add_child(shape_toggle)
	var slider_label := Label.new()
	slider_label.text = "表面笔触强度（仅本场景）"
	slider_label.add_theme_font_size_override("font_size", 16)
	column.add_child(slider_label)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 1
	slider.step = 0.01
	slider.value = brush_strength
	slider.value_changed.connect(set_brush_strength)
	column.add_child(slider)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 15)
	column.add_child(status_label)
	description_label = Label.new()
	description_label.custom_minimum_size = Vector2(330, 0)
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description_label.add_theme_font_size_override("font_size", 14)
	description_label.add_theme_color_override("font_color", Color("c5c8bf"))
	column.add_child(description_label)
	var help := Label.new()
	help.text = "右键拖动：环绕  ·  滚轮：远近\n1—8：风格（4 水墨） · L：光照 · F：手电筒\nR：正面 · F5 / F6 / F7：背面 / 近景 / 俯视\nH：隐藏面板"
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color("aaaeb0"))
	column.add_child(help)

func _refresh_status() -> void:
	if status_label:
		status_label.text = "笔触 %.2f · %s · 仅样板内生效" % [brush_strength, "形体研究" if shape_studies_enabled and style_index in [3, 7] else "材质对照"]
	if description_label:
		description_label.text = ArtistPresets.PRESETS[style_index - 3].description if style_index >= 3 else "原有样板保留；新方向是艺术语言实验，不是名画复刻。"

func capture_suite() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("风格截图需要图形渲染模式。")
		get_tree().quit(1)
		return
	for i in 24:
		await get_tree().process_frame
	get_tree().root.mode = Window.MODE_WINDOWED
	get_tree().root.size = Vector2i(1600, 900)
	get_tree().root.content_scale_factor = 1
	ui.visible = false
	var artist_capture := "--artist-capture" in OS.get_cmdline_user_args()
	var directory := CapturePaths.ensure_dir("artist_exploration" if artist_capture else "painterly_lab")
	for style in range(3 if artist_capture else 0, STYLE_NAMES.size() if artist_capture else 3):
		set_style(style)
		set_lighting(0)
		for view in 4:
			set_view(view)
			for frame in 5:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(directory.path_join("style_%d_view_%d.png" % [style, view]))
		if artist_capture:
			set_view(0)
			for light in [1, 2]:
				set_lighting(light)
				for frame in 6:
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(directory.path_join("style_%d_light_%d.png" % [style, light]))
	set_style(1)
	set_view(0)
	if artist_capture:
		for style in [3, 7]:
			set_style(style)
			set_lighting(0)
			set_shape_studies_enabled(false)
			for frame in 5:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(directory.path_join("style_%d_shapes_off.png" % style))
		set_shape_studies_enabled(true)
		set_style(1)
	for light in [1, 2]:
		set_lighting(light)
		for frame in 6:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(directory.path_join("style_1_light_%d.png" % light))
	set_lighting(0)
	ui.visible = true
	for frame in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(directory.path_join("controls.png"))
	if artist_capture:
		await _capture_comparison(directory)
		await get_tree().process_frame
		await _capture_shape_comparison(directory)
	print("PAINTERLY_CAPTURES: ", directory)
	get_tree().quit()

func _capture_comparison(directory: String) -> void:
	# Native UI gallery of actual renderer captures, not AI-generated mockups.
	ui.visible = false
	var gallery := CanvasLayer.new()
	gallery.layer = 120
	add_child(gallery)
	var canvas := Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.theme = UiTheme.get_theme()
	gallery.add_child(canvas)
	var background := ColorRect.new()
	background.color = Color("171d22")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(background)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 16)
	grid.position = Vector2(18, 18)
	canvas.add_child(grid)
	var logical_size := get_viewport().get_visible_rect().size
	var tile_width := (logical_size.x - 60) / 3
	var tile_height := (logical_size.y - 70) / 2
	var baseline := directory.path_join("comparison_baseline.png")
	# controls.png contains the UI; capture an unobstructed retained gouache view.
	gallery.visible = false
	set_style(1)
	set_lighting(0)
	set_view(0)
	for frame in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(baseline)
	gallery.visible = true
	for style in [1, 3, 4, 5, 6, 7]:
		var tile := VBoxContainer.new()
		grid.add_child(tile)
		var label := Label.new()
		label.text = STYLE_NAMES[style]
		label.add_theme_font_size_override("font_size", 17)
		label.add_theme_color_override("font_color", Color("eee9db"))
		tile.add_child(label)
		var texture_rect := TextureRect.new()
		texture_rect.custom_minimum_size = Vector2(tile_width, tile_height - 28)
		texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var path := baseline if style == 1 else directory.path_join("style_%d_view_0.png" % style)
		texture_rect.texture = ImageTexture.create_from_image(Image.load_from_file(path))
		tile.add_child(texture_rect)
	for frame in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(directory.path_join("comparison.png"))
	gallery.queue_free()

func _capture_shape_comparison(directory: String) -> void:
	ui.visible = false
	var gallery := CanvasLayer.new()
	gallery.layer = 120
	add_child(gallery)
	var background := ColorRect.new()
	background.color = Color("171d22")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gallery.add_child(background)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.position = Vector2(20, 20)
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	grid.theme = UiTheme.get_theme()
	gallery.add_child(grid)
	var logical_size := get_viewport().get_visible_rect().size
	for style in [3, 7]:
		for enabled in [false, true]:
			var tile := VBoxContainer.new()
			grid.add_child(tile)
			var label := Label.new()
			label.text = ("水墨" if style == 3 else "木版") + (" · 专用形体 + 勾线" if enabled else " · 原模型，仅材质（对照）")
			label.add_theme_font_size_override("font_size", 18)
			tile.add_child(label)
			var picture := TextureRect.new()
			picture.custom_minimum_size = Vector2((logical_size.x - 56) / 2, (logical_size.y - 100) / 2)
			picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			var filename := "style_%d_view_0.png" % style if enabled else "style_%d_shapes_off.png" % style
			picture.texture = ImageTexture.create_from_image(Image.load_from_file(directory.path_join(filename)))
			tile.add_child(picture)
	for frame in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(directory.path_join("shape_comparison.png"))
	gallery.queue_free()
