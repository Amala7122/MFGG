@tool
extends RefCounted
## WeatherSystem 的编辑器视觉适配器。
##
## 只负责在 Godot 编辑器里把 WeatherSystem 的序列化参数投射到天空、太阳、
## 环境光、雾和低多边形云。它不会执行降雨、风、落点、音效或其它游戏逻辑。
## 以后若把天气系统抽成插件，这一层可以直接迁入 addons/ 作为编辑器部分。

const CloudField := preload("res://scripts/procedural_cloud_field.gd")
const CloudShadowLighting := preload("res://scripts/cloud_lighting.gd")

var _baseline_captured := false
var _preview_applied := false
var _last_signature := ""
var _base_sky: Dictionary = {}
var _base_environment: Dictionary = {}
var _base_sun: Dictionary = {}
var _base_camera_exposure := 1.0
var _base_cloud: Dictionary = {}
var _cloud_mesh: CloudField


## 返回当前用于低模补光的 weather_darkening；-1 表示预览关闭。
func update(
		host: Node,
		weather: Node,
		sky_world: WorldEnvironment,
		sky_dome: Node,
		sun: DirectionalLight3D
	) -> float:
	if not Engine.is_editor_hint() or weather == null or sky_world == null \
			or sky_dome == null or sun == null:
		return -1.0

	var preview_enabled := bool(weather.get("editor_preview_enabled"))
	if not preview_enabled:
		if _preview_applied:
			_restore(sky_world, sky_dome, sun)
		_reset_capture()
		return -1.0

	_capture_baseline(host, sky_world, sky_dome, sun)
	var signature := _make_signature(weather, sun)
	if signature == _last_signature and _preview_applied:
		return _preview_darkening(weather)
	_last_signature = signature

	var darkening := _apply(host, weather, sky_world, sky_dome, sun)
	_preview_applied = true
	return darkening


func shutdown(sky_world: WorldEnvironment, sky_dome: Node, sun: DirectionalLight3D) -> void:
	if not Engine.is_editor_hint():
		return
	if _preview_applied and sky_world != null and sky_dome != null and sun != null:
		_restore(sky_world, sky_dome, sun)
	_reset_capture()


func _capture_baseline(
		host: Node,
		sky_world: WorldEnvironment,
		sky_dome: Node,
		sun: DirectionalLight3D
	) -> void:
	if _baseline_captured:
		_capture_cloud_baseline(host)
		return

	for key in [
		"cumulus_visible", "sun_disk_intensity", "atm_sun_mie_intensity",
		"sun_light_energy", "atm_darkness", "exposure", "atm_day_tint",
		"atm_night_tint", "atm_horizon_light_tint", "ground_color",
		"fog_visible", "fog_density", "fog_start", "fog_end"
	]:
		_base_sky[key] = sky_dome.get(key)

	var sky_material := sky_dome.get("sky_material") as ShaderMaterial
	if sky_material != null:
		_base_sky["weather_overcast"] = sky_material.get_shader_parameter("weather_overcast")
		_base_sky["weather_cloud_density"] = sky_material.get_shader_parameter("weather_cloud_density")
		_base_sky["weather_horizon"] = sky_material.get_shader_parameter("weather_horizon")

	var environment := sky_world.environment
	if environment != null:
		_base_environment = {
			"fog_enabled": environment.fog_enabled,
			"fog_mode": environment.fog_mode,
			"fog_light_color": environment.fog_light_color,
			"fog_light_energy": environment.fog_light_energy,
			"fog_density": environment.fog_density,
			"fog_aerial_perspective": environment.fog_aerial_perspective,
			"fog_sun_scatter": environment.fog_sun_scatter,
			"fog_sky_affect": environment.fog_sky_affect,
			"ambient_light_source": environment.ambient_light_source,
			"ambient_light_color": environment.ambient_light_color,
			"ambient_light_energy": environment.ambient_light_energy,
			"ambient_light_sky_contribution": environment.ambient_light_sky_contribution,
			"tonemap_exposure": environment.tonemap_exposure,
		}

	_base_sun = {
		"light_energy": sun.light_energy,
		"light_specular": sun.light_specular,
		"shadow_opacity": sun.shadow_opacity,
		"shadow_blur": sun.shadow_blur,
		"light_angular_distance": sun.light_angular_distance,
		"directional_shadow_pancake_size": sun.directional_shadow_pancake_size,
	}
	if sky_world.camera_attributes != null:
		_base_camera_exposure = sky_world.camera_attributes.exposure_multiplier

	_baseline_captured = true
	_capture_cloud_baseline(host)


