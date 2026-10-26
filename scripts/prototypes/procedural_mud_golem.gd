class_name ProceduralMudGolem
extends CharacterBody3D

signal died(enemy: Node3D)
const Lifecycle := preload("res://scripts/enemies/enemy_lifecycle.gd")
const RenderBatch := preload("res://scripts/prototypes/mud_golem_render_batch.gd")
var _render_batch: MudGolemRenderBatch
var _flash_remaining := 0.0

const HealthUtil := preload("res://scripts/health_util.gd")
const Targeting := preload("res://scripts/targeting.gd")
const Nav := preload("res://scripts/nav_steering.gd")
const GroundMovement := preload("res://scripts/ground_movement.gd")
const SpatialProfile := preload("res://scripts/combat_spatial_profile.gd")
@export var combat_spatial_profile: SpatialProfile = preload("res://data/combat_spatial/ground.tres")
var _steering := Nav.new()
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const Melee := preload("res://scripts/prototypes/mud_golem_melee.gd")
var _attack_area := Melee.new()
var _attack_target: Node3D
## 粘贴的程序化泥土傀儡原型，适配独立战斗测试场的敌人接口。

const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const PROFILE_ID := "PrototypeMudGolem"
const Crowd := preload("res://scripts/prototypes/enemy_crowd.gd")
var _crowd := Crowd.new()

const Telemetry := preload("res://scripts/combat_telemetry.gd")
const ReactionProfile := preload("res://scripts/combat_reaction_profile.gd")
const Reactions := preload("res://scripts/combat_reactions.gd")
@export var combat_reaction_profile: ReactionProfile
var _reactions := Reactions.new()

enum State { IDLE, WALK, ATTACK, STAGGER, DEAD, COMBAT_REACTION }
var current_state: State = State.IDLE

var move_speed: float
var attack_damage: float
var max_health: float
var attack_distance: float
var attack_interval: float
@export var ai_enabled := true
## Cannon-fodder units do not need dozens of permanently visible nameplates.
@export var always_show_health_label := false

var health: float
var _tuning: Dictionary = {}
var target: CharacterBody3D
# 测试场统计读取与正式敌人一致的字段。
var _armor := 0.0
var _damage_scale := 1.0
var visual_root: Node3D
var torso_pivot: Node3D
var head_core: Node3D
var left_arm_pivot: Node3D
var right_arm_pivot: Node3D
var left_leg_pivot: Node3D
var right_leg_pivot: Node3D
var anim_clock := 0.0
var _collision: CollisionShape3D
var _action_tween: Tween
var _attack_cooldown := 0.0
var _push_velocity := Vector3.ZERO
var _health_label: Label3D
var _health_label_until_msec := 0
## 仅诊断用：在正式场景里把 AI 各段耗时累计出来。
static var profile_enabled := false
static var prof_tick_us := 0
static var prof_crowd_us := 0
static var prof_attack_us := 0
static var prof_gate_us := 0
static var prof_total_us := 0
static var prof_frames := 0
static var dbg_attempt := 0
static var dbg_in_reach := 0
static var dbg_can := 0
static var dbg_grant := 0
static var dbg_printed := false


static func reset_profile() -> void:
	prof_tick_us = 0
	prof_crowd_us = 0
	prof_attack_us = 0
	prof_gate_us = 0
	prof_total_us = 0
	prof_frames = 0
	dbg_attempt = 0
	dbg_in_reach = 0
	dbg_can = 0
	dbg_grant = 0


