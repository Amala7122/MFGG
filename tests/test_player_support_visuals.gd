extends SceneTree
## 正式玩家 / 组件 / 伤害链；无窗口仅替换鼠标捕获前置，有窗口不使用夹具。
const Settings := preload("res://scripts/player_support_settings.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Capture := preload("res://scripts/capture_paths.gd")
var _world: Node3D
var _player: CharacterBody3D
var _wisp: Node3D
var _shield: Node3D
var _checks := 0
var _failures := 0

class Target extends StaticBody3D:
	# 不暴露 health 属性，覆盖新版 HealthUtil 对泰坦式生命接口的支持。
	var current_hp := 1000.0
	func get_health() -> float:
		return current_hp
	func take_damage(amount: float) -> void:
		current_hp -= amount

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(message)
	else:
		print("PASS ", message)

func _frames(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame

func _target(at: Vector3) -> Target:
	var target := Target.new()
	target.position = at
	target.position.y = maxf(at.y, Terrain.height_at(at.x, at.z) + 1.0)
	target.collision_layer = 4
	target.add_to_group("enemies")
	var collision := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	collision.shape = sphere
	target.add_child(collision)
	_world.add_child(target)
	return target

func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()

func _run() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	var ground := Terrain.height_at(0, 0)
	var floor := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	collision.shape = box
	floor.add_child(collision)
	floor.position.y = ground - 0.5
	_world.add_child(floor)
	if DisplayServer.get_name() != "headless":
		var mesh := MeshInstance3D.new()
		var floor_mesh := BoxMesh.new()
		floor_mesh.size = box.size
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.19, 0.25, 0.23)
		floor_mesh.material = mat
		mesh.mesh = floor_mesh
		floor.add_child(mesh)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-45, -25, 0)
		sun.light_energy = 1.4
		_world.add_child(sun)
		var environment := WorldEnvironment.new()
		environment.environment = Environment.new()
		environment.environment.background_mode = Environment.BG_COLOR
		environment.environment.background_color = Color(0.06, 0.09, 0.13)
		environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.environment.ambient_light_color = Color(0.75, 0.85, 1)
		environment.environment.ambient_light_energy = 0.6
		_world.add_child(environment)
	_player = preload("res://scenes/player.tscn").instantiate()
	if DisplayServer.get_name() == "headless":
		_player.set_script(preload("res://tests/fixtures/player_melee_input_host.gd"))
	_player.position = Vector3(0, ground + 0.9, 0)
	_world.add_child(_player)
	await _frames(3)
	var flow := root.get_node("GameFlow")
	flow._resume_play()
	_player.set_physics_process(false)
	_wisp = _player._wisp
	_wisp.set_physics_process(false)
	_shield = _player._shield_fx
	_shield.set_process(false)
	_check(not _shield.active and not _shield.mesh.visible, "护盾默认隐藏，不是常驻无敌罩")
	_check(_wisp.drone_scale == 2.0 and _wisp._model_pivot.scale.is_equal_approx(Vector3.ONE * 2.0), "卫士按旧版2倍模型接入")
	_check(_wisp._halo_ring != null and (_wisp._drone_body.get_node("DorsalCowl").material_override as StandardMaterial3D).albedo_color.r > 0.9, "白色装甲与守护光环已接入")
	var rotation: float = _wisp._halo_ring.rotation.y
	_wisp._update_idle_animation(0.1)
	_check(not is_equal_approx(_wisp._halo_ring.rotation.y, rotation), "光环实际旋转，不是仅有静态节点")
	var gameplay := [_wisp.base_damage, _wisp.fire_rate, _wisp.attack_range, _wisp.projectile_speed, _wisp.ceasefire_min_enemies]
	var draft := Settings.load_values()
	draft.wisp_scale = 1.8
	_wisp.configure_visuals(draft)
	_check(gameplay == [_wisp.base_damage, _wisp.fire_rate, _wisp.attack_range, _wisp.projectile_speed, _wisp.ceasefire_min_enemies], "表现草稿不改伤害、射速、射程、弹速或末只停火阈值")
	_wisp.configure_visuals(Settings.load_values())
	_follow()
	await _targeting()
	_shield_damage()
	await _panel()
	if DisplayServer.get_name() != "headless":
		await _graphics()
	var panel: CanvasLayer = _player._support_panel
	panel.open()
	panel.free()
	_check(not paused and not root.get_node("GameFlow").has_meta(&"player_visual_tuning_modal") and _wisp.visual_preview_mode == -1, "面板退出树时释放暂停、模态标记与纯视觉超频覆盖")
	_player._damage_invulnerability = 0.0
	_player.shield = 5.0
	_player.health = 1.0
	_player.take_damage(100.0, _player.position + Vector3.RIGHT * 4.0)
	_check(_player._dying and not _shield.active and not _shield.mesh.visible, "死亡立即清除护盾球壳")
	current_scene = null
	_world.queue_free()
	await process_frame
	print("[卫士与能量护盾] checks=", _checks, " failures=", _failures)
	quit(1 if _failures else 0)

