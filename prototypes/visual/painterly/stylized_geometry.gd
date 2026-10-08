extends RefCounted
## Silhouette studies: actual 3D geometry, not a screen-space distortion.
const Geometry := preload("res://scripts/lowpoly_mesh.gd")

static func _outward(builder: Geometry.Builder, a: Vector3, b: Vector3, c: Vector3, reference: Vector3 = Vector3.ZERO) -> void:
	if (b - a).cross(c - a).dot((a + b + c) / 3.0 - reference) < 0:
		Geometry.push_triangle(builder, a, c, b, Color.WHITE)
	else:
		Geometry.push_triangle(builder, a, b, c, Color.WHITE)

static func organic_mass(kind: int, ink: bool) -> ArrayMesh:
	if kind == 5 and ink:
		return ink_mountain()
	var builder := Geometry.begin()
	var sides := 12 if kind == 4 else 32
	var rings := 6 if kind == 4 else 16
	for j in rings:
		for i in sides:
			var a := _mass_point(float(i) / sides, float(j) / rings, kind, ink)
			var b := _mass_point(float(i + 1) / sides, float(j) / rings, kind, ink)
			var c := _mass_point(float(i) / sides, float(j + 1) / rings, kind, ink)
			var d := _mass_point(float(i + 1) / sides, float(j + 1) / rings, kind, ink)
			_outward(builder, a, b, c)
			_outward(builder, b, d, c)
	return Geometry.commit(builder)

static func _mass_point(u: float, v: float, kind: int, ink: bool) -> Vector3:
	var angle := u * TAU
	var latitude := v * PI
	# Every longitude must meet at exactly ONE pole. Angular offsets at radius
	# zero previously split the ridge cap into several heights, opening slits.
	var radius := 0.0 if v <= 0.0 or v >= 1.0 else sin(latitude)
	var y := cos(latitude)
	var irregularity := 1.0 + 0.095 * sin(angle * 3 + y * 2) + 0.045 * cos(angle * 5 - y * 3)
	var p := Vector3(cos(angle) * radius * irregularity, y, sin(angle) * radius * irregularity)
	if kind == 2:
		# Uneven umbrella-like masses, flatter underneath, rounded on top.
		p.y = y * (0.9 if y >= 0 else 0.42) + 0.12 * p.x + 0.06 * sin(angle * 3) * radius
		p.x += 0.12 * (1 - y * y)
	elif kind == 4:
		# An asymmetric rock with a broad shoulder and a buried flatter base.
		p.y = maxf(y, -0.64) + 0.22 * p.x - 0.14 * p.z
		p.x *= 1.0 + 0.16 * y
		# Broad irregular shoulders, not a smooth egg with ink applied to it.
		p.z *= 1.0 + 0.18 * sin(angle * 2.0) * radius
	elif kind == 5:
		# Narrower, leaning summits and broad feet. Fade angular variation at
		# BOTH poles to preserve a closed surface from every camera direction.
		p.y = signf(y) * pow(absf(y), 2.2 if ink else 1.35)
		p.y *= 1.0 + (0.32 if ink else 0.18) * cos(angle * 3 + 0.4) * radius
		p.x += (0.36 if ink else 0.19) * y * y
	return p

static func ink_mountain() -> ArrayMesh:
	# A lofted, stepped crag: broad buried foot, narrower ledges and a leaning
	# summit. It intentionally does not reuse an ellipsoid's silhouette.
	const HEIGHTS := [-0.45, -0.08, 0.27, 0.65, 1.05, 1.34]
	const WIDTHS := [0.9, 1.0, 0.82, 0.6, 0.37, 0.10]
	const LEANS := [0.0, -0.04, -0.12, 0.08, 0.23, 0.30]
	const SIDES := 16
	var builder := Geometry.begin()
	var rings: Array[Array] = []
	for j in HEIGHTS.size():
		var ring: Array[Vector3] = []
		for i in SIDES:
			var angle := float(i) / SIDES * TAU
			var width: float = WIDTHS[j] * (1.0 + 0.14 * sin(angle * 3 + j * 0.24) + 0.08 * cos(angle * 5))
			ring.append(Vector3(cos(angle) * width + LEANS[j], HEIGHTS[j] + 0.035 * sin(angle * 3) * WIDTHS[j], sin(angle) * width * 0.85))
		rings.append(ring)
	var bottom := Vector3(0, -0.5, 0)
	var top := Vector3(0.32, 1.4, 0)
	for i in SIDES:
		var next := (i + 1) % SIDES
		_outward(builder, bottom, rings[0][next], rings[0][i])
		for j in rings.size() - 1:
			_outward(builder, rings[j][i], rings[j][next], rings[j + 1][i])
			_outward(builder, rings[j][next], rings[j + 1][next], rings[j + 1][i])
		_outward(builder, rings.back()[i], rings.back()[next], top)
	return Geometry.commit(builder)

