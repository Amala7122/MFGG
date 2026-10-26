class_name FlowField
extends RefCounted
## 共享流场：以玩家格为源做一次 BFS，所有炮灰只读自己所在格的方向。
## 网格是整张地图一次性烘焙的可行走 mask；流场重建只做 BFS。
## BFS 可以放到 WorkerThreadPool，主线程只交换结果，玩家移动时不再占主线程。
## 只负责“往哪走”，近身战术、攻击、站位仍由敌人自己的控制器决定。

const Terrain := preload("res://scripts/terrain_field.gd")

const CELL_SIZE := 4.0
const MAX_SLOPE_COS := 0.70710678
const DIRECTIONS := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

static var _mask: PackedByteArray = PackedByteArray()
static var _mask_n := 0
static var _mask_origin := Vector2.ZERO
static var _mask_ready := false
static var mask_build_usec := 0

var _distance: PackedInt32Array = PackedInt32Array()
var _n := 0
var _origin := Vector2.ZERO
var _height_provider = null
var _step_height := INF
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
	if _mask_ready:
		return
	var started := Time.get_ticks_usec()
	var half := Terrain.get_extent()
	_mask_n = int(round(half * 2.0 / CELL_SIZE)) + 1
	_mask_origin = Vector2(-half, -half)
	_mask.resize(_mask_n * _mask_n)
	for iz in _mask_n:
		for ix in _mask_n:
			var x := _mask_origin.x + float(ix) * CELL_SIZE
			var z := _mask_origin.y + float(iz) * CELL_SIZE
			var normal := Terrain.normal_at(x, z)
			var walkable := normal.y >= MAX_SLOPE_COS
			_mask[iz * _mask_n + ix] = 1 if walkable else 0
	_mask_ready = true
	mask_build_usec = Time.get_ticks_usec() - started


## 同步重建：仅用于首帧/测试；运行时应走 request_rebuild + poll_rebuild。
func set_height_provider(provider, step_height: float) -> void:
	_height_provider = provider
	_step_height = step_height


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
	var distance := PackedInt32Array()
	distance.resize(total)
	distance.fill(-1)
	var start := _cell_at(center.x, center.z, n, origin)
	if start < 0:
		return {"distance": distance, "n": n, "origin": origin, "reachable": 0,
			"usec": Time.get_ticks_usec() - started, "error": "outside"}
	# 玩家格即使坡度不可走也作为源头（人站在坡上），只要求邻居可走；
	# 否则源会被挪到 4–8m 外，群怪会全停在那个格上。
	var queue := PackedInt32Array()
	queue.resize(total)
	var head := 0
	var tail := 0
	queue[tail] = start
	tail += 1
	distance[start] = 0
	var reached := 1
	while head < tail:
		var index := queue[head]
		head += 1
		var ix: int = index % n
		var iz: int = int(index / n)
		var next_distance := distance[index] + 1
		var current_height := 0.0
		var height_checked := _height_provider != null
		if height_checked:
			var wx := origin.x + float(ix) * CELL_SIZE
			var wz := origin.y + float(iz) * CELL_SIZE
			current_height = _height_provider.height_at(wx, wz)
		for direction: Vector2i in DIRECTIONS:
			var nx: int = ix + direction.x
			var nz: int = iz + direction.y
			if nx < 0 or nz < 0 or nx >= n or nz >= n:
				continue
			var neighbor: int = nz * n + nx
			if _mask[neighbor] == 0 or distance[neighbor] >= 0:
				continue
			if height_checked:
				var wx2 := origin.x + float(nx) * CELL_SIZE
				var wz2 := origin.y + float(nz) * CELL_SIZE
				if absf(_height_provider.height_at(wx2, wz2) - current_height) > _step_height + 0.001:
					continue
			if direction.x != 0 and direction.y != 0:
				# 斜向必须两侧正交格都可走，避免穿墙角。
				if _mask[iz * n + nx] == 0 or _mask[nz * n + ix] == 0:
					continue
			distance[neighbor] = next_distance
			queue[tail] = neighbor
			tail += 1
			reached += 1
	return {"distance": distance, "n": n, "origin": origin, "reachable": reached,
		"usec": Time.get_ticks_usec() - started, "error": ""}


func _apply(result: Dictionary) -> void:
	if result.is_empty():
		return
	_distance = result.get("distance", PackedInt32Array())
	_n = int(result.get("n", 0))
	_origin = result.get("origin", Vector2.ZERO)
	reachable_cells = int(result.get("reachable", 0))
	rebuild_usec = int(result.get("usec", 0))
	last_error = String(result.get("error", ""))


func direction_at(world: Vector3) -> Vector3:
	if _n <= 0 or _distance.is_empty():
		return Vector3.ZERO
	var index := _cell_at(world.x, world.z, _n, _origin)
	if index < 0:
		return Vector3.ZERO
	var current_distance := _distance[index]
	# 不可达格：先指向最近的可达邻格，让单位从障碍内部/边缘走出来，而不是原地朝玩家顶。
	var best := current_distance if current_distance >= 0 else 0x3FFFFFFF
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
		if _distance[neighbor] < 0:
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
