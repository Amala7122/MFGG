extends PanelContainer
## Visual-only profiles use the same schemas and preset store as combat prototypes.
const Tuning = preload("res://scripts/prototypes/enemy_tuning.gd")
const Session := preload("res://scripts/testing/tuning_session.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const InputField := preload("res://scripts/testing/parameter_input.gd")
const Ownership := preload("res://scripts/testing/enemy_parameter_ownership.gd")
const DOMAIN := "visual"
var writable := true
var _readonly: Dictionary = {}
var _pending_cache: Dictionary = {}
var _domain_actions: Array[Button] = []
var _show_references: CheckBox
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
signal combat_requested(profile: String)
signal values_changed(values: Dictionary)
signal field_focused(key: String)
signal pose_selected(index: int)
signal replay_requested
signal seek_requested(fraction: float)
var profile := ""
var values: Dictionary = {}
var draft_id := ""
var target_id := ""
var _session: RefCounted
var _inputs: Dictionary = {}
var _pending: Dictionary = {}
var _notice := ""
var _notice_error := false
var _search: LineEdit
var _filter_rows: Array[Control] = []
var _headers: Array[Control] = []
var _overwrite: ConfirmationDialog
var _overwrite_request: Dictionary = {}
var fields: VBoxContainer
var presets: OptionButton
var preset_name: LineEdit
var status: Label
var poses: OptionButton
var timeline: HSlider
var updating := false
var subject: Node3D
var demo_row: HBoxContainer
var demo_toggle: CheckButton
var demo_distance: SpinBox
var demo_status: Label
var _replay_button: Button

func _ready() -> void:
	theme = InputField.compact_theme(preload("res://scripts/ui_theme.gd").get_theme(), 11)
	_session = Session.shared()
	_session.changed.connect(_on_session_changed)
	custom_minimum_size.x = 300
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 8)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	margin.add_child(column)
	var title := Label.new()
	title.text = "视觉测试台 · 外形草稿"
	column.add_child(title)
	var route := HBoxContainer.new()
	column.add_child(route)
	button(route, "技能 ↗", _request_combat)
	_show_references = CheckBox.new()
	_show_references.text = "战斗参考（只读）"
	_show_references.toggled.connect(func(_enabled: bool): _filter_fields(_search.text))
	route.add_child(_show_references)
	var playback := HBoxContainer.new()
	column.add_child(playback)
	poses = OptionButton.new()
	poses.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for label in ["待机", "原地步态", "技能循环（仅动作）", "蓄力定格"]:
		poses.add_item(label)
	poses.item_selected.connect(func(index: int): pose_selected.emit(index))
	playback.add_child(poses)
	button(playback, "重播", func(): replay_requested.emit())
	timeline = HSlider.new()
	timeline.max_value = 1
	timeline.step = 0.005
	timeline.tooltip_text = "拖动即冻结：定位当前动作周期的任意时刻；点重播继续"
	timeline.value_changed.connect(func(value: float):
		if not updating:
			seek_requested.emit(value))
	column.add_child(timeline)
	demo_row = HBoxContainer.new()
	column.add_child(demo_row)
	demo_toggle = CheckButton.new()
	demo_toggle.text = "范围测试"
	demo_toggle.tooltip_text = "虚拟玩家距离驱动真实行为模块，进入撤退范围会立即取消投囊。"
	demo_row.add_child(demo_toggle)
	demo_distance = SpinBox.new()
	demo_distance.min_value = 0.5
	demo_distance.max_value = 40
	demo_distance.step = 0.5
	demo_distance.suffix = "米"
	demo_row.add_child(demo_distance)
	demo_toggle.toggled.connect(func(enabled: bool):
		if is_instance_valid(subject) and subject.has_method("set_behavior_demo"):
			subject.call("set_behavior_demo", enabled, demo_distance.value))
	demo_distance.value_changed.connect(func(distance: float):
		if is_instance_valid(subject) and subject.has_method("set_behavior_demo"):
			subject.set("preview_player_distance", distance))
	demo_status = Label.new()
	column.add_child(demo_status)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索参数／模块"
	_search.text_changed.connect(_filter_fields)
	column.add_child(_search)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	fields = VBoxContainer.new()
	fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(fields)
	var preset_row := HBoxContainer.new()
	column.add_child(preset_row)
	presets = OptionButton.new()
	presets.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_row.add_child(presets)
	button(preset_row, "载入", _load_selected)
	preset_name = LineEdit.new()
	preset_name.max_length = 64
	preset_name.text_changed.connect(func(text: String):
		if not draft_id.is_empty(): _session.set_candidate_name(draft_id, text))
	preset_name.placeholder_text = "命名方案，例如：宽甲短角"
	column.add_child(preset_name)
	var save_row := HBoxContainer.new()
	column.add_child(save_row)
	button(save_row, "保存候选", _save)
	button(save_row, "覆盖同名…", _request_overwrite)
	button(save_row, "设为默认", _activate)
	var history := HBoxContainer.new()
	column.add_child(history)
	button(history, "撤销", func(): _history(false))
	button(history, "重做", func(): _history(true))
	button(history, "还原外形", func(): _pending.clear(); _session.restore_domain(draft_id, DOMAIN); _on_session_changed(draft_id))
	button(history, "重读…", _request_reload)
	button(history, "撤回输入", _discard_pending)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status)
	_overwrite = ConfirmationDialog.new()
	_overwrite.title = "覆盖已有方案"
	_overwrite.confirmed.connect(_confirm_overwrite)
	add_child(_overwrite)

