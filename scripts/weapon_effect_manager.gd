class_name WeaponEffectManager
extends RefCounted
## 武器命中效果与状态异常中央架构管理器。
##
## 架构定位：
## 1. 彻底解耦武器发射逻辑（PlayerWeapon / Ballistics）与命中衍生效果（点燃、冰冻、感电、腐蚀等）；
## 2. 统一管理 Roguelite 赐福被动与未来武器属性词条的触发、叠加与状态机生命周期；
## 3. 对被命中的各类目标（近战小怪、远程怪、Boss 等）提供即插即用的状态挂载，杜绝在敌人脚本中硬编码分支。

const RunStateUtil := preload("res://scripts/run_state.gd")
const StatusEffectBurnScript := preload("res://scripts/status_effect_burn.gd")
const HealthUtil := preload("res://scripts/health_util.gd")

const EFFECT_BURN := "burn"
const EFFECT_SHOCK := "shock"
const EFFECT_FROST := "frost"
const EFFECT_CORROSION := "corrosion"


## 武器单次命中的全局统一入口：接收命中上下文并分发给所有激活的被动效果
static func apply_hit_effects(target: Node, hit_data: Dictionary) -> void:
	if not is_instance_valid(target) or not target.is_inside_tree():
		return
	if not target.is_in_group("enemies") and not target.is_in_group("boss"):
		return

	var damage: float = float(hit_data.get("damage", 10.0))
	var is_sniper: bool = bool(hit_data.get("is_sniper", false))
	if damage <= 0.0 or not HealthUtil.is_alive(target):
		return

	# 1. 赐福效果分发：灼热射击 (Incendiary Rounds)
	# 主武器子弹点燃目标，2.5s 内造成 35% 额外 DoT 伤害并显示烈焰燃烧视觉表现
	if not is_sniper and RunStateUtil.has_perk("incendiary_rounds"):
		var context: Dictionary = hit_data.get("context", {}).duplicate()
		context["source"] = context.get("source", "primary")
		# 持续伤害归属原武器，但不能把每次跳伤算成新的子弹命中。
		context["shot"] = 0
		context["headshot"] = false
		apply_status_effect(target, EFFECT_BURN, {
			"duration": 2.5,
			"total_damage": damage * 0.35,
			"context": context
		})

	# 2. 预留未来扩展点（词缀、属性子弹、元素附魔等）
	# 例如：
	# if RunStateUtil.has_perk("cryo_rounds"):
	#     apply_status_effect(target, EFFECT_FROST, { "duration": 2.0, "slow_ratio": 0.4 })
	# if RunStateUtil.has_perk("arc_rounds"):
	#     apply_status_effect(target, EFFECT_SHOCK, { "chain_count": 3, "chain_damage": damage * 0.5 })


## 绝境意志只改变玩家武器与共鸣伤害，统一使用描述中的 35% / 40%。
static func damage_multiplier(attacker: Variant) -> float:
	if not RunStateUtil.has_perk("desperate_will"):
		return 1.0
	var maximum := HealthUtil.max_health_or(attacker, 0.0)
	var current := HealthUtil.health_or(attacker, 0.0)
	return 1.4 if maximum > 0.0 and current > 0.0 and current < maximum * 0.35 else 1.0


## 挂载或刷新状态效果（自动处理重复挂载叠加、刷新持续时间）
static func apply_status_effect(target: Node, effect_id: String, params: Dictionary) -> Node:
	if not is_instance_valid(target) or not target.is_inside_tree():
		return null

	var node_name := "StatusEffect_" + effect_id
	var existing := target.get_node_or_null(node_name)
	if is_instance_valid(existing):
		if existing.has_method("refresh"):
			existing.call("refresh", params)
		return existing

	var effect_node: Node = null
	match effect_id:
		EFFECT_BURN:
			effect_node = StatusEffectBurnScript.new()
		_:
			push_warning("WeaponEffectManager: 未知状态效果类型 %s" % effect_id)
			return null

	effect_node.name = node_name
	target.add_child(effect_node)
	if effect_node.has_method("setup"):
		effect_node.call("setup", target, params)
	return effect_node


static func has_status_effect(target: Node, effect_id: String) -> bool:
	if not is_instance_valid(target):
		return false
	var existing := target.get_node_or_null("StatusEffect_" + effect_id)
	return is_instance_valid(existing)


static func remove_status_effect(target: Node, effect_id: String) -> void:
	if not is_instance_valid(target):
		return
	var existing := target.get_node_or_null("StatusEffect_" + effect_id)
	if is_instance_valid(existing):
		existing.queue_free()

