extends "res://prototypes/combat_lab/combat_lab_stats.gd"
## 完整事件与输入流保存在外部产物目录；时间仅为过程坐标，不评分。
const Artifacts := preload("res://scripts/artifact_paths.gd")
const DiagnosticCapture := preload("res://tools/probes/sparring/sparring_capture.gd")
const Adapter := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd")
const InputContract := preload("res://tools/probes/sparring/sparring_input.gd")
const HumanData := preload("res://tools/probes/sparring/sparring_human_data.gd")
const PublicSensor := preload("res://tools/probes/sparring/sparring_controller.gd")
const CycleAnalysis := preload("res://tools/probes/sparring/sparring_cycle_analysis.gd")
var _recorded_actor: Node3D
var _sensor: RefCounted
var _public_context: Dictionary = {}
var _next_context := 0.0
var _danger_started := 0.0
var _public_warning := ""
var imitation_driver: RefCounted
var encounter: RefCounted
var initial_opponents: Array = []
var final_opponents: Array = []
var _opponent_states: Dictionary = {}
var _wall_start_usec := 0
var _engine_start_frame := 0
var _paused_wall_usec := 0
var _paused_engine_frames := 0
var _wall_pause_started := 0
var _pause_engine_started := 0
const STATE_NAMES := ["出土", "待机", "追击", "直线砸地", "横扫", "施盾", "死亡", "跃击蓄力", "跃击空中", "跃击恢复", "高处普攻"]
var directory := ""
var options: Dictionary = {}
var event_rows: Array[Dictionary] = []
var sampled_rows: Array[Dictionary] = []
var activity_seconds: Dictionary = {}
var input_frames := 0
var _inputs: FileAccess
var _events: FileAccess
var _samples: FileAccess
var _sample_timer := 0.0
var _previous_state := -1
var _previous_rage := false
var _previous_shield := false
var _previous_rolling := false
var _last_attack_key := ""
var _last_warning_key := ""
var _last_buttons := ""
var initial_player: Dictionary = {}
var initial_boss: Dictionary = {}
var last_player: Dictionary = {}
var last_boss: Dictionary = {}
var diagnostics: RefCounted
var _noticed := 0
var _last_attack_result := ""
var _pending_input: Dictionary = {}
var _initial_world: Dictionary = {}

func open_recording(settings: Dictionary, actor: Node, boss: Node3D) -> bool:
	options = settings.duplicate(true)
	_recorded_actor = actor
	_sensor = PublicSensor.new()
	_sensor.setup(options.profile, int(options.seed))
	_sensor.encounter = encounter
	var id := "%s_%s_%d" % [String(options.profile_id).validate_filename(), str(options.seed), Time.get_ticks_usec()]
	directory = Artifacts.ensure_dir("reports", "sparring/" + id)
	if directory.is_empty():
		return false
	_inputs = FileAccess.open(directory.path_join("inputs.jsonl"), FileAccess.WRITE)
	_events = FileAccess.open(directory.path_join("events.jsonl"), FileAccess.WRITE)
	_samples = FileAccess.open(directory.path_join("timeline.csv"), FileAccess.WRITE)
	if _inputs == null or _events == null or _samples == null:
		push_error("陪练输出失败：" + directory)
		return false
	diagnostics = DiagnosticCapture.new()
	if not diagnostics.open(directory, options.get("diagnostics", {}), String(options.get("reference_report", ""))):
		return false
	if options.mode == "replay":
		diagnostics.replay_audit["source_preflight"] = options.get("replay_preflight", {})
	_samples.store_csv_line(PackedStringArray(["seconds", "player_hp", "player_shield", "boss_hp", "distance_m", "player_x", "player_z", "boss_x", "boss_z", "boss_state", "rage", "mud_shield", "rolling", "primary_ammo", "sniper_ammo", "primary_reload", "sniper_reload", "activity"]))
	capture_player(actor)
	initial_player = player.duplicate(true)
	initial_player["grenade_stock"] = actor.call("get_grenade_status")
	initial_opponents = encounter.sample() if encounter != null else [Adapter.sample(boss, "legacy_boss")]
	var total_hp := 0.0
	var total_max := 0.0
	var world_opponents: Array = []
	for row: Dictionary in initial_opponents:
		total_hp += float(row.hp) if row.hp != null else 0.0
		total_max += float(row.max_hp)
		world_opponents.append({"id": row.id, "roster_id": row.roster_id, "hp": row.hp, "max_hp": row.max_hp, "position": row.position})
	initial_boss = {"hp": total_hp, "max_hp": total_max, "preset": String(options.get("scenario", {}).get("title", "交战对象")), "compatibility_alias": "opponents_total"}
	var ppos: Vector3 = actor.get("global_position")
	var bpos := Vector3(float(initial_opponents[0].position[0]), float(initial_opponents[0].position[1]), float(initial_opponents[0].position[2]))
	_initial_world = {"player_position": [ppos.x, ppos.y, ppos.z], "boss_position": [bpos.x, bpos.y, bpos.z],
		"boss_uniform": bool(boss.get_meta(&"crowd_uniform", false)) if is_instance_valid(boss) else false,
		"individual_variation": boss.get_meta(&"individual_variation", {}) if is_instance_valid(boss) else {}, "opponents": world_opponents}
	if encounter != null:
		encounter.attach(self)
	else:
		register_enemy(boss)
	start()
	_wall_start_usec = Time.get_ticks_usec()
	_engine_start_frame = Engine.get_physics_frames()
	_event("start", {"conditions": options, "player": initial_player, "boss": initial_boss})
	return true

