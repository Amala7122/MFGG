extends SceneTree
## 经 run_probe 隔离生成，资源先写入本次 tmp/baked_valley；核对后再应用到正式资产。
const Artifacts := preload("res://scripts/artifact_paths.gd")
const Arena := preload("res://scripts/arena.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Art := preload("res://scripts/valley_art.gd")
const Cache := preload("res://scripts/valley_static_cache.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	Arena.current_id = "sanctum"
	Terrain.height_at(0, 0)
	Cache.force_generation = true
	var directory := Artifacts.ensure_dir("tmp", "baked_valley")
	var mountains := Art.mountains()
	if ResourceSaver.save(mountains, directory.path_join("sanctum_mountains.res")) != OK:
		push_error("山谷山体保存失败。")
		quit(1)
		return
	var art := Art.new()
	art.name = "BakedValleyArt"
	root.add_child(art)
	_own_children(art, art)
	# 缓存只保存生成结果；保留根生成脚本会在加载缓存时递归实例化自身。
	art.set_script(null)
	var packed := PackedScene.new()
	if packed.pack(art) != OK or ResourceSaver.save(packed, directory.path_join("sanctum_art.scn")) != OK:
		push_error("山谷美术场景保存失败。")
		quit(1)
		return
	var saved := ResourceLoader.load(directory.path_join("sanctum_art.scn"), "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var restored := saved.instantiate()
	if restored.get_script() != null or restored.get_child_count() != art.get_child_count():
		push_error("山谷缓存必须只含静态几何，且重载后的节点数量须与生成结果一致。")
		restored.free()
		quit(1)
		return
	restored.free()
	var manifest := {"format_version": Cache.FORMAT_VERSION,
		"generated_at": Time.get_datetime_string_from_system(), "signature": Cache.signature(),
		"terrain_signature": Cache.terrain_signature(),
		"mountain_vertices": mountains.surface_get_array_len(0)}
	var file := FileAccess.open(directory.path_join("manifest.json"), FileAccess.WRITE)
	if file == null:
		push_error("山谷资源清单保存失败。")
		quit(1)
		return
	file.store_string(JSON.stringify(manifest, "\t") + "\n")
	file.close()
	print("[山谷资源] 已生成：", directory, "，静态节点：", art.get_child_count())
	art.free()
	quit(0)

func _own_children(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own_children(child, owner_node)
