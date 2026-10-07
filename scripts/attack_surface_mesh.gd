extends RefCounted
## 从起点刷出的可达地表。显示、命中和攻击留下的笔迹共用这一份覆盖。

const CELL_SIZE := 1.0
const MAX_CELLS := 160.0
const BORDER_SUBDIVISIONS := 2
const SURFACE_OFFSET := 0.045
const SURFACE_TOLERANCE := 0.025
const GroundMovement := preload("res://scripts/ground_movement.gd")
const BRUSH_STEP_HEIGHT := GroundMovement.STEP_HEIGHT
const TARGET_CENTER_HEIGHT := 1.0
enum BuildStage { CELLS, FLOW, FACES, EDGES, DONE }
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
var _boundary_edges: Array[Dictionary] = []
var _inverse: Transform3D
var _space: PhysicsDirectSpaceState3D
var _ray := PhysicsRayQueryParameters3D.new()
var _source := Vector3.ZERO
var _forward := Vector3.FORWARD
var _flight_step := 0.0
var _flight_radius := 0.0
var _flight_angle_cos := 0.0
var _flight_segments := PackedVector4Array()
var _flight_inverse_lengths := PackedFloat32Array()
var _plane_height := INF
var _flat_footprint := PackedVector2Array()
var _task_footprint := PackedVector2Array()
var _grid_count := Vector2i.ZERO
var _grid_index := 0
var _stage := BuildStage.DONE
var _triangle_tasks: Array[Array] = []
var _brush_queue: Array[Vector2i] = []
var _brush_head := 0
var _face_keys: Array[Vector2i] = []
var _face_index := 0
var _edge_index := 0
var _meshes: Dictionary = {"fill": null, "edge": null}
static var _jobs: Array[WeakRef] = []
static var _job_frame := -1
static var last_job_frame_usec := 0
const TRACK_FRAME_BUDGET_USEC := 3000


func query_reachable(context: Node3D, pose: Transform3D, spec: Dictionary, world: Vector3) -> bool:
	# 选招只检查通往目标的刷面连通性，复用实际刷面的采样 / 轨迹规则。
	# 不生成网格，不提交显示任务；完整选中范围仍由 prepare / lock 构建。
	_pose = pose
	_inverse = pose.affine_inverse()
	_space = context.get_world_3d().direct_space_state
	_spec = spec.duplicate()
	_height = maxf(float(spec.get("height", 2.5)), 0.1)
	_ray.collision_mask = 1
	_ray.exclude = spec.get("exclude_bodies", [])
	_source = pose.origin + Vector3.UP * float(spec.get("source_height", 0.2 if String(spec.kind) == "circle" else 0.0))
	_forward = -pose.basis.z
	_flight_step = float(spec.get("travel_speed", 0.0)) / 60.0
	_flight_radius = float(spec.get("radius", 0.0))
	_flight_angle_cos = cos(deg_to_rad(float(spec.get("hit_angle", 90.0))))
	_build_flight_path()
	var local := _inverse * world
	var point := Vector2(local.x, local.z)
	if not _path.is_empty():
		return not _sample(point).is_empty()
	var start := Vector2(float(spec.get("offset", 0.0)) if String(spec.kind) == "rect" else 0.0, 0.0)
	if _sample(start).is_empty():
		return false
	var previous := start
	var steps := maxi(1, ceili(start.distance_to(point) / 0.3))
	for i in range(1, steps + 1):
		var next := start.lerp(point, float(i) / steps)
		if not _can_flow(previous, next):
			return false
		previous = next
	return true


func build(context: Node3D, footprint: PackedVector2Array, spec: Dictionary) -> Dictionary:
	begin(context, footprint, spec)
	return finish()


