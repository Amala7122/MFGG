extends RefCounted
const CpuAudit := preload("res://scripts/enemy_cpu_audit.gd")
## 可赋予的空间决策与动作调度；没有敌人种类分支。
const Profile := preload("res://scripts/combat_spatial_profile.gd")
const Capability := preload("res://scripts/traversal_capability.gd")
const Query := preload("res://scripts/spatial_query.gd")
const Planner := preload("res://scripts/spatial_route_planner.gd")
const RetreatPlanner := preload("res://scripts/spatial_retreat_planner.gd")
const SurfaceTraversal := preload("res://scripts/surface_traversal.gd")
const Ground := preload("res://scripts/ground_movement.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
const RingAnchors := preload("res://scripts/nav_ring_anchors.gd")
const INSTANCE := &"combat_spatial_controller"
const FRAME_BUDGET_USEC := 2200
## 目标持续移动时的连续瞄准：只在这个距离内把过期路点换成“当前目标”。
const LIVE_AIM_DISTANCE := 6.0
## 本地身体探测的重估间隔（秒）。0.08 秒内沿用的结论最多差 0.4 米（走速 5 m/s）。
const LIVE_AIM_PERIOD := 0.08
## 改瞄容差角：超过这个夹角说明目标已经折返，保持规划器给的路点。
const LIVE_AIM_CONE_DEG := 75.0
## 远处粗略目标（LOD）：目标在 PRECISE_DISTANCE 内才用精确目标（玩家脚下），
## 更远只给「沿导航路径朝目标前进 band 米」的一个真实落脚点。
##
## **默认关闭**：主场景曾有个体陷入 status=checking、route 为空、travelled≈0 的循环
## （种子 314159 的 N02/N04/N05）。根因已定位：`_publish_route` 用
## 「目标到现在这个粗略点的距离 > 重画阈值 × 2」判过期，而粗略点离目标本来就有
## (距离 - band) 米，超过 21 米的个体**每次结果都被作废**，于是永远没有路线。
## 现在 band > 0 的计划不再用目标位置判过期（改由档位变化与路线走完驱动），
## 但该分支仍保持默认关闭，等同心环目标一并做过对照再评估。
static var coarse_goal_enabled := false
## 同心环目标（用户 2026-10-11 的「铁圈」模型）：见 scripts/nav_ring_anchors.gd。
## 远处的目标点不再是「目标的当前位置」，而是被拖动过一次才动的环圆心，
## 于是目标的小幅移动不再让远处个体整段重画路线。**默认关闭**。
static var ring_goal_enabled := false
## 环半径 m（递增）。第 1 环以内 = 精确目标；第 k 环圆心拖动阈值 = 相邻半径之差。
## 默认环半径 m（递增）。第 1 环是基础过滤器：拖动阈值就是 R_1，追击者进到第 1 环里
## 才转精确追击；因此 R_1 不宜太大（2R_1 是「多早开始精确」的上界）。
static var ring_radii := PackedFloat32Array([6.0, 16.0, 40.0, 90.0])
## 观测：锚点被拖动次数 / 换环次数（验收用）。
static var ring_drag_events := 0
static var ring_switch_events := 0
## 观测：用环目标的规划请求数 / 因不同层回落精确目标的请求数 / 在最内环内的请求数。
static var ring_used := 0
static var ring_level_blocked := 0
static var ring_precise_zone := 0
## 环拖动方式："snap" = 弹开（越过边缘就跳到内圈位置，默认）；"smooth" = 平滑（沿边缘滑行）。
## 两种模式都不改变「目标在圈内移动时圈不动」这条。
static var ring_drag_mode := "snap"
## 观测：用到的最大环号 / 目标点来自环带轨迹的次数 / 回退共享环圆心的次数。
static var ring_entered_max := 0
static var ring_region_used := 0
static var ring_anchor_fallbacks := 0
## 观测：环带方案规划失败后改用环圆心的次数 / 进环落点里挑中「能直着走到」的次数。
static var band_fallbacks := 0
static var direct_band_goals := 0
## 环带方案失败后，改用「该环圆心」多久（秒）。兜底不离开环模型：没进环的追击者
## 精确目标就是环，所以失败只会从漂移候选退成确定的圆心，不会去追玩家坐标。
const BAND_FALLBACK_SECONDS := 2.0
## 进环时最多比较几个落点来找「能直着走过去」的那个。
const BAND_DIRECT_CANDIDATES := 3
# ── 远处个体降频：远处的目标点本来就冻结，不需要每帧做全套身体查询 ──
## 距目标小于这个距离的个体每帧完整判定（近身精度不受影响）。
static var tick_throttle_min_distance := 25.0
## 每多出这么多米，tick 间隔 +1 帧（越远越稀；更大场景可以直接调大这个步长）。
static var tick_throttle_step := 25.0
## tick 间隔上限（帧）。1 = 关闭降频。
static var tick_throttle_max := 6
## 观测：完整判定帧数 / 降频帧数。
static var full_ticks := 0
static var throttled_ticks := 0
## 观测：所有模式下「规划未完成、原地等结果」的帧数（走停的直接量）。
static var stop_wait_frames := 0
## 环目标允许的垂直落差 m。**0 = 不设限（默认）**：圈层之间是解耦的 —— 追击者没进环就只该
## 奔向环，跨层由规划器的完整身体通道 + 能力（跳跃 / 攀爬 / 破障）验证，失败还有精确目标兜底。
## 大于 0 时才会启用这个旧的门（它来自加入圈组之前的粗略点版本，那时目标是沿路径取的合成点，
## 跨层会直接取不到落脚点；环带的锚点是目标站过的位置，不存在这个问题）。
static var ring_level_tolerance := 0.0
## 每个目标一份环状态（所有敌人共享同一组锚点），键是目标 instance_id。
static var _rings: Dictionary = {}
const PRECISE_DISTANCE := 15.0
const COARSE_FAR_DISTANCE := 30.0
const COARSE_BAND_FAR := 15.0
const COARSE_BAND_MID := 9.0
## 接战候选（5 圈 × 8 方位）只在这个距离内生成：远处生成等于白算。
const ATTACK_PLAN_DISTANCE := 8.0
# ── 动作窗口：跳跃 / 攀爬 / 破障 / 自定义动作期间退出规划，结束后错峰恢复 ──
## 每物理帧最多允许多少个个体开始新的整段规划（避免同帧齐发把队列打满）。
const PLAN_STARTS_PER_FRAME := 2
## 动作结束后恢复规划的基础延迟与按个体打散的步长（秒）。
const RESUME_STAGGER_BASE := 0.05
const RESUME_STAGGER_STEP := 0.03
const RESUME_STAGGER_SLOTS := 8
## 同帧超过配额时，被推迟的个体过多久重试。
const PLAN_DEFER_RETRY := 0.05
static var _plan_frame := -1
static var _plan_starts := 0
## 观测：因配额被推迟的规划请求次数。
static var plan_deferrals := 0
static var _jobs: Array[WeakRef] = []
static var _job_frame := -1
static var last_job_usec := 0
## 性能观测：启动过的规划任务数、本地探测次数与累计耗时（测试用它做开销对照）。
static var jobs_started := 0
static var live_probe_calls := 0
static var live_probe_usec := 0
## 动态改线开关：目标持续移动时，最后一段允许朝“当前目标”连续修正瞄准点。
## 默认开启；测试用它做同一场景的对照（见 tests/test_navigation_live_aim.gd）。
static var live_aim_enabled := true
var profile: Profile
var capabilities: Array[Resource] = []
var status := "approach"
var last_failure := ""
var last_action := ""
var route: Dictionary = {}
var escape_reserved: StringName
var _body: CharacterBody3D
var _navigation: RefCounted
var _bindings: Dictionary = {}
var _cooldowns: Dictionary = {}
var _target: Node3D
var _goal_sample := Vector3.ZERO
## 本次规划用的档位（0 = 精确目标）与目标点是否精确。
var _plan_band := 0.0
## 本次带档位计划用的那个锚点（精确目标时为零）。锚点没被拖动就不必为同一个档位重画。
var _goal_anchor := Vector3.ZERO
## 本帧与目标是否同层：不同层（平台/坑/坡）一律用精确目标，粗略目标只用于同层远距离追击。
var _same_level := false
## 本帧脚下与目标支撑面的垂直落差（任一侧没有真实支撑时为 -1 = 未知）。
var _level_gap := -1.0
## 本个体已经处理到的「目标不连续移动」计数：变了就说明目标被瞬移/点击设置过，
## 必须立刻丢掉旧路线改目标。
var _ring_jump_revision := -1
## 本帧是否检测到目标瞬移（在 tick 开头算一次，完整判定里复用）。
var _jumped_this_frame := false
## 环带方案失败后的回落计时：>0 期间改用「该环圆心」这个确定的环内点。
## 不回落玩家精确坐标：没进环的追击者的精确目标就是环。
var _band_centre_timer := 0.0
## 动作窗口内为真：跳跃 / 攀爬 / 破障 / 自定义动作期间不参与规划。
var _planning_suspended := false
var _timer := 0.0
var _job: RefCounted
var _revision := -1
var _nav_revision := -1
var _segment_index := 0
var _point_index := 1
var _active: Dictionary = {}
var _elapsed := 0.0
var _started := false
var _saved_motion_mode := 0
var _saved_up := Vector3.UP
var _exit_anchor := Vector3.ZERO
var _has_exit_anchor := false
var _escape: Dictionary = {}
var _retreat_goal := Vector3.ZERO
var _retreat_route: Dictionary = {}
var _retreat_timer := 0.0
var _route_target: Node3D
var _gravity := 20.0
var _attached: Dictionary = {}
var _last_ground := Vector3.ZERO
var _has_last_ground := false
var _attack_sample: Dictionary = {}
var _attack_timer := 0.0
var _exit_check_timer := 0.0
var _progress_clock := 0.0
var _progress_point := Vector3.ZERO
var _job_kind := "route"
var _retreat_revision := -1
var _rim_anchor := Vector3.ZERO
var _rim_target := Vector3.ZERO
var _has_rim_anchor := false
var _rim_expose := false
var _rim_dwell := -1.0
var _rim_check := 0.0
var _entry_takeoff := Vector3.ZERO
var _rim_detected := false
var recovery_count := 0
var _direct_ground_proof: Dictionary = {}
## 目标持续移动时的连续瞄准状态（每隔 LIVE_AIM_PERIOD 重估一次本地探测）。
var _live_aim_ok := false
var _live_aim_timer := 0.0
## 本帧是否已判定为连续追击（tick 里算一次，adjust_ground_motion 直接复用）。
var _pursuit_active := false
## 同心环锚点的落地复核查询（拖锚点时才调用）。
var _ring_accept: Callable

func setup(body: CharacterBody3D, assigned: Profile, navigation: RefCounted) -> void:
	_body = body
	profile = assigned
	_navigation = navigation
	_body.set_meta(INSTANCE, self)
	_body.tree_exiting.connect(dispose)
	_ring_accept = _ring_anchor_valid
	bind({})

func bind(values: Dictionary, callbacks: Dictionary = {}) -> void:
	_bindings = callbacks
	_gravity = float(values.get("gravity", 20.0))
	capabilities.clear()
	for capability: Resource in profile.capabilities:
		if capability != null and capability.enabled:
			var resolved: Resource = capability.resolved(values)
			if resolved.enabled:
				capabilities.append(resolved)
	_timer = 0.0

func ability(id: StringName) -> Resource:
	for item in capabilities:
		if item.id == id:
			return item
	return null

func remaining(id: StringName) -> float:
	var item := ability(id)
	var channel: StringName = item.cooldown_channel if item != null and not item.cooldown_channel.is_empty() else id
	var value := float(_cooldowns.get(channel, 0.0))
	if _bindings.has("remaining"):
		value = maxf(value, float((_bindings.remaining as Callable).call(channel)))
	return value

func permits_channel(channel: StringName) -> bool:
	if escape_reserved.is_empty():
		return true
	var reserved := ability(escape_reserved)
	return reserved == null or (reserved.cooldown_channel if not reserved.cooldown_channel.is_empty() else reserved.id) != channel

func _consume(item: Resource) -> void:
	var channel: StringName = item.cooldown_channel if not item.cooldown_channel.is_empty() else item.id
	_cooldowns[channel] = float(item.cooldown)
	if _bindings.has("consume"):
		(_bindings.consume as Callable).call(channel, float(item.cooldown))

func _nav_map() -> RID:
	return _navigation._agent.get_navigation_map() if is_instance_valid(_navigation._agent) else RID()

func _planner(destination: Node3D, goal_point: Vector3, precise: bool) -> RefCounted:
	var availability := {}
	for item in capabilities:
		availability[item.id] = remaining(item.id)
	var job := Planner.new()
	# 覆盖参数必须在 begin() 之前设置：规划器只在 begin() 内读取它们（I-082）。
	# 放在 begin() 之后会被静默忽略——环带目标与粗略目标的搜索目标曾因此从未生效。
	if not precise:
		# 远处粗略目标：规划只负责「朝目标方向走到那个落脚点」，不铺到玩家脚下。
		job.goal_override = goal_point
		job.has_goal_override = true
	job.begin(_body, profile, capabilities, _nav_map(), destination, availability)
	if precise:
		# 接战候选（5 圈 × 8 方位）必须在精确目标时都生成：实测把它限制在 8 米内会让
		# 接战链的最长连续零速从 104~133 帧涨到 293~301 帧（敌人找不到可攻击站位，来回摆）。
		# 它依赖 begin() 已设好的 body / target，因此必须留在 begin() 之后。
		job.set_attack_goal(_bindings.get("attack_pose", Callable()), _bindings.get("stance_radii", []))
	job.landing_allowed = _route_landing_allowed
	return job


## ── 同心环目标 ──────────────────────────────────────────────────────────
## 环状态按目标共享：所有敌人看到同一组锚点，每物理帧只同步一次。
static func ring_state(target: Node3D) -> RefCounted:
	if not is_instance_valid(target):
		return null
	var key := target.get_instance_id()
	var state: RefCounted = _rings.get(key)
	if state == null:
		state = RingAnchors.new()
		state.configure(ring_radii)
		state.target_ref = weakref(target)
		_rings[key] = state
	state.drag_mode = ring_drag_mode
	if state.radii != ring_radii:
		# 观察台改了半径：按新几何重新配置并重新起锚。
		state.configure(ring_radii)
		state.reset()
	if _rings.size() > 8:
		_prune_rings()
	return state

static func _prune_rings() -> void:
	for key in _rings.keys():
		var state: RefCounted = _rings[key]
		if state == null or state.target_ref == null or state.target_ref.get_ref() == null:
			_rings.erase(key)

## 测试与观察台用：清掉所有目标的环状态（换相位时保证锚点从头开始）。
static func reset_ring_goals() -> void:
	_rings.clear()
	ring_drag_events = 0
	ring_switch_events = 0
	ring_used = 0
	ring_level_blocked = 0
	ring_precise_zone = 0
	full_ticks = 0
	throttled_ticks = 0
	ring_entered_max = 0
	ring_region_used = 0
	ring_anchor_fallbacks = 0
	band_fallbacks = 0
	stop_wait_frames = 0

## 观察台绘制用：每个目标的每环圆心、半径与被拖动次数。
static func ring_debug_rows(target: Node3D) -> Array:
	if not is_instance_valid(target):
		return []
	var state: RefCounted = _rings.get(target.get_instance_id())
	if state == null:
		return []
	var rows: Array = []
	for index in range(state.radii.size()):
		rows.append({"ring": index + 1, "radius": state.radii[index],
			"anchor": state.anchor_points[index], "drags": state.drags[index]})
	return rows

## 锚点必须是这个身体能站的真实地面。目标站过的地方一般成立，
## 仍然复核一次，不合格就保持旧锚点（不允许锚点落到空中或穿模位置）。
func _ring_anchor_valid(point: Vector3) -> bool:
	if not is_instance_valid(_body):
		return false
	var hit := Query.floor_at(_body, point, maxf(0.6, float(profile.safe_drop) + 0.3))
	if hit.is_empty():
		return false
	return absf(float(hit.position.y) - point.y) <= float(profile.safe_drop) + 0.2

## 本帧该走的环目标；空字典 = 用精确目标。
func _ring_goal() -> Dictionary:
	if not ring_goal_enabled or not is_instance_valid(_target) or not is_instance_valid(_body):
		return {}
	var state := ring_state(_target)
	if state == null or not state.configured():
		return {}
	var before := int(state.drag_events)
	state.sync(_target.global_position, _ring_accept, Engine.get_physics_frames())
	ring_drag_events += int(state.drag_events) - before
	return state.pursuit(_body.global_position)

## 到目标的水平距离（档位判定与接战候选门槛共用）。
func _target_distance() -> float:
	if not is_instance_valid(_target) or not is_instance_valid(_body):
		return 0.0
	return Vector2(_target.global_position.x - _body.global_position.x,
		_target.global_position.z - _body.global_position.z).length()

func _walking(origin: Vector3, destination: Vector3, excluded: Array[RID] = []) -> Dictionary:
	var planner := Planner.new()
	planner.body = _body
	planner.profile = profile
	planner.capabilities = capabilities
	planner.navigation_map = _nav_map()
	return planner.walk_route(origin, destination, excluded)

func _request_route() -> void:
	if _job != null or not is_instance_valid(_target):
		return
	if _planning_suspended:
		return
	if not _admit_plan():
		# 同帧配额用完：过一小会重试，让同时结束动作的多个个体分批进入规划。
		plan_deferrals += 1
		_timer = PLAN_DEFER_RETRY
		return
	# 远处给粗略目标、近了才给精确目标：规划成本随路径长度下降，远处也不因目标移动而重画。
	var pursuit := _pursuit_goal()
	if ring_goal_enabled:
		if pursuit.band > 0.0:
			ring_used += 1
			ring_entered_max = maxi(ring_entered_max, int(pursuit.band))
		elif ring_level_tolerance > 0.0 and _level_gap > ring_level_tolerance:
			# 只有真的被层级门挡回才算；「已经在第 1 环里」按设计走精确追击，单独计。
			ring_level_blocked += 1
		else:
			ring_precise_zone += 1
	if ring_goal_enabled and pursuit.band > 0.0 and _plan_band > 0.0 and not is_equal_approx(pursuit.band, _plan_band):
		ring_switch_events += 1
	_goal_sample = pursuit.point
	_plan_band = pursuit.band
	_goal_anchor = pursuit.point if pursuit.band > 0.0 else Vector3.ZERO
	_job = _planner(_target, pursuit.point, pursuit.band <= 0.0)
	_job_kind = "route"
	_route_target = _target
	_revision = Destruction.geometry_revision
	var nav_map := _nav_map()
	_nav_revision = NavigationServer3D.map_get_iteration_id(nav_map) if nav_map.is_valid() else 0
	_jobs.append(weakref(self))
	jobs_started += 1
	status = "checking"

static func process_jobs() -> void:
	var _cpu_scope := CpuAudit.begin(&"spatial.jobs") if CpuAudit.enabled else null
	# 一次慢渲染帧可能补算8个物理步；异步规划预算只能花一次，不能跟着补8份。
	# 移动／碰撞／技能仍逐物理步执行，只有共享规划队列按渲染帧让出时间。
	var frame := Engine.get_process_frames()
	if _job_frame == frame:
		return
	_job_frame = frame
	var start := Time.get_ticks_usec()
	var count := _jobs.size()
	while count > 0 and not _jobs.is_empty() and Time.get_ticks_usec() - start < FRAME_BUDGET_USEC:
		count -= 1
		var reference: WeakRef = _jobs.pop_front()
		var owner: RefCounted = reference.get_ref()
		if owner == null or owner._job == null or not is_instance_valid(owner._body):
			continue
		owner._job.advance(mini(start + FRAME_BUDGET_USEC, Time.get_ticks_usec() + 700))
		if owner._job.done:
			owner._publish_route()
		else:
			_jobs.append(reference)
	last_job_usec = Time.get_ticks_usec() - start

func _publish_route() -> void:
	var job := _job
	_job = null
	if _job_kind == "retreat":
		_job_kind = "route"
		if _retreat_revision == Destruction.geometry_revision and is_instance_valid(_target) and job.target == _target and _target.global_position.distance_to(job.target_sample) <= float(profile.target_replan_distance):
			_retreat_route = job.result
			_rim_anchor = _retreat_route.get("rim_anchor", _rim_anchor)
			_rim_detected = true
			_retreat_timer = float(profile.retry_delay)
			_rim_dwell = -1.0
			last_failure = "no_safe_retreat" if _retreat_route.is_empty() else "" if bool(_retreat_route.get("safe", false)) else "still_exposed"
		else:
			_retreat_timer = 0.0
		return
	var nav_map := _nav_map()
	var nav_version := NavigationServer3D.map_get_iteration_id(nav_map) if nav_map.is_valid() else 0
	if not is_instance_valid(_body) or not is_instance_valid(_target) or _target != _route_target or _revision != Destruction.geometry_revision or nav_version != _nav_revision:
		last_failure = "publish_rejected"
		_timer = 0.0
		return
	# 这条过期判据只对精确目标成立（_goal_sample 就是目标位置）。粗略 / 环目标本来就放在
	# 离目标 (距离 - band) 米的地方，拿「目标到这个点的距离」判过期会让超过 21 米的个体
	# **每次结果都被作废**——那正是 LOD 版本停在 checking、route 永远为空、travelled≈0 的根因。
	# 带档位的计划改由「档位变化 / 路线快走完」驱动重画。
	if _plan_band <= 0.0 and _target.global_position.distance_to(_goal_sample) > _replan_distance() * 2.0:
		# 结果对应的目标点已经明显过时：作废并立刻重算。A/B 实测（tests/test_navigation_moving_target.gd）
		# 「不作废」会让接战链的最长连续零速从 83 帧升到 111 帧，所以保留作废。
		_timer = 0.0
		return
	route = job.result
	_direct_ground_proof.clear()
	# 直行凭据只给精确目标用：它的判据里有「目标没走远」，粗略 / 环目标天然离目标很远。
	if _plan_band <= 0.0 and not route.is_empty() and route.segments.size() == 1 and bool(route.segments[0].get("direct", false)):
		_direct_ground_proof = {"from": route.segments[0].points[0], "to": route.segments[0].landing,
			"target": _goal_sample, "owner": _target, "geometry": _revision, "navigation": _nav_revision,
			"dimensions": Query.dimensions(_body).duplicate()}
	_segment_index = 0
	_point_index = 1
	_timer = float(profile.replan_interval)
	if route.is_empty():
		if _plan_band > 0.0:
			# 兜底仍在环模型里：环带目标取自「目标走过的位置」，可能存在「目标能过、这个身体
			# 过不去」的地方（目标跳下的落差、目标能钻的缝）。失败后一段时间改用**该环圆心**
			# （确定的环内点）而不是漂移的轨迹候选 —— 精确兜底的目标依然是「进环」，不是玩家。
			_band_centre_timer = maxf(_band_centre_timer, BAND_FALLBACK_SECONDS * 3.0)
			band_fallbacks += 1
		status = "blocked"
		last_failure = "no_capability_route"
	else:
		_retreat_route.clear()
		_has_rim_anchor = false
		status = "approach"
		last_failure = ""

## 远处降频的 tick 间隔：1 = 每帧完整判定。
func _tick_stride() -> int:
	if not ring_goal_enabled or tick_throttle_max <= 1 or not is_instance_valid(_target) or not is_instance_valid(_body):
		return 1
	var distance := _body.global_position.distance_to(_target.global_position)
	var extra := int(floor((distance - tick_throttle_min_distance) / maxf(tick_throttle_step, 1.0)))
	return clampi(1 + extra, 1, tick_throttle_max)


## 这一帧能不能走便宜路径（只沿已发布路线走，不做身体查询与重画判定）。
## 只在「远处 + 有路线 + 状态简单」时成立；任何动作 / 逃逸 / 脱困 / 无路线都交回完整判定。
func _cheap_tick(delta: float, speed: float) -> bool:
	if _job != null or not _active.is_empty() or not _attached.is_empty() or _has_exit_anchor:
		return false
	if status in ["blocked", "unsafe_drop", "relocate", "trapped", "checking"]:
		return false
	for guard in range(4):
		if route.is_empty() or _segment_index >= route.segments.size():
			return false
		var segment: Dictionary = route.segments[_segment_index]
		if String(segment.kind) != "walk":
			return false
		if _body.global_position.distance_to(segment.landing) > 0.18:
			throttled_ticks += 1
			return _move_override(segment, speed, delta)
		_segment_index += 1
		_timer = 0.0
	return false


func tick(delta: float, can_act: bool, target: Node3D, speed: float) -> bool:
	var _cpu_scope := CpuAudit.begin(&"spatial.tick") if CpuAudit.enabled else null
	for channel: StringName in _cooldowns:
		_cooldowns[channel] = maxf(float(_cooldowns[channel]) - delta, 0.0)
	_timer -= delta
	_band_centre_timer = maxf(_band_centre_timer - delta, 0.0)
	_retreat_timer -= delta
	_rim_check -= delta
	_attack_timer -= delta
	_exit_check_timer -= delta
	process_jobs()
	_target = target
	# 目标瞬移必须立刻响应（不能因为降频晚几帧）；其余远处个体按 stride 降频。
	_jumped_this_frame = ring_goal_enabled and _ring_jumped()
	var stride := _tick_stride()
	if not _jumped_this_frame and stride > 1 and can_act and is_instance_valid(_target):
		var phase := (Engine.get_physics_frames() + int(_body.get_instance_id())) % stride
		if phase != 0 and _cheap_tick(delta, speed):
			return true
	full_ticks += 1
	_pursuit_active = false
	_live_aim_timer -= delta
	if not _pursuit_candidate():
		# 只有「当前段是规划器证明的直行段」才可能连续追击；其余情况不探测。
		_live_aim_ok = false
	elif _live_aim_timer <= 0.0:
		_live_aim_timer = LIVE_AIM_PERIOD
		var probe_start := Time.get_ticks_usec()
		_live_aim_ok = _navigation.live_direct_ok(target.global_position) if is_instance_valid(target) else false
		live_probe_calls += 1
		live_probe_usec += Time.get_ticks_usec() - probe_start
	if not _active.is_empty():
		return _advance_action(delta)
	if not can_act or not is_instance_valid(target):
		return false
	var here := Query.support(_body, false)
	if _attached.is_empty() and not here.is_empty() and _body.is_on_floor():
		if _has_last_ground and not _has_exit_anchor and _last_ground.y - _body.global_position.y > float(profile.safe_drop) + 0.1:
			_has_exit_anchor = true
			_exit_anchor = _last_ground
			_entry_takeoff = _body.global_position
			var exit := escape_plan(_body.global_position, _exit_anchor)
			if not exit.is_empty():
				_remember_escape(exit, _exit_anchor)
			else:
				last_failure = "forced_trap"
				status = "trapped"
		if not _has_exit_anchor:
			_last_ground = _body.global_position
			_has_last_ground = true
	if _has_exit_anchor and not here.is_empty():
		var anchor_feet := _exit_anchor.y - float(Query.dimensions(_body).half_height)
		if float(here.position.y) >= anchor_feet - float(profile.safe_drop):
			_release_escape()
		elif not Query.support(target).is_empty() and float(Query.support(target).position.y) > float(here.position.y) + float(profile.safe_drop):
			status = "escaping"
			# 出口实体或导航改变后必须从实际坑内位置重验，不能用旧计划承诺安全。
			if _exit_check_timer <= 0.0 or _revision != Destruction.geometry_revision:
				_exit_check_timer = float(profile.replan_interval)
				var fresh := escape_plan(_body.global_position, _exit_anchor)
				if fresh.is_empty():
					_escape.clear()
					escape_reserved = &""
					status = "trapped"
					last_failure = "exit_invalid"
				else:
					_remember_escape(fresh, _exit_anchor)
			if not _escape.is_empty() and remaining(escape_reserved) <= 0.0:
				var exit := _escape.duplicate(true)
				exit["escaping"] = true
				var approach: Dictionary = _escape.get("approach", {})
				if not approach.is_empty() and _body.global_position.distance_to(approach.landing) > 0.18:
					return _move_override(approach, speed, delta)
				if _begin_action(exit):
					return _advance_action(delta)
			elif _escape.is_empty():
				var exit_route := _walking(_body.global_position, _exit_anchor)
				if not exit_route.is_empty():
					return _move_override(exit_route, speed, delta)
	var nav_map := _nav_map()
	var nav_version := NavigationServer3D.map_get_iteration_id(nav_map) if nav_map.is_valid() else 0
	var target_support := Query.support(target)
	# 只有两侧都拿到真实支撑才谈得上「同层」；拿不到时按未知处理（-1），交给规划器判跳跃 / 攀爬。
	var paired := not here.is_empty() and not target_support.is_empty()
	_level_gap = absf(float(here.position.y) - float(target_support.position.y)) if paired else -1.0
	_same_level = paired and _level_gap <= float(profile.safe_drop)
	# 直行风格只由「规划器已经证明过的整段身体直行通道」放行。本地 0.3 米探测不能替代它：
	# 实测用它当替代条件会让「需要跳跃/破障/攀爬才能接战」的场景失去规划链路（策略与能力回归失败）。
	if profile.preserve_ground_style and _attached.is_empty() and not _has_exit_anchor and status not in ["unsafe_drop", "blocked", "relocate", "trapped"] and not here.is_empty() and not target_support.is_empty() and absf(float(here.position.y) - float(target_support.position.y)) <= float(profile.safe_drop) and _direct_style_valid(nav_version) and _body.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(_body.global_position, target.global_position, 1)).is_empty():
		_job = null
		route.clear()
		status = "approach"
		return false
	# 连续直行追击：本地走廊探测成立且规划器已给出直行段时，完全交给 NavSteering 的
	# NavigationAgent3D 连续跟随 —— 引擎会随目标移动自行更新路径，既没有「走到过期落点
	# 再转向」，也不再有分帧规划任务排队。任何一步不成立就落回下面的规划/路点链路。
	if _live_direct_pursuit(here, target_support):
		_pursuit_active = true
		status = "approach"
		last_failure = ""
		return false
	# 目标不连续移动（点击设点 / 传送）：环组已整体重新落位，旧路线立刻作废、马上改目标。
	var jumped := _jumped_this_frame
	if jumped:
		route.clear()
		_direct_ground_proof.clear()
		_job = null
		_segment_index = 0
		_point_index = 1
		_timer = 0.0
		status = "checking"
	var changed := jumped or target != _route_target or _revision != Destruction.geometry_revision or _nav_revision != nav_version
	if not changed:
		if _plan_band > 0.0:
			# 粗略目标：目标小幅移动不重画；只有「档位变了（更近了，该换更精确的目标）」
			# 或「这条路快走完了」才重画。远处敌人因此不会来回拉扯。
			if _goal_band() != _plan_band:
				changed = true
			elif ring_goal_enabled:
				# 环目标的锚点是冻结的：走完最后几米时若锚点没被拖动、环也没换，重画只会得到
				# 同一个结果，而下一帧又立刻被算作「走完了」，于是变成每帧重画（LOD 版本的死循环）。
				changed = _route_consumed(4.0) and _ring_anchor_changed()
			else:
				changed = _route_consumed(4.0)
		else:
			changed = target.global_position.distance_to(_goal_sample) > _replan_distance()
	# changed 本身已经是「路线终点偏离目标 + 自己快到路线终点」，重画频率由它兜住；
	# 再叠一层 replan_interval 限速会让本该重画时干等，实测把最长停顿从 13-27 帧拉到 88-97 帧。
	if not _planning_suspended and not _can_attack() and ((route.is_empty() and _timer <= 0.0) or changed):
		if _job == null:
			_request_route()
	if not route.is_empty() and _segment_index < route.segments.size():
		var segment: Dictionary = route.segments[_segment_index]
		if String(segment.kind) == "walk" and not _can_attack():
			if _body.global_position.distance_to(segment.landing) > 0.18:
				return _move_override(segment, speed, delta)
			_segment_index += 1
			_timer = 0.0
		elif String(segment.kind) != "walk" and not _can_attack():
			var approach: Dictionary = segment.get("approach", {})
			var approach_tolerance := 0.18 if String(segment.kind) in ["climb", "fly"] else 0.45
			if not approach.is_empty() and _body.global_position.distance_to(approach.landing) > approach_tolerance:
				return _move_override(approach, speed, delta)
			if _begin_action(segment):
				return _advance_action(delta)
			if last_failure == "cooldown":
				return false
	if (status in ["blocked", "unsafe_drop", "relocate", "trapped"] or (status == "checking" and not _retreat_route.is_empty())) and not _can_attack():
		return _relocate(speed, delta)
	if not _attached.is_empty():
		var attached_ability := ability(_attached.capability)
		if attached_ability == null or SurfaceTraversal.contact(_body, _body.global_position, _body.up_direction, attached_ability).is_empty():
			cancel_motion()
			status = "blocked"
			last_failure = "attachment_lost"
			return false
		_body.velocity = Vector3.ZERO
		if _can_attack() and _bindings.has("attached_action"):
			(_bindings.attached_action as Callable).call(delta)
		return true
	if _job != null and route.is_empty() and not _can_attack():
		stop_wait_frames += 1
		# 分帧查询期间停在实际起点，不能让角色直线兜底走离连接或走到坑沿。
		# A/B 实测（tests/test_navigation_moving_target.gd）：按上一步方向降速保留会拉长
		# 接战链的停顿，所以这里保留「停住等结果」，改由 P4 的保留路线避免长期无路可走。
		_body.velocity.x = 0.0
		_body.velocity.z = 0.0
		_body.velocity.y = -0.5 if _body.is_on_floor() else _body.velocity.y - _gravity * delta
		Ground.move(_body, delta)
		return true
	return false

