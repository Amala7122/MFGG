extends "res://tools/probes/sparring/sparring_controller.gd"
## 公开情境检索真人操作片段；没有覆盖就中性输入，不加入自动瞄准／保命规则。
const HumanData := preload("res://tools/probes/sparring/sparring_human_data.gd")
var model: Dictionary = {}
var _frames: Array = []
var _context: Dictionary = {}
var _index := 0
var _remaining := 0.0
var _entered := false
var _danger_age := 0.0
var _warning_key := ""
var covered_seconds := 0.0
var total_seconds := 0.0
var selections := 0

func step(player: CharacterBody3D, boss: Node3D, delta: float) -> Dictionary:
	elapsed += delta
	total_seconds += delta
	var context := public_context(player, boss)
	var key := String(context.warning_key) if bool(context.danger) else ""
	_danger_age = _danger_age + delta if key == _warning_key and not key.is_empty() else 0.0
	_warning_key = key
	context["danger_age"] = _danger_age
	if _index >= _frames.size() or not is_finite(HumanData.context_score(context, _context)):
		var matches := HumanData.candidates(model.chunks, context)
		_frames = []
		_index = 0
		_remaining = 0.0
		_entered = false
		if not matches.is_empty():
			var chosen: Dictionary = model.chunks[int(matches[_rng.randi_range(0, matches.size() - 1)])]
			_frames = chosen.frames
			_context = chosen.context
			selections += 1
	if _frames.is_empty():
		return {"held": {}, "just": {}, "move_local": Vector2.ZERO, "activity": "imitation_uncovered", "aim_captured": false}
	covered_seconds += delta
	var row: Dictionary = _frames[_index]
	var just := {}
	var yaw_delta := 0.0
	var budget := delta
	# 时间重采样；跨过的瞬时键合并一次，不能重复发送同一条翻滚／手雷请求。
	while budget > 0.000001 and _index < _frames.size():
		row = _frames[_index]
		if not _entered:
			_remaining = float(row.delta)
			for action: String in row.just:
				if bool(row.just[action]):
					just[action] = true
			yaw_delta += float(row.yaw_delta)
			_entered = true
		var consumed := minf(budget, _remaining)
		_remaining -= consumed
		budget -= consumed
		if _remaining <= 0.000001:
			_index += 1
			_entered = false
	var output := {"held": row.held.duplicate(), "just": just, "move_local": Vector2(float(row.move[0]), float(row.move[1])),
		"aim_captured": row.aim_captured, "activity": "empirical_imitation", "scan_yaw": yaw_delta, "view_pitch": float(row.pitch)}
	if bool(context.visible):
		output["view_yaw"] = float(context.target_yaw) + float(row.yaw_offset)
		output.view_pitch = clampf(float(context.target_pitch) + float(row.pitch_offset), deg_to_rad(-70.0), deg_to_rad(65.0))
	return output

func audit() -> Dictionary:
	return {"status": "experimental_not_independently_validated", "source_origin": model.get("source_origin", "unknown"),
		"source_directory": model.get("source_directory", ""), "source_input_sha256": model.get("source_input_sha256", ""),
		"source_eligible": model.get("source_eligible", false), "validation": model.get("validation", {}), "selections": selections,
		"covered_seconds": covered_seconds, "total_seconds": total_seconds, "uncovered_fraction": 1.0 - covered_seconds / maxf(total_seconds, 0.001),
		"fallback": "neutral_input", "population_inference_allowed": false}
