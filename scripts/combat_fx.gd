class_name CombatFX
extends RefCounted
## 战斗反馈统一入口：命中火花 / 伤害飘字 / 范围伤害。
##
## 全静态方法，不需要实例化。所有视觉元素均为运行时构造，不依赖任何美术资源。
## 伤害飘字按距离筛选，避免远距离刷屏（超过 max_draw_distance 直接不生成）。
##
## 注意"准星命中标记"**不在这里**：它是屏幕 UI，而本模块是无状态工具类，
## 原先靠 get_first_node_in_group("player_hud") 去猜 HUD 在哪（多个 HUD 时会闪错那个）。
## 现在由 Ballistics 通过 EventBus.hit_confirmed 广播，PlayerHUD 自己订阅。

## 火花与飘字都从对象池取（见 object_pool.gd 的说明：它们是全项目最大的
## 单项开销来源）。用 preload 而不是裸类名，避免依赖 .godot 的 class 缓存。
const PoolUtil := preload("res://scripts/object_pool.gd")
const ImpactSparkUtil := preload("res://scripts/impact_spark.gd")
const DamageNumberUtil := preload("res://scripts/damage_number.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const ShellCasingUtil := preload("res://scripts/shell_casing.gd")
const HealthUtil := preload("res://scripts/health_util.gd")
const GroundDustUtil := preload("res://scripts/ground_dust.gd")

const COLOR_ENEMY_HIT := Color(1.0, 0.78, 0.24, 1.0)
const COLOR_PLAYER_HIT := Color(1.0, 0.26, 0.22, 1.0)
const COLOR_WORLD_HIT := Color(0.8, 0.78, 0.72, 1.0)

## 命中材质分化（juice 侧）：金属跳弹 / 肉体碎散 / 石屑
const COLOR_METAL_HIT := Color(1.0, 0.95, 0.72, 1.0)
const COLOR_FLESH_HIT := Color(1.0, 0.32, 0.18, 1.0)
const COLOR_STONE_HIT := Color(0.82, 0.79, 0.70, 1.0)

## 贴花池上限（弹孔 / 弹坑 / 焦痕共用）
const MAX_DECALS := 96

static var _bullet_hole_texture: ImageTexture = null
static var _crater_texture: ImageTexture = null
static var _scorch_texture: ImageTexture = null
static var _active_decals: Array[Node] = []

const ENEMY_GROUP := "enemies"

const MAX_DRAW_DISTANCE := 45.0


## 在 world_position 生成一簇命中火花。
static func spawn_impact(
	parent: Node,
	world_position: Vector3,
	normal: Vector3,
	color: Color,
	scale_multiplier: float = 1.0
) -> void:
	if not is_instance_valid(parent):
		return
	var spark := PoolUtil.acquire(
		ImpactSparkUtil.POOL_KEY, ImpactSparkUtil
	) as ImpactSpark
	parent.add_child(spark)
	if spark.is_inside_tree():
		spark.global_position = world_position
	else:
		spark.position = world_position
	spark.trigger(normal, color, scale_multiplier)


## 生成伤害飘字；距离观察相机过远时自动跳过。
static func spawn_damage_number(
	parent: Node,
	world_position: Vector3,
	amount: float,
	color: Color,
	emphasis: float = 1.0
) -> void:
	if not is_instance_valid(parent):
		return
	var camera := parent.get_viewport().get_camera_3d() if parent.is_inside_tree() else null
	if camera and camera.global_position.distance_to(world_position) > MAX_DRAW_DISTANCE:
		return
	var number := PoolUtil.acquire(
		DamageNumberUtil.POOL_KEY, DamageNumberUtil
	) as DamageNumber
	parent.add_child(number)
	number.global_position = world_position
	number.show_amount(amount, color, emphasis)


## 对 center 周围 radius 内的所有敌人造成带衰减的范围伤害，可选击退。
## require_line_of_sight 为 true 时会被墙体阻挡（手雷用），地面冲击波可关掉。
## 返回被命中的敌人数量。
static func apply_radial_damage(
	source: Node3D,
	center: Vector3,
	radius: float,
	damage: float,
	push_force: float = 0.0,
	require_line_of_sight: bool = true
) -> int:
	if not is_instance_valid(source) or not source.is_inside_tree():
		return 0
	var tree := source.get_tree()
	var world := source.get_world_3d()
	var hits := 0
	for node in tree.get_nodes_in_group(ENEMY_GROUP):
		var enemy := node as Node3D
		if not is_instance_valid(enemy):
			continue
		var offset := enemy.global_position - center
		var distance := offset.length()
		if distance > radius:
			continue
		if require_line_of_sight and world:
			var query := PhysicsRayQueryParameters3D.create(
				center, enemy.global_position + Vector3.UP * 0.4, 1
			)
			if not world.direct_space_state.intersect_ray(query).is_empty():
				continue
		var falloff := clampf(1.0 - distance / maxf(radius, 0.01), 0.25, 1.0)
		if enemy.has_method("take_damage"):
			Telemetry.hurt_enemy(enemy, damage * falloff, source.get_meta(Telemetry.CONTEXT, {}))
			hits += 1
		if push_force > 0.0 and enemy.has_method("apply_push"):
			var direction := offset
			direction.y = 0.0
			if direction.is_zero_approx():
				direction = Vector3.FORWARD
			enemy.call("apply_push", direction.normalized(), push_force * falloff)
	return hits



# ────────────────── juice 侧特效层（ruin-star 移植）──────────────────

static func spawn_tracer(parent: Node, start_pos: Vector3, end_pos: Vector3, color: Color = Color(1.0, 0.8, 0.4), thickness: float = 0.03) -> void:
	if not is_instance_valid(parent):
		return
	var distance := start_pos.distance_to(end_pos)
	if distance < 0.5:
		return
		
	var mesh := BoxMesh.new()
	mesh.size = Vector3(thickness, thickness, distance)
	
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 4.0
	mesh.material = mat
	
	var tracer := MeshInstance3D.new()
	tracer.mesh = mesh
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(tracer)
	
	tracer.global_position = (start_pos + end_pos) * 0.5
	var dir := (end_pos - start_pos).normalized()
	var up := Vector3.UP if absf(Vector3.UP.dot(dir)) < 0.99 else Vector3.RIGHT
	tracer.look_at_from_position(tracer.global_position, end_pos, up)
		
	var tween := tracer.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.06).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(mat, "emission_energy_multiplier", 0.0, 0.06)
	tween.tween_callback(tracer.queue_free)


