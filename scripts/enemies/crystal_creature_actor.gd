extends CharacterBody3D
## 新三种昆虫的公共战斗宿主；动作、外形和命名方案仍使用原视觉脚本。
signal died(enemy: Node3D)
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Lifecycle := preload("res://scripts/enemies/enemy_lifecycle.gd")
const HitFlash := preload("res://scripts/enemies/enemy_hit_flash.gd")
const Corpse := preload("res://scripts/enemies/creature_corpse.gd")
const Crowd := preload("res://scripts/prototypes/enemy_crowd.gd")
const Nav := preload("res://scripts/nav_steering.gd")
const Ground := preload("res://scripts/ground_movement.gd")
const Health := preload("res://scripts/health_util.gd")
const Targeting := preload("res://scripts/targeting.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Damage := preload("res://scripts/combat_damage.gd")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const Regions := preload("res://scripts/weapon_hit_regions.gd")
const Reactions := preload("res://scripts/combat_reactions.gd")
const ReactionProfile := preload("res://scripts/combat_reaction_profile.gd")
const SpatialProfile := preload("res://scripts/combat_spatial_profile.gd")
const SpatialQuery := preload("res://scripts/spatial_query.gd")
@export var combat_reaction_profile: ReactionProfile = preload("res://data/combat_reactions/evade_knockback.tres")
@export var combat_spatial_profile: SpatialProfile = preload("res://data/combat_spatial/ground.tres")
@export var ai_enabled := true
enum State { IDLE, APPROACH, AIM, WINDUP, CHARGE, RECOVERY, RETREAT, STAGGER, REACTION, DEAD }
var current_state := State.IDLE
var health := 0.0
var max_health := 0.0
var move_speed := 0.0
var attack_damage := 0.0
var projectile_damage := 0.0
var attack_interval := 0.0
var fire_interval := 0.0
var _armor := 0.0
var _damage_scale := 1.0
var target: Node3D
var visual: Node3D
var state_timer := 0.0
var cooldown := 0.0
var anim_clock := 0.0
var _tuning: Dictionary = {}
var _crowd := Crowd.new()
var _steering := Nav.new()
var _reactions := Reactions.new()
var _regions := Regions.new()
var _collision: CollisionShape3D
var _flash: Node
var _push := Vector3.ZERO
var _hit_label: Label3D


func profile_id() -> String:
	return ""


func visual_scene() -> PackedScene:
	return null


func _ready() -> void:
	_tuning = Tuning.resolve(self, profile_id())
	if _tuning.is_empty():
		queue_free()
		return
	_crowd.setup(self, _tuning, profile_id())
	var source_values := _tuning.duplicate(true)
	var times: Array = []
	for key in ["windup", "release", "recovery", "attack_interval", "turn_duration", "contact_windup", "wall_recovery"]:
		if _tuning.has(key):
			times.append(key)
	var damage_keys: Array = ["attack_damage"]
	if _tuning.has("poison_damage"): damage_keys.append("poison_damage")
	_tuning = _crowd.varied_values(_tuning, ["move_speed", "retreat_speed"] if _tuning.has("retreat_speed") else ["move_speed"], damage_keys, times)
	max_health = p("max_health")
	health = max_health
	move_speed = p("move_speed")
	attack_damage = p("attack_damage")
	projectile_damage = attack_damage
	attack_interval = p("attack_interval")
	fire_interval = attack_interval
	_armor = p("armor")
	anim_clock = _crowd.phase
	add_to_group("enemies")
	collision_layer = 4
	collision_mask = 3
	var dimensions: Vector3 = get_script().get_body_dimensions(_tuning)
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = dimensions
	_collision.shape = box
	add_child(_collision)
	visual = visual_scene().instantiate()
	visual.name = "CreatureVisual"
	var visual_values := _tuning.duplicate(true)
	visual_values.body_size = 1.0 # 基础体型只在战斗根节点应用一次。
	# schema 的边界针对体型1的编辑值。先用已验证基础值构建局部模型，
	# 再注入只供战斗行为使用的世界值，不能把放大后的距离再次当输入校验。
	source_values.body_size = 1.0
	visual.set_meta(&"enemy_tuning", source_values)
	visual.position.y = -dimensions.y * 0.5
	add_child(visual)
	visual.set("values", visual_values)
	visual.set_process(false)
	_steering.setup(self, maxf(dimensions.x, dimensions.z) * 0.5, dimensions.y)
	var radii: Array = []
	if _tuning.has("retreat_exit_range"):
		radii = [p("retreat_exit_range"), (p("retreat_exit_range") + p("attack_range")) * 0.5, p("attack_range") * 0.9]
	_steering.spatial.bind(_tuning, {"can_attack": _spatial_can_attack, "attack_pose": can_attack_from, "stance_radii": radii})
	_flash = HitFlash.new()
	_flash.name = "EnemyHitFlash"
	add_child(_flash)
	_flash.setup(visual, _tuning)
	_hit_label = Label3D.new()
	_hit_label.position.y = dimensions.y * 0.5 + 0.35
	_hit_label.font_size = 24
	_hit_label.pixel_size = 0.005
	_hit_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(_hit_label)
	_update_health()
	_reactions.setup(self, combat_reaction_profile, _collision)
	_setup_species()


static func get_body_dimensions(_values: Dictionary = {}) -> Vector3:
	return Vector3.ONE


func _setup_species() -> void:
	pass


func p(key: String) -> float:
	return float(_tuning[key])


func _physics_process(delta: float) -> void:
	if current_state == State.DEAD:
		return
	_crowd.tick(delta)
	anim_clock += delta * _crowd.gait_multiplier
	state_timer += delta
	cooldown = maxf(0.0, cooldown - delta)
	if ai_enabled and not Health.is_alive(target):
		target = Targeting.nearest_player(self)
	if _reactions.step(delta, ai_enabled and current_state in [State.IDLE, State.APPROACH, State.RETREAT], move_speed):
		return
	var approach := ai_enabled and not has_meta(&"attack_inspection_manual") and _crowd.ready_to_move() and current_state in [State.IDLE, State.APPROACH]
	if approach and Health.is_alive(target) and _tuning.has("retreat_range"):
		approach = global_position.distance_to(target.global_position) > p("retreat_range")
	if _steering.tick(delta, approach, target, move_speed):
		_pose(delta)
		return
	var desired := Vector3.ZERO
	if current_state == State.STAGGER:
		if state_timer >= p("stagger_duration"):
			set_state(State.IDLE)
	elif has_meta(&"attack_inspection_manual") and current_state in [State.IDLE, State.APPROACH, State.RETREAT]:
		desired = Vector3.ZERO
	elif ai_enabled and _crowd.ready_to_move() and Health.is_alive(target):
		desired = _think(delta)
	elif current_state not in [State.IDLE, State.REACTION]:
		cancel_attack()
		set_state(State.IDLE)
	var previous := global_position
	if current_state == State.CHARGE:
		velocity.x = desired.x
		velocity.z = desired.z
	else:
		velocity.x = move_toward(velocity.x, desired.x + _push.x, p("acceleration") * delta)
		velocity.z = move_toward(velocity.z, desired.z + _push.z, p("acceleration") * delta)
	_push = _push.move_toward(Vector3.ZERO, p("acceleration") * delta)
	velocity.y = -0.5 if is_on_floor() else velocity.y - p("gravity") * delta
	Ground.move(self, delta)
	_after_move(previous, delta)
	_pose(delta)


func _think(_delta: float) -> Vector3:
	return Vector3.ZERO


func _spatial_can_attack() -> bool:
	return Health.is_alive(target) and can_attack_from(global_transform)


func can_attack_from(pose: Transform3D) -> bool:
	if not Health.is_alive(target):
		return false
	var offset := target.global_position - pose.origin
	return Vector2(offset.x, offset.z).length() <= p("attack_range") and line_clear(target.global_position, pose.origin)


func _after_move(_previous: Vector3, _delta: float) -> void:
	pass


func _pose(_delta: float) -> void:
	visual.preview_pose = 1 if Vector2(velocity.x, velocity.z).length() > 0.15 else 0
	visual.sample_pose(anim_clock)


func set_state(next: State) -> void:
	if current_state != next:
		current_state = next
		state_timer = 0.0


func face(point: Vector3, delta: float) -> void:
	var offset := point - global_position
	if Vector2(offset.x, offset.z).length() > 0.001:
		rotation.y = rotate_toward(rotation.y, atan2(-offset.x, -offset.z), p("turn_speed") * delta)


func navigate(goal: Vector3, speed: float, delta: float) -> Vector3:
	var flat := goal - global_position
	flat.y = 0.0
	var desired := flat.normalized() * speed
	return _steering.ground_velocity(goal, _crowd.steer(desired, goal, delta), delta)


func line_clear(to: Vector3, from: Vector3 = Vector3.INF) -> bool:
	return AttackArea.unobstructed(self, global_position if from == Vector3.INF else from, to)


func take_damage(amount: float) -> void:
	if health <= 0.0 or amount <= 0.0:
		return
	var before := health
	health = maxf(0.0, health - Damage.armored(self, amount, p("armor")))
	Telemetry.enemy_damaged(self, before)
	if health < before:
		_flash.play()
	if bool(get_meta(&"experiment_invincible", false)):
		health = maxf(health, 1.0)
	_update_health()
	if health <= 0.0:
		Lifecycle.credit_player(self, target)
		play_death()
	elif bool(_tuning.stagger_on_damage) and not Telemetry.manages_reaction(self):
		trigger_hit_stagger()


func trigger_hit_stagger(recoil := Vector3.ZERO, seconds := 0.0) -> void:
	if current_state == State.DEAD or not _reactions.allow_normal_stagger():
		return
	cancel_attack()
	_push += recoil
	velocity.x = 0.0
	velocity.z = 0.0
	set_state(State.STAGGER)
	state_timer = -maxf(0.0, seconds - p("stagger_duration"))


func apply_grenade_stagger(seconds: float) -> void:
	trigger_hit_stagger(Vector3.ZERO, seconds)


func apply_push(direction: Vector3, force: float) -> void:
	trigger_hit_stagger(direction.normalized() * force * p("push_multiplier"))


func cancel_attack() -> void:
	_crowd.release_attack()


func _update_health() -> void:
	_hit_label.text = "%d/%d" % [ceili(health), ceili(max_health)]


func play_death() -> float:
	if current_state == State.DEAD:
		return 0.0
	set_state(State.DEAD)
	health = 0.0
	cancel_attack()
	_regions.disable()
	collision_layer = 0
	collision_mask = 0
	_collision.set_deferred("disabled", true)
	Lifecycle.begin_death(self)
	var corpse := Corpse.new()
	corpse.name = "CrystalCreatureCorpse"
	corpse.linger = p("corpse_lifetime")
	get_tree().current_scene.add_child(corpse)
	corpse.global_position = global_position
	var duration: float = corpse.begin(visual, _flash)
	Lifecycle.register_effect(self, corpse)
	queue_free()
	return duration


func combat_reaction_begin(_mode: int) -> void:
	cancel_attack()
	set_state(State.REACTION)


func combat_reaction_end() -> void:
	set_state(State.IDLE)


func combat_reaction_ground_velocity(goal: Vector3, desired: Vector3, delta: float) -> Vector3:
	return _steering.ground_velocity(goal, desired, delta)


func combat_reaction_pose(_mode: int, delta: float) -> void:
	_pose(delta)
