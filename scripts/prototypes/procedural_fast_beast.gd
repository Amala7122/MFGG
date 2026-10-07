class_name ProceduralFastBeast
extends CharacterBody3D
const Nav := preload("res://scripts/nav_steering.gd")
const GroundMovement := preload("res://scripts/ground_movement.gd")
const JumpLanding := preload("res://scripts/jump_landing.gd")
const JumpMelee := preload("res://scripts/jump_melee.gd")
const SpatialQuery := preload("res://scripts/spatial_query.gd")
const SpatialProfile := preload("res://scripts/combat_spatial_profile.gd")
@export var combat_spatial_profile: SpatialProfile = preload("res://data/combat_spatial/jump.tres")
var _jump_melee := JumpMelee.new()
var _normal_cooldown := 0.0
var _normal_check_timer := 0.0
var _pounce_landing := Vector3.ZERO
var _steering := Nav.new()
## 四足晶兽：程序化拼装、侧翼绕行、锁向飞扑与物理解体。
## 运行时数值仅来自独立 JSON 或本轮注入的参数快照。

const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Targeting := preload("res://scripts/targeting.gd")
const Crowd := preload("res://scripts/prototypes/enemy_crowd.gd")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
var _attack_area := AttackArea.new()
const PROFILE_ID := "PrototypeFastBeast"
const ReactionProfile := preload("res://scripts/combat_reaction_profile.gd")
const Reactions := preload("res://scripts/combat_reactions.gd")
@export var combat_reaction_profile: ReactionProfile
var _reactions := Reactions.new()

enum State { IDLE, CIRCLE, POUNCE_WINDUP, POUNCE_LEAP, POUNCE_RECOVERY, HIT_STAGGER, DEAD, JUMP_ATTACK, COMBAT_REACTION }
var current_state: State = State.IDLE
@export var ai_enabled := true
var health: float
var max_health: float
var move_speed: float
var circle_speed: float
var attack_damage: float
var attack_interval: float
var _armor: float
var _damage_scale := 1.0
var target: Node3D
var circle_dir := 1.0
var state_timer := 0.0
var anim_clock := 0.0
var _trot_phase := 0.0
var _orbit_wait: float
var _attack_cooldown := 0.0
var _tuning: Dictionary = {}
var _push_velocity := Vector3.ZERO
var _leap_direction := Vector3.FORWARD
var _action_tween: Tween
var _flash_tween: Tween
var _collision: CollisionShape3D
var _health_label: Label3D
var visual_root: Node3D
var spine_chest: Node3D
var spine_hips: Node3D
var head_pivot: Node3D
var jaw_pivot: Node3D
var tail_nodes: Array[Node3D] = []
var leg_pivots: Array[Node3D] = []
var leg_shins: Array[Node3D] = []
var breakable_parts: Array[MeshInstance3D] = []
var back_crystals: Array[MeshInstance3D] = []
var _crowd := Crowd.new()


func _ready() -> void:
	add_child(_attack_area)
	_tuning = Tuning.resolve(self, PROFILE_ID)
	if _tuning.is_empty():
		queue_free()
		return
	_crowd.setup(self, _tuning, PROFILE_ID)
	_tuning = _crowd.varied_values(_tuning, ["move_speed", "circle_speed"], ["attack_damage"],
		["attack_interval", "pounce_windup", "landing_time", "pounce_recovery", "orbit_wait_min", "orbit_wait_max"])
	anim_clock = _crowd.phase
	_trot_phase = _crowd.phase
	for key in ["max_health", "move_speed", "circle_speed", "attack_damage", "attack_interval"]:
		set(key, _p(key))
	_armor = _p("armor")
	health = max_health
	circle_dir = 1.0 if randf() > 0.5 else -1.0
	add_to_group("enemies")
	collision_layer = 4
	collision_mask = 3
	_build_procedural_beast()
	# 原稿朝向已经是 -Z；只把脚底坐标换算到碰撞中心。
	visual_root.position.y = -0.65
	_setup_collision()
	_steering.setup(self, 0.65, 1.55)
	var spatial_values := _tuning.duplicate()
	spatial_values.traversal_speed = move_speed * _p("pounce_speed_multiplier")
	spatial_values.traversal_rise = _p("pounce_jump_speed") * _p("pounce_jump_speed") / (2.0 * _p("gravity")) - 0.05
	_steering.spatial.bind(spatial_values, {"remaining": _spatial_remaining, "consume": _spatial_consume, "can_attack": _spatial_can_attack, "attack_pose": _spatial_attack_pose})
	_health_label = Label3D.new()
	_health_label.name = "HealthLabel"
	_health_label.position.y = 1.05
	_health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_health_label.font_size = 28
	_health_label.pixel_size = 0.006
	add_child(_health_label)
	_update_health_label()
	_reactions.setup(self, combat_reaction_profile, _collision)
	_sample_orbit_wait()


