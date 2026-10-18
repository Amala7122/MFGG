extends CanvasLayer
## Full-screen image effects shared by every scene. The menu layer stays above this one.

const EFFECT_SHADER := preload("res://shaders/screen_post_process.gdshader")
const STYLE_NONE := 0
const STYLE_BLACK_WHITE_TV := 1
const STYLE_CRT := 2
const STYLE_OLD_PHOTO := 3
const STYLE_INVERT := 4
const STYLE_SKETCH := 5
const SketchSettings := preload("res://scripts/sketch_settings.gd")
const SketchShader := preload("res://shaders/pencil_sketch.gdshader")

var _overlay: ColorRect
var _effect_material: ShaderMaterial
var style := STYLE_NONE
var parameters: Dictionary = {}
var _sketch_layer: CanvasLayer
var _sketch_rect: ColorRect
var _sketch_material: ShaderMaterial
var _sketch_copy: BackBufferCopy
var _sketch_panel: CanvasLayer
var _debug_bypass := false


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
	# 手绘只处理世界。旧五种风格的90层行为不变；HUD在默认0层及以上。
	_sketch_layer = CanvasLayer.new()
	_sketch_layer.layer = -1
	add_child(_sketch_layer)
	_sketch_copy = BackBufferCopy.new()
	_sketch_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_sketch_layer.add_child(_sketch_copy)
	_sketch_material = ShaderMaterial.new()
	_sketch_material.shader = SketchShader
	_sketch_rect = ColorRect.new()
	_sketch_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sketch_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sketch_rect.material = _sketch_material
	_sketch_layer.add_child(_sketch_rect)
	apply_sketch_parameters(SketchSettings.load_values())
	_sketch_panel = preload("res://scripts/sketch_panel.gd").new()
	_sketch_panel.setup(self)
	add_child(_sketch_panel)


func set_style(value: int) -> void:
	var selected := clampi(value, STYLE_NONE, STYLE_SKETCH)
	style = selected
	_effect_material.set_shader_parameter("style", selected)
	_overlay.visible = selected != STYLE_NONE and selected != STYLE_SKETCH and not _debug_bypass
	_refresh_sketch()

func set_debug_bypass(value: bool) -> void:
	_debug_bypass = value
	set_style(style)

func apply_sketch_parameters(values: Dictionary) -> void:
	var valid := SketchSettings.validate(values)
	if valid.is_empty():
		return
	parameters = valid
	for key in parameters:
		var value: Variant = parameters[key]
		if key in SketchSettings.BOOLS:
			value = bool(value)
		elif key == "color_bands":
			value = int(value)
		elif key in SketchSettings.COLORS:
			value = Color(value[0], value[1], value[2], value[3])
		_sketch_material.set_shader_parameter(key, value)
	_refresh_sketch()

func _refresh_sketch() -> void:
	var active := not _debug_bypass and style == STYLE_SKETCH and float(parameters.get("filter_blend", 0.0)) > 0.0
	_sketch_rect.visible = active
	_sketch_copy.visible = active
