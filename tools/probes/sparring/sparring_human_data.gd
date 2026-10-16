extends RefCounted
## 可解释的真人遥测与片段检索基线。标签不等于推断；不由胜率反推性格或技能。
const Inputs := preload("res://tools/probes/sparring/sparring_input.gd")
const Analysis := preload("res://tools/probes/sparring/sparring_analysis.gd")
const CHUNK_SECONDS := 0.2
const MAX_CHUNKS := 4096

static func distribution(values: Array) -> Dictionary:
	if values.is_empty():
		return {"n": 0, "p10": null, "p50": null, "p90": null}
	var ordered := values.duplicate()
	ordered.sort()
	return {"n": ordered.size(), "p10": ordered[int((ordered.size() - 1) * 0.1)], "p50": ordered[int((ordered.size() - 1) * 0.5)], "p90": ordered[int((ordered.size() - 1) * 0.9)]}

static func origin(report: Dictionary) -> String:
	var mode := String(report.get("conditions", {}).get("mode", "auto"))
	if mode == "manual":
		return String(report.conditions.get("capture_origin", "human_legacy"))
	return "empirical_simulation" if mode == "imitate" else "input_replay" if mode == "replay" else "scripted_agent"

static func summarize(report: Dictionary, frames: Array, events: Array) -> Dictionary:
	var duration := 0.0
	var moving := 0.0
	var shooting := 0.0
	var aimed := 0.0
	var strafing := 0.0
	var backing := 0.0
	var moving_fire := 0.0
	var danger_time := 0.0
	var danger_shoot := 0.0
	var path := 0.0
	var reversals := 0
	var toward := 0.0
	var away_time := 0.0
	var orbit := 0.0
	var blocked_intent := 0.0
	var route: Array = []
	var previous: Dictionary = {}
	var cells := {}
	var distances: Array = []
	var speeds: Array = []
	var turns: Array = []
	var attempts := {}
	var responses: Array = []
	var episode: Dictionary = {}
	var last_warning := ""
	for row: Dictionary in frames:
		var delta := float(row.get("delta", 1.0 / float(report.get("physics_ticks", 60))))
		duration += delta
		var movement := Vector2(float(row.move[0]), float(row.move[1]))
		var active := movement.length() > 0.15
		moving += delta if active else 0.0
		shooting += delta if bool(row.held.get("shoot", false)) else 0.0
		aimed += delta if bool(row.held.get("aim", false)) else 0.0
		strafing += delta if absf(movement.x) > 0.15 else 0.0
		backing += delta if movement.y > 0.15 else 0.0
		moving_fire += delta if active and bool(row.held.get("shoot", false)) else 0.0
		for action: String in row.just:
			if bool(row.just[action]):
				attempts[action] = int(attempts.get(action, 0)) + 1
		var context: Dictionary = row.get("context", {})
		if bool(context.get("visible", false)):
			distances.append(float(context.distance))
		if bool(context.get("danger", false)):
			danger_time += delta
			danger_shoot += delta if bool(row.held.get("shoot", false)) else 0.0
		if not previous.is_empty():
			turns.append(absf(rad_to_deg(wrapf(float(row.yaw) - float(previous.yaw), -PI, PI))) / delta)
			var prior_move := Vector2(float(previous.move[0]), float(previous.move[1]))
			if active and prior_move.length() > 0.15 and movement.normalized().dot(prior_move.normalized()) < -0.5:
				reversals += 1
			if row.has("position") and previous.has("position"):
				var displacement := Analysis.position(row, "position") - Analysis.position(previous, "position")
				var length := Vector2(displacement.x, displacement.z).length()
				path += length
				speeds.append(length / delta)
				blocked_intent += delta if active and length / delta < 0.15 and not bool(context.get("locked", false)) else 0.0
				if context.has("target_position") and length > 0.001:
					var away := Analysis.position(row, "position") - Analysis.position(context, "target_position")
					away.y = 0.0
					var radial := displacement.dot(away.normalized()) / delta
					toward += delta if radial < -0.35 else 0.0
					away_time += delta if radial > 0.35 else 0.0
					orbit += delta if absf(radial) <= 0.35 and length / delta > 0.35 else 0.0
		if row.has("position"):
			var position := Analysis.position(row, "position")
			cells["%d,%d" % [floori(position.x / 2.0), floori(position.z / 2.0)]] = true
			if route.is_empty() or float(row.time) - float(route[-1][0]) >= 0.1:
				route.append([row.time, position.x, position.z])
		var key := String(context.get("warning_key", "")) if bool(context.get("danger", false)) else ""
		if key != last_warning:
			if not episode.is_empty():
				responses.append(episode)
			episode = {}
			if not key.is_empty() and bool(context.get("danger", false)):
				episode = {"key": key, "start": row.time, "status": "no_observed_response", "observation_end": row.time,
					"simultaneous_or_anticipatory": bool(row.just.get("dodge", false)),
					"dodge_request_delay": null, "movement_change_delay": null, "already_moving": active,
					"already_rolling": bool(context.get("rolling", false)), "dodge_ready_at_onset": bool(context.get("dodge_ready", false)),
					"locked_at_onset": bool(context.get("locked", false))}
			last_warning = key
		if not episode.is_empty():
			episode.observation_end = row.time
			if bool(row.just.get("dodge", false)) and episode.dodge_request_delay == null:
				episode.dodge_request_delay = float(row.time) - float(episode.start)
				episode.status = "request_observed"
			if not previous.is_empty() and episode.movement_change_delay == null:
				var prior := Vector2(float(previous.move[0]), float(previous.move[1]))
				if (movement - prior).length() > 0.5:
					episode.movement_change_delay = float(row.time) - float(episode.start)
		previous = row
	if not episode.is_empty():
		episode["recording_ended"] = true
		responses.append(episode)
	var accepted := {}
	var releases := {}
	for event: Dictionary in events:
		if event.kind == "input_result":
			var action := String(event.details.action)
			if not accepted.has(action):
				accepted[action] = {"accepted": 0, "rejected": 0}
			accepted[action]["accepted" if bool(event.details.accepted) else "rejected"] += 1
		elif event.kind == "attack_released":
			var source := String(event.details.source)
			releases[source] = int(releases.get(source, 0)) + 1
	var delays: Array = []
	var unresolved := 0
	for response: Dictionary in responses:
		if response.dodge_request_delay != null and not response.already_rolling and not response.locked_at_onset and response.dodge_ready_at_onset and not response.simultaneous_or_anticipatory:
			delays.append(response.dodge_request_delay)
		elif response.dodge_request_delay == null:
			unresolved += 1
	var seconds := maxf(duration, 0.001)
	return {"version": 1, "origin": origin(report), "participant": report.get("conditions", {}).get("participant", {}),
		"seconds": duration, "input_frames": frames.size(), "movement": {"input_fraction": moving / seconds,
			"toward_visible_target_fraction": toward / seconds, "away_from_visible_target_fraction": away_time / seconds,
			"tangential_visible_target_fraction": orbit / seconds, "moving_input_low_displacement_fraction": blocked_intent / seconds, "path_samples_xz": route,
			"strafe_fraction": strafing / seconds, "backward_fraction": backing / seconds, "direction_reversals": reversals,
			"horizontal_path_m": path if not speeds.is_empty() else null, "speed_mps": distribution(speeds), "occupied_2m_cells": cells.size(),
			"visible_target_distance_m": distribution(distances), "view_turn_degrees_per_second": distribution(turns)},
		"attack": {"shoot_held_fraction": shooting / seconds, "aim_held_fraction": aimed / seconds, "moving_fire_fraction": moving_fire / seconds,
			"danger_shoot_fraction": danger_shoot / danger_time if danger_time > 0 else null, "action_requests": attempts, "action_results": accepted, "actual_releases": releases},
		"response": {"episodes": responses, "eligible_dodge_request_delay_seconds": distribution(delays), "no_observed_dodge_request": unresolved,
			"definition": "首次几何可见且覆盖玩家的公开预警到闪避请求；不是人眼察觉或纯反应时间。已行动、锁定、冷却与未响应保留，不能把它们过滤后称群体反应速度。采样误差至多约0.1秒，声效和仅动作预兆尚未覆盖。"},
		"interpretation": "输入意图与实际位移／释放分开。标签由采集者填写，不自动分高手／菜鸟／激进。单局不是稳定人格或玩家人口样本。"}

