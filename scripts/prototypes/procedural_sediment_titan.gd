class_name ProceduralSedimentTitan
extends CharacterBody3D

signal died(enemy: Node3D)
signal crystal_broken(enemy: Node3D)

const HealthUtil := preload("res://scripts/health_util.gd")
const Nav := preload("res://scripts/nav_steering.gd")
const GroundMovement := preload("res://scripts/ground_movement.gd")
const JumpLanding := preload("res://scripts/jump_landing.gd")
const JumpMelee := preload("res://scripts/jump_melee.gd")
const SpatialQuery := preload("res://scripts/spatial_query.gd")
const SpatialProfile := preload("res://scripts/combat_spatial_profile.gd")
@export var combat_spatial_profile: SpatialProfile = preload("res://data/combat_spatial/jump_break.tres")
const Destruction := preload("res://scripts/environment_destruction.gd")
const Reactions := preload("res://scripts/combat_reactions.gd")
var _jump_environment_spent := false
var _sweep_destroyed := false
var _jump_melee := JumpMelee.new()
var _steering := Nav.new()
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
const EventBus := preload("res://scripts/event_bus.gd")
const WaveDirector := preload("res://scripts/wave_director.gd")
var _crowd := Crowd.new()
var _brain := Brain.new()
var _rage_director := preload("res://scripts/prototypes/titan_rage_director.gd").new()

enum State { SPAWN, IDLE, CHASE, ATK_SLAM, ATK_SWEEP, CAST_SHIELD, DEAD, LEAP_WINDUP, LEAP_AIR, LEAP_RECOVERY, JUMP_ATTACK, GROUP_REST, REWARD_LOWER, REWARD_HOLD, REWARD_RISE, REWARD_LANDING, ATK_THRUST, ATK_TRIPLE_SLAM }
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
	get: return move_speed * (rage_speed_multiplier if is_enraged else 1.0) * (_p("rage_gap_close_speed") if _rage_director.gap_close_active else 1.0)
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
var _bullet_hitstop_remaining := 0.0
var _heavy_recovery_scale := 1.0
var _leap_followup_armed := false
var _leap_link_gap := 0.0
var _thrust_windup := 0.0
## 仅保留出土/转阶段准备等待及旧调试入口；招式频率由 _brain 分别管理。
var _active_skill := ""
var _hit_landed := false
var _selection_reason := "manual"
var _breach_target: WeakRef
var _decision_timer := 0.0
## 仅陪练挂记录器时更新；记录真实分支，不额外执行选招或物理查询。
var _sparring_trace: Dictionary = {}
var _sparring_decision: Dictionary = {}
var _in_melee := false
var _target_sample: Node3D
var _target_last_position := Vector3.ZERO
var _target_velocity := Vector3.ZERO
var _attack_elapsed := 0.0
var _leap_plan: Dictionary = {}
var _leap_elapsed := 0.0
var _leap_landing := Vector3.ZERO
var _leap_ground := Vector3.ZERO
var _leap_origin := Vector3.ZERO
var _leap_flight := 1.0
var _leap_arc_height := 0.0
var _leap_plan_failure := ""
var _air_debris: CPUParticles3D
var _flight_shadow: MeshInstance3D
var _left_arm_mesh: MeshInstance3D
var _sweep_fx: Node3D
var _sweep_progress := 0.0
var _sweep_recovery_from := Transform3D.IDENTITY
var _action_tween: Tween
var _grenade_pause := preload("res://scripts/grenade_action_pause.gd").new()
var _player_separation := preload("res://scripts/airborne_player_separation.gd").new()
var _core_tween: Tween
var _collision: CollisionShape3D
var _head_collision: CollisionShape3D
var _health_label: Label3D
var _push_velocity := Vector3.ZERO
var _formal_boss := false
var _formal_boss_title := "沉积泰坦"
var _formal_boss_bar_active := false
var _opening_leap_pending := false
var _heavy_window := false
var _heavy_recovering := false
var _group_rest_remaining := 0.0
var _shield_hits := 0
var _shield_explosions: Dictionary = {}
var _reward_kind := ""
var _pending_reward := ""
var _reward_elapsed := 0.0
var _reward_durations: Dictionary = {}
var _pending_rage := false
var _shield_cracks: Array[MeshInstance3D] = []
var _crystal_hits := 0
var _crystal_shots: Dictionary = {}
var _crystal_guard_remaining := 0.0
var _crystal_break_pending := false
var _crystal_clock := 0.0
var _crystal_guard: Area3D
var _crystal_guard_visual: MeshInstance3D
var _reward_body_area: Area3D
var _reward_head_area: Area3D
var _weapon_regions := preload("res://scripts/weapon_hit_regions.gd").new()
var _crystal_hint: Label3D
var _last_weapon_feedback: Dictionary = {}
var _break_hud_timer := 0.0
var _reward_damage_multiplier := 1.0
const STANDING_VISUAL_Y := -1.6
const LEAP_LANDING_CLEARANCE := 0.04
const LEAP_LANDING_CONTACT_DEPTH := 0.12


func _ready() -> void:
	_formal_boss = bool(get_meta(&"formal_boss", false))
	_formal_boss_title = String(get_meta(&"formal_boss_title", "沉积泰坦"))
	_tuning = Tuning.resolve(self, PROFILE_ID)
	if _tuning.is_empty():
		queue_free()
		return
	_crowd.setup(self, _tuning, PROFILE_ID)
	_tuning = _crowd.varied_values(_tuning, ["move_speed"], ["slam_damage", "sweep_damage", "leap_damage", "thrust_damage"],
		["slam_windup", "slam_swing", "slam_sink_time", "slam_hold", "slam_recovery", "slam_cooldown",
		"sweep_windup", "sweep_swing", "sweep_recovery", "sweep_cooldown",
		"leap_windup", "leap_landing_hold", "leap_recovery", "leap_cooldown"])
	_brain.setup(_tuning)
	_rage_director.setup(self)
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
	_setup_crystal_guard()
	_setup_reward_hitboxes()
	for part: MeshInstance3D in destructible_parts:
		_weapon_regions.add_part(self, part, "crystal" if part == core_mesh else "body")
	_steering.setup(self, 1.4, 3.4)
	_steering.spatial.bind(_tuning, {"remaining": _spatial_remaining, "consume": _spatial_consume, "can_attack": _spatial_can_attack, "attack_pose": _spatial_attack_pose, "break_action": _spatial_break_action})
	_setup_telegraphs()
	_setup_leap_visuals()
	_health_label = Label3D.new()
	_health_label.name = "HealthLabel"
	_health_label.position.y = 3.1
	_health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_health_label.font_size = 28
	_health_label.pixel_size = 0.008
	add_child(_health_label)
	_health_label.visible = not _formal_boss
	_update_health_label()
	if _formal_boss:
		add_to_group("boss")
		for player in get_tree().get_nodes_in_group("player"):
			if player.has_method("enter_titan_grenade_reserve"):
				player.call("enter_titan_grenade_reserve", self, get_grenade_resource_config())
		_publish_formal_boss_health()
	_opening_leap_pending = _formal_boss and bool(_tuning.get("opening_leap", false))
	_mud_shield_cooldown = randf_range(_p("mud_shield_first_min"), _p("mud_shield_first_max"))
	_play_spawn_animation()


func _exit_tree() -> void:
	if _formal_boss:
		for player in get_tree().get_nodes_in_group("player"):
			if player.has_method("leave_titan_grenade_reserve"):
				player.call("leave_titan_grenade_reserve", self)
	_player_separation.clear(self)
	_hide_formal_boss_health()


func get_grenade_resource_config() -> Dictionary:
	var values := {}
	for key in ["grenade_reserve_enabled", "grenade_reserve_capacity", "grenade_reserve_start", "grenade_throw_interval", "grenade_recharge_seconds"]:
		values[key] = _tuning[key]
	return values

func prepare_sparring_phase(phase: String) -> bool:
	# 调试场景在首次开战前调用；正式流程不调用，也不伪造玩家伤害／破解收益。
	if phase == "full":
		return true
	if phase not in ["front", "rage"] or current_state != State.SPAWN:
		return false
	_stop_action()
	visual_root.position.y = STANDING_VISUAL_Y
	current_state = State.IDLE
	_opening_leap_pending = false
	attack_cooldown = 0.0
	if phase == "rage":
		current_hp = max_hp * maxf(rage_health_ratio - 0.01, 0.01)
		_trigger_rage()
		# 准备时已经是目标阶段的稳定外形，避免暂停时等变身 Tween。
		if _core_tween != null and _core_tween.is_valid():
			_core_tween.kill()
		core_mesh.scale = Vector3.ONE * rage_crystal_size
		head_pivot.position.y = 1.9
		_health_label.position.y = 4.2
	else:
		_activate_mud_shield()
	_update_health_label()
	_publish_formal_boss_health()
	return true

func _p(key: String) -> float:
	return float(_tuning[key])


