class_name StatusEffectBurn
extends Node3D
## 点燃 / 灼烧状态效果（持续伤害与烈焰视觉表现）。
##
## 挂载于受击敌人本体节点之下，具备：
## 1. 随怪物奔跑/受击实时跟随的 3D 火焰粒子、飞溅火星与升腾浓烟；
## 2. 动态暖橙色火焰光晕（照射怪物体表与周围地面）；
## 3. 周期性 DoT 伤害跳字与音效反馈；
## 4. 连续受击自动刷新持续时间并重置烈焰强度；
## 5. 目标死亡或效果结束时平滑退场，绝不残留泄漏。

const CombatFXUtil := preload("res://scripts/combat_fx.gd")
const AudioUtil := preload("res://scripts/audio_manager.gd")

var _target: Node = null
var _duration: float = 2.5
var _remaining_time: float = 2.5
var _tick_interval: float = 0.5
var _tick_timer: float = 0.5
var _tick_damage: float = 2.0
var _extinguishing := false

var _flames: CPUParticles3D
var _sparks: CPUParticles3D
var _smoke: CPUParticles3D
var _light: OmniLight3D


func setup(target_node: Node, params: Dictionary) -> void:
	_target = target_node
	_duration = float(params.get("duration", 2.5))
	_remaining_time = _duration
	var total_dmg: float = float(params.get("total_damage", 10.0))
	var ticks_count: float = maxf(_duration / _tick_interval, 1.0)
	_tick_damage = maxf(total_dmg / ticks_count, 1.0)

	# 居中对齐到怪物体表中心（胸腹高度）
	var height_offset := 0.85
	if _target is Node3D:
		height_offset = 0.85 * (_target as Node3D).scale.y
	position = Vector3(0.0, height_offset, 0.0)

	_build_visuals()
	AudioUtil.play_at("shot", global_position, -8.0, 2.4)


func refresh(params: Dictionary) -> void:
	var new_duration: float = float(params.get("duration", 2.5))
	_remaining_time = maxf(_remaining_time, new_duration)
	var new_total_dmg: float = float(params.get("total_damage", 10.0))
	var ticks_count: float = maxf(_remaining_time / _tick_interval, 1.0)
	_tick_damage = maxf(_tick_damage, new_total_dmg / ticks_count)
	_extinguishing = false

	if is_instance_valid(_flames):
		_flames.emitting = true
	if is_instance_valid(_sparks):
		_sparks.emitting = true
	if is_instance_valid(_smoke):
		_smoke.emitting = true
	if is_instance_valid(_light):
		_light.light_energy = 3.6


