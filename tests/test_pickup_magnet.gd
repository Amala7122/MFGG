extends SceneTree
## 掉落物拾取磁力回归。
##
## 【这条测试防的是什么】武器等级完全由"捡到几个模块"决定，而掉落物落在敌人死亡处。
## 磁力（pickup.magnet_range / magnet_speed）如果写错，症状是"看起来加了，其实捡不到" ——
## 而那正是本轮要修的问题本身，所以必须有可重复判定的证据。
##
## 覆盖：
##   1. 配置真的被读到（不是代码里的默认值）；
## 2. 超出吸引半径时掉落物【不动】—— 磁力不能变成全场自动吸附；
##    （否则"要不要前压到尸体附近"这个策略决定会被一起抹掉）
##   3. 进入半径后向玩家飞行，最终被结算并释放；
##   4. 满血（拾取无效）时停在原地，不被消耗 —— 【拾取契约】。
const Config := preload("res://scripts/game_config.gd")
const PickupScene: PackedScene = preload("res://scenes/pickup.tscn")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


## 玩家替身：Targeting 读不到 health 时按存活处理，所以只要在 "player" 组里就够。
class StubPlayer:
	extends CharacterBody3D
	var heal_calls := 0
	var refuse_heal := false

	func try_heal(_amount: float) -> bool:
		if refuse_heal:
			return false
		heal_calls += 1
		return true


func _run() -> void:
	var world := Node3D.new()
	world.name = "MagnetWorld"
	root.add_child(world)

	var player := StubPlayer.new()
	player.add_to_group("player")
	world.add_child(player)

	var range_expected := Config.get_float("pickup.magnet_range", -1.0)
	var speed_expected := Config.get_float("pickup.magnet_speed", -1.0)
	var lifetime_expected := Config.get_float("pickup.lifetime", -1.0)
	_check(range_expected > 0.0, "配置里有 pickup.magnet_range")
	_check(speed_expected > 0.0, "配置里有 pickup.magnet_speed")

	# 1. 配置接线：节点读到的必须等于配置值，而不是脚本里的兜底默认值。
	var probe := _spawn_pickup(world, Vector3.ZERO)
	await process_frame
	_check(is_equal_approx(probe.magnet_range, range_expected),
		"磁力半径来自配置（读到 %.2f，配置 %.2f）" % [probe.magnet_range, range_expected])
	_check(is_equal_approx(probe.magnet_speed, speed_expected), "磁力速度来自配置")
	_check(is_equal_approx(probe.lifetime, lifetime_expected), "存活时长来自配置")
	probe.free()
	await process_frame

	# 2. 半径之外不吸附：放在 2.5 倍半径处，跑 30 帧，位置必须基本不变。
	var far := _spawn_pickup(world, Vector3(0, 0, range_expected * 2.5))
	player.global_position = Vector3.ZERO
	var far_start := far.global_position
	for _frame in range(30):
		_step(far)
	_check(far != null and is_instance_valid(far), "半径外不会被消耗")
	if is_instance_valid(far):
		var drift := far.global_position.distance_to(far_start)
		_check(drift < 0.6, "半径外不产生位移（实际漂移 %.2f 米，只有待机浮动）" % drift)
		far.free()
	await process_frame

	# 3. 半径之内飞向玩家并结算。
	player.global_position = Vector3.ZERO
	player.heal_calls = 0
	var near_pickup := _spawn_pickup(world, Vector3(0, 1.0, range_expected * 0.7))
	var start_distance := near_pickup.global_position.distance_to(player.global_position)
	var collected_frame := -1
	for frame in range(120):
		if not is_instance_valid(near_pickup):
			collected_frame = frame
			break
		_step(near_pickup)
		await process_frame
	# 「已释放」而不是「还挂在场上」：磁力的终点是一次真实结算。
	_check(collected_frame >= 0, "进入半径后被飞向玩家并结算（起始距离 %.2f 米）" % start_distance)
	_check(collected_frame >= 0 and collected_frame < 90,
		"结算发生在 1.5 秒以内（实际第 %d 帧）" % collected_frame)
	_check(player.heal_calls == 1, "结算走的是玩家自己的拾取接口（try_heal 调用 %d 次）" % player.heal_calls)

	# 4. 拾取无效（满血）时**就地放下、不再跟随**。
	#    这是修掉的一个 bug：旧行为会让满血时捡到的血包挂在身上跟着跑，
	#    等玩家一掉血就被"顺手"吃掉（玩家失去"什么时候用"的决定权）。
	player.refuse_heal = true
	player.global_position = Vector3.ZERO
	var blocked := _spawn_pickup(world, Vector3(0, 1.0, range_expected * 0.7))
	for _frame in range(90):
		if is_instance_valid(blocked):
			_step(blocked)
		await process_frame
	_check(is_instance_valid(blocked) and not blocked.consumed,
		"满血时掉落物不被消耗（留在原地等玩家回来拿）")
	_check(is_instance_valid(blocked) and not blocked.follow_until_usable,
		"默认不跟随（pickup.follow_until_usable = false）")

	# 4b. 玩家走远后，放下的掉落物必须留在原地 —— 这就是"不跟随"的可判定证据。
	if is_instance_valid(blocked):
		var settled_pos := blocked.global_position
		player.global_position = Vector3(0, 0, -60.0)
		for _frame in range(60):
			if is_instance_valid(blocked):
				_step(blocked)
			await process_frame
		var moved := blocked.global_position.distance_to(settled_pos)
		_check(moved < 0.6,
			"用不上而放下的掉落物不再跟随玩家（玩家走开 60 米后位移仅 %.2f 米，只有待机浮动）" % moved)
		_check(not blocked.consumed, "放下的掉落物没有被顺手消耗")
		blocked.free()

	print("[掉落物磁力] failures=", _failures)
	quit(1 if _failures else 0)


## 用固定步长驱动掉落物。
##
## 【为什么不靠自动 _process】本轮用 `--script` 跑 SceneTree，节点的空闲处理不由
## 这里保证；项目里的界面测试也是显式 `call("_process", ...)`（见 test_ui_surfaces）。
## 手动步进同时让"第几帧结算"这件事变成确定值，测试不会因帧率变化而漂移。
func _step(pickup: Node) -> void:
	if is_instance_valid(pickup):
		pickup.call("_process", 1.0 / 60.0)


func _spawn_pickup(parent: Node, at: Vector3) -> Area3D:
	var pickup := PickupScene.instantiate() as Area3D
	parent.add_child(pickup)
	pickup.global_position = at
	pickup.call("configure", 0)
	pickup.set_process(false)
	return pickup


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