func _physics_process(delta: float) -> void:
	_bullet_hitstop_remaining = maxf(_bullet_hitstop_remaining - delta, 0.0)
	_player_separation.step(self, current_state in [State.LEAP_AIR, State.REWARD_LANDING])
	if has_meta(&"combat_recorder"):
		_sparring_trace = {"engine_frame": Engine.get_physics_frames(), "branch": "locomotion", "desired": [0.0, 0.0, 0.0]}
	if current_state == State.DEAD:
		return
	_tick_crystal(delta)
	_break_hud_timer -= delta
	if _break_hud_timer <= 0.0:
		_break_hud_timer = 0.1
		_update_crystal_hint()
		_publish_formal_boss_health()
	if current_state == State.REWARD_LANDING:
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y -= _p("gravity") * delta
		GroundMovement.move(self, delta, false)
		_head_collision.position = to_local(core_mesh.global_position)
		if is_on_floor():
			_start_reward(_pending_reward)
		return
	if not _reward_kind.is_empty():
		_tick_reward(delta)
		return
	if _grenade_pause.step(delta, current_state not in [State.SPAWN, State.LEAP_AIR, State.JUMP_ATTACK], _action_tween):
		if not _sparring_trace.is_empty():
			_sparring_trace.branch = "grenade_stagger"
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y = -0.5 if is_on_floor() and velocity.y <= 0.0 else velocity.y - _p("gravity") * delta
		GroundMovement.move(self, delta, false)
		return
	_crowd.tick(delta)
	_brain.tick(delta)
	_rage_director.tick(delta)
	_sample_target_velocity(delta)
	_decision_timer = maxf(_decision_timer - delta, 0.0)
	anim_clock += delta * _crowd.gait_multiplier
	# 自转不再依赖待机动画，追击和攻击过程中也持续旋转。
	core_mesh.rotate_y(deg_to_rad(_p("crystal_spin_speed")) * delta * (rage_spin_multiplier if is_enraged else 1.0))
	if not (is_enraged and bool(_tuning.crystal_break_enabled)):
		_core_light.light_energy = (1.2 if is_enraged else 0.4) * (1.0 + sin(anim_clock * 9.0) * 0.12)
	_update_mud_shield(delta)
	attack_cooldown = maxf(attack_cooldown - delta, 0.0)
	if current_state == State.GROUP_REST:
		_group_rest_remaining = maxf(_group_rest_remaining - delta, 0.0)
		if _group_rest_remaining <= 0.0:
			current_state = State.IDLE
	if current_state in [State.IDLE, State.CHASE] and _brain.link_expired(delta):
		_brain.finish_group("link_timeout")
		current_state = State.GROUP_REST
		_group_rest_remaining = _p("offense_failed_rest")
	_track_melee_attack(delta)
	if current_state == State.ATK_TRIPLE_SLAM:
		_rage_director.tick_triple_slam(delta)
	if current_state == State.LEAP_AIR:
		if not _sparring_trace.is_empty():
			_sparring_trace.branch = "leap_air"
		_update_leap_air(delta)
		_head_collision.position = to_local(core_mesh.global_position)
		return
	if current_state == State.LEAP_WINDUP:
		if not _sparring_trace.is_empty():
			_sparring_trace.branch = "leap_windup"
		_leap_elapsed += delta
		# 起跳是战斗状态，不应只挂在动画 Tween 的完成回调上。开场加载时若 Tween
		# 被接管或回调丢失，旧实现会留下完整预警却永远不进入空中。物理计时现在
		# 是唯一权威，动画只负责表现。
		if _leap_elapsed >= _p("leap_windup"):
			_launch_leap()
			_update_leap_air(delta)
			_head_collision.position = to_local(core_mesh.global_position)
			return
	if ai_enabled and _crowd.ready_to_move() and _target_alive() and current_state in [State.IDLE, State.CHASE]:
		var chase_distance := Vector2(target.global_position.x - global_position.x, target.global_position.z - global_position.z).length()
		_brain.observe_chase(delta, chase_distance, _in_melee)
	if _steering.tick(delta, ai_enabled and _crowd.ready_to_move() and current_state in [State.IDLE, State.CHASE] and attack_cooldown <= 0.0, target, effective_move_speed):
		if not _sparring_trace.is_empty():
			_sparring_trace.branch = "navigation_override"
		_animate_walk(anim_clock)
		_head_collision.position = to_local(core_mesh.global_position)
		return
	var desired := Vector3.ZERO
	if not _sparring_trace.is_empty():
		_sparring_trace["gate"] = "ai_disabled" if not ai_enabled else "activation_wait" if not _crowd.ready_to_move() else "action_state" if current_state not in [State.IDLE, State.CHASE] else "target_missing" if not _target_alive() else "attack_cooldown" if attack_cooldown > 0.0 else "decision_interval" if _decision_timer > 0.0 else "ready"
	if ai_enabled and _crowd.ready_to_move() and current_state in [State.IDLE, State.CHASE]:
		if not _target_alive():
			target = Targeting.nearest_player(self)
		if _target_alive() and _opening_leap_pending and _decision_timer <= 0.0:
			# 尚无合法落点时沿正常选招节奏重试，避免每个物理帧做完整弹道扫描。
			# 失败后仍允许本轮普通选招；不能先重置计时，把所有其他技能永久饿死。
			_selection_reason = "opening_leap"
			if trigger_leap_attack():
				_opening_leap_pending = false
		if _target_alive() and current_state in [State.IDLE, State.CHASE]:
			var offset := target.global_position - global_position
			offset.y = 0.0
			var distance := offset.length()
			var above := _target_above()
			var routing := above or _steering.needs_route(target.global_position)
			var ordinary_range := above and JumpMelee.can_start(self, target, _normal_attack_spec())
			var near_limit := _p("near_exit_distance") if _in_melee else _p("near_enter_distance")
			_in_melee = not routing and distance <= near_limit and absf(target.global_position.y - global_position.y) <= 2.5 * _crowd.size_multiplier
			if distance > 0.001:
				rotation.y = rotate_toward(rotation.y, atan2(-offset.x, -offset.z), turn_speed * delta * (rage_speed_multiplier if is_enraged else 1.0))
			if attack_cooldown <= 0.0 and _decision_timer <= 0.0:
				_decision_timer = 0.18
				_select_attack(distance)
				if current_state not in [State.IDLE, State.CHASE]:
					_opening_leap_pending = false
			if current_state in [State.IDLE, State.CHASE] and not ordinary_range and (routing or distance > _p("near_enter_distance")):
				_set_locomotion(State.CHASE)
				desired = _crowd.steer(-global_basis.z * effective_move_speed, target.global_position, delta)
				desired = _steering.ground_velocity(target.global_position, desired, delta)
				if not desired.is_zero_approx():
					rotation.y = rotate_toward(rotation.y, atan2(-desired.x, -desired.z), turn_speed * delta * (rage_speed_multiplier if is_enraged else 1.0))
			elif current_state in [State.IDLE, State.CHASE]:
				_set_locomotion(State.IDLE)
		elif current_state in [State.IDLE, State.CHASE]:
			_set_locomotion(State.IDLE)
	match current_state:
		State.IDLE:
			_animate_idle(anim_clock)
		State.CHASE:
			_animate_walk(anim_clock)
	_head_collision.position = to_local(core_mesh.global_position)
	# 出土、技能和硬直期间也保留重力，视觉位移与身体碰撞互不干扰。
	if current_state == State.LEAP_WINDUP or _heavy_window or current_state == State.GROUP_REST:
		# 已公布的跃击不受普通推力改变起跳位置；保留重力与地面碰撞。
		velocity.x = 0.0
		velocity.z = 0.0
	else:
		velocity.x = move_toward(velocity.x, desired.x + _push_velocity.x, delta * _p("acceleration"))
		velocity.z = move_toward(velocity.z, desired.z + _push_velocity.z, delta * _p("acceleration"))
	_push_velocity = _push_velocity.move_toward(Vector3.ZERO, delta * _p("push_decay"))
	if not _sparring_trace.is_empty():
		_sparring_trace.desired = [desired.x, desired.y, desired.z]
	velocity.y = -0.5 if is_on_floor() and velocity.y <= 0.0 else velocity.y - _p("gravity") * delta
	GroundMovement.move(self, delta, current_state != State.JUMP_ATTACK)
	if current_state == State.JUMP_ATTACK:
		if _pending_reward.is_empty() and not _jump_environment_spent and _jump_melee.in_strike_window(delta):
			_jump_environment_spent = true
			var spec := _normal_attack_spec()
			_attack_area.prepare(global_transform, {"kind": "sector", "radius": spec.reach,
				"angle": 180.0, "height": spec.height, "ground_effect": false}, 0.0)
			_attack_area.lock()
			if _attack_area.strike():
				Destruction.shape_impact(_attack_area, _p("normal_break_power"))
		if _jump_melee.advance(delta) and _pending_reward.is_empty():
			Telemetry.hurt_player(_attack_target, _p("normal_attack_damage") * _damage_scale, global_position, 1.0, Telemetry.source_info(self, "泰坦跳跃普攻"))
		if _jump_melee.finished():
			if not _pending_reward.is_empty():
				_start_reward(_pending_reward)
			else:
				_finish_action(_p("normal_attack_interval"))


func _sparring_rejected(reason: String) -> bool:
	if has_meta(&"combat_recorder"):
		_sparring_decision["begin_rejected"] = reason
	return false


func get_sparring_diagnostic() -> Dictionary:
	# 只读缓存与上一轮物理接触；不调用选招、规划、get_next_path_position。
	var contacts: Array = []
	for index in range(mini(get_slide_collision_count(), 4)):
		var hit := get_slide_collision(index)
		var normal := hit.get_normal()
		var collider := hit.get_collider()
		contacts.append({"normal": [normal.x, normal.y, normal.z], "collider": str(collider.get_path()) if collider is Node else str(collider)})
	return {"trace": _sparring_trace.duplicate(true), "decision": _sparring_decision.duplicate(true),
		"on_floor": is_on_floor(), "ai_enabled": ai_enabled, "activation_ready": _crowd.ready_to_move(),
		"target_alive": _target_alive(), "attack_cooldown": attack_cooldown, "decision_timer": _decision_timer,
		"cooldowns": _brain.cooldowns.duplicate(), "approach_remaining": _brain.approach_remaining,
		"active_skill": _active_skill, "rhythm": _brain.rhythm_snapshot(),
		"rage_director": _rage_director.snapshot(),
		"break_reward": get_break_reward_status(),
		"heavy_window": _heavy_window, "heavy_recovering": _heavy_recovering, "group_rest_remaining": _group_rest_remaining,
		"heavy_recovery_scale_snapshot": _heavy_recovery_scale,
		"landing_followup_armed": _leap_followup_armed, "landing_link_gap_snapshot": _leap_link_gap,
		"bullet_hitstop_remaining": _bullet_hitstop_remaining,
		"contacts": contacts, "navigation": _steering.get_sparring_diagnostic(),
		"motion": get_meta(&"sparring_motion", {}),
		"physics_enabled": is_physics_processing(), "process_enabled": is_processing(), "process_mode": process_mode, "time_scale": Engine.time_scale,
		"hitstop_restore": get_meta(&"hitstop_restore", {}), "hitstop_token": get_meta(&"hitstop_token", 0)}


