extends SceneTree
## 可投影几何的存在性与查询位置无关；同步后的几何/区域修改必须使缓存失效。
const Cache := preload("res://scripts/nav_projection_cache.gd")
var failed := false
var maps: Array[RID] = []
var regions: Array[NavigationRegion3D] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	Cache.enabled = true
	_check(not Cache.owner_valid(RID(), Vector3.ZERO), "无效地图不可查询")
	var a := _stage(false)
	var b := _stage(true)
	_check(not Cache.owner_valid(maps[0], Vector3.ZERO), "未同步地图不可查询")
	await _synced(maps[0], -1, false)
	await _synced(maps[1], -1, true)
	Cache.reset_counters()
	_check(not Cache.owner_valid(maps[0], Vector3.ZERO), "已同步空地图不能当成有面")
	_check(Cache.owner_valid(maps[1], Vector3.ZERO), "有效地图可查询")
	for point: Vector3 in [Vector3(100, 50, -80), Vector3(-50, 9, 10)]:
		_check(not Cache.owner_valid(maps[0], point), "空地图在不同位置仍为空")
		_check(Cache.owner_valid(maps[1], point), "远离导航面不等于地图无面")
	_check(Cache.owner_misses == 2 and Cache.owner_hits == 4, "每个地图版本只查一次，空结果也复用")
	await _verify_exact(maps[1], maps[0])
	# 最近点缓存切换地图不能清掉另一个地图的存在性缓存。
	Cache.closest(maps[1], Vector3.ZERO)
	Cache.closest(maps[0], Vector3.ZERO)
	_check(Cache.owner_valid(maps[1], Vector3.ZERO), "切换投影地图后存在性仍有效")
	_check(Cache.owner_misses == 2, "最近点查询不强迫重新获取地图存在性")
	var version := NavigationServer3D.map_get_iteration_id(maps[0])
	var mesh := b.navigation_mesh
	a.navigation_mesh = mesh
	await _synced(maps[0], version, true)
	_check(Cache.owner_valid(maps[0], Vector3.ZERO), "新增可用导航面后重新判断")
	version = NavigationServer3D.map_get_iteration_id(maps[1])
	Cache.closest_exact(maps[1], Vector3(0.4, 0.7, 0.2))
	b.navigation_mesh = null
	await _synced(maps[1], version, false)
	_check(not Cache.owner_valid(maps[1], Vector3.ZERO), "移除最后一个几何面后缓存失效")
	_check(Cache.closest_exact(maps[1], Vector3(0.4, 0.7, 0.2)) == Vector3.ZERO,
		"移除导航面后精确缓存也按地图版本失效")
	version = NavigationServer3D.map_get_iteration_id(maps[1])
	b.navigation_mesh = mesh
	await _synced(maps[1], version, true)
	_check(Cache.owner_valid(maps[1], Vector3.ZERO), "恢复几何面后可查询")
	# 4.7.2 的最近点查询仍包含 disabled 区域，路径查询才排除它。
	version = NavigationServer3D.map_get_iteration_id(maps[1])
	b.enabled = false
	await _synced(maps[1], version, true)
	_check(Cache.owner_valid(maps[1], Vector3.ZERO), "禁用区域后保持原生最近面语义")
	_check(NavigationServer3D.map_get_path(maps[1], Vector3(-1, 0, 0), Vector3(1, 0, 0), true).is_empty(), "禁用区域不能用于路径搜索")
	version = NavigationServer3D.map_get_iteration_id(maps[1])
	b.enabled = true
	await _synced(maps[1], version, true)
	_check(Cache.owner_valid(maps[1], Vector3.ZERO), "重新启用后可查询")
	_check(NavigationServer3D.map_get_path(maps[1], Vector3(-1, 0, 0), Vector3(1, 0, 0), true).size() >= 2, "重新启用后恢复路径搜索")
	Cache.enabled = false
	_check(Cache.owner_valid(maps[1], Vector3(100, 0, 100)), "关闭缓存保持原生结果")
	Cache.enabled = true
	for region: NavigationRegion3D in regions:
		region.free()
	for map: RID in maps:
		NavigationServer3D.free_rid(map)
	print("[导航面存在性] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _verify_exact(map: RID, empty_map: RID) -> void:
	var point := Vector3(0.4, 0.7, 0.2)
	var nearby := point + Vector3.RIGHT * 0.02
	var misses: int = Cache.exact_misses
	var hits: int = Cache.exact_hits
	var expected := NavigationServer3D.map_get_closest_point(map, point)
	_check(Cache.closest_exact(map, point) == expected and Cache.closest_exact(map, point) == expected,
		"同帧相同输入共享原生精确投影")
	_check(Cache.exact_misses == misses + 1 and Cache.exact_hits == hits + 1,
		"多宿主相同查询只执行一次原生最近点搜索")
	_check(Cache.closest_exact(map, nearby) == NavigationServer3D.map_get_closest_point(map, nearby)
		and Cache.exact_misses == misses + 2, "相差2cm也不使用量化容差结果")
	await physics_frame
	Cache.closest_exact(map, point)
	_check(Cache.exact_misses == misses + 3, "下一物理帧重新查询，不复用过期位置")
	_check(Cache.closest_exact(empty_map, point) == Vector3.ZERO, "换成空地图不沿用旧地图投影")
	_check(Cache.closest_exact(map, point) == expected, "切回原地图仍返回准确投影")
	Cache.enabled = false
	misses = Cache.exact_misses
	hits = Cache.exact_hits
	_check(Cache.closest_exact(map, nearby) == NavigationServer3D.map_get_closest_point(map, nearby)
		and Cache.exact_hits == hits and Cache.exact_misses == misses, "关闭缓存直接走原生精确查询")
	Cache.enabled = true

func _stage(with_mesh: bool) -> NavigationRegion3D:
	var map := NavigationServer3D.map_create()
	NavigationServer3D.map_set_active(map, true)
	maps.append(map)
	var mesh := NavigationMesh.new()
	mesh.set_vertices(PackedVector3Array([Vector3(-2, 0, -2), Vector3(-2, 0, 2), Vector3(2, 0, 2), Vector3(2, 0, -2)]))
	mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	var region := NavigationRegion3D.new()
	if with_mesh:
		region.navigation_mesh = mesh
	root.add_child(region)
	region.set_navigation_map(map)
	regions.append(region)
	return region

func _synced(map: RID, previous: int, expected_owner: bool) -> void:
	for frame in range(120):
		await physics_frame
		var version := NavigationServer3D.map_get_iteration_id(map)
		if version > 0 and version != previous:
			# 首次地图同步先于区域几何的异步发布；等待原生结果符合舞台状态。
			# 不用待测缓存作为就绪判断，避免把空版本或中间版本当成最终状态。
			if NavigationServer3D.map_get_closest_point_owner(map, Vector3.ZERO).is_valid() == expected_owner:
				return
	_check(false, "导航修改及区域几何必须同步")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[导航面存在性] " + message)
