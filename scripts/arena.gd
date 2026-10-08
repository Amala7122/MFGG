extends RefCounted
## 竞技场定义与几何生成（不挂节点，纯静态）。
##
## ── 为什么几何是"参数 + 生成"而不是把坐标写进配置 ──────────────────
##
## 精确坐标必须与平坦遮罩、导航烘焙保持一致：一座山离遗迹太近，遮罩就会在
## 边缘把几米高的山体硬压回去，造出 52° 的陡坡墙把敌人卡死（这个坑
## terrain_field.gd 里记着，是实测踩出来的）。手写几十个坐标既容易写错、
## 又无法验证一致性。
##
## 所以配置描述【可调的那部分】——
##   体量、起伏幅度、山丘数量与量程、掩体数量与分布环带、装饰密度、
##   刷怪锚点布局、敌人配比、波次参数
## 坐标由这里的【确定性生成器】算出来（同一种子，每次构建完全一致，
## 否则每次重载地形都变，玩家没法建立空间记忆）。
##
## 需要精修的竞技场可以额外提供显式坐标表（hills / cover），直接覆盖生成结果 ——
## 现存那个"湖畔遗址"就是这么保留原样的，因此它的地形与改动前逐点相同。
##
## 加一个新竞技场 = 配置里加一段（约 25 行），不碰代码。

const ConfigUtil := preload("res://scripts/game_config.gd")

## 当前竞技场 id。由 game_flow 在场景加载【之前】写好，各构建器在 _ready() 里读。
static var current_id := ""

## 生成种子基数。种子里混入竞技场 id，保证"同一竞技场每次一样、不同竞技场不一样"。
const SEED_BASE := 90210

## 配置损坏 / 缺省时的兜底体量（与改动前的常量一致）。
const DEFAULT_EXTENT := 60.0


# ---------------------------------------------------------------- 选择

## 竞技场 id 的出场顺序。
static func get_order() -> Array:
	var order := ConfigUtil.get_string_array("arenas.order", [])
	if order.is_empty():
		return ["lakefront"]
	return order


## 当前应当构建的竞技场 id。current_id 为空或不在表里时回退到第一个。
static func resolve_id() -> String:
	var order := get_order()
	if current_id.is_empty() or not order.has(current_id):
		return String(order[0])
	return current_id


## 下一个竞技场 id（到末尾回卷）。Boss 被击败后阶段推进用它。
static func next_id(from_id: String) -> String:
	var order := get_order()
	var index := order.find(from_id)
	if index < 0:
		return String(order[0])
	return String(order[(index + 1) % order.size()])


## 取某个竞技场的完整参数。返回的字典里额外塞了 `_id`，供种子与显示使用。
static func get_params(id: String = "") -> Dictionary:
	_check_invariants()
	var resolved := id if not id.is_empty() else resolve_id()
	var params := ConfigUtil.get_dictionary("arenas.definitions.%s" % resolved)
	if params.is_empty():
		# 【拼错 id 必须立刻吼一声，而不是安静地套用湖畔坐标】
		# 原先这里直接 return {}，于是 terrain_field 的三级兜底会把这颗星球
		# 变成"湖畔遗址"：山丘、湖、主路、遗迹、营地、出生点遮罩全按湖畔来，
		# 而且不报任何错。加一张图时把 id 写歪，排查起来会非常痛苦。
		push_error(
			"Arena: 竞技场 %s 在 arenas.definitions 里不存在，地形将退回湖畔遗址的兜底坐标。" % resolved
		)
		for issue in validate(params):
			push_error("Arena: %s" % issue)
		return {}
	var copy := params.duplicate(true)
	copy["_id"] = resolved
	if not copy.has("label"):
		copy["label"] = resolved
	if not copy.has("extent"):
		copy["extent"] = DEFAULT_EXTENT
	return copy


# ---------------------------------------------------------------- 遮罩（地形压平区）

