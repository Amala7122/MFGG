extends CanvasLayer
## 单进程专业工作区：只让当前场景留在树内；调用方实例原样保留，禁止双世界同时运行。
const InputField := preload("res://scripts/testing/parameter_input.gd")
var frames: Array[Dictionary] = []
var back_button: Button
var destination: Label
var local_back: Callable
var busy := false

static func shared(tree: SceneTree) -> CanvasLayer:
	var existing := tree.root.get_node_or_null("ProfessionalNavigation")
	if existing == null and tree.root.has_meta("professional_navigation_pending"):
		existing = tree.root.get_meta("professional_navigation_pending")
	if existing: return existing
	var service := load("res://scripts/testing/professional_navigation.gd").new() as CanvasLayer
	service.name = "ProfessionalNavigation"
	# 原生F6会在root仍传播ready时调用这里，此时不能同步添加root子节点。
	# 先登记唯一的待挂载实例；控件已在_init构建，调用方可以立即设置返回上下文。
	tree.root.set_meta("professional_navigation_pending", service)
	tree.root.add_child.call_deferred(service)
	return service

func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 120
	var plate := PanelContainer.new()
	plate.position = Vector2(8, 8)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.04,0.06,0.05,0.9)
	background.set_content_margin_all(0)
	plate.add_theme_stylebox_override("panel",background)
	add_child(plate)
	var row := HBoxContainer.new()
	row.theme = InputField.compact_theme(preload("res://scripts/ui_theme.gd").get_theme(), 11)
	plate.add_child(row)
	back_button = Button.new()
	back_button.text = "← 返回"
	back_button.custom_minimum_size = Vector2(68, 24)
	back_button.pressed.connect(back)
	row.add_child(back_button)
	destination = Label.new()
	row.add_child(destination)
	set_local()

func _ready() -> void:
	# 挂载不会重建控件或重置调用方在ready之前设置的上下文。
	get_tree().root.remove_meta("professional_navigation_pending")

func set_local(action := Callable(), title := "") -> void:
	local_back = action
	var label := title if action.is_valid() else String(frames.back().title) if not frames.is_empty() else "独立启动"
	destination.text = label
	back_button.disabled = busy or (not action.is_valid() and frames.is_empty())
	back_button.tooltip_text = "返回" + label + "；草稿与未提交输入保留，不保存、不还原" if not back_button.disabled else "独立启动，没有调用方；从其他测试台进入后可原路返回"

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.alt_pressed and event.keycode == KEY_LEFT:
		back()
		get_viewport().set_input_as_handled()

func back() -> void:
	if busy: return
	if local_back.is_valid():
		local_back.call()
	elif not frames.is_empty():
		_return.call_deferred()

func open(source: Node, scene_path: String, profile: String, form := "visual") -> void:
	if busy: return
	busy = true
	_swap.call_deferred(source, scene_path, profile, form)

func _swap(source: Node, scene_path: String, profile: String, form: String) -> void:
	var tree := get_tree()
	if not is_instance_valid(source) or not source.is_inside_tree(): busy = false; return
	var packed := load(scene_path) as PackedScene
	if packed == null: busy = false; set_local(); return
	var target := packed.instantiate()
	target.set_meta("workspace_profile", profile)
	target.set_meta("workspace_form", form)
	var title := "视觉测试台" if source.has_method("_show_subject") else String(source.get("_title").text)
	var frame := {"source": source, "title": title, "paused": tree.paused, "time_scale": Engine.time_scale, "camera": get_viewport().get_camera_3d(), "local_back": local_back, "local_title": destination.text}
	if source.has_method("workspace_suspending"): source.workspace_suspending()
	# 尺寸信号由视口持有；离树期间不得回调使用get_viewport的旧页面。
	if source.has_method("_layout_interface"):
		var callback := Callable(source, "_layout_interface")
		if get_viewport().size_changed.is_connected(callback): get_viewport().size_changed.disconnect(callback)
	frames.append(frame)
	tree.current_scene = null
	source.set_meta("workspace_suspended", true)
	source.get_parent().remove_child(source)
	tree.paused = false
	Engine.time_scale = 1.0
	tree.root.add_child(target)
	tree.current_scene = target
	busy = false
	set_local()

func _return() -> void:
	if frames.is_empty(): return
	busy = true
	var tree := get_tree()
	var outgoing := tree.current_scene
	if outgoing and outgoing.has_method("workspace_suspending"): outgoing.workspace_suspending()
	tree.current_scene = null
	if outgoing:
		outgoing.set_meta("workspace_suspended", true)
		tree.root.remove_child(outgoing)
		outgoing.queue_free()
	var frame: Dictionary = frames.pop_back()
	var source: Node = frame.source
	tree.root.add_child(source)
	source.remove_meta("workspace_suspended")
	tree.current_scene = source
	if source.has_method("_layout_interface"):
		var callback := Callable(source, "_layout_interface")
		if not get_viewport().size_changed.is_connected(callback): get_viewport().size_changed.connect(callback)
	# 返回保持暂停；视觉自己的冻结/播放状态单独保留。不会自动捕获鼠标。
	tree.paused = frame.paused
	Engine.time_scale = frame.time_scale
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(frame.camera): frame.camera.make_current()
	if source.has_method("workspace_resumed"): source.workspace_resumed()
	busy = false
	set_local(frame.local_back, frame.local_title)

func _exit_tree() -> void:
	for frame: Dictionary in frames:
		if is_instance_valid(frame.source): frame.source.free()
	frames.clear()

func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	visible = scene != null and scene.is_in_group("professional_workspaces")
