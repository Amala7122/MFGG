extends SceneTree
## 真实碰撞平台上的脚步、落地、手雷、敌人死亡与地面残留。

const FX := preload("res://scripts/combat_fx.gd")
const DeathFX := preload("res://scripts/enemy_death_fx.gd")
const PlayerScene := preload("res://scenes/player.tscn")
const GrenadeScript := preload("res://scripts/grenade.gd")
const BossScript := preload("res://scripts/boss.gd")
const Mud := preload("res://scripts/prototypes/procedural_mud_golem.gd")
const Beast := preload("res://scripts/prototypes/procedural_fast_beast.gd")
const Titan := preload("res://scripts/prototypes/procedural_sediment_titan.gd")
const Hornet := preload("res://scripts/prototypes/procedural_hornet.gd")
const Flow := preload("res://scripts/game_flow.gd")
const RunState := preload("res://scripts/run_state.gd")
const Pool := preload("res://scripts/object_pool.gd")
const CapturePaths := preload("res://scripts/capture_paths.gd")
const ActionCam := preload("res://scripts/cinematic_action_cam.gd")

var _failed := false
var _world: Node3D
var _player: CharacterBody3D
var _camera: Camera3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for _frame in range(3):
		await process_frame
	RunState.begin_run()
	Flow.instance.state = Flow.State.PLAYING
	Flow.instance._set_overlay_visible(false)
	paused = false
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	_floor(Vector3(0, 2, 0), Vector3(14, 1, 14))
	var slope := _floor(Vector3(12, 2, 0), Vector3(7, 1, 7))
	slope.rotation.z = deg_to_rad(18)
	_player = PlayerScene.instantiate()
	_world.add_child(_player)
	_player.position = Vector3(0, 3.5, 0)
	_player.set_physics_process(false)
	_player._wisp.set_process(false)
	_player._wisp.set_physics_process(false)
	_camera = Camera3D.new()
	_world.add_child(_camera)
	_camera.position = Vector3(7, 8, 9)
	_camera.look_at(Vector3(0, 2.5, 0))
	_camera.make_current()
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.10, 0.14, 0.18)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.7
	_world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -25, 0)
	_world.add_child(light)
	for _frame in range(4):
		await physics_frame
		_player.velocity = Vector3(0, -1, 0)
		_player.move_and_slide()
	_surface()
	await _footsteps()
	await _explosions()
	await _procedural_deaths()
	await _bounds_and_cleanup()
	paused = false
	current_scene = null
	_world.queue_free()
	await process_frame
	_check(FX._active_decals.is_empty(), "场景退出立即清理贴花登记")
	Pool.clear_all()
	RunState.begin_run()
	print("[地面反馈] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _floor(point: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = point
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.46, 0.50, 0.42)
	mesh.material_override = material
	body.add_child(mesh)
	_world.add_child(body)
	return body


func _surface() -> void:
	var ground := FX.sample_ground(_world, Vector3(0, 4, 0))
	_check(not ground.is_empty() and absf(ground.position.y - 2.5) < 0.01, "读取抬高平台，不把旧高度场当作地板")
	var slope := FX.sample_ground(_world, Vector3(12, 5, 0))
	FX.spawn_scorch_mark(_world, Vector3(12, 5, 0), 1.2)
	var mark := _world.get_children().back() as Decal
	_check(mark != null and mark.global_basis.y.dot(slope.normal) > 0.999, "随机旋转焦痕仍贴合坡面法线")
	var expected: Vector3 = slope.position - slope.normal * mark.size.y * 0.42
	_check(mark.global_position.distance_to(expected) < 0.01, "焦痕投影包围盒跟随真实落点")
	var count := get_nodes_in_group("combat_decal").size()
	FX.spawn_scorch_mark(_world, Vector3(40, 3, 40))
	_check(get_nodes_in_group("combat_decal").size() == count, "无地面时不生成空中焦痕")


