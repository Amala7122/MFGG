extends RefCounted
## 编组与策略独立保存；只引用正式图鉴，不把未投产外形当成有战斗能力的兵种。
const PATH := "res://data/testing/sparring_groups.json"
const Config := preload("res://scripts/game_config.gd")

static func document() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not parsed is Dictionary or not parsed.get("groups") is Dictionary or not parsed.groups.has(String(parsed.get("active", ""))):
		push_error("实战陪练编组文件格式错误")
		return {}
	return parsed

static func roster() -> Dictionary:
	var result := {}
	for entry: Dictionary in Config.get_dictionary("enemy_roster").get("entries", []):
		result[String(entry.id)] = entry
	return result

static func validate(selection: Dictionary, maximum := 128) -> String:
	var entries := roster()
	var total := 0
	for id: String in selection:
		var count: Variant = selection[id]
		if not entries.has(id):
			return "尚未投入正式图鉴的敌人：" + id
		if not (count is int or count is float) or not is_finite(float(count)) or float(count) != floorf(float(count)) or float(count) < 0:
			return "敌人数必须为非负整数：" + id
		total += int(count)
	if total < 1 or total > maximum:
		return "编组总数须为 1–%d；此上限是运行保护，不代表已验证这些规模的性能" % maximum
	return ""

static func resolve(id: String, override_selection: Dictionary = {}) -> Dictionary:
	var doc := document()
	if not doc.get("groups", {}).has(id):
		push_error("未知敌人编组：" + id)
		return {}
	var selection: Dictionary = override_selection if not override_selection.is_empty() else doc.groups[id].selection
	var problem := validate(selection, int(doc.max_enemies))
	if not problem.is_empty():
		push_error(problem)
		return {}
	var normalized := {}
	var count := 0
	for key: String in selection:
		if int(selection[key]) > 0:
			normalized[key] = int(selection[key])
			count += int(selection[key])
	return {"id": id, "title": String(doc.groups[id].get("title", id)), "selection": normalized, "count": count}

static func save_named(id: String, selection: Dictionary, make_default := false) -> Error:
	var doc := document()
	if id.is_empty() or id != id.validate_filename() or not validate(selection, int(doc.max_enemies)).is_empty():
		return ERR_INVALID_DATA
	doc.groups[id] = {"title": id, "selection": selection.duplicate()}
	if make_default:
		doc.active = id
	var file := FileAccess.open(PATH + ".tmp", FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(doc, "  ") + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	return DirAccess.rename_absolute(PATH + ".tmp", PATH) if error == OK else error