static func context_score(current: Dictionary, recorded: Dictionary) -> float:
	for key in ["visible", "danger", "rolling", "locked", "dodge_ready", "ammo_empty", "reloading"]:
		if current.get(key) != recorded.get(key):
			return INF
	if absf(float(current.get("danger_age", 0)) - float(recorded.get("danger_age", 0))) > 0.25 and bool(current.get("danger", false)):
		return INF
	var gap := absf(float(current.get("distance", -1)) - float(recorded.get("distance", -1)))
	if gap > 8.0 or absi(int(current.get("visible_count", 0)) - int(recorded.get("visible_count", 0))) > 2:
		return INF
	return gap / 4.0 + absf(float(current.get("shield_ratio", 0)) - float(recorded.get("shield_ratio", 0))) * 2.0 + absf(float(current.get("health_ratio", 0)) - float(recorded.get("health_ratio", 0))) * 2.0 + absf(float(current.get("warning_progress", 0)) - float(recorded.get("warning_progress", 0)))

static func candidates(chunks: Array, context: Dictionary) -> Array:
	var best := INF
	var selected: Array = []
	for index in range(chunks.size()):
		var score := context_score(context, chunks[index].context)
		if not is_finite(score):
			continue
		if score < best - 0.1:
			best = score
			selected = [index]
		elif score <= best + 0.1:
			selected.append(index)
	return selected

