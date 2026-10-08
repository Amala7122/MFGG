extends CharacterBody3D
## 近战实验场专用目标：只做接近、绕行与脚本化击飞，不承担正式敌人逻辑。

const AudioUtil := preload("res://scripts/audio_manager.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")

signal eliminated(target: Node3D)

@export var approach_speed := 2.9
@export var preferred_distance := 2.05

@onready var _death_pivot: Node3D = $DeathPivot
@onready var _visual: Node3D = $DeathPivot/Visual
@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _shadow: MeshInstance3D = $Shadow

var _target: Node3D
var _dead := false
var _death_time := 0.0
var _launch_velocity := Vector3.ZERO
var _angular_velocity := Vector3.ZERO
var _contact_cooldown := 0.0
var _orbit_sign := 1.0
var _bounce_count := 0
var _grounded := false
var _settle_roll := 1.45


func setup(target: Node3D, orbit_sign: float = 1.0) -> void:
	_target = target
	_orbit_sign = signf(orbit_sign) if not is_zero_approx(orbit_sign) else 1.0


func _physics_process(delta: float) -> void:
	if _dead:
		_tick_death(delta)
		return
	_contact_cooldown = maxf(_contact_cooldown - delta, 0.0)
	if not is_instance_valid(_target):
		velocity = Vector3.ZERO
		return
	var offset := _target.global_position - global_position
	offset.y = 0.0
	var distance := offset.length()
	if distance <= 0.001:
		return
	var direction := offset / distance
	var move_direction := direction
	var speed := approach_speed
	if distance < preferred_distance + 0.65:
		# 到脚边后绕行而不是钻进玩家胶囊中心，给近战挥击留下清楚目标。
		move_direction = direction.rotated(Vector3.UP, _orbit_sign * 1.05)
		speed *= 0.55
		if distance < 1.15 and _contact_cooldown <= 0.0:
			_contact_cooldown = 1.1
			if _target.has_method("receive_lab_contact"):
				_target.call("receive_lab_contact", global_position)
	var separation := _separation_direction()
	if not separation.is_zero_approx():
		move_direction = (move_direction + separation * 1.45).normalized()
	velocity.x = move_direction.x * speed
	velocity.z = move_direction.z * speed
	if not is_on_floor():
		velocity.y -= 20.0 * delta
	else:
		velocity.y = -0.5
	rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), minf(delta * 8.0, 1.0))
	# 很轻的奔跑起伏，仍然保持低矮轮廓。
	_visual.position.y = sin(Time.get_ticks_msec() * 0.018 + get_instance_id()) * 0.035
	move_and_slide()


func _separation_direction() -> Vector3:
	var result := Vector3.ZERO
	for node in get_tree().get_nodes_in_group("lab_melee_target"):
		var other := node as Node3D
		if other == null or other == self or not is_instance_valid(other):
			continue
		if other.has_method("is_lab_dead") and bool(other.call("is_lab_dead")):
			continue
		var away := global_position - other.global_position
		away.y = 0.0
		var distance := away.length()
		if distance <= 0.001 or distance >= 2.35:
			continue
		result += away / distance * (1.0 - distance / 2.35)
	return result.normalized() if not result.is_zero_approx() else Vector3.ZERO


func receive_lab_melee(_origin: Vector3, direction: Vector3) -> bool:
	if _dead:
		return false
	_dead = true
	_collision.set_deferred("disabled", true)
	_shadow.visible = false
	collision_layer = 0
	collision_mask = 0
	var sideways := direction.cross(Vector3.UP).normalized()
	var side_sign := -1.0 if get_instance_id() % 2 == 0 else 1.0
	_launch_velocity = direction.normalized() * 13.2 + Vector3.UP * 6.8 + sideways * side_sign * 1.2
	_angular_velocity = Vector3(7.0, side_sign * 2.2, side_sign * 9.5)
	_settle_roll = side_sign * 1.45
	_death_time = 0.0
	_bounce_count = 0
	_grounded = false
	emit_signal("eliminated", self)
	return true


func is_lab_dead() -> bool:
	return _dead


func _tick_death(delta: float) -> void:
	_death_time += delta
	_death_pivot.scale = _death_pivot.scale.lerp(Vector3.ONE, minf(delta * 9.0, 1.0))
	if not _grounded:
		_launch_velocity.y -= 18.0 * delta
		var next_position := global_position + _launch_velocity * delta
		_death_pivot.rotation += _angular_velocity * delta
		var ground := _sample_ground(next_position)
		if bool(ground.get("found", false)) and next_position.y <= float(ground.y) + 0.035 and _launch_velocity.y < 0.0:
			next_position.y = float(ground.y) + 0.035
			_impact_ground(-_launch_velocity.y)
		global_position = next_position
	else:
		_launch_velocity.y = 0.0
		_launch_velocity.x = move_toward(_launch_velocity.x, 0.0, delta * 12.0)
		_launch_velocity.z = move_toward(_launch_velocity.z, 0.0, delta * 12.0)
		global_position += Vector3(_launch_velocity.x, 0.0, _launch_velocity.z) * delta
		_death_pivot.rotation.x = lerp_angle(_death_pivot.rotation.x, 0.0, minf(delta * 7.0, 1.0))
		_death_pivot.rotation.y = lerp_angle(_death_pivot.rotation.y, 0.0, minf(delta * 6.0, 1.0))
		_death_pivot.rotation.z = lerp_angle(
			_death_pivot.rotation.z, _settle_roll, minf(delta * 8.0, 1.0)
		)
	if _death_time > 1.20:
		var shrink := clampf(1.0 - (_death_time - 1.20) / 0.42, 0.02, 1.0)
		scale = Vector3.ONE * shrink
	if _death_time >= 1.64:
		queue_free()


func _impact_ground(vertical_speed: float) -> void:
	_bounce_count += 1
	_launch_velocity.x *= 0.62
	_launch_velocity.z *= 0.62
	_angular_velocity *= 0.56
	_death_pivot.scale = Vector3(1.10, 0.74, 1.10)
	CombatFXUtil.spawn_impact(
		get_tree().current_scene, global_position + Vector3.UP * 0.08,
		Vector3.UP, Color(0.62, 0.46, 0.28, 1.0), 1.15
	)
	AudioUtil.play_at("hit", global_position, -9.0, 0.48)
	if _bounce_count == 1 and vertical_speed > 3.0:
		_launch_velocity.y = vertical_speed * 0.30
	else:
		_launch_velocity.y = 0.0
		_grounded = true


func _sample_ground(position: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		position + Vector3.UP * 1.25, position + Vector3.DOWN * 1.8, 1
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"found": false, "y": -1000.0}
	return {"found": true, "y": (hit.position as Vector3).y}
