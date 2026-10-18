class_name Grenade
extends RigidBody3D
## 手雷（E 键）：接触存活敌人立即起爆；未碰敌时保留引信与环境反弹。
## 几何、材质、指示光全部代码构建，不依赖任何美术资源。
##
## 物理层：layer 4（值 8），只与世界/玩家/敌人碰撞，不会被子弹击飞。

const AudioUtil := preload("res://scripts/audio_manager.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const HealthUtil := preload("res://scripts/health_util.gd")

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
var stagger_seconds := 0.6
var boss_stagger_seconds := 0.25
const INDICATOR_SAFE := Color(0.32, 0.95, 0.42, 1.0)
const INDICATOR_DANGER := Color(1.0, 0.24, 0.12, 1.0)

var _fuse := DEFAULT_FUSE_SECONDS
var _elapsed := 0.0
var _exploded := false
var _detonation_pending := false
var _direct_target: WeakRef
var _previous_position := Vector3.ZERO
var _contact_shape: SphereShape3D
var _material: StandardMaterial3D
var _light: OmniLight3D


func _ready() -> void:
	fuse_seconds = maxf(
		ConfigUtil.get_float("abilities.grenade.fuse", DEFAULT_FUSE_SECONDS), 0.05
	)
	blast_radius = maxf(ConfigUtil.get_float("abilities.grenade.radius", DEFAULT_BLAST_RADIUS), 0.5)
	blast_damage = maxf(ConfigUtil.get_float("abilities.grenade.damage", DEFAULT_BLAST_DAMAGE), 0.0)
	push_force = maxf(ConfigUtil.get_float("abilities.grenade.push", DEFAULT_PUSH_FORCE), 0.0)
	stagger_seconds = clampf(ConfigUtil.get_float("abilities.grenade.stagger_seconds", 0.6), 0.05, 2.0)
	boss_stagger_seconds = clampf(ConfigUtil.get_float("abilities.grenade.boss_stagger_seconds", 0.25), 0.05, 0.8)
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
	_previous_position = global_position
	body_entered.connect(_on_body_entered)


## 从 from 处沿 direction 抛出，speed 为初速（m/s）。
func launch(from: Vector3, direction: Vector3, speed: float = 17.0) -> void:
	global_position = from
	_previous_position = from
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
	_contact_shape = shape
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)


func _physics_process(delta: float) -> void:
	if _exploded or _detonation_pending:
		return
	_check_enemy_contact()
	_previous_position = global_position
	if _detonation_pending:
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


func _enemy_owner(body: Object) -> Node3D:
	var node := body as Node
	while is_instance_valid(node):
		if node.is_in_group("enemies") and node.has_method("take_damage") and HealthUtil.is_alive(node):
			return node as Node3D
		node = node.get_parent()
	return null

func _on_body_entered(body: Node) -> void:
	var enemy := _enemy_owner(body)
	if enemy != null:
		_request_detonation(enemy)

func _request_detonation(enemy: Node3D) -> void:
	if _exploded or _detonation_pending:
		return
	_detonation_pending = true
	_direct_target = weakref(enemy)
	# 接触通知可能处于物理查询刷新中；在该步末尾安全结算死亡、碎片和反馈。
	call_deferred("explode")

func _check_enemy_contact() -> void:
	var space := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _contact_shape
	query.collision_mask = 5 # 世界阻挡射线；敌人身体及其子级盾壳都可命中。
	query.exclude = [get_rid()]
	query.collide_with_areas = true
	query.transform = Transform3D(Basis.IDENTITY, _previous_position)
	query.motion = global_position - _previous_position
	var fraction := space.cast_motion(query)
	if fraction.size() == 2 and fraction[1] < 1.0:
		query.transform.origin += query.motion * minf(fraction[1] + 0.001, 1.0)
	else:
		query.transform.origin = global_position
	query.motion = Vector3.ZERO
	for hit: Dictionary in space.intersect_shape(query, 16):
		var enemy := _enemy_owner(hit.collider)
		if enemy != null:
			# 在实际扫掠接触点爆炸，而非已越过薄目标的终点。
			global_position = query.transform.origin
			_request_detonation(enemy)
			return

func get_grenade_explosion_id() -> int:
	return get_instance_id()


func explode(direct_target: Node3D = null) -> void:
	if _exploded:
		return
	_exploded = true
	if not is_instance_valid(direct_target) and _direct_target != null:
		direct_target = _direct_target.get_ref() as Node3D
	# 定位播放，靠近才响 —— 手雷的爆炸必须有明确的方向感。
	AudioUtil.play_at("explosion", global_position, 0.0)
	var scene := get_tree().current_scene
	# 手雷会被墙体遮挡，因此要求视线可见才结算伤害。
	CombatFX.apply_radial_damage(
		self, global_position, blast_radius, blast_damage, push_force, true,
		direct_target, stagger_seconds, boss_stagger_seconds
	)
	if scene:
		CombatFX.spawn_impact(
			scene, global_position, Vector3.UP, Color(1.0, 0.62, 0.18, 1.0), 3.2
		)
		CombatFX.spawn_ground_burst(scene, global_position, blast_radius * 0.55, true, blast_radius)
		var flash := BlastFlash.new()
		scene.add_child(flash)
		flash.global_position = global_position
		flash.trigger(Color(1.0, 0.58, 0.16, 1.0), blast_radius * 0.72, 0.34)
	queue_free()
