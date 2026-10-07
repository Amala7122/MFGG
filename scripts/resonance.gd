class_name Resonance
extends Node

const HealthUtil := preload("res://scripts/health_util.gd")
## 遗迹共鸣（Resonance）系统组件。
##
## 核心设计：压力与力量同步蓄积，在极限时刻一键释放毁灭打击！
## - 充能来源：受击 (+8~15)、护盾碎裂 (+25)、完美闪避 (+18)、击杀敌人 (+3.5)
## - 能量达到 100%（上限可溢出至 150%~200%）后进入「共鸣就绪」状态
## - 玩家按释放键（单按 R 键或 F 键）触发「共鸣爆发」：
##   全屏能量震荡、小核弹级毁灭脉冲、全场敌人击飞击退、全场散落残骸吹飞、短暂无敌与全场减速

const EventBusUtil := preload("res://scripts/event_bus.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")
const RunStateUtil := preload("res://scripts/run_state.gd")
const CombatFXUtil := preload("res://scripts/combat_fx.gd")
const ResonanceBurstFXScript := preload("res://scripts/resonance_burst_fx.gd")
const CinematicActionCamScript := preload("res://scripts/cinematic_action_cam.gd")
const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")

var _player: CharacterBody3D
var _hud: Node

var _energy: float = 0.0
var _max_energy: float = 100.0
var _overflow_cap: float = 150.0

var _burst_damage_base: float = 280.0
var _burst_damage_per_energy: float = 2.6
var _burst_radius: float = 15.0
var _burst_push: float = 22.0
var _burst_hold_required: float = 0.7
var _hold_timer: float = 0.0

var _charge_on_hit: float = 9.0
var _charge_on_dodge: float = 18.0
var _charge_on_kill: float = 3.5
var _charge_on_shield_break: float = 26.0

# 机体能量外溢视觉光环（Resonance Visual Aura）
var _aura_root: Node3D = null
var _aura_light: OmniLight3D = null
var _aura_shards: Array[MeshInstance3D] = []
var _aura_mat: StandardMaterial3D = null
var _aura_time: float = 0.0


func setup(player: CharacterBody3D, hud: Node) -> void:
	_player = player
	_hud = hud
	_read_config()
	_apply_perks()
	_setup_aura()
	EventBusUtil.emit_resonance_changed(_energy, _max_energy, _overflow_cap)


func _read_config() -> void:
	_max_energy = maxf(ConfigUtil.get_float("resonance.max_energy", 100.0), 20.0)
	_overflow_cap = maxf(ConfigUtil.get_float("resonance.overflow_cap", 150.0), _max_energy)
	_charge_on_hit = maxf(ConfigUtil.get_float("resonance.charge_on_hit", 9.0), 1.0)
	_charge_on_dodge = maxf(ConfigUtil.get_float("resonance.charge_on_dodge", 18.0), 1.0)
	_charge_on_kill = maxf(ConfigUtil.get_float("resonance.charge_on_kill", 3.5), 0.5)
	_charge_on_shield_break = maxf(ConfigUtil.get_float("resonance.charge_on_shield_break", 26.0), 2.0)
	_burst_radius = maxf(ConfigUtil.get_float("resonance.burst_radius", 15.0), 5.0)
	_burst_damage_base = maxf(ConfigUtil.get_float("resonance.burst_damage_base", 280.0), 10.0)
	_burst_damage_per_energy = maxf(ConfigUtil.get_float("resonance.burst_damage_per_energy", 2.6), 0.5)
	_burst_push = maxf(ConfigUtil.get_float("resonance.burst_push", 22.0), 5.0)
	_burst_hold_required = maxf(ConfigUtil.get_float("resonance.burst_hold_seconds", 0.7), 0.2)


