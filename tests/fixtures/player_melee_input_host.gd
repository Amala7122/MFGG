extends "res://scripts/player.gd"
## 用途：Dummy DisplayServer 不支持鼠标捕获。仅无窗口机制测试替换这个输入前置，
## 仍复用正式 Player、场景、物理和近战全部实现；图形检查绝不使用此替身。
var simulated_capture := true

func _is_aim_captured() -> bool:
	return simulated_capture if DisplayServer.get_name() == "headless" else super._is_aim_captured()
