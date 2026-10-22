extends Node
const CpuAudit := preload("res://scripts/enemy_cpu_audit.gd")
## 每个战斗现场一份、主动轮询的公平起手队列。获准之前不建立预警、不推进技能。
const Policy := preload("res://scripts/enemy_attack_queue_policy.gd")
const Health := preload("res://scripts/health_util.gd")
const Destruction := preload("res://scripts/environment_destruction.gd")
const REQUEST_GRACE := 0.25
const WAIT_RECHECK := 0.1
var clock := 0.0
var pending: Array[Dictionary] = []
var _pending_by_owner: Dictionary = {}
var active: Dictionary = {}
var history: Array[Dictionary] = []
var _serial := 0
var _frame := -1
var _frame_starts := 0
var _target_start: Dictionary = {}
var _peak_active := 0
var _peak_ground := 0
var _waits: Array[float] = []
var _starts: Dictionary = {}
var _grants := 0
var _expired := 0
var _prune_frame := -1
var _prune_clock := -1.0
var _selection_frame := -1
var _selection_clock := -1.0
var _selection_policy := -1
var _selected: Dictionary = {}
var _count_cache: Dictionary = {}
var selection_scans := 0

func _init() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	process_physics_priority = -100

static func applies(body: Node) -> bool:
	return bool(body.get_meta(&"formal_enemy", false)) or bool(body.get_meta(&"formal_boss", false))

static func shared(body: Node, create := true) -> Node:
	if not is_instance_valid(body) or not body.is_inside_tree(): return null
	var scene := body.get_tree().current_scene
	if scene == null or (scene != body and not scene.is_ancestor_of(body)): return null
	var service := scene.get_node_or_null("EnemyAttackQueue")
	if service == null and create:
		service = load("res://scripts/enemy_attack_queue.gd").new()
		service.name = "EnemyAttackQueue"
		scene.add_child(service)
	return service

func _physics_process(delta: float) -> void:
	var _cpu_scope: RefCounted = CpuAudit.begin(&"queue.physics") if CpuAudit.enabled else null
	clock += delta
	_prune(true)

func request(body: Node3D, target: Node3D, profile: String, skill: String, reserve := "", continuation := false) -> bool:
	var _cpu_scope: RefCounted = CpuAudit.begin(&"queue.request") if CpuAudit.enabled else null
	if not _living(body) or not _living(target) or get_tree().paused: return false
	if not Policy.REGISTRY.has(profile) or not Policy.REGISTRY[profile].has(skill):
		push_error("正式敌人缺少起手队列技能登记：" + profile + "/" + skill)
		return false
	if not reserve.is_empty() and String(Policy.REGISTRY[profile][skill].get("reserves", "")) != reserve:
		push_error("技能未声明此接力阶段：" + profile + "/" + skill + "/" + reserve)
		return false
	_prune()
	var owned := int(body.get_meta(&"attack_queue_id", 0))
	if active.has(owned) and active[owned].held and active[owned].owner.get_ref() == body:
		if active[owned].profile != profile: return false
		if continuation and active[owned].reserve == skill and active[owned].target.get_ref() == target:
			active[owned].skill = skill
			active[owned].reserve = ""
			_invalidate()
			return true
		return active[owned].skill == skill and active[owned].target.get_ref() == target
	if continuation: return false
	var owner_id := body.get_instance_id()
	var row: Dictionary = _pending_by_owner.get(owner_id, {})
	if not row.is_empty() and row.target.get_ref() != target:
		pending.erase(row)
		_pending_by_owner.erase(owner_id)
		row = {}
		_invalidate()
	var config := Policy.current()
	if row.is_empty():
		row = {"owner": weakref(body), "owner_id": owner_id, "target": weakref(target), "profile": profile, "skill": skill, "reserve": reserve, "since": clock, "seen": clock}
		pending.append(row)
		_pending_by_owner[owner_id] = row
		_invalidate()
	# 保留同一敌人的有效排队年龄，但总是采用这次完整检查后的最新技能。
	if row.profile != profile or row.skill != skill or row.reserve != reserve: _invalidate()
	row.profile = profile
	row.skill = skill
	row.reserve = reserve
	row.seen = clock
	row.checked = clock
	row.from = body.global_position
	row.aim = target.global_position
	row.geometry = Destruction.geometry_revision
	var process_frame := Engine.get_process_frames()
	if _frame != process_frame: _frame = process_frame; _frame_starts = 0
	if bool(config.enabled):
		if _frame_starts >= int(config.global.starts_per_frame): return false
		# 按到达次序找第一个能容纳的请求；同种技能满额不堵住其他兵种。
		if _choose(config) != row: return false
	_serial += 1
	var definition: Dictionary = Policy.REGISTRY[profile][skill]
	var record := {"id": _serial, "owner": weakref(body), "target": weakref(target), "profile": profile,
		"skill": skill, "ground": bool(definition.ground), "reserve": reserve,
		"held": true, "effects": [], "started": clock}
	active[_serial] = record
	body.set_meta(&"attack_queue_id", _serial)
	pending.erase(row)
	_pending_by_owner.erase(owner_id)
	_invalidate()
	_frame_starts += 1
	_target_start[target.get_instance_id()] = clock
	var wait := clock - float(row.since)
	_waits.append(wait)
	_grants += 1
	if _waits.size() > 4096: _waits.pop_front()
	var key := profile + "/" + skill
	_starts[key] = int(_starts.get(key, 0)) + 1
	var counts := _counts()
	_peak_active = maxi(_peak_active, int(counts.total))
	_peak_ground = maxi(_peak_ground, int(counts.ground))
	history.append({"time": clock, "frame": Engine.get_process_frames(), "owner": body.get_instance_id(), "target": target.get_instance_id(), "skill": key, "wait": wait, "active": counts.total, "ground": counts.ground})
	if history.size() > 2048: history.pop_front()
	return true