## 矩形遮罩：[x0, x1, z0, z1, margin]。这些区域被压平到 0 高度 ——
## 湖、主路、遗迹、营地都靠它保持陈设不悬空。
static func rect_masks(params: Dictionary) -> Array:
	var table: Variant = params.get("mask_rects", null)
	if table is Array and not (table as Array).is_empty():
		return table as Array
	return []


## 圆形遮罩：[cx, cz, radius, margin]。玩家出生点用它保证脚下是平的。
static func circle_masks(params: Dictionary) -> Array:
	var table: Variant = params.get("mask_circles", null)
	if table is Array and not (table as Array).is_empty():
		return table as Array
	return []


## (x, z) 是否落在某个遮罩的【实心区】内（margin 之内，即已被完全压平）。
## 生成器用它避开"压平区里放掩体/锚点"这种无效布点。
static func is_masked_out(params: Dictionary, x: float, z: float) -> bool:
	for rect in rect_masks(params):
		if _inside_rect(rect, x, z, 0.0):
			return true
	for circle in circle_masks(params):
		if _inside_circle(circle, x, z, 0.0):
			return true
	return false


## 到最近遮罩边界的距离（负数表示在遮罩内）。山丘间距校验用它。
static func distance_to_mask_edge(params: Dictionary, x: float, z: float) -> float:
	var best := INF
	for rect in rect_masks(params):
		best = minf(best, _rect_distance(rect, x, z))
	for circle in circle_masks(params):
		best = minf(best, _circle_distance(circle, x, z))
	return best


# ---------------------------------------------------------------- 生成器

## 山脚到遮罩边界需要的余量。
##
## 【必须由生成器与自检共用】—— 一开始两边各写了一个系数（生成按短轴 ×0.75、
## 自检按长轴 ×0.5），结果出现"生成说没问题、自检说有问题"的自相矛盾。
## 改成"最大半径"之后又反过来把本来就正常的湖畔地形判成有问题（那座山的长轴
## 指向背离湖泊的方向，用最大半径衡量过于保守）。
##
## 正确做法是各向异性的：只看【指向遮罩那个方向】上的椭圆半径。
##   椭圆在方向 d 上的半径 = 1 / sqrt((dx/rx)² + (dz/rz)²)
## 这样湖畔那座山按 8.95 米判定（实际余量 14.3，通过），
## 而当初那个真 bug —— HillNW 距遗迹角只有 7.6 米、需要 9.84 米 —— 会被抓出来。
static func hill_clearance_needed(
	center_x: float, center_z: float, radius_x: float, radius_z: float, params: Dictionary
) -> float:
	var edge := nearest_mask_edge_point(params, center_x, center_z)
	var direction := Vector2(edge.x - center_x, edge.y - center_z)
	var radius := maxf(radius_x, radius_z)
	if not direction.is_zero_approx():
		var unit := direction.normalized()
		var ax := unit.x / maxf(radius_x, 0.01)
		var az := unit.y / maxf(radius_z, 0.01)
		radius = 1.0 / sqrt(ax * ax + az * az)
	return radius * 0.6


## 距离 (x, z) 最近的遮罩边界点。点在遮罩内部时返回它自己最近的边。
static func nearest_mask_edge_point(params: Dictionary, x: float, z: float) -> Vector2:
	var best := Vector2(x, z)
	var best_distance := INF
	for rect in rect_masks(params):
		var r := rect as Array
		var point := Vector2(
			clampf(x, float(r[0]), float(r[1])), clampf(z, float(r[2]), float(r[3]))
		)
		var distance := Vector2(point.x - x, point.y - z).length()
		if distance < best_distance:
			best_distance = distance
			best = point
	for circle in circle_masks(params):
		var c := circle as Array
		var center := Vector2(float(c[0]), float(c[1]))
		var radius := float(c[2])
		var offset := Vector2(x, z) - center
		var point := center + (
			offset.normalized() * radius if not offset.is_zero_approx() else Vector2(radius, 0.0)
		)
		var distance := Vector2(point.x - x, point.y - z).length()
		if distance < best_distance:
			best_distance = distance
			best = point
	return best


