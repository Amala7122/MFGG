extends Node3D

const RANGED_ENEMY_SCENE: PackedScene = preload("res://scenes/ranged_enemy.tscn")
const MELEE_ENEMY_SCENE: PackedScene = preload("res://scenes/melee_enemy.tscn")
const BallisticsUtil := preload("res://scripts/ballistics.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

## 以下三项是【可选的逐节点覆盖】。< 0 表示使用 data/game_config.json 的全局值。
## 保留它们是为了能单独调某一个导演节点；平时保持 -1，数值只在配置文件里维护一份。
##
## 瞬发命中后玩家有效 DPS 大幅提升，难度必须靠"数量 + 压迫"而不是单纯堆血量。
@export var extra_enemies_per_level: int = -1
@export var extra_enemies_per_survival_stage: int = -1
@export var ranged_ratio: float = -1.0

var spawn_timer: float
var random := RandomNumberGenerator.new()
const TargetingUtil := preload("res://scripts/targeting.gd")
const TerrainUtil := preload("res://scripts/terrain_field.gd")
const ArenaUtil := preload("res://scripts/arena.gd")

## 缓存的玩家引用。同一场景内不会换人，所以查一次就够，
## 不必每帧 get_first_node_in_group("player")。
var _player: Node3D
## 当前武器等级，由 EventBus.weapon_level_changed 推送。
## 初值 1 与武器开局等级一致，"本局没收到过事件"就等于 1 级。
var _weapon_level: int = 1

## 场上"动态刷出"的敌人数。
##
## 这个数每帧都要用来判断是否已经刷满，但原先是
## `get_tree().get_nodes_in_group("dynamic_enemies").size()` ——
## 那是一次【全场景节点遍历 + 一次数组分配 + 一次 size()】，只读一个每次
## 只会 ±1 变化的整数。动态敌人全部由本节点 spawn_dynamic_enemy 产出，
## 所以直接自己记账：生成 +1，tree_exited -1，查询变成 O(1)。
var _dynamic_count := 0

## 配置的两个子表，在 _ready() 里读一次。刷怪是低频操作（约 1.5 秒一次），
## 但节拍参数在 _process 里每帧要用，所以统一缓存，避免点号查找进热路径。
var _enemy_cfg: Dictionary = {}
var _spawn_cfg: Dictionary = {}


func _enemy_float(key: String, fallback: float) -> float:
	var value: Variant = _enemy_cfg.get(key, null)
	return float(value) if (value is float or value is int) else fallback


func _spawn_float(key: String, fallback: float) -> float:
	var value: Variant = _spawn_cfg.get(key, null)
	return float(value) if (value is float or value is int) else fallback


func _spawn_int(key: String, fallback: int) -> int:
	var value: Variant = _spawn_cfg.get(key, null)
	return int(value) if (value is float or value is int) else fallback


func _enemy_array(key: String, fallback: Array) -> Array:
	var value: Variant = _enemy_cfg.get(key, null)
	return value as Array if value is Array and not (value as Array).is_empty() else fallback


func _title_at(titles: Array, index: int, fallback: String) -> String:
	if index < 0 or index >= titles.size():
		return fallback
	return String(titles[index])


## 取数组指定下标并转成 float。配置里的档位表若被改短，这里也不会越界崩溃。
func _at(values: Array, index: int, fallback: float) -> float:
	if index < 0 or index >= values.size():
		return fallback
	var value: Variant = values[index]
	return float(value) if (value is float or value is int) else fallback


func _ready() -> void:
	random.randomize()
	spawn_timer = 1.0
	_spawn_cfg = ConfigUtil.get_dictionary("spawn")
	# waves 模式下出怪交给 wave_director，本节点保持休眠 ——
	# 两条路径同时运行会把波次节奏冲垮（波次在数剩余人数，无尽还在往里塞人）。
	# 把 spawn.mode 改回 "endless" 即完整恢复改动前的纯无尽行为。
	if String(_spawn_cfg.get("mode", "waves")) != "endless":
		set_process(false)
		return
	EventBusUtil.subscribe_weapon_level_changed(_on_weapon_level_changed)
	_enemy_cfg = ConfigUtil.get_dictionary("enemy")
	# 把"未覆盖"的哨兵值回填成配置值。
	if extra_enemies_per_level < 0:
		extra_enemies_per_level = _spawn_int("extra_enemies_per_level", 7)
	if extra_enemies_per_survival_stage < 0:
		extra_enemies_per_survival_stage = _spawn_int("extra_enemies_per_survival_stage", 4)
	if ranged_ratio < 0.0:
		ranged_ratio = _spawn_float("ranged_ratio", 0.44)


func _on_weapon_level_changed(level: int) -> void:
	_weapon_level = level


func _player_ref() -> Node3D:
	if not is_instance_valid(_player):
		_player = TargetingUtil.nearest_player(self) as Node3D
	return _player


func _process(delta: float) -> void:
	var player := _player_ref()
	if not is_instance_valid(player):
		return
	var weapon_level := _weapon_level
	var survival_seconds: float = player.call("get_survival_time")
	var survival_stage := floori(survival_seconds / _spawn_float("stage_seconds", 45.0))
	var threat_offset := _spawn_int("threat_level_offset", 4)
	var level_extra := maxi(weapon_level - threat_offset, 0) * extra_enemies_per_level
	var time_extra := survival_stage * extra_enemies_per_survival_stage
	var desired_extra := maxi(level_extra, time_extra)
	if _dynamic_count >= desired_extra:
		return
	spawn_timer -= delta
	if spawn_timer > 0.0:
		return
	var threat_level := maxi(weapon_level, threat_offset + survival_stage)
	spawn_dynamic_enemy(player, threat_level, survival_stage)
	spawn_timer = maxf(
		_spawn_float("interval_min", 0.26),
		_spawn_float("interval_base", 1.45)
			- float(threat_level - threat_offset) * _spawn_float("interval_per_threat", 0.09)
	)


## 动态敌人离场（死亡 / 切图）时减账。
func _on_dynamic_enemy_removed() -> void:
	_dynamic_count = maxi(_dynamic_count - 1, 0)


func spawn_dynamic_enemy(player: Node3D, weapon_level: int, survival_stage: int = 0) -> void:
	var is_ranged := random.randf() < ranged_ratio
	var enemy_scene := RANGED_ENEMY_SCENE if is_ranged else MELEE_ENEMY_SCENE
	var enemy := enemy_scene.instantiate() as Node3D
	get_tree().current_scene.add_child(enemy)
	enemy.add_to_group("dynamic_enemies")
	# 记账（见 _dynamic_count 的注释）。ONE_SHOT：节点只会离场一次，
	# 信号本身也会随节点一起释放。
	_dynamic_count += 1
	enemy.tree_exited.connect(_on_dynamic_enemy_removed, CONNECT_ONE_SHOT)
	enemy.global_position = choose_spawn_position(player)
	var roll := random.randf()
	# 大体型占比同时随武器等级与生存时间上升，后期不再是"一群杂兵"。
	var big_weight := minf(
		_enemy_float("big_weight_base", 0.08)
			+ float(weapon_level) * _enemy_float("big_weight_per_level", 0.014)
			+ float(survival_stage) * _enemy_float("big_weight_per_stage", 0.035),
		_enemy_float("big_weight_max", 0.42)
	)
	var size_class: int
	if roll < big_weight:
		size_class = 3
	elif roll < _enemy_float("roll_threshold_heavy", 0.34):
		size_class = 2
	elif roll < _enemy_float("roll_threshold_light", 0.64):
		size_class = 1
	else:
		size_class = 0
	var scale_values := _enemy_array("size_scale", [0.7, 1.0, 1.35, 1.72])
	var health_values := _enemy_array("size_health", [62.0, 128.0, 295.0, 610.0])
	# 速度必须压过玩家步行速度（5.0），否则近战永远追不上人；
	# 但乘以上限后仍低于冲刺速度（8.5），保留"跑得掉"的余地。
	var speed_values := _enemy_array("size_speed", [7.0, 5.9, 4.3, 3.1])
	var damage_values := _enemy_array("size_damage", [13.0, 21.0, 32.0, 44.0])
	var level_growth := 1.0 + float(maxi(weapon_level - 4, 0)) * _enemy_float("health_growth_per_level", 0.3)
	var enemy_scale := _at(scale_values, size_class, 0.7)
	# 远程敌人的血量由"狙击几发打死"的档位决定（与狙击伤害同步成长）；
	# 近战敌人继续按等级膨胀 —— 分工明确：狙击吃远程，冲锋枪吃近战。
	var enemy_health := _at(health_values, size_class, 62.0) * level_growth
	if is_ranged:
		enemy_health = BallisticsUtil.ranged_health(size_class, weapon_level)
	var enemy_speed := _at(speed_values, size_class, 7.0) * minf(
		1.0 + float(weapon_level) * _enemy_float("speed_growth_per_level", 0.02),
		_enemy_float("speed_growth_max", 1.12)
	)
	var enemy_damage := _at(damage_values, size_class, 13.0) * (
		1.0 + float(weapon_level - 4) * _enemy_float("damage_growth_per_level", 0.07)
	)
	var armor_color := Color.from_hsv(random.randf(), 0.72, 0.72, 1.0)
	if is_ranged:
		var pattern := random.randi_range(0, 4)
		var movement := random.randi_range(0, 2)
		var pattern_titles := _enemy_array("ranged_pattern_titles",
			["无尽散射兵", "无尽点射兵", "无尽旋流兵", "无尽弹墙兵", "无尽迫击炮"])
		var bullet_color := Color.from_hsv(random.randf(), 0.9, 1.0, 1.0)
		enemy.call(
			"configure",
			pattern,
			movement,
			_title_at(pattern_titles, pattern, "无尽射手"),
			armor_color,
			bullet_color,
			_enemy_float("ranged_distance_base", 15.0)
				+ enemy_scale * _enemy_float("ranged_distance_per_scale", 3.0)
		)
	else:
		var melee_titles := _enemy_array("melee_titles",
			["无尽猎手", "无尽战士", "无尽重卫", "无尽巨兽"])
		enemy.call("configure_melee_variant",
			_title_at(melee_titles, size_class, "无尽猎手"), armor_color)
	# 【必须对两种敌人都下发】原先这行只在近战分支里，导致动态刷出的远程敌人
	# 拿不到体型缩放，也拿不到上面按档位算出的血量 —— 于是"狙击几发打死"这个
	# 契约只对 15 个固定刷怪点成立，与固定点行为不一致。
	enemy.call("configure_stats", enemy_scale, enemy_health, enemy_speed, enemy_damage)


func choose_spawn_position(player: Node3D) -> Vector3:
	var attempts := maxi(_spawn_int("attempts", 24), 1)
	# 【世界边界与保留区改由竞技场提供】
	# 原先边界读 spawn.world_bound（写死的 48，而 citadel=46 / dunes=68），
	# 保留区读 spawn.lake_exclusion（一个只属于湖畔的矩形）。两者都是"某一
	# 张图的坐标被当成了全局常量"。现在统一走 terrain 的范围与 arena 的遮罩 ——
	# 于是无限模式在任何一张图上都成立，新增地图时也不会突然少刷一块地。
	var bound := TerrainUtil.get_extent()
	# 【必须在循环外取一次】—— ArenaUtil.get_params() 内部会 resolve_id()
	# 并对整张竞技场表做 duplicate(true)（深拷贝），不是一次字典查表；
	# 原先它写在循环里，一次选点最多白跑 24 遍深拷贝。
	var arena := ArenaUtil.get_params()
	for attempt in range(attempts):
		var angle := random.randf_range(0.0, TAU)
		var radius := random.randf_range(
			_spawn_float("radius_min", 15.0), _spawn_float("radius_max", 34.0)
		)
		var candidate := player.global_position + Vector3(sin(angle) * radius, 0.0, cos(angle) * radius)
		if absf(candidate.x) > bound or absf(candidate.z) > bound:
			continue
		# 水面 / 主路 / 遗迹 / 营地等保留区不刷地面敌人。
		if ArenaUtil.is_masked_out(arena, candidate.x, candidate.z):
			continue
		var query := PhysicsRayQueryParameters3D.create(
			candidate + Vector3.UP * 16.0,
			candidate + Vector3.DOWN * 8.0,
			1
		)
		var ground_hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not ground_hit.is_empty():
			return ground_hit.position + Vector3.UP
	return player.global_position + Vector3(0, 1, -22)
