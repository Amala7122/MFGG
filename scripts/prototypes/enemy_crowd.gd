extends RefCounted

const HealthUtil := preload("res://scripts/health_util.gd")
## 个体差异与软群体转向。空间快照每个物理帧只建立一次，邻居按格子查询。
## 无敌人实体碰撞；寻路/技能仍由敌人自己的状态机决定。

const CELL_SIZE := 4.0 # 空间索引的实现尺寸，不是避让距离。
static var _snapshots: Dictionary = {}
var _body: CharacterBody3D
var _settings: Dictionary
var _rng := RandomNumberGenerator.new()
var speed_multiplier := 1.0
var damage_multiplier := 1.0
var size_multiplier := 1.0
var timing_multiplier := 1.0
var gait_multiplier := 1.0
var phase := 0.0
var activation_delay := 0.0
var age := 0.0
var _lane := 0.0
var _wave_phase := 0.0
var _correction := Vector3.ZERO
var height_offset := 0.0
var _vertical_correction := 0.0


func setup(body: CharacterBody3D, values: Dictionary, family: String) -> void:
	_body = body
	_settings = values.duplicate(true)
	_rng.randomize()
	if body.has_meta(&"crowd_seed"):
		_rng.seed = int(body.get_meta(&"crowd_seed"))
	if bool(body.get_meta(&"crowd_uniform", false)):
		_settings.variation_enabled = false
		_settings.crowd_enabled = false
	# 基础体型始终生效；比较开关只关闭随机差异与群体运动。
	var base_size := _p("body_size")
	var random_size := 1.0
	if bool(_settings.variation_enabled):
		speed_multiplier = _sample("variation_speed")
		damage_multiplier = _sample("variation_damage")
		random_size = _sample("variation_size")
		timing_multiplier = _sample("variation_timing")
		gait_multiplier = _sample("variation_gait")
		if bool(_settings.variation_phase):
			phase = _rng.randf_range(0.0, TAU)
	size_multiplier = base_size * random_size
	gait_multiplier *= speed_multiplier / size_multiplier
	_lane = _rng.randf_range(-1.0, 1.0)
	_wave_phase = _rng.randf_range(0.0, TAU)
	if bool(_settings.crowd_enabled):
		activation_delay = _rng.randf_range(0.0, _p("crowd_start_delay"))
		if _settings.has("crowd_height_spread"):
			height_offset = _rng.randf_range(-_p("crowd_height_spread"), _p("crowd_height_spread"))
	body.scale *= size_multiplier
	body.set_meta(&"crowd_family", family)
	body.set_meta(&"crowd_radius", _p("separation_radius") * size_multiplier * 0.5)
	body.set_meta(&"crowd_attacking", false)
	body.set_meta(&"individual_variation", {
		"speed": speed_multiplier, "damage": damage_multiplier, "size": random_size,
		"timing": timing_multiplier, "gait": gait_multiplier, "phase": phase,
	})


func _p(key: String) -> float:
	return float(_settings[key])


func _sample(key: String) -> float:
	var spread := _p(key)
	return _rng.randf_range(1.0 - spread, 1.0 + spread)


func varied_values(values: Dictionary, speeds: Array, damage: Array, times: Array) -> Dictionary:
	var result := values.duplicate(true)
	for key in speeds:
		result[key] = float(result[key]) * speed_multiplier
	for key in damage:
		result[key] = float(result[key]) * damage_multiplier
	for key in times:
		result[key] = float(result[key]) * timing_multiplier
	return result


func tick(delta: float) -> void:
	age += delta


func ready_to_move() -> bool:
	return age >= activation_delay


func enabled() -> bool:
	return bool(_settings.crowd_enabled)


func waiting_velocity(goal: Vector3, speed: float, delta: float) -> Vector3:
	if not enabled():
		return Vector3.ZERO
	var offset := goal - _body.global_position
	var tangent := Vector3(-offset.z, 0.0, offset.x).normalized()
	tangent *= 1.0 if _lane >= 0.0 else -1.0
	return steer(tangent * speed * _p("crowd_wait_speed"), goal, delta, false)


