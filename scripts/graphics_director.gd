extends Node
## 画质与氛围总管。
##
## ── 为什么必须是 autoload ──────────────────────────────────────
##
## 它要作用在两类东西上，而它们的生命周期各不相同：
##
##   1. 根视口              —— 全程都在（启动时设一次）
##   2. 场景里的环境与主光  —— 每次换图都重建
##
## 放进 autoload，才能在"任何一方建好之后"统一去设一遍；
## 否则就得让这两处各自记着"我也要设一下画质"，迟早漏一处。
##
## ── 一条约定：没配 = 不动 ──────────────────────────────────────
##
## 氛围预设里缺的字段一律跳过，不写回默认值。这样"只想改雾的颜色"不需要把
## 十几个值抄一遍，也不会顺手把别人调好的值冲掉。
##
## ── 顺序：先画质档位，再竞技场氛围 ─────────────────────────────
##
## 两者都会碰色调分级（档位给基线，竞技场给倾向），竞技场那份更具体，
## 所以让它后写、覆盖档位。反过来会出现"改了大半天竞技场饱和度没生效"。
##
## ── 本文件里的数值都不是拍脑袋 ─────────────────────────────────
##
## 它们是在"打开抗锯齿 + SSAO"之后用来把画面从"平"拉回来的值。
## 单看某一项可能觉得偏：比如对比 1.06、饱和 1.12 —— 因为抗锯齿会让边缘变柔、
## SSAO 会让暗部变多，整体观感本来是往"灰"的方向走的。

const ConfigUtil := preload("res://scripts/game_config.gd")
const ArenaUtil := preload("res://scripts/arena.gd")

## 程序化天空着色器。它是本项目的第一个着色器，也是唯一一个 —— 除了它
## 与后续地形切面化用到的顶点色之外，其余表现一律走 StandardMaterial3D。
##
## 【加载失败一律退回场景自带材质】—— 天空坏掉不该让游戏打不开，
## 更不该留一块粉色（shader 编译失败时的占位色）在画面上。
const SKY_SHADER_PATH := "res://shaders/procedural_sky.gdshader"
const SKY3D_SCRIPT_PATH := "res://addons/sky_3d/src/Sky3D.gd"
static var _sky_shader: Shader
static var _sky_shader_loaded := false

## 当前档位名（low / medium / high）。启动时读一次。
var _tier := "high"
var _preset: Dictionary = {}


func _ready() -> void:
	_tier = ConfigUtil.get_string("graphics.active", "high")
	_preset = ConfigUtil.get_dictionary("graphics.presets.%s" % _tier)
	if _preset.is_empty():
		# 档位名写错不静默：退回 high 并明确报错，方便发现配置写歪。
		push_error("Graphics: 未知的画质档位 %s（应为 low / medium / high），已退回 high" % _tier)
		_tier = "high"
		_preset = ConfigUtil.get_dictionary("graphics.presets.high")
	apply_to_viewport(get_tree().root)
	# 首个场景在 autoload 之后才进树，所以这一发要延后一帧。
	call_deferred("apply_to_scene")
	# 【刻意不用 current_scene_changed】—— SceneTree 上没有这个信号（实测报
	# "Invalid access to property or key"）。用 node_added 精确捕捉世界环境进树
	# 的那一刻：场景里唯一必须等的就是它，其余节点找不找得到都无所谓。
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if not (node is WorldEnvironment):
		return
	# 主光与环境在同一个场景里，但进树顺序不保证 —— 延后一帧，
	# 让整个场景都挂好之后再去找它们。
	call_deferred("apply_to_scene")


## 给任意视口套用抗锯齿。
func apply_to_viewport(viewport: Viewport) -> void:
	if viewport == null or _preset.is_empty():
		return
	viewport.msaa_3d = int(_preset.get("msaa", Viewport.MSAA_2X))


## 把画质档位与当前竞技场的氛围应用到场景上。
func apply_to_scene() -> void:
	var scene := get_tree().current_scene if is_inside_tree() else null
	if scene == null:
		return
	var world_env := _find_environment(scene)
	if world_env != null and world_env.environment != null:
		_apply_quality(world_env.environment)
		if _is_sky3d(world_env):
			_apply_sky3d_arena(world_env, scene)
		else:
			_apply_arena(world_env.environment, scene)


