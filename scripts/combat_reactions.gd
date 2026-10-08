extends RefCounted

const HealthUtil := preload("res://scripts/health_util.gd")
## 赋予式反应控制器：危险存续期间撤离，命中后独占移动，结束再交回原 AI。
const Profile := preload("res://scripts/combat_reaction_profile.gd")
const GroundMovement := preload("res://scripts/ground_movement.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const INSTANCE := &"combat_reactions"
enum Mode { NONE, EVADE, KNOCKBACK, FALLING, GROUNDED, RISING }

var profile: Profile
var mode := Mode.NONE
var _body: CharacterBody3D
var _flying := false
var _motion_mode: int
var _collision_mask: int
var _threat: Node3D
var _noticed := 0.0
var _scan_timer := 0.0
var _route_timer := 0.0
var _escape_goal := Vector3.ZERO
var _has_route := false
var _timer := 0.0
var _recovery_height := 0.0
var _radius := 0.5
var _half_height := 0.7


func setup(body: CharacterBody3D, assigned: Profile, collision: CollisionShape3D) -> void:
	_body = body
	# 可在生成前给实例覆盖；共享资源从不在运行时改写。
	profile = (body.get_meta(&"combat_reaction_profile") if body.has_meta(&"combat_reaction_profile") else assigned) as Profile
	_flying = body.motion_mode == CharacterBody3D.MOTION_MODE_FLOATING
	_motion_mode = body.motion_mode
	_collision_mask = body.collision_mask
	var scale := collision.global_basis.get_scale().abs()
	if collision.shape is SphereShape3D or collision.shape is CapsuleShape3D:
		_radius = float(collision.shape.radius) * maxf(scale.x, scale.z)
		_half_height = float(collision.shape.radius if collision.shape is SphereShape3D else collision.shape.height * 0.5) * scale.y
	elif collision.shape is BoxShape3D:
		_radius = maxf(collision.shape.size.x * scale.x, collision.shape.size.z * scale.z) * 0.5
		_half_height = collision.shape.size.y * scale.y * 0.5
	body.set_meta(INSTANCE, self)


func owns_motion() -> bool:
	return mode != Mode.NONE


func allow_normal_stagger() -> bool:
	# 撤离没有额外霸体；玩家受击可打断撤离。坠地 / 冲击恢复期间保持移动归属。
	if mode == Mode.EVADE:
		_threat = null
		_noticed = 0.0
		_finish()
	return mode == Mode.NONE


func step(delta: float, can_evade: bool, speed: float) -> bool:
	if profile == null:
		return false
	if mode in [Mode.KNOCKBACK, Mode.FALLING, Mode.GROUNDED, Mode.RISING]:
		_step_impact(delta)
		return true
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = 0.1
		_scan_threat(can_evade or mode == Mode.EVADE)
	if not _active_threat():
		_noticed = 0.0
		if mode == Mode.EVADE:
			_finish()
		return false
	_noticed += delta
	if mode != Mode.EVADE:
		if not can_evade or _noticed < profile.reaction_delay:
			return false
		mode = Mode.EVADE
		_body.call("combat_reaction_begin", mode)
		_route_timer = 0.0
	_route_timer -= delta
	if _route_timer <= 0.0:
		_route_timer = 0.25
		_plan_escape()
	var desired := Vector3.ZERO
	if _has_route:
		var offset := _escape_goal - _body.global_position
		offset.y = 0.0
		if offset.length() > 0.15:
			desired = offset.normalized() * maxf(speed, 0.0) * profile.escape_speed_multiplier
	# 地面路线最后一层仍经过已有寻路 / 跨坎检查；飞行按实体碰撞滑动。
	if not _flying and _has_route:
		desired = _body.call("combat_reaction_ground_velocity", _escape_goal, desired, delta)
	_body.velocity.x = move_toward(_body.velocity.x, desired.x, 35.0 * delta)
	_body.velocity.z = move_toward(_body.velocity.z, desired.z, 35.0 * delta)
	if _flying:
		_body.velocity.y = move_toward(_body.velocity.y, 0.0, 20.0 * delta)
		_body.move_and_slide()
	else:
		_gravity(delta)
		GroundMovement.move(_body, delta)
	_body.call("combat_reaction_pose", mode, delta)
	return true


func receive_impact(origin: Vector3) -> void:
	if profile == null or profile.impact_response == Profile.ImpactResponse.ANCHORED:
		return
	_threat = null
	_noticed = 0.0
	mode = Mode.KNOCKBACK if profile.impact_response == Profile.ImpactResponse.KNOCKBACK else Mode.FALLING
	_timer = 0.0
	_recovery_height = _body.global_position.y
	if _flying:
		_recovery_height = float(_body.call("combat_reaction_flight_height"))
	_body.call("combat_reaction_begin", mode)
	_body.velocity = impact_velocity(origin)
	if mode == Mode.FALLING:
		_body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		_body.collision_mask = 1
	elif not _flying:
		_body.velocity.y = maxf(_body.velocity.y, 0.0)


func impact_velocity(origin: Vector3) -> Vector3:
	if profile == null or profile.impact_response == Profile.ImpactResponse.ANCHORED:
		return Vector3.ZERO
	var direction := _body.global_position - origin
	direction.y = 0.0
	if direction.is_zero_approx():
		direction = _body.global_basis.z
	var impulse := direction.normalized() * profile.knockback_speed
	if profile.impact_response == Profile.ImpactResponse.KNOCKDOWN:
		impulse.y = -profile.fall_speed
	return impulse


func _step_impact(delta: float) -> void:
	_timer += delta
	match mode:
		Mode.KNOCKBACK:
			_body.velocity.x = move_toward(_body.velocity.x, 0.0, profile.impact_drag * delta)
			_body.velocity.z = move_toward(_body.velocity.z, 0.0, profile.impact_drag * delta)
			if _flying:
				_body.move_and_slide()
			else:
				_gravity(delta)
				GroundMovement.move(_body, delta, false)
			if _timer >= profile.hit_duration and (_flying or _body.is_on_floor()):
				_finish()
		Mode.FALLING:
			_body.velocity.x = move_toward(_body.velocity.x, 0.0, profile.impact_drag * delta)
			_body.velocity.z = move_toward(_body.velocity.z, 0.0, profile.impact_drag * delta)
			_gravity(delta)
			GroundMovement.move(_body, delta, false)
			if _body.is_on_floor():
				mode = Mode.GROUNDED
				_timer = 0.0
				_body.velocity = Vector3.ZERO
		Mode.GROUNDED:
			_body.velocity = Vector3.DOWN * 0.5
			GroundMovement.move(_body, delta, false)
			# 脚下支撑消失就继续坠落，不能在空中播放贴地恢复。
			if not _body.is_on_floor():
				mode = Mode.FALLING
			elif _timer >= profile.grounded_duration:
				if _flying:
					mode = Mode.RISING
					_body.motion_mode = _motion_mode
					_timer = 0.0
				else:
					_finish()
		Mode.RISING:
			_body.velocity = Vector3.UP * minf(profile.rise_speed, maxf(_recovery_height - _body.global_position.y, 0.0) * 5.0)
			_body.move_and_slide()
			var ceiling := false
			for index in range(_body.get_slide_collision_count()):
				ceiling = ceiling or _body.get_slide_collision(index).get_normal().y < -0.707
			# 低顶限制实际飞行高度时交回飞行 AI，让其横移离开，避免永久卡在起飞状态。
			if _body.global_position.y >= _recovery_height - 0.12 or ceiling:
				_finish()
	if mode != Mode.NONE:
		_body.call("combat_reaction_pose", mode, delta)


func _gravity(delta: float) -> void:
	if _body.is_on_floor() and _body.velocity.y <= 0.0:
		_body.velocity.y = -0.5
	else:
		_body.velocity.y -= profile.gravity * delta


func _finish() -> void:
	mode = Mode.NONE
	_body.motion_mode = _motion_mode
	_body.collision_mask = _collision_mask
	_body.call("combat_reaction_end")


func _active_threat() -> bool:
	return is_instance_valid(_threat) and bool(_threat.call("danger_active"))


func _scan_threat(can_evade: bool) -> void:
	if not can_evade or profile.warning_response != Profile.WarningResponse.EVADE:
		_threat = null
		return
	# 撤离到安全边缘后保持至冲击 / 取消，避免反复冲回同一预警。
	var nearest: Node3D = _threat if _active_threat() else null
	var urgent := float(nearest.call("danger_remaining")) if nearest != null else INF
	for hazard: Node3D in _body.get_tree().get_nodes_in_group("combat_dangers"):
		if hazard.get_parent() == _body or not bool(hazard.call("danger_active")):
			continue
		if _body.global_position.distance_to(hazard.global_position) > profile.perception_range:
			continue
		if not bool(hazard.call("can_affect_ally", _body)):
			continue
		var remaining := float(hazard.call("danger_remaining"))
		if nearest == null or remaining < urgent:
			nearest = hazard
			urgent = remaining
	if nearest != _threat:
		_noticed = 0.0
		_route_timer = 0.0
	_threat = nearest


func _plan_escape() -> void:
	_has_route = false
	if not _active_threat():
		return
	var center := _threat.global_position
	var offset := _body.global_position - center
	offset.y = 0.0
	var outward := offset.normalized() if not offset.is_zero_approx() else _body.global_basis.z.normalized()
	var clearance := float(_threat.shape.get("radius", 1.0)) + _radius + profile.safe_margin
	if offset.length() >= clearance:
		_escape_goal = _body.global_position
		_has_route = true
		return
	# 从近到远选可走出口，保留整个身体通道和沿途脚印；没有出口就硬吃实际命中。
	for angle: float in [0.0, PI / 4.0, -PI / 4.0, PI / 2.0, -PI / 2.0, PI * 0.75, -PI * 0.75, PI]:
		var direction := outward.rotated(Vector3.UP, angle)
		var projected := offset.dot(direction)
		var travel := -projected + sqrt(maxf(projected * projected + clearance * clearance - offset.length_squared(), 0.0))
		var goal := _body.global_position + direction * (travel + 0.05)
		if _route_clear(goal):
			_escape_goal = goal
			_has_route = true
			return


func _route_clear(goal: Vector3) -> bool:
	var collision := KinematicCollision3D.new()
	if _body.test_move(_body.global_transform, goal - _body.global_position, collision, _body.safe_margin, false, 8):
		for index in range(collision.get_collision_count()):
			if collision.get_normal(index).y < 0.707:
				return false
	if _flying:
		return true
	var steps := maxi(ceili(_body.global_position.distance_to(goal) / 0.5), 1)
	var space := _body.get_world_3d().direct_space_state
	var previous_height := _body.global_position.y - _half_height
	for index in range(1, steps + 1):
		var point := _body.global_position.lerp(goal, float(index) / steps)
		# 中心加四周支撑，防止挑选朝悬崖的出口；低坎仍可交给地面移动跨越。
		for probe: Vector3 in [Vector3.ZERO, Vector3(_radius, 0, 0), Vector3(-_radius, 0, 0), Vector3(0, 0, _radius), Vector3(0, 0, -_radius)]:
			var at := Vector3(point.x, previous_height, point.z) + probe
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.4, at + Vector3.DOWN * 0.4, 1))
			if hit.is_empty() or hit.normal.y < 0.707:
				return false
			if probe == Vector3.ZERO:
				previous_height = hit.position.y
	return true


static func impact_allies(area: Node3D, caster: Node3D, info: Dictionary) -> void:
	var context := info.duplicate(true)
	context["source_kind"] = "enemy"
	context["managed_reaction"] = true
	for actor: Node3D in caster.get_tree().get_nodes_in_group("enemies"):
		if actor == caster or not actor.has_method("take_damage") or not bool(area.call("can_affect_ally", actor)):
			continue
		var reaction: RefCounted = actor.get_meta(INSTANCE, null) as RefCounted
		var actor_context := context.duplicate(true)
		if reaction != null:
			# 致死也携带同一冲击方向，死亡表现无需知道是谁、什么技能打中了它。
			var impulse: Vector3 = reaction.call("impact_velocity", area.global_position)
			if not impulse.is_zero_approx():
				actor_context["impact_velocity"] = impulse
		Telemetry.hurt_enemy(actor, float(area.damage), actor_context)
		if not HealthUtil.is_alive(actor):
			continue
		if reaction != null:
			reaction.call("receive_impact", area.global_position)
