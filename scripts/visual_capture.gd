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
const CapturePaths := preload("res://scripts/capture_paths.gd")
const ArenaUtil := preload("res://scripts/arena.gd")
const TerrainUtil := preload("res://scripts/terrain_field.gd")

const CAPTURE_ARG := "--vis-capture"
const DISPLAY_SETTINGS_ARG := "--vis-display-settings"
const GAME_OVER_ARG := "--vis-game-over"
const SHOW_UI_ARG := "--vis-show-ui"
const PLAY_ARG := "--vis-play"
const ROSTER_ARG := "--vis-roster"
const ROSTER_STRIP_ARG := "--vis-roster-strip"
const HIDE_PREFIX := "--vis-hide="
const ROUND_PREFIX := "--vis-round="
const ARENA_PREFIX := "--vis-arena="
const RESOLUTION_PREFIX := "--vis-resolution="
const ONLY_PREFIX := "--vis-only="
const RENDER_SCALE_PREFIX := "--vis-render-scale="
const UPSCALER_PREFIX := "--vis-upscaler="
const SLOPE_SAMPLES := 60

## 截图取样的条数：沿画面正中竖线从上到下取这么多点。
##
## 【为什么要取样，而不是靠肉眼看图】—— "天空是不是比地面亮了""远景有没有
## 变冷"这类判断，人眼比较两张图时很容易被先后顺序骗过去（先看的那个总是
## 显得更对）。固定位置的颜色读数不会骗人，而且能跨轮次直接对着数字比。
const SAMPLE_ROWS := 9


func _ready() -> void:
	if not _wanted() and not _roster_wanted():
		return
	_pin_arena()
	if _roster_wanted():
		call_deferred("_run_roster")
		return
	call_deferred("_run")


## 【命令行参数的两种落点都必须认】—— 按约定自定义参数跟在 `--` 之后，
## 由 get_cmdline_user_args() 拿到；但不同启动方式下它也可能混进
## get_cmdline_args()。只认一处的话，最典型的故障是"明明传了参数却什么都没发生"。
func _wanted() -> bool:
	return OS.get_cmdline_user_args().has(CAPTURE_ARG) \
		or OS.get_cmdline_args().has(CAPTURE_ARG)


## 图鉴陈列：不拍场景，拍【敌人队列】。见 _run_roster。
func _roster_wanted() -> bool:
	return OS.get_cmdline_user_args().has(ROSTER_ARG) \
		or OS.get_cmdline_args().has(ROSTER_ARG)


## 剥离测试：护甲色统一成中性灰 + 隐藏头顶名字，只留形状。
func _roster_strip_requested() -> bool:
	return OS.get_cmdline_user_args().has(ROSTER_STRIP_ARG) \
		or OS.get_cmdline_args().has(ROSTER_STRIP_ARG)


func _show_ui_requested() -> bool:
	return OS.get_cmdline_user_args().has(SHOW_UI_ARG) \
		or OS.get_cmdline_args().has(SHOW_UI_ARG)


func _play_requested() -> bool:
	return OS.get_cmdline_user_args().has(PLAY_ARG) \
		or OS.get_cmdline_args().has(PLAY_ARG)


func _display_settings_requested() -> bool:
	return OS.get_cmdline_user_args().has(DISPLAY_SETTINGS_ARG) \
		or OS.get_cmdline_args().has(DISPLAY_SETTINGS_ARG)


func _game_over_requested() -> bool:
	return OS.get_cmdline_user_args().has(GAME_OVER_ARG) \
		or OS.get_cmdline_args().has(GAME_OVER_ARG)


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
	_apply_capture_render_scale()
	if _display_settings_requested():
		await _capture_display_settings()
		get_tree().quit()
		return
	if _game_over_requested():
		await _capture_game_over()
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

	_hide_requested_nodes(scene)
	await _set_window_size()
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
	var resolution := _capture_resolution()
	var settings := get_node_or_null("/root/DisplaySettings")
	if settings != null:
		# 验收进程不会存盘；让设置项如实显示当前模拟窗口尺寸。
		settings.set("window_resolution", resolution)
	flow.call("_on_open_display_settings")
	DisplayServer.window_set_size(resolution)
	# 不能按“若干帧”计时：项目不锁帧时 20 帧可能只有二十几毫秒，按钮的
	# 80ms 错峰淡入尚未开始。按真实时间等完完整入场动画再验收。
	await get_tree().create_timer(0.65, true, false, true).timeout
	await RenderingServer.frame_post_draw
	var output_dir := CapturePaths.ensure_dir("ui")
	var tag := "%d_%d" % [resolution.x, resolution.y]
	_save_display_capture(output_dir.path_join("display_settings_%s.png" % tag))
	# 最大 UI 档位是最容易溢出的情况；不写入个人配置，只在本次验收进程中放大。
	if settings != null:
		settings.set("ui_scale", 1.3)
		settings.call("_apply_ui_scale")
		flow.call("_enter_display_settings", 3)
	else:
		get_tree().root.content_scale_factor = 1.3
	await get_tree().create_timer(0.65, true, false, true).timeout
	await RenderingServer.frame_post_draw
	_save_display_capture(output_dir.path_join("display_settings_130pct_%s.png" % tag))


