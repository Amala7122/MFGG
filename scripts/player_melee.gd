extends Node3D
## 空格轻扫 / 蓄力重击。输入、判定和姿势共用秒时钟，不异步遗留命中回调。
const Settings := preload("res://scripts/player_melee_settings.gd")
const Targets := preload("res://scripts/player_melee_targets.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Health := preload("res://scripts/health_util.gd")
const Flow := preload("res://scripts/game_flow.gd")
const Audio := preload("res://scripts/audio_manager.gd")
const FX := preload("res://scripts/combat_fx.gd")
const Events := preload("res://scripts/event_bus.gd")
const TuningPanel := preload("res://scripts/player_melee_panel.gd")

var parameters: Dictionary = {}
var phase := "idle"
var heavy_cooldown := 0.0
var attack_count := 0
var last_hit_count := 0
var _host: CharacterBody3D
var _weapon: Node
var _elapsed := 0.0
var _down := false
var _press_age := 0.0
var _pending := false
var _released := false
var _buffer_left := 0.0
var _charged := false
var _hit := false
var _combo := 0
var _combo_idle := 0.0
var _feedback_pause := 0.0
var _slash: MeshInstance3D
var _panel: CanvasLayer

func setup(host: CharacterBody3D, weapon: Node) -> void:
	_host = host
	_weapon = weapon
	parameters = Settings.load_values()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(3.6, 0.65)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(1.0, 0.8, 0.35, 0.24)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.55, 0.15)
	material.emission_energy_multiplier = 1.4
	mesh.material = material
	_slash = MeshInstance3D.new()
	_slash.mesh = mesh
	_slash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_slash.visible = false
	add_child(_slash)
	_panel = TuningPanel.new()
	_panel.setup(self, host)
	add_child(_panel)

func can_control() -> bool:
	return is_instance_valid(_host) and not parameters.is_empty() and not get_tree().paused \
		and Flow.is_playing() and _host._is_aim_captured() \
		and not _host._dying and not _host._cinematic_locked and not _host._rolling

func _input(event: InputEvent) -> void:
	if event.is_echo() or not event.is_action("melee") or not can_control():
		return
	if event.is_action_pressed("melee"):
		_down = true
		_pending = true
		_released = false
		_press_age = 0.0
		_buffer_left = float(parameters.input_buffer)
	elif event.is_action_released("melee"):
		_down = false
		_released = true
	get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		cancel()

func tick(delta: float, allowed: bool) -> void:
	heavy_cooldown = maxf(heavy_cooldown - delta, 0.0)
	if not allowed or not can_control():
		cancel()
		return
	_combo_idle += delta
	if _combo_idle > float(parameters.combo_reset):
		_combo = 0
	if _pending and _down:
		_press_age += delta
	if phase == "idle" or (phase == "sweep" and _elapsed >= float(parameters.sweep_cancel)):
		if _pending:
			if _released:
				_start("heavy" if _press_age >= float(parameters.charge_threshold) and heavy_cooldown <= 0.0 else "sweep")
			elif _press_age >= float(parameters.charge_enter) and heavy_cooldown <= 0.0:
				phase = "charge"
				_elapsed = 0.0
			else:
				# 按住时不消耗输入缓存；完整短点按可跨过一次物理帧。
				pass
	elif phase != "charge" and _pending:
		_buffer_left -= delta
		if _buffer_left <= 0.0:
			_pending = false
	if phase == "charge":
		if not _charged and _press_age >= float(parameters.charge_threshold):
			_charged = true
			Audio.play("pickup", -12.0, 1.2)
		if _released or _press_age >= float(parameters.charge_auto):
			_start("heavy" if _press_age >= float(parameters.charge_threshold) else "sweep")
	elif phase == "sweep" or phase == "heavy":
		if _feedback_pause > 0.0:
			_feedback_pause = maxf(_feedback_pause - delta, 0.0)
		else:
			_elapsed += delta
		if not _hit and _elapsed >= float(parameters[phase + "_windup"]):
			_hit = true
			_strike(phase)
		if _elapsed >= float(parameters[phase + "_total"]):
			phase = "idle"
	_update_pose()

func _start(kind: String) -> void:
	phase = kind
	_elapsed = 0.0
	_hit = false
	_charged = false
	_pending = false
	_released = false
	_combo_idle = 0.0
	attack_count += 1
	last_hit_count = 0
	if kind == "heavy":
		heavy_cooldown = float(parameters.heavy_cooldown)
		_lunge(float(parameters.heavy_lunge))
	else:
		_combo = 1 - _combo
	Audio.play("whoosh", -3.0, 0.85 if kind == "heavy" else 1.15)