func _p(key: String) -> float:
	return float(_tuning[key])


func _target_alive() -> bool:
	return is_instance_valid(target) and float(target.get("health")) > 0.0


func _physics_process(delta: float) -> void:
	if current_state == State.DEAD:
		return
	_crowd.tick(delta)
	anim_clock += delta * _crowd.gait_multiplier
	# 积分步态相位，速度变化时也连续；不能把随时变化的频率乘累计时间。
	_trot_phase += delta * _p("trot_frequency") * _crowd.gait_multiplier * Vector2(velocity.x, velocity.z).length() / maxf(move_speed, 0.001)
	state_timer += delta
	_attack_cooldown = maxf(_attack_cooldown - delta, 0.0)
	_normal_cooldown = maxf(_normal_cooldown - delta, 0.0)
	_normal_check_timer = maxf(_normal_check_timer - delta, 0.0)
	if _reactions.step(delta, ai_enabled and current_state in [State.IDLE, State.CIRCLE, State.POUNCE_WINDUP], move_speed):
		return
	if ai_enabled and current_state in [State.IDLE, State.CIRCLE] and not _target_alive():
		target = Targeting.nearest_player(self)
	if _steering.tick(delta, ai_enabled and _crowd.ready_to_move() and current_state in [State.IDLE, State.CIRCLE], target, move_speed):
		_animate_trot(anim_clock, Vector2(velocity.x, velocity.z).length() / maxf(move_speed, 0.001))
		return
	var desired := Vector3.ZERO
	match current_state:
		State.IDLE:
			_animate_idle(anim_clock)
			if ai_enabled and _crowd.ready_to_move() and _target_alive():
				_enter_circle()
		State.CIRCLE:
			if ai_enabled and _crowd.ready_to_move() and _target_alive():
				desired = _process_circle_flank(delta)
			else:
				_animate_idle(anim_clock)
		State.POUNCE_WINDUP:
			if not _target_alive():
				_stop_action()
				_enter_circle()
			elif _attack_area.phase == AttackArea.Phase.PREPARE:
				_look_at_target(delta, _p("windup_turn_speed"))
				_attack_area.track(global_transform)
				if state_timer >= _p("pounce_windup") * 0.65:
					_attack_area.lock()
					_leap_direction = -global_basis.z.normalized()
		State.POUNCE_LEAP:
			desired = _leap_direction * move_speed * _p("pounce_speed_multiplier")
	# 每种状态都执行重力；受击与命中后不会把垂直速度清零而悬空。
	if current_state == State.POUNCE_LEAP:
		velocity.x = desired.x + _push_velocity.x
		velocity.z = desired.z + _push_velocity.z
	else:
		velocity.x = move_toward(velocity.x, desired.x + _push_velocity.x, _p("acceleration") * delta)
		velocity.z = move_toward(velocity.z, desired.z + _push_velocity.z, _p("acceleration") * delta)
	_push_velocity = _push_velocity.move_toward(Vector3.ZERO, _p("push_decay") * delta)
	if is_on_floor() and velocity.y <= 0.0:
		velocity.y = -0.5
	else:
		velocity.y -= _p("gravity") * delta
	var previous_position := global_position
	GroundMovement.move(self, delta, current_state not in [State.POUNCE_LEAP, State.JUMP_ATTACK])
	if current_state == State.JUMP_ATTACK:
		if _jump_melee.advance(delta):
			Telemetry.hurt_player(target, _p("normal_attack_damage") * _damage_scale, global_position, 1.0, Telemetry.source_info(self, "晶兽跳跃普攻"))
		if _jump_melee.finished():
			_enter_circle()
	if current_state == State.POUNCE_LEAP:
		_check_pounce_hit(previous_position)
		if current_state == State.POUNCE_LEAP and (is_on_floor() or is_on_wall() or state_timer >= _p("pounce_max_time")):
			_land_recovery()


