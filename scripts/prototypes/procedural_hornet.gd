class_name ProceduralHornet
extends CharacterBody3D
## 三针盘旋、锁向俯冲与触地解体；全部战斗数值来自独立配置。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Targeting := preload("res://scripts/targeting.gd")
const Crowd := preload("res://scripts/prototypes/enemy_crowd.gd")
const Needle := preload("res://scripts/prototypes/hornet_needle.gd")
const DeathBody := preload("res://scripts/prototypes/hornet_death_body.gd")
const PROFILE_ID := "PrototypeHornet"
const VISUAL_OFFSET := -1.0 # 原稿胸部原点换算到球形碰撞中心。
enum State { HOVER_STRAFE, PREPARE_FIRE, FIRE_RECOVER, SWOOP_WINDUP, SWOOP_DIVE, SWOOP_RECOVER, HIT_STAGGER, DEAD }
var current_state: State = State.HOVER_STRAFE
@export var ai_enabled := true
var health: float
var max_health: float
var move_speed: float
var projectile_damage: float
var fire_interval: float
var attack_damage: float
var attack_interval: float
var _armor: float
var _damage_scale := 1.0
var target: Node3D
var flight_clock := 0.0
var state_timer := 0.0
var strafe_dir := 1.0
var remaining_needles: int
var stingers: Array[MeshInstance3D] = []
var visual_root: Node3D
var thorax_node: Node3D
var head_pivot: Node3D
var jaw_left: Node3D
var jaw_right: Node3D
var abdomen_pivot: Node3D
var abdomen_segments: Array[Node3D] = []
var wings: Array[MeshInstance3D] = []
var legs: Array[Node3D] = []
var breakable_parts: Array[MeshInstance3D] = []
var _collision: CollisionShape3D
var _health_label: Label3D
var _tuning: Dictionary
var _crowd := Crowd.new()
var _dive_direction := Vector3.FORWARD


func _ready() -> void:
	_tuning = Tuning.resolve(self, PROFILE_ID)
	if _tuning.is_empty():
		queue_free()
		return
	set_meta(&"crowd_airborne", true)
	_crowd.setup(self, _tuning, PROFILE_ID)
	_tuning = _crowd.varied_values(_tuning, ["flight_speed", "dive_speed", "radial_speed", "pull_up_speed", "pull_back_speed"], ["needle_damage", "bite_damage"],
		["fire_interval", "fire_windup", "fire_recovery", "dive_interval", "dive_windup", "dive_max_time", "recovery_pose_time", "recovery_wait"])
	max_health = _p("max_health")
	health = max_health
	move_speed = _p("flight_speed")
	projectile_damage = _p("needle_damage")
	fire_interval = _p("fire_interval")
	attack_damage = _p("bite_damage")
	attack_interval = _p("dive_interval")
	_armor = _p("armor")
	remaining_needles = int(_p("needle_count"))
	flight_clock = _crowd.phase
	strafe_dir = 1.0 if randf() > 0.5 else -1.0
	add_to_group("enemies")
	collision_layer = 4
	collision_mask = 3
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_build_hornet_mesh()
	visual_root.position.y = VISUAL_OFFSET
	for index in range(stingers.size()):
		stingers[index].visible = index < remaining_needles
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	var sphere := SphereShape3D.new()
	sphere.radius = _p("collision_radius")
	_collision.shape = sphere
	add_child(_collision)
	_health_label = Label3D.new()
	_health_label.name = "HealthLabel"
	_health_label.position.y = 1.05
	_health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_health_label.font_size = 28
	_health_label.pixel_size = 0.006
	add_child(_health_label)
	_update_health_label()


func _p(key: String) -> float:
	return float(_tuning[key])


func get_spawn_height(player_height: float) -> float:
	return maxf(player_height + _p("hover_altitude") + _crowd.height_offset, _collision.shape.radius * scale.y + 0.08)


func _target_alive() -> bool:
	return is_instance_valid(target) and float(target.get("health")) > 0.0


