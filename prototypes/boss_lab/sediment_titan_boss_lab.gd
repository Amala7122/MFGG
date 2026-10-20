@tool
extends "res://scripts/editor_world_preview.gd"
## 沉积泰坦直战入口。
##
## F6 运行本场景后，复用圣所正式地图、WaveDirector、EnemySpawner 与阶段结算，
## 跳过四波普通敌人。玩家在生成前写入三种武器模块的配置上限，并补满全部弹药。

const ArenaUtil := preload("res://scripts/arena.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")
const RunStateUtil := preload("res://scripts/run_state.gd")

const ARENA_ID := "sanctum"
const UPGRADE_IDS := [&"fire_rate", &"damage", &"magazine"]
const NAV_READY_FRAME_LIMIT := 300
const WarmupArea := preload("res://scripts/enemy_attack_area.gd")
const WarmupGround := preload("res://scripts/prototypes/titan_ground_effect.gd")
const WarmupMelee := preload("res://scripts/prototypes/titan_melee_effect.gd")

var _configured_flow: Node
var _warmup_resources: Array[Resource] = []
## 直战投放固定种子，F5 可重复同一出生点；设为 0 时恢复随机投放。
@export var trial_seed: int = 10420261014


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		process_mode = Node.PROCESS_MODE_ALWAYS
		var display := get_node_or_null("/root/DisplaySettings")
		if display != null:
			display.begin_scene_style(self)
		# 根节点要在暂停时接收 F5，但正式世界不能继承 ALWAYS，否则准备遮罩下
		# 的暂停不会冻结玩家、敌人和技能 Tween。
		for child in get_children():
			child.process_mode = Node.PROCESS_MODE_PAUSABLE
		prepare_direct_trial()
	super._enter_tree()


func _ready() -> void:
	if not Engine.is_editor_hint():
		call_deferred("_launch_direct_trial")


## 先写一局状态，再生成玩家；PlayerWeapon.setup() 会读取这份真实状态。
## 返回快照供自动验收确认，不靠 HUD 文本推断是否满配。
func prepare_direct_trial() -> Dictionary:
	ArenaUtil.current_id = ARENA_ID
	RunStateUtil.begin_run()
	var order := ArenaUtil.get_order()
	var arena_index := order.find(ARENA_ID)
	RunStateUtil.set_progress(arena_index + 1 if arena_index >= 0 else 1, 0)
	var weapon_level := 1
	var stacks: Dictionary = {}
	for upgrade_id in UPGRADE_IDS:
		var id := String(upgrade_id)
		var maximum := maxi(ConfigUtil.get_int("weapon.upgrades.%s.max_stacks" % id, 0), 0)
		RunStateUtil.set_upgrade_stacks(id, maximum)
		stacks[id] = maximum
		weapon_level += maximum
	RunStateUtil.set_weapon_level(weapon_level)
	return {"arena_id": ARENA_ID, "weapon_level": weapon_level, "upgrades": stacks}


