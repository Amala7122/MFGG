extends CharacterBody3D
## Boss：每个阶段（一张竞技场）一个，数据来自 game_config.json 的 bosses 段。
##
## ── 与普通敌人的差异（也是它为什么是独立脚本）──────────────────────
##
##   1. 血条走上事件总线（EventBus.boss_updated），不再靠头顶飘字 ——
##      Boss 的血量是几千点，飘字表达不了"还剩几成"。
##   2. 有弱点区，命中弱点额外乘 weak_point_multiplier。
##   3. 三种行为（冲撞 / 震地 / 弹幕），而不是"直线追人 + 定时挥击"。
##
## ── 接入契约（与 Ballistics 及两个普通敌人脚本一致）────────────────
##
##   - 必须在 "enemies" 组里，否则 Ballistics.resolve_hit 根本不会施加伤害；
##   - 必须有一个名为 CollisionShape3D 的 CapsuleShape3D —— is_headshot 靠它
##     换算爆头线（它刻意不加额外碰撞体，见其注释）；
##   - 必须实现 take_damage()；额外实现 take_damage_at() 才能按命中点判弱点。
##     Ballistics 只在目标声明了 take_damage_at 时调用它，所以普通敌人一行都不用改。
##
## ── 为什么不用 navmesh ─────────────────────────────────────────────
##
##   它体型 2.2~2.9 倍，而导航网格的 agent_radius 只有 0.9 米 —— 塞不进掩体缝隙。
##   与其让它卡在导航边缘"蹭"，不如直接朝玩家推进 + 贴合地形高度。
##   这也正是玩家能绕柱子躲开它的前提。

