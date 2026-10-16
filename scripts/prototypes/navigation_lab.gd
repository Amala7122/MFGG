extends Node3D
## 主场景几何的纯移动观察入口；与正式敌人共用 NavSteering 和空间通行。
const Main := preload("res://scenes/hyrule_field.tscn")
const Actor := preload("res://scripts/prototypes/navigation_test_actor.gd")
const Arena := preload("res://scripts/arena.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Query := preload("res://scripts/spatial_query.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
const PathStyle := preload("res://scripts/navigation_path.gd")
const Controller := preload("res://scripts/combat_spatial_controller.gd")
var world: Node3D
var camera: Camera3D
var target: Node3D
var actors: Array[CharacterBody3D] = []
var ready_for_test := false
var elapsed := 0.0
var count := 64
var seed_value := 64768
var paused_motion := false
var spatial_enabled := true
## 画线开关：路线（空间路线）与轨迹分开，避免轨迹把人看糊。
var show_routes := true
var show_trails := true
## 环参数的项目默认文件：保存后每次启动自动读回（用户可以把自己调好的圈数与半径固化）。
const RING_CONFIG_PATH := "res://data/navigation/ring_goals.json"
var _status: Label
var _list: Label
var _draw: MeshInstance3D
var _draw_timer := 0.0
var _seed: SpinBox
var _count: SpinBox
var _speed: SpinBox
var _arena_choice: OptionButton
var _generation := 0
var _dirty_label: Label
var _preset_name: LineEdit
var _rounding: SpinBox
var _lane: SpinBox
var _replan: SpinBox
var _arc_strength: SpinBox
var _arc_midpoints: SpinBox
var _arc_min_distance: SpinBox
var _arc_resample: SpinBox
var _shape_max_points: SpinBox
var _arc_mode: OptionButton
var _sparse_warp: CheckButton
var _final_gate: CheckButton
var _saved_settings: Dictionary = {}
var _message := ""
var spawn_adjustments := 0
var connected_spawns := true
var spawn_samples: Array = []
var full_area := true
var _area_toggle: CheckButton
var _spawn_probe: CharacterBody3D
## WASD 连续移动目标：观察“目标持续移动时敌人是否动态改线”，而不是点一下让整条路线重算。
var keyboard_target := true
var target_speed := 3.2
## 冲刺倍率与正式玩家一致（见任务记录里的玩家走速 5 m/s / 冲刺 ×1.7）。
const TARGET_SPRINT := 1.7
var _target_speed_spin: SpinBox
var _keyboard_toggle: CheckButton
var _keyboard_moved := false
## 启动后不自动开跑：先看清参数，点「开始」（或按空格）才开始寻路（用户 2026-10-11 要求）。
var started := false
var _ring_toggle: CheckButton
var _ring_count: SpinBox
var _ring_mode_choice: OptionButton
var _ring_level_spin: SpinBox
var _spawn_ring_spin: SpinBox
var _throttle_from: SpinBox
var _throttle_step: SpinBox
var _throttle_max: SpinBox
## 只在第 N 环之外投放（0 = 不限）：用来观察远处敌人到底寻路到圈内还是到玩家。
var spawn_outside_ring := 0
## 观测：因不满足「第 N 环之外」被剔除的候选点数。
var spawn_rejected_inside := 0
## 逐环半径输入框（最多 8 环，按当前圈数显示前 N 个）。
var _ring_radius_spins: Array[SpinBox] = []
var _ring_radius_rows: Array[HBoxContainer] = []
var _ring_span_label: Label
const MAX_RINGS := 8
## 中键拖动平移中。
var _panning := false
## 2D 圈号标注（每环一个很小的数字，叠在画面上、不挡 3D 观察）。
var _ring_markers: Array[Label] = []
var _ring_marker_layer: CanvasLayer
## 场景内提示（操作说明）。
## 轨迹只画最近这么多点（观测用；256 体时全画会拖慢画面）。
const TRAIL_DRAW_POINTS := 60
const HINT_TEXT := "空格=开始寻路 · 左键=设目标 · 右键=加测量体 · 中键拖动=平移地图 · 滚轮=缩放 · R=重新投放 · F=重置视角"

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_load_ring_defaults()
	_build_ui()
	await rebuild_world()

func rebuild_world() -> void:
	ready_for_test = false
	_generation += 1
	var generation := _generation
	clear_actors()
	if is_instance_valid(world):
		world.free()
	world = Main.instantiate()
	world.name = "MainSceneGeometry"
	# 在进树前移除所有战斗入口，因此不会先触发一次投放或玩家生命周期。
	for entry in ["Enemies", "Players", "PlayerSpawner", "WeatherEnvironment", "Grass"]:
		var node := world.get_node_or_null(entry)
		if node != null:
			node.free()
	add_child(world)
	for frame in range(8):
		await get_tree().process_frame
		if generation != _generation: return
	var region := world.get_node("NavRegion")
	while not region.is_baked():
		await get_tree().process_frame
		if generation != _generation: return
	await get_tree().physics_frame
	var navigation_map := get_world_3d().navigation_map
	# 烘焙完成先于异步服务器同步；等真实可查询面，不能以固定帧数猜测。
	for frame in range(1200):
		if NavigationServer3D.map_get_closest_point_owner(navigation_map, Vector3.ZERO).is_valid():
			break
		await get_tree().physics_frame
		if generation != _generation: return
	if not NavigationServer3D.map_get_closest_point_owner(navigation_map, Vector3.ZERO).is_valid():
		print("[导航同步] world=", navigation_map, " region=", region.get_navigation_map(), " active=", NavigationServer3D.map_is_active(navigation_map), " iteration=", NavigationServer3D.map_get_iteration_id(navigation_map), " regions=", NavigationServer3D.map_get_regions(navigation_map), " enabled=", region.enabled, " bounds=", NavigationServer3D.region_get_bounds(region.get_rid()), " layers=", region.navigation_layers, " closest=", NavigationServer3D.map_get_closest_point(navigation_map, Vector3(30, 0, 0)), " vertex=", region.navigation_mesh.get_vertices()[0])
		push_error("导航观察台：烘焙后仍没有同步的导航区域")
		return
	if not is_instance_valid(camera):
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
		settings.background_color = Color(0.08, 0.11, 0.13)
		settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		settings.ambient_light_color = Color.WHITE
		settings.ambient_light_energy = 0.65
		env.environment = settings
		add_child(env)
		_draw = MeshInstance3D.new()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		material.no_depth_test = true
		_draw.material_override = material
		add_child(_draw)
		_draw.mesh = ImmediateMesh.new()
		_create_target()
	reset_camera()
	target.position = _marker_position(NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, Vector3(0, 0, 13)))
	ready_for_test = true
	replay()

func _create_target() -> void:
	target = Node3D.new()
	target.name = "MoveTarget"
	add_child(target)
	var mesh := MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.8
	ring.outer_radius = 1.05
	mesh.mesh = ring
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1, 0.85, 0.18)
	material.no_depth_test = true
	mesh.material_override = material
	target.add_child(mesh)

