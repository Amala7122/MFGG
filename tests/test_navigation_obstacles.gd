extends SceneTree
## 独立构造并旋转的碰撞场景；正式实现不能识别这些用例或坐标。
const Actor := preload("res://scripts/prototypes/navigation_test_actor.gd")
const Region := preload("res://scripts/navigation_region.gd")
const Style := preload("res://scripts/navigation_path.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
const Query := preload("res://scripts/spatial_query.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
var failed := false
var rows: Array = []
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	paused = false
	var saved := Style.settings()
	for angle: float in [0.0, 0.77]:
		for spatial: bool in [true, false]:
			for kind: String in ["wall", "corner", "tree", "rock"]:
				Style.apply({"corner_rounding": 2.0, "lane_offset": 1.0, "goal_replan_distance": 0.8})
				await _case(kind, angle, spatial)
	for spatial: bool in [true, false]: await _moving_goal(spatial)
	await _blocked_hint()
	await _contact_margin()
	await _disconnected()
	Style.apply(saved)
	var file := FileAccess.open(Paths.ensure_dir("reports").path_join("navigation_obstacles.json"), FileAccess.WRITE)
	if file == null:
		_check(false, "无法保存验收报告")
	else:
		file.store_string(JSON.stringify(rows, "\t"))
	print("[通用障碍导航] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _stage(angle: float) -> Node3D:
	var stage := Node3D.new()
	stage.position = Vector3(130, 0, 80)
	stage.rotation.y = angle
	root.add_child(stage)
	current_scene = stage
	return stage

func _box(host: Node3D, at: Vector3, size: Vector3, rotation_y := 0.0) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	_solid(host, at, shape, rotation_y)

func _solid(host: Node3D, at: Vector3, shape: Shape3D, rotation_y := 0.0) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.rotation.y = rotation_y
	body.collision_layer = 1
	body.add_to_group("nav_source")
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	host.add_child(body)

func _navigation(stage: Node3D) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	region.set_script(Region)
	stage.add_child(region)
	for frame in range(1200):
		if region.is_baked() and NavigationServer3D.map_get_closest_point_owner(region.get_navigation_map(), stage.global_position) == region.get_rid(): break
		await process_frame
	_check(region.is_baked(), "必须完成真实碰撞烘焙")
	return region

func _actor(stage: Node3D, at: Vector3, goal: Vector3, spatial: bool, radius := 0.52) -> CharacterBody3D:
	var target := Node3D.new()
	target.position = goal + Vector3.UP * 0.06
	stage.add_child(target)
	var body := Actor.new()
	body.position = at + Vector3.UP * 1.05
	body.collision_layer = 4
	body.collision_mask = 1
	body.target = target
	body.spatial_enabled = spatial
	body.set_meta("navigation_identity", 1)
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = 2
	collision.shape = shape
	body.add_child(collision)
	stage.add_child(body)
	return body

func _case(kind: String, angle: float, spatial: bool) -> void:
	var stage := _stage(angle)
	_box(stage, Vector3(0, -0.5, 0), Vector3(40, 1, 34))
	var start := Vector3(-7, 0, 0)
	var goal := Vector3(7, 0, 0)
	match kind:
		"wall": _box(stage, Vector3(0, 1.5, 0), Vector3(0.8, 3, 10))
		"corner":
			_box(stage, Vector3(0, 1.5, 0), Vector3(0.8, 3, 10))
			_box(stage, Vector3(-4, 1.5, -5), Vector3(8, 3, 0.8))
			start = Vector3(-2, 0, -3)
			goal = Vector3(5, 0, -7)
		"tree":
			var shape := CylinderShape3D.new()
			shape.radius = 1.1
			shape.height = 5
			_solid(stage, Vector3(0, 2.5, 0), shape)
		"rock":
			var shape := SphereShape3D.new()
			shape.radius = 2
			_solid(stage, Vector3(0, 1.5, 0), shape)
	await _navigation(stage)
	var actor := _actor(stage, start, goal, spatial)
	var frame_count := 0
	for frame in range(1800):
		await physics_frame
		frame_count = frame
		if actor.reached: break
	_check(actor.reached, "%s angle=%.2f spatial=%s 未到达：%s" % [kind, angle, spatial, actor.snapshot()])
	if not actor.reached:
		Query.debug = true
		var support := Query.support(actor.target, false)
		print("[失败通道] ", kind, " / ", angle, " / ", spatial, " path=", NavigationServer3D.map_get_path(stage.get_world_3d().navigation_map, actor.global_position, actor.target.global_position, true))
		print("[失败步行] ", actor.steering.spatial._walking(actor.global_position, Query.body_on_floor(actor, support)))
		Query.debug = false
	_check(actor.steering.path_requests < 24, "固定目标不应持续重建同一路径")
	_check(actor.travelled > 1.0, "测量体必须实际运行，不能在暂停状态等待帧数")
	rows.append({"kind": kind, "rotation": angle, "spatial": spatial, "frames": frame_count, "actor": actor.snapshot()})
	print("[通用障碍导航] ", kind, " / ", angle, " / ", spatial, " frames=", frame_count, " reached=", actor.reached)
	current_scene = null
	stage.free()
	await physics_frame

func _moving_goal(spatial: bool) -> void:
	var stage := _stage(-0.37)
	_box(stage, Vector3(0, -0.5, 0), Vector3(40, 1, 34))
	_box(stage, Vector3(0, 1.5, 0), Vector3(0.8, 3, 10))
	await _navigation(stage)
	# 另一种身体尺寸；目标跨越障碍后再次移动，验证缓存能刷新。
	var actor := _actor(stage, Vector3(-7, 0, 0), Vector3(7, 0, 0), spatial, 0.9)
	for frame in range(900):
		await physics_frame
		if actor.reached: break
	_check(actor.reached, "较宽身体必须绕过墙体")
	actor.target.position = Vector3(-7, 0.06, 6)
	actor.reached = false
	for frame in range(900):
		await physics_frame
		if actor.reached: break
	_check(actor.reached, "目标改变后必须继续追踪")
	if not spatial: _check(actor.steering.path_requests >= 2 and actor.steering.path_requests < 12, "移动目标应刷新路径，固定段应复用")
	rows.append({"kind": "moving_goal", "spatial": spatial, "radius": 0.9, "actor": actor.snapshot()})
	current_scene = null
	stage.free()
	await physics_frame

func _blocked_hint() -> void:
	var stage := _stage(0.52)
	_box(stage, Vector3(0, -0.5, 0), Vector3(40, 1, 34))
	_box(stage, Vector3(0, 1.5, 0), Vector3(0.8, 3, 10))
	await _navigation(stage)
	var actor := _actor(stage, Vector3(-3, 0, 0), Vector3(7, 0, 0), true)
	actor.running = false
	for frame in range(2): await physics_frame
	var control: RefCounted = actor.steering.spatial
	var landing := Query.body_on_floor(actor, Query.support(actor.target, false))
	# 模拟几何变化后留下的旧路点：它会撞墙，移动链必须自行脱困 / 重算。
	var walking := {"kind": "walk", "points": PackedVector3Array([actor.global_position, stage.to_global(Vector3(0, 1.045, 0)), landing]), "landing": landing, "cost": 2.0}
	control.route = {"segments": [walking], "goal": landing, "cost": 2.0}
	control._route_target = actor.target
	control._goal_sample = actor.target.global_position
	control._revision = Destruction.geometry_revision
	control._nav_revision = NavigationServer3D.map_get_iteration_id(stage.get_world_3d().navigation_map)
	control._timer = 60.0
	actor.running = true
	for frame in range(1200):
		await physics_frame
		if actor.reached: break
	_check(actor.reached, "受阻旧路点必须恢复，不能永久停在墙后")
	_check(control.recovery_count > 0, "受阻测量必须实际触发脱困分支")
	rows.append({"kind": "blocked_hint", "actor": actor.snapshot()})
	current_scene = null
	stage.free()
	await physics_frame

func _disconnected() -> void:
	var stage := _stage(0.41)
	_box(stage, Vector3(-10, -0.5, 0), Vector3(12, 1, 20))
	_box(stage, Vector3(10, -0.5, 0), Vector3(12, 1, 20))
	await _navigation(stage)
	var actor := _actor(stage, Vector3(-8, 0, 0), Vector3(8, 0, 0), true)
	for frame in range(600): await physics_frame
	var local := stage.to_local(actor.global_position)
	_check(not actor.reached and local.x < -4.0 and local.y > 0.9, "断路必须保留不可达结果，不能掉下去或穿过空隙")
	_check(actor.stationary_time > 1.0, "断路检查必须实际运行移动逻辑")
	rows.append({"kind": "disconnected", "actor": actor.snapshot()})
	current_scene = null
	stage.free()
	await physics_frame

func _contact_margin() -> void:
	var stage := _stage(0.0)
	_box(stage, Vector3(0, -0.5, 0), Vector3(40, 1, 34))
	_box(stage, Vector3(0, 1.5, 0), Vector3(0.8, 3, 10))
	var actor := _actor(stage, Vector3(-0.9215, 0, 0), Vector3(-3, 0, 0), true)
	actor.running = false
	await physics_frame
	var pose := actor.global_transform
	var away := Query.motion_clear(actor, pose, Vector3.LEFT * 0.4)
	var inward := Query.motion_clear(actor, pose, Vector3.RIGHT * 0.4)
	_check(away and not inward, "只有查询余量接触时可以离墙，向墙内走必须拒绝")
	pose.origin = stage.to_global(Vector3(-0.90, 1.05, 0))
	_check(not Query.motion_clear(actor, pose, Vector3.LEFT * 0.4), "真实身体穿透不能借扫掠忽略")
	rows.append({"kind": "contact_margin", "away": away, "inward": inward})
	current_scene = null
	stage.free()
	await physics_frame

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[通用障碍导航] " + message)
