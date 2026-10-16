extends SceneTree
## 跨敌人语义、多对象异常、编组保存、正式混战与普通敌人故障注入。
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Adapter := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd")
const Analysis := preload("res://tools/probes/sparring/sparring_analysis.gd")
const Capture := preload("res://tools/probes/sparring/sparring_capture.gd")
const Report := preload("res://tools/probes/sparring/sparring_batch_report.gd")
const Lab := preload("res://prototypes/sparring_lab/combat_sparring_lab.tscn")
var _failures := 0

class IdleContract extends "res://tools/probes/sparring/sparring_controller.gd":
	func step(_player: CharacterBody3D, _opponent: Node3D, _delta: float) -> Dictionary:
		return {"held": {}, "just": {}, "move_world": Vector3.ZERO, "has_aim": false, "activity": "idle_input_contract"}

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _subject(id: String, x: float, frozen := false) -> Dictionary:
	return {"id": id, "title": id, "roster_id": id, "position": [x, 0, 0], "hp": 1000.0, "alive": true,
		"raw_state": -1, "state": "locomotion", "actionable": true, "expected_wait": false,
		"diagnostic": {"physics_enabled": not frozen}, "capabilities": {"state": true, "health": true}}

func _logic_checks() -> void:
	_check(Settings.Groups.validate({"L1MeleeSoldier": 48, "L1ScoutGunner": 12}).is_empty(), "编组配置不能继承原型台 24／36 只限制；这里只验配置，不生成该规模")
	_check(not Settings.Groups.validate({"L1MeleeSoldier": -1}).is_empty(), "负数量拒绝")
	_check(not Settings.Groups.validate({"PrototypeBurstCrawler": 1}).is_empty(), "未投产外形不能静默变成正式战斗敌人")
	var rows: Array = []
	var events: Array = []
	for tick in range(21):
		var now := tick * 0.5
		rows.append({"time": now, "frame": tick, "engine_frame": tick, "player_hp": 100.0, "opponents": [_subject("frozen", 0.0, true), _subject("moving", now)]})
		events.append({"time": now, "kind": "enemy_damage", "details": {"subject_id": "frozen", "damage": 10.0}})
	var result := Analysis.analyze(rows, events, "enemies_defeated")
	_check(result.sample_validity == "needs_review" and result.incidents.size() == 1 and result.incidents[0].subject_id == "frozen", "只能定位实际停摆对象，不因另一敌人在活动而漏检")
	var unknown := rows.duplicate(true)
	for row: Dictionary in unknown:
		row.opponents = [_subject("unknown", float(row.time))]
		row.opponents[0].capabilities.state = false
	_check(Analysis.analyze(unknown, [], "observation_limit").sample_validity == "unverified_capabilities", "未知状态能力不能自动得到正常样本结论")
	var timing := {"sample_validity": "no_detected_anomaly", "eligible_for_balance": true}
	Analysis.apply_temporal_audit(timing, {"trusted": false, "mode": "fast", "fixed_step_accelerated": true})
	_check(timing.sample_validity == "mechanics_only" and not timing.eligible_for_balance, "加速无头不能冒充真实毫秒攻击节奏的难度样本")
	var removed := unknown.duplicate(true)
	removed[-1].opponents[0]["removed_without_death"] = true
	_check(Analysis.analyze(removed, [], "opponents_removed").sample_validity == "needs_review", "对象消失不能冒充全灭获胜")
	var expected: Array = [_subject("a", 0.0), _subject("b", 1.0)]
	var actual := expected.duplicate(true)
	actual[1].position[0] = 5.0
	_check(Capture._opponent_difference(actual, expected).get("subject_id") == "b", "重放必须核对非主目标，不能只比较一个 Boss")
	var trial := {"conditions": {"scenario": {"kind": "roster_encounter"}, "scenario_id": "test", "group_id": "test", "group_selection": {"L1MeleeSoldier": 1}, "profile_id": "orbit", "seed": 1}, "analysis": {"eligible_for_balance": true}, "outcome": "player_dead", "last_hits": []}
	var excluded := trial.duplicate(true)
	excluded.analysis.eligible_for_balance = false
	var summary := Report.group_summary([trial, trial, excluded])[0] as Dictionary
	_check(int(summary.valid) == 2 and int(summary.excluded) == 1 and summary.interpretation.contains("全败") and not summary.mathematically_unavoidable, "全败只描述有效样本，异常不能污染分母，也不能证明全操作必死")
	var censored := trial.duplicate(true)
	censored.outcome = "observation_limit"
	_check(Report.group_summary([trial, censored])[0].interpretation.contains("截断"), "预算截断不得计为存活通关或完整死亡率")

