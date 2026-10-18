extends SceneTree
## 合成音实时调音器（诊断工具，不是正式实现）。
##
## 按游戏射速循环播放 `audio.bank` 里某个键的合成音，键盘即时微调 6 个参数并立刻听到。
## 判定标准是你的耳朵——这个工具不提供任何"更好/更差"的结论。
##
## 运行（需要窗口 + 音频，**不要加 --headless**）：
##   Godot_v4.7.2-stable_win64.exe --path . --script res://tools/probes/audio_synth_tuner.gd
## 想留日志：再加  --log-file <路径>
## 换一个键：  -- --key=sniper
## 自检（无交互，构建后打印并退出，给自动检查用）：
##   ... --script res://tools/probes/audio_synth_tuner.gd -- --selftest
##
## 按键：
##   1..6    选择参数：时长 / 起始频率 / 结束频率 / 衰减指数 / 噪声占比 / 增益
##   ← →     微调选中参数（按住 H 是粗调 ×10）
##   Tab     7 发/秒 ↔ 10.5 发/秒（游戏射速基础 / 满级）
##   V       变体数 1 → 2 → 3 → 4 → 6 循环
##   Space   暂停 / 继续连发
##   R       恢复成 data/game_config.json 里的当前值
##   S       把当前参数打印成可直接粘贴进 audio.bank 的一行
##   Q       退出
##
## 这个工具**不写项目文件**：调好的数值按 S 打印出来，由你决定是否写进
## [game_config.json](../../data/game_config.json) 的 audio.bank。

