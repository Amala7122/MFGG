extends RefCounted
## 只读取已显现目标／地面预警，不访问未公布选招或伤害倒计时。
const Adapter := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd")
var encounter: RefCounted
var profile: Dictionary
var elapsed := 0.0
var _rng := RandomNumberGenerator.new()
var _observations: Array[Dictionary] = []
var _last_seen: Dictionary = {}
var _sample_timer := 0.0
var _aim_timer := 0.0
var _aim_error := Vector2.ZERO
var _learned_radius := 0.0
var _orbit_side := 1.0
var _last_warning := ""
var _warning_noticed_at := 0.0
var _stuck_timer := 0.0
var _last_position := Vector3.INF
var _unstick_remaining := 0.0
var _warning_serial := 0
var _shown_kind := ""
var _shown_progress := 1.0
var _warning_gap := true

func setup(values: Dictionary, run_seed: int) -> void:
	profile = values.duplicate(true)
	_rng.seed = run_seed + 311
	_orbit_side = -1.0 if _rng.randf() < 0.5 else 1.0

func step(player: CharacterBody3D, boss: Node3D, delta: float) -> Dictionary:
	elapsed += delta
	_sample_timer -= delta
	_aim_timer -= delta
	_unstick_remaining = maxf(_unstick_remaining - delta, 0.0)
	if _last_position.is_finite() and player.global_position.distance_to(_last_position) < 0.01:
		_stuck_timer += delta
	else:
		_stuck_timer = 0.0
	_last_position = player.global_position
	if _sample_timer <= 0.0:
		_sample_timer = 0.05
		_observations.append(_observe(player, boss))
	while not _observations.is_empty() and float(_observations[0].time) <= elapsed - float(profile.reaction_seconds):
		var observation: Dictionary = _observations.pop_front()
		if bool(observation.get("target_visible", false)):
			_last_seen = observation
		elif not observation.get("warning", {}).is_empty():
			_last_seen["warning"] = observation.warning
			_last_seen["time"] = observation.time
	var output := {"held": {}, "just": {}, "move_world": Vector3.ZERO,
		"aim_point": Vector3.ZERO, "has_aim": false, "activity": "search", "target_visible": false,
		"warning_seen": "", "reaction_seconds": float(profile.reaction_seconds)}
	output["target_id"] = String(_last_seen.get("target_id", ""))
	if _last_seen.is_empty() or elapsed - float(_last_seen.get("time", 0.0)) > 2.0 or not _last_seen.has("position"):
		output["scan_yaw"] = deg_to_rad(65.0) * delta
		output["scan_pitch"] = -0.1
		var search := -player.global_basis.z
		var camera: Camera3D = player.get("camera") as Camera3D
		if camera != null:
			search = -camera.global_basis.z
		if _last_seen.has("position") and elapsed - float(_last_seen.get("time", 0.0)) < 8.0:
			search = Vector3(_last_seen.position) - player.global_position
		search.y = 0.0
		output.move_world = _avoid_wall(player, search.normalized()) * 0.6
		if _stuck_timer > 0.7 and player.is_on_floor():
			output.just.jump = true
			_stuck_timer = 0.0
		return output
	var target_position: Vector3 = _last_seen.position
	var away := player.global_position - target_position
	away.y = 0.0
	var distance := away.length()
	away = away.normalized() if distance > 0.01 else Vector3.RIGHT
	var side := away.cross(Vector3.UP) * _orbit_side
	var preferred := float(profile.preferred_distance)
	if bool(profile.adapt_to_visible_range):
		preferred = maxf(preferred, _learned_radius + 1.2)
	var movement := side
	if distance < preferred - 1.0:
		movement = away + side * 0.35
	elif distance > preferred + 2.0:
		movement = -away + side * 0.5
	var warning: Dictionary = _last_seen.get("warning", {}) if String(profile.strategy) != "orbit" else {}
	var in_warning := false
	if not warning.is_empty():
		var key := String(warning.key)
		output.warning_seen = key
		if key != _last_warning:
			_last_warning = key
			_warning_noticed_at = elapsed
		if String(warning.shape.get("kind", "")) == "sector":
			_learned_radius = maxf(_learned_radius, float(warning.shape.get("radius", 0.0)))
		in_warning = published_contains(warning, player.global_position)
		if in_warning:
			if elapsed - _warning_noticed_at >= float(profile.greed_seconds):
				movement = escape_direction(warning, player.global_position)
			if float(warning.progress) >= float(profile.dodge_progress) and elapsed - _warning_noticed_at >= float(profile.greed_seconds):
				if not bool(player.get("_rolling")) and float(player.get("_dodge_cooldown")) <= 0.0:
					output.just.dodge = true
	output.move_world = _avoid_wall(player, movement.normalized())
	if _stuck_timer > 0.7:
		_orbit_side *= -1.0
		_unstick_remaining = 1.0
		_stuck_timer = 0.0
		output.just.jump = player.is_on_floor()
	if _unstick_remaining > 0.0 and not in_warning:
		output.move_world = _avoid_wall(player, side * -1.0)
	output.activity = "avoid" if in_warning else "orbit_fire"
	output.target_visible = bool(_last_seen.get("target_visible", false))
	var aiming := bool(profile.use_sniper) and not in_warning and distance > 8.0
	var aim: Vector3 = _last_seen.get("core", target_position + Vector3.UP * 0.5) if aiming else target_position + Vector3.UP * 0.4
	if _aim_timer <= 0.0:
		_aim_timer = 0.25
		_aim_error = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * deg_to_rad(float(profile.aim_error_degrees))
	output.aim_error = _aim_error
	output.aim_point = aim
	output.has_aim = true
	output.held.shoot = true
	output.held.aim = aiming
	output.held.sprint = in_warning
	if bool(profile.use_grenade) and distance <= 18.0 and distance > 5.0 and not in_warning and player.call("can_throw_grenade"):
		output.just.grenade = true
	if bool(profile.use_q) and (bool(_last_seen.get("mud_shield", false)) or int(_last_seen.get("visible_count", 0)) >= 2 or distance <= 5.0) and distance <= 9.0 and float(player.get("_skill_cooldown")) <= 0.0 and int(player.get("_skill_charges")) > 0:
		output.just.skill = true
	var weapon: Node = player.get("_weapon") as Node
	if weapon != null and not aiming and int(weapon.get("_ammo")) <= 0:
		output.activity = "reload"
	if String(profile.strategy) == "break_priority":
		_break_decision(player, output, in_warning, distance)
	return output

