extends SceneTree
## 使用默认 AI 与真实攻击，不抑制停步 / 选招来绕过空间决策。
const Scene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const Query := preload("res://scripts/spatial_query.gd")
const Retreat := preload("res://scripts/spatial_retreat_planner.gd")
var lab: Node3D
var failed := false

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	lab = Scene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for i in range(8): await process_frame
	lab._crowd_motion.button_pressed = false
	if not OS.get_cmdline_user_args().has("--cliff-only"):
		for id: String in [lab.MUD_GOLEM_ID, lab.FAST_BEAST_ID, lab.SEDIMENT_TITAN_ID]:
			await _platform(id, 2.0)
		_raise_platform()
		for id: String in [lab.MUD_GOLEM_ID, lab.FAST_BEAST_ID, lab.SEDIMENT_TITAN_ID]:
			await _platform(id, 5.0)
	for id: String in [lab.MUD_GOLEM_ID, lab.FAST_BEAST_ID]:
		await _deep_pit(id)
	await _boss_pit()
	await _flying_pit()
	current_scene = null
	lab.free()
	paused = false
	print("[T03 策略] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _spawn(id: String, ground: Vector3, target_at: Vector3) -> CharacterBody3D:
	seed(303003)
	lab.set_selection({id: 1})
	await lab.generate_round()
	var enemy: CharacterBody3D = lab._live_enemies[0]
	_check(enemy.get_script() != null and enemy.get_node_or_null("CollisionShape3D") != null, "敌人脚本及真实碰撞必须成功加载")
	if enemy.get_script() == null:
		quit(1)
		return enemy
	enemy.ai_enabled = false
	enemy.position = ground + Vector3.UP * (float(Query.dimensions(enemy).half_height) + 0.08)
	lab._player.position = target_at
	var facing := ground - target_at
	lab._player.rotation.y = atan2(-facing.x, -facing.z)
	lab._start_fight()
	# 保留玩家真实碰撞和 SpringArm 收缩，否则晶针没有实体可命中、相机会穿进坑壁。
	lab._player.set_physics_process(false)
	lab._player.set_process(false)
	paused = false
	for i in range(250): await physics_frame
	return enemy

func _platform(id: String, height: float) -> void:
	var z := -0.5 if id == lab.SEDIMENT_TITAN_ID else -1.45
	var enemy := await _spawn(id, Vector3(6, 0, z), Vector3(6, height + 1.08, -3.0))
	enemy.ai_enabled = true
	var time := -1.0
	for i in range(1800):
		lab._player._damage_invulnerability = 0.0
		await physics_frame
		if lab.get_stats_snapshot().received_hits > 0:
			time = float(i) / 60
			break
	_check(time >= 0.0, "%s 默认 AI 在 %sm 有坡平台建立实际接战；位置 %s / %s" % [id, height, enemy.position, enemy._steering.spatial.last_failure])
	print("[T03 策略] ", id, " height=", height, " first_hit=", time, " at=", enemy.position)
	paused = true

func _raise_platform() -> void:
	var platform: StaticBody3D = lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/Platform2m")
	platform.position.y = 2.5
	(platform.get_node("CollisionShape3D").shape as BoxShape3D).size.y = 5.0
	var ramp: StaticBody3D = lab.get_node("NavigationRegion3D/SpatialLayout/Geometry/PlatformRamp")
	ramp.position.y = 2.5
	ramp.rotation.z = -atan(5.0 / 6.0)
	(ramp.get_node("CollisionShape3D").shape as BoxShape3D).size.x = sqrt(61.0)
	lab.get_node("NavigationRegion3D").bake_navigation_mesh(false)

func _deep_pit(id: String) -> void:
	var start := Vector3(15, 0, -12)
	var enemy := await _spawn(id, start, Vector3(15, -3.92, -17))
	var origin := enemy.position
	# 两个概率端点都用真实角色与物理路径验证，避免随机通过。
	enemy._steering.spatial.profile = enemy._steering.spatial.profile.duplicate(true)
	enemy._steering.spatial.profile.rim_exposure_chance = 0.0
	enemy.ai_enabled = true
	var lowest := 0.0
	var furthest := 0.0
	for i in range(1200):
		await physics_frame
		lowest = minf(lowest, Query.feet(enemy).y)
		furthest = maxf(furthest, Vector2(enemy.position.x - origin.x, enemy.position.z - origin.z).length())
	var threat: Dictionary = lab._player.get_combat_threat()
	var covered := not Retreat.exposed(enemy, enemy.global_position, threat)
	_check(lowest > -0.2, id + "不能凭拥有跳跃 / 破坏能力主动进入无法脱困的 5m 坑")
	_check(furthest <= 3.5 and covered, id + "持续停留在坑边盲区，不能连续撤离越走越远")
	_check(lab.get_stats_snapshot().received_hits == 0, id + "不能隔着不可达高差空放技能并结算伤害")
	enemy._steering.spatial.profile.rim_exposure_chance = 1.0
	var probed := false
	var returned := false
	for i in range(900):
		await physics_frame
		if OS.get_cmdline_user_args().has("--debug-t03") and i % 180 == 0:
			print("[rim trace] ", id, " at=", enemy.position, " anchor=", enemy._steering.spatial._rim_anchor, " expose=", enemy._steering.spatial._rim_expose, " route=", enemy._steering.spatial._retreat_route)
		var exposed := Retreat.exposed(enemy, enemy.global_position, threat)
		probed = probed or exposed
		returned = returned or (probed and not exposed and not enemy._steering.spatial._rim_expose)
		_check(Query.feet(enemy).y > -0.2, id + "胆大探头也不能掉进无法脱困的坑")
		if returned: break
	_check(probed and returned, id + "胆大窗口真实进入射界并回到盲区")
	print("[T03 策略] ", id, " deep_pit lowest=", lowest, " furthest=", furthest, " cover=", covered, " probe=", probed, "/", returned)
	paused = true

func _boss_pit() -> void:
	var enemy := await _spawn(lab.SEDIMENT_TITAN_ID, Vector3(15, 0, -12), Vector3(15, -3.92, -17))
	enemy.ai_enabled = true
	var entered := false
	for i in range(1800):
		lab._player._damage_invulnerability = 0.0
		await physics_frame
		entered = entered or (enemy.is_on_floor() and Query.feet(enemy).y < -4.8)
		if entered and lab.get_stats_snapshot().received_hits > 0: break
	_check(entered and lab.get_stats_snapshot().received_hits > 0, "具有真实返程能力的 Boss 下到坑底并实际攻击：%s / %s" % [enemy.position, enemy._steering.spatial.last_failure])
	_check(not enemy._steering.spatial.escape_reserved.is_empty(), "Boss 下坑后保留返程跳跃冷却")
	# 玩家占住原入口时，也要从附近合法位置返回，而不是重叠落到玩家头上。
	lab._player.position = Vector3(15, 1.08, -12)
	if OS.get_cmdline_user_args().has("--debug-t03"):
		print("[exit trace] entry=", enemy._steering.spatial._entry_takeoff, " anchor=", enemy._steering.spatial._exit_anchor, " escape=", enemy._steering.spatial._escape)
	var escaped := false
	for i in range(1800):
		await physics_frame
		if enemy.is_on_floor() and Query.feet(enemy).y > -0.1 and enemy._steering.spatial.escape_reserved.is_empty():
			escaped = true
			break
	_check(escaped, "玩家出坑后 Boss 用实际跳跃返回上层：%s / %s" % [enemy.position, enemy._steering.spatial.last_failure])
	print("[T03 策略] Boss pit entered=", entered, " hits=", lab.get_stats_snapshot().received_hits, " escaped=", escaped, " at=", enemy.position)
	paused = true

func _flying_pit() -> void:
	var enemy := await _spawn(lab.HORNET_ID, Vector3(15, 3, -10), Vector3(15, -3.92, -17))
	enemy.ai_enabled = true
	var above_pit := 0
	var bite := false
	for i in range(1800):
		lab._player._damage_invulnerability = 0.0
		await physics_frame
		if OS.get_cmdline_user_args().has("--debug-t03") and i % 300 == 0:
			print("[air trace] at=", enemy.position, " state=", enemy.current_state, " needles=", enemy.remaining_needles, " radius=", enemy._air.radius, " steer=", enemy._air.steer(Vector3.FORWARD, 1.0 / 60))
		var offset: Vector3 = enemy.position - lab._player.position
		if Vector2(offset.x, offset.z).length() < 2.7 and enemy.position.y < 1.0:
			above_pit += 1
		bite = lab.get_stats_snapshot().incoming.has(lab.HORNET_ID + "/俯冲撕咬")
		if bite and above_pit > 240: break
	_check(above_pit > 240 and lab.get_stats_snapshot().received_hits >= 2 and bite, "飞行敌人持续追到坑上方，射击后仍能实际俯冲攻击：%s" % enemy.position)
	_check(enemy._air.radius < enemy._p("strafe_distance"), "狭窄空域收缩盘旋半径")
	print("[T03 策略] Flyer pit frames=", above_pit, " hits=", lab.get_stats_snapshot().received_hits, " bite=", bite, " radius=", enemy._air.radius, " at=", enemy.position)
	paused = true

func _check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error("[T03 策略] " + message)
