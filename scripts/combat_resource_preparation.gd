extends RefCounted
## 开局渲染准备：只生成视觉样本，不进入敌人生命周期、导航、队列或伤害。
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Catalog := preload("res://scripts/enemies/creature_catalog.gd")
const Config := preload("res://scripts/game_config.gd")
const Surface := preload("res://scripts/attack_surface_mesh.gd")
const Flash := preload("res://scripts/enemies/enemy_hit_flash.gd")
const Projectile := preload("res://scripts/enemies/crystal_projectile.gd")
const BUILDERS := {
	"PrototypeMudGolem": ["res://prototypes/enemy_prototypes/procedural_mud_golem.tscn", "_build_procedural_mesh"],
	"PrototypeFastBeast": ["res://prototypes/enemy_prototypes/procedural_fast_beast.tscn", "_build_procedural_beast"],
	"PrototypeHornet": ["res://prototypes/enemy_prototypes/procedural_hornet.tscn", "_build_hornet_mesh"],
	"PrototypeSedimentTitan": ["res://prototypes/enemy_prototypes/procedural_sediment_titan.tscn", "_build_titan_mesh"],
}
const VISUALS := {
	"VisualBurstCrawler": "res://prototypes/visual_lab/burst_crawler_visual.tscn",
	"VisualPrismSpider": "res://prototypes/visual_lab/prism_spider_visual.tscn",
	"VisualChargeBeetle": "res://prototypes/visual_lab/charge_beetle_visual.tscn",
}
static var enabled := true # 仅供隔离探针对照；正式默认开启。
static var _signature := ""
static var _resources: Array[Resource] = []
static var runs := 0
static var last_ms := 0.0
static var last_resource_count := 0
static var last_static_bytes := 0

static func _profiles(scene_path: String) -> Dictionary:
	var result := {}
	var session: RefCounted = load("res://scripts/testing/tuning_session.gd").shared()
	for profile: String in Tuning.PROFILE_PATHS:
		var selected: String = session.scene_preset(scene_path, profile)
		result[profile] = Tuning.get_values(profile) if selected.is_empty() else Tuning.preset_values(profile, selected)
	return result

static func fingerprint(viewport: Viewport, scene_path: String) -> String:
	var features := {"msaa": viewport.msaa_3d, "taa": viewport.use_taa,
		"scale": viewport.scaling_3d_scale, "scaling": viewport.scaling_3d_mode,
		"graphics": Config.get_dictionary("graphics"),
		"support": preload("res://scripts/player_support_settings.gd").load_values()}
	var environment := viewport.find_world_3d().environment
	if environment != null:
		for property: String in ["ssao_enabled", "ssil_enabled", "ssr_enabled", "sdfgi_enabled", "volumetric_fog_enabled", "fog_enabled"]:
			features[property] = environment.get(property)
	return JSON.stringify({"profiles": _profiles(scene_path), "render": features}).sha256_text()

static func needed(viewport: Viewport, scene_path: String) -> bool:
	return enabled and DisplayServer.get_name() != "headless" and _signature != fingerprint(viewport, scene_path)

static func warmup(viewport: Viewport, scene_path: String, status := Callable()) -> void:
	if not needed(viewport, scene_path): return
	var camera := viewport.get_camera_3d()
	if camera == null:
		push_error("战场准备缺少活动相机")
		return
	var started := Time.get_ticks_usec()
	var memory_before := OS.get_static_memory_usage()
	var signature := fingerprint(viewport, scene_path)
	var profiles := _profiles(scene_path)
	var resources: Dictionary = {}
	var holder := Node3D.new()
	holder.name = "CombatResourcePreparation"
	holder.process_mode = Node.PROCESS_MODE_DISABLED
	viewport.add_child(holder)
	# 第三人称相机约在玩家身后5m；样本放在相机前2–3m，避免被玩家遮住。
	holder.global_transform = camera.global_transform
	var index := 0
	for profile: String in profiles:
		index += 1
		if status.is_valid(): status.call("正在准备战场…（%d/%d）" % [index, profiles.size() + 1])
		var visual := _visual(profile, profiles[profile])
		holder.add_child(visual)
		_fit(visual)
		var particle_nodes := visual.find_children("*", "CPUParticles3D", true, false)
		for particles: CPUParticles3D in particle_nodes:
			particles.process_mode = Node.PROCESS_MODE_ALWAYS
			particles.emitting = true
		var flash: Node
		if profiles[profile].has("hit_flash_duration"):
			flash = Flash.new()
			visual.add_child(flash)
			flash.setup(visual, profiles[profile])
		# 公开观察采样即时生效，预热不运行任何宿主AI。
		if visual.has_method("sample_pose"):
			visual.preview_pose = 2
			visual.sample_pose(visual.get_preview_duration() * 0.5)
		await _draw(viewport, 120000 if not particle_nodes.is_empty() else 0)
		_collect(visual, resources)
		if flash != null:
			flash.play()
			await _draw(viewport)
			_collect(visual, resources)
			flash.clear()
		visual.free()
	# 字体、透明贴地ArrayMesh与弹体采用正式实现，全部禁用处理且不施放技能。
	if status.is_valid(): status.call("正在准备战场…（%d/%d）" % [index + 1, index + 1])
	await _effects(holder, profiles.VisualBurstCrawler, profiles.VisualPrismSpider, resources)
	await _draw(viewport)
	_collect(holder, resources)
	holder.free()
	# 只保留这一套配置的网格／材质；下一套替换旧集合，不按实例无限增长。
	_resources.clear()
	for resource: Resource in resources.values(): _resources.append(resource)
	_signature = signature
	runs += 1
	last_ms = (Time.get_ticks_usec() - started) / 1000.0
	last_resource_count = _resources.size()
	last_static_bytes = int(OS.get_static_memory_usage()) - int(memory_before)

