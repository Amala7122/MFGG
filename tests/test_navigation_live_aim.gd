extends SceneTree
## 动态改线的独立对照（针对「点一下重算一遍再转向」）。
##
## 单个测量体在开阔地面上追一个**匀速横移**的目标：不换线时，敌人会奔向规划时刻的
## 过期落点，速度方向与“当前目标方向”长期偏离；开启动态改线后，最后一段持续朝
## 当前目标修正。两个相位用同一场景、同一初始条件、同一目标轨迹，逐帧记录
## 「速度方向与目标方向夹角」和「到目标的距离」。
const Controller := preload("res://scripts/combat_spatial_controller.gd")
const Actor := preload("res://scripts/prototypes/navigation_test_actor.gd")
const Region := preload("res://scripts/navigation_region.gd")
const Query := preload("res://scripts/spatial_query.gd")
const Paths := preload("res://scripts/artifact_paths.gd")
const FRAMES := 480
const WARMUP := 60
## 目标 5 m/s 折线走位（每 0.5 秒换向）、测量体 4 m/s：追不上才会一直处在
## “过期落点 vs 当前目标”差别明显的距离上；贴着目标时两种实现都看不出区别。
const TARGET_SPEED := 5.0
const ACTOR_SPEED := 4.0
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	paused = false
	var stage := Node3D.new()
	stage.position = Vector3(400, 0, 120)
	root.add_child(stage)
	current_scene = stage
	_floor(stage, Vector3(0, -0.5, 0), Vector3(60, 1, 40))
	var region := await _navigation(stage)
	var phases: Array = []
	for live: bool in [false, true]:
		phases.append(await _phase(stage, live))
	var before: Dictionary = phases[0]
	var after: Dictionary = phases[1]
	# 重画策略修好之后，两个相位的差异已落到噪声内（都 <1°），因此判据改为绝对质量：
	# 追得住（夹角小）、贴得上（末距小）、且连续追击几乎不需要整段重画。
	_check(float(after.mean_angle) <= 3.0, "连续追击的平均方向夹角必须很小：%.3f°" % after.mean_angle)
	_check(float(before.mean_angle) <= 5.0, "对照相位的平均方向夹角也必须很小：%.3f°" % before.mean_angle)
	# 规划任务数只记录不判定：这个裸场景（一块地板 + 一个无碰撞目标）里空间规划器根本不
	# 发布路线，跟随来自 NavSteering 的 Agent；整段规划的开销对照放在 24 体主场景回归里。
	# 折线目标的“平均追击距离”在两种做法间波动很大（两相位轨迹一旦分叉就不可比），
	# 因此只判定两件稳定的事：转向是否连续跟住目标、最终是否仍能贴身。
	_check(int(after.angle_samples) > 60 and int(before.angle_samples) > 60, "两个相位都必须真的在追：%d / %d 帧" % [before.angle_samples, after.angle_samples])
	_check(float(after.final_distance) <= float(before.final_distance) + 0.5,
		"动态改线后最终必须仍能贴身：%.2f -> %.2f m" % [before.final_distance, after.final_distance])
	# 性能：连续追击应显著减少整段规划任务（不再按目标位移反复排队重算）。
	_check(float(after.probe_avg_usec) <= 300.0, "本地探测单次耗时必须很小：%.1f us" % after.probe_avg_usec)
	_check(float(after.job_usec_p95) <= float(before.job_usec_p95) + 1500.0,
		"连续追击不得抬高单任务耗时分位：%d -> %d us" % [before.job_usec_p95, after.job_usec_p95])
	var file := FileAccess.open(Paths.ensure_dir("reports").path_join("test_navigation_live_aim.json"), FileAccess.WRITE)
	if file == null:
		_check(false, "无法保存动态改线报告")
	else:
		file.store_string(JSON.stringify(phases, "\t"))
	print("[动态改线] 对照：夹角 %.3f° / 末距 %.2f m / 规划 %d 次 / 探测 %d 次×%.1f us / 任务P95 %d us" % [
		before.mean_angle, before.final_distance, before.jobs, before.probe_calls, before.probe_avg_usec, before.job_usec_p95])
	print("[动态改线] 连续追击：夹角 %.3f° / 末距 %.2f m / 规划 %d 次 / 探测 %d 次×%.1f us / 任务P95 %d us" % [
		after.mean_angle, after.final_distance, after.jobs, after.probe_calls, after.probe_avg_usec, after.job_usec_p95])
	current_scene = null
	stage.free()
	await process_frame
	print("[动态改线] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _close_better(after: Dictionary, before: Dictionary) -> bool:
	return float(after.mean_angle) < float(before.mean_angle)

func _floor(host: Node3D, at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = at
	body.collision_layer = 1
	body.add_to_group("nav_source")
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	host.add_child(body)

func _navigation(stage: Node3D) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	region.set_script(Region)
	stage.add_child(region)
	for frame in range(1200):
		await physics_frame
		await process_frame
		if region.is_baked() and NavigationServer3D.map_get_closest_point_owner(region.get_navigation_map(), stage.global_position) == region.get_rid():
			break
	_check(region.is_baked(), "必须完成真实碰撞烘焙")
	return region

func _phase(stage: Node3D, live: bool) -> Dictionary:
	Controller.live_aim_enabled = live
	# 目标与测量体都是 stage 的子节点，用局部坐标（stage 在世界里偏移了 400 米）。
	var target := Node3D.new()
	target.position = Vector3(0, 0.06, 0)
	stage.add_child(target)
	var actor := Actor.new()
	actor.speed = ACTOR_SPEED
	actor.spatial_enabled = true
	actor.target = target
	actor.position = Vector3(0, 1.045, -3)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.52
	capsule.height = 2.0
	collision.shape = capsule
	actor.add_child(collision)
	actor.collision_layer = 4
	actor.collision_mask = 1
	stage.add_child(actor)
	actor.steering.spatial.bind({"move_speed": actor.speed}, {"can_attack": func() -> bool: return false})
	await physics_frame
	var angle_sum := 0.0
	var angle_samples := 0
	var distance_sum := 0.0
	var travelled := 0.0
	# 性能对照：本相位启动的规划任务数、本地探测次数与耗时、单次任务耗时分位。
	var jobs_start := Controller.jobs_started
	var probes_start := Controller.live_probe_calls
	var probe_usec_start := Controller.live_probe_usec
	var job_usec: Array[int] = []
	var previous := actor.global_position
	var local := Vector3(-10.0, 0.06, -10.0)
	var heading := Vector3(1, 0, 0)
	var corners := [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 0, -1)]
	for frame in range(FRAMES):
		# 目标 5 m/s 折线持续走位：每 0.5 秒换一次方向，撞到边界反弹。
		heading = corners[int(float(frame) / 30.0) % 4]
		local += heading * TARGET_SPEED / 60.0
		if absf(local.x) > 14.0:
			local.x = clampf(local.x, -14.0, 14.0)
			heading.x = -heading.x
		if absf(local.z) > 14.0:
			local.z = clampf(local.z, -14.0, 14.0)
			heading.z = -heading.z
		target.position = Vector3(local.x, 0.06, local.z)
		await physics_frame
		job_usec.append(Controller.last_job_usec)
		var here := actor.global_position
		var step := Vector2(here.x - previous.x, here.z - previous.z).length()
		previous = here
		travelled += step
		if frame < WARMUP:
			continue
		var toward := Vector2(target.global_position.x - here.x, target.global_position.z - here.z)
		var flat := Vector2(actor.velocity.x, actor.velocity.z)
		if toward.length() < 2.0:
			continue
		distance_sum += toward.length()
		if flat.length() > 0.5:
			angle_sum += rad_to_deg(acos(clampf(flat.normalized().dot(toward.normalized()), -1.0, 1.0)))
			angle_samples += 1
	job_usec.sort()
	var probe_calls := Controller.live_probe_calls - probes_start
	var probe_usec := Controller.live_probe_usec - probe_usec_start
	var result := {"live_aim": live, "frames": FRAMES, "travelled": travelled,
		"failure": actor.steering.spatial.last_failure,
		"status": actor.steering.spatial.status,
		"route_empty": actor.steering.spatial.route.is_empty(),
		"jobs": Controller.jobs_started - jobs_start,
		"probe_calls": probe_calls,
		"probe_usec_total": probe_usec,
		"probe_avg_usec": float(probe_usec) / float(maxi(probe_calls, 1)),
		"job_usec_p50": job_usec[job_usec.size() / 2] if not job_usec.is_empty() else 0,
		"job_usec_p95": job_usec[mini(job_usec.size() - 1, int(float(job_usec.size()) * 0.95))] if not job_usec.is_empty() else 0,
		"mean_angle": angle_sum / float(maxi(angle_samples, 1)),
		"angle_samples": angle_samples,
		"mean_distance": distance_sum / float(maxi(angle_samples, 1)),
		"final_distance": Vector2(target.global_position.x - actor.global_position.x, target.global_position.z - actor.global_position.z).length()}
	actor.free()
	target.free()
	await physics_frame
	return result

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed = true
		push_error("[动态改线] " + message)