func pause_wall_clock(paused_now: bool) -> void:
	if paused_now and _wall_pause_started == 0:
		_wall_pause_started = Time.get_ticks_usec()
		_pause_engine_started = Engine.get_physics_frames()
	elif not paused_now and _wall_pause_started != 0:
		_paused_wall_usec += Time.get_ticks_usec() - _wall_pause_started
		_paused_engine_frames += Engine.get_physics_frames() - _pause_engine_started
		_wall_pause_started = 0

func temporal_audit() -> Dictionary:
	var now := Time.get_ticks_usec()
	var active_pause := now - _wall_pause_started if _wall_pause_started != 0 else 0
	var pause_frames := Engine.get_physics_frames() - _pause_engine_started if _wall_pause_started != 0 else 0
	var wall := maxf(float(now - _wall_start_usec - _paused_wall_usec - active_pause) / 1000000.0, 0.001)
	var frames := Engine.get_physics_frames() - _engine_start_frame - _paused_engine_frames - pause_frames
	var cadence := float(frames) / wall
	var fixed := OS.get_environment("RUIN_STAR_RUN_FIXED_FPS")
	var accelerated := not fixed.is_empty() and fixed != "unfixed"
	var mode := String(options.get("pacing", "realtime"))
	var trusted := mode == "realtime" and not accelerated and wall >= 1.0 and cadence >= float(Engine.physics_ticks_per_second) * 0.8 and cadence <= float(Engine.physics_ticks_per_second) * 1.2 and time / wall <= 1.2
	return {"trusted": trusted, "mode": mode, "fixed_step_accelerated": accelerated, "wall_seconds": wall,
		"simulation_seconds": time, "physics_frames": frames, "physics_frames_per_wall_second": cadence,
		"status": "realtime_verified" if trusted else "mechanics_only" if accelerated or mode == "fast" else "unverified_cadence",
		"note": "正式远程等含真实毫秒门槛；固定帧加速仅用于机制检查。暂停墙钟已扣除，未观察到真实节奏不进入实战难度对照。"}

func register_enemy(enemy: Node, _descriptor: Dictionary = {}) -> void:
	if enemies.has(enemy.get_instance_id()):
		return
	super.register_enemy(enemy, Adapter.statistics(enemy))
	if accepting():
		_event("enemy_joined", {"subject_id": String(enemy.get_meta(&"sparring_actor_id", "legacy_boss")), "roster_id": String(enemy.get_meta(&"lab_roster_id", "unknown"))})

func record_enemy_attack(enemy: Node, attack: String) -> void:
	if accepting():
		_event("enemy_attack", {"subject_id": String(enemy.get_meta(&"sparring_actor_id", "")), "attack": attack})

func record_input(actor: Node, control: Dictionary, delta: float) -> void:
	if not accepting() or _inputs == null:
		return
	var held := {}
	var pressed := {}
	for key in ["shoot", "aim", "sprint", "free_look"]:
		held[key] = bool(actor.call("_held", key))
	for key in ["dodge", "grenade", "skill", "reload", "jump", "resonance_burst"]:
		pressed[key] = bool(actor.call("_just", key))
	var movement: Vector2 = actor.call("_move_vector")
	if time >= _next_context or _public_context.is_empty():
		_next_context = time + 0.1
		var visible: Node3D = encounter.live_nodes()[0] if encounter != null and not encounter.live_nodes().is_empty() else null
		_public_context = _sensor.public_context(actor, visible)
		var key := String(_public_context.warning_key) if bool(_public_context.danger) else ""
		if key != _public_warning:
			_danger_started = time
			_public_warning = key
	var context := _public_context.duplicate()
	context["danger_age"] = time - _danger_started if bool(context.danger) else 0.0
	var pos: Vector3 = actor.get("global_position")
	var frame := {"schema": 2, "delta": delta, "aim_captured": bool(actor.call("_is_aim_captured")),
		"position": [pos.x, pos.y, pos.z], "context": context,
		"frame": input_frames, "engine_frame": Engine.get_physics_frames(), "time": snappedf(time, 0.000001), "held": held, "just": pressed,
		"move": [movement.x, movement.y], "yaw": float(actor.get("target_yaw")), "pitch": float(actor.get("target_pitch"))}
	_inputs.store_line(JSON.stringify(frame))
	input_frames += 1
	_pending_input = {"just": pressed, "before": _input_state(actor)}
	var activity := String(control.get("activity", "manual"))
	activity_seconds[activity] = float(activity_seconds.get(activity, 0.0)) + delta
	var buttons := JSON.stringify([held, pressed])
	if buttons != _last_buttons:
		_event("input_change", {"held": held, "just": pressed, "activity": activity})
		_last_buttons = buttons
	var warning := String(control.get("warning_seen", ""))
	if not warning.is_empty() and warning != _last_warning_key:
		_event("warning_perceived", {"key": warning, "reaction_seconds": options.profile.reaction_seconds})
		_last_warning_key = warning

