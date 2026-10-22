extends CanvasLayer
## T04：同一暂停圣所的两条试点链路，不扩充可写profile／招式。
const Nav := preload("res://scripts/testing/professional_navigation.gd")
const Session := preload("res://scripts/testing/tuning_session.gd")
const Runtime := preload("res://scripts/testing/workspace_runtime.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
var objects: Array[Node] = []
var selected: Node
var draft_id := ""
var list: ItemList
var status: Label
var detail: Label
var panel: PanelContainer
var visual_button: Button
var combat_button: Button
var opened := false
var last_application: Dictionary = {}
var marker: Label
var _hidden_huds: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 123
	panel = PanelContainer.new()
	panel.position = Vector2(8, 40)
	panel.custom_minimum_size = Vector2(435, 0)
	panel.theme = preload("res://scripts/testing/parameter_input.gd").compact_theme(preload("res://scripts/ui_theme.gd").get_theme(), 11)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(.025, .04, .04, .98)
	background.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", background)
	add_child(panel)
	var rows := VBoxContainer.new()
	panel.add_child(rows)
	detail = Label.new()
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(detail)
	list = ItemList.new()
	list.custom_minimum_size.y = 165
	list.item_selected.connect(_select_index)
	rows.add_child(list)
	_button(rows, "放置缺少的两条试点（本轮／不计波次）", spawn_trials)
	var actions := HBoxContainer.new()
	rows.add_child(actions)
	visual_button = _button(actions, "编辑外形", edit_visual)
	combat_button = _button(actions, "编辑技能／定格", edit_combat)
	_button(actions, "刷新对象", refresh)
	var apply_row := HBoxContainer.new()
	rows.add_child(apply_row)
	_button(apply_row, "应用当前", apply_current)
	_button(apply_row, "同方案全部", apply_peers)
	_button(apply_row, "重建当前", apply_current.bind(true))
	_button(rows, "已保存草稿方案 · 本场景选用（本进程重开保留）", choose_saved)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(status)
	var note := Label.new()
	note.text = "点身体／列表互选；遮挡时用列表。返回保持暂停，继续由暂停菜单操作。\n兜虫：外形；泰坦：仅三线重击定格。其他覆盖本批不补。"
	note.add_theme_font_size_override("font_size", 11)
	rows.add_child(note)
	_button(rows, "返回暂停菜单", close)
	panel.hide()
	marker = Label.new()
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.add_theme_color_override("font_color", Color.YELLOW)
	add_child(marker)

func _process(_delta: float) -> void:
	marker.visible = opened and is_instance_valid(selected) and selected.is_inside_tree()
	if not marker.visible: return
	var camera := get_viewport().get_camera_3d()
	if camera == null: marker.hide(); return
	marker.text = "▼ #%d" % selected.get_instance_id()
	marker.position = camera.unproject_position(selected.global_position) - Vector2(marker.size.x * 0.5, 28)
	marker.visible = not camera.is_position_behind(selected.global_position)

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 24
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func open() -> void:
	opened = true
	for hud: CanvasLayer in get_parent().find_children("WeatherDebugHUD", "CanvasLayer", true, false):
		_hidden_huds[hud] = hud.visible
		hud.hide()
	panel.show()
	get_parent().add_to_group("professional_workspaces")
	get_node("/root/GameFlow").set_meta("sanctum_workspace_modal", true)
	Nav.shared(get_tree()).set_local(close, "暂停菜单")
	refresh()
	get_tree().paused = true
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE

func refresh() -> void:
	objects.clear()
	list.clear()
	for object: Node in get_tree().get_nodes_in_group("enemies"):
		if not get_parent().is_ancestor_of(object): continue
		var identity := Runtime.identity(object)
		if identity.is_empty(): continue
		objects.append(object)
		var title := String(object.get_meta("enemy_entry", {}).get("title", "沉积泰坦"))
		list.add_item("%s · #%d · %s" % [title, object.get_instance_id(), "外形试点" if identity.profile == "VisualChargeBeetle" else "三线重击试点" if identity.profile == "PrototypeSedimentTitan" else "只读／待覆盖"])
		if object == selected: list.select(objects.size() - 1)
	if is_instance_valid(selected): _show_selected()
	else:
		visual_button.disabled = true
		combat_button.disabled = true
		detail.text = "圣所实战 · 请点选本轮实际对象（%d只在场）" % objects.size()
		status.text = "未选中；不会自动选择第一个或同类型替代实例"

func _select_index(index: int) -> void:
	if index < 0 or index >= objects.size(): return
	if selected != objects[index]: last_application = objects[index].get_meta("workspace_application", {}).duplicate(true)
	selected = objects[index]
	_show_selected()

func _show_selected() -> void:
	if not is_instance_valid(selected) or not selected.is_inside_tree():
		status.text = "来源目标已失效，草稿保留；请明确重选"
		return
	var identity := Runtime.identity(selected)
	var profile := String(identity.profile)
	var preset := Runtime.source_preset(selected, profile)
	# 首次绑定采用来源的实际方案；重入只复用同一target草稿。
	var session := Session.shared()
	var last := JSON.stringify([profile, Runtime.target_id(selected)])
	draft_id = session.open_profile(profile, "" if session._last.has(last) else preset, Runtime.target_id(selected))
	get_parent().set_meta("workspace_profile", profile)
	get_parent().set_meta("workspace_target_id", Runtime.target_id(selected))
	visual_button.disabled = profile != "VisualChargeBeetle"
	combat_button.disabled = profile not in ["VisualChargeBeetle", "PrototypeSedimentTitan"]
	var record: Dictionary = session.record(draft_id)
	if selected.get_meta("workspace_applied_revision", -1) == record.revision:
		last_application.merge(selected.get_meta("workspace_application", {}), true)
	detail.text = "圣所 · %s · %s\n来源采用：%s · 草稿：%s r%d · %s" % [identity.role_id, Runtime.target_id(selected), preset, record.preset, record.revision, "未保存" if session.dirty(draft_id) else "已载入／保存"]
	detail.tooltip_text = get_parent().scene_file_path + "\n本轮实例覆盖，不改变项目默认；保存候选与本场景选用分开。"
	status.text = "当前实例基础值／草稿值可在应用后展开提示；尚未应用" if last_application.is_empty() else String(last_application.get("reason", ""))

func edit_visual() -> void:
	if not is_instance_valid(selected) or visual_button.disabled: return
	Nav.shared(get_tree()).open(get_parent(), "res://prototypes/visual_lab/enemy_visual_lab.tscn", Runtime.identity(selected).profile, "combat")

func edit_combat() -> void:
	if not is_instance_valid(selected) or combat_button.disabled: return
	Nav.shared(get_tree()).open(get_parent(), "res://prototypes/combat_lab/combat_lab.tscn", Runtime.identity(selected).profile, "combat")

func returned() -> void:
	get_node("/root/GameFlow").set_meta("sanctum_workspace_modal", true)
	apply_current()

func apply_current(rebuild := false) -> void:
	if draft_id.is_empty(): return
	var profile: String = Session.shared().record(draft_id).profile
	# 在专业台明确选择其他候选后，返回采用该target的同一会话选择。
	draft_id = Session.shared().open_profile(profile, "", Session.shared().record(draft_id).target_id)
	last_application = Session.shared().test_selection(draft_id, get_parent().scene_file_path, func(packet: Dictionary): return Runtime.apply(packet, selected, rebuild))
	if last_application.is_empty(): last_application = {"runtime_applied": false, "reason": "草稿关系校验未通过；原实例保留最后有效运行值"}
	_show_selected()
	status.text = String(last_application.get("reason", ""))
	if is_instance_valid(selected):
		var changes := ""
		for stage in ["immediate", "next_action", "rebuild"]:
			for key: String in last_application.get(stage, []):
				changes += "%s：%s 草稿=%s／当前=%s\n" % [{"immediate":"即时", "next_action":"下次动作", "rebuild":"待重建"}[stage], key, Session.shared().values(draft_id)[key], Runtime.base_values(selected, profile).get(key)]
		status.tooltip_text = changes + "实际运行值（含实例差异／体型换算）：\n" + JSON.stringify(selected.get("_tuning"), "  ")

func apply_peers() -> void:
	if not is_instance_valid(selected) or draft_id.is_empty(): return
	var record: Dictionary = Session.shared().record(draft_id)
	var applied := 0
	var count := 0
	var details := ""
	for object: Node in objects:
		if not is_instance_valid(object) or Runtime.identity(object).get("profile") != record.profile: continue
		var preset := Runtime.source_preset(object, record.profile)
		var source_preset := Runtime.source_preset(selected, record.profile)
		if preset != source_preset: continue
		var result: Dictionary = Session.shared().test_selection(draft_id, get_parent().scene_file_path, func(packet: Dictionary): return Runtime.apply(packet, object, false, true))
		count += 1
		if result.get("runtime_applied", false): applied += 1
		details += "%s：%s\n" % [Runtime.target_id(object), result.get("reason", "候选校验失败，未应用")]
	status.text = "显式同方案 %d只 · 立即%d只；其余未应用／下次动作／待重建（悬停）；未改默认" % [count, applied]
	status.tooltip_text = details

func choose_saved() -> void:
	if draft_id.is_empty(): return
	var session := Session.shared()
	if session.dirty(draft_id) or not session.validation(draft_id).is_empty():
		status.text = "请先在归属台显式保存命名方案；不会自动保存／设为项目默认"
		return
	if session.choose_scene_preset(draft_id, get_parent().scene_file_path):
		status.text = "本场景已明确选用 %s；本进程内重开／新投放采用，现有实例仍按三档应用；未改项目默认" % session.record(draft_id).preset
	else: status.text = session.error

func spawn_trials() -> void:
	# 显式快速触发，不自动改现有战局；样本复用原宿主，不安装正式掉落／波次合同。
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player == null:
		status.text = "圣所尚未生成玩家；请从正式开始入口进入本轮"
		return
	var catalog := preload("res://scripts/testing/tuning_catalog.gd")
	for profile in ["VisualChargeBeetle", "PrototypeSedimentTitan"]:
		var present := false
		for object: Node in objects:
			if is_instance_valid(object) and Runtime.identity(object).get("profile") == profile: present = true
		if present: continue
		var identity := catalog.identity(profile)
		var preset: String = Session.shared().scene_preset(get_parent().scene_file_path, profile)
		if preset.is_empty(): preset = catalog.formal_preset(profile)
		if preset.is_empty(): preset = Tuning.active_name(profile)
		var values := Tuning.preset_values(profile, preset)
		var actor := (load(identity.combat_scene) as PackedScene).instantiate() as CharacterBody3D
		actor.set_meta("enemy_tuning", values)
		actor.set_meta("workspace_source_preset", preset)
		actor.set_meta("enemy_entry", {"species": identity.species, "title": "本轮裂甲兜虫" if profile == "VisualChargeBeetle" else "本轮沉积泰坦", "resolved_preset": preset, "tuning": values.duplicate(true)})
		actor.set_meta("workspace_trial", true)
		actor.set_meta("crowd_uniform", true)
		actor.set_meta("crowd_seed", 251021)
		var point: Vector3 = player.global_position + Vector3(-8 if profile == "VisualChargeBeetle" else 8, 0, -10)
		var dimensions: Vector3 = actor.get_script().get_body_dimensions(values) if actor.has_method("get_body_dimensions") else Vector3.ZERO
		point.y = preload("res://scripts/terrain_field.gd").height_at(point.x, point.z) + dimensions.y * float(values.body_size) * .5 + .15
		actor.position = point
		get_parent().get_node("Enemies").add_child(actor)
		if dimensions == Vector3.ZERO: actor.position.y += actor.get_stand_height()
		actor.target = player
	refresh()
	status.text = "试点已在本轮；不会加入波次、掉落或计击杀。请选择身体／列表，继续前保持暂停。"

func close() -> void:
	opened = false
	for hud in _hidden_huds:
		if is_instance_valid(hud): hud.visible = _hidden_huds[hud]
	_hidden_huds.clear()
	panel.hide()
	get_parent().remove_from_group("professional_workspaces")
	get_node("/root/GameFlow").remove_meta("sanctum_workspace_modal")
	Nav.shared(get_tree()).set_local()
	get_node("/root/GameFlow")._enter_pause()

func _unhandled_input(event: InputEvent) -> void:
	if not opened or Nav.modal(get_tree()): return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var camera := get_viewport().get_camera_3d()
		if camera == null: return
		var origin := camera.project_ray_origin(event.position)
		var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(event.position) * 500.0, 4)
		var hit := (get_parent() as Node3D).get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty(): return
		var index := objects.find(hit.collider)
		if index >= 0:
			list.select(index)
			list.ensure_current_is_visible()
			_select_index(index)
			get_viewport().set_input_as_handled()
