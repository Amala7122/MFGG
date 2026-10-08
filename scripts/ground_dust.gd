extends Node3D
## 脚步与砸地扬尘：不发光，粒子留在世界坐标，随场景暂停和销毁。

const MAX_ACTIVE := 48
const Config := preload("res://scripts/game_config.gd")
static var _texture: ImageTexture
var _particles: CPUParticles3D
var _age := 0.0
var _duration := 0.8


static func spawn(parent: Node, point: Vector3, normal: Vector3, strength: float) -> Node3D:
	if not is_instance_valid(parent) or not parent.is_inside_tree() or parent.get_tree().paused:
		return null
	var existing := parent.get_tree().get_nodes_in_group("ground_dust")
	var limit := clampi(Config.get_int("ground_feedback.max_dust_effects", MAX_ACTIVE), 0, MAX_ACTIVE)
	if existing.size() >= limit:
		return null
	var fx := load("res://scripts/ground_dust.gd").new() as Node3D
	fx.name = "GroundDust"
	parent.add_child(fx)
	fx.global_position = point + normal * 0.035
	fx._build(normal, clampf(strength, 0.25, 3.0))
	return fx


func _ready() -> void:
	add_to_group("ground_dust")


func _build(normal: Vector3, strength: float) -> void:
	_particles = CPUParticles3D.new()
	_particles.name = "Dust"
	_particles.emitting = false
	_particles.one_shot = true
	_particles.explosiveness = 1.0
	_particles.amount = clampi(roundi(12.0 * strength), 6, 36)
	_particles.lifetime = 0.6 + strength * 0.1
	_duration = _particles.lifetime + 0.15
	_particles.local_coords = false
	_particles.direction = normal.normalized()
	_particles.spread = 72.0
	_particles.gravity = Vector3(0, -0.45, 0)
	_particles.initial_velocity_min = 0.3 * strength
	_particles.initial_velocity_max = 1.0 * strength
	_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_particles.emission_sphere_radius = 0.12 * strength
	_particles.scale_amount_min = 0.18 * strength
	_particles.scale_amount_max = 0.34 * strength
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.16, 0.6, 1.0])
	fade.colors = PackedColorArray([
		Color(0.67, 0.60, 0.46, 0.0), Color(0.67, 0.60, 0.46, 0.52),
		Color(0.71, 0.65, 0.53, 0.28), Color(0.74, 0.68, 0.58, 0.0)])
	_particles.color_ramp = fade
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 1.0
	material.albedo_texture = _dust_texture()
	var mesh := QuadMesh.new()
	mesh.material = material
	_particles.mesh = mesh
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_particles)
	_particles.emitting = true


static func _dust_texture() -> ImageTexture:
	if _texture == null:
		var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		for y in range(32):
			for x in range(32):
				var distance := Vector2(x - 15.5, y - 15.5).length() / 15.5
				image.set_pixel(x, y, Color(1, 1, 1, pow(maxf(1.0 - distance, 0.0), 1.5)))
		_texture = ImageTexture.create_from_image(image)
	return _texture


func _process(delta: float) -> void:
	_age += delta
	if _age >= _duration:
		queue_free()
