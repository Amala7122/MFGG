extends Node
signal active_changed(active: bool)
## F4临时开发显示。只改绘制覆盖，不改碰撞 / 导航 / 敌人 / 伤害或天气配置。
const Settings := preload("res://scripts/greybox_settings.gd")
const Palette := preload("res://scripts/greybox_palette.gd")
const WispScript := preload("res://scripts/floating_wisp.gd")
const WEATHER_SCRIPTS := ["weather_system.gd","weather_rain_controller.gd","Sky3D.gd","SkyDome.gd","TimeOfDay.gd"]
const PROTECTED_SCRIPTS := ["enemy_attack_area.gd","telegraph.gd","ground_warning.gd","player_shield_fx.gd",
	"player_melee.gd","resonance_ability.gd","resonance.gd","enemy_bullet.gd","bullet.gd","grenade.gd",
	"mortar_shell.gd","enemy_death_fx.gd","destruction_debris.gd","impact_spark.gd","shell_casing.gd","floating_wisp.gd"]
var is_active := false
var parameters: Dictionary = {}
var palette: RefCounted
var _scene: Node
var _overrides: Dictionary = {}
var _hidden: Dictionary = {}
var _frozen: Dictionary = {}
var _lights: Dictionary = {}
var _cameras: Dictionary = {}
var _wisp_materials: Dictionary = {} # 原材质 -> 灰模副本与使用计数；共享材质每帧只同步一次。
var _dust: Dictionary = {} # 粒子的原 / 灰模色带；不改粒子模拟或脚步逻辑。
var _studio: Environment
var _sun: DirectionalLight3D
var _generation := 0
var _panel: CanvasLayer

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	palette = Palette.new()
	_studio = Environment.new()
	_studio.background_mode = Environment.BG_COLOR
	_studio.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_studio.ambient_light_color = Color(0.58,0.60,0.63)
	_studio.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_studio.ambient_light_sky_contribution = 0.0
	_studio.ssao_intensity = 2.4
	_studio.ssao_radius = 1.3
	_studio.ssao_power = 1.5
	_studio.tonemap_exposure = 1.0
	_sun = DirectionalLight3D.new()
	_sun.name = "GreyboxStudioLight"
	_sun.light_color = Color(1.0,0.98,0.95)
	_sun.rotation_degrees = Vector3(-50,-30,0)
	_sun.shadow_enabled = true
	_sun.visible = false
	add_child(_sun)
	apply_parameters(Settings.load_values())
	_panel = preload("res://scripts/greybox_panel.gd").new()
	_panel.setup(self)
	add_child(_panel)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	active_changed.connect(_refresh_menu)
	set_process(false)

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode != KEY_F4 or _other_modal():
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	toggle()
	get_viewport().set_input_as_handled()

func _other_modal() -> bool:
	var flow := get_node_or_null("/root/GameFlow")
	if flow == null: return false
	for key in [&"player_melee_tuning_modal", &"player_visual_tuning_modal", &"sketch_tuning_modal", &"greybox_tuning_modal", &"workspace_global_modal"]:
		if bool(flow.get_meta(key,false)): return true
	return false

func toggle() -> void:
	if is_active: deactivate()
	else: activate()

func activate() -> void:
	if is_active: return
	is_active = true
	_generation += 1
	get_node("/root/PostProcess").set_debug_bypass(true)
	_attach_scene(get_tree().current_scene)
	set_process(true)
	active_changed.emit(true)
	print("[灰模] 开启 · F4返回原画 · F10调参；天气时钟暂时冻结")

func deactivate() -> void:
	if not is_active: return
	is_active = false
	_generation += 1
	_release_scene()
	get_node("/root/PostProcess").set_debug_bypass(false)
	set_process(false)
	active_changed.emit(false)
	print("[灰模] 关闭 · 恢复原材质、相机环境与天气处理状态")

