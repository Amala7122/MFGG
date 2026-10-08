extends RefCounted
const Query := preload("res://scripts/spatial_query.gd")
const Capability := preload("res://scripts/traversal_capability.gd")

static func pose(body: CharacterBody3D, point: Vector3, normal: Vector3, forward: Vector3) -> Transform3D:
	var up := normal.normalized()
	var direction := forward - up * forward.dot(up)
	if direction.length() < 0.01:
		direction = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	direction = direction.normalized()
	var right := direction.cross(up).normalized()
	return Transform3D(Basis(right, up, -direction).scaled(body.global_basis.get_scale()), point)

static func contact(body: CharacterBody3D, point: Vector3, normal: Vector3, ability: Resource) -> Dictionary:
	var distance := float(Query.dimensions(body).half_height) + float(ability.contact_distance) + 0.1
	var directions: Array[Vector3] = [-normal, Vector3.DOWN, Vector3.UP, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]
	for direction in directions:
		var query := PhysicsRayQueryParameters3D.create(point, point + direction * distance, 1)
		var hit := body.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or (hit.normal as Vector3).dot(normal) < 0.5:
			continue
		var collider: Object = hit.collider
		if collider.has_meta(&"spatial_attachable") and not bool(collider.get_meta(&"spatial_attachable")):
			continue
		return hit
	return {}

static func plan(body: CharacterBody3D, points: PackedVector3Array, normals: PackedVector3Array, ability: Resource, attachable: bool, start_pose: Variant = null) -> Dictionary:
	if ability.kind == Capability.Kind.CUSTOM:
		return ability.plan_custom(body, points, normals)
	if points.size() < 2 or (ability.kind == Capability.Kind.CLIMB and (not attachable or normals.size() != points.size())):
		return {}
	var length := 0.0
	var previous := body.global_transform
	if start_pose is Transform3D:
		previous = start_pose
		length = previous.origin.distance_to(points[0])
	else:
		previous.origin = points[0]
	var poses: Array[Transform3D] = []
	for i in range(points.size()):
		var normal := normals[i] if normals.size() == points.size() else Vector3.UP
		if normal.length() < 0.5:
			return {}
		if i > 0:
			if normals.size() == points.size() and normals[i - 1].angle_to(normal) > deg_to_rad(float(ability.max_turn_degrees)):
				return {}
			length += points[i - 1].distance_to(points[i])
		var forward := points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]
		var next := pose(body, points[i], normal, forward)
		var steps := maxi(1, ceili(previous.origin.distance_to(next.origin) / 0.15))
		steps = maxi(steps, ceili(previous.basis.orthonormalized().get_rotation_quaternion().angle_to(next.basis.orthonormalized().get_rotation_quaternion()) / 0.1))
		for j in range(steps + 1):
			var checked := previous.interpolate_with(next, float(j) / steps)
			# 从真实地面接触开始转身，留白不应大于角色实际接触皮肤。
			var contact_margin := 0.0002 if i == 0 and start_pose is Transform3D else 0.002
			var excluded: Array[RID] = []
			if not Query.motion_clear(body, checked, Vector3.ZERO, excluded, contact_margin):
				return {}
			if j > 0:
				var before := previous.interpolate_with(next, float(j - 1) / steps)
				if not Query.motion_clear(body, before, checked.origin - before.origin, excluded, contact_margin):
					return {}
			if ability.kind == Capability.Kind.CLIMB and contact(body, checked.origin, checked.basis.y.normalized(), ability).is_empty():
				return {}
			if poses.is_empty() or (poses.back() as Transform3D).origin.distance_to(checked.origin) > 0.001 or not (poses.back() as Transform3D).basis.is_equal_approx(checked.basis):
				poses.append(checked)
		previous = next
	if length > float(ability.max_distance):
		return {}
	return {"kind": "climb" if ability.kind == Capability.Kind.CLIMB else "fly", "capability": ability.id,
		"poses": poses, "landing": points[points.size() - 1], "duration": length / maxf(float(ability.travel_speed), 0.1),
		"cost": length / maxf(float(ability.travel_speed), 0.1) * float(ability.cost_multiplier)}
