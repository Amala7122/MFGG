extends RefCounted
## 本轮草稿唯一所有者；不持有游戏 Node、不自动保存、不改变正式默认。
signal changed(draft_id: String)
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
static var _shared: RefCounted
var session_id := "%d:%d" % [OS.get_process_id(), Time.get_ticks_usec()]
var error := ""
var _storage := Tuning.storage_directory
var _drafts: Dictionary = {}
var _sources: Dictionary = {}
var _last: Dictionary = {}
var _serial := 0

static func shared() -> RefCounted:
	if _shared == null or _shared._storage != Tuning.storage_directory:
		_shared = load("res://scripts/testing/tuning_session.gd").new()
	return _shared

func open_profile(profile: String, preset := "", target_id := "") -> String:
	error = ""
	if not Tuning.PROFILE_PATHS.has(profile):
		error = "对象没有已登记的参数方案"
		return ""
	var last_key := JSON.stringify([profile, target_id])
	if preset.is_empty() and _last.has(last_key): return _last[last_key]
	if preset.is_empty(): preset = Tuning.active_name(profile)
	if not Tuning.preset_names(profile).has(preset):
		error = "找不到方案：" + preset
		return ""
	var source_key := JSON.stringify([profile, preset, target_id])
	if not _sources.has(source_key):
		_serial += 1
		var id := "draft:%d" % _serial
		var values := Tuning.preset_values(profile, preset)
		_drafts[id] = {"id": id, "profile": profile, "preset": preset, "target_id": target_id, "source_key": source_key,
			"candidate_name": "" if preset == Tuning.DEFAULT_PRESET else preset,
			"values": values.duplicate(true), "baseline": values.duplicate(true), "base_fingerprint": Tuning.fingerprint(profile, values),
			"schema_fingerprint": Tuning.schema_fingerprint(profile), "revision": 0, "undo": [], "redo": []}
		_sources[source_key] = id
	var key: String = _sources[source_key]
	_last[last_key] = key
	return key

func record(key: String) -> Dictionary:
	var result: Dictionary = _drafts.get(key, {}).duplicate(true)
	result.erase("undo")
	result.erase("redo")
	return result

func values(key: String) -> Dictionary:
	return _drafts.get(key, {}).get("values", {}).duplicate(true)

func dirty(key: String) -> bool:
	return _drafts.has(key) and _drafts[key].values != _drafts[key].baseline

func set_candidate_name(key: String, text: String) -> void:
	if _drafts.has(key): _drafts[key].candidate_name = text

func validation(key: String) -> String:
	return Tuning.validate(_drafts[key].profile, _drafts[key].values) if _drafts.has(key) else "草稿不存在"

func set_value(key: String, field: String, value: Variant) -> bool:
	error = ""
	if not _drafts.has(key): return false
	var data: Dictionary = _drafts[key]
	var spec := Catalog.field(data.profile, field)
	if spec.is_empty(): error = "字段未登记"; return false
	if spec.value is bool:
		if not value is bool: error = "需要开关值"; return false
	elif not (value is int or value is float) or not is_finite(float(value)) or float(value) < float(spec.min) or float(value) > float(spec.max):
		error = "%s需在 %s–%s 之间" % [spec.label, spec.min, spec.max]
		return false
	if data.values[field] == value: return true
	var next: Dictionary = data.values.duplicate(true)
	next[field] = value
	_replace(key, next)
	return true

func _replace(key: String, next: Dictionary) -> void:
	var d: Dictionary = _drafts[key]
	d.undo.append(d.values.duplicate(true))
	if d.undo.size() > 64: d.undo.pop_front()
	d.redo.clear()
	d.values = next.duplicate(true)
	d.revision += 1
	changed.emit(key)

func undo(key: String) -> void:
	if not _drafts.has(key): return
	var d: Dictionary = _drafts[key]
	if d.undo.is_empty(): return
	d.redo.append(d.values.duplicate(true))
	d.values = d.undo.pop_back()
	d.revision += 1
	changed.emit(key)

func redo(key: String) -> void:
	if not _drafts.has(key): return
	var d: Dictionary = _drafts[key]
	if d.redo.is_empty(): return
	d.undo.append(d.values.duplicate(true))
	d.values = d.redo.pop_back()
	d.revision += 1
	changed.emit(key)

func restore(key: String, defaults := false) -> void:
	if not _drafts.has(key): return
	_replace(key, Tuning.defaults(_drafts[key].profile) if defaults else _drafts[key].baseline)

