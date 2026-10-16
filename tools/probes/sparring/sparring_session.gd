extends Node
signal completed(report: Dictionary)
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Controller := preload("res://tools/probes/sparring/sparring_controller.gd")
const Recorder := preload("res://tools/probes/sparring/sparring_recorder.gd")
const Encounter := preload("res://tools/probes/sparring/sparring_encounter.gd")
const HumanData := preload("res://tools/probes/sparring/sparring_human_data.gd")
const Imitation := preload("res://tools/probes/sparring/sparring_imitation.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var _participant: LineEdit
var _style_label: LineEdit
var _recording_path: LineEdit
var _last_model_path := ""
var encounter: RefCounted
var _scenarios: OptionButton
var _scenario_ids: Array = []
var _boss_phase: OptionButton
var _scroll: ScrollContainer
var _outer: VBoxContainer
var _groups: OptionButton
var _group_ids: Array = []
var _group_name: LineEdit
var _group_counts: Dictionary = {}
var _scenario_fields: Dictionary = {}
var _loadout: OptionButton
var _batch_repeats: SpinBox
var _batch_all: CheckBox
var options: Dictionary = {}
var result: Dictionary = {}
var recorder: RefCounted
var actor: Node3D
var boss: Node3D
var arena: Node
var running := false
var _panel: PanelContainer
var _status: Label
var _live: Label
var _dirty: Label
var _profiles: OptionButton
var _mode: OptionButton
var _seed: SpinBox
var _budget: SpinBox
var _name: LineEdit
var _fields: Dictionary = {}
var _diagnostic_fields: Dictionary = {}
var _profile_ids: Array = []
var _document: Dictionary = {}
var _refresh := 0.0

func prepare(world: Node, player: Node3D, titan: Node3D, settings: Dictionary) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 50
	arena = world
	actor = player
	boss = titan
	options = settings.duplicate(true)
	if options.is_empty():
		push_error("陪练准备失败：配置不存在")
		return
	encounter = Encounter.new()
	encounter.configure(world)
	var living: Array = encounter.live_nodes()
	if living.is_empty():
		push_error("陪练准备失败：没有已投放的交战对象")
		return
	boss = living[0]
	_document = Settings.read_document()
	_build_panel()
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if bool(options.autostart):
		start_run()

func start_run() -> void:
	if running or not result.is_empty():
		return
	options = _read_panel()
	var problem := Settings.validate_profile(options.profile)
	if not problem.is_empty():
		_status.text = problem
		return
	if String(options.scenario.kind) == "roster_encounter":
		problem = Settings.Groups.validate(options.group_selection, int(Settings.Groups.document().max_enemies))
		if not problem.is_empty():
			_status.text = problem
			return
	var resolved := Settings.resolve(options)
	if resolved.is_empty():
		_status.text = "实战条件无效，未开始"
		return
	options = resolved
	if not Settings.same_values(options.scenario, arena.run_options.scenario):
		repeat_run()
		return
	var replay: Array = []
	if options.mode == "replay":
		replay = Recorder.read_replay(options.replay_path)
		if replay.is_empty():
			_status.text = "输入录像为空或无效，未开始"
			return
	var driver: RefCounted = Imitation.new() if options.mode == "imitate" else Controller.new()
	if options.mode == "imitate":
		var model: Variant = JSON.parse_string(FileAccess.get_file_as_string(options.model_path)) if FileAccess.file_exists(options.model_path) else {}
		problem = HumanData.model_problem(model)
		if not problem.is_empty():
			_status.text = problem + "；先选择真人记录并分析"
			return
		driver.model = model
		options["model_sha256"] = FileAccess.get_sha256(options.model_path)
	driver.setup(options.profile, int(options.seed))
	driver.encounter = encounter
	actor.get("_weapon").get("_rng").seed = int(options.seed) + 727
	recorder = Recorder.new()
	recorder.encounter = encounter
	if options.mode == "imitate":
		recorder.imitation_driver = driver
	if not recorder.open_recording(options, actor, boss):
		_status.text = "输出失败，未开放战斗"
		return
	actor.call("begin_sparring", driver, recorder, boss, options.mode, replay)
	running = true
	get_tree().paused = false
	_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if options.mode == "manual" else Input.MOUSE_MODE_VISIBLE

func _physics_process(delta: float) -> void:
	if running and recorder != null:
		recorder.pause_wall_clock(get_tree().paused)
	if not running or get_tree().paused:
		return
	recorder.observe(delta, actor, boss if is_instance_valid(boss) else null)
	if options.mode == "replay" and recorder.diagnostics.replay_audit.get("status", "") == "diverged":
		finish("replay_diverged")
	elif float(actor.get("health")) <= 0.0:
		finish("player_dead")
	elif encounter.live_nodes().is_empty():
		finish("opponents_removed" if not encounter.removed_alive.is_empty() else "boss_dead" if options.scenario.kind == "boss_direct" else "enemies_defeated")
	elif options.mode == "replay" and int(actor.get("replay_index")) >= actor.get("replay_frames").size():
		finish("replay_end")
	elif float(recorder.time) >= float(options.observation_seconds):
		finish("observation_limit")

func finish(outcome: String) -> void:
	if not running:
		return
	running = false
	actor.set("sparring_active", false)
	result = recorder.finish(outcome)
	_recording_path.text = recorder.directory
	_last_model_path = recorder.directory.path_join("human_model.json") if FileAccess.file_exists(recorder.directory.path_join("human_model.json")) else ""
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_panel.visible = true
	_status.text = "%s · %s · 受击 %s 次\n%s" % [outcome, result.get("analysis", {}).get("sample_validity", "未核对"), result.get("unblocked_hits", 0), recorder.directory]
	completed.emit(result)

func toggle_pause() -> void:
	if not running:
		_panel.visible = true
		return
	get_tree().paused = not get_tree().paused
	_panel.visible = get_tree().paused
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if options.mode == "manual" and not get_tree().paused else Input.MOUSE_MODE_VISIBLE

func repeat_run() -> void:
	var next := _read_panel()
	if next.scenario.kind == "roster_encounter":
		var problem := Settings.Groups.validate(next.group_selection, int(Settings.Groups.document().max_enemies))
		if not problem.is_empty():
			_status.text = problem
			return
	next.autostart = true
	Settings.pending_run = next
	if running:
		finish("interrupted_repeat")
	get_tree().paused = false
	get_tree().reload_current_scene()

func _exit_tree() -> void:
	if recorder != null:
		if running:
			recorder.finish("interrupted_exit")
		recorder.close_files()
	if encounter != null:
		encounter.detach()
	if is_instance_valid(actor):
		actor.remove_meta(&"combat_recorder")

func _process(delta: float) -> void:
	_refresh -= delta
	if _refresh > 0.0 or _status == null:
		return
	_refresh = 0.25
	_status.tooltip_text = _status.text
	var current := _read_panel()
	var saved: Dictionary = _document.presets.get(current.profile_id, {})
	var saved_diagnostic: Dictionary = saved.get("diagnostics", _document.get("diagnostics", {}))
	var strategy_saved := Settings.same_values(current.profile, saved) and Settings.same_values(current.diagnostics, saved_diagnostic)
	var group_saved := Settings.same_values(current.group_selection, Settings.Groups.document().groups.get(current.group_id, {}).get("selection", {}))
	_dirty.text = ("策略已保存" if strategy_saved else "● 策略未保存") + " · " + ("编组已保存" if group_saved else "● 编组未保存")
	if current.scenario_id != options.scenario_id or current.scenario_overrides.boss_phase != options.scenario.get("boss_phase", "full"):
		_dirty.text += " · 开局条件待重跑"
	if running:
		_status.text = "%.2fs  血 %.1f / 盾 %.1f  存活敌人 %d\nTab 暂停/继续 · F5 同条件重跑" % [recorder.time, actor.get("health"), actor.get("shield"), encounter.live_nodes().size()]
		_live.text = "陪练 %.1fs · 血 %.0f / 盾 %.0f · %s" % [recorder.time, actor.get("health"), actor.get("shield"), options.profile.title]
		if not recorder.diagnostics.notices.is_empty():
			_live.text += " · ⚠ 交战异常已留证"

func _build_panel() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 110
	add_child(layer)
	var hint := Label.new()
	hint.text = "自动陪练 / 真人记录 · Tab 面板 · F5 同条件重跑 · 正式血盾/弹药/冷却"
	hint.position = Vector2(12, 75)
	hint.add_theme_font_size_override("font_size", 14)
	layer.add_child(hint)
	_live = Label.new()
	_live.position = Vector2(12, 96)
	_live.add_theme_font_size_override("font_size", 13)
	layer.add_child(_live)
	_panel = PanelContainer.new()
	_panel.position = Vector2(12, 112)
	_panel.custom_minimum_size = Vector2(400, 0)
	# 调试局部主题：所有输入框／下拉菜单一起缩小，不改变正式 HUD。
	var compact := Theme.new()
	compact.default_font_size = 11
	for type: String in ["Label", "Button", "OptionButton", "CheckBox", "LineEdit", "PopupMenu"]:
		compact.set_font_size("font_size", type, 11)
	for state: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		var box := _mode_style(state)
		compact.set_stylebox(state, "Button", box)
		compact.set_stylebox(state, "OptionButton", box)
	_panel.theme = compact
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.065, 0.09, 0.97)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_content_margin(side, 6)
	_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(_panel)
	var outer := VBoxContainer.new()
	_outer = outer
	outer.add_theme_constant_override("separation", 2)
	_panel.add_child(outer)
	var title := Label.new()
	title.text = "实战陪练 · 正式场景／敌人编组"
	outer.add_child(title)
	_mode = OptionButton.new()
	for label in ["自动陪练", "真人操作录制", "固定输入重放", "真人片段经验模拟"]:
		_mode.add_item(label)
	_mode.select(["auto", "manual", "replay", "imitate"].find(options.mode))
	_row(outer, "运行方式", _mode)
	var quick_start := HBoxContainer.new()
	outer.add_child(quick_start)
	_button(quick_start, "真人打一局并录制", func(): _start_mode("manual"))
	_button(quick_start, "开始自动陪练", func(): _start_mode("auto"))
	var recording_hint := Label.new()
	recording_hint.text = "真人正式操作 · Tab 暂停 · 结束保存操作／战况，可分析与重放"
	recording_hint.tooltip_text = "记录逐帧操作和战况数据，不生成视频。修改开局条件后重跑生效。"
	recording_hint.add_theme_font_size_override("font_size", 10)
	outer.add_child(recording_hint)
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.custom_minimum_size = Vector2(400, 120)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 2)
	scroll.add_child(column)
	_scenarios = OptionButton.new()
	var scenarios := Settings.Scenarios.document()
	for id: String in scenarios.scenarios:
		_scenario_ids.append(id)
		_scenarios.add_item(String(scenarios.scenarios[id].title))
	_scenarios.select(_scenario_ids.find(options.scenario_id))
	_scenarios.item_selected.connect(_select_scenario)
	# 场景选择与真人入口常驻顶部，不埋在逐兵种和策略参数后。
	_row(outer, "正式场景（下轮生效）", _scenarios)
	outer.move_child(_scenarios.get_parent(), 1)
	_boss_phase = OptionButton.new()
	for caption: String in ["完整开场 · 100%", "前半练习 · 100% · 跳过开场", "狂暴练习 · 跳过开场"]:
		_boss_phase.add_item(caption)
	_boss_phase.select(["full", "front", "rage"].find(String(options.scenario.get("boss_phase", "full"))))
	_boss_phase.disabled = options.scenario.kind != "boss_direct"
	_boss_phase.tooltip_text = "下轮生效；狂暴直入使用狂暴阈值减1%生命，初始阶段写入记录与重放条件。"
	_row(outer, "Boss 开局阶段（下轮生效）", _boss_phase)
	outer.move_child(_boss_phase.get_parent(), 2)
	_loadout = OptionButton.new()
	for caption in ["初始装备", "中期模块", "满配模块"]:
		_loadout.add_item(caption)
	_loadout.select(["initial", "mid", "max"].find(options.scenario.loadout))
	_row(column, "玩家配装（真实模块）", _loadout)
	_scenario_fields.enemy_level = _number(column, "敌人等级", 1, 30, 0.5, options.scenario.enemy_level)
	_scenario_fields.count_multiplier = _number(column, "编组数量倍率", 1, 4, 1, options.scenario.count_multiplier)
	_groups = OptionButton.new()
	var groups := Settings.Groups.document()
	for id: String in groups.groups:
		_group_ids.append(id)
		_groups.add_item(String(groups.groups[id].title) + " (" + id + ")")
	_groups.select(_group_ids.find(options.group_id))
	_groups.item_selected.connect(_select_group)
	_row(column, "独立敌人组（Boss 直战不应用）", _groups)
	_group_name = LineEdit.new()
	_group_name.text = options.group_id
	_row(column, "编组保存名称", _group_name)
	var expand := CheckBox.new()
	expand.text = "展开逐兵种数量（正式图鉴）"
	column.add_child(expand)
	var counts := VBoxContainer.new()
	counts.visible = false
	column.add_child(counts)
	expand.toggled.connect(func(visible: bool): counts.visible = visible)
	for id: String in Settings.Groups.roster():
		var entry: Dictionary = Settings.Groups.roster()[id]
		_group_counts[id] = _number(counts, String(entry.title), 0, int(groups.max_enemies), 1, int(options.group_selection.get(id, 0)))
	var group_buttons := HBoxContainer.new()
	column.add_child(group_buttons)
	_button(group_buttons, "保存命名编组", _save_group)
	_button(group_buttons, "编组设为默认", _set_default_group)
	_batch_repeats = _number(column, "无头批测 · 每种子重复次数", 1, 30, 1, 3)
	_batch_all = CheckBox.new()
	_batch_all.text = "批测覆盖全部已保存策略（默认仅当前策略）"
	column.add_child(_batch_all)
	_button(column, "复制无头批测命令（先保存编组／策略）", _copy_batch_command)
	_profiles = OptionButton.new()
	for id: String in _document.presets:
		_profile_ids.append(id)
		_profiles.add_item(String(_document.presets[id].title) + " (" + id + ")")
	_profiles.select(_profile_ids.find(options.profile_id))
	_profiles.item_selected.connect(_select_profile)
	_row(column, "命名方案", _profiles)
	_name = LineEdit.new()
	_name.text = String(options.profile_id)
	_row(column, "保存名称", _name)
	_participant = LineEdit.new()
	_participant.max_length = 64
	_participant.text = String(options.get("participant", {}).get("id", "anonymous"))
	_row(column, "玩家代号（录制标签）", _participant)
	_style_label = LineEdit.new()
	_style_label.max_length = 64
	_style_label.text = String(options.get("participant", {}).get("style_label", "未标注"))
	_row(column, "自报风格／备注（不是分析结论）", _style_label)
	_recording_path = LineEdit.new()
	_recording_path.placeholder_text = "包含 result.json／inputs.jsonl 的录制目录"
	_row(column, "已录制战斗", _recording_path)
	var recording_buttons := GridContainer.new()
	recording_buttons.columns = 2
	column.add_child(recording_buttons)
	_button(recording_buttons, "选择录制目录", _choose_recording)
	_button(recording_buttons, "分析／生成经验模型", _analyze_recording)
	_button(recording_buttons, "原操作重放", _replay_recording)
	_button(recording_buttons, "此风格模拟当前编组", _imitate_recording)
	_seed = _number(column, "种子（固定投放/策略/散布）", 1, 99999999999, 1, float(options.seed))
	_budget = _number(column, "观察预算 秒（截断，不评分）", 1, 1800, 1, float(options.observation_seconds))
	for spec: Array in [["reaction_seconds", "反应延迟 秒", 0, 2, 0.01], ["aim_error_degrees", "瞄准误差 度", 0, 15, 0.1],
		["turn_degrees_per_second", "瞄准转速 度/秒", 15, 360, 5], ["preferred_distance", "期望距离 米", 5, 30, 0.5],
		["dodge_progress", "预警进度达到后翻滚 0–1", 0, 1, 0.01], ["greed_seconds", "发现危险后的贪枪 秒", 0, 1, 0.01]]:
		_fields[spec[0]] = _number(column, spec[1], spec[2], spec[3], spec[4], options.profile[spec[0]])
	for spec: Array in [["use_grenade", "使用 E 手雷"], ["use_q", "使用 Q 震地"], ["use_sniper", "使用狙击"], ["adapt_to_visible_range", "根据可见横扫学习距离"]]:
		var check := CheckBox.new()
		check.text = spec[1]
		check.button_pressed = bool(options.profile[spec[0]])
		column.add_child(check)
		_fields[spec[0]] = check
	for spec: Array in [["stall_seconds", "停摆观察阈值 秒（不评分）", 0.5, 30, 0.5], ["stationary_radius", "原地容差 米", 0.01, 2, 0.01],
		["snapshot_interval", "常态诊断间隔 秒", 0.016, 1, 0.001], ["context_seconds", "异常前保留 秒", 1, 15, 1]]:
		_diagnostic_fields[spec[0]] = _number(column, spec[1], spec[2], spec[3], spec[4], options.diagnostics[spec[0]])
	_dirty = Label.new()
	outer.add_child(_dirty)
	var actions := HBoxContainer.new()
	outer.add_child(actions)
	_button(actions, "开始/继续", func():
		if running:
			if get_tree().paused:
				toggle_pause()
		else:
			start_run())
	_button(actions, "同条件重跑", repeat_run)
	_button(actions, "保存命名方案", _save_preset)
	_button(actions, "设为默认", _set_default)
	var files := HBoxContainer.new()
	outer.add_child(files)
	_button(files, "结束并保存", func():
		if running:
			finish("manual_stop"))
	_button(files, "打开本轮记录", func():
		if recorder != null:
			OS.shell_open(recorder.directory))
	_button(files, "返回主菜单", _return_to_menu)
	_status = Label.new()
	_status.text = "启动前调整；已开始的条件锁定，修改在下次重跑生效。\n策略不代表真人群体，不自动评价好玩。"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 390
	_status.max_lines_visible = 3
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	outer.add_child(_status)
	get_viewport().size_changed.connect(_fit_panel)
	_fit_panel.call_deferred()

