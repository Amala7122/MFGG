extends Node
class_name WeatherTimeline
## 程序化天气时间线驱动器。
##
## 挂在 WeatherEnvironment 下，自动查找 TimeOfDay 和 WeatherSystem，
## 根据游戏内时间流逝产生自然的天气变化。
##
## 设计原则：
##   1. 每局游戏用种子 RNG 在 _ready 时生成多日"天气预报"，同一种子必定产出同样的天气。
##   2. 天气不是瞬间切换，而是在两个预报节点之间做 smoothstep 插值，模拟自然过渡。
##   3. 遵循"气象学常识"：晴→多云→小雨→大雨是渐进的，暴雨后通常放晴。
##   4. 驱动维度：雨量 / 雾量 / 雪量 / 风强度 / 风向，覆盖游戏内全部天气表现。

## ───────────────────────── 配置 ─────────────────────────

@export_category("天气预报")
## 生成多少天的天气预报。超出后会追加生成。
@export var forecast_days: int = 7
## 随机种子。0 = 每次运行随机；非 0 = 可复现。
@export var weather_seed: int = 0
## 暴雨概率权重。
@export_range(0.0, 1.0, 0.05) var storm_probability: float = 0.15
## 雪的概率权重（设为 0 则永远不下雪）。
@export_range(0.0, 1.0, 0.05) var snow_probability: float = 0.08
## 大雾概率。
@export_range(0.0, 1.0, 0.05) var fog_probability: float = 0.12
## 是否在控制台打印天气变化日志。
@export var debug_log: bool = false

@export_category("调试工具")
## F1 = 暂停/恢复敌人，F2 = 时间加速开关，F3 = 跳过到下一个天气节点。
@export var debug_keys_enabled: bool = true

## ───────────────────────── 天气快照 ─────────────────────────

class WeatherKeyframe:
	var abs_hour: float = 0.0
	var rain: float = 0.0
	var fog: float = 0.0
	var snow: float = 0.0
	var wind_strength: float = 0.3  ## 0 = 静风，1 = 狂风
	var wind_dir_degrees: float = 225.0
	var label: String = ""

	func _init(h: float = 0.0, r: float = 0.0, f: float = 0.0, s: float = 0.0,
			w: float = 0.3, wd: float = 225.0, l: String = "") -> void:
		abs_hour = h; rain = r; fog = f; snow = s
		wind_strength = w; wind_dir_degrees = wd; label = l

## ───────────────────────── 日型 ─────────────────────────

enum DayPattern {
	SUNNY_DAY,                     # 全天晴朗
	BREEZY_CLEAR,                  # 晴朗但有风
	MORNING_CLEAR_AFTERNOON_RAIN,  # 上午晴→午后转雨
	RAINY_DAY,                     # 全天有雨
	STORM_DAY,                     # 暴雨日
	FOGGY_MORNING,                 # 清晨大雾→午后放晴
	OVERCAST_DAY,                  # 全天阴天无雨
	SNOW_DAY,                      # 雪天
	RAIN_TO_SNOW,                  # 雨转雪
	VARIABLE,                      # 多变天气
	EVENING_DRIZZLE,               # 傍晚小雨
	WINDY_OVERCAST,                # 大风阴天
}

## ───────────────────────── 运行时状态 ─────────────────────────

var _rng := RandomNumberGenerator.new()
var _keyframes: Array = []
var _current_idx: int = 0
var _generated_days: int = 0
var _last_abs_hour: float = -1.0
var _weather_system: Node = null
var _time_of_day: Node = null
var _current_day_base: int = 0
var _current_label: String = ""

# 调试用
var _enemies_paused: bool = false
var _time_accelerated: bool = false
var _original_minutes_per_day: float = 15.0
var _debug_label: Label = null

signal weather_label_changed(label: String)


