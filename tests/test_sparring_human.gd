extends SceneTree
## 自动注入只验证真人输入通路；明确标 synthetic_input_contract，不冒充玩家样本。
const Lab := preload("res://prototypes/sparring_lab/combat_sparring_lab.tscn")
const Human := preload("res://tools/probes/sparring/sparring_human_data.gd")
const Inputs := preload("res://tools/probes/sparring/sparring_input.gd")
const Imitation := preload("res://tools/probes/sparring/sparring_imitation.gd")
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var _failures := 0

class ContextImitation extends "res://tools/probes/sparring/sparring_imitation.gd":
	var shown: Dictionary
	func public_context(_player: Node3D, _boss: Node3D) -> Dictionary:
		return shown.duplicate()

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _context() -> Dictionary:
	return {"visible": true, "visible_count": 1, "danger": false, "distance": 10.0, "target_yaw": 0.0, "target_pitch": 0.0,
		"health_ratio": 1.0, "shield_ratio": 1.0, "ammo_empty": false, "reloading": false, "rolling": false,
		"dodge_ready": true, "locked": false, "danger_age": 0.0, "warning_key": "", "warning_progress": 0.0}

func _logic() -> void:
	var frames: Array = []
	for index in range(600):
		var context := _context()
		context.warning_key = "test_warning" if index >= 300 and index < 360 else ""
		context.danger = index >= 300 and index < 360
		context.danger_age = (index - 300) / 60.0 if context.danger else 0.0
		frames.append({"schema": 2, "frame": index, "time": index / 60.0, "delta": 1.0 / 60, "held": {"shoot": true},
			"just": {"dodge": index == 318}, "move": [1.0, 0.0], "yaw": 0.01 * index, "pitch": 0.0,
			"aim_captured": true, "context": context, "position": [index / 60.0, 0, 0]})
	var report := {"conditions": {"mode": "manual", "capture_origin": "synthetic_input_contract", "participant": {"id": "fixture_not_a_player"}}, "analysis": {"eligible_for_balance": false}}
	var summary := Human.summarize(report, frames, [])
	_check(summary.origin == "synthetic_input_contract" and absf(summary.movement.horizontal_path_m - 599.0 / 60) < 0.01, "区分来源，并用实际位置而非移动键估路程")
	_check(absf(float(summary.response.eligible_dodge_request_delay_seconds.p50) - 0.3) < 0.001, "响应定义为公开预警到请求的间隔，保留其明确单位")
	var model := Human.fit(report, frames, {"complete_contract": true})
	var paused_turns := frames.duplicate(true)
	for index in range(paused_turns.size()):
		paused_turns[index].move = [1.0 if index < 100 or index >= 400 else -1.0 if index >= 200 and index < 300 else 0.0,0.0]
	var turns_summary := Human.summarize(report,paused_turns,[])
	_check(turns_summary.movement.lateral_input_side_changes == 2 and turns_summary.movement.direction_reversals == 0,"隔松键左右换边与相邻帧急反转分别计数，不能漏记真人往返")
	_check(Human.model_problem(model).is_empty(), "新版录制可生成结构有效的情境模型")
	_check(model.validation.split == "last_quarter_time_block_with_1s_gap" and not model.validation.independent_session, "时间块留出不能冒充独立真人局验证")
	for chunk: Dictionary in model.chunks:
		_check(float(chunk.start) + Human.CHUNK_SECONDS < float(frames[-1].time) * 0.75 - 1.0, "留出数据及保护间隔不能泄入拟合")
	_check(not Inputs.problem(frames[1], 0).is_empty(), "乱序／缺帧不能通过输入合同")
	var broken: Dictionary = frames[0].duplicate(true)
	broken.aim_captured = "true"
	_check(not Inputs.problem(broken, 0).is_empty(), "捕获状态必须有类型保证")
	var no_response := frames.duplicate(true)
	for row: Dictionary in no_response:
		row.just = {}
	var censored := Human.summarize(report, no_response, [])
	_check(censored.response.no_observed_dodge_request == 1 and censored.response.eligible_dodge_request_delay_seconds.n == 0, "未响应保留，不记零延迟也不凭空推反应慢")
	var legacy := frames.duplicate(true)
	legacy[0].erase("aim_captured")
	_check(Human.fit(report, legacy, {"complete_contract": false}).is_empty(), "旧记录只分析已有字段，不补造可模拟模型")

func _start(options: Dictionary) -> Node:
	paused = false
	var world := Lab.instantiate()
	world.run_options = options
	root.add_child(world)
	current_scene = world
	for _frame in range(1200):
		await process_frame
		if is_instance_valid(world.session) and (world.session.running or not world.session.result.is_empty()):
			return world
	_check(false, "真人数据测试能启动正式实战场景")
	return world

func _clear(world: Node) -> void:
	paused = false
	current_scene = null
	world.queue_free()
	for _frame in range(5):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)

func _capture_panel(session: Node) -> void:
	if not OS.get_cmdline_user_args().has("--capture") or DisplayServer.get_name() == "headless":
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var destination := Artifacts.ensure_dir("screenshots", "human").path_join("recording_controls.png")
	_check(root.get_texture().get_image().save_png(destination) == OK, "真人录制面板截图保存成功")