## 开始寻路：把已经投放的测量体放行。启动时默认为「未开始」。
func start_run() -> void:
	if not ready_for_test:
		return
	started = true
	paused_motion = false
	for actor in actors:
		actor.running = true
	_message = "已开始寻路（%d 个体）" % actors.size()


func clear_actors() -> void:
	for actor in actors:
		if is_instance_valid(actor):
			actor.free()
	actors.clear()

func replay() -> void:
	if not ready_for_test:
		return
	Controller.reset_ring_goals()
	clear_actors()
	elapsed = 0.0
	spawn_adjustments = 0
	spawn_rejected_inside = 0
	spawn_samples.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var extent := Terrain.get_extent()
	var map := get_world_3d().navigation_map
	for i in range(count):
		var angle := TAU * float(i) / count + rng.randf_range(-0.12, 0.12)
		var requested := Vector3(cos(angle), 0, sin(angle)) * extent * rng.randf_range(0.38, 0.68)
		if full_area:
			var columns := ceili(sqrt(float(count)))
			var rows := ceili(float(count) / columns)
			requested = Vector3(-extent + extent * 2.0 * (float(i % columns) + rng.randf_range(0.3, 0.7)) / columns, 0,
				-extent + extent * 2.0 * (float(i / columns) + rng.randf_range(0.3, 0.7)) / rows)
		var floor_point := _connected_spawn(requested)
		if floor_point.is_empty():
			_message = "有采样点不连通，未投放；请另选目标"
			continue
		spawn_actor(floor_point.point, i)
	_message = "投放 %d/%d · 重采样 %d · 环外剔除 %d · 失败 %d" % [actors.size(), count, spawn_adjustments, spawn_rejected_inside, count - actors.size()] if spawn_adjustments > 0 or spawn_rejected_inside > 0 or actors.size() < count else ""
	if spawn_outside_ring > 0:
		_message += "（只投放在第 %d 环之外）" % spawn_outside_ring

## 重新投放（reset）：目标回到初始点、测量体按同种子重新投放、环状态与统计清零。
## 观察台里最容易找不到的就是这个动作，所以同时给了 R 键和面板最上方的按钮。
func reset_all() -> void:
	if not ready_for_test:
		return
	paused_motion = false
	started = false
	keyboard_target = true
	if is_instance_valid(_keyboard_toggle):
		_keyboard_toggle.set_pressed_no_signal(true)
	_keyboard_moved = false
	if is_instance_valid(target):
		var map := get_world_3d().navigation_map
		target.position = _marker_position(NavigationServer3D.map_get_closest_point(map, Vector3(0, 0, 13)))
	replay()
	_message = "已重新投放：目标回到初始点，测量体按种子 %d 重新生成；点「开始」才寻路" % seed_value


## 重置视角：正交俯视、以初始中心框住整张地图。
func reset_camera() -> void:
	if not is_instance_valid(camera):
		return
	var extent := Terrain.get_extent()
	camera.position = Vector3(-extent * 0.16, 350, 0)
	camera.look_at(Vector3(-extent * 0.16, 0, 0), Vector3.FORWARD)
	camera.size = extent * 2.25


## 中键拖动平移。相机是正交俯视且以 FORWARD 为 up：屏幕右=+X、屏幕上=−Z，
## 所以「抓着地图拖」就是把相机往反方向挪。
func _pan_camera(relative: Vector2) -> void:
	if not is_instance_valid(camera):
		return
	var viewport_height := maxf(get_viewport().get_visible_rect().size.y, 1.0)
	var per_pixel := camera.size / viewport_height
	camera.position += Vector3(-relative.x * per_pixel, 0.0, -relative.y * per_pixel)


func _marker_position(point: Vector3) -> Vector3:
	var hit := Query.floor_at(self, point, 1.5)
	return (hit.position as Vector3) + Vector3.UP * 0.06 if not hit.is_empty() else point

func _connected_spawn(requested: Vector3) -> Dictionary:
	if not is_instance_valid(_spawn_probe):
		_spawn_probe = CharacterBody3D.new()
		_spawn_probe.collision_layer = 0
		_spawn_probe.collision_mask = 0
		var collision := CollisionShape3D.new()
		collision.shape = _actor_shape()
		_spawn_probe.add_child(collision)
		add_child(_spawn_probe)
	var map := get_world_3d().navigation_map
	var end := NavigationServer3D.map_get_closest_point(map, target.position)
	for ring in range(4):
		for index in range(1 if ring == 0 else 8):
			var angle := TAU * index / 8.0
			var candidate := requested + Vector3(cos(angle), 0, sin(angle)) * ring * 2.0
			var point := NavigationServer3D.map_get_closest_point(map, candidate)
			var hit := Query.floor_at(_spawn_probe, point, 1.5)
			if hit.is_empty() or not Query.full_support(_spawn_probe, hit): continue
			var pose := _spawn_probe.global_transform
			pose.origin = Query.ground_pose(_spawn_probe, hit)
			if not Query.motion_clear(_spawn_probe, pose, Vector3.ZERO): continue
			if not _spawn_outside_ok(point):
				spawn_rejected_inside += 1
				continue
			var path := NavigationServer3D.map_get_path(map, point, end, true)
			var connected := not path.is_empty() and path[path.size() - 1].distance_to(end) < 0.5
			if connected or not connected_spawns:
				if ring > 0: spawn_adjustments += 1
				spawn_samples.append({"requested": [requested.x, requested.y, requested.z], "chosen": [point.x, point.y, point.z], "connected": connected, "resampled": ring > 0})
				return {"point": point}
	spawn_samples.append({"requested": [requested.x, requested.y, requested.z], "connected": false, "skipped": true})
	return {}

## 「只投放在第 N 环之外」：按该环自己的圆心与半径判断（环还没建时退回目标当前位置）。
func _spawn_outside_ok(point: Vector3) -> bool:
	if spawn_outside_ring <= 0:
		return true
	var radii := Controller.ring_radii
	if radii.is_empty() or not is_instance_valid(target):
		return true
	var index := clampi(spawn_outside_ring - 1, 0, radii.size() - 1)
	var centre := target.position
	var rows := Controller.ring_debug_rows(target)
	if index < rows.size():
		var anchor: Vector3 = rows[index]["anchor"]
		if not anchor.is_zero_approx():
			centre = anchor
	return Vector2(point.x - centre.x, point.z - centre.z).length() > radii[index]


func _actor_shape() -> CapsuleShape3D:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.52
	shape.height = 2.0
	return shape

