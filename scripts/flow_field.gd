class_name FlowField
extends RefCounted
## 共享流场：以玩家格为源做一次 BFS，所有炮灰只读自己所在格的方向。
## 网格是整张地图一次性烘焙的可行走 mask；流场重建只做 BFS。
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
var rebuild_usec := 0
var reachable_cells := 0
var last_error := ""


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


func rebuild(center: Vector3) -> void:
	_ensure_mask()
	_n = _mask_n
	_origin = _mask_origin
	var started := Time.get_ticks_usec()
	var total := _n * _n
	if _distance.size() != total:
		_distance.resize(total)
	_distance.fill(-1)
	var start := _cell_at(center.x, center.z)
	if start < 0:
		last_error = "outside"
		rebuild_usec = Time.get_ticks_usec() - started
		return
	if _mask[start] == 0:
		start = _nearest_walkable(start)
		if start < 0:
			last_error = "no_walkable_near_player"
			rebuild_usec = Time.get_ticks_usec() - started
			return
	var queue := PackedInt32Array()
	queue.resize(total)
	var head := 0
	var tail := 0
	queue[tail] = start
	tail += 1
	_distance[start] = 0
	var reached := 1
	while head < tail:
		var index := queue[head]
		head += 1
		var ix: int = index % _n
		var iz: int = int(index / _n)
		var next_distance := _distance[index] + 1
		for direction: Vector2i in DIRECTIONS:
			var nx: int = ix + direction.x
			var nz: int = iz + direction.y
			if nx < 0 or nz < 0 or nx >= _n or nz >= _n:
				continue
			var neighbor: int = nz * _n + nx
			if _mask[neighbor] == 0 or _distance[neighbor] >= 0:
				continue
			if direction.x != 0 and direction.y != 0:
				# 斜向必须两侧正交格都可走，避免穿墙角。
				if _mask[iz * _n + nx] == 0 or _mask[nz * _n + ix] == 0:
					continue
			_distance[neighbor] = next_distance
			queue[tail] = neighbor
			tail += 1
			reached += 1
	reachable_cells = reached
	last_error = ""
	rebuild_usec = Time.get_ticks_usec() - started


func direction_at(world: Vector3) -> Vector3:
	if _n <= 0 or _distance.is_empty():
		return Vector3.ZERO
	var index := _cell_at(world.x, world.z)
	if index < 0 or _distance[index] < 0:
		return Vector3.ZERO
	var ix: int = index % _n
	var iz: int = int(index / _n)
	var best := _distance[index]
	var best_dx := 0
	var best_dz := 0
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


func _cell_at(x: float, z: float) -> int:
	var ix := int(floor((x - _origin.x) / CELL_SIZE))
	var iz := int(floor((z - _origin.y) / CELL_SIZE))
	if ix < 0 or iz < 0 or ix >= _n or iz >= _n:
		return -1
	return iz * _n + ix


func _nearest_walkable(index: int) -> int:
	var ix: int = index % _n
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