func _launch_direct_trial() -> void:
	# GameFlow 首帧会识别当前是独立实验场；等它初始化后再切入可玩状态。
	await get_tree().process_frame
	await get_tree().process_frame
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null:
		flow.set_meta(&"experiment_silent_pause", true)
		_configured_flow = flow
	# 主线程烘焙和首批材质编译先在准备阶段完成，再开放玩家操作。
	get_tree().paused = true
	var loading := _show_loading()
	var nav_region := get_node_or_null("NavRegion")
	for _frame in range(NAV_READY_FRAME_LIMIT):
		if nav_region == null or not nav_region.has_method("is_baked") or bool(nav_region.call("is_baked")):
			break
		await get_tree().process_frame
	if nav_region != null and nav_region.has_method("is_baked") and not bool(nav_region.call("is_baked")):
		push_error("Boss 直战台：导航准备超时，未开放战斗")
		return
	var spawner := get_node_or_null("PlayerSpawner")
	var player: Node = get_tree().get_first_node_in_group("player")
	if player == null and spawner != null and spawner.has_method("spawn_player"):
		player = spawner.call("spawn_player") as Node
	if player == null:
		push_error("Boss 直战台：玩家生成失败")
		return
	await get_tree().process_frame
	refill_player_ammo(player)
	# 玩家主相机已经生成；在准备遮罩下完成整张场景的首次渲染与导航地图同步。
	for _frame in range(3):
		await get_tree().process_frame
	# PhysicsServer 的碰撞体 / 玩家接地和导航地图要完成首次同步，正式投放
	# 才能证明落点可达。此时仍盖着准备界面且尚未生成 Boss，不会消耗其开场。
	get_tree().paused = false
	for _frame in range(2):
		await get_tree().physics_frame
	get_tree().paused = true
	var spawned := await _spawn_trial_opponents(player)
	if spawned and DisplayServer.get_name() != "headless" \
		and not OS.get_cmdline_user_args().has("--skip-boss-warmup") and is_instance_valid(get_tree().get_first_node_in_group("boss")):
		await _warmup_boss_materials(player, get_tree().get_first_node_in_group("boss"))
	loading.queue_free()
	if flow != null and flow.has_method("_resume_play"):
		flow.call("_resume_play")
	else:
		get_tree().paused = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not spawned:
		push_warning("直战准备：未能完成投放，未开放陪练")
		return
	_show_notice(player)


## 通用实战入口复用地图／导航／玩家准备；敌人投放仍由正式入口负责。
func _spawn_trial_opponents(_player: Node) -> bool:
	var director := get_node_or_null("Enemies/WaveDirector")
	if director == null or not director.has_method("start_boss_direct"):
		push_error("Boss 直战台：找不到正式 WaveDirector 直战入口")
		return false
	var spawned := bool(director.call("start_boss_direct", trial_seed))
	for _retry in range(24):
		if spawned:
			break
		await get_tree().process_frame
		# 不重置随机流；继续通过正式投放规则寻找安全位置。
		spawned = bool(director.call("start_boss_direct"))
	return spawned


