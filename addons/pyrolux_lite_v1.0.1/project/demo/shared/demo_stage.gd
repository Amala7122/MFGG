extends Node3D
## Demo stage built from code: dusk sky with glow, a moon light, the ground and simple
## props (crates, barrels, logs, rocks, a hut, trees). Only used by the demo scenes.

const GROUND_SHADER: Shader = preload("res://demo/shared/demo_ground.gdshader")

var environment: Environment
var sun: DirectionalLight3D
var sky_mat: ProceduralSkyMaterial
var props: Node3D
var _mats: Dictionary = {}


func _ready() -> void:
	_build_environment()
	_build_ground()
	props = Node3D.new()
	props.name = "Props"
	add_child(props)


func _build_environment() -> void:
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.02, 0.03, 0.08)
	sky_mat.sky_horizon_color = Color(0.13, 0.12, 0.2)
	sky_mat.ground_horizon_color = Color(0.07, 0.07, 0.1)
	sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.03)
	sky_mat.sun_angle_max = 1.0
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.7
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.0
	environment.glow_enabled = true
	environment.glow_intensity = 0.55
	environment.glow_bloom = 0.0
	environment.glow_hdr_threshold = 0.9
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	environment.set_glow_level(1, 0.6)
	environment.set_glow_level(2, 0.8)
	environment.set_glow_level(3, 0.6)
	environment.set_glow_level(4, 0.2)
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.07, 0.075, 0.12)
	environment.fog_density = 0.004
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = environment
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.light_color = Color(0.55, 0.62, 0.85)
	sun.light_energy = 0.35
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-38.0, -30.0, 0.0)
	add_child(sun)


## Switches between the night look (default) and a daytime look.
func set_daylight(on: bool) -> void:
	if on:
		sky_mat.sky_top_color = Color(0.25, 0.42, 0.7)
		sky_mat.sky_horizon_color = Color(0.68, 0.72, 0.78)
		sky_mat.ground_horizon_color = Color(0.45, 0.43, 0.4)
		sky_mat.ground_bottom_color = Color(0.2, 0.19, 0.18)
		sun.light_color = Color(1.0, 0.95, 0.85)
		sun.light_energy = 1.3
		environment.ambient_light_energy = 1.0
		environment.fog_light_color = Color(0.6, 0.66, 0.74)
		environment.glow_hdr_threshold = 1.2
	else:
		sky_mat.sky_top_color = Color(0.02, 0.03, 0.08)
		sky_mat.sky_horizon_color = Color(0.13, 0.12, 0.2)
		sky_mat.ground_horizon_color = Color(0.07, 0.07, 0.1)
		sky_mat.ground_bottom_color = Color(0.02, 0.02, 0.03)
		sun.light_color = Color(0.55, 0.62, 0.85)
		sun.light_energy = 0.35
		environment.ambient_light_energy = 0.7
		environment.fog_light_color = Color(0.07, 0.075, 0.12)
		environment.glow_hdr_threshold = 0.9


func _build_ground() -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var pm: PlaneMesh = PlaneMesh.new()
	pm.size = Vector2(160.0, 160.0)
	mi.mesh = pm
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = GROUND_SHADER
	mi.material_override = m
	mi.name = "Ground"
	add_child(mi)


func clear_props() -> void:
	for c in props.get_children():
		props.remove_child(c)
		c.queue_free()


func mat(color: Color, rough: float = 0.85) -> StandardMaterial3D:
	var key: String = "%s_%.2f" % [color.to_html(), rough]
	if _mats.has(key):
		return _mats[key]
	var m: StandardMaterial3D = StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	_mats[key] = m
	return m


func add_mesh(mesh: Mesh, pos: Vector3, material: Material, rot_deg: Vector3 = Vector3.ZERO, parent: Node3D = null) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation_degrees = rot_deg
	(parent if parent else props).add_child(mi)
	return mi


