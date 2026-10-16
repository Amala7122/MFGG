extends RefCounted
## 实时与旧实录共用的事后分析。时间阈值只定位异常，不评价战斗质量。
const DEFAULTS := {"stall_seconds": 4.0, "stationary_radius": 0.25, "snapshot_interval": 0.1, "context_seconds": 5.0}

static func position(row: Dictionary, key := "boss_position") -> Vector3:
	var values: Array = row.get(key, row.get("boss" if key == "boss_position" else "player", [0, 0, 0]))
	return Vector3(float(values[0]), float(values[1]) if values.size() > 2 else 0.0, float(values[2]) if values.size() > 2 else float(values[1]))

static func analyze(rows: Array, events: Array, outcome: String, values: Dictionary = {}) -> Dictionary:
	var result := _analyze_encounter(rows, events, outcome, values) if not rows.is_empty() and rows[0].get("opponents") is Array else _analyze_single(rows, events, outcome, values)
	var ground := _player_ground_incidents(rows, events)
	result["player_ground_evidence_available"] = rows.any(func(row: Dictionary): return row.get("player", {}).has("terrain_height"))
	if not ground.is_empty():
		result.incidents.append_array(ground)
		result.eligible_for_balance = false
		result.sample_validity = "needs_review"
	return result

static func _player_ground_incidents(rows: Array, events: Array) -> Array:
	var incidents: Array = []
	var window: Dictionary = {}
	var previous: Dictionary = {}
	for row: Dictionary in rows:
		if row.has("player_position"):
			if not previous.is_empty():
				var elapsed := float(row.time) - float(previous.time)
				var distance := position(row, "player_position").distance_to(position(previous, "player_position"))
				# 旧记录没有地面高度也能发现大幅位置跳变；只定位，不补造穿地原因。
				if elapsed > 0.0 and elapsed <= 0.25 and distance > maxf(8.0, 120.0 * elapsed):
					incidents.append({"kind": "player_position_discontinuity", "subject_id": "player", "start": previous.time, "end": row.time, "duration": elapsed,
						"cause": {"code": "position_discontinuity", "certainty": "observed_position", "distance_m": distance,
							"from": previous.player_position, "to": row.player_position, "summary": "玩家位置短时大幅跳变；缺少回拉事件时不能断定原因"}})
			previous = row
		var player: Dictionary = row.get("player", {})
		if not player.has("terrain_height") or not row.has("player_position"):
			continue
		var below := float(row.player_position[1]) < float(player.terrain_height) - 0.25
		if below:
			if window.is_empty():
				window = {"start": float(row.time), "end": float(row.time), "position": row.player_position, "cause": {"code": "player_below_terrain", "certainty": "observed_position", "contacts": player.get("contacts", []), "summary": "玩家中心持续低于地图地面，不能作为正常战斗结果"}}
			window.end = float(row.time)
		elif not window.is_empty():
			if float(window.end) - float(window.start) >= 0.1 - 0.000001:
				window.merge({"kind": "player_below_terrain", "subject_id": "player", "duration": float(window.end) - float(window.start)})
				incidents.append(window)
			window = {}
	if not window.is_empty() and float(window.end) - float(window.start) >= 0.1 - 0.000001:
		window.merge({"kind": "player_below_terrain", "subject_id": "player", "duration": float(window.end) - float(window.start)})
		incidents.append(window)
	for event: Dictionary in events:
		if event.kind == "player_recovered":
			incidents.append({"kind": "player_recovered", "subject_id": "player", "start": event.time, "end": event.time, "duration": 0.0,
				"cause": {"code": "fall_rescue", "certainty": "observed_recovery", "details": event.details, "summary": "本局触发过坠落回拉，需要单独核对"}})
	for incident: Dictionary in incidents:
		incident["subject_title"] = "玩家"
		incident["boss_damage"] = 0.0
		incident["evidence"] = ["玩家位置／地面高度或实际回拉事件；不推算Boss停摆伤害"]
	return incidents

