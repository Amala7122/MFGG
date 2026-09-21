class_name Shockwave
extends Node3D
## 震地脉冲（Q 键）：以玩家为中心向外扩散的能量环，对范围内敌人造成伤害并击退。
## 伤害在生成瞬间一次性结算，之后的扩散环只是表现。
##
## 与手雷不同：脉冲穿墙生效（require_line_of_sight = false），
## 定位是"贴身被围住时把敌人推开"的自救技。

const AudioUtil := preload("res://scripts/audio_manager.gd")
const ConfigUtil := preload("res://scripts/game_config.gd")

## 扩散时长来自 data/game_config.json 的 abilities.skill.expand_duration。
## 半径 / 伤害 / 击退由 player.gd 传入（它在 abilities.skill 段读好后传过来），
## 所以这三个的 DEFAULT_* 只是在没传参时才生效的兜底值。
const DEFAULT_EXPAND_DURATION := 0.5
const DEFAULT_RADIUS := 9.0
const DEFAULT_DAMAGE := 55.0
const DEFAULT_PUSH := 15.0

var _expand_duration := DEFAULT_EXPAND_DURATION
var _elapsed := 0.0
var _radius := DEFAULT_RADIUS
var _ring: MeshInstance3D
var _material: StandardMaterial3D
var _light: OmniLight3D
var _finished := false


## 结算伤害并生成扩散环。返回被命中的敌人数量。
func perform(radius: float = DEFAULT_RADIUS, damage: float = DEFAULT_DAMAGE, push: float = DEFAULT_PUSH) -> int:
	_expand_duration = maxf(
		ConfigUtil.get_float("abilities.skill.expand_duration", DEFAULT_EXPAND_DURATION), 0.05
	)
	_radius = maxf(radius, 0.5)
	AudioUtil.play_at("shockwave", global_position, -1.0)
	var hits := CombatFX.apply_radial_damage(self, global_position, _radius, damage, push, false)
	_build_visual()
	return hits


func _build_visual() -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = 0.83
	torus.outer_radius = 1.0
	torus.rings = 40
	torus.ring_segments = 8

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = Color(0.45, 0.85, 1.0, 0.85)
	_material.emission_enabled = true
	_material.emission = Color(0.3, 0.75, 1.0, 1.0)
	_material.emission_energy_multiplier = 6.0
	torus.material = _material

	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.scale = Vector3.ONE * (_radius * 0.2)
	add_child(_ring)

	_light = OmniLight3D.new()
	_light.light_color = Color(0.42, 0.82, 1.0, 1.0)
	_light.light_energy = 10.0
	_light.omni_range = _radius * 1.4
	_light.shadow_enabled = false
	add_child(_light)

	var flash := BlastFlash.new()
	add_child(flash)
	flash.trigger(Color(0.4, 0.8, 1.0, 1.0), _radius * 0.55, 0.3)


func _process(delta: float) -> void:
	if _finished:
		return
	_elapsed += delta
	var progress := _elapsed / _expand_duration
	if progress >= 1.0:
		_finished = true
		queue_free()
		return
	var fade := 1.0 - progress
	var eased := 1.0 - pow(1.0 - progress, 2.2)
	if _ring:
		_ring.scale = Vector3.ONE * lerpf(_radius * 0.2, _radius, eased)
	if _material:
		var color := _material.albedo_color
		color.a = 0.85 * fade
		_material.albedo_color = color
		_material.emission_energy_multiplier = 6.0 * fade
	if _light:
		_light.light_energy = 10.0 * fade * fade
