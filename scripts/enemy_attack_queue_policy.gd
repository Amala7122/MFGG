extends RefCounted
## 战斗编排配置；不是敌人的伤害／动画参数。运行应用与保存默认值分开。
const PATH := "res://data/combat/attack_queue.json"
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
const REGISTRY := {
	"PrototypeMudGolem": {"punch": {"slot": 0, "ground": false}},
	"PrototypeFastBeast": {"pounce": {"slot": 0, "ground": true}, "normal_attack": {"slot": 1, "ground": false}},
	"PrototypeHornet": {"needle": {"slot": 0, "ground": false}, "dive": {"slot": 1, "ground": false}},
	"VisualBurstCrawler": {"lob": {"slot": 0, "ground": true, "reserves": "poison"}, "poison": {"slot": 1, "ground": true, "residual": true}},
	"VisualPrismSpider": {"snipe": {"slot": 0, "ground": false}},
	"VisualChargeBeetle": {"charge": {"slot": 0, "ground": true}, "contact": {"slot": 1, "ground": true}},
	"PrototypeSedimentTitan": {"slam": {"slot": 0, "ground": true}, "sweep": {"slot": 1, "ground": true},
		"thrust": {"slot": 2, "ground": true}, "leap": {"slot": 3, "ground": true, "reserves": "thrust"},
		"triple_slam": {"slot": 4, "ground": true}, "normal_attack": {"slot": 5, "ground": false}},
}
const GLOBAL_FIELDS := {
	"max_active": ["总危险技能组上限", "组", 1, 64],
	"max_ground": ["地面危险技能组上限", "组", 1, 64],
	"starts_per_frame": ["每渲染帧起手上限", "组/帧", 1, 8],
	"start_gap": ["同一玩家的起手最小间隔", "秒", 0, 10],
	"waiting_speed_scale": ["等待绕行速度倍率（0守势）", "倍", 0, 4],
}
static var _current: Dictionary = {}
static var _saved: Dictionary = {}
static var revision := 0
static var last_error := ""

static func defaults() -> Dictionary:
	var profiles: Dictionary = {}
	for profile: String in REGISTRY:
		var skills: Dictionary = {}
		for skill: String in REGISTRY[profile]: skills[skill] = 1
		profiles[profile] = {"max_active": 2, "skills": skills}
	return {"version": 1, "enabled": true, "global": {"max_active": 3, "max_ground": 2, "starts_per_frame": 1, "start_gap": 0.35, "waiting_speed_scale": 0.0}, "profiles": profiles}

static func current() -> Dictionary:
	if _current.is_empty():
		var path := storage_path()
		# 导出首启尚无本机覆盖时，仍读取随包发布的项目默认值。
		if path != PATH and not FileAccess.file_exists(path): path = PATH
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		var problems := validate(parsed)
		if not problems.is_empty():
			push_error("起手队列配置无效：" + path + "；" + "；".join(problems))
			_current = defaults()
		else: _current = parsed.duplicate(true)
		_saved = _current.duplicate(true)
	return _current

static func saved() -> Dictionary:
	current()
	return _saved.duplicate(true)

static func storage_path() -> String:
	return "user://attack_queue.json" if OS.has_feature("template") else PATH

static func skill_name(profile: String, skill: String) -> String:
	return String(Layout.SKILLS[profile][int(REGISTRY[profile][skill].slot)][0])

static func validate(document: Variant) -> Array[String]:
	var problems: Array[String] = []
	if not document is Dictionary:
		problems.append("根节点必须是配置对象")
		return problems
	if document.get("version") != 1: problems.append("version必须为1")
	if not document.get("enabled") is bool: problems.append("enabled必须为开关")
	var global: Variant = document.get("global")
	if not global is Dictionary:
		problems.append("缺少global配置")
	else:
		for key: String in GLOBAL_FIELDS:
			var spec: Array = GLOBAL_FIELDS[key]
			_check_number(global.get(key), "全局/" + String(spec[0]), float(spec[2]), float(spec[3]), key in ["max_active", "max_ground", "starts_per_frame"], problems)
		for key: String in global:
			if not GLOBAL_FIELDS.has(key): problems.append("未知全局字段：" + key)
	var profiles: Variant = document.get("profiles")
	if not profiles is Dictionary:
		problems.append("缺少profiles配置")
		return problems
	for profile: String in REGISTRY:
		var entry: Variant = profiles.get(profile)
		if not entry is Dictionary:
			problems.append("缺少兵种：" + profile)
			continue
		_check_number(entry.get("max_active"), profile + "/兵种上限", 0, 64, true, problems)
		var skills: Variant = entry.get("skills")
		if not skills is Dictionary:
			problems.append(profile + "缺少skills")
			continue
		for skill: String in REGISTRY[profile]:
			_check_number(skills.get(skill), profile + "/" + skill_name(profile, skill), 0, 64, true, problems)
		for skill: String in skills:
			if not REGISTRY[profile].has(skill): problems.append("未知技能：" + profile + "/" + skill)
	for profile: String in profiles:
		if not REGISTRY.has(profile): problems.append("未知兵种：" + profile)
	return problems

static func _check_number(value: Variant, field: String, lower: float, upper: float, integer: bool, problems: Array[String]) -> void:
	if not (value is float or value is int):
		problems.append(field + "：请输入数值")
	elif not is_finite(float(value)) or float(value) < lower or float(value) > upper or (integer and float(value) != floorf(float(value))):
		problems.append("%s：需为%s，范围%s–%s；输入%s" % [field, "整数" if integer else "有限数值", lower, upper, str(value)])

static func apply(document: Dictionary) -> bool:
	var problems := validate(document)
	last_error = "；".join(problems)
	if not problems.is_empty(): return false
	if _saved.is_empty(): current()
	_current = document.duplicate(true)
	revision += 1
	return true

static func save(document: Dictionary) -> bool:
	var problems := validate(document)
	last_error = "；".join(problems)
	if not problems.is_empty(): return false
	var path := storage_path()
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		last_error = "无法写入默认配置，原文件保留：" + path
		return false
	file.store_string(JSON.stringify(document, "\t") + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		last_error = "写入失败，原默认值保留：" + error_string(error)
		return false
	error = DirAccess.rename_absolute(temporary, path)
	if error != OK:
		last_error = "替换默认配置失败，原默认值保留：" + error_string(error)
		return false
	_saved = document.duplicate(true)
	return apply(document)
