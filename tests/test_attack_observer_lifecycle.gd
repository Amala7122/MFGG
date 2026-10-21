extends SceneTree
## 真实技能观察后击杀，覆盖散架到queue_free之间仍会发生的采样。
const Lab := preload("res://prototypes/combat_lab/combat_lab.tscn")
const Inspect := preload("res://scripts/testing/enemy_attack_inspection.gd")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Health := preload("res://scripts/health_util.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")
var failures: Array[String] = []
var checks := 0
var cases: Array[Dictionary] = []

func _initialize() -> void: _run.call_deferred()
func frames(count: int) -> void:
	for i in count: await physics_frame
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func _run() -> void:
	await frames(4)
	var lab := Lab.instantiate()
	root.add_child(lab); current_scene = lab
	await frames(8)
	for profile: String in Tuning.PROFILE_PATHS:
		var values := Tuning.defaults(profile)
		values.variation_enabled = false
		values.crowd_enabled = false
		await lab.observe_draft(profile,values)
		var subject: Node3D = lab._live_enemies[0]
		var observer: Node3D = lab._attack_observer
		await frames(30)
		var live_points := Inspect.motion_points(subject)
		check(not live_points.is_empty(),profile+" 活体仍有真实攻击部位")
		if profile == "PrototypeMudGolem":
			check(observer._traces.any(func(trace: Dictionary): return trace.point == "right_fist"),"泥偶原地出拳继续记录真实拳头轨迹")
		subject.set_meta(&"experiment_invincible",false)
		var trace_count: int = observer._traces.size()
		subject.call("take_damage",1000000000.0)
		check(not Health.is_alive(subject),profile+" 真实受击进入死亡")
		check(subject.is_queued_for_deletion(),profile+" 处于散架后仍未释放的当帧")
		if profile == "PrototypeMudGolem":
			check(subject.right_arm_pivot.get_child_count() == 0,"复现泥偶拳头已从旧支点移走")
		check(Inspect.motion_points(subject).is_empty(),profile+" 死亡当帧不采已拆走的部位")
		check(Inspect.sample(subject,0).is_empty(),profile+" 不把死亡残骸显示为技能范围")
		observer._physics_process(0.0)
		check(observer._last_positions.is_empty(),profile+" 死亡清除连续采样游标")
		observer._refresh = 0.0
		observer._process(0.0)
		check(observer._traces.size() == trace_count,profile+" 保留已录轨迹，不生成空引用或原点跳线")
		check(observer.sample_data.is_empty() and observer.active_snapshots.is_empty(),profile+" 死亡清除当前技能几何快照")
		cases.append({"profile":profile,"alive_points":live_points.keys(),"preserved_traces":trace_count})
		await frames(3)
		check(not is_instance_valid(subject),profile+" 宿主正常释放")
		observer._physics_process(0.0)
		observer._refresh = 0.0
		observer._process(0.0)
		check(observer._readout.text.contains("回收"),profile+" 无效目标状态有明确说明")
		if profile == "PrototypeMudGolem" and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			check(root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join("mud_golem_death_observation.png")) == OK,"死亡观察状态截图保存")
		await lab.observe_draft(profile,values)
		check(not Inspect.motion_points(lab._live_enemies[0]).is_empty(),profile+" 重播后新样本恢复真实部位采样")
	paused = false
	current_scene = null
	lab.queue_free()
	await frames(3)
	var report := FileAccess.open(Artifacts.ensure_dir("reports").path_join("attack_observer_lifecycle.json"),FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks":checks,"failures":failures,"cases":cases},"\t")); report.close()
	print("[攻击观察生命周期] checks=",checks," failures=",failures.size())
	quit(0 if failures.is_empty() else 1)
