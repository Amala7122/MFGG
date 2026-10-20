extends CanvasLayer
## F10只调整灰模显示；不提供任何战斗或物理调参。
const Settings := preload("res://scripts/greybox_settings.gd")
const ThemeUtil := preload("res://scripts/ui_theme.gd")
const MODAL := &"greybox_tuning_modal"
var opened := false
var _director: Node
var _root: Control
var _status: Label
var _saved: Dictionary = {}
var _fields: Dictionary = {}
var _colors: Dictionary = {}
var _building := false
var _mouse := Input.MOUSE_MODE_VISIBLE
var _was_active := false

func setup(director: Node) -> void:
	_director = director
	layer = 121
	process_mode = Node.PROCESS_MODE_ALWAYS

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.physical_keycode == KEY_F10:
		if opened: close()
		else: open()
		get_viewport().set_input_as_handled()
	elif opened and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open() -> void:
	if opened or get_tree().paused or _director._other_modal(): return
	_saved = Settings.load_values()
	_mouse = MouseControl.mode
	_was_active = _director.is_active
	if not _was_active: _director.activate()
	get_node("/root/GameFlow").set_meta(MODAL,true)
	opened = true
	get_tree().paused = true
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	_build()

func _build() -> void:
	_building = true
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var panel := PanelContainer.new()
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.035,0.045,0.06,1.0)
	background.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel",background)
	_root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -440
	panel.offset_right = -8
	panel.offset_top = 8
	panel.offset_bottom = -8
	var box := VBoxContainer.new()
	box.theme = Theme.new()
	box.theme.default_font = ThemeUtil.get_font()
	box.theme.default_font_size = 12
	panel.add_child(box)
	var title := Label.new()
	title.text = "灰模显示 · F10 / Esc返回 · F4切换"
	box.add_child(title)
	_status = Label.new()
	box.add_child(_status)
	var note := Label.new()
	note.text = "预警 / 护盾保留；彩光收敛；扬尘默认关；已暂停"
	box.add_child(note)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	_fields.clear()
	_colors.clear()
	for key in Settings.FIELDS:
		var spec: Array = Settings.FIELDS[key]
		var label := Label.new()
		label.text = "%s (%s)" % [spec[0],spec[1]]
		label.custom_minimum_size.x = 260
		grid.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = spec[2]
		spin.max_value = spec[3]
		spin.step = 1.0 if key in ["ssao_enabled","major_grid_step","show_dust"] else 0.001
		spin.custom_minimum_size.x = 140
		grid.add_child(spin)
		_fields[key] = spin
		spin.value_changed.connect(_changed.bind(key))
	for key in Settings.COLORS:
		var label := Label.new()
		label.text = Settings.COLORS[key]+"颜色"
		grid.add_child(label)
		var picker := ColorPickerButton.new()
		picker.edit_alpha = false
		grid.add_child(picker)
		_colors[key] = picker
		picker.color_changed.connect(_color_changed.bind(key))
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	for item in [["保存为项目默认",_save],["重读默认",_reload],["返回",close]]:
		var button := Button.new()
		button.text = item[0]
		button.pressed.connect(item[1])
		buttons.add_child(button)
	_building = false
	_sync()
	_refresh()

func _sync() -> void:
	_building = true
	for key in _fields: _fields[key].value = _director.parameters[key]
	for key in _colors:
		var c: Array = _director.parameters[key]
		_colors[key].color = Color(c[0],c[1],c[2],1.0)
	_building = false

func _refresh() -> void:
	_status.text = "未保存草稿（本次运行生效）" if _director.parameters != _saved else "与项目默认一致"

func _changed(value: float, key: String) -> void:
	if _building: return
	var draft: Dictionary = _director.parameters.duplicate(true)
	draft[key] = value
	_director.apply_parameters(draft)
	_sync()
	_refresh()

func _color_changed(value: Color, key: String) -> void:
	if _building: return
	var draft: Dictionary = _director.parameters.duplicate(true)
	draft[key] = [value.r,value.g,value.b,1.0]
	_director.apply_parameters(draft)
	_refresh()

func _save() -> void:
	var error := Settings.save_values(_director.parameters)
	if error != OK:
		_status.text = "保存失败："+error_string(error)
		return
	_reload()

func _reload() -> void:
	_saved = Settings.load_values()
	_director.apply_parameters(_saved)
	_sync()
	_refresh()

func close() -> void:
	if not opened: return
	opened = false
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null: flow.remove_meta(MODAL)
	get_tree().paused = false
	MouseControl.mode = _mouse
	if is_instance_valid(_root): _root.queue_free()
	if not _was_active and _director.is_active: _director.deactivate()
	_fields.clear()
	_colors.clear()

func _exit_tree() -> void:
	close()