func _ready() -> void:
	_weather_system = _find_node_with_script("res://scripts/weather_system.gd")
	if not _weather_system:
		push_warning("WeatherTimeline: 未找到 WeatherSystem。")
		set_process(false)
		return

	_time_of_day = _find_node_with_script("res://addons/sky_3d/src/TimeOfDay.gd")
	if not _time_of_day:
		push_warning("WeatherTimeline: 未找到 TimeOfDay。")
		set_process(false)
		return

	if weather_seed == 0:
		_rng.randomize()
	else:
		_rng.seed = weather_seed

	_current_day_base = int(_time_of_day.get("day")) if _time_of_day.get("day") != null else 0
	_original_minutes_per_day = float(_time_of_day.get("minutes_per_day"))

	_generate_forecast(forecast_days)
	_apply_weather_at(_get_abs_hour())

	if debug_log:
		_print_forecast()

	if debug_keys_enabled:
		_create_debug_hud()


func _input(event: InputEvent) -> void:
	if not debug_keys_enabled or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var code: int = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	match code:
		KEY_F1:
			_toggle_enemies()
			get_viewport().set_input_as_handled()
		KEY_F2:
			_toggle_time_speed()
			get_viewport().set_input_as_handled()
		KEY_F3:
			_skip_to_next_keyframe()
			get_viewport().set_input_as_handled()



func _process(_delta: float) -> void:
	var abs_hour := _get_abs_hour()
	if absf(abs_hour - _last_abs_hour) > 0.001:
		_last_abs_hour = abs_hour
		_apply_weather_at(abs_hour)
	_update_debug_hud()


## ───────────────────────── 天气预报生成 ─────────────────────────

func _generate_forecast(days: int) -> void:
	for i in range(days):
		var day_index := _generated_days + i
		var pattern := _pick_day_pattern()
		var wind_base_dir := _rng.randf_range(0.0, 360.0)
		_keyframes.append_array(_generate_day(day_index, pattern, wind_base_dir))
	_generated_days += days


func _pick_day_pattern() -> DayPattern:
	var weights := {
		DayPattern.SUNNY_DAY: 0.18,
		DayPattern.BREEZY_CLEAR: 0.10,
		DayPattern.MORNING_CLEAR_AFTERNOON_RAIN: 0.12,
		DayPattern.RAINY_DAY: 0.10,
		DayPattern.STORM_DAY: storm_probability,
		DayPattern.FOGGY_MORNING: fog_probability,
		DayPattern.OVERCAST_DAY: 0.10,
		DayPattern.SNOW_DAY: snow_probability,
		DayPattern.RAIN_TO_SNOW: snow_probability * 0.5,
		DayPattern.VARIABLE: 0.10,
		DayPattern.EVENING_DRIZZLE: 0.08,
		DayPattern.WINDY_OVERCAST: 0.08,
	}
	var total := 0.0
	for w in weights.values():
		total += w
	var roll := _rng.randf() * total
	var cumulative := 0.0
	for p in weights:
		cumulative += weights[p]
		if roll <= cumulative:
			return p as DayPattern
	return DayPattern.SUNNY_DAY