func _input_state(actor: Node) -> Dictionary:
	var weapon: Dictionary = actor.get("_weapon").call("get_combat_snapshot")
	return {"E": int(sources.E.uses), "Q": int(sources.Q.uses), "rolling": bool(actor.get("_rolling")),
		"grenade_stock": actor.call("get_grenade_status"),
		"dodge_cooldown": float(actor.get("_dodge_cooldown")), "grenade_cooldown": float(actor.get("_grenade_cooldown")),
		"skill_cooldown": float(actor.get("_skill_cooldown")), "skill_charges": int(actor.get("_skill_charges")),
		"reload": weapon.reload, "sniper_reload": weapon.sniper_reload, "cinematic": bool(actor.get("_cinematic_locked")),
		"resonance_energy": float(actor.get("_resonance").get("_energy"))}

func record_input_effects(actor: Node) -> void:
	if not accepting() or _pending_input.is_empty():
		return
	var before: Dictionary = _pending_input.before
	var after := _input_state(actor)
	for action: String in _pending_input.just:
		if not bool(_pending_input.just[action]) or action == "jump":
			continue
		var accepted := false
		var reason := "没有观察到动作生效"
		match action:
			"grenade", "skill":
				var key := "E" if action == "grenade" else "Q"
				accepted = int(after[key]) > int(before[key])
				reason = "已开始实际攻击" if accepted else "冷却尚未结束" if float(after.grenade_cooldown if key == "E" else after.skill_cooldown) > 0 else "点数不足" if key == "Q" and int(after.skill_charges) <= 0 else reason
				if not accepted and key == "E" and after.grenade_stock.get("mode") == "reserve" and int(after.grenade_stock.charges) <= 0:
					reason = "手雷库存为空，等待逐枚回充"
			"dodge":
				accepted = bool(after.rolling) and not bool(before.rolling)
				reason = "实际翻滚开始" if accepted else "已在翻滚" if bool(before.rolling) else "冷却尚未结束" if float(after.dodge_cooldown) > 0 else "未满足落地等动作条件"
			"reload":
				accepted = float(after.reload) > float(before.reload) or float(after.sniper_reload) > float(before.sniper_reload)
				reason = "实际装填开始" if accepted else "装填未重新开始（可能已在装填或弹匣足够）"
			"resonance_burst":
				accepted = float(before.resonance_energy) > 0 and float(after.resonance_energy) < float(before.resonance_energy) and bool(after.cinematic)
				reason = "实际共鸣消耗与特写开始" if accepted else "共鸣未生效；见能量与动作状态"
		_event("input_result", {"action": action, "accepted": accepted, "reason": reason, "before": before, "after": after})
	_pending_input = {}

func begin_attack(source: String) -> int:
	var id := super.begin_attack(source)
	if id > 0:
		_event("attack_released", {"source": source, "shot": id})
		if source == "sniper" and is_instance_valid(_recorded_actor):
			# 狙击零散布；在正式fire紧接着结算之前记录同一相机／枪口射线。
			# 只诊断，结果不回传给控制器，不改变扳机或弹道。
			var weapon: Node = _recorded_actor.get("_weapon")
			var camera: Camera3D = _recorded_actor.get("camera")
			var hits: Array = weapon.call("_resolve_shot_hits", -camera.global_basis.z, true)
			var hit: Dictionary = hits[0] if not hits.is_empty() else {}
			var target := hit.get("collider") as Node
			_event("sniper_trace", {"shot": id, "region": hit.get("hit_region", "miss") if bool(hit.get("is_enemy", false)) else "world" if not hit.is_empty() else "miss",
				"subject_id": String(target.get_meta(&"sparring_actor_id", "")) if is_instance_valid(target) else "",
				"blocked": bool(target.call("blocks_weapon_hit", {"hit_region": hit.get("hit_region", "body"), "weapon_kind": "sniper"})) if is_instance_valid(target) and target.has_method("blocks_weapon_hit") else false})
	return id

func resource(source: String, kind: String, amount: float) -> void:
	super.resource(source, kind, amount)
	if accepting() and kind in ["reload", "pickup", "heal"]:
		_event("resource", {"source": source, "kind": kind, "amount": amount})

func record_player_hit(actor: Node, raw: float, hp: float, sp: float, blocked: bool, context: Dictionary, defence: Dictionary = {}) -> void:
	if not accepting():
		return
	player_damaged(context, raw, hp, sp, sp > 0.0 and float(actor.get("shield")) <= 0.0, "免伤窗口" if blocked else "")
	_event("player_hit_blocked" if blocked else "player_hit", {"raw": raw, "hp_loss": hp, "shield_loss": sp,
		"hp": float(actor.get("health")), "shield": float(actor.get("shield")), "source": context, "defence_before_hit": defence,
		"rage": bool(_opponent_states.get(String(context.get("subject_id", "")), {}).get("rage", false))})

func enemy_damaged(enemy: Node, before: float, after: float, context: Dictionary) -> void:
	super.enemy_damaged(enemy, before, after, context)
	if accepting():
		if encounter != null:
			encounter.note_damage(enemy, after)
		var details := {"subject_id": String(enemy.get_meta(&"sparring_actor_id", "legacy_boss")), "roster_id": String(enemy.get_meta(&"lab_roster_id", "unknown")),
			"damage": maxf(maxf(before, 0.0) - maxf(after, 0.0), 0.0), "hp": after, "source": context.get("source", "unknown"),
			"source_kind": context.get("source_kind", "player"), "headshot": context.get("headshot", false),
			"weapon_kind": context.get("weapon_kind", ""), "hit_region": context.get("hit_region", ""), "shot_id": context.get("shot_id", ""),
			"rage": bool(Adapter.value(enemy, "is_enraged", false)), "mud_shield": Adapter.public_shield(enemy)}
		if enemy.has_method("get_break_reward_status"):
			details["break_reward"] = enemy.call("get_break_reward_status")
		_event("enemy_damage", details)
		if Adapter.implementation(enemy) == "titan":
			_event("boss_damage", details)

