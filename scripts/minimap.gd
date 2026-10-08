class_name Minimap
extends Control
## 小地图（右上角）：地形缩略图 + 敌人光点 + 玩家朝向箭头。
##
## 三个设计取舍：
##
##   1. **正北朝上**（不随视角旋转）。旋转式雷达看起来更"专业"，但在这个以掩体
##      走位为核心的玩法里，固定方位参考更利于建立"敌人在战场的哪一边"的空间记忆；
##      而且旋转会连带把地形缩略图转起来，读起来反而更费劲。
##
##   2. **地形只烘一次**。height_at() 每次调用要做十几次三角函数（三层正弦 +
##      6 座山丘的 sqrt），放进每帧绘制是灾难。这里启动时烘成 TEX_SIZE² 的缩略图，
##      之后每帧只做一次裁剪平移。
##
##   3. **玩家居中，贴近地形边界时地图停止滚动**。否则采样框会超出贴图范围，
##      边缘会出现空白或拉伸。这也是绝大多数游戏的处理方式。
##
## 地形底图之外再叠加配置中的道路与主要遗迹：玩家看到的是一张微缩地图，
## 不再是一块只有高低色阶的绿色雷达底。

const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const UiThemeUtil := preload("res://scripts/ui_theme.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const ArenaUtil := preload("res://scripts/arena.gd")

const TEX_SIZE := 512
## 小地图显示的世界半径上限（米）。必须明显小于地形半宽，否则采样框会超出贴图。
## 实际取值还会按当前竞技场的体量收紧（见 _ready）。
const WORLD_RANGE_MAX := 52.0
## 控件边长与距屏幕边距（由 PlayerHUD 用来摆位）。
const PANEL_SIZE := 162.0
const PANEL_HEIGHT := 148.0
const MARGIN := 22.0
const TOP_MARGIN := 20.0

const BLIP_RADIUS := 2.2
const PICKUP_RADIUS := 1.8
const ARROW_RADIUS := 5.0
## 敌人稀少且已经落到小地图外时，用贴边三角指出其真实方向。
## 标志中心内缩一个三角高度，保证尖端恰好贴边而不会被内容区裁掉。
const ENEMY_DIRECTION_MARKER_SIZE := 5.5
const ENEMY_DIRECTION_MARKER_INSET := ENEMY_DIRECTION_MARKER_SIZE + 1.5
## 小地图不是准星，不需要跟 900 FPS 一起重画。20Hz 足够连续，同时把
## 每秒数千次的分组查询压到固定上限。
const REFRESH_INTERVAL := 1.0 / 20.0

## 地形与黑玻璃断面之间的极窄留白。它只负责收住贴图边缘，不形成外框。
const FRAME := 0.0

var _terrain_texture: ImageTexture
var _player: Node3D
var _camera: Camera3D
## 当前竞技场的地形半宽与显示半径。都在 _ready 里定一次 ——
## 竞技场在一次场景生命周期内不会变。
var _extent := 60.0
var _world_range := 52.0
var _enemy_direction_limit := 5
var _refresh_time := 0.0
var _roads: Array = []
var _props: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	# 必须每帧请求重绘：Control 只在进入场景树时自动绘制一次，
	# 不主动标记脏就永远不重画 —— 小地图会一直显示第一帧的静态画面。
	# 项目里其它绘制控件（准星 / 命中标记 / 受击方向 / 武器面板）都自己调
	# queue_redraw()，这里之前漏了。
	set_process(true)
	_extent = TerrainFieldUtil.get_extent()
	# 收紧到地形半宽的 0.85：留出边距，保证 src 采样框永远能完整落在贴图内
	# （否则 clamp 的上下界会反过来，玩家一格都画不出来）。
	_world_range = minf(
		minf(ConfigUtil.get_float("ui.minimap_world_range", WORLD_RANGE_MAX), WORLD_RANGE_MAX),
		_extent * 0.85
	)
	_enemy_direction_limit = maxi(
		ConfigUtil.get_int("ui.minimap_enemy_direction_limit", 5), 1
	)
	var arena := ArenaUtil.get_params()
	var map_value: Variant = arena.get("map", null)
	if map_value is Dictionary:
		var map := map_value as Dictionary
		var roads_value: Variant = map.get("roads", null)
		var props_value: Variant = map.get("props", null)
		if roads_value is Array:
			_roads = (roads_value as Array).duplicate(true)
		if props_value is Array:
			_props = (props_value as Array).duplicate(true)
	_terrain_texture = _build_terrain_texture()


func _process(delta: float) -> void:
	_refresh_time -= delta
	if _refresh_time > 0.0:
		return
	_refresh_time = REFRESH_INTERVAL
	queue_redraw()


func set_player(player: Node3D) -> void:
	_player = player


func set_camera(camera: Camera3D) -> void:
	_camera = camera


## 把高度场烘成一张缩略图。启动时调用一次，之后只读。
func _build_terrain_texture() -> ImageTexture:
	var image := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var span := _extent * 2.0
	# 地形采样一次，细图由双线性插值生成；去掉地表微噪声，不把草地画成雷达色块。
	const GRID := 129
	var heights := PackedFloat32Array()
	heights.resize(GRID * GRID)
	for iz in GRID:
		for ix in GRID:
			heights[iz * GRID + ix] = TerrainFieldUtil.height_at(-_extent + span * ix / (GRID - 1), -_extent + span * iz / (GRID - 1))
	for iz in range(TEX_SIZE):
		var gz := float(iz) / (TEX_SIZE - 1) * (GRID - 1)
		var z0 := mini(floori(gz), GRID - 2)
		var tz := gz - z0
		for ix in range(TEX_SIZE):
			var gx := float(ix) / (TEX_SIZE - 1) * (GRID - 1)
			var x0 := mini(floori(gx), GRID - 2)
			var tx := gx - x0
			var a := heights[z0 * GRID + x0]
			var b := heights[z0 * GRID + x0 + 1]
			var c := heights[(z0 + 1) * GRID + x0]
			var d := heights[(z0 + 1) * GRID + x0 + 1]
			var height := lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)
			var color := _terrain_color(height)
			var slope := absf(b - a) + absf(c - a)
			var phase := fposmod(height, 0.7)
			var line_width := clampf(slope * GRID / TEX_SIZE * 0.35, 0.015, 0.065)
			var contour := 1.0 - smoothstep(line_width * 0.3, line_width, minf(phase, 0.7 - phase))
			if height > 0.28 and slope > 0.035:
				color = color.lerp(Color(0.63, 0.71, 0.51), contour * 0.18)
			# 西北来的柔光塑造山坡，而非把海拔量化为四大色块。
			color = color.lightened(clampf((a - b + a - c) * 0.12, 0, 0.18))
			color = color.darkened(clampf((b - a + c - a) * 0.1, 0, 0.18))
			image.set_pixel(ix, iz, color)
	# 实际树冠的地图投影，启动时烘焙，之后不逐帧遍历场景树。
	var scene := get_tree().current_scene
	if scene != null:
		for node in scene.find_children("*", "Node3D", true, false):
			var tree := node as Node3D
			if not tree.scene_file_path.ends_with("stylized_tree.tscn") and not tree.scene_file_path.ends_with("stylized_pine.tscn"):
				continue
			var center := _world_to_texture(tree.global_position)
			var radius := maxf(3.0, 2.6 * tree.global_basis.get_scale().x / span * TEX_SIZE)
			for py in range(maxi(0, floori(center.y - radius)), mini(TEX_SIZE, ceili(center.y + radius))):
				for px in range(maxi(0, floori(center.x - radius)), mini(TEX_SIZE, ceili(center.x + radius))):
					var offset := (Vector2(px, py) - center) / radius
					var coverage := (1.0 - smoothstep(0.5, 1.0, offset.length())) * 0.58
					var canopy := Color(0.15, 0.27, 0.16).lightened(maxf(0, -offset.x - offset.y) * 0.09)
					image.set_pixel(px, py, image.get_pixel(px, py).lerp(canopy, coverage))
	return ImageTexture.create_from_image(image)


