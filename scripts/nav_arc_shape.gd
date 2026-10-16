extends RefCounted
## APS 路径形状流水线移植（AdaptivePathfindingSystem 2.06 / UE 5.8）。
##
## 来源：D:/godot_project/Adaptive64768b7cb9a5V14/Source/AdaptivePathfindingSystem/
##       Private/Path/APS_PathMode_LowLevelArc.cpp（每个函数/常量后面写 APS 行号）。
## 逐阶段对照见 docs/features/APS路径算法移植实现文档.md 第 4 节。
## 阶段顺序与 APS 一致（LowLevelArc.cpp:2338-2339 的管线自述）：
##   fillet -> resample -> warp -> validate -> final_gate
##
## 刻意与 APS 不同之处（移植适配，全部登记在文档第 9 节）：
##   1. 判定放宽一律不做：APS 的段验证只是 navmesh 表面 LOS，不懂胶囊半径与净空；
##      这里一律用本项目的投影门限（一级）+ Query.ground_segment 完整身体通道（二级）。
##   2. GMinPathPointDistance2D 1.0 uu -> 0.05 m（Godot 网格精度与浮点尺度不同）。
##   3. 宽度来源：APS 用 |LaneOffset| 同时驱动圆角与弧宽；本项目保留既有语义，
##      corner_rounding 决定圆角切除距离、lane_offset 决定车道偏移，互不覆盖。
##      故 BASE_FILLET_SCALE/STRENGTH_FILLET_SCALE 由 APS 的 0.6/0.4 适配为 1.0/0.0。
##   4. 打分阈值：APS 的 0.35 / 0.20 / 0.35 在默认配置下适配为 0.02，保持既有
##      「相邻段夹角 > 0.98 才跳过圆角」的接受面；设回 APS 原值即得 APS 语义。
##   5. 圆角输出点预算：APS 只有 192 点硬上限；这里同时限制参与圆角的角点数
##      （MAX_FILLET_CORNERS），避免一次重算内的 ground_segment 次数失控。
##   6. 弧长重采样用单调游标，不把 APS 的 O(N^2) 弧长查询带进来（移植风险 4）。

const Query := preload("res://scripts/spatial_query.gd")

# ───────────────────────────────────────── APS 原样常量（UU ÷ 100 = 米）
const OFFSET_SCALES := [1.0, 0.875, 0.75, 0.625, 0.5, 0.375, 0.25, 0.125]  # :39
const ABS_FALLBACK_AMPS := [6.0, 4.5, 3.0, 2.0, 1.2, 0.8]                  # :43（600/450/300/200/120/80 uu）
const ARC_MIN_STRENGTH := 0.1            # :2889 |ArcStrength| < 0.1 视为关闭
const ARC_STRENGTH_CAP := 3.0            # :2961
const BASE_AMP_FACTOR := 0.25            # :2963
const SPARSE_WARP_MIN_POINTS := 64       # :2984
const SPARSE_WARP_MAX_STRENGTH := 1.5    # :2984
const TARGET_ARC_SEGMENT_LENGTH := 4.0   # :944 400 uu
const RESAMPLE_CAP := 128                # :946
const FILLET_CAP := 192                  # :1089
const STRONG_CORNER_THRESHOLD := 0.35    # :1067
const MIN_WINDOW_STRENGTH := 0.20        # :1068
const MIN_VISIBILITY_ANCHOR_SPAN := 0.8  # :1069 80 uu
const WINDOW_ANGLE_BLEND := 0.70         # :1070
const CROSS_MISMATCH_FACTOR := 0.60      # :1071
const PERSISTENCE_BASE_FACTOR := 0.45    # :1072
const PERSISTENCE_FULL_SUPPORT := 0.35   # :1073
const BLOCKED_VISIBILITY_FACTOR := 1.15  # :1074
const CLEAR_VISIBILITY_FACTOR := 0.72    # :1075
const NEARBY_CORNER_OVERRIDE := 1.35     # :1076
const MIN_SEGMENT_LEN_FOR_FILLET := 0.08 # :1077 8 uu
const MAX_SEGMENT_PORTION := 0.40        # :1078 APS 0.45 -> 0.40（适配 3，保持既有圆角上限）
const BASE_FILLET_SCALE := 1.0           # :1079 APS 0.6 -> 1.0（适配 3）
const STRENGTH_FILLET_SCALE := 0.0       # :1080 APS 0.4 -> 0.0（适配 3）
const MIN_FILLET_DISTANCE := 0.10        # :1081 APS 4 uu -> 0.10 m（适配 4：与移植前 radius > 0.1 的接受面一致）
const MIN_SLOPE_DISTANCE_2D := 0.16      # :1082 16 uu
const MIN_SLOPE_CHANGE_FOR_SCORE := 0.08 # :1083
const FULL_SLOPE_CHANGE_FOR_SCORE := 0.45 # :1084
const WEAK_CROSS_THRESHOLD := 0.05       # :1085
const MIN_FILLET_SAMPLES := 2            # :1086
const MAX_FILLET_SAMPLES := 6            # :1087
const WINDOW_LOOK_FACTOR := 1.25         # :1093
const WINDOW_LOOK_MIN := 1.0             # :1093 100 uu
const WINDOW_LOOK_MAX := 4.0             # :1093 400 uu
const MIN_CORNER_SPACING_FACTOR := 0.9   # :1094
const MIN_CORNER_SPACING_MIN := 0.8      # :1094 80 uu
const MIN_CORNER_SPACING_MAX := 2.6      # :1094 260 uu
const SLOPE_EVENT_THRESHOLD := 0.35      # :1318 事件分类阈值
# ── 移植适配阈值（适配 4）
const MIN_POINT_DISTANCE := 0.05         # :66 1.0 uu -> 0.05 m
const CORNER_SCORE_THRESHOLD := 0.02     # :1067 APS 0.35 -> 0.02
const CORNER_NOISE_WINDOW := 0.02        # :1068 APS 0.20 -> 0.02
const CORNER_NOISE_LOCAL := 0.02         # :1328 APS 0.35 -> 0.02
const MAX_FILLET_CORNERS := 64           # 适配 5：APS 无角点数上限