func _capture_cloud_baseline(host: Node) -> void:
	_resolve_cloud_mesh(host)
	if not is_instance_valid(_cloud_mesh) or not _base_cloud.is_empty():
		return
	_base_cloud["state"] = _cloud_mesh.get_weather_state()


func _apply(
		host: Node,
		weather: Node,
		sky_world: WorldEnvironment,
		sky_dome: Node,
		sun: DirectionalLight3D
	) -> float:
	var cloud_enabled := bool(weather.get("cloud_enabled"))
	var coverage := clampf(float(weather.get("cloud_coverage")), 0.0, 1.0) \
		if cloud_enabled else 0.0
	var density := clampf(float(weather.get("cloud_density")), 0.0, 1.0)
	var cloud_type := int(weather.get("cloud_type"))
	var daylight := smoothstep(-0.06, 0.25, sun.global_basis.z.normalized().y)
	var overcast_blend := smoothstep(0.55, 0.88, coverage)
	var deck_cover := coverage * overcast_blend
	var stratus_cover := coverage if cloud_type == 1 else 0.0
	var darkening := _preview_darkening(weather)

	# 云幕与运行时使用同一组颜色逻辑。编辑器里也不启用 Sky3D 写实 Cumulus。
	sky_dome.set("cumulus_visible", false)
	var day_light_deck := Color(0.67, 0.71, 0.75, 1.0)
	var day_storm_deck := Color(0.25, 0.29, 0.34, 1.0)
	var night_deck := Color(0.10, 0.13, 0.18, 1.0)
	var heavy_factor := smoothstep(0.52, 1.0, density) * smoothstep(0.65, 1.0, coverage)
	var day_deck := day_light_deck.lerp(day_storm_deck, heavy_factor)
	var matte_deck := night_deck.lerp(day_deck, daylight)

	var sky_material := sky_dome.get("sky_material") as ShaderMaterial
	if sky_material != null:
		sky_material.set_shader_parameter("weather_overcast", deck_cover)
		sky_material.set_shader_parameter("weather_cloud_density", density)
		sky_material.set_shader_parameter("weather_horizon", matte_deck)

	_apply_cloud_banks(host, weather, coverage, density, overcast_blend, daylight, matte_deck)
	_apply_sun_and_sky(sky_dome, sun, stratus_cover, darkening)
	CloudShadowLighting.apply_cloud_shadow_softness(weather, sun,
		float(_base_sun.get("light_angular_distance", 0.0)),
		coverage > 0.001 and is_instance_valid(_cloud_mesh),
		float(_base_sun.get("directional_shadow_pancake_size", 20.0)),
		_cloud_mesh.get_cloud_height_ceiling() if is_instance_valid(_cloud_mesh) else 650.0)
	_apply_environment(weather, sky_world, stratus_cover, darkening, daylight)
	return darkening


