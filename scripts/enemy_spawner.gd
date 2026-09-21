extends Node
## 敌人生成与构造（单机）。
##
## ── 为什么把"构造敌人"整段放在这里 ────────────────────────────────
##
## 敌人的外观、血量、速度、伤害都由图鉴条目（enemy_roster）推导，统一在这一处
## 构造，wave_director 只管"什么时候、在哪、出什么"。改数值规则只动这里。

const ConfigUtil := preload("res://scripts/game_config.gd")
const BallisticsUtil := preload("res://scripts/ballistics.gd")
const BossUtil := preload("res://scripts/boss.gd")

const RANGED_ENEMY_SCENE: PackedScene = preload("res://scenes/ranged_enemy.tscn")
const MELEE_ENEMY_SCENE: PackedScene = preload("res://scenes/melee_enemy.tscn")

## 敌人摆位时抬离地面的高度（配置缺失时的兜底，实际从
## spawn.enemy_stand_clearance 读）。
##
## 敌人场景的碰撞胶囊以【根节点为圆心】、高 2.0 米（原点在胶囊正中，不是脚底），
## 所以根节点要放在地形高度 +1.0 才让胶囊下沿刚好贴地。
##
## 取 1.2 而不是 1.0：**偏高是安全的（落一点点），偏低是致命的** ——
## 胶囊一旦压进地形，就会穿透凹面碰撞体然后无限下坠。实测把这里写成 +0.15 时，
## 敌人全部掉到 y = -78 去了：它们确实被创建了、没报任何错，只是永远在掉。
const DEFAULT_STAND_CLEARANCE := 1.2


## 摆位时抬离地面的高度。从配置读，兜底见 DEFAULT_STAND_CLEARANCE 的说明。
var _stand_clearance := DEFAULT_STAND_CLEARANCE


func _ready() -> void:
	_stand_clearance = maxf(
		ConfigUtil.get_float("spawn.enemy_stand_clearance", DEFAULT_STAND_CLEARANCE), 0.5
	)


## 按图鉴条目生成一个敌人。
func spawn_enemy(entry: Dictionary, position: Vector3, level: float) -> Node3D:
	return _build({
		"kind": String(entry.get("kind", "melee")),
		"entry": entry,
		"position": position,
		"level": level,
	}, position) as Node3D


## Boss 与小兵走同一个入口，构造路径一致。
func spawn_boss(boss_id: String, position: Vector3) -> Node3D:
	return _build({
		"kind": "boss",
		"boss_id": boss_id,
		"entry": {},
		"position": position,
		"level": 0.0,
	}, position) as Node3D


# ---------------------------------------------------------------- 构造

func _build(info: Dictionary, position: Vector3) -> Node:
	var node: Node
	if String(info.get("kind", "")) == "boss":
		node = _build_boss(info)
	else:
		node = _build_enemy(info, position)
	# 生成目标是父节点（Enemies 容器）。它与本节点同在场景原点，
	# 所以下面的局部坐标就等于世界坐标。
	get_parent().add_child(node)
	return node


## 【必须延后配置数值与外观】
##
## configure() / configure_stats() 会访问 @onready 拿到的子节点（灯、模型、骨架），
## 而这里返回时节点刚入树、_ready() 可能还没跑完、@onready 尚为 null。直接配会报
## "Invalid assignment of property ... on a base object of type 'Nil'"。
## 用 call_deferred 把配置推到本帧稍后（那时节点已完全就绪）再执行。
func _build_enemy(info: Dictionary, position: Vector3) -> Node:
	var kind := String(info.get("kind", "melee"))
	var scene := RANGED_ENEMY_SCENE if kind == "ranged" else MELEE_ENEMY_SCENE
	var enemy := scene.instantiate() as Node3D
	enemy.position = position + Vector3.UP * _stand_clearance
	_apply_enemy_config.call_deferred(enemy, info)
	return enemy