## 最近一次 shape() 的统计（观察台与验收报告消费）。
static var last_stats: Dictionary = {}

# ───────────────────────────────────────────────────────────── 通用小工具

static func _count(key: String, amount: int = 1) -> void:
	last_stats[key] = int(last_stats.get(key, 0)) + amount

static func flat_distance(a: Vector3, b: Vector3) -> float:
	## APS FVector::Dist2D：只算水平面。
	return Vector2(a.x - b.x, a.z - b.z).length()

static func direction_2d(from: Vector3, to: Vector3) -> Vector3:
	## APS GetSafeNormal2D。
	var offset := Vector3(to.x - from.x, 0.0, to.z - from.z)
	return offset / offset.length() if offset.length() > 0.000001 else Vector3.ZERO

static func right_of(direction: Vector3) -> Vector3:
	## UE 右向量 (-Dir.Y, Dir.X, 0) -> Godot (-Dir.Z, 0, Dir.X)。
	return Vector3(-direction.z, 0.0, direction.x)

static func cumulative_distances(points: PackedVector3Array) -> Dictionary:
	## APS BuildCumulativeDistances（:1549-1578）。
	var cumulative := PackedFloat32Array()
	var total := 0.0
	for index in range(points.size()):
		if index > 0:
			total += flat_distance(points[index - 1], points[index])
		cumulative.append(total)
	return {"cumulative": cumulative, "total": total}

static func point_at_distance(points: PackedVector3Array, cumulative: PackedFloat32Array, total: float, distance: float, cursor: int) -> Dictionary:
	## APS GetPointAtPathDistance（:1629-1674）；游标单调推进，避免 O(N^2)。
	var count := points.size()
	if count <= 0:
		return {"point": Vector3.ZERO, "index": 0}
	if distance <= 0.0:
		return {"point": points[0], "index": 0}
	if distance >= total:
		return {"point": points[count - 1], "index": count - 1}
	var index := 1 if cursor < 1 else cursor
	while index < count and cumulative[index] < distance:
		index += 1
	if index >= count:
		return {"point": points[count - 1], "index": count - 1}
	var span := cumulative[index] - cumulative[index - 1]
	var local := 0.0 if span <= 0.000001 else (distance - cumulative[index - 1]) / span
	return {"point": points[index - 1].lerp(points[index], clampf(local, 0.0, 1.0)), "index": index}

static func slope_grade(from: Vector3, to: Vector3) -> float:
	## APS ComputeSlopeGrade（:1174-1183）。
	var horizontal := flat_distance(from, to)
	return 0.0 if horizontal < MIN_SLOPE_DISTANCE_2D else (to.y - from.y) / horizontal

static func slope_strength_from_change(change: float) -> float:
	## APS ComputeSlopeStrengthFromChange（:1185-1194）。
	return clampf((change - MIN_SLOPE_CHANGE_FOR_SCORE) / (FULL_SLOPE_CHANGE_FOR_SCORE - MIN_SLOPE_CHANGE_FOR_SCORE), 0.0, 1.0)

