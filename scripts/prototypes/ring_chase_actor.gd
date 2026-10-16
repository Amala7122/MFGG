extends CharacterBody3D
## 精确追击观察台的追击者：只有「朝目标点走」这一个行为。
## 没有攻击、技能、受击、死亡、投放、隐蔽；不挂空间控制器。
##
## 跟随复用正式 [nav_steering.gd] 的 NavigationAgent3D 路径与防卡死状态机，
## 但不调用 steering.tick()，所以空间规划链路在本台完全不参与。
const Steering := preload("res://scripts/nav_steering.gd")
const Ground := preload("res://scripts/ground_movement.gd")
const Query := preload("res://scripts/spatial_query.gd")

## 停滞判定用「窗口净位移」，不能用逐帧位移：
## 贴着墙小幅抖动、或每 0.3 秒往前蹭半厘米时，逐帧位移都不为零，
## 但人眼看到的就是站着不动。正式 NavSteering 的脱困判定用的是同一套口径。
const STUCK_WINDOW := 0.6
const STUCK_MIN_MOVE := 0.25

var steering: RefCounted
var goal := Vector3.ZERO
var has_goal := false
var speed := 4.0
var travelled := 0.0
## 窗口判定为停滞的累计时长（秒）与历史最大值。
var stationary_time := 0.0
var longest_stop := 0.0
## 最近一个窗口的净位移是否不足：观察台据此画红色高杆。
var stalled := false
## 判定为停滞的窗口数（每窗口 0.6 秒）。比累计时长更细，能反映「停一下再走」。
var stalled_windows := 0
## 窗口内净位移（米），用于诊断「看起来不动但每帧都在动」。
var window_moved := 0.0
## 停住超过阈值时采样一次原因，供观察台与探针统计。
var stall_reason := ""
## 本次停顿是否已经计过一次数；恢复移动后清零，避免同一段停顿重复计数。
var stall_counted := false
var trail := PackedVector3Array()
var _previous := Vector3.ZERO
var _window_origin := Vector3.ZERO
var _window_time := 0.0
var _trail_timer := 0.0

func _ready() -> void:
	steering = Steering.new()
	var dimensions := Query.dimensions(self)
	steering.setup(self, float(dimensions.radius), float(dimensions.half_height) * 2.0)
	_previous = global_position
	_window_origin = global_position

## 投放 / 重生：落到指定点，清空累计与轨迹，强制下一帧重算路径。
func place_at(point: Vector3) -> void:
	global_position = point
	velocity = Vector3.ZERO
	_previous = point
	_window_origin = point
	_window_time = 0.0
	travelled = 0.0
	stationary_time = 0.0
	longest_stop = 0.0
	stalled = false
	stalled_windows = 0
	window_moved = 0.0
	stall_reason = ""
	stall_counted = false
	trail.clear()
	_has_goal(false)

func set_goal(point: Vector3) -> void:
	goal = point
	_has_goal(true)

func _has_goal(value: bool) -> void:
	has_goal = value
	if value and steering != null and float(steering._issued_goal.distance_to(goal)) > 1.0:
		steering.repath()

func _physics_process(delta: float) -> void:
	if has_goal:
		var offset := goal - global_position
		offset.y = 0.0
		var fallback := Vector3.ZERO
		if offset.length() > 0.02:
			fallback = offset.normalized()
		# direction_to 含路径跟随、贴墙切向偏转与卡死脱困；返回零表示路径已到终点。
		var direction: Vector3 = steering.direction_to(goal, fallback, delta)
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	velocity.y = -0.5 if is_on_floor() else velocity.y - 20.0 * delta
	Ground.move(self, delta)
	var moved := Vector2(global_position.x - _previous.x, global_position.z - _previous.z).length()
	travelled += moved
	_previous = global_position
	# 窗口净位移判定：每 STUCK_WINDOW 秒比较一次当前位置与窗口起点。
	_window_time += delta
	if _window_time >= STUCK_WINDOW:
		window_moved = Vector2(global_position.x - _window_origin.x,
			global_position.z - _window_origin.z).length()
		_window_origin = global_position
		_window_time = 0.0
		stalled = window_moved < STUCK_MIN_MOVE
		if stalled:
			stalled_windows += 1
			stationary_time += STUCK_WINDOW
			longest_stop = maxf(longest_stop, stationary_time)
			if stall_reason.is_empty():
				stall_reason = _sample_stall_reason()
		else:
			stationary_time = 0.0
			stall_reason = ""
			stall_counted = false
	_trail_timer -= delta
	if _trail_timer <= 0.0:
		_trail_timer = 0.15
		trail.append(global_position)
		# 轨迹只留很短一段：256 个体时每体 200 点会让绘制本身成为瓶颈。
		if trail.size() > 48:
			trail.remove_at(0)

## 停住时采样一次原因：路径走完（含部分路径）/ 目标不可达 / 没有路径 / 有路径但走不动。
func _sample_stall_reason() -> String:
	if steering == null or not is_instance_valid(steering._agent):
		return "no_agent"
	var agent: NavigationAgent3D = steering._agent
	if agent.is_navigation_finished():
		return "path_finished"
	if not agent.is_target_reachable():
		return "unreachable"
	if agent.get_current_navigation_path().size() <= 1:
		return "no_path"
	return "blocked_or_sliding"
