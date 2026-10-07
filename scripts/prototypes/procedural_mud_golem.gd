class_name ProceduralMudGolem
extends CharacterBody3D
const Nav := preload("res://scripts/nav_steering.gd")
const GroundMovement := preload("res://scripts/ground_movement.gd")
const SpatialProfile := preload("res://scripts/combat_spatial_profile.gd")
@export var combat_spatial_profile: SpatialProfile = preload("res://data/combat_spatial/ground.tres")
var _steering := Nav.new()
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
var _attack_area := AttackArea.new()
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

var health: float
var _tuning: Dictionary = {}
var target: CharacterBody3D
# 测试场统计读取与正式敌人一致的字段。
var _armor := 0.0
var _damage_scale := 1.0
var visual_root: Node3D
var torso_pivot: Node3D
var head_core: MeshInstance3D
var left_arm_pivot: Node3D
var right_arm_pivot: Node3D
var left_leg_pivot: Node3D
var right_leg_pivot: Node3D
var body_parts: Array[MeshInstance3D] = []
var anim_clock := 0.0
var _collision: CollisionShape3D
var _action_tween: Tween
var _attack_cooldown := 0.0
var _push_velocity := Vector3.ZERO
var _health_label: Label3D


func _ready() -> void:
	add_child(_attack_area)
	_tuning = Tuning.resolve(self, PROFILE_ID)
	if _tuning.is_empty():
		queue_free()
		return
	_crowd.setup(self, _tuning, PROFILE_ID)
	_tuning = _crowd.varied_values(_tuning, ["move_speed"], ["attack_damage"],
		["attack_interval", "attack_windup", "attack_swing", "attack_recovery"])
	anim_clock = _crowd.phase
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
	_reactions.setup(self, combat_reaction_profile, _collision)


func _p(key: String) -> float:
	return float(_tuning[key])


func _physics_process(delta: float) -> void:
	if current_state == State.ATTACK and (not is_instance_valid(_attack_target) or float(_attack_target.get("health")) <= 0.0):
		_stop_action()
		_finish_action()
	if current_state == State.DEAD:
		return
	_crowd.tick(delta)
	anim_clock += delta * _crowd.gait_multiplier
	_attack_cooldown = maxf(_attack_cooldown - delta, 0.0)
	if _reactions.step(delta, ai_enabled and current_state in [State.IDLE, State.WALK, State.ATTACK], move_speed):
		return
	if _steering.tick(delta, ai_enabled and _crowd.ready_to_move() and current_state in [State.IDLE, State.WALK], target, move_speed):
		_animate_walk(anim_clock)
		return
	var desired := Vector3.ZERO
	if ai_enabled and _crowd.ready_to_move() and current_state in [State.IDLE, State.WALK]:
		if is_instance_valid(target) and float(target.get("health")) > 0.0:
			var offset := target.global_position - global_position
			offset.y = 0.0
			var distance := offset.length()
			if distance > 0.001:
				var direction := offset / distance
				rotation.y = rotate_toward(rotation.y, atan2(-direction.x, -direction.z), delta * _p("turn_speed"))
				if not _spatial_can_attack():
					_set_locomotion(State.WALK)
					desired = _crowd.steer(direction * move_speed, target.global_position, delta)
					desired = _steering.ground_velocity(target.global_position, desired, delta)
					if not desired.is_zero_approx():
						rotation.y = rotate_toward(rotation.y, atan2(-desired.x, -desired.z), delta * _p("turn_speed"))
				elif _attack_cooldown <= 0.0:
					trigger_attack(target.global_position)
					if current_state != State.ATTACK and _crowd.enabled():
						_set_locomotion(State.WALK)
						desired = _crowd.waiting_velocity(target.global_position, move_speed, delta)
				else:
					_set_locomotion(State.IDLE)
		else:
			_set_locomotion(State.IDLE)
	match current_state:
		State.IDLE:
			_animate_idle(anim_clock)
		State.WALK:
			_animate_walk(anim_clock)
	# 重力和击退在待机、攻击、硬直时也持续，避免悬空或穿过地板。
	velocity.x = move_toward(velocity.x, desired.x + _push_velocity.x, delta * _p("acceleration"))
	velocity.z = move_toward(velocity.z, desired.z + _push_velocity.z, delta * _p("acceleration"))
	_push_velocity = _push_velocity.move_toward(Vector3.ZERO, delta * _p("push_decay"))
	if is_on_floor():
		velocity.y = -0.5
	else:
		velocity.y -= _p("gravity") * delta
	GroundMovement.move(self, delta)


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


