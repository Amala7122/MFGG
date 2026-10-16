extends RefCounted
## APS 路径形状流水线的薄适配层：只负责参数入口（data/navigation/steering.json）
## 与调用 nav_arc_shape 的五个阶段，本身不再实现形状数学。
## 形状实现与移植来源见 scripts/nav_arc_shape.gd 与
## docs/features/APS路径算法移植实现文档.md 第 3、4 节。
const Query := preload("res://scripts/spatial_query.gd")
const ArcShape := preload("res://scripts/nav_arc_shape.gd")
const CONFIG_PATH := "res://data/navigation/steering.json"
static var _settings: Dictionary = {}
static var revision := 0

static func defaults() -> Dictionary:
	## 默认值必须保持现状：arc_strength = 0 关闭弧形形变，lane_offset = 0 关闭车道偏移，
	## 只有 corner_rounding 生效（既有圆角），见移植文档第 9 节。
	return {
		"corner_rounding": 0.8,
		"lane_offset": 0.0,
		"goal_replan_distance": 0.8,
		"arc_strength": 0.0,
		"arc_num_midpoints": 3,
		"arc_mode": "smooth",
		"arc_min_distance": 3.0,
		"arc_resample_length": 4.0,
		"shape_max_points": 128,
		"arc_sparse_warp": true,
		"shape_final_gate": true,
	}

static func coerce() -> void:
	_settings["corner_rounding"] = clampf(float(_settings.get("corner_rounding", 0.8)), 0.0, 2.0)
	_settings["lane_offset"] = clampf(float(_settings.get("lane_offset", 0.0)), -3.0, 3.0)
	_settings["goal_replan_distance"] = clampf(float(_settings.get("goal_replan_distance", 0.8)), 0.2, 3.0)
	_settings["arc_strength"] = clampf(float(_settings.get("arc_strength", 0.0)), -3.0, 3.0)
	_settings["arc_num_midpoints"] = clampi(int(_settings.get("arc_num_midpoints", 3)), 1, 6)
	_settings["arc_mode"] = "wavy" if String(_settings.get("arc_mode", "smooth")) == "wavy" else "smooth"
	_settings["arc_min_distance"] = clampf(float(_settings.get("arc_min_distance", 3.0)), 0.0, 50.0)
	_settings["arc_resample_length"] = clampf(float(_settings.get("arc_resample_length", 4.0)), 0.5, 10.0)
	_settings["shape_max_points"] = clampi(int(_settings.get("shape_max_points", 128)), 16, 192)
	_settings["arc_sparse_warp"] = bool(_settings.get("arc_sparse_warp", true))
	_settings["shape_final_gate"] = bool(_settings.get("shape_final_gate", true))

static func settings() -> Dictionary:
	## 返回当前生效设置。调用方不得修改返回值：apply() 每次都换成新字典，
	## 因此早期取到的引用是稳定快照（观察台用它做「未保存」比较）。
	if _settings.is_empty():
		_settings = defaults()
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
		if parsed is Dictionary:
			for key: String in _settings:
				if parsed.has(key):
					_settings[key] = parsed[key]
		coerce()
	return _settings

static func apply(values: Dictionary) -> void:
	## 白名单合并：只接受已知键，未知键忽略；未提供的键保留默认值（不再整体重建）。
	var merged := defaults()
	for key: String in merged:
		if values.has(key):
			merged[key] = values[key]
	_settings = merged
	coerce()
	revision += 1

static func save(path: String = CONFIG_PATH) -> Error:
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error != OK and error != ERR_ALREADY_EXISTS:
		return error
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(settings(), "\t") + "\n")
	return OK

static func shape(body: CharacterBody3D, map: RID, base: PackedVector3Array, safe_drop: float, exclude: Array[RID] = []) -> PackedVector3Array:
	return ArcShape.shape(body, map, base, safe_drop, exclude, settings())

static func stage_stats() -> Dictionary:
	## 最近一次 shape() 的分阶段统计（观察台与验收报告消费）。
	return ArcShape.last_stats