func _break_decision(player: Node3D, output: Dictionary, in_warning: bool, distance: float) -> void:
	var cues: Dictionary = _last_seen.get("break_cues", {})
	if cues.is_empty():
		return # 其他敌人仍走通用预警／射击，不能套泰坦私有状态。
	output.held.aim = false
	output.just.grenade = false
	output.just.skill = false
	output.aim_point = cues.body
	output.activity = "body_fire"
	if bool(profile.use_sniper) and bool(cues.red_crystal) and not bool(cues.guard_visible) and not bool(cues.fallen_pose) and not in_warning and distance > 5.0:
		var weapon: Node = player.get("_weapon")
		if weapon != null and int(weapon.get("_sniper_ammo")) > 0 and float(weapon.get("_sniper_reload_timer")) <= 0.0:
			output.held.aim = true
			output.aim_point = cues.crystal
			output.activity = "crystal_aim"
			# 限速转向之外，需实际把相机转近目标才扣扳机；仍不查询命中答案。
			var camera: Camera3D = player.get("camera")
			output.held.shoot = (-camera.global_basis.z).angle_to(Vector3(cues.crystal) - camera.global_position) <= deg_to_rad(maxf(0.5, float(profile.aim_error_degrees) * 1.5))
	elif bool(cues.guard_visible):
		output.activity = "guard_body_fire"
	elif bool(cues.fallen_pose):
		output.activity = "reward_fire"
	elif bool(_last_seen.get("mud_shield", false)) and bool(profile.use_grenade) and not in_warning and distance <= 18.0 and distance > 5.0:
		output.just.grenade = player.call("can_throw_grenade")
		output.activity = "shield_grenade"

func _observe(player: Node3D, boss: Node3D) -> Dictionary:
	var result := {"time": elapsed, "target_visible": false, "warning": {}, "visible_count": 0}
	var camera: Camera3D = player.get("camera") as Camera3D
	var candidates: Array = encounter.live_nodes() if encounter != null else [boss] if is_instance_valid(boss) else []
	var nearest := INF
	for candidate: Node3D in candidates:
		var point := Adapter.public_point(candidate)
		if _visible(player, camera, point):
			result.visible_count += 1
			var distance := player.global_position.distance_squared_to(candidate.global_position)
			if distance < nearest:
				nearest = distance
				result.target_visible = true
				result.position = candidate.global_position
				result.core = point
				result.mud_shield = Adapter.public_shield(candidate)
				result.break_cues = Adapter.public_break_cues(candidate)
				result["target_id"] = String(candidate.get_meta(&"sparring_actor_id", "target"))
		var warning := _public_warning(player, camera, candidate)
		if not warning.is_empty() and (result.warning.is_empty() or published_contains(warning, player.global_position)):
			result.warning = warning
	if result.warning.is_empty():
		_warning_gap = true
	return result

