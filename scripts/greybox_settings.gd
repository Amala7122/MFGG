extends RefCounted
const PATH := "res://data/graphics/greybox.json"
const FIELDS := {
	"grid_size": ["细格间距", "m", 0.25, 4.0, 0.01],
	"major_grid_step": ["每粗格含细格", "格", 2.0, 10.0, 1.0],
	"line_width": ["细线宽度", "m", 0.005, 0.1, 0.001],
	"major_line_width": ["粗线宽度", "m", 0.01, 0.2, 0.001],
	"checker_strength": ["棋盘明暗", "比例", 0.0, 1.0, 0.01],
	"light_energy": ["中性主光", "强度", 0.0, 3.0, 0.01],
	"ambient_energy": ["中性环境光", "强度", 0.1, 2.0, 0.01],
	"ssao_enabled": ["接触阴影", "0关1开", 0.0, 1.0, 1.0],
	"show_dust": ["中性灰扬尘", "0关1开", 0.0, 1.0, 1.0]
}
const COLORS := {"ground_color":"地面", "obstacle_color":"实体障碍", "enemy_color":"敌人", "studio_background":"背景"}

static func load_values() -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not raw is Dictionary:
		push_error("灰模参数无法读取："+PATH)
		return {}
	return validate(raw)

static func validate(raw: Dictionary) -> Dictionary:
	var values: Dictionary = {}
	for key in FIELDS:
		if not raw.has(key) or not (raw[key] is float or raw[key] is int) or not is_finite(float(raw[key])):
			push_error("灰模参数无效："+key)
			return {}
		values[key] = clampf(float(raw[key]),float(FIELDS[key][2]),float(FIELDS[key][3]))
		if key in ["major_grid_step","ssao_enabled","show_dust"]: values[key] = roundf(values[key])
	for key in COLORS:
		if not raw.get(key) is Array or raw[key].size() != 4:
			push_error("灰模颜色无效："+key)
			return {}
		var channels: Array = []
		for channel in raw[key]:
			if not (channel is float or channel is int) or not is_finite(float(channel)):
				push_error("灰模颜色通道无效："+key)
				return {}
			channels.append(clampf(float(channel),0.0,1.0))
		channels[3] = 1.0
		values[key] = channels
	return values

static func save_values(values: Dictionary) -> Error:
	var valid := validate(values)
	return ERR_INVALID_DATA if valid.is_empty() else preload("res://scripts/json_config_store.gd").save_json(PATH,valid,"greybox")
