extends RefCounted
const Settings := preload("res://tools/probes/sparring/sparring_settings.gd")
const Artifacts := preload("res://scripts/artifact_paths.gd")

static func phase_caption(scenario: Dictionary) -> String:
	return String({"full": "完整开场", "front": "前半直入", "rage": "狂暴直入"}.get(String(scenario.get("boss_phase", "full")), "未知阶段"))

static func group_summary(rows: Array) -> Array:
	var groups := {}
	for trial: Dictionary in rows:
		if trial.is_empty():
			continue
		var condition: Dictionary = trial.conditions
		var boss: bool = condition.get("scenario", {}).get("kind", "") == "boss_direct"
		var identity := {"scenario": condition.get("scenario", {}), "selection": {} if boss else condition.get("group_selection", {}),
			"actor_origin": trial.get("actor_origin", "legacy_scripted"), "participant": condition.get("participant", {}) if condition.get("mode") == "manual" else {},
			"model_source": trial.get("analysis", {}).get("imitation_audit", {}).get("source_input_sha256", "")}
		var key := JSON.stringify(identity).sha256_text()
		if not groups.has(key):
			groups[key] = {"scenario_id": condition.get("scenario_id", "legacy"), "group_id": "Boss直战·" + phase_caption(condition.scenario) if boss else condition.get("group_id", "unknown"), "actor_origin": identity.actor_origin, "identity": identity,
				"total": 0, "valid": 0, "deaths": 0, "wins": 0, "censored": 0, "excluded": 0, "profiles": [], "seeds": [], "incoming_sources": {}, "peak_one_second_loss": 0.0, "mathematically_unavoidable": false}
		var group: Dictionary = groups[key]
		group.total += 1
		if not bool(trial.get("analysis", {}).get("eligible_for_balance", false)):
			group.excluded += 1
			continue
		group.valid += 1
		group.peak_one_second_loss = maxf(float(group.peak_one_second_loss), float(trial.get("pressure", {}).get("peak_one_second", {}).get("durability_loss", 0.0)))
		if not group.profiles.has(String(condition.profile_id)):
			group.profiles.append(String(condition.profile_id))
		if not group.seeds.has(int(condition.seed)):
			group.seeds.append(int(condition.seed))
		if trial.outcome == "player_dead":
			group.deaths += 1
		elif trial.outcome in ["boss_dead", "enemies_defeated"]:
			group.wins += 1
		else:
			group.censored += 1
		for hit: Dictionary in trial.get("last_hits", []):
			var source := String(hit.details.get("source", {}).get("id", "unknown"))
			group.incoming_sources[source] = int(group.incoming_sources.get(source, 0)) + 1
	var output: Array = []
	for group: Dictionary in groups.values():
		group["interpretation"] = "样本无有效交战结论" if int(group.valid) == 0 else "有截断，完整胜负仍未知" if int(group.censored) > 0 else "已完成有效样本全败；不能证明所有操作必死" if int(group.deaths) == int(group.valid) else "这些条件下存在获胜样本；不等于所有玩家均可应对"
		group["incoming_scope"] = "每局最后至多六次受击，来源次数不冒充全场计数"
		output.append(group)
	return output