func _mode_style(state: String) -> StyleBox:
	var box := _panel.get_theme_stylebox(state, "Button").duplicate() as StyleBox
	box.content_margin_top = 2
	box.content_margin_bottom = 2
	box.content_margin_left = 4
	box.content_margin_right = 4
	return box

func _fit_panel() -> void:
	if not is_instance_valid(_scroll):
		return
	var fixed_height := _outer.get_combined_minimum_size().y - _scroll.custom_minimum_size.y
	_scroll.custom_minimum_size.y = maxf(80, get_viewport().get_visible_rect().size.y - _panel.position.y - fixed_height - 24)
	_panel.size = Vector2(0, 0)

func _start_mode(mode: String) -> void:
	if running:
		if options.mode != mode:
			_status.text = "本局方式已锁定；先结束并保存，再选择下一局。"
		elif get_tree().paused:
			toggle_pause()
		return
	_mode.select(["auto", "manual", "replay", "imitate"].find(mode))
	if result.is_empty():
		start_run()
	else:
		repeat_run()

func _return_to_menu() -> void:
	if running:
		finish("manual_stop")
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null:
		flow.call_deferred("return_from_sparring")

func _row(parent: Node, caption: String, control: Control) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = caption
	label.custom_minimum_size.x = 170
	label.clip_text = true
	label.tooltip_text = caption
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)

