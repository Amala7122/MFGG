extends CanvasLayer
## On-screen help shared by the PYROLUX demo scenes (only used by the demos).
## Top left: scene title, one line about what it shows, and the code behind it.
## Bottom: a bar of buttons (mouse and touch) that also show their keyboard key.
## H or ?: a help card with every control. The first demo scene opened shows the card once
## as a start screen; clicking it also gives the browser canvas keyboard focus.

const ACCENT: Color = Color(1.0, 0.62, 0.25)
const TITLE: Color = Color(1.0, 0.86, 0.66)
const TEXT: Color = Color(1.0, 0.94, 0.88)
const DIM: Color = Color(0.74, 0.78, 0.88)
const INTRO_META: StringName = &"pyrolux_demo_intro_done"
## Command line arguments of the automated tests; they skip the start screen.
const NO_INTRO_ARGS: Array[String] = ["--no-intro", "--quick", "--autotest", "--hold"]

var title_label: Label
var desc_label: Label
var code_label: Label
var left_column: VBoxContainer
var bar: HBoxContainer
var overlay: Control
var help_heading: String = ""
## Rows of the help card: {"keys": PackedStringArray, "text": String}. "<" and ">" draw arrow keys.
var help_rows: Array[Dictionary] = []

var _info: PanelContainer
var _hint_box: CenterContainer
var _hint_label: Label
var _card_box: VBoxContainer
var _prompt: Label
var _clock: float = 0.0
var _tex: Dictionary = {}


func _init() -> void:
	layer = 10


func _ready() -> void:
	_tex["tri_left"] = _shape_texture(true, false)
	_tex["tri_right"] = _shape_texture(false, false)
	_tex["arrow_left"] = _shape_texture(true, true)
	_tex["arrow_right"] = _shape_texture(false, true)

	left_column = VBoxContainer.new()
	left_column.position = Vector2(16, 14)
	left_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left_column.add_theme_constant_override("separation", 12)
	add_child(left_column)
	_info = _panel(Color(0.03, 0.02, 0.025, 0.55), 10, 18, 10)
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	left_column.add_child(_info)
	var v: VBoxContainer = VBoxContainer.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 2)
	_info.add_child(v)
	title_label = _label(34, TITLE)
	desc_label = _label(22, TEXT)
	code_label = _label(18, DIM)
	v.add_child(title_label)
	v.add_child(desc_label)
	v.add_child(code_label)

	var bar_panel: PanelContainer = _panel(Color(0.0, 0.0, 0.0, 0.45), 0, 10, 8)
	bar_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar_panel.offset_top = -66.0
	bar_panel.offset_bottom = 0.0
	bar_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bar_panel)
	bar = HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_constant_override("separation", 10)
	bar_panel.add_child(bar)

	_hint_box = CenterContainer.new()
	_hint_box.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint_box.offset_top = -124.0
	_hint_box.offset_bottom = -74.0
	_hint_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint_box)
	var hp: PanelContainer = _panel(Color(0.03, 0.02, 0.025, 0.6), 10, 18, 6)
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_box.add_child(hp)
	_hint_label = _label(23, TEXT)
	hp.add_child(_hint_label)
	_hint_box.visible = false

	_build_overlay()


func _process(delta: float) -> void:
	_clock += delta
	if overlay.visible:
		_prompt.modulate.a = 0.6 + 0.4 * (0.5 + 0.5 * sin(_clock * 4.0))


func _input(event: InputEvent) -> void:
	var k: InputEventKey = event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if overlay.visible:
		hide_help()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_H or k.keycode == KEY_QUESTION or k.unicode == 63:
		show_help(false)
		get_viewport().set_input_as_handled()


## Sets the three lines at the top left.
func set_info(title: String, description: String, code: String) -> void:
	title_label.text = title
	desc_label.text = description
	code_label.text = code
	code_label.visible = code != ""
	_info.reset_size()
	left_column.reset_size()


## One line above the button bar saying what a click does here. Empty hides it.
func set_hint(text: String) -> void:
	_hint_label.text = text
	_hint_box.visible = text != ""


