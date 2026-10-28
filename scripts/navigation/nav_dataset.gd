class_name NavDataset
extends RefCounted
## 地图导航数据（data/navigation/*.json）的加载与校验。
## 这里只读数据，不放算法默认值：缺键直接报错，避免“代码里悄悄兜底”掩盖数据错误。

const SECTIONS := ["grid", "flow", "rebuild"]
const GRID_KEYS := ["cell_size", "half_extent", "ray_top", "ray_bottom",
	"walk_ray_above", "walk_ray_below"]
const FLOW_KEYS := ["cell_size", "wall_margin", "wall_penalty", "edge_sample",
	"source_search_cells", "nearest_search_cells"]
const REBUILD_KEYS := ["move_threshold", "interval", "rebake_radius"]


static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("导航数据不存在：%s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("导航数据不是 JSON 对象：%s" % path)
		return {}
	var data: Dictionary = parsed
	for key in ["scene", "walkability"]:
		if not data.has(key) or String(data[key]).is_empty():
			push_error("导航数据缺少 %s：%s" % [key, path])
			return {}
	for section in SECTIONS:
		if typeof(data.get(section)) != TYPE_DICTIONARY:
			push_error("导航数据缺少 %s 段：%s" % [section, path])
			return {}
	for key in GRID_KEYS:
		if not data.grid.has(key):
			push_error("导航数据缺少 grid.%s：%s" % [key, path])
			return {}
	for key in FLOW_KEYS:
		if not data.flow.has(key):
			push_error("导航数据缺少 flow.%s：%s" % [key, path])
			return {}
	for key in REBUILD_KEYS:
		if not data.rebuild.has(key):
			push_error("导航数据缺少 rebuild.%s：%s" % [key, path])
			return {}
	return data


## 烘焙/运行时共用的单位移动数据。nav 数据只负责指出“这张图用哪个身体”。
static func load_profile(data: Dictionary) -> MovementProfile:
	var path := String(data.get("bake", {}).get("movement_profile", ""))
	if path.is_empty():
		push_error("导航数据缺少 bake.movement_profile")
		return null
	var profile = load(path)
	if profile == null or not (profile is MovementProfile):
		push_error("移动数据加载失败：%s" % path)
		return null
	return profile
