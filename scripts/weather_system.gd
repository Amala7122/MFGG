extends "res://scripts/weather_rain_controller.gd"
class_name WeatherSystem
## 主场景与天气实验场共用的统一天气入口。
## 云、雨、雾、雪是可独立启用的层；天空、光照、雾只在本节点合成一次。
##
## Cloud Layer 当前仍保留两种照明性格：
## - Cumulus 多云：蓝天仍占较大比例，保留较强直射光。
## - Stratus 阴天：连续云底逐步接管直射光与环境光。
##
## 云形由 ProceduralCloudField 复用六种启动时生成的基础网格。
## Coverage 控制云团生长与横向连片；Density 控制厚度与吸光。
## 高覆盖率保留立体云底，同时由天空云幕补齐远处缝隙。
## 整个过程保持 unshaded / matte，不引入太阳高光、银边或真实体积云反射。

const CloudField := preload("res://scripts/procedural_cloud_field.gd")
const CloudShadowLighting := preload("res://scripts/cloud_lighting.gd")

enum CloudType { CUMULUS, STRATUS }

@export_category("编辑器预览")
## 开启后，在 Godot 编辑器 3D 视口里直接预览云、天空光照、太阳与雾。
## 预览由独立 @tool 适配器执行，不会启动雨粒子、风状态机、落点池或其它游戏逻辑。
@export var editor_preview_enabled := true

@export_category("天气组合：可复选")
@export var cloud_enabled := false
## 当前主要决定照明性格；云的视觉形态由 Coverage 连续控制。
@export_enum("Cumulus 多云:0", "Stratus 阴天:1") var cloud_type: int = CloudType.STRATUS
## 云团数量与连片程度。低值是稀疏云团，高值铺开并由天空云幕补齐缝隙。
@export_range(0.0, 1.0, 0.01) var cloud_coverage := 1.0
## 云有多厚。它不决定覆盖面积；低值偏明亮薄云，高值偏厚重吸光。
@export_range(0.0, 1.0, 0.01) var cloud_density := 0.47
## 关闭雨层不影响云、雾、雪或风。雨量使用下方五档预设/连续雨量设置。
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

@export_category("程序云：移动与形态")
## 切面版保留低多边形云的折线；圆润版保留上一轮结果用于比较。
@export_enum("切面云:0", "圆润云（保留）:1") var cloud_shape_style := 0
## 高空主导风速，单位米/秒；高层云以此速度的 0.64 倍移动。
## 独立于地表阵风，避免地表静风时整个天空也停住。
@export_range(0.0, 40.0, 0.5) var cloud_wind_speed := 8.0
## 推进方向：0 沿 +X，90 沿 +Z；高层略偏转以形成层次。
@export_range(0.0, 360.0, 1.0, "degrees") var cloud_wind_direction_degrees := 225.0
@export_range(0.25, 3.0, 0.05) var cloud_size_multiplier := 1.0
## 可选轻微边缘变形。默认关闭；启用后只在 GPU 上变形共享网格。
@export_range(0.0, 0.15, 0.005) var cloud_deformation_amount := 0.0

@export_category("程序云：地面云影")
## 云体投射真实阴影，随太阳方向、云移动/缩放/变形自动变化。
## 复用现有太阳阴影图，不改接收距离/分级，不另建灯光。
## 目前覆盖镜头附近；远景云影需要后续单独处理。薄云仍按不透明云体遮光。
@export var cloud_shadow_enabled := true
## 太阳的 PCSS 光源角径：高空云影随投影距离变柔，近地阴影仍保持较窄边缘。
## 阳光强度由当前太阳能量与高度推导；强光也保留模糊下限。
@export_range(0.1, 2.0, 0.05, "degrees") var cloud_shadow_strong_sun_angle := 0.5
@export_range(0.1, 4.0, 0.05, "degrees") var cloud_shadow_weak_sun_angle := 1.5
## 日光强度固定参照；太阳能量与高度的乘积达到该值时采用强日光的柔度。
@export_range(0.05, 8.0, 0.05) var cloud_shadow_reference_energy := 1.5

var _cloud_level := 0.0
var _cloud_density_level := 0.0
var _snow_level := 0.0
var _sun_angular_baseline := 0.0
var _sun_pancake_baseline := 20.0
@onready var _cloud_field: CloudField = get_node_or_null("ProceduralCloudField")
@onready var _snow_layer: Node3D = get_node_or_null("SnowLayer")

func _ready() -> void:
	if is_instance_valid(_sun):
		_sun_angular_baseline = _sun.light_angular_distance
		_sun_pancake_baseline = _sun.directional_shadow_pancake_size
	# 注：此处旧 WIP 曾写 `_precipitation_environment_coupling = 0.0`，但父类
	# WeatherRainController 并没有该字段（会导致整个脚本解析失败）。父类现用
	# storm_environment_strength（默认 1.0）控制“雨量带来阴天”，单独实例化时保留
	# 旧行为；主游戏的天空参数由下方 _apply_stylized_cloud_field() 逐帧覆写，
	# 因此这里不再改动该耦合。若确需在主游戏关闭它，在此设 storm_environment_strength = 0.0。
	_cloud_level = cloud_coverage if cloud_enabled else 0.0
	_cloud_density_level = cloud_density
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

	# 可见云体由共享的程序低多边形云场负责。
	_sky_dome.set("cumulus_visible", false)

	var coverage := clampf(_cloud_level, 0.0, 1.0)
	var density := clampf(_cloud_density_level, 0.0, 1.0)
	# 0.55 前基本保持独立云团；0.55~0.88 逐步连片并靠拢云幕颜色。
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

	if not is_instance_valid(_cloud_field):
		return

	# 保留原天气色组，云团的几何厚度与覆盖面积由云场独立控制。
	var day_bank_light := Color(0.78, 0.82, 0.86, 1.0)
	var day_bank_heavy := Color(0.34, 0.39, 0.45, 1.0)
	var night_bank := Color(0.11, 0.14, 0.20, 1.0)
	var bank_heavy := smoothstep(0.50, 1.0, density) * smoothstep(0.45, 1.0, coverage)
	var day_bank := day_bank_light.lerp(day_bank_heavy, bank_heavy)
	var matte_bank := night_bank.lerp(day_bank, daylight)

	_cloud_field.set_motion(cloud_wind_speed, cloud_wind_direction_degrees,
		cloud_size_multiplier, cloud_deformation_amount)
	_cloud_field.set_shape_style(cloud_shape_style)
	_cloud_field.set_weather(coverage, density, overcast_blend, matte_bank, matte_deck)
	_cloud_field.set_cloud_shadows(cloud_shadow_enabled)
	CloudShadowLighting.apply_cloud_shadow_softness(self, _sun,
		_sun_angular_baseline, _cloud_field.visible,
		_sun_pancake_baseline, _cloud_field.get_cloud_height_ceiling())


func _update_snow_layer() -> void:
	if _snow_layer == null:
		return
	var daylight := smoothstep(-0.06, 0.25, _sun.global_basis.z.normalized().y) if _sun != null else 0.0
	_snow_layer.call("set_weather", _snow_level, get_wind_vector(), daylight)