func _direct_style_valid(nav_version: int) -> bool:
	# 视线射线只代表一条细线，不能代表整个身体可通行。
	# 直行风格只复用分帧规划器已经证明过的完整身体通道，偏离后交回共用规划。
	if _direct_ground_proof.is_empty() or _direct_ground_proof.owner != _target or _direct_ground_proof.geometry != Destruction.geometry_revision or _direct_ground_proof.navigation != nav_version:
		return false
	if _target.global_position.distance_to(_direct_ground_proof.target) > float(profile.target_replan_distance): return false
	if Query.dimensions(_body) != _direct_ground_proof.dimensions: return false
	var start := Vector2(_direct_ground_proof.from.x, _direct_ground_proof.from.z)
	var end := Vector2(_direct_ground_proof.to.x, _direct_ground_proof.to.z)
	var here := Vector2(_body.global_position.x, _body.global_position.z)
	var line := end - start
	var fraction := clampf((here - start).dot(line) / maxf(line.length_squared(), 0.001), 0.0, 1.0)
	return here.distance_to(start + line * fraction) < 0.3

func _can_attack() -> bool:
	if not _bindings.has("can_attack") or not is_instance_valid(_target):
		return false
	if _attack_timer <= 0.0 or _attack_sample.is_empty() or _body.global_position.distance_to(_attack_sample.at) > 0.2 or _target.global_position.distance_to(_attack_sample.target) > 0.2 or _attack_sample.revision != Destruction.geometry_revision or not _body.global_basis.is_equal_approx(_attack_sample.basis):
		_attack_timer = 0.08
		_attack_sample = {"at": _body.global_position, "target": _target.global_position, "basis": _body.global_basis, "revision": Destruction.geometry_revision, "value": bool((_bindings.can_attack as Callable).call())}
	return bool(_attack_sample.value)