func button(parent: Node, title: String, action: Callable) -> void:
	var control := Button.new()
	control.text = title
	if title == "重播": _replay_button = control
	control.tooltip_text = {"保存候选": "保存当前对象外形与战斗的整份已提交草稿；不自动设为默认。", "还原外形": "只还原视觉模块最近载入／保存时的值，保留战斗修改。", "技能 ↗": "进入战斗原型测试台编辑技能；返回保留草稿、原文和观察状态。", "撤销": "只撤销最新的本模块操作；其他模块的历史须通过专业入口处理。", "重做": "只重做最新的本模块操作。"}.get(title, title)
	control.set_meta("action_tip", control.tooltip_text)
	if title in ["撤销", "重做", "还原外形"]: _domain_actions.append(control)
	control.focus_mode = Control.FOCUS_NONE
	control.pressed.connect(action)
	parent.add_child(control)
	# 五个恢复动作放同一行；不能沿用游戏菜单每侧18px的大边距挤出侧栏。
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style: StyleBox = control.get_theme_stylebox(state).duplicate()
		style.content_margin_left = 6
		style.content_margin_right = 6
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		control.add_theme_stylebox_override(state, style)

func bind_profile(id: String, can_edit := true) -> void:
	if not draft_id.is_empty() and not _commit_inputs(): return
	if not draft_id.is_empty(): _pending_cache[draft_id] = _pending.duplicate()
	_session.store_view(draft_id, DOMAIN, {"pending": _pending.duplicate()})
	writable = can_edit
	for action in _domain_actions:
		action.disabled = not writable
		action.tooltip_text = "该宿主外形编辑尚未接入，本页仅供观察；不会通过恢复动作绕过权限" if not writable else String(action.get_meta("action_tip"))
	profile = id
	visible = not id.is_empty()
	if not visible:
		return
	draft_id = _session.open_profile(id, "", target_id)
	values = _session.values(draft_id)
	_build_fields()
	_refresh_presets(_session.record(draft_id).preset)
	preset_name.text = _session.record(draft_id).candidate_name
	_refresh_status()

func bind_subject(node: Node3D) -> void:
	subject = node
	updating = true
	poses.clear()
	var names: Array = node.call("get_preview_pose_names") if node.has_method("get_preview_pose_names") else ["待机", "原地步态", "技能循环", "蓄力定格"]
	for title in names:
		poses.add_item(String(title))
	var scrub := node.has_method("set_preview_pose") and node.has_method("sample_pose")
	poses.disabled = not scrub
	_replay_button.disabled = not scrub
	_replay_button.tooltip_text = "该战斗体不支持动作采样；用M冻结／慢放，真实技能通过“技能 ↗”观察" if not scrub else "重播当前动作"
	timeline.visible = scrub
	poses.tooltip_text = "该战斗体仅支持冻结与慢放；动作采样不受支持" if not scrub else "选择纯动作姿态；真实技能通过战斗原型台观察"
	if scrub: poses.select(int(node.get("preview_pose")))
	demo_row.visible = node.has_method("set_behavior_demo")
	demo_status.visible = demo_row.visible
	demo_toggle.set_pressed_no_signal(false)
	if demo_row.visible:
		demo_distance.value = float(values.attack_range)
	updating = false

func stop_demo() -> void:
	if demo_toggle.button_pressed:
		demo_toggle.button_pressed = false

