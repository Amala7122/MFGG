extends RefCounted
## 单次实验的结算记录器。不保留敌人对象，不写正式战绩。

const SOURCES := ["primary", "sniper", "E", "Q", "unknown"]
var active := false
var paused := true
var started := false
var time := 0.0
var result := "尚未开始"
var conditions: Dictionary = {}
var player: Dictionary = {}
var sources: Dictionary = {}
var species: Dictionary = {}
var incoming: Dictionary = {}
var enemies: Dictionary = {}
var segments: Array[Dictionary] = []
var wave_count := 0
var wave_total_time := 0.0
var last_wave: Dictionary = {}
var health_loss := 0.0
var shield_loss := 0.0
var received_hits := 0
var shield_breaks := 0
var health_regen := 0.0
var shield_regen := 0.0
var heal := 0.0
var invincible_attempts := 0
var invincible_raw := 0.0
var rejected_hits := 0
var kills := 0
var unassigned_deaths := 0
var _next_shot := 0
var _recent: Array[Dictionary] = []
var _wave_start: Dictionary = {}
var _segment_key := ""


func _init(config: Dictionary = {}) -> void:
	conditions = config.duplicate(true)
	for key in SOURCES:
		sources[key] = {"damage": 0.0, "uses": 0, "hit_shots": 0, "impacts": 0,
			"headshots": 0, "kills": 0, "pickup": 0.0, "reloads": 0, "reload_time": 0.0, "last_hit": -1}


func accepting() -> bool:
	return active and not paused


func start() -> void:
	if started:
		return
	started = true
	active = true
	paused = false
	result = "战斗中"
	_wave_start = _totals()


func stop(reason: String) -> void:
	if started and active:
		active = false
		result = reason


func advance(delta: float) -> void:
	if accepting():
		time += maxf(delta, 0.0)
		while not _recent.is_empty() and float(_recent[0].time) < time - 30.0:
			_recent.pop_front()


func capture_player(actor: Node) -> void:
	if not is_instance_valid(actor) or (started and (not active or paused)):
		return
	var weapon: Node = actor.get("_weapon")
	if not is_instance_valid(weapon):
		return
	player = weapon.call("get_combat_snapshot")
	player["health"] = actor.get("health")
	player["max_health"] = actor.get("max_health")
	player["shield"] = actor.get("shield")
	player["max_shield"] = actor.get("max_shield")
	player["invincible"] = bool(actor.get_meta(&"experiment_invincible", false))
	var key := "%d/%d/%d/%d/%d/%s" % [player.level, player.damage_stacks, player.rate_stacks,
		player.magazine_stacks, int(conditions.get("mode", 0)), str(player.invincible)]
	if key != _segment_key:
		_segment_key = key
		segments.append({"time": time, "player": player.duplicate(true),
			"mode": int(conditions.get("mode", 0)), "totals": _totals()})


func set_mode(mode: int) -> void:
	if int(conditions.get("mode", 0)) != mode:
		conditions["mode"] = mode
		_wave_start = _totals()


