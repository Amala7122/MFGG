extends SceneTree
## 直战入口必须复用正式场景，并在真实 PlayerWeapon 初始化前写入满配状态。

const LabScene := preload("res://prototypes/boss_lab/sediment_titan_boss_lab.tscn")
const PlayerScene := preload("res://scenes/player.tscn")
const RunState := preload("res://scripts/run_state.gd")
const ResonanceScript := preload("res://scripts/resonance.gd")
const CapturePaths := preload("res://scripts/capture_paths.gd")
const AreaClearType: ResonanceType = preload("res://data/resonance/area_clear.tres")
const SingleTargetTemplate: ResonanceType = preload("res://data/resonance/single_target_template.tres")
const ActionCam := preload("res://scripts/cinematic_action_cam.gd")
const EventBus := preload("res://scripts/event_bus.gd")

var _failures := 0
var _boss_deaths := 0
var _stage_clears := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	seed(10420261014)
	var lab := LabScene.instantiate()
	_check(lab.has_node("Enemies/WaveDirector") and lab.has_node("Enemies/EnemySpawner"),
		"直战台继承正式圣所世界与敌人导演")
	_check(lab.has_method("prepare_direct_trial"), "直战台提供可复现的满配准备入口")
	var profile := lab.call("prepare_direct_trial") as Dictionary
	_check(String(profile.get("arena_id", "")) == "sanctum", "直战台固定进入圣所")
	_check(int(profile.get("weapon_level", 0)) == 25, "三类模块各 8 层后实际武器等级为 25")
	for id in ["fire_rate", "damage", "magazine"]:
		_check(RunState.get_upgrade_stacks(id) == 8, "%s 模块写入配置上限" % id)

	var holder := Node3D.new()
	root.add_child(holder)
	current_scene = holder
	var player := PlayerScene.instantiate()
	holder.add_child(player)
	await process_frame
	_check(int(player.call("get_weapon_level")) == 25, "真实玩家武器从 RunState 恢复满级")
	var snapshot := lab.call("refill_player_ammo", player) as Dictionary
	_check(int(snapshot.get("rate_stacks", 0)) == 8 and int(snapshot.get("damage_stacks", 0)) == 8
		and int(snapshot.get("magazine_stacks", 0)) == 8, "真实武器三种模块均为满层")
	_check(int(snapshot.get("ammo", 0)) == 300 and int(snapshot.get("reserve", 0)) == 300,
		"主武器弹匣与备用弹夹补满")
	_check(int(snapshot.get("sniper_ammo", 0)) == 15 and int(snapshot.get("sniper_reserve", 0)) == 40,
		"狙击弹匣与备用弹夹补满")

	current_scene = null
	holder.queue_free()
	lab.free()
	await process_frame

	# 再跑一次完整入口，防止只验证了配置却没验证 F6 启动时序与正式导演投放。
	var runtime_lab := LabScene.instantiate()
	root.add_child(runtime_lab)
	current_scene = runtime_lab
	var boss: Node = null
	for _frame in range(600):
		boss = get_first_node_in_group("boss")
		if boss != null:
			break
		await process_frame
	_check(boss != null and bool(boss.get_meta(&"formal_boss", false)),
		"完整直战场启动后由正式导演投放沉积泰坦")
	if boss != null:
		_check(float(boss.call("get_max_health")) == 360000.0, "直战场中的正式 Boss 为 36 万生命")
		if paused and runtime_lab.has_node("BossTrialLoading"):
			var preparing_position: Vector3 = boss.global_position
			for _frame in range(4):
				await physics_frame
			_check(boss.current_state == boss.State.SPAWN and boss._brain.history.is_empty()
				and boss.global_position.is_equal_approx(preparing_position),
				"准备遮罩下真实暂停 Boss 和技能，预热不能提前消耗第一招")
	var runtime_player := get_first_node_in_group("player")
	_check(runtime_player != null and int(runtime_player.call("get_weapon_level")) == 25,
		"完整直战场生成的玩家持有实际满级武器")
	var breakables := get_nodes_in_group("destructible_props")
	_check(not breakables.is_empty(), "正式圣所掩体接入公共可破坏物契约")
	if boss != null and not breakables.is_empty():
		_check(bool(breakables[0].call("can_break", boss._p("slam_break_power"))),
			"正式 Boss 的砸地破坏强度能处理主场景掩体")

	# 直接验证用户实际遇到的闭环：出土结束后，放大 Boss 必须能用接近跃击或
	# 普通追击显著缩短距离，不能在 no_landing / relocate 中永久静止。
	if boss != null and runtime_player != null:
		runtime_player.max_health = 1000000.0
		runtime_player.health = runtime_player.max_health
		runtime_player.set_physics_process(false)
		var durability_before: float = float(runtime_player.health) + float(runtime_player.shield)
		for _frame in range(300):
			if boss.current_state != boss.State.SPAWN:
				break
			await physics_frame
		_check(boss.current_state != boss.State.SPAWN, "正式 Boss 出土流程会结束")
		if DisplayServer.get_name() != "headless":
			_check(not runtime_lab.has_node("BossMaterialWarmup") and runtime_lab._warmup_resources.size() > 0,
				"预热节点回收、材质与网格保留至本局结束，不能回收后重新首次编译")
		var initial_distance := _flat_distance(boss.global_position, runtime_player.global_position)
		_check(initial_distance >= 25.0, "正式 Boss 在远处出场，留出读取开场跃击的视野")
		var closest_distance := initial_distance
		var leap_seen := false
		var opening_captured := false
		var opening_air_captured := false
		var melee_captured := false
		var warning_frame := -1
		var air_frame := -1
		var impact_frame := -1
		var opening_origin := Vector3.ZERO
		var opening_impact := Vector3.ZERO
		var opening_landing := Vector3.ZERO
		var planned_arc_height := 0.0
		var measured_arc_height := 0.0
		var opening_recovery_recorded := false
		var opening_recovery_result := ""
		var opening_landing_error := -1.0
		var opening_landed_on_floor := false
		var planned_window := 0.0
		for frame in range(600):
			await physics_frame
			if not is_instance_valid(boss):
				break
			if not boss._brain.history.is_empty() and warning_frame < 0:
				warning_frame = frame
				_check(boss.current_state == boss.State.LEAP_WINDUP,
					"首次开场请求发布预警后，同帧不能被待机逻辑覆盖")
				opening_origin = boss.global_position
				opening_landing = boss._leap_plan.get("landing", opening_origin)
				planned_arc_height = float(boss._leap_plan.get("arc_height", 0.0))
				planned_window = boss._p("leap_windup") + float(boss._leap_plan.get("flight", 0.0))
				if boss.current_state != boss.State.LEAP_WINDUP:
					break
			if warning_frame >= 0 and not opening_recovery_recorded:
				_check(boss._brain.history.size() == 1,
					"第一条开场跃击记录必须自己执行，不能由后续技能替代验收")
			if not opening_captured and boss.current_state == boss.State.LEAP_WINDUP:
				opening_captured = await _capture_boss_frame("01_opening_leap_warning", boss, runtime_player)
			if boss.current_state == boss.State.LEAP_AIR and air_frame < 0:
				air_frame = frame
			if boss.current_state == boss.State.LEAP_AIR:
				var leap_progress: float = clampf(boss._leap_elapsed / boss._leap_flight, 0.0, 1.0)
				var flight_baseline_y := lerpf(opening_origin.y, opening_landing.y, leap_progress)
				measured_arc_height = maxf(measured_arc_height, boss.global_position.y - flight_baseline_y)
			if not opening_air_captured and boss.current_state == boss.State.LEAP_AIR \
				and boss._leap_elapsed >= boss._leap_flight * 0.48:
				opening_air_captured = await _capture_boss_frame("02_opening_leap_air", boss, runtime_player)
			if not opening_recovery_recorded and air_frame >= 0 \
				and boss.current_state == boss.State.LEAP_RECOVERY:
				opening_recovery_recorded = true
				opening_recovery_result = boss._brain.last_result
				opening_landing_error = boss.global_position.distance_to(opening_landing)
				opening_landed_on_floor = boss.is_on_floor()
			if warning_frame >= 0 and impact_frame < 0 \
				and float(runtime_player.health) + float(runtime_player.shield) < durability_before:
				impact_frame = frame
				opening_impact = boss.global_position
			if not melee_captured and boss.current_state in [boss.State.ATK_SLAM, boss.State.ATK_SWEEP] \
				and boss._attack_area.visible:
				melee_captured = await _capture_boss_frame("03_stable_melee_warning", boss, runtime_player)
			closest_distance = minf(closest_distance, _flat_distance(boss.global_position, runtime_player.global_position))
			leap_seen = leap_seen or boss.current_state in [boss.State.LEAP_WINDUP, boss.State.LEAP_AIR, boss.State.LEAP_RECOVERY]
			for event: Dictionary in boss._brain.history:
				leap_seen = leap_seen or String(event.get("skill", "")) == "leap"
		_check(leap_seen, "正式放大 Boss 会实际发动接近玩家的跃击")
		var first_skill := ""
		var first_reason := ""
		if not boss._brain.history.is_empty():
			first_skill = String(boss._brain.history[0].get("skill", ""))
			first_reason = String(boss._brain.history[0].get("reason", ""))
		_check(first_skill == "leap" and first_reason == "opening_leap",
			"正式 Boss 的第一招固定为开场跃击")
		_check(warning_frame >= 0 and air_frame > warning_frame,
			"开场跃击显示预警后必须实际进入空中，不能只有地面效果")
		_check(impact_frame > air_frame and _flat_distance(opening_origin, opening_impact) >= 5.0,
			"开场跃击必须完成可见位移并在落地帧结算")
		_check(planned_arc_height >= 4.5 and measured_arc_height >= planned_arc_height * 0.8,
			"开场跃击必须有相对地面清晰可见的离地弧高，不能贴地滑行")
		_check(durability_before - (runtime_player.health + runtime_player.shield) >= 90.0,
			"静止在锁定落点内的玩家会实际吃到跃击伤害")
		var actual_window := float(impact_frame - warning_frame) / float(Engine.physics_ticks_per_second)
		var actual_windup := float(air_frame - warning_frame) / float(Engine.physics_ticks_per_second)
		var actual_flight := float(impact_frame - air_frame) / float(Engine.physics_ticks_per_second)
		_check(absf(actual_window - planned_window) <= 0.08,
			"开场跃击的预警到伤害窗口与配置一致")
		print("[沉积泰坦 Boss 直战台] 开场撤离窗口：计划 %.3fs，实测 %.3fs（蓄力 %.3fs + 飞行 %.3fs）"
			% [planned_window, actual_window, actual_windup, actual_flight])
		print("[沉积泰坦 Boss 直战台] 开场跃击弧高：计划 %.3fm，实测 %.3fm"
			% [planned_arc_height, measured_arc_height])
		print("[沉积泰坦 Boss 直战台] 开场落地：result=%s error=%.3fm floor=%s"
			% [opening_recovery_result, opening_landing_error, opening_landed_on_floor])
		_check(closest_distance <= initial_distance - 5.0 or closest_distance <= 7.0,
			"正式 Boss 出土后能持续接近玩家，不会卡在生成区域")
		_check(not (boss._steering.spatial.status == "relocate" and boss.velocity.length() < 0.05
			and closest_distance > 8.0), "正式 Boss 不会以无落点状态永久停在远处")

		# 共鸣清场不伤Boss；A4.1 重招承诺窗口与狂暴禁止重建泥盾。
		boss._remove_mud_shield()
		var shield_allowed: bool = not boss.is_enraged and not boss._heavy_window
		var boss_health_before := float(boss.call("get_health"))
		var resonance := ResonanceScript.new()
		runtime_lab.add_child(resonance)
		resonance.set("_player", runtime_player)
		resonance.set_resonance_type(AreaClearType)
		var resonance_hits: int = resonance._apply_burst_damage(boss.global_position, 20.0, 999999.0, 50.0, 2.0)
		_check(resonance.get_resonance_type_id() == &"area_clear"
			and SingleTargetTemplate.target_mode == ResonanceType.TargetMode.SINGLE_TARGET,
			"共鸣以资源定义类型，已预留不污染清场规则的单体类型入口")
		_check(resonance_hits == 0 and is_equal_approx(float(boss.call("get_health")), boss_health_before),
			"范围清场共鸣即使使用极高基础伤害也不会伤害 Boss")
		_check(bool(boss.has_mud_shield) == shield_allowed and boss.mud_shield_visual.visible == shield_allowed,
			"共鸣即时响应遵守重招窗口与狂暴无盾边界")
		await _verify_live_resonance(runtime_lab, boss, runtime_player)

	if is_instance_valid(boss):
		boss._stop_action()
		boss.set_physics_process(false)
	current_scene = null
	runtime_lab.queue_free()
	await process_frame
	print("[沉积泰坦 Boss 直战台] failures=", _failures)
	quit(1 if _failures else 0)


