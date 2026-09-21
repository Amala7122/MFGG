extends Node
## 视觉迭代：固定机位自动截图总管（autoload）。
##
## ── 为什么必须是 autoload ──────────────────────────────────────
## 与 graphics_director.gd 同样的理由：它要作用在【每次新场景】上，
## 而主场景是在 autoload 之后才第一次进树的。
##
## ── 什么时候什么都不做 ────────────────────────────────────────
## 没有命令行参数 --vis-capture 时立刻返回。正常游玩不应感受到它：
## 不注册输入、不连事件总线、不进任何分组。
##
## ── 为什么要固定机位 ──────────────────────────────────────────
## 视觉分级只能靠对比。相机一动，同一张地形能拍出完全不同的观感，
## 于是"这一轮是不是变好了"就变成各说各话。相机位姿、等待帧数、
## 是否显示 UI 全部写进配置，每一轮在同一条件下拍同一张图。
##
## ── 为什么必须先等 frame_post_draw 再取画面缓冲 ───────────────
## get_viewport().get_texture().get_image() 取的是【当前渲染目标】。
## 改完相机立刻取，拿到的是上一帧甚至空帧 —— 表现为"三个机位截出来
## 都一样"或干脆全黑。必须等渲染真正提交之后。
##
## ── 顺带做玩法契约自检 ────────────────────────────────────────
## 视觉改动容易顺手破坏玩法（地形重采样 → 坡度超标 → 敌人卡死；
## 新增实体 → 进导航烘焙 → 可走区域变少）。所以每次拍摄都把坡度 /
## 掩体高度 / 导航多边形数打印并写进报告，让"视觉变了但玩法没坏"有据可查。

