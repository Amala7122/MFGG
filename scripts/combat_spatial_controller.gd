extends RefCounted
## 可赋予的空间决策与动作调度；没有敌人种类分支。
const Profile := preload("res://scripts/combat_spatial_profile.gd")
const Capability := preload("res://scripts/traversal_capability.gd")
const Query := preload("res://scripts/spatial_query.gd")
const Planner := preload("res://scripts/spatial_route_planner.gd")
const RetreatPlanner := preload("res://scripts/spatial_retreat_planner.gd")
const SurfaceTraversal := preload("res://scripts/surface_traversal.gd")
const Ground := preload("res://scripts/ground_movement.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
const INSTANCE := &"combat_spatial_controller"
const FRAME_BUDGET_USEC := 2200
static var _jobs: Array[WeakRef] = []
static var _job_frame := -1
static var last_job_usec := 0
var profile: Profile
var capabilities: Array[Resource] = []
var status := "approach"
var last_failure := ""
var last_action := ""
var route: Dictionary = {}
var escape_reserved: StringName
var _body: CharacterBody3D
var _navigation: RefCounted
var _bindings: Dictionary = {}
var _cooldowns: Dictionary = {}
var _target: Node3D
var _goal_sample := Vector3.ZERO
var _timer := 0.0
var _job: RefCounted
var _revision := -1
var _nav_revision := -1
var _segment_index := 0
var _point_index := 1
var _active: Dictionary = {}
var _elapsed := 0.0
var _started := false
var _saved_motion_mode := 0
var _saved_up := Vector3.UP
var _exit_anchor := Vector3.ZERO
var _has_exit_anchor := false
var _escape: Dictionary = {}
var _retreat_goal := Vector3.ZERO
var _retreat_route: Dictionary = {}
var _retreat_timer := 0.0
var _route_target: Node3D
var _gravity := 20.0
var _attached: Dictionary = {}
var _last_ground := Vector3.ZERO
var _has_last_ground := false
var _attack_sample: Dictionary = {}
var _attack_timer := 0.0
var _exit_check_timer := 0.0
var _progress_clock := 0.0
var _progress_point := Vector3.ZERO
var _job_kind := "route"
var _retreat_revision := -1
var _rim_anchor := Vector3.ZERO
var _rim_target := Vector3.ZERO
var _has_rim_anchor := false
var _rim_expose := false
var _rim_dwell := -1.0
var _rim_check := 0.0
var _entry_takeoff := Vector3.ZERO
var _rim_detected := false

func setup(body: CharacterBody3D, assigned: Profile, navigation: RefCounted) -> void:
	_body = body
	profile = assigned
	_navigation = navigation
	_body.set_meta(INSTANCE, self)
	_body.tree_exiting.connect(dispose)
	bind({})

func bind(values: Dictionary, callbacks: Dictionary = {}) -> void:
	_bindings = callbacks
	_gravity = float(values.get("gravity", 20.0))
	capabilities.clear()
	for capability: Resource in profile.capabilities:
		if capability != null and capability.enabled:
			var resolved: Resource = capability.resolved(values)
			if resolved.enabled:
				capabilities.append(resolved)
	_timer = 0.0

func ability(id: StringName) -> Resource:
	for item in capabilities:
		if item.id == id:
			return item
	return null

func remaining(id: StringName) -> float:
	var item := ability(id)
	var channel: StringName = item.cooldown_channel if item != null and not item.cooldown_channel.is_empty() else id
	var value := float(_cooldowns.get(channel, 0.0))
	if _bindings.has("remaining"):
		value = maxf(value, float((_bindings.remaining as Callable).call(channel)))
	return value

func permits_channel(channel: StringName) -> bool:
	if escape_reserved.is_empty():
		return true
	var reserved := ability(escape_reserved)
	return reserved == null or (reserved.cooldown_channel if not reserved.cooldown_channel.is_empty() else reserved.id) != channel

func _consume(item: Resource) -> void:
	var channel: StringName = item.cooldown_channel if not item.cooldown_channel.is_empty() else item.id
	_cooldowns[channel] = float(item.cooldown)
	if _bindings.has("consume"):
		(_bindings.consume as Callable).call(channel, float(item.cooldown))

func _nav_map() -> RID:
	return _navigation._agent.get_navigation_map() if is_instance_valid(_navigation._agent) else RID()

func _planner(destination: Node3D) -> RefCounted:
	var availability := {}
	for item in capabilities:
		availability[item.id] = remaining(item.id)
	var job := Planner.new()
	job.begin(_body, profile, capabilities, _nav_map(), destination, availability)
	job.set_attack_goal(_bindings.get("attack_pose", Callable()))
	job.landing_allowed = _route_landing_allowed
	return job

func _walking(origin: Vector3, destination: Vector3, excluded: Array[RID] = []) -> Dictionary:
	var planner := Planner.new()
	planner.body = _body
	planner.profile = profile
	planner.capabilities = capabilities
	planner.navigation_map = _nav_map()
	return planner.walk_route(origin, destination, excluded)

func _request_route() -> void:
	if _job != null or not is_instance_valid(_target):
		return
	_job = _planner(_target)
	_job_kind = "route"
	_route_target = _target
	_goal_sample = _target.global_position
	_revision = Destruction.geometry_revision
	var nav_map := _nav_map()
	_nav_revision = NavigationServer3D.map_get_iteration_id(nav_map) if nav_map.is_valid() else 0
	_jobs.append(weakref(self))
	status = "checking"

static func process_jobs() -> void:
	var frame := Engine.get_physics_frames()
	if _job_frame == frame:
		return
	_job_frame = frame
	var start := Time.get_ticks_usec()
	var count := _jobs.size()
	while count > 0 and not _jobs.is_empty() and Time.get_ticks_usec() - start < FRAME_BUDGET_USEC:
		count -= 1
		var reference: WeakRef = _jobs.pop_front()
		var owner: RefCounted = reference.get_ref()
		if owner == null or owner._job == null or not is_instance_valid(owner._body):
			continue
		owner._job.advance(mini(start + FRAME_BUDGET_USEC, Time.get_ticks_usec() + 700))
		if owner._job.done:
			owner._publish_route()
		else:
			_jobs.append(reference)
	last_job_usec = Time.get_ticks_usec() - start

func _publish_route() -> void:
	var job := _job
	_job = null
	if _job_kind == "retreat":
		_job_kind = "route"
		if _retreat_revision == Destruction.geometry_revision and is_instance_valid(_target) and job.target == _target and _target.global_position.distance_to(job.target_sample) <= float(profile.target_replan_distance):
			_retreat_route = job.result
			_rim_anchor = _retreat_route.get("rim_anchor", _rim_anchor)
			_rim_detected = true
			_retreat_timer = float(profile.retry_delay)
			_rim_dwell = -1.0
			last_failure = "no_safe_retreat" if _retreat_route.is_empty() else "" if bool(_retreat_route.get("safe", false)) else "still_exposed"
		else:
			_retreat_timer = 0.0
		return
	var nav_map := _nav_map()
	var nav_version := NavigationServer3D.map_get_iteration_id(nav_map) if nav_map.is_valid() else 0
	if not is_instance_valid(_body) or not is_instance_valid(_target) or _target != _route_target or _revision != Destruction.geometry_revision or nav_version != _nav_revision or _target.global_position.distance_to(_goal_sample) > float(profile.target_replan_distance):
		_timer = 0.0
		return
	route = job.result
	_segment_index = 0
	_point_index = 1
	_timer = float(profile.replan_interval)
	if route.is_empty():
		status = "blocked"
		last_failure = "no_capability_route"
	else:
		_retreat_route.clear()
		_has_rim_anchor = false
		status = "approach"
		last_failure = ""

func tick(delta: float, can_act: bool, target: Node3D, speed: float) -> bool:
	for channel: StringName in _cooldowns:
		_cooldowns[channel] = maxf(float(_cooldowns[channel]) - delta, 0.0)
	_timer -= delta
	_retreat_timer -= delta
	_rim_check -= delta
	_attack_timer -= delta
	_exit_check_timer -= delta
	process_jobs()
	_target = target
	if not _active.is_empty():
		return _advance_action(delta)
	if not can_act or not is_instance_valid(target):
		return false
	var here := Query.support(_body, false)
	if _attached.is_empty() and not here.is_empty() and _body.is_on_floor():
		if _has_last_ground and not _has_exit_anchor and _last_ground.y - _body.global_position.y > float(profile.safe_drop) + 0.1:
			_has_exit_anchor = true
			_exit_anchor = _last_ground
			_entry_takeoff = _body.global_position
			var exit := escape_plan(_body.global_position, _exit_anchor)
			if not exit.is_empty():
				_remember_escape(exit, _exit_anchor)
			else:
				last_failure = "forced_trap"
				status = "trapped"
		if not _has_exit_anchor:
			_last_ground = _body.global_position
			_has_last_ground = true
	if _has_exit_anchor and not here.is_empty():
		var anchor_feet := _exit_anchor.y - float(Query.dimensions(_body).half_height)
		if float(here.position.y) >= anchor_feet - float(profile.safe_drop):
			_release_escape()
		elif not Query.support(target).is_empty() and float(Query.support(target).position.y) > float(here.position.y) + float(profile.safe_drop):
			status = "escaping"
			# 出口实体或导航改变后必须从实际坑内位置重验，不能用旧计划承诺安全。
			if _exit_check_timer <= 0.0 or _revision != Destruction.geometry_revision:
				_exit_check_timer = float(profile.replan_interval)
				var fresh := escape_plan(_body.global_position, _exit_anchor)
				if fresh.is_empty():
					_escape.clear()
					escape_reserved = &""
					status = "trapped"
					last_failure = "exit_invalid"
				else:
					_remember_escape(fresh, _exit_anchor)
			if not _escape.is_empty() and remaining(escape_reserved) <= 0.0:
				var exit := _escape.duplicate(true)
				exit["escaping"] = true
				var approach: Dictionary = _escape.get("approach", {})
				if not approach.is_empty() and _body.global_position.distance_to(approach.landing) > 0.18:
					return _move_override(approach, speed, delta)
				if _begin_action(exit):
					return _advance_action(delta)
			elif _escape.is_empty():
				var exit_route := _walking(_body.global_position, _exit_anchor)
				if not exit_route.is_empty():
					return _move_override(exit_route, speed, delta)
	var nav_map := _nav_map()
	var nav_version := NavigationServer3D.map_get_iteration_id(nav_map) if nav_map.is_valid() else 0
	var target_support := Query.support(target)
	if profile.preserve_ground_style and _attached.is_empty() and not _has_exit_anchor and status not in ["unsafe_drop", "blocked", "relocate", "trapped"] and not here.is_empty() and not target_support.is_empty() and absf(float(here.position.y) - float(target_support.position.y)) <= float(profile.safe_drop) and _body.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(_body.global_position, target.global_position, 1)).is_empty():
		_job = null
		route.clear()
		status = "approach"
		return false
	var changed := target != _route_target or target.global_position.distance_to(_goal_sample) > float(profile.target_replan_distance) or _revision != Destruction.geometry_revision or _nav_revision != nav_version
	if not _can_attack() and ((route.is_empty() and _timer <= 0.0) or changed):
		if _job == null:
			_request_route()
	if not route.is_empty() and _segment_index < route.segments.size():
		var segment: Dictionary = route.segments[_segment_index]
		if String(segment.kind) == "walk" and not _can_attack():
			if _body.global_position.distance_to(segment.landing) > 0.18:
				return _move_override(segment, speed, delta)
			_segment_index += 1
			_timer = 0.0
		elif String(segment.kind) != "walk" and not _can_attack():
			var approach: Dictionary = segment.get("approach", {})
			var approach_tolerance := 0.18 if String(segment.kind) in ["climb", "fly"] else 0.45
			if not approach.is_empty() and _body.global_position.distance_to(approach.landing) > approach_tolerance:
				return _move_override(approach, speed, delta)
			if _begin_action(segment):
				return _advance_action(delta)
			if last_failure == "cooldown":
				return false
	if (status in ["blocked", "unsafe_drop", "relocate", "trapped"] or (status == "checking" and not _retreat_route.is_empty())) and not _can_attack():
		return _relocate(speed, delta)
	if not _attached.is_empty():
		var attached_ability := ability(_attached.capability)
		if attached_ability == null or SurfaceTraversal.contact(_body, _body.global_position, _body.up_direction, attached_ability).is_empty():
			cancel_motion()
			status = "blocked"
			last_failure = "attachment_lost"
			return false
		_body.velocity = Vector3.ZERO
		if _can_attack() and _bindings.has("attached_action"):
			(_bindings.attached_action as Callable).call(delta)
		return true
	if _job != null and route.is_empty() and not _can_attack():
		# 分帧查询期间停在实际起点，不能让角色直线兜底走离连接或走到坑沿。
		_body.velocity.x = 0.0
		_body.velocity.z = 0.0
		_body.velocity.y = -0.5 if _body.is_on_floor() else _body.velocity.y - _gravity * delta
		Ground.move(_body, delta)
		return true
	return false

