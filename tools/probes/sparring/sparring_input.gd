extends RefCounted
## 版本化的物理帧输入合同；旧记录能读，但不能补造捕获状态／步长。
const HELD := ["shoot", "aim", "sprint", "free_look"]
const JUST := ["dodge", "grenade", "skill", "reload", "jump", "resonance_burst"]

static func number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func problem(row: Variant, index: int) -> String:
	if not row is Dictionary or not row.get("held") is Dictionary or not row.get("just") is Dictionary or not row.get("move") is Array or row.move.size() != 2:
		return "输入结构不完整"
	for value: Variant in [row.move[0], row.move[1], row.get("yaw"), row.get("pitch"), row.get("time"), row.get("frame")]:
		if not number(value):
			return "输入包含非法坐标／帧号"
	if float(row.frame) != index or Vector2(float(row.move[0]), float(row.move[1])).length() > 1.001:
		return "输入帧缺失、重复或移动向量越界"
	for map: Dictionary in [row.held, row.just]:
		for key: String in map:
			if not map[key] is bool:
				return "输入按键必须是布尔值"
	if int(row.get("schema", 1)) >= 2:
		if not number(row.get("delta")) or float(row.delta) < 0.001 or float(row.delta) > 0.25 or not row.get("aim_captured") is bool:
			return "新版输入缺少有效物理步长／鼠标捕获状态"
		if not row.get("context") is Dictionary or not row.get("position") is Array or row.position.size() != 3:
			return "新版输入缺少公开情境／位置"
		for key: String in ["distance", "visible_count", "danger_age", "warning_progress", "health_ratio", "shield_ratio", "target_yaw", "target_pitch"]:
			if not number(row.context.get(key)):
				return "公开情境数值无效"
		for value: Variant in row.position:
			if not number(value):
				return "位置数值无效"
	return ""

static func read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"frames": [], "problems": ["无法读取输入文件"], "complete_contract": false}
	var frames: Array = []
	var problems: Array = []
	var complete := true
	var last_time := -1.0
	var previous_delta := 0.0
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var row: Variant = JSON.parse_string(line)
		var error := problem(row, frames.size())
		if not error.is_empty() or frames.size() >= 200000:
			problems.append("第 %d 帧：%s" % [frames.size(), error if not error.is_empty() else "超过保护上限"])
			break
		if float(row.time) <= last_time:
			problems.append("输入时间未递增")
			break
		if last_time >= 0 and previous_delta > 0 and absf(float(row.time) - last_time - previous_delta) > 0.001:
			problems.append("输入步长与时间线不连续")
			break
		last_time = float(row.time)
		previous_delta = float(row.get("delta", 0.0))
		complete = complete and int(row.get("schema", 1)) >= 2
		frames.append(row)
	file.close()
	if frames.is_empty() and problems.is_empty():
		problems.append("输入为空")
	return {"frames": frames, "problems": problems, "complete_contract": complete and problems.is_empty() and not frames.is_empty()}
