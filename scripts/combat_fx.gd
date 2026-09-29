class_name CombatFX
extends RefCounted
## 战斗反馈统一入口：命中火花 / 伤害飘字 / 范围伤害。
##
## 全静态方法，不需要实例化。所有视觉元素均为运行时构造，不依赖任何美术资源。
## 伤害飘字按距离筛选，避免远距离刷屏（超过 max_draw_distance 直接不生成）。
##
## 注意"准星命中标记"**不在这里**：它是屏幕 UI，而本模块是无状态工具类，
## 原先靠 get_first_node_in_group("player_hud") 去猜 HUD 在哪（多个 HUD 时会闪错那个）。
## 现在由 Ballistics 通过 EventBus.hit_confirmed 广播，PlayerHUD 自己订阅。

## 火花与飘字都从对象池取（见 object_pool.gd 的说明：它们是全项目最大的
## 单项开销来源）。用 preload 而不是裸类名，避免依赖 .godot 的 class 缓存。
const PoolUtil := preload("res://scripts/object_pool.gd")
const ImpactSparkUtil := preload("res://scripts/impact_spark.gd")
const DamageNumberUtil := preload("res://scripts/damage_number.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")

const COLOR_ENEMY_HIT := Color(1.0, 0.78, 0.24, 1.0)
const COLOR_PLAYER_HIT := Color(1.0, 0.26, 0.22, 1.0)
const COLOR_WORLD_HIT := Color(0.8, 0.78, 0.72, 1.0)

const ENEMY_GROUP := "enemies"

const MAX_DRAW_DISTANCE := 45.0


## 在 world_position 生成一簇命中火花。
static func spawn_impact(
	parent: Node,
	world_position: Vector3,
	normal: Vector3,
	color: Color,
	scale_multiplier: float = 1.0
) -> void:
	if not is_instance_valid(parent):
		return
	var spark := PoolUtil.acquire(
		ImpactSparkUtil.POOL_KEY, ImpactSparkUtil
	) as ImpactSpark
	parent.add_child(spark)
	spark.global_position = world_position
	spark.trigger(normal, color, scale_multiplier)


## 生成伤害飘字；距离观察相机过远时自动跳过。
static func spawn_damage_number(
	parent: Node,
	world_position: Vector3,
	amount: float,
	color: Color,
	emphasis: float = 1.0
) -> void:
	if not is_instance_valid(parent):
		return
	var camera := parent.get_viewport().get_camera_3d() if parent.is_inside_tree() else null
	if camera and camera.global_position.distance_to(world_position) > MAX_DRAW_DISTANCE:
		return
	var number := PoolUtil.acquire(
		DamageNumberUtil.POOL_KEY, DamageNumberUtil
	) as DamageNumber
	parent.add_child(number)
	number.global_position = world_position
	number.show_amount(amount, color, emphasis)


## 对 center 周围 radius 内的所有敌人造成带衰减的范围伤害，可选击退。
## require_line_of_sight 为 true 时会被墙体阻挡（手雷用），地面冲击波可关掉。
## 返回被命中的敌人数量。
static func apply_radial_damage(
	source: Node3D,
	center: Vector3,
	radius: float,
	damage: float,
	push_force: float = 0.0,
	require_line_of_sight: bool = true
) -> int:
	if not is_instance_valid(source) or not source.is_inside_tree():
		return 0
	var tree := source.get_tree()
	var world := source.get_world_3d()
	var hits := 0
	for node in tree.get_nodes_in_group(ENEMY_GROUP):
		var enemy := node as Node3D
		if not is_instance_valid(enemy):
			continue
		var offset := enemy.global_position - center
		var distance := offset.length()
		if distance > radius:
			continue
		if require_line_of_sight and world:
			var query := PhysicsRayQueryParameters3D.create(
				center, enemy.global_position + Vector3.UP * 0.4, 1
			)
			if not world.direct_space_state.intersect_ray(query).is_empty():
				continue
		var falloff := clampf(1.0 - distance / maxf(radius, 0.01), 0.25, 1.0)
		if enemy.has_method("take_damage"):
			Telemetry.hurt_enemy(enemy, damage * falloff, source.get_meta(Telemetry.CONTEXT, {}))
			hits += 1
		if push_force > 0.0 and enemy.has_method("apply_push"):
			var direction := offset
			direction.y = 0.0
			if direction.is_zero_approx():
				direction = Vector3.FORWARD
			enemy.call("apply_push", direction.normalized(), push_force * falloff)
	return hits
