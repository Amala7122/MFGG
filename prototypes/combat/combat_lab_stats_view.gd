extends RefCounted
## 只负责呈现，统计计算在记录器内完成。

const NAMES := {"primary": "主射击", "sniper": "狙击", "E": "E 手雷", "Q": "Q 脉冲", "unknown": "未归属"}


static func weapon_text(p: Dictionary) -> String:
	if p.is_empty():
		return "武器数据准备中"
	var power := "威力 %.1f / 弹" % float(p.damage)
	if int(p.pellets) > 1:
		power += " × %d" % int(p.pellets)
	return "武器 LV %d · %s\n%s · 射速 %.2f 发/秒\n主武器强化：威力 +%.0f%% · 射速 +%.0f%%\n弹匣 %d 发 · 弹匣强化 %d 层\n狙击 %.1f / 发 · %.2f 发/秒" % [
		int(p.level), p.label, power, float(p.rate), float(p.damage_bonus), float(p.rate_bonus),
		int(p.capacity), int(p.magazine_stacks), float(p.sniper_damage), float(p.sniper_rate)]


static func live_text(s: Dictionary) -> String:
	var r: Dictionary = s.recent5
	var k: Dictionary = s.recent30
	var label := "承伤（含无敌模拟）" if int(r.get("simulated_hits", 0)) > 0 else "承伤"
	return "近 5 秒 DPS %.1f\n近 30 秒击杀 %d\n近 5 秒%s：生命 %.1f / 护盾 %.1f" % [
		_rate(float(r.damage), float(r.duration)), int(k.kills), label, float(r.hp), float(r.shield)]


static func _rate(value: float, duration: float) -> float:
	return value / duration if duration > 0.0 else 0.0


static func _average(value: float, count: int, unit: String = "") -> String:
	return "%.2f%s" % [value / float(count), unit] if count > 0 else "—"


static func _percent(value: int, count: int) -> String:
	return "%.1f%%" % (float(value) / float(count) * 100.0) if count > 0 else "—"


static func _title(text: String) -> String:
	return "\n[color=#dfc38a][b]" + text + "[/b][/color]\n"


static func _cells(values: Array) -> String:
	var line := ""
	for value in values:
		line += "[cell]" + str(value) + "[/cell]"
	return line