func _follow() -> void:
	for aiming in [false, true]:
		_player._aiming = aiming
		_player._sprinting = false
		for _i in range(60):
			_player._update_camera(1.0 / 60.0)
		_wisp.global_position = _player.position + Vector3.UP * 20
		_wisp._update_follow_movement(1.0 / 60.0)
		var offset: Vector3 = _wisp._follow_offset(aiming)
		var forward: Vector3 = -_player.camera.global_basis.z
		forward.y = 0.0
		forward = forward.normalized()
		var right: Vector3 = _player.camera.global_basis.x
		right.y = 0.0
		right = right.normalized()
		var expected := _player.global_position + Basis(right, Vector3.UP, -forward).orthonormalized() * offset
		_check(_wisp.global_position.distance_to(expected) < 0.01, "普通 / ADS 跟随位置使用同一配置：%s" % aiming)
		var camera_forward: Vector3 = -_player.camera.global_basis.z.normalized()
		var camera_offset: Vector3 = _wisp.global_position - _player.camera.global_position
		var ray_distance := (camera_offset - camera_forward * camera_offset.dot(camera_forward)).length()
		_check(ray_distance > 0.6, "默认2倍卫士的保守包围球避开普通 / ADS 准星射线：%s" % aiming)
	_player._aiming = false

func _targeting() -> void:
	var rear := _target(_player.position + Vector3(0, 0, 6))
	var side := _target(_player.position + Vector3(-5, 0, 2))
	await _frames(2)
	_wisp._attack_cooldown = 999
	_wisp._update_targeting_and_combat(1.0 / 60.0)
	_wisp._update_visual_state(0.0)
	_check(_wisp._current_target != null, "保留 get_health 生命接口目标的真实索敌")
	_check(_wisp._model_pivot.scale.is_equal_approx(Vector3.ONE * 2.0), "转向没有丢失2倍模型缩放")
	var base_damage: float = _wisp.base_damage
	var base_range: float = _wisp.attack_range
	_wisp.apply_overclock()
	_check(_wisp.base_damage == base_damage + 4.0 and is_equal_approx(_wisp.attack_range, base_range * 1.3), "超频原有数值规则保留")
	_wisp._fire_spirit_dart(rear)
	_wisp._update_visual_state(0.5)
	_check(is_equal_approx(_wisp._light.light_energy, 3.2) and _wisp._lens_material.emission_energy_multiplier >= 9.0, "超频开火脉冲结束不回落到旧普通亮度")
	# 同一真实分支复测每帧写回，不能只检查 apply_overclock 的瞬时值。
	for _i in range(30):
		_wisp._update_targeting_and_combat(1.0 / 60.0)
		_wisp._update_visual_state(1.0 / 60.0)
	_check(_wisp._lens_material.emission_energy_multiplier >= 9.0, "持续索敌不会覆盖超频透镜亮度")
	rear.current_hp = 0.0
	_wisp._update_targeting_and_combat(1.0 / 60.0)
	_wisp._update_visual_state(0.0)
	_check(_wisp._current_target == null, "已死 get_health 目标排除后仅剩一只，按新版规则停火")
	_check(_wisp._lens_material.emission_energy_multiplier >= 9.0, "末只停火仍保留超频外观")
	for child in _world.get_children():
		if child is FloatingWisp.WispDart:
			child.queue_free()
	rear.queue_free()
	side.queue_free()
	await _frames(2)

