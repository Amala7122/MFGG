extends Node3D
## 只显示真实吸收反馈；预览也复用 trigger/sample，不参与防御数值、事件或音频。
const Settings := preload("res://scripts/player_support_settings.gd")
const ShieldShader := preload("res://shaders/shield_impact.gdshader")
var parameters: Dictionary = {}
var mesh: MeshInstance3D
var material: ShaderMaterial
var active := false
var elapsed := 0.0
var peak_intensity := 1.0
var trigger_count := 0

func _ready() -> void:
	mesh = MeshInstance3D.new()
	mesh.name = "EnergyShieldMesh"
	var sphere := SphereMesh.new()
	sphere.radial_segments = 36
	sphere.rings = 18
	mesh.mesh = sphere
	material = ShaderMaterial.new()
	material.shader = ShieldShader
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)
	configure(Settings.load_values())
	cancel()

func configure(values: Dictionary) -> void:
	var valid := Settings.validate(values)
	if valid.is_empty():
		return
	parameters = valid
	var sphere := mesh.mesh as SphereMesh
	sphere.radius = float(parameters.shield_radius)
	sphere.height = sphere.radius * 2.0
	mesh.position.y = float(parameters.shield_center_y)
	material.set_shader_parameter("hex_scale", parameters.shield_hex_scale)
	material.set_shader_parameter("hex_line_thickness", parameters.shield_line_thickness)
	material.set_shader_parameter("fresnel_power", parameters.shield_fresnel)
	material.set_shader_parameter("shield_base_color", Color(0.38, 0.88, 1.0, parameters.shield_base_alpha))
	material.set_shader_parameter("glow_multiplier", parameters.shield_glow)
	if float(parameters.shield_enabled) < 0.5:
		cancel()
	elif active:
		sample(elapsed)

func trigger(world_direction: Vector3, absorbed_raw: float) -> void:
	if parameters.is_empty() or parameters.shield_enabled < 0.5 or absorbed_raw <= 0.0:
		return
	var direction := world_direction.normalized()
	if direction.is_zero_approx():
		direction = -global_basis.z.normalized()
	var local := (mesh.global_basis.inverse() * direction).normalized()
	material.set_shader_parameter("hit_direction_local", local)
	peak_intensity = clampf(1.0 + absorbed_raw * 0.03, 1.0, 2.5)
	active = true
	trigger_count += 1
	sample(0.0)

func _process(delta: float) -> void:
	advance(delta)

func advance(delta: float) -> void:
	if active:
		sample(elapsed + maxf(delta, 0.0))

func sample(time: float) -> void:
	elapsed = maxf(time, 0.0)
	var progress := clampf(elapsed / float(parameters.shield_duration), 0.0, 1.0)
	active = progress < 1.0 and parameters.shield_enabled >= 0.5
	mesh.visible = active
	material.set_shader_parameter("shield_alpha", (1.0 - pow(progress, 1.5)) * float(parameters.shield_alpha) if active else 0.0)
	material.set_shader_parameter("hit_intensity", peak_intensity * (1.0 - progress) if active else 0.0)
	material.set_shader_parameter("ripple_progress", elapsed * float(parameters.shield_ripple_speed))

func cancel() -> void:
	active = false
	elapsed = 0.0
	if is_instance_valid(mesh):
		mesh.visible = false
	if is_instance_valid(material):
		material.set_shader_parameter("shield_alpha", 0.0)
		material.set_shader_parameter("hit_intensity", 0.0)
