"""Install/remove the launchd LaunchAgent that runs the tick every 10 min."""

from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path

LABEL = "com.autoconduct.agent"
PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
LOG_DIR = Path.home() / ".local" / "state" / "autoconduct"
INTERVAL_SECONDS = 600


def _plist_payload(package_dir: Path) -> dict:
    return {
        "Label": LABEL,
        "ProgramArguments": [
            sys.executable,
            "-m",
            "autoconduct",
            "run",
            "--once",
        ],
        "EnvironmentVariables": {
            "PYTHONPATH": str(package_dir),
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
        },
        "StartInterval": INTERVAL_SECONDS,
        "RunAtLoad": False,
        "StandardOutPath": str(LOG_DIR / "agent.log"),
        "StandardErrorPath": str(LOG_DIR / "agent.err.log"),
    }


def install() -> Path:
    package_dir = Path(__file__).resolve().parent.parent
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    PLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
    PLIST_PATH.write_bytes(plistlib.dumps(_plist_payload(package_dir)))
    subprocess.run(["launchctl", "unload", str(PLIST_PATH)], capture_output=True)
    subprocess.run(["launchctl", "load", str(PLIST_PATH)], check=True, capture_output=True)
    return PLIST_PATH


def uninstall() -> None:
    if PLIST_PATH.exists():
        subprocess.run(["launchctl", "unload", str(PLIST_PATH)], capture_output=True)
        PLIST_PATH.unlink()
