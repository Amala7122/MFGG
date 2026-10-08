@tool
extends Node3D
## 固定的 96 个实例复用六种网格。每帧只更新变换与共享材质，不创建云节点。
## 两层各六个 MultiMesh 提交；无透明叠加、碰撞、导航。可选云影复用太阳阴影图。

const Library := preload("res://scripts/cloud_mesh_library.gd")
const CloudShader := preload("res://shaders/procedural_cloud.gdshader")
const GRID := Vector2i(8, 6)
const HALF_EXTENT := 1200.0
const LAYER_HEIGHTS := [300.0, 415.0]
const LAYER_SPEEDS := [1.0, 0.64]
const LAYER_HEIGHT_VARIATION := [58.0, 78.0]

var wind_speed := 8.0
var wind_direction_degrees := 225.0
var size_multiplier := 1.0
var deformation_amount := 0.0
var _shape_style := Library.Style.FACETED
var _coverage := 0.0
var _density := 0.5
var _overcast_blend := 0.0
var _cloud_tint := Color(0.78, 0.82, 0.86)
var _deck_tint := Color(0.67, 0.71, 0.75)
var _material: ShaderMaterial
var _batches: Array[MultiMeshInstance3D] = []
var _clouds: Array[Dictionary] = []
var _layer_offsets: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _clock := 0.0
var _cast_cloud_shadows := false


func _ready() -> void:
	_build_pool()
	_apply_material()
	_update_transforms()


func _process(delta: float) -> void:
	if _batches.is_empty():
		return
	if Engine.is_editor_hint():
		_sync_base_meshes()
	_clock += delta
	var angle := deg_to_rad(wind_direction_degrees)
	for layer in range(LAYER_HEIGHTS.size()):
		# 高层风向略有偏转，仍遵循同一主导风向。
		var direction := Vector2(cos(angle + layer * 0.10), sin(angle + layer * 0.10))
		_layer_offsets[layer] += direction * wind_speed * float(LAYER_SPEEDS[layer]) * delta
		_layer_offsets[layer].x = wrapf(_layer_offsets[layer].x, -HALF_EXTENT, HALF_EXTENT)
		_layer_offsets[layer].y = wrapf(_layer_offsets[layer].y, -HALF_EXTENT, HALF_EXTENT)
	_material.set_shader_parameter("cloud_time", _clock)
	if visible:
		_update_transforms()


func _sync_base_meshes() -> void:
	var meshes := Library.get_meshes(_shape_style)
	if _batches.is_empty() or _batches[0].multimesh.mesh == meshes[0]:
		return
	# @tool 热更新后已有 MultiMesh 仍可能引用旧资源；替换引用即可同步新云形。
	for index in range(_batches.size()):
		_batches[index].multimesh.mesh = meshes[index % meshes.size()]


func set_shape_style(style: int) -> void:
	var wanted := clampi(style, Library.Style.FACETED, Library.Style.ROUNDED)
	if wanted != _shape_style:
		_shape_style = wanted
		_sync_base_meshes()


func set_cloud_shadows(enabled: bool) -> void:
	if enabled == _cast_cloud_shadows:
		return
	_cast_cloud_shadows = enabled
	for batch in _batches:
		batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func set_motion(speed: float, direction_degrees: float, cloud_scale: float, deformation: float) -> void:
	wind_speed = maxf(speed, 0.0)
	wind_direction_degrees = direction_degrees
	size_multiplier = clampf(cloud_scale, 0.25, 3.0)
	deformation_amount = clampf(deformation, 0.0, 0.15)
	if _material != null:
		_material.set_shader_parameter("deformation_amount", deformation_amount)


func set_weather(coverage: float, density: float, blend: float, tint: Color, deck: Color) -> void:
	_coverage = clampf(coverage, 0.0, 1.0)
	_density = clampf(density, 0.0, 1.0)
	_overcast_blend = clampf(blend, 0.0, 1.0)
	_cloud_tint = tint
	_deck_tint = deck
	visible = _coverage > 0.001
	_apply_material()


func get_weather_state() -> Array:
	return [_coverage, _density, _overcast_blend, _cloud_tint, _deck_tint,
		wind_speed, wind_direction_degrees, size_multiplier, deformation_amount, _shape_style,
		_cast_cloud_shadows]


## 保守估计当前云体的最高点，用于保留真实阴影中的云层深度。
func get_cloud_height_ceiling() -> float:
	var highest_top := 0.0
	for mesh in Library.get_meshes(_shape_style):
		highest_top = maxf(highest_top, mesh.get_aabb().end.y)
	highest_top += deformation_amount * 20.0
	var thickness := lerpf(0.65, 1.40, _density) * lerpf(1.0, 0.64, _overcast_blend)
	var low := float(LAYER_HEIGHTS[0]) + float(LAYER_HEIGHT_VARIATION[0]) \
		+ highest_top * 1.15 * size_multiplier * thickness
	var high := float(LAYER_HEIGHTS[1]) + float(LAYER_HEIGHT_VARIATION[1]) \
		+ highest_top * 1.15 * 0.65 * size_multiplier * thickness
	return global_position.y + maxf(low, high) * global_basis.y.length()