## 低地深、高地偏亮。海拔范围约 -2 ~ +6 米，这里按 0~5 归一。
##
## 【去饱和】原先是"深绿 → 亮黄绿"，一块饱和的绿色矩形贴在满屏冷灰蓝里，
## 是全屏唯一抢眼的色块 —— 而小地图的职责是提供方位，不该抢视线。
## 现在压成青灰低地 → 苔绿高地：地形起伏照样分得出来，
## 但它和场景、和其余面板终于是同一套阴天低饱和。
func _terrain_color(height: float) -> Color:
	var t := clampf(height / 5.0, 0.0, 1.0)
	var low := Color(0.10, 0.21, 0.15, 1.0)
	var high := Color(0.36, 0.43, 0.24, 1.0)
	return low.lerp(high, t)


## 内容区（地形真正铺满的那块）。面板的石头边框占掉外圈 FRAME 像素。
func _content() -> Rect2:
	var inset := Vector2(FRAME, FRAME)
	return Rect2(inset, size - inset * 2.0)


func _draw() -> void:
	if _terrain_texture == null or not is_instance_valid(_player):
		return
	# 先铺中性黑玻璃，地形只画在内缩后的内容区。
	var shape := PackedVector2Array([Vector2(7, 0), Vector2(size.x, 0), size, Vector2(0, size.y), Vector2(0, 7)])
	UiThemeUtil.draw_black_glass(self, shape)
	var content := _content()
	var span_px := _world_range * 2.0 / (_extent * 2.0) * float(TEX_SIZE)
	var source_size := Vector2(span_px, span_px * content.size.y / content.size.x)
	var half := source_size * 0.5
	var player_tex := _world_to_texture(_player.global_position)
	# 停止滚动：采样框必须完整落在贴图内。
	var center := Vector2(
		clampf(player_tex.x, half.x, float(TEX_SIZE) - half.x),
		clampf(player_tex.y, half.y, float(TEX_SIZE) - half.y)
	)
	var source := Rect2(center - half, source_size)
	var uvs := PackedVector2Array()
	for p in shape:
		uvs.append((source.position + p / size * source.size) / float(TEX_SIZE))
	draw_polygon(shape, PackedColorArray([Color(1, 1, 1, 0.90)]), uvs, _terrain_texture)
	_draw_world_features(source, span_px)
	_draw_pickups(source, span_px)
	# 指北针要盖住地形与道路，但【必须】在敌人方向箭头之前画 ——
	# 否则正北偏上的敌人箭头会被这块 18×15 的底板吃掉。见 _draw_compass。
	_draw_enemies(source, span_px)
	_draw_player(source, span_px)
	_draw_frame(content)
	_draw_compass()


