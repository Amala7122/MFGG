"""Instrument selected CPU paths in an isolated project, never in live game code."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from artifact_paths import create_run
from run_acceptance import find_godot, isolate_project, run_check, write_report
from project_hygiene import check

SCRIPTS = (
    "spatial_query", "spatial_route_planner", "combat_spatial_controller", "nav_steering",
    "ground_movement", "navigation_path", "enemy_attack_area", "attack_surface_mesh",
    "jump_melee", "jump_landing", "ground_dust", "performance_recorder",
    "enemy_attack_queue", "enemy_attack_queue_policy",
    "enemies/crystal_creature_actor", "enemies/burst_crawler", "enemies/crystal_projectile",
    "prototypes/enemy_crowd", "prototypes/procedural_mud_golem", "prototypes/procedural_fast_beast",
)

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--graphics", action="store_true")
    parser.add_argument("--frames", default=180, type=int)
    parser.add_argument("--spawn", action="store_true", help="诊断正式波次实时刷怪，额外插桩投放与构造")
    parser.add_argument("--seconds", default=20, type=float)
    parser.add_argument("--coarse", action="store_true", help="只计时全部脚本的主更新入口及共享队列，降低插桩对主场景的扰动")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    problems = check(project, project.parent)
    if problems:
        raise ValueError("\n".join(problems))
    run = create_run(project, "main_scene_cpu", args.output)
    isolated = run / "tmp" / "project"
    isolate_project(project, isolated, run.name)
    hashes = {}
    scripts = SCRIPTS + (("wave_director", "enemy_spawner", "enemy_deployment",
                          "prototypes/enemy_tuning", "prototypes/crystal_creature_visual",
                          "enemies/creature_catalog") if args.spawn else ())
    if args.coarse:
        scripts = tuple(p.relative_to(project / "scripts").with_suffix("").as_posix()
                        for p in (project / "scripts").rglob("*.gd"))
    for script in scripts:
        relative = "scripts/" + script + ".gd"
        path = isolated / relative
        source = path.read_text(encoding="utf-8-sig")
        # Multiline signatures end at the line whose first indented body follows.
        lines = source.splitlines(keepends=True)
        result = []
        pending = None
        signature_complete = False
        for line in lines:
            match = re.match(r"(?:static )?func (\w+)\(", line)
            if match:
                label_name = script + "." + match[1]
                allowed = not args.coarse or match[1] in {"_process", "_physics_process"} or label_name in {
                    "combat_spatial_controller.process_jobs", "spatial_route_planner.advance",
                    "enemy_attack_queue.request", "enemy_attack_queue._prune",
                    "attack_surface_mesh.build", "enemy_attack_area.lock",
                }
                pending = label_name if allowed else None
                signature_complete = False
            if pending and not signature_complete:
                signature_complete = line.rstrip().endswith(":")
                result.append(line)
                continue
            if pending and line.startswith("\t") and line.strip() and not line.lstrip().startswith("#"):
                label = json.dumps(pending)
                result.append(f'\tvar _cpu_scope = preload("res://tools/probes/cpu_scope.gd").new({label})\n')
                pending = None
            result.append(line)
        path.write_text("".join(result), encoding="utf-8")
        hashes[relative] = {"source_sha256": hashlib.sha256(source.encode()).hexdigest(),
                            "instrumented_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    (run / "reports" / "instrumentation.json").write_text(json.dumps(hashes, indent=2), encoding="utf-8")
    print(f"CPU probe: {run}", flush=True)
    godot = find_godot(project)
    results = [run_check(godot, isolated, run / "logs", "import", ["--editor", "--import"], 240, False)]
    if results[0]["passed"]:
        pacing = ["--max-fps", "0"] if args.spawn else ["--fixed-fps", "60"]
        probe = "formal_spawn_perf" if args.spawn else "main_scene_cpu"
        results.append(run_check(godot, isolated, run / "logs", "main_scene_cpu",
            [*pacing, "--script", "res://tools/probes/" + probe + ".gd", "--",
             "--artifact-dir=" + str(run), "--frames=" + str(args.frames), "--warmup=60",
             "--seconds=" + str(args.seconds)], 240, args.graphics))
    passed = write_report(run / "reports", results, [], project)
    print(f"{'PASS' if passed else 'FAIL'}: {run / 'reports' / 'summary.md'}")
    return 0 if passed else 1

if __name__ == "__main__":
    raise SystemExit(main())
