extends SceneTree
## 正式圣所场景：入口 / 祭坛绕行的碰撞和导航，以及建筑内的真实装饰几何。
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Arena := preload("res://scripts/arena.gd")
const Cache := preload("res://scripts/valley_static_cache.gd")
const Art := preload("res://scripts/valley_art.gd")
const MapBuilder := preload("res://scripts/world_map_builder.gd")
var _failed := false
var _report: Dictionary = {"routes": [], "captures": []}

func _initialize() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	call_deferred("_run")

func _run() -> void:
	for _frame in 30:
		await process_frame
	# Runtime bake_finished 并不代表异步导航服务器已发布地图；等真实可查询面。
	var navigation_map: RID = current_scene.get_world_3d().navigation_map
	for _frame in range(1200):
		if NavigationServer3D.map_get_closest_point_owner(navigation_map, Vector3.ZERO).is_valid(): break
		await physics_frame
	paused = true
	var scene := current_scene as Node3D
	var builder: Node3D
	for node in scene.get_children():
		if node.get_script() == MapBuilder:
			builder = node
	_check(builder != null, "正式场景必须使用地图构建器")
	_check(Cache.current() and Art.generated_builds == 0, "正式场景必须加载与当前配置匹配的静态美术")
	var nav := scene.get_node("NavRegion") as NavigationRegion3D
	_check(nav.call("is_baked"), "正式导航必须完成烘焙")
	if builder == null:
		quit(1)
		return
	_check(builder.get_node_or_null("EntranceApron") != null, "正式入口必须生成收口石铺")
	var space := scene.get_world_3d().direct_space_state
	var map := nav.get_navigation_map()
	_verify_route("入口与门洞", [Vector2(3, -20), Vector2(3, -38)], space, map)
	_verify_route("蓝祭坛左绕行", [Vector2(3, -38), Vector2(-5.5, -38), Vector2(-5.5, -53), Vector2(3, -53)], space, map)
	_verify_route("蓝祭坛右绕行", [Vector2(3, -38), Vector2(11.5, -38), Vector2(11.5, -53), Vector2(3, -53)], space, map)
	_verify_route("后门", [Vector2(3, -53), Vector2(3, -64)], space, map)
	_verify_route("红祭坛前原道路", [Vector2(12, 2), Vector2(52, 2)], space, map)
	_verify_route("红祭坛连接路", [Vector2(31, 3), Vector2(31, 8)], space, map)
	_verify_route("黄色祭坛入口", [Vector2(-24, 2), Vector2(-30, 2)], space, map)
	_verify_decor(scene, builder)
	var bases := 0
	for child in builder.get_children():
		if child is StaticBody3D and child.position.distance_to(Vector3(31, 0.25, 13)) < 0.1:
			bases += 1
	_check(bases == 1, "红祭坛底座必须整组移动到路旁并贴地")
	for at in [Vector2(-39, -4), Vector2(-28, 8), Vector2(26.75, 8.75), Vector2(35.25, 17.25)]:
		_check(absf(Terrain.height_at(at.x, at.y)) < 0.001, "祭坛基础范围必须水平落地：%s" % at)
	if DisplayServer.get_name() != "headless":
		await _capture(scene)
	var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("sanctum_layout.json"), FileAccess.WRITE)
	if file == null:
		_check(false, "地图验证报告必须写入")
	else:
		_report["passed"] = not _failed
		_report["static_signature"] = Cache.signature()
		file.store_string(JSON.stringify(_report, "\t") + "\n")
		file.close()
	print("[圣所布局] ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)

func _verify_route(label: String, points: Array, space: PhysicsDirectSpaceState3D, map: RID) -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.5
	capsule.height = 1.9
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = 1
	query.margin = 0.01
	var hits: Array = []
	var paths: Array = []
	for index in range(points.size() - 1):
		var start: Vector2 = points[index]
		var finish: Vector2 = points[index + 1]
		for sample in range(ceili(start.distance_to(finish) / 0.5) + 1):
			var at := start.lerp(finish, minf(sample * 0.5 / start.distance_to(finish), 1.0))
			query.transform = Transform3D(Basis.IDENTITY, Vector3(at.x, Terrain.height_at(at.x, at.y) + 1.25, at.y))
			for hit in space.intersect_shape(query, 8):
				hits.append({"point": at, "collider": str(hit.collider.get_path())})
		var a := Vector3(start.x, Terrain.height_at(start.x, start.y), start.y)
		var b := Vector3(finish.x, Terrain.height_at(finish.x, finish.y), finish.y)
		var path := NavigationServer3D.map_get_path(map, a, b, true)
		_check(path.size() >= 2 and path[-1].distance_to(b) < 1.0, "%s 第%d段导航必须到达" % [label, index])
		paths.append(path)
	_check(hits.is_empty(), "%s 玩家胶囊路线必须畅通：%s" % [label, hits])
	_report.routes.append({"name": label, "waypoints": points, "collisions": hits, "navigation": paths})

func _verify_decor(scene: Node3D, builder: Node3D) -> void:
	var chapel := AABB(Vector3(-40.5, -1, -5), Vector3(13, 16, 14))
	var checked := 0
	for mesh in builder.get_node("Grove").find_children("*", "MeshInstance3D", true, false):
		var bounds: AABB = mesh.global_transform * mesh.get_aabb()
		_check(not bounds.intersects(chapel), "树干 / 树冠不得侵入黄色祭坛：%s" % mesh.get_path())
		checked += 1
	var rocks := scene.get_node("WorldDecor/FieldBoulders/BoulderBatch") as MultiMeshInstance3D
	var rock_bounds: Array[AABB] = []
	for i in rocks.multimesh.instance_count:
		var transform := rocks.global_transform * rocks.multimesh.get_instance_transform(i)
		var bounds: AABB = transform * rocks.multimesh.mesh.get_aabb()
		_check(not bounds.intersects(chapel), "岩块不得侵入黄色祭坛：%d" % i)
		rock_bounds.append(bounds)
		checked += 1
	for trunk in builder.get_node("Grove").find_children("Trunk", "MeshInstance3D", true, false):
		var bounds: AABB = trunk.global_transform * trunk.get_aabb()
		for rock in rock_bounds:
			_check(not bounds.intersects(rock), "树干不得长进岩块：%s" % trunk.get_path())
	for name in ["MeadowColonies", "MeadowShrubs"]:
		var meshes := builder.get_node("ValleyArt").find_children(name, "MeshInstance3D", true, false)
		_check(meshes.size() == 1, "必须检查当前缓存里的实际植被：%s" % name)
		for mesh in meshes:
			var vertices: PackedVector3Array = mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				_check(not chapel.has_point(mesh.global_transform * vertex), "缓存植被不得长进黄色祭坛：%s" % name)
		_report["checked_decor_objects"] = checked

func _capture(scene: Node3D) -> void:
	MouseControl.mode = Input.MOUSE_MODE_VISIBLE
	DisplayServer.window_set_size(Vector2i(1600, 1000))
	root.size = Vector2i(1600, 1000)
	for canvas in root.find_children("*", "CanvasLayer", true, false):
		canvas.hide()
	var weather := scene.get_node("WeatherEnvironment/WeatherSystem")
	weather.set("cloud_enabled", false)
	weather.set("rain_enabled", false)
	weather.set("fog_enabled", false)
	weather.set("snow_enabled", false)
	var sky := scene.get_node("WeatherEnvironment/Sky3D")
	var time := sky.get_node("TimeOfDay")
	time.call("pause")
	time.set("current_time", 11.83)
	sky.set("current_time", 11.83)
	time.call("_update_celestial_coords")
	weather.call("_sync_extra_layers")
	weather.call("_update_environment")
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.far = 2500
	camera.fov = 50
	camera.make_current()
	var views := [
		{"name": "layout_overview", "camera": Vector3(78, 100, 76), "target": Vector3(0, 0, -19)},
		{"name": "entrance_and_blue_altar", "camera": Vector3(42, 66, 12), "target": Vector3(3, 0, -36)},
		{"name": "yellow_altar", "camera": Vector3(-15, 27, 26), "target": Vector3(-34, 1, 2)},
		{"name": "red_altar", "camera": Vector3(54, 30, 36), "target": Vector3(31, 0, 7)}]
	for view in views:
		camera.global_position = view.camera
		camera.look_at(view.target)
		for _frame in 12:
			await RenderingServer.frame_post_draw
		var path := Artifacts.ensure_dir("screenshots").path_join(view.name + ".png")
		_check(root.get_texture().get_image().save_png(path) == OK, "布局截图必须保存")
		_report.captures.append({"name": view.name, "path": path, "camera": camera.global_transform})

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failed = true
		push_error("[圣所布局] " + message)
