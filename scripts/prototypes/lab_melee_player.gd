extends CharacterBody3D
## 近战实验场的最小可操作角色。目的仅是验证范围、节奏和命中反馈。

const AudioUtil := preload("res://scripts/audio_manager.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")

@export var move_speed := 5.6
@export var sprint_speed := 8.0
@export var mouse_sensitivity := 0.0026
@export var melee_radius := 1.55
@export var melee_reach := 1.25
@export var melee_half_angle_degrees := 55.0
@export var melee_max_targets := 3
@export var juice_enabled := true

@onready var _camera_pitch: Node3D = $CameraPitch
@onready var _camera: Camera3D = $CameraPitch/SpringArm3D/Camera3D
@onready var _visual: Node3D = $Visual
@onready var _weapon_pivot: Node3D = $Visual/WeaponPivot
@onready var _slash: MeshInstance3D = $Slash

var _cooldown := 0.0
var _shake_time := 0.0
var _impact_velocity := Vector3.ZERO
var _attack_tween: Tween
var _hit_stop_serial := 0
var _base_camera_offset := Vector3.ZERO
var _base_camera_rotation := Vector3.ZERO
var last_melee_hits := 0


func _ready() -> void:
	_base_camera_offset = _camera.position
	_base_camera_rotation = _camera.rotation
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _exit_tree() -> void:
	Engine.time_scale = 1.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		rotation.y -= motion.relative.x * mouse_sensitivity
		_camera_pitch.rotation.x = clampf(
			_camera_pitch.rotation.x - motion.relative.y * mouse_sensitivity, -0.72, 0.38
		)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F:
			perform_melee()
		elif event.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := global_transform.basis.x * input.x + global_transform.basis.z * input.y
	if direction.length_squared() > 1.0:
		direction = direction.normalized()
	var target_speed := sprint_speed if Input.is_action_pressed("sprint") else move_speed
	var desired := direction * target_speed + _impact_velocity
	velocity.x = move_toward(velocity.x, desired.x, delta * 28.0)
	velocity.z = move_toward(velocity.z, desired.z, delta * 28.0)
	_impact_velocity = _impact_velocity.move_toward(Vector3.ZERO, delta * 14.0)
	if not is_on_floor():
		velocity.y -= 22.0 * delta
	else:
		velocity.y = -0.6
	move_and_slide()
	var movement_ratio := clampf(Vector2(velocity.x, velocity.z).length() / sprint_speed, 0.0, 1.0)
	_visual.position.y = sin(Time.get_ticks_msec() * 0.012) * 0.025 * movement_ratio
	_tick_camera_feedback(delta)


func perform_melee() -> void:
	if _cooldown > 0.0 or not is_inside_tree():
		return
	_cooldown = 0.65
	last_melee_hits = 0
	var forward := -global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	_play_melee_windup()
	# 判定不再发生在按键当帧，而是锁到武器真正扫过目标的冲击帧。
	get_tree().create_timer(0.095).timeout.connect(
		_resolve_melee.bind(forward), CONNECT_ONE_SHOT
	)


func _resolve_melee(forward: Vector3) -> void:
	if not is_inside_tree():
		return
	var candidates := _find_melee_targets(forward)
	var hit_count := mini(candidates.size(), melee_max_targets)
	last_melee_hits = hit_count
	_cooldown = 0.28 if hit_count > 0 else 0.48
	_show_slash()
	if hit_count <= 0:
		if juice_enabled:
			AudioUtil.play("hit", -16.0, 1.8)
		return

	# 命中时只短冲一小步，不把角色强行吸到目标身上。
	move_and_collide(forward * 0.48)
	for index in range(hit_count):
		var target := candidates[index] as Node3D
		if not is_instance_valid(target):
			continue
		if bool(target.call("receive_lab_melee", global_position, forward)) and juice_enabled:
			var hit_position := target.global_position + Vector3.UP * 0.72
			CombatFXUtil.spawn_impact(
				get_tree().current_scene, hit_position, -forward,
				Color(1.0, 0.56, 0.12, 1.0), 1.75
			)
	if juice_enabled:
		# 高频破裂、中频击杀确认、低频闷响三层同时落在冲击帧。
		AudioUtil.play("hit", 0.0, 0.52)
		AudioUtil.play("kill", -1.5, 0.88)
		AudioUtil.play("shockwave", -11.0, 0.64)
		_shake_time = 0.24
		_camera.fov = 50.0
		_camera.rotation.z = -0.035
		_visual.position.z = 0.13
		_hit_stop_serial += 1
		_apply_hit_stop(_hit_stop_serial)