static func corner_right_vector(direction_in: Vector3, direction_out: Vector3, fallback: Vector3) -> Vector3:
	## APS ComputeCornerRightVector（:988-1011）。
	var tangent := direction_in + direction_out
	tangent.y = 0.0
	if tangent.length() > 0.000001:
		return right_of(tangent.normalized())
	var combined := right_of(direction_in) + right_of(direction_out)
	combined.y = 0.0
	if combined.length() > 0.000001:
		return combined.normalized()
	return right_of(fallback)

# ───────────────────────────────────────────────── 纯数学：包络 / 符号 / 幅度

static func arc_shape(t: float, num_midpoints: int, mode: String) -> float:
	## APS ComputeArcShape（:2273-2302）。
	## Smooth: Shape = sin(pi t)^(1+(N-1)*0.5)；Wavy: Shape = sin(pi t)*|sin(N pi t)|。
	var outer := sin(PI * t)
	if mode == "wavy":
		var humps := clampi(num_midpoints, 1, MAX_FILLET_SAMPLES)
		return outer * absf(sin(float(humps) * PI * t))
	var exponent := 1.0 + (float(clampi(num_midpoints, 1, MAX_FILLET_SAMPLES)) - 1.0) * 0.5
	if outer <= 0.0:
		return -pow(-outer, exponent) if outer < 0.0 else 0.0
	return pow(outer, exponent)

static func local_side_sign(t: float, num_midpoints: int, mode: String, global_side: float) -> float:
	## APS ComputeLocalSideSign（:2309-2330）：Smooth 恒用全局侧；Wavy 按半波交替。
	if mode != "wavy":
		return global_side
	var humps := clampi(num_midpoints, 1, MAX_FILLET_SAMPLES)
	var carrier := signf(sin(float(humps) * PI * t))
	return global_side * (carrier if absf(carrier) > 0.0 else 1.0)

static func base_amp(dist2d: float, strength: float) -> float:
	## APS :2959-2963 BaseAmp = 0.25 * Dist2D * clamp(|S|,0,3)/3。
	return BASE_AMP_FACTOR * dist2d * clampf(absf(strength), 0.0, ARC_STRENGTH_CAP) / ARC_STRENGTH_CAP

static func offset_scales() -> Array:
	return OFFSET_SCALES.duplicate()

static func abs_fallback_amps() -> Array:
	return ABS_FALLBACK_AMPS.duplicate()

static func resample_count(total_length: float, num_midpoints: int, in_count: int, max_points: int, segment_length: float = TARGET_ARC_SEGMENT_LENGTH) -> int:
	## APS BuildArcSamplingPath（:941-946）：min(max3(N+2, ceil(len/L)+1, in), cap)。
	var driven := ceili(total_length / maxf(segment_length, 0.01)) + 1
	return mini(maxi(maxi(num_midpoints + 2, driven), in_count), max_points)

static func resample(points: PackedVector3Array, desired_total: int) -> PackedVector3Array:
	## APS BuildArcSamplingPath（:948-985）：2D 弧长等分，首末端点精确保留。
	var count := points.size()
	if count < 2 or desired_total < 2:
		return points
	var measured := cumulative_distances(points)
	var cumulative: PackedFloat32Array = measured.cumulative
	var total: float = measured.total
	if total < 0.000001:
		return points
	var out := PackedVector3Array()
	out.append(points[0])
	var index := 1
	for sample in range(1, desired_total - 1):
		var target := total * float(sample) / float(desired_total - 1)
		while index < count and cumulative[index] < target:
			index += 1
		if index >= count:
			out.append(points[count - 1])
			continue
		var span := cumulative[index] - cumulative[index - 1]
		var local := 0.0 if span <= 0.000001 else (target - cumulative[index - 1]) / span
		out.append(points[index - 1].lerp(points[index], clampf(local, 0.0, 1.0)))
	out.append(points[count - 1])
	return out

# ───────────────────────────────────────────────────── 一级 / 二级验证

static func projection_ok(body: CharacterBody3D, navigation_map: RID, point: Vector3) -> bool:
	## 一级（便宜）：投影门限。APS 用 Extent 限制的 FindNearestPoly；Godot 的
	## map_get_closest_point 不受范围限制，必须自己加几何门限（文档第 5 节）。
	var half := float(Query.dimensions(body).half_height)
	var feet := point - Vector3.UP * half
	var projected := NavigationServer3D.map_get_closest_point(navigation_map, feet)
	return Vector2(projected.x - feet.x, projected.z - feet.z).length() <= 0.35 and absf(projected.y - feet.y) <= 0.5