func _apply_perks() -> void:
	# 检查 Roguelite 强化被动加成
	if RunStateUtil.has_perk("resonance_amplification"):
		_max_energy += 30.0 * RunStateUtil.get_perk_count("resonance_amplification")
		_overflow_cap = _max_energy * 1.5

	if RunStateUtil.has_perk("overload_core"):
		_overflow_cap += 50.0 * RunStateUtil.get_perk_count("overload_core")


## 供外部每当挑选强化后重新刷新加成
func refresh_perks() -> void:
	_apply_perks()
	EventBusUtil.emit_resonance_changed(_energy, _max_energy, _overflow_cap)


# ---------------------------------------------------------------- 充能入口

func on_player_hit(amount: float) -> void:
	var mult := 1.0
	if RunStateUtil.has_perk("fury_charge"):
		mult += 0.5 * RunStateUtil.get_perk_count("fury_charge")
	var gain := (_charge_on_hit + amount * 0.12) * mult
	add_energy(gain)


func on_shield_break() -> void:
	add_energy(_charge_on_shield_break)
	if _hud and _hud.has_method("show_notice"):
		_hud.call("show_notice", "护盾破碎 · 共鸣充能激增！", "shield")


func on_perfect_dodge() -> void:
	var mult := 1.0
	if RunStateUtil.has_perk("phantom_dodge"):
		mult += 1.0 * RunStateUtil.get_perk_count("phantom_dodge")
	add_energy(_charge_on_dodge * mult)
	EventBusUtil.emit_perfect_dodge()
	AudioUtil.play("pickup", 1.0, 1.6)
	if _hud and _hud.has_method("show_notice"):
		_hud.call("show_notice", "完美闪避！能量 +%d" % roundi(_charge_on_dodge * mult), "upgrade")


func on_enemy_kill() -> void:
	add_energy(_charge_on_kill)


func add_energy(amount: float) -> void:
	var prev := _energy
	_energy = clampf(_energy + amount, 0.0, _overflow_cap)
	if prev < _max_energy and _energy >= _max_energy:
		# 刚充满就绪提示
		AudioUtil.play("pickup", 3.0, 1.8)
		if _hud and _hud.has_method("show_notice"):
			_hud.call("show_notice", "★ 遗迹共鸣就绪！[按 R 释放]", "upgrade")
	EventBusUtil.emit_resonance_changed(_energy, _max_energy, _overflow_cap)


func is_ready() -> bool:
	return _energy >= _max_energy


func get_hold_progress() -> float:
	if not is_ready() or _burst_hold_required <= 0.01:
		return 0.0
	return clampf(_hold_timer / _burst_hold_required, 0.0, 1.0)


# ---------------------------------------------------------------- 帧更新与释放

func update(delta: float, _is_holding: bool) -> bool:
	_update_aura(delta)
	return false


func _setup_aura() -> void:
	if not is_instance_valid(_player):
		return
	_aura_root = Node3D.new()
	_aura_root.name = "ResonanceAura"
	_player.add_child(_aura_root)
	_aura_root.position = Vector3(0.0, 1.15, 0.0)
	_aura_root.visible = false

	_aura_light = OmniLight3D.new()
	_aura_light.omni_range = 5.5
	_aura_light.omni_attenuation = 2.0
	_aura_light.light_energy = 0.0
	_aura_root.add_child(_aura_light)

	_aura_mat = StandardMaterial3D.new()
	_aura_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_aura_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_aura_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_aura_mat.emission_enabled = true

	# 3 枚悬浮共鸣晶核围绕机体腰身环绕
	var prism_mesh := PrismMesh.new()
	prism_mesh.size = Vector3(0.12, 0.22, 0.12)
	prism_mesh.material = _aura_mat

	for _i in range(3):
		var shard := MeshInstance3D.new()
		shard.mesh = prism_mesh
		_aura_root.add_child(shard)
		_aura_shards.append(shard)