func _apply_enemy_config(enemy: Node3D, info: Dictionary) -> void:
	if not is_instance_valid(enemy):
		return
	var entry := info.get("entry", {}) as Dictionary
	var kind := String(info.get("kind", "melee"))
	var level := float(info.get("level", 1.0))

	var armor := _color(entry.get("armor_color", null), Color(0.6, 0.2, 0.2, 1.0))
	if kind == "ranged":
		var bullet := _color(entry.get("bullet_color", null), Color(1.0, 0.2, 0.2, 1.0))
		enemy.call(
			"configure",
			int(entry.get("ranged_pattern", 0)),
			int(entry.get("movement_style", 0)),
			String(entry.get("title", "射手")),
			armor,
			bullet,
			float(entry.get("preferred_distance", 15.0))
		)
	else:
		enemy.call("configure_melee_variant", String(entry.get("title", "战士")), armor)

	var health := _health_for(entry, kind, level)
	var speed := float(entry.get("move_speed", 5.0)) * minf(
		1.0 + level * ConfigUtil.get_float("enemy_roster.speed_growth_per_level", 0.05),
		ConfigUtil.get_float("enemy_roster.max_speed_growth", 1.25)
	)
	var damage := float(entry.get("damage", 10.0)) * (
		1.0 + level * ConfigUtil.get_float("enemy_roster.damage_growth_per_level", 0.14)
	)
	# 重量属性（阶段 2）：默认表 + 本条覆盖。
	enemy.call(
		"configure_stats", float(entry.get("scale", 1.0)), health, speed, damage,
		_resolve_attrs(entry)
	)


## 合并『重量』属性：先取 enemy_roster.attrs_default（全部等于旧行为），
## 再用本条 entry 的 attrs 覆盖。逐条启用时只有被覆盖的那几项会改变行为。
func _resolve_attrs(entry: Dictionary) -> Dictionary:
	# 必须 duplicate：get_dictionary 返回的是配置内部字典的【引用】，
	# 直接写入会把这条覆盖污染到全局，之后所有敌人都跟着变。
	var attrs := ConfigUtil.get_dictionary("enemy_roster.attrs_default").duplicate(true)
	var overrides: Variant = entry.get("attrs", null)
	if overrides is Dictionary:
		for key in (overrides as Dictionary):
			attrs[key] = (overrides as Dictionary)[key]
	return attrs


func _build_boss(info: Dictionary) -> Node:
	var boss := CharacterBody3D.new()
	boss.set_script(BossUtil)
	_apply_boss_config.call_deferred(boss, info)
	return boss


func _apply_boss_config(boss: Node3D, info: Dictionary) -> void:
	if not is_instance_valid(boss):
		return
	var boss_id := String(info.get("boss_id", ""))
	var position: Vector3 = info.get("position", Vector3.ZERO)
	var label := String(ConfigUtil.get_dictionary("bosses.%s" % boss_id).get("label", "BOSS"))
	boss.call("configure", boss_id, label)
	# 站立高度 = 胶囊半高 × 体型，而体型是 configure 读出来的，所以摆位必须在它之后。
	boss.position = position + Vector3.UP * float(boss.call("get_stand_height"))


# ---------------------------------------------------------------- 数值

## 远程血量走档位表（"狙击几发打死"的契约），绝不叠加等级成长 ——
## 否则档位会随等级漂移。近战则是基准 × 等级成长。
func _health_for(entry: Dictionary, kind: String, level: float) -> float:
	var tier := int(entry.get("health_tier", -1))
	if kind == "ranged":
		return BallisticsUtil.ranged_health(maxi(tier, 0), int(level))
	var base := float(entry.get("health", 100.0))
	if base < 0.0:
		base = 100.0
	return base * (1.0 + level * ConfigUtil.get_float("enemy_roster.health_growth_per_level", 0.35))


func _color(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var parts := value as Array
		return Color(float(parts[0]), float(parts[1]), float(parts[2]), 1.0)
	return fallback
