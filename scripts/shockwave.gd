class_name Shockwave
extends Node3D
## 震地脉冲（Q 键）：以玩家为中心向外扩散的能量环，对范围内敌人造成伤害并击退。
## 伤害在生成瞬间一次性结算，之后的扩散环只是表现。
##
## 与手雷不同：脉冲穿墙生效（require_line_of_sight = false），
## 定位是"贴身被围住时把敌人推开"的自救技。

const AudioUtil := preload("res://scripts/audio_manager.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

## 扩散时长来自 data/game_config.json 的 abilities.skill.expand_duration。
## 半径 / 伤害 / 击退由 player.gd 传入（它在 abilities.skill 段读好后传过来），
## 所以这三个的 DEFAULT_* 只是在没传参时才生效的兜底值。
const DEFAULT_EXPAND_DURATION := 0.5
const DEFAULT_RADIUS := 9.0
const DEFAULT_DAMAGE := 55.0
const DEFAULT_PUSH := 15.0

var _expand_duration := DEFAULT_EXPAND_DURATION
var _elapsed := 0.0
var _radius := DEFAULT_RADIUS
var _ring: MeshInstance3D
var _material: StandardMaterial3D
var _light: OmniLight3D
var _finished := false


## 结算伤害、全方位格挡拦截并生成扩散环。返回被命中的敌人数量。
func perform(radius: float = DEFAULT_RADIUS, damage: float = DEFAULT_DAMAGE, push: float = DEFAULT_PUSH) -> int:
	_expand_duration = maxf(
		ConfigUtil.get_float("abilities.skill.expand_duration", DEFAULT_EXPAND_DURATION), 0.05
	)
	_radius = maxf(radius, 0.5)
	AudioUtil.play_at("shockwave", global_position, 1.5, 1.05)

	# 1. 对范围内敌人造成伤害与击退
	var hits := CombatFX.apply_radial_damage(self, global_position, _radius, damage, push, false)

	# 2. 全方位格挡与危机拦截（破除被围攻与逃不出红圈的死局）
	_parry_and_intercept()

	_build_visual()
	return hits


## 全方位格挡：摧毁敌方飞行物、驱散地面危险红圈、打断敌人蓄力出招与Boss技能
func _parry_and_intercept() -> void:
	if not is_inside_tree() or get_tree() == null:
		return
	var scene := get_tree().current_scene
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var center := global_position

	var projectile_intercepted := 0
	# 1. 拦截并摧毁范围内所有敌方弹幕与重型穿甲弹
	for node in get_tree().get_nodes_in_group("enemy_projectiles"):
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		var p_pos: Vector3 = (node as Node3D).global_position
		if p_pos.distance_to(center) <= _radius * 1.35:
			projectile_intercepted += 1
			if scene:
				CombatFX.spawn_impact(scene, p_pos, Vector3.UP, Color(0.35, 0.9, 1.0, 1.0), 1.6)
			if node.has_method("deflect"):
				node.call("deflect")
			elif node.has_method("die"):
				node.call("die")
			else:
				node.queue_free()

	# 兜底查找场景中可能存在的敌方弹体
	if scene:
		for child in scene.get_children():
			if not is_instance_valid(child) or not (child is Node3D):
				continue
			if child.is_in_group("enemy_projectiles"):
				continue
			var c_name := child.name
			if c_name.begins_with("EnemyBullet") or c_name.begins_with("SniperBullet") or c_name.begins_with("MortarShell"):
				var c_pos: Vector3 = (child as Node3D).global_position
				if c_pos.distance_to(center) <= _radius * 1.35:
					projectile_intercepted += 1
					CombatFX.spawn_impact(scene, c_pos, Vector3.UP, Color(0.35, 0.9, 1.0, 1.0), 1.6)
					child.queue_free()

	# 2. 驱散范围内的所有地面危险区（迫击炮落点红圈、Boss 砸地重击预警）
	var hazard_intercepted := 0
	for hazard in get_tree().get_nodes_in_group("ground_hazards"):
		if not is_instance_valid(hazard) or not hazard.is_inside_tree():
			continue
		var h_pos: Vector3 = (hazard as Node3D).global_position
		if h_pos.distance_to(center) <= _radius * 1.25:
			hazard_intercepted += 1
			if scene:
				CombatFX.spawn_impact(scene, h_pos + Vector3.UP * 0.2, Vector3.UP, Color(0.4, 0.85, 1.0, 1.0), 2.0)
			if hazard.has_method("dispel"):
				hazard.call("dispel")
			else:
				hazard.queue_free()

	# 3. 打断并破招范围内所有蓄力与冲锋动作（包含普通怪与 Boss）
	var skill_interrupted := 0
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			continue
		var e_pos: Vector3 = (enemy as Node3D).global_position
		if e_pos.distance_to(center) <= _radius * 1.15:
			skill_interrupted += 1
			if enemy.has_method("parry"):
				enemy.call("parry")
			elif enemy.has_method("cancel_skill"):
				enemy.call("cancel_skill")
			elif enemy.has_method("_cancel_skill"):
				enemy.call("_cancel_skill")
			elif enemy.has_method("cancel_attack_charge"):
				enemy.call("cancel_attack_charge")

	# 4. 取消并淡出范围内的敌人威胁预警线条与扇面 (Telegraph)
	for tele in get_tree().get_nodes_in_group("enemy_telegraphs"):
		if not is_instance_valid(tele) or not tele.is_inside_tree():
			continue
		var t_pos: Vector3 = (tele as Node3D).global_position
		if t_pos.distance_to(center) <= _radius * 1.25:
			if tele.has_method("cancel"):
				tele.call("cancel")
			else:
				tele.queue_free()

	# 5. 触发清脆金属破招音效与玩家 HUD 提示
	var total := projectile_intercepted + hazard_intercepted + skill_interrupted
	if total > 0:
		AudioUtil.play_at("shot", global_position, 2.5, 2.3)
		if player and player.has_method("on_shockwave_parry"):
			player.call("on_shockwave_parry", total)


func _build_visual() -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = 0.83
	torus.outer_radius = 1.0
	torus.rings = 40
	torus.ring_segments = 8

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.no_depth_test = true
	_material.render_priority = 12
	_material.albedo_color = Color(0.45, 0.85, 1.0, 0.85)
	_material.emission_enabled = true
	_material.emission = Color(0.3, 0.75, 1.0, 1.0)
	_material.emission_energy_multiplier = 6.0
	torus.material = _material

	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.scale = Vector3.ONE * (_radius * 0.2)
	add_child(_ring)

	_light = OmniLight3D.new()
	_light.light_color = Color(0.42, 0.82, 1.0, 1.0)
	_light.light_energy = 10.0
	_light.omni_range = _radius * 1.4
	_light.shadow_enabled = false
	add_child(_light)

	var flash := BlastFlash.new()
	add_child(flash)
	flash.trigger(Color(0.4, 0.8, 1.0, 1.0), _radius * 0.55, 0.3)


func _process(delta: float) -> void:
	if _finished:
		return
	_elapsed += delta
	var progress := _elapsed / _expand_duration
	if progress >= 1.0:
		_finished = true
		queue_free()
		return
	var fade := 1.0 - progress
	var eased := 1.0 - pow(1.0 - progress, 2.2)
	if _ring:
		_ring.scale = Vector3.ONE * lerpf(_radius * 0.2, _radius, eased)
	if _material:
		var color := _material.albedo_color
		color.a = 0.85 * fade
		_material.albedo_color = color
		_material.emission_energy_multiplier = 6.0 * fade
	if _light:
		_light.light_energy = 10.0 * fade * fade

