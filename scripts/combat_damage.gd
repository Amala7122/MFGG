extends RefCounted
## 护甲仍由目标自己的伤害入口计算；只有玩家近战重击携带穿甲上下文。
static func armored(enemy: Node, amount: float, armor: float) -> float:
	var context: Dictionary = enemy.get_meta(&"combat_context", {})
	var penetration := 0.0
	if context.get("source_kind", "") == "player" and context.get("melee_kind", "") == "heavy":
		penetration = clampf(float(context.get("armor_penetration", 0.0)), 0.0, 1.0)
	return amount * (1.0 - clampf(armor, 0.0, 1.0) * (1.0 - penetration))
