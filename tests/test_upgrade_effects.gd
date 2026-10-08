extends SceneTree
## 选卡事件 -> 真实瞬发命中 / 护盾计时 / 共鸣爆发 / 持续领域。

const PlayerScene := preload("res://scenes/player.tscn")
const RunState := preload("res://scripts/run_state.gd")
const EventBus := preload("res://scripts/event_bus.gd")
const Flow := preload("res://scripts/game_flow.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Health := preload("res://scripts/health_util.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const CapturePaths := preload("res://scripts/capture_paths.gd")
const Pool := preload("res://scripts/object_pool.gd")
const MudGolem := preload("res://scripts/prototypes/procedural_mud_golem.gd")
const HoldReaction := preload("res://data/combat_reactions/hold_anchored.tres")
const Feedback := preload("res://scripts/combat_fx.gd")
const Config := preload("res://scripts/game_config.gd")
const Arena := preload("res://scripts/arena.gd")

class Target extends CharacterBody3D:
	var health := 10000.0
	var max_health := 10000.0
	var _armor := 0.0
	var last_context: Dictionary = {}
	func take_damage(amount: float) -> void:
		last_context = get_meta(Telemetry.CONTEXT, {}).duplicate()
		health = maxf(health - amount, 0.0)

class HealthAccessor extends Node:
	func get_health() -> float:
		return 25.0
	func get_max_health() -> float:
		return 100.0

class SlowTarget extends CharacterBody3D:
	var health := 10000.0
	var move_speed := 10.0
	func take_damage(amount: float) -> void:
		health -= amount

var _failed := false
var _world: Node3D
var _player: CharacterBody3D
var _camera: Camera3D
var _ground_y := 0.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for _frame in range(3):
		await process_frame
	await _incendiary()
	await _piercing()
	await _desperate()
	await _shield()
	await _aftermath()
	await _hitstop()
	await _capacity_and_stages()
	await _timewarp()
	await _charge_perks()
	await _kill_perks()
	await _reaper_echo()
	await _capture()
	await _dispose()
	RunState.begin_run()
	await create_timer(0.5).timeout
	Pool.clear_all()
	print("[赐福效果测试] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _fixture() -> void:
	await _dispose()
	RunState.begin_run()
	Flow.instance.state = Flow.State.PLAYING
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	_ground_y = Terrain.height_at(0.0, 0.0)
	var floor_body := StaticBody3D.new()
	floor_body.position.y = _ground_y - 0.5
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	floor_shape.shape = box
	floor_body.add_child(floor_shape)
	var floor_mesh := MeshInstance3D.new()
	var floor_box := BoxMesh.new()
	floor_box.size = box.size
	floor_mesh.mesh = floor_box
	floor_body.add_child(floor_mesh)
	_world.add_child(floor_body)
	_player = PlayerScene.instantiate()
	_player.position = Vector3(0, _ground_y + 1.0, 0)
	_world.add_child(_player)
	_player.set_physics_process(false)
	_player._wisp.set_process(false)
	_player._wisp.set_physics_process(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var rig := Node3D.new()
	rig.position = Vector3(0, 0.6, 0)
	_player.add_child(rig)
	var muzzle := Node3D.new()
	muzzle.position = Vector3(0.4, 0, -0.8)
	rig.add_child(muzzle)
	_camera = Camera3D.new()
	_camera.position = Vector3(0, _ground_y + 1.6, 4.5)
	_world.add_child(_camera)
	_camera.make_current()
	_player._weapon._camera = _camera
	_player._weapon._weapon_rig = rig
	_player._weapon._muzzle = muzzle
	await physics_frame
	await physics_frame
	paused = true


func _target(at: Vector3) -> Target:
	var target := Target.new()
	target.position = at + Vector3.UP * _ground_y
	target.collision_layer = 4
	target.collision_mask = 0
	target.add_to_group("enemies")
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.5
	capsule.height = 2.0
	collision.shape = capsule
	target.add_child(collision)
	var model := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.5
	mesh.height = 2.0
	model.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.12, 0.55, 0.72)
	model.material_override = material
	target.add_child(model)
	_world.add_child(target)
	return target


func _choose(id: String) -> void:
	RunState.add_perk(id)
	EventBus.emit_upgrade_chosen(id)


func _sync() -> void:
	paused = false
	await physics_frame
	await physics_frame
	paused = true


func _incendiary() -> void:
	await _fixture()
	var target := _target(Vector3(0, 1, -3))
	await _sync()
	_player._weapon._fire_hitscan(Vector3.FORWARD, false)
	_check(target.get_node_or_null("StatusEffect_burn") == null, "没有赐福的子弹不点燃")
	_choose("incendiary_rounds")
	var shot_damage: float = _player._weapon.get_bullet_damage()
	_player._weapon._fire_hitscan(Vector3.FORWARD, false)
	var burn := target.get_node_or_null("StatusEffect_burn")
	_check(burn != null, "真实主武器命中挂载燃烧组件")
	if burn == null:
		return
	_check(is_equal_approx(burn.position.y, 0.2), "按敌人碰撞体中心附着火焰，不悬在头顶")
	_check(burn._flames.emitting and burn._sparks.emitting and burn._smoke.emitting
		and burn._light.light_energy > 0.0, "燃烧保留火焰、火星、浓烟和暖光")
	var before := target.health
	for _tick in range(5):
		burn._process(0.5)
	_check(is_equal_approx(before - target.health, shot_damage * 0.35), "2.5 秒完整结算子弹 35% 的伤害")
	_check(burn._extinguishing, "最后一跳结算后进入退场")
	_check(target.last_context.get("source") == "primary" and int(target.last_context.get("shot", -1)) == 0,
		"灼烧归属主武器，不增加子弹命中计数")
	_player._weapon._fire_hitscan(Vector3.FORWARD, false)
	_check(target.get_node("StatusEffect_burn") == burn and not burn._extinguishing,
		"再次命中复用组件，并取消旧的退场")
	before = target.health
	burn._process(2.5)
	_check(is_equal_approx(before - target.health, shot_damage * 0.35), "低帧率也不漏掉燃烧跳伤")
	var sniper_target := _target(Vector3(2, 1, -3))
	_camera.look_at(sniper_target.global_position + Vector3.UP * 0.6)
	await _sync()
	_player._weapon._fire_hitscan(-_camera.global_basis.z, true)
	_check(sniper_target.get_node_or_null("StatusEffect_burn") == null, "灼热射击不影响狙击")
	print("[赐福效果测试] 灼热射击：命中、已有表现、完整跳伤、刷新与狙击边界通过")


func _piercing() -> void:
	await _fixture()
	var targets: Array[Target] = []
	for index in range(6):
		targets.append(_target(Vector3(0, 1, -3.0 * (index + 1))))
	await _sync()
	var hits: Array = _player._weapon._resolve_shot_hits(Vector3.FORWARD, true)
	_check(hits.size() == 3, "没有赐福的狙击仍穿透三个目标")
	_choose("armor_pierce")
	hits = _player._weapon._resolve_shot_hits(Vector3.FORWARD, true)
	_check(hits.size() == 5, "穿甲弹芯把实际穿透数增加到五个")
	if hits.size() == 5:
		for hit: Dictionary in hits:
			_check(is_equal_approx(float(hit.amount), float(hits[0].amount)), "穿透伤害不递减")
	_player._weapon._fire_hitscan(Vector3.FORWARD, true)
	for index in range(5):
		_check(targets[index].health < targets[index].max_health, "前五个穿透目标实际扣血")
	_check(targets[5].health == targets[5].max_health, "第六个目标不受伤")
	_choose("armor_pierce")
	_check(_player._weapon._resolve_shot_hits(Vector3.FORWARD, true).size() == 5, "重复选卡仍遵守五个目标上限")
	_check(_player._weapon._resolve_shot_hits(Vector3.FORWARD, false).size() == 1, "赐福不让主武器穿透")
	print("[赐福效果测试] 穿甲弹芯：真实五目标命中与伤害通过")


func _desperate() -> void:
	await _fixture()
	var target := _target(Vector3(0, 1, -3))
	await _sync()
	var primary: float = _player._weapon.get_bullet_damage()
	var sniper: float = _player._weapon._resolve_shot_hits(Vector3.FORWARD, true)[0].amount
	var burst: float = _player._resonance._calculate_burst_damage(1.0)
	_choose("desperate_will")
	_player.health = _player.max_health * 0.35
	_check(is_equal_approx(_player._weapon.get_bullet_damage(), primary), "35% 血量边界不提前触发")
	_player.health = _player.max_health * 0.10
	_check(is_equal_approx(_player._weapon.get_bullet_damage(), primary * 1.4), "低血量主武器增伤 40%")
	_check(is_equal_approx(float(_player._weapon._resolve_shot_hits(Vector3.FORWARD, true)[0].amount), sniper * 1.4),
		"低血量狙击增伤 40%")
	_check(is_equal_approx(float(_player._resonance._calculate_burst_damage(1.0)), burst * 1.4),
		"共鸣读取最大血量并增伤 40%")
	var before := target.health
	_player._weapon._fire_hitscan(Vector3.FORWARD, false)
	_check(is_equal_approx(before - target.health, primary * 1.4), "增伤进入实际伤害结算")
	_player.health = _player.max_health
	_check(is_equal_approx(_player._weapon.get_bullet_damage(), primary)
		and is_equal_approx(float(_player._resonance._calculate_burst_damage(1.0)), burst), "恢复生命后撤销增伤")
	var accessor := HealthAccessor.new()
	_check(is_equal_approx(Health.max_health_or(accessor), 100.0), "最大血量访问器与当前血量分开")
	accessor.free()
	print("[赐福效果测试] 绝境意志：主武器、狙击、共鸣与血量边界通过")


func _shield() -> void:
	await _fixture()
	var maximum: float = _player.max_shield
	var delay: float = _player._shield_regen_delay
	_choose("shield_overload")
	_check(is_equal_approx(_player.max_shield, maximum + 35.0)
		and is_equal_approx(_player.shield, maximum + 35.0), "护盾过载增加上限并补满")
	_check(is_equal_approx(_player._shield_regen_delay, maxf(delay - 0.8, 0.0)), "护盾恢复延迟缩短 0.8 秒")
	_player.take_damage(10.0, Vector3.ZERO, 1.0)
	var damaged: float = _player.shield
	_player._tick_timers(_player._shield_regen_delay - 0.01)
	_check(is_equal_approx(_player.shield, damaged), "新恢复延迟结束前不自愈")
	_player._tick_timers(0.02)
	_check(_player.shield > damaged, "越过新恢复延迟后开始自愈")
	for _stack in range(5):
		_choose("shield_overload")
	_check(is_zero_approx(_player._shield_regen_delay), "多次选择不会产生负恢复延迟")
	print("[赐福效果测试] 护盾过载：上限、实际恢复计时与下限通过")


func _aftermath() -> void:
	await _fixture()
	var inside := _target(Vector3(0, 1, -3))
	var outside := _target(Vector3(0, 1, -18))
	var elevated := _target(Vector3(3, 6, 0))
	var old_boss := _target(Vector3(4, 1, -3))
	old_boss.collision_layer = 3
	var blocked := _target(Vector3(-6, 1, 0))
	var wall := StaticBody3D.new()
	wall.position = Vector3(-4, _ground_y + 2.0, 0)
	var wall_collision := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(1, 4, 6)
	wall_collision.shape = wall_box
	wall.add_child(wall_collision)
	_world.add_child(wall)
	for target in [inside, outside, elevated, old_boss, blocked]:
		target.add_to_group("boss")
	await _sync()
	_choose("resonance_burn")
	_player._resonance._energy = _player._resonance._max_energy
	_player._resonance.perform_burst()
	var zone := _world.get_node_or_null("ResonanceBurningZone")
	_check(zone != null, "选择赐福后真实共鸣爆发生成灼烧领域")
	if zone == null:
		return
	var inside_hp := inside.health
	var outside_hp := outside.health
	var elevated_hp := elevated.health
	var old_boss_hp := old_boss.health
	var blocked_hp := blocked.health
	var lifetime: float = zone._remaining_time
	await process_frame
	await process_frame
	_check(inside.health == inside_hp and zone._remaining_time == lifetime, "暂停期间领域不跳伤也不消耗寿命")
	zone._physics_process(0.5)
	_check(is_equal_approx(inside_hp - inside.health, 20.0), "领域每半秒按配置结算 20 点伤害")
	_check(outside.health == outside_hp and elevated.health == elevated_hp, "领域不伤害范围外或另一楼层敌人")
	_check(old_boss.health < old_boss_hp, "占地形碰撞层的旧 Boss 仍能被领域灼烧")
	_check(blocked.health == blocked_hp, "领域伤害不能穿过实体墙")
	outside.position = Vector3(5, _ground_y + 1, 0)
	zone._physics_process(0.5)
	_check(outside.health < outside_hp, "爆发后新踏入领域的敌人也受伤")
	inside.position.x = 30.0
	inside_hp = inside.health
	zone._physics_process(4.0)
	_check(inside.health == inside_hp, "离开领域后停止灼烧")
	_check(zone.is_queued_for_deletion(), "五秒寿命结束后领域清理")
	_check(is_equal_approx(outside_hp - outside.health, 180.0), "新进入目标完整结算剩余 4.5 秒的领域伤害")
	_check(outside.last_context.get("source_kind") == "player", "领域伤害保留玩家归属")
	print("[赐福效果测试] 余震烈焰：真实爆发、持续伤害、进入/离开、高度与暂停生命周期通过")


func _capture() -> void:
	if not "--capture-perks" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless":
		return
	await _fixture()
	var target := MudGolem.new()
	target.combat_reaction_profile = HoldReaction
	target.ai_enabled = false
	target.position = Vector3(0, _ground_y + 0.65, -3)
	_world.add_child(target)
	target.set_physics_process(false)
	target.health = 1000.0
	target.max_health = 1000.0
	target.get_node("HealthLabel").hide()
	_camera.look_at(target.global_position)
	await _sync()
	_choose("incendiary_rounds")
	_player._weapon._fire_hitscan(-_camera.global_basis.z, false)
	_check(target.get_node_or_null("StatusEffect_burn") != null, "正式泥偶敌人被真实子弹点燃")
	_player._resonance._spawn_burning_aftermath(Vector3(0, _ground_y + 0.04, 0), 6.0)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -20, 0)
	_world.add_child(sun)
	_camera.position = Vector3(3.3, _ground_y + 2.7, 2.5)
	_camera.look_at(target.global_position)
	_camera.make_current()
	root.size = Vector2i(1280, 720)
	for canvas in root.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).hide()
	paused = false
	for _frame in range(36):
		await RenderingServer.frame_post_draw
	var path := CapturePaths.file("upgrade_effects/incendiary_and_aftermath.png")
	CapturePaths.ensure_dir("upgrade_effects")
	_check(root.get_texture().get_image().save_png(path) == OK, "燃烧与领域图形验证截图保存")
	print("[赐福效果测试] 画面：", path)