func observe(delta: float, actor: Node3D, boss: Node3D) -> void:
	if not accepting():
		return
	advance(delta)
	capture_player(actor)
	last_player = player.duplicate(true)
	if encounter != null:
		encounter.sync()
	var subjects: Array = encounter.sample() if encounter != null else [Adapter.sample(boss, "legacy_boss")] if is_instance_valid(boss) else []
	if subjects.is_empty():
		return
	final_opponents = subjects
	var total_hp := 0.0
	var alive := 0
	var distance := INF
	var primary: Dictionary = subjects[0]
	for subject: Dictionary in subjects:
		var id := String(subject.id)
		var prior: Dictionary = _opponent_states.get(id, {})
		if subject.hp != null:
			total_hp += maxf(float(subject.hp), 0.0)
		if bool(subject.alive):
			alive += 1
			primary = subject
			var point := Vector3(float(subject.position[0]), float(subject.position[1]), float(subject.position[2]))
			distance = minf(distance, actor.global_position.distance_to(point))
		if subject.state != prior.get("state", ""):
			_event("enemy_state", {"subject_id": id, "state": subject.state, "implementation": subject.implementation})
			if subject.implementation == "titan":
				_event("boss_state", {"state": subject.raw_state, "name": subject.state})
		if subject.implementation == "titan":
			var reward: Dictionary = subject.diagnostic.get("break_reward", {})
			var old_reward: Dictionary = prior.get("diagnostic", {}).get("break_reward", {})
			for field: String in ["shield_hits", "crystal_hits", "kind", "pending", "state"]:
				if reward.get(field) != old_reward.get(field):
					_event("break_progress", {"subject_id": id, "field": field, "before": old_reward.get(field), "after": reward.get(field), "reward": reward})
			if bool(subject.rage) != bool(prior.get("rage", false)):
				_event("rage", {"subject_id": id, "enabled": subject.rage})
			if bool(subject.mud_shield) != bool(prior.get("mud_shield", false)):
				_event("mud_shield", {"subject_id": id, "enabled": subject.mud_shield})
			if not String(subject.attack_key).is_empty() and subject.attack_key != prior.get("attack_key", ""):
				_event("boss_attack", subject.attack.duplicate(true))
				_event("enemy_attack", {"subject_id": id, "attack": subject.attack.duplicate(true)})
			if not subject.attack.is_empty() and subject.attack.get("result", "") != "preparing" and subject.attack != prior.get("attack", {}):
				_event("boss_attack_result", subject.attack.duplicate(true))
		_opponent_states[id] = subject
	_previous_rage = bool(primary.rage)
	var rolling := bool(actor.get("_rolling"))
	if rolling and not _previous_rolling:
		_event("dodge_started", {})
	_previous_rolling = rolling
	if diagnostics != null:
		diagnostics.record(actor, boss, input_frames - 1, time, delta, subjects)
		while _noticed < diagnostics.notices.size():
			_event("diagnostic_anomaly", diagnostics.notices[_noticed])
			_noticed += 1
	last_boss = {"hp": total_hp, "rage": bool(primary.rage), "mud_shield": bool(primary.mud_shield), "state": int(primary.raw_state), "alive": alive, "compatibility_alias": "opponents_total"}
	_sample_timer -= delta
	if _sample_timer > 0.0:
		return
	_sample_timer = 0.25
	var weapon: Dictionary = actor.get("_weapon").call("get_combat_snapshot")
	var activity := String(actor.get("controls").get("activity", "manual"))
	var first := Vector3(float(primary.position[0]), float(primary.position[1]), float(primary.position[2]))
	var row := {"time": time, "player_hp": float(actor.get("health")), "player_shield": float(actor.get("shield")),
		"boss_hp": total_hp, "distance": distance if is_finite(distance) else 0.0, "player": [actor.global_position.x, actor.global_position.z],
		"boss": [first.x, first.z], "state": primary.raw_state, "rage": primary.rage, "shielded": primary.mud_shield,
		"rolling": rolling, "ammo": weapon.ammo, "sniper_ammo": weapon.sniper_ammo,
		"reload": weapon.reload, "sniper_reload": weapon.sniper_reload, "activity": activity}
	sampled_rows.append(row)
	_samples.store_csv_line(PackedStringArray([str(time), str(row.player_hp), str(row.player_shield), str(row.boss_hp),
		str(row.distance), str(row.player[0]), str(row.player[1]), str(row.boss[0]), str(row.boss[1]), str(row.state), str(row.rage),
		str(row.shielded), str(rolling), str(weapon.ammo), str(weapon.sniper_ammo), str(weapon.reload), str(weapon.sniper_reload), activity]))

func _event(kind: String, details: Dictionary) -> void:
	var entry := {"time": snappedf(time, 0.000001), "engine_frame": Engine.get_physics_frames(), "input_frame": input_frames - 1, "kind": kind, "details": details}
	event_rows.append(entry)
	if _events != null:
		_events.store_line(JSON.stringify(entry))