## Adds a button to the bottom bar. `key` is shown as a key cap ("<" / ">" draw arrows).
func add_bar_button(text: String, key: String, action: Callable, icon: String = "", icon_after: bool = false) -> PanelContainer:
	var b: PanelContainer = make_button(text, key, action, icon, icon_after)
	bar.add_child(b)
	return b


## Thin gap between groups of buttons in the bar.
func add_bar_gap() -> void:
	var c: Control = Control.new()
	c.custom_minimum_size = Vector2(8, 0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(c)


## A clickable / tappable button with an optional icon and a key cap.
func make_button(text: String, key: String, action: Callable, icon: String = "", icon_after: bool = false) -> PanelContainer:
	var b: PanelContainer = PanelContainer.new()
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var h: HBoxContainer = HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 8)
	b.add_child(h)
	var ic: TextureRect = null
	if icon != "":
		ic = TextureRect.new()
		ic.texture = _tex[icon]
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.custom_minimum_size = Vector2(20, 20)
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if not icon_after:
			h.add_child(ic)
	var l: Label = _label(21, TEXT, 0)
	l.text = text
	l.visible = text != ""
	h.add_child(l)
	if ic and icon_after:
		h.add_child(ic)
	if key != "":
		h.add_child(_keycap(key, 17))
	b.set_meta(&"label", l)
	b.set_meta(&"hover", false)
	b.set_meta(&"selected", false)
	_restyle(b)
	b.mouse_entered.connect(_on_hover.bind(b, true))
	b.mouse_exited.connect(_on_hover.bind(b, false))
	b.gui_input.connect(_on_button_input.bind(b, action))
	return b


func set_button_text(b: PanelContainer, text: String) -> void:
	var l: Label = b.get_meta(&"label")
	l.text = text
	b.reset_size()


func set_button_selected(b: PanelContainer, on: bool) -> void:
	b.set_meta(&"selected", on)
	_restyle(b)


## Shows the help card. `first` = start screen wording ("click to start").
func show_help(first: bool) -> void:
	for c in _card_box.get_children():
		_card_box.remove_child(c)
		c.queue_free()
	var t: Label = _label(60, ACCENT, 8)
	t.text = "PYROLUX"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_box.add_child(t)
	var s: Label = _label(24, TEXT, 0)
	s.text = "Fire, explosion, smoke and lava VFX for Godot 4  -  live demo"
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_box.add_child(s)
	var gap: Control = Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	_card_box.add_child(gap)
	if help_heading != "":
		var hh: Label = _label(25, TITLE, 0)
		hh.text = help_heading
		_card_box.add_child(hh)
	var grid: GridContainer = GridContainer.new()
	grid.columns = 2
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 9)
	_card_box.add_child(grid)
	for row in help_rows:
		var keys: PackedStringArray = row["keys"]
		var text: String = row["text"]
		var kh: HBoxContainer = HBoxContainer.new()
		kh.mouse_filter = Control.MOUSE_FILTER_IGNORE
		kh.alignment = BoxContainer.ALIGNMENT_END
		kh.add_theme_constant_override("separation", 6)
		for key in keys:
			kh.add_child(_keycap(key, 20))
		grid.add_child(kh)
		var dl: Label = _label(22, TEXT, 0)
		dl.text = text
		grid.add_child(dl)
	var note: Label = _label(18, DIM, 0)
	note.text = "Every key also has a button at the bottom of the screen (mouse or touch)."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_box.add_child(note)
	var gap2: Control = Control.new()
	gap2.custom_minimum_size = Vector2(0, 6)
	_card_box.add_child(gap2)
	_prompt = _label(28, ACCENT, 0)
	_prompt.text = "Click or tap anywhere to start" if first else "Click or tap anywhere to close"
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_box.add_child(_prompt)
	overlay.visible = true


func hide_help() -> void:
	overlay.visible = false


## Shows the help card as a start screen the first time any demo scene opens (not again
## after switching scenes, and never in the automated test runs).
func show_intro_once() -> void:
	if Engine.has_meta(INTRO_META):
		return
	Engine.set_meta(INTRO_META, true)
	for a in OS.get_cmdline_user_args():
		if NO_INTRO_ARGS.has(a) or a.begins_with("--slot="):
			return
	show_help(true)


# ------------------------------------------------------------------ internals