func _ready() -> void:
	_attack_area.setup(self)
	_tuning = Tuning.resolve(self, PROFILE_ID)
	if _tuning.is_empty():
		queue_free()
		return
	_crowd.setup(self, _tuning, PROFILE_ID)
	_tuning = _crowd.varied_values(_tuning, ["move_speed"], ["attack_damage"],
		["attack_interval", "attack_windup", "attack_swing", "attack_recovery"])
	anim_clock = _crowd.phase
	# 错开 10Hz 群体重算与站定刷新：否则 36 只会落在同一物理帧，
	# 造成每 0.1 秒一次的重帧脉冲（平均不差但体感抖）。
	_crowd_clock = fmod(float(get_instance_id() % 997) * 0.011, CROWD_INTERVAL)
	_still_frames = int(get_instance_id() % STILL_MOVE_INTERVAL)
	_ai_phase = int(get_instance_id() % maxi(ai_stride, 1))
	for key in ["move_speed", "attack_damage", "max_health", "attack_distance", "attack_interval"]:
		set(key, float(_tuning[key]))
	_armor = _p("armor")
	health = max_health
	add_to_group("enemies")
	collision_layer = 4
	collision_mask = 3
	_build_procedural_mesh()
	# 原稿晶核朝 +Z；只旋转视觉层，统一项目敌人朝向为 -Z。
	# 战斗测试场以胶囊中心摆位，因此视觉的脚底也换算到中心坐标。
	visual_root.rotation.y = PI
	visual_root.position.y = -0.65
	_setup_collision()
	_steering.setup(self, 0.45, 1.3)
	_steering.spatial.bind(_tuning, {"can_attack": _spatial_can_attack, "attack_pose": _spatial_attack_pose})
	_health_label = Label3D.new()
	_health_label.name = "HealthLabel"
	_health_label.position.y = 0.92
	_health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_health_label.font_size = 28
	_health_label.pixel_size = 0.006
	add_child(_health_label)
	_update_health_label()
	_health_label.visible = always_show_health_label
	_render_batch = RenderBatch.acquire(self)
	_render_batch.register(self, visual_root, torso_pivot, head_core, left_arm_pivot,
		right_arm_pivot, left_leg_pivot, right_leg_pivot)
	_reactions.setup(self, combat_reaction_profile, _collision)


func _exit_tree() -> void:
	if is_instance_valid(_render_batch):
		_render_batch.unregister(self)


## Only presentation reads this timer. Damage and combat timing never depend on rendering.
func visual_flash_strength() -> float:
	var now := Time.get_ticks_msec()
	# This method runs once per displayed golem, so no per-enemy UI timer is needed.
	if not always_show_health_label and is_instance_valid(_health_label) and _health_label.visible and now >= _health_label_until_msec:
		_health_label.visible = false
	return _p("hit_flash_strength") if _flash_remaining > 0.0 else 0.0


## Attack observation reads the same live anchor used to draw the batched fist.
func attack_motion_point() -> Vector3:
	return right_arm_pivot.to_global(Vector3(0.15, -0.3, 0.0))


func _p(key: String) -> float:
	return float(_tuning[key])


const CROWD_INTERVAL := 0.1
const STILL_MOVE_INTERVAL := 6
const AI_TICK_STRIDE := 2
static var ai_stride := 2
## 排队等待时围着入场锚点小范围游荡，避免“原地踏步/完全静止”。
const WANDER_RADIUS := 1.2
const WANDER_SPEED := 0.55
var _wander_anchor := Vector3.ZERO
var _wander_direction := Vector3.ZERO
var _wander_until_msec := 0
var _wander_active := false
var _still_frames := 0
var _close_hold := false
var _ai_phase := 0
var _crowd_clock := 0.0
var _crowd_ready := false
var _cached_crowd := Vector3.ZERO
var _cached_wait := Vector3.ZERO


func _physics_process(delta: float) -> void:
	if not profile_enabled:
		_ai_physics(delta)
		return
	var started := Time.get_ticks_usec()
	_ai_physics(delta)
	prof_total_us += Time.get_ticks_usec() - started


