extends "res://scripts/player.gd"
## 正式玩家的实验场适配：死亡交给测试场，不提交战绩或打开正式结算。

signal defeated

const Telemetry := preload("res://scripts/combat_telemetry.gd")


func _input(event: InputEvent) -> void:
	var lab := get_tree().current_scene
	# 键盘快捷键在玩家和界面入口都可达，由 viewport 防止重复处理。
	if event is InputEventKey and (event.physical_keycode in [KEY_ESCAPE, KEY_TAB] or event.keycode in [KEY_ESCAPE, KEY_TAB]):
		lab.call("handle_lab_input", event)
		return
	# 正式 GameFlow 在实验场保持 PLAYING；配置面板期间不能借此重新锁鼠标。
	if not bool(lab.call("accepts_player_input")):
		return
	super._input(event)


func take_damage(amount: float, source_position: Vector3 = Vector3.ZERO, shield_damage_scale: float = 1.0) -> void:
	var before_health := health
	var before_shield := shield
	var blocked := ""
	if bool(get_meta(&"experiment_invincible", false)):
		blocked = "无敌"
	elif _damage_invulnerability > 0.0 or health <= 0.0:
		blocked = "免伤窗口" if health > 0.0 else "已倒下"
	super.take_damage(amount, source_position, shield_damage_scale)
	var stats := Telemetry.recorder(self)
	if stats:
		stats.call("player_damaged", get_meta(Telemetry.CONTEXT, {}), maxf(amount, 0.0),
			maxf(before_health - health, 0.0), maxf(before_shield - shield, 0.0),
			before_shield > 0.0 and shield <= 0.0, blocked)
		stats.call("capture_player", self)
		if health <= 0.0:
			stats.call("stop", "玩家倒下")


func _regenerate(delta: float) -> void:
	var before_health := health
	var before_shield := shield
	super._regenerate(delta)
	Telemetry.resource(self, "player", "health_regen", maxf(health - before_health, 0.0))
	Telemetry.resource(self, "player", "shield_regen", maxf(shield - before_shield, 0.0))


func try_heal(amount: float) -> bool:
	var before := health
	var applied := super.try_heal(amount)
	Telemetry.resource(self, "player", "heal", maxf(health - before, 0.0))
	return applied


func _finish_death() -> void:
	if _death_event_sent:
		return
	_death_event_sent = true
	set_physics_process(false)
	defeated.emit()