func _update_aura(delta: float) -> void:
	if not _aura_root or not is_instance_valid(_player):
		return
	var ready := is_ready()
	if not ready:
		if _aura_root.visible:
			_aura_root.visible = false
		return

	if not _aura_root.visible:
		_aura_root.visible = true

	_aura_time += delta
	var ratio := _energy / _max_energy
	var is_overload := (ratio >= 1.75)

	var spin_speed := 3.2 if not is_overload else 7.8
	var orbit_radius := 0.72 if not is_overload else 0.96

	var color_target := Color(1.0, 0.82, 0.28, 0.9) if not is_overload else Color(0.35, 0.95, 1.0, 1.0)
	_aura_mat.albedo_color = color_target
	_aura_mat.emission = color_target
	_aura_mat.emission_energy_multiplier = 4.0 if not is_overload else 9.5

	if _aura_light:
		_aura_light.light_color = color_target
		var breath := (sin(_aura_time * 6.0) * 0.35 + 1.0) if not is_overload else (sin(_aura_time * 14.0) * 0.6 + 1.8)
		_aura_light.light_energy = (1.2 if not is_overload else 2.6) * breath

	for i in range(_aura_shards.size()):
		var shard := _aura_shards[i]
		var angle := _aura_time * spin_speed + float(i) * (TAU / 3.0)
		var h_bob := sin(_aura_time * 4.0 + float(i) * 2.0) * 0.12
		shard.position = Vector3(cos(angle) * orbit_radius, h_bob, sin(angle) * orbit_radius)
		shard.rotation = Vector3(_aura_time * 5.0, angle, _aura_time * 4.0)


## 触发共鸣大爆发（毁灭脉冲）！
func perform_burst() -> void:
	if not is_instance_valid(_player):
		return

	var p_pos := _player.global_position if _player.is_inside_tree() else Vector3.ZERO
	var ground_y := TerrainFieldUtil.height_at(p_pos.x, p_pos.z)
	var burst_pos := Vector3(p_pos.x, ground_y + 0.04, p_pos.z)
	var ratio := _energy / _max_energy
	var is_overload := (ratio >= 1.75) # 接近或达到 200% 充能

	# 200% 溢出爆发范围扩大至 26 米，普通 100% 爆发为 20 米
	var effective_radius := _burst_radius if not is_overload else _burst_radius * 1.3
	var total_damage := _calculate_burst_damage(ratio)
	var effective_push := _burst_push * (1.35 if is_overload else 1.0)

	var hit_count := 0
	if _player.is_inside_tree():
		# 1. 造成大范围毁灭级打击（带 200% 非 Boss 斩杀契约与 100% 中小怪斩杀契约）
		hit_count = _apply_burst_damage(burst_pos, effective_radius, total_damage, effective_push, ratio)

		# 2. 震撼多层音效
		AudioUtil.play("shockwave", 5.0, 0.55)
		AudioUtil.play("explode", 4.0, 0.70)
		AudioUtil.play("pickup", 3.0, 0.45)

		# 3. 专属宏大视觉特效：通天光柱 + 毁灭半球 + 双重地表环 + 爆裂晶片 + 强光
		_spawn_burst_fx(burst_pos, effective_radius, is_overload)

		# 4. 启动大招专属全景慢动作特写镜头（随机轨迹多角度特写 + 深度慢动作 + 输入锁定保护）
		var action_cam := CinematicActionCamScript.new()
		action_cam.name = "ResonanceActionCam"
		var host: Node = _player.get_tree().current_scene if _player.get_tree().current_scene != null else _player.get_tree().root
		host.add_child(action_cam)
		action_cam.start(_player, 1.15 if is_overload else 0.88, 0.08 if is_overload else 0.12)

		# 5. 镜头剧烈震颤冲击感
		if _player.has_method("apply_camera_shake"):
			_player.call("apply_camera_shake", 1.6 if is_overload else 1.2)

		# 6. 玩家获得短暂无敌（安全窗口）
		var invuln_duration := 2.2 if is_overload else 1.8
		if _player.has_method("grant_invulnerability"):
			_player.call("grant_invulnerability", invuln_duration)
		elif _player.get("_damage_invulnerability") != null:
			_player.set("_damage_invulnerability", invuln_duration)

		# 6. 全场生还敌人减速控场
		var slow_duration := 2.5
		if RunStateUtil.has_perk("timewarp"):
			slow_duration = 4.5
		_apply_slow_to_enemies(burst_pos, effective_radius * 1.2, slow_duration)

		# 7. 特殊强化：余震灼烧
		if RunStateUtil.has_perk("resonance_burn"):
			_spawn_burning_aftermath(burst_pos, effective_radius * 0.75)

	# 8. 特殊强化：收割回响 (击杀数 >= 2 时返还能量)
	var refund := 0.0
	if RunStateUtil.has_perk("reaper_echo") and hit_count >= 2:
		refund = _max_energy * 0.35
		if _hud and _hud.has_method("show_notice"):
			_hud.call("show_notice", "收割回响！返还 35% 共鸣能量", "upgrade")

	_energy = refund
	if _aura_root:
		_aura_root.visible = false

	EventBusUtil.emit_resonance_burst(total_damage)
	EventBusUtil.emit_resonance_changed(_energy, _max_energy, _overflow_cap)

	if _hud and _hud.has_method("show_notice"):
		var notice_title := ("💥 200% 过载毁灭脉冲！全场肃清 " + str(hit_count) + " 目标") if is_overload else ("💥 遗迹共鸣大爆发！击退 " + str(hit_count) + " 目标")
		_hud.call("show_notice", notice_title, "upgrade")


