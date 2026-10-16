extends SceneTree
## 陪练信息边界、真实血盾、完整输入与正式闭环冒烟。
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Controller := preload("res://tools/probes/sparring/sparring_controller.gd")
const Lab := preload("res://prototypes/boss_lab/titan_sparring_lab.tscn")
const Recorder := preload("res://tools/probes/sparring/sparring_recorder.gd")
const Batch := preload("res://tools/probes/titan_sparring.gd")
var _failures := 0

class Actor extends CharacterBody3D:
	var _rolling := false
	var _dodge_cooldown := 0.0
	var _grenade_cooldown := 0.0
	var _skill_cooldown := 0.0
	var _skill_charges := 0
	var _weapon: Node
	func can_throw_grenade() -> bool:
		return _grenade_cooldown <= 0.0

class DelayedController extends "res://tools/probes/sparring/sparring_controller.gd":
	var visible_target := true
	var shown_warning: Dictionary = {}
	func _observe(_player: Node3D, _boss: Node3D) -> Dictionary:
		return {"time": elapsed, "target_visible": visible_target, "position": Vector3(0, 0, -10), "warning": shown_warning.duplicate(true)}
	func _avoid_wall(_player: Node3D, direction: Vector3) -> Vector3:
		return direction

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)

func _run() -> void:
	var profile: Dictionary = Settings.resolve({"profile_id": "reactive"}).profile
	_check(Batch.same_value({"seed": 10420261014, "nested": [180, true]}, {"seed": 10420261014.0, "nested": [180.0, true]}), "JSON 数字类型变化仍能配对相同条件")
	_check(not Batch.same_value({"seed": 1}, {"seed": 2.0}), "不同种子不得配对")
	_check(Batch.same_value({"damage": 298.34999999999997}, {"damage": 298.35}), "JSON 序列化的极小浮点尾差不能排除相同配装")
	var broken := profile.duplicate(true)
	broken.reaction_seconds = -0.1
	_check(not Settings.validate_profile(broken).is_empty(), "负反应延迟必须拒绝")
	broken = profile.duplicate(true)
	broken.aim_error_degrees = NAN
	_check(not Settings.validate_profile(broken).is_empty(), "非有限瞄准误差必须拒绝")
	var actor := Actor.new()
	root.add_child(actor)
	var controller := DelayedController.new()
	controller.setup(profile, 123)
	var output: Dictionary = controller.step(actor, null, 0.1)
	_check(not output.has_aim and not output.just.get("dodge", false), "未经过反应延迟不能瞄准或翻滚")
	controller.step(actor, null, 0.1)
	output = controller.step(actor, null, 0.1)
	_check(not output.has_aim, "首个观测仍在反应队列中")
	output = controller.step(actor, null, 0.1)
	_check(output.has_aim, "反应延迟后可使用已知位置")
	controller.shown_warning = {"key": "visible-circle", "pose": Transform3D.IDENTITY, "shape": {"kind": "circle", "radius": 2.0}, "progress": 0.9}
	output = controller.step(actor, null, 0.1)
	_check(not output.just.get("dodge", false), "刚公布的危险不能穿过反应队列立即翻滚")
	for _frame in range(3):
		output = controller.step(actor, null, 0.1)
	_check(bool(output.just.get("dodge", false)), "经过延迟且满足可见进度后翻滚")
	actor._dodge_cooldown = 0.5
	output = controller.step(actor, null, 0.1)
	_check(not output.just.get("dodge", false), "真实冷却尚未结束不能请求翻滚")
	_check(not Controller.published_contains(controller.shown_warning, Vector3(5, 0, 0)), "圈外不属于危险区")
	var orbit := DelayedController.new()
	var orbit_profile := profile.duplicate(true)
	orbit_profile.strategy = "orbit"
	orbit.setup(orbit_profile, 123)
	orbit.shown_warning = controller.shown_warning
	for _frame in range(6):
		output = orbit.step(actor, null, 0.1)
	_check(not output.just.get("dodge", false) and output.warning_seen == "", "持续绕射策略不使用预警反应，和预警策略形成对照")
	controller.visible_target = false
	controller.shown_warning = {}
	for _frame in range(30):
		output = controller.step(actor, null, 0.1)
	_check(not output.has_aim and output.activity == "search", "丢失视野后不能永久追踪目标")
	actor.queue_free()

	var world := Lab.instantiate()
	world.run_options = {"profile_id": "reactive", "seed": 10420261014, "observation_seconds": 8.0, "autostart": true}
	root.add_child(world)
	current_scene = world
	var session: Node
	for _frame in range(1200):
		await process_frame
		if is_instance_valid(world.session) and world.session.running:
			session = world.session
			break
	_check(session != null, "完整入口能投放 Boss 并开始陪练")
	if session != null:
		var panel: Dictionary = session._read_panel()
		_check(Settings.same_values(panel.diagnostics, Settings.read_document().diagnostics), "未修改的面板参数不得被步长截断或浮点尾差改写：" + str(panel.diagnostics))
		_check(float(session.actor.health) == 100.0 and float(session.actor.shield) == 70.0, "使用正式血盾而非高血量陪练")
		_check(not session.actor.get_meta(&"experiment_invincible", false), "未启用实验无敌")
		session.toggle_pause()
		var paused_time: float = session.recorder.time
		for _frame in range(4):
			await process_frame
		_check(is_equal_approx(float(session.recorder.time), paused_time), "暂停时输入和战斗计时冻结")
		session.toggle_pause()
		var start: Vector3 = session.actor.global_position
		while session.result.is_empty():
			await process_frame
		_check(session.result.outcome == "observation_limit" or session.result.outcome == "player_dead", "预算截断与真实死亡分别记录")
		_check(start.distance_to(session.actor.global_position) > 1.0, "真实玩家发生移动，不能原地伪造统计")
		_check(int(session.result.input_frames) >= 100, "完整逐帧输入已记录")
		_check(float(session.result.final_boss.hp) < float(session.result.initial_boss.hp), "正式开火实际削减 Boss 生命")
		_check(FileAccess.file_exists(String(session.result.directory).path_join("events.jsonl")), "完整事件产物存在")
		_check(not bool(session.result.time_is_quality_score), "时长不被当作质量分")
		_check(session.result.execution_environment.fixed_fps == OS.get_environment("RUIN_STAR_RUN_FIXED_FPS"), "报告帧推进条件必须取实际启动器证据，不能把被引擎消费的参数当未开启")
		var original := Settings.read_document()
		session._name.text = "acceptance_named"
		session._fields.reaction_seconds.value = 0.35
		session._save_preset()
		var saved := Settings.read_document()
		_check(saved.presets.has("acceptance_named") and saved.active == original.active, "命名保存落盘但不修改默认方案")
		session._set_default()
		_check(Settings.read_document().active == "acceptance_named", "单独设默认会写入所选方案")
		_check(Settings.write_document(original) == OK, "隔离验收恢复配置，避免污染后续用例")
		var frames := Recorder.read_replay(String(session.result.directory).path_join("inputs.jsonl"))
		_check(frames.size() == int(session.result.input_frames) and frames[0].has("yaw"), "逐帧输入能完整读回用于重放")
		_check(frames[0].just.has("resonance_burst"), "输入录像包含 C 共鸣，不能遗漏真人战斗操作")
		session.actor.health = 100.0
		session.actor.shield = 70.0
		session.actor._damage_invulnerability = 0.0
		session.actor.take_damage(95.0)
		_check(float(session.actor.health) == 75.0 and float(session.actor.shield) == 0.0, "正式 95 伤害准确穿透 70 盾并扣 25 血，未修改容错")
		session.actor._damage_invulnerability = 0.0
		session.actor.take_damage(200.0)
		_check(float(session.actor.health) == 0.0 and bool(session.actor._dying), "真实致死伤害归零并触发死亡")
	paused = false
	current_scene = null
	world.queue_free()
	for _frame in range(8):
		await process_frame
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[自动陪练] failures=", _failures)
	quit(1 if _failures else 0)
