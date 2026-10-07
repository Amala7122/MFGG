class_name NavSteering
extends RefCounted
const GroundMovement := preload("res://scripts/ground_movement.gd")
const SpatialController := preload("res://scripts/combat_spatial_controller.gd")
const SpatialProfile := preload("res://scripts/combat_spatial_profile.gd")
const DefaultSpatialProfile := preload("res://data/combat_spatial/ground.tres")
var spatial: RefCounted
## 敌人寻路辅助：包装一个 NavigationAgent3D，给出"朝目标该往哪走"的水平方向。
##
## 用代码创建 NavigationAgent3D、而不是给敌人场景挂节点 —— 与 EnemyRig /
## EnemyVisuals 的既有做法一致，敌人 .tscn 保持干净。
##
## 导航尚未同步时回退直线追击；已到达可走路径终点则停止。
## 原型若需继续贴近目标，ground_velocity 会检查完整身体通道与脚下支撑，
## 不能靠无条件直线回退硬顶不可达平台或走出悬崖。
##
## 导航起点与目标都按网格表面高度对齐。本体原点在胶囊中心，直接用它
## 推进路径会让第一个地面路径点始终无法抵达，敌人不断回头，形成运动抖动。
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
## 必须明显大于导航网格的 agent_radius（1.2），否则算出来还是同一条路径。
const REROUTE_OFFSET := 4.5
## 中间点取在"自己→目标"直线上的比例：0.5 = 中点。太靠近目标就起不到绕路作用。
const REROUTE_ALONG_RATIO := 0.5
## 走到距中间点这么近就算抵达，提前结束换路。
const REROUTE_ARRIVE := 2.0

enum State { NORMAL, UNSTICKING, REROUTING }

var _agent: NavigationAgent3D
var _nav_origin: Node3D
var _body_height := 2.0
var _body_radius := 0.5
var _body: Node3D
## 敌人本体若是 CharacterBody3D，就能读到上一帧的接触法线（预防层的输入）。
var _character: CharacterBody3D
var _timer := 0.0

var _state := State.NORMAL
var _state_time := 0.0
var _stuck_tries := 0
## 脱困 / 换路时朝哪一侧绕。每次进入都翻转，保证连续两次不会挤同一个死角。
var _side_sign := 1.0
## 卡死检测窗口的起点与时长。
##
## 不能累计每帧位移：敌人在树干边左右抖动时，虽然始终没离开原地，累计路程
## 仍会不断增长，最终被误判为“正在前进”。窗口首尾的净位移才代表真的脱困。
var _window_origin := Vector3.ZERO
var _window_time := 0.0
var _prev_position := Vector3.ZERO
var _has_prev := false
## 本帧调用方是否确实想移动（由 expects_movement 传入）。
var _expects := true
## 换路用的中间点。
var _detour_point := Vector3.ZERO
## 最近一次由调用方传入的真实目标（近战是玩家，远程是短程移动目标）。换路时
## 要基于它算中间点，而那时 _detour_point 正在被当作导航目标用，不能拿它当
## “最终目标”。
var _last_goal := Vector3.ZERO
## 一次脱困固定横移方向；不能每帧跟着重算的路径旋转，否则会左右互顶。
var _last_direction := Vector3.FORWARD
var _unstick_heading := Vector3.ZERO


