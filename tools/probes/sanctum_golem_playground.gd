extends SceneTree
## 正式圣所 + 30 只泥土傀儡的试玩入口（不是性能探针，不会自动退出）。
## 用途：手动走一圈，确认群体降频/站定跳物理没有把行为压过头。
## R 重开一波，F10 退出；自动化验证可加 -- --probe-seconds=8。

const MainScene := preload("res://scenes/sanctum_main.tscn")
const Creatures := preload("res://scripts/enemies/creature_catalog.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const SPAWN_RING := [8.0, 10.5, 13.0, 15.5]
const COUNT := 30

var _scene: Node
var _player: Node3D
var _spawned: Array[Node] = []
var _probe_seconds := 0.0
var _started_msec := 0
var _started := false
var _restarting := false
var _invincible := true
var _ai_on := true
var _frozen := false
var _shadows_on := true
var _weather_on := true
var _post_on := true
var _held: Dictionary = {}
var _hint_label: Label


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--probe-seconds="):
			_probe_seconds = maxf(float(arg.trim_prefix("--probe-seconds=")), 0.0)
		elif arg == "--invincible=off":
			_invincible = false
	call_deferred("_run")


func _run() -> void:
	var initial := MainScene.instantiate()
	root.add_child(initial)
	current_scene = initial
	for _frame in 3:
		await process_frame
	var flow := root.get_node_or_null("GameFlow")
	if flow == null:
		push_error("试玩入口：找不到 GameFlow")
		quit(1)
		return
	var old_scene := current_scene
	flow.call("start_run")
	for _frame in 360:
		await process_frame
		if current_scene != null and current_scene != old_scene \
				and not get_nodes_in_group("player").is_empty() \
				and not bool(flow.get("_preparing_run")):
			break
	if current_scene == null or get_nodes_in_group("player").is_empty():
		push_error("试玩入口：正式场景或玩家未就绪")
		quit(1)
		return
	_scene = current_scene
	_player = get_nodes_in_group("player")[0] as Node3D
	_player.set_meta(&"experiment_invincible", _invincible)
	# 只留我们手动放的 30 只；正式波次停掉，避免混入其他兵种。
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := _scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
			director.set_physics_process(false)
	for spawn_point in _scene.find_children("*", "EnemySpawnPoint", true, false):
		spawn_point.set_process(false)
		spawn_point.set_physics_process(false)
	await _clear_enemies()
	_spawn_golems()
	_add_hint()
	_started = true
	_started_msec = Time.get_ticks_msec()
	process_frame.connect(_tick)


func _spawn_golems() -> void:
	var holder := _scene.get_node_or_null("Enemies")
	for index in COUNT:
		var enemy := Creatures.instantiate({"species": "mud_golem"})
		if enemy == null:
			continue
		enemy.set_meta(&"crowd_seed", 314159 + index)
		var angle := TAU * float(index) / float(COUNT)
		var radius: float = SPAWN_RING[index % SPAWN_RING.size()]
		var x := _player.global_position.x + cos(angle) * radius
		var z := _player.global_position.z + sin(angle) * radius
		enemy.position = Vector3(x, Terrain.height_at(x, z) + 0.6, z)
		enemy.add_to_group("dynamic_enemies")
		if enemy.has_method("set_combat_target"):
			enemy.call("set_combat_target", _player)
		(holder if holder != null else _scene).add_child(enemy)
		_spawned.append(enemy)
	print("[playground] spawned=%d invincible=%s" % [_spawned.size(), _invincible])


func _clear_enemies() -> void:
	for enemy in _spawned:
		if is_instance_valid(enemy):
			enemy.queue_free()
	_spawned.clear()
	for enemy in get_nodes_in_group("enemies"):
		if is_instance_valid(enemy):
			enemy.queue_free()
	for group in ["enemy_projectiles", "enemy_hazards"]:
		for node in get_nodes_in_group(group):
			if is_instance_valid(node) and not node.is_queued_for_deletion():
				node.queue_free()
	for _frame in 4:
		await process_frame


func _restart() -> void:
	if not _started or _restarting:
		return
	_restarting = true
	await _clear_enemies()
	_spawn_golems()
	_started_msec = Time.get_ticks_msec()
	_restarting = false


func _tick() -> void:
	if not _started:
		return
	if Input.is_key_pressed(KEY_F10):
		quit()
		return
	if Input.is_key_pressed(KEY_R):
		_restart()
	if _pressed_once(KEY_F1):
		_ai_on = not _ai_on
		for enemy in _spawned:
			if is_instance_valid(enemy):
				enemy.set("ai_enabled", _ai_on)
		_update_hint()
	if _pressed_once(KEY_F2):
		_frozen = not _frozen
		for enemy in _spawned:
			if is_instance_valid(enemy):
				enemy.process_mode = Node.PROCESS_MODE_DISABLED if _frozen else Node.PROCESS_MODE_INHERIT
		_update_hint()
	if _pressed_once(KEY_F3):
		_shadows_on = not _shadows_on
		for light in _scene.find_children("*", "DirectionalLight3D", true, false):
			(light as DirectionalLight3D).shadow_enabled = _shadows_on
		_update_hint()
	if _pressed_once(KEY_F4):
		_weather_on = not _weather_on
		var timeline := _scene.find_child("WeatherTimeline", true, false)
		if timeline != null:
			timeline.visible = _weather_on
			timeline.set_process(_weather_on)
		for particles in _scene.find_children("*", "GPUParticles3D", true, false):
			(particles as GPUParticles3D).visible = _weather_on
		for particles in _scene.find_children("*", "CPUParticles3D", true, false):
			(particles as CPUParticles3D).visible = _weather_on
		_update_hint()
	if _pressed_once(KEY_F5):
		_post_on = not _post_on
		var post := root.get_node_or_null("PostProcess")
		if post != null:
			post.visible = _post_on
		_update_hint()
	if _probe_seconds > 0.0 and (Time.get_ticks_msec() - _started_msec) / 1000.0 >= _probe_seconds:
		quit()


func _pressed_once(key: Key) -> bool:
	var down := Input.is_key_pressed(key)
	var was := bool(_held.get(key, false))
	_held[key] = down
	return down and not was


func _add_hint() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PlaygroundHint"
	_hint_label = Label.new()
	_hint_label.add_theme_font_size_override("font_size", 16)
	_hint_label.position = Vector2(24, 24)
	_hint_label.modulate = Color(0.95, 0.92, 0.82, 0.9)
	layer.add_child(_hint_label)
	root.add_child(layer)
	_update_hint()


func _update_hint() -> void:
	if _hint_label == null:
		return
	_hint_label.text = ("正式圣所 · 30 只泥土傀儡 · 无敌：%s\n"
		+ "R 重开 · F10 退出\n"
		+ "F1 AI：%s · F2 冻结：%s · F3 阴影：%s · F4 天气粒子：%s · F5 后处理：%s") % [
		"开" if _invincible else "关",
		"开" if _ai_on else "关",
		"是" if _frozen else "否",
		"开" if _shadows_on else "关",
		"开" if _weather_on else "关",
		"开" if _post_on else "关"]