func _draw_world_features(source: Rect2, span_px: float) -> void:
	var road_index := 0
	for value in _roads:
		if not (value is Dictionary):
			continue
		var road := value as Dictionary
		var pos := _pair(road.get("pos", []))
		var road_size := _pair(road.get("size", []))
		if road_size.x <= 0.0 or road_size.y <= 0.0:
			continue
		var edge := float(road.get("edge_width", 0.7))
		var yaw := float(road.get("yaw", 0.0))
		# 真实道路很宽；按实宽画到 124px 地图上会像一条棕色墙。地图符号略作收窄，
		# 庭院仍保留实际占地，兼顾空间判断与清爽度。
		var display_size := road_size
		if String(road.get("material", "")) != "court":
			display_size.x *= 0.58
		if String(road.get("material", "")) == "court":
			draw_colored_polygon(_map_rect(pos, display_size, yaw, source, span_px), Color(0.49, 0.52, 0.43, 0.55))
		else:
			# 与道路生成器同一条中线，不凭空画直十字或伪造河流。
			var path := PackedVector2Array()
			var seed := 131 + road_index * 977 + int(absf(pos.x) * 17 + absf(pos.y) * 31)
			var phase := float(seed % 29) * 0.37
			for station in 65:
				var u := float(station) / 64.0
				var shift := lerpf(float(road.get("curve_start", 0)), float(road.get("curve_end", 0)), smoothstep(0, 1, u))
				if ArenaUtil.resolve_id() == "sanctum" and edge > 0:
					shift += sin(u * TAU + phase) * 1.2 * sin(PI * u)
				else:
					shift += (sin(u * TAU * 1.35 + phase) * 0.22 + sin(u * TAU * 3.7 + phase * 0.61) * 0.09) * pow(sin(PI * u), 2)
				# Godot 绕 Y 正旋转，与二维 x/z 旋转符号相反。
				var world := pos + Vector2(shift, (u - 0.5) * road_size.y).rotated(-deg_to_rad(yaw))
				path.append(_to_map(Vector3(world.x, 0, world.y), source, span_px))
			var road_width := clampf(display_size.x * content_scale_factor() * 0.30, 1.7, 4.0)
			draw_polyline(path, Color(0.1, 0.16, 0.1, 0.65), road_width + 1.8, true)
			draw_polyline(path, Color(0.84, 0.67, 0.40, 0.94), road_width, true)
		road_index += 1

	for value in _props:
		if not (value is Dictionary):
			continue
		var prop := value as Dictionary
		var pos := _pair(prop.get("pos", []))
		var shape := String(prop.get("shape", ""))
		if shape == "diamond":
			var diamond_at := _to_map(Vector3(pos.x, 0, pos.y), source, span_px)
			if _inside(diamond_at):
				draw_colored_polygon(PackedVector2Array([
					diamond_at + Vector2(0, -3), diamond_at + Vector2(3, 0),
					diamond_at + Vector2(0, 3), diamond_at + Vector2(-3, 0),
				]), Color(0.72, 0.90, 0.92, 0.92))
			continue
		if shape == "cylinder":
			var point := _to_map(Vector3(pos.x, 0, pos.y), source, span_px)
			if _inside(point):
				var radius := float(prop.get("radius", 0.8)) * _content().size.x / (_world_range * 2.0)
				draw_circle(point, maxf(radius, 1.2), Color(0.48, 0.50, 0.45, 0.78))
			continue
		if shape != "box":
			continue
		var raw_size: Variant = prop.get("size", [])
		if not (raw_size is Array) or (raw_size as Array).size() < 3:
			continue
		var dimensions := raw_size as Array
		var footprint := Vector2(float(dimensions[0]), float(dimensions[2]))
		var yaw := float(prop.get("yaw", 0.0))
		var polygon := _map_rect(pos, footprint, yaw, source, span_px)
		draw_colored_polygon(polygon, Color(0.48, 0.53, 0.47, 0.70))
		draw_polyline(UiThemeUtil.closed(polygon), Color(0.77, 0.80, 0.73, 0.65), 0.8, true)