static func write(rows: Array, comparison := "") -> void:
	var directory := Artifacts.ensure_dir("reports", "sparring")
	var batch := {"schema_version": 3, "trials": rows, "time_is_quality_score": false, "comparison": comparison, "groups": group_summary(rows)}
	batch["cycle_contrasts"] = load("res://tools/probes/sparring/sparring_cycle_analysis.gd").contrasts(rows)
	batch["eligible_trials"] = rows.filter(func(row: Dictionary): return bool(row.get("analysis", {}).get("eligible_for_balance", false))).size()
	batch["review_trials"] = rows.size() - int(batch.eligible_trials)
	var file := FileAccess.open(directory.path_join("batch.json"), FileAccess.WRITE)
	if file == null:
		push_error("陪练批次无法输出")
		return
	file.store_string(JSON.stringify(batch, "  ") + "\n")
	file.close()
	var baseline: Array = []
	var paired_count := 0
	var used_prior := {}
	var exclusions: Array[String] = []
	if not comparison.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(comparison))
		if parsed is Dictionary and parsed.get("trials") is Array:
			baseline = parsed.trials
		else:
			push_error("对照文件无效，必须为此前的 batch.json")
	file = FileAccess.open(directory.path_join("批次报告.md"), FileAccess.WRITE)
	if file == null:
		push_error("陪练批次报告无法输出")
		return
	file.store_string("# 实战陪练 · 编组测试\n\n正式地图与真实玩家，配装按每局快照。结果来自有限脚本策略，不代表全体玩家。时长只作过程坐标，预算截断不计死亡或通关；不生成好玩分。\n")
	file.store_string("\n## 编组重复测试\n\n| 场景／编组 | 有效／全部 | 玩家死亡 | 击败敌人 | 截断未定 | 一秒峰值血盾损失 | 覆盖策略／种子 | 判断边界 |\n|---|---:|---:|---:|---:|---:|---|---|\n")
	for group: Dictionary in batch.groups:
		file.store_string("| %s / %s / %s | %d / %d | %d | %d | %d | %.1f | %d / %d | %s |\n" % [group.scenario_id, group.group_id, group.actor_origin, group.valid, group.total, group.deaths, group.wins, group.censored, group.peak_one_second_loss, group.profiles.size(), group.seeds.size(), group.interpretation])
	file.store_string("\n样本审计：可作正常交战对照 %d 局，待复核／重放等 %d 局。进程执行成功不等于样本有效；CI 可传 --require-valid。\n\n" % [batch.eligible_trials, batch.review_trials])
	file.store_string("| 场景／编组 | 策略／实例试验 | 种子 | 原始结果 | 样本有效性 | 观察秒 | 敌方剩余总生命 | 实际受击 | 寻敌占比 | 记录 |\n|---|---|---|---|---|---:|---:|---:|---:|---|\n")
	for row: Dictionary in rows:
		if row.is_empty():
			continue
		file.store_string("| %s | %s | %s | %s | %s | %.2f | %.0f | %d | %.1f%% | [详情](<%s>) |\n" % [String(row.conditions.get("scenario_id", "legacy")) + "/" + (String(row.conditions.get("group_id", "")) if row.conditions.get("scenario", {}).get("kind", "") != "boss_direct" else "Boss直战·" + phase_caption(row.conditions.scenario)), String(row.conditions.profile.title) + "/" + String(row.conditions.profile.get("boss_experiment", {}).get("pressure_trial", "formal")), row.conditions.seed, row.outcome, row.get("analysis", {}).get("sample_validity", "旧报告未核对"), row.observation_seconds, row.final_boss.get("hp", 0), row.unblocked_hits, float(row.get("engagement", {}).get("search_fraction", 0.0)) * 100.0, String(row.directory).path_join("结果.md")])
	if not baseline.is_empty():
		file.store_string("\n## 同条件配对差异\n\n只配对审计未发现异常、且策略参数、种子、配装、初始位置、预算、模式、运行环境与陪练指纹相同的样本；玩法指纹允许不同且明确列出。排除原因单列，截断样本无法推出完整胜率。\n\n| 策略/种子 | 基线 → 当前 | 受击变化 | 敌方剩余总生命变化 | 玩法文件变化 | 陪练指纹 |\n|---|---|---:|---:|---|---|\n")
		for row: Dictionary in rows:
			for prior: Dictionary in baseline:
				if row.conditions.profile_id != prior.get("conditions", {}).get("profile_id") or int(row.conditions.seed) != int(prior.get("conditions", {}).get("seed", 0)):
					continue
				var rejection := comparison_rejection(row, prior)
				if not rejection.is_empty():
					exclusions.append("%s/%s：%s" % [row.conditions.profile_id, row.conditions.seed, rejection])
					continue
				if not used_prior.has(String(prior.directory)):
					used_prior[String(prior.directory)] = true
					paired_count += 1
					var changed: Array[String] = []
					for path: String in row.gameplay_sha256:
						if row.gameplay_sha256[path] != prior.get("gameplay_sha256", {}).get(path):
							changed.append(path.get_file())
					var harness_matches: bool = row.get("harness_sha256", {}) == prior.get("harness_sha256", {}) and row.has("harness_sha256")
					file.store_string("| %s/%s | %s → %s | %+d | %+.0f | %s | %s |\n" % [row.conditions.profile_id, row.conditions.seed, prior.outcome, row.outcome, row.unblocked_hits - prior.unblocked_hits, float(row.final_boss.hp) - float(prior.final_boss.hp), ", ".join(changed) if not changed.is_empty() else "无", "一致" if harness_matches else "不同或旧报告未记录，需复核"])
					break
	file.store_string("\n## 新循环与明确试验轴\n\n| 策略／种子 | 狙击／有效破击／保护拦截 | 有效触盾 | 奖励窗口数（含截断） | 窗口实际伤害／总伤害占比 |\n|---|---|---:|---:|---|\n")
	for row: Dictionary in rows:
		var cycles: Dictionary = row.get("cycles", {})
		file.store_string("| %s／%s | %d／%d／%d | %d | %d | %.0f／%s |\n" % [row.conditions.profile_id, row.conditions.seed, cycles.get("sniper_shots", 0), cycles.get("crystal_break_hits", 0), cycles.get("protected_shots", 0), cycles.get("shield_contacts", 0), cycles.get("windows", []).size(), cycles.get("damage_in_reward", 0.0), str(cycles.get("reward_share", null))])
	file.store_string("\n同种子、初始条件、环境与指纹审计后的策略／倒地时长／命名压力候选配对 %d；排除 %d，逐对原因见 batch.json 的 cycle_contrasts。仅声明的策略开关、倒地时长或压力候选可以不同，反应／误差不同不会伪装成同条件配对。\n" % [batch.cycle_contrasts.pairs.size(), batch.cycle_contrasts.exclusions.size()])
	if not comparison.is_empty():
		file.store_string("\n满足条件的配对：%d。\n" % paired_count)
		for reason: String in exclusions:
			file.store_string("\n- 排除：" + reason + "\n")
		if paired_count == 0:
			push_error("没有满足相同条件与初始配装的陪练样本，未生成比较结论")
	file.close()


