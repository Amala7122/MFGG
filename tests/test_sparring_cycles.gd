extends SceneTree
## A7有限策略信息边界、明确对照轴、窗口截断与真实入口契约。
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Analysis := preload("res://tools/probes/sparring/sparring_cycle_analysis.gd")
var failures := 0
class Actor extends CharacterBody3D:
	var _rolling := false
	var _dodge_cooldown := 0.0
	var _grenade_cooldown := 0.0
	var _skill_cooldown := 0.0
	var _skill_charges := 0
	var _weapon: Node
	var camera: Camera3D
	func can_throw_grenade() -> bool: return true
class Sensor extends "res://tools/probes/sparring/sparring_controller.gd":
	var cues := {"body": Vector3(0, 1, -12), "crystal": Vector3(0, 5, -12), "red_crystal": true, "guard_visible": false, "fallen_pose": false}
	func _observe(_actor: Node3D, _boss: Node3D) -> Dictionary:
		return {"time": elapsed, "target_visible": true, "position": Vector3(0, 0, -12), "core": cues.crystal, "break_cues": cues.duplicate(), "warning": {}, "mud_shield": false}
	func _avoid_wall(_actor: Node3D, direction: Vector3) -> Vector3: return direction
class Gun extends Node:
	var _sniper_ammo := 5
	var _sniper_reload_timer := 0.0
	var _ammo := 50
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func progress(time: float, field: String, before: Variant, after: Variant, reward: Dictionary) -> Dictionary:
	return {"time": time, "kind": "break_progress", "details": {"subject_id": "boss", "field": field, "before": before, "after": after, "reward": reward}}
