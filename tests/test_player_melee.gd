extends SceneTree
## 正式玩家接线 + 真实物理查询；不复制近战判定。F7 保存只在验收隔离副本执行。
const Player := preload("res://scenes/player.tscn")
const Settings := preload("res://scripts/player_melee_settings.gd")
const Targets := preload("res://scripts/player_melee_targets.gd")
const Damage := preload("res://scripts/combat_damage.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Capture := preload("res://scripts/capture_paths.gd")
var _failures := 0
var _checks := 0
var _world: Node3D
var _player: CharacterBody3D
var _melee: Node3D

class Target extends StaticBody3D:
	var health := 10000.0
	var hits := 0
	var armor := 0.2
	var contexts: Array[Dictionary] = []
	func take_damage(amount: float) -> void:
		contexts.append(get_meta(&"combat_context", {}).duplicate())
		health -= preload("res://scripts/combat_damage.gd").armored(self, amount, armor)
		hits += 1

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(message)
	else:
		print("PASS ", message)

func _event(pressed: bool, key := KEY_SPACE) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.keycode = key
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _advance(seconds: float) -> void:
	for _i in range(ceili(seconds * 60.0)):
		_melee.tick(1.0 / 60.0, true)

func _frames(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame

func _target(at: Vector3, size := Vector3(1, 2, 1)) -> Target:
	var actor := Target.new()
	actor.position = at
	actor.collision_layer = 4
	actor.collision_mask = 0
	actor.add_to_group("enemies")
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	actor.add_child(collision)
	if DisplayServer.get_name() != "headless":
		var visual := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = size
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.55, 0.23, 0.12)
		mesh.material = material
		visual.mesh = mesh
		actor.add_child(visual)
	_world.add_child(actor)
	return actor

func _reset() -> void:
	_melee.cancel()
	_melee.heavy_cooldown = 0.0
	_player.global_position = Vector3(0, 0.9, 0)
	_player.velocity = Vector3.ZERO
	_player._hitstop_timer = 0.0
	_event(false)

func _run() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	var floor := StaticBody3D.new()
	var floor_collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	floor_collision.shape = box
	floor.position.y = -0.5
	floor.add_child(floor_collision)
	if DisplayServer.get_name() != "headless":
		var visual := MeshInstance3D.new()
		var floor_mesh := BoxMesh.new()
		floor_mesh.size = box.size
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.25, 0.29, 0.27)
		floor_mesh.material = material
		visual.mesh = floor_mesh
		floor.add_child(visual)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-50, -30, 0)
		sun.light_energy = 1.6
		_world.add_child(sun)
		var environment := WorldEnvironment.new()
		environment.environment = Environment.new()
		environment.environment.background_mode = Environment.BG_COLOR
		environment.environment.background_color = Color(0.09, 0.13, 0.18)
		environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.environment.ambient_light_color = Color(0.8, 0.85, 1.0)
		environment.environment.ambient_light_energy = 0.5
		_world.add_child(environment)
	_world.add_child(floor)
	_player = Player.instantiate()
	if DisplayServer.get_name() == "headless":
		_player.set_script(preload("res://tests/fixtures/player_melee_input_host.gd"))
	_player.position = Vector3(0, 1, 0)
	_world.add_child(_player)
	await _frames(3)
	var flow := root.get_node("GameFlow")
	flow._resume_play()
	MouseControl.mode = Input.MOUSE_MODE_CAPTURED
	_player.target_yaw = 0.0
	_player.target_pitch = 0.0
	_player.camera_pivot.rotation = Vector3.ZERO
	await _frames(25)
	_melee = _player.get_node("PlayerMelee")
	print("[近战环境] gate=", _melee.can_control(), " mouse=", MouseControl.mode, " paused=", paused,
		" flow=", flow.state, " dying=", _player._dying, " cine=", _player._cinematic_locked,
		" rolling=", _player._rolling, " params=", _melee.parameters.size())
	_check(_melee.can_control(), "测试前置：正式玩家近战控制闸门已开启")
	if not _melee.can_control():
		quit(1)
		return
	if DisplayServer.get_name() == "headless":
		_player.simulated_capture = false
		_check(not _melee.can_control(), "无鼠标捕获时近战闸门仍关闭")
		_player.simulated_capture = true
	var values := Settings.load_values()
	_check(not values.is_empty() and values.heavy_damage == 180.0 and values.sweep_damage == 60.0, "独立配置加载旧版轻扫60 / 重击180")
	_check(not _player.jump_enabled and InputMap.action_get_events("jump").is_empty(), "主动跳跃关闭且 jump 不占空格")
	var melee_keys := InputMap.action_get_events("melee")
	_check(melee_keys.size() == 1 and melee_keys[0].physical_keycode == KEY_SPACE, "近战真实映射为空格")
	var grenade_keys := InputMap.action_get_events("grenade")
	_check(grenade_keys.size() == 1 and grenade_keys[0].physical_keycode == KEY_E, "E 仍独立映射手雷")
	var target := _target(Vector3(0, 1, -2.7))
	# 同一个 actor 的两个身体碰撞形状：一次挥击只能算一次。
	target.add_child(target.get_child(0).duplicate())
	await _frames(2)
	var height := _player.position.y
	_event(true)
	await _frames(3)
	_event(false)
	await _frames(10)
	_check(target.hits == 1 and is_equal_approx(target.health, 9952.0), "真实空格轻扫经过护甲，双碰撞只命中一次")
	_check(_player.position.y <= height + 0.03 and _player.velocity.y <= 0.01, "空格近战没有触发起跳")
	_check(_player._grenade_cooldown == 0.0, "空格不消费 E 手雷")
	if DisplayServer.get_name() != "headless":
		await _capture_action()
	await _frames(25)
	var attacks_before: int = _melee.attack_count
	_event(true, KEY_E)
	await _frames(2)
	_event(false, KEY_E)
	await _frames(2)
	_check(_player._grenade_cooldown > 0.0 and _melee.attack_count == attacks_before, "真实 E 投雷，未触发近战")
	# 余下用组件的同一秒时钟精确核对边界，暂停玩家自动驱动避免双 tick。
	_player.set_physics_process(false)
	_reset()
	target.hits = 0
	target.health = 10000.0
	_event(true)
	_advance(0.43)
	_check(_melee.phase == "charge" and not _melee._hit, "长按先蓄力，不提前伤害")
	_event(false)
	_advance(0.2)
	_check(target.hits == 1 and is_equal_approx(target.health, 9838.0), "松开重击一次180伤害、50%护甲穿透")
	_check(_melee.heavy_cooldown > 2.5 and target.contexts.back().melee_kind == "heavy", "重击独立冷却并走现有伤害上下文")
	_check(not target.has_meta(&"combat_context"), "命中上下文正确恢复，无残留穿甲")
	_advance(0.6)
	_event(true)
	_event(false)
	_advance(0.2)
	_check(target.hits == 2, "重击冷却不阻止点按轻扫")
	_reset()
	target.hits = 0
	_event(true)
	_advance(1.6)
	_check(target.hits == 1, "长按自动释放一次，不持续自动连击")
	_event(false)
	_reset()
	_event(true)
	_event(false)
	_advance(0.18)
	var combo_attacks: int = _melee.attack_count
	_event(true)
	_event(false)
	_advance(0.35)
	_check(_melee.attack_count == combo_attacks + 1, "输入缓存跨恢复段接轻扫连段")
	_reset()
	_event(true)
	_advance(0.2)
	_melee.on_hurt(80.0, 50.0, 0.0)
	_check(_melee.phase == "charge", "护盾未破不打断蓄力")
	_melee.on_hurt(50.0, 0.0, 1.0)
	_check(_melee.phase == "idle" and _melee.heavy_cooldown > 1.4, "破盾打断蓄力，只有半冷却")
	_event(false)
	var hits_before := target.hits
	_advance(0.5)
	_check(target.hits == hits_before, "被打断后无延迟命中")
	_reset()
	_event(true)
	_event(false)
	_player._start_roll(Vector3.FORWARD)
	_player._rolling = false
	_advance(0.5)
	_check(_melee.phase == "idle" and target.hits == hits_before, "翻滚清除未出手近战")
	_event(true)
	_advance(0.2)
	_player.set_cinematic_locked(true)
	_check(_melee.phase == "idle", "特写锁定立即取消蓄力")
	_player.set_cinematic_locked(false)
	_event(false)
	_reset()
	var panel: CanvasLayer = _melee._panel
	print("[面板前] gate=", _melee.can_control(), " mouse=", MouseControl.mode, " paused=", paused,
		" flow=", flow.state, " dying=", _player._dying, " cine=", _player._cinematic_locked, " rolling=", _player._rolling)
	panel.open()
	_check(paused and panel.opened and flow.has_meta(&"player_melee_tuning_modal"), "F7面板暂停战斗并独占关闭输入")
	if not panel.opened:
		quit(1)
		return
	var original_damage: float = _melee.parameters.sweep_damage
	var original_lunge: float = _melee.parameters.sweep_lunge
	var original_cancel: float = _melee.parameters.sweep_cancel
	panel._fields.sweep_damage.value = original_damage + 7.0
	_check(_melee.parameters.sweep_damage == original_damage + 7.0 and Settings.load_values().sweep_damage == original_damage, "调参草稿生效但未擅自写默认")
	_check(_melee.parameters.sweep_lunge == original_lunge and _melee.parameters.sweep_cancel == original_cancel, "只改一个字段，不把其他控件显示取整写回")
	panel._reload()
	_check(_melee.parameters.sweep_damage == original_damage, "重读配置撤回草稿")
	# 只允许隔离验收副本保存；手动直接跑脚本不会改真实工程参数。
	if ProjectSettings.globalize_path("res://").contains("/tmp/project/") or ProjectSettings.globalize_path("res://").contains("\\tmp\\project\\"):
		panel._fields.sweep_damage.value = original_damage + 7.0
		panel._save()
		_check(Settings.load_values().sweep_damage == original_damage + 7.0, "显式保存写回隔离工程，重读一致")
		panel._fields.sweep_damage.value = original_damage
		panel._save()
		_check(Settings.load_values().sweep_damage == original_damage, "保存恢复基线成功")
		_check(panel._status.text.begins_with("与项目默认一致"), "保存后显示状态与实际落盘值一致")
	if DisplayServer.get_name() != "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		Capture.ensure_dir("player_melee")
		_check(root.get_texture().get_image().save_png(Capture.file("player_melee/panel.png")) == OK, "调参面板截图保存")
	_event(true, KEY_ESCAPE)
	await process_frame
	_event(false, KEY_ESCAPE)
	_check(not paused and not panel.opened and not flow.has_meta(&"player_melee_tuning_modal"), "Esc只关闭调参，不遗留暂停或流程元数据")
	_reset()
	target.queue_free()
	await _frames(2)
	var edge := _target(Vector3(0, 1, -5.3), Vector3(2, 3, 4))
	var behind := _target(Vector3(0, 1, 2.5))
	await _frames(2)
	var found := Targets.collect(_player, Vector3.FORWARD, 3.5, 2.2, 80.0, 128)
	_check(found.size() == 1 and found[0].target == edge, "距离按大体型碰撞边界判定，排除身后目标")
	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(5, 4, 0.2)
	wall_shape.shape = wall_box
	wall.position = Vector3(0, 1, -1.7)
	wall.add_child(wall_shape)
	_world.add_child(wall)
	await _frames(2)
	found = Targets.collect(_player, Vector3.FORWARD, 3.5, 2.2, 80.0, 128)
	_check(found.is_empty(), "实体墙遮挡近战，不能穿墙伤害")
	wall.queue_free()
	edge.queue_free()
	behind.queue_free()
	await _frames(2)
	var crowd: Array[Target] = []
	for index in range(100):
		crowd.append(_target(Vector3((index % 10 - 4.5) * 0.12, 1, -2.0 - floorf(index / 10.0) * 0.08), Vector3(0.1, 1, 0.1)))
	await _frames(2)
	_reset()
	_event(true)
	_event(false)
	_advance(0.2)
	var total_hits := 0
	for actor in crowd:
		total_hits += actor.hits
	_check(total_hits == 3, "100体候选中轻扫仍严格最多命中3个（不代表100体帧率验收）")
	_reset()
	_event(true)
	_advance(0.43)
	_event(false)
	_advance(0.2)
	total_hits = 0
	for actor in crowd:
		total_hits += actor.hits
	_check(total_hits == 4, "100体候选中重击只增加一个目标")
	# 普通非近战伤害保持原护甲计算；Boss不额外套穿甲或强制破甲。
	var plain := Target.new()
	plain.armor = 0.4
	_check(is_equal_approx(Damage.armored(plain, 100.0, 0.4), 60.0), "非近战护甲结算不变")
	plain.free()
	for actor in crowd:
		actor.queue_free()
	await _frames(2)
	await _normal_enemy_contract()
	await _boss_contract()
	_reset()
	_event(true)
	_advance(0.2)
	_player._die()
	_check(_melee.phase == "idle", "死亡立即清空近战输入和姿势")
	current_scene = null
	_world.queue_free()
	await process_frame
	print("[玩家近战] checks=", _checks, " failures=", _failures)
	quit(1 if _failures else 0)