func _build_overlay() -> void:
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	add_child(overlay)
	var dim: ColorRect = ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.5)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	var cc: CenterContainer = CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(cc)
	var card: PanelContainer = _panel(Color(0.06, 0.035, 0.03, 0.86), 14, 40, 24)
	var sb: StyleBoxFlat = card.get_theme_stylebox(&"panel") as StyleBoxFlat
	sb.border_color = Color(ACCENT, 0.7)
	sb.set_border_width_all(2)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cc.add_child(card)
	_card_box = VBoxContainer.new()
	_card_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_box.add_theme_constant_override("separation", 6)
	card.add_child(_card_box)
	overlay.gui_input.connect(_on_overlay_input)


func _on_overlay_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb and mb.pressed:
		hide_help()
		overlay.accept_event()


func _on_button_input(event: InputEvent, b: PanelContainer, action: Callable) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		b.accept_event()
		action.call()


func _on_hover(b: PanelContainer, on: bool) -> void:
	b.set_meta(&"hover", on)
	_restyle(b)


func _restyle(b: PanelContainer) -> void:
	var hover: bool = b.get_meta(&"hover")
	var selected: bool = b.get_meta(&"selected")
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2 if selected else 1)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	if selected:
		sb.bg_color = Color(0.5, 0.22, 0.05, 0.95)
		sb.border_color = Color(1.0, 0.82, 0.5)
	elif hover:
		sb.bg_color = Color(0.3, 0.15, 0.06, 0.95)
		sb.border_color = ACCENT
	else:
		sb.bg_color = Color(0.13, 0.075, 0.05, 0.85)
		sb.border_color = Color(1.0, 0.62, 0.3, 0.45)
	b.add_theme_stylebox_override(&"panel", sb)


func _keycap(key: String, font_size: int) -> PanelContainer:
	var p: PanelContainer = PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 1.0, 1.0, 0.13)
	sb.border_color = Color(1.0, 1.0, 1.0, 0.5)
	sb.set_border_width_all(1)
	sb.border_width_bottom = 3
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 7.0
	sb.content_margin_right = 7.0
	sb.content_margin_top = 0.0
	sb.content_margin_bottom = 1.0
	p.add_theme_stylebox_override(&"panel", sb)
	if key == "<" or key == ">":
		var ic: TextureRect = TextureRect.new()
		ic.texture = _tex["arrow_left" if key == "<" else "arrow_right"]
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.custom_minimum_size = Vector2(font_size + 2, font_size + 4)
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(ic)
	else:
		var l: Label = _label(font_size, Color(1, 1, 1), 0)
		l.text = key
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.custom_minimum_size = Vector2(font_size * 0.8, 0)
		p.add_child(l)
	return p


func _label(font_size: int, color: Color, outline: int = 5) -> Label:
	var l: Label = Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override(&"font_size", font_size)
	l.add_theme_color_override(&"font_color", color)
	if outline > 0:
		l.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override(&"outline_size", outline)
	return l


func _panel(bg: Color, radius: int, margin_x: float, margin_y: float) -> PanelContainer:
	var p: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = margin_x
	sb.content_margin_right = margin_x
	sb.content_margin_top = margin_y
	sb.content_margin_bottom = margin_y
	p.add_theme_stylebox_override(&"panel", sb)
	return p


## Small white triangle (button icon) or arrow (arrow key cap), drawn once at start.
func _shape_texture(left: bool, arrow: bool) -> ImageTexture:
	var n: int = 32
	var ss: int = 4
	var img: Image = Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var cov: int = 0
			for sy in ss:
				for sx in ss:
					var u: float = (float(x) + (float(sx) + 0.5) / ss) / n
					var v: float = absf((float(y) + (float(sy) + 0.5) / ss) / n - 0.5)
					if left:
						u = 1.0 - u
					var inside: bool
					if arrow:
						inside = (u >= 0.5 and u <= 0.9 and v <= (0.9 - u) / 0.4 * 0.36) or (u >= 0.1 and u < 0.55 and v <= 0.08)
					else:
						inside = u >= 0.2 and u <= 0.86 and v <= (0.86 - u) / 0.66 * 0.4
					if inside:
						cov += 1
			img.set_pixel(x, y, Color(1, 1, 1, float(cov) / float(ss * ss)))
	return ImageTexture.create_from_image(img)
