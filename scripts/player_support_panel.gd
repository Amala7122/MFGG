extends CanvasLayer
## F8：正式表现的草稿调参 / 定向护盾重播；暂停战斗，不假造伤害或赐福。
const Settings := preload("res://scripts/player_support_settings.gd")
const ThemeUtil := preload("res://scripts/ui_theme.gd")
const MODAL := &"player_visual_tuning_modal"
var parameters: Dictionary = {}
var opened := false
var _host: CharacterBody3D
var _root: Control
var _fields: Dictionary = {}
var _status: Label
var _saved: Dictionary = {}
var _building := false
var _mouse := Input.MOUSE_MODE_CAPTURED
var _previous_meta: Variant = null
var _preview_running := false
var _preview_elapsed := 0.0
var _preview_direction := Vector3.FORWARD
var _damage: SpinBox
var _scrub: HSlider
var _loop: CheckBox
var _overclock_preview: CheckBox

func setup(host: CharacterBody3D) -> void:
	_host = host
	layer = 110
	process_mode = Node.PROCESS_MODE_ALWAYS
	parameters = Settings.load_values()

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F8:
		if opened:
			close()
		elif _host._melee.can_control():
			open()
		get_viewport().set_input_as_handled()
	elif opened and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func open() -> void:
	if opened or not _host._melee.can_control():
		return
	_host._melee.cancel()
	_saved = Settings.load_values()
	_mouse = MouseControl.mode
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null:
		_previous_meta = flow.get_meta(MODAL) if flow.has_meta(MODAL) else null
		flow.set_meta(MODAL, true)
	opened = true
	get_tree().paused = true
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	_build()

func apply_parameters(values: Dictionary) -> void:
	var valid := Settings.validate(values)
	if valid.is_empty():
		return
	parameters = valid
	_host._wisp.configure_visuals(parameters)
	_host._shield_fx.configure(parameters)

func _build() -> void:
	_building = true
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	# 靠右放置，保留中央角色与左肩卫士供观察。
	var panel := PanelContainer.new()
	panel.name = "SupportParameters"
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.035, 0.045, 0.06, 1.0)
	background.set_content_margin_all(8.0)
	panel.add_theme_stylebox_override("panel", background)
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
	title.text = "卫士 / 能量护盾 · F8 / Esc 返回战斗"
	box.add_child(title)
	_status = Label.new()
	box.add_child(_status)
	var note := Label.new()
	note.text = "战斗已暂停；护盾预览不扣血、不改变防御数值"
	box.add_child(note)
	var preview := HBoxContainer.new()
	box.add_child(preview)
	for direction in ["正面", "左侧", "右侧", "背后", "上方"]:
		var button := Button.new()
		button.text = direction
		button.pressed.connect(_direction_preview.bind(direction))
		preview.add_child(button)
	var controls := HBoxContainer.new()
	box.add_child(controls)
	var label := Label.new()
	label.text = "预览吸收量"
	controls.add_child(label)
	_damage = SpinBox.new()
	_damage.min_value = 1
	_damage.max_value = 100
	_damage.value = 25
	controls.add_child(_damage)
	_loop = CheckBox.new()
	_loop.text = "循环"
	controls.add_child(_loop)
	_overclock_preview = CheckBox.new()
	_overclock_preview.text = "预览超频外观（不授予赐福）"
	_overclock_preview.button_pressed = _host._wisp._overclock_mult > 1.0
	_overclock_preview.toggled.connect(_preview_wisp)
	box.add_child(_overclock_preview)
	_preview_wisp(_overclock_preview.button_pressed)
	var timeline := Label.new()
	timeline.text = "护盾时间线（0–100%）· 拖动定位"
	box.add_child(timeline)
	_scrub = HSlider.new()
	_scrub.min_value = 0.0
	_scrub.max_value = 1.0
	_scrub.step = 0.01
	_scrub.value_changed.connect(_seek)
	box.add_child(_scrub)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	_fields.clear()
	for key in Settings.FIELDS:
		var spec: Array = Settings.FIELDS[key]
		var caption := Label.new()
		caption.text = "%s (%s)" % [spec[0], spec[1]]
		caption.custom_minimum_size.x = 260
		grid.add_child(caption)
		var spin := SpinBox.new()
		spin.min_value = spec[2]
		spin.max_value = spec[3]
		spin.step = minf(float(spec[4]), 0.001) if key != "shield_enabled" else 1.0
		spin.value = parameters[key]
		spin.custom_minimum_size.x = 140
		grid.add_child(spin)
		_fields[key] = spin
		spin.value_changed.connect(_changed.bind(key))
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	for item in [["保存为项目默认", _save], ["重读已保存值", _reload], ["返回", close]]:
		var button := Button.new()
		button.text = item[0]
		button.pressed.connect(item[1])
		buttons.add_child(button)
	_building = false
	_refresh()

