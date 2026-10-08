extends SceneTree
## 真实波次生成路径：小队散布、动态距离、出生体型、障碍与断开的导航区域。

const Deployment := preload("res://scripts/enemy_deployment.gd")
const Director := preload("res://scripts/wave_director.gd")
const Spawner := preload("res://scripts/enemy_spawner.gd")
const Flow := preload("res://scripts/game_flow.gd")
const RunState := preload("res://scripts/run_state.gd")
const Pool := preload("res://scripts/object_pool.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Arena := preload("res://scripts/arena.gd")
const WorldScene := preload("res://scenes/hyrule_field.tscn")
const Config := preload("res://scripts/game_config.gd")

class Player extends Node3D:
	var health := 100.0

var _failed := false
var _world: Node3D
var _director: Node
var _deployment: RefCounted
var _player: Node3D
var _floor_body: StaticBody3D
var _entry := {"kind": "melee", "title": "投放回归兵", "scale": 1.0, "health": 100.0,
	"move_speed": 4.0, "damage": 10.0, "weight": 1.0, "min_weapon_level": 1}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for _frame in range(3):
		await process_frame
	await _fixture()
	await _squads_and_movement()
	await _space_and_budget()
	await _navigation()
	await _dispose()
	await _real_arenas()
	Pool.clear_all()
	RunState.begin_run()
	print("[动态小队投放] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _fixture() -> void:
	RunState.begin_run()
	Flow.instance.state = Flow.State.PLAYING
	Flow.instance._set_overlay_visible(false)
	paused = false
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	_floor_body = _box(Vector3(0, 2, 0), Vector3(110, 1, 110))
	_player = Player.new()
	_player.add_to_group("player")
	_player.position = Vector3(0, 3.5, 0)
	_world.add_child(_player)
	var spawner := Spawner.new()
	spawner.name = "EnemySpawner"
	_world.add_child(spawner)
	_director = Director.new()
	_world.add_child(_director)
	_director.set_process(false)
	_director._arena = {"extent": 60.0, "mask_rects": [], "mask_circles": []}
	_director._random.seed = 7721
	_deployment = _director._deployment
	_deployment.configure(_director, _director._arena, _director._random)
	_director._roster = [_entry]
	_director._anchors = [Vector3(20, 2.5, 0)]
	_director._state = Director.State.FIGHT
	for _frame in range(4):
		await physics_frame


func _squads_and_movement() -> void:
	_director._spawn_budget = 13
	_deployment.begin_wave(13)
	var budget := 0
	for squad in _deployment._squads:
		budget += int(squad.count)
		_check(int(squad.count) <= 4 and int(squad.count) >= 1, "编组最多四人且尾组保留余数")
	_check(budget == 13, "编组不增减本波总预算")
	var points: Array[Vector3] = []
	for index in range(13):
		if index == 6:
			_player.position.x = 20
		var before: int = _director._spawn_budget
		for attempt in range(4):
			_director._spawn_one()
			if _director._spawn_budget < before:
				break
		_check(_director._spawn_budget == before - 1, "真实导演每次成功生成只扣一个预算")
		if _director._spawn_budget == before:
			continue
		var enemy: Node3D = _director._alive.back()
		enemy.set_physics_process(false)
		await process_frame
		points.append(enemy.global_position)
		var distance := Vector2(enemy.global_position.x - _player.position.x, enemy.global_position.z - _player.position.z).length()
		_check(distance >= 14.0 and distance <= 32.0, "投放距离随移动后的玩家重新校验")
		_check(absf(enemy.global_position.y - 3.7) < 0.02, "敌人出生在真实平台高度加胶囊净空")
		var interval: float = _director._spawn_cooldown
		_check(is_equal_approx(interval, 0.25) or is_equal_approx(interval, 0.85), "组内快速加入，组间留出间隔")
	_check(points.size() == 13 and points[0].distance_to(points[1]) <= 3.3, "同组成员在中心附近散布")
	_check(points[0].distance_to(points[5]) > 5.0, "下一小队换方向，不轮转固定投放点")
	_check(_director._wave_spawned == 13 and _director._spawn_budget == 0, "实际生成数与预算闭合")
	var second := Player.new()
	second.add_to_group("player")
	second.position = Vector3(20, 3.5, 0)
	_world.add_child(second)
	_player.position = Vector3(0, 3.5, 0)
	_check(_deployment.validate(Vector3(21, 2.5, 0), _entry).is_empty(), "避开全部玩家，不能在第二名玩家身旁投放")
	second.free()
	await _clear_enemies()
	print("[动态小队投放] 小队、动态距离、多人守卫与预算通过")


func _space_and_budget() -> void:
	var wall_a := _box(Vector3(20, 5.5, -1.05), Vector3(5, 6, 0.5))
	var wall_b := _box(Vector3(20, 5.5, 1.05), Vector3(5, 6, 0.5))
	for _frame in range(3):
		await physics_frame
	_check(not _deployment.validate(Vector3(20, 2.5, 0), _entry).is_empty(), "小体型可进入净空足够的通道")
	var heavy := _entry.duplicate()
	heavy.scale = 1.75
	_check(_deployment.validate(Vector3(20, 2.5, 0), heavy).is_empty(), "按体型阻止重型敌人卡进狭窄通道")
	wall_a.free()
	wall_b.free()
	_director._roster = [heavy]
	_director._spawn_budget = 1
	_deployment.begin_wave(1)
	_director._spawn_one()
	var enemy: Node3D = _director._alive.back()
	enemy.set_physics_process(false)
	await process_frame
	_check(enemy.global_position.y >= 2.5 + 1.75 + 0.14, "重型出生高度覆盖放大后的胶囊")
	await _clear_enemies()
	_floor_body.free()
	await physics_frame
	await physics_frame
	_director._spawn_budget = 3
	_director._wave_spawned = 0
	_deployment.begin_wave(3)
	_director._spawn_one()
	_check(_director._spawn_budget == 3 and _director._wave_spawned == 0 and _director._alive.is_empty(),
		"没有安全支撑面时保留预算，不强行退回固定锚点")
	_check(_deployment._squads[0].spawned == 0, "失败投放不消耗小队成员")
	_director._wave = _director._total_waves
	_director._boss_id = "warden"
	_director._start_wave()
	_check(_director._state == Director.State.BREAK and _director._boss == null
		and _director._wave == _director._total_waves, "首领无安全落点时重试，不累计虚假波次")
	Flow.instance.state = Flow.State.PAUSED
	var cooldown: float = _director._spawn_cooldown
	_director._process(10.0)
	_check(_director._spawn_cooldown == cooldown and _director._spawn_budget == 3, "暂停流程不投放或消耗冷却")
	Flow.instance.state = Flow.State.PLAYING
	_floor_body = _box(Vector3(0, 2, 0), Vector3(110, 1, 110))
	for _frame in range(3):
		await physics_frame
	_director._spawn_one()
	_check(_director._spawn_budget == 2, "支撑面恢复后可继续未完成的小队")
	await _clear_enemies()
	print("[动态小队投放] 身体净空、失败重试和重型摆位通过")


func _navigation() -> void:
	_player.position = Vector3(-10, 3.5, 0)
	var left := _nav_rect(-40, -5)
	var right := _nav_rect(5, 40)
	for _frame in range(8):
		await physics_frame
	_check(_deployment.validate(Vector3(10, 2.5, 0), _entry).is_empty(), "拒绝与玩家断开连接的导航孤岛")
	var bridge := _nav_rect(-5, 5)
	for _frame in range(8):
		await physics_frame
	_check(not _deployment.validate(Vector3(10, 2.5, 0), _entry).is_empty(), "有完整导航路径时允许投放")
	left.free()
	right.free()
	bridge.free()
	print("[动态小队投放] 导航连通性通过")


func _real_arenas() -> void:
	# 正式出场顺序目前只有 sanctum；隔离进程内临时打开所有已有定义进行回归。
	var arena_config := Config.get_dictionary("arenas")
	var saved_order: Array = arena_config.order.duplicate()
	arena_config.order = (arena_config.definitions as Dictionary).keys()
	for id in Arena.get_order():
		Arena.current_id = id
		RunState.begin_run()
		Flow.instance.state = Flow.State.PLAYING
		Flow.instance._set_overlay_visible(false)
		paused = false
		_world = WorldScene.instantiate()
		root.add_child(_world)
		current_scene = _world
		for _frame in range(12):
			await process_frame
			await physics_frame
		_director = _world.get_node("Enemies/WaveDirector")
		_director.set_process(false)
		_deployment = _director._deployment
		_director._random.seed = 508
		var player := _world.get_tree().get_first_node_in_group("player") as Node3D
		_check(player != null, "真实竞技场生成玩家")
		var successes := 0
		if player:
			player.set_physics_process(false)
			for attempt in range(6):
				var location: Dictionary = _deployment.select_single(_entry, _director._anchors)
				if not location.is_empty():
					successes += 1
					_check(not _deployment.validate(location.position, _entry).is_empty(), "真实地图落点可复核")
			_check(successes > 0, "竞技场 %s 有动态安全投放点" % id)
		print("[动态小队投放] 竞技场 ", id, " 有效候选 ", successes, "/6")
		await _dispose()
	arena_config.order = saved_order
	Arena.current_id = ""


func _nav_rect(x0: float, x1: float) -> NavigationRegion3D:
	var region := NavigationRegion3D.new()
	var mesh := NavigationMesh.new()
	mesh.vertices = PackedVector3Array([Vector3(x0, 2.5, -40), Vector3(x0, 2.5, 40),
		Vector3(x1, 2.5, 40), Vector3(x1, 2.5, -40)])
	mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	region.navigation_mesh = mesh
	_world.add_child(region)
	return region


func _box(point: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	body.position = point
	_world.add_child(body)
	return body


func _clear_enemies() -> void:
	for enemy in _director._alive.duplicate():
		if is_instance_valid(enemy):
			enemy.queue_free()
	await process_frame
	_director._alive.clear()


func _dispose() -> void:
	paused = false
	current_scene = null
	if is_instance_valid(_world):
		_world.queue_free()
	await process_frame
	Pool.clear_all()


func _check(ok: bool, label: String) -> void:
	if not ok:
		_failed = true
		push_error("[动态小队投放] " + label)