func _strike(kind: String) -> void:
	var forward := _forward()
	var fodder_damage := float(parameters[kind + "_damage"])
	var fodder_reach := float(parameters[kind + "_reach"])
	for field in _host.get_tree().get_nodes_in_group("fodder_fields"):
		if is_instance_valid(field) and field.has_method("cone_hit"):
			field.call("cone_hit", _host.global_position, forward, fodder_reach,
				deg_to_rad(60.0), fodder_damage, float(parameters[kind + "_push"]))
	var candidates := Targets.collect(_host, forward, float(parameters[kind + "_reach"]),
		float(parameters[kind + "_radius"]), float(parameters[kind + "_half_angle"]), int(parameters.candidate_limit))
	var context := Telemetry.begin_attack(_host, "melee_" + kind)
	context.merge({"source_kind": "player", "melee_kind": kind,
		"armor_penetration": float(parameters.heavy_armor_pen) if kind == "heavy" else 0.0,
		"managed_reaction": true}, true)
	for candidate in candidates:
		if last_hit_count >= int(parameters[kind + "_max_targets"]):
			break
		var target: Node3D = candidate.target
		var before := Health.health_or(target, 0.0)
		Telemetry.hurt_enemy(target, float(parameters[kind + "_damage"]), context)
		last_hit_count += 1
		var actual_damage := maxf(before - Health.health_or(target, 0.0), 0.0)
		var scene := get_tree().current_scene
		if actual_damage > 0.0 and is_instance_valid(scene):
			var color := Color(1.0, 0.75, 0.32)
			FX.spawn_impact(scene, candidate.point, -forward, color, 1.5 if kind == "heavy" else 0.8)
			FX.spawn_damage_number(scene, candidate.point + Vector3.UP * 0.3, actual_damage, color, 1.4 if kind == "heavy" else 1.0)
			Events.emit_hit_confirmed(false, not Health.is_alive(target))
		# 泰坦的泥盾、破招和阶段反应仍完全由 Boss 自己决定。
		if is_instance_valid(target) and Health.is_alive(target) and not target.is_in_group("boss"):
			var push := forward * float(parameters[kind + "_push"])
			if target.has_method("trigger_hit_stagger"):
				target.call("trigger_hit_stagger", push, float(parameters.heavy_stagger) if kind == "heavy" else 0.0)
			else:
				if target.has_method("apply_push"):
					target.call("apply_push", forward, float(parameters[kind + "_push"]))
				if kind == "heavy" and target.has_method("apply_grenade_stagger"):
					target.call("apply_grenade_stagger", float(parameters.heavy_stagger))
	if last_hit_count > 0:
		if kind == "sweep":
			_lunge(float(parameters.sweep_lunge))
		_feedback_pause = 0.06 if kind == "heavy" else 0.04
		_host.apply_hitstop(_feedback_pause)
		_host.apply_camera_shake(0.65 if kind == "heavy" else 0.3)
		_host.trigger_fov_punch(3.5 if kind == "heavy" else 1.5)
		_host.apply_rumble(0.35, 0.6 if kind == "heavy" else 0.2, 0.12)
		Audio.play("hit_metal" if kind == "heavy" else "hit", 0.0, 0.85 if kind == "heavy" else 1.0)

func _forward() -> Vector3:
	var forward: Vector3 = -_host.camera_pivot.global_basis.z
	forward.y = 0.0
	return forward.normalized() if not forward.is_zero_approx() else Vector3.FORWARD

func _lunge(distance: float) -> void:
	if distance > 0.0:
		_host.move_and_collide(_forward() * distance) # 扫掠碰撞，不穿墙瞬移。

func movement_scale() -> float:
	if phase == "charge":
		return float(parameters.charge_speed_scale)
	return float(parameters.sweep_speed_scale) if is_attacking() else 1.0

func is_attacking() -> bool:
	return phase != "idle"

func _update_pose() -> void:
	var pose := Vector3.ZERO
	if phase == "charge":
		pose = Vector3(0.35, 0.0, -0.25) * clampf(_press_age / float(parameters.charge_threshold), 0.0, 1.0)
	elif phase == "sweep" or phase == "heavy":
		var windup := float(parameters[phase + "_windup"])
		var active_end := windup + float(parameters[phase + "_active"])
		var total := float(parameters[phase + "_total"])
		var side := 1.0 if _combo == 0 else -1.0
		var ready := Vector3(0.25, 0.0, side * 0.8)
		var slash := Vector3(-1.35, -side * 0.18, -side * 1.1)
		if phase == "heavy":
			ready = Vector3(0.35, 0.0, -0.25)
			slash = Vector3(-1.6, 0.1, 0.8)
		if _elapsed < windup:
			pose = ready.lerp(slash, clampf(_elapsed / windup, 0.0, 1.0))
		else:
			pose = slash.lerp(Vector3.ZERO, clampf((_elapsed - active_end) / maxf(total - active_end, 0.01), 0.0, 1.0))
	_weapon.set_melee_pose(pose, is_attacking())
	_slash.visible = _hit and (phase == "sweep" or phase == "heavy") and _elapsed < float(parameters[phase + "_windup"]) + 0.14
	if _slash.visible:
		_slash.global_position = _host.global_position + Vector3.UP * 0.4 + _forward() * 1.4
		_slash.global_rotation = Vector3(-PI * 0.5, _host.camera_pivot.global_rotation.y, 0.2 if _combo == 0 else -0.2)

func on_hurt(previous_shield: float, current_shield: float, health_damage: float) -> void:
	if phase == "charge" and ((previous_shield > 0.0 and current_shield <= 0.0) or health_damage >= 28.0):
		cancel()
		heavy_cooldown = maxf(heavy_cooldown, float(parameters.heavy_cooldown) * float(parameters.interrupt_cooldown_scale))

func cancel() -> void:
	phase = "idle"
	_pending = false
	_down = false
	_released = false
	_charged = false
	_feedback_pause = 0.0
	_hit = false
	if is_instance_valid(_weapon):
		_weapon.set_melee_pose(Vector3.ZERO, false)
	if is_instance_valid(_slash):
		_slash.visible = false

func configure(values: Dictionary) -> void:
	var valid := Settings.validate(values)
	if valid.is_empty():
		return
	cancel()
	parameters = valid

func get_status() -> Dictionary:
	var text := "空格 点按轻扫 / 长按重击 · F7 调参"
	if phase == "charge":
		text = "空格 重击已就绪 · 松开释放" if _charged else "空格 蓄力 %d%%" % roundi(_press_age / float(parameters.charge_threshold) * 100.0)
	elif heavy_cooldown > 0.0:
		text = "空格 轻扫可用 · 重击 %.1fs" % heavy_cooldown
	return {"text": text, "phase": phase, "heavy_cooldown": heavy_cooldown}