func spawn_actor(floor_point: Vector3, index: int) -> CharacterBody3D:
	var actor := Actor.new()
	actor.name = "N%02d" % (index + 1)
	actor.position = floor_point + Vector3.UP * 1.1
	actor.collision_layer = 4
	actor.collision_mask = 1
	actor.target = target
	actor.speed = _speed.value if _speed != null else 4.0
	actor.spatial_enabled = spatial_enabled
	actor.set_meta("navigation_identity", index)
	actor.running = started and not paused_motion
	var collision := CollisionShape3D.new()
	collision.shape = _actor_shape()
	actor.add_child(collision)
	var visual := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.52
	mesh.height = 2.0
	visual.mesh = mesh
	var color := Color.from_hsv(float(index % 24) / 24.0, 0.65, 1.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	visual.material_override = material
	actor.set_meta("nav_color", color)
	actor.add_child(visual)
	add_child(actor)
	# 体素面不是实际地面；与正式投放一样把身体放到真实支撑上，避免初始嵌地。
	var support := Query.floor_at(actor, floor_point, 1.5)
	if not support.is_empty(): actor.position = Query.ground_pose(actor, support)
	actors.append(actor)
	return actor

## WASD 连续控制目标。相机是正交俯视且 look_at 以 FORWARD 为 up（见 rebuild_world），
## 因此屏幕方向就是世界方向：W = -Z，S = +Z，A = -X，D = +X。Shift 冲刺 ×1.7。
func _physics_process(delta: float) -> void:
	if not ready_for_test or not started or not keyboard_target or paused_motion or not is_instance_valid(target):
		return
	var direction := _target_input()
	if direction.is_zero_approx():
		return
	_advance_target(direction, delta)

func _target_input() -> Vector2:
	var direction := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		direction.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		direction.y += 1.0
	if Input.is_key_pressed(KEY_A):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		direction.x += 1.0
	return direction.normalized() if direction.length() > 0.0 else Vector2.ZERO

func _advance_target(direction: Vector2, delta: float) -> void:
	var speed := target_speed * (TARGET_SPRINT if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var wanted: Vector3 = target.position + Vector3(direction.x, 0.0, direction.y) * speed * delta
	var extent := Terrain.get_extent() * 0.95
	wanted.x = clampf(wanted.x, -extent, extent)
	wanted.z = clampf(wanted.z, -extent, extent)
	var grounded := _marker_position(wanted)
	# 前方没有可站立地面时不移动：目标不能瞬移过沟或被吸附到远处台面。
	if Vector2(grounded.x - wanted.x, grounded.z - wanted.z).length() > 1.0:
		return
	target.position = grounded
	_keyboard_moved = true
	for actor in actors:
		actor.reached = false

func _process(delta: float) -> void:
	if not ready_for_test:
		return
	if started and not paused_motion:
		elapsed += delta
	_draw_timer -= delta
	if _draw_timer > 0:
		return
	_draw_timer = 0.2
	var reached := 0
	var stuck := 0
	var lines := PackedStringArray()
	for actor in actors:
		if actor.reached:
			reached += 1
		if actor.stationary_time > 2.0:
			stuck += 1
		var state: Dictionary = actor.snapshot()
		var names := {"approach": "行走", "checking": "算路", "recovering": "脱困", "blocked": "无路线", "relocate": "入口等待", "unsafe_drop": "边界保护", "trapped": "无安全出口"}
		# 档位与圈号一起报：追击者说「几号体在几号圈」时不用再猜。
		var spatial_state: RefCounted = actor.steering.spatial
		var band := int(spatial_state._plan_band)
		var band_text := "已进%s" % _ring_glyph(1) if band <= 0 else "奔向%s" % _ring_glyph(band)
		var gap := Vector2(actor.global_position.x - target.position.x, actor.global_position.z - target.position.z).length()
		lines.append("%s %s %s 停%.1fs 距%.0fm" % [actor.name, band_text,
			"已到达" if actor.reached else names.get(state.status, state.status), actor.stationary_time, gap])
	var stats: Dictionary = PathStyle.stage_stats()
	var hits: Dictionary = stats.get("scale_hits", {})
	_status.text = "%.1fs  到达 %d/%d  停滞 %d\n目标 (%.1f, %.1f) · %s\n右键增加测量体 · 滚轮缩放\n蓝：基础网格路径  绿：成形路径  彩色：实际轨迹\n成形候选 %d · 一级 %d · 二级 %d · 缩幅命中 %s · 终检失败 %d\n目标 %.1f m/s（Shift ×%.1f）%s\n%s\n%s" % [
		elapsed, reached, actors.size(), stuck, target.position.x, target.position.z,
		"%s · %s" % ["未开始（点开始 / 空格）" if not started else ("已暂停" if paused_motion else "运行中"),
			"WASD 连续控制中" if keyboard_target else "左键点击设置"],
		int(stats.get("candidates", 0)), int(stats.get("level1_queries", 0)), int(stats.get("level2_queries", 0)),
		str(hits), int(stats.get("final_gate_failures", 0)),
		target_speed, TARGET_SPRINT, " · 已用键盘移动过" if _keyboard_moved else "",
		ring_legend(), _message]
	_list.text = "\n".join(lines)
	redraw_paths()
	_update_ring_labels()

func redraw_paths() -> void:
	var mesh := _draw.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if actors.is_empty():
		return
	if not show_routes and not show_trails and not Controller.ring_goal_enabled:
		return
	# 三段路线：基础网格路径（成形前） / 成形路径 / 实际轨迹，分开观察形状流水线做了什么。
	var routes: Array[PackedVector3Array] = []
	var bases: Array[PackedVector3Array] = []
	var goals: Array[Vector3] = []
	var any_lines := Controller.ring_goal_enabled and is_instance_valid(target)
	for actor in actors:
		var spatial: RefCounted = actor.steering.spatial
		var path := PackedVector3Array()
		var base := PackedVector3Array()
		if not spatial.route.is_empty() and spatial._segment_index < spatial.route.segments.size():
			var segment: Dictionary = spatial.route.segments[spatial._segment_index]
			path = segment.get("points", PackedVector3Array())
			base = segment.get("base", PackedVector3Array())
		elif not actor.spatial_enabled:
			# 只有纯 NavSteering 模式才画 Agent 自己的路径。空间决策开启时不画：Agent 的目标
			# 永远是玩家，画出来会让人误以为「没进环的追击者也在连玩家」。
			path = actor.steering._agent.get_current_navigation_path()
		routes.append(path)
		bases.append(base)
		goals.append(spatial._goal_sample)
		any_lines = any_lines or (show_routes and (path.size() > 1 or base.size() > 1)) or (show_trails and actor.trail.size() > 1)
	# 大数量默认少画：路线仍然全画（要看的就是它），轨迹由上面的 TRAIL_DRAW_POINTS 限长。
	if not any_lines:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(actors.size()):
		var actor := actors[i]
		if show_routes:
			_draw_lines(mesh, bases[i], Color(0.25, 0.65, 1.0))
			_draw_lines(mesh, routes[i], Color(0.35, 1.0, 0.45))
		if show_trails:
			# 每个测量体的轨迹最多画最近 TRAIL_DRAW_POINTS 个点：256 体 × 600 点每 0.2 秒重传
			# 十几万条线段，画面上不卡才怪；看路径形状几十个点足够。
			var trail: PackedVector3Array = actor.trail
			if trail.size() > TRAIL_DRAW_POINTS:
				trail = trail.slice(trail.size() - TRAIL_DRAW_POINTS)
			_draw_lines(mesh, trail, actor.get_meta("nav_color"))
		# 当前规划用的目标点：一小段竖线，直接看得到它落在哪条环带里。
		if not goals[i].is_zero_approx():
			mesh.surface_set_color(Color(1.0, 0.35, 0.2, 0.95))
			mesh.surface_add_vertex(goals[i] + Vector3.UP * 0.4)
			mesh.surface_add_vertex(goals[i] + Vector3.UP * 3.4)
	if Controller.ring_goal_enabled and is_instance_valid(target):
		_draw_rings(mesh)
		# 目标轨迹（环带候选只从这里挑）：黄=轨迹点，白线=轨迹连线。
		var state: RefCounted = Controller.ring_state(target)
		if state != null and state.trail.size() > 1:
			mesh.surface_set_color(Color(1.0, 0.9, 0.35, 0.9))
			for point: Vector3 in state.trail:
				mesh.surface_add_vertex(point + Vector3.UP * 0.6)
				mesh.surface_add_vertex(point + Vector3.UP * 1.6)
			_draw_lines(mesh, PackedVector3Array(state.trail), Color(1.0, 0.75, 0.2, 0.5))
	mesh.surface_end()


const RING_GLYPHS: Array[String] = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧"]
## 每环标注放在各自圆周上的不同方位，避免几张标签叠在目标点上、数字看不清。
const RING_LABEL_ANGLES: Array[float] = [205.0, 145.0, 65.0, 335.0, 250.0, 110.0, 20.0, 300.0]


func _ring_glyph(ring: int) -> String:
	return RING_GLYPHS[clampi(ring - 1, 0, RING_GLYPHS.size() - 1)]


func _ring_color(ring: int) -> Color:
	if ring <= 1:
		return Color(1.0, 0.85, 0.18, 0.8)
	return Color(1.0, 0.4, 0.35, 0.7).lerp(Color(0.35, 0.8, 1.0, 0.7), clampf(float(ring - 2) / 3.0, 0.0, 1.0))


## 圈号图例：场景里只画一个很小的数字，半径 / 拖动阈值 / 已拖动次数放在这里。
func ring_legend() -> String:
	if not Controller.ring_goal_enabled:
		return "环目标 关"
	if not is_instance_valid(target):
		return "环目标 开"
	var rows := Controller.ring_debug_rows(target)
	if rows.is_empty():
		return "环目标 开 · 尚未建立环"
	var parts := PackedStringArray()
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		var ring := int(row["ring"])
		var radius := float(row["radius"])
		if ring <= 1:
			parts.append("%s%.0fm精确带" % [_ring_glyph(ring), radius])
		else:
			parts.append("%s%.0fm(阈%.0f,拖%d)" % [_ring_glyph(ring), radius,
				radius - float(rows[index - 1]["radius"]), int(row["drags"])])
	return "环目标 开 · 拖动 %d 换环 %d\n计划用环 %d · 层级挡回 %d · 内环精确 %d\n%s" % [
		Controller.ring_drag_events, Controller.ring_switch_events,
		Controller.ring_used, Controller.ring_level_blocked, Controller.ring_precise_zone, " ".join(parts)] + "\n降频：完整 %d 帧 · 便宜 %d 帧（间隔上限 %d）" % [
		Controller.full_ticks, Controller.throttled_ticks, Controller.tick_throttle_max]


## 圈号用 2D 叠层（把世界坐标投影到屏幕）：字号是确定的屏幕像素，不受 3D 尺寸影响，
## 也不会像 Label3D 那样随正交相机的距离算错大小、挡住画面。
func _ensure_ring_markers() -> void:
	if is_instance_valid(_ring_marker_layer):
		return
	_ring_marker_layer = CanvasLayer.new()
	_ring_marker_layer.layer = 1
	add_child(_ring_marker_layer)
	for index in range(8):
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		label.add_theme_constant_override("outline_size", 4)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.visible = false
		_ring_marker_layer.add_child(label)
		_ring_markers.append(label)


func _update_ring_labels() -> void:
	_ensure_ring_markers()
	for label in _ring_markers:
		label.visible = false
	if not (Controller.ring_goal_enabled and ready_for_test and is_instance_valid(target)):
		return
	if not is_instance_valid(camera):
		return
	var rows := Controller.ring_debug_rows(target)
	for index in range(mini(rows.size(), _ring_markers.size())):
		var row: Dictionary = rows[index]
		var ring := int(row["ring"])
		var radius := float(row["radius"])
		var centre: Vector3 = row["anchor"]
		if centre.is_zero_approx():
			centre = target.position
		var angle := deg_to_rad(RING_LABEL_ANGLES[(ring - 1) % RING_LABEL_ANGLES.size()])
		var world := centre + Vector3(cos(angle), 0.0, sin(angle)) * (radius * 0.85)
		var label := _ring_markers[index]
		label.text = _ring_glyph(ring)
		label.add_theme_color_override("font_color", _ring_color(ring))
		label.position = camera.unproject_position(world) + Vector2(-5.0, -9.0)
		label.visible = true


## 同心环：每环画成一个圆（半径 R_k），圆心是它自己的 A_k。第 1 环贴在目标身上。
## 目标小范围移动时外圈圆心不动，这张图能直接看出拖动发生在哪一环。
func _draw_rings(mesh: ImmediateMesh) -> void:
	var rows := Controller.ring_debug_rows(target)
	if rows.is_empty():
		mesh.surface_set_color(Color(1.0, 0.85, 0.18, 0.55))
		_draw_ring(mesh, target.position, Controller.ring_radii[0] if not Controller.ring_radii.is_empty() else 15.0)
		return
	for row: Dictionary in rows:
		var ring := int(row["ring"])
		var centre: Vector3 = row["anchor"]
		if centre.is_zero_approx():
			centre = target.position
		mesh.surface_set_color(_ring_color(ring))
		_draw_ring(mesh, centre, float(row["radius"]))


func _draw_ring(mesh: ImmediateMesh, centre: Vector3, radius: float) -> void:
	var segments := 64
	var previous := centre + Vector3(radius, 0.0, 0.0)
	for index in range(1, segments + 1):
		var angle := TAU * float(index) / float(segments)
		var point := centre + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		mesh.surface_add_vertex(previous + Vector3.UP * 0.4)
		mesh.surface_add_vertex(point + Vector3.UP * 0.4)
		previous = point

func _draw_lines(mesh: ImmediateMesh, points: PackedVector3Array, color: Color) -> void:
	mesh.surface_set_color(color)
	for i in range(1, points.size()):
		mesh.surface_add_vertex(points[i - 1] + Vector3.UP * 0.4)
		mesh.surface_add_vertex(points[i] + Vector3.UP * 0.4)

func _unhandled_input(event: InputEvent) -> void:
	# 键盘：R = 重新投放，F = 重置视角（W/A/S/D 留给目标，Shift 冲刺）。
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			reset_all()
		elif event.keycode == KEY_F:
			reset_camera()
		elif event.keycode == KEY_SPACE:
			start_run()
		return
	if not ready_for_test:
		return
	if event is InputEventMouseMotion and _panning:
		_pan_camera(event.relative)
		return
	if not event is InputEventMouseButton:
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		return
	if not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		# 允许拉到 12 米视野看局部（配合中键平移），也允许拉到 400 米看全图。
		camera.size = clampf(camera.size * (0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1), 12, 400)
	elif event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		var start := camera.project_ray_origin(event.position)
		var end := start + camera.project_ray_normal(event.position) * 1000
		var map := get_world_3d().navigation_map
		var point := NavigationServer3D.map_get_closest_point_to_segment(map, start, end, true)
		if NavigationServer3D.map_get_closest_point_owner(map, point).is_valid():
			if event.button_index == MOUSE_BUTTON_RIGHT:
				if actors.size() < 256:
					var selected := _connected_spawn(point)
					if not selected.is_empty(): spawn_actor(selected.point, actors.size())
				return
			target.position = _marker_position(point)
			for actor in actors:
				actor.reached = false

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	layer.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	panel.offset_left = 12
	panel.offset_right = 248
	panel.offset_top = 12
	panel.offset_bottom = -12
	var theme := Theme.new()
	theme.default_font_size = 9
	theme.default_font = panel.get_theme_default_font()
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.1, 0.14, 0.11, 0.9) if state != "hover" else Color(0.22, 0.28, 0.22)
		box.set_content_margin_all(2.0)
		theme.set_stylebox(state, "Button", box)
		theme.set_stylebox(state, "OptionButton", box)
	panel.theme = theme
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 218
	column.add_theme_constant_override("separation", 2)
	scroll.add_child(column)
	var title := Label.new()
	title.text = "主场景 · 导航俯视观察台"
	column.add_child(title)
	# 操作说明与最常用的两个动作放在最上面：观察台里最容易找不到的就是「重新投放」。
	var hint := Label.new()
	hint.text = HINT_TEXT
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 210
	hint.add_theme_color_override("font_color", Color(0.72, 0.86, 0.72))
	column.add_child(hint)
	var top_row := HBoxContainer.new()
	column.add_child(top_row)
	var start_button := Button.new()
	start_button.text = "▶ 开始"
	start_button.tooltip_text = "启动后不会自动寻路；确认参数后点这里（或按空格）才开始"
	start_button.pressed.connect(start_run)
	top_row.add_child(start_button)
	var reset_button := Button.new()
	reset_button.text = "重新投放 R"
	reset_button.tooltip_text = "目标回到初始点 + 测量体按当前种子重新投放 + 环状态与统计清零"
	reset_button.pressed.connect(reset_all)
	top_row.add_child(reset_button)
	var view_button := Button.new()
	view_button.text = "重置视角 F"
	view_button.tooltip_text = "相机回到初始俯视位置与缩放"
	view_button.pressed.connect(reset_camera)
	top_row.add_child(view_button)
	_arena_choice = OptionButton.new()
	_arena_choice.tooltip_text = "选择测试地图；切换会重建世界并重新烘焙导航网格"
	for id: String in Arena.get_order():
		_arena_choice.add_item(String(Arena.get_params(id).get("label", id)))
	_arena_choice.select(Arena.get_order().find(Arena.resolve_id()))
	_arena_choice.item_selected.connect(func(index: int): Arena.current_id = Arena.get_order()[index]; rebuild_world())
	column.add_child(_arena_choice)
	_seed = _number(column, "固定种子", 1, 999999, 1, seed_value, "投放用的随机种子。同一种子得到同一组起点，方便对比两次改动")
	_seed.value_changed.connect(func(value: float): seed_value = int(value))
	_count = _number(column, "测量体数量", 1, 256, 1, count, "投放多少个测量体（纯移动、无攻击）。数量越大越接近压力测试")
	_count.value_changed.connect(func(value: float): count = int(value))
	_speed = _number(column, "测量体速度 m/s", 0.5, 8, 0.5, 4, "测量体的移动速度，即时生效")
	_keyboard_toggle = CheckButton.new()
	_keyboard_toggle.text = "WASD 连续控制目标"
	_keyboard_toggle.button_pressed = keyboard_target
	_keyboard_toggle.tooltip_text = "用 W/A/S/D 连续移动目标，Shift 冲刺 ×1.7；用来观察敌人是否动态改线"
	_keyboard_toggle.toggled.connect(func(value: bool): keyboard_target = value)
	column.add_child(_keyboard_toggle)
	_target_speed_spin = _number(column, "目标速度 m/s", 0.5, 8, 0.1, target_speed, "WASD 移动目标的速度；按住 Shift 冲刺 ×1.7")
	_target_speed_spin.value_changed.connect(func(value: float): target_speed = value)
	_speed.value_changed.connect(func(value: float):
		for actor in actors:
			actor.speed = value
			actor.steering.spatial.bind({"move_speed": value}, {"can_attack": func(): return false}))
	_button(column, "相同种子重播", replay, "清掉现有测量体并按当前种子重新投放；目标停在原地。要让目标也回初始点用上面的「重新投放 R」")
	var batches := HBoxContainer.new()
	column.add_child(batches)
	for amount: int in [64, 128, 256]:
		var button := Button.new()
		button.text = "%d 个" % amount
		button.tooltip_text = "全区域投放并重播"
		button.pressed.connect(_pressure_count.bind(amount))
		batches.add_child(button)
	_area_toggle = CheckButton.new()
	_area_toggle.text = "全区域分层投放"
	_area_toggle.tooltip_text = "开启 = 按网格铺满整张地图（压力测试）；关闭 = 只沿环形散布"
	_area_toggle.button_pressed = full_area
	_area_toggle.toggled.connect(func(value: bool): full_area = value; replay())
	column.add_child(_area_toggle)
	_button(column, "开始（空格）", func(): start_run(), "启动后不会自动寻路：参数确认好再点这里（或按空格）开始")
	_button(column, "暂停 / 继续", func():
		if not started:
			_message = "先点「开始（空格）」再暂停"
			return
		paused_motion = not paused_motion
		for actor in actors: actor.running = not paused_motion, "冻结 / 恢复所有测量体的移动，用于逐帧观察")
	var spatial := CheckButton.new()
	spatial.text = "空间通行决策（仅行走）"
	spatial.tooltip_text = "开启 = 走正式空间通行决策（跳跃 / 攀爬 / 破障 / 绕行都参与）；关闭 = 只走 NavSteering 原生网格跟随"
	spatial.button_pressed = true
	spatial.toggled.connect(func(value: bool): spatial_enabled = value; replay())
	column.add_child(spatial)
	var connected := CheckButton.new()
	connected.text = "仅在连通区域投放"
	connected.tooltip_text = "开启 = 只在导航连通的位置投放；关闭 = 允许投在孤岛上，用来观察真实不可达"
	connected.button_pressed = connected_spawns
	connected.toggled.connect(func(value: bool): connected_spawns = value; replay())
	column.add_child(connected)
	var visible_routes := CheckButton.new()
	visible_routes.text = "显示路线"
	visible_routes.tooltip_text = "显示 蓝=基础网格路径、绿=成形路径；关掉后只看轨迹"
	visible_routes.button_pressed = true
	visible_routes.toggled.connect(func(value: bool): show_routes = value)
	column.add_child(visible_routes)
	var visible_trails := CheckButton.new()
	visible_trails.text = "显示轨迹"
	visible_trails.tooltip_text = "显示每个测量体走过的彩色轨迹；嫌画面乱时关掉，只看路线与目标点"
	visible_trails.button_pressed = true
	visible_trails.toggled.connect(func(value: bool):
		show_trails = value
		# 大数量下默认不画轨迹：256 条彩线会把人看糊也拖慢画面。
		if value and actors.size() > 128:
			_message = "测量体超过 128 个：轨迹只画最近 %d 个点，可随时关掉" % TRAIL_DRAW_POINTS)
	column.add_child(visible_trails)
	# 同心环目标（「铁圈」模型）：远处目标点改成被拖动过才动的环圆心，默认关闭。
	_ring_toggle = CheckButton.new()
	_ring_toggle.text = "同心环带目标"
	_ring_toggle.tooltip_text = "开启 = 远处目标点改成目标环带内的一个区域（从目标真实走过的位置里挑），目标小范围移动不重画；关闭 = 一律规划到玩家当前位置。默认关闭"
	_ring_toggle.button_pressed = Controller.ring_goal_enabled
	_ring_toggle.toggled.connect(func(value: bool):
		Controller.ring_goal_enabled = value
		Controller.reset_ring_goals()
		for actor in actors:
			actor.steering.spatial.route.clear()
			actor.steering.spatial._timer = 0.0
			actor.steering.repath())
	column.add_child(_ring_toggle)
	# 拖动方式：两种模式的共同点是「目标在圈内移动时圈不动」，差别只在越过边缘后怎么走。
	_ring_mode_choice = OptionButton.new()
	_ring_mode_choice.tooltip_text = "环被拖动的方式：\n弹开 = 越过边缘就跳到内圈位置（默认，位置永远是走过的点）\n平滑 = 圆心贴着边缘滑行"
	_ring_mode_choice.add_item("弹开（越过边缘跳到内圈）")
	_ring_mode_choice.add_item("平滑（沿边缘滑行）")
	_ring_mode_choice.select(1 if Controller.ring_drag_mode == "smooth" else 0)
	_ring_mode_choice.item_selected.connect(func(index: int):
		Controller.ring_drag_mode = "smooth" if index == 1 else "snap"
		Controller.reset_ring_goals()
		for actor in actors:
			actor.steering.spatial.route.clear()
			actor.steering.spatial._timer = 0.0
			actor.steering.repath())
	column.add_child(_ring_mode_choice)
	# 圈数与每一圈的半径分开指定：数量自己定，半径逐环自己填（不再强制 2 倍递增）。
	_ring_count = _number(column, "同心环数量", 2, MAX_RINGS, 1, maxi(Controller.ring_radii.size(), 2), "同心环总数（2~8）。改它只改变用几环，半径在下面逐环填")
	_ring_count.value_changed.connect(func(_value: float): _ring_count_changed())
	_ring_level_spin = _number(column, "环层级容差 m", 0, 20, 1, Controller.ring_level_tolerance, "0 = 不设限（默认，推荐）：没进环就只奔向环，跨层交给规划器判能力与完整身体通道。大于 0 才启用旧的层级门（来自加入圈组之前的粗略点版本）")
	_ring_level_spin.value_changed.connect(func(value: float):
		Controller.ring_level_tolerance = value
		Controller.reset_ring_goals()
		for actor in actors:
			actor.steering.spatial.route.clear()
			actor.steering.spatial._timer = 0.0
			actor.steering.repath())
	_button(column, "远处降频（省每帧查询）", func():
		Controller.tick_throttle_max = 1 if Controller.tick_throttle_max > 1 else 6
		_message = "远处降频：%s（上限 %d 帧）" % ["关" if Controller.tick_throttle_max <= 1 else "开", Controller.tick_throttle_max],
		"远处个体（目标点已经冻结）不再每帧做全套身体查询，只沿已发布路线走；近身 25 米内始终每帧完整判定")
	_throttle_from = _number(column, "降频起点 m", 5, 200, 5, Controller.tick_throttle_min_distance, "距目标小于这个距离的个体每帧完整判定")
	_throttle_step = _number(column, "降频步长 m", 5, 200, 5, Controller.tick_throttle_step, "每多出这么多米，tick 间隔 +1 帧；更大场景可以调大")
	_throttle_max = _number(column, "降频上限 帧", 1, 20, 1, Controller.tick_throttle_max, "tick 间隔上限；1 = 关闭降频")
	for spin: SpinBox in [_throttle_from, _throttle_step, _throttle_max]:
		spin.value_changed.connect(func(_value: float):
			Controller.tick_throttle_min_distance = _throttle_from.value
			Controller.tick_throttle_step = _throttle_step.value
			Controller.tick_throttle_max = int(_throttle_max.value))
	_spawn_ring_spin = _number(column, "投放于第N环外", 0, MAX_RINGS, 1, spawn_outside_ring, "0 = 不限；N = 只把测量体投放在第 N 环之外（按该环圆心与半径判断）。用来观察远处敌人到底寻路到圈内还是到玩家")
	_spawn_ring_spin.value_changed.connect(func(value: float):
		spawn_outside_ring = int(value)
		replay())
	for index in range(MAX_RINGS):
		var row := HBoxContainer.new()
		var tag := Label.new()
		tag.text = "%s 第%d环半径 m" % [_ring_glyph(index + 1), index + 1]
		tag.custom_minimum_size.x = 130
		tag.tooltip_text = "第 %d 环的半径（米）。必须比内一环大；内侧越小越精确，外环越大越钝" % (index + 1)
		row.add_child(tag)
		var spin := SpinBox.new()
		spin.min_value = 1
		spin.max_value = 400
		spin.step = 1
		spin.tooltip_text = "第 %d 环半径（1~400 米）。拖动或输入后立即生效并重置环状态" % (index + 1)
		spin.value_changed.connect(func(_value: float): _apply_ring_radii())
		row.add_child(spin)
		column.add_child(row)
		_ring_radius_rows.append(row)
		_ring_radius_spins.append(spin)
	_button(column, "按 2 倍递增填充", _fill_ring_radii_doubling, "以第 1 环为基准，把每环半径填成 ×2 的等比数列；填完仍可逐环改")
	_button(column, "保存环参数为默认", _save_ring_defaults, "把当前环开关 / 拖动方式 / 圈数 / 逐环半径 / 层级容差 / 投放约束写进 data/navigation/ring_goals.json，下次启动自动读回")
	_ring_span_label = Label.new()
	_ring_span_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ring_span_label.custom_minimum_size.x = 210
	column.add_child(_ring_span_label)
	_saved_settings = PathStyle.settings()
	_rounding = _number(column, "转角圆弧 m", 0, 2, 0.1, _saved_settings.get("corner_rounding", 0.8), "APS 圆角：拐角切掉多少米。空间不足或候选被拒时保留原角点")
	_lane = _number(column, "路线侧偏 m", -3, 3, 0.05, _saved_settings.get("lane_offset", 0.0), "APS 车道偏移：按转角强度加权把路线往一侧偏；0 = 关闭")
	_replan = _number(column, "目标移动重算 m", 0.2, 3, 0.1, _saved_settings.get("goal_replan_distance", 0.8), "NavSteering 自己的重算阈值：目标累计移动超过它才重建网格路径")
	# APS 移植新增调参键：与 navigation_path.apply 白名单、steering.json 三处同步登记。
	_arc_strength = _number(column, "弧形强度 -3..3", -3, 3, 0.1, _saved_settings.get("arc_strength", 0.0), "APS 弧形鼓包强度：正 = 一侧、负 = 另一侧；|强度| < 0.1 视为关闭")
	_arc_midpoints = _number(column, "弧形中点 1..6", 1, 6, 1, _saved_settings.get("arc_num_midpoints", 3), "smooth 的包络指数 / wavy 的波峰数，同时是圆角细节采样上限")
	_arc_min_distance = _number(column, "弧形最短 m", 0, 50, 0.5, _saved_settings.get("arc_min_distance", 3.0), "低于这个水平距离不做弧形（APS 对应 300 uu）")
	_arc_resample = _number(column, "重采样段长 m", 0.5, 10, 0.5, _saved_settings.get("arc_resample_length", 4.0), "弧长等分的目标段长（APS 对应 400 uu）")
	_shape_max_points = _number(column, "成形点数上限", 16, 192, 1, _saved_settings.get("shape_max_points", 128), "重采样输出的点数上限（APS 原实现硬上限 128）")
	var mode_row := HBoxContainer.new()
	column.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "弧形模式"
	mode_label.custom_minimum_size.x = 130
	mode_row.add_child(mode_label)
	_arc_mode = OptionButton.new()
	_arc_mode.tooltip_text = "smooth = 单侧鼓包；wavy = 蛇形交替（APS ComputeLocalSideSign）"
	_arc_mode.add_item("smooth 单侧")
	_arc_mode.add_item("wavy 蛇形")
	_arc_mode.select(1 if String(_saved_settings.get("arc_mode", "smooth")) == "wavy" else 0)
	mode_row.add_child(_arc_mode)
	_sparse_warp = CheckButton.new()
	_sparse_warp.text = "密集点隔点形变"
	_sparse_warp.tooltip_text = "点数 > 64 且弧形强度 < 1.5 时，隔一个点做形变（APS 稀疏形变）"
	_sparse_warp.button_pressed = bool(_saved_settings.get("arc_sparse_warp", true))
	column.add_child(_sparse_warp)
	_final_gate = CheckButton.new()
	_final_gate.text = "整条终检（失败回退基准）"
	_final_gate.tooltip_text = "成形后逐段复检整条路径；任一候选失败就回退到基准路径"
	_final_gate.button_pressed = bool(_saved_settings.get("shape_final_gate", true))
	column.add_child(_final_gate)
	for spin: SpinBox in [_rounding, _lane, _replan, _arc_strength, _arc_midpoints, _arc_min_distance, _arc_resample, _shape_max_points]:
		spin.value_changed.connect(func(_value: float): _apply_settings())
	_arc_mode.item_selected.connect(func(_index: int): _apply_settings())
	_sparse_warp.toggled.connect(func(_value: bool): _apply_settings())
	_final_gate.toggled.connect(func(_value: bool): _apply_settings())
	_dirty_label = Label.new()
	_dirty_label.text = "导航参数：与项目默认一致"
	_dirty_label.tooltip_text = "面板里的导航参数只影响本轮运行；要变成下次启动的默认值必须点下面「将导航参数设为项目默认」"
	column.add_child(_dirty_label)
	_button(column, "将导航参数设为项目默认", func():
		var error := PathStyle.save()
		if error == OK:
			_saved_settings = PathStyle.settings()
			_dirty_label.text = "导航参数：已保存项目默认"
		else:
			_dirty_label.text = "保存失败（%d）" % error,
		"把面板里的导航参数写入 data/navigation/steering.json，成为下次启动的项目默认值")
	_preset_name = LineEdit.new()
	_preset_name.placeholder_text = "方案名称"
	_preset_name.tooltip_text = "命名方案的文件名；保存到 data/navigation/presets/<名称>.json，只保存方案、不改项目默认"
	column.add_child(_preset_name)
	_button(column, "另存命名方案", func():
		var name_value := _preset_name.text.strip_edges().validate_filename()
		if name_value.is_empty():
			_message = "请先填写方案名称"
			return
		# 方案里同时保存导航参数与环参数（原来只存导航参数，环参数读不回来）。
		var payload := PathStyle.settings()
		var ring := Controller.ring_config()
		ring["spawn_outside_ring"] = spawn_outside_ring
		payload["ring"] = ring
		var preset_path := "res://data/navigation/presets/" + name_value + ".json"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://data/navigation/presets"))
		var file := FileAccess.open(preset_path, FileAccess.WRITE)
		if file == null:
			_message = "保存方案失败（%d）" % FileAccess.get_open_error()
		else:
			file.store_string(JSON.stringify(payload, "	"))
			file.close()
			_message = "已另存方案：" + name_value + "（含环参数）",
		"把当前面板里的导航参数另存为 data/navigation/presets/<名称>.json；只保存方案，不改项目默认")
	_button(column, "读取命名方案", func():
		var name_value := _preset_name.text.strip_edges().validate_filename()
		var path := "res://data/navigation/presets/" + name_value + ".json"
		if name_value.is_empty() or not FileAccess.file_exists(path):
			_message = "未找到命名方案"
			return
		var values: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not values is Dictionary:
			_message = "方案文件格式错误"
			return
		_rounding.value = values.get("corner_rounding", 0.8)
		_lane.value = values.get("lane_offset", 0.0)
		_replan.value = values.get("goal_replan_distance", 0.8)
		_arc_strength.value = values.get("arc_strength", 0.0)
		_arc_midpoints.value = values.get("arc_num_midpoints", 3)
		_arc_min_distance.value = values.get("arc_min_distance", 3.0)
		_arc_resample.value = values.get("arc_resample_length", 4.0)
		_shape_max_points.value = values.get("shape_max_points", 128)
		_arc_mode.select(1 if String(values.get("arc_mode", "smooth")) == "wavy" else 0)
		_sparse_warp.set_pressed_no_signal(bool(values.get("arc_sparse_warp", true)))
		_final_gate.set_pressed_no_signal(bool(values.get("shape_final_gate", true)))
		# 环参数一起读回，并同步面板控件。
		var ring: Dictionary = values.get("ring", {}) if values.get("ring") is Dictionary else {}
		Controller.apply_ring_config(ring)
		spawn_outside_ring = int(ring.get("spawn_outside_ring", spawn_outside_ring))
		_ring_toggle.set_pressed_no_signal(Controller.ring_goal_enabled)
		_ring_mode_choice.select(1 if Controller.ring_drag_mode == "smooth" else 0)
		_ring_count.set_value_no_signal(maxi(Controller.ring_radii.size(), 2))
		_ring_count_changed()
		_ring_level_spin.set_value_no_signal(Controller.ring_level_tolerance)
		_spawn_ring_spin.set_value_no_signal(spawn_outside_ring)
		_apply_settings(),
		"读取 data/navigation/presets/<名称>.json 里的方案到面板；只改本轮预览，不改项目默认")
	_button(column, "保存本轮测量报告", export_report, "把本帧所有测量体的状态（位置、累计路程、最长停滞、状态、档位）写到项目外产物目录")
	_status = Label.new()
	_status.text = "正在构建主场景几何与导航网格…"
	column.add_child(_status)
	_list = Label.new()
	column.add_child(_list)
	# 面板建好后按当前配置回填逐环半径与可见行。
	_ring_count_changed()

## 圈数变化：可见行 = 前 N 行。半径优先用「已经生效的配置」，没有配置的新行按上一环 ×2 补，
## 因此改小圈数再改回来不会丢已经填好的半径。
func _ring_count_changed() -> void:
	var count := int(_ring_count.value)
	var previous := 0.0
	for index in range(_ring_radius_spins.size()):
		var row := _ring_radius_rows[index]
		row.visible = index < count
		if index >= count:
			continue
		var value := float(Controller.ring_radii[index]) if index < Controller.ring_radii.size() else (previous * 2.0 if index > 0 else 15.0)
		value = maxf(value, previous + 1.0)
		_ring_radius_spins[index].set_value_no_signal(value)
		previous = value
	_apply_ring_radii()


## 逐环半径 → 共用导航。半径强制递增（外环至少比内环大 1 米），并把修正后的值写回输入框，
## 保证面板显示的就是实际生效的。拖动阈值 T_k = R_k - R_(k-1)。
## 读回项目里的环参数默认（没有文件就用代码默认）。
func _load_ring_defaults() -> void:
	if not FileAccess.file_exists(RING_CONFIG_PATH):
		return
	var values: Variant = JSON.parse_string(FileAccess.get_file_as_string(RING_CONFIG_PATH))
	if not values is Dictionary:
		return
	Controller.apply_ring_config(values)
	spawn_outside_ring = int(values.get("spawn_outside_ring", spawn_outside_ring))


## 把当前环参数写进项目默认文件，下次启动自动读回。
func _save_ring_defaults() -> void:
	var payload := Controller.ring_config()
	payload["spawn_outside_ring"] = spawn_outside_ring
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://data/navigation"))
	var file := FileAccess.open(RING_CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		_message = "环参数保存失败（%d）" % FileAccess.get_open_error()
		return
	file.store_string(JSON.stringify(payload, "	"))
	file.close()
	_message = "已把当前环参数写为项目默认：ring_goals.json（下次启动自动读回）"


func _apply_ring_radii() -> void:
	var radii := PackedFloat32Array()
	var previous := 0.0
	for index in range(int(_ring_count.value)):
		var value := maxf(float(_ring_radius_spins[index].value), previous + 1.0)
		_ring_radius_spins[index].set_value_no_signal(value)
		radii.append(value)
		previous = value
	Controller.ring_radii = radii
	Controller.reset_ring_goals()
	for actor in actors:
		actor.steering.spatial.route.clear()
		actor.steering.spatial._timer = 0.0
		actor.steering.repath()
	_sync_ring_span()


## 快速填充：以第 1 环为基准，每环 ×2。
func _fill_ring_radii_doubling() -> void:
	var base := maxf(float(_ring_radius_spins[0].value), 1.0)
	for index in range(int(_ring_count.value)):
		_ring_radius_spins[index].set_value_no_signal(base * pow(2.0, float(index)))
	_apply_ring_radii()


func _sync_ring_span() -> void:
	if not is_instance_valid(_ring_span_label):
		return
	var radii := Controller.ring_radii
	if radii.is_empty():
		_ring_span_label.text = "当前环：未配置"
		return
	var parts := PackedStringArray()
	for index in range(radii.size()):
		parts.append("%s%.0f" % [_ring_glyph(index + 1), radii[index]])
	_ring_span_label.text = "当前环：%s  最外 %.0f m" % [" / ".join(parts), radii[radii.size() - 1]]


func _apply_settings() -> void:
	PathStyle.apply({
		"corner_rounding": _rounding.value, "lane_offset": _lane.value,
		"goal_replan_distance": _replan.value, "arc_strength": _arc_strength.value,
		"arc_num_midpoints": int(_arc_midpoints.value), "arc_min_distance": _arc_min_distance.value,
		"arc_resample_length": _arc_resample.value, "shape_max_points": int(_shape_max_points.value),
		"arc_mode": "wavy" if _arc_mode.selected == 1 else "smooth",
		"arc_sparse_warp": _sparse_warp.button_pressed, "shape_final_gate": _final_gate.button_pressed,
	})
	_dirty_label.text = "导航参数：未保存" if PathStyle.settings() != _saved_settings else "导航参数：与项目默认一致"
	for actor in actors:
		actor.steering.spatial.route.clear()
		actor.steering.spatial._timer = 0.0
		actor.steering.repath()

func _pressure_count(amount: int) -> void:
	_count.value = amount
	full_area = true
	_area_toggle.set_pressed_no_signal(true)
	replay()

func _number(column: VBoxContainer, text: String, low: float, high: float, step: float, value: float, tip := "") -> SpinBox:
	var row := HBoxContainer.new()
	column.add_child(row)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 130
	label.tooltip_text = tip
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.value = value
	spin.tooltip_text = "%s（范围 %.2f~%.2f，步长 %.2f）" % [tip, low, high, step] if not tip.is_empty() else ""
	row.add_child(spin)
	return spin

func _button(column: VBoxContainer, text: String, callback: Callable, tip := "") -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.pressed.connect(callback)
	column.add_child(button)
	return button

func export_report() -> void:
	var rows: Array = []
	for actor in actors: rows.append(actor.snapshot())
	var path := Paths.ensure_dir("reports", "navigation").path_join("run_%d.json" % Time.get_ticks_msec())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("导航报告写入失败：" + path)
		return
	file.store_string(JSON.stringify({"arena": Arena.resolve_id(), "seed": seed_value, "seconds": elapsed, "full_area": full_area, "connected_spawns": connected_spawns, "spawn_adjustments": spawn_adjustments, "spawn_samples": spawn_samples, "navigation_settings": PathStyle.settings(), "target": [target.position.x, target.position.y, target.position.z], "actors": rows}, "\t"))
	_message = "测量已保存到项目外产物目录"
	print("[导航观察] 已保存：", path)
