extends SceneTree
## 共用手势、真实草稿入口、GUI隔离与固定机位／跟随回归；不操作系统鼠标。
const CameraControl := preload("res://scripts/testing/observation_camera.gd")
const Combat := preload("res://prototypes/combat_lab/combat_lab.tscn")
const Visual := preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
const Navigation := preload("res://scripts/prototypes/navigation_lab.gd")
const Chase := preload("res://scripts/prototypes/ring_chase_lab.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); push_error(label)
func frames(count: int) -> void:
	for i in count: await process_frame
func button(key: MouseButton, down := true, position := Vector2(900,500)) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = key
	event.pressed = down
	event.position = position
	event.global_position = position
	event.factor = 1.0
	if key in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT,MOUSE_BUTTON_MIDDLE] and down: event.button_mask = 1 << (int(key)-1)
	return event
func motion(relative: Vector2, position := Vector2(900,500)) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.relative = relative
	event.position = position
	event.global_position = position
	return event
func drag(control: Node, key: MouseButton, relative: Vector2) -> void:
	control.handle_event(button(key))
	control.handle_event(motion(relative))
	control.handle_event(button(key,false))
func routed(event: InputEvent) -> void:
	root.push_input(event,true)
	await frames(2)

func gestures(control: Node, label: String) -> void:
	var view: Camera3D = control.camera
	var before := view.global_transform
	var focus: Vector3 = control.focus
	var distance: float = control.distance()
	drag(control,MOUSE_BUTTON_RIGHT,Vector2(45,20))
	check(not view.global_transform.is_equal_approx(before),label+" 右键旋转")
	check(control.focus.is_equal_approx(focus) and is_equal_approx(control.distance(),distance),label+" 旋转围绕观察中心并保持距离")
	var amount: float = view.size if view.projection == Camera3D.PROJECTION_ORTHOGONAL else control.distance()
	control.handle_event(button(MOUSE_BUTTON_WHEEL_UP))
	var nearer: float = view.size if view.projection == Camera3D.PROJECTION_ORTHOGONAL else control.distance()
	check(nearer < amount,label+" 滚轮向上拉近")
	control.handle_event(button(MOUSE_BUTTON_WHEEL_DOWN))
	var restored: float = view.size if view.projection == Camera3D.PROJECTION_ORTHOGONAL else control.distance()
	check(is_equal_approx(amount,restored),label+" 正反滚轮可复现")
	focus = control.focus
	var screen := view.unproject_position(focus)
	var position := view.global_position
	var basis := view.global_basis
	var relative := Vector2(35,-18)
	drag(control,MOUSE_BUTTON_MIDDLE,relative)
	check(not control.focus.is_equal_approx(focus),label+" 中键平移观察中心")
	check((view.global_position-position).is_equal_approx(control.focus-focus) and view.global_basis.is_equal_approx(basis),label+" 平移保留朝向及相机与中心关系")
	check((view.unproject_position(focus)-screen).distance_to(relative)<0.5,label+" 画面随拖动按像素移动")
	before = view.global_transform
	control.handle_event(motion(Vector2(90,40)))
	check(view.global_transform.is_equal_approx(before),label+" 松键后停止拖动")
	control.handle_event(button(MOUSE_BUTTON_RIGHT))
	control.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	control.handle_event(motion(Vector2(90,40)))
	check(view.global_transform.is_equal_approx(before),label+" 失焦清拖动状态")

