extends RefCounted
## 从起点刷出的可达地表。显示、命中和攻击留下的笔迹共用这一份覆盖。

const CELL_SIZE := 0.5
const MAX_CELLS := 500.0
const SURFACE_OFFSET := 0.045
const SURFACE_TOLERANCE := 0.025
const GroundMovement := preload("res://scripts/ground_movement.gd")
const BRUSH_STEP_HEIGHT := GroundMovement.STEP_HEIGHT
const TARGET_CENTER_HEIGHT := 1.0
var _context: Node3D
var _pose: Transform3D
var _spec: Dictionary
var _height := 2.5
var _samples: Dictionary = {}
var _cells: Dictionary = {}
var _pieces: Dictionary = {}
var _reached: Dictionary = {}
var _first := Vector2.ZERO
var _step := CELL_SIZE
var _path: Array[Vector3] = []
var _fill := PackedVector3Array()
var _fill_uv := PackedVector2Array()
var _edge := PackedVector3Array()
var _triangles: Array[Dictionary] = []
var _by_cell: Dictionary = {}
var _boundary: Dictionary = {}


func build(context: Node3D, footprint: PackedVector2Array, spec: Dictionary) -> Dictionary:
	_context = context
	_pose = context.global_transform
	_spec = spec.duplicate()
	_height = maxf(float(spec.get("height", 2.5)), 0.1)
	if footprint.size() < 3:
		return {"fill": null, "edge": null}
	_build_flight_path()
	var bounds := Rect2(footprint[0], Vector2.ZERO)
	for point in footprint:
		bounds = bounds.expand(point)
	_step = maxf(CELL_SIZE, sqrt(bounds.get_area() / MAX_CELLS))
	_first = (bounds.position / _step).floor() * _step
	var count := ((bounds.end - _first) / _step).ceil()
	for x in range(int(count.x)):
		for z in range(int(count.y)):
			var key := Vector2i(x, z)
			var origin := _first + Vector2(key) * _step
			var cell := PackedVector2Array([origin, origin + Vector2(_step, 0),
				origin + Vector2(_step, _step), origin + Vector2(0, _step)])
			var pieces := Geometry2D.intersect_polygons(footprint, cell)
			if pieces.is_empty():
				continue
			var center := Vector2.ZERO
			for p: Vector2 in pieces[0]:
				center += p
			center /= pieces[0].size()
			if not _sample(center).is_empty():
				_cells[key] = center
				_pieces[key] = pieces
	if not _path.is_empty():
		# 飞扑的连接是实际飞行轨迹，可以跨越确实能跳过的空隙。
		_reached = _cells.duplicate()
	else:
		_brush_from_origin()
	for key: Vector2i in _reached:
		for piece in _pieces[key]:
			var indices := Geometry2D.triangulate_polygon(piece)
			for i in range(0, indices.size(), 3):
				_add_triangle(piece[indices[i]], piece[indices[i + 1]], piece[indices[i + 2]], key)
	# 边界来自真正刷出的面，包括被墙/台阶截断的边，不再画原始完整轮廓。
	for edge: Dictionary in _boundary.values():
		if edge.count != 1:
			continue
		var a: Vector3 = edge.a
		var b: Vector3 = edge.b
		var middle := (a + b) * 0.5
		var along := Vector2(b.x - a.x, b.z - a.z).normalized()
		var side := Vector3(-along.y, 0, along.x) * 0.002
		# 自适应细分形成 T 接缝；两侧都有覆盖的边属于内部，不能画成橙色网格线。
		if allows(_pose * (middle + side)) and allows(_pose * (middle - side)):
			continue
		var center: Vector3 = edge.center
		var inset := minf(0.3, 0.035 / maxf(minf(a.distance_to(center), b.distance_to(center)), 0.001))
		for p: Vector3 in [a, b, b.lerp(center, inset), a, b.lerp(center, inset), a.lerp(center, inset)]:
			_edge.append(p + Vector3.UP * 0.004)
	return {"fill": _commit(_fill, _fill_uv), "edge": _commit(_edge)}


func _brush_from_origin() -> void:
	var start := Vector2(float(_spec.get("offset", 0.0)) if String(_spec.kind) == "rect" else 0.0, 0.0)
	var seed := Vector2i(((start - _first) / _step).floor())
	var queue: Array[Vector2i] = []
	var origin := _sample(start)
	if origin.is_empty():
		return
	if not start.is_zero_approx():
		var previous := Vector2.ZERO
		for i in range(1, ceili(start.length() / CELL_SIZE) + 1):
			var next := start * minf(float(i) * CELL_SIZE / start.length(), 1.0)
			if not _can_flow(previous, next):
				return
			previous = next
	for x in range(-1, 2):
		for z in range(-1, 2):
			var key := seed + Vector2i(x, z)
			if _cells.has(key) and start.distance_to(_cells[key]) <= _step * 1.5 and _can_flow(start, _cells[key]):
				_reached[key] = _cells[key]
				queue.append(key)
	var head := 0
	while head < queue.size():
		var key := queue[head]
		head += 1
		var a: Vector2 = _cells[key]
		for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = key + offset
			if _reached.has(next) or not _cells.has(next):
				continue
			var b: Vector2 = _cells[next]
			if _can_flow(a, b):
				_reached[next] = b
				queue.append(next)