static func comparison_rejection(current: Dictionary, prior: Dictionary) -> String:
	if not bool(current.get("analysis", {}).get("eligible_for_balance", false)) or not bool(prior.get("analysis", {}).get("eligible_for_balance", false)):
		return "样本异常、重放或旧报告尚未完成有效性审计"
	for row: Dictionary in [current, prior]:
		for field: String in ["conditions", "initial_player", "initial_world", "harness_sha256", "gameplay_sha256", "execution_environment"]:
			if not row.get(field) is Dictionary or row[field].is_empty():
				return "缺少实际配对证据：" + field
	if not same_value(current.get("conditions", {}), prior.get("conditions", {})):
		return "运行条件不同"
	if not same_value(current.get("initial_player", {}), prior.get("initial_player", {})):
		return "实际初始配装不同"
	if not same_value(current.get("harness_sha256", {}), prior.get("harness_sha256", {})):
		return "陪练、观测代码或配置指纹不同"
	if not same_value(current.get("initial_world", {}), prior.get("initial_world", {})):
		return "初始位置或个体参数不同"
	if not current.has("execution_environment") or not prior.has("execution_environment") or not same_value(current.execution_environment, prior.execution_environment):
		return "无头／图形、引擎或帧推进环境不同，或旧报告缺少环境记录"
	return ""

static func same_value(left: Variant, right: Variant) -> bool:
	return Settings.same_values(left, right)
