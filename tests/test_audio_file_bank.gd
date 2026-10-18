extends SceneTree
## 音色库的文件音源层（Ovani Sound 音效库）。
##
## 两种环境都要能判 PASS：
##   - **开发机**（音效库在项目里）：配置点名的键必须真的换成音频文件，流可加载、时长非零。
##   - **干净检出**（音效库被 .gitignore 排除，见 I-035）：这些键必须静默回退到合成音色，
##     键一个不少、不崩、不报错。
##
## 只读检查：不播放、不改项目配置。运行方式与其它 tests/ 脚本一致：
##   godot --headless --script res://tests/test_audio_file_bank.gd

const AudioManagerScript := preload("res://scripts/audio_manager.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

const PACK_ROOT := "res://addons/Sound FX Starter Pack Vol. 1/"
const PROBE_FILE := PACK_ROOT + "Hollywood/Titan Handgun.wav"
const PROBE_LOOP := PACK_ROOT + "Environment/Wind Loop.wav"


func _initialize() -> void:
	var failed := false
	var table: Dictionary = ConfigUtil.get_dictionary("audio.file_bank")
	var enabled: bool = ConfigUtil.get_bool("audio.file_bank_enabled", true)
	print("[音效] file_bank_enabled=%s，配置条目 %d 个" % [enabled, table.size()])

	var manager: Node = AudioManagerScript.new()
	manager.call("rebuild_bank")
	var bank: Dictionary = manager.get("_bank")
	var file_keys: Array = manager.get("_file_keys")

	# 1. 配置里点名的键必须都在音色库里，且总数不能少于兜底表。
	for raw_key in table.keys():
		if not bank.has(String(raw_key)):
			push_error("[音效] 键 %s 在音色库里不存在。" % String(raw_key))
			failed = true
	if bank.size() < AudioManagerScript.BANK_FALLBACK.size():
		push_error("[音效] 音色库只有 %d 个键，少于兜底表的 %d 个。"
			% [bank.size(), AudioManagerScript.BANK_FALLBACK.size()])
		failed = true

	# 2. mortar 必须在：mortar_shell.gd 在播它，而它曾漏在键清单外（I-033）。
	if not bank.has("mortar"):
		push_error("[音效] 键 mortar 缺失，迫击炮落地仍然没有声音（I-033）。")
		failed = true

	# 3. 按环境分别判定。
	#    表为空 / 开关关闭都表示「全部走合成音色」，这是合法状态（枪声已撤销文件音源），
	#    此时必须一个文件键都没有、且键一个不少。
	var pack_present := ResourceLoader.exists(PROBE_FILE)
	if table.is_empty() or not enabled:
		var reason := "file_bank 为空" if table.is_empty() else "file_bank_enabled=false"
		if _check_pure_synth(bank, file_keys, reason):
			failed = true
	elif not pack_present:
		if _check_pure_synth(bank, file_keys, "音效库不在项目里"):
			failed = true
	else:
		if _check_wired(table, bank, file_keys):
			failed = true
		if _check_fallback(bank, file_keys):
			failed = true
		if _check_loop(manager):
			failed = true

	manager.free()
	quit(1 if failed else 0)


## 音效库在场：点名过的键必须真的走文件，且能加载出非零时长的音频流。
func _check_wired(table: Dictionary, bank: Dictionary, file_keys: Array) -> bool:
	var failed := false
	for raw_key in table.keys():
		var key := String(raw_key)
		if not file_keys.has(key):
			push_error("[音效] 音效库在场，但键 %s 没有换成文件音源。" % key)
			failed = true
			continue
		var stream: Variant = bank[key]
		if not (stream is AudioStream):
			push_error("[音效] 键 %s 的音源不是 AudioStream。" % key)
			failed = true
			continue
		var length: float = (stream as AudioStream).get_length()
		if length <= 0.0:
			push_error("[音效] 键 %s 的音频流时长为 0，文件可能没导入成功。" % key)
			failed = true
	if not failed:
		print("[音效] %d 个键已换成真实音频文件。" % file_keys.size())
	return failed


## 没点名文件音源的键必须继续保留合成音色，接文件层不能让任何音效变成哑巴。
func _check_fallback(bank: Dictionary, file_keys: Array) -> bool:
	var failed := false
	for raw_key in AudioManagerScript.BANK_FALLBACK.keys():
		if not bank.has(String(raw_key)):
			push_error("[音效] 未配文件音源的键 %s 丢失。" % String(raw_key))
			failed = true
	for raw_key in file_keys:
		if not bank.has(String(raw_key)):
			push_error("[音效] 文件键 %s 不在音色库里。" % String(raw_key))
			failed = true
	if not failed:
		print("[音效] 未配文件音源的 %d 个键全部保留合成音色。"
			% (AudioManagerScript.BANK_FALLBACK.size() - file_keys.size()))
	return failed


## 应当全部走合成音色的状态（表为空 / 开关关闭 / 干净检出错没有音效库）：
## 必须一个文件键都没有，且音色键一个不少。
func _check_pure_synth(bank: Dictionary, file_keys: Array, reason: String) -> bool:
	var failed := false
	if not file_keys.is_empty():
		push_error("[音效] %s，却仍有 %d 个键走了文件音源。" % [reason, file_keys.size()])
		failed = true
	for raw_key in AudioManagerScript.BANK_FALLBACK.keys():
		if not bank.has(String(raw_key)):
			push_error("[音效] %s，键 %s 丢失，回退不完整。" % [reason, String(raw_key)])
			failed = true
	if not failed:
		print("[音效] %s：%d 个键全部走合成音色。" % [reason, bank.size()])
	return failed


## 名字带 Loop 的文件导入后是 LOOP_DISABLED（I-032）；
## 配置写 "loop": true 时必须在运行时真的打开循环。
func _check_loop(manager: Node) -> bool:
	if not ResourceLoader.exists(PROBE_LOOP):
		print("[音效] 找不到循环素材，跳过循环检查")
		return false
	var loaded: Variant = load(PROBE_LOOP)
	if not (loaded is AudioStreamWAV):
		push_error("[音效] %s 不是 AudioStreamWAV，无法验证循环开关。" % PROBE_LOOP)
		return true
	var wav := loaded as AudioStreamWAV
	if wav.loop_mode != AudioStreamWAV.LOOP_DISABLED:
		push_error("[音效] 未开循环前 loop_mode 已是 %d，请先核对导入设置。" % wav.loop_mode)
		return true
	manager.call("_enable_loop", wav)
	if wav.loop_mode != AudioStreamWAV.LOOP_FORWARD:
		push_error("[音效] 开启循环后 loop_mode 仍为 %d。" % wav.loop_mode)
		return true
	if wav.loop_end <= 0:
		push_error("[音效] 循环终点 loop_end=%d，会退化成不循环。" % wav.loop_end)
		return true
	print("[音效] 循环开关可用：%.1f 秒，loop_end=%d 帧" % [wav.get_length(), wav.loop_end])
	return false
