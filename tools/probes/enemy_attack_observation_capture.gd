extends SceneTree
## 隔离图形入口：实际面板与实际单招，不保存草稿或项目默认。
const Lab := preload("res://prototypes/combat_lab/combat_lab.tscn")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failed := false

func _initialize() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for i in count: await physics_frame
func capture(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var path := Artifacts.ensure_dir("screenshots").path_join(name+".png")
	var error := root.get_texture().get_image().save_png(path)
	if error != OK: failed = true; push_error("截图失败："+path)
	print("截图：", path)

func _run() -> void:
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1280, 720)
	await frames(4)
	var lab := Lab.instantiate()
	root.add_child(lab)
	current_scene = lab
	await frames(8)
	lab._show_enemy_tuning("VisualPrismSpider")
	lab._tuning_panel._tabs.current_tab = 2
	await frames(4)
	await capture("01_spider_unified_attack_parameters")
	lab._show_enemy_tuning("PrototypeSedimentTitan")
	lab._tuning_panel._tabs.current_tab = 7
	await frames(4)
	await capture("02_titan_exclusive_parameters")
	for id: String in ["PrototypeMudGolem", "VisualChargeBeetle", "VisualBurstCrawler", "PrototypeFastBeast", "PrototypeHornet", "PrototypeSedimentTitan"]:
		var values := Tuning.defaults(id)
		values.body_size = 1.5
		values.variation_enabled = false
		values.crowd_enabled = false
		await lab.observe_draft(id, values)
		lab._attack_observer._framing.select(1)
		lab._attack_observer.frame_study()
		await frames(18)
		paused = true
		await capture("03_"+id+"_windup")
		paused = false
		await frames(65)
		paused = true
		await capture("04_"+id+"_trajectory")
		lab._show_configuration()
	paused = false
	lab.queue_free()
	await frames(2)
	quit(1 if failed else 0)