func finish(outcome: String) -> Dictionary:
	_event("end", {"outcome": outcome})
	stop(outcome)
	var hits: Array[Dictionary] = []
	var max_loss := 0.0
	var warning_count := 0
	var attack_count := 0
	var phases := {"normal": {"boss_damage": 0.0, "hits": 0, "durability_loss": 0.0}, "rage": {"boss_damage": 0.0, "hits": 0, "durability_loss": 0.0}}
	for event: Dictionary in event_rows:
		var phase: Dictionary = phases.rage if bool(event.details.get("rage", false)) else phases.normal
		if event.kind == "player_hit":
			hits.append(event)
			max_loss = maxf(max_loss, float(event.details.hp_loss) + float(event.details.shield_loss))
			phase.hits += 1
			phase.durability_loss += float(event.details.hp_loss) + float(event.details.shield_loss)
		elif event.kind == "enemy_damage":
			phase.boss_damage += float(event.details.damage)
		elif event.kind == "warning_perceived":
			warning_count += 1
		elif event.kind == "enemy_attack":
			attack_count += 1
	var tail: Array = hits.slice(maxi(hits.size() - 6, 0))
	var search_fraction := float(activity_seconds.get("search", 0.0)) / maxf(time, 0.01)
	var fingerprints := {}
	fingerprints["res://scripts/ballistics.gd"] = FileAccess.get_sha256("res://scripts/ballistics.gd")
	fingerprints["res://scripts/prototypes/titan_combat_brain.gd"] = FileAccess.get_sha256("res://scripts/prototypes/titan_combat_brain.gd")
	for path in ["res://scripts/player.gd", "res://scripts/player_weapon.gd", "res://scripts/grenade.gd",
		"res://scripts/prototypes/procedural_sediment_titan.gd", "res://data/enemy_presets/PrototypeSedimentTitan.json", "res://data/game_config.json", "res://scripts/melee_enemy.gd", "res://scripts/ranged_enemy.gd"]:
		fingerprints[path] = FileAccess.get_sha256(path)
	var diagnosis: Dictionary = diagnostics.finish(event_rows, outcome) if diagnostics != null else {}
	preload("res://tools/probes/sparring/sparring_analysis.gd").apply_temporal_audit(diagnosis, temporal_audit())
	if imitation_driver != null:
		diagnosis["imitation_audit"] = imitation_driver.call("audit")
		diagnosis.eligible_for_balance = false
		if diagnosis.sample_validity == "no_detected_anomaly":
			diagnosis.sample_validity = "unverified_player_model"
	if options.mode == "manual" and String(options.get("capture_origin", "")) != "human":
		diagnosis.eligible_for_balance = false
		if diagnosis.sample_validity == "no_detected_anomaly":
			diagnosis.sample_validity = "synthetic_or_unverified_capture"
	var report := {"schema_version": 4, "input_schema": 2, "actor_origin": HumanData.origin({"conditions": options}), "outcome": outcome, "observation_seconds": time,
		"cycles": CycleAnalysis.summarize(event_rows, time),
		"analysis": diagnosis,
		"pressure": pressure_summary(hits),
		"time_is_quality_score": false, "conditions": options, "engine": Engine.get_version_info(),
		"physics_ticks": Engine.physics_ticks_per_second, "gameplay_sha256": fingerprints,
		"execution_environment": {"headless": DisplayServer.get_name() == "headless", "display_server": DisplayServer.get_name(),
			"pacing": String(options.get("pacing", "realtime")),
			"fixed_fps": OS.get_environment("RUIN_STAR_RUN_FIXED_FPS") if OS.has_environment("RUIN_STAR_RUN_FIXED_FPS") else "unverified_editor_launch",
			"physics_ticks": Engine.physics_ticks_per_second, "time_scale": Engine.time_scale, "engine": Engine.get_version_info().string},
		"initial_player": initial_player, "initial_boss": initial_boss, "final_player": last_player, "final_boss": last_boss,
		"initial_world": _initial_world, "opponents": {"initial": initial_opponents, "final": final_opponents},
		"reproducibility": {"guarantee": "checkpoint_verification_only", "controlled": ["投放种子", "策略 RNG", "武器 RNG"],
			"not_claimed_deterministic": ["共用随机流的消费顺序", "相机墙钟震动", "导航微秒预算和初始化时序"],
			"crowd_uniform": _initial_world.boss_uniform},
		"stats": snapshot(), "activity_seconds": activity_seconds, "input_frames": input_frames,
		"attacks": attack_count, "warnings_perceived": warning_count, "unblocked_hits": hits.size(),
		"max_single_hit_durability_loss": max_loss, "last_hits": tail,
		"phases": phases, "engagement": {"search_fraction": search_fraction, "high_search_time": search_fraction > 0.2,
			"note": "寻敌占比高时，先复核遮挡与策略能力，不能直接归因 Boss 难度"},
		"limitations": ["测试策略不是玩家群体分布", "时长只记录，不用于质量评分", "读取已发布预警几何，不读取未公布选招或未来命中时间", "自定义遭遇和指定配装不等于完整四波流程，配装以实际快照为准", "脚本策略不能证明手感或反馈满意"],
		"directory": directory}
	var harness := {}
	for path in ["res://tools/probes/sparring/sparring_boss_trials.gd", "res://tools/probes/sparring/sparring_pressure_analysis.gd"]:
		harness[path] = FileAccess.get_sha256(path)
	for path in ["res://data/testing/titan_sparring.json", "res://scripts/prototypes/titan_sparring_lab.gd", "res://tools/probes/titan_sparring.gd",
		"res://tools/probes/sparring/sparring_settings.gd", "res://tools/probes/sparring/sparring_spawner.gd", "res://tools/probes/sparring/sparring_player.gd",
		"res://tools/probes/sparring/sparring_controller.gd", "res://tools/probes/sparring/sparring_session.gd", "res://tools/probes/sparring/sparring_recorder.gd"]:
		harness[path] = FileAccess.get_sha256(path)
	harness["res://tools/probes/sparring/sparring_runtime.gd"] = FileAccess.get_sha256("res://tools/probes/sparring/sparring_runtime.gd")
	for path in ["res://tools/probes/sparring/sparring_analysis.gd", "res://tools/probes/sparring/sparring_capture.gd", "res://scripts/nav_steering.gd", "res://scripts/combat_spatial_controller.gd"]:
		harness[path] = FileAccess.get_sha256(path)
	for path in ["res://tools/probes/sparring/sparring_enemy_adapter.gd", "res://tools/probes/sparring/sparring_encounter.gd", "res://tools/probes/sparring/sparring_scenarios.gd", "res://tools/probes/sparring/sparring_groups.gd", "res://scripts/prototypes/combat_sparring_lab.gd", "res://data/testing/sparring_groups.json", "res://data/testing/sparring_scenarios.json", "res://scripts/combat_telemetry.gd", "res://prototypes/combat_lab/combat_lab_stats.gd"]:
		harness[path] = FileAccess.get_sha256(path)
	for path in ["res://tools/probes/combat_sparring.gd", "res://tools/probes/sparring/sparring_batch_report.gd", "res://prototypes/boss_lab/sediment_titan_boss_lab.gd", "res://prototypes/sparring_lab/combat_sparring_lab.tscn"]:
		harness[path] = FileAccess.get_sha256(path)
	for path in ["res://tools/run_probe.py", "res://tools/run_acceptance.py"]:
		harness[path] = FileAccess.get_sha256(path)
	harness["res://tools/probes/sparring/sparring_cycle_analysis.gd"] = FileAccess.get_sha256("res://tools/probes/sparring/sparring_cycle_analysis.gd")
	harness["res://scripts/ui_theme.gd"] = FileAccess.get_sha256("res://scripts/ui_theme.gd")
	for path in ["res://tools/probes/sparring/sparring_input.gd", "res://tools/probes/sparring/sparring_human_data.gd", "res://tools/probes/sparring/sparring_imitation.gd"]:
		harness[path] = FileAccess.get_sha256(path)
	for path in ["res://scripts/enemy_spawner.gd", "res://scripts/enemy_deployment.gd", "res://scripts/arena.gd", "res://scripts/terrain_field.gd", "res://scripts/ground_movement.gd", "res://scenes/hyrule_field.tscn"]:
		report.gameplay_sha256[path] = FileAccess.get_sha256(path)
	for path in ["res://scripts/grenade_reserve.gd", "res://data/enemies/procedural_sediment_titan.json", "res://scripts/prototypes/enemy_tuning.gd", "res://scripts/grenade_action_pause.gd", "res://scripts/airborne_player_separation.gd", "res://scripts/combat_fx.gd", "res://scripts/enemy_attack_area.gd", "res://scripts/ground_warning.gd", "res://scripts/boss.gd", "res://scripts/prototypes/procedural_mud_golem.gd", "res://scripts/prototypes/procedural_fast_beast.gd", "res://scripts/prototypes/procedural_hornet.gd"]:
		report.gameplay_sha256[path] = FileAccess.get_sha256(path)
	for path in ["res://scripts/weapon_hit_regions.gd", "res://scripts/player_hud.gd", "res://scripts/dynamic_crosshair.gd"]:
		report.gameplay_sha256[path] = FileAccess.get_sha256(path)
	report["harness_sha256"] = harness
	close_files()
	var input := InputContract.read(directory.path_join("inputs.jsonl"))
	var diagnostic_rows := preload("res://tools/probes/sparring/sparring_analysis.gd").read_lines(directory.path_join("snapshots.jsonl"))
	report["boss_pressure"] = preload("res://tools/probes/sparring/sparring_pressure_analysis.gd").summarize(diagnostic_rows, input.frames, event_rows, time)
	report["input_audit"] = {"complete_contract": input.complete_contract, "problems": input.problems, "reported_frames_match": input.frames.size() == input_frames}
	report["human_behavior"] = HumanData.summarize(report, input.frames, event_rows)
	report.human_behavior["input_audit"] = report.input_audit
	report.human_behavior["sample_analysis"] = diagnosis
	report.human_behavior["source_input_sha256"] = FileAccess.get_sha256(directory.path_join("inputs.jsonl"))
	report.human_behavior["source_directory"] = directory
	if imitation_driver != null:
		report["style_comparison"] = HumanData.compare_style(report.human_behavior, imitation_driver.get("model"))
	if options.mode == "manual":
		var model := HumanData.fit(report, input.frames, input)
		if not model.is_empty():
			model["source_input_sha256"] = FileAccess.get_sha256(directory.path_join("inputs.jsonl"))
		if not HumanData.write_bundle(directory, report.human_behavior, model):
			push_error("真人行为分析无法写入")
	var file := FileAccess.open(directory.path_join("result.json"), FileAccess.WRITE)
	if file == null:
		push_error("陪练结果无法保存")
		return {}
	report.cycles["clips"] = CycleAnalysis.write_clips(directory, diagnostics.samples, report.cycles, event_rows)
	file.store_string(JSON.stringify(report, "  ") + "\n")
	file.close()
	_write_markdown(report)
	_write_svg()
	close_files()
	return report