func _save_display_capture(path: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		print("[显示验收] %s（%d×%d）" % [path, image.get_width(), image.get_height()])
	else:
		push_error("[显示验收] 截图保存失败：%d" % error)


## 不调用成绩提交，只显示与真实阵亡页同一套排版；同时验收最大 UI 缩放。
func _capture_game_over() -> void:
	for _frame in range(4):
		await get_tree().process_frame
	var flow := get_node_or_null("/root/GameFlow")
	if flow == null or not flow.has_method("_preview_game_over"):
		push_error("[结算验收] 找不到阵亡页预览入口")
		return
	flow.call("_preview_game_over")
	var resolution := _capture_resolution()
	DisplayServer.window_set_size(resolution)
	var output_dir := CapturePaths.ensure_dir("ui")
	var tag := "%d_%d" % [resolution.x, resolution.y]
	await get_tree().create_timer(0.65, true, false, true).timeout
	await RenderingServer.frame_post_draw
	_save_display_capture(output_dir.path_join("game_over_%s.png" % tag))
	var settings := get_node_or_null("/root/DisplaySettings")
	if settings != null:
		settings.set("ui_scale", 1.3)
		settings.call("_apply_ui_scale")
	else:
		get_tree().root.content_scale_factor = 1.3
	await get_tree().create_timer(0.35, true, false, true).timeout
	await RenderingServer.frame_post_draw
	_save_display_capture(output_dir.path_join("game_over_130pct_%s.png" % tag))


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
	DisplayServer.window_set_size(_capture_resolution())
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
		var only := _arg_value(ONLY_PREFIX)
		if not only.is_empty() and shot_name != only:
			continue
		var position := _read_vec3(spec.get("pos", null), Vector3(0.0, 5.0, 20.0))
		# 地形重构后旧的低机位可能埋入坡地，按实际地面保留最低眼高。
		if absf(position.x) <= TerrainUtil.get_extent() and absf(position.z) <= TerrainUtil.get_extent():
			position.y = maxf(position.y, TerrainUtil.height_at(position.x, position.z) + 1.7)
		var target := _read_vec3(spec.get("look_at", null), Vector3.ZERO)
		camera.global_position = position
		# 视点与 target 重合时 look_at 会退化出 NaN 基向量。
		if target.distance_to(position) > 0.01:
			camera.look_at(target, Vector3.UP)
		camera.fov = float(spec.get("fov", 60.0))
		# 拍摄时场景树暂停，草地不会自动跑距离刷新；用当前镜头更新静态 LOD。
		var grass := scene.get_node_or_null("Grass")
		if grass != null and grass.has_method("_update_visibility"):
			grass.set("_observer_points", [Vector2(position.x, position.z)])
			grass.call("_update_visibility")

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


func _capture_resolution() -> Vector2i:
	var raw := _arg_value(RESOLUTION_PREFIX).to_lower().split("x")
	if raw.size() == 2 and raw[0].is_valid_int() and raw[1].is_valid_int():
		var width := int(raw[0])
		var height := int(raw[1])
		if width >= 640 and height >= 480:
			return Vector2i(width, height)
	var configured := ConfigUtil.get_float_array("visual.resolution", [1920.0, 1080.0])
	if configured.size() < 2:
		return Vector2i(1920, 1080)
	return Vector2i(int(configured[0]), int(configured[1]))


func _apply_capture_render_scale() -> void:
	var raw := _arg_value(RENDER_SCALE_PREFIX)
	if raw.is_empty():
		return
	var percentage := clampf(raw.to_float(), 50.0, 100.0)
	var viewport := get_tree().root
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR \
		if _arg_value(UPSCALER_PREFIX) == "bilinear" else Viewport.SCALING_3D_MODE_FSR
	viewport.scaling_3d_scale = percentage / 100.0
	print("[拍摄] 3D %d%%，模式 %s" % [roundi(percentage), _arg_value(UPSCALER_PREFIX)])


func _arg_value(prefix: String) -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length()).strip_edges()
	return ""


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