static func _analyze_single(rows: Array, events: Array, outcome: String, values: Dictionary = {}) -> Dictionary:
	var settings := DEFAULTS.duplicate()
	settings.merge(values, true)
	var incidents: Array = []
	var window: Dictionary = {}
	var last: Dictionary = {}
	var attacks: Array = []
	for event: Dictionary in events:
		if event.kind == "boss_attack":
			attacks.append(float(event.time))
	var attack_index := 0
	var last_attack := -1000.0
	var has_causes := false
	for row: Dictionary in rows:
		var now := float(row.time)
		while attack_index < attacks.size() and float(attacks[attack_index]) <= now:
			last_attack = float(attacks[attack_index])
			attack_index += 1
		var diagnostic: Dictionary = row.get("diagnostic", {})
		has_causes = has_causes or not diagnostic.is_empty()
		var eligible := bool(row.get("actionable", int(row.get("state", -1)) in [1, 2])) and float(row.get("boss_hp", 0)) > 0.0 and float(row.get("player_hp", 1)) > 0.0
		eligible = eligible and not bool(row.get("expected_wait", false)) and (float(diagnostic.get("attack_cooldown", 0.0)) <= 0.0 or bool(row.get("suspended", false)))
		if not eligible or (not window.is_empty() and last_attack > float(window.start.time)):
			if not window.is_empty():
				_close_window(window, row if float(row.get("boss_hp", 1)) <= 0 else last, events, incidents, settings)
			window = {}
		if eligible:
			if not window.is_empty() and position(row).distance_to(position(window.start)) > float(settings.stationary_radius):
				_close_window(window, last, events, incidents, settings)
				window = {}
			if window.is_empty():
				window = {"start": row, "last_attack": last_attack}
		last = row
	if not window.is_empty():
		_close_window(window, last, events, incidents, settings)
	var flagged := not incidents.is_empty()
	return {"version": 2, "raw_outcome": outcome, "sample_validity": "needs_review" if flagged else "no_detected_anomaly" if has_causes else "unverified_legacy",
		"eligible_for_balance": not flagged and has_causes, "cause_evidence_available": has_causes,
		"incidents": incidents, "thresholds": settings, "time_is_quality_score": false,
		"explanation": "原始胜负保留；异常局不参与正常交战胜率。未检测到异常不等于证明无问题。旧实录缺失原因不能补造。"}

static func _analyze_encounter(rows: Array, events: Array, outcome: String, values: Dictionary) -> Dictionary:
	var subjects := {}
	var unsupported := {}
	var removed := {}
	for frame: Dictionary in rows:
		for opponent: Dictionary in frame.opponents:
			var id := String(opponent.id)
			if not subjects.has(id):
				subjects[id] = []
			if not bool(opponent.capabilities.get("state", false)) or not bool(opponent.capabilities.get("health", false)):
				unsupported[id] = String(opponent.title)
			if bool(opponent.get("removed_without_death", false)):
				removed[id] = frame.time
			var suspended := not bool(opponent.diagnostic.get("physics_enabled", true)) and not bool(opponent.diagnostic.get("suspension_expected", false))
			subjects[id].append({"time": frame.time, "frame": frame.frame, "engine_frame": frame.engine_frame,
				"boss_position": opponent.position, "boss_hp": float(opponent.hp) if opponent.hp != null else 0.0, "player_hp": frame.player_hp,
				"state": opponent.raw_state, "actionable": bool(opponent.actionable) or suspended, "expected_wait": bool(opponent.expected_wait) and not suspended, "suspended": suspended,
				"diagnostic": opponent.diagnostic, "subject_id": id, "subject_title": opponent.title})
	var incidents: Array = []
	for id: String in subjects:
		var relevant: Array = []
		for event: Dictionary in events:
			if String(event.get("details", {}).get("subject_id", "")) == id and event.kind in ["enemy_damage", "enemy_attack"]:
				var copied := event.duplicate(true)
				copied.kind = "boss_damage" if event.kind == "enemy_damage" else "boss_attack"
				relevant.append(copied)
		var result := _analyze_single(subjects[id], relevant, outcome, values)
		incidents.append_array(result.incidents)
	for id: String in removed:
		incidents.append({"kind": "opponent_removed", "subject_id": id, "start": removed[id], "end": removed[id], "duration": 0.0, "boss_damage": 0.0,
			"evidence": ["最后存活记录后退出树，未观察到生命归零"], "cause": {"code": "removed_without_death", "summary": "对象消失，不能当作正常击杀", "certainty": "observed_removal"}})
	var thresholds := DEFAULTS.duplicate()
	thresholds.merge(values, true)
	return {"version": 3, "raw_outcome": outcome, "sample_validity": "needs_review" if not incidents.is_empty() else "unverified_capabilities" if not unsupported.is_empty() or subjects.is_empty() else "no_detected_anomaly",
		"eligible_for_balance": incidents.is_empty() and unsupported.is_empty() and not subjects.is_empty(), "incidents": incidents,
		"cause_evidence_available": not subjects.is_empty(), "thresholds": thresholds, "time_is_quality_score": false,
		"coverage": {"subjects": subjects.size(), "unsupported_subjects": unsupported, "removed_without_death": removed.keys()},
		"explanation": "逐对象核对，不用泰坦状态编号解释其他兵种；异常／缺能力样本单列。未检出不证明无问题。"}