func _route_landing_allowed(origin: Vector3, landing: Vector3, consumed: StringName, excluded: Array) -> bool:
	if landing.y >= origin.y - float(profile.safe_drop):
		return true
	var rids: Array[RID] = []
	rids.assign(excluded)
	return not escape_plan(landing, origin, consumed, rids).is_empty()

func adjust_ground_motion(goal: Vector3, desired: Vector3, delta: float) -> Vector3:
	var _cpu_scope := CpuAudit.begin(&"spatial.adjust") if CpuAudit.enabled else null
	var live := goal
	if _pursuit_active:
		# 连续追击：朝“当前目标”连续修正，由 NavSteering 的 Agent 路径负责绕开地形。
		var velocity_live: Vector3 = _navigation.raw_ground_velocity(live, desired, delta)
		return gate_motion(velocity_live, delta)
	var final_leg := route.is_empty()
	if not route.is_empty() and _segment_index < route.segments.size() and is_instance_valid(_target) and goal.distance_to(_target.global_position) < 1.5:
		var segment: Dictionary = route.segments[_segment_index]
		if String(segment.kind) == "walk":
			var points: PackedVector3Array = segment.points
			while _point_index < points.size() and _body.global_position.distance_to(points[_point_index]) < 0.6:
				_point_index += 1
			if _point_index < points.size():
				goal = points[_point_index]
				# 同上：只有规划器证明为直行的段才允许连续改瞄。
				final_leg = bool(segment.get("direct", false)) and _point_index >= points.size() - 1
			else:
				_segment_index += 1
				_point_index = 1
				final_leg = false
	# 同上：最后一段且本地探测成立时，朝“当前目标”连续修正（动态改线）。
	if final_leg and _live_aim_ready(goal):
		goal = live
	var velocity: Vector3 = _navigation.raw_ground_velocity(goal, desired, delta)
	return gate_motion(velocity, delta)


