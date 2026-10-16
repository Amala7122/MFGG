extends SceneTree
## APS 形状数学的纯公式守卫（移植文档第 4、11 节）；不需要物理与导航烘焙。
const Shape := preload("res://scripts/nav_arc_shape.gd")
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_envelope()
	_resample_formula()
	_scale_chain()
	_abs_fallback_chain()
	_resample_points()
	_amplitude()
	_side_sign()
	_corner_vector()
	_distance_lookup()
	print("[APS 形状数学] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[APS 形状数学] " + message)

func _close(a: float, b: float, tolerance := 0.00001) -> bool:
	return absf(a - b) <= tolerance

## LowLevelArc.cpp:2273-2302 ComputeArcShape / :2309-2330 ComputeLocalSideSign。
func _envelope() -> void:
	for t: float in [0.1, 0.25, 0.5, 0.75, 0.9]:
		var outer := sin(PI * t)
		_check(_close(Shape.arc_shape(t, 1, "smooth"), outer), "Smooth(N=1) 必须等于 sin(pi t)，t=%.2f" % t)
		_check(_close(Shape.arc_shape(t, 6, "smooth"), pow(outer, 3.5)), "Smooth(N=6) 必须等于 sin(pi t)^3.5，t=%.2f" % t)
		_check(_close(Shape.arc_shape(t, 3, "wavy"), outer * absf(sin(3.0 * PI * t))), "Wavy(N=3) 必须等于 sin(pi t)*|sin(3 pi t)|，t=%.2f" % t)
	_check(_close(Shape.arc_shape(0.0, 3, "smooth"), 0.0) and _close(Shape.arc_shape(1.0, 3, "smooth"), 0.0), "包络在两端必须为 0")
	# 强度上限：N 超过 6 视为 6（APS MaxFilletSamples）。
	_check(_close(Shape.arc_shape(0.4, 9, "smooth"), Shape.arc_shape(0.4, 6, "smooth")), "包络的 N 必须夹到 1..6")

## LowLevelArc.cpp:941-946 点数公式 min(max3(N+2, ceil(len/L)+1, in), cap)。
func _resample_formula() -> void:
	var cases := [
		{"length": 4.0, "midpoints": 3, "in_count": 5, "cap": 128, "expected": 5},
		{"length": 40.0, "midpoints": 3, "in_count": 5, "cap": 128, "expected": 11},
		{"length": 40.0, "midpoints": 3, "in_count": 30, "cap": 128, "expected": 30},
		{"length": 4000.0, "midpoints": 3, "in_count": 30, "cap": 128, "expected": 128},
		{"length": 4000.0, "midpoints": 3, "in_count": 30, "cap": 192, "expected": 192},
	]
	for item: Dictionary in cases:
		var actual := Shape.resample_count(float(item.length), int(item.midpoints), int(item.in_count), int(item.cap))
		_check(actual == int(item.expected), "重采样点数应为 %d，实际 %d（len=%.1f）" % [int(item.expected), actual, float(item.length)])

## LowLevelArc.cpp:39 GOffsetScales。
func _scale_chain() -> void:
	var scales: Array = Shape.offset_scales()
	_check(scales.size() == 8, "相对缩幅必须是 8 档，实际 %d" % scales.size())
	var expected := [1.0, 0.875, 0.75, 0.625, 0.5, 0.375, 0.25, 0.125]
	for index in range(scales.size()):
		_check(_close(float(scales[index]), float(expected[index])), "第 %d 档应为 %.3f，实际 %.3f" % [index, float(expected[index]), float(scales[index])])
	for index in range(1, scales.size()):
		_check(float(scales[index]) < float(scales[index - 1]), "缩幅链必须严格单调递减")

## LowLevelArc.cpp:43 GArcAbsFallbackAmps（600/450/300/200/120/80 uu -> 米）。
func _abs_fallback_chain() -> void:
	var amps: Array = Shape.abs_fallback_amps()
	_check(amps.size() == 6, "绝对宽度回退必须是 6 档，实际 %d" % amps.size())
	var expected := [6.0, 4.5, 3.0, 2.0, 1.2, 0.8]
	for index in range(amps.size()):
		_check(_close(float(amps[index]), float(expected[index])), "绝对档 %d 应为 %.2f m" % [index, float(expected[index])])
	for index in range(1, amps.size()):
		_check(float(amps[index]) < float(amps[index - 1]), "绝对档必须降序")