func _can_attack() -> bool:
	if not _bindings.has("can_attack") or not is_instance_valid(_target):
		return false
	if _attack_timer <= 0.0 or _attack_sample.is_empty() or _body.global_position.distance_to(_attack_sample.at) > 0.2 or _target.global_position.distance_to(_attack_sample.target) > 0.2 or _attack_sample.revision != Destruction.geometry_revision or not _body.global_basis.is_equal_approx(_attack_sample.basis):
		_attack_timer = 0.08
		_attack_sample = {"at": _body.global_position, "target": _target.global_position, "basis": _body.global_basis, "revision": Destruction.geometry_revision, "value": bool((_bindings.can_attack as Callable).call())}
	return bool(_attack_sample.value)

func _route_landing_allowed(origin: Vector3, landing: Vector3, consumed: StringName, excluded: Array) -> bool:
	if landing.y >= origin.y - float(profile.safe_drop):
		return true
	var rids: Array[RID] = []
	rids.assign(excluded)
	return not escape_plan(landing, origin, consumed, rids).is_empty()

func adjust_ground_motion(goal: Vector3, desired: Vector3, delta: float) -> Vector3:
	if not route.is_empty() and _segment_index < route.segments.size() and is_instance_valid(_target) and goal.distance_to(_target.global_position) < 1.5:
		var segment: Dictionary = route.segments[_segment_index]
		if String(segment.kind) == "walk":
			var points: PackedVector3Array = segment.points
			while _point_index < points.size() and _body.global_position.distance_to(points[_point_index]) < 0.6:
				_point_index += 1
			if _point_index < points.size():
				goal = points[_point_index]
			else:
				_segment_index += 1
				_point_index = 1
	var velocity: Vector3 = _navigation.raw_ground_velocity(goal, desired, delta)
	return gate_motion(velocity, delta)

