class_name PyroluxMeshes
extends RefCounted
## Index meshes shared by every effect. Each vertex stores its element index in x and its
## corner in UV; the shaders compute the real positions, so one cached mesh per size is
## reused by all instances.

static var _cache: Dictionary = {}


## count quads (4 vertices each), UV = corner.
static func quads(count: int) -> ArrayMesh:
	return _cached("q3_%d" % count, count, 1, false)


## count ribbons of `segments` segments, UV.x = side (0..1), UV.y = along (0..1).
static func strips(count: int, segments: int) -> ArrayMesh:
	return _cached("s3_%d_%d" % [count, segments], count, segments, false)


static func quads_2d(count: int) -> ArrayMesh:
	return _cached("q2_%d" % count, count, 1, true)


static func strips_2d(count: int, segments: int) -> ArrayMesh:
	return _cached("s2_%d_%d" % [count, segments], count, segments, true)


## Quads placed on surface samples of a mesh. VERTEX = sample position (mesh space),
## NORMAL = surface normal, UV = corner, UV2.x = element index. Not cached.
static func surface_quads(points: PackedVector3Array, normals: PackedVector3Array) -> ArrayMesh:
	var count: int = points.size()
	var mesh: ArrayMesh = ArrayMesh.new()
	if count == 0:
		return mesh
	var v: PackedVector3Array = PackedVector3Array()
	var n: PackedVector3Array = PackedVector3Array()
	var uv: PackedVector2Array = PackedVector2Array()
	var uv2: PackedVector2Array = PackedVector2Array()
	var idx: PackedInt32Array = PackedInt32Array()
	v.resize(count * 4)
	n.resize(count * 4)
	uv.resize(count * 4)
	uv2.resize(count * 4)
	idx.resize(count * 6)
	var corners: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]
	for i in count:
		for c in 4:
			var j: int = i * 4 + c
			v[j] = points[i]
			n[j] = normals[i]
			uv[j] = corners[c]
			uv2[j] = Vector2(float(i), 0.0)
		var b: int = i * 4
		idx[i * 6] = b
		idx[i * 6 + 1] = b + 1
		idx[i * 6 + 2] = b + 3
		idx[i * 6 + 3] = b
		idx[i * 6 + 4] = b + 3
		idx[i * 6 + 5] = b + 2
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Random points on the surface of `mesh`, weighted by triangle area.
static func sample_surface(mesh: Mesh, count: int, seed: int) -> Array[PackedVector3Array]:
	var pts: PackedVector3Array = PackedVector3Array()
	var nrm: PackedVector3Array = PackedVector3Array()
	var tris: PackedVector3Array = PackedVector3Array()
	if mesh == null:
		return [pts, nrm]
	for s in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var ind: PackedInt32Array = PackedInt32Array()
		if arr[Mesh.ARRAY_INDEX] != null:
			ind = arr[Mesh.ARRAY_INDEX]
		if ind.is_empty():
			for i in verts.size():
				tris.append(verts[i])
		else:
			for i in ind:
				tris.append(verts[i])
	var tri_count: int = int(tris.size() / 3.0)
	if tri_count == 0:
		return [pts, nrm]
	var cdf: PackedFloat32Array = PackedFloat32Array()
	cdf.resize(tri_count)
	var total: float = 0.0
	for t in tri_count:
		var a: Vector3 = tris[t * 3]
		total += (tris[t * 3 + 1] - a).cross(tris[t * 3 + 2] - a).length() * 0.5
		cdf[t] = total
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	for i in count:
		var r: float = rng.randf() * total
		var lo: int = 0
		var hi: int = tri_count - 1
		while lo < hi:
			var mid: int = (lo + hi) >> 1
			if cdf[mid] < r:
				lo = mid + 1
			else:
				hi = mid
		var a: Vector3 = tris[lo * 3]
		var b: Vector3 = tris[lo * 3 + 1]
		var c: Vector3 = tris[lo * 3 + 2]
		var u: float = rng.randf()
		var w: float = rng.randf()
		if u + w > 1.0:
			u = 1.0 - u
			w = 1.0 - w
		pts.append(a + (b - a) * u + (c - a) * w)
		var nn: Vector3 = (b - a).cross(c - a)
		nrm.append(nn.normalized() if nn.length_squared() > 0.0 else Vector3.UP)
	return [pts, nrm]


static func _cached(key: String, count: int, segments: int, flat: bool) -> ArrayMesh:
	if _cache.has(key):
		return _cache[key]
	var mesh: ArrayMesh = _build(count, segments, flat)
	_cache[key] = mesh
	return mesh


static func _build(count: int, segments: int, flat: bool) -> ArrayMesh:
	count = maxi(count, 1)
	var per: int = (segments + 1) * 2
	var n: int = count * per
	var uvs: PackedVector2Array = PackedVector2Array()
	uvs.resize(n)
	var idx: PackedInt32Array = PackedInt32Array()
	idx.resize(count * segments * 6)
	var v3: PackedVector3Array = PackedVector3Array()
	var v2: PackedVector2Array = PackedVector2Array()
	if flat:
		v2.resize(n)
	else:
		v3.resize(n)
	var k: int = 0
	for i in count:
		var b: int = i * per
		var fi: float = float(i)
		for s in segments + 1:
			var along: float = float(s) / float(segments)
			var j: int = b + s * 2
			uvs[j] = Vector2(0.0, along)
			uvs[j + 1] = Vector2(1.0, along)
			if flat:
				v2[j] = Vector2(fi, 0.0)
				v2[j + 1] = Vector2(fi, 1.0)
			else:
				v3[j] = Vector3(fi, 0.0, 0.0)
				v3[j + 1] = Vector3(fi, 1.0, 0.0)
		for s in segments:
			var j: int = b + s * 2
			idx[k] = j
			idx[k + 1] = j + 1
			idx[k + 2] = j + 3
			idx[k + 3] = j
			idx[k + 4] = j + 3
			idx[k + 5] = j + 2
			k += 6
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	if flat:
		arrays[Mesh.ARRAY_VERTEX] = v2
	else:
		arrays[Mesh.ARRAY_VERTEX] = v3
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh: ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
