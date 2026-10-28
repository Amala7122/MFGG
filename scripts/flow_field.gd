class_name FlowField
extends RefCounted
## 共享流场：以玩家格为源做一次 BFS，所有炮灰只读自己所在格的方向。
## 网格是整张地图一次性烘焙的可行走 mask；流场重建只做 BFS。
## BFS 可以放到 WorkerThreadPool，主线程只交换结果，玩家移动时不再占主线程。
## 只负责“往哪走”，近身战术、攻击、站位仍由敌人自己的控制器决定。

const Terrain := preload("res://scripts/terrain_field.gd")

const CELL_SIZE := 2.0
const WALL_MARGIN := 1.4
const WALL_PENALTY := 4.0
const MAX_SLOPE_COS := 0.70710678
const DIRECTIONS := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

var _mask: PackedByteArray = PackedByteArray()
var _mask_n := 0
var _mask_origin := Vector2.ZERO
var _mask_ready := false
var _mask_provider = null
var _mask_profile = null
var mask_build_usec := 0

var _distance: PackedFloat32Array = PackedFloat32Array()
var _n := 0
var _origin := Vector2.ZERO
var _height_provider = null
var _height_profile = null
var _step_height := INF
var _edge_step := INF
var target_position := Vector3.ZERO
var tracking_player := true
var rebuild_usec := 0
var reachable_cells := 0
var last_error := ""

# 后台重建状态：worker 只写这些字段，主线程在任务完成后统一搬进 _distance。
var _task_id := -1
var _worker_center := Vector3.ZERO
var _worker_result: Dictionary = {}
var _pending_center := Vector3.ZERO
var _has_pending := false


func _ensure_mask() -> void:
	if _mask_ready and _mask_provider == _height_provider and _mask_profile == _height_profile:
		return
	_mask_provider = _height_provider
	_mask_profile = _height_profile
	var started := Time.get_ticks_usec()
	var half := Terrain.get_extent()
	if _height_provider != null and _height_provider.get("half_extent") != null:
		half = float(_height_provider.half_extent)
	_mask_n = int(round(half * 2.0 / CELL_SIZE)) + 1
	_mask_origin = Vector2(-half, -half)
	_mask.resize(_mask_n * _mask_n)
	var ignore := _height_profile != null and bool(_height_profile.ignore_terrain)
	var step_limit := INF
	if _height_profile != null and not ignore:
		step_limit = float(_height_profile.step_height)
	var direct := _height_provider != null and _height_provider.get("heights") != null \
		and _height_provider.get("terrain_heights") != null and bool(_height_provider.get("ready"))
	if direct:
		var source_heights: PackedFloat32Array = _height_provider.heights
		var source_terrain: PackedFloat32Array = _height_provider.terrain_heights
		var source_hits: PackedByteArray = _height_provider.hits
		var source_n := int(_height_provider.n)
		var source_cell := float(_height_provider.cell_size)
		var source_origin: Vector2 = _height_provider.origin
		for iz in _mask_n:
			for ix in _mask_n:
				var x := _mask_origin.x + float(ix) * CELL_SIZE
				var z := _mask_origin.y + float(iz) * CELL_SIZE
				var sx := clampi(int(round((x - source_origin.x) / source_cell)), 0, source_n - 1)
				var sz := clampi(int(round((z - source_origin.y) / source_cell)), 0, source_n - 1)
				var source_index := sz * source_n + sx
				var walkable := true
				if not ignore:
					if _height_provider.get("blocked") != null:
						var source_blocked: PackedByteArray = _height_provider.blocked
						walkable = source_blocked[source_index] == 0
					else:
						walkable = source_hits[source_index] != 0 \
							and source_heights[source_index] - source_terrain[source_index] <= step_limit + 0.001
				_mask[iz * _mask_n + ix] = 1 if walkable else 0
	else:
		for iz in _mask_n:
			for ix in _mask_n:
				var x := _mask_origin.x + float(ix) * CELL_SIZE
				var z := _mask_origin.y + float(iz) * CELL_SIZE
				var walkable := true
				if not ignore:
					if _height_provider != null and _height_provider.has_method("hit_at") \
							and not bool(_height_provider.hit_at(x, z)):
						walkable = false
					elif _height_provider != null and _height_provider.has_method("height_at"):
						var surface := float(_height_provider.height_at(x, z))
						if surface - Terrain.height_at(x, z) > step_limit + 0.001:
							walkable = false
					else:
						walkable = Terrain.normal_at(x, z).y >= MAX_SLOPE_COS
				_mask[iz * _mask_n + ix] = 1 if walkable else 0
	_mask_ready = true
	mask_build_usec = Time.get_ticks_usec() - started