static func ground_at(body: CharacterBody3D, navigation_map: RID, point: Vector3, exclude: Array[RID]) -> Dictionary:
	## 二级（重）：真实支撑 + 落脚高度。返回地面点，失败返回空字典。
	_count("level1_queries")
	if not projection_ok(body, navigation_map, point):
		return {}
	_count("level2_queries")
	var hit := Query.floor_at(body, point - Vector3.UP * float(Query.dimensions(body).half_height),
		maxf(0.65, float(Query.dimensions(body).radius) + 0.25), exclude)
	return {"point": Query.ground_pose(body, hit, exclude)} if not hit.is_empty() else {}

static func _chain_ok(body: CharacterBody3D, from: Vector3, to: Vector3, safe_drop: float, exclude: Array[RID]) -> bool:
	_count("level2_segments")
	return Query.ground_segment(body, from, to, safe_drop, exclude)

static func _append(out: PackedVector3Array, point: Vector3) -> void:
	## APS AddPointIfNotNear2D（:1031-1044）：只做 2D 去重，不做验证。
	if out.is_empty() or flat_distance(out[out.size() - 1], point) > MIN_POINT_DISTANCE:
		out.append(point)

# ───────────────────────────────────────────────────────────── 圆角阶段

static func fillet_stage(body: CharacterBody3D, navigation_map: RID, points: PackedVector3Array, safe_drop: float, exclusion: Array[RID], values: Dictionary) -> PackedVector3Array:
	## APS BuildAdaptiveCornerFilletPath（:1046-1547）。
	var count := points.size()
	var width := absf(float(values.get("corner_rounding", 0.0)))
	var lane := float(values.get("lane_offset", 0.0))
	if count < 3 or (width <= 0.01 and absf(lane) <= 0.01):
		return points
	var detail := clampi(int(values.get("arc_num_midpoints", 3)), MIN_FILLET_SAMPLES, MAX_FILLET_SAMPLES)
	var look := clampf(width * WINDOW_LOOK_FACTOR, WINDOW_LOOK_MIN, WINDOW_LOOK_MAX)
	# 适配 4：车道偏移未启用时不做间距抑制，保持既有「除噪声外都圆角」的接受面。
	var spacing := clampf(absf(lane) * MIN_CORNER_SPACING_FACTOR, MIN_CORNER_SPACING_MIN, MIN_CORNER_SPACING_MAX) if absf(lane) > 0.01 else 0.0
	var measured := cumulative_distances(points)
	var cumulative: PackedFloat32Array = measured.cumulative
	var total: float = measured.total
	if total < 0.000001:
		return points
	var out := PackedVector3Array([points[0]])
	var tail := points[0]
	var has_accepted := false
	var last_accepted_distance := 0.0
	var last_accepted_score := 0.0
	var cursor := 1
	var handled := 0
	for index in range(1, count - 1):
		if handled >= MAX_FILLET_CORNERS:
			_append(out, points[index])
			tail = out[out.size() - 1]
			continue
		var previous := points[index - 1]
		var corner := points[index]
		var following := points[index + 1]
		var direction_in := direction_2d(previous, corner)
		var direction_out := direction_2d(corner, following)
		var length_in := flat_distance(previous, corner)
		var length_out := flat_distance(corner, following)
		var corner_distance: float = cumulative[index]
		# 回退 A（短段，:1229-1241）
		if direction_in.is_zero_approx() or direction_out.is_zero_approx() or length_in < MIN_SEGMENT_LEN_FOR_FILLET or length_out < MIN_SEGMENT_LEN_FOR_FILLET:
			_append(out, corner)
			tail = out[out.size() - 1]
			continue
		handled += 1
		_count("corners")
		var dot_in_out := direction_in.dot(direction_out)
		var local_strength := clampf(1.0 - dot_in_out, 0.0, 1.0)
		var cross_z := direction_in.x * direction_out.z - direction_in.z * direction_out.x
		var previous_anchor := point_at_distance(points, cumulative, total, maxf(0.0, corner_distance - look), cursor)
		var next_anchor := point_at_distance(points, cumulative, total, minf(total, corner_distance + look), cursor)
		cursor = int(previous_anchor.index)
		var anchor_in: Vector3 = previous_anchor.point
		var anchor_out: Vector3 = next_anchor.point
		var window_strength := local_strength
		var window_cross := cross_z
		var window_in := direction_in
		var window_out := direction_out
		var span := flat_distance(anchor_in, anchor_out)
		var resolved_in := direction_2d(anchor_in, corner)
		var resolved_out := direction_2d(corner, anchor_out)
		if not resolved_in.is_zero_approx() and not resolved_out.is_zero_approx():
			window_in = resolved_in
			window_out = resolved_out
			window_strength = clampf(1.0 - window_in.dot(window_out), 0.0, 1.0)
			window_cross = window_in.x * window_out.z - window_in.z * window_out.x
		# 坡度事件（:1266-1274）
		var local_slope_change := absf(slope_grade(corner, following) - slope_grade(previous, corner))
		var window_slope_change := absf(slope_grade(corner, anchor_out) - slope_grade(anchor_in, corner))
		var slope_strength := maxf(slope_strength_from_change(local_slope_change), slope_strength_from_change(window_slope_change))
		# 叉积一致性（:1276-1278）
		var cross_ok := absf(window_cross) > 0.000001 and signf(window_cross) == signf(cross_z)
		var cross_factor := 1.0 if cross_ok else CROSS_MISMATCH_FACTOR
		# 邻居支持（:1280-1294）
		var neighbor_support := 0.0
		for neighbor in [index - 1, index + 1]:
			if neighbor <= 0 or neighbor >= count - 1:
				continue
			var support_in := direction_2d(points[neighbor - 1], points[neighbor])
			var support_out := direction_2d(points[neighbor], points[neighbor + 1])
			if support_in.is_zero_approx() or support_out.is_zero_approx():
				continue
			var support_cross := support_in.x * support_out.z - support_in.z * support_out.x
			if absf(support_cross) > 0.000001 and signf(support_cross) != signf(cross_z):
				continue
			neighbor_support = maxf(neighbor_support, clampf(1.0 - support_in.dot(support_out), 0.0, 1.0))
		var persistence := lerpf(PERSISTENCE_BASE_FACTOR, 1.0, clampf(neighbor_support / PERSISTENCE_FULL_SUPPORT, 0.0, 1.0))
		# 锚点可见性（:1301-1311）：APS 用 navmesh raycast，这里用一级投影采样替代，只影响打分。
		var visibility := 1.0
		if span >= MIN_VISIBILITY_ANCHOR_SPAN:
			_count("level1_queries")
			var visible := true
			for step in range(3):
				if not projection_ok(body, navigation_map, anchor_in.lerp(anchor_out, float(step + 1) / 4.0)):
					visible = false
					break
			visibility = CLEAR_VISIBILITY_FACTOR if visible else BLOCKED_VISIBILITY_FACTOR
		var angle_score := lerpf(local_strength, window_strength, WINDOW_ANGLE_BLEND)
		var final_corner_score := angle_score * visibility * cross_factor * persistence
		var final_event_score := maxf(final_corner_score, slope_strength)
		# 事件分类（:1318-1326）
		var slope_dominant := slope_strength >= SLOPE_EVENT_THRESHOLD and (absf(cross_z) < WEAK_CROSS_THRESHOLD or angle_score < STRONG_CORNER_THRESHOLD or slope_strength > angle_score)
		# 回退 B（噪声，:1328-1348）
		if window_strength < CORNER_NOISE_WINDOW and local_strength < CORNER_NOISE_LOCAL and slope_strength < CORNER_NOISE_LOCAL:
			_append(out, corner)
			tail = out[out.size() - 1]
			continue
		# 回退 C（弱角，:1350-1370）
		if final_event_score < CORNER_SCORE_THRESHOLD:
			_append(out, corner)
			tail = out[out.size() - 1]
			continue
		# 回退 D（过密，:1372-1391）
		if has_accepted and corner_distance - last_accepted_distance < spacing and final_event_score < last_accepted_score * NEARBY_CORNER_OVERRIDE:
			_append(out, corner)
			tail = out[out.size() - 1]
			continue
		var corner_strength := clampf(final_event_score, 0.0, 1.0)
		# 圆角尺寸（:1395-1397）：切除距离由 corner_rounding 驱动（适配 3）。
		var max_fillet := MAX_SEGMENT_PORTION * minf(length_in, length_out)
		var fillet_distance := clampf(width * (BASE_FILLET_SCALE + STRENGTH_FILLET_SCALE * corner_strength), 0.0, max_fillet)
		# 回退 E（圆角过小，:1399-1413）
		if fillet_distance < MIN_FILLET_DISTANCE:
			_append(out, corner)
			tail = out[out.size() - 1]
			continue
		var entry := corner - direction_in * fillet_distance
		var exit := corner + direction_out * fillet_distance
		var fallback_direction := direction_2d(previous, following)
		var lane_sign := 1.0 if lane >= 0.0 else -1.0
		var preferred := Vector3.ZERO
		if slope_dominant:
			var travel := _resolve_travel_direction(next_anchor.point - previous_anchor.point, fallback_direction, direction_in, direction_out)
			var travel_right := right_of(travel)
			var right_free := _side_free_scale(body, navigation_map, entry, corner, exit, travel_right, width, safe_drop, exclusion)
			var left_free := _side_free_scale(body, navigation_map, entry, corner, exit, -travel_right, width, safe_drop, exclusion)
			if right_free <= 0.0 and left_free <= 0.0:
				preferred = corner_right_vector(direction_in, direction_out, fallback_direction)
			else:
				preferred = travel_right if right_free >= left_free else -travel_right
		else:
			var corner_right := corner_right_vector(direction_in, direction_out, fallback_direction)
			preferred = corner_right if cross_z > 0.0 else -corner_right
		if preferred.is_zero_approx():
			preferred = corner_right_vector(direction_in, direction_out, fallback_direction)
		# APS :1477 Control = Corner + PreferredBaseSide * LaneSign * DesiredWidth；
		# lane_offset 同时是这个项目的车道偏移与「外鼓」来源，默认 0 时 Control == Corner。
		var control := corner + preferred * (lane * corner_strength)
		# APS :1479-1482 采样数随强度插值；仅在 AP S 模式（弧形/车道生效）下启用，
		# 只开 corner_rounding 时沿用移植前的固定采样参数，保证默认配置行为不变（适配 4）。
		var aps_mode := absf(float(values.get("arc_strength", 0.0))) >= ARC_MIN_STRENGTH or absf(lane) > 0.01
		var samples := detail if not aps_mode else clampi(roundi(lerpf(float(MIN_FILLET_SAMPLES), float(detail), corner_strength)), MIN_FILLET_SAMPLES, detail)
		# 回退 F（点预算，:1484-1489）
		if out.size() + samples + 3 > FILLET_CAP:
			_append(out, corner)
			tail = out[out.size() - 1]
			continue
		# 生成候选：圆角采样只做**一级**（投影 + 真实落脚）——这与 APS 一致（原实现根本
		# 不验证圆角输出），完整身体通道由流水线末尾的整条终检统一复检；终检失败则按 APS
		# 语义整条退回基准路径。此前每个采样点都跑一次 ground_segment，是单次规划耗时
		# 偏高的主要来源（24 体持续追击时把帧预算打满）。
		var rollback := out.size()
		var chain := tail
		var accepted := true
		var candidate_points := PackedVector3Array([entry])
		for sample in range(1, samples + 1):
			var u := float(sample) / float(samples + 1)
			var one_minus := 1.0 - u
			candidate_points.append(entry * one_minus * one_minus + control * 2.0 * one_minus * u + exit * u * u)
		candidate_points.append(exit)
		for candidate: Vector3 in candidate_points:
			var ground := ground_at(body, navigation_map, candidate, exclusion)
			if ground.is_empty():
				accepted = false
				break
			_append(out, ground.point)
			chain = ground.point
		if not accepted or out.size() == rollback:
			out.resize(rollback)
			_append(out, corner)
			tail = out[out.size() - 1]
			continue
		tail = chain
		has_accepted = true
		last_accepted_distance = corner_distance
		last_accepted_score = final_event_score
		_count("corners_rounded")
	_append(out, points[count - 1])
	return out

