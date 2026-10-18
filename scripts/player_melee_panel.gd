extends CanvasLayer
## 编辑器运行 F7：暂停战斗调参。草稿即时应用，只有显式保存才写项目默认。
const Settings := preload("res://scripts/player_melee_settings.gd")
const Flow := preload("res://scripts/game_flow.gd")
const ThemeUtil := preload("res://scripts/ui_theme.gd")
const MODAL := &"player_melee_tuning_modal"
var _melee: Node
var _host: Node
var _root: Control
var _status: Label
var _fields: Dictionary = {}
var _saved: Dictionary = {}
var _mouse := Input.MOUSE_MODE_CAPTURED
var _previous_meta: Variant = null
var _building := false
var opened := false

func setup(melee: Node, host: Node) -> void:
	_melee = melee
	_host = host
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F7:
		if opened:
			close()
		elif _melee.can_control():
			open()
		get_viewport().set_input_as_handled()
	elif opened and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open() -> void:
	if opened or not _melee.can_control():
		return
	_melee.cancel()
	_saved = Settings.load_values()
	_mouse = Input.mouse_mode
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null:
		_previous_meta = flow.get_meta(MODAL) if flow.has_meta(MODAL) else null
		flow.set_meta(MODAL, true)
	opened = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build()

func _build() -> void:
	_building = true
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.025, 0.035, 0.88)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(480, 0)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.add_theme_font_override("font", ThemeUtil.get_font())
	box.add_theme_font_size_override("font_size", 12)
	panel.add_child(box)
	var title := Label.new()
	title.text = "玩家近战 · 战斗已暂停 · F7 / Esc 关闭"
	box.add_child(title)
	_status = Label.new()
	box.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(480, minf(420.0, get_viewport().get_visible_rect().size.y - 140.0))
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	_fields.clear()
	for key in Settings.FIELDS:
		var spec: Array = Settings.FIELDS[key]
		var label := Label.new()
		label.text = "%s (%s)" % [spec[0], spec[1]]
		label.custom_minimum_size.x = 280
		grid.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = float(spec[2])
		spin.max_value = float(spec[3])
		spin.step = float(spec[4])
		if key.ends_with("_windup") or key.ends_with("_active") or key.ends_with("_total") or key.ends_with("_cancel") or key.ends_with("_lunge"):
			spin.step = minf(spin.step, 0.001)
		spin.custom_minimum_size.x = 150
		spin.value = float(_melee.parameters[key])
		grid.add_child(spin)
		_fields[key] = spin
		spin.value_changed.connect(_changed.bind(key))
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	for item in [["保存为项目默认", _save], ["重读已保存值", _reload], ["返回战斗", close]]:
		var button := Button.new()
		button.text = item[0]
		button.pressed.connect(item[1])
		buttons.add_child(button)
	_building = false
	_refresh()

func _changed(value: float, key: String) -> void:
	if _building:
		return
	# 只改用户实际编辑的字段，不把其他 SpinBox 的显示取整悄悄写回。
	var draft: Dictionary = _melee.parameters.duplicate()
	draft[key] = value
	_melee.configure(draft)
	_sync_fields()
	_refresh()

func _sync_fields() -> void:
	_building = true
	for key in _fields:
		_fields[key].value = _melee.parameters[key]
	_building = false

func _refresh() -> void:
	_status.text = "未保存草稿：仅本次运行生效" if _melee.parameters != _saved else "与项目默认一致 · 时长单位为秒"

func _save() -> void:
	var result := Settings.save_values(_melee.parameters)
	if result == OK:
		_saved = Settings.load_values()
		_melee.configure(_saved) # 使用实际落盘精度，状态不因序列化尾差误报未保存。
		_sync_fields()
		_refresh()
	else:
		_status.text = "保存失败：" + error_string(result)

func _reload() -> void:
	_saved = Settings.load_values()
	_melee.configure(_saved)
	_sync_fields()
	_refresh()

func close() -> void:
	if not opened:
		return
	opened = false
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null:
		if _previous_meta == null:
			flow.remove_meta(MODAL)
		else:
			flow.set_meta(MODAL, _previous_meta)
	get_tree().paused = false
	Input.mouse_mode = _mouse
	if is_instance_valid(_root):
		_root.queue_free()

func _exit_tree() -> void:
	close()