func _process(_delta: float) -> void:
	if demo_toggle != null and demo_toggle.button_pressed and is_instance_valid(subject):
		var controller = subject.get("behavior")
		demo_status.text = ["待机", "先转身", "投囊", "收甲回位", "近身撤退", "死亡"][int(controller.state)]
		poses.select(int(subject.get("preview_pose")))

func _build_fields() -> void:
	updating = true
	var retained: Dictionary = _session.view_data(draft_id, DOMAIN).get("pending", _pending_cache.get(draft_id, {})).duplicate()
	_inputs.clear()
	_readonly.clear()
	_pending.clear()
	_filter_rows.clear()
	_headers.clear()
	for child in fields.get_children():
		child.free()
	for group: Dictionary in Layout.groups(profile, Tuning.get_schema(profile)):
		var heading := Label.new()
		heading.text = String(group.title)
		fields.add_child(heading)
		_headers.append(heading)
		var section := ""
		var subheading: Label
		for field: Dictionary in group.fields:
			if field.section != section:
				section = field.section
				subheading = Label.new()
				subheading.text = "  " + section
				fields.add_child(subheading)
				_headers.append(subheading)
			var row := HBoxContainer.new()
			fields.add_child(row)
			row.set_meta("search", (String(group.title) + section + String(field.label) + String(field.key)).to_lower())
			row.set_meta("heading", heading)
			row.set_meta("subheading", subheading)
			row.tooltip_text = InputField.tooltip(profile, field)
			_filter_rows.append(row)
			var label := Label.new()
			label.text = String(field.label)
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			label.custom_minimum_size.x = 112
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(label)
			var key := String(field.key)
			row.set_meta("reference", not Ownership.editable(profile, key, DOMAIN))
			row.tooltip_text += "\n归属：" + Ownership.title(profile, key) + "\n" + Ownership.dependency(profile, key)
			if not writable or not Ownership.editable(profile, key, DOMAIN):
				var reference := Label.new()
				reference.add_theme_font_size_override("font_size", 11)
				row.add_child(reference)
				_readonly[key] = reference
				continue
			if field.value is bool:
				var toggle := CheckButton.new()
				toggle.button_pressed = bool(values[key])
				toggle.tooltip_text = String(field.get("tip", "保存后用于下一次实例"))
				toggle.toggled.connect(_field_changed.bind(key))
				toggle.mouse_entered.connect(func() -> void: field_focused.emit(key))
				row.mouse_entered.connect(func() -> void: field_focused.emit(key))
				row.add_child(toggle)
				_inputs[key] = toggle
				continue
			var spin := SpinBox.new()
			spin.min_value = float(field.min)
			spin.max_value = float(field.max)
			InputField.configure_step(spin, float(field.step))
			InputField.update_number(spin, Layout.display_number(key, float(values[field.key])))
			spin.custom_minimum_size.x = 96
			spin.tooltip_text = "%s – %s；%s" % [field.min, field.max, String(field.get("tip", "即时预览；保存后可复用"))]
			spin.value_changed.connect(_field_changed.bind(String(field.key)))
			spin.get_line_edit().text_changed.connect(func(text: String):
				if not updating: _pending[key] = text; _notice = ""; _notice_error = false; _refresh_status(); _restore_pending.call_deferred())
			spin.get_line_edit().text_submitted.connect(func(_text: String): _commit_inputs())
			spin.get_line_edit().focus_exited.connect(func(): _commit_inputs())
			spin.get_line_edit().focus_entered.connect(func(): _restore_pending.call_deferred())
			# 悬停或改动都告诉观察台：这个参数动的是哪一块、作用在哪个阶段。
			spin.mouse_entered.connect(func() -> void: field_focused.emit(key))
			row.mouse_entered.connect(func() -> void: field_focused.emit(key))
			row.add_child(spin)
			_inputs[key] = spin
			var unit := Label.new()
			unit.text = InputField.unit(profile, field)
			unit.custom_minimum_size.x = 26
			row.add_child(unit)
	_pending = retained
	_restore_pending()
	updating = false
	_filter_fields(_search.text)
	_on_session_changed.call_deferred(draft_id)

