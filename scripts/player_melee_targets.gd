extends RefCounted
## 有界物理查询；按 actor 去重，使用碰撞表面而非大 Boss 的根节点作距离判定。
const Health := preload("res://scripts/health_util.gd")

static func collect(host: CharacterBody3D, forward: Vector3, reach: float, radius: float, half_angle: float, limit: int) -> Array[Dictionary]:
	var shape := SphereShape3D.new()
	shape.radius = maxf(radius, reach * 0.5 + 0.6)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, host.global_position + Vector3.UP * 0.05 + forward * reach * 0.5)
	query.collision_mask = 4
	query.exclude = [host.get_rid()]
	var space := host.get_world_3d().direct_space_state
	var best: Dictionary = {}
	for hit in space.intersect_shape(query, limit):
		var body := hit.collider as CollisionObject3D
		if body == null or not body.is_in_group("enemies") or not Health.is_alive(body) or not body.has_method("take_damage"):
			continue
		var point := _closest(body, int(hit.shape), host.global_position + Vector3.UP * 0.05)
		var offset := point - host.global_position
		var flat := Vector3(offset.x, 0.0, offset.z)
		var distance := flat.length()
		var alignment := forward.dot(flat / distance) if distance > 0.001 else 1.0
		if offset.length() > reach + 0.6 or (distance > 0.85 and alignment < cos(deg_to_rad(half_angle))):
			continue
		var ray := PhysicsRayQueryParameters3D.create(host.global_position + Vector3.UP * 0.2,
			point, 1 | 16, [host.get_rid(), body.get_rid()])
		if not space.intersect_ray(ray).is_empty():
			continue
		var score := offset.length() - alignment * 0.45
		var id := body.get_instance_id()
		if not best.has(id) or score < float(best[id].score):
			best[id] = {"target": body, "point": point, "score": score}
	var result: Array[Dictionary] = []
	for value in best.values():
		result.append(value)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.score) < float(b.score))
	return result

static func _closest(body: CollisionObject3D, index: int, from: Vector3) -> Vector3:
	var owner := body.shape_owner_get_owner(body.shape_find_owner(index)) as CollisionShape3D
	if owner == null or owner.shape == null:
		return body.global_position
	var local := owner.global_transform.affine_inverse() * from
	var closest := Vector3.ZERO
	var radius := 0.0
	if owner.shape is CapsuleShape3D:
		radius = owner.shape.radius
		var half := maxf(owner.shape.height * 0.5 - radius, 0.0)
		closest.y = clampf(local.y, -half, half)
	elif owner.shape is SphereShape3D:
		radius = owner.shape.radius
	elif owner.shape is BoxShape3D:
		var half: Vector3 = owner.shape.size * 0.5
		closest = local.clamp(-half, half)
	else:
		return body.global_position
	if radius > 0.0:
		var direction := local - closest
		closest += direction.normalized() * minf(radius, direction.length())
	return owner.global_transform * closest