func _hitstop() -> void:
	await _fixture()
	var target := _target(Vector3(0, 1, -3))
	await _sync()
	target.set_process(true)
	target.set_physics_process(true)
	Feedback.hitstop(target, 0.2)
	Feedback.hitstop(target, 0.3)
	_check(not target.is_processing() and not target.is_physics_processing(), "顿帧暂停敌人自身更新")
	_check(_player._weapon._resolve_shot_hits(Vector3.FORWARD, false).size() == 1,
		"顿帧中的敌人仍能被下一发子弹命中")
	await create_timer(0.22, true, false, true).timeout
	_check(not target.is_physics_processing(), "连续顿帧不会被旧回调提前恢复")
	await create_timer(0.12, true, false, true).timeout
	_check(target.is_processing() and target.is_physics_processing(), "顿帧结束恢复原更新状态")
	Feedback.hitstop(target, 0.1)
	target.health = 0.0
	await create_timer(0.12, true, false, true).timeout
	_check(not target.is_physics_processing(), "顿帧回调不恢复已经死亡的敌人")
	print("[赐福效果测试] 顿帧：碰撞保留、延时刷新、恢复与死亡边界通过")


func _capacity_and_stages() -> void:
	await _fixture()
	var resonance: Node = _player._resonance
	var base_energy: float = resonance._max_energy
	var base_damage: float = resonance._calculate_burst_damage(1.0)
	_choose("resonance_amplification")
	resonance._energy = 80.0
	_choose("fury_charge")
	for _refresh in range(10):
		resonance.refresh_perks()
	_check(resonance._max_energy == base_energy + 30.0 and resonance._energy == 80.0,
		"无关选卡/重复刷新不累加容量，也不填充当前能量")
	_choose("overload_core")
	_check(is_equal_approx(float(resonance._overflow_cap), float(resonance._max_energy) * 2.0)
		and is_equal_approx(float(resonance._calculate_burst_damage(1.0)), base_damage * 1.3),
		"过载核心按描述提供 200% 溢出空间和 30% 爆发增伤")
	_choose("resonance_amplification")
	for _copy in range(2):
		_choose("shield_overload")
		_choose("rapid_cycler")
		_choose("wisp_overclock")
	var expected := {
		"shield": _player.max_shield, "delay": _player._shield_regen_delay,
		"speed": _player.speed, "dodge": _player.dodge_cooldown_time,
		"energy": resonance._max_energy, "overflow": resonance._overflow_cap,
		"wisp_range": _player._wisp.attack_range, "wisp_damage": _player._wisp.base_damage}
	_player.shield = 12.0
	for _refresh in range(10):
		_player._apply_passive_perks()
		_player._apply_wisp_perks()
	_check(_player.max_shield == expected.shield and _player.speed == expected.speed
		and _player.shield == 12.0 and _player._wisp.attack_range == expected.wisp_range
		and _player._wisp.base_damage == expected.wisp_damage,
		"被动刷新幂等，无关刷新不补盾或重复叠加浮游卫士加成")
	RunState.set_weapon_level(8)
	RunState.set_upgrade_stacks("damage", 2)
	paused = false
	_check(change_scene_to_file("res://scenes/player.tscn") == OK, "载入实际玩家场景用于切关")
	await _loaded_player()
	var order := Arena.get_order()
	Flow.instance._apply_next_stage(String(order[1]) if order.size() > 1 else String(order[0]))
	await _loaded_player()
	_check(RunState.get_stage() == 2 and _player._weapon.get_level() == 1,
		"实际切关保留进度，武器档位仍按原设计重置")
	_check(_player.max_shield == expected.shield and _player.shield == expected.shield
		and is_equal_approx(float(_player._shield_regen_delay), float(expected.delay))
		and is_equal_approx(float(_player.speed), float(expected.speed))
		and is_equal_approx(float(_player.dodge_cooldown_time), float(expected.dodge)),
		"实际场景重载恢复全部层数的护盾、延迟、移速和翻滚冷却")
	_check(_player._resonance._max_energy == expected.energy and _player._resonance._overflow_cap == expected.overflow
		and is_equal_approx(float(_player._wisp.attack_range), float(expected.wisp_range))
		and is_equal_approx(float(_player._wisp.base_damage), float(expected.wisp_damage)),
		"共鸣容量和已有浮游卫士赐福同样跨关恢复")
	Flow.instance._on_restart()
	await _loaded_player()
	_check(RunState.get_perks().is_empty() and _player._resonance._max_energy == base_energy
		and _player.max_shield == Config.get_float("player.shield_max", 70.0)
		and _player.speed == Config.get_float("player.speed", 5.0)
		and _player.dodge_cooldown_time == Config.get_float("abilities.dodge.cooldown", 0.85),
		"实际重开清除赐福，不把上局加成带入新局")
	print("[赐福效果测试] 容量幂等、实际切关与重开恢复通过")


