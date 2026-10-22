extends Node
## 敌人生成与构造（单机）。
##
## ── 为什么把"构造敌人"整段放在这里 ────────────────────────────────
##
## 敌人的外观、血量、速度、伤害都由图鉴条目（enemy_roster）推导，统一在这一处
## 构造，wave_director 只管"什么时候、在哪、出什么"。改数值规则只动这里。

const ConfigUtil := preload("res://scripts/game_config.gd")
const GaitUtil := preload("res://scripts/enemy_gait.gd")
const BallisticsUtil := preload("res://scripts/ballistics.gd")
const BossUtil := preload("res://scripts/boss.gd")
const EnemyTuningUtil := preload("res://scripts/prototypes/enemy_tuning.gd")
const CreatureCatalog := preload("res://scripts/enemies/creature_catalog.gd")
const CreatureLifecycle := preload("res://scripts/enemies/enemy_lifecycle.gd")

const RANGED_ENEMY_SCENE: PackedScene = preload("res://scenes/ranged_enemy.tscn")
const MELEE_ENEMY_SCENE: PackedScene = preload("res://scenes/melee_enemy.tscn")
const SEDIMENT_TITAN_SCENE: PackedScene = preload("res://prototypes/enemy_prototypes/procedural_sediment_titan.tscn")

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
	if node == null:
		return null
	# 生成目标是父节点（Enemies 容器）。它与本节点同在场景原点，
	# 所以下面的局部坐标就等于世界坐标。
	get_parent().add_child(node)
	if bool(node.get_meta(&"formal_boss", false)):
		# 出土期间也有明确目标，保证提前受伤/击杀归属，不依赖首次AI选招才绑定。
		node.set("target", preload("res://scripts/targeting.gd").nearest_player(node))
	if bool(node.get_meta(&"formal_enemy", false)):
		_place_creature(node, position)
	return node


## 选点与实例化共用解析结果，避免落点按小体型检查、进树后又放大。
func prepare_entry(entry: Dictionary) -> Dictionary:
	var source := entry.duplicate(true)
	if source.has("species"):
		var profile := String(CreatureCatalog.SPECIES.get(String(source.species), {}).get("profile", ""))
		var preset := _workspace_preset(profile)
		if not preset.is_empty(): source.preset = preset
	return CreatureCatalog.prepare(source) if source.has("species") else source

func _workspace_preset(profile: String) -> String:
	var scene: Node = self
	while scene != null and scene.scene_file_path != "res://scenes/sanctum_main.tscn": scene = scene.get_parent()
	if scene == null or scene.scene_file_path != "res://scenes/sanctum_main.tscn": return ""
	return load("res://scripts/testing/tuning_session.gd").shared().scene_preset(scene.scene_file_path, profile)


func _place_creature(body: CharacterBody3D, ground: Vector3) -> void:
	var entry: Dictionary = body.get_meta(&"enemy_entry")
	body.target = preload("res://scripts/targeting.gd").nearest_player(body)
	var dimensions: Vector3 = body.get_script().get_body_dimensions(entry.tuning)
	var height := dimensions.y * body.scale.y * 0.5 + 0.15
	if body.has_method("get_spawn_height"):
		# 空中单位仍需合法地面投放区，但出生高度使用其自身飞行参数。
		height = maxf(height, float(body.get_spawn_height(0.0)))
	body.global_position = ground + Vector3.UP * height
	var lifecycle := CreatureLifecycle.new()
	lifecycle.name = "EnemyLifecycle"
	lifecycle.spawn_position = body.global_position
	lifecycle.settings = entry.get("lifecycle", {}).duplicate(true)
	body.add_child(lifecycle)


## 【必须延后配置数值与外观】
##
## configure() / configure_stats() 会访问 @onready 拿到的子节点（灯、模型、骨架），
## 而这里返回时节点刚入树、_ready() 可能还没跑完、@onready 尚为 null。直接配会报
## "Invalid assignment of property ... on a base object of type 'Nil'"。
## 用 call_deferred 把配置推到本帧稍后（那时节点已完全就绪）再执行。
func _build_enemy(info: Dictionary, position: Vector3) -> Node:
	var entry: Dictionary = info.get("entry", {})
	if entry.has("species"):
		# 已投放的对象不变；明确场景选用只影响之后生成的实例。
		if not _workspace_preset(String(CreatureCatalog.SPECIES.get(String(entry.species), {}).get("profile", ""))).is_empty():
			entry = prepare_entry(entry)
		var creature := CreatureCatalog.instantiate(entry)
		if creature != null:
			creature.position = position + Vector3.UP * _stand_clearance
		return creature
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
	# 形体剖面：按图鉴条目把共用骨架改成该兵种的剪影（见 enemy_profile.gd）。
	# 必须晚于上面的 configure —— 剖面新增的部件要参与染色与受击闪白。
	if enemy.has_method("apply_body_profile"):
		enemy.call("apply_body_profile", String(entry.get("profile", "")))

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
	enemy.call("configure_gait", GaitUtil.resolve(entry))
	# 体型在延后配置时才确定；出生抬升必须覆盖放大后的胶囊半高。
	var collision := enemy.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var clearance := _stand_clearance
	if collision and collision.shape is CapsuleShape3D:
		clearance = maxf(clearance, collision.shape.height * 0.5 * enemy.scale.y + 0.15)
	enemy.global_position = (info.get("position", Vector3.ZERO) as Vector3) + Vector3.UP * clearance


