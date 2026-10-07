extends PanelContainer

const Config = preload("res://scripts/game_config.gd")
const CONFIG_PATH = "res://data/game_config.json"

var target_id := ""
var sliders := {}
var schema = {
	"charge_range": {"label": "冲锋触发距离(m)", "min": 2.0, "max": 25.0, "step": 0.5, "default": 10.0},
	"windup_duration": {"label": "前摇时间(s)", "min": 0.1, "max": 2.0, "step": 0.1, "default": 0.8},
	"strike_duration": {"label": "冲锋时间(s)", "min": 0.1, "max": 2.0, "step": 0.05, "default": 0.6},
	"dash_speed": {"label": "冲锋速度倍率", "min": 1.0, "max": 10.0, "step": 0.5, "default": 5.0},
	"knockback_force": {"label": "击退力度", "min": 0.0, "max": 30.0, "step": 1.0, "default": 10.0},
	"knockback_duration": {"label": "击退硬直(s)", "min": 0.1, "max": 2.0, "step": 0.05, "default": 0.35}
}

func _ready() -> void:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.95)
	style.set_border_width_all(2)
	style.border_color = Color(0.4, 0.6, 0.8)
	add_theme_stylebox_override("panel", style)
	
	var vbox = VBoxContainer.new()
	add_child(vbox)
	
	var title = Label.new()
	title.text = "冲锋参数预设编辑"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())
	
	var grid = GridContainer.new()
	grid.columns = 3
	vbox.add_child(grid)
	
	for key in schema:
		var cfg = schema[key]
		var lbl = Label.new()
		lbl.text = cfg.label
		grid.add_child(lbl)
		
		var slider = HSlider.new()
		slider.min_value = cfg.min
		slider.max_value = cfg.max
		slider.step = cfg.step
		slider.value = cfg.default
		slider.custom_minimum_size = Vector2(150, 0)
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(slider)
		
		var val_lbl = Label.new()
		val_lbl.text = str(cfg.default)
		grid.add_child(val_lbl)
		
		slider.value_changed.connect(func(v): val_lbl.text = str(v))
		sliders[key] = slider
		
	vbox.add_child(HSeparator.new())
	
	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(hbox)
	
	var save_btn = Button.new()
	save_btn.text = "保存至 Config (实装)"
	save_btn.pressed.connect(_on_save_pressed)
	hbox.add_child(save_btn)
	
	var close_btn = Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(func(): visible = false)
	hbox.add_child(close_btn)

func open_for_enemy(enemy_id: String) -> void:
	target_id = enemy_id
	visible = true
	var dict = Config.get_dictionary("enemy_roster")
	var entries = dict.get("entries", [])
	for e in entries:
		if e.get("id") == target_id:
			var attrs = e.get("attrs", {})
			for key in schema:
				if attrs.has(key):
					sliders[key].value = float(attrs[key])
				else:
					sliders[key].value = schema[key].default
			break

func _on_save_pressed() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var file = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	var text = file.get_as_text()
	file.close()
	
	var data = JSON.parse_string(text)
	var entries = data.get("enemy_roster", {}).get("entries", [])
	for e in entries:
		if e.get("id") == target_id:
			if not e.has("attrs"):
				e["attrs"] = {}
			for key in schema:
				e["attrs"][key] = sliders[key].value
			break
			
	var out_file = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	out_file.store_string(JSON.stringify(data, "  "))
	out_file.close()
	if Config.instance:
		Config.instance.load_config()
	print("Saved preset to config!")