static func fit(report: Dictionary, frames: Array, audit: Dictionary) -> Dictionary:
	if String(report.get("conditions", {}).get("mode", "")) != "manual" or not bool(audit.get("complete_contract", false)) or frames.size() < 120:
		return {}
	var all_chunks: Array = []
	var chunk: Dictionary = {}
	var elapsed := 0.0
	var previous_yaw := float(frames[0].yaw)
	for row: Dictionary in frames:
		var context: Dictionary = row.get("context", {})
		if context.is_empty():
			return {}
		if chunk.is_empty():
			chunk = {"context": context, "start": row.time, "frames": []}
			elapsed = 0.0
		chunk.frames.append({"delta": row.delta, "held": row.held, "just": row.just, "move": row.move,
			"aim_captured": row.aim_captured, "yaw_delta": wrapf(float(row.yaw) - previous_yaw, -PI, PI), "pitch": row.pitch,
			"yaw_offset": wrapf(float(row.yaw) - float(context.target_yaw), -PI, PI), "pitch_offset": float(row.pitch) - float(context.target_pitch)})
		previous_yaw = float(row.yaw)
		elapsed += float(row.delta)
		if elapsed >= CHUNK_SECONDS:
			all_chunks.append(chunk)
			chunk = {}
	# 留最后四分之一连续时间段，边界前留1秒；不随机拆相邻物理帧。
	var cutoff := float(frames[-1].time) * 0.75
	var training: Array = []
	var heldout: Array = []
	for item: Dictionary in all_chunks:
		if float(item.start) + CHUNK_SECONDS < cutoff - 1.0:
			training.append(item)
		elif float(item.start) >= cutoff:
			heldout.append(item)
	if training.is_empty():
		return {}
	var original_size := training.size()
	if training.size() > MAX_CHUNKS:
		var sampled: Array = []
		for index in range(MAX_CHUNKS):
			sampled.append(training[int(float(index) * training.size() / MAX_CHUNKS)])
		training = sampled
	var covered := 0
	var shoot_error := 0.0
	var movement_error := 0.0
	for item: Dictionary in heldout:
		var matches := candidates(training, item.context)
		if matches.is_empty():
			continue
		covered += 1
		var prediction: Dictionary = training[int(matches[0])].frames[0]
		var actual: Dictionary = item.frames[0]
		shoot_error += 0.0 if prediction.held.get("shoot", false) == actual.held.get("shoot", false) else 1.0
		movement_error += Vector2(float(prediction.move[0]), float(prediction.move[1])).distance_to(Vector2(float(actual.move[0]), float(actual.move[1])))
	return {"version": 1, "kind": "contextual_action_chunks", "participant": report.get("conditions", {}).get("participant", {}),
		"reference_metrics": features(summarize(report, frames, [])),
		"source_origin": origin(report), "source_directory": report.get("directory", ""), "source_gameplay_sha256": report.get("gameplay_sha256", {}),
		"source_eligible": bool(report.get("analysis", {}).get("eligible_for_balance", false)), "chunks": training,
		"training_chunks_before_limit": original_size, "chunk_seconds": CHUNK_SECONDS,
		"validation": {"split": "last_quarter_time_block_with_1s_gap", "independent_session": false, "heldout_chunks": heldout.size(), "covered_chunks": covered,
			"shoot_first_frame_error": shoot_error / covered if covered > 0 else null, "movement_first_frame_l2": movement_error / covered if covered > 0 else null,
			"status": "exploratory_only_not_validated_player_model"},
		"limitations": ["近邻情境片段基线，不是成熟神经模仿学习训练器", "未覆盖情境输出中性输入并报告，不暗中切高手脚本", "相似视线目标重新对齐；不学习完整寻路、长远策略或人类认知", "时间段留出只有粗略首帧诊断，仍需独立真人局与闭环模拟分布验证"]}

