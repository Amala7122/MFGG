extends RefCounted
## 狂暴由有限模板与选位驱动。预警出现即锁定，三道同时落下是一招完整攻势。
const Area := preload("res://scripts/enemy_attack_area.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const Effect := preload("res://scripts/prototypes/titan_melee_effect.gd")
const Audio := preload("res://scripts/audio_manager.gd")
const TripleSlam := preload("res://scripts/prototypes/titan_triple_slam_definition.gd")
var actor: CharacterBody3D
var cycle := 0
var closing_elapsed := 0.0
var after_sweep := false
var intent := "ready"
var areas: Array[Node3D] = []
var triple_elapsed := 0.0
var triple_struck := false
var triple_snapshot: Dictionary = {}
var leap_retry := 0.0
var gap_close_active := false
var pursuit_clock := 0.0

func setup(host: CharacterBody3D) -> void:
	actor = host

func enabled() -> bool:
	return actor.is_enraged and bool(actor._tuning.get("rage_director_enabled",false))

func tick(delta: float) -> void:
	leap_retry = maxf(leap_retry-delta,0.0)
	var can_pursue: bool = enabled() and actor.current_state in [actor.State.IDLE,actor.State.CHASE] and actor._target_alive()
	var far: bool = can_pursue and actor.global_position.distance_to(actor.target.global_position) > actor._p("triple_slam_length")*actor._crowd.size_multiplier*.85
	if far:
		pursuit_clock = fmod(pursuit_clock+delta,actor._p("rage_gap_close_burst")+.4)
		gap_close_active = pursuit_clock < actor._p("rage_gap_close_burst")
	else:
		pursuit_clock = 0.0
		gap_close_active = false
	if enabled() and actor.current_state in [actor.State.IDLE,actor.State.CHASE] and intent == "closing":
		closing_elapsed += delta

func choose(distance: float) -> String:
	if not enabled(): return ""
	var close: float = actor._p("rage_close_distance")*actor._crowd.size_multiplier
	if after_sweep:
		if actor._brain.available("triple_slam") and triple_reaches(distance):
			intent = "triple_slam_finisher"
			return "triple_slam"
		if float(actor._brain.cooldowns.triple_slam) <= .45:
			intent = "finisher_readying"
			return "move"
		intent = "unavailable_finisher"
		return "rest"
	# 每另一组主动改变双方位置，不把“追击失败”寄托在极少数待机帧。
	if cycle%2 == 1 or distance > close+5.0:
		if leap_retry <= 0.0 and actor._brain.available("leap") and distance >= actor._p("leap_min_distance"):
			intent = "reposition_leap"
			return "leap"
	if distance > close and closing_elapsed < actor._p("rage_close_timeout"):
		intent = "closing"
		return "move"
	if distance <= actor._p("sweep_distance")*actor._crowd.size_multiplier and actor._brain.available("sweep") and not actor._brain.needs_heavy(true):
		intent = "close_sweep"
		return "sweep"
	if actor._brain.available("triple_slam") and triple_reaches(distance):
		intent = "triple_slam"
		return "triple_slam"
	intent = "legal_approach"
	return "move"

func triple_reaches(distance: float) -> bool:
	var radius: float = actor._p("triple_slam_length")*actor._crowd.size_multiplier
	if distance > radius: return false
	# 起手时已知目标会在首击前跑出射程，就不站定放空；继续选位。
	# 仅影响是否起手，既有预警/三道朝向仍一次锁定，不读取未来输入。
	var future: Vector3 = actor.target.global_position-actor.global_position+actor._target_velocity*actor._p("triple_slam_windup")
	return Vector2(future.x,future.z).length() <= radius

func leap_failed() -> void:
	leap_retry = 1.0
	intent = "leap_illegal_ground_approach"

func finished(skill: String, heavy: bool) -> void:
	if not enabled(): return
	if skill == "sweep" and not heavy:
		after_sweep = true
		return
	if heavy or skill == "triple_slam":
		cycle += 1
		closing_elapsed = 0.0
		after_sweep = false
		intent = "recovery_complete"

func interrupt() -> void:
	clear_triple_slam()
	after_sweep = false
	closing_elapsed = 0.0
	intent = "interrupted"
	gap_close_active = false
	pursuit_clock = 0.0

func clear_triple_slam() -> void:
	for area: Node3D in areas:
		if is_instance_valid(area):
			area.cancel()
			area.queue_free()
	areas.clear()
	triple_snapshot.clear()
	triple_struck = false
	triple_elapsed = 0.0

func start_triple_slam() -> void:
	clear_triple_slam()
	triple_snapshot = TripleSlam.snapshot(actor._tuning,actor._crowd.size_multiplier,actor._damage_scale)
	# 三道共用脚下起点，向左/中/右展开；近处重叠、向外形成缝隙，出现后不追踪。
	var offset: Vector3 = actor.target.global_position-actor.global_position
	offset.y = 0.0
	var led: Vector3 = offset+actor._target_velocity*.3
	var base_yaw := atan2(-offset.x,-offset.z)
	var lead_yaw := atan2(-led.x,-led.z)
	base_yaw += clampf(wrapf(lead_yaw-base_yaw,-PI,PI),deg_to_rad(-20.0),deg_to_rad(20.0))
	actor.rotation.y = base_yaw
	for entry: Dictionary in TripleSlam.shapes(triple_snapshot,Transform3D(Basis(Vector3.UP,base_yaw),actor.global_position)):
		var area := Area.new()
		actor.add_child(area)
		area.prepare(entry.pose,entry.spec,float(triple_snapshot.damage))
		area.lock()
		areas.append(area)
	Audio.play_at("titan_charge",actor.global_position,-6.0,.8)

func tick_triple_slam(delta: float) -> void:
	if triple_snapshot.is_empty(): return
	triple_elapsed += delta
	var timing := TripleSlam.timing(triple_snapshot,triple_elapsed)
	if not triple_struck:
		for area: Node3D in areas: area.set_progress(timing.progress)
		var raise: float = timing.raise
		actor.left_arm_pivot.rotation_degrees.x = -75.0*raise
		actor.right_arm_pivot.rotation_degrees.x = -110.0*raise
		actor.torso_pivot.rotation_degrees.x = -12.0*raise
		if timing.struck:
			triple_struck = true
			# 先同时熄灭全部预警，再统一命中。三道是一击，不能叠伤三次。
			for area: Node3D in areas: area.strike()
			var hit := false
			for i in range(areas.size()):
				var area: Node3D = areas[i]
				if not hit and area.can_hit(actor._attack_target,area.hit_source()):
					hit = true
					actor._hit_landed = true
					Telemetry.hurt_player(actor._attack_target,area.damage,actor.global_position,1.0,Telemetry.source_info(actor,"泰坦三线重击"))
				var spec: Dictionary = area.shape.duplicate(true)
				spec["surface"] = area.get_surface()
				spec["compact_impact"] = true
				Effect.spawn(actor.get_tree().current_scene,area.global_transform,spec,actor._crowd.size_multiplier,false,.18,actor._p("ground_shake_strength")*.5)
				Telemetry.enemy_attack_beat(actor,"三线重击",i+1,3)
				area.recover()
			Audio.play_at("titan_land",actor.global_position,-7.0,1.0)
			actor._heavy_recovering = true
			actor._publish_formal_boss_health()
	if triple_struck:
		var recovery: float = timing.recovery
		var impulse: float = timing.impulse
		actor.torso_pivot.position.y = 1.8-.32*impulse
		actor.left_arm_pivot.rotation_degrees.x = 15.0*(1.0-recovery)
		actor.right_arm_pivot.rotation_degrees.x = 15.0*(1.0-recovery)
		actor.torso_pivot.rotation_degrees.x = -12.0*(1.0-recovery)
		if recovery >= 1.0: actor._finish_action(0.0)

func public_areas() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for area: Node3D in areas:
		if is_instance_valid(area) and area.visible and area.phase in [1,2]: result.append(area)
	return result

func public_area() -> Node3D:
	# 兼容单区域调用方；正式陪练从public_areas读取三道并保留间隙。
	for area: Node3D in public_areas():
		if area.contains(actor.target.global_position): return area
	return areas[1] if areas.size()==3 and not triple_struck else null

func snapshot() -> Dictionary:
	var geometry: Array = []
	for area: Node3D in areas:
		var p := area.global_position
		geometry.append({"origin":[p.x,p.y,p.z],"yaw":area.global_rotation.y,"shape":area.shape.duplicate(true)})
	return {"enabled":enabled(),"cycle":cycle,"intent":intent,"closing_elapsed":closing_elapsed,"after_sweep":after_sweep,"triple_struck":triple_struck,"triple_elapsed":triple_elapsed,"triple_snapshot":triple_snapshot.duplicate(true),"triple_geometry":geometry,"gap_close_active":gap_close_active,"pursuit_clock":pursuit_clock}
