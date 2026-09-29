extends Node3D
class_name WeatherRainController
## 雨层与风场。WeatherSystem 是对外的统一入口，本脚本负责雨的实现。
##
## 设计边界：
## - Inspector 选好降雨档位，运行后立刻是该天气，不需要等待随机天气轮换。
## - 默认风场是“静风 -> 阵风 -> 静风”的状态机；静风阶段输出严格为 0。
## - 同一股风同时驱动雨线、草和地面雨点带，避免各套效果互相穿帮。
## - Sky3D 提供晴天天空；阴雨增加漫射天幕与原生距离雨雾。

const TerrainFieldUtil := preload("res://scripts/terrain_field.gd")
const RainStreakShader := preload("res://shaders/weather_rain_streak.gdshader")
const RainImpactShader := preload("res://shaders/weather_rain_impact.gdshader")
const CloudLighting := preload("res://scripts/cloud_lighting.gd")


enum RainPreset { CLEAR, DRIZZLE, STEADY, HEAVY, DOWNPOUR }
enum WindMode { NATURAL_GUSTS, FORCE_CALM, FORCE_PREVIEW_GUST }

## 五档不只是密度不同：这些曲线共同决定连续性、速度、粗细、亮度与落点表现。
## 横坐标与 preset_intensity() 一致：晴朗 / 小雨 / 中雨 / 大雨 / 暴雨。
const PROFILE_INTENSITIES := [0.0, 0.18, 0.43, 0.72, 1.0]

const DefaultProfiles := [
	preload("res://data/weather/clear.tres"),
	preload("res://data/weather/drizzle.tres"),
	preload("res://data/weather/steady.tres"),
	preload("res://data/weather/heavy.tres"),
	preload("res://data/weather/downpour.tres"),
]

@export_category("雨天参数资源（展开每档调整，保存资源持久化）")
## 固定顺序：晴朗、小雨、中雨、大雨、暴雨。空项自动使用对应默认资源。
@export var weather_profiles: Array[Resource] = [DefaultProfiles[0], DefaultProfiles[1], DefaultProfiles[2], DefaultProfiles[3], DefaultProfiles[4]]
## 开启后使用下面的 0..1 连续雨量；关闭则使用离散档位选择。
@export var continuous_rain_enabled := false
## 0=晴朗，0.18=小雨，0.43=中雨，0.72=大雨，1=暴雨；中间值联动插值。
@export_range(0.0, 1.0, 0.001) var continuous_rain_amount := 0.43

signal wind_changed(wind_vector: Vector2, strength: float)

@export_category("天气（运行前直接指定）")
## 本次运行直接使用的天气。当前只实现雨：晴朗关闭降水，其余四档使用不同的
## 密度、连续性、速度、线宽、亮度和地面落点曲线，不是同一效果的简单加密。
@export_enum("晴朗:0", "小雨:1", "中雨:2", "大雨:3", "暴雨:4") var rain_preset: int = RainPreset.STEADY
## 切换预设时，从旧雨量平滑过渡到新雨量所需的秒数。只影响过渡速度，不改变
## 最终档位强度；开场直接使用 Inspector 选定天气，之后的切换才渐变。
@export_range(0.1, 8.0, 0.1) var weather_transition_seconds := 1.8

@export_category("阵风（默认不会持续吹）")
## 自然阵风=静风与阵风随机交替；强制静风=始终无风；持续预览阵风=为了调效果
## 明确保持一股风。正式体验建议使用“自然阵风”。
@export_enum("自然阵风:0", "强制静风:1", "持续预览阵风:2") var wind_mode: int = WindMode.NATURAL_GUSTS
## 主导风向，单位为角度。自然阵风会在这个方向附近偏转；持续预览阵风严格使用它。
@export_range(0.0, 360.0, 1.0, "degrees") var prevailing_direction_degrees := 225.0
## 只在“持续预览阵风”模式生效。0=无风，1=当前允许的最强阵风。
@export_range(0.0, 1.0, 0.01) var preview_gust_strength := 0.72
## 自然风两次阵风之间的最短静风时间。
@export_range(0.5, 30.0, 0.5) var calm_seconds_min := 5.0
## 自然风两次阵风之间的最长静风时间；因此世界可以较长时间完全无风。
@export_range(1.0, 45.0, 0.5) var calm_seconds_max := 18.0
## 单次阵风最短持续时间。
@export_range(0.4, 10.0, 0.1) var gust_seconds_min := 1.4
## 单次阵风最长持续时间。
@export_range(0.5, 14.0, 0.1) var gust_seconds_max := 4.8
## 自然阵风随机峰值的下限。
@export_range(0.05, 1.0, 0.01) var gust_strength_min := 0.18
## 自然阵风随机峰值的上限。
@export_range(0.05, 1.0, 0.01) var gust_strength_max := 0.92
## 每股自然阵风相对主导风向允许左右偏转的最大角度。
@export_range(0.0, 90.0, 1.0, "degrees") var gust_direction_variation := 38.0

