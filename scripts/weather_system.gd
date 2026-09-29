extends "res://scripts/weather_rain_controller.gd"
class_name WeatherSystem
## 主场景与天气实验场共用的统一天气入口。
## 云、雨、雾、雪是可独立启用的层；天空、光照、雾只在本节点合成一次。
##
## Cloud Layer 第一版拆成三个维度：
## - Type：Cumulus 多云 / Stratus 阴天
## - Coverage：天空覆盖面积
## - Density：云体厚度与吸光程度
##
## 多云暂时保留强直射阳光，不做“云块刚好遮住太阳”时的局部光照采样；
## 阴天使用连续层云并接管直射光/环境光。先把两类天空的视觉家族分开。

enum CloudType { CUMULUS, STRATUS }

@export_category("天气组合：可复选")
@export var cloud_enabled := false
## Cumulus：分散积云，保留蓝天；Stratus：连续层云，用于阴天。
@export_enum("Cumulus 多云:0", "Stratus 阴天:1") var cloud_type: int = CloudType.STRATUS
## 天空有多少面积被云覆盖。Stratus 接近 1 时成为连续云底。
@export_range(0.0, 1.0, 0.01) var cloud_coverage := 1.0
## 云有多厚。它不决定覆盖面积；低值偏明亮薄云，高值偏厚重吸光。
@export_range(0.0, 1.0, 0.01) var cloud_density := 0.47
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
var _cloud_density_level := 0.0
var _snow_level := 0.0
@onready var _snow_layer: Node3D = get_node_or_null("SnowLayer")


func _ready() -> void:
	# 统一天气入口关闭“下雨自动变阴天”的旧耦合。
	# WeatherRainController 单独使用时仍保留旧行为，避免破坏旧实验。
	_precipitation_environment_coupling = 0.0
	_cloud_level = cloud_coverage if cloud_enabled else 0.0
	_cloud_density_level = cloud_density
	_snow_level = snow_amount if snow_enabled else 0.0
	_sync_extra_layers()
	super._ready()
	_update_snow_layer()


func _process(delta: float) -> void:
	var transition_speed := delta / maxf(weather_transition_seconds, 0.1)
	var cloud_target := cloud_coverage if cloud_enabled else 0.0
	var snow_target := snow_amount if snow_enabled else 0.0
	_cloud_level = move_toward(_cloud_level, cloud_target, transition_speed)
	_cloud_density_level = move_toward(_cloud_density_level, cloud_density, transition_speed)
	_snow_level = move_toward(_snow_level, snow_target, transition_speed)
	_sync_extra_layers()
	super._process(delta)
	_update_snow_layer()


func _target_intensity() -> float:
	return super._target_intensity() if rain_enabled else 0.0


func set_cloud_type(type: int) -> void:
	cloud_type = clampi(type, CloudType.CUMULUS, CloudType.STRATUS)


func set_cloud_coverage(amount: float) -> void:
	cloud_coverage = clampf(amount, 0.0, 1.0)
	cloud_enabled = cloud_coverage > 0.001


func set_cloud_density(amount: float) -> void:
	cloud_density = clampf(amount, 0.0, 1.0)


## 兼容第一版 Cloud Amount API；新代码应明确调用 set_cloud_coverage()。
func set_cloud_amount(amount: float) -> void:
	set_cloud_coverage(amount)


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
	_external_cloud_cover = _cloud_level
	_external_cloud_density = _cloud_density_level
	_external_cloud_style = cloud_type
	_external_storm_strength = _cloud_darkness(
		_cloud_level, _cloud_density_level, cloud_type
	)
	_standalone_fog_distance = fog_visibility_distance
	_standalone_fog_color = fog_color


static func _cloud_darkness(coverage: float, density: float, type: int) -> float:
	# 多云第一版保持晴空照明家族：云块会出现在天空，但不统一压暗整个世界。
	# 后续再根据太阳方向的局部云密度驱动直射光。
	if type == CloudType.CUMULUS:
		return 0.0
	var cover := smoothstep(0.35, 1.0, clampf(coverage, 0.0, 1.0))
	var thick := smoothstep(0.12, 1.0, clampf(density, 0.0, 1.0))
	return cover * thick * 0.92


func _update_snow_layer() -> void:
	if _snow_layer == null:
		return
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) if _sun != null else 0.0
	_snow_layer.call("set_weather", _snow_level, get_wind_vector(), daylight)