func _ai_physics(delta: float) -> void:
	_flash_remaining = maxf(_flash_remaining - delta, 0.0)
	if current_state == State.ATTACK and not HealthUtil.is_alive(_attack_target):
		_stop_action()
		_finish_action()
	if current_state == State.DEAD:
		return
	if ai_enabled and not HealthUtil.is_alive(target):
		target = Targeting.nearest_player(self)
	anim_clock += delta * _crowd.gait_multiplier
	_attack_cooldown = maxf(_attack_cooldown - delta, 0.0)
	# AI 决策每 2 个物理 tick 一次（按实例错峰）；移动/物理仍每 tick，
	# 低帧时不会因为一渲染帧补多个物理 tick 而重复跑完整决策。
	var physics_frame := Engine.get_physics_frames()
	if ai_enabled and (physics_frame + _ai_phase) % maxi(ai_stride, 1) != 0:
		_continue_motion(delta)
		return
	if profile_enabled:
		prof_frames += 1
	var prof_start := Time.get_ticks_usec()
	_crowd.tick(delta)
	if profile_enabled:
		prof_crowd_us += Time.get_ticks_usec() - prof_start
	_crowd_clock += delta
	_crowd_ready = _crowd_clock >= CROWD_INTERVAL
	var crowd_step := _crowd_clock
	if _crowd_ready:
		_crowd_clock = 0.0
	if _reactions.step(delta, ai_enabled and current_state in [State.IDLE, State.WALK, State.ATTACK], move_speed):
		return
	if _try_attack_first():
		return
	# 移动门保持旧行为：排队时停步/小范围游荡，不持续寻路；
	# 攻击门独立：上面的 _try_attack_first 每 tick 都跑，近身仍可转身出手。
	var queue_wait := ai_enabled and current_state in [State.IDLE, State.WALK] and _crowd.defer_attack_check(target)
	if not queue_wait:
		_wander_active = false
	var ticked := false
	if not _close_hold and not queue_wait:
		var tick_start := Time.get_ticks_usec()
		ticked = _steering.tick(delta, ai_enabled and _crowd.ready_to_move() and current_state in [State.IDLE, State.WALK], target, move_speed)
		if profile_enabled:
			prof_tick_us += Time.get_ticks_usec() - tick_start
	if ticked:
		_animate_walk(anim_clock)
		return
	var desired := Vector3.ZERO
	if _close_hold:
		# 贴身战斗姿态：面向玩家停步；不再沿旧路线走开或原地踏步。
		desired = Vector3.ZERO
		_set_locomotion(State.IDLE)
	elif queue_wait:
		# 排队等待时绕入场锚点小范围游荡，一半概率朝玩家。
		if not _wander_active:
			_wander_active = true
			_wander_anchor = global_position
			_pick_wander()
		elif Time.get_ticks_msec() >= _wander_until_msec:
			_pick_wander()
		var desired_wander := _wander_direction * WANDER_SPEED
		var wander_offset := _wander_anchor - global_position
		wander_offset.y = 0.0
		if wander_offset.length_squared() > WANDER_RADIUS * WANDER_RADIUS:
			desired_wander += wander_offset.normalized() * WANDER_SPEED
		elif wander_offset.length_squared() > WANDER_RADIUS * WANDER_RADIUS * 0.64:
			desired_wander *= 0.45
		desired = _steering.spatial.gate_motion(desired_wander, delta)
		_set_locomotion(State.IDLE if desired.is_zero_approx() else State.WALK)
	elif ai_enabled and _crowd.ready_to_move() and current_state in [State.IDLE, State.WALK]:
		if HealthUtil.is_alive(target):
			var offset := target.global_position - global_position
			offset.y = 0.0
			var distance := offset.length()
			if distance > 0.001:
				var direction := offset / distance
				rotation.y = rotate_toward(rotation.y, atan2(-direction.x, -direction.z), delta * _p("turn_speed"))
				var attack_start := Time.get_ticks_usec()
				var can_attack := _spatial_can_attack()
				if profile_enabled:
					prof_attack_us += Time.get_ticks_usec() - attack_start
				if not can_attack:
					_set_locomotion(State.WALK)
					if _crowd_ready:
						var steer_start := Time.get_ticks_usec()
						_cached_crowd = _crowd.steer(direction * move_speed, target.global_position, crowd_step)
						if profile_enabled:
							prof_crowd_us += Time.get_ticks_usec() - steer_start
					desired = _cached_crowd
					var ground_start := Time.get_ticks_usec()
					desired = _steering.ground_velocity(target.global_position, desired, delta)
					if profile_enabled:
						prof_gate_us += Time.get_ticks_usec() - ground_start
					if not desired.is_zero_approx():
						rotation.y = rotate_toward(rotation.y, atan2(-desired.x, -desired.z), delta * _p("turn_speed"))
				elif _attack_cooldown <= 0.0:
					var trigger_start := Time.get_ticks_usec()
					trigger_attack(target.global_position)
					if profile_enabled:
						prof_attack_us += Time.get_ticks_usec() - trigger_start
					if current_state != State.ATTACK and _crowd.enabled():
						if _crowd_ready:
							var waiting_start := Time.get_ticks_usec()
							_cached_wait = _crowd.waiting_velocity(target.global_position, move_speed, crowd_step)
							if profile_enabled:
								prof_crowd_us += Time.get_ticks_usec() - waiting_start
						desired = _cached_wait
						_set_locomotion(State.IDLE if desired.is_zero_approx() else State.WALK)
				else:
					_set_locomotion(State.IDLE)
		else:
			_set_locomotion(State.IDLE)
	match current_state:
		State.IDLE:
			_animate_idle(anim_clock)
		State.WALK:
			_animate_walk(anim_clock)
	_move_physics(desired, delta)


