extends RefCounted
## One continuous background surface. Only the waterfall's local escarpment is
## refined; distant mountains retain large, irregular, flat-shaded faces.
const Geometry := preload("res://scripts/lowpoly_mesh.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const StaticCache := preload("res://scripts/valley_static_cache.gd")
const RINGS := 28
const SEGMENTS := 36
const BIN_SIZE := 32.0
const LIP_X := [50.0, 68.0, 85.0, 97.0, 110.0, 126.0, 145.0, 158.0]
const LIP_Z := [-357.0, -349.0, -355.0, -352.0, -350.0, -355.0, -348.0, -355.0]

static var _mesh: ArrayMesh
static var _raw_vertices := PackedVector3Array()
static var _vertices := PackedVector3Array()
static var _raw_bins: Dictionary = {}
static var _bins: Dictionary = {}
static var _samples: Dictionary = {}
static var _crest_height := 0.0
static var _arena_key := ""
static var generated_builds := 0

static func reset() -> void:
	_mesh = null
	_raw_vertices.clear()
	_vertices.clear()
	_raw_bins.clear()
	_bins.clear()
	_samples.clear()
	_arena_key = ""

static func height(x: float, z: float) -> float:
	var r := maxf(absf(x), absf(z))
	var a := atan2(z, x)
	var boundary := Vector2(x, z) * (89.0 / maxf(r, 89.0))
	var base := Terrain.height_at(boundary.x, boundary.y)
	var foothill := 11.0 + 6.0 * sin(a * 5.0 + 0.6) + 3.0 * cos(a * 11.0)
	var ridge := 72.0 + 34.0 * sin(a * 7.0 + 0.9) + 19.0 * cos(a * 13.0 - 0.5)
	var summit := 122.0 + 55.0 * sin(a * 9.0 - 0.3) + 33.0 * cos(a * 17.0)
	var h := foothill * exp(-pow((r - 205.0) / 75.0, 2.0))
	h += ridge * exp(-pow((r - 395.0 - 28.0 * sin(a * 6.0)) / 102.0, 2.0))
	h += summit * exp(-pow((r - 590.0 - 35.0 * cos(a * 5.0)) / 116.0, 2.0))
	var lateral := minf(absf(x), absf(z))
	var spur := exp(-pow((lateral - 190.0) / 105.0, 2.0)) * exp(-pow((r - 370.0) / 132.0, 2.0))
	h += 74.0 * spur * (0.77 + 0.23 * sin(lateral * 0.064 + r * 0.027 + a * 3.7)) * smoothstep(210.0, 300.0, r)
	var wall := exp(-pow((lateral - 335.0) / 145.0, 2.0)) * exp(-pow((r - 575.0) / 145.0, 2.0))
	h += 58.0 * wall * (0.80 + 0.20 * cos(lateral * 0.039 - a * 5.0))
	return lerpf(base - 0.04, h, smoothstep(89.0, 180.0, r))

static func lip_z(x: float) -> float:
	for i in LIP_X.size() - 1:
		if x <= LIP_X[i + 1]:
			return lerpf(LIP_Z[i], LIP_Z[i + 1], clampf((x - LIP_X[i]) / (LIP_X[i + 1] - LIP_X[i]), 0.0, 1.0))
	return LIP_Z[-1]

static func mountains() -> ArrayMesh:
	var key := StaticCache.signature()
	if _mesh != null and _arena_key == key:
		return _mesh
	reset()
	_arena_key = key
	if StaticCache.current():
		_mesh = ResourceLoader.load(StaticCache.MOUNTAIN_PATH, "", ResourceLoader.CACHE_MODE_REPLACE) as ArrayMesh
		_vertices = _mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		return _mesh
	generated_builds += 1
	var raw := Geometry.begin()
	for side in 4:
		var grid: Array[Vector3] = []
		for ring in RINGS + 1:
			for column in SEGMENTS + 1:
				grid.append(_grid_point(side, ring, column))
		for ring in RINGS:
			for column in SEGMENTS:
				var a := grid[ring * (SEGMENTS + 1) + column]
				var b := grid[ring * (SEGMENTS + 1) + column + 1]
				var c := grid[(ring + 1) * (SEGMENTS + 1) + column + 1]
				var d := grid[(ring + 1) * (SEGMENTS + 1) + column]
				if sin(float(ring * 37 + column * 13 + side * 73)) > 0.0:
					Geometry.push_triangle(raw, a, b, d, Color.WHITE)
					Geometry.push_triangle(raw, b, c, d, Color.WHITE)
				else:
					Geometry.push_quad(raw, a, b, c, d, Color.WHITE)
	_raw_vertices = raw.verts
	_raw_bins = _index(_raw_vertices)
	_crest_height = _sample(Vector2(104.0, lip_z(104.0)), _raw_vertices, _raw_bins) + 25.0
	var land := Geometry.begin()
	for i in range(0, _raw_vertices.size(), 3):
		# Stored Godot winding -> utility's outward winding.
		var a := _raw_vertices[i]
		var b := _raw_vertices[i + 2]
		var c := _raw_vertices[i + 1]
		var near_cascade := maxf(a.x, maxf(b.x, c.x)) > 40.0 and minf(a.x, minf(b.x, c.x)) < 170.0 \
			and maxf(a.z, maxf(b.z, c.z)) > -438.0 and minf(a.z, minf(b.z, c.z)) < -336.0
		if near_cascade:
			_refine(land, a, b, c, 2)
		else:
			_push_land(land, a, b, c)
	_vertices = land.verts
	_bins = _index(_vertices)
	_mesh = Geometry.commit(land)
	return _mesh

static func _grid_point(side: int, ring: int, column: int) -> Vector3:
	var r := lerpf(89.0, 820.0, pow(float(ring) / RINGS, 1.35))
	var u := -1.0 + 2.0 * float(column) / SEGMENTS
	if ring > 0 and ring < RINGS and column > 0 and column < SEGMENTS:
		# Jitter is a fraction of cell size, not tiny periodic ripples on a dense grid.
		var previous := lerpf(89.0, 820.0, pow(float(ring - 1) / RINGS, 1.35))
		u += (2.0 / SEGMENTS) * 0.23 * sin(float(ring * 71 + column * 43 + side * 19))
		r += (r - previous) * 0.18 * sin(float(ring * 31 + column * 59 + side * 47))
	var p := Vector3(r * u, 0, -r)
	p = Basis(Vector3.UP, side * PI * 0.5) * p
	p.y = height(p.x, p.z)
	return p

static func _refine(builder: Geometry.Builder, a: Vector3, b: Vector3, c: Vector3, depth: int) -> void:
	if depth > 0:
		var ab := (a + b) * 0.5
		var bc := (b + c) * 0.5
		var ca := (c + a) * 0.5
		_refine(builder, a, ab, ca, depth - 1)
		_refine(builder, ab, b, bc, depth - 1)
		_refine(builder, ca, bc, c, depth - 1)
		_refine(builder, ab, bc, ca, depth - 1)
		return
	# Split at the actual crest and foot of the escarpment. Both banks and the
	# steep face are the same surface, sharing the same boundary coordinates.
	var min_x := minf(a.x, minf(b.x, c.x))
	var max_x := maxf(a.x, maxf(b.x, c.x))
	var cuts := [-10000.0] + LIP_X + [10000.0]
	for slab in cuts.size() - 1:
		var lo: float = cuts[slab]
		var hi: float = cuts[slab + 1]
		if lo > max_x or hi < min_x:
			continue
		var polygon: Array[Vector3] = [a, b, c]
		polygon = _clip(polygon, Vector2(1, 0), lo, false)
		polygon = _clip(polygon, Vector2(1, 0), hi, true)
		if polygon.size() < 3:
			continue
		var x0 := maxf(lo, 50.0)
		var x1 := minf(hi, 158.0)
		var slope := (lip_z(x1) - lip_z(x0)) / maxf(x1 - x0, 0.001) if x1 > x0 else 0.0
		var intercept := lip_z(x0) - slope * x0
		var normal := Vector2(-slope, 1)
		_push_polygon(builder, _clip(polygon, normal, intercept, true))
		var downstream := _clip(polygon, normal, intercept, false)
		_push_polygon(builder, _clip(downstream, normal, intercept + 1.8, true))
		_push_polygon(builder, _clip(downstream, normal, intercept + 1.8, false))

static func _clip(polygon: Array[Vector3], normal: Vector2, offset: float, low: bool) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if polygon.is_empty():
		return out
	for i in polygon.size():
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		var da := normal.dot(Vector2(a.x, a.z)) - offset
		var db := normal.dot(Vector2(b.x, b.z)) - offset
		var inside_a := da <= 0.000001 if low else da >= -0.000001
		var inside_b := db <= 0.000001 if low else db >= -0.000001
		if inside_a:
			out.append(a)
		if inside_a != inside_b:
			out.append(a.lerp(b, da / (da - db)))
	return out

static func _push_polygon(builder: Geometry.Builder, polygon: Array[Vector3]) -> void:
	if polygon.size() < 3:
		return
	for i in polygon.size():
		polygon[i].y += _lift(polygon[i])
	for i in range(1, polygon.size() - 1):
		_push_land(builder, polygon[0], polygon[i], polygon[i + 1])

static func _lift(p: Vector3) -> float:
	var shoulder := 1.0 - smoothstep(30.0, 54.0, absf(p.x - 104.0))
	var rear := smoothstep(-425.0, -397.0, p.z)
	var drop := 1.0 - smoothstep(0.0, 1.8, p.z - lip_z(p.x))
	# Fill the valley to a common terrace level; do not raise both hills into
	# symmetrical dam wings. The terrace disappears where existing slopes rise.
	var terrace := _crest_height + (-352.0 - p.z) * 0.07
	return maxf(terrace - p.y, 0.0) * shoulder * rear * drop

static func shelf_raise(x: float, z: float) -> float:
	mountains()
	return _lift(Vector3(x, _sample(Vector2(x, z), _raw_vertices, _raw_bins), z))

static func _push_land(builder: Geometry.Builder, a: Vector3, b: Vector3, c: Vector3) -> void:
	var start := builder.verts.size()
	Geometry.push_triangle(builder, a, b, c, Color.WHITE)
	if builder.verts.size() == start:
		return
	var p := (a + b + c) / 3.0
	var distance := maxf(absf(p.x), absf(p.z))
	var steepness := 1.0 - builder.normals[start].y
	var base := Color(0.30, 0.45, 0.18).lerp(Color(0.35, 0.47, 0.57), smoothstep(143, 280, distance))
	base = base.lerp(Color(0.60, 0.70, 0.82), smoothstep(300, 780, distance) * 0.65)
	var rock_amount := smoothstep(0.10, 0.52, steepness) * smoothstep(140, 250, distance)
	var rock := Color(0.32, 0.37, 0.41).lerp(Color(0.57, 0.65, 0.76), smoothstep(260, 760, distance))
	var color := base.lerp(rock, rock_amount * 0.86)
	var wet := exp(-pow((p.x - 104.0) / 42.0, 2.0)) * exp(-pow((p.z + 351.0) / 26.0, 2.0))
	color = color.lerp(Color(0.23, 0.29, 0.33), wet * smoothstep(0.30, 0.75, steepness) * 0.80)
	var snow := smoothstep(155, 250, p.y) * smoothstep(335, 480, distance)
	color = color.lerp(Color(0.76, 0.82, 0.88), snow * 0.72)
	for vertex in 3:
		builder.colors[start + vertex] = color

static func _index(vertices: PackedVector3Array) -> Dictionary:
	var result: Dictionary = {}
	for i in range(0, vertices.size(), 3):
		var a := vertices[i]
		var b := vertices[i + 1]
		var c := vertices[i + 2]
		var lo := Vector2i(floori(minf(a.x, minf(b.x, c.x)) / BIN_SIZE), floori(minf(a.z, minf(b.z, c.z)) / BIN_SIZE))
		var hi := Vector2i(floori(maxf(a.x, maxf(b.x, c.x)) / BIN_SIZE), floori(maxf(a.z, maxf(b.z, c.z)) / BIN_SIZE))
		for bx in range(lo.x, hi.x + 1):
			for bz in range(lo.y, hi.y + 1):
				var key := Vector2i(bx, bz)
				if not result.has(key):
					result[key] = []
				result[key].append(i)
	return result

static func sample_height(x: float, z: float) -> float:
	if _mesh == null:
		mountains()
	if _bins.is_empty():
		_bins = _index(_vertices)
	var point := Vector2(x, z)
	if _samples.has(point):
		return _samples[point]
	var y := _sample(point, _vertices, _bins)
	_samples[point] = y
	return y

static func _sample(point: Vector2, vertices: PackedVector3Array, bins: Dictionary) -> float:
	var key := Vector2i(floori(point.x / BIN_SIZE), floori(point.y / BIN_SIZE))
	var highest := -INF
	for first in bins.get(key, []):
		var a := vertices[first]
		var b := vertices[first + 1]
		var c := vertices[first + 2]
		var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(denominator) < 0.000001:
			continue
		var wa := ((b.z - c.z) * (point.x - c.x) + (c.x - b.x) * (point.y - c.z)) / denominator
		var wb := ((c.z - a.z) * (point.x - c.x) + (a.x - c.x) * (point.y - c.z)) / denominator
		var wc := 1.0 - wa - wb
		if minf(wa, minf(wb, wc)) >= -0.00001:
			highest = maxf(highest, wa * a.y + wb * b.y + wc * c.y)
	return highest if is_finite(highest) else height(point.x, point.y)
