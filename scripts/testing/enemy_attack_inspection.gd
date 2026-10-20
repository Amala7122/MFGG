extends RefCounted
## 观察适配：读取实际 spec／弹道公式，不维护另一套攻击数值。
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
const Projectile := preload("res://scripts/enemies/crystal_projectile.gd")

static func profile(actor: Node) -> String:
	return String(actor.call("profile_id")) if actor.has_method("profile_id") else String(actor.get_meta(&"lab_roster_id", actor.get_script().get_script_constant_map().get("PROFILE_ID", "")))

static func names(actor: Node) -> Array[String]:
	var result: Array[String] = []
	for skill: Array in Layout.SKILLS.get(profile(actor), []): result.append(skill[0])
	return result

static func sample(actor: Node3D, index: int) -> Dictionary:
	var id := profile(actor)
	var skills := names(actor)
	if index < 0 or index >= skills.size(): return {}
	var title := skills[index]
	var v: Dictionary = actor.get("_tuning")
	var size := actor.scale.x
	var pose := actor.global_transform.orthonormalized()
	var spec := {}
	var path := PackedVector3Array()
	var notes := "蓝色为无障碍理论范围；橙色为当前公布判定，最终命中仍检查高度、地形与遮挡。"
	var target := actor.get("target") as Node3D
	match id:
		"PrototypeMudGolem": spec = actor.call("_attack_spec")
		"PrototypeFastBeast":
			if index == 0:
				spec = actor.call("_pounce_spec")
				for step in 49:
					var at := float(spec.flight_time) * step / 48.0
					path.append(pose.origin - pose.basis.z * float(spec.travel_speed) * at + Vector3.UP * (float(spec.jump_speed) * at - float(spec.gravity) * at * at * 0.5))
			else: spec = _jump(actor.call("_normal_attack_spec"))
		"PrototypeSedimentTitan":
			match index:
				0: spec = actor.call("_slam_spec")
				1: spec = actor.call("_sweep_spec")
				2: spec = actor.call("_thrust_spec")
				3:
					spec = {"kind":"circle", "radius": float(v.leap_max_distance), "height":float(v.leap_max_elevation)}
					if actor.current_state == actor.State.LEAP_AIR:
						for step in 49:
							var t := step / 48.0
							path.append(actor._leap_origin.lerp(actor._leap_landing - Vector3.UP * actor.LEAP_LANDING_CONTACT_DEPTH, t) + Vector3.UP * (4.0 * actor._leap_arc_height * t * (1.0 - t)))
					notes = "蓝圈为跃击施放上限；落点橙圈是实际爆炸范围。起跳后蓝线读取已锁定落点与弧高。"
				4:
					spec = {"kind":"fan_rects", "length":float(v.triple_slam_length)*size, "width":float(v.triple_slam_width)*size, "spread":float(v.triple_slam_spread), "height":2.5*size}
				5: spec = _jump(actor.call("_normal_attack_spec"))
				6: notes = "护盾是增益技能，无对外伤害范围。专属参数控制减伤与破解。"
		"PrototypeHornet":
			var ranged := index == 0
			spec = {"kind":"sphere", "radius":float(v.needle_range if ranged else v.dive_range)}
			if is_instance_valid(target):
				var origin: Vector3 = actor.stingers[maxi(actor.remaining_needles - 1, 0)].global_position if ranged else actor.global_position
				var aim: Vector3 = target.global_position + Vector3.UP * float(v.needle_aim_height if ranged else v.dive_aim_height)
				var length := float(v.needle_range) if ranged else float(v.dive_speed)*float(v.dive_max_time)
				path = PackedVector3Array([origin, origin + (aim-origin).normalized()*length])
			notes = "蓝球为三维施放距离；晶针按中心线射线命中，俯冲按身体运动段与撕咬半径命中。"
		"VisualBurstCrawler":
			if is_instance_valid(target):
				var goal := Vector3(target.global_position.x, 0.04, target.global_position.z)
				var floor_hit := Projectile.FX.sample_ground(actor, target.global_position + Vector3.UP, 12.0)
				if not floor_hit.is_empty(): goal = floor_hit.position
				pose.origin = goal
				if index == 0:
					var origin: Vector3 = actor.visual.sacs[0].global_position
					path = Projectile.lob_points(origin, goal, v)
				spec = {"kind":"circle", "radius":float(v.blast_radius if index == 0 else v.poison_radius), "height":float(v.blast_height if index == 0 else v.poison_hit_height)}
				notes = "蓝圈为当前目标落点的爆炸／黏液范围；蓝线为同公式预计抛物线，绿色保留实际运动。"
		"VisualPrismSpider":
			spec = {"kind":"circle", "radius":float(v.attack_range), "height":0.0}
			if is_instance_valid(target):
				var origin: Vector3 = actor.visual.focus.global_position
				var aim: Vector3 = actor.aim_point if actor.current_state == actor.State.AIM else target.global_position
				path = PackedVector3Array([origin, origin + (aim-origin).normalized()*float(v.projectile_speed)*float(v.projectile_lifetime)])
			notes = "蓝圈为施放上限；蓝线为弹体寿命内理论航程，弹体实际按中心线射线碰撞。"
		"VisualChargeBeetle":
			pose = actor.call("_warning_pose")
			spec = actor.call("attack_debug_spec", index == 1)
			if index == 0: path = PackedVector3Array([actor.global_position, actor.global_position - pose.basis.z * minf(float(v.charge_distance), float(v.charge_speed)*float(v.charge_timeout))])
	return {"title":title, "spec":spec, "pose":pose, "path":path, "notes":notes}

