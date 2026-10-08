@tool
extends Node3D
## 圣所的静态美术层：连续外围山谷、砌石、群落。沿用统一几何绕序。
const Geometry := preload("res://scripts/lowpoly_mesh.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const Landscape := preload("res://scripts/valley_terrain.gd")
const StaticCache := preload("res://scripts/valley_static_cache.gd")
const CASCADE_UPPER_STEPS := 108
const CASCADE_FALL_STEPS := 24
const CASCADE_LOWER_STEPS := 128
const CASCADE_BANDS := 18
const CASCADE_WATER_LIFT := 1.25
static var generated_builds := 0

static func append_mesh(builder: Geometry.Builder, mesh: Mesh, transform: Transform3D, tint: Color) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	for i in points.size():
		builder.verts.append(transform * points[i])
		builder.normals.append((transform.basis.inverse().transposed() * normals[i]).normalized())
		builder.colors.append((colors[i] if colors.size() > i else Color.WHITE) * tint)


static func masonry(size: Vector3, bevel: float) -> ArrayMesh:
	var builder := Geometry.begin()
	var rows := maxi(ceili(size.y / 1.25), 1)
	var long_x := size.x >= size.z
	var length := size.x if long_x else size.z
	var row_height := size.y / float(rows)
	for row in rows:
		var cursor := -length * 0.5
		var block_index := 0
		while cursor < length * 0.5 - 0.01:
			var span := minf(2.7 if block_index > 0 or row % 2 == 0 else 1.35, length * 0.5 - cursor)
			var block_size := Vector3(span - 0.028, row_height - 0.024, size.z)
			var center := Vector3(cursor + span * 0.5, -size.y * 0.5 + (row + 0.5) * row_height, 0)
			if not long_x:
				block_size = Vector3(size.x, row_height - 0.024, span - 0.028)
				center = Vector3(0, center.y, cursor + span * 0.5)
			var tone := 0.93 + 0.07 * sin(float(row * 11 + block_index * 7))
			var stone := Geometry.chamfered_box(block_size, minf(bevel, 0.085))
			append_mesh(builder, stone, Transform3D(Basis.IDENTITY, center), Color(tone, tone, tone * 0.98))
			cursor += span
			block_index += 1
	return Geometry.commit(builder)


static func mountain_height(x: float, z: float) -> float:
	return Landscape.height(x, z)


static func mountains() -> ArrayMesh:
	return Landscape.mountains()


func _ready() -> void:
	if StaticCache.current():
		var scene := ResourceLoader.load(StaticCache.ART_PATH, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
		add_child(scene.instantiate())
		return
	if not StaticCache.force_generation and not OS.get_cmdline_user_args().has("--valley-source"):
		push_warning("山谷静态资源不存在或已过期，本次使用源几何。运行 tests/bake_valley_art.gd 可重新预生成。")
	generated_builds += 1
	_build_art()


func _build_art() -> void:
	Landscape.mountains()
	var rng := RandomNumberGenerator.new()
	rng.seed = 924061
	var plants := Geometry.begin()
	var shrubs := Geometry.begin()
	var rocks := Geometry.begin()
	var trunks := Geometry.begin()
	var crowns := Geometry.begin()
	var rock_mesh := Geometry.faceted_ellipsoid(1.0, 2.0, 7, 3, 0.21)
	var crown_mesh := Geometry.faceted_ellipsoid(1.0, 2.0, 7, 3, 0.13)
	var pine_mesh := Geometry.faceted_cone(1.0, 2.0, 7)
	# 群落沿道路两侧展开；各群之间保留开阔草地。
	for cluster in 34:
		var side := -1.0 if cluster % 2 == 0 else 1.0
		var center := Vector2(side * rng.randf_range(12, 69), rng.randf_range(-70, 75))
		for member in 115:
			var p := center + Vector2(rng.randfn(0, 4.5), rng.randfn(0, 4.5))
			if not _clear_ground(p):
				continue
			var origin := Vector3(p.x, Terrain.height_at(p.x, p.y) - 0.025, p.y)
			var height := rng.randf_range(0.24, 0.72)
			var color := Color(0.16, 0.34, 0.07).lerp(Color(0.33, 0.48, 0.10), rng.randf())
			for blade in 4:
				var angle := rng.randf_range(0, TAU)
				var spread := Vector3(cos(angle), 0, sin(angle)) * rng.randf_range(0.08, 0.22)
				var tip := origin + Vector3.UP * height + spread * 1.8
				Geometry.push_triangle(plants, origin - spread, origin + spread, tip, color)
				Geometry.push_triangle(plants, origin + spread, origin - spread, tip, color)
			if member % 9 == 0:
				append_mesh(plants, crown_mesh, Transform3D(Basis.IDENTITY.scaled(Vector3(0.10, 0.13, 0.10)), origin + Vector3.UP * height), Color(0.97, 0.74, 0.12))
		for bush in 5:
			var p := center + Vector2(rng.randfn(0, 4.2), rng.randfn(0, 4.2))
			if not _clear_ground(p):
				continue
			var radius := rng.randf_range(0.45, 1.15)
			var base := Vector3(p.x, Terrain.height_at(p.x, p.y) + radius * 0.30, p.y)
			var tint := Color(0.18, 0.35, 0.08).lerp(Color(0.28, 0.45, 0.12), rng.randf())
			append_mesh(shrubs, crown_mesh, Transform3D(Basis.IDENTITY.scaled(Vector3(radius, radius * 0.57, radius)), base), tint)
		# 主岩体只放在外围，避免用纯装饰冒充场内可交互掩体。
		if absf(center.x) > 52:
			var base := Vector3(center.x, Terrain.height_at(center.x, center.y), center.y)
			for stone in 4:
				var position := base + Vector3(rng.randf_range(-4, 4), 0, rng.randf_range(-4, 4))
				position.y = Terrain.height_at(position.x, position.z) + 0.35
				var scale_value := Vector3(rng.randf_range(1.7, 3.4), rng.randf_range(1.3, 2.6), rng.randf_range(1.4, 2.8))
				var rock_transform := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(scale_value), position)
				append_mesh(rocks, rock_mesh, rock_transform, Color(0.41, 0.43, 0.38))
				var body := StaticBody3D.new()
				body.position = position
				body.add_to_group("nav_source", true)
				var collision := CollisionShape3D.new()
				var shape := rock_mesh.create_convex_shape()
				var points := shape.points
				for index in points.size():
					points[index] = rock_transform.basis * points[index]
				shape.points = points
				collision.shape = shape
				body.add_child(collision)
				add_child(body)
	# 远处树林形成成组的轮廓，不占据主路与战斗区。
	for tree in 230:
		var near_slope := tree < 140
		var p := Vector2(
			rng.randf_range(36, 125) * (-1 if tree % 2 == 0 else 1) if near_slope else rng.randf_range(96, 188) * (-1 if tree % 2 == 0 else 1),
			rng.randf_range(92, 210) if near_slope else rng.randf_range(-210, 210)
		)
		if near_slope and absf(p.x) < 16:
			continue
		var base := Vector3(p.x, _mountain_mesh_height(p.x, p.y) - 0.15, p.y)
		var height := rng.randf_range(5.0, 10.5)
		Geometry.push_box(trunks, base + Vector3.UP * height * 0.3, Vector3(0.42, height * 0.6, 0.42), Color(0.24, 0.16, 0.09))
		for tier in 3:
			var radius := height * (0.26 - tier * 0.055)
			append_mesh(crowns, pine_mesh, Transform3D(Basis.IDENTITY.scaled(Vector3(radius, height * 0.28, radius)), base + Vector3.UP * height * (0.47 + tier * 0.18)), Color(0.15 + tier * 0.025, 0.29 + tier * 0.03, 0.12))
	# 新增的远山林带以小群落而非均匀噪点落在缓坡；陡岩和山脊留白。
	for grove in 40:
		var angle := (float(grove) + rng.randf_range(-0.28, 0.28)) * TAU / 40.0
		var radius := rng.randf_range(225.0, 475.0)
		var center := Vector2(cos(angle), sin(angle)) * radius
		for member in 23:
			var p := center + Vector2(rng.randfn(0, 22.0), rng.randfn(0, 22.0))
			var ring := maxf(absf(p.x), absf(p.y))
			if ring < 185.0 or ring > 550.0:
				continue
			var ground_y := _mountain_mesh_height(p.x, p.y)
			if ground_y > 115.0:
				continue
			if p.y > -421.0 and p.y < -350.0 and absf(p.x - _river_center(p.y)) < 38.0:
				continue
			if p.y >= -350.0 and p.y < -258.0 and absf(p.x - _river_center(p.y)) < _river_width(p.y) + 5.0:
				continue
			var slope := Vector2(_mountain_mesh_height(p.x + 3.0, p.y) - _mountain_mesh_height(p.x - 3.0, p.y),
				_mountain_mesh_height(p.x, p.y + 3.0) - _mountain_mesh_height(p.x, p.y - 3.0)).length() / 6.0
			if slope > 0.72:
				continue
			var base := Vector3(p.x, ground_y - 0.4, p.y)
			var height := rng.randf_range(7.0, 12.0) * lerpf(1.0, 1.28, smoothstep(230.0, 520.0, ring))
			Geometry.push_box(trunks, base + Vector3.UP * height * 0.3, Vector3(0.52, height * 0.6, 0.52), Color(0.23, 0.17, 0.11))
			for tier in 3:
				var crown_radius := height * (0.26 - tier * 0.055)
				append_mesh(crowns, pine_mesh, Transform3D(Basis.IDENTITY.scaled(Vector3(crown_radius, height * 0.28, crown_radius)),
					base + Vector3.UP * height * (0.47 + tier * 0.18)), Color(0.17 + tier * 0.025, 0.31 + tier * 0.03, 0.15))
	# The new river terrace needs a few trees rooted in its actual raised surface;
	# trees placed at the old mountain height would disappear inside the shelf.
	for shelf_tree in 12:
		var side := -1.0 if shelf_tree % 2 == 0 else 1.0
		var z := -409.0 + floorf(float(shelf_tree) * 0.5) * 7.5 + 2.0 * sin(float(shelf_tree) * 1.7)
		var x := _river_center(z) + side * (23.0 + 5.0 * absf(sin(float(shelf_tree) * 2.3)))
		var base := _shelf_point(x, z) - Vector3.UP * 0.25
		var height := 6.0 + 2.8 * absf(sin(float(shelf_tree) * 1.4))
		Geometry.push_box(trunks, base + Vector3.UP * height * 0.3,
			Vector3(0.42, height * 0.6, 0.42), Color(0.23, 0.17, 0.11))
		for tier in 3:
			var crown_radius := height * (0.25 - tier * 0.052)
			append_mesh(crowns, pine_mesh, Transform3D(Basis.IDENTITY.scaled(
				Vector3(crown_radius, height * 0.28, crown_radius)),
				base + Vector3.UP * height * (0.47 + tier * 0.18)),
				Color(0.15 + tier * 0.025, 0.29 + tier * 0.03, 0.12))
	_mount(plants, "MeadowColonies", false)
	_mount(shrubs, "MeadowShrubs", false)
	_mount(_distant_road(), "WindingValleyTrack", false)
	_mount(_waterfall(), "SaddleCascade", false)
	_mount(_cascade_rocks(), "CascadeBoulders", false)
	_mount(_ruin_surfaces(), "BrokenGalleryPaving", true)
	var pebbles := Geometry.begin()
	for i in 48:
		var p := Vector2(rng.randf_range(-2.2, 2.2), rng.randf_range(-17, 77))
		var scale_value := Vector3(rng.randf_range(0.13, 0.32), rng.randf_range(0.045, 0.10), rng.randf_range(0.13, 0.30))
		append_mesh(pebbles, rock_mesh, Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(scale_value), Vector3(p.x, Terrain.height_at(p.x, p.y) + 0.035, p.y)), Color(0.35, 0.34, 0.28))
	_mount(pebbles, "EmbeddedRoadStones", true)
	_mount(rocks, "BankBoulders", true)
	_mount(trunks, "ValleyTreeTrunks", true)
	_mount(crowns, "ValleyCanopies", true)




