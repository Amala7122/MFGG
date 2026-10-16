extends RefCounted
## Interpretive experiments, not reproductions of paintings. Palette ordering:
## meadow, stone, foliage, wood, rock, distant ridge, accent, road.
const PRESETS := [
	{
		"name": "水墨丹青 · 山水留白", "mode": 0,
		"description": "形体研究：倾斜山峰、弯干树枝、叠簇树冠、勾线与淡墨点染；仍是样板，不是完成的国画场景。",
		"palette": ["c7cec0", "75796a", "294f44", "30382f", "4c6158", "6b8d83", "61aca3", "d0c6ab"],
		"sky": "e4e3d5", "horizon": "ece9da", "ambient": "e4e5d8", "sun": "f5f1de",
		"fog": 0.0045, "sun_scale": 0.48, "ambient_scale": 0.6, "softness": 0.75,
	},
	{
		"name": "莫奈启发 · 印象色光", "mode": 1,
		"description": "初稿：目前只研究短碎笔触与色光；形体与轮廓尚未按此方向重做。",
		"palette": ["83a568", "b5b29b", "559d85", "7d6b79", "9caaa9", "9eabc4", "93cbdc", "dab78b"],
		"sky": "a8bfdb", "horizon": "e2d6dc", "ambient": "b6bfed", "sun": "ffe4c6",
		"fog": 0.007, "sun_scale": 0.78, "ambient_scale": 1.08, "softness": 0.82,
	},
	{
		"name": "塞尚启发 · 色面建构", "mode": 2,
		"description": "初稿：目前只研究斜向笔触与冷暖色面；形体与轮廓尚未按此方向重做。",
		"palette": ["79915b", "b7a379", "466c52", "735e47", "8a968e", "788ca9", "699dab", "bb8652"],
		"sky": "789bb7", "horizon": "c3c8b0", "ambient": "b2c8d4", "sun": "ffdda9",
		"fog": 0.003, "sun_scale": 0.78, "ambient_scale": 0.88, "softness": 0.26,
	},
	{
		"name": "梵高启发 · 律动厚涂", "mode": 3,
		"description": "初稿：目前只研究弯曲排线与浓重色彩；形体与轮廓尚未按此方向重做。",
		"palette": ["87943d", "c2aa60", "42774a", "80603c", "6b8a92", "527b9e", "64cdb9", "dca544"],
		"sky": "2d6291", "horizon": "96b7bd", "ambient": "93b5df", "sun": "ffe08e",
		"fog": 0.004, "sun_scale": 0.88, "ambient_scale": 0.9, "softness": 0.38,
	},
	{
		"name": "木版卡通 · 刀刻色块", "mode": 4,
		"description": "刀刻色块首版：三档主明暗、成组叶团、局部锥形切痕、克制细轮廓；远景与路面减少碎纹。参数仅保存在实验室。",
		"palette": ["85a64b", "c1ae83", "648934", "705337", "999583", "729db9", "65c9d8", "edb65f"],
		"sky": "62a5d1", "horizon": "b6cfda", "ambient": "9eb8ce", "sun": "ffedce",
		"fog": 0.003, "sun_scale": 0.9, "ambient_scale": 0.65, "softness": 0.0,
	},
]

static func surface_kind(node_name: String, is_ground: bool) -> int:
	if is_ground: return 0
	if node_name.begins_with("Crown") or node_name.begins_with("Grass"): return 2
	if node_name.begins_with("Tree"): return 3
	if node_name.begins_with("Boulder"): return 4
	if node_name.begins_with("DistantRidge"): return 5
	if node_name.begins_with("Crystal") or node_name.begins_with("Wildflower"): return 6
	return 1
