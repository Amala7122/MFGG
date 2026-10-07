extends SceneTree

const SpatialScene := preload("res://prototypes/combat/spatial/combat_spatial_lab.tscn")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
const GroundWarning := preload("res://scenes/ground_warning.tscn")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const StatsView := preload("res://prototypes/combat/combat_lab_stats_view.gd")
const MeleeEffect := preload("res://scripts/prototypes/titan_melee_effect.gd")
class Victim extends Node3D:
	var health := 100.0
var _failed := false
var _lab: Node3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_lab = SpatialScene.instantiate()
	root.add_child(_lab)
	current_scene = _lab
	for _frame in range(8):
		await process_frame
	_lab.set_selection({_lab.FAST_BEAST_ID: 1})
	await _lab.generate_round()
	for _frame in range(4):
		await physics_frame
	paused = true
	_verify_pressure()
	_verify_projection()
	await _verify_reachability()
	_verify_pounce_obstruction()
	await _capture()
	await _verify_enemy_integration()
	await _verify_blocked_enemy()
	current_scene = null
	_lab.queue_free()
	await process_frame
	paused = false
	await create_timer(0.5).timeout
	print("[战斗反馈] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _verify_pressure() -> void:
	var player: CharacterBody3D = _lab._player
	var stats: RefCounted = _lab._stats
	player.health = 100.0
	player.max_health = 100.0
	player.shield = 70.0
	player.max_shield = 70.0
	player._shield_regen_delay = 3.0
	player._shield_regen_rate = 35.0
	player._damage_invulnerability = 0.0
	player.set_meta(&"experiment_invincible", false)
	player.get_pressure_shield()
	player.set_meta(&"experiment_invincible", true)
	stats.start()
	var info := {"id": _lab.FAST_BEAST_ID, "title": "晶兽", "attack": "飞扑"}
	Telemetry.hurt_player(player, 50.0, Vector3.ONE, 0.7, info)
	_check(is_equal_approx(stats.shield_loss, 35.0) and stats.health_loss == 0.0, "无敌也记录护盾倍率后的有效承伤")
	_check(player.health == 100.0 and player.shield == 70.0, "模拟不扣除真实生命护盾")
	Telemetry.hurt_player(player, 50.0, Vector3.ONE, 0.7, info)
	_check(stats.received_hits == 1 and stats.rejected_hits == 1, "同一受击免伤窗口不重复计入")
	player._tick_timers(0.43)
	Telemetry.hurt_player(player, 70.0, Vector3.ONE, 0.7, info)
	_check(is_equal_approx(stats.shield_loss, 70.0) and is_equal_approx(stats.health_loss, 20.0) and stats.shield_breaks == 1,
		"虚拟护盾会耗尽，破盾溢出按原始伤害换算")
	player._tick_timers(0.43)
	Telemetry.hurt_player(player, 150.0, Vector3.ONE, 1.0, info)
	_check(is_equal_approx(stats.health_loss, 170.0) and player.health == 100.0, "无敌长测生命承伤持续累计")
	player._damage_invulnerability = player.dodge_invulnerability
	Telemetry.hurt_player(player, 80.0, Vector3.ONE, 1.0, info)
	_check(stats.received_hits == 3, "翻滚免伤不计入有效承伤")
	player._tick_timers(0.35)
	Telemetry.hurt_player(player, 0.0, Vector3.ONE, 1.0, info)
	Telemetry.hurt_player(player, -20.0, Vector3.ONE, 1.0, info)
	_check(stats.received_hits == 3 and stats.invincible_attempts == 3, "零值和负值不产生模拟受击")
	player._tick_timers(2.7)
	_check(is_equal_approx(player.get_pressure_shield(), 70.0) and is_equal_approx(stats.simulated_shield_regen, 70.0), "停火后按正式规则恢复模拟护盾")
	Telemetry.hurt_player(player, 10.0, Vector3.ONE, 0.7, info)
	_check(is_equal_approx(stats.shield_loss, 77.0), "恢复后的护盾继续吸收下一次攻击")
	player.set_meta(&"experiment_invincible", false)
	player.get_pressure_shield()
	player._damage_invulnerability = 0.0
	Telemetry.hurt_player(player, 50.0, Vector3.ONE, 0.7, info)
	_check(is_equal_approx(player.shield, 35.0) and is_equal_approx(stats.shield_loss - stats.simulated_shield_loss, 35.0), "关闭无敌后实际损失单独可核对")
	player.set_meta(&"experiment_invincible", true)
	player._damage_invulnerability = 0.0
	Telemetry.hurt_player(player, 70.0, Vector3.ONE, 0.7, info)
	_check(is_equal_approx(stats.shield_loss, 147.0) and is_equal_approx(stats.health_loss, 190.0), "重新开启无敌从真实剩余护盾开始模拟")
	var row: Dictionary = stats.incoming[_lab.FAST_BEAST_ID + "/飞扑"]
	var species: Dictionary = stats.species[_lab.FAST_BEAST_ID]
	_check(is_equal_approx(row.shield, 147.0) and is_equal_approx(row.health, 190.0)
		and is_equal_approx(species.shield_loss, 147.0) and is_equal_approx(species.health_loss, 190.0), "兵种和攻击来源统计包含同一模拟承压")
	var snapshot: Dictionary = stats.snapshot()
	_check(is_equal_approx(snapshot.recent5.shield, 147.0) and is_equal_approx(snapshot.recent5.hp, 190.0), "实时窗口包含模拟生命护盾承伤")
	var report := StatsView.report(snapshot)
	_check(report.contains("其中实际损失：生命 0.0 / 护盾 35.0") and report.contains("无敌模拟：生命 190.0 / 护盾 112.0")
		and StatsView.live_text(stats.live_snapshot()).contains("含无敌模拟"), "界面明确区分实际与模拟")
	stats.complete_wave()
	_check(is_equal_approx(stats.last_wave.shield, 147.0), "循环批次使用一致承伤口径")
	stats.paused = true
	player._damage_invulnerability = 0.0
	Telemetry.hurt_player(player, 50.0, Vector3.ONE, 1.0, info)
	_check(player.get_pressure_shield() == 0.0 and stats.received_hits == 6, "暂停不会消耗模拟护盾或记录攻击")
	stats.advance(10.0)
	_check(stats.time == 0.0, "暂停不推进统计时间")
	stats.paused = false
	stats.advance(36.0)
	_check(stats.rolling(5.0).hp == 0.0 and stats.rolling(5.0).shield == 0.0, "滚动窗口按战斗时间过期")
	print("[战斗反馈] 无敌承压、护盾回复、免伤窗口和混合口径通过")


func _verify_projection() -> void:
	var cases := [
		{"name": "坡道矩形", "origin": Vector3(-12, 2.2, 9), "spec": {"kind": "rect", "width": 5.0, "length": 11.0, "height": 4.0}},
		{"name": "1m 台阶圆形", "origin": Vector3(-5, 1.08, -5), "spec": {"kind": "circle", "radius": 4.5, "height": 3.0}},
		{"name": "2m 平台扇形", "origin": Vector3(6, 1.1, 0), "spec": {"kind": "sector", "radius": 8.0, "angle": 120.0, "height": 3.0}},
		{"name": "掩体胶囊", "origin": Vector3(6, 1, 9), "spec": {"kind": "capsule", "radius": 2.5, "length": 8.0, "height": 3.0}, "yaw": -0.2},
		{"name": "悬崖圆形", "origin": Vector3(13, 0.5, -13.5), "spec": {"kind": "circle", "radius": 5.0, "height": 2.5}},
		{"name": "平地圆形", "origin": Vector3(-1, 1, 12), "spec": {"kind": "circle", "radius": 2.0, "height": 2.5}},
	]
	var total_us := 0
	for item: Dictionary in cases:
		var area := AttackArea.new()
		area.process_mode = Node.PROCESS_MODE_DISABLED
		_lab.add_child(area)
		var start := Time.get_ticks_usec()
		area.prepare(Transform3D(Basis(Vector3.UP, float(item.get("yaw", 0.0))), item.origin), item.spec, 20.0)
		total_us += Time.get_ticks_usec() - start
		area.set_progress(0.7)
		_check(area._mesh.mesh != null and area._border.mesh != null, item.name + "生成贴地填充与边界")
		_verify_mesh(area._mesh, item.name + "填充", false)
		_verify_mesh(area._border, item.name + "边界", true)
		_verify_damage_surface(area, item.name)
		if item.name == "平地圆形":
			_check(absf(_projected_area(area._mesh) - PI * 4.0) < 0.1, "细分裁剪保留准确轮廓面积")
			var next_pose := Transform3D(Basis(Vector3.UP, 0.4), Vector3(-12, 2.2, 5))
			area.track(next_pose)
			_check(area.global_transform.is_equal_approx(next_pose), "准备期命中区域立即跟随最新姿态")
			_verify_mesh(area._mesh, "追踪等待期间", false)
		area.lock()
		_check(area._mesh.global_transform.is_equal_approx(area.global_transform), "锁定立即刷新最终贴地姿态")
		var locked_pose := area.global_transform
		area.track(Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
		_check(area.global_transform.is_equal_approx(locked_pose), "锁定后预警不追踪")
		if item.name == "平地圆形":
			area.prepare(Transform3D(Basis.IDENTITY, item.origin), item.spec, 20.0)
			area.set_progress(0.7)
			area.lock()
	var void_area := AttackArea.new()
	_lab.add_child(void_area)
	void_area.prepare(Transform3D(Basis.IDENTITY, Vector3(70, 1, 0)), {"kind": "circle", "radius": 3.0}, 10.0)
	_check(void_area._mesh.mesh == null and void_area._border.mesh == null, "无碰撞地面不制造悬空预警")
	void_area.prepare(Transform3D(Basis.IDENTITY, Vector3(0, 8, 12)), {"kind": "circle", "radius": 2.0, "height": 2.5}, 10.0)
	_check(void_area._mesh.mesh == null, "超出攻击高度窗口不投影到其他楼层")
	void_area.lock()
	_check(void_area.strike() and not void_area.strike() and not void_area.visible, "攻击仅消费一次并隐藏预警")
	void_area.cancel()
	var warning := GroundWarning.instantiate()
	warning.process_mode = Node.PROCESS_MODE_DISABLED
	_lab.add_child(warning)
	warning.global_position = Vector3(-12, 1.2, 5)
	warning.visual_only = true
	warning.setup(2.5, 1.0, 20.0, Color.ORANGE_RED)
	_check(not warning.ring.visible and not warning.disc.visible, "炮击不叠加悬空平面圆环")
	warning.explode()
	_verify_mesh(warning.disc, "炮击爆炸闪光", false)
	_check(warning.disc.mesh == warning._attack_area._mesh.mesh, "炮击闪光复用贴地网格")
	warning.free()
	print("[战斗反馈] 各地形预警网格通过；6 个范围构建 %.1f ms" % (total_us / 1000.0))


func _verify_damage_surface(area: Node3D, label: String) -> void:
	if area._mesh.mesh == null:
		return
	var victim := Victim.new()
	_lab.add_child(victim)
	var vertices: PackedVector3Array = area._mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var valid := true
	var source: Vector3 = area.global_position + Vector3.UP * float(area.shape.get("source_height", 0.2 if String(area.shape.kind) == "circle" else 0.0))
	for i in range(0, vertices.size(), 3):
		victim.global_position = area._mesh.to_global((vertices[i] + vertices[i + 1] + vertices[i + 2]) / 3.0) + Vector3.UP * 0.955
		if not area.can_hit(victim, source):
			valid = false
			break
	_check(valid, label + "画出的每个面中心均可按同一攻击规则命中站立目标")
	victim.free()
	if area._border.mesh != null:
		vertices = area._border.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		valid = true
		for i in range(0, vertices.size(), 6):
			var a := vertices[i]
			var b := vertices[i + 1]
			var along := Vector2(b.x - a.x, b.z - a.z).normalized()
			var side := Vector3(-along.y, 0, along.x) * 0.002
			var center := (a + b) * 0.5
			if area.get_surface().allows(area._border.to_global(center + side)) and area.get_surface().allows(area._border.to_global(center - side)):
				valid = false
				break
		_check(valid, label + "只画真实覆盖边界，不显示内部三角网格线")


func _verify_reachability() -> void:
	for item in [
		{"name": "掩体后", "pose": Vector3(10, 1, 8), "target": Vector3(10, 1, 2), "spec": {"kind": "rect", "width": 3.0, "length": 10.0, "height": 3.0}},
		{"name": "掩体顶边", "pose": Vector3(10, 1, 8), "target": Vector3(10, 3.4, 4.05), "spec": {"kind": "rect", "width": 3.0, "length": 10.0, "height": 3.0}},
		{"name": "独立高台", "pose": Vector3(6, 1.1, 0), "target": Vector3(6, 3.08, -5), "spec": {"kind": "sector", "radius": 8.0, "angle": 120.0, "height": 3.0}},
		{"name": "悬崖对岸", "pose": Vector3(13, 1, -12), "target": Vector3(13, 1, -21), "spec": {"kind": "rect", "width": 4.0, "length": 12.0, "height": 8.0}},
	]:
		var area := AttackArea.new()
		_lab.add_child(area)
		area.prepare(Transform3D(Basis.IDENTITY, item.pose), item.spec, 10.0)
		_check(area.contains(item.target) and not area.can_reach(item.target), item.name + "虽在原始形状内，但不画地面且不结算地面技能命中")
		_verify_damage_surface(area, item.name)
		var stroke := PackedVector2Array([Vector2(-2, 0), Vector2(2, 0), Vector2(2, -12), Vector2(-2, -12)])
		var trace: ArrayMesh = area.get_surface().paint_strokes(area.global_transform, [stroke])
		if trace:
			var vertices: PackedVector3Array = trace.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var valid := true
			for i in range(0, vertices.size(), 3):
				var point: Vector3 = area.to_global((vertices[i] + vertices[i + 1] + vertices[i + 2]) / 3.0)
				if not area.can_reach(point):
					valid = false
					break
			_check(valid, item.name + "攻击笔迹同样裁剪到可达面")
		area.free()
	var ordinary := AttackArea.new()
	_lab.add_child(ordinary)
	ordinary.prepare(Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)), {"kind": "sector", "radius": 2.0, "angle": 120.0, "height": 2.0, "ground_effect": false}, 10.0)
	_check(not ordinary.visible and ordinary._mesh.mesh == null and ordinary.can_reach(Vector3(0, 2, -1)), "普通挥击不生成地面效果，仍保留空间攻击判定")
	ordinary.free()
	var sweep := AttackArea.new()
	_lab.add_child(sweep)
	var spec := {"kind": "sector", "radius": 6.0, "angle": 270.0, "height": 3.0}
	sweep.prepare(Transform3D(Basis.IDENTITY, Vector3(10, 1, 8)), spec, 10.0)
	spec["surface"] = sweep.get_surface()
	var effect: Node3D = MeleeEffect.spawn(_lab, sweep.global_transform, spec, 1.0, true, 1.0)
	effect.set_progress(0.4)
	if effect._trace.mesh != null:
		_verify_mesh(effect._trace, "扫过后笔迹", false)
		var vertices: PackedVector3Array = effect._trace.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var valid := true
		for i in range(0, vertices.size(), 3):
			var local := (vertices[i] + vertices[i + 1] + vertices[i + 2]) / 3.0
			if not sweep.can_reach(effect.to_global(local)):
				valid = false
		_check(valid, "横扫预生成笔迹全部裁剪到可命中路径")
		var saved_mesh: Mesh = effect._trace.mesh
		effect.set_progress(0.45)
		_check(effect._trace.mesh == saved_mesh, "横扫推进复用网格，不每帧重裁剪旧笔迹")
		effect.set_progress(0.4)
		await _verify_sweep_render(effect)
	else:
		_check(false, "横扫实际留下可见笔迹")
	effect.free()
	sweep.free()
	print("[战斗反馈] 可达面、地面技能命中和已扫过笔迹保持一致；普通攻击无地面效果")


