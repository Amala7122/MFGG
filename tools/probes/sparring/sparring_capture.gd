extends RefCounted
## 常态 10Hz 快照；异常前后保留物理帧。只读取当前实例，不重新做战斗判定。
const Analysis := preload("res://tools/probes/sparring/sparring_analysis.gd")
const Adapter := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
var samples: Array = []
var replay_audit: Dictionary = {"status": "not_replay"}
var clips: Array = []
var notices: Array = []
var costs: Array = []
var _directory := ""
var _stream: FileAccess
var _settings: Dictionary
var _timer := 0.0
var _ring: Array = []
var _pending: Array = []
var _watch: Dictionary = {}
var _last_row: Dictionary = {}
var _last_attack := ""
var _reference: Dictionary = {}
var _reference_available := false
var _watches: Dictionary = {}
var _player_ground_watch: Dictionary = {}

func open(directory: String, settings: Dictionary = {}, reference := "") -> bool:
	_directory = directory
	_settings = Analysis.DEFAULTS.duplicate()
	_settings.merge(settings, true)
	_stream = FileAccess.open(directory.path_join("snapshots.jsonl"), FileAccess.WRITE)
	if _stream == null:
		push_error("诊断快照无法保存")
		return false
	if not reference.is_empty():
		var path := reference.get_base_dir().path_join("snapshots.jsonl")
		replay_audit = {"status": "unverified_missing_checkpoints", "reference": reference}
		if FileAccess.file_exists(path):
			for row: Dictionary in Analysis.read_lines(path):
				_reference[int(row.frame)] = row
			_reference_available = not _reference.is_empty()
			if _reference_available:
				replay_audit.status = "checking"
	return true

func record(actor: CharacterBody3D, boss: CharacterBody3D, frame: int, now: float, delta: float, opponents: Array = []) -> Dictionary:
	var started := Time.get_ticks_usec()
	var primary: Dictionary = opponents[0] if not opponents.is_empty() else Adapter.sample(boss, "legacy_boss")
	for candidate: Dictionary in opponents:
		if bool(candidate.alive):
			primary = candidate
			break
	var pos := Vector3(float(primary.position[0]), float(primary.position[1]), float(primary.position[2]))
	var ppos := actor.global_position
	var player_contacts: Array = []
	for index in range(mini(actor.get_slide_collision_count(), 4)):
		var contact := actor.get_slide_collision(index)
		var collider := contact.get_collider() as Node
		var normal := contact.get_normal()
		player_contacts.append({"collider": str(collider.get_path()) if is_instance_valid(collider) and collider.is_inside_tree() else "removed",
			"normal": [normal.x, normal.y, normal.z]})
	var velocity := Vector3(float(primary.velocity[0]), float(primary.velocity[1]), float(primary.velocity[2]))
	var camera: Camera3D = actor.get("camera")
	var facing := -camera.global_basis.z
	var key := String(primary.attack_key)
	var diagnostic: Dictionary = primary.diagnostic
	var row := {"time": now, "frame": frame, "engine_frame": Engine.get_physics_frames(), "delta": delta,
		"boss_position": [pos.x, pos.y, pos.z], "player_position": [ppos.x, ppos.y, ppos.z],
		"boss_velocity": [velocity.x, velocity.y, velocity.z], "state": int(primary.raw_state),
		"boss_hp": float(primary.hp) if primary.hp != null else 0.0, "player_hp": float(actor.get("health")), "player_shield": float(actor.get("shield")),
		"camera_forward": [facing.x, facing.y, facing.z], "diagnostic": diagnostic, "attack_key": key,
		"player": {"on_floor": actor.is_on_floor(), "rolling": actor.get("_rolling"), "iframes": actor.get("_damage_invulnerability"),
			"grenade_stock": actor.call("get_grenade_status"),
			"terrain_height": Terrain.height_at(ppos.x, ppos.z), "velocity": [actor.velocity.x, actor.velocity.y, actor.velocity.z],
			"contacts": player_contacts, "collision_mask": actor.collision_mask,
			"dodge_cooldown": actor.get("_dodge_cooldown"), "grenade_cooldown": actor.get("_grenade_cooldown"),
			"skill_cooldown": actor.get("_skill_cooldown"), "skill_charges": actor.get("_skill_charges"),
			"cinematic_locked": actor.get("_cinematic_locked")}}
	_last_row = row
	_ring.append(row)
	while not _ring.is_empty() and float(_ring[0].time) < now - float(_settings.context_seconds) - float(_settings.stall_seconds):
		_ring.pop_front()
	_check_player_ground(row)
	if not opponents.is_empty():
		row["opponents"] = opponents
		for opponent: Dictionary in opponents:
			var id := String(opponent.id)
			var old: Dictionary = _watches.get(id, {"watch": {}, "attack": ""})
			_watch = old.watch
			_last_attack = old.attack
			var subject_row := row.duplicate()
			var suspended := not bool(opponent.diagnostic.get("physics_enabled", true)) and not bool(opponent.diagnostic.get("suspension_expected", false))
			subject_row.merge({"boss_hp": float(opponent.hp) if opponent.hp != null else 0.0, "boss_position": opponent.position,
				"state": opponent.raw_state, "diagnostic": opponent.diagnostic, "actionable": bool(opponent.actionable) or suspended,
				"expected_wait": bool(opponent.expected_wait) and not suspended, "subject_id": id, "suspended": suspended}, true)
			_check_watch(subject_row, String(opponent.attack_key))
			_watches[id] = {"watch": _watch, "attack": _last_attack}
	else:
		_check_watch(row, key)
	for pending: Dictionary in _pending.duplicate():
		pending.frames.append(row)
		if now >= float(pending.until):
			_write_clip(pending, false)
			_pending.erase(pending)
	_timer -= delta
	if _timer <= 0.0:
		_timer = float(_settings.snapshot_interval)
		samples.append(row)
		_stream.store_line(JSON.stringify(row))
	if String(actor.get("sparring_mode")) == "replay":
		_check_replay(row)
	costs.append(Time.get_ticks_usec() - started)
	return row

