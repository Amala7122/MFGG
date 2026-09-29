class_name ProceduralSedimentTitan
extends CharacterBody3D
## 沉积泰坦：条件选招、独立冷却、招式记忆与长距离跃击。

const AttackArea := preload("res://scripts/enemy_attack_area.gd")
var _attack_area := AttackArea.new()
var _attack_target: Node3D

const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const PROFILE_ID := "PrototypeSedimentTitan"

const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Targeting := preload("res://scripts/targeting.gd")
const Crowd := preload("res://scripts/prototypes/enemy_crowd.gd")
const Brain := preload("res://scripts/prototypes/titan_combat_brain.gd")
const GroundEffect := preload("res://scripts/prototypes/titan_ground_effect.gd")
const MeleeEffect := preload("res://scripts/prototypes/titan_melee_effect.gd")
const Audio := preload("res://scripts/audio_manager.gd")
var _crowd := Crowd.new()
var _brain := Brain.new()

enum State { SPAWN, IDLE, CHASE, ATK_SLAM, ATK_SWEEP, CAST_SHIELD, DEAD, LEAP_WINDUP, LEAP_AIR, LEAP_RECOVERY }
var current_state: State = State.SPAWN

var max_hp: float
var move_speed: float
var turn_speed: float
var slam_damage: float
var sweep_damage: float
var shield_reduction: float
var mud_shield_duration: float
var mud_shield_interval_min: float
var mud_shield_interval_max: float
var rage_health_ratio: float
var rage_range_multiplier: float
var rage_damage_multiplier: float
var rage_speed_multiplier: float
var rage_incoming_multiplier: float
var rage_crystal_size: float
var rage_spin_multiplier: float
@export var ai_enabled := true
var current_hp: float
var _tuning: Dictionary = {}
var is_enraged := false
var has_mud_shield := false
var _mud_shield_remaining := 0.0
var _mud_shield_cooldown := 0.0
var mud_shield_visual: Node3D
var target: Node3D
# 对齐实验场统计、射击和技能使用的通用敌人字段。
var health: float:
	get: return current_hp
	set(value): current_hp = value
var max_health: float:
	get: return max_hp
var _armor: float:
	get: return shield_reduction if has_mud_shield else 0.0
var _damage_scale: float:
	get: return rage_damage_multiplier if is_enraged else 1.0
var effective_move_speed: float:
	get: return move_speed * (rage_speed_multiplier if is_enraged else 1.0)
var attack_range_scale: float:
	get: return rage_range_multiplier if is_enraged else 1.0
var attack_damage: float:
	get: return slam_damage
var attack_interval: float:
	get: return maxf(_p("slam_windup") + _p("slam_swing") + _p("slam_sink_time") + _p("slam_hold") + _p("slam_recovery"), _p("slam_cooldown"))

var visual_root: Node3D
var torso_pivot: Node3D
var core_mesh: MeshInstance3D
var head_pivot: Node3D
var rage_flames: CPUParticles3D
var rage_embers: CPUParticles3D
var _core_light: OmniLight3D
var right_arm_pivot: Node3D
var right_forearm: Node3D
var left_arm_pivot: Node3D
var left_leg_pivot: Node3D
var right_leg_pivot: Node3D
var destructible_parts: Array[MeshInstance3D] = []
var anim_clock := 0.0
var attack_cooldown := 0.0
## 仅保留出土/转阶段准备等待及旧调试入口；招式频率由 _brain 分别管理。
var _active_skill := ""
var _hit_landed := false
var _selection_reason := "manual"
var _decision_timer := 0.0
var _in_melee := false
var _target_sample: Node3D
var _target_last_position := Vector3.ZERO
var _target_velocity := Vector3.ZERO
var _attack_elapsed := 0.0
var _leap_plan: Dictionary = {}
var _leap_elapsed := 0.0
var _leap_landing := Vector3.ZERO
var _leap_ground := Vector3.ZERO
var _leap_flight := 1.0
var _leap_horizontal := Vector3.ZERO
var _leap_plan_failure := ""
var _air_debris: CPUParticles3D
var _flight_shadow: MeshInstance3D
var _left_arm_mesh: MeshInstance3D
var _sweep_fx: Node3D
var _sweep_progress := 0.0
var _sweep_recovery_from := Transform3D.IDENTITY
var _action_tween: Tween
var _core_tween: Tween
var _collision: CollisionShape3D
var _head_collision: CollisionShape3D
var _health_label: Label3D
var _push_velocity := Vector3.ZERO
const STANDING_VISUAL_Y := -1.6


func _ready() -> void:
	_tuning = Tuning.resolve(self, PROFILE_ID)
	if _tuning.is_empty():
		queue_free()
		return
	_crowd.setup(self, _tuning, PROFILE_ID)
	_tuning = _crowd.varied_values(_tuning, ["move_speed"], ["slam_damage", "sweep_damage", "leap_damage"],
		["slam_windup", "slam_swing", "slam_sink_time", "slam_hold", "slam_recovery", "slam_cooldown",
		"sweep_windup", "sweep_swing", "sweep_recovery", "sweep_cooldown",
		"leap_windup", "leap_landing_hold", "leap_recovery", "leap_cooldown"])
	_brain.setup(_tuning)
	anim_clock = _crowd.phase
	max_hp = _p("max_health")
	for key in ["move_speed", "turn_speed", "slam_damage", "sweep_damage", "shield_reduction", "mud_shield_duration", "mud_shield_interval_min", "mud_shield_interval_max", "rage_health_ratio", "rage_range_multiplier", "rage_damage_multiplier", "rage_speed_multiplier", "rage_incoming_multiplier", "rage_crystal_size", "rage_spin_multiplier"]:
		set(key, float(_tuning[key]))
	current_hp = max_hp
	add_to_group("enemies")
	collision_layer = 4
	collision_mask = 3
	_build_titan_mesh()
	# 原稿模型正面为 +Z，项目攻击和转向统一为 -Z。
	visual_root.rotation.y = PI
	_setup_collision()
	_setup_telegraphs()
	_setup_leap_visuals()
	_health_label = Label3D.new()
	_health_label.name = "HealthLabel"
	_health_label.position.y = 3.1
	_health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_health_label.font_size = 28
	_health_label.pixel_size = 0.008
	add_child(_health_label)
	_update_health_label()
	_mud_shield_cooldown = randf_range(_p("mud_shield_first_min"), _p("mud_shield_first_max"))
	_play_spawn_animation()


func _p(key: String) -> float:
	return float(_tuning[key])


