extends SceneTree
## python -B tools/run_probe.py tools/probes/titan_sparring.gd --task titan_sparring --timeout 600 --args --profiles=orbit,reactive,greedy --seeds=10420261014,10420261015 --seconds=180
const Lab := preload("res://prototypes/boss_lab/titan_sparring_lab.tscn")
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const BatchReport := preload("res://tools/probes/sparring/sparring_batch_report.gd")
const Analysis := preload("res://tools/probes/sparring/sparring_analysis.gd")
const HumanData := preload("res://tools/probes/sparring/sparring_human_data.gd")
var _rows: Array[Dictionary] = []
var _capture := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var flags := {}
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--"):
			var pair := argument.trim_prefix("--").split("=", true, 1)
			flags[pair[0]] = pair[1] if pair.size() == 2 else "true"
	if flags.has("human-analyze"):
		var reviewed := HumanData.review(String(flags["human-analyze"]))
		var output := Artifacts.ensure_dir("reports", "human_analysis")
		if reviewed.is_empty() or not HumanData.write_bundle(output, reviewed.summary, reviewed.model):
			push_error("真人实录无效或分析输出失败")
			quit(1)
			return
		print("[真人分析] ", output)
		quit(0)
		return
	if flags.has("dataset"):
		var dataset := HumanData.dataset(String(flags.dataset))
		var output := Artifacts.ensure_dir("reports", "human_dataset")
		var file := FileAccess.open(output.path_join("dataset.json"), FileAccess.WRITE)
		if dataset.is_empty() or file == null:
			push_error("真人数据清单无效或输出失败")
			quit(1)
			return
		file.store_string(JSON.stringify(dataset, "  ") + "\n")
		file.close()
		file = FileAccess.open(output.path_join("玩家数据汇总.md"), FileAccess.WRITE)
		if file == null:
			quit(1)
			return
		file.store_string("# 玩家录制资料汇总\n\n%s\n\n去重 %d 份；有效真人分层 %d 组。\n\n| 玩家／自报标签 | 独立录制 | 获胜 | 死亡 | 截断 |\n|---|---:|---:|---:|---:|\n" % [dataset.note, dataset.duplicates_excluded, dataset.eligible_human_cohorts.size()])
		for cohort: Dictionary in dataset.eligible_human_cohorts:
			file.store_string("| %s | %d | %d | %d | %d |\n" % [str(cohort.identity.participant).replace("|", "／"), cohort.recordings, cohort.wins, cohort.deaths, cohort.censored])
		file.store_string("\n逐局移动／攻击／响应分布与被排除源记录保留在 dataset.json，不以总帧数当独立玩家数。\n")
		file.close()
		print("[真人数据汇总] ", output)
		quit(0)
		return
	if flags.has("analyze-batch"):
		_analyze_batch(String(flags["analyze-batch"]))
		return
	if flags.has("analyze"):
		_analyze_existing(String(flags.analyze))
		return
	var doc := Settings.read_document()
	if doc.is_empty():
		quit(1)
		return
	var profiles := String(flags.get("profiles", doc.active)).split(",", false)
	var seeds := String(flags.get("seeds", str(int(doc.default_seed)))).split(",", false)
	var budget := float(flags.get("seconds", doc.observation_seconds))
	if not is_finite(budget) or budget < 1.0 or budget > 1800.0 or profiles.is_empty() or seeds.is_empty():
		push_error("陪练批量条件无效：预算须为 1–1800 秒，方案与种子不能为空")
		quit(1)
		return
	_capture = flags.has("capture") and DisplayServer.get_name() != "headless"
	var replay := String(flags.get("replay", ""))
	if not replay.is_empty():
		var options := HumanData.replay_options(replay.get_base_dir())
		if options.is_empty():
			push_error("重放需要 inputs.jsonl 同目录的 result.json 条件快照")
			quit(1)
			return
		options.pacing = String(flags.get("pacing", options.get("pacing", "realtime")))
		await _trial(options)
	else:
		var scenarios := String(flags.get("scenarios", default_scenario())).split(",", false)
		var groups := String(flags.get("groups", Settings.Groups.document().active)).split(",", false)
		var repeats := int(flags.get("repeats", 1))
		if repeats < 1 or repeats > 30:
			push_error("重复次数必须为 1–30")
			quit(1)
			return
		for scenario_id: String in scenarios:
			for group_id: String in groups:
				for profile: String in profiles:
					for run_seed: String in seeds:
						if not run_seed.is_valid_int() or int(run_seed) <= 0 or not doc.presets.has(profile):
							push_error("未知方案或非整数种子：" + profile + "/" + run_seed)
							quit(1)
							return
						for repetition in range(repeats):
							var overrides := {}
							for field in ["enemy_level", "count_multiplier", "loadout", "boss_phase"]:
								if flags.has(field):
									overrides[field] = String(flags[field]) if field in ["loadout", "boss_phase"] else float(flags[field])
							var options := Settings.resolve({"profile_id": profile, "seed": int(run_seed), "observation_seconds": budget, "autostart": true,
								"scenario_id": scenario_id, "group_id": group_id, "scenario_overrides": overrides, "pacing": String(flags.get("pacing", "realtime"))})
							if options.is_empty():
								quit(1)
								return
							if flags.has("model"):
								options.mode = "imitate"
								options.model_path = String(flags.model)
							for field: String in ["reaction_seconds", "aim_error_degrees", "turn_degrees_per_second", "preferred_distance", "dodge_progress", "greed_seconds"]:
								if flags.has(field):
									if not String(flags[field]).is_valid_float():
										push_error("陪练数值参数无效：" + field)
										quit(1)
										return
									options.profile[field] = float(flags[field])
							if not Settings.validate_profile(options.profile).is_empty():
								push_error("陪练参数越界")
								quit(1)
								return
							await _trial(options)
							if _rows.is_empty() or _rows[-1].is_empty():
								quit(1)
								return

	_write_batch(String(flags.get("compare", "")))
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	if flags.has("require-replay-match"):
		for row: Dictionary in _rows:
			if row.get("analysis", {}).get("replay_audit", {}).get("status", "") != "matched_observed_checkpoints":
				print("[陪练] 重放未通过原局检查点核对")
				quit(3)
				return
	if flags.has("require-valid"):
		for row: Dictionary in _rows:
			if not bool(row.get("analysis", {}).get("eligible_for_balance", false)):
				print("[陪练] 执行完成，但存在不可用于正常交战统计的样本")
				quit(2)
				return
	quit(0 if not _rows.is_empty() and not _rows.has({}) else 1)