static func _resolve_travel_direction(primary: Vector3, secondary: Vector3, direction_in: Vector3, direction_out: Vector3) -> Vector3:
	## APS ResolvePreferredDir2D（:1196-1212）：Primary -> Secondary -> DirIn/DirOut -> Zero。
	var resolved := direction_2d(Vector3.ZERO, primary)
	if not resolved.is_zero_approx():
		return resolved
	resolved = direction_2d(Vector3.ZERO, secondary)
	if not resolved.is_zero_approx():
		return resolved
	resolved = direction_in + direction_out
	resolved.y = 0.0
	return resolved.normalized() if resolved.length() > 0.000001 else Vector3.ZERO

static func _side_free_scale(body: CharacterBody3D, navigation_map: RID, entry: Vector3, corner: Vector3, exit: Vector3, side: Vector3, width: float, safe_drop: float, exclusion: Array[RID]) -> float:
	## APS EvaluateSideFreeScale（:1432-1452）：8 档相对缩幅内找首个两侧都能通过的档位。
	if width <= 0.000001 or side.is_zero_approx():
		return 0.0
	for scale: float in OFFSET_SCALES:
		_count("candidates")
		var control := corner + side * width * scale
		var control_ground := ground_at(body, navigation_map, control, exclusion)
		if control_ground.is_empty():
			continue
		if not _chain_ok(body, entry, control_ground.point, safe_drop, exclusion):
			continue
		if not _chain_ok(body, control_ground.point, exit, safe_drop, exclusion):
			continue
		return scale
	return 0.0

