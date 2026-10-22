extends RefCounted

const HealthUtil := preload("res://scripts/health_util.gd")
const CpuAudit := preload("res://scripts/enemy_cpu_audit.gd")
## 可选的结算观察入口；只有实验场给实例挂记录器，正式战斗为空操作。

const RECORDER := &"combat_recorder"
const CONTEXT := &"combat_context"


static func recorder(node: Object) -> RefCounted:
	if not is_instance_valid(node) or not node.has_meta(RECORDER):
		return null
	return node.get_meta(RECORDER, null) as RefCounted

static func enemy_attack_started(host: Node, attack: String) -> void:
	if CpuAudit.enabled: CpuAudit.mark_attack(host)
	var stats := recorder(host)
	if stats == null:
		return
	host.set_meta(&"sparring_attack_serial", int(host.get_meta(&"sparring_attack_serial", 0)) + 1)
	if stats.has_method("record_enemy_attack"):
		stats.call("record_enemy_attack", host, attack)


static func enemy_attack_beat(host: Node, attack: String, beat: int, total: int) -> void:
	var stats := recorder(host)
	if stats != null and stats.has_method("record_enemy_beat"):
		stats.call("record_enemy_beat",host,attack,beat,total)


static func begin_attack(host: Node, source: String) -> Dictionary:
	var stats := recorder(host)
	if stats == null:
		return {}
	stats.call("capture_player", host)
	return {"source": source, "shot": stats.call("begin_attack", source), "headshot": false}


static func source_info(source: Node, attack: String) -> Dictionary:
	if not is_instance_valid(source):
		return {"id": "unknown", "title": "未归属", "attack": attack}
	var info := {
		"id": String(source.get_meta(&"lab_roster_id", "unknown")),
		"title": String(source.get_meta(&"lab_title", "未归属")), "attack": attack,
	}
	if source.has_meta(&"sparring_actor_id"):
		info["subject_id"] = String(source.get_meta(&"sparring_actor_id"))
	if source.is_inside_tree() and source.get_tree().has_group("attack_inspection_observers"):
		info["inspection_actor_id"] = source.get_instance_id()
	return info


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
		stats.call("enemy_damaged", enemy, before, HealthUtil.health_or(enemy, 0.0), enemy.get_meta(CONTEXT, {}))


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
