extends RefCounted
## 两类电影镜头共用控制权；旧镜头退出不能覆盖新镜头。

static var _active: Camera3D


static func claim(camera: Camera3D) -> void:
	if is_instance_valid(_active) and _active != camera:
		_active.call("restore_and_destroy")
	_active = camera


static func release(camera: Camera3D) -> void:
	if _active == camera:
		_active = null
