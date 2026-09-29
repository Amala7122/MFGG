@tool
extends Node
## Sky3D 场景的低多边形补光适配；天气与雾由 WeatherSystem 统一控制。

@onready var _sun: DirectionalLight3D = get_node("../Sky3D/SunLight")
@onready var _moon: DirectionalLight3D = get_node("../Sky3D/MoonLight")
@onready var _fill: DirectionalLight3D = get_node("../FillLight")
@onready var _night_sky: DirectionalLight3D = get_node("../NightSkyLight")
@onready var _time_of_day: Node = get_node("../Sky3D/TimeOfDay")

const CLEAR_NIGHT_DOWNWARD_ENERGY := 1.05
const SEVERE_WEATHER_NIGHT_DOWNWARD_ENERGY := 0.72
const SEVERE_WEATHER_DAY_DOWNWARD_ENERGY := 0.60

@export_range(0.0, 1.0, 0.01) var weather_darkening := 0.0:
	set(value):
		weather_darkening = clampf(value, 0.0, 1.0)
		if is_inside_tree() and not _update_pending:
			_update_pending = true
			call_deferred("_flush_stylized_fill_update")

var _update_pending := false
var _day_fill_energy := 0.68
var _night_fill_energy := 0.14

func _ready() -> void:
	if _time_of_day.has_signal("time_changed"):
		_time_of_day.connect("time_changed", _on_time_changed)
	call_deferred("_update_stylized_fill")

func _on_time_changed(_value: Variant) -> void:
	# Sky3D 更新灯光方向晚于时间信号，延后一帧再按新太阳高度补光。
	if not _update_pending:
		_update_pending = true
		call_deferred("_flush_stylized_fill_update")

func _flush_stylized_fill_update() -> void:
	_update_pending = false
	_update_stylized_fill()

func _update_stylized_fill() -> void:
	if not is_instance_valid(_sun) or not is_instance_valid(_moon) \
			or not is_instance_valid(_fill) or not is_instance_valid(_night_sky):
		return
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y)
	var weather_light_scale := lerpf(1.0, 0.58, weather_darkening)
	_fill.light_energy = lerpf(_night_fill_energy, _day_fill_energy, daylight) * weather_light_scale
	var clear_fill := Color(0.38, 0.48, 0.72).lerp(Color(0.55, 0.67, 0.82), daylight)
	_fill.light_color = clear_fill.lerp(Color(0.29, 0.35, 0.42), weather_darkening)
	_fill.light_specular = 0.0
	_fill.light_volumetric_fog_energy = 0.0
	_night_sky.light_volumetric_fog_energy = 0.0
	var celestial_downward := _downward_energy(_sun) + _downward_energy(_moon)
	var night_floor := lerpf(CLEAR_NIGHT_DOWNWARD_ENERGY,
		SEVERE_WEATHER_NIGHT_DOWNWARD_ENERGY, weather_darkening)
	var day_floor := lerpf(CLEAR_NIGHT_DOWNWARD_ENERGY,
		SEVERE_WEATHER_DAY_DOWNWARD_ENERGY, weather_darkening)
	var sun_downward_factor := clampf(_sun.global_basis.z.normalized().y, 0.0, 1.0)
	var daytime_weight := smoothstep(0.015, 0.42, sun_downward_factor)
	var protected_floor := lerpf(night_floor, day_floor, daytime_weight)
	var missing_downward := maxf(protected_floor - celestial_downward, 0.0)
	var night_sky_down_factor := maxf(_night_sky.global_basis.z.normalized().y, 0.1)
	_night_sky.light_energy = missing_downward / night_sky_down_factor
	if daylight < 0.05 and _moon.light_energy < 0.01:
		_fill.light_energy = maxf(_fill.light_energy, 0.05)

func _downward_energy(light: DirectionalLight3D) -> float:
	var downward_factor := clampf(light.global_basis.z.normalized().y, 0.0, 1.0)
	return maxf(light.light_energy, 0.0) * downward_factor