func _generate_day(day_idx: int, pattern: DayPattern, wind_dir: float) -> Array:
	var kfs: Array = []
	var b := float(day_idx) * 24.0  # base hour
	# 辅助：为每个 keyframe 加入微随机风向偏移
	var wd := func(base: float) -> float: return fmod(base + _rng.randf_range(-30, 30) + 360.0, 360.0)
	var rf := func(lo: float, hi: float) -> float: return _rng.randf_range(lo, hi)

	match pattern:
		DayPattern.SUNNY_DAY:
			#              hour  rain  fog   snow  wind  wind_dir  label
			kfs.append(WeatherKeyframe.new(b+0,  0, 0,    0, rf.call(0.05,0.15), wd.call(wind_dir), "夜间晴朗"))
			kfs.append(WeatherKeyframe.new(b+6,  0, rf.call(0,0.06), 0, rf.call(0.08,0.20), wd.call(wind_dir), "清晨薄雾散去"))
			kfs.append(WeatherKeyframe.new(b+10, 0, 0,    0, rf.call(0.12,0.25), wd.call(wind_dir), "上午阳光明媚"))
			kfs.append(WeatherKeyframe.new(b+14, 0, 0,    0, rf.call(0.15,0.30), wd.call(wind_dir), "午后暖风"))
			kfs.append(WeatherKeyframe.new(b+19, 0, 0,    0, rf.call(0.08,0.18), wd.call(wind_dir), "傍晚微风"))
			kfs.append(WeatherKeyframe.new(b+23.5, 0, 0,  0, rf.call(0.03,0.10), wd.call(wind_dir), "夜深风止"))

		DayPattern.BREEZY_CLEAR:
			kfs.append(WeatherKeyframe.new(b+0,  0, 0, 0, rf.call(0.20,0.35), wd.call(wind_dir), "夜间有风"))
			kfs.append(WeatherKeyframe.new(b+7,  0, 0, 0, rf.call(0.35,0.55), wd.call(wind_dir), "早晨起风"))
			kfs.append(WeatherKeyframe.new(b+12, 0, 0, 0, rf.call(0.55,0.75), wd.call(wind_dir), "正午大风"))
			kfs.append(WeatherKeyframe.new(b+16, 0, rf.call(0,0.08), 0, rf.call(0.60,0.80), wd.call(wind_dir), "午后劲风"))
			kfs.append(WeatherKeyframe.new(b+20, 0, 0, 0, rf.call(0.30,0.50), wd.call(wind_dir), "入夜风减"))
			kfs.append(WeatherKeyframe.new(b+23.5, 0, 0, 0, rf.call(0.15,0.25), wd.call(wind_dir), "深夜渐静"))

		DayPattern.MORNING_CLEAR_AFTERNOON_RAIN:
			var peak: float = rf.call(0.25, 0.55)
			kfs.append(WeatherKeyframe.new(b+0,  0, 0, 0, rf.call(0.08,0.15), wd.call(wind_dir), "凌晨晴朗"))
			kfs.append(WeatherKeyframe.new(b+8,  0, 0, 0, rf.call(0.10,0.20), wd.call(wind_dir), "上午晴好"))
			kfs.append(WeatherKeyframe.new(b+11, 0, rf.call(0.10,0.22), 0, rf.call(0.20,0.35), wd.call(wind_dir), "午前转阴"))
			kfs.append(WeatherKeyframe.new(b+14, peak*0.5, rf.call(0.12,0.20), 0, rf.call(0.30,0.50), wd.call(wind_dir), "午后飘雨"))
			kfs.append(WeatherKeyframe.new(b+17, peak, rf.call(0.18,0.30), 0, rf.call(0.40,0.60), wd.call(wind_dir), "傍晚雨势渐大"))
			kfs.append(WeatherKeyframe.new(b+21, peak*0.3, rf.call(0.08,0.15), 0, rf.call(0.25,0.35), wd.call(wind_dir), "入夜雨渐停"))
			kfs.append(WeatherKeyframe.new(b+23.5, 0, rf.call(0,0.05), 0, rf.call(0.08,0.15), wd.call(wind_dir), "深夜放晴"))

		DayPattern.RAINY_DAY:
			var base_rain: float = rf.call(0.28, 0.60)
			var base_fog: float = rf.call(0.15, 0.30)
			kfs.append(WeatherKeyframe.new(b+0,  base_rain*0.4, base_fog*0.5, 0, rf.call(0.25,0.40), wd.call(wind_dir), "凌晨细雨"))
			kfs.append(WeatherKeyframe.new(b+5,  base_rain*0.6, base_fog*0.7, 0, rf.call(0.30,0.50), wd.call(wind_dir), "清晨持续降雨"))
			kfs.append(WeatherKeyframe.new(b+10, base_rain, base_fog, 0, rf.call(0.40,0.65), wd.call(wind_dir), "上午雨势最强"))
			kfs.append(WeatherKeyframe.new(b+13, base_rain*0.9, base_fog*0.85, 0, rf.call(0.35,0.55), wd.call(wind_dir), "午间不减"))
			kfs.append(WeatherKeyframe.new(b+17, base_rain*0.7, base_fog*0.7, 0, rf.call(0.30,0.45), wd.call(wind_dir), "傍晚稍缓"))
			kfs.append(WeatherKeyframe.new(b+21, base_rain*0.45, base_fog*0.5, 0, rf.call(0.20,0.35), wd.call(wind_dir), "入夜淅沥"))
			kfs.append(WeatherKeyframe.new(b+23.5, base_rain*0.3, base_fog*0.3, 0, rf.call(0.15,0.25), wd.call(wind_dir), "深夜绵绵"))

		DayPattern.STORM_DAY:
			var build: float = rf.call(8.0, 13.0)
			var peak_h: float = build + rf.call(2.0, 3.5)
			var clear_h: float = minf(peak_h + rf.call(3.0, 5.0), 22.0)
			kfs.append(WeatherKeyframe.new(b+0, 0, rf.call(0.05,0.12), 0, rf.call(0.10,0.20), wd.call(wind_dir), "暴风雨前的宁静"))
			kfs.append(WeatherKeyframe.new(b+build-2, 0, rf.call(0.18,0.30), 0, rf.call(0.25,0.40), wd.call(wind_dir), "天色渐沉"))
			kfs.append(WeatherKeyframe.new(b+build, 0.28, rf.call(0.20,0.30), 0, rf.call(0.40,0.55), wd.call(wind_dir), "乌云压顶，开始落雨"))
			kfs.append(WeatherKeyframe.new(b+peak_h, rf.call(0.85,1.0), rf.call(0.45,0.65), 0, rf.call(0.75,0.95), wd.call(wind_dir), "暴雨倾盆！"))
			kfs.append(WeatherKeyframe.new(b+peak_h+1.5, rf.call(0.80,0.95), rf.call(0.40,0.55), 0, rf.call(0.70,0.90), wd.call(wind_dir), "狂风暴雨持续"))
			kfs.append(WeatherKeyframe.new(b+clear_h, 0.18, rf.call(0.10,0.18), 0, rf.call(0.35,0.50), wd.call(wind_dir), "雨势减弱"))
			kfs.append(WeatherKeyframe.new(b+minf(clear_h+2,23.5), 0, rf.call(0,0.08), 0, rf.call(0.15,0.25), wd.call(wind_dir), "雨过天晴"))

		DayPattern.FOGGY_MORNING:
			var fog_peak: float = rf.call(0.55, 0.85)
			kfs.append(WeatherKeyframe.new(b+0,  0, fog_peak*0.2, 0, rf.call(0.03,0.08), wd.call(wind_dir), "凌晨薄雾"))
			kfs.append(WeatherKeyframe.new(b+4,  0, fog_peak*0.7, 0, rf.call(0.02,0.06), wd.call(wind_dir), "浓雾渐起"))
			kfs.append(WeatherKeyframe.new(b+6,  0, fog_peak, 0, rf.call(0.02,0.05), wd.call(wind_dir), "大雾弥漫，能见度极低"))
			kfs.append(WeatherKeyframe.new(b+9,  0, fog_peak*0.6, 0, rf.call(0.08,0.15), wd.call(wind_dir), "日出暖气驱散薄雾"))
			kfs.append(WeatherKeyframe.new(b+12, 0, rf.call(0.05,0.12), 0, rf.call(0.12,0.22), wd.call(wind_dir), "雾散天晴"))
			kfs.append(WeatherKeyframe.new(b+18, 0, rf.call(0,0.05), 0, rf.call(0.10,0.18), wd.call(wind_dir), "傍晚通透"))
			kfs.append(WeatherKeyframe.new(b+23.5, 0, rf.call(0.05,0.15), 0, rf.call(0.03,0.08), wd.call(wind_dir), "夜间微雾再起"))

		DayPattern.OVERCAST_DAY:
			kfs.append(WeatherKeyframe.new(b+0,  0, rf.call(0.10,0.20), 0, rf.call(0.15,0.25), wd.call(wind_dir), "凌晨多云"))
			kfs.append(WeatherKeyframe.new(b+7,  0, rf.call(0.18,0.30), 0, rf.call(0.20,0.35), wd.call(wind_dir), "早晨阴沉"))
			kfs.append(WeatherKeyframe.new(b+12, rf.call(0,0.05), rf.call(0.22,0.35), 0, rf.call(0.25,0.40), wd.call(wind_dir), "正午厚重云层"))
			kfs.append(WeatherKeyframe.new(b+17, 0, rf.call(0.15,0.28), 0, rf.call(0.20,0.30), wd.call(wind_dir), "傍晚依旧阴"))
			kfs.append(WeatherKeyframe.new(b+23.5, 0, rf.call(0.08,0.18), 0, rf.call(0.10,0.20), wd.call(wind_dir), "深夜阴云"))

		DayPattern.SNOW_DAY:
			var snow_i: float = rf.call(0.30, 0.80)
			kfs.append(WeatherKeyframe.new(b+0,  0, rf.call(0.08,0.15), snow_i*0.15, rf.call(0.10,0.20), wd.call(wind_dir), "凌晨零星飘雪"))
			kfs.append(WeatherKeyframe.new(b+6,  0, rf.call(0.12,0.22), snow_i*0.5, rf.call(0.15,0.30), wd.call(wind_dir), "清晨雪渐大"))
			kfs.append(WeatherKeyframe.new(b+11, 0, rf.call(0.18,0.30), snow_i, rf.call(0.25,0.45), wd.call(wind_dir), "纷纷扬扬"))
			kfs.append(WeatherKeyframe.new(b+15, 0, rf.call(0.15,0.25), snow_i*0.85, rf.call(0.30,0.50), wd.call(wind_dir), "午后风雪交加"))
			kfs.append(WeatherKeyframe.new(b+19, 0, rf.call(0.10,0.18), snow_i*0.5, rf.call(0.20,0.35), wd.call(wind_dir), "傍晚雪势渐缓"))
			kfs.append(WeatherKeyframe.new(b+23.5, 0, rf.call(0.05,0.12), snow_i*0.15, rf.call(0.08,0.15), wd.call(wind_dir), "深夜小雪"))

		DayPattern.RAIN_TO_SNOW:
			var rain_peak: float = rf.call(0.30, 0.55)
			var snow_peak: float = rf.call(0.30, 0.60)
			kfs.append(WeatherKeyframe.new(b+0,  0, rf.call(0.05,0.12), 0, rf.call(0.10,0.20), wd.call(wind_dir), "凌晨阴天"))
			kfs.append(WeatherKeyframe.new(b+6,  rain_peak*0.4, rf.call(0.12,0.20), 0, rf.call(0.20,0.35), wd.call(wind_dir), "清晨小雨"))
			kfs.append(WeatherKeyframe.new(b+10, rain_peak, rf.call(0.18,0.30), 0, rf.call(0.30,0.50), wd.call(wind_dir), "上午雨势渐大"))
			kfs.append(WeatherKeyframe.new(b+14, rain_peak*0.5, rf.call(0.20,0.30), snow_peak*0.3, rf.call(0.35,0.50), wd.call(wind_dir), "午后雨夹雪"))
			kfs.append(WeatherKeyframe.new(b+17, 0, rf.call(0.15,0.25), snow_peak, rf.call(0.30,0.45), wd.call(wind_dir), "傍晚转纯雪"))
			kfs.append(WeatherKeyframe.new(b+21, 0, rf.call(0.10,0.18), snow_peak*0.5, rf.call(0.15,0.25), wd.call(wind_dir), "入夜雪小"))
			kfs.append(WeatherKeyframe.new(b+23.5, 0, rf.call(0.05,0.10), snow_peak*0.1, rf.call(0.05,0.12), wd.call(wind_dir), "深夜渐停"))

		DayPattern.EVENING_DRIZZLE:
			kfs.append(WeatherKeyframe.new(b+0,  0, 0, 0, rf.call(0.05,0.12), wd.call(wind_dir), "凌晨晴朗"))
			kfs.append(WeatherKeyframe.new(b+8,  0, 0, 0, rf.call(0.10,0.20), wd.call(wind_dir), "上午天气不错"))
			kfs.append(WeatherKeyframe.new(b+15, 0, rf.call(0.05,0.12), 0, rf.call(0.15,0.25), wd.call(wind_dir), "下午云渐多"))
			kfs.append(WeatherKeyframe.new(b+18, rf.call(0.10,0.22), rf.call(0.08,0.18), 0, rf.call(0.20,0.35), wd.call(wind_dir), "傍晚飘起细雨"))
			kfs.append(WeatherKeyframe.new(b+21, rf.call(0.15,0.28), rf.call(0.10,0.20), 0, rf.call(0.18,0.28), wd.call(wind_dir), "夜间淅淅沥沥"))
			kfs.append(WeatherKeyframe.new(b+23.5, rf.call(0.08,0.15), rf.call(0.05,0.12), 0, rf.call(0.08,0.15), wd.call(wind_dir), "深夜小雨"))

		DayPattern.WINDY_OVERCAST:
			kfs.append(WeatherKeyframe.new(b+0,  0, rf.call(0.10,0.18), 0, rf.call(0.30,0.45), wd.call(wind_dir), "凌晨大风"))
			kfs.append(WeatherKeyframe.new(b+6,  0, rf.call(0.15,0.25), 0, rf.call(0.50,0.70), wd.call(wind_dir), "清晨狂风阴天"))
			kfs.append(WeatherKeyframe.new(b+11, rf.call(0,0.08), rf.call(0.20,0.35), 0, rf.call(0.65,0.85), wd.call(wind_dir), "午前大风呼啸"))
			kfs.append(WeatherKeyframe.new(b+15, rf.call(0,0.05), rf.call(0.18,0.28), 0, rf.call(0.55,0.75), wd.call(wind_dir), "午后风力不减"))
			kfs.append(WeatherKeyframe.new(b+20, 0, rf.call(0.10,0.18), 0, rf.call(0.35,0.50), wd.call(wind_dir), "入夜风渐小"))
			kfs.append(WeatherKeyframe.new(b+23.5, 0, rf.call(0.05,0.12), 0, rf.call(0.20,0.30), wd.call(wind_dir), "深夜风歇"))

		_:  # VARIABLE 或 fallback
			var types := [0.0, 0.0, 0.0, 0.0]  # rain, fog, snow, wind
			var count := _rng.randi_range(4, 7)
			var hours: Array = [0.0]
			for j in range(count - 2):
				hours.append(rf.call(2.0, 22.0))
			hours.append(23.5)
			hours.sort()
			for j in range(hours.size()):
				# 随机扰动每个维度
				types[0] = clampf(types[0] + rf.call(-0.2, 0.25), 0.0, 0.65)
				types[1] = clampf(types[1] + rf.call(-0.15, 0.2), 0.0, 0.5)
				types[2] = clampf(types[2] + rf.call(-0.1, 0.1) * snow_probability * 5.0, 0.0, 0.5)
				types[3] = clampf(types[3] + rf.call(-0.15, 0.2), 0.05, 0.7)
				var lbl := "多变天气"
				if types[0] > 0.3: lbl = "阵雨"
				elif types[2] > 0.15: lbl = "阵雪"
				elif types[1] > 0.25: lbl = "云雾"
				elif types[3] > 0.5: lbl = "大风"
				else: lbl = "多云间晴"
				kfs.append(WeatherKeyframe.new(b+hours[j], types[0], types[1], types[2], types[3], wd.call(wind_dir), lbl))

	return kfs


