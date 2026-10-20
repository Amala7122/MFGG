extends PanelContainer
## 面板根据参数配置生成控件；不维护另一份数值默认值。

signal saved(id: String, name: String)
signal default_changed(id: String, name: String)
signal closed
signal observe_requested(profile: String, values: Dictionary)

const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const UI := preload("res://scripts/ui_theme.gd")
const Session := preload("res://scripts/testing/tuning_session.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const InputField := preload("res://scripts/testing/parameter_input.gd")
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
var _session: RefCounted
var draft_id := ""
var _source_info: Label
var _search: LineEdit
var _formal: Button
var _overwrite: ConfirmationDialog
var _overwrite_request: Dictionary = {}
var _rows: Array[Control] = []
var enemy_id := ""
var _draft: Dictionary = {}
var _fields: Dictionary = {}
var _pending_text: Dictionary = {}
var _enemy_choice: OptionButton
var _preset_choice: OptionButton
var _name_edit: LineEdit
var _message: Label
var _tabs: TabContainer
var _grids: Array[GridContainer] = []
var _loading := false
var _layout_pending := false


func _ready() -> void:
	minimum_size_changed.connect(_queue_layout)
	theme = InputField.compact_theme(UI.get_theme())
	_session = Session.shared()
	_session.changed.connect(_on_session_changed)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.065, 0.105, 0.09, 0.98)
	style.border_color = UI.COLOR_TITLE
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	add_child(column)
	column.add_child(_label("战斗原型测试台 · 参数", 14, UI.COLOR_TITLE))
	_source_info = _label("", 12)
	_source_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_source_info)
	var note := _label("距离按体型联动；生命／伤害／时序独立。悬停查看原字段与规则。草稿可直接单体观察。", 11, UI.COLOR_DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	var choices := HBoxContainer.new()
	column.add_child(choices)
	choices.add_child(_label("敌人", 12))
	_enemy_choice = OptionButton.new()
	_enemy_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id: String in Tuning.PROFILE_PATHS:
		_enemy_choice.add_item(String(Tuning.get_schema(id).get("title", id)).split(" · ")[0])
		_enemy_choice.set_item_metadata(_enemy_choice.item_count - 1, id)
	_enemy_choice.item_selected.connect(_on_enemy_selected)
	choices.add_child(_enemy_choice)
	choices.add_child(_label("方案", 12))
	_preset_choice = OptionButton.new()
	_preset_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_choice.item_selected.connect(_on_preset_selected)
	choices.add_child(_preset_choice)
	_formal = Button.new()
	_formal.text = "载入正式 Boss 引用"
	_formal.pressed.connect(func(): _load_preset(Catalog.formal_preset(enemy_id)))
	choices.add_child(_formal)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索参数名称、模块或字段"
	_search.text_changed.connect(_filter_fields)
	column.add_child(_search)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_font_size_override("font_size", 12)
	column.add_child(_tabs)
	var name_row := HBoxContainer.new()
	column.add_child(name_row)
	name_row.add_child(_label("候选名称", 12))
	_name_edit = LineEdit.new()
	_name_edit.name = "PresetName"
	_name_edit.max_length = 64
	_name_edit.text_changed.connect(func(text: String):
		if not draft_id.is_empty(): _session.set_candidate_name(draft_id, text))
	_name_edit.placeholder_text = "例如：高血量练习 / 快速前摇"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_edit)
	_message = _label("", 12, UI.COLOR_DIM)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_message)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	_button(actions, "保存候选", save_current)
	_button(actions, "覆盖同名…", _request_overwrite)
	_button(actions, "设为当前默认", _activate)
	_button(actions, "撤销", func(): _pending_text.clear(); _session.undo(draft_id); _on_session_changed(draft_id))
	_button(actions, "重做", func(): _pending_text.clear(); _session.redo(draft_id); _on_session_changed(draft_id))
	var reset := HBoxContainer.new()
	column.add_child(reset)
	_button(reset, "还原本草稿", func(): _pending_text.clear(); _session.restore(draft_id))
	_button(reset, "载入基础值", _restore_defaults)
	_button(reset, "重读磁盘…", _request_reload)
	_button(reset, "观察本草稿", func():
		if _commit_inputs() and _session.validation(draft_id).is_empty(): observe_requested.emit(enemy_id, _session.values(draft_id)))
	_button(reset, "返回敌人配置", func():
		if _commit_inputs(): closed.emit())
	_overwrite = ConfirmationDialog.new()
	_overwrite.title = "覆盖已有方案"
	_overwrite.confirmed.connect(_confirm_overwrite)
	add_child(_overwrite)
	visible = false