func _footsteps() -> void:
	_check(_player.is_on_floor(), "真实玩家碰撞胶囊已落地")
	var rig: Node = _player._rig
	var count := get_nodes_in_group("ground_dust").size()
	rig._gait_phase = PI - 0.01
	rig.update(0.05, 4.0, 0.0, true, 4.0, 8.0)
	_check(get_nodes_in_group("ground_dust").size() == count + 1, "真实步态信号驱动脚下扬尘")
	var dust: Node3D = get_nodes_in_group("ground_dust").back()
	_check(absf(dust.global_position.y - 2.535) < 0.01, "脚步在平台表面生成，不埋入地板")
	_check(dust.find_children("*", "OmniLight3D", true, false).is_empty()
		and not dust._particles.mesh.material.emission_enabled, "脚步是无发光扬尘，不复用命中火花")
	var walk_size: float = dust._particles.scale_amount_max
	_player._on_footstep(true)
	var sprint: Node3D = get_nodes_in_group("ground_dust").back()
	_check(sprint._particles.scale_amount_max > walk_size, "冲刺扬尘强于行走")
	count = get_nodes_in_group("ground_dust").size()
	rig.update(0.2, 0.0, 0.0, true, 4.0, 8.0)
	rig.rolling = true
	rig.update(0.2, 8.0, 0.0, true, 4.0, 8.0)
	rig.rolling = false
	_check(get_nodes_in_group("ground_dust").size() == count, "静止与翻滚不触发行走脚步")
	paused = true
	var age: float = dust._age
	_player._on_footstep(true)
	await create_timer(0.08, true, false, true).timeout
	_check(dust._age == age and get_nodes_in_group("ground_dust").size() == count, "暂停冻结寿命并阻止新脚步")
	paused = false
	_player._was_grounded = false
	_player._fall_speed = -10.0
	_player._update_landing(0.016)
	_player._update_landing(0.016)
	_check(get_nodes_in_group("ground_dust").size() == count + 1, "落地扬尘仅在落地边沿触发一次")
	_player._cinematic_locked = true
	_player._on_footstep(false)
	_player._cinematic_locked = false
	_check(get_nodes_in_group("ground_dust").size() == count + 1, "特写锁定不产生脚步")
	await _capture("01_footsteps")
	_clear_dust()


func _explosions() -> void:
	var grenade := GrenadeScript.new()
	_world.add_child(grenade)
	grenade.global_position = Vector3(-3, 3.5, 0)
	grenade.freeze = true
	var count := get_nodes_in_group("combat_decal").size()
	grenade.explode()
	_check(get_nodes_in_group("combat_decal").size() == count + 1, "真实手雷爆炸补回地面焦痕")
	var model := Node3D.new()
	_world.add_child(model)
	model.position = Vector3(0, 3.5, -2)
	var part := MeshInstance3D.new()
	part.mesh = BoxMesh.new()
	model.add_child(part)
	var death: Node3D = DeathFX.spawn_small(_world, model, model.global_position, Color.ORANGE, true)
	death.set_process(false)
	death._process(0.21)
	_check(death._detonated and death._shockwave.visible, "终结散体真正触发地面爆炸")
	_check(absf(death._shockwave.global_position.y - 2.58) < 0.01
		and death._shockwave.global_basis.y.normalized().dot(Vector3.UP) > 0.999, "死亡冲击环水平贴在真实平台上")
	var scorch: Decal = get_nodes_in_group("combat_decal").back()
	death.queue_free()
	model.queue_free()
	await process_frame
	_check(is_instance_valid(scorch) and not scorch.is_queued_for_deletion(), "短命散体消失后地面焦痕保留")
	var boss := BossScript.new()
	_world.add_child(boss)
	boss.configure("warden")
	boss.global_position = Vector3(3, 2.5, -2)
	boss.set_physics_process(false)
	boss._die()
	var large: Node3D = get_nodes_in_group("enemy_death_fx").back()
	large.set_process(false)
	large._process(1.0)
	large._process(1.6)
	_check(large._impact_triggered and large._detached and large._collapse_pieces.size() >= 7,
		"真实首领完整移交外壳和核心，倒地后拆解两者")
	_check(absf(large._shockwave.global_position.y - 2.58) < 0.01, "首领次级殉爆落在平台上")
	await _capture("02_explosion_aftermath")
	large._process(0.5)
	large._corpse_light.light_energy = 0.0
	await create_timer(0.8).timeout
	await _scorch_pixels()
	await _capture("03_ground_scorch")
	large.queue_free()
	await process_frame
	_player._resonance._energy = _player._resonance._max_energy
	_player._resonance.perform_burst()
	ActionCam.dismiss_active()
	var burst: Node3D
	for child in _world.get_children():
		if child.get_script() == preload("res://scripts/resonance_burst_fx.gd"):
			burst = child
	_check(burst != null and absf(burst.global_position.y - 2.54) < 0.01,
		"真实共鸣爆发的光柱与地表环从平台表面发出")