## ───────────────────────── 天气应用 ─────────────────────────

func _get_abs_hour() -> float:
	if not _time_of_day:
		return 0.0
	var day: int = int(_time_of_day.get("day")) if _time_of_day.get("day") != null else 0
	var hour: float = float(_time_of_day.get("current_time")) if _time_of_day.get("current_time") != null else 0.0
	return float(day - _current_day_base) * 24.0 + hour


func _apply_weather_at(abs_hour: float) -> void:
	if _keyframes.is_empty():
		return

	var last_kf: WeatherKeyframe = _keyframes[_keyframes.size() - 1]
	if abs_hour > last_kf.abs_hour - 24.0:
		_generate_forecast(3)
		if debug_log:
			print("[天气] 追加 3 天预报，共 %d 天" % _generated_days)

	while _current_idx < _keyframes.size() - 2:
		var next_kf: WeatherKeyframe = _keyframes[_current_idx + 1]
		if abs_hour < next_kf.abs_hour:
			break
		_current_idx += 1

	var kf_a: WeatherKeyframe = _keyframes[_current_idx]
	var kf_b: WeatherKeyframe = _keyframes[mini(_current_idx + 1, _keyframes.size() - 1)]

	var span := kf_b.abs_hour - kf_a.abs_hour
	var t := 0.0
	if span > 0.001:
		t = clampf((abs_hour - kf_a.abs_hour) / span, 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)  # smoothstep

	var rain := lerpf(kf_a.rain, kf_b.rain, t)
	var fog := lerpf(kf_a.fog, kf_b.fog, t)
	var snow := lerpf(kf_a.snow, kf_b.snow, t)
	var wind := lerpf(kf_a.wind_strength, kf_b.wind_strength, t)
	var wind_dir := lerp_angle(deg_to_rad(kf_a.wind_dir_degrees), deg_to_rad(kf_b.wind_dir_degrees), t)

	# 驱动 WeatherSystem
	if _weather_system.has_method("set_rain_amount"):
		_weather_system.call("set_rain_amount", rain)
	if _weather_system.has_method("set_fog_amount"):
		_weather_system.call("set_fog_amount", fog)
	if _weather_system.has_method("set_snow_amount"):
		_weather_system.call("set_snow_amount", snow)

	# 驱动风力：直接设置 WeatherRainController 的阵风参数
	_weather_system.set("gust_strength_min", clampf(wind * 0.7, 0.05, 1.0))
	_weather_system.set("gust_strength_max", clampf(wind * 1.3, 0.05, 1.0))
	_weather_system.set("prevailing_direction_degrees", rad_to_deg(wind_dir))
	# 暴雨时缩短静风间隙，让风持续吹
	if rain > 0.6 or snow > 0.4:
		_weather_system.set("calm_seconds_min", 1.0)
		_weather_system.set("calm_seconds_max", 3.0)
	else:
		_weather_system.set("calm_seconds_min", 5.0)
		_weather_system.set("calm_seconds_max", 18.0)

	var new_label := kf_a.label if t < 0.5 else kf_b.label
	if new_label != _current_label:
		_current_label = new_label
		emit_signal("weather_label_changed", new_label)
		if debug_log:
			print("[天气] %s" % new_label)