func _changed(value: float, key: String) -> void:
	if _building:
		return
	var draft := parameters.duplicate()
	draft[key] = value
	apply_parameters(draft)
	_sync_fields()
	_refresh()

func _sync_fields() -> void:
	_building = true
	for key in _fields:
		_fields[key].value = parameters[key]
	_building = false

func _refresh() -> void:
	_status.text = "未保存草稿（本次运行生效）" if parameters != _saved else "与项目默认一致"

func _save() -> void:
	var error := Settings.save_values(parameters)
	if error != OK:
		_status.text = "保存失败：" + error_string(error)
		return
	_saved = Settings.load_values()
	apply_parameters(_saved)
	_sync_fields()
	_refresh()

func _reload() -> void:
	_saved = Settings.load_values()
	apply_parameters(_saved)
	_sync_fields()
	_refresh()

func _direction_preview(direction: String) -> void:
	var forward: Vector3 = -_host.camera_pivot.global_basis.z
	forward.y = 0.0
	forward = forward.normalized() if not forward.is_zero_approx() else Vector3.FORWARD
	var right := forward.cross(Vector3.UP).normalized()
	match direction:
		"左侧": _preview_direction = -right
		"右侧": _preview_direction = right
		"背后": _preview_direction = -forward
		"上方": _preview_direction = Vector3.UP
		_: _preview_direction = forward
	_replay()

func _preview_wisp(overclocked: bool) -> void:
	_host._wisp.set_visual_preview(1 if overclocked else 0)

func _replay() -> void:
	_host._shield_fx.trigger(_preview_direction, _damage.value)
	_preview_elapsed = 0.0
	_preview_running = true
	_scrub.set_value_no_signal(0.0)

func _seek(value: float) -> void:
	if _building:
		return
	_preview_running = false
	_host._shield_fx.trigger(_preview_direction, _damage.value)
	_preview_elapsed = value * float(parameters.shield_duration)
	_host._shield_fx.sample(_preview_elapsed)

func _process(delta: float) -> void:
	if not opened or not _preview_running:
		return
	_preview_elapsed += delta
	if _preview_elapsed >= float(parameters.shield_duration):
		if _loop.button_pressed:
			_replay()
		else:
			_preview_running = false
	_host._shield_fx.sample(_preview_elapsed)
	_scrub.set_value_no_signal(clampf(_preview_elapsed / float(parameters.shield_duration), 0.0, 1.0))

func close() -> void:
	if not opened:
		return
	opened = false
	_preview_running = false
	if is_instance_valid(_host) and is_instance_valid(_host._shield_fx):
		_host._shield_fx.cancel()
	if is_instance_valid(_host) and is_instance_valid(_host._wisp):
		_host._wisp.set_visual_preview(-1)
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null:
		if _previous_meta == null:
			flow.remove_meta(MODAL)
		else:
			flow.set_meta(MODAL, _previous_meta)
	get_tree().paused = false
	MouseControl.mode = _mouse
	if is_instance_valid(_root):
		_root.queue_free()

func _exit_tree() -> void:
	close()
