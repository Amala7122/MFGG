extends SceneTree
## 通过统一天气入口验证首帧、渐变、照明和云影，禁止绕过运行驱动直接更新云场。

const Weather := preload("res://scripts/weather_system.gd")
const Field := preload("res://scripts/procedural_cloud_field.gd")
const Timeline := preload("res://scripts/weather_timeline.gd")
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://scenes/hyrule_field.tscn")
	for _frame in range(8):
		await process_frame
	var main_weather := current_scene.get_node("WeatherEnvironment/WeatherSystem") as Weather
	var main_field := main_weather.get_node("ProceduralCloudField") as Field
	var expected_coverage := main_weather.cloud_coverage if main_weather.cloud_enabled else 0.0
	var clouds_visible := expected_coverage > 0.001
	_check(is_equal_approx(float(main_field.get_weather_state()[0]), expected_coverage),
		"主场景运行后云场采用配置覆盖率")
	_check(main_field.visible == clouds_visible, "主场景云体遵循实际开关")
	if clouds_visible:
		_check(_casts_shadows(main_field) == main_weather.cloud_shadow_enabled, "主场景可见云体遵循云影开关")
	else:
		_check(not main_field.is_visible_in_tree(), "关闭云层的父节点阻止云体和云影绘制")
	if DisplayServer.get_name() != "headless":
		if clouds_visible:
			_check(_rendered_cloud_count(main_field) > 0, "主菜单暂停时也提交可见云体变换")
		else:
			_check(not main_field.is_visible_in_tree(), "关闭云层不绘制缓存的云体变换")
	print("[运行时云层测试] 主场景覆盖率：配置 %.2f / 云场 %.2f" % [
		main_weather.cloud_coverage, float(main_field.get_weather_state()[0])])
	current_scene.queue_free()
	await process_frame

	var scene := load("res://scenes/weather_environment.tscn").instantiate() as Node3D
	# 关闭随机天气导演，使用真实天气环境测试固定输入和确定的过渡时长。
	scene.get_node("WeatherTimeline").free()
	var weather := scene.get_node("WeatherSystem") as Weather
	weather.cloud_enabled = true
	weather.cloud_type = Weather.CloudType.CUMULUS
	weather.cloud_coverage = 0.46
	weather.cloud_density = 0.47
	weather.weather_transition_seconds = 1.8
	weather.rain_enabled = true
	weather.rain_preset = Weather.RainPreset.DOWNPOUR
	weather.fog_enabled = false
	weather.snow_enabled = false
	root.add_child(scene)
	current_scene = scene
	weather.set_process(false)
	var field := weather.get_node("ProceduralCloudField") as Field
	field.set_process(false)
	var sky := scene.get_node("Sky3D") as WorldEnvironment
	var dome := sky.get_node("SkyDome")
	var sun := sky.get_node("SunLight") as DirectionalLight3D
	var sky_material := dome.get("sky_material") as ShaderMaterial
	_check(is_equal_approx(float(field.get_weather_state()[0]), 0.46), "首帧立即采用覆盖率，无需等待过渡")
	_check(is_equal_approx(float(field.get_weather_state()[1]), 0.47), "首帧立即采用云厚度")
	_check(_casts_shadows(field), "首帧开启云影")
	if DisplayServer.get_name() != "headless":
		_check(_rendered_cloud_count(field) > 0, "首帧无需等待逐帧更新即可显示云体")
	_check(not bool(dome.get("cumulus_visible")), "程序云停用 Sky3D 的另一套积云")
	weather._update_environment()
	_check(not bool(dome.get("cumulus_visible")), "外部环境刷新不会重新开启另一套积云")
	_check(not sky.environment.fog_enabled, "暴雨不会擅自开启独立雾层")
	var clear_sun_energy := float(dome.get("sun_light_energy"))
	var clear_darkening := float(scene.get_node("Sky3DExperimentController").get("weather_darkening"))
	_check(is_zero_approx(clear_darkening), "多云保留晴天照明，暴雨不覆盖云型")

	weather.cloud_coverage = 0.82
	weather.cloud_density = 0.86
	weather.cloud_type = Weather.CloudType.STRATUS
	weather._process(0.45)
	_check(is_equal_approx(float(field.get_weather_state()[0]), 0.71), "运行入口按过渡时长平滑增加覆盖率")
	_check(is_equal_approx(float(field.get_weather_state()[1]), 0.72), "云厚度沿同一运行入口平滑变化")
	weather._process(1.8)
	_check(is_equal_approx(float(field.get_weather_state()[0]), 0.82), "覆盖率到达新目标")
	_check(is_equal_approx(float(field.get_weather_state()[1]), 0.86), "云厚度到达新目标")
	_check(is_equal_approx(float(sky_material.get_shader_parameter("weather_overcast")),
		0.82 * smoothstep(0.55, 0.88, 0.82)), "云幕使用当前覆盖率，父类更新不会覆盖它")
	weather._update_environment()
	_check(is_equal_approx(float(sky_material.get_shader_parameter("weather_overcast")),
		0.82 * smoothstep(0.55, 0.88, 0.82)), "外部环境刷新保留程序云幕")
	_check(float(dome.get("sun_light_energy")) < clear_sun_energy, "阴天云层降低直射光")
	_check(sky.environment.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR,
		"阴天云层切换到漫射环境光")
	var overcast_darkening := float(scene.get_node("Sky3DExperimentController").get("weather_darkening"))
	_check(overcast_darkening > clear_darkening, "云覆盖率和厚度驱动阴天暗度")

	weather.cloud_wind_speed = 13.0
	weather.cloud_wind_direction_degrees = 72.0
	weather.cloud_size_multiplier = 1.2
	weather.cloud_deformation_amount = 0.03
	weather.cloud_shape_style = 1
	weather.cloud_shadow_enabled = false
	weather._process(0.0)
	_check(is_equal_approx(field.wind_speed, 13.0) and is_equal_approx(field.wind_direction_degrees, 72.0),
		"运行入口同步云风速和方向")
	_check(is_equal_approx(field.size_multiplier, 1.2) and is_equal_approx(field.deformation_amount, 0.03),
		"运行入口同步云缩放和变形")
	_check(int(field.get_weather_state()[9]) == 1, "运行入口同步云形风格")
	_check(not _casts_shadows(field), "运行中可以关闭云影")
	_check(is_equal_approx(sun.light_angular_distance, weather._sun_angular_baseline), "关闭云影恢复太阳角径")
	_check(is_equal_approx(sun.directional_shadow_pancake_size, weather._sun_pancake_baseline),
		"关闭云影恢复太阳投影深度")
	weather.cloud_shadow_enabled = true
	weather._process(0.0)
	_check(_casts_shadows(field), "运行中可以重新开启云影")

	weather.set_rain_amount(0.0)
	weather.set_snow_amount(1.0)
	weather._process(1.8)
	_check(is_equal_approx(float(field.get_weather_state()[0]), 0.82), "雨雪变化不修改独立云覆盖率")
	_check(is_equal_approx(float(scene.get_node("Sky3DExperimentController").get("weather_darkening")),
		overcast_darkening), "雨雪变化不替代云层照明")
	_check(not sky.environment.fog_enabled, "雨雪变化不打开关闭的独立雾层")
	weather.cloud_enabled = false
	weather._process(0.9)
	_check(field.visible and is_equal_approx(float(field.get_weather_state()[0]), 0.32),
		"关闭云层时先平滑减少覆盖率")
	weather._process(0.9)
	_check(not field.visible and is_zero_approx(float(field.get_weather_state()[0])), "过渡结束后隐藏云场")
	_check(is_zero_approx(float(sky_material.get_shader_parameter("weather_overcast"))), "关闭云层也清空天空云幕")
	_check(is_equal_approx(sun.light_angular_distance, weather._sun_angular_baseline), "云场隐藏后恢复太阳角径")
	_check(is_equal_approx(sun.directional_shadow_pancake_size, weather._sun_pancake_baseline),
		"云场隐藏后恢复太阳投影深度")
	weather.cloud_enabled = true
	weather.cloud_type = Weather.CloudType.CUMULUS
	weather._process(1.8)
	_check(field.visible and is_equal_approx(float(field.get_weather_state()[0]), 0.82), "云层关闭后可以重新开启")
	_check(is_equal_approx(float(dome.get("sun_light_energy")), clear_sun_energy), "切回多云恢复直射光")
	_check_forecast(weather, field, scene)
	scene.queue_free()
	await process_frame
	print("[运行时云层测试] %s" % ["通过" if not _failed else "失败"])
	quit(1 if _failed else 0)