const ConfigUtil := preload("res://scripts/game_config.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const EventBusUtil := preload("res://scripts/event_bus.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const PoolUtil := preload("res://scripts/object_pool.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")

const ENEMY_BULLET_SCENE: PackedScene = preload("res://scenes/enemy_bullet.tscn")
const GROUND_WARNING_SCENE: PackedScene = preload("res://scenes/ground_warning.tscn")
const BULLET_POOL_KEY := "enemy_bullet"

const GROUP_ENEMIES := "enemies"
const GROUP_PLAYER := "player"
const TargetingUtil := preload("res://scripts/targeting.gd")

enum Behavior { CHARGE, SLAM, BARRAGE }
## 行为内的细分阶段：逼近 → 起手 → 出手 → 收招。
enum Step { APPROACH, WINDUP, STRIKE, RECOVER }

const BEHAVIOR_NAMES := {
	Behavior.CHARGE: "charge",
	Behavior.SLAM: "slam",
	Behavior.BARRAGE: "barrage",
}

## 胶囊半高 / 半径 / 弱点核心半径。默认值与 bosses 段的配置一致；
## configure() 里会从配置读入 —— 它们同时影响站位高度、爆头线与弱点区，
## 所以必须能调。
var _capsule_half_height := 1.15
var _capsule_radius := 0.62
var _weak_core_radius := 0.34
## 收招时长（玩家的反击窗口）与 Boss 行为间隔的兜底值。
var _recover_duration := 0.5

var _boss_id := ""
var _title := "BOSS"
var _max_health := 2600.0
var _health := 2600.0
var _move_speed := 4.6
var _touch_damage := 26.0
var _weak_ratio := 0.34
var _weak_multiplier := 2.0
var _body_scale := 2.2
var _behavior := Behavior.CHARGE
var _params: Dictionary = {}
var _contact_cooldown := 1.1

var _step := Step.APPROACH
var _step_timer := 0.0
var _action_cooldown := 2.0
var _contact_timer := 0.0
var _strike_done := false
var _dead := false

var _target: Node3D
var _visual: MeshInstance3D
var _material: StandardMaterial3D
var _warning: Node3D
var _flash := 0.0
var _random := RandomNumberGenerator.new()


# ---------------------------------------------------------------- 构建

## 由 wave_director 在生成后立刻调用。boss_id 对应 bosses 段里的键名。
func configure(boss_id: String, fallback_label: String = "BOSS") -> void:
	_boss_id = boss_id
	var cfg := ConfigUtil.get_dictionary("bosses.%s" % boss_id)
	_title = String(cfg.get("label", fallback_label))
	_max_health = maxf(float(cfg.get("health", 2600.0)), 1.0)
	_health = _max_health
	_move_speed = float(cfg.get("move_speed", 4.6))
	_touch_damage = float(cfg.get("touch_damage", 26.0))
	_weak_ratio = clampf(float(cfg.get("weak_point_ratio", 0.34)), 0.05, 0.95)
	_weak_multiplier = maxf(float(cfg.get("weak_point_multiplier", 2.0)), 1.0)
	_body_scale = maxf(float(cfg.get("scale", 2.2)), 0.5)
	_behavior = _parse_behavior(String(cfg.get("behavior", "charge")))
	_params = ConfigUtil.get_dictionary("bosses.behaviors.%s" % BEHAVIOR_NAMES[_behavior])
	_contact_cooldown = maxf(ConfigUtil.get_float("bosses.contact_damage_cooldown", 1.1), 0.1)
	_capsule_half_height = maxf(ConfigUtil.get_float("bosses.capsule_half_height", 1.15), 0.2)
	_capsule_radius = maxf(ConfigUtil.get_float("bosses.capsule_radius", 0.62), 0.05)
	_weak_core_radius = maxf(ConfigUtil.get_float("bosses.weak_core_radius", 0.34), 0.05)
	_recover_duration = maxf(ConfigUtil.get_float("bosses.recover_duration", 0.5), 0.0)
	_random.randomize()
	_build_body()
	_publish_health()
	print("[Boss] %s 登场：血量 %.0f，体型 ×%.2f，行为 %s"
		% [_title, _max_health, _body_scale, BEHAVIOR_NAMES[_behavior]])


func _build_body() -> void:
	add_to_group(GROUP_ENEMIES)
	# 根节点缩放。is_headshot 是按 global_basis 的 y 缩放换算局部高度的，
	# 所以体型必须体现在这里，而不是只缩放网格。
	scale = Vector3(_body_scale, _body_scale, _body_scale)

	var capsule := CapsuleMesh.new()
	capsule.radius = 0.62
	capsule.height = _capsule_half_height * 2.0
	capsule.radial_segments = 20
	capsule.rings = 10
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.34, 0.09, 0.4, 1.0)
	_material.roughness = 0.62
	_material.emission_enabled = true
	_material.emission = Color(0.18, 0.02, 0.24, 1.0)
	capsule.material = _material
	_visual = MeshInstance3D.new()
	_visual.name = "Visual"
	_visual.mesh = capsule
	_visual.position = Vector3(0.0, _capsule_half_height, 0.0)
	add_child(_visual)

	# 弱点标记：顶端一圈亮色，让"打哪有效"看得见而不是靠猜。
	var core := SphereMesh.new()
	core.radius = 0.34
	core.height = 0.68
	core.radial_segments = 16
	core.rings = 8
	var core_material := StandardMaterial3D.new()
	core_material.albedo_color = Color(1.0, 0.86, 0.3, 1.0)
	core_material.emission_enabled = true
	core_material.emission = Color(1.0, 0.62, 0.1, 1.0)
	core.material = core_material
	var core_mesh := MeshInstance3D.new()
	core_mesh.name = "WeakCore"
	core_mesh.mesh = core
	# 放在弱点区正中：weak_ratio 是"从顶部往下占多少比例"。
	core_mesh.position = Vector3(0.0, _capsule_half_height * 2.0 * (1.0 - _weak_ratio * 0.5), 0.0)
	add_child(core_mesh)

	var shape := CapsuleShape3D.new()
	shape.radius = 0.62
	shape.height = _capsule_half_height * 2.0
	var collision := CollisionShape3D.new()
	# 名字必须是 CollisionShape3D —— Ballistics.is_headshot 按这个名字找胶囊。
	collision.name = "CollisionShape3D"
	collision.shape = shape
	collision.position = Vector3(0.0, _capsule_half_height, 0.0)
	add_child(collision)

	# 用来识别"这是敌人"的层与掩码。第 1 层与地形/掩体一致，第 2 层留给玩家与子弹。
	collision_layer = 3
	collision_mask = 1


# ---------------------------------------------------------------- 受击

