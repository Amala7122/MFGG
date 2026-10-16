extends SceneTree
## 震地脉冲（Q）击退的真实场景复现：在**空间战斗测试台**里量"释放一次之后敌人离玩家多远"。
##
## 【为什么不满足于隔离测试】隔离测试（自己在空世界里 `apply_push`）是通过的，
## 但用户在实验场里的实测是"推不开、连续按反而被拉到身边"。两者矛盾说明
## 差异出在**真实环境**：实验场里的敌人由 spawner 生成、由 combat_spatial_controller
## 驱动、姿态机也在跑。所以这条测试必须在真的实验场里量位置，而不是量函数返回值。
##
## 【为什么不在默认验收里】本用例会播放定位音效、建起空间声道池，而引擎关闭顺序会让
## 音效库里的 `.wav` 偶尔被判成"仍在使用"，把一条本来通过的用例变成**间歇性失败**
## （I-041，音效库接入遗留，与本用例逻辑无关）。在 I-041 修好之前按需运行：
##   python -B tools/run_acceptance.py --tests test_shockwave_push
const SpatialScene := preload("res://prototypes/spatial_lab/combat_spatial_lab.tscn")
const ShockwaveScript := preload("res://scripts/shockwave.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	paused = false
	var lab := SpatialScene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for _frame in range(8):
		await process_frame
	paused = false

	lab.set_selection({lab.SHIELD_GUARD_ID: 1})
	await lab.generate_round()
	lab._start_fight()
	paused = false
	for _frame in range(4):
		await process_frame

	var player: CharacterBody3D = lab._player
	_check(is_instance_valid(player), "实验场里存在玩家")
	if not is_instance_valid(player):
		_finish(lab)
		return
	_check(lab._live_enemies.size() == 1, "场上有一只盾卫（实际 %d）" % lab._live_enemies.size())
	if lab._live_enemies.is_empty():
		_finish(lab)
		return

	var guard: CharacterBody3D = lab._live_enemies[0]
	# 把它摆到玩家身前 2 米：这正是 Q 该生效的距离。
	var forward := -player.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	guard.global_position = player.global_position + forward * 2.0
	guard.velocity = Vector3.ZERO
	guard.set("_stagger_time", 0.0)
	for _frame in range(4):
		await physics_frame

	var before := _flat_distance(guard, player)
	_check(before < 3.5, "盾卫确实在贴近距离内（%.2f 米）" % before)

	# 走**真实技能路径**：真的生成一颗 Shockwave 并 perform，参数取自玩家配置。
	var wave: Node3D = ShockwaveScript.new()
	lab.add_child(wave)
	wave.global_position = Vector3(
		player.global_position.x,
		player.global_position.y - 1.0,
		player.global_position.z
	)
	var hits: int = int(wave.call("perform", player.get("skill_radius"),
		player.get("skill_damage"), player.get("skill_push")))
	_check(hits > 0, "脉冲命中了盾卫（命中 %d）" % hits)
	var stagger_after: float = float(guard.get("_stagger_time"))
	var stagger_vel: Vector3 = guard.get("_stagger_velocity")
	print("[震地复现] 命中=", hits, " 击退时长=", stagger_after, " 击退速度=", stagger_vel,
		" 距离前=%.2f" % before)

	var peak := before
	for _frame in range(40):
		await physics_frame
		peak = maxf(peak, _flat_distance(guard, player))
	var after := _flat_distance(guard, player)
	print("[震地复现] 距离后=%.2f 峰值=%.2f" % [after, peak])

	_check(peak > before + 0.8,
		"释放后盾卫被推远过（%.2f → 峰值 %.2f）" % [before, peak])
	_check(after > before - 0.3,
		"40 帧后没有被拉得更近（%.2f → %.2f）" % [before, after])

	# 脉冲自带网格/材质/音效与地面预警；先让它自己收尾再退场，
	# 否则退出时会留下"资源仍在使用"（会被验收当成失败）。
	if is_instance_valid(wave):
		wave.queue_free()
	for _frame in range(6):
		await process_frame
	_finish(lab)


func _flat_distance(a: Node3D, b: Node3D) -> float:
	var d := a.global_position - b.global_position
	d.y = 0.0
	return d.length()


func _finish(lab: Node) -> void:
	paused = false
	if is_instance_valid(lab):
		lab.queue_free()
	for _frame in range(12):
		await process_frame
	print("[震地复现] failures=", _failures)
	quit(1 if _failures else 0)


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
