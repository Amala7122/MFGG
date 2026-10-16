extends SceneTree
const Lab := preload("res://prototypes/navigation_lab/navigation_lab.tscn")
const Query := preload("res://scripts/spatial_query.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var lab := Lab.instantiate()
	lab.count = 12
	lab.full_area = false
	root.add_child(lab)
	current_scene = lab
	while not lab.ready_for_test: await process_frame
	for frame in range(60): await physics_frame
	for actor in lab.actors: actor.running = false
	Query.debug = true
	for actor in lab.actors:
		if actor.name not in ["N02", "N03", "N09"]: continue
		print("[诊断] ", actor.name, " ", actor.position, " -> ", lab.target.position)
		var route: Dictionary = actor.steering.spatial._walking(actor.global_position, Query.body_on_floor(actor, Query.support(lab.target)))
		print("[诊断结果] ", actor.name, " ", route)
	Query.debug = false
	lab.queue_free()
	await process_frame
	quit()
