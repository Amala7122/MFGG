extends CanvasLayer
## Full-screen image effects shared by every scene. The menu layer stays above this one.

const EFFECT_SHADER := preload("res://shaders/screen_post_process.gdshader")
const STYLE_NONE := 0
const STYLE_BLACK_WHITE_TV := 1
const STYLE_CRT := 2
const STYLE_OLD_PHOTO := 3
const STYLE_INVERT := 4

var _overlay: ColorRect
var _effect_material: ShaderMaterial


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_effect_material = ShaderMaterial.new()
	_effect_material.shader = EFFECT_SHADER
	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.material = _effect_material
	_overlay.visible = false
	add_child(_overlay)


func set_style(style: int) -> void:
	var selected := clampi(style, STYLE_NONE, STYLE_INVERT)
	_effect_material.set_shader_parameter("style", selected)
	_overlay.visible = selected != STYLE_NONE
