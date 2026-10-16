extends PanelContainer
## Visual-only profiles use the same schemas and preset store as combat prototypes.
const Tuning = preload("res://scripts/prototypes/enemy_tuning.gd")
signal values_changed(values: Dictionary)
signal field_focused(key: String)
signal pose_selected(index: int)
signal replay_requested
signal seek_requested(fraction: float)
var profile := ""
var drafts: Dictionary = {}
var baselines: Dictionary = {}
var values: Dictionary = {}
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
	custom_minimum_size.x = 250
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 8)
	add_child(margin)
	var column := VBoxContainer.new()
	margin.add_child(column)
	var title := Label.new()
	title.text = "外形编辑 · 即时预览"
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
	preset_name.placeholder_text = "命名方案，例如：宽甲短角"
	column.add_child(preset_name)
	var save_row := HBoxContainer.new()
	column.add_child(save_row)
	button(save_row, "保存命名方案", _save)
	button(save_row, "所选设为默认", _activate)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status)

func button(parent: Node, title: String, action: Callable) -> void:
	var control := Button.new()
	control.text = title
	control.focus_mode = Control.FOCUS_NONE
	control.pressed.connect(action)
	parent.add_child(control)

func bind_profile(id: String) -> void:
	profile = id
	visible = not id.is_empty()
	if not visible:
		return
	if not drafts.has(id):
		drafts[id] = Tuning.get_values(id).duplicate(true)
		baselines[id] = drafts[id].duplicate(true)
	values = drafts[id]
	_build_fields()
	_refresh_presets()
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
	for child in fields.get_children():
		child.free()
	for group: Dictionary in Tuning.get_schema(profile).groups:
		var heading := Label.new()
		heading.text = String(group.title)
		fields.add_child(heading)
		for field: Dictionary in group.fields:
			var row := HBoxContainer.new()
			fields.add_child(row)
			var label := Label.new()
			label.text = String(field.label)
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
				continue
			var spin := SpinBox.new()
			spin.min_value = float(field.min)
			spin.max_value = float(field.max)
			spin.step = float(field.step)
			spin.value = float(values[field.key])
			spin.suffix = String(field.get("unit", ""))
			spin.custom_minimum_size.x = 96
			spin.tooltip_text = "%s – %s；%s" % [field.min, field.max, String(field.get("tip", "即时预览；保存后可复用"))]
			spin.value_changed.connect(_field_changed.bind(String(field.key)))
			# 悬停或改动都告诉观察台：这个参数动的是哪一块、作用在哪个阶段。
			spin.mouse_entered.connect(func() -> void: field_focused.emit(key))
			row.mouse_entered.connect(func() -> void: field_focused.emit(key))
			row.add_child(spin)

func _field_changed(value: Variant, key: String) -> void:
	values[key] = value
	values_changed.emit(values)
	_refresh_status()

func _refresh_presets(select_name := "") -> void:
	presets.clear()
	for title in Tuning.preset_names(profile):
		presets.add_item(title)
		if title == select_name or (select_name.is_empty() and title == Tuning.active_name(profile)):
			presets.select(presets.item_count - 1)

func _refresh_status() -> void:
	status.text = ("● 未保存修改" if values != baselines[profile] else "已载入 / 已保存") + "\n下次默认：" + Tuning.active_name(profile)

func _load_selected() -> void:
	var title := presets.get_item_text(presets.selected)
	values = Tuning.preset_values(profile, title)
	drafts[profile] = values
	baselines[profile] = values.duplicate(true)
	preset_name.text = "" if title == Tuning.DEFAULT_PRESET else title
	_build_fields()
	values_changed.emit(values)
	_refresh_status()

func _save() -> void:
	var title := preset_name.text.strip_edges()
	# Saving an active name would alter the next default implicitly: require a new name.
	if title == Tuning.active_name(profile):
		status.text = "请另存新名称，再显式设为默认。"
		return
	if not Tuning.save_preset(profile, title, values, false):
		status.text = Tuning.last_error
		return
	baselines[profile] = values.duplicate(true)
	_refresh_presets(title)
	_refresh_status()

func _activate() -> void:
	if Tuning.set_active_preset(profile, presets.get_item_text(presets.selected)):
		_refresh_status()
	else:
		status.text = Tuning.last_error