## 是否可能出现连续追击（当前段是规划器证明的直行段）。只有这种段才需要本地探测，
## 其余情况一律不探测，避免每个敌人每 0.08 秒都做身体扫掠。
## 目标移动多少才值得重画整条路线：随「敌人到目标的距离」放大（0.25×距离，夹在基础值与 6 米）。
## 远处敌人对目标的小幅移动本来就不敏感，用固定 0.8 米会让所有敌人都跟着小幅抖动反复重画。
func _replan_distance() -> float:
	var base := float(profile.target_replan_distance)
	if not is_instance_valid(_target) or not is_instance_valid(_body):
		return base
	return clampf(maxf(base, _body.global_position.distance_to(_target.global_position) * 0.25), base, 6.0)


## 动作开始（跳跃 / 攀爬 / 破障 / 自定义）：统一退出规划。
## 动作一开始，之前铺的路线就作废了（位置、落点、状态全会变），把在飞任务从队列里丢掉，
## 别再占每帧 700 µs 的规划预算；动作期间也不申请新规划。
func _start_action_window() -> void:
	_job = null
	_planning_suspended = true


## 动作结束 / 取消 / 被拒：统一恢复规划，并**错峰**。
## 多个个体常常在同一帧结束动作，如果都立刻申请重算，队列会瞬间打满、
## 帧耗时出现尖峰。这里按 instance_id 打散到 RESUME_STAGGER_SLOTS 个时隙上，
## 再由 _admit_plan 的每帧配额兜一层。
func _end_action_window(delay := -1.0) -> void:
	_planning_suspended = false
	var stagger := delay
	if stagger < 0.0:
		stagger = RESUME_STAGGER_BASE + float(int(_body.get_instance_id()) % RESUME_STAGGER_SLOTS) * RESUME_STAGGER_STEP
	_timer = maxf(_timer, stagger)


