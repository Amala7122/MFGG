extends RefCounted
## Boss 的局部动作暂停：保留选招、锁向、进度；空中不计时，安全阶段才兑现。
var remaining := 0.0
var pending := 0.0
var _paused_tween: Tween

func request(seconds: float, defer_until_safe: bool, action: Tween = null) -> void:
	if defer_until_safe:
		pending = maxf(pending, seconds)
	else:
		remaining = maxf(remaining, seconds)
		_pause(action)

func step(delta: float, safe: bool, action: Tween = null) -> bool:
	if not safe:
		return false
	if pending > 0.0:
		request(pending, false, action)
		pending = 0.0
	if remaining <= 0.0:
		return false
	_pause(action)
	remaining = maxf(remaining - delta, 0.0)
	if remaining <= 0.0 and _paused_tween != null and _paused_tween.is_valid():
		_paused_tween.play()
		_paused_tween = null
	return true

func _pause(action: Tween) -> void:
	if action != null and action.is_valid() and action.is_running():
		action.pause()
		_paused_tween = action
