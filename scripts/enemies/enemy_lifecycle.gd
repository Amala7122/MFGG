extends Node
## 战斗宿主的公共附属流程；实验室不安装此节点，也不产生正式掉落。
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Targeting := preload("res://scripts/targeting.gd")
const Pickup := preload("res://scripts/pickup.gd")
const PickupScene := preload("res://scenes/pickup.tscn")
const Wave := preload("res://scripts/wave_director.gd")
const Terrain := preload("res://scripts/terrain_field.gd")
const FX := preload("res://scripts/combat_fx.gd")

var spawn_position := Vector3.ZERO
var settings: Dictionary = {}
var _elapsed := 0.0


static func credit_player(enemy: Node3D, preferred: Node3D) -> void:
	if enemy.get_meta("workspace_trial", false): return
	if not Telemetry.credits_player(enemy) or bool(enemy.get_meta(&"kill_credited", false)):
		return
	var player := preferred if is_instance_valid(preferred) else Targeting.nearest_player(enemy)
	if is_instance_valid(player) and player.has_method("register_enemy_kill"):
		enemy.set_meta(&"kill_credited", true)
		player.call("register_enemy_kill", enemy)


static func begin_death(enemy: Node3D) -> void:
	if bool(enemy.get_meta(&"death_notified", false)):
		return
	enemy.set_meta(&"death_notified", true)
	enemy.remove_from_group("enemies")
	if bool(enemy.get_meta(&"formal_enemy", false)):
		var entry: Dictionary = enemy.get_meta(&"enemy_entry", {})
		var type := Pickup.roll_drop(String(entry.get("drop_kind", entry.get("kind", "melee"))))
		if type >= 0:
			var drop := PickupScene.instantiate() as Node3D
			drop.configure(type)
			enemy.get_tree().current_scene.add_child(drop)
			var options: Dictionary = entry.get("lifecycle", {})
			var surface := FX.sample_ground(enemy, enemy.global_position, float(options.get("drop_probe_depth", 32.0)))
			var ground: Vector3 = surface.get("position", Vector3(enemy.global_position.x, Terrain.height_at(enemy.global_position.x, enemy.global_position.z), enemy.global_position.z))
			drop.global_position = ground + Vector3.UP * float(options.get("pickup_height", 0.5))
	# 必须在根节点回收之前发出；波次与其他订阅者由此取得最后落点。
	enemy.emit_signal("died", enemy)


static func register_effect(enemy: Node3D, effect: Node3D) -> void:
	if not bool(enemy.get_meta(&"formal_enemy", false)) or bool(enemy.get_meta(&"death_focus_registered", false)):
		return
	enemy.set_meta(&"death_focus_registered", true)
	Wave.notify_death_fx(effect, enemy.global_position)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < float(settings.get("watchdog_interval", 1.0)):
		return
	_elapsed = 0.0
	var body := get_parent() as CharacterBody3D
	if body == null or bool(body.get_meta(&"death_notified", false)):
		return
	var point := body.global_position
	var limit := Terrain.get_extent() + float(settings.get("edge_margin", 2.0))
	if point.y < Terrain.height_at(point.x, point.z) - float(settings.get("fall_margin", 12.0)) or absf(point.x) > limit or absf(point.z) > limit:
		# 恢复有效出生点，不把坠界误算成击杀，也不留下永远无法清空的波次。
		body.global_position = spawn_position
		body.velocity = Vector3.ZERO
