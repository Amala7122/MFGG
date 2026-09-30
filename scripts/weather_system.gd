extends "res://scripts/weather_rain_controller.gd"
class_name WeatherSystem
## 主场景与天气实验场共用的统一天气入口。
## 云、雨、雾、雪是可独立启用的层；天空、光照、雾只在本节点合成一次。
##
## Cloud Layer 当前仍保留两种照明性格：
## - Cumulus 多云：蓝天仍占较大比例，保留较强直射光。
## - Stratus 阴天：连续云底逐步接管直射光与环境光。
##
## 从这一版开始，两者不再使用两套不同风格的云几何。Sky3D 原生真实积云被停用，
## 统一改用 weather shader 的低频 Stylized Cloud Field。Coverage 决定云块从分离到连片，
## Density 决定云底厚度与吸光。云色只使用大块漫射明暗，不读取太阳高光或 Mie 银边，
## 避免出现天空中漂浮的塑料块。

enum CloudType { CUMULUS, STRATUS }

@export_category("天气组合：可复选")
@export var cloud_enabled := false
## 当前暂时作为照明性格选择；云的形状已经统一为 Stylized Cloud Field。
@export_enum("Cumulus 多云:0", "Stratus 阴天:1") var cloud_type: int = CloudType.STRATUS
## 天空有多少面积被云覆盖。低值形成分散大云块，高值逐渐连成连续云幕。
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
	_apply_stylized_cloud_field()
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
	# 父类会按 CloudType 更新天空；最后统一覆盖为风格化云场，确保两种天气不会
	# 在视觉上突然从 low-poly 世界切换成写实体积云。
	_apply_stylized_cloud_field()
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
	# 暂时保留现有两套照明响应。云形本身会在 _apply_stylized_cloud_field()
	# 统一，所以这里的 type 只决定多云/阴天对直射光和环境光的影响。
	_external_cloud_style = cloud_type
	_external_storm_strength = _cloud_darkness(
		_cloud_level, _cloud_density_level, cloud_type
	)
	_standalone_fog_distance = fog_visibility_distance
	_standalone_fog_color = fog_color


static func _cloud_darkness(coverage: float, density: float, type: int) -> float:
	# 多云第一版保持晴空照明家族：云块会出现在天空，但不统一压暗整个世界。
	# 阴天在覆盖面积足够高之后，才随厚度逐渐进入重阴状态。
	if type == CloudType.CUMULUS:
		return 0.0
	var cover := smoothstep(0.35, 1.0, clampf(coverage, 0.0, 1.0))
	var thick := smoothstep(0.12, 1.0, clampf(density, 0.0, 1.0))
	return cover * thick * 0.96


func _apply_stylized_cloud_field() -> void:
	if _sky_dome == null:
		return

	# Sky3D 原生 Cumulus 是偏写实体积云，也是此前与世界风格割裂、出现高亮银边的来源。
	# 统一云场开启后，无论 CloudType 都不再渲染它。
	_sky_dome.set("cumulus_visible", false)

	var sky_material := _sky_dome.get("sky_material") as ShaderMaterial
	if sky_material == null:
		return

	var coverage := clampf(_cloud_level, 0.0, 1.0)
	var density := clampf(_cloud_density_level, 0.0, 1.0)
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) \
		if is_instance_valid(_sun) else 0.0

	# 这套云色刻意不取 sun_light_color，也不计算太阳方向高光。
	# 亮云仍然是低反射的冷灰漫射面；Density 高时只扩大暗部，不产生白色银边。
	var day_light_cloud := Color(0.66, 0.70, 0.74, 1.0)
	var day_storm_cloud := Color(0.27, 0.31, 0.36, 1.0)
	var night_cloud := Color(0.10, 0.13, 0.18, 1.0)
	var heavy_factor := smoothstep(0.52, 1.0, density) * smoothstep(0.55, 1.0, coverage)
	var day_cloud := day_light_cloud.lerp(day_storm_cloud, heavy_factor)
	var matte_cloud := night_cloud.lerp(day_cloud, daylight)

	# 同一张低频云场从分散云块连续长成完整阴天云幕。
	# weather shader 内部只做大尺度明暗，不使用真实体积云的镜面/Mie 响应。
	sky_material.set_shader_parameter("weather_overcast", coverage)
	sky_material.set_shader_parameter("weather_cloud_density", density)
	sky_material.set_shader_parameter("weather_horizon", matte_cloud)


func _update_snow_layer() -> void:
	if _snow_layer == null:
		return
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) if _sun != null else 0.0
	_snow_layer.call("set_weather", _snow_level, get_wind_vector(), daylight)