func gate_motion(desired: Vector3, delta: float) -> Vector3:
	if desired.is_zero_approx() or not _body.is_on_floor():
		return desired
	var here := Query.support(_body, false)
	if here.is_empty():
		return Vector3.ZERO
	var radius := float(Query.dimensions(_body).radius)
	var ahead := desired.normalized() * maxf(radius * 0.65 + 0.2, desired.length() * maxf(delta, 0.12))
	var feet_ahead := (here.position as Vector3) + ahead
	var normal: Vector3 = here.normal
	feet_ahead.y -= (normal.x * ahead.x + normal.z * ahead.z) / maxf(normal.y, 0.01)
	var lower := Query.floor_at(_body, feet_ahead, maxf(float(profile.safe_drop), 12.0))
	if not lower.is_empty() and absf(float(lower.position.y) - feet_ahead.y) <= float(profile.safe_drop) + 0.05:
		return desired
	if not lower.is_empty() and Query.ground_connected(_body, here, lower.position, float(profile.safe_drop)):
		return desired
	if not lower.is_empty():
		var entered := Query.body_on_floor(_body, lower)
		var exit := escape_plan(entered, _exit_anchor if _has_exit_anchor else _body.global_position)
		if not exit.is_empty():
			_remember_escape(exit, _body.global_position)
			return desired
	status = "unsafe_drop"
	last_failure = "no_exit_proof" if not lower.is_empty() else "no_landing"
	return Vector3.ZERO

