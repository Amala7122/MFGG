extends CharacterBody3D
## 编辑器预览用的步行控制器：只负责走动、观察和复位，不带武器、敌人或战斗逻辑。
##
## 鼠标模式一律通过 MouseControl 请求；自动运行下系统鼠标保持可见，不会被捕获。

const MouseControlUtil := preload("res://scripts/mouse_control.gd")

@export var walk_speed := 4.4
@export var sprint_speed := 7.2
@export var ground_acceleration := 28.0
@export var ground_deceleration := 24.0
@export var air_control := 0.34
@export var jump_velocity := 5.2
@export var gravity := 22.0
@export var mouse_sensitivity := 0.0026
@export var pitch_limit_degrees := 82.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var hint: Label = $UI/Root/Panel/Margin/VBox/Hint
@onready var crosshair: ColorRect = $UI/Root/Crosshair

var _start_transform: Transform3D
var _start_yaw := 0.0
var _pitch := 0.0
var _jump_requested := false
var _captured := false


func _ready() -> void:
	_start_transform = global_transform
	_start_yaw = rotation.y
	up_direction = Vector3.UP
	floor_snap_length = 0.4
	floor_max_angle = deg_to_rad(52.0)
	safe_margin = 0.04
	MouseControlUtil.mode = Input.MOUSE_MODE_VISIBLE
	_update_hint()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			if not MouseControlUtil.is_automation():
				MouseControlUtil.mode = Input.MOUSE_MODE_CAPTURED
				_update_hint()
	elif event is InputEventMouseMotion:
		if MouseControlUtil.mode == Input.MOUSE_MODE_CAPTURED:
			rotate_y(-event.relative.x * mouse_sensitivity)
			_pitch = clampf(
				_pitch - event.relative.y * mouse_sensitivity,
				-deg_to_rad(pitch_limit_degrees),
				deg_to_rad(pitch_limit_degrees)
			)
			head.rotation.x = _pitch
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				MouseControlUtil.mode = Input.MOUSE_MODE_VISIBLE
				_update_hint()
			KEY_SPACE:
				_jump_requested = true
			KEY_R:
				_reset()
				_update_hint()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif _jump_requested:
		velocity.y = jump_velocity
	_jump_requested = false

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input.x, 0.0, input.y))
	direction.y = 0.0
	direction = direction.normalized()
	var wanted := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	if input.is_zero_approx():
		velocity.x = move_toward(velocity.x, 0.0, ground_deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, ground_deceleration * delta)
	else:
		var control := 1.0 if is_on_floor() else air_control
		velocity.x = move_toward(velocity.x, direction.x * wanted, ground_acceleration * control * delta)
		velocity.z = move_toward(velocity.z, direction.z * wanted, ground_acceleration * control * delta)
	move_and_slide()


func _process(_delta: float) -> void:
	var captured := MouseControlUtil.mode == Input.MOUSE_MODE_CAPTURED
	if captured != _captured:
		_captured = captured
		_update_hint()


func _reset() -> void:
	global_transform = _start_transform
	velocity = Vector3.ZERO
	_pitch = 0.0
	head.rotation.x = 0.0
	rotation.y = _start_yaw


func _update_hint() -> void:
	if hint == null:
		return
	if MouseControlUtil.is_automation():
		hint.text = "自动运行：视角不捕获，可直接用外部控制移动"
		return
	if MouseControlUtil.mode == Input.MOUSE_MODE_CAPTURED:
		hint.text = "Esc 释放鼠标 · R 回到起点"
	else:
		hint.text = "点击画面锁定视角 · R 回到起点"
	if crosshair != null:
		crosshair.visible = MouseControlUtil.mode == Input.MOUSE_MODE_CAPTURED
