extends SceneTree
const Tuning = preload("res://scripts/prototypes/enemy_tuning.gd")
const Behavior = preload("res://scripts/prototypes/crawler_behavior.gd")
const Lab = preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
var failures := 0
var finish_count := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func run() -> void:
	test_behavior()
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	await process_frame
	await test_hornet_twitch(lab)
	for index in lab.GALLERY.size():
		var id := String(lab.GALLERY[index].profile)
		if not id.begins_with("Visual"):
			continue
		lab.call("_show_subject", index)
		await process_frame
		var subject: Node3D = lab.get("_subject")
		var death_index := int(subject.call("death_pose_index"))
		check(lab.get("_visual_panel").poses.item_count == subject.call("get_preview_pose_names").size(), "Death absent from pose menu")
		subject.call("set_preview_pose", death_index)
		lab.call("_update_status")
		check(lab.get("_timeline").visible, "Death must have a timeline")
		var duration := float(subject.call("get_preview_duration"))
		lab.call("_seek_visual", 1.0)
		check(is_equal_approx(float(subject.get("preview_time")), duration), "Death seek used the attack duration")
		for step in 61:
			subject.call("sample_pose", duration * step / 60.0)
			for node in subject.find_children("*", "Node3D", true, false):
				check(node.transform.is_finite(), id + " nonfinite death pose")
		if id == "VisualBurstCrawler":
			check(subject.get("poison_pool").visible, "Crawler death must leave poison film")
			for organ in subject.get("sac_organs"):
				check(not organ.visible, "Ruptured sac remained intact")
		else:
			check(is_equal_approx(subject.get("rig").rotation.z, PI), "Insect must end on its back")
			var first_leg: Dictionary = subject.get("legs")[0]
			var tip := (first_leg.shin as MeshInstance3D).global_transform * Vector3(0, ((first_leg.shin as MeshInstance3D).mesh as CylinderMesh).height * 0.5, 0)
			check(tip.y > (first_leg.node as Node3D).global_position.y + 0.2, "Inverted insect legs must point up")
			if id == "VisualPrismSpider":
				check(not subject.get("focus").visible and subject.get("dropped_eye").visible, "Spider eye did not detach")
		var final: Transform3D = subject.get("rig").transform
		var leg: Node3D = subject.get("legs")[0].node
		var shin: Transform3D = (subject.get("legs")[0].shin as Node3D).transform
		subject.call("sample_pose", duration + 50.0)
		check(subject.get("rig").transform.is_equal_approx(final), "Corpse must not loop back to life")
		check((subject.get("legs")[0].shin as Node3D).transform.is_equal_approx(shin), "Twitch must stop")
		subject.call("sample_pose", 0.1)
		subject.call("sample_pose", duration)
		check(subject.get("rig").transform.is_equal_approx(final), "Death seek is not deterministic")
		finish_count = 0
		subject.connect("death_finished", func(): finish_count += 1)
		subject.call("play_death")
		check(subject.is_in_group("enemy_death_effect"), "Settlement must wait while death plays")
		subject.call("_process", duration * 0.5)
		subject.call("play_death")
		check(float(subject.get("preview_time")) > 0.0, "Repeated death restarted animation")
		subject.call("_process", duration)
		subject.call("_process", duration)
		check(finish_count == 1 and not subject.is_in_group("enemy_death_effect"), "Death completion must emit once and release settlement")
		subject.call("reset_death_preview")
		check(not subject.get("death_fx").visible, "Replay reset leaked death effects")
		if id == "VisualBurstCrawler":
			var output: Dictionary = subject.call("update_combat", 0.1, Vector3(0, 0, -3))
			check(output.state == Behavior.State.RETREAT, "Live distance must trigger retreat")
			check(subject.get("back_armor").rotation.x < deg_to_rad(45), "Close-range back armor must immediately close")
			check(is_zero_approx(subject.get("back_armor").rotation.x), "Closed armor must not reopen when retreat begins")
			subject.call("reset_death_preview")
			var target := Node3D.new()
			lab.add_child(target)
			target.global_position = subject.global_position + subject.global_basis.orthonormalized() * Vector3(0, 0, -3)
			subject.call("set_combat_target", target)
			subject.call("_process", 0.1)
			check(subject.get("behavior").state == Behavior.State.RETREAT, "Bound combat target must drive actual distance detection")
			subject.call("set_combat_target", null)
			target.queue_free()
	lab.queue_free()
	await process_frame
	print("New enemy death / crawler behavior: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)

func test_hornet_twitch(lab: Node3D) -> void:
	for index in lab.GALLERY.size():
		if String(lab.GALLERY[index].profile) != "PrototypeHornet":
			continue
		lab.call("_show_subject", index)
		await process_frame
		var event := InputEventKey.new()
		event.physical_keycode = KEY_K
		event.pressed = true
		lab.call("_unhandled_input", event)
		var corpse = get_nodes_in_group("hornet_death_body")[0]
		corpse.set_physics_process(false)
		var before: Vector3 = corpse.legs[0].rotation
		corpse.call("_physics_process", 0.05)
		check(not corpse.legs[0].rotation.is_equal_approx(before), "Hornet death legs must twitch")
		corpse.queue_free()
		await process_frame

func test_behavior() -> void:
	var values := Tuning.defaults("VisualBurstCrawler")
	var brain := Behavior.new()
	var offset := Vector3(0, 0, -float(values.attack_range) + 1.0)
	var output := brain.update(0, offset, values)
	check(output.state == Behavior.State.TURN and not output.throw, "In range must turn before throwing")
	output = brain.update(float(values.turn_duration), offset, values)
	check(absf(absf(wrapf(float(output.yaw), -PI, PI)) - PI) < 0.01, "Must finish 180-degree turn")
	check(not output.throw, "Cannot throw during turn")
	# A player entering retreat range on the release frame takes priority over throwing.
	output = brain.update(float(values.release), Vector3(0, 0, -float(values.retreat_range)), values)
	check(output.state == Behavior.State.RETREAT and not output.throw and (output.velocity as Vector3).z > 0, "Retreat must cancel the pending throw")
	output = brain.update(0.2, Vector3(0, 0, -float(values.retreat_range) - 0.1), values)
	check(output.state == Behavior.State.RETREAT, "Retreat hysteresis must avoid range-edge flicker")
	brain.reset()
	var shots := 0
	for i in 300:
		output = brain.update(1.0 / 60.0, offset, values)
		if output.throw:
			shots += 1
	check(shots == 1, "Single attack must issue exactly one throw event")
	brain.kill()
	output = brain.update(10, Vector3.ZERO, values)
	check(not output.throw and (output.velocity as Vector3).is_zero_approx(), "Dead crawler must stop attacking and retreating")