static func _draw(viewport: Viewport, minimum_usec := 0) -> void:
	var started := Time.get_ticks_usec()
	var frames := 0
	while frames < 2 or Time.get_ticks_usec() - started < minimum_usec:
		await viewport.get_tree().process_frame
		await RenderingServer.frame_post_draw
		frames += 1

static func _visual(profile: String, values: Dictionary) -> Node3D:
	if VISUALS.has(profile):
		var visual: Node3D = load(VISUALS[profile]).instantiate()
		visual.set_meta(&"enemy_tuning", values.duplicate(true))
		visual.process_mode = Node.PROCESS_MODE_DISABLED
		return visual
	var spec: Array = BUILDERS[profile]
	# 程序化三怪与Boss尚无独立视觉场景：仅在离树构造器调用纯建模方法。
	# 构造器从未入树，_ready、碰撞、导航、随机差异和战斗注册都不会执行。
	var builder: Node = load(spec[0]).instantiate()
	builder.set("_tuning", values.duplicate(true))
	builder.call(spec[1])
	var result: Node3D = builder.get("visual_root")
	builder.remove_child(result)
	for child in builder.get_children(): child.free()
	# 部分宿主在成员初始化时创建攻击区，尚未成为子节点，需显式释放。
	var area: Node = builder.get("_attack_area") if profile != "PrototypeHornet" else null
	if is_instance_valid(area) and area.get_parent() == null: area.free()
	builder.free()
	return result

static func _fit(visual: Node3D) -> void:
	var bounds := AABB()
	var first := true
	var inverse := visual.global_transform.affine_inverse()
	for part: MeshInstance3D in visual.find_children("*", "MeshInstance3D", true, false):
		if not part.is_visible_in_tree(): continue
		var local: AABB = (inverse * part.global_transform) * part.get_aabb()
		bounds = local if first else bounds.merge(local)
		first = false
	var ratio := 3.0 / maxf(bounds.size.length(), 0.1)
	visual.scale *= ratio
	visual.position = Vector3(0, 0, -3) - bounds.get_center() * ratio

static func _collect(root: Node, resources: Dictionary) -> void:
	for part: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for resource: Resource in [part.mesh, part.material_override, part.material_overlay]:
			if resource != null: resources[resource.get_instance_id()] = resource
	for particles: CPUParticles3D in root.find_children("*", "CPUParticles3D", true, false):
		for resource: Resource in [particles.mesh, particles.material_override, particles.material_overlay]:
			if resource != null: resources[resource.get_instance_id()] = resource