static func hitstop(victim: Node, duration: float = 0.035) -> void:
	if not is_instance_valid(victim) or not victim.is_inside_tree():
		return
	var tree := victim.get_tree()
	if tree == null:
		return
	var real_duration := maxf(duration, 0.015)
	
	# 1. 玩家受击/特写顿帧：通过 Player 自身的 _hitstop_timer 局部暂停物理计算
	if victim.has_method("apply_hitstop"):
		victim.call("apply_hitstop", real_duration)
	# 2. 暂停敌人自身更新，保留碰撞与身上的燃烧粒子。
	elif victim.is_in_group("enemies"):
		if not victim.has_meta(&"hitstop_restore"):
			victim.set_meta(&"hitstop_restore", {
				"process": victim.is_processing(), "physics": victim.is_physics_processing()})
		var token: int = int(victim.get_meta(&"hitstop_token", 0)) + 1
		victim.set_meta(&"hitstop_token", token)
		victim.set_process(false)
		victim.set_physics_process(false)
		var victim_ref: WeakRef = weakref(victim)
		var timer := tree.create_timer(real_duration, true, false, true)
		timer.timeout.connect(func():
			var actor := victim_ref.get_ref() as Node
			if actor == null or int(actor.get_meta(&"hitstop_token", 0)) != token:
				return
			var restore: Dictionary = actor.get_meta(&"hitstop_restore", {})
			actor.remove_meta(&"hitstop_restore")
			if actor.is_inside_tree() and HealthUtil.is_alive(actor):
				actor.set_process(bool(restore.get("process", false)))
				actor.set_physics_process(bool(restore.get("physics", false)))
		)


