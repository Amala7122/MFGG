extends SceneTree
## 帧耗诊断：手绘滤镜 × 移动视角 × 爆囊爬兽 × 地面预警并发。
##
## 目的：区分「全局卡」和「特定对象卡」。分档逐项只改变一个因素：
##   无滤镜静止 → 手绘静止 → 手绘移动 → 手绘移动+爆囊 → 关滤镜+爆囊 → 手绘移动+泥偶（对照）
## 另单独测 attack_surface_mesh.prepare() 在真实圣所地形上的单次与四并发耗时。
##
## 口径：帧耗用 Time.get_ticks_usec() 的墙钟间隔（run_probe 的 --fixed-fps 只固定模拟步长，
## 不改变墙钟）；process/physics/draw/primitives 取 Performance 监视器。静止档与移动档分开记录，
## 并在结束时报告实际达成的视角位移，防止「以为在转、其实被角色脚本每帧覆盖」。

const MainScene := preload("res://scenes/sanctum_main.tscn")
const Creatures := preload("res://scripts/enemies/creature_catalog.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Config := preload("res://scripts/game_config.gd")

const WARMUP := 30
const FRAMES := 150
const SKETCH := 5
const WARN_COUNT := 4
const WARN_SPEC := {"kind": "sector", "radius": 5.0, "angle": 270.0, "height": 2.5}
const SPAWN_RING := [8.0, 10.5, 13.0, 15.5]

var _scene: Node
var _player: Node3D
var _pivot: Node3D
var _camera: Camera3D
var _spawned: Array[Node] = []
var _rows: Array[Dictionary] = []
var _render_scale := 1.0
var _window := Vector2i.ZERO
var _tier := ""
var _warmup := WARMUP
var _frames := FRAMES
var _count := 12
var _repeat := 2
var _species := ""
var _origin := Vector3.ZERO
var _initial_yaw := 0.0


func _initialize() -> void:
	# 预热/测量帧数、敌人数、同档位重复次数都可调。
	# repeat>1 时同一档位在同一进程内连续跑多遍：尖峰只在第 1 遍=首次成本，每遍都有=持续成本。
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--warmup="):
			_warmup = clampi(int(arg.trim_prefix("--warmup=")), 0, 600)
		elif arg.begins_with("--frames="):
			_frames = clampi(int(arg.trim_prefix("--frames=")), 30, 900)
		elif arg.begins_with("--count="):
			_count = clampi(int(arg.trim_prefix("--count=")), 1, 40)
		elif arg.begins_with("--repeat="):
			_repeat = clampi(int(arg.trim_prefix("--repeat=")), 1, 4)
		elif arg.begins_with("--species="):
			_species = arg.trim_prefix("--species=")
	call_deferred("_run")


func _run() -> void:
	if not await _start_formal_scene():
		quit(1)
		return
	_window = Vector2i(DisplayServer.window_get_size())
	_render_scale = float(root.scaling_3d_scale)
	_tier = String(Config.get_string("graphics.active", "high"))

	var plan := [
		["1_无滤镜_静止_0敌", false, false, "", 0],
		["2_手绘_静止_0敌", true, false, "", 0],
		["3_手绘_移动_0敌", true, true, "", 0],
		["4_手绘_移动_爆囊", true, true, "burst_crawler", _count],
		["5_无滤镜_移动_爆囊", false, true, "burst_crawler", _count],
		["6_手绘_移动_泥偶", true, true, "mud_golem", _count],
		["7_手绘_移动_晶兽", true, true, "fast_beast", _count],
	]
	for item in plan:
		if not _species.is_empty() and item[3] != _species:
			continue
		for round_index in _repeat:
			await _phase("%s#%d" % [item[0], round_index + 1],
				item[1], item[2], item[3], item[4])

	_set_filter(false)
	_clear_enemies()
	var warn := await _measure_warning_builds()

	var result := {
		"window": [_window.x, _window.y],
		"render_scale": _render_scale,
		"render_texture": [root.get_texture().get_width(), root.get_texture().get_height()],
		"graphics_tier": _tier,
		"warmup_frames": _warmup,
		"measured_frames": _frames,
		"enemy_count": _count,
		"repeat": _repeat,
		"phases": _rows,
		"warning_build": warn,
		"note": "帧耗为墙钟间隔；手绘档已关闭天气时间线与其他调试面板，敌人只保留自身战斗逻辑。",
	}
	var path := Artifacts.ensure_dir("reports").path_join("burst_crawler_perf.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("帧耗诊断：无法写入 " + path)
		quit(1)
		return
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("[帧耗诊断] ", path)
	for row in _rows:
		print("[帧耗诊断] %-22s fps=%6.1f avg=%7.2fms p95=%7.2fms max=%8.2fms >16.7=%3d/%d draw=%5d prim=%8d 视角=%5.1f° 位移=%4.2fm" % [
			row.name, row.fps, row.avg_ms, row.p95_ms, row.max_ms, row.over_16_7, row.frames,
			row.draw_calls, row.primitives, row.yaw_deg, row.moved_m])
	print("[帧耗诊断] 预警单次=", warn.single_ms, " 四并发=", warn.four_ms)
	quit(0)


func _start_formal_scene() -> bool:
	var initial := MainScene.instantiate()
	root.add_child(initial)
	current_scene = initial
	for _frame in 3:
		await process_frame
	var flow := root.get_node_or_null("GameFlow")
	if flow == null:
		push_error("帧耗诊断：找不到 GameFlow")
		return false
	var old_scene := current_scene
	flow.call("start_run")
	for _frame in 360:
		await process_frame
		if current_scene != null and current_scene != old_scene \
				and not get_nodes_in_group("player").is_empty():
			break
	if current_scene == null or get_nodes_in_group("player").is_empty():
		push_error("帧耗诊断：正式场景或玩家未就绪")
		return false
	_scene = current_scene
	_player = get_nodes_in_group("player")[0] as Node3D
	_player.set_meta(&"experiment_invincible", true)
	_origin = _player.global_position
	_pivot = _player.get_node_or_null("CameraPivot") as Node3D
	_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if _pivot == null or _camera == null:
		push_error("帧耗诊断：找不到正式相机")
		return false
	_initial_yaw = _pivot.rotation.y
	if _uses_formal_population():
		return true
	# 固定人口：停掉正式刷怪与天气时间线，敌人自身战斗逻辑保持运行。
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := _scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
	for spawn_point in _scene.find_children("*", "EnemySpawnPoint", true, false):
		spawn_point.set_process(false)
		spawn_point.set_physics_process(false)
	var timeline := _scene.find_child("WeatherTimeline", true, false)
	if timeline != null:
		timeline.set_process(false)
		timeline.set_process_input(false)
	await _clear_enemies()
	return true

func _uses_formal_population() -> bool:
	return false


func _set_filter(enabled: bool) -> void:
	var post := root.get_node_or_null("PostProcess")
	if post != null:
		post.call("set_style", SKETCH if enabled else 0)


func _spawn(count: int, species: String) -> void:
	for index in count:
		var entry := {"species": species}
		var enemy := Creatures.instantiate(entry)
		if enemy == null:
			continue
		_configure_enemy(enemy, index)
		var angle := TAU * float(index) / float(maxi(count, 1))
		var radius: float = SPAWN_RING[index % SPAWN_RING.size()]
		var x := _player.global_position.x + cos(angle) * radius
		var z := _player.global_position.z + sin(angle) * radius
		enemy.position = Vector3(x, Terrain.height_at(x, z) + 0.6, z)
		enemy.add_to_group("dynamic_enemies")
		if enemy.has_method("set_combat_target"):
			enemy.call("set_combat_target", _player)
		var holder := _scene.get_node_or_null("Enemies")
		(holder if holder != null else _scene).add_child(enemy)
		_spawned.append(enemy)

func _configure_enemy(enemy: Node, index: int) -> void:
	enemy.set_meta(&"crowd_seed", 314159 + index)


func _clear_enemies() -> void:
	Input.action_release("move_right")
	for enemy in _spawned:
		if is_instance_valid(enemy):
			enemy.queue_free()
	_spawned.clear()
	for enemy in get_nodes_in_group("dynamic_enemies"):
		if is_instance_valid(enemy):
			enemy.queue_free()
	for group in ["enemy_projectiles", "enemy_hazards"]:
		for node in get_nodes_in_group(group):
			if not node.is_queued_for_deletion():
				node.queue_free()
	for _frame in 4:
		await process_frame


func _phase(name: String, filter: bool, move: bool, species: String, count: int) -> void:
	_set_filter(filter)
	await _clear_enemies()
	_player.global_position = _origin
	_player.set("velocity", Vector3.ZERO)
	_player.set("target_yaw", _initial_yaw)
	_pivot.rotation.y = _initial_yaw
	_camera.rotation.y = 0.0
	if count > 0 and not species.is_empty():
		_spawn(count, species)
	var yaw_start: float = _pivot.rotation.y
	var pos_start: Vector3 = _player.global_position
	for _frame in _warmup:
		if move:
			_advance_view()
		await process_frame
	var frame_ms: Array[float] = []
	var process_ms: Array[float] = []
	var physics_ms: Array[float] = []
	var draws: Array[float] = []
	var prims: Array[float] = []
	var previous := Time.get_ticks_usec()
	for frame in _frames:
		if move:
			_advance_view()
		await process_frame
		var now := Time.get_ticks_usec()
		frame_ms.append(float(now - previous) / 1000.0)
		previous = now
		process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		prims.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		if frame % 60 == 0 and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
	var sorted := frame_ms.duplicate()
	sorted.sort()
	var total := 0.0
	var slow := 0
	for value in frame_ms:
		total += value
		if value > 16.7:
			slow += 1
	var moved := Vector2(
		_player.global_position.x - pos_start.x,
		_player.global_position.z - pos_start.z).length()
	_rows.append({
		"name": name,
		"filter": filter,
		"move": move,
		"species": species,
		"count": count,
		"frames": _frames,
		"avg_ms": total / float(maxi(frame_ms.size(), 1)),
		"p50_ms": sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0,
		"p95_ms": sorted[clampi(ceili(float(sorted.size()) * 0.95) - 1, 0, maxi(sorted.size() - 1, 0))] if not sorted.is_empty() else 0.0,
		"max_ms": sorted.back() if not sorted.is_empty() else 0.0,
		"over_16_7": slow,
		"fps": 1000.0 / maxf(total / float(maxi(frame_ms.size(), 1)), 0.001),
		"process_ms": _mean(process_ms),
		"physics_ms": _mean(physics_ms),
		"draw_calls": int(_mean(draws)),
		"primitives": int(_mean(prims)),
		"yaw_deg": rad_to_deg(absf(wrapf(_pivot.rotation.y - yaw_start, -PI, PI))),
		"moved_m": moved,
		"alive": _spawned.size(),
	})
	Input.action_release("move_right")


func _advance_view() -> void:
	# 走真实玩家移动路径；固定模拟输入，不再以墙钟决定每帧瞬移方向。
	# 必须改 target_yaw，直接改 pivot 会被玩家相机平滑覆盖。
	Input.action_press("move_right", 0.65)
	_player.set("target_yaw", wrapf(float(_player.get("target_yaw")) + 0.012, -PI, PI))


func _measure_warning_builds() -> Dictionary:
	# 每轮重建全新 area：测「首次构建」与「同进程后续构建」是否不同。
	var spots := [Vector3(-12, 2.2, 9), Vector3(-11.8, 2.2, 9), Vector3(-12.2, 2.2, 9), Vector3(4, 2.2, 9)]
	var singles: Array[float] = []
	var fours: Array[float] = []
	for round_index in _repeat:
		var area := AttackArea.new()
		area.process_mode = Node.PROCESS_MODE_DISABLED
		_scene.add_child(area)
		var started := Time.get_ticks_usec()
		area.prepare(Transform3D(Basis.IDENTITY, spots[0]), WARN_SPEC, 10.0)
		singles.append(float(Time.get_ticks_usec() - started) / 1000.0)
		area.free()
		var areas: Array[Node] = []
		var started_all := Time.get_ticks_usec()
		for index in WARN_COUNT:
			var item := AttackArea.new()
			item.process_mode = Node.PROCESS_MODE_DISABLED
			_scene.add_child(item)
			item.prepare(Transform3D(Basis.IDENTITY, spots[index]), WARN_SPEC, 10.0)
			areas.append(item)
		fours.append(float(Time.get_ticks_usec() - started_all) / 1000.0)
		for item in areas:
			item.free()
	return {"single_ms": singles, "four_ms": fours, "count": WARN_COUNT,
		"spec": WARN_SPEC, "terrain": "scenes/sanctum_main.tscn"}


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())
