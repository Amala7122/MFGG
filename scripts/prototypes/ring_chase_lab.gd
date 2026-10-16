extends Node3D
## 精确追击观察台（保留原场景路径，单环目标模型已退役）。
##
## 所有追击者直接规划到移动标记的位置；没有环目标、接战或战斗链路。
## 默认进入标记 1.5 m 内且在同层才近距回收，60 m 外掉队回收。
## 诊断可显式使用旧组的 31.5 m 回收距离做同负载对照；回收事件不是路径成功率。
##
## 地图与正式主场景完全相同：实例化 [hyrule_field.tscn]，摘掉战斗入口，等 NavRegion
## 运行时烘焙并同步。追击者复用正式 NavSteering 的路径跟随，不复制另一套寻路。
##
## 两条硬规则：
##   1. 近距回收与掉队回收分开记录，卡住不回收。
##   2. **停滞可见且可数**。判据是 0.6 秒窗口的净位移（与正式 NavSteering 的脱困判据一致），
##      不是逐帧位移——贴墙抖动的人逐帧都在动，但人眼看到的就是站着不动。
##
## 相机是正俯视，所以所有指示标记都画在**水平面**里：竖直的杆从上往下投影只是一个点。
##
## 操作：W/A/S/D 移动标记（Shift 冲刺）、F 重置视角。
const Main := preload("res://scenes/hyrule_field.tscn")
const Actor := preload("res://scripts/prototypes/ring_chase_actor.gd")
const Query := preload("res://scripts/spatial_query.gd")

## 追击者数量。固定值，不做面板。
const COUNT := 256
## 生成/重生的固定种子，保证同一套起点可复现。
const SEED := 64768
## 固定压力投放和回收距离（米）；不参与导航选点。
const SPAWN_MIN_DISTANCE := 32.0
const SPAWN_MAX_DISTANCE := 48.0
const DROP_DISTANCE := 60.0
## 停滞累计到多久算一次「卡住」并记录原因（秒）。取 1.2 秒＝两个 0.6 秒窗口。
const STALL_COUNT_SECONDS := 1.2
## 标记移动速度（米/秒）与冲刺倍率。
const MARKER_SPEED := 12.0
const MARKER_SPRINT := 1.7
## 正交俯视相机的视野跨度（米）与高度。相机跟随标记。
const CAMERA_SIZE := 130.0
const CAMERA_HEIGHT := 160.0
## 目标点重算间隔（物理帧）：错峰执行，避免单帧堆叠选点开销。
const GOAL_REFRESH_FRAMES := 15
## 追击者碰撞胶囊（也是可见模型的尺寸）。
const BODY_RADIUS := 0.52
const BODY_HEIGHT := 2.0

var world: Node3D
var camera: Camera3D
var marker: Node3D
var actors: Array[CharacterBody3D] = []
var ready_for_test := false
## 探针接管标记位置时为 true：本台不再读键盘。
var probe_driven := false
## 默认接近精确目标才回收；只由诊断命令改变，不做运行面板参数。
var recycle_near_distance := 1.5
var rng := RandomNumberGenerator.new()
var entered := 0
var dropped := 0
var unreachable := 0
## 停滞统计（只统计，不销毁）：卡住次数、停滞窗口数与原因分布。
var stall_events := 0
var stalled_windows := 0
var stall_reasons := {}
var _seen_windows: Array[int] = []
var elapsed := 0.0
var _draw: MeshInstance3D
var _status: Label
var _last_enter_time := 0.0

func _ready() -> void:
	call_deferred("_build")

