extends SceneTree
## 云场契约：基础网格共享、天气变化不重建、分层风速、方向和循环边界。

const Field := preload("res://scripts/procedural_cloud_field.gd")
const Library := preload("res://scripts/cloud_mesh_library.gd")
const Preview := preload("res://scripts/weather_editor_preview.gd")
const CloudLighting := preload("res://scripts/cloud_lighting.gd")
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var bright_angle := CloudLighting.cloud_shadow_angle(Vector3.UP, 1.5, 0.5, 1.5, 1.5)
	var weak_angle := CloudLighting.cloud_shadow_angle(Vector3.UP, 0.3, 0.5, 1.5, 1.5)
	var low_sun_angle := CloudLighting.cloud_shadow_angle(Vector3(0.8, 0.2, 0.56).normalized(), 1.5, 0.5, 1.5, 1.5)
	_check(bright_angle > 0.0 and weak_angle > bright_angle, "强日光仍有半影，弱日光的半影更宽")
	_check(low_sun_angle > bright_angle, "低角度日光更柔")
	_check(is_equal_approx(CloudLighting.cloud_shadow_angle(Vector3.UP, 10.0, 0.0, 0.0, 1.5), 0.1), "错误的柔度参数也不能产生零半影")
	var first := Field.new()
	var second := Field.new()
	root.add_child(first)
	root.add_child(second)
	first.set_process(false)
	second.set_process(false)
	var meshes := Library.get_meshes()
	_check(meshes.size() == 6, "生成六种基础网格")
	_check(first.get_child_count() == 12, "两层各六个实例批次")
	var triangles := 0
	for mesh in meshes:
		_check(mesh.get_surface_count() == 1, "基础网格只有一个表面")
		_check(mesh.get_aabb().size.y > 75.0, "基础云形内部具有高低差和体积")
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		triangles += vertices.size() / 3
		for index in range(0, vertices.size(), 3):
			var winding := (vertices[index + 1] - vertices[index]).cross(vertices[index + 2] - vertices[index])
			_check(winding.length_squared() > 0.00001, "没有退化三角形")
			_check(winding.normalized().dot(normals[index]) < -0.99, "Godot 正面绕序与外法线一致")
		for vertex in vertices:
			_check(vertex.is_finite(), "所有顶点有效")
		_check_closed_surface(vertices)
	for batch_index in range(12):
		var a := first.get_child(batch_index) as MultiMeshInstance3D
		var b := second.get_child(batch_index) as MultiMeshInstance3D
		_check(a.multimesh.mesh == b.multimesh.mesh, "不同云场共享网格")
		_check(a.multimesh.mesh == meshes[batch_index % 6], "同种云形共享网格")
		_check(a.multimesh.instance_count == 8, "总实例数固定为 96")
		_check(a.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "不参加实时阴影")
	var rounded := Library.get_meshes(Library.Style.ROUNDED)
	_check(rounded.size() == 6, "圆润版本的六种模型完整保留")
	var rounded_triangles := 0
	for index in range(rounded.size()):
		_check(rounded[index] != meshes[index], "两种风格分别缓存")
		var vertices: PackedVector3Array = rounded[index].surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		rounded_triangles += vertices.size() / 3
		_check_closed_surface(vertices)
	_check(rounded_triangles == 12624, "保留圆润版本原有几何规模")
	first.set_shape_style(Library.Style.ROUNDED)
	_check((first.get_child(0) as MultiMeshInstance3D).multimesh.mesh == rounded[0], "可以切换到保留的圆润模型")
	first.set_shape_style(Library.Style.FACETED)
	_check((first.get_child(0) as MultiMeshInstance3D).multimesh.mesh == meshes[0], "切回切面版继续复用原缓存")
	var nodes_before := first.get_child_count()
	var ids: Array[int] = []
	for mesh in meshes:
		ids.append(mesh.get_instance_id())
	first.set_motion(8.0, 0.0, 1.0, 0.0)
	first.set_weather(1.0, 0.5, 1.0, Color.WHITE, Color.GRAY)
	first._update_transforms()
	var low_batch := first.get_child(0) as MultiMeshInstance3D
	var high_batch := first.get_child(6) as MultiMeshInstance3D
	var low_before := first.get_cloud_transform(0).origin
	var high_before := first.get_cloud_transform(48).origin
	first._process(1.0)
	var low_delta := first.get_cloud_transform(0).origin - low_before
	var high_delta := first.get_cloud_transform(48).origin - high_before
	_check(low_delta.is_equal_approx(Vector3(8.0, 0.0, 0.0)), "0 度沿 +X 推进")
	_check(is_equal_approx(high_delta.length(), 8.0 * 0.64), "高层以低层 0.64 倍速度推进")
	first.set_motion(8.0, 90.0, 1.0, 0.05)
	low_before = first.get_cloud_transform(0).origin
	first._process(1.0)
	_check((first.get_cloud_transform(0).origin - low_before).is_equal_approx(Vector3(0.0, 0.0, 8.0)), "90 度沿 +Z 推进")
	first.set_motion(0.0, 90.0, 1.0, 0.0)
	low_before = first.get_cloud_transform(0).origin
	first._process(1.0)
	_check(first.get_cloud_transform(0).origin == low_before, "零风速停止位移")
	var sparse_count := 0
	first.set_weather(0.21, 0.0, 0.0, Color.WHITE, Color.GRAY)
	first._update_transforms()
	for index in range(first._clouds.size()):
		if first.get_cloud_transform(index).basis.x.length() > 0.001:
			sparse_count += 1
	_check(sparse_count > 0 and sparse_count < 40, "低覆盖率保留稀疏云团")
	first.set_weather(1.0, 1.0, 1.0, Color.GRAY, Color.GRAY)
	first._clouds[0]["base"] = Vector2(1199.0, 0.0)
	first._layer_offsets[0] = Vector2.ZERO
	first._update_transforms()
	_check(first.get_cloud_transform(0).basis.x.length() < 0.001, "循环边缘先收缩至零")
	first.set_motion(8.0, 0.0, 1.0, 0.0)
	first._process(1.0)
	_check(first.get_cloud_transform(0).origin.x < 0.0, "跨边界回收至另一侧")
	_check(first.get_cloud_transform(0).basis.x.length() < 0.001, "回收后仍隐藏在边缘")
	# 图形运行时再核对提交给真实 MultiMesh 的数据；headless 的 dummy 后端无此缓存。
	if DisplayServer.get_name() != "headless":
		_check(low_batch.multimesh.get_instance_transform(0).is_equal_approx(first.get_cloud_transform(0)), "低层变换实际提交给渲染器")
		_check(high_batch.multimesh.get_instance_transform(0).is_equal_approx(first.get_cloud_transform(48)), "高层变换实际提交给渲染器")
	first._process(100000.0)
	for offset in first._layer_offsets:
		_check(absf(offset.x) <= 1200.0 and absf(offset.y) <= 1200.0, "长时间运行的位移保持有界")
	var saved := first.get_weather_state()
	first.set_cloud_shadows(true)
	for batch in first.get_children():
		_check((batch as MultiMeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "所有天空云批次参与真实投影")
	first.set_shape_style(Library.Style.ROUNDED)
	_check(low_batch.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "切换云型保留投影状态")
	first.set_cloud_shadows(false)
	_check(low_batch.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "可以关闭真实云影")
	first.set_weather(0.0, 0.5, 0.0, Color.WHITE, Color.GRAY)
	_check(not first.visible, "关闭云层隐藏所有批次")
	first.restore_weather_state(saved)
	_check(first.get_weather_state() == saved, "编辑器预览状态可以恢复")
	_check(first.get_child_count() == nodes_before, "天气与运动不增加节点")
	for index in range(meshes.size()):
		_check(Library.get_meshes()[index].get_instance_id() == ids[index], "天气与运动不重建网格")
	first.free()
	second.free()
	change_scene_to_file("res://prototypes/environment/weather_lab.tscn")
	for _frame in range(8):
		await process_frame
	var scene := current_scene
	_check(scene.find_child("BackdropClouds", true, false) == null, "统一天气场景停用旧云网格")
	var weather := scene.get_node("WeatherEnvironment/WeatherSystem")
	var gallery := scene.get_node("CloudModelGallery/__CloudModels")
	_check(gallery.get_child_count() == 6, "实验场地面陈列六种基础模型")
	for index in range(6):
		var model := gallery.get_node("Cloud%02d/Model" % (index + 1)) as MeshInstance3D
		_check(model.mesh == Library.get_meshes()[index], "地面陈列与天空共享相同模型")
		_check(not model.is_in_group("nav_source"), "陈列云不加入导航烘焙")
	var field := weather.get_node("ProceduralCloudField")
	_check(field.get_child_count() == 12, "天气实验场已接入云场")
	_check((field.get_child(0) as MultiMeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "统一天气默认开启真实云影")
	weather.cloud_wind_speed = 13.0
	weather.cloud_wind_direction_degrees = 72.0
	weather.cloud_size_multiplier = 1.2
	weather.cloud_deformation_amount = 0.03
	weather.call("_process", 0.0)
	_check(is_equal_approx(field.wind_speed, 13.0) and is_equal_approx(field.wind_direction_degrees, 72.0), "天气入口传递云风速和方向")
	_check(is_equal_approx(field.size_multiplier, 1.2) and is_equal_approx(field.deformation_amount, 0.03), "天气入口传递缩放与轻微变形")
	var baseline: Array = field.get_weather_state()
	var sky := scene.get_node("WeatherEnvironment/Sky3D") as WorldEnvironment
	var dome := sky.get_node("SkyDome")
	var sun := sky.get_node("SunLight") as DirectionalLight3D
	_check(sun.light_angular_distance > 0.0, "运行时真实云影启用距离相关的 PCSS 柔化")
	var baseline_angle := sun.light_angular_distance
	var baseline_depth := sun.directional_shadow_pancake_size
	_check(baseline_depth >= field.get_cloud_height_ceiling() / sun.global_basis.z.y,
		"阴影深度保留最高云层，避免多层云被压到同一边界")
	var shadow_distance := sun.directional_shadow_max_distance
	var engine_baseline := float(weather.get("_sun_angular_baseline"))
	weather.cloud_shadow_enabled = false
	weather.call("_process", 0.0)
	_check(is_equal_approx(sun.light_angular_distance, engine_baseline), "关闭云影恢复原太阳角径，关闭新增软影开销")
	_check(is_equal_approx(sun.directional_shadow_pancake_size, float(weather.get("_sun_pancake_baseline"))), "关闭云影恢复原投影深度")
	_check(is_equal_approx(sun.directional_shadow_max_distance, shadow_distance), "云影不扩大近景接收阴影的范围")
	weather.cloud_shadow_enabled = true
	weather.call("_process", 0.0)
	var host := scene.get_node("WeatherEnvironment/Sky3DExperimentController")
	var preview := Preview.new()
	preview._capture_baseline(host, sky, dome, sun)
	weather.cloud_coverage = 0.67
	weather.cloud_density = 0.82
	weather.cloud_wind_speed = 4.0
	weather.cloud_shape_style = Library.Style.ROUNDED
	weather.cloud_shadow_enabled = false
	preview._apply(host, weather, sky, dome, sun)
	var preview_state: Array = field.get_weather_state()
	_check(is_equal_approx(preview_state[0], 0.67) and is_equal_approx(preview_state[1], 0.82), "编辑器适配器传递相同天气参数")
	_check(is_equal_approx(field.wind_speed, 4.0), "编辑器适配器传递云层移动参数")
	_check((field.get_child(0) as MultiMeshInstance3D).multimesh.mesh == rounded[0], "编辑器适配器同步云形风格")
	_check((field.get_child(0) as MultiMeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "编辑器适配器同步云影开关")
	_check(is_equal_approx(sun.light_angular_distance, baseline_angle), "编辑器关闭云影恢复预览前的角径")
	weather.cloud_shadow_enabled = true
	weather.cloud_shadow_weak_sun_angle = 2.0
	preview._apply(host, weather, sky, dome, sun)
	_check(sun.light_angular_distance > 0.0, "编辑器适配器启用同一半影规则")
	_check(is_equal_approx(sun.light_angular_distance, CloudLighting.cloud_shadow_angle(
		sun.global_basis.z.normalized(), sun.light_energy, 0.5, 2.0, 1.5)), "编辑器柔度依当前阳光强度推导")
	gallery.get_parent().call("_build")
	_check((scene.get_node("CloudModelGallery/__CloudModels/Cloud01/Model") as MeshInstance3D).mesh == rounded[0], "地面陈列跟随天气风格切换")
	preview._restore(sky, dome, sun)
	_check(is_equal_approx(sun.light_angular_distance, baseline_angle), "关闭预览恢复太阳原半影设置")
	_check(is_equal_approx(sun.directional_shadow_pancake_size, baseline_depth), "关闭预览恢复太阳原投影深度")
	weather.cloud_shape_style = Library.Style.FACETED
	weather.cloud_shadow_enabled = true
	_check(field.get_weather_state() == baseline, "关闭编辑器预览可恢复完整云场状态")
	var min_height := INF
	var max_height := -INF
	for cloud in field._clouds:
		if int(cloud["layer"]) == 0:
			min_height = minf(min_height, float(cloud["height"]))
			max_height = maxf(max_height, float(cloud["height"]))
	_check(max_height - min_height > 90.0, "同层云团具有明显高度错落")
	print("[程序云测试] %s；基础网格合计 %d 三角形，12 批次 / 96 实例，稀疏状态 %d 团" % [
		"通过" if not _failed else "失败", triangles, sparse_count])
	quit(1 if _failed else 0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[程序云测试] " + message)


func _check_closed_surface(vertices: PackedVector3Array) -> void:
	var ids: Dictionary = {}
	var edges: Dictionary = {}
	var neighbors: Array[Dictionary] = []
	for index in range(0, vertices.size(), 3):
		var triangle: Array[int] = []
		for corner in range(3):
			var vertex := vertices[index + corner]
			if not ids.has(vertex):
				ids[vertex] = ids.size()
				neighbors.append({})
			triangle.append(ids[vertex])
		for corner in range(3):
			var a := triangle[corner]
			var b := triangle[(corner + 1) % 3]
			var key := Vector2i(mini(a, b), maxi(a, b))
			edges[key] = int(edges.get(key, 0)) + 1
			neighbors[a][b] = true
			neighbors[b][a] = true
	var closed := true
	for count in edges.values():
		if int(count) != 2:
			closed = false
	_check(closed, "融合云形为封闭表面，不存在裸露边缘与内部重叠面")
	var visited: Dictionary = {0: true}
	var stack: Array[int] = [0]
	while not stack.is_empty():
		var index: int = stack.pop_back()
		for neighbor in neighbors[index]:
			if not visited.has(neighbor):
				visited[neighbor] = true
				stack.append(neighbor)
	_check(visited.size() == ids.size(), "每种基础云形是一个连续体块")