@export_category("雨线（数值表示暴雨上限）")
## 暴雨时允许同时存在的雨滴上限。其它档位按内部曲线取其中一部分；修改后需重开场景。
@export_range(100, 30000, 100) var maximum_streaks := 12000
## 以相机为中心生成雨滴的水平半径。越大覆盖越远，但相同数量会显得更稀；需重开场景。
@export_range(5.0, 40.0, 0.5) var rain_radius := 18.0
## 雨滴发射盒位于相机上方的高度。太低容易看到生成边界，太高则可能落不到地面。
@export_range(4.0, 24.0, 0.5) var emitter_height := 11.0
## 暴雨档的最大下落速度（米/秒）。小雨、中雨和大雨按各自比例自动降低。
@export_range(10.0, 90.0, 0.5) var fall_speed := 58.0

@export_category("地面落点（数值表示暴雨上限）")
## 可同时保留的地面雨点环数量。池满后循环覆盖最旧落点；修改后需重开场景。
@export_range(32, 2048, 16) var impact_pool_size := 768
## 只在相机周围这个半径内生成地面落点，避免为玩家看不到的远处付出开销。
@export_range(2.0, 30.0, 0.5) var impact_radius := 16.0
## 暴雨档每秒生成的地面落点数。小雨约为其 0.4%，中雨约 18%，大雨约 52%。
@export_range(10.0, 1000.0, 1.0) var impacts_per_second_at_downpour := 520.0

@export_category("大雨 / 暴雨环境联动")
## 阵风改变新雨滴落点的疏密分布；已落地的水花固定在原位置。
@export var wind_impact_bands_enabled := true
## 雨点带的疏密对比。0=均匀落雨，1=明显的弯曲密集雨带。
@export_range(0.0, 1.0, 0.05) var wind_impact_band_contrast := 0.95
## 白天暴雨天幕和远处雨雾共同使用的冷灰色。修改此项不改变地表光照。
@export var downpour_sky_color := Color(0.39, 0.43, 0.48)
## 暴雨时远景完全进入雨雾的距离；较小会更快吞没远山，但不要低于战斗距离。
@export_range(70.0, 400.0, 5.0) var downpour_fog_end := 120.0
## 暴雨对天空与日照的接管程度。1=阴沉冷灰天空与弱日照，但不会把天空压成纯黑。
@export_range(0.0, 1.0, 0.01) var storm_environment_strength := 1.0
## 从无雾增长到目标雨雾所需的最短秒数。雨可以先落下来，远景随后才逐渐消失。
@export_range(2.0, 90.0, 1.0) var fog_build_seconds := 22.0
## 停雨后雨雾完全消散所需的秒数。默认比起雾慢，符合湿空气不会瞬间清空。
@export_range(2.0, 180.0, 1.0) var fog_clear_seconds := 38.0

@onready var _sky_dome: Node = get_node_or_null("../Sky3D/SkyDome")
@onready var _sky_controller: Node = get_node_or_null("../Sky3DExperimentController")
@onready var _sun: DirectionalLight3D = get_node_or_null("../Sky3D/SunLight")
@onready var _moon: DirectionalLight3D = get_node_or_null("../Sky3D/MoonLight")
@onready var _sky_world: WorldEnvironment = get_node_or_null("../Sky3D") as WorldEnvironment

## 由统一入口注入的独立天气层；与降雨插值分别保存，组合时只汇总一次天空/雾。
var _external_fog_strength := 0.0
var _baseline_fog_enabled := false
var _external_cloud_cover := 0.0
## 0=Cumulus 多云，1=Stratus 阴天。底层只需要知道当前合成风格。
var _external_cloud_style := 1
var _external_cloud_density := 0.0
var _external_storm_strength := 0.0
var _standalone_fog_distance := 150.0
var _standalone_fog_color := Color(0.72, 0.79, 0.83)
## 兼容旧实验：直接实例化 WeatherRainController 时雨仍会带来阴天/雨雾；
## WeatherSystem 会把它设为 0，让云、雨、雾、雪成为真正独立的输入层。
var _precipitation_environment_coupling := 1.0

var _rain_particles: GPUParticles3D
var _rain_process: ParticleProcessMaterial
var _streak_material: ShaderMaterial
var _impact_multimesh: MultiMesh
var _impact_node: MultiMeshInstance3D
var _backdrop_clouds: MeshInstance3D
var _backdrop_landforms: MeshInstance3D

var _rng := RandomNumberGenerator.new()
var _rain_intensity := 0.0
var _wetness := 0.0
var _fog_amount := 0.0
var _impact_budget := 0.0
var _impact_cursor := 0
var _impact_ages := PackedFloat32Array()
var _impact_lifetimes := PackedFloat32Array()
var _impact_strengths := PackedFloat32Array()
var _impact_phases := PackedFloat32Array()
var _impact_levels := PackedFloat32Array()

