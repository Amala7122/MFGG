extends Node3D
## 统一天气入口的独立降雪层；不会改动雨层，雨雪可以同时发射。
const SnowShader = preload("res://shaders/weather_snow_flake.gdshader")

var _particles: GPUParticles3D
var _process_material: ParticleProcessMaterial
var _draw_material: ShaderMaterial

func _ready() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "Snowflakes"
	_particles.amount = 2200
	_particles.amount_ratio = 0.0
	_particles.lifetime = 4.5
	_particles.local_coords = false
	_particles.emitting = false
	_particles.visibility_aabb = AABB(Vector3(-25, -22, -25), Vector3(50, 48, 50))
	_particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	_process_material = ParticleProcessMaterial.new()
	_process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_process_material.emission_box_extents = Vector3(18.0, 1.5, 18.0)
	_process_material.direction = Vector3.DOWN
	_process_material.spread = 25.0
	_process_material.initial_velocity_min = 2.0
	_process_material.initial_velocity_max = 3.3
	_process_material.gravity = Vector3(0.0, -0.45, 0.0)
	_process_material.scale_min = 0.65
	_process_material.scale_max = 1.6
	_particles.process_material = _process_material
	_draw_material = ShaderMaterial.new()
	_draw_material.shader = SnowShader
	var quad := QuadMesh.new()
	quad.size = Vector2(0.10, 0.10)
	quad.material = _draw_material
	_particles.draw_pass_1 = quad
	add_child(_particles)

func set_weather(level: float, wind: Vector2, daylight: float) -> void:
	if _particles == null:
		return
	var amount := clampf(level, 0.0, 1.0)
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		_particles.global_position = camera.global_position + Vector3.UP * 8.0
	_particles.amount_ratio = amount
	_particles.emitting = amount > 0.005
	_process_material.direction = Vector3(wind.x * 0.35, -1.0, wind.y * 0.35).normalized()
	_process_material.gravity = Vector3(wind.x * 1.6, -0.45, wind.y * 1.6)
	_draw_material.set_shader_parameter("daylight", daylight)