func escape_plan(entered: Vector3, anchor: Vector3, consumed: StringName = &"", excluded: Array[RID] = []) -> Dictionary:
	var walk := _walking(entered, anchor, excluded)
	if not walk.is_empty():
		return {"kind": "walk", "route": walk}
	var ground := Query.floor_at(_body, anchor - Vector3.UP * float(Query.dimensions(_body).half_height), 0.5, excluded)
	if ground.is_empty():
		return {}
	for item in capabilities:
		if item.kind != Capability.Kind.JUMP:
			continue
		var wait := remaining(item.id)
		if item.id == consumed:
			wait = maxf(wait, float(item.cooldown))
		if wait > float(profile.max_escape_wait):
			continue
		var plan := Query.jump_plan(_body, entered, ground, item, excluded)
		if not plan.is_empty():
			plan["wait"] = wait
			return plan
		# 坑内追击可能走到贴墙位置；先返回已验证的起跳空地，再执行同一返程跳跃。
		if _has_exit_anchor:
			var approach := _walking(entered, _entry_takeoff, excluded)
			if not approach.is_empty():
				plan = Query.jump_plan(_body, _entry_takeoff, ground, item, excluded)
				if not plan.is_empty():
					plan["approach"] = approach
					plan["wait"] = wait
					return plan
			# 玩家可能正站在原入口；出口是同层安全区域，不强迫落在被占用的一个点上。
			var spacing := float(Query.dimensions(_body).radius) * 2.0 + 0.35
			for direction: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
				var nearby := Query.floor_at(_body, (ground.position as Vector3) + direction * spacing, 0.2, excluded)
				if nearby.is_empty() or absf(float(nearby.position.y) - float(ground.position.y)) > float(profile.safe_drop):
					continue
				plan = Query.jump_plan(_body, entered, nearby, item, excluded)
				if plan.is_empty() and not approach.is_empty():
					plan = Query.jump_plan(_body, _entry_takeoff, nearby, item, excluded)
					if not plan.is_empty():
						plan["approach"] = approach
				if not plan.is_empty():
					plan["wait"] = wait
					return plan
	for item in capabilities:
		if item.kind not in [Capability.Kind.CLIMB, Capability.Kind.FLY, Capability.Kind.CUSTOM]:
			continue
		var wait := maxf(remaining(item.id), float(item.cooldown) if item.id == consumed else 0.0)
		if wait > float(profile.max_escape_wait):
			continue
		for link: Node3D in _body.get_tree().get_nodes_in_group("spatial_traversal_links"):
			if not link.enabled or link.capability != item.id:
				continue
			for reverse in ([false, true] if link.bidirectional else [false]):
				var points: PackedVector3Array = link.world_points(reverse)
				if points.size() < 2 or _walking(entered, points[0], excluded).is_empty() or _walking(points[-1], anchor, excluded).is_empty():
					continue
				var plan := SurfaceTraversal.plan(_body, points, link.world_normals(reverse), item, link.attachable)
				if not plan.is_empty():
					plan["link"] = weakref(link)
					plan["reverse"] = reverse
					plan["approach"] = _walking(entered, points[0], excluded)
					plan["wait"] = wait
					return plan
	return {}