func begin(context: Node3D, footprint: PackedVector2Array, spec: Dictionary) -> void:
	_pose = context.global_transform
	_inverse = _pose.affine_inverse()
	_space = context.get_world_3d().direct_space_state
	_ray.collision_mask = 1
	_ray.exclude = spec.get("exclude_bodies", [])
	_spec = spec.duplicate()
	_height = maxf(float(spec.get("height", 2.5)), 0.1)
	_source = _pose.origin + Vector3.UP * float(spec.get("source_height", 0.2 if String(spec.kind) == "circle" else 0.0))
	_forward = -_pose.basis.z
	_flight_step = float(spec.get("travel_speed", 0.0)) / 60.0
	_flight_radius = float(spec.get("radius", 0.0))
	_flight_angle_cos = cos(deg_to_rad(float(spec.get("hit_angle", 90.0))))
	if footprint.size() < 3:
		return
	_build_flight_path()
	var bounds := Rect2(footprint[0], Vector2.ZERO)
	for point in footprint:
		bounds = bounds.expand(point)
	_step = maxf(CELL_SIZE, sqrt(bounds.get_area() / MAX_CELLS))
	_first = (bounds.position / _step).floor() * _step
	_find_clear_plane(footprint)
	var plane_polygon := footprint if _path.is_empty() else _clear_flight_footprint(footprint)
	if is_finite(_plane_height) and not plane_polygon.is_empty():
		# 整个范围只有同一块平坦地板时，直接裁剪原轮廓即可；不跑密集栅格。
		_flat_footprint = plane_polygon
		var key := Vector2i.ZERO
		_cells[key] = Vector2.ZERO
		var indices := Geometry2D.triangulate_polygon(plane_polygon)
		for i in range(0, indices.size(), 3):
			_add_triangle(plane_polygon[indices[i]], plane_polygon[indices[i + 1]], plane_polygon[indices[i + 2]], key)
		_meshes = _finish_meshes()
		return
	_task_footprint = footprint
	_grid_count = Vector2i(((bounds.end - _first) / _step).ceil())
	_stage = BuildStage.CELLS


func finish() -> Dictionary:
	while not is_finished():
		advance(1000000)
	return _meshes


func is_finished() -> bool:
	return _stage == BuildStage.DONE


func get_meshes() -> Dictionary:
	return _meshes


func queue_build() -> void:
	if not is_finished():
		_jobs.append(weakref(self))


static func process_build_jobs() -> void:
	var frame := Engine.get_process_frames()
	if frame == _job_frame:
		return
	_job_frame = frame
	var start := Time.get_ticks_usec()
	while not _jobs.is_empty() and Time.get_ticks_usec() - start < TRACK_FRAME_BUDGET_USEC:
		var job: RefCounted = _jobs.pop_front().get_ref()
		if job == null or job.is_finished():
			continue
		job.advance(mini(500, TRACK_FRAME_BUDGET_USEC - int(Time.get_ticks_usec() - start)))
		if not job.is_finished():
			_jobs.append(weakref(job))
	last_job_frame_usec = Time.get_ticks_usec() - start


func advance(budget_usec: int) -> void:
	var end := Time.get_ticks_usec() + maxi(budget_usec, 1)
	while not is_finished() and Time.get_ticks_usec() < end:
		match _stage:
			BuildStage.CELLS:
				if _grid_index < _grid_count.x * _grid_count.y:
					_collect_cell(Vector2i(_grid_index / _grid_count.y, _grid_index % _grid_count.y))
					_grid_index += 1
				else:
					_stage = BuildStage.FLOW
					if not _path.is_empty():
						_reached = _cells.duplicate()
					else:
						_begin_brush()
			BuildStage.FLOW:
				if _brush_head < _brush_queue.size():
					_flow_cell()
				else:
					_face_keys.assign(_reached.keys())
					_stage = BuildStage.FACES
			BuildStage.FACES:
				if _triangle_tasks.is_empty():
					if _face_index < _face_keys.size():
						var key := _face_keys[_face_index]
						_face_index += 1
						for piece in _pieces[key]:
							var indices := Geometry2D.triangulate_polygon(piece)
							for i in range(0, indices.size(), 3):
								_triangle_tasks.append([piece[indices[i]], piece[indices[i + 1]], piece[indices[i + 2]], key, 0])
					else:
						_stage = BuildStage.EDGES
				else:
					var task: Array = _triangle_tasks.pop_back()
					_add_triangle(task[0], task[1], task[2], task[3], task[4])
			BuildStage.EDGES:
				if _edge_index < _boundary_edges.size():
					_add_border(_boundary_edges[_edge_index])
					_edge_index += 1
				else:
					_meshes = {"fill": _commit(_fill, _fill_uv), "edge": _commit(_edge)}
					_stage = BuildStage.DONE


