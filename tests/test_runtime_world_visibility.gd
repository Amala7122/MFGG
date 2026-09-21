extends SceneTree


func _initialize() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	call_deferred("_verify_after_build")


func _verify_after_build() -> void:
	# 地图内容和导航都是延迟挂载；给它们几个完整帧完成初始化。
	for _frame in range(8):
		await process_frame
	var scene := current_scene
	var failed := false
	for node_name in ["Ground", "Grass", "WorldDecor", "Cover"]:
		var node := scene.get_node_or_null(node_name) as Node3D
		if node == null or not node.is_visible_in_tree():
			failed = true
			push_error("[世界可见性测试] %s 在正式运行时不可见" % node_name)
		else:
			print("[世界可见性测试] %s 可见" % node_name)
	var terrain := scene.get_node_or_null("Ground/TerrainMesh") as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		failed = true
		push_error("[世界可见性测试] 彩色地形网格未生成")
	else:
		var arrays := terrain.mesh.surface_get_arrays(0)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		if colors.is_empty():
			failed = true
			push_error("[世界可见性测试] 地形缺少顶点色，会显示成白色")
		else:
			print("[世界可见性测试] 地形顶点色 %d 个" % colors.size())
	var max_fps := int(ProjectSettings.get_setting("application/run/max_fps", -1))
	var vsync_mode := int(ProjectSettings.get_setting("display/window/vsync/vsync_mode", -1))
	if max_fps != 0 or vsync_mode != 0:
		failed = true
		push_error("[性能显示测试] 限帧设置错误：max_fps=%d vsync=%d" % [max_fps, vsync_mode])
	else:
		print("[性能显示测试] 引擎帧率上限关闭，垂直同步关闭")
	quit(1 if failed else 0)
