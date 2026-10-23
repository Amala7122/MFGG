extends SceneTree
## Lab diagnostic: drive the real combat lab through its real generate button,
## wait for the 36-golem horde to actually engage, then record every frame.
## Phases are recorded separately so spawn/countdown spikes cannot be confused
## with steady melee cost.

const Artifacts := preload("res://scripts/artifact_paths.gd")

var _count := 36
var _line_z := -1000.0
var _measure_seconds := 12.0
var _ablate := "none"
var _pre_ablate := "none"
var _player_mode := "idle"
var _cluster := false
var _lab: Node3D
var _player: Node3D
var _rows: Array[Dictionary] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--count="):
			_count = clampi(int(arg.trim_prefix("--count=")), 1, 36)
		elif arg.begins_with("--line-z="):
			_line_z = float(arg.trim_prefix("--line-z="))
		elif arg.begins_with("--measure="):
			_measure_seconds = clampf(float(arg.trim_prefix("--measure=")), 2.0, 60.0)
		elif arg.begins_with("--ablate="):
			_ablate = arg.trim_prefix("--ablate=")
		elif arg.begins_with("--pre-ablate="):
			_pre_ablate = arg.trim_prefix("--pre-ablate=")
		elif arg.begins_with("--player="):
			_player_mode = arg.trim_prefix("--player=")
		elif arg == "--cluster=on":
			_cluster = true
	call_deferred("_run")


func _run() -> void:
	var scene: PackedScene = load("res://prototypes/combat_lab/combat_lab.tscn")
	_lab = scene.instantiate() as Node3D
	if _line_z > -999.0:
		_lab.set("enemy_line_z", _line_z)
	root.add_child(_lab)
	current_scene = _lab
	# 持续 36 只的压力口径：双方都不死，避免人口缩水后帧率自然回升。
	var player_inv := _lab.get("_invincible") as CheckBox
	if player_inv != null:
		player_inv.button_pressed = true
	var enemy_inv := _lab.get("_enemy_invincible") as CheckBox
	if enemy_inv != null:
		enemy_inv.button_pressed = true
	for _frame in 3:
		await process_frame
	_lab.call("set_selection", {"PrototypeMudGolem": _count})
	for _frame in 3:
		await process_frame
	var generate := _lab.get("_generate") as Button
	generate.emit_signal("pressed")

	# Phase 1: generation + countdown, until FIGHTING (enum value 2).
	var phase_start := Time.get_ticks_msec()
	var deadline := phase_start + 30000
	while Time.get_ticks_msec() < deadline and int(_lab.get("state")) != 2:
		_apply_pre_ablation()
		await _sample("countdown")
	var countdown_ms := Time.get_ticks_msec() - phase_start
	if _cluster:
		_cluster_horde()
	# 模拟玩家实际操作：持续射击、前压、绕圈、周期手雷。
	_player = _lab.get("_player") as Node3D
	if _player_mode.contains("shoot"):
		Input.action_press("shoot")
	if _player_mode.contains("move"):
		Input.action_press("move_forward")
	if _player_mode.contains("circle"):
		Input.action_press("move_right")

	# Phase 2: horde approach, until someone is within 4m or 35s pass.
	phase_start = Time.get_ticks_msec()
	deadline = phase_start + 35000
	while Time.get_ticks_msec() < deadline and _nearest_distance() > 4.0:
		await _sample("approach")
	var approach_ms := Time.get_ticks_msec() - phase_start
	var contact_distance := _nearest_distance()

	_apply_ablation()
	for _frame in 30:
		await process_frame

	# Phase 3: steady melee.
	phase_start = Time.get_ticks_msec()
	deadline = phase_start + int(_measure_seconds * 1000.0)
	var pulse := 0
	while Time.get_ticks_msec() < deadline:
		pulse += 1
		if _player_mode.contains("circle") and is_instance_valid(_player):
			_player.set("target_yaw", float(_player.get("target_yaw")) + 0.02)
		if _player_mode.contains("grenade") and pulse % 20 == 0:
			Input.action_press("grenade")
			await process_frame
			Input.action_release("grenade")
		await _sample("melee")
	var melee_ms := Time.get_ticks_msec() - phase_start
	Input.action_release("shoot")
	Input.action_release("grenade")
	Input.action_release("move_forward")
	Input.action_release("move_right")

	var screenshot := await _capture()
	var summary := _summary(countdown_ms, approach_ms, melee_ms, contact_distance, screenshot)
	var path := Artifacts.ensure_dir("reports").path_join("combat_fight.json")
	var handle := FileAccess.open(path, FileAccess.WRITE)
	handle.store_string(JSON.stringify(summary, "  "))
	handle.close()
	_write_csv()
	print("[combat fight] ", JSON.stringify(summary))
	var melee_phase: Dictionary = summary["phases"]["melee"]
	quit(0 if int(melee_phase["frames"]) > 0 else 1)


func _sample(phase: String) -> void:
	var before := Time.get_ticks_usec()
	await process_frame
	var now := Time.get_ticks_usec()
	var enemies: Array = _lab.get("_live_enemies")
	var alive := 0
	var attackers := 0
	for enemy in enemies:
		if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
			alive += 1
			if int(enemy.get("current_state")) == 2:
				attackers += 1
	_rows.append({
		"phase": phase,
		"ms": float(now - before) / 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"batch_cells": _batch_cells(),
		"alive": alive,
		"attackers": attackers,
		"nearest": _nearest_distance(),
	})


func _batch_cells() -> int:
	var batch: Node = _lab.get_node_or_null("MudGolemRenderBatch")
	return int(batch.call("batch_count")) if batch != null else 0


