extends CanvasLayer
## 单进程专业工作区：只让当前场景留在树内；调用方实例原样保留，禁止双世界同时运行。
const InputField := preload("res://scripts/testing/parameter_input.gd")
var frames: Array[Dictionary] = []
var back_button: Button
var destination: Label
var local_back: Callable
var busy := false
var global_button: Button
var module_close: Callable
var module_return: Dictionary = {}
var _globals: CanvasLayer
var _service_tree: SceneTree

static func suspended(node: Node) -> bool:
	while node != null:
		if node.get_meta("workspace_suspended", false): return true
		node = node.get_parent()
	return false

static func modal(tree: SceneTree) -> bool:
	var queue_flow := tree.root.get_node_or_null("GameFlow")
	if queue_flow != null and bool(queue_flow.get_meta(&"attack_queue_modal", false)): return true
	var flow := tree.root.get_node_or_null("GameFlow")
	if flow == null: return false
	for key in [&"player_melee_tuning_modal", &"player_visual_tuning_modal", &"sketch_tuning_modal", &"greybox_tuning_modal", &"workspace_global_modal"]:
		if flow.get_meta(key, false): return true
	return false

func enter_module(close: Callable, title: String) -> void:
	module_return = {"action": local_back, "title": destination.text}
	module_return.huds = {}
	# F9／F10也可能在导航延迟挂载前调用；与T02的提前set_local合同一致。
	var tree := get_tree() if is_inside_tree() else _service_tree
	var scene := tree.current_scene if tree != null else null
	if scene:
		for hud: CanvasLayer in scene.find_children("WeatherDebugHUD", "CanvasLayer", true, false):
			module_return.huds[hud] = hud.visible
			hud.hide()
	module_close = close
	set_local(close, title)
	global_button.disabled = true

func leave_module() -> void:
	module_close = Callable()
	for hud in module_return.get("huds", {}):
		if is_instance_valid(hud): hud.visible = module_return.huds[hud]
	set_local(module_return.get("action", Callable()), module_return.get("title", ""))
	module_return.clear()
	global_button.disabled = false

func _toggle_global() -> void:
	if modal(get_tree()): return
	if not is_instance_valid(_globals):
		_globals = load("res://scripts/testing/global_adjustments.gd").new()
		get_tree().root.add_child(_globals)
	_globals.open()

static func shared(tree: SceneTree) -> CanvasLayer:
	var existing := tree.root.get_node_or_null("ProfessionalNavigation")
	if existing == null and tree.root.has_meta("professional_navigation_pending"):
		existing = tree.root.get_meta("professional_navigation_pending")
	if existing: return existing
	var service := load("res://scripts/testing/professional_navigation.gd").new() as CanvasLayer
	service._service_tree = tree
	service.name = "ProfessionalNavigation"
	# 原生F6会在root仍传播ready时调用这里，此时不能同步添加root子节点。
	# 先登记唯一的待挂载实例；控件已在_init构建，调用方可以立即设置返回上下文。
	tree.root.set_meta("professional_navigation_pending", service)
	tree.root.add_child.call_deferred(service)
	return service

func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 公共模块的全屏输入根位于120–122；共享返回必须保持可点击。
	layer = 140
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
	global_button = Button.new()
	global_button.text = "全局调节"
	global_button.custom_minimum_size = Vector2(76, 24)
	global_button.pressed.connect(_toggle_global)
	row.add_child(global_button)
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
		busy = true
		_return.call_deferred()

func open(source: Node, scene_path: String, profile: String, form := "visual") -> void:
	if busy or modal(get_tree()): return
	busy = true
	_swap.call_deferred(source, scene_path, profile, form)

func _swap(source: Node, scene_path: String, profile: String, form: String) -> void:
	var tree := get_tree()
	if not is_instance_valid(source) or not source.is_inside_tree(): busy = false; return
	if not ResourceLoader.exists(scene_path):
		busy = false
		back_button.tooltip_text = "目标资源不存在；原现场与草稿保留：" + scene_path
		return
	var packed := load(scene_path) as PackedScene
	if packed == null: busy = false; set_local(); return
	var target := packed.instantiate()
	target.set_meta("workspace_profile", profile)
	target.set_meta("workspace_form", form)
	if source.get_meta("workspace_profile", "") == profile:
		target.set_meta("workspace_target_id", source.get_meta("workspace_target_id", ""))
	var title := "圣所实战"
	if source.has_method("_show_subject"): title = "视觉测试台"
	elif source.get("_title") is Label: title = source.get("_title").text
	elif not source.scene_file_path.is_empty(): title = source.scene_file_path.get_file().get_basename()
	if source.scene_file_path == "res://scenes/sanctum_main.tscn": title = "圣所实战"
	var frame := {"source": source, "title": title, "paused": tree.paused, "time_scale": Engine.time_scale, "camera": get_viewport().get_camera_3d(), "local_back": local_back, "local_title": destination.text}
	var flow := tree.root.get_node_or_null("GameFlow")
	if flow:
		frame.flow = {"state": flow.state, "mode": flow.process_mode, "visible": flow.visible}
	frame.connections = _suspend_connections(source)
	# 并发技能占位属于原现场；预览使用独立占位表，不能把离树对象清掉。
	frame.limiter = preload("res://scripts/skill_limiter.gd")._active.duplicate(true)
	preload("res://scripts/skill_limiter.gd")._active = {}
	# 空间规划是静态分帧队列；仅让当前工作区推进，保留来源尚未完成的同一任务对象。
	frame.spatial_jobs = preload("res://scripts/combat_spatial_controller.gd")._jobs.duplicate()
	frame.spatial_rings = preload("res://scripts/combat_spatial_controller.gd")._rings.duplicate()
	preload("res://scripts/combat_spatial_controller.gd")._jobs = []
	preload("res://scripts/combat_spatial_controller.gd")._rings = {}
	if source.has_method("workspace_suspending"): source.workspace_suspending()
	# 尺寸信号由视口持有；离树期间不得回调使用get_viewport的旧页面。
	if source.has_method("_layout_interface"):
		var callback := Callable(source, "_layout_interface")
		if get_viewport().size_changed.is_connected(callback): get_viewport().size_changed.disconnect(callback)
	frames.append(frame)
	tree.current_scene = null
	source.set_meta("workspace_suspended", true)
	source.get_parent().remove_child(source)
	if flow:
		flow.process_mode = Node.PROCESS_MODE_DISABLED
		flow.visible = false
	tree.paused = false
	Engine.time_scale = 1.0
	tree.root.add_child(target)
	tree.current_scene = target
	busy = false
	set_local()