static func apply_replay_audit(analysis: Dictionary, audit: Dictionary, is_replay: bool) -> void:
	analysis["replay_audit"] = audit
	if not is_replay:
		return
	analysis.eligible_for_balance = false
	analysis.sample_validity = "replay_diverged" if String(audit.get("status", "")) == "diverged" else "replay_only"

static func apply_temporal_audit(analysis: Dictionary, audit: Dictionary) -> void:
	analysis["temporal_audit"] = audit
	if bool(audit.get("trusted", false)):
		return
	analysis.eligible_for_balance = false
	if String(analysis.sample_validity) == "no_detected_anomaly":
		analysis.sample_validity = "mechanics_only" if bool(audit.get("fixed_step_accelerated", false)) or audit.get("mode") == "fast" else "unverified_timing"

static func _close_window(window: Dictionary, end: Dictionary, events: Array, output: Array, settings: Dictionary) -> void:
	if end.is_empty() or float(end.time) - float(window.start.time) < float(settings.stall_seconds):
		return
	var damage := 0.0
	for event: Dictionary in events:
		if float(event.time) >= float(window.start.time) and float(event.time) <= float(end.time) + 0.00001 and event.kind == "boss_damage":
			damage += float(event.details.get("damage", 0.0))
	if damage <= 0.0:
		return
	output.append({"kind": "boss_pressure_lost", "start": float(window.start.time), "end": float(end.time),
		"subject_id": window.start.get("subject_id", "legacy_boss"), "subject_title": window.start.get("subject_title", "Boss"),
		"duration": float(end.time) - float(window.start.time), "boss_damage": damage,
		"position": window.start.get("boss_position", window.start.get("boss", [])),
		"cause": classify(end.get("diagnostic", window.start.get("diagnostic", {})), end),
		"evidence": ["正常行动状态", "位置在诊断容差内", "没有新的起招", "期间继续受到伤害"],
		"context_start": maxf(float(window.start.time) - float(settings.context_seconds), 0.0)})

static func classify(diagnostic: Dictionary, row: Dictionary = {}) -> Dictionary:
	if diagnostic.is_empty():
		return {"code": "missing_cause_evidence", "summary": "旧实录可确认交战停摆，未记录物理／决策原因", "certainty": "insufficient", "missing": ["高度和速度", "物理处理分支", "碰撞", "导航状态", "选招拒绝"]}
	var trace: Dictionary = diagnostic.get("trace", {})
	var navigation: Dictionary = diagnostic.get("navigation", {})
	var decision: Dictionary = diagnostic.get("decision", {})
	var code := "unclassified_stall"
	var summary := "停摆事实已确认，现有分支仍不足以确定根因"
	if not bool(diagnostic.get("physics_enabled", true)):
		code = "physics_suspended"
		summary = "交战对象物理处理被关闭；需核对停顿的调用来源"
		if not diagnostic.get("hitstop_restore", {}).is_empty():
			summary = "交战对象被伤害顿帧持有处理开关；见恢复目标和连续 token"
	elif not bool(diagnostic.get("ai_enabled", true)):
		code = "ai_disabled"
		summary = "交战对象 AI 已关闭，不能计为正常交战样本"
	elif not bool(diagnostic.get("target_alive", true)):
		code = "target_missing"
		summary = "活着的玩家未成为有效攻击目标"
	elif String(trace.get("branch", "")) == "navigation_override":
		code = "navigation_override_no_progress"
		summary = "导航接管并提前返回，本轮普通攻击判定未执行"
		if bool(navigation.get("job_pending", false)) and String(navigation.get("status", "")) == "checking":
			code = "navigation_plan_wait"
			summary = "导航持续等待规划，接管分支阻止了后续选招"
		elif not String(navigation.get("failure", "")).is_empty():
			code = "navigation_rejected"
			summary = "导航接管无进展，记录到拒绝原因：" + String(navigation.failure)
	elif String(decision.get("selected", "_not_run")) == "" and int(decision.get("engine_frame", -1)) >= int(row.get("engine_frame", 0)) - 60:
		code = "no_legal_attack"
		summary = "选招实际执行，但没有合法候选；见门槛与跃击拒绝原因"
	var wall_contacts := 0
	for contact: Dictionary in diagnostic.get("contacts", []):
		if absf(float(contact.normal[1])) < 0.7:
			wall_contacts += 1
	return {"code": code, "summary": summary, "certainty": "observed_branch" if code != "unclassified_stall" else "insufficient",
		"trace": trace, "navigation": navigation, "decision": decision, "contacts": diagnostic.get("contacts", []),
		"motion": diagnostic.get("motion", {}), "hitstop_restore": diagnostic.get("hitstop_restore", {}), "hitstop_token": diagnostic.get("hitstop_token", 0),
		"wall_contacts": wall_contacts, "on_floor": diagnostic.get("on_floor"), "note": "分支定位是运行证据，碰撞根因或调用来源仍须结合片段验证"}

