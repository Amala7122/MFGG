extends SceneTree
## 三种新战斗实体在真实物理世界中的关键时序、命中、遮挡和死亡。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Catalog := preload("res://scripts/enemies/creature_catalog.gd")
const Flow := preload("res://scripts/game_flow.gd")
const Spawner := preload("res://scripts/enemy_spawner.gd")
const Config := preload("res://scripts/game_config.gd")
const Scenes := {
	"VisualBurstCrawler": preload("res://prototypes/enemy_prototypes/procedural_burst_crawler.tscn"),
	"VisualPrismSpider": preload("res://prototypes/enemy_prototypes/procedural_prism_spider.tscn"),
	"VisualChargeBeetle": preload("res://prototypes/enemy_prototypes/procedural_charge_beetle.tscn"),
}
class Target extends CharacterBody3D:
	var health := 10000.0
	var hits := 0
	var kills := 0
	func take_damage(amount: float, _at := Vector3.ZERO, _scale := 1.0) -> void:
		health -= amount
		hits += 1
	func register_enemy_kill(_enemy: Node3D = null) -> void:
		kills += 1

var failed := false
var world: Node3D
var player: Target
var actor: CharacterBody3D
var died := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for frame in range(3):
		await process_frame
	Flow.instance.state = Flow.State.PLAYING
	Flow.instance.visible = false
	paused = false
	await _crawler_throw()
	await _crawler_cancel()
	await _spider_hit(false)
	await _spider_hit(true)
	await _spider_obstruction()
	await _beetle(false, false)
	await _beetle(true, false)
	await _beetle(false, true)
	await _contact_and_interrupt()
	for id: String in Scenes:
		await _death(id)
		await _catalog_contract(id)
	await _dispose()
	Flow.instance.state = Flow.State.MENU
	preload("res://scripts/object_pool.gd").clear_all()
	await create_timer(0.6).timeout
	print("[Crystal creature combat] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)


func _fixture(id: String, distance := 12.0) -> void:
	await _dispose()
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var floor := _box(Vector3(0, -0.5, 0), Vector3(90, 1, 90))
	var region := NavigationRegion3D.new()
	var mesh := NavigationMesh.new()
	mesh.vertices = PackedVector3Array([Vector3(-44, 0, -44), Vector3(-44, 0, 44), Vector3(44, 0, 44), Vector3(44, 0, -44)])
	mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	region.navigation_mesh = mesh
	world.add_child(region)
	player = Target.new()
	player.collision_layer = 2
	player.collision_mask = 0
	player.add_to_group("player")
	player.position = Vector3(0, 0.95, -distance)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collision.shape = capsule
	player.add_child(collision)
	world.add_child(player)
	var values := Tuning.defaults(id)
	actor = Scenes[id].instantiate()
	actor.set_meta(&"enemy_tuning", values)
	actor.set_meta(&"crowd_uniform", true)
	actor.set_meta(&"crowd_seed", 19)
	actor.target = player
	var dimensions: Vector3 = actor.get_script().get_body_dimensions(values)
	actor.position.y = dimensions.y * 0.5 + 0.06
	actor.ai_enabled = false
	world.add_child(actor)
	for frame in range(8):
		await physics_frame


func _box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	world.add_child(body)
	return body


func _frames(count: int) -> void:
	for frame in range(count):
		await physics_frame


func _until(property: String, wanted: Variant, maximum := 240) -> bool:
	for frame in range(maximum):
		if actor.get(property) == wanted:
			return true
		await physics_frame
	return false


func _crawler_throw() -> void:
	await _fixture("VisualBurstCrawler")
	actor.ai_enabled = true
	_check(await _until("throws", 1), "爬兽能通过原生范围判断投出真实爆囊")
	_check(absf(wrapf(actor.visual.rig.rotation.y, -PI, PI)) > PI * 0.8, "投囊前已完成180度转身")
	_check(get_nodes_in_group("enemy_projectiles").size() == 1, "一次投囊只产生一个投射物")
	var projectile: Node3D = get_nodes_in_group("enemy_projectiles")[0]
	_check(is_equal_approx(float(projectile._warning.mesh.outer_radius), actor.p("poison_radius")), "落点预告包含大块黏液范围，不只显示较小的爆炸半径")
	await _frames(100)
	_check(player.hits == 1 and player.health < 10000.0, "落囊爆炸产生一次真实伤害")
	player.position = actor.global_position + Vector3(0, 0, -3)
	await _frames(2)
	_check(actor.current_state == actor.State.RETREAT, "玩家进近身区立即改为撤退")
	var start := actor.position
	await _frames(20)
	_check(actor.position.distance_to(start) > 0.3 and actor.throws == 1, "收甲时已实际撤离，没有补发爆囊")
	_check(absf(actor.visual.back_armor.rotation.x) < 0.1, "紧急撤退收起背甲")


func _crawler_cancel() -> void:
	await _fixture("VisualBurstCrawler", 3)
	actor.set_physics_process(false)
	actor.ai_enabled = true
	actor.current_state = actor.State.WINDUP
	actor.visual.behavior.state = actor.visual.Behavior.State.THROW
	actor.visual.behavior.clock = actor.p("release") * actor.p("release_snap_ratio") - 0.005
	actor._physics_process(0.02)
	_check(actor.throws == 0 and actor.current_state == actor.State.RETREAT, "释放同帧进入撤退区优先取消，绝不晚发")


func _spider_hit(dodge: bool) -> void:
	await _fixture("VisualPrismSpider", 14)
	var eye_y: float = actor.visual.focus.global_position.y
	actor.ai_enabled = true
	_check(await _until("aim_locked", true), "蜘蛛瞄准末段实际锁定")
	_check(actor.visual.focus.global_position.y > eye_y + 0.4 and actor._aim_line.visible, "瞄准时撑起前腿、抬高晶眼并显示瞄准线")
	var locked: Vector3 = actor.aim_point
	if dodge:
		player.position.x = 5.0
	_check(await _until("shots", 1), "完成前摇后发射晶束")
	_check(actor.aim_point.is_equal_approx(locked), "锁向后不追踪玩家")
	await _frames(35)
	_check(player.hits == (0 if dodge else 1), "晶束对侧移玩家落空" if dodge else "实际晶束能够命中玩家")


func _spider_obstruction() -> void:
	await _fixture("VisualPrismSpider", 14)
	actor.ai_enabled = true
	_check(await _until("aim_locked", true), "遮挡用例进入锁定")
	_box(Vector3(0, 1.7, -6), Vector3(8, 3.4, 0.5))
	await _frames(45)
	_check(actor.shots == 0 and player.hits == 0, "发射前新出现掩体会取消，不穿墙狙击")
	_check(not actor._aim_line.visible, "取消时清除瞄准线")


func _beetle(dodge: bool, wall: bool) -> void:
	await _fixture("VisualChargeBeetle", 12)
	actor.ai_enabled = true
	_check(await _until("charge_locked", true), "兜虫蓄力末段锁向")
	var heading: Vector3 = actor.charge_direction
	var warning_pose: Transform3D = actor._lane.global_transform
	_check(actor._lane.visible and actor._lane.phase == actor._lane.Phase.LOCKED, "冲锋锁向时显示实际贴地预警")
	_check(absf(warning_pose.origin.y) < 0.1, "冲锋预警位于脚下地面而非身体中心")
	_check(float(actor._lane.shape.length) > actor.p("charge_distance"), "冲锋预警包含前角的触及范围")
	if dodge:
		player.position.x = 7.0
	if wall:
		_box(Vector3(0, 1.8, -6), Vector3(10, 3.6, 0.5))
	_check(await _until("charges", 1), "兜虫发动真实位移冲锋")
	_check(actor._lane.global_transform.is_equal_approx(warning_pose), "锁向后预警不跟随目标改变方向")
	_check(await _until("current_state", actor.State.RECOVERY), "冲锋结束或接触后进入恢复")
	_check(actor.charge_direction.is_equal_approx(heading) and absf(actor.position.x) < 0.2, "锁定后冲锋不拐弯追踪")
	if wall:
		_check(actor.position.z > -5.0 and player.hits == 0, "角部遇墙提前停止，不穿墙伤害")
		_check(is_equal_approx(actor._recovery_time, actor.p("wall_recovery")), "撞墙使用独立恢复时间")
	else:
		_check(player.hits == (0 if dodge else 1), "侧移可躲开冲锋" if dodge else "接触玩家产生一次冲锋伤害")
	var hits := player.hits
	await _frames(30)
	_check(player.hits == hits, "同一次冲锋不会逐帧重复伤害")


func _contact_and_interrupt() -> void:
	await _fixture("VisualChargeBeetle", 2.8)
	actor.ai_enabled = true
	await _frames(70)
	_check(actor.charges == 0 and player.hits == 1, "近身时短顶撞，无冲锋起步死角")
	await _fixture("VisualChargeBeetle", 3.75)
	_check(not actor.can_attack_from(actor.global_transform), "顶撞范围外且不足冲锋距离时继续接近，不能宣称已能攻击")
	actor.ai_enabled = true
	await _frames(120)
	_check(player.hits > 0, "顶撞与冲锋之间的距离也会先接近再实际命中")
	await _fixture("VisualChargeBeetle", 12)
	actor.ai_enabled = true
	_check(await _until("charge_locked", true), "打断用例进入蓄力")
	actor.apply_grenade_stagger(0.6)
	await _frames(25)
	_check(actor.charges == 0 and not actor._lane.visible, "手雷硬直清除蓄力与预警，不延迟冲出")


func _death(id: String) -> void:
	await _fixture(id)
	died = 0
	actor.died.connect(_died)
	actor.take_damage(1000000.0)
	actor.take_damage(1000000.0)
	_check(died == 1 and player.kills == 1, "死亡通知与击杀只发一次：" + id)
	await process_frame
	_check(not is_instance_valid(actor) and not get_nodes_in_group("enemy_death_effect").is_empty(), "活体回收后死亡动画独立继续：" + id)
	await _frames(220)
	_check(get_nodes_in_group("enemy_death_effect").is_empty(), "死亡动画结束释放结算等待：" + id)
	_check(player.hits == 0, "死亡自爆、毒液和尸体不伤害玩家：" + id)


func _died(_enemy: Node3D) -> void:
	died += 1


func _catalog_contract(id: String) -> void:
	await _fixture(id)
	actor.queue_free()
	await process_frame
	var species := "burst_crawler" if id == "VisualBurstCrawler" else ("prism_spider" if id == "VisualPrismSpider" else "charge_beetle")
	var entry := Catalog.prepare({"species": species, "kind": "melee" if species == "charge_beetle" else "ranged"})
	_check(not entry.is_empty() and entry.resolved_preset == Tuning.active_name(id), "公共注册表解析已保存默认方案：" + id)
	var values: Dictionary = entry.tuning.duplicate(true)
	values.merge({"max_health": 173.0, "attack_damage": 37.0, "move_speed": 1.7, "windup": 1.3, "body_size": 1.4, "variation_enabled": false}, true)
	entry.tuning = values
	var spawner := Spawner.new()
	world.add_child(spawner)
	actor = spawner.spawn_enemy(entry, Vector3(6, 0, 0), 1.0) as CharacterBody3D
	actor.set_physics_process(false)
	_check(actor.health == 173.0 and actor.attack_damage == 37.0 and actor.move_speed == 1.7, "宿主使用注入的生命、攻击和移速：" + id)
	_check(actor.p("windup") == 1.3 and actor.visual.p("windup") == 1.3, "宿主和动作读取同一前摇快照：" + id)
	_check(is_equal_approx(actor.scale.x, 1.4) and is_equal_approx(actor.visual.rig.scale.x, 1.0), "模型与碰撞只应用一次基础体型：" + id)
	var dimensions: Vector3 = actor.get_script().get_body_dimensions(values)
	_check(is_equal_approx(actor.global_position.y, dimensions.y * 1.4 * 0.5 + 0.15), "公共生成器按子类真实尺寸摆位：" + id)
	_check(actor.has_node("EnemyLifecycle") and actor.target == player, "公共生成器装配生命周期并绑定目标：" + id)
	var drops_before := get_nodes_in_group("pickups").size()
	var original: Dictionary = Config._data.drops.duplicate(true)
	Config._data.drops.melee_chance = 1.0
	Config._data.drops.ranged_chance = 1.0
	died = 0
	actor.died.connect(_died)
	actor.target = null
	actor.take_damage(1000000.0)
	actor.take_damage(1000000.0)
	_check(died == 1 and player.kills == 1 and get_nodes_in_group("pickups").size() == drops_before + 1, "正式模式一次死亡、击杀和公共掉落：" + id)
	Config._data.drops = original
	await _frames(230)
	_check(get_nodes_in_group("enemy_death_effect").is_empty(), "正式模式死亡动画也正确释放等待组：" + id)


func _dispose() -> void:
	if is_instance_valid(world):
		current_scene = null
		world.queue_free()
		await process_frame
		await physics_frame


func _check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error(message)