func apply_parameters(values: Dictionary) -> void:
	var valid := Settings.validate(values)
	if valid.is_empty(): return
	parameters = valid
	palette.configure(valid)
	_studio.background_color = _color(valid.studio_background)
	_studio.ambient_light_energy = valid.ambient_energy
	_studio.ssao_enabled = bool(valid.ssao_enabled)
	_sun.light_energy = valid.light_energy
	for node in _dust:
		if is_instance_valid(node): _dust_visibility(node)

func _color(value: Array) -> Color:
	return Color(value[0],value[1],value[2],1.0)

func _refresh_menu(_active: bool) -> void:
	var flow := get_node_or_null("/root/GameFlow")
	if flow != null and flow.state == flow.State.DISPLAY_SETTINGS:
		flow._enter_display_settings(5)

func _apply_camera(camera: Camera3D) -> void:
	if camera.get_viewport() != get_viewport(): return
	if camera.environment != _studio:
		# 如果外部在灰模期间明确更换了原相机环境，保留最新选择供退出时恢复。
		_cameras[camera] = camera.environment
		camera.environment = _studio

func _process(_delta: float) -> void:
	if get_tree().current_scene != _scene:
		_release_scene()
		_attach_scene(get_tree().current_scene)
	var camera := get_viewport().get_camera_3d()
	if is_instance_valid(camera) and is_instance_valid(_scene) and _scene.is_ancestor_of(camera):
		_apply_camera(camera)
	# 保留原天气调试入口（它也承载F1敌人冻结）。手动F3可能刷新天空的
	# 灯 / 雾可见性；只维护已接管的少量显示节点，不扫描世界或触碰敌人。
	for node in _hidden:
		if is_instance_valid(node): node.visible = false
	for node in _lights:
		if is_instance_valid(node): node.visible = false
	for source in _wisp_materials:
		_sync_wisp(source)

func _attach_scene(scene: Node) -> void:
	if not is_instance_valid(scene): return
	_scene = scene
	_scene.tree_exiting.connect(_release_scene, CONNECT_ONE_SHOT)
	_visit(scene)
	_sun.visible = true
	var camera := get_viewport().get_camera_3d()
	if is_instance_valid(camera) and _scene.is_ancestor_of(camera): _apply_camera(camera)

func _release_scene() -> void:
	if is_instance_valid(_panel) and _panel.opened: _panel.close()
	if is_instance_valid(_scene) and _scene.tree_exiting.is_connected(_release_scene):
		_scene.tree_exiting.disconnect(_release_scene)
	for node in _overrides:
		if is_instance_valid(node) and node.material_override == _overrides[node].applied:
			node.material_override = _overrides[node].original
	for node in _dust:
		if is_instance_valid(node) and node.color_ramp == _dust[node].applied:
			node.color_ramp = _dust[node].original
	for node in _hidden:
		if is_instance_valid(node) and not node.visible: node.visible = _hidden[node]
	for node in _cameras:
		if is_instance_valid(node) and node.environment == _studio: node.environment = _cameras[node]
	for node in _lights:
		if is_instance_valid(node) and not node.visible: node.visible = _lights[node]
	for node in _frozen:
		if is_instance_valid(node) and node.process_mode == Node.PROCESS_MODE_DISABLED: node.process_mode = _frozen[node]
	_overrides.clear()
	_hidden.clear()
	_cameras.clear()
	_lights.clear()
	_frozen.clear()
	_wisp_materials.clear()
	_dust.clear()
	_scene = null
	_sun.visible = false

func _on_node_added(node: Node) -> void:
	if is_active and (node is GeometryInstance3D or node is Camera3D or node is Light3D or node.get_script() != null):
		call_deferred("_apply_added", weakref(node), _generation)

func _apply_added(reference: WeakRef, generation: int) -> void:
	var node: Node = reference.get_ref()
	if not is_active or generation != _generation or not is_instance_valid(node) or not is_instance_valid(_scene): return
	if node != _scene and not _scene.is_ancestor_of(node): return
	_visit(node)

