@tool
extends Resource
## 一档雨天的可保存关键帧。雨量坐标由控制器固定为晴/小/中/大/暴，运行时连续插值。
@export var label := ""
## 雨线调节系数；密度、速度仍乘场景中的暴雨上限。
@export_range(0.0, 3.0, 0.01) var streak_density: float = 0
## 雨线调节系数；密度、速度仍乘场景中的暴雨上限。
@export_range(0.0, 3.0, 0.01) var streak_speed: float = 0
## 雨线调节系数；密度、速度仍乘场景中的暴雨上限。
@export_range(0.0, 3.0, 0.01) var streak_width: float = 0
## 雨线调节系数；密度、速度仍乘场景中的暴雨上限。
@export_range(0.0, 3.0, 0.01) var streak_length: float = 0
## 雨线调节系数；密度、速度仍乘场景中的暴雨上限。
@export_range(0.0, 4.0, 0.01) var streak_length_power: float = 2.8
## 雨线调节系数；密度、速度仍乘场景中的暴雨上限。
@export_range(0.0, 3.0, 0.01) var streak_brightness: float = 0
## 落点调节系数，频率乘场景的暴雨上限。
@export_range(0.0, 3.0, 0.01) var impact_rate: float = 0
## 落点贴片直径下限，单位米；水花会在贴片内扩张。
@export_range(0.0, 3.0, 0.01) var impact_size_min: float = 0
## 落点贴片直径上限，单位米；每次生成在上下限间随机。
@export_range(0.0, 3.0, 0.01) var impact_size_max: float = 0
## 落点调节系数，频率乘场景的暴雨上限。
@export_range(0.0, 3.0, 0.01) var impact_brightness: float = 0
## 落点调节系数，频率乘场景的暴雨上限。
@export_range(0.0, 3.0, 0.01) var impact_lifetime: float = 0
## 阴沉程度和雨雾目标强度，0 到 1。
@export_range(0.0, 3.0, 0.01) var storm_strength: float = 0
## 云层遮住太阳的比例，1 时无太阳直射。
@export_range(0.0, 3.0, 0.01) var cloud_cover: float = 0
## 此档雨对阵风落点带的响应；风本身仍遵循全局静风/阵风节律。
@export_range(0.0, 3.0, 0.01) var wind_band_response: float = 0
## 地面目标湿润程度，停雨后缓慢变干。
@export_range(0.0, 3.0, 0.01) var wetness: float = 0