## 开发版写到项目同级目录；导出版使用可写的 user:// 目录。
func _ensure_output_dir() -> String:
	var wanted := ConfigUtil.get_string("visual.output_dir", "../visual_captures")
	var configured := CapturePaths.root()
	if not OS.has_feature("standalone") and wanted != "../visual_captures":
		if wanted.begins_with("res://") or wanted.begins_with("user://"):
			configured = ProjectSettings.globalize_path(wanted)
		elif wanted.is_absolute_path():
			configured = wanted
		else:
			configured = ProjectSettings.globalize_path("res://").path_join(wanted).simplify_path()
	for absolute in [configured, CapturePaths.root(), ProjectSettings.globalize_path("user://visual_captures")]:
		var error := DirAccess.make_dir_recursive_absolute(absolute)
		if error != OK and error != ERR_ALREADY_EXISTS:
			continue
		if DirAccess.open(absolute) != null:
			return absolute
	push_error("[拍摄] 输出目录创建失败，仍尝试写入 %s" % wanted)
	return configured


# ---------------------------------------------------------------- 图鉴陈列

## 【为什么要有这个模式】
## "敌人的辨识度"是一个必须在【同一条件】下横向比较的东西：同一排站位、
## 同一批机位、同一段距离。否则"这一轮改完是不是更好"只能靠记忆和感觉，
## 而记忆恰恰会被先后顺序骗过去（先看到的那个总是显得更对）。
##
## 它拍的不是场景，是队列：把所有图鉴条目按体型从小到大摆成一排，用远/中/近
## 三档机位拍下来。中距离那张是主验收图 —— 在那个像素高度上还能不能区分剪影，
## 就是"30 米外能不能认出它"的答案。
##
## --vis-roster-strip 会额外把护甲色统一成中性灰、隐藏头顶名字：
## 去掉颜色与文字之后剩下的形状，才是真正属于"这个兵种"的信息量。
func _run_roster() -> void:
	while get_tree().current_scene == null:
		await get_tree().process_frame
	var settle := maxi(ConfigUtil.get_int("visual.settle_frames", 150), 1)
	for _frame in range(settle):
		await get_tree().process_frame
	_hide_ui(get_tree().root)
	await _set_window_size()
	var cfg := ConfigUtil.get_dictionary("visual.roster")
	_hide_roster_clutter(cfg)
	var strip := _roster_strip_requested()
	var order := await _spawn_roster_lineup(cfg, strip)
	if order.is_empty():
		push_error("[陈列] 队列为空：检查 visual.roster.lineup 与 enemy_roster.entries")
		get_tree().quit()
		return
	var shots := await _capture_roster_shots(cfg, order)
	var text := _render_roster_report(order, shots, strip)
	print(text)
	_write_roster_report(text)
	get_tree().quit()


## --vis-hide=<节点名>：在拍摄前隐藏指定节点（可重复）。
##
## 【为什么需要它】对照实验是排查"这个红色的东西是谁画的"最省事的办法：
## 把候选来源逐个关掉再拍同一机位，哪一次它消失了，答案就是那个。
## 它比读代码猜快得多 —— 尤其是当同一个画面里有一堆半透明加色叠加物的时候。
func _hide_requested_nodes(scene: Node) -> void:
	var wanted: Array[String] = []
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with(HIDE_PREFIX):
			var name := arg.substr(HIDE_PREFIX.length()).strip_edges()
			if not name.is_empty():
				wanted.append(name)
	for node_name in wanted:
		var node := scene.find_child(node_name, true, false) as Node3D
		if node == null:
			print("[拍摄] --vis-hide=%s：场景里没有这个节点" % node_name)
			continue
		node.visible = false
		print("[拍摄] 已隐藏节点 %s（路径 %s）" % [node_name, str(scene.get_path_to(node))])


## 陈列图的主体是敌人，不是关卡。掩体与陈设会挡人，也会让两轮之间的背景变来变去，
## 所以这个模式下把它们收起来（只留地面 / 道路 / 远景），保证"同一条件"这条前提。
func _hide_roster_clutter(cfg: Dictionary) -> void:
	var names: Array = cfg.get("hide_nodes", ["Cover", "MapContent"])
	var scene := get_tree().current_scene
	for item in names:
		var node := scene.find_child(String(item), true, false) as Node3D
		if node != null:
			node.visible = false


