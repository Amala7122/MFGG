class_name NavSteering
extends RefCounted
## 敌人寻路辅助：包装一个 NavigationAgent3D，给出"朝目标该往哪走"的水平方向。
##
## 用代码创建 NavigationAgent3D、而不是给敌人场景挂节点 —— 与 EnemyRig /
## EnemyVisuals 的既有做法一致，敌人 .tscn 保持干净。
##
## 关键设计：**导航不可用时自动回退直线追击**。
## 烘焙是异步的（选敌人大批生成时网格可能还没好），而且烘焙本身也可能失败；
## 任何情况下都不能让敌人原地发呆，所以拿不到有效路径就退回直线。
##
## 关于 is_target_reachable() 偶发为 false：
## 实测过 3 个敌人里有 1 个报 false。逐项排查后确认**不是 bug，也不需要在
## 生成点做落点吸附** —— 那个敌人离导航网格只有 0.73 米，与两个正常的
## （0.45 / 0.46 米）完全同一量级，说明它并没有站在不可导航的位置。
## 真正原因是调用方会跳过路径更新：melee_enemy 被手雷/脉冲击退时
## （_stagger_time > 0）会提前 return，此代理缓存的仍是上一次较旧的结果。
## 因为已有直线兜底，行为不受影响，所以这里只记录现象、不做补偿。
##
## ── 防卡死 ─────────────────────────────────────────────────────
##
## 敌人会卡在两个障碍物之间（V 形夹角）：朝出口推进 → 撞 A 后沿 A 滑 →
## 立刻撞 B → 速度被投影回来 → 净位移为 0，而每 REPATH_INTERVAL 重算的是
## 同一条路径，于是永远出不来，表现为原地抖动。
##
## 分三层处理，顺序是「先别卡 → 真卡了脱困 → 脱不掉就换路」：
##
##   1. 预防（_contact_push）：撞上东西时不要硬顶，而是沿接触法线偏出去。
##      这让敌人自然绕开掩体角，而不是贴着墙一路磨过去。
##   2. 脱困（State.UNSTICKING）：判定卡住后，改走期望方向的**垂直分量**，
##      从夹角里横向蹭出来。左右两侧逐次交替，避免两次挤进同一个死角。
##   3. 换路（State.REROUTING）：连续脱困 UNSTICK_MAX_TRIES 次仍未脱身，
##      就不再朝玩家直奔，改为先走向一个横向偏移的中间点 —— 导航目标换了，
##      算出来的就是另一条路径，而不是重复那条走不通的。
##
## 「怎么进 / 怎么出」的判定条件全部写在下面的常量注释里。

## 重新设定目标的间隔。每帧设一次会反复触发寻路，20 多个敌人时开销明显。
const REPATH_INTERVAL := 0.22
## 路径点距离自己小于这个值就认为"路径已到脚下"，退回直线避免原地打转。
const MIN_DIRECTION_SQR := 0.04

# ------------------------------------------------------------ 预防：贴墙切向偏转
## 0 = 完全硬顶（改动前的行为），1 = 完全沿墙走。
## 取 0.9：基本贴着墙滑，但还留一点朝目标的推进分量，不会沿墙越走越远。
const CONTACT_PUSH := 0.9

# ------------------------------------------------------------ 卡死检测
## 判定窗口的长度（秒）。连续这么久没走出 STUCK_MIN_MOVE 才算卡住。
const STUCK_WINDOW := 0.6
## 窗口内的水平位移阈值（米）。最慢的敌人 2.2 m/s，0.6 秒也该走 1.3 米，
## 所以 0.25 米是"基本没动"的明确信号，正常减速不会被误判。
const STUCK_MIN_MOVE := 0.25
## 单帧位移超过这个值视为"被击退 / 重新定位"，不当成"走得很顺"，直接开新窗口。
## 最快的敌人 6.2 m/s，一帧（1/60 秒）只有 0.1 米，所以 2.0 米只可能是瞬移。
const TELEPORT_MOVE := 2.0

# ------------------------------------------------------------ 脱困
## 单次脱困时长。够蹭出夹角，又短到不会让人看出在瞎走。
const UNSTICK_DURATION := 0.9
## 连续脱困这么多次仍没脱身 → 认定此路不通，进入换路。
const UNSTICK_MAX_TRIES := 3
## 脱困方向的侧向占比：0 = 纯侧移，1 = 纯前进。0.75 以侧移为主。
const UNSTICK_SIDE_RATIO := 0.75

