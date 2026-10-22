extends CanvasLayer
## 战斗编排的统一入口；草稿／本次应用／项目默认分开，返回保留非法原文。
const Policy := preload("res://scripts/enemy_attack_queue_policy.gd")
const InputField := preload("res://scripts/testing/parameter_input.gd")
const Nav := preload("res://scripts/testing/professional_navigation.gd")
var opened := false
var draft: Dictionary = {}
var raw: Dictionary = {}
var controls: Dictionary = {}
var panel: PanelContainer
var status: Label
var live: Label
var profiles: OptionButton
var _profile := "PrototypeFastBeast"
var _paused := false
var _mouse := Input.MOUSE_MODE_VISIBLE
var _root: Control
var _enabled: CheckButton
var _nav_visible := false

static func shared(tree: SceneTree) -> CanvasLayer:
	var node := tree.root.get_node_or_null("EnemyAttackQueuePanel")
	if node == null:
		node = load("res://scripts/testing/enemy_attack_queue_panel.gd").new()
		node.name = "EnemyAttackQueuePanel"
		tree.root.add_child(node)
	return node

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 125

func open() -> void:
	if opened or Nav.modal(get_tree()): return
	if draft.is_empty(): draft = Policy.current().duplicate(true)
	_paused = get_tree().paused
	_mouse = MouseControl.mode
	get_tree().paused = true
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	get_node("/root/GameFlow").set_meta(&"attack_queue_modal", true)
	var existing := get_tree().root.get_node_or_null("ProfessionalNavigation")
	if existing == null and get_tree().root.has_meta("professional_navigation_pending"):
		existing = get_tree().root.get_meta("professional_navigation_pending")
	_nav_visible = existing != null and existing.visible
	var navigation := Nav.shared(get_tree())
	navigation.show()
	navigation.enter_module(close, "原工作区")
	opened = true
	_build()

func _build() -> void:
	if is_instance_valid(_root):
		remove_child(_root)
		_root.queue_free()
	controls.clear()
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.015, 0.02, 0.025, 1.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 16
	panel.offset_top = 44
	panel.offset_right = -16
	panel.offset_bottom = -16
	panel.theme = InputField.compact_theme(preload("res://scripts/ui_theme.gd").get_theme(), 12)
	_root.add_child(panel)
	var scroll := ScrollContainer.new()
	panel.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 5)
	scroll.add_child(rows)
	_label(rows, "敌人起手队列 · 战斗编排")
	_label(rows, "排队默认守势，可调等待绕行速度；获准才完整起手。已经公布的攻击、弹体和毒池保留。")
	_label(rows, "总／地面上限按整个战场；兵种／技能上限和起手间隔按受攻击玩家。地面按技能组计，泰坦三线是一组完整招式。")
	_enabled = CheckButton.new()
	_enabled.text = "启用起手错峰和并发限制（关闭用于对照；仍记录在场危险）"
	_enabled.button_pressed = bool(draft.enabled)
	_enabled.toggled.connect(func(value: bool): draft.enabled = value; _dirty())
	rows.add_child(_enabled)
	for key: String in Policy.GLOBAL_FIELDS:
		var spec: Array = Policy.GLOBAL_FIELDS[key]
		_number(rows, "global/" + key, String(spec[0]), String(spec[1]), float(draft.global[key]), float(spec[2]), float(spec[3]))
	profiles = OptionButton.new()
	var keys := Policy.REGISTRY.keys()
	for profile: String in keys:
		var schema: Dictionary = preload("res://scripts/prototypes/enemy_tuning.gd").get_schema(profile)
		profiles.add_item(String(schema.get("title", profile)).split(" · ")[0])
	profiles.select(keys.find(_profile))
	profiles.item_selected.connect(func(index: int): _profile = keys[index]; _build())
	rows.add_child(profiles)
	var entry: Dictionary = draft.profiles[_profile]
	_number(rows, "profiles/" + _profile + "/max_active", "此兵种危险技能组上限", "组/玩家", float(entry.max_active), 0, 64)
	for skill: String in Policy.REGISTRY[_profile]:
		var title := Policy.skill_name(_profile, skill)
		if skill == "poison": title += "（含在途投囊的落地预留）"
		_number(rows, "profiles/" + _profile + "/skills/" + skill, title + "并发上限", "组/玩家", float(entry.skills[skill]), 0, 64)
	_label(rows, "兵种／技能填0：暂停该类新起手；已在场动作仍结束。地面上限含飞行落点与持续毒池；毒池消失前占位。")
	_label(rows, "运行应用在下一次起手生效；排队不消耗技能冷却。低于当前在场数时等待自然回收，不取消已公布的招式。")
	live = _label(rows, "")
	status = _label(rows, "")
	var buttons := HBoxContainer.new()
	rows.add_child(buttons)
	_button(buttons, "应用本次运行", _apply)
	_button(buttons, "保存为默认并应用", _save)
	_button(buttons, "恢复已保存值", _restore)
	_button(buttons, "关闭／返回（保留草稿）", close)
	_dirty()

