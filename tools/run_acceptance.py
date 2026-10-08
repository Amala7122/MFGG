"""Run Godot checks in an isolated copy and reject engine errors even on exit 0."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid


CORE_TESTS = (
    "test_scene_dependencies",
    "test_stability_contracts",
    "test_lowpoly_mesh",
    "test_runtime_world_visibility",
    "test_player_hitscan",
    "test_player_spread",
    "test_combat_feedback",
    "test_combat_reactions",
    "test_ground_juice",
    "test_enemy_deployment",
    "test_procedural_clouds",
    "test_weather_runtime_clouds",
    "test_player_presentation",
    "test_ui_surfaces",
    "test_upgrade_effects",
    "test_cinematic_flow_lifecycle",
)
GRAPHICS_ONLY = {"test_cloud_shadow_rendering"}
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
ENGINE_ERROR = re.compile(r"^\s*(?:SCRIPT ERROR|ERROR):", re.IGNORECASE)
ENGINE_WARNING = re.compile(r"^\s*WARNING:", re.IGNORECASE)


def find_godot(project: Path) -> Path:
    configured = os.environ.get("GODOT_BIN")
    if configured:
        return Path(configured).expanduser().resolve()
    for name in ("godot", "godot4"):
        executable = shutil.which(name)
        if executable:
            return Path(executable).resolve()
    candidates = list(project.parent.glob("Godot*_console.exe"))
    if candidates:
        return max(candidates, key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.name)))
    raise ValueError("找不到 Godot；用 --godot 指定引擎可执行文件，或设置 GODOT_BIN。")


def isolate_project(source: Path, destination: Path, run_id: str) -> None:
    ignored = shutil.ignore_patterns(
        ".git", ".godot", ".godot-mcp", ".agents", ".codex", ".aws",
        ".codebuddy", "__pycache__", "build", "visual_captures", "performance_logs",
        "*.log", "*.log.*",
    )
    shutil.copytree(source, destination, ignore=ignored)
    config_path = destination / "project.godot"
    config = config_path.read_text(encoding="utf-8-sig")
    user_directory = f"Godot/app_userdata/ruin-star-acceptance-{run_id}"
    for setting, value in (
        ("config/use_custom_user_dir", "true"),
        ("config/custom_user_dir_name", json.dumps(user_directory)),
    ):
        pattern = rf"(?m)^{re.escape(setting)}=.*$"
        replacement = f"{setting}={value}"
        if re.search(pattern, config):
            config = re.sub(pattern, lambda _: replacement, config)
        else:
            config = config.replace("[application]", f"[application]\n{replacement}", 1)
    config = re.sub(r"(?m)^(?:MCPRuntimeServer|_mcp_game_helper)=.*\n?", "", config)
    config = re.sub(
        r"(?ms)(\[editor_plugins\]\s*)enabled=.*?$",
        lambda match: match.group(1) + "enabled=PackedStringArray()",
        config,
    )
    config_path.write_text(config, encoding="utf-8", newline="\n")


def run_check(godot: Path, project: Path, output: Path, name: str,
              arguments: list[str], timeout: float, graphics: bool) -> dict:
    engine_log = output / f"{name}.engine.log"
    command = [str(godot), "--path", str(project)]
    if not graphics:
        command.append("--headless")
    command += ["--log-file", str(engine_log)] + arguments
    started = time.monotonic()
    timed_out = False
    launch_error = None
    stdout = stderr = ""
    exit_code = None
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    startup_info = None
    if os.name == "nt":
        startup_info = subprocess.STARTUPINFO()
        startup_info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup_info.wShowWindow = subprocess.SW_HIDE
    try:
        process = subprocess.Popen(
            command, cwd=project, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8", errors="replace", creationflags=creation_flags,
            startupinfo=startup_info,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            stdout, stderr = process.communicate()
        exit_code = process.returncode
    except OSError as error:
        launch_error = str(error)
    (output / f"{name}.stdout.log").write_text(stdout, encoding="utf-8")
    (output / f"{name}.stderr.log").write_text(stderr, encoding="utf-8")
    texts = [stdout, stderr]
    if engine_log.is_file():
        texts.append(engine_log.read_text(encoding="utf-8-sig", errors="replace"))
    lines = [ANSI.sub("", line) for text in texts for line in text.splitlines()]
    errors = sorted({line.strip() for line in lines if ENGINE_ERROR.match(line)})
    warnings = sorted({line.strip() for line in lines if ENGINE_WARNING.match(line)})
    passed = (exit_code == 0 and not errors and not timed_out
              and launch_error is None and engine_log.is_file())
    return {
        "name": name, "passed": passed, "exit_code": exit_code,
        "timed_out": timed_out, "launch_error": launch_error,
        "missing_engine_log": not engine_log.is_file(),
        "engine_errors": errors, "warnings": warnings,
        "seconds": round(time.monotonic() - started, 2),
        "engine_log": str(engine_log), "command": command,
    }


def verify_error_gate(godot: Path, project: Path, output: Path, timeout: float) -> dict:
    # These scripts intentionally print PASS and exit 0 after an engine error.
    # Their failed results prove that the outer gate does not trust either signal.
    fixture_directory = project / ".acceptance-fixtures"
    fixture_directory.mkdir()
    scripts = {
        "clean": 'extends SceneTree\nfunc _initialize():\n\tprint("PASS")\n\tquit(0)\n',
        "script_error": (
            'extends SceneTree\nfunc _initialize():\n\t_break_contract()\n'
            '\tprint("PASS")\n\tquit(0)\nfunc _break_contract():\n'
            '\tvar missing: Object = null\n\tmissing.call("not_available")\n'
        ),
        "resource_error": (
            'extends SceneTree\nfunc _initialize():\n'
            '\tResourceLoader.load("res://.acceptance-fixtures/missing_scene.tscn")\n'
            '\tprint("PASS")\n\tquit(0)\n'
        ),
    }
    cases = []
    for case, script in scripts.items():
        (fixture_directory / f"{case}.gd").write_text(script, encoding="utf-8")
        result = run_check(
            godot, project, output, f"gate_{case}",
            ["--script", f"res://.acceptance-fixtures/{case}.gd"], timeout, False,
        )
        text = (output / f"gate_{case}.stdout.log").read_text(encoding="utf-8")
        expected = result["passed"] if case == "clean" else (
            not result["passed"] and result["exit_code"] == 0
            and bool(result["engine_errors"]) and "PASS" in text
        )
        result["expectation_met"] = expected
        cases.append(result)
    return {"name": "engine_error_gate", "passed": all(c["expectation_met"] for c in cases),
            "cases": cases, "seconds": round(sum(c["seconds"] for c in cases), 2)}


def write_report(output: Path, results: list[dict], skipped: list[str], project: Path) -> bool:
    passed = bool(results) and all(result["passed"] for result in results)
    report = {"passed": passed, "source_project": str(project),
              "results": results, "skipped": skipped}
    (output / "summary.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8",
    )
    rows = ["# Godot 验收结果", "", f"结果：{'通过' if passed else '失败'}", "",
            "| 检查 | 结果 | 时间（秒） |", "|---|---|---:|"]
    for result in results:
        rows.append(f"| {result['name']} | {'通过' if result['passed'] else '失败'} | {result['seconds']} |")
    if skipped:
        rows += ["", "本次未运行（需要图形环境）：" + "、".join(skipped)]
    rows += ["", "脚本/资源错误、非零退出、超时或缺失引擎日志均使验收失败。",
             "音频等 WARNING 保留在 JSON 和日志中，不混同为脚本/资源错误。",
             "错误门槛自检中的报错是故意注入；这些用例必须被拒绝，才算自检通过。"]
    (output / "summary.md").write_text("\n".join(rows) + "\n", encoding="utf-8")
    return passed


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--suite", choices=("core", "full"), default="core")
    parser.add_argument("--tests", nargs="+", help="只运行指定 test_ 名称，可省略 .gd")
    parser.add_argument("--graphics", action="store_true", help="启用图形渲染及相关视觉检查")
    parser.add_argument("--output", type=Path, help="验收产物的父目录；每次新建独立子目录")
    parser.add_argument("--timeout", type=float, default=180.0, help="每项检查的秒数上限")
    parser.add_argument("--self-test-only", action="store_true", help="只验证错误日志门槛")
    args = parser.parse_args()
    project = args.project.resolve()
    if not (project / "project.godot").is_file() or args.timeout <= 0:
        parser.error("需要有效 Godot 项目和大于 0 的超时。")
    try:
        godot = args.godot.expanduser().resolve() if args.godot else find_godot(project)
    except ValueError as error:
        parser.error(str(error))
    if not godot.is_file():
        parser.error(f"引擎文件不存在：{godot}")
    available = {path.stem for path in (project / "tests").glob("test_*.gd")}
    requested = ([name.removesuffix(".gd") for name in args.tests] if args.tests else
                 (sorted(available) if args.suite == "full" else list(CORE_TESTS)))
    missing = sorted(set(requested) - available)
    if missing:
        parser.error("检查不存在：" + ", ".join(missing))
    skipped = [name for name in requested if name in GRAPHICS_ONLY and not args.graphics]
    selected = list(dict.fromkeys(name for name in requested if name not in skipped))
    if not selected and not args.self_test_only:
        parser.error("没有可运行的检查；图形检查需要 --graphics。")
    run_id = datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:8]
    base = (args.output or project.parent / "_analysis" / "acceptance").resolve()
    # Reject a location inside the source to avoid recursively copying our output.
    if base == project or project in base.parents:
        parser.error("验收输出目录必须位于原项目目录之外。")
    output = base / run_id
    output.mkdir(parents=True)
    isolated = output / "project"
    print(f"验收记录：{output}", flush=True)
    results: list[dict] = []
    try:
        isolate_project(project, isolated, run_id)
        imported = run_check(godot, isolated, output, "import",
                             ["--editor", "--import"], max(args.timeout, 240.0), False)
        results.append(imported)
        print(f"{'通过' if imported['passed'] else '失败'} import", flush=True)
        if imported["passed"]:
            gate = verify_error_gate(godot, isolated, output, args.timeout)
            results.append(gate)
            print(f"{'通过' if gate['passed'] else '失败'} engine_error_gate", flush=True)
            if gate["passed"] and not args.self_test_only:
                for name in selected:
                    arguments = ["--fixed-fps", "60", "--script", f"res://tests/{name}.gd"]
                    extra = []
                    if name == "test_cinematic_flow_lifecycle":
                        extra.append("--live-cinematics")
                    if args.graphics and name == "test_ui_surfaces":
                        extra.append("--capture")
                    if args.graphics and name == "test_upgrade_effects":
                        extra.append("--capture-perks")
                    if args.graphics and name == "test_ground_juice":
                        extra.append("--capture-ground")
                    if extra:
                        arguments += ["--"] + extra
                    result = run_check(godot, isolated, output, name, arguments, args.timeout, args.graphics)
                    results.append(result)
                    print(f"{'通过' if result['passed'] else '失败'} {name} ({result['seconds']}s)", flush=True)
                    if not result["passed"]:
                        for line in result["engine_errors"][:4]:
                            print("  " + line, flush=True)
    except Exception as error:
        results.append({"name": "runner", "passed": False, "seconds": 0,
                        "error": str(error)})
        print(f"验收执行失败：{error}", file=sys.stderr)
    passed = write_report(output, results, skipped, project)
    print(f"{'全部通过' if passed else '验收失败'}：{output / 'summary.md'}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
