extends RefCounted
## 两面板共用精确数字提交；步长只供箭头，不回写未编辑的舍入显示值。
static func compact_theme(base: Theme, font_size := 12) -> Theme:
	var result: Theme = base.duplicate()
	for type in ["Label", "Button", "OptionButton", "LineEdit", "CheckBox", "CheckButton", "TabBar", "PopupMenu"]:
		result.set_font_size("font_size", type, font_size)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		if not result.has_stylebox(state, "Button"): continue
		var style: StyleBox = result.get_stylebox(state, "Button").duplicate()
		style.content_margin_left = 6
		style.content_margin_right = 6
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		result.set_stylebox(state, "Button", style)
	return result

static func update_number(control: SpinBox, value: float) -> void:
	control.set_value_no_signal(value)
	control.get_line_edit().text = String.num(value, 12)

static func configure_step(control: SpinBox, arrow_step: float) -> void:
	# Range.step 同时决定原生文本刷新精度；箭头步长用独立属性，避免画面把草稿舍入。
	control.step = 0.000000000001
	control.custom_arrow_step = arrow_step
	# 原生Range不得先把非法文字变成“合法边界值”；共用提交校验决定是否接纳。
	control.allow_greater = true
	control.allow_lesser = true

static func read_number(control: SpinBox, entered: Variant = null) -> Dictionary:
	var text := (control.get_line_edit().text if entered == null else String(entered)).strip_edges().trim_prefix(control.prefix).trim_suffix(control.suffix).strip_edges()
	if not text.is_valid_float(): return {"ok": false, "error": "请输入完整数值"}
	var value := text.to_float()
	if not is_finite(value): return {"ok": false, "error": "不能使用NaN或无穷大"}
	if value < control.min_value or value > control.max_value:
		return {"ok": false, "error": "数值需在 %s–%s 之间" % [control.min_value, control.max_value]}
	return {"ok": true, "value": value}

static func inspect_pending(profile: String, controls: Dictionary, pending: Dictionary, values: Dictionary) -> Dictionary:
	var tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
	var layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
	var next := values.duplicate(true)
	var issues: Array[Dictionary] = []
	for key: String in pending:
		if not controls.has(key): continue
		var parsed := read_number(controls[key], pending[key])
		if not parsed.ok:
			var meta := preload("res://scripts/testing/tuning_catalog.gd").field(profile, key)
			issues.append({"keys": [key], "code": "text", "raw": String(pending[key]), "message": String(parsed.error) + "；" + String(meta.get("limit_reason", ""))})
		else: next[key] = layout.stored_number(key, float(parsed.value))
	if issues.is_empty(): issues = tuning.validation_issues(profile, next)
	return {"values": next, "issues": issues}

static func describe(profile: String, issues: Array, action := "", can_return := true) -> String:
	if issues.is_empty(): return ""
	var tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
	var catalog := preload("res://scripts/testing/tuning_catalog.gd")
	var issue: Dictionary = issues[0]
	var names: Array[String] = []
	for key: String in issue.keys:
		var spec := catalog.field(profile, key)
		names.append("%s／%s（%s）" % [spec.get("module", ""), spec.get("label", key), key])
	return "%s%s：%s\n%s%s%s。请修正／撤销，或点“撤回输入”%s。" % ["无法" + action + "；" if not action.is_empty() else "", String(tuning.get_schema(profile).get("title", profile)).split(" · ")[0], "、".join(names), "输入“%s”：" % issue.raw if issue.has("raw") else "", issue.message, "；另有%d项问题" % (issues.size()-1) if issues.size()>1 else "", "；返回会保留输入" if can_return else ""]

static func mark_issues(controls: Dictionary, issues: Array) -> void:
	var bad := {}
	for issue: Dictionary in issues:
		for key: String in issue.keys: bad[key] = true
	for key: String in controls:
		if not controls[key] is SpinBox: continue
		var edit: LineEdit = controls[key].get_line_edit()
		if bad.has(key): edit.add_theme_color_override("font_color", Color(1.0, 0.42, 0.32))
		else: edit.remove_theme_color_override("font_color")

static func exact_change(control: SpinBox, value: float, pending: Variant) -> float:
	var parsed := read_number(control, pending)
	# focus/Enter 原生提交会按 step 舍入；箭头真正改变了一步则沿用新值。
	return float(parsed.value) if parsed.ok and is_equal_approx(value, snappedf(float(parsed.value), control.step)) else value

static func tooltip(profile: String, field: Dictionary) -> String:
	var meta := preload("res://scripts/testing/tuning_catalog.gd").field(profile, String(field.key))
	return "%s\n统一语义：%s／%s\n单位：%s；允许：%s–%s；原建议：%s–%s\n约束：%s\n体型：%s；框内保存体型1的基础值，实例生成时换算。\n生效：%s\n原字段：%s" % [field.get("tip", ""), field.get("section", meta.get("module", "")), field.get("semantic", field.key), field.get("unit", meta.get("unit", "")), field.get("min", "关"), field.get("max", "开"), field.get("recommended_min", "关"), field.get("recommended_max", "开"), field.get("limit_reason", "开关"), field.get("scale_rule", "独立控制"), meta.get("apply", "重新生成"), field.key]

static func unit(profile: String, field: Dictionary) -> String:
	return String(field.get("unit", preload("res://scripts/testing/tuning_catalog.gd").field(profile, String(field.key)).get("unit", "")))