var _wind_direction := Vector2(1.0, 0.0)
var _wind_strength := 0.0
var _gust_peak := 0.0
var _gust_elapsed := 0.0
var _gust_duration := 1.0
var _wind_state_timer := 0.0
var _in_gust := false
var _wind_clock := 0.0
var _impact_advection := Vector2.ZERO

var _base_sky: Dictionary = {}
var _base_environment: Dictionary = {}


func _ready() -> void:
	_rng.randomize()
	_build_rain_streaks()
	_build_ground_impacts()
	_capture_sky_baseline()
	_begin_calm(true)
	# 预设决定运行首帧天气。
	_rain_intensity = _target_intensity()
	# 云层本身不等于雾。只有旧雨雾联动或独立 Fog Layer 才决定开场雾量。
	var opening_rain_fog := profile_value(&"storm_strength") * storm_environment_strength * _precipitation_environment_coupling
	_fog_amount = 1.0 - (1.0 - clampf(opening_rain_fog, 0.0, 1.0)) * (1.0 - _external_fog_strength)
	_update_environment()
	set_process(true)


func _exit_tree() -> void:
	# 实验场景重载时显式清空接收端，避免编辑器远程调试暂停在上一股阵风上。
	get_tree().call_group("weather_wind_receiver", "set_weather_wind", Vector2.ZERO, 0.0)
	get_tree().call_group("weather_wetness_receiver", "set_weather_wetness", 0.0)


func _process(delta: float) -> void:
	var target_rain := _target_intensity()
	var transition_speed := 1.0 / maxf(weather_transition_seconds, 0.1)
	_rain_intensity = move_toward(_rain_intensity, target_rain, delta * transition_speed)
	_update_wind(delta)
	_impact_advection += get_wind_vector() * delta * 7.0
	_update_rain_particles()
	_update_impacts(delta)
	_update_wetness(delta)
	_update_environment(delta)
	_broadcast_weather()


static func preset_intensity(preset: int) -> float:
	match preset:
		RainPreset.DRIZZLE:
			return 0.18
		RainPreset.STEADY:
			return 0.43
		RainPreset.HEAVY:
			return 0.72
		RainPreset.DOWNPOUR:
			return 1.0
		_:
			return 0.0


static func gust_envelope(progress: float) -> float:
	# 前段较快抬升、后段缓慢退去；两个 smoothstep 相乘，首尾严格回到 0。
	var t := clampf(progress, 0.0, 1.0)
	return smoothstep(0.0, 0.20, t) * (1.0 - smoothstep(0.62, 1.0, t))


func _target_intensity() -> float:
	return clampf(continuous_rain_amount, 0.0, 1.0) if continuous_rain_enabled else preset_intensity(rain_preset)


## 后续天气导演直接调用；与 Inspector 共用同一条渐变路径。
func set_rain_amount(amount: float) -> void:
	continuous_rain_amount = clampf(amount, 0.0, 1.0)
	continuous_rain_enabled = true


func _profile(index: int) -> Resource:
	if index < weather_profiles.size() and weather_profiles[index] != null \
			and weather_profiles[index].get_script() == DefaultProfiles[index].get_script():
		return weather_profiles[index]
	return DefaultProfiles[index]


func profile_value(key: StringName, intensity: float = -1.0) -> float:
	var rain := clampf(_rain_intensity if intensity < 0.0 else intensity, 0.0, 1.0)
	for index in range(1, PROFILE_INTENSITIES.size()):
		var right := float(PROFILE_INTENSITIES[index])
		if rain <= right:
			var weight := inverse_lerp(float(PROFILE_INTENSITIES[index - 1]), right, rain)
			return lerpf(float(_profile(index - 1).get(key)), float(_profile(index).get(key)), weight)
	return float(_profile(4).get(key))


func impact_diameter_range() -> Vector2:
	var a := maxf(profile_value(&"impact_size_min"), 0.0)
	var b := maxf(profile_value(&"impact_size_max"), 0.0)
	return Vector2(minf(a, b), maxf(a, b))


func sample_impact_diameter() -> float:
	var bounds := impact_diameter_range()
	return _rng.randf_range(bounds.x, bounds.y)


func get_wind_vector() -> Vector2:
	return _wind_direction * _wind_strength