func _check_player_ground(row: Dictionary) -> void:
	if float(row.player_position[1]) >= float(row.player.terrain_height) - 0.25:
		_player_ground_watch = {}
		return
	if _player_ground_watch.is_empty():
		_player_ground_watch = {"start": row.time, "reported": false}
	if bool(_player_ground_watch.reported) or float(row.time) - float(_player_ground_watch.start) < 0.1:
		return
	_player_ground_watch.reported = true
	var notice := {"kind": "player_below_terrain", "subject_id": "player", "time": row.time, "start": _player_ground_watch.start,
		"cause": {"code": "player_below_terrain", "certainty": "observed_position", "summary": "玩家中心持续低于地图地面；原因需结合接触片段核对"}}
	notices.append(notice)
	if clips.size() + _pending.size() < 8:
		_pending.append({"id": clips.size() + _pending.size() + 1, "trigger": notice, "until": float(row.time) + 2.0, "frames": _ring.duplicate()})
	_stream.flush()

func _check_watch(row: Dictionary, key: String) -> void:
	var diagnostic: Dictionary = row.diagnostic
	var eligible := bool(row.get("actionable", int(row.state) in [1, 2])) and not bool(row.get("expected_wait", false)) and float(row.boss_hp) > 0.0 and float(row.player_hp) > 0.0 and (float(diagnostic.get("attack_cooldown", 0.0)) <= 0.0 or bool(row.get("suspended", false)))
	if not eligible or key != _last_attack:
		_watch = {}
	_last_attack = key
	if not eligible:
		return
	if not _watch.is_empty() and Analysis.position(row).distance_to(Analysis.position(_watch.start)) > float(_settings.stationary_radius):
		_watch = {}
	if _watch.is_empty():
		_watch = {"start": row, "reported": false}
	if bool(_watch.reported) or float(row.time) - float(_watch.start.time) < float(_settings.stall_seconds) or float(row.boss_hp) >= float(_watch.start.boss_hp):
		return
	_watch.reported = true
	var notice := {"kind": "boss_pressure_lost", "subject_id": row.get("subject_id", "legacy_boss"), "time": row.time, "start": _watch.start.time, "cause": Analysis.classify(diagnostic, row)}
	notices.append(notice)
	if clips.size() + _pending.size() < 8:
		_pending.append({"id": clips.size() + _pending.size() + 1, "trigger": notice, "until": float(row.time) + 2.0, "frames": _ring.duplicate()})
	_stream.flush()