func open_enemy(id: String) -> void:
	if not Tuning.PROFILE_PATHS.has(id):
		return
	if not draft_id.is_empty() and not _commit_inputs():
		_select_enemy(enemy_id)
		return
	enemy_id = id
	draft_id = _session.open_profile(id)
	_select_enemy(id)
	_refresh_presets(_session.record(draft_id).preset)
	_build_fields(_session.values(draft_id))
	_formal.visible = not Catalog.formal_preset(id).is_empty()
	_message.text = "本轮草稿已载入；未写入项目。"
	_update_source()
	visible = true
	layout_panel()


func _select_enemy(id: String) -> void:
	for index in range(_enemy_choice.item_count):
		if _enemy_choice.get_item_metadata(index) == id:
			_enemy_choice.select(index)


func layout_panel() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var width := minf(1000.0, viewport_size.x - 24.0)
	position = Vector2((viewport_size.x - width) * 0.5, 40)
	size = Vector2(width, maxf(viewport_size.y - 52.0, 240.0))
	for grid in _grids:
		grid.columns = 2 if width >= 820.0 else 1


func _queue_layout() -> void:
	# 动态分页先产生较大的临时最小尺寸，滚动容器排版后才收缩。
	# 再次按视口定尺寸，避免把保存/返回按钮留在窗口之外。
	if _layout_pending:
		return
	_layout_pending = true
	_apply_deferred_layout.call_deferred()


func _apply_deferred_layout() -> void:
	_layout_pending = false
	layout_panel()


func _on_enemy_selected(index: int) -> void:
	open_enemy(String(_enemy_choice.get_item_metadata(index)))


func _refresh_presets(selected: String) -> void:
	_preset_choice.clear()
	for name in Tuning.preset_names(enemy_id):
		_preset_choice.add_item(name)
		if name == selected:
			_preset_choice.select(_preset_choice.item_count - 1)
	_name_edit.text = _session.record(draft_id).get("candidate_name", "")


func _on_preset_selected(index: int) -> void:
	_load_preset(_preset_choice.get_item_text(index))


func _load_preset(name: String) -> void:
	if not _commit_inputs():
		_refresh_presets(_session.record(draft_id).preset)
		return
	var next: String = _session.open_profile(enemy_id, name)
	if next.is_empty(): _message.text = _session.error; return
	draft_id = next
	_refresh_presets(name)
	_build_fields(_session.values(draft_id))
	_update_source()


