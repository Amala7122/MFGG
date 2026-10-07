extends RefCounted
const SpatialQuery := preload("res://scripts/spatial_query.gd")
## 原地跳起的普通近战：沿真实身体移动判定挥击，落回原来的地面，不创建地面效果。
var _body: CharacterBody3D
var _target: Node3D
var _spec: Dictionary
var _elapsed := 0.0
var _flight := 0.0
var _previous := Vector3.ZERO
var _spent := false


static func can_start(body: CharacterBody3D, target: Node3D, spec: Dictionary) -> bool:
	var apex := float(spec.jump_speed) * float(spec.jump_speed) / (2.0 * float(spec.gravity))
	return body.is_on_floor() and not body.test_move(body.global_transform, Vector3.UP * apex) and can_start_at(body, target, spec, body.global_transform)


static func can_start_at(body: CharacterBody3D, target: Node3D, spec: Dictionary, pose: Transform3D) -> bool:
	if not is_instance_valid(target) or float(target.get("health")) <= 0.0:
		return false
	var offset := target.global_position - pose.origin
	if Vector2(offset.x, offset.z).length() > float(spec.reach):
		return false
	var apex := float(spec.jump_speed) * float(spec.jump_speed) / (2.0 * float(spec.gravity))
	# 完整身体向上扫掠，包括头部；低顶和台子底面会阻止这次跳跃。
	var raised := pose
	raised.origin.y += 0.01
	if not SpatialQuery.motion_clear(body, raised, Vector3.UP * apex):
		return false
	for i in range(5):
		var point := pose.origin + Vector3.UP * apex * (0.55 + i * 0.1)
		if absf(target.global_position.y - point.y) <= float(spec.height) and _clear(body, point, target.global_position):
			return true
	return false


func begin(body: CharacterBody3D, target: Node3D, spec: Dictionary) -> void:
	_body = body
	_target = target
	_spec = spec.duplicate()
	_elapsed = 0.0
	_flight = 2.0 * float(spec.jump_speed) / float(spec.gravity)
	_previous = body.global_position
	_spent = false
	body.velocity = Vector3.UP * float(spec.jump_speed)


func in_strike_window(delta := 0.0) -> bool:
	return _elapsed + delta >= _flight * 0.35 and _elapsed + delta <= _flight * 0.65


func advance(delta: float) -> bool:
	_elapsed += delta
	var hit := false
	if not _spent and is_instance_valid(_target) and float(_target.get("health")) > 0.0 and _elapsed >= _flight * 0.35 and _elapsed <= _flight * 0.65:
		var point := Geometry3D.get_closest_point_to_segment(_target.global_position, _previous, _body.global_position)
		var offset := _target.global_position - point
		var flat := Vector3(offset.x, 0, offset.z)
		if flat.length() <= float(_spec.reach) and absf(offset.y) <= float(_spec.height) and (flat.is_zero_approx() or (-_body.global_basis.z).dot(flat.normalized()) >= 0.0) and _clear(_body, point, _target.global_position):
			_spent = true
			hit = true
	_previous = _body.global_position
	return hit


func finished() -> bool:
	return (_elapsed > 0.2 and _body.is_on_floor()) or _elapsed > _flight + 0.5


static func _clear(context: Node3D, from: Vector3, to: Vector3) -> bool:
	return context.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 1)).is_empty()
