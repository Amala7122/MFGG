extends Node3D
## Shared visual rig only: no AI, hitboxes or damage. Facing -Z, feet at Y=0.
const Tuning = preload("res://scripts/prototypes/enemy_tuning.gd")
var ai_enabled := false
var preview_pose := 0
var preview_time := 0.0
## 观察台用：0 冻结、1 原速、小于 1 为慢放。默认原速，不影响既有行为。
var preview_speed := 1.0
var values: Dictionary
var rig: Node3D
var body: Node3D
var legs: Array[Dictionary] = []
var rock: StandardMaterial3D
var belly: StandardMaterial3D
var crystal: StandardMaterial3D
var dark: StandardMaterial3D
signal death_started
signal death_finished
var death_fx: Node3D
var model_bounds: AABB
var _runtime_death := false
var _death_completed := false
var _limb_pending := false
var _limb_time := 0.0
var _limb_walk := 0.0

func profile_id() -> String:
	return ""

func _ready() -> void:
	values = Tuning.resolve(self, profile_id())
	rebuild()

func p(key: String) -> float:
	return float(values[key])

func apply_visual_values(next: Dictionary) -> void:
	if not Tuning.validate(profile_id(), next).is_empty():
		return
	values = next.duplicate(true)
	rebuild()

func rebuild() -> void:
	if is_instance_valid(rig):
		rig.free()
	if is_instance_valid(death_fx):
		death_fx.free()
	legs.clear()
	rock = material(Color(p("rock_r"), p("rock_g"), p("rock_b")))
	belly = material(Color(0.30, 0.35, 0.27))
	dark = material(Color(0.065, 0.083, 0.088))
	crystal = material(Color(p("crystal_r"), p("crystal_g"), p("crystal_b")), p("glow"))
	rig = pivot(self, "VisualRig")
	rig.scale = Vector3.ONE * p("body_size")
	body = pivot(rig, "Body")
	build_creature()
	model_bounds = AABB()
	var first := true
	for part in rig.find_children("*", "MeshInstance3D", true, false):
		var bounds: AABB = (rig.global_transform.affine_inverse() * part.global_transform) * part.get_aabb()
		model_bounds = bounds if first else model_bounds.merge(bounds)
		first = false
	death_fx = pivot(self, "DeathEffects")
	death_fx.scale = Vector3.ONE * p("body_size")
	build_death_effects()
	sample_pose(preview_time)

func build_death_effects() -> void:
	pass

func build_creature() -> void:
	pass

func _process(delta: float) -> void:
	preview_time += delta * preview_speed
	if not is_preview_looping():
		preview_time = minf(preview_time, get_preview_duration())
	sample_pose(preview_time)
	if _runtime_death and not _death_completed and preview_time >= get_preview_duration():
		_death_completed = true
		remove_from_group("enemy_death_effect")
		death_finished.emit()

func set_preview_pose(value: int) -> void:
	preview_pose = posmod(value, get_preview_pose_names().size())
	preview_time = 0.0
	sample_pose(0.0)

func get_preview_pose_name() -> String:
	return get_preview_pose_names()[preview_pose]

func get_preview_pose_names() -> Array[String]:
	return ["待机", "原地步态", "技能循环（仅动作）", "蓄力定格", "死亡（单次，停在尸体）"]

func death_pose_index() -> int:
	return get_preview_pose_names().size() - 1

func is_preview_looping() -> bool:
	return preview_pose != death_pose_index()

func get_preview_duration() -> float:
	if preview_pose == death_pose_index():
		return p("death_prepare") + p("death_action") + p("death_twitch_time") + p("death_hold")
	if preview_pose == 0:
		return 1.0 / p("breath_rate")
	if preview_pose == 1:
		return 1.0 / p("gait_rate")
	return p("windup") + p("release") + p("recovery")

