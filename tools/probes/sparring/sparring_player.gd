extends "res://scripts/player.gd"
## 仅诊断输入与记录适配；正式移动、武器、血盾、恢复、受伤与判定不变。
var sparring_active := false
var sparring_mode := "auto"
var driver: RefCounted
var recorder: RefCounted
var opponent: Node3D
var controls: Dictionary = {}
var replay_frames: Array = []
var replay_index := 0

func begin_sparring(controller: RefCounted, logbook: RefCounted, boss: Node3D, mode: String, frames: Array = []) -> void:
	driver = controller
	recorder = logbook
	opponent = boss
	sparring_mode = mode
	replay_frames = frames
	replay_index = 0
	sparring_active = true
	set_meta(&"combat_recorder", logbook)

func _physics_process(delta: float) -> void:
	if sparring_active and not _dying:
		if sparring_mode == "replay" and replay_index < replay_frames.size():
			var frame: Dictionary = replay_frames[replay_index]
			controls = {"held": frame.held, "just": frame.just, "move_local": Vector2(float(frame.move[0]), float(frame.move[1])), "activity": "replay", "aim_captured": frame.get("aim_captured", true)}
			target_yaw = float(frame.yaw)
			target_pitch = float(frame.pitch)
			replay_index += 1
		elif sparring_mode in ["auto", "imitate"]:
			if not is_instance_valid(opponent):
				opponent = null
			controls = driver.call("step", self, opponent, delta)
			if controls.has("view_yaw"):
				target_yaw = float(controls.view_yaw)
			if controls.has("view_pitch"):
				target_pitch = float(controls.view_pitch)
			if controls.has("scan_yaw"):
				target_yaw += float(controls.scan_yaw)
			if controls.has("scan_pitch"):
				target_pitch = move_toward(target_pitch, float(controls.scan_pitch), delta)
			if bool(controls.get("has_aim", false)):
				var offset: Vector3 = controls.aim_point - camera.global_position
				var error: Vector2 = controls.get("aim_error", Vector2.ZERO)
				var rate := deg_to_rad(float(driver.profile.turn_degrees_per_second)) * delta
				target_yaw = rotate_toward(target_yaw, atan2(-offset.x, -offset.z) + error.x, rate)
				target_pitch = move_toward(target_pitch, clampf(atan2(offset.y, Vector2(offset.x, offset.z).length()) + error.y, deg_to_rad(-65.0), deg_to_rad(60.0)), rate)
		if recorder != null:
			recorder.call("record_input", self, controls, delta)
	super._physics_process(delta)
	if sparring_active and recorder != null:
		recorder.call("record_input_effects", self)
	controls["just"] = {}

func _held(action: String) -> bool:
	if not sparring_active:
		return false
	return super._held(action) if sparring_mode == "manual" else bool(controls.get("held", {}).get(action, false))

func _just(action: String) -> bool:
	if not sparring_active:
		return false
	return super._just(action) if sparring_mode == "manual" else bool(controls.get("just", {}).get(action, false))

func _move_vector() -> Vector2:
	if not sparring_active:
		return Vector2.ZERO
	if sparring_mode == "manual":
		return super._move_vector()
	if controls.has("move_local"):
		return controls.move_local
	var direction: Vector3 = camera_pivot.global_basis.inverse() * Vector3(controls.get("move_world", Vector3.ZERO))
	return Vector2(direction.x, direction.z).limit_length()

func _is_aim_captured() -> bool:
	return super._is_aim_captured() if sparring_mode == "manual" else sparring_active and bool(controls.get("aim_captured", true))

func _input(event: InputEvent) -> void:
	if sparring_active and sparring_mode == "manual":
		super._input(event)

func take_damage(amount: float, source_position: Vector3 = Vector3.ZERO, shield_damage_scale: float = 1.0) -> void:
	var hp := health
	var sp := shield
	var blocked := _damage_invulnerability > 0.0 or health <= 0.0
	var defence := {"rolling": _rolling, "iframes": _damage_invulnerability, "dodge_cooldown": _dodge_cooldown,
		"cinematic_locked": _cinematic_locked, "health": health, "shield": shield}
	super.take_damage(amount, source_position, shield_damage_scale)
	if recorder != null:
		recorder.call("record_player_hit", self, amount, hp - health, sp - shield, blocked, get_meta(&"combat_context", {}), defence)

func _die() -> void:
	# 使用正式 take_damage 的归零判定，只隔离战绩／场景结算，供连续诊断。
	if _dying:
		return
	_dying = true
	_rolling = false
	_sprinting = false
	_aiming = false
	if _rig:
		_rig.begin_death()

func _finish_death() -> void:
	_death_event_sent = true
	set_physics_process(false)
