extends PanelContainer
## 面板根据参数配置生成控件；不维护另一份数值默认值。

signal saved(id: String, name: String)
signal closed

const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const UI := preload("res://scripts/ui_theme.gd")
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
	theme = UI.get_theme()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.065, 0.105, 0.09, 0.98)
	style.border_color = UI.COLOR_TITLE
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(18)
	add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	add_child(column)
	column.add_child(_label("敌人调参", 24, UI.COLOR_TITLE))
	var note := _label("保存后用于下一轮；当前轮次和自动补兵保留开场参数。\n时间单位为秒，比例 0.5 表示 50%。Esc 返回并保持鼠标释放。", 13, UI.COLOR_DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	var choices := HBoxContainer.new()
	column.add_child(choices)
	choices.add_child(_label("敌人", 14))
	_enemy_choice = OptionButton.new()
	_enemy_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for id: String in Tuning.PROFILE_PATHS:
		_enemy_choice.add_item(String(Tuning.get_schema(id).get("title", id)))
		_enemy_choice.set_item_metadata(_enemy_choice.item_count - 1, id)
	_enemy_choice.item_selected.connect(_on_enemy_selected)
	choices.add_child(_enemy_choice)
	choices.add_child(_label("方案", 14))
	_preset_choice = OptionButton.new()
	_preset_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_choice.item_selected.connect(_on_preset_selected)
	choices.add_child(_preset_choice)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_font_size_override("font_size", 14)
	column.add_child(_tabs)
	var name_row := HBoxContainer.new()
	column.add_child(name_row)
	name_row.add_child(_label("保存方案名称", 14))
	_name_edit = LineEdit.new()
	_name_edit.name = "PresetName"
	_name_edit.max_length = 64
	_name_edit.placeholder_text = "例如：高血量练习 / 快速前摇"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_edit)
	_message = _label("", 13, UI.COLOR_DIM)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_message)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	_button(actions, "保存并选用", save_current)
	_button(actions, "恢复项目默认", _restore_defaults)
	_button(actions, "返回敌人配置", func(): closed.emit())
	visible = false


func open_enemy(id: String) -> void:
	if not Tuning.PROFILE_PATHS.has(id):
		return
	enemy_id = id
	for index in range(_enemy_choice.item_count):
		if _enemy_choice.get_item_metadata(index) == id:
			_enemy_choice.select(index)
	_refresh_presets(Tuning.active_name(id))
	_build_fields(Tuning.get_values(id))
	_message.text = "已载入：" + Tuning.active_name(id)
	_message.modulate = UI.COLOR_BODY
	visible = true
	layout_panel()


func layout_panel() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var width := minf(860.0, viewport_size.x - 48.0)
	position = Vector2((viewport_size.x - width) * 0.5, 88)
	size = Vector2(width, maxf(viewport_size.y - 112.0, 380.0))
	for grid in _grids:
		grid.columns = 2 if width >= 760.0 else 1


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
	_name_edit.text = "我的方案" if selected == Tuning.DEFAULT_PRESET else selected


func _on_preset_selected(index: int) -> void:
	var name := _preset_choice.get_item_text(index)
	_name_edit.text = "我的方案" if name == Tuning.DEFAULT_PRESET else name
	_build_fields(Tuning.preset_values(enemy_id, name))
	_message.text = "已载入：%s；点击保存并选用后用于下一轮。" % name
	_message.modulate = UI.COLOR_BODY


func _build_fields(values: Dictionary) -> void:
	_loading = true
	_draft = values.duplicate(true)
	_fields.clear()
	_pending_text.clear()
	_grids.clear()
	for child in _tabs.get_children():
		_tabs.remove_child(child)
		child.queue_free()
	for group: Dictionary in Tuning.get_schema(enemy_id).get("groups", []):
		var scroll := ScrollContainer.new()
		scroll.name = String(group.title)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_tabs.add_child(scroll)
		var grid := GridContainer.new()
		grid.columns = 2
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", 18)
		grid.add_theme_constant_override("v_separation", 10)
		scroll.add_child(grid)
		_grids.append(grid)
		for field: Dictionary in group.fields:
			var key := String(field.key)
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.custom_minimum_size.y = 34
			row.tooltip_text = String(field.get("tip", ""))
			grid.add_child(row)
			var label := _label(String(field.label), 14)
			label.custom_minimum_size.x = 164
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
				input.step = float(field.step)
				input.value = float(values[key])
				input.custom_minimum_size.x = 94
				input.value_changed.connect(_changed.bind(key))
				input.get_line_edit().text_changed.connect(_mark_text_changed.bind(key))
				row.add_child(input)
				var unit := _label(String(field.get("unit", "")), 12, UI.COLOR_DIM)
				unit.custom_minimum_size.x = 56
				row.add_child(unit)
				_fields[key] = input
	_loading = false
	layout_panel()


func _changed(value: Variant, key: String) -> void:
	if _loading:
		return
	_draft[key] = value
	_pending_text.erase(key)
	_message.text = "参数已修改，尚未保存。"
	_message.modulate = UI.COLOR_TITLE


func _mark_text_changed(_text: String, key: String) -> void:
	if not _loading:
		_pending_text[key] = true


func _commit_inputs() -> void:
	# Enter 前仍停留在数值框里的文字也必须参与保存，不能只保存旧 SpinBox 值。
	# 仅提交用户实际键入的框：隐藏分页的 LineEdit 可能尚未同步绘制，不能覆盖草稿。
	for key: String in _pending_text.keys():
		(_fields[key] as SpinBox).apply()


func save_current() -> void:
	_commit_inputs()
	var name := _name_edit.text.strip_edges()
	if not Tuning.save_preset(enemy_id, name, _draft):
		_message.text = Tuning.last_error
		_message.modulate = UI.COLOR_DANGER
		return
	_refresh_presets(name)
	_message.text = "已保存并选用：%s。重新生成敌人后生效。" % name
	_message.modulate = UI.COLOR_BODY
	saved.emit(enemy_id, name)


func _restore_defaults() -> void:
	_build_fields(Tuning.defaults(enemy_id))
	_message.text = "已恢复项目默认，点击保存并选用后生效。"
	_message.modulate = UI.COLOR_TITLE


func _button(parent: Node, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size.y = 40
	button.add_theme_font_size_override("font_size", 14)
	button.pressed.connect(callback)
	parent.add_child(button)


func _label(text: String, font_size: int, color: Color = UI.COLOR_BODY) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label