const AudioManagerScript := preload("res://scripts/audio_manager.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

const PARAM_NAMES := ["时长(s)", "起始频率(Hz)", "结束频率(Hz)", "衰减指数", "噪声占比", "增益"]
const STEPS := [0.01, 10.0, 10.0, 0.2, 0.02, 0.02]
const LIMITS := [
	[0.02, 1.0], [40.0, 4000.0], [30.0, 4000.0], [0.2, 12.0], [0.0, 1.0], [0.05, 1.5],
]
const VARIANT_CHOICES := [1, 2, 3, 4, 6]

var _manager: Node
var _player: AudioStreamPlayer
var _label: Label
var _key := "shot"
var _values: Array[float] = []
var _initial: Array[float] = []
var _variant_choice := 3  # 索引到 VARIANT_CHOICES → 4 个变体
var _shots_per_second := 7.0
var _accum_ms := 0.0
var _last_ms := 0
var _playing := true
var _selected := 0
var _quit := false
var _prev_keys: Dictionary = {}
var _dirty := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var selftest := false
	for arg in args:
		if arg == "--selftest":
			selftest = true
		elif arg.begins_with("--key="):
			_key = arg.substr(6)

	_manager = AudioManagerScript.new()
	if not _load_values():
		quit(1)
		return

	if selftest:
		_run_selftest()
		return

	_build_ui()
	_rebuild()
	_last_ms = Time.get_ticks_msec()
	print("[调音器] 键=%s  射速=%.1f/s  变体=%d  参数=%s" % [
		_key, _shots_per_second, _current_variants(), _values_text()])

	while not _quit:
		await process_frame
		_tick()


# ---------------------------------------------------------------- 参数

func _load_values() -> bool:
	var table: Dictionary = ConfigUtil.get_dictionary("audio.bank")
	var spec: Variant = table.get(_key, null)
	if not AudioManagerScript._valid_spec(spec):
		if _key in AudioManagerScript.BANK_FALLBACK:
			spec = AudioManagerScript.BANK_FALLBACK[_key]
			push_warning("[调音器] 配置里取不到 %s 的合法参数，改用兜底值。" % _key)
		else:
			push_error("[调音器] 未知音色键：%s" % _key)
			return false
	_values.clear()
	for item in spec as Array:
		_values.append(float(item))
	_initial = _values.duplicate()
	return true


func _current_variants() -> int:
	return int(VARIANT_CHOICES[_variant_choice])


func _values_text() -> String:
	var parts: Array[String] = []
	for index in range(_values.size()):
		parts.append("%.3f" % _values[index])
	return "[" + ", ".join(PackedStringArray(parts)) + "]"


# ---------------------------------------------------------------- 音源构建与播放

func _rebuild() -> void:
	var stream: AudioStream = _manager.call(
		"_build_synth_stream", _values, _current_variants()
	)
	_player.stream = stream
	_dirty = true
	var kind := "随机 %d 变体" % _current_variants()
	if stream is AudioStreamWAV:
		kind = "单波形"
	print("[调音器] 重建 %s：%s  %s" % [_key, kind, _values_text()])
	_refresh_label()


func _play_shot() -> void:
	if _player.stream == null:
		return
	_player.play()


func _tick() -> void:
	_handle_keys()
	var now := Time.get_ticks_msec()
	var elapsed := float(now - _last_ms)
	_last_ms = now
	if not _playing:
		return
	_accum_ms += elapsed
	var interval := 1000.0 / _shots_per_second
	# 一帧内可能要补多发，但最多补 4 发，避免卡顿后一次性炸出一串。
	var guard := 0
	while _accum_ms >= interval and guard < 4:
		_accum_ms -= interval
		_play_shot()
		guard += 1
	if _accum_ms > interval * 4.0:
		_accum_ms = 0.0


# ---------------------------------------------------------------- 输入

func _just(keycode: Key) -> bool:
	var down := Input.is_key_pressed(keycode)
	var was := bool(_prev_keys.get(keycode, false))
	_prev_keys[keycode] = down
	return down and not was


func _handle_keys() -> void:
	for index in range(6):
		if _just(KEY_1 + index):
			_selected = index
			_refresh_label()
			print("[调音器] 选中参数 %d %s" % [_selected + 1, PARAM_NAMES[_selected]])
			return
	var coarse := Input.is_key_pressed(KEY_H)
	var direction := 0
	if _just(KEY_LEFT):
		direction = -1
	if _just(KEY_RIGHT):
		direction = 1
	if direction != 0:
		_adjust(direction, coarse)
	if _just(KEY_TAB):
		_shots_per_second = 10.5 if is_equal_approx(_shots_per_second, 7.0) else 7.0
		print("[调音器] 射速 = %.1f 发/秒" % _shots_per_second)
		_refresh_label()
	if _just(KEY_V):
		_variant_choice = (_variant_choice + 1) % VARIANT_CHOICES.size()
		_rebuild()
	if _just(KEY_SPACE):
		_playing = not _playing
		print("[调音器] %s" % ("继续" if _playing else "暂停"))
		_refresh_label()
	if _just(KEY_R):
		_values = _initial.duplicate()
		_rebuild()
	if _just(KEY_S):
		print("[调音器] 可直接粘贴进 audio.bank：")
		print("\t\"%s\": %s," % [_key, _values_text()])
		_dirty = false
		_refresh_label()
	if _just(KEY_Q):
		_quit = true
		quit(0)


func _adjust(direction: int, coarse: bool) -> void:
	var step := float(STEPS[_selected]) * (10.0 if coarse else 1.0)
	var limits: Array = LIMITS[_selected]
	_values[_selected] = clampf(
		_values[_selected] + step * float(direction), float(limits[0]), float(limits[1])
	)
	_rebuild()


# ---------------------------------------------------------------- 界面与自检

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	_label = Label.new()
	_label.position = Vector2(24, 24)
	_label.add_theme_font_size_override("font_size", 15)
	layer.add_child(_label)
	_player = AudioStreamPlayer.new()
	root.add_child(_player)


func _refresh_label() -> void:
	if _label == null:
		return
	var lines: Array[String] = []
	lines.append("合成音调音器   键 = %s" % _key)
	lines.append("射速 %.1f 发/秒（Tab 切换）   变体 %d（V 切换）   %s"
		% [_shots_per_second, _current_variants(), "播放中" if _playing else "已暂停"])
	lines.append("")
	for index in range(PARAM_NAMES.size()):
		var marker := "▶" if index == _selected else "  "
		lines.append("%s %d. %-14s %8.3f" % [marker, index + 1, PARAM_NAMES[index], _values[index]])
	lines.append("")
	lines.append("1-6 选参数   ← → 微调   按住 H 粗调   R 复原   S 打印可粘贴行   Q 退出")
	lines.append("未保存：调好按 S 打印，再决定是否写进 game_config.json")
	_label.text = "\n".join(PackedStringArray(lines))


## 自检：构建当前键的音源并打印结构，供自动检查调用。
func _run_selftest() -> void:
	var stream: AudioStream = _manager.call("_build_synth_stream", _values, _current_variants())
	var detail := ""
	if stream is AudioStreamRandomizer:
		var randomizer := stream as AudioStreamRandomizer
		detail = "variants=%d mode=%d" % [randomizer.streams_count, randomizer.playback_mode]
	elif stream is AudioStreamWAV:
		detail = "bytes=%d loop=%d" % [(stream as AudioStreamWAV).data.size(),
			(stream as AudioStreamWAV).loop_mode]
	print("[调音器-自检] key=%s class=%s %s params=%s"
		% [_key, stream.get_class(), detail, _values_text()])
	var ok := stream != null and (stream is AudioStreamWAV or stream is AudioStreamRandomizer)
	_manager.free()
	quit(0 if ok else 1)