func _loaded_player() -> void:
	await process_frame
	await process_frame
	_world = current_scene as Node3D
	_player = _world as CharacterBody3D
	_player.set_physics_process(false)
	_player._wisp.set_process(false)
	_player._wisp.set_physics_process(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _timewarp() -> void:
	await _fixture()
	var target := SlowTarget.new()
	target.position = _player.position + Vector3.FORWARD * 3
	target.add_to_group("enemies")
	target.add_to_group("boss")
	_world.add_child(target)
	_choose("timewarp")
	_player._resonance._energy = _player._resonance._max_energy
	_player._resonance.perform_burst()
	var timer := target.get_node_or_null("ResonanceSlowTimer") as Timer
	_check(timer != null and is_equal_approx(timer.wait_time, 4.2) and is_equal_approx(target.move_speed, 4.5),
		"真实共鸣触发 4.2 秒减速，符合时空裂隙描述")
	if timer == null:
		return
	_player._resonance._apply_slow_to_enemies(_player.position, 10.0, 4.2)
	_check(target.get_node("ResonanceSlowTimer") == timer and is_equal_approx(target.move_speed, 4.5),
		"重复减速刷新时长，不重复乘速度或保存减速后的基础值")
	var remaining := timer.time_left
	await create_timer(0.2, true, false, true).timeout
	_check(timer.time_left == remaining, "暂停期间减速计时冻结")
	timer.timeout.emit()
	_check(is_equal_approx(target.move_speed, 10.0), "减速到期恢复原速度")
	print("[赐福效果测试] 时空裂隙时长、刷新、暂停与恢复通过")


func _charge_perks() -> void:
	await _fixture()
	var resonance: Node = _player._resonance
	resonance._energy = 0.0
	_player.take_damage(10.0, Vector3.ZERO, 1.0)
	var base_gain: float = resonance._energy
	_choose("fury_charge")
	resonance._energy = 0.0
	_player._damage_invulnerability = 0.0
	_player.take_damage(10.0, Vector3.ZERO, 1.0)
	_check(base_gain > 0.0 and is_equal_approx(float(resonance._energy), base_gain * 1.5),
		"怒火充能在实际受击路径增加 50% 能量")
	_choose("phantom_dodge")
	resonance._energy = 0.0
	_player._rolling = true
	_player._damage_invulnerability = 0.2
	var shield: float = _player.shield
	_player.take_damage(10.0, Vector3.ZERO, 1.0)
	_check(_player.shield == shield and is_equal_approx(float(resonance._energy), float(resonance._charge_on_dodge) * 2.0),
		"幻影回响在实际翻滚免伤路径使完美闪避充能翻倍")
	_player._rolling = false
	resonance._energy = 0.0
	_player.on_shockwave_parry(1)
	_check(is_equal_approx(float(resonance._energy), float(resonance._charge_on_dodge) * 2.0),
		"一次震地破招只结算一次完美闪避充能")
	print("[赐福效果测试] 怒火充能、幻影回响与一次破招充能通过")


func _mud(at: Vector3) -> CharacterBody3D:
	var target := MudGolem.new()
	target.combat_reaction_profile = HoldReaction
	target.ai_enabled = false
	target.position = at + Vector3.UP * _ground_y
	_world.add_child(target)
	target.set_physics_process(false)
	target.target = _player
	target.health = 1.0
	return target


func _kill_perks() -> void:
	await _fixture()
	_choose("vampiric_touch")
	_player.health = _player.max_health - 10.0
	var kills: int = _player.kill_count
	var victim := _mud(Vector3(10, 1, 0))
	Telemetry.hurt_enemy(victim, 100.0, {"source": "primary", "source_kind": "player"})
	_check(_player.kill_count == kills + 1 and _player.health == _player.max_health - 6.0,
		"战地汲取在真实泥偶死亡时回复 4 点生命")
	_check(is_equal_approx(float(_player._resonance._energy), float(_player._resonance._charge_on_kill)),
		"真实击杀仍结算一次基础共鸣充能")
	var enemy_owned := _mud(Vector3(10, 1, 0))
	Telemetry.hurt_enemy(enemy_owned, 100.0, {"source_kind": "enemy"})
	_check(_player.kill_count == kills + 1 and _player.health == _player.max_health - 6.0,
		"敌人造成的死亡不触发玩家击杀赐福")
	_choose("chain_lightning")
	var nearest := _target(Vector3(10.4, 1, 0))
	var farther := _target(Vector3(12, 1, 0))
	var near_player := _target(Vector3(2, 1, 0))
	victim = _mud(Vector3(10, 1, 0))
	Telemetry.hurt_enemy(victim, 100.0, {"source": "primary", "source_kind": "player"})
	_check(nearest.health == nearest.max_health - 60.0 and farther.health == farther.max_health
		and near_player.health == near_player.max_health,
		"连锁电弧从真实死者跳射到最近存活目标，包含贴身目标")
	_check(nearest.last_context.get("source") == "chain_lightning"
		and nearest.last_context.get("source_kind") == "player", "电弧伤害保留玩家和赐福归属")
	for target in [nearest, farther, near_player]:
		target.health = 0.0
	var boundary := _target(Vector3(15, 1, 0))
	var outside := _target(Vector3(15.01, 1, 0))
	_player.health = _player.max_health - 1.0
	victim = _mud(Vector3(10, 1, 0))
	Telemetry.hurt_enemy(victim, 100.0, {"source": "primary", "source_kind": "player"})
	_check(boundary.health == boundary.max_health - 60.0 and outside.health == outside.max_health,
		"电弧包含 5 米边界，排除范围外与死亡目标")
	_check(_player.health == _player.max_health, "战地汲取不超过最大生命")
	boundary.health = 0.0
	outside.health = 0.0
	var chain: Array[CharacterBody3D] = []
	for offset in [0.0, 0.4, 0.8]:
		chain.append(_mud(Vector3(10 + offset, 1, 0)))
	kills = _player.kill_count
	_player.health = _player.max_health - 20.0
	_player._resonance._energy = 0.0
	Telemetry.hurt_enemy(chain[0], 100.0, {"source": "primary", "source_kind": "player"})
	_check(_player.kill_count == kills + 3 and _player.health == _player.max_health - 8.0
		and is_equal_approx(float(_player._resonance._energy), float(_player._resonance._charge_on_kill) * 3.0),
		"电弧致死能够继续跳射，每个真实击杀只结算一次回血和共鸣")
	print("[赐福效果测试] 战地汲取与实际击杀电弧的起点、最近目标、范围和归属通过")


func _reaper_echo() -> void:
	await _fixture()
	_choose("reaper_echo")
	var first := _target(Vector3(0, 1, -3))
	first.add_to_group("boss")
	var second := _target(Vector3(3, 1, 0))
	second.add_to_group("boss")
	second.health = 0.0
	var resonance: Node = _player._resonance
	resonance._energy = resonance._max_energy
	resonance.perform_burst()
	_check(is_zero_approx(float(resonance._energy)), "一个存活目标和一个死亡目标不满足收割回响")
	second.health = second.max_health
	resonance._energy = resonance._max_energy
	resonance.perform_burst()
	_check(is_equal_approx(float(resonance._energy), float(resonance._max_energy) * 0.35),
		"真实共鸣命中两个存活敌人后返还 35% 能量")
	_check(first.last_context.get("source") == "resonance" and second.last_context.get("source_kind") == "player",
		"爆发伤害保留共鸣和玩家归属")
	print("[赐福效果测试] 收割回响真实双目标、死亡排除和伤害归属通过")


func _dispose() -> void:
	paused = false
	Engine.time_scale = 1.0
	if is_instance_valid(_world):
		current_scene = null
		_world.queue_free()
		await process_frame
	_world = null


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[赐福效果测试] " + message)