func _build_flight_path() -> void:
	if not _spec.has("travel_speed") or not _spec.has("body_shape"):
		return
	var position := _pose.origin
	var vertical := float(_spec.jump_speed)
	var dt := 1.0 / 60.0
	var forward := -_pose.basis.z
	_path.append(position)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _spec.body_shape
	query.collision_mask = 1
	query.margin = 0.001
	for _i in range(ceili(float(_spec.flight_time) / dt)):
		vertical -= float(_spec.gravity) * dt
		var motion := (forward * float(_spec.travel_speed) + Vector3.UP * vertical) * dt
		query.transform = Transform3D(_pose.basis.scaled(_spec.get("body_scale", Vector3.ONE)), position)
		query.motion = motion
		var fractions := _context.get_world_3d().direct_space_state.cast_motion(query)
		var fraction := float(fractions[0]) if not fractions.is_empty() else 0.0
		position += motion * fraction
		_path.append(position)
		if fraction < 0.999:
			break


func _sample(point: Vector2) -> Dictionary:
	var key := Vector2i((point * 10000.0).round())
	if _samples.has(key):
		return _samples[key]
	var world := _pose * Vector3(point.x, 0, point.y)
	var top := Vector3(world.x, _pose.origin.y + _height + 0.25, world.z)
	var bottom := Vector3(world.x, _pose.origin.y - _height - 0.25, world.z)
	var space := _context.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(top, bottom, 1))
	var sample: Dictionary = {}
	if not hit.is_empty() and hit.normal.y >= 0.707:
		var victim: Vector3 = hit.position + Vector3.UP * TARGET_CENTER_HEIGHT
		var source := _pose.origin + Vector3.UP * float(_spec.get("source_height", 0.2 if String(_spec.kind) == "circle" else 0.0))
		var eligible := absf(victim.y - _pose.origin.y) <= _height
		if not _path.is_empty():
			eligible = false
			# 与实际飞扑使用相同的轨迹段、水平半径、高度及前方限制。
			for i in range(_path.size() - 1):
				var nearest := Geometry3D.get_closest_point_to_segment(victim, _path[i], _path[i + 1])
				var offset := victim - nearest
				var flat := victim - _path[i]
				flat.y = 0.0
				if Vector2(offset.x, offset.z).length() <= float(_spec.radius) and absf(offset.y) <= _height - 0.03 and (flat.is_zero_approx() or (-_pose.basis.z).dot(flat.normalized()) >= cos(deg_to_rad(float(_spec.get("hit_angle", 90.0))))):
					source = nearest
					eligible = true
					break
		if eligible and (source.is_equal_approx(victim) or space.intersect_ray(PhysicsRayQueryParameters3D.create(source, victim, 1)).is_empty()):
			world.y = hit.position.y + SURFACE_OFFSET
			sample = {"point": _pose.affine_inverse() * world, "height": float(hit.position.y)}
	_samples[key] = sample
	return sample


func _continuous(a: Vector2, b: Vector2, pa: Dictionary, pb: Dictionary) -> bool:
	if pa.is_empty() or pb.is_empty() or absf(float(pa.height) - float(pb.height)) > a.distance_to(b) + 0.03:
		return false
	var mid := _sample((a + b) * 0.5)
	return not mid.is_empty() and absf(float(mid.height) - (float(pa.height) + float(pb.height)) * 0.5) <= SURFACE_TOLERANCE


func _can_flow(a: Vector2, b: Vector2) -> bool:
	var pa := _sample(a)
	var pb := _sample(b)
	if _continuous(a, b, pa, pb):
		return true
	# 笔刷可以越过能跨的薄板低边，但不会把断层两边连成悬空斜面。
	return not pa.is_empty() and not pb.is_empty() and absf(float(pa.height) - float(pb.height)) <= BRUSH_STEP_HEIGHT and not _sample((a + b) * 0.5).is_empty()


