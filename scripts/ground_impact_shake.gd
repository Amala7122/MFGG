extends Node
## 局部相机位移：暂停同步，移除自身上帧偏移后再叠加，不写入瞄准角。
var strength := 0.0
var remaining := 0.0
var age := 0.0
var _offset := Vector3.ZERO

func request(amount: float) -> void:
	strength = minf(maxf(strength, amount), 0.06)
	remaining = 0.32
	age = 0.0

func _physics_process(delta: float) -> void:
	var camera := get_parent() as Camera3D
	if camera == null:
		return
	camera.position -= _offset
	remaining = maxf(remaining - delta, 0.0)
	age += delta
	var envelope := pow(remaining / 0.32, 2.0)
	_offset = Vector3(sin(age * 71.0) * 0.35, sin(age * 57.0), 0.0) * strength * envelope
	camera.position += _offset
	if remaining <= 0.0:
		strength = 0.0

func _exit_tree() -> void:
	var camera := get_parent() as Camera3D
	if is_instance_valid(camera):
		camera.position -= _offset
