@tool
extends "res://prototypes/boss_lab/sediment_titan_boss_lab.gd"
## 正式地图遭遇；只共享既有地图／导航准备，不使用原型实验场的无敌或空场规则。
const SparringSettings := preload("res://tools/probes/sparring/sparring_settings.gd")
const SparringSpawner := preload("res://tools/probes/sparring/sparring_spawner.gd")
const Session := preload("res://tools/probes/sparring/sparring_session.gd")
var run_options: Dictionary = {}
var session: Node

func _ready() -> void:
	if not Engine.is_editor_hint():
		var flow := get_node_or_null("/root/GameFlow")
		if flow != null:
			flow.set("state", preload("res://scripts/game_flow.gd").State.PLAYING)
			flow.set("visible", false)
	super._ready()

func default_scenario() -> String:
	return String(SparringSettings.read_document().get("active_scenario", SparringSettings.Scenarios.document().get("active", "sanctum_mixed")))

func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		if run_options.is_empty():
			run_options = SparringSettings.pending_run.duplicate(true)
			SparringSettings.pending_run.clear()
			if run_options.is_empty():
				run_options = {"mode": "manual", "autostart": false}
		var flow := get_node_or_null("/root/GameFlow")
		if flow != null:
			flow.set_meta(&"sparring_session_active", true)
		if not run_options.has("scenario_id"):
			run_options.scenario_id = default_scenario()
		run_options = SparringSettings.resolve(run_options)
		if not run_options.is_empty():
			trial_seed = int(run_options.seed)
			seed(trial_seed)
		get_node("PlayerSpawner").set_script(SparringSpawner)
	super._enter_tree()

func prepare_direct_trial() -> Dictionary:
	ArenaUtil.current_id = "sanctum"
	RunStateUtil.begin_run()
	RunStateUtil.set_progress(ArenaUtil.get_order().find("sanctum") + 1, 0)
	var loadout := String(run_options.get("scenario", {}).get("loadout", "max"))
	var weapon_level := 1
	var stacks := {}
	for key in UPGRADE_IDS:
		var maximum := ConfigUtil.get_int("weapon.upgrades.%s.max_stacks" % key, 0)
		var count: int = maximum if loadout == "max" else int(maximum / 2) if loadout == "mid" else 0
		RunStateUtil.set_upgrade_stacks(String(key), count)
		stacks[String(key)] = count
		weapon_level += count
	RunStateUtil.set_weapon_level(weapon_level)
	return {"arena_id": "sanctum", "weapon_level": weapon_level, "upgrades": stacks}

func _spawn_trial_opponents(player: Node) -> bool:
	if run_options.is_empty():
		return false
	if run_options.scenario.kind == "boss_direct":
		if not await super._spawn_trial_opponents(player):
			return false
		var opponent := get_tree().get_first_node_in_group("boss")
		var phase := String(run_options.scenario.get("boss_phase", "full"))
		if phase != "full" and (opponent == null or not opponent.has_method("prepare_sparring_phase") or not opponent.call("prepare_sparring_phase", phase)):
			push_error("当前Boss没有实现所选阶段的准备接口：" + phase)
			return false
		return true
	var director := get_node("Enemies/WaveDirector")
	director.set_process(false)
	director._started = true
	var random := RandomNumberGenerator.new()
	random.seed = trial_seed
	var deployment := preload("res://scripts/enemy_deployment.gd").new()
	deployment.configure(director, ArenaUtil.get_params(), random)
	var spawner := get_node("Enemies/EnemySpawner")
	var roster := SparringSettings.Groups.roster()
	var ids: Array = run_options.scenario.selection.keys()
	ids.sort()
	for id: String in ids:
		for _index in range(int(run_options.scenario.selection[id]) * int(run_options.scenario.count_multiplier)):
			var position := {}
			for _retry in range(24):
				position = deployment.select_single(roster[id], director._anchors)
				if not position.is_empty():
					break
				await get_tree().process_frame
			if position.is_empty():
				push_error("实战陪练投放失败：" + id)
				return false
			var enemy: Node3D = spawner.spawn_enemy(roster[id], position.position, float(run_options.scenario.enemy_level))
			enemy.set_meta(&"lab_roster_id", id)
			enemy.set_meta(&"lab_title", String(roster[id].title))
			enemy.set_meta(&"lab_kind", String(roster[id].kind))
			await get_tree().process_frame
	return true

func _show_notice(player: Node) -> void:
	session = Session.new()
	session.name = "SparringSession"
	add_child(session)
	session.prepare(self, player, null, run_options)

func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not is_instance_valid(session) or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F5:
		get_viewport().set_input_as_handled()
		session.repeat_run()
	elif event.physical_keycode == KEY_TAB:
		get_viewport().set_input_as_handled()
		session.toggle_pause()

func _unhandled_input(_event: InputEvent) -> void:
	pass

func _exit_tree() -> void:
	if not Engine.is_editor_hint():
		var flow := get_node_or_null("/root/GameFlow")
		if flow != null:
			flow.remove_meta(&"sparring_session_active")
	super._exit_tree()