## Ballistics 在目标声明了 take_damage_at 时会走这条路径，从而支持按命中点判弱点。
func take_damage_at(amount: float, hit_position: Vector3, _headshot: bool) -> void:
	if _dead:
		return
	var weak := is_weak_point(hit_position)
	_apply_damage(amount * (_weak_multiplier if weak else 1.0), weak)


## 没有命中点信息时（如近战回击、范围伤害）退化成普通受击。
func take_damage(amount: float) -> void:
	if _dead:
		return
	_apply_damage(amount, false)


## 弱点判定与 Ballistics.is_headshot 共用同一套坐标换算（同一胶囊、同一缩放），
## 所以"弱点区"对玩家来说就是"爆头线以上"，不需要学第二套几何。
##
## 几何换算：胶囊体从脚底 y=0 长到 2×half_height，所以"顶部 weak_ratio 那一段"
## 的下沿在 2×half_height×(1-weak_ratio) 处。
##
## 注意这里踩过一次符号坑：写成 half_height×(weak_ratio×2-1) 的话，
## weak_ratio=0.34 会算出【负数】阈值，等于把整条腿都算成弱点 —— 探针的
## "底部不该被判为弱点"那条断言就是专门拦这个的。
func is_weak_point(hit_position: Vector3) -> bool:
	var half_height := _capsule_half_height
	var capsule := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if capsule and capsule.shape is CapsuleShape3D:
		half_height = (capsule.shape as CapsuleShape3D).height * 0.5
	var scale_y := maxf(global_basis.get_scale().y, 0.01)
	var local_y := (hit_position.y - global_position.y) / scale_y
	return local_y >= half_height * 2.0 * (1.0 - _weak_ratio)


func _apply_damage(amount: float, weak: bool) -> void:
	if amount <= 0.0:
		return
	_health = maxf(_health - amount, 0.0)
	_flash = 0.12
	if weak:
		_material.emission = Color(0.9, 0.5, 0.05, 1.0)
	_publish_health()
	if _health <= 0.0:
		_die()


func _die() -> void:
	if _dead:
		return
	_dead = true
	EventBusUtil.emit_boss_updated(false, _title, 0.0, _max_health)
	AudioUtil.play_at("explosion", global_position, -2.0)
	var scene := get_tree().current_scene
	if scene:
		# 死亡要"看得见"：一圈火花 + 一个飘字，避免它静悄悄地消失。
		for index in range(8):
			var angle := TAU * float(index) / 8.0
			CombatFXUtil.spawn_impact(
				scene,
				global_position + Vector3(cos(angle) * 1.4, 1.2, sin(angle) * 1.4),
				Vector3.UP,
				Color(1.0, 0.6, 0.2, 1.0),
				2.4
			)
	queue_free()


func _publish_health() -> void:
	EventBusUtil.emit_boss_updated(true, _title, _health, _max_health)


func get_title() -> String:
	return _title


func get_health() -> float:
	return _health


func get_max_health() -> float:
	return _max_health


func is_dead() -> bool:
	return _dead


# ---------------------------------------------------------------- 行为

func _physics_process(delta: float) -> void:
	if _dead:
		return
	if not is_instance_valid(_target):
		_target = TargetingUtil.nearest_player(self) as Node3D
		if not is_instance_valid(_target):
			return

	_tick_flash(delta)
	_contact_timer = maxf(_contact_timer - delta, 0.0)
	_action_cooldown = maxf(_action_cooldown - delta, 0.0)

	match _step:
		Step.APPROACH:
			_approach(delta)
			if _action_cooldown <= 0.0:
				_begin_action()
		Step.WINDUP:
			_step_timer -= delta
			_velocity_toward(Vector3.ZERO, delta)
			if _step_timer <= 0.0:
				_release_action()
		Step.STRIKE:
			_step_timer -= delta
			_tick_strike(delta)
			if _step_timer <= 0.0:
				_step = Step.RECOVER
				_step_timer = _recover_duration
		Step.RECOVER:
			_step_timer -= delta
			_velocity_toward(Vector3.ZERO, delta)
			# 收招时长 = 玩家的反击窗口（配置 bosses.recover_duration）。
			if _step_timer <= 0.0:
				_step = Step.APPROACH
				_step_timer = 0.0
				_action_cooldown = _interval_for_behavior()

	move_and_slide()
	# 撞到玩家就按冷却结算一次接触伤害。放在 move_and_slide 之后，
	# 这样拿到的是本帧真实的碰撞面。
	_resolve_contact_damage()
	_snap_to_terrain()