func steer(base_velocity: Vector3, goal: Vector3, delta: float, approaching := true) -> Vector3:
	base_velocity.y = 0.0
	if not enabled() or base_velocity.is_zero_approx():
		_correction = Vector3.ZERO
		return base_velocity
	var speed := base_velocity.length()
	var forward := base_velocity / speed
	var to_goal := goal - _body.global_position
	to_goal.y = 0.0
	var distance := to_goal.length()
	var goal_direction := to_goal.normalized() if distance > 0.001 else forward
	var side := Vector3(-goal_direction.z, 0.0, goal_direction.x)
	var separation := Vector3.ZERO
	var alignment := Vector3.ZERO
	var center := Vector3.ZERO
	var count := 0
	var pressure := 0.0
	for other: Dictionary in _neighbors(_p("crowd_neighbor_radius")):
		var away: Vector3 = _body.global_position - other.position
		var vertical_gap := absf(away.y)
		away.y = 0.0
		var gap := away.length()
		var spacing := float(_body.get_meta(&"crowd_radius")) + float(other.radius)
		# 飞行者越过地面敌人时，不让地面成员为头顶的蜂群偏航。
		if bool(_body.get_meta(&"crowd_airborne", false)) or bool(other.airborne):
			gap = sqrt(gap * gap + vertical_gap * vertical_gap)
		if gap < spacing:
			var away_direction := away / gap if gap > 0.001 else _overlap_direction(int(other.id))
			var weight := 1.0 - gap / maxf(spacing, 0.001)
			separation += away_direction * weight
			pressure += weight
		if other.family == _body.get_meta(&"crowd_family") and (other.velocity as Vector3).length_squared() > 0.01:
			alignment += other.velocity
			center += other.position
			count += 1
	var desired := base_velocity
	if approaching and distance > 0.001:
		# 固定个体侧翼倾向 + 平滑路径偏移；靠近目标时偏移归零，仍能接战。
		var envelope := clampf(distance / _p("crowd_flank_distance"), 0.0, 1.0)
		var lane_goal := goal + side * _lane * _p("crowd_flank_width") * envelope
		var lane_direction := lane_goal - _body.global_position
		lane_direction.y = 0.0
		desired += (lane_direction.normalized() - goal_direction) * speed
	var oscillation := sin(age * TAU / _p("crowd_sway_period") + _wave_phase)
	desired += side * oscillation * _p("crowd_sway_strength") * speed
	desired += separation.limit_length(1.0) * _p("crowd_separation_weight") * speed
	if count > 0:
		alignment /= count
		var cohesion := center / count - _body.global_position
		cohesion.y = 0.0
		# 只柔和跟随同种移动邻居；不能被队尾拉回，更不能盖过原有追击方向。
		desired += (alignment.normalized() - forward).limit_length(1.0) * _p("crowd_alignment_weight") * speed
		desired += cohesion.normalized() * _p("crowd_cohesion_weight") * speed
	var correction := desired - base_velocity
	_correction = _correction.lerp(correction, 1.0 - exp(-_p("crowd_response") * delta))
	var surge := 1.0 + sin(age * TAU / _p("crowd_surge_period") + _wave_phase) * _p("crowd_surge_strength")
	var brake := 1.0 / (1.0 + pressure * _p("crowd_density_brake"))
	return ((base_velocity + _correction) * surge * brake).limit_length(speed * _p("crowd_speed_limit"))


func air_height() -> float:
	if not enabled():
		return 0.0
	return height_offset + sin(age * TAU / _p("crowd_vertical_period") + _wave_phase) * _p("crowd_vertical_sway")


func steer_air(base_velocity: Vector3, goal: Vector3, delta: float, approaching := true) -> Vector3:
	var result := steer(base_velocity, goal, delta, approaching)
	result.y = base_velocity.y
	if not enabled():
		return result
	var separation := 0.0
	for other: Dictionary in _neighbors(_p("crowd_neighbor_radius")):
		var away: Vector3 = _body.global_position - other.position
		var gap := away.length()
		var spacing := float(_body.get_meta(&"crowd_radius")) + float(other.radius)
		if gap < spacing and gap > 0.001:
			separation += away.y / gap * (1.0 - gap / maxf(spacing, 0.001))
	_vertical_correction = lerpf(_vertical_correction, clampf(separation, -1.0, 1.0) * _p("crowd_vertical_separation") * base_velocity.length(), 1.0 - exp(-_p("crowd_response") * delta))
	result.y += _vertical_correction
	return result


