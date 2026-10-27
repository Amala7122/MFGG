class_name WalkabilityGrid
extends RefCounted
## 静态地图的烘焙表面/通行高度网格。离线生成后存盘，运行时只加载。
## 与 SurfaceGrid 的区别：这个对象可以被序列化，不再每次启动重新打射线。

const Terrain := preload("res://scripts/terrain_field.gd")
const FORMAT_VERSION := 1

var cell_size := 1.0
var half_extent := 60.0
var n := 0
var origin := Vector2.ZERO
var heights := PackedFloat32Array()
var terrain_heights := PackedFloat32Array()
var hits := PackedByteArray()
var ready := false
var build_usec := 0
var hit_count := 0


func build(world: World3D, center: Vector2, extent: float, cell := 1.0) -> void:
	cell_size = maxf(cell, 0.5)
	half_extent = extent
	n = int(round(extent * 2.0 / cell_size)) + 1
	origin = center - Vector2(extent, extent)
	heights.resize(n * n)
	terrain_heights.resize(n * n)
	hits.resize(n * n)
	var started := Time.get_ticks_usec()
	var space := world.direct_space_state
	hit_count = 0
	for iz in n:
		for ix in n:
			var x := origin.x + float(ix) * cell_size
			var z := origin.y + float(iz) * cell_size
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(x, 200.0, z), Vector3(x, -100.0, z), 1)
			var hit := space.intersect_ray(query)
			var index := iz * n + ix
			terrain_heights[index] = Terrain.height_at(x, z)
			if hit.is_empty():
				heights[index] = terrain_heights[index]
				hits[index] = 0
			else:
				heights[index] = float(hit.position.y)
				hits[index] = 1
				hit_count += 1
	ready = true
	build_usec = Time.get_ticks_usec() - started


func rebake_region(world: World3D, center: Vector2, radius: float) -> int:
	if not ready or n <= 0:
		return 0
	var min_x := clampi(int(floor((center.x - radius - origin.x) / cell_size)), 0, n - 1)
	var max_x := clampi(int(ceil((center.x + radius - origin.x) / cell_size)), 0, n - 1)
	var min_z := clampi(int(floor((center.y - radius - origin.y) / cell_size)), 0, n - 1)
	var max_z := clampi(int(ceil((center.y + radius - origin.y) / cell_size)), 0, n - 1)
	var space := world.direct_space_state
	var touched := 0
	for iz in range(min_z, max_z + 1):
		for ix in range(min_x, max_x + 1):
			var x := origin.x + float(ix) * cell_size
			var z := origin.y + float(iz) * cell_size
			var index := iz * n + ix
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(x, 200.0, z), Vector3(x, -100.0, z), 1)
			var hit := space.intersect_ray(query)
			var was_hit := hits[index] != 0
			terrain_heights[index] = Terrain.height_at(x, z)
			if hit.is_empty():
				heights[index] = terrain_heights[index]
				hits[index] = 0
				if was_hit:
					hit_count -= 1
			else:
				heights[index] = float(hit.position.y)
				hits[index] = 1
				if not was_hit:
					hit_count += 1
			touched += 1
	build_usec = 0
	return touched


func height_at(x: float, z: float) -> float:
	if not ready or n <= 0:
		return Terrain.height_at(x, z)
	var ix := clampi(int(round((x - origin.x) / cell_size)), 0, n - 1)
	var iz := clampi(int(round((z - origin.y) / cell_size)), 0, n - 1)
	return heights[iz * n + ix]


func hit_at(x: float, z: float) -> bool:
	if not ready or n <= 0:
		return false
	var ix := clampi(int(round((x - origin.x) / cell_size)), 0, n - 1)
	var iz := clampi(int(round((z - origin.y) / cell_size)), 0, n - 1)
	return hits[iz * n + ix] != 0


func to_dict() -> Dictionary:
	return {
		"format": FORMAT_VERSION,
		"cell_size": cell_size,
		"half_extent": half_extent,
		"n": n,
		"origin_x": origin.x,
		"origin_z": origin.y,
		"heights": Array(heights),
		"terrain_heights": Array(terrain_heights),
		"hits": Array(hits),
		"hit_count": hit_count,
		"build_usec": build_usec,
	}


func from_dict(data: Dictionary) -> bool:
	if int(data.get("format", 0)) != FORMAT_VERSION:
		return false
	cell_size = float(data.get("cell_size", 1.0))
	half_extent = float(data.get("half_extent", 60.0))
	n = int(data.get("n", 0))
	if n <= 0:
		return false
	origin = Vector2(float(data.get("origin_x", -half_extent)),
		float(data.get("origin_z", -half_extent)))
	var height_values: Array = data.get("heights", [])
	var hit_values: Array = data.get("hits", [])
	if height_values.size() != n * n:
		return false
	heights.resize(n * n)
	for index in n * n:
		heights[index] = float(height_values[index])
	terrain_heights.resize(n * n)
	var terrain_values: Array = data.get("terrain_heights", [])
	if terrain_values.size() == n * n:
		for index in n * n:
			terrain_heights[index] = float(terrain_values[index])
	else:
		for index in n * n:
			terrain_heights[index] = heights[index]
	hits.resize(n * n)
	for index in mini(hit_values.size(), n * n):
		hits[index] = int(hit_values[index])
	hit_count = int(data.get("hit_count", 0))
	build_usec = 0
	ready = true
	return true


func save_json(path: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(to_dict()))
	file.close()
	return true


func load_json(path: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute):
		return false
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return false
	return from_dict(parsed)