func _check_forecast(weather: Weather, field: Field, scene: Node3D) -> void:
	var timeline := Timeline.new()
	timeline._weather_system = weather
	var clear := Timeline.WeatherKeyframe.new(0.0)
	var overcast := Timeline.WeatherKeyframe.new(12.0)
	overcast.cloud_coverage = 1.0
	overcast.cloud_density = 0.75
	overcast.cloud_type = Weather.CloudType.STRATUS
	var tail := Timeline.WeatherKeyframe.new(96.0)
	timeline._keyframes = [clear, overcast, tail]
	timeline._apply_weather_at(0.0, false)
	_check(is_equal_approx(weather.cloud_coverage, 0.82), "导演初始化保留开场 Inspector 云层")
	timeline._apply_weather_at(0.0)
	weather._process(1.8)
	_check(not field.visible and not weather.cloud_enabled, "晴朗预报可以关闭云层")
	timeline._apply_weather_at(6.0)
	weather._process(1.8)
	_check(is_equal_approx(float(field.get_weather_state()[0]), 0.5)
		and is_equal_approx(float(field.get_weather_state()[1]), 0.5), "天气预报平滑插值覆盖率和厚度")
	timeline._apply_weather_at(12.0)
	weather._process(1.8)
	_check(is_equal_approx(float(field.get_weather_state()[0]), 1.0)
		and weather.cloud_type == Weather.CloudType.STRATUS, "无雨的阴天预报也能接管云层")
	_check(is_zero_approx(weather.continuous_rain_amount)
		and float(scene.get_node("Sky3DExperimentController").get("weather_darkening")) > 0.0,
		"无雨阴天由云层独立驱动照明")
	for pattern in Timeline.DayPattern.values():
		timeline._rng.seed = 1234
		var frames := timeline._generate_day(0, pattern, 225.0)
		for frame: Timeline.WeatherKeyframe in frames:
			_check(frame.cloud_coverage >= 0.0 and frame.cloud_coverage <= 1.0
				and frame.cloud_density >= 0.0 and frame.cloud_density <= 1.0,
				"所有日型的云层预报参数有效")
			if pattern == Timeline.DayPattern.WINDY_OVERCAST:
				_check(frame.cloud_type == Weather.CloudType.STRATUS and frame.cloud_coverage > 0.8,
					"大风阴天日型包含独立阴天云层")
		if pattern == Timeline.DayPattern.OVERCAST_DAY:
			_check(frames[2].cloud_coverage > 0.9 and frames[2].cloud_density > 0.7,
				"厚重云层预报同时增加覆盖率和厚度")
		if pattern == Timeline.DayPattern.STORM_DAY:
			_check(frames[3].cloud_type == Weather.CloudType.STRATUS and frames[3].cloud_coverage > 0.95,
				"暴雨峰值包含完整阴天云层")
	timeline.free()


func _casts_shadows(field: Field) -> bool:
	for batch in field.get_children():
		if (batch as MultiMeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
			return false
	return field.get_child_count() == 12


func _rendered_cloud_count(field: Field) -> int:
	var count := 0
	for child in field.get_children():
		var batch := child as MultiMeshInstance3D
		for index in range(batch.multimesh.instance_count):
			if batch.multimesh.get_instance_transform(index).basis.x.length() > 0.001:
				count += 1
	return count


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error("[运行时云层测试] " + message)