func _return() -> void:
	if frames.is_empty(): busy = false; return
	if not is_instance_valid(frames.back().source):
		frames.pop_back()
		busy = false
		set_local()
		back_button.tooltip_text = "来源场景已失效；当前专业台及草稿保留，可另存或继续返回可用调用方"
		return
	busy = true
	var tree := get_tree()
	var outgoing := tree.current_scene
	if outgoing and outgoing.has_method("workspace_suspending"): outgoing.workspace_suspending()
	if outgoing: _suspend_connections(outgoing, false)
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
	preload("res://scripts/skill_limiter.gd")._active = frame.limiter
	preload("res://scripts/combat_spatial_controller.gd")._jobs.assign(frame.spatial_jobs)
	preload("res://scripts/combat_spatial_controller.gd")._rings = frame.spatial_rings
	_restore_connections(frame.connections)
	var flow := tree.root.get_node_or_null("GameFlow")
	if flow and frame.has("flow"):
		flow.state = frame.flow.state
		flow.process_mode = frame.flow.mode
		flow.visible = frame.flow.visible
	var director := source.get_node_or_null("Enemies/WaveDirector")
	if director: director.instance = director
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
	if source.has_meta("sanctum_workspace"):
		source.get_meta("sanctum_workspace").returned()

func _suspend_connections(source: Node, preserving := true) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# 暂停不会阻止信号；冻结现场及GameFlow的总线订阅必须显式隔离。
	var bus := get_node_or_null("/root/EventBus")
	var flow := get_node_or_null("/root/GameFlow")
	# SceneTree本身也持有HUD等订阅；离树不是释放，必须显式隔离。
	for signal_name in ["node_added", "node_removed"]:
		for item: Dictionary in get_tree().get_signal_connection_list(signal_name):
			var receiver: Object = item.callable.get_object()
			if receiver is Node and (receiver == source or source.is_ancestor_of(receiver)):
				result.append({"bus": get_tree(), "signal": signal_name, "callable": item.callable, "flags": item.flags})
				get_tree().disconnect(signal_name, item.callable)
	if preserving:
		var nodes: Array[Node] = [source]
		nodes.append_array(source.find_children("*", "", true, false))
		for emitter: Node in nodes:
			for signal_name in ["tree_exiting", "tree_exited"]:
				for item: Dictionary in emitter.get_signal_connection_list(signal_name):
					var receiver: Object = item.callable.get_object()
					# 原生GUI自己管理ScrollBar等退出连接，不能截断引擎内部生命周期。
					if receiver is Node and receiver.get_script() == null: continue
					# 灰模渲染覆盖必须先释放，随后由其现有场景适配器重新附着。
					if item.callable.get_object() == get_node_or_null("/root/GreyboxDirector"): continue
					result.append({"bus": emitter, "signal": signal_name, "callable": item.callable, "flags": item.flags})
					emitter.disconnect(signal_name, item.callable)
	if bus == null: return result
	for spec: Dictionary in bus.get_signal_list():
		for item: Dictionary in bus.get_signal_connection_list(spec.name):
			var receiver: Object = item.callable.get_object()
			if receiver == flow or (receiver is Node and (receiver == source or source.is_ancestor_of(receiver))):
				result.append({"bus": bus, "signal": spec.name, "callable": item.callable, "flags": item.flags})
				bus.disconnect(spec.name, item.callable)
	return result

func _restore_connections(connections: Array) -> void:
	for item: Dictionary in connections:
		if is_instance_valid(item.bus) and item.callable.is_valid() and not item.bus.is_connected(item.signal, item.callable):
			item.bus.connect(item.signal, item.callable, item.flags)

func _exit_tree() -> void:
	for frame: Dictionary in frames:
		if is_instance_valid(frame.source): frame.source.free()
	frames.clear()

func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	visible = module_close.is_valid() or (scene != null and scene.is_in_group("professional_workspaces"))