func _procedural_deaths() -> void:
	for script in [Mud, Beast, Titan]:
		_clear_dust()
		var enemy: CharacterBody3D = script.new()
		_world.add_child(enemy)
		enemy.global_position = Vector3(-2, 3.5, 2)
		enemy.set_physics_process(false)
		var method := "trigger_death_shatter" if script == Beast else "trigger_death_scatter"
		enemy.call(method)
		_check(get_nodes_in_group("ground_dust").size() == 1, "新敌人保留原散架并接入地面扬尘")
		await process_frame
		for debris in get_nodes_in_group("enemy_death_effect"):
			debris.queue_free()
		for core in get_nodes_in_group("sediment_titan_core"):
			core.queue_free()
		await process_frame
	_clear_dust()
	var hornet := Hornet.new()
	_world.add_child(hornet)
	hornet.global_position = Vector3(2, 5, 2)
	hornet.set_physics_process(false)
	hornet.trigger_death_fall()
	await process_frame
	_check(get_nodes_in_group("ground_dust").is_empty(), "飞行敌人仍在空中时不播放砸地反馈")
	for _frame in range(100):
		await physics_frame
		if not get_nodes_in_group("ground_dust").is_empty():
			break
	_check(not get_nodes_in_group("ground_dust").is_empty(), "飞行敌人尸体真实触地才扬尘")
	for debris in get_nodes_in_group("enemy_death_effect"):
		debris.queue_free()
	await process_frame


func _bounds_and_cleanup() -> void:
	_clear_dust()
	for _index in range(60):
		FX.spawn_ground_dust(_world, Vector3(0, 2.5, 0), Vector3.UP, 0.5)
	_check(get_nodes_in_group("ground_dust").size() == 48, "扬尘并发有上限")
	for dust in get_nodes_in_group("ground_dust"):
		dust._process(2.0)
	await process_frame
	_check(get_nodes_in_group("ground_dust").is_empty(), "扬尘寿命结束自动清理")
	for _index in range(110):
		FX.spawn_scorch_mark(_world, Vector3(0, 3, 0), 1.0)
	await process_frame
	_check(FX._active_decals.size() == FX.MAX_DECALS, "焦痕与弹痕共用数量上限")


func _clear_dust() -> void:
	for dust in get_nodes_in_group("ground_dust"):
		dust.free()


func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless" or not OS.get_cmdline_user_args().has("--capture-ground"):
		return
	await create_timer(0.12).timeout
	await RenderingServer.frame_post_draw
	var path := CapturePaths.ensure_dir("ground_juice").path_join(label + ".png")
	root.get_texture().get_image().save_png(path)
	print("[地面反馈截图] ", path)


func _scorch_pixels() -> void:
	if DisplayServer.get_name() == "headless":
		return
	paused = true
	var decals := get_nodes_in_group("combat_decal")
	for decal in decals:
		decal.visible = false
	await RenderingServer.frame_post_draw
	var clean := root.get_texture().get_image()
	for decal in decals:
		decal.visible = true
	await RenderingServer.frame_post_draw
	var marked := root.get_texture().get_image()
	var darkened := 0
	for y in range(0, marked.get_height(), 3):
		for x in range(0, marked.get_width(), 3):
			if clean.get_pixel(x, y).get_luminance() - marked.get_pixel(x, y).get_luminance() > 0.04:
				darkened += 1
	_check(darkened > 30, "图形渲染中焦痕确实改变地面像素")
	print("[地面反馈] 焦痕变暗像素采样 ", darkened)
	paused = false


func _check(ok: bool, label: String) -> void:
	if not ok:
		_failed = true
		push_error("[地面反馈] " + label)