## ───────────────────────── 调试工具 ─────────────────────────

func _toggle_enemies() -> void:
	_enemies_paused = not _enemies_paused
	get_tree().call_group("enemies", "set_process", not _enemies_paused)
	get_tree().call_group("enemies", "set_physics_process", not _enemies_paused)
	# 也暂停敌人子弹
	for bullet in get_tree().get_nodes_in_group("enemy_bullets"):
		bullet.set_physics_process(not _enemies_paused)
	if debug_log:
		print("[调试] 敌人 %s" % ("已冻结" if _enemies_paused else "已恢复"))


func _toggle_time_speed() -> void:
	_time_accelerated = not _time_accelerated
	if _time_accelerated:
		# 加速到 60 倍（15 分钟一天 → 15 秒一天）
		_time_of_day.set("minutes_per_day", _original_minutes_per_day / 60.0)
	else:
		_time_of_day.set("minutes_per_day", _original_minutes_per_day)
	if debug_log:
		print("[调试] 时间速度 %s" % ("×60 加速" if _time_accelerated else "恢复正常"))


func _skip_to_next_keyframe() -> void:
	if _current_idx + 1 >= _keyframes.size():
		return
	var next_kf: WeatherKeyframe = _keyframes[_current_idx + 1]
	# 直接跳转 TimeOfDay
	var target_hour := fmod(next_kf.abs_hour, 24.0)
	_time_of_day.set("current_time", target_hour)
	if debug_log:
		print("[调试] 跳转到下一天气节点：%s (%.1f:00)" % [next_kf.label, target_hour])


