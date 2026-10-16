extends RefCounted
## 同心环锚点（用户 2026-10-11 提出的「铁圈」模型）。
##
## 目标身上挂一组同心圆环 R_1 < R_2 < ... < R_n，每环有自己的圆心 A_k：
##
## - **链条传导**：目标只直接拖动第 1 环，第 k 环由第 k-1 环拖动 —— 「内圈碰到外圈才带动外圈」。
##   每一环只沿圆心连线移动**超出的那一段**：目标在一圈里移动时该圈纹丝不动，只有一直走到
##   边缘继续往外，才把这一圈拖着跑。阈值就是环间距 T_k = R_k - R_(k-1)，越外圈越钝。
## - **第 1 环是基础过滤器**：它的任务是把玩家的小范围晃动滤掉（拖动阈值 = R_1）。
##   追击者只要**进入第 1 环**（到 A_1 的距离 ≤ R_1）就转精确追击：对着玩家当前位置做
##   接战站位 / 跳跃 / 攀爬 / 破障规划。
## - 追击者还没进第 1 环时，按「自己越过几环」逐级向内：越过越少说明越近。
##
## 每帧只做 O(环数) 次距离比较，**不做任何路径查询**；圆心只在被拖动时更新。
##
## 拖动后的新圆心必须通过真实地面复核（accept），因此圆心不会落到空中或穿进实体；
## 追击者的实际目标点另外取自**目标真实走过的轨迹**，天然落在导航面上、天然连通。
##
## 单元对照见 tests/test_navigation_ring_goal.gd；接入点见 combat_spatial_controller.gd。

## 目标一帧内移动超过这个距离视为「不连续变化」（点击设置目标、传送、切场景）：
## 所有环立刻重新落在目标身上、旧轨迹作废，追击者必须马上改目标而不是走完旧路线。
const JUMP_DISTANCE := 3.0

## 换环迟滞：向内换环（进入更精确的目标）要求在收缩 10% 的半径以内，
## 避免个体停在环边界上反复换来换去。向外换环仍按真实半径。
const HYSTERESIS := 0.1

## 环半径 m（递增）。配置时过滤掉非正与不递增的值。
var radii := PackedFloat32Array()
## 每环圆心，与 radii 同长。第 1 环的圆心只在目标走到它边缘时才被拖着走。
var anchor_points: Array[Vector3] = []
## 每环被拖动的累计次数（观测；记「开始被拖动」的次数，不是帧数）。
var drags: Array[int] = []
## 每环当前是否正处于「被拖动」状态（用来把次数记成次数而不是帧数）。
var pushing: Array[bool] = []
## 拖动方式：
## - "snap"（弹开）：越过边缘就把本环圆心跳到内圈位置。位置永远是内圈站过的点。
## - "smooth"（平滑）：只沿连线移动超出的那一段，圆心贴着边缘滑行；新位置不可站时退回弹开。
var drag_mode := "snap"
## 目标最近真实停留过的位置（环形缓冲，所有追击者共享）。
## 追击者的环带目标只从这里挑：不在目标轨迹上的几何点无法保证落在导航面上、也无法保证连通。
var trail: Array[Vector3] = []
## 轨迹采样：每 trail_frame_step 个物理帧采一次，点间距不足 trail_min_spacing 就不采。
var trail_frame_step := 10
var trail_min_spacing := 0.4
var trail_limit := 120
## 观测：轨迹长度峰值。
var trail_peak := 0
## 锚点被拖动的总次数（观测）。
var drag_events := 0
## 真正执行过同步的物理帧数（观测）。
var sync_frames := 0
## 每环「内圈圆心到本环圆心」见过的最大距离（观测）：用来判断阈值是不是设得太大、
## 根本没机会拖动。第 1 环的「内圈」就是目标本身。
var gap_max: Array[float] = []

## 最近一次同步到的目标位置（观测 / 绘制用）。
var last_target := Vector3.ZERO
## 目标不连续移动的计数：每跳一次 +1，追击者据此立刻丢弃旧路线并重算。
var jump_revision := 0
## 持有目标的弱引用，供控制器清理已释放目标的环状态。
var target_ref: WeakRef
var _frame := -1

