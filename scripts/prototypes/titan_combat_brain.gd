extends RefCounted
## 独立冷却与记忆不阻止移动；只在当前合法候选之间选择。
var cooldowns := {"slam": 0.0, "sweep": 0.0, "leap": 0.0, "thrust": 0.0, "triple_slam":0.0}
var approach_remaining := 0.0
var chase_time := 0.0
var far_time := 0.0
var near_time := 0.0
var last_skill := ""
var last_result := ""
var last_established_near := false
var history: Array[Dictionary] = []
var _settings: Dictionary
var elapsed := 0.0
var group_index := 0
var group_count := 0
var link_elapsed := 0.0
var group_limit := 2
var group_result := "ready"

func rhythm_enabled() -> bool:
	return bool(_settings.get("offense_enabled", false))

func commit_offense(rage: bool, heavy: bool) -> void:
	if not rhythm_enabled():
		return
	if group_count == 0:
		group_index += 1
		# 已开始的一组不因半血切换临时多加一刀。
		group_limit = int(_settings.offense_rage_limit if rage else _settings.offense_front_limit)
	group_count += 1
	link_elapsed = 0.0
	group_result = "heavy" if heavy else "pressure"

func finish_group(reason: String) -> void:
	group_count = 0
	link_elapsed = 0.0
	group_result = reason

func needs_heavy(rage := false) -> bool:
	if not rhythm_enabled():
		return false
	var limit := group_limit if group_count > 0 else int(_settings.offense_rage_limit if rage else _settings.offense_front_limit)
	return group_count >= limit - 1

func link_expired(delta: float) -> bool:
	if not rhythm_enabled() or group_count == 0:
		return false
	link_elapsed += delta
	return link_elapsed >= float(_settings.offense_link_timeout)

func rhythm_snapshot() -> Dictionary:
	return {"enabled": rhythm_enabled(), "group": group_index, "count": group_count,
		"limit": group_limit, "link_elapsed": link_elapsed, "result": group_result}

func setup(settings: Dictionary) -> void:
	_settings = settings

func tick(delta: float) -> void:
	elapsed += delta
	for key: String in cooldowns:
		cooldowns[key] = maxf(float(cooldowns[key]) - delta, 0.0)
	approach_remaining = maxf(approach_remaining - delta, 0.0)

func observe_chase(delta: float, distance: float, near: bool) -> void:
	if near:
		near_time += delta
		far_time = 0.0
		if near_time >= float(_settings.near_confirm_time):
			chase_time = 0.0
	else:
		near_time = 0.0
		chase_time += delta
		far_time = far_time + delta if distance >= float(_settings.leap_far_distance) else 0.0

func wants_approach(distance: float) -> bool:
	return distance >= float(_settings.leap_min_distance) and (
		far_time >= float(_settings.far_confirm_time) or chase_time >= float(_settings.chase_failure_time))

func available(skill: String) -> bool:
	return float(cooldowns.get(skill, INF)) <= 0.0 and (skill != "leap" or approach_remaining <= 0.0)

func choose(candidates: Dictionary) -> String:
	var choice := ""
	var best := -INF
	for skill: String in candidates:
		if not available(skill):
			continue
		var score := float(candidates[skill])
		if skill == last_skill:
			score -= float(_settings.repeat_penalty)
			if last_result in ["miss", "blocked", "cancelled"]:
				score -= 0.25
		if score > best:
			best = score
			choice = skill
	return choice

func started(skill: String, reason: String, distance: float) -> void:
	cooldowns[skill] = float(_settings[skill + "_cooldown"])
	if skill == "leap":
		approach_remaining = float(_settings.approach_interval)
		chase_time = 0.0
		far_time = 0.0
	last_skill = skill
	last_result = "preparing"
	last_established_near = false
	history.append({"time": snappedf(elapsed, 0.001), "skill": skill, "reason": reason,
		"distance": snappedf(distance, 0.01), "result": last_result})
	if rhythm_enabled():
		history[-1]["rhythm"] = rhythm_snapshot()
	if history.size() > 64:
		history.pop_front()

func completed(result: String, established_near: bool) -> void:
	last_result = result
	last_established_near = established_near
	if not history.is_empty():
		history[-1].result = result
		history[-1].established_near = established_near
