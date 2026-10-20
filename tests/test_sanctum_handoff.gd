extends SceneTree
## 新入口、实际地图投放、预设、击杀附属流程和死亡结算交接。
const WorldScene := preload("res://scenes/sanctum_main.tscn")
const Flow := preload("res://scripts/game_flow.gd")
const Wave := preload("res://scripts/wave_director.gd")
const Config := preload("res://scripts/game_config.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Pool := preload("res://scripts/object_pool.gd")
const RunState := preload("res://scripts/run_state.gd")
const Terrain := preload("res://scripts/terrain_field.gd")

var _failures := 0
var _died := 0
var _world: Node3D
var _director: Node
var _player: CharacterBody3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for frame in range(3):
		await process_frame
	var source := FileAccess.get_file_as_string("res://scenes/sanctum_main.tscn")
	_check(Flow._main_scene_path() == "res://scenes/sanctum_main.tscn", "新主入口及练习场返回入口一致")
	_check(not source.contains("hyrule_field") and not source.contains("enemy_spawn_point") and not source.contains("survival_director"), "新场景没有继承旧主场景或旧投放节点")
	_check(FileAccess.get_file_as_bytes("res://scenes/hyrule_field.tscn") == FileAccess.get_file_as_bytes("res://data/retired/hyrule_field_20261019/hyrule_field.tscn.snapshot"), "旧场景完整保留")
	_check(Config.get_dictionary("enemy_roster").entries.size() == 16, "退役图鉴未被替换")
	Flow.instance.state = Flow.State.MENU
	Flow.instance._set_overlay_visible(false)
	paused = false
	RunState.begin_run()
	_world = WorldScene.instantiate()
	root.add_child(_world)
	current_scene = _world
	for frame in range(12):
		await process_frame
	_director = _world.get_node("Enemies/WaveDirector")
	_director.set_process(false)
	_check(_world.has_node("MapContent") and _world.has_node("Backdrop"), "新场景生成圣所地图与远景")
	_check(_world.get_node("NavRegion")._baked, "新场景导航完成")
	_check(_world.get_node("Enemies").get_child_count() == 2, "敌人容器只有公共生成器与波次器")
	_check(_director._roster.size() == 6 and _director._boss_id == "sediment_titan", "六种混编后安排沉积泰坦")
	_check(_director._spawn_cfg.max_alive == 30 and _director._count_for_wave(1) == 30 and _director._count_for_wave(3) == 60, "独立编排覆盖旧场景密度和等级加量")
	Flow.instance.state = Flow.State.PLAYING
	_player = _world.get_node("PlayerSpawner").spawn_player()
	_player.set_physics_process(false)
	_player.set_process_input(false)
	_director._random.seed = 251019
	_director._start_wave()
	for frame in range(300):
		if _director._alive.size() >= 6:
			break
		_director._spawn_one()
		await physics_frame
	_check(_director._alive.size() == 6, "实际圣所地图成功投放六种敌人")
	var species := {}
	for enemy: CharacterBody3D in _director._alive:
		_check(is_instance_valid(enemy.target), "正式生成绑定玩家，泥偶无需依赖实验室手动传目标")
		enemy.ai_enabled = false
		var entry: Dictionary = enemy.get_meta(&"enemy_entry")
		species[entry.species] = true
		_check(enemy.has_node("EnemyLifecycle") and enemy.collision_layer == 4 and enemy.collision_mask == 3, "公共生命周期且不做敌人实体碰撞")
		var dimensions: Vector3 = enemy.get_script().get_body_dimensions(entry.tuning)
		_check(enemy.position.y - Terrain.height_at(enemy.position.x, enemy.position.z) >= dimensions.y * enemy.scale.y * 0.5 - 0.05, "真实体型落点没有埋地")
		_check(enemy.health == float(entry.tuning.max_health), "最大生命来自已保存方案")
		_check(enemy.scale.x <= float(entry.scale) + 0.001, "实际随机体型受选点上界约束")
		_check(not bool(enemy.get_meta(&"crowd_uniform", false)), "正式小怪保留个体差异和群体转向")
		if entry.species == "fast_beast":
			_check(entry.resolved_preset == Tuning.active_name("PrototypeFastBeast"), "正式晶兽使用面板选定的默认方案")
		if entry.species == "hornet":
			_check(enemy.position.y > Terrain.height_at(enemy.position.x, enemy.position.z) + 2.0, "晶刺蜂按悬停高度出生")
	_check(species.size() == 6, "首轮保证六个物种都出现")
	if not _director._alive.is_empty():
		var enemy: CharacterBody3D = _director._alive[0]
		var lifecycle: Node = enemy.get_node("EnemyLifecycle")
		var kills: int = _player.kill_count
		enemy.global_position.y = -100.0
		lifecycle._physics_process(1.1)
		_check(enemy.global_position.is_equal_approx(lifecycle.spawn_position) and enemy.health > 0, "坠界恢复合法出生点而非永久占用波次")
		_check(_player.kill_count == kills, "环境恢复不误发击杀奖励")
	await _death_contracts()
	await _settlement_contracts()
	await _boss_contract()
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	Flow.instance.state = Flow.State.PLAYING
	paused = false
	MouseControl.mode = Input.MOUSE_MODE_CAPTURED
	Flow.instance._input(cancel)
	_check(Flow.instance.state == Flow.State.PAUSED and MouseControl.mode == Input.MOUSE_MODE_VISIBLE, "Esc 暂停并释放鼠标")
	paused = false
	Flow.instance.state = Flow.State.MENU
	_director._cancel_clear_cinematic()
	current_scene = null
	_world.queue_free()
	await process_frame
	Pool.clear_all()
	RunState.begin_run()
	await create_timer(0.2).timeout
	print("[Sanctum handoff] failures=", _failures)
	quit(1 if _failures else 0)


func _death_contracts() -> void:
	var original: Dictionary = Config._data.drops.duplicate(true)
	Config._data.drops.melee_chance = 1.0
	Config._data.drops.ranged_chance = 1.0
	var pickups_before := get_nodes_in_group("pickups").size()
	var kills_before: int = _player.kill_count
	var enemies: Array = _director._alive.duplicate()
	for enemy: CharacterBody3D in enemies:
		enemy.died.connect(_on_died)
		enemy.target = null # 击杀归属不能依赖 AI 之前是否已经发现玩家。
		var before := float(enemy.health)
		enemy.take_damage(1.0)
		_check(enemy.health < before and enemy.health > 0, "真实战斗实体响应非致命伤害")
		enemy.take_damage(1000000.0)
		enemy.take_damage(1000000.0)
	_check(_died == 6 and _player.kill_count == kills_before + 6, "每个敌人恰好一次死亡通知与击杀奖励")
	_check(get_nodes_in_group("pickups").size() == pickups_before + 6, "通过公共掉落表生成正式掉落")
	for drop: Node3D in get_nodes_in_group("pickups"):
		_check(absf(drop.global_position.y - Terrain.height_at(drop.global_position.x, drop.global_position.z) - 0.5) < 0.3, "飞行单位掉落也落到可拾取的地面高度")
	_check(is_instance_valid(_director._last_death_fx), "正式死亡表现登记为特写目标")
	await process_frame
	_director._purge_dead()
	_check(_director._alive.is_empty() and get_nodes_in_group("enemies").is_empty(), "根节点回收后波次存活数归零")
	_check(not get_nodes_in_group("enemy_death_effect").is_empty(), "根节点回收后死亡演出继续存在")
	Config._data.drops = original


func _settlement_contracts() -> void:
	_director._state = Wave.State.BREAK
	_director._spawn_budget = 0
	_director._on_clear_cinematic_finished(false, 1, 3, 1)
	_check(Flow.is_playing() and not _director._pending_clear.is_empty(), "特写结束仍等待死亡演出，不提前弹选卡")
	_director._process(10.0)
	_check(_director._state == Wave.State.BREAK, "等待期间不会偷偷开启下一波")
	for effect: Node in get_nodes_in_group("enemy_death_effect"):
		effect.queue_free()
	await process_frame
	_director._try_complete_clear()
	_check(Flow.instance.state == Flow.State.UPGRADE_PICK and _director._pending_clear.is_empty(), "演出结束后才弹出一次选卡")
	Flow.instance.state = Flow.State.PLAYING
	paused = false
	var effect := Node3D.new()
	effect.add_to_group("enemy_death_effect")
	_world.add_child(effect)
	_director._state = Wave.State.CLEARED
	_director._on_clear_cinematic_finished(true, 3, 3, 1)
	_check(Flow.is_playing(), "Boss 结算同样等待演出")
	effect.queue_free()
	await process_frame
	_director._try_complete_clear()
	_check(Flow.instance.state == Flow.State.STAGE_CLEAR, "Boss 演出完成后进入结算")
	Flow.instance.state = Flow.State.PLAYING
	paused = false
	effect = Node3D.new()
	effect.add_to_group("enemy_death_effect")
	_world.add_child(effect)
	_director._on_clear_cinematic_finished(false, 2, 3, 1)
	_director._on_player_died(0.0, 0)
	effect.queue_free()
	await process_frame
	_director._try_complete_clear()
	_check(Flow.is_playing() and _director._pending_clear.is_empty(), "玩家死亡或退出取消旧结算请求")


func _on_died(_enemy: Node3D) -> void:
	_died += 1


func _boss_contract() -> void:
	_director._wave = 3
	_director._start_wave()
	# 此夹具手动暂停了推进器；正常流程选点失败会在BREAK里重试，测试也须推进。
	for frame in range(360):
		await physics_frame
		if is_instance_valid(_director._boss): break
		_director._process(1.0 / 60.0)
	var titan: Node3D = _director._boss
	_check(is_instance_valid(titan) and _director._state == Wave.State.BOSS, "三波结束经正式推进器实际生成泰坦")
	if not is_instance_valid(titan): return
	titan.ai_enabled = false
	var cfg := Config.get_dictionary("bosses.sediment_titan")
	var values := Tuning.preset_values("PrototypeSedimentTitan", String(cfg.preset))
	_check(titan._tuning == values and titan.get_max_health() == float(values.max_health), "共用直战台公共生成器及保存方案，数值不额外缩放")
	_check(titan._formal_boss and bool(titan.get_meta(&"crowd_uniform")) and titan.target == _player, "正式Boss血条、统一体型与目标绑定")
	titan.take_damage(100000000.0)
	await process_frame
	_check(not get_nodes_in_group("enemy_death_effect").is_empty(), "实际泰坦死亡核心纳入结算等待")
	_director._on_clear_cinematic_finished(true, 3, 3, 1)
	_check(Flow.is_playing(), "真实泰坦核心未消失时不结算")
	for frame in range(720):
		await physics_frame
		if get_nodes_in_group("enemy_death_effect").is_empty(): break
	_director._try_complete_clear()
	_check(Flow.instance.state == Flow.State.STAGE_CLEAR, "真实泰坦死亡演出结束才结算")
	_director._cancel_clear_cinematic()
	paused = false


func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures += 1
		push_error(message)