func get_preview_bands() -> Array:
	if preview_pose != death_pose_index():
		return []
	var prepare := p("death_prepare")
	var action := prepare + p("death_action")
	var twitch := action + p("death_twitch_time")
	return [
		{"from": 0.0, "to": prepare, "label": "死亡预备", "color": Color(0.5, 0.32, 0.12, 0.9)},
		{"from": prepare, "to": action, "label": "爆裂 / 翻身", "color": Color(0.8, 0.18, 0.12, 0.9), "decisive": true},
		{"from": action, "to": twitch, "label": "抖腿衰减", "color": Color(0.4, 0.28, 0.55, 0.9)},
		{"from": twitch, "to": get_preview_duration(), "label": "尸体定格", "color": Color(0.2, 0.3, 0.4, 0.9)}]

func play_death() -> float:
	if not _runtime_death:
		_runtime_death = true
		_death_completed = false
		add_to_group("enemy_death_effect")
		set_preview_pose(death_pose_index())
		death_started.emit()
	return get_preview_duration()

func reset_death_preview() -> void:
	_runtime_death = false
	_death_completed = false
	remove_from_group("enemy_death_effect")
	set_preview_pose(0)

func sample_pose(time: float) -> void:
	_sample_pose(time, false)

## 战斗宿主：身体、囊体、眼睛与角仍逐物理步更新；纯装饰腿只提交最终显示姿态。
## 公开观察／逐帧接口sample_pose始终即时更新全部节点。
func sample_combat_pose(time: float) -> void:
	_sample_pose(time, true)

func _sample_pose(time: float, defer_limbs: bool) -> void:
	_limb_pending = false
	if not is_instance_valid(body):
		return
	body.position = Vector3.ZERO
	body.rotation = Vector3.ZERO
	body.scale = Vector3.ONE
	rig.position = Vector3.ZERO
	rig.rotation = Vector3.ZERO
	death_fx.visible = false
	reset_effect_parts()
	if preview_pose == death_pose_index():
		sample_death(maxf(0.0, time))
		return
	var breath := sin(time * TAU * p("breath_rate")) * p("breath_amount")
	body.position.y = breath
	var walk := 1.0 if preview_pose == 1 else 0.0
	animate_creature(time, walk, charge_at(time), breath)
	walk = gait_amount(time, walk)
	if defer_limbs:
		_limb_pending = true
		_limb_time = time
		_limb_walk = walk
	else:
		_sample_limbs(time, walk)

func flush_limb_pose() -> void:
	if not _limb_pending or not is_instance_valid(body): return
	_limb_pending = false
	_sample_limbs(_limb_time, _limb_walk)

func _sample_limbs(time: float, walk: float) -> void:
	# 同一次姿态采样的曲线／身体变换对所有腿相同；保留原采样时间和计算顺序。
	var gait_phase := time * TAU * p("gait_rate")
	var stride := p("stride")
	var lift := p("foot_lift")
	var charge := charge_at(time)
	var release := release_at(time)
	var torso := body.transform
	for leg in legs:
		var node: Node3D = leg.node
		var phase := gait_phase + float(leg.phase)
		# Hip follows the acting torso; planted feet remain in rig space.
		# This lets a rearing pose really straighten its support legs.
		var hip: Vector3 = torso * (leg.hip as Vector3)
		var knee: Vector3 = (leg.hip as Vector3) + (leg.knee as Vector3)
		var foot: Vector3 = (leg.hip as Vector3) + (leg.foot as Vector3)
		var stance := leg_stance(leg, time, charge, release)
		knee += stance[0]
		foot += stance[1]
		var swing := cos(phase)
		var raised := maxf(0.0, sin(phase))
		foot.z += walk * swing * stride
		foot.y += walk * raised * lift
		knee.z += walk * swing * stride * 0.4
		knee.y += walk * raised * lift * 0.5
		node.rotation = Vector3.ZERO
		node.position = hip
		place_segment(leg.upper, Vector3.ZERO, knee - hip)
		place_segment(leg.shin, knee - hip, foot - hip)
		(leg.joint as Node3D).position = knee - hip

