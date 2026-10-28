extends SceneTree
## 庭院回归探针：玩家在围墙外 (27.9,-35.9)，默认 100 体出生在墙内，测 10 秒。
##
## 量化四类用户可见问题，供修复前/后同条件对照：
##   - 运行期位置跳变（瞬移/被搬出墙）：单步位移 > 0.5m
##   - 无故上下移动：单步竖直位移 > 0.2m 而水平位移 < 0.02m
##   - 身体/手臂贴墙穿模：胶囊与 static 几何重叠、左右手方向 0.95m 射线命中
##   - 是否真的从开口绕出去：4m 内数量、仍在墙内数量、终局每秒进展
##
## 只读诊断：不改地图、波次与正式参数。变体：
##   current（100 体）、solo（1 体）、squad（10 体）、
##   long（1200 步，看队伍是否持续排空）、queue_on（手动让行实验，默认关）。

const Artifacts := preload("res://scripts/artifact_paths.gd")
const MainScene := preload("res://scenes/sanctum_main.tscn")
const FodderScript := preload("res://scripts/prototypes/fodder_field.gd")
const NavDataset := preload("res://scripts/navigation/nav_dataset.gd")
const NAV_PATH := "res://data/navigation/sanctum_nav.json"
const Terrain := preload("res://scripts/terrain_field.gd")

const AMOUNT := 100
const PLAYER_POINT := Vector2(27.9, -35.9)
const SPAWN_ORIGIN := Vector2(19.0, -32.5)
const SPAWN_STEP := 0.68
const STEPS := 600
const SAMPLE_INTERVAL := 3
const JUMP_LIMIT := 0.5
const VERTICAL_LIMIT := 0.2
const ARM_REACH := 0.95
const ARM_EXTENT := 0.761
const ARM_HEIGHT := 0.62
const BODY_RADIUS := 0.76
const NEAR_DISTANCE := 4.0
const INTERIOR := Rect2(18.5, -33.5, 9.0, 9.5)

var _variant := "current"
var _point := PLAYER_POINT
var _amount := AMOUNT
var _steps := STEPS
var _field
var _failures: Array[String] = []


func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--variant="):
			_variant = argument.trim_prefix("--variant=")
		elif argument.begins_with("--point="):
			var parts := argument.trim_prefix("--point=").split(",")
			if parts.size() == 2:
				_point = Vector2(float(parts[0]), float(parts[1]))
	# 单体/10 体走同一个开口，验证不是靠人数和挤位碰巧出来的。
	match _variant:
		"solo":
			_amount = 1
		"squad":
			_amount = 10
		"long":
			_steps = 1200
	call_deferred("_run")


func _fail(text: String) -> void:
	_failures.append(text)
	push_error(text)