static func _jump(spec: Dictionary) -> Dictionary:
	return {"kind":"circle", "radius":float(spec.reach), "height":float(spec.height)}

static func motion_points(actor: Node3D) -> Dictionary:
	# 采实际攻击部位的位置；原地出拳也必须有轨迹，不能只记录身体平移。
	match profile(actor):
		"PrototypeMudGolem": return {"right_fist":actor.right_arm_pivot.get_child(0).global_position}
		"PrototypeSedimentTitan": return {"right_fist":actor.right_forearm.get_node("MassiveFist").global_position, "sweep_tip":actor.left_arm_pivot.to_global(Vector3(0,-1.1,0))}
		"PrototypeFastBeast": return {"jaw":actor.jaw_pivot.global_position}
		"PrototypeHornet": return {"bite":actor.head_pivot.global_position}
		"VisualBurstCrawler": return {"sac":actor.visual.sacs[0].global_position}
		"VisualPrismSpider": return {"eye":actor.visual.focus.global_position}
		"VisualChargeBeetle":
			var horn := actor.visual.find_child("ShovelHorn",true,false) as Node3D
			return {"horn":horn.global_position} if horn else {}
	return {}

static func trigger(actor: Node3D, index: int) -> void:
	# 使用真实入口；不绕过合法性、冷却或地形检查。重播会重建固定条件实例。
	match profile(actor):
		"PrototypeMudGolem": actor.trigger_attack(actor.target.global_position)
		"PrototypeFastBeast":
			if index == 0: actor.trigger_pounce()
			else: actor.trigger_jump_attack()
		"PrototypeHornet":
			if index == 0: actor.trigger_fire()
			else: actor.trigger_swoop_dive()
		"PrototypeSedimentTitan":
			match index:
				0: actor.trigger_slam_attack()
				1: actor.trigger_sweep_attack()
				2: actor.trigger_thrust_attack()
				3: actor.trigger_leap_attack()
				4: actor.trigger_triple_slam_attack()
				5: actor.trigger_jump_attack()
				6: actor._activate_mud_shield()
		"VisualPrismSpider", "VisualChargeBeetle": actor.trigger_attack()
		"VisualBurstCrawler": actor._think(0.0)

