extends RefCounted
## 可选的结算观察入口；只有实验场给实例挂记录器，正式战斗为空操作。

const RECORDER := &"combat_recorder"
const CONTEXT := &"combat_context"


static func recorder(node: Object) -> RefCounted:
	if not is_instance_valid(node) or not node.has_meta(RECORDER):
		return null
	return node.get_meta(RECORDER, null) as RefCounted


static func begin_attack(host: Node, source: String) -> Dictionary:
	var stats := recorder(host)
	if stats == null:
		return {}
	stats.call("capture_player", host)
	return {"source": source, "shot": stats.call("begin_attack", source), "headshot": false}


static func source_info(source: Node, attack: String) -> Dictionary:
	if not is_instance_valid(source):
		return {"id": "unknown", "title": "未归属", "attack": attack}
	return {
		"id": String(source.get_meta(&"lab_roster_id", "unknown")),
		"title": String(source.get_meta(&"lab_title", "未归属")), "attack": attack,
	}


static func hurt_player(target: Node, amount: float, at: Vector3, scale: float, info: Dictionary) -> void:
	if recorder(target) == null:
		target.call("take_damage", amount, at, scale)
		return
	var previous: Variant = target.get_meta(CONTEXT) if target.has_meta(CONTEXT) else null
	target.set_meta(CONTEXT, info)
	target.call("take_damage", amount, at, scale)
	if previous == null:
		target.remove_meta(CONTEXT)
	else:
		target.set_meta(CONTEXT, previous)


static func enemy_damaged(enemy: Node, before: float) -> void:
	var stats := recorder(enemy)
	if stats != null:
		stats.call("enemy_damaged", enemy, before, float(enemy.get("health")), enemy.get_meta(CONTEXT, {}))


static func hurt_enemy(enemy: Node, amount: float, context: Dictionary) -> void:
	var previous: Variant = enemy.get_meta(CONTEXT) if enemy.has_meta(CONTEXT) else null
	enemy.set_meta(CONTEXT, context)
	enemy.call("take_damage", amount)
	if previous == null:
		enemy.remove_meta(CONTEXT)
	else:
		enemy.set_meta(CONTEXT, previous)


static func credits_player(enemy: Node) -> bool:
	return String(enemy.get_meta(CONTEXT, {}).get("source_kind", "player")) != "enemy"


static func manages_reaction(enemy: Node) -> bool:
	return bool(enemy.get_meta(CONTEXT, {}).get("managed_reaction", false))


static func resource(host: Node, source: String, kind: String, amount: float = 1.0) -> void:
	var stats := recorder(host)
	if stats != null:
		stats.call("resource", source, kind, amount)