func content_scale_factor() -> float:
	return _content().size.x / (_world_range * 2.0)


func _pair(value: Variant) -> Vector2:
	if value is Array and (value as Array).size() >= 2:
		var pair := value as Array
		return Vector2(float(pair[0]), float(pair[1]))
	return Vector2.ZERO


func _map_rect(center: Vector2, dimensions: Vector2, yaw: float, source: Rect2, span_px: float) -> PackedVector2Array:
	var half := dimensions * 0.5
	var radians := -deg_to_rad(yaw)
	var out := PackedVector2Array()
	for local in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
		var world := center + (local as Vector2).rotated(radians)
		out.append(_to_map(Vector3(world.x, 0, world.y), source, span_px))
	return out


func _world_to_texture(world: Vector3) -> Vector2:
	var span := _extent * 2.0
	return Vector2(
		(world.x + _extent) / span * float(TEX_SIZE),
		(world.z + _extent) / span * float(TEX_SIZE)
	)


## 贴图像素 → 小地图像素。span_px 个贴图像素正好铺满内容区边长。
func _to_map(world: Vector3, source: Rect2, span_px: float) -> Vector2:
	var texture_px := _world_to_texture(world)
	return _content().position + (texture_px - source.position) * (_content().size.x / span_px)


func _inside(point: Vector2) -> bool:
	return _content().grow(-1.0).has_point(point)