func _physics_process(delta: float) -> void:
	if current_state in [State.ATK_SLAM, State.ATK_SWEEP, State.LEAP_WINDUP] and (not is_instance_valid(_attack_target) or float(_attack_target.get("health")) <= 0.0):
		if current_state == State.LEAP_WINDUP:
			_cancel_leap_windup()
		else:
			_stop_action()
			_finish_action(_p("rage_ready_delay"))
	if current_state == State.DEAD:
		return
	_crowd.tick(delta)
	_brain.tick(delta)
	_sample_target_velocity(delta)
	_decision_timer = maxf(_decision_timer - delta, 0.0)
	anim_clock += delta * _crowd.gait_multiplier
	# 自转不再依赖待机动画，追击和攻击过程中也持续旋转。
	core_mesh.rotate_y(deg_to_rad(_p("crystal_spin_speed")) * delta * (rage_spin_multiplier if is_enraged else 1.0))
	_core_light.light_energy = (1.2 if is_enraged else 0.4) * (1.0 + sin(anim_clock * 9.0) * 0.12)
	_update_mud_shield(delta)
	attack_cooldown = maxf(attack_cooldown - delta, 0.0)
	_track_melee_attack(delta)
	if current_state == State.LEAP_AIR:
		_update_leap_air(delta)
		_head_collision.position = to_local(core_mesh.global_position)
		return
	if current_state == State.LEAP_WINDUP:
		_leap_elapsed += delta
		if _decision_timer <= 0.0:
			_decision_timer = 0.18
			var updated := _plan_leap()
			if not updated.is_empty():
				_leap_plan = updated
				_attack_area.track(Transform3D(Basis.IDENTITY, updated.ground))
				var facing: Vector3 = updated.landing - global_position
				rotation.y = rotate_toward(rotation.y, atan2(-facing.x, -facing.z), turn_speed * 0.18)
	var desired := Vector3.ZERO
	if ai_enabled and _crowd.ready_to_move() and current_state in [State.IDLE, State.CHASE]:
		if not _target_alive():
			target = Targeting.nearest_player(self)
		if _target_alive():
			var offset := target.global_position - global_position
			offset.y = 0.0
			var distance := offset.length()
			var near_limit := _p("near_exit_distance") if _in_melee else _p("near_enter_distance")
			_in_melee = distance <= near_limit and absf(target.global_position.y - global_position.y) <= 2.5 * _crowd.size_multiplier
			_brain.observe_chase(delta, distance, _in_melee)
			if distance > 0.001:
				rotation.y = rotate_toward(rotation.y, atan2(-offset.x, -offset.z), turn_speed * delta * (rage_speed_multiplier if is_enraged else 1.0))
			if attack_cooldown <= 0.0 and _decision_timer <= 0.0:
				_decision_timer = 0.18
				_select_attack(distance)
			if current_state in [State.IDLE, State.CHASE] and distance > _p("near_enter_distance"):
				_set_locomotion(State.CHASE)
				desired = _crowd.steer(-global_basis.z * effective_move_speed, target.global_position, delta)
			elif current_state in [State.IDLE, State.CHASE]:
				_set_locomotion(State.IDLE)
		else:
			_set_locomotion(State.IDLE)
	match current_state:
		State.IDLE:
			_animate_idle(anim_clock)
		State.CHASE:
			_animate_walk(anim_clock)
	_head_collision.position = to_local(core_mesh.global_position)
	# 出土、技能和硬直期间也保留重力，视觉位移与身体碰撞互不干扰。
	velocity.x = move_toward(velocity.x, desired.x + _push_velocity.x, delta * _p("acceleration"))
	velocity.z = move_toward(velocity.z, desired.z + _push_velocity.z, delta * _p("acceleration"))
	_push_velocity = _push_velocity.move_toward(Vector3.ZERO, delta * _p("push_decay"))
	velocity.y = -0.5 if is_on_floor() else velocity.y - _p("gravity") * delta
	move_and_slide()


func _target_alive() -> bool:
	return is_instance_valid(target) and float(target.get("health")) > 0.0


func _set_locomotion(next_state: State) -> void:
	if current_state != next_state:
		_reset_pose()
		current_state = next_state


func _reset_pose() -> void:
	torso_pivot.position.y = 1.8
	torso_pivot.rotation = Vector3.ZERO
	right_arm_pivot.rotation = Vector3.ZERO
	left_arm_pivot.rotation = Vector3.ZERO
	left_arm_pivot.position = Vector3(-1.4, 0.5, 0.0)
	left_arm_pivot.scale = Vector3.ONE
	if is_instance_valid(_left_arm_mesh):
		_left_arm_mesh.position = Vector3(-0.2, -0.5, 0.2)
		_left_arm_mesh.rotation_degrees = Vector3(0, 0, -15)
	right_forearm.position = Vector3(0.8, -0.3, 0.0)
	left_leg_pivot.rotation = Vector3.ZERO
	right_leg_pivot.rotation = Vector3.ZERO


func _stop_action() -> void:
	if is_instance_valid(_sweep_fx):
		_sweep_fx.call("stop_motion")
	_sweep_fx = null
	if is_instance_valid(_air_debris):
		_air_debris.emitting = false
	if is_instance_valid(_flight_shadow):
		_flight_shadow.visible = false
	if current_state != State.DEAD:
		collision_mask = 3
	if not _active_skill.is_empty():
		_brain.completed("cancelled", _in_melee)
		_active_skill = ""
	_crowd.release_attack()
	if _action_tween != null and _action_tween.is_valid():
		_action_tween.kill()
	_action_tween = null
	_attack_area.cancel()
	_leap_plan.clear()
	if current_state != State.DEAD and is_instance_valid(torso_pivot):
		_reset_pose()


func _sample_target_velocity(delta: float) -> void:
	if not _target_alive():
		_target_sample = null
		_target_velocity = Vector3.ZERO
		return
	if _target_sample != target:
		_target_sample = target
		_target_last_position = target.global_position
		_target_velocity = Vector3.ZERO
	else:
		var measured := (target.global_position - _target_last_position) / maxf(delta, 0.001)
		measured.y = 0.0
		_target_velocity = _target_velocity.lerp(measured.limit_length(10.0), 1.0 - exp(-delta * 12.0))
		_target_last_position = target.global_position


func _select_attack(distance: float) -> void:
	var candidates := {}
	var size := _crowd.size_multiplier
	var height_ok := absf(target.global_position.y - global_position.y) <= 2.5 * size
	var away := target.global_position - global_position
	away.y = 0.0
	var retreat_speed := maxf(_target_velocity.dot(away.normalized()), 0.0)
	if height_ok and AttackArea.unobstructed(self, global_position, target.global_position):
		if distance + retreat_speed * (_p("slam_windup") * 0.35 + _p("slam_swing")) <= _p("slam_distance") * attack_range_scale * size:
			candidates.slam = 1.1 if distance > _p("sweep_preferred_distance") * attack_range_scale * size else 1.0
		if distance + retreat_speed * (_p("sweep_windup") * 0.35 + _p("sweep_swing")) <= _p("sweep_distance") * attack_range_scale * size:
			candidates.sweep = 1.3
	_leap_plan.clear()
	if bool(_tuning.leap_enabled) and is_on_floor() and _brain.available("leap") and _brain.wants_approach(distance):
		_leap_plan = _plan_leap()
		if not _leap_plan.is_empty():
			candidates.leap = 2.0
	var skill := _brain.choose(candidates)
	_selection_reason = "far_distance" if _brain.far_time >= _p("far_confirm_time") else "chase_failed" if skill == "leap" else "near_distance"
	match skill:
		"slam": trigger_slam_attack()
		"sweep": trigger_sweep_attack()
		"leap": trigger_leap_attack()