func _build() -> void:
	rng.seed = SEED
	world = Main.instantiate()
	world.name = "MainSceneGeometry"
	for entry in ["Enemies", "Players", "PlayerSpawner", "WeatherEnvironment", "Grass"]:
		var node := world.get_node_or_null(entry)
		if node != null:
			node.free()
	add_child(world)
	for frame in range(8):
		await get_tree().process_frame
	var region := world.get_node("NavRegion")
	while not region.is_baked():
		await get_tree().process_frame
	await get_tree().physics_frame
	var navigation_map := get_world_3d().navigation_map
	# 烘焙完成先于异步服务器同步；等真实可查询面，不用固定帧数猜。
	for frame in range(1200):
		if NavigationServer3D.map_get_closest_point_owner(navigation_map, Vector3.ZERO).is_valid():
			break
		await get_tree().physics_frame
	if not NavigationServer3D.map_get_closest_point_owner(navigation_map, Vector3.ZERO).is_valid():
		push_error("精确追击观察台：烘焙后仍没有同步的导航区域")
		return
	_build_view()
	marker = Node3D.new()
	marker.name = "ChaseTarget"
	add_child(marker)
	var centre := _surface(NavigationServer3D.map_get_closest_point(navigation_map, Vector3(0, 0, 13)))
	marker.global_position = centre if not centre.is_zero_approx() else Vector3(0, 1, 0)
	_spawn_all()
	ready_for_test = true

func _build_view() -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 1200.0
	add_child(camera)
	camera.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-65, -25, 0)
	sun.light_energy = 1.4
	add_child(sun)
	var env := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.07, 0.10, 0.12)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color.WHITE
	settings.ambient_light_energy = 0.7
	env.environment = settings
	add_child(env)
	_draw = MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	_draw.material_override = material
	_draw.mesh = ImmediateMesh.new()
	add_child(_draw)
	_status = Label.new()
	_status.position = Vector2(10, 8)
	_status.add_theme_font_size_override("font_size", 12)
	add_child(_status)
	reset_camera()

func reset_camera() -> void:
	var centre: Vector3 = marker.global_position if is_instance_valid(marker) else Vector3.ZERO
	camera.size = CAMERA_SIZE
	camera.position = Vector3(centre.x, CAMERA_HEIGHT, centre.z)
	camera.look_at(Vector3(camera.position.x, 0.0, camera.position.z), Vector3.FORWARD)

## 相机跟随标记：正交俯视只平移，方向保持竖直向下。
func _follow_camera(centre: Vector3) -> void:
	if is_instance_valid(camera):
		camera.position = Vector3(centre.x, CAMERA_HEIGHT, centre.z)

## 投放一个追击者，并把地面点换算成**身体原点**高度
## （胶囊中心在 origin，直接把地面点当 origin 会让身体半埋进地里）。
func _spawn_one(actor: CharacterBody3D) -> bool:
	var navigation_map := get_world_3d().navigation_map
	var lift := float(Query.dimensions(actor).half_height) + 0.05
	for attempt in range(60):
		var angle := rng.randf_range(0.0, TAU)
		var distance := rng.randf_range(SPAWN_MIN_DISTANCE, SPAWN_MAX_DISTANCE)
		var wanted: Vector3 = marker.global_position + Vector3(cos(angle), 0.0, sin(angle)) * distance
		var ground := _surface(NavigationServer3D.map_get_closest_point(navigation_map, wanted))
		if ground.is_zero_approx():
			continue
		var offset := ground - marker.global_position
		offset.y = 0.0
		if offset.length() <= recycle_near_distance:
			continue
		# 只在**与目标连通**的地方投放：孤岛上的追击者永远走不到目标，表现为永久站住
		# （实测 256 体时停滞原因 100% 是 path_finished，个体累计只走了 2 米）。
		if not _connected_to_target(ground, navigation_map):
			continue
		actor.place_at(ground + Vector3.UP * lift)
		return true
	return false

## 从这个候选点能不能真的走到目标附近：部分路径的终点不算连通。
func _connected_to_target(point: Vector3, navigation_map: RID) -> bool:
	var target := NavigationServer3D.map_get_closest_point(navigation_map, marker.global_position)
	var path := NavigationServer3D.map_get_path(navigation_map, point, target, true)
	if path.size() < 2:
		return false
	return Vector2(path[path.size() - 1].x - target.x,
		path[path.size() - 1].z - target.z).length() <= 2.0

func _spawn_all() -> void:
	for index in range(COUNT):
		var actor := _make_actor(index)
		actors.append(actor)
		_seen_windows.append(0)
		if not _spawn_one(actor):
			unreachable += 1