func _draw_enemies(source: Rect2, span_px: float) -> void:
	var enemies: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group("enemies"):
		var enemy := node as Node3D
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		enemies.append(enemy)

	var show_directions := _should_show_enemy_directions(enemies.size())
	for enemy in enemies:
		var point := _to_map(enemy.global_position, source, span_px)
		if not _inside(point):
			if show_directions:
				_draw_enemy_direction_marker(enemy, source, span_px)
			continue
		# 【形状也参与编码】远程画菱形、近战画圆点。
		# 原先靠颜色区分（橙 / 红），可这两个颜色在缩略图的低饱和底色上
		# 差别很微弱，色觉障碍的玩家更是完全读不出来。形状是免费的第二通道。
		var is_ranged := enemy.has_method("fire_pattern")
		var color: Color = Color(1.0, 0.62, 0.22, 1.0) if is_ranged else UiThemeUtil.COLOR_DANGER
		# 先压一圈暗色底：敌点要压在地形上，深色描边比加亮更有辨识度。
		draw_circle(point, BLIP_RADIUS + 1.2, Color(0.0, 0.0, 0.0, 0.55))
		if is_ranged:
			draw_colored_polygon(
				PackedVector2Array([
					point + Vector2(0.0, -BLIP_RADIUS - 1.0),
					point + Vector2(BLIP_RADIUS + 1.0, 0.0),
					point + Vector2(0.0, BLIP_RADIUS + 1.0),
					point + Vector2(-BLIP_RADIUS - 1.0, 0.0),
				]),
				color
			)
		else:
			draw_circle(point, BLIP_RADIUS, color)


func _should_show_enemy_directions(enemy_count: int) -> bool:
	return enemy_count > 0 and enemy_count < _enemy_direction_limit


## 在内容区边缘画一个朝向地图外敌人的红色三角。
##
## 方向必须从玩家的世界位置推导，而不是直接拿地图外坐标 clamp：后者会让
## 斜对角的敌人全部挤到角点，箭头也读不出真正的方位。
func _draw_enemy_direction_marker(enemy: Node3D, source: Rect2, span_px: float) -> void:
	var player_point := _to_map(_player.global_position, source, span_px)
	var enemy_point := _to_map(enemy.global_position, source, span_px)
	var direction := enemy_point - player_point
	if direction.is_zero_approx():
		return
	direction = direction.normalized()
	var center := _ray_to_content_edge(player_point, direction)
	var side := Vector2(-direction.y, direction.x)
	var nose := center + direction * ENEMY_DIRECTION_MARKER_SIZE
	var tail := center - direction * ENEMY_DIRECTION_MARKER_SIZE * 0.72
	var half_width := ENEMY_DIRECTION_MARKER_SIZE * 0.72
	var points := PackedVector2Array([
		nose,
		tail + side * half_width,
		tail - side * half_width,
	])
	# 深色外轮廓保证红标经过亮色地形时依旧清楚。
	var outline_size := ENEMY_DIRECTION_MARKER_SIZE + 1.5
	var outline_tail := center - direction * outline_size * 0.72
	var outline_half_width := outline_size * 0.72
	draw_colored_polygon(PackedVector2Array([
		center + direction * outline_size,
		outline_tail + side * outline_half_width,
		outline_tail - side * outline_half_width,
	]), Color(0.0, 0.0, 0.0, 0.72))
	draw_colored_polygon(points, UiThemeUtil.COLOR_DANGER)