func permit_landing(landing: Vector3, consumed: StringName = &"", excluded: Array[RID] = [], commit := true) -> bool:
	if landing.y >= _body.global_position.y - float(profile.safe_drop):
		return true
	var exit := escape_plan(landing, _exit_anchor if _has_exit_anchor else _body.global_position, consumed, excluded)
	if exit.is_empty():
		last_failure = "no_exit_proof"
		return false
	if commit:
		_remember_escape(exit, _body.global_position)
	return true

func _remember_escape(plan: Dictionary, anchor: Vector3) -> void:
	if not _has_exit_anchor:
		_exit_anchor = anchor
		_has_exit_anchor = true
		_entry_takeoff = plan.get("from", _body.global_position)
	_escape.clear()
	escape_reserved = &""
	if String(plan.kind) != "walk":
		_escape = plan
		escape_reserved = plan.capability if profile.reserve_escape else &""

func _release_escape() -> void:
	_has_exit_anchor = false
	_escape.clear()
	escape_reserved = &""

func _begin_action(plan: Dictionary) -> bool:
	var item := ability(plan.get("capability", &""))
	if item == null or not item.enabled:
		return _reject_action("ability_unavailable")
	if remaining(item.id) > 0.0:
		last_failure = "cooldown"
		return false
	if String(plan.kind) == "jump":
		if not _body.is_on_floor():
			return false
		var support := Query.floor_at(_body, plan.ground, 0.2)
		var fresh := Query.jump_plan(_body, _body.global_position, support, item)
		if fresh.is_empty() or (not bool(plan.get("escaping", false)) and not permit_landing(fresh.landing, item.id)):
			last_failure = "jump_invalid"
			_timer = 0.0
			route.clear()
			return false
		fresh["escaping"] = plan.get("escaping", false)
		plan = fresh
	elif String(plan.kind) == "break":
		var component: Node3D = (plan.component as WeakRef).get_ref()
		if component == null or component.is_broken or not component.can_break(float(item.power)):
			_timer = 0.0
			route.clear()
			return false
		if _bindings.has("break_action"):
			if bool((_bindings.break_action as Callable).call(component, plan.point, item)):
				last_action = "break"
				status = "breaking"
				route.clear()
				_timer = float(profile.retry_delay)
				return false
			last_failure = "break_action_unavailable"
			return false
	elif String(plan.kind) in ["climb", "fly"]:
		var link: Node3D = (plan.link as WeakRef).get_ref()
		if link == null or not link.enabled:
			return _reject_action("link_unavailable")
		var reverse := bool(plan.get("reverse", false))
		var points: PackedVector3Array = link.world_points(reverse)
		if points.is_empty() or _body.global_position.distance_to(points[0]) > 0.25:
			return _reject_action("link_start_unreachable")
		var fresh := SurfaceTraversal.plan(_body, points, link.world_normals(reverse), item, link.attachable, _body.global_transform)
		if fresh.is_empty():
			return _reject_action("surface_invalid")
		fresh["escaping"] = plan.get("escaping", false)
		plan = fresh
	elif not item.begin_custom(_body, plan):
		return false
	_active = plan.duplicate(true)
	_elapsed = 0.0
	_started = false
	_saved_motion_mode = _body.motion_mode
	_saved_up = _body.up_direction
	status = "escaping" if bool(plan.get("escaping", false)) else "traversing"
	last_action = String(plan.kind)
	_consume(item)
	return true

