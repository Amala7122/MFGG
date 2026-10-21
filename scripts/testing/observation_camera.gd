extends Node
## 观察相机共用操作。宿主只把未被GUI使用的输入交给handle_event；不改变系统鼠标模式。
signal changed
const HELP_TEXT := "右键拖动旋转 · 滚轮缩放 · 中键拖动平移"
var camera: Camera3D
var focus := Vector3.ZERO
var min_distance := 0.25
var max_distance := 5000.0
var min_size := 0.5
var max_size := 5000.0
var sensitivity := 0.006
var user_adjusted := false
var active := true:
	set(value):
		active = value
		if not active: cancel_drag()
var _drag_button := MOUSE_BUTTON_NONE

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func bind(view: Camera3D, target: Vector3) -> void:
	camera = view
	focus = target
	user_adjusted = false
	cancel_drag()

func set_view(position: Vector3, target: Vector3, up := Vector3.UP) -> void:
	if not is_instance_valid(camera): return
	cancel_drag()
	focus = target
	camera.global_position = position
	camera.look_at(focus, up)
	user_adjusted = false
	changed.emit()

func distance() -> float:
	return camera.global_position.distance_to(focus) if is_instance_valid(camera) else 0.0

func set_distance(value: float) -> void:
	if not is_instance_valid(camera): return
	var direction := (camera.global_position-focus).normalized()
	if direction.is_zero_approx(): direction = camera.global_basis.z.normalized()
	camera.global_position = focus + direction * clampf(value,min_distance,minf(max_distance,camera.far*0.8))
	changed.emit()

func translate_focus(offset: Vector3) -> void:
	if not is_instance_valid(camera): return
	focus += offset
	camera.global_position += offset

func cancel_drag() -> void: _drag_button = MOUSE_BUTTON_NONE

func _available() -> bool:
	return active and is_instance_valid(camera) and camera.is_current()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT: cancel_drag()

func _input(event: InputEvent) -> void:
	# 拖动在空白处开始后，跨过GUI仍连续；在GUI上松键也必须结束，避免粘住。
	if not _available(): cancel_drag(); return
	if _drag_button != MOUSE_BUTTON_NONE and (event is InputEventMouseMotion or (event is InputEventMouseButton and not event.pressed)):
		if handle_event(event): get_viewport().set_input_as_handled()

func handle_event(event: InputEvent) -> bool:
	if not _available(): cancel_drag(); return false
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_drag()
		return false
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_RIGHT,MOUSE_BUTTON_MIDDLE]:
			if event.pressed: _drag_button = event.button_index
			elif event.button_index == _drag_button: cancel_drag()
			return true
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
			var steps: float = event.factor if event.factor > 0.0 else 1.0
			var factor := pow(0.9,steps if event.button_index == MOUSE_BUTTON_WHEEL_UP else -steps)
			if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
				camera.size = clampf(camera.size*factor,min_size,max_size)
				changed.emit()
			else: set_distance(distance()*factor)
			user_adjusted = true
			return true
	if not event is InputEventMouseMotion or _drag_button == MOUSE_BUTTON_NONE: return false
	if _drag_button == MOUSE_BUTTON_RIGHT:
		var offset := camera.global_position-focus
		var radius := maxf(offset.length(),min_distance)
		var yaw: float = atan2(offset.x,offset.z) - event.relative.x*sensitivity
		var pitch := clampf(asin(clampf(offset.y/radius,-1,1))+event.relative.y*sensitivity,-PI*0.497,PI*0.497)
		camera.global_position = focus + Vector3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))*radius
		camera.look_at(focus)
	else:
		# 按实际投影反算每像素世界位移：透视／正交、斜视／顶视均同一方向与比例。
		var center := camera.get_viewport().get_visible_rect().size*0.5
		var depth := maxf(distance(),camera.near*2.0)
		translate_focus(camera.project_position(center,depth)-camera.project_position(center+event.relative,depth))
	user_adjusted = true
	changed.emit()
	return true