## 队列顺序：默认"先近战、再远程，各自体型从小到大" —— 陈列图要能一眼扫完，
## 而不是被解锁顺序打散。也可以在 visual.roster.lineup 里显式指定。
func _roster_entries(cfg: Dictionary) -> Array:
	var roster := ConfigUtil.get_dictionary("enemy_roster")
	var all: Array = roster.get("entries", []) as Array
	var wanted: Array = cfg.get("lineup", []) as Array
	var out: Array = []
	if not wanted.is_empty():
		for id in wanted:
			var found := _find_entry(all, String(id))
			if not found.is_empty():
				out.append(found)
		return out
	var melee: Array = []
	var ranged: Array = []
	for item in all:
		if not (item is Dictionary):
			continue
		var entry := item as Dictionary
		if String(entry.get("kind", "melee")) == "melee":
			melee.append(entry)
		else:
			ranged.append(entry)
	melee.sort_custom(_sort_by_scale)
	ranged.sort_custom(_sort_by_scale)
	out.append_array(melee)
	out.append_array(ranged)
	return out


func _sort_by_scale(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("scale", 1.0)) < float(b.get("scale", 1.0))


func _find_entry(entries: Array, id: String) -> Dictionary:
	for item in entries:
		if item is Dictionary and String((item as Dictionary).get("id", "")) == id:
			return item as Dictionary
	return {}


## 摆队列并冻结。冻结是为了让画面可重复：敌人一走动，两轮之间的画面就不可比。
## 注意 y 是【直接摆到位】而不是让它落地 —— 菜单状态下场景是暂停的（重力不跑），
## 靠物理落位会永远浮在空中。
func _spawn_roster_lineup(cfg: Dictionary, strip: bool) -> Array:
	var scene := get_tree().current_scene
	var spawner := scene.find_child("EnemySpawner", true, false)
	if spawner == null or not spawner.has_method("spawn_enemy"):
		push_error("[陈列] 场景里找不到 EnemySpawner")
		return []
	var entries := _roster_entries(cfg)
	var spacing := maxf(float(cfg.get("spacing", 2.7)), 0.5)
	var base_z := float(cfg.get("z", -14.0))
	var origin_x := float(cfg.get("origin_x", 0.0))
	var yaw := deg_to_rad(float(cfg.get("yaw_degrees", 180.0)))
	var stand := maxf(ConfigUtil.get_float("spawn.enemy_stand_clearance", 1.2), 0.5)
	var count := entries.size()
	var spawned: Array = []
	# 报告要的是"左 → 右分别是哪一条"，所以返回的是条目表而不是节点表。
	var placed: Array = []
	for index in range(count):
		var entry := entries[index] as Dictionary
		var x := origin_x + (float(index) - float(count - 1) * 0.5) * spacing
		var enemy := spawner.call("spawn_enemy", entry, Vector3(x, 0.0, base_z), 1.0) as Node3D
		if enemy == null:
			continue
		spawned.append(enemy)
		placed.append(entry)
	# 等 3 帧：configure / apply_body_profile 是 call_deferred 的，要等它们跑完。
	for _frame in range(3):
		await get_tree().process_frame
	for index in range(spawned.size()):
		var enemy := spawned[index] as Node3D
		var x := origin_x + (float(index) - float(spawned.size() - 1) * 0.5) * spacing
		# 站高 = 胶囊半高（1.0）。用 stand_clearance 会让脚离地 20 公分。
		var foot := TerrainUtil.height_at(x, base_z)
		enemy.set_physics_process(false)
		enemy.global_position = Vector3(x, foot + 1.0, base_z)
		enemy.rotation = Vector3(0.0, yaw, 0.0)
		if strip:
			_strip_enemy(enemy)
	return placed


## 剥离测试：把护甲色与自发光统一压成中性灰，并隐藏头顶血条/名字。
## 改的是材质实例（场景材质是 resource_local_to_scene），不会串到别的敌人。
func _strip_enemy(enemy: Node3D) -> void:
	var label := enemy.find_child("HealthLabel", true, false) as Label3D
	if label != null:
		label.visible = false
	var neutral := Color(0.62, 0.63, 0.66, 1.0)
	for child in enemy.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh == null or not (mesh.material_override is StandardMaterial3D):
			continue
		var material := mesh.material_override as StandardMaterial3D
		material.albedo_color = neutral
		if material.emission_enabled:
			material.emission = Color(0.86, 0.88, 0.92, 1.0)
	# 自发光部件往往还带一盏点光（枪口 / 能量核）。形状测试里它会在敌人周围
	# 染出一圈颜色，"剥离"就不彻底了 —— 一并关掉。
	for child in enemy.find_children("*", "OmniLight3D", true, false):
		(child as OmniLight3D).light_energy = 0.0