func _create_debug_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "WeatherDebugHUD"
	canvas.layer = 120
	add_child(canvas)
	_debug_label = Label.new()
	_debug_label.position = Vector2(12, 12)
	_debug_label.add_theme_font_size_override("font_size", 14)
	_debug_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0, 0.85))
	_debug_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_debug_label.add_theme_constant_override("shadow_offset_x", 1)
	_debug_label.add_theme_constant_override("shadow_offset_y", 1)
	canvas.add_child(_debug_label)


func _update_debug_hud() -> void:
	if not _debug_label:
		return
	var abs_h := _get_abs_hour()
	var day := int(abs_h / 24.0) + 1
	var hour := fmod(abs_h, 24.0)
	var time_str := "%02d:%02d" % [int(hour), int(fmod(hour * 60.0, 60.0))]

	var kf_a: WeatherKeyframe = _keyframes[_current_idx] if _current_idx < _keyframes.size() else null
	var rain_pct := 0.0; var fog_pct := 0.0; var snow_pct := 0.0; var wind_pct := 0.0
	if kf_a:
		var kf_b: WeatherKeyframe = _keyframes[mini(_current_idx+1, _keyframes.size()-1)]
		var span := kf_b.abs_hour - kf_a.abs_hour
		var t := clampf((abs_h - kf_a.abs_hour) / maxf(span, 0.001), 0.0, 1.0)
		t = t * t * (3.0 - 2.0 * t)
		rain_pct = lerpf(kf_a.rain, kf_b.rain, t) * 100
		fog_pct = lerpf(kf_a.fog, kf_b.fog, t) * 100
		snow_pct = lerpf(kf_a.snow, kf_b.snow, t) * 100
		wind_pct = lerpf(kf_a.wind_strength, kf_b.wind_strength, t) * 100

	var lines := "[天气系统] 第%d天 %s  %s" % [day, time_str, _current_label]
	lines += "\n  雨 %.0f%%  雾 %.0f%%  雪 %.0f%%  风 %.0f%%" % [rain_pct, fog_pct, snow_pct, wind_pct]
	lines += "\n[F1] 敌人: %s  [F2] 时间: %s  [F3] 跳到下个天气" % [
		"冻结" if _enemies_paused else "正常",
		"×60加速" if _time_accelerated else "正常",
	]
	_debug_label.text = lines


