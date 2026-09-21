extends Node
## 存档（autoload）。
##
## 原来最好成绩只是 player.gd 里的一个 static var，重启游戏就丢。
## 这里统一负责读写 user://save.cfg，并作为"最好成绩"的唯一真相来源。

static var instance: Node

const SAVE_PATH := "user://save.cfg"
const SECTION := "progress"

var best_survival := 0.0
var best_kills := 0
var total_runs := 0


func _ready() -> void:
	instance = self
	load_data()


func load_data() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	best_survival = float(config.get_value(SECTION, "best_survival", 0.0))
	best_kills = int(config.get_value(SECTION, "best_kills", 0))
	total_runs = int(config.get_value(SECTION, "total_runs", 0))


func save_data() -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION, "best_survival", best_survival)
	config.set_value(SECTION, "best_kills", best_kills)
	config.set_value(SECTION, "total_runs", total_runs)
	config.save(SAVE_PATH)


## 一局结束时调用。返回是否刷新了最好成绩。
func record_run(survival: float, kills: int) -> bool:
	total_runs += 1
	var improved := survival > best_survival
	best_survival = maxf(best_survival, survival)
	best_kills = maxi(best_kills, kills)
	save_data()
	return improved


# ---------------------------------------------------------------- 静态入口

static func get_best_survival() -> float:
	return float(instance.best_survival) if instance else 0.0


static func get_best_kills() -> int:
	return int(instance.best_kills) if instance else 0


static func get_total_runs() -> int:
	return int(instance.total_runs) if instance else 0


static func submit_run(survival: float, kills: int) -> bool:
	return bool(instance.record_run(survival, kills)) if instance else false