static func features(summary: Dictionary) -> Dictionary:
	return {"moving_fraction": summary.movement.input_fraction, "shoot_fraction": summary.attack.shoot_held_fraction,
		"backward_fraction": summary.movement.backward_fraction, "strafe_fraction": summary.movement.strafe_fraction,
		"visible_target_distance_p50_m": summary.movement.visible_target_distance_m.p50,
		"view_turn_p50_degrees_per_second": summary.movement.view_turn_degrees_per_second.p50,
		"dodge_requests_per_minute": 60.0 * int(summary.attack.action_requests.get("dodge", 0)) / maxf(float(summary.seconds), 0.001)}

static func compare_style(summary: Dictionary, model: Dictionary) -> Dictionary:
	var actual := features(summary)
	var differences := {}
	for key: String in model.get("reference_metrics", {}):
		var prior: Variant = model.reference_metrics[key]
		var current: Variant = actual.get(key)
		differences[key] = float(current) - float(prior) if prior != null and current != null else null
	return {"reference": model.get("reference_metrics", {}), "simulation": actual, "simulation_minus_source": differences,
		"source_input_sha256": model.get("source_input_sha256", ""), "validated_as_player": false,
		"note": "闭环模拟与源局的可解释行为差异。遭遇不同也会改变指标；不是独立留出验证，不据此宣称模型像真人。"}

static func review(directory: String) -> Dictionary:
	if not FileAccess.file_exists(directory.path_join("result.json")):
		return {}
	var data := Analysis.read_recording(directory)
	if data.is_empty():
		return {}
	var input := Inputs.read(directory.path_join("inputs.jsonl"))
	var report: Dictionary = data.source_report.duplicate(true)
	report.analysis = data.analysis
	var summary := summarize(report, input.frames, data.events)
	summary["input_audit"] = {"complete_contract": input.complete_contract, "problems": input.problems,
		"reported_frames_match": int(report.get("input_frames", -1)) == input.frames.size()}
	summary["source_directory"] = directory
	summary["source_input_sha256"] = FileAccess.get_sha256(directory.path_join("inputs.jsonl"))
	summary["sample_analysis"] = data.analysis
	var model := fit(report, input.frames, input)
	if not bool(summary.input_audit.reported_frames_match) or not data.analysis.get("data_integrity_problems", []).is_empty():
		model = {}
	if not model.is_empty():
		model["source_input_sha256"] = summary.source_input_sha256
	return {"summary": summary, "model": model}