func _field_changed(value: Variant, key: String) -> void:
	if updating or not _inputs.has(key): return
	if _pending.has(key) and _inputs[key] is SpinBox:
		var parsed := InputField.read_number(_inputs[key], _pending[key])
		if not parsed.ok or not Tuning.field_issue(Catalog.field(profile, key), Layout.stored_number(key, float(parsed.get("value", 0.0)))).is_empty():
			_restore_pending.call_deferred()
			_refresh_status()
			return
		value = InputField.exact_change(_inputs[key], float(value), _pending[key])
	if _inputs[key] is SpinBox: value = Layout.stored_number(key, float(value))
	if not Tuning.field_issue(Catalog.field(profile, key), value).is_empty():
		if not _pending.has(key): _pending[key] = String.num(Layout.display_number(key, float(value)), 12)
		_restore_pending.call_deferred()
		_refresh_status()
		return
	_pending.erase(key)
	_notice = ""
	_notice_error = false
	if not _session.set_domain_value(draft_id, DOMAIN, key, value): _show_failure("修改参数", _session.error)
	_on_session_changed.call_deferred(draft_id)

func _restore_pending() -> void:
	for key: String in _pending:
		if _inputs.has(key) and _inputs[key] is SpinBox:
			var edit: LineEdit = _inputs[key].get_line_edit()
			if edit.text != String(_pending[key]): edit.text = String(_pending[key])

func _discard_pending() -> void:
	_pending.clear()
	_notice = "未提交文字已撤回，已提交草稿保留；未写磁盘。"
	_notice_error = false
	_on_session_changed(draft_id)

func _refresh_presets(select_name := "") -> void:
	presets.clear()
	for title in Tuning.preset_names(profile):
		presets.add_item(title)
		if title == select_name or (select_name.is_empty() and title == Tuning.active_name(profile)):
			presets.select(presets.item_count - 1)

func _refresh_status() -> void:
	if draft_id.is_empty() or profile.is_empty(): return
	_pending_cache[draft_id] = _pending.duplicate()
	_session.store_view(draft_id, DOMAIN, {"pending": _pending.duplicate()})
	var d: Dictionary = _session.record(draft_id)
	var inspection := InputField.inspect_pending(profile, _inputs, _pending, values)
	InputField.mark_issues(_inputs, inspection.issues)
	var state := "输入待提交" if not _pending.is_empty() else "未保存" if _session.dirty(draft_id) else "已载入／保存"
	var application := "只读观察：该宿主外形编辑尚未接入" if not writable else "战斗样本已重建；正式现场待生成" if subject is CharacterBody3D else "模型已应用；保存包含整份草稿"
	status.text = InputField.describe(profile, inspection.issues, "", true) if not inspection.issues.is_empty() else _notice if _notice_error else "%s · %s · r%d\n%s" % [d.preset, state, d.revision, application]
	status.tooltip_text = "%s\n当前默认：%s\n保存包含外形与战斗的整份已提交草稿。%s" % [status.text, Tuning.active_name(profile), _notice]
	status.add_theme_color_override("font_color", Color(1.0, 0.42, 0.32) if not inspection.issues.is_empty() or _notice_error else Color(0.96, 0.91, 0.76))

func _set_notice(text: String, failed := false) -> void:
	_notice = text
	_notice_error = failed
	_refresh_status()

func _show_failure(action: String, reason: String) -> void:
	_set_notice("无法%s：%s；草稿已保留。" % [action, reason], true)

func _load_selected() -> void:
	if not _commit_inputs(): return
	var title := presets.get_item_text(presets.selected)
	draft_id = _session.open_profile(profile, title, target_id)
	values = _session.values(draft_id)
	preset_name.text = _session.record(draft_id).candidate_name
	_build_fields()
	values_changed.emit(values)
	_refresh_status()

func _save() -> void:
	if not _commit_inputs(): return
	var title := preset_name.text.strip_edges()
	if not _session.save_as(draft_id, title):
		_show_failure("保存候选", _session.error)
		return
	_refresh_presets(title)
	_refresh_status()

func _activate() -> void:
	if not _commit_inputs(): return
	if _session.activate(draft_id):
		_refresh_status()
	else:
		_show_failure("提交／保存草稿", _session.error)

func _commit_inputs() -> bool:
	# 观察战斗实体时没有绑定可编辑profile；旧草稿仍由Session保留，不能用空身份校验它。
	if updating or draft_id.is_empty() or profile.is_empty(): return true
	var inspection := InputField.inspect_pending(profile, _inputs, _pending, values)
	if not inspection.issues.is_empty():
		_restore_pending()
		_restore_pending.call_deferred()
		_refresh_status()
		# 视觉面板搜索可能隐藏错误字段；失败时直接定位，保留原始文字。
		_search.text = ""
		_filter_fields("")
		if not inspection.issues[0].keys.is_empty():
			var key := String(inspection.issues[0].keys[0])
			if _inputs.has(key): fields.get_parent().call_deferred("ensure_control_visible", _inputs[key].get_parent())
		return false
	var keys := _pending.keys()
	_pending.clear()
	for key: String in keys:
		if not _session.set_domain_value(draft_id, DOMAIN, key, inspection.values[key]):
			_show_failure("提交／保存草稿", _session.error)
			return false
	_refresh_status()
	return true