func release(body: Node) -> void:
	var changed := false
	var owner_id := body.get_instance_id()
	if _pending_by_owner.has(owner_id):
		pending.erase(_pending_by_owner[owner_id])
		_pending_by_owner.erase(owner_id)
		changed = true
	var id := int(body.get_meta(&"attack_queue_id", 0))
	if active.has(id) and active[id].owner.get_ref() == body and active[id].held:
		active[id].held = false
		changed = true
	if body.has_meta(&"attack_queue_id"): body.remove_meta(&"attack_queue_id")
	if changed: _invalidate()
	_prune(changed)

## 仅优化已排队者；不是施放许可。名额可用时必须回宿主完整复核再request。
func defer_check(body: Node3D, target: Node3D) -> bool:
	var _cpu_scope: RefCounted = CpuAudit.begin(&"queue.defer") if CpuAudit.enabled else null
	var config := Policy.current()
	if not bool(config.enabled) or not _living(target): return false
	var row: Dictionary = _pending_by_owner.get(body.get_instance_id(), {})
	if row.is_empty() or row.target.get_ref() != target: return false
	if clock - float(row.checked) >= WAIT_RECHECK or row.geometry != Destruction.geometry_revision: return false
	if body.global_position.distance_squared_to(row.from) > 0.16 or target.global_position.distance_squared_to(row.aim) > 0.04: return false
	_prune()
	# 清理可能已让本票失效。
	if not _pending_by_owner.has(body.get_instance_id()): return false
	var frame_full := _frame == Engine.get_process_frames() and _frame_starts >= int(config.global.starts_per_frame)
	if not frame_full and _choose(config) == row: return false
	row.seen = clock
	return true

func is_pending(body: Node) -> bool:
	return _pending_by_owner.has(body.get_instance_id())

## 弹体和残留接力同一占位；不把已公布的效果塞回起手队列。
static func track_effect(source: Node, effect: Node, phase := "") -> void:
	var service: Node
	var id := 0
	if source.has_meta(&"attack_queue_effect"):
		var lease: Dictionary = source.get_meta(&"attack_queue_effect")
		service = lease.service.get_ref()
		id = int(lease.id)
	else:
		service = shared(source, false)
		id = int(source.get_meta(&"attack_queue_id", 0))
	if not is_instance_valid(service) or not service.active.has(id): return
	if not service.get_parent().is_ancestor_of(source) or not service.get_parent().is_ancestor_of(effect): return
	var record: Dictionary = service.active[id]
	if not source.has_meta(&"attack_queue_effect") and record.owner.get_ref() != source: return
	var skill := String(record.skill) if phase.is_empty() else phase
	for previous: Dictionary in record.effects:
		if previous.ref.get_ref() == effect:
			previous.skill = skill
			service._invalidate()
			return
	effect.set_meta(&"attack_queue_effect", {"service": weakref(service), "id": id})
	record.effects.append({"ref": weakref(effect), "skill": skill})
	effect.tree_exiting.connect(service._effect_exiting, CONNECT_ONE_SHOT)
	service._invalidate()

func _effect_exiting() -> void:
	# 只标记失效，不在离树通知中清理；整个现场跨台离树时也会触发本通知。
	_prune_frame = -1
	_invalidate()

func _invalidate() -> void:
	_selection_frame = -1
	_selected = {}
	_count_cache.clear()