func _physics_process(delta: float) -> void:
	if current_state == State.DEAD:
		return
	_crowd.tick(delta)
	flight_clock += delta * _crowd.gait_multiplier
	state_timer += delta
	_animate_wings()
	if ai_enabled and not _target_alive():
		target = Targeting.nearest_player(self)
	if current_state in [State.PREPARE_FIRE, State.SWOOP_WINDUP, State.SWOOP_DIVE] and not _target_alive():
		_enter_hover()
	var desired := Vector3.ZERO
	var response := _p("flight_response")
	match current_state:
		State.HOVER_STRAFE:
			_animate_hover_idle()
			if ai_enabled and _crowd.ready_to_move() and _target_alive():
				desired = _orbital_velocity(delta)
				var distance := global_position.distance_to(target.global_position)
				if remaining_needles > 0 and state_timer >= fire_interval and distance <= _p("needle_range"):
					trigger_fire()
				elif remaining_needles == 0 and state_timer >= attack_interval and distance <= _p("dive_range"):
					trigger_swoop_dive()
		State.PREPARE_FIRE:
			response = _p("fire_drag")
			_look_at_target(delta)
			abdomen_pivot.rotation_degrees.x = lerpf(abdomen_pivot.rotation_degrees.x, _p("aim_abdomen_angle"), 1.0 - exp(-_p("aim_response") * delta))
			if state_timer >= _p("fire_windup"):
				_launch_stinger_needle()
				_set_state(State.FIRE_RECOVER)
		State.FIRE_RECOVER:
			response = _p("fire_drag")
			if state_timer >= _p("fire_recovery"):
				strafe_dir *= -1.0
				_enter_hover()
		State.SWOOP_WINDUP:
			response = _p("fire_drag")
			_look_at_target(delta)
			var progress := clampf(state_timer / _p("dive_windup"), 0.0, 1.0)
			visual_root.position.y = VISUAL_OFFSET + _p("dive_lift") * progress
			head_pivot.rotation_degrees.x = _p("dive_head_angle") * progress
			jaw_left.rotation_degrees.y = _p("jaw_open_angle") * progress
			jaw_right.rotation_degrees.y = -_p("jaw_open_angle") * progress
			if state_timer >= _p("dive_windup"):
				_dive_direction = (target.global_position + Vector3.UP * _p("dive_aim_height") - global_position).normalized()
				velocity = _dive_direction * _p("dive_speed")
				_set_state(State.SWOOP_DIVE)
		State.SWOOP_DIVE:
			desired = _dive_direction * _p("dive_speed")
			jaw_left.rotation_degrees.y = sin(flight_clock * _p("bite_frequency")) * _p("bite_angle")
			jaw_right.rotation_degrees.y = -jaw_left.rotation_degrees.y
		State.SWOOP_RECOVER:
			desired = global_basis.z * _p("pull_back_speed")
			desired.y = clampf((_hover_height() - global_position.y) * _p("height_response"), -_p("pull_up_speed"), _p("pull_up_speed"))
			var progress := clampf(state_timer / _p("recovery_pose_time"), 0.0, 1.0)
			visual_root.position.y = VISUAL_OFFSET + _p("dive_lift") * (1.0 - progress)
			head_pivot.rotation_degrees.x = _p("dive_head_angle") * (1.0 - progress)
			jaw_left.rotation_degrees.y = _p("jaw_open_angle") * (1.0 - progress)
			jaw_right.rotation_degrees.y = -jaw_left.rotation_degrees.y
			if state_timer >= _p("recovery_pose_time") + _p("recovery_wait"):
				_enter_hover()
		State.HIT_STAGGER:
			response = _p("stagger_drag")
			var progress := minf(state_timer / _p("stagger_in"), 1.0)
			if state_timer > _p("stagger_in") + _p("stagger_hold"):
				progress = 1.0 - clampf((state_timer - _p("stagger_in") - _p("stagger_hold")) / _p("stagger_out"), 0.0, 1.0)
			thorax_node.rotation_degrees.x = _p("stagger_angle") * progress
			if state_timer >= _p("stagger_in") + _p("stagger_hold") + _p("stagger_out"):
				_enter_hover()
	if current_state == State.SWOOP_DIVE:
		velocity = _dive_direction * _p("dive_speed")
	else:
		velocity = velocity.lerp(desired, 1.0 - exp(-response * delta))
	var previous := global_position
	move_and_slide()
	if current_state == State.SWOOP_DIVE:
		_check_dive_hit(previous)
		if current_state == State.SWOOP_DIVE and (state_timer >= _p("dive_max_time") or get_slide_collision_count() > 0):
			_dive_pull_up()


