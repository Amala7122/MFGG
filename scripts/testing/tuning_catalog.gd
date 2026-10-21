extends RefCounted
## 归属与身份目录；从现有 schema / species / 图鉴派生，不新增另一份游戏数值。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Ownership := preload("res://scripts/testing/enemy_parameter_ownership.gd")
const Creatures := preload("res://scripts/enemies/creature_catalog.gd")
const Config := preload("res://scripts/game_config.gd")
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
const PILOT := {
	"body_size": ["视觉测试台", "体型", "重建身体／碰撞"],
	"max_health": ["战斗原型测试台", "基础属性", "重新生成"],
	"thrust_width": ["战斗原型测试台", "远距震拳／形状", "重新生成；起手快照"],
	"thrust_distance": ["战斗原型测试台", "远距震拳／形状", "重新生成；起手快照"],
	"thrust_damage": ["战斗原型测试台", "远距震拳／伤害", "重新生成；起手快照"],
	"thrust_windup": ["战斗原型测试台", "远距震拳／时序", "重新生成；起手快照"],
	"thrust_swing": ["战斗原型测试台", "远距震拳／时序", "重新生成；起手快照"],
	"thrust_recovery": ["战斗原型测试台", "远距震拳／时序", "重新生成；起手快照"],
	"thrust_cooldown": ["战斗原型测试台", "远距震拳／冷却", "重新生成"],
	"offense_front_limit": ["战斗原型测试台", "个体策略／招组", "重新生成"],
}
const DOMAINS := {
	"spawn": {"mode": ["模式", "", "投放"], "max_alive": ["人数硬上限", "只", "容量"], "target_alive": ["目标存活", "只", "容量"], "refill_interval": ["补充间隔", "秒", "投放"], "prepare_seconds": ["准备时间", "秒", "流程"], "spawn_interval": ["批间间隔", "秒", "投放"], "squad_member_interval": ["批内间隔", "秒", "投放"], "extra_enemies_per_level": ["每等级加量", "只", "波次"], "wave_stuck_guard": ["停滞保护", "秒", "高级生命周期"], "ranged_ratio": ["远程比例", "比例", "候选池"]},
	"wave": {"count": ["波数", "波", "波次"], "base_enemies": ["基础预算", "只", "波次"], "growth_per_wave": ["逐波加量", "只", "波次"], "intermission": ["波间时间", "秒", "流程"], "boss_id": ["Boss 引用", "角色", "Boss"], "guarantee_roster": ["保证名单", "开关", "候选池"]},
	"lifecycle": {"watchdog_interval": ["巡检间隔", "秒", "高级生命周期"], "edge_margin": ["越界余量", "米", "高级生命周期"], "fall_margin": ["坠界余量", "米", "高级生命周期"], "pickup_height": ["掉落抬高", "米", "高级生命周期"], "drop_probe_depth": ["掉落探地", "米", "高级生命周期"]},
	"entry": {"id": ["条目身份", "ID", "角色引用"], "species": ["物种", "角色", "角色引用"], "title": ["显示名", "文本", "角色引用"], "kind": ["近远程类别", "类别", "候选池"], "drop_kind": ["掉落类别", "类别", "高级生命周期"], "preset": ["成员方案", "引用", "角色引用"], "min_weapon_level": ["最低武器等级", "级", "候选池"], "weight": ["类别内权重", "权重", "候选池"], "min_player_distance": ["最小投放距离", "米", "投放"], "max_player_distance": ["最大投放距离", "米", "投放"]},
}

static func roles() -> Dictionary:
	var result := {}
	for species: String in Creatures.SPECIES:
		var item: Dictionary = Creatures.SPECIES[species]
		result["enemy:" + species] = {"role_id": "enemy:" + species, "species": species, "profile": item.profile, "combat_scene": item.scene.resource_path}
	result["enemy:sediment_titan"] = {"role_id": "enemy:sediment_titan", "species": "sediment_titan", "profile": "PrototypeSedimentTitan", "combat_scene": "res://prototypes/enemy_prototypes/procedural_sediment_titan.tscn"}
	for entry: Dictionary in Config.get_dictionary("enemy_roster").get("entries", []):
		result["legacy:" + String(entry.id)] = {"role_id": "legacy:" + String(entry.id), "legacy_id": entry.id, "profile": "", "entry": entry.duplicate(true)}
	return result

static func identity(identifier: String, form := "combat") -> Dictionary:
	if identifier.is_empty(): return {}
	if form not in ["combat", "visual"]: return {}
	for item: Dictionary in roles().values():
		if identifier in [item.role_id, String(item.get("species", "")), String(item.get("legacy_id", ""))] or (not String(item.profile).is_empty() and identifier == item.profile):
			var result := item.duplicate(true)
			result["form"] = form
			return result
	return {}