## 求从玩家位置沿 direction 射向小地图内缩边框的交点。
func _ray_to_content_edge(origin: Vector2, direction: Vector2) -> Vector2:
	var bounds := _content().grow(-ENEMY_DIRECTION_MARKER_INSET)
	var start := Vector2(
		clampf(origin.x, bounds.position.x, bounds.end.x),
		clampf(origin.y, bounds.position.y, bounds.end.y)
	)
	var distance := INF
	if direction.x > 0.0001:
		distance = minf(distance, (bounds.end.x - start.x) / direction.x)
	elif direction.x < -0.0001:
		distance = minf(distance, (bounds.position.x - start.x) / direction.x)
	if direction.y > 0.0001:
		distance = minf(distance, (bounds.end.y - start.y) / direction.y)
	elif direction.y < -0.0001:
		distance = minf(distance, (bounds.position.y - start.y) / direction.y)
	if not is_finite(distance) or distance < 0.0:
		return bounds.get_center()
	return start + direction * distance


func _draw_pickups(source: Rect2, span_px: float) -> void:
	for node in get_tree().get_nodes_in_group("pickups"):
		var pickup := node as Node3D
		if not is_instance_valid(pickup):
			continue
		var point := _to_map(pickup.global_position, source, span_px)
		if not _inside(point):
			continue
		draw_circle(point, PICKUP_RADIUS + 1.0, Color(0.0, 0.0, 0.0, 0.5))
		draw_circle(point, PICKUP_RADIUS, Color(0.58, 0.94, 0.66, 0.95))


func _draw_player(source: Rect2, span_px: float) -> void:
	var center := _to_map(_player.global_position, source, span_px)
	var facing := Vector2(0.0, -1.0)
	if _camera:
		var forward := -_camera.global_basis.z
		var flat := Vector2(forward.x, forward.z)
		if not flat.is_zero_approx():
			facing = flat.normalized()
	# 朝向用一个小三角：顶尖朝前，比圆点更能读出"我在看哪边"。
	var side := Vector2(-facing.y, facing.x)
	var nose := center + facing * ARROW_RADIUS
	var left := center - facing * ARROW_RADIUS * 0.6 + side * ARROW_RADIUS * 0.72
	var right := center - facing * ARROW_RADIUS * 0.6 - side * ARROW_RADIUS * 0.72
	draw_circle(center, ARROW_RADIUS + 2.0, Color(0.55, 0.92, 1.0, 0.22))
	draw_colored_polygon(PackedVector2Array([nose, left, center - facing * 1.2, right]), Color(0.84, 0.98, 1.0, 1.0))


## 内容区收边：只保留一圈极淡的青发丝线。
##
## 发丝线不是为了"描边"，是为了把地形和石头框之间那条生硬的接缝盖掉 ——
## 否则贴图边缘与面板内圈之间会出现一条色差细缝。
func _draw_frame(content: Rect2) -> void:
	var shine := PackedVector2Array([Vector2(7, 0), Vector2(size.x * 0.66, 0), Vector2(size.x * 0.08, size.y), Vector2(0, size.y), Vector2(0, 7)])
	draw_polygon(shine, PackedColorArray([Color(1, 1, 1, 0.12), Color(1, 1, 1, 0.045), Color(1, 1, 1, 0.005), Color(1, 1, 1, 0.025), Color(1, 1, 1, 0.12)]))
	draw_polyline(PackedVector2Array([Vector2(0, 7), Vector2(7, 0), Vector2(size.x, 0)]), Color(0.9, 0.97, 1, 0.28), 0.65, true)


## 指北针。单独成函数是因为它的画序有要求：必须在 _draw_enemies 之前调用，
## 否则正北偏上的敌人方向箭头会被这块 18×15 的底板盖住。
## N 本身比箭头"更基础"，但箭头是可行动信息，不能被装饰元素吃掉。
func _draw_compass() -> void:
	draw_string_outline(UiThemeUtil.get_font(), Vector2(size.x * 0.5 - 4.5, 17), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 1, Color(0, 0, 0, 0.4))
	draw_string(UiThemeUtil.get_font(), Vector2(size.x * 0.5 - 4.5, 17), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.94, 0.96, 0.98))