func configure(ring_radii: PackedFloat32Array) -> void:
	var clean := PackedFloat32Array()
	for value in ring_radii:
		if value > 0.0 and (clean.is_empty() or value > clean[clean.size() - 1]):
			clean.append(value)
	radii = clean
	while anchor_points.size() < radii.size():
		anchor_points.append(Vector3.ZERO)
		drags.append(0)
		gap_max.append(0.0)
		pushing.append(false)
	if anchor_points.size() > radii.size():
		anchor_points.resize(radii.size())
		drags.resize(radii.size())
		gap_max.resize(radii.size())
		pushing.resize(radii.size())

## 至少要两环才有意义：一环保精确，外环才有锚点。
func configured() -> bool:
	return radii.size() >= 2

func reset() -> void:
	for index in range(anchor_points.size()):
		anchor_points[index] = Vector3.ZERO
		drags[index] = 0
		gap_max[index] = 0.0
		pushing[index] = false
	drag_events = 0
	sync_frames = 0
	trail_peak = 0
	trail.clear()
	_frame = -1

## 每物理帧最多同步一次。accept 用来复核新圆心是不是真实地面；不合格就不拖，保持旧圆心。
##
## 拖动的关键是「**只动被碰到的那个圈**」：每一环都直接用目标来判断 —— 目标离开第 k 环圆心
## 超过阈值 T_k = R_k - R_(k-1)（第 1 环的阈值 = R_1）时才动它，**一个圈动了不会带着外圈一起动**。
## 外圈只有在目标自己也越过了它的边界时才会动，所以一次推动通常只动相邻的那一个，
## 外层圆心几乎不动，过滤更彻底。
##
## 第 1 环的阈值就是 R_1：目标在一圈里自由移动时该圈纹丝不动，只有走到边缘继续往外才被拖动。
## 目标离开任何一环都不会超过 T_k ≤ R_k，所以「目标永远在自己所有环的内部」始终成立。
func sync(target: Vector3, accept: Callable, frame: int) -> void:
	if frame == _frame:
		return
	_frame = frame
	var previous_target := last_target
	last_target = target
	sync_frames += 1
	if not previous_target.is_zero_approx() and previous_target.distance_to(target) > JUMP_DISTANCE:
		# 点击设点 / 传送：**不重绘所有圆**，而是走与平时完全相同的拖动规则 —— 第 1 环的阈值
		# 就是 R_1，外圈只有被推过自己的边界才会动。这里只记一次「不连续移动」，让追击者
		# 立刻丢掉旧路线改目标；圆动不动由下面的 _drag_ring 按阈值判断。
		jump_revision += 1
	# 目标轨迹采样：只在目标真实站在地面上时记点（accept 由调用方给）。
	if frame % trail_frame_step == 0 and (accept.is_valid() == false or bool(accept.call(target))):
		if trail.is_empty() or trail[trail.size() - 1].distance_to(target) >= trail_min_spacing:
			trail.append(target)
			if trail.size() > trail_limit:
				trail.remove_at(0)
			trail_peak = maxi(trail_peak, trail.size())
	if not configured():
		return
	if anchor_points[0].is_zero_approx():
		for index in range(radii.size()):
			anchor_points[index] = target
		return
	# 每一环都只看「目标」：一个圈被拖动不会带动外圈（避免一次推动把所有圈一起弹开）。
	for index in range(radii.size()):
		var limit := radii[index] if index == 0 else radii[index] - radii[index - 1]
		_drag_ring(index, target, limit, accept)


## 第 index 环的拖动：目标离开本环圆心超过 limit 时才动本环；动不了外圈。
## 两种模式的共同点：没到边缘就一动不动。
## - snap（弹开）：直接跳到内圈位置（目标/内圈真正走过的地方）。
## - smooth（平滑）：只移动超出的那一段；新位置不是真实地面时退回弹开，避免卡在边缘不动。
func _drag_ring(index: int, inner: Vector3, limit: float, accept: Callable) -> void:
	var offset := inner - anchor_points[index]
	var gap := offset.length()
	gap_max[index] = maxf(gap_max[index], gap)
	if gap <= limit:
		pushing[index] = false
		return
	var moved := inner
	if drag_mode == "smooth":
		moved = anchor_points[index] + offset / gap * (gap - limit)
		if accept.is_valid() and not bool(accept.call(moved)):
			moved = inner
	if accept.is_valid() and not bool(accept.call(moved)):
		return
	anchor_points[index] = moved
	if not pushing[index]:
		pushing[index] = true
		drags[index] += 1
		drag_events += 1