# ---------------------------------------------------------------- 画质档位

func _apply_quality(env: Environment) -> void:
	# SSAO：让物体接触处出现阴影。不开的话所有东西都像浮在地面上。
	var ssao := bool(_preset.get("ssao", true))
	env.ssao_enabled = ssao
	if ssao:
		env.ssao_intensity = float(_preset.get("ssao_intensity", 1.8))
		env.ssao_radius = float(_preset.get("ssao_radius", 1.1))
		env.ssao_power = float(_preset.get("ssao_power", 1.4))
		env.ssao_detail = float(_preset.get("ssao_detail", 0.5))
		# 只让环境光受影响，不参与直接光照 —— 否则亮面会出现脏斑。
		env.ssao_light_affect = 0.25
		env.ssao_ao_channel_affect = 0.0

	# 体积雾：阳光在空气里形成光柱。代价偏高，只在高档开。
	env.volumetric_fog_enabled = bool(_preset.get("volumetric_fog", false))
	if env.volumetric_fog_enabled:
		env.volumetric_fog_density = float(_preset.get("volumetric_fog_density", 0.012))
		env.volumetric_fog_length = float(_preset.get("volumetric_fog_length", 120.0))
		env.volumetric_fog_ambient_inject = 0.35

	var tonemap := ConfigUtil.get_dictionary("graphics.tonemap")
	env.tonemap_exposure = float(tonemap.get("exposure", 1.0))
	env.glow_enabled = bool(_preset.get("glow", true))
	if env.glow_enabled:
		env.glow_intensity = float(tonemap.get("glow_intensity", 0.5))
		env.glow_bloom = float(tonemap.get("glow_bloom", 0.05))
		env.glow_hdr_threshold = 0.85
	env.adjustment_enabled = bool(_preset.get("adjustment", true))
	if env.adjustment_enabled:
		env.adjustment_saturation = float(tonemap.get("saturation", 1.1))
		env.adjustment_contrast = float(tonemap.get("contrast", 1.05))

	_apply_shadow_quality(env)


## 阴影质量。档位同时决定"分几块投"与"投多远"。
##
## 低档把最大距离压到 60 米：省得最多，而代价只是远处的影子消失 ——
## 远景本来就有雾挡着，看不出少了什么。
func _apply_shadow_quality(env: Environment) -> void:
	var quality := clampi(int(_preset.get("shadow_quality", 1)), 0, 2)
	var distance := float(_preset.get("shadow_max_distance", 80.0))
	# 显式标 float：数组下标返回 Variant，类型推不出来（编译期就报错）。
	var blur: float = [0.5, 0.45, 0.4][quality]
	# 环境本身不持有主光，所以阴影参数在主光上，这里只把两个值记在 metadata 上，
	# 由 _apply_arena 在主光上落地 —— 避免同一份档位值在两处各读一遍。
	env.set_meta("graphics_shadow_quality", quality)
	env.set_meta("graphics_shadow_distance", distance)
	env.set_meta("graphics_shadow_blur", blur)
	env.set_meta("graphics_shadow_bias", 0.1)
	env.set_meta("graphics_shadow_normal_bias", 0.15)


# ---------------------------------------------------------------- 竞技场氛围

## 应用当前竞技场的氛围。
##
## 只覆盖配置里【写过】的字段。没写的保持场景当前值 —— 于是
## "只想把沙丘的雾调浓"就只写一行 fog_density，不必抄十几个值。
func _apply_arena(env: Environment, scene: Node) -> void:
	var preset := ConfigUtil.get_dictionary("lighting.arenas.%s" % ArenaUtil.resolve_id())
	if preset.is_empty():
		# 没配氛围的竞技场不是错误（新增地图时可以暂缺），保持场景原样即可。
		_apply_lights(scene, {})
		return
	_apply_sky(env, scene, preset)
	_apply_ambient(env, preset)
	_apply_fog(env, preset)
	_apply_grading(env, preset)
	_apply_lights(scene, preset)