static func _waterfall() -> Geometry.Builder:
	# Keep the previous readable vertical fall, now attached to the natural
	# saddle terrace. All three parts share their boundary vertices exactly.
	var builder := Geometry.begin()
	for step in CASCADE_UPPER_STEPS:
		var t0 := float(step) / CASCADE_UPPER_STEPS
		var t1 := float(step + 1) / CASCADE_UPPER_STEPS
		for band in CASCADE_BANDS:
			var s0 := -1.0 + 2.0 * float(band) / CASCADE_BANDS
			var s1 := -1.0 + 2.0 * float(band + 1) / CASCADE_BANDS
			Geometry.push_quad(builder, _upper_river_point(s1, t0), _upper_river_point(s0, t0),
				_upper_river_point(s0, t1), _upper_river_point(s1, t1), Color(0.30, 0.61, 0.68, 1.0))
	for step in CASCADE_FALL_STEPS:
		var t0 := float(step) / CASCADE_FALL_STEPS
		var t1 := float(step + 1) / CASCADE_FALL_STEPS
		for band in CASCADE_BANDS:
			var s0 := -1.0 + 2.0 * float(band) / CASCADE_BANDS
			var s1 := -1.0 + 2.0 * float(band + 1) / CASCADE_BANDS
			Geometry.push_quad(builder, _fall_point(s1, t0), _fall_point(s0, t0),
				_fall_point(s0, t1), _fall_point(s1, t1), Color(0.66, 0.80, 0.86, 0.0))
	for step in CASCADE_LOWER_STEPS:
		var t0 := float(step) / CASCADE_LOWER_STEPS
		var t1 := float(step + 1) / CASCADE_LOWER_STEPS
		var z := _lower_river_point(0.0, t0).z
		var whitewater := 1.0 - smoothstep(-345.0, -326.0, z)
		var tint := Color(0.30 + 0.36 * whitewater, 0.61 + 0.19 * whitewater,
			0.68 + 0.18 * whitewater, 1.0 - whitewater)
		for band in CASCADE_BANDS:
			var s0 := -1.0 + 2.0 * float(band) / CASCADE_BANDS
			var s1 := -1.0 + 2.0 * float(band + 1) / CASCADE_BANDS
			Geometry.push_quad(builder, _lower_river_point(s1, t0), _lower_river_point(s0, t0),
				_lower_river_point(s0, t1), _lower_river_point(s1, t1), tint)
	return builder