# ───────────────────────────────────────────────────────────── 重采样阶段

static func resample_stage(body: CharacterBody3D, navigation_map: RID, points: PackedVector3Array, safe_drop: float, exclusion: Array[RID], values: Dictionary) -> PackedVector3Array:
	## APS BuildArcSamplingPath（:907-986）+ 本项目的一级/二级验证。
	var midpoints := int(values.get("arc_num_midpoints", 3))
	if points.size() < 2 or midpoints <= 0:
		return points
	var measured := cumulative_distances(points)
	if float(measured.total) < 0.000001:
		return points
	var segment := float(values.get("arc_resample_length", TARGET_ARC_SEGMENT_LENGTH))
	var cap := int(values.get("shape_max_points", RESAMPLE_CAP))
	var desired := resample_count(float(measured.total), midpoints, points.size(), cap, segment)
	if desired == points.size():
		return points
	var sampled := resample(points, desired)
	if sampled.size() < 2:
		return points
	# APS :949 / :985 精确保留首末点（不重新投影，端点由调用方保证）；中间点补一二级
	# 验证，任一点失败就放弃重采样（保守回退），残余风险交给终检。
	var verified := PackedVector3Array([sampled[0]])
	var tail := sampled[0]
	for index in range(1, sampled.size() - 1):
		var ground := ground_at(body, navigation_map, sampled[index], exclusion)
		if ground.is_empty() or not _chain_ok(body, tail, ground.point, safe_drop, exclusion):
			return points
		verified.append(ground.point)
		tail = ground.point
	verified.append(sampled[sampled.size() - 1])
	last_stats["resampled"] = verified.size()
	return verified