func public_context(player: Node3D, boss: Node3D) -> Dictionary:
	# 录制／经验模拟共用同一可见采样，不读取敌方诊断或未来攻击。
	var seen := _observe(player, boss)
	var context := {"visible": bool(seen.target_visible), "visible_count": int(seen.visible_count),
		"danger": not seen.warning.is_empty() and published_contains(seen.warning, player.global_position),
		"warning_key": String(seen.warning.get("key", "")), "warning_progress": float(seen.warning.get("progress", 0.0)),
		"rolling": bool(player.get("_rolling")), "dodge_ready": float(player.get("_dodge_cooldown")) <= 0.0,
		"locked": bool(player.get("_cinematic_locked")) or float(player.get("_hitstop_timer")) > 0.0,
		"distance": -1.0, "target_yaw": 0.0, "target_pitch": 0.0,
		"health_ratio": float(player.get("health")) / maxf(float(player.get("max_health")), 1.0),
		"shield_ratio": float(player.get("shield")) / maxf(float(player.get("max_shield")), 1.0)}
	context["grenade"] = player.call("get_grenade_status")
	var weapon: Node = player.get("_weapon")
	context["ammo_empty"] = int(weapon.get("_ammo")) <= 0
	context["reloading"] = float(weapon.get("_reload_timer")) > 0.0 if "_reload_timer" in weapon else false
	if bool(seen.target_visible):
		context["target_id"] = seen.target_id
		var target: Vector3 = seen.position
		context["target_position"] = [target.x, target.y, target.z]
		context.distance = player.global_position.distance_to(Vector3(seen.position))
		var camera: Camera3D = player.get("camera")
		var offset := Vector3(seen.core) - camera.global_position
		context.target_yaw = atan2(-offset.x, -offset.z)
		context.target_pitch = atan2(offset.y, Vector2(offset.x, offset.z).length())
	return context

func _public_warning(player: Node3D, camera: Camera3D, opponent: Node3D) -> Dictionary:
	var area := Adapter.public_area(opponent)
	if is_instance_valid(area) and area.visible and int(area.get("phase")) in [1, 2]:
		# 脚下可见预警也能被发现，不要求预警中心正好在画面中央。
		var near_point := player.global_position - Vector3.UP * 1.0
		if (bool(area.call("contains", player.global_position)) and _visible(player, camera, near_point + Vector3.UP * 0.12)) or _visible(player, camera, area.global_position + Vector3.UP * 0.1):
			var spec: Dictionary = area.get("shape").duplicate(true)
			var progress := float(area.get("progress"))
			var kind := String(spec.get("kind", ""))
			if _warning_gap or kind != _shown_kind or progress < _shown_progress - 0.15:
				_warning_serial += 1
			_shown_kind = kind
			_shown_progress = progress
			_warning_gap = false
			var key := "%s:%s:%d" % [String(opponent.get_meta(&"sparring_actor_id", "target")), kind, _warning_serial]
			return {"key": key, "pose": area.global_transform, "shape": spec, "progress": float(area.get("progress")), "sample": near_point}
	return {}

func _visible(player: Node3D, camera: Camera3D, point: Vector3) -> bool:
	if camera == null:
		return false
	var ray := point - camera.global_position
	if ray.length() > 70.0 or ray.length() < 0.01:
		return false
	if camera.is_position_behind(point) or not camera.get_viewport().get_visible_rect().has_point(camera.unproject_position(point)):
		return false
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, point, 1, [player.get_rid()])
	return player.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

static func published_contains(warning: Dictionary, point: Vector3) -> bool:
	var pose: Transform3D = warning.pose
	var local := pose.affine_inverse() * point
	var shape: Dictionary = warning.shape
	var kind := String(shape.get("kind", "circle"))
	if kind == "rect":
		return absf(local.x - float(shape.get("offset", 0.0))) <= float(shape.width) * 0.5 + 0.3 and local.z <= 0.3 and local.z >= -float(shape.length) - 0.3
	var radius := float(shape.get("radius", 0.0)) + 0.3
	var flat := Vector2(local.x, local.z)
	if flat.length() > radius:
		return false
	if kind == "circle" or float(shape.get("angle", 360.0)) >= 359.0 or flat.length() < 0.01:
		return true
	return -local.z / flat.length() >= cos(deg_to_rad(float(shape.get("angle", 360.0)) * 0.5))

static func escape_direction(warning: Dictionary, point: Vector3) -> Vector3:
	var pose: Transform3D = warning.pose
	var local := pose.affine_inverse() * point
	var shape: Dictionary = warning.shape
	var direction := Vector3(local.x, 0.0, local.z)
	if String(shape.get("kind", "")) == "rect":
		direction = Vector3(1.0 if local.x >= float(shape.get("offset", 0.0)) else -1.0, 0.0, 0.0)
	elif direction.length_squared() < 0.01:
		direction = Vector3.RIGHT
	var world := pose.basis * direction.normalized()
	world.y = 0.0
	return world.normalized()

func _avoid_wall(player: Node3D, direction: Vector3) -> Vector3:
	if direction.is_zero_approx():
		return direction
	var from := player.global_position + Vector3.UP * 0.2
	for candidate: Vector3 in [direction, direction.rotated(Vector3.UP, PI * 0.5), direction.rotated(Vector3.UP, -PI * 0.5)]:
		var query := PhysicsRayQueryParameters3D.create(from, from + candidate * 2.0, 1)
		if player.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
			return candidate
	return Vector3.ZERO