func _stop_action() -> void:
	_attack_area.cancel()
	_crowd.release_attack()
	if _action_tween != null and _action_tween.is_valid():
		_action_tween.kill()
	_action_tween = null


func _build_procedural_mesh() -> void:
	visual_root = Node3D.new()
	visual_root.name = "VisualRoot"
	add_child(visual_root)

	# --- 材质定义（纯色、粗糙、无高光塑料感） ---
	var mat_mud := StandardMaterial3D.new()
	mat_mud.albedo_color = Color(0.28, 0.32, 0.22) # 苔藓深泥色
	mat_mud.roughness = 0.95
	mat_mud.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mat_stone := StandardMaterial3D.new()
	mat_stone.albedo_color = Color(0.42, 0.44, 0.45) # 岩石灰
	mat_stone.roughness = 0.9
	mat_stone.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mat_core := StandardMaterial3D.new()
	mat_core.albedo_color = Color(0.1, 0.85, 0.9) # 亮青色晶核
	mat_core.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED # 自发光无视光照

	# --- 躯干基准点 (Torso Pivot) ---
	torso_pivot = Node3D.new()
	torso_pivot.position.y = 0.75
	visual_root.add_child(torso_pivot)

	# 躯干：使用 5 棱圆台（极具低多边形切面感）
	var torso_mesh := CylinderMesh.new()
	torso_mesh.top_radius = 0.4
	torso_mesh.bottom_radius = 0.25
	torso_mesh.height = 0.6
	torso_mesh.radial_segments = 5 # 关键：5面硬棱角
	torso_mesh.rings = 0
	var torso_node := _create_part("Torso", torso_mesh, mat_mud, torso_pivot)
	torso_node.position.y = 0.0

	# 核心/眼睛：内嵌发光四方晶石
	var core_mesh := BoxMesh.new()
	core_mesh.size = Vector3(0.16, 0.16, 0.16)
	head_core = _create_part("Core", core_mesh, mat_core, torso_pivot)
	head_core.position = Vector3(0.0, 0.12, 0.32)
	head_core.rotation_degrees = Vector3(45, 45, 0) # 菱形斜角嵌入

	# --- 手臂与拳头 (Arms) ---
	# 左臂 Pivot
	left_arm_pivot = Node3D.new()
	left_arm_pivot.position = Vector3(-0.45, 0.15, 0.0)
	torso_pivot.add_child(left_arm_pivot)
	var l_fist := _create_fist_mesh(mat_stone)
	l_fist.position = Vector3(-0.15, -0.3, 0.0)
	left_arm_pivot.add_child(l_fist)
	body_parts.append(l_fist)

	# 右臂 Pivot（主攻击手，略大一点）
	right_arm_pivot = Node3D.new()
	right_arm_pivot.position = Vector3(0.45, 0.15, 0.0)
	torso_pivot.add_child(right_arm_pivot)
	var r_fist := _create_fist_mesh(mat_stone)
	r_fist.position = Vector3(0.15, -0.3, 0.0)
	r_fist.scale = Vector3(1.15, 1.15, 1.15)
	right_arm_pivot.add_child(r_fist)
	body_parts.append(r_fist)

	# --- 短腿 (Legs) ---
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(0.18, 0.35, 0.22)

	left_leg_pivot = Node3D.new()
	left_leg_pivot.position = Vector3(-0.22, 0.35, 0.0)
	visual_root.add_child(left_leg_pivot)
	var l_leg := _create_part("LeftLeg", leg_mesh, mat_mud, left_leg_pivot)
	l_leg.position.y = -0.15

	right_leg_pivot = Node3D.new()
	right_leg_pivot.position = Vector3(0.22, 0.35, 0.0)
	visual_root.add_child(right_leg_pivot)
	var r_leg := _create_part("RightLeg", leg_mesh, mat_mud, right_leg_pivot)
	r_leg.position.y = -0.15