static func pressure_summary(hits: Array) -> Dictionary:
	var peak := {"window_seconds": 1.0, "durability_loss": 0.0, "hits": 0, "sources": [], "start": 0.0, "end": 0.0}
	var first := 0
	var amount := 0.0
	var smallest_gap: Variant = null
	for index in range(hits.size()):
		var hit: Dictionary = hits[index]
		amount += float(hit.details.hp_loss) + float(hit.details.shield_loss)
		while float(hit.time) - float(hits[first].time) > 1.0:
			amount -= float(hits[first].details.hp_loss) + float(hits[first].details.shield_loss)
			first += 1
		if index > 0:
			var gap := float(hit.time) - float(hits[index - 1].time)
			smallest_gap = gap if smallest_gap == null else minf(float(smallest_gap), gap)
		if amount > float(peak.durability_loss):
			var sources: Array[String] = []
			for member: Dictionary in hits.slice(first, index + 1):
				var source: Dictionary = member.details.get("source", {})
				var key := String(source.get("subject_id", source.get("id", "unknown")))
				if not sources.has(key):
					sources.append(key)
			peak = {"window_seconds": 1.0, "durability_loss": amount, "hits": index - first + 1, "sources": sources, "start": hits[first].time, "end": hit.time}
	return {"peak_one_second": peak, "smallest_observed_hit_gap": smallest_gap,
		"last_hit_defence": hits[-1].details.get("defence_before_hit", {}) if not hits.is_empty() else {},
		"unavoidable_proven": false, "interpretation": "实际承伤集中度与命中前防御状态；缺少对其他可行动作的穷举，不判全操作必死"}