func _continue_motion(delta: float) -> void:
	var desired := Vector3(velocity.x, 0.0, velocity.z)
	match current_state:
		State.IDLE:
			_animate_idle(anim_clock)
		State.WALK:
			_animate_walk(anim_clock)
	_move_physics(desired, delta)


func _move_physics(desired: Vector3, delta: float) -> void:
	# 顶墙时把“往墙里”的期望速度改成沿墙切向滑动，并轻推离墙；
	# 否则 move_and_slide 清零速度后它还会原地播走路动画，看起来就是顶石头。
	if is_on_wall():
		var wall_normal := get_wall_normal()
		wall_normal.y = 0.0
		if wall_normal.length_squared() > 0.0001:
			wall_normal = wall_normal.normalized()
			var into := desired.dot(wall_normal)
			if into < -0.001:
				desired -= wall_normal * into
				desired += wall_normal * 0.2
				if desired.length_squared() < 0.01:
					desired = wall_normal * 0.6
	# 站定/排队时不每帧跑 move_and_slide；每 6 帧刷新一次贴地。
	# 移动、击退、悬空仍每帧走物理，避免影响追击与击退。
	var still := is_on_floor() and desired.is_zero_approx() \
		and _push_velocity.is_zero_approx() \
		and Vector2(velocity.x, velocity.z).length_squared() < 0.0004
	if still and _still_frames < STILL_MOVE_INTERVAL:
		_still_frames += 1
		velocity = Vector3.ZERO
		_push_velocity = Vector3.ZERO
	else:
		_still_frames = 0
		velocity.x = move_toward(velocity.x, desired.x + _push_velocity.x, delta * _p("acceleration"))
		velocity.z = move_toward(velocity.z, desired.z + _push_velocity.z, delta * _p("acceleration"))
		_push_velocity = _push_velocity.move_toward(Vector3.ZERO, delta * _p("push_decay"))
		if is_on_floor():
			velocity.y = -0.5
		else:
			velocity.y -= _p("gravity") * delta
		GroundMovement.move(self, delta)


func _try_attack_first() -> bool:
	_close_hold = false
	if not ai_enabled or current_state not in [State.IDLE, State.WALK]:
		return false
	if not is_instance_valid(target):
		return false
	dbg_attempt += 1
	var offset := target.global_position - global_position
	offset.y = 0.0
	var distance := offset.length()
	var reach := (attack_distance + _p("attack_reach_extra")) * _crowd.size_multiplier
	var hold := reach + 0.25
	if distance > hold or distance <= 0.001:
		return false
	dbg_in_reach += 1
	# 近身立即转身面向玩家；背后贴脸也能进入攻击扇区。
	var direction := offset / distance
	rotation.y = atan2(-direction.x, -direction.z)
	# 只有真实可达（扇形/高度/遮挡都通过）才停步进入战斗姿态；
	# 被石头挡住的继续寻路，不能在这里假装能打。
	if not _spatial_can_attack():
		return false
	dbg_can += 1
	_close_hold = true
	if _attack_cooldown > 0.0:
		return false
	var started := trigger_attack(target.global_position)
	if started:
		dbg_grant += 1
	return started


