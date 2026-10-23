"""Run Godot checks in an isolated copy and reject engine errors even on exit 0."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from artifact_paths import create_run
from automation_windows import BackgroundWindows


CORE_TESTS = (
    "test_mouse_control",
    "test_fps_overlay",
    "test_scene_dependencies",
    "test_audio_file_bank",
    "test_audio_synth_variants",
    "test_stability_contracts",
    "test_lowpoly_mesh",
    "test_runtime_world_visibility",
    "test_player_hitscan",
    "test_player_spread",
    "test_skill_charges",
    "test_player_melee",
    "test_player_support_visuals",
    "test_sketch_filter",
    "test_greybox",
    "test_combat_feedback",
    "test_combat_reactions",
    "test_ground_juice",
    "test_enemy_deployment",
    "test_sanctum_handoff",
    "test_crystal_creature_combat",
    "test_enemy_parameter_contract",
    "test_skill_shape_workspace",
    "test_enemy_parameter_input",
    "test_observation_camera",
    "test_poison_puddle",
    "test_titan_sanctum_route",
    "test_creature_navigation_and_attacks",
    "test_mud_golem_architecture",
    "test_navigation_render_budget",
    "test_navigation_planner_yield",
    "test_main_run_preparation",
    "test_combat_resource_preparation",
    "test_enemy_attack_queue",
    "test_enemy_attack_queue_panel",
    "test_enemy_attack_queue_hosts",
    "test_crystal_pose_equivalence",
    "test_enemy_hit_flash",
    "test_enemy_roster",
    "test_sediment_titan_boss",
    "test_sediment_titan_boss_lab",
    "test_boss_scene_style",
    "test_boss_scene_cold_start",
    "test_titan_sparring",
    "test_sparring_cycles",
    "test_sparring_diagnostics",
    "test_combat_sparring",
    "test_combat_sparring_handoff",
    "test_sparring_human",
    "test_sparring_manual_entry",
    "test_grenade_enemy_contact",
    "test_grenade_hit_stagger",
    "test_grenade_reserve",
    "test_titan_offense_rhythm",
    "test_titan_pressure",
    "test_titan_followup",
    "test_titan_rage_director",
    "test_titan_triple_slam_readability",
    "test_titan_shield_break",
    "test_titan_crystal_protection",
    "test_titan_crystal_targeting",
    "test_titan_down_reward",
    "test_sparring_phase_entry",
    "test_player_boss_ground_safety",
    "test_heavy_response",
    "test_shield_guard_preview",
    "test_pickup_magnet",
    "test_procedural_clouds",
    "test_weather_runtime_clouds",
    "test_player_presentation",
    "test_ui_surfaces",
    "test_upgrade_effects",
    "test_cinematic_flow_lifecycle",
)
GRAPHICS_ONLY = {"test_cloud_shadow_rendering", "test_weather_visual_regressions", "test_titan_break_visuals"}
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
        ".codebuddy", "__pycache__", "build", "visual_captures", "performance_logs", "captures", "_artifacts",
        "*.log", "*.log.*",
    )
    shutil.copytree(source, destination, ignore=ignored)
    config_path = destination / "project.godot"
    config = config_path.read_text(encoding="utf-8-sig")
    user_directory = f"Godot/app_userdata/ruin-star-acceptance-{run_id}"
    for section, setting, value in (
        ("application", "config/use_custom_user_dir", "true"),
        ("application", "config/custom_user_dir_name", json.dumps(user_directory)),
        # 必须在创建第一个窗口前生效，运行后设 flag 仍可能先抢一次焦点。
        ("display", "window/size/no_focus", "true"),
        ("display", "window/size/always_on_top", "false"),
        ("display", "window/size/mode", "0"),
    ):
        pattern = rf"(?m)^{re.escape(setting)}=.*$"
        replacement = f"{setting}={value}"
        if re.search(pattern, config):
            config = re.sub(pattern, lambda _: replacement, config)
        elif f"[{section}]" in config:
            config = config.replace(f"[{section}]", f"[{section}]\n{replacement}", 1)
        else:
            config += f"\n[{section}]\n{replacement}\n"
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
    background = {"enabled": False, "placements": [], "errors": []}
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    startup_info = None
    # 测试的编辑器缓存和 user:// 都归本次运行，避免写入真实用户目录。
    environment = os.environ.copy()
    # 逻辑捕获由 MouseControl 记录，绝不限制用户的系统鼠标。
    # 用环境变量而不是仅传命令行，确保 OS.execute 启动的子引擎也受保护。
    environment["RUIN_STAR_AUTOMATION"] = "1"
    # 引擎会消费部分启动参数；记录器不能据 OS.get_cmdline_args() 的缺项判 false。
    engine_arguments = arguments[:arguments.index("--")] if "--" in arguments else arguments
    fixed_fps = "unfixed"
    for index, argument in enumerate(engine_arguments):
        if argument == "--fixed-fps" and index + 1 < len(engine_arguments):
            fixed_fps = engine_arguments[index + 1]
        elif argument.startswith("--fixed-fps="):
            fixed_fps = argument.partition("=")[2]
    environment["RUIN_STAR_RUN_FIXED_FPS"] = fixed_fps
    if os.name == "nt":
        user_data = output.parent / "tmp" / "user-data"
        user_data.mkdir(parents=True, exist_ok=True)
        environment["APPDATA"] = str(user_data)
        environment["LOCALAPPDATA"] = str(user_data)
    if os.name == "nt":
        startup_info = subprocess.STARTUPINFO()
        startup_info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup_info.wShowWindow = subprocess.SW_HIDE
    try:
        process = subprocess.Popen(
            command, cwd=project, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8", errors="replace", creationflags=creation_flags,
            startupinfo=startup_info, env=environment,
        )
        windows = BackgroundWindows(process.pid, graphics)
        try:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                process.kill()
                stdout, stderr = process.communicate()
        finally:
            background = windows.close()
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
              and launch_error is None and engine_log.is_file() and not background["errors"])
    return {
        "name": name, "passed": passed, "exit_code": exit_code,
        "timed_out": timed_out, "launch_error": launch_error,
        "missing_engine_log": not engine_log.is_file(),
        "engine_errors": errors, "warnings": warnings,
        "seconds": round(time.monotonic() - started, 2),
        "engine_log": str(engine_log), "command": command,
        "automation_mouse_isolation": True,
        "background_windows": background,
    }


def verify_error_gate(godot: Path, project: Path, output: Path, timeout: float) -> dict:
    # These scripts intentionally print PASS and exit 0 after an engine error.
    # Their failed results prove that the outer gate does not trust either signal.
    fixture_directory = project / "tests" / "fixtures" / "_error_gate"
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
            '\tResourceLoader.load("res://tests/fixtures/_error_gate/missing_scene.tscn")\n'
            '\tprint("PASS")\n\tquit(0)\n'
        ),
    }
    cases = []
    for case, script in scripts.items():
        (fixture_directory / f"{case}.gd").write_text(script, encoding="utf-8")
        result = run_check(
            godot, project, output, f"gate_{case}",
            ["--script", f"res://tests/fixtures/_error_gate/{case}.gd"], timeout, False,
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
    metadata_file = output / "run.json"
    metadata = json.loads(metadata_file.read_text(encoding="utf-8")) if metadata_file.exists() else {}
    report = {"passed": passed, "source_project": str(project), "run": metadata,
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
    parser.add_argument("--output", type=Path, help="项目外的产物父目录；每次新建独立子目录")
    parser.add_argument("--task", default="acceptance", help="产物任务名，默认 acceptance")
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
    from project_hygiene import check
    problems = check(project, project.parent)
    if problems:
        parser.error("目录检查失败；先整理以下问题：\n" + "\n".join(problems))
    try:
        output = create_run(project, args.task, args.output)
    except ValueError as error:
        parser.error(str(error))
    run_id = output.name
    logs = output / "logs"
    isolated = output / "tmp" / "project"
    print(f"验收记录：{output}", flush=True)
    results: list[dict] = []
    try:
        isolate_project(project, isolated, run_id)
        imported = run_check(godot, isolated, logs, "import",
                             ["--editor", "--import"], max(args.timeout, 240.0), False)
        results.append(imported)
        print(f"{'通过' if imported['passed'] else '失败'} import", flush=True)
        if imported["passed"]:
            gate = verify_error_gate(godot, isolated, logs, args.timeout)
            results.append(gate)
            print(f"{'通过' if gate['passed'] else '失败'} engine_error_gate", flush=True)
            if gate["passed"] and not args.self_test_only:
                for name in selected:
                    arguments = ["--fixed-fps", "60", "--script", f"res://tests/{name}.gd"]
                    extra = ["--artifact-dir=" + str(output)]
                    if name == "test_cinematic_flow_lifecycle":
                        extra.append("--live-cinematics")
                    if args.graphics and name == "test_ui_surfaces":
                        extra.append("--capture")
                    if args.graphics and name == "test_upgrade_effects":
                        extra.append("--capture-perks")
                    if args.graphics and name == "test_ground_juice":
                        extra.append("--capture-ground")
                    if args.graphics and name == "test_combat_feedback":
                        extra.append("--capture-feedback")
                    if args.graphics and name == "test_motion_observation_tools":
                        extra.append("--capture-motion-tools")
                    if extra:
                        arguments += ["--"] + extra
                    result = run_check(godot, isolated, logs, name, arguments, args.timeout, args.graphics)
                    results.append(result)
                    print(f"{'通过' if result['passed'] else '失败'} {name} ({result['seconds']}s)", flush=True)
                    if not result["passed"]:
                        for line in result["engine_errors"][:4]:
                            print("  " + line, flush=True)
    except Exception as error:
        results.append({"name": "runner", "passed": False, "seconds": 0,
                        "error": str(error)})
        print(f"验收执行失败：{error}", file=sys.stderr)
    passed = write_report(output / "reports", results, skipped, project)
    print(f"{'全部通过' if passed else '验收失败'}：{output / 'reports' / 'summary.md'}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