func _build_rain_streaks() -> void:
	_rain_particles = GPUParticles3D.new()
	_rain_particles.name = "RainStreaks"
	_rain_particles.amount = maximum_streaks
	_rain_particles.amount_ratio = 0.0
	_rain_particles.lifetime = 0.92
	_rain_particles.fixed_fps = 45
	_rain_particles.fract_delta = true
	_rain_particles.interpolate = true
	_rain_particles.local_coords = false
	_rain_particles.visibility_aabb = AABB(
		Vector3(-rain_radius * 1.8, -30.0, -rain_radius * 1.8),
		Vector3(rain_radius * 3.6, 60.0, rain_radius * 3.6)
	)
	_rain_particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_rain_particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY

	_rain_process = ParticleProcessMaterial.new()
	_rain_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_rain_process.emission_box_extents = Vector3(rain_radius, 1.2, rain_radius)
	_rain_process.direction = Vector3.DOWN
	_rain_process.spread = 2.5
	_rain_process.initial_velocity_min = fall_speed * 0.88
	_rain_process.initial_velocity_max = fall_speed * 1.12
	_rain_process.gravity = Vector3(0.0, -7.0, 0.0)
	_rain_process.scale_min = 0.72
	_rain_process.scale_max = 1.25
	_rain_process.color = Color(0.48, 0.66, 0.76, 0.62)
	_rain_particles.process_material = _rain_process

	_streak_material = ShaderMaterial.new()
	_streak_material.shader = RainStreakShader
	var streak_mesh := QuadMesh.new()
	streak_mesh.size = Vector2(0.018, 0.92)
	streak_mesh.material = _streak_material
	_rain_particles.draw_pass_1 = streak_mesh
	add_child(_rain_particles)
	_rain_particles.restart()


func _build_ground_impacts() -> void:
	_impact_multimesh = MultiMesh.new()
	_impact_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_impact_multimesh.use_custom_data = true
	_impact_multimesh.instance_count = impact_pool_size
	_impact_multimesh.visible_instance_count = impact_pool_size

	var impact_material := ShaderMaterial.new()
	impact_material.shader = RainImpactShader
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = impact_material
	_impact_multimesh.mesh = quad

	_impact_node = MultiMeshInstance3D.new()
	_impact_node.name = "GroundRainImpacts"
	_impact_node.multimesh = _impact_multimesh
	_impact_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var world_extent := TerrainFieldUtil.get_extent() + impact_radius + 4.0
	_impact_node.custom_aabb = AABB(
		Vector3(-world_extent, -12.0, -world_extent),
		Vector3(world_extent * 2.0, 36.0, world_extent * 2.0)
	)
	add_child(_impact_node)

	_impact_ages.resize(impact_pool_size)
	_impact_lifetimes.resize(impact_pool_size)
	_impact_strengths.resize(impact_pool_size)
	_impact_phases.resize(impact_pool_size)
	_impact_levels.resize(impact_pool_size)
	for index in impact_pool_size:
		_impact_ages[index] = 2.0
		_impact_lifetimes[index] = 1.0
		_impact_multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY, Vector3.ZERO))
		_impact_multimesh.set_instance_custom_data(index, Color(2.0, 0.0, 0.0, 0.0))


func _update_rain_particles() -> void:
	if not is_instance_valid(_rain_particles):
		return
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		_rain_particles.global_position = Vector3(
			camera.global_position.x,
			camera.global_position.y + emitter_height,
			camera.global_position.z
		)
	var ratio := profile_value(&"streak_density")
	_rain_particles.amount_ratio = ratio
	_rain_particles.emitting = ratio > 0.001
	var wind := get_wind_vector()
	var fall_direction := Vector3(wind.x * 0.34, -1.0, wind.y * 0.34).normalized()
	_rain_process.direction = fall_direction
	_rain_process.gravity = Vector3(wind.x * 4.5, -7.0, wind.y * 4.5)
	var speed := fall_speed * profile_value(&"streak_speed")
	_rain_process.initial_velocity_min = speed * 0.90
	_rain_process.initial_velocity_max = speed * 1.10
	_rain_process.color = Color(
		0.48, 0.66, 0.76, lerpf(0.40, 0.76, profile_value(&"streak_brightness"))
	)
	if is_instance_valid(_streak_material):
		var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) \
			if is_instance_valid(_sun) else 0.0
		_streak_material.set_shader_parameter("u_daylight", daylight)
		_streak_material.set_shader_parameter(
			"u_width_scale", profile_value(&"streak_width")
		)
		_streak_material.set_shader_parameter(
			"u_length_scale", profile_value(&"streak_length")
		)
		_streak_material.set_shader_parameter(
			"u_length_power", profile_value(&"streak_length_power")
		)
		_streak_material.set_shader_parameter(
			"u_brightness", profile_value(&"streak_brightness")
		)


func _update_impacts(delta: float) -> void:
	for index in impact_pool_size:
		if _impact_ages[index] >= 1.0:
			continue
		_impact_ages[index] += delta / maxf(_impact_lifetimes[index], 0.05)
		_impact_multimesh.set_instance_custom_data(index, Color(
			_impact_ages[index], _impact_strengths[index], _impact_phases[index],
			_impact_levels[index]
		))

	if _rain_intensity <= 0.01:
		return
	var rate := impacts_per_second_at_downpour * profile_value(&"impact_rate") \
		* lerpf(1.0, 6.0, _impact_band_strength())
	_impact_budget += rate * delta
	var spawn_count := mini(int(floor(_impact_budget)), 96)
	_impact_budget -= float(spawn_count)
	for _unused in spawn_count:
		_spawn_impact()