func _pick_wander() -> void:
	var direction := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	if direction.length_squared() < 0.01:
		direction = Vector3.FORWARD
	if is_instance_valid(target) and randf() < 0.5:
		var to_target := target.global_position - global_position
		to_target.y = 0.0
		if to_target.length_squared() > 0.01:
			direction = direction.normalized() * 0.4 + to_target.normalized() * 0.6
	_wander_direction = direction.normalized()
	_wander_until_msec = Time.get_ticks_msec() + randi_range(600, 1200)


func _set_locomotion(next_state: State) -> void:
	if current_state != next_state:
		_reset_pose()
		current_state = next_state


func _reset_pose() -> void:
	torso_pivot.rotation = Vector3.ZERO
	torso_pivot.position.y = 0.75
	left_arm_pivot.rotation = Vector3.ZERO
	right_arm_pivot.rotation = Vector3.ZERO
	left_leg_pivot.rotation = Vector3.ZERO
	right_leg_pivot.rotation = Vector3.ZERO


func _stop_action(keep_reservation := false) -> void:
	_attack_area.cancel()
	if not keep_reservation: _crowd.release_attack()
	if _action_tween != null and _action_tween.is_valid():
		_action_tween.kill()
	_action_tween = null


## Pure pose anchors: visual geometry is shared, not owned by the actor.
## Compatible with the original animation and melee Tween targets.
func _build_procedural_mesh() -> void:
	visual_root = Node3D.new()
	visual_root.name = "VisualRoot"
	add_child(visual_root)

	torso_pivot = Node3D.new()
	torso_pivot.name = "TorsoPivot"
	torso_pivot.position.y = 0.75
	visual_root.add_child(torso_pivot)

	head_core = Node3D.new()
	head_core.name = "CoreAnchor"
	head_core.position = Vector3(0.0, 0.12, 0.32)
	head_core.rotation_degrees = Vector3(45.0, 45.0, 0.0)
	torso_pivot.add_child(head_core)

	left_arm_pivot = Node3D.new()
	left_arm_pivot.name = "LeftArm"
	left_arm_pivot.position = Vector3(-0.45, 0.15, 0.0)
	torso_pivot.add_child(left_arm_pivot)

	right_arm_pivot = Node3D.new()
	right_arm_pivot.name = "RightArm"
	right_arm_pivot.position = Vector3(0.45, 0.15, 0.0)
	torso_pivot.add_child(right_arm_pivot)

	left_leg_pivot = Node3D.new()
	left_leg_pivot.name = "LeftLeg"
	left_leg_pivot.position = Vector3(-0.22, 0.35, 0.0)
	visual_root.add_child(left_leg_pivot)

	right_leg_pivot = Node3D.new()
	right_leg_pivot.name = "RightLeg"
	right_leg_pivot.position = Vector3(0.22, 0.35, 0.0)
	visual_root.add_child(right_leg_pivot)


func _setup_collision() -> void:
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	var shape := CapsuleShape3D.new()
	shape.radius = get_body_dimensions().x * 0.5
	shape.height = get_body_dimensions().y
	_collision.shape = shape
	add_child(_collision)


func _animate_idle(t: float) -> void:
	torso_pivot.position.y = 0.75 + sin(t * 3.0) * 0.03
	head_core.rotation_degrees.z = 45.0 + sin(t * 2.0) * 10.0
	left_arm_pivot.rotation.x = sin(t * 2.5) * 0.08
	right_arm_pivot.rotation.x = -sin(t * 2.5) * 0.08


func _animate_walk(t: float) -> void:
	var w_speed := _p("walk_frequency")
	left_leg_pivot.rotation.x = sin(t * w_speed) * 0.65
	right_leg_pivot.rotation.x = -sin(t * w_speed) * 0.65
	torso_pivot.rotation.z = sin(t * w_speed * 0.5) * 0.12
	torso_pivot.position.y = 0.75 + abs(sin(t * w_speed)) * _p("walk_bob")
	left_arm_pivot.rotation.x = -sin(t * w_speed) * 0.5
	right_arm_pivot.rotation.x = sin(t * w_speed) * 0.5


