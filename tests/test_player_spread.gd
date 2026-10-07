extends SceneTree
## T01：真实连射节奏、物理命中及相机 / HUD 投影。仅省去音效与命中表现。

const Weapon := preload("res://scripts/player_weapon.gd")
const Crosshair := preload("res://scripts/dynamic_crosshair.gd")

class Target extends CharacterBody3D:
	var hit_count := 0
	func take_damage(_amount: float) -> void:
		hit_count += 1

class RecordingWeapon extends "res://scripts/player_weapon.gd":
	var directions: Array[Vector3] = []
	var query_hits := true
	func fire() -> void:
		if _aiming:
			_fire_sniper(-_camera.global_basis.z)
			_sniper_ammo -= 1
		else:
			_fire_rapid(-_camera.global_basis.z)
			_ammo -= 1
	func _fire_hitscan(direction: Vector3, sniper: bool) -> void:
		directions.append(direction)
		if query_hits:
			for hit: Dictionary in _resolve_shot_hits(direction, sniper):
				if hit.is_enemy:
					hit.collider.take_damage(hit.amount)

class LegacyWeapon extends RecordingWeapon:
	func get_current_spread_degrees() -> float:
		return (base_spread_degrees + _bloom) * (1.0 + _movement_ratio * 1.8)

var _failed := false
var _viewport: SubViewport
var _world: Node3D
var _camera: Camera3D
var _host: CharacterBody3D
var _weapon: RecordingWeapon
var _crosshair: Control
var _canvas: CanvasLayer


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	paused = false
	(root.get_node("GameFlow") as CanvasLayer).hide()
	await _fixture()
	_independent_movement()
	await _projection_cases()
	await _window_scale_cases()
	await _dispose()
	await _running_accuracy()
	print("[T01] 移动散布与准星回归：", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _fixture(legacy: bool = false) -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1152, 648)
	_viewport.own_world_3d = true
	root.add_child(_viewport)
	_world = Node3D.new()
	_viewport.add_child(_world)
	current_scene = _viewport
	_host = CharacterBody3D.new()
	_host.position = Vector3(0, 1, 0)
	_world.add_child(_host)
	# 与第三人称的空间关系相同，目标距离从玩家而非相机计量。
	var model := Node3D.new()
	model.name = "PlayerModel"
	_host.add_child(model)
	var rig := Node3D.new()
	rig.name = "WeaponRig"
	rig.position = Vector3(0, 0.6, 0)
	model.add_child(rig)
	var recoil := Node3D.new()
	recoil.name = "RecoilPivot"
	rig.add_child(recoil)
	var muzzle := Node3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0.4, 0, -0.8)
	recoil.add_child(muzzle)
	_camera = Camera3D.new()
	_camera.position = Vector3(0, 1.0, 4.5)
	_camera.fov = 70.0
	_world.add_child(_camera)
	_weapon = LegacyWeapon.new() if legacy else RecordingWeapon.new()
	_host.add_child(_weapon)
	_weapon.setup(_host, _camera)
	_weapon._rng.seed = 71001
	_canvas = CanvasLayer.new()
	_viewport.add_child(_canvas)
	_crosshair = Crosshair.new()
	_crosshair.camera = _camera
	_canvas.add_child(_crosshair)
	await physics_frame
	await physics_frame


