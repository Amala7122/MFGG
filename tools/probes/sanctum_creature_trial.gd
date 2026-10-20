extends SceneTree
## 在新主入口跑完整六种混编三波；先观察AI，随后用真实武器射击并自动选卡。
## 玩家补血仅用于持续测试，不改变敌人、武器伤害或波次预算。
const WorldScene := preload("res://scenes/sanctum_main.tscn")
const Flow := preload("res://scripts/game_flow.gd")
const Pool := preload("res://scripts/object_pool.gd")
const RunState := preload("res://scripts/run_state.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Health := preload("res://scripts/health_util.gd")
const Config := preload("res://scripts/game_config.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")

var _failed := false
var _shots := 0
var _hits := 0
var _hurt_frames := 0
var _seen := {}
var _choices := 0
var _start_positions := {}
var _distance_travelled := {}
var _observed_states := {}
var _world: Node3D
var _player: CharacterBody3D
var _director: Node
var _aim_point := Vector3.ZERO
var _spawn_serial := 0
var _variations := {}
var _unstick_input_frames := 0
var _walk_direction := Vector3.ZERO
var _walk_started := 0
var _boss_frame := -1
var _rage_frame := -1
var _boss_states := {}
var _boss_facts := {}
var _boss_shots := 0
var _boss_front_attacks := 0
var _boss_rage_attacks := 0
var _boss_finisher := false
var _poison_seen := false
var _expected_small_kills := 0
var _density_samples: Array = []
var _peak_alive := {}
var _last_sample_ms := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	node_added.connect(_seed_enemy)
	seed(251019)
	for frame in range(3):
		await process_frame
	Flow.instance.state = Flow.State.MENU
	paused = false
	_world = WorldScene.instantiate()
	root.add_child(_world)
	current_scene = _world
	for frame in range(12):
		await process_frame
	Flow.instance._enter_menu()
	await _capture("01_main_menu")
	Flow.instance.start_run()
	await scene_changed
	_world = current_scene
	for frame in range(12):
		await process_frame
	_player = get_first_node_in_group("player") as CharacterBody3D
	_director = _world.get_node("Enemies/WaveDirector")
	_check(_player != null and Flow.is_playing(), "真实开始流程生成玩家并进入新场景")
	if _player == null:
		quit(1)
		return
	_player.max_health = 100000.0
	_player.health = 100000.0
	# 起招观察阶段停用自动小精灵，避免尚未进入技能就被自动枪线打断；
	# 后续完整通关恢复原自动攻击，敌人生命/伤害/技能参数不改。
	_player._wisp.set_process(false)
	_player._wisp.set_physics_process(false)
	# 固定观察点，避免昆虫接触把玩家一路推动，导致远程怪始终不在观察射程。
	# 射击阶段恢复完整玩家物理与走位。
	_player.set_physics_process(false)
	_director._random.seed = 251019
	for wave in range(1, _director._total_waves + 1):
		_expected_small_kills += _director._count_for_wave(wave)
	var cleared := false
	var captured_combat := false
	for frame in range(maxi(14400, _expected_small_kills * 180)):
		await process_frame
		if _director.get_state() == _director.State.FIGHT:
			var wave_key := str(_director._wave)
			var alive: int = _director._alive.size()
			_peak_alive[wave_key] = maxi(int(_peak_alive.get(wave_key, 0)), alive)
			if alive > int(_director._spawn_cfg.max_alive):
				_check(false, "实际同时在场小怪不得超过配置上限")
			if frame % 60 == 0:
				var now := Time.get_ticks_msec()
				_density_samples.append({"frame": frame, "wave": _director._wave, "alive": alive, "budget": _director._spawn_budget, "wall_ms_per_60_frames": now - _last_sample_ms if _last_sample_ms > 0 else 0})
				_last_sample_ms = now
		if _player.health < 99999.9:
			_hurt_frames += 1
		elif _player.shield < _player.max_shield - 0.01:
			_hurt_frames += 1
		_player.health = 100000.0
		if not _poison_seen and not get_nodes_in_group("enemy_hazards").is_empty():
			_poison_seen = true
			await _poison_overview(get_nodes_in_group("enemy_hazards")[0])
		for enemy: Node3D in get_nodes_in_group("enemies"):
			if bool(enemy.get_meta(&"formal_boss", false)):
				await _observe_boss(enemy, frame)
				continue
			var entry: Dictionary = enemy.get_meta(&"enemy_entry", {})
			var species := String(entry.get("species", "legacy"))
			_seen[species] = true
			if not _observed_states.has(species):
				_observed_states[species] = {}
			var states: Dictionary = enemy.State
			for label: String in states:
				if int(states[label]) == int(enemy.current_state):
					_observed_states[species][label] = true
			var id := enemy.get_instance_id()
			if not _start_positions.has(id):
				_start_positions[id] = enemy.global_position
				_variations[str(id)] = {"species": species, "seed": enemy.get_meta(&"crowd_seed", -1), "values": enemy.get_meta(&"individual_variation", {})}
			_distance_travelled[species] = maxf(float(_distance_travelled.get(species, 0.0)), enemy.global_position.distance_to(_start_positions[id]))
		if Flow.instance.state == Flow.State.UPGRADE_PICK:
			_check(get_nodes_in_group("enemy_death_effect").is_empty(), "选卡出现时死亡演出已结束")
			var expected := 0
			for wave in range(1, _choices + 2): expected += _director._count_for_wave(wave)
			_check(_player.kill_count == expected, "每波选卡前必须实际清空全部预算，不能由看门狗跳过")
			if _choices == 0:
				await _capture("03_upgrade_after_death")
			# 选择界面实际提供的首个选项，不注入额外天赋。
			var buttons: Array = Flow.instance._actions.get_children()
			if not buttons.is_empty():
				buttons[0].emit_signal("pressed")
			_choices += 1
			continue
		if Flow.instance.state == Flow.State.STAGE_CLEAR:
			_check(get_nodes_in_group("enemy_death_effect").is_empty(), "结算出现时死亡演出已结束")
			await _capture("04_stage_clear")
			cleared = true
			break
		if not Flow.is_playing():
			_walk_input(Vector3.ZERO)
			continue
		if frame == 1750:
			await _overview()
		if frame == 1800:
			_player.set_physics_process(true)
			_player._damage_invulnerability = 0.0
			_player._wisp.set_process(true)
			_player._wisp.set_physics_process(true)
		if frame >= 1800:
			# 用真实移动输入换枪线；先前一直向右会把观察玩家带出战区。
			var pos := _player.global_position
			var bound := float(_director._arena.extent) * 0.65
			if absf(pos.x) > bound or absf(pos.z) > bound:
				_walk_input(Vector3(-pos.x, 0.0, -pos.z))
			elif _unstick_input_frames > 0:
				_walk_input(_walk_direction)
				_unstick_input_frames -= 1
			else:
				_walk_input(Vector3.ZERO)
		if frame < 1800 or frame % 5 != 0 or _player.is_cinematic_locked():
			continue
		var target := _pick_visible_target()
		if target == null:
			if _unstick_input_frames == 0:
				_plan_walk()
			continue
		var weapon: Node = _player._weapon
		var camera: Camera3D = weapon._camera
		camera.look_at(_aim_point)
		weapon._aiming = false
		if weapon.get_ammo() <= 0:
			weapon.refill_all_ammo()
		var before := Health.health_or(target)
		var ammo_before := int(weapon.get_ammo())
		weapon.fire()
		if int(weapon.get_ammo()) < ammo_before:
			_shots += 1
		if not is_instance_valid(target) or Health.health_or(target) < before:
			_hits += 1
			if is_instance_valid(target) and bool(target.get_meta(&"formal_boss", false)): _boss_shots += 1
		if not captured_combat and _hits > 0:
			await _capture("02_native_combat")
			captured_combat = true
	_check(cleared, "三波完整打通并进入结算")
	_walk_input(Vector3.ZERO)
	_check(_seen.size() == 6 and not _seen.has("legacy"), "全程仅出现六个新物种")
	_check(_player.kill_count == _expected_small_kills + 1, "%d只小怪及一个Boss均回收为真实击杀" % _expected_small_kills)
	_check(int(_peak_alive.get("1", 0)) >= mini(int(_director._spawn_cfg.target_alive), _director._count_for_wave(1)), "开场原生投放能达到目标围攻人数")
	_check(_boss_frame >= 0 and _choices == 3, "三波和三次选卡结束后才进入同一套泰坦战")
	_check(_boss_shots > 0 and _boss_front_attacks > 0 and _boss_rage_attacks > 0, "Boss普通/狂暴阶段原生攻击、真实枪线受伤均已验证")
	_check(_poison_seen, "正式地图实际投囊会留下有毒黏液")
	_check(_shots > 0 and _hits > 0, "实际 fire/物理枪线可以命中新敌人")
	_check(_hurt_frames > 0, "原生AI和攻击确实能够伤害玩家")
	_check(_observed_states.get("mud_golem", {}).has("ATTACK"), "泥偶原生追击后挥拳")
	_check(_observed_states.get("fast_beast", {}).has("POUNCE_LEAP") or _observed_states.get("fast_beast", {}).has("JUMP_ATTACK"), "晶兽原生近身或飞扑攻击")
	_check(_observed_states.get("burst_crawler", {}).has("WINDUP"), "爬兽原生转身投囊")
	_check(_observed_states.get("prism_spider", {}).has("AIM"), "蜘蛛原生锁向瞄准")
	_check(_observed_states.get("charge_beetle", {}).has("CHARGE"), "兜虫原生冲锋")
	var report := {"passed": not _failed, "scene": _world.scene_file_path,
		"species": _seen.keys(), "shots": _shots, "hit_shots": _hits,
		"damage_frames": _hurt_frames, "kills": _player.kill_count,
		"upgrade_choices": _choices, "max_travel_by_species": _distance_travelled,
		"expected_small_kills": _expected_small_kills, "peak_alive_by_wave": _peak_alive,
		"normal_input_repositions": _walk_started, "final_player_position": str(_player.global_position),
		"spawn_configuration": _director._spawn_cfg.duplicate(true), "density_samples": _density_samples,
		"observed_states": _observed_states,
		"boss": _boss_facts, "boss_states": _boss_states, "boss_hit_shots": _boss_shots,
		"boss_front_attacks": _boss_front_attacks, "boss_rage_attacks": _boss_rage_attacks,
		"boss_phase_and_death_damage_injected_for_testing": _boss_finisher,
		"poison_puddle_seen": _poison_seen,
		"variations": _variations,
		"wisp_disabled_during_initial_observation": true,
		"player_physics_frozen_during_initial_observation": true,
		"player_health_refilled_for_testing": true}
	var remaining: Array = []
	for enemy: Node3D in get_nodes_in_group("enemies"):
		var entry: Dictionary = enemy.get_meta(&"enemy_entry", {})
		remaining.append({"species": entry.get("species", enemy.get_meta(&"formal_boss_id", "legacy")), "health": Health.health_or(enemy),
			"player_position": str(_player.global_position), "can_attack": enemy._spatial_can_attack() if String(entry.get("species", "")) != "hornet" else false,
			"position": [enemy.position.x, enemy.position.y, enemy.position.z], "state": enemy.current_state,
			"navigation": enemy._steering.get_sparring_diagnostic() if String(entry.get("species", "")) != "hornet" else {}})
	report["remaining"] = remaining
	if not cleared: await _capture("failed_remaining")
	# 结算后的重开与下一阶段也必须留在新入口。
	Flow.instance._on_restart()
	await scene_changed
	_world = current_scene
	for frame in range(12):
		await process_frame
	report["restart_scene"] = _world.scene_file_path
	_check(_world.scene_file_path == "res://scenes/sanctum_main.tscn", "重开继续使用新主场景")
	Flow.instance._apply_next_stage("sanctum")
	await scene_changed
	_world = current_scene
	for frame in range(12):
		await process_frame
	report["next_stage_scene"] = _world.scene_file_path
	_check(_world.scene_file_path == "res://scenes/sanctum_main.tscn", "下一阶段继续使用新主场景")
	_director = _world.get_node("Enemies/WaveDirector")
	report["passed"] = not _failed
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("trial.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	Flow.instance.state = Flow.State.MENU
	paused = false
	_director._cancel_clear_cinematic()
	current_scene = null
	_world.queue_free()
	await process_frame
	Pool.clear_all()
	RunState.begin_run()
	await create_timer(1.0).timeout
	print("[Sanctum native trial] ", JSON.stringify(report))
	quit(1 if _failed else 0)


func _observe_boss(boss: Node3D, frame: int) -> void:
	if _boss_frame < 0:
		_boss_frame = frame
		var cfg := Config.get_dictionary("bosses.sediment_titan")
		var values := Tuning.preset_values("PrototypeSedimentTitan", String(cfg.preset))
		_check(boss._tuning == values and boss.get_max_health() == float(values.max_health), "Boss完整共用实战台保存方案")
		_boss_facts = {"preset": cfg.preset, "max_health": boss.get_max_health(), "tuning": boss._tuning.duplicate(true)}
		await _capture("03a_titan_entrance")
	for label: String in boss.State:
		if int(boss.State[label]) == int(boss.current_state): _boss_states[label] = true
	if boss.current_state == boss.State.DEAD: return
	if _rage_frame < 0:
		_boss_front_attacks = boss._brain.history.size()
		if frame - _boss_frame >= 900 and _boss_front_attacks > 0 and _boss_shots > 0:
			# 保留36万生命正式方案，用真实伤害入口进入下一阶段，不能把短测当作击杀耗时。
			var transition: float = boss.get_health() - boss.get_max_health() * 0.45
			if boss.has_mud_shield: transition /= 1.0 - boss.shield_reduction
			boss.take_damage(transition)
			_check(boss.is_enraged, "同一Boss经真实伤害入口进入狂暴")
			_rage_frame = frame
	else:
		_boss_rage_attacks = boss._brain.history.size() - _boss_front_attacks
		if not _boss_finisher and frame - _rage_frame >= 900 and _boss_rage_attacks > 0:
			await _capture("03b_titan_rage")
			_boss_finisher = true
			boss.take_damage(boss.get_max_health() * 100.0)


func _walk_input(direction: Vector3) -> void:
	for action in ["move_left", "move_right", "move_forward", "move_back"]:
		Input.action_release(action)
	if direction.is_zero_approx(): return
	var local: Vector3 = _player.camera_pivot.global_basis.inverse() * direction.normalized()
	if absf(local.x) > 0.15: Input.action_press("move_right" if local.x > 0.0 else "move_left", absf(local.x))
	if absf(local.z) > 0.15: Input.action_press("move_back" if local.z > 0.0 else "move_forward", absf(local.z))


func _plan_walk() -> void:
	var best: Node3D
	var distance := INF
	for enemy: Node3D in get_nodes_in_group("enemies"):
		if not Health.is_alive(enemy): continue
		var gap := _player.global_position.distance_to(enemy.global_position)
		if gap < distance:
			distance = gap
			best = enemy
	if best == null: return
	var offset := best.global_position - _player.global_position
	offset.y = 0.0
	_walk_direction = offset.normalized()
	if distance < 20.0:
		_walk_direction = Vector3(-offset.z, 0.0, offset.x).normalized()
		var predicted := _player.global_position + _walk_direction * 6.0
		var bound := float(_director._arena.extent) * 0.65
		if absf(predicted.x) > bound or absf(predicted.z) > bound: _walk_direction = -_walk_direction
	_unstick_input_frames = 36
	_walk_started += 1


func _pick_visible_target() -> Node3D:
	var best: Node3D
	var distance := INF
	var weapon: Node = _player._weapon
	var camera: Camera3D = weapon._camera
	for enemy: Node3D in get_nodes_in_group("enemies"):
		if not Health.is_alive(enemy):
			continue
		var candidate := camera.global_position.distance_to(enemy.global_position)
		if candidate >= distance:
			continue
		var points: Array[Vector3] = [enemy.global_position]
		var collision: CollisionShape3D = preload("res://scripts/spatial_query.gd").primary(enemy)
		var half_height: float = (collision.shape.size.y if collision.shape is BoxShape3D else collision.shape.height if collision.shape is CapsuleShape3D else collision.shape.radius * 2.0) * enemy.scale.y * 0.35
		points.append(enemy.global_position + Vector3.UP * half_height)
		for region: Area3D in enemy.find_children("*", "Area3D", true, false):
			if region.has_meta(&"damage_receiver"): points.append(region.global_position)
		for point: Vector3 in points:
			camera.look_at(point)
			var hits: Array = weapon._resolve_shot_hits(-camera.global_basis.z, false)
			if not hits.is_empty() and hits[0].collider == enemy:
				distance = candidate
				best = enemy
				_aim_point = point
				break
	return best


func _seed_enemy(node: Node) -> void:
	if node is CharacterBody3D and node.has_meta(&"enemy_tuning"):
		node.set_meta(&"crowd_seed", 251019 + _spawn_serial)
		_spawn_serial += 1


func _overview() -> void:
	var camera := Camera3D.new()
	_world.add_child(camera)
	camera.global_position = _player.global_position + Vector3(16, 21, 25)
	camera.look_at(_player.global_position + Vector3(0, 1, -5))
	camera.make_current()
	await _capture("02a_mixed_group")
	var native: Camera3D = _player._weapon._camera
	native.make_current()
	camera.queue_free()


func _poison_overview(pool: Node3D) -> void:
	var camera := Camera3D.new()
	_world.add_child(camera)
	camera.global_position = pool.global_position + Vector3(7, 9, 9)
	camera.look_at(pool.global_position)
	camera.make_current()
	await _capture("02b_poison_puddle")
	var native: Camera3D = _player._weapon._camera
	native.make_current()
	camera.queue_free()


func _capture(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := Artifacts.ensure_dir("screenshots").path_join(name + ".png")
	_check(image.save_png(path) == OK, "保存实际渲染截图：" + name)


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error(message)
