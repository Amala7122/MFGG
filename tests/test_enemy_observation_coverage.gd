extends SceneTree
## 敌人观察台覆盖守卫：新敌人必须登记进观察台，且能力声明要与实现一致。
##
## 为什么要它：用户要求「以后新加入的敌人都要进这里观察分析」。只写进规则会漂，
## 这里把三件事变成可判定的门槛：
##   1. 每个画廊条目都显式声明 observe（scrub / play），不允许沉默；
##   2. 声明与实际能力一致：scrub 必须有 sample_pose + set_preview_pose，play 必须没有 sample_pose；
##   3. 每个带参数配置的敌人（enemy_tuning.PROFILE_PATHS）都必须在画廊里有条目；
##      新外形还必须登记参数→部位，否则点击拾取反查不到参数。

const LabScene := preload("res://prototypes/visual_lab/enemy_visual_lab.tscn")
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const ParamParts := preload("res://scripts/prototypes/visual_param_parts.gd")
## 「还没投入主场景的敌人」= 这些目录里的原型/新外形场景。主场景只引 melee_enemy.tscn /
## ranged_enemy.tscn + 图鉴 body profile，所以这些原型都属于"新敌人"，必须能在这里观察。
const PROTOTYPE_SCENE_DIRS := ["res://prototypes/enemy_prototypes/", "res://prototypes/visual_lab/"]
const EXCLUDED_SCENES := ["res://prototypes/visual_lab/enemy_visual_lab.tscn"]
## 2026-10-10 用户要求：把机器人样的正式兵种（大型盾卫）撤出观察台，以后再说。
## 泥土傀儡 / 沉积泰坦 保留（用户明确「这两个不撤」）。显式登记撤离项，避免守卫判成漏登记。
const DEFERRED_SCENES := [
	"res://prototypes/visual_lab/shield_guard_visual.tscn",
]
const DEFERRED_PROFILES: Array[String] = []
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _run() -> void:
	var lab: Node3D = LabScene.instantiate()
	root.add_child(lab)
	current_scene = lab
	for frame in range(5):
		await process_frame
	var gallery: Array = lab.get("GALLERY")
	var declared_profiles := {}
	for entry: Dictionary in gallery:
		var title := String(entry.get("title", "?"))
		_check(entry.has("observe"), "画廊条目缺少 observe 声明：" + title)
		var observe := String(entry.get("observe", ""))
		_check(observe == "scrub" or observe == "play", "observe 只能是 scrub / play：" + title)
		var profile := String(entry.get("profile", ""))
		if not profile.is_empty():
			declared_profiles[profile] = true
	# 声明必须与实现一致：逐个实例化，与观察台取主体走同一条路径。
	for index in gallery.size():
		var entry: Dictionary = gallery[index]
		var title := String(entry.get("title", "?"))
		lab.call("_show_subject", index)
		for frame in range(3):
			await process_frame
		var subject: Node3D = lab.get("_subject")
		_check(subject != null, "取不到主体：" + title)
		if subject == null:
			continue
		var declared := String(entry.get("observe", ""))
		var scrub := declared == "scrub"
		_check(subject.has_method("sample_pose") == scrub,
			"%s 的 observe 声明与实际能力不符：sample_pose=%s，声明=%s" % [title, str(subject.has_method("sample_pose")), declared])
		if scrub:
			_check(subject.has_method("set_preview_pose"), title + " 声明可逐帧，但缺少 set_preview_pose")
	# 带参数配置的敌人一个都不能漏登记。
	for id: String in Tuning.PROFILE_PATHS:
		if DEFERRED_PROFILES.has(id):
			continue
		_check(declared_profiles.has(id), "敌人参数配置 %s 没有对应的观察台条目（新敌人必须登记）" % id)
		if id.begins_with("Visual"):
			_check(ParamParts.has_profile(id), "%s 缺少参数→部位登记，点击拾取反查不到参数" % id)
	# 未投入主场景的原型场景一个都不能漏：新敌人往这些目录里一放，就必须登记。
	var gallery_scenes := {}
	for entry: Dictionary in gallery:
		var scene := entry.get("scene") as PackedScene
		if scene != null:
			gallery_scenes[scene.resource_path] = true
	for dir: String in PROTOTYPE_SCENE_DIRS:
		for file_name in DirAccess.get_files_at(dir):
			if not String(file_name).ends_with(".tscn"):
				continue
			var path := dir + String(file_name)
			if EXCLUDED_SCENES.has(path) or DEFERRED_SCENES.has(path):
				continue
			_check(gallery_scenes.has(path), "未投入主场景的原型场景没有登记进观察台：" + path)
	lab.queue_free()
	await process_frame
	print("Enemy observation coverage: ", "PASS" if failures == 0 else "%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)
