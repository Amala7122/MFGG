class_name DamageDirectionIndicator
extends Control
## 受击方向指示：在准星外围、朝伤害来源画一枚低多边形楔片。
##
## 为什么需要它：这是第三人称视角，背后完全在画面之外。被近战从后面捅刀时
## 玩家拿不到任何信息 —— 既看不到人，也听不出方位（音效是固定的"受伤"声）。
## 于是"被背刺"就从"可以应对的失误"变成了"随机死亡"。
## 这个指示器把伤害来源变成可见信息，配合护盾构成完整的应对闭环：
## 指示器告诉你往哪转 / 往哪跑，护盾保证你有那个时间窗口。
##
## 实现要点：
##   - 方位角以【相机水平朝向】为前方基准，而不是角色身体朝向。
##     玩家是转视角观察的，指示器跟着视角走才符合直觉。
##   - 最多同时保留 MAX_MARKERS 个方位，各自独立淡出，可叠加显示被围攻。

const MAX_MARKERS := 4
## 单个指示的存活时间（秒）。
const LIFETIME := 1.6
## 弧距屏幕中心的半径（会被屏幕短边缩小，窄屏也能完整显示）。
const RADIUS := 132.0
## 楔片张角（弧度）。
const ARC_SPAN := 0.62
const COLOR_HIT := Color(1.0, 0.32, 0.24, 1.0)

## [{ "angle": float（0=正前方，顺时针为正）, "age": float }]
var _markers: Array = []
var _camera: Camera3D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## 注入用来判定"前方"的相机。
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## 登记一次受击。from_world = 受伤者位置，source_world = 伤害来源位置。
func register_hit(from_world: Vector3, source_world: Vector3) -> void:
	if _camera == null:
		return
	var forward := -_camera.global_basis.z
	forward.y = 0.0
	if forward.is_zero_approx():
		return
	forward = forward.normalized()
	var to_source := source_world - from_world
	to_source.y = 0.0
	if to_source.is_zero_approx():
		# 来源与自己重合（例如脚下的爆炸）：没有方位可言，跳过。
		return
	to_source = to_source.normalized()
	# forward.cross(UP) 就是右手方向，用它与 to_source 的点积区分左右。
	var right := forward.cross(Vector3.UP)
	var angle := atan2(to_source.dot(right), to_source.dot(forward))
	_markers.append({"angle": angle, "age": 0.0})
	while _markers.size() > MAX_MARKERS:
		_markers.pop_front()


func is_active() -> bool:
	return not _markers.is_empty()


func _process(delta: float) -> void:
	if _markers.is_empty():
		return
	var alive: Array = []
	for marker in _markers:
		var entry := marker as Dictionary
		entry["age"] = float(entry["age"]) + delta
		if float(entry["age"]) < LIFETIME:
			alive.append(entry)
	_markers = alive
	queue_redraw()


func _draw() -> void:
	if _markers.is_empty():
		return
	var center := size * 0.5
	# 用短边推算半径：窄屏时自动收进来，不会画到画面外。
	var radius := minf(RADIUS, minf(size.x, size.y) * 0.42)
	if radius <= 1.0:
		return
	for marker in _markers:
		var entry := marker as Dictionary
		var angle := float(entry["angle"])
		var fade := 1.0 - clampf(float(entry["age"]) / LIFETIME, 0.0, 1.0)
		# 屏幕坐标 y 轴朝下，而"前方"是屏幕上方，所以方向向量要用 -cos。
		var facing := Vector2(sin(angle), -cos(angle))
		var polar := atan2(facing.y, facing.x)
		var inner := radius - 12.0
		var outer := radius + 3.0
		var left_angle := polar - ARC_SPAN * 0.5
		var right_angle := polar + ARC_SPAN * 0.5
		var left := Vector2(cos(left_angle), sin(left_angle))
		var middle := Vector2(cos(polar), sin(polar))
		var right := Vector2(cos(right_angle), sin(right_angle))
		var color := Color(COLOR_HIT.r, COLOR_HIT.g, COLOR_HIT.b, COLOR_HIT.a * fade)
		draw_colored_polygon(PackedVector2Array([
			center + left * inner,
			center + left * outer,
			center + middle * (outer + 7.0),
			center + right * outer,
			center + right * inner,
			center + middle * (inner + 4.0),
		]), color)