func _run() -> void:
	_logic()
	var world: Node = await _start({"mode": "manual", "capture_origin": "synthetic_input_contract", "participant": {"id": "injected_A", "style_label": "fixture_circle"},
		"scenario_id": "sanctum_mixed", "group_id": "mixed_patrol", "group_selection": {"L1MeleeSoldier": 1, "L1ScoutGunner": 1}, "profile_id": "reactive", "seed": 10420261014, "observation_seconds": 8.0, "autostart": true})
	var session: Node = world.session
	var source := ""
	if is_instance_valid(session) and session.running:
		var index := 0
		while session.running and index < 600:
			for action: String in ["shoot", "aim", "sprint", "move_left", "move_right", "free_look", "dodge", "grenade", "skill", "reload", "jump"]:
				Input.action_release(action)
			Input.action_press("shoot")
			Input.action_press("move_left" if index % 120 < 60 else "move_right")
			if index % 180 < 60:
				Input.action_press("aim")
			for pair: Array in [[45, "dodge"], [110, "grenade"], [180, "skill"], [250, "reload"], [320, "jump"]]:
				if index == int(pair[0]):
					Input.action_press(String(pair[1]))
			MouseControl.mode = Input.MOUSE_MODE_VISIBLE if index >= 200 and index < 240 else Input.MOUSE_MODE_CAPTURED
			var event := InputEventMouseMotion.new()
			event.relative = Vector2(0.2, 0)
			session.actor.call("_input", event)
			index += 1
			await physics_frame
		for action: String in ["shoot", "aim", "sprint", "move_left", "move_right", "dodge", "grenade", "skill", "reload", "jump"]:
			Input.action_release(action)
		if session.running:
			session.finish("test_budget")
		await _capture_panel(session)
		source = session.recorder.directory
		var input := Inputs.read(source.path_join("inputs.jsonl"))
		_check(input.complete_contract and input.frames.size() > 200, "真人正式输入通路逐物理帧保存完整步长与捕获状态")
		_check(input.frames.any(func(row: Dictionary): return not bool(row.aim_captured)), "鼠标释放期间不能被重放为仍可开火")
		_check(session.result.human_behavior.attack.action_requests.get("grenade", 0) > 0 and session.result.human_behavior.movement.horizontal_path_m > 0, "分析实际采集的技能请求与位移")
		_check(FileAccess.file_exists(source.path_join("human_model.json")), "真人模式结束保存可复用模型，但注入来源标记保留")
		var reviewed := Human.review(source)
		_check(reviewed.summary.origin == "synthetic_input_contract" and not reviewed.model.source_eligible, "自动注入不能伪称有效真人平衡数据")
		var driver := ContextImitation.new()
		driver.setup(Settings.resolve().profile, 1)
		var piece: Dictionary = reviewed.model.chunks[0].duplicate(true)
		piece.context = _context()
		piece.frames = piece.frames.slice(0, 2)
		for row: Dictionary in piece.frames:
			row.just = {}
		piece.frames[0].just.grenade = true
		driver.model = {"chunks": [piece]}
		driver.shown = _context()
		var presses := 0
		for _tick in range(6):
			var output: Dictionary = driver.step(session.actor, null, 0.005)
			presses += int(bool(output.just.get("grenade", false)))
		_check(presses == 1, "重采样不能把一个手雷请求重复成每个物理帧都按")
		driver.shown.visible = false
		var unsupported: Dictionary = driver.step(session.actor, null, 0.016)
		_check(unsupported.activity == "imitation_uncovered" and unsupported.held.is_empty(), "未覆盖情境必须显式中性，不偷换自动高手")
		_check(not Human.replay_options(source).is_empty(), "真人录制可生成源条件与版本核对后的重放入口")
	await _clear(world)
	if not source.is_empty():
		var replay_options := Human.replay_options(source)
		world = await _start(replay_options)
		session = world.session
		for _tick in range(1200):
			await process_frame
			if not session.running:
				break
		var replay_audit: Dictionary = session.result.get("analysis", {}).get("replay_audit", {})
		_check(replay_audit.get("status", "") in ["diverged", "matched_observed_checkpoints", "unverified_source_contract"], "实际真人输入重放必须核对状态或明确报源条件不完整")
		_check(session.result.actor_origin == "input_replay" and not session.result.analysis.eligible_for_balance, "原局回放不增加真人／平衡样本")
		await _clear(world)
		world = await _start({"mode": "imitate", "model_path": source.path_join("human_model.json"), "scenario_id": "sanctum_mixed", "group_id": "melee_patrol", "profile_id": "reactive", "seed": 10420261015, "observation_seconds": 2.0, "autostart": true})
		session = world.session
		for _tick in range(1000):
			await process_frame
			if not session.running:
				break
		_check(not session.result.is_empty() and session.result.actor_origin == "empirical_simulation", "经验模型能在另一正式敌人组中实际驱动玩家")
		_check(not session.result.analysis.eligible_for_balance and session.result.analysis.has("imitation_audit"), "未验证模型有覆盖报告且不自动进入真人／正常难度统计")
		var manifest := Artifacts.ensure_dir("tmp", "human_contract").path_join("dataset_manifest.json")
		var file := FileAccess.open(manifest, FileAccess.WRITE)
		file.store_string(JSON.stringify({"recordings": [source, source, session.recorder.directory]}))
		file.close()
		var dataset := Human.dataset(manifest)
		_check(dataset.duplicates_excluded == 1 and dataset.eligible_human_cohorts.is_empty(), "重复文件、自动注入与模拟不能增加真人样本数")
		await _clear(world)
	print("[真人录制／分析／经验模拟] failures=", _failures)
	quit(0 if _failures == 0 else 1)
