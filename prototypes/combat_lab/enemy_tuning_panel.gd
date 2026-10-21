extends PanelContainer
## 面板根据参数配置生成控件；不维护另一份数值默认值。

signal visual_requested(profile: String)
signal saved(id: String, name: String)
signal default_changed(id: String, name: String)
signal closed
signal observe_requested(profile: String, values: Dictionary)

const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const UI := preload("res://scripts/ui_theme.gd")
const Session := preload("res://scripts/testing/tuning_session.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const InputField := preload("res://scripts/testing/parameter_input.gd")
const Ownership := preload("res://scripts/testing/enemy_parameter_ownership.gd")
const DOMAIN := "combat_prototype"
var _readonly: Dictionary = {}
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
var _pending_cache: Dictionary = {}
var _notice := ""
var _notice_error := false
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
	_button(actions, "撤销", func(): _history(false))
	_button(actions, "重做", func(): _history(true))
	var reset := HBoxContainer.new()
	column.add_child(reset)
	_button(reset, "还原战斗", func(): _pending_text.clear(); _session.restore_domain(draft_id, DOMAIN); _on_session_changed(draft_id))
	_button(reset, "载入基础值", _restore_defaults)
	_button(reset, "重读磁盘…", _request_reload)
	_button(reset, "观察本草稿", _request_observe)
	_button(reset, "撤回输入", _discard_pending)
	_button(reset, "外形 ↗", _request_visual)
	_overwrite = ConfirmationDialog.new()
	_overwrite.title = "覆盖已有方案"
	_overwrite.confirmed.connect(_confirm_overwrite)
	add_child(_overwrite)
	visible = false


func open_enemy(id: String) -> void:
	if not Tuning.PROFILE_PATHS.has(id):
		return
	if visible and not draft_id.is_empty() and not _commit_inputs():
		_select_enemy(enemy_id)
		return
	if not draft_id.is_empty(): _pending_cache[draft_id] = _pending_text.duplicate()
	_session.store_view(draft_id, DOMAIN, {"pending": _pending_text.duplicate()})
	enemy_id = id
	draft_id = _session.open_profile(id)
	_select_enemy(id)
	_refresh_presets(_session.record(draft_id).preset)
	_build_fields(_session.values(draft_id))
	_formal.visible = not Catalog.formal_preset(id).is_empty()
	_set_notice("本轮草稿已载入；未写入项目。")
	_update_source()
	visible = true
	layout_panel()


func _select_enemy(id: String) -> void:
	for index in range(_enemy_choice.item_count):
		if _enemy_choice.get_item_metadata(index) == id:
			_enemy_choice.select(index)


func layout_panel() -> void:
	if not is_inside_tree(): return
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
	if next.is_empty(): _show_failure("提交／保存草稿", _session.error); return
	draft_id = next
	_refresh_presets(name)
	_build_fields(_session.values(draft_id))
	_update_source()


func _build_fields(values: Dictionary) -> void:
	var retained: Dictionary = _session.view_data(draft_id, DOMAIN).get("pending", _pending_cache.get(draft_id, {})).duplicate()
	_loading = true
	_draft = values.duplicate(true)
	_fields.clear()
	_readonly.clear()
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
			if not Ownership.editable(enemy_id, key, DOMAIN):
				var reference := _label((String.num(Layout.display_number(key, float(values[key])), 12) if values[key] is float or values[key] is int else str(values[key])) + " · 视觉 ↗", 11, UI.COLOR_DIM)
				reference.tooltip_text = Ownership.title(enemy_id, key) + "：只读引用；通过“外形 ↗”进入。" + Ownership.dependency(enemy_id, key)
				row.add_child(reference)
				_readonly[key] = reference
				continue
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
				input.get_line_edit().focus_entered.connect(func(): _restore_pending_text.call_deferred())
				row.add_child(input)
				var unit := _label(InputField.unit(enemy_id, field), 11, UI.COLOR_DIM)
				unit.custom_minimum_size.x = 42
				row.add_child(unit)
				_fields[key] = input
	_pending_text = retained
	_restore_pending_text()
	_loading = false
	_filter_fields(_search.text)
	_on_session_changed.call_deferred(draft_id)
	layout_panel()


func _changed(value: Variant, key: String) -> void:
	if _loading or not _fields.has(key): return
	if _pending_text.has(key) and _fields[key] is SpinBox:
		var parsed := InputField.read_number(_fields[key], _pending_text[key])
		if not parsed.ok or not Tuning.field_issue(Catalog.field(enemy_id, key), Layout.stored_number(key, float(parsed.get("value", 0.0)))).is_empty():
			_restore_pending_text.call_deferred()
			_refresh_feedback()
			return
		value = InputField.exact_change(_fields[key], float(value), _pending_text[key])
	if _fields[key] is SpinBox: value = Layout.stored_number(key, float(value))
	if not Tuning.field_issue(Catalog.field(enemy_id, key), value).is_empty():
		if not _pending_text.has(key): _pending_text[key] = String.num(Layout.display_number(key, float(value)), 12)
		_restore_pending_text.call_deferred()
		_refresh_feedback()
		return
	_pending_text.erase(key)
	_notice = ""
	_notice_error = false
	if not _session.set_domain_value(draft_id, DOMAIN, key, value): _show_failure("修改参数", _session.error)
	_on_session_changed.call_deferred(draft_id)


func _mark_text_changed(text: String, key: String) -> void:
	if _loading: return
	_pending_text[key] = text
	_notice = ""
	_notice_error = false
	_update_source()
	_refresh_feedback()
	_restore_pending_text.call_deferred()


func _restore_pending_text() -> void:
	for key: String in _pending_text:
		if _fields.has(key) and _fields[key] is SpinBox:
			var edit: LineEdit = _fields[key].get_line_edit()
			if edit.text != String(_pending_text[key]): edit.text = String(_pending_text[key])


func _refresh_feedback(action := "", locate := false) -> void:
	if draft_id.is_empty(): return
	_pending_cache[draft_id] = _pending_text.duplicate()
	_session.store_view(draft_id, DOMAIN, {"pending": _pending_text.duplicate()})
	var inspection := InputField.inspect_pending(enemy_id, _fields, _pending_text, _session.values(draft_id))
	InputField.mark_issues(_fields, inspection.issues)
	_message.text = InputField.describe(enemy_id, inspection.issues, action) if not inspection.issues.is_empty() else _notice
	_message.tooltip_text = _message.text
	_message.add_theme_color_override("font_color", UI.COLOR_DANGER if not inspection.issues.is_empty() or _notice_error else UI.COLOR_DIM)
	if locate and not inspection.issues.is_empty() and not inspection.issues[0].keys.is_empty():
		_locate_issue.call_deferred(String(inspection.issues[0].keys[0]))


func _locate_issue(key: String) -> void:
	if not visible or not _fields.has(key): return
	_search.text = ""
	_filter_fields("")
	var row: Control = _fields[key].get_parent()
	_tabs.current_tab = int(row.get_meta("tab"))
	(_tabs.get_child(_tabs.current_tab) as ScrollContainer).ensure_control_visible(row)
	if _fields[key] is SpinBox:
		_fields[key].get_line_edit().grab_focus()
		_restore_pending_text()
		_fields[key].get_line_edit().select_all()


func _set_notice(text: String, failed := false) -> void:
	_notice = text
	_notice_error = failed
	_refresh_feedback()


func _show_failure(action: String, reason: String) -> void:
	_set_notice("无法%s：%s；草稿已保留。" % [action, reason], true)


func _commit_inputs(action := "提交", locate := false) -> bool:
	if _loading or draft_id.is_empty(): return true
	var inspection := InputField.inspect_pending(enemy_id, _fields, _pending_text, _session.values(draft_id))
	if not inspection.issues.is_empty():
		_restore_pending_text()
		_restore_pending_text.call_deferred()
		_refresh_feedback(action, locate)
		return false
	var keys := _pending_text.keys()
	_pending_text.clear()
	for key: String in keys:
		if not _session.set_domain_value(draft_id, DOMAIN, key, inspection.values[key]):
			_show_failure("提交／保存草稿", _session.error)
			return false
	_refresh_feedback()
	return true


func _request_observe() -> void:
	if _commit_inputs("观察本草稿", true): observe_requested.emit(enemy_id, _session.values(draft_id))


func _request_return() -> void:
	_commit_inputs("提交")
	_pending_cache[draft_id] = _pending_text.duplicate()
	_session.store_view(draft_id, DOMAIN, {"pending": _pending_text.duplicate()})
	closed.emit()


func _discard_pending() -> void:
	_pending_text.clear()
	_pending_cache.erase(draft_id)
	_notice = "未提交文字已撤回，保留已提交草稿；未写磁盘。"
	_notice_error = false
	_on_session_changed(draft_id)


func save_current() -> void:
	if not _commit_inputs("保存候选", true): return
	var name := _name_edit.text.strip_edges()
	if not _session.save_as(draft_id, name):
		_show_failure("保存候选", _session.error)
		return
	_refresh_presets(name)
	_set_notice("候选已保存：%s；当前默认与正式绑定未变。" % name)
	saved.emit(enemy_id, name)


func _restore_defaults() -> void:
	_pending_text.clear()
	_session.restore_domain(draft_id, DOMAIN, true)
	_on_session_changed(draft_id)
	_set_notice("本模块基础值已载入草稿；外形修改保留；未保存、未改默认。")


func _button(parent: Node, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size.y = 24
	button.tooltip_text = {"保存候选": "保存同对象外形与战斗的整份已提交草稿；不改变默认。其他模块有未提交输入时会提示先处理。", "还原战斗": "仅恢复战斗模块最近载入／保存值，保留外形修改。", "载入基础值": "仅载入战斗模块基础值，保留外形草稿。", "外形 ↗": "带同一草稿进入视觉测试台；返回保留当前分页、搜索和未提交输入。", "重读磁盘…": "重新读取整份方案；有未保存内容时先明确确认。", "撤销": "只撤销历史中最近的本模块操作；最近操作属于其他模块时提示所属入口。", "重做": "只重做最近的本模块操作，不跳过其他模块历史。"}.get(text, text)
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
	if draft_id.is_empty() or not is_inside_tree(): return
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
	for field: String in _readonly:
		_readonly[field].text = String.num(Layout.display_number(field, float(_draft[field])), 12) if _draft[field] is float or _draft[field] is int else str(_draft[field])
		_readonly[field].text += " · 视觉 ↗"
	_update_source()
	_refresh_feedback()


func _activate() -> void:
	if not _commit_inputs(): return
	if not _session.activate(draft_id): _show_failure("设为当前默认", _session.error); return
	_set_notice("已明确设为当前默认；正式 Boss 的独立指定名称不变。")
	default_changed.emit(enemy_id, _session.record(draft_id).preset)


func _request_overwrite() -> void:
	if not _commit_inputs(): return
	var name := _name_edit.text.strip_edges()
	var expected := Tuning.saved_fingerprint(enemy_id, name, true)
	if expected.is_empty() or name == Tuning.DEFAULT_PRESET:
		_set_notice("请选择可覆盖的命名方案；新名称使用“保存候选”。")
		return
	_overwrite_request = {"kind": "save", "draft": draft_id, "name": name, "fingerprint": expected}
	var refs := Catalog.references(enemy_id, name)
	_overwrite.dialog_text = "覆盖整份方案（包含外形与战斗已提交草稿）：%s\n引用范围：%s\n这些入口下次读取会采用覆盖后的内容。当前默认选择和当前战斗实例不变。" % [name, "、".join(refs) if not refs.is_empty() else "已登记关卡未直接引用；其他命名引用仍可能采用"]
	_overwrite.popup_centered(Vector2i(580, 180))


func _confirm_overwrite() -> void:
	if _overwrite_request.get("draft") != draft_id: return
	if _overwrite_request.get("kind") == "reload":
		_pending_text.clear()
		_set_notice("已重新读取磁盘方案" if _session.reload_from_disk(draft_id, true) else _session.error)
		return
	if not _session.save_as(draft_id, _overwrite_request.name, true, _overwrite_request.fingerprint):
		_show_failure("提交／保存草稿", _session.error)
		return
	_refresh_presets(_overwrite_request.name)
	_set_notice("同名方案已覆盖；已列出的引用将在下次读取时采用。")
	saved.emit(enemy_id, _overwrite_request.name)


func _request_reload() -> void:
	if _session.dirty(draft_id) or not _pending_text.is_empty():
		_overwrite_request = {"kind": "reload", "draft": draft_id}
		_overwrite.dialog_text = "重读整份方案：丢弃本对象各模块已提交草稿及本页未提交输入？\n其他对象和其他方案的草稿保留。"
		_overwrite.popup_centered(Vector2i(560, 150))
	else:
		_set_notice("已重新读取磁盘方案" if _session.reload_from_disk(draft_id) else _session.error)


func _filter_fields(query: String) -> void:
	var text := query.strip_edges().to_lower()
	for row: Control in _rows: row.visible = text.is_empty() or String(row.get_meta("search")).contains(text)
	if not text.is_empty():
		for row: Control in _rows:
			if row.visible:
				_tabs.current_tab = int(row.get_meta("tab"))
				break

func _history(forward: bool) -> void:
	if not _session.domain_history(draft_id, DOMAIN, forward):
		_set_notice(_session.error, true)
		return
	_pending_text.clear()
	_on_session_changed(draft_id)

func _request_visual() -> void:
	_commit_inputs()
	_pending_cache[draft_id] = _pending_text.duplicate()
	_session.store_view(draft_id, DOMAIN, {"pending": _pending_text.duplicate()})
	visual_requested.emit(enemy_id)

func remember_view() -> void:
	_session.store_view(draft_id, DOMAIN, {"pending": _pending_text.duplicate()})

func resume_view() -> void:
	_pending_text = _session.view_data(draft_id, DOMAIN).get("pending", _pending_text).duplicate()
	_on_session_changed(draft_id)
