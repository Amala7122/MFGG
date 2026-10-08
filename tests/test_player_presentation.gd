extends SceneTree
## 真实玩家相机的 FOV 收敛，以及 F / R / C 的独立输入路径。

const PlayerScene := preload("res://scenes/player.tscn")
const Flow := preload("res://scripts/game_flow.gd")
const RunState := preload("res://scripts/run_state.gd")
const Pool := preload("res://scripts/object_pool.gd")
const ActionCam := preload("res://scripts/cinematic_action_cam.gd")

class CapturedPlayer extends "res://scripts/player.gd":
	func _is_aim_captured() -> bool:
		return true

var _failed := false
var _world: Node3D
var _player: CharacterBody3D


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for _frame in range(3):
		await process_frame
	RunState.begin_run()
	Flow.instance.state = Flow.State.PLAYING
	Flow.instance._set_overlay_visible(false)
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	_player = PlayerScene.instantiate()
	_player.set_script(CapturedPlayer)
	_world.add_child(_player)
	_player.set_physics_process(false)
	_player._wisp.set_process(false)
	_player._wisp.set_physics_process(false)
	await process_frame
	paused = true
	_fov()
	await _input_actions()
	ActionCam.dismiss_active()
	paused = false
	current_scene = null
	_world.queue_free()
	await process_frame
	Pool.clear_all()
	RunState.begin_run()
	print("[玩家表现与输入] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _fov() -> void:
	var transition_samples: Array[float] = []
	for hz in [30, 60, 120]:
		for time_scale in [1.0, 0.15, 0.08]:
			var delta: float = time_scale / hz
			var steps := int(ceil(3.0 / delta))
			_player.camera.fov = _player.hip_fov
			_player._sprint_fov_offset = 0.0
			_player._fov_punch = 0.0
			_player._aiming = false
			_player._sprinting = true
			for _step in range(steps):
				_player._update_camera(delta)
				_check(_player.camera.fov <= _player.hip_fov + 4.501, "冲刺 FOV 不重复累加")
			_check(absf(_player.camera.fov - (_player.hip_fov + 4.5)) < 0.01,
				"30/60/120 Hz 与慢动作均收敛到基础 FOV +4.5°")
			_player._sprinting = false
			for _step in range(steps):
				_player._update_camera(delta)
			_check(absf(_player.camera.fov - _player.hip_fov) < 0.01, "停止冲刺恢复基础 FOV")
			_player._aiming = true
			_player._sprinting = true
			for _step in range(steps):
				_player._update_camera(delta)
			_check(absf(_player.camera.fov - _player.sniper_fov) < 0.01, "狙击不会保留冲刺 FOV 偏移")
		_player.camera.fov = _player.hip_fov
		_player._aiming = false
		_player._sprinting = true
		_player._sprint_fov_offset = 0.0
		for _step in range(hz / 2):
			_player._update_camera(1.0 / hz)
		transition_samples.append(_player.camera.fov)
		_player._sprinting = false
		_player._sprint_fov_offset = 0.0
		_player.camera.fov = _player.hip_fov
		_player._fov_punch = 6.0
		var peak: float = _player.camera.fov
		for _step in range(hz * 3):
			_player._update_camera(1.0 / hz)
			peak = maxf(peak, _player.camera.fov)
		_check(peak > _player.hip_fov and peak <= _player.hip_fov + 6.0
			and absf(_player.camera.fov - _player.hip_fov) < 0.01, "FOV 冲击有反馈、幅度有界且回落")
	_check(transition_samples.max() - transition_samples.min() < 0.15, "不同更新频率下冲刺过渡一致")
	print("[玩家表现与输入] FOV 冲刺、停止、狙击、冲击与九种步长通过")


func _key(key: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	return event


func _send_key(key: Key, pressed: bool) -> void:
	Input.parse_input_event(_key(key, pressed))
	Input.flush_buffered_events()


func _input_actions() -> void:
	_check(_key(KEY_F, true).is_action_pressed("flashlight")
		and not _key(KEY_F, true).is_action_pressed("resonance_burst"), "F 只映射手电筒")
	_check(_key(KEY_R, true).is_action_pressed("reload")
		and not _key(KEY_R, true).is_action_pressed("resonance_burst"), "R 只映射换弹")
	_check(_key(KEY_C, true).is_action_pressed("resonance_burst")
		and not _key(KEY_C, true).is_action_pressed("reload")
		and not _key(KEY_C, true).is_action_pressed("flashlight"), "C 为独立共鸣动作")
	_player._aiming = false
	_player._sprinting = false
	_player._flashlight_override = 0
	_player._update_flashlight()
	var resonance: Node = _player._resonance
	resonance._energy = resonance._max_energy
	var event := _key(KEY_F, true)
	_send_key(KEY_F, true)
	_player._input(event)
	_player._update_combat(0.016)
	_check(_player._flashlight.is_light_enabled() and resonance._energy == resonance._max_energy
		and not _player.is_cinematic_locked(), "共鸣满能量时按 F 仍只切换手电筒")
	_send_key(KEY_F, false)
	await process_frame
	_player._weapon._ammo = _player._weapon.magazine_capacity - 5
	_send_key(KEY_R, true)
	_player._update_combat(0.016)
	_check(_player._weapon.is_reloading() and resonance._energy == resonance._max_energy
		and not _player.is_cinematic_locked(), "共鸣满能量时按 R 正常换弹")
	_send_key(KEY_R, false)
	await process_frame
	_send_key(KEY_C, true)
	_player._update_combat(0.016)
	_check(is_zero_approx(float(resonance._energy)) and _player.is_cinematic_locked(),
		"独立 C 动作触发真实共鸣与电影镜头")
	_check(_player._flashlight.is_light_enabled(), "释放共鸣不切换手电筒")
	ActionCam.dismiss_active()
	await process_frame
	resonance._energy = resonance._max_energy
	_player._update_combat(0.016)
	_check(resonance._energy == resonance._max_energy and not _player.is_cinematic_locked(),
		"持续按住 C 不重复触发爆发")
	_send_key(KEY_C, false)
	print("[玩家表现与输入] F 手电筒、R 换弹、C 共鸣与按住边界通过")


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failed = true
		push_error("[玩家表现与输入] " + description)