func register_enemy(enemy: Node) -> void:
	var id := String(enemy.get_meta(&"lab_roster_id", "unknown"))
	var ranged := String(enemy.get_meta(&"lab_kind", "melee")) == "ranged"
	if not species.has(id):
		species[id] = {"title": String(enemy.get_meta(&"lab_title", id)), "alive": 0, "spawned": 0,
			"kills": 0, "unassigned": 0, "damage": 0.0, "ttk_sum": 0.0, "ttk_samples": 0,
			"wait_sum": 0.0, "wait_samples": 0, "primary_ammo": 0, "sniper_ammo": 0,
			"mixed": 0, "health": float(enemy.get("max_health")), "armor": float(enemy.get("_armor")),
			"speed": float(enemy.get("move_speed")), "speed_sum": 0.0, "speed_samples": 0,
			"received_hits": 0, "health_loss": 0.0, "shield_loss": 0.0,
			"invincible_attempts": 0, "invincible_raw": 0.0,
			"attack_damage": float(enemy.get("projectile_damage" if ranged else "attack_damage")) * float(enemy.get("_damage_scale")),
			"attack_interval": float(enemy.get("fire_interval" if ranged else "attack_interval")),
			"configured_ranges": {}}
	var row: Dictionary = species[id]
	row.alive += 1
	row.spawned += 1
	var spatial := enemy as Node3D
	var configured := {"health": float(enemy.get("max_health")), "armor": float(enemy.get("_armor")),
		"speed": float(enemy.get("move_speed")), "size": spatial.scale.x if spatial else 1.0,
		"attack_damage": float(enemy.get("projectile_damage" if ranged else "attack_damage")) * float(enemy.get("_damage_scale")),
		"attack_interval": float(enemy.get("fire_interval" if ranged else "attack_interval"))}
	for field: String in configured:
		var value := float(configured[field])
		row[field] = float(row.get(field, value)) + (value - float(row.get(field, value))) / int(row.spawned)
		var bounds: Dictionary = row.configured_ranges.get(field, {"min": value, "max": value})
		bounds.min = minf(float(bounds.min), value)
		bounds.max = maxf(float(bounds.max), value)
		row.configured_ranges[field] = bounds
	enemies[enemy.get_instance_id()] = {"id": id, "born": time, "first_hit": -1.0, "dead": false,
		"shots": {}, "ammo": {"primary": 0, "sniper": 0}, "contributors": {}}


func enemy_damaged(enemy: Node, before: float, after: float, context: Dictionary) -> void:
	if not accepting() or not enemies.has(enemy.get_instance_id()):
		return
	var life: Dictionary = enemies[enemy.get_instance_id()]
	if life.dead:
		return
	var effective := maxf(maxf(before, 0.0) - maxf(after, 0.0), 0.0)
	if effective <= 0.0:
		return
	var key := String(context.get("source", "unknown"))
	if not sources.has(key):
		key = "unknown"
	var src: Dictionary = sources[key]
	var row: Dictionary = species[life.id]
	src.damage += effective
	if key != "unknown":
		row.damage += effective
		life.contributors[key] = true
		if float(life.first_hit) < 0.0:
			life.first_hit = time
			row.wait_sum += time - float(life.born)
			row.wait_samples += 1
		_recent.append({"time": time, "damage": effective})
	if key in ["primary", "sniper"]:
		var shot := int(context.get("shot", 0))
		if shot > 0:
			if int(src.last_hit) != shot:
				src.hit_shots += 1
				src.last_hit = shot
			if int(life.shots.get(key, -1)) != shot:
				life.ammo[key] += 1
				life.shots[key] = shot
			src.impacts += 1
			if key == "sniper" and bool(context.get("headshot", false)):
				src.headshots += 1
	if after <= 0.0:
		life.dead = true
		# 有死亡演出的原型可能稍后才退出树，生命归零时已经不算存活。
		row.alive = maxi(int(row.alive) - 1, 0)
		if key == "unknown":
			unassigned_deaths += 1
			src.kills += 1
			row.unassigned += 1
		else:
			kills += 1
			row.kills += 1
			src.kills += 1
			row.ttk_sum += time - float(life.first_hit)
			row.ttk_samples += 1
			row.primary_ammo += int(life.ammo.primary)
			row.sniper_ammo += int(life.ammo.sniper)
			if life.contributors.size() > 1:
				row.mixed += 1
			_recent.append({"time": time, "kills": 1})


func remove_enemy(instance_id: int, count_death: bool = true) -> void:
	if not enemies.has(instance_id):
		return
	var life: Dictionary = enemies[instance_id]
	var row: Dictionary = species[life.id]
	if not life.dead:
		row.alive = maxi(int(row.alive) - 1, 0)
	if accepting() and count_death and not life.dead:
		unassigned_deaths += 1
		sources.unknown.kills += 1
		row.unassigned += 1
	enemies.erase(instance_id)


func sample_motion(actors: Array[Node3D]) -> void:
	if not accepting():
		return
	for actor in actors:
		if not is_instance_valid(actor) or actor.is_queued_for_deletion():
			continue
		var body := actor as CharacterBody3D
		var life: Dictionary = enemies.get(actor.get_instance_id(), {})
		if body == null or life.is_empty():
			continue
		var v := body.get_real_velocity()
		var row: Dictionary = species[life.id]
		row.speed_sum += Vector2(v.x, v.z).length()
		row.speed_samples += 1


