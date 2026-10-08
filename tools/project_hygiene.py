"""Reversible file migration and non-destructive workspace hygiene checks."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

from artifact_paths import create_run

PROJECT = Path(__file__).resolve().parent.parent
WORKSPACE = PROJECT.parent
ARCHIVE_DOCS = {
    "docs/ui_design/implementation_plan.md": "docs/archive/ui/implementation_plan.md",
    "docs/普攻与敌人改造计划.md": "docs/archive/combat/普攻与敌人改造计划.md",
    "docs/数值审计报告.md": "docs/archive/numerics/数值审计报告.md",
    "docs/视觉迭代日志.md": "docs/archive/visual/视觉迭代日志.md",
}
SKIP = {".git", ".godot", ".codebuddy", ".godot-mcp", "addons", "assets",
        "build", "export_templates", "__pycache__"}


def digest(file: Path) -> str:
    value = hashlib.sha256()
    with file.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def within(file: Path, root: Path) -> bool:
    resolved, boundary = file.resolve(), root.resolve()
    return resolved == boundary or boundary in resolved.parents


def write_json(file: Path, value: dict) -> None:
    file.parent.mkdir(parents=True, exist_ok=True)
    temporary = file.with_suffix(file.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(file)


def artifact_kind(file: Path) -> str:
    suffix = file.suffix.lower()
    if suffix in {".png", ".jpg", ".jpeg", ".webp", ".svg"}:
        return "screenshots"
    if suffix == ".log" or ".log." in file.name:
        return "logs"
    if suffix in {".json", ".md", ".csv", ".txt", ".tsv"}:
        return "reports"
    return "tmp"


def migration_plan(run: Path) -> list[dict]:
    moves: list[dict] = []
    def add(source: Path, target: Path, reason: str) -> None:
        if source.is_symlink() or not within(source, WORKSPACE) or not within(target, WORKSPACE):
            raise ValueError(f"迁移路径越界或为符号链接：{source}")
        if target.exists():
            raise ValueError(f"目标已存在，不覆盖：{target}")
        moves.append({"source": str(source), "target": str(target),
                      "reason": reason, "size": source.stat().st_size,
                      "sha256": digest(source), "moved": False})
    for file in sorted(WORKSPACE.glob("*.log")):
        add(file, WORKSPACE / "_artifacts" / "legacy" / run.name / "logs" / file.name,
            "父目录散落日志；归属未确认，按原名保留")
    for file in sorted(PROJECT.glob("*.log")):
        add(file, run / "logs" / "historical_project_root" / file.name, "项目根目录历史日志")
    for folder in ("visual_captures", "performance_logs", "captures"):
        directory = PROJECT / folder
        for file in sorted(directory.rglob("*")):
            if file.is_file():
                add(file, run / artifact_kind(file) / "historical" / folder / file.relative_to(directory),
                    "本项目历史产物；保留原相对路径")
    for old, new in ARCHIVE_DOCS.items():
        file = PROJECT / old
        if file.is_file():
            add(file, PROJECT / new, "被替代的方案或历史分析；原文保留，现行要求另行提取")
    for file in sorted((PROJECT / ".codebuddy" / "plans").glob("*.md")):
        add(file, PROJECT / "docs" / "archive" / "agent_plans" / file.name,
            "保全未受 Git 管理的 agent 历史计划")
    analysis = WORKSPACE / "_analysis"
    for entry in sorted(analysis.glob("ruin_new*")):
        files = [entry] if entry.is_file() else sorted(f for f in entry.rglob("*") if f.is_file())
        for file in files:
            relative = file.relative_to(entry) if entry.is_dir() else Path(entry.name)
            # Historical isolated projects stay intact; changing their layout breaks reports.
            add(file, run / "tmp" / "historical_analysis" / entry.name / relative,
                "名称明确归属 ruin_new；完整保留历史验收目录结构")
    return moves


def migrate() -> None:
    run = create_run(PROJECT, "project_cleanup")
    # Record original tracked text before any edits. Also retain ignored agent plans.
    tracked = subprocess.check_output(
        ["git", "--no-optional-locks", "-C", str(PROJECT), "ls-files", "-z"],
        encoding="utf-8",
    ).split("\0")
    backups = []
    for relative in tracked:
        source = PROJECT / relative
        if not relative or not source.is_file() or source.suffix.lower() not in {
            ".gd", ".uid", ".py", ".md", ".json", ".cfg", ".godot", ".tscn", ".tres", "",
        }:
            continue
        target = run / "tmp" / "before" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        backups.append({"source": str(source), "backup": str(target), "sha256": digest(source)})
    moves = migration_plan(run)
    manifest = {"project": str(PROJECT), "workspace": str(WORKSPACE),
                "run": str(run), "backups": backups, "moves": moves,
                "status": "planned"}
    file = run / "reports" / "migration.json"
    write_json(file, manifest)
    print(f"迁移清单：{file}\n待迁移 {len(moves)} 个文件；先保全 {len(backups)} 个源文件", flush=True)
    # Each file has a checked absolute source/target; no computed recursive deletion/move.
    try:
        for index, item in enumerate(moves):
            source, target = Path(item["source"]), Path(item["target"])
            if digest(source) != item["sha256"]:
                raise ValueError(f"源文件在盘点后发生变化：{source}")
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                raise ValueError(f"目标已存在：{target}")
            source.rename(target)
            if digest(target) != item["sha256"]:
                raise ValueError(f"迁移后校验失败：{target}")
            item["moved"] = True
            if index % 500 == 0:
                write_json(file, manifest)
                print(f"已迁移 {index + 1}/{len(moves)}", flush=True)
        manifest["status"] = "migrated"
    finally:
        write_json(file, manifest)
    rows = ["# 整理迁移记录", "", "每个文件的原路径、去向、大小、SHA-256 和状态见 migration.json。",
            "恢复前先预览；恢复不会覆盖已有文件或删除整理后新创建的文件。", "",
            f"迁移文件：{len(moves)}；源码备份：{len(backups)}。", "",
            "| 原因 | 文件数 |", "|---|---:|"]
    rows += [f"| {reason} | {count} |" for reason, count in Counter(x["reason"] for x in moves).items()]
    (run / "reports" / "migration.md").write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"迁移完成：{run}", flush=True)


def restore(file: Path, apply: bool) -> None:
    manifest = json.loads(file.read_text(encoding="utf-8"))
    actions = []
    originals = {item["source"]: item for item in manifest["backups"]}
    for item in reversed(manifest["moves"]):
        source, target = Path(item["source"]), Path(item["target"])
        if source.exists() and not target.exists() and digest(source) == item["sha256"]:
            continue
        if not within(source, WORKSPACE) or not within(target, WORKSPACE):
            raise ValueError("清单路径越界")
        if not target.is_file() or digest(target) not in {item["sha256"], item.get("organized_sha256")} or source.exists():
            raise ValueError(f"拒绝覆盖或恢复已变化的文件：{source}")
        original = originals.get(str(source))
        if original is not None:
            backup = Path(original["backup"])
            if not within(backup, Path(manifest["run"])) or not backup.is_file() or digest(backup) != original["sha256"]:
                raise ValueError(f"源码备份缺失或变化：{source}")
        actions.append((target, source, Path(original["backup"]) if original else None))
    changed = []
    moved_sources = {item["source"] for item in manifest["moves"]}
    for item in manifest["backups"]:
        source, backup = Path(item["source"]), Path(item["backup"])
        if item["source"] in moved_sources or not source.exists() or digest(source) == item["sha256"]:
            continue
        if digest(source) != item.get("organized_sha256") or digest(backup) != item["sha256"]:
            raise ValueError(f"源码在整理后有新修改；先人工合并再恢复：{source}")
        changed.append((source, backup))
    print(f"可恢复迁移文件：{len(actions)}；源码修改：{len(changed)}；模式：{'执行' if apply else '预览'}")
    if apply:
        recovery = Path(manifest["run"]) / "tmp" / "restore_preserved"
        for target, source, backup in actions:
            source.parent.mkdir(parents=True, exist_ok=True)
            if backup is not None and digest(target) != digest(backup):
                preserved = recovery / "edited_migrations" / target.relative_to(WORKSPACE)
                preserved.parent.mkdir(parents=True, exist_ok=True)
                target.rename(preserved)
                shutil.copy2(backup, source)
            else:
                target.rename(source)
        for source, backup in changed:
            preserved = recovery / "edited_source" / source.relative_to(PROJECT)
            preserved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, preserved)
            shutil.copy2(backup, source)


def finalize(file: Path) -> None:
    manifest = json.loads(file.read_text(encoding="utf-8"))
    for item in manifest["backups"]:
        source = Path(item["source"])
        if source.is_file():
            item["organized_sha256"] = digest(source)
    for item in manifest["moves"]:
        target = Path(item["target"])
        if target.is_file() and (PROJECT in target.parents) and target.suffix in {".md", ".gd", ".uid", ".py"}:
            item["organized_sha256"] = digest(target)
    for item in manifest.get("copies", []):
        target = Path(item["target"])
        if target.is_file():
            item["organized_sha256"] = digest(target)
    manifest["status"] = "organized_and_verified"
    write_json(file, manifest)
    print("已登记整理后的源码与归档校验值；恢复预览会保护之后的新修改。")


def check(project: Path, workspace: Path) -> list[str]:
    problems = []
    allowed = {"README.md", "AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "GEMINI.md",
               ".mcp.json", "active-game.json", "active-game.example.json", "opencode.json", "opencode.example.json"}
    for root in (workspace, project):
        for file in root.iterdir():
            # User-requested workspace-level history index; not an artifact dump.
            if root == workspace and file.name == "项目演进与功能清单.md":
                continue
            if file.is_file() and file.name not in allowed and (file.suffix.lower() in {".log", ".png", ".jpg", ".csv", ".py", ".gd", ".md", ".txt", ".tsv", ".json"}
                                   or ".log." in file.name):
                problems.append(f"根目录散落产物或脚本：{file}")
    for name in ("visual_captures", "performance_logs", "captures"):
        if any(file.is_file() for file in (project / name).rglob("*")):
            problems.append(f"仍在使用旧产物目录：{project / name}")
    for directory in ("scripts", "tests", "tools"):
        for file in (project / directory).rglob("*"):
            if file.suffix not in {".gd", ".py"} or file == Path(__file__).resolve():
                continue
            if directory == "tests" and "fixtures" in file.relative_to(project / "tests").parts:
                continue  # Declared historical comparison data is not a new output writer.
            text = file.read_text(encoding="utf-8-sig")
            if re.search(r'["\'](?:res://(?:\.\./)?visual_captures|D:[/\\]godot_project[/\\]visual_captures|res://performance_logs)', text):
                problems.append(f"旧产物输出路径：{file}")
    for file in project.rglob("*.md"):
        if any(part in SKIP for part in file.relative_to(project).parts):
            continue
        for match in re.finditer(r"\[[^\]]+\]\(([^)]+)\)", file.read_text(encoding="utf-8-sig")):
            link = match.group(1).split("#", 1)[0]
            if not link or re.match(r"^[A-Za-z]+:", link) or link.startswith("/"):
                continue
            if not (file.parent / link).exists():
                problems.append(f"文档链接失效：{file.relative_to(project)} -> {link}")
    return problems


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "migrate", "restore", "finalize"))
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--apply", action="store_true", help="执行迁移/恢复；恢复默认只预览")
    args = parser.parse_args()
    if args.action == "migrate":
        if not args.apply:
            parser.error("迁移必须显式指定 --apply")
        migrate()
    elif args.action in {"restore", "finalize"}:
        if args.manifest is None:
            parser.error("恢复需要 --manifest")
        if args.action == "restore":
            restore(args.manifest, args.apply)
        else:
            finalize(args.manifest)
    else:
        problems = check(PROJECT, WORKSPACE)
        print("\n".join(problems) if problems else "目录检查通过：根目录整洁、产物路径规范、文档链接有效。")
        return 1 if problems else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