static func eject_casing(parent: Node, origin: Vector3, velocity: Vector3, is_large: bool = false) -> void:
	if not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	var casing := ShellCasingUtil.new()
	parent.add_child(casing)
	casing.launch(origin, velocity, is_large)


static func _get_bullet_hole_texture() -> ImageTexture:
	if _bullet_hole_texture != null:
		return _bullet_hole_texture
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var center := Vector2(16.0, 16.0)
	for y in range(32):
		for x in range(32):
			var dist := Vector2(x, y).distance_to(center)
			if dist <= 5.5:
				img.set_pixel(x, y, Color(0.03, 0.03, 0.03, 0.96))
			elif dist <= 13.5:
				var t := (dist - 5.5) / 8.0
				var alpha := lerpf(0.92, 0.0, t)
				var c := lerpf(0.08, 0.32, t)
				img.set_pixel(x, y, Color(c, c * 0.95, c * 0.85, alpha))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	_bullet_hole_texture = ImageTexture.create_from_image(img)
	return _bullet_hole_texture


static func _get_crater_texture() -> ImageTexture:
	if _crater_texture != null:
		return _crater_texture
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var center := Vector2(32.0, 32.0)
	for y in range(64):
		for x in range(64):
			var offset := Vector2(x, y) - center
			var dist := offset.length()
			var angle := atan2(offset.y, offset.x)
			var jag := 1.0 + sin(angle * 5.0) * 0.12 + cos(angle * 7.0) * 0.08
			var adj_dist := dist / maxf(jag, 0.5)
			if adj_dist <= 8.5:
				img.set_pixel(x, y, Color(0.02, 0.02, 0.02, 0.98))
			elif adj_dist <= 17.5:
				var t := (adj_dist - 8.5) / 9.0
				var alpha := lerpf(0.95, 0.75, t)
				var r := lerpf(0.06, 0.18, t)
				var g := lerpf(0.04, 0.13, t)
				var b := lerpf(0.03, 0.08, t)
				img.set_pixel(x, y, Color(r, g, b, alpha))
			elif adj_dist <= 29.0:
				var t := (adj_dist - 17.5) / 11.5
				var alpha := lerpf(0.72, 0.0, pow(t, 0.85))
				var c := lerpf(0.18, 0.28, t)
				img.set_pixel(x, y, Color(c, c * 0.85, c * 0.65, alpha))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	_crater_texture = ImageTexture.create_from_image(img)
	return _crater_texture


static func _get_scorch_texture() -> ImageTexture:
	if _scorch_texture != null:
		return _scorch_texture
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var center := Vector2(32.0, 32.0)
	for y in range(64):
		for x in range(64):
			var offset := Vector2(x, y) - center
			var dist := offset.length()
			var angle := atan2(offset.y, offset.x)
			var blast_wave := 1.0 + sin(angle * 6.0) * 0.15 + cos(angle * 9.0) * 0.10
			var adj_dist := dist / maxf(blast_wave, 0.5)
			if adj_dist <= 13.0:
				img.set_pixel(x, y, Color(0.03, 0.03, 0.03, 0.96))
			elif adj_dist <= 30.5:
				var t := (adj_dist - 13.0) / 17.5
				var alpha := lerpf(0.92, 0.0, pow(t, 0.72))
				var c := lerpf(0.05, 0.22, t)
				img.set_pixel(x, y, Color(c, c * 0.92, c * 0.82, alpha))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	_scorch_texture = ImageTexture.create_from_image(img)
	return _scorch_texture


## 从效果来源向下寻找真实支撑面；只查世界碰撞层，不命中角色或散落碎片。
static func sample_ground(parent: Node, world_position: Vector3, max_drop: float = 8.0) -> Dictionary:
	if not is_instance_valid(parent) or not parent.is_inside_tree():
		return {}
	var world := parent.get_viewport().find_world_3d()
	if world == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(
		world_position + Vector3.UP * 0.2, world_position - Vector3.UP * maxf(max_drop, 0.1), 1)
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty() or (hit.normal as Vector3).dot(Vector3.UP) < 0.25:
		return {}
	return hit