func _nearest_distance() -> float:
	var player: Node3D = _lab.get("_player") as Node3D
	if player == null:
		return 9999.0
	var closest := 9999.0
	for enemy in _lab.get("_live_enemies"):
		if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
			closest = minf(closest, player.global_position.distance_to((enemy as Node3D).global_position))
	return closest


func _cluster_horde() -> void:
	var player: Node3D = _lab.get("_player") as Node3D
	if player == null:
		return
	var center := player.global_position + Vector3(0, 0, -6)
	var enemies: Array = _lab.get("_live_enemies")
	var index := 0
	for enemy in enemies:
		if not is_instance_valid(enemy):
			continue
		var angle := TAU * float(index) / maxf(float(enemies.size()), 1.0) + 0.3
		var radius := 1.2 + 0.45 * float(index % 8)
		var point := center + Vector3(cos(angle), 0.0, sin(angle)) * radius
		(enemy as Node3D).global_position = Vector3(point.x, (enemy as Node3D).global_position.y, point.z)
		enemy.set("velocity", Vector3.ZERO)
		index += 1


func _apply_pre_ablation() -> void:
	if _pre_ablate == "ai":
		for enemy in _lab.get("_live_enemies"):
			if is_instance_valid(enemy):
				enemy.set("ai_enabled", false)
	elif _pre_ablate == "ui":
		var interface: CanvasItem = _lab.get("_interface") as CanvasItem
		if interface != null:
			interface.visible = false
	elif _pre_ablate == "stats":
		var stats: RefCounted = _lab.get("_stats") as RefCounted
		if stats != null:
			stats.set("active", false)
	elif _pre_ablate == "observer":
		var observer: Node = _lab.get("_attack_observer") as Node
		if observer != null:
			observer.set("enabled", false)
			observer.set("study", false)
			observer.visible = false


func _apply_ablation() -> void:
	if _ablate == "none":
		return
	for enemy in _lab.get("_live_enemies"):
		if not is_instance_valid(enemy):
			continue
		if _ablate == "ai":
			enemy.set("ai_enabled", false)
		elif _ablate == "physics":
			enemy.process_mode = Node.PROCESS_MODE_DISABLED
	if _ablate == "observer":
		var observer: Node = _lab.get("_attack_observer") as Node
		if observer != null:
			observer.set("enabled", false)
			observer.set("study", false)
			observer.visible = false
	elif _ablate == "stats":
		var stats: RefCounted = _lab.get("_stats") as RefCounted
		if stats != null:
			stats.set("active", false)


func _summary(countdown_ms: int, approach_ms: int, melee_ms: int,
		contact_distance: float, screenshot: String) -> Dictionary:
	var result := {
		"count": _count, "line_z": _line_z, "ablation": _ablate,
		"pre_ablation": _pre_ablate, "player_mode": _player_mode,
		"cluster": _cluster,
		"countdown_ms": countdown_ms, "approach_ms": approach_ms,
		"melee_ms": melee_ms, "contact_distance": contact_distance,
		"screenshot": screenshot, "phases": {},
	}
	for phase in ["countdown", "approach", "melee"]:
		var values: Array[float] = []
		var physics := 0.0
		var process := 0.0
		var draws := 0.0
		var nodes := 0.0
		var attackers := 0
		var alive := 0
		var nearest := 9999.0
		for row in _rows:
			if row.phase != phase:
				continue
			values.append(row.ms)
			physics += row.physics_ms
			process += row.process_ms
			draws += row.draw_calls
			nodes += row.nodes
			attackers = maxi(attackers, row.attackers)
			alive = maxi(alive, row.alive)
			nearest = minf(nearest, row.nearest)
		values.sort()
		var total := 0.0
		for value in values:
			total += value
		var count := values.size()
		var worst: float = values.back() if count > 0 else 0.0
		result.phases[phase] = {
			"frames": count,
			"avg_ms": total / maxf(float(count), 1.0),
			"p50_ms": values[count / 2] if count > 0 else 0.0,
			"p95_ms": values[clampi(ceili(float(count) * 0.95) - 1, 0, maxi(count - 1, 0))] if count > 0 else 0.0,
			"max_ms": worst,
			"min_fps": 1000.0 / maxf(worst, 0.001),
			"over_33ms": _count_over(values, 33.3),
			"over_50ms": _count_over(values, 50.0),
			"physics_ms": physics / maxf(float(count), 1.0),
			"process_ms": process / maxf(float(count), 1.0),
			"draw_calls": int(draws / maxf(float(count), 1.0)),
			"nodes": int(nodes / maxf(float(count), 1.0)),
			"attackers_peak": attackers,
			"alive_peak": alive,
			"nearest_m": nearest,
		}
	return result


func _count_over(values: Array[float], limit: float) -> int:
	var count := 0
	for value in values:
		if value > limit:
			count += 1
	return count


func _write_csv() -> void:
	var path := Artifacts.ensure_dir("reports").path_join("combat_fight_frames.csv")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_line("phase,ms,physics_ms,process_ms,draw_calls,nodes,batch_cells,alive,attackers,nearest")
	for row in _rows:
		file.store_line("%s,%.3f,%.3f,%.3f,%d,%d,%d,%d,%d,%.3f" % [
			row.phase, row.ms, row.physics_ms, row.process_ms, row.draw_calls,
			row.nodes, row.batch_cells, row.alive, row.attackers, row.nearest])
	file.close()


func _capture() -> String:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		return ""
	var path := Artifacts.ensure_dir("screenshots").path_join("combat_fight_%d.png" % _count)
	return path if image.save_png(path) == OK else ""