func _build_visuals() -> void:
	# 1. 升腾火舌粒子（Flames）
	_flames = CPUParticles3D.new()
	_flames.amount = 18
	_flames.lifetime = 0.55
	_flames.local_coords = false # 烟火停留在世界空间轨迹上
	_flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_flames.emission_sphere_radius = 0.35
	_flames.direction = Vector3.UP
	_flames.spread = 25.0
	_flames.gravity = Vector3(0.0, 2.2, 0.0)
	_flames.initial_velocity_min = 0.6
	_flames.initial_velocity_max = 1.6
	_flames.scale_amount_min = 0.22
	_flames.scale_amount_max = 0.55

	var fl_mesh := BoxMesh.new()
	fl_mesh.size = Vector3(0.12, 0.16, 0.12)
	var fl_mat := StandardMaterial3D.new()
	fl_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fl_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fl_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fl_mat.albedo_color = Color(1.0, 0.52, 0.12, 0.85)
	fl_mesh.material = fl_mat
	_flames.mesh = fl_mesh
	add_child(_flames)

	# 2. 飞溅火星粒子（Sparks / Embers）
	_sparks = CPUParticles3D.new()
	_sparks.amount = 12
	_sparks.lifetime = 0.75
	_sparks.local_coords = false
	_sparks.direction = Vector3.UP
	_sparks.spread = 45.0
	_sparks.gravity = Vector3(0.0, 1.4, 0.0)
	_sparks.initial_velocity_min = 1.0
	_sparks.initial_velocity_max = 2.4
	_sparks.scale_amount_min = 0.05
	_sparks.scale_amount_max = 0.12

	var sp_mesh := BoxMesh.new()
	sp_mesh.size = Vector3(0.05, 0.05, 0.05)
	var sp_mat := StandardMaterial3D.new()
	sp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sp_mat.albedo_color = Color(1.0, 0.82, 0.22, 1.0)
	sp_mesh.material = sp_mat
	_sparks.mesh = sp_mesh
	add_child(_sparks)

	# 3. 升腾黑烟粒子（Smoke）
	_smoke = CPUParticles3D.new()
	_smoke.amount = 10
	_smoke.lifetime = 0.95
	_smoke.local_coords = false
	_smoke.direction = Vector3.UP
	_smoke.spread = 20.0
	_smoke.gravity = Vector3(0.0, 2.0, 0.0)
	_smoke.initial_velocity_min = 0.4
	_smoke.initial_velocity_max = 1.0
	_smoke.scale_amount_min = 0.25
	_smoke.scale_amount_max = 0.65

	var sm_mesh := SphereMesh.new()
	sm_mesh.radius = 0.16
	sm_mesh.height = 0.32
	var sm_mat := StandardMaterial3D.new()
	sm_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm_mat.albedo_color = Color(0.12, 0.12, 0.14, 0.65)
	sm_mesh.material = sm_mat
	_smoke.mesh = sm_mesh
	add_child(_smoke)

	# 4. 烈焰照射光源（Light）
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.45, 0.12)
	_light.light_energy = 3.6
	_light.omni_range = 5.5
	_light.shadow_enabled = false
	add_child(_light)


func _process(delta: float) -> void:
	if not is_instance_valid(_target) or not _target.is_inside_tree():
		queue_free()
		return

	# 若目标已死亡（如血量归零或处于濒死动画中），停止喷火并优雅退场
	var health_val = _target.get("health")
	if health_val != null and float(health_val) <= 0.0:
		_extinguish()

	_remaining_time -= delta
	if _remaining_time <= 0.0:
		_extinguish()

	# 火光微晃
	if is_instance_valid(_light):
		_light.light_energy = (3.2 + sin(Time.get_ticks_msec() * 0.02) * 0.6) * (_remaining_time / _duration if _extinguishing else 1.0)

	# 周期结算 DoT 伤害与跳字
	if not _extinguishing:
		_tick_timer -= delta
		if _tick_timer <= 0.0:
			_tick_timer = _tick_interval
			_apply_tick_damage()


func _apply_tick_damage() -> void:
	if not is_instance_valid(_target):
		return
	var health_val = _target.get("health")
	if health_val != null and float(health_val) <= 0.0:
		_extinguish()
		return

	if _target.has_method("take_damage"):
		_target.call("take_damage", _tick_damage)

	# 弹出暖橙色灼烧伤害飘字
	var scene := get_tree().current_scene if get_tree() else null
	if scene:
		var target_pos := (_target as Node3D).global_position if _target is Node3D else global_position
		CombatFXUtil.spawn_damage_number(
			scene,
			target_pos + Vector3.UP * (1.6 * (_target.scale.y if _target is Node3D else 1.0)),
			_tick_damage,
			Color(1.0, 0.45, 0.12, 1.0),
			0.85
		)


func _extinguish() -> void:
	if _extinguishing:
		return
	_extinguishing = true
	if is_instance_valid(_flames):
		_flames.emitting = false
	if is_instance_valid(_sparks):
		_sparks.emitting = false
	if is_instance_valid(_smoke):
		_smoke.emitting = false
	if is_instance_valid(_light):
		var tween := create_tween()
		if tween:
			tween.tween_property(_light, "light_energy", 0.0, 0.4)
			tween.tween_callback(queue_free)
		else:
			queue_free()
	else:
		queue_free()