func _hover_height() -> float:
	var base := target.global_position.y if _target_alive() else global_position.y - _p("hover_altitude")
	return maxf(base + _p("hover_altitude") + _crowd.air_height(), _collision.shape.radius * scale.y + 0.08)


func _orbital_velocity(delta: float) -> Vector3:
	var offset := global_position - target.global_position
	offset.y = 0.0
	var distance := offset.length()
	var approaching := distance > _p("strafe_distance") + _p("orbit_band")
	var desired: Vector3
	if approaching:
		desired = -offset.normalized() * move_speed
	else:
		var radial := offset.normalized() * _p("radial_speed") if distance < _p("strafe_distance") - _p("orbit_band") else Vector3.ZERO
		desired = offset.cross(Vector3.UP).normalized() * strafe_dir * move_speed + radial
	desired += Vector3(sin(flight_clock * 2.5), 0, cos(flight_clock * 2.0)) * _p("turbulence_strength")
	desired.y = clampf((_hover_height() - global_position.y) * _p("height_response"), -_p("vertical_speed_limit"), _p("vertical_speed_limit"))
	desired = _crowd.steer_air(desired, target.global_position, delta, approaching)
	_look_at_target(delta)
	thorax_node.rotation_degrees.z = lerpf(thorax_node.rotation_degrees.z, -strafe_dir * _p("bank_angle") if not approaching else 0.0, 1.0 - exp(-_p("flight_response") * delta))
	return desired


func _look_at_target(delta: float) -> void:
	if not _target_alive():
		return
	var offset := target.global_position - global_position
	offset.y = 0.0
	if not offset.is_zero_approx():
		rotation.y = lerp_angle(rotation.y, atan2(-offset.x, -offset.z), 1.0 - exp(-_p("turn_speed") * delta))


func _set_state(next: State) -> void:
	current_state = next
	state_timer = 0.0


func _enter_hover() -> void:
	_crowd.release_attack()
	visual_root.position.y = VISUAL_OFFSET
	thorax_node.rotation = Vector3.ZERO
	head_pivot.rotation = Vector3.ZERO
	jaw_left.rotation = Vector3.ZERO
	jaw_right.rotation = Vector3.ZERO
	_set_state(State.HOVER_STRAFE)


func trigger_fire() -> void:
	if current_state != State.HOVER_STRAFE or not _target_alive() or remaining_needles <= 0 or not _crowd.request_attack():
		return
	_set_state(State.PREPARE_FIRE)


func _launch_stinger_needle() -> void:
	if remaining_needles <= 0 or not _target_alive():
		return
	remaining_needles -= 1
	var origin := stingers[remaining_needles].global_position
	stingers[remaining_needles].visible = false
	var needle := Needle.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.03
	mesh.bottom_radius = 0.08
	mesh.height = 0.7
	mesh.radial_segments = 4
	needle.mesh = mesh
	needle.material_override = stingers[remaining_needles].material_override
	needle.direction = (target.global_position + Vector3.UP * _p("needle_aim_height") - origin).normalized()
	needle.speed = _p("needle_range") / _p("needle_travel_time")
	needle.remaining_range = _p("needle_range")
	needle.damage = projectile_damage
	needle.source_info = Telemetry.source_info(self, "晶针射击")
	needle.add_to_group("hornet_needles")
	get_tree().current_scene.add_child(needle)
	needle.global_position = origin
	needle.look_at(origin + needle.direction, Vector3.FORWARD if absf(needle.direction.dot(Vector3.UP)) > 0.99 else Vector3.UP)
	needle.rotate_object_local(Vector3.RIGHT, -PI * 0.5)
	_update_health_label()


func trigger_swoop_dive() -> void:
	if current_state != State.HOVER_STRAFE or not _target_alive() or not _crowd.request_attack():
		return
	_set_state(State.SWOOP_WINDUP)


