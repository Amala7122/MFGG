@tool
@icon("res://addons/pyrolux_fx/icons/palette.svg")
class_name PyroluxPalette
extends Resource
## Colours shared by fire, sparks, explosions and lava. The heat ramp goes
## cool -> hot -> core as the temperature rises.

## Edge of the flame and dying embers.
@export var cool: Color = Color(0.85, 0.16, 0.02)
## Body of the flame.
@export var hot: Color = Color(1.0, 0.5, 0.08)
## White-hot centre.
@export var core: Color = Color(1.0, 0.9, 0.55)
## Smoke colour (alpha = density).
@export var smoke: Color = Color(0.22, 0.2, 0.19, 0.85)
## Colour of the OmniLight3D and of the glow under the smoke.
@export var light: Color = Color(1.0, 0.55, 0.2)
## Multiplier for the brightness of everything hot.
@export_range(0.0, 8.0, 0.01) var emission: float = 1.5


func apply_to(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("col_cool", cool)
	mat.set_shader_parameter("col_hot", hot)
	mat.set_shader_parameter("col_core", core)
	mat.set_shader_parameter("col_smoke", smoke)
	mat.set_shader_parameter("col_glow", light)
	mat.set_shader_parameter("emission", emission)
