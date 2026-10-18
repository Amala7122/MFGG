extends RefCounted
## 分析实际事件，不能让诊断结果反向参与策略。截断窗口单列。
const Batch := preload("res://tools/probes/sparring/sparring_batch_report.gd")

static func summarize(events: Array, end_time: float) -> Dictionary:
	var result := {"version": 1, "shield_contacts": 0, "crystal_break_hits": 0,
		"sniper_shots": 0, "sniper_regions": {}, "protected_shots": 0,
		"windows": [], "damage_in_reward": 0.0, "damage_outside_reward": 0.0,
		"reward_share": null, "note": "伤害采用实际扣血，死亡截断的窗口不冒充完整窗口；命中轨迹不等于玩家看懂提示。"}
	var open := {}
	var first := {}
	for event: Dictionary in events:
		var details: Dictionary = event.details
		var id := String(details.get("subject_id", ""))
		var now := float(event.time)
		if event.kind == "sniper_trace":
			result.sniper_shots += 1
			var region := String(details.region)
			result.sniper_regions[region] = int(result.sniper_regions.get(region, 0)) + 1
			if bool(details.blocked):
				result.protected_shots += 1
		if event.kind == "break_progress":
			var reward: Dictionary = details.reward
			var field := String(details.field)
			if field in ["shield_hits", "crystal_hits"]:
				var before := int(details.before) if details.get("before") != null else 0
				var added := int(details.after) - before
				if added > 0:
					result["shield_contacts" if field == "shield_hits" else "crystal_break_hits"] += added
					var kind := "kneel" if field == "shield_hits" else "down"
					if before == 0:
						first[id + kind] = now
			if field == "state":
				if open.has(id) and int(details.after) != 13:
					_close(result, open[id], now, int(details.after) == 6)
					open.erase(id)
				if int(details.after) == 13 and not String(reward.get("kind", "")).is_empty():
					var kind := String(reward.kind)
					open[id] = {"subject_id": id, "kind": kind, "start": now, "damage": 0.0, "shots": 0,
						"earned_after_seconds": now - float(first[id + kind]) if first.has(id + kind) else null,
						"configured_seconds": reward.get("durations", {}).get("hold", null)}
		if event.kind == "enemy_damage":
			var reward: Dictionary = details.get("break_reward", {})
			var in_reward := int(reward.get("state", -1)) == 13 and not String(reward.get("kind", "")).is_empty()
			result["damage_in_reward" if in_reward else "damage_outside_reward"] += float(details.damage)
			if in_reward and open.has(id):
				open[id].damage += float(details.damage)
		if event.kind == "attack_released":
			for window: Dictionary in open.values():
				window.shots += 1
	for window: Dictionary in open.values():
		_close(result, window, end_time, true)
	var total := float(result.damage_in_reward) + float(result.damage_outside_reward)
	result.reward_share = float(result.damage_in_reward) / total if total > 0.0 else null
	result["offense"] = offense_summary(events)
	return result

static func offense_summary(events: Array) -> Dictionary:
	var result := {"attack_kinds": {}, "groups": 0, "single_heavy_groups": 0, "sequences": [], "unclassified_attack_events": 0, "scope": "有招组元数据的已出招记录；不把三招上限当实际三连招，普通敌人的文字攻击名保留在通用事件统计"}
	var groups := {}
	for event: Dictionary in events:
		if event.kind != "enemy_attack": continue
		var details: Dictionary = event.details
		var raw_attack: Variant = details.get("attack", {})
		if not raw_attack is Dictionary or not raw_attack.get("rhythm") is Dictionary or not raw_attack.rhythm.has("group"):
			result.unclassified_attack_events += 1
			continue
		var attack: Dictionary = raw_attack
		var rhythm: Dictionary = attack.rhythm
		var skill := String(attack.get("skill", "unknown"))
		var key := String(details.get("subject_id", "legacy")) + ":" + str(rhythm.group)
		result.attack_kinds[skill] = int(result.attack_kinds.get(skill, 0)) + 1
		if not groups.has(key): groups[key] = []
		groups[key].append(skill)
	result.groups = groups.size()
	for sequence: Array in groups.values():
		if sequence.size() == 1 and sequence[0] in ["slam", "leap"]: result.single_heavy_groups += 1
		result.sequences.append(sequence)
	return result

static func _close(result: Dictionary, window: Dictionary, end_time: float, censored: bool) -> void:
	window["end"] = end_time
	window["observed_seconds"] = maxf(end_time - float(window.start), 0.0)
	window["censored"] = censored
	result.windows.append(window)