func _make_actor(index: int) -> CharacterBody3D:
	var actor: CharacterBody3D = Actor.new()
	actor.name = "Chaser%02d" % index
	actor.collision_layer = 4
	actor.collision_mask = 1
	actor.floor_max_angle = deg_to_rad(46.0)
	actor.speed = 4.0
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_HEIGHT
	collision.shape = capsule
	actor.add_child(collision)
	# 可见模型：没有它场上什么都看不到（只有轨迹线，会被误认为敌人本体）。
	var visual := MeshInstance3D.new()
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = BODY_RADIUS
	body_mesh.height = BODY_HEIGHT
	visual.mesh = body_mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.62, 0.18)
	visual.material_override = material
	actor.add_child(visual)
	add_child(actor)
	return actor

func _physics_process(delta: float) -> void:
	if not ready_for_test or not is_instance_valid(marker):
		return
	elapsed += delta
	if not probe_driven:
		_move_marker(delta)
	var centre := marker.global_position
	_follow_camera(centre)
	var frame := Engine.get_physics_frames()
	for index in range(actors.size()):
		var actor: CharacterBody3D = actors[index]
		if not is_instance_valid(actor):
			continue
		var offset := actor.global_position - centre
		offset.y = 0.0
		var distance := offset.length()
		var same_level := absf(actor.global_position.y - BODY_HEIGHT * 0.5 - centre.y) <= 0.35
		if distance <= recycle_near_distance and (recycle_near_distance > 1.5 or same_level):
			# 默认接近标记且同层才回收；旧压力距离只供显式诊断对照。
			entered += 1
			_last_enter_time = elapsed
			if not _spawn_one(actor):
				unreachable += 1
			_refresh_goal(actor, centre, index)
			continue
		if distance > DROP_DISTANCE:
			# 掉队回收：只为了维持场上人数，单独计数，**不算进圈**。
			dropped += 1
			if not _spawn_one(actor):
				unreachable += 1
			_refresh_goal(actor, centre, index)
			continue
		# 卡住只统计与标记，**不回收**。
		# 逐窗口记录原因：0.6 秒级的短暂红圈也要有归因，否则只看到「有几个红圈」查不出为什么。
		if index < _seen_windows.size():
			if actor.stalled_windows < _seen_windows[index]:
				_seen_windows[index] = actor.stalled_windows
			elif actor.stalled_windows > _seen_windows[index]:
				_seen_windows[index] = actor.stalled_windows
				stalled_windows += 1
				var why: String = actor.stall_reason if not actor.stall_reason.is_empty() else "unknown"
				stall_reasons[why] = int(stall_reasons.get(why, 0)) + 1
				_refresh_goal(actor, centre, index)
		if actor.stationary_time >= STALL_COUNT_SECONDS and not actor.stall_counted:
			actor.stall_counted = true
			stall_events += 1
		# 目标点错峰重算：每帧只算少数几个，避免单帧堆叠选点开销。
		if (frame + index) % GOAL_REFRESH_FRAMES == 0:
			_refresh_goal(actor, centre, index)
	_draw_frame()
	_update_status()

## 所有个体都规划到标记的精确位置，保持原来的错峰刷新频率。
func _refresh_goal(actor: CharacterBody3D, centre: Vector3, _index: int) -> void:
	actor.set_goal(centre)

func _move_marker(delta: float) -> void:
	var direction := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): direction.z -= 1.0
	if Input.is_key_pressed(KEY_S): direction.z += 1.0
	if Input.is_key_pressed(KEY_A): direction.x -= 1.0
	if Input.is_key_pressed(KEY_D): direction.x += 1.0
	if Input.is_key_pressed(KEY_F): reset_camera()
	if direction.is_zero_approx():
		return
	var speed := MARKER_SPEED * (MARKER_SPRINT if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var wanted := marker.global_position + direction.normalized() * speed * delta
	var grounded := _surface(NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, wanted))
	# 前方没有可站立地面就不动：标记不会瞬移过沟，目标也不会跑到导航面外。
	if not grounded.is_zero_approx():
		marker.global_position = grounded

## 把一个点落到真实可站立地面；返回零向量表示这里不能站。
func _surface(point: Vector3) -> Vector3:
	var navigation_map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(navigation_map) == 0:
		return Vector3.ZERO
	if not NavigationServer3D.map_get_closest_point_owner(navigation_map, point).is_valid():
		return Vector3.ZERO
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * 2.5, point + Vector3.DOWN * 5.0, 1))
	if hit.is_empty() or (hit.normal as Vector3).y < 0.707:
		return Vector3.ZERO
	return (hit.position as Vector3) + Vector3.UP * 0.05