func _run() -> void:
	check(not Settings.validate_cli_flags({"scenario": "titan_sanctum"}).is_empty(), "拼错场景参数必须拒绝，不沿默认混编运行")
	check(Settings.validate_cli_flags({"scenarios": "titan_sanctum", "boss_phase": "rage", "down-seconds": "4,5,6,8", "artifact-dir": "test"}).is_empty(), "正式场景与窗口批测参数可接受")
	var linked := {"id": "link_test", "position": [0, 0, 0], "hp": 1, "state": "leap_air", "alive": true, "roster_id": "titan", "diagnostic": {"landing_followup_armed": true}}
	var changed_link := linked.duplicate(true)
	changed_link.diagnostic.landing_followup_armed = false
	var capture := preload("res://tools/probes/sparring/sparring_capture.gd")
	check(capture._opponent_difference([changed_link], [linked]).get("kind") == "attack_link", "相同姿态但后续承诺不同，重放提前定位首次衔接偏离")
	linked.diagnostic.erase("landing_followup_armed")
	check(capture._opponent_difference([changed_link], [linked]).is_empty(), "旧记录缺衔接字段不能补造偏离")
	var profile: Dictionary = Settings.resolve({"profile_id": "break_priority"}).profile
	var invalid := profile.duplicate(true)
	invalid.boss_experiment = {"max_health": 1}
	check(not Settings.validate_profile(invalid).is_empty(), "试验不允许任意改血量等正式参数")
	invalid.boss_experiment = {"down_hold_seconds": 7}
	check(not Settings.validate_profile(invalid).is_empty(), "当前对照严格限4／5／6／8／10秒，未知7秒拒绝")
	for seconds in [4, 5, 6, 8, 10]:
		invalid.boss_experiment = {"down_hold_seconds": seconds}
		check(Settings.validate_profile(invalid).is_empty(), "新旧窗口值显式支持，不重新解释已保存值")
	invalid.boss_experiment = {"pressure_trial": "made_up"}
	check(not Settings.validate_profile(invalid).is_empty(), "未知压力候选不得回退正式配置")
	invalid.boss_experiment = {"pressure_trial": "hitstop", "down_hold_seconds": 6}
	check(Settings.validate_profile(invalid).is_empty(), "命名压力候选与窗长可记录，配对时仍须分离试验轴")
	var actor := Actor.new()
	root.add_child(actor)
	actor.camera = Camera3D.new()
	actor.add_child(actor.camera)
	actor._weapon = Gun.new()
	actor.add_child(actor._weapon)
	var sensor := Sensor.new()
	sensor.setup(profile, 42)
	var output := sensor.step(actor, null, 0.1)
	check(not output.has_aim, "新策略仍须经过感知延迟")
	for _i in range(4): output = sensor.step(actor, null, 0.1)
	check(output.held.aim and output.activity == "crystal_aim", "仅可见红晶体开放时狙击")
	sensor.cues.guard_visible = true
	output = sensor.step(actor, null, 0.1)
	check(output.held.aim, "新护罩不能绕过感知延迟瞬时切枪")
	for _i in range(4): output = sensor.step(actor, null, 0.1)
	check(not output.held.aim and output.activity == "guard_body_fire", "看到护罩后打身体，不能读5秒倒计时")
	sensor.cues.guard_visible = false
	sensor.cues.fallen_pose = true
	for _i in range(5): output = sensor.step(actor, null, 0.1)
	check(not output.held.aim and output.activity == "reward_fire", "可见倒地姿态使用真实身体瞄点")
	actor.queue_free()
	var events: Array = [progress(0, "crystal_hits", null, 0, {}), progress(1, "crystal_hits", 0, 1, {}), progress(7, "crystal_hits", 1, 2, {}), progress(13, "crystal_hits", 2, 3, {}),
		progress(14, "state", 12, 13, {"kind": "down", "durations": {"hold": 8}}),
		{"time": 15, "kind": "enemy_damage", "details": {"subject_id": "boss", "damage": 200, "break_reward": {"state": 13, "kind": "down"}}},
		{"time": 16, "kind": "sniper_trace", "details": {"region": "crystal_guard", "blocked": true}}]
	var result := Analysis.summarize(events, 18)
	check(result.crystal_break_hits == 3 and result.protected_shots == 1, "有效进度与拦截分别统计，首次空值不崩溃")
	check(result.windows.size() == 1 and result.windows[0].censored and result.windows[0].observed_seconds == 4, "预算截断不能报已兑现完整8秒")
	check(result.damage_in_reward == 200 and result.reward_share == 1.0, "实际窗口扣血独立统计")
	events.append(progress(18, "state", 13, 6, {"kind": "down"}))
	check(Analysis.summarize(events, 18).windows[0].censored, "奖励期间死亡同样是截断")
	var observed := Analysis.observed_progress([{"state": 1, "diagnostic": {"break_reward": {"state": 1, "crystal_hits": 0}}}, {"state": 13, "diagnostic": {"break_reward": {"state": 13, "kind": "down", "crystal_hits": 3}}}])
	check(observed.crystal_hits_observed == 3 and observed.down_holds_observed == 1 and not observed.per_shot_regions_available, "旧实录仅报告观察到的进度下界，不补造每枪原因")
	var offense := Analysis.offense_summary([{"kind": "enemy_attack", "details": {"subject_id": "boss", "attack": {"skill": "slam", "rhythm": {"group": 1}}}}, {"kind": "enemy_attack", "details": {"subject_id": "boss", "attack": {"skill": "sweep", "rhythm": {"group": 2}}}}, {"kind": "enemy_attack", "details": {"subject_id": "boss", "attack": {"skill": "leap", "rhythm": {"group": 2}}}}])
	check(offense.groups == 2 and offense.single_heavy_groups == 1, "招组统计区分单次重招与有组织攻势")
	var ordinary := Analysis.offense_summary([{"kind": "enemy_attack", "details": {"attack": "点射"}}, {"kind": "enemy_attack", "details": {"attack": {"skill": "legacy"}}}])
	check(ordinary.groups == 0 and ordinary.unclassified_attack_events == 2, "普通文字攻击名和无招组元数据事件不能报错，也不伪报实际无攻击")
	var trial := {"directory": "a", "analysis": {"eligible_for_balance": true}, "conditions": {"profile_id": "body_control", "profile": Settings.resolve({"profile_id": "body_control"}).profile, "seed": 1},
		"initial_player": {"hp": 100}, "harness_sha256": {"x": "same"}, "gameplay_sha256": {"boss": "same"}, "initial_world": {"position": [0, 1, 2]}, "execution_environment": {"headless": true}, "cycles": {"windows": [{"kind": "down", "observed_seconds": 4}]}}
	var other := trial.duplicate(true)
	other.conditions.profile_id = "break_priority"
	other.conditions.profile = profile.duplicate(true)
	check(Analysis.contrast_rejection(other, trial, "policy").is_empty(), "声明策略轴后同条件破解／不破解可以配对")
	other.conditions.profile.reaction_seconds = 0.5
	check(not Analysis.contrast_rejection(other, trial, "policy").is_empty(), "反应时间不同不得伪装成只改破解策略")
	other = trial.duplicate(true)
	other.conditions.profile.boss_experiment = {"down_hold_seconds": 6}
	check(Analysis.contrast_rejection(other, trial, "down_hold_seconds").is_empty(), "明确窗口轴才允许6秒与正式配置配对")
	other.analysis.eligible_for_balance = false
	check(not Analysis.contrast_rejection(other, trial, "down_hold_seconds").is_empty(), "异常局仍然排除，试验轴不放松有效性")
	other = trial.duplicate(true)
	other.conditions.profile["boss_experiment"] = {"pressure_trial": "hitstop"}
	check(Analysis.contrast_rejection(other, trial, "pressure_trial").is_empty(), "同实现只改命名压力候选可明确配对")
	other.conditions.profile.boss_experiment["down_hold_seconds"] = 6
	check(not Analysis.contrast_rejection(other, trial, "pressure_trial").is_empty(), "压力与窗长同时改变不能冒充单项对照")
	other.conditions.profile.boss_experiment.erase("down_hold_seconds")
	other.gameplay_sha256.boss = "different"
	check(not Analysis.contrast_rejection(other, trial, "pressure_trial").is_empty(), "压力轴不得掩盖不同Boss实现")
	var missing := trial.duplicate(true)
	missing.erase("harness_sha256")
	check(not Analysis.contrast_rejection(missing, missing, "policy").is_empty(), "两份都缺陪练指纹时也不能以空字典相等冒充同实现")
	missing = trial.duplicate(true)
	missing.cycles.windows = []
	check(not Analysis.contrast_rejection(missing, trial, "down_hold_seconds").is_empty(), "未触发倒地不能宣称已比较6／8／10秒收益")
	var world: Node = load("res://prototypes/sparring_lab/combat_sparring_lab.tscn").instantiate()
	profile["boss_experiment"] = {"down_hold_seconds": 6}
	profile.boss_experiment["pressure_trial"] = "pursuit"
	world.run_options = {"profile_id": "break_priority", "profile": profile, "scenario_id": "titan_sanctum", "scenario_overrides": {"boss_phase": "rage"}, "seed": 42, "observation_seconds": 3, "autostart": true}
	root.add_child(world)
	current_scene = world
	var session: Node
	for _i in range(1200):
		await process_frame
		if is_instance_valid(world.session) and world.session.running:
			session = world.session
			break
	check(session != null, "A7真实场景可启动")
	if session != null:
		check(float(session.actor.health) == 100.0 and float(session.actor.shield) == 70.0, "试验仍使用正式100血／70盾")
		check(session.boss._tuning.down_hold_seconds == 6, "试验必须实际进入本轮Boss，不能只改报告")
		check(session._read_panel().profile.boss_experiment.down_hold_seconds == 6, "面板保留命名／CLI试验条件")
		check(is_equal_approx(float(session.boss.rage_speed_multiplier), 1.6), "追速候选实际写入已缓存的阶段速度")
		check(session._read_panel().profile.boss_experiment.pressure_trial == "pursuit", "面板保留压力候选，命名保存不丢条件")
		while session.result.is_empty(): await process_frame
		check(session.result.has("cycles") and session.result.harness_sha256.has("res://tools/probes/sparring/sparring_cycle_analysis.gd"), "实际录制有循环结果与分析器指纹")
	paused = false
	current_scene = null
	world.queue_free()
	for _i in range(8): await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[A7循环] failures=", failures)
	quit(1 if failures else 0)
