extends Control
## 只画玻璃底层，文字图标仍由父控件以原生分辨率绘制，不参与模糊。
const GLASS_SHADER := preload("res://shaders/hud_black_glass.gdshader")
var _shape := PackedVector2Array()
var _bounds := Rect2()

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	show_behind_parent = true
	var glass := ShaderMaterial.new()
	glass.shader = GLASS_SHADER
	material = glass

func set_shape(points: PackedVector2Array, at: Vector2) -> void:
	position = at
	if points == _shape:
		return
	_shape = points.duplicate()
	_bounds = Rect2(points[0], Vector2.ZERO)
	for point in points:
		_bounds = _bounds.expand(point)
	var corners := points.duplicate()
	while corners.size() < 8:
		corners.append(Vector2.ZERO)
	material.set_shader_parameter("corners", corners)
	material.set_shader_parameter("corner_count", points.size())
	material.set_shader_parameter("panel_origin", _bounds.position)
	material.set_shader_parameter("panel_size", _bounds.size)
	queue_redraw()

func _draw() -> void:
	if not _shape.is_empty():
		draw_rect(_bounds.grow(1), Color.WHITE)