## 山丘表：[[中心x, 中心z, 半径x, 半径z, 高度], ...]
##
## 显式提供 `hills` 时直接用（精修过的竞技场走这条路），
## 否则按 `hill_layout` 生成：角度均分 + 抖动，保证四周围一圈但不显机械。
static func generate_hills(params: Dictionary) -> Array:
	var explicit: Variant = params.get("hills", null)
	if explicit is Array and not (explicit as Array).is_empty():
		return explicit as Array
	var spec := _sub(params, "hill_layout")
	if spec.is_empty():
		return []
	var extent := float(params.get("extent", DEFAULT_EXTENT))
	var count := maxi(int(spec.get("count", 0)), 0)
	var rng := _rng(params)
	var out: Array = []
	for index in range(count):
		# 先定高度（与位置无关），再反复找一个"山脚不会撞进遮罩"的位置。
		#
		# 这一步是必须的：遮罩会把山体在几米内硬压回 0 高度，于是山脚处出现
		# 一道 52° 的陡坡墙。它不会让游戏报错，但敌人会被卡死在那面墙前 ——
		# 这个坑在 terrain_field.gd 里记着，是实测踩出来的。所以宁可挪山、缩山，
		# 也不接受"山脚压进遮罩"。
		var height := rng.randf_range(
			float(spec.get("height_min", 4.0)), float(spec.get("height_max", 6.5))
		)
		var radius_x := 0.0
		var radius_z := 0.0
		var x := 0.0
		var z := 0.0
		var settled := false
		for _attempt in range(16):
			var angle := TAU * float(index) / float(maxf(float(count), 1.0))
			angle += rng.randf_range(-0.4, 0.4)
			var ring := rng.randf_range(
				float(spec.get("ring_radius_min", extent * 0.52)),
				float(spec.get("ring_radius_max", extent * 0.8))
			)
			x = cos(angle) * ring
			z = sin(angle) * ring
			radius_x = rng.randf_range(
				float(spec.get("radius_min", 12.0)), float(spec.get("radius_max", 22.0))
			)
			radius_z = radius_x * rng.randf_range(0.6, 1.0)
			# 【坡度必须按短轴核算，不是长轴】
			# 钟形剖面 (1-d²)² 最陡处斜率 = 1.539×山高/半径，而椭圆山的短轴可以只有
			# 长轴的 0.6。之前只用长轴做安全校核，短轴方向的坡于是悄悄超标 ——
			# 实测 quarry 因此出现 57.1° 的坡面，远超 agent_max_slope=45°。
			# 这里按短轴反推山高上限：山可以矮，但不能陡。
			var slope_cap := tan(deg_to_rad(38.0))
			height = minf(height, minf(radius_x, radius_z) * slope_cap / 1.539)
			# 判据与自检共用同一个函数，避免两套阈值互相打架。
			var wanted := hill_clearance_needed(x, z, radius_x, radius_z, params)
			var clearance := distance_to_mask_edge(params, x, z)
			if clearance >= wanted:
				settled = true
				break
			# 这个方向塞不下就把山收小到空隙里；缩得太小就没有"高地"的意义了，
			# 此时换一个角度重试。
			var shrink := clearance / maxf(wanted, 0.01)
			if shrink >= 0.4:
				radius_x *= shrink
				radius_z *= shrink
				# 【高度必须跟着缩】—— 钟形剖面最陡处的斜率是 1.539×山高/半径。
				# 只缩半径、不降高度，等于把同一个坡按比例压陡：实测 quarry 因此
				# 出现 57.1° 的坡面，远超 navigation.agent_max_slope=45°，
				# 那片坡对敌人等于不存在（走不上去），而画面上完全看不出异常。
				# 等高比缩放则让坡度保持恒定 —— 山变小，但不会变陡。
				height *= shrink
				settled = true
				break
		if not settled:
			continue
		out.append([x, z, radius_x, radius_z, height])
	return out


