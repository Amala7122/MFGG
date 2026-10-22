extends "res://scripts/prototypes/crystal_creature_visual.gd"
## 爆囊爬兽：腹部、背囊与短肢构成低矮剪影。
var sacs: Array[Node3D] = []
var sac_organs: Array[Node3D] = []
var jaw: Node3D
var back_armor: Node3D
var flank_armor: Array[Node3D] = []
const Behavior = preload("res://scripts/prototypes/crawler_behavior.gd")
var behavior := Behavior.new()
var combat_target: Node3D
var behavior_demo := false
var preview_player_distance := 16.0
signal movement_requested(velocity: Vector3)
signal throw_requested(origin: Vector3, direction: Vector3)
var poison_pool: Node3D
var splash: Array[Node3D] = []
var burst_flash: Node3D
var _retreat_start_charge := 1.0

func profile_id() -> String:
	return "VisualBurstCrawler"


## 用户要求：这个怪的技能循环整体倒放——现在的动作倒过来播放，顺序才对。
func _ready() -> void:
	skill_reversed = true
	super()

func get_preview_pose_names() -> Array[String]:
	return ["待机", "原地步态", "转身投囊循环", "蓄力定格", "近身收甲撤退", "死亡自爆（单次）"]

func set_preview_pose(value: int) -> void:
	if posmod(value, get_preview_pose_names().size()) == 4:
		_retreat_start_charge = 1.0
	super(value)

func get_preview_duration() -> float:
	if preview_pose == 4:
		return p("retreat_close_time") + p("retreat_preview_time")
	if preview_pose == 2 or preview_pose == 3:
		return p("turn_duration") + p("release") + p("recovery") + p("windup")
	return super()

func get_preview_bands() -> Array:
	if preview_pose == 4:
		return [{"from": 0.0, "to": p("retreat_close_time"), "label": "紧急收甲", "color": Color(0.8, 0.3, 0.2, 0.9)}, {"from": p("retreat_close_time"), "to": get_preview_duration(), "label": "直接撤离", "color": Color(0.25, 0.5, 0.7, 0.9)}]
	if preview_pose != 2:
		return super()
	var end_throw := p("turn_duration") + p("release") * p("release_snap_ratio")
	var end_hold := p("turn_duration") + p("release") + p("recovery")
	return [{"from": 0.0, "to": p("turn_duration"), "label": "转身预备", "color": Color(0.38, 0.30, 0.52, 0.85)}, {"from": p("turn_duration"), "to": end_throw, "label": "弹甲投囊", "color": Color(0.86, 0.28, 0.16, 0.95), "decisive": true}, {"from": end_throw, "to": end_hold, "label": "定势", "color": Color(0.24, 0.52, 0.34, 0.85)}, {"from": end_hold, "to": get_preview_duration(), "label": "收甲回位", "color": Color(0.20, 0.42, 0.72, 0.85)}]

func skill_clock(time: float) -> float:
	# Preserve the user's reversed throw curves, but complete the turn first.
	var duration := p("windup") + p("release") + p("recovery")
	var t := fposmod(time, get_preview_duration()) - p("turn_duration")
	if t < 0.0:
		return 0.0
	var old_start := p("recovery") + p("release") * (1.0 - p("release_snap_ratio"))
	return clampf(duration - old_start - t, 0.0, duration)

func turn_at(time: float) -> float:
	if preview_pose == 3:
		return 1.0
	if preview_pose != 2:
		return 0.0
	var t := fposmod(time, get_preview_duration())
	var end_hold := p("turn_duration") + p("release") + p("recovery")
	return smoothstep(0.0, p("turn_duration"), t) if t < end_hold else 1.0 - smoothstep(end_hold, get_preview_duration(), t)

func charge_at(time: float) -> float:
	if preview_pose == 4:
		return _retreat_start_charge * (1.0 - smoothstep(0.0, p("retreat_close_time"), clampf(time, 0.0, get_preview_duration())))
	if preview_pose == 2 and fposmod(time, get_preview_duration()) < p("turn_duration"):
		return 0.0
	return super(time)

func release_at(time: float) -> float:
	if preview_pose == 2 and fposmod(time, get_preview_duration()) < p("turn_duration"):
		return 0.0
	return super(time)

func _process(delta: float) -> void:
	if _runtime_death or not (behavior_demo or (ai_enabled and is_instance_valid(combat_target))):
		super(delta)
		return
	var offset := Vector3(0, 0, -preview_player_distance) if behavior_demo else global_basis.orthonormalized().inverse() * (combat_target.global_position - global_position)
	var result := update_combat(delta * preview_speed, offset)
	movement_requested.emit(result.velocity)
	if bool(result.throw):
		throw_requested.emit(sacs[0].global_position, (global_basis.orthonormalized() * offset).normalized())

