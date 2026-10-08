extends RefCounted
## 新敌人的唯一数值来源是各自 JSON；方案文件只保存玩家调整值。

const PROFILE_PATHS := {
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


static func validate(id: String, values: Dictionary) -> String:
	var schema := get_schema(id)
	if schema.is_empty():
		return "找不到敌人参数配置"
	for group: Dictionary in schema.groups:
		for field: Dictionary in group.fields:
			var value: Variant = values.get(String(field.key))
			if field.value is bool:
				if not value is bool:
					return String(field.label) + "必须为开关"
			elif not (value is float or value is int):
				return String(field.label) + "必须为数值"
			elif not is_finite(float(value)) or float(value) < float(field.min) or float(value) > float(field.max):
				return "%s需在 %s–%s 之间" % [field.label, field.min, field.max]
	for pair in [["scatter_up_min", "scatter_up_max"], ["mud_shield_first_min", "mud_shield_first_max"], ["mud_shield_interval_min", "mud_shield_interval_max"], ["orbit_wait_min", "orbit_wait_max"]]:
		if values.has(pair[0]) and float(values[pair[0]]) > float(values[pair[1]]):
			return "随机区间的下限不能大于上限"
	if values.has("sweep_preferred_distance") and float(values.sweep_preferred_distance) > float(values.sweep_distance):
		return "横扫优先施放距离不能大于攻击半径"
	if values.has("circle_inner_distance") and float(values.circle_inner_distance) > float(values.circle_outer_distance):
		return "绕行内圈不能大于外圈"
	if values.has("pounce_min_distance") and float(values.pounce_min_distance) > float(values.pounce_max_distance):
		return "飞扑施放距离下限不能大于上限"
	if values.has("leap_min_distance"):
		if float(values.leap_min_distance) > float(values.leap_far_distance) or float(values.leap_far_distance) > float(values.leap_max_distance):
			return "跃击距离需满足：最小距离 ≤ 远距触发 ≤ 最大距离"
		if float(values.leap_min_flight) > float(values.leap_max_flight):
			return "跃击飞行时间下限不能大于上限"
		if float(values.near_enter_distance) > float(values.near_exit_distance):
			return "近身进入距离不能大于离开距离"
	return ""


static func save_preset(id: String, name: String, values: Dictionary) -> bool:
	last_error = validate(id, values)
	name = name.strip_edges()
	if name.is_empty() or name == DEFAULT_PRESET or name.length() > 64:
		last_error = "请填写 1–64 字的方案名称，项目默认不可覆盖"
	if not last_error.is_empty():
		return false
	var document := _document(id).duplicate(true)
	document.presets[name] = values.duplicate(true)
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
		last_error = "无法创建方案目录（错误 %d）" % directory_error
		return false
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		last_error = "无法保存方案（错误 %d）" % FileAccess.get_open_error()
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