## 每帧规划开始配额：同帧只放行 PLAN_STARTS_PER_FRAME 个新规划，其余推迟重试。
static func _admit_plan() -> bool:
	var frame := Engine.get_physics_frames()
	if _plan_frame != frame:
		_plan_frame = frame
		_plan_starts = 0
	if _plan_starts >= PLAN_STARTS_PER_FRAME:
		return false
	_plan_starts += 1
	return true


## 目标是否刚刚发生了不连续移动（每个个体只认一次）。
func _ring_jumped() -> bool:
	if not ring_goal_enabled or not is_instance_valid(_target):
		return false
	var state := ring_state(_target)
	if state == null:
		return false
	if _ring_jump_revision == int(state.jump_revision):
		return false
	_ring_jump_revision = int(state.jump_revision)
	return true


## 环参数快照 / 应用（观察台保存方案与项目默认用）。
static func ring_config() -> Dictionary:
	return {"enabled": ring_goal_enabled, "drag_mode": ring_drag_mode, "radii": Array(ring_radii),
		"level_tolerance": ring_level_tolerance}


static func apply_ring_config(values: Dictionary) -> void:
	if values.is_empty():
		return
	ring_goal_enabled = bool(values.get("enabled", ring_goal_enabled))
	ring_drag_mode = String(values.get("drag_mode", ring_drag_mode))
	ring_level_tolerance = float(values.get("level_tolerance", ring_level_tolerance))
	var radii := PackedFloat32Array()
	for value in values.get("radii", []):
		radii.append(float(value))
	if radii.size() >= 2:
		ring_radii = radii
	reset_ring_goals()


## 进环落点选择：在环带候选里优先挑「能直着走过去」的（细射线不挡 + 整段完整身体通道成立，
## 与规划器 direct 分支同一判据）；都没有直线可达时才用几何最优候选，交给规划器绕行。
## 每调用一次最多做 BAND_DIRECT_CANDIDATES 次身体通道查询，只在发起规划时调用。
func _choose_band_goal(band: int) -> Vector3:
	var state := ring_state(_target)
	if state == null:
		return Vector3.ZERO
	if _band_centre_timer > 0.0:
		return state.point_for(band)
	var candidates: Array[Vector3] = state.region_candidates(band, _body.global_position, BAND_DIRECT_CANDIDATES)
	if candidates.is_empty():
		return state.point_for(band)
	for point: Vector3 in candidates:
		if _direct_walk_proof(point):
			direct_band_goals += 1
			return point
	return candidates[0]


## 「走直线就能到」的凭据：细射线不挡 + 整段完整身体通道通过。
func _direct_walk_proof(point: Vector3) -> bool:
	if not is_instance_valid(_body) or point.is_zero_approx():
		return false
	var space := _body.get_world_3d().direct_space_state
	if not space.intersect_ray(PhysicsRayQueryParameters3D.create(_body.global_position, point, 1)).is_empty():
		return false
	return Query.ground_segment(_body, _body.global_position, point, float(profile.safe_drop))


## 当前档位下这个追击者要用的目标点：先挑环带轨迹点（区域目标），再回退共享环圆心。
## 区域目标允许漂移：不要求落在某个精确坐标上，只要落进目标环带就算「进入下一层环」。
func _band_goal(band: int) -> Vector3:
	if not ring_goal_enabled or band < 1:
		return Vector3.ZERO
	var state := ring_state(_target)
	if state == null:
		return Vector3.ZERO
	# 轨迹候选刚失败过：先退回该环圆心（更保守、更近的锚点），等计时结束再试轨迹点。
	if _band_centre_timer <= 0.0:
		var region: Vector3 = state.region_goal(band, _body.global_position)
		if not region.is_zero_approx():
			return region
	return state.point_for(band)


## 当前档位的目标点是否已经换地方了。1 米以内不算换：环带里任何一个点都算「进入下一层环」，
## 不必贴住某个精确坐标，所以小幅漂移不应该触发重画。
func _ring_anchor_changed() -> bool:
	if _goal_anchor.is_zero_approx():
		return true
	var goal := _band_goal(int(_plan_band))
	if goal.is_zero_approx():
		return true
	return _goal_anchor.distance_to(goal) > 1.0


## 当前路线是否快走完：到路线终点的距离小于 margin。
func _route_consumed(margin: float) -> bool:
	if route.is_empty():
		return true
	var landing := _route_landing()
	return Vector2(landing.x - _body.global_position.x, landing.z - _body.global_position.z).length() <= margin


