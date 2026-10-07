class_name Ballistics
extends RefCounted
## 命中结算统一入口。
##
## 瞬发命中（玩家的射击路径，原先的"T 键切换弹丸"已删除、玩家侧飞行弹退役）
## 与敌人弹幕命中结算。玩家的射击固定瞬发；敌人弹幕仍是飞行弹丸 ——
## 射线直击）都走这里，避免"伤害 + 特效 + 伤害飘字 + 命中标记"被抄成三份。

## 音频走静态入口，autoload 未注册时自动降级为空操作。
const AudioUtil := preload("res://scripts/audio_manager.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")

## 爆头时的特效配色，也会传给伤害飘字。
const HEADSHOT_COLOR := Color(1.0, 0.45, 0.12, 1.0)
## 默认爆头区：碰撞胶囊总高度从上往下 25% 以内。
const DEFAULT_HEADSHOT_HEIGHT_RATIO := 0.75

## 以下数值全部来自 data/game_config.json 的 weapon 段，函数里的字面量只是兜底默认值。
##
## 为什么用静态变量缓存、而不是每次直接读配置：Ballistics 全是静态函数，放不了成员
## 变量；而 sniper_damage() 每发子弹都会调用一次，点号查找需要 split 字符串再走一遍
## 字典，放在发射路径上不值得。缓存后开销与改动前的 const 读取等价。
const ConfigUtil := preload("res://scripts/game_config.gd")

static var _cache_sniper_base := -1.0
static var _cache_sniper_growth := -1.0
static var _cache_tiers: Array = []
static var _cache_margin := -1.0


## 狙击单发基础伤害（武器 Lv.1）。改这个值，下面的档位会整体等比缩放。
static func _sniper_base() -> float:
	if _cache_sniper_base < 0.0:
		_cache_sniper_base = ConfigUtil.get_float("weapon.sniper_base_damage", 60.0)
	return _cache_sniper_base


## 狙击伤害随武器等级的成长系数（默认每级 +11%）。
static func _sniper_growth_per_level() -> float:
	if _cache_sniper_growth < 0.0:
		_cache_sniper_growth = ConfigUtil.get_float("weapon.sniper_growth_per_level", 0.11)
	return _cache_sniper_growth


## 远程敌人的血量档位，按"狙击几发打死"定义（躯干 / 爆头）：
##   档 0 → 1 发 / 爆头 1 发
##   档 1 → 2 发 / 爆头 1 发
##   档 2 → 3 发 / 爆头 1 发
##   档 3 → 5 发 / 爆头 2 发
##
## 之所以能用"发数"当档位，是因为狙击是固定伤害：伤害不随目标血量浮动，
## 于是敌人强度可以直接用"几发死"来表达，而不是一个抽象的百分比。
static func _shot_tiers() -> Array:
	if _cache_tiers.is_empty():
		_cache_tiers = ConfigUtil.get_int_array("weapon.ranged_shot_tiers", [1, 2, 3, 5])
	return _cache_tiers


## 血量余量系数：把血量压在整发数之下，避免浮点 / 取整误差导致要多打一发。
static func _health_margin() -> float:
	if _cache_margin < 0.0:
		_cache_margin = ConfigUtil.get_float("weapon.ranged_health_margin", 0.92)
	return _cache_margin


## 狙击伤害与远程敌人血量共用这个系数 —— 因此"几发打死"在整个武器等级
## 区间内恒定，玩家升级不会让档位表失效。
static func sniper_growth(weapon_level: int) -> float:
	return 1.0 + float(maxi(weapon_level - 1, 0)) * _sniper_growth_per_level()


static func sniper_damage(weapon_level: int) -> float:
	return _sniper_base() * sniper_growth(weapon_level)


## 远程敌人血量：按档位 + 武器等级算出，与狙击伤害同步成长。
static func ranged_health(tier: int, weapon_level: int) -> float:
	return ranged_health_tier(tier) * sniper_growth(weapon_level)


## 不随等级的档位基准值（固定刷怪点用它，再由 enemy_spawn_point 乘成长系数）。
static func ranged_health_tier(tier: int) -> float:
	var tiers := _shot_tiers()
	var index := clampi(tier, 0, tiers.size() - 1)
	return float(tiers[index]) * _sniper_base() * _health_margin()


## 爆头判定：把命中点换算到敌人的局部高度后与胶囊上沿比较。
##
## 刻意不加额外碰撞体：既不用改敌人场景，也天然适配敌人的 0.65~1.75 倍缩放。
static func is_headshot(
	enemy: Node3D, hit_y: float, height_ratio: float = DEFAULT_HEADSHOT_HEIGHT_RATIO
) -> bool:
	if not is_instance_valid(enemy):
		return false
	var half_height := 0.95
	var capsule := enemy.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if capsule and (capsule.shape is CapsuleShape3D or capsule.shape is CylinderShape3D):
		half_height = float(capsule.shape.height) * 0.5
	elif capsule and capsule.shape is BoxShape3D:
		half_height = (capsule.shape as BoxShape3D).size.y * 0.5
	elif capsule and capsule.shape is SphereShape3D:
		half_height = (capsule.shape as SphereShape3D).radius
	var scale_y := maxf(enemy.global_basis.get_scale().y, 0.01)
	var local_y := (hit_y - enemy.global_position.y) / scale_y
	return local_y >= half_height * (height_ratio * 2.0 - 1.0)


## 最终伤害 = 固定伤害 × 爆头倍率。
##
## 刻意不用"按目标最大生命比例"结算：那样血量成长对玩家完全无感，
## 敌人也没法用"几发死"来表达强度。固定伤害 + 血量档位才让敌人有分级。
static func damage_with_headshot(
	base_damage: float, headshot_multiplier: float, headshot: bool
) -> float:
	return base_damage * headshot_multiplier if headshot else base_damage


