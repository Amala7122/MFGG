extends RefCounted
const PATH := "res://data/testing/sparring_scenarios.json"
const Config := preload("res://scripts/game_config.gd")

static func document() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not parsed is Dictionary or not parsed.get("scenarios") is Dictionary:
		push_error("实战陪练场景配置格式错误")
		return {}
	return parsed

static func resolve(id: String, overrides: Dictionary = {}) -> Dictionary:
	var doc := document()
	if not doc.get("scenarios", {}).has(id):
		push_error("未知实战陪练场景：" + id)
		return {}
	var value: Dictionary = doc.scenarios[id].duplicate(true)
	for key: String in overrides:
		if key not in ["loadout", "enemy_level", "count_multiplier", "boss_phase"]:
			push_error("未知遭遇覆盖参数：" + key)
			return {}
	value.merge(overrides, true)
	var phase := String(value.get("boss_phase", "full"))
	if phase not in ["full", "front", "rage"] or (value.get("kind") != "boss_direct" and phase != "full"):
		push_error("Boss阶段无效；阶段直入仅用于Boss直战")
		return {}
	value["boss_phase"] = phase
	if value.get("kind") not in ["boss_direct", "roster_encounter"] or value.get("arena_id") != "sanctum" or value.get("loadout") not in ["initial", "mid", "max"]:
		push_error("场景类型、地图或配装尚未接入")
		return {}
	if not (value.get("enemy_level") is float or value.get("enemy_level") is int) or not is_finite(float(value.enemy_level)) or float(value.enemy_level) < 1 or float(value.enemy_level) > 30:
		push_error("敌人等级必须为 1–30")
		return {}
	if not (value.get("count_multiplier") is float or value.get("count_multiplier") is int) or float(value.count_multiplier) != floorf(float(value.count_multiplier)) or int(value.count_multiplier) < 1 or int(value.count_multiplier) > 4:
		push_error("数量倍率必须为 1–4 的整数")
		return {}
	if value.kind == "roster_encounter":
		var roster := {}
		for entry: Dictionary in Config.get_dictionary("enemy_roster").get("entries", []):
			roster[String(entry.id)] = entry
		var total := 0
		for enemy_id: String in value.get("selection", {}):
			var count: Variant = value.selection[enemy_id]
			if not roster.has(enemy_id) or not (count is int or count is float) or float(count) != floorf(float(count)) or float(count) < 0:
				push_error("遭遇编组条目不合法：" + enemy_id)
				return {}
			total += int(count) * int(value.count_multiplier)
		if total < 1 or total > 128:
			push_error("遭遇总数必须为 1–128；实际编组另行校验")
			return {}
	value["id"] = id
	return value
