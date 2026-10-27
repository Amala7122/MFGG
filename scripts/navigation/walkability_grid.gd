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
var walk_heights := PackedFloat32Array()
var hits := PackedByteArray()
var blocked := PackedByteArray()
var clearance := PackedFloat32Array()
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
	walk_heights.resize(n * n)
	hits.resize(n * n)
	blocked.resize(n * n)
	clearance.resize(n * n)
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
			var walk_query := PhysicsRayQueryParameters3D.create(
				Vector3(x, terrain_heights[index] + 2.0, z),
				Vector3(x, terrain_heights[index] - 1.0, z), 1)
			var walk_hit := space.intersect_ray(walk_query)
			if walk_hit.is_empty():
				walk_heights[index] = terrain_heights[index]
			else:
				walk_heights[index] = float(walk_hit.position.y)
			blocked[index] = 1 if _body_blocked(space, x, z, terrain_heights[index]) else 0
			if hit.is_empty():
				heights[index] = terrain_heights[index]
				hits[index] = 0
			else:
				heights[index] = float(hit.position.y)
				hits[index] = 1
				hit_count += 1
	ready = true
	build_usec = Time.get_ticks_usec() - started
	_compute_clearance()


func _compute_clearance() -> void:
	clearance.resize(n * n)
	for index in n * n:
		clearance[index] = 0.0 if blocked[index] != 0 else 1.0e20
	var diagonal := 1.41421356
	for iz in range(1, n):
		for ix in range(1, n):
			var index := iz * n + ix
			if blocked[index] != 0:
				continue
			clearance[index] = minf(clearance[index], clearance[index - n - 1] + diagonal)
			clearance[index] = minf(clearance[index], clearance[index - n] + 1.0)
			clearance[index] = minf(clearance[index], clearance[index - 1] + 1.0)
	for iz in range(n - 2, -1, -1):
		for ix in range(n - 2, -1, -1):
			var index := iz * n + ix
			if blocked[index] != 0:
				continue
			clearance[index] = minf(clearance[index], clearance[index + n + 1] + diagonal)
			clearance[index] = minf(clearance[index], clearance[index + n] + 1.0)
			clearance[index] = minf(clearance[index], clearance[index + 1] + 1.0)
	for index in n * n:
		clearance[index] = minf(clearance[index], 1.0e20) * cell_size


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
			var walk_query := PhysicsRayQueryParameters3D.create(
				Vector3(x, terrain_heights[index] + 2.0, z),
				Vector3(x, terrain_heights[index] - 1.0, z), 1)
			var walk_hit := space.intersect_ray(walk_query)
			walk_heights[index] = float(walk_hit.position.y) if not walk_hit.is_empty() else terrain_heights[index]
			blocked[index] = 1 if _body_blocked(space, x, z, terrain_heights[index]) else 0
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
	_compute_clearance()
	return touched


func _body_blocked(space: PhysicsDirectSpaceState3D, x: float, z: float, terrain: float) -> bool:
	var query := PhysicsPointQueryParameters3D.new()
	query.collision_mask = 1
	query.collide_with_areas = false
	query.collide_with_bodies = true
	for offset in [Vector2.ZERO, Vector2(0.32, 0.0), Vector2(-0.32, 0.0),
			Vector2(0.0, 0.32), Vector2(0.0, -0.32)]:
		query.position = Vector3(x + offset.x, terrain + 0.9, z + offset.y)
		if not space.intersect_point(query, 1).is_empty():
			return true
	return false


func height_at(x: float, z: float) -> float:
	if not ready or n <= 0:
		return Terrain.height_at(x, z)
	var ix := clampi(int(round((x - origin.x) / cell_size)), 0, n - 1)
	var iz := clampi(int(round((z - origin.y) / cell_size)), 0, n - 1)
	return heights[iz * n + ix]


func nav_height_at(x: float, z: float) -> float:
	if not ready or n <= 0:
		return Terrain.height_at(x, z)
	var ix := clampi(int(round((x - origin.x) / cell_size)), 0, n - 1)
	var iz := clampi(int(round((z - origin.y) / cell_size)), 0, n - 1)
	return walk_heights[iz * n + ix]


