extends RefCounted
## 攻击与环境之间的公共接口；物件类型不参与攻击逻辑。
const OWNER_META := &"destructible_component"
static var geometry_revision := 0


static func component_for(collider: Object) -> Node3D:
	return _component(collider)


static func geometry_changed() -> void:
	geometry_revision += 1


static func _component(collider: Object) -> Node3D:
	if collider == null or not collider.has_meta(OWNER_META):
		return null
	return collider.get_meta(OWNER_META).get_ref() as Node3D


static func breakable_rids(context: Node3D, power: float) -> Array[RID]:
	var result: Array[RID] = []
	for prop: Node in context.get_tree().get_nodes_in_group("destructible_props"):
		if not prop.is_queued_for_deletion() and prop.can_break(power):
			result.append_array(prop.get_collision_rids())
	return result


static func break_contacts(body: CharacterBody3D, motion: Vector3, power: float) -> int:
	var broken := 0
	var space := body.get_world_3d().direct_space_state
	var exclude := breakable_rids(body, power)
	exclude.append(body.get_rid())
	# 每次重新扫到最近接触，不能穿过不可破坏墙去砸后面的石块。
	for _attempt in range(8):
		var contact := KinematicCollision3D.new()
		if not body.test_move(body.global_transform, motion, contact, 0.01, true, 8):
			break
		var changed := false
		for i in range(contact.get_collision_count()):
			var prop := _component(contact.get_collider(i))
			if prop == null:
				continue
			var point := contact.get_position(i)
			var query := PhysicsRayQueryParameters3D.create(body.global_position, point, 1, exclude)
			if space.intersect_ray(query).is_empty() and prop.break_from_impact(point, motion, power):
				broken += 1
				changed = true
		if not changed:
			break
	return broken


static func radial_impact(context: Node3D, point: Vector3, radius: float, height: float, power: float) -> int:
	return _impact(context, Transform3D(Basis.IDENTITY, point),
		{"kind": "circle", "radius": radius, "height": height, "source_height": 0.2}, power)


static func shape_impact(area: Node3D, power: float, first_angle := -INF, last_angle := INF) -> int:
	return _impact(area, area.global_transform, area.shape, power, area.get_surface(), first_angle, last_angle)


static func _impact(context: Node3D, pose: Transform3D, spec: Dictionary, power: float,
		surface: RefCounted = null, first_angle := -INF, last_angle := INF) -> int:
	if power <= 0.0 or context.get_tree().get_nodes_in_group("destructible_props").is_empty():
		return 0
	var source := pose.origin + Vector3.UP * float(spec.get("source_height", 0.0))
	var space := context.get_world_3d().direct_space_state
	var candidates: Dictionary = {}
	var exclude: Array[RID] = []
	for polygon: PackedVector2Array in _footprints(spec, first_angle, last_angle):
		var vertices := PackedVector3Array()
		var height := maxf(float(spec.get("height", 2.5)), 0.1)
		for point in polygon:
			vertices.append(Vector3(point.x, -height, point.y))
			vertices.append(Vector3(point.x, height, point.y))
		var volume := ConvexPolygonShape3D.new()
		volume.points = vertices
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = volume
		query.transform = pose
		query.collision_mask = 1
		# 分批排除已查询的碰撞体，密集场景也不受单次物理查询返回数限制。
		while true:
			var hits := space.intersect_shape(query, 256)
			var visited: Array[RID] = query.exclude
			for hit: Dictionary in hits:
				visited.append(hit.rid)
				var prop := _component(hit.collider)
				if prop == null or prop.is_queued_for_deletion() or not prop.can_break(power):
					continue
				if not candidates.has(prop):
					candidates[prop] = []
					exclude.append_array(prop.get_collision_rids())
				candidates[prop].append_array(prop.contact_points(pose, polygon, source))
			if hits.size() < 256:
				break
			query.exclude = visited
	var broken := 0
	for prop: Node3D in candidates:
		for point: Vector3 in candidates[prop]:
			if surface and not surface.call("allows", point):
				continue
			var ray := PhysicsRayQueryParameters3D.create(source, point, 1, exclude)
			if space.intersect_ray(ray).is_empty() and prop.break_from_impact(point, point - source, power):
				broken += 1
				break
	return broken


static func _footprints(spec: Dictionary, first: float, last: float) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	if String(spec.kind) == "rect":
		var x := float(spec.get("offset", 0.0))
		var half := float(spec.width) * 0.5
		var length := float(spec.length)
		result.append(PackedVector2Array([Vector2(x-half, 0), Vector2(x+half, 0), Vector2(x+half, -length), Vector2(x-half, -length)]))
		return result
	var arc := TAU if String(spec.kind) == "circle" else deg_to_rad(float(spec.get("angle", 180.0)))
	first = maxf(first, -arc * 0.5)
	last = minf(last, arc * 0.5)
	if last <= first:
		return result
	# 大于半圆的扇形不能用单个凸体查询；拆成最多 90 度的连续片段。
	var slices := maxi(1, ceili((last - first) / (PI * 0.5)))
	for i in range(slices):
		var start := lerpf(first, last, float(i) / slices)
		var end := lerpf(first, last, float(i + 1) / slices)
		var polygon := PackedVector2Array([Vector2.ZERO])
		var steps := maxi(1, ceili((end - start) / (PI / 24.0)))
		for j in range(steps + 1):
			var angle := lerpf(start, end, float(j) / steps)
			polygon.append(Vector2(sin(angle), -cos(angle)) * float(spec.radius))
		result.append(polygon)
	return result