func _reject_action(reason: String) -> bool:
	last_failure = reason
	status = "blocked"
	route.clear()
	_timer = float(profile.retry_delay)
	return false

func _advance_action(delta: float) -> bool:
	var item := ability(_active.get("capability", &""))
	if item == null:
		cancel_motion()
		return false
	_elapsed += delta
	if _elapsed < float(item.windup):
		_body.velocity.x = 0.0
		_body.velocity.z = 0.0
		_body.velocity.y = -0.5 if _body.is_on_floor() else _body.velocity.y - float(item.gravity) * delta
		Ground.move(_body, delta, false)
		return true
	if not _started:
		_started = true
		if String(_active.kind) == "jump":
			_body.velocity = _active.launch
		else:
			_body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var elapsed := _elapsed - float(item.windup)
	if String(_active.kind) == "jump":
		_body.velocity.x = float(_active.launch.x)
		_body.velocity.z = float(_active.launch.z)
		_body.velocity.y -= float(_active.gravity) * delta
		_body.move_and_slide()
		var collision := _body.is_on_wall() or _body.is_on_ceiling()
		if collision or elapsed > float(_active.flight) + 0.7:
			_finish_motion(false)
		elif _body.is_on_floor() and elapsed > 0.15:
			_finish_motion(_body.global_position.distance_to(_active.landing) < 0.65)
	elif String(_active.kind) in ["climb", "fly"]:
		var poses: Array = _active.poses
		var fraction := clampf(elapsed / maxf(float(_active.duration), 0.01), 0.0, 1.0)
		var position := fraction * (poses.size() - 1)
		var index := mini(floori(position), poses.size() - 1)
		var desired: Transform3D = (poses[index] as Transform3D).interpolate_with(poses[mini(index + 1, poses.size() - 1)], position - index)
		if not Query.motion_clear(_body, desired, Vector3.ZERO) or (String(_active.kind) == "climb" and SurfaceTraversal.contact(_body, desired.origin, desired.basis.y.normalized(), item).is_empty()):
			_finish_motion(false)
			return true
		_body.global_basis = desired.basis
		_body.up_direction = desired.basis.y.normalized()
		_body.velocity = (desired.origin - _body.global_position) / maxf(delta, 0.001)
		_body.move_and_slide()
		if _body.global_position.distance_to(desired.origin) > 0.15:
			_finish_motion(false)
		elif fraction >= 1.0:
			_finish_motion(true)
	else:
		var outcome: String = item.step_custom(_body, _active, delta)
		if outcome != "running":
			_finish_motion(outcome == "arrived")
	return true