func clearance_at(x: float, z: float) -> float:
	if not ready or n <= 0:
		return 100.0
	var ix := clampi(int(round((x - origin.x) / cell_size)), 0, n - 1)
	var iz := clampi(int(round((z - origin.y) / cell_size)), 0, n - 1)
	return clearance[iz * n + ix]


func blocked_at(x: float, z: float) -> bool:
	if not ready or n <= 0:
		return false
	var ix := clampi(int(round((x - origin.x) / cell_size)), 0, n - 1)
	var iz := clampi(int(round((z - origin.y) / cell_size)), 0, n - 1)
	return blocked[iz * n + ix] != 0


func nearest_open(x: float, z: float, max_radius_cells := 12) -> Vector3:
	if not ready or n <= 0:
		return Vector3(x, Terrain.height_at(x, z), z)
	var cx := clampi(int(round((x - origin.x) / cell_size)), 0, n - 1)
	var cz := clampi(int(round((z - origin.y) / cell_size)), 0, n - 1)
	for radius in range(0, max_radius_cells + 1):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if radius > 0 and absi(dx) != radius and absi(dz) != radius:
					continue
				var ix := cx + dx
				var iz := cz + dz
				if ix < 0 or iz < 0 or ix >= n or iz >= n:
					continue
				var index := iz * n + ix
				if blocked[index] == 0:
					return Vector3(origin.x + float(ix) * cell_size,
						walk_heights[index], origin.y + float(iz) * cell_size)
	return Vector3(x, nav_height_at(x, z), z)


func nearest_open_away(x: float, z: float, avoid: Vector3, max_radius_cells := 20) -> Vector3:
	if not ready or n <= 0:
		return Vector3(x, Terrain.height_at(x, z), z)
	var cx := clampi(int(round((x - origin.x) / cell_size)), 0, n - 1)
	var cz := clampi(int(round((z - origin.y) / cell_size)), 0, n - 1)
	var current_distance := Vector2(x - avoid.x, z - avoid.z).length()
	var best := Vector3(x, nav_height_at(x, z), z)
	var best_score := INF
	for radius in range(0, max_radius_cells + 1):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if radius > 0 and absi(dx) != radius and absi(dz) != radius:
					continue
				var ix := cx + dx
				var iz := cz + dz
				if ix < 0 or iz < 0 or ix >= n or iz >= n:
					continue
				var index := iz * n + ix
				if blocked[index] != 0:
					continue
				var wx := origin.x + float(ix) * cell_size
				var wz := origin.y + float(iz) * cell_size
				var distance_to_avoid := Vector2(wx - avoid.x, wz - avoid.z).length()
				if distance_to_avoid < current_distance - 0.5:
					continue
				var score := Vector2(wx - x, wz - z).length() + maxf(0.0, 2.0 - distance_to_avoid) * 2.0
				if score < best_score:
					best_score = score
					best = Vector3(wx, walk_heights[index], wz)
		if best_score < INF:
			return best
	return Vector3(x, nav_height_at(x, z), z)


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
		"walk_heights": Array(walk_heights),
		"hits": Array(hits),
		"blocked": Array(blocked),
		"clearance": Array(clearance),
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
	walk_heights.resize(n * n)
	var walk_values: Array = data.get("walk_heights", [])
	if walk_values.size() == n * n:
		for index in n * n:
			walk_heights[index] = float(walk_values[index])
	else:
		for index in n * n:
			walk_heights[index] = terrain_heights[index]
	hits.resize(n * n)
	for index in mini(hit_values.size(), n * n):
		hits[index] = int(hit_values[index])
	blocked.resize(n * n)
	var blocked_values: Array = data.get("blocked", [])
	for index in mini(blocked_values.size(), n * n):
		blocked[index] = int(blocked_values[index])
	clearance.resize(n * n)
	var clearance_values: Array = data.get("clearance", [])
	if clearance_values.size() == n * n:
		for index in n * n:
			clearance[index] = float(clearance_values[index])
	else:
		_compute_clearance()
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