func _check_dive_hit(previous: Vector3) -> void:
	if not _target_alive():
		return
	var nearest := Geometry3D.get_closest_point_to_segment(target.global_position, previous, global_position)
	if nearest.distance_to(target.global_position) > _p("bite_radius") * scale.x:
		return
	var query := PhysicsRayQueryParameters3D.create(nearest, target.global_position, 1)
	if not get_world_3d().direct_space_state.intersect_ray(query).is_empty():
		return
	Telemetry.hurt_player(target, attack_damage, global_position, 1.0, Telemetry.source_info(self, "俯冲撕咬"))
	_dive_pull_up()


func _dive_pull_up() -> void:
	_set_state(State.SWOOP_RECOVER)
	velocity = Vector3.UP * _p("pull_up_speed") + global_basis.z * _p("pull_back_speed")


func take_damage(amount: float, hit_dir := Vector3.ZERO) -> void:
	if current_state == State.DEAD or amount <= 0.0:
		return
	var before := health
	health = maxf(health - amount * (1.0 - _armor), 0.0)
	Telemetry.enemy_damaged(self, before)
	_update_health_label()
	if health <= 0.0:
		if is_instance_valid(target) and target.has_method("register_enemy_kill"):
			target.call("register_enemy_kill")
		trigger_death_fall()
		return
	var direction := hit_dir.normalized() if not hit_dir.is_zero_approx() else global_basis.z
	trigger_hit_stagger(direction * _p("damage_recoil_speed"))


func trigger_hit_stagger(recoil: Vector3) -> void:
	_crowd.release_attack()
	_enter_hover()
	_set_state(State.HIT_STAGGER)
	velocity = recoil + Vector3.UP * _p("stagger_up_speed")


func apply_push(direction: Vector3, force: float) -> void:
	if current_state == State.DEAD:
		return
	trigger_hit_stagger(direction.normalized() * maxf(force, 0.0) * _p("push_multiplier"))


func _update_health_label() -> void:
	_health_label.text = "晶刺蜂  %d/%d  晶针 %d" % [ceili(health), ceili(max_health), remaining_needles]


func _animate_wings() -> void:
	var phase := flight_clock * _p("wing_frequency")
	for index in range(wings.size()):
		var side := 1.0 if index % 2 == 0 else -1.0
		var amplitude := _p("wing_amplitude") if index < 2 else _p("wing_rear_amplitude")
		wings[index].rotation_degrees.z = side * (sin(phase + (0.5 if index >= 2 else 0.0)) * amplitude - _p("wing_rest_angle"))


func _animate_hover_idle() -> void:
	abdomen_pivot.rotation_degrees.x = _p("abdomen_rest_angle") + sin(flight_clock * _p("abdomen_frequency")) * _p("abdomen_amplitude")
	for index in range(abdomen_segments.size()):
		abdomen_segments[index].rotation_degrees.x = 10.0 + sin(flight_clock * _p("abdomen_frequency") - index * 0.4) * 4.0
	for index in range(legs.size()):
		legs[index].rotation_degrees.x = sin(flight_clock * _p("leg_frequency") + index) * _p("leg_amplitude")
	visual_root.position.y = VISUAL_OFFSET + sin(flight_clock * _p("hover_bob_frequency")) * _p("hover_bob_amplitude")


func trigger_death_fall() -> void:
	_crowd.release_attack()
	_set_state(State.DEAD)
	_collision.set_deferred("disabled", true)
	for wing in wings:
		wing.queue_free()
	wings.clear()
	var body := DeathBody.new()
	body.tuning = _tuning.duplicate(true)
	body.mass = _p("death_body_mass")
	body.collision_layer = 0
	body.collision_mask = 1
	get_tree().current_scene.add_child(body)
	body.global_transform = Transform3D(global_basis.orthonormalized(), thorax_node.global_position)
	visual_root.reparent(body, true)
	for part in breakable_parts:
		if part.visible:
			body.parts.append(part)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 0.6, 1.2) * global_basis.get_scale().abs()
	collision.shape = box
	body.add_child(collision)
	var horizontal := _p("death_horizontal_impulse")
	body.apply_central_impulse(Vector3(randf_range(-horizontal, horizontal), _p("death_up_impulse"), randf_range(-horizontal, horizontal)))
	var torque := _p("death_torque")
	body.apply_torque_impulse(Vector3(torque, randf_range(-torque, torque), torque / 3.0))
	queue_free()


