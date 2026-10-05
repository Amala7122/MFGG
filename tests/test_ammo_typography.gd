extends SceneTree
## 字形空间回归：斜体只改变 x；所有数字和斜杠的 y / 基线必须原样保留。
const Weapon := preload("res://scripts/weapon_panel.gd")
const CapturePaths := preload("res://scripts/capture_paths.gd")

class TypographyComparison extends Control:
	var before_font: Font
	var after_font: Font
	var caption_font: Font

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.13, 0.14))
		for row in 2:
			var baseline := 135.0 + row * 175.0
			var font := before_font if row == 0 else after_font
			var caption := "修改前：纵向错切" if row == 0 else "修改后：仅字形向右倾，基线水平"
			draw_string(caption_font, Vector2(36, baseline - 80), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.8, 0.85, 0.9))
			draw_line(Vector2(36, baseline), Vector2(900, baseline), Color(0.2, 0.75, 0.85, 0.65), 1)
			draw_string(font, Vector2(48, baseline), "30", HORIZONTAL_ALIGNMENT_LEFT, -1, 72, Color.WHITE)
			draw_string(font, Vector2(165, baseline), "/ 30", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color.WHITE)
			draw_string(font, Vector2(320, baseline), "45678", HORIZONTAL_ALIGNMENT_LEFT, -1, 72, Color.WHITE)

func _initialize() -> void:
	var italic := Weapon.make_number_font()
	var upright := FontVariation.new()
	upright.base_font = italic.base_font
	upright.variation_opentype = italic.variation_opentype.duplicate()
	var wrong := FontVariation.new()
	wrong.base_font = italic.base_font
	wrong.variation_opentype = italic.variation_opentype.duplicate()
	wrong.variation_transform = Transform2D(Vector2(1, 0), Vector2(Weapon.NUMBER_SLANT, 1), Vector2.ZERO)
	var server := TextServerManager.get_primary_interface()
	var checked := 0
	var old_vertical_drift := 0.0
	for font_size in [23, 35, 46, 60]:
		for character in "0123456789/":
			var code := character.unicode_at(0)
			var normal_index := server.font_get_glyph_index(upright.get_rids()[0], font_size, code, 0)
			var italic_index := server.font_get_glyph_index(italic.get_rids()[0], font_size, code, 0)
			var wrong_index := server.font_get_glyph_index(wrong.get_rids()[0], font_size, code, 0)
			var normal_data := server.font_get_glyph_contours(upright.get_rids()[0], font_size, normal_index)
			var italic_data := server.font_get_glyph_contours(italic.get_rids()[0], font_size, italic_index)
			var wrong_data := server.font_get_glyph_contours(wrong.get_rids()[0], font_size, wrong_index)
			var normal_points: PackedVector3Array = normal_data.get("points", PackedVector3Array())
			var italic_points: PackedVector3Array = italic_data.get("points", PackedVector3Array())
			var wrong_points: PackedVector3Array = wrong_data.get("points", PackedVector3Array())
			if normal_points.is_empty() or normal_points.size() != italic_points.size():
				push_error("字形轮廓缺失：%s / %d" % [character, font_size])
				quit(1)
				return
			for i in normal_points.size():
				var before := normal_points[i]
				var after := italic_points[i]
				old_vertical_drift = maxf(old_vertical_drift, absf(wrong_points[i].y - before.y))
				# TextServer 返回屏幕空间（y 向下），所以期望 x'=x-s*y。
				if absf(after.y - before.y) > 0.02 or absf(after.x - (before.x - Weapon.NUMBER_SLANT * before.y)) > 0.04:
					push_error("斜体变换改变了纵坐标或方向：%s / %d / %d" % [character, font_size, i])
					quit(1)
					return
			checked += 1
	if old_vertical_drift < 1.0:
		push_error("负对照未检测出旧变换的纵向错切")
		quit(1)
		return
	print("[弹药字形] %d 个字形/字号组合通过：仅横向倾斜，纵坐标和基线不变" % checked)
	print("[负对照] 旧变换最大纵向偏移 %.2f 像素，已被检测到" % old_vertical_drift)
	if "--capture" in OS.get_cmdline_user_args():
		call_deferred("_capture", wrong, italic, upright)
	else:
		quit()


func _capture(before: Font, after: Font, caption: Font) -> void:
	var game_flow := root.get_node("GameFlow")
	game_flow.visible = false
	game_flow.process_mode = Node.PROCESS_MODE_DISABLED
	paused = false
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(960, 370)
	root.content_scale_size = Vector2i(960, 370)
	root.content_scale_factor = 1.0
	var comparison := TypographyComparison.new()
	comparison.before_font = before
	comparison.after_font = after
	comparison.caption_font = caption
	comparison.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(comparison)
	for i in 12:
		await process_frame
	# DisplaySettings 的启动回调可能晚于 _capture，等它完成后固定截图尺寸。
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(960, 370)
	root.content_scale_factor = 1.0
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var dir := CapturePaths.ensure_dir("hud_review")
	var path := dir.path_join("ammo_typography.png")
	root.get_texture().get_image().save_png(path)
	print("[字形对照] ", path)
	quit()