func trigger_attack(target_pos: Vector3) -> bool:
	if current_state not in [State.IDLE, State.WALK]:
		return false
	if not _crowd.request_attack("punch"):
		return false
	_stop_action(true)
	_reset_pose()
	var direction := target_pos - global_position
	direction.y = 0.0
	if not direction.is_zero_approx():
		rotation.y = atan2(-direction.x, -direction.z)
	# 蓄力开始时锁定方向，玩家可在配置的前摇期间移开或打断。
	current_state = State.ATTACK
	_attack_target = target
	_attack_cooldown = attack_interval
	velocity.x = 0.0
	velocity.z = 0.0
	_attack_area.prepare(global_transform, _attack_spec(), attack_damage * _damage_scale,
		_p("attack_windup") + _p("attack_swing"))
	Telemetry.enemy_attack_started(self, "傀儡挥拳")
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees", Vector3(-95, 20, 0), _p("attack_windup"))
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees", Vector3(-10, -25, 5), _p("attack_windup"))
	_action_tween.tween_callback(_attack_area.lock)
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees", Vector3(55, -10, 0), _p("attack_swing")).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees", Vector3(15, 10, 0), _p("attack_swing")).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	_action_tween.tween_callback(_on_attack_hit_frame)
	_action_tween.tween_property(right_arm_pivot, "rotation_degrees", Vector3.ZERO, _p("attack_recovery")).set_trans(Tween.TRANS_SINE)
	_action_tween.parallel().tween_property(torso_pivot, "rotation_degrees", Vector3.ZERO, _p("attack_recovery")).set_trans(Tween.TRANS_SINE)
	_action_tween.tween_callback(_finish_action)
	return true


func _on_attack_hit_frame() -> void:
	if current_state != State.ATTACK or not _attack_area.strike():
		return
	if _attack_area.can_hit(_attack_target, _attack_area.origin):
		Telemetry.hurt_player(_attack_target, _attack_area.damage, _attack_area.origin, 1.0,
			Telemetry.source_info(self, "傀儡挥拳"))
	_attack_area.recover()


func _spatial_can_attack() -> bool:
	return _spatial_attack_pose(global_transform)

func _spatial_attack_pose(pose: Transform3D) -> bool:
	return is_instance_valid(target) and AttackArea.candidate_can_hit(self, pose, _attack_spec(), target)


func _attack_spec() -> Dictionary:
	return {"kind": "sector", "radius": (attack_distance + _p("attack_reach_extra")) * _crowd.size_multiplier,
		"angle": _p("attack_angle") * 2.0, "height": 2.0 * _crowd.size_multiplier, "ground_effect": false}


func apply_grenade_stagger(seconds: float) -> void:
	trigger_hit_stagger(_push_velocity, seconds)

func trigger_hit_stagger(knockback_dir: Vector3, minimum_seconds: float = 0.0) -> void:
	if current_state == State.DEAD or not _reactions.allow_normal_stagger():
		return
	_stop_action()
	_reset_pose()
	current_state = State.STAGGER
	_push_velocity = Vector3(knockback_dir.x, 0.0, knockback_dir.z)
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.tween_property(torso_pivot, "rotation_degrees", Vector3(-35, randf_range(-15, 15), 0), _p("stagger_hit_time")).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_action_tween.tween_interval(maxf(minimum_seconds - _p("stagger_hit_time") - _p("stagger_recovery"), 0.0))
	_action_tween.tween_property(torso_pivot, "rotation_degrees", Vector3.ZERO, _p("stagger_recovery")).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_action_tween.tween_callback(_finish_action)


func _finish_action() -> void:
	_attack_area.cancel()
	_crowd.release_attack()
	if current_state == State.DEAD:
		return
	_reset_pose()
	current_state = State.IDLE


func take_damage(amount: float) -> void:
	if current_state == State.DEAD or amount <= 0.0:
		return
	var before := health
	health = maxf(health - preload("res://scripts/combat_damage.gd").armored(self, amount, _armor), 0.0)
	Telemetry.enemy_damaged(self, before)
	if health < before:
		_flash_remaining = _p("hit_flash_duration")
		_health_label_until_msec = Time.get_ticks_msec() + 1500
		if is_instance_valid(_health_label):
			_health_label.visible = true
	if bool(get_meta(&"experiment_invincible", false)):
		health = maxf(health, 1.0)
	_update_health_label()
	if health <= 0.0:
		Lifecycle.credit_player(self, target)
		trigger_death_scatter()
	elif bool(_tuning.stagger_on_damage) and not Telemetry.manages_reaction(self):
		trigger_hit_stagger(Vector3.ZERO)


