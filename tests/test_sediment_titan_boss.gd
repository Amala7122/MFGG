extends SceneTree
## 圣所四波后的正式 Boss 必须生成放大沉积泰坦，而不是旧占位 Boss。

const Config := preload("res://scripts/game_config.gd")
const SpawnerScript := preload("res://scripts/enemy_spawner.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")

var _failures := 0
var _died := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var sanctum := Config.get_dictionary("arenas.definitions.sanctum.wave")
	_check(String(sanctum.get("boss_id", "")) == "sediment_titan", "圣所四波后指定沉积泰坦")
	var boss_cfg := Config.get_dictionary("bosses.sediment_titan")
	_check(String(boss_cfg.get("preset", "")) == "圣所关底 Boss", "正式 Boss 使用独立命名方案")
	_check(bool(boss_cfg.get("flat_spawn", false)), "大型平底 Boss 出生时检查完整脚印的平整度")
	_check(float(boss_cfg.get("min_player_distance", 0.0)) == 26.0
		and float(boss_cfg.get("max_player_distance", 0.0)) == 34.0,
		"正式 Boss 使用独立的远距离投放区间")
	var preset := Tuning.preset_values("PrototypeSedimentTitan", "圣所关底 Boss")
	_check(is_equal_approx(float(preset.get("body_size", 0.0)), 1.65), "正式泰坦体型放大到 1.65 倍")
	_check(float(preset.get("max_health", 0.0)) == 360000.0, "正式泰坦按满配输出使用 36 万生命基线")
	_check(is_equal_approx(float(preset.get("move_speed", 0.0)), 3.6)
		and is_equal_approx(float(preset.get("turn_speed", 0.0)), 3.6), "正式 Boss 普通追击与转向速度独立提高")
	_check(bool(preset.get("leap_enabled", false)) and float(preset.get("slam_break_power", 0.0)) >= 1.0,
		"正式 Boss 方案显式保留接近跃击与破障")
	_check(bool(preset.get("opening_leap", false)) and float(preset.get("leap_damage", 0.0)) == 95.0,
		"正式 Boss 出土后固定以高威胁跃击开场")
	_check(is_equal_approx(float(preset.get("leap_arc_height", 0.0)), 3.0),
		"正式 Boss 的跃击弧高独立于飞行时间，按体型放大后清晰离地")
	_check(float(preset.get("sweep_angle", 0.0)) == 360.0
		and float(preset.get("sweep_damage", 0.0)) == 60.0,
		"正式 Boss 横扫覆盖完整一圈并能消耗大部分基础护盾")
	_check(not bool(preset.get("variation_enabled", true)) and not bool(preset.get("crowd_enabled", true)),
		"正式 Boss 关闭随机体型与普通群体行为")

	var scene := Node3D.new()
	scene.name = "SedimentTitanBossTest"
	root.add_child(scene)
	current_scene = scene
	var floor := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(80.0, 1.0, 80.0)
	floor_shape.shape = floor_box
	floor.position.y = -0.5
	floor.add_child(floor_shape)
	scene.add_child(floor)
	var enemies := Node3D.new()
	enemies.name = "Enemies"
	scene.add_child(enemies)
	var spawner := Node.new()
	spawner.name = "EnemySpawner"
	spawner.set_script(SpawnerScript)
	enemies.add_child(spawner)
	await process_frame

	var boss := spawner.call("spawn_boss", "sediment_titan", Vector3(4.0, 0.0, 5.0)) as Node3D
	await process_frame
	await process_frame
	_check(is_instance_valid(boss), "生成器创建正式沉积泰坦")
	if is_instance_valid(boss):
		_check(boss is ProceduralSedimentTitan, "正式 Boss 复用沉积泰坦实现而非旧胶囊占位符")
		_check(boss.is_in_group("boss") and boss.is_in_group("enemies"), "正式 Boss 同时进入 Boss 与敌人契约组")
		_check(bool(boss.get_meta(&"formal_boss", false)), "正式 Boss 模式在入树前注入")
		_check(is_equal_approx(boss.scale.x, 1.65), "模型、碰撞和招式范围共用体型倍率")
		_check(float(boss.call("get_max_health")) == 360000.0, "Boss 血量来自正式命名方案")
		_check(String(boss.call("get_title")) == "沉积泰坦", "Boss 血条标题正确")
		_check(not (boss.get_node("HealthLabel") as Label3D).visible, "正式 Boss 隐藏原型头顶血字")
		_check(is_equal_approx(float(boss.call("get_stand_height")), 2.805), "放大后的碰撞体按实际半高计算站立高度")
		_check(boss.position.y >= 2.75, "生成器按放大后的站立高度摆放 Boss")
		_check(boss._steering.spatial.ability(&"jump") != null and boss._steering.spatial.ability(&"break") != null,
			"正式 Boss 实例装载步行、跳跃与破障空间能力")
		_check(boss._steering.spatial._bindings.has("break_action"), "正式 Boss 用自身砸地执行空间破障")
		boss.connect("died", _on_boss_died)
		boss.call("take_damage", 1000000.0)
		await process_frame
		_check(_died, "沉积泰坦死亡发出波次结算所需信号")
		_check(not is_instance_valid(boss), "死亡演出交接后 Boss 实体退出")
		_check(not get_nodes_in_group("sediment_titan_core").is_empty(), "死亡核心保留供击杀镜头取景")
		for core: Node in get_nodes_in_group("sediment_titan_core"):
			_check(core.is_in_group("enemy_death_effect"), "核心旋转死亡演出也参与结算等待")

	current_scene = null
	scene.queue_free()
	await process_frame
	print("[沉积泰坦正式 Boss] failures=", _failures)
	quit(1 if _failures else 0)


func _on_boss_died(_enemy: Node3D) -> void:
	_died = true


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
