extends RefCounted
## 首条实用闭环的显式适配。未审定字段一律待重建，不泛化到其他敌人。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const COLORS := ["rock_r", "rock_g", "rock_b", "crystal_r", "crystal_g", "crystal_b", "glow"]

static func identity(target: Node) -> Dictionary:
	var entry: Dictionary = target.get_meta("enemy_entry", {})
	var profile := String(entry.get("species", ""))
	if target.has_method("profile_id"): profile = target.profile_id()
	elif target.get_script() and target.get_script().resource_path.ends_with("procedural_sediment_titan.gd"): profile = "PrototypeSedimentTitan"
	return Catalog.identity(profile)

static func target_id(target: Node) -> String:
	return "instance:%d" % target.get_instance_id()

static func source_preset(target: Node, profile: String) -> String:
	return String(target.get_meta("enemy_entry", {}).get("resolved_preset", target.get_meta("workspace_source_preset", Catalog.formal_preset(profile))))

static func base_values(target: Node, profile: String) -> Dictionary:
	return target.get_meta("workspace_values", target.get_meta("enemy_tuning", target.get_meta("enemy_entry", {}).get("tuning", Tuning.get_values(profile)))).duplicate(true)

static func apply(packet: Dictionary, target: Node, rebuild := false, allow_peer := false) -> Dictionary:
	var result := {"runtime_applied": false, "immediate": [], "next_action": [], "rebuild": [], "reason": ""}
	if not is_instance_valid(target) or not target.is_inside_tree():
		result.reason = "来源实例已失效；草稿保留，不替换为同类型其他对象"
		return result
	var profile := String(packet.identity.profile)
	if identity(target).get("profile") != profile or (not allow_peer and packet.target_id != target_id(target)):
		result.reason = "实例身份不匹配，未应用"
		return result
	var values: Dictionary = packet.values
	result.reason = Tuning.validate(profile, values)
	if not result.reason.is_empty(): return result
	var previous := base_values(target, profile)
	var changed: Array[String] = []
	for key: String in values:
		if values[key] != previous.get(key): changed.append(key)
	if changed.is_empty():
		if target.has_meta("workspace_next_action"): target.remove_meta("workspace_next_action")
		result.reason = "与当前采用值一致"
		return result
	for key: String in changed:
		if profile == "VisualChargeBeetle" and key in COLORS: result.immediate.append(key)
		elif profile == "PrototypeSedimentTitan" and (key.begins_with("triple_slam_") or key == "rage_director_enabled"): result.next_action.append(key)
		else: result.rebuild.append(key)
	if rebuild:
		if profile != "VisualChargeBeetle":
			result.reason = "此宿主重建未接入；保留原实例，未重开圣所"
			return result
		for key: String in changed:
			if preload("res://scripts/testing/enemy_parameter_ownership.gd").owner(profile, key) != "visual":
				result.reason = "待重建：本批只接入兜虫外形的现场重建；战斗字段%s请在原型台生成重测，未假报已应用" % key
				return result
		result.reason = target.rebuild_workspace(values)
		if not result.reason.is_empty(): return result
		result.immediate = changed
		result.rebuild = []
		previous = values.duplicate(true)
	elif not result.immediate.is_empty():
		# 只换本实例独占材质，不重建部件／受弹区，不影响当前动作、随机差异。
		var visual: Node3D = target.visual
		for key: String in result.immediate:
			previous[key] = values[key]
			target._tuning[key] = values[key]
			visual.values[key] = values[key]
		visual.rock.albedo_color = Color(values.rock_r, values.rock_g, values.rock_b)
		visual.crystal.albedo_color = Color(values.crystal_r, values.crystal_g, values.crystal_b)
		visual.crystal.emission = visual.crystal.albedo_color
		visual.crystal.emission_energy_multiplier = values.glow
	if not result.next_action.is_empty():
		var next := {}
		for key: String in result.next_action: next[key] = values[key]
		target.set_meta("workspace_next_action", {"values": next, "revision": packet.revision})
		target.set_meta("workspace_pending_revision", packet.revision)
	elif target.has_meta("workspace_next_action"):
		target.remove_meta("workspace_next_action")
	target.set_meta("workspace_values", previous)
	result.runtime_applied = not result.immediate.is_empty()
	result.reason = "立即 %d · 下次动作 %d · 待重建 %d" % [result.immediate.size(), result.next_action.size(), result.rebuild.size()]
	target.set_meta("workspace_application", result.duplicate(true))
	return result