func _verify_sweep_render(effect: Node3D) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(320, 320)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var trace := MeshInstance3D.new()
	trace.mesh = effect._trace.mesh
	trace.material_override = effect._trace_material
	viewport.add_child(trace)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = effect.radius * 2.2
	viewport.add_child(camera)
	camera.position = Vector3(0, 20, 0)
	camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	var counts: Array[int] = []
	for progress in [0.0, 0.4, 1.0]:
		effect.set_progress(progress)
		for _frame in range(5):
			await process_frame
		await RenderingServer.frame_post_draw
		var pixels: Image = viewport.get_texture().get_image()
		var count := 0
		var valid := true
		for x in range(320):
			for y in range(320):
				if pixels.get_pixel(x, y).a > 0.1:
					count += 1
					var point := camera.project_position(Vector2(x + 0.5, y + 0.5), 20.0)
					if atan2(point.x, -point.z) > -effect.arc * 0.5 + effect.arc * progress + 0.02:
						valid = false
		_check(valid, "横扫材质实际像素没有提前露出未扫过的区域")
		counts.append(count)
		if OS.get_cmdline_user_args().has("--capture-feedback"):
			DirAccess.make_dir_recursive_absolute("res://visual_captures/combat_feedback")
			pixels.save_png("res://visual_captures/combat_feedback/sweep_%d.png" % roundi(progress * 100))
	_check(counts[0] == 0 and counts[1] > 0 and counts[1] < counts[2], "横扫实际渲染随进度增加，0% 无笔迹、40% 部分、100% 完整")
	print("[战斗反馈] 横扫实际像素 0/40/100%：", counts)
	effect.set_progress(0.4)
	viewport.free()