## LowLevelArc.cpp:948-985 弧长等分与精确端点。
func _resample_points() -> void:
	var points := PackedVector3Array([Vector3(0, 1, 0), Vector3(5, 1, 0), Vector3(5, 1, 5), Vector3(15, 1, 5), Vector3(15, 1, 10)])
	var sampled := Shape.resample(points, 11)
	_check(sampled.size() == 11, "重采样点数应为 11，实际 %d" % sampled.size())
	_check(sampled[0].is_equal_approx(points[0]), "重采样必须精确保留首点")
	_check(sampled[sampled.size() - 1].is_equal_approx(points[points.size() - 1]), "重采样必须精确保留末点")
	var first := Shape.flat_distance(sampled[0], sampled[1])
	for index in range(1, sampled.size()):
		var step := Shape.flat_distance(sampled[index - 1], sampled[index])
		_check(_close(step, first, 0.001), "重采样必须按 2D 弧长等分，第 %d 段 %.4f != %.4f" % [index, step, first])
	_check(Shape.resample(PackedVector3Array([Vector3.ZERO, Vector3(1, 0, 0)]), 1).size() == 2, "目标点数 < 2 时必须原样返回")
	# 折线总长 = 5 + 5 + 10 + 5 = 25 米，11 点等分 -> 每段 2.5 米。
	_check(_close(Shape.flat_distance(sampled[0], sampled[1]), 25.0 / 10.0, 0.001), "重采样段长应为总长/(n-1)")

## LowLevelArc.cpp:2959-2963 BaseAmp = 0.25 * Dist2D * clamp(|S|,0,3)/3。
func _amplitude() -> void:
	_check(_close(Shape.base_amp(10.0, 3.0), 2.5), "BaseAmp(10, S=3) 必须为 2.5")
	_check(_close(Shape.base_amp(10.0, 1.5), 1.25), "BaseAmp(10, S=1.5) 必须为 1.25")
	_check(_close(Shape.base_amp(10.0, 9.0), 2.5), "|S| 必须夹到 3")
	_check(_close(Shape.base_amp(10.0, -1.5), 1.25), "BaseAmp 取 |S|")
	_check(_close(Shape.base_amp(10.0, 0.0), 0.0), "S=0 时幅度必须为 0")

## LowLevelArc.cpp:2309-2330 ComputeLocalSideSign：Smooth 恒定，Wavy 半波交替。
func _side_sign() -> void:
	_check(_close(Shape.local_side_sign(0.3, 3, "smooth", -1.0), -1.0), "Smooth 必须恒用全局侧符号")
	_check(_close(Shape.local_side_sign(0.1, 3, "wavy", 1.0), 1.0), "Wavy 第一个半波符号应与全局侧一致")
	_check(_close(Shape.local_side_sign(0.4, 3, "wavy", 1.0), -1.0), "Wavy 第二个半波必须反向")
	_check(_close(Shape.local_side_sign(0.4, 3, "wavy", -1.0), 1.0), "Wavy 反向强度必须整体翻侧")

## LowLevelArc.cpp:988-1011 ComputeCornerRightVector。
func _corner_vector() -> void:
	var right := Shape.corner_right_vector(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 0))
	_check(_close(right.length(), 1.0, 0.0001), "转角右向量必须是单位向量")
	_check(_close(right.y, 0.0), "转角右向量必须在水平面内")
	var degenerate := Shape.corner_right_vector(Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, 1))
	_check(degenerate.length() > 0.9, "退化时必须回退到备用方向的右向量")

## LowLevelArc.cpp:1629-1674 GetPointAtPathDistance。
func _distance_lookup() -> void:
	var points := PackedVector3Array([Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(4, 0, 6)])
	var measured := Shape.cumulative_distances(points)
	var cumulative: PackedFloat32Array = measured.cumulative
	_check(_close(float(measured.total), 10.0), "累计长度应为 10，实际 %.3f" % float(measured.total))
	var middle := Shape.point_at_distance(points, cumulative, 10.0, 5.0, 1)
	_check(middle.point.is_equal_approx(Vector3(4, 0, 1)), "按距离取点应为 (4,0,1)，实际 %s" % str(middle.point))
	_check(Shape.point_at_distance(points, cumulative, 10.0, -1.0, 1).point.is_equal_approx(points[0]), "距离 <= 0 必须返回首点")
	_check(Shape.point_at_distance(points, cumulative, 10.0, 99.0, 1).point.is_equal_approx(points[2]), "距离 >= 总长必须返回末点")