func _build_fields(values: Dictionary) -> void:
	_loading = true
	_draft = values.duplicate(true)
	_fields.clear()
	_pending_text.clear()
	_grids.clear()
	_rows.clear()
	for child in _tabs.get_children():
		_tabs.remove_child(child)
		child.queue_free()
	for group: Dictionary in Layout.groups(enemy_id, Tuning.get_schema(enemy_id)):
		var scroll := ScrollContainer.new()
		scroll.name = String(group.title)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_tabs.add_child(scroll)
		var sections := VBoxContainer.new()
		sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(sections)
		var grid: GridContainer
		var section := ""
		if group.fields.is_empty(): sections.add_child(_label("此敌人不使用这类公共参数。", 12, UI.COLOR_DIM))
		for field: Dictionary in group.fields:
			if section != field.section:
				section = field.section
				sections.add_child(_label(section, 12, UI.COLOR_TITLE))
				grid = GridContainer.new()
				grid.columns = 2
				grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				grid.add_theme_constant_override("h_separation", 12)
				grid.add_theme_constant_override("v_separation", 3)
				sections.add_child(grid)
				_grids.append(grid)
			var key := String(field.key)
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.custom_minimum_size.y = 24
			row.tooltip_text = InputField.tooltip(enemy_id, field)
			row.set_meta("search", (String(group.title) + section + String(field.label) + String(field.key)).to_lower())
			row.set_meta("tab", Layout.TABS.find(String(group.title)))
			_rows.append(row)
			grid.add_child(row)
			var label := _label(String(field.label) + (" ↗" if String(field.scale_rule).begins_with("随体型") else ""), 12)
			label.custom_minimum_size.x = 150
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(label)
			if field.value is bool:
				var toggle := CheckBox.new()
				toggle.text = "开启"
				toggle.button_pressed = bool(values[key])
				toggle.toggled.connect(_changed.bind(key))
				row.add_child(toggle)
				_fields[key] = toggle
			else:
				var input := SpinBox.new()
				input.name = key
				input.min_value = float(field.min)
				input.max_value = float(field.max)
				InputField.configure_step(input, float(field.step))
				InputField.update_number(input, Layout.display_number(key, float(values[key])))
				input.custom_minimum_size.x = 94
				input.value_changed.connect(_changed.bind(key))
				input.get_line_edit().text_changed.connect(_mark_text_changed.bind(key))
				input.get_line_edit().text_submitted.connect(func(_text: String): _commit_inputs())
				input.get_line_edit().focus_exited.connect(func(): _commit_inputs())
				row.add_child(input)
				var unit := _label(InputField.unit(enemy_id, field), 11, UI.COLOR_DIM)
				unit.custom_minimum_size.x = 42
				row.add_child(unit)
				_fields[key] = input
	_loading = false
	_filter_fields(_search.text)
	_on_session_changed.call_deferred(draft_id)
	layout_panel()


func _changed(value: Variant, key: String) -> void:
	if _loading:
		return
	if _pending_text.has(key) and _fields[key] is SpinBox:
		value = InputField.exact_change(_fields[key], float(value), _pending_text[key])
	_pending_text.erase(key)
	if _fields[key] is SpinBox: value = Layout.stored_number(key, float(value))
	if not _session.set_value(draft_id, key, value): _message.text = _session.error
	_on_session_changed.call_deferred(draft_id)


func _mark_text_changed(text: String, key: String) -> void:
	if not _loading:
		_pending_text[key] = text
		_update_source()


func _commit_inputs() -> bool:
	# Enter 前仍停留在数值框里的文字也必须参与保存，不能只保存旧 SpinBox 值。
	# 仅提交用户实际键入的框：隐藏分页的 LineEdit 可能尚未同步绘制，不能覆盖草稿。
	for key: String in _pending_text.keys():
		var entered: String = _pending_text[key]
		var parsed := InputField.read_number(_fields[key], entered)
		if not parsed.ok:
			(_fields[key] as SpinBox).get_line_edit().text = entered
			_message.text = key + "：" + String(parsed.error)
			return false
		_pending_text.erase(key)
		if not _session.set_value(draft_id, key, Layout.stored_number(key, float(parsed.value))):
			_pending_text[key] = entered
			_message.text = _session.error
			return false
	return true


func save_current() -> void:
	if not _commit_inputs(): return
	var name := _name_edit.text.strip_edges()
	if not _session.save_as(draft_id, name):
		_message.text = _session.error
		return
	_refresh_presets(name)
	_message.text = "候选已保存：%s；当前默认与正式绑定未变。" % name
	saved.emit(enemy_id, name)


func _restore_defaults() -> void:
	_pending_text.clear()
	_session.restore(draft_id, true)
	_message.text = "基础值已载入本轮草稿；未保存、未改默认。"


