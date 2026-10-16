extends "res://scripts/nav_steering.gd"
## 架构审查用独立原生路径对照，仅由性能探针装配。
## 继承只为满足正式敌人的 NavSteering 类型接口；不调用父类运行逻辑。
## 普通路径由 NavigationServer3D 搜索并缓存，按 XZ 路点推进。
## 不重做整段身体/地面证明；实际世界碰撞仍由正式敌人 CharacterBody3D 执行。
## 没有局部避让和能力跨越，故只证明普通导航的成本，不能冒充行为验收。

const QUERY_PERIOD := 0.25
const TARGET_ERROR := 0.8
const WAYPOINT_DISTANCE := 0.5

static var native_queries := 0
static var native_query_usec := 0

var _native_body: Node3D
var _native_map := RID()
var _native_path := PackedVector3Array()
var _native_index := 1
var _native_goal := Vector3.ZERO
var _native_has_goal := false
var _native_timer := 0.0
var _native_revision := -1
var _native_force := false


func setup(body: Node3D, _radius: float, _height: float) -> void:
	_native_body = body
	_native_map = body.get_world_3d().navigation_map
	_native_timer = float(body.get_instance_id() % 15) / 60.0
	spatial = null


func repath() -> void:
	_native_force = true
	_native_timer = 0.0


func tick(_delta: float, _can_act: bool, _target: Node3D, _speed: float) -> bool:
	# 正式敌人继续执行自己的近战/远程行为、移动、攻击和动画。
	return false


func ground_velocity(goal: Vector3, desired: Vector3, delta: float) -> Vector3:
	return direction_to(goal, desired, delta, not desired.is_zero_approx()) * desired.length()


func direction_to(
	goal: Vector3, _fallback: Vector3, delta: float, expects_movement: bool = true
) -> Vector3:
	if not is_instance_valid(_native_body):
		return Vector3.ZERO
	_native_timer -= delta
	if not expects_movement:
		return Vector3.ZERO
	var revision := NavigationServer3D.map_get_iteration_id(_native_map)
	if revision == 0:
		return Vector3.ZERO
	var changed := not _native_has_goal or _native_force or _native_revision != revision \
		or Vector2(goal.x - _native_goal.x, goal.z - _native_goal.z).length() > TARGET_ERROR
	if changed and _native_timer <= 0.0:
		var started := Time.get_ticks_usec()
		_native_path = NavigationServer3D.map_get_path(
			_native_map, _native_body.global_position, goal, true
		)
		native_query_usec += Time.get_ticks_usec() - started
		native_queries += 1
		_native_index = 1
		_native_goal = goal
		_native_has_goal = true
		_native_force = false
		_native_revision = revision
		_native_timer = QUERY_PERIOD
		path_requests += 1
	var position := _native_body.global_position
	while _native_index < _native_path.size():
		var waypoint := _native_path[_native_index]
		var toward := Vector3(waypoint.x - position.x, 0.0, waypoint.z - position.z)
		if toward.length() > WAYPOINT_DISTANCE:
			return toward.normalized()
		_native_index += 1
	return Vector3.ZERO


func has_path() -> bool:
	return not _native_path.is_empty() \
		and Vector2(_native_path[-1].x - _native_goal.x, _native_path[-1].z - _native_goal.z).length() < 1.0
