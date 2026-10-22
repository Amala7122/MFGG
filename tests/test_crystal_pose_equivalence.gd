extends SceneTree
## 程序腿采样提取公共计算后，与修改前采样器逐节点对照，包含倒放和死亡。
const Reference := preload("res://tests/fixtures/crystal_pose_reference.gd")
const Scenes := [preload("res://prototypes/visual_lab/burst_crawler_visual.tscn"),
	preload("res://prototypes/visual_lab/prism_spider_visual.tscn"), preload("res://prototypes/visual_lab/charge_beetle_visual.tscn")]
var _failed := false
var _samples := 0

func _initialize() -> void:
	call_deferred("_run")

func _capture(visual: Node) -> Dictionary:
	var result: Dictionary = {}
	for node: Node3D in visual.find_children("*", "Node3D", true, false):
		result[node.get_instance_id()] = {"transform": node.transform, "visible": node.visible}
	return result

func _check_pose(visual: Node3D, time: float) -> void:
	Reference.sample(visual, time)
	var expected := _capture(visual)
	visual.sample_pose(time)
	_compare(visual, expected, time)
	# 模拟慢渲染帧的多物理步：主体先更新，显示前一次提交腿的最后姿态。
	visual.sample_combat_pose(time + 0.1)
	visual.sample_combat_pose(time + 0.05)
	visual.sample_combat_pose(time)
	visual.flush_limb_pose()
	_compare(visual, expected, time)
	_samples += 1

func _compare(visual: Node3D, expected: Dictionary, time: float) -> void:
	for node: Node3D in visual.find_children("*", "Node3D", true, false):
		var row: Dictionary = expected[node.get_instance_id()]
		if not node.transform.is_equal_approx(row.transform) or node.visible != row.visible:
			_failed = true
			push_error("姿态等价失败：%s/%s pose=%d time=%s" % [visual.name, node.name, visual.preview_pose, time])

func _run() -> void:
	for _frame in range(3): await process_frame
	paused = false
	for scene: PackedScene in Scenes:
		var visual := scene.instantiate() as Node3D
		root.add_child(visual)
		visual.set_process(false)
		for pose in range(visual.get_preview_pose_names().size()):
			visual.preview_pose = pose
			var duration: float = visual.get_preview_duration()
			for fraction: float in [0.0, 0.03, 0.15, 0.35, 0.49, 0.65, 0.81, 0.99, 1.01, 1.75]:
				_check_pose(visual, duration * fraction)
		visual.free()
	print("[程序腿采样等价] samples=", _samples, " ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
