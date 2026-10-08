extends RefCounted
## 只查询真实支撑、身体净空与轨迹，不创建显示网格。
const Landing := preload("res://scripts/jump_landing.gd")
const Ground := preload("res://scripts/ground_movement.gd")
static var _last_support: Dictionary = {}
static var debug := false

static func parts(body: Node3D) -> Array[CollisionShape3D]:
	var result: Array[CollisionShape3D] = []
	for child in body.get_children():
		if child is CollisionShape3D and child.shape != null and not child.disabled:
			result.append(child)
	return result

static func shape_bounds(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		return AABB(-shape.size * 0.5, shape.size)
	var radius := float(shape.radius) if shape is SphereShape3D or shape is CapsuleShape3D or shape is CylinderShape3D else 0.0
	if radius > 0.0:
		var height := radius * 2.0 if shape is SphereShape3D else float(shape.height)
		return AABB(Vector3(-radius, -height * 0.5, -radius), Vector3(radius * 2.0, height, radius * 2.0))
	return shape.get_debug_mesh().get_aabb()

static func primary(body: Node3D) -> CollisionShape3D:
	var best: CollisionShape3D
	var bottom := INF
	for part in parts(body):
		var bounds: AABB = (body.global_transform.affine_inverse() * part.global_transform) * shape_bounds(part.shape)
		if bounds.position.y < bottom:
			bottom = bounds.position.y
			best = part
	return best

static func dimensions(body: Node3D) -> Dictionary:
	var frame := Engine.get_physics_frames()
	if body.has_meta(&"spatial_dimensions"):
		var cached: Dictionary = body.get_meta(&"spatial_dimensions")
		if cached.frame == frame and cached.scale == body.global_basis.get_scale().abs():
			return cached.result
	var bounds := AABB()
	var found := false
	for part in parts(body):
		var local: AABB = (body.global_transform.affine_inverse() * part.global_transform) * shape_bounds(part.shape)
		bounds = bounds.merge(local) if found else local
		found = true
	var scale := body.global_basis.get_scale().abs()
	var result := {"half_height": -bounds.position.y * scale.y if found else 0.0,
		"radius": maxf(bounds.size.x * scale.x, bounds.size.z * scale.z) * 0.5 if found else 0.25}
	body.set_meta(&"spatial_dimensions", {"frame": frame, "scale": scale, "result": result})
	return result

static func feet(body: Node3D) -> Vector3:
	return body.global_position - Vector3.UP * float(dimensions(body).half_height)

static func floor_at(context: Node3D, expected: Vector3, depth := 0.6, exclude: Array[RID] = []) -> Dictionary:
	var centre := _floor_ray(context, expected, depth, exclude)
	if not centre.is_empty() and absf(float(centre.position.y) - expected.y) < 0.35:
		return centre
	# 脚印可跨越薄板端面 / 极窄接缝。射线先碰到斜端面不等于没有可走支撑。
	# 只在身体脚印内补探；深坑不能通过导航投影或远处地板补成出口。
	var radius := minf(float(dimensions(context).radius) * 0.3, 0.12)
	var best := centre
	var distance := absf(float(centre.position.y) - expected.y) if not centre.is_empty() else INF
	for direction: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		var hit := _floor_ray(context, expected + direction * radius, minf(depth, 0.4), exclude)
		if not hit.is_empty() and absf(float(hit.position.y) - expected.y) < distance:
			best = hit
			distance = absf(float(hit.position.y) - expected.y)
	return best

static func _floor_ray(context: Node3D, expected: Vector3, depth: float, exclude: Array[RID]) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(expected + Vector3.UP * 0.16, expected + Vector3.DOWN * depth, 1, exclude)
	for i in range(3):
		var hit := context.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			return {}
		if (hit.normal as Vector3).y >= 0.707:
			return hit
		query.from = hit.position + Vector3.DOWN * 0.02
	return {}

static func support(body: Node3D, remember := true) -> Dictionary:
	var depth := 0.65
	if body is CharacterBody3D and body.is_on_floor():
		depth = maxf(depth, float(dimensions(body).radius) * tan(body.floor_max_angle) + 0.2)
	var hit := floor_at(body, feet(body), depth)
	var key := body.get_instance_id()
	if not hit.is_empty():
		if remember:
			if not body.has_meta(&"spatial_support_cleanup"):
				body.set_meta(&"spatial_support_cleanup", true)
				body.tree_exiting.connect(func(): forget(body), CONNECT_ONE_SHOT)
			_last_support[key] = {"body": weakref(body), "hit": hit}
		return hit
	if remember and _last_support.has(key):
		var saved: Dictionary = _last_support[key]
		var owner: Object = saved.hit.get("collider")
		if saved.body.get_ref() != body or not is_instance_valid(owner):
			_last_support.erase(key)
		else:
			var previous: Vector3 = saved.hit.position
			var flat := Vector2(previous.x - body.global_position.x, previous.z - body.global_position.z)
			if flat.length() < 1.5:
				var fresh := floor_at(body, previous, 0.2)
				if not fresh.is_empty() and fresh.rid == saved.hit.rid:
					return fresh
	return {}

static func forget(body: Node3D) -> void:
	_last_support.erase(body.get_instance_id())
	if body.has_meta(&"spatial_support_cleanup"):
		body.remove_meta(&"spatial_support_cleanup")
	if body.has_meta(&"spatial_dimensions"):
		body.remove_meta(&"spatial_dimensions")

static func ground_connected(context: Node3D, origin: Dictionary, destination: Vector3, safe_drop: float) -> bool:
	var start: Vector3 = origin.position
	var previous := origin
	var steps := maxi(1, ceili(Vector2(destination.x - start.x, destination.z - start.z).length() / 0.15))
	for i in range(1, steps + 1):
		var expected := start.lerp(destination, float(i) / steps)
		var normal: Vector3 = previous.normal
		var horizontal := expected - (previous.position as Vector3)
		expected.y = float(previous.position.y) - (normal.x * horizontal.x + normal.z * horizontal.z) / maxf(normal.y, 0.01)
		var next := floor_at(context, expected, safe_drop + 0.05)
		if next.is_empty() or absf(float(next.position.y) - expected.y) > safe_drop + 0.03:
			return false
		previous = next
	return true

static func landing_candidates(context: Node3D, target: Node3D, radius: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var hit := support(target)
	if hit.is_empty():
		return result
	result.append(hit)
	var centre: Vector3 = hit.position
	var toward := context.global_position - centre
	toward.y = 0.0
	toward = toward.normalized() if toward.length() > 0.01 else Vector3.FORWARD
	# 中心优先；同一支撑面内取有限落点，目标靠边不等于整个台面站不下。
	for ring in [0.5, 1.0]:
		for i in range(8):
			var direction := toward.rotated(Vector3.UP, TAU * float(i) / 8.0)
			var point: Vector3 = centre + direction * radius * float(ring)
			point.y = centre.y - ((hit.normal as Vector3).x * (point.x - centre.x) + (hit.normal as Vector3).z * (point.z - centre.z)) / maxf(float(hit.normal.y), 0.01)
			var nearby := floor_at(context, point, 0.22)
			if not nearby.is_empty() and nearby.rid == hit.rid:
				result.append(nearby)
	return result

static func full_support(body: CharacterBody3D, hit: Dictionary, exclude: Array[RID] = []) -> bool:
	var shape := primary(body)
	return shape != null and not hit.is_empty() and Landing.supported(body, hit.position, hit.normal, shape.shape, shape.global_basis, exclude)

static func body_on_floor(body: Node3D, hit: Dictionary) -> Vector3:
	var dimensions_here := dimensions(body)
	var normal: Vector3 = hit.normal
	var slope := float(dimensions_here.radius) * Vector2(normal.x, normal.z).length() / maxf(normal.y, 0.01)
	return (hit.position as Vector3) + Vector3.UP * (float(dimensions_here.half_height) + slope + 0.045)

static func ground_pose(body: CharacterBody3D, hit: Dictionary, exclude: Array[RID] = []) -> Vector3:
	var centre: Vector3 = hit.position + Vector3.UP * (float(dimensions(body).half_height) + 0.045)
	var shape := primary(body)
	if shape == null:
		return centre
	var bounds := shape_bounds(shape.shape)
	# 脚印向下扫掠得到有限坡板的真实最高接触；不把坡面无限外推到台面上。
	var footprint: Shape3D
	if shape.shape is BoxShape3D:
		var box := BoxShape3D.new()
		box.size = Vector3(bounds.size.x, 0.02, bounds.size.z)
		footprint = box
	else:
		var disk := CylinderShape3D.new()
		disk.radius = maxf(bounds.size.x, bounds.size.z) * 0.5
		disk.height = 0.02
		footprint = disk
	var clearance := float(dimensions(body).radius) * tan(body.floor_max_angle) + 0.2
	var parameters := PhysicsShapeQueryParameters3D.new()
	parameters.shape = footprint
	parameters.transform = Transform3D(shape.global_basis, hit.position + Vector3.UP * clearance)
	parameters.motion = Vector3.DOWN * (clearance + 0.15)
	parameters.collision_mask = 1
	parameters.exclude = exclude
	parameters.margin = 0.002
	var fraction := body.get_world_3d().direct_space_state.cast_motion(parameters)
	if fraction[0] > 0.0 and fraction[0] < 1.0:
		centre.y = float(hit.position.y) + clearance + parameters.motion.y * float(fraction[0]) + float(dimensions(body).half_height) + 0.03
	return centre

static func motion_clear(body: CharacterBody3D, from: Transform3D, motion: Vector3, exclude: Array[RID] = [], margin := 0.002) -> bool:
	var space := body.get_world_3d().direct_space_state
	var ignored: Array[RID] = [body.get_rid()]
	ignored.append_array(exclude)
	for part in parts(body):
		var local := body.global_transform.affine_inverse() * part.global_transform
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = part.shape
		query.transform = from * local
		query.motion = motion
		query.margin = margin
		query.collision_mask = 1
		query.exclude = ignored
		if not space.intersect_shape(query, 1).is_empty() or space.cast_motion(query)[0] < 0.999:
			return false
	return true

static func landing_clear(body: CharacterBody3D, point: Vector3) -> bool:
	# 环境净空另由弧线检查；落脚还不能与移动模式会碰撞的角色实体重叠。
	var mask := body.collision_mask & ~1
	if mask == 0:
		return true
	var pose := body.global_transform
	pose.origin = point
	for part in parts(body):
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = part.shape
		query.transform = pose * (body.global_transform.affine_inverse() * part.global_transform)
		query.collision_mask = mask
		query.exclude = [body.get_rid()]
		query.margin = 0.002
		if not body.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
			return false
	return true

static func arc_clear(body: CharacterBody3D, origin: Vector3, launch: Vector3, gravity: float, duration: float, exclude: Array[RID] = []) -> bool:
	var previous := origin + Vector3.UP * 0.04
	for i in range(1, 25):
		var time := duration * float(i) / 24.0
		var next := origin + launch * time + Vector3.DOWN * gravity * time * time * 0.5 + Vector3.UP * 0.04
		var pose := body.global_transform
		pose.origin = previous
		if not motion_clear(body, pose, next - previous, exclude):
			return false
		previous = next
	return true

static func jump_plan(body: CharacterBody3D, origin: Vector3, hit: Dictionary, capability: Resource, exclude: Array[RID] = []) -> Dictionary:
	if hit.is_empty():
		return {}
	var landing := body_on_floor(body, hit)
	var offset := landing - origin
	var distance := Vector2(offset.x, offset.z).length()
	if distance > float(capability.max_distance) or offset.y > float(capability.max_rise) + 0.05 or -offset.y > float(capability.max_drop) + 0.05:
		return {}
	if not full_support(body, hit, exclude):
		return {}
	if not landing_clear(body, landing):
		return {}
	var longest := float(capability.max_flight)
	if float(capability.launch_speed_limit) > 0.0:
		var speed := float(capability.launch_speed_limit)
		var discriminant := speed * speed - 2.0 * float(capability.gravity) * offset.y
		if discriminant < 0.0:
			return {}
		longest = minf(longest, (speed + sqrt(discriminant)) / float(capability.gravity))
	if longest < float(capability.min_flight):
		return {}
	var shortest := clampf(distance / maxf(float(capability.travel_speed), 0.1), float(capability.min_flight), longest)
	for duration: float in [shortest, longest, (shortest + longest) * 0.5]:
		if distance / duration > float(capability.travel_speed) + 0.05:
			continue
		# move_and_slide 使用先减重力再移动的离散积分；补偿半个物理步的速度误差。
		var launch := offset / duration + Vector3.UP * float(capability.gravity) * (duration + 1.0 / Engine.physics_ticks_per_second) * 0.5
		if float(capability.launch_speed_limit) > 0.0 and launch.y > float(capability.launch_speed_limit) + 0.05:
			continue
		if not arc_clear(body, origin, launch, float(capability.gravity), duration, exclude):
			continue
		return {"kind": "jump", "capability": capability.id, "from": origin, "ground": hit.position,
			"landing": landing, "flight": duration, "launch": launch, "gravity": capability.gravity,
			"support_rid": hit.rid, "exclude": exclude.duplicate(), "cost": (duration + float(capability.windup)) * float(capability.cost_multiplier)}
	return {}

static func ground_segment(body: CharacterBody3D, from: Vector3, to: Vector3, safe_drop: float, exclude: Array[RID] = [], fine := false) -> bool:
	var offset := to - from
	var distance := Vector2(offset.x, offset.z).length()
	var steps := maxi(1, ceili(distance / (0.15 if fine else 0.45)))
	var half := float(dimensions(body).half_height)
	var previous := from + Vector3.UP * 0.025
	var previous_hit := floor_at(body, from - Vector3.UP * half, safe_drop + float(dimensions(body).radius) + 0.1, exclude)
	if previous_hit.is_empty():
		if debug: print("[T03 query] source ", from)
		return false
	for i in range(1, steps + 1):
		var fraction := float(i) / steps
		var expected := from.lerp(to, fraction) - Vector3.UP * half
		# 沿连续坡面的高度查询，不把头顶顶板误当成脚下支撑。
		var previous_normal: Vector3 = previous_hit.normal
		var step_horizontal := expected - (previous_hit.position as Vector3)
		expected.y = float(previous_hit.position.y) - (previous_normal.x * step_horizontal.x + previous_normal.z * step_horizontal.z) / maxf(previous_normal.y, 0.01)
		if previous_normal.y > 0.99:
			expected.y += Ground.STEP_HEIGHT
		var hit := floor_at(body, expected, safe_drop + 0.1, exclude)
		if hit.is_empty():
			if debug: print("[T03 query] floor ", expected, " from=", from, " to=", to)
			return false
		var normal: Vector3 = previous_hit.normal
		var horizontal := (hit.position as Vector3) - (previous_hit.position as Vector3)
		var plane_height := float(previous_hit.position.y) - (normal.x * horizontal.x + normal.z * horizontal.z) / maxf(normal.y, 0.01)
		if plane_height - float(hit.position.y) > safe_drop + 0.03:
			if debug: print("[T03 query] drop ", plane_height, " hit=", hit.position, " from=", from, " to=", to)
			return false
		var next := body_on_floor(body, hit)
		var pose := body.global_transform
		pose.origin = previous
		if not motion_clear(body, pose, next - previous, exclude):
			next = ground_pose(body, hit, exclude)
			if normal.y > 0.99 and float(hit.normal.y) > 0.99 and next.y - previous.y > Ground.STEP_HEIGHT + 0.02:
				if not fine:
					return ground_segment(body, from, to, safe_drop, exclude, true)
				if debug: print("[T03 query] rise ", previous, " -> ", next)
				return false
			if motion_clear(body, pose, next - previous, exclude):
				previous = next
				previous_hit = hit
				continue
			# 与真实跨坎动作相同：先抬起完整身体、再推进、最后落到已验证的支撑。
			var raised := pose
			raised.origin.y += Ground.STEP_HEIGHT
			var ahead := next
			ahead.y = maxf(raised.origin.y, next.y)
			if not motion_clear(body, pose, Vector3.UP * Ground.STEP_HEIGHT, exclude) or not motion_clear(body, raised, ahead - raised.origin, exclude):
				if debug: print("[T03 query] step ", previous, " -> ", next, " from=", from, " to=", to)
				return false
			var at := raised
			at.origin = ahead
			if not motion_clear(body, at, next - ahead, exclude):
				if debug: print("[T03 query] step_down ", previous, " -> ", next, " from=", from, " to=", to)
				return false
		previous = next
		previous_hit = hit
	return true
