extends RefCounted
## 各实现的语义只在这里适配。公共可见采样与隐藏诊断分开，未知实现不猜状态。
const Health := preload("res://scripts/health_util.gd")
static var _properties: Dictionary = {}

static func value(actor: Object, key: String, fallback: Variant = null) -> Variant:
	var script: Script = actor.get_script()
	var identity: Variant = script.get_instance_id() if script != null else actor.get_class()
	if not _properties.has(identity):
		var names := {}
		for property: Dictionary in actor.get_property_list():
			names[String(property.name)] = true
		_properties[identity] = names
	return actor.get(key) if _properties[identity].has(key) else fallback

static func implementation(actor: Node) -> String:
	var script: Script = actor.get_script()
	var path := script.resource_path if script != null else ""
	if path.ends_with("procedural_sediment_titan.gd"):
		return "titan"
	if path.ends_with("melee_enemy.gd"):
		return "roster_melee"
	if path.ends_with("ranged_enemy.gd"):
		return "roster_ranged"
	return "basic"

static func public_point(actor: Node3D) -> Vector3:
	if implementation(actor) == "titan":
		var core: Node3D = value(actor, "core_mesh")
		if is_instance_valid(core):
			return core.global_position
	return actor.global_position + Vector3.UP * 0.45

static func public_area(actor: Node3D) -> Node3D:
	# 只适配实际显示的地面预警；不拿远程私有瞄准倒计时伪造可见圆圈。
	if implementation(actor) not in ["titan", "roster_melee"]:
		return null
	var area: Node3D = value(actor, "_attack_area")
	if is_instance_valid(area) and not bool(area.get("shape").get("ground_effect", true)):
		return null
	return area

static func public_shield(actor: Node3D) -> bool:
	return bool(value(actor, "has_mud_shield", false)) if implementation(actor) == "titan" else false

static func public_break_cues(actor: Node3D) -> Dictionary:
	# 决策只看场景中已显示的模型／颜色／罩；不读计数、状态机或剩余计时。
	if implementation(actor) != "titan":
		return {}
	var core: MeshInstance3D = value(actor, "core_mesh")
	var torso: Node3D = value(actor, "torso_pivot")
	var visual: Node3D = value(actor, "visual_root")
	var guard: Node3D = value(actor, "_crystal_guard_visual")
	if not is_instance_valid(core) or not core.is_visible_in_tree():
		return {}
	var material := core.material_override as StandardMaterial3D
	return {"crystal": core.global_position, "body": torso.global_position,
		"red_crystal": material != null and material.albedo_color.g < 0.2,
		"guard_visible": is_instance_valid(guard) and guard.is_visible_in_tree(),
		"fallen_pose": absf(visual.rotation.x) > 0.8}