static func write_bundle(output: String, summary: Dictionary, model: Dictionary) -> bool:
	for name: String in ["human_analysis.json", "human_model.json"]:
		var value: Dictionary = summary if name == "human_analysis.json" else model
		if value.is_empty():
			continue
		var file := FileAccess.open(output.path_join(name), FileAccess.WRITE)
		if file == null:
			return false
		file.store_string(JSON.stringify(value, "  ") + "\n")
		file.close()
	var text := FileAccess.open(output.path_join("真人行为分析.md"), FileAccess.WRITE)
	if text == null:
		return false
	text.store_string("# 真人操作行为分析\n\n来源：%s；采集标签：%s。\n\n%s\n\n" % [summary.origin, str(summary.participant), summary.interpretation])
	text.store_string("移动意图 %.1f%%；实际水平路程 %s 米；后退 %.1f%%；横移 %.1f%%；方向反转 %d 次。可见目标距离分布 %s。\n\n" % [100.0 * summary.movement.input_fraction, str(summary.movement.horizontal_path_m), 100.0 * summary.movement.backward_fraction, 100.0 * summary.movement.strafe_fraction, summary.movement.direction_reversals, str(summary.movement.visible_target_distance_m)])
	text.store_string("开火按住 %.1f%%；瞄准 %.1f%%；移动开火 %.1f%%。动作请求 %s；实际生效／失败 %s；实际攻击释放 %s。\n\n" % [100.0 * summary.attack.shoot_held_fraction, 100.0 * summary.attack.aim_held_fraction, 100.0 * summary.attack.moving_fire_fraction, str(summary.attack.action_requests), str(summary.attack.action_results), str(summary.attack.actual_releases)])
	text.store_string("响应间隔：%s；未观察到闪避请求 %d 次。%s\n\n" % [str(summary.response.eligible_dodge_request_delay_seconds), summary.response.no_observed_dodge_request, summary.response.definition])
	text.store_string("输入核对：%s。样本诊断：%s。\n\n模型：%s。未经独立局验证的模型不会进入正常交战平衡统计。固定操作回放、经验模拟与真人样本分别记录；不由有限样本推断全部玩家。\n" % [str(summary.get("input_audit", {})), str(summary.get("sample_analysis", {}).get("sample_validity", "见原报告")), str(model.get("validation", "缺少新版情境／录制过短，不生成模型"))])
	text.close()
	var route: Array = summary.movement.get("path_samples_xz", [])
	if route.size() >= 2:
		var min_x := INF
		var min_z := INF
		var max_x := -INF
		var max_z := -INF
		for point: Array in route:
			min_x = minf(min_x, float(point[1]))
			max_x = maxf(max_x, float(point[1]))
			min_z = minf(min_z, float(point[2]))
			max_z = maxf(max_z, float(point[2]))
		var scale := minf(700.0 / maxf(max_x - min_x, 1), 400.0 / maxf(max_z - min_z, 1))
		var points := ""
		for point: Array in route:
			points += "%.2f,%.2f " % [40 + (float(point[1]) - min_x) * scale, 50 + (float(point[2]) - min_z) * scale]
		var svg := FileAccess.open(output.path_join("movement_path.svg"), FileAccess.WRITE)
		if svg == null:
			return false
		svg.store_string('<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500"><rect width="800" height="500" fill="#15202b"/><text x="20" y="25" fill="white">Observed movement XZ; world metres; no map collision overlay</text><polyline fill="none" stroke="#55c9ba" stroke-width="2" points="%s"/></svg>' % points)
		svg.close()
	return true

static func model_problem(model: Variant) -> String:
	if not model is Dictionary or model.get("kind") != "contextual_action_chunks" or int(model.get("version", 0)) != 1 or not model.get("chunks") is Array or model.chunks.is_empty() or model.chunks.size() > MAX_CHUNKS:
		return "经验模型结构无效"
	for chunk: Variant in model.chunks:
		if not chunk is Dictionary or not chunk.get("context") is Dictionary or not chunk.get("frames") is Array or chunk.frames.is_empty() or chunk.frames.size() > 250:
			return "经验片段无效"
		for key: String in ["distance", "visible_count", "danger_age", "warning_progress", "health_ratio", "shield_ratio"]:
			if not Inputs.number(chunk.context.get(key)):
				return "经验情境包含非法数值"
		for key: String in ["visible", "danger", "rolling", "locked", "dodge_ready", "ammo_empty", "reloading"]:
			if not chunk.context.get(key) is bool:
				return "经验情境能力缺失"
		for row: Variant in chunk.frames:
			if not row is Dictionary or not row.get("held") is Dictionary or not row.get("just") is Dictionary or not row.get("move") is Array or row.move.size() != 2 or not row.get("aim_captured") is bool:
				return "经验片段输入无效"
			for key: String in ["delta", "yaw_delta", "pitch", "yaw_offset", "pitch_offset"]:
				if not Inputs.number(row.get(key)):
					return "经验片段包含非法数值"
			if float(row.delta) < 0.001 or float(row.delta) > 0.25:
				return "经验片段步长越界"
			if not Inputs.number(row.move[0]) or not Inputs.number(row.move[1]) or Vector2(float(row.move[0]), float(row.move[1])).length() > 1.001:
				return "经验移动输入越界"
			for values: Dictionary in [row.held, row.just]:
				for value: Variant in values.values():
					if not value is bool:
						return "经验按键非布尔值"
	return ""