func _apply_cloud_banks(
		host: Node,
		weather: Node,
		coverage: float,
		density: float,
		overcast_blend: float,
		daylight: float,
		matte_deck: Color
	) -> void:
	_resolve_cloud_mesh(host)
	if not is_instance_valid(_cloud_mesh):
		return
	_capture_cloud_baseline(host)

	var day_bank_light := Color(0.78, 0.82, 0.86, 1.0)
	var day_bank_heavy := Color(0.34, 0.39, 0.45, 1.0)
	var night_bank := Color(0.11, 0.14, 0.20, 1.0)
	var bank_heavy := smoothstep(0.50, 1.0, density) * smoothstep(0.45, 1.0, coverage)
	var day_bank := day_bank_light.lerp(day_bank_heavy, bank_heavy)
	var matte_bank := night_bank.lerp(day_bank, daylight)
	_cloud_mesh.set_motion(float(weather.get("cloud_wind_speed")),
		float(weather.get("cloud_wind_direction_degrees")),
		float(weather.get("cloud_size_multiplier")), float(weather.get("cloud_deformation_amount")))
	_cloud_mesh.set_shape_style(int(weather.get("cloud_shape_style")))
	_cloud_mesh.set_weather(coverage, density, overcast_blend, matte_bank, matte_deck)
	_cloud_mesh.set_cloud_shadows(bool(weather.get("cloud_shadow_enabled")))


func _apply_sun_and_sky(
		sky_dome: Node,
		sun: DirectionalLight3D,
		stratus_cover: float,
		darkening: float
	) -> void:
	var sun_occlusion := smoothstep(0.04, 0.88, stratus_cover)
	var sun_disk_scale := 1.0 - smoothstep(0.02, 0.72, stratus_cover)
	var direct_sun_scale := lerpf(1.0, 0.06, sun_occlusion)
	var specular_scale := lerpf(1.0, 0.025, smoothstep(0.0, 0.72, stratus_cover))
	var shadow_scale := lerpf(1.0, 0.10, sun_occlusion)

	sky_dome.set(
		"sun_disk_intensity",
		float(_base_sky.get("sun_disk_intensity", 24.0)) * sun_disk_scale
	)
	sky_dome.set(
		"atm_sun_mie_intensity",
		float(_base_sky.get("atm_sun_mie_intensity", 1.0)) * sun_disk_scale
	)
	var sun_energy := float(_base_sky.get("sun_light_energy", 1.5)) * direct_sun_scale
	sky_dome.set("sun_light_energy", sun_energy)
	sun.light_energy = float(_base_sun.get("light_energy", sun_energy)) * direct_sun_scale
	sun.light_specular = float(_base_sun.get("light_specular", 1.0)) * specular_scale
	sun.shadow_opacity = float(_base_sun.get("shadow_opacity", 1.0)) * shadow_scale
	sun.shadow_blur = lerpf(float(_base_sun.get("shadow_blur", 1.0)), 1.45, sun_occlusion)

	sky_dome.set(
		"atm_darkness",
		lerpf(float(_base_sky.get("atm_darkness", 0.48)), 0.72, darkening)
	)
	sky_dome.set(
		"exposure",
		lerpf(float(_base_sky.get("exposure", 0.805)), 0.72, darkening)
	)
	var base_day := _base_sky.get("atm_day_tint", Color(0.76, 0.87, 0.96, 1.0)) as Color
	var base_night := _base_sky.get("atm_night_tint", Color(0.08, 0.12, 0.22, 1.0)) as Color
	var base_horizon := _base_sky.get(
		"atm_horizon_light_tint", Color(0.96, 0.70, 0.52, 1.0)
	) as Color
	sky_dome.set("atm_day_tint", base_day.lerp(Color(0.27, 0.325, 0.39, 1.0), darkening))
	sky_dome.set("atm_night_tint", base_night.lerp(Color(0.05, 0.065, 0.085, 1.0), darkening * 0.72))
	sky_dome.set("atm_horizon_light_tint", base_horizon.lerp(Color(0.28, 0.31, 0.35, 1.0), darkening))


