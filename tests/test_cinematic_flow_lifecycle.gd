extends SceneTree
## 真实输入、镜头、暂停界面和狙击场景的生命周期交接。

const PlayerScene := preload("res://scenes/player.tscn")
const RangedScene := preload("res://scenes/ranged_enemy.tscn")
const Ranged := preload("res://scripts/ranged_enemy.gd")
const Flow := preload("res://scripts/game_flow.gd")
const WaveDirector := preload("res://scripts/wave_director.gd")
const KillCam := preload("res://scripts/cinematic_kill_cam.gd")
const ActionCam := preload("res://scripts/cinematic_action_cam.gd")
const RunState := preload("res://scripts/run_state.gd")
const Limiter := preload("res://scripts/skill_limiter.gd")
const EventBus := preload("res://scripts/event_bus.gd")
const Pool := preload("res://scripts/object_pool.gd")
const Terrain := preload("res://scripts/terrain_field.gd")

class CapturedPlayer extends "res://scripts/player.gd":
	func _is_aim_captured() -> bool:
		return true

class VisibleSniper extends "res://scripts/ranged_enemy.gd":
	func can_attack_from_current_view() -> bool:
		return true

var _failed := false
var _world: Node3D
var _player: CharacterBody3D
var _flow: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for _frame in range(3):
		await process_frame
	_flow = Flow.instance
	await _input_guard()
	await _wave_pause(false)
	await _wave_pause(true)
	await _pending_requests()
	await _camera_handoff()
	await _sniper_ownership()
	await _scene_exit()
	await _live_pause()
	await _dispose()
	RunState.begin_run()
	Pool.clear_all()
	await create_timer(0.5).timeout
	print("[电影与名额测试] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)


func _fixture() -> void:
	await _dispose()
	RunState.begin_run()
	_flow.state = Flow.State.PLAYING
	_flow._set_overlay_visible(false)
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	_player = PlayerScene.instantiate()
	_player.set_script(CapturedPlayer)
	_player.position = Vector3(0, Terrain.height_at(0, 0) + 1, 0)
	_world.add_child(_player)
	_player.set_physics_process(false)
	_player._wisp.set_process(false)
	_player._wisp.set_physics_process(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await process_frame


func _director() -> Node:
	var spawner := Node.new()
	spawner.name = "EnemySpawner"
	_world.add_child(spawner)
	var director := WaveDirector.new()
	_world.add_child(director)
	director.set_process(false)
	return director


func _input_guard() -> void:
	await _fixture()
	_player.set_cinematic_locked(true)
	var before_ammo: int = _player._weapon.get_ammo()
	_player._weapon._fire_cooldown = 0.5
	_player._weapon._sniper_reload_timer = 0.5
	_player._resonance._energy = _player._resonance._max_energy
	var energy: float = _player._resonance._energy
	for action in ["shoot", "aim", "reload", "resonance_burst", "grenade", "skill", "dodge", "sprint"]:
		Input.action_press(action)
	_player._update_combat(0.1)
	_check(_player._weapon.get_ammo() == before_ammo and not _player._aiming,
		"电影期间开枪和瞄准被阻止")
	_check(_player._grenade_cooldown == 0.0 and _player._skill_cooldown == 0.0
		and _player._resonance._energy == energy, "电影期间手雷、脉冲与共鸣不被触发")
	_check(is_equal_approx(float(_player._weapon._fire_cooldown), 0.4)
		and is_equal_approx(float(_player._weapon._sniper_reload_timer), 0.4),
		"电影期间武器冷却和自动装填继续更新")
	var mouse := InputEventMouseMotion.new()
	mouse.relative = Vector2(100, 50)
	var yaw: float = _player.target_yaw
	var pitch: float = _player.target_pitch
	_player._input(mouse)
	_check(_player.target_yaw == yaw and _player.target_pitch == pitch, "电影期间鼠标不能改视角")
	for action in ["shoot", "aim", "reload", "resonance_burst", "grenade", "skill", "dodge", "sprint"]:
		Input.action_release(action)
	_player.set_cinematic_locked(false)
	_player._input(mouse)
	_check(_player.target_yaw != yaw, "镜头退出后恢复鼠标输入")
	print("[电影与名额测试] 输入守卫与内部冷却通过")


func _wave_pause(boss: bool) -> void:
	await _fixture()
	var director := _director()
	if boss:
		director._state = WaveDirector.State.BOSS
		director._tick_boss()
	else:
		director._state = WaveDirector.State.BREAK
		director._timer = 0.0
		director._play_wave_clear_cinematic(1, 4, null, _player.position + Vector3.FORWARD * 3)
	var cam := KillCam.active_cam
	_check(is_instance_valid(cam) and _player.is_cinematic_locked(), "波次/霸主特写持有玩家输入锁")
	if not is_instance_valid(cam):
		return
	cam.set_process(false)
	_advance_camera(cam, 0.2)
	var elapsed: float = cam._elapsed_real_time
	var position := cam.global_transform
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	_flow._input(cancel)
	cam._process(1.0)
	await create_timer(3.2, true, false, true).timeout
	_check(_flow.state == Flow.State.PAUSED and paused, "特写期间按暂停，不会被选卡或结算覆盖")
	_check(cam._elapsed_real_time == elapsed and cam.global_transform == position
		and is_equal_approx(Engine.time_scale, 0.15), "暂停冻结运镜、寿命和慢动作倍率")
	_flow._on_resume()
	_check(KillCam.active_cam == cam and _player.is_cinematic_locked(), "继续后保留同一特写和输入锁")
	director._process(1.0)
	_check(director._state == (WaveDirector.State.CLEARED if boss else WaveDirector.State.BREAK),
		"特写期间不会开下一波")
	_advance_camera(cam, 3.1)
	_check(_flow.state == (Flow.State.STAGE_CLEAR if boss else Flow.State.UPGRADE_PICK) and paused,
		"特写真正结束后进入一次对应流程")
	_check(not _player.is_cinematic_locked() and is_equal_approx(Engine.time_scale, 1.0)
		and _player.camera.current, "结束归还相机、输入和时间倍率")
	print("[电影与名额测试] ", "霸主结算" if boss else "波间赐福", "暂停/继续/完成通过")


func _pending_requests() -> void:
	await _fixture()
	_flow._enter_pause()
	EventBus.emit_upgrade_pick_requested(1, 4)
	_check(_flow.state == Flow.State.PAUSED and _flow._pending_transition.get("kind") == "upgrade",
		"暂停期间收到选卡请求只暂存")
	_flow._on_open_display_settings()
	EventBus.emit_upgrade_pick_requested(1, 4)
	_check(_flow.state == Flow.State.DISPLAY_SETTINGS, "显示设置不会被选卡覆盖")
	_flow._on_display_settings_back()
	_check(_flow.state == Flow.State.PAUSED, "显示设置先返回暂停")
	_flow._on_resume()
	_check(_flow.state == Flow.State.UPGRADE_PICK and _flow._pending_transition.is_empty(),
		"继续后只消费一次待选卡请求")
	_flow._resume_play()
	_flow._enter_pause()
	EventBus.emit_upgrade_pick_requested(2, 4)
	EventBus.emit_stage_cleared(1)
	EventBus.emit_upgrade_pick_requested(2, 4)
	_flow._on_resume()
	_check(_flow.state == Flow.State.STAGE_CLEAR, "待结算优先于待选卡")
	for state in [Flow.State.MENU, Flow.State.DYING, Flow.State.GAME_OVER, Flow.State.STAGE_CLEAR, Flow.State.UPGRADE_PICK]:
		_flow.state = state
		EventBus.emit_upgrade_pick_requested(1, 4)
		EventBus.emit_stage_cleared(1)
		_check(_flow.state == state, "终止/菜单流程拒绝迟到请求")
	_flow.state = Flow.State.PAUSED
	EventBus.emit_upgrade_pick_requested(3, 4)
	_flow._enter_menu()
	_check(_flow._pending_transition.is_empty(), "返回菜单清理旧局待执行请求")
	print("[电影与名额测试] 请求暂存、终止拒绝与结算优先级通过")


func _camera_handoff() -> void:
	await _fixture()
	var action := ActionCam.new()
	_world.add_child(action)
	action.start(_player, 0.5, 0.08)
	action.set_process(false)
	var kill := KillCam.new()
	_world.add_child(kill)
	kill.start(null, _player.position, false, 0.8)
	kill.set_process(false)
	await process_frame
	_check(kill.current and _player.is_cinematic_locked() and is_equal_approx(Engine.time_scale, 0.15),
		"动作镜头交给终结镜头，旧镜头退出不解锁或覆盖时间倍率")
	kill.restore_and_destroy()
	kill.restore_and_destroy()
	var next := ActionCam.new()
	_world.add_child(next)
	next.start(_player, 0.5, 0.08)
	next.set_process(false)
	await process_frame
	_check(next.current and _player.is_cinematic_locked() and is_equal_approx(Engine.time_scale, 0.08),
		"重复释放和旧退出不能覆盖新动作镜头")
	_flow._enter_pause()
	var elapsed: float = next._elapsed_real_time
	next._process(1.0)
	_check(next._elapsed_real_time == elapsed, "动作镜头同样尊重暂停")
	_flow._on_resume()
	_advance_camera(next, 0.6)
	_check(not _player.is_cinematic_locked() and is_equal_approx(Engine.time_scale, 1.0),
		"动作镜头自然结束恢复控制权")
	print("[电影与名额测试] 跨类型镜头交接与幂等退出通过")


func _sniper() -> CharacterBody3D:
	var sniper := RangedScene.instantiate() as CharacterBody3D
	# 替换可见性判定之前，释放旧脚本构造但尚未挂树的 Rig。
	(sniper.get("_rig") as Node).free()
	sniper.set_script(VisibleSniper)
	sniper.position = _player.position + Vector3.FORWARD * 5
	_world.add_child(sniper)
	sniper.set_physics_process(false)
	sniper.target = _player
	sniper.pattern_type = Ranged.PatternType.SNIPER
	return sniper


func _advance_camera(cam: Camera3D, seconds: float) -> void:
	cam.set("_last_msec", Time.get_ticks_msec() - roundi(seconds * 1000.0))
	cam.call("_process", 0.0)


func _charge(sniper: CharacterBody3D) -> void:
	Ranged.next_global_fire_msec = 0
	sniper.fire_cooldown = 0.0
	sniper.update_firing(0.01, 5.0)


func _sniper_ownership() -> void:
	await _fixture()
	var first := _sniper()
	var second := _sniper()
	_charge(first)
	_check(first.attack_queued and not Limiter.can_start("sniper_lock"), "真实狙击蓄力获取一个名额")
	second.cancel_attack_charge()
	_charge(second)
	_check(first.attack_queued and not second.attack_queued and not Limiter.can_start("sniper_lock"),
		"未持有名额的狙击兵取消，不释放他人名额")
	first.cancel_attack_charge()
	_charge(second)
	first.cancel_attack_charge()
	_check(second.attack_queued and not Limiter.can_start("sniper_lock"), "重复取消不能释放新持有者")
	second.update_firing(10.0, 5.0)
	_check(Limiter.can_start("sniper_lock"), "实际狙击出手归还名额")
	_charge(first)
	first.die()
	_check(Limiter.can_start("sniper_lock"), "狙击兵死亡即回收名额")
	_charge(second)
	RunState.begin_run()
	var third := _sniper()
	_charge(third)
	second.cancel_attack_charge()
	_check(third.attack_queued and not Limiter.can_start("sniper_lock"), "整局重置后旧持有者不能释放新名额")
	_world.remove_child(third)
	_check(Limiter.can_start("sniper_lock"), "退出场景立即回收名额")
	third.free()
	print("[电影与名额测试] 真实狙击持有、取消、出手、死亡、重开与退出通过")


func _scene_exit() -> void:
	await _fixture()
	var director := _director()
	director._play_wave_clear_cinematic(1, 4, null, _player.position)
	var sniper := _sniper()
	_charge(sniper)
	_flow._enter_pause()
	EventBus.emit_upgrade_pick_requested(1, 4)
	_world.queue_free()
	current_scene = null
	await process_frame
	_world = Node3D.new()
	root.add_child(_world)
	current_scene = _world
	_flow._on_resume()
	await create_timer(3.2, true, false, true).timeout
	_check(_flow.state == Flow.State.PLAYING and _flow._pending_transition.is_empty(),
		"旧场景卸载后没有迟到特写回调或待选卡请求")
	_check(Limiter.can_start("sniper_lock") and is_equal_approx(Engine.time_scale, 1.0)
		and not is_instance_valid(KillCam.active_cam), "卸载回收狙击名额与镜头倍率")
	print("[电影与名额测试] 场景退出无旧回调、锁和名额残留通过")


func _dispose() -> void:
	if is_instance_valid(_flow):
		_flow._pending_transition.clear()
		_flow._dismiss_cinematics()
	paused = false
	if is_instance_valid(_world):
		current_scene = null
		_world.queue_free()
		await process_frame
	_world = null
	Engine.time_scale = 1.0


func _live_pause() -> void:
	if not "--live-cinematics" in OS.get_cmdline_user_args():
		return
	await _fixture()
	var director := _director()
	director._play_wave_clear_cinematic(1, 4, null, _player.position + Vector3.FORWARD * 3)
	var cam := KillCam.active_cam
	await _wait_real(0.25)
	_check(cam._elapsed_real_time > 0.1 and _flow.state == Flow.State.PLAYING,
		"真实帧循环按现实时间播放慢动作特写")
	_flow._enter_pause()
	var elapsed: float = cam._elapsed_real_time
	var pose := cam.global_transform
	await _wait_real(2.4)
	_check(_flow.state == Flow.State.PAUSED and cam._elapsed_real_time == elapsed
		and cam.global_transform == pose, "真实帧循环暂停超过特写时长仍保持暂停")
	_flow._on_resume()
	await _wait_real(2.4)
	_check(_flow.state == Flow.State.UPGRADE_PICK and paused and not _player.is_cinematic_locked(),
		"真实继续后播放剩余特写，再自动进入赐福")
	print("[电影与名额测试] 真实帧循环慢动作/暂停/继续通过")


func _wait_real(seconds: float) -> void:
	var until := Time.get_ticks_msec() + roundi(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[电影与名额测试] " + message)
