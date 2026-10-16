extends "res://scripts/prototypes/crystal_creature_visual.gd"
## 裂甲兜虫：蓄力后坐、压角、蹬地；冲锋仅做有限的展示位移。
var head: Node3D
var shell_halves: Array[Node3D] = []

func profile_id() -> String:
	return "VisualChargeBeetle"

func gait_amount(time: float, walk: float) -> float:
	return maxf(walk, release_at(time))

func build_creature() -> void:
	shell_halves.clear()
	var width := p("shell_width")
	var length := p("shell_length")
	oval(body, "Underbody", Vector3(0, 0.78, 0.30), Vector3(width * 0.87, 0.90, length * 0.91), dark)
	for side in [-1.0, 1.0]:
		var half := pivot(body, "Elytron", Vector3(side * 0.06, 1.08, 0.30))
		oval(half, "HeavyShell", Vector3(side * width * 0.23, 0, 0), Vector3(width * 0.53, p("shell_height"), length), rock)
		# One long armor ridge per wing case keeps the shell broad and uncluttered.
		horn(half, "ShellRidge", [Vector3(side * width * 0.28, 0.22, -length * 0.32), Vector3(side * width * 0.30, p("shell_height") * 0.49, 0.15), Vector3(side * width * 0.24, 0.05, length * 0.47)], [0.12, 0.16, 0.0], belly, 0.5)
		shell_halves.append(half)
		for i in 3:
			var z := -0.70 + i * 0.80
			limb("BeetleLeg", Vector3(side * width * 0.32, 0.84, z), Vector3(side * width * 0.58, 0.50, z + 0.28), Vector3(side * width * 0.68, 0.09, z - 0.20), p("leg_thickness"), PI * (i % 2 + (1 if side > 0 else 0)))
		horn(body, "CrystalSeam", [Vector3(side * 0.04, 1.55, -0.25), Vector3(side * 0.045, 1.65, 0.40), Vector3(side * 0.04, 1.39, 1.15)], [0.035, 0.045, 0.0], crystal)
	head = pivot(body, "HeadPivot", Vector3(0, 0.94, -length * 0.45))
	oval(head, "NeckShield", Vector3(0, 0.20, 0), Vector3(width * 0.86, 0.88, 1.02), rock)
	oval(head, "WedgeHead", Vector3(0, -0.16, -0.42), Vector3(1.18, 0.64, 0.88), belly)
	for side in [-1.0, 1.0]:
		oval(head, "EyeSocket", Vector3(side * 0.40, -0.04, -0.73), Vector3(0.33, 0.23, 0.15), dark)
		oval(head, "CrystalEye", Vector3(side * 0.40, -0.04, -0.79), Vector3(0.22, 0.10, 0.08), crystal)
		segment(head, "JawTusk", Vector3(side * 0.35, -0.35, -0.56), Vector3(side * 0.21, -0.25, -1.04), 0.13, 0.015, rock)
	var reach := p("horn_length")
	horn(head, "ShovelHorn", [Vector3(0, 0.02, -0.42), Vector3(0, 0.06, -0.85), Vector3(0, 0.22, -0.80 - reach * 0.64), Vector3(0, 0.65, -0.80 - reach)], [p("horn_width"), p("horn_width") * 0.77, p("horn_width") * 0.45, 0.0], rock, 0.60)
	horn(head, "HornRootCrystal", [Vector3(0, 0.24, -0.56), Vector3(0, 0.24, -0.95), Vector3(0, 0.36, -1.22)], [0.08, 0.07, 0.0], crystal)

func animate_creature(time: float, walk: float, charge: float, _breath: float) -> void:
	var release := release_at(time)
	body.position.y += charge * p("rear_lift") - release * p("crouch")
	body.position.z = charge * p("charge_setback")
	body.rotation.x = -deg_to_rad(p("charge_pitch")) * charge
	rig.position.z = -release * p("dash_distance") * p("body_size")
	body.rotation.z = sin(time * TAU * p("gait_rate")) * walk * 0.028
	head.rotation.x = -charge * p("head_lower")
	for i in shell_halves.size():
		shell_halves[i].rotation.z = (-1.0 if i == 0 else 1.0) * charge * deg_to_rad(p("shell_flare"))
	crystal.emission_energy_multiplier = p("glow") * (1.0 + charge * 1.1)

func leg_stance(leg: Dictionary, time: float, charge: float, _release: float) -> Array[Vector3]:
	var hip: Vector3 = leg.hip
	var side := signf(hip.x)
	var front := hip.z < 0.0
	var scrape := sin(time * TAU * p("scrape_rate") + float(leg.phase)) * charge if preview_pose == 2 else 0.0
	var foot := Vector3(side * p("brace_spread") * charge, maxf(0, scrape) * p("foot_lift") if front else 0.0, scrape * p("scrape_distance") if front else charge * p("hind_pushback"))
	return [Vector3(side * p("brace_spread") * charge, charge * p("rear_lift") * (0.3 if front else 1.0), charge * p("charge_setback") * 0.5), foot]

func reset_effect_parts() -> void:
	head.rotation = Vector3.ZERO
	for half in shell_halves:
		half.rotation = Vector3.ZERO

func sample_death(time: float) -> void:
	var flip := smoothstep(p("death_prepare"), p("death_prepare") + p("death_action"), time)
	var wobble := sin(time * TAU * p("death_struggle_rate")) * deg_to_rad(p("death_wobble")) * (1.0 - flip)
	roll_corpse(flip * PI + wobble)
	head.rotation.x = -0.12 * (1.0 - flip)
	death_legs(time)
	crystal.emission_energy_multiplier = p("glow") * (1.0 - flip)
