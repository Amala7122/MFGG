extends SceneTree
## 观察工具守卫：慢放、逐帧、运动分解（叠影 / 排开）、技能循环时间轴。
## 这些能力退化时本测试必须失败，否则用户又会退回"说不清哪里不对"的处境。

const LabScene := preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
const CapturePaths := preload("res://scripts/capture_paths.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const ParamParts := preload("res://scripts/prototypes/visual_param_parts.gd")
const BURST_TITLE := "爆囊爬兽"
const PROFILE_ORDER: Array[String] = ["VisualBurstCrawler", "VisualPrismSpider", "VisualChargeBeetle"]
const PROFILE_TITLES := {
	"VisualBurstCrawler": "爆囊爬兽",
	"VisualPrismSpider": "棱眼蛛",
	"VisualChargeBeetle": "裂甲兜虫",
}
const CRAWLER_TRIANGLES := 3600
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	var lab: Node3D = LabScene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for frame in range(5):
		await process_frame
	lab.call("_show_subject", _gallery_index_of(lab, BURST_TITLE))
	for frame in range(4):
		await process_frame
	var mount := lab.get_node("SubjectMount") as Node3D
	var subject := mount.get_child(0) as Node3D
	_check(subject.name == "ProceduralBurstCrawlerVisual", "预览主体应为爆囊爬兽")

	# —— 技能循环：时间轴必须出现，并且把"爆发"段标出来 ——
	lab.call("_unhandled_input", _key(KEY_P))
	lab.call("_unhandled_input", _key(KEY_P))
	for frame in range(3):
		await process_frame
	_check(int(subject.get("preview_pose")) == 2, "两次 P 应进入技能循环")
	var timeline: Control = lab.get("_timeline")
	_check(timeline != null and timeline.visible, "技能循环应显示时间轴")
	if timeline != null and timeline.visible:
		var bands: Array = timeline.get("_bands")
		_check(bands.size() == 4, "时间轴应有蓄力 / 定势 / 爆发 / 收势四段")
		var cycle := float(lab.call("_cycle_duration"))
		var burst_ratio := -1.0
		for band in bands:
			if bool(band.get("decisive", false)):
				burst_ratio = (float(band["to"]) - float(band["from"])) / cycle
		_check(burst_ratio >= 0.0, "时间轴必须标出打击段")
		_check(burst_ratio < 0.06, "默认爆发段应短于 6%%，实测 %.3f" % burst_ratio)
		_check(timeline.get("_charge") is PackedFloat32Array and (timeline.get("_charge") as PackedFloat32Array).size() > 2,
			"时间轴应带有蓄力曲线采样")

	# —— 慢放 ——
	_check(is_equal_approx(float(subject.get("preview_speed")), 1.0), "默认应为原速")
	lab.call("_unhandled_input", _key(KEY_BRACKETLEFT))
	_check(is_equal_approx(float(subject.get("preview_speed")), 0.5), "按一次 [ 应降到 0.5 倍速")
	lab.call("_unhandled_input", _key(KEY_BRACKETLEFT))
	_check(is_equal_approx(float(subject.get("preview_speed")), 0.25), "再按一次 [ 应降到 0.25 倍速")
	lab.call("_unhandled_input", _key(KEY_BRACKETRIGHT))
	_check(is_equal_approx(float(subject.get("preview_speed")), 0.5), "] 应升回 0.5 倍速")

	# —— 逐帧：冻结后前进一帧 = 1/60 秒，且可回退 ——
	lab.call("_unhandled_input", _key(KEY_M))
	for frame in range(2):
		await process_frame
	_check(subject.process_mode == Node.PROCESS_MODE_DISABLED, "M 应冻结主体")
	var before := float(subject.get("preview_time"))
	lab.call("_unhandled_input", _key(KEY_PERIOD))
	var stepped := float(subject.get("preview_time"))
	_check(absf(stepped - before - 1.0 / 60.0) < 0.0005, "按一次 . 应前进 1/60 秒，实测 %.5f" % (stepped - before))
	_check(subject.process_mode == Node.PROCESS_MODE_DISABLED, "逐帧后应保持冻结")
	lab.call("_unhandled_input", _key(KEY_COMMA))
	_check(absf(float(subject.get("preview_time")) - before) < 0.0005, "按一次 , 应退回原帧")

	# —— 同一时间必须得到同一姿态（洋葱皮才可信） ——
	subject.set("preview_time", 0.9)
	subject.call("sample_pose", 0.9)
	var first: Vector3 = (subject.get("body") as Node3D).rotation
	subject.call("sample_pose", 0.9)
	var second: Vector3 = (subject.get("body") as Node3D).rotation
	_check(first.is_equal_approx(second), "同一时间重复采样应得到相同姿态")

	# —— 运动分解：残影必须在独立挂点上，不能污染 SubjectMount 的子节点顺序 ——
	lab.call("_unhandled_input", _key(KEY_V))
	for frame in range(3):
		await process_frame
	_check(int(lab.get("_motion_decompose")) == 1, "第一次 V 应进入叠影")
	var ghost_mount := lab.get_node_or_null("MotionDecompose")
	_check(ghost_mount != null, "叠影应有独立挂点 MotionDecompose")
	_check(mount.get_child_count() == 1, "残影不得挂进 SubjectMount（测试与截图按该挂点取主体）")
	if ghost_mount != null:
		_check(ghost_mount.get_child_count() == 4, "叠影应有 4 个残影，实测 %d" % ghost_mount.get_child_count())
		var times := {}
		var xs := {}
		for child in ghost_mount.get_children():
			var ghost := child as Node3D
			times[snappedf(float(ghost.get("preview_time")), 0.0001)] = true
			xs[snappedf(ghost.position.x, 0.001)] = true
			var parts := ghost.find_children("*", "MeshInstance3D", true, false)
			_check(parts.size() > 0, "残影应有网格")
			_check((parts[0] as MeshInstance3D).material_override != null, "残影应换成半透明材质")
		_check(times.size() == 4, "4 个残影应处于不同时间，实测 %d 种" % times.size())
		_check(xs.size() == 1, "叠影不应沿 X 排开，实测 %d 种位置" % xs.size())
	_check(int(lab.call("_count_triangles")) <= CRAWLER_TRIANGLES, "残影不得计入主体的三角面统计")
	lab.call("_unhandled_input", _key(KEY_V))
	for frame in range(3):
		await process_frame
	_check(int(lab.get("_motion_decompose")) == 2, "第二次 V 应进入排开")
	if ghost_mount != null:
		var spread := {}
		for child in ghost_mount.get_children():
			spread[snappedf((child as Node3D).position.x, 0.001)] = true
		_check(spread.size() == 4, "排开应有 4 个不同位置，实测 %d 种" % spread.size())
	lab.call("_unhandled_input", _key(KEY_V))
	for frame in range(3):
		await process_frame
	_check(int(lab.get("_motion_decompose")) == 0, "第三次 V 应关闭运动分解")
	if ghost_mount != null:
		_check(ghost_mount.get_child_count() == 0, "关闭后不应残留残影")

	# —— 换角色后残影与时间轴都要收拾干净 ——
	lab.call("_unhandled_input", _key(KEY_V))
	for frame in range(3):
		await process_frame
	lab.call("_show_subject", _gallery_index_of(lab, "镇墓兽"))
	for frame in range(4):
		await process_frame
	_check(mount.get_child_count() == 1, "换角色后 SubjectMount 仍应只有一个主体")
	# 镇墓兽那份 sample_pose 必须真的把姿态定住并推进 1/60 秒（不只是"有这个方法"）。
	var guardian := mount.get_child(0) as Node3D
	lab.set("_motion_enabled", false)
	lab.call("_apply_motion_state")
	for frame in range(2):
		await process_frame
	var guardian_before := float(guardian.get("preview_time"))
	lab.call("_unhandled_input", _key(KEY_PERIOD))
	_check(absf(float(guardian.get("preview_time")) - guardian_before - 1.0 / 60.0) < 0.0005,
		"镇墓兽按一次 . 应前进 1/60 秒，实测 %.5f" % (float(guardian.get("preview_time")) - guardian_before))
	# 镇墓兽同样声明了可逐帧：残影应重建到它身上，而不是残留上一个角色的。
	if ghost_mount != null:
		_check(ghost_mount.get_child_count() == 4, "可逐帧的角色应重建残影，实测 %d" % ghost_mount.get_child_count())
	# 切到没有时间轴的角色（战斗体）：残影必须清掉。
	lab.call("_show_subject", _gallery_index_of(lab, "晶刺蜂"))
	for frame in range(4):
		await process_frame
	if ghost_mount != null:
		_check(ghost_mount.get_child_count() == 0, "无时间轴的角色不应残留残影")

	# —— 参数 → 部位：每个字段都要有登记，且登记的节点名必须真实存在 ——
	for profile in PROFILE_ORDER:
		lab.call("_show_subject", _gallery_index_of(lab, PROFILE_TITLES[profile]))
		for frame in range(4):
			await process_frame
		var model := mount.get_child(0) as Node3D
		var missing: Array = []
		for group: Dictionary in Tuning.get_schema(profile).get("groups", []):
			for field: Dictionary in group.get("fields", []):
				var key := String(field.get("key", ""))
				var entry := ParamParts.lookup(profile, key)
				if entry.is_empty():
					missing.append(key)
					continue
				for part in entry.get("parts", []) as Array:
					_check(model.find_children(String(part) + "*", "Node3D", true, false).size() > 0,
						"%s 的 %s 指向不存在的节点：%s" % [profile, key, part])
		_check(missing.is_empty(), "%s 有参数没登记作用部位：%s" % [profile, str(missing)])

	# —— 高亮行为：命中承托甲子树，清除后不留痕迹 ——
	lab.call("_show_subject", _gallery_index_of(lab, BURST_TITLE))
	for frame in range(4):
		await process_frame
	subject = mount.get_child(0) as Node3D
	var hinge := subject.get_node_or_null("VisualRig/Body/BackArmorHinge")
	_check(hinge != null, "承托甲铰链节点应存在")
	lab.call("_highlight_field", "back_raise")
	var restore: Dictionary = lab.get("_highlight_restore")
	_check(restore.size() > 0, "高亮 back_raise 应命中承托甲子树")
	var hinge_hit := false
	if hinge != null:
		for node in hinge.find_children("*", "MeshInstance3D", true, false):
			if restore.has(node):
				hinge_hit = true
	_check(hinge_hit, "高亮 back_raise 应覆盖承托甲子树的网格")
	var hint := String(lab.get("_param_hint"))
	_check(hint.contains("承托甲组抬起角度"), "提示应带参数名，实测：" + hint)
	_check(hint.contains("BackArmorHinge"), "提示应带作用节点，实测：" + hint)
	_check(hint.contains("弹甲投囊"), "提示应带缩短后的作用阶段，实测：" + hint)
	lab.call("_clear_highlight")
	_check((lab.get("_highlight_restore") as Dictionary).is_empty(), "清除后不应残留高亮记录")

	# —— 点击拾取：射线求交必须准，点中就能报出名字与影响它的参数 ——
	var sac_nodes: Array = subject.find_children("LuminousSac*", "MeshInstance3D", true, false)
	_check(sac_nodes.size() > 0, "应能找到晶囊网格")
	var sac: MeshInstance3D = null
	if sac_nodes.size() > 0:
		sac = sac_nodes[0] as MeshInstance3D
	if sac != null:
		var from_behind := sac.global_position + Vector3(0.0, 0.0, 6.0)
		var hit := float(lab.call("_ray_mesh_distance", sac, from_behind, Vector3(0.0, 0.0, -1.0)))
		_check(hit > 0.0, "射向晶囊应命中，实测距离 " + str(hit))
		var miss := float(lab.call("_ray_mesh_distance", sac, from_behind, Vector3(0.0, 0.0, 1.0)))
		_check(miss < 0.0, "背向晶囊的射线不应命中")
		lab.call("_select_mesh", sac)
		_check(lab.get("_selected_mesh") == sac, "选中后应记录该网格")
		var select_hint := String(lab.get("_selection_hint"))
		_check(select_hint.contains("LuminousSac"), "提示应含几何体名称，实测：" + select_hint)
		_check(select_hint.contains("影响参数"), "提示应含影响参数，实测：" + select_hint)
		_check(select_hint.contains("瘪囊"), "点中的几何体自己的参数应排在前面，实测：" + select_hint)
		lab.call("_clear_selection")
		_check(lab.get("_selected_mesh") == null, "清除后不应残留选中")
		_check(sac.material_override != lab.get("_select_material"), "清除后应恢复原材质")

	if "--capture-motion-tools" in OS.get_cmdline_user_args():
		await _capture_motion_tools(lab)
	lab.queue_free()
	await process_frame
	print("Motion Observation Tools: ", "PASS" if failures == 0 else "%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)


## 截图：观察工具的实际画面（时间轴 + 残影），供人工核对渲染结果。
func _capture_motion_tools(lab: Node3D) -> void:
	var output_dir := CapturePaths.ensure_dir("motion_tools")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	# 断言阶段可能把运动分解留在某个档位，截图从固定状态开始。
	lab.set("_motion_decompose", 0)
	lab.call("_clear_ghosts")
	lab.call("_show_subject", _gallery_index_of(lab, BURST_TITLE))
	for frame in range(6):
		await process_frame
	var mount := lab.get_node("SubjectMount") as Node3D
	var model := mount.get_child(0) as Node3D
	model.call("set_preview_pose", 2)
	for frame in range(3):
		await process_frame
	# 倒放后的关键时刻：strike=弹甲瞬间（转身已到 180°），hold=甲完全弹开
	var values: Dictionary = model.get("values")
	var cycle := float(model.call("get_preview_duration"))
	var strike := float(values.turn_duration) / cycle
	var hold := (float(values.turn_duration) + float(values.release) * float(values.release_snap_ratio)) / cycle
	lab.call("_seek_visual", strike)
	lab.call("_unhandled_input", _key(KEY_V))
	for frame in range(8):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(output_dir + "/01_prepare_onion.png")
	# 甲完全弹开、晶囊鼓起的那一帧
	lab.call("_seek_visual", hold)
	for frame in range(6):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(output_dir + "/02_armor_snap.png")
	# 排开：一次看全整轮姿态
	lab.call("_unhandled_input", _key(KEY_V))
	lab.call("_set_distance", 16.0)
	(lab.get_node("CameraRig") as Node3D).rotation.y = 0.0
	lab.call("_seek_visual", hold)
	for frame in range(8):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(output_dir + "/03_strip.png")
	lab.call("_unhandled_input", _key(KEY_V))
	# 参数 → 部位高亮：把「承托甲组抬起角度」指给你看
	lab.call("_seek_visual", hold)
	lab.call("_highlight_field", "back_raise")
	for frame in range(6):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(output_dir + "/04_param_highlight.png")
	lab.call("_clear_highlight")
	# 点击拾取：点中晶囊，报出名字与影响它的参数
	var sac_nodes: Array = model.find_children("LuminousSac*", "MeshInstance3D", true, false)
	if sac_nodes.size() > 0:
		lab.call("_select_mesh", sac_nodes[0] as MeshInstance3D)
		for frame in range(6):
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(output_dir + "/05_click_select.png")
	lab.call("_clear_selection")


func _key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	return event


func _gallery_index_of(lab: Node, title_part: String) -> int:
	var gallery: Array = lab.get("GALLERY")
	for i in range(gallery.size()):
		if String(gallery[i].get("title", "")).contains(title_part):
			return i
	push_error("画廊里找不到条目：" + title_part)
	return 0