func _tick_flash(delta: float) -> void:
	if _flash <= 0.0:
		return
	_flash = maxf(_flash - delta, 0.0)
	if _flash <= 0.0:
		_material.emission = Color(0.18, 0.02, 0.24, 1.0)


## 逼近。弹幕型维持距离，其余两种贴上去。
func _approach(delta: float) -> void:
	var desired := (_target.global_position - global_position)
	var flat := Vector3(desired.x, 0.0, desired.z)
	var distance := flat.length()
	if _behavior == Behavior.BARRAGE:
		var standoff := float(_params.get("barrage_distance", 16.0))
		# 太近就后退，太远才前进 —— 中间留一条"原地输出"的带。
		if distance < standoff * 0.8:
			_velocity_toward(-flat.normalized(), delta, 0.75)
		elif distance > standoff * 1.15:
			_velocity_toward(flat.normalized(), delta, 0.75)
		else:
			_velocity_toward(Vector3.ZERO, delta)
		return
	if _behavior == Behavior.SLAM and distance <= float(_params.get("slam_range", 7.0)):
		_velocity_toward(Vector3.ZERO, delta)
		return
	_velocity_toward(flat.normalized(), delta)


func _begin_action() -> void:
	_strike_done = false
	match _behavior:
		Behavior.CHARGE:
			_step = Step.WINDUP
			_step_timer = float(_params.get("charge_windup", 0.85))
		Behavior.SLAM:
			_step = Step.WINDUP
			_step_timer = float(_params.get("slam_windup", 1.15))
			_spawn_slam_warning(_step_timer)
		Behavior.BARRAGE:
			_step = Step.WINDUP
			_step_timer = float(_params.get("barrage_windup", 0.45))


func _release_action() -> void:
	_step = Step.STRIKE
	match _behavior:
		Behavior.CHARGE:
			_step_timer = float(_params.get("charge_duration", 1.25))
		Behavior.SLAM:
			_step_timer = 0.25
			_do_slam()
		Behavior.BARRAGE:
			_step_timer = 0.2
			_do_barrage()


func _tick_strike(delta: float) -> void:
	if _behavior != Behavior.CHARGE:
		_velocity_toward(Vector3.ZERO, delta)
		return
	# 冲撞：朝起手瞬间锁定的方向直线突进，不再跟踪 —— 否则玩家永远躲不开。
	var to_player := _target.global_position - global_position
	var direction := Vector3(to_player.x, 0.0, to_player.z).normalized()
	var speed := _move_speed * float(_params.get("charge_speed_scale", 2.7))
	_velocity_toward(direction, delta, speed / maxf(_move_speed, 0.01))


func _interval_for_behavior() -> float:
	match _behavior:
		Behavior.CHARGE:
			return float(_params.get("charge_interval", 5.5))
		Behavior.SLAM:
			return float(_params.get("slam_interval", 3.2))
		_:
			return float(_params.get("barrage_interval", 3.6))


## 把期望速度落成 velocity。speed_ratio = 1 表示按基础速度走。
func _velocity_toward(direction: Vector3, delta: float, speed_ratio: float = 1.0) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	var desired := flat.normalized() * _move_speed * speed_ratio
	var accel := 14.0 * delta
	velocity.x = move_toward(velocity.x, desired.x, accel * _move_speed)
	velocity.z = move_toward(velocity.z, desired.z, accel * _move_speed)
	# 重力保持简单：只负责让它贴住地面，不需要跳跃。
	velocity.y = -12.0