static func spawn_ground_dust(parent: Node, point: Vector3, normal: Vector3, strength: float = 0.5) -> Node3D:
	return GroundDustUtil.spawn(parent, point, normal, strength)


## 纯视觉地面反馈，不改变伤害或范围判定。无真实落点时不在空中绘制地面效果。
static func spawn_ground_burst(parent: Node, origin: Vector3, strength: float = 1.5, scorch: bool = false, max_drop: float = 8.0) -> void:
	var ground := sample_ground(parent, origin, max_drop)
	if ground.is_empty():
		return
	spawn_ground_dust(parent, ground.position, ground.normal, strength)
	if scorch:
		spawn_scorch_mark(parent, ground.position, strength)


static func spawn_ground_crater(parent: Node, world_position: Vector3, normal: Vector3, is_heavy: bool = false) -> void:
	if not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	var decal := Decal.new()
	decal.name = "GroundCrater"
	var w := 1.35 if is_heavy else 0.75
	decal.size = Vector3(w, 2.0, w)
	decal.texture_albedo = _get_crater_texture()
	decal.modulate = Color(0.95, 0.95, 0.95, 0.95)
	decal.cull_mask = 1
	parent.add_child(decal)
	_orient_decal(decal, world_position, normal)
	_track_decal(decal, 20.0)


static func spawn_bullet_hole(parent: Node, world_position: Vector3, normal: Vector3, is_heavy: bool = false) -> void:
	if not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	var decal := Decal.new()
	decal.name = "BulletHole"
	var w := 0.65 if is_heavy else 0.38
	decal.size = Vector3(w, 1.4, w)
	decal.texture_albedo = _get_bullet_hole_texture()
	decal.modulate = Color(0.95, 0.95, 0.95, 0.94)
	decal.cull_mask = 1
	parent.add_child(decal)
	_orient_decal(decal, world_position, normal)
	_track_decal(decal, 16.0)


static func spawn_scorch_mark(parent: Node, world_position: Vector3, radius: float = 3.0) -> void:
	if not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	var ground := sample_ground(parent, world_position)
	if ground.is_empty():
		return
	var decal := Decal.new()
	decal.name = "ScorchMark"
	var d_size := maxf(radius * 1.8, 1.8)
	decal.size = Vector3(d_size, 2.4, d_size)
	decal.texture_albedo = _get_scorch_texture()
	decal.modulate = Color(0.92, 0.92, 0.92, 0.92)
	decal.cull_mask = 1
	parent.add_child(decal)
	_orient_decal(decal, ground.position, ground.normal)
	_track_decal(decal, 26.0)


static func _orient_decal(decal: Decal, world_pos: Vector3, normal: Vector3) -> void:
	var safe_normal := normal.normalized() if not normal.is_zero_approx() else Vector3.UP
	# 把贴花包围盒向法线相反方向（泥土深处）推入 42%，防止贴花包围盒延伸到地面上方笼罩低空悬浮道具
	decal.global_position = world_pos - safe_normal * (decal.size.y * 0.42)
	var forward := Vector3.FORWARD if absf(safe_normal.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var right := safe_normal.cross(forward).normalized()
	forward = right.cross(safe_normal).normalized()
	decal.global_transform.basis = Basis(right, safe_normal, forward)
	decal.rotate_object_local(Vector3.UP, randf() * TAU)


static func _track_decal(decal: Decal, duration: float) -> void:
	decal.add_to_group("combat_decal")
	_active_decals.append(decal)
	decal.tree_exited.connect(func(): _active_decals.erase(decal), CONNECT_ONE_SHOT)
	if _active_decals.size() > MAX_DECALS:
		var oldest: Decal = _active_decals.pop_front() as Decal
		if is_instance_valid(oldest):
			oldest.queue_free()
	var tween := decal.create_tween()
	tween.tween_interval(duration * 0.6)
	tween.tween_property(decal, "modulate:a", 0.0, duration * 0.4)
	tween.tween_callback(func():
		_active_decals.erase(decal)
		if is_instance_valid(decal):
			decal.queue_free()
	)