## 水平十字：正俯视下竖直的杆只是一个点，所以所有标记都画在水平面里。
func _cross(mesh: ImmediateMesh, at: Vector3, size: float, color: Color) -> void:
	mesh.surface_set_color(color)
	var lift := Vector3.UP * 0.6
	mesh.surface_add_vertex(at + Vector3(-size, 0.0, 0.0) + lift)
	mesh.surface_add_vertex(at + Vector3(size, 0.0, 0.0) + lift)
	mesh.surface_add_vertex(at + Vector3(0.0, 0.0, -size) + lift)
	mesh.surface_add_vertex(at + Vector3(0.0, 0.0, size) + lift)

func _circle(mesh: ImmediateMesh, centre: Vector3, radius: float, color: Color, segments := 16) -> void:
	mesh.surface_set_color(color)
	var previous := centre + Vector3(radius, 0.0, 0.0) + Vector3.UP * 0.6
	for index in range(1, segments + 1):
		var angle := TAU * float(index) / float(segments)
		var point := centre + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius) + Vector3.UP * 0.6
		mesh.surface_add_vertex(previous)
		mesh.surface_add_vertex(point)
		previous = point

func _draw_frame() -> void:
	# 无界面测量不做绘制：省下的时间才能反映真实物理与导航开销。
	if DisplayServer.get_name() == "headless":
		return
	var mesh := _draw.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var centre := marker.global_position
	# 精确追击目标。
	_cross(mesh, centre, 3.0, Color(1.0, 0.25, 0.25, 1.0))
	for actor: CharacterBody3D in actors:
		if not is_instance_valid(actor):
			continue
		var here: Vector3 = actor.global_position
		if actor.stalled:
			# 停滞：红色大十字 + 红圈，正俯视下一眼可见。
			_cross(mesh, here, 3.0, Color(1.0, 0.15, 0.15, 1.0))
			_circle(mesh, here, 2.0, Color(1.0, 0.15, 0.15, 0.8), 12)
		else:
			_cross(mesh, here, 1.2, Color(0.95, 0.95, 0.95, 0.85))
		if not actor.has_goal:
			continue
		# 当前目标点：橙色小十字（水平，正俯视可见）。
		_cross(mesh, actor.goal, 1.0, Color(1.0, 0.5, 0.05, 1.0))
		mesh.surface_set_color(Color(0.35, 0.85, 1.0, 0.5))
		var trail: PackedVector3Array = actor.trail
		for index in range(1, trail.size()):
			mesh.surface_add_vertex(trail[index - 1] + Vector3.UP * 0.25)
			mesh.surface_add_vertex(trail[index] + Vector3.UP * 0.25)
	mesh.surface_end()

func _update_status() -> void:
	if not is_instance_valid(_status):
		return
	var chasing := 0
	var stalled := 0
	var nearest := INF
	var farthest := 0.0
	var centre := marker.global_position
	for actor: CharacterBody3D in actors:
		if not is_instance_valid(actor):
			continue
		chasing += 1
		if actor.stalled:
			stalled += 1
		var offset := actor.global_position - centre
		offset.y = 0.0
		var distance := offset.length()
		nearest = minf(nearest, distance)
		farthest = maxf(farthest, distance)
	if nearest == INF:
		nearest = 0.0
	_status.text = "精确追击 · 追击 %d · 近距回收 %d · 掉队回收 %d · 重生失败 %d · 停滞中 %d · 停滞窗口 %d · 距离 %.0f~%.0f m · 距上次近距回收 %.1fs · 原因 %s" % [
		chasing, entered, dropped, unreachable, stalled, stalled_windows, nearest, farthest,
		maxf(elapsed - _last_enter_time, 0.0), _stall_summary()]

## 卡住原因分布，供状态栏直接读。
func _stall_summary() -> String:
	if stall_reasons.is_empty():
		return "无"
	var parts: Array[String] = []
	for key: String in stall_reasons:
		parts.append("%s=%d" % [key, int(stall_reasons[key])])
	return " ".join(parts)
