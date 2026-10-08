class_name DynamicCrosshair
extends Control
## 四条线段的内沿标出实际散布投影边界，换弹时旋转提示。
## 纯 _draw() 绘制，铺满父容器（放在 AimUI 这个 CanvasLayer 下）。

const LINE_WIDTH := 2.4
const LINE_LENGTH := 9.0
const UiThemeUtil := preload("res://scripts/ui_theme.gd")

## 武器传入完整角度，不再用 bloom 比例估计像素距离。
var spread_angles_degrees := Vector2.ZERO
var camera: Camera3D
var aiming := false
var reloading := false

var _reload_spin := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	if reloading:
		_reload_spin = fmod(_reload_spin + delta * TAU * 1.15, TAU)
	elif not is_zero_approx(_reload_spin):
		_reload_spin = 0.0
	queue_redraw()


func _draw() -> void:
	var center := get_aim_center()
	var extent := get_spread_half_extent()
	var color := UiThemeUtil.COLOR_AMMO if reloading else UiThemeUtil.COLOR_TITLE
	if aiming:
		color = UiThemeUtil.COLOR_ACCENT
	draw_circle(center, 1.2, color, true, -1, true)
	if not extent.is_zero_approx() or reloading:
		var directions: Array[Vector2] = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
		for direction in directions:
			var gap := extent.y if direction.x == 0.0 else extent.x
			var rotated := direction.rotated(_reload_spin)
			draw_line(center + rotated * gap, center + rotated * (gap + LINE_LENGTH), color, LINE_WIDTH, true)
	if aiming:
		var diamond := PackedVector2Array([
			center + Vector2(0.0, -2.8), center + Vector2(2.8, 0.0),
			center + Vector2(0.0, 2.8), center + Vector2(-2.8, 0.0),
		])
		draw_polyline(UiThemeUtil.closed(diamond), color, 1.4, true)


func get_aim_center() -> Vector2:
	if not is_instance_valid(camera):
		return size * 0.5
	return _project_direction(-camera.global_basis.z)


## 投影顺序与弹丸相同：先绕相机上轴偏航，再绕右轴俯仰。
## 水平边界包含俯仰造成的透视增量；使用相机投影自动适配 FOV / 宽高比，
## 再逆变换到控件坐标，避免 UI 缩放再次放大准星。
func get_spread_half_extent() -> Vector2:
	if not is_instance_valid(camera) or spread_angles_degrees.is_zero_approx():
		return Vector2.ZERO
	var direction := (-camera.global_basis.z).rotated(camera.global_basis.y, deg_to_rad(spread_angles_degrees.x))
	direction = direction.rotated(camera.global_basis.x, deg_to_rad(spread_angles_degrees.y))
	return (_project_direction(direction) - get_aim_center()).abs()


func _project_direction(direction: Vector3) -> Vector2:
	var pixel := camera.unproject_position(camera.global_position + direction * 10.0)
	return get_global_transform_with_canvas().affine_inverse() * pixel