func _shield_damage() -> void:
	_player.shield = 70.0
	_player.health = 100.0
	_player._damage_invulnerability = 0.0
	_player._rig._hit_flash_remaining = 0.0
	_shield.cancel()
	_player.take_damage(20.0, _player.position + Vector3.RIGHT * 5.0)
	_check(_player.shield == 50.0 and _player.health == 100.0 and _shield.active, "真实护盾吸收时才显示球壳，结算不改")
	_check(_player._rig._hit_flash_remaining == 0.0, "护盾全吸收仍不播身体白闪")
	var local: Vector3 = _shield.material.get_shader_parameter("hit_direction_local")
	_check((_shield.mesh.global_basis * local).normalized().dot(Vector3.RIGHT) > 0.99, "受击方向正确从世界映射到护盾局部")
	var count: int = _shield.trigger_count
	_player.take_damage(20.0, _player.position + Vector3.LEFT * 5.0)
	_check(_shield.trigger_count == count and _player.shield == 50.0, "无敌帧免伤不伪造新的护盾吸收")
	var alpha: float = _shield.material.get_shader_parameter("shield_alpha")
	_shield.sample(float(_shield.parameters.shield_duration) * 0.5)
	_check(_shield.mesh.visible and float(_shield.material.get_shader_parameter("shield_alpha")) < alpha, "护盾在配置时长内渐隐")
	_shield.sample(float(_shield.parameters.shield_duration))
	_check(not _shield.active and not _shield.mesh.visible, "达到时长完全隐藏，不残留球壳")
	_player._damage_invulnerability = 0.0
	_player.shield = 5.0
	_player.take_damage(10.0, _player.position + Vector3.BACK * 4.0, 0.7)
	_check(is_equal_approx(_player.health, 100.0 - (10.0 - 5.0 / 0.7)) and _player.shield == 0.0 and _shield.active, "破盾溢出保留0.7倍率语义，已吸收部分仍有反馈")
	_check(_player._rig._hit_flash_remaining > 0.0, "破盾溢出生命伤害仍播身体白闪")
	_shield.cancel()
	_player._damage_invulnerability = 0.0
	count = _shield.trigger_count
	_player.take_damage(1.0, _player.position + Vector3.LEFT * 4)
	_check(_shield.trigger_count == count and not _shield.active, "无盾纯生命伤害不显示护盾")
	_player.shield = 70.0
	_player._damage_invulnerability = 0.0
	_player.set_meta(&"experiment_invincible", true)
	_player.take_damage(5.0, _player.position + Vector3.LEFT * 4)
	_check(_player.shield == 70.0 and not _shield.active, "实验无敌未扣盾，不伪造球壳吸收")
	_player.remove_meta(&"experiment_invincible")
	_player.rotation.y = PI * 0.5
	_shield.trigger(Vector3.RIGHT, 10)
	local = _shield.material.get_shader_parameter("hit_direction_local")
	_check((_shield.mesh.global_basis * local).normalized().dot(Vector3.RIGHT) > 0.999, "玩家转向后世界 / 局部受击方向仍正确")
	_shield.sample(0.1)
	var weak: float = _shield.material.get_shader_parameter("hit_intensity")
	_shield.trigger(Vector3.RIGHT, 40)
	_shield.sample(0.1)
	_check(float(_shield.material.get_shader_parameter("hit_intensity")) > weak, "相同时间的吸收强度差异保留，未被逐帧常数覆盖")
	_player.rotation.y = 0
	_shield.cancel()

