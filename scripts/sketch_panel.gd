extends CanvasLayer
## F9运行调参：暂停战斗；草稿与显式保存项目默认 / 个人风格选择分开。
const Settings := preload("res://scripts/sketch_settings.gd")
const ThemeUtil := preload("res://scripts/ui_theme.gd")
const MODAL := &"sketch_tuning_modal"
var opened := false
var _effect: CanvasLayer
var _root: Control
var _status: Label
var _saved: Dictionary = {}
var _fields: Dictionary = {}
var _colors: Dictionary = {}
var _building := false
var _mouse := Input.MOUSE_MODE_VISIBLE
var _previous_style := 0
var _scene: Node
var _paused := false

func setup(effect: CanvasLayer) -> void:
	_effect = effect
	layer = 125
	process_mode = Node.PROCESS_MODE_ALWAYS

func _player() -> Node:
	return get_tree().get_first_node_in_group("player")

func _can_open() -> bool:
	if preload("res://scripts/testing/professional_navigation.gd").modal(get_tree()): return false
	var greybox := get_node_or_null("/root/GreyboxDirector")
	if greybox != null and greybox.is_active: return false
	var player := _player()
	if player == null or get_tree().paused: return true
	return is_instance_valid(player) and is_instance_valid(player._melee) and player._melee.can_control()

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F9:
		if opened:
			close()
		elif _can_open():
			open()
		get_viewport().set_input_as_handled()
	elif opened and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open() -> void:
	if opened or not _can_open():
		return
	_saved = Settings.load_values()
	_mouse = MouseControl.mode
	_paused = get_tree().paused
	_previous_style = _effect.style
	_scene = get_tree().current_scene
	if is_instance_valid(_scene):
		_scene.tree_exiting.connect(close, CONNECT_ONE_SHOT)
	get_node("/root/GameFlow").set_meta(MODAL, true)
	var player := _player()
	if is_instance_valid(player) and is_instance_valid(player.get("_melee")): player._melee.cancel()
	opened = true
	preload("res://scripts/testing/professional_navigation.gd").shared(get_tree()).enter_module(close, "当前工作区")
	get_tree().paused = true
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	_effect.set_style(5)
	_build()

func _build() -> void:
	_building = true
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var panel := PanelContainer.new()
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.035, 0.045, 0.06, 1.0)
	background.set_content_margin_all(8.0)
	panel.add_theme_stylebox_override("panel", background)
	_root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -500
	panel.offset_right = -8
	panel.offset_top = 8
	panel.offset_bottom = -8
	var box := VBoxContainer.new()
	box.theme = Theme.new()
	box.theme.default_font = ThemeUtil.get_font()
	box.theme.default_font_size = 12
	panel.add_child(box)
	var title := Label.new()
	title.text = "手绘画面 · F9 / Esc 返回 · 战斗已暂停"
	box.add_child(title)
	_status = Label.new()
	box.add_child(_status)
	var note := Label.new()
	note.text = "草稿立即预览；红色保色为启发式，不是精确技能遮罩"
	box.add_child(note)
	var modes := HBoxContainer.new()
	box.add_child(modes)
	for item in [["原画对照", "off"], ["轻量彩铅", "light"], ["旧版复线", "legacy"], ["黑白素描", "mono"]]:
		_button(modes, item[0], _recipe.bind(item[1]))
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
		var caption := Label.new()
		caption.text = "%s (%s)" % [spec[0], spec[1]]
		caption.custom_minimum_size.x = 300
		grid.add_child(caption)
		var spin := SpinBox.new()
		spin.min_value = spec[2]
		spin.max_value = spec[3]
		spin.step = 1.0 if key in Settings.BOOLS or key == "color_bands" else 0.001
		spin.custom_minimum_size.x = 155
		grid.add_child(spin)
		_fields[key] = spin
		spin.value_changed.connect(_changed.bind(key))
	for key in Settings.COLORS:
		var caption := Label.new()
		caption.text = Settings.COLORS[key]
		grid.add_child(caption)
		var picker := ColorPickerButton.new()
		picker.edit_alpha = false
		grid.add_child(picker)
		_colors[key] = picker
		picker.color_changed.connect(_color_changed.bind(key))
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	_button(buttons, "保存为项目默认", _save)
	_button(buttons, "重读默认", _reload)
	_button(buttons, "返回", close)
	var choice := HBoxContainer.new()
	box.add_child(choice)
	_button(choice, "本机启用手绘并返回", _use_style.bind(5))
	_button(choice, "本机关闭滤镜并返回", _use_style.bind(0))
	_building = false
	_sync()
	_refresh()

func _button(parent: Node, caption: String, action: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(action)
	parent.add_child(button)

func _sync() -> void:
	_building = true
	for key in _fields:
		_fields[key].value = _effect.parameters[key]
	for key in _colors:
		var value: Array = _effect.parameters[key]
		_colors[key].color = Color(value[0], value[1], value[2], value[3])
	_building = false

func _refresh() -> void:
	_status.text = "未保存草稿（本次运行生效）" if _effect.parameters != _saved else "与项目默认一致"
	if _effect.style != 5:
		_status.text += " · 正在看原画"

func _changed(value: float, key: String) -> void:
	if _building:
		return
	var draft: Dictionary = _effect.parameters.duplicate(true)
	draft[key] = value
	_effect.apply_sketch_parameters(draft)
	_effect.set_style(5)
	_sync()
	_refresh()

func _color_changed(value: Color, key: String) -> void:
	if _building:
		return
	var draft: Dictionary = _effect.parameters.duplicate(true)
	draft[key] = [value.r, value.g, value.b, value.a]
	_effect.apply_sketch_parameters(draft)
	_effect.set_style(5)
	_refresh()

func _recipe(name: String) -> void:
	if name == "off":
		_effect.set_style(0)
	else:
		_effect.apply_sketch_parameters(Settings.recipe(name))
		_effect.set_style(5)
	_sync()
	_refresh()

func _save() -> void:
	var error := Settings.save_values(_effect.parameters)
	if error != OK:
		_status.text = "保存失败：" + error_string(error)
		return
	_saved = Settings.load_values()
	_effect.apply_sketch_parameters(_saved)
	_sync()
	_refresh()

func _reload() -> void:
	_saved = Settings.load_values()
	_effect.apply_sketch_parameters(_saved)
	_sync()
	_refresh()

func _use_style(value: int) -> void:
	get_node("/root/DisplaySettings").select_post_process_style(value)
	_previous_style = value
	close()

func close() -> void:
	if not opened:
		return
	opened = false
	if is_instance_valid(_scene) and _scene.tree_exiting.is_connected(close):
		_scene.tree_exiting.disconnect(close)
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null:
		flow.remove_meta(MODAL)
	get_tree().paused = _paused
	MouseControl.mode = _mouse
	if is_instance_valid(_effect):
		_effect.set_style(_previous_style)
	if is_instance_valid(_root):
		_root.queue_free()
	_fields.clear()
	_colors.clear()
	preload("res://scripts/testing/professional_navigation.gd").shared(get_tree()).leave_module()

func _exit_tree() -> void:
	close()