func _process_circle_flank(delta: float) -> Vector3:
	var offset := target.global_position - global_position
	offset.y = 0.0
	var distance := offset.length()
	var ordinary_only: bool = not _steering.spatial.permits_channel(&"pounce")
	if _normal_cooldown <= 0.0 and _normal_check_timer <= 0.0 and distance <= _p("normal_attack_reach") * _crowd.size_multiplier and (_target_above() or ordinary_only):
		_normal_check_timer = 0.18
		if (ordinary_only or not _pounce_landing_ok()) and trigger_jump_attack():
			return Vector3.ZERO
	var above := _target_above()
	var routing: bool = above or ordinary_only or _steering.needs_route(target.global_position)
	_look_at_target(delta, _p("turn_speed"))
	var desired: Vector3
	if (above or ordinary_only) and JumpMelee.can_start(self, target, _normal_attack_spec()):
		desired = Vector3.ZERO
	elif routing or distance > _p("circle_outer_distance"):
		# 场地初始相隔很远，先接近目标，避免切向绕行导致迟迟不能接战。
		desired = offset.normalized() * move_speed
	else:
		var radial := Vector3.ZERO
		if distance < _p("circle_inner_distance"):
			radial = global_basis.z * _p("retreat_weight")
		desired = (global_basis.x * circle_dir + radial).normalized() * circle_speed
	if _crowd.enabled():
		desired = _crowd.steer(desired, target.global_position, delta, distance > _p("circle_outer_distance"))
	desired = _steering.ground_velocity(target.global_position, desired, delta)
	if routing and not desired.is_zero_approx():
		rotation.y = lerp_angle(rotation.y, atan2(-desired.x, -desired.z), clampf(_p("turn_speed") * delta, 0.0, 1.0))
	_animate_trot(anim_clock, desired.length() / maxf(move_speed, 0.001))
	if state_timer >= _orbit_wait and _attack_cooldown <= 0.0 and is_on_floor():
		if distance >= _p("pounce_min_distance") and distance <= _p("pounce_max_distance"):
			trigger_pounce()
			if current_state == State.POUNCE_WINDUP:
				desired = Vector3.ZERO
		else:
			circle_dir *= -1.0
			_sample_orbit_wait()
	return desired


func _look_at_target(delta: float, speed: float) -> void:
	if not _target_alive():
		return
	var offset := target.global_position - global_position
	offset.y = 0.0
	if not offset.is_zero_approx():
		rotation.y = lerp_angle(rotation.y, atan2(-offset.x, -offset.z), clampf(speed * delta, 0.0, 1.0))


func _sample_orbit_wait() -> void:
	# 每次绕行仅抽取一次等待时间，避免逐帧重抽改变随机区间的含义。
	state_timer = 0.0
	_orbit_wait = randf_range(_p("orbit_wait_min"), _p("orbit_wait_max"))


func _enter_circle() -> void:
	_attack_area.cancel()
	_crowd.release_attack()
	if current_state == State.DEAD:
		return
	_reset_pose()
	current_state = State.CIRCLE if ai_enabled and _target_alive() else State.IDLE
	_sample_orbit_wait()


func _reset_pose() -> void:
	spine_chest.position.y = 0.75
	spine_chest.rotation = Vector3.ZERO
	spine_hips.position.y = 0.05
	spine_hips.rotation = Vector3.ZERO
	head_pivot.rotation = Vector3.ZERO
	jaw_pivot.rotation = Vector3.ZERO
	for node in leg_pivots + leg_shins + tail_nodes:
		node.rotation = Vector3.ZERO


func _stop_action() -> void:
	_attack_area.cancel()
	_crowd.release_attack()
	if _action_tween != null and _action_tween.is_valid():
		_action_tween.kill()
	_action_tween = null


func trigger_pounce() -> void:
	if current_state not in [State.IDLE, State.CIRCLE] or not _target_alive():
		return
	if not _pounce_landing_ok():
		trigger_jump_attack()
		return
	if not _steering.spatial.permits_channel(&"pounce") or not AttackArea.candidate_can_hit(self, global_transform, _pounce_spec(), target):
		return
	_stop_action()
	if not _crowd.request_attack():
		return
	if not _steering.spatial.permit_landing(_pounce_landing, &"jump"):
		_crowd.release_attack()
		return
	_reset_pose()
	current_state = State.POUNCE_WINDUP
	state_timer = 0.0
	_attack_cooldown = attack_interval
	velocity.x = 0.0
	velocity.z = 0.0
	var flight := minf(_p("pounce_max_time"), 2.0 * _p("pounce_jump_speed") / maxf(_p("gravity"), 0.01))
	_attack_area.prepare(global_transform, _pounce_spec(), attack_damage * _damage_scale, _p("pounce_windup"))
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_action_tween.tween_property(spine_chest, "position:y", 0.35, _p("pounce_windup"))
	_action_tween.parallel().tween_property(spine_hips, "position:y", -0.2, _p("pounce_windup"))
	_action_tween.parallel().tween_property(jaw_pivot, "rotation_degrees:x", 35.0, _p("pounce_windup"))
	for index in [2, 3]:
		_action_tween.parallel().tween_property(leg_pivots[index], "rotation_degrees:x", -45.0, _p("pounce_windup"))
	_action_tween.tween_callback(_launch_pounce)