static func _cascade_rocks() -> Geometry.Builder:
	var builder := Geometry.begin()
	var stone := Geometry.faceted_ellipsoid(1.0, 2.0, 8, 4, 0.18)
	for cluster in 9:
		var cluster_z := -391.0 + float(cluster) * 14.5 + 2.4 * sin(float(cluster) * 2.1)
		var cluster_side := -1.0 if cluster % 3 != 1 else 1.0
		for member in 3:
			var i := cluster * 3 + member
			var z := cluster_z + 3.8 * sin(float(i) * 2.47)
			var flank := cluster_side if member != 2 else -cluster_side
			var size := 1.0 + 0.39 * float(i % 5)
			var offset := _river_width(z) + size * 1.75 + 0.8 + 2.8 * absf(sin(float(i) * 1.83))
			var x := _river_center(z) + flank * offset
			var ground := _shelf_point(x, z).y if z < _lip_z(x) else _mountain_mesh_height(x, z)
			var y := ground + size * 0.30
			append_mesh(builder, stone, Transform3D(Basis(Vector3.UP, float(i) * 2.37).scaled(
				Vector3(size * 1.55, size * 0.95, size * 1.10)), Vector3(x, y, z)),
				Color(0.34, 0.37, 0.38) * (0.90 + 0.08 * sin(float(i) * 3.1)))
	return builder