func _panel() -> void:
	_player.health = 100.0
	_player.shield = 70.0
	_key(KEY_F8)
	var panel: CanvasLayer = _player._support_panel
	_check(panel.opened and paused, "真实F8打开面板并暂停战斗")
	if not panel.opened:
		return
	var background := panel._root.get_node("SupportParameters").get_theme_stylebox("panel") as StyleBoxFlat
	_check(background != null and background.bg_color.a == 1.0 and panel.layer > 100, "调参区不透出小地图并位于游戏HUD之上")
	_check(not _player._melee._panel.opened, "F8不误开F7近战面板")
	var gameplay := [_wisp.base_damage, _wisp.attack_range, _wisp._overclock_mult]
	panel._overclock_preview.button_pressed = false
	_check(is_equal_approx(_wisp._light.light_energy, float(panel.parameters.wisp_light_energy)), "超频玩家也可预览普通外观")
	panel._overclock_preview.button_pressed = true
	_check(gameplay == [_wisp.base_damage, _wisp.attack_range, _wisp._overclock_mult] and _wisp._lens_material.emission_energy_multiplier >= 9.0, "快速超频预览只改外观，不授予或撤回赐福")
	var original := Settings.load_values()
	panel._fields.wisp_scale.value = 1.7
	_check(is_equal_approx(_wisp._model_pivot.scale.x, 1.7) and Settings.load_values().wisp_scale == original.wisp_scale, "尺寸草稿即时生效但未写项目默认")
	_check(panel.parameters.shield_line_thickness == original.shield_line_thickness, "未编辑的护盾字段不被控件取整写回")
	var health: float = _player.health
	var shield: float = _player.shield
	panel._direction_preview("左侧")
	panel._seek(0.2)
	_check(_shield.active and _player.health == health and _player.shield == shield, "指定方向重播 / 定位共用正式效果，不扣血盾")
	panel._loop.button_pressed = true
	panel._direction_preview("正面")
	panel._process(float(panel.parameters.shield_duration) + 0.05)
	_check(_shield.active and panel._preview_running and _player.health == health, "暂停中的循环重播实际续播，且不造成伤害")
	panel._loop.button_pressed = false
	panel._process(float(panel.parameters.shield_duration) + 0.05)
	_check(not _shield.active and not panel._preview_running, "关闭循环后按时结束预览")
	panel._reload()
	_check(_wisp.drone_scale == original.wisp_scale and panel._status.text.begins_with("与项目默认一致"), "重读撤销草稿且状态一致")
	if ProjectSettings.globalize_path("res://").replace("\\", "/").contains("/tmp/project/"):
		panel._fields.wisp_scale.value = 1.7
		panel._save()
		_check(Settings.load_values().wisp_scale == 1.7 and panel._status.text.begins_with("与项目默认一致"), "显式保存写入隔离项目并回读一致")
		var fresh_wisp := FloatingWisp.new()
		_world.add_child(fresh_wisp)
		fresh_wisp.setup(_player, _player.camera)
		_check(is_equal_approx(fresh_wisp._model_pivot.scale.x, 1.7), "新建正式卫士组件读取已保存尺寸，不依赖面板临时值")
		fresh_wisp.queue_free()
		panel.apply_parameters(original)
		panel._save()
		_check(Settings.load_values() == original, "保存后恢复基线参数，没有改其他配置段")
	_key(KEY_ESCAPE)
	_check(not paused and not panel.opened and not _shield.active and not root.get_node("GameFlow").has_meta(&"player_visual_tuning_modal"), "Esc关闭F8并清除预览与暂停状态")
	_key(KEY_F7)
	_check(_player._melee._panel.opened and not panel.opened, "F7近战面板保持独立可用")
	_key(KEY_F8)
	_check(not panel.opened, "F7已打开时F8不叠加另一个暂停面板")
	_key(KEY_ESCAPE)
	await process_frame

func _capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	Capture.ensure_dir("player_support")
	_check(root.get_texture().get_image().save_png(Capture.file("player_support/" + name + ".png")) == OK, "图形截图 " + name)

func _graphics() -> void:
	# 机制用例确实受过伤；不要把未推进的 HUD 蓝闪 / 身体白闪当作视觉基线。
	var spawn := _player.global_position
	_player.queue_free()
	await _frames(3)
	_player = preload("res://scenes/player.tscn").instantiate()
	_player.position = spawn
	_world.add_child(_player)
	await _frames(90)
	_player.set_physics_process(false)
	_wisp = _player._wisp
	_wisp.set_physics_process(false)
	_shield = _player._shield_fx
	_shield.set_process(false)
	_player._aiming = false
	for _i in range(60):
		_player._update_camera(1.0 / 60.0)
	_wisp._update_follow_movement(1.0)
	_player._update_presentation(1.0 / 60.0)
	await _capture("hip_wisp")
	_player._aiming = true
	for _i in range(60):
		_player._update_camera(1.0 / 60.0)
	_wisp._update_follow_movement(1.0)
	await _capture("ads_wisp")
	_player._aiming = false
	# 独立细节机位不受正式 SpringArm 内部物理回写，正式相机不改。
	var detail_camera := Camera3D.new()
	_world.add_child(detail_camera)
	detail_camera.global_position = _player.global_position + Vector3(0, 1.1, 6.5)
	detail_camera.look_at(_player.global_position + Vector3.UP * 0.05)
	detail_camera.fov = 60
	detail_camera.make_current()
	_shield.trigger(Vector3.BACK, 15)
	_shield.sample(0.08)
	await _capture("shield_contact")
	_shield.trigger(Vector3.RIGHT, 15)
	_shield.sample(0.08)
	await _capture("shield_side")
	_shield.cancel()
	_key(KEY_F8)
	_player._support_panel._direction_preview("背后")
	_player._support_panel._scrub.value = 0.15
	await _capture("panel")
	_key(KEY_ESCAPE)
