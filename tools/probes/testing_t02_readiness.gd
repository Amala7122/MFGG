extends SceneTree
## T02只读准备：导出当前字段、归属候选与真实画廊能力，不安装归属过滤或改写方案。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
const Parts := preload("res://scripts/prototypes/visual_param_parts.gd")
const Gallery := preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const PURE_VISUAL_GROUPS := ["物种外形", "材质", "死亡表现（无伤害，可重播）", "技能姿态张力（即时生效）"]
const VISUAL_KEYS := ["body_size", "corpse_lifetime", "impact_fx_lifetime", "hit_flash_duration", "hit_flash_strength", "crystal_flash_scale", "crystal_flash_in", "crystal_flash_out", "crystal_flash_strength", "crystal_spin_speed", "core_lifetime", "core_death_spin", "mud_shield_spin", "rage_crystal_size", "rage_spin_multiplier", "ground_shake_strength", "aim_abdomen_angle", "dive_lift", "dive_head_angle", "dive_body_angle", "jaw_open_angle", "bite_frequency", "bite_angle", "stagger_angle"]
var fields: Array[Dictionary] = []
var capabilities: Array[Dictionary] = []
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for index in count: await process_frame

func candidate(profile: String, key: String, group: String, meta: Dictionary) -> Dictionary:
	var owner := "combat_prototype"
	var reason := "个体行为／战斗定义候选；必须按实际读取复核"
	if key.begins_with("grenade_"):
		owner = "player_conditions"
		reason = "泰坦schema内的玩家手雷资源；存储位置不决定编辑归属"
	elif profile == "VisualBurstCrawler" and key in ["turn_yaw", "release_snap_ratio"]:
		reason = "crawler_behavior直接用于攻击方向／实际投囊触发时刻，不能按姿态栏归视觉"
	elif key in VISUAL_KEYS or int(meta.tab) == 6 or group in PURE_VISUAL_GROUPS or group == "死亡演出":
		owner = "visual"
		reason = "外形／表现候选；仍须登记碰撞、发射点、生命周期等依赖"
	elif group == "体型与动作（编辑即时生效）" and key not in ["windup", "release", "recovery"]:
		owner = "visual"
		reason = "体型／步态／呼吸；技能时序另归战斗"
	if key.begins_with("crowd_"):
		owner = "combat_prototype"
		reason = "当前是个体邻域响应，不是持久编组策略；空间台引用角色方案"
	return {"candidate_owner":owner,"candidate_reason":reason,"review_state":"候选，未作为正式编辑权限；T02逐项复核"}

func _run() -> void:
	await frames(4)
	var flow := root.get_node_or_null("GameFlow")
	if flow:
		flow.process_mode = Node.PROCESS_MODE_DISABLED
		flow.visible = false
	for profile: String in Tuning.PROFILE_PATHS:
		var schema := Tuning.get_schema(profile)
		if schema.is_empty(): failures.append("配置不可读："+profile); continue
		for group: Dictionary in schema.groups:
			for spec: Dictionary in group.fields:
				var key := String(spec.key)
				var meta := Layout.field(profile,spec,String(group.title))
				var entry := {"profile":profile,"key":key,"label":meta.label,"source":Tuning.PROFILE_PATHS[profile],"source_group":group.title,"tab":Layout.TABS[int(meta.tab)],"section":meta.section,"unit":meta.unit,"scale_rule":meta.scale_rule,"value":spec.value,"min":meta.get("min"),"max":meta.get("max"),"recommended_min":meta.get("recommended_min"),"recommended_max":meta.get("recommended_max"),"part_mapping":Parts.lookup(profile,key)}
				entry.merge(candidate(profile,key,String(group.title),meta))
				fields.append(entry)
	var gallery := Gallery.instantiate()
	root.add_child(gallery)
	current_scene = gallery
	await frames(6)
	for index in gallery.GALLERY.size():
		gallery._show_subject(index)
		await frames(3)
		var subject: Node3D = gallery._subject
		if not is_instance_valid(subject): failures.append("画廊无法创建："+str(index)); continue
		var entry: Dictionary = gallery.GALLERY[index]
		if gallery._gallery_index != index or subject.scene_file_path != (entry.scene as PackedScene).resource_path:
			failures.append("画廊停留在旧对象："+String(entry.title))
		var agent := subject.get_node_or_null("NavOrigin/NavAgent") as NavigationAgent3D
		var collision := subject.get_node_or_null("CollisionShape3D") as CollisionShape3D
		var record := {"index":index,"title":entry.title,"profile":entry.profile,"scene":entry.scene.resource_path,"declared_observation":entry.observe,"sample_pose":subject.has_method("sample_pose"),"apply_visual_values":subject.has_method("apply_visual_values"),"panel_visible":gallery._visual_panel.visible,"editable_fields":gallery._visual_panel._inputs.size() if gallery._visual_panel.visible else 0,"script":subject.get_script().resource_path,"scale":str(subject.scale),"collision":str(collision.shape) if collision else "","agent_radius":agent.radius if agent else 0.0,"agent_height":agent.height if agent else 0.0}
		if subject.has_method("get_body_dimensions"):
			record["base_body_dimensions"] = str(subject.get_script().get_body_dimensions(Tuning.defaults(String(entry.profile))))
		capabilities.append(record)
	current_scene = null
	gallery.queue_free()
	await frames(3)
	var owners := {}
	for entry: Dictionary in fields:
		owners[entry.candidate_owner] = int(owners.get(entry.candidate_owner,0))+1
	var path := Artifacts.ensure_dir("reports").path_join("t02_readiness.json")
	var out := FileAccess.open(path,FileAccess.WRITE)
	if out == null:
		push_error("T02准备报告无法写入："+path)
		quit(1)
		return
	out.store_string(JSON.stringify({"purpose":"只读准备；候选归属并非已实现路由，能力为本次真实运行结果","engine":Engine.get_version_info(),"fields":fields,"candidate_counts":owners,"gallery":capabilities,"failures":failures},"\t"))
	out.close()
	for message: String in failures: push_error(message)
	print("[T02准备] fields=",fields.size()," gallery=",capabilities.size()," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