static func bent_trunk(original: CylinderMesh, ink: bool) -> ArrayMesh:
	var builder := Geometry.begin()
	const SIDES := 12
	const RINGS := 6
	for j in RINGS:
		var t0 := float(j) / RINGS
		var t1 := float(j + 1) / RINGS
		var c0 := _trunk_center(t0, original.height, ink)
		var c1 := _trunk_center(t1, original.height, ink)
		var r0 := lerpf(original.bottom_radius, original.top_radius, t0)
		var r1 := lerpf(original.bottom_radius, original.top_radius, t1)
		for i in SIDES:
			var a0 := TAU * float(i) / SIDES
			var a1 := TAU * float(i + 1) / SIDES
			var a := c0 + Vector3(cos(a0), 0, sin(a0)) * r0
			var b := c0 + Vector3(cos(a1), 0, sin(a1)) * r0
			var c := c1 + Vector3(cos(a0), 0, sin(a0)) * r1
			var d := c1 + Vector3(cos(a1), 0, sin(a1)) * r1
			_outward(builder, a, b, c, (c0 + c1) / 2)
			_outward(builder, b, d, c, (c0 + c1) / 2)
			if j == 0:
				Geometry.push_triangle(builder, c0, a, b, Color.WHITE)
			if j == RINGS - 1:
				Geometry.push_triangle(builder, c1, d, c, Color.WHITE)
	return Geometry.commit(builder)

static func _trunk_center(t: float, height: float, ink: bool) -> Vector3:
	return Vector3(sin(t * PI * 0.9) * (0.38 if ink else 0.22), (t - 0.5) * height, sin(t * PI * 1.3) * 0.12)

static func validate_trunk_outward(mesh: ArrayMesh, height: float, ink: bool) -> PackedStringArray:
	# A curved tube is not convex about the global origin. Validate each side
	# against its LOCAL centerline, and end caps against their axial directions.
	var errors := PackedStringArray()
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in range(0, vertices.size(), 3):
		var a := vertices[i]
		var b := vertices[i + 1]
		var c := vertices[i + 2]
		var front := (c - a).cross(b - a).normalized()
		var center := (a + b + c) / 3.0
		var t := clampf(center.y / height + 0.5, 0.0, 1.0)
		var outward := center - _trunk_center(t, height, ink)
		if is_equal_approx(a.y, b.y) and is_equal_approx(a.y, c.y):
			outward = Vector3.DOWN if t < 0.5 else Vector3.UP
		if front.length_squared() < 0.9 or front.dot(outward) <= 0.0001:
			errors.append("triangle %d: inward/degenerate curved tube face" % (i / 3))
		if front.dot(normals[i]) < 0.999:
			errors.append("triangle %d: normal disagrees with front face" % (i / 3))
	return errors

static func carved_stone(original: ArrayMesh, ink: bool, bevel: float) -> ArrayMesh:
	var arrays: Array = closed_chamfer(original.get_aabb().size, bevel).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var builder := Geometry.begin()
	var amount := 0.055 if ink else 0.085
	for i in range(0, vertices.size(), 3):
		var points: Array[Vector3] = []
		for j in 3:
			var p := vertices[i + j]
			# Same input coordinate -> same output, preserving welded edge positions.
			p += Vector3(sin(p.y * 2.3 + p.z), sin(p.x * 2 + p.z * 1.4), cos(p.y * 2.4 + p.x)) * amount
			points.append(p)
		_outward(builder, points[0], points[1], points[2])
	return Geometry.commit(builder)

