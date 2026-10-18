extends SceneTree
## 正式灰模接线的可恢复显示契约；不调整或放宽任何战斗规则。
const Settings := preload("res://scripts/greybox_settings.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Dust := preload("res://scripts/ground_dust.gd")
const Wisp := preload("res://scripts/floating_wisp.gd")
const Pool := preload("res://scripts/object_pool.gd")
const BulletScene := preload("res://scenes/enemy_bullet.tscn")
var director: Node
var world: Node3D
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if ok: print("PASS ",message)
	else:
		failures += 1
		push_error(message)
func frames(count: int) -> void:
	for _i in count:
		await process_frame
		if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw
func key(code: Key) -> void:
	for pressed in [true,false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
func mesh(parent: Node, label: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2,0.7,0.3)
	node.material_override = mat
	parent.add_child(node)
	return node
func _run() -> void:
	director = root.get_node("GreyboxDirector")
	check(not director.is_active and not director.is_processing(),"默认关闭且不逐帧巡场")
	await fixture()
	await fx_fixture()
	await runtime()
	director.deactivate()
	current_scene = null
	world.queue_free()
	await frames(3)
	preload("res://scripts/object_pool.gd").clear_all()
	print("[灰模] checks=",checks," failures=",failures)
	quit(1 if failures else 0)

func fixture() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	await frames(2)
	root.get_node("GameFlow")._resume_play()
	var camera := Camera3D.new()
	camera.environment = Environment.new()
	camera.environment.ambient_light_energy = 0.637
	world.add_child(camera)
	camera.make_current()
	var original_environment := camera.environment
	var original_ambient := original_environment.ambient_light_energy
	var sun := DirectionalLight3D.new()
	sun.light_energy = 2.137
	world.add_child(sun)
	var sun_energy := sun.light_energy
	var hidden_sun := DirectionalLight3D.new()
	hidden_sun.visible = false
	world.add_child(hidden_sun)
	var floor := mesh(world,"TerrainMesh")
	var road := mesh(world,"ValleyRoad_131")
	var road_mesh := road.mesh
	var road_pose := road.transform
	var road_material := road.material_override
	var original := floor.material_override
	var scene_mesh := floor.mesh
	var decor := Node3D.new()
	decor.name = "WorldDecor"
	world.add_child(decor)
	var flowers := mesh(decor,"Flowers")
	var pebbles := mesh(decor,"GroundPebbles")
	pebbles.visible = false
	var body := StaticBody3D.new()
	body.name = "FieldBoulders"
	body.collision_layer = 3
	decor.add_child(body)
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	var rocks := MultiMeshInstance3D.new()
	rocks.name = "BoulderBatch"
	rocks.multimesh = MultiMesh.new()
	rocks.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	rocks.multimesh.mesh = BoxMesh.new()
	rocks.multimesh.instance_count = 2
	rocks.multimesh.set_instance_transform(0,Transform3D(Basis(),Vector3(3,0,-4)))
	rocks.material_override = original
	body.add_child(rocks)
	var multimesh := rocks.multimesh
	var original_transform := multimesh.get_instance_transform(0)
	var enemy := CharacterBody3D.new()
	enemy.name = "SedimentTitan"
	enemy.add_to_group("enemies")
	enemy.velocity = Vector3(1,2,3)
	world.add_child(enemy)
	var enemy_mesh := mesh(enemy,"MainTorso")
	var shield_plate := mesh(enemy,"MudShieldPlate")
	var warning := preload("res://scripts/enemy_attack_area.gd").new()
	enemy.add_child(warning)
	warning.set_physics_process(false)
	var warning_fill: Material = warning._mesh.material_override
	var warning_edge: Material = warning._border.material_override
	var shield := preload("res://scripts/player_shield_fx.gd").new()
	world.add_child(shield)
	var shield_material: Material = shield.mesh.material_override
	var shared := mesh(world,"SharedMesh")
	shared.mesh = scene_mesh
	shared.material_override = null
	var player := Node3D.new()
	player.add_to_group("player")
	world.add_child(player)
	var player_body := mesh(player,"Body")
	var player_gun := mesh(player,"GunBody")
	var crowd: Array = []
	for index in range(100):
		var actor := CharacterBody3D.new()
		actor.add_to_group("enemies")
		actor.position = Vector3(index%10,0,-10-index/10)
		actor.velocity = Vector3(1,0,2)
		world.add_child(actor)
		var part := mesh(actor,"Body")
		crowd.append({"actor":actor,"part":part,"original":part.material_override,"pose":actor.transform})
	var effect := root.get_node("PostProcess")
	effect.set_style(5)
	director.activate()
	var entries: int = director._overrides.size()
	director.activate()
	check(director._overrides.size()==entries,"重复开启不清空原始材质记录")
	check(floor.material_override != original and floor.material_override.shader == preload("res://shaders/prototype_grid.gdshader"),"地面使用世界尺度网格")
	check(road.material_override.shader==floor.material_override.shader and road.material_override.get_shader_parameter("u_grid_size")==floor.material_override.get_shader_parameter("u_grid_size"),"道路与地形共用世界空间网格Shader和尺度")
	check(road.mesh==road_mesh and road.transform==road_pose and road.get_child_count()==0,"道路只换材质，不加厚、不新增碰撞或绘制层")
	check(scene_mesh == floor.mesh and shared.mesh == scene_mesh and scene_mesh.material == null,"共享Mesh资源未改写")
	check(rocks.visible and decor.visible and rocks.material_override != original,"MultiMesh岩块转换但不隐藏整个WorldDecor")
	check(body.collision_layer == 3 and not collision.disabled and enemy.velocity == Vector3(1,2,3),"碰撞层、碰撞启用与角色速度完全不变")
	check(rocks.multimesh == multimesh and multimesh.instance_count==2 and multimesh.get_instance_transform(0)==original_transform,"批量网格实例与变换不变（与该渲染器原读值对照）")
	if DisplayServer.get_name() != "headless":
		check(original_transform.origin==Vector3(3,0,-4),"实际图形渲染器保留指定批量变换")
	check(not flowers.visible and not pebbles.visible,"仅隐藏纯装饰并保留原隐藏值")
	check(enemy_mesh.material_override.albedo_color.r>0.8,"使用敌人语义组识别泰坦，不依赖enemy名字")
	check(shield_plate.material_override.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,"实体泥盾不会被旧版shield名字规则变成透明罩")
	check(player_body.material_override != player_gun.material_override,"玩家身体与武器功能明度分离")
	var crowd_ok := true
	for row in crowd:
		crowd_ok = crowd_ok and row.part.material_override==director.palette._mat_enemy_body and row.actor.transform==row.pose and row.actor.velocity==Vector3(1,0,2)
	check(crowd_ok,"100个受控角色转换显示不改变位置 / 速度（不是AI帧率测试）")
	check(warning._mesh.material_override==warning_fill and warning._border.material_override==warning_edge and shield.mesh.material_override==shield_material,"AttackArea填充 / 外沿与真实能量护盾保持原实现")
	check(camera.environment == director._studio and original_environment.ambient_light_energy==original_ambient,"独立相机环境覆盖，原环境资源不修改")
	check(not sun.visible and sun.light_energy == sun_energy and director._sun.visible,"中性灯替代世界灯但不改原灯能量")
	check(effect.style == 5 and not effect._sketch_rect.visible and not effect._sketch_copy.visible,"灰模暂绕过手绘，不丢风格选择")
	effect.set_style(4)
	check(not effect._overlay.visible,"灰模期间选其他风格仍不绘制全屏滤镜")
	var added := mesh(enemy,"LaterBodyPart")
	var added_original := added.material_override
	await frames(2)
	check(added.material_override != added_original,"后生成的角色部件在初始化后接入")
	var detached := mesh(enemy,"DetachedBodyPart")
	var detached_original := detached.material_override
	await frames(2)
	enemy.remove_child(detached)
	check(detached.material_override == detached_original,"离树但未释放的网格立即恢复，不能带覆盖到别处")
	detached.free()
	var edit := StandardMaterial3D.new()
	shared.material_override = edit
	var pending := mesh(enemy,"PendingBodyPart")
	var pending_original := pending.material_override
	director.deactivate()
	await frames(2)
	check(pending.material_override == pending_original,"关闭之后的旧队列不能重新施加灰模")
	check(floor.material_override==original and rocks.material_override==original and added.material_override==added_original,"原材质引用准确恢复，动态部件同样恢复")
	check(road.material_override==road_material,"道路原材质同样准确恢复")
	check(shared.material_override == edit,"不覆盖灰模期间外部设置的新材质")
	check(flowers.visible and not pebbles.visible and sun.visible and not hidden_sun.visible,"原本可见 / 隐藏状态准确恢复")
	check(camera.environment==original_environment and effect.style==4 and effect._overlay.visible,"原相机环境恢复，期间选择的新风格保留")
	check(director._overrides.is_empty() and director._cameras.is_empty(),"关闭清空引用缓存")
	for row in crowd: crowd_ok = crowd_ok and row.part.material_override==row.original
	check(crowd_ok,"100个受控角色材质引用全部恢复")
	key(KEY_F4)
	check(director.is_active,"真实F4开启")
	key(KEY_F4)
	check(not director.is_active,"真实F4关闭")
	await panel()
	effect.set_style(0)
	current_scene = null
	world.queue_free()
	await frames(2)

func panel() -> void:
	var defaults := Settings.load_values()
	var hash := FileAccess.get_sha256(Settings.PATH)
	key(KEY_F10)
	await frames(2)
	check(director._panel.opened and director.is_active and paused,"F10打开暂停与临时灰模预览")
	key(KEY_F4)
	check(director.is_active,"模态内F4不穿透改变显示状态")
	director._panel._fields.grid_size.value = 1.337
	check(director.parameters.grid_size==1.337 and director.parameters.line_width==defaults.line_width,"只改所编辑参数，不损失其他字段精度")
	check(director.palette._mat_ground.get_shader_parameter("u_grid_size")==1.337 and director._panel._status.text.begins_with("未保存") and FileAccess.get_sha256(Settings.PATH)==hash,"即时预览与未保存状态，不自动落盘")
	check(director.palette._mat_road.get_shader_parameter("u_grid_size")==1.337 and director.palette._mat_road.get_shader_parameter("u_major_grid_step")==defaults.major_grid_step,"F10尺度同步到道路，不维护第二套网格参数")
	director._panel._fields.show_dust.value = 1
	check(director.parameters.show_dust==1 and FileAccess.get_sha256(Settings.PATH)==hash,"F10中性扬尘开关即时预览但不自动保存")
	check(ProjectSettings.globalize_path("res://").replace("\\","/").contains("/tmp/project/"),"保存只操作隔离工程")
	if ProjectSettings.globalize_path("res://").replace("\\","/").contains("/tmp/project/"):
		director._panel._save()
		check(Settings.load_values().grid_size==1.337 and Settings.load_values().show_dust==1 and director._panel._status.text=="与项目默认一致","显式保存网格 / 扬尘并回读确认")
		director._panel._fields.grid_size.value = 2.0
		director._panel._reload()
		check(director.parameters.grid_size==1.337,"重读丢弃草稿")
		check(Settings.save_values(defaults)==OK,"隔离默认恢复")
		director._panel._reload()
	key(KEY_ESCAPE)
	check(not director._panel.opened and not paused and not director.is_active,"Esc只关F10并还原先前关闭状态")
	director.activate()
	key(KEY_F10)
	key(KEY_ESCAPE)
	check(director.is_active and not paused,"原本已开灰模则关闭面板仍保持灰模")
	director.deactivate()

func capture(label: String) -> Image:
	if DisplayServer.get_name()=="headless": return null
	await frames(8)
	var image := root.get_texture().get_image()
	check(image.save_png(Artifacts.ensure_dir("screenshots","greybox").path_join(label+".png"))==OK,"保存正式地图画面："+label)
	return image

func neutral(color: Color) -> bool:
	return is_equal_approx(color.r,color.g) and is_equal_approx(color.g,color.b) and color.r<=1.0

func fx_fixture() -> void:
	# 使用正式卫士、敌弹、钉弹和扬尘实现；仅固定机位、位置与模拟以重复看表现。
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	await frames(2)
	var floor := mesh(world,"TerrainMesh")
	(floor.mesh as BoxMesh).size = Vector3(14,0.15,14)
	floor.position.y = -0.075
	var road := mesh(world,"ValleyRoad_FxFixture")
	road.mesh = PlaneMesh.new()
	(road.mesh as PlaneMesh).size = Vector2(2.5,14)
	road.position.y = 0.025
	var camera := Camera3D.new()
	camera.environment = Environment.new()
	camera.environment.background_mode = Environment.BG_COLOR
	camera.environment.background_color = Color(0.3,0.3,0.3)
	camera.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	camera.environment.ambient_light_color = Color.WHITE
	camera.environment.ambient_light_energy = 0.8
	world.add_child(camera)
	camera.position = Vector3(2.5,2.5,5)
	camera.look_at(Vector3(0,0.9,0))
	camera.make_current()
	var player := CharacterBody3D.new()
	player.add_to_group("player")
	world.add_child(player)
	var wisp := Wisp.new()
	player.add_child(wisp)
	wisp.setup(player,camera)
	wisp.set_physics_process(false)
	wisp.position = Vector3(-0.9,1.5,0)
	var gameplay := [wisp.base_damage,wisp.fire_rate,wisp.attack_range,wisp.projectile_speed,wisp.ceasefire_min_enemies]
	var glow: Material = wisp._halo_ring.material_override
	var lens: Material = wisp._sensor_eye.material_override
	var plume: Material = wisp._left_plume.material_override
	var halo_mesh := wisp._halo_ring.mesh
	var bullet: Node3D = BulletScene.instantiate()
	world.add_child(bullet)
	bullet.position = Vector3(0.3,0.8,0)
	bullet.setup(Vector3.FORWARD,player,21.0,11.0,0.25,Color.MAGENTA)
	bullet.set_physics_process(false)
	var core := bullet.get_node("Core") as MeshInstance3D
	var aura := bullet.get_node("Aura") as MeshInstance3D
	var trail := bullet.get_node("Trail") as MeshInstance3D
	var bullet_glow := bullet.get_node("Glow") as OmniLight3D
	var bullet_core: Material = core.material_override
	var bullet_aura: Material = aura.material_override
	var bullet_pose := bullet.transform
	var target := Node3D.new()
	world.add_child(target)
	target.position = Vector3(0.6,1.3,-3)
	var dart := Wisp.WispDart.new()
	world.add_child(dart)
	dart.setup(Vector3(0.6,1.3,-0.6),target,9.0,42.0,Color.CYAN)
	dart.set_physics_process(false)
	var dart_original: Material = dart._mesh_inst.material_override
	var dust := Dust.spawn(world,Vector3(0.5,0,1.5),Vector3.UP,0.55)
	dust.set_process(false) # 只固定截图样本寿命；后面另验正式自动清理。
	var original_ramp: Gradient = dust._particles.color_ramp
	var original_colors := original_ramp.colors
	var dust_material: Material = dust._particles.mesh.material
	await capture("fx_art_before")
	director.activate()
	await frames(3)
	check(director._fx_kind(dart._mesh_inst)=="wisp_dart","独立内嵌钉弹按脚本身份接入，不依赖其默认节点名")
	check(core.material_override==director.palette._mat_projectile_core and neutral(core.material_override.albedo_color) and not core.material_override.emission_enabled,"敌弹浅灰弹芯不发光但保持可见")
	check(aura.material_override==director.palette._mat_projectile_rim and trail.material_override==director.palette._mat_projectile_trail,"敌弹外壳只画深色细外缘，拖尾中性化")
	check(not bullet_glow.visible and not wisp._light.visible and not dart._light.visible,"敌弹、玩家下的卫士与独立钉弹均不向地面投彩光")
	check(neutral(wisp._halo_ring.material_override.albedo_color) and neutral(wisp._sensor_eye.material_override.albedo_color) and not wisp._sensor_eye.material_override.emission_enabled,"卫士光环 / 透镜中性化且不产生HDR强光")
	check(wisp._left_plume.material_override==wisp._halo_ring.material_override and neutral(wisp._left_plume.material_override.albedo_color),"CPU尾焰与光环共用灰模副本，不遗漏粒子")
	check(dart._mesh_inst.material_override==director.palette._mat_projectile_core and dart._damage==9.0 and dart._speed==42.0,"钉弹只换显示，伤害 / 速度不变")
	check(bullet.damage==21.0 and bullet.speed==11.0 and bullet.turn_rate==0.25 and bullet.transform==bullet_pose,"敌弹伤害 / 速度 / 转向 / 位置不变")
	check(not dust._particles.visible and dust.is_processing() == false and dust._particles.mesh.material==dust_material,"扬尘默认只隐藏显示，不改透明材质或脚步逻辑")
	check(original_ramp.colors==original_colors and dust._particles.color_ramp!=original_ramp,"灰模扬尘使用独立色带，不污染原画共享资源")
	var source_count: int = director._wisp_materials.size()
	check(source_count<=6 and source_count>0,"卫士共享材质只建少量副本，不按每片装甲逐帧更新")
	var added_wisp := Wisp.new()
	player.add_child(added_wisp)
	added_wisp.setup(player,camera)
	added_wisp.set_physics_process(false)
	added_wisp.visible = false # 新生成测试样本不挤占主要截图。
	var added_dart := Wisp.WispDart.new()
	world.add_child(added_dart)
	added_dart.setup(Vector3(0,1,0),target,7.0,30.0,Color.CYAN)
	added_dart.set_physics_process(false)
	added_dart.visible = false
	await frames(3)
	check(neutral(added_wisp._halo_ring.material_override.albedo_color) and not added_wisp._light.visible and added_dart._mesh_inst.material_override==director.palette._mat_projectile_core and not added_dart._light.visible,"开启后新生卫士 / 内嵌钉弹自动接入，不遗漏局部灯与粒子")
	player.remove_child(added_wisp)
	world.remove_child(added_dart)
	check(director._wisp_materials.size()==source_count and added_wisp._halo_ring.material_override==added_wisp._glow_material and added_wisp._light.visible and added_dart._light.visible,"动态效果离树恢复并回收材质缓存，不随发射数量累积")
	added_wisp.free()
	added_dart.free()
	await capture("fx_greybox")
	var grey_glow: float = wisp._halo_ring.material_override.albedo_color.r
	var grey_lens: float = wisp._sensor_eye.material_override.albedo_color.r
	wisp.set_visual_preview(1)
	wisp._shot_flash = 1.0
	wisp._update_visual_state(0.0)
	var rotation: float = wisp._halo_ring.rotation.y
	wisp._update_idle_animation(0.1)
	await frames(3)
	check(wisp._halo_ring.material_override.albedo_color.r>grey_glow and wisp._sensor_eye.material_override.albedo_color.r>grey_lens,"超频状态仍用中性明度变化表达，不冻住状态表现")
	check(not wisp._light.visible and neutral(wisp._halo_ring.material_override.albedo_color) and wisp._halo_ring.rotation.y != rotation and wisp._halo_ring.mesh==halo_mesh,"开火更新不重新投彩光，光环动画与原网格保持")
	check(gameplay==[wisp.base_damage,wisp.fire_rate,wisp.attack_range,wisp.projectile_speed,wisp.ceasefire_min_enemies],"灰模不修改卫士伤害 / 射速 / 射程 / 弹速 / 停火阈值")
	# 真对象池脱离树与再次setup：恢复必须先于新一发重写原色，不能把灰模材质带回池。
	Pool.release("enemy_bullet",bullet)
	check(core.material_override==bullet_core and aura.material_override==bullet_aura and bullet_glow.visible,"敌弹回池立即恢复材质与灯光可见性")
	var reused: Node3D = Pool.acquire_scene("enemy_bullet",BulletScene)
	check(reused==bullet,"实际复用同一颗敌弹而非替代夹具")
	world.add_child(reused)
	reused.setup(Vector3.RIGHT,player,33.0,13.0,0.0,Color.YELLOW)
	reused.set_physics_process(false)
	await frames(3)
	check(core.material_override==director.palette._mat_projectile_core and not bullet_glow.visible and reused.damage==33.0,"池化后新颜色 / 新伤害setup仍被灰模显示接管，数值保留")
	var draft: Dictionary = director.parameters.duplicate(true)
	draft.show_dust = 1
	director.apply_parameters(draft)
	var neutral_ramp: Gradient = dust._particles.color_ramp
	check(dust._particles.visible and neutral(neutral_ramp.get_color(1)) and neutral_ramp.get_color(0).a==0.0 and neutral_ramp.get_color(3).a==0.0,"中性扬尘可即时打开，颜色中性且保留淡入淡出")
	var sprint := Dust.spawn(world,Vector3(0.2,0,1),Vector3.UP,0.55)
	await frames(2)
	check(sprint._particles.visible and neutral(sprint._particles.color_ramp.get_color(1)),"已开启扬尘时，后生粒子同样中性化")
	await capture("fx_dust_preview")
	var recent_color: Color = glow.albedo_color
	var recent_energy: float = wisp._light.light_energy
	director.deactivate()
	check(wisp._halo_ring.material_override==glow and wisp._sensor_eye.material_override==lens and wisp._left_plume.material_override==plume and glow.albedo_color==recent_color,"退出恢复原材质引用，保留期间最新超频表现，不回退状态")
	check(wisp._light.visible and wisp._light.light_energy==recent_energy and bullet_glow.visible and dart._light.visible,"退出恢复局部灯可见性，不回退期间更新的灯光能量")
	check(dust._particles.visible and dust._particles.color_ramp==original_ramp and original_ramp.colors==original_colors,"仍存活扬尘的原可见性 / 色带准确恢复")
	check(core.material_override==bullet_core and bullet_aura==aura.material_override and bullet_glow.light_color==Color.YELLOW and dart._mesh_inst.material_override==dart_original,"敌弹与钉弹恢复原画，池化后的最新颜色保留")
	check(director._wisp_materials.is_empty() and director._dust.is_empty(),"关闭清空新增效果缓存，不留死引用")
	await capture("fx_art_restored")
	director.apply_parameters(Settings.load_values())
	director.activate()
	var transient := Dust.spawn(world,Vector3.ZERO,Vector3.UP,0.35)
	var lifespan: WeakRef = weakref(transient)
	await frames(65)
	check(lifespan.get_ref()==null,"隐藏的正式扬尘仍按原寿命自动销毁，不冻结脚本或堆积节点")
	director.deactivate()
	current_scene = null
	world.queue_free()
	await frames(3)

func runtime() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	await frames(25)
	world = current_scene
	root.get_node("GameFlow")._resume_play()
	world.get_node("Enemies/WaveDirector").process_mode = Node.PROCESS_MODE_DISABLED
	var player: Node3D = world.get_node("PlayerSpawner").spawn_player()
	player.set_physics_process(false)
	player._wisp.set_physics_process(false)
	var y := Terrain.height_at(0,24)
	player.position = Vector3(0,y+1,24)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(12,y+11,29)
	camera.look_at(Vector3(0,y+2,10))
	camera.make_current()
	var weather := world.get_node("WeatherEnvironment/WeatherSystem")
	var sky := world.get_node("WeatherEnvironment/Sky3D")
	var time := sky.get_node("TimeOfDay")
	var original_environment: Environment = sky.environment
	var original_camera_environment := camera.environment
	var rain_mode: Node.ProcessMode = weather.process_mode
	var time_mode: Node.ProcessMode = time.process_mode
	var rain_visibility: bool = weather.visible
	var decor := world.find_child("WorldDecor",true,false)
	var rocks := decor.get_node("FieldBoulders/BoulderBatch")
	var original_rocks: Material = rocks.material_override
	var grass := world.get_node("Grass")
	var grass_visible: bool = grass.visible
	var meadow := world.find_child("MeadowColonies",true,false) as Node3D
	var shrubs := world.find_child("MeadowShrubs",true,false) as Node3D
	var fog_mesh: MeshInstance3D = sky.get_node("SkyDome").fog_mesh
	var meadow_visible := meadow.visible
	var shrubs_visible := shrubs.visible
	var fog_visible := fog_mesh.visible
	var original_rain_enabled: bool = weather.rain_enabled
	var roads := world.find_children("ValleyRoad_*","MeshInstance3D",true,false)
	var road_snapshots: Array = []
	for node in roads:
		road_snapshots.append({"node":node,"mesh":node.mesh,"pose":node.transform,"material":node.material_override})
	check(not roads.is_empty(),"正式圣所找到真实程序道路，不只验证命名夹具")
	var area := preload("res://scripts/enemy_attack_area.gd").new()
	world.add_child(area)
	await physics_frame
	area.prepare(Transform3D(Basis(),Vector3(0,Terrain.height_at(0,15)+0.1,15)),{"kind":"circle","radius":6.0},30)
	area.set_progress(0.55)
	area.set_physics_process(false)
	var fill_material: Material = area._mesh.material_override
	var border_material: Material = area._border.material_override
	root.get_node("PostProcess").set_style(5)
	await capture("art_before")
	director.activate()
	await frames(5)
	var clock: float = sky.current_time
	var rain: float = weather._rain_intensity
	await frames(120)
	check(sky.current_time==clock and weather._rain_intensity==rain and weather.rain_enabled==original_rain_enabled,"持续运行不被天气重写，天气配置未被禁用")
	check(weather.process_mode==Node.PROCESS_MODE_DISABLED and time.process_mode==Node.PROCESS_MODE_DISABLED and not weather.visible,"天气 / 天空控制器临时冻结并隐藏天气几何")
	check(sky.environment==original_environment and camera.environment==director._studio,"正式Sky3D环境引用不变，只有相机覆盖")
	check(not grass.visible and rocks.is_visible_in_tree() and rocks.material_override != original_rocks,"正式场景草隐藏，带碰撞岩块依然可见并使用灰模")
	check(not meadow.visible and not shrubs.visible and not fog_mesh.visible,"缓存静态草丛与SkyDome雾幕也临时隐藏")
	var timeline := world.find_child("WeatherTimeline",true,false)
	check(timeline != null and timeline.process_mode != Node.PROCESS_MODE_DISABLED,"灰模不禁用同时承载敌人调试的预报脚本")
	var enemies_paused: bool = timeline._enemies_paused
	key(KEY_F1)
	check(timeline._enemies_paused != enemies_paused,"灰模期间真实F1仍走原敌人调试入口")
	key(KEY_F1)
	check(timeline._enemies_paused == enemies_paused,"F1恢复原调试状态，灰模未接管敌人")
	check(area._mesh.material_override==fill_material and area._border.material_override==border_material and area.progress==0.55 and area.damage==30,"正式预警完整边界 / 填充 / 倒计时 / 伤害字段不变")
	var roads_ok := true
	for row in road_snapshots:
		roads_ok = roads_ok and row.node.material_override==director.palette._mat_road and row.node.mesh==row.mesh and row.node.transform==row.pose and row.node.get_child_count()==0
	check(roads_ok,"正式道路全部接入同源格线，网格 / 高度 / 变换不变且不新增碰撞")
	for _i in 4:
		await physics_frame
		player.velocity = Vector3(0,-1,0)
		player.move_and_slide()
	check(player.is_on_floor(),"灰模正式玩家仍能在原地形碰撞上落地")
	if player.is_on_floor():
		var dust_count := get_nodes_in_group("ground_dust").size()
		player._on_footstep(false)
		player._on_footstep(true)
		await frames(2)
		var samples := get_nodes_in_group("ground_dust")
		check(samples.size()==dust_count+2,"灰模保留真实行走 / 冲刺脚步反馈入口与生成逻辑")
		if samples.size()>=dust_count+2:
			var walk: Node3D = samples[dust_count]
			var sprint: Node3D = samples[dust_count+1]
			check(not walk._particles.visible and not sprint._particles.visible and sprint._particles.scale_amount_max>walk._particles.scale_amount_max,"真实行走 / 冲刺扬尘都只隐藏显示，原强度差异保持")
	await capture("greybox")
	key(KEY_F9)
	check(not root.get_node("PostProcess")._sketch_panel.opened,"灰模时不打开看不到手绘效果的F9面板")
	# 动态正式敌人；只核对渲染接入，不启动战斗AI。
	var boss: CharacterBody3D = world.get_node("Enemies/EnemySpawner").spawn_boss("sediment_titan",Vector3(0,Terrain.height_at(0,5),5))
	boss.ai_enabled = false
	check(boss.prepare_sparring_phase("front"),"动态泰坦先进入可见稳定姿态")
	boss.set_physics_process(false)
	await frames(5)
	check(boss.has_mud_shield and boss.core_mesh.material_override != director.palette._mat_enemy_body,"泰坦泥盾状态保留，弱点晶体不改敌人橙色")
	check(boss.torso_pivot.get_node("MainTorso").material_override==director.palette._mat_enemy_body,"正式动态泰坦体块接入灰模")
	await capture("greybox_boss")
	var replacement := Camera3D.new()
	world.add_child(replacement)
	replacement.transform = camera.transform
	replacement.make_current()
	await frames(3)
	check(replacement.environment==director._studio,"运行中更换相机也使用独立灰模环境")
	director._panel.open()
	await capture("panel")
	director._panel.close()
	director.deactivate()
	check(camera.environment==original_camera_environment and replacement.environment==null and sky.environment==original_environment,"原相机 / 新相机环境引用准确恢复")
	check(weather.process_mode==rain_mode and time.process_mode==time_mode and weather.visible==rain_visibility,"天气处理与可见性恢复原状态而不是套默认")
	check(grass.visible==grass_visible and rocks.material_override==original_rocks,"正式装饰和岩块材质恢复")
	check(meadow.visible==meadow_visible and shrubs.visible==shrubs_visible and fog_mesh.visible==fog_visible,"缓存静态草丛与独立雾幕原可见性恢复")
	for row in road_snapshots: roads_ok = roads_ok and row.node.material_override==row.material
	check(roads_ok,"正式道路退出灰模后恢复原材质")
	await frames(6)
	check(sky.current_time != clock,"退出灰模后天空时间重新推进")
	await capture("art_restored")
	# 开启状态跨场景继续；离树节点不能遗留覆盖或暂停。
	director.activate()
	director._panel.open()
	var next := Node3D.new()
	root.add_child(next)
	current_scene = next
	world.queue_free()
	world = next
	await frames(4)
	check(director.is_active and director._scene==next and not director._panel.opened and not paused,"灰模跨场景接入，F10不遗留暂停或旧场景引用")
	var next_mesh := mesh(next,"NextTerrain")
	var original := next_mesh.material_override
	await frames(3)
	check(next_mesh.material_override!=original,"切图后的新增几何同样接入")
	director.deactivate()
	check(next_mesh.material_override==original,"新场景关闭后恢复")