static func _river_center(z: float) -> float:
	return 104.0 + 2.5 * sin((z + 345.0) * 0.026)


static func _river_width(z: float) -> float:
	var broad := 9.0 + 4.0 * exp(-pow((z + 336.0) / 13.0, 2.0))
	return lerpf(broad, 5.5, smoothstep(-292.0, -264.0, z))


static func _lip_z(x: float) -> float:
	return Landscape.lip_z(x)


static func _shelf_raise(x: float, z: float) -> float:
	return Landscape.shelf_raise(x, z)


static func _shelf_point(x: float, z: float) -> Vector3:
	return Vector3(x, _mountain_mesh_height(x, z), z)


static func _upper_river_point(side: float, t: float) -> Vector3:
	var nominal_z := lerpf(-452.0, -352.0, t)
	var width := lerpf(1.2, 9.0, t)
	var x := _river_center(nominal_z) + side * width
	var z := lerpf(-452.0, _lip_z(x), t)
	var rock := _shelf_point(x, z)
	return Vector3(x, rock.y + CASCADE_WATER_LIFT, z)


static func _fall_point(side: float, t: float) -> Vector3:
	var top := _upper_river_point(side, 1.0)
	var foot_z := top.z + 5.8
	var foot_y := _mountain_mesh_height(top.x, foot_z) + CASCADE_WATER_LIFT
	var bulge := sin(t * PI)
	return Vector3(top.x + 0.26 * sin(side * 9.0 + t * 7.0) * bulge,
		lerpf(top.y, foot_y, t),
		lerpf(top.z, foot_z, t) + 0.30 * sin(side * 6.0 + t * 9.0) * bulge)