static func read_recording(directory: String) -> Dictionary:
	var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("result.json")))
	if not report is Dictionary:
		return {}
	var rows: Array = []
	var snapshots := directory.path_join("snapshots.jsonl")
	if FileAccess.file_exists(snapshots):
		rows = read_lines(snapshots)
	else:
		var file := FileAccess.open(directory.path_join("timeline.csv"), FileAccess.READ)
		if file == null:
			return {}
		var header := file.get_csv_line()
		while not file.eof_reached():
			var line := file.get_csv_line()
			if line.size() != header.size():
				continue
			var row := {}
			for index in range(header.size()):
				row[header[index]] = line[index]
			rows.append({"time": float(row.seconds), "state": int(row.boss_state), "boss_hp": float(row.boss_hp),
				"player_hp": float(row.player_hp), "boss": [float(row.boss_x), float(row.boss_z)], "player": [float(row.player_x), float(row.player_z)]})
	var events := read_lines(directory.path_join("events.jsonl"))
	var previous: Dictionary = report.get("analysis", {})
	var settings: Dictionary = report.get("conditions", {}).get("diagnostics", previous.get("thresholds", {}))
	var analysis := analyze(rows, events, String(report.outcome), settings)
	apply_replay_audit(analysis, previous.get("replay_audit", {"status": "unverified_missing_audit"}), String(report.get("conditions", {}).get("mode", "")) == "replay")
	apply_temporal_audit(analysis, previous.get("temporal_audit", {"trusted": false, "status": "legacy_missing_wall_clock"}))
	analysis["clips"] = previous.get("clips", [])
	if String(report.get("conditions", {}).get("mode", "")) == "imitate":
		analysis["imitation_audit"] = previous.get("imitation_audit", {})
		analysis.eligible_for_balance = false
		if analysis.sample_validity == "no_detected_anomaly":
			analysis.sample_validity = "unverified_player_model"
	if report.get("conditions", {}).get("mode") == "manual" and report.conditions.get("capture_origin", "") != "human":
		analysis.eligible_for_balance = false
		if analysis.sample_validity == "no_detected_anomaly":
			analysis.sample_validity = "synthetic_or_unverified_capture"
	var integrity: Array[String] = []
	if rows.is_empty():
		integrity.append("没有可读状态时间线")
	elif float(report.get("observation_seconds", 0.0)) - float(rows[-1].time) > maxf(float(settings.get("snapshot_interval", 0.25)) + 0.1, 0.5):
		integrity.append("状态时间线早于报告结束，可能截断")
	if events.is_empty() or String(events[-1].get("kind", "")) != "end" or String(events[-1].get("details", {}).get("outcome", "")) != String(report.outcome):
		integrity.append("缺少与结果一致的结束事件，事件文件可能缺失或截断")
	analysis["data_integrity_problems"] = integrity
	if not integrity.is_empty():
		analysis.sample_validity = "incomplete_recording"
		analysis.eligible_for_balance = false
	return {"source_report": report, "rows": rows, "events": events, "analysis": analysis}

static func read_lines(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var rows: Array = []
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var row: Variant = JSON.parse_string(line)
		if not row is Dictionary:
			push_error("诊断记录格式错误：" + path)
			return []
		rows.append(row)
	return rows
