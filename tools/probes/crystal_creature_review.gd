extends SceneTree
## 受保护图形复验：六种受击闪红，以及新三种在既有战斗实验场的原生AI与死亡。
const Catalog := preload("res://scripts/enemies/creature_catalog.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Lab := preload("res://prototypes/combat_lab/combat_lab.tscn")
const Flow := preload("res://scripts/game_flow.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failed := false
var world: Node3D
var camera: Camera3D
var observed := {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for frame in range(3):
		await process_frame
	var roster_hash := FileAccess.get_sha256("res://data/encounters/sanctum_creatures.json")
	Flow.instance.state = Flow.State.PLAYING
	Flow.instance.visible = false
	paused = false
	await _flash_review()
	await _battle_review()
	_check(FileAccess.get_sha256("res://data/encounters/sanctum_creatures.json") == roster_hash, "实验没有改主场景编排")
	var report := {"passed": not failed, "observed": observed, "main_encounter_sha256": roster_hash,
		"main_species": ["mud_golem", "fast_beast", "hornet"], "test_player_invincible": true}
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("review.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	await _dispose()
	preload("res://scripts/object_pool.gd").clear_all()
	await create_timer(0.8).timeout
	print("[Crystal creature review] ", JSON.stringify(report))
	quit(1 if failed else 0)


func _flash_review() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.105, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.6
	environment.environment = env
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -25, 0)
	world.add_child(sun)
	var floor := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 40)
	collision.shape = box
	floor.add_child(collision)
	floor.position.y = -0.5
	world.add_child(floor)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 7, 31)
	camera.look_at(Vector3(0, 1, 0))
	camera.make_current()
	var models: Array[CharacterBody3D] = []
	var index := 0
	for id: String in ["mud_golem", "fast_beast", "hornet", "burst_crawler", "prism_spider", "charge_beetle"]:
		var record: Dictionary = Catalog.SPECIES[id]
		var actor: CharacterBody3D = record.scene.instantiate()
		var values := Tuning.defaults(record.profile)
		actor.set_meta(&"enemy_tuning", values)
		actor.set_meta(&"crowd_uniform", true)
		actor.ai_enabled = false
		var dimensions: Vector3 = actor.get_script().get_body_dimensions(values)
		actor.position = Vector3(-12.5 + index * 5.0, 1.7 if id == "hornet" else dimensions.y * 0.5 + 0.06, 0)
		actor.rotation.y = PI * 0.8
		world.add_child(actor)
		for label: Label3D in actor.find_children("*", "Label3D", true, false):
			label.visible = false
		models.append(actor)
		index += 1
	for frame in range(25):
		await process_frame
	await _capture("01_six_models_normal")
	paused = true
	for actor in models:
		actor.take_damage(2.0)
	await _capture("02_six_models_red_hit")
	paused = false
	for frame in range(24):
		await process_frame
	await _capture("03_six_models_restored")
	await _dispose()


func _battle_review() -> void:
	var lab := Lab.instantiate()
	world = lab
	root.add_child(lab)
	current_scene = lab
	for frame in range(12):
		await process_frame
	lab.set_selection({"VisualBurstCrawler": 1, "VisualPrismSpider": 1, "VisualChargeBeetle": 1})
	lab._invincible.button_pressed = true
	lab._crowd_motion.button_pressed = true
	await lab.generate_round()
	lab._start_fight()
	# 观察敌人技能期间暂停自动卫士，防止它提前击杀样本。
	lab._player._wisp.set_process(false)
	lab._player._wisp.set_physics_process(false)
	camera = Camera3D.new()
	lab.add_child(camera)
	camera.position = Vector3(12, 15, 18)
	camera.look_at(Vector3(0, 0, -9))
	camera.make_current()
	var actors: Array = lab._live_enemies.duplicate()
	var captured := {}
	for frame in range(2100):
		await physics_frame
		for actor: CharacterBody3D in actors:
			if not is_instance_valid(actor):
				continue
			var id: String = actor.profile_id()
			if not observed.has(id):
				observed[id] = {"states": {}}
			observed[id].states[str(actor.current_state)] = true
			var active: bool = actor.current_state in [actor.State.AIM, actor.State.WINDUP] and actor.state_timer > 0.5
			if active and not captured.has(id):
				captured[id] = true
				camera.global_position = actor.global_position + Vector3(5, 3.8, 6)
				camera.look_at(actor.global_position + Vector3.UP * 0.7)
				await _capture("04_" + id + "_windup")
	for actor: CharacterBody3D in actors:
		_check(is_instance_valid(actor), "观察期样本存活，未被提前清除")
		if not is_instance_valid(actor):
			continue
		var id: String = actor.profile_id()
		var count: int = actor.throws if id == "VisualBurstCrawler" else (actor.shots if id == "VisualPrismSpider" else actor.charges)
		observed[id]["skill_count"] = count
		_check(count > 0, id + " 通过真实导航接敌并施放技能")
		actor.take_damage(1000000.0)
	await process_frame
	var waited := false
	for frame in range(280):
		await physics_frame
		if not get_nodes_in_group("enemy_death_effect").is_empty():
			waited = true
			_check(lab.state != lab.State.FINISHED, "死亡演出期间实验场不提前结算")
	_check(waited and lab.state == lab.State.FINISHED, "三种死亡完成后实验场结算")
	camera.global_position = Vector3(8, 6, 12)
	camera.look_at(Vector3(0, 0.5, 4))
	await _capture("05_lab_result_after_deaths")
	observed["death_settlement_waited"] = waited
	await _dispose()


func _capture(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var path := Artifacts.ensure_dir("screenshots").path_join(name + ".png")
	_check(root.get_texture().get_image().save_png(path) == OK, "保存图形证据：" + name)


func _dispose() -> void:
	paused = false
	if is_instance_valid(world):
		current_scene = null
		world.queue_free()
		await process_frame
		await physics_frame


func _check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error(message)