static func report(s: Dictionary) -> String:
	if not bool(s.started):
		return "[b]尚未开始战斗[/b]\n生成敌人并完成倒数后开始记录。\n暂停、倒数和配置阶段不计入统计。"
	var p: Dictionary = s.player
	var mode: String = ["单轮", "A · 整批循环", "B · 逐只补兵"][int(s.conditions.get("mode", 0))]
	var text := "[b]%s · %.1f 秒 · %s[/b]\n" % [s.result, float(s.time), mode]
	text += "起始玩家 / 敌人测试等级 %d · 起始阵容 %d 只 · 当前无敌：%s\n" % [
		int(s.conditions.get("level", 1)), int(s.conditions.get("count", 0)), "开启" if p.get("invincible", false) else "关闭"]
	text += _title("当前武器与玩家状态")
	text += weapon_text(p) + "\n"
	if not p.is_empty():
		text += "生命 %.1f / %.1f · 护盾 %.1f / %.1f\n" % [float(p.health), float(p.max_health), float(p.shield), float(p.max_shield)]
		if p.get("invincible", false):
			text += "无敌模拟护盾 %.1f / %.1f（真实血盾保持无敌）\n" % [float(p.get("pressure_shield", p.shield)), float(p.max_shield)]
		text += "主弹药 %d / %d · 备弹 %s；狙击 %d / %d · 备弹 %s\n" % [
			int(p.ammo), int(p.capacity), _reserve(int(p.reserve)), int(p.sniper_ammo), int(p.sniper_capacity), _reserve(int(p.sniper_reserve))]
		text += "当前装填：主武器 %.1f 秒 / 狙击 %.1f 秒；狙击爆头倍率 ×%.1f\n" % [float(p.reload), float(p.sniper_reload), float(p.headshot_multiplier)]
	text += _title("输出与承压")
	text += "有效总伤害 %.1f · 全程 DPS %.1f · 近 5 秒 DPS %.1f\n" % [float(s.totals.damage),
		_rate(float(s.totals.damage), float(s.time)), _rate(float(s.recent5.damage), float(s.recent5.duration))]
	text += "玩家击杀 %d · 未归属 / 环境死亡 %d · 近 30 秒击杀 %d（%.1f 只/分钟）\n" % [
		int(s.totals.kills), int(s.unassigned_deaths), int(s.recent30.kills), _rate(float(s.recent30.kills) * 60.0, float(s.recent30.duration))]
	if float(s.time) < 30.0:
		text += "开场阶段：输出窗口 %.1f 秒，击杀窗口 %.1f 秒；每分钟击杀率为当前窗口推算。\n" % [float(s.recent5.duration), float(s.recent30.duration)]
	text += "承伤合计：生命 %.1f · 护盾 %.1f · 有效受击 %d 次 · 破盾 %d 次\n" % [float(s.health_loss), float(s.shield_loss), int(s.received_hits), int(s.shield_breaks)]
	text += "其中实际损失：生命 %.1f / 护盾 %.1f；无敌模拟：生命 %.1f / 护盾 %.1f\n" % [
		float(s.health_loss) - float(s.simulated_health_loss), float(s.shield_loss) - float(s.simulated_shield_loss),
		float(s.simulated_health_loss), float(s.simulated_shield_loss)]
	text += "自动回血 %.1f / 回盾 %.1f · 拾取回血 %.1f\n" % [float(s.health_regen), float(s.shield_regen), float(s.heal)]
	text += "无敌模拟回盾 %.1f · 无敌有效命中 %d 次（原始攻击量 %.1f）· 其他免伤 / 无效判定 %d 次\n" % [
		float(s.simulated_shield_regen), int(s.invincible_attempts), float(s.invincible_raw), int(s.rejected_hits)]
	text += _title("武器与技能：来源拆分")
	text += "[table=6]" + _cells(["来源", "有效伤害 / 击杀", "开火 / 耗弹", "命中率", "补给 / 换弹", "装填时间"])
	for key in NAMES:
		var row: Dictionary = s.sources[key]
		var gun: bool = key in ["primary", "sniper"]
		var uses := "%d 发" % int(row.uses) if gun else ("%d 次" % int(row.uses) if key != "unknown" else "—")
		var accuracy := _percent(int(row.hit_shots), int(row.uses)) if gun else "—"
		if key == "sniper":
			accuracy += "\n爆头 " + _percent(int(row.headshots), int(row.impacts))
		text += _cells([NAMES[key], "%.1f / %d" % [float(row.damage), int(row.kills)], uses, accuracy,
			"+%d 发 / %d 次" % [int(row.pickup), int(row.reloads)] if gun else "—",
			"%.1f 秒 / %.1f%%" % [float(row.reload_time), _rate(float(row.reload_time) * 100.0, float(s.time))] if gun else "—"])
	text += "[/table]\n"
	text += _title("按兵种：击杀效率与场面压力")
	text += "承压数值包含无敌模拟，与上方承伤合计使用同一口径。\n"
	text += "[table=4]" + _cells(["兵种 / 存活 / 生成", "属性 / 实际水平速度", "击杀效率", "造成的承压"])
	for row: Dictionary in s.species.values():
		text += _cells(["%s\n存活 %d / 生成 %d" % [row.title, int(row.alive), int(row.spawned)],
			"生命 %.1f · 护甲 %.0f%%\n基础攻击 %s / 间隔 %s 秒\n配置移速 %s / 实测 %s\n体型 %s 倍" % [float(row.health), float(row.armor) * 100.0,
				_configured(row, "attack_damage"), _configured(row, "attack_interval"), _configured(row, "speed"), _average(float(row.speed_sum), int(row.speed_samples), " m/s"), _configured(row, "size")],
			"击杀 %d · TTK %s\n耗弹：主 %s / 狙 %s\n接战等待 %s · 混合击杀 %d" % [int(row.kills), _average(float(row.ttk_sum), int(row.ttk_samples), " 秒"),
				_average(float(row.primary_ammo), int(row.kills)), _average(float(row.sniper_ammo), int(row.kills)), _average(float(row.wait_sum), int(row.wait_samples), " 秒"), int(row.mixed)],
			"受击 %d 次\n生命 %.1f / 护盾 %.1f\n无敌命中 %d 次\n未归属死亡 %d" % [int(row.received_hits), float(row.health_loss), float(row.shield_loss), int(row.invincible_attempts), int(row.unassigned)]])
	text += "[/table]\n"
	text += _title("受击来源")
	if s.incoming.is_empty():
		text += "尚无有效承伤。\n"
	else:
		text += "[table=5]" + _cells(["兵种 / 攻击", "有效受击", "生命承伤", "护盾承伤", "无敌命中 / 原始量"])
		for row: Dictionary in s.incoming.values():
			text += _cells([row.title + " / " + row.attack, row.hits,
				"%.1f\n其中模拟 %.1f" % [float(row.health), float(row.simulated_health)],
				"%.1f\n其中模拟 %.1f" % [float(row.shield), float(row.simulated_shield)],
				"%d 次 / %.1f" % [int(row.invincible_attempts), float(row.invincible_raw)]])
		text += "[/table]\n"
	text += _title("循环表现")
	if int(s.conditions.get("mode", 0)) == 1:
		text += "完成 %d 批 · 平均每批 %.1f 秒\n" % [int(s.wave_count), float(s.wave_average)]
		if not s.last_wave.is_empty():
			var w: Dictionary = s.last_wave
			text += "上一批 %.1f 秒 · 伤害 %.1f · 耗弹 主 %d / 狙 %d · 承伤 生命 %.1f / 护盾 %.1f\n" % [float(w.time), float(w.damage), int(w.primary), int(w.sniper), float(w.health), float(w.shield)]
	elif int(s.conditions.get("mode", 0)) == 2:
		text += "B 模式以近 30 秒击杀率和资源消耗比较；不计算全灭时间。\n"
	else:
		text += "单轮结束用时见上方；接敌、移动、躲避与换弹均计入全程效率。\n"
	text += _title("等级、强化与模式变化（最近 8 段）")
	var segments: Array = s.segments
	for index in range(maxi(segments.size() - 8, 0), segments.size()):
		var segment: Dictionary = segments[index]
		var end: Dictionary = segments[index + 1].totals if index + 1 < segments.size() else s.totals
		var duration := float(end.time) - float(segment.time)
		var damage := float(end.damage) - float(segment.totals.damage)
		var weapon: Dictionary = segment.player
		text += "%.1f–%.1f 秒 · LV %d · 威力/射速/弹匣 %d/%d/%d 层 · %s · 无敌%s · DPS %.1f\n" % [
			float(segment.time), float(end.time), int(weapon.level), int(weapon.damage_stacks), int(weapon.rate_stacks), int(weapon.magazine_stacks),
			["单轮", "A", "B"][int(segment.mode)], "开" if weapon.invincible else "关", _rate(damage, duration)]
	text += _title("口径")
	text += "配置属性显示本轮生成个体的平均值；有差异时括号列出最小–最大值。\n"
	text += "无敌模拟按正式护盾倍率、破盾溢出、受击/翻滚免伤窗口和护盾恢复规则计入承压；真实血盾不扣除。\n模拟生命承伤在破盾后持续累计，不设死亡上限；实际损失和模拟承伤分别列出。切换无敌后重新以真实护盾开始模拟。\n"
	text += "有效伤害排除过量击杀与未归属伤害；生命、护盾及恢复分别记录。\n命中率按一次开火计算，多弹丸 / 穿透不重复计次；爆头率仅针对狙击有效命中。\nTTK 从首次玩家伤害到死亡；耗弹按该目标受到的射击次数，穿透的一发可同时贡献多个目标。\n实测均速包含攻击站定 / 击退，反映整体移动，不等于单独的追击速度。\n暂停、倒数、死亡演出不计时；补兵连续记录，手动生成清零；无样本显示“—”。"
	return text


static func _reserve(value: int) -> String:
	return "机制关闭" if value < 0 else str(value)


static func _configured(row: Dictionary, key: String) -> String:
	var result := "%.2f" % float(row.get(key, 1.0))
	var bounds: Dictionary = row.get("configured_ranges", {}).get(key, {})
	if not bounds.is_empty() and float(bounds.max) - float(bounds.min) > 0.001:
		result += "（%.2f–%.2f）" % [float(bounds.min), float(bounds.max)]
	return result