func _collect_cell(key: Vector2i) -> void:
	var origin := _first + Vector2(key) * _step
	var cell := PackedVector2Array([origin, origin + Vector2(_step, 0), origin + Vector2(_step, _step), origin + Vector2(0, _step)])
	var pieces := Geometry2D.intersect_polygons(_task_footprint, cell)
	if pieces.is_empty():
		return
	var center := Vector2.ZERO
	for p: Vector2 in pieces[0]:
		center += p
	center /= pieces[0].size()
	if not _sample(center).is_empty():
		_cells[key] = center
		_pieces[key] = pieces


func _finish_meshes() -> Dictionary:
	# 边界来自真正刷出的面，包括被墙/台阶截断的边，不再画原始完整轮廓。
	for edge: Dictionary in _boundary_edges:
		_add_border(edge)
	return {"fill": _commit(_fill, _fill_uv), "edge": _commit(_edge)}


func _add_border(edge: Dictionary) -> void:
	if edge.count != 1:
		return
	var a: Vector3 = edge.a
	var b: Vector3 = edge.b
	var middle := (a + b) * 0.5
	var along := Vector2(b.x - a.x, b.z - a.z).normalized()
	var side := Vector3(-along.y, 0, along.x) * 0.002
	if allows(_pose * (middle + side)) and allows(_pose * (middle - side)):
		return
	var center: Vector3 = edge.center
	var inset := minf(0.3, 0.035 / maxf(minf(a.distance_to(center), b.distance_to(center)), 0.001))
	for p: Vector3 in [a, b, b.lerp(center, inset), a, b.lerp(center, inset), a.lerp(center, inset)]:
		_edge.append(p + Vector3.UP * 0.004)


func _find_clear_plane(footprint: PackedVector2Array) -> void:
	if _pose.basis.y.dot(Vector3.UP) < 0.99999:
		return
	var world_bounds := AABB(_pose * Vector3(footprint[0].x, 0, footprint[0].y), Vector3.ZERO)
	for p in footprint:
		world_bounds = world_bounds.expand(_pose * Vector3(p.x, 0, p.y))
	world_bounds = world_bounds.expand(_source)
	world_bounds.position.y = _pose.origin.y - _height - 0.25
	world_bounds.size.y = (_height + 0.25) * 2.0
	var box := BoxShape3D.new()
	box.size = world_bounds.size + Vector3(0.01, 0.01, 0.01)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(Basis.IDENTITY, world_bounds.get_center())
	query.collision_mask = 1
	query.exclude = _ray.exclude
	var overlaps := _space.intersect_shape(query, 2)
	# 有第二个碰撞面（台阶、坡板、墙、桥等）就保留完整刷面流程。
	if overlaps.size() != 1 or not overlaps[0].collider is StaticBody3D:
		return
	var body: StaticBody3D = overlaps[0].collider
	var owner := body.shape_owner_get_owner(body.shape_find_owner(int(overlaps[0].shape))) as CollisionShape3D
	if owner == null or not owner.shape is BoxShape3D or owner.global_basis.y.normalized().dot(Vector3.UP) < 0.99999:
		return
	var inverse := owner.global_transform.affine_inverse()
	var half: Vector3 = owner.shape.size * 0.5
	for p in footprint:
		var local := inverse * (_pose * Vector3(p.x, 0, p.y))
		if absf(local.x) > half.x - 0.005 or absf(local.z) > half.z - 0.005:
			return
	var height := (owner.global_transform * Vector3(0, half.y, 0)).y
	if _source.y <= height + 0.005:
		return
	_plane_height = height


func _clear_flight_footprint(footprint: PackedVector2Array) -> PackedVector2Array:
	if not is_finite(_plane_height) or _path.size() < 2 or absf(_forward.y) > 0.001 or _flight_angle_cos > 0.00001:
		return PackedVector2Array()
	var victim_y := _plane_height + TARGET_CENTER_HEIGHT
	var shift := 0.0
	for i in range(_flight_segments.size()):
		var segment := _flight_segments[i]
		var gap := maxf(absf(victim_y - segment.y), absf(victim_y - segment.y - segment.w))
		if gap > _height - 0.03 or minf(segment.y, segment.y + segment.w) <= _plane_height + 0.005:
			return PackedVector2Array()
		# 最近三维点相对水平投影的最大偏移。收窄这几厘米，保证整片笔刷确实能命中。
		shift = maxf(shift, gap * absf(segment.z * segment.w) * _flight_inverse_lengths[i])
	var radius := _flight_radius - shift - 0.005
	if radius <= 0.0:
		return PackedVector2Array()
	var length := (_path[-1] - _path[0]).dot(_forward)
	var brush := PackedVector2Array([Vector2(-radius, -0.001), Vector2(radius, -0.001)])
	for i in range(17):
		var a := PI * i / 16.0
		brush.append(Vector2(cos(a) * radius, -length - sin(a) * radius))
	var clipped := Geometry2D.intersect_polygons(footprint, brush)
	return clipped[0] if clipped.size() == 1 else PackedVector2Array()