func request_attack() -> bool:
	if not enabled():
		return true
	var count := 1
	var busy := 0
	for other: Dictionary in _neighbors(_p("crowd_attack_radius")):
		if other.family != _body.get_meta(&"crowd_family"):
			continue
		count += 1
		# 读实时预约，不读快照里的旧状态，避免同一帧所有成员一起占位。
		var node := (other.ref as WeakRef).get_ref() as Node
		if is_instance_valid(node) and bool(node.get_meta(&"crowd_attacking", false)):
			busy += 1
	var capacity := maxi(1, ceili(count * _p("crowd_attack_fraction")))
	if busy >= capacity:
		return false
	_body.set_meta(&"crowd_attacking", true)
	return true


func release_attack() -> void:
	if is_instance_valid(_body):
		_body.set_meta(&"crowd_attacking", false)


func _overlap_direction(other_id: int) -> Vector3:
	# 完全重叠也会分离，成对方向严格相反；不靠随机抖动或实体推挤。
	var own_id := _body.get_instance_id()
	var angle := float((mini(own_id, other_id) * 31 + maxi(own_id, other_id)) % 360) * PI / 180.0
	return Vector3(cos(angle), 0.0, sin(angle)) * (1.0 if own_id < other_id else -1.0)


func _neighbors(radius: float) -> Array[Dictionary]:
	var snapshot := _snapshot(_body.get_tree())
	var cells: Dictionary = snapshot.cells
	var point := _body.global_position
	var low := Vector2i(floori((point.x - radius) / CELL_SIZE), floori((point.z - radius) / CELL_SIZE))
	var high := Vector2i(floori((point.x + radius) / CELL_SIZE), floori((point.z + radius) / CELL_SIZE))
	var result: Array[Dictionary] = []
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			for sample: Dictionary in cells.get(Vector2i(x, z), []):
				if int(sample.id) == _body.get_instance_id():
					continue
				var other := (sample.ref as WeakRef).get_ref() as Node3D
				if not HealthUtil.is_alive(other):
					continue
				var offset: Vector3 = sample.position - point
				offset.y = 0.0
				if offset.length_squared() <= radius * radius:
					result.append(sample)
	return result


static func _snapshot(tree: SceneTree) -> Dictionary:
	var key := tree.get_instance_id()
	var frame := Engine.get_physics_frames()
	if _snapshots.has(key) and int(_snapshots[key].frame) == frame:
		return _snapshots[key]
	for old_key in _snapshots.keys():
		if (_snapshots[old_key].tree as WeakRef).get_ref() == null:
			_snapshots.erase(old_key)
	var cells := {}
	for node in tree.get_nodes_in_group("enemies"):
		var body := node as CharacterBody3D
		if not HealthUtil.is_alive(body):
			continue
		var point := body.global_position
		var cell := Vector2i(floori(point.x / CELL_SIZE), floori(point.z / CELL_SIZE))
		if not cells.has(cell):
			cells[cell] = []
		var flat_velocity := body.velocity
		flat_velocity.y = 0.0
		cells[cell].append({"id": body.get_instance_id(), "ref": weakref(body), "position": point,
			"airborne": bool(body.get_meta(&"crowd_airborne", false)),
			"velocity": flat_velocity, "radius": float(body.get_meta(&"crowd_radius", _shape_radius(body))),
			"family": String(body.get_meta(&"crowd_family", ""))})
	var snapshot := {"tree": weakref(tree), "frame": frame, "cells": cells}
	_snapshots[key] = snapshot
	return snapshot


static func _shape_radius(body: CharacterBody3D) -> float:
	var collision := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision == null:
		return 0.0
	var shape := collision.shape
	var size := body.global_basis.get_scale()
	if shape is CapsuleShape3D or shape is CylinderShape3D or shape is SphereShape3D:
		return float(shape.radius) * maxf(size.x, size.z)
	if shape is BoxShape3D:
		return Vector2(shape.size.x * size.x, shape.size.z * size.z).length() * 0.5
	return 0.0
