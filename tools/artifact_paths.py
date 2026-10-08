"""One artifact run directory for development tools (never inside the project)."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import subprocess
import uuid


def git_state(project: Path) -> dict:
    def read(*args: str) -> str:
        try:
            return subprocess.check_output(
                ["git", "--no-optional-locks", "-c", "core.quotepath=false", "-C", str(project), *args],
                encoding="utf-8", errors="replace", stderr=subprocess.DEVNULL,
                timeout=10,
            ).strip()
        except (OSError, subprocess.SubprocessError):
            return "unavailable"
    return {"commit": read("rev-parse", "HEAD"),
            "worktree_status": read("status", "--porcelain=v1")}


def create_run(project: Path, task: str, base: Path | None = None) -> Path:
    project = project.resolve()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", task):
        raise ValueError("任务名只允许字母、数字、下划线和连字符。")
    base = (base or project.parent / "_artifacts" / project.name / task).resolve()
    if base == project or project in base.parents:
        raise ValueError("运行产物必须保存在原项目之外。")
    stamp = datetime.now(timezone(timedelta(hours=8))).strftime("%Y%m%d_%H%M%S")
    run = base / (stamp + "_" + uuid.uuid4().hex[:8])
    for name in ("logs", "screenshots", "reports", "tmp"):
        (run / name).mkdir(parents=True, exist_ok=True)
    metadata = {"source_project": str(project), "task": task,
                "created_at": datetime.now(timezone(timedelta(hours=8))).isoformat(),
                **git_state(project)}
    (run / "reports" / "run.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8",
    )
    return run
