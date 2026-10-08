extends Node3D

## 档位常量集中在 Ballistics，避免"狙击伤害"与"远程血量"各写一份而漂移。
const BallisticsUtil := preload("res://scripts/ballistics.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const TargetingUtil := preload("res://scripts/targeting.gd")
const TerrainUtil := preload("res://scripts/terrain_field.gd")
const ArenaUtil := preload("res://scripts/arena.gd")

@export var enemy_scene: PackedScene
@export var respawn_delay: float = 5.0
@export var random_spawn_radius: float = 13.0
@export var minimum_player_distance: float = 10.0
@export_category("Progression")
@export_range(1, 4) var required_weapon_level: int = 1
@export var activation_delay_max: float = 2.2
## 武器等级每高一级，重生等待缩短该比例，形成持续压力（上限缩短 60%）。
@export var respawn_speedup_per_level: float = 0.16
@export_category("Enemy stats")
@export var enemy_scale: float = 1.0
@export var enemy_health: float = -1.0
@export var enemy_move_speed: float = -1.0
@export var enemy_damage: float = -1.0
@export_category("Enemy stat growth（随武器等级）")
## 刷新点数量有限（15 个），若数值固定，玩家一升级它们就沦为背景。
## 这里让 15 个固定点跟动态刷怪一起成长：
##   血量 ×(1 + level × 0.22) → Lv1 已 +22%，Lv8 约 +276%
##   伤害 ×(1 + level × 0.14)
##   速度 ×(1 + level × 0.05)，但封顶 max_speed_growth —— 必须永远跑不过玩家冲刺。
@export var health_growth_per_level: float = 0.22
@export var damage_growth_per_level: float = 0.14
@export var speed_growth_per_level: float = 0.05
@export var max_speed_growth: float = 1.25
@export_category("Ranged enemy variant")
@export var ranged_pattern: int = -1
@export var movement_style: int
@export var enemy_title: String
@export var armor_color: Color = Color(0.58, 0.08, 0.12, 1.0)
@export var bullet_color: Color = Color(1.0, 0.04, 0.24, 1.0)
@export var preferred_distance: float = 14.0
## 远程敌人血量档位（0..3 = 狙击躯干 1/2/3/5 发打死，爆头 1/1/1/2 发）。
## >= 0 时覆盖上面的 enemy_health —— 让"几发死"成为远程敌人的强度契约。
@export_range(-1, 3) var ranged_health_tier: int = -1

var active_enemy: Node3D
var respawn_timer: float
var has_spawned: bool
var spawn_origin: Vector3
var random := RandomNumberGenerator.new()
var unlocked: bool
## 当前武器等级，由 EventBus.weapon_level_changed 推送，供成长系数与重生加速使用。
##
## 初值 1 与武器开局等级（player_weapon._weapon_level 初值）一致，因此
## "本局还没收到过任何事件"就等于 1 级，不需要额外去查询玩家。
var _weapon_level: int = 1


func _ready() -> void:
	spawn_origin = global_position
	random.randomize()
	# waves 模式下这 15 个固定刷怪点不生成敌人：它们的坐标只对湖畔遗址有意义，
	# 而波次系统用的是竞技场自己的刷怪锚点（四张图各不相同）。
	#
	# 但它们并没有被废弃 —— 节点上的 @export 数值是【敌人图鉴的原始出处】，
	# 已经逐值迁进 game_config.json 的 enemy_roster.entries。
	# 把 spawn.mode 改回 "endless" 即恢复原状。
	if String(ConfigUtil.get_string("spawn.mode", "waves")) != "endless":
		set_process(false)
		return
	# 替代原先每帧 get_first_node_in_group("player") + call("get_weapon_level")。
	EventBusUtil.subscribe_weapon_level_changed(_on_weapon_level_changed)


func _on_weapon_level_changed(level: int) -> void:
	_weapon_level = level


func _process(delta: float) -> void:
	if _weapon_level < required_weapon_level:
		return
	if not unlocked:
		unlocked = true
		respawn_timer = random.randf_range(0.35, activation_delay_max)
		return
	if is_instance_valid(active_enemy):
		return
	respawn_timer = maxf(respawn_timer - delta, 0.0)
	if respawn_timer <= 0.0:
		spawn_enemy()


func spawn_enemy() -> void:
	if not enemy_scene:
		return
	active_enemy = enemy_scene.instantiate() as Node3D
	get_tree().current_scene.add_child(active_enemy)
	active_enemy.global_transform = choose_random_spawn_transform()
	if ranged_pattern >= 0 and active_enemy.has_method("configure"):
		active_enemy.call(
			"configure",
			ranged_pattern,
			movement_style,
			enemy_title,
			armor_color,
			bullet_color,
			preferred_distance
		)
	elif active_enemy.has_method("configure_melee_variant"):
		active_enemy.call("configure_melee_variant", enemy_title, armor_color)
	if active_enemy.has_method("configure_stats"):
		var level := float(_weapon_level)
		active_enemy.call(
			"configure_stats",
			enemy_scale,
			get_effective_health(),
			enemy_move_speed * minf(1.0 + level * speed_growth_per_level, max_speed_growth),
			enemy_damage * (1.0 + level * damage_growth_per_level)
		)
	active_enemy.tree_exited.connect(on_enemy_removed, CONNECT_ONE_SHOT)
	has_spawned = true
	respawn_timer = get_effective_respawn_delay()


func on_enemy_removed() -> void:
	active_enemy = null
	respawn_timer = get_effective_respawn_delay()


## 等级越高重生越快；下限 1.5 秒，避免刚死就贴脸刷回来。
func get_effective_respawn_delay() -> float:
	var speedup := 1.0 - minf(float(_weapon_level - 1) * respawn_speedup_per_level, 0.6)
	return maxf(respawn_delay * speedup, 1.5)


## 远程点血量 = 狙击档位（与狙击伤害同步成长）；
## 近战点血量按武器等级膨胀。
##
## 远程点绝不能走 health_growth_per_level：那会让"狙击几发打死"随等级漂移，
## 档位表当场失效（这正是之前用比例伤害时埋下的问题）。
func get_effective_health() -> float:
	if ranged_health_tier >= 0:
		return BallisticsUtil.ranged_health(ranged_health_tier, _weapon_level)
	return enemy_health * (1.0 + float(_weapon_level) * health_growth_per_level)


func choose_random_spawn_transform() -> Transform3D:
	var player := TargetingUtil.nearest_player(self) as Node3D
	# 【下面两个都必须在循环外取一次】—— 原先 bound 与 get_params() 都写在
	# 循环体里，一次选点最多各跑 16 遍，而 get_params() 内部还要对整张竞技场
	# 表做一次 duplicate(true)（深拷贝）。
	var bound := TerrainUtil.get_extent()
	var arena := ArenaUtil.get_params()
	for attempt in range(16):
		var angle := random.randf_range(0.0, TAU)
		var distance := random.randf_range(random_spawn_radius * 0.35, random_spawn_radius)
		var candidate := spawn_origin + Vector3(sin(angle) * distance, 0.0, cos(angle) * distance)
		# 【世界边界与保留区都改由竞技场提供】
		# 原先这里写死了 48.0（湖畔坐标概念，而 citadel extent=46、dunes=68，
		# 两者都不等于 48），以及湖盒的四个数字直接嵌在 if 里 ——
		# 换一张没有湖的图，它会静默屏蔽一块本该刷怪的合法地面。
		# 保留区的判据现在复用 arena 的遮罩，于是"哪块地不放东西"只有一处定义。
		if absf(candidate.x) > bound or absf(candidate.z) > bound:
			continue
		if ArenaUtil.is_masked_out(arena, candidate.x, candidate.z):
			continue
		if is_instance_valid(player) and candidate.distance_to(player.global_position) < minimum_player_distance:
			continue
		var query := PhysicsRayQueryParameters3D.create(
			candidate + Vector3.UP * 16.0,
			candidate + Vector3.DOWN * 8.0,
			1
		)
		var ground_hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not ground_hit.is_empty():
			candidate.y = ground_hit.position.y + 1.0
			return Transform3D(global_basis, candidate)
	return Transform3D(global_basis, spawn_origin)
