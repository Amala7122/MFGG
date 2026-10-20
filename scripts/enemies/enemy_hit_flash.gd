extends Node
## 一次缓存网格、每只共用一个短暂红色叠层；不改共享材质或晶体原色。
var duration := 0.14
var strength := 0.8
var remaining := 0.0
var _parts: Array[MeshInstance3D] = []
var _original: Array[Material] = []
var _red: StandardMaterial3D


func setup(visual: Node, values: Dictionary) -> void:
	duration = float(values.hit_flash_duration)
	strength = float(values.hit_flash_strength)
	_red = StandardMaterial3D.new()
	_red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_red.albedo_color = Color(1.0, 0.025, 0.015, strength)
	_red.cull_mode = BaseMaterial3D.CULL_DISABLED
	for part: MeshInstance3D in visual.find_children("*", "MeshInstance3D", true, false):
		_parts.append(part)
		_original.append(part.material_overlay)
	set_process(false)


func play() -> void:
	remaining = duration
	for part in _parts:
		if is_instance_valid(part):
			part.material_overlay = _red
	set_process(true)


func clear() -> void:
	remaining = 0.0
	for index in _parts.size():
		if is_instance_valid(_parts[index]):
			_parts[index].material_overlay = _original[index]
	set_process(false)


func _process(delta: float) -> void:
	remaining -= delta
	if remaining <= 0.0:
		clear()


func _exit_tree() -> void:
	clear()