func _finish_motion(success: bool) -> void:
	var escaped := bool(_active.get("escaping", false))
	var stay_attached := success and String(_active.kind) == "climb" and _body.up_direction.dot(Vector3.UP) < 0.99
	if stay_attached:
		_attached = {"capability": _active.capability}
	else:
		_attached.clear()
		_body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		_body.up_direction = Vector3.UP
		if String(_active.kind) in ["climb", "fly"]:
			_body.global_basis = Basis(Vector3.UP, _body.rotation.y).scaled(_body.global_basis.get_scale())
	_body.velocity.x = 0.0
	_body.velocity.z = 0.0
	_active.clear()
	if success:
		_segment_index += 1
		_point_index = 1
		last_failure = ""
		if escaped:
			var support := Query.support(_body, false)
			var anchor_feet := _exit_anchor.y - float(Query.dimensions(_body).half_height)
			if not support.is_empty() and float(support.position.y) >= anchor_feet - float(profile.safe_drop):
				_release_escape()
			else:
				_escape.clear()
		status = "approach"
	else:
		last_failure = "motion_blocked"
		route.clear()
		_timer = float(profile.retry_delay)
		status = "blocked"

func cancel_motion() -> void:
	var surface_motion := not _active.is_empty() and String(_active.kind) in ["climb", "fly"]
	if not _active.is_empty() and is_instance_valid(_body):
		var item := ability(_active.get("capability", &""))
		if item != null:
			item.cancel_custom(_body)
		_body.motion_mode = _saved_motion_mode
		_body.up_direction = _saved_up
	_active.clear()
	if (surface_motion or not _attached.is_empty()) and is_instance_valid(_body):
		_body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		_body.up_direction = Vector3.UP
		_body.global_basis = Basis(Vector3.UP, _body.rotation.y).scaled(_body.global_basis.get_scale())
	_attached.clear()
	route.clear()
	_job = null
	_timer = float(profile.retry_delay)

func _move_override(walking: Dictionary, speed: float, delta: float) -> bool:
	var points: PackedVector3Array = walking.points
	var next := walking.landing as Vector3
	var cursor := int(walking.get("_cursor", 1))
	while cursor < points.size() - 1 and Vector2(_body.global_position.x - points[cursor].x, _body.global_position.z - points[cursor].z).length() < 0.28:
		cursor += 1
	walking["_cursor"] = cursor
	if cursor < points.size():
		next = points[cursor]
	var direction := next - _body.global_position
	direction.y = 0.0
	var desired := gate_motion(direction.normalized() * minf(speed, direction.length() / maxf(delta, 0.001)), delta) if direction.length() > 0.1 else Vector3.ZERO
	if not desired.is_zero_approx() and _body.up_direction.dot(Vector3.UP) > 0.99:
		_body.rotation.y = rotate_toward(_body.rotation.y, atan2(-desired.x, -desired.z), delta * 6.0)
	_body.velocity.x = move_toward(_body.velocity.x, desired.x, float(profile.acceleration) * delta)
	_body.velocity.z = move_toward(_body.velocity.z, desired.z, float(profile.acceleration) * delta)
	_body.velocity.y = -0.5 if _body.is_on_floor() else _body.velocity.y - _gravity * delta
	Ground.move(_body, delta)
	_progress_clock += delta
	if _progress_clock >= 0.6:
		if _body.global_position.distance_to(_progress_point) < 0.12 and direction.length() > 0.25:
			route.clear()
			if walking.has("rim_anchor"):
				_retreat_route.clear()
				_retreat_timer = float(profile.retry_delay)
			_timer = float(profile.retry_delay)
			status = "blocked"
			last_failure = "walking_blocked"
		_progress_point = _body.global_position
		_progress_clock = 0.0
	return true