func _run() -> void:
	paused = false
	var menu := MainScene.instantiate()
	root.add_child(menu)
	current_scene = menu
	for _frame in 3:
		await process_frame
	var game_flow := root.get_node_or_null("GameFlow")
	if game_flow == null:
		_fail("GameFlow 存在")
		_finish()
		return
	game_flow.call("start_run")
	for _frame in 360:
		await process_frame
		if current_scene != null and current_scene != menu \
				and not get_nodes_in_group("player").is_empty() \
				and not bool(game_flow.get("_preparing_run")):
			break
	var scene := current_scene as Node3D
	if scene == null or get_nodes_in_group("player").is_empty():
		_fail("正式场景与玩家就绪")
		_finish()
		return
	var player := get_nodes_in_group("player")[0] as Node3D
	player.set_meta(&"experiment_invincible", true)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	for director_name in ["WaveDirector", "SurvivalDirector"]:
		var director := scene.find_child(director_name, true, false)
		if director != null:
			director.set_process(false)
			director.set_physics_process(false)
	for enemy in get_nodes_in_group("enemies"):
		enemy.queue_free()
	for _frame in 2:
		await process_frame

	player.global_position = Vector3(_point.x,
		Terrain.height_at(_point.x, _point.y) + 0.2, _point.y)
	var arm_extent := ARM_EXTENT
	_field = FodderScript.new()
	_field.top_level = true
	scene.add_child(_field)
	var nav := NavDataset.load_file(NAV_PATH)
	_field.setup(player, null, _amount, player.global_position,
		NavDataset.load_profile(nav), nav)
	if _variant == "queue_on":
		# 手动实验：门洞/接战让行（默认关，A/B 见任务记录）。
		_field.queue_pacing = true
	var waited := 0
	while not bool(_field.get("_flow_ready")) and waited < 900:
		await physics_frame
		waited += 1
	if not bool(_field.get("_flow_ready")):
		_fail("流场在 900 物理步内就绪")
		_finish()
		return

	var surface = _field.get("_surface")
	var body_offset: float = _field.get("BODY_OFFSET")
	var spawn_blocked := 0
	var spawn_unreachable := 0
	if _variant == "point":
		# 用 field.setup 自带的出生环：测“就地刷 100 只”的真实情况。
		for index in _amount:
			var p: Vector3 = _field._positions[index]
			if surface.blocked_at(p.x, p.z):
				spawn_blocked += 1
			if not _field.flow.is_reachable(p):
				spawn_unreachable += 1
	else:
		for index in _amount:
			var x := SPAWN_ORIGIN.x + float(index % 10) * SPAWN_STEP
			var z := SPAWN_ORIGIN.y + float(index / 10) * SPAWN_STEP
			if _variant == "solo":
				x = SPAWN_ORIGIN.x
				z = SPAWN_ORIGIN.y
			elif _variant == "squad":
				x = SPAWN_ORIGIN.x + float(index) * SPAWN_STEP
				z = SPAWN_ORIGIN.y
			var ground: float = surface.nav_height_at(x, z)
			_field._positions[index] = Vector3(x, ground + body_offset, z)
			_field._last_positions[index] = _field._positions[index]
			_field._ground_heights[index] = ground
			_field._velocity[index] = Vector3.ZERO
			_field._state[index] = 0
			_field._stuck_count[index] = 0
			_field._timer[index] = 0.0
			if surface.blocked_at(x, z):
				spawn_blocked += 1
			if not _field.flow.is_reachable(_field._positions[index]):
				spawn_unreachable += 1

	var initial_unstuck: int = _field.unstuck_count
	var space: PhysicsDirectSpaceState3D = _field.get_world_3d().direct_space_state
	var body_shape := CapsuleShape3D.new()
	body_shape.radius = BODY_RADIUS
	body_shape.height = 1.6
	var body_query := PhysicsShapeQueryParameters3D.new()
	body_query.shape = body_shape
	body_query.collision_mask = 1
	body_query.collide_with_areas = false
	body_query.collide_with_bodies = true

	var previous: PackedVector3Array = _field._positions.duplicate()
	var second_ago: PackedVector3Array = _field._positions.duplicate()
	var jump_count := 0
	var max_jump := 0.0
	var vertical_count := 0
	var arm_clip_frames := 0
	var arm_max_penetration := 0.0
	var body_overlap_frames := 0
	var frame_usec: Array[int] = []
	var physics_usec: Array[int] = []
	var samples: Array[Dictionary] = []
	var tracks: Array[Dictionary] = []
	var ever_near := PackedByteArray()
	ever_near.resize(_amount)
	for step in _steps:
		var started := Time.get_ticks_usec()
		await physics_frame
		frame_usec.append(Time.get_ticks_usec() - started)
		physics_usec.append(int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0))
		var positions: PackedVector3Array = _field._positions
		var check_geometry := step % SAMPLE_INTERVAL == 0
		for index in _amount:
			var delta_position := positions[index] - previous[index]
			var flat := Vector2(delta_position.x, delta_position.z).length()
			if delta_position.length() > JUMP_LIMIT:
				jump_count += 1
				max_jump = maxf(max_jump, delta_position.length())
			if absf(delta_position.y) > VERTICAL_LIMIT and flat < 0.02:
				vertical_count += 1
			if not check_geometry:
				continue
			body_query.transform = Transform3D(Basis(), positions[index] + Vector3.UP * 0.2)
			var overlaps := space.intersect_shape(body_query, 1)
			if not overlaps.is_empty():
				var rest := space.get_rest_info(body_query)
				var normal: Vector3 = rest.get("normal", Vector3.UP)
				if absf(normal.y) < 0.7:
					body_overlap_frames += 1
			var yaw: float = _field._yaw[index]
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var origin := positions[index] + Vector3.UP * ARM_HEIGHT
			for side in [-1.0, 1.0]:
				var ray := PhysicsRayQueryParameters3D.create(
					origin, origin + right * side * ARM_REACH, 1)
				var hit := space.intersect_ray(ray)
				if hit.is_empty():
					continue
				var depth := arm_extent - origin.distance_to(hit.position)
				if depth > 0.02:
					arm_clip_frames += 1
					arm_max_penetration = maxf(arm_max_penetration, depth)
		previous = positions.duplicate()
		if (step + 1) % 60 == 0:
			var near := 0
			var interior := 0
			for index in _amount:
				var position: Vector3 = positions[index]
				if Vector2(position.x - _point.x, position.z - _point.y).length() \
						<= NEAR_DISTANCE:
					near += 1
					ever_near[index] = 1
				if INTERIOR.has_point(Vector2(position.x, position.z)):
					interior += 1
			samples.append({"step": step + 1, "near4": near, "interior": interior})
			# 最后一秒的采样不要覆盖 second_ago，否则终局“每秒进展”恒为 0。
			if step + 1 < _steps:
				second_ago = positions.duplicate()
			for track_index in [0, 24, 49, 74, 99]:
				if track_index >= _amount:
					continue
				var track_position: Vector3 = positions[track_index]
				var flow_direction := Vector3.ZERO
				if _field.flow != null:
					flow_direction = _field.flow.direction_at(track_position)
				tracks.append({
					"step": step + 1, "index": track_index,
					"x": track_position.x, "y": track_position.y, "z": track_position.z,
					"flow_x": flow_direction.x, "flow_z": flow_direction.z,
					"slot": int(_field._slot_ok[track_index]),
					"stuck": int(_field._stuck_count[track_index]),
					"blocked": bool(_field._surface.blocked_at(track_position.x, track_position.z)),
				})

	var final_positions: PackedVector3Array = _field._positions
	var near_final := 0
	var interior_final := 0
	var blocked_final := 0
	var stalled_final := 0
	var ever_near_count := 0
	var final_dump: Array[Dictionary] = []
	for index in _amount:
		var position: Vector3 = final_positions[index]
		if Vector2(position.x - _point.x, position.z - _point.y).length() \
				<= NEAR_DISTANCE:
			near_final += 1
		if INTERIOR.has_point(Vector2(position.x, position.z)):
			interior_final += 1
		if _field.is_position_blocked(position):
			blocked_final += 1
		if ever_near[index] != 0:
			ever_near_count += 1
		var moved := position.distance_to(second_ago[index])
		if moved < 0.3 and Vector2(position.x - _point.x,
				position.z - _point.y).length() > NEAR_DISTANCE:
			stalled_final += 1
		var flow_here := Vector3.ZERO
		if _field.flow != null:
			flow_here = _field.flow.direction_at(position)
		final_dump.append({
			"index": index, "x": position.x, "y": position.y, "z": position.z,
			"flow_x": flow_here.x, "flow_z": flow_here.z,
			"moved_1s": moved,
			"slot": int(_field._slot_ok[index]),
			"stuck": int(_field._stuck_count[index]),
			"state": int(_field._state[index]),
			"blocked": bool(_field._surface.blocked_at(position.x, position.z)),
			"walk": _field._surface.nav_height_at(position.x, position.z),
			"terrain": Terrain.height_at(position.x, position.z),
			"slope": rad_to_deg(acos(clampf(Terrain.normal_at(position.x, position.z).y,
				-1.0, 1.0))),
		})
	frame_usec.sort()
	var median := frame_usec[frame_usec.size() / 2] if not frame_usec.is_empty() else 0
	var p95_index := mini(frame_usec.size() - 1, int(float(frame_usec.size()) * 0.95))
	var p95 := frame_usec[p95_index] if not frame_usec.is_empty() else 0
	physics_usec.sort()
	var physics_median := physics_usec[physics_usec.size() / 2] if not physics_usec.is_empty() else 0
	var physics_p95 := physics_usec[mini(physics_usec.size() - 1,
		int(float(physics_usec.size()) * 0.95))] if not physics_usec.is_empty() else 0
	var report := {
		"variant": _variant,
		"amount": _amount,
		"steps": _steps,
		"spawn_blocked_cells": spawn_blocked,
		"spawn_unreachable": spawn_unreachable,
		"unstuck_delta": int(_field.unstuck_count) - initial_unstuck,
		"jumps_over_0_5m": jump_count,
		"max_single_step_m": max_jump,
		"vertical_only_jumps": vertical_count,
		"arm_clip_unit_frames": arm_clip_frames,
		"arm_max_penetration_m": arm_max_penetration,
		"body_overlap_unit_frames": body_overlap_frames,
		"final_near4": near_final,
		"final_interior": interior_final,
		"final_blocked_cells": blocked_final,
		"final_stalled": stalled_final,
		"ever_near4": ever_near_count,
		"frame_usec_median": median,
		"frame_usec_p95": p95,
		"physics_usec_median": physics_median,
		"physics_usec_p95": physics_p95,
		"samples": samples,
		"tracks": tracks,
		"final": final_dump,
	}
	var directory := Artifacts.ensure_dir("reports")
	var path := directory.path_join("courtyard_%s.json" % _variant)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("报告写入：%s" % path)
	else:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print("[courtyard] " + JSON.stringify(report))
	_field.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	print("[courtyard] ", "PASS" if _failures.is_empty() else "FAIL", " variant=", _variant)
	quit(0 if _failures.is_empty() else 1)
