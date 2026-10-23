extends SceneTree
const Catalog := preload("res://scripts/enemies/creature_catalog.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Flow := preload("res://scripts/game_flow.gd")
var failed := false
var world: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for frame in range(3):
		await process_frame
	Flow.instance.state = Flow.State.PLAYING
	paused = false
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var floor := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(50, 1, 50)
	collision.shape = box
	floor.add_child(collision)
	floor.position.y = -0.5
	world.add_child(floor)
	for id: String in Catalog.SPECIES:
		var record: Dictionary = Catalog.SPECIES[id]
		var enemy: CharacterBody3D = record.scene.instantiate()
		var values := Tuning.defaults(record.profile)
		enemy.set_meta(&"enemy_tuning", values)
		enemy.set_meta(&"crowd_uniform", true)
		enemy.ai_enabled = false
		enemy.position.y = 3.0
		world.add_child(enemy)
		await physics_frame
		# 节点式宿主保留覆盖材质断言；批量渲染宿主没有私有网格节点，
		# 改为检查它真正提交给 MultiMesh 的闪红强度与暂停/到期语义。
		var flash := enemy.get_node_or_null("EnemyHitFlash")
		if flash != null:
			await _check_overlay(enemy, flash, values, id)
		elif enemy.has_method("visual_flash_strength"):
			await _check_batched(enemy, values, id)
		else:
			_check(false, id + " 缺少可观察的受击闪光实现")
		enemy.set_meta(&"experiment_invincible", true)
		enemy.take_damage(1000000.0)
		_check(enemy.health == 1.0 and not enemy.is_queued_for_deletion(), id + " 实验场敌人不死保持生命1")
		if flash != null:
			flash.clear()
		enemy.take_damage(2.0)
		_check(enemy.health == 1.0 and _flash_active(enemy, flash), id + " 生命1仍可重复观察受击闪红")
		_check(get_nodes_in_group("enemy_death_effect").is_empty(), id + " 实验不死不产生死亡演出或结束回合")
		enemy.queue_free()
		await process_frame
	current_scene = null
	world.queue_free()
	await process_frame
	await create_timer(0.5).timeout
	Flow.instance.state = Flow.State.MENU
	preload("res://scripts/object_pool.gd").clear_all()
	print("[Enemy red hit flash] ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)


func _check_overlay(enemy: CharacterBody3D, flash: Node, values: Dictionary, id: String) -> void:
	var parts: Array = flash._parts
	_check(not parts.is_empty(), id + " 受击缓存覆盖模型")
	var part := parts[0] as MeshInstance3D
	var original := part.material_overlay
	var base_material := part.get_active_material(0)
	enemy.take_damage(2.0)
	_check(flash.remaining > 0.0 and part.material_overlay != original, id + " 命中立即使用红色叠层")
	_check(part.material_overlay.albedo_color.r > 0.9 and part.material_overlay.albedo_color.g < 0.1, id + " 实际闪红而不是变亮原色")
	_check(part.get_active_material(0) == base_material, id + " 不修改共享基础材质")
	for frame in range(4):
		await process_frame
	enemy.take_damage(2.0)
	_check(flash.remaining >= float(values.hit_flash_duration) - 0.001, id + " 连续命中刷新时长")
	paused = true
	var before: float = flash.remaining
	for frame in range(3):
		await process_frame
	_check(is_equal_approx(flash.remaining, before), id + " 暂停冻结闪红时长")
	paused = false
	for frame in range(20):
		await process_frame
	_check(flash.remaining <= 0.0 and part.material_overlay == original, id + " 到时恢复原叠层")


func _check_batched(enemy: CharacterBody3D, values: Dictionary, id: String) -> void:
	_check(float(enemy.call("visual_flash_strength")) <= 0.0, id + " 初始不闪红")
	enemy.take_damage(2.0)
	_check(float(enemy.call("visual_flash_strength")) > 0.0, id + " 命中后提交闪红强度")
	paused = true
	for frame in range(3):
		await process_frame
	_check(float(enemy.call("visual_flash_strength")) > 0.0, id + " 暂停冻结闪红强度")
	paused = false
	await create_timer(float(values.hit_flash_duration) + 0.2).timeout
	_check(float(enemy.call("visual_flash_strength")) <= 0.0, id + " 到时停止提交闪红")


func _flash_active(enemy: Node, flash: Node) -> bool:
	if flash != null:
		return float(flash.remaining) > 0.0
	return float(enemy.call("visual_flash_strength")) > 0.0


func _check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error(message)