func _cached_counts(target: Node = null) -> Dictionary:
	var key := target.get_instance_id() if target != null else 0
	if not _count_cache.has(key): _count_cache[key] = _counts(target)
	return _count_cache[key]

func _choose(config: Dictionary) -> Dictionary:
	var frame := Engine.get_physics_frames()
	if _selection_frame == frame and _selection_clock == clock and _selection_policy == Policy.revision: return _selected
	_selection_frame = frame
	_selection_clock = clock
	_selection_policy = Policy.revision
	_selected = {}
	selection_scans += 1
	for candidate in pending:
		if _fits(candidate, config): _selected = candidate; break
	return _selected

func _fits(row: Dictionary, config: Dictionary) -> bool:
	var profile: String = row.profile
	var skill: String = row.skill
	var target: Node = row.target.get_ref()
	if not _living(target) or not _living(row.owner.get_ref()): return false
	var counts := _cached_counts(target)
	var entry: Dictionary = config.profiles[profile]
	var definition: Dictionary = Policy.REGISTRY[profile][skill]
	if clock - float(_target_start.get(target.get_instance_id(), -1000.0)) < float(config.global.start_gap): return false
	# 全场上限同时约束构建压力；间隔按玩家计算，不让另一名玩家替本目标占起手间隔。
	var scene_counts := _cached_counts()
	if int(scene_counts.total) >= int(config.global.max_active): return false
	if bool(definition.ground) and int(scene_counts.ground) >= int(config.global.max_ground): return false
	if int(counts.profiles.get(profile, 0)) >= int(entry.max_active): return false
	for required in [skill, String(row.reserve)]:
		if not required.is_empty() and int(counts.skills.get(profile + "/" + required, 0)) >= int(entry.skills[required]): return false
	return true

func _counts(target: Node = null) -> Dictionary:
	var result := {"total": 0, "ground": 0, "profiles": {}, "skills": {}}
	for record: Dictionary in active.values():
		if target != null and record.target.get_ref() != target: continue
		result.total += 1
		if record.ground: result.ground += 1
		result.profiles[record.profile] = int(result.profiles.get(record.profile, 0)) + 1
		var skills: Dictionary = {}
		if record.held: skills[record.skill] = true
		for effect: Dictionary in record.effects: skills[effect.skill] = true
		# 投囊时就为将来的毒池预留容量；不会落地后无提示地删池或排队延迟伤害。
		if not String(record.reserve).is_empty(): skills[record.reserve] = true
		for skill: String in skills:
			var key := String(record.profile) + "/" + skill
			result.skills[key] = int(result.skills.get(key, 0)) + 1
	return result

func _prune(force := false) -> void:
	var _cpu_scope: RefCounted = CpuAudit.begin(&"queue.prune") if CpuAudit.enabled else null
	# 整个现场离树进入专业台时，队列与占位原样保留，不能视为敌人退场。
	if not is_inside_tree(): return
	var frame := Engine.get_physics_frames()
	if not force and _prune_frame == frame and _prune_clock == clock: return
	_prune_frame = frame
	_prune_clock = clock
	var changed := false
	for index in range(pending.size() - 1, -1, -1):
		var row := pending[index]
		if not _living(row.owner.get_ref()) or not _living(row.target.get_ref()) or clock - float(row.seen) > REQUEST_GRACE:
			_pending_by_owner.erase(int(row.owner_id))
			pending.remove_at(index)
			_expired += 1
			changed = true
	for id: int in active.keys():
		var record: Dictionary = active[id]
		if record.held and not _living(record.owner.get_ref()): record.held = false; changed = true
		for index in range(record.effects.size() - 1, -1, -1):
			var effect: Node = record.effects[index].ref.get_ref()
			if not is_instance_valid(effect) or not effect.is_inside_tree() or effect.is_queued_for_deletion(): record.effects.remove_at(index); changed = true
		if not record.held and record.effects.is_empty(): active.erase(id); changed = true
	if changed: _invalidate()

static func _living(node: Node) -> bool:
	return is_instance_valid(node) and node.is_inside_tree() and Health.is_alive(node)

func snapshot() -> Dictionary:
	_prune(true)
	var result := _counts()
	var waits := _waits.duplicate()
	waits.sort()
	result.merge({"clock": clock, "pending": pending.size(), "peak_active": _peak_active, "peak_ground": _peak_ground, "selection_scans": selection_scans,
		"starts": _starts.duplicate(), "expired": _expired, "grants": _grants,
		"wait_p95": waits[mini(ceili(waits.size() * 0.95) - 1, waits.size() - 1)] if not waits.is_empty() else 0.0,
		"wait_max": waits.back() if not waits.is_empty() else 0.0,
		"history": history.duplicate(true)})
	return result