## Sky3D 场景的职责边界：Sky3D 独占天空材质、天体和时间，
## Graphics 只继续提供项目统一的画质档位、竞技场色调与低模补光。
##
## 不能让它走上面的普通路径：_apply_sky() 会把 Sky3D 自带 Shader 换成项目旧
## Shader，月亮、银河和大气散射会因此一起失效；_apply_fog() 还会叠加第二层雾。
func _apply_sky3d_arena(world_env: WorldEnvironment, scene: Node) -> void:
	var env := world_env.environment
	var preset := ConfigUtil.get_dictionary("lighting.arenas.%s" % ArenaUtil.resolve_id())
	var dome := world_env.get_node_or_null("SkyDome")
	# 只允许手电筒的局部 FogVolume 形成光柱，不恢复曾洗白全场景的全局体积雾。
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0
	env.volumetric_fog_length = 38.0
	env.volumetric_fog_ambient_inject = 0.0
	env.volumetric_fog_sky_affect = 0.0

	# 有 WeatherSystem 时，距离雾由它合成。画质管理器不能在场景加载后
	# 再把雨雾关掉；没有天气层的 Sky3D 场景仍使用天幕自身的雾。
	var weather := scene.find_child("WeatherSystem", true, false)
	if weather == null:
		env.fog_enabled = false
	if dome != null:
		if weather == null:
			dome.set("fog_visible", true)
		# 默认云的写实噪声与低多边形语言差异过大；银河和独立星点保持启用。
		dome.set("cirrus_visible", false)
		dome.set("cumulus_visible", false)
		if preset.has("sky_ground"):
			dome.set("ground_color", _color(preset.get("sky_ground"), Color(0.4, 0.52, 0.46)))
		if preset.has("sky_horizon"):
			dome.set("atm_day_tint", _color(preset.get("sky_horizon"), Color(0.76, 0.87, 0.96)))
		if preset.has("sun_color"):
			var sun_color := _color(preset.get("sun_color"), Color(1.0, 0.89, 0.7))
			dome.set("sun_light_color", sun_color)
		if preset.has("sun_energy"):
			dome.set("sun_light_energy", maxf(float(preset.get("sun_energy")), 0.0))

	if preset.has("ambient_energy"):
		# 原预设面向白天固定天空；动态夜景给低模切面留出最低可读环境光。
		env.ambient_light_energy = maxf(float(preset.get("ambient_energy")), 0.6)
	if preset.has("exposure"):
		env.tonemap_exposure = maxf(float(preset.get("exposure")), 0.01)
	_apply_grading(env, preset)

	var sun := world_env.get_node_or_null("SunLight") as DirectionalLight3D
	if sun != null:
		_apply_shadow_settings(sun)
	var moon := world_env.get_node_or_null("MoonLight") as DirectionalLight3D
	if moon != null:
		_apply_shadow_settings(moon)
	var fill := _find_light(scene, "FillLight")
	if fill != null and preset.has("fill_energy"):
		fill.light_energy = maxf(float(preset.get("fill_energy")), 0.0)
	# 场景初始化与画质设置完成后，按 Inspector 当前天气重算一次；
	# 主菜单可能暂停游戏，此时不能等天气节点的 _process 来纠正环境。
	if weather != null:
		weather.call_deferred("_update_environment")


## 环境光：整体"底色"的冷暖。它决定阴影里是什么颜色 —— 沙丘的阴影偏橙、
## 内城的阴影偏蓝，靠的都是这一项。
func _apply_ambient(env: Environment, preset: Dictionary) -> void:
	# 没配 ambient 就不碰环境光 —— 保持场景原值（可能继续用天空驱动）。
	var wants_manual := preset.has("ambient_color") or preset.has("ambient_energy")
	if not wants_manual:
		return
	# 【关键坑】ambient_light_source = SKY 时，ambient_light_sky_contribution 默认 = 1.0，
	# 环境光 100% 取自天空，ambient_light_color/energy 完全不生效（文档原文：
	# ambient light parameter has no effect）。必须先把天空贡献归零，下面两个
	# ambient 参数才能真正接管阴影的冷暖与明度，否则调 ambient_* 全是静默无效。
	env.ambient_light_sky_contribution = 0.0
	if preset.has("ambient_color"):
		env.ambient_light_color = _color(preset.get("ambient_color"), env.ambient_light_color)
	if preset.has("ambient_energy"):
		env.ambient_light_energy = maxf(float(preset.get("ambient_energy")), 0.0)