func _target_above() -> bool:
	if not _target_alive():
		return false
	var support := SpatialQuery.support(target)
	return not support.is_empty() and float(support.position.y) > SpatialQuery.feet(self).y + 0.4


func _pounce_landing_ok() -> bool:
	if not _target_alive():
		return false
	var apex := _p("pounce_jump_speed") * _p("pounce_jump_speed") / (2.0 * _p("gravity")) - 0.05
	var ignored: Array[RID] = []
	for hit in SpatialQuery.landing_candidates(self, target, _steering.spatial.profile.candidate_radius):
		if SpatialQuery.full_support(self, hit):
			var landing := SpatialQuery.body_on_floor(self, hit)
			if landing.y - global_position.y <= apex and _steering.spatial.permit_landing(landing, &"jump", ignored, false):
				_pounce_landing = landing
				return true
	return false


func _pounce_spec() -> Dictionary:
	var flight := minf(_p("pounce_max_time"), 2.0 * _p("pounce_jump_speed") / maxf(_p("gravity"), 0.01))
	return {"kind": "capsule", "radius": _p("pounce_hit_radius") * _crowd.size_multiplier,
		"length": move_speed * _p("pounce_speed_multiplier") * flight, "height": _p("pounce_hit_height") * _crowd.size_multiplier,
		"travel_speed": move_speed * _p("pounce_speed_multiplier"), "jump_speed": _p("pounce_jump_speed"),
		"gravity": _p("gravity"), "flight_time": flight, "hit_angle": _p("pounce_hit_angle"),
		"body_shape": _collision.shape, "body_scale": _collision.global_basis.get_scale()}


func _spatial_remaining(channel: StringName) -> float:
	return _attack_cooldown if channel == &"pounce" else 0.0


func _spatial_consume(channel: StringName, duration: float) -> void:
	if channel == &"pounce":
		_attack_cooldown = maxf(_attack_cooldown, duration)


func _spatial_can_attack() -> bool:
	if not _target_alive():
		return false
	if (_target_above() or not _steering.spatial.permits_channel(&"pounce")) and JumpMelee.can_start(self, target, _normal_attack_spec()):
		return true
	var distance := Vector2(target.global_position.x - global_position.x, target.global_position.z - global_position.z).length()
	return _steering.spatial.permits_channel(&"pounce") and distance >= _p("pounce_min_distance") and distance <= _p("pounce_max_distance") and AttackArea.candidate_can_hit(self, global_transform, _pounce_spec(), target)


func _normal_attack_spec() -> Dictionary:
	return {"reach": _p("normal_attack_reach") * _crowd.size_multiplier, "height": _p("normal_attack_height") * _crowd.size_multiplier,
		"jump_speed": _p("normal_jump_speed"), "gravity": _p("gravity")}

func _spatial_attack_pose(pose: Transform3D) -> bool:
	return _target_alive() and JumpMelee.can_start_at(self, target, _normal_attack_spec(), pose)


func trigger_jump_attack() -> bool:
	if current_state not in [State.IDLE, State.CIRCLE] or _normal_cooldown > 0.0 or not JumpMelee.can_start(self, target, _normal_attack_spec()):
		return false
	_stop_action()
	if not _crowd.request_attack():
		return false
	_reset_pose()
	current_state = State.JUMP_ATTACK
	_normal_cooldown = _p("normal_attack_interval")
	var offset := target.global_position - global_position
	rotation.y = atan2(-offset.x, -offset.z)
	_jump_melee.begin(self, target, _normal_attack_spec())
	var flight := 2.0 * _p("normal_jump_speed") / _p("gravity")
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.tween_property(jaw_pivot, "rotation_degrees:x", 30.0, flight * 0.3)
	_action_tween.parallel().tween_property(leg_pivots[0], "rotation_degrees:x", -45.0, flight * 0.3)
	_action_tween.tween_property(spine_chest, "rotation_degrees:x", 20.0, flight * 0.4)
	return true


func _launch_pounce() -> void:
	if current_state != State.POUNCE_WINDUP:
		return
	if not _target_alive():
		_enter_circle()
		return
	# 前 65% 蓄力追踪，最后 35% 提前锁向；起跳后不修正路线。
	if not _pounce_landing_ok():
		_enter_circle()
		return
	if _attack_area.phase == AttackArea.Phase.PREPARE:
		_attack_area.track(global_transform)
		_attack_area.lock()
		_leap_direction = -global_basis.z.normalized()
	if not _attack_area.can_reach(target.global_position):
		_enter_circle()
		return
	current_state = State.POUNCE_LEAP
	state_timer = 0.0
	velocity = _leap_direction * move_speed * _p("pounce_speed_multiplier") + Vector3.UP * _p("pounce_jump_speed")
	for index in [0, 1]:
		leg_pivots[index].rotation_degrees.x = -60.0
	for index in [2, 3]:
		leg_pivots[index].rotation_degrees.x = 50.0


