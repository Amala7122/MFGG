extends RefCounted
## 独立冷却与记忆不阻止移动；只在当前合法候选之间选择。
var cooldowns := {"slam": 0.0, "sweep": 0.0, "leap": 0.0}
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
	if history.size() > 64:
		history.pop_front()

func completed(result: String, established_near: bool) -> void:
	last_result = result
	last_established_near = established_near
	if not history.is_empty():
		history[-1].result = result
		history[-1].established_near = established_near
