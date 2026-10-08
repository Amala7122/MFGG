extends RefCounted
const Query := preload("res://scripts/spatial_query.gd")
const Capability := preload("res://scripts/traversal_capability.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
const SurfaceTraversal := preload("res://scripts/surface_traversal.gd")
var body: CharacterBody3D
var profile: Resource
var capabilities: Array[Resource] = []
var navigation_map := RID()
var target: Node3D
var goal := Vector3.ZERO
var ready_after: Dictionary = {}
var done := false
var result: Dictionary = {}
var expansions := 0
var _queue: Array[Dictionary] = []
var _visited: Dictionary = {}
var _goal_support: Dictionary = {}
var attack_pose: Callable
var _stances: Array[Vector3] = []
var landing_allowed: Callable
var _stance_candidates: Array[Vector3] = []

func begin(actor: CharacterBody3D, settings: Resource, abilities: Array[Resource], nav_map: RID, destination: Node3D, availability: Dictionary) -> void:
	body = actor
	profile = settings
	capabilities = abilities
	navigation_map = nav_map
	target = destination
	ready_after = availability.duplicate()
	_goal_support = Query.support(target)
	goal = Query.body_on_floor(body, _goal_support) if not _goal_support.is_empty() else target.global_position
	_queue.append({"at": body.global_position, "pose": body.global_transform, "cost": 0.0, "time": 0.0, "segments": [], "exclude": [], "used": {}})

func set_attack_goal(check: Callable) -> void:
	attack_pose = check
	if not attack_pose.is_valid():
		return
	# 可接战的落脚点也是目标：小台无需容纳敌人，但台下站位必须确实能攻击。
	var here := Query.support(body, false)
	if here.is_empty():
		return
	var toward := body.global_position - target.global_position
	toward.y = 0.0
	toward = toward.normalized() if toward.length() > 0.01 else Vector3.FORWARD
	for ring: float in [1.0, 1.5, 2.0, 2.5, 3.0]:
		for i in range(8):
			var expected := target.global_position + toward.rotated(Vector3.UP, TAU * i / 8.0) * ring
			expected.y = here.position.y
			_stance_candidates.append(expected)
	_stance_candidates.sort_custom(func(a: Vector3, b: Vector3): return a.distance_squared_to(body.global_position) < b.distance_squared_to(body.global_position))

func _pose_at(at: Vector3) -> Transform3D:
	var pose := body.global_transform
	pose.origin = at
	var direction := target.global_position - at
	direction.y = 0.0
	if direction.length() > 0.01:
		pose.basis = Basis(Vector3.UP, atan2(-direction.x, -direction.z)).scaled(body.global_basis.get_scale())
	return pose

func _can_attack_at(at: Vector3) -> bool:
	return attack_pose.is_valid() and bool(attack_pose.call(_pose_at(at)))

func advance(deadline_usec: int) -> void:
	while not done and Time.get_ticks_usec() < deadline_usec:
		if not is_instance_valid(body) or not is_instance_valid(target):
			done = true
			return
		if not _stance_candidates.is_empty():
			var expected: Vector3 = _stance_candidates.pop_front()
			var hit := Query.floor_at(body, expected, 0.3)
			if not hit.is_empty():
				var at := Query.body_on_floor(body, hit)
				if _can_attack_at(at) and Query.motion_clear(body, _pose_at(at), Vector3.ZERO) and Query.full_support(body, hit):
					_stances.append(at)
			continue
		if _queue.is_empty() or expansions >= int(profile.maximum_expansions):
			done = true
			return
		_queue.sort_custom(func(a: Dictionary, b: Dictionary): return float(a.cost) < float(b.cost))
		var state: Dictionary = _queue.pop_front()
		if not result.is_empty() and float(state.cost) >= float(result.cost):
			continue
		expansions += 1
		var ignored: Array[RID] = []
		ignored.assign(state.exclude)
		var state_pose: Transform3D = state.pose
		var grounded := state_pose.basis.y.normalized().dot(Vector3.UP) > 0.99
		var walking := walk_route(state.at, goal, ignored) if grounded else {}
		if not walking.is_empty() and attack_pose.is_valid() and not _can_attack_at(walking.landing):
			walking.clear()
		if attack_pose.is_valid() and bool(attack_pose.call(_pose_at(state.at) if grounded else state_pose)):
			walking = {"kind": "walk", "points": PackedVector3Array([state.at]), "landing": state.at, "cost": 0.0}
		if walking.is_empty() and grounded:
			for stance in _stances:
				walking = walk_route(state.at, stance, ignored)
				if not walking.is_empty():
					break
		if not walking.is_empty():
			var segments: Array = state.segments.duplicate()
			segments.append(walking)
			var cost := float(state.cost) + float(walking.cost)
			if result.is_empty() or cost < float(result.cost):
				result = {"segments": segments, "cost": cost, "goal": goal, "expansions": expansions}
		if state.segments.size() >= 4:
			continue
		for ability: Resource in capabilities:
			if not ability.enabled:
				continue
			var used: Dictionary = state.used
			var available := maxf(float(ready_after.get(ability.id, 0.0)), float(used.get(ability.id, 0.0)))
			var wait := maxf(available - float(state.time), 0.0)
			if wait > float(profile.max_escape_wait):
				continue
			match ability.kind:
				Capability.Kind.JUMP:
					if grounded:
						_expand_jump(state, ability, ignored, wait)
				Capability.Kind.BREAK:
					if grounded:
						_expand_break(state, ability, ignored, wait)
				Capability.Kind.CLIMB, Capability.Kind.FLY, Capability.Kind.CUSTOM:
					_expand_links(state, ability, ignored, wait)

func walk_route(origin: Vector3, destination: Vector3, exclude: Array[RID] = []) -> Dictionary:
	var speed := 5.0
	var has_walk := false
	for ability: Resource in capabilities:
		if ability.enabled and ability.kind == Capability.Kind.WALK:
			has_walk = true
			speed = maxf(float(ability.travel_speed), 0.1)
	if not has_walk:
		return {}
	var points := PackedVector3Array([origin, destination])
	if Query.ground_segment(body, origin, destination, float(profile.safe_drop), exclude):
		return {"kind": "walk", "points": points, "landing": destination, "cost": origin.distance_to(destination) / speed}
	if not navigation_map.is_valid() or NavigationServer3D.map_get_iteration_id(navigation_map) == 0:
		return {}
	var half := float(Query.dimensions(body).half_height)
	var source := NavigationServer3D.map_get_closest_point(navigation_map, origin - Vector3.UP * half)
	var end := NavigationServer3D.map_get_closest_point(navigation_map, destination - Vector3.UP * half)
	# 投影只能补偿烘焙余量，不能把另一个楼层 / 部分路径当成完整可达。
	if absf(end.y - (destination.y - half)) > 0.4:
		if Query.debug: print("[T03 nav] goal_height ", end, " destination=", destination)
		return {}
	var radius := float(Query.dimensions(body).radius)
	if Vector2(end.x - destination.x, end.z - destination.z).length() > radius + 0.5:
		var projected := Query.floor_at(body, end, 0.35, exclude)
		if projected.is_empty() or not _can_attack_at(Query.body_on_floor(body, projected)):
			if Query.debug: print("[T03 nav] projection ", end, " destination=", destination, " floor=", projected)
			return {}
	var parameters := NavigationPathQueryParameters3D.new()
	parameters.map = navigation_map
	parameters.start_position = source
	parameters.target_position = end
	parameters.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_EDGECENTERED
	var answer := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(parameters, answer)
	var path := answer.path
	if path.is_empty() or path[path.size() - 1].distance_to(end) > 0.4:
		if Query.debug: print("[T03 nav] partial ", end, " path=", path)
		return {}
	points = PackedVector3Array([origin])
	var cost := 0.0
	for ground in path:
		var hit := Query.floor_at(body, ground, maxf(0.65, radius * tan(body.floor_max_angle) + 0.25), exclude)
		if hit.is_empty():
			if Query.debug: print("[T03 nav] missing_ground ", ground)
			return {}
		var point := Query.ground_pose(body, hit, exclude)
		var previous := points[points.size() - 1]
		if previous.distance_to(point) < 0.12:
			continue
		if not Query.ground_segment(body, previous, point, float(profile.safe_drop), exclude):
			return {}
		cost += previous.distance_to(point) / speed
		points.append(point)
	return {"kind": "walk", "points": points, "landing": points[points.size() - 1], "cost": cost}

func _enqueue(state: Dictionary, segment: Dictionary, ability: Resource, wait: float, extra_exclude: Array[RID] = []) -> void:
	var point: Vector3 = segment.landing
	var excluded: Array = state.exclude.duplicate()
	excluded.append_array(extra_exclude)
	if landing_allowed.is_valid() and not bool(landing_allowed.call(state.at, point, ability.id, excluded)):
		return
	var key := "%s:%s:%s" % [point.snapped(Vector3.ONE * 0.4), ability.id, state.exclude.size() + extra_exclude.size()]
	var cost := float(state.cost) + float(segment.cost) + wait * float(profile.wait_cost)
	if _visited.has(key) and float(_visited[key]) <= cost:
		return
	_visited[key] = cost
	var used: Dictionary = state.used.duplicate()
	var elapsed := float(state.time) + wait + float(segment.get("flight", segment.get("duration", segment.cost)))
	used[ability.id] = elapsed + float(ability.cooldown)
	var segments: Array = state.segments.duplicate()
	segment["wait"] = wait
	segments.append(segment)
	var final_pose := _pose_at(point)
	if segment.has("poses"):
		final_pose = segment.poses.back()
	_queue.append({"at": point, "pose": final_pose, "cost": cost, "time": elapsed, "segments": segments, "exclude": excluded, "used": used})

func _expand_jump(state: Dictionary, ability: Resource, excluded: Array[RID], wait: float) -> void:
	var candidates: Array[Dictionary] = []
	if state.segments.is_empty():
		candidates = Query.landing_candidates(body, target, float(profile.candidate_radius))
	elif not _goal_support.is_empty():
		candidates.append(_goal_support)
	var obstruction := _obstruction(state.at, goal, excluded)
	if not obstruction.is_empty():
		var collider: Node3D = obstruction.collider as Node3D
		if collider:
			var direction := goal - (state.at as Vector3)
			direction.y = 0.0
			direction = direction.normalized()
			var farthest := (obstruction.position as Vector3).dot(direction)
			for part in Query.parts(collider):
				var box: AABB = part.global_transform * Query.shape_bounds(part.shape)
				for i in range(8):
					farthest = maxf(farthest, box.get_endpoint(i).dot(direction))
			var at: Vector3 = state.at
			var beyond := at + direction * (farthest - at.dot(direction) + float(Query.dimensions(body).radius) + 0.35)
			var hit := Query.floor_at(body, beyond - Vector3.UP * float(Query.dimensions(body).half_height), float(ability.max_drop) + 0.3, excluded)
			if not hit.is_empty():
				candidates.append(hit)
	var count := 0
	for hit in candidates:
		if count >= 3:
			break
		var plan := Query.jump_plan(body, state.at, hit, ability, excluded)
		if plan.is_empty():
			continue
		count += 1
		if (plan.landing as Vector3).distance_to(state.at) < 0.4:
			continue
		plan["support"] = hit
		_enqueue(state, plan, ability, wait)

func _obstruction(origin: Vector3, destination: Vector3, excluded: Array[RID]) -> Dictionary:
	return body.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin, destination, 1, excluded))