func _impact_band_strength() -> float:
	if not wind_impact_bands_enabled:
		return 0.0
	return smoothstep(0.05, 0.65, _wind_strength) \
		* profile_value(&"wind_band_response") * wind_impact_band_contrast


static func impact_band_weight(point: Vector2, advection: Vector2, direction: Vector2, strength: float) -> float:
	var p := point - advection
	var along := p.dot(direction)
	var across := p.dot(Vector2(-direction.y, direction.x))
	var bend := sin(across * 0.47 + sin(across * 0.19)) * 1.6
	var phase := along * 0.85 + bend + sin(along * 0.23 + across * 0.31) * 0.8
	var ridge := pow(0.5 + 0.5 * sin(phase), 7.0)
	var broken := 0.45 + 0.55 * (0.5 + 0.5 * sin(across * 0.7 + along * 0.21))
	return lerpf(1.0, 0.015 + ridge * broken, clampf(strength, 0.0, 1.0))


func _spawn_impact() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var center := Vector2(camera.global_position.x, camera.global_position.z)
	var point := center
	var total_weight := 0.0
	# 加权蓄水池抽样：不会在重试用尽后把落点强行塞进稀疏区。
	# 风只影响新落点的抽样，已生成的水花绝不随风滑动。
	var band_strength := _impact_band_strength()
	var candidates := 24 if band_strength > 0.01 else 1
	for attempt in candidates:
		var angle := _rng.randf_range(0.0, TAU)
		var radius := impact_radius * sqrt(_rng.randf())
		var candidate := center + Vector2(cos(angle), sin(angle)) * radius
		var weight := impact_band_weight(candidate, _impact_advection, _wind_direction, band_strength)
		total_weight += weight
		if _rng.randf() * total_weight <= weight:
			point = candidate

	var height := TerrainFieldUtil.height_at(point.x, point.y) + 0.035
	var normal := TerrainFieldUtil.normal_at(point.x, point.y)
	var tangent := Vector3.RIGHT.cross(normal).normalized()
	if tangent.length_squared() < 0.01:
		tangent = Vector3.FORWARD
	var bitangent := normal.cross(tangent).normalized()
	var size := sample_impact_diameter()
	var basis := Basis(tangent * size, bitangent * size, normal)
	var transform := Transform3D(basis, Vector3(point.x, height, point.y))

	var index := _impact_cursor
	_impact_cursor = (_impact_cursor + 1) % impact_pool_size
	_impact_ages[index] = 0.0
	_impact_lifetimes[index] = _rng.randf_range(0.42, 0.66) \
		* profile_value(&"impact_lifetime") * lerpf(1.0, 0.28, band_strength)
	_impact_strengths[index] = profile_value(&"impact_brightness") \
		* _rng.randf_range(0.82, 1.10)
	_impact_phases[index] = _rng.randf()
	_impact_levels[index] = _rain_intensity
	_impact_multimesh.set_instance_transform(index, transform)
	_impact_multimesh.set_instance_custom_data(index, Color(
		0.0, _impact_strengths[index], _impact_phases[index], _impact_levels[index]
	))


func _update_wetness(delta: float) -> void:
	var target := clampf(profile_value(&"wetness"), 0.0, 1.0)
	# 淋湿较快、放晴后蒸发较慢；切到晴朗不会像关灯一样瞬间复原。
	var rate := 0.18 if target > _wetness else 0.035
	_wetness = move_toward(_wetness, target, rate * delta)


func _update_wind(delta: float) -> void:
	_wind_clock += delta
	match wind_mode:
		WindMode.FORCE_CALM:
			_wind_strength = move_toward(_wind_strength, 0.0, delta * 2.8)
			return
		WindMode.FORCE_PREVIEW_GUST:
			_wind_direction = _direction_from_degrees(prevailing_direction_degrees)
			_wind_strength = move_toward(_wind_strength, preview_gust_strength, delta * 1.8)
			return

	_wind_state_timer -= delta
	if _in_gust:
		_gust_elapsed += delta
		var envelope := gust_envelope(_gust_elapsed / maxf(_gust_duration, 0.01))
		var turbulence := 1.0
		if envelope > 0.0:
			turbulence += sin(_wind_clock * 4.7) * 0.12 + sin(_wind_clock * 9.1 + 1.3) * 0.05
		var wanted := clampf(_gust_peak * envelope * turbulence, 0.0, 1.0)
		_wind_strength = lerpf(_wind_strength, wanted, 1.0 - exp(-delta * 5.0))
		if _wind_state_timer <= 0.0:
			_begin_calm(false)
	else:
		# 静风不是“很小的风”，而是明确回到 0。
		_wind_strength = move_toward(_wind_strength, 0.0, delta * 2.2)
		if _wind_strength < 0.001:
			_wind_strength = 0.0
		if _wind_state_timer <= 0.0:
			_begin_gust()