# ───────────────────────────────────────────────────────────── 形变阶段

static func warp_stage(body: CharacterBody3D, navigation_map: RID, points: PackedVector3Array, safe_drop: float, exclusion: Array[RID], values: Dictionary) -> PackedVector3Array:
	## APS WarpPathToArc（:2869-3345）的形变与逐点回退链。
	var count := points.size()
	var strength := float(values.get("arc_strength", 0.0))
	var lane := float(values.get("lane_offset", 0.0))
	var arc_on := absf(strength) >= ARC_MIN_STRENGTH
	var lane_on := absf(lane) > 0.01
	if not arc_on and not lane_on:
		return points
	var measured := cumulative_distances(points)
	var cumulative: PackedFloat32Array = measured.cumulative
	var total: float = measured.total
	if total < 0.000001:
		return points
	var midpoints := int(values.get("arc_num_midpoints", 3))
	var mode := String(values.get("arc_mode", "smooth"))
	var min_distance := float(values.get("arc_min_distance", 3.0))
	var global_side := 1.0 if strength >= 0.0 else -1.0
	var amplitude := base_amp(total, strength) if arc_on else 0.0
	if arc_on and flat_distance(points[0], points[count - 1]) < min_distance:
		return points
	if arc_on and amplitude <= 0.000001:
		return points
	var min_relative: float = amplitude * float(OFFSET_SCALES[OFFSET_SCALES.size() - 1])
	var sparse := bool(values.get("arc_sparse_warp", true)) and count > SPARSE_WARP_MIN_POINTS and absf(strength) < SPARSE_WARP_MAX_STRENGTH
	var lane_sign := 1.0 if lane >= 0.0 else -1.0
	var warped := points.duplicate()
	var tail: Vector3 = warped[0]
	var changed := false
	for index in range(1, count - 1):
		if sparse and (index & 1) == 0:
			continue
		var base_point := points[index]
		var t: float = cumulative[index] / total
		if t <= 0.0 or t >= 1.0:
			continue
		var tangent := direction_2d(points[index - 1], points[index + 1])
		if tangent.is_zero_approx():
			continue
		var right := right_of(tangent)
		var offset := Vector3.ZERO
		var arc_direction := Vector3.ZERO
		if arc_on:
			var envelope := arc_shape(t, midpoints, mode)
			if envelope <= 0.0:
				continue
			var side := local_side_sign(t, midpoints, mode, global_side)
			arc_direction = right * (side * envelope)
			offset += arc_direction * amplitude
		if lane_on:
			# APS 转角车道偏移（:3030-3054）：车道偏移只作用在真实转角上，按转角强度加权。
			var direction_in := direction_2d(points[index - 1], points[index])
			var direction_out := direction_2d(points[index], points[index + 1])
			var corner_strength := clampf(1.0 - direction_in.dot(direction_out), 0.0, 1.0)
			var cross_z := direction_in.x * direction_out.z - direction_in.z * direction_out.x
			var lane_direction := right
			if corner_strength > 0.0 and absf(cross_z) > 0.000001:
				var corner_right := corner_right_vector(direction_in, direction_out, tangent)
				lane_direction = corner_right if cross_z > 0.0 else -corner_right
			offset += lane_direction * (lane * maxf(corner_strength, 0.05))
		if offset.is_zero_approx():
			continue
		var accepted := false
		for scale: float in OFFSET_SCALES:
			_count("candidates")
			var ground := ground_at(body, navigation_map, base_point + offset * scale, exclusion)
			if ground.is_empty():
				continue
			if not _chain_ok(body, tail, ground.point, safe_drop, exclusion):
				continue
			if not _chain_ok(body, ground.point, points[index + 1], safe_drop, exclusion):
				continue
			warped[index] = ground.point
			tail = ground.point
			accepted = true
			changed = true
			_bump_scale(scale)
			break
		if accepted or not arc_on:
			continue
		# 绝对宽度回退（:3232-3319）：弧形换成固定宽度，车道偏移保持全幅。
		for amount: float in ABS_FALLBACK_AMPS:
			if amount >= min_relative:
				continue
			_count("candidates")
			_count("absolute_candidates")
			var rebuilt := base_point + arc_direction * amount + offset - arc_direction * amplitude
			var ground := ground_at(body, navigation_map, rebuilt, exclusion)
			if ground.is_empty():
				continue
			if not _chain_ok(body, tail, ground.point, safe_drop, exclusion):
				continue
			if not _chain_ok(body, ground.point, points[index + 1], safe_drop, exclusion):
				continue
			warped[index] = ground.point
			tail = ground.point
			accepted = true
			changed = true
			_bump_scale(-amount)
			break
		# 最终回退：该点保持基准点（:3320-3333）。
	last_stats["warped_points"] = count_shaped(warped, points)
	return warped if changed else points