func save_as(key: String, name: String, overwrite := false, expected_target := "") -> bool:
	error = validation(key)
	if not error.is_empty(): return false
	var d: Dictionary = _drafts[key]
	if Tuning.schema_fingerprint(d.profile) != d.schema_fingerprint:
		error = "参数结构已变化；草稿已保留，请重开调参会话"
		return false
	name = name.strip_edges()
	var new_source := JSON.stringify([d.profile, name, d.target_id])
	if _sources.has(new_source) and _sources[new_source] != key:
		error = "目标方案另有会话草稿，请切到该草稿覆盖，或另存新名称"
		return false
	var expected: String = d.base_fingerprint if name == d.preset else expected_target
	if not Tuning.save_candidate(d.profile, name, d.values, overwrite, expected):
		error = Tuning.last_error
		return false
	_sources.erase(d.source_key)
	d.source_key = new_source
	d.preset = name
	d.candidate_name = name
	d.baseline = d.values.duplicate(true)
	d.base_fingerprint = Tuning.fingerprint(d.profile, d.values)
	_sources[new_source] = key
	changed.emit(key)
	return true

func activate(key: String) -> bool:
	error = ""
	if not _drafts.has(key): error = "草稿不存在"; return false
	var d: Dictionary = _drafts[key]
	if dirty(key): error = "请先保存当前草稿，再明确设为默认"; return false
	if Tuning.saved_fingerprint(d.profile, d.preset, true) != d.base_fingerprint:
		error = "磁盘方案已变化，请先核对；未修改默认"
		return false
	if not Tuning.set_active_preset(d.profile, d.preset): error = Tuning.last_error; return false
	changed.emit("")
	return true

func reload_from_disk(key: String, discard_unsaved := false) -> bool:
	error = ""
	if not _drafts.has(key): error = "草稿不存在"; return false
	var d: Dictionary = _drafts[key]
	if dirty(key) and not discard_unsaved:
		error = "本草稿尚未保存；请另存或明确确认丢弃后重读"
		return false
	if Tuning.schema_fingerprint(d.profile) != d.schema_fingerprint:
		error = "参数结构已变化，请重开会话；当前草稿保留"
		return false
	var fingerprint := Tuning.saved_fingerprint(d.profile, d.preset, true)
	if fingerprint.is_empty(): error = "磁盘方案已不存在，草稿保留，可另存新名称"; return false
	d.values = Tuning.preset_values(d.profile, d.preset)
	d.baseline = d.values.duplicate(true)
	d.base_fingerprint = fingerprint
	d.undo.clear()
	d.redo.clear()
	d.revision += 1
	changed.emit(key)
	return true

func snapshot(key: String, form := "combat") -> Dictionary:
	if not _drafts.has(key): return {}
	var d: Dictionary = _drafts[key]
	return {"version": 1, "kind": "tuning_snapshot", "session_id": session_id, "draft_id": key,
		"identity": Catalog.identity(d.profile, form), "preset": d.preset, "target_id": d.target_id,
		"revision": d.revision, "base_fingerprint": d.base_fingerprint, "schema_fingerprint": d.schema_fingerprint,
		"values": d.values.duplicate(true)}

func test_selection(key: String, scene_id: String) -> Dictionary:
	# 只建立“本轮场景选用”的数据合同；真正装配／应用由 T04/T06 执行。
	if not _drafts.has(key) or scene_id.is_empty() or not validation(key).is_empty(): return {}
	return {"kind": "test_selection", "scene_id": scene_id, "snapshot": snapshot(key),
		"scope": "this_test_only", "runtime_applied": false, "project_default_changed": false}

func accept_result(key: String, packet: Dictionary) -> bool:
	error = "结果不属于当前会话／对象，或草稿修订已经变化"
	if not _drafts.has(key): return false
	var d: Dictionary = _drafts[key]
	if packet.get("version") != 1 or packet.get("kind") != "tuning_snapshot" or packet.get("session_id") != session_id or packet.get("draft_id") != key: return false
	if packet.get("revision") != d.revision or packet.get("base_fingerprint") != d.base_fingerprint or packet.get("schema_fingerprint") != Tuning.schema_fingerprint(d.profile): return false
	if not packet.get("identity") is Dictionary or packet.identity.get("role_id") != Catalog.identity(d.profile).get("role_id") or packet.identity.get("profile") != d.profile or packet.get("target_id") != d.target_id: return false
	if packet.identity.get("form") not in ["combat", "visual"] or packet.get("preset") != d.preset: return false
	if not packet.get("values") is Dictionary: return false
	var next: Dictionary = packet.values
	if next.size() != d.values.size(): return false
	for field: String in next:
		if not d.values.has(field): return false
	error = Tuning.validate(d.profile, next)
	if not error.is_empty(): return false
	_replace(key, next)
	return true
