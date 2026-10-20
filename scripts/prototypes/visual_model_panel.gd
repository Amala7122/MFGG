extends PanelContainer
## Visual-only profiles use the same schemas and preset store as combat prototypes.
const Tuning = preload("res://scripts/prototypes/enemy_tuning.gd")
const Session := preload("res://scripts/testing/tuning_session.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const InputField := preload("res://scripts/testing/parameter_input.gd")
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
signal values_changed(values: Dictionary)
signal field_focused(key: String)
signal pose_selected(index: int)
signal replay_requested
signal seek_requested(fraction: float)
var profile := ""
var values: Dictionary = {}
var draft_id := ""
var _session: RefCounted
var _inputs: Dictionary = {}
var _pending: Dictionary = {}
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
	button(history, "撤销", func(): _pending.clear(); _session.undo(draft_id); _on_session_changed(draft_id))
	button(history, "重做", func(): _pending.clear(); _session.redo(draft_id); _on_session_changed(draft_id))
	button(history, "还原草稿", func(): _pending.clear(); _session.restore(draft_id))
	button(history, "重读…", _request_reload)
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
	control.focus_mode = Control.FOCUS_NONE
	control.pressed.connect(action)
	parent.add_child(control)

func bind_profile(id: String) -> void:
	if not draft_id.is_empty() and not _commit_inputs(): return
	profile = id
	visible = not id.is_empty()
	if not visible:
		return
	draft_id = _session.open_profile(id)
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
	poses.select(int(node.get("preview_pose")))
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
	_inputs.clear()
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
				if not updating: _pending[key] = text; _refresh_status())
			spin.get_line_edit().text_submitted.connect(func(_text: String): _commit_inputs())
			spin.get_line_edit().focus_exited.connect(func(): _commit_inputs())
			# 悬停或改动都告诉观察台：这个参数动的是哪一块、作用在哪个阶段。
			spin.mouse_entered.connect(func() -> void: field_focused.emit(key))
			row.mouse_entered.connect(func() -> void: field_focused.emit(key))
			row.add_child(spin)
			_inputs[key] = spin
			var unit := Label.new()
			unit.text = InputField.unit(profile, field)
			unit.custom_minimum_size.x = 26
			row.add_child(unit)
	updating = false
	_filter_fields(_search.text)
	_on_session_changed.call_deferred(draft_id)

func _field_changed(value: Variant, key: String) -> void:
	if updating: return
	if _pending.has(key) and _inputs[key] is SpinBox:
		value = InputField.exact_change(_inputs[key], float(value), _pending[key])
	_pending.erase(key)
	if _inputs[key] is SpinBox: value = Layout.stored_number(key, float(value))
	if not _session.set_value(draft_id, key, value): status.text = _session.error
	_on_session_changed.call_deferred(draft_id)

func _refresh_presets(select_name := "") -> void:
	presets.clear()
	for title in Tuning.preset_names(profile):
		presets.add_item(title)
		if title == select_name or (select_name.is_empty() and title == Tuning.active_name(profile)):
			presets.select(presets.item_count - 1)

func _refresh_status() -> void:
	if draft_id.is_empty() or profile.is_empty(): return
	var d: Dictionary = _session.record(draft_id)
	status.text = "%s · %s · 修订 %d\n当前默认：%s\n外形预览即时；战斗属性重新生成生效。%s" % [d.preset, "输入待提交" if not _pending.is_empty() else "未保存" if _session.dirty(draft_id) else "已载入／保存", d.revision, Tuning.active_name(profile), _session.validation(draft_id)]

func _load_selected() -> void:
	if not _commit_inputs(): return
	var title := presets.get_item_text(presets.selected)
	draft_id = _session.open_profile(profile, title)
	values = _session.values(draft_id)
	preset_name.text = _session.record(draft_id).candidate_name
	_build_fields()
	values_changed.emit(values)
	_refresh_status()

func _save() -> void:
	if not _commit_inputs(): return
	var title := preset_name.text.strip_edges()
	if not _session.save_as(draft_id, title):
		status.text = _session.error
		return
	_refresh_presets(title)
	_refresh_status()

func _activate() -> void:
	if not _commit_inputs(): return
	if _session.activate(draft_id):
		_refresh_status()
	else:
		status.text = _session.error

func _commit_inputs() -> bool:
	for key: String in _pending.keys():
		var entered: String = _pending[key]
		var parsed := InputField.read_number(_inputs[key], entered)
		if not parsed.ok:
			(_inputs[key] as SpinBox).get_line_edit().text = entered
			status.text = key + "：" + String(parsed.error)
			return false
		_pending.erase(key)
		if not _session.set_value(draft_id, key, Layout.stored_number(key, float(parsed.value))):
			_pending[key] = entered
			status.text = _session.error
			return false
	return true

func _on_session_changed(key: String) -> void:
	if draft_id.is_empty() or profile.is_empty() or (not key.is_empty() and key != draft_id): return
	var previous := values
	values = _session.values(draft_id)
	updating = true
	for field: String in _inputs:
		if _pending.has(field): continue
		if _inputs[field] is SpinBox: InputField.update_number(_inputs[field], Layout.display_number(field, float(values[field])))
		else: _inputs[field].set_pressed_no_signal(bool(values[field]))
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
		status.text = "新名称请保存候选；基础值不可覆盖。"
		return
	_overwrite_request = {"kind": "save", "draft": draft_id, "name": name, "fingerprint": expected}
	var refs := Catalog.references(profile, name)
	_overwrite.dialog_text = "覆盖：%s\n引用范围：%s\n下次读取会采用新内容；当前默认选择不变。" % [name, "、".join(refs) if not refs.is_empty() else "已登记关卡无直接引用，其他同名引用仍可能采用"]
	_overwrite.popup_centered(Vector2i(560, 180))

func _confirm_overwrite() -> void:
	if _overwrite_request.get("draft") != draft_id: return
	if _overwrite_request.get("kind") == "reload":
		_pending.clear()
		status.text = "已重新读取磁盘方案" if _session.reload_from_disk(draft_id, true) else _session.error
		return
	if not _session.save_as(draft_id, _overwrite_request.name, true, _overwrite_request.fingerprint):
		status.text = _session.error
		return
	_refresh_presets(_overwrite_request.name)
	_refresh_status()

func _request_reload() -> void:
	if _session.dirty(draft_id) or not _pending.is_empty():
		_overwrite_request = {"kind": "reload", "draft": draft_id}
		_overwrite.dialog_text = "丢弃当前未保存修改／输入后重读磁盘？其他草稿保留。"
		_overwrite.popup_centered(Vector2i(540, 150))
	else:
		status.text = "已重新读取磁盘方案" if _session.reload_from_disk(draft_id) else _session.error

func _filter_fields(query: String) -> void:
	var text := query.strip_edges().to_lower()
	for heading: Control in _headers: heading.visible = false
	for row: Control in _filter_rows:
		row.visible = text.is_empty() or String(row.get_meta("search")).contains(text)
		if row.visible:
			row.get_meta("heading").visible = true
			row.get_meta("subheading").visible = true