func crate(pos: Vector3, s: float = 1.0, parent: Node3D = null) -> MeshInstance3D:
	var b: BoxMesh = BoxMesh.new()
	b.size = Vector3.ONE * s
	b.subdivide_width = 3
	b.subdivide_height = 3
	b.subdivide_depth = 3
	return add_mesh(b, pos + Vector3(0.0, s * 0.5, 0.0), mat(Color(0.48, 0.33, 0.2)), Vector3(0.0, fmod(pos.x * 37.0, 30.0), 0.0), parent)


func barrel(pos: Vector3, parent: Node3D = null) -> MeshInstance3D:
	var c: CylinderMesh = CylinderMesh.new()
	c.top_radius = 0.38
	c.bottom_radius = 0.38
	c.height = 1.0
	return add_mesh(c, pos + Vector3(0.0, 0.5, 0.0), mat(Color(0.55, 0.16, 0.1), 0.5), Vector3.ZERO, parent)


func rock(pos: Vector3, s: float = 1.0, parent: Node3D = null) -> MeshInstance3D:
	var sm: SphereMesh = SphereMesh.new()
	sm.radius = 0.5 * s
	sm.height = 0.6 * s
	sm.radial_segments = 9
	sm.rings = 5
	return add_mesh(sm, pos + Vector3(0.0, 0.12 * s, 0.0), mat(Color(0.3, 0.29, 0.28)), Vector3(0.0, pos.x * 40.0, 0.0), parent)


func campfire_base(pos: Vector3, parent: Node3D = null) -> void:
	for i in 5:
		var a: float = TAU * float(i) / 5.0
		var c: CylinderMesh = CylinderMesh.new()
		c.top_radius = 0.07
		c.bottom_radius = 0.08
		c.height = 1.0
		add_mesh(c, pos + Vector3(cos(a) * 0.25, 0.12, sin(a) * 0.25), mat(Color(0.25, 0.16, 0.1)), Vector3(70.0, -rad_to_deg(a) + 90.0, 0.0), parent)
	for i in 9:
		var a: float = TAU * float(i) / 9.0
		rock(pos + Vector3(cos(a) * 0.62, 0.0, sin(a) * 0.62), 0.32, parent)


func hut(pos: Vector3, parent: Node3D = null) -> Node3D:
	var root: Node3D = Node3D.new()
	root.position = pos
	(parent if parent else props).add_child(root)
	var walls: BoxMesh = BoxMesh.new()
	walls.size = Vector3(3.2, 2.2, 2.6)
	add_mesh(walls, Vector3(0.0, 1.1, 0.0), mat(Color(0.42, 0.36, 0.3)), Vector3.ZERO, root)
	var roof: PrismMesh = PrismMesh.new()
	roof.size = Vector3(3.6, 1.2, 3.0)
	add_mesh(roof, Vector3(0.0, 2.8, 0.0), mat(Color(0.3, 0.18, 0.13)), Vector3.ZERO, root)
	var door: BoxMesh = BoxMesh.new()
	door.size = Vector3(0.7, 1.3, 0.05)
	add_mesh(door, Vector3(0.0, 0.65, 1.31), mat(Color(0.12, 0.08, 0.06)), Vector3.ZERO, root)
	return root


func tree(pos: Vector3, s: float = 1.0, parent: Node3D = null) -> void:
	var trunk: CylinderMesh = CylinderMesh.new()
	trunk.top_radius = 0.12 * s
	trunk.bottom_radius = 0.18 * s
	trunk.height = 1.6 * s
	add_mesh(trunk, pos + Vector3(0.0, 0.8 * s, 0.0), mat(Color(0.25, 0.18, 0.12)), Vector3.ZERO, parent)
	var crown: CylinderMesh = CylinderMesh.new()
	crown.top_radius = 0.0
	crown.bottom_radius = 1.0 * s
	crown.height = 2.6 * s
	add_mesh(crown, pos + Vector3(0.0, 2.6 * s, 0.0), mat(Color(0.12, 0.22, 0.12)), Vector3.ZERO, parent)