func _start(options: Dictionary) -> Node:
	paused = false
	var world := Lab.instantiate()
	world.run_options = options
	root.add_child(world)
	current_scene = world
	for _frame in range(1200):
		await process_frame
		if is_instance_valid(world.session) and world.session.running:
			return world
	_check(false, "正式实战入口能准备并启动")
	return world

func _clear(world: Node) -> void:
	paused = false
	current_scene = null
	world.queue_free()
	for _frame in range(5):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)

func _run() -> void:
	_logic_checks()
	var world: Node = await _start({"scenario_id": "sanctum_mixed", "group_id": "mixed_patrol", "group_selection": {"L1MeleeSoldier": 1, "L1ScoutGunner": 1}, "profile_id": "reactive", "seed": 10420261014, "observation_seconds": 12, "autostart": true})
	if is_instance_valid(world.session) and world.session.running:
		var session: Node = world.session
		_check(session.encounter.actors.size() == 2 and session.recorder.initial_opponents.size() == 2, "按编组创建多个不同正式敌人，不生成泰坦替身")
		_check(session.actor.health == 100.0 and session.actor.shield == 70.0 and int(session.recorder.initial_player.level) == 1, "初始配装使用正式血盾与模块，不默认满配或无敌")
		var groups_before := FileAccess.get_file_as_string(Settings.Groups.PATH)
		var before := Settings.Groups.document()
		session._group_name.text = "acceptance_group"
		session._save_group()
		_check(Settings.Groups.document().active == before.active and Settings.Groups.document().groups.has("acceptance_group"), "命名编组与默认分开")
		_check(session.batch_arguments().has("--groups=acceptance_group"), "编辑器保存的组能生成同条件无头批测命令")
		session._batch_all.button_pressed = true
		_check(not session.batch_arguments().is_empty(), "批测命令能覆盖全部保存策略，不依赖当前一个策略")
		session._batch_all.button_pressed = false
		session._set_default_group()
		_check(Settings.Groups.document().active == "acceptance_group", "编组默认操作单独落盘")
		var restored := FileAccess.open(Settings.Groups.PATH, FileAccess.WRITE)
		restored.store_string(groups_before)
		restored.close()
		var live: Array = session.encounter.live_nodes()
		var melee: Node3D
		for node: Node3D in live:
			if Adapter.implementation(node) == "roster_melee":
				melee = node
		if melee != null:
			var position_before := melee.global_position
			var cooldown_before := float(melee.attack_cooldown)
			var requests_before := int(melee._steering.path_requests)
			Adapter.sample(melee, "check")
			_check(melee.global_position == position_before and float(melee.attack_cooldown) == cooldown_before and int(melee._steering.path_requests) == requests_before, "普通敌人只读观测不推进战斗")
			melee._attack_area.prepare(melee.global_transform, {"kind": "sector", "radius": 2.0, "angle": 100.0, "ground_effect": false}, 1.0)
			_check(Adapter.public_area(melee) == null, "不可见的内部攻击扇形不能提供给策略")
			melee._attack_area.cancel()
		var entry: Dictionary = Settings.Groups.roster().L2SwiftBlade
		var deployment := preload("res://scripts/enemy_deployment.gd").new()
		var random := RandomNumberGenerator.new()
		random.seed = 9
		deployment.configure(world.get_node("Enemies/WaveDirector"), preload("res://scripts/arena.gd").get_params(), random)
		var chosen := {}
		for _retry in range(24):
			chosen = deployment.select_single(entry, world.get_node("Enemies/WaveDirector")._anchors)
			if not chosen.is_empty():
				break
			await physics_frame
		_check(not chosen.is_empty(), "晚加入对象仍通过正式安全投放")
		if not chosen.is_empty():
			var extra: Node3D = world.get_node("Enemies/EnemySpawner").spawn_enemy(entry, chosen.position, 4.0)
			extra.set_meta(&"lab_roster_id", "L2SwiftBlade")
			extra.set_meta(&"lab_title", entry.title)
		while session.result.is_empty():
			await process_frame
		_check(session.result.opponents.final.size() == 3, "晚加入敌人、单体死亡与其余交战能持续跟踪")
		for initial: Dictionary in session.result.opponents.initial:
			_check(float(initial.hp) == float(initial.max_hp), "后续伤害不能反向改写初始生命快照")
		_check(session.result.stats.species.has("L1ScoutGunner") and session.result.stats.species.has("L1MeleeSoldier"), "统计按真实兵种归属")
		_check(Analysis.read_recording(String(session.result.directory)).analysis.sample_validity == session.result.analysis.sample_validity, "多敌实录可直接离线重分析")
	await _clear(world)

	world = await _start({"scenario_id": "sanctum_mixed", "group_id": "mixed_patrol", "group_selection": {"L4GiantBrute": 1, "L1ScoutGunner": 1}, "scenario_overrides": {"enemy_level": 20.0}, "profile_id": "reactive", "seed": 10420261014, "observation_seconds": 12, "autostart": true, "diagnostics": {"stall_seconds": 0.5, "context_seconds": 1.0}})
	if is_instance_valid(world.session) and world.session.running:
		var session: Node = world.session
		var brute: Node3D
		for node: Node3D in session.encounter.live_nodes():
			if String(node.get_meta(&"lab_roster_id")) == "L4GiantBrute":
				brute = node
		var id := String(brute.get_meta(&"sparring_actor_id"))
		var offset: Vector3 = brute.global_position - session.actor.camera.global_position
		session.actor.target_yaw = atan2(-offset.x, -offset.z)
		session.actor.target_pitch = atan2(offset.y, Vector2(offset.x, offset.z).length())
		brute.set_physics_process(false)
		while session.result.is_empty():
			await process_frame
		var found := false
		for incident: Dictionary in session.result.analysis.incidents:
			found = found or (incident.get("subject_id") == id and incident.cause.code == "physics_suspended")
		_check(found and not session.result.analysis.eligible_for_balance, "正式普通敌人被故意停摆时也必须留下对象级异常，而非仅泰坦可诊断")
		_check(not session.result.analysis.clips.is_empty(), "多敌故障自动保存前后物理帧")
	await _clear(world)

	# 只验证正常死亡留证：明确闲置输入，不作为玩家能力／必死概率样本。
	world = await _start({"scenario_id": "sanctum_mixed", "group_id": "melee_patrol", "group_selection": {"L1MeleeSoldier": 2, "L2HeavyWarrior": 1}, "scenario_overrides": {"enemy_level": 15.0}, "profile_id": "reactive", "seed": 10420261015, "observation_seconds": 30, "autostart": true})
	if is_instance_valid(world.session) and world.session.running:
		var session: Node = world.session
		var idle := IdleContract.new()
		idle.setup(session.options.profile, int(session.options.seed))
		session.actor.driver = idle
		while session.result.is_empty():
			await process_frame
		_check(session.result.outcome == "player_dead", "闲置输入契约通过正式敌人真实伤害导致死亡，不能直接扣血伪造")
		_check(FileAccess.file_exists(String(session.result.directory).path_join("terminal_player_dead.json")), "正常死亡也能保存最后交战物理帧")
		_check(not session.result.last_hits.is_empty() and not session.result.last_hits[-1].details.get("defence_before_hit", {}).is_empty(), "死亡前实际翻滚／无敌帧／冷却状态已经留证")
	await _clear(world)
	print("[通用实战陪练] failures=", _failures)
	quit(1 if _failures else 0)