func _number(parent: Node, caption: String, minimum: float, maximum: float, step: float, value: float) -> SpinBox:
	var field := SpinBox.new()
	field.min_value = minimum
	field.max_value = maximum
	field.step = step
	field.value = value
	_row(parent, caption, field)
	return field

func _button(parent: Node, caption: String, action: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.add_theme_font_size_override("font_size", 11)
	button.pressed.connect(action)
	parent.add_child(button)

func _read_panel() -> Dictionary:
	var value := options.duplicate(true)
	if _profiles == null:
		return value
	value.profile_id = _profile_ids[_profiles.selected]
	value.profile = _document.presets[value.profile_id].duplicate(true)
	for key: String in _fields:
		value.profile[key] = _fields[key].button_pressed if _fields[key] is CheckBox else _fields[key].value
	value.diagnostics = {}
	for key: String in _diagnostic_fields:
		value.diagnostics[key] = _diagnostic_fields[key].value
	value.seed = int(_seed.value)
	value.observation_seconds = _budget.value
	value.mode = ["auto", "manual", "replay", "imitate"][_mode.selected]
	value.participant = {"id": _participant.text.strip_edges().left(64), "style_label": _style_label.text.strip_edges().left(64)}
	value.scenario_id = _scenario_ids[_scenarios.selected]
	value.scenario = Settings.Scenarios.document().scenarios[value.scenario_id].duplicate(true)
	value.scenario_overrides = {"loadout": ["initial", "mid", "max"][_loadout.selected], "enemy_level": _scenario_fields.enemy_level.value, "count_multiplier": int(_scenario_fields.count_multiplier.value)}
	value.scenario_overrides["boss_phase"] = ["full", "front", "rage"][_boss_phase.selected] if value.scenario.kind == "boss_direct" else "full"
	value.group_id = _group_ids[_groups.selected]
	value.group_selection = {}
	for id: String in _group_counts:
		if int(_group_counts[id].value) > 0:
			value.group_selection[id] = int(_group_counts[id].value)
	return value

func _choose_recording() -> void:
	var picker := FileDialog.new()
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	picker.title = "选择包含 result.json／inputs.jsonl 的战斗目录"
	picker.dir_selected.connect(func(path: String):
		_recording_path.text = path
		_last_model_path = ""
		picker.queue_free())
	picker.canceled.connect(picker.queue_free)
	add_child(picker)
	picker.popup_centered_ratio(0.75)

func _analyze_recording() -> void:
	var source := _recording_path.text.strip_edges()
	var reviewed := HumanData.review(source) if FileAccess.file_exists(source.path_join("result.json")) else {}
	if reviewed.is_empty():
		_status.text = "录制目录无效；需要原始 result.json、输入和事件／快照"
		return
	var output := Artifacts.ensure_dir("reports", "human_review/" + str(Time.get_ticks_usec()))
	if not HumanData.write_bundle(output, reviewed.summary, reviewed.model):
		_status.text = "分析输出失败"
		return
	_last_model_path = output.path_join("human_model.json") if not reviewed.model.is_empty() else ""
	_status.text = "行为分析已保存；原局 %s，%s\n%s" % [reviewed.summary.origin, "经验模型可运行（未独立验证）" if not _last_model_path.is_empty() else "旧数据／过短，未生成模型", output]
	if DisplayServer.get_name() != "headless":
		OS.shell_open(output)

func _launch_recording_options(next: Dictionary) -> void:
	if running:
		finish("interrupted_import")
	Settings.pending_run = next
	get_tree().paused = false
	get_tree().reload_current_scene()

func _replay_recording() -> void:
	var source := _recording_path.text.strip_edges()
	var next := HumanData.replay_options(source) if FileAccess.file_exists(source.path_join("result.json")) else {}
	if next.is_empty():
		_status.text = "输入录制无法读取，未开始重放"
		return
	_launch_recording_options(next)

func _imitate_recording() -> void:
	if _last_model_path.is_empty():
		_analyze_recording()
	if _last_model_path.is_empty():
		return
	var next := _read_panel()
	next.mode = "imitate"
	next.model_path = _last_model_path
	next.autostart = true
	_launch_recording_options(next)

func _select_scenario(index: int) -> void:
	var scenario: Dictionary = Settings.Scenarios.document().scenarios[_scenario_ids[index]]
	_loadout.select(["initial", "mid", "max"].find(scenario.loadout))
	for key: String in _scenario_fields:
		_scenario_fields[key].value = scenario[key]
	_boss_phase.disabled = scenario.kind != "boss_direct"
	if _boss_phase.disabled:
		_boss_phase.select(0)

func _select_group(index: int) -> void:
	var id := String(_group_ids[index])
	_group_name.text = id
	var selection: Dictionary = Settings.Groups.document().groups[id].selection
	for key: String in _group_counts:
		_group_counts[key].value = int(selection.get(key, 0))

func _save_group() -> void:
	var id := _group_name.text.strip_edges()
	var error := Settings.Groups.save_named(id, _read_panel().group_selection)
	if error != OK:
		_status.text = "编组保存失败：" + error_string(error)
		return
	if not _group_ids.has(id):
		_group_ids.append(id)
		_groups.add_item(id)
	_groups.select(_group_ids.find(id))
	_status.text = "编组已保存到 sparring_groups.json；默认编组未变"

func _set_default_group() -> void:
	var current := _read_panel()
	var named: Dictionary = Settings.Groups.document().groups[current.group_id].selection
	if not Settings.same_values(current.group_selection, named):
		_status.text = "请先保存编组修改，再设为默认"
		return
	var error := Settings.Groups.save_named(current.group_id, named, true)
	_status.text = "默认编组已保存" if error == OK else "默认编组保存失败"

func batch_arguments() -> Array[String]:
	var current := _read_panel()
	var saved: Dictionary = _document.presets[current.profile_id]
	if current.mode != "auto" or not Settings.same_values(current.profile, saved) or not Settings.same_values(current.diagnostics, saved.get("diagnostics", _document.get("diagnostics", {}))) or not Settings.same_values(current.group_selection, Settings.Groups.document().groups[current.group_id].selection):
		return []
	var profiles := ",".join(_document.presets.keys()) if _batch_all.button_pressed else String(current.profile_id)
	var timeout: int = int(current.observation_seconds) * int(_batch_repeats.value) * (_document.presets.size() if _batch_all.button_pressed else 1) + 240
	return ["-B", ProjectSettings.globalize_path("res://tools/run_probe.py"), "tools/probes/combat_sparring.gd", "--task", "combat_sparring", "--timeout", str(timeout), "--args",
		"--scenarios=" + String(current.scenario_id), "--groups=" + String(current.group_id), "--profiles=" + profiles,
		"--seeds=" + str(current.seed), "--seconds=" + str(current.observation_seconds), "--repeats=" + str(int(_batch_repeats.value)),
		"--loadout=" + String(current.scenario_overrides.loadout), "--enemy_level=" + str(current.scenario_overrides.enemy_level), "--count_multiplier=" + str(current.scenario_overrides.count_multiplier), "--boss_phase=" + String(current.scenario_overrides.boss_phase)]

func _copy_batch_command() -> void:
	var arguments := batch_arguments()
	if arguments.is_empty():
		_status.text = "请用自动模式，并先保存策略／诊断参数和编组修改"
		return
	var quoted: Array[String] = []
	for argument: String in arguments:
		quoted.append("'" + argument.replace("'", "''") + "'")
	DisplayServer.clipboard_set("python " + " ".join(quoted))
	_status.text = "无头批测命令已复制；同种子重复，额外种子可在 --seeds 追加。结果单独生成，不覆盖本局。"

func _select_profile(index: int) -> void:
	var values: Dictionary = _document.presets[_profile_ids[index]]
	_name.text = String(_profile_ids[index])
	for key: String in _fields:
		if _fields[key] is CheckBox:
			_fields[key].button_pressed = values[key]
		else:
			_fields[key].value = values[key]
	var diagnostic: Dictionary = values.get("diagnostics", _document.get("diagnostics", {}))
	for key: String in _diagnostic_fields:
		_diagnostic_fields[key].value = diagnostic.get(key, options.diagnostics[key])

func _save_preset() -> void:
	var id := _name.text.strip_edges()
	if id.is_empty() or id != id.validate_filename():
		_status.text = "方案名称不能为空或含路径符号"
		return
	var document := _document.duplicate(true)
	var values: Dictionary = _read_panel().profile
	values["diagnostics"] = _read_panel().diagnostics
	values.title = id
	document.presets[id] = values
	var error := Settings.write_document(document)
	if error != OK:
		_status.text = "保存失败：" + error_string(error)
		return
	_document = document
	if not _profile_ids.has(id):
		_profile_ids.append(id)
		_profiles.add_item(id)
	_profiles.select(_profile_ids.find(id))
	_status.text = "方案已保存到 data/testing/titan_sparring.json；默认方案未变"

func _set_default() -> void:
	var current := _read_panel()
	if not Settings.same_values(current.profile, _document.presets[current.profile_id]) or not Settings.same_values(current.diagnostics, _document.presets[current.profile_id].get("diagnostics", _document.get("diagnostics", {}))):
		_status.text = "请先保存当前修改，再设为默认"
		return
	var document := _document.duplicate(true)
	document.active = current.profile_id
	document.default_seed = current.seed
	document.observation_seconds = current.observation_seconds
	document.diagnostics = current.diagnostics
	document.active_scenario = current.scenario_id
	document.default_scenario_overrides = current.scenario_overrides
	var error := Settings.write_document(document)
	if error == OK:
		_document = document
	_status.text = "默认方案已保存" if error == OK else "保存默认失败：" + error_string(error)