## 已经从外面越过了几环：0 = 已经进入第 1 环（这一环的任务就是基础过滤，进来就精确追击）。
## 每一环都按「这个位置到该环圆心的距离」判断，和环自己的圆心一致。
## 向内换环带迟滞，向外仍按真实半径。
func entered_rings(from: Vector3) -> int:
	var entered := 0
	for index in range(radii.size()):
		if from.distance_to(anchor_points[index]) > radii[index] * (1.0 - HYSTERESIS):
			entered = index + 1
	return entered

## 这个位置的环带档位。返回空字典 = 已经进入第 1 环，走精确追击。
##
## 越过 entered 环 ⇒ 下一个目标是「进入第 entered 环」⇒ 目标取该环圆心作为兜底，
## 真正的目标点由 region_goal() 从目标轨迹里挑（环带区域，不要求落在圆心上）。
func pursuit(from: Vector3) -> Dictionary:
	if not configured():
		return {}
	var entered := entered_rings(from)
	if entered < 1:
		return {}
	return {"point": anchor_points[entered - 1], "ring": entered}


## 该档位的环带候选点，按几何评分排序（离追击者近 + 靠近环带中线），最多 limit 个。
## 追击者拿到候选后可以自己再按「能不能直着走过去」挑最佳落点。
func region_candidates(entered: int, from: Vector3, limit: int) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if not configured() or entered < 1 or limit <= 0:
		return result
	var ring := mini(entered, radii.size())
	var inner := 0.0 if ring <= 1 else radii[ring - 2]
	var outer := radii[ring - 1]
	var middle := (inner + outer) * 0.5
	var centre: Vector3 = anchor_points[ring - 1]
	var scored: Array = []
	for point in trail:
		var gap := point.distance_to(centre)
		if gap < inner or gap > outer:
			continue
		scored.append({"point": point, "score": from.distance_to(point) + absf(gap - middle) * 0.5})
	if scored.is_empty():
		return result
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.score) < float(b.score))
	for item: Dictionary in scored:
		if result.size() >= limit:
			break
		result.append(item.point)
	return result


## 给「还没进第 entered 环」的追击者挑一个目标点：目标是**进入第 entered 环**（圆心 A_entered）。
##
## 只在目标真实走过的位置里挑（连通性免费，不需要任何路径查询）：
## - 只取到目标当前距离落在该环带 (R_(entered-1), R_entered] 内的点，避免落在圈边缘；
## - 偏好靠近环带中线的点（中点 = (内半径 + 外半径) / 2）；
## - 同一带里优先离这个追击者近的点：每个追击者各挑各的，不要求统一。
## 返回零向量表示没有合格候选（例如目标刚开始移动、轨迹还没铺开）。
func region_goal(entered: int, from: Vector3) -> Vector3:
	if not configured() or entered < 1:
		return Vector3.ZERO
	var ring := mini(entered, radii.size())
	var inner := 0.0 if ring <= 1 else radii[ring - 2]
	var outer := radii[ring - 1]
	var middle := (inner + outer) * 0.5
	var best := Vector3.ZERO
	var best_score := INF
	var centre: Vector3 = anchor_points[ring - 1]
	for point in trail:
		var gap := point.distance_to(centre)
		if gap < inner or gap > outer:
			continue
		var score := from.distance_to(point) + absf(gap - middle) * 0.5
		if score < best_score:
			best_score = score
			best = point
	return best

## 第 ring 环（1 起）的圆心。
func point_for(ring: int) -> Vector3:
	if ring < 1 or ring > anchor_points.size():
		return Vector3.ZERO
	return anchor_points[ring - 1]

## 第 ring 环的半径（1 起）。
func radius_for(ring: int) -> float:
	if ring < 1 or ring > radii.size():
		return 0.0
	return radii[ring - 1]

## 第 ring 环的拖动阈值 T_k = R_k - R_(k-1)。
func threshold_for(ring: int) -> float:
	if ring < 2 or ring > radii.size():
		return 0.0
	return radii[ring - 1] - radii[ring - 2]