func _check_pounce_hit(previous_position: Vector3) -> void:
	if current_state != State.POUNCE_LEAP or _attack_area.phase != AttackArea.Phase.LOCKED or not _target_alive() or not target.has_method("take_damage"):
		return
	if not _attack_area.can_reach(target.global_position):
		return
	# 检查本帧走过的线段，高速调参时也不会直接跨过目标而漏掉命中。
	var closest := Geometry3D.get_closest_point_to_segment(target.global_position, previous_position, global_position)
	var offset := target.global_position - closest
	var horizontal := Vector2(offset.x, offset.z).length()
	if horizontal > _p("pounce_hit_radius") * _crowd.size_multiplier or absf(offset.y) > _p("pounce_hit_height") * _crowd.size_multiplier:
		return
	var flat := target.global_position - previous_position
	flat.y = 0.0
	if not flat.is_zero_approx() and _leap_direction.dot(flat.normalized()) < cos(deg_to_rad(_p("pounce_hit_angle"))):
		return
	var query := PhysicsRayQueryParameters3D.create(closest, target.global_position, 1)
	if not closest.is_equal_approx(target.global_position) and not get_world_3d().direct_space_state.intersect_ray(query).is_empty():
		return
	if not _attack_area.strike():
		return
	Telemetry.hurt_player(target, _attack_area.damage, global_position, 1.0,
		Telemetry.source_info(self, "晶兽飞扑"))
	_land_recovery()


func _land_recovery() -> void:
	if current_state != State.POUNCE_LEAP:
		return
	_stop_action()
	current_state = State.POUNCE_RECOVERY
	state_timer = 0.0
	velocity.x = 0.0
	velocity.z = 0.0
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	_action_tween.tween_property(spine_chest, "position:y", 0.4, _p("landing_time"))
	_action_tween.parallel().tween_property(jaw_pivot, "rotation_degrees:x", 0.0, _p("landing_time"))
	_action_tween.tween_property(spine_chest, "position:y", 0.75, _p("pounce_recovery"))
	_action_tween.parallel().tween_property(spine_hips, "position:y", 0.05, _p("pounce_recovery"))
	for node in leg_pivots + leg_shins:
		_action_tween.parallel().tween_property(node, "rotation", Vector3.ZERO, _p("pounce_recovery"))
	_action_tween.tween_callback(_enter_circle)


func trigger_hit_stagger(recoil: Vector3) -> void:
	if current_state == State.DEAD or not _reactions.allow_normal_stagger():
		return
	_stop_action()
	_reset_pose()
	current_state = State.HIT_STAGGER
	state_timer = 0.0
	_push_velocity = Vector3(recoil.x, 0.0, recoil.z)
	# 立即切换水平动量，Q 不会先继承飞扑速度继续冲向玩家。
	velocity.x = _push_velocity.x
	velocity.z = _push_velocity.z
	velocity.y = maxf(velocity.y, _p("stagger_jump_speed"))
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_action_tween.tween_property(head_pivot, "rotation_degrees:y", randf_range(-35.0, 35.0), _p("stagger_hit_time"))
	_action_tween.tween_interval(_p("stagger_hold"))
	_action_tween.tween_property(head_pivot, "rotation_degrees:y", 0.0, _p("stagger_recovery"))
	_action_tween.tween_callback(_enter_circle)


func take_damage(amount: float) -> void:
	if current_state == State.DEAD or amount <= 0.0:
		return
	var before := health
	health = maxf(health - amount * (1.0 - _armor), 0.0)
	Telemetry.enemy_damaged(self, before)
	_update_health_label()
	if health <= 0.0:
		if Telemetry.credits_player(self) and is_instance_valid(target) and target.has_method("register_enemy_kill"):
			target.call("register_enemy_kill")
		trigger_death_shatter()
		return
	_flash_crystals()
	if bool(_tuning.stagger_on_damage) and not Telemetry.manages_reaction(self) and current_state in [State.IDLE, State.CIRCLE, State.POUNCE_WINDUP]:
		trigger_hit_stagger(global_basis.z * _p("damage_recoil_speed"))