func combat_reaction_begin(_mode: int) -> void:
	_steering.spatial.cancel_motion()
	_stop_action()
	_reset_pose()
	_push_velocity = Vector3.ZERO
	current_state = State.COMBAT_REACTION


func combat_reaction_end() -> void:
	_finish_action()


func combat_reaction_ground_velocity(goal: Vector3, desired: Vector3, delta: float) -> Vector3:
	return _steering.ground_velocity(goal, _crowd.steer(desired, goal, delta), delta)


func combat_reaction_pose(mode: int, delta: float) -> void:
	if mode == Reactions.Mode.EVADE:
		if Vector2(velocity.x, velocity.z).length() > 0.1:
			rotation.y = rotate_toward(rotation.y, atan2(-velocity.x, -velocity.z), delta * _p("turn_speed"))
		_animate_walk(anim_clock)
	else:
		torso_pivot.rotation_degrees.x = -25.0


func apply_push(direction: Vector3, force: float) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	trigger_hit_stagger(flat.normalized() * maxf(force, 0.0) * _p("push_multiplier"))


func _update_health_label() -> void:
	_health_label.text = "泥土傀儡  %d/%d" % [ceili(health), ceili(max_health)]


func trigger_death_scatter() -> void:
	if current_state == State.DEAD:
		return
	current_state = State.DEAD
	health = 0.0
	_flash_remaining = 0.0
	Lifecycle.begin_death(self)
	_stop_action()
	_collision.set_deferred("disabled", true)
	collision_layer = 0
	collision_mask = 0
	# 碎片挂在测试场根节点，重开时与子弹等动态内容一起清理。
	var debris_parent := get_tree().current_scene
	if debris_parent == null:
		debris_parent = get_parent()
	preload("res://scripts/combat_fx.gd").spawn_ground_burst(debris_parent, global_position, 1.2)
	var debris: Array[Dictionary] = _render_batch.debris_parts(self) if is_instance_valid(_render_batch) else []
	# Remove the world batch instance before spawning rigidbody fragments.
	if is_instance_valid(_render_batch):
		_render_batch.unregister(self)
	for part in debris:
		var world_transform: Transform3D = part.transform
		var rb := RigidBody3D.new()
		rb.name = "MudGolemDebris"
		rb.mass = _p("debris_mass")
		rb.add_to_group("mud_golem_debris")
		rb.add_to_group("enemy_death_effect")
		rb.collision_layer = 0
		rb.collision_mask = 1
		debris_parent.add_child(rb)
		Lifecycle.register_effect(self, rb)
		# 把世界缩放保留在网格，刚体仅保留位置和旋转，避免物理缩放。
		rb.global_transform = Transform3D(world_transform.basis.orthonormalized(), world_transform.origin)
		var fragment := MeshInstance3D.new()
		fragment.name = "MudGolemFragment"
		fragment.mesh = part.mesh
		fragment.material_override = part.material
		fragment.transform = Transform3D(Basis.from_scale(world_transform.basis.get_scale()), Vector3.ZERO)
		rb.add_child(fragment)
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = (part.mesh as Mesh).get_aabb().size * world_transform.basis.get_scale().abs()
		col.shape = box
		rb.add_child(col)
		var horizontal := _p("scatter_horizontal")
		rb.apply_central_impulse(Vector3(randf_range(-horizontal, horizontal), randf_range(_p("scatter_up_min"), _p("scatter_up_max")), randf_range(-horizontal, horizontal)) * rb.mass)
		rb.apply_torque_impulse(Vector3(randf(), randf(), randf()) * _p("scatter_torque"))
		# 子节点计时器随碎片销毁和暂停，避免重开留下回调。
		var lifetime := Timer.new()
		lifetime.one_shot = true
		lifetime.wait_time = _p("debris_lifetime")
		rb.add_child(lifetime)
		lifetime.timeout.connect(rb.queue_free)
		lifetime.start()
	queue_free()


static func get_body_dimensions(_values: Dictionary = {}) -> Vector3:
	return Vector3(0.9, 1.3, 0.9)
