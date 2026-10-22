"""Summarize a real-play --perf-detail capture, including physics catch-up.

This deliberately does not sum inclusive CPU scopes from nested calls.
Use raw uninstrumented frame capture for FPS; CPU scope capture for attribution.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from collections import defaultdict
from pathlib import Path


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def frame_summary(rows: list[dict], physics_tps: int) -> dict:
    if not rows:
        return {"frames": 0}
    elapsed = sum(row["wall_frame_ms"] for row in rows) / 1000
    steps = sum(row["physics_steps"] for row in rows)
    frame_ms = [row["wall_frame_ms"] for row in rows]
    return {
        "frames": len(rows),
        "wall_seconds": round(elapsed, 3),
        "fps": round(len(rows) / elapsed, 2) if elapsed > 0 else 0,
        "p50_ms": round(percentile(frame_ms, .50), 3),
        "p95_ms": round(percentile(frame_ms, .95), 3),
        "p99_ms": round(percentile(frame_ms, .99), 3),
        "max_ms": round(max(frame_ms), 3),
        "over_16_67": sum(v > 16.67 for v in frame_ms),
        "over_33_33": sum(v > 33.33 for v in frame_ms),
        "physics_steps": steps,
        "catchup_frames": sum(r["physics_steps"] > 1 for r in rows),
        "simulation_seconds_per_wall_second": round(steps / (elapsed * physics_tps), 3) if elapsed > 0 else 0,
    }


def read_frames(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as file:
        rows = []
        for original in csv.DictReader(line for line in file if not line.startswith("#")):
            if not original:
                continue
            rows.append({
                "elapsed_s": float(original["elapsed_s"]),
                "wall_frame_ms": float(original["wall_frame_ms"]),
                "engine_delta_ms": float(original["engine_delta_ms"]),
                "physics_steps": int(original["physics_steps"]),
                "enemies": int(original["enemies"]),
                "physics_monitor_ms": float(original["physics_monitor_ms"]),
                "process_monitor_ms": float(original["process_monitor_ms"]),
                "draw_calls": int(original["draw_calls"]),
                "primitives": int(original["primitives"]),
            })
    return rows


def bucket_enemy(n: int) -> str:
    if n == 0:
        return "00"
    if n <= 9:
        return "01-09"
    if n <= 19:
        return "10-19"
    if n <= 29:
        return "20-29"
    return "30+"


def read_cpu(path: Path) -> dict:
    grouped: dict[str, dict] = defaultdict(lambda: {"calls": 0, "total_ms": 0.0, "max_ms": 0.0})
    with path.open(encoding="utf-8-sig", newline="") as file:
        for original in csv.DictReader(line for line in file if not line.startswith("#")):
            if not original:
                continue
            label = original["scope"]
            group = grouped[label]
            group["calls"] += int(original["sampled_calls"])
            group["total_ms"] += float(original["inclusive_total_ms"])
            group["max_ms"] = max(group["max_ms"], float(original["max_call_ms"]))
    return {
        label: {
            "calls": row["calls"],
            "inclusive_avg_ms": round(row["total_ms"] / row["calls"], 4) if row["calls"] else 0,
            "inclusive_total_sampled_ms": round(row["total_ms"], 3),
            "max_call_ms": round(row["max_ms"], 3),
            "sampled": not label.startswith("attack_starts."),
        }
        for label, row in sorted(grouped.items())
    }


def analyze(path: Path, tps: int) -> dict:
    frames = read_frames(path)
    groups = defaultdict(list)
    steps = defaultdict(list)
    for frame in frames:
        groups[bucket_enemy(frame["enemies"])].append(frame)
        steps["0" if frame["physics_steps"] == 0 else "1" if frame["physics_steps"] == 1
              else "2" if frame["physics_steps"] == 2 else "3+"].append(frame)
    cpu_path = Path(str(path).replace("_frames.csv", "_enemy_cpu.csv"))
    return {
        "input": str(path),
        "physics_tps_assumption": tps,
        "overall": frame_summary(frames, tps),
        "enemy_population": {k: frame_summary(v, tps) for k, v in sorted(groups.items())},
        "physics_steps_per_render_frame": {k: frame_summary(v, tps) for k, v in sorted(steps.items())},
        "slowest_frames": sorted(frames, key=lambda r: r["wall_frame_ms"], reverse=True)[:12],
        "sampled_cpu": read_cpu(cpu_path) if cpu_path.exists() else {},
        "interpretation": [
            "The raw wall_frame_ms is render frame pacing; engine_delta_ms is not reliable wall time.",
            "physics_steps > 1 marks catch-up, but not necessarily its cause.",
            "TIME_PHYSICS_PROCESS and TIME_PROCESS are engine monitors, NOT disjoint script/physics buckets.",
            "CPU sample scopes are inclusive, sparse (1 in 8 physics steps), and must not be added across nested methods.",
            "attack_starts.* are complete unsampled counts during instrumented play, not hit confirmations.",
            "Judge FPS using a capture WITHOUT --perf-enemy-cpu; use CPU capture only to rank hotspots.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frames_csv", type=Path, nargs="+")
    parser.add_argument("--physics-tps", type=int, default=60)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.physics_tps <= 0:
        parser.error("--physics-tps must be positive")
    results = [analyze(path, args.physics_tps) for path in args.frames_csv]
    rendered = json.dumps(results[0] if len(results) == 1 else results, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
