class_name ImpactSpark
extends Node3D
## 命中火花：纯代码构建的碎片 + 瞬时闪光 + 短命点光，不依赖任何贴图/模型资源。
##
## 【池化改造】所有网格与材质只在 _build() 里创建一次，trigger() 只重置
## 位置/速度/配色。改造前每次命中都要新建 8 个碎片网格 + 5 个材质 + 1 个点光，
## 瞬发命中下每秒数百次 —— 这是全项目最大的单项开销。
##
## 刻意不使用 GPUParticles3D：避免运行时构造 ParticleProcessMaterial 的参数风险，
## 同时保证在任何渲染后端下表现一致。

const PoolUtil := preload("res://scripts/object_pool.gd")

const POOL_KEY := "impact_spark"
const FRAGMENT_COUNT := 8
const LIFETIME := 0.42
const FRAGMENT_GRAVITY := 12.0
const BASE_EMISSION := 7.0
const BASE_FLASH_ENERGY := 9.0
const BASE_LIGHT_ENERGY := 4.0

var _fragments: Array[MeshInstance3D] = []
var _velocities: Array[Vector3] = []
var _fragment_material: StandardMaterial3D
var _flash_material: StandardMaterial3D
var _flash: MeshInstance3D
var _light: OmniLight3D
var _rng := RandomNumberGenerator.new()
var _elapsed := 0.0
var _scale_factor := 1.0
var _active := false


func _ready() -> void:
	if _fragments.is_empty():
		_build()


## 只跑一次：把 8 个碎片、闪光面片、点光以及全部材质建好。
## 尺寸统一按 1.0 构建，实际大小通过节点 scale 与光照参数按 _scale_factor 缩放，
## 这样同一个实例可以服务不同体量的命中。
func _build() -> void:
	_rng.randomize()

	_fragment_material = StandardMaterial3D.new()
	_fragment_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fragment_material.albedo_color = Color.WHITE
	_fragment_material.emission_enabled = true
	_fragment_material.emission_energy_multiplier = BASE_EMISSION

	var fragment_mesh := SphereMesh.new()
	fragment_mesh.radius = 0.03
	fragment_mesh.height = 0.06
	fragment_mesh.radial_segments = 6
	fragment_mesh.rings = 3

	for _index in range(FRAGMENT_COUNT):
		var fragment := MeshInstance3D.new()
		fragment.mesh = fragment_mesh
		fragment.material_override = _fragment_material
		add_child(fragment)
		_fragments.append(fragment)
		_velocities.append(Vector3.ZERO)

	_flash_material = StandardMaterial3D.new()
	_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_flash_material.emission_enabled = true

	var flash_mesh := QuadMesh.new()
	flash_mesh.size = Vector2(0.34, 0.34)
	flash_mesh.material = _flash_material
	_flash = MeshInstance3D.new()
	_flash.mesh = flash_mesh
	add_child(_flash)

	_light = OmniLight3D.new()
	_light.shadow_enabled = false
	add_child(_light)


## 在世界坐标处炸开一簇火花，normal 为命中面法线（决定碎片喷射方向）。
## 可重复调用：每次都会把状态完整重置，因此同一个实例能反复使用。
func trigger(normal: Vector3, color: Color, scale_multiplier: float = 1.0) -> void:
	if _fragments.is_empty():
		_build()
	_scale_factor = maxf(scale_multiplier, 0.2)
	_elapsed = 0.0
	_active = true
	visible = true

	var safe_normal := Vector3.UP if normal.is_zero_approx() else normal.normalized()
	var reference := Vector3.UP if absf(safe_normal.dot(Vector3.UP)) < 0.92 else Vector3.FORWARD
	var tangent := safe_normal.cross(reference).normalized()
	var bitangent := safe_normal.cross(tangent).normalized()

	_fragment_material.emission = color
	_fragment_material.emission_energy_multiplier = BASE_EMISSION
	for index in range(_fragments.size()):
		var fragment := _fragments[index]
		fragment.position = Vector3.ZERO
		fragment.scale = Vector3.ONE * _scale_factor
		var direction := (
			safe_normal * _rng.randf_range(0.45, 1.0)
			+ tangent * _rng.randf_range(-0.9, 0.9)
			+ bitangent * _rng.randf_range(-0.9, 0.9)
		).normalized()
		_velocities[index] = direction * _rng.randf_range(2.8, 7.0) * _scale_factor

	# 面向命中法线的加色光斑，给火花一个"起爆"亮度。
	_flash_material.albedo_color = Color(color.r, color.g, color.b, 0.9)
	_flash_material.emission = color
	_flash_material.emission_energy_multiplier = BASE_FLASH_ENERGY
	_flash.position = safe_normal * 0.05
	_flash.scale = Vector3.ONE * _scale_factor
	# 法线接近竖直时必须换一个 up，否则 look_at 会因方向与 up 平行而报错。
	var safe_up := Vector3.UP if absf(safe_normal.dot(Vector3.UP)) < 0.92 else Vector3.FORWARD
	_flash.look_at(_flash.global_position + safe_normal, safe_up)

	_light.light_color = color
	_light.light_energy = BASE_LIGHT_ENERGY * _scale_factor
	_light.omni_range = 3.0 * _scale_factor
	_light.position = safe_normal * 0.12


func _process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta
	var progress := _elapsed / LIFETIME
	if progress >= 1.0:
		_active = false
		PoolUtil.release(POOL_KEY, self)
		return
	var fade := 1.0 - progress
	var shrink := maxf(1.0 - progress * 0.85, 0.05) * _scale_factor
	var damping := maxf(1.0 - 5.0 * delta, 0.0)

	for index in range(_fragments.size()):
		var fragment := _fragments[index]
		var velocity := _velocities[index]
		velocity.y -= FRAGMENT_GRAVITY * delta
		velocity *= damping
		_velocities[index] = velocity
		fragment.position += velocity * delta
		fragment.scale = Vector3.ONE * shrink

	_fragment_material.emission_energy_multiplier = BASE_EMISSION * fade
	var flash_color := _flash_material.albedo_color
	flash_color.a = 0.9 * fade * fade
	_flash_material.albedo_color = flash_color
	_flash_material.emission_energy_multiplier = BASE_FLASH_ENERGY * fade * fade
	_flash.scale = Vector3.ONE * (_scale_factor * (1.0 + progress * 0.9))
	_light.light_energy = BASE_LIGHT_ENERGY * _scale_factor * fade
