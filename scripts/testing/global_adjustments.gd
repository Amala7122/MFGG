extends CanvasLayer
## 公共目录及个人显示设置；复用既有渲染服务，不改变GameFlow流程状态。
const Nav := preload("res://scripts/testing/professional_navigation.gd")
const InputField := preload("res://scripts/testing/parameter_input.gd")
var opened := false
var panel: PanelContainer
var _paused := false
var _mouse := Input.MOUSE_MODE_VISIBLE

func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 124

func open() -> void:
	if opened or Nav.modal(get_tree()): return
	_paused = get_tree().paused
	_mouse = MouseControl.mode
	opened = true
	get_node("/root/GameFlow").set_meta("workspace_global_modal", true)
	get_tree().paused = true
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	Nav.shared(get_tree()).enter_module(close, "当前工作区")
	_build(false)

func _build(display: bool) -> void:
	if is_instance_valid(panel):
		remove_child(panel)
		panel.queue_free()
	panel = PanelContainer.new()
	panel.position = Vector2(8, 40)
	panel.custom_minimum_size.x = 340
	panel.theme = InputField.compact_theme(preload("res://scripts/ui_theme.gd").get_theme(), 12)
	add_child(panel)
	var rows := VBoxContainer.new()
	panel.add_child(rows)
	var title := Label.new()
	title.text = ("显示 · 个人设置（立即生效／本机保存）" if display else "全局调节 · 当前场景：" + get_tree().current_scene.name)
	rows.add_child(title)
	if display:
		var settings := get_node("/root/DisplaySettings")
		for item in [["显示模式", "mode_label", "cycle_display_mode"], ["窗口分辨率", "resolution_label", "cycle_resolution"], ["3D渲染比例", "render_scale_label", "cycle_render_scale"], ["界面缩放", "ui_scale_label", "cycle_ui_scale"], ["画面风格", "post_process_label", "cycle_post_process_style"]]:
			_button(rows, item[0]+"　"+String(settings.call(item[1])), func(): settings.call(item[2]); _build(true))
		_button(rows, "返回公共目录", _build.bind(false))
	else:
		_button(rows, "敌人起手队列 · 并发／间隔", _attack_queue)
		_button(rows, "显示设置", _build.bind(true))
		_button(rows, "画面风格 · F9", _module.bind("sketch"))
		_button(rows, "灰模 · F10", _module.bind("greybox"))
		var later := Label.new()
		later.text = "环境包 T08 · 天空／云／天气 T09 · 声音／诊断 T10"
		later.add_theme_font_size_override("font_size", 11)
		rows.add_child(later)
	_button(rows, "关闭 · 返回工作区", close)

func _button(rows: Node, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 24
	button.pressed.connect(action)
	rows.add_child(button)

func _module(kind: String) -> void:
	close()
	if kind == "sketch": get_node("/root/PostProcess")._sketch_panel.open()
	else: get_node("/root/GreyboxDirector")._panel.open()

func _attack_queue() -> void:
	close()
	load("res://scripts/testing/enemy_attack_queue_panel.gd").shared(get_tree()).open()

func close() -> void:
	if not opened: return
	opened = false
	get_node("/root/GameFlow").remove_meta("workspace_global_modal")
	get_tree().paused = _paused
	MouseControl.mode = _mouse
	if is_instance_valid(panel): panel.queue_free()
	Nav.shared(get_tree()).leave_module()

func _input(event: InputEvent) -> void:
	if opened and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
