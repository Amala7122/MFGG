extends SceneTree
## APS 回退链的真实几何守卫（移植文档第 4.4、11 节）。
## 覆盖：全候选被拒 -> 逐点等于基准点；弧形被接受 -> 命中缩幅档；整条终检失败 -> 回到基准路径。
const Shape := preload("res://scripts/nav_arc_shape.gd")
const Region := preload("res://scripts/navigation_region.gd")
const Query := preload("res://scripts/spatial_query.gd")
var failed := false
var rows: Array = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	paused = false
	await _all_candidates_rejected()
	await _arc_accepted()
	await _final_gate_fallback()
	_report()
	print("[APS 形状回退] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[APS 形状回退] " + message)

func _values(overrides: Dictionary) -> Dictionary:
	var values := {"corner_rounding": 0.8, "lane_offset": 0.0, "arc_strength": 0.0, "arc_num_midpoints": 3,
		"arc_mode": "smooth", "arc_min_distance": 3.0, "arc_resample_length": 4.0, "shape_max_points": 128,
		"arc_sparse_warp": true, "shape_final_gate": true}
	for key: String in overrides:
		values[key] = overrides[key]
	return values

func _stage() -> Node3D:
	var stage := Node3D.new()
	stage.position = Vector3(220, 0, 90)
	root.add_child(stage)
	current_scene = stage
	return stage

