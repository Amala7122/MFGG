extends RefCounted
## 新敌人的唯一数值来源是各自 JSON；方案文件只保存玩家调整值。
const Limits := preload("res://scripts/testing/enemy_parameter_limits.gd")

const PROFILE_PATHS := {
	"VisualBurstCrawler": "res://data/enemies/visual_burst_crawler.json",
	"VisualPrismSpider": "res://data/enemies/visual_prism_spider.json",
	"VisualChargeBeetle": "res://data/enemies/visual_charge_beetle.json",
	"PrototypeMudGolem": "res://data/enemies/procedural_mud_golem.json",
	"PrototypeSedimentTitan": "res://data/enemies/procedural_sediment_titan.json",
	"PrototypeFastBeast": "res://data/enemies/procedural_fast_beast.json",
	"PrototypeHornet": "res://data/enemies/procedural_hornet.json",
}
const DEFAULT_PRESET := "项目默认"
static var storage_directory := "res://data/enemy_presets"
static var _schemas: Dictionary = {}
static var _saved: Dictionary = {}
static var last_error := ""


static func get_schema(id: String) -> Dictionary:
	if not _schemas.has(id):
		if not PROFILE_PATHS.has(id):
			return {}
		var schema := _read_json(PROFILE_PATHS[id])
		if schema.get("id", "") != id or not _valid_schema(schema):
			_schemas[id] = {}
			last_error = "敌人参数配置损坏：" + String(PROFILE_PATHS[id])
			push_error(last_error)
			return {}
		Limits.apply(id, schema)
		_schemas[id] = schema
	return _schemas[id]


static func defaults(id: String) -> Dictionary:
	var result := {}
	for group: Dictionary in get_schema(id).get("groups", []):
		for field: Dictionary in group.fields:
			result[String(field.key)] = field.value
	return result


static func _document(id: String) -> Dictionary:
	if not _saved.has(id):
		var path := _save_path(id)
		# 导出版本首次运行也继承项目中已经选用的方案，再由用户目录保存后续修改。
		if not FileAccess.file_exists(path):
			path = storage_directory.path_join(id + ".json")
		var saved := _read_json(path) if FileAccess.file_exists(path) else {}
		if saved.get("version", 0) != 1 or not saved.get("presets") is Dictionary:
			saved = {"version": 1, "active": DEFAULT_PRESET, "presets": {}}
		_saved[id] = saved
	return _saved[id]


static func preset_names(id: String) -> Array[String]:
	var names: Array[String] = [DEFAULT_PRESET]
	for name: String in _document(id).presets:
		names.append(name)
	return names


static func active_name(id: String) -> String:
	var name := String(_document(id).get("active", DEFAULT_PRESET))
	return name if preset_names(id).has(name) else DEFAULT_PRESET


static func preset_values(id: String, name: String) -> Dictionary:
	var values := defaults(id)
	if name != DEFAULT_PRESET:
		var override: Variant = _document(id).presets.get(name, {})
		if override is Dictionary:
			# 配置新增字段时，旧方案继承新字段默认值；未知旧字段不传播。
			for key: String in values:
				if override.has(key):
					values[key] = override[key]
	if not validate(id, values).is_empty():
		last_error = "保存的方案不合法，已使用项目默认：" + name
		push_warning(last_error)
		return defaults(id)
	return values


static func get_values(id: String) -> Dictionary:
	return preset_values(id, active_name(id))


static func resolve(enemy: Node, id: String) -> Dictionary:
	var values: Dictionary = enemy.get_meta(&"enemy_tuning", get_values(id)).duplicate(true)
	var error := validate(id, values)
	if not error.is_empty():
		push_error("敌人参数不可用：" + error)
		return {}
	return values


static func field_issue(spec: Dictionary, value: Variant) -> Dictionary:
	var key := String(spec.key)
	var error := ""
	var code := "type"
	if spec.value is bool:
		if not value is bool: error = "需要开关值"
	elif not (value is float or value is int): error = "需要完整数值"
	elif not is_finite(float(value)): error = "不能使用NaN或无穷大"
	elif float(value) < float(spec.min) or float(value) > float(spec.max):
		code = "range"
		error = "输入%s，允许范围%s–%s" % [value, spec.min, spec.max]
	elif spec.get("integer", false) and float(value) != roundf(float(value)):
		code = "integer"
		error = "输入%s；计数必须为整数" % value
	return {} if error.is_empty() else {"keys": [key], "code": code, "message": error}


static func validation_issues(id: String, values: Dictionary) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var schema := get_schema(id)
	if schema.is_empty(): return [{"keys": [], "code": "schema", "message": "找不到敌人参数配置"}]
	for group: Dictionary in schema.groups:
		for spec: Dictionary in group.fields:
			var issue := field_issue(spec, values.get(String(spec.key)))
			if not issue.is_empty(): issues.append(issue)
	if not issues.is_empty(): return issues
	var pairs := [
		["scatter_up_min", "scatter_up_max", false], ["mud_shield_first_min", "mud_shield_first_max", false],
		["mud_shield_interval_min", "mud_shield_interval_max", false], ["orbit_wait_min", "orbit_wait_max", false],
		["sweep_preferred_distance", "sweep_distance", false], ["grenade_reserve_start", "grenade_reserve_capacity", false],
		["circle_inner_distance", "circle_outer_distance", false], ["pounce_min_distance", "pounce_max_distance", false],
		["leap_min_distance", "leap_far_distance", false], ["leap_far_distance", "leap_max_distance", false],
		["leap_min_flight", "leap_max_flight", false], ["near_enter_distance", "near_exit_distance", false],
		["retreat_range", "retreat_exit_range", true], ["retreat_exit_range", "attack_range", true],
	]
	for pair: Array in pairs:
		if not values.has(pair[0]) or not values.has(pair[1]): continue
		if float(values[pair[0]]) > float(values[pair[1]]) or (pair[2] and float(values[pair[0]]) == float(values[pair[1]])):
			issues.append({"keys": [String(pair[0]), String(pair[1])], "code": "relation",
				"message": "需满足前者%s后者；当前%s与%s" % ["小于" if pair[2] else "不大于", values[pair[0]], values[pair[1]]]})
	return issues


