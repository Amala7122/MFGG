extends RefCounted
## 本轮草稿唯一所有者；不持有游戏 Node、不自动保存、不改变正式默认。
signal changed(draft_id: String)
const Tuning := preload("res://scripts/prototypes/enemy_tuning.gd")
const Catalog := preload("res://scripts/testing/tuning_catalog.gd")
const Ownership := preload("res://scripts/testing/enemy_parameter_ownership.gd")
static var _shared: RefCounted
var session_id := "%d:%d" % [OS.get_process_id(), Time.get_ticks_usec()]
var error := ""
var _storage := Tuning.storage_directory
var _drafts: Dictionary = {}
var _sources: Dictionary = {}
var _last: Dictionary = {}
var _serial := 0
var _views: Dictionary = {}
var scene_presets: Dictionary = {}

func choose_scene_preset(key: String, scene_path: String) -> bool:
	error = ""
	if not _drafts.has(key) or dirty(key) or not validation(key).is_empty():
		error = "请先显式保存有效命名方案"
		return false
	var d: Dictionary = _drafts[key]
	if not test_selection(key, scene_path).get("reason", "").is_empty():
		error = "仍有未提交原文；请回所属专业台修正／撤回"
		return false
	if Tuning.saved_fingerprint(d.profile, d.preset, true) != d.base_fingerprint:
		error = "磁盘方案有外部修改；请核对后再选用，草稿保留"
		return false
	scene_presets[scene_path + ":" + d.profile] = {"preset": d.preset, "fingerprint": d.base_fingerprint}
	return true

func scene_preset(scene_path: String, profile: String) -> String:
	var choice: Dictionary = scene_presets.get(scene_path + ":" + profile, {})
	if choice.is_empty(): return ""
	if Tuning.saved_fingerprint(profile, choice.preset, true) != choice.fingerprint:
		error = "本场景选用方案已被外部修改，未采用；请重新明确选用"
		return ""
	return choice.preset

func view_data(key: String, domain: String) -> Dictionary:
	return _views.get(key + ":" + domain, {}).duplicate(true)

func store_view(key: String, domain: String, state: Dictionary) -> void:
	_views[key + ":" + domain] = state.duplicate(true)

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
			"values": values.duplicate(true), "baseline": values.duplicate(true), "last_valid": values.duplicate(true), "base_fingerprint": Tuning.fingerprint(profile, values),
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

func preview_values(key: String) -> Dictionary:
	if not _drafts.has(key): return {}
	var d: Dictionary = _drafts[key]
	if Tuning.validate(d.profile, d.values).is_empty(): d.last_valid = d.values.duplicate(true)
	return d.last_valid.duplicate(true)

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
	var issue := Tuning.field_issue(spec, value)
	if not issue.is_empty():
		error = "%s：%s" % [spec.label, issue.message]
		return false
	if data.values[field] == value: return true
	var next: Dictionary = data.values.duplicate(true)
	next[field] = value
	_replace(key, next, Ownership.owner(data.profile, field))
	return true

func set_domain_value(key: String, domain: String, field: String, value: Variant) -> bool:
	if not _drafts.has(key) or not Ownership.editable(_drafts[key].profile, field, domain):
		error = "此参数归属其他模块，请通过专业入口编辑；草稿保留"
		return false
	return set_value(key, field, value)

func history_owner(key: String, forward := false) -> String:
	if not _drafts.has(key): return ""
	var stack: Array = _drafts[key].redo if forward else _drafts[key].undo
	return "" if stack.is_empty() else String(stack.back().domain)

func domain_history(key: String, domain: String, forward := false) -> bool:
	error = ""
	var latest := history_owner(key, forward)
	if latest.is_empty(): return true
	if latest != domain and not (domain == "combat_prototype" and latest == "player_conditions"):
		error = "最近操作来自%s，请进入该模块%s；不会越过中间历史" % [Ownership.TITLES.get(latest, "整对象操作"), "重做" if forward else "撤销"]
		return false
	if forward: redo(key)
	else: undo(key)
	return true

func restore_domain(key: String, domain: String, defaults := false) -> void:
	if not _drafts.has(key): return
	var d: Dictionary = _drafts[key]
	var baseline: Dictionary = Tuning.defaults(d.profile) if defaults else d.baseline
	var next: Dictionary = d.values.duplicate(true)
	for field: String in next:
		if Ownership.editable(d.profile, field, domain): next[field] = baseline[field]
	if next != d.values: _replace(key, next, domain)

func _replace(key: String, next: Dictionary, domain := "whole_object") -> void:
	var d: Dictionary = _drafts[key]
	d.undo.append({"values": d.values.duplicate(true), "domain": domain})
	if d.undo.size() > 64: d.undo.pop_front()
	d.redo.clear()
	d.values = next.duplicate(true)
	if Tuning.validate(d.profile, d.values).is_empty(): d.last_valid = d.values.duplicate(true)
	d.revision += 1
	changed.emit(key)

func undo(key: String) -> void:
	if not _drafts.has(key): return
	var d: Dictionary = _drafts[key]
	if d.undo.is_empty(): return
	var item: Dictionary = d.undo.pop_back()
	d.redo.append({"values": d.values.duplicate(true), "domain": item.domain})
	d.values = item.values
	d.revision += 1
	changed.emit(key)

func redo(key: String) -> void:
	if not _drafts.has(key): return
	var d: Dictionary = _drafts[key]
	if d.redo.is_empty(): return
	var item: Dictionary = d.redo.pop_back()
	d.undo.append({"values": d.values.duplicate(true), "domain": item.domain})
	d.values = item.values
	d.revision += 1
	changed.emit(key)

func restore(key: String, defaults := false) -> void:
	if not _drafts.has(key): return
	_replace(key, Tuning.defaults(_drafts[key].profile) if defaults else _drafts[key].baseline)

func save_as(key: String, name: String, overwrite := false, expected_target := "") -> bool:
	for view: String in _views:
		if view.begins_with(key + ":") and not _views[view].get("pending", {}).is_empty():
			var domain := view.trim_prefix(key + ":")
			error = "%s仍有未提交输入；请从专业入口修正／撤回后再保存整份方案，草稿与原文保留" % Ownership.TITLES.get(domain, domain)
			return false
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

func test_selection(key: String, scene_id: String, runtime_apply := Callable()) -> Dictionary:
	if not _drafts.has(key) or scene_id.is_empty() or not validation(key).is_empty(): return {}
	var selection := {"kind": "test_selection", "scene_id": scene_id, "snapshot": snapshot(key),
		"scope": "this_test_only", "runtime_applied": false, "project_default_changed": false}
	var d: Dictionary = _drafts[key]
	if Tuning.schema_fingerprint(d.profile) != d.schema_fingerprint or Tuning.saved_fingerprint(d.profile, d.preset, true) != d.base_fingerprint:
		selection.reason = "来源方案／参数结构已在外部变化；草稿保留，请核对后重读或另存"
		return selection
	for view: String in _views:
		if view.begins_with(key + ":") and not _views[view].get("pending", {}).is_empty():
			selection.reason = "有未提交／非法原文；保留最后有效运行值，请回专业台修正或撤回"
			return selection
	if runtime_apply.is_valid():
		var result: Dictionary = runtime_apply.call(selection.snapshot)
		selection.merge(result, true)
	return selection

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
