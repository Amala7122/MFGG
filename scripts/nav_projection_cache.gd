extends RefCounted
## 导航投影共享缓存（A 方案：压「之后」那一层的每体每帧投影）。
##
## `map_get_closest_point` / `map_get_closest_point_owner` 都是**纯函数**（地图 + 位置 → 结果），
## 但在 256 体下实测约 80 µs/次，而每个个体每帧各调一次 —— 这就是几十毫秒的来源。
##
## 做法：位置按格量化成键跨帧跨个体复用，**命中时还要校验缓存点与本次查询点的距离**，
## 超过容差就重新查询并覆盖。输入容差不保证投影输出误差：断开的导航面边界
## 可能发生最近面跳变（I-089）；本轮只优化地图有效性，最近点复用判据保持原样。
##
## 地图版本（map_get_iteration_id）一变整表作废，因此不会拿到过期地形。
## 随时可用 enabled = false 完全关掉，行为与直接用 NavigationServer3D 完全一致。

## 位置量化格边长（米）。
const CELL := 0.5
## 自身位置投影的容差（米）。追击者 4 m/s、每帧走 0.067 米，0.3 米容差约合 4~5 帧复用一次。
const CLOSEST_TOLERANCE := 0.3
## 表上限；超过就整表清空，避免长时间运行无界增长。
const LIMIT := 120000

static var enabled := true
static var hits := 0
static var misses := 0
static var owner_hits := 0
static var owner_misses := 0
static var exact_hits := 0
static var exact_misses := 0
static var _map := RID()
static var _iteration := -1
static var _closest: Dictionary = {}
static var _owner: Dictionary = {}
static var _exact: Dictionary = {}
static var _exact_frame := -1

static func reset_counters() -> void:
	hits = 0
	misses = 0
	owner_hits = 0
	owner_misses = 0
	exact_hits = 0
	exact_misses = 0

static func _cell(point: Vector3) -> Vector3i:
	return Vector3i(int(floorf(point.x / CELL)), int(floorf(point.y / CELL)), int(floorf(point.z / CELL)))

## 地图换了就整表作废。返回地图是否可用于查询。
static func _fresh(map: RID) -> bool:
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	if map != _map or iteration != _iteration:
		_map = map
		_iteration = iteration
		_closest.clear()
		_exact.clear()
	return iteration > 0

static func closest(map: RID, point: Vector3) -> Vector3:
	if not enabled or not map.is_valid() or not _fresh(map):
		return NavigationServer3D.map_get_closest_point(map, point)
	var key := _cell(point)
	var cached: Variant = _closest.get(key)
	if cached is Array and (cached[0] as Vector3).distance_to(point) <= CLOSEST_TOLERANCE:
		hits += 1
		return cached[1]
	misses += 1
	var result := NavigationServer3D.map_get_closest_point(map, point)
	if _closest.size() >= LIMIT:
		_closest.clear()
	_closest[key] = [point, result]
	return result

## 精度敏感的高度／连通判定：只共享本物理帧完全相同的查询点。
## 不走0.3m容差缓存；断开导航面的边界、移动及地图同步仍返回原生精确结果。
static func closest_exact(map: RID, point: Vector3) -> Vector3:
	if not enabled or not map.is_valid() or not _fresh(map):
		return NavigationServer3D.map_get_closest_point(map, point)
	var frame := Engine.get_physics_frames()
	if frame != _exact_frame:
		_exact_frame = frame
		_exact.clear()
	if _exact.has(point):
		exact_hits += 1
		return _exact[point]
	exact_misses += 1
	var result := NavigationServer3D.map_get_closest_point(map, point)
	if _exact.size() >= LIMIT:
		_exact.clear()
	_exact[point] = result
	return result

static func owner_valid(map: RID, point: Vector3) -> bool:
	if not map.is_valid():
		return false
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	if iteration == 0:
		return false
	if not enabled:
		return NavigationServer3D.map_get_closest_point_owner(map, point).is_valid()
	# 最近面所属 RID 是否有效只说明地图存在导航面，并非 point 在面内。
	# 空地图的 false 也可复用；区域开关/网格修改同步后 iteration 会变化。
	var cached: Variant = _owner.get(map)
	if cached is Array and int(cached[0]) == iteration:
		hits += 1
		owner_hits += 1
		return bool(cached[1])
	misses += 1
	owner_misses += 1
	var result := NavigationServer3D.map_get_closest_point_owner(map, point).is_valid()
	if _owner.size() >= LIMIT:
		_owner.clear()
	_owner[map] = [iteration, result]
	return result