func _apply_environment(
		weather: Node,
		sky_world: WorldEnvironment,
		stratus_cover: float,
		darkening: float,
		daylight: float
	) -> void:
	var environment := sky_world.environment
	if environment == null or _base_environment.is_empty():
		return

	if stratus_cover > 0.001:
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	else:
		environment.ambient_light_source = int(_base_environment.get(
			"ambient_light_source", Environment.AMBIENT_SOURCE_SKY
		))
	var light_overcast := Color(0.43, 0.49, 0.58).lerp(Color(0.72, 0.76, 0.82), daylight)
	var deep_overcast := Color(0.27, 0.31, 0.38).lerp(Color(0.47, 0.52, 0.59), daylight)
	var overcast_ambient := light_overcast.lerp(deep_overcast, darkening)
	var base_ambient := _base_environment.get("ambient_light_color", Color.WHITE) as Color
	environment.ambient_light_color = base_ambient.lerp(overcast_ambient, stratus_cover)
	var overcast_energy := lerpf(0.38, 0.86, daylight) * lerpf(1.0, 0.70, darkening)
	environment.ambient_light_energy = lerpf(
		float(_base_environment.get("ambient_light_energy", 1.0)),
		overcast_energy,
		stratus_cover
	)
	environment.ambient_light_sky_contribution = lerpf(
		float(_base_environment.get("ambient_light_sky_contribution", 1.0)),
		0.0,
		stratus_cover
	)
	environment.tonemap_exposure = lerpf(
		float(_base_environment.get("tonemap_exposure", 1.0)), 0.84, darkening
	)
	if sky_world.camera_attributes != null:
		sky_world.camera_attributes.exposure_multiplier = lerpf(
			_base_camera_exposure, 1.0, darkening
		)

	var fog_enabled := bool(weather.get("fog_enabled"))
	var fog_strength := clampf(float(weather.get("fog_amount")), 0.0, 1.0) \
		if fog_enabled else 0.0
	var fog_distance := maxf(float(weather.get("fog_visibility_distance")), 1.0)
	var fog_color: Color = weather.get("fog_color")
	environment.fog_enabled = fog_strength > 0.001
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_light_color = fog_color
	environment.fog_light_energy = 1.0
	environment.fog_aerial_perspective = 0.0
	environment.fog_sun_scatter = 0.0
	environment.fog_sky_affect = 0.0
	environment.fog_density = 4.6 / fog_distance * pow(fog_strength, 1.6)

	var atmospheric_share := 1.0 - smoothstep(0.12, 0.50, fog_strength)
	var sky_dome := sky_world.get_node_or_null("SkyDome")
	if sky_dome != null:
		sky_dome.set("fog_visible", atmospheric_share > 0.02)
		sky_dome.set(
			"fog_density",
			float(_base_sky.get("fog_density", 1.0)) * atmospheric_share
		)
		sky_dome.set(
			"fog_start",
			lerpf(float(_base_sky.get("fog_start", 85.0)), 18.0, fog_strength)
		)
		sky_dome.set(
			"fog_end",
			lerpf(float(_base_sky.get("fog_end", 820.0)), fog_distance, fog_strength)
		)


func _preview_darkening(weather: Node) -> float:
	if not bool(weather.get("cloud_enabled")) or int(weather.get("cloud_type")) == 0:
		return 0.0
	var coverage := clampf(float(weather.get("cloud_coverage")), 0.0, 1.0)
	var density := clampf(float(weather.get("cloud_density")), 0.0, 1.0)
	return smoothstep(0.35, 1.0, coverage) * smoothstep(0.12, 1.0, density) * 0.96


func _make_signature(weather: Node, sun: DirectionalLight3D) -> String:
	return "%s|%s|%.4f|%.4f|%s|%.4f|%.2f|%s|%.5f|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%.4f" % [
		str(weather.get("cloud_enabled")),
		str(weather.get("cloud_type")),
		float(weather.get("cloud_coverage")),
		float(weather.get("cloud_density")),
		str(weather.get("fog_enabled")),
		float(weather.get("fog_amount")),
		float(weather.get("fog_visibility_distance")),
		str(weather.get("fog_color")),
		sun.global_basis.z.normalized().y,
		weather.get("cloud_wind_speed"), weather.get("cloud_wind_direction_degrees"),
		weather.get("cloud_size_multiplier"), weather.get("cloud_deformation_amount"),
		weather.get("cloud_shape_style"),
		weather.get("cloud_shadow_enabled"),
		weather.get("cloud_shadow_strong_sun_angle"), weather.get("cloud_shadow_weak_sun_angle"),
		weather.get("cloud_shadow_reference_energy"),
		_cloud_mesh.get_instance_id() if is_instance_valid(_cloud_mesh) else 0,
		sun.light_energy,
	]


