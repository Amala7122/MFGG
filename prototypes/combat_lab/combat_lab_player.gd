extends "res://scripts/player.gd"
## 正式玩家的实验场适配：死亡交给测试场，不提交战绩或打开正式结算。

signal defeated

const Telemetry := preload("res://scripts/combat_telemetry.gd")
var _probe_active := false
var _probe_shield := 0.0
var _probe_max_shield := 0.0
var _probe_regen_timer := 0.0


func _sync_damage_probe() -> void:
	var enabled := bool(get_meta(&"experiment_invincible", false))
	if enabled and not _probe_active:
		_probe_shield = shield
		_probe_regen_timer = _shield_regen_timer
	elif enabled and not is_equal_approx(max_shield, _probe_max_shield):
		_probe_shield = clampf(_probe_shield + max_shield - _probe_max_shield, 0.0, max_shield)
	_probe_max_shield = max_shield
	_probe_active = enabled


func get_pressure_shield() -> float:
	_sync_damage_probe()
	return _probe_shield


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
	var stats := Telemetry.recorder(self)
	_sync_damage_probe()
	if _damage_invulnerability > 0.0 or health <= 0.0:
		blocked = "免伤窗口" if health > 0.0 else "已倒下"
	elif _probe_active:
		blocked = "无敌"
	super.take_damage(amount, source_position, shield_damage_scale)
	var hp := maxf(before_health - health, 0.0)
	var sp := maxf(before_shield - shield, 0.0)
	var broken := before_shield > 0.0 and shield <= 0.0
	var simulated := blocked == "无敌" and amount > 0.0 and (stats == null or bool(stats.call("accepting")))
	if simulated:
		# 无敌保留真实血盾；独立护盾池按正式倍率、溢出和恢复规则测量承压。
		# 破盾后的生命伤害持续累计，不因模拟死亡而中断长时间压力测试。
		var scale := clampf(shield_damage_scale, 0.01, 10.0)
		var absorbed := minf(_probe_shield / scale, amount)
		sp = absorbed * scale
		hp = amount - absorbed
		broken = _probe_shield > 0.0 and _probe_shield - sp <= 0.0
		_probe_shield = maxf(_probe_shield - sp, 0.0)
		_probe_regen_timer = _shield_regen_delay
		_damage_invulnerability = hit_invulnerability
	if stats:
		stats.call("player_damaged", get_meta(Telemetry.CONTEXT, {}), maxf(amount, 0.0),
			hp, sp, broken, blocked, simulated)
		stats.call("capture_player", self)
		if health <= 0.0:
			stats.call("stop", "玩家倒下")


func _regenerate(delta: float) -> void:
	_sync_damage_probe()
	if _probe_active:
		var before_probe := _probe_shield
		_probe_regen_timer = maxf(_probe_regen_timer - delta, 0.0)
		if _probe_regen_timer <= 0.0:
			_probe_shield = minf(_probe_shield + _shield_regen_rate * delta, max_shield)
		Telemetry.resource(self, "player", "shield_regen_simulated", _probe_shield - before_probe)
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
