extends SceneTree
## 统一布局完整覆盖、真实实例缩放、七兵种单招入口与暂停合同。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Layout := preload("res://scripts/testing/enemy_parameter_layout.gd")
const Inspect := preload("res://scripts/testing/enemy_attack_inspection.gd")
const Lab := preload("res://prototypes/combat_lab/combat_lab.tscn")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures: Array[String] = []
var checks := 0
var observations: Array[Dictionary] = []
var catalog: Array[Dictionary] = []

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func frames(count: int) -> void:
	for i in count: await physics_frame

func _run() -> void:
	await frames(5)
	_layout()
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	await frames(8)
	for id: String in Tuning.PROFILE_PATHS:
		var base := Tuning.defaults(id)
		base.variation_enabled = false
		base.crowd_enabled = false
		base.body_size = 1.0
		await lab.observe_draft(id, base)
		var subject: Node3D = lab._live_enemies[0]
		check(lab._attack_observer.study and MouseControl.mode == Input.MOUSE_MODE_VISIBLE, id+" 单体观察释放鼠标")
		check(subject.get_meta(&"crowd_seed") == 20261020 and subject.get_meta(&"crowd_uniform"), id+" 固定个体条件")
		var small: Dictionary = subject._tuning.duplicate(true)
		var small_spec: Dictionary = Inspect.sample(subject, 0).spec
		var small_agent := subject.get_node_or_null("NavOrigin/NavAgent") as NavigationAgent3D
		var agent_radius := small_agent.radius if small_agent else 0.0
		var agent_height := small_agent.height if small_agent else 0.0
		await frames(90)
		var state_after: int = subject.current_state
		var trace_count: int = lab._attack_observer._traces.size()
		if id in ["PrototypeMudGolem", "PrototypeSedimentTitan"]:
			check(lab._attack_observer._traces.any(func(trace: Dictionary): return trace.point == "right_fist"), id+" 原地出拳保留实际拳头轨迹")
		var values := base.duplicate(true)
		values.body_size = 2.0
		await lab.observe_draft(id, values)
		subject = lab._live_enemies[0]
		check(is_equal_approx(subject.scale.x, 2.0), id+" 真实模型／碰撞只放大一次")
		var large_agent := subject.get_node_or_null("NavOrigin/NavAgent") as NavigationAgent3D
		if large_agent:
			check(is_equal_approx(large_agent.radius,agent_radius*2.0) and is_equal_approx(large_agent.height,agent_height*2.0),id+" 导航代理世界尺寸跟随体型")
		for key: String in Layout.WORLD_KEYS[id]:
			check(is_equal_approx(float(subject._tuning[key]), float(small[key])*2.0), id+" 世界值联动 "+key)
		for key: String in ["max_health", "attack_damage", "attack_interval", "windup", "armor", "move_speed", "flight_speed"]:
			if small.has(key): check(subject._tuning[key] == small[key], id+" 体型不改独立值 "+key)
		var large_spec: Dictionary = Inspect.sample(subject, 0).spec
		for key: String in ["radius", "length", "width", "height"]:
			if small_spec.has(key): check(is_equal_approx(float(large_spec[key]),float(small_spec[key])*2.0),id+" 实际判定尺寸联动 "+key)
		observations.append({"profile":id,"state_after_90":state_after,"traces":trace_count,"small":small_spec,"large":large_spec})
		lab._attack_observer.get_tree().paused = true
		var before: Vector3 = subject.global_position
		var clock_key := "flight_clock" if id == "PrototypeHornet" else "anim_clock"
		var timer: float = subject.get(clock_key)
		await frames(3)
		check(subject.global_position.is_equal_approx(before), id+" 暂停冻结身体")
		var frozen: float = subject.get(clock_key)
		check(is_equal_approx(timer,frozen), id+" 暂停冻结攻击计时")
		await lab._attack_observer._step()
		await process_frame
		var stepped: float = subject.get(clock_key)
		check(paused and stepped > frozen and stepped-frozen < 0.04, id+" 单帧只推进一帧并重新冻结")
		lab._show_enemy_tuning(id)
		check(lab._tuning_panel._fields.size() == Tuning.defaults(id).size(),id+" 面板没有遗漏参数")
		check(lab._tuning_panel._tabs.get_tab_count() == Layout.TABS.size(),id+" 固定八分页")
		for key: String in ["walk_frequency", "trot_frequency"]:
			if values.has(key):
				check(is_equal_approx(lab._tuning_panel._fields[key].value,float(values[key])/TAU),id+" 步频统一显示Hz")
				var control: SpinBox = lab._tuning_panel._fields[key]
				var entered := (control.min_value+control.max_value)*0.5
				control.value = entered
				check(is_equal_approx(float(lab._tuning_panel._session.values(lab._tuning_panel.draft_id)[key]),TAU*entered),id+" Hz输入换算原存储值")
	# 每一招都走实际入口；不只覆盖每个敌人的默认一招。
	for id: String in Tuning.PROFILE_PATHS:
		for index in Layout.SKILLS[id].size():
			var values := Tuning.defaults(id)
			values.body_size = 1.0
			for key in ["leap_enabled","thrust_enabled"]:
				if values.has(key): values[key] = true
			lab._attack_observer.skill_choice.select(index)
			lab._attack_observer.distance_input.value = lab._observation_distance(id, values, index)
			lab._observation_profile = id
			await lab.observe_draft(id, values, false)
			var subject: Node3D = lab._live_enemies[0]
			var sample := Inspect.sample(subject,index)
			check(not sample.is_empty() and sample.title == Layout.SKILLS[id][index][0],id+" 可观察技能 "+str(index))
			await frames(12)
			var active: bool = not lab._attack_observer.active_snapshots.is_empty()
			var action: bool = active or subject.current_state != 0
			check(action,id+" 真实单招启动 "+String(sample.title))
			if id == "VisualBurstCrawler" and index == 1:
				# 黏液由投囊真实落地生成，不伪造伤害池。
				await frames(240)
				check(not get_nodes_in_group("enemy_poison_puddles").is_empty() or not lab._attack_observer._traces.is_empty(), "黏液观察由真实投射物驱动")
	paused = false
	lab.queue_free()
	await frames(2)
	var out := FileAccess.open(Artifacts.ensure_dir("reports").path_join("enemy_parameter_contract.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify({"checks":checks,"failures":failures,"observations":observations,"catalog":catalog},"\t"))
	out.close()
	print("[统一调参] checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)

func _layout() -> void:
	for id: String in Tuning.PROFILE_PATHS:
		check(Layout.SKILLS.has(id) and Layout.WORLD_KEYS.has(id),id+" 必须声明技能映射与缩放合同")
		if not Layout.SKILLS.has(id) or not Layout.WORLD_KEYS.has(id): continue
		var schema := Tuning.get_schema(id)
		var groups := Layout.groups(id,schema)
		var actual := {}
		var index := 0
		for group: Dictionary in groups:
			check(group.title == Layout.TABS[index],id+" 固定页序 "+str(index))
			index += 1
			for spec: Dictionary in group.fields:
				catalog.append({"profile":id,"tab":group.title,"section":spec.section,"key":spec.key,"label":spec.label,"unit":spec.unit,"scale":spec.scale_rule})
				check(not actual.has(spec.key),id+" 字段不重复 "+String(spec.key))
				actual[spec.key] = true
				check(spec.has("semantic") and spec.has("unit") and spec.has("scale_rule"),id+" 字段合同 "+String(spec.key))
				check(spec.value == Tuning.defaults(id)[spec.key],id+" 显示层不改变默认值 "+String(spec.key))
		check(actual.size() == Tuning.defaults(id).size(),id+" 全部字段覆盖")
		for skill: Array in Layout.SKILLS[id]:
			for key: String in skill[1]:
				check(actual.has(key),id+" 技能绑定字段存在 "+key)
