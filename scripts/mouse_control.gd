class_name MouseControl
extends RefCounted
## 鼠标模式唯一入口。自动运行保留游戏请求状态，但系统鼠标始终可见、自由。
## 标记由统一启动器设置，子引擎继承；手动编辑器运行仍直接使用 Input。

static var _automation := OS.get_environment("RUIN_STAR_AUTOMATION") == "1"
static var _requested_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE

static var mode: Input.MouseMode:
	set(value):
		_requested_mode = value
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _automation else value
	get:
		return _requested_mode if _automation else Input.mouse_mode


static func is_automation() -> bool:
	return _automation