func reset_effect_parts() -> void:
	pass

func sample_death(_time: float) -> void:
	pass

## Roll the entire body and legs together. Reposition from model bounds to clear the floor.
func roll_corpse(angle: float) -> void:
	rig.rotation.z = angle
	var minimum := INF
	for corner in 8:
		minimum = minf(minimum, (rig.basis * model_bounds.get_endpoint(corner)).y)
	rig.position.y = -minimum

func death_legs(time: float) -> void:
	var fold := smoothstep(0.0, p("death_prepare") + p("death_action"), time) * p("death_leg_fold")
	var end := p("death_prepare") + p("death_action") + p("death_twitch_time")
	var envelope := (1.0 - smoothstep(p("death_prepare"), end, time)) if time < end else 0.0
	for leg in legs:
		var hip: Vector3 = leg.hip
		var knee: Vector3 = leg.knee
		var foot: Vector3 = leg.foot
		var side := signf(hip.x)
		knee = knee.lerp(Vector3(side * 0.27, -0.20, knee.z * 0.4), fold)
		foot = foot.lerp(Vector3(side * 0.38, -0.55, foot.z * 0.25), fold)
		var jitter := sin(time * TAU * p("death_twitch_rate") + float(leg.phase) + hip.z) * p("death_leg_twitch") * envelope
		knee.z += jitter * 0.6
		foot.z += jitter
		foot.x += jitter * side * 0.5
		(leg.node as Node3D).position = hip
		(leg.node as Node3D).rotation = Vector3.ZERO
		place_segment(leg.upper, Vector3.ZERO, knee)
		place_segment(leg.shin, knee, foot)
		(leg.joint as Node3D).position = knee

func leg_stance(_leg: Dictionary, _time: float, _charge: float, _release: float) -> Array[Vector3]:
	return [Vector3.ZERO, Vector3.ZERO]

func gait_amount(_time: float, walk: float) -> float:
	return walk

