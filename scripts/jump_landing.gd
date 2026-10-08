extends RefCounted
## 跳上台面需要完整脚印有支撑。中心射线命中不代表身体能站稳。
const SAMPLE_STEP := 0.25


static func supported(context: Node3D, ground: Vector3, normal: Vector3, shape: Shape3D, basis: Basis, exclude: Array[RID] = []) -> bool:
	var footprint := PackedVector2Array()
	var scale := basis.get_scale().abs()
	var yaw := basis.orthonormalized()
	if shape is BoxShape3D:
		var half: Vector3 = shape.size * scale * 0.5 + Vector3(0.05, 0, 0.05)
		for corner in [Vector3(-half.x, 0, -half.z), Vector3(half.x, 0, -half.z), Vector3(half.x, 0, half.z), Vector3(-half.x, 0, half.z)]:
			var p: Vector3 = yaw * corner
			footprint.append(Vector2(p.x, p.z))
	else:
		var radius := float(shape.radius) * maxf(scale.x, scale.z) + 0.05
		for i in range(32):
			footprint.append(Vector2(cos(TAU * i / 32.0), sin(TAU * i / 32.0)) * radius)
	var points := PackedVector2Array([Vector2.ZERO])
	var bounds := Rect2(footprint[0], Vector2.ZERO)
	for i in range(footprint.size()):
		bounds = bounds.expand(footprint[i])
		var a := footprint[i]
		var b := footprint[(i + 1) % footprint.size()]
		var steps := maxi(ceili(a.distance_to(b) / SAMPLE_STEP), 1)
		for j in range(steps):
			points.append(a.lerp(b, float(j) / steps))
	for x in range(ceili(bounds.size.x / SAMPLE_STEP) + 1):
		for z in range(ceili(bounds.size.y / SAMPLE_STEP) + 1):
			var p := bounds.position + Vector2(x, z) * SAMPLE_STEP
			if Geometry2D.is_point_in_polygon(p, footprint):
				points.append(p)
	var space := context.get_world_3d().direct_space_state
	for p in points:
		var expected := ground + Vector3(p.x, -(normal.x * p.x + normal.z * p.y) / maxf(normal.y, 0.01), p.y)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(expected + Vector3.UP * 0.2, expected + Vector3.DOWN * 0.2, 1, exclude))
		if hit.is_empty() or hit.normal.y < 0.707 or absf(float(hit.position.y) - expected.y) > 0.12:
			return false
	return true