static func _bump_scale(scale: float) -> void:
	var hits: Dictionary = last_stats.get("scale_hits", {})
	var key := str(snappedf(scale, 0.001))
	hits[key] = int(hits.get(key, 0)) + 1
	last_stats["scale_hits"] = hits

static func count_shaped(candidate: PackedVector3Array, reference: PackedVector3Array) -> int:
	var moved := 0
	for index in range(mini(candidate.size(), reference.size())):
		if candidate[index].distance_to(reference[index]) > 0.001:
			moved += 1
	return moved

# ───────────────────────────────────────────────────────────── 终检与总入口

static func final_gate(body: CharacterBody3D, points: PackedVector3Array, safe_drop: float, exclusion: Array[RID]) -> bool:
	## APS ValidatePathOnNavMesh（:870-894）：整条路径逐段复检。
	if points.size() < 2:
		return true
	for index in range(1, points.size()):
		if not _chain_ok(body, points[index - 1], points[index], safe_drop, exclusion):
			return false
	return true

static func shape(body: CharacterBody3D, navigation_map: RID, base: PackedVector3Array, safe_drop: float, exclude: Array[RID], values: Dictionary) -> PackedVector3Array:
	## 移植后的总入口：fillet -> resample -> warp -> validate -> final_gate。
	last_stats = {"input_points": base.size(), "output_points": base.size(), "level1_queries": 0, "level2_queries": 0,
		"level2_segments": 0, "corners": 0, "corners_rounded": 0, "candidates": 0, "absolute_candidates": 0,
		"scale_hits": {}, "resampled": 0, "warped_points": 0, "final_gate_failures": 0, "stage": "bypassed"}
	if base.size() < 3:
		return base
	var low := base[0].y
	var high := low
	for point in base:
		low = minf(low, point.y)
		high = maxf(high, point.y)
	# 坡板 / 台阶优先保持已验通过的落脚线；平滑不得改变空间能力的进出口（既有硬约束）。
	if high - low > 0.5:
		return base
	last_stats["stage"] = "shaping"
	var shaped := fillet_stage(body, navigation_map, base, safe_drop, exclude, values)
	shaped = resample_stage(body, navigation_map, shaped, safe_drop, exclude, values)
	shaped = warp_stage(body, navigation_map, shaped, safe_drop, exclude, values)
	if shaped.is_empty() or shaped.size() < 2:
		return base
	if bool(values.get("shape_final_gate", true)) and not final_gate(body, shaped, safe_drop, exclude):
		# APS :3336-3344：终检失败则连圆角一起丢弃，回到未加工的基准路径。
		last_stats["final_gate_failures"] = int(last_stats["final_gate_failures"]) + 1
		last_stats["stage"] = "final_gate_rejected"
		last_stats["output_points"] = base.size()
		return base
	last_stats["output_points"] = shaped.size()
	last_stats["stage"] = "shaped"
	return shaped