func _warmup_boss_materials(player: Node3D, titan: Node3D) -> void:
	# 正式导演已投放同一个 Boss；暂停下临时显示完整模型，再恢复出土姿态。
	# 复用原空中碎土 / 阴影，地面特效另建临时视觉实例；不执行攻击、伤害或结算。
	var preview := Node3D.new()
	preview.name = "BossMaterialWarmup"
	add_child(preview)
	var spawn_y: float = titan.visual_root.position.y
	titan.visual_root.position.y = titan.STANDING_VISUAL_Y
	var player_camera := get_viewport().get_camera_3d()
	var camera := Camera3D.new()
	preview.add_child(camera)
	var focus := (player.global_position + titan.global_position) * 0.5
	camera.global_position = focus + Vector3(0.0, 24.0, 24.0)
	camera.look_at(focus)
	camera.make_current()
	var particles: CPUParticles3D = titan._air_debris
	var particle_mode := particles.process_mode
	var particle_preprocess := particles.preprocess
	particles.process_mode = Node.PROCESS_MODE_ALWAYS
	particles.preprocess = 0.2
	particles.emitting = true
	var area := WarmupArea.new()
	preview.add_child(area)
	var center := player.global_position - Vector3.UP
	if is_instance_valid(player_camera):
		# 玩家脚下可能在第三人称镜头的近端盲区；把纯视觉预热放在正式视野前方。
		var forward := -player_camera.global_basis.z
		forward.y = 0.0
		center += forward.normalized() * 8.0
		var query := PhysicsRayQueryParameters3D.create(center + Vector3.UP * 8.0,
			center + Vector3.DOWN * 8.0, 1)
		var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			center = hit.position
	# 空中贴地阴影也用同一真实实例预热，结束后恢复原位置和隐藏状态。
	var shadow: MeshInstance3D = titan._flight_shadow
	var shadow_pose := shadow.global_transform
	shadow.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3(2.5, 1.0, 2.5)),
		center + Vector3.UP * 0.16)
	shadow.visible = true
	area.prepare(Transform3D(Basis.IDENTITY, center), {"kind": "circle", "radius": 8.25,
		"height": 5.0, "source_height": 0.2}, 0.0)
	area.lock()
	area.set_progress(0.5)
	var dust := WarmupGround.spawn(preview, center, 8.25, 1.0, true, 0.0, true, area.get_surface())
	dust.process_mode = Node.PROCESS_MODE_DISABLED
	dust._dust.visible = true
	var sweep := WarmupMelee.spawn(preview, area.global_transform, {"kind": "sector",
		"radius": 8.25, "angle": 360.0, "surface": area.get_surface(), "material_warmup": true},
		1.65, true, 0.3, 0.0)
	sweep.process_mode = Node.PROCESS_MODE_DISABLED
	sweep.set_progress(0.5)
	var slam := WarmupMelee.spawn(preview, area.global_transform, {"kind": "rect",
		"width": 4.0, "length": 10.0, "offset": 0.0,
		"surface": area.get_surface(), "material_warmup": true}, 1.65, false, 0.1, 0.0)
	slam.process_mode = Node.PROCESS_MODE_DISABLED
	for _frame in range(6):
		await get_tree().process_frame
	if is_instance_valid(player_camera):
		player_camera.make_current()
	# 尘浪运行时会变成横向扩张、纵向压扁的形状；只画初始单位缩放没有
	# 覆盖该首次绘制组合。用同一视觉更新函数采样，不推进世界或技能计时。
	dust._physics_process(0.25)
	for _frame in range(6):
		await get_tree().process_frame
	particles.emitting = false
	particles.preprocess = particle_preprocess
	particles.process_mode = particle_mode
	shadow.visible = false
	shadow.global_transform = shadow_pose
	titan.visual_root.position.y = spawn_y
	if is_instance_valid(player_camera):
		player_camera.make_current()
	# 回收节点，但保留这局用过的网格 / 材质。若最后一份临时材质也释放，
	# 下次动态创建相同尘浪仍可能重新生成 Shader 与绘制流水线。
	for visual: GeometryInstance3D in preview.find_children("*", "GeometryInstance3D", true, false):
		if visual.material_override != null:
			_warmup_resources.append(visual.material_override)
		var mesh: Mesh
		if visual is MeshInstance3D:
			mesh = visual.mesh
		elif visual is MultiMeshInstance3D and visual.multimesh != null:
			_warmup_resources.append(visual.multimesh)
			mesh = visual.multimesh.mesh
		if mesh != null:
			_warmup_resources.append(mesh)
			for index in range(mesh.get_surface_count()):
				var material := mesh.surface_get_material(index)
				if material != null:
					_warmup_resources.append(material)
	preview.queue_free()
	await get_tree().process_frame


func _show_loading() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = "BossTrialLoading"
	layer.layer = 120
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.035, 0.045, 0.05, 0.94)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(panel)
	var label := Label.new()
	label.text = "正在准备圣所…\nC 共鸣 · R 换弹 · F5 重新挑战"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", 22)
	layer.add_child(label)
	return layer


## 直接操作玩家持有的正式 PlayerWeapon；不构造实验版武器，也不伪造 HUD 数字。
func refill_player_ammo(player: Node) -> Dictionary:
	if player == null:
		return {}
	var weapon: Node = player.get("_weapon") as Node
	if weapon == null or not weapon.has_method("refill_all_ammo"):
		return {}
	weapon.call("refill_all_ammo")
	return weapon.call("get_combat_snapshot") as Dictionary


func _show_notice(player: Node) -> void:
	var hud: Node = player.get("_hud") as Node
	if hud != null and hud.has_method("show_notice"):
		hud.call("show_notice", "◆ C 共鸣 · R 换弹 · F5 重开 ◆", "upgrade")


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if key.pressed and not key.echo and (key.physical_keycode == KEY_F5 or key.keycode == KEY_F5):
		get_viewport().set_input_as_handled()
		get_tree().reload_current_scene()


func _exit_tree() -> void:
	if is_instance_valid(_configured_flow):
		_configured_flow.remove_meta(&"experiment_silent_pause")
	super._exit_tree()