## 天空。
##
## 【旧实现里埋着一个静默失效的坑，这里必须绕开】—— 原先开头写的是
## `if not (env.sky.sky_material is ProceduralSkyMaterial): return`。
## 一旦材质换成自定义 ShaderMaterial（本项目的程序化天空就是），
## 四张竞技场的天空覆盖会【安静地全部失效】：没有任何报错，天空只是
## 永远停在着色器的默认值上，看起来像"预设没生效"却查不出原因。
## 现在两种材质都认，谁在就写谁。
func _apply_sky(env: Environment, scene: Node, preset: Dictionary) -> void:
	if env.sky == null:
		return
	var material := _resolve_sky_material(env)
	if material is ShaderMaterial:
		_apply_sky_shader(material as ShaderMaterial, preset)
	elif material is ProceduralSkyMaterial:
		var sky := material as ProceduralSkyMaterial
		if preset.has("sky_top"):
			sky.sky_top_color = _color(preset.get("sky_top"), sky.sky_top_color)
		if preset.has("sky_horizon"):
			sky.sky_horizon_color = _color(preset.get("sky_horizon"), sky.sky_horizon_color)


## 决定这次用哪个天空材质。
##
## 总开关关掉、shader 资源缺失、或资源类型不对时，直接返回场景原本的材质 ——
## 于是"关掉程序化天空"这条路与改动前逐值相同，任何时候都能一行回退做对比。
func _resolve_sky_material(env: Environment) -> Material:
	var shader := _load_sky_shader()
	if shader == null:
		return env.sky.sky_material
	var existing := env.sky.sky_material
	if existing is ShaderMaterial and (existing as ShaderMaterial).shader == shader:
		return existing
	var material := ShaderMaterial.new()
	material.shader = shader
	env.sky.sky_material = material
	return material


func _load_sky_shader() -> Shader:
	if _sky_shader_loaded:
		return _sky_shader
	_sky_shader_loaded = true
	if not ConfigUtil.get_bool("graphics.procedural_sky", true):
		return null
	if not ResourceLoader.exists(SKY_SHADER_PATH):
		push_error("Graphics: 找不到 %s，天空退回场景自带材质。" % SKY_SHADER_PATH)
		return null
	var loaded: Resource = load(SKY_SHADER_PATH)
	if not (loaded is Shader):
		push_error("Graphics: %s 不是 Shader，天空退回场景自带材质。" % SKY_SHADER_PATH)
		return null
	_sky_shader = loaded as Shader
	return _sky_shader


## 逐项写 uniform。
##
## 没配的键【一律不写】—— 这与本文件一贯的"没配 = 不动"约定一致，
## 好处是竞技场预设只需要写它想改的那几个值，其余自动保持着色器里
## 声明好的默认值，不用把十几个 uniform 抄一遍。
func _apply_sky_shader(material: ShaderMaterial, preset: Dictionary) -> void:
	_set_sky_color(material, "u_top_color", preset, "sky_top")
	_set_sky_color(material, "u_mid_color", preset, "sky_mid")
	_set_sky_color(material, "u_horizon_color", preset, "sky_horizon")
	_set_sky_color(material, "u_ground_color", preset, "sky_ground")
	_set_sky_color(material, "u_cloud_light", preset, "cloud_light")
	_set_sky_color(material, "u_cloud_shadow", preset, "cloud_shadow")
	_set_sky_color(material, "u_sun_glow", preset, "sun_glow")
	_set_sky_number(material, "u_mid_stop", preset, "sky_mid_stop")
	_set_sky_number(material, "u_horizon_width", preset, "sky_horizon_width")
	_set_sky_number(material, "u_horizon_gain", preset, "sky_horizon_gain")
	_set_sky_number(material, "u_cloud_amount", preset, "cloud_amount")
	_set_sky_number(material, "u_cloud_scale", preset, "cloud_scale")
	_set_sky_number(material, "u_cloud_flatten", preset, "cloud_flatten")
	_set_sky_number(material, "u_cloud_threshold", preset, "cloud_threshold")
	_set_sky_number(material, "u_cloud_sharpness", preset, "cloud_sharpness")
	_set_sky_number(material, "u_cloud_floor", preset, "cloud_floor")
	_set_sky_number(material, "u_cloud_ceiling", preset, "cloud_ceiling")
	_set_sky_number(material, "u_sun_glow_power", preset, "sun_glow_power")
	_set_sky_number(material, "u_sun_glow_strength", preset, "sun_glow_strength")


