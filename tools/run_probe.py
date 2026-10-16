"""Run one diagnostic/capture script in an isolated project with organized output."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

from artifact_paths import create_run
from run_acceptance import find_godot, isolate_project, run_check, write_report


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("script", help="项目内 tools/probes/*.gd")
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--graphics", action="store_true")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--task", default="probe")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--args", nargs=argparse.REMAINDER, default=[])
    args = parser.parse_args()
    project = args.project.resolve()
    script = (project / args.script.removeprefix("res://")).resolve()
    if not script.is_file() or script.suffix != ".gd" or project / "tools" / "probes" not in script.parents:
        parser.error("只能运行本项目 tools/probes 中的 .gd 工具。")
    if args.timeout <= 0:
        parser.error("超时必须大于 0。")
    from project_hygiene import check
    problems = check(project, project.parent)
    if problems:
        parser.error("目录检查失败：\n" + "\n".join(problems))
    run = create_run(project, args.task, args.output)
    isolated = run / "tmp" / "project"
    godot = args.godot.resolve() if args.godot else find_godot(project)
    isolate_project(project, isolated, run.name)
    print(f"探针产物：{run}", flush=True)
    results = [run_check(godot, isolated, run / "logs", "import",
                         ["--editor", "--import"], max(args.timeout, 240), False)]
    if results[0]["passed"]:
        # 实战 NPC 有真实毫秒限流；无头不应等于加速模拟。机制快测须显式请求 fast。
        sparring = script.stem in {"combat_sparring", "titan_sparring", "sparring_human_check"}
        fast = "--pacing=fast" in args.args
        pacing = ["--max-fps", "60"] if sparring and not fast else ["--fixed-fps", "60"]
        command = [*pacing, "--script", "res://" + script.relative_to(project).as_posix(),
                   "--", "--artifact-dir=" + str(run), *args.args]
        results.append(run_check(godot, isolated, run / "logs", script.stem, command, args.timeout, args.graphics))
    passed = write_report(run / "reports", results, [], project)
    print(f"{'通过' if passed else '失败'}：{run / 'reports' / 'summary.md'}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