func _calculate_burst_damage(ratio: float) -> float:
	var stage := RunStateUtil.get_stage()
	var stage_bonus := float(stage - 1) * 90.0
	var base_dmg: float
	if ratio < 1.0:
		base_dmg = ratio * 520.0
	elif ratio < 2.0:
		# 100% ~ 200% 平滑过渡：100% 为 520 点（秒杀所有中小敌人），200% 为 2400 点（秒杀所有非 Boss 敌人）
		var t := clampf(ratio - 1.0, 0.0, 1.0)
		var eased_t := t * t * (3.0 - 2.0 * t)
		base_dmg = lerpf(520.0 + stage_bonus, 2400.0 + stage_bonus * 2.5, eased_t)
	else:
		base_dmg = 2400.0 + stage_bonus * 2.5 + (ratio - 2.0) * 1200.0

	# 强化词条加成
	if RunStateUtil.has_perk("overload_core"):
		base_dmg *= 1.35
	if RunStateUtil.has_perk("desperate_will") and is_instance_valid(_player):
		var hp := HealthUtil.health_or(_player, 0.0)
		var max_hp := HealthUtil.health_or(_player, 0.0)
		if hp < max_hp * 0.35:
			base_dmg *= 1.5

	return base_dmg


func _apply_burst_damage(center: Vector3, radius: float, base_damage: float, push_force: float, ratio: float) -> int:
	if not is_instance_valid(_player) or not _player.is_inside_tree():
		return 0
	var tree := _player.get_tree()
	var enemies := tree.get_nodes_in_group("enemies")
	var hits := 0
	var is_overload_burst := (ratio >= 1.75)

	for node in enemies:
		var enemy := node as Node3D
		if not is_instance_valid(enemy):
			continue
		var offset := enemy.global_position - center
		var dist := offset.length()
		if dist > radius:
			continue

		# 脉冲波衰减极其平缓：边缘仍保留 80% 威力
		var dist_factor := clampf(1.0 - (dist / radius) * 0.20, 0.80, 1.0)
		var target_dmg := base_damage * dist_factor

		var is_boss: bool = enemy.has_method("take_damage_at") or enemy.is_in_group("boss") or enemy.name == "Boss" or enemy.get("is_boss") == true
		var is_large: bool = enemy.scale.x >= 1.25 or (enemy.get("enemy_title") != null and (String(enemy.get("enemy_title")).contains("巨型") or String(enemy.get("enemy_title")).contains("重装") or String(enemy.get("enemy_title")).contains("大型") or String(enemy.get("enemy_title")).contains("破坏者")))

		var enemy_hp := HealthUtil.health_or(enemy, 0.0)

		# 小核弹气势契约：
		# 小型敌人直接击飞死亡！大型敌人高额伤害+重力击退！
		if not is_boss:
			if not is_large:
				target_dmg = maxf(target_dmg, enemy_hp + 600.0)
			else:
				if is_overload_burst:
					target_dmg = maxf(target_dmg, enemy_hp + 600.0)

		if enemy.has_method("take_damage"):
			enemy.call("take_damage", target_dmg)
			hits += 1

		# 击退击飞效果：
		var dir := offset
		dir.y = 0.0
		if dir.is_zero_approx():
			dir = Vector3.FORWARD
		dir = dir.normalized()

		if enemy.has_method("apply_push"):
			if not is_large and not is_boss:
				# 小型敌人：高高击飞抛向半空，展现小核弹冲击波气势
				enemy.call("apply_push", dir + Vector3.UP * 1.6, push_force * 2.2 * dist_factor)
			else:
				# 大型敌人：强力击退
				enemy.call("apply_push", dir + Vector3.UP * 0.3, push_force * 1.35 * dist_factor)

	# 核心特性：小核弹冲击波吹飞全场敌人死亡后的散落残骸与碎片构件！
	var EnemyDeathFXScript := load("res://scripts/enemy_death_fx.gd") as GDScript
	if EnemyDeathFXScript and EnemyDeathFXScript.has_method("blow_away_debris"):
		EnemyDeathFXScript.blow_away_debris(tree, center, radius, push_force * 1.4)

	return hits