static func sample(actor: Node3D, id: String) -> Dictionary:
	var kind := implementation(actor)
	var supported := kind != "basic"
	var pos := actor.global_position
	var velocity: Vector3 = actor.velocity if actor is CharacterBody3D else Vector3.ZERO
	var state := "unknown"
	var raw_state := -1
	var waiting := false
	var actionable := false
	var cooldown := 0.0
	var attack_key := str(actor.get_meta(&"sparring_attack_serial", ""))
	var diagnostic := {}
	var attack := {}
	if kind == "titan":
		raw_state = int(value(actor, "current_state", -1))
		var names := ["emerging", "idle", "chase", "slam", "sweep", "shield", "dead", "leap_windup", "leap_air", "leap_recover", "jump_melee", "group_rest", "reward_lower", "reward_hold", "reward_rise", "reward_landing", "thrust"]
		state = names[raw_state] if raw_state >= 0 and raw_state < names.size() else "unknown"
		actionable = raw_state in [1, 2]
		waiting = not actionable
		cooldown = float(value(actor, "attack_cooldown", 0.0))
		diagnostic = actor.call("get_sparring_diagnostic")
		var brain: RefCounted = value(actor, "_brain")
		if brain != null and not brain.history.is_empty():
			attack = brain.history[-1].duplicate(true)
			attack_key = "%s:%s" % [attack.time, attack.skill]
	elif kind in ["roster_melee", "roster_ranged"]:
		var attacking := float(value(actor, "_attack_elapsed", -1.0)) >= 0.0 if kind == "roster_melee" else bool(value(actor, "attack_queued", false)) or int(value(actor, "burst_remaining", 0)) > 0
		var defending := int(value(actor, "_shield_state", 0)) != 0
		var staggered := float(value(actor, "_stagger_time", 0.0)) > 0.0
		state = "dead" if not Health.is_alive(actor) else "defending" if defending else "stagger" if staggered else "attack" if attacking else "locomotion"
		actionable = state == "locomotion"
		cooldown = float(value(actor, "attack_cooldown" if kind == "roster_melee" else "fire_cooldown", 0.0))
		var global_wait := maxi(int(value(actor, "next_global_fire_msec", 0)) - Time.get_ticks_msec(), 0) if kind == "roster_ranged" else 0
		waiting = not actionable or global_wait > 0
		var steering: RefCounted = value(actor, "_steering")
		diagnostic = {"trace": actor.get_meta(&"sparring_trace", {}), "navigation": steering.get_sparring_diagnostic() if steering != null else {},
			"global_fire_wait_ms": global_wait, "attack_cooldown": cooldown}
	if actor is CharacterBody3D:
		var contacts: Array = []
		for index in range(mini(actor.get_slide_collision_count(), 4)):
			var hit: KinematicCollision3D = actor.get_slide_collision(index)
			var normal := hit.get_normal()
			var collider := hit.get_collider()
			contacts.append({"normal": [normal.x, normal.y, normal.z], "collider": str(collider.get_path()) if collider is Node else str(collider)})
		diagnostic.merge({"contacts": contacts, "on_floor": actor.is_on_floor()})
	diagnostic.merge({"physics_enabled": actor.is_physics_processing(), "process_enabled": actor.is_processing(),
		"ai_enabled": bool(value(actor, "ai_enabled", true)), "target_alive": Health.is_alive(value(actor, "target")),
		"hitstop_restore": actor.get_meta(&"hitstop_restore", {}), "hitstop_token": actor.get_meta(&"hitstop_token", 0), "motion": actor.get_meta(&"sparring_motion", {})})
	if actor.has_method("grenade_stagger_active") and actor.call("grenade_stagger_active"):
		waiting = true
		actionable = false
		diagnostic["grenade_stagger"] = true
	return {"id": id, "roster_id": String(actor.get_meta(&"lab_roster_id", kind)), "title": String(actor.get_meta(&"lab_title", value(actor, "enemy_title", kind))),
		"implementation": kind, "alive": Health.is_alive(actor), "available": true,
		"removed_without_death": actor.is_queued_for_deletion() and (Health.health_of(actor) == null or Health.health_or(actor, 1.0) > 0.0),
		"hp": Health.health_of(actor), "max_hp": Health.max_health_or(actor, 0.0), "position": [pos.x, pos.y, pos.z], "velocity": [velocity.x, velocity.y, velocity.z],
		"state": state, "raw_state": raw_state, "actionable": actionable, "expected_wait": waiting, "attack_cooldown": cooldown,
		"attack_key": attack_key, "attack": attack, "diagnostic": diagnostic,
		"rage": bool(value(actor, "is_enraged", false)), "mud_shield": public_shield(actor),
		"capabilities": {"state": supported, "attack_events": supported, "navigation": supported, "causal_trace": supported,
			"public_ground_warning": kind == "titan", "health": Health.health_of(actor) != null}}

static func statistics(actor: Node) -> Dictionary:
	var ranged := implementation(actor) == "roster_ranged"
	return {"health": Health.max_health_or(actor, 0.0), "armor": float(value(actor, "_armor", 0.0)), "speed": float(value(actor, "move_speed", 0.0)),
		"size": actor.scale.x if actor is Node3D else 1.0,
		"attack_damage": float(value(actor, "projectile_damage" if ranged else "attack_damage", 0.0)) * float(value(actor, "_damage_scale", 1.0)),
		"attack_interval": float(value(actor, "fire_interval" if ranged else "attack_interval", 0.0))}
