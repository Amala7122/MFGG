"""Compare attack admission policies in the actual mixed-wave scene, in real time."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from artifact_paths import create_run
from run_acceptance import find_godot, isolate_project, run_check, write_report
from project_hygiene import check


def percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * p) - 1)] if ordered else 0.0


def summarize(document: dict, variant: str, path: Path) -> dict:
    samples = [row for row in document["samples"] if row["seconds"] >= 10]
    times = [row["ms"] for row in samples]
    queue = document.get("attack_queue", {})
    config = document["queue_config"]
    history = queue.get("history", [])
    violations = []
    if document.get("max_untracked_ground", 0):
        violations.append("untracked_ground_effect")
    if config["enabled"] and document.get("peak_actual_ground_groups", 0) > config["global"]["max_ground"]:
        violations.append("actual_ground_limit")
    per_frame: dict[int, int] = {}
    target_time: dict[int, float] = {}
    for row in history:
        frame = row["frame"]
        per_frame[frame] = per_frame.get(frame, 0) + 1
        if config["enabled"]:
            if row["active"] > config["global"]["max_active"]:
                violations.append("active_limit")
            if row["ground"] > config["global"]["max_ground"]:
                violations.append("ground_limit")
            if per_frame[frame] > config["global"]["starts_per_frame"]:
                violations.append("frame_limit")
            previous = target_time.get(row["target"], -1000)
            if row["time"] - previous + 1e-6 < config["global"]["start_gap"]:
                violations.append("start_gap")
        target_time[row["target"]] = row["time"]
    starts = queue.get("starts", {})
    profiles = sorted({key.split("/")[0] for key in starts})
    return {
        "variant": variant, "source": str(path), "config": config,
        "fps_after_10s": len(times) * 1000 / sum(times) if times else 0,
        "p95_ms_after_10s": percentile(times, .95),
        "max_ms_after_10s": max(times) if times else 0,
        "max_ms_including_cold_spawn": document["max_ms"],
        "peak_ground_visible": max((row.get("visible_ground", 0) for row in samples), default=0),
        "p95_ground_visible": percentile([row.get("visible_ground", 0) for row in samples], .95),
        "untracked_ground": document.get("max_untracked_ground", 0),
        "peak_actual_ground_groups": document.get("peak_actual_ground_groups", 0),
        "spawned": document["spawned"], "queue": queue,
        "served_profiles": profiles, "violations": sorted(set(violations)),
        "admissions_per_second": len(history) / max(document["samples"][-1]["seconds"] - 4, 1),
    }


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=40)
    parser.add_argument("--variants", default="off,conservative,open,default,default,off")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    problems = check(project, project.parent)
    if problems:
        raise ValueError("\n".join(problems))
    variants = args.variants.split(",")
    if any(item not in {"off", "conservative", "open", "default"} for item in variants):
        parser.error("未知候选")
    run = create_run(project, "attack_queue_calibration", args.output)
    isolated = run / "tmp/project"
    isolate_project(project, isolated, run.name)
    godot = find_godot(project)
    print("CALIBRATION " + str(run), flush=True)
    imported = run_check(godot, isolated, run / "logs", "import", ["--editor", "--import"], 240, False)
    write_report(run / "reports", [imported], [], project)
    if not imported["passed"]:
        return 1
    summaries = []
    for index, variant in enumerate(variants):
        case = create_run(project, "attack_queue_" + variant, args.output)
        result = run_check(godot, isolated, case / "logs", "formal_spawn_perf", [
            "--max-fps", "0", "--script", "res://tools/probes/formal_spawn_perf.gd", "--",
            "--artifact-dir=" + str(case), "--seconds=" + str(args.seconds),
            "--queue-variant=" + variant, *( ["--capture"] if variant == "default" else []),
        ], args.seconds + 90, True)
        write_report(case / "reports", [result], [], project)
        path = case / "reports/formal_spawn_perf.json"
        if not result["passed"] or not path.exists():
            summaries.append({"variant": variant, "passed": False, "source": str(path)})
            print(f"FAIL {index + 1}/{len(variants)} {variant}: {case}", flush=True)
            break
        row = summarize(json.loads(path.read_text(encoding="utf-8")), variant, path)
        row["passed"] = not row["violations"] and row["spawned"] >= 24
        summaries.append(row)
        print(f"{index + 1}/{len(variants)} {variant}: fps={row['fps_after_10s']:.1f} "
              f"p95={row['p95_ms_after_10s']:.1f}ms starts={row['queue'].get('grants')} "
              f"wait95={row['queue'].get('wait_p95', 0):.2f}s "
              f"ground={row['queue'].get('peak_ground')} visible={row['peak_ground_visible']} "
              f"violations={row['violations']} -> {case}", flush=True)
        (run / "reports/calibration.json").write_text(
            json.dumps({"runs": summaries}, ensure_ascii=False, indent=2), encoding="utf-8")
        if not row["passed"]:
            break
    passed = len(summaries) == len(variants) and all(row.get("passed") for row in summaries)
    # 先看合同，再看吞吐／等待／真实警示数量；数值推荐由报告审阅，不伪装成玩家手感验收。
    report = {"passed": passed, "runs": summaries,
              "scope": "固定种子正式30怪原地转头压力；不代替玩家躲避或三波通关。off关闭正式编排限制，仅作无约束对照。"}
    (run / "reports/calibration.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(("PASS " if passed else "FAIL ") + str(run / "reports/calibration.json"), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