static func replay_options(directory: String) -> Dictionary:
	if not FileAccess.file_exists(directory.path_join("result.json")):
		return {}
	var data := Analysis.read_recording(directory)
	var input := Inputs.read(directory.path_join("inputs.jsonl"))
	if data.is_empty() or not input.problems.is_empty():
		return {}
	var report: Dictionary = data.source_report
	var problems: Array = []
	if not bool(input.complete_contract):
		problems.append("旧输入缺少捕获状态／步长")
	if input.frames.size() != int(report.get("input_frames", -1)):
		problems.append("输入总帧数与原报告不符")
	if int(report.get("physics_ticks", 0)) != Engine.physics_ticks_per_second or report.get("engine", {}).get("string", "") != Engine.get_version_info().string:
		problems.append("引擎版本或物理频率不同")
	for row: Dictionary in input.frames:
		if row.has("delta") and absf(float(row.delta) - 1.0 / Engine.physics_ticks_per_second) > 0.0001:
			problems.append("原局步长不同，不能按当前物理帧还原")
			break
	for path: String in report.get("gameplay_sha256", {}):
		if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != report.gameplay_sha256[path]:
			problems.append("玩法版本不同：" + path)
	for issue: String in data.analysis.get("data_integrity_problems", []):
		problems.append(issue)
	var options: Dictionary = report.conditions.duplicate(true)
	options.merge({"mode": "replay", "autostart": true, "replay_path": directory.path_join("inputs.jsonl"),
		"reference_report": directory.path_join("result.json"), "replay_preflight": {"compatible": problems.is_empty(), "problems": problems,
			"source_input_sha256": FileAccess.get_sha256(directory.path_join("inputs.jsonl")), "source_origin": origin(report)}}, true)
	return options

static func dataset(manifest: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest))
	if not parsed is Dictionary or not parsed.get("recordings") is Array or parsed.recordings.size() > 3000:
		return {}
	var rows: Array = []
	var groups := {}
	var seen := {}
	var duplicate_count := 0
	for value: Variant in parsed.recordings:
		if not value is String:
			return {}
		var directory: String = value if value.is_absolute_path() else manifest.get_base_dir().path_join(value)
		var reviewed := review(directory)
		if reviewed.is_empty():
			rows.append({"directory": directory, "status": "missing_or_invalid"})
			continue
		var summary: Dictionary = reviewed.summary
		var hash_key := String(summary.source_input_sha256)
		if seen.has(hash_key):
			duplicate_count += 1
			continue
		seen[hash_key] = true
		rows.append(summary)
		if summary.origin != "human" or not bool(summary.sample_analysis.eligible_for_balance) or not bool(summary.input_audit.complete_contract) or not bool(summary.input_audit.reported_frames_match):
			continue
		var raw: Dictionary = Analysis.read_recording(directory).source_report
		var identity := {"participant": summary.participant, "scenario": raw.conditions.get("scenario", {}),
			"selection": raw.conditions.get("group_selection", {}), "gameplay": raw.get("gameplay_sha256", {})}
		# 通过唯一录制数与已标注玩家分别计数；anonymous 不能冒充多个已知玩家。
		var key := JSON.stringify(identity).sha256_text()
		if not groups.has(key):
			groups[key] = {"identity": identity, "recordings": 0, "wins": 0, "deaths": 0, "censored": 0, "sessions": []}
		var group: Dictionary = groups[key]
		group.recordings += 1
		group.sessions.append({"directory": directory, "movement": summary.movement, "attack": summary.attack, "response": summary.response})
		if raw.outcome in ["enemies_defeated", "boss_dead"]:
			group.wins += 1
		elif raw.outcome == "player_dead":
			group.deaths += 1
		else:
			group.censored += 1
	return {"version": 1, "recordings": rows, "duplicates_excluded": duplicate_count, "eligible_human_cohorts": groups.values(),
		"note": "同源重放／模拟、自动注入、旧缺输入合同及异常局不增加有效真人样本。按玩家标签／实际遭遇／玩法版本分层，保留逐局分布；自报风格不是自动聚类结论。"}
