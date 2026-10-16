"""敌人寻路成本拆分计量台（只读诊断，不改动正式运行代码）。

把一次性的注入式计时固化成可复用入口：

1. 在本次运行目录 `tmp/instrumented/` 生成注入副本：计时模块 + 目标函数包装 +
   原生导航调用改名。**项目内的 scripts/ 一个字节都不改**，只在项目外的隔离副本里生效。
2. 用 `run_acceptance` 的隔离与运行管线在副本上跑探针（`--scene=formal` 跑
   `tools/probes/navigation_cost_audit.gd`，`--scene=precise` 跑 `tools/probes/ring_chase_lab.gd`）。
3. 把探针指标按用途分桶，写 `reports/nav_cost_buckets.{json,md}`。

分桶是为了回答一个具体问题：降低寻路开销应该先动哪一层。
`search` 是网格搜索（地图相关，可预处理/共享），`validation` 是身体通行与支撑
（身体相关，与地图无关，只能靠惰性验证与同体型共享）。

用法：
    python -B tools/nav_cost_profile.py --ui=0 --ring=0
    python -B tools/nav_cost_profile.py --scene=precise --frames=900
    python -B tools/nav_cost_profile.py --count=128 --frames=600 --ring=1

注意：enter/leave 计时本身的开销与调用次数成正比，绝对耗时被抬高；
分桶用于比较量级与占比，不用于宣称帧率。正式口径以 `tools/run_probe.py` 的无注入运行为准。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from artifact_paths import create_run
from project_hygiene import check as hygiene_check
from run_acceptance import find_godot, isolate_project, run_check, write_report

PROBE = "tools/probes/navigation_cost_audit.gd"
## 场景：formal = 正式导航配置（空间规划器参与），precise = 精确追击压力台。
SCENES = {
    "formal": "tools/probes/navigation_cost_audit.gd",
    "precise": "tools/probes/ring_chase_lab.gd",
    # 保留旧命令别名，单环目标模型已经退役。
    "ring": "tools/probes/ring_chase_lab.gd",
}

# 计时模块。只在隔离副本里生成，正式运行代码不加载它。
METRICS_MODULE = '''extends RefCounted
static var enabled := false
static var stack: Array = []
static var frame: Dictionary = {}
static func enter(key: String) -> void:
\tif not enabled: return
\tstack.append([key, Time.get_ticks_usec(), 0])
static func leave() -> void:
\tif not enabled: return
\tvar now := Time.get_ticks_usec()
\tvar item: Array = stack.pop_back()
\tvar elapsed := now - int(item[1])
\tvar own := elapsed - int(item[2])
\tvar key: String = item[0]
\tif not frame.has(key): frame[key] = [0, 0, 0, 0]
\tframe[key][0] += 1
\tframe[key][1] += elapsed
\tframe[key][2] += own
\tframe[key][3] = maxi(frame[key][3], elapsed)
\tif not stack.is_empty(): stack.back()[2] += Time.get_ticks_usec() - int(item[1])
static func take_frame() -> Dictionary:
\tvar result := frame
\tframe = {}
\treturn result
static func count(key: String) -> void:
\tif not enabled: return
\tif not frame.has(key): frame[key] = [0, 0, 0, 0]
\tframe[key][0] += 1
static func closest(map: RID, point: Vector3) -> Vector3:
\tenter("native.closest_point")
\tvar result := NavigationServer3D.map_get_closest_point(map, point)
\tleave()
\treturn result
static func owner(map: RID, point: Vector3) -> RID:
\tenter("native.closest_owner")
\tvar result := NavigationServer3D.map_get_closest_point_owner(map, point)
\tleave()
\treturn result
static func path(params: NavigationPathQueryParameters3D, result: NavigationPathQueryResult3D) -> void:
\tenter("native.query_path")
\tNavigationServer3D.query_path(params, result)
\tleave()
'''

# 需要计时的函数。键是相对项目根的路径，值是函数名。
TARGETS: dict[str, list[str]] = {
    "scripts/combat_spatial_controller.gd": [
        "tick", "_cheap_tick", "process_jobs", "_request_route", "_publish_route",
        "_choose_band_goal", "_move_override", "_recover_walk", "gate_motion",
        "escape_plan", "_relocate", "_walking", "_ring_goal", "_ring_jumped",
    ],
    "scripts/spatial_query.gd": [
        "support", "floor_at", "_floor_ray", "dimensions", "parts",
        "ground_segment", "ground_pose", "motion_clear", "full_support",
    ],
    "scripts/spatial_route_planner.gd": ["begin", "advance", "walk_route", "_physical_walk_points"],
    "scripts/nav_steering.gd": ["direction_to", "raw_ground_velocity", "needs_route", "live_direct_ok"],
    "scripts/ground_movement.gd": ["move", "step_landing"],
    "scripts/nav_arc_shape.gd": ["shape", "fillet_stage", "resample_stage", "warp_stage", "final_gate"],
    "scripts/nav_ring_anchors.gd": ["sync", "region_candidates", "region_goal"],
    "scripts/prototypes/navigation_lab.gd": ["_process", "redraw_paths"],
    "scripts/prototypes/navigation_test_actor.gd": ["_physics_process", "snapshot"],
    # 精确追击压力台（--scene=precise；ring 为旧命令别名）
    "scripts/prototypes/ring_chase_lab.gd": ["_physics_process", "_refresh_goal", "_spawn_one"],
    "scripts/prototypes/ring_chase_actor.gd": ["_physics_process", "set_goal"],
}

# 计数口径：高频纯叶子函数只记次数，不记 enter/leave。
# 理由：enter/leave 开销与调用次数成正比，这几个每帧被调几十万到上百万次，
# 计时会让 validation 桶虚高；它们的真实耗时由调用它们的已计时父函数独占吸收。
COUNT_ONLY = {
    "spatial_query._floor_ray",
    "spatial_query.parts",
    "spatial_query.dimensions",
    # 投影缓存本身多数是字典命中（很便宜），计时会把它的 enter/leave 开销算得比真实还大。
    "nav_projection_cache.closest",
    "nav_projection_cache.owner_valid",
}

# 分桶：前缀匹配，先命中先算。顺序即优先级。
BUCKETS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("search", ("native.query_path", "native.closest_point", "native.closest_owner")),
    ("projection_cache", ("nav_projection_cache.",)),
    ("bench_ring", ("ring_chase_lab.", "ring_chase_actor.")),
    ("validation", ("spatial_query.",)),
    ("shaping", ("nav_arc_shape.", "navigation_path.")),
    ("planning", ("combat_spatial_controller.", "spatial_route_planner.", "spatial_retreat_planner.")),
    ("steering", ("nav_steering.",)),
    ("ring_goal", ("nav_ring_anchors.",)),
    ("physics_move", ("ground_movement.",)),
    ("bench_ui", ("navigation_lab.", "navigation_test_actor.")),
)

BUCKET_NOTE = {
    "search": "网格搜索与原生投影：地图相关，预处理或共享能省",
    "projection_cache": "投影共享缓存本身（多数是字典命中）",
    "bench_ring": "单环观察台自身：追击者驱动、选点、重生",
    "validation": "身体通行 / 支撑 / 净空查询：身体相关，预处理省不掉",
    "shaping": "APS 形状流水线（圆角 / 重采样 / 形变 / 终检）",
    "planning": "规划框架与任务调度（控制器 tick、规划器推进、状态机）",
    "steering": "NavSteering 与 NavigationAgent 跟随",
    "ring_goal": "同心环目标状态",
    "physics_move": "角色实际移动（move_and_slide / 跨坎）",
    "bench_ui": "观察台面板与测量体自身记账（诊断开销）",
    "other": "未归类",
}

FUNC_RE = r"^(static )?func {name}\((.*?)\) -> ([\w\[\]]+):"


def split_parameters(argument_text: str) -> list[str]:
    """把形参表拆成实参名。目标函数没有含逗号的默认值。"""
    return [x.strip().split(":")[0].split("=")[0].strip()
            for x in argument_text.split(",") if x.strip()]


def instrument_script(relative: str, functions: list[str], text: str) -> str:
    """把目标函数改名并追加同名包装；原生导航调用改走计时入口。"""
    text = text.replace("NavigationServer3D.map_get_closest_point(", "AuditMetrics.closest(")
    text = text.replace("NavigationServer3D.map_get_closest_point_owner(", "AuditMetrics.owner(")
    text = text.replace("NavigationServer3D.query_path(", "AuditMetrics.path(")
    text = re.sub(r"^(extends [^\n]+)$",
                  r'\1\nconst AuditMetrics := preload("res://scripts/nav_audit_metrics.gd")',
                  text, count=1, flags=re.M)
    stem = Path(relative).stem
    for name in functions:
        pattern = re.compile(FUNC_RE.format(name=re.escape(name)), re.M | re.S)
        match = pattern.search(text)
        if not match:
            raise RuntimeError(f"找不到要计时的函数：{relative}::{name}")
        signature = match.group(0)
        return_type = match.group(3)
        implementation = "__audit_impl_" + name
        text = (text[:match.start()]
                + signature.replace(f"func {name}(", f"func {implementation}(")
                + text[match.end():])
        key = f"{stem}.{name}"
        if key in COUNT_ONLY:
            body = [signature, f'\tAuditMetrics.count("{key}")']
        else:
            body = [signature, f'\tAuditMetrics.enter("{key}")']
        invocation = implementation + "(" + ", ".join(split_parameters(match.group(2))) + ")"
        if return_type == "void":
            body += ["\t" + invocation]
        else:
            body += [f"\tvar result: {return_type} = {invocation}"]
        if key not in COUNT_ONLY:
            body.append("\tAuditMetrics.leave()")
        if return_type != "void":
            body.append("\treturn result")
        text += "\n" + "\n".join(body) + "\n"
    return text


def build_overlay(project: Path, overlay: Path) -> dict[str, str]:
    """在项目外生成注入副本，返回原文件哈希用于核对正式代码未被改动。"""
    hashes: dict[str, str] = {}
    metrics_path = overlay / "scripts" / "nav_audit_metrics.gd"
    metrics_path.parent.mkdir(parents=True, exist_ok=True)
    metrics_path.write_text(METRICS_MODULE, encoding="utf-8")
    for relative, functions in TARGETS.items():
        source = project / relative
        hashes[relative] = hashlib.sha256(source.read_bytes()).hexdigest()
        text = source.read_text(encoding="utf-8-sig")
        target = overlay / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(instrument_script(relative, functions, text), encoding="utf-8")
    return hashes


def apply_overlay(overlay: Path, destination: Path) -> int:
    count = 0
    for path in overlay.rglob("*.gd"):
        target = destination / path.relative_to(overlay)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        count += 1
    return count


def bucket_of(key: str) -> str:
    for name, prefixes in BUCKETS:
        if any(key.startswith(prefix) for prefix in prefixes):
            return name
    return "other"


def build_buckets(report: dict) -> dict:
    metrics: dict = report.get("metrics", {})
    buckets: dict[str, dict] = {}
    for key, value in metrics.items():
        calls, inclusive, exclusive, worst = (int(value[0]), int(value[1]),
                                              int(value[2]), int(value[3]))
        item = buckets.setdefault(bucket_of(key), {"calls": 0, "inclusive_us": 0,
                                                   "exclusive_us": 0, "max_us": 0,
                                                   "keys": []})
        item["calls"] += calls
        item["inclusive_us"] += inclusive
        item["exclusive_us"] += exclusive
        item["max_us"] = max(item["max_us"], worst)
        item["keys"].append(key)
    total = sum(item["exclusive_us"] for item in buckets.values())
    for item in buckets.values():
        item["share"] = (item["exclusive_us"] / total) if total else 0.0
        item["keys"].sort()
    return {"total_exclusive_us": total, "buckets": buckets,
            "count_only_keys": sorted(COUNT_ONLY),
            "note": "独占耗时相加；enter/leave 开销与调用次数成正比，"
                    "已把最高频的纯叶子函数改为只计次（见 count_only_keys），"}


def _num(value: object, fallback: float = 0.0) -> float:
    """报告字段缺省或为 None 时按 fallback 处理：两个探针的字段并不完全相同。"""
    return fallback if value is None else float(value)


def write_bucket_report(reports: Path, report: dict) -> dict:
    summary = build_buckets(report)
    buckets = summary["buckets"]
    ordered = sorted(buckets.items(), key=lambda kv: kv[1]["exclusive_us"], reverse=True)
    lines = [
        "# 敌人寻路成本拆分",
        "",
        f"场景：{report.get('count')} 个体 / {report.get('frames')} 帧 / warmup {report.get('warmup')}"
        f" / 观察台 UI {report.get('ui')} / 同心环 {report.get('ring')} / 种子 {report.get('seed')}",
        "",
        f"帧耗时 p50 {_num(report.get('ms_p50')):.2f} ms / p95 {_num(report.get('ms_p95')):.2f} ms"
        f" / p99 {_num(report.get('ms_p99')):.2f} ms"
        f"；在追/活跃 {report.get('cohort', report.get('active_over_20m'))}"
        f"；零速比例 {_num(report.get('zero_ratio_window', report.get('all_actor_zero_ratio'))):.4f}",
        "",
        "## 分桶（按独占耗时）",
        "",
        "| 桶 | 说明 | 调用次数 | 独占耗时 ms | 占比 |",
        "|---|---|---:|---:|---:|",
    ]
    for name, item in ordered:
        lines.append(f"| {name} | {BUCKET_NOTE.get(name, name)} | {item['calls']} | "
                     f"{item['exclusive_us'] / 1000.0:.1f} | {item['share'] * 100:.1f}% |")
    lines += [
        "",
        f"已计时总量（独占相加）：{summary['total_exclusive_us'] / 1e6:.2f} s",
        "",
        "> enter/leave 计时开销与调用次数成正比，绝对耗时被抬高；本表用于判断先动哪一层，",
        "> 不能当作帧率结论。正式帧率口径见 `tools/run_probe.py` 的无注入运行。",
        "",
        "只计次不计时的叶子函数（其真实耗时被已计时的父函数吸收）："
        + "、".join(f"`{k}`" for k in sorted(COUNT_ONLY)),
        "",
        "## 明细（独占耗时前 20）",
        "",
        "| 函数 | 调用次数 | 独占 us | 包含 us | 单次最大 us |",
        "|---|---:|---:|---:|---:|",
    ]
    detail = sorted(report.get("metrics", {}).items(),
                    key=lambda kv: int(kv[1][2]), reverse=True)
    for key, value in detail[:20]:
        lines.append(f"| {key} | {int(value[0])} | {int(value[2])} | {int(value[1])} | {int(value[3])} |")
    lines.append("")
    (reports / "nav_cost_buckets.md").write_text("\n".join(lines), encoding="utf-8")
    (reports / "nav_cost_buckets.json").write_text(
        json.dumps({"config": {k: report.get(k) for k in
                               ("count", "frames", "warmup", "ui", "ring", "seed")},
                    "frame": {k: report.get(k) for k in
                              ("ms_p50", "ms_p95", "ms_p99", "ms_mean", "job_us_p95",
                               "jobs", "full_ticks", "cheap_ticks", "active_over_20m",
                               "all_actor_zero_ratio")},
                    **summary}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--count", type=int, default=256, help="正式链路数量 1..256；精确追击固定 256")
    parser.add_argument("--frames", type=int, default=900, help="计时帧数")
    parser.add_argument("--warmup", type=int, default=120, help="不计时的预热帧数")
    parser.add_argument("--seed", type=int, default=64768)
    parser.add_argument("--ui", type=int, default=0, choices=(0, 1), help="观察台面板是否每帧刷新")
    parser.add_argument("--ring", type=int, default=0, choices=(0, 1), help="同心环目标开关")
    parser.add_argument("--task", default="nav_cost_profile")
    parser.add_argument("--scene", default="formal", choices=sorted(SCENES),
                        help="formal = 正式导航配置；precise = 精确追击压力台；ring 为旧别名")
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--graphics", action="store_true", help="带渲染运行（默认 headless）")
    arguments = parser.parse_args()

    project = arguments.project.resolve()
    if not 1 <= arguments.count <= 256:
        parser.error("--count 必须在 1..256。")
    if arguments.warmup < 0 or arguments.frames <= 0:
        parser.error("--warmup 不能为负，--frames 必须为正。")
    problems = hygiene_check(project, project.parent)
    if problems:
        parser.error("目录检查失败：\n" + "\n".join(problems))

    run = create_run(project, arguments.task)
    overlay = run / "tmp" / "instrumented"
    hashes = build_overlay(project, overlay)
    (run / "reports" / "source_hashes.json").write_text(
        json.dumps(hashes, indent=2) + "\n", encoding="utf-8")

    isolated = run / "tmp" / "project"
    isolate_project(project, isolated, run.name)
    copied = apply_overlay(overlay, isolated)
    print(f"注入副本：{copied} 个脚本 -> {isolated}", flush=True)
    print(f"计量产物：{run}", flush=True)

    godot = arguments.godot.resolve() if arguments.godot else find_godot(project)
    results = [run_check(godot, isolated, run / "logs", "import",
                         ["--editor", "--import"], max(arguments.timeout, 240), False)]
    if results[0]["passed"]:
        probe_args = [f"--count={arguments.count}", f"--frames={arguments.frames}",
                      f"--warmup={arguments.warmup}", f"--seed={arguments.seed}",
                      f"--ui={arguments.ui}", f"--ring={arguments.ring}"]
        command = ["--fixed-fps", "60", "--script", "res://" + SCENES[arguments.scene],
                   "--", "--artifact-dir=" + str(run), *probe_args]
        results.append(run_check(godot, isolated, run / "logs",
                                 Path(SCENES[arguments.scene]).stem,
                                 command, arguments.timeout, arguments.graphics))
    passed = write_report(run / "reports", results, [], project)

    probe_report = run / "reports" / (Path(SCENES[arguments.scene]).stem + ".json")
    if passed and probe_report.is_file():
        summary = write_bucket_report(run / "reports",
                                      json.loads(probe_report.read_text(encoding="utf-8")))
        print("[成本拆分] 独占总量 %.2f s" % (summary["total_exclusive_us"] / 1e6))
        for name, item in sorted(summary["buckets"].items(),
                                 key=lambda kv: kv[1]["exclusive_us"], reverse=True):
            print("  %-14s %8.1f ms  %5.1f%%  calls=%d" % (
                name, item["exclusive_us"] / 1000.0, item["share"] * 100, item["calls"]))
        print(f"分桶报告：{run / 'reports' / 'nav_cost_buckets.md'}")
    elif passed:
        print("探针报告缺失：", probe_report, file=sys.stderr)
        passed = False
    print(f"{'通过' if passed else '失败'}：{run / 'reports' / 'summary.md'}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
