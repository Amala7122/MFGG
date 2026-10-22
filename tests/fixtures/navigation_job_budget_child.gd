extends SceneTree
## 真实时间子进程夹具：人为阻塞一帧，验证多物理步追赶时共享规划仅推进一次。
const Controller := preload("res://scripts/combat_spatial_controller.gd")

class Job extends RefCounted:
	var done := false
	var calls := 0
	func advance(_deadline_usec: int) -> void:
		calls += 1

class Owner extends RefCounted:
	var _body := CharacterBody3D.new()
	var _job := Job.new()
	func _publish_route() -> void:
		pass

var owner: RefCounted
var frames: Dictionary = {}
var blocked := false
var started := 0
var processes := 0

func _initialize() -> void:
	call_deferred("_setup")

func _setup() -> void:
	paused = false
	owner = Owner.new()
	Controller._jobs.clear()
	Controller._jobs.append(weakref(owner))
	started = Time.get_ticks_msec()

func _physics_process(_delta: float) -> bool:
	if owner == null:
		return false
	var frame := Engine.get_process_frames()
	var row: Dictionary = frames.get(frame, {"physics": 0, "advances": 0})
	row.physics += 1
	var before: int = owner._job.calls
	Controller.process_jobs()
	row.advances += owner._job.calls - before
	frames[frame] = row
	return false

func _process(_delta: float) -> bool:
	if owner == null:
		return false
	paused = false
	processes += 1
	if processes == 10:
		# 子进程保持原生时间推进，产生至少3次真实物理追赶；不操作系统输入。
		OS.delay_msec(110)
		blocked = true
	var caught_up := false
	var valid := true
	for row: Dictionary in frames.values():
		caught_up = caught_up or int(row.physics) >= 3
		valid = valid and int(row.advances) <= 1
	if blocked and caught_up and processes > 16:
		_finish(valid and owner._job.calls > 1, frames)
	elif Time.get_ticks_msec() - started > 3000:
		_finish(false, frames)
	return false

func _finish(passed: bool, detail: Dictionary) -> void:
	Controller._jobs.clear()
	owner._body.free()
	owner = null
	print("[规划渲染帧预算子进程] ", "PASS" if passed else "FAIL", " ", detail)
	quit(0 if passed else 1)