func _build_hornet_mesh() -> void:
	visual_root = Node3D.new()
	visual_root.name = "VisualRoot"
	add_child(visual_root)

	# --- 材质定义 ---
	var mat_carapace := StandardMaterial3D.new()
	mat_carapace.albedo_color = Color(0.18, 0.2, 0.22) # 黑曜石暗甲
	mat_carapace.roughness = 0.85
	mat_carapace.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mat_amber := StandardMaterial3D.new()
	mat_amber.albedo_color = Color(0.9, 0.45, 0.1) # 虎头蜂黄褐警戒纹
	mat_amber.roughness = 0.9
	mat_amber.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mat_crystal := StandardMaterial3D.new()
	mat_crystal.albedo_color = Color(0.1, 0.95, 0.85) # 青色晶刺/复眼
	mat_crystal.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var mat_wing := StandardMaterial3D.new()
	# 更饱和、更不透明的蓝色薄翼，让晶刺蜂在战斗距离也能读出飞行轮廓。
	mat_wing.albedo_color = Color(0.16, 0.58, 1.0, 0.72)
	mat_wing.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_wing.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_wing.cull_mode = BaseMaterial3D.CULL_DISABLED

	# --- 1. 胸腔（Thorax）---
	thorax_node = Node3D.new()
	thorax_node.position.y = 1.0
	visual_root.add_child(thorax_node)

	var thorax_mesh := CylinderMesh.new()
	thorax_mesh.top_radius = 0.35
	thorax_mesh.bottom_radius = 0.25
	thorax_mesh.height = 0.7
	thorax_mesh.radial_segments = 6 # 6棱多面体胸
	var th := _create_part("Thorax", thorax_mesh, mat_carapace, thorax_node)
	th.rotation_degrees.x = 90.0

	# --- 2. 头部与可咬合双动大牙（Head & Mandibles）---
	head_pivot = Node3D.new()
	head_pivot.position = Vector3(0.0, 0.05, -0.42)
	thorax_node.add_child(head_pivot)

	var skull_mesh := PrismMesh.new()
	skull_mesh.size = Vector3(0.38, 0.38, 0.3)
	var skull := _create_part("Skull", skull_mesh, mat_amber, head_pivot)
	skull.rotation_degrees = Vector3(-90, 0, 180)

	# 双侧复眼
	var eye_mesh := BoxMesh.new()
	eye_mesh.size = Vector3(0.1, 0.14, 0.22)
	var eye_l := _create_part("EyeL", eye_mesh, mat_crystal, head_pivot)
	eye_l.position = Vector3(-0.18, 0.05, -0.1)
	eye_l.rotation_degrees = Vector3(15, 20, 0)
	var eye_r := _create_part("EyeR", eye_mesh, mat_crystal, head_pivot)
	eye_r.position = Vector3(0.18, 0.05, -0.1)
	eye_r.rotation_degrees = Vector3(15, -20, 0)

	# 左剪刀牙
	jaw_left = Node3D.new()
	jaw_left.position = Vector3(-0.12, -0.12, -0.2)
	head_pivot.add_child(jaw_left)
	var jaw_l_mesh := BoxMesh.new()
	jaw_l_mesh.size = Vector3(0.08, 0.08, 0.28)
	var jl := _create_part("JawL_Mesh", jaw_l_mesh, mat_carapace, jaw_left)
	jl.position.z = -0.12
	jl.rotation_degrees.y = -15.0

	# 右剪刀牙
	jaw_right = Node3D.new()
	jaw_right.position = Vector3(0.12, -0.12, -0.2)
	head_pivot.add_child(jaw_right)
	var jaw_r_mesh := BoxMesh.new()
	jaw_r_mesh.size = Vector3(0.08, 0.08, 0.28)
	var jr := _create_part("JawR_Mesh", jaw_r_mesh, mat_carapace, jaw_right)
	jr.position.z = -0.12
	jr.rotation_degrees.y = 15.0

	# --- 3. 四翼（Wings）---
	# 翅膀承担飞行敌人的第一识别特征：前翼更长更宽，后翼略短，
	# 并向身体两侧展开，避免原版细长薄片在远处几乎消失。
	wings.clear()
	_create_wing("WingFL", Vector3(-0.42, 0.25, -0.08), Vector3(0.72, 0.025, 1.2), mat_wing, -18.0)
	_create_wing("WingFR", Vector3(0.42, 0.25, -0.08), Vector3(0.72, 0.025, 1.2), mat_wing, 18.0)
	_create_wing("WingBL", Vector3(-0.36, 0.22, 0.22), Vector3(0.55, 0.025, 0.85), mat_wing, -28.0)
	_create_wing("WingBR", Vector3(0.36, 0.22, 0.22), Vector3(0.55, 0.025, 0.85), mat_wing, 28.0)

	# --- 4. 三段铰接腹腔与晶刺（Abdomen & 3 Needles）---
	abdomen_segments.clear()
	stingers.clear()

	abdomen_pivot = Node3D.new()
	abdomen_pivot.position = Vector3(0.0, -0.05, 0.35)
	thorax_node.add_child(abdomen_pivot)

	var parent_ab: Node3D = abdomen_pivot
	for i in range(3):
		var ab_node := Node3D.new()
		ab_node.position.z = 0.3
		parent_ab.add_child(ab_node)
		abdomen_segments.append(ab_node)

		var ab_mesh := CylinderMesh.new()
		ab_mesh.radial_segments = 6
		var factor := 1.0 + float(i) * 0.15 if i < 2 else 0.7
		ab_mesh.top_radius = 0.32 * factor
		ab_mesh.bottom_radius = 0.25 * factor
		ab_mesh.height = 0.35
		var seg := _create_part("Abdomen_%d" % i, ab_mesh, mat_amber if i % 2 == 0 else mat_carapace, ab_node)
		seg.rotation_degrees.x = 80.0
		parent_ab = ab_node

	# 在第 3 节末端挂载 3 根发光晶刺
	var needle_mesh := CylinderMesh.new()
	needle_mesh.top_radius = 0.02
	needle_mesh.bottom_radius = 0.06
	needle_mesh.height = 0.55
	needle_mesh.radial_segments = 4 # 菱面尖锐刺

	var stinger_offsets := [
		Vector3(-0.09, 0.08, 0.25),
		Vector3(0.09, 0.08, 0.25),
		Vector3(0.0, -0.1, 0.25)
	]

	for i in range(3):
		var st_node := _create_part("Stinger_%d" % i, needle_mesh, mat_crystal, parent_ab)
		st_node.position = stinger_offsets[i]
		st_node.rotation_degrees.x = 90.0
		stingers.append(st_node)

	# --- 5. 六条节肢（细爪）---
	legs.clear()
	for i in range(3):
		var z_pos := -0.15 + float(i) * 0.18
		_create_leg("L", Vector3(-0.25, -0.2, z_pos), mat_carapace)
		_create_leg("R", Vector3(0.25, -0.2, z_pos), mat_carapace)

