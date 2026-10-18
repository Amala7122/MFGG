extends RefCounted
const PATH := "res://data/player_visuals/support.json"
const FIELDS := {
	"wisp_scale": ["卫士模型倍率", "倍", 0.5, 3.0, 0.05],
	"wisp_offset_x": ["普通跟随 左右", "m", -3.0, 3.0, 0.01],
	"wisp_offset_y": ["普通跟随 高度", "m", 0.5, 3.5, 0.01],
	"wisp_offset_z": ["普通跟随 前后", "m", -2.0, 2.0, 0.01],
	"wisp_ads_x": ["瞄准跟随 左右", "m", -3.0, 3.0, 0.01],
	"wisp_ads_y": ["瞄准跟随 高度", "m", 0.5, 3.5, 0.01],
	"wisp_ads_z": ["瞄准跟随 前后", "m", -2.0, 2.0, 0.01],
	"wisp_light_energy": ["卫士灯光能量", "强度", 0.0, 5.0, 0.1],
	"wisp_light_range": ["卫士灯光范围", "m", 0.5, 10.0, 0.1],
	"wisp_overclock_light": ["超频灯光能量", "强度", 0.0, 8.0, 0.1],
	"wisp_lens_energy": ["普通透镜发光", "强度", 0.0, 12.0, 0.1],
	"wisp_locked_lens": ["锁敌透镜发光", "强度", 0.0, 15.0, 0.1],
	"wisp_overclock_lens": ["超频透镜发光", "强度", 0.0, 15.0, 0.1],
	"wisp_glow": ["普通能量装饰", "强度", 0.0, 4.0, 0.1],
	"wisp_overclock_glow": ["超频能量装饰", "强度", 0.0, 5.0, 0.1],
	"wisp_halo_speed": ["光环旋转速度", "rad/s", 0.0, 5.0, 0.1],
	"shield_enabled": ["护盾表现开关", "0关1开", 0.0, 1.0, 1.0],
	"shield_radius": ["护盾半径", "m", 0.7, 2.0, 0.01],
	"shield_center_y": ["护盾中心高度偏移", "m", -0.3, 0.8, 0.01],
	"shield_duration": ["受击显示时长", "s", 0.1, 2.0, 0.01],
	"shield_alpha": ["护盾总体显现", "比例", 0.0, 1.0, 0.01],
	"shield_base_alpha": ["球壳基础透明度", "比例", 0.0, 0.5, 0.01],
	"shield_hex_scale": ["蜂巢密度", "格/m", 1.0, 10.0, 0.1],
	"shield_line_thickness": ["蜂巢线宽", "比例", 0.01, 0.2, 0.001],
	"shield_fresnel": ["边缘光集中度", "指数", 1.0, 6.0, 0.1],
	"shield_glow": ["受击发光", "倍率", 0.0, 3.0, 0.1],
	"shield_ripple_speed": ["涟漪扩散速度", "rad/s", 0.0, 10.0, 0.1]
}

static func load_values() -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not raw is Dictionary:
		push_error("卫士 / 护盾表现配置无法读取：" + PATH)
		return {}
	return validate(raw)

static func validate(raw: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in FIELDS:
		if not raw.has(key) or not (raw[key] is float or raw[key] is int) or not is_finite(float(raw[key])):
			push_error("卫士 / 护盾参数无效：" + key)
			return {}
		var spec: Array = FIELDS[key]
		result[key] = clampf(float(raw[key]), float(spec[2]), float(spec[3]))
	result.shield_enabled = roundf(result.shield_enabled)
	return result

static func save_values(raw: Dictionary) -> Error:
	var values := validate(raw)
	return ERR_INVALID_DATA if values.is_empty() else preload("res://scripts/json_config_store.gd").save_json(PATH, values, "player_support")