func begin_attack(source: String) -> int:
	if not accepting() or not sources.has(source):
		return 0
	_next_shot += 1
	sources[source].uses += 1
	return _next_shot


func player_damaged(info: Dictionary, raw: float, hp: float, sp: float, broken: bool, blocked: String) -> void:
	if not accepting():
		return
	var id := String(info.get("id", "unknown"))
	var attack := String(info.get("attack", "未归属"))
	var key := id + "/" + attack
	if (blocked == "无敌" or hp + sp > 0.0) and not incoming.has(key):
		incoming[key] = {"title": String(info.get("title", "未归属")), "attack": attack,
			"hits": 0, "health": 0.0, "shield": 0.0, "invincible_attempts": 0, "invincible_raw": 0.0}
	if blocked == "无敌":
		invincible_attempts += 1
		invincible_raw += raw
		incoming[key].invincible_attempts += 1
		incoming[key].invincible_raw += raw
		if species.has(id):
			species[id].invincible_attempts += 1
			species[id].invincible_raw += raw
		return
	if not blocked.is_empty() or hp + sp <= 0.0:
		rejected_hits += 1
		return
	health_loss += hp
	shield_loss += sp
	received_hits += 1
	if broken:
		shield_breaks += 1
	var row: Dictionary = incoming[key]
	row.hits += 1
	row.health += hp
	row.shield += sp
	if species.has(id):
		species[id].received_hits += 1
		species[id].health_loss += hp
		species[id].shield_loss += sp
	_recent.append({"time": time, "hp": hp, "shield": sp})


func resource(source: String, kind: String, amount: float) -> void:
	if not accepting() or amount <= 0.0:
		return
	if source == "player":
		match kind:
			"health_regen": health_regen += amount
			"shield_regen": shield_regen += amount
			"heal": heal += amount
	elif sources.has(source):
		match kind:
			"pickup": sources[source].pickup += amount
			"reload": sources[source].reloads += int(amount)
			"reload_time": sources[source].reload_time += amount


func complete_wave() -> void:
	if not accepting():
		return
	var now := _totals()
	last_wave = {}
	for key in now:
		last_wave[key] = float(now[key]) - float(_wave_start.get(key, 0.0))
	wave_count += 1
	wave_total_time += float(last_wave.time)
	_wave_start = now


func _totals() -> Dictionary:
	var damage := 0.0
	for key in ["primary", "sniper", "E", "Q"]:
		damage += float(sources[key].damage)
	return {"time": time, "damage": damage, "kills": kills, "health": health_loss,
		"shield": shield_loss, "primary": int(sources.primary.uses), "sniper": int(sources.sniper.uses)}


func rolling(seconds: float) -> Dictionary:
	var out := {"damage": 0.0, "hp": 0.0, "shield": 0.0, "kills": 0}
	for event in _recent:
		if float(event.time) > time - seconds or time < seconds:
			for key in out:
				out[key] += event.get(key, 0)
	out["duration"] = minf(time, seconds)
	return out


func snapshot() -> Dictionary:
	return {"time": time, "active": active, "started": started, "result": "已暂停" if active and paused else result,
		"conditions": conditions.duplicate(true), "player": player.duplicate(true),
		"sources": sources.duplicate(true), "species": species.duplicate(true), "incoming": incoming.duplicate(true),
		"segments": segments.duplicate(true), "totals": _totals(), "recent5": rolling(5.0), "recent30": rolling(30.0),
		"health_loss": health_loss, "shield_loss": shield_loss, "received_hits": received_hits, "shield_breaks": shield_breaks,
		"health_regen": health_regen, "shield_regen": shield_regen, "heal": heal,
		"invincible_attempts": invincible_attempts, "invincible_raw": invincible_raw, "rejected_hits": rejected_hits,
		"wave_count": wave_count, "last_wave": last_wave.duplicate(), "wave_average": wave_total_time / maxf(wave_count, 1.0),
		"unassigned_deaths": unassigned_deaths}


func live_snapshot() -> Dictionary:
	# 实时三项读数不需要每帧深拷贝完整兵种表和历史分段。
	return {"recent5": rolling(5.0), "recent30": rolling(30.0)}