func _run() -> void:
	await frames(8)
	root.get_node("GameFlow").process_mode = Node.PROCESS_MODE_DISABLED
	root.get_node("GameFlow").visible = false
	paused = false
	var stage := Node3D.new()
	root.add_child(stage)
	current_scene = stage
	var view := Camera3D.new()
	stage.add_child(view)
	view.current = true
	var control := CameraControl.new()
	stage.add_child(control)
	control.bind(view,Vector3.ZERO)
	for projection: int in [Camera3D.PROJECTION_PERSPECTIVE,Camera3D.PROJECTION_ORTHOGONAL]:
		view.projection = projection
		view.size = 20
		control.set_view(Vector3(3,12,20),Vector3(0,2,0))
		gestures(control,"透视" if projection == 0 else "正交")
	control.set_view(Vector3(0,30,0),Vector3.ZERO,Vector3.FORWARD)
	drag(control,MOUSE_BUTTON_RIGHT,Vector2(12,-8))
	check(is_finite(view.global_position.y) and absf(view.global_basis.determinant()-1)<0.0001,"正俯视可旋转且姿态非奇异")
	paused = true
	gestures(control,"暂停世界")
	paused = false
	var chase := Chase.new()
	chase.camera = view
	chase.camera_control.free()
	chase.camera_control = control
	chase.reset_camera()
	gestures(control,"追击观察台")
	var pose := view.global_transform
	var focus: Vector3 = control.focus
	chase._follow_camera(Vector3(8,2,-5))
	check(view.global_basis.is_equal_approx(pose.basis) and view.global_position.is_equal_approx(pose.origin+Vector3(8,0,-5)),"跟随目标保留手动视角与平移偏置")
	check(control.focus.is_equal_approx(focus+Vector3(8,0,-5)),"跟随同步观察中心")
	chase.free()
	var navigation := Navigation.new()
	navigation.camera = view
	navigation.camera_control.free()
	navigation.camera_control = control
	navigation.reset_camera()
	gestures(control,"导航观察台")
	navigation.reset_camera()
	check(view.global_basis.z.is_equal_approx(Vector3.UP) and not control.user_adjusted,"导航F复位仍为固定顶视")
	navigation.free()
	stage.free()
	await _combat()
	await _visual()
	var out := FileAccess.open(Artifacts.ensure_dir("reports").path_join("observation_camera.json"),FileAccess.WRITE)
	out.store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	out.close()
	print("[观察相机] checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)

func _combat() -> void:
	var lab := Combat.instantiate()
	root.add_child(lab)
	current_scene = lab
	await frames(6)
	check(lab.get_selection().is_empty() and lab._generate.disabled,"战斗原型台启动全不选且不能空生成")
	lab._show_enemy_tuning("VisualChargeBeetle")
	await frames(5)
	var observe: Button
	for node in lab._tuning_panel.find_children("*","Button",true,false):
		if node.text == "观察本草稿": observe = node
	check(is_instance_valid(observe),"实际调参页有观察本草稿按钮")
	var point := observe.get_global_rect().get_center()
	await routed(motion(Vector2.ZERO,point))
	await routed(button(MOUSE_BUTTON_LEFT,true,point))
	await routed(button(MOUSE_BUTTON_LEFT,false,point))
	for i in 24: await physics_frame
	var observer: Node3D = lab._attack_observer
	check(observer.study and observer.camera_control.active,"真实按钮进入可操作观察相机")
	if not observer.study or not observer.camera_control.active:
		lab.queue_free()
		paused = false
		await frames(3)
		return
	paused = true
	gestures(observer.camera_control,"冻结草稿")
	var before: Transform3D = observer.camera.global_transform
	point = observer._pause.get_global_rect().get_center()
	await routed(button(MOUSE_BUTTON_RIGHT,true,point))
	await routed(motion(Vector2(50,25),point+Vector2(50,25)))
	await routed(button(MOUSE_BUTTON_RIGHT,false,point))
	check(observer.camera.global_transform.is_equal_approx(before),"从GUI按钮上开始的右键拖动不穿透")
	var background := root.get_visible_rect().size*Vector2(0.72,0.8)
	await routed(button(MOUSE_BUTTON_RIGHT,true,background))
	await routed(motion(Vector2(55,10),background+Vector2(55,10)))
	check(not observer.camera.global_transform.is_equal_approx(before),"冻结时空白画面的实际右键输入能旋转")
	await routed(button(MOUSE_BUTTON_RIGHT,false,point))
	before = observer.camera.global_transform
	await routed(motion(Vector2(55,10),background))
	check(observer.camera.global_transform.is_equal_approx(before),"在GUI上松键不会粘住相机")
	await lab.observe_draft("VisualChargeBeetle",Tuning.defaults("VisualChargeBeetle"),false)
	check(observer.camera.global_transform.is_equal_approx(before),"同一草稿重播保留手动构图")
	observer._view.select(1)
	observer._view.item_selected.emit(1)
	check(observer.camera.global_basis.z.is_equal_approx(Vector3.UP) and not observer.camera_control.user_adjusted,"固定俯视可恢复明确构图")
	lab._show_enemy_tuning("VisualChargeBeetle")
	check(not observer.camera_control.active,"返回参数后停止观察相机输入")
	paused = false
	lab.queue_free()
	await frames(3)

func _visual() -> void:
	var lab := Visual.instantiate()
	root.add_child(lab)
	current_scene = lab
	await frames(6)
	gestures(lab.camera_control,"敌人视觉台")
	lab._reset_view()
	check(not lab.camera_control.user_adjusted and lab.camera_control.focus.is_equal_approx(lab._camera_rig.global_position),"视觉台复位恢复模型中心")
	lab.queue_free()
	await frames(3)
