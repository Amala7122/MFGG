extends "res://scripts/weather_rain_controller.gd"
class_name WeatherSystem
## 主场景与天气实验场共用的统一天气入口。
## 云、雨、雾、雪是可独立启用的层；天空、光照、雾只在本节点合成一次。
##
## Cloud Layer 当前仍保留两种照明性格：
## - Cumulus 多云：蓝天仍占较大比例，保留较强直射光。
## - Stratus 阴天：连续云底逐步接管直射光与环境光。
##
## 云形使用项目原有的低多边形 BackdropClouds。Coverage 较低时它们保持清晰的
## 独立云团；Coverage 超过约 0.55 后，Stratus 云幕从背后长出来，同时旧云逐渐
## 横向摊开、压平、降低自身色差并靠拢云幕颜色，最终在完整阴天里“融化”。
## 整个过程保持 unshaded / matte，不引入太阳高光、银边或真实体积云反射。

enum CloudType { CUMULUS, STRATUS }

@export_category("编辑器预览")
## 开启后，在 Godot 编辑器 3D 视口里直接预览云、天空光照、太阳与雾。
## 预览由独立 @tool 适配器执行，不会启动雨粒子、风状态机、落点池或其它游戏逻辑。
@export var editor_preview_enabled := true

@export_category("天气组合：可复选")
@export var cloud_enabled := false
## 当前主要决定照明性格；云的视觉形态由 Coverage 连续控制。
@export_enum("Cumulus 多云:0", "Stratus 阴天:1") var cloud_type: int = CloudType.STRATUS
## 天空有多少面积被云覆盖。低值是独立风格云，高值逐渐融入连续云幕。
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
var _stylized_cloud_mesh: MeshInstance3D
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
	# 父类先完成通用天空/光照合成；最后再覆写项目自己的云形过渡。
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
	# CloudType 暂时只保留多云 / 阴天的照明差异。云形过渡本身由 Coverage 连续驱动。
	_external_cloud_style = cloud_type
	_external_storm_strength = _cloud_darkness(
		_cloud_level, _cloud_density_level, cloud_type
	)
	_standalone_fog_distance = fog_visibility_distance
	_standalone_fog_color = fog_color


static func _cloud_darkness(coverage: float, density: float, type: int) -> float:
	# 多云第一版保持晴空照明家族；阴天才逐步进入低曝光的重阴状态。
	# 后续会再根据太阳方向的局部云密度补上多云时的云影与短时遮阳。
	if type == CloudType.CUMULUS:
		return 0.0
	var cover := smoothstep(0.35, 1.0, clampf(coverage, 0.0, 1.0))
	var thick := smoothstep(0.12, 1.0, clampf(density, 0.0, 1.0))
	return cover * thick * 0.96


func _apply_stylized_cloud_field() -> void:
	if _sky_dome == null:
		return

	# 停用 Sky3D 偏写实的体积积云。多云的可见云体改回项目原有 BackdropClouds。
	_sky_dome.set("cumulus_visible", false)

	var coverage := clampf(_cloud_level, 0.0, 1.0)
	var density := clampf(_cloud_density_level, 0.0, 1.0)
	# 0.55 前基本保持独立云团；0.55~0.88 是主要“融化”区间。
	var overcast_blend := smoothstep(0.55, 0.88, coverage)
	# 云幕不是从 Coverage=0 就铺一层白雾，而是在风格云开始连片时才从背后长出来。
	var deck_cover := coverage * overcast_blend
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) \
		if is_instance_valid(_sun) else 0.0

	var day_light_deck := Color(0.67, 0.71, 0.75, 1.0)
	var day_storm_deck := Color(0.25, 0.29, 0.34, 1.0)
	var night_deck := Color(0.10, 0.13, 0.18, 1.0)
	var heavy_factor := smoothstep(0.52, 1.0, density) * smoothstep(0.65, 1.0, coverage)
	var day_deck := day_light_deck.lerp(day_storm_deck, heavy_factor)
	var matte_deck := night_deck.lerp(day_deck, daylight)

	var sky_material := _sky_dome.get("sky_material") as ShaderMaterial
	if sky_material != null:
		sky_material.set_shader_parameter("weather_overcast", deck_cover)
		sky_material.set_shader_parameter("weather_cloud_density", density)
		sky_material.set_shader_parameter("weather_horizon", matte_deck)

	_resolve_stylized_cloud_mesh()
	if not is_instance_valid(_stylized_cloud_mesh):
		return

	# 低 Coverage 时独立云团逐渐出现；到完整阴天的最后一段才真正消失。
	# 中间大部分时间依靠“颜色靠拢 + 云幕长出”来融，而不是简单 alpha 交叉淡化。
	var bank_in := smoothstep(0.02, 0.26, coverage)
	var final_dissolve := smoothstep(0.88, 1.0, coverage)
	var bank_visibility := bank_in * (1.0 - final_dissolve)
	_stylized_cloud_mesh.transparency = 1.0 - bank_visibility

	var material := _stylized_cloud_mesh.material_override as ShaderMaterial
	if material == null:
		return

	# 旧云继续保持低反射冷灰漫射色。随着 Density 与融化程度增加，云团和云幕
	# 使用越来越接近的色组，最终视觉上失去“贴在云幕前面”的独立边界。
	var day_bank_light := Color(0.78, 0.82, 0.86, 1.0)
	var day_bank_heavy := Color(0.34, 0.39, 0.45, 1.0)
	var night_bank := Color(0.11, 0.14, 0.20, 1.0)
	var bank_heavy := smoothstep(0.50, 1.0, density) * smoothstep(0.45, 1.0, coverage)
	var day_bank := day_bank_light.lerp(day_bank_heavy, bank_heavy)
	var matte_bank := night_bank.lerp(day_bank, daylight)

	material.set_shader_parameter("cloud_coverage", coverage)
	material.set_shader_parameter("cloud_density", density)
	material.set_shader_parameter("overcast_blend", overcast_blend)
	material.set_shader_parameter("cloud_tint", matte_bank)
	material.set_shader_parameter("overcast_tint", matte_deck)


func _resolve_stylized_cloud_mesh() -> void:
	if is_instance_valid(_stylized_cloud_mesh):
		return
	_stylized_cloud_mesh = get_tree().root.find_child("BackdropClouds", true, false) as MeshInstance3D


func _update_snow_layer() -> void:
	if _snow_layer == null:
		return
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) if _sun != null else 0.0
	_snow_layer.call("set_weather", _snow_level, get_wind_vector(), daylight)
