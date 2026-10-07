extends Node3D
## 给任意物件赋予破坏能力：挂在物件根节点下，收集其静态碰撞与完整模型。
signal broken(component: Node3D)
signal restored(component: Node3D)
const Profile := preload("res://scripts/destruction_profile.gd")
const Debris := preload("res://scripts/destruction_debris.gd")
const Audio := preload("res://scripts/audio_manager.gd")
const OWNER_META := &"destructible_component"
@export var profile: Profile = preload("res://data/destruction/stone.tres")
@export_node_path("Node3D") var intact_path := NodePath("../Intact")
@export_node_path("Node3D") var remains_path := NodePath("../Rubble")
@export_node_path("Node3D") var object_path := NodePath("..")
var is_broken := false
var _object: Node3D
var _intact: Array[Node3D] = []
var _visibility: Array[bool] = []
var _remains: Node3D
var _bodies: Array[StaticBody3D] = []
var _layers: Array[int] = []
var _bounds := AABB(Vector3.ZERO, Vector3.ONE)


func _ready() -> void:
	_object = get_node_or_null(object_path) as Node3D
	if _object == null:
		return
	if not profile is Profile:
		profile = Profile.new()
	_remains = get_node_or_null(remains_path) as Node3D
	var intact := get_node_or_null(intact_path) as Node3D
	if intact:
		_intact.append(intact)
	_collect(_object, intact == null)
	for visual in _intact:
		_visibility.append(visual.visible)
	if _remains:
		_remains.visible = false
	_bounds = _measure_bounds()
	add_to_group("destructible_props")


func _collect(node: Node, collect_visuals: bool) -> void:
	if node == self or node == _remains:
		return
	if node is StaticBody3D:
		_bodies.append(node)
		_layers.append(node.collision_layer)
		node.set_meta(OWNER_META, weakref(self))
	if collect_visuals and node is GeometryInstance3D:
		_intact.append(node)
	for child in node.get_children():
		_collect(child, collect_visuals)


func _measure_bounds() -> AABB:
	var meshes: Array[Node] = _object.find_children("*", "MeshInstance3D", true, false)
	if _object is MeshInstance3D:
		meshes.append(_object)
	var bounds := AABB()
	var found := false
	for mesh: MeshInstance3D in meshes:
		if mesh.mesh == null or (_remains and (_remains == mesh or _remains.is_ancestor_of(mesh))):
			continue
		var box: AABB = (_object.global_transform.affine_inverse() * mesh.global_transform) * mesh.get_aabb()
		bounds = bounds.merge(box) if found else box
		found = true
	# 无视觉网格的物件也可以用已有碰撞得到边界。
	if not found:
		for body in _bodies:
			for child in body.get_children():
				if child is CollisionShape3D and child.shape:
					var box: AABB = (_object.global_transform.affine_inverse() * child.global_transform) * child.shape.get_debug_mesh().get_aabb()
					bounds = bounds.merge(box) if found else box
					found = true
	return bounds if found else AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)


func can_break(power: float) -> bool:
	return not is_broken and not _bodies.is_empty() and power > 0.0 and power >= float(profile.strength)


func get_collision_rids() -> Array[RID]:
	var result: Array[RID] = []
	for body in _bodies:
		if is_instance_valid(body) and not body.is_queued_for_deletion():
			result.append(body.get_rid())
	return result


func impact_point(from: Vector3) -> Vector3:
	var local := _object.to_local(from)
	return _object.to_global(Vector3(clampf(local.x, _bounds.position.x, _bounds.end.x),
		clampf(local.y, _bounds.position.y + minf(0.15, _bounds.size.y * 0.5), _bounds.end.y),
		clampf(local.z, _bounds.position.z, _bounds.end.z)))


func contact_points(pose: Transform3D, footprint: PackedVector2Array, source: Vector3) -> Array[Vector3]:
	# 用物件边界与本段攻击相交，长墙的边缘命中也成立，不只检查物件中心。
	var inverse := pose.affine_inverse()
	var projected := PackedVector2Array()
	for i in range(8):
		var local: Vector3 = inverse * (_object.global_transform * _bounds.get_endpoint(i))
		projected.append(Vector2(local.x, local.z))
	var hull := Geometry2D.convex_hull(projected)
	if hull.size() > 1 and hull[0].is_equal_approx(hull[-1]):
		hull.resize(hull.size() - 1)
	var result: Array[Vector3] = []
	var height: float = (inverse * impact_point(source)).y
	for patch: PackedVector2Array in Geometry2D.intersect_polygons(footprint, hull):
		var center := Vector2.ZERO
		for point in patch:
			center += point
		center /= patch.size()
		result.append(pose * Vector3(center.x, height, center.y))
	return result


func break_from_impact(point: Vector3, direction: Vector3, power: float) -> bool:
	if not can_break(power):
		return false
	is_broken = true
	preload("res://scripts/environment_destruction.gd").geometry_changed()
	# 同帧移除整个物件的碰撞；下一次移动或攻击射线立即看到通路。
	for body in _bodies:
		if is_instance_valid(body):
			body.collision_layer = 0
	for visual in _intact:
		visual.visible = false
	if _remains:
		_remains.visible = true
	var host := get_tree().current_scene
	if host == null:
		host = _object.get_parent()
	var pose := _object.global_transform * Transform3D(Basis.IDENTITY, _bounds.position)
	Debris.spawn(host, pose, _bounds.size, profile, direction)
	Audio.play_at("explosion", point, -13.0, 0.8)
	broken.emit(self)
	return true


func reset_destruction() -> void:
	if not is_broken:
		return
	is_broken = false
	preload("res://scripts/environment_destruction.gd").geometry_changed()
	for i in range(_bodies.size()):
		if is_instance_valid(_bodies[i]):
			_bodies[i].collision_layer = _layers[i]
	for i in range(_intact.size()):
		_intact[i].visible = _visibility[i]
	if _remains:
		_remains.visible = false
	restored.emit(self)


func _exit_tree() -> void:
	for body in _bodies:
		if is_instance_valid(body) and body.has_meta(OWNER_META) and body.get_meta(OWNER_META).get_ref() == self:
			body.remove_meta(OWNER_META)