func _box(host: Node3D, at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.collision_layer = 1
	body.add_to_group("nav_source")
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	host.add_child(body)

func _navigation(stage: Node3D, require_walkable := true) -> NavigationRegion3D:
	## require_walkable=false 允许「通道比烘焙 agent_radius 还窄 -> 导航面为空」，
	## 该状态本身是有效输入（没有导航面时不得形变）。
	var region := NavigationRegion3D.new()
	region.set_script(Region)
	stage.add_child(region)
	var map := region.get_navigation_map()
	for frame in range(1200):
		await physics_frame
		await process_frame
		if require_walkable:
			# 烘焙完成 != 导航服务器已同步；必须等地图真的包含该 region，否则查询拿不到面。
			if region.is_baked() and NavigationServer3D.map_get_closest_point_owner(map, stage.global_position) == region.get_rid():
				break
		elif frame > 60 and region.navigation_mesh != null and region.navigation_mesh.get_polygon_count() == 0:
			break
	if require_walkable:
		_check(region.is_baked(), "必须完成真实碰撞烘焙")
	else:
		_check(region.navigation_mesh != null and region.navigation_mesh.get_polygon_count() == 0,
			"窄于 agent_radius 的通道应烘出空导航面，用于验证「无导航面不得形变」")
	return region

func _body(stage: Node3D) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.collision_layer = 4
	body.collision_mask = 1
	body.floor_max_angle = deg_to_rad(46.0)
	body.position = Vector3(0, 1.045, 0)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.52
	capsule.height = 2.0
	collision.shape = capsule
	body.add_child(collision)
	stage.add_child(body)
	await physics_frame
	return body

func _base_path(body: CharacterBody3D, stage: Node3D, local_points: Array) -> PackedVector3Array:
	var points := PackedVector3Array()
	for local: Vector3 in local_points:
		var hit := Query.floor_at(body, stage.to_global(Vector3(local.x, 0.045, local.z)), 1.2)
		if hit.is_empty():
			_check(false, "基准路径点缺少真实支撑 %s" % str(local))
			continue
		points.append(Query.body_on_floor(body, hit))
	return points

func _path_is_walkable(body: CharacterBody3D, points: PackedVector3Array, safe_drop := 0.3) -> bool:
	for index in range(1, points.size()):
		if not Query.ground_segment(body, points[index - 1], points[index], safe_drop):
			return false
	return true

## 窄通道 + 超过通道宽度的弧形振幅：八个相对档全部被拒，必须逐点等于基准点。
func _all_candidates_rejected() -> void:
	var stage := _stage()
	# 内壁 ±1.0 的通道比烘焙 agent_radius(1.2) 还窄，导航面为空：APS 与移植实现
	# 都必须放弃形变，输出逐点等于基准点（LowLevelArc.cpp:2880-2883 的空守卫语义）。
	_box(stage, Vector3(0, -0.5, 0), Vector3(6, 1, 24))
	_box(stage, Vector3(1.6, 2.0, 0), Vector3(1.2, 4, 24))
	_box(stage, Vector3(-1.6, 2.0, 0), Vector3(1.2, 4, 24))
	await _navigation(stage, false)
	var body := await _body(stage)
	var base := _base_path(body, stage, [Vector3(0, 0, -8), Vector3(0, 0, -4), Vector3(0, 0, 0), Vector3(0, 0, 4), Vector3(0, 0, 8)])
	_check(base.size() == 5 and _path_is_walkable(body, base), "基准路径必须是可走的")
	var values := _values({"arc_strength": 3.0, "arc_min_distance": 0.0, "lane_offset": 0.0})
	var shaped := Shape.shape(body, stage.get_world_3d().navigation_map, base, 0.3, [], values)
	var stats := Shape.last_stats.duplicate()
	_check(shaped == base, "全部候选被拒时必须逐点等于基准点")
	_check(shaped[0].is_equal_approx(base[0]) and shaped[shaped.size() - 1].is_equal_approx(base[base.size() - 1]), "首末端点坐标不得改变")
	_check(int(stats.get("candidates", 0)) > 0, "必须真的尝试过候选：%s" % str(stats))
	_check(int(stats.get("level1_queries", 0)) > 0, "必须记录一级查询次数")
	_check((stats.get("scale_hits", {}) as Dictionary).is_empty(), "窄通道里不应命中任何缩幅档")
	rows.append({"case": "reject_all", "candidates": stats.get("candidates"), "level1": stats.get("level1_queries"),
		"level2": stats.get("level2_queries"), "scale_hits": stats.get("scale_hits"), "stage": stats.get("stage")})
	current_scene = null
	stage.free()
	await physics_frame

## 开阔地面：弧形被接受，且命中档位不能超过 1.0。
func _arc_accepted() -> void:
	var stage := _stage()
	_box(stage, Vector3(0, -0.5, 0), Vector3(40, 1, 34))
	await _navigation(stage)
	var body := await _body(stage)
	var base := _base_path(body, stage, [Vector3(0, 0, -9), Vector3(0, 0, -3), Vector3(0, 0, 3), Vector3(0, 0, 9)])
	_check(base.size() == 4, "开阔地面基准路径应完整")
	var values := _values({"arc_strength": 1.0, "arc_min_distance": 0.0})
	var shaped := Shape.shape(body, stage.get_world_3d().navigation_map, base, 0.3, [], values)
	var stats := Shape.last_stats.duplicate()
	var hits: Dictionary = stats.get("scale_hits", {})
	_check(shaped.size() >= base.size(), "弧形被接受后不应丢点")
	_check(shaped[0].is_equal_approx(base[0]) and shaped[shaped.size() - 1].is_equal_approx(base[base.size() - 1]), "首末端点坐标不得改变")
	var moved := 0
	for index in range(mini(shaped.size(), base.size())):
		if shaped[index].distance_to(base[index]) > 0.001:
			moved += 1
	_check(moved > 0, "开阔地面必须至少有一个点被形变")
	_check(not hits.is_empty(), "必须记录命中的缩幅档位：%s" % str(stats))
	for key: String in hits:
		_check(float(key) <= 1.0 + 0.0001, "命中档位不得超过 1.0：%s" % key)
	_check(_path_is_walkable(body, shaped), "形变后的路径仍必须整段可走（不得放宽身体通道）")
	rows.append({"case": "arc_accepted", "moved": moved, "candidates": stats.get("candidates"),
		"scale_hits": hits, "level1": stats.get("level1_queries"), "level2": stats.get("level2_queries"),
		"level2_segments": stats.get("level2_segments")})
	current_scene = null
	stage.free()
	await physics_frame

## 断开地面：整条终检失败 -> 连圆角一起丢弃，输出回到基准路径。
func _final_gate_fallback() -> void:
	var stage := _stage()
	_box(stage, Vector3(-8, -0.5, 0), Vector3(12, 1, 20))
	_box(stage, Vector3(8, -0.5, 0), Vector3(12, 1, 20))
	await _navigation(stage)
	var body := await _body(stage)
	var left := Query.floor_at(body, stage.to_global(Vector3(-6, 0.045, 0)), 1.2)
	var near := Query.floor_at(body, stage.to_global(Vector3(-3, 0.045, 0)), 1.2)
	var far := Query.floor_at(body, stage.to_global(Vector3(3, 0.045, 0)), 1.2)
	_check(not left.is_empty() and not near.is_empty() and not far.is_empty(), "断路两侧都必须有真实支撑")
	var base := PackedVector3Array([Query.body_on_floor(body, left), Query.body_on_floor(body, near),
		Query.body_on_floor(body, far)])
	_check(not _path_is_walkable(body, base), "基准路径必须真的跨过断路，否则本用例无效")
	var values := _values({"corner_rounding": 0.8})
	var shaped := Shape.shape(body, stage.get_world_3d().navigation_map, base, 0.3, [], values)
	var stats := Shape.last_stats.duplicate()
	_check(shaped == base, "终检失败时必须回到未加工的基准路径")
	_check(int(stats.get("final_gate_failures", 0)) == 1, "必须记录一次终检失败：%s" % str(stats))
	_check(String(stats.get("stage", "")) == "final_gate_rejected", "阶段状态应为终检拒绝：%s" % stats.get("stage"))
	rows.append({"case": "final_gate", "final_gate_failures": stats.get("final_gate_failures"), "stage": stats.get("stage")})
	current_scene = null
	stage.free()
	await physics_frame

func _report() -> void:
	var Paths := preload("res://scripts/artifact_paths.gd")
	var file := FileAccess.open(Paths.ensure_dir("reports").path_join("test_nav_shape_fallback.json"), FileAccess.WRITE)
	if file == null:
		_check(false, "无法保存回退链报告")
	else:
		file.store_string(JSON.stringify(rows, "\t"))