## 合并重量属性：默认 → 步态的转向/起停 → 兵种显式 attrs。
## 步态不会覆盖护甲、击退抗性等战斗重量属性。
func _resolve_attrs(entry: Dictionary) -> Dictionary:
	# 必须 duplicate：get_dictionary 返回的是配置内部字典的【引用】，
	# 直接写入会把这条覆盖污染到全局，之后所有敌人都跟着变。
	var attrs := ConfigUtil.get_dictionary("enemy_roster.attrs_default").duplicate(true)
	var gait := GaitUtil.resolve(entry)
	for field in GaitUtil.MOTION_FIELDS:
		if gait.has(field):
			attrs[field] = gait[field]
	var overrides: Variant = entry.get("attrs", null)
	if overrides is Dictionary:
		for key in (overrides as Dictionary):
			attrs[key] = (overrides as Dictionary)[key]
	return attrs


func _build_boss(info: Dictionary) -> Node:
	var boss_id := String(info.get("boss_id", ""))
	if boss_id == "sediment_titan":
		var titan := SEDIMENT_TITAN_SCENE.instantiate() as Node3D
		var cfg := ConfigUtil.get_dictionary("bosses.%s" % boss_id)
		var preset := String(cfg.get("preset", "项目默认"))
		var test_preset := _workspace_preset("PrototypeSedimentTitan")
		if not test_preset.is_empty(): preset = test_preset
		var values := EnemyTuningUtil.preset_values("PrototypeSedimentTitan", preset)
		# 元数据必须在 add_child 之前写入；泰坦 _ready 会据此读取固定 Boss
		# 方案，关闭随机个体差异，并切换到正式 Boss 血条契约。
		titan.set_meta(&"enemy_tuning", values)
		titan.set_meta("workspace_source_preset", preset)
		titan.set_meta(&"crowd_uniform", true)
		titan.set_meta(&"formal_boss", true)
		titan.set_meta(&"formal_boss_id", boss_id)
		titan.set_meta(&"formal_boss_title", String(cfg.get("label", "沉积泰坦")))
		_apply_boss_config.call_deferred(titan, info)
		return titan
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
	if boss.has_method("configure"):
		boss.call("configure", boss_id, label)
	# 站立高度 = 胶囊半高 × 体型，而体型是 configure 读出来的，所以摆位必须在它之后。
	var stand_height := float(boss.call("get_stand_height")) if boss.has_method("get_stand_height") else _stand_clearance
	boss.position = position + Vector3.UP * stand_height


# ---------------------------------------------------------------- 数值

## 远程血量走档位表（"狙击几发打死"的契约），绝不叠加等级成长 ——
## 否则档位会随等级漂移。近战则是基准 × 等级成长。
##
## 【为什么近战血量要多一个复利项】`health_growth_per_level` 是**线性**的，而玩家
## 输出随等级是**近似指数**的（等级曲线 + 模块乘区，实测到 L13 约 19 倍）。
## 两者相除，击杀耗时 TTK 会一路塌下去：L1 约 1 秒 → L13 约 0.4 秒。
## 于是敌人**在跑到玩家面前之前就死了**（投放距离 14~32 米，接近要 2~4 秒），
## 表现就是"怪很多但没压力、近战像木桩"。加再多数量也只是把队列拉长。
##
## `health_growth_compound` 用复利把 TTK 拉平到 1~1.4 秒：默认改 1.0 即恢复纯线性。
## 只作用于近战；远程仍走档位表，避免破坏"狙击几发打死"的契约。
func _health_for(entry: Dictionary, kind: String, level: float) -> float:
	var tier := int(entry.get("health_tier", -1))
	if kind == "ranged":
		return BallisticsUtil.ranged_health(maxi(tier, 0), int(level))
	var base := float(entry.get("health", 100.0))
	if base < 0.0:
		base = 100.0
	var linear := 1.0 + level * ConfigUtil.get_float("enemy_roster.health_growth_per_level", 0.35)
	var compound := pow(
		maxf(ConfigUtil.get_float("enemy_roster.health_growth_compound", 1.0), 0.5),
		maxf(level - 1.0, 0.0)
	)
	return base * linear * compound


func _color(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var parts := value as Array
		return Color(float(parts[0]), float(parts[1]), float(parts[2]), 1.0)
	return fallback
