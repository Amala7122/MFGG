extends RefCounted
## 玩家近战唯一参数源；草稿与保存分开。保存时在项目外保留旧值和校验记录。
const PATH := "res://data/player_melee/default.json"
const Artifacts := preload("res://scripts/artifact_paths.gd")
# 名称、单位、最小、最大、步长；不在面板维护第二套默认数值。
const FIELDS := {
	"sweep_damage": ["轻扫伤害", "点", 0.0, 10000.0, 1.0],
	"sweep_reach": ["轻扫距离", "m", 0.5, 12.0, 0.1],
	"sweep_radius": ["轻扫查询半径", "m", 0.2, 8.0, 0.1],
	"sweep_half_angle": ["轻扫半角", "度", 5.0, 180.0, 1.0],
	"sweep_max_targets": ["轻扫目标上限", "个", 1.0, 20.0, 1.0],
	"sweep_push": ["轻扫推力", "m/s", 0.0, 30.0, 0.5],
	"sweep_windup": ["轻扫前摇", "s", 0.02, 1.0, 0.01],
	"sweep_active": ["轻扫出手段", "s", 0.01, 0.5, 0.01],
	"sweep_total": ["轻扫总时长", "s", 0.05, 2.0, 0.01],
	"sweep_cancel": ["轻扫连段开放", "s", 0.02, 2.0, 0.01],
	"sweep_lunge": ["轻扫命中前进", "m", 0.0, 2.0, 0.05],
	"sweep_speed_scale": ["轻扫移动倍率", "倍", 0.0, 1.0, 0.05],
	"heavy_damage": ["重击伤害", "点", 0.0, 20000.0, 1.0],
	"heavy_reach": ["重击距离", "m", 0.5, 12.0, 0.1],
	"heavy_radius": ["重击查询半径", "m", 0.2, 8.0, 0.1],
	"heavy_half_angle": ["重击半角", "度", 5.0, 180.0, 1.0],
	"heavy_max_targets": ["重击目标上限", "个", 1.0, 20.0, 1.0],
	"heavy_push": ["重击推力", "m/s", 0.0, 30.0, 0.5],
	"heavy_armor_pen": ["重击护甲穿透", "比例", 0.0, 1.0, 0.05],
	"heavy_stagger": ["普通敌人重击硬直", "s", 0.0, 3.0, 0.05],
	"heavy_lunge": ["重击前进", "m", 0.0, 3.0, 0.05],
	"heavy_windup": ["重击前摇", "s", 0.02, 1.0, 0.01],
	"heavy_active": ["重击出手段", "s", 0.01, 0.5, 0.01],
	"heavy_total": ["重击总时长", "s", 0.05, 2.0, 0.01],
	"heavy_cooldown": ["重击冷却", "s", 0.1, 15.0, 0.1],
	"charge_enter": ["长按进入蓄力", "s", 0.02, 0.5, 0.01],
	"charge_threshold": ["重击蓄满阈值", "s", 0.1, 2.0, 0.05],
	"charge_auto": ["长按自动释放", "s", 0.2, 3.0, 0.05],
	"charge_speed_scale": ["蓄力移动倍率", "倍", 0.0, 1.0, 0.05],
	"interrupt_cooldown_scale": ["蓄力被打断冷却", "倍", 0.0, 1.0, 0.05],
	"combo_reset": ["连段重置", "s", 0.1, 3.0, 0.05],
	"input_buffer": ["输入缓存", "s", 0.05, 0.5, 0.01],
	"candidate_limit": ["碰撞候选预算", "个", 16.0, 256.0, 1.0]
}

static func load_values() -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not raw is Dictionary:
		push_error("玩家近战配置读取失败：" + PATH)
		return {}
	return validate(raw)

static func validate(raw: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in FIELDS:
		if not raw.has(key) or not (raw[key] is float or raw[key] is int):
			push_error("玩家近战参数缺失或非数值：" + key)
			return {}
		var spec: Array = FIELDS[key]
		result[key] = clampf(float(raw[key]), float(spec[2]), float(spec[3]))
	for kind in ["sweep", "heavy"]:
		result[kind + "_total"] = maxf(result[kind + "_total"], result[kind + "_windup"] + result[kind + "_active"] + 0.01)
	result.sweep_cancel = clampf(result.sweep_cancel, result.sweep_windup + result.sweep_active, result.sweep_total)
	result.charge_threshold = maxf(result.charge_threshold, result.charge_enter)
	result.charge_auto = maxf(result.charge_auto, result.charge_threshold)
	return result

static func save_values(raw: Dictionary) -> Error:
	var values := validate(raw)
	if values.is_empty():
		return ERR_INVALID_DATA
	if OS.has_feature("standalone"):
		return ERR_UNAVAILABLE # 项目默认只能由编辑器运行显式写回。
	var stamp := str(Time.get_ticks_usec())
	var backup := Artifacts.ensure_dir("reports").path_join("melee_previous_" + stamp + ".json")
	var original := FileAccess.open(PATH, FileAccess.READ)
	if original == null:
		return FileAccess.get_open_error()
	var previous := original.get_as_text()
	original.close()
	var kept := FileAccess.open(backup, FileAccess.WRITE)
	if kept == null:
		return FileAccess.get_open_error()
	kept.store_string(previous)
	kept.flush()
	var backup_error := kept.get_error()
	kept.close()
	if backup_error != OK or FileAccess.get_sha256(backup) != previous.sha256_text():
		return ERR_FILE_CORRUPT
	var temporary := Artifacts.ensure_dir("tmp").path_join("melee_" + stamp + ".json")
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(values, "  ") + "\n")
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		return write_error
	var saved := DirAccess.rename_absolute(temporary, ProjectSettings.globalize_path(PATH))
	if saved != OK:
		push_error("近战配置保存失败，项目原值保留：%s" % error_string(saved))
	return saved