const ConfigUtil := preload("res://scripts/game_config.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
const TerrainUtil := preload("res://scripts/terrain_field.gd")

const CAPTURE_ARG := "--vis-capture"
const DISPLAY_SETTINGS_ARG := "--vis-display-settings"
const SHOW_UI_ARG := "--vis-show-ui"
const PLAY_ARG := "--vis-play"
const ROUND_PREFIX := "--vis-round="
const ARENA_PREFIX := "--vis-arena="
const SLOPE_SAMPLES := 60

## 截图取样的条数：沿画面正中竖线从上到下取这么多点。
##
## 【为什么要取样，而不是靠肉眼看图】—— "天空是不是比地面亮了""远景有没有
## 变冷"这类判断，人眼比较两张图时很容易被先后顺序骗过去（先看的那个总是
## 显得更对）。固定位置的颜色读数不会骗人，而且能跨轮次直接对着数字比。
const SAMPLE_ROWS := 9


func _ready() -> void:
	if not _wanted():
		return
	_pin_arena()
	call_deferred("_run")


## 【命令行参数的两种落点都必须认】—— 按约定自定义参数跟在 `--` 之后，
## 由 get_cmdline_user_args() 拿到；但不同启动方式下它也可能混进
## get_cmdline_args()。只认一处的话，最典型的故障是"明明传了参数却什么都没发生"。
func _wanted() -> bool:
	return OS.get_cmdline_user_args().has(CAPTURE_ARG) \
		or OS.get_cmdline_args().has(CAPTURE_ARG)


func _show_ui_requested() -> bool:
	return OS.get_cmdline_user_args().has(SHOW_UI_ARG) \
		or OS.get_cmdline_args().has(SHOW_UI_ARG)


func _play_requested() -> bool:
	return OS.get_cmdline_user_args().has(PLAY_ARG) \
		or OS.get_cmdline_args().has(PLAY_ARG)


func _display_settings_requested() -> bool:
	return OS.get_cmdline_user_args().has(DISPLAY_SETTINGS_ARG) \
		or OS.get_cmdline_args().has(DISPLAY_SETTINGS_ARG)


## 锁定要拍的竞技场。必须在场景进树【之前】做 —— 地形是在 scene 的
## _ready() 里按当时的 ArenaUtil.current_id 建出来的。
func _pin_arena() -> void:
	var wanted := _arena_override()
	if wanted.is_empty():
		wanted = ConfigUtil.get_string("visual.arena_id", "")
	if wanted.is_empty():
		return
	ArenaUtil.current_id = wanted


func _run() -> void:
	while get_tree().current_scene == null:
		await get_tree().process_frame
	if _display_settings_requested():
		await _capture_display_settings()
		get_tree().quit()
		return
	if _play_requested():
		# GameFlow._ready() 还会 await 一帧再进入菜单；等它完成后再按开始，
		# 否则我们的 PLAYING 状态会被那次迟到的 _enter_menu() 覆盖。
		for _frame in range(3):
			await get_tree().process_frame
		var old_scene := get_tree().current_scene
		var flow := get_node_or_null("/root/GameFlow")
		if flow != null and flow.has_method("_on_start"):
			flow.call("_on_start")
			for _frame in range(120):
				await get_tree().process_frame
				if get_tree().current_scene != null and get_tree().current_scene != old_scene:
					break
	var scene := get_tree().current_scene

	# 等氛围 / 地形 / 掩体 / 装饰 / 导航烘焙落地。
	# 导航是 navigation_region.gd 里延迟 2 帧同步烘的，这里给足余量。
	var settle := maxi(ConfigUtil.get_int("visual.settle_frames", 150), 1)
	for _frame in range(settle):
		await get_tree().process_frame

	if ConfigUtil.get_bool("visual.hide_ui", true) and not _show_ui_requested():
		_hide_ui(get_tree().root)

	_set_window_size()
	var shots := await _capture_all(scene)
	var report := _build_report(shots)
	var text := _render_report(report)
	print(text)
	_write_report_file(report, text)
	get_tree().quit()


## 显示改造的专用验收图：它拍的不是场景美术，而是 1080p 下真实菜单排版。
## 保留成命令行入口，后续改字体 / 边框 / UI 缩放时可用同一条件复查溢出。
func _capture_display_settings() -> void:
	for _frame in range(4):
		await get_tree().process_frame
	var flow := get_node_or_null("/root/GameFlow")
	if flow == null or not flow.has_method("_on_open_display_settings"):
		push_error("[显示验收] 找不到显示设置页面")
		return
	flow.call("_on_open_display_settings")
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	# 不能按“若干帧”计时：项目不锁帧时 20 帧可能只有二十几毫秒，按钮的
	# 80ms 错峰淡入尚未开始。按真实时间等完完整入场动画再验收。
	await get_tree().create_timer(0.65, true, false, true).timeout
	await RenderingServer.frame_post_draw
	var output_dir := ProjectSettings.globalize_path("res://visual_captures/ui")
	DirAccess.make_dir_recursive_absolute(output_dir)
	_save_display_capture(output_dir.path_join("display_settings_1080.png"))
	# 最大 UI 档位是最容易溢出的情况；不写入个人配置，只在本次验收进程中放大。
	var settings := get_node_or_null("/root/DisplaySettings")
	if settings != null:
		settings.set("ui_scale", 1.3)
		settings.call("_apply_ui_scale")
		flow.call("_enter_display_settings", 2)
	else:
		get_tree().root.content_scale_factor = 1.3
	await get_tree().create_timer(0.65, true, false, true).timeout
	await RenderingServer.frame_post_draw
	_save_display_capture(output_dir.path_join("display_settings_130pct_1080.png"))


func _save_display_capture(path: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		print("[显示验收] %s（%d×%d）" % [path, image.get_width(), image.get_height()])
	else:
		push_error("[显示验收] 截图保存失败：%d" % error)


## 隐藏所有 CanvasLayer（菜单蒙层 / HUD / 准星都会盖住画面）。
## 递归整棵 root：GameFlow 与 PlayerHUD 是 autoload 或挂在别处的
## CanvasLayer，不在 current_scene 里。
func _hide_ui(node: Node) -> void:
	for child in node.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false
		_hide_ui(child)


## 固定窗口尺寸。分辨率不同会改变构图、透视与拉伸强度，不锁死就
## 又回到"两张图没法比"的状态。
func _set_window_size() -> void:
	var raw := ConfigUtil.get_float_array("visual.resolution", [1600.0, 900.0])
	if raw.size() < 2:
		return
	var width := int(float(raw[0]))
	var height := int(float(raw[1]))
	if width < 64 or height < 64:
		return
	DisplayServer.window_set_size(Vector2i(width, height))
	for _frame in range(4):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _capture_all(scene: Node) -> Array:
	var camera := Camera3D.new()
	camera.name = "VisualCaptureCamera"
	scene.add_child(camera)
	camera.make_current()

	var specs := _camera_specs()
	var round_name := _round_name()
	var output_dir := _ensure_output_dir()
	var shots: Array = []
	for entry in specs:
		var spec := entry as Dictionary
		if spec.is_empty():
			continue
		var shot_name := String(spec.get("name", "shot"))
		var position := _read_vec3(spec.get("pos", null), Vector3(0.0, 5.0, 20.0))
		var target := _read_vec3(spec.get("look_at", null), Vector3.ZERO)
		camera.global_position = position
		# 视点与 target 重合时 look_at 会退化出 NaN 基向量。
		if target.distance_to(position) > 0.01:
			camera.look_at(target, Vector3.UP)
		camera.fov = float(spec.get("fov", 60.0))

		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw

		var image := get_viewport().get_texture().get_image()
		var path := "%s/%s_%s.png" % [output_dir, round_name, shot_name]
		var error := image.save_png(path)
		shots.append({
			"name": shot_name,
			"path": path,
			"error": error,
			"width": image.get_width(),
			"height": image.get_height(),
			"column": _sample_column(image),
		})
	return shots


## 沿画面正中竖线取样，返回每行的 "y  颜色  V  S" 文本。
##
## 这串数字直接对应"明度结构"这件事：从上到下的 V 曲线就是画面的
## 明暗骨架，S 曲线就是色彩的克制程度。两者都是可以跨轮次比较的量。
func _sample_column(image: Image) -> Array:
	var out: Array = []
	var x := clampi(int(float(image.get_width()) * 0.5), 0, image.get_width() - 1)
	var height := image.get_height()
	for index in range(SAMPLE_ROWS):
		var ratio := (float(index) + 0.5) / float(SAMPLE_ROWS)
		var y := clampi(int(float(height) * ratio), 0, height - 1)
		var color := image.get_pixel(x, y)
		var value := maxf(maxf(color.r, color.g), color.b)
		var lowest := minf(minf(color.r, color.g), color.b)
		out.append(
			"y=%.2f  (%0.2f,%0.2f,%0.2f)  V=%.2f S=%.2f"
			% [ratio, color.r, color.g, color.b, value, value - lowest]
		)
	return out


## --vis-arena=<id> 临时换一张图拍。用来验证"新增/切换地图不再需要改代码"。
func _arena_override() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with(ARENA_PREFIX):
			return arg.substr(ARENA_PREFIX.length()).strip_edges()
	return ""


func _camera_specs() -> Array:
	var raw: Variant = ConfigUtil.get_dictionary("visual").get("cameras", null)
	if raw is Array:
		return raw as Array
	return []


func _round_name() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with(ROUND_PREFIX):
			var value := arg.substr(ROUND_PREFIX.length()).strip_edges()
			if not value.is_empty():
				return value
	return "0"


## 输出目录先试 res://，写不了再退 user://（导出版本的 res:// 是只读的）。
func _ensure_output_dir() -> String:
	var wanted := ConfigUtil.get_string("visual.output_dir", "res://visual_captures")
	for candidate in [wanted, "user://visual_captures"]:
		var absolute := ProjectSettings.globalize_path(candidate)
		var error := DirAccess.make_dir_recursive_absolute(absolute)
		if error != OK and error != ERR_ALREADY_EXISTS:
			continue
		if DirAccess.open(absolute) != null:
			return candidate
	push_error("[拍摄] 输出目录创建失败，仍尝试写入 %s" % wanted)
	return wanted


# ---------------------------------------------------------------- 契约自检

func _build_report(shots: Array) -> Dictionary:
	return {
		"round": _round_name(),
		"arena": ArenaUtil.resolve_id(),
		"engine": String(Engine.get_version_info().get("string", "?")),
		"checks": _collect_checks(get_tree().current_scene),
		"shots": shots,
	}


func _collect_checks(scene: Node) -> Array:
	var lines: Array = []

	# 1) 地形坡度："地形怎么改敌人还能走"的唯一硬指标，
	#    navigation.agent_max_slope 写的就是 45°。
	var worst := _max_slope_degrees()
	var max_angle := float(worst.get("angle", 0.0))
	var where := worst.get("at", Vector2.ZERO) as Vector2
	# 【必须报出坐标】—— 只报一个角度的话，超标时无从下手：是山丘太陡、
	# 还是遮罩过渡太窄、还是两块遮罩接缝对不齐，全都表现为"某个角度很大"。
	# 有了坐标就能直接对着 terrain 参数判断是哪一类。
	lines.append(
		"地形最大坡度 %.1f°（红线 45°）%s　最陡处 x=%.0f z=%.0f"
		% [max_angle, " ✔" if max_angle <= 45.0 else " ✘ 超标", where.x, where.y]
	)

	# 2) 掩体数量与高度区间。低于 2.2 米挡不住站立姿态的互相视线，
	#    高于 2.8 米会把战场切成迷宫（敌人无寻路会卡死）。见 field_cover.gd。
	var cover := scene.find_child("Cover", true, false)
	var count := 0
	var highest := 0.0
	if cover != null:
		for body in cover.get_children():
			if not (body is StaticBody3D):
				continue
			count += 1
			highest = maxf(highest, _body_height(body as StaticBody3D))
	lines.append("掩体 %d 个，最高 %.2f m（有效区间 2.2~2.6）" % [count, highest])

	# 3) 导航多边形数。最容易被新增实体静默破坏的一项：烘焙"成功"但
	#    产出空网格时敌人完全不动，而画面上看不出异常。
	var nav := _find_nav_region(scene)
	if nav == null or nav.navigation_mesh == null:
		lines.append("导航网格未生成 ✘")
	else:
		var polygons := nav.navigation_mesh.get_polygon_count()
		lines.append(
			"导航多边形数 %d %s" % [polygons, " ✔" if polygons > 0 else " ✘ 空网格"]
		)

	# 4) 网格实例数：新增视觉内容要能回答"代价是多少"。
	var meshes := scene.find_children("*", "MeshInstance3D", true, false).size()
	lines.append("场景 MeshInstance3D 数量 %d" % meshes)
	return lines


## 返回 { "angle": 度, "at": Vector2(x, z) }。
func _max_slope_degrees() -> Dictionary:
	var extent := TerrainUtil.get_extent()
	var step := (extent * 2.0) / float(SLOPE_SAMPLES)
	var worst := 0.0
	var worst_at := Vector2.ZERO
	for iz in range(SLOPE_SAMPLES + 1):
		var z := -extent + step * float(iz)
		for ix in range(SLOPE_SAMPLES + 1):
			var x := -extent + step * float(ix)
			# normal_at 返回的是归一化朝上向量，y 分量即 cos(倾角)。
			var normal := TerrainUtil.normal_at(x, z)
			var angle := rad_to_deg(acos(clampf(normal.y, -1.0, 1.0)))
			if angle > worst:
				worst = angle
				worst_at = Vector2(x, z)
	return {"angle": worst, "at": worst_at}


func _body_height(body: StaticBody3D) -> float:
	for child in body.get_children():
		if not (child is CollisionShape3D):
			continue
		var shape := (child as CollisionShape3D).shape
		if shape is BoxShape3D:
			return (shape as BoxShape3D).size.y
		if shape is SphereShape3D:
			return (shape as SphereShape3D).radius
	return 0.0


func _find_nav_region(node: Node) -> NavigationRegion3D:
	if node is NavigationRegion3D:
		return node as NavigationRegion3D
	for child in node.get_children():
		var found := _find_nav_region(child)
		if found != null:
			return found
	return null


# ---------------------------------------------------------------- 输出

func _render_report(report: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("──────── 视觉拍摄报告 ────────")
	lines.append("轮次 = %s" % String(report.get("round", "?")))
	lines.append("竞技场 = %s" % String(report.get("arena", "?")))
	lines.append("引擎 = %s" % String(report.get("engine", "?")))
	lines.append("")
	lines.append("【玩法契约自检】")
	for line in report.get("checks", []) as Array:
		lines.append("  " + String(line))
	lines.append("")
	lines.append("【截图与中轴取样】")
	for shot in report.get("shots", []) as Array:
		var entry := shot as Dictionary
		var code := int(entry.get("error", 0))
		lines.append(
			"  %s  %s  %s"
			% [
				String(entry.get("name", "?")),
				"%dx%d" % [int(entry.get("width", 0)), int(entry.get("height", 0))],
				"✔ " + String(entry.get("path", "?")) if code == OK \
					else "✘ 保存失败 code=%d" % code,
			]
		)
		for row in entry.get("column", []) as Array:
			lines.append("      " + String(row))
	lines.append("─────────────────────────────")
	return "\n".join(lines)


func _write_report_file(report: Dictionary, text: String) -> void:
	var directory := _ensure_output_dir()
	var path := "%s/%s_report.txt" % [directory, String(report.get("round", "0"))]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[拍摄] 报告写入失败：%s" % path)
		return
	file.store_string(text + "\n")
	file.close()


## [x, y, z] → Vector3。数组写错长度时退回 fallback。
func _read_vec3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var parts := value as Array
		return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	return fallback
