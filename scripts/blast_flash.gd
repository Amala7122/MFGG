class_name BlastFlash
extends Node3D
## 爆炸闪光：向外扩散的加色球体 + 点光，纯代码构建，生命周期结束自行释放。
## 手雷与震地脉冲共用。

const DEFAULT_LIFETIME := 0.34

var _sphere: MeshInstance3D
var _material: StandardMaterial3D
var _light: OmniLight3D
var _elapsed := 0.0
var _duration := DEFAULT_LIFETIME
var _target_radius := 2.0


## radius 为最终扩散半径；life 为持续时间。
func trigger(color: Color, radius: float, life: float = DEFAULT_LIFETIME) -> void:
	_target_radius = maxf(radius, 0.2)
	_duration = maxf(life, 0.05)

	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 16
	mesh.rings = 8

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = Color(color.r, color.g, color.b, 0.8)
	_material.emission_enabled = true
	_material.emission = color
	_material.emission_energy_multiplier = 7.0
	mesh.material = _material

	_sphere = MeshInstance3D.new()
	_sphere.mesh = mesh
	_sphere.scale = Vector3.ONE * (_target_radius * 0.25)
	add_child(_sphere)

	_light = OmniLight3D.new()
	_light.light_color = color
	_light.light_energy = 9.0
	_light.omni_range = _target_radius * 1.6
	_light.shadow_enabled = false
	add_child(_light)


func _process(delta: float) -> void:
	_elapsed += delta
	var progress := _elapsed / _duration
	if progress >= 1.0:
		queue_free()
		return
	var fade := 1.0 - progress
	var eased := 1.0 - pow(1.0 - progress, 2.0)
	if _sphere:
		_sphere.scale = Vector3.ONE * lerpf(_target_radius * 0.25, _target_radius, eased)
	if _material:
		var color := _material.albedo_color
		color.a = 0.8 * fade * fade
		_material.albedo_color = color
		_material.emission_energy_multiplier = 7.0 * fade
	if _light:
		_light.light_energy = 9.0 * fade * fade