func _write_markdown(report: Dictionary) -> void:
	var file := FileAccess.open(directory.path_join("结果.md"), FileAccess.WRITE)
	if file == null:
		push_error("陪练说明无法保存")
		return
	file.store_string("# 实战陪练记录\n\n策略：%s；种子：%s；模式：%s。策略参数是测试假设，不代表真人群体。\n\n" % [options.profile.title, options.seed, options.mode])
	file.store_string("场景：%s；编组：%s；实际初始对象 %d 个。配装／等级／倍率见条件快照。\n\n" % [String(options.get("scenario_id", "legacy")), String(options.get("group_id", "")) if options.get("scenario", {}).get("kind", "") != "boss_direct" else "Boss 直战不应用编组", initial_opponents.size()])
	file.store_string("结果：**%s**。观察 %.2f 秒，仅为过程坐标，不按长短判好坏；预算到期属于截断，不算死亡或通关。\n\n" % [report.outcome, time])
	if options.get("scenario", {}).get("kind", "") == "boss_direct":
		file.store_string("Boss初始阶段：**%s**；直入阶段的记录只与相同起点比较，不能推算完整流程胜率。\n\n" % String(options.scenario.get("boss_phase", "full")))
		file.store_string("Boss实例试验：%s；实际覆盖 %s。未覆盖项目沿用正式方案，正式默认不被试验改写。\n\n" % [str(options.profile.get("boss_experiment", {})), str(preload("res://tools/probes/sparring/sparring_boss_trials.gd").values(options.profile.get("boss_experiment", {})))])
	var exposure: Dictionary = report.get("boss_pressure", {})
	if exposure.get("status") == "observed_diagnostic_snapshots":
		file.store_string("动作暂停 %.2f秒；追击／待机 %.2f秒（最长连续 %.2f秒）；完整重招后摇 %.2f秒；长奖励状态 %.2f秒。暂停可与后摇重叠，不相加评分。公开预警危及玩家当前位置 %.2f秒，无该预警时按住射击 %.2f秒；后者仍可能有其他威胁，不等于绝对安全。\n\n" % [exposure.action_pause_seconds, exposure.chase_idle_seconds, exposure.longest_chase_idle_seconds, exposure.heavy_recovery_seconds, exposure.reward_seconds, exposure.public_danger_seconds, exposure.shooting_without_public_danger_seconds])
	file.store_string("**样本有效性：%s；可用于正常交战对照：%s。** 原始胜负与诊断分开。\n\n" % [report.analysis.get("sample_validity", "unknown"), str(report.analysis.get("eligible_for_balance", false))])
	file.store_string("时间审计：%s；活动墙钟 %.3f 秒／模拟 %.3f 秒。加速与节奏未核对的记录不参与实战对照。\n\n" % [report.analysis.temporal_audit.status, report.analysis.temporal_audit.wall_seconds, time])
	for incident: Dictionary in report.analysis.get("incidents", []):
		file.store_string("- %s／%s · %.2f–%.2f 秒：%s；该对象实损 %.1f。证据：%s。\n" % [incident.get("subject_id", "legacy_boss"), incident.get("subject_title", "交战对象"), incident.start, incident.end, incident.cause.summary, incident.boss_damage, ", ".join(incident.evidence)])
	file.store_string("\n重放核对：%s。诊断快照 snapshots.jsonl；异常帧片段 %s；采集耗时见 result.json 的 capture_cost_usec。\n\n" % [report.analysis.get("replay_audit", {}), str(report.analysis.get("clips", []))])
	file.store_string("玩家初始血盾：%s / %s；实际武器等级 %s，初始弹匣 %s，狙击弹 %s。未使用无敌、无限技能或高血量。\n\n" % [initial_player.health, initial_player.shield, initial_player.level, initial_player.ammo, initial_player.sniper_ammo])
	file.store_string("交战对象初始总生命 %s；最后记录 %s。观察到 %d 次起招、陪练感知到 %d 次预警；实际承受 %d 次未被无敌帧挡住的伤害。单次最大血盾损失 %.1f。\n\n" % [initial_boss.hp, last_boss.get("hp", 0), report.attacks, report.warnings_perceived, report.unblocked_hits, report.max_single_hit_durability_loss])
	file.store_string("寻敌活动占比 %.1f%%。%s\n\n" % [float(report.engagement.search_fraction) * 100.0, report.engagement.note])
	file.store_string("一秒观察窗内最大实际血盾损失 %.1f，%d 次受击，来源对象 %s；最短实际受击间隔 %s 秒。最后受击前防御：%s。这些是承压事实，不证明其他操作也无法避免。\n\n" % [report.pressure.peak_one_second.durability_loss, report.pressure.peak_one_second.hits, str(report.pressure.peak_one_second.sources), str(report.pressure.smallest_observed_hit_gap), str(report.pressure.last_hit_defence)])
	file.store_string("## 逐对象结果\n\n| 局内 ID | 兵种 | 剩余生命 | 状态 | 退出 |\n|---|---|---:|---|---|\n")
	for subject: Dictionary in final_opponents:
		file.store_string("| %s | %s | %s | %s | %s |\n" % [subject.id, subject.title, str(subject.hp), subject.state, "未观察到死亡而消失" if bool(subject.get("removed_without_death", false)) else "死亡／仍在场"])
	file.store_string("\n## 最后受击\n\n| 时间 | 来源对象／兵种 | 招式 | 原始伤害 | 血损失 | 盾损失 |\n|---|---|---|---:|---:|---:|\n")
	for event: Dictionary in report.last_hits:
		file.store_string("| %.3f | %s / %s | %s | %.1f | %.1f | %.1f |\n" % [event.time, event.details.source.get("subject_id", "unknown"), event.details.source.get("title", "未归属"), event.details.source.get("attack", "未归属"), event.details.raw, event.details.hp_loss, event.details.shield_loss])
	file.store_string("\n## 产物\n\n- result.json：配置快照、实际配装、受击和玩法指纹。\n- timeline.csv / 战斗曲线.svg：血盾、距离与状态时间线。\n- events.jsonl：完整伤害、预警感知、起招和输入变化。\n- inputs.jsonl：每物理帧输入与瞄准，用于固定操作复现。\n\n## 如何与感受核对\n\n能核对单次失误代价、死亡前连击、实际操作与资源耗时；不能由机器胜率直接判定躲闪是否有趣或反馈是否满意。若结果与你的体验不同，先看配装、策略和失败片段，不调参数强行迎合。\n")
	file.store_string("\n操作来源：%s；录制标签：%s。行为画像见 result.json 的 human_behavior，真人模式另有真人行为分析.md／movement_path.svg。\n\n" % [report.actor_origin, str(options.get("participant", {}))])
	if report.has("style_comparison"):
		file.store_string("经验模拟覆盖：%s。\n\n源局与本局风格差异：%s。\n\n模型尚未通过独立真人局验证，不纳入正常交战难度统计。\n" % [str(report.analysis.imitation_audit), str(report.style_comparison.simulation_minus_source)])
	file.close()