func _independent_movement() -> void:
	for level in [1, 4, 12]:
		_weapon._weapon_level = level
		for bloom in [0.0, 2.0, _weapon.max_bloom_degrees]:
			_weapon._bloom = bloom
			_weapon.update(0.0, false, false, 0.0)
			var standing := _weapon.get_current_spread_degrees()
			_weapon.update(0.0, false, false, 1.0)
			var running := _weapon.get_current_spread_degrees()
			_weapon.update(0.0, false, false, 1.7)
			var sprinting := _weapon.get_current_spread_degrees()
			_check(is_equal_approx(running - standing, _weapon.movement_spread_degrees), "移动增加量不随 bloom / 等级放大")
			_check(is_equal_approx(sprinting - standing, _weapon.movement_spread_degrees * 1.6), "疾跑独立增加量有速度上限")
	# 松开扳机仍实时反映移动；停步立即去掉移动项，bloom 按原速度回收。
	_weapon.update(0.2, false, false, 0.0)
	_check(is_equal_approx(_weapon.get_current_spread_degrees(), _weapon.base_spread_degrees + maxf(_weapon.max_bloom_degrees - 0.2 * _weapon.bloom_decay, 0.0)), "停步与连射回复独立")
	_weapon.update(0.0, false, true, 1.6)
	_check(_weapon.get_spread_angles_degrees() == Vector2.ZERO, "狙击显示零散布，不继承主武器 bloom / 移动")
	_weapon.directions.clear()
	_weapon.fire()
	_check(_weapon.directions.size() == 1 and _weapon.directions[0].is_equal_approx(-_camera.global_basis.z), "狙击实际弹道零散布")
	_weapon.update(0.0, false, false, 1.6)
	_check(_weapon.get_spread_angles_degrees().x > _weapon.base_spread_degrees, "退出狙击恢复主武器完整散布")


func _projection_cases() -> void:
	_weapon.query_hits = false
	_weapon._weapon_level = 12
	for viewport_size in [Vector2i(1152, 648), Vector2i(1024, 768), Vector2i(2560, 1080)]:
		_viewport.size = viewport_size
		await process_frame
		for keep_aspect in [Camera3D.KEEP_HEIGHT, Camera3D.KEEP_WIDTH]:
			_camera.keep_aspect = keep_aspect
			for fov in [26.0, 70.0, 100.0]:
				_camera.fov = fov
				for ui_scale in [0.85, 1.0, 1.3]:
					_canvas.transform = Transform2D.IDENTITY.scaled(Vector2.ONE * ui_scale)
					for pitch in [-75.0, 0.0, 65.0]:
						_camera.rotation_degrees = Vector3(pitch, 37.0, 12.0)
						_weapon._bloom = _weapon.max_bloom_degrees
						_weapon.update(0.0, false, false, 1.6)
						_crosshair.spread_angles_degrees = _weapon.get_spread_angles_degrees()
						_check_projection("视口 / FOV / UI 缩放 / 俯仰")
	# 多弹丸类型的准星必须包含外侧图案，单弹丸不凭空添加图案宽度。
	_weapon._class_traits = {"pellet_curve": "pellet_count", "pattern_spread_curve": "pattern_spread"}
	_crosshair.spread_angles_degrees = _weapon.get_spread_angles_degrees()
	_check_projection("多弹丸图案")
	_weapon._class_traits = {"pattern_spread_curve": "pattern_spread"}
	_check(is_equal_approx(_weapon.get_spread_angles_degrees().x, _weapon.get_current_spread_degrees()), "单弹丸忽略没有发射的扇形图案")
	# 连续开火实际采样：极大俯仰时仍沿相机轴展开，边界没有归一化截断。
	for pitch in [-75.0, 0.0, 65.0]:
		_camera.rotation_degrees = Vector3(pitch, 37.0, 12.0)
		_weapon._class_traits = {}
		_weapon._bloom = _weapon.max_bloom_degrees
		_crosshair.spread_angles_degrees = _weapon.get_spread_angles_degrees()
		_weapon.directions.clear()
		for shot in range(1024):
			_weapon._fire_rapid(-_camera.global_basis.z)
		var extent: Vector2 = _crosshair.get_spread_half_extent()
		var center: Vector2 = _crosshair.get_aim_center()
		var inverse := _crosshair.get_global_transform_with_canvas().affine_inverse()
		var measured := Vector2.ZERO
		for direction: Vector3 in _weapon.directions:
			var offset: Vector2 = (inverse * _camera.unproject_position(_camera.global_position + direction * 10.0) - center).abs()
			_check(offset.x <= extent.x + 0.02 and offset.y <= extent.y + 0.02, "实际弹丸不超出准星边界")
			measured = measured.max(offset)
		_check(measured.x > extent.x * 0.95 and measured.y > extent.y * 0.95, "大俯仰实际散布仍与准星边界相符")
	print("[T01] 准星投影：162 组相机 / UI 条件及 3072 发实际弹道通过")


