extends "res://scripts/weather_rain_controller.gd"
class_name WeatherSystem
## 主场景与寂石圣所实验场景共用的天气入口。
## 云、雨、雾、雪是可独立启用的层；天空、光照、雾只在本节点合成一次。
## 日后抽成插件时，场景只需实例化本节点及其 SnowLayer 子节点。

@export_category("天气组合：可复选")
## 独立阴天层。它只改变云幕与环境光照，不自动产生雨、雪或雾。
@export var cloud_enabled := false
## 0=晴空，约 0.25=薄阴，0.55=普通阴天，0.80=厚云，1=压城重云。
## 浅阴优先消除硬太阳、高光与硬阴影；重阴才明显降低整体亮度。
@export_range(0.0, 1.0, 0.01) var cloud_amount := 0.0
## 关闭雨层不影响云、雾、雪或风。雨量使用下方五档预设/连续雨量设置。
@export var rain_enabled := true
## 独立雾层开关，不再由云层自动开启。
@export var fog_enabled := true
## 0=无独立雾，1=最浓。开场立即采用 Inspector 数值，运行中平滑变化。
@export_range(0.0, 1.0, 0.01) var fog_amount := 0.48
## 独立雾完全遮蔽远景的距离；值越小，雾越浓。
@export_range(70.0, 500.0, 5.0) var fog_visibility_distance := 145.0
@export var fog_color := Color(0.72, 0.79, 0.83)
## 降雪可与云、雨、雾同时启用。当前雪层只负责雪花；不会再自动把天空改成阴天。
@export var snow_enabled := false
@export_range(0.0, 1.0, 0.01) var snow_amount := 0.45

var _cloud_level := 0.0
var _snow_level := 0.0
@onready var _snow_layer: Node3D = get_node_or_null("SnowLayer")


func _ready() -> void:
	# 统一天气入口从这一版开始把降水与天空环境解耦。
	# WeatherRainController 单独使用时仍保留旧的“雨量带阴天”行为，避免破坏旧实验场。
	_precipitation_environment_coupling = 0.0
	_cloud_level = cloud_amount if cloud_enabled else 0.0
	_snow_level = snow_amount if snow_enabled else 0.0
	_sync_extra_layers()
	super._ready()
	_update_snow_layer()


func _process(delta: float) -> void:
	var transition_speed := delta / maxf(weather_transition_seconds, 0.1)
	var cloud_target := cloud_amount if cloud_enabled else 0.0
	var snow_target := snow_amount if snow_enabled else 0.0
	_cloud_level = move_toward(_cloud_level, cloud_target, transition_speed)
	_snow_level = move_toward(_snow_level, snow_target, transition_speed)
	_sync_extra_layers()
	super._process(delta)
	_update_snow_layer()


func _target_intensity() -> float:
	return super._target_intensity() if rain_enabled else 0.0


func set_cloud_amount(amount: float) -> void:
	cloud_amount = clampf(amount, 0.0, 1.0)
	cloud_enabled = cloud_amount > 0.001


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
	# 云量与“阴沉程度”不是同一条线。薄阴可以已经遮住太阳，但环境仍然明亮；
	# 只有厚云继续增加时，整个世界才逐渐进入低曝光的重阴状态。
	_external_cloud_cover = _cloud_level
	_external_storm_strength = _cloud_darkness(_cloud_level)
	_standalone_fog_distance = fog_visibility_distance
	_standalone_fog_color = fog_color


static func _cloud_darkness(amount: float) -> float:
	return smoothstep(0.30, 1.0, clampf(amount, 0.0, 1.0)) * 0.92


func _update_snow_layer() -> void:
	if _snow_layer == null:
		return
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) if _sun != null else 0.0
	_snow_layer.call("set_weather", _snow_level, get_wind_vector(), daylight)
