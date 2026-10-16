extends "res://scripts/prototypes/crystal_creature_visual.gd"
## 棱眼蛛：八腿支架、小腹部、正面主晶眼，瞄准时打开护眼甲。
var head: Node3D
var shutters: Array[Node3D] = []
var focus: Node3D
var dropped_eye: Node3D

func profile_id() -> String:
	return "VisualPrismSpider"

func build_creature() -> void:
	shutters.clear()
	var height := p("body_height")
	oval(body, "Abdomen", Vector3(0, height, 0.57), Vector3(1.05, 0.78, 1.28) * p("abdomen_size"), rock)
	oval(body, "Thorax", Vector3(0, height, -0.23), Vector3(0.85, 0.52, 0.82), dark)
	for side in [-1.0, 1.0]:
		for i in 4:
			var z := -0.66 + i * 0.40
			var spread := [-0.85, -0.33, 0.40, 1.03][i] as float
			var reach := p("leg_span") * (0.88 if i == 0 or i == 3 else 1.0)
			limb("SpiderLeg", Vector3(side * 0.34, height, z), Vector3(side * reach * 0.66, height + 0.32, z + spread * 0.35), Vector3(side * reach, 0.055, z + spread), p("leg_thickness"), PI * (i % 2 + (1 if side > 0 else 0)))
		horn(body, "AbdomenSeam", [Vector3(side * 0.22, height + 0.27, 0.20), Vector3(side * 0.25, height + 0.43, 0.67), Vector3(side * 0.19, height + 0.22, 1.15)], [0.045, 0.055, 0.0], crystal)
	head = pivot(body, "EyeHead", Vector3(0, height, -0.67))
	oval(head, "EyeArmor", Vector3.ZERO, Vector3(1.04, 0.88, 0.68), rock)
	oval(head, "RecessedSocket", Vector3(0, 0, -0.30), Vector3(0.83, 0.72, 0.26), dark)
	focus = pivot(head, "FocusCrystal", Vector3(0, 0, -0.43))
	oval(focus, "SingleCrystalEye", Vector3.ZERO, Vector3(0.63, 0.59, 0.28) * p("eye_size"), crystal)
	oval(focus, "DarkPupil", Vector3(0, 0, -0.14), Vector3(0.095, 0.33, 0.06) * p("eye_size"), dark)
	for side in [-1.0, 1.0]:
		var shutter := pivot(head, "EyeShutter", Vector3(side * 0.39, 0.02, -0.29))
		horn(shutter, "ShutterPlate", [Vector3(0, -0.27, 0), Vector3(-side * 0.13, 0.05, -0.13), Vector3(-side * 0.11, 0.38, 0.02)], [0.11, 0.16, 0.0], rock, 0.65)
		shutters.append(shutter)
		segment(head, "Mandible", Vector3(side * 0.30, -0.31, -0.18), Vector3(side * 0.22, -0.49, -0.55), 0.12, 0.015, rock)

func animate_creature(time: float, walk: float, charge: float, _breath: float) -> void:
	var release := release_at(time)
	# Keep the raised firing platform through discharge, then settle during recovery.
	var raised := maxf(charge, release)
	body.position.y += raised * p("aim_lift")
	body.position.z = raised * p("aim_setback") + release * p("recoil_distance")
	body.rotation.x = deg_to_rad(p("aim_pitch")) * raised
	body.rotation.z = sin(time * TAU * p("gait_rate")) * walk * 0.035
	head.rotation.y = sin(time * 0.7) * 0.12 * (1.0 - charge)
	head.position.y = p("body_height") + raised * p("eye_lift")
	head.rotation.x = -body.rotation.x + deg_to_rad(p("recoil_pitch")) * release
	for i in shutters.size():
		shutters[i].rotation.y = (-1.0 if i == 0 else 1.0) * raised * p("shutter_open")
	focus.scale = Vector3.ONE * (1.0 + charge * 0.10)
	crystal.emission_energy_multiplier = p("glow") * (1.0 + charge * 1.8 + release_at(time) * 2.0)

func leg_stance(leg: Dictionary, _time: float, charge: float, release: float) -> Array[Vector3]:
	var raised := maxf(charge, release)
	var hip: Vector3 = leg.hip
	var front := clampf((0.65 - hip.z) / 1.3, 0.0, 1.0)
	var spread := signf(hip.x) * p("brace_spread") * raised
	return [Vector3(spread * 0.5, raised * p("knee_lift") * lerpf(0.35, 1.0, front), 0), Vector3(spread, 0, -front * p("front_reach") * raised)]

func build_death_effects() -> void:
	dropped_eye = pivot(death_fx, "DroppedEye")
	oval(dropped_eye, "DetachedCrystalEye", Vector3.ZERO, Vector3(0.63, 0.59, 0.28) * p("eye_size"), crystal)
	oval(dropped_eye, "DetachedPupil", Vector3(0, 0, -0.14) * p("eye_size"), Vector3(0.095, 0.33, 0.06) * p("eye_size"), dark)

func reset_effect_parts() -> void:
	focus.visible = true
	focus.scale = Vector3.ONE
	head.position.y = p("body_height")
	head.rotation = Vector3.ZERO
	for shutter in shutters:
		shutter.rotation = Vector3.ZERO

func sample_death(time: float) -> void:
	death_fx.visible = true
	var drop_start := p("death_prepare") * 0.4
	var eye_t := clampf((time - drop_start) / p("death_eye_drop"), 0.0, 1.0)
	focus.visible = time < drop_start
	dropped_eye.visible = time >= drop_start
	var start := Vector3(0, p("body_height"), -1.10)
	var end := Vector3(p("death_eye_distance") * 0.35, p("eye_size") * 0.32, -1.10 - p("death_eye_distance"))
	dropped_eye.position = start.lerp(end, eye_t)
	dropped_eye.position.y += absf(sin(eye_t * TAU)) * (1.0 - eye_t) * p("death_eye_bounce")
	dropped_eye.rotation = Vector3(eye_t * TAU, 0, eye_t * PI * 0.4)
	var flip := smoothstep(p("death_prepare"), p("death_prepare") + p("death_action"), time)
	var struggle := sin(time * TAU * 2.0) * deg_to_rad(p("death_wobble")) * (1.0 - flip)
	roll_corpse(flip * PI + struggle)
	death_legs(time)
	crystal.emission_energy_multiplier = p("glow") * (1.0 - smoothstep(p("death_prepare"), p("death_prepare") + p("death_action"), time))