## 同步重建：仅用于首帧/测试；运行时应走 request_rebuild + poll_rebuild。
func set_height_provider(provider, step_height: float) -> void:
	_height_provider = provider
	_height_profile = null
	_step_height = step_height
	_edge_step = step_height
	_mask_ready = false


func set_height_profile(provider, profile) -> void:
	_height_provider = provider
	_height_profile = profile
	_step_height = profile.flow_edge_limit(CELL_SIZE)
	_edge_step = profile.step_height
	_mask_ready = false


func rebuild(center: Vector3) -> void:
	_ensure_mask()
	_apply(_compute(center))


## 请求后台重建；如果已有任务在跑，只记录最新目标，完成后接着算。
func request_rebuild(center: Vector3) -> void:
	_ensure_mask()
	if _task_id >= 0:
		_pending_center = center
		_has_pending = true
		return
	_worker_center = center
	_task_id = WorkerThreadPool.add_task(Callable(self, "_worker_run"), true, "flow_field_rebuild")


## 主线程轮询；返回 true 表示刚交换了一份新流场。
func poll_rebuild() -> bool:
	if _task_id < 0:
		if _has_pending:
			_has_pending = false
			request_rebuild(_pending_center)
		return false
	if not WorkerThreadPool.is_task_completed(_task_id):
		return false
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_apply(_worker_result)
	if _has_pending:
		_has_pending = false
		request_rebuild(_pending_center)
	return true


func _worker_run() -> void:
	_worker_result = _compute(_worker_center)


func _compute(center: Vector3) -> Dictionary:
	var started := Time.get_ticks_usec()
	var n := _mask_n
	var origin := _mask_origin
	var total := n * n
	var distance := PackedFloat32Array()
	distance.resize(total)
	distance.fill(1.0e20)
	var start := _cell_at(center.x, center.z, n, origin)
	var source := start
	var tracking := true
	if source < 0 or _mask[source] == 0 or _cell_is_high(source):
		source = _nearest_ground_cell(start, n)
		tracking = false
	if source < 0:
		return {"distance": distance, "n": n, "origin": origin, "reachable": 0,
			"usec": Time.get_ticks_usec() - started, "error": "outside",
			"target": center, "tracking": false}
	var queue: Array[int] = []
	distance[source] = 0.0
	_heap_push(queue, distance, source)
	var reached := 1
	var source_ix: int = source % n
	var source_iz: int = int(source / n)
	var anchor := Vector3(origin.x + float(source_ix) * CELL_SIZE,
		_height_at_world(origin.x + float(source_ix) * CELL_SIZE,
			origin.y + float(source_iz) * CELL_SIZE),
		origin.y + float(source_iz) * CELL_SIZE)
	var goal := center if tracking else anchor
	while not queue.is_empty():
		var index := _heap_pop(queue, distance)
		if index < 0:
			break
		var ix: int = index % n
		var iz: int = int(index / n)
		var current_distance := distance[index]
		for direction: Vector2i in DIRECTIONS:
			var nx: int = ix + direction.x
			var nz: int = iz + direction.y
			if nx < 0 or nz < 0 or nx >= n or nz >= n:
				continue
			var neighbor: int = nz * n + nx
			if _mask[neighbor] == 0:
				continue
			if direction.x != 0 and direction.y != 0:
				if _mask[iz * n + nx] == 0 or _mask[nz * n + ix] == 0:
					continue
			if not _edge_allowed(ix, iz, nx, nz):
				continue
			var step := 1.41421356 if direction.x != 0 and direction.y != 0 else 1.0
			var penalty := _wall_penalty(nx, nz)
			var candidate := current_distance + step * (1.0 + penalty)
			if candidate + 0.0001 < distance[neighbor]:
				if distance[neighbor] >= 1.0e19:
					reached += 1
				distance[neighbor] = candidate
				_heap_push(queue, distance, neighbor)
	return {"distance": distance, "n": n, "origin": origin, "reachable": reached,
		"usec": Time.get_ticks_usec() - started, "error": "",
		"target": goal, "tracking": tracking}