func setup(body: Node3D, radius: float, height: float) -> void:
	_body = body
	_character = body as CharacterBody3D
	_body_height = height
	_body_radius = radius
	# Agent 使用父节点的位置推进路径。敌人原点在胶囊中心，路径点却在地面；
	# 若直接挂在本体下，0.3 米到达容差永远覆盖不到脚下的第一个路径点。
	_nav_origin = Node3D.new()
	_nav_origin.name = "NavOrigin"
	body.add_child(_nav_origin)
	_nav_origin.position.y = -height * 0.5
	var agent := NavigationAgent3D.new()
	agent.name = "NavAgent"
	# 这里只是局部避让代理尺寸；普通寻路的实际通行宽度由烘焙网格的
	# NavigationMesh.agent_radius 决定，不能靠这里的 radius 缩小窄缝。
	agent.radius = radius
	agent.height = height
	# 大型平底身体在坡角不能像胶囊那样擦角；经过通道中部再转入坡脚。
	if radius >= 1.3:
		agent.path_postprocessing = NavigationPathQueryParameters3D.PATH_POSTPROCESSING_EDGECENTERED
	# 保持关闭：开启避障后必须每帧回写 set_velocity，否则代理会以为静止不动。
	# 敌人之间刻意不互相碰撞（collision_mask 不含自身层），分离交给下面这套
	# 防卡死逻辑，避免为 RVO 付出每帧的额外物理开销。
	agent.avoidance_enabled = false
	# 拐点容差过大时会提前跳过转角，角色从导航网格边缘抄近路撞上实体障碍。
	agent.path_desired_distance = 0.3
	agent.target_desired_distance = 0.7
	_nav_origin.add_child(agent)
	_agent = agent
	if _character != null:
		var assigned: Resource = body.get_meta(&"combat_spatial_profile") if body.has_meta(&"combat_spatial_profile") else null
		if assigned == null:
			for property in body.get_property_list():
				if property.name == "combat_spatial_profile":
					assigned = body.get("combat_spatial_profile")
		if not assigned is SpatialProfile:
			assigned = DefaultSpatialProfile
		spatial = SpatialController.new()
		spatial.setup(_character, assigned, self)


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
		_window_origin = position
		_has_prev = true
	if not expects_movement:
		_state = State.NORMAL
		_state_time = 0.0
		_stuck_tries = 0
		_window_origin = position
		_window_time = 0.0
		_prev_position = position
		_timer = 0.0
		return Vector3.ZERO

	# ── 导航路径 ──
	var nav_map := _agent.get_navigation_map()
	var map_ready := NavigationServer3D.map_get_iteration_id(nav_map) > 0
	if map_ready:
		# 地图已同步但还没有可走面时，closest_point 会返回原点；不能把它当目标。
		map_ready = NavigationServer3D.map_get_closest_point_owner(nav_map, position).is_valid()
	if map_ready:
		# 烘焙网格有栅格高度误差，胶囊在坡上也有离地间隙。按脚下网格的高度
		# 对齐起点，并保留实际水平位置；体型缩放和坡面都不会妨碍路径点推进。
		var feet := _body.to_global(Vector3(0.0, -_body_height * 0.5, 0.0))
		var surface := NavigationServer3D.map_get_closest_point(nav_map, feet)
		_nav_origin.global_position = Vector3(position.x, surface.y, position.z)
	# 换路期间把目标换成中间点：这是"走另一条线路"的全部实现。
	_timer -= delta
	var nav_goal := _detour_point if _state == State.REROUTING else goal
	if not map_ready:
		_timer = 0.0
	elif _timer <= 0.0:
		_timer = REPATH_INTERVAL
		# 目标同样取导航表面高度，不能用敌人的高度去覆盖远处坡面的高度。
		var surface_goal := nav_goal
		if map_ready:
			surface_goal = NavigationServer3D.map_get_closest_point(nav_map, nav_goal)
		_agent.target_position = surface_goal
	var desired := fallback
	if map_ready:
		var next := _agent.get_next_path_position()
		# 部分路径的终点也算 finished；不能在此退回直线继续顶不可达平台。
		if _agent.is_navigation_finished():
			_state = State.NORMAL
			_window_origin = position
			_window_time = 0.0
			return Vector3.ZERO
		var flat := Vector3(next.x - position.x, 0.0, next.z - position.z)
		if flat.length_squared() >= MIN_DIRECTION_SQR:
			desired = flat.normalized()

	# ── 卡死状态机 ──
	if _state != State.UNSTICKING and not desired.is_zero_approx():
		_last_direction = desired.normalized()
	_update_stuck_state(position, delta)
	if _state == State.UNSTICKING:
		desired = _unstick_direction(desired)
	# 换路不需要覆盖方向：导航目标已经是中间点，沿着它算出的路径走即可。
	return _contact_push(desired)


## 导航是否真的给出了可达路径（探针 / 调试用）。
func has_path() -> bool:
	return is_instance_valid(_agent) and _agent.is_target_reachable()


## 同层且能直达时保留绕行/群体风格；高低差或路径拐角优先沿导航走。
func ground_velocity(goal: Vector3, desired: Vector3, delta: float) -> Vector3:
	return spatial.adjust_ground_motion(goal, desired, delta) if spatial != null else raw_ground_velocity(goal, desired, delta)


func tick(delta: float, can_act: bool, target: Node3D, speed: float) -> bool:
	return spatial != null and spatial.tick(delta, can_act, target, speed)


func raw_ground_velocity(goal: Vector3, desired: Vector3, delta: float) -> Vector3:
	if desired.is_zero_approx():
		direction_to(goal, Vector3.ZERO, delta, false)
		return Vector3.ZERO
	var route := direction_to(goal, desired.normalized(), delta)
	if route.is_zero_approx():
		# 真正到达目标附近时仍允许安全的局部后退 / 绕行。
		# 部分路径终点不能沿旧的战术方向直接走向不可达目标。
		var nearby := Vector2(goal.x - _body.global_position.x, goal.z - _body.global_position.z).length() <= 0.8
		if nearby and not needs_route(goal) and _safe_local_motion(desired, delta):
			return desired
		# 公共网格给大型敌人留了余量。到达小台面旁的路径终点后，小体型仍可
		# 沿实际有支撑、完整身体无遮挡的地面接近到自身普攻距离。
		if _can_approach(goal):
			var closer := goal - _body.global_position
			closer.y = 0.0
			return closer.normalized() * desired.length()
		return Vector3.ZERO
	var direct := goal - _body.global_position
	direct.y = 0.0
	if needs_route(goal) or (not direct.is_zero_approx() and route.dot(direct.normalized()) < 0.95):
		return route * desired.length()
	return desired


