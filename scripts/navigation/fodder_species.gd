class_name FodderSpecies
extends RefCounted
## 人群/炮灰系统可用的敌人种类登记：种类 id → 导航数据（内含 movement_profile 与通行表）。
## 换敌人只查这张表，不在观察台、探针或命令行李写路径。

const SPECIES := {
	"mud_golem": {
		"nav": "res://data/navigation/sanctum_nav.json",
		"label": "泥土傀儡",
	},
	"fast_beast": {
		"nav": "res://data/navigation/sanctum_nav_fast_beast.json",
		"label": "迅兽",
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