func _wall_penalty(nx: int, nz: int) -> float:
	if _height_provider == null or _height_profile == null \
			or bool(_height_profile.ignore_terrain):
		return 0.0
	if not _height_provider.has_method("clearance_at"):
		return 0.0
	var x := _mask_origin.x + float(nx) * CELL_SIZE
	var z := _mask_origin.y + float(nz) * CELL_SIZE
	var clearance := float(_height_provider.clearance_at(x, z))
	if clearance >= WALL_MARGIN:
		return 0.0
	var normalized := (WALL_MARGIN - clearance) / WALL_MARGIN
	return WALL_PENALTY * normalized * normalized


func _heap_push(heap: Array[int], priorities: PackedFloat32Array, index: int) -> void:
	heap.append(index)
	var child := heap.size() - 1
	while child > 0:
		var parent := (child - 1) / 2
		if priorities[heap[parent]] <= priorities[heap[child]]:
			break
		var swap := heap[parent]
		heap[parent] = heap[child]
		heap[child] = swap
		child = parent


func _heap_pop(heap: Array[int], priorities: PackedFloat32Array) -> int:
	if heap.is_empty():
		return -1
	var result := heap[0]
	var last: int = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var parent := 0
		while true:
			var left := parent * 2 + 1
			if left >= heap.size():
				break
			var right := left + 1
			var best := left
			if right < heap.size() and priorities[heap[right]] < priorities[heap[left]]:
				best = right
			if priorities[heap[parent]] <= priorities[heap[best]]:
				break
			var swap := heap[parent]
			heap[parent] = heap[best]
			heap[best] = swap
			parent = best
	return result


func _height_at_world(x: float, z: float) -> float:
	if _height_provider == null:
		return Terrain.height_at(x, z)
	if _height_provider.has_method("nav_height_at"):
		return float(_height_provider.nav_height_at(x, z))
	if _height_provider.has_method("height_at"):
		return float(_height_provider.height_at(x, z))
	return Terrain.height_at(x, z)


func _cell_is_high(index: int) -> bool:
	if _height_profile != null and bool(_height_profile.ignore_terrain):
		return false
	if _height_provider == null:
		return false
	var ix: int = index % _mask_n
	var iz: int = int(index / _mask_n)
	var x := _mask_origin.x + float(ix) * CELL_SIZE
	var z := _mask_origin.y + float(iz) * CELL_SIZE
	return _height_at_world(x, z) - Terrain.height_at(x, z) > _edge_step + 0.001


func _nearest_ground_cell(start: int, n: int) -> int:
	var sx := -1
	var sz := -1
	if start >= 0:
		sx = start % n
		sz = int(start / n)
	else:
		sx = int(n / 2)
		sz = int(n / 2)
	for radius in range(1, 25):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dz) != radius:
					continue
				var ix := sx + dx
				var iz := sz + dz
				if ix < 0 or iz < 0 or ix >= n or iz >= n:
					continue
				var index := iz * n + ix
				if _mask[index] != 0 and not _cell_is_high(index):
					return index
	return -1


func _edge_allowed(ix: int, iz: int, nx: int, nz: int) -> bool:
	if _height_provider == null or _height_profile == null:
		return true
	if bool(_height_profile.ignore_terrain):
		return true
	var ax := _mask_origin.x + float(ix) * CELL_SIZE
	var az := _mask_origin.y + float(iz) * CELL_SIZE
	var bx := _mask_origin.x + float(nx) * CELL_SIZE
	var bz := _mask_origin.y + float(nz) * CELL_SIZE
	var steps := maxi(2, int(ceil(Vector2(bx - ax, bz - az).length() / 0.5)))
	var previous := _height_at_world(ax, az)
	for step in range(1, steps + 1):
		var t := float(step) / float(steps)
		var height := _height_at_world(lerpf(ax, bx, t), lerpf(az, bz, t))
		if absf(height - previous) > _edge_step + 0.02:
			return false
		previous = height
	return true


func _apply(result: Dictionary) -> void:
	if result.is_empty():
		return
	_distance = result.get("distance", PackedFloat32Array())
	_n = int(result.get("n", 0))
	_origin = result.get("origin", Vector2.ZERO)
	reachable_cells = int(result.get("reachable", 0))
	rebuild_usec = int(result.get("usec", 0))
	last_error = String(result.get("error", ""))
	target_position = result.get("target", Vector3.ZERO)
	tracking_player = bool(result.get("tracking", true))


func movement_target() -> Vector3:
	return target_position


