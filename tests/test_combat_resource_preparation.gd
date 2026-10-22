extends SceneTree
const Preparation := preload("res://scripts/combat_resource_preparation.gd")
var failed := false
var actors_added := 0
var particles_added := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, text: String) -> void:
	if not condition: failed = true; push_error(text)

func _run() -> void:
	for _frame in range(3): await process_frame
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var floor_body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(30, 1, 30)
	collision.shape = shape
	floor_body.add_child(collision)
	floor_body.position.y = -0.5
	scene.add_child(floor_body)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.make_current()
	await physics_frame
	paused = true
	var orphan_count := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	node_added.connect(func(node: Node):
		if node is CharacterBody3D: actors_added += 1
		if node is CPUParticles3D: particles_added += 1)
	seed(79191)
	if DisplayServer.get_name() == "headless":
		_check(not Preparation.needed(root, "res://scenes/sanctum_main.tscn"), "无头不等待渲染完成信号")
	else:
		_check(Preparation.needed(root, "res://scenes/sanctum_main.tscn"), "首次配置需要准备")
		await Preparation.warmup(root, "res://scenes/sanctum_main.tscn")
		var actual_random := randf()
		# CPUParticles3D原生构造器本身抽取种子；对照相同数量的原生分配，
		# 检查样本没有额外执行战斗选招／随机差异，而非假设所有引擎分配无副作用。
		seed(79191)
		for _index in particles_added:
			var control := CPUParticles3D.new()
			control.free()
		_check(randf() == actual_random, "除原生粒子取种子外，准备没有执行额外战斗随机逻辑")
		_check(Preparation.runs == 1 and Preparation.last_resource_count > 0, "实际绘制后保存有限资源集")
		_check(actors_added == 0, "建模构造器从未入树，没有注册战斗身体")
		_check(not Preparation.needed(root, "res://scenes/sanctum_main.tscn"), "同配置重开复用准备结果")
		var count := Preparation.last_resource_count
		await Preparation.warmup(root, "res://scenes/sanctum_main.tscn")
		_check(Preparation.runs == 1 and Preparation.last_resource_count == count, "重复调用不会累积样本或资源")
		var previous := root.msaa_3d
		root.msaa_3d = Viewport.MSAA_2X if previous != Viewport.MSAA_2X else Viewport.MSAA_DISABLED
		_check(Preparation.needed(root, "res://scenes/sanctum_main.tscn"), "画质管线特性改变后重新准备")
		root.msaa_3d = previous
		Preparation._signature = "force-test-rebuild"
		await Preparation.warmup(root, "res://scenes/sanctum_main.tscn")
		_check(Preparation.runs == 2 and Preparation.last_resource_count == count, "下一套替换前套，缓存不随准备次数增长")
	_check(root.find_children("CombatResourcePreparation", "", true, false).is_empty(), "准备后不遗留显示场景")
	for group: String in ["enemies", "boss", "enemy_projectiles", "enemy_hazards", "enemy_attack_debug_areas", "combat_dangers"]:
		_check(get_nodes_in_group(group).is_empty(), "准备不遗留战斗注册：" + group)
	_check(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == orphan_count, "离树构造器与预创建攻击区完整释放")
	_check(paused, "准备函数保持调用方暂停状态")
	print("[战场渲染准备] ", "FAIL" if failed else "PASS", " resources=", Preparation.last_resource_count, " ms=", Preparation.last_ms)
	quit(1 if failed else 0)