## 震地：范围伤害 + 击退，用敌人迫击炮那套地面预警圈做预告。
func _do_slam() -> void:
	AudioUtil.play_at("shockwave", global_position, -3.0)
	var radius := float(_params.get("slam_radius", 5.2))
	var damage := _touch_damage * float(_params.get("slam_damage_scale", 1.25))
	var scene := get_tree().current_scene
	if scene:
		CombatFXUtil.spawn_impact(
			scene, global_position + Vector3.UP * 0.3, Vector3.UP,
			Color(1.0, 0.7, 0.25, 1.0), 3.0
		)
	# 【圈内所有人都吃伤害】
	#
	# 原先只伤 _target（Boss 当前盯的那个人）：另一位玩家站在震地的圈里
	# 会毫发无伤 —— 一次范围攻击只对一个人生效，读起来像判定漏了。
	for node in TargetingUtil.living_players(self):
		var player := node as Node3D
		if player == null:
			continue
		var flat_distance := Vector2(
			player.global_position.x - global_position.x,
			player.global_position.z - global_position.z
		).length()
		if flat_distance <= radius and player.has_method("take_damage"):
			player.call("take_damage", damage, global_position)


func _spawn_slam_warning(delay: float) -> void:
	var scene := get_tree().current_scene
	if not scene:
		return
	if _warning != null and is_instance_valid(_warning):
		_warning.queue_free()
	_warning = GROUND_WARNING_SCENE.instantiate()
	scene.add_child(_warning)
	_warning.global_position = global_position
	_warning.call(
		"setup",
		float(_params.get("slam_radius", 5.2)),
		delay,
		_touch_damage * float(_params.get("slam_damage_scale", 1.25)),
		Color(1.0, 0.55, 0.15, 1.0)
	)


## 弹幕：扇面齐射。复用敌人的子弹对象池，不新建资源路径。
func _do_barrage() -> void:
	var scene := get_tree().current_scene
	if not scene:
		return
	AudioUtil.play_at("enemy_shot", global_position + Vector3.UP * 2.0, -3.0)
	var muzzle := global_position + Vector3.UP * (_capsule_half_height * _body_scale * 1.6)
	var aim := (_target.global_position + Vector3.UP * 0.35 - muzzle)
	if aim.length_squared() <= 0.0001:
		return
	aim = aim.normalized()
	var count := maxi(int(_params.get("barrage_count", 5)), 1)
	var spread := float(_params.get("barrage_spread_degrees", 26.0))
	var speed := float(_params.get("barrage_speed", 7.2))
	var damage := _touch_damage * float(_params.get("barrage_damage_scale", 0.8))
	for index in range(count):
		var ratio := 0.0 if count == 1 else float(index) / float(count - 1)
		var angle := deg_to_rad(lerpf(-spread, spread, ratio))
		var direction := aim.rotated(Vector3.UP, angle)
		var bullet := PoolUtil.acquire_scene(BULLET_POOL_KEY, ENEMY_BULLET_SCENE)
		scene.add_child(bullet)
		# 顺序不能反：先摆到世界坐标，setup() 里的朝向计算才有正确基准。
		bullet.global_position = muzzle
		bullet.call("setup", direction, self, damage, speed, 0.0, Color(1.0, 0.45, 0.1, 1.0))


func _resolve_contact_damage() -> void:
	if _contact_timer > 0.0:
		return
	for index in range(get_slide_collision_count()):
		var collision := get_slide_collision(index)
		var other := collision.get_collider() as Node
		if other == null or not other.is_in_group(GROUP_PLAYER):
			continue
		if other.has_method("take_damage"):
			other.call("take_damage", _touch_damage, global_position)
		_contact_timer = _contact_cooldown
		return


## 让胶囊下沿刚好贴地时，根节点应有的高度。
##
## 敌人（含 Boss）的碰撞胶囊以根节点为圆心，所以"站在地上"= 根节点高度为
## 半高 × 体型，而不是地形高度本身。生成方用它来摆位（见 wave_director）。
func get_stand_height() -> float:
	return _capsule_half_height * _body_scale


## 贴合地形高度。
##
## 这里踩过一次和普通敌人同源的坑：原来直接把地形高度赋给根节点，等于让胶囊
## 圆心落在地面、半个身子埋进土里；一旦压进凹面碰撞体就会穿透并无限下坠。
func _snap_to_terrain() -> void:
	var ground := TerrainFieldUtil.height_at(global_position.x, global_position.z)
	var floor_y := ground + get_stand_height()
	if global_position.y <= floor_y + 0.01:
		global_position.y = floor_y
		velocity.y = 0.0


static func _parse_behavior(name: String) -> Behavior:
	match name:
		"slam":
			return Behavior.SLAM
		"barrage":
			return Behavior.BARRAGE
		_:
			return Behavior.CHARGE