func _create_wing(
	part_name: String, pos: Vector3, size: Vector3, mat: Material, yaw_degrees: float = 0.0
) -> void:
	var w_node := MeshInstance3D.new()
	w_node.name = part_name
	var mesh := BoxMesh.new()
	mesh.size = size
	w_node.mesh = mesh
	w_node.material_override = mat
	w_node.position = pos
	w_node.rotation_degrees.y = yaw_degrees
	thorax_node.add_child(w_node)
	wings.append(w_node)

func _create_leg(side: String, offset: Vector3, mat: Material) -> void:
	var leg_root := Node3D.new()
	leg_root.position = offset
	thorax_node.add_child(leg_root)
	legs.append(leg_root)

	var upper := MeshInstance3D.new()
	var u_mesh := BoxMesh.new()
	u_mesh.size = Vector3(0.05, 0.35, 0.05)
	upper.mesh = u_mesh
	upper.material_override = mat
	upper.position = Vector3(-0.08 if side == "L" else 0.08, -0.15, 0.0)
	upper.rotation_degrees.z = 25.0 if side == "L" else -25.0
	leg_root.add_child(upper)
	breakable_parts.append(upper)

func _create_part(part_name: String, mesh: Mesh, mat: Material, parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	parent.add_child(mi)
	breakable_parts.append(mi)
	return mi