## 结算一次命中 = 施加伤害 + 出表现。
##
## 【这是唯一的伤害入口】—— 血量与击杀都在这里一次算清，
## 调用方（玩家武器 / 爆炸物）只管把碰撞结果传进来。
static func resolve_hit(
	scene: Node,
	position: Vector3,
	normal: Vector3,
	collider: Object,
	amount: float,
	headshot: bool,
	impact_scale: float = 1.0
) -> void:
	var killed := apply_damage(collider, amount, position, headshot)
	play_hit_feedback(
		scene, position, normal, collider, amount, headshot, killed,
		impact_scale, true
	)


## 只施加伤害，返回是否击杀。
## 击杀判定必须放在 take_damage 之后：敌人是在 die() 里 queue_free 的。
static func apply_damage(
	collider: Object, amount: float, position: Vector3, headshot: bool, context: Dictionary = {}
) -> bool:
	var target := collider as Node
	if target == null or not target.is_in_group("enemies"):
		return false
	var observing := Telemetry.recorder(target) != null
	var previous: Variant = target.get_meta(Telemetry.CONTEXT) if observing and target.has_meta(Telemetry.CONTEXT) else null
	if observing:
		var hit_context := context.duplicate()
		hit_context["headshot"] = headshot
		target.set_meta(Telemetry.CONTEXT, hit_context)
	# 声明了 take_damage_at 的目标可以按命中点细分伤害（Boss 用它判弱点）。
	# 普通敌人没有这个方法，继续走单一参数那条路 —— 所以这次改动对它们
	# 是完全透明的，不需要逐个去改 take_damage 的签名。
	if target.has_method("take_damage_at"):
		target.call("take_damage_at", amount, position, headshot)
	elif target.has_method("take_damage"):
		target.call("take_damage", amount)
	if observing:
		if previous == null:
			target.remove_meta(Telemetry.CONTEXT)
		else:
			target.set_meta(Telemetry.CONTEXT, previous)
	return target.is_queued_for_deletion()


## 命中表现：火花 / 飘字 / 音效 / 准星标记。**各端本地调用，不参与任何判定。**
## 打在地形上只出火花，不飘字。
static func play_hit_feedback(
	scene: Node,
	position: Vector3,
	normal: Vector3,
	collider: Object,
	amount: float,
	headshot: bool,
	killed: bool,
	impact_scale: float = 1.0,
	marker: bool = true
) -> void:
	var target := collider as Node
	var is_enemy := target != null and target.is_in_group("enemies")
	var is_metal := false
	if is_enemy and target != null:
		is_metal = target.is_in_group("boss") or float(target.get("_armor")) > 0.15
	play_hit_feedback_flagged(
		scene, position, normal, is_enemy, amount, headshot, killed,
		impact_scale, marker, is_metal, target
	)


## 同上，但"打中的是不是敌人"直接给出。
##
## 需要这个入口是因为【霰弹/穿透等多个命中点】：一次开火的多个命中点里，
## 后续命中点拿到的 collider 可能已经被击杀释放，拿不到节点。
static func play_hit_feedback_flagged(
	scene: Node,
	position: Vector3,
	normal: Vector3,
	is_enemy: bool,
	amount: float,
	headshot: bool,
	killed: bool,
	impact_scale: float = 1.0,
	marker: bool = true,
	is_metal: bool = false,
	target: Node = null
) -> void:
	if not scene:
		return
	var color: Color = CombatFX.COLOR_STONE_HIT
	if is_enemy:
		if headshot:
			color = HEADSHOT_COLOR
		elif is_metal:
			color = CombatFX.COLOR_METAL_HIT
		else:
			color = CombatFX.COLOR_FLESH_HIT

	var final_impact_scale := impact_scale * (1.2 if is_metal else 1.0)
	CombatFX.spawn_impact(scene, position, normal, color, final_impact_scale)

	if not is_enemy:
		# 打地形/世界：播放碎石崩裂音效，区分地表弹坑与垂直掩体穿透弹孔
		AudioUtil.play_at("hit_stone", position, -11.0, randf_range(0.95, 1.05))
		var is_heavy := amount >= 100.0 or impact_scale > 1.2
		if normal.dot(Vector3.UP) >= 0.35:
			CombatFX.spawn_ground_crater(scene, position, normal, is_heavy)
		else:
			CombatFX.spawn_bullet_hole(scene, position, normal, is_heavy)
		return

	# 敌人受击材质分化：区分重甲/Boss (金属跳弹) 与 普通生物/无护甲 (沉闷肉身冲击)
	if is_metal:
		AudioUtil.play_at("hit_metal", position, -6.5, randf_range(0.96, 1.05))
	else:
		AudioUtil.play_at("hit_flesh", position, -6.5, randf_range(0.96, 1.05))

	if headshot:
		AudioUtil.play_at("headshot", position, -6.0)
	if killed:
		AudioUtil.play_at("kill", position, -5.0)

	# 暴击 / 爆头 / 狙击贯通局部顿帧（Hitstop）
	var hitstop_node: Node = target if is_instance_valid(target) else scene
	if headshot:
		CombatFX.hitstop(hitstop_node, 0.038)
	elif amount >= 150.0:
		CombatFX.hitstop(hitstop_node, 0.028)
	var emphasis := 1.75 if headshot else clampf(impact_scale * 1.2, 0.7, 2.0)
	CombatFX.spawn_damage_number(scene, position + Vector3.UP * 0.32, amount, color, emphasis)
	# 准星命中标记属于屏幕 UI：由 PlayerHUD 订阅
	if marker:
		EventBusUtil.emit_hit_confirmed(headshot, killed)
