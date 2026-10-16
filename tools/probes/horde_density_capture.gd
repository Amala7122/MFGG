extends SceneTree
## 正式第三人称相机下的敌人视觉密度对照。
##
## 只在 run_probe 的隔离工程里运行：加载正式圣所、正式玩家与正式敌人外观，
## 关闭波次和敌人逻辑后，用同一组确定性站位拍摄不同数量。它只回答
## 「画面里多少轮廓开始像海量」，不把静态截图冒充正式战斗性能。

const MainScene := preload("res://scenes/hyrule_field.tscn")
const ConfigUtil := preload("res://scripts/game_config.gd")
const TerrainUtil := preload("res://scripts/terrain_field.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")

const COUNTS := [18, 32, 48, 64, 96, 128]
const MIN_DISTANCE := 15.0
const MAX_DISTANCE := 52.0
const HALF_ANGLE := deg_to_rad(39.0)
const ROW_STEP := 3.1
const COLUMN_STEP := 2.65
const SEED := 64768

var _scene: Node
var _player: Node3D
var _camera: Camera3D
var _spawner: Node
var _entries: Array = []
var _positions: Array[Vector3] = []
var _spawned: Array[Node3D] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if not await _start_formal_scene():
		quit(1)
		return
	_prepare_camera()
	# 所有数量档必须共享同一天气、时刻和 UI 帧；否则亮度、雨幕和云影会污染
	# 「数量差异」这一唯一变量。SceneTree 脚本与渲染仍会继续，场景节点暂停。
	paused = true
	_positions = _candidate_positions()
	if _positions.size() < COUNTS[-1]:
		push_error("海量敌人视觉计量：候选站位不足 %d" % COUNTS[-1])
		quit(1)
		return

	var output := Artifacts.ensure_dir("screenshots", "horde_density")
	var captures: Array[Dictionary] = []
	for count in COUNTS:
		await _replace_horde(count)
		await RenderingServer.frame_post_draw
		var path := output.path_join("visible_%03d.png" % count)
		var image := root.get_texture().get_image()
		if image == null or image.is_empty() or image.save_png(path) != OK:
			push_error("海量敌人视觉计量：截图失败 %s" % path)
			quit(1)
			return
		var in_frustum := 0
		for enemy in _spawned:
			if _camera.is_position_in_frustum(enemy.global_position + Vector3.UP * 1.1):
				in_frustum += 1
		captures.append({
			"requested": count,
			"spawned": _spawned.size(),
			"in_camera_frustum": in_frustum,
			"screenshot": path,
		})
		print("[海量视觉计量] 数量=%d 视锥内=%d 截图=%s" % [count, in_frustum, path])

	var report := {
		"purpose": "正式第三人称相机下的静态视觉密度对照；不是性能结论",
		"counts": COUNTS,
		"seed": SEED,
		"placement": {
			"min_distance_m": MIN_DISTANCE,
			"max_distance_m": MAX_DISTANCE,
			"half_angle_degrees": rad_to_deg(HALF_ANGLE),
			"row_step_m": ROW_STEP,
			"column_step_m": COLUMN_STEP,
		},
		"camera": {
			"fov_degrees": _camera.fov,
			"position": _camera.global_position,
			"forward": -_camera.global_basis.z,
			"viewport": root.get_visible_rect().size,
		},
		"captures": captures,
	}
	var report_path := Artifacts.ensure_dir("reports").path_join("horde_density.json")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("海量敌人视觉计量：无法写报告 %s" % report_path)
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("[海量视觉计量] 报告=", report_path)
	quit()


func _start_formal_scene() -> bool:
	var initial := MainScene.instantiate()
	root.add_child(initial)
	current_scene = initial
	for _frame in 3:
		await process_frame
	var flow := root.get_node_or_null("GameFlow")
	if flow == null:
		push_error("海量敌人视觉计量：找不到 GameFlow")
		return false
	var old_scene := current_scene
	flow.call("start_run")
	for _frame in 240:
		await process_frame
		if current_scene != null and current_scene != old_scene \
				and not get_nodes_in_group("player").is_empty():
			break
	if current_scene == null or get_nodes_in_group("player").is_empty():
		push_error("海量敌人视觉计量：正式场景或玩家未就绪")
		return false
	_scene = current_scene
	_player = get_nodes_in_group("player")[0] as Node3D
	_camera = _player.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	_spawner = _scene.find_child("EnemySpawner", true, false)
	if _camera == null or _spawner == null:
		push_error("海量敌人视觉计量：找不到正式相机或 EnemySpawner")
		return false
	var roster := ConfigUtil.get_dictionary("enemy_roster")
	var raw_entries: Variant = roster.get("entries", [])
	if raw_entries is not Array or (raw_entries as Array).is_empty():
		push_error("海量敌人视觉计量：敌人图鉴为空")
		return false
	_entries = raw_entries as Array
	var wave := _scene.find_child("WaveDirector", true, false)
	if wave != null:
		wave.set_process(false)
	await _clear_enemies()
	return true


func _prepare_camera() -> void:
	_player.rotation.y = 0.0
	_player.set("target_yaw", 0.0)
	_player.set("target_pitch", deg_to_rad(-12.0))
	var pivot := _player.get_node_or_null("CameraPivot") as Node3D
	if pivot != null:
		pivot.rotation = Vector3(deg_to_rad(-12.0), 0.0, 0.0)
	_camera.fov = 70.0
	_camera.current = true
	_player.set_process(false)
	_player.set_physics_process(false)


func _candidate_positions() -> Array[Vector3]:
	var local_points: Array[Vector2] = []
	var distance := MIN_DISTANCE
	while distance <= MAX_DISTANCE + 0.01:
		var half_width := tan(HALF_ANGLE) * distance
		var x := -half_width
		var row := roundi((distance - MIN_DISTANCE) / ROW_STEP)
		while x <= half_width + 0.01:
			var stagger := COLUMN_STEP * 0.5 if row % 2 != 0 else 0.0
			var shifted_x := x + stagger
			if absf(shifted_x) <= half_width:
				local_points.append(Vector2(shifted_x, distance))
			x += COLUMN_STEP
		distance += ROW_STEP
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for index in range(local_points.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var temporary := local_points[index]
		local_points[index] = local_points[swap_index]
		local_points[swap_index] = temporary
	var result: Array[Vector3] = []
	for point in local_points:
		var x := _player.global_position.x + point.x
		var z := _player.global_position.z - point.y
		result.append(Vector3(x, TerrainUtil.height_at(x, z), z))
	return result


func _replace_horde(count: int) -> void:
	await _clear_enemies()
	for index in count:
		var entry := _entries[(index * 5 + index / 7) % _entries.size()] as Dictionary
		var enemy := _spawner.call("spawn_enemy", entry, _positions[index], 4.0) as Node3D
		if enemy == null:
			continue
		enemy.process_mode = Node.PROCESS_MODE_DISABLED
		_spawned.append(enemy)
	for _frame in 4:
		await process_frame
	for index in _spawned.size():
		var enemy := _spawned[index]
		if not is_instance_valid(enemy):
			continue
		var target := Vector3(_player.global_position.x, enemy.global_position.y, _player.global_position.z)
		enemy.look_at(target, Vector3.UP)
	for _frame in 3:
		await process_frame


func _clear_enemies() -> void:
	for enemy in get_nodes_in_group("dynamic_enemies"):
		if is_instance_valid(enemy):
			enemy.queue_free()
	for enemy in _spawned:
		if is_instance_valid(enemy):
			enemy.queue_free()
	_spawned.clear()
	await process_frame
	await process_frame