static func validate(id: String, values: Dictionary) -> String:
	var issues := validation_issues(id, values)
	return "" if issues.is_empty() else "; ".join(issues[0].keys) + "：" + String(issues[0].message)


static func save_preset(id: String, name: String, values: Dictionary, make_active := true) -> bool:
	last_error = validate(id, values)
	name = name.strip_edges()
	if name.is_empty() or name == DEFAULT_PRESET or name.length() > 64:
		last_error = "请填写 1–64 字的方案名称，项目默认不可覆盖"
	if not last_error.is_empty():
		return false
	var document := _document(id).duplicate(true)
	document.presets[name] = values.duplicate(true)
	if make_active:
		document.active = name
	if not _write_document(id, document):
		return false
	_saved[id] = document
	return true


static func _save_path(id: String) -> String:
	# 导出游戏的资源包只读，方案保存在其用户目录；项目运行可随项目复用。
	var directory := "user://enemy_presets" if OS.has_feature("standalone") else storage_directory
	return directory.path_join(id + ".json")


static func _write_document(id: String, document: Dictionary) -> bool:
	var path := _save_path(id)
	var directory_error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if directory_error != OK:
		last_error = "无法创建方案目录：%s（错误 %d）；请检查目标是否可写／被同名文件占用" % [path.get_base_dir(), directory_error]
		return false
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		last_error = "无法保存方案：%s（错误 %d）；请检查目录权限和文件占用" % [path, FileAccess.get_open_error()]
		return false
	file.store_string(JSON.stringify(document, "\t") + "\n")
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		last_error = "方案写入失败（错误 %d），原方案保留" % write_error
		return false
	var rename_error := DirAccess.rename_absolute(temporary, path)
	if rename_error != OK:
		last_error = "方案保存失败（错误 %d），原方案保留" % rename_error
		return false
	return true


static func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


static func _valid_schema(schema: Dictionary) -> bool:
	if not schema.get("groups") is Array or schema.groups.is_empty():
		return false
	var keys := {}
	for group: Variant in schema.groups:
		if not group is Dictionary or not group.get("title") is String or not group.get("fields") is Array:
			return false
		for field: Variant in group.fields:
			if not field is Dictionary or not field.get("key") is String or not field.get("label") is String:
				return false
			if keys.has(field.key):
				return false
			keys[field.key] = true
			if field.get("value") is bool:
				continue
			for key in ["value", "min", "max", "step"]:
				if not (field.get(key) is float or field.get(key) is int) or not is_finite(float(field[key])):
					return false
			if float(field.step) <= 0.0 or float(field.value) < float(field.min) or float(field.value) > float(field.max):
				return false
	return not keys.is_empty()


static func reload_saved() -> void:
	_saved.clear()


static func fingerprint(id: String, values: Dictionary) -> String:
	# JSON 数字往返可能由 int 变 float；签名按 schema 归一，忽略字典插入顺序。
	var canonical := {}
	for key: String in defaults(id):
		var value: Variant = values.get(key)
		canonical[key] = value if value is bool else float(value) if value is int or value is float else value
	return JSON.stringify({"profile": id, "values": canonical}, "", true).sha256_text()


static func schema_fingerprint(id: String) -> String:
	return (FileAccess.get_sha256(PROFILE_PATHS[id]) + FileAccess.get_sha256("res://scripts/testing/enemy_parameter_limits.gd")).sha256_text() if PROFILE_PATHS.has(id) else ""


static func saved_fingerprint(id: String, name: String, fresh := false) -> String:
	if fresh:
		_saved.erase(id)
	return fingerprint(id, preset_values(id, name)) if preset_names(id).has(name) else ""


static func save_candidate(id: String, name: String, values: Dictionary,
		overwrite := false, expected_fingerprint := "") -> bool:
	# 面板的新保存入口：刷新磁盘、检查同名冲突，永不顺带改变 active。
	_saved.erase(id)
	var exists := preset_names(id).has(name.strip_edges())
	if exists and not overwrite:
		last_error = "同名方案已存在：请另存新名称，或明确确认覆盖。"
		return false
	if exists and (expected_fingerprint.is_empty() or saved_fingerprint(id, name) != expected_fingerprint):
		last_error = "方案已被其他入口修改，未覆盖；草稿已保留，请重新载入或另存。"
		return false
	return save_preset(id, name, values, false)


static func set_active_preset(id: String, name: String) -> bool:
	if not preset_names(id).has(name):
		last_error = "找不到方案：" + name
		return false
	var document := _document(id).duplicate(true)
	document.active = name
	if not _write_document(id, document):
		return false
	_saved[id] = document
	return true
