extends SceneTree
## 合成音的「多变体」层。
##
## 契约：
##   1. `audio.synth_variants` 里配了 N>1 的键，必须装成 AudioStreamRandomizer，
##      `streams_count == N` 且模式是 `PLAYBACK_RANDOM_NO_REPEATS`（不连续重复）。
##   2. 没配（或配 1）的键必须还是单个 AudioStreamWAV，不能被包一层。
##   3. 变体之间必须真的不同（否则等于没做）。
##   4. 合成必须**确定**：两次重建出的同一个变体逐字节相同（避免每次启动音色漂移）。
##   5. 音色不变：变体 0 走的是种子偏移 0 的原有路径（由第 4 条 + 代码保证）。
##
## 只读检查，不播放、不改项目配置。

const AudioManagerScript := preload("res://scripts/audio_manager.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")


func _initialize() -> void:
	var failed := false
	var counts: Dictionary = ConfigUtil.get_dictionary("audio.synth_variants")
	print("[变体] 配置了变体的键：%d 个" % counts.size())

	var started := Time.get_ticks_msec()
	var manager: Node = AudioManagerScript.new()
	manager.call("rebuild_bank")
	var build_ms := Time.get_ticks_msec() - started
	var bank: Dictionary = manager.get("_bank")
	print("[变体] 音色库构建耗时 %d ms，键 %d 个" % [build_ms, bank.size()])

	# 1. 每个兜底键都必须存在且是音频流。
	for raw_key in AudioManagerScript.BANK_FALLBACK.keys():
		var key := String(raw_key)
		if not bank.has(key):
			push_error("[变体] 音色键 %s 缺失。" % key)
			failed = true
		elif not (bank[key] is AudioStream):
			push_error("[变体] 音色键 %s 不是 AudioStream。" % key)
			failed = true

	# 2/3. 按配置校验随机化器与变体内容。
	for raw_key in AudioManagerScript.BANK_FALLBACK.keys():
		var key := String(raw_key)
		if not bank.has(key):
			continue
		var expected := clampi(int(counts.get(key, 1)), 1, AudioManagerScript.MAX_SYNTH_VARIANTS)
		var stream: Variant = bank[key]
		if expected <= 1:
			if not (stream is AudioStreamWAV):
				push_error("[变体] 键 %s 没配变体，却被打包成了 %s。" % [key, (stream as Object).get_class()])
				failed = true
			continue
		if not (stream is AudioStreamRandomizer):
			push_error("[变体] 键 %s 配了 %d 个变体，实际是 %s。"
				% [key, expected, (stream as Object).get_class()])
			failed = true
			continue
		var randomizer := stream as AudioStreamRandomizer
		if randomizer.streams_count != expected:
			push_error("[变体] 键 %s 变体数 %d ≠ 配置 %d。"
				% [key, randomizer.streams_count, expected])
			failed = true
		if randomizer.playback_mode != AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS:
			push_error("[变体] 键 %s 播放模式不是『不连续重复』。" % key)
			failed = true
		# 变体之间必须真的不同。
		var seen: Dictionary = {}
		for index in range(randomizer.streams_count):
			var variant: Variant = randomizer.get_stream(index)
			if not (variant is AudioStreamWAV):
				push_error("[变体] 键 %s 的变体 %d 不是 AudioStreamWAV。" % [key, index])
				failed = true
				continue
			var digest := (variant as AudioStreamWAV).data.slice(0, 512).hex_encode()
			if seen.has(digest):
				push_error("[变体] 键 %s 的变体 %d 与变体 %d 波形相同，变体没生效。"
					% [key, index, int(seen[digest])])
				failed = true
			else:
				seen[digest] = index

	# 4. 确定性：两次重建的变体 0 必须逐字节相同。
	var first := _variant_zero(bank, "shot")
	var again: Node = AudioManagerScript.new()
	again.call("rebuild_bank")
	var second := _variant_zero(again.get("_bank"), "shot")
	again.free()
	if first == null or second == null:
		push_error("[变体] 取不到 shot 的变体 0，无法验证确定性。")
		failed = true
	elif not first.data == second.data:
		push_error("[变体] 两次重建的 shot 变体 0 不同，合成不确定。")
		failed = true

	manager.free()
	if not failed:
		print("[变体] 全部通过：配置生效、变体互不相同、合成确定。")
	quit(1 if failed else 0)


func _variant_zero(bank: Dictionary, key: String) -> AudioStreamWAV:
	if not bank.has(key):
		return null
	var stream: Variant = bank[key]
	if stream is AudioStreamRandomizer:
		var inner: Variant = (stream as AudioStreamRandomizer).get_stream(0)
		return inner as AudioStreamWAV
	return stream as AudioStreamWAV