func _relocate(speed: float, delta: float) -> bool:
	if not _has_rim_anchor or _target.global_position.distance_to(_rim_target) > float(profile.rim_patrol_radius):
		_rim_anchor = _body.global_position
		_rim_detected = false
		_rim_target = _target.global_position
		_has_rim_anchor = true
		_rim_expose = false
		_rim_dwell = -1.0
		_retreat_route.clear()
		_retreat_timer = 0.0
	if _retreat_revision != Destruction.geometry_revision:
		_retreat_route.clear()
		_retreat_timer = 0.0
	if not _retreat_route.is_empty():
		var arrived := _body.global_position.distance_to(_retreat_route.landing) < 0.25
		if arrived:
			if _rim_dwell < 0.0:
				_rim_dwell = float(profile.rim_exposure_duration) if _rim_expose else randf_range(float(profile.rim_dwell_min), float(profile.rim_dwell_max))
			_rim_dwell -= delta
			if _rim_dwell <= 0.0:
				_rim_expose = false if _rim_expose else randf() < float(profile.rim_exposure_chance)
				_retreat_route.clear()
				_retreat_timer = 0.0
		# 玩家改变枪口 / 相机时及时重验掩护；探头窗口到时再回到盲区。
		if not _rim_expose and _rim_check <= 0.0 and not _retreat_route.is_empty():
			_rim_check = 0.25
			var threat := {"range": profile.threat_range_fallback, "origin": _target.global_position, "camera": _target.global_position}
			if _target.has_method("get_combat_threat"):
				threat.merge(_target.call("get_combat_threat"), true)
			if bool(_retreat_route.get("safe", false)) and RetreatPlanner.exposed(_body, _retreat_route.landing, threat):
				_retreat_route.clear()
				_retreat_timer = 0.0
	if _retreat_route.is_empty() and _retreat_timer <= 0.0 and _job == null:
		_retreat_timer = float(profile.retry_delay)
		var planner := Planner.new()
		planner.body = _body
		planner.profile = profile
		planner.capabilities = capabilities
		planner.navigation_map = _nav_map()
		var search := RetreatPlanner.new()
		search.begin(_body, _target, profile, planner, _rim_anchor, _rim_expose, not _rim_detected)
		_job = search
		_job_kind = "retreat"
		_retreat_revision = Destruction.geometry_revision
		_jobs.append(weakref(self))
	var here := Query.support(_body, false)
	var trapped := _has_exit_anchor and _escape.is_empty() and not here.is_empty() and float(here.position.y) < _exit_anchor.y - float(Query.dimensions(_body).half_height) - float(profile.safe_drop)
	status = "trapped" if trapped else "relocate"
	if not _retreat_route.is_empty():
		return _move_override(_retreat_route, speed, delta)
	_body.velocity.x = move_toward(_body.velocity.x, 0.0, float(profile.acceleration) * delta)
	_body.velocity.z = move_toward(_body.velocity.z, 0.0, float(profile.acceleration) * delta)
	_body.velocity.y = -0.5 if _body.is_on_floor() else _body.velocity.y - _gravity * delta
	Ground.move(_body, delta)
	last_failure = "no_exit_proof" if trapped else "checking_retreat" if _job != null else "no_safe_retreat"
	return true


func dispose() -> void:
	cancel_motion()
	_release_escape()
	for index in range(_jobs.size() - 1, -1, -1):
		var owner: RefCounted = _jobs[index].get_ref()
		if owner == null or owner == self:
			_jobs.remove_at(index)
	if is_instance_valid(_body):
		Query.forget(_body)
		_body.remove_meta(INSTANCE)
	_body = null
	_navigation = null
	_bindings.clear()