# 辅助生成器：构造具有切面厚重感的大拳头
func _create_fist_mesh(mat: Material) -> MeshInstance3D:
	var fist := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.28, 0.42, 0.32)
	fist.mesh = mesh
	fist.material_override = mat
	return fist

func _create_part(part_name: String, mesh: Mesh, mat: Material, parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	body_parts.append(mi)
	return mi


func _setup_collision() -> void:
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	var shape := CapsuleShape3D.new()
	shape.radius = 0.45
	shape.height = 1.3
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


func trigger_attack(target_pos: Vector3) -> void:
	if current_state not in [State.IDLE, State.WALK]:
		return
	_stop_action()
	if not _crowd.request_attack():
		return
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
	_attack_area.prepare(global_transform, {"kind": "sector", "radius": (attack_distance + _p("attack_reach_extra")) * _crowd.size_multiplier,
		"angle": _p("attack_angle") * 2.0, "height": 2.0 * _crowd.size_multiplier, "ground_effect": false}, attack_damage * _damage_scale,
		_p("attack_windup") + _p("attack_swing"))
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


func _on_attack_hit_frame() -> void:
	if current_state != State.ATTACK or not _attack_area.strike():
		return
	if _attack_area.can_hit(_attack_target, _attack_area.global_position):
		Telemetry.hurt_player(_attack_target, _attack_area.damage, _attack_area.global_position, 1.0,
			Telemetry.source_info(self, "傀儡挥拳"))
	_attack_area.recover()


func _spatial_can_attack() -> bool:
	return _spatial_attack_pose(global_transform)

func _spatial_attack_pose(pose: Transform3D) -> bool:
	return is_instance_valid(target) and AttackArea.candidate_can_hit(self, pose,
		{"kind": "sector", "radius": (attack_distance + _p("attack_reach_extra")) * _crowd.size_multiplier,
		"angle": _p("attack_angle") * 2.0, "height": 2.0 * _crowd.size_multiplier, "ground_effect": false}, target)


func trigger_hit_stagger(knockback_dir: Vector3) -> void:
	if current_state == State.DEAD or not _reactions.allow_normal_stagger():
		return
	_stop_action()
	_reset_pose()
	current_state = State.STAGGER
	_push_velocity = Vector3(knockback_dir.x, 0.0, knockback_dir.z)
	_action_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_action_tween.tween_property(torso_pivot, "rotation_degrees", Vector3(-35, randf_range(-15, 15), 0), _p("stagger_hit_time")).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
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
	health = maxf(health - amount * (1.0 - _armor), 0.0)
	Telemetry.enemy_damaged(self, before)
	_update_health_label()
	if health <= 0.0:
		if Telemetry.credits_player(self) and is_instance_valid(target) and target.has_method("register_enemy_kill"):
			target.call("register_enemy_kill")
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
	_stop_action()
	_collision.set_deferred("disabled", true)
	collision_layer = 0
	collision_mask = 0
	# 碎片挂在测试场根节点，重开时与子弹等动态内容一起清理。
	var debris_parent := get_tree().current_scene
	if debris_parent == null:
		debris_parent = get_parent()
	for part in body_parts:
		if not is_instance_valid(part):
			continue
		var world_transform := part.global_transform
		var rb := RigidBody3D.new()
		rb.name = "MudGolemDebris"
		rb.mass = _p("debris_mass")
		rb.add_to_group("mud_golem_debris")
		rb.add_to_group("enemy_death_effect")
		rb.collision_layer = 0
		rb.collision_mask = 1
		debris_parent.add_child(rb)
		# 把世界缩放保留在网格，刚体仅保留位置和旋转，避免物理缩放。
		rb.global_transform = Transform3D(world_transform.basis.orthonormalized(), world_transform.origin)
		part.reparent(rb, false)
		part.transform = Transform3D(Basis.from_scale(world_transform.basis.get_scale()), Vector3.ZERO)
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = part.mesh.get_aabb().size * world_transform.basis.get_scale().abs()
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
