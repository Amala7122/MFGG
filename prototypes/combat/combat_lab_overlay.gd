extends CanvasLayer
## 暂停配置时仍接收快捷键，世界与玩家保持暂停。


func _input(event: InputEvent) -> void:
	get_parent().handle_lab_input(event)
