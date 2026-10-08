@tool
extends RefCounted
## 保留的圆润云版本。默认几何、采样和松弛参数保持不变。

const Geometry := preload("res://scripts/lowpoly_mesh.gd")
const VARIANT_COUNT := 6
const GENERATION_VERSION := 2
const SURFACE_STEP := 20.0
const BLEND_RADIUS := 20.0
const TETRAHEDRA := [[0, 5, 1, 6], [0, 1, 2, 6], [0, 2, 3, 6], [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6]]
static var _meshes: Array[ArrayMesh] = []
static var _built_version := 0

class Puff:
	var center: Vector3
	var radii: Vector3
	var inverse_rotation: Basis
	var distance_scale: float


static func get_meshes() -> Array[ArrayMesh]:
	if _meshes.is_empty() or _built_version != GENERATION_VERSION:
		_meshes.clear()
		for variant in range(VARIANT_COUNT):
			_meshes.append(_build_cloud(variant))
		_built_version = GENERATION_VERSION
	return _meshes


static func refresh_for_editor() -> void:
	if Engine.is_editor_hint():
		_meshes.clear()


static func _build_cloud(variant: int) -> ArrayMesh:
	var shape := make_puffs(variant)
	return _extract_surface(shape["puffs"], shape["lower"], shape["upper"])


