extends "res://tests/test_titan_followup.gd"
## 候选实验：正式玩家移动/加减速/翻滚/受伤，公共攻击几何。
## 未接入Boss状态机；快测不能证明真实时间实战难度或真人可读性。
const Area := preload("res://scripts/enemy_attack_area.gd")
const Telemetry := preload("res://scripts/combat_telemetry.gd")
const POLICIES := ["stand", "small_step_stop", "roll_stop", "run_right", "run_left", "orbit_right", "orbit_left", "retreat", "diagonal_right", "diagonal_left", "read_reverse_right", "read_reverse_left", "read_fast_chain_right", "read_fast_chain_left"]
const MOVE_ACTIONS := ["move_right", "move_left", "move_forward", "move_back", "sprint"]
const ONE_DIRECTION := ["run_right", "run_left", "orbit_right", "orbit_left", "retreat", "diagonal_right", "diagonal_left"]
const PATTERNS := {
	"single_line": {"times":[1.0], "angles":[0.0], "widths":[4.3], "radii":[13.2]},
	# 保留已测失败候选，不能改名覆盖旧证据。
	"fan_three": {"times":[1.0,1.7,2.4], "angles":[-25.0,0.0,25.0], "widths":[70.0,70.0,70.0], "radii":[13.2,13.2,13.2]},
	"fan_split": {"times":[1.0,1.7,2.4], "angles":[0.0,45.0,-45.0], "widths":[40.0,65.0,65.0], "radii":[18.0,23.0,26.0]},
	"fan_predict_lock": {"times":[1.0,1.95,2.9], "angles":[0.0,0.0,0.0], "widths":[40.0,28.0,28.0], "radii":[18.0,23.0,26.0], "sample_each_beat":true, "prediction_cap_m":8.5},
	# 新反馈：一次起手、三拍连续落下；左右左与镜像，均先公布顺序。
	"fan_fast_lrl": {"times":[1.0,1.4,1.8], "angles":[-22.0,22.0,-22.0], "widths":[50.0,50.0,50.0], "radii":[24.0,24.0,24.0]},
	"fan_fast_rlr": {"times":[1.0,1.4,1.8], "angles":[22.0,-22.0,22.0], "widths":[50.0,50.0,50.0], "radii":[24.0,24.0,24.0]},
	# 扩外缘而保留内侧6度交叠，检验绕圈漏洞与反向可行解是否同时成立。
	"fan_fast_spread_lrl": {"times":[1.0,1.4,1.8], "angles":[-24.5,24.5,-24.5], "widths":[55.0,55.0,55.0], "radii":[24.0,24.0,24.0]},
	"fan_fast_spread_rlr": {"times":[1.0,1.4,1.8], "angles":[24.5,-24.5,24.5], "widths":[55.0,55.0,55.0], "radii":[24.0,24.0,24.0]}
}

func _movement(policy: String, elapsed: float, last_warning: float, warning_count: int) -> void:
	for action: String in MOVE_ACTIONS: Input.action_release(action)
	if elapsed < .25 or policy in ["stand", "roll_stop"]: return
	if policy == "small_step_stop" and elapsed >= .75: return
	Input.action_press("sprint")
	var left := policy.ends_with("left")
	if policy.begins_with("read_fast_chain"):
		# 已提前公布三拍；0.25秒后走第一步，制动，过边界后反向，末拍翻滚。
		# 这是已知序列的存在性反例，不能当作通用陪练或真人反应成功率。
		if elapsed >= .52 and elapsed < .82: return
		if elapsed >= .82: left = not left
		if elapsed >= 1.4 and elapsed < 1.42 and player._can_dodge():
			player._start_roll(Vector3.LEFT if policy.ends_with("left") else Vector3.RIGHT)
		Input.action_press("move_left" if left else "move_right")
		return
	if policy.begins_with("read_reverse"):
		# 仅在已出现的公共预警后0.25秒改向，不读未公布的后一拍。
		var reversals := warning_count-1 if elapsed >= last_warning+.25 else warning_count-2
		if maxi(reversals,0)%2 == 1: left = not left
	if policy.begins_with("orbit"):
		# 看向Boss并持续保持同侧切向输入，无预警反应或方向反转。
		var radial: Vector3 = player.global_position-boss.global_position
		var yaw := atan2(radial.x,radial.z)
		player.target_yaw = yaw
		player.camera_pivot.rotation.y = yaw
	if policy == "retreat" or policy.begins_with("diagonal"):
		Input.action_press("move_forward")
	if policy != "retreat": Input.action_press("move_left" if left else "move_right")