func update_combat(delta: float, target_offset: Vector3, line_clear := true, defer_idle_pose := false) -> Dictionary:
	var previous := behavior.state
	var opening := back_armor.rotation.x / maxf(0.001, deg_to_rad(p("back_raise")))
	var result := behavior.update(delta, target_offset, values, line_clear)
	if _runtime_death:
		return result
	if result.state == Behavior.State.RETREAT:
		if previous != Behavior.State.RETREAT:
			_retreat_start_charge = clampf(opening, 0.0, 1.0)
		preview_pose = 4
		preview_time = minf(float(result.retreat_time), get_preview_duration())
	elif result.state == Behavior.State.IDLE:
		preview_pose = 0
		preview_time += delta
	else:
		preview_pose = 2
		preview_time = float(result.action_time)
	# 正式宿主随后会按实际移动采样步态；IDLE在同一物理步重复采样不可见。
	# 投掷／撤退仍立即采样，投射物继续读取当前姿态的真实囊体位置。
	if not defer_idle_pose: sample_pose(preview_time)
	elif result.state != Behavior.State.IDLE: sample_combat_pose(preview_time)
	rig.rotation.y = float(result.yaw)
	return result

func set_behavior_demo(enabled: bool, distance: float) -> void:
	behavior_demo = enabled
	preview_player_distance = distance
	if enabled:
		behavior.reset()
	else:
		set_preview_pose(0)

func set_combat_target(target: Node3D) -> void:
	combat_target = target
	ai_enabled = is_instance_valid(target)
	behavior.reset()

func play_death() -> float:
	behavior.kill()
	behavior_demo = false
	movement_requested.emit(Vector3.ZERO)
	return super()

func reset_death_preview() -> void:
	behavior.reset()
	super()

func build_creature() -> void:
	sacs.clear()
	sac_organs.clear()
	flank_armor.clear()
	var width := p("body_width")
	var length := p("body_length")
	oval(body, "SoftAbdomen", Vector3(0, 0.62, 0.28), Vector3(width, p("belly_height"), length), belly)
	back_armor = pivot(body, "BackArmorHinge", Vector3(0, 0.88, length * 0.48))
	oval(back_armor, "BackCarapace", Vector3(0, 0, -length * 0.37), Vector3(width * 0.90, 0.42, length * 0.86), rock)
	var head := pivot(body, "Head", Vector3(0, 0.66, -length * 0.49))
	oval(head, "Skull", Vector3.ZERO, Vector3(0.98, 0.60, 0.83), rock)
	oval(head, "MouthCavity", Vector3(0, -0.12, -0.36), Vector3(0.64, 0.30, 0.24), dark)
	jaw = pivot(head, "Jaw", Vector3(0, -0.24, -0.15))
	oval(jaw, "LowerJaw", Vector3(0, 0, -0.22), Vector3(0.68, 0.16, 0.46), rock)
	for side in [-1.0, 1.0]:
		oval(head, "EyeSocket", Vector3(side * 0.32, 0.10, -0.30), Vector3(0.27, 0.23, 0.16), dark)
		oval(head, "CrystalEye", Vector3(side * 0.32, 0.10, -0.37), Vector3(0.16, 0.12, 0.08), crystal)
		segment(head, "Fang", Vector3(side * 0.23, -0.06, -0.43), Vector3(side * 0.18, -0.23, -0.46), 0.065, 0, rock)
		for i in 2:
			var z := -0.66 if i == 0 else 0.88
			limb("ShortLeg", Vector3(side * width * 0.32, 0.63, z), Vector3(side * width * 0.60, 0.43, z + 0.18), Vector3(side * width * 0.68, 0.10, z - 0.16), 0.18, PI * (i + (1 if side > 0 else 0)))
	# Three large organs rather than dozens of transparent bubbles.
	var sac_mat := material(Color(0.35, 0.72, 0.30), p("glow") * 0.45)
	for i in 3:
		var x := [-0.40, 0.40, 0.0][i] as float
		var z := float([0.02, 0.32, 0.72][i]) * length / 2.25
		# The socket belongs to its carrier plate, never to the moving torso.
		var root := pivot(back_armor, "CrystalSac", Vector3(x * width / 1.65, 0.22, z - back_armor.position.z))
		oval(root, "RootCollar", Vector3.ZERO, Vector3(0.80, 0.30, 0.82) * p("sac_size"), dark)
		# Inflate outward from the attachment point, keeping the collar fixed.
		var organ := pivot(root, "SacOrgan", Vector3(0, 0.10, 0))
		oval(organ, "LuminousSac", Vector3(0, 0.45, 0) * p("sac_size"), Vector3(0.80, 0.90, 0.80) * p("sac_size"), sac_mat)
		horn(organ, "SacCrystal", [Vector3(0, 0.65, 0.12) * p("sac_size"), Vector3(0, 1.01, 0.22) * p("sac_size"), Vector3(0, 1.21, 0.28) * p("sac_size")], [0.14, 0.11, 0.0], crystal)
		sacs.append(root)
		sac_organs.append(organ)
	for side in [-1.0, 1.0]:
		for i in 3:
			var z := -0.15 + i * 0.55
			# Side armor is a fixed rim of the same carrier, not a separate flap.
			var plate := pivot(back_armor, "FlankRim", Vector3(side * width * 0.39, 0.75, z) - back_armor.position)
			horn(plate, "FlankPlate", [Vector3.ZERO, Vector3(side * width * 0.18, 0.17, 0.15), Vector3(side * width * 0.20, 0.12, 0.37)], [0.20, 0.16, 0.0], rock, 0.55)
			flank_armor.append(plate)