static func make_puffs(variant: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7319 + variant * 103
	# 六种非对称骨架：隆起、弯尾、分叉、宽团、斜坡、破碎长带。
	# 云块先融合为一个体积场，再提取连续表面；不保留相交椭球的台阶和薄片。
	var layouts := [
		[Vector3(-48, -8, 10), Vector3(0, 14, 0), Vector3(38, 32, -10), Vector3(66, 2, 17), Vector3(-12, -18, 32), Vector3(12, 0, -37)],
		[Vector3(-76, -22, -20), Vector3(-38, -6, -7), Vector3(0, 12, 8), Vector3(36, 22, 27), Vector3(63, 0, 56), Vector3(32, -13, 66)],
		[Vector3(-57, 2, 0), Vector3(-14, 20, 3), Vector3(23, 0, -23), Vector3(63, -18, -35), Vector3(21, 33, 30), Vector3(54, 11, 56)],
		[Vector3(-45, 9, -23), Vector3(0, 26, -33), Vector3(48, -4, -9), Vector3(27, 13, 34), Vector3(-15, -20, 40), Vector3(-54, -2, 22)],
		[Vector3(-77, -26, 16), Vector3(-37, -7, -9), Vector3(0, 14, 8), Vector3(30, 39, -16), Vector3(60, 20, -36), Vector3(53, -8, 20)],
		[Vector3(-97, 10, -14), Vector3(-61, -12, 10), Vector3(-17, 23, 0), Vector3(22, -9, -23), Vector3(61, 11, -7), Vector3(94, -16, 19), Vector3(10, 5, 40)],
	]
	var layout: Array = layouts[variant]
	var largest := rng.randi_range(1, 3)
	var puffs: Array[Puff] = []
	var lower := Vector3.ONE * INF
	var upper := Vector3.ONE * -INF
	for index in range(layout.size()):
		var puff := Puff.new()
		puff.center = layout[index] + Vector3(
			rng.randf_range(-9.0, 9.0), rng.randf_range(-10.0, 10.0), rng.randf_range(-9.0, 9.0))
		var mass := rng.randf_range(0.86, 1.12)
		if index == largest:
			mass = 1.28
		puff.radii = Vector3(
			rng.randf_range(42.0, 57.0), rng.randf_range(34.0, 51.0), rng.randf_range(37.0, 53.0)) * mass
		var rotation := Basis.from_euler(Vector3(
			rng.randf_range(-0.12, 0.12), rng.randf_range(-0.45, 0.45), rng.randf_range(-0.14, 0.14)))
		puff.inverse_rotation = rotation.transposed()
		puff.distance_scale = minf(puff.radii.x, minf(puff.radii.y, puff.radii.z))
		var extent := rotation.x.abs() * puff.radii.x + rotation.y.abs() * puff.radii.y + rotation.z.abs() * puff.radii.z
		lower = lower.min(puff.center - extent)
		upper = upper.max(puff.center + extent)
		puffs.append(puff)
	return {"puffs": puffs, "lower": lower - Vector3.ONE * 40.0, "upper": upper + Vector3.ONE * 40.0}


static func _distance(point: Vector3, puffs: Array[Puff]) -> float:
	var distance := 1000000.0
	for puff in puffs:
		var local := puff.inverse_rotation * (point - puff.center) / puff.radii
		var next := (local.length() - 1.0) * puff.distance_scale
		var blend := clampf(0.5 + 0.5 * (next - distance) / BLEND_RADIUS, 0.0, 1.0)
		distance = lerpf(next, distance, blend) - BLEND_RADIUS * blend * (1.0 - blend)
	return distance


static func _extract_surface(puffs: Array[Puff], lower: Vector3, upper: Vector3,
		sampler: Callable = Callable(), relaxation: float = 0.28, face_color: Callable = Callable(), weld_distance: float = 0.0) -> ArrayMesh:
	var cells := Vector3i(
		ceili((upper.x - lower.x) / SURFACE_STEP), ceili((upper.y - lower.y) / SURFACE_STEP),
		ceili((upper.z - lower.z) / SURFACE_STEP))
	var nx := cells.x + 1
	var ny := cells.y + 1
	var points := PackedVector3Array()
	var values := PackedFloat32Array()
	for z in range(cells.z + 1):
		for y in range(ny):
			for x in range(nx):
				var point := lower + Vector3(x, y, z) * SURFACE_STEP
				points.append(point)
				values.append(float(sampler.call(point)) if sampler.is_valid() else _distance(point, puffs))
	var vertices := PackedVector3Array()
	var faces := PackedInt32Array()
	var crossings: Dictionary = {}
	for z in range(cells.z):
		for y in range(cells.y):
			for x in range(cells.x):
				var base := (z * ny + y) * nx + x
				var ids := [base, base + 1, base + nx + 1, base + nx,
					base + nx * ny, base + nx * ny + 1, base + nx * ny + nx + 1, base + nx * ny + nx]
				for tetrahedron in TETRAHEDRA:
					var inside: Array[int] = []
					var outside: Array[int] = []
					for corner in tetrahedron:
						var id: int = ids[corner]
						if values[id] < 0.0:
							inside.append(id)
						else:
							outside.append(id)
					if inside.is_empty() or outside.is_empty():
						continue
					var direction := Vector3.ZERO
					for id in outside:
						direction += points[id] / float(outside.size())
					for id in inside:
						direction -= points[id] / float(inside.size())
					if inside.size() == 2:
						var a := _crossing(inside[0], outside[0], points, values, vertices, crossings)
						var b := _crossing(inside[0], outside[1], points, values, vertices, crossings)
						var c := _crossing(inside[1], outside[0], points, values, vertices, crossings)
						var d := _crossing(inside[1], outside[1], points, values, vertices, crossings)
						_append_face(a, b, c, direction, vertices, faces)
						_append_face(b, d, c, direction, vertices, faces)
					else:
						var single: Array[int] = inside if inside.size() == 1 else outside
						var others: Array[int] = outside if inside.size() == 1 else inside
						var a := _crossing(single[0], others[0], points, values, vertices, crossings)
						var b := _crossing(single[0], others[1], points, values, vertices, crossings)
						var c := _crossing(single[0], others[2], points, values, vertices, crossings)
						_append_face(a, b, c, direction, vertices, faces)
	# 平面体积场可能恰好穿过采样点，先焊接浮点误差产生的几乎重合顶点。
	if weld_distance > 0.0:
		var welded := _weld_surface(vertices, faces, weld_distance)
		vertices = welded["vertices"]
		faces = welded["faces"]
		vertices = _repair_slivers(vertices, faces)
	# 圆润版做两次松弛；切面版保持零松弛，提交时都使用硬面法线。
	if relaxation > 0.0:
		vertices = _relax_surface(vertices, faces, relaxation)
	var builder := Geometry.begin()
	for index in range(0, faces.size(), 3):
		var a := vertices[faces[index]]
		var b := vertices[faces[index + 1]]
		var c := vertices[faces[index + 2]]
		if face_color.is_valid():
			Geometry.push_triangle(builder, a, b, c, face_color.call(a, b, c))
		else:
			_push_face(builder, a, b, c, 0.0)
	return Geometry.commit(builder)


static func _weld_surface(vertices: PackedVector3Array, faces: PackedInt32Array, tolerance: float) -> Dictionary:
	var welded := PackedVector3Array()
	var remap := PackedInt32Array()
	var buckets: Dictionary = {}
	for vertex in vertices:
		var cell := Vector3i(floori(vertex.x / tolerance), floori(vertex.y / tolerance), floori(vertex.z / tolerance))
		var matched := -1
		for dz in range(-1, 2):
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var neighbor := cell + Vector3i(dx, dy, dz)
					for candidate in buckets.get(neighbor, []):
						if vertex.distance_squared_to(welded[candidate]) < tolerance * tolerance:
							matched = int(candidate)
		if matched < 0:
			matched = welded.size()
			welded.append(vertex)
			if not buckets.has(cell):
				buckets[cell] = []
			buckets[cell].append(matched)
		remap.append(matched)
	var clean_faces := PackedInt32Array()
	for index in range(0, faces.size(), 3):
		var a := remap[faces[index]]
		var b := remap[faces[index + 1]]
		var c := remap[faces[index + 2]]
		if a != b and a != c and b != c:
			clean_faces.append_array(PackedInt32Array([a, b, c]))
	return {"vertices": welded, "faces": clean_faces}


static func _repair_slivers(vertices: PackedVector3Array, faces: PackedInt32Array) -> PackedVector3Array:
	var neighbors: Array[Dictionary] = []
	for _index in range(vertices.size()):
		neighbors.append({})
	for index in range(0, faces.size(), 3):
		for edge in range(3):
			var a := faces[index + edge]
			var b := faces[index + (edge + 1) % 3]
			neighbors[a][b] = true
			neighbors[b][a] = true
	# 只修复数值上近乎共线的微小三角形，正常平面和剪影顶点保持原位。
	for _iteration in range(3):
		var affected: Dictionary = {}
		for index in range(0, faces.size(), 3):
			var a := faces[index]
			var b := faces[index + 1]
			var c := faces[index + 2]
			if (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).length_squared() < 0.01:
				affected[a] = true
				affected[b] = true
				affected[c] = true
		if affected.is_empty():
			break
		var repaired := vertices.duplicate()
		for index in affected:
			var average := Vector3.ZERO
			for neighbor in neighbors[index]:
				average += vertices[neighbor]
			repaired[index] = vertices[index].lerp(average / neighbors[index].size(), 0.15)
		vertices = repaired
	return vertices


static func _crossing(a: int, b: int, points: PackedVector3Array, values: PackedFloat32Array,
		vertices: PackedVector3Array, crossings: Dictionary) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if crossings.has(key):
		return int(crossings[key])
	var index := vertices.size()
	var t := values[a] / (values[a] - values[b])
	vertices.append(points[a].lerp(points[b], t))
	crossings[key] = index
	return index


static func _append_face(a: int, b: int, c: int, outward: Vector3,
		vertices: PackedVector3Array, faces: PackedInt32Array) -> void:
	if (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).dot(outward) < 0.0:
		faces.append_array(PackedInt32Array([a, c, b]))
	else:
		faces.append_array(PackedInt32Array([a, b, c]))


static func _relax_surface(vertices: PackedVector3Array, faces: PackedInt32Array, weight: float = 0.28) -> PackedVector3Array:
	var neighbors: Array[Dictionary] = []
	for _index in range(vertices.size()):
		neighbors.append({})
	for index in range(0, faces.size(), 3):
		for edge in range(3):
			var a := faces[index + edge]
			var b := faces[index + (edge + 1) % 3]
			neighbors[a][b] = true
			neighbors[b][a] = true
	for _iteration in range(2):
		var relaxed := vertices.duplicate()
		for index in range(vertices.size()):
			var average := Vector3.ZERO
			for neighbor in neighbors[index]:
				average += vertices[neighbor]
			if not neighbors[index].is_empty():
				relaxed[index] = vertices[index].lerp(average / neighbors[index].size(), weight)
		vertices = relaxed
	return vertices


static func _push_face(builder: Geometry.Builder, a: Vector3, b: Vector3, c: Vector3, shade_bias: float) -> void:
	var normal := (b - a).cross(c - a).normalized()
	# 按实际切面方向保存结构明暗，替代“底面一整块灰、侧面一整圈白”的分区色。
	var shade := clampf(0.91 + normal.y * 0.075 + normal.x * 0.025 + normal.z * 0.018 + shade_bias, 0.80, 1.0)
	Geometry.push_triangle(builder, a, b, c, Color(shade, minf(shade + 0.012, 1.0), minf(shade + 0.025, 1.0)))