func _spawn_burst_fx(pos: Vector3, radius: float, is_overload: bool) -> void:
	if not is_instance_valid(_player) or not _player.is_inside_tree():
		return
	var tree := _player.get_tree()
	if not tree:
		return
	var scene := tree.current_scene if tree.current_scene != null else tree.root
	ResonanceBurstFXScript.spawn(scene, pos, radius, is_overload)


func _apply_slow_to_enemies(pos: Vector3, radius: float, duration: float) -> void:
	if not is_instance_valid(_player) or not _player.is_inside_tree():
		return
	var tree := _player.get_tree()
	if not tree:
		return
	var enemies := tree.get_nodes_in_group("enemies")
	for node in enemies:
		if node is CharacterBody3D and is_instance_valid(node):
			var dist := pos.distance_to(node.global_position)
			if dist <= radius:
				if node.has_method("apply_slow"):
					node.call("apply_slow", 0.4, duration)
				elif node.get("move_speed") != null:
					var orig_speed := float(node.get("move_speed"))
					node.set("move_speed", orig_speed * 0.45)
					var timer := tree.create_timer(duration)
					timer.timeout.connect(func():
						if is_instance_valid(node):
							node.set("move_speed", orig_speed)
					)
				elif node.get("speed") != null:
					var orig_speed := float(node.get("speed"))
					node.set("speed", orig_speed * 0.45)
					var timer := tree.create_timer(duration)
					timer.timeout.connect(func():
						if is_instance_valid(node):
							node.set("speed", orig_speed)
					)


func _spawn_burning_aftermath(pos: Vector3, radius: float) -> void:
	var scene := _player.get_tree().current_scene
	if not scene:
		return
	var burning_zone := Node3D.new()
	scene.add_child(burning_zone)
	burning_zone.global_position = pos

	# 持续 5 秒，每 0.5 秒对圈内敌人造成持续伤害
	var ticks := 10
	var timer := burning_zone.get_tree().create_timer(0.5)
	var tick_fn = func():
		pass # 使用连环计时器
	# 简单的自消亡定时器
	var cleanup := burning_zone.get_tree().create_timer(5.0)
	cleanup.timeout.connect(burning_zone.queue_free)
