extends SceneTree
## 阶段选择走真实场景与按钮；校验条件隔离、原输入重放的起点及紧凑布局。
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Human := preload("res://tools/probes/sparring/sparring_human_data.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Lab := preload("res://prototypes/sparring_lab/combat_sparring_lab.tscn")
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _prepared() -> Node:
	for _i in range(1800):
		await process_frame
		if is_instance_valid(current_scene) and is_instance_valid(current_scene.get("session")):
			return current_scene.session
	check(false, "真实场景完成准备")
	return null

func _capture(name: String) -> void:
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots", "sparring_phase").path_join(name + ".png")) == OK, "保存实际布局")

func _run() -> void:
	Settings.pending_run = {"scenario_id": "titan_sanctum", "mode": "manual", "autostart": false,
		"scenario_overrides": {"boss_phase": "rage"}, "capture_origin": "synthetic_input_contract"}
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	var session: Node = await _prepared()
	if session != null:
		for _i in range(8):
			await process_frame
		var boss: Node = session.boss
		check(paused and not session.running, "直入狂暴仍先停在准备面板")
		check(boss.is_enraged and is_equal_approx(float(boss.health) / float(boss.max_hp), 0.49), "无需实战扣血，开局即49%狂暴")
		check(not boss.has_mud_shield and not boss._opening_leap_pending, "狂暴练习不带泥盾、不重播开场跃击")
		check(session.actor.get_grenade_status().charges == 3, "新阶段练习从真实三枚库存开始")
		check(session._boss_phase.selected == 2 and not session._boss_phase.disabled, "顶部阶段选择与实际初始条件一致")
		check(session._panel.get_global_rect().end.y <= root.get_visible_rect().size.y, "紧凑面板整体在窗口内")
		check(session._scroll.size.y >= 220, "参数区保留足够高度，增加同时可见行数")
		check(session._mode.get_theme_font_size("font_size") == 11, "下拉控件同样应用紧凑字号")
		await _capture("rage_ready")
		# 完整流程和狂暴直入不是相同条件。
		var full := Settings.resolve({"scenario_id": "titan_sanctum", "scenario_overrides": {"boss_phase": "full"}})
		check(not Settings.same_values(full.scenario, session.options.scenario), "阶段不同不能混为同条件对照")
		session.start_run()
		check(session.running, "狂暴真人局可实际启动")
		for _i in range(14):
			await physics_frame
		session.finish("manual_stop")
		check(session.result.conditions.scenario.boss_phase == "rage" and session.result.initial_boss.hp < session.result.initial_boss.max_hp, "阶段与真实初始生命写入结果")
		var another: Dictionary = session.result.duplicate(true)
		another.conditions.scenario.boss_phase = "full"
		var groups := preload("res://tools/probes/sparring/sparring_batch_report.gd").group_summary([session.result, another])
		check(groups.size() == 2 and groups[0].group_id.contains("狂暴"), "批次报告按初始阶段分组并显示阶段，不只存隐藏字段")
		var replay := Human.replay_options(session.recorder.directory)
		check(replay.get("scenario_overrides", {}).get("boss_phase") == "rage", "原操作重放保留狂暴起点，不回满血开场")
		session._mode.select(0)
		var args: Array = session.batch_arguments()
		check(args.has("--boss_phase=rage"), "无头批测命令包含所选阶段")
		# 用面板切换阶段并重跑，校验不是只改标签。
		session._boss_phase.select(1)
		session._mode.select(1)
		session.repeat_run()
		session = await _prepared()
		if session != null:
			# repeat_run 会自动开局，立即暂停检查。
			if not paused:
				session.toggle_pause()
			boss = session.boss
			check(not boss.is_enraged and boss.has_mud_shield and float(boss.health) == float(boss.max_hp), "实际重载到满血前半有盾阶段")
			check(not boss._opening_leap_pending, "前半练习跳过开场跃击")
			await _capture("front_ready")
			if session.running:
				session.finish("manual_stop")
	paused = false
	var last := current_scene
	current_scene = null
	if is_instance_valid(last):
		last.queue_free()
	for _i in range(6):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[陪练阶段入口] failures=", failures)
	quit(1 if failures else 0)
