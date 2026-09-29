extends RefCounted
## 共用步态预设 + 条目覆盖。每次返回独立字典，避免兵种之间串参数。

const Config := preload("res://scripts/game_config.gd")
const MOTION_FIELDS := ["turn_speed", "accel_ratio", "brake_ratio"]


static func resolve(entry: Dictionary) -> Dictionary:
	var fallback := "ranged" if entry.get("kind", "melee") == "ranged" else "normal"
	if fallback == "normal":
		var size := float(entry.get("scale", 1.0))
		fallback = "light" if size <= 0.85 else ("heavy" if size >= 1.35 else "normal")
	var preset := String(entry.get("gait_preset", fallback))
	var settings := Config.get_dictionary("enemy_gaits." + preset).duplicate(true)
	if settings.is_empty():
		settings = Config.get_dictionary("enemy_gaits." + fallback).duplicate(true)
	var overrides: Variant = entry.get("gait", {})
	if overrides is Dictionary:
		settings.merge(overrides, true)
	return settings