func _add_triangle(a: Vector2, b: Vector2, c: Vector2, key: Vector2i, depth := 0) -> void:
	if absf((b - a).cross(c - a)) <= 0.000001:
		return
	var pa := _sample(a)
	var pb := _sample(b)
	var pc := _sample(c)
	var center := _sample((a + b + c) / 3.0)
	if not _continuous(a, b, pa, pb) or not _continuous(b, c, pb, pc) or not _continuous(c, a, pc, pa) or center.is_empty() or absf(float(center.height) - (float(pa.height) + float(pb.height) + float(pc.height)) / 3.0) > SURFACE_TOLERANCE:
		# 只细分地形边界：保留边两侧的有效地面，缺口本身不连面。
		if depth < 3:
			var ab := (a + b) * 0.5
			var bc := (b + c) * 0.5
			var ca := (c + a) * 0.5
			_add_triangle(a, ab, ca, key, depth + 1)
			_add_triangle(ab, b, bc, key, depth + 1)
			_add_triangle(ca, bc, c, key, depth + 1)
			_add_triangle(ab, bc, ca, key, depth + 1)
		return
	# 边界细分不能在同一粗格内重新捡起墙顶/另一层平台的孤立小片。
	if _path.is_empty() and not _can_flow(_cells[key], (a + b + c) / 3.0):
		return
	var vertices := PackedVector3Array([pa.point, pb.point, pc.point])
	var bounds := Rect2(a, Vector2.ZERO).expand(b).expand(c)
	if not _by_cell.has(key):
		_by_cell[key] = []
	_by_cell[key].append(_triangles.size())
	_triangles.append({"vertices": vertices, "polygon": PackedVector2Array([a, b, c]), "cell": key, "bounds": bounds})
	for p: Vector3 in vertices:
		_fill.append(p)
		_fill_uv.append(Vector2(p.x, p.z))
	for i in range(3):
		var start := vertices[i]
		var end := vertices[(i + 1) % 3]
		var ka := Vector3i((start * 10000.0).round())
		var kb := Vector3i((end * 10000.0).round())
		var edge_key := str(ka) + "/" + str(kb) if str(ka) < str(kb) else str(kb) + "/" + str(ka)
		if _boundary.has(edge_key):
			_boundary[edge_key].count += 1
		else:
			_boundary[edge_key] = {"a": start, "b": end, "center": (vertices[0] + vertices[1] + vertices[2]) / 3.0, "count": 1}


func allows(world: Vector3) -> bool:
	var local := _pose.affine_inverse() * world
	var point := Vector2(local.x, local.z)
	var key := Vector2i(((point - _first) / _step).floor())
	var fraction := ((point - _first) / _step).posmod(1.0)
	var border := minf(minf(fraction.x, 1.0 - fraction.x), minf(fraction.y, 1.0 - fraction.y)) < 0.001
	var padding := 1 if border else 0
	for x in range(-padding, padding + 1):
		for z in range(-padding, padding + 1):
			for index: int in _by_cell.get(key + Vector2i(x, z), []):
				var polygon: PackedVector2Array = _triangles[index].polygon
				if Geometry2D.is_point_in_polygon(point, polygon):
					return true
	return false


## 攻击后的油漆笔迹只裁剪到同一份可达面；不再独立投影到另一层地形。
func paint_strokes(pose: Transform3D, strokes: Array) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var inverse := pose.affine_inverse()
	var to_brush := _pose.affine_inverse() * pose
	for stroke: PackedVector2Array in strokes:
		var polygon := PackedVector2Array()
		for p in stroke:
			var local := to_brush * Vector3(p.x, 0, p.y)
			polygon.append(Vector2(local.x, local.z))
		var bounds := Rect2(polygon[0], Vector2.ZERO)
		for p in polygon:
			bounds = bounds.expand(p)
		for triangle: Dictionary in _triangles:
			if not bounds.intersects(triangle.bounds):
				continue
			for piece in Geometry2D.intersect_polygons(polygon, triangle.polygon):
				var indices := Geometry2D.triangulate_polygon(piece)
				var tri: PackedVector3Array = triangle.vertices
				var a := Vector2(tri[0].x, tri[0].z)
				var b := Vector2(tri[1].x, tri[1].z)
				var c := Vector2(tri[2].x, tri[2].z)
				var area := (b - a).cross(c - a)
				for index in indices:
					var p := piece[index]
					var u := (p - a).cross(c - a) / area
					var v := (b - a).cross(p - a) / area
					var height := tri[0].y + (tri[1].y - tri[0].y) * u + (tri[2].y - tri[0].y) * v
					vertices.append(inverse * (_pose * Vector3(p.x, height + 0.004, p.y)))
	return _commit(vertices)


func _commit(vertices: PackedVector3Array, uv := PackedVector2Array()) -> ArrayMesh:
	if vertices.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	arrays[Mesh.ARRAY_NORMAL] = normals
	if not uv.is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