func _write_clip(pending: Dictionary, truncated: bool) -> void:
	var name := "incident_%03d.json" % int(pending.id)
	var file := FileAccess.open(_directory.path_join(name), FileAccess.WRITE)
	if file == null:
		push_error("异常片段无法保存")
		return
	file.store_string(JSON.stringify({"version": 2, "trigger": pending.trigger, "post_context_truncated": truncated, "frames": pending.frames}) + "\n")
	file.close()
	clips.append(name)

func _check_replay(row: Dictionary) -> void:
	if not _reference_available or String(replay_audit.status) == "diverged" or not _reference.has(int(row.frame)):
		return
	var expected: Dictionary = _reference[int(row.frame)]
	var opponent_difference := _opponent_difference(row.get("opponents", []), expected.get("opponents", []))
	var player_error := Analysis.position(row, "player_position").distance_to(Analysis.position(expected, "player_position"))
	var boss_error := Analysis.position(row).distance_to(Analysis.position(expected))
	var hp_error := absf(float(row.boss_hp) - float(expected.boss_hp))
	var durability_error := absf(float(row.player_hp) - float(expected.player_hp)) + absf(float(row.get("player_shield", 0)) - float(expected.get("player_shield", 0)))
	var resource_difference := _grenade_resource_difference(row.get("player", {}).get("grenade_stock", {}), expected.get("player", {}).get("grenade_stock", {}))
	if player_error > 0.5 or boss_error > 0.5 or hp_error > 1.0 or durability_error > 0.1 or int(row.state) != int(expected.state) or not opponent_difference.is_empty() or not resource_difference.is_empty():
		replay_audit.merge({"status": "diverged", "first_frame": row.frame, "first_time": row.time,
			"player_position_error": player_error, "boss_position_error": boss_error, "boss_hp_error": hp_error,
			"player_durability_error": durability_error,
			"expected_state": expected.state, "actual_state": row.state,
			"opponent_difference": opponent_difference,
			"player_resource_difference": resource_difference,
			"explanation": "这是首次超过诊断容差的检查点，后续画面不能作为原局复现证据"}, true)
	else:
		replay_audit["matched_checkpoints"] = int(replay_audit.get("matched_checkpoints", 0)) + 1

static func _grenade_resource_difference(actual: Dictionary, expected: Dictionary) -> Dictionary:
	if expected.is_empty():
		return {} # 旧快照缺库存，不补造该项重放证据。
	for key in ["mode", "charges", "capacity"]:
		if expected.has(key) and actual.get(key) != expected[key]:
			return {"kind": "grenade_resource", "field": key, "expected": expected[key], "actual": actual.get(key)}
	for key in ["throw_remaining", "recharge_remaining"]:
		if expected.has(key) and (not actual.has(key) or absf(float(actual[key]) - float(expected[key])) > 0.1):
			return {"kind": "grenade_resource", "field": key, "expected": expected[key], "actual": actual.get(key)}
	return {}