func _safe_local_motion(desired: Vector3, delta: float) -> bool:
	if _character == null or not _character.is_on_floor():
		return false
	var motion := desired * maxf(delta, 0.04)
	if _character.test_move(_character.global_transform, motion) and GroundMovement.step_landing(_character, _character.global_transform, motion).is_empty():
		return false
	var feet := _body.to_global(Vector3(0, -_body_height * 0.5, 0)) + motion
	var side := Vector3(-motion.z, 0, motion.x).normalized() * _body_radius * 0.75
	for point in [feet, feet + side, feet - side]:
		var hit := _body.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(point + Vector3.UP * GroundMovement.STEP_HEIGHT, point + Vector3.DOWN * GroundMovement.STEP_HEIGHT, 1))
		if hit.is_empty() or (hit.normal as Vector3).dot(_character.up_direction) < cos(_character.floor_max_angle):
			return false
	return true


func _can_approach(goal: Vector3) -> bool:
	if _character == null or not _character.is_on_floor():
		return false
	var offset := goal - _body.global_position
	offset.y = 0.0
	if offset.length() <= 0.7:
		return false
	var motion := offset.normalized() * 0.12
	if _character.test_move(_character.global_transform, motion) and GroundMovement.step_landing(_character, _character.global_transform, motion).is_empty():
		return false
	var feet := _body.to_global(Vector3(0, -_body_height * 0.5, 0)) + motion
	var hit := _body.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(feet + Vector3.UP * GroundMovement.STEP_HEIGHT, feet + Vector3.DOWN * GroundMovement.STEP_HEIGHT, 1))
	return not hit.is_empty() and hit.normal.dot(_character.up_direction) >= cos(_character.floor_max_angle)


func needs_route(goal: Vector3) -> bool:
	if not is_instance_valid(_agent) or not is_instance_valid(_body):
		return false
	var nav_map := _agent.get_navigation_map()
	if NavigationServer3D.map_get_iteration_id(nav_map) == 0:
		return false
	var feet := _body.to_global(Vector3(0, -_body_height * 0.5, 0))
	var floor_here := NavigationServer3D.map_get_closest_point(nav_map, feet)
	var floor_goal := NavigationServer3D.map_get_closest_point(nav_map, goal)
	if absf(floor_here.y - floor_goal.y) > 0.4:
		return true
	return not _body.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(_body.global_position, goal, 1)).is_empty()


# ---------------------------------------------------------------- 状态机

func _update_stuck_state(position: Vector3, delta: float) -> void:
	_state_time += delta
	var moved := Vector3(
		position.x - _prev_position.x, 0.0, position.z - _prev_position.z
	).length()
	_prev_position = position
	if moved > TELEPORT_MOVE:
		_window_origin = position
		_window_time = 0.0
	else:
		_window_time += delta
	if _window_time < STUCK_WINDOW:
		return

	var progress := Vector3(
		position.x - _window_origin.x, 0.0, position.z - _window_origin.z
	).length()
	_window_origin = position
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
	var side := Vector3(-_last_direction.z, 0.0, _last_direction.x) * _side_sign
	_unstick_heading = (
		side * UNSTICK_SIDE_RATIO + _last_direction * (1.0 - UNSTICK_SIDE_RATIO)
	).normalized()


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
	return desired if _unstick_heading.is_zero_approx() else _unstick_heading


## 预防：顶着障碍时沿接触法线的切向偏出去，而不是继续硬顶。
##
## 读的是上一帧 move_and_slide() 留下的接触。法线由障碍物指向自己，所以
## -desired·away 越大说明越是在正对着墙推；推力按这个比例给，
## 擦着墙走的时候几乎不改动方向，不会把正常沿墙移动也搅乱。
func _contact_push(desired: Vector3) -> Vector3:
	if _character == null:
		return desired
	# 薄板挡脚边虽有竖直法线，却是可跨低坎；先确认完整身体能通过再决定绕墙。
	if _character.is_on_floor() and not desired.is_zero_approx() and not GroundMovement.step_landing(_character, _character.global_transform, desired * 0.1).is_empty():
		return desired
	var count := _character.get_slide_collision_count()
	if count == 0:
		return desired
	var away := Vector3.ZERO
	for index in range(count):
		var normal := _character.get_slide_collision(index).get_normal()
		# 地面的水平法线在斜坡上并不为零；归一化后会变成完整的“墙壁推力”。
		# 只绕不可行走的表面，避免坡面三角形切换时不断改变前进方向。
		if normal.dot(_character.up_direction) >= cos(_character.floor_max_angle):
			continue
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
