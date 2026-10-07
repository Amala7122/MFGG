extends RefCounted
## 与追击搜索共用帧调度；逐个评估候选，避免多人受阻时同时扫描整场。
const Query := preload("res://scripts/spatial_query.gd")
var body: CharacterBody3D
var target: Node3D
var profile: Resource
var walking: RefCounted
var threat: Dictionary
var done := false
var result: Dictionary = {}
var _index := 0
var _score := -INF
var _away := Vector3.ZERO
var _anchor := Vector3.ZERO
var _expose := false
var _probe_distance := 0.0
var _probe_step := 1
var _probe_start := Vector3.ZERO
var target_sample := Vector3.ZERO

func begin(actor: CharacterBody3D, destination: Node3D, settings: Resource, ground_planner: RefCounted, anchor: Vector3, seek_exposure := false, probe_rim := false) -> void:
	body = actor
	target = destination
	target_sample = target.global_position
	profile = settings
	walking = ground_planner
	_anchor = anchor
	_expose = seek_exposure
	threat = {"range": profile.threat_range_fallback, "origin": target.global_position, "camera": target.global_position}
	if target.has_method("get_combat_threat"):
		threat.merge(target.call("get_combat_threat"), true)
	_away = body.global_position - target.global_position
	_away.y = 0.0
	_away = _away.normalized() if _away.length() > 0.1 else Vector3.FORWARD
	if probe_rim:
		_probe_start = Query.feet(body)
		_probe_distance = minf(Vector2(body.global_position.x - target.global_position.x, body.global_position.z - target.global_position.z).length(), 8.0)

func advance(deadline_usec: int) -> void:
	while not done and Time.get_ticks_usec() < deadline_usec:
		if not is_instance_valid(body) or not is_instance_valid(target) or _index >= 46:
			done = true
			return
		if _probe_step * 0.25 <= _probe_distance:
			# 坑沿本身就是掩体；分帧查找最后一处完整支撑，随后只沿边或小幅退让。
			var feet := _probe_start - _away * (_probe_step * 0.25)
			_probe_step += 1
			var rim := Query.floor_at(body, feet, float(profile.safe_drop) + 0.05)
			if rim.is_empty() or not Query.full_support(body, rim):
				_probe_distance = 0.0
				continue
			var at := Query.body_on_floor(body, rim)
			if not Query.ground_segment(body, _anchor, at, float(profile.safe_drop)):
				_probe_distance = 0.0
				continue
			_anchor = at
			continue
		var lateral := [0.0, 0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 1.0, -1.0]
		var setback := [0.0, 0.35, 0.75, 1.25, 1.75]
		var tangent := Vector3(-_away.z, 0, _away.x)
		var point := body.global_position if _index == 0 else _anchor + tangent * float(lateral[(_index - 1) % 9]) * float(profile.rim_patrol_radius) + _away * float(setback[(_index - 1) / 9])
		_index += 1
		var hit := Query.floor_at(body, point - Vector3.UP * float(Query.dimensions(body).half_height), float(profile.safe_drop) + 0.1)
		if hit.is_empty():
			continue
		if not Query.full_support(body, hit):
			continue
		point = Query.body_on_floor(body, hit)
		var route: Dictionary = walking.walk_route(body.global_position, point)
		if route.is_empty():
			continue
		var distance := point.distance_to(threat.origin)
		var safe := distance > float(threat.range) or not exposed(body, point, threat)
		# 安全点优先；同等遮挡时靠近目标，维持坑边压力。胆大窗口只改变暴露偏好，仍验证地板和路线。
		var preferred := not safe if _expose else safe
		var flat_distance := Vector2(point.x - target.global_position.x, point.z - target.global_position.z).length()
		var score := (100.0 if preferred else 0.0) * float(profile.exposure_weight) - flat_distance - point.distance_to(_anchor) * 0.3 - float(route.cost) * 0.25
		if score > _score:
			_score = score
			route["safe"] = safe
			route["outside_range"] = distance > float(threat.range)
			result = route
			result["rim_anchor"] = _anchor

static func exposed(actor: CharacterBody3D, point: Vector3, attack: Dictionary) -> bool:
	var half := float(Query.dimensions(actor).half_height)
	for height in [-half * 0.55, 0.0, half * 0.8]:
		var sample: Vector3 = point + Vector3.UP * float(height)
		var camera := actor.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(attack.camera, sample, 1))
		var muzzle := actor.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(attack.origin, sample, 1))
		if camera.is_empty() and muzzle.is_empty():
			return true
	return false