func combat_reaction_begin(_mode: int) -> void:
	_steering.spatial.cancel_motion()
	_stop_action()
	_reset_pose()
	_push_velocity = Vector3.ZERO
	current_state = State.COMBAT_REACTION
	state_timer = 0.0


func combat_reaction_end() -> void:
	_enter_circle()


func combat_reaction_ground_velocity(goal: Vector3, desired: Vector3, delta: float) -> Vector3:
	return _steering.ground_velocity(goal, _crowd.steer(desired, goal, delta), delta)


func combat_reaction_pose(mode: int, delta: float) -> void:
	if mode == Reactions.Mode.EVADE:
		if Vector2(velocity.x, velocity.z).length() > 0.1:
			rotation.y = rotate_toward(rotation.y, atan2(-velocity.x, -velocity.z), delta * _p("turn_speed"))
		_animate_trot(anim_clock, Vector2(velocity.x, velocity.z).length() / maxf(move_speed, 0.001))
	else:
		head_pivot.rotation_degrees.y = 25.0
		spine_chest.rotation_degrees.x = -12.0


func apply_push(direction: Vector3, force: float) -> void:
	if current_state == State.DEAD:
		return
	var flat := Vector3(direction.x, 0.0, direction.z)
	var recoil := flat.normalized() * maxf(force, 0.0) * _p("push_multiplier")
	if bool(_tuning.push_interrupts_pounce):
		trigger_hit_stagger(recoil)
	else:
		_push_velocity += recoil


func _flash_crystals() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	for index in range(back_crystals.size()):
		if index > 0:
			_flash_tween.parallel()
		_flash_tween.tween_property(back_crystals[index], "scale", Vector3.ONE * _p("crystal_flash_scale"), _p("crystal_flash_in"))
	for index in range(back_crystals.size()):
		if index > 0:
			_flash_tween.parallel()
		_flash_tween.tween_property(back_crystals[index], "scale", Vector3.ONE, _p("crystal_flash_out"))


func _update_health_label() -> void:
	_health_label.text = "迅捷晶兽  %d/%d" % [ceili(health), ceili(max_health)]


