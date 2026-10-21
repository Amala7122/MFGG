extends PanelContainer
## 战斗原型页的紧凑视图，输入／草稿／校验仍交给原参数控制器，避免两份状态。
const InputField := preload("res://scripts/testing/parameter_input.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const TripleSlam := preload("res://scripts/prototypes/titan_triple_slam_definition.gd")
const PROFILE := "PrototypeSedimentTitan"
const KEYS := ["triple_slam_length","triple_slam_width","triple_slam_spread","triple_slam_windup","triple_slam_recovery","triple_slam_damage","triple_slam_cooldown"]
signal sample_changed
signal play_requested
signal fight_requested
var source: PanelContainer
var fields: Dictionary = {}
var time_input: SpinBox
var timeline: HSlider
var status: Label
var phase_label: Label
var enable_toggle: CheckBox
var _loading := false
var _last_valid: Dictionary = {}
var _pose := Transform3D.IDENTITY
var _size := 1.0
var _draft := ""
var _display_values: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = InputField.compact_theme(preload("res://scripts/ui_theme.gd").get_theme(),11)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(.035,.055,.045,.98)
	style.set_content_margin_all(6)
	add_theme_stylebox_override("panel",style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",3)
	add_child(column)
	var heading := HBoxContainer.new()
	column.add_child(heading)
	_label(heading,"三线重击 · 定格编辑")
	enable_toggle = CheckBox.new()
	enable_toggle.text = "启用"
	enable_toggle.tooltip_text = "启用狂暴编排：真实三线重击依赖此开关，也影响狂暴选招；只修改当前草稿，不改变正式默认。"
	heading.add_child(enable_toggle)
	enable_toggle.toggled.connect(func(value: bool):
		if not _loading and is_instance_valid(source): source._changed(value,"rage_director_enabled"); _refresh())
	var note := _label(column,"几何即时预览；运行样本需重播／试打。保存使用完整参数页。")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	for key: String in KEYS:
		var spec := Catalog.field(PROFILE,key)
		var row := HBoxContainer.new()
		rows.add_child(row)
		var label := _label(row,String(spec.label))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.tooltip_text = String(spec.label)+"（"+key+"）"
		var input := SpinBox.new()
		input.custom_minimum_size.x = 86
		input.min_value = float(spec.min)
		input.max_value = float(spec.max)
		InputField.configure_step(input,float(spec.step))
		input.tooltip_text = InputField.tooltip(PROFILE,spec)
		row.add_child(input)
		fields[key] = input
		input.get_line_edit().text_changed.connect(_text_changed.bind(key))
		input.get_line_edit().text_submitted.connect(func(_text: String): commit())
		input.get_line_edit().focus_exited.connect(commit)
		input.value_changed.connect(_value_changed.bind(key))
		input.get_line_edit().focus_entered.connect(func(): _refresh.call_deferred())
		var unit := _label(row,String(spec.unit))
		unit.custom_minimum_size.x = 25
	var clock := HBoxContainer.new()
	column.add_child(clock)
	_label(clock,"几何时间")
	time_input = SpinBox.new()
	time_input.min_value = 0
	time_input.max_value = 3600
	time_input.step = .01
	time_input.suffix = "秒"
	time_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_input.tooltip_text = "固定绝对时刻，只采样几何与时序，不倒放肢体或物理世界。修改前摇后时刻不变。"
	clock.add_child(time_input)
	time_input.value_changed.connect(func(value: float): timeline.set_value_no_signal(value); sample_changed.emit())
	timeline = HSlider.new()
	timeline.step = .01
	column.add_child(timeline)
	timeline.value_changed.connect(func(value: float): time_input.value = value)
	phase_label = _label(column,"")
	status = _label(column,"")
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.max_lines_visible = 4
	status.custom_minimum_size.y = 52
	var actions := HBoxContainer.new()
	column.add_child(actions)
	_button(actions,"播放单次",func(): if commit(): play_requested.emit())
	_button(actions,"真人试打",func(): if commit(): fight_requested.emit())
	_button(actions,"撤回输入",func(): source._discard_pending(); _refresh())
	visible = false

func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	return label

func _button(parent: Node, text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.tooltip_text = {"播放单次":"用整份已提交草稿重新生成并播放一次真实技能；不会保存或修改默认。","真人试打":"同一草稿重新生成，玩家接管并开启真实AI；便利条件沿用配置区。","撤回输入":"撤回本对象尚未提交的文字，保留已提交草稿。"}[text]
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	parent.add_child(button)

func bind(controller: PanelContainer, pose: Transform3D, body_size: float) -> void:
	source = controller
	_pose = pose
	_size = body_size
	if _draft != source.draft_id:
		_draft = source.draft_id
		_last_valid = source._session.preview_values(_draft)
		time_input.value = float(_last_valid.triple_slam_windup)*.5
	if not source._session.changed.is_connected(_session_changed): source._session.changed.connect(_session_changed)
	visible = true
	_refresh()

func _session_changed(key: String) -> void:
	if is_instance_valid(source) and key == source.draft_id: _refresh()

func _text_changed(text: String, key: String) -> void:
	if _loading or not is_instance_valid(source): return
	source._mark_text_changed(text,key)
	_refresh.call_deferred()

func _value_changed(value: float, key: String) -> void:
	if _loading or not is_instance_valid(source): return
	# 失焦后的原生格式化可能晚于commit发出旧值，不能作为一次用户修改回写草稿。
	if not fields[key].get_line_edit().has_focus():
		_refresh.call_deferred()
		return
	# 原生SpinBox格式化非法输入时保留原文，不能借value_changed静默限幅。
	if source._pending_text.has(key):
		var parsed := InputField.read_number(fields[key],source._pending_text[key])
		if not parsed.ok: _refresh.call_deferred(); return
	source._changed(value,key)
	_refresh()

func commit() -> bool:
	var ok: bool = source._commit_inputs("播放／试打")
	_refresh()
	if ok and not bool(source._session.values(_draft).rage_director_enabled):
		status.text = "当前未启用狂暴编排；请先勾选“启用”，再播放／试打。"
		status.tooltip_text = status.text
		return false
	return ok

func _refresh() -> void:
	if not is_instance_valid(source) or _draft.is_empty(): return
	_loading = true
	var values: Dictionary = source._session.values(_draft)
	_display_values = values.duplicate()
	enable_toggle.set_pressed_no_signal(bool(values.rage_director_enabled))
	for key: String in fields:
		var edit: LineEdit = fields[key].get_line_edit()
		var caret := edit.caret_column
		if source._pending_text.has(key):
			if edit.text != String(source._pending_text[key]):
				edit.text = String(source._pending_text[key])
				if edit.has_focus(): edit.caret_column = mini(caret,edit.text.length())
		elif not is_equal_approx(fields[key].value,float(values[key])) or edit.text != String.num(float(values[key]),12):
			InputField.update_number(fields[key],float(values[key]))
			if edit.has_focus(): edit.caret_column = mini(caret,edit.text.length())
	var inspection := InputField.inspect_pending(PROFILE,source._fields,source._pending_text,values)
	InputField.mark_issues(fields,inspection.issues)
	if inspection.issues.is_empty(): _last_valid = inspection.values.duplicate(true)
	else: _last_valid = source._session.preview_values(_draft)
	status.text = ("合法输入已预览；回车／离开输入框提交，未保存。" if not source._pending_text.is_empty() else "几何已预览；真实样本待重播，保存请进参数页。") if inspection.issues.is_empty() else InputField.describe(PROFILE,inspection.issues,"更新预览")
	if inspection.issues.is_empty() and not bool(values.rage_director_enabled): status.text = "未启用狂暴编排，仅预览几何；勾选“启用”后可播放／试打。"
	status.tooltip_text = status.text
	if not inspection.issues.is_empty():
		var issue: Dictionary = inspection.issues[0]
		var labels: Array[String] = []
		for key: String in issue.keys: labels.append(String(Catalog.field(PROFILE,key).label))
		status.text = "%s%s\n%s\n修正／撤回；返回保留，未应用。" % ["／".join(labels)," 输入“%s”" % issue.raw if issue.has("raw") else "",issue.message]
	status.add_theme_color_override("font_color",Color(.85,.86,.8) if inspection.issues.is_empty() else Color(1,.42,.32))
	timeline.max_value = maxf(float(_last_valid.triple_slam_windup)+float(_last_valid.triple_slam_recovery),time_input.value)
	_loading = false
	sample_changed.emit()

func _process(_delta: float) -> void:
	if not visible or _loading or not is_instance_valid(source): return
	# 原生SpinBox在显示／排版后仍可能用自己的小数位格式化文字；只修复非编辑框。
	# 不重新校验整份草稿，不改用户原文、数值、焦点或观察时间。
	_loading = true
	for key: String in fields:
		var edit: LineEdit = fields[key].get_line_edit()
		if edit.has_focus() or source._pending_text.has(key) or not _display_values.has(key): continue
		var value: float = _display_values[key]
		if not is_equal_approx(fields[key].value,value) or edit.text != String.num(value,12): InputField.update_number(fields[key],value)
	_loading = false

func sample() -> Dictionary:
	if _last_valid.is_empty(): return {}
	var data := TripleSlam.snapshot(_last_valid,_size)
	var timing := TripleSlam.timing(data,time_input.value)
	phase_label.text = "%s · %.2f秒／%.2f秒" % [timing.phase,time_input.value,float(data.windup)+float(data.recovery)]
	return {"snapshot":data,"shapes":TripleSlam.shapes(data,_pose),"timing":timing,"values":_last_valid.duplicate(true)}