func _check_projection(label: String) -> void:
	var angles: Vector2 = _weapon.get_spread_angles_degrees()
	var extent: Vector2 = _crosshair.get_spread_half_extent()
	var center: Vector2 = _crosshair.get_aim_center()
	var inverse := _crosshair.get_global_transform_with_canvas().affine_inverse()
	for yaw_sign in [-1.0, 1.0]:
		for pitch_sign in [-1.0, 1.0]:
			var yaw := deg_to_rad(angles.x * yaw_sign)
			var pitch := deg_to_rad(angles.y * pitch_sign)
			# 从局部弹道独立构造四角，再直接投影；避免把待测准星函数当参考。
			var local_direction := Vector3(-sin(yaw), cos(yaw) * sin(pitch), -cos(yaw) * cos(pitch))
			var corner := _camera.unproject_position(_camera.global_position + _camera.global_basis * local_direction * 10.0)
			var offset: Vector2 = (inverse * corner - center).abs()
			_check(offset.distance_to(extent) < 0.03, label + "：四角与线段内沿一致")


func _window_scale_cases() -> void:
	var previous_camera := _camera
	var previous_crosshair := _crosshair
	var window_world := Node3D.new()
	root.add_child(window_world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.02, 0.02, 0.02)
	window_world.add_child(environment)
	_camera = Camera3D.new()
	window_world.add_child(_camera)
	_camera.make_current()
	var canvas := CanvasLayer.new()
	window_world.add_child(canvas)
	_crosshair = Crosshair.new()
	_crosshair.camera = _camera
	canvas.add_child(_crosshair)
	_weapon._class_traits = {}
	# 使用正式窗口的 content_scale_factor，而不仅是单独控件的缩放。
	root.size = Vector2i(1920, 1080)
	for ui_scale in [0.85, 1.0, 1.3]:
		root.content_scale_factor = ui_scale
		for state in ["idle", "running", "running_bloom", "sniper"]:
			var aiming: bool = state == "sniper"
			_weapon._bloom = _weapon.max_bloom_degrees if state == "running_bloom" else 0.0
			_weapon.update(0.0, false, aiming, 0.0 if state == "idle" else 1.6)
			_crosshair.spread_angles_degrees = _weapon.get_spread_angles_degrees()
			_crosshair.aiming = aiming
			_camera.fov = 26.0 if aiming else 70.0
			await process_frame
			await process_frame
			var center: Vector2 = _crosshair.get_aim_center()
			_check(center.distance_to(_crosshair.size * 0.5) < 0.03, "实际窗口缩放不移动屏幕中心")
			_check_projection("实际窗口缩放")
			if DisplayServer.get_name().to_lower() != "headless":
				await RenderingServer.frame_post_draw
				var capture := root.get_texture().get_image()
				_check_rendered_extent(capture)
				if OS.get_cmdline_user_args().has("--capture-spread") and is_equal_approx(ui_scale, 1.0):
					var folder := ProjectSettings.globalize_path("res://../visual_captures/t01_spread")
					DirAccess.make_dir_recursive_absolute(folder)
					capture.save_png(folder.path_join(state + ".png"))
	print("[T01] 实际窗口 1080p / 85–130% UI 缩放通过；图形运行另检查准星像素")
	window_world.queue_free()
	await process_frame
	_camera = previous_camera
	_crosshair = previous_crosshair