func _begin_brush() -> void:
	var start := Vector2(float(_spec.get("offset", 0.0)) if String(_spec.kind) == "rect" else 0.0, 0.0)
	var seed := Vector2i(((start - _first) / _step).floor())
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
				_brush_queue.append(key)


func _flow_cell() -> void:
	var key := _brush_queue[_brush_head]
	_brush_head += 1
	var a: Vector2 = _cells[key]
	for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var next: Vector2i = key + offset
		if _reached.has(next) or not _cells.has(next):
			continue
		var b: Vector2 = _cells[next]
		if _can_flow(a, b):
			_reached[next] = b
			_brush_queue.append(next)


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
	query.exclude = _ray.exclude
	query.margin = 0.001
	for _i in range(ceili(float(_spec.flight_time) / dt)):
		vertical -= float(_spec.gravity) * dt
		var motion := (forward * float(_spec.travel_speed) + Vector3.UP * vertical) * dt
		query.transform = Transform3D(_pose.basis.scaled(_spec.get("body_scale", Vector3.ONE)), position)
		query.motion = motion
		var fractions := _space.cast_motion(query)
		var fraction := float(fractions[0]) if not fractions.is_empty() else 0.0
		position += motion * fraction
		_path.append(position)
		if fraction < 0.999:
			break
	for i in range(_path.size() - 1):
		var motion := _path[i + 1] - _path[i]
		_flight_segments.append(Vector4((_path[i] - _path[0]).dot(_forward), _path[i].y, motion.dot(_forward), motion.y))
		_flight_inverse_lengths.append(1.0 / maxf(motion.length_squared(), 0.00000001))