static func closed_chamfer(size: Vector3, bevel: float) -> ArrayMesh:
	# Six rectangular faces + twelve edge quads + eight corner triangles.
	# At a corner, TWO coordinates are inset. Insetting only ONE and also
	# adding edge quads produces overlapping faces (a truncated cube plus
	# extra ribbons), even if every triangle's individual normal faces out.
	var half := size * 0.5
	if bevel <= 0.0:
		var box := Geometry.begin()
		Geometry.push_box(box, Vector3.ZERO, size, Color.WHITE)
		return Geometry.commit(box)
	var b := clampf(bevel, 0.001, minf(half.x, minf(half.y, half.z)) * 0.95)
	var vertices: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var signs := Vector3(sx, sy, sz)
				for axis in 3:
					var point := signs * (half - Vector3.ONE * b)
					point[axis] = signs[axis] * half[axis]
					vertices.append(point)
	var builder := Geometry.begin()
	for axis in 3:
		for sign_value in [-1.0, 1.0]:
			var normal := Vector3.ZERO
			normal[axis] = sign_value
			_plane_polygon(builder, vertices, normal, half[axis])
	for pair: Vector2i in [Vector2i(0, 1), Vector2i(0, 2), Vector2i(1, 2)]:
		for sa in [-1.0, 1.0]:
			for sb in [-1.0, 1.0]:
				var normal := Vector3.ZERO
				normal[pair.x] = sa
				normal[pair.y] = sb
				_plane_polygon(builder, vertices, normal, half[pair.x] + half[pair.y] - b)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				_plane_polygon(builder, vertices, Vector3(sx, sy, sz), half.x + half.y + half.z - 2.0 * b)
	return Geometry.commit(builder)

static func _plane_polygon(builder: Geometry.Builder, vertices: Array[Vector3], normal: Vector3, distance: float) -> void:
	var points: Array[Vector3] = []
	var center := Vector3.ZERO
	for vertex in vertices:
		if absf(vertex.dot(normal) - distance) < 0.00001:
			points.append(vertex)
			center += vertex
	assert(points.size() >= 3)
	center /= points.size()
	var helper := Vector3.UP if absf(normal.normalized().y) < 0.9 else Vector3.RIGHT
	var axis_u := helper.cross(normal).normalized()
	var axis_v := normal.cross(axis_u).normalized()
	points.sort_custom(func(a: Vector3, c: Vector3) -> bool:
		return atan2((a - center).dot(axis_v), (a - center).dot(axis_u)) < atan2((c - center).dot(axis_v), (c - center).dot(axis_u))
	)
	for i in range(1, points.size() - 1):
		_outward(builder, points[0], points[i], points[i + 1])

static func contour_shell(source: Mesh) -> Mesh:
	if not source is ArrayMesh:
		return source
	# Flat face normals on duplicated vertices tear an expanded outline hull
	# apart. Weld NORMALS (not positions) for this separate contour pass so
	# every coincident corner expands in exactly the same direction.
	var arrays: Array = source.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var accumulated: Dictionary = {}
	for i in range(0, vertices.size(), 3):
		var normal := (vertices[i + 2] - vertices[i]).cross(vertices[i + 1] - vertices[i])
		for j in 3:
			var key := Vector3i((vertices[i + j] * 10000.0).round())
			accumulated[key] = accumulated.get(key, Vector3.ZERO) + normal
	var normals := PackedVector3Array()
	for vertex in vertices:
		var key := Vector3i((vertex * 10000.0).round())
		var normal: Vector3 = accumulated[key]
		normals.append(normal.normalized())
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func validate_closed_surface(mesh: ArrayMesh) -> PackedStringArray:
	# Edge pairing catches open caps and locally reversed faces, including
	# non-convex curved tubes. Position quantization welds float-equivalent seams.
	var errors := PackedStringArray()
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var edges: Dictionary = {}
	for i in range(0, vertices.size(), 3):
		for j in 3:
			var a := Vector3i((vertices[i + j] * 10000.0).round())
			var b := Vector3i((vertices[i + (j + 1) % 3] * 10000.0).round())
			var sa := str(a)
			var sb := str(b)
			var forward := sa < sb
			var key := sa + ":" + sb if forward else sb + ":" + sa
			var counts: Vector2i = edges.get(key, Vector2i.ZERO)
			counts += Vector2i(1, 1 if forward else -1)
			edges[key] = counts
	for key in edges:
		var counts: Vector2i = edges[key]
		if counts != Vector2i(2, 0):
			errors.append("Unpaired/reversed edge %s: %s" % [key, counts])
	return errors