## 掩体表：[[x, z, 宽, 高, 深, 绕Y旋转(度), 类型], ...]
## 类型：0 = 石墙残段（挡视线）  1 = 木箱堆（半身掩护）  2 = 巨石（可平滑绕行）
##
## 生成策略：环带内布点 + 最小间距 + 避开遮罩 + 避开山丘坡面。
## 最后一条很重要：掩体贴在陡坡上会一半悬空一半埋地。
static func generate_cover(params: Dictionary) -> Array:
	var explicit: Variant = params.get("cover", null)
	if explicit is Array and not (explicit as Array).is_empty():
		return explicit as Array
	var spec := _sub(params, "cover_layout")
	if spec.is_empty():
		return []
	var extent := float(params.get("extent", DEFAULT_EXTENT))
	var rng := _rng(params)
	var hills := generate_hills(params)
	var placed: Array = []
	var inner := float(spec.get("inner_radius", extent * 0.16))
	var outer := float(spec.get("outer_radius", extent * 0.78))
	var spacing := float(spec.get("min_spacing", 5.0))
	var attempts_per_piece := 40

	# [类型, 数量, 宽度范围, 高度范围, 深度范围]
	var groups := [
		[0, int(spec.get("wall_count", 0)), [5.0, 7.0], [2.4, 2.6], [1.1, 1.2]],
		[1, int(spec.get("crate_count", 0)), [2.2, 3.0], [1.5, 2.2], [2.2, 3.0]],
		[2, int(spec.get("boulder_count", 0)), [1.1, 2.2], [0.0, 0.0], [0.0, 0.0]],
	]
	for group in groups:
		var kind := int(group[0])
		var count := int(group[1])
		for _index in range(count):
			for _attempt in range(attempts_per_piece):
				var angle := rng.randf_range(0.0, TAU)
				var radius := rng.randf_range(inner, outer)
				var x := cos(angle) * radius
				var z := sin(angle) * radius
				if absf(x) > extent * 0.95 or absf(z) > extent * 0.95:
					continue
				if is_masked_out(params, x, z):
					continue
				if distance_to_mask_edge(params, x, z) < spacing:
					continue
				if _too_close(placed, x, z, spacing):
					continue
				if _on_too_steep_hill(hills, x, z, spacing):
					continue
				var width := rng.randf_range(float(group[2][0]), float(group[2][1]))
				var height := rng.randf_range(float(group[3][0]), float(group[3][1]))
				var depth := rng.randf_range(float(group[4][0]), float(group[4][1]))
				var rotation := 0.0 if kind == 2 else rng.randf_range(0.0, 180.0)
				placed.append([x, z, width, height, depth, rotation, kind])
				break
	return placed


## 刷怪锚点：[[x, z], ...]。绕中心的环带均分，避开遮罩区。
##
## 只返回平面坐标，y 由调用方查 height_at() —— 这样本模块不需要依赖
## terrain_field，避免两个脚本互相 preload。
static func generate_spawn_anchors(params: Dictionary) -> Array:
	var spec := _sub(params, "spawn_anchors")
	if spec.is_empty():
		return []
	var count := maxi(int(spec.get("count", 0)), 0)
	var inner := float(spec.get("radius_min", 20.0))
	var outer := float(spec.get("radius_max", 40.0))
	var center := _center(spec)
	var rng := _rng(params)
	var out: Array = []
	for index in range(count):
		# 锚点不抖动：环带均分能保证任何方向都有敌人，抖动会留下缺口。
		var angle := TAU * float(index) / float(maxf(float(count), 1.0))
		# 内外两环交替 + 抖动：让玩家不能只守一个半径。
		#
		# 原先只有配置里给了 "alternate" 键才交替，而四张竞技场都没给 ——
		# 于是 15 个锚点全落在 radius_max 的同一个圆上，radius_min 形同虚设，
		# 也顺带让"锚点比敌人察觉距离更远"这个问题被放大成全场冻结。
		var ring := inner if index % 2 == 0 else outer
		var radius := ring * rng.randf_range(0.94, 1.06)
		var x := center.x + cos(angle) * radius
		var z := center.y + sin(angle) * radius
		# 落在压平区（湖/路/遗迹）里的锚点往外推，直到离开遮罩。
		for _push in range(12):
			if not is_masked_out(params, x, z):
				break
			radius += 2.0
			x = center.x + cos(angle) * radius
			z = center.y + sin(angle) * radius
		out.append([x, z])
	return out


