extends MainLoop
## 临时性能核查脚本（用完即删）。
##
## 目的：在动手改配置之前，先在真实的 Godot 版本上核对几个关键 API 是否还在。
## 本项目踩过"写了不存在的 Environment 属性却不报错、只是静默失效"的坑
## （见 graphics_director.gd 里 _set_env_number 的存在性闸），所以这里先把
## 属性清单打出来眼见为实，再去改 game_config.json。


func _initialize() -> void:
	var info := Engine.get_version_info()
	print("[PROBE] Godot ", String(info.get("string", "?")))

	# Environment 是 Resource（RefCounted），不能 free。
	var env := Environment.new()
	print("[PROBE] --- Environment 上所有含 ssao / ao 的属性 ---")
	for entry in env.get_property_list():
		var prop_name := String(entry.get("name", ""))
		if prop_name.contains("ssao") or prop_name.contains("_ao_"):
			print("[PROBE]   ", prop_name)
	print("[PROBE] ssao_half_size 存在 = ", "ssao_half_size" in env)

	print("[PROBE] --- Environment 上所有含 shadow 的属性 ---")
	for entry in env.get_property_list():
		var prop_name := String(entry.get("name", ""))
		if prop_name.contains("shadow"):
			print("[PROBE]   ", prop_name)

	print("[PROBE] --- 项目设置里所有含 ssao / ao / msaa 的键 ---")
	for entry in ProjectSettings.get_property_list():
		var prop_name := String(entry.get("name", ""))
		if prop_name.contains("ssao") or prop_name.contains("/ao") \
				or prop_name.contains("msaa"):
			print("[PROBE]   ", prop_name, " = ", ProjectSettings.get_setting(prop_name))

	print("[PROBE] --- Viewport.MSAA ---")
	print("[PROBE]   DISABLED=", Viewport.MSAA_DISABLED,
		"  MSAA_2X=", Viewport.MSAA_2X,
		"  MSAA_4X=", Viewport.MSAA_4X,
		"  MSAA_8X=", Viewport.MSAA_8X)

	print("[PROBE] --- DirectionalLight3D.ShadowMode ---")
	print("[PROBE]   SHADOW_ORTHOGONAL=", DirectionalLight3D.SHADOW_ORTHOGONAL,
		"  PARALLEL_2_SPLITS=", DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"  PARALLEL_4_SPLITS=", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)

	print("[PROBE] --- GeometryInstance3D 的 visibility_range ---")
	var mi := MeshInstance3D.new()
	var found_vr := false
	for entry in mi.get_property_list():
		var prop_name := String(entry.get("name", ""))
		if prop_name.contains("visibility_range"):
			found_vr = true
			print("[PROBE]   ", prop_name)
	if not found_vr:
		print("[PROBE]   不存在 visibility_range 属性！")
	mi.free()

	print("[PROBE] --- 各场景的可绘制对象数 ---")
	for path in [
		"res://scenes/hyrule_field.tscn",
		"res://scenes/melee_enemy.tscn",
		"res://scenes/ranged_enemy.tscn",
		"res://scenes/enemy_bullet.tscn",
		"res://scenes/ground_warning.tscn",
	]:
		var packed: PackedScene = load(path)
		if packed == null:
			print("[PROBE]   ", path, " 加载失败")
			continue
		var root := packed.instantiate()
		if root == null:
			print("[PROBE]   ", path, " 实例化失败")
			continue
		var meshes := 0
		var labels := 0
		var lights := 0
		var shadow_casters := 0
		var total := 0
		# type 必须传 ""（任意类型）。传 "*" 会被当成类名去比对，一个都匹配不上。
		for node in root.find_children("*", "", true, false):
			total += 1
			if node is MeshInstance3D:
				meshes += 1
				if node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					shadow_casters += 1
			elif node is Label3D:
				labels += 1
			elif node is Light3D:
				lights += 1
		print("[PROBE]   %-26s 节点=%3d mesh=%3d 投影=%3d label3d=%2d light=%d" % [
			path.get_file(), total, meshes, shadow_casters, labels, lights
		])
		root.free()


func _process(_delta: float) -> bool:
	return true
