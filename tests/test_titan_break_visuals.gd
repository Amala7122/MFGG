extends SceneTree
## 正式地图中的受控视觉分段；不冒充真人或胜率，真实E/枪线另有机制契约。
const Lab := preload("res://prototypes/sparring_lab/combat_sparring_lab.tscn")
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures := 0
func _initialize() -> void:call_deferred("_run")
func frames(count: int) -> void:
	for _i in range(count):await physics_frame
func capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots", "titan_breaks").path_join(name + ".png")) != OK:
		failures += 1
		push_error("视觉截图保存失败")
func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("本项需要图形")
		quit(1)
		return
	Settings.pending_run = {"scenario_id": "titan_sanctum", "mode": "manual", "autostart": false, "scenario_overrides": {"boss_phase": "front"}}
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	for _i in range(1800):
		await process_frame
		if is_instance_valid(lab.session):break
	if not is_instance_valid(lab.session):
		push_error("正式地图未准备")
		quit(1)
		return
	var session: Node = lab.session
	var boss: Node3D = session.boss
	var player: Node3D = session.actor
	session._panel.visible = false
	boss.ai_enabled = false
	player.set_physics_process(false)
	paused = false
	boss.position = Vector3(0, 2.86, 31)
	var camera := Camera3D.new()
	lab.add_child(camera)
	camera.make_current()
	camera.global_position = Vector3(12, 9, 48)
	camera.look_at(Vector3(0, 4, 31))
	await frames(12)
	boss.receive_grenade_contact(10, 101, {})
	boss.receive_grenade_contact(10, 102, {})
	await frames(5)
	await capture("shield_two_cracks")
	boss.receive_grenade_contact(10, 103, {})
	await frames(42)
	await capture("kneel_effective")
	await frames(300)
	boss.current_hp = boss.max_hp * .49
	boss._trigger_rage()
	await frames(30)
	boss._crystal_clock = .12
	await frames(1)
	await capture("crystal_open")
	boss.take_weapon_hit(100, boss.core_mesh.global_position, true, {"weapon_kind": "sniper", "shot_id": "visual1", "hit_region": "crystal"})
	await frames(5)
	await capture("crystal_guard")
	await frames(302)
	boss.take_weapon_hit(100, boss.core_mesh.global_position, true, {"weapon_kind": "sniper", "shot_id": "visual2", "hit_region": "crystal"})
	await frames(302)
	boss.take_weapon_hit(100, boss.core_mesh.global_position, true, {"weapon_kind": "sniper", "shot_id": "visual3", "hit_region": "crystal"})
	await frames(52)
	await capture("down_effective")
	if boss._reward_kind != "down" or boss.current_state != boss.State.REWARD_HOLD:
		failures += 1
		push_error("截图应处于真实倒地有效状态")
	await frames(560)
	await capture("crystal_reset")
	current_scene = null
	lab.queue_free()
	paused = false
	await frames(6)
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	print("[泰坦破解视觉] failures=", failures)
	quit(1 if failures else 0)