## 目标距离档位：0 = 精确目标；>0 = 粗略目标，同心环模式下就是「第几环」。
func _goal_band() -> float:
	if not is_instance_valid(_target):
		return 0.0
	if ring_goal_enabled:
		# 「没进环就只奔向环」：默认不做层级门（圈层解耦，跨层交给规划器判能力）。
		# 只有把 ring_level_tolerance 调成 > 0 时才启用旧的门；环带方案刚失败过也暂时交回精确目标。
		if ring_level_tolerance > 0.0 and _level_gap > ring_level_tolerance:
			return 0.0
		# 注意：环带计划失败**不会**回落到玩家精确坐标 —— 精确兜底的目标仍然是「进环」，
		# 只是从「目标轨迹里挑的漂移点」退成「该环圆心」这个确定的环内点（见 _band_goal）。
		var ring := _ring_goal()
		return 0.0 if ring.is_empty() else float(ring.ring)
	if not _same_level:
		# 不同层（平台、坑、坡）必须把真实目标交给规划器：那里要判跳跃 / 攀爬 / 破障。
		return 0.0
	if not coarse_goal_enabled:
		return 0.0
	var distance := _target_distance()
	if distance <= PRECISE_DISTANCE:
		return 0.0
	return COARSE_BAND_FAR if distance > COARSE_FAR_DISTANCE else COARSE_BAND_MID


## 粗略落脚点：沿导航网格路径朝目标前进 band 米，取那一点的**真实落脚**。
## 只查一次原生路径 + 一次落地查询，比让规划器铺一整条 30 米路线便宜得多。
func _coarse_point(band: float) -> Vector3:
	var map := _nav_map()
	if not map.is_valid():
		return Vector3.ZERO
	# 关键：粗略点取自**导航网格路径的顶点、按路径顺序**，不是朝玩家的直线方向。
	# 因此长墙、U 形障碍、需要先往侧面走（甚至暂时远离玩家）的连接关系天然被尊重。
	var path := NavigationServer3D.map_get_path(map, _body.global_position, _target.global_position, true)
	if path.size() < 2:
		return Vector3.ZERO
	var last := path[path.size() - 1]
	# 只接受**完整路径**：部分路径的终点不是目标，沿它走就会进死角。
	if Vector2(last.x - _target.global_position.x, last.z - _target.global_position.z).length() > 1.0:
		return Vector3.ZERO
	var travelled := 0.0
	var previous: Vector3 = _body.global_position
	for index in range(1, path.size()):
		travelled += Vector2(path[index].x - previous.x, path[index].z - previous.z).length()
		previous = path[index]
		if travelled < band:
			continue
		var hit := Query.floor_at(_body, path[index], maxf(1.0, float(Query.dimensions(_body).radius)))
		if hit.is_empty():
			continue    # 该顶点落不到真实地面：继续沿路径往前找，找不到就整体回落
		var grounded := Query.ground_pose(_body, hit)
		# 允许「先往侧面走 / 暂时远离玩家」，但第一段不跨层：跨层要交给规划器判跳跃、攀爬、坡度。
		if absf(grounded.y - _body.global_position.y) > float(profile.safe_drop):
			return Vector3.ZERO
		return grounded
	return Vector3.ZERO


## 本次规划要用的目标点与档位。
func _pursuit_goal() -> Dictionary:
	var band := _goal_band()
	if band <= 0.0:
		return {"point": _target.global_position, "band": 0.0}
	if ring_goal_enabled:
		# 同心环带目标：优先从目标真实轨迹里挑一个落在目标环带内、靠近中线的点
		# （连通性免费、每个追击者各挑各的）；轨迹还没铺开就回退共享环圆心；再不行回精确目标。
		var state := ring_state(_target)
		var region: Vector3 = _choose_band_goal(int(band)) if state != null else Vector3.ZERO
		if not region.is_zero_approx():
			ring_region_used += 1
			return {"point": region, "band": band}
		var anchor: Vector3 = state.point_for(int(band)) if state != null else Vector3.ZERO
		if not anchor.is_zero_approx():
			ring_anchor_fallbacks += 1
			return {"point": anchor, "band": band}
		return {"point": _target.global_position, "band": 0.0}
	# 粗略点任何一步不可靠（部分路径 / 落不到地面 / 首段跨层）都回落精确目标：
	# 宁可让规划器多算一条完整路线，也不能用「直线方向」把敌人送进死角。
	var coarse := _coarse_point(band)
	if coarse.is_zero_approx():
		return {"point": _target.global_position, "band": 0.0}
	return {"point": coarse, "band": band}


## 路线终点（最后一段的落点）。
func _route_landing() -> Vector3:
	if route.is_empty():
		return Vector3.ZERO
	var segments: Array = route.segments
	return Vector3.ZERO if segments.is_empty() else segments[segments.size() - 1].get("landing", Vector3.ZERO)


func _pursuit_candidate() -> bool:
	if not live_aim_enabled or _attached.size() > 0 or _has_exit_anchor:
		return false
	if _plan_band > 0.0:
		# 带档位的计划：瞄准点必须停在环锚点上。连续追击是朝「当前目标」修正，
		# 一旦放行就等于把环目标又换回跟着目标抖，环模型白做。
		return false
	if route.is_empty() or _segment_index >= route.segments.size() or not is_instance_valid(_target):
		return false
	var segment: Dictionary = route.segments[_segment_index]
	return String(segment.kind) == "walk" and bool(segment.get("direct", false))


## 连续直行追击是否成立：已有验证路线 + 当前段是规划器证明的直行段 + 本地走廊探测通过 +
## 同层且不处于逃逸/附着状态。成立时调用方直接走 NavSteering 的连续跟随。
func _live_direct_pursuit(here: Dictionary, target_support: Dictionary) -> bool:
	# _live_aim_ok 只在 _pursuit_candidate()（当前段是规划器证明的直行段）里被置真。
	if not _live_aim_ok or here.is_empty() or target_support.is_empty():
		return false
	return absf(float(here.position.y) - float(target_support.position.y)) <= float(profile.safe_drop)


## 是否允许把瞄准点从过期路点换成“当前目标”。只改变瞄准点，不改变通行判定。
##
## 锥形保护：只有在“朝当前目标”与“朝路点”两个方向夹角不超过 LIVE_AIM_CONE_DEG 时才改瞄。
## 目标直线前进时两者几乎同向，连续修正生效；目标急转回折时保持规划器给的路点，
## 避免纯追踪在折返瞬间甩过头（单测 tests/test_navigation_live_aim.gd 对照过两种做法）。
func _live_aim_ready(waypoint: Vector3) -> bool:
	if not live_aim_enabled or not _live_aim_ok or not is_instance_valid(_target) or not is_instance_valid(_body):
		return false
	var offset := _target.global_position - _body.global_position
	offset.y = 0.0
	if offset.length() < 0.35 or offset.length() > LIVE_AIM_DISTANCE:
		return false
	var to_waypoint := waypoint - _body.global_position
	to_waypoint.y = 0.0
	if to_waypoint.length() < 0.2:
		return true
	return offset.normalized().dot(to_waypoint.normalized()) >= cos(deg_to_rad(LIVE_AIM_CONE_DEG))

func gate_motion(desired: Vector3, delta: float) -> Vector3:
	var _cpu_scope := CpuAudit.begin(&"spatial.gate") if CpuAudit.enabled else null
	if desired.is_zero_approx() or not _body.is_on_floor():
		return desired
	var here := Query.support(_body, false)
	if here.is_empty():
		return Vector3.ZERO
	var radius := float(Query.dimensions(_body).radius)
	var ahead := desired.normalized() * maxf(radius * 0.65 + 0.2, desired.length() * maxf(delta, 0.12))
	var feet_ahead := (here.position as Vector3) + ahead
	var normal: Vector3 = here.normal
	feet_ahead.y -= (normal.x * ahead.x + normal.z * ahead.z) / maxf(normal.y, 0.01)
	var lower := Query.floor_at(_body, feet_ahead, maxf(float(profile.safe_drop), 12.0))
	if not lower.is_empty() and absf(float(lower.position.y) - feet_ahead.y) <= float(profile.safe_drop) + 0.05:
		return desired
	# 大身体的前探较远，当前切平面可能钻进弯曲上坡的地下，单条向下射线会漏地。
	# 即使远端射线落空，也沿小步逐段确认连续支撑；真正断崖仍会在段内被拒绝。
	if Query.ground_connected(_body, here, feet_ahead, float(profile.safe_drop)):
		return desired
	if not lower.is_empty():
		var entered := Query.body_on_floor(_body, lower)
		var exit := escape_plan(entered, _exit_anchor if _has_exit_anchor else _body.global_position)
		if not exit.is_empty():
			_remember_escape(exit, _body.global_position)
			return desired
	status = "unsafe_drop"
	last_failure = "no_exit_proof" if not lower.is_empty() else "no_landing"
	return Vector3.ZERO

