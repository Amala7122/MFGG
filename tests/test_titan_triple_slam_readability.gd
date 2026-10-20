extends "res://tests/test_titan_followup.gd"
## 图形验证完整危险面从出现即明确、外部不染色；无头仍检查复用/清理契约。
const Area := preload("res://scripts/enemy_attack_area.gd")

func picture() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func difference(a: Image, b: Image, point: Vector3, camera: Camera3D) -> float:
	var pixel: Vector2 = root.get_stretch_transform()*camera.unproject_position(point)
	var total := 0.0
	for x in range(int(pixel.x)-2,int(pixel.x)+3):
		for y in range(int(pixel.y)-2,int(pixel.y)+3):
			var first := a.get_pixel(x,y)
			var second := b.get_pixel(x,y)
			total += Vector3(first.r-second.r,first.g-second.g,first.b-second.b).length()
	return total/25.0

func _run() -> void:
	root.get_node("GameFlow").set_meta(&"sparring_session_active",true)
	await setup("rage")
	player.set_physics_process(false)
	player.visible = false
	boss.visual_root.visible = false
	boss.set_physics_process(false)
	check(boss.trigger_triple_slam_attack(),"真实三线重击开始")
	boss.set_physics_process(false)
	var areas: Array = boss._rage_director.areas
	check(areas.size()==3,"三线显示使用三个真实危险区域")
	var spread: float = deg_to_rad(float(boss._rage_director.triple_snapshot.spread))
	var expected_width: float = areas[0].shape.width
	for area: Node3D in areas:
		check(area._material.get_shader_parameter("solid_footprint")==true,"三线从出现即用完整危险面")
		check(area.is_visible_in_tree(),"像素检查中的真实预警未被父节点隐藏")
	if DisplayServer.get_name() != "headless":
		root.get_node("PostProcess").set_style(0)
		# 本项量地面像素；准星/血条否则恰好盖住中心点与远端外部点。
		for layer: Node in root.find_children("*","CanvasLayer",true,false): layer.hide()
		var ground := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(150,150)
		ground.mesh = plane
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ground.material_override = material
		world.add_child(ground)
		var camera := Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 38
		camera.position = Vector3(0,45,-12)
		world.add_child(camera)
		camera.look_at(Vector3(0,0,-12),Vector3.FORWARD)
		camera.make_current()
		var last_clear: Image
		for color: Color in [Color(.15,.24,.12),Color(.68,.50,.29)]:
			material.albedo_color = color
			for area: Node3D in areas: area.visible = false
			var clear := await picture()
			last_clear = clear
			for area: Node3D in areas: area.visible = true
			for area: Node3D in areas: area.set_progress(0.0)
			for area: Node3D in areas: area._material.set_shader_parameter("solid_footprint",false)
			var old_image := await picture()
			var old_outer := difference(clear,old_image,Vector3(0,.12,-22),camera)
			for area: Node3D in areas: area._material.set_shader_parameter("solid_footprint",true)
			for progress: float in [0.0,.5,.95]:
				for area: Node3D in areas: area.set_progress(progress)
				var image := await picture()
				check(difference(clear,image,Vector3(0,.12,-22),camera)>old_outer*1.8,"远端危险面比旧微弱填充明确；真实旧材质作为负对照")
				var minimum := 10.0
				for distance: float in [4.0,12.0,20.0]:
					for slot: float in [-1.0,0.0,1.0]:
						var p := Vector3(sin(slot*spread)*distance,.12,-cos(slot*spread)*distance)
						var delta := difference(clear,image,p,camera)
						minimum = minf(minimum,delta)
						check(delta>.20,"所有阶段近中远完整危险区与背景有明显差别，不能留暗外圈")
				for gap_distance: float in [8.0,12.0,20.0]:
					for side: float in [-1.0,1.0]:
						var p := Vector3(sin(side*spread*.5)*gap_distance,.12,-cos(spread*.5)*gap_distance)
						check(difference(clear,image,p,camera)<.01,"展开缝隙保持原地面，不被任意一条涂成危险")
				for point: Vector3 in [Vector3(0,.12,-2),Vector3(sin(spread*.5)*4,.12,-cos(spread*.5)*4)]:
					check(difference(clear,image,point,camera)>.20,"近处交叠仍完整标为危险，不出现假缝隙")
				results.append({"ground":str(color),"progress":progress,"minimum_inside_difference":minimum})
				check(image.save_png(Artifacts.ensure_dir("screenshots","triple_slam_readability").path_join(str(results.size())+".png"))==OK,"危险区测试画面保存成功")
		for area: Node3D in areas: area.recover()
		var removed := await picture()
		check(difference(removed,last_clear,Vector3(0,.12,-12),camera)<.01,"回收后恢复原地面，没有延迟残影")
	# 三线命中不保留地面标记污染下一招。
	var effect: Node3D = preload("res://scripts/prototypes/titan_melee_effect.gd").spawn(world,areas[1].global_transform,{"kind":"rect","offset":0.0,"width":expected_width,"length":24.0,"compact_impact":true,"surface":areas[1].get_surface()},1.65,false)
	check(not effect._trace.visible and effect.lifetime<=.18,"命中后不保留三道残影")
	await frames(15)
	check(not is_instance_valid(effect),"短促命中效果完整回收")
	for area: Node3D in areas: area.cancel()
	check(areas_hidden(areas),"取消立即关闭全部危险面")
	areas[0].prepare(Transform3D.IDENTITY,{"kind":"circle","radius":4.0},35.0)
	check(areas[0]._material.get_shader_parameter("solid_footprint")==false and (areas[0]._border.material_override as ShaderMaterial).get_shader_parameter("solid_footprint")==false,"普通预警复用时恢复旧显示，不能污染其他敌人")
	var file := FileAccess.open(Artifacts.ensure_dir("reports","triple_slam_readability").path_join("result.json"),FileAccess.WRITE)
	if file == null:
		push_error("危险面验收报告保存失败")
		quit(1)
		return
	file.store_string(JSON.stringify({"trials":results,"failures":failures},"\t"))
	file.close()
	await dispose()
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	root.get_node("GameFlow").remove_meta(&"sparring_session_active")
	quit(1 if failures else 0)

func areas_hidden(areas: Array) -> bool:
	for area: Node3D in areas:
		if area.visible: return false
	return true