# ------------------------------------------------------------ 换路
## 换路状态的最长持续时间；走到中间点会提前结束。
const REROUTE_DURATION := 4.0
## 中间点相对"自己→目标"直线的横向偏移量（米）。
## 必须明显大于导航网格的 agent_radius（0.9），否则算出来还是同一条路径。
const REROUTE_OFFSET := 4.5
## 中间点取在"自己→目标"直线上的比例：0.5 = 中点。太靠近目标就起不到绕路作用。
const REROUTE_ALONG_RATIO := 0.5
## 走到距中间点这么近就算抵达，提前结束换路。
const REROUTE_ARRIVE := 2.0

enum State { NORMAL, UNSTICKING, REROUTING }

var _agent: NavigationAgent3D
var _body: Node3D
## 敌人本体若是 CharacterBody3D，就能读到上一帧的接触法线（预防层的输入）。
var _character: CharacterBody3D
var _timer := 0.0

var _state := State.NORMAL
var _state_time := 0.0
var _stuck_tries := 0
## 脱困 / 换路时朝哪一侧绕。每次进入都翻转，保证连续两次不会挤同一个死角。
var _side_sign := 1.0
## 卡死检测窗口内累计的水平位移与时长。
var _window_move := 0.0
var _window_time := 0.0
var _prev_position := Vector3.ZERO
var _has_prev := false
## 本帧调用方是否确实想移动（由 expects_movement 传入）。
var _expects := true
## 换路用的中间点。
var _detour_point := Vector3.ZERO
## 最近一次传入的真实目标（玩家位置）。换路时要基于它算中间点，
## 而那时 _detour_point 正在被当作导航目标用，不能拿它当"最终目标"。
var _last_goal := Vector3.ZERO


func setup(body: Node3D, radius: float, height: float) -> void:
	_body = body
	_character = body as CharacterBody3D
	var agent := NavigationAgent3D.new()
	agent.name = "NavAgent"
	agent.radius = radius
	agent.height = height
	# 保持关闭：开启避障后必须每帧回写 set_velocity，否则代理会以为静止不动。
	# 敌人之间刻意不互相碰撞（collision_mask 不含自身层），分离交给下面这套
	# 防卡死逻辑，避免为 RVO 付出每帧的额外物理开销。
	agent.avoidance_enabled = false
	agent.path_desired_distance = 0.7
	agent.target_desired_distance = 0.7
	body.add_child(agent)
	_agent = agent


## 返回朝 goal 的水平单位方向；导航不可用时返回 fallback。
##
## expects_movement：调用方这一帧是否确实在尝试移动。敌人停在攻击距离上
## 挥砍、或远程兵停在理想射距上，都属于"站着不动但不是卡住" —— 不传 false
## 的话这些情况会被误判成卡死，敌人就会莫名其妙地横向乱走。
func direction_to(
	goal: Vector3, fallback: Vector3, delta: float, expects_movement: bool = true
) -> Vector3:
	if not is_instance_valid(_agent) or not is_instance_valid(_body):
		return fallback
	_expects = expects_movement
	_last_goal = goal
	var position := _body.global_position
	if not _has_prev:
		_prev_position = position
		_has_prev = true

	# ── 导航路径 ──
	# 换路期间把目标换成中间点：这是"走另一条线路"的全部实现。
	_timer -= delta
	var nav_goal := _detour_point if _state == State.REROUTING else goal
	if _timer <= 0.0:
		_timer = REPATH_INTERVAL
		# 目标点必须压到与自身同一水平面。
		# 玩家节点的原点在胶囊中心（离地约 1 米），直接拿来当导航目标会超出
		# target_desired_distance 而被判为"不可达"，路径被截断在玩家脚下 ——
		# 表现就是敌人明明在追，is_target_reachable() 却一直是 false。
		# 导航网格自带高度，压平不会丢任何信息。
		_agent.target_position = Vector3(nav_goal.x, position.y, nav_goal.z)
	var next := _agent.get_next_path_position()
	var flat := Vector3(next.x - position.x, 0.0, next.z - position.z)
	var desired := fallback
	if flat.length_squared() >= MIN_DIRECTION_SQR:
		desired = flat.normalized()

	# ── 卡死状态机 ──
	_update_stuck_state(position, delta)
	if _state == State.UNSTICKING:
		desired = _unstick_direction(desired)
	# 换路不需要覆盖方向：导航目标已经是中间点，沿着它算出的路径走即可。
	return _contact_push(desired)


## 导航是否真的给出了可达路径（探针 / 调试用）。
func has_path() -> bool:
	return is_instance_valid(_agent) and _agent.is_target_reachable()


# ---------------------------------------------------------------- 状态机