func _run() -> void:
	root.get_node("GameFlow").set_meta(&"sparring_session_active", true)
	var selected: Array = PATTERNS.keys()
	var policies: Array = POLICIES
	var moving_start := false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--patterns="):
			selected = Array(arg.trim_prefix("--patterns=").split(","))
		if arg.begins_with("--policies="):
			policies = Array(arg.trim_prefix("--policies=").split(","))
		if arg == "--moving-start": moving_start = true
	for policy: String in policies:
		if policy not in POLICIES:
			push_error("未知移动策略："+policy)
			quit(1)
			return
	for pattern: String in selected:
		if not PATTERNS.has(pattern):
			push_error("未知扇形候选："+pattern)
			quit(1)
			return
		for distance: float in [10.0,16.0]:
			for policy: String in policies:
				await setup("rage")
				player.max_health = 100
				player.health = 100
				player.shield = 70
				player._shield_regen_timer = 1000
				player._health_regen_timer = 1000
				player.position = Vector3(0,1.01,-distance)
				player.velocity = Vector3.ZERO
				player.camera_pivot.rotation = Vector3.ZERO
				player.target_yaw = 0
				player.target_pitch = 0
				await frames(5)
				var running: bool = moving_start and policy in ONE_DIRECTION
				if running:
					# 显式初态：已经全速，不把预警后才开始加速冒充持续跑。
					var direction := Vector3.ZERO
					if policy != "retreat": direction.x = -1.0 if policy.ends_with("left") else 1.0
					if policy.begins_with("orbit"): direction.x *= -1.0
					if policy == "retreat" or policy.begins_with("diagonal"): direction.z = -1.0
					player.velocity = direction.normalized()*player.speed*player.sprint_multiplier
				var config: Dictionary = PATTERNS[pattern]
				var impacts: Array = config.times
				var areas: Array[Node3D] = []
				var warning_rows: Array = []
				var beat_rows: Array = []
				var sampled: bool = config.get("sample_each_beat",false)
				var spent := 0
				var last_warning := 0.0
				for tick in range(0,int((float(impacts.back())+.3)*60)+1):
					var elapsed := float(tick)/60.0
					var next := areas.size()
					# 固定扇全部在开头公布；预测扇每拍开头取样一次，之后不追踪。
					while next < impacts.size() and (not sampled or elapsed >= (0.0 if next == 0 else float(impacts[next-1]))):
						var angle: float = config.angles[next]
						var predicted := Vector3.ZERO
						if sampled:
							var offset: Vector3 = player.velocity * (float(impacts[next])-elapsed)
							offset.y = 0.0
							offset = offset.limit_length(float(config.prediction_cap_m))
							predicted = player.global_position-boss.global_position+offset
							angle = rad_to_deg(atan2(predicted.x,-predicted.z))
						var area := Area.new()
						boss.add_child(area)
						var spec := {"kind":"rect","width":float(config.widths[next]),"length":float(config.radii[next]),"height":4.1,"offset":0.0,"stable_tracking_surface":true} if pattern == "single_line" else {"kind":"sector","radius":float(config.radii[next]),"angle":float(config.widths[next]),"height":4.1,"stable_tracking_surface":true}
						area.prepare(Transform3D(Basis(Vector3.UP,deg_to_rad(-angle)),boss.global_position),spec,40.0,float(impacts[next])-elapsed)
						area.lock()
						areas.append(area)
						warning_rows.append({"beat":next+1,"time":elapsed,"angle":angle,"width":config.widths[next],"radius":config.radii[next],"sampled_velocity":[player.velocity.x,player.velocity.z],"predicted_point":[predicted.x,predicted.z],"locked":true})
						last_warning = elapsed
						next += 1
					_movement(policy,elapsed+.25 if running else elapsed,last_warning,areas.size())
					if policy == "roll_stop" and tick == 54 and player._can_dodge(): player._start_roll(Vector3.RIGHT)
					await physics_frame
					if spent < impacts.size() and elapsed >= float(impacts[spent]):
						var before: float = player.health+player.shield
						var area: Node3D = areas[spent]
						var geometry := bool(area.strike()) and bool(area.can_hit(player,area.hit_source()))
						if geometry: Telemetry.hurt_player(player,40.0,boss.global_position,1.0,{"source":"pattern_probe"})
						area.recover()
						beat_rows.append({"beat":spent+1,"time":elapsed,"geometry_contains":geometry,"actual_loss":before-player.health-player.shield,"player_position":[player.position.x,player.position.y,player.position.z]})
						spent += 1
				check(beat_rows.size() == impacts.size(),"候选每拍必须实际结算，不能漏跑")
				results.append({"pattern":pattern,"policy":policy,"start_distance":distance,"moving_start":running,"actual_loss":170-player.health-player.shield,"warnings":warning_rows,"beats":beat_rows,"scope":"受控几何/原生移动/无敌帧快测；不是Boss完整技能或玩家群体结论"})
				for action: String in MOVE_ACTIONS: Input.action_release(action)
				await dispose()
	var file := FileAccess.open(Artifacts.ensure_dir("reports","fan_pattern").path_join("experiment.json"),FileAccess.WRITE)
	if file == null:
		push_error("扇形实验报告无法保存")
		quit(1)
		return
	file.store_string(JSON.stringify({"trials":results,"patterns":PATTERNS,"reaction_seconds":.25,"normalised_damage_per_beat":40,"purpose":"候选最小对照，未修改正式Boss"},"\t"))
	file.close()
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	root.get_node("GameFlow").remove_meta(&"sparring_session_active")
	print("[扇形候选] trials=",results.size()," failures=",failures)
	quit(1 if failures else 0)