static func _lower_river_point(side: float, t: float) -> Vector3:
	var start := _fall_point(side, 1.0)
	var z := lerpf(start.z, -262.0, t)
	var target_x := _river_center(z) + side * _river_width(z)
	var x := lerpf(start.x, target_x, smoothstep(0.0, 0.19, t))
	return Vector3(x, _mountain_mesh_height(x, z) + CASCADE_WATER_LIFT, z)


static func _distant_road() -> Geometry.Builder:
	var builder := Geometry.begin()
	var steps := 180
	for index in steps:
		var z0 := lerpf(82.0, 226.0, float(index) / steps)
		var z1 := lerpf(82.0, 226.0, float(index + 1) / steps)
		var center0 := _road_center(z0)
		var center1 := _road_center(z1)
		var width0 := lerpf(2.8, 1.05, smoothstep(82.0, 220.0, z0))
		var width1 := lerpf(2.8, 1.05, smoothstep(82.0, 220.0, z1))
		var jitter0 := sin(index * 1.7) * 0.12
		var jitter1 := sin((index + 1) * 1.7) * 0.12
		var right0 := _road_point(center0 + width0 + jitter0, z0)
		var left0 := _road_point(center0 - width0 - jitter0, z0)
		var right1 := _road_point(center1 + width1 + jitter1, z1)
		var left1 := _road_point(center1 - width1 - jitter1, z1)
		var tone := 0.95 + 0.035 * sin(index * 0.57)
		Geometry.push_quad(builder, right0, left0, left1, right1, Color(0.58, 0.34, 0.17) * tone)
	return builder


static func _road_center(z: float) -> float:
	var t := maxf(z - 82.0, 0.0)
	return -4.5 + 11.0 * sin(t * 0.035) * smoothstep(0.0, 22.0, t) - t * 0.035


static func _road_point(x: float, z: float) -> Vector3:
	var y := Terrain.height_at(x, z) if z < 89.0 else _mountain_mesh_height(x, z)
	return Vector3(x, y + 0.16, z)


static func _mountain_mesh_height(x: float, z: float) -> float:
	return Landscape.sample_height(x, z)


static func _ruin_surfaces() -> Geometry.Builder:
	var builder := Geometry.begin()
	var chip := Geometry.faceted_ellipsoid(1.0, 2.0, 6, 2, 0.12)
	for side in [-1.0, 1.0]:
		var center_x: float = 3.0 + side * 19.0
		for ix in 6:
			for iz in 11:
				if (ix * 7 + iz * 13 + (0 if side < 0 else 3)) % 23 == 0:
					continue
				var x: float = center_x - 5.0 + ix * 2.0
				var z: float = -34.0 + iz * 2.0
				var top := Terrain.height_at(x, z) + 0.19
				var tone := 0.94 + 0.06 * sin(ix * 4.1 + iz * 2.7)
				Geometry.push_box(builder, Vector3(x, top, z), Vector3(1.89, 0.04, 1.89), Color(0.51, 0.49, 0.42) * tone)
		for piece in 15:
			var angle := float(piece) * 2.399
			var distance := 6.4 + float(piece % 4) * 0.56
			var x := center_x + cos(angle) * distance
			var z := -24.0 + sin(angle) * 10.8
			var scale_value := Vector3(0.36 + float(piece % 3) * 0.18, 0.16 + float(piece % 2) * 0.09, 0.33 + float(piece % 4) * 0.10)
			append_mesh(builder, chip, Transform3D(Basis(Vector3.UP, angle).scaled(scale_value), Vector3(x, Terrain.height_at(x, z) + scale_value.y * 0.65, z)), Color(0.51, 0.49, 0.41))
	return builder


func _clear_ground(p: Vector2) -> bool:
	if absf(p.x) < 10.0 or absf(p.x) > 84 or absf(p.y) > 84:
		return false
	if p.x > 7 and p.x < 57 and absf(p.y - 2.0) < 6:
		return false
	# 遗迹密集区保留给建筑；在外围草地做密度群落。
	return not (p.x > -29 and p.x < 32 and p.y > -51 and p.y < -8)


func _mount(builder: Geometry.Builder, label: String, shadow: bool) -> void:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = Geometry.commit(builder)
	if label == "SaddleCascade":
		var water_material := ShaderMaterial.new()
		water_material.shader = preload("res://shaders/cascade_water.gdshader")
		node.material_override = water_material
	else:
		var material := StandardMaterial3D.new()
		material.vertex_color_use_as_albedo = true
		material.vertex_color_is_srgb = true
		material.roughness = 0.95
		node.material_override = material
	if not shadow:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