func escape_plan(entered: Vector3, anchor: Vector3, consumed: StringName = &"", excluded: Array[RID] = []) -> Dictionary:
	var walk := _walking(entered, anchor, excluded)
	if not walk.is_empty():
		return {"kind": "walk", "route": walk}
	var ground := Query.floor_at(_body, anchor - Vector3.UP * float(Query.dimensions(_body).half_height), 0.5, excluded)
	if ground.is_empty():
		return {}
	for item in capabilities:
		if item.kind != Capability.Kind.JUMP:
			continue
		var wait := remaining(item.id)
		if item.id == consumed:
			wait = maxf(wait, float(item.cooldown))
		if wait > float(profile.max_escape_wait):
			continue
		var plan := Query.jump_plan(_body, entered, ground, item, excluded)
		if not plan.is_empty():
			plan["wait"] = wait
			return plan
		# 坑内追击可能走到贴墙位置；先返回已验证的起跳空地，再执行同一返程跳跃。
		if _has_exit_anchor:
			var approach := _walking(entered, _entry_takeoff, excluded)
			if not approach.is_empty():
				plan = Query.jump_plan(_body, _entry_takeoff, ground, item, excluded)
				if not plan.is_empty():
					plan["approach"] = approach
					plan["wait"] = wait
					return plan
			# 玩家可能正站在原入口；出口是同层安全区域，不强迫落在被占用的一个点上。
			var spacing := float(Query.dimensions(_body).radius) * 2.0 + 0.35
			for direction: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
				var nearby := Query.floor_at(_body, (ground.position as Vector3) + direction * spacing, 0.2, excluded)
				if nearby.is_empty() or absf(float(nearby.position.y) - float(ground.position.y)) > float(profile.safe_drop):
					continue
				plan = Query.jump_plan(_body, entered, nearby, item, excluded)
				if plan.is_empty() and not approach.is_empty():
					plan = Query.jump_plan(_body, _entry_takeoff, nearby, item, excluded)
					if not plan.is_empty():
						plan["approach"] = approach
				if not plan.is_empty():
					plan["wait"] = wait
					return plan
	for item in capabilities:
		if item.kind not in [Capability.Kind.CLIMB, Capability.Kind.FLY, Capability.Kind.CUSTOM]:
			continue
		var wait := maxf(remaining(item.id), float(item.cooldown) if item.id == consumed else 0.0)
		if wait > float(profile.max_escape_wait):
			continue
		for link: Node3D in _body.get_tree().get_nodes_in_group("spatial_traversal_links"):
			if not link.enabled or link.capability != item.id:
				continue
			for reverse in ([false, true] if link.bidirectional else [false]):
				var points: PackedVector3Array = link.world_points(reverse)
				if points.size() < 2 or _walking(entered, points[0], excluded).is_empty() or _walking(points[-1], anchor, excluded).is_empty():
					continue
				var plan := SurfaceTraversal.plan(_body, points, link.world_normals(reverse), item, link.attachable)
				if not plan.is_empty():
					plan["link"] = weakref(link)
					plan["reverse"] = reverse
					plan["approach"] = _walking(entered, points[0], excluded)
					plan["wait"] = wait
					return plan
	return {}

func permit_landing(landing: Vector3, consumed: StringName = &"", excluded: Array[RID] = [], commit := true) -> bool:
	if landing.y >= _body.global_position.y - float(profile.safe_drop):
		return true
	var exit := escape_plan(landing, _exit_anchor if _has_exit_anchor else _body.global_position, consumed, excluded)
	if exit.is_empty():
		last_failure = "no_exit_proof"
		return false
	if commit:
		_remember_escape(exit, _body.global_position)
	return true

func _remember_escape(plan: Dictionary, anchor: Vector3) -> void:
	if not _has_exit_anchor:
		_exit_anchor = anchor
		_has_exit_anchor = true
		_entry_takeoff = plan.get("from", _body.global_position)
	_escape.clear()
	escape_reserved = &""
	if String(plan.kind) != "walk":
		_escape = plan
		escape_reserved = plan.capability if profile.reserve_escape else &""

func _release_escape() -> void:
	_has_exit_anchor = false
	_escape.clear()
	escape_reserved = &""

func _begin_action(plan: Dictionary) -> bool:
	var item := ability(plan.get("capability", &""))
	if item == null or not item.enabled:
		return _reject_action("ability_unavailable")
	if remaining(item.id) > 0.0:
		last_failure = "cooldown"
		return false
	if String(plan.kind) == "jump":
		if not _body.is_on_floor():
			return false
		var support := Query.floor_at(_body, plan.ground, 0.2)
		var fresh := Query.jump_plan(_body, _body.global_position, support, item)
		if fresh.is_empty() or (not bool(plan.get("escaping", false)) and not permit_landing(fresh.landing, item.id)):
			last_failure = "jump_invalid"
			_timer = 0.0
			route.clear()
			return false
		fresh["escaping"] = plan.get("escaping", false)
		plan = fresh
	elif String(plan.kind) == "break":
		var component: Node3D = (plan.component as WeakRef).get_ref()
		if component == null or component.is_broken or not component.can_break(float(item.power)):
			_timer = 0.0
			route.clear()
			return false
		if _bindings.has("break_action"):
			if bool((_bindings.break_action as Callable).call(component, plan.point, item)):
				last_action = "break"
				status = "breaking"
				route.clear()
				_timer = float(profile.retry_delay)
				return false
			last_failure = "break_action_unavailable"
			return false
	elif String(plan.kind) in ["climb", "fly"]:
		var link: Node3D = (plan.link as WeakRef).get_ref()
		if link == null or not link.enabled:
			return _reject_action("link_unavailable")
		var reverse := bool(plan.get("reverse", false))
		var points: PackedVector3Array = link.world_points(reverse)
		if points.is_empty() or _body.global_position.distance_to(points[0]) > 0.25:
			return _reject_action("link_start_unreachable")
		var fresh := SurfaceTraversal.plan(_body, points, link.world_normals(reverse), item, link.attachable, _body.global_transform)
		if fresh.is_empty():
			return _reject_action("surface_invalid")
		fresh["escaping"] = plan.get("escaping", false)
		plan = fresh
	elif not item.begin_custom(_body, plan):
		return false
	# 动作期间退出规划（统一信号，见 _start_action_window / _end_action_window）。
	_start_action_window()
	_active = plan.duplicate(true)
	_elapsed = 0.0
	_started = false
	_saved_motion_mode = _body.motion_mode
	_saved_up = _body.up_direction
	status = "escaping" if bool(plan.get("escaping", false)) else "traversing"
	last_action = String(plan.kind)
	_consume(item)
	return true

func _reject_action(reason: String) -> bool:
	last_failure = reason
	status = "blocked"
	route.clear()
	_timer = float(profile.retry_delay)
	_end_action_window(float(profile.retry_delay))
	return false

func _advance_action(delta: float) -> bool:
	var item := ability(_active.get("capability", &""))
	if item == null:
		cancel_motion()
		return false
	_elapsed += delta
	if _elapsed < float(item.windup):
		_body.velocity.x = 0.0
		_body.velocity.z = 0.0
		_body.velocity.y = -0.5 if _body.is_on_floor() else _body.velocity.y - float(item.gravity) * delta
		Ground.move(_body, delta, false)
		return true
	if not _started:
		_started = true
		if String(_active.kind) == "jump":
			_body.velocity = _active.launch
		else:
			_body.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var elapsed := _elapsed - float(item.windup)
	if String(_active.kind) == "jump":
		_body.velocity.x = float(_active.launch.x)
		_body.velocity.z = float(_active.launch.z)
		_body.velocity.y -= float(_active.gravity) * delta
		_body.move_and_slide()
		var collision := _body.is_on_wall() or _body.is_on_ceiling()
		if collision or elapsed > float(_active.flight) + 0.7:
			_finish_motion(false)
		elif _body.is_on_floor() and elapsed > 0.15:
			_finish_motion(_body.global_position.distance_to(_active.landing) < 0.65)
	elif String(_active.kind) in ["climb", "fly"]:
		var poses: Array = _active.poses
		var fraction := clampf(elapsed / maxf(float(_active.duration), 0.01), 0.0, 1.0)
		var position := fraction * (poses.size() - 1)
		var index := mini(floori(position), poses.size() - 1)
		var desired: Transform3D = (poses[index] as Transform3D).interpolate_with(poses[mini(index + 1, poses.size() - 1)], position - index)
		if not Query.motion_clear(_body, desired, Vector3.ZERO) or (String(_active.kind) == "climb" and SurfaceTraversal.contact(_body, desired.origin, desired.basis.y.normalized(), item).is_empty()):
			_finish_motion(false)
			return true
		_body.global_basis = desired.basis
		_body.up_direction = desired.basis.y.normalized()
		_body.velocity = (desired.origin - _body.global_position) / maxf(delta, 0.001)
		_body.move_and_slide()
		if _body.global_position.distance_to(desired.origin) > 0.15:
			_finish_motion(false)
		elif fraction >= 1.0:
			_finish_motion(true)
	else:
		var outcome: String = item.step_custom(_body, _active, delta)
		if outcome != "running":
			_finish_motion(outcome == "arrived")
	return true

