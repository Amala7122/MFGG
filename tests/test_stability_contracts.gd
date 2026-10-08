extends SceneTree

const ConfigUtil := preload("res://scripts/game_config.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const GameFlowUtil := preload("res://scripts/game_flow.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const MinimapUtil := preload("res://scripts/minimap.gd")
const PlayerRigUtil := preload("res://scripts/player_rig.gd")
const RangedEnemyScene: PackedScene = preload("res://scenes/ranged_enemy.tscn")
const MeleeEnemyScene: PackedScene = preload("res://scenes/melee_enemy.tscn")
const PlayerScene: PackedScene = preload("res://scenes/player.tscn")
const DisplaySettingsUtil := preload("res://scripts/display_settings.gd")

var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	paused = false
	await process_frame
	_verify_graphics_order()
	_verify_display_defaults()
	_verify_hit_owner_payload()
	_verify_minimap_enemy_directions()
	_verify_player_gait_cadence()
	await _verify_target_camera()
	await _verify_player_fall_guard()
	await _verify_enemy_fall_kill()
	await _verify_fall_kill_credit()
	await _verify_player_death_transition()
	quit(1 if _failed else 0)


func _verify_graphics_order() -> void:
	var low := ConfigUtil.get_dictionary("graphics.presets.low")
	var medium := ConfigUtil.get_dictionary("graphics.presets.medium")
	var high := ConfigUtil.get_dictionary("graphics.presets.high")
	var keys := ["msaa", "shadow_quality", "shadow_max_distance"]
	for key in keys:
		var a := float(low.get(key, 0.0))
		var b := float(medium.get(key, 0.0))
		var c := float(high.get(key, 0.0))
		if a > b or b > c:
			_fail("画质档位 %s 未按 low <= medium <= high 排列：%s/%s/%s" % [key, a, b, c])
	var ssao := [
		bool(low.get("ssao", false)), bool(medium.get("ssao", false)),
		bool(high.get("ssao", false)),
	]
	if int(ssao[0]) > int(ssao[1]) or int(ssao[1]) > int(ssao[2]):
		_fail("SSAO 档位顺序错误：%s" % [ssao])
	else:
		print("[稳定性测试] 画质档位顺序通过")


func _verify_display_defaults() -> void:
	var expected := {
		"display/window/size/viewport_width": 1152,
		"display/window/size/viewport_height": 648,
		"display/window/size/window_width_override": 1920,
		"display/window/size/window_height_override": 1080,
	}
	for key in expected:
		var actual := int(ProjectSettings.get_setting(key, 0))
		if actual != int(expected[key]):
			_fail("显示默认值 %s 应为 %s，实际 %s" % [key, expected[key], actual])
	if DisplaySettingsUtil.DEFAULT_RESOLUTION != Vector2i(1920, 1080):
		_fail("显示设置默认窗口不是 1920×1080")
	if DisplaySettingsUtil.UI_SCALES != [0.85, 1.0, 1.15, 1.3]:
		_fail("UI 缩放档位发生意外变化")
	else:
		print("[稳定性测试] 1080p 显示默认值通过")


func _verify_hit_owner_payload() -> void:
	var received: Array = []
	var callback := func(headshot: bool, killed: bool) -> void:
		received.append([headshot, killed])
	EventBusUtil.instance.connect(EventBusUtil.SIG_HIT_CONFIRMED, callback)
	EventBusUtil.emit_hit_confirmed(true, false)
	EventBusUtil.instance.disconnect(EventBusUtil.SIG_HIT_CONFIRMED, callback)
	if received != [[true, false]]:
		_fail("命中事件载荷错误：%s" % [received])
	else:
		print("[稳定性测试] 命中事件载荷通过")


func _verify_minimap_enemy_directions() -> void:
	var minimap := MinimapUtil.new()
	minimap.size = Vector2(MinimapUtil.PANEL_SIZE, MinimapUtil.PANEL_SIZE)
	minimap.set("_enemy_direction_limit", 5)
	var threshold_ok := (
		bool(minimap.call("_should_show_enemy_directions", 1))
		and bool(minimap.call("_should_show_enemy_directions", 4))
		and not bool(minimap.call("_should_show_enemy_directions", 0))
		and not bool(minimap.call("_should_show_enemy_directions", 5))
	)
	var center := minimap.size * 0.5
	var right_edge := minimap.call("_ray_to_content_edge", center, Vector2.RIGHT) as Vector2
	var expected_x := (
		MinimapUtil.PANEL_SIZE - MinimapUtil.FRAME - MinimapUtil.ENEMY_DIRECTION_MARKER_INSET
	)
	var edge_ok := (
		absf(right_edge.x - expected_x) < 0.01
		and absf(right_edge.y - center.y) < 0.01
	)
	minimap.free()
	if not threshold_ok or not edge_ok:
		_fail("小地图残敌方向标阈值或边缘定位错误")
	else:
		print("[稳定性测试] 小地图残敌方向标通过")


func _verify_player_gait_cadence() -> void:
	var rig := PlayerRigUtil.new()
	rig.walk_cadence = 7.4
	rig.run_cadence = 12.0
	var slow := float(rig.call("_cadence_for_speed", 2.5, 5.0, 8.5))
	var walk := float(rig.call("_cadence_for_speed", 5.0, 5.0, 8.5))
	var run := float(rig.call("_cadence_for_speed", 8.5, 5.0, 8.5))
	rig.free()
	if not (slow < walk and walk < run):
		_fail("玩家步频没有随实际移动速度递增：%.2f / %.2f / %.2f" % [slow, walk, run])
	else:
		print("[稳定性测试] 玩家步频随速度递增通过")


func _verify_target_camera() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var target := CharacterBody3D.new()
	target.name = "Target"
	world.add_child(target)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	target.add_child(pivot)
	var player_camera := Camera3D.new()
	player_camera.name = "Camera3D"
	pivot.add_child(player_camera)
	# 玩家本体相机不是根视口的 current camera（相机由玩家自己持有并切换）。
	player_camera.current = false
	var enemy := RangedEnemyScene.instantiate() as CharacterBody3D
	world.add_child(enemy)
	enemy.set("target", target)
	await process_frame
	var selected := enemy.call("_target_camera") as Camera3D
	if selected != player_camera:
		_fail("远程敌人没有使用目标玩家相机")
	else:
		print("[稳定性测试] 远程敌人相机归属通过")
	world.queue_free()
	await process_frame


func _verify_player_fall_guard() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var player := PlayerScene.instantiate() as CharacterBody3D
	player.position = Vector3(4.0, 2.0, 6.0)
	world.add_child(player)
	await process_frame
	var safe := Vector3(4.0, 2.0, 6.0)
	player.set("_last_safe_position", safe)
	player.set("_has_safe_position", true)
	player.global_position = Vector3(20.0, -100.0, 20.0)
	var recovered := bool(player.call("_recover_if_below_world"))
	var expected := safe + Vector3.UP * 1.1
	if not recovered or player.global_position.distance_to(expected) > 0.01:
		_fail("玩家掉出世界后没有返回最近安全落脚点")
	else:
		print("[稳定性测试] 玩家坠落保险通过")
	world.queue_free()
	await process_frame


## 与玩家那份对称：玩家掉出去被送回来，敌人掉出去则必须【真的消失】。
## 判而不杀会让波次推进器把它永久留在存活名单里（它永远不退出场景树）。
func _verify_enemy_fall_kill() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var enemy := RangedEnemyScene.instantiate() as CharacterBody3D
	world.add_child(enemy)
	await process_frame
	# 站在地面上不远处：这里若判死，正常起伏的山地会把整波敌人清空。
	enemy.global_position = Vector3(6.0, TerrainFieldUtil.height_at(6.0, 6.0) + 2.0, 6.0)
	if bool(enemy.call("_kill_if_below_world")):
		_fail("敌人在正常地面上方被误判为坠落")
		world.queue_free()
		await process_frame
		return
	enemy.global_position = Vector3(20.0, -100.0, 20.0)
	if not bool(enemy.call("_kill_if_below_world")):
		_fail("敌人掉出场地后没有判定死亡")
		world.queue_free()
		await process_frame
		return
	await process_frame
	if is_instance_valid(enemy):
		_fail("判死的敌人没有退出场景树 —— 波次会继续把它算作存活")
	else:
		print("[稳定性测试] 敌人坠落判死通过")
	world.queue_free()
	await process_frame


## 坠亡的击杀归属：坠下去这一下本身没有加害者，不能因为我懒就把人头送出去。
## 语义是"刚被人打过才记给他"（多半正是那一发把它轰下去的），一次没挨过打就不记。
## 这一条日后很可能在重构 _credit_killer 时被改成无条件记账 —— 那时这里会先响。
##
## 兵种取近战：退场那一条（_verify_enemy_fall_kill）用的是远程，两者合起来
## 两个兵种都覆盖到了。
func _verify_fall_kill_credit() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var player := PlayerScene.instantiate() as Node3D
	world.add_child(player)
	await process_frame
	if not player.is_in_group("player"):
		# 归属逻辑靠"最近玩家"找人，先保证他确实在玩家组里。
		player.add_to_group("player")
	var credited := MeleeEnemyScene.instantiate() as CharacterBody3D
	var loner := MeleeEnemyScene.instantiate() as CharacterBody3D
	credited.name = "Credited"
	loner.name = "Loner"
	world.add_child(credited)
	world.add_child(loner)
	var before := int(player.get("kill_count"))
	credited.set("_took_damage", true)
	credited.global_position = Vector3(20.0, -100.0, 20.0)
	loner.global_position = Vector3(24.0, -100.0, 24.0)
	# 【不能靠等帧】坠落判定挂在 _physics_process 上，而这个 headless SceneTree
	# 脚本环境并不真的推进物理 tick —— await process_frame / physics_frame 都能
	# 顺利返回，却一个物理帧都没发生，断言于是静默退化成"没判死"，看上去像实现坏了
	#（这条坑定位过一轮）。直接驱动 _physics_process 一样走得到服务端门控、
	# 判定早退与 tree_exited，且不依赖引擎调度。
	for _i in 30:
		for body in [credited, loner]:
			# is_queued_for_deletion：引擎在 queue_free 之后同样不再把物理帧交给它。
			if is_instance_valid(body) and not body.is_queued_for_deletion():
				body._physics_process(1.0 / 60.0)
	await process_frame
	var gain := int(player.get("kill_count")) - before
	if gain != 1:
		_fail("坠落击杀归属错误：应只把挨过打的那个记给玩家，实际增加 %d" % gain)
	else:
		print("[稳定性测试] 坠落击杀归属通过")
	world.queue_free()
	await process_frame


func _verify_player_death_transition() -> void:
	var world := Node3D.new()
	root.add_child(world)
	GameFlowUtil.instance.set("state", GameFlowUtil.State.PLAYING)
	var player := PlayerScene.instantiate() as CharacterBody3D
	world.add_child(player)
	await process_frame
	player.set("_death_duration", 0.4)
	var received: Array = []
	var callback := func(survival: float, kills: int) -> void:
		received.append([survival, kills])
	EventBusUtil.instance.connect(EventBusUtil.SIG_PLAYER_DIED, callback)
	player.call("_die")
	var delayed: bool = (
		received.is_empty()
		and bool(player.get("_dying"))
		and int(GameFlowUtil.instance.get("state")) == GameFlowUtil.State.DYING
	)
	player.call("_update_death", 0.2)
	delayed = delayed and received.is_empty()
	player.call("_update_death", 0.2)
	var completed := received.size() == 1 and bool(player.get("_death_event_sent"))
	EventBusUtil.instance.disconnect(EventBusUtil.SIG_PLAYER_DIED, callback)
	paused = false
	world.free()
	if not delayed or not completed:
		_fail("玩家死亡结算没有等待倒地过渡完成")
	else:
		print("[稳定性测试] 玩家死亡过渡时序通过")


func _fail(message: String) -> void:
	_failed = true
	push_error("[稳定性测试] " + message)
