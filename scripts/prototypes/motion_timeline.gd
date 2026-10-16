extends Control
## 技能循环时间轴：把 charge / release 曲线和阶段占比画出来，让"爆发只有几个帧"这件事可见。
## 只读控件：不驱动动画；点击或拖动只发出 seek_requested(fraction)。

signal seek_requested(fraction: float)

const BAND_TEXT_MIN_PX := 58.0
const TICK_SECONDS := 0.25

var _bands: Array = []
var _cycle := 1.0
var _charge := PackedFloat32Array()
var _release := PackedFloat32Array()
var _cursor := 0.0
var _dragging := false
var heading := "技能循环"
var legend := "黄：蓄力量　蓝：释放量"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func set_state(bands: Array, cycle: float, charge: PackedFloat32Array, release_curve: PackedFloat32Array) -> void:
	_bands = bands
	_cycle = maxf(cycle, 0.0001)
	_charge = charge
	_release = release_curve
	queue_redraw()


func set_cursor(time_in_cycle: float) -> void:
	_cursor = clampf(time_in_cycle / _cycle, 0.0, 1.0)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
			if button.pressed:
				_emit_seek(button.position.x)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_emit_seek((event as InputEventMouseMotion).position.x)
		accept_event()


func _emit_seek(x: float) -> void:
	if size.x > 1.0:
		seek_requested.emit(clampf(x / size.x, 0.0, 1.0))


func _draw() -> void:
	var font: Font = get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.05, 0.86), true)
	if size.x < 120.0 or size.y < 80.0:
		return
	var inner := Rect2(Vector2(10, 8), Vector2(size.x - 20, size.y - 16))
	var bar := Rect2(inner.position + Vector2(0, 16), Vector2(inner.size.x, 18.0))
	var labels := PackedStringArray()
	for band in _bands:
		labels.append(String(band["label"]))
	draw_string(font, inner.position + Vector2(0, 11),
		"%s %.2f 秒（60 fps 共 %d 帧）　左起：%s" % [heading, _cycle, int(roundf(_cycle * 60.0)), " / ".join(labels)],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.88, 0.92, 1.0))
	for band in _bands:
		var from: float = float(band["from"]) / _cycle
		var to: float = float(band["to"]) / _cycle
		var band_px := bar.size.x * (to - from)
		draw_rect(Rect2(bar.position + Vector2(bar.size.x * from, 0), Vector2(maxf(band_px, 1.0), bar.size.y)), band["color"], true)
		if band_px > BAND_TEXT_MIN_PX:
			draw_string(font, bar.position + Vector2(bar.size.x * from + 5, 13),
				String(band["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.95))
	_draw_burst_marker(font, bar)
	var graph := Rect2(bar.position + Vector2(0, bar.size.y + 20),
		Vector2(inner.size.x, maxf(inner.size.y - bar.size.y - 30, 24.0)))
	draw_rect(graph, Color(0.06, 0.07, 0.09, 0.9), true)
	_draw_time_ticks(font, graph)
	_draw_curve(graph, _charge, Color(1.0, 0.82, 0.35, 0.95))
	_draw_curve(graph, _release, Color(0.42, 0.85, 1.0, 0.95))
	draw_string(font, graph.position + Vector2(4, 12), legend, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.78, 0.82, 1.0))
	var cursor_x := inner.position.x + inner.size.x * _cursor
	draw_line(Vector2(cursor_x, inner.position.y), Vector2(cursor_x, inner.end.y), Color(1, 1, 1, 0.85), 2.0)
	draw_string(font, Vector2(minf(cursor_x + 4.0, size.x - 74.0), size.y - 4.0),
		"%.2f s" % (_cursor * _cycle), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.9))


## 爆发段可能只有 1~2 像素宽：额外画一根醒目竖线和帧数标注，避免被看成没有这一段。
func _draw_burst_marker(font: Font, bar: Rect2) -> void:
	for band in _bands:
		if not bool(band.get("decisive", false)):
			continue
		var from: float = float(band["from"]) / _cycle
		var to: float = float(band["to"]) / _cycle
		var center := bar.position.x + bar.size.x * ((from + to) * 0.5)
		draw_line(Vector2(center, bar.position.y - 3.0), Vector2(center, bar.end.y + 3.0),
			Color(1.0, 0.42, 0.2, 1.0), 2.0)
		var frames: float = roundf((to - from) * _cycle * 60.0)
		draw_string(font, Vector2(clampf(center - 46.0, bar.position.x, bar.end.x - 96.0), bar.end.y + 12.0),
			"打击段 %.1f%%，约 %d 帧" % [(to - from) * 100.0, int(frames)],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.62, 0.4, 1.0))


func _draw_time_ticks(font: Font, graph: Rect2) -> void:
	var t := 0.0
	while t <= _cycle + 0.0001:
		var x := graph.position.x + graph.size.x * (t / _cycle)
		draw_line(Vector2(x, graph.position.y), Vector2(x, graph.end.y), Color(1, 1, 1, 0.08), 1.0)
		if t > 0.0:
			draw_string(font, Vector2(x + 2.0, graph.end.y - 3.0), "%.2f" % t,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.62, 0.66, 0.7, 1.0))
		t += TICK_SECONDS


func _draw_curve(graph: Rect2, curve: PackedFloat32Array, color: Color) -> void:
	if curve.size() < 2:
		return
	var points := PackedVector2Array()
	for i in curve.size():
		var x := graph.position.x + graph.size.x * (float(i) / float(curve.size() - 1))
		var y := graph.end.y - graph.size.y * clampf(curve[i], 0.0, 1.0)
		points.append(Vector2(x, y))
	draw_polyline(points, color, 1.6, true)
