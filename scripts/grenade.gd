class_name Grenade
extends RigidBody3D
## 手雷（E 键）：抛出后按引信起爆，对范围内敌人造成伤害并击退。
## 几何、材质、指示光全部代码构建，不依赖任何美术资源。
##
## 物理层：layer 4（值 8），只与世界/玩家/敌人碰撞，不会被子弹击飞。

const AudioUtil := preload("res://scripts/audio_manager.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

## 以下四项在 _ready() 里从 data/game_config.json 的 abilities.grenade 段读入。
## 这里的 DEFAULT_* 只是兜底值：配置缺失/损坏时退回它们，手感与改动前完全一致。
const DEFAULT_FUSE_SECONDS := 1.7
const DEFAULT_BLAST_RADIUS := 5.5
const DEFAULT_BLAST_DAMAGE := 95.0
const DEFAULT_PUSH_FORCE := 12.0

var fuse_seconds := DEFAULT_FUSE_SECONDS
var blast_radius := DEFAULT_BLAST_RADIUS
var blast_damage := DEFAULT_BLAST_DAMAGE
var push_force := DEFAULT_PUSH_FORCE
const INDICATOR_SAFE := Color(0.32, 0.95, 0.42, 1.0)
const INDICATOR_DANGER := Color(1.0, 0.24, 0.12, 1.0)

var _fuse := DEFAULT_FUSE_SECONDS
var _elapsed := 0.0
var _exploded := false
var _material: StandardMaterial3D
var _light: OmniLight3D


func _ready() -> void:
	fuse_seconds = maxf(
		ConfigUtil.get_float("abilities.grenade.fuse", DEFAULT_FUSE_SECONDS), 0.05
	)
	blast_radius = maxf(ConfigUtil.get_float("abilities.grenade.radius", DEFAULT_BLAST_RADIUS), 0.5)
	blast_damage = maxf(ConfigUtil.get_float("abilities.grenade.damage", DEFAULT_BLAST_DAMAGE), 0.0)
	push_force = maxf(ConfigUtil.get_float("abilities.grenade.push", DEFAULT_PUSH_FORCE), 0.0)
	_fuse = fuse_seconds
	mass = 0.45
	gravity_scale = 1.15
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 4
	collision_layer = 8
	collision_mask = 7
	_build_body()
	_build_collision()


## 从 from 处沿 direction 抛出，speed 为初速（m/s）。
func launch(from: Vector3, direction: Vector3, speed: float = 17.0) -> void:
	global_position = from
	var safe_direction := direction.normalized() if not direction.is_zero_approx() else Vector3.FORWARD
	linear_velocity = safe_direction * speed + Vector3.UP * 2.6
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	angular_velocity = Vector3(
		rng.randf_range(-8.0, 8.0), rng.randf_range(-8.0, 8.0), rng.randf_range(-8.0, 8.0)
	)


func _build_body() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.26, 0.3, 0.26, 1.0)
	_material.metallic = 0.35
	_material.roughness = 0.55
	_material.emission_enabled = true
	_material.emission = INDICATOR_SAFE
	_material.emission_energy_multiplier = 1.0

	var mesh := SphereMesh.new()
	mesh.radius = 0.13
	mesh.height = 0.26
	mesh.radial_segments = 12
	mesh.rings = 6
	mesh.material = _material

	var body_mesh := MeshInstance3D.new()
	body_mesh.mesh = mesh
	add_child(body_mesh)

	_light = OmniLight3D.new()
	_light.light_color = INDICATOR_SAFE
	_light.light_energy = 0.8
	_light.omni_range = 3.0
	_light.shadow_enabled = false
	add_child(_light)


func _build_collision() -> void:
	var shape := SphereShape3D.new()
	shape.radius = 0.13
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)


func _physics_process(delta: float) -> void:
	if _exploded:
		return
	_elapsed += delta
	_fuse -= delta
	var progress := clampf(_elapsed / fuse_seconds, 0.0, 1.0)
	var blink_speed := lerpf(9.0, 46.0, progress)
	var blink := 0.5 + 0.5 * sin(_elapsed * blink_speed)
	var indicator := INDICATOR_SAFE.lerp(INDICATOR_DANGER, progress)
	if _material:
		_material.emission = indicator
		_material.emission_energy_multiplier = 1.0 + blink * (2.5 + progress * 9.0)
	if _light:
		_light.light_color = indicator
		_light.light_energy = 0.8 + blink * (1.6 + progress * 5.0)
	if _fuse <= 0.0:
		explode()


func explode() -> void:
	if _exploded:
		return
	_exploded = true
	# 定位播放，靠近才响 —— 手雷的爆炸必须有明确的方向感。
	AudioUtil.play_at("explosion", global_position, 0.0)
	var scene := get_tree().current_scene
	# 手雷会被墙体遮挡，因此要求视线可见才结算伤害。
	CombatFX.apply_radial_damage(
		self, global_position, blast_radius, blast_damage, push_force, true
	)
	if scene:
		CombatFX.spawn_impact(
			scene, global_position, Vector3.UP, Color(1.0, 0.62, 0.18, 1.0), 3.2
		)
		var flash := BlastFlash.new()
		scene.add_child(flash)
		flash.global_position = global_position
		flash.trigger(Color(1.0, 0.58, 0.16, 1.0), blast_radius * 0.72, 0.34)
	queue_free()