func _track_melee_attack(delta: float) -> void:
	if current_state not in [State.ATK_SLAM, State.ATK_SWEEP] or _attack_area.phase != AttackArea.Phase.PREPARE:
		return
	_attack_elapsed += delta
	var windup := _p("slam_windup" if current_state == State.ATK_SLAM else "sweep_windup")
	if _attack_elapsed >= windup * 0.65:
		_attack_area.lock()
		return
	var direction := _attack_target.global_position - global_position
	if Vector2(direction.x, direction.z).length() > 0.001:
		rotation.y = rotate_toward(rotation.y, atan2(-direction.x, -direction.z), turn_speed * delta)
	_attack_area.track(global_transform)


func _plan_leap() -> Dictionary:
	_leap_plan_failure = ""
	if not _target_alive():
		_leap_plan_failure = "no_target"
		return {}
	var distance := Vector2(target.global_position.x - global_position.x, target.global_position.z - global_position.z).length()
	if distance < _p("leap_min_distance") or distance > _p("leap_max_distance"):
		_leap_plan_failure = "distance"
		return {}
	var flight := clampf(distance / _p("leap_travel_speed"), _p("leap_min_flight"), _p("leap_max_flight"))
	# 有上限的运动预判在起跳时锁死；落点预警也显示预判位置。
	var aim := target.global_position + (_target_velocity * flight * _p("leap_lead_ratio")).limit_length(_p("leap_lead_limit"))
	var flat_aim := Vector3(aim.x - global_position.x, 0.0, aim.z - global_position.z).limit_length(_p("leap_max_distance"))
	aim.x = global_position.x + flat_aim.x
	aim.z = global_position.z + flat_aim.z
	var query := PhysicsRayQueryParameters3D.create(aim + Vector3.UP * 3.0, aim + Vector3.DOWN * 7.0, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or (hit.normal as Vector3).y < 0.75:
		_leap_plan_failure = "no_floor_or_slope"
		return {}
	var ground: Vector3 = hit.position
	var size := _crowd.size_multiplier
	# 圆柱底面接触斜坡时需留出半径对应的高差，不能只按中心射线放置身体。
	var normal: Vector3 = hit.normal
	var slope_clearance := 1.4 * size * Vector2(normal.x, normal.z).length() / normal.y
	var landing := ground + Vector3.UP * (1.7 * size + slope_clearance + 0.04)
	if absf(landing.y - global_position.y) > _p("leap_max_elevation"):
		_leap_plan_failure = "elevation"
		return {}
	distance = Vector2(landing.x - global_position.x, landing.z - global_position.z).length()
	if distance > _p("leap_max_distance") or distance < _p("leap_min_distance"):
		_leap_plan_failure = "predicted_distance"
		return {}
	flight = clampf(distance / _p("leap_travel_speed"), _p("leap_min_flight"), _p("leap_max_flight"))
	var launch := (landing - global_position) / flight + Vector3.UP * _p("gravity") * flight * 0.5
	if not _arc_clear(global_position, launch, flight):
		return {}
	return {"ground": ground, "landing": landing, "flight": flight, "launch": launch}


func _arc_clear(origin: Vector3, launch: Vector3, flight: float) -> bool:
	var size := _crowd.size_multiplier
	var body_shape := CylinderShape3D.new()
	body_shape.radius = 1.4 * size
	body_shape.height = 3.4 * size
	var head_shape := SphereShape3D.new()
	head_shape.radius = (_head_collision.shape as SphereShape3D).radius * size
	var head_offset := _head_collision.position * size
	var space := get_world_3d().direct_space_state
	for part in [{"shape": body_shape, "offset": Vector3.ZERO}, {"shape": head_shape, "offset": head_offset}]:
		var shape_query := PhysicsShapeQueryParameters3D.new()
		shape_query.shape = part.shape
		shape_query.collision_mask = 1
		shape_query.exclude = [get_rid()]
		shape_query.margin = 0.005
		var previous := origin + Vector3.UP * 0.035 + (part.offset as Vector3)
		for i in range(1, 19):
			var time := flight * float(i) / 18.0
			var next := origin + launch * time + Vector3.DOWN * _p("gravity") * time * time * 0.5 + (part.offset as Vector3)
			shape_query.transform = Transform3D(Basis.IDENTITY, previous)
			shape_query.motion = next - previous
			if not space.intersect_shape(shape_query, 1).is_empty():
				_leap_plan_failure = "arc_overlap_%d" % i
				return false
			var result := space.cast_motion(shape_query)
			if result[0] < 0.999:
				_leap_plan_failure = "arc_sweep_%d" % i
				return false
			previous = next
	return true


func trigger_leap_attack() -> bool:
	if not bool(_tuning.leap_enabled) or not is_on_floor():
		return false
	var plan := _leap_plan.duplicate(true) if not _leap_plan.is_empty() else _plan_leap()
	if plan.is_empty() or not _begin_attack(State.LEAP_WINDUP):
		return false
	_leap_plan = plan
	_leap_elapsed = 0.0
	_attack_area.prepare(Transform3D(Basis.IDENTITY, plan.ground), {"kind": "circle", "radius": _p("leap_radius") * _crowd.size_multiplier,
		"height": 3.0 * _crowd.size_multiplier}, _p("leap_damage") * _damage_scale, _p("leap_windup") + float(plan.flight))
	Audio.play_at("titan_charge", global_position, -8.0)
	GroundEffect.spawn(get_tree().current_scene, global_position - Vector3.UP * 1.7 * _crowd.size_multiplier,
		1.9 * _crowd.size_multiplier, 0.25, true, 0.0, true)
	_action_tween.tween_property(torso_pivot, "position:y", 1.2, _p("leap_windup"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", -18.0, _p("leap_windup"))
	_action_tween.parallel().tween_property(right_arm_pivot, "rotation_degrees:x", -85.0, _p("leap_windup"))
	_action_tween.parallel().tween_property(left_arm_pivot, "rotation_degrees:x", -45.0, _p("leap_windup"))
	_action_tween.parallel().tween_property(left_leg_pivot, "rotation_degrees:x", -30.0, _p("leap_windup"))
	_action_tween.parallel().tween_property(right_leg_pivot, "rotation_degrees:x", -30.0, _p("leap_windup"))
	_action_tween.tween_callback(_launch_leap)
	return true


func _launch_leap() -> void:
	if current_state != State.LEAP_WINDUP:
		return
	var plan := _plan_leap()
	if plan.is_empty():
		_cancel_leap_windup()
		return
	_leap_ground = plan.ground
	_leap_landing = plan.landing
	_leap_flight = plan.flight
	_attack_area.track(Transform3D(Basis.IDENTITY, _leap_ground))
	_attack_area.lock()
	current_state = State.LEAP_AIR
	_air_debris.emitting = true
	# 空中的重砸使用区域命中，玩家实体不能成为提前落地的平台。
	collision_mask = 1
	_leap_elapsed = 0.0
	velocity = plan.launch
	_leap_horizontal = Vector3(velocity.x, 0, velocity.z)
	GroundEffect.spawn(get_tree().current_scene, global_position - Vector3.UP * 1.7 * _crowd.size_multiplier,
		2.3 * _crowd.size_multiplier, 0.7, true, _p("ground_shake_strength"))


func _update_leap_air(delta: float) -> void:
	_leap_elapsed += delta
	velocity.x = _leap_horizontal.x
	velocity.z = _leap_horizontal.z
	velocity.y -= _p("gravity") * delta
	move_and_slide()
	_update_flight_shadow()
	var progress := clampf(_leap_elapsed / _leap_flight, 0.0, 1.0)
	torso_pivot.position.y = lerpf(1.45, 1.75, sin(progress * PI))
	right_arm_pivot.rotation_degrees.x = lerpf(-130.0, 65.0, pow(progress, 3.0))
	left_leg_pivot.rotation_degrees.x = lerpf(-40.0, 15.0, progress)
	right_leg_pivot.rotation_degrees.x = lerpf(-40.0, 15.0, progress)
	var blocked := false
	for i in range(get_slide_collision_count()):
		if (get_slide_collision(i).get_normal()).y < 0.7:
			blocked = true
	if blocked or is_on_ceiling():
		_land_leap(false)
	elif is_on_floor() and _leap_elapsed > _leap_flight * 0.5:
		_land_leap(global_position.distance_to(_leap_landing) < 0.9 * _crowd.size_multiplier)
	elif _leap_elapsed > _leap_flight + 0.8:
		_land_leap(false)


func _land_leap(valid: bool) -> void:
	_air_debris.emitting = false
	_flight_shadow.visible = false
	current_state = State.LEAP_RECOVERY
	collision_mask = 3
	velocity.x = 0.0
	velocity.z = 0.0
	if valid and _attack_area.strike():
		_hurt_target(_attack_area.damage, "泰坦蓄力跃击")
		GroundEffect.spawn(get_tree().current_scene, _leap_ground, _p("leap_radius") * _crowd.size_multiplier,
			1.0, false, _p("ground_shake_strength"))
	else:
		_brain.completed("blocked", false)
	_attack_area.recover()
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	torso_pivot.position.y = 1.12
	torso_pivot.rotation_degrees.x = 22.0
	right_arm_pivot.rotation_degrees.x = 65.0
	_recover_leap_pose(_p("leap_landing_hold"))


func _cancel_leap_windup() -> void:
	_stop_action()
	current_state = State.LEAP_RECOVERY
	velocity.x = 0.0
	velocity.z = 0.0
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_recover_leap_pose(0.0)


func _recover_leap_pose(hold: float) -> void:
	if hold > 0.0:
		_action_tween.tween_interval(hold)
	_action_tween.tween_property(torso_pivot, "position:y", 1.8, _p("leap_recovery")).set_trans(Tween.TRANS_BACK)
	_action_tween.parallel().tween_property(torso_pivot, "rotation", Vector3.ZERO, _p("leap_recovery"))
	for joint in [right_arm_pivot, left_arm_pivot, left_leg_pivot, right_leg_pivot]:
		_action_tween.parallel().tween_property(joint, "rotation", Vector3.ZERO, _p("leap_recovery"))
	_action_tween.tween_callback(_finish_action.bind(0.0))


func _setup_leap_visuals() -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.45, 0.37, 0.24)
	stone.roughness = 1.0
	var fragment := BoxMesh.new()
	fragment.size = Vector3.ONE * 0.09
	fragment.material = stone
	_air_debris = CPUParticles3D.new()
	_air_debris.mesh = fragment
	_air_debris.amount = 14
	_air_debris.lifetime = 0.6
	_air_debris.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_air_debris.emission_box_extents = Vector3(0.8, 0.2, 0.5)
	_air_debris.direction = Vector3.DOWN
	_air_debris.gravity = Vector3.DOWN * 9.8
	_air_debris.initial_velocity_min = 0.3
	_air_debris.initial_velocity_max = 1.0
	_air_debris.local_coords = false
	_air_debris.emitting = false
	_air_debris.position.y = 2.0
	visual_root.add_child(_air_debris)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(20):
		var a := TAU * float(i) / 20.0
		var b := TAU * float(i + 1) / 20.0
		for point in [Vector3.ZERO, Vector3(cos(a), 0, sin(a)), Vector3(cos(b), 0, sin(b))]:
			surface.add_vertex(point)
	surface.generate_normals()
	_flight_shadow = MeshInstance3D.new()
	_flight_shadow.mesh = surface.commit()
	var shadow_material := StandardMaterial3D.new()
	shadow_material.albedo_color = Color(0.10, 0.09, 0.07, 0.20)
	shadow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_flight_shadow.material_override = shadow_material
	_flight_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_flight_shadow)
	_flight_shadow.top_level = true
	_flight_shadow.visible = false


func _update_flight_shadow() -> void:
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP, global_position + Vector3.DOWN * 30.0, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	_flight_shadow.visible = not hit.is_empty()
	if not hit.is_empty():
		var radius := 1.5 * _crowd.size_multiplier
		var normal: Vector3 = hit.normal
		var tangent := normal.cross(Vector3.FORWARD).normalized()
		var shadow_basis := Basis(tangent, normal, tangent.cross(normal)).scaled(Vector3(radius, 1, radius))
		_flight_shadow.global_transform = Transform3D(shadow_basis, (hit.position as Vector3) + normal * 0.04)


func _build_titan_mesh() -> void:
	visual_root = Node3D.new()
	visual_root.name = "VisualRoot"
	add_child(visual_root)

	# --- 材质配置（保持低面数与哑光质感） ---
	var mat_basalt := StandardMaterial3D.new()
	mat_basalt.albedo_color = Color(0.24, 0.27, 0.3) # 深青灰玄武岩
	mat_basalt.roughness = 0.95
	mat_basalt.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mat_ruin_stone := StandardMaterial3D.new()
	mat_ruin_stone.albedo_color = Color(0.5, 0.48, 0.44) # 风化古建筑石
	mat_ruin_stone.roughness = 0.9
	mat_ruin_stone.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mat_core := StandardMaterial3D.new()
	mat_core.albedo_color = Color(1.0, 0.82, 0.15)
	mat_core.vertex_color_use_as_albedo = true
	mat_core.roughness = 0.25
	mat_core.emission_enabled = true
	mat_core.emission = Color(1.0, 0.62, 0.05)
	mat_core.emission_energy_multiplier = 0.65

	# --- 躯干基准点 (Torso Pivot) ---
	torso_pivot = Node3D.new()
	torso_pivot.position.y = 1.8
	visual_root.add_child(torso_pivot)

	# 主躯干：倒梯形低多边形块（6棱圆台）
	var torso_mesh := CylinderMesh.new()
	torso_mesh.top_radius = 1.3
	torso_mesh.bottom_radius = 0.7
	torso_mesh.height = 1.6
	torso_mesh.radial_segments = 6 # 6棱角切面
	torso_mesh.rings = 0
	var main_torso := _create_part("MainTorso", torso_mesh, mat_ruin_stone, torso_pivot)
	main_torso.position.y = 0.0

	# 石质颈座与悬浮晶体构成头部，晶体不再埋在胸口。
	var neck_mesh := CylinderMesh.new()
	neck_mesh.top_radius = 0.48
	neck_mesh.bottom_radius = 0.62
	neck_mesh.height = 0.28
	neck_mesh.radial_segments = 6
	var neck := _create_part("CrystalSocket", neck_mesh, mat_basalt, torso_pivot)
	neck.position.y = 0.95
	head_pivot = Node3D.new()
	head_pivot.name = "CrystalHead"
	head_pivot.position.y = 1.6
	torso_pivot.add_child(head_pivot)
	core_mesh = _create_part("HeadCrystal", _crystal_mesh(), mat_core, head_pivot)
	core_mesh.rotation.y = PI * 0.25
	_build_crystal_fire()

	# --- 左臂（轻型护盾臂） ---
	left_arm_pivot = Node3D.new()
	left_arm_pivot.position = Vector3(-1.4, 0.5, 0.0)
	torso_pivot.add_child(left_arm_pivot)

	var l_shield_mesh := BoxMesh.new()
	l_shield_mesh.size = Vector3(0.35, 1.2, 0.6)
	var l_shield := _create_part("LeftShieldArm", l_shield_mesh, mat_ruin_stone, left_arm_pivot)
	_left_arm_mesh = l_shield
	l_shield.position = Vector3(-0.2, -0.5, 0.2)
	l_shield.rotation_degrees.z = -15

	# --- 右臂（核心特征：极端超大巨拳构件） ---
	right_arm_pivot = Node3D.new()
	right_arm_pivot.position = Vector3(1.5, 0.6, 0.0)
	torso_pivot.add_child(right_arm_pivot)

	# 右大臂：粗壮横向石桥
	var r_shoulder_mesh := BoxMesh.new()
	r_shoulder_mesh.size = Vector3(0.9, 0.8, 0.9)
	var r_shoulder := _create_part("RightShoulder", r_shoulder_mesh, mat_basalt, right_arm_pivot)
	r_shoulder.position = Vector3(0.4, 0.0, 0.0)

	# 右前臂与巨手骨节（体积占全身 1/3）
	right_forearm = Node3D.new()
	right_forearm.position = Vector3(0.8, -0.3, 0.0)
	right_arm_pivot.add_child(right_forearm)

	# 巨拳主体（类似整块断裂的石基座）
	var r_fist_mesh := BoxMesh.new()
	r_fist_mesh.size = Vector3(1.3, 1.6, 1.4)
	var r_fist := _create_part("MassiveFist", r_fist_mesh, mat_basalt, right_forearm)
	r_fist.position = Vector3(0.4, -0.9, 0.2)

	# 拳头外突的古代断柱（增强受力剪影）
	var r_pillar_mesh := CylinderMesh.new()
	r_pillar_mesh.top_radius = 0.4
	r_pillar_mesh.bottom_radius = 0.45
	r_pillar_mesh.height = 1.1
	r_pillar_mesh.radial_segments = 5
	var r_pillar := _create_part("FistPillar", r_pillar_mesh, mat_ruin_stone, r_fist)
	r_pillar.position = Vector3(0.3, 0.2, 0.6)
	r_pillar.rotation_degrees.x = 90

	# --- 下肢（粗短双柱） ---
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(0.65, 1.3, 0.75)

	left_leg_pivot = Node3D.new()
	left_leg_pivot.position = Vector3(-0.75, 1.1, 0.0)
	visual_root.add_child(left_leg_pivot)
	var l_leg := _create_part("LeftLeg", leg_mesh, mat_basalt, left_leg_pivot)
	l_leg.position.y = -0.55

	right_leg_pivot = Node3D.new()
	right_leg_pivot.position = Vector3(0.75, 1.1, 0.0)
	visual_root.add_child(right_leg_pivot)
	var r_leg := _create_part("RightLeg", leg_mesh, mat_basalt, right_leg_pivot)
	r_leg.position.y = -0.55
	_build_mud_shield()


func _build_mud_shield() -> void:
	mud_shield_visual = Node3D.new()
	mud_shield_visual.name = "MudShield"
	mud_shield_visual.position.y = 1.8
	mud_shield_visual.visible = false
	visual_root.add_child(mud_shield_visual)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.32, 0.18, 0.075, 0.18)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.95
	var shell := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.65
	sphere.height = 3.3
	sphere.radial_segments = 16
	sphere.rings = 8
	shell.mesh = sphere
	shell.scale = Vector3(1.0, 0.9, 1.0)
	shell.material_override = material
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mud_shield_visual.add_child(shell)
	var mud_mat := StandardMaterial3D.new()
	mud_mat.albedo_color = Color(0.32, 0.21, 0.1)
	mud_mat.roughness = 1.0
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(0.2, 0.55, 0.65)
	for index in range(8):
		var angle := TAU * float(index) / 8.0
		var plate := MeshInstance3D.new()
		plate.mesh = plate_mesh
		plate.material_override = mud_mat
		plate.position = Vector3(cos(angle) * 1.62, 0.28 if index % 2 == 0 else -0.28, sin(angle) * 1.62)
		plate.rotation = Vector3(0.12 if index % 2 == 0 else -0.12, -angle, 0)
		mud_shield_visual.add_child(plate)


