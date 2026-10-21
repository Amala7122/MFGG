"""Cold-start the three professional scenes using the real scene entry, as F6 does.

Reuses the acceptance launcher's isolated project, error gate, mouse and window
isolation. The watchdog exists only in the artifact copy, never in game exports.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT / "tools"))
from artifact_paths import create_run
from project_hygiene import check
from run_acceptance import find_godot, isolate_project, run_check, write_report

SCENES = {
    "prototype": "res://prototypes/combat_lab/combat_lab.tscn",
    "visual": "res://prototypes/visual_lab/enemy_visual_lab.tscn",
    "spatial": "res://prototypes/spatial_lab/combat_spatial_lab.tscn",
}
WATCHDOG = '''extends Node
const Artifacts := preload("res://scripts/artifact_paths.gd")
var frames := 0
var failures: Array[String] = []
var checks := 0
var finished := false
func _ready() -> void: process_mode = Node.PROCESS_MODE_ALWAYS
func check(ok: bool, text: String) -> void:
    checks += 1
    if not ok: failures.append(text); push_error(text)
func _process(_delta: float) -> void:
    frames += 1
    if frames >= 12 and not finished:
        finished = true
        verify()
func verify() -> void:
    var tree := get_tree()
    var scene := tree.current_scene
    check(scene != null and scene.is_node_ready(), "F6真实场景完成初始化")
    var nav := tree.root.get_node_or_null("ProfessionalNavigation")
    check(nav != null and nav.is_node_ready(), "冷启动后导航已挂载且完成初始化")
    if nav != null:
        check(nav.destination != null and nav.destination.text == "独立启动", "导航控件真实存在且来源正确")
        check(nav.back_button != null and nav.back_button.disabled, "无调用方的返回禁用")
        var services := 0
        for child in tree.root.get_children():
            if child.name == "ProfessionalNavigation": services += 1
        check(services == 1, "只挂载一个导航服务")
    if scene != null and nav != null and scene.has_method("_show_enemy_tuning"):
        scene.call("_show_enemy_tuning", "VisualChargeBeetle")
        await tree.process_frame
        check(scene.get("_tuning_panel") != null and scene.get("_tuning_panel").visible, "F6之后可以进入参数页")
        check(not nav.back_button.disabled and nav.destination.text == "敌人配置", "进入参数后返回状态更新")
        nav.back()
        await tree.process_frame
        check(scene.get("_panel").visible and not scene.get("_tuning_panel").visible, "冷启动导航实际返回配置")
    if scene != null and nav != null and scene.has_method("_show_subject"):
        scene.call("_show_subject", 10)
        await tree.process_frame
        check(scene.get("_visual_panel").visible and scene.get("_visual_panel").profile == "VisualChargeBeetle", "F6视觉台能切到战斗体外形编辑")
    check(MouseControl.mode == Input.MOUSE_MODE_VISIBLE, "启动及参数往返不捕获鼠标")
    var case := "startup"
    for argument in OS.get_cmdline_user_args():
        if argument.begins_with("--f6-case="): case = argument.trim_prefix("--f6-case=")
    if DisplayServer.get_name() != "headless":
        await RenderingServer.frame_post_draw
        check(tree.root.get_texture().get_image().save_png(Artifacts.ensure_dir("screenshots").path_join("f6_"+case+".png")) == OK, "冷启动截图已保存")
    var file := FileAccess.open(Artifacts.ensure_dir("reports").path_join("f6_"+case+".json"),FileAccess.WRITE)
    file.store_string(JSON.stringify({"scene":scene.scene_file_path if scene else "", "checks":checks,"failures":failures},"\\t"))
    file.close()
    tree.quit(0 if failures.is_empty() else 1)
'''


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graphics", action="store_true")
    parser.add_argument("--task", default="professional_f6_startup")
    args = parser.parse_args()
    problems = check(PROJECT, PROJECT.parent)
    if problems:
        parser.error("\n".join(problems))
    run = create_run(PROJECT, args.task)
    isolated = run / "tmp" / "project"
    isolate_project(PROJECT, isolated, run.name)
    watchdog = isolated / "tests" / "fixtures" / "_professional_f6_watchdog.gd"
    watchdog.write_text(WATCHDOG, encoding="utf-8")
    settings = isolated / "project.godot"
    content = settings.read_text(encoding="utf-8")
    content = content.replace("[autoload]", '[autoload]\nProfessionalF6Watchdog="*res://tests/fixtures/_professional_f6_watchdog.gd"', 1)
    settings.write_text(content, encoding="utf-8")
    godot = find_godot(PROJECT)
    results = [run_check(godot, isolated, run / "logs", "import", ["--editor", "--import"], 240, False)]
    print(f"F6启动验证：{run}", flush=True)
    if results[0]["passed"]:
        for case, scene in SCENES.items():
            result = run_check(godot, isolated, run / "logs", "f6_" + case,
                               ["--fixed-fps", "60", "--quit-after", "120", scene,
                                "--", "--artifact-dir=" + str(run), "--f6-case=" + case],
                               90, args.graphics)
            report = run / "reports" / ("f6_" + case + ".json")
            result["startup_report_exists"] = report.is_file()
            result["passed"] = result["passed"] and report.is_file()
            results.append(result)
            print(f"{'通过' if result['passed'] else '失败'} F6 {case}", flush=True)
    passed = write_report(run / "reports", results, [], PROJECT)
    print(f"{'全部通过' if passed else '失败'}：{run / 'reports' / 'summary.md'}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
