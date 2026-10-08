class_name ShellCasing
extends Node3D
## 程序化弹壳抛射系统：开火时从枪身抛壳窗喷出，受重力旋转下落，与地面轻脆碰撞弹跳。
## 纯代码构建黄铜圆柱网格，零外部资源依赖。

const AudioUtil := preload("res://scripts/audio_manager.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")

var _velocity := Vector3.ZERO
var _angular_velocity := Vector3.ZERO
var _settled := false
var _elapsed := 0.0
var _bounces := 0
var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D


func _ready() -> void:
	_build_mesh()


func _build_mesh() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.016
	mesh.bottom_radius = 0.016
	mesh.height = 0.075
	mesh.radial_segments = 8

	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.88, 0.72, 0.28, 1.0)
	_material.metallic = 0.95
	_material.roughness = 0.25
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)


func launch(start_pos: Vector3, initial_vel: Vector3, is_large: bool = false) -> void:
	global_position = start_pos
	_velocity = initial_vel
	var scale_mult := 1.45 if is_large else 1.0
	scale = Vector3.ONE * scale_mult
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_angular_velocity = Vector3(
		rng.randf_range(-22.0, 22.0),
		rng.randf_range(-25.0, 25.0),
		rng.randf_range(-22.0, 22.0)
	)


func _process(delta: float) -> void:
	_elapsed += delta
	if _settled:
		if _elapsed >= 3.2:
			var fade := clampf((4.2 - _elapsed) / 1.0, 0.0, 1.0)
			if _material:
				_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				var col := _material.albedo_color
				col.a = fade
				_material.albedo_color = col
			if _elapsed >= 4.2:
				queue_free()
		return

	_velocity.y -= 13.5 * delta
	global_position += _velocity * delta
	rotate_x(_angular_velocity.x * delta)
	rotate_y(_angular_velocity.y * delta)
	rotate_z(_angular_velocity.z * delta)

	var ground_y := TerrainFieldUtil.height_at(global_position.x, global_position.z)
	if global_position.y <= ground_y + 0.02:
		global_position.y = ground_y + 0.02
		if _velocity.y < -0.9 and _bounces < 2:
			_bounces += 1
			_velocity.y = -_velocity.y * 0.35
			_velocity.x *= 0.55
			_velocity.z *= 0.55
			_angular_velocity *= 0.45
			AudioUtil.play_at("casing_clink", global_position, -20.0, randf_range(0.95, 1.15))
		else:
			_settled = true
			_velocity = Vector3.ZERO
			_angular_velocity = Vector3.ZERO
			rotation.x = PI * 0.5
			rotation.z = randf() * TAU