func animate_creature(time: float, walk: float, charge: float, breath: float) -> void:
	var release := release_at(time)
	body.position.y += -charge * p("charge_crouch") + release * p("throw_lift")
	body.position.z = charge * p("charge_setback") - release * p("throw_push")
	body.rotation.x = deg_to_rad(p("throw_pitch")) * release
	body.scale = Vector3(1.0 + charge * 0.08, 1.0 - charge * 0.10, 1.0)
	body.rotation.z = sin(time * TAU * p("gait_rate")) * 0.045 * walk
	back_armor.rotation.x = deg_to_rad(p("back_raise")) * charge
	jaw.rotation.x = -0.15 - charge * 0.35 - release * 0.3
	for i in sacs.size():
		var expansion := 1.0 + charge * p("sac_inflate") - release * p("sac_deflate") + breath * 0.5
		sac_organs[i].scale = Vector3(expansion, expansion + charge * p("sac_lift") / (0.9 * p("sac_size")), expansion)
	rig.rotation.y = deg_to_rad(p("turn_yaw")) * turn_at(time)
	if preview_pose == 4:
		rig.rotation.y = PI
		rig.position.z = smoothstep(0.0, get_preview_duration(), time) * p("retreat_preview_distance") * p("body_size")
	crystal.emission_energy_multiplier = p("glow") * (1.0 + charge)

func leg_stance(leg: Dictionary, _time: float, charge: float, release: float) -> Array[Vector3]:
	var side := signf((leg.hip as Vector3).x)
	return [Vector3(side * p("brace_spread") * charge, -charge * p("charge_crouch") * 0.5 + release * p("throw_lift") * 0.5, 0), Vector3(side * p("brace_spread") * charge, 0, 0)]

func gait_amount(_time: float, walk: float) -> float:
	return 1.0 if preview_pose == 4 else walk

func build_death_effects() -> void:
	splash.clear()
	var poison := material(Color(p("death_poison_r"), p("death_poison_g"), p("death_poison_b")))
	poison_pool = pivot(death_fx, "PoisonPool", Vector3(0, 0.018, 0.3))
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 12:
		var a := TAU * i / 12.0
		var b := TAU * (i + 1) / 12.0
		var radius_a := p("death_splash_radius") * (0.84 + 0.12 * sin(i * 2.7))
		var radius_b := p("death_splash_radius") * (0.84 + 0.12 * sin((i + 1) * 2.7))
		triangle(surface, Vector3.ZERO, Vector3(cos(a) * radius_a, 0, sin(a) * radius_a), Vector3(cos(b) * radius_b, 0, sin(b) * radius_b))
	mesh_part(poison_pool, "PoisonFilm", surface.commit(), Vector3.ZERO, poison)
	for i in 8:
		var droplet := oval(death_fx, "PoisonDroplet", Vector3.ZERO, Vector3(0.12, 0.24, 0.12), poison)
		splash.append(droplet)
	burst_flash = oval(death_fx, "BurstFlash", Vector3(0, 1.1, 0.3), Vector3.ONE, material(Color(0.6, 1.0, 0.16), 2.0))

func reset_effect_parts() -> void:
	for organ in sac_organs:
		organ.visible = true
		organ.scale = Vector3.ONE

func sample_death(time: float) -> void:
	death_fx.visible = true
	var rupture := smoothstep(p("death_prepare"), p("death_prepare") + p("death_action"), time)
	var swell := smoothstep(0, p("death_prepare"), time)
	back_armor.rotation.x = deg_to_rad(p("back_raise")) * swell * (1.0 - rupture)
	jaw.rotation.x = -0.5 * swell
	for organ in sac_organs:
		organ.scale = Vector3.ONE * lerpf(1.0, p("death_sac_swell"), swell)
		organ.visible = time < p("death_prepare")
	var after := maxf(0.0, time - p("death_prepare"))
	var spread := smoothstep(0.0, p("death_splash_time"), after)
	poison_pool.visible = after > 0.0
	poison_pool.scale = Vector3.ONE * maxf(0.001, spread)
	burst_flash.visible = after > 0.0 and after < p("death_action") * 0.3
	burst_flash.scale = Vector3.ONE * (0.1 + rupture * 3.0)
	for i in splash.size():
		var t := clampf(after / p("death_splash_time"), 0.0, 1.0)
		var angle := TAU * i / splash.size()
		splash[i].position = Vector3(cos(angle) * p("death_splash_radius") * t, (1.0 - t) * 1.1 + sin(t * PI) * p("death_splash_height"), 0.3 + sin(angle) * p("death_splash_radius") * t)
		splash[i].visible = after > 0.0 and t < 1.0
	body.scale = Vector3(1.0, 1.0 - rupture * 0.3, 1.0)
	crystal.emission_energy_multiplier = p("glow") * (1.0 - rupture)
	death_legs(time)
