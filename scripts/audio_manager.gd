extends Node
## 音频管理（autoload）。
##
## 关键决策：**全部音效由代码合成（AudioStreamWAV），不依赖任何音频文件。**
## 理由：这个项目从第一天就是"零美术资源"的风格（网格是程序化的、特效是代码
## 拼的），引入二进制音频会打破它，也让仓库变重。而枪声 / 命中 / 爆炸本质就是
## "噪声 + 快速衰减 + 频率下坠"，合成出来足够用。
##
## 用法：
##   AudioUtil.play("shot")            非定位（自己的枪声、UI）
##   AudioUtil.play_at("hit", 位置)     3D 定位（命中、爆炸、敌人开火）
##
## autoload 未注册时 instance 为 null，所有调用自动变成空操作，不会崩。

static var instance: Node

const SAMPLE_RATE := 22050
## 非定位声道数。连发时同一个音效会叠很多层，留足余量避免互相打断。
const VOICE_COUNT := 12
## 3D 声道数。
const SPATIAL_VOICE_COUNT := 16

var _bank: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _spatial: Array[AudioStreamPlayer3D] = []
var _next_voice := 0
var _next_spatial := 0
var _spatial_host: Node = null
var _rng := RandomNumberGenerator.new()

# ── juice 侧音频（ruin-star 移植）──
# 侧链闪避（Audio Ducking）：大招/特写时压低细碎枪声
var _duck_timer := 0.0
var _duck_attenuation_db := -9.0
const DUCKABLE_KEYS := ["shot", "enemy_shot", "hit", "hurt", "wisp_shot", "hit_metal", "hit_flesh", "hit_stone"]
# 连杀音调阶梯（Multi-Kill Pitch Escalation）
var _kill_combo := 0
var _last_kill_time := 0.0
# 濒死低通滤波（Low-Pass Filter）
var _lpf_effect: AudioEffectLowPassFilter = null
var _lpf_index := -1
var _low_health_danger := 0.0
var _current_cutoff := 20500.0


func _ready() -> void:
	instance = self
	_rng.randomize()
	_build_bank()
	_setup_low_pass_filter()
	for _index in range(VOICE_COUNT):
		var player := AudioStreamPlayer.new()
		add_child(player)
		_voices.append(player)


func _exit_tree() -> void:
	_stop_spatial_pool()
	for player in _voices:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_voices.clear()
	_bank.clear()
	instance = null


func _stop_spatial_pool() -> void:
	for player in _spatial:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_spatial.clear()
	_spatial_host = null


func _on_spatial_host_exiting(host: Node) -> void:
	if host == _spatial_host:
		_stop_spatial_pool()


# ---------------------------------------------------------------- 静态入口