func _capture_action() -> void:
	# 有窗口时使用原场景 / 原脚本 / 真鼠标捕获，不使用无窗口输入夹具。
	await _frames(25)
	_player.set_physics_process(false)
	_reset()
	_event(true)
	_event(false)
	_advance(0.12)
	_player._update_presentation(1.0 / 60.0)
	await process_frame
	await RenderingServer.frame_post_draw
	Capture.ensure_dir("player_melee")
	_check(root.get_texture().get_image().save_png(Capture.file("player_melee/sweep.png")) == OK, "正式空格挥扫截图保存")
	_melee.cancel()
	_player.set_physics_process(true)

func _normal_enemy_contract() -> void:
	_reset()
	var enemy := preload("res://scenes/melee_enemy.tscn").instantiate() as CharacterBody3D
	enemy.position = Vector3(0, 1, -2.7)
	_world.add_child(enemy)
	await _frames(2)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.health = 1000.0
	enemy._armor = 0.2
	_event(true)
	_advance(0.43)
	_event(false)
	_advance(0.2)
	_check(is_equal_approx(float(enemy.health), 838.0), "真实普通敌人重击通过护甲入口结算162点")
	_check(enemy._stagger_time >= 0.99, "真实普通敌人重击硬直接入已有反应链")
	enemy.queue_free()
	await _frames(2)

func _boss_contract() -> void:
	var boss := preload("res://prototypes/enemy_prototypes/procedural_sediment_titan.tscn").instantiate() as CharacterBody3D
	boss.position = Vector3(0, 1.7, -3.5)
	boss.add_to_group("boss")
	_world.add_child(boss)
	await _frames(2)
	boss.set_physics_process(false)
	boss.set_process(false)
	boss.has_mud_shield = true
	boss.shield_reduction = 0.8
	boss.is_enraged = false
	boss._tuning.rage_enabled = false
	var before: float = boss.current_hp
	var state: int = boss.current_state
	Telemetry.hurt_enemy(boss, 180.0, {"source_kind": "player", "melee_kind": "heavy", "armor_penetration": 0.5, "managed_reaction": true})
	_check(is_equal_approx(before - float(boss.current_hp), 36.0), "泰坦重击仍受80%泥盾减伤，不套旧占位Boss倍伤")
	_check(boss.has_mud_shield and boss.current_state == state, "近战不擅自移除泥盾或打断Boss阶段")
	boss.queue_free()
	await _frames(2)
