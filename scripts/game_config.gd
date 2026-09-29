extends Node
## 全局数值配置（autoload「GameConfig」）。
##
## 【项目约定】新增玩法要素时，凡是可以做成数值 / 开关 / 掉落权重的部分，
## 一律放进 data/game_config.json，不要写死在代码里。代码只保留：
##   - 结构性逻辑（"先扣护盾再扣生命"这种规则本身）
##   - 调用点附近的兜底默认值
## 这样调平衡、改数值、开关功能都不需要碰代码。
##
## 设计原则
## ────────
##   1. **data/game_config.json 是唯一的编辑入口**，代码只读不写。
##   2. **兜底默认值放在调用点**，不在这里再维护一份完整的默认字典 ——
##      那样就有两份需要同步的真相。这里只提供类型化访问器，像
##      `ConfigUtil.get_float("weapon.sniper_base_damage", 60.0)`，
##      默认值就写在参数里（与 save_manager.gd 的 ConfigFile.get_value 同一思路）。
##   3. **配置坏了绝不能让游戏打不开**。文件缺失 / JSON 非法 / 键不存在 /
##      类型不对，一律回退到兜底值并给出明确报错；最坏情况就是"回到改动前"。
##
## 用法（沿用本项目一贯的 preload + 静态入口）
## ────────────────────────────────────────
##     const ConfigUtil := preload("res://scripts/game_config.gd")
##     var base := ConfigUtil.get_float("weapon.sniper_base_damage", 60.0)
##
## 性能提示
## ────────
## 点号查找每次都会 split 字符串并走一遍字典，**不要放在每帧路径上**。
## 需要频繁读取的值请在 _ready()/setup() 里读进成员变量缓存一次。
##
## 程序化敌人的独立调参入口：data/enemies/*.json，数值由 enemy_tuning.gd 读取；
## 测试面板的命名方案保存在 data/enemy_presets，导出版本使用 user://enemy_presets。
## 这两类敌人不在本文件重复维护默认值，技能时间和范围也统一来自独立配置。

const CONFIG_PATH := "res://data/game_config.json"

## autoload 实例。未注册时 _data 恒为空，所有访问器返回兜底值。
static var instance: Node
static var _data: Dictionary = {}
## 是否已尝试加载（无论成功失败）。用于"只报一次错"，避免逐帧刷屏。
static var _load_attempted := false


func _ready() -> void:
	instance = self
	load_config()


## 重新读取配置文件。改完 JSON 想立刻生效（不重开场景）时可以手动调。
func load_config() -> void:
	_load_attempted = true
	_data = _read_config_file()
	if _data.is_empty():
		return
	var version: Variant = _data.get("version", 0)
	print("[配置] 已加载 %s（version=%s）" % [CONFIG_PATH, version])


static func _read_config_file() -> Dictionary:
	if not FileAccess.file_exists(CONFIG_PATH):
		push_error("GameConfig: 找不到 %s，全部数值将使用代码内的兜底默认值。" % CONFIG_PATH)
		return {}
	var file := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		push_error("GameConfig: 无法打开 %s（错误码 %d），改用兜底默认值。"
			% [CONFIG_PATH, FileAccess.get_open_error()])
		return {}
	var text := file.get_as_text()
	file.close()
	# JSON.parse_string 返回 Variant，必须显式标注类型（本项目把类型推断警告当错误）。
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("GameConfig: %s 不是合法的 JSON 对象（解析结果 %s），改用兜底默认值。"
			% [CONFIG_PATH, type_string(typeof(parsed))])
		return {}
	return parsed as Dictionary


# ---------------------------------------------------------------- 点号查找

## 按点号路径取值，任一段缺失即返回 null。
static func _lookup(path: String) -> Variant:
	if _data.is_empty():
		if not _load_attempted:
			# 调用方在 GameConfig 的 _ready() 之前就来读了（例如其它 autoload 的 _ready）。
			# 这里补一次加载，让"先注册的 autoload 读配置"也能拿到真值。
			_data = _read_config_file()
		if _data.is_empty():
			return null
	var cursor: Variant = _data
	for part in path.split("."):
		if not (cursor is Dictionary):
			return null
		var dict := cursor as Dictionary
		if not dict.has(part):
			return null
		cursor = dict[part]
	return cursor


static func _warn_type(path: String, expected: String, got: Variant) -> void:
	push_error("GameConfig: %s 期望 %s，实际是 %s，已改用兜底值。"
		% [path, expected, type_string(typeof(got))])


# ---------------------------------------------------------------- 访问器

static func get_float(path: String, fallback: float) -> float:
	var value: Variant = _lookup(path)
	if value == null:
		return fallback
	if value is float or value is int:
		return float(value)
	_warn_type(path, "number", value)
	return fallback


static func get_int(path: String, fallback: int) -> int:
	var value: Variant = _lookup(path)
	if value == null:
		return fallback
	if value is float or value is int:
		return int(value)
	_warn_type(path, "number", value)
	return fallback


static func get_string(path: String, fallback: String) -> String:
	var value: Variant = _lookup(path)
	if value == null:
		return fallback
	if value is String:
		return value
	_warn_type(path, "string", value)
	return fallback


static func get_bool(path: String, fallback: bool) -> bool:
	var value: Variant = _lookup(path)
	if value == null:
		return fallback
	if value is bool:
		return value
	# 也接受 0/1：JSON 里写成数字是很自然的笔误，不必因此整项作废。
	if value is float or value is int:
		return float(value) != 0.0
	_warn_type(path, "boolean", value)
	return fallback


static func get_dictionary(path: String) -> Dictionary:
	var value: Variant = _lookup(path)
	if value is Dictionary:
		return value as Dictionary
	return {}


## 取数字数组。数组里出现非数字元素时整项作废（回退），避免"部分生效"这种难查状态。
static func get_float_array(path: String, fallback: Array) -> Array:
	var value: Variant = _lookup(path)
	if not (value is Array):
		if value != null:
			_warn_type(path, "array", value)
		return fallback
	var source := value as Array
	var out: Array = []
	for item in source:
		if not (item is float or item is int):
			_warn_type(path, "array of numbers", item)
			return fallback
		out.append(float(item))
	if out.is_empty():
		return fallback
	return out


static func get_int_array(path: String, fallback: Array) -> Array:
	var value: Variant = _lookup(path)
	if not (value is Array):
		if value != null:
			_warn_type(path, "array", value)
		return fallback
	var source := value as Array
	var out: Array = []
	for item in source:
		if not (item is float or item is int):
			_warn_type(path, "array of numbers", item)
			return fallback
		out.append(int(item))
	if out.is_empty():
		return fallback
	return out


static func get_string_array(path: String, fallback: Array) -> Array:
	var value: Variant = _lookup(path)
	if not (value is Array):
		if value != null:
			_warn_type(path, "array", value)
		return fallback
	var source := value as Array
	var out: Array = []
	for item in source:
		if not (item is String):
			_warn_type(path, "array of strings", item)
			return fallback
		out.append(item)
	if out.is_empty():
		return fallback
	return out


## 配置是否真的从文件加载成功。探针与调试用。
static func is_loaded() -> bool:
	return not _data.is_empty()