static func play(key: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if instance:
		instance.call("_play", key, volume_db, pitch)


static func play_at(
	key: String, position: Vector3, volume_db: float = 0.0, pitch: float = 1.0
) -> void:
	if instance:
		instance.call("_play_at", key, position, volume_db, pitch)


# ---------------------------------------------------------------- 音色库

## 音色参数表来自 data/game_config.json 的 audio.bank，数组含义：
##   [时长, 起始频率, 结束频率, 衰减指数, 噪声占比, 增益]
##
## 频率一律从高往低走 —— 这是"打击感"的来源，升调听起来像提示音。
##
## 注意键名清单仍由下面这个常量决定（而不是"JSON 里有什么就合成什么"）：
## 新增音色本来就必须同时改代码（要有地方 play 它），所以让代码掌握清单，
## 配置只负责"参数"。这样 JSON 里多写了键会被忽略，少写了键会自动兜底。
const ConfigUtil := preload("res://scripts/game_config.gd")

## 兜底参数表，与 game_config.json 的 audio.bank 一致。
## 存在的意义只是"配置文件丢了也要有声音"，正常流程一律读 JSON。
const BANK_FALLBACK := {
	"shot": [0.13, 460.0, 95.0, 4.5, 0.55, 0.85],
	"sniper": [0.34, 210.0, 52.0, 3.0, 0.5, 1.0],
	"enemy_shot": [0.15, 320.0, 120.0, 4.0, 0.45, 0.6],
	"hit": [0.08, 900.0, 430.0, 7.0, 0.35, 0.5],
	"headshot": [0.17, 1350.0, 880.0, 5.0, 0.18, 0.62],
	"kill": [0.26, 520.0, 130.0, 4.0, 0.25, 0.7],
	"hurt": [0.24, 170.0, 62.0, 3.5, 0.35, 0.9],
	"pickup": [0.2, 640.0, 1180.0, 3.0, 0.05, 0.42],
	"explosion": [0.55, 150.0, 38.0, 2.6, 0.8, 1.0],
	"shockwave": [0.42, 260.0, 45.0, 2.8, 0.55, 0.95],
	"titan_charge": [0.8, 72.0, 118.0, 0.6, 0.22, 0.45],
	"titan_takeoff": [0.3, 145.0, 42.0, 2.4, 0.65, 0.7],
	"titan_land": [0.65, 92.0, 24.0, 2.5, 0.72, 0.85],
	"titan_sweep": [0.45, 180.0, 38.0, 1.7, 0.70, 0.68],
	"ui": [0.09, 880.0, 1200.0, 4.0, 0.0, 0.35],
	# 低频闷响：低血量时由 LowHealthOverlay 按危险程度加速播放。
	"heartbeat": [0.2, 88.0, 42.0, 3.2, 0.22, 1.0],
	"wisp_shot": [0.12, 1180.0, 360.0, 5.2, 0.12, 0.45],
	"shield_break": [0.32, 1850.0, 160.0, 4.8, 0.55, 1.0],
	"bullet_whiz": [0.16, 1500.0, 310.0, 4.2, 0.42, 0.85],
	"footstep": [0.07, 190.0, 55.0, 7.0, 0.42, 0.38],
	"hit_metal": [0.11, 2100.0, 640.0, 6.2, 0.12, 0.65],
	"hit_flesh": [0.10, 420.0, 95.0, 4.6, 0.68, 0.58],
	"hit_stone": [0.09, 720.0, 180.0, 6.5, 0.72, 0.48],
	"casing_clink": [0.045, 2600.0, 1900.0, 9.0, 0.06, 0.22],
	"whoosh": [0.18, 540.0, 110.0, 3.8, 0.65, 0.75],
}


func _build_bank() -> void:
	var configured := ConfigUtil.get_dictionary("audio.bank")
	for key in BANK_FALLBACK.keys():
		var spec: Variant = configured.get(key, null)
		var stream := _synth_from_spec(spec)
		if stream == null:
			# 键缺失或参数非法：回退到内置参数，保证每个音色一定可用。
			if spec != null:
				push_error("AudioManager: 音色 %s 的参数非法，已用兜底值。" % key)
			stream = _synth_from_spec(BANK_FALLBACK[key])
		_bank[key] = stream


## 把 [时长, 起始频率, 结束频率, 衰减指数, 噪声占比, 增益] 合成成音频流。
## 参数缺失或类型不对时返回 null，由调用方决定怎么兜底。
func _synth_from_spec(spec: Variant) -> AudioStreamWAV:
	if not (spec is Array) or (spec as Array).size() < 6:
		return null
	var values := spec as Array
	for item in values:
		if not (item is float or item is int):
			return null
	return _synth(
		float(values[0]), float(values[1]), float(values[2]),
		float(values[3]), float(values[4]), float(values[5])
	)


## 合成一段单声道 16bit PCM。
func _synth(
	duration: float,
	freq_start: float,
	freq_end: float,
	decay: float,
	noise_mix: float,
	gain: float
) -> AudioStreamWAV:
	var count := int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	# 用参数派生固定种子：同一种音效每次生成的波形一致，避免听感漂移。
	rng.seed = int(freq_start) * 7919 + count
	var phase := 0.0
	for index in range(count):
		var progress := float(index) / float(count)
		var envelope := pow(1.0 - progress, decay)
		var frequency := lerpf(freq_start, freq_end, progress)
		phase += TAU * frequency / SAMPLE_RATE
		var tone := sin(phase)
		var noise := rng.randf_range(-1.0, 1.0)
		var sample := (tone * (1.0 - noise_mix) + noise * noise_mix) * envelope * gain
		data.encode_s16(index * 2, int(clampf(sample, -1.0, 1.0) * 32000.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream


# ---------------------------------------------------------------- 播放

func _play(key: String, volume_db: float, pitch: float) -> void:
	if not _bank.has(key) or _voices.is_empty():
		return
	var player := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	player.stream = _bank[key]
	player.volume_db = _calc_volume(key, volume_db)
	# 加一点随机音高：连发时同一段波形逐发叠加会形成明显的"机关枪嗡声"。
	player.pitch_scale = _calc_pitch(key, pitch) * _rng.randf_range(0.96, 1.05)
	player.play()


func _play_at(key: String, position: Vector3, volume_db: float, pitch: float) -> void:
	if not _bank.has(key):
		return
	var pool := _ensure_spatial_pool()
	if pool.is_empty():
		_play(key, volume_db, pitch)
		return
	var player := pool[_next_spatial]
	_next_spatial = (_next_spatial + 1) % pool.size()
	player.global_position = position
	player.stream = _bank[key]
	player.volume_db = _calc_volume(key, volume_db)
	player.pitch_scale = _calc_pitch(key, pitch) * _rng.randf_range(0.94, 1.07)
	player.play()


## 3D 声道必须挂在真实的 3D 场景里才能正确衰减，而 autoload 的父节点是
## Window（不是 Node3D），所以延迟挂到 current_scene 上。
## 换关卡时旧声道会随场景一起释放，这里检测到就重建。
func _ensure_spatial_pool() -> Array[AudioStreamPlayer3D]:
	var host := get_tree().current_scene
	if host == null:
		return []
	if host == _spatial_host and not _spatial.is_empty() and is_instance_valid(_spatial[0]):
		return _spatial
	_stop_spatial_pool()
	for _index in range(SPATIAL_VOICE_COUNT):
		var player := AudioStreamPlayer3D.new()
		player.max_distance = 70.0
		player.unit_size = 7.0
		host.add_child(player)
		_spatial.append(player)
	_spatial_host = host
	var on_exit := _on_spatial_host_exiting.bind(host)
	if not host.tree_exiting.is_connected(on_exit):
		host.tree_exiting.connect(on_exit, CONNECT_ONE_SHOT)
	return _spatial

# ────────────────── juice 侧音频（ruin-star 移植）──────────────────

func _setup_low_pass_filter() -> void:
	_lpf_effect = AudioEffectLowPassFilter.new()
	_lpf_effect.cutoff_hz = 20500.0
	_lpf_effect.resonance = 0.5
	AudioServer.add_bus_effect(0, _lpf_effect)
	_lpf_index = AudioServer.get_bus_effect_count(0) - 1
	AudioServer.set_bus_effect_enabled(0, _lpf_index, false)


func _process(delta: float) -> void:
	if _duck_timer > 0.0:
		_duck_timer = maxf(_duck_timer - delta, 0.0)
	if _lpf_effect != null and _lpf_index >= 0:
		var target_cutoff := lerpf(20500.0, 480.0, _low_health_danger) if _low_health_danger > 0.001 else 20500.0
		_current_cutoff = lerpf(_current_cutoff, target_cutoff, minf(delta * 7.5, 1.0))
		if _low_health_danger <= 0.001 and _current_cutoff >= 20000.0:
			if AudioServer.is_bus_effect_enabled(0, _lpf_index):
				AudioServer.set_bus_effect_enabled(0, _lpf_index, false)
		else:
			if not AudioServer.is_bus_effect_enabled(0, _lpf_index):
				AudioServer.set_bus_effect_enabled(0, _lpf_index, true)
			_lpf_effect.cutoff_hz = _current_cutoff


## 濒死危险值 0..1：低血量时压低高频。
static func set_low_health_danger(danger: float) -> void:
	if instance:
		instance.set("_low_health_danger", clampf(danger, 0.0, 1.0))


## 触发音频闪避：大招/特写/Boss 终结时压低细碎枪声与杂音。
static func duck(duration: float = 1.2, attenuation_db: float = -9.0) -> void:
	if instance:
		instance.call("_duck", duration, attenuation_db)


func _duck(duration: float, attenuation_db: float) -> void:
	_duck_timer = maxf(_duck_timer, duration)
	_duck_attenuation_db = attenuation_db


func _calc_volume(key: String, volume_db: float) -> float:
	var final_vol := volume_db
	if _duck_timer > 0.0 and key in DUCKABLE_KEYS:
		final_vol += _duck_attenuation_db
	return final_vol


func _calc_pitch(key: String, pitch: float) -> float:
	var final_pitch := pitch
	if key == "kill":
		var now := float(Time.get_ticks_msec()) * 0.001
		if now - _last_kill_time <= 2.2:
			_kill_combo = mini(_kill_combo + 1, 8)
		else:
			_kill_combo = 0
		_last_kill_time = now
		final_pitch *= (1.0 + float(_kill_combo) * 0.08)
	return final_pitch