func _build_procedural_beast() -> void:
	visual_root = Node3D.new()
	visual_root.name = "VisualRoot"
	add_child(visual_root)

	# --- 材质定义（玄武黑岩 + 苔原暗绿 + 高光共鸣青晶） ---
	var mat_carapace := StandardMaterial3D.new()
	mat_carapace.albedo_color = Color(0.2, 0.22, 0.25) # 深黑青坚甲
	mat_carapace.roughness = 0.9
	mat_carapace.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mat_underbelly := StandardMaterial3D.new()
	mat_underbelly.albedo_color = Color(0.35, 0.38, 0.3) # 浅灰绿腹底
	mat_underbelly.roughness = 0.95
	mat_underbelly.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mat_crystal := StandardMaterial3D.new()
	mat_crystal.albedo_color = Color(0.08, 0.95, 0.85) # 亮青发光晶体
	mat_crystal.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# --- 脊椎前胸 (Chest: y=0.75, z=-0.1) ---
	spine_chest = Node3D.new()
	spine_chest.position = Vector3(0.0, 0.75, -0.1)
	visual_root.add_child(spine_chest)

	var chest_mesh := CylinderMesh.new()
	chest_mesh.top_radius = 0.45
	chest_mesh.bottom_radius = 0.32
	chest_mesh.height = 0.7
	chest_mesh.radial_segments = 5 # 5面多边形，前凸棱胸
	var chest := _create_part("Chest", chest_mesh, mat_carapace, spine_chest)
	chest.rotation_degrees.x = 80.0

	# 背部主发光共鸣晶角
	var main_horn_mesh := PrismMesh.new()
	main_horn_mesh.size = Vector3(0.14, 0.5, 0.28)
	var horn1 := _create_part("CrystalHorn1", main_horn_mesh, mat_crystal, spine_chest)
	horn1.position = Vector3(0.0, 0.38, -0.1)
	horn1.rotation_degrees.x = -25.0
	back_crystals.append(horn1)

	# --- 脊椎后臀 (Hips: 连接在前胸后方) ---
	spine_hips = Node3D.new()
	spine_hips.position = Vector3(0.0, 0.05, 0.6)
	spine_chest.add_child(spine_hips)

	var hips_mesh := BoxMesh.new()
	hips_mesh.size = Vector3(0.52, 0.42, 0.55)
	var hips := _create_part("Hips", hips_mesh, mat_underbelly, spine_hips)
	hips.position.y = 0.0

	# 臀部次晶角
	var sub_horn_mesh := PrismMesh.new()
	sub_horn_mesh.size = Vector3(0.1, 0.32, 0.2)
	var horn2 := _create_part("CrystalHorn2", sub_horn_mesh, mat_crystal, spine_hips)
	horn2.position = Vector3(0.0, 0.28, 0.05)
	horn2.rotation_degrees.x = -15.0
	back_crystals.append(horn2)

	# --- 头部与下颚 ---
	head_pivot = Node3D.new()
	head_pivot.position = Vector3(0.0, 0.1, -0.45)
	spine_chest.add_child(head_pivot)

	var skull_mesh := PrismMesh.new()
	skull_mesh.size = Vector3(0.32, 0.45, 0.28)
	var skull := _create_part("Skull", skull_mesh, mat_carapace, head_pivot)
	skull.rotation_degrees = Vector3(-90, 0, 180) # 尖吻向前突刺

	# 头部发光双眼 (细长方条)
	var eye_mesh := BoxMesh.new()
	eye_mesh.size = Vector3(0.34, 0.04, 0.06)
	var eyes := _create_part("Eyes", eye_mesh, mat_crystal, head_pivot)
	eyes.position = Vector3(0.0, 0.05, -0.15)

	# 下颚咬合骨节
	jaw_pivot = Node3D.new()
	jaw_pivot.position = Vector3(0.0, -0.08, -0.1)
	head_pivot.add_child(jaw_pivot)
	var jaw_mesh := BoxMesh.new()
	jaw_mesh.size = Vector3(0.2, 0.06, 0.3)
	var jaw := _create_part("Jaw", jaw_mesh, mat_underbelly, jaw_pivot)
	jaw.position.z = -0.12

	# --- 三段铰接平衡尾舵 ---
	tail_nodes.clear()
	var parent_tail: Node3D = spine_hips
	for i in range(3):
		var t_node := Node3D.new()
		t_node.position = Vector3(0.0, 0.05, 0.3 if i == 0 else 0.28)
		parent_tail.add_child(t_node)
		tail_nodes.append(t_node)

		var t_mesh := BoxMesh.new()
		var factor := 1.0 - float(i) * 0.25
		t_mesh.size = Vector3(0.14 * factor, 0.14 * factor, 0.32)
		var t_mesh_node := _create_part("Tail_%d" % i, t_mesh, mat_carapace, t_node)
		t_mesh_node.position.z = 0.14
		parent_tail = t_node

	# --- 四足反关节肢体生成 ---
	leg_pivots.clear()
	leg_shins.clear()

	# 前肢挂在 spine_chest，后肢挂在 spine_hips
	_create_leg("LF", spine_chest, Vector3(-0.35, -0.05, -0.2), false, mat_carapace, mat_underbelly)
	_create_leg("RF", spine_chest, Vector3(0.35, -0.05, -0.2), false, mat_carapace, mat_underbelly)
	_create_leg("LR", spine_hips, Vector3(-0.32, -0.05, 0.15), true, mat_carapace, mat_underbelly)
	_create_leg("RR", spine_hips, Vector3(0.32, -0.05, 0.15), true, mat_carapace, mat_underbelly)

# 关节肢体生成辅助函数（两段式折角腿）
func _create_leg(id: String, parent_bone: Node3D, offset: Vector3, is_rear: bool, mat_upper: Material, mat_lower: Material) -> void:
	var hip_pivot := Node3D.new()
	hip_pivot.position = offset
	parent_bone.add_child(hip_pivot)
	leg_pivots.append(hip_pivot)

	# 大腿 (Thigh)
	var upper_mesh := BoxMesh.new()
	upper_mesh.size = Vector3(0.12, 0.42, 0.14) if not is_rear else Vector3(0.14, 0.48, 0.18)
	var upper := _create_part(id + "_Thigh", upper_mesh, mat_upper, hip_pivot)
	upper.position.y = -0.18

	# 膝盖/反关节轴 (Shin Pivot)
	var knee_pivot := Node3D.new()
	knee_pivot.position = Vector3(0.0, -0.38, 0.0)
	hip_pivot.add_child(knee_pivot)
	leg_shins.append(knee_pivot)

	# 小腿与爪尖 (Shin/Claw)
	var lower_mesh := BoxMesh.new()
	lower_mesh.size = Vector3(0.09, 0.44, 0.1)
	var lower := _create_part(id + "_Shin", lower_mesh, mat_lower, knee_pivot)
	lower.position.y = -0.18
	lower.rotation_degrees.x = 25.0 if is_rear else -15.0

