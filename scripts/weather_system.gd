extends "res://scripts/weather_rain_controller.gd"
class_name WeatherSystem
## 主场景与寂石圣所实验场景共用的天气入口。每个天气是可复选的层，天空/光照/雾只合成一次。
## 日后抽成插件时，场景只需实例化本节点及其 SnowLayer 子节点。

@export_category("天气组合：可复选")
## 关闭雨层不影响雾、雪或风。雨量使用下方五档预设/连续雨量设置。
@export var rain_enabled := true
## 独立雾层开关；雨雪自带的能见度变化仍由各自天气控制。
@export var fog_enabled := true
## 0=无独立雾，1=最浓。开场立即采用 Inspector 数值，运行中平滑变化。
@export_range(0.0, 1.0, 0.01) var fog_amount := 0.48
## 独立雾完全遮蔽远景的距离；值越小，雾越浓。
@export_range(70.0, 500.0, 5.0) var fog_visibility_distance := 145.0
@export var fog_color := Color(0.72, 0.79, 0.83)
## 降雪可与雨、雾同时启用。雪层尚未加积雪材质，只负责雪花及天空联动。
@export var snow_enabled := false
@export_range(0.0, 1.0, 0.01) var snow_amount := 0.45

var _snow_level := 0.0
@onready var _snow_layer: Node3D = get_node_or_null("SnowLayer")

func _ready() -> void:
	_snow_level = snow_amount if snow_enabled else 0.0
	_sync_extra_layers()
	super._ready()
	_update_snow_layer()

func _process(delta: float) -> void:
	var snow_target := snow_amount if snow_enabled else 0.0
	_snow_level = move_toward(_snow_level, snow_target, delta / maxf(weather_transition_seconds, 0.1))
	_sync_extra_layers()
	super._process(delta)
	_update_snow_layer()

func _target_intensity() -> float:
	return super._target_intensity() if rain_enabled else 0.0

func set_rain_amount(amount: float) -> void:
	rain_enabled = amount > 0.001
	super.set_rain_amount(amount)

func set_fog_amount(amount: float) -> void:
	fog_amount = clampf(amount, 0.0, 1.0)
	fog_enabled = fog_amount > 0.001

func set_snow_amount(amount: float) -> void:
	snow_amount = clampf(amount, 0.0, 1.0)
	snow_enabled = snow_amount > 0.001

func _sync_extra_layers() -> void:
	_baseline_fog_enabled = fog_enabled
	_external_fog_strength = fog_amount if fog_enabled else 0.0
	_external_cloud_cover = _snow_level * 0.65
	_external_storm_strength = _snow_level * 0.45
	_standalone_fog_distance = fog_visibility_distance
	_standalone_fog_color = fog_color

func _update_snow_layer() -> void:
	if _snow_layer == null:
		return
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) if _sun != null else 0.0
	_snow_layer.call("set_weather", _snow_level, get_wind_vector(), daylight)