func _verify_pounce_obstruction() -> void:
	var area := AttackArea.new()
	_lab.add_child(area)
	var body := BoxShape3D.new()
	body.size = Vector3(0.9, 1.55, 1.6)
	area.prepare(Transform3D(Basis.IDENTITY, Vector3(10, 0.8, 8)), {"kind": "capsule", "radius": 1.6, "length": 9.15, "height": 1.6,
		"travel_speed": 11.44, "jump_speed": 4.5, "gravity": 14.0, "flight_time": 0.8, "hit_angle": 90.0, "body_shape": body}, 10.0)
	_check(area.can_reach(Vector3(10, 1, 6)), "飞扑障碍前的真实轨迹仍有预警")
	_check(area.contains(Vector3(10, 1, 2)) and not area.can_reach(Vector3(10, 1, 2)), "飞扑完整身体会撞墙时，墙后不画预警")
	area.free()


func _verify_enemy_integration() -> void:
	_lab._crowd_motion.button_pressed = false
	await _lab.generate_round()
	for _frame in range(4):
		await physics_frame
	_lab._player.position = Vector3(0, 1.08, -8)
	var beast: CharacterBody3D = _lab._live_enemies[0]
	beast.ai_enabled = false
	beast.rotation.y = PI
	_lab._start_fight()
	paused = false
	beast.trigger_pounce()
	for _frame in range(120):
		await physics_frame
	var stats: Dictionary = _lab.get_stats_snapshot()
	_check(stats.invincible_attempts > 0 and stats.shield_loss > 0.0, "实际晶兽攻击也能在无敌状态记录承伤")
	_check(_lab._player.health == _lab._player.max_health and _lab._player.shield == _lab._player.max_shield,
		"真实敌人攻击后玩家仍然保持无敌")
	_check(stats.species[_lab.FAST_BEAST_ID].shield_loss > 0.0 and not stats.incoming.has("unknown/未归属"), "实际攻击正确归属兵种与招式")
	paused = true
	_check(stats.simulated_hits > 0 and stats.received_hits == stats.simulated_hits, "重开本轮清零旧的实际与模拟承伤")
	print("[战斗反馈] 实际敌人战斗承伤通过：生命 %.1f / 护盾 %.1f，%d 次" % [stats.health_loss, stats.shield_loss, stats.received_hits])


