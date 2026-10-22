extends SceneTree
## Same-step exact support cache: no spatial tolerance, no moving collider reuse.
const Query := preload("res://scripts/spatial_query.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var ground := BoxShape3D.new()
	ground.size = Vector3(20.0, 1.0, 20.0)
	floor_shape.shape = ground
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -0.5, 0.0)
	var target := CharacterBody3D.new()
	var target_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 2.0
	target_shape.shape = capsule
	target.add_child(target_shape)
	root.add_child(target)
	target.global_position = Vector3(0.0, 1.0, 0.0)
	await physics_frame
	await physics_frame
	Query.support_cache_enabled = true
	Query.reset_support_cache_counters()
	var a: Dictionary = Query.support(target, false, true)
	var b: Dictionary = Query.support(target, true, true)
	_check(not a.is_empty() and b.position == a.position, "exact same-step cache preserves contact")
	_check(Query.support_cache_misses == 1 and Query.support_cache_hits == 1, "identical target support queried once")
	_check(not Query._last_support.get(target.get_instance_id(), {}).is_empty(), "remember=true after remember=false still records support")
	target.global_position += Vector3(1.0, 0.0, 0.0)
	Query.support(target, true, true)
	_check(Query.support_cache_misses == 2, "moving body invalidates even within same physics step")
	Destruction.geometry_changed()
	Query.support(target, true, true)
	_check(Query.support_cache_misses == 3, "world geometry revision invalidates")
	floor_body.global_position += Vector3(0.0, 0.1, 0.0)
	Query.support(target, true, true)
	_check(Query.support_cache_misses == 4, "supporting static collider movement invalidates")
	await physics_frame
	Query.support(target, true, true)
	_check(Query.support_cache_misses == 5, "next physics step invalidates")
	Query.support_cache_enabled = false
	Query.support(target, true, true)
	_check(Query.support_cache_hits == 1, "disabled mode bypasses reuse")
	Query.support_cache_enabled = true
	Query.forget(target)
	_check(not target.has_meta(Query.SUPPORT_CACHE_META), "forget removes cached entry")
	target.queue_free()
	floor_body.queue_free()
	await process_frame
	print("[支撑查询精确复用] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)

func _check(ok: bool, label: String) -> void:
	if not ok:
		failed = true
		push_error(label)
