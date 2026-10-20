extends "res://scripts/enemies/crystal_creature_actor.gd"
const Projectile := preload("res://scripts/enemies/crystal_projectile.gd")
const Behavior := preload("res://scripts/prototypes/crawler_behavior.gd")
const FX := preload("res://scripts/combat_fx.gd")
var throws := 0
var _sac_rest := Vector3.ZERO


func profile_id() -> String:
	return "VisualBurstCrawler"


func visual_scene() -> PackedScene:
	return preload("res://prototypes/visual_lab/burst_crawler_visual.tscn")


static func get_body_dimensions(values: Dictionary = {}) -> Vector3:
	return Vector3(float(values.get("body_width", 1.65)) * 0.9, float(values.get("belly_height", 1.0)) + 0.65, float(values.get("body_length", 2.25)) * 0.9)


func _setup_species() -> void:
	_sac_rest = visual.to_local(visual.sacs[0].global_position)
	for part: MeshInstance3D in visual.find_children("*", "MeshInstance3D", true, false):
		if String(part.name).begins_with("LuminousSac"):
			_regions.add_part(self, part, "body")


func _think(delta: float) -> Vector3:
	var offset := global_basis.orthonormalized().inverse() * (target.global_position - global_position)
	var behavior: RefCounted = visual.behavior
	if behavior.state == Behavior.State.IDLE and offset.length() <= p("attack_range") and behavior.cooldown <= 0.0:
		if not _crowd.request_attack():
			face(target.global_position, delta)
			return navigate(target.global_position, move_speed * p("crowd_wait_speed"), delta)
	var result: Dictionary = visual.update_combat(delta, offset, can_attack_from(global_transform))
	match int(result.state):
		Behavior.State.RETREAT:
			_crowd.release_attack()
			set_state(State.RETREAT)
			var away: Vector3 = global_basis.orthonormalized() * result.velocity
			var goal := global_position + away.normalized() * p("retreat_exit_range")
			return navigate(goal, p("retreat_speed"), delta)
		Behavior.State.TURN, Behavior.State.THROW:
			set_state(State.WINDUP)
		Behavior.State.RECOVER:
			set_state(State.RECOVERY)
		_:
			_crowd.release_attack()
			visual.behavior.yaw = 0.0
			visual.rig.rotation.y = 0.0
			face(target.global_position, delta)
			if not can_attack_from(global_transform):
				set_state(State.APPROACH)
				return navigate(target.global_position, move_speed, delta)
			set_state(State.IDLE)
	if bool(result.throw):
		_throw_sac()
	return Vector3.ZERO


func can_attack_from(pose: Transform3D) -> bool:
	if not Health.is_alive(target):
		return false
	var offset := target.global_position - pose.origin
	var distance := Vector2(offset.x, offset.z).length()
	if distance <= p("retreat_range") or distance > p("attack_range"):
		return false
	var surface := FX.sample_ground(self, target.global_position + Vector3.UP, 12.0)
	if surface.is_empty(): return false
	var origin: Vector3
	if visual.behavior.state in [Behavior.State.TURN, Behavior.State.THROW]:
		origin = pose * to_local(visual.sacs[0].global_position)
	else:
		var facing := Basis(Vector3.UP, atan2(-offset.x, -offset.z)).scaled(pose.basis.get_scale())
		origin = pose.origin + facing * (visual.position + _sac_rest.rotated(Vector3.UP, deg_to_rad(p("turn_yaw"))))
	return Projectile.lob_is_clear(self, origin, surface.position, _tuning)


func _throw_sac() -> void:
	if not Health.is_alive(target):
		return
	var origin: Vector3 = visual.sacs[0].global_position
	var surface := FX.sample_ground(self, target.global_position + Vector3.UP, 12.0)
	if surface.is_empty():
		return
	if not Projectile.lob_is_clear(self, origin, surface.position, _tuning):
		return
	var projectile := Projectile.new()
	get_tree().current_scene.add_child(projectile)
	projectile.configure_lob(origin, surface.position, _tuning, Telemetry.source_info(self, "转身抛爆囊"))
	throws += 1
	Telemetry.enemy_attack_started(self, "转身抛爆囊")


func cancel_attack() -> void:
	super()
	if is_instance_valid(visual):
		visual.behavior.reset()
		visual.rig.rotation.y = 0.0


func _pose(delta: float) -> void:
	if current_state in [State.IDLE, State.APPROACH, State.STAGGER, State.REACTION]:
		super(delta)