func _write_svg() -> void:
	if sampled_rows.size() < 2:
		return
	var file := FileAccess.open(directory.path_join("战斗曲线.svg"), FileAccess.WRITE)
	if file == null:
		push_error("陪练曲线无法保存")
		return
	file.store_string('<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="400" viewBox="0 0 1000 400"><rect width="1000" height="400" fill="#111820"/><g fill="#dbe5ef" font-family="sans-serif" font-size="15"><text x="30" y="27">Opponent HP / player HP+shield / distance — process only, no quality score</text><text x="30" y="383">Blue: Opponent HP ratio · Green: Player durability ratio · Orange: distance / 40m</text></g>')
	var colors := ["#5aa9ff", "#68d391", "#f6ad55"]
	for channel in range(3):
		var points := ""
		for row: Dictionary in sampled_rows:
			var value := float(row.boss_hp) / maxf(float(initial_boss.hp), 1.0)
			if channel == 1:
				value = (float(row.player_hp) + float(row.player_shield)) / maxf(float(initial_player.health) + float(initial_player.shield), 1.0)
			elif channel == 2:
				value = float(row.distance) / 40.0
			points += "%.1f,%.1f " % [35.0 + float(row.time) / maxf(time, 0.01) * 930.0, 345.0 - clampf(value, 0.0, 1.0) * 290.0]
		file.store_string('<polyline fill="none" stroke="%s" stroke-width="2" points="%s"/>' % [colors[channel], points])
	file.store_string('</svg>')
	file.close()

func close_files() -> void:
	if diagnostics != null:
		diagnostics.close()
	for file in [_inputs, _events, _samples]:
		if file != null and file.is_open():
			file.flush()
			file.close()

static func read_replay(path: String) -> Array:
	var input := InputContract.read(path)
	if not input.problems.is_empty():
		push_error("陪练输入无效：" + str(input.problems))
		return []
	return input.frames