func _set_sky_color(
	material: ShaderMaterial, uniform: String, preset: Dictionary, key: String
) -> void:
	if preset.has(key):
		material.set_shader_parameter(uniform, _color(preset.get(key), Color.WHITE))


func _set_sky_number(
	material: ShaderMaterial, uniform: String, preset: Dictionary, key: String
) -> void:
	if preset.has(key):
		material.set_shader_parameter(uniform, float(preset.get(key)))


## 把场景主光的方向喂给天空着色器，让阴天那点方向性提亮出现在正确的一侧。
##
## DirectionalLight3D 沿自身 -Z 照射，所以"指向太阳"就是 +Z。
## 刻意不读 sky shader 的 LIGHT0_* 内置量：那会引入一处编译期依赖，
## 而这里的太阳只是"一片很软的方向性提亮"，不值得为它赌兼容性。
func _apply_sky_sun_direction(scene: Node, sun: DirectionalLight3D) -> void:
	if _sky_shader == null:
		return
	var world_env := _find_environment(scene)
	if world_env == null or world_env.environment == null or world_env.environment.sky == null:
		return
	var material := world_env.environment.sky.sky_material
	if not (material is ShaderMaterial):
		return
	var shader_material := material as ShaderMaterial
	if shader_material.shader != _sky_shader:
		return
	shader_material.set_shader_parameter(
		"u_sun_direction", sun.global_basis.z.normalized()
	)


## 气雾。
##
## 【这一项就是本项目"空间纵深"的全部来源】—— 目标是四段：
##   0~50m 几乎无雾 / 50~200m 开始降对比 / 200~500m 明显蓝灰化 / 500m+ 只剩剪影
## 四段分别落在四个旋钮上：
##
##   fog_depth_begin / fog_depth_end  「从哪开始起雾、到哪饱和」
##   fog_depth_curve                  「近场有多干净、中段爬升多陡」
##   fog_aerial_perspective           「远景是被糊成一片白，还是被天空色吃掉」
##   fog_sky_affect                   「连天空本身要不要一起发灰」
##
## 【关键选择一：用 depth 模式而不是 exponential】
## exponential 是"一出门就开始积雾"，近景也会被蒙上一层，于是"近景高对比、
## 轮廓清楚"这条要求根本做不到。depth 模式可以明确地"前 50 米一点都不加"。
##
## 【关键选择二：fog_sky_affect 要【调低】而不是调高】
## 它控制的是"雾遮住天空的程度"，1.0 = 天空被雾色整片盖掉。这一项一旦调高，
## 天空就会重新变成一块均匀灰 —— 恰恰是要避免的结果。远景的蓝灰化应该交给
## fog_aerial_perspective（让远景取天空自身的辐射色），而不是把天空也糊掉。
func _apply_fog(env: Environment, preset: Dictionary) -> void:
	if preset.has("fog_color"):
		env.fog_light_color = _color(preset.get("fog_color"), env.fog_light_color)
	if preset.has("fog_density"):
		env.fog_density = maxf(float(preset.get("fog_density")), 0.0)
	if preset.has("fog_mode"):
		env.fog_mode = (
			Environment.FOG_MODE_DEPTH
			if String(preset.get("fog_mode")) == "depth"
			else Environment.FOG_MODE_EXPONENTIAL
		)
	if preset.has("fog_energy"):
		env.fog_light_energy = maxf(float(preset.get("fog_energy")), 0.0)
	_set_env_number(env, "fog_depth_begin", preset, "fog_depth_begin")
	_set_env_number(env, "fog_depth_end", preset, "fog_depth_end")
	_set_env_number(env, "fog_depth_curve", preset, "fog_depth_curve")
	_set_env_number(env, "fog_aerial_perspective", preset, "fog_aerial_perspective")
	_set_env_number(env, "fog_sky_affect", preset, "fog_sky_affect")
	_set_env_number(env, "fog_sun_scatter", preset, "fog_sun_scatter")