func _check_rendered_extent(capture: Image) -> void:
	_check(not capture.is_empty(), "实际图形窗口有渲染结果")
	if capture.is_empty():
		return
	var transform := root.get_final_transform() * _crosshair.get_global_transform_with_canvas()
	var center: Vector2 = _crosshair.get_aim_center()
	var extent: Vector2 = _crosshair.get_spread_half_extent()
	var center_pixel := transform * center
	var expected_edge := transform * (center + Vector2(extent.x + Crosshair.LINE_LENGTH, 0.0))
	if extent.is_zero_approx():
		expected_edge = transform * (center + Vector2(2.8, 0.0))
	var scan_radius := ceili(center_pixel.distance_to(expected_edge)) + 5
	var rightmost := -1
	var top := maxi(int(center_pixel.y) - scan_radius, 0)
	var bottom := mini(int(center_pixel.y) + scan_radius, capture.get_height() - 1)
	var left := maxi(int(center_pixel.x) - scan_radius, 0)
	var right := mini(int(center_pixel.x) + scan_radius, capture.get_width() - 1)
	for y in range(top, bottom + 1):
		for x in range(left, right + 1):
			var color := capture.get_pixel(x, y)
			if maxf(color.r, maxf(color.g, color.b)) > 0.6:
				rightmost = maxi(rightmost, x)
	_check(rightmost >= 0 and absf(float(rightmost) - expected_edge.x) < 3.0, "实际准星像素与投影边界一致：外沿 %d / 预期 %.2f，UI 缩放没有重复放大" % [rightmost, expected_edge.x])


func _running_accuracy() -> void:
	for level in [1, 12]:
		for distance in [1.0, 3.0, 5.0, 10.0]:
			var rates: Array[float] = []
			for legacy in [true, false]:
				await _fixture(legacy)
				_weapon._weapon_level = level
				var target := Target.new()
				target.position = Vector3(0, 1, -distance)
				target.collision_layer = 4
				target.collision_mask = 0
				target.add_to_group("enemies")
				var collision := CollisionShape3D.new()
				var shape := CapsuleShape3D.new()
				shape.radius = 0.5
				shape.height = 2.0
				collision.shape = shape
				target.add_child(collision)
				_world.add_child(target)
				await physics_frame
				await physics_frame
				# 20 次真实节奏的 30 发弹匣，按实际疾跑速度绕固定目标移动，重瞄身体中心。
				for magazine in range(20):
					_weapon._bloom = 0.0
					_weapon._fire_cooldown = 0.0
					_weapon._ammo = 30
					_weapon._reload_timer = 0.0
					_weapon._rng.seed = 71001 + magazine
					var tick := 0
					var run_speed := 5.0 * 1.7
					while _weapon._ammo > 0 and tick < 600:
						var angle: float = float(tick) / 60.0 * run_speed / float(distance)
						var radial := Vector3(sin(angle), 0, cos(angle))
						_host.position = target.position + radial * distance
						_host.velocity = Vector3(cos(angle), 0, -sin(angle)) * run_speed
						_camera.position = _host.position + radial * 4.5
						_camera.look_at(target.position)
						_weapon.update(1.0 / 60.0, true, false, Vector2(_host.velocity.x, _host.velocity.z).length() / 5.0)
						tick += 1
				_check(_weapon.directions.size() == 600, "正常连射节奏打完弹匣")
				rates.append(float(target.hit_count) / 600.0)
				await _dispose()
			print("[T01] L%d 疾跑扫射 %.0fm，旧 %.1f%% → 新 %.1f%%（600 发）" % [level, distance, rates[0] * 100.0, rates[1] * 100.0])
			_check(rates[1] >= rates[0] - 0.01, "疾跑首发与持续扫射不退步")
			if level == 12 and distance <= 5.0:
				_check(rates[1] > rates[0] + 0.2, "高等级近距离扫射至少提升 20 个百分点")


func _dispose() -> void:
	current_scene = null
	_viewport.queue_free()
	await process_frame
	await physics_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[T01] " + message)
