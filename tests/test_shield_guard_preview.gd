extends SceneTree
## 盾卫插盾姿态预览（视觉台角色）回归。
##
## 【这条测试防的是什么】视觉台的 GALLERY 是"新增角色只登记一行"的入口，
## 登记错了不会有任何报错，只会表现为"按 D 轮到它时是白盒子/悬空/盾散在一边"。
## 而 `test_enemy_visual_lab.gd` 需要渲染、headless 跑不了，所以这里补一条
## 纯 headless 的守卫，钉住三件曾经真的做错过的事：
##   1. **必须走正式生成器**（否则护甲色是白的、体型没缩放、剖面没接上）；
##   2. **脚要落在挂点原点**（生成器把原点放在胶囊中心，不处理就是悬空）；
##   3. **盾要长在身上**（骨架不被摆姿势时，盾面会散落在身体外）。
const PreviewScene: PackedScene = preload("res://prototypes/visual_lab/shield_guard_visual.tscn")
const ConfigUtil := preload("res://scripts/game_config.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var root_node := Node3D.new()
	root_node.name = "PreviewWorld"
	root.add_child(root_node)
	current_scene = root_node

	var subject := PreviewScene.instantiate() as Node3D
	root_node.add_child(subject)
	for _frame in range(6):
		await process_frame

	var enemy := _find_enemy(subject)
	_check(enemy != null, "预览角色生成了敌人")
	if enemy == null:
		_finish(root_node)
		return

	# 1. 走的是正式生成器 / 图鉴条目。
	var expected := _roster_entry()
	_check(not expected.is_empty(), "图鉴里有 L3ShieldGuard")
	_check(is_equal_approx(enemy.scale.y, float(expected.get("scale", 0.0))),
		"体型来自图鉴（%.2f）" % enemy.scale.y)
	var armor: Variant = enemy.get("_armor_color")
	_check(armor is Color and not (armor as Color).is_equal_approx(Color.WHITE),
		"护甲色来自图鉴而不是默认白（%s）" % str(armor))
	_check(enemy.get("_shield_pivot") != null, "盾被真建出来了（ShieldPivot）")

	# 2. 脚落在挂点原点附近，不是悬在半空。
	#    生成器把原点放在**胶囊中心**，所以"落位对不对"要看脚，而不是看原点数值。
	var collision := enemy.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var half := 0.85 * enemy.scale.y
	if collision != null and collision.shape is CapsuleShape3D:
		half = (collision.shape as CapsuleShape3D).height * 0.5 * enemy.scale.y
	var feet_y := enemy.position.y - half
	_check(absf(feet_y) < 0.08, "脚落在挂点原点（脚高 %.2f，原点 %.2f）" % [feet_y, enemy.position.y])

	# 3. 盾长在身上：所有盾面相对身体原点的距离都在合理范围内。
	var pivot: Node3D = enemy.get("_shield_pivot")
	var shield_meshes := pivot.find_children("*", "MeshInstance3D", true, false)
	_check(shield_meshes.size() >= 3, "盾由多块盾面组成（%d 块）" % shield_meshes.size())
	var far := 0.0
	for node: Node in shield_meshes:
		far = maxf(far, enemy.to_local((node as MeshInstance3D).global_position).length())
	_check(far < 2.2, "盾面都贴在身体上（最远 %.2f 米）" % far)

	# 纯观察：不混进正式战斗。
	_check(not enemy.is_in_group("enemies"), "预览角色不进 enemies 分组")
	_check(not bool(enemy.get("ai_enabled")), "预览角色不跑 AI")
	_check(enemy.collision_layer == 0, "预览角色不参与碰撞")

	# 姿态 API：视觉台按 P 就靠这三样。
	_check(int(subject.call("get_preview_pose_count")) == 4, "四个姿态")
	var names := {}
	for i in range(int(subject.call("get_preview_pose_count"))):
		subject.call("set_preview_pose", i)
		var pose_name := String(subject.call("get_preview_pose_name"))
		_check(not pose_name.is_empty(), "姿态 %d 有名字" % i)
		names[pose_name] = true
	_check(names.size() == 4, "四个姿态名字互不重复")

	# 收盾 vs 插盾防御：盾必须**整体挪到身前并落到地上**，否则「P 换姿态」等于没换。
	# 注意断言的是盾的**世界位置**而不是单一旋转角 —— "插盾"主要由位移表达
	#（绕肘旋转会让盾变成一块斜板、底边落不到地），只盯 pitch 会写出假通过的断言。
	var shield_piece := shield_meshes[0] as MeshInstance3D
	subject.call("set_preview_pose", 0)
	for _frame in range(12):
		await process_frame
	var rest_pos := shield_piece.global_position
	subject.call("set_preview_pose", 1)
	for _frame in range(12):
		await process_frame
	var planted_pos := shield_piece.global_position
	_check(rest_pos.distance_to(planted_pos) > 0.3,
		"插盾把盾整体挪了位置（位移 %.2f 米）" % rest_pos.distance_to(planted_pos))
	_check(planted_pos.y < rest_pos.y - 0.15,
		"插盾把盾放低了（%.2f → %.2f）" % [rest_pos.y, planted_pos.y])

	# 全程循环：走的是正式相位机，所以能看到相位推进到插盾防御与解除。
	# 一个完整循环 = 起手 0.35 + 保持 2.4 + 解除 0.55 ≈ 3.3 秒，按 60fps 给足余量。
	subject.call("set_preview_pose", 3)
	var seen_states := {}
	for _frame in range(260):
		await process_frame
		seen_states[int(enemy.get("_shield_state"))] = true
	_check(seen_states.has(2), "全程循环里出现过插盾防御相位（走的是正式相位机）")
	_check(seen_states.has(3), "全程循环里出现过解除相位")

	_finish(root_node)


func _find_enemy(subject: Node) -> CharacterBody3D:
	for child in subject.get_children():
		if child is CharacterBody3D:
			return child as CharacterBody3D
	return null


func _roster_entry() -> Dictionary:
	var entries: Array = ConfigUtil.get_dictionary("enemy_roster").get("entries", [])
	for entry: Variant in entries:
		if entry is Dictionary and String(entry.get("id", "")) == "L3ShieldGuard":
			return entry
	return {}


func _finish(root_node: Node) -> void:
	root_node.free()
	print("[盾卫姿态预览] failures=", _failures)
	quit(1 if _failures else 0)


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
