extends RefCounted
## 陪练配置是诊断条件，不修改正式战斗参数。保存方案与设默认分开。
const PATH := "res://data/testing/titan_sparring.json"
const DiagnosticDefaults := preload("res://tools/probes/sparring/sparring_analysis.gd")
const Scenarios := preload("res://tools/probes/sparring/sparring_scenarios.gd")
const Groups := preload("res://tools/probes/sparring/sparring_groups.gd")
static var pending_run: Dictionary = {}

static func same_values(left: Variant, right: Variant) -> bool:
	# JSON 数字类型与 SpinBox 的浮点尾差不构成参数修改。
	if (left is float or left is int) and (right is float or right is int):
		return absf(float(left) - float(right)) <= 0.00000001
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key: Variant in left:
			if not right.has(key) or not same_values(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in range(left.size()):
			if not same_values(left[index], right[index]):
				return false
		return true
	return left == right

static func read_document() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not parsed is Dictionary or int(parsed.get("version", 0)) != 1 or not parsed.get("presets") is Dictionary:
		push_error("陪练配置格式错误：" + PATH)
		return {}
	for id: String in parsed.presets:
		var problem := validate_profile(parsed.presets[id])
		if not problem.is_empty():
			push_error("陪练方案 %s：%s" % [id, problem])
			return {}
	if not parsed.presets.has(String(parsed.get("active", ""))):
		push_error("陪练默认方案不存在")
		return {}
	return parsed

static func validate_profile(profile: Dictionary) -> String:
	if String(profile.get("strategy", "")) not in ["orbit", "reactive", "greedy"]:
		return "未知策略"
	for spec: Array in [["reaction_seconds", 0.0, 2.0], ["aim_error_degrees", 0.0, 15.0],
		["turn_degrees_per_second", 15.0, 360.0], ["preferred_distance", 5.0, 30.0],
		["dodge_progress", 0.0, 1.0], ["greed_seconds", 0.0, 1.0]]:
		var value: Variant = profile.get(spec[0])
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) < float(spec[1]) or float(value) > float(spec[2]):
			return "%s 超出范围" % spec[0]
	for key in ["use_grenade", "use_q", "use_sniper", "adapt_to_visible_range"]:
		if not profile.get(key) is bool:
			return key + " 必须是开关"
	return ""

static func write_document(document: Dictionary) -> Error:
	for id: String in document.presets:
		if not validate_profile(document.presets[id]).is_empty():
			return ERR_INVALID_DATA
	if not document.presets.has(String(document.get("active", ""))):
		return ERR_INVALID_DATA
	var file := FileAccess.open(PATH + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(document, "  ") + "\n")
	file.flush()
	var result := file.get_error()
	file.close()
	if result != OK:
		return result
	return DirAccess.rename_absolute(PATH + ".tmp", PATH)

static func resolve(options: Dictionary = {}) -> Dictionary:
	var document := read_document()
	if document.is_empty():
		return {}
	var id := String(options.get("profile_id", document.active))
	if not document.presets.has(id):
		push_error("陪练方案不存在：" + id)
		return {}
	var profile: Dictionary = document.presets[id].duplicate(true)
	if options.get("profile") is Dictionary:
		profile.merge(options.profile, true)
	if not validate_profile(profile).is_empty():
		push_error("陪练运行参数不合法")
		return {}
	if String(options.get("mode", "auto")) not in ["auto", "manual", "replay", "imitate"]:
		push_error("未知陪练模式")
		return {}
	if String(options.get("pacing", "realtime")) not in ["realtime", "fast"]:
		push_error("未知运行节奏")
		return {}
	var diagnostic: Variant = options.get("diagnostics", profile.get("diagnostics", document.get("diagnostics", {})))
	if not diagnostic is Dictionary:
		push_error("诊断参数必须为字典")
		return {}
	for spec: Array in [["stall_seconds", 0.5, 30], ["stationary_radius", 0.01, 2], ["snapshot_interval", 0.016, 1], ["context_seconds", 1, 15]]:
		if diagnostic.has(spec[0]) and (not (diagnostic[spec[0]] is float or diagnostic[spec[0]] is int) or not is_finite(float(diagnostic[spec[0]])) or float(diagnostic[spec[0]]) < float(spec[1]) or float(diagnostic[spec[0]]) > float(spec[2])):
			push_error("诊断参数超出范围：" + String(spec[0]))
			return {}
	var resolved_diagnostics := DiagnosticDefaults.DEFAULTS.duplicate()
	resolved_diagnostics.merge(diagnostic, true)
	var scenario_id := String(options.get("scenario_id", profile.get("scenario_id", document.get("active_scenario", "titan_sanctum"))))
	var scenario_overrides: Variant = options.get("scenario_overrides", document.get("default_scenario_overrides", {}) if scenario_id == String(document.get("active_scenario", "")) else {})
	if not scenario_overrides is Dictionary:
		push_error("遭遇覆盖参数必须为字典")
		return {}
	var scenario := Scenarios.resolve(scenario_id, scenario_overrides)
	if scenario.is_empty():
		return {}
	var group_id := String(options.get("group_id", document.get("active_group", Groups.document().get("active", "mixed_patrol"))))
	var selection: Variant = options.get("group_selection", {})
	if not selection is Dictionary:
		push_error("编组必须为字典")
		return {}
	if scenario.kind == "roster_encounter" and options.has("group_selection") and selection.is_empty():
		push_error("显式空编组不能回退到默认编组")
		return {}
	var group := Groups.resolve(group_id, selection)
	if group.is_empty():
		return {}
	if scenario.kind == "roster_encounter":
		scenario.selection = group.selection.duplicate()
		if int(group.count) * int(scenario.count_multiplier) > int(Groups.document().max_enemies):
			push_error("编组与倍率超过总数保护上限")
			return {}
	return {"profile_id": id, "profile": profile, "seed": int(options.get("seed", document.default_seed)),
		"participant": options.get("participant", {"id": "anonymous", "style_label": "未标注"}),
		"capture_origin": String(options.get("capture_origin", "human")), "model_path": String(options.get("model_path", "")),
		"replay_preflight": options.get("replay_preflight", {}),
		"observation_seconds": clampf(float(options.get("observation_seconds", document.observation_seconds)), 1.0, 1800.0),
		"mode": String(options.get("mode", "auto")), "autostart": bool(options.get("autostart", false)),
		"replay_path": String(options.get("replay_path", "")), "reference_report": String(options.get("reference_report", "")),
		"diagnostics": resolved_diagnostics, "scenario_id": scenario_id, "scenario_overrides": scenario_overrides, "scenario": scenario,
		"group_id": group_id, "group_selection": group.selection, "group": group, "pacing": String(options.get("pacing", "realtime"))}