func _expand_break(state: Dictionary, ability: Resource, excluded: Array[RID], wait: float) -> void:
	var contact := _obstruction(state.at, goal, excluded)
	if Query.debug: print("[T03 break] contact=", contact, " power=", ability.power)
	if contact.is_empty():
		return
	var component: Node3D = Destruction.component_for(contact.collider)
	if component == null or not component.can_break(float(ability.power)):
		return
	var direction := goal - (state.at as Vector3)
	direction.y = 0.0
	direction = direction.normalized()
	var stand := (contact.position as Vector3) - direction * (float(Query.dimensions(body).radius) + minf(float(ability.max_distance) * 0.4, 1.0))
	stand.y = float(state.at.y)
	var floor_here := Query.floor_at(body, stand - Vector3.UP * float(Query.dimensions(body).half_height), 0.6, excluded)
	if floor_here.is_empty():
		return
	stand = Query.body_on_floor(body, floor_here)
	var approach := walk_route(state.at, stand, excluded)
	if Query.debug: print("[T03 break] stance=", stand, " approach=", approach)
	if approach.is_empty():
		return
	var point: Vector3 = component.impact_point(stand)
	if stand.distance_to(point) > float(ability.max_distance) + float(Query.dimensions(body).radius):
		return
	var ignored: Array[RID] = excluded.duplicate()
	ignored.append_array(component.get_collision_rids())
	if not _obstruction(stand, point, ignored).is_empty():
		return
	var follow := walk_route(stand, goal, ignored)
	if Query.debug: print("[T03 break] point=", point, " continuation=", follow)
	# 不先破坏一个并不能打开通路的物件；多障碍连接按后续状态继续规划。
	var segment := {"kind": "break", "capability": ability.id, "landing": stand,
		"approach": approach, "component": weakref(component), "point": point,
		"power": ability.power, "duration": ability.windup, "cost": float(approach.cost) + float(ability.windup) * float(ability.cost_multiplier),
		"opened": component.get_collision_rids(), "continuation": follow}
	_enqueue(state, segment, ability, wait, component.get_collision_rids())

