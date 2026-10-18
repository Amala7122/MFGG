extends RefCounted
## 被动观察：把奖励／后摇和追击、动作暂停分开，不以战斗总长或死亡率评分。
static func summarize(samples: Array, inputs: Array, events: Array, end_time: float) -> Dictionary:
	if samples.is_empty() or samples.any(func(frame): return not frame.get("diagnostic") is Dictionary):
		return {"status": "insufficient_diagnostic_snapshots", "note": "缺少原因快照，不能把未知暂停／后摇写成0秒"}
	# 编号只属于泰坦；普通兵适配的raw_state=-1不能冒充已识别的泰坦动作。
	if samples.any(func(frame): return frame.get("opponents", []).size() != 1 or frame.opponents[0].get("implementation") != "titan"):
		return {"status": "unsupported_pressure_model", "note": "该分段仅支持单体泰坦；其他Boss／混编继续使用通用逐对象分析，不套用泰坦状态编号"}
	var result := {"sampled_seconds": 0.0, "states_seconds": {}, "action_pause_seconds": 0.0,
		"heavy_recovery_seconds": 0.0, "reward_seconds": 0.0, "chase_idle_seconds": 0.0,
		"public_danger_seconds": 0.0, "shooting_without_public_danger_seconds": 0.0,
		"input_seconds": 0.0, "longest_chase_idle_seconds": 0.0, "scope": "快照分段积分；地面预警危及当前位置不等于所有威胁；不是好玩或人群难度评分"}
	result["status"] = "observed_diagnostic_snapshots"
	var shield_known := samples.all(func(frame): return frame.opponents[0].has("rage") and frame.opponents[0].has("mud_shield"))
	var front_active := 0.0
	var front_shield := 0.0
	var landing_time := -1.0
	var landing_links: Array = []
	var previous_state := -1
	var chase_run := 0.0
	for i in range(samples.size()):
		var frame: Dictionary = samples[i]
		var dt := maxf((float(samples[i + 1].time) if i + 1 < samples.size() else end_time) - float(frame.time), 0.0)
		var diagnostic: Dictionary = frame.get("diagnostic", {})
		var state := int(frame.get("state", -1))
		result.sampled_seconds += dt
		result.states_seconds[str(state)] = float(result.states_seconds.get(str(state), 0.0)) + dt
		if diagnostic.get("trace", {}).get("branch") == "grenade_stagger": result.action_pause_seconds += dt
		if bool(diagnostic.get("heavy_recovering", false)): result.heavy_recovery_seconds += dt
		var reward := not String(diagnostic.get("break_reward", {}).get("kind", "")).is_empty() or state == 15
		if reward: result.reward_seconds += dt
		if shield_known and not bool(frame.opponents[0].rage) and not reward and state not in [0, 6]:
			front_active += dt
			if bool(frame.opponents[0].mud_shield): front_shield += dt
		if state == 9 and previous_state != 9: landing_time = float(frame.time)
		if reward: landing_time = -1.0
		if landing_time >= 0.0 and state in [3, 4, 7, 16]:
			landing_links.append({"landing_observed_at": landing_time, "next_warning_observed_at": float(frame.time),
				"gap_seconds_approx": float(frame.time) - landing_time, "next_skill": diagnostic.get("active_skill", "unknown"),
				"scope": "快照首次观察边界，误差约一个采样间隔；不是精确命中时刻"})
			landing_time = -1.0
		previous_state = state
		if state in [1, 2] and not reward:
			result.chase_idle_seconds += dt
			chase_run += dt
			result.longest_chase_idle_seconds = maxf(result.longest_chase_idle_seconds, chase_run)
		else:
			chase_run = 0.0
	for frame: Dictionary in inputs:
		var dt := float(frame.delta)
		result.input_seconds += dt
		var danger := bool(frame.get("context", {}).get("danger", false))
		if danger: result.public_danger_seconds += dt
		if not danger and bool(frame.get("held", {}).get("shoot", false)): result.shooting_without_public_danger_seconds += dt
	var starts: Array = []
	for event: Dictionary in events:
		if event.kind == "enemy_attack": starts.append(float(event.time))
	var gaps: Array = []
	for i in range(1, starts.size()): gaps.append(starts[i] - starts[i - 1])
	gaps.sort()
	result["attack_start_gaps_including_rewards"] = {"count": gaps.size(), "median": gaps[int(gaps.size() / 2)] if not gaps.is_empty() else null, "max": gaps[-1] if not gaps.is_empty() else null}
	result["front_shield_coverage"] = {"status": "observed" if shield_known else "unknown_missing_opponent_shield", "active_seconds": front_active if shield_known else null, "shield_seconds": front_shield if shield_known else null, "fraction": front_shield / front_active if front_active > 0 else null, "scope": "排除出土、死亡及挣得奖励；不把狂暴无盾算盾空档"}
	result["landing_to_next_warning"] = landing_links
	return result