func _update_mud_shield(delta: float) -> void:
	if is_enraged or not bool(_tuning.mud_shield_enabled):
		return
	if has_mud_shield:
		mud_shield_visual.rotate_y(delta * _p("mud_shield_spin"))
		_mud_shield_remaining = maxf(_mud_shield_remaining - delta, 0.0)
		if _mud_shield_remaining <= 0.0:
			_remove_mud_shield()
	# 随机间隔在出土后的行动期间推进，释放时等当前攻击完成。
	if ai_enabled and _target_alive() and current_state != State.SPAWN:
		_mud_shield_cooldown = maxf(_mud_shield_cooldown - delta, 0.0)
		if _mud_shield_cooldown <= 0.0 and not has_mud_shield and current_state in [State.IDLE, State.CHASE]:
			_cast_mud_shield()


func _cast_mud_shield() -> void:
	if is_enraged or not bool(_tuning.mud_shield_enabled) or has_mud_shield or current_state not in [State.IDLE, State.CHASE]:
		return
	if _p("mud_shield_windup") + _p("mud_shield_cast") + _p("mud_shield_recovery") <= 0.0:
		_activate_mud_shield()
		return
	_stop_action()
	_reset_pose()
	current_state = State.CAST_SHIELD
	velocity.x = 0.0
	velocity.z = 0.0
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.tween_property(left_arm_pivot, "rotation_degrees:x", -45.0, _p("mud_shield_windup"))
	_action_tween.tween_interval(_p("mud_shield_cast"))
	_action_tween.tween_callback(_activate_mud_shield)
	_action_tween.tween_property(left_arm_pivot, "rotation_degrees:x", 0.0, _p("mud_shield_recovery"))
	_action_tween.tween_callback(_finish_shield_cast)


