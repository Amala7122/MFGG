extends SceneTree
const Planner := preload("res://scripts/spatial_route_planner.gd")
var failed := false
class SlowPlanner extends Planner:
	var calls: Array[Vector3] = []
	func walk_route(_origin: Vector3, destination: Vector3, _exclude: Array[RID] = []) -> Dictionary:
		calls.append(destination)
		OS.delay_usec(300)
		if destination.x == 24.0:
			return {"kind": "walk", "points": PackedVector3Array([Vector3.ZERO, destination]), "landing": destination, "cost": 1.0}
		return {}
func _initialize() -> void:
	call_deferred("_run")
func _check(ok: bool, message: String) -> void:
	if not ok: failed = true; push_error(message)
func _run() -> void:
	for _frame in range(3): await process_frame
	paused = false
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var body := CharacterBody3D.new()
	var target := CharacterBody3D.new()
	world.add_child(body)
	world.add_child(target)
	target.position.x = 100
	var job := SlowPlanner.new()
	job.begin(body, preload("res://data/combat_spatial/ground.tres"), [], RID(), target, {})
	job.attack_pose = func(_pose: Transform3D): return false
	for index in range(1, 25): job._stances.append(Vector3(index, 0, 0))
	job.advance(Time.get_ticks_usec() + 1200)
	_check(not job.done and not job.calls.is_empty() and job.calls.size() < 25, "一次小预算不能连续扫完全部慢站位")
	for _index in range(50):
		job.advance(Time.get_ticks_usec() + 1200)
		if job.done: break
	_check(job.done and job.calls.size() == 25 and job.expansions == 1, "跨预算续跑不重复扩展或丢弃候选")
	_check(not job.result.is_empty() and job.result.segments[0].landing == Vector3(24, 0, 0), "分步后仍找到原顺序最后的可行站位")
	for index in range(1, job.calls.size()): _check(job.calls[index].x == float(index), "站位遍历顺序保持")
	print("[导航规划续跑] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