func _verify_live_resonance(lab: Node, boss: Node3D, player: Node) -> void:
	# 用户实际操作的是玩家持有的共鸣，包含特效、控场、电影镜头与导演结算。
	boss._stop_action()
	boss.current_state = boss.State.IDLE
	boss.ai_enabled = false
	boss.set_physics_process(false)
	await process_frame
	boss.died.connect(func(_enemy): _boss_deaths += 1)
	var bus: Node = EventBus.instance
	var on_clear := func(_stage): _stage_clears += 1
	bus.stage_cleared.connect(on_clear)
	var boss_id := boss.get_instance_id()
	var lab_id := lab.get_instance_id()
	var hp := float(boss.get_health())
	var resonance: Node = player._resonance
	for charge_ratio in [1.0, 2.0]:
		boss._remove_mud_shield()
		resonance._overflow_cap = resonance._max_energy * 2.0
		resonance._energy = 0.0
		resonance.add_energy(resonance._max_energy * charge_ratio)
		player._weapon.refill_all_ammo()
		player._weapon._ammo = player._weapon.get_capacity() - 5
		var reload_press := _key(KEY_R, true)
		Input.parse_input_event(reload_press)
		Input.flush_buffered_events()
		lab._unhandled_input(reload_press)
		player._update_combat(1.0 / 60.0)
		_check(player._weapon.is_reloading() and resonance.is_ready(),
			"满共鸣时 R 只换弹，保留共鸣能量")
		print("[Boss 共鸣输入] charge=", charge_ratio, " reload=", player._weapon.is_reloading(),
			" energy=", resonance._energy, " just_R=", Input.is_action_just_pressed("reload"))
		Input.parse_input_event(_key(KEY_R, false))
		Input.flush_buffered_events()
		await process_frame
		var burst_press := _key(KEY_C, true)
		_check(burst_press.is_action_pressed("resonance_burst"), "C 映射真实共鸣动作")
		Input.parse_input_event(burst_press)
		Input.flush_buffered_events()
		player._update_combat(1.0 / 60.0)
		if not player._is_aim_captured():
			# 无界面环境不能捕获鼠标时，仍执行同一玩家的完整爆发。
			resonance.perform_burst()
		_check(is_zero_approx(float(resonance._energy)) and player.is_cinematic_locked(),
			"100% / 200% 玩家共鸣实际消耗能量并进入特写")
		Input.parse_input_event(_key(KEY_C, false))
		Input.flush_buffered_events()
		_check(is_instance_valid(boss) and boss.get_instance_id() == boss_id
			and is_equal_approx(float(boss.get_health()), hp) and boss.has_mud_shield,
			"100% / 200% 完整共鸣保留原 Boss 与生命，并触发泥盾")
		ActionCam.dismiss_active()
		await process_frame
		_check(is_instance_valid(lab) and lab.get_instance_id() == lab_id
			and current_scene == lab and _boss_deaths == 0 and _stage_clears == 0,
			"共鸣与 R 换弹均不重载直战场、不触发 Boss 死亡或阶段结算")
	bus.stage_cleared.disconnect(on_clear)


func _key(code: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	return event


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _capture_boss_frame(label: String, boss: Node3D, player: Node3D) -> bool:
	var has_artifact_dir := false
	for argument in OS.get_cmdline_user_args():
		has_artifact_dir = has_artifact_dir or argument.begins_with("--artifact-dir=")
	if DisplayServer.get_name() == "headless" or not has_artifact_dir:
		return false
	var camera := Camera3D.new()
	boss.get_tree().current_scene.add_child(camera)
	var focus := (boss.global_position + player.global_position) * 0.5
	camera.global_position = focus + Vector3(0.0, 20.0, 18.0)
	camera.look_at(focus + Vector3.UP * 0.8)
	camera.make_current()
	await RenderingServer.frame_post_draw
	CapturePaths.ensure_dir("boss_combat")
	var error := root.get_texture().get_image().save_png(CapturePaths.file("boss_combat/%s.png" % label))
	camera.queue_free()
	return error == OK