static func _opponent_difference(actual: Array, expected: Array) -> Dictionary:
	if expected.is_empty():
		return {}
	var by_id := {}
	for subject: Dictionary in actual:
		by_id[String(subject.id)] = subject
	if by_id.size() != expected.size():
		return {"kind": "membership", "actual_count": by_id.size(), "expected_count": expected.size()}
	for prior: Dictionary in expected:
		if not by_id.has(String(prior.id)):
			return {"kind": "missing_subject", "subject_id": prior.id}
		var current: Dictionary = by_id[String(prior.id)]
		var old_director: Dictionary = prior.get("diagnostic",{}).get("rage_director",{})
		var new_director: Dictionary = current.get("diagnostic",{}).get("rage_director",{})
		for key: String in ["cycle","intent","after_sweep","fan_beat","fan_snapshot","triple_struck","triple_snapshot","gap_close_active"]:
			if old_director.has(key) and old_director[key] != new_director.get(key):
				return {"kind":"attack_pattern","subject_id":prior.id,"field":key,"expected":old_director[key],"actual":new_director.get(key)}
		for key: String in ["closing_elapsed","fan_elapsed","triple_elapsed","pursuit_clock"]:
			if old_director.has(key) and (not new_director.has(key) or absf(float(old_director[key])-float(new_director[key])) > .1):
				return {"kind":"attack_pattern","subject_id":prior.id,"field":key,"expected":old_director[key],"actual":new_director.get(key)}
		for key: String in ["landing_followup_armed", "landing_link_gap_snapshot", "heavy_recovery_scale_snapshot"]:
			var prior_diagnostic: Dictionary = prior.get("diagnostic", {})
			var current_diagnostic: Dictionary = current.get("diagnostic", {})
			if prior_diagnostic.has(key) and prior_diagnostic[key] != current_diagnostic.get(key):
				return {"kind": "attack_link", "subject_id": prior.id, "field": key, "expected": prior_diagnostic[key], "actual": current_diagnostic.get(key)}
		var prior_reward: Dictionary = prior.get("diagnostic", {}).get("break_reward", {})
		var current_reward: Dictionary = current.get("diagnostic", {}).get("break_reward", {})
		for key: String in ["shield_hits", "kind", "pending", "crystal_hits", "crystal_break_pending"]:
			if prior_reward.has(key) and prior_reward[key] != current_reward.get(key):
				return {"kind": "break_reward", "subject_id": prior.id, "field": key, "expected": prior_reward[key], "actual": current_reward.get(key)}
		for key: String in ["elapsed", "crystal_guard_remaining"]:
			if prior_reward.has(key) and (not current_reward.has(key) or absf(float(prior_reward[key]) - float(current_reward[key])) > 0.1):
				return {"kind": "break_reward", "subject_id": prior.id, "field": key, "expected": prior_reward[key], "actual": current_reward.get(key)}
		var error := Vector3(float(current.position[0]), float(current.position[1]), float(current.position[2])).distance_to(Vector3(float(prior.position[0]), float(prior.position[1]), float(prior.position[2])))
		var hp_error := absf(float(current.hp) - float(prior.hp)) if current.hp != null and prior.hp != null else 0.0
		if error > 0.5 or hp_error > 1.0 or current.state != prior.state or current.alive != prior.alive or current.roster_id != prior.roster_id:
			return {"kind": "subject_state", "subject_id": prior.id, "position_error": error, "hp_error": hp_error, "expected_state": prior.state, "actual_state": current.state}
	return {}

func finish(events: Array, outcome: String) -> Dictionary:
	if not _last_row.is_empty() and (samples.is_empty() or samples[-1].frame != _last_row.frame):
		samples.append(_last_row)
		_stream.store_line(JSON.stringify(_last_row))
	for pending: Dictionary in _pending:
		_write_clip(pending, true)
	_pending.clear()
	if String(replay_audit.status) == "checking":
		replay_audit["reference_checkpoints"] = _reference.size()
		replay_audit.status = "matched_observed_checkpoints" if int(replay_audit.get("matched_checkpoints", 0)) == _reference.size() and not _reference.is_empty() else "unverified_incomplete_checkpoints"
		if replay_audit.status == "matched_observed_checkpoints" and replay_audit.has("source_preflight") and not bool(replay_audit.source_preflight.get("compatible", false)):
			replay_audit.status = "unverified_source_contract"
	var analysis := Analysis.analyze(samples, events, outcome, _settings)
	if outcome == "player_dead" and not _ring.is_empty():
		var terminal := FileAccess.open(_directory.path_join("terminal_player_dead.json"), FileAccess.WRITE)
		if terminal == null:
			push_error("死亡前交战片段保存失败")
		else:
			terminal.store_string(JSON.stringify({"kind": "player_dead", "time": _last_row.time, "frames": _ring, "post_context_truncated": true}) + "\n")
			terminal.close()
			analysis["terminal_clip"] = "terminal_player_dead.json"
	analysis["clips"] = clips
	Analysis.apply_replay_audit(analysis, replay_audit, String(replay_audit.status) != "not_replay")
	costs.sort()
	analysis["capture_cost_usec"] = {"samples": costs.size(), "p50": costs[int(costs.size() * 0.5)] if not costs.is_empty() else 0,
		"p95": costs[mini(int(costs.size() * 0.95), costs.size() - 1)] if not costs.is_empty() else 0}
	close()
	return analysis

func close() -> void:
	if _stream != null and _stream.is_open():
		_stream.flush()
		_stream.close()
