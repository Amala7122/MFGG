extends "res://scripts/nav_steering.gd"
## 仅供同进程A/B：原生分支逐字保留修改前needs_route，其他导航实现完全共用。
static var elapsed_usec := 0
static var calls := 0
var native_query := false

func needs_route(goal: Vector3) -> bool:
	var start := Time.get_ticks_usec()
	var result := _native_needs_route(goal) if native_query else super.needs_route(goal)
	elapsed_usec += Time.get_ticks_usec() - start
	calls += 1
	return result

func _native_needs_route(goal: Vector3) -> bool:
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