func _finish_shield_cast() -> void:
	if current_state != State.CAST_SHIELD:
		return
	_reset_pose()
	current_state = State.IDLE


func _activate_mud_shield() -> void:
	if is_enraged or not bool(_tuning.mud_shield_enabled) or has_mud_shield or current_state not in [State.IDLE, State.CHASE, State.CAST_SHIELD]:
		return
	has_mud_shield = true
	_mud_shield_remaining = mud_shield_duration
	_mud_shield_cooldown = randf_range(mud_shield_interval_min, mud_shield_interval_max)
	mud_shield_visual.visible = true
	_update_health_label()


func _remove_mud_shield() -> void:
	has_mud_shield = false
	_mud_shield_remaining = 0.0
	mud_shield_visual.visible = false
	_update_health_label()


func _crystal_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring := [Vector3(0.42, 0, 0), Vector3(0, 0, 0.42), Vector3(-0.42, 0, 0), Vector3(0, 0, -0.42)]
	for index in range(4):
		var a: Vector3 = ring[index]
		var b: Vector3 = ring[(index + 1) % 4]
		for top in [true, false]:
			var tip := Vector3(0, 0.55 if top else -0.55, 0)
			var vertices := [tip, a, b] if top else [tip, b, a]
			var normal: Vector3 = (vertices[2] - vertices[0]).cross(vertices[1] - vertices[0]).normalized()
			var tint := 1.0 - float(index % 3) * 0.14 - (0.12 if not top else 0.0)
			for vertex in vertices:
				surface.set_normal(normal)
				surface.set_color(Color(tint, tint, tint))
				surface.add_vertex(vertex)
	return surface.commit()