func _update_stuck_state(position: Vector3, delta: float) -> void:
	_state_time += delta
	var moved := Vector3(
		position.x - _prev_position.x, 0.0, position.z - _prev_position.z
	).length()
	_prev_position = position
	if moved > TELEPORT_MOVE:
		_window_move = 0.0
		_window_time = 0.0
	else:
		_window_move += moved
		_window_time += delta
	if _window_time < STUCK_WINDOW:
		return

	var progress := _window_move
	_window_move = 0.0
	_window_time = 0.0

	match _state:
		State.NORMAL:
			# 怎么进：窗口内几乎没动，且调用方确实在试图移动。
			if progress >= STUCK_MIN_MOVE * 3.0:
				# 走得很顺，把连续脱困计数清零，下次重新从"第一次卡住"算起。
				_stuck_tries = 0
				return
			if progress >= STUCK_MIN_MOVE or not _expects:
				return
			_enter_unstick()

		State.UNSTICKING:
			# 怎么出（其一）：蹭出来了就回正常，并立刻重新规划路径。
			if progress >= STUCK_MIN_MOVE:
				_leave_to_normal()
				return
			# 怎么出（其二）：单次脱困超时。次数够了就换路，否则换个方向再试。
			if _state_time >= UNSTICK_DURATION:
				_stuck_tries += 1
				if _stuck_tries >= UNSTICK_MAX_TRIES:
					_enter_reroute(position, _last_goal)
				else:
					_enter_unstick()

		State.REROUTING:
			# 怎么出：走到中间点，或者兜底超时。
			var to_point := Vector3(
				_detour_point.x - position.x, 0.0, _detour_point.z - position.z
			).length()
			if to_point <= REROUTE_ARRIVE or _state_time >= REROUTE_DURATION:
				_leave_to_normal()


func _enter_unstick() -> void:
	_state = State.UNSTICKING
	_state_time = 0.0
	_side_sign = -_side_sign


func _leave_to_normal() -> void:
	_state = State.NORMAL
	_state_time = 0.0
	_side_sign = -_side_sign
	# 立刻重算路径：脱困期间是横向走的，缓存的路径已经不代表当前位置。
	_timer = 0.0


## 换路：先在"自己→目标"的侧前方定一个中间点，把导航目标指过去。
func _enter_reroute(position: Vector3, goal: Vector3) -> void:
	var to_goal := Vector3(goal.x - position.x, 0.0, goal.z - position.z)
	if to_goal.length_squared() < MIN_DIRECTION_SQR:
		_leave_to_normal()
		return
	var along := to_goal.normalized() * minf(
		to_goal.length() * REROUTE_ALONG_RATIO, REROUTE_OFFSET * 2.0
	)
	var side := Vector3(-to_goal.z, 0.0, to_goal.x).normalized() * REROUTE_OFFSET * _side_sign
	var point := position + along + side
	# 中间点必须落在可导航区域上，否则路径会被截断，等于没换路。
	# map_get_closest_point 在没有网格时返回原点，用"吸附距离是否合理"来识别
	# 这种情况 —— 直接判 is_zero_approx 会误伤本来就靠近原点的合法点。
	if is_instance_valid(_agent):
		var closest := NavigationServer3D.map_get_closest_point(_agent.get_navigation_map(), point)
		if closest.distance_to(point) < 20.0:
			point = closest
	_detour_point = point
	_state = State.REROUTING
	_state_time = 0.0
	_side_sign = -_side_sign
	_timer = 0.0


# ---------------------------------------------------------------- 方向修正

## 脱困：走期望方向的垂直分量，从夹角里横向蹭出来。
func _unstick_direction(desired: Vector3) -> Vector3:
	var side := Vector3(-desired.z, 0.0, desired.x) * _side_sign
	if side.is_zero_approx():
		return desired
	var blended := side * UNSTICK_SIDE_RATIO + desired * (1.0 - UNSTICK_SIDE_RATIO)
	if blended.is_zero_approx():
		return side.normalized()
	return blended.normalized()


## 预防：顶着障碍时沿接触法线的切向偏出去，而不是继续硬顶。
##
## 读的是上一帧 move_and_slide() 留下的接触。法线由障碍物指向自己，所以
## -desired·away 越大说明越是在正对着墙推；推力按这个比例给，
## 擦着墙走的时候几乎不改动方向，不会把正常沿墙移动也搅乱。
func _contact_push(desired: Vector3) -> Vector3:
	if _character == null:
		return desired
	var count := _character.get_slide_collision_count()
	if count == 0:
		return desired
	var away := Vector3.ZERO
	for index in range(count):
		var normal := _character.get_slide_collision(index).get_normal()
		away += Vector3(normal.x, 0.0, normal.z)
	if away.is_zero_approx():
		return desired
	away = away.normalized()
	var opposing := clampf(-desired.dot(away), 0.0, 1.0)
	if opposing <= 0.0:
		return desired
	var pushed := desired + away * opposing * CONTACT_PUSH
	if pushed.is_zero_approx():
		return desired
	return pushed.normalized()