func default_scenario() -> String:
	return "titan_sanctum"

func _trial(options: Dictionary) -> void:
	print("[陪练] 开始 ", options.profile_id, " seed=", options.seed, " mode=", options.mode)
	paused = false
	var world: Node = load("res://prototypes/sparring_lab/combat_sparring_lab.tscn").instantiate()
	world.run_options = options
	root.add_child(world)
	current_scene = world
	var ready_session: Node
	for _frame in range(1200):
		await process_frame
		if is_instance_valid(world.session) and world.session.running:
			ready_session = world.session
			break
	if ready_session == null:
		push_error("陪练启动超时")
		_rows.append({})
	else:
		if _capture:
			await _screenshot("start_" + String(options.profile_id))
		var captured_action := false
		while ready_session.result.is_empty() and ready_session.running:
			await process_frame
			if _capture and not captured_action and ready_session.recorder.time >= 6.0:
				captured_action = true
				await _screenshot("action_" + String(options.profile_id))
		_rows.append(ready_session.result)
		if _capture:
			await _screenshot("result_" + String(options.profile_id))
		if ready_session.result.is_empty():
			push_error("陪练输出失败，不能生成有效样本")
		else:
			print("[陪练] 结束 ", ready_session.result.outcome, " hits=", ready_session.result.unblocked_hits, " enemy_hp_total=", ready_session.result.final_boss.get("hp", 0), " → ", ready_session.result.directory)
	paused = false
	current_scene = null
	world.queue_free()
	for _frame in range(4):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)

