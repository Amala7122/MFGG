extends RefCounted
## 程序化战斗敌人的接入表。模型、AI、受击与动画仍使用实验室里的同一场景。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const SPECIES := {
	"burst_crawler": {"profile": "VisualBurstCrawler", "box": true, "scene": preload("res://prototypes/enemy_prototypes/procedural_burst_crawler.tscn")},
	"prism_spider": {"profile": "VisualPrismSpider", "box": true, "scene": preload("res://prototypes/enemy_prototypes/procedural_prism_spider.tscn")},
	"charge_beetle": {"profile": "VisualChargeBeetle", "box": true, "scene": preload("res://prototypes/enemy_prototypes/procedural_charge_beetle.tscn")},
	"mud_golem": {"profile": "PrototypeMudGolem", "scene": preload("res://prototypes/enemy_prototypes/procedural_mud_golem.tscn")},
	"fast_beast": {"profile": "PrototypeFastBeast", "scene": preload("res://prototypes/enemy_prototypes/procedural_fast_beast.tscn")},
	"hornet": {"profile": "PrototypeHornet", "scene": preload("res://prototypes/enemy_prototypes/procedural_hornet.tscn")},
}


static func prepare(entry: Dictionary) -> Dictionary:
	var id := String(entry.get("species", ""))
	if not SPECIES.has(id):
		push_error("未登记的战斗敌人：" + id)
		return {}
	var record: Dictionary = SPECIES[id]
	var preset := String(entry.get("preset", "@active"))
	if preset == "@active":
		preset = Tuning.active_name(record.profile)
	if not Tuning.preset_names(record.profile).has(preset):
		push_error("敌人方案不存在：%s / %s" % [id, preset])
		return {}
	var values := Tuning.preset_values(record.profile, preset)
	var result := entry.duplicate(true)
	result["resolved_preset"] = preset
	result["tuning"] = values
	# 与实际碰撞形状取同一份几何定义，按最大随机体型检查落点。
	# 不实例化“尚未进树”的临时敌人：其预创建攻击区还没有父节点，会泄漏。
	var state: SceneState = record.scene.get_state()
	var model: Script
	for index in range(state.get_node_property_count(0)):
		if state.get_node_property_name(0, index) == &"script":
			model = state.get_node_property_value(0, index)
	if model == null or not model.has_method("get_body_dimensions"):
		push_error("战斗敌人缺少投放尺寸接口：" + id)
		return {}
	var dimensions: Vector3 = model.get_body_dimensions(values)
	result["body_radius"] = Vector2(dimensions.x, dimensions.z).length() * 0.5 if id == "fast_beast" or bool(record.get("box", false)) else dimensions.x * 0.5
	result["body_height"] = dimensions.y
	if id == "fast_beast" or bool(record.get("box", false)):
		result["body_dimensions"] = dimensions
	result["scale"] = float(values.body_size) * (1.0 + float(values.variation_size) if bool(values.variation_enabled) else 1.0)
	return result


static func instantiate(entry: Dictionary) -> CharacterBody3D:
	var prepared := entry if entry.has("tuning") else prepare(entry)
	if prepared.is_empty():
		return null
	var node: CharacterBody3D = SPECIES[String(prepared.species)].scene.instantiate()
	node.set_meta(&"enemy_tuning", prepared.tuning.duplicate(true))
	node.set_meta(&"formal_enemy", true)
	node.set_meta(&"enemy_entry", prepared.duplicate(true))
	return node