func _number(rows: Node, path: String, title: String, unit: String, value: float, minimum: float, maximum: float) -> void:
	var row := HBoxContainer.new()
	rows.add_child(row)
	var label := _label(row, title)
	label.custom_minimum_size.x = 300
	var edit := LineEdit.new()
	edit.custom_minimum_size.x = 100
	edit.text = String(raw.get(path, String.num(value, 8)))
	edit.tooltip_text = "%s；单位%s；范围%s–%s。数值无效时保留原文，不会静默限幅。" % [title, unit, minimum, maximum]
	controls[path] = edit
	row.add_child(edit)
	_label(row, "%s　%s–%s" % [unit, minimum, maximum])
	edit.text_changed.connect(func(text: String): raw[path] = text; _dirty())

func _document() -> Dictionary:
	var result := draft.duplicate(true)
	var errors: Array[String] = []
	for path: String in raw:
		var text: String = String(raw[path]).strip_edges()
		if not text.is_valid_float() or not is_finite(text.to_float()):
			errors.append(path + "：输入“" + String(raw[path]) + "”无效，请修正或恢复已保存值")
			continue
		var keys := path.split("/")
		var cursor: Dictionary = result
		for index in range(keys.size() - 1): cursor = cursor[keys[index]]
		cursor[keys[-1]] = text.to_float()
	if errors.is_empty(): errors = Policy.validate(result)
	return {"values": result, "errors": errors}

func _dirty() -> void:
	if not is_instance_valid(status): return
	var parsed := _document()
	if not parsed.errors.is_empty():
		status.text = "尚未应用／保存：" + "；".join(parsed.errors) + "。返回会保留输入。"
	else:
		status.text = ("本次运行已应用" if parsed.values == Policy.current() else "有尚未应用的草稿") \
			+ ("；默认值已保存" if parsed.values == Policy.saved() else "；尚未保存为默认")

func _apply() -> void:
	var parsed := _document()
	if not parsed.errors.is_empty(): _dirty(); return
	if Policy.apply(parsed.values): draft = parsed.values; raw.clear(); _dirty()
	else: status.text = Policy.last_error

func _save() -> void:
	var parsed := _document()
	if not parsed.errors.is_empty(): _dirty(); return
	if Policy.save(parsed.values):
		draft = parsed.values
		raw.clear()
		_dirty()
		status.text += "；" + Policy.storage_path()
	else: status.text = Policy.last_error

func _restore() -> void:
	draft = Policy.saved()
	raw.clear()
	_build()

func _process(_delta: float) -> void:
	if not opened or not is_instance_valid(live): return
	var scene := get_tree().current_scene
	var queue := scene.get_node_or_null("EnemyAttackQueue") if scene != null else null
	if queue == null: live.text = "当前现场尚无队列；从主场景继续游戏后自动建立。"; return
	var state: Dictionary = queue.snapshot()
	live.text = "现场：危险组%d／地面组%d／待起手%d；累计许可%d；等待p95 %.2f秒" % [state.total, state.ground, state.pending, state.grants, state.wait_p95]

func close() -> void:
	if not opened: return
	opened = false
	get_node("/root/GameFlow").remove_meta(&"attack_queue_modal")
	var navigation := Nav.shared(get_tree())
	navigation.leave_module()
	navigation.visible = _nav_visible
	get_tree().paused = _paused
	MouseControl.mode = _mouse
	if is_instance_valid(_root): _root.hide()

func _input(event: InputEvent) -> void:
	if not opened: return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()

func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	return label

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 26
	button.pressed.connect(action)
	parent.add_child(button)
	return button
