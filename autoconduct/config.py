"""Configuration loading. Immutable Config dataclass, JSON file on disk."""

from __future__ import annotations

import json
from dataclasses import dataclass, replace
from pathlib import Path

CONFIG_PATH = Path.home() / ".config" / "autoconduct" / "config.json"

DEFAULTS = {
    "active_hours": (23, 7),  # resume only between 23:00 and 07:00 local
    "five_hour_ceiling": 85.0,  # never push the 5h window above this %
    "weekly_ceiling": 90.0,  # absolute weekly stop line
    "max_resumes_per_session": 3,  # per night, per session
    "max_sessions_per_night": 10,
    "permission_mode": "acceptEdits",
    "resume_prompt": (
        "Continue where you left off. Finish the task you were working on. "
        "If everything is already done, reply DONE and stop."
    ),
}


@dataclass(frozen=True)
class Config:
    active_hours: tuple[int, int]
    five_hour_ceiling: float
    weekly_ceiling: float
    max_resumes_per_session: int
    max_sessions_per_night: int
    permission_mode: str
    resume_prompt: str


def default_config() -> Config:
    return Config(
        active_hours=tuple(DEFAULTS["active_hours"]),
        five_hour_ceiling=DEFAULTS["five_hour_ceiling"],
        weekly_ceiling=DEFAULTS["weekly_ceiling"],
        max_resumes_per_session=DEFAULTS["max_resumes_per_session"],
        max_sessions_per_night=DEFAULTS["max_sessions_per_night"],
        permission_mode=DEFAULTS["permission_mode"],
        resume_prompt=DEFAULTS["resume_prompt"],
    )


def load_config(path: Path = CONFIG_PATH) -> Config:
    """Load config from JSON, falling back to defaults for missing keys."""
    base = default_config()
    if not path.exists():
        return base
    try:
        raw = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Invalid config at {path}: {exc}") from exc
    known = {k: v for k, v in raw.items() if hasattr(base, k)}
    if "active_hours" in known:
        known["active_hours"] = tuple(known["active_hours"])
    return replace(base, **known)


def write_default_config(path: Path = CONFIG_PATH) -> None:
    """Write the default config if none exists. Never overwrites."""
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    serializable = {**DEFAULTS, "active_hours": list(DEFAULTS["active_hours"])}
    path.write_text(json.dumps(serializable, indent=2) + "\n")
