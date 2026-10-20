extends SceneTree
## T01：真实方案存储、共享草稿、消息拒绝和现有两个面板的行为合同。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Session := preload("res://scripts/testing/tuning_session.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const CombatPanel := preload("res://prototypes/combat_lab/enemy_tuning_panel.gd")
const VisualPanel := preload("res://scripts/prototypes/visual_model_panel.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures: Array[String] = []
var checks := 0
var world: Node3D

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func frames(count: int) -> void:
	for _i in count: await process_frame

func _run() -> void:
	await frames(3)
	var flow := root.get_node("GameFlow")
	flow.process_mode = Node.PROCESS_MODE_DISABLED
	flow.visible = false
	paused = false
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var previous := Tuning.storage_directory
	Tuning.storage_directory = Artifacts.ensure_dir("tmp", "t01_presets")
	# 使用真实已有方案的只读副本，包括正式 Boss 指定名；不把空测试目录
	# 的基础值回退当成“已验证正式引用未变”。
	for profile: String in Tuning.PROFILE_PATHS:
		var original := previous.path_join(profile + ".json")
		if FileAccess.file_exists(original):
			var copy := FileAccess.open(Tuning.storage_directory.path_join(profile + ".json"), FileAccess.WRITE)
			copy.store_buffer(FileAccess.get_file_as_bytes(original))
			copy.close()
	Tuning.reload_saved()
	_catalog()
	_core()
	await _panels()
	Tuning.storage_directory = previous
	Tuning.reload_saved()
	current_scene = null
	world.queue_free()
	await frames(2)
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("t01_contracts.json"), FileAccess.WRITE)
	if file == null:
		push_error("T01 检查结果无法写入")
		quit(1)
		return
	file.store_string(JSON.stringify({"passed": failures.is_empty(), "checks": checks, "failures": failures, "scope": "T01 身份／草稿／保存及现有面板；没有 T02 新战斗宿主外形或 T03 实时技能编辑"}, "\t"))
	file.close()
	print("[T01] checks=", checks, " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)

func _catalog() -> void:
	for profile: String in Tuning.PROFILE_PATHS:
		check(Catalog.identity(profile).profile == profile, "七份 schema 都能从角色身份定位")
	for species: String in preload("res://scripts/enemies/creature_catalog.gd").SPECIES:
		var actor := Catalog.identity(species, "combat")
		var visual := Catalog.identity(actor.profile, "visual")
		check(actor.role_id == visual.role_id and actor.form != visual.form, "外形和战斗形态同角色、不同用途")
	for entry: Dictionary in preload("res://scripts/game_config.gd").get_dictionary("enemy_roster").entries:
		check(Catalog.identity(String(entry.id)).role_id.begins_with("legacy:"), "旧图鉴身份保留独立命名空间")
	check(Catalog.identity("").is_empty(), "空身份不能误匹配第一个物种")
	for key: String in Catalog.PILOT:
		var field := Catalog.field("PrototypeSedimentTitan", key)
		check(not field.is_empty() and field.reviewed and not String(field.owner).is_empty() and field.has("unit") and field.has("min") and field.has("apply") and field.has("observation"), "试点字段归属／单位／范围／生效／观察登记：" + key)
	var fields := Catalog.encounter_fields("res://data/encounters/sanctum_creatures.json")
	var encounter: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/encounters/sanctum_creatures.json"))
	var expected := _leaf_paths(encounter)
	var actual: Array[String] = []
	for field: Dictionary in fields: actual.append(field.path)
	expected.sort()
	actual.sort()
	check(actual == expected, "当前编排每个实际叶字段都登记，不只登记整个文件或固定计数")
	for field: Dictionary in fields:
		check(field.status != "缺失登记" and field.module != "未登记" and field.has("source") and field.has("save"), "编排字段有编辑归属：" + String(field.path))
	var group := Catalog.group_context("A", "rev1", "instance:8", "member:3")
	check(group.template_id != group.instance_id and group.quantity_unit == "组" and group.member_unit == "只", "模板、实例与组／人数单位不混用")
	var lab := preload("res://scripts/prototypes/enemy_visual_lab.gd")
	var visual_index: int = lab.gallery_index_for("VisualBurstCrawler", "visual")
	var combat_index: int = lab.gallery_index_for("VisualBurstCrawler", "combat")
	check(visual_index != combat_index and lab.GALLERY[visual_index].observe == "scrub" and lab.GALLERY[combat_index].observe == "play", "重复 profile 的外形与战斗入口定位明确")

func _leaf_paths(value: Variant, prefix := "") -> Array[String]:
	var out: Array[String] = []
	if value is Dictionary:
		for key: String in value: out.append_array(_leaf_paths(value[key], key if prefix.is_empty() else prefix + "." + key))
	elif value is Array:
		for index in value.size(): out.append_array(_leaf_paths(value[index], prefix + "[%d]" % index))
	else: out.append(prefix)
	return out

func _core() -> void:
	var session := Session.new()
	var profile := "PrototypeSedimentTitan"
	var key := session.open_profile(profile)
	var base := session.values(key)
	var active := Tuning.active_name(profile)
	var formal := Catalog.formal_preset(profile)
	var formal_values := Tuning.preset_values(profile, formal)
	check(session.set_value(key, "thrust_width", float(base.thrust_width) + 0.125), "真实技能字段可编辑")
	check(session.dirty(key), "修改有未保存状态")
	session.open_profile("PrototypeHornet")
	check(session.open_profile(profile) == key and session.values(key).thrust_width != base.thrust_width, "切对象返回保留草稿")
	session.undo(key)
	check(not session.dirty(key), "撤销回到基线")
	session.redo(key)
	check(session.dirty(key), "重做恢复修改")
	var copied := session.values(key)
	copied.thrust_width = 999999.0
	check(session.values(key).thrust_width != copied.thrust_width, "暴露值的副本不能绕过草稿合同")
	check(not session.set_value(key, "thrust_width", INF), "拒绝非有限值")
	check(not session.set_value(key, "not_a_field", 1), "拒绝未知字段")
	check(session.save_as(key, "T01 candidate"), "另存真实命名候选")
	check(Tuning.active_name(profile) == active and Tuning.preset_values(profile, formal) == formal_values, "候选保存不改变默认或正式 Boss 指定方案")
	Tuning.reload_saved()
	check(Tuning.preset_values(profile, "T01 candidate") == session.values(key), "保存后重读一致")
	check(session.activate(key) and Tuning.active_name(profile) == "T01 candidate", "单独设默认必须显式执行")
	check(Catalog.formal_preset(profile) == formal and Tuning.preset_values(profile, formal) == formal_values, "原型默认改变不替换正式 Boss 独立指定")
	session.set_value(key, "thrust_width", float(session.values(key).thrust_width) + 0.125)
	check(not session.save_as(key, "T01 candidate"), "普通保存不得静默覆盖同名")
	var outside := session.values(key)
	outside.thrust_width += 0.125
	check(Tuning.save_preset(profile, "T01 candidate", outside, false), "模拟另一个入口已保存新内容")
	check(not session.save_as(key, "T01 candidate", true), "旧草稿覆盖须拒绝磁盘指纹冲突")
	check(session.dirty(key) and Tuning.preset_values(profile, "T01 candidate") == outside, "拒绝覆盖保留草稿与其他入口的新内容")
	check(not session.reload_from_disk(key), "未保存草稿不能被普通重读静默丢弃")
	check(session.reload_from_disk(key, true) and session.values(key) == outside and not session.dirty(key), "明确丢弃后可重读真实磁盘新内容")
	check(session.save_as(key, "T01 after conflict"), "冲突草稿可另存新名")
	session.set_value(key, "thrust_width", float(session.values(key).thrust_width) + 0.125)
	check(session.save_as(key, "T01 after conflict", true), "有明确动作且指纹相符时可覆盖")
	var packet: Dictionary = JSON.parse_string(JSON.stringify(session.snapshot(key)))
	packet.values.thrust_width += 0.125
	check(session.accept_result(key, packet), "纯数据快照 JSON 往返可提交草稿结果")
	check(not session.accept_result(key, packet), "旧修订回包不能覆盖新草稿")
	packet = session.snapshot(key)
	packet.session_id = "another-session"
	check(not session.accept_result(key, packet), "拒绝其他会话回包")
	packet = session.snapshot(key)
	packet.identity.profile = "PrototypeHornet"
	check(not session.accept_result(key, packet), "拒绝错对象回包")
	packet = session.snapshot(key)
	packet.values["arbitrary"] = 1
	check(not session.accept_result(key, packet), "拒绝未登记参数回包")
	var selection := session.test_selection(key, "res://scenes/sanctum_main.tscn")
	check(selection.scope == "this_test_only" and not selection.runtime_applied and not selection.project_default_changed, "场景本轮选用合同与默认保存分开，不冒充已经应用到运行场景")
	var directory := Tuning.storage_directory
	var blocked := Artifacts.ensure_dir("tmp").path_join("t01_blocked_store")
	var blocker := FileAccess.open(blocked, FileAccess.WRITE)
	blocker.store_string("file, not a directory")
	blocker.close()
	Tuning.storage_directory = blocked
	Tuning.reload_saved()
	var before := session.values(key)
	check(not session.save_as(key, "T01 cannot write"), "真实文件错误须返回保存失败")
	check(session.values(key) == before and session.dirty(key), "保存失败不丢草稿")
	Tuning.storage_directory = directory
	Tuning.reload_saved()

func _panels() -> void:
	var combat := CombatPanel.new()
	world.add_child(combat)
	var visual := VisualPanel.new()
	world.add_child(visual)
	var profile := "VisualBurstCrawler"
	combat.open_enemy(profile)
	visual.bind_profile(profile)
	check(combat.draft_id == visual.draft_id, "现有两个面板共用同一对象／方案草稿")
	combat._changed(2.678901234567, "move_speed")
	await frames(2)
	var spin: SpinBox = combat._fields.body_size
	spin.get_line_edit().text = "1.23456789123"
	spin.get_line_edit().text_changed.emit("1.23456789123")
	spin.apply()
	check(combat._commit_inputs(), "直接键入可提交，不依赖先按 Enter")
	check(absf(float(visual.values.body_size) - 1.23456789123) < 1e-11, "共享草稿保留键入精度，步长不强制取整")
	combat.open_enemy("PrototypeHornet")
	combat.open_enemy(profile)
	check(absf(float(combat._draft.body_size) - 1.23456789123) < 1e-11, "切换对象后高精度草稿保留")
	spin = combat._fields.body_size
	spin.get_line_edit().text = "bad input"
	spin.get_line_edit().text_changed.emit("bad input")
	check(not combat._commit_inputs(), "非法文字显示错误而非静默保存旧值")
	combat.open_enemy("PrototypeHornet")
	check(combat.enemy_id == profile, "非法未提交内容阻止切走丢失输入")
	spin.get_line_edit().text = "1.23456789123"
	spin.get_line_edit().text_changed.emit("1.23456789123")
	check(combat._commit_inputs(), "修正文字后可继续")
	var active := Tuning.active_name(profile)
	combat._name_edit.text = "T01 UI candidate"
	combat.save_current()
	check(Tuning.active_name(profile) == active, "战斗面板保存候选不自动切默认")
	check(absf(float(Tuning.preset_values(profile, "T01 UI candidate").move_speed) - 2.678901234567) < 1e-11, "保存其他字段时不得舍入未编辑数字")
	check(not visual._session.dirty(visual.draft_id), "一个入口保存后另一个入口更新保存状态")
	visual._field_changed(1.34567891234, "body_size")
	check(absf(float(combat._draft.body_size) - 1.34567891234) < 1e-11, "视觉入口编辑也能回到战斗面板")
	visual._session.undo(visual.draft_id)
	check(not combat._session.dirty(combat.draft_id), "共享撤销恢复两个入口的基线状态")
	await frames(4)
	check(absf(visual._inputs.body_size.get_line_edit().text.to_float() - float(visual.values.body_size)) < 1e-11, "绘制后视觉输入显示真实草稿值，不按箭头步长舍入")
	check(absf(combat._fields.body_size.get_line_edit().text.to_float() - float(combat._draft.body_size)) < 1e-11, "绘制后战斗输入保持真实精度")
	check(is_equal_approx(visual._inputs.body_size.custom_arrow_step, 0.05), "箭头仍沿用schema的操作步长")
	visual.visible = false
	combat.open_enemy("PrototypeSedimentTitan")
	combat._load_preset(Catalog.formal_preset("PrototypeSedimentTitan"))
	check(combat._source_info.text.contains(Catalog.formal_preset("PrototypeSedimentTitan")), "面板显式显示正式 Boss 引用")
	combat._request_overwrite()
	check(combat._overwrite.dialog_text.contains("正式沉积泰坦 Boss"), "覆盖确认列出正式引用范围")
	combat._overwrite.hide()
	combat._search.text = "thrust"
	combat._filter_fields("thrust")
	await frames(5)
	check(combat.position.y + combat.size.y <= root.get_visible_rect().size.y + 1.0, "紧凑面板底部不超出窗口")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join("t01_combat_parameters.png")) == OK, "保存实际战斗参数面板截图")
		combat.hide()
		visual.show()
		var visible_size := root.get_visible_rect().size
		visual.position = Vector2(visible_size.x - 372, 12)
		visual.size = Vector2(356, visible_size.y - 24)
		visual._search.text = "body_size"
		visual._filter_fields("body_size")
		await frames(4)
		await RenderingServer.frame_post_draw
		check(visual.is_visible_in_tree() and root.get_visible_rect().encloses(visual.get_global_rect()), "视觉面板位于实际逻辑视口内，兼容窗口缩放")
		var image := root.get_texture().get_image()
		var scale_factor := Vector2(image.get_size()) / visible_size
		var panel_rect := Rect2i(visual.get_global_rect().position * scale_factor, visual.size * scale_factor)
		var sampled := image.get_region(panel_rect)
		sampled.resize(16, 16)
		var distinct := {}
		for y in range(sampled.get_height()):
			for x in range(sampled.get_width()):
				distinct[sampled.get_pixel(x, y).to_rgba32()] = true
		check(distinct.size() > 8, "视觉截图包含实际面板内容，不能仅为纯背景")
		check(image.save_png(Artifacts.ensure_dir("screenshots").path_join("t01_visual_parameters.png")) == OK, "保存实际视觉参数面板截图")
	combat.queue_free()
	visual.queue_free()
	await frames(2)