func _target_alive() -> bool:
	return HealthUtil.is_alive(target)


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
	_rage_director.clear_triple_slam()
	_leap_followup_armed = false
	_heavy_recovery_scale = 1.0
	_breach_target = null
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
	_heavy_window = false
	_heavy_recovering = false


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
	if _rage_director.enabled() and not _target_above():
		_select_directed_rage(distance)
		return
	# 高处先判断能否完整落脚；不能上台时用跳跃普攻，不反复释放跃击。
	var above := _target_above()
	if has_meta(&"combat_recorder"):
		_sparring_decision = {"engine_frame": Engine.get_physics_frames(), "distance": distance, "above": above, "on_floor": is_on_floor(), "leap_planned": false}
	_leap_plan.clear()
	if bool(_tuning.leap_enabled) and is_on_floor() and _brain.available("leap") \
		and (above or _brain.wants_approach(distance)):
		_leap_plan = _plan_leap()
		if not _sparring_decision.is_empty():
			_sparring_decision.leap_planned = true
			_sparring_decision["leap_rejection"] = _leap_plan_failure
	if above and not _brain.needs_heavy(is_enraged) and (_leap_plan.is_empty() or not _brain.available("leap")) and trigger_jump_attack():
		if not _sparring_decision.is_empty():
			_sparring_decision["selected"] = "jump_melee"
		return
	var candidates := {}
	var size := _crowd.size_multiplier
	var height_ok := absf(target.global_position.y - global_position.y) <= 2.5 * size
	var away := target.global_position - global_position
	away.y = 0.0
	var retreat_speed := maxf(_target_velocity.dot(away.normalized()), 0.0)
	if not above and height_ok and AttackArea.unobstructed(self, global_position, target.global_position):
		if not _sparring_decision.is_empty():
			_sparring_decision["melee_line_clear"] = true
		if distance + retreat_speed * (_p("slam_windup") * 0.35 + _p("slam_swing")) <= _p("slam_distance") * attack_range_scale * size:
			var can_slam := AttackArea.candidate_can_hit(self, global_transform, _slam_spec(), target)
			if not _sparring_decision.is_empty():
				_sparring_decision["slam_geometry_valid"] = can_slam
			if can_slam:
				candidates.slam = 1.1 if distance > _p("sweep_preferred_distance") * attack_range_scale * size else 1.0
		if distance + retreat_speed * (_p("sweep_windup") * 0.35 + _p("sweep_swing")) <= _p("sweep_distance") * attack_range_scale * size:
			var can_sweep := AttackArea.candidate_can_hit(self, global_transform, _sweep_spec(), target)
			if not _sparring_decision.is_empty():
				_sparring_decision["sweep_geometry_valid"] = can_sweep
			if can_sweep:
				candidates.sweep = 1.3
		if bool(_tuning.thrust_enabled) and AttackArea.candidate_can_hit(self, global_transform, _thrust_spec(), target):
			candidates.thrust = 2.5
	if not _leap_plan.is_empty() and _steering.spatial.permits_channel(&"leap"):
		candidates.leap = 2.0
	if _brain.rhythm_enabled():
		# 合法性由上面的地形／射程检查决定；只约束攻势，不强迫无落点跃击。
		if _brain.needs_heavy(is_enraged):
			candidates.erase("sweep")
			candidates.erase("thrust")
		elif candidates.has("sweep") and _brain.available("sweep"):
			candidates.sweep = 4.0

	var skill := _brain.choose(candidates)
	if not _sparring_decision.is_empty():
		_sparring_decision["candidates"] = candidates.duplicate()
		_sparring_decision["selected"] = skill
		_sparring_decision["height_ok"] = height_ok
		_sparring_decision["retreat_speed"] = retreat_speed
		_sparring_decision["slam_reach"] = _p("slam_distance") * attack_range_scale * size
		_sparring_decision["sweep_reach"] = _p("sweep_distance") * attack_range_scale * size
		_sparring_decision["melee_gate"] = "target_above" if above else "height_mismatch" if not height_ok else "checked" if _sparring_decision.get("melee_line_clear", false) else "obstructed"
		_sparring_decision["reason"] = "no_legal_candidate" if skill.is_empty() else "selected"
	_selection_reason = "far_distance" if _brain.far_time >= _p("far_confirm_time") else "chase_failed" if skill == "leap" else "near_distance"
	match skill:
		"slam": trigger_slam_attack()
		"sweep": trigger_sweep_attack()
		"leap": trigger_leap_attack()
		"thrust": trigger_thrust_attack()


func _select_directed_rage(distance: float) -> void:
	var choice: String = _rage_director.choose(distance)
	if has_meta(&"combat_recorder"):
		_sparring_decision = {"engine_frame":Engine.get_physics_frames(),"distance":distance,"selected":choice,"reason":_rage_director.intent,"candidates":{},"director":true}
	_selection_reason = _rage_director.intent
	match choice:
		"triple_slam":
			if trigger_triple_slam_attack(): return
		"sweep":
			if AttackArea.candidate_can_hit(self,global_transform,_sweep_spec(),target):
				trigger_sweep_attack()
		"leap":
			if trigger_leap_attack(): return
			_rage_director.leap_failed()
		"rest":
			_brain.finish_group("directed_unavailable")
			_rage_director.interrupt()
			current_state = State.GROUP_REST
			_group_rest_remaining = _p("offense_failed_rest")
	# 未能规划跃击/被遮挡时仍沿既有地面/空间移动，不隔墙出招。


func _track_melee_attack(delta: float) -> void:
	if current_state not in [State.ATK_SLAM, State.ATK_SWEEP] or _attack_area.phase != AttackArea.Phase.PREPARE:
		return
	if _breach_target != null:
		_attack_elapsed += delta
		if _attack_elapsed >= _p("slam_windup") * 0.65:
			_attack_area.lock()
		return
	if not HealthUtil.is_alive(_attack_target):
		# 目标消失也执行已经公布的招式，停止追踪并沿当前方向挥空。
		_attack_area.lock()
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
	var minimum := 0.5 if _target_above() else _p("leap_min_distance")
	if distance < minimum or distance > _p("leap_max_distance"):
		_leap_plan_failure = "distance"
		return {}
	var flight := clampf(distance / _p("leap_travel_speed"), _p("leap_min_flight"), _p("leap_max_flight"))
	# 在预警出现前完成运动预判、落脚与通道检查，之后不再追踪目标。
	# 新狂暴预判覆盖“起手+飞行”，而非漏掉整段蓄力；仍只用已观察速度，预警后不修正。
	var horizon := flight+_p("leap_windup") if _rage_director.enabled() else flight
	var lead_limit := _p("rage_leap_lead_limit") if _rage_director.enabled() else _p("leap_lead_limit")
	var aim := target.global_position + (_target_velocity * horizon * _p("leap_lead_ratio")).limit_length(lead_limit)
	# 新选位不能把追不上目标的预测点截成一次注定落后的跳跃：先继续地面接近。
	# 原型/旧对照仍保留原截断语义；预警出现后的落点固定规则不变。
	if _rage_director.enabled() and Vector2(aim.x-global_position.x,aim.z-global_position.z).length() > _p("leap_max_distance"):
		_leap_plan_failure = "predicted_out_of_reach"
		return {}
	var flat_aim := Vector3(aim.x - global_position.x, 0.0, aim.z - global_position.z).limit_length(_p("leap_max_distance"))
	aim.x = global_position.x + flat_aim.x
	aim.z = global_position.z + flat_aim.z
	var breakable := Destruction.breakable_rids(self, _p("leap_break_power"))
	var supports := SpatialQuery.landing_candidates(self, target, _steering.spatial.profile.candidate_radius)
	if supports.is_empty():
		_leap_plan_failure = "no_floor_or_slope"
		return {}
	# 预判位置以真实支撑层为基准；不从头顶穿过其他楼层寻找首个表面。
	var expected: Vector3 = supports[0].position
	var predicted := SpatialQuery.floor_at(self, Vector3(aim.x, expected.y, aim.z), 7.0, breakable)
	if not predicted.is_empty():
		supports.push_front(predicted)
	for hit in supports:
		var after_break := SpatialQuery.floor_at(self, hit.position, 7.0, breakable)
		if after_break.is_empty() or (after_break.normal as Vector3).y < 0.75:
			continue
		var plan := _plan_leap_landing(after_break, minimum, breakable)
		if not plan.is_empty():
			return plan
	return {}


func _plan_leap_landing(hit: Dictionary, minimum: float, breakable: Array[RID]) -> Dictionary:
	var ground: Vector3 = hit.position
	if not JumpLanding.supported(self, ground, hit.normal, _collision.shape, _collision.global_basis, breakable):
		_leap_plan_failure = "landing_too_small"
		return {}
	var size := _crowd.size_multiplier
	# 圆柱底面接触斜坡时需留出半径对应的高差，不能只按中心射线放置身体。
	var normal: Vector3 = hit.normal
	var slope_clearance := 1.4 * size * Vector2(normal.x, normal.z).length() / normal.y
	var landing := ground + Vector3.UP * (1.7 * size + slope_clearance + LEAP_LANDING_CLEARANCE)
	if not SpatialQuery.landing_clear(self, landing):
		_leap_plan_failure = "landing_occupied"
		return {}
	if absf(landing.y - global_position.y) > _p("leap_max_elevation"):
		_leap_plan_failure = "elevation"
		return {}
	var distance := Vector2(landing.x - global_position.x, landing.z - global_position.z).length()
	if distance > _p("leap_max_distance") or distance < minimum:
		_leap_plan_failure = "predicted_distance"
		return {}
	var flight := clampf(distance / _p("leap_travel_speed"), _p("leap_min_flight"), _p("leap_max_flight"))
	# 飞行时长承担躲避窗口，弧顶高度承担“确实跳起来”的可读性，二者不能再由
	# 同一个全局重力偶然决定。高度按体型缩放，使正式巨型 Boss 仍有清晰离地量。
	var arc_height := _p("leap_arc_height") * size
	if not _arc_clear(global_position, landing, arc_height, breakable):
		return {}
	if not _steering.spatial.permit_landing(landing, &"jump", breakable, false):
		_leap_plan_failure = "no_exit_proof"
		return {}
	_leap_plan_failure = ""
	return {"ground": ground, "landing": landing, "flight": flight,
		"arc_height": arc_height, "breakable": breakable}


func _target_above() -> bool:
	return _target_above_at(global_transform)


func _target_above_at(pose: Transform3D) -> bool:
	if not _target_alive():
		return false
	var support := SpatialQuery.support(target)
	return not support.is_empty() and float(support.position.y) > pose.origin.y - float(SpatialQuery.dimensions(self).half_height) + 0.4


func _normal_attack_spec() -> Dictionary:
	return {"reach": _p("normal_attack_reach") * _crowd.size_multiplier, "height": _p("normal_attack_height") * _crowd.size_multiplier,
		"jump_speed": _p("normal_jump_speed"), "gravity": _p("gravity")}


func trigger_jump_attack() -> bool:
	if _brain.needs_heavy(is_enraged):
		return false
	if current_state not in [State.IDLE, State.CHASE] or attack_cooldown > 0.0 or not JumpMelee.can_start(self, target, _normal_attack_spec()):
		return false
	_stop_action()
	if not _crowd.request_attack():
		return false
	_reset_pose()
	_active_skill = ""
	_attack_target = target
	current_state = State.JUMP_ATTACK
	attack_cooldown = _p("normal_attack_interval")
	var offset := target.global_position - global_position
	rotation.y = atan2(-offset.x, -offset.z)
	_jump_melee.begin(self, target, _normal_attack_spec())
	_jump_environment_spent = false
	_brain.commit_offense(is_enraged, false)
	var flight := 2.0 * _p("normal_jump_speed") / _p("gravity")
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees:x", -95.0, flight * 0.3)
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees:x", 35.0, flight * 0.4)
	return true