func restore_weather_state(state: Array) -> void:
	set_weather(state[0], state[1], state[2], state[3], state[4])
	set_motion(state[5], state[6], state[7], state[8])
	set_shape_style(state[9] if state.size() > 9 else Library.Style.FACETED)
	set_cloud_shadows(bool(state[10]) if state.size() > 10 else false)


func _build_pool() -> void:
	if not _batches.is_empty():
		return
	_material = ShaderMaterial.new()
	_material.shader = CloudShader
	var meshes := Library.get_meshes(_shape_style)
	var rng := RandomNumberGenerator.new()
	rng.seed = 982451
	for layer in range(LAYER_HEIGHTS.size()):
		for variant in range(meshes.size()):
			var batch := MultiMeshInstance3D.new()
			batch.name = "Layer%dShape%d" % [layer, variant]
			batch.multimesh = MultiMesh.new()
			batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			batch.multimesh.use_custom_data = true
			batch.multimesh.mesh = meshes[variant]
			batch.multimesh.instance_count = GRID.x * GRID.y / meshes.size()
			batch.material_override = _material
			batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if _cast_cloud_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			batch.extra_cull_margin = 8.0
			add_child(batch)
			_batches.append(batch)
		for cell in range(GRID.x * GRID.y):
			var variant := cell % meshes.size()
			var slot := cell / meshes.size()
			var batch_index := layer * meshes.size() + variant
			var base := Vector2(
				(float(cell % GRID.x) + rng.randf_range(0.15, 0.85)) / GRID.x,
				(float(cell / GRID.x) + rng.randf_range(0.15, 0.85)) / GRID.y
			) * HALF_EXTENT * 2.0 - Vector2.ONE * HALF_EXTENT
			var phase := rng.randf()
			var base_scale := Vector3(rng.randf_range(0.80, 1.25), rng.randf_range(0.85, 1.15), rng.randf_range(0.85, 1.35))
			if layer == 1:
				base_scale *= Vector3(1.25, 0.65, 1.25)
			_clouds.append({
				"batch": batch_index, "slot": slot, "layer": layer,
				"base": base, "height": float(LAYER_HEIGHTS[layer]) + rng.randf_range(-float(LAYER_HEIGHT_VARIATION[layer]), float(LAYER_HEIGHT_VARIATION[layer])),
				"scale": base_scale, "rotation": rng.randf_range(-PI, PI),
				# 互质置换使低覆盖时保留下来的云遍布整个天空。
				"rank": (float((cell * 19 + layer * 11) % (GRID.x * GRID.y)) + 0.5) / (GRID.x * GRID.y),
				"phase": phase,
			})
			_batches[batch_index].multimesh.set_instance_custom_data(slot, Color(phase, rng.randf(), 0.0, 1.0))


func _apply_material() -> void:
	if _material == null:
		return
	_material.set_shader_parameter("cloud_tint", _cloud_tint)
	_material.set_shader_parameter("overcast_tint", _deck_tint)
	_material.set_shader_parameter("cloud_density", _density)
	_material.set_shader_parameter("overcast_blend", _overcast_blend)
	_material.set_shader_parameter("deformation_amount", deformation_amount)


func _update_transforms() -> void:
	var anchor := Vector2.ZERO
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		var local_camera := to_local(camera.global_position)
		anchor = Vector2(local_camera.x, local_camera.z)
	for index in range(_clouds.size()):
		var cloud := _clouds[index]
		_batches[int(cloud["batch"])].multimesh.set_instance_transform(int(cloud["slot"]), get_cloud_transform(index, anchor))


## 可在无渲染器的诊断中查询同一份实际变换；observer 为本地 XZ 观察位置。
func get_cloud_transform(index: int, observer := Vector2.ZERO) -> Transform3D:
	var cloud := _clouds[index]
	var layer := int(cloud["layer"])
	var xy: Vector2 = cloud["base"] + _layer_offsets[layer] - observer
	xy = Vector2(wrapf(xy.x, -HALF_EXTENT, HALF_EXTENT), wrapf(xy.y, -HALF_EXTENT, HALF_EXTENT))
	# 循环边缘在地平线附近收缩至零，跨边界回收不会弹出一朵新云。
	var edge := 1.0 - smoothstep(920.0, 1160.0, xy.length())
	var rank := float(cloud["rank"])
	var growth := smoothstep(rank - 0.06, rank + 0.06, _coverage)
	if _coverage <= 0.001:
		growth = 0.0
	var spread := lerpf(0.85, 1.85, _coverage)
	var thickness := lerpf(0.65, 1.40, _density) * lerpf(1.0, 0.64, _overcast_blend)
	var cloud_scale: Vector3 = cloud["scale"] * Vector3(spread, thickness, spread)
	cloud_scale *= size_multiplier * growth * edge
	var basis := Basis(Vector3.UP, float(cloud["rotation"])) * Basis.from_scale(cloud_scale)
	var origin := Vector3(xy.x + observer.x, float(cloud["height"]), xy.y + observer.y)
	return Transform3D(basis, origin)
