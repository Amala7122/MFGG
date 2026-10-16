extends RefCounted
## 玩家资源按交战实例绑定；普通冷却保留交接，同一实例不重复发放初始库存。
var _owner: WeakRef
var _entry: Dictionary = {}
var _encounters: Dictionary = {}
var _normal_wait := 0.0

func active() -> bool:
	return _owner != null

func owner_alive() -> bool:
	return _owner != null and is_instance_valid(_owner.get_ref())

func matches(host: Node) -> bool:
	return _owner != null and _owner.get_ref() == host

func enter(host: Node, values: Dictionary, current_wait: float) -> float:
	if matches(host) or not bool(values.get("grenade_reserve_enabled", false)):
		return current_wait
	if active():
		current_wait = leave(current_wait)
	for key: int in _encounters.keys():
		if not is_instance_valid(_encounters[key].owner.get_ref()):
			_encounters.erase(key)
	var id := host.get_instance_id()
	if not _encounters.has(id):
		_encounters[id] = {"owner": weakref(host), "capacity": int(values.grenade_reserve_capacity), "charges": int(values.grenade_reserve_start),
			"interval": float(values.grenade_throw_interval), "recharge": float(values.grenade_recharge_seconds), "remaining": 0.0, "throw_wait": 0.0}
		if int(_encounters[id].charges) < int(_encounters[id].capacity):
			_encounters[id].remaining = _encounters[id].recharge
	_entry = _encounters[id]
	_owner = weakref(host)
	_normal_wait = maxf(_normal_wait, current_wait)
	return maxf(current_wait, float(_entry.throw_wait))

func leave(current_wait: float) -> float:
	if not active():
		return current_wait
	_entry.throw_wait = current_wait
	_owner = null
	_entry = {}
	return maxf(current_wait, _normal_wait)

func count() -> int:
	return int(_entry.charges) if active() else -1

func spend(normal_cooldown: float) -> float:
	if not active() or count() <= 0:
		return -1.0
	if count() == int(_entry.capacity):
		_entry.remaining = _entry.recharge
	_entry.charges = count() - 1
	_entry.throw_wait = _entry.interval
	_normal_wait = maxf(_normal_wait, normal_cooldown)
	return float(_entry.interval)

func tick(delta: float) -> void:
	_normal_wait = maxf(_normal_wait - delta, 0.0)
	for entry: Dictionary in _encounters.values():
		entry.throw_wait = maxf(float(entry.throw_wait) - delta, 0.0)
	if not active():
		return
	if count() >= int(_entry.capacity):
		_entry.remaining = 0.0
		return
	_entry.remaining = float(_entry.remaining) - delta
	while float(_entry.remaining) <= 0.00000001 and count() < int(_entry.capacity):
		_entry.charges = count() + 1
		_entry.remaining = float(_entry.remaining) + float(_entry.recharge)
	if count() >= int(_entry.capacity):
		_entry.remaining = 0.0

func snapshot(current_wait: float) -> Dictionary:
	if not active():
		return {"mode": "cooldown", "throw_remaining": current_wait}
	return {"mode": "reserve", "charges": count(), "capacity": int(_entry.capacity), "throw_interval": float(_entry.interval),
		"throw_remaining": current_wait, "recharge_seconds": float(_entry.recharge), "recharge_remaining": float(_entry.remaining)}