# ---------------------------------------------------------------- 自检

## 把"手写坐标互相矛盾"这类问题在启动时就报出来，而不是等玩家撞上一座 52° 的墙。
## 返回问题描述列表（空列表 = 通过）。
static func validate(params: Dictionary) -> Array:
	var issues: Array = []
	var extent := float(params.get("extent", DEFAULT_EXTENT))
	if extent < 20.0 or extent > 120.0:
		issues.append("extent %.1f 超出合理范围 20~120" % extent)
	for hill in generate_hills(params):
		var x := float(hill[0])
		var z := float(hill[1])
		if absf(x) > extent or absf(z) > extent:
			issues.append("山丘 (%.0f, %.0f) 超出地形范围 ±%.0f" % [x, z, extent])
		else:
			var clearance := distance_to_mask_edge(params, x, z)
			var wanted := hill_clearance_needed(x, z, float(hill[2]), float(hill[3]), params)
			if clearance < wanted:
				# 山体有一半压在遮罩里 → 会被硬压回去造出陡坡墙。
				issues.append(
					"山丘 (%.0f, %.0f) 距遮罩边界 %.1f 米，不足所需的 %.1f 米（会造出陡坡墙）"
					% [x, z, clearance, wanted]
				)
	var anchors := generate_spawn_anchors(params)
	if anchors.is_empty():
		issues.append("没有生成任何刷怪锚点（spawn_anchors.count 是否为 0？）")
	for anchor in anchors:
		var ax := float(anchor[0])
		var az := float(anchor[1])
		if absf(ax) > extent or absf(az) > extent:
			issues.append("刷怪锚点 (%.0f, %.0f) 超出地形范围" % [ax, az])
	return issues


## 启动时只跑一次的跨文件不变式检查。
##
## 【它防的是什么】—— `enemy.*_detection_range` 必须大于所有竞技场
## `spawn_anchors.radius_max` 的最大值，否则远处刷出来的近战敌人会因为
## "还没察觉到玩家"而原地站定，波次清不掉（这个坑实测踩过，见
## game_config.json 的 _detection_doc）。但这条约束写在【两个不同的文件段】里，
## 加一张 radius_max 更大的新图就会静默复活它 —— 所以把它变成会自动报警的检查。
static var _invariants_checked := false


static func _check_invariants() -> void:
	if _invariants_checked:
		return
	_invariants_checked = true
	var widest := 0.0
	for id in get_order():
		var params := ConfigUtil.get_dictionary("arenas.definitions.%s" % String(id))
		var anchors := _sub(params, "spawn_anchors")
		widest = maxf(widest, float(anchors.get("radius_max", 0.0)))
		# 【逐图自检必须真的跑起来】—— validate() 写了很久但全仓零调用，
		# 于是"手写坐标互相矛盾"这件事从来没有人报过。它是加图时最先该报警的东西：
		# 山丘离遮罩太近会在山脚造出陡坡墙，敌人直接卡死，而画面上完全看不出异常。
		for issue in validate(params):
			push_error("Arena(%s): %s" % [String(id), issue])
			print("[竞技场] ✘ %s: %s" % [String(id), issue])
	if widest <= 0.0:
		return
	var weakest := minf(
		ConfigUtil.get_float("enemy.melee_detection_range", 75.0),
		ConfigUtil.get_float("enemy.ranged_detection_range", 75.0)
	)
	if weakest <= widest:
		push_error(
			"Arena: 敌人觉察距离 %.0f 不大于最大刷怪锚点半径 %.0f —— 远处刷出的敌人会原地不动。"
			% [weakest, widest]
		)
	else:
		print("[竞技场] 不变式通过：觉察距离 %.0f > 最大锚点半径 %.0f" % [weakest, widest])