func _verify_blocked_enemy() -> void:
	await _lab.generate_round()
	for _frame in range(4):
		await physics_frame
	var beast: CharacterBody3D = _lab._live_enemies[0]
	beast.ai_enabled = false
	beast.rotation.y = PI
	_lab._player.position = Vector3(0, 1.08, -8)
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	wall.position = Vector3(0, 1.2, -9)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(4, 2.4, 0.4)
	collision.shape = shape
	wall.add_child(collision)
	_lab.add_child(wall)
	_lab._start_fight()
	_lab._player.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	for _frame in range(4):
		await physics_frame
	beast.trigger_pounce()
	for _frame in range(100):
		await physics_frame
	_check(_lab.get_stats_snapshot().received_hits == 0 and not beast._attack_area.visible, "真实晶兽不会穿墙飞扑或继续画墙后的范围")
	wall.free()
	paused = true
	print("[战斗反馈] 真实飞扑受墙体阻挡，没有伤害或墙后预警")


func _verify_mesh(instance: MeshInstance3D, label: String, border: bool) -> void:
	if instance.mesh == null:
		_check(false, label + "网格为空")
		return
	var arrays := instance.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var points: Array[Vector3] = []
	for vertex in vertices:
		points.append(instance.to_global(vertex))
	var surface := instance.get_world_3d().direct_space_state
	var valid := true
	for i in range(0, indices.size() if not indices.is_empty() else points.size(), 3):
		var a := points[indices[i] if not indices.is_empty() else i]
		var b := points[indices[i + 1] if not indices.is_empty() else i + 1]
		var c := points[indices[i + 2] if not indices.is_empty() else i + 2]
		for p: Vector3 in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
			var hit := surface.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, 10, p.z), Vector3(p.x, -10, p.z), 1))
			if hit.is_empty() or absf(p.y - float(hit.position.y) - (0.05 if border else 0.045)) > 0.08:
				valid = false
				break
		if not valid:
			break
	_check(valid, label + "顶点、边中点及面中心贴合实际地面，断层不连面")


