extends RefCounted
## 稳定局内 ID + 弱引用；跟踪多敌、晚加入、死亡与异常消失，不把一个目标当整局。
const Adapter := preload("res://tools/probes/sparring/sparring_enemy_adapter.gd")
const Health := preload("res://scripts/health_util.gd")
var owner: Node
var recorder: RefCounted
var actors: Dictionary = {}
var last_samples: Dictionary = {}
var removed_alive: Array[String] = []
var _by_instance: Dictionary = {}

func configure(world: Node) -> void:
	owner = world
	sync()

func sync() -> void:
	if not is_instance_valid(owner) or not owner.is_inside_tree():
		return
	for node: Node in owner.get_tree().get_nodes_in_group("enemies"):
		if not node is Node3D or not owner.is_ancestor_of(node) or _by_instance.has(node.get_instance_id()):
			continue
		var id := "enemy_%04d" % (actors.size() + 1)
		_by_instance[node.get_instance_id()] = id
		actors[id] = weakref(node)
		node.set_meta(&"sparring_actor_id", id)
		if not node.has_meta(&"lab_roster_id"):
			node.set_meta(&"lab_roster_id", node.get_meta(&"formal_boss_id", Adapter.implementation(node)))
			node.set_meta(&"lab_title", node.get_meta(&"formal_boss_title", String(Adapter.value(node, "enemy_title", Adapter.implementation(node)))))
		last_samples[id] = Adapter.sample(node, id)
		if recorder != null:
			recorder.call("register_enemy", node)
			node.set_meta(&"combat_recorder", recorder)

func attach(logbook: RefCounted) -> void:
	recorder = logbook
	for id: String in actors:
		var node: Node = actors[id].get_ref()
		if is_instance_valid(node):
			recorder.call("register_enemy", node)
			node.set_meta(&"combat_recorder", recorder)

func live_nodes() -> Array[Node3D]:
	var output: Array[Node3D] = []
	for id: String in actors:
		var node: Node3D = actors[id].get_ref()
		if is_instance_valid(node) and Health.is_alive(node):
			output.append(node)
	return output

func sample() -> Array:
	var output: Array = []
	for id: String in actors:
		var node: Node3D = actors[id].get_ref()
		var row: Dictionary
		if is_instance_valid(node):
			row = Adapter.sample(node, id)
			if bool(row.get("removed_without_death", false)) and not removed_alive.has(id):
				removed_alive.append(id)
		elif last_samples.has(id):
			row = last_samples[id].duplicate(true)
			if bool(row.alive) and not removed_alive.has(id):
				removed_alive.append(id)
			row.available = false
			row.alive = false
			row["removed_without_death"] = removed_alive.has(id)
		else:
			continue
		last_samples[id] = row
		output.append(row)
	return output

func note_damage(enemy: Node, hp: float) -> void:
	var id := String(enemy.get_meta(&"sparring_actor_id", ""))
	if last_samples.has(id):
		# 已输出的帧与初始配装快照保持不变；只更新用于退出后留证的缓存。
		last_samples[id] = last_samples[id].duplicate(true)
		last_samples[id].hp = hp
		last_samples[id].alive = hp > 0.0

func detach() -> void:
	for id: String in actors:
		var node: Node = actors[id].get_ref()
		if is_instance_valid(node) and node.has_meta(&"combat_recorder") and node.get_meta(&"combat_recorder") == recorder:
			node.remove_meta(&"combat_recorder")
	recorder = null