func _build_crystal_fire() -> void:
	_core_light = OmniLight3D.new()
	_core_light.name = "CrystalGlow"
	_core_light.light_color = Color(1.0, 0.65, 0.08)
	_core_light.omni_range = 4.0
	_core_light.light_energy = 0.4
	_core_light.shadow_enabled = false
	head_pivot.add_child(_core_light)
	# 无外部贴图：柔边火舌、向上飘散的红色余烬环绕头部。
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.3, 0.7, 1.0])
	gradient.colors = PackedColorArray([Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.7), Color(1, 1, 1, 0.18), Color(1, 1, 1, 0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 64
	texture.height = 64
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(0.5, 0.0)
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var flame_mesh := QuadMesh.new()
	flame_mesh.size = Vector2(0.45, 1.1)
	flame_mesh.material = material
	rage_flames = CPUParticles3D.new()
	rage_flames.name = "RedCrystalFlames"
	rage_flames.mesh = flame_mesh
	rage_flames.amount = 48
	rage_flames.lifetime = 0.85
	rage_flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE_SURFACE
	rage_flames.emission_sphere_radius = 0.6
	rage_flames.direction = Vector3.UP
	rage_flames.spread = 18.0
	rage_flames.gravity = Vector3(0, 0.8, 0)
	rage_flames.initial_velocity_min = 0.7
	rage_flames.initial_velocity_max = 1.6
	rage_flames.scale_amount_min = 0.65
	rage_flames.scale_amount_max = 1.2
	rage_flames.local_coords = true
	rage_flames.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var colors := Gradient.new()
	colors.offsets = PackedFloat32Array([0.0, 0.2, 0.6, 1.0])
	colors.colors = PackedColorArray([Color(1, 0.15, 0.03, 0), Color(0.85, 0.055, 0.008, 0.65), Color(0.65, 0.008, 0.002, 0.4), Color(0.5, 0, 0, 0)])
	rage_flames.color_ramp = colors
	var size_curve := Curve.new()
	size_curve.add_point(Vector2(0, 0.4))
	size_curve.add_point(Vector2(0.18, 1))
	size_curve.add_point(Vector2(1, 0.05))
	rage_flames.scale_amount_curve = size_curve
	rage_flames.emitting = false
	head_pivot.add_child(rage_flames)
	var ember_mesh := SphereMesh.new()
	ember_mesh.radius = 0.025
	ember_mesh.height = 0.05
	ember_mesh.radial_segments = 6
	ember_mesh.rings = 3
	var ember_mat := StandardMaterial3D.new()
	ember_mat.albedo_color = Color(1.0, 0.12, 0.02)
	ember_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ember_mesh.material = ember_mat
	rage_embers = CPUParticles3D.new()
	rage_embers.name = "RedCrystalEmbers"
	rage_embers.mesh = ember_mesh
	rage_embers.amount = 16
	rage_embers.lifetime = 1.1
	rage_embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE_SURFACE
	rage_embers.emission_sphere_radius = 0.7
	rage_embers.direction = Vector3.UP
	rage_embers.spread = 30.0
	rage_embers.gravity = Vector3(0, 0.5, 0)
	rage_embers.initial_velocity_min = 0.8
	rage_embers.initial_velocity_max = 2.0
	rage_embers.scale_amount_curve = size_curve
	rage_embers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rage_embers.emitting = false
	head_pivot.add_child(rage_embers)


func _create_part(part_name: String, mesh: Mesh, mat: Material, parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	destructible_parts.append(mi)
	return mi


func _setup_collision() -> void:
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	var shape := CylinderShape3D.new()
	shape.radius = 1.4
	shape.height = 3.4
	_collision.shape = shape
	add_child(_collision)
	_head_collision = CollisionShape3D.new()
	_head_collision.name = "HeadCollision"
	var head_shape := SphereShape3D.new()
	head_shape.radius = 0.5
	_head_collision.shape = head_shape
	_head_collision.position = to_local(core_mesh.global_position)
	add_child(_head_collision)


func _setup_telegraphs() -> void:
	add_child(_attack_area)


func _play_spawn_animation() -> void:
	current_state = State.SPAWN
	visual_root.position.y = STANDING_VISUAL_Y - _p("spawn_depth")
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	if _crowd.activation_delay > 0.0:
		_action_tween.tween_interval(_crowd.activation_delay)
	_action_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_action_tween.tween_property(visual_root, "position:y", STANDING_VISUAL_Y, _p("spawn_duration"))
	_action_tween.parallel().tween_property(right_arm_pivot, "rotation_degrees:x", -30.0, _p("spawn_duration") * 0.8)
	_action_tween.tween_callback(_finish_action.bind(_p("spawn_ready_delay")))


func _animate_idle(t: float) -> void:
	torso_pivot.position.y = 1.8 + sin(t * 1.5) * 0.05
	torso_pivot.rotation_degrees.z = -3.0 + sin(t * 1.5) * 1.2
	right_arm_pivot.rotation_degrees.x = 10.0 + sin(t * 1.2) * 4.0


func _animate_walk(t: float) -> void:
	var w_speed := _p("walk_frequency") * (rage_speed_multiplier if is_enraged else 1.0)
	left_leg_pivot.rotation.x = sin(t * w_speed) * 0.45
	right_leg_pivot.rotation.x = -sin(t * w_speed) * 0.45
	torso_pivot.rotation.z = sin(t * w_speed * 0.5) * 0.08 - 0.05
	torso_pivot.position.y = 1.8 + abs(sin(t * w_speed)) * _p("walk_bob")
	right_arm_pivot.rotation.x = sin(t * w_speed) * 0.25


func _begin_attack(next_state: State) -> bool:
	if current_state not in [State.IDLE, State.CHASE] or attack_cooldown > 0.0:
		return false
	var skill := "leap" if next_state == State.LEAP_WINDUP else "slam" if next_state == State.ATK_SLAM else "sweep"
	if not _brain.available(skill):
		return false
	_stop_action()
	if not _crowd.request_attack():
		return false
	_reset_pose()
	current_state = next_state
	_attack_target = target
	_active_skill = skill
	_hit_landed = false
	_attack_elapsed = 0.0
	_brain.started(skill, _selection_reason, global_position.distance_to(target.global_position) if _target_alive() else 0.0)
	if _target_alive():
		var direction := target.global_position - global_position
		direction.y = 0.0
		if not direction.is_zero_approx():
			rotation.y = atan2(-direction.x, -direction.z)
	velocity.x = 0.0
	velocity.z = 0.0
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	return true


func trigger_slam_attack() -> void:
	if not _begin_attack(State.ATK_SLAM):
		return
	var size := _crowd.size_multiplier
	_attack_area.prepare(global_transform, {"kind": "rect", "width": _p("slam_width") * size,
		"length": _p("slam_distance") * attack_range_scale * size, "offset": _p("slam_offset") * size,
		"height": 2.5 * size}, slam_damage * _damage_scale, _p("slam_windup") + _p("slam_swing"))
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees:x", -120.0, _p("slam_windup"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", -15.0, _p("slam_windup"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:y", -20.0, _p("slam_windup"))
	_action_tween.tween_callback(_attack_area.lock)
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees:x", 0.0, _p("slam_swing")).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	_action_tween.parallel().tween_property(torso_pivot, "position:y", 1.2, _p("slam_swing"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", 20.0, _p("slam_swing"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:y", -80.0, _p("slam_swing"))
	_action_tween.tween_callback(_execute_slam_impact)
	_action_tween.tween_property(right_forearm, "position:y", -0.4, _p("slam_sink_time")).set_trans(Tween.TRANS_LINEAR)
	_action_tween.tween_interval(_p("slam_hold"))
	_action_tween.tween_property(torso_pivot, "position:y", 1.8, _p("slam_recovery")).set_trans(Tween.TRANS_BACK)
	_action_tween.parallel().tween_property(right_arm_pivot, "rotation_degrees:x", 0.0, _p("slam_recovery"))
	_action_tween.parallel().tween_property(right_forearm, "position:y", -0.3, _p("slam_recovery"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", 0.0, _p("slam_recovery"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:y", 0.0, _p("slam_recovery"))
	_action_tween.tween_callback(_finish_action.bind(_p("slam_cooldown")))


func _execute_slam_impact() -> void:
	if current_state == State.ATK_SLAM and _attack_area.strike():
		_hurt_target(_attack_area.damage, "泰坦直线砸地")
		var visual_spec := _attack_area.shape.duplicate(true)
		visual_spec.contact = _attack_area.to_local((right_forearm.get_node("MassiveFist") as Node3D).global_position)
		MeleeEffect.spawn(get_tree().current_scene, _attack_area.global_transform, visual_spec,
			_crowd.size_multiplier, false, 0.4, _p("ground_shake_strength"))
		_attack_area.recover()


func trigger_sweep_attack() -> void:
	if not _begin_attack(State.ATK_SWEEP):
		return
	var size := _crowd.size_multiplier
	_attack_area.prepare(global_transform, {"kind": "sector", "radius": _p("sweep_distance") * attack_range_scale * size,
		"angle": _p("sweep_angle"), "height": 2.5 * size}, sweep_damage * _damage_scale,
		_p("sweep_windup"))
	_sweep_progress = 0.0
	_action_tween.tween_method(_prepare_sweep, 0.0, 1.0, _p("sweep_windup"))
	_action_tween.tween_callback(_start_sweep)
	_action_tween.tween_method(_advance_sweep, 0.0, 1.0, _p("sweep_swing")).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_action_tween.tween_callback(_execute_sweep_impact)
	_action_tween.tween_method(_recover_sweep, 0.0, 1.0, _p("sweep_recovery")).set_trans(Tween.TRANS_SINE)
	_action_tween.tween_callback(_finish_action.bind(_p("sweep_cooldown")))


func _execute_sweep_impact() -> void:
	if current_state == State.ATK_SWEEP and _attack_area.phase == AttackArea.Phase.STRIKE:
		_advance_sweep(1.0)
		_sweep_recovery_from = left_arm_pivot.transform
		if is_instance_valid(_sweep_fx):
			_sweep_fx.call("stop_motion")
		_attack_area.recover()


func _sweep_arm_pose(angle: float) -> Transform3D:
	var size := _crowd.size_multiplier
	var direction := _attack_area.global_basis * Vector3(sin(angle), 0, -cos(angle))
	direction.y = 0.0
	direction = direction.normalized()
	var shoulder := torso_pivot.to_global(Vector3(-1.4, 0.5, 0))
	var tip := _attack_area.global_position + direction * float(_attack_area.shape.radius) + Vector3.UP * ((0.85 - 1.7) * size)
	var reach := tip - shoulder
	var y_axis := -reach.normalized()
	var reference := Vector3.UP if absf(y_axis.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
	var x_axis := y_axis.cross(reference).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	var length_scale := maxf(reach.length() / 1.1, 0.25)
	# 拉伸沿手臂自身的长轴，避免旋转后变成世界坐标轴缩放。
	var arm_basis := Basis(x_axis * 1.9 * size, y_axis * length_scale, z_axis * 1.9 * size)
	return Transform3D(arm_basis, shoulder)


func _prepare_sweep(value: float) -> void:
	var half := deg_to_rad(float(_attack_area.shape.angle)) * 0.5
	torso_pivot.rotation.y = value * 0.22
	right_arm_pivot.rotation.x = value * 0.18
	var rest := torso_pivot.global_transform * Transform3D(Basis.IDENTITY, Vector3(-1.4, 0.5, 0))
	left_arm_pivot.global_transform = rest.interpolate_with(_sweep_arm_pose(-half), value)
	_left_arm_mesh.position = Vector3(-0.2, -0.5, 0.2).lerp(Vector3(0, -0.5, 0), value)
	_left_arm_mesh.rotation.z = lerpf(deg_to_rad(-15), 0.0, value)


func _start_sweep() -> void:
	_attack_area.lock()
	if not _attack_area.strike():
		return
	_sweep_fx = MeleeEffect.spawn(get_tree().current_scene, _attack_area.global_transform, _attack_area.shape,
		_crowd.size_multiplier, true, _p("sweep_swing"))
	_advance_sweep(0.0)


func _advance_sweep(value: float) -> void:
	if current_state != State.ATK_SWEEP or _attack_area.phase != AttackArea.Phase.STRIKE:
		return
	var arc := deg_to_rad(float(_attack_area.shape.angle))
	var previous := -arc * 0.5 + arc * _sweep_progress
	var angle := -arc * 0.5 + arc * value
	torso_pivot.rotation.y = -sin(angle) * 0.25
	left_arm_pivot.global_transform = _sweep_arm_pose(angle)
	if is_instance_valid(_sweep_fx):
		_sweep_fx.call("set_progress", value)
	if not _hit_landed and _attack_area.can_hit(_attack_target, _attack_area.global_position):
		var local := _attack_area.to_local(_attack_target.global_position)
		var target_angle := atan2(local.x, -local.z)
		var width := atan2(0.35 * _crowd.size_multiplier, maxf(Vector2(local.x, local.z).length(), 0.1))
		if target_angle >= previous - width and target_angle <= angle + width:
			_hurt_target(_attack_area.damage, "泰坦左臂横扫")
	_sweep_progress = value


func _recover_sweep(value: float) -> void:
	torso_pivot.rotation.y = lerpf(-0.25 * sin(deg_to_rad(float(_attack_area.shape.angle)) * 0.5), 0.0, value)
	right_arm_pivot.rotation.x = lerpf(0.18, 0.0, value)
	left_arm_pivot.transform = _sweep_recovery_from.interpolate_with(Transform3D(Basis.IDENTITY, Vector3(-1.4, 0.5, 0)), value)
	_left_arm_mesh.position = Vector3(0, -0.5, 0).lerp(Vector3(-0.2, -0.5, 0.2), value)
	_left_arm_mesh.rotation.z = lerpf(0.0, deg_to_rad(-15), value)


func _hurt_target(amount: float, attack: String) -> void:
	if _attack_area.can_hit(_attack_target, _attack_area.global_position):
		_hit_landed = true
		Telemetry.hurt_player(_attack_target, amount, global_position, 1.0, Telemetry.source_info(self, attack))


func _finish_action(cooldown: float) -> void:
	_attack_area.cancel()
	_crowd.release_attack()
	if current_state == State.DEAD:
		return
	_reset_pose()
	current_state = State.IDLE
	if not _active_skill.is_empty():
		var near := _target_alive() and Vector2(target.global_position.x - global_position.x, target.global_position.z - global_position.z).length() <= _p("near_exit_distance")
		_brain.completed("blocked" if _brain.last_result == "blocked" else "hit" if _hit_landed else "miss", near)
		_active_skill = ""
		attack_cooldown = 0.0
	else:
		attack_cooldown = cooldown
	_decision_timer = 0.0


func take_damage_at(amount: float, _hit_position: Vector3, _headshot: bool) -> void:
	# 晶体只是阶段标识，不再叠加旧的 2.5 倍弱点奖励。
	take_damage(amount)


func take_damage(amount: float, _hit_part: Node = null) -> void:
	if current_state == State.DEAD or amount <= 0.0:
		return
	var final_damage := amount * (rage_incoming_multiplier if is_enraged else 1.0)
	if has_mud_shield and not is_enraged:
		final_damage *= 1.0 - shield_reduction
	_apply_damage(final_damage)
	if current_state == State.DEAD:
		return
	if bool(_tuning.rage_enabled) and not is_enraged and current_hp <= max_hp * rage_health_ratio:
		_trigger_rage()
	if has_mud_shield and bool(_tuning.mud_shield_break_on_q) and String(get_meta(Telemetry.CONTEXT, {}).get("source", "")) == "Q":
		_remove_mud_shield()


func _apply_damage(amount: float) -> void:
	var before := current_hp
	current_hp = maxf(current_hp - amount, 0.0)
	Telemetry.enemy_damaged(self, before)
	_update_health_label()
	if current_hp <= 0.0:
		if is_instance_valid(target) and target.has_method("register_enemy_kill"):
			target.call("register_enemy_kill")
		trigger_death_scatter()


func _trigger_rage() -> void:
	if not bool(_tuning.rage_enabled) or is_enraged or current_state == State.DEAD:
		return
	is_enraged = true
	_remove_mud_shield()
	var mat := core_mesh.material_override as StandardMaterial3D
	mat.albedo_color = Color(1.0, 0.055, 0.025)
	mat.emission = Color(1.0, 0.015, 0.005)
	mat.emission_energy_multiplier = 1.1
	_core_light.light_color = Color(1.0, 0.06, 0.02)
	rage_flames.emitting = true
	rage_embers.emitting = true
	# 范围改变时取消当前蓄力，避免旧预警突然结算扩大后的伤害。
	if current_state in [State.ATK_SLAM, State.ATK_SWEEP, State.CAST_SHIELD]:
		_stop_action()
		_finish_action(_p("rage_ready_delay"))
	(_head_collision.shape as SphereShape3D).radius = 0.5 * rage_crystal_size
	_core_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_core_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_core_tween.tween_property(core_mesh, "scale", Vector3.ONE * rage_crystal_size, _p("rage_transform_time"))
	_core_tween.parallel().tween_property(head_pivot, "position:y", 1.9, _p("rage_transform_time"))
	_core_tween.parallel().tween_property(_health_label, "position:y", 4.2, _p("rage_transform_time"))
	_update_health_label()


func apply_push(direction: Vector3, force: float) -> void:
	if current_state == State.DEAD:
		return
	# 巨型敌人仅承受 15% 击退，Q 使用现有范围伤害与击退。
	_push_velocity = Vector3(direction.x, 0, direction.z).normalized() * maxf(force, 0.0) * _p("push_multiplier")


func _update_health_label() -> void:
	var phase_text := " · 红晶狂暴" if is_enraged else (" · 泥盾 %d%%" % roundi(shield_reduction * 100.0) if has_mud_shield else "")
	_health_label.text = "沉积泰坦  %d/%d%s" % [ceili(current_hp), ceili(max_hp), phase_text]


func trigger_death_scatter() -> void:
	if current_state == State.DEAD:
		return
	current_state = State.DEAD
	current_hp = 0.0
	_stop_action()
	if _core_tween != null and _core_tween.is_valid():
		_core_tween.kill()
	_collision.set_deferred("disabled", true)
	_head_collision.set_deferred("disabled", true)
	collision_layer = 0
	collision_mask = 0
	var debris_parent := get_tree().current_scene
	if debris_parent == null:
		debris_parent = get_parent()
	# 所有世界变换在解绑前缓存，包含巨拳子节点里的断柱。
	var transforms: Array[Transform3D] = []
	for part in destructible_parts:
		transforms.append(part.global_transform)
	for index in range(destructible_parts.size()):
		var part := destructible_parts[index]
		var world_transform := transforms[index]
		if part == core_mesh:
			part.reparent(debris_parent, true)
			part.add_to_group("sediment_titan_core")
			# 旋转 Tween 绑定到核心自身，主敌人销毁后继续运行。
			var spin := part.create_tween().set_loops()
			spin.tween_property(part, "rotation_degrees:y", 360.0, 360.0 / _p("core_death_spin")).as_relative()
			_add_lifetime(part, _p("core_lifetime"))
			continue
		var rb := RigidBody3D.new()
		rb.name = "SedimentTitanDebris"
		rb.mass = _p("debris_mass")
		rb.collision_layer = 0
		rb.collision_mask = 1
		rb.add_to_group("sediment_titan_debris")
		rb.add_to_group("enemy_death_effect")
		debris_parent.add_child(rb)
		rb.global_transform = Transform3D(world_transform.basis.orthonormalized(), world_transform.origin)
		part.reparent(rb, false)
		part.transform = Transform3D(Basis.from_scale(world_transform.basis.get_scale()), Vector3.ZERO)
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = part.mesh.get_aabb().size * world_transform.basis.get_scale().abs()
		col.shape = box
		rb.add_child(col)
		# 原稿质量 8kg 的小冲量几乎不散开，按质量换算期望散开速度。
		var horizontal := _p("scatter_horizontal")
		rb.apply_central_impulse(Vector3(randf_range(-horizontal, horizontal), randf_range(_p("scatter_up_min"), _p("scatter_up_max")), randf_range(-horizontal, horizontal)) * rb.mass)
		rb.apply_torque_impulse(Vector3(randf(), randf(), randf()) * _p("scatter_torque"))
		_add_lifetime(rb, _p("debris_lifetime"))
	queue_free()


func _add_lifetime(node: Node, seconds: float) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = seconds
	node.add_child(timer)
	timer.timeout.connect(node.queue_free)
	timer.start()
