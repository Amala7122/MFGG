extends RefCounted
## 修改前HEAD采样器，仅供逐节点姿态对照，非正式实现。
static func sample(visual: Node3D, time: float) -> void:
	if not is_instance_valid(visual.body):
		return
	visual.body.position = Vector3.ZERO
	visual.body.rotation = Vector3.ZERO
	visual.body.scale = Vector3.ONE
	visual.rig.position = Vector3.ZERO
	visual.rig.rotation = Vector3.ZERO
	visual.death_fx.visible = false
	visual.reset_effect_parts()
	if visual.preview_pose == visual.death_pose_index():
		visual.sample_death(maxf(0.0, time))
		return
	var breath: float = sin(time * TAU * visual.p("breath_rate")) * visual.p("breath_amount")
	visual.body.position.y = breath
	var walk := 1.0 if visual.preview_pose == 1 else 0.0
	visual.animate_creature(time, walk, visual.charge_at(time), breath)
	walk = visual.gait_amount(time, walk)
	for leg in visual.legs:
		var node: Node3D = leg.node
		var phase: float = time * TAU * visual.p("gait_rate") + float(leg.phase)
		# Hip follows the acting torso; planted feet remain in visual.rig space.
		# This lets a rearing pose really straighten its support visual.legs.
		var hip: Vector3 = visual.body.transform * (leg.hip as Vector3)
		var knee: Vector3 = (leg.hip as Vector3) + (leg.knee as Vector3)
		var foot: Vector3 = (leg.hip as Vector3) + (leg.foot as Vector3)
		var stance: Array = visual.leg_stance(leg, time, visual.charge_at(time), visual.release_at(time))
		knee += stance[0]
		foot += stance[1]
		foot.z += walk * cos(phase) * visual.p("stride")
		foot.y += walk * maxf(0.0, sin(phase)) * visual.p("foot_lift")
		knee.z += walk * cos(phase) * visual.p("stride") * 0.4
		knee.y += walk * maxf(0.0, sin(phase)) * visual.p("foot_lift") * 0.5
		node.rotation = Vector3.ZERO
		node.position = hip
		visual.place_segment(leg.upper, Vector3.ZERO, knee - hip)
		visual.place_segment(leg.shin, knee - hip, foot - hip)
		(leg.joint as Node3D).position = knee - hip