## 只在属性真实存在时才写。
##
## 【为什么需要这道闸】—— Godot 里给 Environment 写一个不存在的属性【不会报错】，
## 只是静默不生效。那是最难查的一类失效：配置明明改了，画面却毫无反应，
## 于是会去怀疑雾的参数、怀疑渲染管线，就是不怀疑"这个名字根本不存在"。
## 统一走一次存在性检查，对不上时明确 warning，而不是安静地跳过。
func _set_env_number(env: Environment, property: String, preset: Dictionary, key: String) -> void:
	if not preset.has(key):
		return
	if not (property in env):
		push_warning("Graphics: Environment 上没有 %s，%s 已跳过。" % [property, key])
		return
	env.set(property, float(preset.get(key)))


## 色调分级里的"每个图的倾向"。竞技场这份写在档位基线之后，所以它说了算。
func _apply_grading(env: Environment, preset: Dictionary) -> void:
	if preset.has("exposure"):
		env.tonemap_exposure = maxf(float(preset.get("exposure")), 0.01)
	if not env.adjustment_enabled:
		return
	if preset.has("saturation"):
		env.adjustment_saturation = float(preset.get("saturation"))
	if preset.has("contrast"):
		env.adjustment_contrast = float(preset.get("contrast"))


func _apply_lights(scene: Node, preset: Dictionary) -> void:
	var sun := _find_light(scene, "Sun")
	if sun != null:
		if preset.has("sun_color"):
			sun.light_color = _color(preset.get("sun_color"), sun.light_color)
		if preset.has("sun_energy"):
			sun.light_energy = maxf(float(preset.get("sun_energy")), 0.0)
		_apply_shadow_settings(sun)
		# 天空那点方向性提亮必须跟着主光走，否则改了光照方向之后，
		# 天空的亮部会留在旧的一侧，天地光照互相矛盾。
		_apply_sky_sun_direction(scene, sun)
	var fill := _find_light(scene, "FillLight")
	if fill != null and preset.has("fill_energy"):
		fill.light_energy = maxf(float(preset.get("fill_energy")), 0.0)


## 主光的阴影参数来自画质档位（上一轮存在环境节点的 metadata 上）。
func _apply_shadow_settings(sun: DirectionalLight3D) -> void:
	var scene := sun.get_tree().current_scene if sun.is_inside_tree() else null
	if scene == null:
		return
	var env := _find_environment(scene)
	if env == null or env.environment == null:
		return
	var quality := int(env.environment.get_meta("graphics_shadow_quality", 1))
	sun.directional_shadow_mode = quality
	sun.shadow_blur = float(env.environment.get_meta("graphics_shadow_blur", 1.2))
	sun.directional_shadow_max_distance = float(
		env.environment.get_meta("graphics_shadow_distance", 80.0)
	)
	sun.shadow_bias = float(env.environment.get_meta("graphics_shadow_bias", 0.1))
	sun.shadow_normal_bias = float(
		env.environment.get_meta("graphics_shadow_normal_bias", 0.15)
	)


# ---------------------------------------------------------------- 查找与工具

## 场景里的世界环境节点。递归找是因为它不一定挂在场景根下。
func _find_environment(node: Node) -> WorldEnvironment:
	if node is WorldEnvironment:
		return node as WorldEnvironment
	for child in node.get_children():
		var found := _find_environment(child)
		if found != null:
			return found
	return null


func _is_sky3d(world_env: WorldEnvironment) -> bool:
	var attached: Script = world_env.get_script() as Script
	return attached != null and attached.resource_path == SKY3D_SCRIPT_PATH


func _find_light(node: Node, wanted: String) -> DirectionalLight3D:
	for candidate in node.get_children():
		if candidate.name == wanted and candidate is DirectionalLight3D:
			return candidate as DirectionalLight3D
		var found := _find_light(candidate, wanted)
		if found != null:
			return found
	return null


## [r,g,b] → Color。数组写错长度时退回 fallback，而不是拼出一个诡异的颜色。
func _color(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var parts := value as Array
		return Color(float(parts[0]), float(parts[1]), float(parts[2]))
	return fallback
