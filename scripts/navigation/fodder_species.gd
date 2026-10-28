class_name FodderSpecies
extends RefCounted
## 人群/炮灰系统可用的敌人种类登记：种类 id → 导航数据（内含 profile 与通行表）。
## 换敌人只查这张表，不在观察台、探针或命令行李写路径。
## 没有预烘焙数据的种类会在运行时按体型生成 profile，并让 FodderField 现烘通行表。

const Catalog := preload("res://scripts/enemies/creature_catalog.gd")

const SPECIES := {
	"mud_golem": {
		"nav": "res://data/navigation/sanctum_nav.json",
		"label": "泥土傀儡",
	},
	"fast_beast": {
		"nav": "res://data/navigation/sanctum_nav_fast_beast.json",
		"label": "迅兽",
	},
	"burst_crawler": {
		"nav": "",
		"label": "爆囊爬兽",
	},
	"prism_spider": {
		"nav": "",
		"label": "棱眼蛛",
	},
	"charge_beetle": {
		"nav": "",
		"label": "裂甲兜虫",
	},
}


static func ids() -> Array:
	return SPECIES.keys()


static func has_species(id: String) -> bool:
	return SPECIES.has(id)


static func nav_path(id: String) -> String:
	return String(SPECIES.get(id, {}).get("nav", ""))


static func label(id: String) -> String:
	return String(SPECIES.get(id, {}).get("label", id))


## 在登记表里循环切种类；步长为 +1/-1。
static func next_id(id: String, step := 1) -> String:
	var list := ids()
	var index := list.find(id)
	if index < 0:
		index = 0
	var size := list.size()
	return String(list[(index + step + size) % size])


## 没有预烘焙 nav 的种类：按战斗目录的真实体型现场生成 movement profile。
## 胶囊要求 height >= 2r，所以半径钳到 min(半对角线, 高/2)，和 fast_beast 的结论一致。
static func runtime_profile(id: String):
	var prepared: Dictionary = Catalog.prepare({"species": id})
	if prepared.is_empty():
		return null
	var body_radius := float(prepared.get("body_radius", 0.5))
	var body_height := float(prepared.get("body_height", 1.0))
	var radius := minf(body_radius, body_height * 0.5 - 0.001)
	if radius <= 0.05:
		radius = 0.05
	var profile := MovementProfile.new()
	profile.id = id
	profile.radius = radius
	profile.body_height = body_height
	profile.step_height = 0.7
	profile.max_slope_deg = 40.0
	profile.ignore_terrain = id == "prism_spider"
	profile.foot_clearance = 0.05
	profile.sweep_lift = 0.2
	profile.separation_radius = maxf(radius * 2.0 + 0.2, 1.2)
	profile.separation_strength = 1.1
	return profile
