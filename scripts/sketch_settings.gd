extends RefCounted
## 正式效果、运行面板、复现对照共用；开关由DisplaySettings的画面风格管理。
const PATH := "res://data/graphics/sketch_default.json"
const LEGACY_PATH := "res://data/graphics/sketch_legacy.json"
const FIELDS := {
	"filter_blend": ["手绘混合", "比例", 0.0, 1.0, 0.01],
	"monochrome_mode": ["黑白素描", "0关1开", 0.0, 1.0, 1.0],
	"color_saturation": ["彩铅饱和度", "倍率", 0.0, 2.5, 0.01],
	"color_contrast": ["彩铅对比度", "倍率", 0.5, 2.0, 0.01],
	"paper_tint": ["纸底混入", "比例", 0.0, 0.5, 0.01],
	"protect_vfx_particles": ["亮部特效保护", "0关1开", 0.0, 1.0, 1.0],
	"vfx_threshold": ["亮部识别阈值", "亮度", 0.6, 2.0, 0.01],
	"vfx_glow_intensity": ["亮部保护增益", "倍率", 0.5, 3.0, 0.01],
	"keep_vfx_color": ["亮部保留原色", "0关1开", 0.0, 1.0, 1.0],
	"preserve_red_signals": ["红色信号保色", "0关1开", 0.0, 1.0, 1.0],
	"paper_texture_strength": ["纸张纤维", "强度", 0.0, 0.4, 0.01],
	"paper_mottling": ["纸张斑驳", "强度", 0.0, 0.4, 0.01],
	"paper_vignette": ["纸面暗角", "强度", 0.0, 1.0, 0.01],
	"line_thickness": ["线条宽度", "px", 0.5, 4.0, 0.01],
	"edge_strength": ["轮廓强度", "倍率", 0.0, 10.0, 0.01],
	"edge_threshold": ["轮廓识别阈值", "比例", 0.02, 0.5, 0.01],
	"line_wobble": ["线条弯曲", "px", 0.0, 5.0, 0.01],
	"stroke_roughness": ["笔触飞白", "比例", 0.0, 1.0, 0.01],
	"double_stroke": ["复线（>0.01多8次采样）", "强度", 0.0, 1.0, 0.01],
	"enable_hatching": ["暗部排线", "0关1开", 0.0, 1.0, 1.0],
	"shadow_threshold": ["排线起始明度", "比例", 0.1, 0.6, 0.01],
	"hatch_density": ["排线密度", "倍率", 1.0, 10.0, 0.01],
	"color_bands": ["明度色阶（0连续）", "级", 0.0, 8.0, 1.0]
}
const BOOLS := ["monochrome_mode", "protect_vfx_particles", "keep_vfx_color", "preserve_red_signals", "enable_hatching"]
const COLORS := {"paper_color": "纸张颜色", "pencil_color": "铅笔颜色"}

static func load_values(path: String = PATH) -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not raw is Dictionary:
		push_error("手绘参数无法读取：" + path)
		return {}
	return validate(raw)

static func validate(raw: Dictionary) -> Dictionary:
	var values: Dictionary = {}
	for key in FIELDS:
		if not raw.has(key) or not (raw[key] is float or raw[key] is int) or not is_finite(float(raw[key])):
			push_error("手绘参数无效：" + key)
			return {}
		var spec: Array = FIELDS[key]
		values[key] = clampf(float(raw[key]), float(spec[2]), float(spec[3]))
		if key in BOOLS or key == "color_bands":
			values[key] = roundf(values[key])
	for key in COLORS:
		if not raw.get(key) is Array or raw[key].size() != 4:
			push_error("手绘颜色无效：" + key)
			return {}
		var channels: Array = []
		for channel in raw[key]:
			if not (channel is float or channel is int) or not is_finite(float(channel)):
				push_error("手绘颜色通道无效：" + key)
				return {}
			channels.append(clampf(float(channel), 0.0, 1.0))
		values[key] = channels
	return values

static func recipe(name: String) -> Dictionary:
	var values := load_values(LEGACY_PATH)
	if name != "legacy":
		values.double_stroke = 0.0
	if name == "mono":
		values.monochrome_mode = 1.0
		values.filter_blend = 1.0
		values.paper_texture_strength = 0.16
		values.enable_hatching = 1.0
	return values

static func save_values(values: Dictionary) -> Error:
	var valid := validate(values)
	return ERR_INVALID_DATA if valid.is_empty() else preload("res://scripts/json_config_store.gd").save_json(PATH, valid, "sketch")