func _create_part(part_name: String, mesh: Mesh, mat: Material, parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	breakable_parts.append(mi)
	return mi


func _animate_idle(t: float) -> void:
	# 前胸与后臀相位错开的呼吸起伏
	spine_chest.position.y = 0.75 + sin(t * 2.5) * 0.02
	spine_hips.position.y = 0.05 + sin(t * 2.5 - 0.6) * 0.025
	head_pivot.rotation.x = sin(t * 1.5) * 0.06
	jaw_pivot.rotation.x = abs(sin(t * 2.0)) * 0.08

	# 尾巴三节延迟跟随摆动
	for i in range(tail_nodes.size()):
		var phase_lag: float = float(i) * 0.55
		tail_nodes[i].rotation.y = sin(t * 3.0 - phase_lag) * 0.15
		tail_nodes[i].rotation.x = cos(t * 2.0 - phase_lag) * 0.05

func _animate_trot(_t: float, _speed_factor: float) -> void:
	var stride := _trot_phase

	# 对角腿步态：[LF(0) + RR(3)] 一组，[RF(1) + LR(2)] 一组
	var diag_a := sin(stride)
	var diag_b := sin(stride + PI)

	# 前肢
	leg_pivots[0].rotation.x = diag_a * 0.65
	leg_shins[0].rotation.x = clamp(-diag_a * 0.5, 0.0, 0.8)
	leg_pivots[1].rotation.x = diag_b * 0.65
	leg_shins[1].rotation.x = clamp(-diag_b * 0.5, 0.0, 0.8)

	# 后肢
	leg_pivots[2].rotation.x = diag_b * 0.6
	leg_shins[2].rotation.x = clamp(diag_b * 0.5, -0.8, 0.0)
	leg_pivots[3].rotation.x = diag_a * 0.6
	leg_shins[3].rotation.x = clamp(diag_a * 0.5, -0.8, 0.0)

	# 脊椎颠簸与侧向扭摆
	spine_chest.position.y = 0.75 + abs(sin(stride)) * _p("trot_bob")
	spine_chest.rotation.z = sin(stride * 0.5) * 0.08
	spine_hips.rotation.y = -sin(stride * 0.5) * 0.12

	# 奔跑时尾巴水平甩动保持平衡
	for i in range(tail_nodes.size()):
		tail_nodes[i].rotation.y = sin(stride * 0.5 - float(i) * 0.7) * 0.25


func _setup_collision() -> void:
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	# 覆盖正常站姿的躯干与晶角；原稿 0.9 米高的盒子会漏掉上背部射击。
	shape.size = Vector3(0.9, 1.55, 1.6)
	_collision.shape = shape
	add_child(_collision)


func trigger_death_shatter() -> void:
	if current_state == State.DEAD:
		return
	current_state = State.DEAD
	health = 0.0
	_stop_action()
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_collision.set_deferred("disabled", true)
	collision_layer = 0
	collision_mask = 0
	var debris_parent := get_tree().current_scene
	if debris_parent == null:
		debris_parent = get_parent()
	# 先缓存全部世界变换，拆掉胸部也不会改变后续子部件的参考坐标。
	var transforms: Array[Transform3D] = []
	for part in breakable_parts:
		transforms.append(part.global_transform)
	for index in range(breakable_parts.size()):
		var part := breakable_parts[index]
		var world_transform := transforms[index]
		var rb := RigidBody3D.new()
		rb.name = "FastBeastDebris"
		rb.mass = _p("debris_mass")
		rb.add_to_group("fast_beast_debris")
		rb.add_to_group("enemy_death_effect")
		rb.collision_layer = 0
		rb.collision_mask = 1
		debris_parent.add_child(rb)
		rb.global_transform = Transform3D(world_transform.basis.orthonormalized(), world_transform.origin)
		part.reparent(rb, false)
		var mesh_scale := world_transform.basis.get_scale().abs()
		part.transform = Transform3D(Basis.from_scale(mesh_scale), Vector3.ZERO)
		var bounds := part.mesh.get_aabb()
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = bounds.size * mesh_scale
		col.shape = box
		col.position = bounds.get_center() * mesh_scale
		rb.add_child(col)
		var horizontal := _p("scatter_horizontal")
		rb.apply_central_impulse(Vector3(randf_range(-horizontal, horizontal), randf_range(_p("scatter_up_min"), _p("scatter_up_max")), randf_range(-horizontal, horizontal)) * rb.mass)
		rb.apply_torque_impulse(Vector3(randf(), randf(), randf()) * _p("scatter_torque"))
		var lifetime := Timer.new()
		lifetime.one_shot = true
		lifetime.wait_time = _p("debris_lifetime")
		rb.add_child(lifetime)
		lifetime.timeout.connect(rb.queue_free)
		lifetime.start()
	queue_free()