func _button(parent: Node, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size.y = 26
	button.add_theme_font_size_override("font_size", 12)
	button.pressed.connect(callback)
	parent.add_child(button)


func _label(text: String, font_size: int, color: Color = UI.COLOR_BODY) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _update_source() -> void:
	if draft_id.is_empty(): return
	var d: Dictionary = _session.record(draft_id)
	var formal := Catalog.formal_preset(enemy_id)
	_source_info.text = "草稿：%s · %s | 默认：%s | 体型 ×%.3f" % [d.preset, "有输入待提交" if not _pending_text.is_empty() else "未保存" if _session.dirty(draft_id) else "已载入", Tuning.active_name(enemy_id), float(_session.values(draft_id).get("body_size", 1.0))]
	_source_info.tooltip_text = "修订 %d；正式 Boss 引用：%s。保存候选与设默认分开；战斗实例重新生成生效。↗ 表示随体型缩放，框内是体型1的基础值。实际体型还包含个体浮动。\n%s" % [d.revision, formal if not formal.is_empty() else "无独立指定", JSON.stringify(Catalog.identity(enemy_id))]


func _on_session_changed(key: String) -> void:
	if key != draft_id and not key.is_empty(): return
	if draft_id.is_empty(): return
	_draft = _session.values(draft_id)
	var name: String = _session.record(draft_id).preset
	if _preset_choice.item_count != Tuning.preset_names(enemy_id).size() or _preset_choice.get_item_text(_preset_choice.selected) != name:
		_refresh_presets(name)
	_loading = true
	for field: String in _fields:
		if _pending_text.has(field): continue
		if _fields[field] is SpinBox: InputField.update_number(_fields[field], Layout.display_number(field, float(_draft[field])))
		else: _fields[field].set_pressed_no_signal(bool(_draft[field]))
	_loading = false
	_update_source()
	_message.text = _session.validation(draft_id)


func _activate() -> void:
	if not _commit_inputs(): return
	if not _session.activate(draft_id): _message.text = _session.error; return
	_message.text = "已明确设为当前默认；正式 Boss 的独立指定名称不变。"
	default_changed.emit(enemy_id, _session.record(draft_id).preset)


func _request_overwrite() -> void:
	if not _commit_inputs(): return
	var name := _name_edit.text.strip_edges()
	var expected := Tuning.saved_fingerprint(enemy_id, name, true)
	if expected.is_empty() or name == Tuning.DEFAULT_PRESET:
		_message.text = "请选择可覆盖的命名方案；新名称使用“保存候选”。"
		return
	_overwrite_request = {"kind": "save", "draft": draft_id, "name": name, "fingerprint": expected}
	var refs := Catalog.references(enemy_id, name)
	_overwrite.dialog_text = "覆盖：%s\n引用范围：%s\n这些入口下次读取会采用覆盖后的内容。当前默认选择和当前战斗实例不变。" % [name, "、".join(refs) if not refs.is_empty() else "已登记关卡未直接引用；其他命名引用仍可能采用"]
	_overwrite.popup_centered(Vector2i(580, 180))


func _confirm_overwrite() -> void:
	if _overwrite_request.get("draft") != draft_id: return
	if _overwrite_request.get("kind") == "reload":
		_pending_text.clear()
		_message.text = "已重新读取磁盘方案" if _session.reload_from_disk(draft_id, true) else _session.error
		return
	if not _session.save_as(draft_id, _overwrite_request.name, true, _overwrite_request.fingerprint):
		_message.text = _session.error
		return
	_refresh_presets(_overwrite_request.name)
	_message.text = "同名方案已覆盖；已列出的引用将在下次读取时采用。"
	saved.emit(enemy_id, _overwrite_request.name)


func _request_reload() -> void:
	if _session.dirty(draft_id) or not _pending_text.is_empty():
		_overwrite_request = {"kind": "reload", "draft": draft_id}
		_overwrite.dialog_text = "丢弃当前未保存修改／输入并重新读取磁盘？\n其他对象和其他方案的草稿保留。"
		_overwrite.popup_centered(Vector2i(560, 150))
	else:
		_message.text = "已重新读取磁盘方案" if _session.reload_from_disk(draft_id) else _session.error


func _filter_fields(query: String) -> void:
	var text := query.strip_edges().to_lower()
	for row: Control in _rows: row.visible = text.is_empty() or String(row.get_meta("search")).contains(text)
	if not text.is_empty():
		for row: Control in _rows:
			if row.visible:
				_tabs.current_tab = int(row.get_meta("tab"))
				break