func _finish_motion(success: bool) -> void:
	var escaped := bool(_active.get("escaping", false))
	var stay_attached := success and String(_active.kind) == "climb" and _body.up_direction.dot(Vector3.UP) < 0.99
	if stay_attached:
		_attached = {"capability": _active.capability}
	else:
		_attached.clear()
		_body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		_body.up_direction = Vector3.UP
		if String(_active.kind) in ["climb", "fly"]:
			_body.global_basis = Basis(Vector3.UP, _body.rotation.y).scaled(_body.global_basis.get_scale())
	_body.velocity.x = 0.0
	_body.velocity.z = 0.0
	_active.clear()
	if success:
		_segment_index += 1
		_point_index = 1
		last_failure = ""
		if escaped:
			var support := Query.support(_body, false)
			var anchor_feet := _exit_anchor.y - float(Query.dimensions(_body).half_height)
			if not support.is_empty() and float(support.position.y) >= anchor_feet - float(profile.safe_drop):
				_release_escape()
			else:
				_escape.clear()
		status = "approach"
		_end_action_window()
	else:
		last_failure = "motion_blocked"
		route.clear()
		_timer = float(profile.retry_delay)
		status = "blocked"
		_end_action_window(float(profile.retry_delay))

func cancel_motion() -> void:
	var surface_motion := not _active.is_empty() and String(_active.kind) in ["climb", "fly"]
	if not _active.is_empty() and is_instance_valid(_body):
		var item := ability(_active.get("capability", &""))
		if item != null:
			item.cancel_custom(_body)
		_body.motion_mode = _saved_motion_mode
		_body.up_direction = _saved_up
	_active.clear()
	if (surface_motion or not _attached.is_empty()) and is_instance_valid(_body):
		_body.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		_body.up_direction = Vector3.UP
		_body.global_basis = Basis(Vector3.UP, _body.rotation.y).scaled(_body.global_basis.get_scale())
	_attached.clear()
	route.clear()
	_job = null
	_end_action_window(float(profile.retry_delay))

func _move_override(walking: Dictionary, speed: float, delta: float) -> bool:
	var points: PackedVector3Array = walking.points
	var next := walking.landing as Vector3
	var cursor := int(walking.get("_cursor", 1))
	while cursor < points.size() - 1 and Vector2(_body.global_position.x - points[cursor].x, _body.global_position.z - points[cursor].z).length() < 0.28:
		cursor += 1
	walking["_cursor"] = cursor
	if cursor < points.size():
		next = points[cursor]
	var direction := next - _body.global_position
	direction.y = 0.0
	var desired := gate_motion(direction.normalized() * minf(speed, direction.length() / maxf(delta, 0.001)), delta) if direction.length() > 0.1 else Vector3.ZERO
	if _body.has_meta(&"combat_recorder"):
		var requested := direction.normalized() * minf(speed, direction.length() / maxf(delta, 0.001)) if direction.length() > 0.1 else Vector3.ZERO
		_body.set_meta(&"sparring_motion", {"engine_frame": Engine.get_physics_frames(), "source": "spatial_override",
			"requested": [requested.x, requested.y, requested.z], "allowed": [desired.x, desired.y, desired.z]})
	if not desired.is_zero_approx() and _body.up_direction.dot(Vector3.UP) > 0.99:
		_body.rotation.y = rotate_toward(_body.rotation.y, atan2(-desired.x, -desired.z), delta * 6.0)
	_body.velocity.x = move_toward(_body.velocity.x, desired.x, float(profile.acceleration) * delta)
	_body.velocity.z = move_toward(_body.velocity.z, desired.z, float(profile.acceleration) * delta)
	_body.velocity.y = -0.5 if _body.is_on_floor() else _body.velocity.y - _gravity * delta
	Ground.move(_body, delta)
	_progress_clock += delta
	if _progress_clock >= 0.6:
		if _body.global_position.distance_to(_progress_point) < 0.12 and direction.length() > 0.25:
			if not walking.has("rim_anchor") and _recover_walk(walking, direction):
				status = "recovering"
				last_failure = ""
			else:
				route.clear()
				# 行走受阻先从实际位置重算；只有确实无通行能力时才交给坑沿策略。
				_timer = 0.0
				status = "approach"
				last_failure = "walking_replan"
				_navigation.repath()
			if walking.has("rim_anchor"):
				_retreat_route.clear()
				_retreat_timer = float(profile.retry_delay)
		_progress_point = _body.global_position
		_progress_clock = 0.0
	return true

func _recover_walk(walking: Dictionary, direction: Vector3) -> bool:
	# APS 式局部绕行点：两侧 / 后方都试，入口和返程都必须有真实身体通道。
	var forward := direction.normalized()
	var side := Vector3(-forward.z, 0, forward.x)
	var half := float(Query.dimensions(_body).half_height)
	var origin := _body.global_position
	var landing: Vector3 = walking.landing
	for distance: float in [1.5, 3.0]:
		for heading: Vector3 in [side, -side, -forward, (side - forward).normalized(), (-side - forward).normalized()]:
			var expected := origin + heading * distance - Vector3.UP * half
			var floor_hit := Query.floor_at(_body, expected, 1.5)
			if floor_hit.is_empty(): continue
			var candidate := Query.ground_pose(_body, floor_hit)
			if not Query.ground_segment(_body, origin, candidate, float(profile.safe_drop)): continue
			var onward := _walking(candidate, landing)
			if onward.is_empty(): continue
			var points := PackedVector3Array([origin, candidate])
			var onward_points: PackedVector3Array = onward.points
			for i in range(1, onward_points.size()): points.append(onward_points[i])
			walking["points"] = points
			walking["_cursor"] = 1
			recovery_count += 1
			return true
	return false

func _relocate(speed: float, delta: float) -> bool:
	if not _has_rim_anchor or _target.global_position.distance_to(_rim_target) > float(profile.rim_patrol_radius):
		_rim_anchor = _body.global_position
		_rim_detected = false
		_rim_target = _target.global_position
		_has_rim_anchor = true
		_rim_expose = false
		_rim_dwell = -1.0
		_retreat_route.clear()
		_retreat_timer = 0.0
	if _retreat_revision != Destruction.geometry_revision:
		_retreat_route.clear()
		_retreat_timer = 0.0
	if not _retreat_route.is_empty():
		var arrived := _body.global_position.distance_to(_retreat_route.landing) < 0.25
		if arrived:
			if _rim_dwell < 0.0:
				_rim_dwell = float(profile.rim_exposure_duration) if _rim_expose else randf_range(float(profile.rim_dwell_min), float(profile.rim_dwell_max))
			_rim_dwell -= delta
			if _rim_dwell <= 0.0:
				_rim_expose = false if _rim_expose else randf() < float(profile.rim_exposure_chance)
				_retreat_route.clear()
				_retreat_timer = 0.0
		# 玩家改变枪口 / 相机时及时重验掩护；探头窗口到时再回到盲区。
		if not _rim_expose and _rim_check <= 0.0 and not _retreat_route.is_empty():
			_rim_check = 0.25
			var threat := {"range": profile.threat_range_fallback, "origin": _target.global_position, "camera": _target.global_position}
			if _target.has_method("get_combat_threat"):
				threat.merge(_target.call("get_combat_threat"), true)
			if bool(_retreat_route.get("safe", false)) and RetreatPlanner.exposed(_body, _retreat_route.landing, threat):
				_retreat_route.clear()
				_retreat_timer = 0.0
	if _retreat_route.is_empty() and _retreat_timer <= 0.0 and _job == null:
		_retreat_timer = float(profile.retry_delay)
		var planner := Planner.new()
		planner.body = _body
		planner.profile = profile
		planner.capabilities = capabilities
		planner.navigation_map = _nav_map()
		var search := RetreatPlanner.new()
		search.begin(_body, _target, profile, planner, _rim_anchor, _rim_expose, not _rim_detected)
		_job = search
		_job_kind = "retreat"
		_retreat_revision = Destruction.geometry_revision
		_jobs.append(weakref(self))
	var here := Query.support(_body, false)
	var trapped := _has_exit_anchor and _escape.is_empty() and not here.is_empty() and float(here.position.y) < _exit_anchor.y - float(Query.dimensions(_body).half_height) - float(profile.safe_drop)
	status = "trapped" if trapped else "relocate"
	if not _retreat_route.is_empty():
		return _move_override(_retreat_route, speed, delta)
	_body.velocity.x = move_toward(_body.velocity.x, 0.0, float(profile.acceleration) * delta)
	_body.velocity.z = move_toward(_body.velocity.z, 0.0, float(profile.acceleration) * delta)
	_body.velocity.y = -0.5 if _body.is_on_floor() else _body.velocity.y - _gravity * delta
	Ground.move(_body, delta)
	last_failure = "no_exit_proof" if trapped else "checking_retreat" if _job != null else "no_safe_retreat"
	return true


func dispose() -> void:
	cancel_motion()
	_release_escape()
	for index in range(_jobs.size() - 1, -1, -1):
		var owner: RefCounted = _jobs[index].get_ref()
		if owner == null or owner == self:
			_jobs.remove_at(index)
	if is_instance_valid(_body):
		Query.forget(_body)
		_body.remove_meta(INSTANCE)
	_body = null
	_navigation = null
	_bindings.clear()