func _begin_calm(first_cycle: bool) -> void:
	_in_gust = false
	var low := minf(calm_seconds_min, calm_seconds_max)
	var high := maxf(calm_seconds_min, calm_seconds_max)
	_wind_state_timer = _rng.randf_range(low, high)
	# 开场无需为了演示效果强塞一股风；但缩短首个静风，让测试者不用等满 18 秒。
	if first_cycle:
		_wind_state_timer = minf(_wind_state_timer, 6.0)


func _begin_gust() -> void:
	_in_gust = true
	_gust_elapsed = 0.0
	var duration_low := minf(gust_seconds_min, gust_seconds_max)
	var duration_high := maxf(gust_seconds_min, gust_seconds_max)
	_gust_duration = _rng.randf_range(duration_low, duration_high)
	_wind_state_timer = _gust_duration
	_gust_peak = _rng.randf_range(
		minf(gust_strength_min, gust_strength_max), maxf(gust_strength_min, gust_strength_max)
	)
	var angle := prevailing_direction_degrees + _rng.randf_range(
		-gust_direction_variation, gust_direction_variation
	)
	_wind_direction = _direction_from_degrees(angle)


func _direction_from_degrees(degrees: float) -> Vector2:
	var angle := deg_to_rad(degrees)
	return Vector2(cos(angle), sin(angle)).normalized()


func _broadcast_weather() -> void:
	var wind := get_wind_vector()
	get_tree().call_group("weather_wind_receiver", "set_weather_wind", _wind_direction, _wind_strength)
	get_tree().call_group("weather_wetness_receiver", "set_weather_wetness", _wetness)
	wind_changed.emit(wind, _wind_strength)


func _capture_sky_baseline() -> void:
	if _sky_dome == null:
		return
	for key in [
		"fog_density", "fog_start", "fog_end", "atm_day_tint", "atm_night_tint",
		"atm_horizon_light_tint", "atm_sun_intensity", "atm_darkness", "exposure",
		"ground_color", "starmap_color", "star_field_color", "sun_disk_intensity",
		"sun_light_energy", "atm_sun_mie_intensity",
		"cumulus_visible", "cumulus_intensity", "cumulus_coverage",
		"cumulus_thickness", "cumulus_absorption", "cumulus_mie_intensity",
		"cumulus_size"
	]:
		_base_sky[key] = _sky_dome.get(key)
	if is_instance_valid(_sky_world) and _sky_world.environment != null:
		var environment := _sky_world.environment
		_base_environment = {
			"ambient_light_energy": environment.ambient_light_energy,
			"ambient_light_sky_contribution": environment.ambient_light_sky_contribution,
			"tonemap_exposure": environment.tonemap_exposure,
			"ambient_light_source": environment.ambient_light_source,
			"ambient_light_color": environment.ambient_light_color,
		}
		_base_environment["sun_specular"] = _sun.light_specular
		_base_environment["sun_shadow_opacity"] = _sun.shadow_opacity
		_base_environment["sun_shadow_blur"] = _sun.shadow_blur
		if _moon != null:
			_base_environment["moon_scatter"] = _moon.light_volumetric_fog_energy
		if _sky_world.camera_attributes != null:
			_base_environment["camera_exposure"] = \
				_sky_world.camera_attributes.exposure_multiplier