func _projected_area(instance: MeshInstance3D) -> float:
	var arrays := instance.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var area := 0.0
	for i in range(0, indices.size() if not indices.is_empty() else vertices.size(), 3):
		var a := vertices[indices[i] if not indices.is_empty() else i]
		var b := vertices[indices[i + 1] if not indices.is_empty() else i + 1]
		var c := vertices[indices[i + 2] if not indices.is_empty() else i + 2]
		area += absf(Vector2(b.x - a.x, b.z - a.z).cross(Vector2(c.x - a.x, c.z - a.z))) * 0.5
	return area


func _capture() -> void:
	if not OS.get_cmdline_user_args().has("--capture-feedback") or DisplayServer.get_name() == "headless":
		return
	_lab._interface.visible = false
	_lab._weapon_plate.visible = false
	_lab._player.aim_ui.visible = false
	_lab._overview.current = true
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	var directory := "res://visual_captures/combat_feedback"
	DirAccess.make_dir_recursive_absolute(directory)
	root.get_texture().get_image().save_png(directory.path_join("01_terrain_warnings.png"))
	_lab._overview.global_position = Vector3(-21, 12, 16)
	_lab._overview.look_at(Vector3(-12, 0.7, 2))
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join("02_slope_warning.png"))
	_lab._interface.visible = true
	_lab._countdown.visible = false
	_lab._countdown_hint.visible = false
	_lab._panel.visible = false
	_lab._stats_panel.visible = true
	_lab._stats_report.text = StatsView.report(_lab.get_stats_snapshot())
	for _frame in range(5):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join("03_pressure_statistics.png"))


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[战斗反馈] " + message)
