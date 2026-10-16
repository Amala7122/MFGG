extends SceneTree
## 可直接 F6 的开发入口清单。子场景、零件、legacy 与历史转发壳不计入。

const ENTRIES := [
	"res://prototypes/boss_lab/sediment_titan_boss_lab.tscn",
	"res://prototypes/boss_lab/titan_sparring_lab.tscn",
	"res://prototypes/sparring_lab/combat_sparring_lab.tscn",
	"res://prototypes/navigation_lab/navigation_lab.tscn",
	"res://prototypes/ring_chase_lab/ring_chase_lab.tscn",
	"res://prototypes/spatial_lab/combat_spatial_lab.tscn",
	"res://prototypes/spatial_lab/capability_lab.tscn",
	"res://prototypes/combat_lab/combat_lab.tscn",
	"res://prototypes/visual_lab/enemy_visual_lab.tscn",
	"res://prototypes/painterly_lab/painterly_style_lab.tscn",
	"res://prototypes/weather_lab/weather_lab.tscn",
	"res://prototypes/weather_lab/sanctum_sky3d_experiment.tscn",
]

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var unique := {}
	var readme := FileAccess.get_file_as_string("res://prototypes/README.md")
	for path: String in ENTRIES:
		_check(not unique.has(path), "入口没有重复登记：" + path)
		unique[path] = true
		_check(ResourceLoader.exists(path), "入口场景存在：" + path)
		var resource := load(path)
		_check(resource is PackedScene, "入口能加载为场景：" + path)
		_check(readme.contains(path.get_file()), "prototypes/README 索引包含入口：" + path)
	_check(ENTRIES.size() == 12, "当前有效开发入口总数为 12")
	_check(not unique.has("res://prototypes/combat_lab.tscn"), "历史 Combat Lab 转发壳不重复计数")
	print("[开发入口清单] entries=", ENTRIES.size(), " failures=", _failures)
	quit(1 if _failures else 0)


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)