## 三档机位：远（整排 / 剪影检查）、中（两段 / 主验收）、近（四段 / 细节）。
## 距离由"要覆盖多宽"反推，所以条数变了也不用改机位。
func _capture_roster_shots(cfg: Dictionary, order: Array) -> Array:
	var scene := get_tree().current_scene
	var camera := Camera3D.new()
	camera.name = "RosterCamera"
	scene.add_child(camera)
	camera.make_current()

	var spacing := maxf(float(cfg.get("spacing", 2.7)), 0.5)
	var base_z := float(cfg.get("z", -14.0))
	var origin_x := float(cfg.get("origin_x", 0.0))
	var row_width := maxf(float(order.size() - 1) * spacing, 4.0)
	var aspect := _viewport_aspect()
	var round_name := _round_name()
	var output_dir := _ensure_output_dir()
	var shots: Array = []
	for item in _roster_shot_specs(cfg):
		var spec := item as Dictionary
		var panels := maxi(int(spec.get("panels", 1)), 1)
		var fov := float(spec.get("fov", 34.0))
		var height := float(spec.get("height", 2.4))
		var focus_y := float(spec.get("focus_y", 1.6))
		var covered := maxf(row_width / float(panels) * 1.14, 6.0)
		var distance := _distance_for_width(covered, fov, aspect)
		for panel in range(panels):
			var center_x := origin_x - row_width * 0.5 \
				+ row_width * (float(panel) + 0.5) / float(panels)
			camera.global_position = Vector3(center_x, height, base_z + distance)
			camera.look_at(Vector3(center_x, focus_y, base_z), Vector3.UP)
			camera.fov = fov
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var image := get_viewport().get_texture().get_image()
			var shot_name := "%s_%s" % [String(spec.get("name", "shot")), panel]
			var path := "%s/%s_%s.png" % [output_dir, round_name, shot_name]
			var error := image.save_png(path)
			shots.append({
				"name": shot_name,
				"path": path,
				"error": error,
				"width": image.get_width(),
				"height": image.get_height(),
				"distance": distance,
			})
	return shots


func _roster_shot_specs(cfg: Dictionary) -> Array:
	var raw: Variant = cfg.get("shots", null)
	if raw is Array and not (raw as Array).is_empty():
		return raw as Array
	return [
		{"name": "far", "panels": 1, "fov": 30.0, "height": 3.4, "focus_y": 1.8},
		{"name": "mid", "panels": 2, "fov": 34.0, "height": 2.4, "focus_y": 1.6},
		{"name": "near", "panels": 4, "fov": 40.0, "height": 1.9, "focus_y": 1.5},
	]


## 让 width 米的东西正好填满画面【横向】。Camera3D.fov 是纵向视场角，
## 所以横向半角要先按宽高比换算。
func _distance_for_width(width_m: float, fov_deg: float, aspect: float) -> float:
	var half_v := deg_to_rad(fov_deg) * 0.5
	var half_h := atan(tan(half_v) * maxf(aspect, 0.1))
	return (width_m * 0.5) / maxf(tan(half_h), 0.0001)


func _viewport_aspect() -> float:
	var size := get_viewport().get_visible_rect().size
	if size.y <= 1.0:
		return 16.0 / 9.0
	return size.x / size.y


func _render_roster_report(order: Array, shots: Array, strip: bool) -> String:
	var lines := PackedStringArray()
	lines.append("──────── 图鉴陈列报告 ────────")
	lines.append("轮次 = %s" % _round_name())
	lines.append("竞技场 = %s" % ArenaUtil.resolve_id())
	lines.append("剥离模式 = %s" % ("开（中性灰 + 隐藏名字）" if strip else "关（护甲色 + 头顶名字）"))
	lines.append("")
	lines.append("【队列（左 → 右）】")
	for index in range(order.size()):
		var entry := order[index] as Dictionary
		lines.append("  %2d. %-18s %-10s scale=%.2f profile=%s" % [
			index + 1,
			String(entry.get("id", "?")),
			String(entry.get("title", "?")),
			float(entry.get("scale", 1.0)),
			String(entry.get("profile", "-")),
		])
	lines.append("")
	lines.append("【截图】")
	for item in shots:
		var shot := item as Dictionary
		lines.append("  %-8s %sx%s 距离 %.1fm  %s" % [
			String(shot.get("name", "?")),
			int(shot.get("width", 0)),
			int(shot.get("height", 0)),
			float(shot.get("distance", 0.0)),
			String(shot.get("path", "?")),
		])
	lines.append("─────────────────────────────")
	return "\n".join(lines)


func _write_roster_report(text: String) -> void:
	var path := "%s/%s_roster.txt" % [_ensure_output_dir(), _round_name()]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[陈列] 报告写入失败：%s" % path)
		return
	file.store_string(text + "\n")
	file.close()


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