static func formal_preset(profile: String) -> String:
	return String(Config.get_dictionary("bosses.sediment_titan").get("preset", "")) if profile == "PrototypeSedimentTitan" else ""

static func references(profile: String, name: String) -> Array[String]:
	var result: Array[String] = []
	if Tuning.active_name(profile) == name: result.append("当前默认（所有跟随默认的入口）")
	if formal_preset(profile) == name and not name.is_empty(): result.append("正式沉积泰坦 Boss")
	for file: String in DirAccess.get_files_at("res://data/encounters"):
		if not file.ends_with(".json"): continue
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/encounters/" + file))
		if not data is Dictionary: continue
		for entry: Dictionary in data.get("entries", []):
			var record := identity(String(entry.get("species", "")))
			if record.get("profile", "") == profile and String(entry.get("preset", "@active")) == name:
				result.append(String(data.get("title", file)) + "／" + String(entry.get("title", entry.get("id", ""))))
	return result

static func field(profile: String, key: String) -> Dictionary:
	for group: Dictionary in Tuning.get_schema(profile).get("groups", []):
		for spec: Dictionary in group.fields:
			if String(spec.key) != key: continue
			var d := spec.duplicate(true)
			d["profile"] = profile
			d["module"] = group.title
			d["owner"] = Ownership.title(profile, key)
			d["domain"] = Ownership.owner(profile, key)
			d["dependency"] = Ownership.dependency(profile, key)
			d["apply"] = "战斗实体重新生成"
			d["reviewed"] = profile == "PrototypeSedimentTitan" and PILOT.has(key)
			if d.reviewed:
				d.owner = PILOT[key][0]
				d.module = PILOT[key][1]
				d.apply = PILOT[key][2]
			d["unit"] = spec.get("unit", "开关" if spec.value is bool else "")
			if d.reviewed:
				d.unit = {"body_size": "倍", "max_health": "点", "thrust_width": "米", "thrust_distance": "米", "thrust_damage": "点", "offense_front_limit": "招"}.get(key, "秒")
			d["source"] = Tuning.PROFILE_PATHS[profile]
			d["save"] = "命名方案；另存与默认分开"
			d["observation"] = "现有战斗场重新生成后试打；实时形状编辑待 T03"
			var presentation := Layout.field(profile, spec, String(group.title))
			for member in ["label", "unit", "semantic", "scale_rule", "section", "tab"]:
				if presentation.has(member): d[member] = presentation[member]
			# 会话用 min/max 校验存储单位；界面换算后的边界必须另列，不能覆盖。
			d["storage_unit"] = spec.get("unit", "")
			d["display_min"] = presentation.get("min")
			d["display_max"] = presentation.get("max")
			d.module = Layout.TABS[int(presentation.tab)] + "／" + String(presentation.section)
			d.observation = "战斗原型测试台：观察本草稿→固定目标→重播本招；普通战斗V切换范围与轨迹"
			return d
	return {}

static func encounter_fields(path: String) -> Array[Dictionary]:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var out: Array[Dictionary] = []
	if not parsed is Dictionary: return out
	for key: String in parsed:
		if key in ["spawn", "wave", "lifecycle"]:
			for member: String in parsed[key]: out.append(_encounter_field(path, key + "." + member, key, member, parsed[key][member]))
		elif key == "entries":
			for index in parsed.entries.size():
				for member: String in parsed.entries[index]: out.append(_encounter_field(path, "entries[%d].%s" % [index, member], "entry", member, parsed.entries[index][member]))
		else:
			var labels := {"id": "编排身份", "title": "编排名称", "notes": "编排说明", "version": "格式版本"}
			out.append({"path": key, "source": path, "owner": "实战测试台", "module": "编排说明" if labels.has(key) else "未登记", "label": labels.get(key, key), "unit": "文本", "value": parsed[key], "status": "缺失登记" if not labels.has(key) else "内部只读" if key == "version" else "待 T06 编辑", "apply": "重开本轮", "save": "关卡命名编排，与正式绑定分开"})
	return out

static func _encounter_field(path: String, address: String, domain: String, key: String, value: Variant) -> Dictionary:
	var spec: Array = DOMAINS.get(domain, {}).get(key, [])
	return {"path": address, "source": path, "owner": "实战测试台", "module": spec[2] if spec.size() == 3 else "未登记", "label": spec[0] if spec.size() == 3 else key, "unit": spec[1] if spec.size() == 3 else "", "value": value, "status": "待 T06 编辑" if spec.size() == 3 else "缺失登记", "apply": "重新生成／重开本轮", "save": "关卡命名编排，与正式绑定分开"}

static func group_context(template_id: String, template_revision: String, instance_id: String, member_id: String) -> Dictionary:
	return {"template_id": template_id, "template_revision": template_revision, "instance_id": instance_id, "member_id": member_id, "quantity_unit": "组", "member_unit": "只", "runtime_status": "T05 未接入"}
