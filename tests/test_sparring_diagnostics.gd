extends SceneTree
## 负向验收：系统必须发现被故意制造的停摆，并避免把正常蓄力误报。
const Analysis := preload("res://tools/probes/sparring/sparring_analysis.gd")
const Capture := preload("res://tools/probes/sparring/sparring_capture.gd")
const Lab := preload("res://prototypes/boss_lab/titan_sparring_lab.tscn")
const Batch := preload("res://tools/probes/titan_sparring.gd")
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _run() -> void:
	var ground_rows: Array = []
	for index in range(6):
		ground_rows.append({"time": index * 0.1, "frame": index, "engine_frame": index, "boss_position": [index, 0, 0], "player_position": [0, -1, 0],
			"state": 1, "boss_hp": 100, "player_hp": 100, "player": {"terrain_height": 0, "on_floor": false, "contacts": []}, "diagnostic": {"physics_enabled": true}})
	var ground_result := Analysis.analyze(ground_rows, [], "player_dead")
	_check(not ground_result.eligible_for_balance and ground_result.incidents.any(func(item: Dictionary): return item.kind == "player_below_terrain"), "玩家穿地也必须排除正常胜率，不能只观察Boss")
	for row: Dictionary in ground_rows:
		row.player_position[1] = 1.0
	_check(Analysis.analyze(ground_rows, [], "player_dead").incidents.is_empty(), "正常地上位置不误报穿地")
	var rescued := Analysis.analyze(ground_rows, [{"time": 0.5, "kind": "player_recovered", "details": {"from": [0,-15,0], "to": [0,1,0]}}], "player_dead")
	_check(not rescued.eligible_for_balance and rescued.incidents[0].kind == "player_recovered", "即使快照错过跌落也保留实际回拉事件")
	var old_jump := [{"time": 1.0, "player_position": [0,-14,0]}, {"time": 1.1, "player_position": [0,1.8,0]}]
	_check(Analysis._player_ground_incidents(old_jump, []).any(func(item: Dictionary): return item.kind == "player_position_discontinuity"), "旧录像缺少地面高度时仍能定位16米回拉，不臆造根因")
	var rows: Array = []
	var events: Array = []
	for tick in range(21):
		var now := float(tick) * 0.5
		rows.append({"time": now, "frame": tick, "engine_frame": tick, "boss_position": [0, 0, 0], "player_position": [0, 0, 10],
			"state": 1, "boss_hp": 1000.0 - tick * 10, "player_hp": 100,
			"diagnostic": {"physics_enabled": true, "trace": {"branch": "navigation_override"}, "navigation": {"status": "checking", "job_pending": true}}})
		events.append({"time": now, "kind": "boss_damage", "details": {"damage": 10}})
	var result := Analysis.analyze(rows, events, "boss_dead")
	_check(result.sample_validity == "needs_review" and not result.eligible_for_balance, "无进展却持续受伤的异常胜利不能进入正常统计")
	_check(result.incidents.size() == 1 and result.incidents[0].cause.code == "navigation_plan_wait", "实际导航等待分支能从异常片段定位")
	var moving := rows.duplicate(true)
	for row: Dictionary in moving:
		row.boss_position[0] = float(row.time)
	_check(Analysis.analyze(moving, events, "boss_dead").incidents.is_empty(), "正常移动不能仅因未命中而判卡死")
	var winding := rows.duplicate(true)
	for row: Dictionary in winding:
		row.state = 7
	_check(Analysis.analyze(winding, events, "boss_dead").incidents.is_empty(), "正常蓄力与非行动奖励状态不误报")
	var repeated := events.duplicate(true)
	for at: float in [2, 4, 6, 8]:
		repeated.append({"time": at, "kind": "boss_attack", "details": {}})
	repeated.sort_custom(func(a: Dictionary, b: Dictionary): return float(a.time) < float(b.time))
	_check(Analysis.analyze(rows, repeated, "boss_dead").incidents.is_empty(), "持续正常起招的站桩输出不误报")
	var legacy := rows.duplicate(true)
	for row: Dictionary in legacy:
		row.erase("diagnostic")
	result = Analysis.analyze(legacy, events, "boss_dead")
	_check(result.incidents[0].cause.code == "missing_cause_evidence", "旧实录不能补造根因")
	var auditor := Capture.new()
	auditor.replay_audit = {"status": "checking"}
	auditor._reference_available = true
	auditor._reference = {1: rows[1]}
	auditor._check_replay(rows[1])
	_check(int(auditor.replay_audit.get("matched_checkpoints", 0)) == 1, "一致检查点可以核对通过")
	var diverged: Dictionary = rows[1].duplicate(true)
	diverged.boss_position[0] = 3.0
	auditor._check_replay(diverged)
	_check(auditor.replay_audit.status == "diverged" and int(auditor.replay_audit.first_frame) == 1, "重放状态偏离必须记录首个超差检查点")
	var replay_analysis := Analysis.analyze(moving, events, "replay_diverged")
	Analysis.apply_replay_audit(replay_analysis, auditor.replay_audit, true)
	_check(replay_analysis.sample_validity == "replay_diverged" and not replay_analysis.eligible_for_balance, "离线重新分析不能把偏离重放洗成正常战斗样本")
	var incomplete := Capture.new()
	incomplete.replay_audit = {"status": "checking", "matched_checkpoints": 1}
	incomplete._reference = {1: rows[1], 2: rows[2]}
	_check(incomplete.finish([], "interrupted").replay_audit.status == "unverified_incomplete_checkpoints", "提前结束且只核对部分检查点不能判重放通过")
	_check(not Batch.comparison_rejection({"analysis": {"eligible_for_balance": false}}, {}).is_empty(), "异常或未审计样本不能悄悄参与版本配对")

	# 实际正式场景：只有故障注入改动 Boss 处理开关，陪练仍真实开火与判定。
	var world := Lab.instantiate()
	world.run_options = {"profile_id": "reactive", "seed": 10420261014, "autostart": true, "observation_seconds": 12,
		"diagnostics": {"stall_seconds": 1.0, "context_seconds": 1.0, "snapshot_interval": 0.05}}
	root.add_child(world)
	current_scene = world
	var session: Node
	for _frame in range(1200):
		await process_frame
		if is_instance_valid(world.session) and world.session.running:
			session = world.session
			break
	_check(session != null, "诊断负向测试能启动正式场景")
	if session != null:
		var position_before: Vector3 = session.boss.global_position
		var state_before: int = session.boss.current_state
		var cooldowns_before: Dictionary = session.boss._brain.cooldowns.duplicate()
		var path_requests_before: int = session.boss._steering.path_requests
		session.boss.get_sparring_diagnostic()
		session.boss.get_sparring_diagnostic()
		_check(session.boss.global_position == position_before and int(session.boss.current_state) == state_before and session.boss._brain.cooldowns == cooldowns_before and int(session.boss._steering.path_requests) == path_requests_before, "读取诊断不能推进位置、选招、冷却或路径请求")
		for _frame in range(600):
			await physics_frame
			if session.recorder.time > 4.4 and int(session.boss.current_state) in [1, 2] and float(session.boss.attack_cooldown) <= 0:
				break
		session.boss.set_physics_process(false)
		while session.result.is_empty():
			await process_frame
		var diagnosis: Dictionary = session.result.analysis
		_check(diagnosis.sample_validity == "needs_review", "真实场景的停摆必须被自动判异常")
		_check(not diagnosis.incidents.is_empty() and diagnosis.incidents[0].cause.code == "physics_suspended", "诊断必须指出物理处理关闭，不能仅写 Boss 不动")
		_check(not diagnosis.clips.is_empty() and FileAccess.file_exists(String(session.result.directory).path_join(diagnosis.clips[0])), "异常前后物理帧自动落盘")
		_check(FileAccess.file_exists(String(session.result.directory).path_join("snapshots.jsonl")), "完整原因快照已保存")
		_check(not diagnosis.eligible_for_balance, "故障注入样本不得污染正常战斗结果")
		var reread := Analysis.read_recording(String(session.result.directory))
		_check(reread.analysis.sample_validity == "needs_review" and reread.analysis.data_integrity_problems.is_empty(), "在线与离线对同一完整异常实录结论一致")
		_check(float(reread.analysis.thresholds.stall_seconds) == 1.0, "离线分析沿用实录诊断阈值，不能默默换成默认值")
		var fixture := preload("res://scripts/artifact_paths.gd").ensure_dir("tmp", "sparring_incomplete_fixture")
		for name: String in ["result.json", "snapshots.jsonl"]:
			_check(DirAccess.copy_absolute(String(session.result.directory).path_join(name), fixture.path_join(name)) == OK, "创建截断记录反例")
		var partial := FileAccess.open(fixture.path_join("events.jsonl"), FileAccess.WRITE)
		partial.store_line(JSON.stringify({"time": 0.0, "kind": "begin", "details": {}}))
		partial.close()
		var missing_end := Analysis.read_recording(fixture).analysis as Dictionary
		_check(missing_end.sample_validity == "incomplete_recording" and not missing_end.eligible_for_balance, "缺少结束事件的记录不能被判为正常样本")
	paused = false
	current_scene = null
	world.queue_free()
	for _frame in range(5):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[陪练诊断] failures=", _failures)
	quit(1 if _failures else 0)
