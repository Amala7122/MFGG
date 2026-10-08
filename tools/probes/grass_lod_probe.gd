extends SceneTree
## 手动草地 LOD 诊断探针。
##
## 这不是自动回归测试：它通过移动一个虚拟 player，打印草地 chunk 的 LOD / 可见性
## 分布，适合在调整 grass_field.gd 的 LOD 逻辑后人工核对。
## 正式自动测试请放在 tests/，只打印观察结果的诊断脚本统一放 tools/probes/。


var _frame := 0
var _grass: Node3D
var _player: Node3D


func _initialize() -> void:
	_grass = (load("res://scripts/grass_field.gd") as GDScript).new()
	root.add_child(_grass)
	_player = Node3D.new()
	_player.name = "Probe"
	_player.add_to_group("player")
	root.add_child(_player)
	_player.global_position = Vector3.ZERO


func _process(delta: float) -> bool:
	_frame += 1
	_grass._process(delta)
	if _frame == 2:
		_dump("建好时玩家在(0,0)")
	elif _frame == 4:
		var target: Vector2 = (_grass.get("_chunks") as Array)[0]["center"]
		_player.global_position = Vector3(target.x, 0.0, target.y)
		_move()
	elif _frame == 6:
		_dump("走到某块草地中心")
	elif _frame == 8:
		_player.global_position = Vector3.ZERO
		_move()
	elif _frame == 10:
		_dump("回到原点")
	return _frame > 11


## 强制刷新观察者并立刻重算 LOD（headless 的 delta 太小，走不到定时器）。
func _move() -> void:
	_grass._refresh_observers()
	_grass._update_visibility()


func _dump(label: String) -> void:
	var chunks: Array = _grass.get("_chunks")
	var counts := {0: 0, 1: 0, 2: 0, -1: 0}
	var visible := 0
	for chunk in chunks:
		var info: Dictionary = chunk
		var lv: int = info["level"]
		counts[lv] = int(counts[lv]) + 1
		for entry in info["nodes"]:
			var node: MultiMeshInstance3D = entry
			if node.visible:
				visible += 1
	print("%s -> L0=%d L1=%d L2=%d 隐藏=%d 可见层级=%d"
		% [label, counts[0], counts[1], counts[2], counts[-1], visible])