func _screenshot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var directory := Artifacts.ensure_dir("screenshots", "sparring")
	var error := root.get_texture().get_image().save_png(directory.path_join(label + "_" + str(Time.get_ticks_usec()) + ".png"))
	if error != OK:
		push_error("陪练截图失败：" + error_string(error))

func _write_batch(comparison: String) -> void:
	BatchReport.write(_rows, comparison)

func _analyze_existing(path: String) -> void:
	var directory := path.get_base_dir() if path.ends_with(".json") else path.trim_suffix("/").trim_suffix("\\")
	var data := Analysis.read_recording(directory)
	if data.is_empty():
		push_error("旧实录缺少完整 result.json／timeline.csv 或 snapshots.jsonl")
		quit(1)
		return
	var output := Artifacts.ensure_dir("reports", "sparring_analysis")
	var analysis: Dictionary = data.analysis
	analysis["source_directory"] = directory
	analysis["source_sha256"] = {}
	for name in ["result.json", "events.jsonl", "timeline.csv", "inputs.jsonl", "snapshots.jsonl"]:
		if FileAccess.file_exists(directory.path_join(name)):
			analysis.source_sha256[name] = FileAccess.get_sha256(directory.path_join(name))
	var file := FileAccess.open(output.path_join("analysis.json"), FileAccess.WRITE)
	if file == null:
		push_error("分析输出失败")
		quit(1)
		return
	file.store_string(JSON.stringify(analysis, "  ") + "\n")
	file.close()
	file = FileAccess.open(output.path_join("诊断报告.md"), FileAccess.WRITE)
	if file == null:
		push_error("分析说明输出失败")
		quit(1)
		return
	file.store_string("# 陪练实录自动诊断\n\n原始结果：%s；样本有效性：**%s**；可用于正常交战对照：%s。\n\n原始目录：%s\n\n" % [data.source_report.outcome, analysis.sample_validity, str(analysis.eligible_for_balance), directory])
	file.store_string("重放核对：%s。数据完整性问题：%s。\n\n" % [str(analysis.replay_audit), str(analysis.data_integrity_problems)])
	file.store_string("时间审计：%s。\n\n" % str(analysis.temporal_audit))
	for incident: Dictionary in analysis.incidents:
		file.store_string("- %s／%s · %.2f–%.2f 秒：**%s**；该对象实损 %.1f。\n  证据：%s。分类 %s，证据程度 %s。\n\n" % [incident.get("subject_id", "legacy_boss"), incident.get("subject_title", "交战对象"), incident.start, incident.end, incident.cause.summary, incident.boss_damage, ", ".join(incident.evidence), incident.cause.code, incident.cause.certainty])
	file.store_string("缺少原因数据的旧实录不会补造根因。新记录在 snapshots.jsonl 保存实际分支、选招门槛、导航状态与碰撞；incident 文件保存异常前后物理帧。原始胜负保留，异常局单列，不以战斗总时长打分。\n")
	file.close()
	print("[陪练诊断] ", analysis.sample_validity, " incidents=", analysis.incidents.size(), " → ", output)
	quit(0)

func _analyze_batch(path: String) -> void:
	var source: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not source is Dictionary or not source.get("trials") is Array:
		push_error("批次分析须提供已有 batch.json")
		quit(1)
		return
	var reviewed: Array = []
	for prior: Dictionary in source.trials:
		var data := Analysis.read_recording(String(prior.directory))
		var copy := prior.duplicate(true)
		copy["source_batch"] = path
		copy["source_batch_sha256"] = FileAccess.get_sha256(path)
		copy.analysis = data.analysis if not data.is_empty() else {"sample_validity": "incomplete_recording", "eligible_for_balance": false}
		reviewed.append(copy)
	BatchReport.write(reviewed)
	print("[实战陪练] 已独立复核旧批次；原始文件未覆盖")
	quit(0)

static func comparison_rejection(current: Dictionary, prior: Dictionary) -> String:
	return BatchReport.comparison_rejection(current, prior)

static func same_value(left: Variant, right: Variant) -> bool:
	return Settings.same_values(left, right)
