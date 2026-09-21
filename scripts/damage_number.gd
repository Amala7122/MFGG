class_name DamageNumber
extends Label3D
## 伤害飘字：命中点上方弹出数字，向上飘并淡出，结束后回收进对象池。
## 纯代码创建，不需要 .tscn 或字体资源（复用引擎默认字体）。
##
## 【池化改造】show_amount() 会把全部状态重置，因此同一实例可反复使用；
## 生命周期结束时交还 ObjectPool 而不是 queue_free()。

const PoolUtil := preload("res://scripts/object_pool.gd")

const POOL_KEY := "damage_number"
const LIFETIME := 0.85

var _elapsed := 0.0
var _rise := Vector3(0.0, 1.7, 0.0)
var _drift := Vector3.ZERO
var _delay := 0.0
var _base_alpha := 1.0
var _active := false


## amount 为伤害数值；emphasis 用于区分普通命中/高伤（同时放大字号）。
func show_amount(amount: float, color: Color, emphasis: float = 1.0) -> void:
	_elapsed = 0.0
	_active = true
	visible = true
	var safe_emphasis := clampf(emphasis, 0.6, 1.8)
	text = "%d" % roundi(maxf(amount, 1.0))
	font_size = roundi(56.0 * safe_emphasis)
	outline_size = roundi(18.0 * safe_emphasis)
	outline_modulate = Color(0.02, 0.02, 0.03, 0.9)
	pixel_size = 0.0032 / safe_emphasis
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	no_depth_test = true
	double_sided = true
	fixed_size = false
	var tint := color
	tint.a = 1.0
	modulate = tint

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_rise = Vector3(rng.randf_range(-0.55, 0.55), 1.75, rng.randf_range(-0.55, 0.55))
	_drift = Vector3(rng.randf_range(-0.4, 0.4), 0.0, rng.randf_range(-0.4, 0.4))
	_delay = rng.randf_range(0.0, 0.1)


func _process(delta: float) -> void:
	if not _active:
		return
	_elapsed += delta
	var span := maxf(LIFETIME - _delay, 0.01)
	var progress := clampf((_elapsed - _delay) / span, 0.0, 1.0)
	if progress >= 1.0:
		_active = false
		PoolUtil.release(POOL_KEY, self)
		return

	position += (_rise + _drift) * delta
	_rise.x = move_toward(_rise.x, 0.0, 2.2 * delta)
	_rise.y = move_toward(_rise.y, 0.3, 3.4 * delta)
	_rise.z = move_toward(_rise.z, 0.0, 2.2 * delta)

	var alpha := _base_alpha * (1.0 - progress * progress)
	var tint := modulate
	tint.a = alpha
	modulate = tint
	var outline := outline_modulate
	outline.a = 0.9 * alpha
	outline_modulate = outline