func _update_environment(delta: float = 0.0) -> void:
	# 降水、云型、云覆盖、云厚度与雾分别保存。
	# WeatherSystem 关闭 precipitation coupling，因此主游戏的雨不会偷偷改天空。
	var rain_storm := profile_value(&"storm_strength") * storm_environment_strength * _precipitation_environment_coupling
	var rain_cloud := profile_value(&"cloud_cover") * storm_environment_strength * _precipitation_environment_coupling
	var cloud_cover := clampf(maxf(rain_cloud, _external_cloud_cover), 0.0, 1.0)
	var cloud_density := clampf(maxf(rain_storm, _external_cloud_density), 0.0, 1.0)
	var is_cumulus := _external_cloud_style == 0 and _external_cloud_cover >= rain_cloud
	var stratus_cover := 0.0 if is_cumulus else cloud_cover
	var storm := clampf(maxf(rain_storm, _external_storm_strength), 0.0, 1.0)
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) if is_instance_valid(_sun) else 0.0

	# Stratus 是连续云底，才整体接管天空色与漫射照明。
	# Cumulus 保留原本蓝天天空，让 Sky3D 自己的积云体漂在其上。
	var clear_horizon := Color(0.13, 0.16, 0.20).lerp(Color(0.56, 0.60, 0.64), daylight)
	var overcast_horizon := Color(0.16, 0.19, 0.23).lerp(
		Color(0.72, 0.75, 0.78).lerp(Color(0.27, 0.30, 0.34), storm), daylight
	)
	var horizon := clear_horizon.lerp(overcast_horizon, stratus_cover)

	# 云层本身不降低能见度。只有旧雨雾联动或独立 Fog Layer 改变雾量。
	var fog_target := 1.0 - (1.0 - clampf(rain_storm, 0.0, 1.0)) * (1.0 - clampf(_external_fog_strength, 0.0, 1.0))
	var fog_seconds := fog_build_seconds if fog_target > _fog_amount else fog_clear_seconds
	if delta > 0.0:
		_fog_amount = move_toward(_fog_amount, fog_target, delta / maxf(fog_seconds, 0.1))
	var fog_strength := clampf(_fog_amount, 0.0, 1.0)

	if _sky_controller != null:
		_sky_controller.set("weather_darkening", storm)
	_update_backdrop_clouds(storm)
	if _sky_dome == null or _base_sky.is_empty():
		return

	# 晴天保留 Sky3D 的散射雾；浓雨雾再逐步交给引擎雾。
	var atmospheric_share := 1.0 - smoothstep(0.12, 0.50, fog_strength)
	_sky_dome.set("fog_visible", atmospheric_share > 0.02)

	# 两套云结构：
	# Cumulus 使用 Sky3D 原生积云，云块之间是真正蓝天。
	# Stratus 使用低频连续云底，Coverage 接近 1 时保证无蓝天空洞。
	var cumulus_active := is_cumulus and cloud_cover > 0.001
	if cumulus_active:
		_sky_dome.set("cumulus_visible", true)
		_sky_dome.set("cumulus_coverage", cloud_cover)
		_sky_dome.set("cumulus_intensity", lerpf(0.52, 0.90, cloud_density))
		_sky_dome.set("cumulus_thickness", lerpf(0.012, 0.038, cloud_density))
		_sky_dome.set("cumulus_absorption", lerpf(1.15, 4.2, cloud_density))
		_sky_dome.set("cumulus_mie_intensity", lerpf(1.15, 0.65, cloud_density))
		_sky_dome.set("cumulus_size", lerpf(0.62, 0.42, cloud_density))
	else:
		_sky_dome.set("cumulus_visible", bool(_base_sky.cumulus_visible) if cloud_cover <= 0.001 else false)

	var sky_material := _sky_dome.get("sky_material") as ShaderMaterial
	if sky_material != null:
		sky_material.set_shader_parameter("weather_overcast", stratus_cover)
		sky_material.set_shader_parameter("weather_cloud_density", cloud_density)
		sky_material.set_shader_parameter("weather_horizon", horizon)

	_sky_dome.set("fog_density", float(_base_sky.fog_density) * atmospheric_share)
	_sky_dome.set("fog_start", lerpf(float(_base_sky.fog_start), 18.0, fog_strength))
	_sky_dome.set("fog_end", lerpf(float(_base_sky.fog_end), downpour_fog_end, fog_strength))
	_sky_dome.set("atm_day_tint", (_base_sky.atm_day_tint as Color).lerp(
		Color(0.27, 0.325, 0.39, 1.0), storm
	))
	_sky_dome.set("atm_night_tint", (_base_sky.atm_night_tint as Color).lerp(
		Color(0.050, 0.065, 0.085, 1.0), storm * 0.72
	))
	_sky_dome.set("atm_horizon_light_tint", (_base_sky.atm_horizon_light_tint as Color).lerp(
		Color(0.28, 0.31, 0.35, 1.0), storm
	))
	_sky_dome.set("atm_sun_intensity", lerpf(float(_base_sky.atm_sun_intensity), 8.0, storm))
	_sky_dome.set("atm_darkness", lerpf(float(_base_sky.atm_darkness), 0.72, storm))
	_sky_dome.set("exposure", lerpf(float(_base_sky.exposure), 0.72, storm))
	_sky_dome.set("ground_color", (_base_sky.ground_color as Color).lerp(
		Color(0.20, 0.23, 0.25, 1.0), storm
	))
	_sky_dome.set("starmap_color", _weather_star_color(_base_sky.starmap_color as Color, storm))
	_sky_dome.set("star_field_color", _weather_star_color(_base_sky.star_field_color as Color, storm))

	# 第一版 Cumulus 不统一削弱太阳：蓝天缝隙仍保持晴天式直射光。
	# Stratus 则随着 Coverage 消除太阳轮廓、镜面高光与硬阴影。
	var sun_occlusion := smoothstep(0.04, 0.88, stratus_cover)
	var sun_disk_scale := 1.0 - smoothstep(0.02, 0.72, stratus_cover)
	var direct_sun_scale := lerpf(1.0, 0.06, sun_occlusion)
	var specular_scale := lerpf(1.0, 0.025, smoothstep(0.0, 0.72, stratus_cover))
	var shadow_scale := lerpf(1.0, 0.10, sun_occlusion)
	_sky_dome.set("sun_disk_intensity", float(_base_sky.sun_disk_intensity) * sun_disk_scale)
	_sky_dome.set("atm_sun_mie_intensity", float(_base_sky.atm_sun_mie_intensity) * sun_disk_scale)
	_sky_dome.set("sun_light_energy", float(_base_sky.sun_light_energy) * direct_sun_scale)
	_sun.light_specular = float(_base_environment.get("sun_specular", 1.0)) * specular_scale
	_sun.shadow_opacity = float(_base_environment.get("sun_shadow_opacity", 1.0)) * shadow_scale
	_sun.shadow_blur = lerpf(
		float(_base_environment.get("sun_shadow_blur", 1.0)), 1.45, sun_occlusion
	)
	if _moon != null:
		_moon.light_volumetric_fog_energy = float(_base_environment.get("moon_scatter", 1.0)) * (1.0 - stratus_cover)

	if is_instance_valid(_sky_world) and _sky_world.environment != null and not _base_environment.is_empty():
		var environment := _sky_world.environment
		environment.fog_enabled = fog_strength > 0.001
		environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		environment.fog_aerial_perspective = 0.0
		var manual_share := _external_fog_strength / maxf(_external_fog_strength + rain_storm, 0.001)
		environment.fog_light_color = horizon.lerp(_standalone_fog_color, manual_share)
		environment.fog_light_energy = 1.0
		environment.fog_sun_scatter = 0.0
		environment.fog_sky_affect = 0.0
		var fog_distance := lerpf(downpour_fog_end, _standalone_fog_distance, manual_share)
		environment.fog_density = (
			4.6 / maxf(fog_distance, 1.0)
			* pow(fog_strength, 1.6)
			* (1.0 + _wind_strength * 0.45)
		)

		# 多云继续使用 Sky3D 天空作为环境光源，因此蓝天区域仍会贡献蓝色天光。
		# 阴天改用冷灰漫射色，Coverage 越接近 1，越彻底离开晴天天空照明。
		environment.ambient_light_source = (
			Environment.AMBIENT_SOURCE_COLOR
			if stratus_cover > 0.001
			else int(_base_environment.ambient_light_source)
		)
		var light_overcast := Color(0.43, 0.49, 0.58).lerp(Color(0.72, 0.76, 0.82), daylight)
		var deep_overcast := Color(0.27, 0.31, 0.38).lerp(Color(0.47, 0.52, 0.59), daylight)
		var overcast_ambient := light_overcast.lerp(deep_overcast, storm)
		environment.ambient_light_color = (_base_environment.ambient_light_color as Color).lerp(
			overcast_ambient, stratus_cover
		)
		var overcast_energy := lerpf(0.38, 0.86, daylight) * lerpf(1.0, 0.70, storm)
		environment.ambient_light_energy = lerpf(
			float(_base_environment.ambient_light_energy), overcast_energy, stratus_cover
		)
		environment.ambient_light_sky_contribution = lerpf(
			float(_base_environment.ambient_light_sky_contribution), 0.0, stratus_cover
		)
		environment.tonemap_exposure = lerpf(
			float(_base_environment.tonemap_exposure), 0.84, storm
		)
		if _sky_world.camera_attributes != null and _base_environment.has("camera_exposure"):
			_sky_world.camera_attributes.exposure_multiplier = lerpf(
				float(_base_environment.camera_exposure), 1.0, storm
			)


