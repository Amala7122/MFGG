extends SceneTree
## Test the cannon-fodder architecture, not simply a reduced render detail level.
## No game scene and no external player interaction are required.
const Actor := preload("res://scripts/prototypes/procedural_mud_golem.gd")
const Batch := preload("res://scripts/prototypes/mud_golem_render_batch.gd")
const Melee := preload("res://scripts/prototypes/mud_golem_melee.gd")
const AttackArea := preload("res://scripts/enemy_attack_area.gd")
var _failures := 0


func _initialize() -> void:
	call_deferred("_check")


func _check() -> void:
	var arena := Node3D.new()
	arena.name = "MudHordeTestWorld"
	root.add_child(arena)
	current_scene = arena

	var actors: Array[CharacterBody3D] = []
	for index in 14:
		var enemy := Actor.new()
		enemy.name = "Mud_%d" % index
		enemy.ai_enabled = false
		enemy.position = Vector3(float(index) * 0.16, 2.0, -1.0)
		enemy.set_physics_process(false)
		arena.add_child(enemy)
		actors.append(enemy)
	var manager := arena.get_node_or_null("MudGolemRenderBatch") as MudGolemRenderBatch
	_expect(manager != null, "a single scene-owned renderer exists")
	if manager == null:
		quit(1)
		return
	_expect(manager.actor_count() == 14, "all actors register without duplicate renderer nodes")
	for enemy in actors:
		_expect(enemy.find_children("*", "MeshInstance3D", true, false).is_empty(),
			"actors own only pose anchors, no individual mesh draws")
		_expect(_descendants(enemy) <= 16, "character body keeps a small scene tree")
	manager._process(0.016)
	_expect(manager.batch_count() == 1, "nearby horde shares one 24m spatial batch")
	_expect(manager.expected_draw_groups() == 4, "one visible cell has four batched mesh groups")
	var fragments: Array[Dictionary] = manager.debris_parts(actors[0])
	_expect(fragments.size() == 6, "original torso/core/fists/legs can still scatter on death")
	for part in fragments:
		_expect((part.mesh as Mesh).get_surface_count() > 0, "death fragment preserves genuine geometry")
	var torso_group := arena.get_node("MudGolemRenderBatch/MudGolemCell_0_-1/Mud_0") as MultiMeshInstance3D
	if torso_group != null:
		_expect(torso_group.multimesh.visible_instance_count == 14,
			"batched renderer draws 14 independent torsos")
		_expect(torso_group.multimesh.get_instance_transform(0).origin.is_equal_approx(actors[0].torso_pivot.global_position),
			"submitted visual pose follows this actor's true world transform")
	# New cells must not duplicate combat actors or affect their world transform.
	actors[0].global_position = Vector3(65.0, 2.0, -1.0)
	manager._process(0.016)
	_expect(manager.actor_count() == 14, "cross-cell moves retain 14 combat bodies")
	_expect(manager.batch_count() == 2, "moving across cells allocates only another render group")
	_expect(manager.expected_draw_groups() == 8, "only occupied cells submit geometry")
	var shape := {"kind": "sector", "radius": 2.2, "angle": 120.0, "height": 1.4, "ground_effect": false}
	var pose := Transform3D.IDENTITY
	var existing := AttackArea.new()
	arena.add_child(existing)
	existing.prepare(pose, shape, 7.5, 0.5)
	var lightweight := Melee.new()
	lightweight.setup(actors[0])
	lightweight.prepare(pose, shape, 7.5, 0.5)
	for x in range(-6, 7):
		for z in range(-6, 7):
			var point := Vector3(float(x) * 0.4, 0.0, float(z) * 0.4)
			_expect(existing.can_reach(point) == lightweight.can_reach(point),
				"lightweight sector keeps the old spatial reach rule at " + str(point))
	lightweight.lock()
	_expect(lightweight.strike(), "locked strike happens once")
	_expect(not lightweight.strike(), "repeated strike cannot deal duplicate damage")
	lightweight.recover()
	lightweight.cancel()
	_expect(lightweight.phase == Melee.Phase.IDLE and not lightweight.visible,
		"cancel resets the attack without any warning mesh")

	actors[1].queue_free()
	await process_frame
	manager._process(0.016)
	_expect(manager.actor_count() == 13, "removed enemy exits shared batch")
	arena.queue_free()
	await process_frame
	print("[Mud horde architecture] ", "PASS" if _failures == 0 else "FAIL", " failures=", _failures)
	quit(0 if _failures == 0 else 1)


func _descendants(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		count += 1 + _descendants(child)
	return count


func _expect(ok: bool, reason: String) -> void:
	if not ok:
		_failures += 1
		push_error("[Mud horde] " + reason)