func _on_session_changed(key: String) -> void:
	if not is_inside_tree(): return
	if draft_id.is_empty() or profile.is_empty() or (not key.is_empty() and key != draft_id): return
	var previous := values
	values = _session.values(draft_id)
	updating = true
	for field: String in _inputs:
		if _pending.has(field): continue
		if _inputs[field] is SpinBox: InputField.update_number(_inputs[field], Layout.display_number(field, float(values[field])))
		else: _inputs[field].set_pressed_no_signal(bool(values[field]))
	for field: String in _readonly:
		_readonly[field].text = String.num(Layout.display_number(field, float(values[field])), 12) if values[field] is float or values[field] is int else str(values[field])
		_readonly[field].tooltip_text = Ownership.title(profile, field) + "／" + InputField.unit(profile, Catalog.field(profile, field))
	updating = false
	var name: String = _session.record(draft_id).preset
	if presets.item_count != Tuning.preset_names(profile).size() or presets.get_item_text(presets.selected) != name: _refresh_presets(name)
	_refresh_status()
	if previous != values: values_changed.emit(values)

func _request_overwrite() -> void:
	if not _commit_inputs(): return
	var name := preset_name.text.strip_edges()
	var expected := Tuning.saved_fingerprint(profile, name, true)
	if expected.is_empty() or name == Tuning.DEFAULT_PRESET:
		_set_notice("新名称请保存候选；基础值不可覆盖。")
		return
	_overwrite_request = {"kind": "save", "draft": draft_id, "name": name, "fingerprint": expected}
	var refs := Catalog.references(profile, name)
	_overwrite.dialog_text = "覆盖整份方案（外形＋战斗草稿）：%s\n引用范围：%s\n下次读取会采用新内容；当前默认选择不变。" % [name, "、".join(refs) if not refs.is_empty() else "已登记关卡无直接引用，其他同名引用仍可能采用"]
	_overwrite.popup_centered(Vector2i(560, 180))

func _confirm_overwrite() -> void:
	if _overwrite_request.get("draft") != draft_id: return
	if _overwrite_request.get("kind") == "reload":
		_pending.clear()
		_set_notice("已重新读取磁盘方案" if _session.reload_from_disk(draft_id, true) else _session.error)
		return
	if not _session.save_as(draft_id, _overwrite_request.name, true, _overwrite_request.fingerprint):
		_show_failure("提交／保存草稿", _session.error)
		return
	_refresh_presets(_overwrite_request.name)
	_refresh_status()

func _request_reload() -> void:
	if _session.dirty(draft_id) or not _pending.is_empty():
		_overwrite_request = {"kind": "reload", "draft": draft_id}
		_overwrite.dialog_text = "重读整份方案：丢弃本对象各模块已提交草稿及本页未提交输入？其他草稿保留。"
		_overwrite.popup_centered(Vector2i(540, 150))
	else:
		_set_notice("已重新读取磁盘方案" if _session.reload_from_disk(draft_id) else _session.error)

func _filter_fields(query: String) -> void:
	var text := query.strip_edges().to_lower()
	for heading: Control in _headers: heading.visible = false
	for row: Control in _filter_rows:
		row.visible = (text.is_empty() or String(row.get_meta("search")).contains(text)) and (not row.get_meta("reference", false) or _show_references.button_pressed or not text.is_empty())
		if row.visible:
			row.get_meta("heading").visible = true
			row.get_meta("subheading").visible = true

func _history(forward: bool) -> void:
	if not _session.domain_history(draft_id, DOMAIN, forward):
		_set_notice(_session.error, true)
		return
	_pending.clear()
	_on_session_changed(draft_id)

func _request_combat() -> void:
	_commit_inputs()
	_pending_cache[draft_id] = _pending.duplicate()
	_session.store_view(draft_id, DOMAIN, {"pending": _pending.duplicate()})
	combat_requested.emit(profile)

func remember_view() -> void:
	_session.store_view(draft_id, DOMAIN, {"pending": _pending.duplicate()})

func resume_view() -> void:
	_pending = _session.view_data(draft_id, DOMAIN).get("pending", _pending).duplicate()
	_on_session_changed(draft_id)