func _update_backdrop_clouds(storm: float) -> void:
	_resolve_backdrop_clouds()
	if is_instance_valid(_backdrop_clouds):
		# 高空云不吃贴地雾的逐像素漂白；真正浓雾时由天气层整体遮蔽。
		_backdrop_clouds.transparency = maxf(
			smoothstep(0.0, 0.18, maxf(_rain_intensity, _external_cloud_cover)),
			smoothstep(0.35, 0.78, _fog_amount)
		)
		var material := _backdrop_clouds.material_override as ShaderMaterial
		if material != null:
			material.set_shader_parameter("cloud_tint", CloudLighting.tint_for_sun(_sun, storm))
	if not is_instance_valid(_backdrop_landforms):
		_backdrop_landforms = get_tree().root.find_child("BackdropLandforms", true, false) as MeshInstance3D
	if is_instance_valid(_backdrop_landforms):
		# 远山是远景装饰层；与成熟雨雾连续淡出，避免雾色和天幕色差描出山脊。
		_backdrop_landforms.transparency = smoothstep(0.35, 0.9,
			_fog_amount * (1.0 + _wind_strength * 0.25))


func _resolve_backdrop_clouds() -> void:
	if is_instance_valid(_backdrop_clouds):
		return
	var candidate := get_tree().root.find_child("BackdropClouds", true, false)
	if not (candidate is MeshInstance3D):
		return
	_backdrop_clouds = candidate as MeshInstance3D


func _weather_star_color(base: Color, rain: float) -> Color:
	# Sky3D 的星空主要读取 RGB，单改 alpha 基本看不出变化。中雨仍留出宇宙暗示，
	# 只有暴雨才把银河压到接近不可见。
	var factor := 1.0 - pow(clampf(rain, 0.0, 1.0), 1.35) * 0.92
	var result := Color(base.r * factor, base.g * factor, base.b * factor, base.a * factor)
	return result