func _sample(point: Vector2) -> Dictionary:
	var key := Vector2i((point * 10000.0).round())
	if _samples.has(key):
		return _samples[key]
	var world := _pose * Vector3(point.x, 0, point.y)
	var top := Vector3(world.x, _pose.origin.y + _height + 0.25, world.z)
	var bottom := Vector3(world.x, _pose.origin.y - _height - 0.25, world.z)
	var hit: Dictionary
	if is_finite(_plane_height):
		hit = {"position": Vector3(world.x, _plane_height, world.z), "normal": Vector3.UP}
	else:
		_ray.from = top
		_ray.to = bottom
		hit = _space.intersect_ray(_ray)
	var sample: Dictionary = {}
	if not hit.is_empty() and hit.normal.y >= 0.707:
		var victim: Vector3 = hit.position + Vector3.UP * TARGET_CENTER_HEIGHT
		var source := _source
		var eligible := absf(victim.y - _pose.origin.y) <= _height
		if not _path.is_empty():
			eligible = false
			# 与实际飞扑使用相同的轨迹段、水平半径、高度及前方限制。
			# 水平速度固定；只有目标前后一个命中半径内的轨迹段可能命中。
			# 不为每个地表采样点遍历整条飞行轨迹。
			var first := 0
			var last := _path.size() - 1
			var along := (victim - _path[0]).dot(_forward)
			var side_squared := maxf(Vector2(victim.x - _path[0].x, victim.z - _path[0].z).length_squared() - along * along, 0.0)
			if _flight_step > 0.001 and absf(_forward.y) < 0.001:
				first = maxi(floori((along - _flight_radius) / _flight_step) - 1, 0)
				last = mini(ceili((along + _flight_radius) / _flight_step) + 1, last)
			for i in range(first, last):
				if absf(_forward.y) < 0.001:
					var segment := _flight_segments[i]
					var ahead := along - segment.x
					if (side_squared + ahead * ahead > 0.000001 and ahead / sqrt(side_squared + ahead * ahead) < _flight_angle_cos):
						continue
					var t := clampf((ahead * segment.z + (victim.y - segment.y) * segment.w) * _flight_inverse_lengths[i], 0.0, 1.0)
					if side_squared + pow(ahead - segment.z * t, 2.0) <= _flight_radius * _flight_radius and absf(victim.y - segment.y - segment.w * t) <= _height - 0.03:
						source = _path[i].lerp(_path[i + 1], t)
						eligible = true
						break
					continue
				var nearest := Geometry3D.get_closest_point_to_segment(victim, _path[i], _path[i + 1])
				var offset := victim - nearest
				var flat := victim - _path[i]
				flat.y = 0.0
				if Vector2(offset.x, offset.z).length_squared() <= _flight_radius * _flight_radius and absf(offset.y) <= _height - 0.03 and (flat.is_zero_approx() or _forward.dot(flat.normalized()) >= _flight_angle_cos):
					source = nearest
					eligible = true
					break
		_ray.from = source
		_ray.to = victim
		if eligible and (is_finite(_plane_height) or source.is_equal_approx(victim) or _space.intersect_ray(_ray).is_empty()):
			world.y = hit.position.y + SURFACE_OFFSET
			sample = {"point": _inverse * world, "height": float(hit.position.y)}
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
	# 四个探针都不可达时，不继续细分空白区域。边界有有效探针时仍细分到原精度。
	if pa.is_empty() and pb.is_empty() and pc.is_empty() and center.is_empty():
		return
	if not _continuous(a, b, pa, pb) or not _continuous(b, c, pb, pc) or not _continuous(c, a, pc, pa) or center.is_empty() or absf(float(center.height) - (float(pa.height) + float(pb.height) + float(pc.height)) / 3.0) > SURFACE_TOLERANCE:
		# 只细分地形边界：保留边两侧的有效地面，缺口本身不连面。
		if depth < BORDER_SUBDIVISIONS:
			var ab := (a + b) * 0.5
			var bc := (b + c) * 0.5
			var ca := (c + a) * 0.5
			if _stage == BuildStage.FACES:
				_triangle_tasks.append_array([[a, ab, ca, key, depth + 1], [ab, b, bc, key, depth + 1], [ca, bc, c, key, depth + 1], [ab, bc, ca, key, depth + 1]])
			else:
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
		# 数值键替代每条边多次 Vector3→字符串转换，边的端点只排序一次。
		if ka.x > kb.x or (ka.x == kb.x and (ka.y > kb.y or (ka.y == kb.y and ka.z > kb.z))):
			var swap := ka
			ka = kb
			kb = swap
		if not _boundary.has(ka):
			_boundary[ka] = {}
		var ends: Dictionary = _boundary[ka]
		if ends.has(kb):
			ends[kb].count += 1
		else:
			var edge := {"a": start, "b": end, "center": (vertices[0] + vertices[1] + vertices[2]) / 3.0, "count": 1}
			ends[kb] = edge
			_boundary_edges.append(edge)


func allows(world: Vector3) -> bool:
	var local := _inverse * world
	var point := Vector2(local.x, local.z)
	if not _flat_footprint.is_empty():
		return not _triangles.is_empty() and Geometry2D.is_point_in_polygon(point, _flat_footprint)
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
	var uv := PackedVector2Array()
	var inverse := pose.affine_inverse()
	var to_brush := _inverse * pose
	for stroke: PackedVector2Array in strokes:
		var polygon := PackedVector2Array()
		for p in stroke:
			var local := to_brush * Vector3(p.x, 0, p.y)
			polygon.append(Vector2(local.x, local.z))
		var bounds := Rect2(polygon[0], Vector2.ZERO)
		for p in polygon:
			bounds = bounds.expand(p)
		# 只访问笔迹包围盒里的格子，不逐笔遍历整个攻击面的所有三角形。
		var first := Vector2i(((bounds.position - _first) / _step).floor())
		var last := Vector2i(((bounds.end - _first) / _step).floor())
		var candidates: Array[int] = []
		if not _flat_footprint.is_empty():
			for i in range(_triangles.size()):
				candidates.append(i)
		else:
			for x in range(first.x, last.x + 1):
				for z in range(first.y, last.y + 1):
					candidates.append_array(_by_cell.get(Vector2i(x, z), []))
		for triangle_index in candidates:
			var triangle: Dictionary = _triangles[triangle_index]
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
					var vertex := inverse * (_pose * Vector3(p.x, height + 0.004, p.y))
					vertices.append(vertex)
					uv.append(Vector2(vertex.x, vertex.z))
	return _commit(vertices, uv)


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
