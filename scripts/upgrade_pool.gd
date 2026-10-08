class_name UpgradePool
extends RefCounted
## Roguelite 波间强化词条库与抽取系统。
##
## 每波清空后由 WaveDirector 触发，GameFlow 弹出 3 选 1 石板面板。
## 强化的效果与「遗迹共鸣」「武器性能」「生存防御」紧密协同。

const RunStateUtil := preload("res://scripts/run_state.gd")

enum Rarity { COMMON, RARE, LEGENDARY }

const PERKS: Array[Dictionary] = [
	{
		"id": "resonance_amplification",
		"title": "共鸣增幅",
		"icon": "🔮",
		"rarity": Rarity.COMMON,
		"desc": "共鸣能量上限 +30，溢出空间提升。能蓄积更多能量以发动更强爆发。"
	},
	{
		"id": "fury_charge",
		"title": "怒火充能",
		"icon": "⚡",
		"rarity": Rarity.COMMON,
		"desc": "受击时共鸣能量充能速度提升 50%。在密集压力下快速积蓄力量。"
	},
	{
		"id": "phantom_dodge",
		"title": "幻影回响",
		"icon": "💨",
		"rarity": Rarity.RARE,
		"desc": "完美闪避（在翻滚无敌帧避开攻击）获得的能量翻倍 (+100%)。"
	},
	{
		"id": "reaper_echo",
		"title": "收割回响",
		"icon": "💀",
		"rarity": Rarity.LEGENDARY,
		"desc": "共鸣爆发命中 2 个以上敌人时，立即返还 35% 能量！"
	},
	{
		"id": "overload_core",
		"title": "过载核心",
		"icon": "💎",
		"rarity": Rarity.RARE,
		"desc": "能量溢出上限提升至 200%，共鸣爆发总体伤害额外提升 30%。"
	},
	{
		"id": "desperate_will",
		"title": "绝境意志",
		"icon": "🩸",
		"rarity": Rarity.COMMON,
		"desc": "生命值低于 35% 时，全武器与爆发伤害提升 40%。"
	},
	{
		"id": "shield_overload",
		"title": "护盾过载",
		"icon": "🛡️",
		"rarity": Rarity.COMMON,
		"desc": "最大护盾值 +35 点，护盾自愈延迟缩短 0.8 秒。"
	},
	{
		"id": "chain_lightning",
		"title": "连锁电弧",
		"icon": "⚡",
		"rarity": Rarity.RARE,
		"desc": "击杀敌人时，向 5 米内最近的另一个敌人跳射闪电，造成 60 点伤害。"
	},
	{
		"id": "incendiary_rounds",
		"title": "灼热射击",
		"icon": "🔥",
		"rarity": Rarity.COMMON,
		"desc": "主武器子弹使敌人点燃，在 2.5 秒内持续造成相当于子弹 35% 的伤害。"
	},
	{
		"id": "armor_pierce",
		"title": "穿甲弹芯",
		"icon": "🎯",
		"rarity": Rarity.RARE,
		"desc": "狙击穿透目标数 +2（最多穿透 5 个敌人），穿透伤害不递减。"
	},
	{
		"id": "timewarp",
		"title": "时空裂隙",
		"icon": "⏱️",
		"rarity": Rarity.RARE,
		"desc": "共鸣爆发造成的敌人减速时长从 2.2 秒延长至 4.2 秒。"
	},
	{
		"id": "vampiric_touch",
		"title": "战地汲取",
		"icon": "🩹",
		"rarity": Rarity.COMMON,
		"desc": "击杀敌人时立即回复 4 点生命值。"
	},
	{
		"id": "rapid_cycler",
		"title": "游击步伐",
		"icon": "🏃",
		"rarity": Rarity.COMMON,
		"desc": "移动速度 +12%，翻滚冷却时间缩短 20%。"
	},
	{
		"id": "resonance_burn",
		"title": "余震烈焰",
		"icon": "🌋",
		"rarity": Rarity.LEGENDARY,
		"desc": "共鸣爆发后在地面留下一片灼烧领域，持续 5 秒灼烧踏入其中的敌人。"
	}
]


static func get_perk(id: String) -> Dictionary:
	for perk in PERKS:
		if String(perk.get("id", "")) == id:
			return perk
	return {}


static func roll_three(stage: int = 1, wave: int = 1) -> Array[Dictionary]:
	var available: Array[Dictionary] = PERKS.duplicate()
	var result: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	# 随着波次推进，高稀有度概率略微上升
	var legendary_chance := 0.10 + float(wave) * 0.04

	available.shuffle()

	# 抽取 3 个互不相同的词条
	while result.size() < 3 and not available.is_empty():
		var candidate: Dictionary = available.pop_back()
		# 传说词条概率筛选
		if int(candidate.get("rarity", Rarity.COMMON)) == Rarity.LEGENDARY:
			if rng.randf() > legendary_chance:
				continue
		result.append(candidate)

	# 兜底保证至少 3 个
	if result.size() < 3:
		for perk in PERKS:
			if not result.has(perk):
				result.append(perk)
			if result.size() >= 3:
				break

	return result