## ───────────────────────── 工具 ─────────────────────────

func _find_node_with_script(script_path: String) -> Node:
	var parent := get_parent()
	if parent:
		for child in parent.get_children():
			if child.get_script() and child.get_script().resource_path == script_path:
				return child
		var gp := parent.get_parent()
		if gp:
			var found := _search_tree(gp, script_path)
			if found: return found
	var root := get_tree().current_scene
	if root:
		return _search_tree(root, script_path)
	return null


func _search_tree(node: Node, script_path: String) -> Node:
	if node.get_script() and node.get_script().resource_path == script_path:
		return node
	for child in node.get_children():
		var found := _search_tree(child, script_path)
		if found: return found
	return null


func get_current_label() -> String:
	return _current_label


func _print_forecast() -> void:
	print("═══════════════ 天气预报 ═══════════════")
	for kf in _keyframes:
		var wkf: WeatherKeyframe = kf
		var day := int(wkf.abs_hour / 24.0) + 1
		var hour := fmod(wkf.abs_hour, 24.0)
		var ts := "%02d:%02d" % [int(hour), int(fmod(hour * 60.0, 60.0))]
		var s := ""
		if wkf.rain > 0.01: s += " 雨%.0f%%" % (wkf.rain * 100)
		if wkf.fog > 0.01: s += " 雾%.0f%%" % (wkf.fog * 100)
		if wkf.snow > 0.01: s += " 雪%.0f%%" % (wkf.snow * 100)
		s += " 风%.0f%%" % (wkf.wind_strength * 100)
		print("  第%d天 %s  %-16s [%s]" % [day, ts, wkf.label, s.strip_edges()])
	print("═══════════════════════════════════════")