func place_segment(part: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	part.position = (a + b) * 0.5
	part.quaternion = Quaternion(Vector3.UP, (b - a).normalized())
	part.scale.y = a.distance_to(b) / (part.mesh as CylinderMesh).height

## 技能循环是否整体倒放。默认关：只有用户明确要求的角色打开（目前是爆囊爬兽）。
var skill_reversed := false

## 倒放时钟：把实际播放时间映射到原曲线的时间。
func skill_clock(time: float) -> float:
	var cycle := p("windup") + p("release") + p("recovery")
	var t := fposmod(time, cycle)
	return fposmod(cycle - t, cycle) if skill_reversed else t

## 转身进度：倒放后的预备段转到 1（屁股朝向玩家），投囊与定势保持，收甲段转回 0。
func turn_at(time: float) -> float:
	if preview_pose == 3:
		return 1.0
	if preview_pose != 2:
		return 0.0
	var cycle := p("windup") + p("release") + p("recovery")
	var t := fposmod(time, cycle)
	var strike_start := cycle - p("windup") - p("release") * p("release_snap_ratio")
	var hold_end := cycle - p("windup") + p("windup") * (1.0 - p("windup_rise_ratio"))
	if t < strike_start:
		return smoothstep(0.0, strike_start, t)
	if t < hold_end:
		return 1.0
	return 1.0 - smoothstep(hold_end, cycle, t)


func charge_at(time: float) -> float:
	if preview_pose == 3:
		return 1.0
	if preview_pose != 2:
		return 0.0
	var t := skill_clock(time)
	if t < p("windup"):
		return smoothstep(0.0, p("windup") * p("windup_rise_ratio"), t)
	return 1.0 - smoothstep(p("windup"), p("windup") + p("release") * p("release_snap_ratio"), t)

func release_at(time: float) -> float:
	if preview_pose != 2:
		return 0.0
	var t := skill_clock(time) - p("windup")
	if t < 0.0:
		return 0.0
	var peak := p("release") * p("release_snap_ratio")
	if t < peak:
		return smoothstep(0.0, peak, t)
	return 1.0 - smoothstep(peak, p("release") + p("recovery"), t)

func animate_creature(_time: float, _walk: float, _charge: float, _breath: float) -> void:
	pass

func material(color: Color, glow := 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.82 if glow == 0 else 0.32
	mat.emission_enabled = glow > 0
	mat.emission = color
	mat.emission_energy_multiplier = glow
	return mat

func pivot(parent: Node3D, title: String, at := Vector3.ZERO) -> Node3D:
	var node := Node3D.new()
	node.name = title
	parent.add_child(node)
	node.position = at
	return node

func mesh_part(parent: Node3D, title: String, mesh: Mesh, at: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = title
	node.mesh = mesh
	node.material_override = mat
	parent.add_child(node)
	node.position = at
	return node

func oval(parent: Node3D, title: String, at: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 10
	sphere.rings = 4
	var part := mesh_part(parent, title, sphere, at, mat)
	part.scale = size
	return part

func segment(parent: Node3D, title: String, a: Vector3, b: Vector3, radius: float, tip: float, mat: Material) -> MeshInstance3D:
	var cylinder := CylinderMesh.new()
	cylinder.radial_segments = 6
	cylinder.rings = 1
	cylinder.bottom_radius = radius
	cylinder.top_radius = tip
	cylinder.height = a.distance_to(b)
	var part := mesh_part(parent, title, cylinder, (a + b) * 0.5, mat)
	part.quaternion = Quaternion(Vector3.UP, (b - a).normalized())
	return part

func limb(title: String, hip: Vector3, knee: Vector3, foot: Vector3, thickness: float, phase: float) -> void:
	var joint := pivot(rig, title, hip)
	var upper := segment(joint, "Upper", Vector3.ZERO, knee - hip, thickness, thickness * 0.75, rock)
	var knee_mesh := oval(joint, "Knee", knee - hip, Vector3.ONE * thickness * 1.9, rock)
	var shin := segment(joint, "Shin", knee - hip, foot - hip, thickness * 0.72, thickness * 0.22, rock)
	legs.append({"node": joint, "phase": phase, "hip": hip, "knee": knee - hip, "foot": foot - hip, "upper": upper, "shin": shin, "joint": knee_mesh})

## Faceted swept hexagonal section; useful for armor ridges and curved horns.
func horn(parent: Node3D, title: String, points: Array[Vector3], radii: Array[float], mat: Material, flatten := 1.0) -> MeshInstance3D:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array[PackedVector3Array] = []
	for i in points.size():
		var direction := points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]
		var axis := direction.normalized()
		var side := axis.cross(Vector3.RIGHT).normalized()
		if side.length_squared() < 0.01:
			side = axis.cross(Vector3.UP).normalized()
		var across := side.cross(axis).normalized()
		var ring := PackedVector3Array()
		for j in 6:
			var angle := TAU * j / 6.0
			ring.append(points[i] + radii[i] * (across * cos(angle) + side * sin(angle) * flatten))
		rings.append(ring)
	for i in range(rings.size() - 1):
		for j in 6:
			var k := (j + 1) % 6
			triangle(surface, rings[i][j], rings[i + 1][j], rings[i][k])
			if radii[i + 1] > 0:
				triangle(surface, rings[i][k], rings[i + 1][j], rings[i + 1][k])
	for j in 6:
		triangle(surface, points[0], rings[0][(j + 1) % 6], rings[0][j])
	return mesh_part(parent, title, surface.commit(), Vector3.ZERO, mat)

func triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (c - a).cross(b - a).normalized()
	for vertex in [a, b, c]:
		surface.set_normal(normal)
		surface.add_vertex(vertex)