func _resolve_cloud_mesh(host: Node) -> void:
	if is_instance_valid(_cloud_mesh):
		return
	var root := host.get_tree().edited_scene_root
	if root == null:
		root = host.get_tree().current_scene
	if root != null:
		_cloud_mesh = root.find_child("ProceduralCloudField", true, false) as CloudField
		_base_cloud.clear()


func _restore(
		sky_world: WorldEnvironment,
		sky_dome: Node,
		sun: DirectionalLight3D
	) -> void:
	if not _baseline_captured:
		return
	for key in [
		"cumulus_visible", "sun_disk_intensity", "atm_sun_mie_intensity",
		"sun_light_energy", "atm_darkness", "exposure", "atm_day_tint",
		"atm_night_tint", "atm_horizon_light_tint", "ground_color",
		"fog_visible", "fog_density", "fog_start", "fog_end"
	]:
		if _base_sky.has(key):
			sky_dome.set(key, _base_sky[key])
	var sky_material := sky_dome.get("sky_material") as ShaderMaterial
	if sky_material != null:
		for key in ["weather_overcast", "weather_cloud_density", "weather_horizon"]:
			if _base_sky.has(key):
				sky_material.set_shader_parameter(key, _base_sky[key])

	if not _base_sun.is_empty():
		sun.light_energy = float(_base_sun.get("light_energy", sun.light_energy))
		sun.light_specular = float(_base_sun.get("light_specular", sun.light_specular))
		sun.shadow_opacity = float(_base_sun.get("shadow_opacity", sun.shadow_opacity))
		sun.shadow_blur = float(_base_sun.get("shadow_blur", sun.shadow_blur))
		sun.light_angular_distance = float(_base_sun.get("light_angular_distance", sun.light_angular_distance))
		sun.directional_shadow_pancake_size = float(_base_sun.get("directional_shadow_pancake_size", sun.directional_shadow_pancake_size))

	var environment := sky_world.environment
	if environment != null and not _base_environment.is_empty():
		environment.fog_enabled = bool(_base_environment.get("fog_enabled", false))
		environment.fog_mode = int(_base_environment.get("fog_mode", Environment.FOG_MODE_EXPONENTIAL))
		environment.fog_light_color = _base_environment.get("fog_light_color", Color.WHITE) as Color
		environment.fog_light_energy = float(_base_environment.get("fog_light_energy", 1.0))
		environment.fog_density = float(_base_environment.get("fog_density", 0.0))
		environment.fog_aerial_perspective = float(_base_environment.get("fog_aerial_perspective", 0.0))
		environment.fog_sun_scatter = float(_base_environment.get("fog_sun_scatter", 0.0))
		environment.fog_sky_affect = float(_base_environment.get("fog_sky_affect", 1.0))
		environment.ambient_light_source = int(_base_environment.get("ambient_light_source", Environment.AMBIENT_SOURCE_SKY))
		environment.ambient_light_color = _base_environment.get("ambient_light_color", Color.WHITE) as Color
		environment.ambient_light_energy = float(_base_environment.get("ambient_light_energy", 1.0))
		environment.ambient_light_sky_contribution = float(_base_environment.get("ambient_light_sky_contribution", 1.0))
		environment.tonemap_exposure = float(_base_environment.get("tonemap_exposure", 1.0))
	if sky_world.camera_attributes != null:
		sky_world.camera_attributes.exposure_multiplier = _base_camera_exposure

	if is_instance_valid(_cloud_mesh) and not _base_cloud.is_empty():
		_cloud_mesh.restore_weather_state(_base_cloud["state"])
	_preview_applied = false


func _reset_capture() -> void:
	_baseline_captured = false
	_preview_applied = false
	_last_signature = ""
	_base_sky.clear()
	_base_environment.clear()
	_base_sun.clear()
	_base_cloud.clear()
	_cloud_mesh = null
