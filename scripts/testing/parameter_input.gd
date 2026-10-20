extends RefCounted
## 两面板共用精确数字提交；步长只供箭头，不回写未编辑的舍入显示值。
static func compact_theme(base: Theme, font_size := 12) -> Theme:
	var result: Theme = base.duplicate()
	for type in ["Label", "Button", "OptionButton", "LineEdit", "CheckBox", "CheckButton", "TabBar", "PopupMenu"]:
		result.set_font_size("font_size", type, font_size)
	return result

static func update_number(control: SpinBox, value: float) -> void:
	control.set_value_no_signal(value)
	control.get_line_edit().text = String.num(value, 12)

static func configure_step(control: SpinBox, arrow_step: float) -> void:
	# Range.step 同时决定原生文本刷新精度；箭头步长用独立属性，避免画面把草稿舍入。
	control.step = 0.000000000001
	control.custom_arrow_step = arrow_step

static func read_number(control: SpinBox, entered: Variant = null) -> Dictionary:
	var text := (control.get_line_edit().text if entered == null else String(entered)).strip_edges().trim_prefix(control.prefix).trim_suffix(control.suffix).strip_edges()
	if not text.is_valid_float(): return {"ok": false, "error": "请输入完整数值"}
	var value := text.to_float()
	if not is_finite(value) or value < control.min_value or value > control.max_value:
		return {"ok": false, "error": "数值需在 %s–%s 之间" % [control.min_value, control.max_value]}
	return {"ok": true, "value": value}

static func exact_change(control: SpinBox, value: float, pending: Variant) -> float:
	var parsed := read_number(control, pending)
	# focus/Enter 原生提交会按 step 舍入；箭头真正改变了一步则沿用新值。
	return float(parsed.value) if parsed.ok and is_equal_approx(value, snappedf(float(parsed.value), control.step)) else value

static func tooltip(profile: String, field: Dictionary) -> String:
	var meta := preload("res://scripts/testing/tuning_catalog.gd").field(profile, String(field.key))
	return "%s\n统一语义：%s／%s\n单位：%s；范围：%s–%s\n体型：%s；框内保存体型1的基础值，实例生成时换算。\n生效：%s\n原字段：%s" % [field.get("tip", ""), field.get("section", meta.get("module", "")), field.get("semantic", field.key), field.get("unit", meta.get("unit", "")), field.get("min", "关"), field.get("max", "开"), field.get("scale_rule", "独立控制"), meta.get("apply", "重新生成"), field.key]

static func unit(profile: String, field: Dictionary) -> String:
	return String(field.get("unit", preload("res://scripts/testing/tuning_catalog.gd").field(profile, String(field.key)).get("unit", "")))