static func _effects(holder: Node3D, lob_values: Dictionary, bolt_values: Dictionary, resources: Dictionary) -> void:
	# 首次命中世界会启用Decal渲染路径；使用真实纹理和真实地面。
	var fx := preload("res://scripts/combat_fx.gd")
	var players := holder.get_tree().get_nodes_in_group("player")
	var point: Vector3 = players[0].global_position if not players.is_empty() else Vector3.ZERO
	var ground: Dictionary = fx.sample_ground(holder, point)
	if not ground.is_empty():
		var decal := Decal.new()
		decal.size = Vector3(6, 2, 6)
		decal.texture_albedo = fx._get_crater_texture()
		decal.cull_mask = 1
		holder.add_child(decal)
		decal.global_position = ground.position - Vector3.UP * 0.84
		await _draw(holder.get_viewport())
		resources[decal.texture_albedo.get_instance_id()] = decal.texture_albedo
		decal.free()
	# 玩家闪白与敌人红闪的剔除模式不同。只取玩家模型，构造器不入树、不运行玩家逻辑。
	var player_builder: Node = load("res://scenes/player.tscn").instantiate()
	var player_model: Node3D = player_builder.get_node("PlayerModel")
	player_builder.remove_child(player_model)
	player_builder.free()
	holder.add_child(player_model)
	_fit(player_model)
	var rig: Node = preload("res://scripts/player_rig.gd").new()
	player_model.add_child(rig)
	rig.call("setup", player_model)
	rig.call("flash_hit")
	await _draw(holder.get_viewport())
	_collect(player_model, resources)
	player_model.free()
	# 原生命中火花（8碎片＋闪光）只触发视觉，不走对象池、命中或伤害入口。
	var spark: Node3D = preload("res://scripts/impact_spark.gd").new()
	holder.add_child(spark)
	spark.global_position = holder.global_transform * Vector3(0, 0, -2.5)
	spark.call("trigger", -holder.global_basis.z, Color(1.0, 0.78, 0.24), 1.0)
	# 火花与弹丸不能叠在同一位置预热：不透明弹丸会挡住碎片，遗漏真实管线。
	# 推进纯视觉采样，让八个碎片展开；未到回收时刻，不进入对象池。
	spark.call("_process", 0.05)
	await _draw(holder.get_viewport())
	_collect(spark, resources)
	spark.free()
	var shield: Node3D = preload("res://scripts/player_shield_fx.gd").new()
	holder.add_child(shield)
	shield.position = Vector3(0, -0.7, -2.5)
	shield.call("trigger", -holder.global_basis.z, 10.0)
	await _draw(holder.get_viewport())
	_collect(shield, resources)
	shield.free()
	# 无人机内置弹体也是首次交战路径，不能用有自发光的敌方弹丸代表。
	var dart: Node3D = preload("res://scripts/floating_wisp.gd").WispDart.new()
	holder.add_child(dart)
	dart.position = Vector3(0, 0, -2.5)
	dart.call("_build_visuals")
	await _draw(holder.get_viewport())
	_collect(dart, resources)
	dart.free()
	# 飘字的no_depth_test和描边与敌人姓名不同，必须走实际配置。
	var number: Label3D = preload("res://scripts/damage_number.gd").new()
	holder.add_child(number)
	number.position = Vector3(0, 0, -2.5)
	number.call("show_amount", 1234567890.0, Color.WHITE, 1.0)
	number.text = "0123456789"
	await _draw(holder.get_viewport())
	number.free()
	for size in [24, 28]:
		var label := Label3D.new()
		label.text = "泥土傀儡 迅捷晶兽 晶刺蜂 爆囊爬兽 棱眼蛛 铲角兜虫 沉积泰坦 0123456789/"
		label.font_size = size
		label.pixel_size = 0.006
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		holder.add_child(label)
		label.position = Vector3(0, float(size - 24) * 0.1, -2.5)
	var vertices := PackedVector3Array([Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)])
	var uv := PackedVector2Array()
	for vertex in vertices: uv.append(Vector2(vertex.x, vertex.z))
	var mesh: ArrayMesh = Surface.new()._commit(vertices, uv)
	var shaders := [preload("res://shaders/enemy_attack_fill.gdshader"), preload("res://shaders/enemy_attack_border.gdshader")]
	for index in shaders.size():
		var part := MeshInstance3D.new()
		part.mesh = mesh
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := ShaderMaterial.new()
		material.shader = shaders[index]
		material.set_shader_parameter("radius", 1.0)
		part.material_override = material
		holder.add_child(part)
		part.position = Vector3(float(index - 1) * 2.2, -1, -2.5)
		part.rotation.x = PI * 0.5
	# 黏液走正式地面构建和材质绑定顺序，避免只画代表面仍漏掉首池的管线。
	var pool: Node3D = preload("res://scripts/enemies/poison_puddle.gd").new()
	holder.add_child(pool)
	pool.call("configure", point, lob_values, {})
	pool.remove_from_group("enemy_hazards")
	for lob in [false, true]:
		var projectile := Projectile.new()
		holder.add_child(projectile)
		projectile.remove_from_group("enemy_projectiles")
		var origin := holder.global_transform * Vector3(0, 0, -2.5)
		if lob: projectile.configure_lob(origin, origin + Vector3(0, -1, -1), lob_values, {})
		else: projectile.configure_bolt(origin, -holder.global_basis.z, bolt_values, {})
		await _draw(holder.get_viewport())
		_collect(holder, resources)
		projectile.free()