func _on_node_removed(node: Node) -> void:
	if _overrides.has(node) and _overrides[node].has("wisp_source"):
		var source: BaseMaterial3D = _overrides[node].wisp_source
		_wisp_materials[source].users -= 1
		if _wisp_materials[source].users == 0: _wisp_materials.erase(source)
	if _overrides.has(node) and is_instance_valid(node) and node.material_override == _overrides[node].applied:
		node.material_override = _overrides[node].original
	if _dust.has(node) and is_instance_valid(node) and node.color_ramp == _dust[node].applied:
		node.color_ramp = _dust[node].original
	if _hidden.has(node) and is_instance_valid(node) and not node.visible: node.visible = _hidden[node]
	if _lights.has(node) and is_instance_valid(node) and not node.visible: node.visible = _lights[node]
	if _frozen.has(node) and is_instance_valid(node) and node.process_mode == Node.PROCESS_MODE_DISABLED: node.process_mode = _frozen[node]
	if _cameras.has(node) and is_instance_valid(node) and node.environment == _studio:
		node.environment = _cameras[node]
	for cache in [_overrides,_hidden,_cameras,_lights,_frozen,_dust]: cache.erase(node)

func _script_name(node: Node) -> String:
	var script: Script = node.get_script()
	return script.resource_path.get_file() if script else ""

func _visit(node: Node) -> void:
	if node is CanvasLayer or node is Control or node is SubViewport: return
	if node is Camera3D: _apply_camera(node)
	if node is MeshInstance3D and String(node.name)=="_FogMeshI" and _script_name(node.get_parent())=="SkyDome.gd":
		_hide(node)
		return
	var source := _script_name(node)
	var fx := _fx_kind(node)
	if source in WEATHER_SCRIPTS:
		if not _frozen.has(node):
			_frozen[node] = node.process_mode
			node.process_mode = Node.PROCESS_MODE_DISABLED
		if source in ["weather_system.gd","weather_rain_controller.gd"] and node is Node3D: _hide(node)
	if node is Light3D and node != _sun:
		# 弹体 / 卫士无论是否挂在玩家下都不投彩光；不关闭其业务脚本。
		var fx_light := fx in ["enemy_bullet","wisp","wisp_dart"]
		if (fx_light or ((node is DirectionalLight3D or not _protected(node)) and _actor(node) != "player")) and not _lights.has(node):
			_lights[node] = node.visible
			node.visible = false
	if node is CPUParticles3D and fx == "dust":
		_apply_dust(node)
		return
	if node is Node3D and _decor(node):
		_hide(node)
		return
	var fx_mesh := fx in ["enemy_bullet","wisp","wisp_dart"]
	if (node is MeshInstance3D or node is MultiMeshInstance3D or (node is CPUParticles3D and fx == "wisp")) and (fx_mesh or not _protected(node)):
		if not _overrides.has(node):
			var material: Material
			var original: Material = node.material_override
			if fx in ["enemy_bullet","wisp_dart"]:
				material = palette.for_projectile(String(node.name).to_lower())
			elif fx == "wisp" and original is BaseMaterial3D:
				material = _wisp_material(original)
			else:
				material = palette.for_role(_role(node), String(node.name).to_lower())
			_overrides[node] = {"original":node.material_override,"applied":material}
			if fx == "wisp" and original is BaseMaterial3D: _overrides[node].wisp_source = original
			node.material_override = material
	for child in node.get_children(): _visit(child)

func _fx_kind(node: Node) -> String:
	var current := node
	while current != null and current != get_tree().root:
		# 内嵌GDScript的resource_path可能带子资源后缀，用实际脚本身份识别钉弹。
		if current.get_script() == WispScript.WispDart: return "wisp_dart"
		match _script_name(current):
			"enemy_bullet.gd": return "enemy_bullet"
			"floating_wisp.gd": return "wisp"
			"ground_dust.gd": return "dust"
		current = current.get_parent()
	return ""