func _expand_links(state: Dictionary, ability: Resource, excluded: Array[RID], wait: float) -> void:
	for link: Node3D in body.get_tree().get_nodes_in_group("spatial_traversal_links"):
		if not link.enabled or link.capability != ability.id:
			continue
		for reverse in ([false, true] if link.bidirectional else [false]):
			var points: PackedVector3Array = link.world_points(reverse)
			var normals: PackedVector3Array = link.world_normals(reverse)
			if points.size() < 2 or (state.at as Vector3).distance_to(points[0]) > float(ability.max_distance):
				continue
			var state_pose: Transform3D = state.pose
			var approach := walk_route(state.at, points[0], excluded) if state_pose.basis.y.normalized().dot(Vector3.UP) > 0.99 else {}
			if (state.at as Vector3).distance_to(points[0]) < 0.25:
				approach = {"kind": "walk", "points": PackedVector3Array([state.at, points[0]]), "landing": points[0], "cost": 0.0}
			if approach.is_empty():
				continue
			var plan := SurfaceTraversal.plan(body, points, normals, ability, link.attachable)
			if plan.is_empty():
				continue
			plan["approach"] = approach
			plan["link"] = weakref(link)
			plan["reverse"] = reverse
			plan["cost"] = float(plan.cost) + float(approach.cost)
			_enqueue(state, plan, ability, wait)
