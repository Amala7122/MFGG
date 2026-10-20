extends "res://tests/test_titan_followup.gd"
## 正式玩家/地表/伤害验证同时三线与安全通道；不以测试死亡率判手感。
const Adapter := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd")

func ready_lines(distance := 12.0) -> void:
	await setup("rage")
	player.max_health = 100
	player.health = 100
	player.shield = 70
	player._shield_regen_timer = 1000
	player.position = Vector3(0,1.01,-distance)
	player.camera_pivot.rotation = Vector3.ZERO
	player.target_yaw = 0
	await frames(5)
	check(boss.trigger_triple_slam_attack(),"正式狂暴能开始同时三线重击")
	check(boss._brain.group_count == 1 and boss._heavy_window,"三道只消费一个有限重攻势")
	check(Adapter.public_areas(boss).size()==3,"三道同时公开，陪练不能只观察中线")
	for area: Node3D in boss._rage_director.areas:
		check(area.visible and area.phase==area.Phase.LOCKED and area.shape.kind=="rect","三条矩形同时锁向/可见，无扇面或隐藏后续拍")

func _run() -> void:
	root.get_node("GameFlow").set_meta(&"sparring_session_active",true)
	# 共起点三道线心、中远两个缝隙、近处两道/三道交叠；只在锁向后摆测点。
	var cases: Array = []
	for distance: float in [4.0,12.0,22.0]:
		for axis: float in [-1.0,0.0,1.0]: cases.append({"distance":distance,"angle":axis*35.0,"damage":35.0,"kind":"line"})
	for distance: float in [8.0,12.0,20.0]:
		for side: float in [-1.0,1.0]: cases.append({"distance":distance,"angle":side*17.5,"damage":0.0,"kind":"gap"})
	for angle: float in [-17.5,17.5]: cases.append({"distance":4.0,"angle":angle,"damage":35.0,"kind":"double_overlap"})
	cases.append({"distance":2.0,"angle":0.0,"damage":35.0,"kind":"triple_overlap"})
	for trial: Dictionary in cases:
		await ready_lines()
		player.set_physics_process(false)
		player.hit_invulnerability = 0.0 # 单独检查去重，不靠受击保护掩盖重复伤害。
		var areas: Array = boss._rage_director.areas
		var angle := deg_to_rad(float(trial.angle))
		player.position = Vector3(sin(angle)*float(trial.distance),1.01,-cos(angle)*float(trial.distance))
		var covering := 0
		for area: Node3D in areas:
			check(area.global_position.is_equal_approx(boss.global_position) and area.shape.offset==0.0,"三道同起点且没有横向平移")
			if area.can_reach(player.position): covering += 1
		if trial.kind=="double_overlap": check(covering==2,"近处有真实两道交叠")
		if trial.kind=="triple_overlap": check(covering==3,"脚前近区三道真实交叠")
		if trial.kind=="gap": check(covering==0,"展开后的缝隙在全部三道之外")
		var camera := Camera3D.new()
		world.add_child(camera)
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 38.0
		camera.position = Vector3(0,45,-12)
		camera.look_at(Vector3(0,0,-12),Vector3.FORWARD)
		camera.make_current()
		var controller := preload("res://tools/probes/sparring/sparring_controller.gd").new()
		var warning: Dictionary = controller._public_warning(player,camera,boss)
		check(warning.get("regions",[]).size()==3,"实际可见三道均进入公开情境")
		if not warning.is_empty():
			check(controller.published_contains(warning,player.position)==(trial.kind!="gap"),"陪练按并集保留缝隙，不把外包范围当全域危险")
		var impact_frames: Array = []
		var strike_frame := -1
		for tick in range(150):
			if tick==20:
				boss._tuning.triple_slam_windup = .6
				boss._tuning.triple_slam_damage = 60.0
				boss._tuning.triple_slam_width = 4.0
				boss._tuning.triple_slam_spread = 20.0
				boss._tuning.triple_slam_recovery = .5
			await physics_frame
			var visible_count := 0
			for area: Node3D in areas:
				if is_instance_valid(area) and area.visible: visible_count += 1
			check(visible_count in [0,3],"三道始终同时出现/消失")
			if boss._rage_director.triple_struck and strike_frame<0:
				strike_frame = tick
				for area: Node3D in areas:
					check(not area.visible and area.phase==area.Phase.RECOVERY,"同一物理帧全部命中/熄灭")
					impact_frames.append(Engine.get_physics_frames())
			if boss.current_state==boss.State.IDLE: break
		check(170-player.health-player.shield==float(trial.damage),"线内/交叠一次35，缝隙0；不靠受击保护去重")
		check(strike_frame>=70 and strike_frame<=73 and impact_frames.size()==3,"三道共同1.2秒结算，没有后续拍")
		check(boss.current_state==boss.State.IDLE and boss._brain.group_count==0 and boss._rage_director.areas.is_empty(),"共同命中后完整收势并清招组")
		var record := trial.duplicate()
		record.merge({"loss":170-player.health-player.shield,"covering_regions":covering,"strike_frame":strike_frame,"same_frame_impacts":impact_frames})
		results.append(record)
		await dispose()
	# 原生走位：近处跑到展开口，中远就近侧移进缝隙；只在预警后0.3秒开始。
	for distance: float in [4.0,8.0,12.0,20.0]:
		for side: float in [-1.0,1.0]:
			await ready_lines(distance)
			var destination := Vector3(side*(float(boss._rage_director.triple_snapshot.width)*.5+.65),1.01,-distance)
			if distance==4.0: destination = Vector3(side*sin(deg_to_rad(17.5))*9.0,1.01,-cos(deg_to_rad(17.5))*9.0)
			for tick in range(150):
				for key: String in ["move_right","move_left","move_forward","move_back","sprint"]: Input.action_release(key)
				var offset: Vector3 = destination-player.position
				if tick>=18 and Vector2(offset.x,offset.z).length()>.25:
					if absf(offset.x)>.18: Input.action_press("move_right" if offset.x>0 else "move_left")
					if absf(offset.z)>.18: Input.action_press("move_back" if offset.z>0 else "move_forward")
					if distance==4.0: Input.action_press("sprint")
				await physics_frame
			check(player.health+player.shield==170.0,"0.3秒后原生走/跑进左右缝隙，无翻滚/传送仍零受伤")
			results.append({"native_distance":distance,"side":side,"loss":170-player.health-player.shield})
			for key: String in ["move_right","move_left","move_forward","move_back","sprint"]: Input.action_release(key)
			await dispose()
	await ready_lines()
	player.set_physics_process(false)
	await frames(18)
	var t: float = boss._rage_director.triple_elapsed
	var pose: Transform3D = boss._rage_director.areas[1].global_transform
	paused = true
	await process_frame
	await process_frame
	check(boss._rage_director.triple_elapsed == t,"暂停冻结整组三线时间")
	paused = false
	boss.apply_grenade_stagger(.25)
	await frames(8)
	check(is_equal_approx(boss._rage_director.triple_elapsed,t),"真实E短硬直延后未发生拍，不吞拍或清招组")
	player.position.x += 8
	await frames(12)
	check(boss._rage_director.areas[1].global_transform == pose,"三线起手后玩家改位不追踪重瞄")
	check(Adapter.sample(boss,"new").state == "triple_slam","陪练识别新三线，不报unknown")
	# 奖励入口取消所有三线；真实三枪全链由晶体/倒地测试另外守住。
	boss._request_reward("down")
	check(boss._rage_director.areas.is_empty() and boss._reward_kind == "down","已挣得倒地优先取消全部未兑现拍")
	var hp: float = player.health+player.shield
	await frames(100)
	check(player.health+player.shield == hp,"倒地之后无残留扇形扣血")
	check(not boss.has_mud_shield,"狂暴新技能和奖励不重建盾")
	await dispose()
	await ready_lines()
	player.set_physics_process(false)
	await frames(10)
	boss.take_damage(10000000)
	check(boss.current_state == boss.State.DEAD and boss._rage_director.areas.is_empty(),"死亡取消三线与预警")
	await dispose()
	# 真实自动选位：起点留出远距确认期间的追赶距离，体型改变不能将样本变成近区。
	await setup("rage")
	var start_distance: float = boss._p("leap_far_distance") + boss.effective_move_speed * boss._p("far_confirm_time") + 4.0 * boss.scale.x
	player.position = Vector3(0,1.01,-start_distance)
	player.set_physics_process(false)
	player.health = 100000
	boss.ai_enabled = true
	await frames(1500)
	var skills := {}
	for row: Dictionary in boss._brain.history: skills[row.skill] = true
	check(skills.has("triple_slam") and skills.has("sweep") and skills.has("leap"),"真实远区自动循环实际压近/横扫/三线/跃击，不仅计数上限成立")
	check(not skills.has("slam"),"狂暴默认不再反复使用慢直线")
	check(boss._brain.group_count <= boss._brain.group_limit,"新模板不越过招组上限")
	results.append({"auto_start_distance":start_distance,"auto_skills":skills,"history":boss._brain.history.duplicate(true)})
	await dispose()
	# 追赶是有限地面移动，不放宽跃击距离/地表条件，也不在近身或出招中提速。
	await setup("rage")
	player.set_physics_process(false)
	boss.set_physics_process(false)
	boss.current_state = boss.State.IDLE
	player.position = Vector3(0,1.01,-45)
	var ordinary_speed: float = boss.effective_move_speed
	# 位于真实最大距离内沿，向外预测后必须超距；不固定旧的30世界米。
	player.position.z = -(boss._p("leap_max_distance")-0.5)
	boss._target_velocity = Vector3(0,0,-8.5)
	check(boss._plan_leap().is_empty() and boss._leap_plan_failure == "predicted_out_of_reach","不会把超距预测落点截短后反复无效起跳，先地面追赶")
	player.position.z = -22
	check(not boss._rage_director.triple_reaches(22),"已观察到首拍前退出射程，不在扇形外缘站定放空")
	player.position.z = -12
	check(boss._rage_director.triple_reaches(12),"持续直退进入实际首拍射程后仍可合法起手")
	player.position.z = -45
	boss._rage_director.tick(.1)
	check(boss._rage_director.gap_close_active and boss.effective_move_speed > ordinary_speed,"远距空档使用地面加速追赶")
	boss._rage_director.tick(1.55)
	check(not boss._rage_director.gap_close_active and is_equal_approx(boss.effective_move_speed,ordinary_speed),"1.6秒追赶后有0.4秒普通移动，不持续冲刺")
	boss._rage_director.tick(.4)
	check(boss._rage_director.gap_close_active,"远距仍可开始下一次有限追赶")
	player.position.z = -10
	boss._rage_director.tick(.1)
	check(not boss._rage_director.gap_close_active and boss._rage_director.pursuit_clock == 0.0,"回到交战距离立即恢复普通移动")
	player.position.z = -45
	boss.current_state = boss.State.ATK_THRUST
	boss._rage_director.tick(.1)
	check(not boss._rage_director.gap_close_active,"攻击期间不借追赶倍率额外滑步")
	boss.current_state = boss.State.IDLE
	boss.set_physics_process(true)
	await frames(4)
	var pursuit_time: float = boss._rage_director.pursuit_clock
	paused = true
	await process_frame
	await process_frame
	check(boss._rage_director.pursuit_clock == pursuit_time,"暂停冻结追赶节拍")
	paused = false
	boss.apply_grenade_stagger(.25)
	await frames(8)
	check(is_equal_approx(boss._rage_director.pursuit_clock,pursuit_time),"手雷硬直冻结追赶，不用提速抵消硬直")
	boss._request_reward("down")
	check(not boss._rage_director.gap_close_active and boss._rage_director.pursuit_clock == 0.0,"长奖励清理追赶，不带提速起身")
	await dispose()
	await setup("front")
	boss.current_state = boss.State.IDLE
	player.position.z = -45
	boss._rage_director.tick(.1)
	check(not boss._rage_director.gap_close_active,"前半不启用狂暴追赶")
	check(not boss.trigger_triple_slam_attack() and boss.has_mud_shield,"前半不启用狂暴三线，常驻盾规则保持")
	await dispose()
	var melee_effect := preload("res://scripts/prototypes/titan_melee_effect.gd")
	check(melee_effect.spawn(null,Transform3D.IDENTITY,{},1.0,false)==null,"离场后current_scene为空，不创建近战特效")
	var detached := Node3D.new()
	check(melee_effect.spawn(detached,Transform3D.IDENTITY,{},1.0,false)==null,"脱离场景的宿主不创建近战特效")
	detached.free()
	var leaving := Node3D.new()
	root.add_child(leaving)
	leaving.queue_free()
	check(melee_effect.spawn(leaving,Transform3D.IDENTITY,{},1.0,false)==null,"已排队删除的宿主不创建近战特效")
	await frames(2)
	results.append({"melee_effect_teardown_hosts_rejected":3})
	var file := FileAccess.open(Artifacts.ensure_dir("reports","rage_director").path_join("result.json"),FileAccess.WRITE)
	if file == null:
		push_error("新攻势测试报告写入失败")
		quit(1)
		return
	file.store_string(JSON.stringify({"trials":results,"failures":failures},"\t"))
	file.close()
	preload("res://scripts/object_pool.gd").clear_all()
	await preload("res://tools/probes/sparring/sparring_runtime.gd").settle_audio(self)
	root.get_node("GameFlow").remove_meta(&"sparring_session_active")
	print("[狂暴选位与三线] failures=",failures)
	quit(1 if failures else 0)