# ---------------------------------------------------------------- 内部工具

static func _sub(params: Dictionary, key: String) -> Dictionary:
	var value: Variant = params.get(key, null)
	if value is Dictionary:
		return value as Dictionary
	return {}


static func _center(spec: Dictionary) -> Vector2:
	var value: Variant = spec.get("center", null)
	if value is Array and (value as Array).size() >= 2:
		var pair := value as Array
		return Vector2(float(pair[0]), float(pair[1]))
	return Vector2.ZERO


## 同一种子 → 同一套几何。种子里混入竞技场 id，所以不同竞技场互不重复。
static func _rng(params: Dictionary) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED_BASE + String(params.get("_id", "")).hash()
	return rng


static func _too_close(placed: Array, x: float, z: float, spacing: float) -> bool:
	for piece in placed:
		var dx := float(piece[0]) - x
		var dz := float(piece[1]) - z
		if sqrt(dx * dx + dz * dz) < spacing:
			return true
	return false


## 是否落在某座山的坡面上。掩体贴陡坡会一半悬空一半埋地。
static func _on_too_steep_hill(hills: Array, x: float, z: float, spacing: float) -> bool:
	for hill in hills:
		var dx := (x - float(hill[0])) / maxf(float(hill[2]), 0.01)
		var dz := (z - float(hill[1])) / maxf(float(hill[3]), 0.01)
		# 0.55~0.95 是钟形剖面最陡的那一段；山顶（<0.55）反而是平的，可以放。
		var d := sqrt(dx * dx + dz * dz)
		if d > 0.55 and d < 0.95:
			return true
		if d <= 0.55 and sqrt(dx * dx + dz * dz) < 0.2 and spacing > 0.0:
			# 山顶虽平，但放掩体会挡住"高地视野"这个设计意图，也一并排除。
			return true
	return false


static func _inside_rect(rect: Variant, x: float, z: float, margin: float) -> bool:
	if not (rect is Array) or (rect as Array).size() < 4:
		return false
	var r := rect as Array
	return (
		x > float(r[0]) + margin and x < float(r[1]) - margin
		and z > float(r[2]) + margin and z < float(r[3]) - margin
	)


static func _inside_circle(circle: Variant, x: float, z: float, margin: float) -> bool:
	if not (circle is Array) or (circle as Array).size() < 3:
		return false
	var c := circle as Array
	var dx := x - float(c[0])
	var dz := z - float(c[1])
	return sqrt(dx * dx + dz * dz) < float(c[2]) - margin


## 到矩形遮罩的距离（矩形内部为负数，近似用 max 分量）。
static func _rect_distance(rect: Variant, x: float, z: float) -> float:
	if not (rect is Array) or (rect as Array).size() < 4:
		return INF
	var r := rect as Array
	var dx := maxf(maxf(float(r[0]) - x, x - float(r[1])), 0.0)
	var dz := maxf(maxf(float(r[2]) - z, z - float(r[3])), 0.0)
	if dx <= 0.0 and dz <= 0.0:
		# 在矩形内部：返回到最近边的负距离。
		return -minf(
			minf(x - float(r[0]), float(r[1]) - x), minf(z - float(r[2]), float(r[3]) - z)
		)
	return sqrt(dx * dx + dz * dz)


static func _circle_distance(circle: Variant, x: float, z: float) -> float:
	if not (circle is Array) or (circle as Array).size() < 3:
		return INF
	var c := circle as Array
	var dx := x - float(c[0])
	var dz := z - float(c[1])
	return sqrt(dx * dx + dz * dz) - float(c[2])