func direction_at(world: Vector3) -> Vector3:
	if _n <= 0 or _distance.is_empty():
		return Vector3.ZERO
	var index := _cell_at(world.x, world.z, _n, _origin)
	if index < 0:
		return Vector3.ZERO
	var current_distance := _distance[index]
	# 不可达格：先指向最近的可达邻格，让单位从障碍内部/边缘走出来，而不是原地朝玩家顶。
	var best := current_distance if current_distance < 1.0e19 else 1.0e20
	var best_dx := 0
	var best_dz := 0
	var ix: int = index % _n
	var iz: int = int(index / _n)
	for direction: Vector2i in DIRECTIONS:
		var nx: int = ix + direction.x
		var nz: int = iz + direction.y
		if nx < 0 or nz < 0 or nx >= _n or nz >= _n:
			continue
		var neighbor: int = nz * _n + nx
		if _distance[neighbor] >= 1.0e19:
			continue
		if not _edge_allowed(ix, iz, nx, nz):
			continue
		if direction.x != 0 and direction.y != 0:
			if _mask[iz * _n + nx] == 0 or _mask[nz * _n + ix] == 0:
				continue
		if _distance[neighbor] < best:
			best = _distance[neighbor]
			best_dx = direction.x
			best_dz = direction.y
	if best_dx == 0 and best_dz == 0:
		return Vector3.ZERO
	return Vector3(float(best_dx), 0.0, float(best_dz)).normalized()


func nearest_reachable(world: Vector3, max_radius_cells := 40) -> Vector3:
	if _n <= 0:
		return world
	var index := _cell_at(world.x, world.z, _n, _origin)
	var center_x := 0
	var center_z := 0
	if index >= 0:
		center_x = index % _n
		center_z = int(index / _n)
	else:
		center_x = int(clampf((world.x - _origin.x) / CELL_SIZE, 0.0, float(_n - 1)))
		center_z = int(clampf((world.z - _origin.y) / CELL_SIZE, 0.0, float(_n - 1)))
	for radius in range(0, max_radius_cells + 1):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if radius > 0 and absi(dx) != radius and absi(dz) != radius:
					continue
				var ix := center_x + dx
				var iz := center_z + dz
				if ix < 0 or iz < 0 or ix >= _n or iz >= _n:
					continue
				var candidate := iz * _n + ix
				if _distance[candidate] < 1.0e19:
					return Vector3(_origin.x + float(ix) * CELL_SIZE,
						_height_at_world(_origin.x + float(ix) * CELL_SIZE,
							_origin.y + float(iz) * CELL_SIZE),
						_origin.y + float(iz) * CELL_SIZE)
	return world


func is_reachable(world: Vector3) -> bool:
	if _n <= 0:
		return false
	var index := _cell_at(world.x, world.z, _n, _origin)
	return index >= 0 and _distance[index] < 1.0e19


func distance_at(world: Vector3) -> float:
	if _n <= 0:
		return -1.0
	var index := _cell_at(world.x, world.z, _n, _origin)
	return -1.0 if index < 0 else _distance[index]


func debug_cells(center: Vector3, radius: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _n <= 0 or _distance.is_empty():
		return result
	var min_x := int(floor((center.x - radius - _origin.x) / CELL_SIZE))
	var max_x := int(ceil((center.x + radius - _origin.x) / CELL_SIZE))
	var min_z := int(floor((center.z - radius - _origin.y) / CELL_SIZE))
	var max_z := int(ceil((center.z + radius - _origin.y) / CELL_SIZE))
	min_x = clampi(min_x, 0, _n - 1)
	max_x = clampi(max_x, 0, _n - 1)
	min_z = clampi(min_z, 0, _n - 1)
	max_z = clampi(max_z, 0, _n - 1)
	for iz in range(min_z, max_z + 1):
		for ix in range(min_x, max_x + 1):
			var index := iz * _n + ix
			var world := Vector3(_origin.x + float(ix) * CELL_SIZE, 0.0,
				_origin.y + float(iz) * CELL_SIZE)
			var distance := _distance[index]
			result.append({
				"world": world,
				"distance": distance,
				"direction": direction_at(world),
			})
	return result


func _cell_at(x: float, z: float, n: int, origin: Vector2) -> int:
	var ix := int(floor((x - origin.x) / CELL_SIZE))
	var iz := int(floor((z - origin.y) / CELL_SIZE))
	if ix < 0 or iz < 0 or ix >= n or iz >= n:
		return -1
	return iz * n + ix


func _nearest_walkable(index: int) -> int:
	var ix := index % _n
	var iz: int = int(index / _n)
	for radius in range(1, 6):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var nx: int = ix + dx
				var nz: int = iz + dz
				if nx < 0 or nz < 0 or nx >= _n or nz >= _n:
					continue
				if _mask[nz * _n + nx] != 0:
					return nz * _n + nx
	return -1