func _wisp_material(source: BaseMaterial3D) -> Material:
	if not _wisp_materials.has(source):
		_wisp_materials[source] = {"applied":source.duplicate(),"users":0,"signature":[]}
		_sync_wisp(source)
	_wisp_materials[source].users += 1
	return _wisp_materials[source].applied

func _sync_wisp(source: BaseMaterial3D) -> void:
	var entry: Dictionary = _wisp_materials[source]
	var signature := [source.albedo_color,source.emission_enabled,source.emission_energy_multiplier,source.shading_mode]
	if signature != entry.signature:
		palette.sync_wisp(source,entry.applied)
		entry.signature = signature

func _apply_dust(node: CPUParticles3D) -> void:
	if not _dust.has(node):
		var original := node.color_ramp
		if original == null: return
		var neutral := original.duplicate() as Gradient
		for index in neutral.get_point_count():
			var color := neutral.get_color(index)
			neutral.set_color(index,Color(0.48,0.48,0.48,color.a * 0.55))
		_dust[node] = {"original":original,"applied":neutral}
		node.color_ramp = neutral
	_dust_visibility(node)

func _dust_visibility(node: CPUParticles3D) -> void:
	if not bool(parameters.show_dust): _hide(node)
	elif _hidden.has(node):
		if not node.visible: node.visible = _hidden[node]
		_hidden.erase(node)

func _hide(node: Node3D) -> void:
	if not _hidden.has(node):
		_hidden[node] = node.visible
		node.visible = false

func _decor(node: Node) -> bool:
	# 不隐藏WorldDecor父层：它还含有FieldBoulders及碰撞。树干 / 树冠也保留。
	return _script_name(node) == "grass_field.gd" or String(node.name) in ["Flowers","GroundPebbles","DistantPines","MeadowColonies","MeadowShrubs"]

func _protected(node: Node) -> bool:
	var current := node
	while current != null and current != get_tree().root:
		if current is CanvasLayer or current is Control or current is SubViewport: return true
		if _script_name(current) in PROTECTED_SCRIPTS or _script_name(current) in WEATHER_SCRIPTS: return true
		if current.is_in_group("enemy_telegraphs") or current.is_in_group("ground_hazards") or current.is_in_group("enemy_death_fx"): return true
		if _decor(current): return true
		var lower := String(current.name).to_lower()
		for token in ["telegraph","warning","hazard","attackarea","energyshield","muzzle","tracer","bullet","particle","resonance","crystalfire","headcrystal"]:
			if lower.contains(token): return true
		current = current.get_parent()
	return false

func _actor(node: Node) -> String:
	var current := node
	while current != null and current != _scene:
		if current.is_in_group("player"): return "player"
		if current.is_in_group("enemies") or current.is_in_group("dynamic_enemies"): return "enemy"
		if _script_name(current) in ["procedural_sediment_titan.gd","procedural_mud_golem.gd","procedural_fast_beast.gd","procedural_hornet.gd"]: return "enemy"
		current = current.get_parent()
	return ""

func _role(node: Node) -> String:
	var actor := _actor(node)
	if not actor.is_empty(): return actor
	var current := node
	while current != null and current != _scene:
		var lower := String(current.name).to_lower()
		if lower.contains("paving") or lower.contains("embedded"): return "paving"
		if lower.contains("road") or lower.contains("path"): return "road"
		if lower.contains("terrain") or lower == "ground": return "ground"
		if lower.contains("crown"): return "crown"
		if lower.contains("tree") or lower.contains("trunk") or lower.contains("grove") or lower.contains("wood"): return "wood"
		if lower.contains("shrine") or lower.contains("beacon") or lower.contains("pickup") or lower.contains("crystal"): return "accent"
		current = current.get_parent()
	return "obstacle"

func _exit_tree() -> void:
	if is_instance_valid(_studio): _release_scene()
