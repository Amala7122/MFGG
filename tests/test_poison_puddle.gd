extends "res://tests/test_crystal_creature_combat.gd"
const Puddle := preload("res://scripts/enemies/poison_puddle.gd")


func _run() -> void:
	for frame in range(3): await process_frame
	Flow.instance.state = Flow.State.PLAYING
	Flow.instance.visible = false
	paused = false
	await _fixture("VisualBurstCrawler")
	var values := Tuning.defaults("VisualBurstCrawler")
	values.merge({"poison_damage": 7.0, "poison_duration": 3.5, "poison_tick_interval": 0.5}, true)
	var pool := Puddle.new()
	world.add_child(pool)
	pool.configure(Vector3.ZERO, values, {"attack": "原爆囊", "id": "crawler"})
	actor.queue_free()
	player.position = Vector3(3, 0.95, 0)
	await _frames(35)
	_check(pool.can_affect(player) and player.hits == 1 and player.health == 9993.0, "大于爆炸半径的黏液范围内产生配置周期毒伤，投掷者消失不影响")
	_check(pool._mesh.mesh != null and pool.radius == 4.0, "可见贴地网格与实际毒池半径同源")
	player.position.x = 5.0
	await _frames(35)
	_check(player.hits == 1, "离开毒池不继续受伤")
	player.position.x = 3.0
	await _frames(30)
	_check(player.hits == 2, "重新进入毒池恢复周期伤害")
	player.position.y = 4.0
	await _frames(30)
	_check(player.hits == 2 and not pool.can_affect(player), "跳出有效高度不会隔空中毒")
	var at: float = pool.elapsed
	paused = true
	for frame in range(20): await process_frame
	_check(pool.elapsed == at and player.hits == 2, "暂停冻结毒池寿命及伤害")
	paused = false
	await _frames(120)
	_check(not is_instance_valid(pool) and get_nodes_in_group("enemy_hazards").is_empty(), "到期回收毒池且没有死亡结算等待残留")
	await _fixture("VisualBurstCrawler")
	_box(Vector3(1.5, 1.5, 0), Vector3(0.4, 3, 10))
	await _frames(2)
	pool = Puddle.new()
	world.add_child(pool)
	pool.configure(Vector3.ZERO, values, {})
	player.position = Vector3(3, 0.95, 0)
	await _frames(70)
	_check(not pool.can_affect(player) and player.hits == 0, "墙体截断黏液可达面，墙后不显示为可达也不造成毒伤")
	pool.queue_free()
	await _frames(1)
	_box(Vector3(3, 2.8, 0), Vector3(2, 0.4, 2))
	await _frames(2)
	pool = Puddle.new()
	world.add_child(pool)
	pool.configure(Vector3.ZERO, values, {})
	player.position = Vector3(3, 3.95, 0)
	await _frames(35)
	_check(not pool.can_affect(player) and player.hits == 0, "不同楼层不共享毒伤")
	await _dispose()
	Flow.instance.state = Flow.State.MENU
	preload("res://scripts/object_pool.gd").clear_all()
	await create_timer(0.3).timeout
	print("[Poison puddle] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