static func observed_progress(samples: Array) -> Dictionary:
	# 兼容A6旧真人录制：只把确实观察到的快照增量列出来，不补造逐发判区。
	var result := {"evidence": "snapshot_only_lower_bound", "crystal_hits_observed": 0, "shield_contacts_observed": 0, "down_holds_observed": 0,
		"per_shot_regions_available": false, "note": "快照间可能漏过增量／重置，数值是观察下界；旧实录缺逐发判区，不能追认每发未破击原因。"}
	var previous := {}
	for frame: Dictionary in samples:
		var opponents: Array = frame.get("opponents", [{"id": "legacy", "raw_state": frame.get("state", -1), "diagnostic": frame.get("diagnostic", {})}])
		for opponent: Dictionary in opponents:
			var id := String(opponent.id)
			var reward: Dictionary = opponent.get("diagnostic", {}).get("break_reward", {})
			var prior: Dictionary = previous.get(id, {})
			for pair: Array in [["crystal_hits", "crystal_hits_observed"], ["shield_hits", "shield_contacts_observed"]]:
				if reward.has(pair[0]):
					result[pair[1]] += maxi(int(reward[pair[0]]) - int(prior.get(pair[0], 0)), 0)
			if int(opponent.get("raw_state", -1)) == 13 and reward.get("kind") == "down" and int(prior.get("state", -1)) != 13:
				result.down_holds_observed += 1
			previous[id] = reward.duplicate()
	return result

static func contrast_rejection(current: Dictionary, prior: Dictionary, axis: String) -> String:
	# 不改变原来的严格配对契约；只在这里显式声明允许不同的唯一试验轴。
	var left := current.duplicate(true)
	var right := prior.duplicate(true)
	if axis == "policy":
		for row: Dictionary in [left, right]:
			row.conditions.erase("profile_id")
			for key in ["title", "strategy", "use_grenade", "use_q", "use_sniper"]:
				row.conditions.profile.erase(key)
	elif axis in ["down_hold_seconds", "pressure_trial"]:
		for row: Dictionary in [left, right]:
			var experiment: Dictionary = row.conditions.profile.get("boss_experiment", {}).duplicate()
			experiment.erase(axis)
			row.conditions.profile["boss_experiment"] = experiment
	else:
		return "未知对照轴"
	var reason := Batch.comparison_rejection(left, right)
	if not reason.is_empty(): return reason
	if axis == "pressure_trial" and not Batch.same_value(current.gameplay_sha256, prior.gameplay_sha256):
		return "压力候选须在同一实现／正式配置下，仅改变声明的实例试验"
	if axis == "down_hold_seconds":
		for row: Dictionary in [current, prior]:
			if not row.get("cycles", {}).get("windows", []).any(func(window): return window.get("kind") == "down" and float(window.get("observed_seconds", 0.0)) > 0.0):
				return "未实际进入倒地有效窗口，不能比较窗长收益"
	return ""

static func contrasts(rows: Array) -> Dictionary:
	var result := {"pairs": [], "exclusions": [], "not_a_population_estimate": true}
	for i in range(rows.size()):
		for j in range(i + 1, rows.size()):
			var a: Dictionary = rows[i]
			var b: Dictionary = rows[j]
			if a.is_empty() or b.is_empty() or int(a.conditions.seed) != int(b.conditions.seed):
				continue
			var same_policy := String(a.conditions.profile_id) == String(b.conditions.profile_id)
			var axis := "down_hold_seconds" if same_policy else "policy"
			if same_policy and a.conditions.profile.get("boss_experiment", {}).get("pressure_trial", "") != b.conditions.profile.get("boss_experiment", {}).get("pressure_trial", ""):
				axis = "pressure_trial"
			if same_policy and a.conditions.profile.get("boss_experiment", {}) == b.conditions.profile.get("boss_experiment", {}):
				continue
			var reason := contrast_rejection(a, b, axis)
			var pair := {"axis": axis, "left": a.directory, "right": b.directory,
				"left_policy": a.conditions.profile_id, "right_policy": b.conditions.profile_id, "seed": a.conditions.seed}
			if reason.is_empty():
				pair["hit_delta"] = int(b.unblocked_hits) - int(a.unblocked_hits)
				pair["boss_hp_delta"] = float(b.final_boss.hp) - float(a.final_boss.hp)
				pair["left_cycles"] = a.get("cycles", {})
				pair["right_cycles"] = b.get("cycles", {})
				result.pairs.append(pair)
			else:
				pair["reason"] = reason
				result.exclusions.append(pair)
	return result

static func write_clips(directory: String, samples: Array, cycles: Dictionary, events: Array) -> Array:
	var triggers: Array = []
	for window: Dictionary in cycles.windows.slice(0, 4):
		triggers.append({"kind": "reward_window", "start": window.start, "end": window.end, "window": window})
	for event: Dictionary in events:
		if event.kind == "sniper_trace" and (bool(event.details.blocked) or event.details.region != "crystal") and triggers.size() < 7:
			triggers.append({"kind": "sniper_not_breaking", "start": event.time, "end": event.time, "trace": event.details})
	var paths: Array = []
	for trigger: Dictionary in triggers:
		var rows := samples.filter(func(row: Dictionary): return float(row.time) >= float(trigger.start) - 1.0 and float(row.time) <= float(trigger.end) + 1.0)
		var name := "cycle_clip_%02d.json" % paths.size()
		var file := FileAccess.open(directory.path_join(name), FileAccess.WRITE)
		if file == null:
			push_error("循环分析片段输出失败")
			continue
		file.store_string(JSON.stringify({"trigger": trigger, "samples": rows, "sampling": "diagnostic_snapshots_not_video"}, "  ") + "\n")
		file.close()
		paths.append(name)
	return paths