func _arc_clear(origin: Vector3, landing: Vector3, arc_height: float,
		breakable: Array[RID] = []) -> bool:
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
			var progress := float(i) / 18.0
			var arc_exclude: Array[RID] = [get_rid()]
			# 只有下落重砸能破坏，上升时的柱子和天花板仍须避开。
			if progress >= 0.5:
				arc_exclude.append_array(breakable)
			shape_query.exclude = arc_exclude
			var next := origin.lerp(landing, progress) \
				+ Vector3.UP * (4.0 * arc_height * progress * (1.0 - progress)) \
				+ (part.offset as Vector3)
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
	if current_state not in [State.IDLE, State.CHASE] or not bool(_tuning.leap_enabled) or not is_on_floor():
		return _sparring_rejected("leap_state_disabled_or_not_on_floor")
	# 出土准备等待和技能冷却期间，不为必然被 _begin_attack 拒绝的动作重复扫描地形。
	if attack_cooldown > 0.0 or not _brain.available("leap") \
		or not _steering.spatial.permits_channel(&"leap"):
		return _sparring_rejected("leap_cooldown_or_reserved_channel")
	# 选招候选可能已经过时；在显示任何效果之前确认最终可执行计划。
	var plan := _plan_leap()
	var link := bool(_tuning.leap_followup_enabled) and bool(_tuning.thrust_enabled) and _brain.rhythm_enabled() and not _brain.needs_heavy(is_enraged) and _brain.available("thrust")
	if plan.is_empty() or not _begin_attack(State.LEAP_WINDUP, not link):
		if has_meta(&"combat_recorder") and plan.is_empty():
			_sparring_decision["begin_rejected"] = "leap_plan:" + _leap_plan_failure
		return false
	_leap_followup_armed = link
	_leap_link_gap = _p("rage_leap_link_gap" if is_enraged else "leap_link_gap")
	# 开场承诺时快照；中途半血不会缩短原本的收势／衔接。
	_heavy_recovery_scale = _p("rage_heavy_recovery_scale") if is_enraged else 1.0
	_steering.spatial.permit_landing(plan.landing, &"jump", plan.breakable)
	_leap_plan = plan
	_leap_elapsed = 0.0
	_attack_area.prepare(Transform3D(Basis.IDENTITY, plan.ground), {"kind": "circle", "radius": _p("leap_radius") * _crowd.size_multiplier,
		"height": 3.0 * _crowd.size_multiplier, "ally_height": 6.0 * _crowd.size_multiplier,
		"source_height": 0.2, "affects_allies": true, "exclude_bodies": plan.breakable},
		_p("leap_damage") * _damage_scale, _p("leap_windup") + float(plan.flight))
	_attack_area.lock()
	var facing: Vector3 = plan.landing - global_position
	rotation.y = atan2(-facing.x, -facing.z)
	Audio.play_at("titan_charge", global_position, -8.0)
	GroundEffect.spawn(get_tree().current_scene, global_position - Vector3.UP * 1.7 * _crowd.size_multiplier,
		1.9 * _crowd.size_multiplier, 0.25, true, 0.0, true)
	_action_tween.tween_property(torso_pivot, "position:y", 1.2, _p("leap_windup"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", -18.0, _p("leap_windup"))
	_action_tween.parallel().tween_property(right_arm_pivot, "rotation_degrees:x", -85.0, _p("leap_windup"))
	_action_tween.parallel().tween_property(left_arm_pivot, "rotation_degrees:x", -45.0, _p("leap_windup"))
	_action_tween.parallel().tween_property(left_leg_pivot, "rotation_degrees:x", -30.0, _p("leap_windup"))
	_action_tween.parallel().tween_property(right_leg_pivot, "rotation_degrees:x", -30.0, _p("leap_windup"))
	return true


func _launch_leap() -> void:
	if current_state != State.LEAP_WINDUP:
		return
	# 预警就是施放承诺；使用已确认计划，不根据玩家的新位置重新判定。
	var plan := _leap_plan
	_leap_ground = plan.ground
	_leap_landing = plan.landing
	_leap_origin = global_position
	_leap_flight = plan.flight
	_leap_arc_height = plan.arc_height
	current_state = State.LEAP_AIR
	_player_separation.begin(self)
	_air_debris.emitting = true
	# 空中的重砸使用区域命中，玩家实体不能成为提前落地的平台。
	collision_mask = 1
	_leap_elapsed = 0.0
	velocity = Vector3.ZERO
	GroundEffect.spawn(get_tree().current_scene, global_position - Vector3.UP * 1.7 * _crowd.size_multiplier,
		2.3 * _crowd.size_multiplier, 0.7, true, _p("ground_shake_strength"))


func _update_leap_air(delta: float) -> void:
	_leap_elapsed += delta
	var progress := clampf(_leap_elapsed / _leap_flight, 0.0, 1.0)
	# 规划点保留少量安全间隙；运行轨迹的末点压回真实接触高度，确保最后一帧
	# 仍有向下运动并由 move_and_slide 建立 is_on_floor，而不是悬在间隙上收招。
	var contact_landing := _leap_landing - Vector3.UP * LEAP_LANDING_CONTACT_DEPTH
	var planned_position := _leap_origin.lerp(contact_landing, progress) \
		+ Vector3.UP * (4.0 * _leap_arc_height * progress * (1.0 - progress))
	velocity = (planned_position - global_position) / maxf(delta, 0.0001)
	if velocity.y < 0.0:
		Destruction.break_contacts(self, velocity * delta, _p("leap_break_power"))
	move_and_slide()
	_update_flight_shadow()
	torso_pivot.position.y = lerpf(1.45, 1.75, sin(progress * PI))
	right_arm_pivot.rotation_degrees.x = lerpf(-130.0, 65.0, pow(progress, 3.0))
	left_leg_pivot.rotation_degrees.x = lerpf(-40.0, 15.0, progress)
	right_leg_pivot.rotation_degrees.x = lerpf(-40.0, 15.0, progress)
	var blocked := false
	for i in range(get_slide_collision_count()):
		if (get_slide_collision(i).get_normal()).y < 0.7:
			blocked = true
	# 落点可能同时存在被本次重砸刚刚破坏的掩体接触；规划轨迹已经抵达合法
	# 落脚体积时，比同帧残留的侧向碰撞更权威，否则会在正确落点误报 blocked。
	var landing_distance := global_position.distance_to(_leap_landing)
	var landing_flat_distance := Vector2(global_position.x - _leap_landing.x,
		global_position.z - _leap_landing.z).length()
	var reached_landing := _leap_elapsed > _leap_flight * 0.5 \
		and is_on_floor() and landing_flat_distance < 0.3 * _crowd.size_multiplier \
		and absf(global_position.y - _leap_landing.y) < 0.12
	if reached_landing:
		_land_leap(true)
	elif landing_distance < 0.9 * _crowd.size_multiplier \
		and _leap_elapsed <= _leap_flight + 0.1:
		# 破坏物的碰撞体可能在本帧末才退出；给规划终点数帧时间完成最后一小段。
		pass
	elif is_on_floor() and _leap_elapsed > _leap_flight * 0.5:
		_land_leap(false)
	elif blocked or is_on_ceiling():
		_land_leap(false)
	elif _leap_elapsed > _leap_flight + 0.8:
		_land_leap(false)


func _land_leap(valid: bool) -> void:
	if not _pending_reward.is_empty():
		_start_reward(_pending_reward)
		return
	_air_debris.emitting = false
	_flight_shadow.visible = false
	current_state = State.LEAP_RECOVERY
	collision_mask = 3
	velocity.x = 0.0
	velocity.z = 0.0
	if valid and _attack_area.phase == AttackArea.Phase.LOCKED:
		Destruction.radial_impact(self, _leap_ground, _p("leap_radius") * _crowd.size_multiplier,
			3.0 * _crowd.size_multiplier, _p("leap_break_power"))
		_attack_area.shape.erase("exclude_bodies")
		_attack_area.refresh_surface()
	if valid and _attack_area.strike():
		_hurt_target(_attack_area.damage, "泰坦蓄力跃击")
		Reactions.impact_allies(_attack_area, self, Telemetry.source_info(self, "泰坦蓄力跃击"))
		GroundEffect.spawn(get_tree().current_scene, _leap_ground, _p("leap_radius") * _crowd.size_multiplier,
			1.0, false, _p("ground_shake_strength"), false, _attack_area.get_surface())
	else:
		_brain.completed("blocked", false)
	_attack_area.recover()
	_heavy_recovering = _heavy_window
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	torso_pivot.position.y = 1.12
	torso_pivot.rotation_degrees.x = 22.0
	right_arm_pivot.rotation_degrees.x = 65.0
	if valid and _leap_followup_armed and _can_landing_thrust():
		_action_tween.tween_property(torso_pivot, "position:y", 1.8, _leap_link_gap)
		_action_tween.parallel().tween_property(torso_pivot, "rotation", Vector3.ZERO, _leap_link_gap)
		_action_tween.tween_callback(_finish_leap_link)
	else:
		# 落点失败、墙后或目标已离开：不跨地形强接，完整收招结束本组。
		_heavy_window = _brain.rhythm_enabled()
		_heavy_recovering = _heavy_window
		_leap_followup_armed = false
		_recover_leap_pose(_p("leap_landing_hold") * _heavy_recovery_scale)


func _can_landing_thrust() -> bool:
	if not _target_alive() or not is_on_floor() or not _brain.available("thrust"):
		return false
	var offset := target.global_position - global_position
	var pose := Transform3D(Basis(Vector3.UP, atan2(-offset.x, -offset.z)), global_position)
	return AttackArea.unobstructed(self, global_position, target.global_position) and AttackArea.candidate_can_hit(self, pose, _thrust_spec(), target)


func _finish_leap_link() -> void:
	if current_state != State.LEAP_RECOVERY or not _pending_reward.is_empty() or not _reward_kind.is_empty():
		return
	var can_link := _leap_followup_armed and _can_landing_thrust()
	_leap_followup_armed = false
	_finish_action(0.0)
	if can_link:
		_selection_reason = "landing_followup"
		if trigger_thrust_attack(true):
			return
	_brain.finish_group("landing_link_unavailable")
	current_state = State.GROUP_REST
	_group_rest_remaining = _p("offense_failed_rest")


func _recover_leap_pose(hold: float) -> void:
	var recovery := _p("leap_recovery") * _heavy_recovery_scale
	if hold > 0.0:
		_action_tween.tween_interval(hold)
	_action_tween.tween_property(torso_pivot, "position:y", 1.8, recovery).set_trans(Tween.TRANS_BACK)
	_action_tween.parallel().tween_property(torso_pivot, "rotation", Vector3.ZERO, recovery)
	for joint in [right_arm_pivot, left_arm_pivot, left_leg_pivot, right_leg_pivot]:
		_action_tween.parallel().tween_property(joint, "rotation", Vector3.ZERO, recovery)
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
	# 明亮裂纹分两级显示，随盾旋转；主动卸盾仅隐藏，不清进度。
	for index in range(6):
		var crack := MeshInstance3D.new()
		crack.name = "ShieldCrack%d" % index
		var crack_mesh := BoxMesh.new()
		crack_mesh.size = Vector3(0.035, 0.46, 0.07)
		crack.mesh = crack_mesh
		var crack_mat := StandardMaterial3D.new()
		crack_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		crack_mat.albedo_color = Color(1, 0.67, 0.19)
		crack.material_override = crack_mat
		var plate_index: int = [0, 3, 6, 1, 4, 7][index]
		var angle := float(plate_index) * TAU / 8.0
		crack.position = Vector3(cos(angle) * 1.75, 0.28 if plate_index % 2 == 0 else -0.28, sin(angle) * 1.75)
		crack.rotation = Vector3(0.35 if index % 2 == 0 else -0.4, -angle, 0)
		crack.visible = false
		mud_shield_visual.add_child(crack)
		_shield_cracks.append(crack)


func _update_mud_shield(delta: float) -> void:
	if is_enraged or (_heavy_window and bool(_tuning.heavy_sheds_shield)) or not _reward_kind.is_empty() or not _pending_reward.is_empty():
		if has_mud_shield:
			_remove_mud_shield()
		return
	if _brain.rhythm_enabled():
		# 正式前半全攻势常驻；仅破盾长奖励和狂暴允许解除。旧卸盾方案兼容。
		if has_mud_shield:
			mud_shield_visual.rotate_y(delta * _p("mud_shield_spin"))
		elif current_state in [State.IDLE, State.CHASE]:
			_activate_mud_shield()
		return
	if has_mud_shield:
		mud_shield_visual.rotate_y(delta * _p("mud_shield_spin"))
		_mud_shield_remaining = maxf(_mud_shield_remaining - delta, 0.0)
		if _mud_shield_remaining <= 0.0:
			_remove_mud_shield()
	if is_enraged or not bool(_tuning.mud_shield_enabled):
		return
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


func _activate_mud_shield(force := false) -> void:
	if is_enraged or (_heavy_window and bool(_tuning.heavy_sheds_shield)) or not _reward_kind.is_empty() or not _pending_reward.is_empty() or current_state == State.DEAD or not bool(_tuning.mud_shield_enabled) or has_mud_shield:
		return
	if not force and (is_enraged or current_state not in [State.IDLE, State.CHASE, State.CAST_SHIELD]):
		return
	has_mud_shield = true
	_mud_shield_remaining = mud_shield_duration
	_mud_shield_cooldown = randf_range(mud_shield_interval_min, mud_shield_interval_max)
	mud_shield_visual.visible = true
	_update_health_label()


func get_break_reward_status() -> Dictionary:
	return {"shield_hits": _shield_hits, "shield_required": int(_tuning.shield_grenade_hits),
		"kind": _reward_kind, "pending": _pending_reward, "state": current_state,
		"elapsed": _reward_elapsed, "durations": _reward_durations.duplicate(), "rage_pending": _pending_rage,
		"crystal_hits": _crystal_hits, "crystal_required": int(_tuning.crystal_sniper_hits),
		"crystal_guard_remaining": _crystal_guard_remaining, "crystal_break_pending": _crystal_break_pending}

func receive_grenade_contact(amount: float, explosion_id: int, context: Dictionary) -> void:
	var earned := false
	if bool(_tuning.shield_break_enabled) and has_mud_shield and not is_enraged and _reward_kind.is_empty() and _pending_reward.is_empty():
		if _shield_explosions.has(explosion_id):
			return
		_shield_explosions[explosion_id] = true
		_shield_hits += 1
		earned = _shield_hits >= int(_tuning.shield_grenade_hits)
		if earned:
			_pending_reward = "kneel" # 先锁定已挣得奖励，第三炸跨半血也不吞掉。
		_update_shield_cracks()
		_reward_feedback("泥盾 %d/%d" % [_shield_hits, int(_tuning.shield_grenade_hits)], Color(1, 0.65, 0.2))
	Telemetry.hurt_enemy(self, amount, context)
	if earned and current_state != State.DEAD:
		_request_reward("kneel")

func _update_shield_cracks() -> void:
	for index in range(_shield_cracks.size()):
		_shield_cracks[index].visible = _shield_hits > 0 and index < _shield_hits * 3

func _request_reward(kind: String) -> void:
	if current_state == State.DEAD or not _reward_kind.is_empty():
		return
	_pending_reward = kind
	_rage_director.interrupt()
	_remove_mud_shield()
	_attack_area.cancel()
	_grenade_pause = preload("res://scripts/grenade_action_pause.gd").new()
	if current_state in [State.LEAP_AIR, State.JUMP_ATTACK]:
		return # 保留真实飞行与落点计划；接地入口会接管，不再伤人。
	_start_reward(kind)

func _start_reward(kind: String) -> void:
	if not is_on_floor():
		# 被侧墙／天花板阻挡的空中动作也先真实落地，再开始任何过渡与有效奖励。
		_air_debris.emitting = false
		_flight_shadow.visible = false
		_stop_action()
		_pending_reward = kind
		current_state = State.REWARD_LANDING
		collision_mask = 1
		velocity = Vector3(0, minf(velocity.y, 0), 0)
		_player_separation.begin(self)
		return
	_stop_action()
	_pending_reward = ""
	_reward_kind = kind
	_reward_elapsed = 0.0
	var prefix := "down" if kind == "down" else "kneel"
	_reward_durations = {"lower": _p(prefix + "_lower_seconds"), "hold": _p(prefix + "_hold_seconds"), "rise": _p(prefix + "_rise_seconds")}
	_reward_damage_multiplier = _p("down_damage_multiplier") if kind == "down" else 1.0
	if kind == "down":
		_crystal_guard_remaining = 0.0
		_set_crystal_guard(false)
		_set_reward_hitboxes(true)
	_brain.finish_group("crystal_broken" if kind == "down" else "shield_broken")
	current_state = State.REWARD_LOWER
	velocity = Vector3.ZERO
	_push_velocity = Vector3.ZERO
	_reward_feedback("晶体击碎 · 倒地" if kind == "down" else "破盾 · 跪地", Color(1, 0.8, 0.25))

func _tick_reward(delta: float) -> void:
	_reward_elapsed += delta
	var duration := float(_reward_durations.lower if current_state == State.REWARD_LOWER else _reward_durations.hold if current_state == State.REWARD_HOLD else _reward_durations.rise)
	var blend := clampf(_reward_elapsed / maxf(duration, 0.001), 0.0, 1.0)
	if current_state == State.REWARD_HOLD:
		blend = 1.0
	elif current_state == State.REWARD_RISE:
		blend = 1.0 - blend
	_sample_reward_pose(blend)
	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y = -0.5 if is_on_floor() and velocity.y <= 0.0 else velocity.y - _p("gravity") * delta
	GroundMovement.move(self, delta, false)
	_head_collision.position = to_local(core_mesh.global_position)
	if _reward_elapsed + 0.000001 < duration:
		return
	_reward_elapsed = 0.0
	if current_state == State.REWARD_LOWER:
		current_state = State.REWARD_HOLD
	elif current_state == State.REWARD_HOLD:
		current_state = State.REWARD_RISE
	else:
		var was_down := _reward_kind == "down"
		_reward_kind = ""
		if was_down:
			_crystal_hits = 0
			_crystal_shots.clear()
			_crystal_break_pending = false
			_set_reward_hitboxes(false)
			visual_root.rotation.x = 0.0
			visual_root.position.y = STANDING_VISUAL_Y
			_reward_feedback("晶体重聚 · 开放", Color(1, 0.55, 0.3))
		_shield_hits = 0
		_shield_explosions.clear()
		_update_shield_cracks()
		_reset_pose()
		current_state = State.IDLE
		if _pending_rage:
			_pending_rage = false
			_trigger_rage()
		elif not is_enraged:
			_activate_mud_shield()

func _setup_reward_hitboxes() -> void:
	_reward_body_area = _make_reward_area(torso_pivot, "FallenBody", CylinderShape3D.new())
	var body_shape := (_reward_body_area.get_child(0) as CollisionShape3D).shape as CylinderShape3D
	body_shape.radius = 1.25
	body_shape.height = 2.3
	_reward_head_area = _make_reward_area(core_mesh, "FallenCrystal", SphereShape3D.new())
	((_reward_head_area.get_child(0) as CollisionShape3D).shape as SphereShape3D).radius = 0.5

func _make_reward_area(parent: Node3D, title: String, shape: Shape3D) -> Area3D:
	var area := Area3D.new()
	area.name = title
	area.collision_layer = 0
	area.collision_mask = 0
	area.monitoring = false
	area.set_meta(&"damage_receiver", get_instance_id())
	area.set_meta(&"hit_region", "body")
	var collision := CollisionShape3D.new()
	collision.shape = shape
	area.add_child(collision)
	parent.add_child(area)
	return area

func _set_reward_hitboxes(active: bool) -> void:
	# 身体实体继续对世界接地；倒地命中区域独立跟随表现，均解析回唯一Boss。
	collision_layer = 0 if active else 4
	_reward_body_area.collision_layer = 4 if active else 0
	_reward_head_area.collision_layer = 4 if active else 0

func _sample_reward_pose(blend: float) -> void:
	if _reward_kind == "down":
		visual_root.rotation.x = 1.35 * blend
		visual_root.position.y = STANDING_VISUAL_Y + 0.8 * blend
		torso_pivot.position.y = 1.8
		torso_pivot.rotation = Vector3.ZERO
		right_arm_pivot.rotation.x = -0.3 * blend
		left_arm_pivot.rotation.x = -0.3 * blend
		left_leg_pivot.rotation.x = -0.15 * blend
		right_leg_pivot.rotation.x = 0.15 * blend
		return
	torso_pivot.position.y = lerpf(1.8, 0.95, blend)
	torso_pivot.rotation.x = deg_to_rad(30.0) * blend
	right_arm_pivot.rotation.x = deg_to_rad(65.0) * blend
	left_arm_pivot.rotation.x = deg_to_rad(-20.0) * blend
	left_leg_pivot.rotation.x = deg_to_rad(-65.0) * blend
	right_leg_pivot.rotation.x = deg_to_rad(60.0) * blend

func _reward_feedback(text: String, color: Color) -> void:
	var scene := get_tree().current_scene
	if scene != null:
		var notice := Label3D.new()
		notice.text = text
		notice.font_size = 42
		notice.pixel_size = 0.012
		notice.modulate = color
		notice.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		scene.add_child(notice)
		notice.global_position = core_mesh.global_position + Vector3.UP
		var fade := notice.create_tween()
		fade.tween_property(notice, "position:y", notice.position.y + 0.8, 0.8)
		fade.parallel().tween_property(notice, "modulate:a", 0.0, 0.8)
		fade.tween_callback(notice.queue_free)

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


func _begin_attack(next_state: State, heavy := false, combat := true) -> bool:
	if current_state not in [State.IDLE, State.CHASE] or attack_cooldown > 0.0:
		return _sparring_rejected("state_or_attack_cooldown")
	if combat and not heavy and _brain.needs_heavy(is_enraged):
		return _sparring_rejected("group_requires_heavy")
	var skill := "leap" if next_state == State.LEAP_WINDUP else "slam" if next_state == State.ATK_SLAM else "thrust" if next_state == State.ATK_THRUST else "triple_slam" if next_state == State.ATK_TRIPLE_SLAM else "sweep"
	if not _brain.available(skill) or not _steering.spatial.permits_channel(StringName(skill)):
		return _sparring_rejected("skill_cooldown_or_reserved_channel")
	_stop_action()
	if not _crowd.request_attack():
		return _sparring_rejected("crowd_attack_budget")
	_reset_pose()
	current_state = next_state
	_attack_target = target
	_active_skill = skill
	_heavy_window = heavy and _brain.rhythm_enabled()
	# 半血和运行调参不能缩短已经公布的窗口；只在下一记重招开始时快照。
	_heavy_recovery_scale = _p("rage_heavy_recovery_scale") if is_enraged and _heavy_window and next_state not in [State.ATK_THRUST,State.ATK_TRIPLE_SLAM] else 1.0
	_heavy_recovering = false
	if _heavy_window and bool(_tuning.heavy_sheds_shield):
		_remove_mud_shield()
	if combat:
		_brain.commit_offense(is_enraged, _heavy_window)
	_hit_landed = false
	_attack_elapsed = 0.0
	_brain.started(skill, _selection_reason, global_position.distance_to(target.global_position) if _target_alive() else 0.0)
	_brain.history[-1]["heavy_recovery_scale"] = _heavy_recovery_scale
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


func _spatial_remaining(channel: StringName) -> float:
	var result := float(_brain.cooldowns.get(String(channel), 0.0))
	return maxf(result, _brain.approach_remaining) if channel == &"leap" else result


func _spatial_consume(channel: StringName, duration: float) -> void:
	if _brain.cooldowns.has(String(channel)):
		_brain.cooldowns[String(channel)] = maxf(float(_brain.cooldowns[String(channel)]), duration)
	if channel == &"leap":
		_brain.approach_remaining = maxf(_brain.approach_remaining, _p("approach_interval"))


func _slam_spec() -> Dictionary:
	var size := _crowd.size_multiplier
	return {"kind": "rect", "width": _p("slam_width") * size, "length": _p("slam_distance") * attack_range_scale * size,
		"offset": _p("slam_offset") * size, "height": 2.5 * size,
		"stable_tracking_surface": true,
		"exclude_bodies": Destruction.breakable_rids(self, _p("slam_break_power"))}


func _sweep_spec() -> Dictionary:
	var size := _crowd.size_multiplier
	return {"kind": "sector", "radius": _p("sweep_distance") * attack_range_scale * size,
		"angle": _p("sweep_angle"), "height": 2.5 * size,
		"stable_tracking_surface": true,
		"exclude_bodies": Destruction.breakable_rids(self, _p("sweep_break_power"))}


func _thrust_spec() -> Dictionary:
	return {"kind": "rect", "offset": 0.0, "width": _p("thrust_width") * _crowd.size_multiplier,
		"length": _p("thrust_distance") * attack_range_scale * _crowd.size_multiplier,
		"height": 2.5 * _crowd.size_multiplier, "stable_tracking_surface": true}


func trigger_triple_slam_attack() -> bool:
	if not is_enraged or not bool(_tuning.get("rage_director_enabled",false)) or not _target_alive() or not is_on_floor(): return false
	var offset: Vector3 = target.global_position-global_position
	if Vector2(offset.x,offset.z).length() > _p("triple_slam_length")*_crowd.size_multiplier or absf(offset.y) > 4.1: return false
	if not AttackArea.unobstructed(self,global_position,target.global_position): return false
	if not _begin_attack(State.ATK_TRIPLE_SLAM,true): return false
	# 三线共用物理时钟；不用三个异步回调分别结算。
	_action_tween.kill()
	_action_tween = null
	_rage_director.start_triple_slam()
	_publish_formal_boss_health()
	return true


func get_public_attack_area() -> Node3D:
	return _rage_director.public_area() if current_state == State.ATK_TRIPLE_SLAM else _attack_area


func get_public_attack_areas() -> Array[Node3D]:
	if current_state == State.ATK_TRIPLE_SLAM: return _rage_director.public_areas()
	var result: Array[Node3D] = []
	if is_instance_valid(_attack_area): result.append(_attack_area)
	return result


func trigger_thrust_attack(landing_finisher := false) -> bool:
	if not bool(_tuning.thrust_enabled) or not _begin_attack(State.ATK_THRUST, landing_finisher):
		return false
	_thrust_windup = _p("rage_thrust_windup" if is_enraged else "thrust_windup")
	# 狙击抬头时地面可能出屏；高音短蓄力与跃击低音蓄力区分，提示独立第二击。
	Audio.play_at_priority("titan_charge", global_position, -6.0, 1.6)
	_attack_area.prepare(global_transform, _thrust_spec(), _p("thrust_damage") * _damage_scale, _thrust_windup + _p("thrust_swing"))
	# 完整线形预警出现就锁方向；不在玩家翻滚冷却中追踪补正。
	_attack_area.lock()
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees:x", -65.0, _thrust_windup)
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", -10.0, _thrust_windup)
	_action_tween.tween_property(right_forearm, "position:z", 2.3, _p("thrust_swing"))
	_action_tween.parallel().tween_property(right_arm_pivot, "rotation_degrees:x", -90.0, _p("thrust_swing"))
	_action_tween.tween_callback(_execute_thrust_impact)
	_action_tween.tween_property(right_forearm, "position:z", 0.0, _p("thrust_recovery"))
	_action_tween.parallel().tween_property(right_arm_pivot, "rotation", Vector3.ZERO, _p("thrust_recovery"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation", Vector3.ZERO, _p("thrust_recovery"))
	_action_tween.tween_callback(_finish_action.bind(0.0))
	return true


func _execute_thrust_impact() -> void:
	if current_state != State.ATK_THRUST or not _attack_area.strike():
		return
	_hurt_target(_attack_area.damage, "泰坦远距震拳")
	var spec := _attack_area.shape.duplicate(true)
	spec["surface"] = _attack_area.get_surface()
	MeleeEffect.spawn(get_tree().current_scene, _attack_area.global_transform, spec, _crowd.size_multiplier, false, 0.16, _p("ground_shake_strength") * 0.4)
	_attack_area.recover()
	_heavy_recovering = _heavy_window


func _spatial_can_attack() -> bool:
	if not _target_alive():
		return false
	if _brain.available("leap") and bool(_tuning.leap_enabled) and _steering.spatial.permits_channel(&"leap"):
		var distance := Vector2(target.global_position.x - global_position.x, target.global_position.z - global_position.z).length()
		if (_target_above() or _brain.wants_approach(distance)) and not _plan_leap().is_empty():
			return true
	return _spatial_attack_pose(global_transform)

func _spatial_attack_pose(pose: Transform3D) -> bool:
	if not _target_alive(): return false
	# 与实际选招共用高处判定。高处目标不会释放地面重击，不能因此让导航提前交还。
	if _target_above_at(pose):
		return JumpMelee.can_start_at(self, target, _normal_attack_spec(), pose)
	return absf(target.global_position.y - pose.origin.y) <= 2.5 * _crowd.size_multiplier and \
		AttackArea.unobstructed(self, pose.origin, target.global_position) and \
		(AttackArea.candidate_can_hit(self, pose, _slam_spec(), target) or AttackArea.candidate_can_hit(self, pose, _sweep_spec(), target))


func _spatial_break_action(component: Node3D, point: Vector3, _ability: Resource) -> bool:
	if current_state not in [State.IDLE, State.CHASE] or not _brain.available("slam") or not _steering.spatial.permits_channel(&"slam"):
		return false
	var direction := point - global_position
	direction.y = 0.0
	if not direction.is_zero_approx():
		rotation.y = atan2(-direction.x, -direction.z)
	var power := _p("slam_break_power")
	if not component.can_break(power):
		return false
	_selection_reason = "navigation_break"
	trigger_slam_attack(component)
	return current_state == State.ATK_SLAM


func trigger_slam_attack(obstacle: Node3D = null) -> void:
	if not _begin_attack(State.ATK_SLAM, not is_instance_valid(obstacle), not is_instance_valid(obstacle)):
		return
	if is_instance_valid(obstacle):
		_breach_target = weakref(obstacle)
		var point: Vector3 = obstacle.impact_point(global_position)
		var direction := point - global_position
		direction.y = 0.0
		if not direction.is_zero_approx():
			rotation.y = atan2(-direction.x, -direction.z)
	var size := _crowd.size_multiplier
	_attack_area.prepare(global_transform, _slam_spec(),
		slam_damage * _damage_scale, _p("slam_windup") + _p("slam_swing"))
	# 完整预警一出现就固定攻击方向，玩家可以按边界选择撤离路线。
	_attack_area.lock()
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees:x", -120.0, _p("slam_windup"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", -15.0, _p("slam_windup"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:y", -20.0, _p("slam_windup"))
	_action_tween.tween_callback(_attack_area.lock)
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees:x", 0.0, _p("slam_swing")).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	_action_tween.parallel().tween_property(torso_pivot, "position:y", 1.2, _p("slam_swing"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", 20.0, _p("slam_swing"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:y", -80.0, _p("slam_swing"))
	_action_tween.tween_callback(_execute_slam_impact)
	_action_tween.tween_property(right_forearm, "position:y", -0.4, _p("slam_sink_time") * _heavy_recovery_scale).set_trans(Tween.TRANS_LINEAR)
	_action_tween.tween_interval(_p("slam_hold") * _heavy_recovery_scale)
	_action_tween.tween_property(torso_pivot, "position:y", 1.8, _p("slam_recovery") * _heavy_recovery_scale).set_trans(Tween.TRANS_BACK)
	_action_tween.parallel().tween_property(right_arm_pivot, "rotation_degrees:x", 0.0, _p("slam_recovery") * _heavy_recovery_scale)
	_action_tween.parallel().tween_property(right_forearm, "position:y", -0.3, _p("slam_recovery") * _heavy_recovery_scale)
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:x", 0.0, _p("slam_recovery") * _heavy_recovery_scale)
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees:y", 0.0, _p("slam_recovery") * _heavy_recovery_scale)
	_action_tween.tween_callback(_finish_action.bind(_p("slam_cooldown")))


func _execute_slam_impact() -> void:
	if current_state == State.ATK_SLAM and _attack_area.phase == AttackArea.Phase.LOCKED:
		Destruction.shape_impact(_attack_area, _p("slam_break_power"))
		_attack_area.shape.erase("exclude_bodies")
		_attack_area.refresh_surface()
	if current_state == State.ATK_SLAM and _attack_area.strike():
		_hurt_target(_attack_area.damage, "泰坦直线砸地")
		var visual_spec := _attack_area.shape.duplicate(true)
		visual_spec["surface"] = _attack_area.get_surface()
		visual_spec.contact = _attack_area.to_local((right_forearm.get_node("MassiveFist") as Node3D).global_position)
		MeleeEffect.spawn(get_tree().current_scene, _attack_area.global_transform, visual_spec,
			_crowd.size_multiplier, false, 0.4, _p("ground_shake_strength"))
		_attack_area.recover()
		_heavy_recovering = _heavy_window


func trigger_sweep_attack() -> void:
	if not _begin_attack(State.ATK_SWEEP):
		return
	var size := _crowd.size_multiplier
	_attack_area.prepare(global_transform, _sweep_spec(), sweep_damage * _damage_scale,
		_p("sweep_windup"))
	_sweep_progress = 0.0
	_sweep_destroyed = false
	_action_tween.tween_method(_prepare_sweep, 0.0, 1.0, _p("sweep_windup"))
	_action_tween.tween_callback(_start_sweep)
	_action_tween.tween_method(_advance_sweep, 0.0, 1.0, _p("sweep_swing")).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_action_tween.tween_callback(_execute_sweep_impact)
	_action_tween.tween_method(_recover_sweep, 0.0, 1.0, _p("sweep_recovery")).set_trans(Tween.TRANS_SINE)
	_action_tween.tween_callback(_finish_action.bind(_p("sweep_cooldown")))


func _execute_sweep_impact() -> void:
	if current_state == State.ATK_SWEEP and _attack_area.phase == AttackArea.Phase.STRIKE:
		_advance_sweep(1.0)
		if _sweep_destroyed:
			_attack_area.shape.erase("exclude_bodies")
			_attack_area.refresh_surface()
			if is_instance_valid(_sweep_fx):
				_sweep_fx.call("refresh_surface", _attack_area.get_surface())
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
	var visual_spec := _attack_area.shape.duplicate(true)
	visual_spec["surface"] = _attack_area.get_surface()
	_sweep_fx = MeleeEffect.spawn(get_tree().current_scene, _attack_area.global_transform, visual_spec,
		_crowd.size_multiplier, true, _p("sweep_swing"))
	_advance_sweep(0.0)


func _advance_sweep(value: float) -> void:
	if current_state != State.ATK_SWEEP or _attack_area.phase != AttackArea.Phase.STRIKE:
		return
	var arc := deg_to_rad(float(_attack_area.shape.angle))
	var previous := -arc * 0.5 + arc * _sweep_progress
	var angle := -arc * 0.5 + arc * value
	var half_width := atan2(0.35 * _crowd.size_multiplier, maxf(float(_attack_area.shape.radius), 0.1))
	_sweep_destroyed = Destruction.shape_impact(_attack_area, _p("sweep_break_power"),
		previous - half_width, angle + half_width) > 0 or _sweep_destroyed
	torso_pivot.rotation.y = -sin(angle) * 0.25
	left_arm_pivot.global_transform = _sweep_arm_pose(angle)
	if is_instance_valid(_sweep_fx):
		_sweep_fx.call("set_progress", value)
	if not _hit_landed and _attack_area.can_hit(_attack_target, _attack_area.hit_source()):
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
	if _attack_area.can_hit(_attack_target, _attack_area.hit_source()):
		_hit_landed = true
		Telemetry.hurt_player(_attack_target, amount, global_position, 1.0, Telemetry.source_info(self, attack))


func _finish_action(cooldown: float) -> void:
	_breach_target = null
	_attack_area.cancel()
	_leap_plan.clear()
	_crowd.release_attack()
	if current_state == State.DEAD:
		return
	_rage_director.finished(_active_skill,_heavy_window)
	_rage_director.clear_triple_slam()
	if _heavy_window:
		_brain.finish_group("heavy_recovered")
	_heavy_window = false
	_heavy_recovering = false
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
	if _brain.rhythm_enabled() and not is_enraged:
		_activate_mud_shield()
	_publish_formal_boss_health()


func get_hit_region(shape_index: int) -> String:
	if shape_index < 0:
		return "body"
	var owner_id := shape_find_owner(shape_index)
	return "crystal" if shape_owner_get_owner(owner_id) == _head_collision else "body"

func get_projectile_exclusions() -> Array[RID]:
	var result: Array[RID] = [get_rid()]
	result.append_array(_weapon_regions.exclusions())
	if is_instance_valid(_crystal_guard):
		result.append(_crystal_guard.get_rid())
	if is_instance_valid(_reward_body_area):
		result.append(_reward_body_area.get_rid())
		result.append(_reward_head_area.get_rid())
	return result

func get_weapon_query_exclusions() -> Array[RID]:
	# 保留世界移动和手雷接触体；仅玩家武器改用可见部件。
	return [get_rid(), _reward_body_area.get_rid(), _reward_head_area.get_rid()]

func blocks_weapon_hit(context: Dictionary) -> bool:
	return bool(_tuning.crystal_break_enabled) and is_enraged and _crystal_guard_remaining > 0.000001 and String(context.get("hit_region", "body")) in ["crystal", "crystal_guard"]

func get_weapon_aim_feedback(context: Dictionary) -> Dictionary:
	if not bool(_tuning.crystal_break_enabled) or not is_enraged or current_state == State.DEAD:
		return {}
	var progress := "%d/%d" % [_crystal_hits, int(_tuning.crystal_sniper_hits)]
	if not _reward_kind.is_empty() or not _pending_reward.is_empty():
		return {"kind": "reward", "text": "倒地输出 ×2" if _reward_kind == "down" and current_state == State.REWARD_HOLD else "起身中 · 普通伤害" if current_state == State.REWARD_RISE else "倒地中" if _reward_kind == "down" or _pending_reward == "down" else "跪地中", "color": Color(1, 0.85, 0.35)}
	if blocks_weapon_hit(context):
		return {"kind": "protected", "text": "晶体保护 %.1fs · 射击身体" % _crystal_guard_remaining, "color": Color(0.3, 0.85, 1)}
	if String(context.get("hit_region", "body")) == "crystal":
		return {"kind": "crystal", "text": "晶体 %s · 狙击可破击" % progress if context.get("weapon_kind") == "sniper" else "晶体 %s · 需狙击破击" % progress, "color": Color(1, 0.82, 0.25)}
	return {"kind": "body", "text": "身体 · 不累计破击", "color": Color(0.8, 0.85, 0.88)}

func get_weapon_hit_feedback(context: Dictionary) -> Dictionary:
	return _last_weapon_feedback.duplicate() if _last_weapon_feedback.has("text") and _last_weapon_feedback.get("shot_id", "") == context.get("shot_id", "") else {}

func _save_weapon_feedback(context: Dictionary, kind: String, text: String, color: Color) -> void:
	_last_weapon_feedback = {"shot_id": context.get("shot_id", ""), "kind": kind, "text": text, "color": color}

func take_weapon_hit(amount: float, _position: Vector3, _headshot: bool, context: Dictionary) -> void:
	if blocks_weapon_hit(context):
		_save_weapon_feedback(context, "protected", "护罩拦截 · 不累计破击", Color(0.3, 0.85, 1))
		# 持续扫射仍即时反馈，但不让重复浮字淹没晶体；准星与局部状态常驻。
		return
	var eligible: bool = bool(_tuning.crystal_break_enabled) and is_enraged and _reward_kind.is_empty() and _pending_reward.is_empty() and not _crystal_break_pending and String(context.get("weapon_kind", "")) == "sniper" and String(context.get("hit_region", "body")) == "crystal"
	var shot_id := String(context.get("shot_id", ""))
	if eligible and not shot_id.is_empty() and _crystal_shots.has(shot_id):
		return
	var feedback := get_weapon_aim_feedback(context)
	_last_weapon_feedback = feedback.duplicate()
	_last_weapon_feedback["shot_id"] = shot_id
	if feedback.get("kind") == "body":
		_last_weapon_feedback["text"] = "身体命中 · 不累计破击"
	elif feedback.get("kind") == "crystal" and context.get("weapon_kind") != "sniper":
		_last_weapon_feedback["text"] = "命中晶体 · 需狙击破击"
	elif feedback.get("kind") == "reward" and _reward_kind == "down" and current_state == State.REWARD_HOLD:
		_last_weapon_feedback["text"] = "倒地命中 ×2" # 描述这一枪，起身后不误称仍在倍伤窗口。
	take_damage(amount)
	if current_state == State.DEAD:
		_save_weapon_feedback(context, "defeated", "击败首领", Color(1, 0.85, 0.35))
	if current_state == State.DEAD or not eligible or shot_id.is_empty():
		return
	_crystal_shots[shot_id] = true
	_crystal_hits += 1
	_save_weapon_feedback(context, "break", "晶体破击 %d/%d" % [_crystal_hits, int(_tuning.crystal_sniper_hits)], Color(1, 0.82, 0.25))
	_reward_feedback("晶体破击 %d/%d" % [_crystal_hits, int(_tuning.crystal_sniper_hits)], Color(1, 0.75, 0.25))
	Audio.play_at("hit_metal", core_mesh.global_position, -5.0)
	CombatFX.spawn_impact(get_tree().current_scene, core_mesh.global_position, Vector3.UP, Color(1, 0.45, 0.1), 1.5)
	if _crystal_hits >= int(_tuning.crystal_sniper_hits):
		_crystal_break_pending = true
		crystal_broken.emit(self)
		if bool(_tuning.down_reward_enabled):
			_request_reward("down")
	else:
		_crystal_guard_remaining = _p("crystal_guard_seconds")
		_set_crystal_guard(true)
	_update_crystal_hint()
	_publish_formal_boss_health() # 进度与局部提示同次更新，不等待下一次10Hz刷新。

func _setup_crystal_guard() -> void:
	_crystal_guard = Area3D.new()
	_crystal_guard.name = "CrystalGuard"
	_crystal_guard.collision_layer = 0
	_crystal_guard.collision_mask = 0
	_crystal_guard.monitoring = false
	_crystal_guard.set_meta(&"damage_receiver", get_instance_id())
	_crystal_guard.set_meta(&"hit_region", "crystal_guard")
	core_mesh.add_child(_crystal_guard)
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.65
	shape.shape = sphere
	_crystal_guard.add_child(shape)
	_crystal_guard_visual = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.65
	mesh.height = 1.3
	_crystal_guard_visual.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.12, 0.7, 1, 0.28)
	_crystal_guard_visual.material_override = mat
	_crystal_guard_visual.visible = false
	_crystal_guard.add_child(_crystal_guard_visual)
	_crystal_hint = Label3D.new()
	_crystal_hint.name = "CrystalStatus"
	_crystal_hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_crystal_hint.font_size = 26
	_crystal_hint.outline_size = 6
	_crystal_hint.pixel_size = 0.005
	_crystal_hint.no_depth_test = false
	_crystal_hint.visible = false
	add_child(_crystal_hint)

func _update_crystal_hint() -> void:
	if not is_instance_valid(_crystal_hint): return
	_crystal_hint.visible = bool(_tuning.crystal_break_enabled) and is_enraged and current_state != State.DEAD
	if not _crystal_hint.visible: return
	_crystal_hint.position = to_local(core_mesh.global_position + Vector3.UP * 1.2 * _crowd.size_multiplier)
	var feedback := get_weapon_aim_feedback({"hit_region": "crystal", "weapon_kind": "sniper"})
	_crystal_hint.text = "晶体 %d/%d\n%s" % [_crystal_hits, int(_tuning.crystal_sniper_hits), "保护 %.1fs · 射击身体" % _crystal_guard_remaining if _crystal_guard_remaining > 0.0 else "狙击红色晶体" if feedback.get("kind") == "crystal" else feedback.get("text", "")]
	_crystal_hint.modulate = feedback.get("color", Color.WHITE)

func _set_crystal_guard(active: bool) -> void:
	_crystal_guard.collision_layer = 4 if active else 0
	_crystal_guard_visual.visible = active

func _tick_crystal(delta: float) -> void:
	if not bool(_tuning.crystal_break_enabled) or not is_enraged:
		return
	_crystal_clock += delta
	if _crystal_guard_remaining > 0.0:
		_crystal_guard_remaining = maxf(_crystal_guard_remaining - delta, 0.0)
		if _crystal_guard_remaining <= 0.000001:
			_crystal_guard_remaining = 0.0
			_set_crystal_guard(false)
			_reward_feedback("晶体开放", Color(0.7, 1, 1))
	var strength := maxf(1.0 - float(_crystal_hits) / float(_tuning.crystal_sniper_hits), 0.15)
	var flash := (0.55 + 0.45 * pow(0.5 + 0.5 * sin(_crystal_clock * TAU * 1.8), 6.0)) * strength
	(core_mesh.material_override as StandardMaterial3D).emission_energy_multiplier = _p("crystal_flash_strength") * flash
	_core_light.light_energy = 0.4 + flash * 1.8

func take_damage_at(amount: float, _hit_position: Vector3, _headshot: bool) -> void:
	# 晶体只是阶段标识，不再叠加旧的 2.5 倍弱点奖励。
	take_damage(amount)


func take_damage(amount: float, _hit_part: Node = null) -> void:
	if current_state == State.DEAD or amount <= 0.0:
		return
	var state_multiplier := _reward_damage_multiplier if _reward_kind == "down" and current_state == State.REWARD_HOLD else rage_incoming_multiplier if is_enraged else 1.0
	var final_damage := amount * state_multiplier
	if has_mud_shield:
		final_damage *= 1.0 - shield_reduction
	_apply_damage(final_damage)
	if current_state == State.DEAD:
		return
	if bool(_tuning.rage_enabled) and not is_enraged and current_hp <= max_hp * rage_health_ratio:
		_trigger_rage()
	if has_mud_shield and bool(_tuning.mud_shield_break_on_q) and String(get_meta(Telemetry.CONTEXT, {}).get("source", "")) == "Q":
		_remove_mud_shield()


func on_resonance_incoming(_center: Vector3) -> void:
	# 共鸣不覆盖重招输出窗口，也不能在狂暴阶段重建泥盾。
	if _formal_boss and current_state != State.DEAD:
		_activate_mud_shield(true)


func _apply_damage(amount: float) -> void:
	var before := current_hp
	current_hp = maxf(current_hp - amount, 0.0)
	Telemetry.enemy_damaged(self, before)
	_update_health_label()
	_publish_formal_boss_health()
	if current_hp <= 0.0:
		if Telemetry.credits_player(self) and is_instance_valid(target) and target.has_method("register_enemy_kill"):
			target.call("register_enemy_kill", self)
		trigger_death_scatter()


func _trigger_rage() -> void:
	if not bool(_tuning.rage_enabled) or is_enraged or current_state == State.DEAD:
		return
	if not _reward_kind.is_empty() or not _pending_reward.is_empty():
		_pending_rage = true
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
	# 已公布的攻击沿用 AttackArea 保存的范围与伤害；狂暴倍率从下一击生效。
	if current_state == State.CAST_SHIELD:
		_stop_action()
		_finish_action(_p("rage_ready_delay"))
	(_head_collision.shape as SphereShape3D).radius = 0.5 * rage_crystal_size
	_core_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_core_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_core_tween.tween_property(core_mesh, "scale", Vector3.ONE * rage_crystal_size, _p("rage_transform_time"))
	_core_tween.parallel().tween_property(head_pivot, "position:y", 1.9, _p("rage_transform_time"))
	_core_tween.parallel().tween_property(_health_label, "position:y", 4.2, _p("rage_transform_time"))
	_update_health_label()


func apply_hitstop(seconds: float) -> void:
	# 复用既有局部暂停契约，不能关闭整个Boss物理导致晶体罩和长奖励停表。
	# 普通枪的表现顿帧与E的战术硬直分开；只限制狂暴阶段连续枪击拖慢动作。
	if is_enraged and bool(_tuning.rage_shot_movement_armor) and current_state in [State.IDLE, State.CHASE]:
		return
	if is_enraged and _bullet_hitstop_remaining > 0.0:
		return
	if is_enraged:
		_bullet_hitstop_remaining = _p("rage_bullet_hitstop_interval")
	apply_grenade_stagger(seconds)

func apply_grenade_stagger(seconds: float) -> void:
	if not _reward_kind.is_empty() or not _pending_reward.is_empty():
		return
	if current_state != State.DEAD:
		_grenade_pause.request(seconds, current_state in [State.SPAWN, State.LEAP_AIR, State.JUMP_ATTACK], _action_tween)

func grenade_stagger_active() -> bool:
	return current_state != State.DEAD and _grenade_pause.remaining > 0.0

func apply_push(direction: Vector3, force: float) -> void:
	if current_state == State.DEAD or not _reward_kind.is_empty() or not _pending_reward.is_empty():
		return
	# 巨型敌人仅承受 15% 击退，Q 使用现有范围伤害与击退。
	_push_velocity = Vector3(direction.x, 0, direction.z).normalized() * maxf(force, 0.0) * _p("push_multiplier")


func _update_health_label() -> void:
	var phase_text := " · 红晶狂暴" if is_enraged else (" · 泥盾 %d%%" % roundi(shield_reduction * 100.0) if has_mud_shield else "")
	_health_label.text = "沉积泰坦  %d/%d%s" % [ceili(current_hp), ceili(max_hp), phase_text]


func _publish_formal_boss_health() -> void:
	if not _formal_boss or current_state == State.DEAD:
		return
	_formal_boss_bar_active = true
	EventBus.emit_boss_updated(true, _formal_boss_title + _break_status_caption(), current_hp, max_hp)


func _break_status_caption() -> String:
	if not _reward_kind.is_empty():
		var prefix := "倒地" if _reward_kind == "down" else "跪地"
		if current_state == State.REWARD_HOLD:
			return " · %s破绽 %.1fs%s" % [prefix, maxf(float(_reward_durations.hold) - _reward_elapsed, 0), " ×2" if _reward_kind == "down" else ""]
		return " · " + prefix + ("起身" if current_state == State.REWARD_RISE else "失衡")
	if is_enraged and bool(_tuning.crystal_break_enabled):
		var action := " · 收势" if current_state == State.ATK_TRIPLE_SLAM and _rage_director.triple_struck else " · 三线" if current_state == State.ATK_TRIPLE_SLAM else ""
		return action+" · 晶体 %d/%d · %s" % [_crystal_hits, int(_tuning.crystal_sniper_hits), "护%.1fs" % _crystal_guard_remaining if _crystal_guard_remaining > 0 else "开放"]
	if has_mud_shield and bool(_tuning.shield_break_enabled):
		return " · 泥盾 %d/%d" % [_shield_hits, int(_tuning.shield_grenade_hits)]
	return " · 卸盾收势" if _heavy_recovering else ""

func _hide_formal_boss_health() -> void:
	if not _formal_boss_bar_active:
		return
	_formal_boss_bar_active = false
	EventBus.emit_boss_updated(false, _formal_boss_title, 0.0, max_hp)


func get_stand_height() -> float:
	return 1.7 * maxf(scale.y, 0.01)


func get_title() -> String:
	return _formal_boss_title


func get_health() -> float:
	return current_hp


func get_max_health() -> float:
	return max_hp


func is_dead() -> bool:
	return current_state == State.DEAD


func trigger_death_scatter() -> void:
	if current_state == State.DEAD:
		return
	current_state = State.DEAD
	_set_crystal_guard(false)
	_set_reward_hitboxes(false)
	_weapon_regions.disable()
	if is_instance_valid(_crystal_hint): _crystal_hint.visible = false
	current_hp = 0.0
	_hide_formal_boss_health()
	died.emit(self)
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
	preload("res://scripts/combat_fx.gd").spawn_ground_burst(debris_parent, global_position, 2.6, true)
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
			part.add_to_group("enemy_death_effect")
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
	if is_instance_valid(core_mesh):
		WaveDirector.notify_death_fx(core_mesh, global_position)
	queue_free()


func _add_lifetime(node: Node, seconds: float) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = seconds
	node.add_child(timer)
	timer.timeout.connect(node.queue_free)
	timer.start()