func receive_lab_contact(source_position: Vector3) -> void:
	var away := global_position - source_position
	away.y = 0.0
	if away.is_zero_approx():
		away = global_transform.basis.z
	_impact_velocity = away.normalized() * 4.8
	_shake_time = maxf(_shake_time, 0.20)
	if juice_enabled:
		AudioUtil.play("hurt", -7.0, 1.2)


func _find_melee_targets(forward: Vector3) -> Array[Node3D]:
	var shape := SphereShape3D.new()
	shape.radius = melee_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, global_position + Vector3.UP * 0.72 + forward * melee_reach)
	query.collision_mask = 4
	query.collide_with_bodies = true
	query.exclude = [get_rid()]
	var results := get_world_3d().direct_space_state.intersect_shape(query, 16)
	var scored: Array = []
	var minimum_dot := cos(deg_to_rad(melee_half_angle_degrees))
	for result in results:
		var collider := result.get("collider") as Node3D
		if collider == null or not collider.is_in_group("lab_melee_target"):
			continue
		if collider.has_method("is_lab_dead") and bool(collider.call("is_lab_dead")):
			continue
		var offset := collider.global_position - global_position
		offset.y = 0.0
		var distance := offset.length()
		if distance <= 0.001 or forward.dot(offset / distance) < minimum_dot:
			continue
		scored.append({"target": collider, "score": distance - forward.dot(offset / distance) * 0.45})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.score) < float(b.score))
	var targets: Array[Node3D] = []
	for entry in scored:
		targets.append(entry.target as Node3D)
	return targets


func _play_melee_windup() -> void:
	if _attack_tween and _attack_tween.is_valid():
		_attack_tween.kill()
	_weapon_pivot.rotation = Vector3(-0.18, 0.0, 0.38)
	_attack_tween = create_tween()
	_attack_tween.set_trans(Tween.TRANS_QUART)
	# 短促后拉让玩家看见“发力”，随后用更短时间扫过目标。
	_attack_tween.tween_property(
		_weapon_pivot, "rotation", Vector3(0.18, 0.08, 1.02), 0.055
	).set_ease(Tween.EASE_OUT)
	_attack_tween.tween_property(
		_weapon_pivot, "rotation", Vector3(-1.34, -0.18, -1.12), 0.060
	).set_ease(Tween.EASE_IN)
	_attack_tween.tween_property(
		_weapon_pivot, "rotation", Vector3(-0.18, 0.0, 0.38), 0.22
	).set_ease(Tween.EASE_OUT)


func _show_slash() -> void:
	_slash.visible = true
	_slash.scale = Vector3(0.18, 0.18, 0.18)
	var slash_tween := create_tween()
	slash_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	slash_tween.tween_property(_slash, "scale", Vector3(1.0, 1.0, 1.0), 0.08)
	slash_tween.tween_interval(0.035)
	slash_tween.tween_callback(func() -> void: _slash.visible = false)


func _apply_hit_stop(serial: int) -> void:
	# 先近乎完全冻结，再用一小段慢速恢复；比单一短停顿更有“压进目标”的重量。
	Engine.time_scale = 0.025
	await get_tree().create_timer(0.078, true, false, true).timeout
	if serial != _hit_stop_serial:
		return
	Engine.time_scale = 0.32
	await get_tree().create_timer(0.042, true, false, true).timeout
	if serial == _hit_stop_serial:
		Engine.time_scale = 1.0


func _tick_camera_feedback(delta: float) -> void:
	_camera.fov = lerpf(_camera.fov, 44.0, minf(delta * 12.0, 1.0))
	_camera.rotation.z = lerp_angle(
		_camera.rotation.z, _base_camera_rotation.z, minf(delta * 15.0, 1.0)
	)
	_visual.position.z = lerpf(_visual.position.z, 0.0, minf(delta * 14.0, 1.0))
	if _shake_time <= 0.0:
		_camera.position = _camera.position.lerp(_base_camera_offset, minf(delta * 20.0, 1.0))
		return
	_shake_time = maxf(_shake_time - delta, 0.0)
	var strength := minf(_shake_time * 0.52, 0.11)
	_camera.position = _base_camera_offset + Vector3(
		randf_range(-strength, strength), randf_range(-strength, strength), 0.0
	)
