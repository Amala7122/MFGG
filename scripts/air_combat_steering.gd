extends RefCounted
## 空中接战策略：按真实空域缩小盘旋半径，遮挡时先飞到目标上空再下降。
## 可赋给任意飞行角色，不使用物种、坑名或世界零高度。
const Query := preload("res://scripts/spatial_query.gd")
const Capability := preload("res://scripts/traversal_capability.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
var radius := 0.0
var _body: CharacterBody3D
var _profile: Resource
var _ability: Resource
var _target: Node3D
var _height := 0.0
var _sample := Vector3.INF
var _timer := 0.0
var _revision := -1
var attack_pose: Callable

func setup(body: CharacterBody3D, profile: Resource, values: Dictionary, attack_check: Callable = Callable()) -> void:
	_body = body
	_profile = profile
	attack_pose = attack_check
	_body.tree_exiting.connect(dispose)
	for item: Resource in profile.capabilities:
		if item.kind == Capability.Kind.FLY and item.enabled:
			_ability = item.resolved(values)
			break

func hover_height(target: Node3D, altitude: float) -> float:
	var height := target.global_position.y + altitude
	var floor := Query.floor_at(_body, target.global_position, 20.0)
	if not floor.is_empty():
		height = maxf(height, float(floor.position.y) + float(Query.dimensions(_body).half_height) + 0.08)
	return height

func update(delta: float, target: Node3D, height: float, preferred_radius: float) -> void:
	_target = target
	_height = height
	_timer -= delta
	if _timer > 0.0 and _sample.distance_to(target.global_position) < float(_profile.target_replan_distance) and _revision == Destruction.geometry_revision:
		return
	_timer = float(_profile.replan_interval)
	_sample = target.global_position
	_revision = Destruction.geometry_revision
	radius = 0.0
	if _ability == null or not _ability.enabled:
		return
	var candidate := minf(preferred_radius, float(_ability.max_distance))
	# 一整圈都要有净空与射线，避免出坑之后又被径向转向推回墙后。
	for ring in range(5):
		var legal := true
		for i in range(8):
			var point := target.global_position + Vector3(cos(TAU * i / 8.0), 0, sin(TAU * i / 8.0)) * candidate
			point.y = height
			var pose := _body.global_transform
			pose.origin = point
			if not _clear(pose, Vector3.ZERO) or not _attack_at(pose):
				legal = false
				break
		if legal:
			radius = candidate
			return
		candidate *= 0.5

func line_clear(origin: Vector3, aim: Vector3) -> bool:
	return _body.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin, aim, 1)).is_empty()

func _attack_at(pose: Transform3D) -> bool:
	var toward := _target.global_position - pose.origin
	toward.y = 0.0
	if toward.length() > 0.01:
		pose.basis = Basis(Vector3.UP, atan2(-toward.x, -toward.z)).scaled(_body.global_basis.get_scale())
	return bool(attack_pose.call(pose)) if attack_pose.is_valid() else line_clear(pose.origin, _target.global_position)

func _clear(pose: Transform3D, motion: Vector3) -> bool:
	# CharacterBody 实际停在 1mm 安全余量处；查询余量不能更大而把离墙动作也封死。
	return Query.motion_clear(_body, pose, motion, [], 0.0002)

func steer(desired: Vector3, delta: float) -> Vector3:
	if _ability == null or not _ability.enabled or not is_instance_valid(_target):
		return Vector3.ZERO
	var offset := _body.global_position - _target.global_position
	offset.y = 0.0
	var pose := _body.global_transform
	var ahead := desired * maxf(delta, 0.25)
	var future := pose
	future.origin += ahead
	if offset.length() <= radius + 0.5 and _attack_at(future) and _clear(pose, ahead):
		return desired
	var direction := offset.normalized() if offset.length() > 0.05 else Vector3.FORWARD
	var goal := _target.global_position + direction * radius
	goal.y = _height
	var goal_pose := pose
	goal_pose.origin = goal
	if not _clear(goal_pose, Vector3.ZERO):
		goal = Vector3(_target.global_position.x, _height, _target.global_position.z)
		goal_pose.origin = goal
		if not _clear(goal_pose, Vector3.ZERO):
			return Vector3.ZERO
	var waypoint := goal
	if not _clear(pose, goal - pose.origin):
		# 先进入目标上方空域，再下降；有实际顶板时仍拒绝穿越。
		var cruise := maxf(_body.global_position.y, goal.y)
		var contact := _body.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(pose.origin, goal, 1))
		if not contact.is_empty():
			for part in Query.parts(contact.collider):
				var bounds: AABB = part.global_transform * Query.shape_bounds(part.shape)
				cruise = maxf(cruise, bounds.end.y + float(Query.dimensions(_body).half_height) + 0.15)
		if cruise - _body.global_position.y > float(_ability.max_rise):
			return Vector3.ZERO
		var above := Vector3(goal.x, cruise, goal.z)
		var staging := Vector3(pose.origin.x, cruise, pose.origin.z)
		var staged := pose
		staged.origin = staging
		var above_pose := pose
		above_pose.origin = above
		if not _clear(pose, staging - pose.origin) or not _clear(staged, above - staging) or not _clear(above_pose, goal - above):
			return Vector3.ZERO
		waypoint = staging if pose.origin.distance_to(staging) > 0.15 else above if pose.origin.distance_to(above) > 0.2 else goal
	var to_goal := waypoint - pose.origin
	return to_goal.normalized() * minf(float(_ability.travel_speed), to_goal.length() * 3.0)

func dispose() -> void:
	attack_pose = Callable()
	_body = null
	_target = null
	_profile = null
	_ability = null
